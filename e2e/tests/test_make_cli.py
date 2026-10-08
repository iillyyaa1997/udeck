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
    # Two examples, one of them hello-card: the image's check-repo script copies
    # it into a repository it makes, and adds a line to its README.
    (root / "examples" / "first").mkdir(parents=True)
    (root / "examples" / "hello-card").mkdir(parents=True)
    (root / "examples" / "hello-card" / "README.md").write_text("# Hello card\n")
    (root / "examples" / "hello-card" / "manifest.json").write_text('{"id": "hello-card"}\n')
    (root / "Sources" / "uDeck" / "Support").mkdir(parents=True)
    shutil.copy(REPO / "Sources" / "uDeck" / "Support" / "Info.plist", root / "Sources" / "uDeck" / "Support")
    # The lock file's reader, which the image runs out of the specification.
    (root / "docs").mkdir()
    shutil.copy(REPO / "docs" / "plugin-repository.md", root / "docs")
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
        (["version", "--out", "x"], "Usage:"),
        (["sums", "--version", ""], "--version is empty"),
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


def sources_archive(out, version=VERSION, change=None):
    """A sources archive as `sources` writes one — or, with `change`, one it
    would not: a file that is not what SHA512SUMS says, one more file, a file
    owned by 501, a pax record, a record outside its folder."""
    out.mkdir(parents=True, exist_ok=True)
    folder = f"udeck-plugin-image-sources-{version}"
    files = {
        "README": b"The sources of the GPL and LGPL software in the udeck-plugin image\n",
        f"aports/{'0' * 40}/main/git/APKBUILD": b"pkgname=git\n",
        "distfiles/git-2.54.0.tar.xz": b"git's source\n",
    }
    sums = "".join(f"{hashlib.sha512(data).hexdigest()}  {name}\n" for name, data in sorted(files.items()) if name != "README")
    files["SHA512SUMS"] = sums.encode()
    if change == "tampered":
        files["distfiles/git-2.54.0.tar.xz"] = b"something else\n"
    if change == "unlisted":
        files["distfiles/extra.tar.gz"] = b"not in SHA512SUMS\n"
    archive = out / f"{folder}.tar"
    with tarfile.open(archive, "w", format=tarfile.PAX_FORMAT if change == "pax" else tarfile.GNU_FORMAT) as tar:
        def add(name, data=None):
            info = tarfile.TarInfo(name)
            info.uid = info.gid = 0
            if change == "owned" and name.endswith("APKBUILD"):
                info.uid = 501
            if change == "pax" and name.endswith("APKBUILD"):
                info.pax_headers = {"SCHILY.xattr.com.apple.provenance": "made on a Mac"}
            if data is None:
                info.type, info.mode = tarfile.DIRTYPE, 0o755
                tar.addfile(info)
            else:
                info.mode, info.size = 0o644, len(data)
                tar.addfile(info, io.BytesIO(data))

        add(folder)
        for name, data in sorted(files.items()):
            add(f"{folder}/{name}", data)
        if change == "outside":
            add("elsewhere", b"x\n")
    return archive


def release_set(out, version=VERSION, image=GHCR):
    for name in ("macos-universal", "linux-x86_64", "linux-aarch64"):
        real_archive(out, version, name)
    (out / "udeck-plugin-image.txt").write_text(image_file(image, version))
    sources_archive(out, version)


def test_sums_cover_the_three_archives_the_image_and_its_sources_and_say_what_sha256sum_says(checkout):
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
            f"udeck-plugin-image-sources-{VERSION}.tar",
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
        # The image's sources: there, of this version, and every file in them
        # what their own SHA512SUMS says.
        (lambda out: (release_set(out), (out / f"udeck-plugin-image-sources-{VERSION}.tar").unlink()),
         "no udeck-plugin-image-sources-9.9.9.tar"),
        (lambda out: (release_set(out), sources_archive(out, "9.9.8")), "a sources archive no release names"),
        (lambda out: (release_set(out), sources_archive(out, change="tampered")), "distfiles/git-2.54.0.tar.xz is not what its SHA512SUMS says"),
        (lambda out: (release_set(out), sources_archive(out, change="unlisted")), "its SHA512SUMS names wrongly"),
        (lambda out: (release_set(out), sources_archive(out, change="owned")), "is owned by 501:0"),
        (lambda out: (release_set(out), sources_archive(out, change="pax")), "or carries pax records"),
        (lambda out: (release_set(out), sources_archive(out, change="outside")), "elsewhere is outside"),
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
    assert notes.splitlines()[2] == f"    {GHCR}@{BUILT}", "the digest, on the third line"
    assert "THIRD_PARTY_NOTICES" in notes
    assert f"is udeck-plugin-image-sources-{VERSION}.tar." in notes


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
        # Byte for byte (D1b's review: `$(cat file)` drops every line break
        # at a file's end, and three more or none at all passed).
        (image_file() + "\n\n\n", "udeck-plugin-image.txt says"),
        (image_file() + "\n", "not, byte for byte"),
        (image_file()[:-1], "udeck-plugin-image.txt says"),
        (image_file().replace("\n", "\r\n"), "no line tag=vX.Y.Z"),
        (image_file() + "source=x\n", "udeck-plugin-image.txt says"),
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
    # A script the image's shell runs — check-repo on a repository made in
    # it, pin on a release on its disk — runs here, as written, against a
    # udeck-plugin that answers as the image's would (or, told so, does not),
    # each in a /tmp of its own as each container has: what the script holds
    # the command to is held here too.
    case " $* " in
        *" sh -eu -c "*)
            while [ "$1" != "-c" ]; do shift; done
            script="$2"
            shift 2
            sandbox="$(mktemp -d "$DOCKER_SANDBOX/run.XXXXXX")"
            mkdir -p "$sandbox/tmp"
            # Only a path the script names itself — after a space, a quote, an
            # = or file:// — so that a checkout under a /tmp/ of its own is
            # left as it is.
            script="$(printf '%s\n' "$script" | sed -E -e "s#(^|[ \"'=])/examples#\\1$PWD/examples#g" \
                -e "s#(^|[ \"'=])/docs/#\\1$PWD/docs/#g" \
                -e "s#(^|[ \"'=]|file://)/tmp/#\\1$sandbox/tmp/#g")"
            PATH="$IMAGE_FAKES:$PATH" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 exec sh -eu -c "$script" "$@" ;;
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
        *"cat /usr/share/licenses/udeck-plugin/ALPINE-PACKAGES"*)
            printf '%s\n' "# Every Alpine package in this image: its name and version, its licence, and its folder in" \
                "# udeck-plugin-image-sources-${FAKE_SOURCES_VERSION:-9.9.9}.tar, an asset of the release that published this image," \
                "# https://github.com/iillyyaa1997/udeck/releases/tag/v9.9.9"
            commit=0000000000000000000000000000000000000000
            [ "$platform" = linux/arm64 ] && commit=1111111111111111111111111111111111111111
            printf '%s\n' "busybox 1.37.0-r31 | GPL-2.0-only | https://gitlab.alpinelinux.org/alpine/aports/-/tree/$commit/main/busybox" \
                "libcurl 8.22.0-r0 | curl | https://gitlab.alpinelinux.org/alpine/aports/-/tree/2222222222222222222222222222222222222222/main/curl" ;;
        *"/lib/apk/db/installed"*) printf '%s\n' GPL-2.0-only MIT "${FAKE_LICENSE:-curl}" ;;
        *"cd /usr/share/licenses/udeck-plugin"*) exit "${FAKE_NO_NOTICES:-0}" ;;
        *"udeck-plugin --version"*) echo "udeck-plugin $says" ;;
        *"udeck-plugin --help"*) echo "usage: udeck-plugin check [--strict] <folder>..." ;;
        *"git --version"*)
            echo "git version 2.52.0"
            case "$*" in *"curl --version"*) [ "${FAKE_NO_CURL:-0}" = 1 ] && exit 127 ;; esac ;;
        *"check --strict /udeck/examples"*)
            echo "checked /udeck/examples/first/ at 0123456789ab strictly: 0 errors, 0 warnings"
            [ "${FAKE_ONE_EXAMPLE:-0}" = 1 ] || echo "checked /udeck/examples/hello-card/ at 0123456789ab strictly: 0 errors, 0 warnings" ;;
    esac
    exit 0
