// Claudex Usage 앱 아이콘 생성기 - 1024x1024 PNG 를 만든다.
// 사용법: makeicon <출력경로.png>
//
// 두 개의 게이지 링으로 Claude(바깥, 흰색)와 Codex(안쪽, OpenAI 그린)를 나타낸다.
// 배경은 Claude 주황 계열 그라데이션이라 채도가 낮은 기본 아이콘과 확실히 구분된다.

import AppKit

let outputPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "icon.png"

let side = 1024
let canvas = CGFloat(side)

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
) else { fatalError("비트맵을 만들 수 없습니다") }

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// 배경: macOS 아이콘 비율에 맞춘 둥근 사각형 + 대각 그라데이션
// 실제 앱 아이콘은 리소스에 여러 크기로 두므로 약간 안쪽으로 그린다
let inset = canvas * 0.06
let plate = NSRect(x: inset, y: inset, width: canvas - inset * 2, height: canvas - inset * 2)
let corner = plate.width * 0.2237   // Apple 스퀘어클 Radius ≈ corner radius
let platePath = NSBezierPath(roundedRect: plate, xRadius: corner, yRadius: corner)

let topColor = NSColor(srgbRed: 0.93, green: 0.53, blue: 0.36, alpha: 1)      // 밝은 주황
let bottomColor = NSColor(srgbRed: 0.72, green: 0.29, blue: 0.16, alpha: 1)   // 진한 주황
NSGradient(starting: topColor, ending: bottomColor)?.draw(in: platePath, angle: -60)

let center = NSPoint(x: canvas / 2, y: canvas / 2)

// 그라데이션 위에 링만으로 채워지는 심플 그래픽
func ring(radius: CGFloat, width: CGFloat, fraction: CGFloat, color: NSColor) {
    // 트랙(밝은 주황)을 뒤에 아주 희미하게 둔다.
    // 각도 없는 배경 위에 일부분 유색선을 얹으면 훨씬 선이 된다.
    let track = NSBezierPath()
    track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
    track.lineWidth = width
    NSColor.white.withAlphaComponent(0.20).setStroke()
    track.stroke()

    guard fraction > 0 else { return }
    let filled = NSBezierPath()
    filled.appendArc(withCenter: center, radius: radius,
                     startAngle: 90, endAngle: 90 - 360 * fraction, clockwise: true)
    filled.lineWidth = width
    filled.lineCapStyle = .round
    color.setStroke()
    filled.stroke()
}

// 바깥 링 = Claude, 안쪽 링 = Codex
ring(radius: canvas * 0.29, width: canvas * 0.095, fraction: 0.72, color: .white)
ring(radius: canvas * 0.19, width: canvas * 0.095, fraction: 0.45,
     color: NSColor(srgbRed: 0.10, green: 0.83, blue: 0.62, alpha: 1))

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("PNG 로 변환하지 못했습니다")
}
try png.write(to: URL(fileURLWithPath: outputPath))
print("아이콘 생성: \(outputPath)")
