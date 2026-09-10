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

# The icon. Committed rather than generated here, so an ordinary build needs
# neither a renderer nor a toolchain step; `Scripts/make-icon.sh` rebuilds it
# from `Scripts/icon/render-icon.swift` when the icon itself changes.
if [ -f Sources/uDeck/Support/uDeck.icns ]; then
    cp Sources/uDeck/Support/uDeck.icns "$APP/Contents/Resources/uDeck.icns"
fi

# Any SwiftPM resource bundles that exist alongside the binary belong inside.
for bundle in .build/release/*.bundle; do
    [ -e "$bundle" ] || continue
    cp -R "$bundle" "$APP/Contents/Resources/"
done

# Frameworks the binary links against have to travel with it. Sparkle carries
# its own helpers — Autoupdate and the XPC services that install an update while
# the application it is replacing is shutting down — so it is copied whole
# rather than reduced to a dylib.
if [ -d .build/release/Sparkle.framework ]; then
    echo "==> Embedding Sparkle.framework"
    mkdir -p "$APP/Contents/Frameworks"
    cp -R .build/release/Sparkle.framework "$APP/Contents/Frameworks/"
fi

echo "==> Signing with identity: $IDENTITY"

# See the comment in the file itself. Scoped to ad-hoc so that a Developer ID
# build keeps library validation, which is the point of the hardened runtime.
SIGN_FLAGS=(--force --options runtime --sign "$IDENTITY")
if [ "$IDENTITY" = "-" ]; then
    SIGN_FLAGS+=(--entitlements Scripts/adhoc.entitlements)
fi
# The hardened runtime is enabled now rather than later: it is what
# notarisation will require, and finding out that something in the app is
# incompatible with it is much cheaper today than on the day of a release.
#
# Inside out: a nested framework has to be signed before the bundle that
# contains it, because signing the outer one seals a hash of the inner. `--deep`
# is documented as unsuitable for exactly this and is kept only for whatever it
# still reaches that is not named here.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
if [ -d "$SPARKLE" ]; then
    # Sparkle arrives signed by whoever built it, and a nested signature from
    # another team is not usable inside an ad-hoc signed application: dyld
    # refuses the framework with "different Team IDs" and the app does not
    # launch at all. Everything is therefore re-signed with this build's
    # identity, innermost first — the XPC services and the updater helper, then
    # the version directory, then the framework — because signing a bundle
    # seals a hash of what is inside it, and anything signed afterwards
    # invalidates that seal.
    for helper in "$SPARKLE/Versions/B/XPCServices/"*.xpc "$SPARKLE/Versions/B/Updater.app"; do
        [ -e "$helper" ] || continue
        codesign "${SIGN_FLAGS[@]}" "$helper"
    done
    codesign "${SIGN_FLAGS[@]}" "$SPARKLE/Versions/B"
    codesign "${SIGN_FLAGS[@]}" "$SPARKLE"
fi
# Not `--deep`: it would re-sign the framework's contents in its own order and
# undo the inside-out pass above. Apple documents `--deep` as unsuitable for
# signing an application for distribution, and this is why.
codesign "${SIGN_FLAGS[@]}" "$APP"
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
