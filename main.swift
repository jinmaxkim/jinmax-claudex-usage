//
// Cloudex Usage(5시간 / 주간) 메뉴바 표시 앱
//
// 데이터는 Claude 데스크톱 앱이 약 5분마다 기록하는 파일 하나만 읽는다.
// 네트워크 접근도, 권한 요청도 없다.
//   ~/Library/Application Support/Claude/plan-usage-history.json
//   samples[].t = 기록 시각(ms epoch), .u.fh = 5시간 사용률(%), .u.sd = 주간(7일) 사용률(%)
//
// 재설정 시각은 파일에 없으므로 히스토리에서 역산한다.
//   5시간 - 마지막 리셋 이후 사용률이 0에서 올라간 시점 + 5시간 (기록 간격 때문에 ±5분 오차)
//   주간   - 마지막 리셋 + 7일, 7일 주기가 일정해 기록이 비어도 보정된다.
//

import AppKit

// MARK: - 데이터

private let historyURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/Claude/plan-usage-history.json")

struct Snapshot {
    var fh: Int
    var sd: Int
    var recordedAt: Date
    var fhReset: Date?
    var sdReset: Date?
}

func loadSnapshot() -> Snapshot? {
    guard let data = try? Data(contentsOf: historyURL),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let raw = root["samples"] as? [[String: Any]]
    else { return nil }

    let samples: [(t: Double, fh: Int, sd: Int)] = raw.compactMap { s in
        guard let ms = s["t"] as? Double else { return nil }
        let u = s["u"] as? [String: Any]
        return (
            ms / 1000,
            (u?["fh"] as? NSNumber)?.intValue ?? 0,
            (u?["sd"] as? NSNumber)?.intValue ?? 0
        )
    }

    guard let last = samples.last else { return nil }
    guard samples.count > 1 else {
        return Snapshot(
            fh: last.fh,
            sd: last.sd,
            recordedAt: Date(timeIntervalSince1970: last.t),
            fhReset: nil,
            sdReset: nil
        )
    }

    // 5시간: 값이 줄어든 마지막 지점(리셋) 이후, 0에서 올라간 첫 지점이 새 시작
    var fhResetIdx: Int?
    for i in 1..<samples.count where samples[i].fh < samples[i - 1].fh {
        fhResetIdx = i
    }

    // 리셋 직후 값이 이미 0보다 크면(100% → 1%처럼) 그 지점을 새 시작점으로 본다
    var fhStart: Double?
    if let r = fhResetIdx {
        if samples[r].fh > 0 {
            fhStart = samples[r].t
        } else if r + 1 < samples.count {
            for i in (r + 1)..<samples.count
            where samples[i].fh > 0 && samples[i - 1].fh == 0 {
                fhStart = samples[i].t
                break
            }
        }
    }

    let fhReset = fhStart.map {
        Date(timeIntervalSince1970: $0 + 5 * 3600)
    }

    // 주간: 마지막 리셋 후 7일, 이미 지난 값이면 7일 단위로 미래까지 밀어준다.
    var sdResetAt: Double?
    for i in 1..<samples.count where samples[i].sd < samples[i - 1].sd {
        sdResetAt = samples[i].t
    }

    var sdReset: Date?
    if let base = sdResetAt {
        let week = 7.0 * 86400
        let elapsed = Date().timeIntervalSince1970 - base
        sdReset = Date(
            timeIntervalSince1970: base + (floor(elapsed / week) + 1) * week
        )
    }

    return Snapshot(
        fh: last.fh,
        sd: last.sd,
        recordedAt: Date(timeIntervalSince1970: last.t),
        fhReset: fhReset,
        sdReset: sdReset
    )
}

// MARK: - Codex (ChatGPT 앱 통합 CLI)

// Codex는 사용량을 디스크에 남기지 않는다. app-server에 JSON-RPC로 물어봐야 한다.
// 일반 호출이 아니라 계정 조회라 토큰 사용량은 늘지 않지만, 프로세스를 띄우므로 자주 부르지 않는다.
private let codexExecutable = "/Applications/ChatGPT.app/Contents/Resources/codex"

