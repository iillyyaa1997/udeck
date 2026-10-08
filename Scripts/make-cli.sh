#!/bin/bash
#
# Makes udeck-plugin for whoever has no uDeck to take it from: an archive for a
# Mac, one for each Linux a plugin repository's CI runs on, the checksums over
# them, the container image such a CI pulls, and what the release says of it.
#
# Usage:  Scripts/make-cli.sh macos [--version X.Y.Z] [--sign IDENTITY] [--out DIR]
#         Scripts/make-cli.sh linux --arch x86_64|aarch64 [--version X.Y.Z] [--out DIR]
#         Scripts/make-cli.sh image [--version X.Y.Z] [--out DIR] [--stage REGISTRY/NAME] [--revision COMMIT]
#         Scripts/make-cli.sh push [--version X.Y.Z] [--out DIR] [--stage REGISTRY/NAME] [--repository REGISTRY/NAME]
#         Scripts/make-cli.sh sums [--version X.Y.Z] [--out DIR] [--repository REGISTRY/NAME]
#         Scripts/make-cli.sh notes [--version X.Y.Z] [--out DIR] [--repository REGISTRY/NAME]
#         Scripts/make-cli.sh version
#
# One script for both places that make them. release.yml runs it at a tag and
# publishes what it made; ci.yml runs the same commands on every push and
# publishes nothing. A release is therefore made by code every push has already
# run, push and notes included: the only things a tag changes are where `push`
# copies the image — ghcr.io instead of a second name in the job's own registry
# — the login just before it, and `gh release create`. And two copies of the
# steps cannot drift apart, as the bash example check in ci.yml once drifted
# from the rules it stood in for.
#
# --version is the release's version, the tag without its "v". Each command
# runs the binary it made and refuses to go on unless it says exactly
# "udeck-plugin <version>": the number in an archive's name, the image's tag
# and what the command says of itself are one number, held to the tag. Without
# --version the binary's own answer is taken. CI passes what `version` prints —
# the app's CFBundleShortVersionString, which release.yml holds a tag to — so
# that every check a tag makes of the number runs on every push, and a command
# that says another number than the app fails there rather than at the tag.
#
# --out (default .build/cli) is where archives go and where the commands after
# them find them. Relative paths are read from the repository's root, wherever
# the script is started from. A release puts them in release-cli/ — never
# release/, which generate_appcast reads whole: an archive there would be
# offered to Sparkle as an update.
#
# macos builds the command for arm64 and for x86_64 and joins the two into one
# universal binary: one archive for every Mac, and no choice of architecture
# for the person downloading it to get wrong — under Rosetta `uname -m` says
# x86_64 on an Apple Silicon Mac. It is signed exactly as Scripts/make-app.sh
# signs the copy inside uDeck.app (the same flags, the same entitlements for an
# ad-hoc signature), and not stripped: it is that command, for both
# architectures. --sign as in make-app.sh.
#
# linux builds the static musl binary for one architecture, with the Static
# Linux SDK the calling job installed (ci.yml and release.yml pin the toolchain
# image and the SDK, and a test holds the two files to one pin), strips it —
# unstripped, the binary was 71 MB — and checks that it is static: no dynamic
# loader asked for and no shared library needed, so it runs on any Linux of its
# architecture with nothing installed. It runs on a machine of that
# architecture, because the binary is run to say its version.
#
# image builds the image for linux/amd64 and linux/arm64 from the two Linux
# archives — the very binaries the archives carry — once, and pushes it to
# --stage: a registry the job runs beside itself (localhost:5000, registry:2
# as a service of the job, pinned by digest in both workflows), which nothing
# outside the runner can see. It is pushed as a release pushes it — BuildKit's
# image exporter, OCI media types, one index of both platforms — and the digest
# BuildKit reports for that index is required. The index is then read back
# from the registry, and each platform's image is pulled from it by that digest
# and run before anything else happens: --version, --help, check and
# check-repo on the examples, with the checkout mounted read-only and no
# network, as a repository's CI runs it, and pin on a release laid out on the
# image's own disk, through its curl — the lock file it writes then read by the
# reader docs/plugin-repository.md gives, with the image's BusyBox, as a GitLab
# job in the image reads it. arm64 runs under QEMU on an amd64 runner
# (or amd64 on an arm64 one): the binary itself is proved natively by the
# Linux build job, and what the image adds — Alpine's git and curl, a shell,
# /tmp — is what emulation runs here. What ran is written to
# udeck-plugin-staged.txt.
#
# push copies that index — by its digest, byte for byte — to --repository
# (ghcr.io/iillyyaa1997/udeck-plugin unless told otherwise), tagged
# v<version>; reads the tag back and requires the digest that ran; and writes
# udeck-plugin-image.txt: the image, its tag, its digest (the sha256 of that
# index, what a lock file pins) and its platforms. What is published is what
# was run, not a second build of it. Logging in to the registry is the
# caller's, just before push: no credential passes through here, and none is
# held while anything is built or run.
#
# sums writes SHA256SUMS over the three archives and udeck-plugin-image.txt —
# one version, all three platforms and the image of that version, or it
# refuses — once it has read every record of every archive, and checks what it
# wrote. notes holds udeck-plugin-image.txt to what it must say and writes
# notes.md, what the release says before GitHub's own notes: the image by its
# digest. Both read the image file the same way, and compare it byte for byte
# with the four lines push writes — `udeck-plugin pin` reads it as strictly — so
# they refuse one that names another image, another version or no whole
# digest, and one with a line more, a blank line or no line break at its end.
#
# version prints the release's version as the app says it, and nothing else.
#
# An archive holds one folder, udeck-plugin-<version>-<platform>/, with the
# command, LICENSE, NOTICE and THIRD_PARTY_NOTICES (Scripts/third-party/: what
# else the command is made of, and under what licences) in it.

