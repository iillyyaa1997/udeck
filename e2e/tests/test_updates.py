"""The update that is offered: signing, the appcast, the feed in the guest, installing."""

import subprocess
from pathlib import Path

import pytest
from fakes import Dropped, Failed, Machine as FakeMachine

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


def test_the_feed_is_served_from_inside_the_guest_on_its_own_loopback(tmp_path):
    # It takes a moment to come up: the guest answers 000 twice, then 200.
    machine = FakeMachine({"curl": ["000", "000", "200"]})
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
    machine = FakeMachine({"curl": "000", "server.log": "Address already in use"})
    appcast_file = tmp_path / "appcast.xml"
    appcast_file.write_text("<rss/>")
    with pytest.raises(LabError, match="Address already in use"):
        updates.Feed(machine, note=lambda text: None).serve(appcast_file)
    assert machine.now >= config.FEED_UP_SECONDS


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


# --- Who asked the feed ---------------------------------------------------------------

UDECK_ASKED = '127.0.0.1 - - [26/Sep/2026 20:45:31] "GET /appcast.xml HTTP/1.1" 200 -'
LAB_ASKED = f'127.0.0.1 - - [26/Sep/2026 20:40:18] "GET /appcast.xml?{updates.LAB_PROBE} HTTP/1.1" 200 -'


def test_the_lab_marks_its_own_requests_for_the_appcast(tmp_path):
    """Two checks turn on "did uDeck ask its feed"; the lab asking must never be read as uDeck asking."""
    machine = FakeMachine({"curl": "200"})
    feed = updates.Feed(machine, note=lambda text: None)
    appcast_file = tmp_path / updates.APPCAST
    appcast_file.write_text("<rss/>")
    feed.serve(appcast_file)
    assert feed.answers_now("asking")
    asked = [c for c in machine.ssh.commands if "curl" in c]
    assert len(asked) == 2 and all(feed.probe_url in c for c in asked)
    assert feed.probe_url == f"{feed.url}?{updates.LAB_PROBE}"
    # The address every lab build carries is still the plain one: only the lab's own asking is marked.
    assert feed.url == f"http://127.0.0.1:{config.FEED_PORT}/{updates.APPCAST}"


def test_what_the_lab_asked_for_is_not_what_uDeck_asked_for():
    log = "\n".join([
        "Serving HTTP on 127.0.0.1 port 8765 (http://127.0.0.1:8765/) ...",
        LAB_ASKED,
        UDECK_ASKED,
        '127.0.0.1 - - [26/Sep/2026 20:45:40] "GET /uDeck-0.4.2.zip HTTP/1.1" 200 -',
        f'127.0.0.1 - - [26/Sep/2026 20:45:50] "GET /appcast.xml?x=1&{updates.LAB_PROBE} HTTP/1.1" 200 -',
    ])
    assert updates.asked_for_the_appcast(log) == [UDECK_ASKED]


def test_uDeck_asking_with_parameters_of_its_own_is_still_uDeck_asking():
    """Sparkle may add a query to the feed's address; what is asked is who asked, not how."""
    with_query = '127.0.0.1 - - [26/Sep/2026 20:45:31] "GET /appcast.xml?appVersion=6 HTTP/1.0" 404 -'
    assert updates.asked_for_the_appcast(with_query) == [with_query]


def test_a_log_that_is_the_oracle_is_never_read_as_empty_when_it_could_not_be_read(tmp_path):
    """"Nobody asked" out of a log nobody could read would be a verdict made of a dropped connection."""
    with pytest.raises(LabError, match="SSH"):
        updates.Feed(FakeMachine({"server.log": Dropped}), note=lambda t: None).read_log("reading")
    with pytest.raises(LabError, match="No such file"):
        updates.Feed(
            FakeMachine({"server.log": Failed(1, "cat: server.log: No such file or directory")}), note=lambda t: None
        ).read_log("reading")
    assert updates.Feed(FakeMachine({"server.log": UDECK_ASKED}), note=lambda t: None).read_log("reading") == UDECK_ASKED


def test_an_empty_appcast_is_a_feed_that_offers_nothing():
    from xml.etree import ElementTree

    root = ElementTree.fromstring(updates.empty_appcast())
    assert root.tag == "rss" and root.find("channel") is not None
    assert list(root.iter("item")) == []