struct CodexLimit {
    var usedPercent: Int
    var resetsAt: Date?
    var windowMinutes: Int?

    // 창 길이로 이름을 붙인다 (10080분 = 7일 = 주간)
    var label: String {
        guard let m = windowMinutes else { return "Codex 한도" }
        if m >= 10080 { return "Codex 주간 한도" }
        if m >= 1440 { return "Codex \(m / 1440)일 한도" }
        if m >= 60 { return "Codex \(m / 60)시간 한도" }
        return "Codex \(m)분 한도"
    }
}

func loadCodexLimits() -> [CodexLimit] {
    guard FileManager.default.isExecutableFile(atPath: codexExecutable) else {
        return []
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: codexExecutable)
    process.arguments = ["app-server"]

    let stdinPipe = Pipe()
    let stdoutPipe = Pipe()

    process.standardInput = stdinPipe
    process.standardOutput = stdoutPipe
    process.standardError = FileHandle.nullDevice

    guard (try? process.run()) != nil else {
        return []
    }

    let requests = [
        #"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"clientInfo":{"name":"claudex-usage","version":"1.0"}}}"#,
        #"{"jsonrpc":"2.0","method":"initialized","params":{}}"#,
        #"{"jsonrpc":"2.0","id":1,"method":"account/rateLimits/read","params":{}}"#
    ].joined(separator: "\n") + "\n"

    stdinPipe.fileHandleForWriting.write(Data(requests.utf8))

    // id:1 응답 한 줄만 기다린다
    let semaphore = DispatchSemaphore(value: 0)
    var buffer = Data()
    var limits: [CodexLimit] = []

    let reader = stdoutPipe.fileHandleForReading
    reader.readabilityHandler = { handle in
        let chunk = handle.availableData

        if chunk.isEmpty {
            semaphore.signal()
            return
        }

        buffer.append(chunk)

        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[buffer.startIndex..<newline])
            buffer.removeSubrange(buffer.startIndex...newline)

            guard
                let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                (obj["id"] as? NSNumber)?.intValue == 1,
                let result = obj["result"] as? [String: Any],
                let snapshot = result["rateLimits"] as? [String: Any]
            else {
                continue
            }

            for key in ["primary", "secondary"] {
                guard
                    let window = snapshot[key] as? [String: Any],
                    let pct = (window["usedPercent"] as? NSNumber)?.intValue
                else {
                    continue
                }

                limits.append(
                    CodexLimit(
                        usedPercent: pct,
                        resetsAt: (window["resetsAt"] as? NSNumber).map {
                            Date(timeIntervalSince1970: $0.doubleValue)
                        },
                        windowMinutes: (window["windowDurationMins"] as? NSNumber)?.intValue
                    )
                )
            }

            semaphore.signal()
            return
        }
    }

    _ = semaphore.wait(timeout: .now() + 20)
    reader.readabilityHandler = nil
    process.terminate()

    return limits
}

// MARK: - 아이콘

private let claudeAppPath = "/Applications/Claude.app"
private let chatgptAppPath = "/Applications/ChatGPT.app"

/// 앱 번들의 공식 아이콘을 그대로 가져온다.
/// NSWorkspace가 돌려주는 인스턴스는 공유될 수 있어 복사한 뒤 크기를 바꾼다.
private func appIcon(atPath path: String, size: CGFloat) -> NSImage? {
    guard
        FileManager.default.fileExists(atPath: path),
        let icon = NSWorkspace.shared.icon(forFile: path).copy() as? NSImage
    else {
        return nil
    }

    icon.size = NSSize(width: size, height: size)
    return icon
}

/// 메뉴바는 주변 아이콘과 높이만 맞추고, 메뉴 안은 표준 크기를 쓴다
private let menuBarIconSize: CGFloat = 19
private let menuItemIconSize: CGFloat = 16

