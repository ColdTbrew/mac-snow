#!/bin/bash
# MacSnow.app 빌드 (Xcode 없이 Command Line Tools만으로). 사용법: ./build.sh [--run]
set -euo pipefail
cd "$(dirname "$0")"
APP=build/MacSnow.app
MIN=13.0
SPARKLE_DIR=build/deps/sparkle
./tools/fetch_sparkle.sh
rm -rf "$APP" build/obj
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks" build/obj
# Apple Silicon + Intel 유니버설 바이너리
for ARCH in arm64 x86_64; do
  swiftc -O -swift-version 5 -target "$ARCH-apple-macos$MIN" \
    -F "$SPARKLE_DIR" \
    -framework AppKit -framework QuartzCore -framework ApplicationServices -framework IOKit -framework ServiceManagement -framework Sparkle \
    -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
    Sources/*.swift -o "build/obj/MacSnow-$ARCH"
done
lipo -create build/obj/MacSnow-arm64 build/obj/MacSnow-x86_64 -output "$APP/Contents/MacOS/MacSnow"
cp Info.plist "$APP/Contents/Info.plist"
if [ -n "${SPARKLE_PUBLIC_ED_KEY:-}" ]; then
  plutil -replace SUPublicEDKey -string "$SPARKLE_PUBLIC_ED_KEY" "$APP/Contents/Info.plist"
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"   # 원본: Resources/AppIcon.svg (tools/make_icns.py)
ditto "$SPARKLE_DIR/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
# Sparkle 중첩 번들·XPC·실행 파일부터 안쪽에서 바깥쪽으로 애드혹 서명
SPARKLE_FW="$APP/Contents/Frameworks/Sparkle.framework"
SPARKLE_VER="$SPARKLE_FW/Versions/$(readlink "$SPARKLE_FW/Versions/Current")"
for XPC in "$SPARKLE_VER"/XPCServices/*.xpc; do
  [ -d "$XPC" ] && codesign -s - --force "$XPC"
done
[ -f "$SPARKLE_VER/Autoupdate" ] && codesign -s - --force "$SPARKLE_VER/Autoupdate"
[ -d "$SPARKLE_VER/Updater.app" ] && codesign -s - --force "$SPARKLE_VER/Updater.app"
codesign -s - --force "$SPARKLE_FW"
codesign -s - --force "$APP"
echo "built $APP"
if [[ "${1:-}" == "--run" ]]; then
  pkill -x MacSnow 2>/dev/null || true
  open "$APP"
fi