set -euo pipefail

cd "$(dirname "$0")/.."

IMAGE_REPOSITORY="ghcr.io/iillyyaa1997/udeck-plugin"
# The job's own registry: the service both workflows run beside the image job
# (`ports: 5000:5000`; a test holds the three to one port).
STAGE="localhost:5000/udeck-plugin"
# Pinned by digest, as the toolchain image in ci.yml is: a tag can be moved to
# another build, and these run with the job's privileges — binfmt as
# --privileged, BuildKit with the job's network. The digests are the
# multi-architecture ones (Docker Hub, 2026-10-06), so they serve either runner.
BUILDKIT="moby/buildkit:v0.33.1@sha256:cec9f139f45e93c5c69c60f8b07cfad9f43f4ef6b6a6cd917527fea5ff2e3dea"
BINFMT="tonistiigi/binfmt:qemu-v10.2.3@sha256:400a4873b838d1b89194d982c45e5fb3cda4593fbfd7e08a02e76b03b21166f0"
PLATFORMS="linux/amd64,linux/arm64"
NOTICES="Scripts/third-party/THIRD_PARTY_NOTICES"
# The awk that takes the lock file's reader out of docs/plugin-repository.md,
# from between its markers — ci.yml's, word for word (a test holds the two to
# one) — run in the image by its own awk.
# shellcheck disable=SC2016
LOCK_READER='/^<!-- \/lock-reader -->$/ { inside = 0 } inside && !/^```/ { print } /^<!-- lock-reader -->$/ { inside = 1 }'

# The licences of what the image holds, for its licenses label, one SPDX
# expression to a line. First the command's — its own and those of what is
# linked into it, as THIRD_PARTY_NOTICES lists them — then those of Alpine's
# packages, exactly as each package's record in /lib/apk/db/installed says
# (L:). check_image reads every record in the image it built and refuses a
# licence this list does not name: the label cannot quietly fall behind what
# Alpine installs.
COMMAND_LICENSES="Apache-2.0
Apache-2.0 WITH Swift-exception
Apache-2.0 WITH LLVM-exception
MIT
BSD-3-Clause"
ALPINE_LICENSES="Apache-2.0
BSD-3-Clause
BSD-3-Clause OR GPL-2.0-or-later
curl
GPL-2.0-only
GPL-2.0-or-later OR LGPL-3.0-or-later
MIT
MIT AND BSD-2-Clause AND GPL-2.0-or-later
MPL-2.0 AND MIT
Zlib"

usage() {
    sed -n '7,13p' "$0" | sed 's/^# \{0,1\}//' >&2
    exit 2
}

fail() {
    echo "make-cli: $*" >&2
    exit 1
}

# The version a tag of this commit has to name: CFBundleShortVersionString in
# the app's Info.plist, which release.yml holds the tag to — read with sed, so
# that a Linux job, which has no PlistBuddy, can ask it too.
release_version() {
    local plist="Sources/uDeck/Support/Info.plist" keys said
    [ -f "$plist" ] || fail "no $plist"
    keys="$(grep -c '<key>CFBundleShortVersionString</key>' "$plist" || true)"
    [ "$keys" = 1 ] || fail "$plist names CFBundleShortVersionString $keys times, not once"
    said="$(sed -n '/^[[:space:]]*<key>CFBundleShortVersionString<\/key>[[:space:]]*$/{n;s/^[[:space:]]*<string>\([^<]*\)<\/string>[[:space:]]*$/\1/p;}' "$plist")"
    printf '%s\n' "$said" | grep -Eqx '[0-9]+\.[0-9]+\.[0-9]+' && [ "$(printf '%s\n' "$said" | wc -l | tr -d ' ')" = 1 ] \
        || fail "$plist says CFBundleShortVersionString is \"$said\", not X.Y.Z on the line after its key"
    printf '%s\n' "$said"
}

[ $# -gt 0 ] || usage
WHAT="$1"
shift
case "$WHAT" in
    macos|linux|image|push|sums|notes|version) ;;
    *) echo "make-cli: unknown command: $WHAT" >&2; usage ;;
esac

if [ "$WHAT" = version ]; then
    [ $# -eq 0 ] || usage
    release_version
    exit 0
fi

VERSION=""
VERSION_GIVEN=0
OUT=".build/cli"
ARCH=""
IDENTITY="-"
REVISION=""
while [ $# -gt 0 ]; do
    case "$1" in
        --version) VERSION="${2-}"; VERSION_GIVEN=1; shift 2 ;;
        --out) OUT="${2-}"; shift 2 ;;
        --arch) ARCH="${2-}"; shift 2 ;;
        --sign) IDENTITY="${2-}"; shift 2 ;;
        --stage) STAGE="${2-}"; shift 2 ;;
        --repository) IMAGE_REPOSITORY="${2-}"; shift 2 ;;
        --revision) REVISION="${2-}"; shift 2 ;;
        *) echo "make-cli: unknown option: $1" >&2; usage ;;
    esac
done

if [ -z "$OUT" ]; then
    echo "make-cli: --out needs a directory" >&2
    exit 2
fi
# Given and empty is a version somebody meant to say and did not — as
# `--version "$(make-cli.sh version)"` reads when `version` failed — not
# "whatever the binary says".
if [ "$VERSION_GIVEN" = 1 ] && [ -z "$VERSION" ]; then
    echo "make-cli: --version is empty; it takes X.Y.Z (the tag without its v)" >&2
    exit 2
fi
if [ -n "$VERSION" ] && ! printf '%s\n' "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo "make-cli: --version $VERSION is not X.Y.Z (the tag without its v)" >&2
    exit 2
