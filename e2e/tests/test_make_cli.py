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
PUSHED = "sha256:" + "a" * 64
BUILT = "sha256:" + "b" * 64
ON_A_MAC = platform.system() == "Darwin"


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
    found = members(archive)
    assert sorted(found) == [folder, f"{folder}/LICENSE", f"{folder}/NOTICE", f"{folder}/udeck-plugin"]
    assert found[f"{folder}/udeck-plugin"].mode & 0o111
    assert {(m.uid, m.gid) for m in found.values()} == {(0, 0)}, "nothing of the machine it was made on"

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
    found = members(archive)
    assert sorted(found) == [folder, f"{folder}/LICENSE", f"{folder}/NOTICE", f"{folder}/udeck-plugin"]
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
        ([], "Usage:"),
    ):
        done = make_cli(checkout, *args)
        assert done.returncode == 2, (args, done.stdout, done.stderr)
        assert said in done.stderr, (args, done.stderr)


# --- sums ---------------------------------------------------------------------------------------


def toy_archives(out, version=VERSION, platforms=("macos-universal", "linux-x86_64", "linux-aarch64")):
    out.mkdir(parents=True, exist_ok=True)
    for name in platforms:
        (out / f"udeck-plugin-{version}-{name}.tar.gz").write_bytes(f"archive {version} {name}\n".encode())


def test_sums_cover_the_three_archives_and_the_image_and_say_what_sha256sum_says(checkout):
    out = checkout / "out"
    toy_archives(out)
    (out / "udeck-plugin-image.txt").write_text(f"image=ghcr.io/x/udeck-plugin\ndigest={PUSHED}\n")
    (out / "notes.txt").write_text("not an asset\n")
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
        (lambda out: toy_archives(out, platforms=("macos-universal", "linux-x86_64")), "no udeck-plugin-9.9.9-linux-aarch64"),
        (lambda out: (toy_archives(out), toy_archives(out, "9.9.8", ("linux-x86_64",))), "more than one version"),
        (lambda out: (toy_archives(out), toy_archives(out, platforms=("linux-riscv64",))), "no release names"),
        (lambda out: toy_archives(out, "9.9.8"), "this release is 9.9.9"),
        (lambda out: out.mkdir(), "no udeck-plugin archive"),
    ],
)
def test_sums_refuse_a_set_a_release_would_not_publish(checkout, arrange, said):
    arrange(checkout / "out")
    done = make_cli(checkout, "sums", "--version", VERSION, "--out", "out")
    assert done.returncode == 1, done.stdout + done.stderr
    assert said in done.stderr
    assert not (checkout / "out" / "SHA256SUMS").exists()


# --- image --------------------------------------------------------------------------------------

DOCKER = r"""#!/bin/sh
# One line a call, a script given to `sh -c` included.
printf '%s\n' "$*" | tr '\n' ' ' | sed 's/ *$//' >> "$DOCKER_LOG"
echo >> "$DOCKER_LOG"
case "$1 $2" in
    "buildx build")
        metadata=""
        push=0
        previous=""
        for arg in "$@"; do
            [ "$previous" = "--metadata-file" ] && metadata="$arg"
            [ "$arg" = "--push" ] && push=1
            previous="$arg"
            context="$arg"
        done
        mkdir -p "$DOCKER_SEEN"
        cp "$context/amd64/udeck-plugin" "$DOCKER_SEEN/amd64"
        cp "$context/arm64/udeck-plugin" "$DOCKER_SEEN/arm64"
        cp "$context/Dockerfile" "$DOCKER_SEEN/Dockerfile"
        if [ -n "$metadata" ]; then
            if [ "$push" = 1 ]; then digest="sha256:PUSHED"; else digest="sha256:BUILT"; fi
            printf '{\n  "buildx.build.ref": "x",\n  "containerimage.digest": "%s"\n}\n' "$digest" > "$metadata"
        fi
        exit 0 ;;
    "buildx imagetools")
        echo '{"manifests": [{"platform": {"architecture": "amd64", "os": "linux"}}, {"platform": {"architecture": "arm64", "os": "linux"}}]}'
        exit 0 ;;
    "image inspect") echo 12345; exit 0 ;;
esac
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
""".replace("sha256:PUSHED", PUSHED).replace("sha256:BUILT", BUILT)


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


