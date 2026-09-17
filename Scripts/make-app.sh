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
# Usage:  Scripts/make-app.sh [--debug] [--install] [--sign IDENTITY] [--dmg]
#                             [--test-feed URL --test-key PUBLIC_KEY]
#                             [--out DIR] [--version X.Y.Z] [--build N] [--zip]
#
# --debug bundles the debug build instead of the release one, into
# dist/uDeck-debug.app. It exists because a bare `.build/debug/uDeck` is not an
# application as far as macOS is concerned: it has no Resources, so it shows the
# system's generic executable tile wherever an icon is asked for, and the
# embedded Info.plist is all it has to go on. Working against a real bundle
# means the copy being developed behaves like the copy being shipped — same
# icon, same layout, same Sparkle framework beside it — while the released
# application stays installed and untouched. It is also its own application:
# `place.unicorns.udeck.debug`, with no update feed, so it can sit beside the
# release without taking its login item or updating itself into a second copy of
# it.
#
# --test-feed and --test-key build the release configuration against a throwaway
# appcast and public key, which is how the end-to-end lab in `e2e/` tests an
# update without going near the real feed.
#
# The lab also needs three things an ordinary build does not. --out puts the
# bundle somewhere other than dist/, so a test build never lands where the
# copies a person uses are kept. --version and --build set the two version keys
# — the one people read and CFBundleVersion, which is the one Sparkle compares —
# so that two builds of one commit can stand as an update pair. --zip leaves the
# bundle only as a zip: a lab build carries the *release's* bundle identifier,
# so an unpacked copy on this Mac could take the release's login item merely by
# being launched. It is unpacked inside the test machine and nowhere else.
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
INSTALL=0
CONFIG="release"
TEST_FEED=""
TEST_KEY=""
OUT="dist"
SET_VERSION=""
SET_BUILD=""
MAKE_ZIP=0
while [ $# -gt 0 ]; do
    case "$1" in
        --sign) IDENTITY="$2"; shift 2 ;;
        --dmg) MAKE_DMG=1; shift ;;
        --debug) CONFIG="debug"; shift ;;
        --install) INSTALL=1; shift ;;
        --test-feed) TEST_FEED="$2"; shift 2 ;;
        --test-key) TEST_KEY="$2"; shift 2 ;;
        --out) OUT="$2"; shift 2 ;;
        --version) SET_VERSION="$2"; shift 2 ;;
        --build) SET_BUILD="$2"; shift 2 ;;
        --zip) MAKE_ZIP=1; shift ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

if [ -z "$OUT" ]; then
    echo "--out needs a directory" >&2
    exit 2
fi
if [ "$MAKE_ZIP" = "1" ] && { [ "$INSTALL" = "1" ] || [ "$MAKE_DMG" = "1" ]; }; then
    # --zip removes the bundle it made; the other two need it.
    echo "--zip cannot be combined with --install or --dmg" >&2
    exit 2
fi

if [ -n "$TEST_FEED$TEST_KEY" ]; then
    if [ -z "$TEST_FEED" ] || [ -z "$TEST_KEY" ]; then
        echo "--test-feed and --test-key are only useful together" >&2
        exit 2
    fi
    if [ "$CONFIG" = "debug" ]; then
        # A debug build carries no feed at all (see below), so pointing one at a
        # test feed would silently do nothing.
        echo "--test-feed builds the release configuration; drop --debug" >&2
        exit 2
    fi
fi

if [ "$CONFIG" = "debug" ]; then
    APP="$OUT/uDeck-debug.app"
    BUILT="./.build/debug/uDeck"
else
    APP="$OUT/uDeck.app"
    BUILT="./.build/release/uDeck"
fi
PLIST="Sources/uDeck/Support/Info.plist"
VERSION="${SET_VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")}"

echo "==> Building uDeck $VERSION for $CONFIG"
if [ "$CONFIG" = "debug" ]; then
    swift build
else
    swift build -c release
