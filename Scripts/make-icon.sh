#!/bin/bash
#
# Builds the application icon from Sources/uDeck/Support/uDeck.icon.
#
# The icon is an Icon Composer document — a JSON file and two SVGs — and macOS
# draws the glass itself: the tile, its thickness, the lit edge, the shadow under
# the mark, and a different version of all of it for each system appearance. The
# document is authored here rather than in Icon Composer's window, so the icon
# stays reviewable text in the repository; `Scripts/icon/draw-mark.swift` writes
# the two shapes from the geometry, and `actool` turns the document into what a
# bundle needs.
#
# Two things come out and both are committed, so an ordinary build needs neither
# Xcode nor this script:
#
#   Assets.car   what macOS 26 and later read, where the glass is still a
#                material rather than a picture of one
#   uDeck.icns   a flat rendering of the same document, for earlier systems
#
# Run this after changing the mark or the colour, and commit what it produces.

set -euo pipefail
cd "$(dirname "$0")/.."

DOC="Sources/uDeck/Support/uDeck.icon"
SUPPORT="Sources/uDeck/Support"

if ! xcrun --find actool >/dev/null 2>&1; then
    echo "actool not found — this needs Xcode, not just the command line tools." >&2
    exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> Drawing the mark"
swiftc -O -o "$WORK/draw-mark" Scripts/icon/draw-mark.swift
"$WORK/draw-mark" "$DOC/Assets"

# actool matches --app-icon against the document's own name, so the document has
# to be called uDeck.icon — which it is — and it wants an absolute path to it.
echo "==> Compiling $DOC"
mkdir -p "$WORK/out"
# The deployment target is the format's, not the application's: below 26 actool
# accepts the document and silently compiles nothing at all. uDeck itself still
# runs on macOS 14 and falls back to the .icns there.
xcrun actool "$PWD/$DOC" \
    --compile "$WORK/out" \
    --platform macosx \
    --minimum-deployment-target 26.0 \
    --app-icon uDeck \
    --output-partial-info-plist "$WORK/partial.plist" \
    --output-format human-readable-text >/dev/null

for produced in Assets.car uDeck.icns; do
    if [ ! -f "$WORK/out/$produced" ]; then
        echo "actool produced no $produced — the document or its name is wrong." >&2
        exit 1
    fi
    cp "$WORK/out/$produced" "$SUPPORT/$produced"
    echo "==> $SUPPORT/$produced ($(wc -c < "$SUPPORT/$produced" | tr -d ' ') bytes)"
done
