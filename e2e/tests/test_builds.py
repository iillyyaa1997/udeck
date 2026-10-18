"""Lab builds: the key that never reaches the keychain, and what make-app.sh is asked."""

import base64
import plistlib
import signal
import subprocess
import zipfile
from pathlib import Path

import pytest
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

from udeck_e2e import builds, config, plugin_repository
from udeck_e2e.builds import Builder, SigningKey, make_key
from udeck_e2e.errors import LabError

FEED = "http://127.0.0.1:8765/appcast.xml"


def done(args, rc=0, out="", err=""):
    return subprocess.CompletedProcess(args, rc, out, err)


class Process:
    """A `make-app.sh` that has been started: answers like Popen, kills like Popen."""

    def __init__(self, script):
        self.script = script
        script.process = self
        self.pid = 4242
        self.returncode = None
        self._left = script.timeouts

    def communicate(self, timeout=None):
        if timeout is not None and self._left > 0:
            self._left -= 1
            raise subprocess.TimeoutExpired(self.script.args, timeout, output=self.script.out, stderr=self.script.err)
        if timeout is not None and self.script.interrupts:
            # Ctrl-C while the lab was waiting for the build.
            self.script.interrupts = False
            raise KeyboardInterrupt
        if self.returncode is None:
            self.returncode = self.script.rc if not self.script.stopped else -15
        return self.script.out, self.script.err

    def poll(self):
        return self.returncode


class Script:
    """Stands in for Scripts/make-app.sh: records the call, makes what it would make."""

    def __init__(self, rc=0, out="==> Done", err="", leaves_bundle=False, makes_zip=True,
                 wrong_version="", identifier="place.unicorns.udeck", timeouts=0, interrupts=False,
                 ignores_test_plugins=False, local_networking=True, ignores_repository_id=False,
                 ignores_host_map=False, host_map=None):
        self.rc, self.out, self.err = rc, out, err
        self.leaves_bundle = leaves_bundle
        self.makes_zip = makes_zip
        self.wrong_version = wrong_version
        self.identifier = identifier
        self.timeouts = timeouts
        self.interrupts = interrupts
        # A make-app.sh that dropped --test-plugins leaves the addresses the
        # application ships with, which are GitHub's.
        self.ignores_test_plugins = ignores_test_plugins
        self.local_networking = local_networking
        # A make-app.sh that set the fake's addresses and kept the number the
        # application ships with for the official repository, which is GitHub's.
        self.ignores_repository_id = ignores_repository_id
        # A make-app.sh that wrote no host map for the GitLabs the fake answers as — or wrote another one.
        self.ignores_host_map = ignores_host_map
        self.host_map = host_map
        self.stopped = False
        self.ignores_sigterm = False
        self.process = None
        self.signals = []
        self.calls = []
        self.args = []

    def __call__(self, args, **kwargs):
        self.calls.append((args, kwargs))
        self.args = args
        options = dict(zip(args[1:], args[2:]))
        out = Path(options["--out"])
        if self.makes_zip:
            plist = {
                "CFBundleShortVersionString": self.wrong_version or options.get("--version"),
                "CFBundleVersion": options.get("--build"),
                "CFBundleIdentifier": self.identifier,
                "SUFeedURL": options.get("--test-feed"),
                "SUPublicEDKey": options.get("--test-key"),
                # What Sources/uDeck/Support/Info.plist ships, and what
                # make-app.sh sets from --test-plugins.
                "UDeckPluginsAPIBase": "https://api.github.com",
                "UDeckPluginsRawBase": "https://raw.githubusercontent.com",
                "UDeckPluginsRepository": "iillyyaa1997/udeck-plugins",
                "UDeckPluginsRepositoryID": 1393324153,
            }
            base = (options.get("--test-plugins") or "").rstrip("/")
            if base and not self.ignores_test_plugins:
                plist["UDeckPluginsAPIBase"] = f"{base}/api"
                plist["UDeckPluginsRawBase"] = f"{base}/raw"
                if not self.ignores_repository_id:
                    plist["UDeckPluginsRepositoryID"] = 900000001
                if not self.ignores_host_map:
                    plist["UDeckPluginsHostMap"] = self.host_map or builds.host_map(base)
            elif self.host_map is not None:
                plist["UDeckPluginsHostMap"] = self.host_map
            if (options.get("--test-feed") or base) and self.local_networking:
                plist["NSAppTransportSecurity"] = {"NSAllowsLocalNetworking": True}
            with zipfile.ZipFile(out / f"uDeck-{options['--version']}.zip", "w") as archive:
                archive.writestr("uDeck.app/Contents/Info.plist", plistlib.dumps(plist))
        if self.leaves_bundle:
            (out / "uDeck.app").mkdir(parents=True, exist_ok=True)
        return Process(self)

    def killpg(self, group, sig):
        self.signals.append(sig)
        if sig == signal.SIGTERM and self.ignores_sigterm:
            return
        self.stopped = True
        # A build that was signalled dies, as a real one does.
        self.process.returncode = -15 if sig == signal.SIGTERM else -9


