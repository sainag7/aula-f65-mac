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
codesign -s - --force --deep "$STAGE"
codesign --verify --deep --strict "$STAGE"
rm -rf "$APP"
mv "$STAGE" "$APP"
echo "Built $(pwd)/$APP"
