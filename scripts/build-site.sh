#!/bin/bash
# Builds the download page from site/ into a folder, filled in with the latest GitHub release:
# scripts/build-site.sh build/site
set -euo pipefail
cd "$(dirname "$0")/.."

OUT=${1:-build/site}
REPO=stanimir93/snapkeep

release=$(gh release view --repo "$REPO" --json tagName,publishedAt,url,assets)
version=$(jq -r '.tagName | ltrimstr("v")' <<<"$release")
date=$(jq -r '.publishedAt | fromdateiso8601 | (strftime("%d") | tonumber | tostring) + " " + strftime("%B %Y")' <<<"$release")
notes=$(jq -r .url <<<"$release")
download=$(jq -r '[.assets[] | select(.name | endswith(".zip"))][0].url // empty' <<<"$release")
size=$(jq -r '[.assets[] | select(.name | endswith(".zip"))][0].size // 0 | . / 1048576 * 10 | round / 10 | tostring + " MB"' <<<"$release")
if [[ -z "$download" ]]; then
    echo "The latest release ($version) has no .zip asset." >&2
    exit 1
fi

rm -rf "$OUT"
mkdir -p "$OUT"
sed -e "s|{{VERSION}}|$version|g" \
    -e "s|{{DATE}}|$date|g" \
    -e "s|{{SIZE}}|$size|g" \
    -e "s|{{DOWNLOAD_URL}}|$download|g" \
    -e "s|{{NOTES_URL}}|$notes|g" \
    site/index.html >"$OUT/index.html"
cp docs/icon.png "$OUT/icon.png"
echo "Built $OUT for Snapkeep $version"
