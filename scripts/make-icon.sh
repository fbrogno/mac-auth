#!/bin/zsh
# Draws the icon (scripts/make-icon.swift) and packs Resources/AppIcon.icns with all sizes up to 1024.
# Also leaves build/icon-1024.png for a look at the result.
set -euo pipefail
cd "$(dirname "$0")/.."

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p build
swift scripts/make-icon.swift "$tmp/icon-1024.png"
cp "$tmp/icon-1024.png" build/icon-1024.png

iconset="$tmp/AppIcon.iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
  sips -z $size $size "$tmp/icon-1024.png" --out "$iconset/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z $double $double "$tmp/icon-1024.png" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o Resources/AppIcon.icns
echo "Resources/AppIcon.icns aktualisiert"
