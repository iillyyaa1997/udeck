"""The update that is offered: signing, the appcast, the feed in the guest, installing."""

import subprocess
from pathlib import Path

import pytest

from udeck_e2e import config, updates
from udeck_e2e.builds import Build, make_key
from udeck_e2e.errors import LabError

SIGNATURE = "B5jqMnVKb2UEvjAejhXyD2W7k5ibBYjgLmuxEA0FcFmfW1FmLFtGlBfbWJhsFdEZSXFzrxTWlZfJtZLGDwmLDA=="


def done(args, rc=0, out="", err=""):
    return subprocess.CompletedProcess(args, rc, out, err)


def a_build(tmp_path, version="0.4.2", number="7", size=4105315):
    zip_path = tmp_path / f"uDeck-{version}.zip"
    zip_path.write_bytes(b"x" * size)
    return Build(version, number, zip_path)


# --- Signing -------------------------------------------------------------------------


def test_signing_asks_sparkles_own_tool_with_this_runs_key(tmp_path):
    seen = []
    key = make_key(tmp_path / "signing")
    signature = updates.sign(
        a_build(tmp_path, size=10).zip, key, Path("/repo/.build/…/sign_update"),
        run=lambda args, **kwargs: seen.append((args, kwargs)) or done(args, out=SIGNATURE + "\n"),
    )  # fmt: skip
    args, kwargs = seen[0]
    assert args[0].endswith("sign_update")
    assert args[args.index("--ed-key-file") + 1] == str(key.private_key_file)
    assert "-p" in args and kwargs["timeout"] == config.SIGN_SECONDS
    assert kwargs["stdin"] is subprocess.DEVNULL and kwargs["start_new_session"] is True
    assert signature == SIGNATURE


def test_a_signing_that_fails_or_says_nothing_is_a_lab_error(tmp_path):
    key = make_key(tmp_path / "signing")
    build = a_build(tmp_path, size=10)
    with pytest.raises(LabError, match="sign_update exited 1"):
        updates.sign(build.zip, key, Path("/sign_update"), run=lambda args, **k: done(args, 1, err="ERROR! key too short"))
    with pytest.raises(LabError, match="exited 0"):
        updates.sign(build.zip, key, Path("/sign_update"), run=lambda args, **k: done(args, 0, out="  \n"))
    with pytest.raises(LabError, match="did not finish"):
        def hangs(args, **kwargs):
            raise subprocess.TimeoutExpired(args, kwargs["timeout"])

        updates.sign(build.zip, key, Path("/sign_update"), run=hangs)


def test_sparkles_tool_is_taken_from_the_checkout_and_says_so_when_it_is_not_there(tmp_path):
    with pytest.raises(LabError, match="swift build"):
        updates.find_sign_update(tmp_path)
    tool = tmp_path / updates.SIGN_UPDATE
    tool.parent.mkdir(parents=True)
    tool.write_text("#!/bin/sh\n")
    assert updates.find_sign_update(tmp_path) == tool


# --- The appcast ----------------------------------------------------------------------


def test_the_appcast_offers_the_build_number_sparkle_compares(tmp_path):
    build = a_build(tmp_path)
    feed = updates.appcast(updates.Offer(build, SIGNATURE, build.zip.stat().st_size), "http://127.0.0.1:8765")
    assert "<sparkle:version>7</sparkle:version>" in feed
    assert "<sparkle:shortVersionString>0.4.2</sparkle:shortVersionString>" in feed
    assert 'url="http://127.0.0.1:8765/uDeck-0.4.2.zip"' in feed
    assert f'length="{build.zip.stat().st_size}"' in feed
    assert f'sparkle:edSignature="{SIGNATURE}"' in feed
    # It is XML a person may have to read, and Sparkle certainly will.
    from xml.etree import ElementTree

    root = ElementTree.fromstring(feed)
    (enclosure,) = root.iter("enclosure")
    assert enclosure.attrib["type"] == "application/octet-stream"


def test_a_signature_with_xml_in_it_cannot_break_the_feed(tmp_path):
    feed = updates.appcast(updates.Offer(a_build(tmp_path), 'a"b&c<d', 10), "http://127.0.0.1:8765/")
    from xml.etree import ElementTree

    (enclosure,) = ElementTree.fromstring(feed).iter("enclosure")
    sparkle = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
    assert enclosure.attrib[f"{sparkle}edSignature"] == 'a"b&c<d'


# --- The feed, and installing, inside the guest ------------------------------------------


class Clock:
    def __init__(self):
        self.now = 0.0

    def __call__(self):
        return self.now

    def sleep(self, seconds):
        self.now += seconds


