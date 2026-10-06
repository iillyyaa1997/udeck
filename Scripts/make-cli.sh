#!/bin/bash
#
# Makes udeck-plugin for whoever has no uDeck to take it from: an archive for a
# Mac, one for each Linux a plugin repository's CI runs on, the checksums over
# them, and the container image such a CI pulls.
#
# Usage:  Scripts/make-cli.sh macos [--version X.Y.Z] [--sign IDENTITY] [--out DIR]
#         Scripts/make-cli.sh linux --arch x86_64|aarch64 [--version X.Y.Z] [--out DIR]
#         Scripts/make-cli.sh sums [--out DIR]
#         Scripts/make-cli.sh image [--version X.Y.Z] [--out DIR] [--push]
#                                   [--repository REGISTRY/NAME] [--revision COMMIT]
#
# One script for both places that make them. release.yml runs it at a tag and
# publishes what it made; ci.yml runs the same commands on every push and
# publishes nothing. A release is therefore made by code every push has already
# run — the only steps a tag adds are the registry login, `--push`, and `gh
# release create` — and two copies of the steps cannot drift apart, as the bash
# example check in ci.yml once drifted from the rules it stood in for.
#
# --version is the release's version, the tag without its "v". Each command
# runs the binary it made and refuses to go on unless it says exactly
# "udeck-plugin <version>": the number in an archive's name, the image's tag
# and what the command says of itself are one number, held to the tag. Without
# --version the binary's own answer is taken, as CI does.
#
# --out (default .build/cli) is where archives go and where `sums` and `image`
# find them. Relative paths are read from the repository's root, wherever the
# script is started from. A release puts them in release-cli/ — never
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
# sums writes SHA256SUMS over the three archives — one version, all three
# platforms, or it refuses — and over udeck-plugin-image.txt when it is there,
# and checks what it wrote.
#
# image builds the image for linux/amd64 and linux/arm64 from the two Linux
# archives — the very binaries the archives carry — and runs each platform's
# copy before anything else happens: --version, --help, and check and
# check-repo on the examples, with the checkout mounted read-only and no
# network, as a repository's CI runs it. arm64 runs under QEMU on an amd64
# runner (or amd64 on an arm64 one): the binary itself is proved natively by
# the Linux build job, and what the image adds — Alpine's git, a shell, /tmp —
# is what emulation runs here. With --push the same build is pushed, tagged
# v<version>, as one multi-platform index, and its digest — the sha256 of that
# index, what a lock file pins — is written to udeck-plugin-image.txt. Logging
# in to the registry is the caller's: no credential passes through here.
#
# An archive holds one folder, udeck-plugin-<version>-<platform>/, with the
# command, LICENSE and NOTICE in it.

set -euo pipefail

cd "$(dirname "$0")/.."

IMAGE_REPOSITORY="ghcr.io/iillyyaa1997/udeck-plugin"
# Pinned by digest, as the toolchain image in ci.yml is: a tag can be moved to
# another build, and these run with the job's privileges — binfmt as
# --privileged, BuildKit with the registry login. The digests are the
# multi-architecture ones (Docker Hub, 2026-10-06), so they serve either runner.
BUILDKIT="moby/buildkit:v0.33.1@sha256:cec9f139f45e93c5c69c60f8b07cfad9f43f4ef6b6a6cd917527fea5ff2e3dea"
BINFMT="tonistiigi/binfmt:qemu-v10.2.3@sha256:400a4873b838d1b89194d982c45e5fb3cda4593fbfd7e08a02e76b03b21166f0"
PLATFORMS="linux/amd64,linux/arm64"

usage() {
    sed -n '7,11p' "$0" | sed 's/^# \{0,1\}//' >&2
    exit 2
}

fail() {
    echo "make-cli: $*" >&2
    exit 1
}

[ $# -gt 0 ] || usage
WHAT="$1"
shift
case "$WHAT" in
    macos|linux|sums|image) ;;
    *) echo "make-cli: unknown command: $WHAT" >&2; usage ;;
esac

VERSION=""
OUT=".build/cli"
ARCH=""
IDENTITY="-"
PUSH=0
REVISION=""
while [ $# -gt 0 ]; do
    case "$1" in
        --version) VERSION="${2-}"; shift 2 ;;
        --out) OUT="${2-}"; shift 2 ;;
        --arch) ARCH="${2-}"; shift 2 ;;
        --sign) IDENTITY="${2-}"; shift 2 ;;
        --push) PUSH=1; shift ;;
        --repository) IMAGE_REPOSITORY="${2-}"; shift 2 ;;
        --revision) REVISION="${2-}"; shift 2 ;;
        *) echo "make-cli: unknown option: $1" >&2; usage ;;
    esac
