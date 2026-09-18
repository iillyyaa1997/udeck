"""`Scripts/make-app.sh`, run for real against a toy checkout.

The expensive half of that script is `swift build`; everything the lab depends
on is the other half — where the bundle goes, which version it carries, and that
a lab build is left only as a zip. So the build is stubbed and the rest runs as
it does in earnest: PlistBuddy, ditto, codesign and all.
"""

import os
import plistlib
import signal
import shutil
import subprocess
import time
import zipfile
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[2]
FEED = "http://127.0.0.1:8765/appcast.xml"
KEY = "WdWK0Ud4EIQS36TpiZy9POU3i8IY3R7vpo0qwkGEKa4="


@pytest.fixture
def checkout(tmp_path):
    """A directory shaped like the repository, with the build already 'done'."""
    (tmp_path / "Scripts").mkdir()
    for name in ("make-app.sh", "adhoc.entitlements"):
        shutil.copy(REPO / "Scripts" / name, tmp_path / "Scripts" / name)
    support = tmp_path / "Sources" / "uDeck" / "Support"
    support.mkdir(parents=True)
    shutil.copy(REPO / "Sources" / "uDeck" / "Support" / "Info.plist", support / "Info.plist")
    built = tmp_path / ".build" / "release"
    built.mkdir(parents=True)
    # A real Mach-O, so that codesign has something it can actually sign.
    shutil.copy("/bin/echo", built / "uDeck")
    stubs = tmp_path / "stubs"
    stubs.mkdir()
    (stubs / "swift").write_text("#!/bin/sh\nexit 0\n")
    (stubs / "swift").chmod(0o755)
    return tmp_path


def make_app(checkout, *args):
    return subprocess.run(
        [str(checkout / "Scripts" / "make-app.sh"), *args],
        capture_output=True,
        text=True,
        timeout=180,
        cwd=str(checkout),
        env={**os.environ, "PATH": f"{checkout / 'stubs'}:{os.environ['PATH']}"},
    )


def plist_in(zip_path):
    with zipfile.ZipFile(zip_path) as archive:
        return plistlib.loads(archive.read("uDeck.app/Contents/Info.plist"))


def test_a_lab_build_lands_where_it_was_told_carries_both_versions_and_leaves_only_a_zip(checkout):
    done = make_app(
        checkout, "--out", "lab-builds", "--version", "9.9.9", "--build", "99",
        "--zip", "--test-feed", FEED, "--test-key", KEY,
    )  # fmt: skip
    assert done.returncode == 0, done.stdout + done.stderr

    out = checkout / "lab-builds"
    assert [p.name for p in out.iterdir()] == ["uDeck-9.9.9.zip"]
    assert not (checkout / "dist").exists()

    plist = plist_in(out / "uDeck-9.9.9.zip")
    assert plist["CFBundleShortVersionString"] == "9.9.9"
    # What Sparkle compares when it decides whether an update is newer.
    assert plist["CFBundleVersion"] == "99"
    assert plist["SUFeedURL"] == FEED and plist["SUPublicEDKey"] == KEY
    assert plist["NSAppTransportSecurity"] == {"NSAllowsLocalNetworking": True}
    # A lab build is the released application, identifier and all.
    assert plist["CFBundleIdentifier"] == "place.unicorns.udeck"


def test_a_build_with_no_options_still_goes_to_dist_and_keeps_the_plists_versions(checkout):
    done = make_app(checkout)
    assert done.returncode == 0, done.stdout + done.stderr
    app = checkout / "dist" / "uDeck.app"
    assert app.is_dir()
    plist = plistlib.loads((app / "Contents" / "Info.plist").read_bytes())
    original = plistlib.loads((checkout / "Sources/uDeck/Support/Info.plist").read_bytes())
    assert plist["CFBundleShortVersionString"] == original["CFBundleShortVersionString"]
    assert plist["CFBundleVersion"] == original["CFBundleVersion"]
    assert plist["SUFeedURL"] == original["SUFeedURL"]


def test_a_debug_build_is_its_own_application_wherever_it_is_built(checkout):
    shutil.copytree(checkout / ".build" / "release", checkout / ".build" / "debug")
    done = make_app(checkout, "--debug", "--out", "elsewhere")
    assert done.returncode == 0, done.stdout + done.stderr
    plist = plistlib.loads((checkout / "elsewhere" / "uDeck-debug.app" / "Contents" / "Info.plist").read_bytes())
    assert plist["CFBundleIdentifier"] == "place.unicorns.udeck.debug"
    assert "SUFeedURL" not in plist


def test_a_build_that_dies_after_assembly_leaves_no_bundle_behind(checkout):
    """The bundle carries the release's identifier: it must not outlive a failed build."""
    (checkout / "stubs" / "codesign").write_text("#!/bin/sh\necho 'codesign: the disk is full' >&2\nexit 1\n")
    (checkout / "stubs" / "codesign").chmod(0o755)
    done = make_app(
        checkout, "--out", "lab-builds", "--version", "9.9.9", "--build", "99",
        "--zip", "--test-feed", FEED, "--test-key", KEY,
    )  # fmt: skip
    assert done.returncode != 0
    assert not (checkout / "lab-builds" / "uDeck.app").exists(), sorted(p.name for p in (checkout / "lab-builds").iterdir())


