#!/bin/bash
# Build support/AppIcon.icns from assets/icon/icon-1024.png.
# Re-render the PNG first if icon.svg changed:
#   node assets/icon/render.mjs
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SRC="$HERE/icon-1024.png"
SET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$SET"
for size in 16 32 128 256 512; do
    sips -z $size $size "$SRC" --out "$SET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z $double $double "$SRC" --out "$SET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o "$ROOT/support/AppIcon.icns"
echo "$ROOT/support/AppIcon.icns"
