#!/bin/zsh
# Renders Resources/AppIcon.png and Resources/AppIcon.icns from the root
# logo.svg. Checked-in so `make app` does not need librsvg; re-run this after
# changing the mark. Usage: scripts/make-app-icon.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SVG="$ROOT/logo.svg"
OUT="$ROOT/Resources"

[[ -f "$SVG" ]] || { echo "make-app-icon: missing $SVG" >&2; exit 1 }

if ! command -v rsvg-convert >/dev/null; then
  echo "make-app-icon: rsvg-convert not found (brew install librsvg)" >&2
  exit 1
fi

mkdir -p "$OUT"
rsvg-convert -w 1024 -h 1024 "$SVG" -o "$OUT/AppIcon.png"

ICONSET="$(mktemp -d "${TMPDIR:-/tmp}/directa-iconset.XXXXXX")"
trap 'rm -rf "$ICONSET"' EXIT
mkdir "$ICONSET/AppIcon.iconset"

# iconutil names: the 1x file and the @2x file for each slot. Render each size
# from the SVG rather than scaling a raster, so the 16px slot is not a
# downsampled 1024.
for size name in \
  16 icon_16x16 \
  32 'icon_16x16@2x' \
  32 icon_32x32 \
  64 'icon_32x32@2x' \
  128 icon_128x128 \
  256 'icon_128x128@2x' \
  256 icon_256x256 \
  512 'icon_256x256@2x' \
  512 icon_512x512 \
  1024 'icon_512x512@2x'
do
  rsvg-convert -w "$size" -h "$size" "$SVG" -o "$ICONSET/AppIcon.iconset/${name}.png"
done

iconutil -c icns -o "$OUT/AppIcon.icns" "$ICONSET/AppIcon.iconset"
echo "wrote $OUT/AppIcon.png and $OUT/AppIcon.icns"
