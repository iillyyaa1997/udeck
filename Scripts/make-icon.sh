#!/bin/bash
#
# Builds Sources/uDeck/Support/uDeck.icns from Scripts/icon/render-icon.swift.
#
# The .icns is committed, so an ordinary build needs none of this. Run it after
# changing the icon's source, and commit what it produces.

set -euo pipefail
cd "$(dirname "$0")/.."

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
ICONSET="$WORK/uDeck.iconset"
mkdir -p "$ICONSET"

echo "==> Rendering"
swiftc -O -o "$WORK/render" Scripts/icon/render-icon.swift
"$WORK/render" "$WORK"

# iconutil wants exactly these names; anything else in the folder is an error.
cp "$WORK/icon_16.png"   "$ICONSET/icon_16x16.png"
cp "$WORK/icon_32.png"   "$ICONSET/icon_16x16@2x.png"
cp "$WORK/icon_32.png"   "$ICONSET/icon_32x32.png"
cp "$WORK/icon_64.png"   "$ICONSET/icon_32x32@2x.png"
cp "$WORK/icon_128.png"  "$ICONSET/icon_128x128.png"
cp "$WORK/icon_256.png"  "$ICONSET/icon_128x128@2x.png"
cp "$WORK/icon_256.png"  "$ICONSET/icon_256x256.png"
cp "$WORK/icon_512.png"  "$ICONSET/icon_256x256@2x.png"
cp "$WORK/icon_512.png"  "$ICONSET/icon_512x512.png"
cp "$WORK/icon_1024.png" "$ICONSET/icon_512x512@2x.png"

echo "==> Packing"
iconutil --convert icns --output Sources/uDeck/Support/uDeck.icns "$ICONSET"
echo "==> Done: Sources/uDeck/Support/uDeck.icns ($(wc -c < Sources/uDeck/Support/uDeck.icns) bytes)"
