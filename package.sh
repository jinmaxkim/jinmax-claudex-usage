#!/bin/bash
# ClaudexUsage.app 을 배포용 DMG 로 묶는다.
#
# 주의: 개발자 인증서 서명/공증(notarization)이 없다. 다른 맥에서 처음 열면
# Gatekeeper 가 막으므로 우클릭 → "열기" 를 한 번 이용해야 한다.
set -e

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$SRC_DIR/.build/ClaudexUsage.app"
DIST="$SRC_DIR/dist"

# 항상 최신 소스로 다시 빌드해서 담는다
"$SRC_DIR/build.sh" >/dev/null

VERSION=$(defaults read "$APP/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "1.0")
DMG="$DIST/ClaudexUsage-$VERSION.dmg"

mkdir -p "$DIST"
STAGING=$(mktemp -d)
trap 'rm -rf "$STAGING"' EXIT

cp -R "$APP" "$STAGING/ClaudexUsage.app"
ln -s /Applications "$STAGING/Applications"    # 드래그해서 설치할 수 있게

rm -f "$DMG"
hdiutil create -volname "ClaudexUsage $VERSION" -srcfolder "$STAGING" \
    -ov -format UDZO -quiet "$DMG"

echo "생성됨: $DMG"
echo "크기: $(ls -lh "$DMG" | awk '{print $5}')"
