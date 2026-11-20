#!/bin/bash
# 배포 파일 만들기: ./tools/release.sh 0.1.0 [빌드번호]
# -> dist/MacSnow-<버전>.dmg, dist/MacSnow-<버전>.zip, dist/SHA256SUMS.txt
#    (SPARKLE_PRIVATE_ED_KEY가 있으면 dist/appcast.xml도 함께 생성)
# 애드혹 서명(개발자 ID 없음, 공증 안 함).
set -euo pipefail
cd "$(dirname "$0")/.."
VER="${1:?버전을 주세요 (예: 0.1.0)}"
BUILD="${2:-1}"
./build.sh
APP=build/MacSnow.app
SPARKLE_DIR=build/deps/sparkle
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VER" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$APP/Contents/Info.plist"
if [ -n "${SPARKLE_PUBLIC_ED_KEY:-}" ]; then
  plutil -replace SUPublicEDKey -string "$SPARKLE_PUBLIC_ED_KEY" "$APP/Contents/Info.plist"
fi
# 앱 아이콘이 번들에 들어갔는지 확인
[ "$(/usr/libexec/PlistBuddy -c "Print :CFBundleIconFile" "$APP/Contents/Info.plist")" = AppIcon ]
cmp -s Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns" || { echo "AppIcon.icns 누락" >&2; exit 1; }
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
codesign --verify --deep --strict "$APP"

rm -rf dist && mkdir -p dist/dmg
ZIP="dist/MacSnow-$VER.zip"
DMG="dist/MacSnow-$VER.dmg"
ditto -c -k --keepParent "$APP" "$ZIP"
ditto "$APP" "dist/dmg/MacSnow.app"
ln -s /Applications dist/dmg/Applications
hdiutil create -volname "MacSnow $VER" -srcfolder dist/dmg -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
rm -rf dist/dmg
(cd dist && shasum -a 256 "MacSnow-$VER.dmg" "MacSnow-$VER.zip" > SHA256SUMS.txt && cat SHA256SUMS.txt)

if [ -n "${SPARKLE_PRIVATE_ED_KEY:-}" ]; then
  MIN_OS="$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" "$APP/Contents/Info.plist")"
  ZIP_LEN="$(stat -f%z "$ZIP")"
  PUB_DATE="$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")"
  ED_SIG="$(printf '%s' "$SPARKLE_PRIVATE_ED_KEY" | "$SPARKLE_DIR/bin/sign_update" --ed-key-file - -p "$ZIP")"
  cat > dist/appcast.xml <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>MacSnow</title>
    <link>https://github.com/ColdTbrew/mac-snow</link>
    <description>MacSnow updates</description>
    <language>en</language>
    <item>
      <title>MacSnow $VER</title>
      <link>https://github.com/ColdTbrew/mac-snow/releases/tag/v$VER</link>
      <pubDate>$PUB_DATE</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VER</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MIN_OS</sparkle:minimumSystemVersion>
      <enclosure
        url="https://github.com/ColdTbrew/mac-snow/releases/download/v$VER/MacSnow-$VER.zip"
        sparkle:edSignature="$ED_SIG"
        length="$ZIP_LEN"
        type="application/octet-stream" />
    </item>
  </channel>
</rss>
EOF
  echo "generated dist/appcast.xml"
else
  echo "note: SPARKLE_PRIVATE_ED_KEY is not set; skipping dist/appcast.xml generation."
fi