fi
exit 0
""".replace("sha256:BUILT", BUILT)

# udeck-plugin as the image's answers the two scripts check_image runs in it —
# or, told so by FAKE_RULE18, FAKE_PIN or FAKE_PIN_CHECK, does not.
IMAGE_UDECK_PLUGIN = r"""#!/bin/sh
command="$1"
shift
case "$command" in
check-repo)
    strict=0
    repo=""
    while [ $# -gt 0 ]; do
        case "$1" in --strict) strict=1 ;; --repo) repo="$2"; shift ;; esac
        shift
    done
    how=""
    [ "$strict" = 1 ] && how=" strictly"
    if [ "$(git -C "$repo" rev-list --count HEAD)" -gt 1 ] && [ "${FAKE_RULE18:-}" != silent ]; then
        echo "error: plugins/hello-card/manifest.json: the folder changed; its version 1.0.0 did not go up [rule 18]"
        echo "checked 1 plugin folder at 0123456789ab$how: 1 error, 0 warnings"
        exit 1
    fi
    echo "checked 1 plugin folder at 0123456789ab$how: 0 errors, 0 warnings" ;;
pin)
    repo=""
    version=""
    check=0
    while [ $# -gt 0 ]; do
        case "$1" in --repo) repo="$2"; shift ;; --version) version="$2"; shift ;; --check) check=1 ;; esac
        shift
    done
    lock="$repo/.github/udeck-plugin.lock"
    [ -n "$version" ] || version="$(sed -n 's/^version=//p' "$lock")"
    release="${UDECK_PLUGIN_DOWNLOAD_BASE#file://}/v$version"
    expected="$(mktemp)"
    {
        echo "version=$version"
        for platform in macos-universal linux-x86_64 linux-aarch64; do
            sum="$(awk -v name="udeck-plugin-$version-$platform.tar.gz" '$2 == name { print $1 }' "$release/SHA256SUMS")"
            [ "${FAKE_PIN:-}" = wrong ] && sum="ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
            [ "${FAKE_PIN:-}" = wrong-mac ] && [ "$platform" = macos-universal ] \
                && sum="eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
            echo "$platform=$sum"
        done
        echo "image=$(sed -n 's/^digest=//p' "$release/udeck-plugin-image.txt")"
        # A line no lock file has, which this pin's own --check takes.
        [ "${FAKE_PIN:-}" = extra-line ] && echo "comment=1"
    } > "$expected"
    if [ "$check" = 0 ]; then
        mkdir -p "$repo/.github"
        cat "$expected" > "$lock"
    elif [ "${FAKE_PIN_CHECK:-}" != pass ] && ! cmp -s "$lock" "$expected"; then
        echo "  image: $(sed -n 's/^image=//p' "$lock") here, $(sed -n 's/^image=//p' "$expected") in the release"
        rm -f "$expected"
        exit 1
    fi
    rm -f "$expected" ;;
*) exit 2 ;;
esac
"""

# cmp as the image's, or — told so by FAKE_CMP — one that takes the lock file
# with a line more for the five lines it should be: the reader leaning on it
# would take that file, and the image's script must say so.
IMAGE_CMP = """#!/bin/sh
case "$*" in *longer.lock*) [ "${FAKE_CMP:-}" = lenient ] && exit 0 ;; esac
exec /usr/bin/cmp "$@"
"""

# sha256sum, which a Mac may not have, as the image's BusyBox prints it.
IMAGE_SHA256SUM = """#!/bin/sh
exec python3 -I -c 'import hashlib, sys
for name in sys.argv[1:]:
    print(hashlib.sha256(open(name, "rb").read()).hexdigest() + "  " + name)' "$@"