def run_image(checkout, *args, **env):
    log = checkout / "docker.log"
    done = make_cli(checkout, "image", "--out", "out", "--revision", "c0ffee", *args,
                    DOCKER_LOG=str(log), DOCKER_SEEN=str(checkout / "seen"), **env)  # fmt: skip
    calls = log.read_text().splitlines() if log.exists() else []
    return done, calls


def test_an_image_is_built_and_run_on_both_platforms_and_published_nowhere_without_push(image):
    done, calls = run_image(image)
    assert done.returncode == 0, done.stdout + done.stderr
    assert not any("--push" in call or "login" in call or "imagetools" in call for call in calls), calls
    assert not (image / "out" / "udeck-plugin-image.txt").exists()
    assert any(call.startswith("run --privileged --rm tonistiigi/binfmt:") and call.endswith("--install arm64") for call in calls)
    multi = [call for call in calls if call.startswith("buildx build") and "--platform linux/amd64,linux/arm64" in call]
    assert len(multi) == 1 and "type=oci" in multi[0] and "--provenance=false" in multi[0]
    for platform in ("linux/amd64", "linux/arm64"):
        runs = [call for call in calls if call.startswith(f"run --rm --network none --platform {platform}")]
        assert any("udeck-plugin --version" in call for call in runs), platform
        assert any("check --strict /udeck/examples/" in call and ":/udeck:ro" in call for call in runs), platform
        assert any("check-repo" in call and ":/examples:ro" in call for call in runs), platform
    # The binaries the image is built from are the ones the archives carry.
    for arch, platform in (("x86_64", "amd64"), ("aarch64", "arm64")):
        assert (image / "seen" / platform).read_text() == f"#!/bin/sh\necho the {arch} binary\n"
    assert (image / "seen" / "Dockerfile").read_text() == (REPO / "Scripts" / "udeck-plugin.Dockerfile").read_text()
    assert f"an index of digest {BUILT}, not published" in done.stdout
    assert left_behind(image) == []
    assert any(call.startswith("buildx rm --force udeck-plugin-") for call in calls), "the builder is taken away"


def test_with_push_the_image_is_pushed_once_after_both_platforms_ran_and_its_digest_is_written(image):
    done, calls = run_image(image, "--version", VERSION, "--push")
    assert done.returncode == 0, done.stdout + done.stderr
    pushes = [i for i, call in enumerate(calls) if "--push" in call]
    assert len(pushes) == 1, calls
    pushed = calls[pushes[0]]
    assert f"--tag ghcr.io/iillyyaa1997/udeck-plugin:v{VERSION}" in pushed
    assert "--platform linux/amd64,linux/arm64" in pushed and "--provenance=false" in pushed and "--sbom=false" in pushed
    assert "--build-arg VERSION=9.9.9" in pushed and "--build-arg REVISION=c0ffee" in pushed
    assert "index:org.opencontainers.image.source=https://github.com/iillyyaa1997/udeck" in pushed
    last_run = max(i for i, call in enumerate(calls) if call.startswith("run --rm"))
    assert last_run < pushes[0], "both platforms run before anything is pushed"
    assert any(call == f"buildx imagetools inspect --raw ghcr.io/iillyyaa1997/udeck-plugin@{PUSHED}" for call in calls)
    assert (image / "out" / "udeck-plugin-image.txt").read_text() == (
        "image=ghcr.io/iillyyaa1997/udeck-plugin\n"
        f"tag=v{VERSION}\n"
        f"digest={PUSHED}\n"
        "platforms=linux/amd64,linux/arm64\n"
    )