done

if [ -z "$OUT" ]; then
    echo "make-cli: --out needs a directory" >&2
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

# The archive of `binary` for `platform`, made in OUT; prints its path. Owner
# and group are 0 and gzip leaves out the time, so that an archive says nothing
# of the machine it was made on.
archive() {
    local binary="$1" version="$2" platform="$3"
    local name="udeck-plugin-$version-$platform"
    local folder="$SCRATCH/archive/$name"
    rm -rf "$SCRATCH/archive"
    mkdir -p "$folder"
    cp "$binary" "$folder/udeck-plugin"
    chmod 755 "$folder/udeck-plugin"
    cp LICENSE NOTICE "$folder/"
    chmod 644 "$folder/LICENSE" "$folder/NOTICE"
    local owner
    if tar --version 2>/dev/null | grep -q 'GNU tar'; then
        owner=(--owner=0 --group=0 --numeric-owner)
    else
        owner=(--uid 0 --gid 0)
    fi
    rm -f "$OUT/$name.tar.gz"
    (cd "$SCRATCH/archive" && tar "${owner[@]}" -cf - "$name") | gzip -n -9 > "$OUT/$name.tar.gz"
    # Read back: what it holds is what a person unpacks.
    local listed
    listed="$(tar -tzf "$OUT/$name.tar.gz" | sort | tr '\n' ' ')"
    [ "$listed" = "$name/ $name/LICENSE $name/NOTICE $name/udeck-plugin " ] || fail "$name.tar.gz holds $listed"
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
    if [ -f udeck-plugin-image.txt ]; then
        files+=(udeck-plugin-image.txt)
    fi
    sha256 "${files[@]}" > SHA256SUMS
    sha256 -c SHA256SUMS
    echo "==> $OUT/SHA256SUMS:"
    cat SHA256SUMS
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
    echo "$version"
}