/// 시스템 메뉴바와 같은 크기로 맞춰 숫자는 등폭으로 (자릿수가 바뀌어도 흔들리지 않게)
private func menuBarFont() -> NSFont {
    NSFont.monospacedDigitSystemFont(
        ofSize: NSFont.menuBarFont(ofSize: 0).pointSize,
        weight: .regular
    )
}

// MARK: - 표시 형식

private let weekdayKo = ["일", "월", "화", "수", "목", "금", "토"]

private func hhmm(_ date: Date) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "HH:mm"
    return f.string(from: date)
}

/// "3일 23시간 10분" - 0인 단위는 생략한다
func durationKo(_ seconds: TimeInterval) -> String {
    let s = Int(seconds)

    var parts: [String] = []

    if s / 86400 > 0 {
        parts.append("\(s / 86400)일")
    }

    if (s % 86400) / 3600 > 0 {
        parts.append("\((s % 86400) / 3600)시간")
    }

    if (s % 3600) / 60 > 0 {
        parts.append("\((s % 3600) / 60)분")
    }

    return parts.isEmpty ? "1분 미만" : parts.joined(separator: " ")
}

/// 하루 이상 남으면 "2026-08-12 10:03 (수) 재설정", 그 이하면 "7분 후 재설정"
func resetText(_ date: Date?) -> String? {
    guard let date else { return nil }

    let left = date.timeIntervalSinceNow

    if left < 0 {
        return "곧 재설정"
    }

    if left > 86400 {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"

        let wd = Calendar.current.component(.weekday, from: date) - 1

        return "\(f.string(from: date)) (\(weekdayKo[wd])) 재설정"
    }

    return "\(durationKo(left)) 후 재설정"
}

