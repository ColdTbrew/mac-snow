#!/bin/bash
# DMG 창 레이아웃(배경·아이콘 위치)을 쓰는 dmgbuild를 build/deps/dmgbuild 가상환경에 설치해요.
# Finder를 AppleScript로 조작하지 않고 .DS_Store를 직접 써서 CI(맥 러너)에서도 그대로 돌아요.
set -euo pipefail
cd "$(dirname "$0")/.."
DMGBUILD_VERSION="1.6.5"            # 1.6.x: 맥 기본 python3(3.9)에서 동작
VENV="build/deps/dmgbuild"
if [ -x "$VENV/bin/dmgbuild" ] && [ "$(cat "$VENV/.version" 2>/dev/null)" = "$DMGBUILD_VERSION" ]; then
  exit 0
fi
rm -rf "$VENV"
mkdir -p build/deps
/usr/bin/python3 -m venv "$VENV"
"$VENV/bin/python" -m pip install --quiet --disable-pip-version-check "dmgbuild==$DMGBUILD_VERSION"
echo "$DMGBUILD_VERSION" > "$VENV/.version"
echo "Installed dmgbuild $DMGBUILD_VERSION at $VENV"