def start_a_build_that_waits(checkout, seconds=60):
    """A build stopped at ditto, with the bundle already assembled."""
    (checkout / "stubs" / "ditto").write_text(f"#!/bin/sh\nsleep {seconds}\n")
    (checkout / "stubs" / "ditto").chmod(0o755)
    process = subprocess.Popen(
        [str(checkout / "Scripts" / "make-app.sh"), "--out", "lab-builds", "--version", "9.9.9",
         "--build", "99", "--zip", "--test-feed", FEED, "--test-key", KEY],
        cwd=str(checkout), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        env={**os.environ, "PATH": f"{checkout / 'stubs'}:{os.environ['PATH']}"},
        start_new_session=True,
    )  # fmt: skip
    deadline = time.monotonic() + 30
    while not (checkout / "lab-builds" / "uDeck.app").exists() and time.monotonic() < deadline:
        time.sleep(0.05)
    assert (checkout / "lab-builds" / "uDeck.app").exists(), "the bundle was never assembled"
    return process


def test_a_build_stopped_by_a_signal_leaves_no_bundle_behind(checkout):
    """How the lab ends a build that overran: SIGTERM to the whole process group.

    Ten times over, because the hole this closes was a race — with only an EXIT
    trap the bundle survived twice in twenty tries, bash having died from the
    signal without running it.
    """
    for _ in range(10):
        process = start_a_build_that_waits(checkout)
        os.killpg(os.getpgid(process.pid), signal.SIGTERM)
        process.wait(timeout=30)
        assert not (checkout / "lab-builds" / "uDeck.app").exists()


def test_the_bundle_is_armed_for_removal_against_signals_as_well_as_failures(checkout):
    """The invariant behind the test above, where a race could otherwise hide it."""
    script = (checkout / "Scripts" / "make-app.sh").read_text()
    assert """trap 'rm -rf "$APP"' EXIT""" in script
    assert """trap 'rm -rf "$APP"; exit 130' INT""" in script
    assert """trap 'rm -rf "$APP"; exit 143' TERM""" in script


def test_a_build_killed_while_it_waits_takes_its_bundle_once_the_step_it_ran_returns(checkout):
    """`kill` on the script alone: bash acts on the signal when the running step ends."""
    process = start_a_build_that_waits(checkout, seconds=2)
    process.terminate()  # the shell alone, not its process group
    assert process.wait(timeout=30) == 143
    assert not (checkout / "lab-builds" / "uDeck.app").exists()


def test_a_zip_without_an_out_directory_is_refused_so_dist_is_never_emptied(checkout):
    done = make_app(checkout, "--zip")
    assert done.returncode == 2 and "--zip needs --out" in done.stderr
    assert not (checkout / "dist").exists()




def test_the_options_that_would_leave_a_lab_build_lying_about_are_refused(checkout):
    """Refusals, checked against a toy checkout — never the repository's own dist/."""
    for args in (["--zip", "--install"], ["--zip", "--dmg"], ["--out", ""], ["--what"]):
        done = make_app(checkout, *args)
        assert done.returncode == 2, (args, done.stdout, done.stderr)
    assert "cannot be combined" in make_app(checkout, "--zip", "--install").stderr
    assert "needs a directory" in make_app(checkout, "--out", "").stderr
    assert not (checkout / "dist").exists()


# The one other file allowed to reach the checkout, and what it may do there:
# read uDeck's own gesture defaults, so the lab's push can be checked against
# the numbers it has to clear. Reading a source file cannot build anything.
MAY_READ_THE_CHECKOUT = {"test_panel.py"}


def test_this_is_the_only_file_that_runs_anything_in_the_repository():
    """Running the real script from a test can build in the checkout and empty dist/.

    It happened: a mutation that disabled one of the script's refusals let a test
    in tests/test_builds.py build for real and take dist/uDeck.app with it
    (2026-09-17). Here the script only ever runs against a toy checkout in a
    temporary directory.

    So: no other test file may reach the repository — `parents[2]` from tests/ is
    its root — except the few that only *read* a file there, and those may not
    start a process at all. That is the line the incident drew; a test that both
    knows where the checkout is and can run something in it is the thing to keep
    from existing.
    """
    for path in sorted(Path(__file__).parent.glob("test_*.py")):
        if path.name == Path(__file__).name:
            continue
        text = path.read_text()
        if "parents[2]" not in text:
            continue
        assert path.name in MAY_READ_THE_CHECKOUT, f"{path.name} reaches the checkout"
        for running in ("subprocess", "Popen", "os.system", "pytester"):
            assert running not in text, f"{path.name} reaches the checkout and can run {running}"