fi
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"

# The temporary folders this run made, removed however it ends.
SCRATCH=""
BUILDER=""
cleanup() {
    if [ -n "$BUILDER" ]; then docker buildx rm --force "$BUILDER" >/dev/null 2>&1 || true; fi
    if [ -n "$SCRATCH" ]; then rm -rf "$SCRATCH"; fi
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM
TEMPORARY="${TMPDIR:-/tmp}"
SCRATCH="$(mktemp -d "${TEMPORARY%/}/make-cli.XXXXXX")"

# What `binary --version` says must be "udeck-plugin <version>": the version
# asked for, or — with none asked for — whatever X.Y.Z it says, which then
# names the archive. Prints the version.
version_of() {
    local binary="$1" said
    said="$("$@" --version)" || fail "$binary --version failed"
    case "$said" in
        "udeck-plugin "*) ;;
        *) fail "$binary --version said \"$said\", not \"udeck-plugin X.Y.Z\"" ;;
    esac
    said="${said#udeck-plugin }"
    printf '%s\n' "$said" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || fail "$binary says its version is \"$said\""
    if [ -n "$VERSION" ] && [ "$said" != "$VERSION" ]; then
        fail "$binary says it is udeck-plugin $said; this release is $VERSION — the command, the archive and the tag must say one number"
    fi
    printf '%s\n' "$said"
}

size_of() {
    wc -c < "$1" | tr -d ' '
}

# Every record of a tar.gz as the format stores it — one line each, sorted:
# kind, mode, owner, group, name, and the pax keys it carries ("-" for none).
# Read with Python's tarfile, which shows what is there: bsdtar on a Mac, asked
# to list an archive, folds AppleDouble records (._NAME) into the files they
# describe and shows neither them nor the extended attributes a pax header
# holds, which another machine's tar unpacks as files of their own.
records_of() {
    python3 - "$1" <<'PY'
import sys, tarfile
with tarfile.open(sys.argv[1]) as tar:
    lines = []
    for m in tar.getmembers():
        kind = "dir" if m.isdir() else "file" if m.isreg() else "other"
        mode = "-" if m.isdir() else oct(m.mode & 0o7777)[2:]
        pax = ",".join(sorted(m.pax_headers)) or "-"
        lines.append(f"{kind} {mode} {m.uid} {m.gid} {m.name} {pax}")
for line in sorted(lines, key=lambda l: l.split(" ")[4]):
    print(line)
PY
}

# What every archive holds, record for record, as records_of prints it.
records_expected() {
    local name="$1"
    printf '%s\n' \
        "dir - 0 0 $name -" \
        "file 644 0 0 $name/LICENSE -" \
        "file 644 0 0 $name/NOTICE -" \
        "file 644 0 0 $name/THIRD_PARTY_NOTICES -" \
        "file 755 0 0 $name/udeck-plugin -"
}

# Refuses an archive that holds anything but what records_expected says.
check_records() {
    local archive="$1" name="$2" found
    found="$(records_of "$archive")" || fail "$(basename "$archive") cannot be read as a tar.gz"
    [ "$found" = "$(records_expected "$name")" ] \
        || fail "$(basename "$archive") does not hold exactly the command, LICENSE, NOTICE and THIRD_PARTY_NOTICES, owned by 0:0 and with nothing of the machine it was made on; it holds: $found"
}

# The archive of `binary` for `platform`, made in OUT; prints its path. Owner
# and group are 0, gzip leaves out the time, and no extended attribute, ACL,
# file flag or AppleDouble record of a Mac goes in, so that an archive says
# nothing of the machine it was made on.
archive() {
    local binary="$1" version="$2" platform="$3"
    local name="udeck-plugin-$version-$platform"
    local folder="$SCRATCH/archive/$name"
    rm -rf "$SCRATCH/archive"
    mkdir -p "$folder"
    cp "$binary" "$folder/udeck-plugin"
    chmod 755 "$folder/udeck-plugin"
    cp LICENSE NOTICE "$folder/"
    cp "$NOTICES" "$folder/THIRD_PARTY_NOTICES"
    chmod 644 "$folder/LICENSE" "$folder/NOTICE" "$folder/THIRD_PARTY_NOTICES"
    local options gnu=0
    if tar --version 2>/dev/null | grep -q 'GNU tar'; then
        # GNU tar stores no extended attribute unless asked (--xattrs).
        gnu=1
        options=(--owner=0 --group=0 --numeric-owner)
    else
        # bsdtar stores a Mac's extended attributes — com.apple.provenance is
        # on every file a Mac has downloaded or made — as pax records and, with
        # its copyfile, AppleDouble ._ files beside them.
        options=(--uid 0 --gid 0 --no-mac-metadata --no-xattrs --no-acls --no-fflags)
    fi
    rm -f "$OUT/$name.tar.gz"
    (cd "$SCRATCH/archive" && COPYFILE_DISABLE=1 tar "${options[@]}" -cf - "$name") | gzip -n -9 > "$OUT/$name.tar.gz"
    # Read back: what it holds is what a person unpacks. GNU tar lists every
    # record as it is stored, and the Static Linux SDK's image has no Python;
    # `sums` reads these archives' records with Python before a release names
    # them.
    if [ "$gnu" = 1 ]; then
        local listed
        listed="$(tar -tzf "$OUT/$name.tar.gz" | sort | tr '\n' ' ')"
        [ "$listed" = "$name/ $name/LICENSE $name/NOTICE $name/THIRD_PARTY_NOTICES $name/udeck-plugin " ] \
            || fail "$name.tar.gz holds $listed"
    else
        check_records "$OUT/$name.tar.gz" "$name"
    fi
    echo "$OUT/$name.tar.gz"
}