// MARK: - 메뉴바

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var codexTimer: Timer?

    private var codexLimits: [CodexLimit] = []

    private lazy var claudeIcon =
        appIcon(atPath: claudeAppPath, size: menuItemIconSize)

    private lazy var codexIcon =
        appIcon(atPath: chatgptAppPath, size: menuItemIconSize)

    private lazy var claudeBarIcon =
        appIcon(atPath: claudeAppPath, size: menuBarIconSize)

    private lazy var codexBarIcon =
        appIcon(atPath: chatgptAppPath, size: menuBarIconSize)

    /// 메뉴바에 무엇을 표시할지 (기본은 모두 표시)
    private enum Show {
        static let fiveHour = "showFiveHour"
        static let weekly = "showWeekly"
        static let codex = "showCodex"
    }

    private func isShown(_ key: String) -> Bool {
        UserDefaults.standard.object(forKey: key) == nil
            ? true
            : UserDefaults.standard.bool(forKey: key)
    }

    /// 둘 다 꺼져 있으면 Claude 쪽은 파일조차 읽지 않는다
    private var claudeTracked: Bool {
        isShown(Show.fiveHour) || isShown(Show.weekly)
    }

    @objc
    private func toggleShow(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else {
            return
        }

        let turningOn = !isShown(key)

        UserDefaults.standard.set(turningOn, forKey: key)

        if turningOn {
            // 켜질 때는 즉시 새 값을 반영
            if key == Show.codex {
                refreshCodex()
            }
        } else if key == Show.codex {
            // 꺼질 때는 조회를 멈추고 캐시도 비운다
            codexLimits = []
        }

        refresh()
    }

    private var loginPlistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/LaunchAgents/local.claudex-usage.plist"
            )
    }

    func applicationDidFinishLaunching(
        _ notification: Notification
    ) {

        statusItem = NSStatusBar.system.statusItem(
            withLength: NSStatusItem.variableLength
        )

        let menu = NSMenu()

        menu.delegate = self
        statusItem.menu = menu

        refresh()
        refreshCodex()

        timer = Timer.scheduledTimer(
            withTimeInterval: 60,
            repeats: true
        ) { [weak self] _ in
            self?.refresh()
        }

        // Codex 조회는 프로세스가 떠서 무거우므로 간격을 길게 둔다
        codexTimer = Timer.scheduledTimer(
            withTimeInterval: 300,
            repeats: true
        ) { [weak self] _ in
            self?.refreshCodex()
        }
    }

    /// 메뉴를 열 때는 파일만 다시 읽는다 (Codex 조회는 제외)
    func menuWillOpen(_ menu: NSMenu) {
        refresh()
    }

    @objc
    private func refreshNow() {
        refresh()
        refreshCodex()
    }

    private func refreshCodex() {
        // 꺼져 있으면 app-server 프로세스도 아예 띄우지 않는다
        guard isShown(Show.codex) else { return }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let limits = loadCodexLimits()

            DispatchQueue.main.async {
                self?.codexLimits = limits
                self?.refresh()
            }
        }
    }

    private func refresh() {
        let snap = claudeTracked ? loadSnapshot() : nil
        updateTitle(snap)
        rebuildMenu(snap)
    }

    private func colored(_ text: String, _ pct: Int) -> NSAttributedString {
        let color: NSColor =
            pct >= 85 ? .systemRed :
            (pct >= 60 ? .systemOrange : .labelColor)

        return NSAttributedString(
            string: text,
            attributes: [
                .foregroundColor: color,
                .font: menuBarFont()
            ]
        )
    }

    /// 앱 아이콘을 메뉴바 문자열 안에 끼워 넣는다
    private func iconText(
        _ image: NSImage?,
        fallback: String
    ) -> NSAttributedString {

        guard let image else {
            return NSAttributedString(string: fallback)
        }

        let attachment = NSTextAttachment()
        attachment.image = image

        // 아이콘 가운데를 글자 높이에 맞춘다
        let offsetY =
            (menuBarFont().capHeight - menuBarIconSize) / 2

        attachment.bounds = CGRect(
            x: 0,
            y: offsetY,
            width: menuBarIconSize,
            height: menuBarIconSize
        )

        return NSAttributedString(attachment: attachment)
    }

    private func updateTitle(_ snap: Snapshot?) {

        guard let button = statusItem.button else { return }

        let title = NSMutableAttributedString()

        let showFive = isShown(Show.fiveHour)
        let showWeek = isShown(Show.weekly)

        if let snap, showFive || showWeek {

            title.append(iconText(claudeBarIcon, fallback: "Claude"))

            if showFive {
                title.append(NSAttributedString(string: " "))
                title.append(colored("\(snap.fh)%", snap.fh))
            }

            if showWeek {
                title.append(NSAttributedString(string: " "))
                title.append(colored("\(snap.sd)%", snap.sd))
            }
        }

        // 창이 여러 개면 가장 많이 쓴 값을 올린다
        if isShown(Show.codex),
           let worst = codexLimits.max(by: { $0.usedPercent < $1.usedPercent }) {

            if title.length > 0 {
                title.append(NSAttributedString(string: " "))
            }

            title.append(iconText(codexBarIcon, fallback: "Codex"))
            title.append(NSAttributedString(string: " "))
            title.append(colored("\(worst.usedPercent)%", worst.usedPercent))
        }

        // 전부 끄면 클릭할 자리만 남도록 아이콘 하나만 표시
        if title.length == 0 {
            title.append(iconText(claudeBarIcon, fallback: "사용량"))
        }

        button.attributedTitle = title
    }

    private func addInfo(
        _ menu: NSMenu,
        _ title: String,
        icon: NSImage? = nil
    ) {
        let item = NSMenuItem(
            title: title,
            action: nil,
            keyEquivalent: ""
        )

        item.isEnabled = false
        item.image = icon

        menu.addItem(item)
    }

    private func rebuildMenu(_ snap: Snapshot?) {

        guard let menu = statusItem.menu else { return }

        menu.removeAllItems()

        if !claudeTracked && !isShown(Show.codex) {
            addInfo(menu, "추적 중인 항목이 없습니다")
        }

        if let snap {

            if isShown(Show.fiveHour) {
                addInfo(
                    menu,
                    "5시간 한도 \(snap.fh)%",
                    icon: claudeIcon
                )

                if let t = resetText(snap.fhReset) {
                    addInfo(menu, "  \(t)")
                }

                menu.addItem(.separator())
            }

            if isShown(Show.weekly) {
                addInfo(
                    menu,
                    "주간 한도 \(snap.sd)%",
                    icon: claudeIcon
                )

                if let t = resetText(snap.sdReset) {
                    addInfo(menu, "  \(t)")
                }

                menu.addItem(.separator())
            }

            let mins = max(
                1,
                Int(-snap.recordedAt.timeIntervalSinceNow / 60)
            )

            addInfo(
                menu,
                "기록 \(hhmm(snap.recordedAt)) (\(mins)분 전) · 앱이 약 5분마다 갱신"
            )

        } else if claudeTracked {

            addInfo(menu, "사용량 기록을 읽을 수 없습니다")
            addInfo(menu, "Claude 데스크톱 앱 실행 여부를 확인하세요")
        }

        if !codexLimits.isEmpty {

            menu.addItem(.separator())

            for limit in codexLimits {

                addInfo(
                    menu,
                    "\(limit.label) \(limit.usedPercent)%",
                    icon: codexIcon
                )

                if let t = resetText(limit.resetsAt) {
                    addInfo(menu, "  \(t)")
                }
            }
        }

        menu.addItem(.separator())

        let displaySubmenu = NSMenu()

        for (title, key) in [
            ("5시간 한도", Show.fiveHour),
            ("주간 한도", Show.weekly),
            ("Codex", Show.codex)
        ] {

            let item = NSMenuItem(
                title: title,
                action: #selector(toggleShow(_:)),
                keyEquivalent: ""
            )

            item.target = self
            item.representedObject = key
            item.state = isShown(key) ? .on : .off
            item.image = (key == Show.codex)
                ? codexIcon
                : claudeIcon

            displaySubmenu.addItem(item)
        }

        // 앱 표시만 아니라 조절 자체를 "표시 항목"으로 부른다
        let displayItem = NSMenuItem(
            title: "추적 항목",
            action: nil,
            keyEquivalent: ""
        )

        displayItem.submenu = displaySubmenu
        menu.addItem(displayItem)

        let refreshItem = menu.addItem(
            withTitle: "지금 새로고침",
            action: #selector(refreshNow),
            keyEquivalent: "r"
        )

        refreshItem.target = self

        let loginItem = menu.addItem(
            withTitle: "로그인 시 자동 실행",
            action: #selector(toggleLoginItem),
            keyEquivalent: ""
        )

        loginItem.target = self
        loginItem.state = FileManager.default.fileExists(
            atPath: loginPlistURL.path
        ) ? .on : .off

        menu.addItem(.separator())

        menu.addItem(
            withTitle: "종료",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
    }

    @objc
    private func toggleLoginItem(_ sender: NSMenuItem) {

        let fm = FileManager.default

        if fm.fileExists(atPath: loginPlistURL.path) {
            try? fm.removeItem(at: loginPlistURL)
            sender.state = .off
            return
        }

        let plist = """
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
 "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>local.claudex-usage</string>

    <key>ProgramArguments</key>
    <array>
        <string>\(Bundle.main.bundlePath)/Contents/MacOS/\(Bundle.main.infoDictionary?["CFBundleExecutable"] as? String ?? "claudex-usage")</string>
    </array>

    <key>RunAtLoad</key>
    <true/>

    <key>KeepAlive</key>
    <false/>
</dict>
</plist>
"""

        try? plist.write(
            to: loginPlistURL,
            atomically: true,
            encoding: .utf8
        )

        sender.state = .on
    }
}

// ------------------------------------------------------------
// CLI (--print)
// ------------------------------------------------------------

if CommandLine.arguments.contains("--print") {

    if let snap = loadSnapshot() {
        print("Claude 5시간 : \(snap.fh)%")
        print("Claude 주간  : \(snap.sd)%")
    }

    for limit in loadCodexLimits() {
        print("\(limit.label): \(limit.usedPercent)%")
    }

    exit(EXIT_SUCCESS)
}

// ------------------------------------------------------------
// App
// ------------------------------------------------------------

let app = NSApplication.shared
let delegate = AppDelegate()

app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
