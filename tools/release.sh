#!/bin/bash
# 배포 파일 만들기: ./tools/release.sh 0.1.0 [빌드번호]
# -> dist/MacSnow-<버전>.dmg, dist/MacSnow-<버전>.zip, dist/SHA256SUMS.txt
# 애드혹 서명(개발자 ID 없음, 공증 안 함).
set -euo pipefail
cd "$(dirname "$0")/.."
VER="${1:?버전을 주세요 (예: 0.1.0)}"
BUILD="${2:-1}"
./build.sh
APP=build/MacSnow.app
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VER" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$APP/Contents/Info.plist"
# 앱 아이콘이 번들에 들어갔는지 확인
[ "$(/usr/libexec/PlistBuddy -c "Print :CFBundleIconFile" "$APP/Contents/Info.plist")" = AppIcon ]
cmp -s Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns" || { echo "AppIcon.icns 누락" >&2; exit 1; }
codesign -s - --force "$APP"
codesign --verify --strict "$APP"
rm -rf dist && mkdir -p dist/dmg
ditto -c -k --keepParent "$APP" "dist/MacSnow-$VER.zip"
cp -R "$APP" dist/dmg/
ln -s /Applications dist/dmg/Applications
hdiutil create -volname "MacSnow $VER" -srcfolder dist/dmg -fs HFS+ -format UDZO -ov "dist/MacSnow-$VER.dmg" >/dev/null
rm -rf dist/dmg
(cd dist && shasum -a 256 "MacSnow-$VER.dmg" "MacSnow-$VER.zip" > SHA256SUMS.txt && cat SHA256SUMS.txt)
