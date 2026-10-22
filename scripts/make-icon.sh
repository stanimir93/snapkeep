#!/bin/bash
# Draws the app icon and packs it into an .icns file: scripts/make-icon.sh Resources/AppIcon.icns
set -euo pipefail
cd "$(dirname "$0")/.."

OUT=${1:-Resources/AppIcon.icns}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

swift scripts/draw-icon.swift "$WORK/icon-1024.png"
ICONSET="$WORK/AppIcon.iconset"
mkdir "$ICONSET"
for size in 16 32 128 256 512; do
    sips -z $size $size "$WORK/icon-1024.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z $double $double "$WORK/icon-1024.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$OUT"
echo "Wrote $OUT"