# --- macos ---------------------------------------------------------------------------------------

build_macos() {
    [ "$(uname -s)" = "Darwin" ] || fail "macos builds on a Mac: lipo and codesign are the Mac's"
    local package="Packages/UDeckPluginFormat"
    local slices=()
    local arch bin slice
    for arch in arm64 x86_64; do
        echo "==> Building udeck-plugin for $arch"
        swift build -c release --package-path "$package" --product udeck-plugin --arch "$arch"
        bin="$(swift build -c release --package-path "$package" --product udeck-plugin --arch "$arch" --show-bin-path)"
        [ -x "$bin/udeck-plugin" ] || fail "no udeck-plugin in $bin after the $arch build"
        # Taken away at once: a build system may put both architectures'
        # products at one path (Swift 6.4's default one does: measured, the
        # x86_64 build overwrote the arm64 one), and the next build would.
        slice="$SCRATCH/udeck-plugin-$arch"
        cp "$bin/udeck-plugin" "$slice"
        [ "$(lipo -archs "$slice")" = "$arch" ] || fail "the $arch build made a binary for $(lipo -archs "$slice")"
        slices+=("$slice")
    done
    local binary="$SCRATCH/udeck-plugin"
    lipo -create -output "$binary" "${slices[@]}"
    local archs
    archs="$(lipo -archs "$binary")"
    case " $archs " in
        *" arm64 "*) ;;
        *) fail "the universal binary has no arm64 slice: $archs" ;;
    esac
    case " $archs " in
        *" x86_64 "*) ;;
        *) fail "the universal binary has no x86_64 slice: $archs" ;;
    esac

    # As Scripts/make-app.sh signs the command inside uDeck.app — the same
    # lines; a test holds the two scripts to them.
    SIGN_FLAGS=(--force --options runtime --sign "$IDENTITY")
    if [ "$IDENTITY" = "-" ]; then
        SIGN_FLAGS+=(--entitlements Scripts/adhoc.entitlements)
    fi
    echo "==> Signing with identity: $IDENTITY"
    codesign "${SIGN_FLAGS[@]}" "$binary"
    codesign --verify --strict --verbose=2 "$binary"

    local version
    version="$(version_of "$binary")"
    # The other slice as well, where this Mac can run it: Apple Silicon runs
    # x86_64 under Rosetta when Rosetta is installed, and says so when not.
    if [ "$(uname -m)" = "arm64" ]; then
        if arch -x86_64 /usr/bin/true 2>/dev/null; then
            [ "$(version_of arch -x86_64 "$binary")" = "$version" ] || fail "the x86_64 slice says another version"
            echo "==> Both slices say udeck-plugin $version"
        else
            echo "==> The x86_64 slice was not run: this Mac cannot run x86_64 code (no Rosetta)"
        fi
    fi
    echo "==> udeck-plugin $version for macOS ($archs): $(size_of "$binary") bytes"
    local made
    made="$(archive "$binary" "$version" macos-universal)"
    echo "==> Done: $made, $(size_of "$made") bytes"
}

# --- linux ---------------------------------------------------------------------------------------

build_linux() {
    local machine
    case "$ARCH" in
        x86_64) machine="X86-64" ;;
        aarch64) machine="AArch64" ;;
        "") echo "make-cli: linux needs --arch x86_64 or --arch aarch64" >&2; exit 2 ;;
        *) echo "make-cli: --arch $ARCH: x86_64 or aarch64" >&2; exit 2 ;;
    esac
    [ "$(uname -s)" = "Linux" ] || fail "linux builds on Linux, with the Static Linux SDK installed"
    [ "$(uname -m)" = "$ARCH" ] || fail "linux --arch $ARCH builds on an $ARCH machine: the binary is run to say its version, and this is $(uname -m)"

    local package="Packages/UDeckPluginFormat"
    # `--build-system native`: with Swift 6.4.0's default build system a
    # static standard library with Foundation fails to link on Linux
    # (swiftlang/swift-build#1764), as ci.yml says where it was found.
    local build=(swift build -c release --build-system native --swift-sdk "$ARCH-swift-linux-musl"
                 --package-path "$package" --product udeck-plugin)
    echo "==> Building udeck-plugin for $ARCH-swift-linux-musl"
    "${build[@]}"
    local bin
    bin="$("${build[@]}" --show-bin-path)"
    [ -x "$bin/udeck-plugin" ] || fail "no udeck-plugin in $bin after the build"

    local binary="$SCRATCH/udeck-plugin"
    cp "$bin/udeck-plugin" "$binary"
    local linked
    linked="$(size_of "$binary")"
    strip "$binary"
    local stripped
    stripped="$(size_of "$binary")"

    readelf -h "$binary" | grep 'Machine:' | grep -q "$machine" \
        || fail "udeck-plugin is not built for $ARCH: $(readelf -h "$binary" | grep 'Machine:')"
    if readelf -l "$binary" | grep -q 'INTERP'; then
        fail "udeck-plugin asks for a dynamic loader; it is not a static binary"
    fi
    if readelf -d "$binary" | grep -q 'NEEDED'; then
        fail "udeck-plugin needs shared libraries; it is not a static binary: $(readelf -d "$binary" | grep 'NEEDED' | tr '\n' ' ')"
    fi

    local version
    version="$(version_of "$binary")"
    echo "==> udeck-plugin $version for linux-$ARCH: $linked bytes as linked, $stripped stripped"
    local made
    made="$(archive "$binary" "$version" "linux-$ARCH")"
    echo "==> Done: $made, $(size_of "$made") bytes"
}