class Clock:
    """Moves only when something waits on it, so a loop with no end shows up as one."""

    def __init__(self):
        self.now = 0.0

    def __call__(self):
        return self.now

    def sleep(self, seconds):
        self.now += seconds


def builder(script, tmp_path, key=None, seconds=config.BUILD_SECONDS, feed=FEED):
    killpg = script.killpg if isinstance(script, Script) else (lambda group, sig: None)
    clock = Clock()
    return Builder(
        repo_root=tmp_path / "repo",
        work_dir=tmp_path / "run" / "builds",
        feed_url=feed,
        key=key or make_key(tmp_path / "signing"),
        note=lambda text: None,
        popen=script,
        seconds=seconds,
        sleep=clock.sleep,
        clock=clock,
        killpg=killpg,
        getpgid=lambda pid: pid,
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


def digest(feed=FEED):
    import hashlib

    return hashlib.sha256(feed.encode()).hexdigest()[:8]


def test_a_lab_build_goes_to_its_own_directory_with_its_own_versions_and_stays_zipped(tmp_path):
    script = Script()
    build = builder(script, tmp_path).build("0.4.1", "6")
    (args, kwargs) = script.calls[0]
    assert args[0].endswith("Scripts/make-app.sh")
    options = dict(zip(args[1:], args[2:]))
    assert options["--version"] == "0.4.1" and options["--build"] == "6"
    assert options["--test-feed"] == FEED
    assert Path(options["--out"]) == tmp_path / "run" / "builds" / digest() / "0.4.1-6"
    assert "--zip" in args and "--install" not in args and "--dmg" not in args
    assert "dist" not in options["--out"].split("/")[-3:]
    assert kwargs["cwd"] == str(tmp_path / "repo")
    assert kwargs["stdin"] is subprocess.DEVNULL and kwargs["start_new_session"] is True
    assert build.zip.name == "uDeck-0.4.1.zip" and build.zip.is_file()
    assert (build.zip.parent / "build.log").read_text().startswith("==> Done")


def test_every_lab_build_reads_its_plugin_catalogue_from_the_fake_in_the_guest(tmp_path):
    """A lab build reads the catalogue by itself after every launch: never from github.com."""
    script = Script()
    builder(script, tmp_path).build("0.4.1", "6")
    options = dict(zip(script.calls[0][0][1:], script.calls[0][0][2:]))
    assert options["--test-plugins"] == plugin_repository.base_url() == f"http://127.0.0.1:{config.PLUGINS_PORT}"


def test_a_build_that_would_read_github_is_refused(tmp_path):
    """The mutant: make-app.sh without --test-plugins, and the build keeps GitHub's addresses."""
    with pytest.raises(LabError, match="UDeckPluginsAPIBase is 'https://api.github.com'") as raised:
        builder(Script(ignores_test_plugins=True), tmp_path).build("0.4.1", "6")
    assert "UDeckPluginsRawBase is 'https://raw.githubusercontent.com'" in raised.value.reason


def _shipped(tmp_path, api="https://api.github.com", number=1393324153):
    """The checkout's Info.plist, as Sources/uDeck/Support/Info.plist ships the catalogue's addresses and number."""
    plist = tmp_path / "repo" / "Sources" / "uDeck" / "Support" / "Info.plist"
    plist.parent.mkdir(parents=True, exist_ok=True)
    plist.write_bytes(plistlib.dumps({"UDeckPluginsAPIBase": api, "UDeckPluginsRawBase": "https://raw.githubusercontent.com",
                                      "UDeckPluginsRepositoryID": number}))


def test_every_lab_build_carries_the_fakes_number_for_the_official_repository(tmp_path):
    """The mutant: make-app.sh pointed the catalogue at the fake and kept GitHub's number, which the fake never answers."""
    builder(Script(), tmp_path).build("0.4.1", "6")
    with pytest.raises(LabError, match="UDeckPluginsRepositoryID is 1393324153, not 900000001"):
        builder(Script(ignores_repository_id=True), tmp_path / "again").build("0.4.1", "6")


def test_every_lab_build_carries_the_host_map_of_the_fakes_gitlabs_and_no_other(tmp_path):
    """Each GitLab the fake answers as, on its own port of the fake's host (stage 4, R2): a build without the map, or
    with another, is refused."""
    assert builds.host_map("http://127.0.0.1:8766") == {"gitlab.example.test": "http://127.0.0.1:8768",
                                                        "gitlab.com": "http://127.0.0.1:8769"}
    assert builds.host_map(plugin_repository.base_url()) == {host: f"http://127.0.0.1:{port}"
                                                             for host, port in config.GITLAB_PORTS.items()}
    builder(Script(), tmp_path).build("0.4.1", "6")
    with pytest.raises(LabError, match="UDeckPluginsHostMap is None, not"):
        builder(Script(ignores_host_map=True), tmp_path / "without").build("0.4.1", "6")
    with pytest.raises(LabError, match="UDeckPluginsHostMap is .*gitlab.example.test.*8766"):
        builder(Script(host_map={"gitlab.example.test": "http://127.0.0.1:8766"}), tmp_path / "another").build("0.4.1", "6")


def test_the_smokes_build_carries_no_host_map_and_a_checkout_that_ships_one_gives_none(tmp_path):
    """A build as shipped, and the smoke's, carry no host map: one there would send a host's requests elsewhere."""
    _shipped(tmp_path)
    the_builder = builder(Script(), tmp_path)
    the_builder.plugins_url = None
    the_builder.build("0.4.1", "6")
    the_builder = builder(Script(host_map={"gitlab.com": "http://127.0.0.1:8769"}), tmp_path)
    the_builder.plugins_url = None
    with pytest.raises(LabError, match="UDeckPluginsHostMap is .*a build as shipped carries none"):
        the_builder.build("0.4.1", "6")
    plist = tmp_path / "repo" / "Sources" / "uDeck" / "Support" / "Info.plist"
    shipped = plistlib.loads(plist.read_bytes())
    plist.write_bytes(plistlib.dumps({**shipped, "UDeckPluginsHostMap": {"gitlab.com": "http://127.0.0.1:8769"}}))
    the_builder = builder(Script(), tmp_path)
    the_builder.plugins_url = None
    with pytest.raises(LabError, match="ships UDeckPluginsHostMap"):
        the_builder.build("0.4.1", "6")


def test_the_smokes_build_carries_githubs_own_number_and_a_checkout_that_does_not_ship_it_gives_none(tmp_path):
    """smoke.real-pull-request's build keeps 1393324153, and the shipped plist is held to it."""
    _shipped(tmp_path)
    the_builder = builder(Script(), tmp_path)
    the_builder.plugins_url = None
    the_builder.build("0.4.1", "6")
    _shipped(tmp_path, number=900000001)
    the_builder = builder(Script(), tmp_path)
    the_builder.plugins_url = None
    with pytest.raises(LabError, match="ships UDeckPluginsRepositoryID 900000001, not GitHub's own 1393324153"):
        the_builder.build("0.4.1", "6")


def test_the_smokes_build_keeps_githubs_addresses_and_is_held_to_them(tmp_path):
    """smoke.real-pull-request's build: no --test-plugins, and the addresses the checkout ships."""
    _shipped(tmp_path)
    script = Script()
    the_builder = builder(script, tmp_path)
    the_builder.plugins_url = None
    the_builder.build("0.4.1", "6")
    assert "--test-plugins" not in script.calls[0][0]
    # A make-app.sh that pointed it at the fake all the same is refused.
    script = Script()
    the_builder = builder(script, tmp_path)
    the_builder.plugins_url = None
    script_calls = script.__call__

    def at_the_fake(args, **kwargs):
        return script_calls([*args, "--test-plugins", "http://127.0.0.1:1"], **kwargs)

    the_builder._popen = at_the_fake
    with pytest.raises(LabError, match="UDeckPluginsAPIBase is 'http://127.0.0.1:1/api', not 'https://api.github.com'"):
        the_builder.build("0.4.1", "6")


def test_a_checkout_that_does_not_ship_githubs_addresses_gives_the_smoke_no_build(tmp_path):
    _shipped(tmp_path, api="http://127.0.0.1:8766/api")
    the_builder = builder(Script(), tmp_path)
    the_builder.plugins_url = None
    with pytest.raises(LabError, match="does not ship GitHub's own addresses"):
        the_builder.build("0.4.1", "6")


def test_a_build_that_cannot_speak_plain_http_to_the_fake_is_refused(tmp_path):
    """Without local networking every request to the fake fails inside uDeck, and reads as silence."""
    with pytest.raises(LabError, match="without NSAllowsLocalNetworking"):
        builder(Script(local_networking=False), tmp_path).build("0.4.1", "6")


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
    assert "no such module" in (tmp_path / "run" / "builds" / digest() / "0.4.1-6" / "build.log").read_text()


def test_a_build_that_made_no_zip_is_a_lab_error(tmp_path):
    with pytest.raises(LabError, match="is not there"):
        builder(Script(makes_zip=False), tmp_path).build("0.4.1", "6")


def test_a_build_that_hangs_is_stopped_whole_and_keeps_the_log_of_how_far_it_got(tmp_path):
    """A shell that starts a compiler: killing the shell alone leaves swift build running."""
    script = Script(timeouts=1, out="==> Building uDeck 0.4.1 for release", makes_zip=False)
    with pytest.raises(LabError, match="did not finish in 60s"):
        builder(script, tmp_path, seconds=60).build("0.4.1", "6")
    assert script.signals[0] == signal.SIGTERM
    log = (tmp_path / "run" / "builds" / digest() / "0.4.1-6" / "build.log").read_text()
    assert "==> Building uDeck 0.4.1" in log and "killed at the deadline" in log


def test_ctrl_c_during_a_build_does_not_leave_it_running(tmp_path):
    script = Script(interrupts=True, makes_zip=False)
    with pytest.raises(KeyboardInterrupt):
        builder(script, tmp_path).build("0.4.1", "6")
    assert script.signals[0] == signal.SIGTERM


def test_builds_for_two_feeds_do_not_overwrite_each_other(tmp_path):
    """Two checks, each serving its own appcast, build the same versions."""
    first = builder(Script(), tmp_path, feed="http://127.0.0.1:8765/appcast.xml").build("0.4.1", "6")
    second = builder(Script(), tmp_path, feed="http://127.0.0.1:8899/appcast.xml").build("0.4.1", "6")
    assert first.zip != second.zip and first.zip.is_file() and second.zip.is_file()


def test_a_bundle_the_build_left_behind_is_removed_even_when_the_build_failed(tmp_path):
    """It carries the release's identifier: launching it would take the release's login item."""
    script = Script(rc=1, err="error: no space left on device", makes_zip=False, leaves_bundle=True)
    with pytest.raises(LabError, match="no space left"):
        builder(script, tmp_path).build("0.4.1", "6")
    assert not (tmp_path / "run" / "builds" / digest() / "0.4.1-6" / "uDeck.app").exists()


def test_a_build_that_is_not_the_one_that_was_asked_for_is_refused(tmp_path):
    """The script could ignore an option; a check would then fail for the wrong reason."""
    with pytest.raises(LabError, match="CFBundleShortVersionString is '0.4.0'"):
        builder(Script(wrong_version="0.4.0"), tmp_path).build("0.4.1", "6")
    with pytest.raises(LabError, match="which is the debug application"):
        builder(Script(identifier="place.unicorns.udeck.debug"), tmp_path).build("0.4.1", "6")
    out = tmp_path / "run" / "builds" / digest() / "0.4.1-6"
    out.mkdir(parents=True, exist_ok=True)
    (out / "uDeck-0.4.1.zip").write_bytes(b"not a zip at all")
    with pytest.raises(LabError, match="could not read"):
        builder(Script(makes_zip=False), tmp_path).build("0.4.1", "6")


def test_the_lab_never_unpacks_a_build_on_this_mac():
    """A lab build may be read, never extracted, on this Mac (Q41).

    Every module, not only the one that builds: the guard is about the Mac, and
    the code that unpacks has moved twice already — it is `app.install` now, and
    it unpacks in the guest, where it belongs. So `ditto -x` is allowed in
    exactly one file, which has to be named here, and a second one has to be
    argued for.
    """
    package = Path(Builder.__module__.replace(".", "/")).parent
    here = Path(__file__).resolve().parents[1]
    sources = sorted((here / package).glob("*.py"))
    assert len(sources) > 5, sources
    for source in sources:
        text = source.read_text()
        for unpacking in ("unzip", "extractall", "shutil.unpack", ".extract("):
            assert unpacking not in text, f"{source.name}: {unpacking}"
        if "ditto -x" in text:
            assert source.name == "app.py", f"{source.name} unpacks a build; only the guest may"
    # And there it is the guest that runs it, over SSH, never this Mac.
    install = (here / package / "app.py").read_text()
    unpacks = install[install.index("def install("):]
    assert "machine.ssh.run(" in unpacks[: unpacks.rindex("ditto -x")]


# --- The script itself, ended by the lab ------------------------------------------------


def test_a_build_that_ignores_the_first_signal_is_killed(tmp_path):
    """The deadline must end the compiler, not only the shell that started it.

    `swift build` left running is reparented, still compiling into the checkout
    and still holding SwiftPM's lock after the lab has given up on it — on the
    operator's own Mac.
    """
    script = Script(timeouts=1, makes_zip=False)
    script.ignores_sigterm = True
    lab = builder(script, tmp_path, seconds=60)
    with pytest.raises(LabError, match="did not finish"):
        lab.build("0.4.1", "6")
    assert script.signals == [signal.SIGTERM, signal.SIGKILL]
    # The clock moves only when something waits on it: this is the grace period
    # actually being waited out before the kill.
    assert lab._clock() >= config.BUILD_STOP_GRACE_SECONDS


# --- A build that carries a published release's key ---------------------------------------


def test_a_build_carrying_a_releases_public_key_says_so_to_make_app_and_keeps_every_other_rule(tmp_path):
    """The private half lives in GitHub's secrets: the public half is what lets a lab build accept the release."""
    from udeck_e2e.builds import PublicKey

    script = Script()
    release_key = PublicKey("pxUvxCxwUBF6ftsanVsAhrjGKlvWP5Qfdzf+c1BpMCw=")
    build = builder(script, tmp_path, key=release_key).build("0.4.1", "1")
    options = dict(zip(script.calls[0][0][1:], script.calls[0][0][2:]))
    assert options["--test-key"] == release_key.public_key
    assert options["--test-feed"] == FEED, "its feed is still the lab's own in its plist"
    assert options["--test-plugins"] == plugin_repository.base_url()
    assert build.zip.is_file()
    # Never where a build carrying the run's own key stands.
    assert Path(options["--out"]).parent != tmp_path / "run" / "builds" / digest()


def test_a_build_carrying_a_releases_key_is_held_to_the_same_rules(tmp_path):
    from udeck_e2e.builds import PublicKey

    with pytest.raises(LabError, match="UDeckPluginsAPIBase is 'https://api.github.com'"):
        builder(Script(ignores_test_plugins=True), tmp_path, key=PublicKey("cmVsZWFzZQ==")).build("0.4.1", "1")
    with pytest.raises(LabError, match="without NSAllowsLocalNetworking"):
        builder(Script(local_networking=False), tmp_path, key=PublicKey("cmVsZWFzZQ==")).build("0.4.1", "1")


# --- Binaries compiled elsewhere (`--prebuilt`) ---------------------------------------


def test_a_build_from_prebuilt_binaries_says_where_they_are_and_keeps_every_other_rule(tmp_path):
    script = Script()
    lab_builder = builder(script, tmp_path)
    lab_builder.prebuilt = tmp_path / "prebuilt"
    build = lab_builder.build("0.4.1", "6")
    options = dict(zip(script.calls[0][0][1:], script.calls[0][0][2:]))
    assert options["--prebuilt"] == str(tmp_path / "prebuilt")
    assert options["--test-feed"] == FEED and "--zip" in script.calls[0][0]
    assert build.zip.is_file()
    # And without it, nothing is said about prebuilt binaries at all.
    plain = Script()
    builder(plain, tmp_path).build("0.4.1", "7")
    assert "--prebuilt" not in plain.calls[0][0]


def test_prebuilt_binaries_are_taken_only_from_this_checkouts_commit(tmp_path):
    from udeck_e2e.builds import prebuilt_problem

    directory = tmp_path / "prebuilt"
    directory.mkdir()
    head = lambda root: "a" * 40  # noqa: E731
    clean = lambda root: []  # noqa: E731
    assert "has no uDeck, udeck-plugin" in prebuilt_problem(directory, tmp_path, head=head, changed=clean)
    for name in ("uDeck", "udeck-plugin"):
        (directory / name).write_bytes(b"binary")
    assert "does not say which commit" in prebuilt_problem(directory, tmp_path, head=head, changed=clean)
    (directory / "commit").write_text("b" * 40 + "\n")
    assert prebuilt_problem(directory, tmp_path, head=head, changed=clean) == f"--prebuilt {directory} was compiled from bbbbbbbbbbbb, and this checkout is aaaaaaaaaaaa"
    (directory / "commit").write_text("a" * 40 + "\n")
    assert prebuilt_problem(directory, tmp_path, head=head, changed=clean) is None
    assert "could not read this checkout's commit" in prebuilt_problem(directory, tmp_path, head=lambda root: None, changed=clean)


def test_prebuilt_binaries_are_refused_under_a_working_copy_that_changed_what_they_are_compiled_from(tmp_path):
    """The commit is the same, the code is not: a Mac's edited checkout must not
    check the commit's binaries as its own (on a runner only prebuilt/ itself
    is new, and it is not compiled from)."""
    from udeck_e2e.builds import prebuilt_problem

    directory = tmp_path / "prebuilt"
    directory.mkdir()
    for name in ("uDeck", "udeck-plugin"):
        (directory / name).write_bytes(b"binary")
    (directory / "commit").write_text("a" * 40 + "\n")
    head = lambda root: "a" * 40  # noqa: E731
    edited = ["Sources/uDeck/App.swift", "Package.resolved", "Sources/uDeck/Panel.swift", "Packages/X/Y.swift"]
    assert prebuilt_problem(directory, tmp_path, head=head, changed=lambda root: edited) == (
        f"--prebuilt {directory} was compiled from aaaaaaaaaaaa, and this working copy has changed "
        "Sources/uDeck/App.swift, Package.resolved, Sources/uDeck/Panel.swift and 1 more since"
    )
    assert "could not read whether this checkout's sources changed" in prebuilt_problem(
        directory, tmp_path, head=head, changed=lambda root: None
    )


def test_what_changed_is_read_out_of_git_for_the_compiled_paths_only(tmp_path):
    """A real repository: an edit in Sources is seen, one in e2e/ and an untracked prebuilt/ are not."""
    from udeck_e2e import builds

    def git(*args):
        subprocess.run(["git", "-C", str(tmp_path), *args], check=True, capture_output=True)

    git("init", "-q")
    (tmp_path / "Sources").mkdir()
    (tmp_path / "Sources" / "a.swift").write_text("let a = 1\n")
    (tmp_path / "e2e").mkdir()
    (tmp_path / "e2e" / "x.py").write_text("x = 1\n")
    git("add", "-A")
    git("-c", "user.name=lab", "-c", "user.email=lab@example.invalid", "-c", "commit.gpgsign=false", "commit", "-q", "-m", "one")
    (tmp_path / "e2e" / "x.py").write_text("x = 2\n")
    (tmp_path / "prebuilt").mkdir()
    (tmp_path / "prebuilt" / "uDeck").write_bytes(b"binary")
    assert builds._changed(tmp_path) == []
    (tmp_path / "Sources" / "a.swift").write_text("let a = 2\n")
    (tmp_path / "Sources" / "b.swift").write_text("let b = 1\n")
    assert builds._changed(tmp_path) == ["Sources/a.swift", "Sources/b.swift"]
    assert builds._changed(tmp_path / "not-a-repository") is None
