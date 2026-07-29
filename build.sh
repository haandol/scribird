#!/bin/bash
#
# Scribird.app 번들을 만든다.
#
# 맨몸 실행 파일로는 마이크·화면녹음 권한(TCC)을 받을 수 없다. macOS는 권한을
# 번들 식별자에 묶어 관리하므로 반드시 .app 구조로 감싸고 코드서명까지 해야
# 시스템 설정에 항목이 나타난다.
set -euo pipefail

cd "$(dirname "$0")"

CONFIG="${1:-release}"
APP_NAME="Scribird"
APP_BUNDLE="build/${APP_NAME}.app"
ICON_SOURCE="Resources/AppIcon.png"
ICONSET="build/AppIcon.iconset"
ICON_FILE="build/AppIcon.icns"

echo "==> 빌드 (${CONFIG})"
swift build -c "$CONFIG"
BINARY="$(swift build -c "$CONFIG" --show-bin-path)/${APP_NAME}"

echo "==> 번들 구성"
rm -rf "$APP_BUNDLE"
mkdir -p "${APP_BUNDLE}/Contents/MacOS" "${APP_BUNDLE}/Contents/Resources"
cp "$BINARY" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
cp Resources/Info.plist "${APP_BUNDLE}/Contents/Info.plist"

echo "==> 앱 아이콘 생성"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
for SIZE in 16 32 128 256 512; do
	DOUBLE_SIZE=$((SIZE * 2))
	sips -s format png --resampleHeightWidth "$SIZE" "$SIZE" \
		"$ICON_SOURCE" --out "${ICONSET}/icon_${SIZE}x${SIZE}.png" >/dev/null
	sips -s format png --resampleHeightWidth "$DOUBLE_SIZE" "$DOUBLE_SIZE" \
		"$ICON_SOURCE" --out "${ICONSET}/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$ICON_FILE"
cp "$ICON_FILE" "${APP_BUNDLE}/Contents/Resources/AppIcon.icns"

echo "==> 코드서명"
# 애드혹 서명(-)으로도 TCC가 동작한다. 다른 사람에게 배포하려면
# Developer ID 인증서로 바꾸고 공증(notarize)까지 거쳐야 한다.
codesign --force --sign - \
	--entitlements Resources/Scribird.entitlements \
	--options runtime \
	"$APP_BUNDLE"

codesign --verify --verbose "$APP_BUNDLE"

echo
echo "완료: ${APP_BUNDLE}"
echo "실행: open ${APP_BUNDLE}"
