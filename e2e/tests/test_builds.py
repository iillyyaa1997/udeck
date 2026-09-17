"""Lab builds: the key that never reaches the keychain, and what make-app.sh is asked."""

import base64
import plistlib
import subprocess
import zipfile
from pathlib import Path

import pytest
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

from udeck_e2e import config
from udeck_e2e.builds import Builder, SigningKey, make_key
from udeck_e2e.errors import LabError

FEED = "http://127.0.0.1:8765/appcast.xml"


def done(args, rc=0, out="", err=""):
    return subprocess.CompletedProcess(args, rc, out, err)


class Script:
    """Stands in for Scripts/make-app.sh: records the call, makes what it would make."""

    def __init__(self, rc=0, out="==> Done", err="", leaves_bundle=False, makes_zip=True,
                 wrong_version="", identifier="place.unicorns.udeck"):
        self.rc, self.out, self.err = rc, out, err
        self.leaves_bundle = leaves_bundle
        self.makes_zip = makes_zip
        self.wrong_version = wrong_version
        self.identifier = identifier
        self.calls = []

    def __call__(self, args, **kwargs):
        self.calls.append((args, kwargs))
        options = dict(zip(args[1:], args[2:]))
        out = Path(options["--out"])
        if self.makes_zip:
            plist = {
                "CFBundleShortVersionString": self.wrong_version or options.get("--version"),
                "CFBundleVersion": options.get("--build"),
                "CFBundleIdentifier": self.identifier,
                "SUFeedURL": options.get("--test-feed"),
                "SUPublicEDKey": options.get("--test-key"),
            }
            with zipfile.ZipFile(out / f"uDeck-{options['--version']}.zip", "w") as archive:
                archive.writestr("uDeck.app/Contents/Info.plist", plistlib.dumps(plist))
        if self.leaves_bundle:
            (out / "uDeck.app").mkdir(parents=True, exist_ok=True)
        return done(args, self.rc, self.out, self.err)


def builder(script, tmp_path, key=None, seconds=config.BUILD_SECONDS):
    return Builder(
        repo_root=tmp_path / "repo",
        work_dir=tmp_path / "run" / "builds",
        feed_url=FEED,
        key=key or make_key(tmp_path / "signing"),
        note=lambda text: None,
        run=script,
        seconds=seconds,
    )


# --- The signing key ------------------------------------------------------------------


def test_the_signing_key_is_a_throwaway_seed_on_disk_and_never_the_keychain(tmp_path):
    key = make_key(tmp_path / "signing")
    seed = base64.b64decode(key.private_key_file.read_text())
    assert len(seed) == 32
    # The public key in the bundle belongs to that seed — the whole point of the pair.
    public = Ed25519PrivateKey.from_private_bytes(seed).public_key().public_bytes(
        serialization.Encoding.Raw, serialization.PublicFormat.Raw
    )
    assert base64.b64encode(public).decode() == key.public_key
    # Nobody else on the Mac reads it, and it does not print its own path.
    assert key.private_key_file.stat().st_mode & 0o077 == 0
    assert str(key.private_key_file) not in repr(key)


def test_two_runs_never_share_a_key(tmp_path):
    first, second = make_key(tmp_path / "a"), make_key(tmp_path / "b")
    assert first.public_key != second.public_key


# --- What make-app.sh is asked --------------------------------------------------------


def test_a_lab_build_goes_to_its_own_directory_with_its_own_versions_and_stays_zipped(tmp_path):
    script = Script()
    build = builder(script, tmp_path).build("0.4.1", "6")
    (args, kwargs) = script.calls[0]
    assert args[0].endswith("Scripts/make-app.sh")
    options = dict(zip(args[1:], args[2:]))
    assert options["--version"] == "0.4.1" and options["--build"] == "6"
    assert options["--test-feed"] == FEED
    assert Path(options["--out"]) == tmp_path / "run" / "builds" / "0.4.1-6"
    assert "--zip" in args and "--install" not in args and "--dmg" not in args
    assert "dist" not in options["--out"].split("/")[-3:]
    assert kwargs["timeout"] == config.BUILD_SECONDS
    assert kwargs["cwd"] == str(tmp_path / "repo")
    assert kwargs["stdin"] is subprocess.DEVNULL and kwargs["start_new_session"] is True
    assert build.zip.name == "uDeck-0.4.1.zip" and build.zip.is_file()
    assert (build.zip.parent / "build.log").read_text().startswith("==> Done")


