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
# 실제 인증서로 서명해야 TCC 권한 프롬프트가 뜬다.
#
# 애드혹 서명(-)은 TeamIdentifier가 비어 안정적인 앱 신원이 없다. 마이크처럼
# AVFoundation이 명시적으로 요청하는 권한은 그래도 동작하지만, Core Audio
# 프로세스 탭(kTCCServiceAudioCapture)은 프롬프트가 아예 뜨지 않고 조용히
# 무음만 흘려보냈다. 그래서 키체인의 서명 인증서를 우선 사용한다.
#
# SIGN_IDENTITY 환경변수로 원하는 인증서를 지정할 수 있다.
if [[ -z "${SIGN_IDENTITY:-}" ]]; then
	SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
		| grep -oE '"(Developer ID Application|Apple Development)[^"]*"' \
		| head -1 | tr -d '"')"
fi

if [[ -n "$SIGN_IDENTITY" ]]; then
	echo "    인증서: ${SIGN_IDENTITY}"
else
	echo "    경고: 서명 인증서가 없어 애드혹으로 서명합니다." >&2
	echo "    시스템 오디오 캡처 권한 프롬프트가 뜨지 않을 수 있습니다." >&2
	SIGN_IDENTITY="-"
fi

codesign --force --sign "$SIGN_IDENTITY" \
	--entitlements Resources/Scribird.entitlements \
	--options runtime \
	--timestamp=none \
	"$APP_BUNDLE"

codesign --verify --verbose "$APP_BUNDLE"

echo
echo "완료: ${APP_BUNDLE}"
echo "실행: open ${APP_BUNDLE}"