# --- the image file ------------------------------------------------------------------------------

# What an image file says — udeck-plugin-staged.txt, written by `image`, and
# udeck-plugin-image.txt, written by `push` — given the image, the version
# and the digest: four lines, in this order, and nothing else.
image_text() {
    printf 'image=%s\ntag=v%s\ndigest=%s\nplatforms=%s\n' "$1" "$2" "$3" "$PLATFORMS"
}

# Reads an image file and holds it to image_text, byte for byte — compared by
# cmp, since `$(cat file)` drops every line break at a file's end and would
# take three more, or none, for the one there should be (D1b's review): of the
# image `repository` names, of --version when one is asked for, with a digest
# that is a whole sha256. Sets IMAGE_VERSION and IMAGE_DIGEST. Each refusal is
# an exit of its own: a check in the middle of `a && b` does not stop a script
# under `set -e`, and a release whose notes name `image@` with no digest is
# immutable once made.
read_image_file() {
    local file="$1" repository="$2" name
    name="$(basename "$file")"
    [ -f "$file" ] || fail "no $name in $(dirname "$file")"
    local version digest
    version="$(sed -n 's/^tag=v\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)$/\1/p' "$file")"
    digest="$(sed -n 's/^digest=\(sha256:[0-9a-f]\{64\}\)$/\1/p' "$file")"
    if [ -z "$version" ]; then
        fail "$name has no line tag=vX.Y.Z: $(tr '\n' ' ' < "$file")"
    fi
    if [ -z "$digest" ]; then
        fail "$name has no line digest=sha256:<64 hexadecimal digits>: $(tr '\n' ' ' < "$file")"
    fi
    image_text "$repository" "$version" "$digest" > "$SCRATCH/expected-$name"
    if ! cmp -s "$file" "$SCRATCH/expected-$name"; then
        fail "$name says: $(od -An -c "$file" | tr -s ' \n' ' ')— not, byte for byte, $(tr '\n' ' ' < "$SCRATCH/expected-$name")"
    fi
    if [ -n "$VERSION" ] && [ "$version" != "$VERSION" ]; then
        fail "$name is of v$version; this release is $VERSION"
    fi
    IMAGE_VERSION="$version"
    IMAGE_DIGEST="$digest"
}

# --- sums ----------------------------------------------------------------------------------------

sha256() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$@"; else shasum -a 256 "$@"; fi
}

write_sums() {
    cd "$OUT"
    local versions
    versions="$( (ls udeck-plugin-*.tar.gz 2>/dev/null || true) \
        | sed -n 's/^udeck-plugin-\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)-.*\.tar\.gz$/\1/p' | sort -u)"
    [ -n "$versions" ] || fail "no udeck-plugin archive in $OUT"
    [ "$(printf '%s\n' "$versions" | wc -l | tr -d ' ')" = "1" ] \
        || fail "archives of more than one version in $OUT: $(printf '%s\n' "$versions" | tr '\n' ' ')"
    local version="$versions"
    if [ -n "$VERSION" ] && [ "$version" != "$VERSION" ]; then
        fail "the archives in $OUT are $version; this release is $VERSION"
    fi
    local files=() platform
    for platform in macos-universal linux-x86_64 linux-aarch64; do
        [ -f "udeck-plugin-$version-$platform.tar.gz" ] || fail "no udeck-plugin-$version-$platform.tar.gz in $OUT"
        files+=("udeck-plugin-$version-$platform.tar.gz")
    done
    local found
    for found in udeck-plugin-*.tar.gz; do
        case "$found" in
            "udeck-plugin-$version-macos-universal.tar.gz" | "udeck-plugin-$version-linux-x86_64.tar.gz" \
                | "udeck-plugin-$version-linux-aarch64.tar.gz") ;;
            *) fail "an archive no release names is in $OUT: $found" ;;
        esac
    done
    # Every record, as whoever unpacks one will find it — on any machine, with
    # any tar.
    for platform in macos-universal linux-x86_64 linux-aarch64; do
        check_records "udeck-plugin-$version-$platform.tar.gz" "udeck-plugin-$version-$platform"
    done
    VERSION="$version"
    read_image_file "$OUT/udeck-plugin-image.txt" "$IMAGE_REPOSITORY"
    files+=(udeck-plugin-image.txt)
    sha256 "${files[@]}" > SHA256SUMS
    sha256 -c SHA256SUMS
    echo "==> $OUT/SHA256SUMS:"
    cat SHA256SUMS
}

# --- notes ---------------------------------------------------------------------------------------

write_notes() {
    read_image_file "$OUT/udeck-plugin-image.txt" "$IMAGE_REPOSITORY"
    # Said first, ahead of what GitHub generates: the image by its digest,
    # which is what a repository's CI pins.
    printf '%s\n' \
        "**udeck-plugin** for a plugin repository's CI — the image, pulled by its digest:" \
        "" \
        "    $IMAGE_REPOSITORY@$IMAGE_DIGEST" \
        "" \
        "linux/amd64 and linux/arm64. The archives below — macOS (universal), Linux x86_64 and aarch64 — are checked against SHA256SUMS; what else each is made of, and under what licences, is in its THIRD_PARTY_NOTICES." \
        > "$OUT/notes.md"
    echo "==> $OUT/notes.md:"
    cat "$OUT/notes.md"
}

# --- image ---------------------------------------------------------------------------------------