"""

LABEL = (
    "Apache-2.0 AND Apache-2.0 WITH Swift-exception AND Apache-2.0 WITH LLVM-exception AND MIT AND BSD-3-Clause"
    " AND (BSD-3-Clause OR GPL-2.0-or-later) AND curl AND GPL-2.0-only AND (GPL-2.0-or-later OR LGPL-3.0-or-later)"
    " AND (MIT AND BSD-2-Clause AND GPL-2.0-or-later) AND (MPL-2.0 AND MIT) AND Zlib"
)


@pytest.fixture
def image(checkout):
    """Docker stubbed — every call logged — on an x86_64 machine, with the two Linux archives."""
    executable(checkout / "stubs" / "docker", DOCKER)
    executable(checkout / "image-fakes" / "udeck-plugin", IMAGE_UDECK_PLUGIN)
    executable(checkout / "image-fakes" / "sha256sum", IMAGE_SHA256SUM)
    executable(checkout / "image-fakes" / "cmp", IMAGE_CMP)
    (checkout / "sandbox").mkdir()
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
    done = make_cli(checkout, *args, DOCKER_LOG=str(log), DOCKER_SEEN=str(checkout / "seen"),
                    DOCKER_SANDBOX=str(checkout / "sandbox"), IMAGE_FAKES=str(checkout / "image-fakes"), **env)
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
        for looked_for in ("test -s LICENSE", "test -s NOTICE", "test -s THIRD_PARTY_NOTICES", 'grep -q "^git " ALPINE-PACKAGES',
                           'grep -q "udeck-plugin-image-sources-X\\.Y\\.Z\\.tar" THIRD_PARTY_NOTICES'):
            assert looked_for in notices[0], (platform, looked_for)
        assert sum(call.endswith(" cat /usr/share/licenses/udeck-plugin/ALPINE-PACKAGES") for call in ran) == 1, platform
        assert any("check --strict /udeck/examples/" in call and ":/udeck:ro" in call for call in ran), platform
        assert any("check-repo" in call and ":/examples:ro" in call for call in ran), platform
        assert any("read_udeck_plugin_lock" in call and "/docs:/docs:ro " in call for call in ran), platform
    assert "the lock file read by the reader in the docs, as a job in this image reads it" in done.stdout
    # The binaries the image is built from are the ones the archives carry.
    for arch, platform in (("x86_64", "amd64"), ("aarch64", "arm64")):
        assert (image / "seen" / f"{platform}-udeck-plugin").read_text() == f"#!/bin/sh\necho the {arch} binary\n"
    assert (image / "seen" / "Dockerfile").read_text() == (REPO / "Scripts" / "udeck-plugin.Dockerfile").read_text()
    assert (image / "seen" / "THIRD_PARTY_NOTICES").read_bytes() == (REPO / "Scripts" / "third-party" / "THIRD_PARTY_NOTICES").read_bytes()
    assert (image / "out" / "udeck-plugin-staged.txt").read_text() == image_file(STAGE)
    # What `sources` gathers from: each platform's ALPINE-PACKAGES, its
    # comment left out, every line marked with the platform it came from.
    tree = "https://gitlab.alpinelinux.org/alpine/aports/-/tree"
    assert (image / "out" / "udeck-plugin-staged-packages.txt").read_text() == (
        f"linux/amd64 busybox 1.37.0-r31 | GPL-2.0-only | {tree}/{'0' * 40}/main/busybox\n"
        f"linux/amd64 libcurl 8.22.0-r0 | curl | {tree}/{'2' * 40}/main/curl\n"
        f"linux/arm64 busybox 1.37.0-r31 | GPL-2.0-only | {tree}/{'1' * 40}/main/busybox\n"
        f"linux/arm64 libcurl 8.22.0-r0 | curl | {tree}/{'2' * 40}/main/curl\n"
    )
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
        # The image's own scripts, held to what they check (D1b's review: the
        # rule-18 check could be taken out of the script, and every test
        # stayed green).
        ({"FAKE_RULE18": "silent"}, "check-repo on a repository made in the image did not say what it should (linux/amd64)"),
        ({"FAKE_PIN": "wrong"}, "pin in the image did not pin a release on its disk as it should (linux/amd64)"),
        ({"FAKE_PIN_CHECK": "pass"}, "pin in the image did not pin a release on its disk as it should (linux/amd64)"),
        # What only the reader from the docs sees, run in the image (D2a's
        # review: nothing ran it with BusyBox): a sum the greps do not look at,
        # and a line no lock file has, both of which pin's --check takes.
        ({"FAKE_PIN": "wrong-mac"}, "pin in the image did not pin a release on its disk as it should (linux/amd64)"),
        ({"FAKE_PIN": "extra-line"}, "pin in the image did not pin a release on its disk as it should (linux/amd64)"),
        ({"FAKE_CMP": "lenient"}, "pin in the image did not pin a release on its disk as it should (linux/amd64)"),
        ({"FAKE_NO_CURL": "1"}, "no shell, git, curl or /tmp in the image (linux/amd64)"),
        ({"FAKE_LICENSE": "GPL-3.0-only"}, 'under "GPL-3.0-only", which its licenses label does not name'),
        ({"FAKE_NO_NOTICES": "1"}, "lacks its licences, its notices or the list of its Alpine packages"),
        # The list that names the asset with the sources has to name this
        # release's.
        ({"FAKE_SOURCES_VERSION": "9.9.8"}, "does not name udeck-plugin-image-sources-9.9.9.tar"),
    ],
)
def test_an_image_that_does_not_do_its_work_on_either_platform_is_never_staged(image, env, said):
    done, calls = run_image(image, "--version", VERSION, **env)
    assert done.returncode == 1, done.stdout + done.stderr
    assert said in done.stderr
    assert not (image / "out" / "udeck-plugin-staged.txt").exists()
    assert not (image / "out" / "udeck-plugin-staged-packages.txt").exists()
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


def test_push_refuses_a_staged_file_with_a_line_break_more(image):
    staged(image, image_file(STAGE) + "\n")
    done, calls = run_docker(image, "push", "--version", VERSION, "--out", "out")
    assert done.returncode == 1 and "udeck-plugin-staged.txt says" in done.stderr
    assert calls == [] and not (image / "out" / "udeck-plugin-image.txt").exists()


def test_push_without_an_image_that_ran_does_nothing(image):
    done, calls = run_docker(image, "push", "--out", "out")
    assert done.returncode == 1 and "no udeck-plugin-staged.txt" in done.stderr
    assert calls == []


# --- sources ------------------------------------------------------------------------------------

TREE = "https://gitlab.alpinelinux.org/alpine/aports/-/tree"


def sha512_hex(data):
    return hashlib.sha512(data).hexdigest()


class Alpine:
    """A copy of aports, a git repository with main/<origin>/ folders at two
    commits, and of Alpine's distfiles, a folder of upstream archives — what
    `sources` reads, at file:// addresses — with the files `image` leaves in
    out/ for it."""

    UPSTREAM = {
        "git-2.54.0.tar.xz": b"git's source\n",
        "busybox-1.37.0.tar.bz2": b"busybox's source\n",
        "zstd-1.5.7.tar.gz": b"zstd's source\n",
    }

    def __init__(self, checkout):
        self.checkout = checkout
        self.aports = checkout.parent / "aports"
        self.distfiles = checkout.parent / "distfiles"
        self.out = checkout / "out"
        self.aports.mkdir()
        self.distfiles.mkdir()
        self.out.mkdir()
        self.env = {**os.environ, "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
                    "TMPDIR": str(checkout.parent / "tmp")}
        self.git("init", "-q", "-b", "master")
        # What Alpine's GitLab allows: a filter, and an object asked for by its id.
        self.git("config", "uploadpack.allowFilter", "true")
        self.git("config", "uploadpack.allowAnySHA1InWant", "true")
        for name, data in self.UPSTREAM.items():
            (self.distfiles / name).write_bytes(data)
        self.package("git", "git-2.54.0.tar.xz", {"fix.patch": b"--- a\n+++ b\n", "git-daemon.initd": b"#!/sbin/openrc-run\n"},
                     executable={"git-daemon.initd"})
        # An install script, and another that is a link to it, as aports has
        # alpine-baselayout's.
        (self.aports / "main" / "git" / "git.pre-upgrade").write_text("#!/bin/sh\n")
        (self.aports / "main" / "git" / "git.post-upgrade").symlink_to("git.pre-upgrade")
        self.package("busybox", "busybox-1.37.0.tar.bz2", {"busyboxconfig": b"CONFIG_ASH=y\n"})
        # Not under the GPL, and its upstream archive is nowhere: never read.
        self.package("curl", "curl-8.22.0.tar.xz", {})
        self.first = self.commit("First")
        self.package("busybox", "busybox-1.37.0.tar.bz2", {"busyboxconfig": b"CONFIG_ASH=y\nCONFIG_HUSH=y\n"})
        self.package("zstd", "zstd-1.5.7.tar.gz", {})
        self.second = self.commit("Second")
        (self.out / "udeck-plugin-staged.txt").write_text(image_file(STAGE))
        self.listing(self.lines())

    def git(self, *args):
        return subprocess.run(["git", "-C", str(self.aports), "-c", "user.name=CI", "-c", "user.email=ci@example.invalid", *args],
                              check=True, capture_output=True, text=True, env=self.env).stdout.strip()

    def package(self, origin, remote, local, executable=(), sums=None):
        folder = self.aports / "main" / origin
        folder.mkdir(parents=True, exist_ok=True)
        for name, data in local.items():
            (folder / name).write_bytes(data)
            (folder / name).chmod(0o755 if name in executable else 0o644)
        upstream = self.UPSTREAM.get(remote, b"nowhere\n")
        lines = [f"{sha512_hex(upstream)}  {remote}"] + [f"{sha512_hex(data)}  {name}" for name, data in local.items()]
        sources = "\n\t".join([f"https://example.invalid/{remote}", *local])
        apkbuild = f'pkgname={origin}\npkgver=1\npkgrel=0\nsource="{sources}\n\t"\n'
        apkbuild += "\nsha512sums=\"\n" + "\n".join(lines) + "\n\"\n" if sums is None else sums
        (folder / "APKBUILD").write_text(apkbuild)

    def commit(self, message):
        self.git("add", "-A")
        self.git("commit", "-q", "-m", message)
        return self.git("rev-parse", "HEAD")

    def lines(self, first=None, second=None):
        first, second = first or self.first, second or self.second
        return [
            f"linux/amd64 busybox 1.37.0-r31 | GPL-2.0-only | {TREE}/{first}/main/busybox",
            f"linux/amd64 git 2.54.0-r0 | GPL-2.0-only | {TREE}/{first}/main/git",
            f"linux/amd64 libcurl 8.22.0-r0 | curl | {TREE}/{first}/main/curl",
            f"linux/amd64 zstd-libs 1.5.7-r2 | BSD-3-Clause OR GPL-2.0-or-later | {TREE}/{second}/main/zstd",
            # On arm64, busybox from the later commit: a platform's packages
            # are built when its builder gets to them.
            f"linux/arm64 busybox 1.37.0-r31 | GPL-2.0-only | {TREE}/{second}/main/busybox",
            f"linux/arm64 git 2.54.0-r0 | GPL-2.0-only | {TREE}/{first}/main/git",
            f"linux/arm64 libcurl 8.22.0-r0 | curl | {TREE}/{first}/main/curl",
            f"linux/arm64 zstd-libs 1.5.7-r2 | BSD-3-Clause OR GPL-2.0-or-later | {TREE}/{second}/main/zstd",
        ]

    def listing(self, lines):
        (self.out / "udeck-plugin-staged-packages.txt").write_text("".join(line + "\n" for line in lines))

    def run(self, *args, **env):
        return make_cli(self.checkout, "sources", "--out", "out", "--aports", f"file://{self.aports}",
                        "--distfiles", f"file://{self.distfiles}", *args, GIT_CONFIG_GLOBAL="/dev/null",
                        GIT_CONFIG_NOSYSTEM="1", **env)

    @property
    def archive(self):
        return self.out / f"udeck-plugin-image-sources-{VERSION}.tar"


@pytest.fixture
def alpine(checkout):
    return Alpine(checkout)


def test_sources_gather_each_gpl_and_lgpl_package_s_aports_folder_at_its_commit_and_its_upstream_archives(alpine):
    done = alpine.run("--version", VERSION)
    assert done.returncode == 0, done.stdout + done.stderr
    folder = f"udeck-plugin-image-sources-{VERSION}"
    found = members(alpine.archive)
    assert all(name == folder or name.startswith(folder + "/") for name in found)
    files = {name[len(folder) + 1:]: member for name, member in found.items() if member.isreg()}
    first, second = alpine.first, alpine.second
    assert sorted(files) == sorted([
        "README", "SHA512SUMS",
        f"aports/{first}/main/busybox/APKBUILD", f"aports/{first}/main/busybox/busyboxconfig",
        f"aports/{first}/main/git/APKBUILD", f"aports/{first}/main/git/fix.patch", f"aports/{first}/main/git/git-daemon.initd",
        f"aports/{first}/main/git/git.pre-upgrade",
        f"aports/{second}/main/busybox/APKBUILD", f"aports/{second}/main/busybox/busyboxconfig",
        f"aports/{second}/main/zstd/APKBUILD",
        "distfiles/busybox-1.37.0.tar.bz2", "distfiles/git-2.54.0.tar.xz", "distfiles/zstd-1.5.7.tar.gz",
    ]), "every GPL and LGPL package's folder at the commit it was built from, and nothing of curl's"
    with tarfile.open(alpine.archive) as tar:
        def read(path):
            return tar.extractfile(f"{folder}/{path}").read()

        for path in files:
            if path.startswith("aports/"):
                commit, rest = path.split("/", 2)[1:]
                assert read(path) == subprocess.run(["git", "-C", str(alpine.aports), "show", f"{commit}:{rest}"],
                                                    capture_output=True, check=True, env=alpine.env).stdout, path
        for name, data in Alpine.UPSTREAM.items():
            assert read(f"distfiles/{name}") == data
        sums = read("SHA512SUMS").decode()
        assert sums == "".join(f"{sha512_hex(read(path))}  {path}\n" for path in sorted(files) if path not in ("README", "SHA512SUMS"))
        readme = read("README").decode()
    assert {(m.uid, m.gid, m.uname, m.gname, m.mtime) for m in found.values()} == {(0, 0, "", "", 0)}
    assert {name: dict(m.pax_headers) for name, m in found.items() if m.pax_headers} == {}
    assert files[f"aports/{first}/main/git/git-daemon.initd"].mode == 0o755
    assert files[f"aports/{first}/main/git/fix.patch"].mode == 0o644
    links = {name[len(folder) + 1:]: member.linkname for name, member in found.items() if member.issym()}
    assert links == {f"aports/{first}/main/git/git.post-upgrade": "git.pre-upgrade"}, "a link aports keeps, kept as one"
    # What it holds, said in it: each package once a folder, with the
    # platforms whose image holds it.
    assert f"  busybox 1.37.0-r31 | GPL-2.0-only | linux/amd64 | aports/{first}/main/busybox\n" in readme
    assert f"  busybox 1.37.0-r31 | GPL-2.0-only | linux/arm64 | aports/{second}/main/busybox\n" in readme
    assert f"  git 2.54.0-r0 | GPL-2.0-only | linux/amd64, linux/arm64 | aports/{first}/main/git\n" in readme
    assert (f"  zstd-libs 1.5.7-r2 | BSD-3-Clause OR GPL-2.0-or-later | linux/amd64, linux/arm64 | aports/{second}/main/zstd\n"
            in readme)
    assert "libcurl" not in readme and "curl-8.22.0" not in readme
    assert f"https://github.com/iillyyaa1997/udeck/releases/tag/v{VERSION}" in readme
    assert left_behind(alpine.checkout) == []
    # Made the same way twice, it is the same archive, byte for byte.
    made = alpine.archive.read_bytes()
    assert alpine.run().returncode == 0
    assert alpine.archive.read_bytes() == made


def test_sums_take_the_sources_that_sources_made(alpine):
    assert alpine.run("--version", VERSION).returncode == 0
    for name in ("macos-universal", "linux-x86_64", "linux-aarch64"):
        real_archive(alpine.out, VERSION, name)
    (alpine.out / "udeck-plugin-image.txt").write_text(image_file())
    done = make_cli(alpine.checkout, "sums", "--version", VERSION, "--out", "out")
    assert done.returncode == 0, done.stdout + done.stderr
    assert f"  udeck-plugin-image-sources-{VERSION}.tar\n" in (alpine.out / "SHA256SUMS").read_text()


def point(alpine, origin, commit):
    """The list as the image would have it had `origin` been built at `commit`."""
    alpine.listing([re.sub(rf"/[0-9a-f]{{40}}/main/{origin}$", f"/{commit}/main/{origin}", line) for line in alpine.lines()])


def a_patch_its_apkbuild_does_not_name(alpine):
    alpine.package("git", "git-2.54.0.tar.xz", {"fix.patch": b"what the APKBUILD names\n"})
    (alpine.aports / "main" / "git" / "fix.patch").write_bytes(b"something else\n")
    return alpine.commit("A patch changed, and its sum not")


def an_apkbuild_with(alpine, sums):
    alpine.package("git", "git-2.54.0.tar.xz", {}, sums=sums)
    return alpine.commit("An APKBUILD of its own")


def a_link_out_of_the_folder(alpine, target):
    (alpine.aports / "main" / "git" / "link").symlink_to(target)
    return alpine.commit("A link out")


def a_submodule_in_the_folder(alpine):
    alpine.git("update-index", "--add", "--cacheinfo", f"160000,{alpine.first},main/git/vendored")
    alpine.git("commit", "-q", "-m", "A submodule")
    return alpine.git("rev-parse", "HEAD")


@pytest.mark.parametrize(
    ("arrange", "said"),
    [
        (lambda a: (a.distfiles / "git-2.54.0.tar.xz").write_bytes(b"another git\n"),
         "git-2.54.0.tar.xz from file://"),
        (lambda a: (a.distfiles / "zstd-1.5.7.tar.gz").unlink(), "zstd-1.5.7.tar.gz, which aports"),
        # A file of the folder that is not what its APKBUILD says, as abuild
        # would refuse it.
        (lambda a: point(a, "git", a_patch_its_apkbuild_does_not_name(a)),
         " main/git/fix.patch is not what its APKBUILD's sha512sums says"),
        (lambda a: point(a, "git", "e" * 40), f"aports commit {'e' * 40} (main/git) cannot be fetched from file://"),
        (lambda a: a.listing([line.replace("/main/git", "/main/nothere") for line in a.lines()]), "has no main/nothere"),
        (lambda a: a.listing([*a.lines(), "linux/amd64 git 2.54.0-r0 | GPL-2.0-only | https://example.invalid/git"]),
         "has a line that is not <platform> <name> <version> | <licence>"),
        (lambda a: a.listing([*a.lines(), f"linux/riscv64 git 2.54.0-r0 | GPL-2.0-only | {TREE}/{a.first}/main/git"]),
         "has a line that is not"),
        (lambda a: a.listing([line for line in a.lines() if line.startswith("linux/amd64 ")]),
         "lists no package of linux/arm64"),
        (lambda a: a.listing([line for line in a.lines() if "libcurl" in line]), "is under the GPL or the LGPL"),
        (lambda a: a.listing([]), "has a line that is not"),
        (lambda a: (a.out / "udeck-plugin-staged-packages.txt").unlink(), "no udeck-plugin-staged-packages.txt"),
        (lambda a: (a.out / "udeck-plugin-staged.txt").unlink(), "no udeck-plugin-staged.txt"),
        (lambda a: point(a, "git", an_apkbuild_with(a, "# no sums\n")), "its APKBUILD names no sha512sums"),
        (lambda a: point(a, "git", an_apkbuild_with(a, f'sha512sums="{"a" * 128}  ../escape"\n')), "is not <sha512>  <file>"),
        (lambda a: point(a, "git", a_link_out_of_the_folder(a, "../busybox/APKBUILD")), "is a link that leads out of its folder"),
        (lambda a: point(a, "git", a_link_out_of_the_folder(a, "/etc/passwd")), "is a link that leads out of its folder"),
        (lambda a: point(a, "git", a_link_out_of_the_folder(a, "..")), "is a link that leads out of its folder"),
        (lambda a: point(a, "git", a_submodule_in_the_folder(a)), "holds what is not a plain file with a plain name"),
    ],
)  # fmt: skip
def test_sources_refuse_what_they_cannot_hold_to_what_alpine_built_and_make_no_archive(alpine, arrange, said):
    arrange(alpine)
    done = alpine.run("--version", VERSION)
    assert done.returncode == 1, done.stdout + done.stderr
    assert said in done.stderr
    assert not alpine.archive.exists()
    assert left_behind(alpine.checkout) == []


def test_sources_of_another_version_than_the_image_that_ran_are_refused(alpine):
    done = alpine.run("--version", "9.9.8")
    assert done.returncode == 1 and "is of v9.9.9; this release is 9.9.8" in done.stderr
    assert not alpine.archive.exists()


def test_the_image_and_what_builds_it_are_pinned_by_digest_and_say_where_they_come_from():
    dockerfile = (REPO / "Scripts" / "udeck-plugin.Dockerfile").read_text()
    assert re.search(r"^FROM alpine:[0-9.]+@sha256:[0-9a-f]{64}$", dockerfile, re.M), "the base by digest"
    assert re.search(r"^apk add --no-cache git curl$", dockerfile, re.M), "check and check-repo start git, pin curl"
    assert not re.search(r"^ENTRYPOINT", dockerfile, re.M), "GitLab CI hands the job's script to the image's shell"
    for label in ('source="https://github.com/iillyyaa1997/udeck"', 'version="${VERSION}"', 'licenses="${LICENSES}"'):
        assert f"org.opencontainers.image.{label}" in dockerfile
    assert "COPY LICENSE NOTICE THIRD_PARTY_NOTICES /usr/share/licenses/udeck-plugin/" in dockerfile
    assert "' /lib/apk/db/installed | sort\n} > /usr/share/licenses/udeck-plugin/ALPINE-PACKAGES" in dockerfile
    script = (REPO / "Scripts" / "make-cli.sh").read_text()
    for name in ("BUILDKIT", "BINFMT"):
        assert re.search(rf'^{name}="[a-z/]+:[A-Za-z0-9.-]+@sha256:[0-9a-f]{{64}}"$', script, re.M), name


def test_the_sources_are_read_from_the_alpine_release_the_image_is_built_on():
    """The distfiles `sources` reads are the ones of the Alpine release in the
    Dockerfile's FROM: a base moved to 3.25 with distfiles left at v3.24 would
    look for its archives where they are not."""
    dockerfile = (REPO / "Scripts" / "udeck-plugin.Dockerfile").read_text()
    release = re.search(r"^FROM alpine:(\d+\.\d+)\.\d+@sha256:", dockerfile, re.M).group(1)
    script = (REPO / "Scripts" / "make-cli.sh").read_text()
    assert re.findall(r'^DISTFILES="(.*)"$', script, re.M) == [f"https://distfiles.alpinelinux.org/distfiles/v{release}"]
    # aports from its GitHub mirror: Alpine's GitLab turns GitHub's runners away.
    assert re.findall(r'^APORTS="(.*)"$', script, re.M) == ["https://github.com/alpinelinux/aports.git"]


def alpine_packages_script(tmp_path, installed):
    """The Dockerfile's RUN that writes ALPINE-PACKAGES, run here on a copy of
    /lib/apk/db/installed — apk itself left out."""
    dockerfile = (REPO / "Scripts" / "udeck-plugin.Dockerfile").read_text()
    script = re.search(r"^RUN <<'SH'\n(.*?)\nSH$", dockerfile, re.M | re.S).group(1)
    assert "apk add --no-cache git curl\n" in script and "/lib/apk/db/installed" in script
    (tmp_path / "installed").write_text(installed)
    script = (script.replace("apk add --no-cache git curl\n", "")
              .replace("mkdir -p /usr/share/licenses/udeck-plugin\n", "")
              .replace("/lib/apk/db/installed", str(tmp_path / "installed"))
              .replace("/usr/share/licenses/udeck-plugin/ALPINE-PACKAGES", str(tmp_path / "ALPINE-PACKAGES")))
    subprocess.run(["sh", "-c", script], check=True, env={**os.environ, "VERSION": VERSION})
    return (tmp_path / "ALPINE-PACKAGES").read_text()


def test_the_list_of_alpine_packages_names_each_with_its_licence_and_its_source_in_main():
    """The awk program the Dockerfile writes ALPINE-PACKAGES with, run here on
    two records of /lib/apk/db/installed. Every package the image holds is
    from Alpine's main repository (v3.24's index, 2026-10-07: git and curl and
    all they bring), so the link is to aports' main/ — a link to community/
    would send whoever wants a GPL package's source to nothing (D1b's review:
    that change passed every test).
    """
    dockerfile = (REPO / "Scripts" / "udeck-plugin.Dockerfile").read_text()
    program = re.search(r"^ *awk '\n(.*?)\n *' /lib/apk/db/installed", dockerfile, re.M | re.S).group(1)
    installed = (
        "C:Q1abc=\nP:git\nV:2.54.0-r0\nA:x86_64\nL:GPL-2.0-only\no:git\nc:0123456789abcdef\n\n"
        "C:Q1def=\nP:libcurl\nV:8.22.0-r0\nL:curl\no:curl\nc:fedcba9876543210\n"
    )
    done = subprocess.run(["awk", program], input=installed, capture_output=True, text=True, check=True)
    assert done.stdout.splitlines() == [
        "git 2.54.0-r0 | GPL-2.0-only | https://gitlab.alpinelinux.org/alpine/aports/-/tree/0123456789abcdef/main/git",
        "libcurl 8.22.0-r0 | curl | https://gitlab.alpinelinux.org/alpine/aports/-/tree/fedcba9876543210/main/curl",
    ]


def test_the_list_of_alpine_packages_says_first_which_asset_holds_the_sources(tmp_path):
    """ALPINE-PACKAGES as the image's RUN writes it: comment lines naming the
    release's sources asset of the image's version — the very line image
    checks for in the image it built, and `sources` reads past — then one line
    a package, sorted."""
    installed = (
        "C:Q1def=\nP:libcurl\nV:8.22.0-r0\nL:curl\no:curl\nc:" + "f" * 40 + "\n\n"
        "C:Q1abc=\nP:git\nV:2.54.0-r0\nA:x86_64\nL:GPL-2.0-only\no:git\nc:" + "0" * 40 + "\n"
    )
    lines = alpine_packages_script(tmp_path, installed).splitlines()
    header = [line for line in lines if line.startswith("#")]
    assert lines[: len(header)] == header, "the comment comes first"
    assert f"# udeck-plugin-image-sources-{VERSION}.tar, an asset of the release that published this image," in header
    assert f"# https://github.com/iillyyaa1997/udeck/releases/tag/v{VERSION}" in header
    assert lines[len(header):] == [
        f"git 2.54.0-r0 | GPL-2.0-only | https://gitlab.alpinelinux.org/alpine/aports/-/tree/{'0' * 40}/main/git",
        f"libcurl 8.22.0-r0 | curl | https://gitlab.alpinelinux.org/alpine/aports/-/tree/{'f' * 40}/main/curl",
    ]
    script = (REPO / "Scripts" / "make-cli.sh").read_text()
    assert 'grep -qxF "# udeck-plugin-image-sources-$version.tar, an asset of the release that published this image,"' in script


def test_version_is_what_the_app_says_read_without_a_mac():
    """What CI passes as --version: CFBundleShortVersionString, read with sed
    where a Linux job has no PlistBuddy — and the same as plistlib reads it."""
    import plistlib

    done = make_cli(REPO, "version")
    assert done.returncode == 0, done.stderr
    app = plistlib.loads((REPO / "Sources" / "uDeck" / "Support" / "Info.plist").read_bytes())
    assert done.stdout == app["CFBundleShortVersionString"] + "\n"


@pytest.mark.parametrize(
    ("change", "said"),
    [
        (("<string>0.5.0</string>", "<string>0.5</string>"), 'is "0.5", not X.Y.Z'),
        (("<string>0.5.0</string>", "<string>v0.5.0</string>"), "not X.Y.Z"),
        (("<key>CFBundleShortVersionString</key>", "<key>CFBundleVersionString</key>"), "0 times, not once"),
        (("<key>CFBundleVersion</key>", "<key>CFBundleShortVersionString</key>"), "2 times, not once"),
    ],
)
def test_version_refuses_an_info_plist_it_cannot_read_one_number_from(checkout, change, said):
    plist = checkout / "Sources" / "uDeck" / "Support" / "Info.plist"
    text = plist.read_text()
    version = re.search(r"<key>CFBundleShortVersionString</key>\s*<string>([^<]*)</string>", text).group(1)
    old, new = change
    plist.write_text(text.replace(old.replace("0.5.0", version), new.replace("0.5.0", version)))
    done = make_cli(checkout, "version")
    assert done.returncode == 1, done.stdout
    assert said.replace("0.5.0", version) in done.stderr
    assert done.stdout == ""


def test_the_notices_name_every_package_the_command_is_built_with():
    notices = (REPO / "Scripts" / "third-party" / "THIRD_PARTY_NOTICES").read_text()
    resolved = json.loads((REPO / "Packages" / "UDeckPluginFormat" / "Package.resolved").read_text())
    for pin in resolved["pins"]:
        assert pin["identity"] in notices, f"{pin['identity']} is in Package.resolved and not in THIRD_PARTY_NOTICES"
        if pin["identity"] == "swift-crypto":
            assert f"swift-crypto {pin['state']['version']} (revision {pin['state']['revision']})" in notices
    for component in ("musl", "mimalloc", "fts", "BoringSSL", "libdispatch", "swift-foundation", "libc++"):
        assert component in notices, component
    # swift-foundation's uuid.c is under a licence of its own, and its notice
    # has to travel with the binary (D1b's review).
    assert "10. uuid.c" in notices and "Copyright (c) 2004 Apple Computer, Inc." in notices
    assert "Redistributions in binary form must reproduce the above copyright" in notices.split("[G] uuid.c")[1]


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
        "release-cli/udeck-plugin-image.txt", '"release-cli/udeck-plugin-image-sources-$version.tar"',
        "release-cli/SHA256SUMS",
    ):  # fmt: skip
        assert asset in create, asset
    assert "make-cli.sh sums" in blocks["publish"] and "make-cli.sh notes" in blocks["publish"]
    assert "--notes-file release-cli/notes.md" in create and "--generate-notes" in create
    assert "sed " not in blocks["publish"] and "test -n" not in blocks["publish"], "the image file is read by make-cli, nowhere else"


def test_archives_never_go_where_generate_appcast_reads():
    text = workflow("release.yml")
    assert re.search(r"generate_appcast\"? \\\n(?:.*\\\n)*\s+release/$", text, re.M), "the appcast is written from release/"
    for line in re.findall(r"^.*make-cli\.sh (?:macos|linux|image|sources|push|sums|notes).*$", text, re.M):
        assert "--out release-cli" in line, line


def test_ci_makes_what_a_release_publishes_on_every_push_and_publishes_nothing():
    text = workflow("ci.yml")
    blocks = jobs(text)
    assert "make-cli.sh macos" in blocks["build-and-test"]
    assert "make-cli.sh linux" in blocks["plugin-format-linux"]
    assert "make-cli.sh image" in blocks["udeck-plugin-image"]
    assert "make-cli.sh sources" in blocks["udeck-plugin-image"]
    assert "--out release-cli --repository localhost:5001/iillyyaa1997/udeck-plugin" in blocks["udeck-plugin-image"]
    assert "make-cli.sh sums" in blocks["release-assets"] and "make-cli.sh notes" in blocks["release-assets"]
    assert needs(blocks["release-assets"]) == {"build-and-test", "plugin-format-linux", "udeck-plugin-image"}
    for forbidden in ("--push", "gh release", ": write"):
        assert forbidden not in text, forbidden
    # The one login: to the job's own second registry, never to ghcr.io.
    logins = re.findall(r"docker login (\S+)", text)
    assert logins == ["localhost:5001"], logins
    for line in text.splitlines():
        if "make-cli.sh " in line and not line.strip().startswith("#"):
            assert "ghcr.io" not in line, line
    assert re.search(r"^permissions:\n  contents: read\n", text, re.M), "the token reads, and that is all"


def test_ci_copies_the_image_to_a_second_registry_that_asks_for_a_login_and_logs_out_whatever_happened():
    """D1b's review: the dry run copied within one registry and without a
    login, where a release copies between two and with one."""
    block = jobs(workflow("ci.yml"))["udeck-plugin-image"]
    found = steps(block)
    named = [re.search(r"name: (.*)", step).group(1) if "name:" in step else step.split("\n")[0].strip() for step in found]
    start = next(i for i, step in enumerate(found) if "docker run -d --name second-registry" in step)
    image = next(i for i, step in enumerate(found) if "make-cli.sh image" in step)
    login = next(i for i, step in enumerate(found) if "docker login" in step)
    push = next(i for i, step in enumerate(found) if "make-cli.sh push" in step)
    logout = next(i for i, step in enumerate(found) if "docker logout" in step)
    assert image < start < login and push == login + 1 and logout == push + 1, named
    assert "if: always()" in found[logout]
    assert "--repository localhost:5001/iillyyaa1997/udeck-plugin" in found[push]
    second = found[start]
    service = re.search(r"image: (registry:\S+)", block).group(1)
    assert service in second, "the second registry is the service's image, by the same digest"
    assert "-p 5001:5000" in second and "REGISTRY_AUTH=htpasswd" in second
    assert "openssl rand" in second and "::add-mask::" in second, "a password of this run's own, masked"
    assert "htpasswd -Bbn" in second
    assert "--password-stdin" in found[login]


def test_every_make_cli_call_in_ci_says_the_version_a_tag_would():
    text = workflow("ci.yml")
    calls = [line for line in text.splitlines() if re.search(r"Scripts/make-cli\.sh (macos|linux|image|sources|push|sums|notes)", line)]
    assert len(calls) == 7, calls
    for call in calls:
        assert '--version "$(Scripts/make-cli.sh version)"' in call, call
    assert '--revision "$GITHUB_SHA"' in next(call for call in calls if "make-cli.sh image" in call)


@pytest.mark.parametrize(("name", "job"), [("ci.yml", "udeck-plugin-image"), ("release.yml", "image")])
def test_the_sources_are_gathered_from_the_image_that_ran_before_it_is_copied_and_kept_for_the_release(name, job):
    """Gathered after `image` — which writes the package list they are read
    from — and before the login and the copy, so that an image whose sources
    cannot be gathered is never published; kept with the image's file for
    the job that writes SHA256SUMS. Downloaded afresh, as a release does:
    no cache in either workflow."""
    found = steps(jobs(workflow(name))[job])
    image = next(i for i, step in enumerate(found) if "make-cli.sh image" in step)
    sources = [i for i, step in enumerate(found) if "make-cli.sh sources" in step]
    login = next(i for i, step in enumerate(found) if "docker login" in step)
    assert sources == [image + 1] and sources[0] < login, [step.split("\n")[0] for step in found]
    kept = next(step for step in found if "upload-artifact@" in step and "udeck-plugin-image.txt" in step)
    assert "release-cli/udeck-plugin-image-sources-*.tar" in kept
    assert "actions/cache" not in workflow(name)


def test_ci_pins_a_release_whose_sums_name_its_sources_and_checks_them():
    step = next(step for step in steps(jobs(workflow("ci.yml"))["release-assets"]) if "pin --repo" in step)
    assert '"release-cli/udeck-plugin-image-sources-$version.tar" "$releases/download/v$version/"' in step
    assert 'grep " udeck-plugin-image-sources-$version.tar\\$" SHA256SUMS | sha256sum -c -' in step


def test_ci_pins_the_release_it_made_and_reads_the_pin_with_the_reader_in_the_docs():
    block = jobs(workflow("ci.yml"))["release-assets"]
    step = next(step for step in steps(block) if "pin --repo" in step)
    assert 'command="$RUNNER_TEMP/udeck-plugin-$version-linux-x86_64/udeck-plugin"' in step, "the static command from its archive"
    for said in ('"$command" pin --repo "$repo"\n', '"$command" pin --repo "$repo" --check\n',
                 '"$command" pin --repo "$repo" --check --version latest\n', "read_udeck_plugin_lock", "sha256sum -c -",
                 "test \"$status\" -eq 1"):
        assert said in step, said
    docs = (REPO / "docs" / "plugin-repository.md").read_text()
    assert docs.count("\n<!-- lock-reader -->\n```sh\n") == 1 and docs.count("\n```\n<!-- /lock-reader -->\n") == 1


def lock_text(version, digit):
    sums = "".join(f"{platform}={digit * 64}\n" for platform in ("macos-universal", "linux-x86_64", "linux-aarch64"))
    return f"version={version}\n{sums}image=sha256:{digit * 64}\n"


def test_the_ci_example_in_the_docs_reads_the_lock_file_of_the_base_not_the_pull_requests(tmp_path):
    """D2a's review: the example read the checkout's lock file, which a pull request writes."""
    docs = (REPO / "docs" / "plugin-repository.md").read_text()
    after = docs.split("\n<!-- /lock-reader -->\n", 1)[1]
    example = after.split("```sh\n", 1)[1].split("```\n", 1)[0]
    reading = example.split('read_udeck_plugin_lock "$lock" || exit 1\n', 1)
    assert len(reading) == 2, "the example reads the lock file it took from the base"
    assert "read_udeck_plugin_lock .github" not in example, "never the checkout's"
    reader = subprocess.run(["awk", re.findall(r"^LOCK_READER='(.*)'$", (REPO / "Scripts" / "make-cli.sh").read_text(), re.M)[0]],
                            input=docs, capture_output=True, text=True, check=True).stdout

    repo = tmp_path / "plugins-repository"
    (repo / ".github").mkdir(parents=True)
    env = {**os.environ, "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1", "TMPDIR": str(tmp_path)}

    def git(*args):
        return subprocess.run(["git", "-C", str(repo), "-c", "user.name=CI", "-c", "user.email=ci@example.invalid", *args],
                              capture_output=True, text=True, check=True, env=env).stdout.strip()

    git("init", "-q", "-b", "main")
    (repo / "udeck-plugins.json").write_text('{"format": 1, "name": "Docs"}\n')
    git("add", "-A")
    git("commit", "-q", "-m", "No lock file yet")
    bare = git("rev-parse", "HEAD")
    (repo / ".github" / "udeck-plugin.lock").write_text(lock_text("0.6.0", "1"))
    git("add", "-A")
    git("commit", "-q", "-m", "The lock file, merged")
    base = git("rev-parse", "HEAD")
    # The pull request: another release, of its own choosing, in the checkout.
    (repo / ".github" / "udeck-plugin.lock").write_text(lock_text("0.7.0", "2"))
    git("commit", "-q", "-a", "-m", "A pull request that pins what it likes")

    script = reader + reading[0] + 'read_udeck_plugin_lock "$lock" || exit 1\nprintf "%s %s\\n" "$version" "$linux_x86_64"\n'
    for shell in ("/bin/sh", "/bin/bash"):
        done = subprocess.run([shell, "-c", script], cwd=repo, capture_output=True, text=True, env={**env, "BASE_SHA": base})
        assert done.returncode == 0, done.stderr
        assert done.stdout == f"0.6.0 {'1' * 64}\n", "the base's lock file"
        stopped = subprocess.run([shell, "-c", script], cwd=repo, capture_output=True, text=True, env={**env, "BASE_SHA": bare})
        assert stopped.returncode != 0 and stopped.stdout == "", "a base with no lock file chose nothing"


def test_the_image_takes_the_reader_out_of_the_docs_as_ci_does():
    """One awk program, in make-cli.sh and in ci.yml, for the reader between its markers."""
    script = (REPO / "Scripts" / "make-cli.sh").read_text()
    found = re.findall(r"^LOCK_READER='(.*)'$", script, re.M)
    assert len(found) == 1, found
    step = next(step for step in steps(jobs(workflow("ci.yml"))["release-assets"]) if "pin --repo" in step)
    assert f"awk '{found[0]}' \\\n" in step, "ci.yml's awk is make-cli.sh's"
    docs = (REPO / "docs" / "plugin-repository.md").read_text()
    reader = subprocess.run(["awk", found[0]], input=docs, capture_output=True, text=True, check=True).stdout
    assert reader.startswith("# Reads a lock file as udeck-plugin reads it") and "read_udeck_plugin_lock() {" in reader
    assert "```" not in reader and "<!--" not in reader


def test_the_cla_action_is_pinned_by_its_commit():
    uses = re.findall(r"^\s+(?:- )?uses: (.*)$", workflow("cla.yml"), re.M)
    assert uses == ["contributor-assistant/github-action@ca4a40a7d1004f18d9960b404b97e5f30a505a08 # v2.6.1"], uses


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


def test_no_pipeline_ends_in_a_grep_that_leaves_early():
    """Under pipefail, `writer | grep -q` fails whenever grep has its answer
    before the writer is done: the writer dies of SIGPIPE and the pipeline
    reports it. MIT, in the middle of ALPINE_LICENSES, failed CI that way
    (run 37716911865), and `if readelf -l … | grep -q INTERP` would read the
    same failure as "no INTERP". What is looked for is read with a
    here-string instead."""
    for name in ("make-cli.sh", "make-app.sh"):
        script = (REPO / "Scripts" / name).read_text()
        code = [line for line in script.splitlines() if not line.lstrip().startswith("#")]
        found = [line for line in code if re.search(r"\|\s*grep\s+(-\w*q|--quiet)", line)]
        assert found == [], (name, found)