class Dropped:
    """A connection that failed, as each of the two calls sees it.

    `run(check=False)` gets an exit code and no output; `ask` turns that into a
    lab failure. A fake that raised from both would let a check read a pid with
    the wrong one and never be caught.
    """


class FakeGuest:
    """The SSH side of a machine: answers commands, remembers what was copied in."""

    def __init__(self, answers=None):
        self.commands = []
        self.copied = []
        self.answers = answers or {}
        self.serving_after = 0

    def _answer(self, command):
        """The scripted answer, or None. A list answers once per call, the last one repeating."""
        for pattern, answer in self.answers.items():
            if pattern in command:
                if isinstance(answer, list):
                    return answer.pop(0) if len(answer) > 1 else answer[0]
                return answer
        return None

    def run(self, command, step, seconds=None, check=True):
        self.commands.append(command)
        answer = self._answer(command)
        if answer is Dropped:
            if check:
                raise LabError(step, "SSH to 192.168.64.2 failed")
            return done([], 255, "")
        if isinstance(answer, BaseException):
            raise answer
        return done([], 0, answer or "")

    def ask(self, command, step, seconds=None):
        self.commands.append(command)
        if "curl" in command:
            self.serving_after -= 1
            return done([], 0, "200" if self.serving_after < 0 else "000")
        answer = self._answer(command)
        if answer is Dropped:
            raise LabError(step, "SSH to 192.168.64.2 failed")
        if isinstance(answer, BaseException):
            raise answer
        if answer is None:
            return done([], 1, "")
        return done([], 0 if answer else 1, answer)

    def copy_in(self, local, remote, step, seconds=None):
        self.copied.append((Path(local).name, remote))


class FakeMachine:
    def __init__(self, answers=None):
        self.name = "udeck-e2e-probe"
        self.ssh = FakeGuest(answers)
        self._clock = Clock()

    def clock(self):
        return self._clock()

    def sleep(self, seconds):
        self._clock.sleep(seconds)


def test_the_feed_is_served_from_inside_the_guest_on_its_own_loopback(tmp_path):
    machine = FakeMachine()
    machine.ssh.serving_after = 2  # it takes a moment to come up
    feed = updates.Feed(machine, note=lambda text: None)
    appcast_file = tmp_path / "appcast.xml"
    appcast_file.write_text("<rss/>")
    archive = a_build(tmp_path, size=10).zip
    feed.serve(appcast_file, archive)

    assert feed.url == f"http://127.0.0.1:{config.FEED_PORT}/appcast.xml"
    assert machine.ssh.copied == [
        ("appcast.xml", f"{updates.GUEST_FEED_DIR}/appcast.xml"),
        (archive.name, f"{updates.GUEST_FEED_DIR}/{archive.name}"),
    ]
    served = [c for c in machine.ssh.commands if "http.server" in c]
    assert served and f"http.server {config.FEED_PORT}" in served[0]
    # Not every address the guest has: its own network is reachable from this Mac.
    assert "--bind 127.0.0.1" in served[0]
    assert "127.0.0.1" in [c for c in machine.ssh.commands if "curl" in c][0]

    feed.stop()
    assert any("kill $(cat" in c for c in machine.ssh.commands)


def test_a_feed_that_never_answers_is_a_lab_error_with_what_the_server_said(tmp_path):
    machine = FakeMachine({"server.log": "Address already in use"})
    machine.ssh.serving_after = 10_000
    appcast_file = tmp_path / "appcast.xml"
    appcast_file.write_text("<rss/>")
    with pytest.raises(LabError, match="Address already in use"):
        updates.Feed(machine, note=lambda text: None).serve(appcast_file)
    assert machine._clock.now >= config.FEED_UP_SECONDS


def test_installing_puts_the_build_in_applications_owned_by_the_person_using_the_guest(tmp_path):
    machine = FakeMachine({"stat -f %Su": config.GUEST_USER})
    archive = a_build(tmp_path, version="0.4.1", size=10).zip
    updates.install(machine, archive, note=lambda text: None)
    assert machine.ssh.copied == [(archive.name, f"/tmp/{archive.name}")]
    unpack = [c for c in machine.ssh.commands if "ditto -x -k" in c]
    assert unpack and updates.GUEST_APPLICATIONS in unpack[0]
    # The copy already there goes first: ditto would otherwise merge into it and
    # leave files of the old version inside the new bundle.
    assert f"rm -rf {updates.GUEST_APPLICATIONS}/{updates.APP}" in unpack[0]
    assert any("xattr -p com.apple.quarantine" in c for c in machine.ssh.commands)