# The two Linux binaries, out of the archives the release publishes, into the
# image's build context; prints the version they are.
image_context() {
    local context="$1" versions version
    versions="$( (ls "$OUT"/udeck-plugin-*-linux-*.tar.gz 2>/dev/null || true) | sed -n \
        's|^.*/udeck-plugin-\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)-linux-[a-z0-9_]*\.tar\.gz$|\1|p' | sort -u)"
    [ -n "$versions" ] || fail "no Linux archive of udeck-plugin in $OUT"
    [ "$(printf '%s\n' "$versions" | wc -l | tr -d ' ')" = "1" ] || fail "Linux archives of more than one version in $OUT"
    version="$versions"
    if [ -n "$VERSION" ] && [ "$version" != "$VERSION" ]; then
        fail "the Linux archives in $OUT are $version; this release is $VERSION"
    fi
    local arch platform_arch name
    for arch in x86_64 aarch64; do
        case "$arch" in x86_64) platform_arch=amd64 ;; aarch64) platform_arch=arm64 ;; esac
        name="udeck-plugin-$version-linux-$arch"
        [ -f "$OUT/$name.tar.gz" ] || fail "no $name.tar.gz in $OUT"
        mkdir -p "$context/$platform_arch"
        tar -xzf "$OUT/$name.tar.gz" -C "$SCRATCH" "$name/udeck-plugin"
        mv "$SCRATCH/$name/udeck-plugin" "$context/$platform_arch/udeck-plugin"
        rmdir "$SCRATCH/$name"
    done
    cp Scripts/udeck-plugin.Dockerfile "$context/Dockerfile"
    cp LICENSE NOTICE "$context/"
    cp "$NOTICES" "$context/THIRD_PARTY_NOTICES"
    echo "$version"
}

# The image's licenses label: COMMAND_LICENSES and ALPINE_LICENSES, each once,
# joined into one SPDX expression — a licence that is itself an AND or an OR
# in brackets.
licenses_label() {
    local label="" seen="" licence
    while IFS= read -r licence; do
        [ -n "$licence" ] || continue
        if printf '%s\n' "$seen" | grep -Fxq -- "$licence"; then continue; fi
        seen="$seen
$licence"
        case "$licence" in
            *" AND "* | *" OR "*) licence="($licence)" ;;
        esac
        label="${label:+$label AND }$licence"
    done <<EOF
$COMMAND_LICENSES
$ALPINE_LICENSES
EOF
    printf '%s\n' "$label"
}

# The index at repository@digest, read from its registry: an OCI index with an
# image for each platform.
check_index() {
    local repository="$1" digest="$2"
    docker buildx imagetools inspect --raw "$repository@$digest" > "$SCRATCH/index.json" \
        || fail "$repository@$digest cannot be read from its registry"
    grep -q '"mediaType": *"application/vnd.oci.image.index.v1+json"' "$SCRATCH/index.json" \
        || fail "$repository@$digest is not an OCI image index: $(cat "$SCRATCH/index.json")"
    local arch
    for arch in amd64 arm64; do
        grep -q "\"architecture\": *\"$arch\"" "$SCRATCH/index.json" \
            || fail "$repository@$digest has no linux/$arch image: $(cat "$SCRATCH/index.json")"
    done
}

