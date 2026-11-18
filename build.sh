#!/bin/bash
# MacSnow.app 빌드 (Xcode 없이 Command Line Tools만으로). 사용법: ./build.sh [--run]
set -euo pipefail
cd "$(dirname "$0")"
APP=build/MacSnow.app
MIN=13.0
rm -rf "$APP" build/obj
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/obj
# Apple Silicon + Intel 유니버설 바이너리
for ARCH in arm64 x86_64; do
  swiftc -O -swift-version 5 -target "$ARCH-apple-macos$MIN" \
    -framework AppKit -framework QuartzCore -framework ApplicationServices -framework IOKit -framework ServiceManagement \
    Sources/*.swift -o "build/obj/MacSnow-$ARCH"
done
lipo -create build/obj/MacSnow-arm64 build/obj/MacSnow-x86_64 -output "$APP/Contents/MacOS/MacSnow"
cp Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"   # 원본: Resources/AppIcon.svg (tools/make_icns.py)
codesign -s - --force "$APP"
echo "built $APP"
if [[ "${1:-}" == "--run" ]]; then
  pkill -x MacSnow 2>/dev/null || true
  open "$APP"
fi
