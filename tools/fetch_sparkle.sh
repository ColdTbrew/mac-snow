#!/bin/bash
# Sparkle 2 바이너리 릴리스를 내려받아 SHA-256을 검증하고 build/deps/sparkle에 캐시해요.
set -euo pipefail
cd "$(dirname "$0")/.."

SPARKLE_VERSION="2.10.1"
SPARKLE_SHA256="1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27"
SPARKLE_URL="https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/Sparkle-${SPARKLE_VERSION}.tar.xz"
DEST="build/deps/sparkle"
MARKER="$DEST/.sparkle-version"
EXPECTED_MARKER="${SPARKLE_VERSION} ${SPARKLE_SHA256}"

if [ -d "$DEST/Sparkle.framework" ] && [ -f "$MARKER" ] && [ "$(cat "$MARKER")" = "$EXPECTED_MARKER" ]; then
  exit 0
fi

mkdir -p build/deps
TMP_DIR="$(mktemp -d build/deps/.sparkle-tmp.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

ARCHIVE="$TMP_DIR/Sparkle-${SPARKLE_VERSION}.tar.xz"
echo "Fetching Sparkle ${SPARKLE_VERSION}..."
curl -fsSL --retry 3 --retry-delay 2 "$SPARKLE_URL" -o "$ARCHIVE"

ACTUAL_SHA256="$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
if [ "$ACTUAL_SHA256" != "$SPARKLE_SHA256" ]; then
  echo "Sparkle SHA-256 mismatch!" >&2
  echo "  expected: $SPARKLE_SHA256" >&2
  echo "  actual:   $ACTUAL_SHA256" >&2
  exit 1
fi

STAGE="$TMP_DIR/extract"
mkdir -p "$STAGE"
tar -xJf "$ARCHIVE" -C "$STAGE"

if [ ! -d "$STAGE/Sparkle.framework" ]; then
  echo "Sparkle.framework not found in archive" >&2
  exit 1
fi

printf '%s\n' "$EXPECTED_MARKER" > "$STAGE/.sparkle-version"
rm -rf "$DEST"
mv "$STAGE" "$DEST"
echo "Cached Sparkle ${SPARKLE_VERSION} at $DEST"
