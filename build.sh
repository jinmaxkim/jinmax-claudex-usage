#!/bin/bash
# ClaudexUsage.app 빌드 및 설치 (Xcode 없이 swiftc 만 사용)
set -e

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
# 응용 프로그램 폴더에 설치한다 (내 홈 폴더에 설치됨)
if [ -w "/Applications" ]; then
    APP="/Applications/ClaudexUsage.app"
else
    APP="$HOME/Applications/ClaudexUsage.app"
fi
BIN="$SRC_DIR/.build/ClaudexUsage"

mkdir -p "$SRC_DIR/.build"
echo "메인 앱 빌드..."
swiftc -O "$SRC_DIR/main.swift" -o "$BIN" -framework AppKit

echo "아이콘 빌드..."
swiftc -O "$SRC_DIR/makeicon.swift" -o "$SRC_DIR/.build/makeicon" -framework AppKit
"$SRC_DIR/.build/makeicon" "$SRC_DIR/.build/icon.png" >/dev/null
ICONSET="$SRC_DIR/.build/AppIcon.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
    sips -z "$s" "$s" "$SRC_DIR/.build/icon.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z "$((s * 2))" "$((s * 2))" "$SRC_DIR/.build/icon.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$SRC_DIR/.build/AppIcon.icns"

echo "앱 구성: $APP"
# 실행 중이면 먼저 내린다 (같은 경로에 덮어쓰기 위해)
pkill -x ClaudexUsage 2>/dev/null || true
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ClaudexUsage"
cp "$SRC_DIR/.build/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>ClaudexUsage</string>
    <key>CFBundleDisplayName</key><string>Claudex Usage</string>
    <key>CFBundleExecutable</key><string>ClaudexUsage</string>
    <key>CFBundleIdentifier</key><string>local.claudex-usage</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <!-- 메뉴바에만 표시하고 Dock 아이콘과 앱 스위처에는 넣지 않는다 -->
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

# 서명 없는 번들은 실행 시 거부될 수 있어 ad-hoc 서명을 붙인다
codesign --force --sign - "$APP" 2>/dev/null || echo "(codesign 실패)"

echo "완료: $APP"
echo "실행: open -a \"$APP\""
