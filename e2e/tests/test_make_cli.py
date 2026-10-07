"""`Scripts/make-cli.sh` and the two workflows that run it, against a toy checkout.

What the script builds is the expensive half and needs a Swift toolchain, a
Static Linux SDK or Docker; what it decides is the other half — which binary
goes into which archive, what it must say of itself, what is refused, what the
image is run with before anything is pushed, and what is pushed. So the
builders are stubbed and the rest runs as it does in earnest: on a Mac, lipo
and codesign on real Mach-O binaries compiled here.

The workflows are read as text: a release publishes once and cannot take an
asset back, so what it may do — and in which order — is held here, on every
push, before a tag tries it.
"""

import hashlib
import io
import json
import os
import platform
import re
import shutil
import subprocess
import tarfile
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[2]
VERSION = "9.9.9"
BUILT = "sha256:" + "b" * 64
OTHER = "sha256:" + "c" * 64
STAGE = "localhost:5000/udeck-plugin"
GHCR = "ghcr.io/iillyyaa1997/udeck-plugin"
ON_A_MAC = platform.system() == "Darwin"
CONTENTS = ("LICENSE", "NOTICE", "THIRD_PARTY_NOTICES", "udeck-plugin")


def executable(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
    path.chmod(0o755)


@pytest.fixture
def checkout(tmp_path):
    """A directory shaped like the repository, as far as the script reads it."""
    root = tmp_path / "udeck"
    (root / "Scripts").mkdir(parents=True)
    for name in ("make-cli.sh", "udeck-plugin.Dockerfile", "adhoc.entitlements"):
        shutil.copy(REPO / "Scripts" / name, root / "Scripts" / name)
    for name in ("LICENSE", "NOTICE"):
        shutil.copy(REPO / name, root / name)
    (root / "Scripts" / "third-party").mkdir()
    shutil.copy(REPO / "Scripts" / "third-party" / "THIRD_PARTY_NOTICES", root / "Scripts" / "third-party")
    for example in ("first", "second"):
        (root / "examples" / example).mkdir(parents=True)
    (root / "stubs").mkdir()
    (tmp_path / "tmp").mkdir()
    return root


def make_cli(checkout, *args, **env):
    return subprocess.run(
        [str(checkout / "Scripts" / "make-cli.sh"), *args],
        capture_output=True,
        text=True,
        timeout=180,
        cwd=str(checkout),
        env={
            **os.environ,
            "PATH": f"{checkout / 'stubs'}:{os.environ['PATH']}",
            "TMPDIR": str(checkout.parent / "tmp"),
            **env,
        },
    )


def left_behind(checkout):
    """What the script left in its temporary folder: nothing, however it ended."""
    return sorted(p.name for p in (checkout.parent / "tmp").iterdir())


def members(archive):
    with tarfile.open(archive) as tar:
        return {m.name: m for m in tar.getmembers()}


def clean_records(archive, folder):
    """Every record, as any tar finds it: the folder and its four files, owned by 0:0, and no pax key."""
    found = members(archive)
    assert sorted(found) == [folder] + [f"{folder}/{name}" for name in CONTENTS], sorted(found)
    assert {(m.uid, m.gid) for m in found.values()} == {(0, 0)}, "nothing of the machine it was made on"
    assert {name: dict(m.pax_headers) for name, m in found.items() if m.pax_headers} == {}
    assert found[f"{folder}/udeck-plugin"].mode & 0o777 == 0o755
    for name in ("LICENSE", "NOTICE", "THIRD_PARTY_NOTICES"):
        assert found[f"{folder}/{name}"].mode & 0o777 == 0o644, name
    return found


# --- macos --------------------------------------------------------------------------------------


def compile_command(path, arch, version=VERSION):
    """A real Mach-O for `arch` that answers --version as udeck-plugin does."""
    source = path.parent / f"udeck-plugin-{arch}.c"
    path.parent.mkdir(parents=True, exist_ok=True)
    source.write_text(
        "#include <stdio.h>\n#include <string.h>\n"
        "int main(int argc, char **argv) {\n"
        '  if (argc > 1 && strcmp(argv[1], "--version") == 0) { printf("udeck-plugin %s\\n", VERSION); return 0; }\n'
        "  return 2;\n}\n"
    )
    done = subprocess.run(
        ["cc", "-arch", arch, f'-DVERSION="{version}"', "-o", str(path), str(source)],
        capture_output=True, text=True,
    )  # fmt: skip
    if done.returncode != 0:
        pytest.skip(f"cannot compile for {arch} here: {done.stderr.strip()}")


@pytest.fixture
def mac(checkout):
    """swift stubbed: each --arch build puts its prebuilt binary at ONE path.

    As Swift 6.4's default build system does (measured: the x86_64 build
    overwrote the arm64 one), so that a script taking the slices from where
    the builds leave them would join one architecture with itself.
    """
    if not ON_A_MAC:
        pytest.skip("lipo and codesign are a Mac's")
    prebuilt = checkout / "prebuilt"
    for arch in ("arm64", "x86_64"):
        compile_command(prebuilt / arch, arch)
    executable(checkout / "stubs" / "swift", f"""#!/bin/sh
arch=""
show=0
while [ $# -gt 0 ]; do
    case "$1" in
        --arch) arch="$2"; shift 2 ;;
        --show-bin-path) show=1; shift ;;
        *) shift ;;
    esac
done
out="$PWD/Packages/UDeckPluginFormat/.build/out/Products/Release"
if [ "$show" = 1 ]; then echo "$out"; exit 0; fi
mkdir -p "$out"
cp "{prebuilt}/${{FAKE_SLICE:-$arch}}" "$out/udeck-plugin"
""")
    return checkout


def test_a_mac_archive_holds_one_universal_command_signed_as_the_one_inside_udeck_app(mac):
    done = make_cli(mac, "macos", "--version", VERSION, "--out", "out")
    assert done.returncode == 0, done.stdout + done.stderr
    archive = mac / "out" / f"udeck-plugin-{VERSION}-macos-universal.tar.gz"
    assert sorted(p.name for p in (mac / "out").iterdir()) == [archive.name]
    folder = f"udeck-plugin-{VERSION}-macos-universal"
    clean_records(archive, folder)

    unpacked = mac / "unpacked"
    with tarfile.open(archive) as tar:
        tar.extractall(unpacked, filter="tar")
    binary = unpacked / folder / "udeck-plugin"
    assert set(subprocess.run(["lipo", "-archs", str(binary)], capture_output=True, text=True).stdout.split()) == {"arm64", "x86_64"}
    shown = subprocess.run(["codesign", "-dv", "--entitlements", "-", str(binary)], capture_output=True, text=True)
    assert "flags=0x10002(adhoc,runtime)" in shown.stderr, shown.stderr
    assert "com.apple.security.cs.disable-library-validation" in shown.stdout + shown.stderr
    assert subprocess.run(["codesign", "--verify", "--strict", str(binary)]).returncode == 0
    assert subprocess.run([str(binary), "--version"], capture_output=True, text=True).stdout == f"udeck-plugin {VERSION}\n"
    assert "udeck-plugin 9.9.9 for macOS" in done.stdout
    assert left_behind(mac) == []


def test_a_mac_archive_carries_no_extended_attribute_and_no_appledouble_record_of_the_files_it_was_made_from(mac):
    # As every file a Mac has downloaded carries com.apple.provenance: bsdtar
    # stores such an attribute as a pax record and an AppleDouble ._ file, and
    # lists neither — another machine's tar unpacks both.
    for name in ("LICENSE", "NOTICE", "Scripts/third-party/THIRD_PARTY_NOTICES"):
        subprocess.run(["xattr", "-w", "com.example.udeck-tests", "made here", str(mac / name)], check=True)
    assert "com.example.udeck-tests" in subprocess.run(["xattr", str(mac / "LICENSE")], capture_output=True, text=True).stdout
    done = make_cli(mac, "macos", "--version", VERSION, "--out", "out")
    assert done.returncode == 0, done.stdout + done.stderr
    folder = f"udeck-plugin-{VERSION}-macos-universal"
    found = clean_records(mac / "out" / f"{folder}.tar.gz", folder)
    assert found[f"{folder}/THIRD_PARTY_NOTICES"].size == (REPO / "Scripts" / "third-party" / "THIRD_PARTY_NOTICES").stat().st_size


def test_an_archive_that_took_a_macs_attributes_all_the_same_is_refused_and_not_left_behind(mac):
    # A tar that ignores what it is told: the archive is read back record by
    # record, not listed by bsdtar, which would show none of what went in.
    subprocess.run(["xattr", "-w", "com.example.udeck-tests", "made here", str(mac / "LICENSE")], check=True)
    executable(mac / "stubs" / "tar", """#!/bin/sh
for arg in "$@"; do
    shift
    case "$arg" in --no-*) ;; *) set -- "$@" "$arg" ;; esac
done
unset COPYFILE_DISABLE
exec /usr/bin/tar "$@"
""")
    done = make_cli(mac, "macos", "--version", VERSION, "--out", "out")
    assert done.returncode == 1, done.stdout + done.stderr
    assert "does not hold exactly the command, LICENSE, NOTICE and THIRD_PARTY_NOTICES" in done.stderr
    assert "._LICENSE" in done.stderr and "SCHILY.xattr.com.example.udeck-tests" in done.stderr
    assert left_behind(mac) == []


def test_without_a_version_the_archive_is_named_by_what_the_command_says(mac):
    done = make_cli(mac, "macos", "--out", "out")
    assert done.returncode == 0, done.stdout + done.stderr
    assert (mac / "out" / f"udeck-plugin-{VERSION}-macos-universal.tar.gz").is_file()


def test_a_command_that_says_another_version_than_the_release_is_refused_and_nothing_is_archived(mac):
    done = make_cli(mac, "macos", "--version", "9.9.8", "--out", "out")
    assert done.returncode == 1
    assert "this release is 9.9.8" in done.stderr
    assert list((mac / "out").iterdir()) == []
    assert left_behind(mac) == []


def test_a_build_that_made_the_same_architecture_twice_is_refused(mac):
    done = make_cli(mac, "macos", "--out", "out", FAKE_SLICE="arm64")
    assert done.returncode == 1
    assert "the x86_64 build made a binary for arm64" in done.stderr
    assert list((mac / "out").iterdir()) == []


# --- linux --------------------------------------------------------------------------------------

PADDING = "# padding a linker leaves and strip takes away\n" * 400


@pytest.fixture
def linux(checkout):
    """A Linux of `FAKE_MACHINE`, a Static Linux SDK build, strip and readelf, all stubbed."""
    stubs = checkout / "stubs"
    executable(checkout / "prebuilt" / "linux", f'#!/bin/sh\n[ "$1" = --version ] && echo "udeck-plugin ${{FAKE_SAYS:-{VERSION}}}"\n{PADDING}')
    executable(stubs / "uname", '#!/bin/sh\ncase "$1" in -s) echo Linux ;; -m) echo "${FAKE_MACHINE:-x86_64}" ;; esac\n')
    executable(stubs / "swift", f"""#!/bin/sh
for arg in "$@"; do
    if [ "$arg" = --show-bin-path ]; then echo "$PWD/.build/linux"; exit 0; fi
done
echo "$*" >> "$PWD/swift-calls.txt"
mkdir -p "$PWD/.build/linux"
cp "{checkout / 'prebuilt' / 'linux'}" "$PWD/.build/linux/udeck-plugin"
""")
    executable(stubs / "strip", "#!/bin/sh\nsed '/^# padding/d' \"$1\" > \"$1.stripped\" && cat \"$1.stripped\" > \"$1\" && rm \"$1.stripped\"\n")
    executable(stubs / "readelf", """#!/bin/sh
case "$1" in
    -h) echo "  Machine:                           ${FAKE_ELF:-Advanced Micro Devices X86-64}" ;;
    -l) [ "${FAKE_INTERP:-0}" = 1 ] && echo "  INTERP         0x0000000000000318" ;;
    -d) [ "${FAKE_NEEDED:-0}" = 1 ] && echo " 0x0000000000000001 (NEEDED)             Shared library: [libc.so.6]" ;;
esac
exit 0
""")
    return checkout


def test_a_linux_archive_holds_the_stripped_static_command_and_says_both_sizes(linux):
    done = make_cli(linux, "linux", "--arch", "x86_64", "--version", VERSION, "--out", "out")
    assert done.returncode == 0, done.stdout + done.stderr
    calls = (linux / "swift-calls.txt").read_text()
    assert "--build-system native" in calls and "--swift-sdk x86_64-swift-linux-musl" in calls
    assert "--package-path Packages/UDeckPluginFormat --product udeck-plugin" in calls
    archive = linux / "out" / f"udeck-plugin-{VERSION}-linux-x86_64.tar.gz"
    folder = f"udeck-plugin-{VERSION}-linux-x86_64"
    found = clean_records(archive, folder)
    linked = (linux / "prebuilt" / "linux").stat().st_size
    shipped = found[f"{folder}/udeck-plugin"].size
    assert shipped < linked, "the archive holds the stripped binary"
    assert f"{linked} bytes as linked, {shipped} stripped" in done.stdout
    assert left_behind(linux) == []


@pytest.mark.parametrize(
    ("env", "said"),
    [
        ({"FAKE_INTERP": "1"}, "asks for a dynamic loader"),
        ({"FAKE_NEEDED": "1"}, "needs shared libraries"),
        ({"FAKE_ELF": "AArch64"}, "is not built for x86_64"),
        ({"FAKE_SAYS": "9.9.8"}, "this release is 9.9.9"),
        ({"FAKE_MACHINE": "aarch64"}, "builds on an x86_64 machine"),
    ],
)
def test_a_binary_that_is_not_what_a_release_ships_is_refused_and_nothing_is_archived(linux, env, said):
    done = make_cli(linux, "linux", "--arch", "x86_64", "--version", VERSION, "--out", "out", **env)
    assert done.returncode == 1, done.stdout + done.stderr
    assert said in done.stderr
    assert list((linux / "out").iterdir()) == []
    assert left_behind(linux) == []


def test_requests_that_make_no_sense_are_refused_with_how_to_ask(checkout):
    for args, said in (
        (["linux"], "needs --arch"),
        (["linux", "--arch", "riscv64"], "x86_64 or aarch64"),
        (["release"], "unknown command"),
        (["sums", "--version", "1.2"], "is not X.Y.Z"),
        (["sums", "--out", ""], "--out needs a directory"),
        (["image", "--what"], "unknown option"),
        (["publish"], "unknown command"),
        ([], "Usage:"),
    ):
        done = make_cli(checkout, *args)
        assert done.returncode == 2, (args, done.stdout, done.stderr)
        assert said in done.stderr, (args, done.stderr)


# --- the image file, sums and notes -------------------------------------------------------------


def image_file(image=GHCR, version=VERSION, digest=BUILT, platforms="linux/amd64,linux/arm64"):
    return f"image={image}\ntag=v{version}\ndigest={digest}\nplatforms={platforms}\n"


def real_archive(out, version=VERSION, name="linux-x86_64", extra=None, uid=0):
    """An archive as make-cli makes one, or — with `extra` — with a record more, or a pax key on one."""
    out.mkdir(parents=True, exist_ok=True)
    folder = f"udeck-plugin-{version}-{name}"
    archive = out / f"{folder}.tar.gz"
    with tarfile.open(archive, "w:gz", format=tarfile.PAX_FORMAT if extra == "xattr" else tarfile.GNU_FORMAT) as tar:
        def add(member_name, data=None, mode=0o644, pax=None):
            info = tarfile.TarInfo(member_name)
            info.uid = info.gid = 0
            if member_name == f"{folder}/LICENSE":
                info.uid = uid
            if data is None:
                info.type, info.mode = tarfile.DIRTYPE, 0o755
                tar.addfile(info)
                return
            info.mode, info.size = mode, len(data)
            if pax:
                info.pax_headers = pax
            tar.addfile(info, io.BytesIO(data))

        add(folder)
        for content in CONTENTS:
            pax = {"SCHILY.xattr.com.apple.provenance": "made on a Mac"} if extra == "xattr" and content == "LICENSE" else None
            add(f"{folder}/{content}", f"{content} {version} {name}\n".encode(), 0o755 if content == "udeck-plugin" else 0o644, pax)
        if extra == "appledouble":
            add(f"{folder}/._LICENSE", b"\x00\x05\x16\x07")
    return archive


def release_set(out, version=VERSION, image=GHCR):
    for name in ("macos-universal", "linux-x86_64", "linux-aarch64"):
        real_archive(out, version, name)
    (out / "udeck-plugin-image.txt").write_text(image_file(image, version))


def test_sums_cover_the_three_archives_and_the_image_and_say_what_sha256sum_says(checkout):
    out = checkout / "out"
    release_set(out)
    (out / "notes.md").write_text("not an asset\n")
    (out / "udeck-plugin-staged.txt").write_text(image_file(STAGE))
    done = make_cli(checkout, "sums", "--version", VERSION, "--out", "out")
    assert done.returncode == 0, done.stdout + done.stderr
    expected = "".join(
        f"{hashlib.sha256((out / name).read_bytes()).hexdigest()}  {name}\n"
        for name in (
            f"udeck-plugin-{VERSION}-macos-universal.tar.gz",
            f"udeck-plugin-{VERSION}-linux-x86_64.tar.gz",
            f"udeck-plugin-{VERSION}-linux-aarch64.tar.gz",
            "udeck-plugin-image.txt",
        )
    )
    assert (out / "SHA256SUMS").read_text() == expected


@pytest.mark.parametrize(
    ("arrange", "said"),
    [
        (lambda out: (release_set(out), (out / f"udeck-plugin-{VERSION}-linux-aarch64.tar.gz").unlink()), "no udeck-plugin-9.9.9-linux-aarch64"),
        (lambda out: (release_set(out), real_archive(out, "9.9.8")), "more than one version"),
        (lambda out: (release_set(out), real_archive(out, name="linux-riscv64")), "no release names"),
        (lambda out: release_set(out, "9.9.8"), "this release is 9.9.9"),
        (lambda out: out.mkdir(), "no udeck-plugin archive"),
        (lambda out: (release_set(out), (out / "udeck-plugin-image.txt").unlink()), "no udeck-plugin-image.txt"),
        (lambda out: (release_set(out), (out / "udeck-plugin-image.txt").write_text(image_file(version="9.9.8"))), "is of v9.9.8"),
        (lambda out: (release_set(out), (out / "udeck-plugin-image.txt").write_text(image_file(STAGE))), "udeck-plugin-image.txt says"),
        (lambda out: (release_set(out), real_archive(out, extra="appledouble")), "._LICENSE"),
        (lambda out: (release_set(out), real_archive(out, name="macos-universal", extra="xattr")), "SCHILY.xattr.com.apple.provenance"),
        (lambda out: (release_set(out), real_archive(out, uid=501)), " 501 0 "),
    ],
)  # fmt: skip
def test_sums_refuse_a_set_a_release_would_not_publish(checkout, arrange, said):
    arrange(checkout / "out")
    done = make_cli(checkout, "sums", "--version", VERSION, "--out", "out")
    assert done.returncode == 1, done.stdout + done.stderr
    assert said in done.stderr
    assert not (checkout / "out" / "SHA256SUMS").exists()


def test_notes_name_the_image_by_its_digest_first(checkout):
    out = checkout / "out"
    out.mkdir()
    (out / "udeck-plugin-image.txt").write_text(image_file())
    done = make_cli(checkout, "notes", "--version", VERSION, "--out", "out")
    assert done.returncode == 0, done.stdout + done.stderr
    notes = (out / "notes.md").read_text()
    assert notes.startswith("**udeck-plugin** for a plugin repository's CI")
    assert f"\n    {GHCR}@{BUILT}\n" in notes
    assert "THIRD_PARTY_NOTICES" in notes


@pytest.mark.parametrize(
    ("text", "said"),
    [
        # The release's guard once read `test -n "$digest" && test -n "$image"`,
        # which under `set -e` went on to `gh release create` with a digest of
        # sha256:short: the notes said `image@` and nothing after it.
        (image_file(digest="sha256:short"), "no line digest=sha256:<64 hexadecimal digits>"),
        (image_file(digest=""), "no line digest="),
        (image_file().replace("tag=v9.9.9\n", ""), "no line tag=vX.Y.Z"),
        (image_file(image=""), "udeck-plugin-image.txt says"),
        (image_file(image="ghcr.io/somebody/else"), "udeck-plugin-image.txt says"),
        (image_file(platforms="linux/amd64"), "udeck-plugin-image.txt says"),
        (image_file() + f"digest={OTHER}\n", "udeck-plugin-image.txt says"),
        (image_file(version="9.9.8"), "is of v9.9.8; this release is 9.9.9"),
        (None, "no udeck-plugin-image.txt"),
    ],
)
def test_notes_refuse_an_image_file_that_is_not_what_push_writes(checkout, text, said):
    out = checkout / "out"
    out.mkdir()
    if text is not None:
        (out / "udeck-plugin-image.txt").write_text(text)
    done = make_cli(checkout, "notes", "--version", VERSION, "--out", "out")
    assert done.returncode == 1, done.stdout + done.stderr
    assert said in done.stderr
    assert not (out / "notes.md").exists()


# --- image and push -----------------------------------------------------------------------------

DOCKER = r"""#!/bin/sh
# One line a call, a script given to `sh -c` included.
printf '%s\n' "$*" | tr '\n' ' ' | sed 's/ *$//' >> "$DOCKER_LOG"
echo >> "$DOCKER_LOG"
case "$1 $2" in
    "buildx build")
        metadata=""
        previous=""
        for arg in "$@"; do
            [ "$previous" = "--metadata-file" ] && metadata="$arg"
            previous="$arg"
            context="$arg"
        done
        mkdir -p "$DOCKER_SEEN"
        for name in amd64/udeck-plugin arm64/udeck-plugin Dockerfile THIRD_PARTY_NOTICES LICENSE NOTICE; do
            cp "$context/$name" "$DOCKER_SEEN/$(echo "$name" | tr / -)"
        done
        if [ -n "$metadata" ]; then
            printf '{\n  "buildx.build.ref": "x",\n  "containerimage.digest": "%s"\n}\n' "${FAKE_BUILT-sha256:BUILT}" > "$metadata"
        fi
        exit 0 ;;
    "buildx imagetools")
        case "$3" in
            create) exit "${FAKE_CREATE:-0}" ;;
            inspect)
                if [ "$4" = --raw ]; then
                    echo '{"schemaVersion":2,"mediaType":"'"${FAKE_MEDIA:-application/vnd.oci.image.index.v1+json}"'","manifests":[{"platform":{"architecture":"amd64","os":"linux"}},{"platform":{"architecture":"'"${FAKE_SECOND:-arm64}"'","os":"linux"}}]}'
                else
                    printf 'Name:      %s\nMediaType: application/vnd.oci.image.index.v1+json\nDigest:    %s\n\nManifests:\n' "$4" "${FAKE_TAG:-sha256:BUILT}"
                fi
                exit 0 ;;
        esac ;;
esac
case "$1" in pull|image) exit 0 ;; esac
if [ "$1" = run ]; then
    case "$*" in
        *"--privileged"*) exit 0 ;;
    esac
    platform=""
    previous=""
    for arg in "$@"; do
        [ "$previous" = "--platform" ] && platform="$arg"
        previous="$arg"
    done
    says="${FAKE_SAYS:-9.9.9}"
    [ "$platform" = linux/arm64 ] && says="${FAKE_ARM64_SAYS:-$says}"
    case "$*" in
        *"/lib/apk/db/installed"*) printf '%s\n' GPL-2.0-only MIT "${FAKE_LICENSE:-curl}" ;;
        *"cd /usr/share/licenses/udeck-plugin"*) exit "${FAKE_NO_NOTICES:-0}" ;;
        *"udeck-plugin --version"*) echo "udeck-plugin $says" ;;
        *"udeck-plugin --help"*) echo "usage: udeck-plugin check [--strict] <folder>..." ;;
        *"git --version"*) echo "git version 2.52.0" ;;
        *"check --strict /udeck/examples"*)
            echo "checked /udeck/examples/first/ at 0123456789ab strictly: 0 errors, 0 warnings"
            [ "${FAKE_ONE_EXAMPLE:-0}" = 1 ] || echo "checked /udeck/examples/second/ at 0123456789ab strictly: 0 errors, 0 warnings" ;;
        *"check-repo"*) exit "${FAKE_CHECK_REPO:-0}" ;;
    esac
    exit 0
fi
exit 0
""".replace("sha256:BUILT", BUILT)

LABEL = (
    "Apache-2.0 AND Apache-2.0 WITH Swift-exception AND Apache-2.0 WITH LLVM-exception AND MIT AND BSD-3-Clause"
    " AND (BSD-3-Clause OR GPL-2.0-or-later) AND curl AND GPL-2.0-only AND (GPL-2.0-or-later OR LGPL-3.0-or-later)"
    " AND (MIT AND BSD-2-Clause AND GPL-2.0-or-later) AND (MPL-2.0 AND MIT) AND Zlib"
)


@pytest.fixture
def image(checkout):
    """Docker stubbed — every call logged — on an x86_64 machine, with the two Linux archives."""
    executable(checkout / "stubs" / "docker", DOCKER)
    executable(checkout / "stubs" / "uname", '#!/bin/sh\ncase "$1" in -s) echo Linux ;; -m) echo x86_64 ;; esac\n')
    out = checkout / "out"
    for arch in ("x86_64", "aarch64"):
        folder = checkout / "made" / f"udeck-plugin-{VERSION}-linux-{arch}"
        executable(folder / "udeck-plugin", f"#!/bin/sh\necho the {arch} binary\n")
        for name in ("LICENSE", "NOTICE"):
            shutil.copy(checkout / name, folder / name)
        out.mkdir(exist_ok=True)
        with tarfile.open(out / f"{folder.name}.tar.gz", "w:gz") as tar:
            tar.add(folder, arcname=folder.name)
    return checkout


def run_docker(checkout, *args, **env):
    log = checkout / "docker.log"
    log.unlink(missing_ok=True)
    done = make_cli(checkout, *args, DOCKER_LOG=str(log), DOCKER_SEEN=str(checkout / "seen"), **env)
    calls = log.read_text().splitlines() if log.exists() else []
    return done, calls


def run_image(checkout, *args, **env):
    return run_docker(checkout, "image", "--out", "out", "--revision", "c0ffee", *args, **env)


def test_an_image_is_built_once_pushed_to_the_jobs_registry_and_run_from_it_by_its_digest(image):
    done, calls = run_image(image)
    assert done.returncode == 0, done.stdout + done.stderr
    assert not any("login" in call or "imagetools create" in call or "ghcr.io" in call for call in calls), calls
    assert not (image / "out" / "udeck-plugin-image.txt").exists()
    binfmt = [i for i, call in enumerate(calls) if call.startswith("run --privileged --rm tonistiigi/binfmt:")]
    assert len(binfmt) == 1 and calls[binfmt[0]].endswith("--install arm64")
    create = [call for call in calls if call.startswith("buildx create ")]
    assert len(create) == 1 and "--driver-opt network=host" in create[0] and "--driver-opt image=moby/buildkit:" in create[0]
    builds = [i for i, call in enumerate(calls) if call.startswith("buildx build")]
    assert len(builds) == 1, "built once: what is pushed is what ran"
    build = calls[builds[0]]
    assert f"--output type=image,name={STAGE}:v{VERSION},push=true,oci-mediatypes=true" in build
    assert "--platform linux/amd64,linux/arm64" in build and "--provenance=false" in build and "--sbom=false" in build
    assert "--build-arg VERSION=9.9.9" in build and "--build-arg REVISION=c0ffee" in build
    assert f"--build-arg LICENSES={LABEL} " in build and f"index:org.opencontainers.image.licenses={LABEL} " in build
    assert "index:org.opencontainers.image.source=https://github.com/iillyyaa1997/udeck" in build
    ref = f"{STAGE}@{BUILT}"
    inspect = calls.index(f"buildx imagetools inspect --raw {ref}")
    assert builds[0] < inspect
    for platform in ("linux/amd64", "linux/arm64"):
        pulled = calls.index(f"pull --platform {platform} {ref}")
        runs = [i for i, call in enumerate(calls) if call.startswith(f"run --rm --network none --platform {platform} ")]
        assert inspect < pulled < min(runs), platform
        ran = [calls[i] for i in runs]
        assert all(f" {ref} " in call for call in ran), "run from the registry, by the digest"
        assert any("udeck-plugin --version" in call for call in ran), platform
        assert any("/lib/apk/db/installed" in call for call in ran), platform
        notices = [call for call in ran if "cd /usr/share/licenses/udeck-plugin" in call]
        assert len(notices) == 1, platform
        for looked_for in ("test -s LICENSE", "test -s NOTICE", "test -s THIRD_PARTY_NOTICES", 'grep -q "^git " ALPINE-PACKAGES'):
            assert looked_for in notices[0], (platform, looked_for)
        assert any("check --strict /udeck/examples/" in call and ":/udeck:ro" in call for call in ran), platform
        assert any("check-repo" in call and ":/examples:ro" in call for call in ran), platform
    # The binaries the image is built from are the ones the archives carry.
    for arch, platform in (("x86_64", "amd64"), ("aarch64", "arm64")):
        assert (image / "seen" / f"{platform}-udeck-plugin").read_text() == f"#!/bin/sh\necho the {arch} binary\n"
    assert (image / "seen" / "Dockerfile").read_text() == (REPO / "Scripts" / "udeck-plugin.Dockerfile").read_text()
    assert (image / "seen" / "THIRD_PARTY_NOTICES").read_bytes() == (REPO / "Scripts" / "third-party" / "THIRD_PARTY_NOTICES").read_bytes()
    assert (image / "out" / "udeck-plugin-staged.txt").read_text() == image_file(STAGE)
    assert left_behind(image) == []
    assert any(call.startswith("buildx rm --force udeck-plugin-") for call in calls), "the builder is taken away"


@pytest.mark.parametrize(
    ("env", "said"),
    [
        ({"FAKE_BUILT": ""}, "no image digest in"),
        ({"FAKE_BUILT": "sha256:short"}, "no image digest in"),
        ({"FAKE_SECOND": "s390x"}, "has no linux/arm64 image"),
        ({"FAKE_MEDIA": "application/vnd.docker.distribution.manifest.list.v2+json"}, "is not an OCI image index"),
        ({"FAKE_ARM64_SAYS": "9.9.8"}, "in the image (linux/arm64) udeck-plugin says"),
        ({"FAKE_ONE_EXAMPLE": "1"}, "1 of 2 examples checked clean"),
        ({"FAKE_CHECK_REPO": "1"}, "check-repo on a repository made in the image"),
        ({"FAKE_LICENSE": "GPL-3.0-only"}, 'under "GPL-3.0-only", which its licenses label does not name'),
        ({"FAKE_NO_NOTICES": "1"}, "lacks its licences, its notices or the list of its Alpine packages"),
    ],
)
def test_an_image_that_does_not_do_its_work_on_either_platform_is_never_staged(image, env, said):
    done, calls = run_image(image, "--version", VERSION, **env)
    assert done.returncode == 1, done.stdout + done.stderr
    assert said in done.stderr
    assert not (image / "out" / "udeck-plugin-staged.txt").exists()
    assert left_behind(image) == []


def test_an_image_of_another_version_than_the_release_is_refused_before_anything_runs(image):
    done, calls = run_image(image, "--version", "9.9.8")
    assert done.returncode == 1 and "this release is 9.9.8" in done.stderr
    assert calls == []


def staged(checkout, text=None):
    out = checkout / "out"
    out.mkdir(exist_ok=True)
    (out / "udeck-plugin-staged.txt").write_text(image_file(STAGE) if text is None else text)


def test_push_copies_the_index_that_ran_by_its_digest_and_writes_the_image_file(image):
    staged(image)
    done, calls = run_docker(image, "push", "--version", VERSION, "--out", "out")
    assert done.returncode == 0, done.stdout + done.stderr
    assert calls == [
        f"buildx imagetools create --tag {GHCR}:v{VERSION} {STAGE}@{BUILT}",
        f"buildx imagetools inspect {GHCR}:v{VERSION}",
        f"buildx imagetools inspect --raw {GHCR}@{BUILT}",
    ], "copied, never built again, and read back"
    assert (image / "out" / "udeck-plugin-image.txt").read_text() == image_file()


def test_push_writes_where_it_was_told_to_copy_as_ci_does(image):
    staged(image)
    done, _ = run_docker(image, "push", "--out", "out", "--repository", "localhost:5000/iillyyaa1997/udeck-plugin")
    assert done.returncode == 0, done.stdout + done.stderr
    assert (image / "out" / "udeck-plugin-image.txt").read_text() == image_file("localhost:5000/iillyyaa1997/udeck-plugin")


@pytest.mark.parametrize(
    ("staged_text", "env", "said"),
    [
        (None, {"FAKE_TAG": OTHER}, f"not {BUILT}, which ran"),
        (None, {"FAKE_SECOND": "s390x"}, "has no linux/arm64 image"),
        (None, {"FAKE_CREATE": "1"}, ""),
        (image_file("elsewhere/udeck-plugin"), {}, "udeck-plugin-staged.txt says"),
        (image_file(STAGE, "9.9.8"), {}, "is of v9.9.8; this release is 9.9.9"),
        (image_file(STAGE, digest="sha256:short"), {}, "no line digest="),
    ],
)
def test_push_refuses_what_did_not_run_or_did_not_arrive_and_writes_no_image_file(image, staged_text, env, said):
    staged(image, staged_text)
    done, _ = run_docker(image, "push", "--version", VERSION, "--out", "out", **env)
    assert done.returncode != 0, done.stdout + done.stderr
    assert said in done.stderr
    assert not (image / "out" / "udeck-plugin-image.txt").exists()


def test_push_without_an_image_that_ran_does_nothing(image):
    done, calls = run_docker(image, "push", "--out", "out")
    assert done.returncode == 1 and "no udeck-plugin-staged.txt" in done.stderr
    assert calls == []


def test_the_image_and_what_builds_it_are_pinned_by_digest_and_say_where_they_come_from():
    dockerfile = (REPO / "Scripts" / "udeck-plugin.Dockerfile").read_text()
    assert re.search(r"^FROM alpine:[0-9.]+@sha256:[0-9a-f]{64}$", dockerfile, re.M), "the base by digest"
    assert re.search(r"^apk add --no-cache git$", dockerfile, re.M), "check and check-repo start git"
    assert not re.search(r"^ENTRYPOINT", dockerfile, re.M), "GitLab CI hands the job's script to the image's shell"
    for label in ('source="https://github.com/iillyyaa1997/udeck"', 'version="${VERSION}"', 'licenses="${LICENSES}"'):
        assert f"org.opencontainers.image.{label}" in dockerfile
    assert "COPY LICENSE NOTICE THIRD_PARTY_NOTICES /usr/share/licenses/udeck-plugin/" in dockerfile
    assert "/lib/apk/db/installed | sort > /usr/share/licenses/udeck-plugin/ALPINE-PACKAGES" in dockerfile
    script = (REPO / "Scripts" / "make-cli.sh").read_text()
    for name in ("BUILDKIT", "BINFMT"):
        assert re.search(rf'^{name}="[a-z/]+:[A-Za-z0-9.-]+@sha256:[0-9a-f]{{64}}"$', script, re.M), name


def test_the_notices_name_every_package_the_command_is_built_with():
    notices = (REPO / "Scripts" / "third-party" / "THIRD_PARTY_NOTICES").read_text()
    resolved = json.loads((REPO / "Packages" / "UDeckPluginFormat" / "Package.resolved").read_text())
    for pin in resolved["pins"]:
        assert pin["identity"] in notices, f"{pin['identity']} is in Package.resolved and not in THIRD_PARTY_NOTICES"
        if pin["identity"] == "swift-crypto":
            assert f"swift-crypto {pin['state']['version']} (revision {pin['state']['revision']})" in notices
    for component in ("musl", "mimalloc", "fts", "BoringSSL", "libdispatch", "swift-foundation", "libc++"):
        assert component in notices, component


# --- the workflows ------------------------------------------------------------------------------


def workflow(name):
    return (REPO / ".github" / "workflows" / name).read_text()


def jobs(text):
    """Each job's block of a workflow, by its id: the lines under it, as written."""
    body = text.split("\njobs:\n", 1)[1]
    found = {}
    current = None
    for line in body.splitlines():
        heading = re.match(r"^  ([A-Za-z0-9_-]+):\s*$", line)
        if heading:
            current = heading.group(1)
            found[current] = []
        elif current is not None:
            found[current].append(line)
    return {job: "\n".join(lines) for job, lines in found.items()}


def needs(block):
    match = re.search(r"^    needs: \[?([^\]\n]*)\]?$", block, re.M)
    return {need.strip() for need in match.group(1).split(",")} if match else set()


def test_a_release_builds_for_linux_with_the_toolchain_and_sdk_ci_proves_on_every_push():
    ci, release = jobs(workflow("ci.yml")), jobs(workflow("release.yml"))
    for pin in (r"container: (swift:\S+@sha256:[0-9a-f]{64})", r"STATIC_SDK_URL: (\S+)", r"STATIC_SDK_CHECKSUM: ([0-9a-f]{64})"):
        proved = re.findall(pin, ci["plugin-format-linux"])
        released = re.findall(pin, release["command-linux"])
        assert len(proved) == 1 and proved == released, pin


def test_only_the_image_job_may_write_packages_and_only_the_last_may_write_the_repository():
    text = workflow("release.yml")
    assert re.search(r"^permissions: \{\}$", text, re.M), "nothing unless a job asks"
    blocks = jobs(text)
    assert set(blocks) == {"app", "command-linux", "image", "publish"}
    for job, block in blocks.items():
        writes = sorted(re.findall(r"^      ([a-z-]+): write$", block, re.M))
        assert writes == {"image": ["packages"], "publish": ["contents"]}.get(job, []), (job, writes)
    assert "SPARKLE_PRIVATE_KEY" not in blocks["image"] + blocks["publish"] + blocks["command-linux"]


def test_the_image_is_pushed_after_everything_is_made_and_before_the_release_that_names_its_digest():
    blocks = jobs(workflow("release.yml"))
    assert needs(blocks["image"]) == {"app", "command-linux"}
    assert needs(blocks["publish"]) == {"app", "command-linux", "image"}
    assert "make-cli.sh image" in blocks["image"] and "make-cli.sh push" in blocks["image"]
    text = workflow("release.yml")
    # One call, comments aside: an immutable release takes no asset after it.
    assert len(re.findall(r"^\s+gh release create ", text, re.M)) == 1
    assert re.search(r"^\s+gh release create ", blocks["publish"], re.M)
    create = blocks["publish"][re.search(r"^\s+gh release create ", blocks["publish"], re.M).start():]
    for asset in (
        '"release/uDeck-$version.zip"', "release/appcast.xml",
        '"release-cli/udeck-plugin-$version-macos-universal.tar.gz"',
        '"release-cli/udeck-plugin-$version-linux-x86_64.tar.gz"',
        '"release-cli/udeck-plugin-$version-linux-aarch64.tar.gz"',
        "release-cli/udeck-plugin-image.txt", "release-cli/SHA256SUMS",
    ):  # fmt: skip
        assert asset in create, asset
    assert "make-cli.sh sums" in blocks["publish"] and "make-cli.sh notes" in blocks["publish"]
    assert "--notes-file release-cli/notes.md" in create and "--generate-notes" in create
    assert "sed " not in blocks["publish"] and "test -n" not in blocks["publish"], "the image file is read by make-cli, nowhere else"


def test_archives_never_go_where_generate_appcast_reads():
    text = workflow("release.yml")
    assert re.search(r"generate_appcast\"? \\\n(?:.*\\\n)*\s+release/$", text, re.M), "the appcast is written from release/"
    for line in re.findall(r"^.*make-cli\.sh (?:macos|linux|image|push|sums|notes).*$", text, re.M):
        assert "--out release-cli" in line, line


def test_ci_makes_what_a_release_publishes_on_every_push_and_publishes_nothing():
    text = workflow("ci.yml")
    blocks = jobs(text)
    assert "make-cli.sh macos" in blocks["build-and-test"]
    assert "make-cli.sh linux" in blocks["plugin-format-linux"]
    assert "make-cli.sh image" in blocks["udeck-plugin-image"]
    assert "make-cli.sh push --out release-cli --repository localhost:5000/iillyyaa1997/udeck-plugin" in blocks["udeck-plugin-image"]
    assert "make-cli.sh sums" in blocks["release-assets"] and "make-cli.sh notes" in blocks["release-assets"]
    assert needs(blocks["release-assets"]) == {"build-and-test", "plugin-format-linux", "udeck-plugin-image"}
    for forbidden in ("--push", "docker login", "gh release", ": write"):
        assert forbidden not in text, forbidden
    for line in text.splitlines():
        if "make-cli.sh " in line and not line.strip().startswith("#"):
            assert "ghcr.io" not in line, line
    assert re.search(r"^permissions:\n  contents: read\n", text, re.M), "the token reads, and that is all"


def steps(block):
    """A job's steps, each as the text of its lines."""
    found, current = [], None
    for line in block.splitlines():
        if line.startswith("      - "):
            current = [line]
            found.append(current)
        elif current is not None and (line.startswith("        ") or not line.strip()):
            current.append(line)
        elif current is not None and not line.startswith("      #"):
            current = None
    return ["\n".join(step) for step in found]


@pytest.mark.parametrize("name", ["ci.yml", "release.yml"])
def test_every_action_is_pinned_by_its_commit_and_no_checkout_keeps_the_token(name):
    text = workflow(name)
    uses = re.findall(r"^\s+(?:- )?uses: (.*)$", text, re.M)
    assert uses
    for use in uses:
        assert re.fullmatch(r"actions/(checkout|upload-artifact|download-artifact)@[0-9a-f]{40} # v\d+\.\d+\.\d+", use), use
    pins = {}
    for use in uses:
        action, rest = use.split("@")
        pins.setdefault(action, set()).add(rest)
    assert all(len(found) == 1 for found in pins.values()), pins
    for block in jobs(text).values():
        for step in steps(block):
            if "uses: actions/checkout@" in step:
                assert "persist-credentials: false" in step, step


@pytest.mark.parametrize(("name", "job"), [("ci.yml", "udeck-plugin-image"), ("release.yml", "image")])
def test_the_image_job_has_a_registry_of_its_own_where_make_cli_looks_for_it(name, job):
    block = jobs(workflow(name))[job]
    assert re.search(r"^    services:\n      registry:\n        image: registry:2\.[0-9.]+@sha256:[0-9a-f]{64}\n        ports:\n          - 5000:5000$", block, re.M), block
    assert re.search(r'^STAGE="localhost:5000/udeck-plugin"$', (REPO / "Scripts" / "make-cli.sh").read_text(), re.M)


def test_a_release_logs_in_only_for_the_copy_and_out_again_whatever_happened():
    found = steps(jobs(workflow("release.yml"))["image"])
    named = [re.search(r"name: (.*)", step).group(1) if "name:" in step else step.split("\n")[0].strip() for step in found]
    login = next(i for i, step in enumerate(found) if "docker login" in step)
    image = next(i for i, step in enumerate(found) if "make-cli.sh image" in step)
    push = next(i for i, step in enumerate(found) if "make-cli.sh push" in step)
    logout = next(i for i, step in enumerate(found) if "docker logout" in step)
    assert image < login and push == login + 1 and logout == push + 1, named
    assert "if: always()" in found[logout]
    assert sum("docker login" in step for step in found) == 1


def test_the_command_in_an_archive_is_signed_as_the_one_inside_udeck_app():
    make_app = (REPO / "Scripts" / "make-app.sh").read_text()
    make_cli = (REPO / "Scripts" / "make-cli.sh").read_text()
    for line in ('SIGN_FLAGS=(--force --options runtime --sign "$IDENTITY")', 'if [ "$IDENTITY" = "-" ]; then',
                 "    SIGN_FLAGS+=(--entitlements Scripts/adhoc.entitlements)"):  # fmt: skip
        assert line in make_app and line in make_cli, line