# Runs `ref`, as platform `platform`, the way a repository's CI runs it.
check_image() {
    local ref="$1" platform="$2" version="$3"
    local run=(docker run --rm --network none --platform "$platform")
    echo "==> Running $ref as $platform"
    local said
    said="$("${run[@]}" "$ref" udeck-plugin --version)" || fail "udeck-plugin --version failed in the image ($platform)"
    [ "$said" = "udeck-plugin $version" ] || fail "in the image ($platform) udeck-plugin says \"$said\", not \"udeck-plugin $version\""
    "${run[@]}" "$ref" udeck-plugin --help > "$SCRATCH/help.txt" || fail "udeck-plugin --help failed in the image ($platform)"
    grep -q '^usage: udeck-plugin' "$SCRATCH/help.txt" || fail "udeck-plugin --help in the image ($platform) printed no usage"
    # The image's own shell and git, which GitLab CI and the check start, and
    # curl, which `udeck-plugin pin` reads a release with.
    "${run[@]}" "$ref" sh -c 'git --version && curl --version && test -d /tmp' \
        || fail "no shell, git, curl or /tmp in the image ($platform)"

    # What it says of what it holds: the notices beside the command, the list
    # of Alpine's packages with where their sources are, and no package under
    # a licence the label does not name.
    "${run[@]}" "$ref" sh -c 'cd /usr/share/licenses/udeck-plugin && test -s LICENSE && test -s NOTICE && test -s THIRD_PARTY_NOTICES && grep -q "^git " ALPINE-PACKAGES' \
        || fail "the image ($platform) lacks its licences, its notices or the list of its Alpine packages"
    "${run[@]}" "$ref" sed -n 's/^L://p' /lib/apk/db/installed > "$SCRATCH/licenses.txt" \
        || fail "the image's ($platform) package records cannot be read"
    [ -s "$SCRATCH/licenses.txt" ] || fail "the image ($platform) has no package records"
    local licence
    while IFS= read -r licence; do
        printf '%s\n' "$ALPINE_LICENSES" | grep -Fxq -- "$licence" \
            || fail "a package in the image ($platform) is under \"$licence\", which its licenses label does not name: add it to ALPINE_LICENSES"
    done < "$SCRATCH/licenses.txt"

    # The examples, strictly, read through git — the checkout made by the
    # runner's user, read by the image's root, as safe.directory allows.
    local examples=0 example
    for example in examples/*/; do
        if [ -d "$example" ]; then examples=$((examples + 1)); fi
    done
    "${run[@]}" -v "$PWD:/udeck:ro" "$ref" sh -c 'udeck-plugin check --strict /udeck/examples/*/' \
        | tee "$SCRATCH/check.txt" || fail "check --strict on the examples failed in the image ($platform)"
    local clean
    clean="$(grep -c '^checked /udeck/examples/.* at [0-9a-f]\{12\} strictly: 0 errors, 0 warnings$' "$SCRATCH/check.txt" || true)"
    [ "$clean" = "$examples" ] || fail "in the image ($platform), $clean of $examples examples checked clean"

    # A plugin repository made inside, as an author makes one: clean at its
    # first commit, and a change without a new version refused (rule 18),
    # which takes git's history. The script is the image's shell's, and its
    # variables are the image's: the quotes keep them from this one.
    # shellcheck disable=SC2016
    "${run[@]}" -v "$PWD/examples:/examples:ro" "$ref" sh -eu -c '
        repo=/tmp/repository
        mkdir -p "$repo/plugins"
        cp -R /examples/hello-card "$repo/plugins/hello-card"
        printf "{\"format\": 1, \"name\": \"Made in the image\"}\n" > "$repo/udeck-plugins.json"
        commit() { git -C "$repo" -c user.name=CI -c user.email=ci@example.invalid commit -q "$@"; }
        git -C "$repo" init -q -b main
        git -C "$repo" add -A
        commit -m "A plugin"
        udeck-plugin check-repo --strict --repo "$repo" | tee /tmp/out.txt
        grep -q "^checked 1 plugin folder at [0-9a-f]\{12\} strictly: 0 errors" /tmp/out.txt
        printf "\nChanged.\n" >> "$repo/plugins/hello-card/README.md"
        commit -a -m "A change without a new version"
        status=0
        udeck-plugin check-repo --repo "$repo" > /tmp/out.txt || status=$?
        cat /tmp/out.txt
        test "$status" -eq 1
        grep -q "^error: plugins/hello-card/manifest.json: the folder changed.*\[rule 18\]$" /tmp/out.txt
    ' || fail "check-repo on a repository made in the image did not say what it should ($platform)"

    # A release on the image's own disk, laid out as GitHub's, and a plugin
    # repository pinned to it: pin writes the lock file from the release's
    # SHA256SUMS and image file through the image's curl, --check holds it to
    # them, and a sum changed by hand is a failed --check. And the lock file
    # read as a GitLab job in this image reads it: the reader in
    # docs/plugin-repository.md — taken out of it here by the same awk as
    # ci.yml's — run by the image's BusyBox sh, sed, mktemp and cmp, held to
    # every value pin wrote, and refusing a file with a line more than pin
    # writes, which only its cmp tells from the lock file.
    # shellcheck disable=SC2016
    "${run[@]}" -v "$PWD/docs:/docs:ro" "$ref" sh -eu -c '
        wanted="$1"
        release="/tmp/releases/download/v$wanted"
        repo=/tmp/plugins-repository
        mkdir -p "$release" "$repo"
        cd "$release"
        for platform in macos-universal linux-x86_64 linux-aarch64; do
            printf "the %s archive\n" "$platform" > "udeck-plugin-$wanted-$platform.tar.gz"
        done
        printf "image=registry.invalid/udeck/udeck-plugin\ntag=v%s\ndigest=sha256:%s\nplatforms=linux/amd64,linux/arm64\n" \
            "$wanted" 0000000000000000000000000000000000000000000000000000000000000000 > udeck-plugin-image.txt
        sha256sum "udeck-plugin-$wanted-macos-universal.tar.gz" "udeck-plugin-$wanted-linux-x86_64.tar.gz" \
            "udeck-plugin-$wanted-linux-aarch64.tar.gz" udeck-plugin-image.txt > SHA256SUMS
        printf "{\"format\": 1, \"name\": \"Pinned in the image\"}\n" > "$repo/udeck-plugins.json"
        export UDECK_PLUGIN_DOWNLOAD_BASE="file:///tmp/releases/download"
        udeck-plugin pin --repo "$repo" --version "$wanted"
        lock="$repo/.github/udeck-plugin.lock"
        cat "$lock"
        grep -qx "version=$wanted" "$lock"
        grep -qx "linux-x86_64=$(sha256sum "udeck-plugin-$wanted-linux-x86_64.tar.gz" | cut -d " " -f 1)" "$lock"
        grep -qx "image=sha256:0000000000000000000000000000000000000000000000000000000000000000" "$lock"
        udeck-plugin pin --repo "$repo" --check

        awk "$2" /docs/plugin-repository.md > /tmp/read-lock.sh
        grep -q "^read_udeck_plugin_lock() {" /tmp/read-lock.sh
        . /tmp/read-lock.sh
        read_udeck_plugin_lock "$lock"
        test "$version" = "$wanted"
        for platform in macos-universal linux-x86_64 linux-aarch64; do
            case "$platform" in
                macos-universal) read="$macos_universal" ;;
                linux-x86_64) read="$linux_x86_64" ;;
                linux-aarch64) read="$linux_aarch64" ;;
            esac
            test "$read" = "$(sha256sum "udeck-plugin-$wanted-$platform.tar.gz" | cut -d " " -f 1)"
        done
        test "$image" = "sha256:0000000000000000000000000000000000000000000000000000000000000000"
        { cat "$lock"; echo "comment=1"; } > /tmp/longer.lock
        if read_udeck_plugin_lock /tmp/longer.lock 2>/dev/null; then exit 1; fi
        echo "the lock file read by the reader in the docs, as a job in this image reads it"

        sed "s/^image=sha256:0/image=sha256:1/" "$lock" > /tmp/changed.lock
        cat /tmp/changed.lock > "$lock"
        status=0
        udeck-plugin pin --repo "$repo" --check > /tmp/out.txt || status=$?
        cat /tmp/out.txt
        test "$status" -eq 1
        grep -q "^  image: sha256:1" /tmp/out.txt
    ' sh "$version" "$LOCK_READER" || fail "pin in the image did not pin a release on its disk as it should ($platform)"
    echo "==> $ref as $platform: udeck-plugin $version; check, check-repo and pin as a repository's CI runs them, the pin read as its CI reads it"
}

