#!/bin/bash
# Rebuilds AppIcon.icns from the SVGs. Only needed after changing the icon: the .icns is committed.
# Needs node and Google Chrome (used headless to render the SVG filters faithfully).
set -euo pipefail
cd "$(dirname "$0")"
CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
node make-svg.mjs
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
render() { # svg → 1024 px PNG with a transparent background
  printf '<html><body style="margin:0;background:transparent"><img src="file://%s" width="1024" height="1024"></body></html>' "$PWD/$1" > "$WORK/page.html"
  "$CHROME" --headless=new --disable-gpu --hide-scrollbars --user-data-dir="$WORK/profile" --allow-file-access-from-files \
    --default-background-color=00000000 --force-device-scale-factor=1 --window-size=1024,1024 \
    --screenshot="$2" "file://$WORK/page.html" >/dev/null 2>&1
}
render AppIcon.svg "$WORK/full.png"
render AppIcon-small.svg "$WORK/small.png"
SET="$WORK/AppIcon.iconset"; mkdir -p "$SET"
# name → pixel size → which artwork (the small one up to 64 px)
for spec in 16x16:16:small 16x16@2x:32:small 32x32:32:small 32x32@2x:64:small 128x128:128:full 128x128@2x:256:full \
            256x256:256:full 256x256@2x:512:full 512x512:512:full 512x512@2x:1024:full; do
  IFS=: read -r name px art <<< "$spec"
  sips -z "$px" "$px" "$WORK/$art.png" --out "$SET/icon_$name.png" >/dev/null
done
iconutil -c icns "$SET" -o AppIcon.icns
cp "$WORK/full.png" AppIcon-1024.png
echo "Built $(pwd)/AppIcon.icns"
