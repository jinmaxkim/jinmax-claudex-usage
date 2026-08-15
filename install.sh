#!/bin/bash
# 빌드한 ClaudexUsage.app을 응용 프로그램 폴더에 설치한다.
set -e

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILT_APP="$SRC_DIR/.build/ClaudexUsage.app"

"$SRC_DIR/build.sh"

if [ -w "/Applications" ]; then
    APP="/Applications/ClaudexUsage.app"
else
    APP="$HOME/Applications/ClaudexUsage.app"
fi

echo "앱 설치: $APP"
pkill -x ClaudexUsage 2>/dev/null || true
mkdir -p "$(dirname "$APP")"
rm -rf "$APP"
cp -R "$BUILT_APP" "$APP"

echo "완료: $APP"
echo "실행: open -a \"$APP\""