build_image() {
    local context="$SCRATCH/context"
    mkdir -p "$context"
    local version
    version="$(image_context "$context")"
    VERSION="$version"
    if [ -z "$REVISION" ]; then
        REVISION="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
    fi
    local tag="$STAGE:v$version"
    local description="udeck-plugin $version: checks uDeck plugins and plugin repositories, in a repository's CI"
    local licenses
    licenses="$(licenses_label)"
    rm -f "$OUT/udeck-plugin-staged.txt"

    # QEMU for the platform this runner is not, so that both platforms'
    # copies are built and run here; then a builder of its own — the Docker
    # engine's default one cannot hold an image of two platforms — on the
    # runner's network: BuildKit runs in a container, and the job's registry
    # is at the runner's localhost.
    local foreign
    case "$(uname -m)" in
        x86_64|amd64) foreign=arm64 ;;
        aarch64|arm64) foreign=amd64 ;;
        *) fail "an image is built on an x86_64 or an arm64 machine, not $(uname -m)" ;;
    esac
    echo "==> Letting this $(uname -m) machine run $foreign code"
    docker run --privileged --rm "$BINFMT" --install "$foreign"
    BUILDER="udeck-plugin-$$"
    docker buildx create --name "$BUILDER" --driver docker-container \
        --driver-opt "image=$BUILDKIT" --driver-opt network=host --bootstrap

    # No provenance attestation and no SBOM: the index holds exactly the two
    # images people run, which every registry and every copy by digest — a
    # mirror of it on a GitLab — reads as it is. Attestations are a decision of
    # their own, not one to take in passing. OCI media types said rather than
    # left to BuildKit's default, which has changed between its versions: the
    # index's annotations need them.
    echo "==> Building $tag for $PLATFORMS and pushing it to the job's own registry"
    docker buildx build --builder "$BUILDER" --file "$context/Dockerfile" \
        --build-arg "VERSION=$version" --build-arg "REVISION=$REVISION" --build-arg "LICENSES=$licenses" \
        --provenance=false --sbom=false \
        --platform "$PLATFORMS" \
        --annotation "index:org.opencontainers.image.description=$description" \
        --annotation "index:org.opencontainers.image.source=https://github.com/iillyyaa1997/udeck" \
        --annotation "index:org.opencontainers.image.version=$version" \
        --annotation "index:org.opencontainers.image.licenses=$licenses" \
        --output "type=image,name=$tag,push=true,oci-mediatypes=true" \
        --metadata-file "$SCRATCH/built.json" "$context"
    local digest
    digest="$(digest_in "$SCRATCH/built.json")"
    check_index "$STAGE" "$digest"
    echo "==> $STAGE@$digest: an index for $PLATFORMS"

    # Each platform's image as a repository's CI gets it: pulled by the
    # index's digest, from the registry it was pushed to.
    local platform
    for platform in linux/amd64 linux/arm64; do
        docker pull --platform "$platform" "$STAGE@$digest"
        check_image "$STAGE@$digest" "$platform" "$version"
        docker image rm "$STAGE@$digest" >/dev/null 2>&1 || true
    done

    image_text "$STAGE" "$version" "$digest" > "$OUT/udeck-plugin-staged.txt"
    echo "==> Built and run, not published: $OUT/udeck-plugin-staged.txt:"
    cat "$OUT/udeck-plugin-staged.txt"
}

push_image() {
    read_image_file "$OUT/udeck-plugin-staged.txt" "$STAGE"
    local version="$IMAGE_VERSION" digest="$IMAGE_DIGEST"
    local tag="$IMAGE_REPOSITORY:v$version"
    rm -f "$OUT/udeck-plugin-image.txt"
    echo "==> Publishing $STAGE@$digest as $tag"
    # One source and no annotation of its own: the index is copied as it is,
    # its bytes and so its digest unchanged, with every blob it names.
    docker buildx imagetools create --tag "$tag" "$STAGE@$digest"
    # Read back: the tag names the very index that ran.
    docker buildx imagetools inspect "$tag" > "$SCRATCH/pushed.txt" || fail "$tag cannot be read back"
    local said
    said="$(sed -n 's/^Digest: *\(sha256:[0-9a-f]\{64\}\)$/\1/p' "$SCRATCH/pushed.txt" | head -1)"
    [ "$said" = "$digest" ] || fail "$tag is ${said:-(no digest)}, not $digest, which ran: $(cat "$SCRATCH/pushed.txt")"
    check_index "$IMAGE_REPOSITORY" "$digest"
    image_text "$IMAGE_REPOSITORY" "$version" "$digest" > "$OUT/udeck-plugin-image.txt"
    echo "==> Published $IMAGE_REPOSITORY@$digest ($tag); $OUT/udeck-plugin-image.txt:"
    cat "$OUT/udeck-plugin-image.txt"
}

# The digest BuildKit reports for what it pushed, from its metadata file —
# required: the digest is what a release names.
digest_in() {
    local digest
    digest="$(sed -n 's/.*"containerimage\.digest": *"\(sha256:[0-9a-f]\{64\}\)".*/\1/p' "$1" | head -1)"
    [ -n "$digest" ] || fail "no image digest in $1: $(cat "$1")"
    echo "$digest"
}

case "$WHAT" in
    macos) build_macos ;;
    linux) build_linux ;;
    image) build_image ;;
    push) push_image ;;
    sums) write_sums ;;
    notes) write_notes ;;
esac