@pytest.mark.parametrize(
    ("env", "said"),
    [
        ({"FAKE_ARM64_SAYS": "9.9.8"}, "in the image (linux/arm64) udeck-plugin says"),
        ({"FAKE_ONE_EXAMPLE": "1"}, "1 of 2 examples checked clean"),
        ({"FAKE_CHECK_REPO": "1"}, "check-repo on a repository made in the image"),
    ],
)
def test_an_image_that_does_not_do_its_work_on_either_platform_is_never_pushed(image, env, said):
    done, calls = run_image(image, "--version", VERSION, "--push", **env)
    assert done.returncode == 1, done.stdout + done.stderr
    assert said in done.stderr
    assert not any("--push" in call for call in calls)
    assert not (image / "out" / "udeck-plugin-image.txt").exists()
    assert left_behind(image) == []


def test_an_image_of_another_version_than_the_release_is_refused_before_anything_runs(image):
    done, calls = run_image(image, "--version", "9.9.8", "--push")
    assert done.returncode == 1 and "this release is 9.9.8" in done.stderr
    assert calls == []


def test_the_image_and_what_builds_it_are_pinned_by_digest_and_say_where_they_come_from():
    dockerfile = (REPO / "Scripts" / "udeck-plugin.Dockerfile").read_text()
    assert re.search(r"^FROM alpine:[0-9.]+@sha256:[0-9a-f]{64}$", dockerfile, re.M), "the base by digest"
    assert "RUN apk add --no-cache git" in dockerfile, "check and check-repo start git"
    assert not re.search(r"^ENTRYPOINT", dockerfile, re.M), "GitLab CI hands the job's script to the image's shell"
    for label in ("source=\"https://github.com/iillyyaa1997/udeck\"", "version=\"${VERSION}\"", "licenses=\"Apache-2.0\""):
        assert f"org.opencontainers.image.{label}" in dockerfile
    script = (REPO / "Scripts" / "make-cli.sh").read_text()
    for name in ("BUILDKIT", "BINFMT"):
        assert re.search(rf'^{name}="[a-z/]+:[A-Za-z0-9.-]+@sha256:[0-9a-f]{{64}}"$', script, re.M), name


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
    assert "make-cli.sh image" in blocks["image"] and "--push" in blocks["image"]
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
    assert "make-cli.sh sums" in blocks["publish"]
    assert "--generate-notes" in create and "$digest" in blocks["publish"]


def test_archives_never_go_where_generate_appcast_reads():
    text = workflow("release.yml")
    assert re.search(r"generate_appcast\"? \\\n(?:.*\\\n)*\s+release/$", text, re.M), "the appcast is written from release/"
    for line in re.findall(r"^.*make-cli\.sh (?:macos|linux|image).*$", text, re.M):
        assert "--out release-cli" in line, line


def test_ci_makes_what_a_release_publishes_on_every_push_and_publishes_nothing():
    text = workflow("ci.yml")
    blocks = jobs(text)
    assert "make-cli.sh macos" in blocks["build-and-test"]
    assert "make-cli.sh linux" in blocks["plugin-format-linux"]
    assert "make-cli.sh image" in blocks["udeck-plugin-image"]
    assert "make-cli.sh sums" in blocks["release-assets"]
    for forbidden in ("--push", "docker login", "gh release", "packages: write", "contents: write"):
        assert forbidden not in text, forbidden


def test_the_command_in_an_archive_is_signed_as_the_one_inside_udeck_app():
    make_app = (REPO / "Scripts" / "make-app.sh").read_text()
    make_cli = (REPO / "Scripts" / "make-cli.sh").read_text()
    for line in ('SIGN_FLAGS=(--force --options runtime --sign "$IDENTITY")', 'if [ "$IDENTITY" = "-" ]; then',
                 "    SIGN_FLAGS+=(--entitlements Scripts/adhoc.entitlements)"):  # fmt: skip
        assert line in make_app and line in make_cli, line
