#!/bin/bash
# Draws site/preview.png, the download page's screenshot: Snapkeep's preview window with its
# sample drawings, over a made-up app window (mock-window.html, rendered by headless Chrome),
# so nothing real is in it. The sample drawings sit at fixed fractions of the image, and the
# mock is laid out to fit them.
# Usage: scripts/site-screenshot/make.sh   (after ./build.sh build; needs Google Chrome)
set -euo pipefail
cd "$(dirname "$0")/../.."
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

"$CHROME" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=2 --window-size=900,560 \
    --screenshot="$WORK/mock.png" "file://$PWD/scripts/site-screenshot/mock-window.html" >/dev/null 2>&1
sips -s dpiWidth 144 -s dpiHeight 144 "$WORK/mock.png" >/dev/null # Retina, so it shows at 900×560 points
build/Snapkeep.app/Contents/MacOS/Snapkeep --render-preview "$WORK/mock.png" "$WORK"
cp "$WORK/window-drawn.png" site/preview.png
echo "Drew site/preview.png"
