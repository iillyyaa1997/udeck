#!/bin/bash
#
# Assembles uDeck.app from a release build.
#
# SwiftPM does not produce application bundles, so this does it by hand — which
# is a handful of directories and a plist, and needs no Xcode project. The
# binary already carries the Info.plist in its __TEXT section, so a development
# build runs perfectly well without any of this; the bundle exists for handing a
# copy to somebody else.
#
# Usage:  Scripts/make-app.sh [--sign IDENTITY] [--dmg]
#
# Without --sign the bundle is ad-hoc signed. That is enough for the machine it
# was built on and not enough for anyone else: macOS will refuse a downloaded
# ad-hoc copy on first launch, and the person opening it has to right-click and
# choose Open. Notarisation needs a paid Developer ID, and when there is one,
# `--sign "Developer ID Application: …"` plus `xcrun notarytool` is the whole
# difference — nothing about the build changes.

set -euo pipefail

cd "$(dirname "$0")/.."

IDENTITY="-"
MAKE_DMG=0
while [ $# -gt 0 ]; do
    case "$1" in
        --sign) IDENTITY="$2"; shift 2 ;;
        --dmg) MAKE_DMG=1; shift ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

APP="dist/uDeck.app"
PLIST="Sources/uDeck/Support/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"

echo "==> Building uDeck $VERSION for release"
swift build -c release

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/uDeck "$APP/Contents/MacOS/uDeck"
cp "$PLIST" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Any SwiftPM resource bundles that exist alongside the binary belong inside.
for bundle in .build/release/*.bundle; do
    [ -e "$bundle" ] || continue
    cp -R "$bundle" "$APP/Contents/Resources/"
done

echo "==> Signing with identity: $IDENTITY"
# The hardened runtime is enabled now rather than later: it is what
# notarisation will require, and finding out that something in the app is
# incompatible with it is much cheaper today than on the day of a release.
codesign --force --deep --options runtime --sign "$IDENTITY" "$APP"
codesign --verify --verbose=2 "$APP"

if [ "$IDENTITY" = "-" ]; then
    cat <<'WARNING'

    This build is ad-hoc signed. On any machine other than this one, macOS will
    refuse to open it on the first attempt; right-click the app and choose Open
    to get the dialog that lets you through. For a build you can hand out
    without that step, sign with a Developer ID and notarise it.

WARNING
fi

if [ "$MAKE_DMG" = "1" ]; then
    echo "==> Making dist/uDeck-$VERSION.dmg"
    rm -f "dist/uDeck-$VERSION.dmg"
    hdiutil create -volname "uDeck $VERSION" -srcfolder "$APP" \
        -ov -format UDZO "dist/uDeck-$VERSION.dmg"
fi

echo "==> Done: $APP"