def test_the_public_key_the_bundle_carries_is_this_runs_key(tmp_path):
    script = Script()
    key = make_key(tmp_path / "signing")
    builder(script, tmp_path, key=key).build("0.4.1", "6")
    options = dict(zip(script.calls[0][0][1:], script.calls[0][0][2:]))
    assert options["--test-key"] == key.public_key


def test_a_build_left_unpacked_on_this_mac_is_refused(tmp_path):
    """A lab build carries the release's identifier: an unpacked copy here is a hazard."""
    script = Script(leaves_bundle=True)
    with pytest.raises(LabError, match="left .* unpacked on this Mac"):
        builder(script, tmp_path).build("0.4.1", "6")


def test_a_build_that_failed_says_what_the_script_said_and_keeps_its_log(tmp_path):
    script = Script(rc=1, out="==> Building uDeck", err="error: no such module 'Sparkle'", makes_zip=False)
    with pytest.raises(LabError, match="no such module 'Sparkle'") as raised:
        builder(script, tmp_path).build("0.4.1", "6")
    assert raised.value.step.startswith("building uDeck 0.4.1")
    assert "no such module" in (tmp_path / "run" / "builds" / "0.4.1-6" / "build.log").read_text()


def test_a_build_that_made_no_zip_is_a_lab_error(tmp_path):
    with pytest.raises(LabError, match="is not there"):
        builder(Script(makes_zip=False), tmp_path).build("0.4.1", "6")


def test_a_build_that_hangs_is_a_lab_error_at_its_deadline(tmp_path):
    def hangs(args, **kwargs):
        raise subprocess.TimeoutExpired(args, kwargs["timeout"])

    with pytest.raises(LabError, match="did not finish in 60s"):
        builder(hangs, tmp_path, seconds=60).build("0.4.1", "6")


def test_a_build_that_is_not_the_one_that_was_asked_for_is_refused(tmp_path):
    """The script could ignore an option; a check would then fail for the wrong reason."""
    with pytest.raises(LabError, match="CFBundleShortVersionString is '0.4.0'"):
        builder(Script(wrong_version="0.4.0"), tmp_path).build("0.4.1", "6")
    with pytest.raises(LabError, match="which is the debug application"):
        builder(Script(identifier="place.unicorns.udeck.debug"), tmp_path).build("0.4.1", "6")
    out = tmp_path / "run" / "builds" / "0.4.1-6"
    out.mkdir(parents=True, exist_ok=True)
    (out / "uDeck-0.4.1.zip").write_bytes(b"not a zip at all")
    with pytest.raises(LabError, match="could not read"):
        builder(Script(makes_zip=False), tmp_path).build("0.4.1", "6")


def test_the_lab_never_unpacks_a_build_itself():
    """A lab build may be read, never extracted, on this Mac (Q41)."""
    source = Path(Builder.__module__.replace(".", "/") + ".py")
    text = (Path(__file__).resolve().parents[1] / source).read_text()
    for unpacking in ("ditto -x", "unzip", "extractall", "shutil.unpack", ".extract("):
        assert unpacking not in text, unpacking


# --- The script itself, run for real (it refuses before it builds anything) ------------


MAKE_APP_SH = Path(__file__).resolve().parents[2] / "Scripts" / "make-app.sh"


def run_script(*args):
    return subprocess.run([str(MAKE_APP_SH), *args], capture_output=True, text=True, timeout=60)


def test_the_script_refuses_the_combinations_that_would_leave_a_lab_build_lying_about():
    for args in (["--zip", "--install"], ["--zip", "--dmg"], ["--out", ""]):
        done = run_script(*args)
        assert done.returncode == 2, (args, done.stdout, done.stderr)
    assert "cannot be combined" in run_script("--zip", "--install").stderr
    assert "needs a directory" in run_script("--out", "").stderr
    assert run_script("--what").returncode == 2
