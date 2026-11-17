#!/bin/bash
# Builds "F65 Lighting.app" next to this script. Needs only the Xcode Command Line Tools (swiftc).
set -euo pipefail
cd "$(dirname "$0")"

APP="F65 Lighting.app"
ARCH="$(uname -m)"
CONFIG="${1:-release}"   # ./build.sh debug  → unoptimised build

FLAGS=(-target "$ARCH-apple-macos13.0")
if [ "$CONFIG" = "debug" ]; then FLAGS+=(-Onone -g); else FLAGS+=(-O); fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "Compiling ($CONFIG, $ARCH)…"
swiftc "${FLAGS[@]}" -module-name F65Lighting -o "$APP/Contents/MacOS/F65Lighting" Sources/*.swift

cp Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "Signing (ad-hoc)…"
codesign -s - --force --deep "$APP"

echo "Built $(pwd)/$APP"
echo "Run it with:  open \"$(pwd)/$APP\""