fi

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILT" "$APP/Contents/MacOS/uDeck"
cp "$PLIST" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# The two version keys. CFBundleVersion is the one Sparkle compares when it
# decides whether an update is newer, so an update pair differs in both.
if [ -n "$SET_VERSION" ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $SET_VERSION" "$APP/Contents/Info.plist"
fi
if [ -n "$SET_BUILD" ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $SET_BUILD" "$APP/Contents/Info.plist"
fi

# A debug build is a different application as far as macOS is concerned, and it
# does not update itself.
#
# Both halves were measured in a virtual machine rather than assumed. A second
# copy carrying the *release's* bundle identifier takes over the release's login
# item merely by being launched — one record exists per identifier, and the copy
# that ran last owns it — and switching "Open at Login" off in either copy
# switches it off for both. Sparkle then closes the loop: offered a release
# update, a debug build installs it over itself and becomes a second copy of the
# release identifier again. Hence no feed here.
if [ "$CONFIG" = "debug" ]; then
    BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST")"
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier ${BUNDLE_ID}.debug" "$APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Delete :SUFeedURL" "$APP/Contents/Info.plist" >/dev/null 2>&1 || true
fi

# A lab build is the release pointed at a throwaway feed and signing key, so an
# end-to-end update test never involves the real ones. Both are baked into the
# bundle rather than passed at run time because Sparkle relaunches the
# application to install an update, and an environment override does not survive
# that relaunch. `NSAllowsLocalNetworking` is what lets the feed be plain HTTP on
# the loopback address inside the test machine.
if [ -n "$TEST_FEED" ]; then
    /usr/libexec/PlistBuddy -c "Set :SUFeedURL $TEST_FEED" "$APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :SUPublicEDKey $TEST_KEY" "$APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Delete :NSAppTransportSecurity" "$APP/Contents/Info.plist" >/dev/null 2>&1 || true
    /usr/libexec/PlistBuddy -c "Add :NSAppTransportSecurity dict" "$APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :NSAppTransportSecurity:NSAllowsLocalNetworking bool true" "$APP/Contents/Info.plist"
fi

# The icon, in both of the forms a bundle can carry it: Assets.car is what
# macOS 26 and later read, and where the glass is still a material the system
# draws rather than a picture of one; the .icns is the same icon flattened, for
# earlier systems. Both are committed, so an ordinary build needs neither Xcode
# nor a rendering step; `Scripts/make-icon.sh` rebuilds them from
# `Sources/uDeck/Support/uDeck.icon` when the icon itself changes.
for icon in Assets.car uDeck.icns; do
    [ -f "Sources/uDeck/Support/$icon" ] || continue
    cp "Sources/uDeck/Support/$icon" "$APP/Contents/Resources/$icon"
done

# Any SwiftPM resource bundles that exist alongside the binary belong inside.
for bundle in "$(dirname "$BUILT")"/*.bundle; do
    [ -e "$bundle" ] || continue
    cp -R "$bundle" "$APP/Contents/Resources/"
done

# Frameworks the binary links against have to travel with it. Sparkle carries
# its own helpers — Autoupdate and the XPC services that install an update while
# the application it is replacing is shutting down — so it is copied whole
# rather than reduced to a dylib.
if [ -d "$(dirname "$BUILT")/Sparkle.framework" ]; then
    echo "==> Embedding Sparkle.framework"
    mkdir -p "$APP/Contents/Frameworks"
    cp -R "$(dirname "$BUILT")/Sparkle.framework" "$APP/Contents/Frameworks/"
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

# An application outside one of the Applications folders does not get its icon
# everywhere. Measured: the same ad-hoc signed bundle shows the system's
# placeholder tile in Stage Manager's strip when it is run from a build
# directory, and its own icon when it is run from ~/Applications or
# /Applications — bundle identifier and contents unchanged, only the path. So a
# copy that is going to be used rather than tested belongs in one of them.
if [ "$INSTALL" = "1" ]; then
    DEST="$HOME/Applications/$(basename "$APP")"
    echo "==> Installing to $DEST"
    rm -rf "$DEST"
    mkdir -p "$HOME/Applications"
    # ditto rather than cp -R: it keeps the symlinks and extended attributes a
    # signed bundle is made of, and a copy that loses them will not launch.
    ditto "$APP" "$DEST"
fi

if [ "$MAKE_DMG" = "1" ]; then
    echo "==> Making $OUT/uDeck-$VERSION.dmg"
    rm -f "$OUT/uDeck-$VERSION.dmg"
    hdiutil create -volname "uDeck $VERSION" -srcfolder "$APP" \
        -ov -format UDZO "$OUT/uDeck-$VERSION.dmg"
fi

# A zip, and nothing unpacked left behind. ditto rather than zip(1): it keeps the
# symlinks and extended attributes a signed bundle is made of, and a copy that
# loses them will not launch.
if [ "$MAKE_ZIP" = "1" ]; then
    ZIP="${APP%.app}-$VERSION.zip"
    echo "==> Zipping $ZIP"
    rm -f "$ZIP"
    ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
    rm -rf "$APP"
    echo "==> Done: $ZIP"
    exit 0
fi

echo "==> Done: $APP"