# Runs `tag`, as platform `platform`, the way a repository's CI runs it.
check_image() {
    local tag="$1" platform="$2" version="$3"
    local run=(docker run --rm --network none --platform "$platform")
    echo "==> Running $tag as $platform"
    local said
    said="$("${run[@]}" "$tag" udeck-plugin --version)" || fail "udeck-plugin --version failed in the image ($platform)"
    [ "$said" = "udeck-plugin $version" ] || fail "in the image ($platform) udeck-plugin says \"$said\", not \"udeck-plugin $version\""
    "${run[@]}" "$tag" udeck-plugin --help > "$SCRATCH/help.txt" || fail "udeck-plugin --help failed in the image ($platform)"
    grep -q '^usage: udeck-plugin' "$SCRATCH/help.txt" || fail "udeck-plugin --help in the image ($platform) printed no usage"
    # The image's own shell and git, which GitLab CI and the check start.
    "${run[@]}" "$tag" sh -c 'git --version && test -d /tmp' || fail "no shell, git or /tmp in the image ($platform)"

    # The examples, strictly, read through git — the checkout made by the
    # runner's user, read by the image's root, as safe.directory allows.
    local examples=0 example
    for example in examples/*/; do
        if [ -d "$example" ]; then examples=$((examples + 1)); fi
    done
    "${run[@]}" -v "$PWD:/udeck:ro" "$tag" sh -c 'udeck-plugin check --strict /udeck/examples/*/' \
        | tee "$SCRATCH/check.txt" || fail "check --strict on the examples failed in the image ($platform)"
    local clean
    clean="$(grep -c '^checked /udeck/examples/.* at [0-9a-f]\{12\} strictly: 0 errors, 0 warnings$' "$SCRATCH/check.txt" || true)"
    [ "$clean" = "$examples" ] || fail "in the image ($platform), $clean of $examples examples checked clean"

    # A plugin repository made inside, as an author makes one: clean at its
    # first commit, and a change without a new version refused (rule 18),
    # which takes git's history. The script is the image's shell's, and its
    # variables are the image's: the quotes keep them from this one.
    # shellcheck disable=SC2016
    "${run[@]}" -v "$PWD/examples:/examples:ro" "$tag" sh -eu -c '
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
    echo "==> $tag as $platform: udeck-plugin $version, check and check-repo as a repository's CI runs them"
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
    local tag="$IMAGE_REPOSITORY:v$version"
    local description="udeck-plugin $version: checks uDeck plugins and plugin repositories, in a repository's CI"

    # QEMU for the platform this runner is not, so that both platforms'
    # copies are built and run here; then a builder of its own — the Docker
    # engine's default one cannot hold an image of two platforms.
    local foreign
    case "$(uname -m)" in
        x86_64|amd64) foreign=arm64 ;;
        aarch64|arm64) foreign=amd64 ;;
        *) fail "an image is built on an x86_64 or an arm64 machine, not $(uname -m)" ;;
    esac
    echo "==> Letting this $(uname -m) machine run $foreign code"
    docker run --privileged --rm "$BINFMT" --install "$foreign"
    BUILDER="udeck-plugin-$$"
    docker buildx create --name "$BUILDER" --driver docker-container --driver-opt "image=$BUILDKIT" --bootstrap

    # What goes into the image and how it is said, the same in every build
    # below. No provenance attestation and no SBOM: the index holds exactly the
    # two images people run, which every registry and every copy by digest
    # — a mirror of it on a GitLab — reads as it is. Attestations are a
    # decision of their own, not one to take in passing.
    local build=(docker buildx build --builder "$BUILDER" --file "$context/Dockerfile"
                 --build-arg "VERSION=$version" --build-arg "REVISION=$REVISION"
                 --provenance=false --sbom=false)
    local index=(--platform "$PLATFORMS"
                 --annotation "index:org.opencontainers.image.description=$description"
                 --annotation "index:org.opencontainers.image.source=https://github.com/iillyyaa1997/udeck"
                 --annotation "index:org.opencontainers.image.version=$version"
                 --annotation "index:org.opencontainers.image.licenses=Apache-2.0")

    echo "==> Building $tag for $PLATFORMS"
    "${build[@]}" "${index[@]}" --output "type=oci,dest=$SCRATCH/image.oci.tar" \
        --metadata-file "$SCRATCH/built.json" "$context"
    local built
    built="$(digest_in "$SCRATCH/built.json" optional)"
    echo "==> Built for $PLATFORMS: an index of digest ${built:-(BuildKit said none)}, not published"

    local platform arch
    for platform in linux/amd64 linux/arm64; do
        arch="${platform#linux/}"
        "${build[@]}" --platform "$platform" --load --tag "udeck-plugin-check:$arch" "$context"
        echo "==> $platform: $(docker image inspect --format '{{.Size}}' "udeck-plugin-check:$arch") bytes"
        check_image "udeck-plugin-check:$arch" "$platform" "$version"
        docker image rm "udeck-plugin-check:$arch" >/dev/null
    done

    if [ "$PUSH" != "1" ]; then
        echo "==> Not published: $tag would be pushed with --push"
        return
    fi
    echo "==> Publishing $tag"
    "${build[@]}" "${index[@]}" --push --tag "$tag" --metadata-file "$SCRATCH/pushed.json" "$context"
    local digest
    digest="$(digest_in "$SCRATCH/pushed.json")"
    # Read back from the registry: the digest names an index of both platforms.
    docker buildx imagetools inspect --raw "$IMAGE_REPOSITORY@$digest" > "$SCRATCH/index.json"
    for arch in amd64 arm64; do
        grep -q "\"architecture\": *\"$arch\"" "$SCRATCH/index.json" \
            || fail "$IMAGE_REPOSITORY@$digest has no linux/$arch image: $(cat "$SCRATCH/index.json")"
    done
    {
        echo "image=$IMAGE_REPOSITORY"
        echo "tag=v$version"
        echo "digest=$digest"
        echo "platforms=$PLATFORMS"
    } > "$OUT/udeck-plugin-image.txt"
    echo "==> Published $IMAGE_REPOSITORY@$digest ($tag); $OUT/udeck-plugin-image.txt:"
    cat "$OUT/udeck-plugin-image.txt"
}

# The digest BuildKit reports for what it built, from its metadata file —
# required, unless `optional` says an empty answer will do.
digest_in() {
    local digest
    digest="$(sed -n 's/.*"containerimage\.digest": *"\(sha256:[0-9a-f]\{64\}\)".*/\1/p' "$1" | head -1)"
    if [ -z "$digest" ] && [ "${2-}" != "optional" ]; then
        fail "no image digest in $1: $(cat "$1")"
    fi
    echo "$digest"
}

case "$WHAT" in
    macos) build_macos ;;
    linux) build_linux ;;
    sums) write_sums ;;
    image) build_image ;;
esac
