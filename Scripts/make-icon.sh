#!/usr/bin/env bash
# Rebuilds Resources/AppIcon.icns from Resources/AppIcon.svg. Run by hand after editing the SVG; commit both.
set -euo pipefail
cd "$(dirname "$0")/.."

SRC=Resources/AppIcon.svg
OUT=Resources/AppIcon.icns
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
ICONSET="$WORK/AppIcon.iconset"
mkdir "$ICONSET"

# Each size is rasterized from the vector source rather than downscaled from 1024, so small sizes stay sharp.
render() {
  sips -s format png -z "$1" "$1" "$SRC" --out "$ICONSET/$2" >/dev/null \
    || { echo "error: sips could not rasterize $SRC" >&2; exit 1; }
}

for size in 16 32 128 256 512; do
  render "$size" "icon_${size}x${size}.png"
  render $((size * 2)) "icon_${size}x${size}@2x.png"
done

iconutil -c icns "$ICONSET" -o "$OUT"
echo "Wrote $OUT"