def test_a_build_that_landed_wrong_in_the_guest_is_a_lab_error(tmp_path):
    archive = a_build(tmp_path, version="0.4.1", size=10).zip
    with pytest.raises(LabError, match="belongs to root"):
        updates.install(FakeMachine({"stat -f %Su": "root"}), archive, note=lambda text: None)

    quarantined = FakeMachine({"stat -f %Su": config.GUEST_USER, "xattr -p com.apple.quarantine": "0083;68c9…"})
    with pytest.raises(LabError, match="quarantine"):
        updates.install(quarantined, archive, note=lambda text: None)


def test_the_version_on_disk_is_read_from_the_bundle_in_the_guest():
    machine = FakeMachine({"defaults read": "0.4.1\n6\n"})
    assert updates.installed_version(machine) == ("0.4.1", "6")
    # One line instead of two: one of the two reads answered with nothing.
    with pytest.raises(LabError, match="unexpected answer"):
        updates.installed_version(FakeMachine({"defaults read": "0.4.1\n"}))


# --- What is running in the guest ------------------------------------------------------


def test_the_pids_uDeck_has_are_read_in_a_way_a_dropped_connection_cannot_answer():
    """`ask`, not `run(check=False)`: SSH failing must not read as "it is not running"."""
    machine = FakeMachine({"pgrep -x uDeck": "101\n202\n"})
    assert updates.running_pids(machine) == {"101", "202"}

    dropped = FakeMachine({"pgrep -x uDeck": Dropped})
    with pytest.raises(LabError, match="SSH to 192.168.64.2 failed"):
        updates.running_pids(dropped)


def test_a_running_uDeck_is_asked_to_quit_before_its_bundle_is_replaced():
    """A copy left by the previous check keeps running from the bundle ditto deletes.

    `open -a` then only brings that one forward, and the check drives an
    application that is not the one it installed.
    """
    machine = FakeMachine({"pgrep -x uDeck": ["909", "909", ""]})
    updates.quit_app(machine, "quitting uDeck")
    asked = [c for c in machine.ssh.commands if "to quit" in c]
    assert asked and "System Events" in asked[0], "a bare quit resolves the bundle that is going"
    assert not any("pkill" in c for c in machine.ssh.commands), "it went when it was asked"


def test_a_uDeck_that_will_not_quit_is_killed_and_then_given_up_on():
    killed = FakeMachine({"pgrep -x uDeck": ["909"] * 20 + [""]})
    updates.quit_app(killed, "quitting uDeck")
    assert any("pkill -x uDeck" in c for c in killed.ssh.commands)
    assert killed._clock.now >= config.QUIT_SECONDS / 2

    stuck = FakeMachine({"pgrep -x uDeck": "909"})
    with pytest.raises(LabError, match="still running in the guest as"):
        updates.quit_app(stuck, "quitting uDeck")
    assert stuck._clock.now >= config.QUIT_SECONDS


def test_nothing_is_asked_to_quit_when_nothing_is_running():
    machine = FakeMachine()
    updates.quit_app(machine, "quitting uDeck")
    assert not any("quit" in c or "pkill" in c for c in machine.ssh.commands)


def test_installing_ends_what_is_running_before_it_replaces_the_bundle(tmp_path):
    machine = FakeMachine({"pgrep -x uDeck": ["909", ""], "stat -f %Su": config.GUEST_USER})
    updates.install(machine, a_build(tmp_path, version="0.4.1", size=10).zip, note=lambda text: None)
    quit_at = next(i for i, c in enumerate(machine.ssh.commands) if "to quit" in c)
    ditto_at = next(i for i, c in enumerate(machine.ssh.commands) if "ditto -x -k" in c)
    assert quit_at < ditto_at


# --- The feed's own log, as evidence ---------------------------------------------------


def test_the_feeds_log_is_brought_back_as_evidence(tmp_path):
    """For the negative control it is the proof: a fetched archive is a checked signature."""
    line = '127.0.0.1 - - [18/Sep/2026] "GET /uDeck-0.4.2.zip HTTP/1.1" 200 -'
    machine = FakeMachine({"server.log": line})
    text = updates.Feed(machine, note=lambda t: None).collect_log(tmp_path)
    assert line in text
    assert line in (tmp_path / "feed-server.log").read_text()


def test_a_log_that_cannot_be_collected_is_said_and_not_raised(tmp_path):
    """Evidence, not a verdict: a check must not turn on whether its artefacts arrived."""
    machine = FakeMachine({"server.log": Dropped})
    said = []
    assert updates.Feed(machine, note=said.append).collect_log(tmp_path) == ""
    assert any("could not be read" in note for note in said)

    unwritable = FakeMachine({"server.log": "a line"})
    said = []
    assert updates.Feed(machine=unwritable, note=said.append).collect_log(tmp_path / "nowhere") == "a line"
    assert any("could not be written" in note for note in said)
