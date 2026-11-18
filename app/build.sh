#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
APP="F65 Lighting.app"
CONFIG="${1:-release}"
case "$CONFIG" in debug|release) ;; *) echo 'Use debug or release' >&2; exit 2;; esac
swift build -c "$CONFIG" --product F65Lighting
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
# Assemble only after compilation succeeds; never delete a working bundle for a failed build.
STAGE=".build/F65 Lighting.staging.app"
rm -rf "$STAGE"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
cp "$BIN_DIR/F65Lighting" "$STAGE/Contents/MacOS/F65Lighting"
cp Info.plist "$STAGE/Contents/Info.plist"
printf 'APPL????' > "$STAGE/Contents/PkgInfo"
if [ -d Resources/keyboard ]; then cp -R Resources/keyboard "$STAGE/Contents/Resources/keyboard"; fi
cp Resources/icon/AppIcon.icns "$STAGE/Contents/Resources/AppIcon.icns"   # rebuild with Resources/icon/build-icns.sh
# Sign with a stable identity so macOS keeps the Input Monitoring permission across rebuilds
# (ad-hoc signatures change every build). Override with F65_SIGN_ID; falls back to ad-hoc.
SIGN_ID="${F65_SIGN_ID:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development|F65 Lighting Dev/ {print $2; exit}')}"
codesign -s "${SIGN_ID:--}" --force --deep "$STAGE"
echo "Signed with: ${SIGN_ID:-ad-hoc}"
codesign --verify --deep --strict "$STAGE"
rm -rf "$APP"
mv "$STAGE" "$APP"
echo "Built $(pwd)/$APP"
