"""The update checks themselves: what they prove, and what they must never pass on.

The checks in `checks/` are the only code in the lab whose mistakes are invisible
— a check that proves nothing looks exactly like a check that passed. So they are
driven here against a machine made of answers: every SSH command, every click and
every screenshot is scripted, including the ones that fail.

Two questions are asked of every test below. Would this check still be green if
uDeck did nothing at all? And when something goes wrong, does the run say "uDeck
is broken" (CheckFailed) or "the lab could not tell" (LabError) — because saying
the first about the second is how a lab loses the right to be believed.
"""

import importlib.util
import re
import sys
from pathlib import Path

import pytest
from fakes import Dropped, Failed, Lab, Machine

from udeck_e2e import app, pairs, ui, updates
from udeck_e2e.errors import CheckFailed, LabError, NotThere


def _load():
    """The check file, loaded the way the lab loads it: by path, not as a package."""
    path = Path(__file__).resolve().parents[1] / "checks" / "check_updates.py"
    spec = importlib.util.spec_from_file_location("check_updates_under_test", path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


checks = _load()

# The pair every update check but the one by a published release runs with by
# default, resolved as the lab resolves it: two builds of this checkout, nothing fetched.
BETWEEN_CHECKOUTS = pairs.resolve(pairs.THE_WHOLE_UPDATE, pairs.BETWEEN_CHECKOUTS, False, None, Path("."))


@pytest.fixture
def machine():
    # The feed answering is the state every check starts from — `serve` proves it
    # before anything else happens — so it is the fake's default, and the test
    # about a feed that died says so for itself.
    return Machine({"http_code": "200"})


@pytest.fixture
def lab(tmp_path):
    return Lab(tmp_path)


@pytest.fixture
def check_dir(tmp_path):
    path = tmp_path / "updates.sparkle"
    path.mkdir()
    return path


@pytest.fixture(autouse=True)
def no_real_work(monkeypatch, tmp_path):
    """Nothing here signs, serves or reaches a real machine."""
    monkeypatch.setattr(updates, "sign", lambda *a, **k: "a-signature")
    monkeypatch.setattr(updates, "find_sign_update", lambda root: tmp_path / "sign_update")
    monkeypatch.setattr(updates.Feed, "serve", lambda self, *a: setattr(self, "serving", True))
    monkeypatch.setattr(updates.Feed, "stop", lambda self: setattr(self, "serving", False))
    monkeypatch.setattr(updates.Feed, "collect_log", lambda self, directory, name="feed-server.log": self.log)
    monkeypatch.setattr(updates.Feed, "log", "", raising=False)


def prepared(monkeypatch, version="0.4.2", number="7", zip_name="uDeck-0.4.2.zip"):
    """Skip the preparation: its own tests are further down."""
    offer = checks.Offered(version, number, zip_name, None, "http://127.0.0.1:8765/appcast.xml")
    monkeypatch.setattr(checks, "_prepare", lambda machine, check_dir, lab, feed, pair, signed_by=None: offer)
    monkeypatch.setattr(checks, "_open_the_about_pane", lambda machine, check_dir, shot=None: None)
    return offer


def at(machine, identifier):
    return ui.Element(identifier, 100, 200, 40, 20)


def finds(monkeypatch, **answers):
    """What `ui.wait_for` says for each identifier: an Element, or something raised."""

    def wait_for(machine, identifier, step, window=ui.SETTINGS_WINDOW, seconds=None):
        answer = answers.get(identifier, at(machine, identifier))
        if isinstance(answer, BaseException):
            raise answer
        return answer

    monkeypatch.setattr(ui, "wait_for", wait_for)
    monkeypatch.setattr(ui, "click", lambda machine, identifier, step, window=ui.SETTINGS_WINDOW: at(machine, identifier))


def says(monkeypatch, *sentences):
    monkeypatch.setattr(ui, "static_texts", lambda machine, step, window=ui.SETTINGS_WINDOW: list(sentences))


def says_nothing_readable(monkeypatch, error=None):
    def refuse(machine, step, window=ui.SETTINGS_WINDOW):
        raise error or LabError(step, "System Events refused: … (-1728)")

    monkeypatch.setattr(ui, "static_texts", refuse)


def feed_log(text):
    return lambda self, directory, name="feed-server.log": text


# --- The negative control: it has to prove uDeck tried ---------------------------------


def test_a_click_the_lab_could_not_make_is_not_a_passed_control(machine, lab, check_dir, monkeypatch):
    """The control used to swallow every lab failure as "uDeck did not even offer it".

    System Events refusing once, a pointer that did not land, a click that timed
    out: nothing installed afterwards either, so the check read the old version
    off the disk and passed — having pressed nothing and checked no signature.
    """
    prepared(monkeypatch)
    finds(monkeypatch)
    says(monkeypatch, "Installed 0.4.1")
    monkeypatch.setattr(app, "installed_version", lambda m: checks.FIRST)
    machine.click_fails = LabError("pressing Install", "the VNC click did not finish in 30s")

    with pytest.raises(LabError, match="the VNC click did not finish"):
        checks.check_wrong_key(machine, check_dir, lab, BETWEEN_CHECKOUTS)
    assert "   uDeck did not even offer it" not in lab.notes


def test_system_events_refusing_is_not_uDeck_declining_to_offer(machine, lab, check_dir, monkeypatch):
    """Only the deadline says something about uDeck; a refusal says something about the lab.

    Both used to arrive as one LabError, and the control caught both — so a guest
    whose System Events refused once was written down as "uDeck did not even
    offer it" and the check passed, having watched nothing at all.
    """
    prepared(monkeypatch)
    finds(monkeypatch, **{"updates.install": LabError("waiting", "System Events refused: … (-1728)")})
    says(monkeypatch, "Installed 0.4.1")
    monkeypatch.setattr(app, "installed_version", lambda m: checks.FIRST)

    with pytest.raises(LabError, match="System Events refused"):
        checks.check_wrong_key(machine, check_dir, lab, BETWEEN_CHECKOUTS)
    assert "   uDeck did not even offer it" not in lab.notes


def test_an_update_that_was_never_offered_does_not_pass_as_a_refusal(machine, lab, check_dir, monkeypatch):
    """An update uDeck was never offered is one whose signature was never reached.

    The appcast is served unsigned and Sparkle checks the key when it downloads, so
    the offer not appearing is about the feed, the window or the click — never about
    the key this control is named after. It is the lab failing to ask the question."""
    prepared(monkeypatch)
    finds(monkeypatch, **{"updates.install": NotThere("waiting", "'updates.install' did not appear")})
    says(monkeypatch, "Installed 0.4.1", "Latest 0.4.1")
    monkeypatch.setattr(app, "installed_version", lambda m: checks.FIRST)
    monkeypatch.setattr(updates.Feed, "collect_log", feed_log('"GET /appcast.xml HTTP/1.1" 200 -'))

    with pytest.raises(LabError, match="never offered the update") as raised:
        checks.check_wrong_key(machine, check_dir, lab, BETWEEN_CHECKOUTS)
    assert not isinstance(raised.value, CheckFailed)


def test_the_control_passes_when_the_guest_saw_uDeck_fetch_the_archive(machine, lab, check_dir, monkeypatch):
    """Downloaded and not installed: Sparkle checks the signature after downloading."""
    offer = prepared(monkeypatch)
    finds(monkeypatch)
    says(monkeypatch, "Installed 0.4.1", "Latest 0.4.2")
    monkeypatch.setattr(app, "installed_version", lambda m: checks.FIRST)
    monkeypatch.setattr(updates.Feed, "collect_log", feed_log(f'"GET /{offer.archive} HTTP/1.1" 200 -'))

    checks.check_wrong_key(machine, check_dir, lab, BETWEEN_CHECKOUTS)
    assert machine.clicks and machine.clicks[-1][2].startswith("pressing Install")
    assert machine.now >= checks.REFUSAL_SECONDS


def test_uDeck_saying_its_check_did_not_finish_is_not_a_refusal(machine, lab, check_dir, monkeypatch):
    """uDeck prints that sentence for any trouble its updater runs into, including
    never having got as far as the archive. It used to be accepted as proof that the
    signature had been reached, which let this control pass having downloaded nothing
    — a control that proves nothing. The words stay in the report and decide nothing."""
    prepared(monkeypatch)
    finds(monkeypatch)
    says(monkeypatch, "Installed 0.4.1", "The check did not finish: The update is improperly signed")
    monkeypatch.setattr(app, "installed_version", lambda m: checks.FIRST)
    monkeypatch.setattr(updates.Feed, "collect_log", feed_log(""))

    with pytest.raises(LabError, match="never answered for"):
        checks.check_wrong_key(machine, check_dir, lab, BETWEEN_CHECKOUTS)


def test_a_window_that_cannot_be_read_does_not_hide_an_update_that_installed(machine, lab, check_dir, monkeypatch):
    """The worst case the control exists for: uDeck installed it, and the pane went away.

    Reading the pane is evidence, so it may not decide the outcome. If it could,
    the one run that finds uDeck trusting a key it must not trust would be filed
    as "could not check" and nobody would look.
    """
    prepared(monkeypatch)
    finds(monkeypatch)
    says_nothing_readable(monkeypatch)
    monkeypatch.setattr(app, "installed_version", lambda m: checks.SECOND)

    with pytest.raises(CheckFailed, match="which was signed with a key it does not trust"):
        checks.check_wrong_key(machine, check_dir, lab, BETWEEN_CHECKOUTS)


def test_a_screenshot_that_fails_does_not_hide_an_update_that_installed(machine, lab, check_dir, monkeypatch):
    prepared(monkeypatch)
    finds(monkeypatch)
    says(monkeypatch, "Installed 0.4.2")
    monkeypatch.setattr(app, "installed_version", lambda m: checks.SECOND)
    machine.screenshot_fails = LabError("taking a screenshot", "the machine is gone")
    machine.screenshot_fails_at = "after the refusal"

    with pytest.raises(CheckFailed, match="signed with a key it does not trust"):
        checks.check_wrong_key(machine, check_dir, lab, BETWEEN_CHECKOUTS)
    assert any("no screenshot 'after the refusal'" in note for note in lab.notes)


def test_an_install_still_in_flight_is_not_nothing_installed(machine, lab, check_dir, monkeypatch):
    """The wait is a fixed window; a running installer means it was simply too short."""
    offer = prepared(monkeypatch)
    finds(monkeypatch)
    says(monkeypatch, "Installed 0.4.1")
    monkeypatch.setattr(app, "installed_version", lambda m: checks.FIRST)
    monkeypatch.setattr(updates.Feed, "collect_log", feed_log(f'"GET /{offer.archive} HTTP/1.1" 200 -'))
    machine.ssh.answers["pgrep -fl"] = "941 /Applications/uDeck.app/Contents/Frameworks/Autoupdate"

    with pytest.raises(LabError, match="still installing"):
        checks.check_wrong_key(machine, check_dir, lab, BETWEEN_CHECKOUTS)


def test_a_uDeck_that_died_on_the_press_is_not_a_refusal(machine, lab, check_dir, monkeypatch):
    """"The version on disk did not change" is also true of an application that fell
    over when Install was pressed. Refusing is something uDeck does while carrying on
    being itself."""
    offer = prepared(monkeypatch)
    finds(monkeypatch)
    says(monkeypatch, "Installed 0.4.1")
    monkeypatch.setattr(app, "installed_version", lambda m: checks.FIRST)
    monkeypatch.setattr(updates.Feed, "collect_log", feed_log(f'"GET /{offer.archive} HTTP/1.1" 200 -'))
    machine.ssh.answers["pgrep -x uDeck"] = ["404", ""]

    with pytest.raises(CheckFailed, match="did not refuse the update and carry on"):
        checks.check_wrong_key(machine, check_dir, lab, BETWEEN_CHECKOUTS)


def test_a_uDeck_that_came_back_as_another_process_is_not_a_refusal(machine, lab, check_dir, monkeypatch):
    """A new pid after the press is an application that was replaced and relaunched,
    which is what installing looks like from outside — and the version on disk is read
    once, at one moment."""
    offer = prepared(monkeypatch)
    finds(monkeypatch)
    says(monkeypatch, "Installed 0.4.1")
    monkeypatch.setattr(app, "installed_version", lambda m: checks.FIRST)
    monkeypatch.setattr(updates.Feed, "collect_log", feed_log(f'"GET /{offer.archive} HTTP/1.1" 200 -'))
    machine.ssh.answers["pgrep -x uDeck"] = ["404", "909"]

    with pytest.raises(CheckFailed, match="did not refuse the update and carry on"):
        checks.check_wrong_key(machine, check_dir, lab, BETWEEN_CHECKOUTS)


def test_an_archive_the_server_refused_is_not_an_archive_it_served(machine, lab, check_dir, monkeypatch):
    """The witness is the guest's server *answering* for the archive. A request it
    turned away means Sparkle never had the bytes whose signature this is about."""
    offer = prepared(monkeypatch)
    finds(monkeypatch)
    says(monkeypatch, "Installed 0.4.1")
    monkeypatch.setattr(app, "installed_version", lambda m: checks.FIRST)
    monkeypatch.setattr(updates.Feed, "collect_log", feed_log(f'"GET /{offer.archive} HTTP/1.1" 404 -'))

    with pytest.raises(LabError, match="never answered for"):
        checks.check_wrong_key(machine, check_dir, lab, BETWEEN_CHECKOUTS)


def test_the_archive_is_recognised_whatever_protocol_the_server_logs(machine, lab, check_dir, monkeypatch):
    """The protocol version sits inside the quoted request and is not part of the
    question. Pinning it would make the witness a fact about `http.server`."""
    offer = prepared(monkeypatch)
    finds(monkeypatch)
    says(monkeypatch, "Installed 0.4.1")
    monkeypatch.setattr(app, "installed_version", lambda m: checks.FIRST)
    monkeypatch.setattr(updates.Feed, "collect_log", feed_log(f'"GET /{offer.archive} HTTP/1.0" 200 -'))

    checks.check_wrong_key(machine, check_dir, lab, BETWEEN_CHECKOUTS)


def test_the_running_installer_is_looked_for_in_a_way_that_cannot_match_the_question(machine, lab, check_dir, monkeypatch):
    """`pgrep -f` reads the arguments of the shell running this very command."""
    offer = prepared(monkeypatch)
    finds(monkeypatch)
    says(monkeypatch, "Installed 0.4.1")
    monkeypatch.setattr(app, "installed_version", lambda m: checks.FIRST)
    monkeypatch.setattr(updates.Feed, "collect_log", feed_log(f'"GET /{offer.archive} HTTP/1.1" 200 -'))

    checks.check_wrong_key(machine, check_dir, lab, BETWEEN_CHECKOUTS)
    asked = [c for c in machine.ssh.commands if "pgrep -fl" in c]
    assert asked and "Autoupdate" not in asked[0] and "[A]utoupdate" in asked[0]


# --- The update itself -----------------------------------------------------------------


def test_a_slow_relaunch_is_not_a_failed_update(machine, lab, check_dir, monkeypatch):
    """Sparkle swaps the bundle and relaunches; the pid read at once catches the gap."""
    prepared(monkeypatch)
    finds(monkeypatch)
    says(monkeypatch, "Installed 0.4.1", "Version 0.4.2 is available.")
    monkeypatch.setattr(app, "installed_version", lambda m: checks.SECOND)
    machine.ssh.answers["pgrep -x uDeck"] = ["101", "", "", "202"]

    checks.check_sparkle(machine, check_dir, lab, BETWEEN_CHECKOUTS)
    assert "after the update" in machine.shots


def test_an_updated_uDeck_that_crashes_on_launch_is_not_one_that_came_back(machine, lab, check_dir, monkeypatch):
    """One look after the relaunch catches the moment the new process is alive. An
    update that installed a uDeck which falls over straight away shows a new pid for
    exactly that long, and a check that stopped looking there would call it working."""
    prepared(monkeypatch)
    finds(monkeypatch)
    says(monkeypatch, "Installed 0.4.1", "Version 0.4.2 is available.")
    monkeypatch.setattr(app, "installed_version", lambda m: checks.SECOND)
    machine.ssh.answers["pgrep -x uDeck"] = ["101", "202", ""]

    with pytest.raises(CheckFailed, match="was gone"):
        checks.check_sparkle(machine, check_dir, lab, BETWEEN_CHECKOUTS)


def test_an_old_uDeck_still_running_beside_the_new_one_is_not_an_update(machine, lab, check_dir, monkeypatch):
    """Sparkle replaces the copy that is running. One still there beside the new is an
    update that did not replace anything, whatever the version on disk says."""
    prepared(monkeypatch)
    finds(monkeypatch)
    says(monkeypatch, "Installed 0.4.1", "Version 0.4.2 is available.")
    monkeypatch.setattr(app, "installed_version", lambda m: checks.SECOND)
    machine.ssh.answers["pgrep -x uDeck"] = ["101", "101 202"]

    with pytest.raises(CheckFailed, match="did not replace the copy that was running"):
        checks.check_sparkle(machine, check_dir, lab, BETWEEN_CHECKOUTS)


def test_the_uDeck_that_came_back_is_watched_for_the_whole_settle(machine, lab, check_dir, monkeypatch):
    """Watched, not read once at the end: the sentence has to be able to say when it
    went, and a crash in the middle of the window must not be missed by a read after."""
    prepared(monkeypatch)
    finds(monkeypatch)
    says(monkeypatch, "Installed 0.4.1", "Version 0.4.2 is available.")
    monkeypatch.setattr(app, "installed_version", lambda m: checks.SECOND)
    # Up, gone for one look, back again: a crash and a relaunch by something else.
    machine.ssh.answers["pgrep -x uDeck"] = ["101", "202", "202", "", "202"]

    with pytest.raises(CheckFailed, match="was gone"):
        checks.check_sparkle(machine, check_dir, lab, BETWEEN_CHECKOUTS)


def test_a_dropped_connection_never_reads_as_uDeck_is_not_running(machine, lab, check_dir, monkeypatch):
    """"uDeck did not come back" is a verdict; SSH failing is not evidence for it."""
    prepared(monkeypatch)
    finds(monkeypatch)
    says(monkeypatch, "Version 0.4.2 is available.")
    monkeypatch.setattr(app, "installed_version", lambda m: checks.SECOND)
    machine.ssh.answers["pgrep -x uDeck"] = ["101", Dropped]

    with pytest.raises(LabError, match="SSH to 192.168.64.2 failed"):
        checks.check_sparkle(machine, check_dir, lab, BETWEEN_CHECKOUTS)


def test_a_screenshot_that_fails_does_not_hide_an_update_that_did_not_happen(machine, lab, check_dir, monkeypatch):
    prepared(monkeypatch)
    finds(monkeypatch)
    says(monkeypatch, "Version 0.4.2 is available.")
    monkeypatch.setattr(app, "installed_version", lambda m: checks.FIRST)
    machine.ssh.answers["pgrep -x uDeck"] = ["101", "202"]
    machine.screenshot_fails = LabError("taking a screenshot", "the machine is gone")
    machine.screenshot_fails_at = "after the update"

    with pytest.raises(CheckFailed, match=r"the version on disk is \('0.4.1', '6'\)"):
        checks.check_sparkle(machine, check_dir, lab, BETWEEN_CHECKOUTS)


def test_uDeck_saying_it_is_up_to_date_is_a_failure(machine, lab, check_dir, monkeypatch):
    """The feed was proved to answer and declares a newer build: this is uDeck's answer."""
    prepared(monkeypatch)
    finds(monkeypatch, **{"updates.install": NotThere("waiting", "'updates.install' did not appear")})
    says(monkeypatch, "Installed 0.4.1", "uDeck is up to date.")
    monkeypatch.setattr(app, "installed_version", lambda m: checks.FIRST)

    with pytest.raises(CheckFailed, match="did not offer 0.4.2"):
        checks.check_sparkle(machine, check_dir, lab, BETWEEN_CHECKOUTS)


def test_a_feed_that_died_is_not_uDeck_failing_to_find_an_update(machine, lab, check_dir, monkeypatch):
    """The guest's server is a process the lab left running in a machine it is also
    driving. One that has since died gives uDeck nothing whatever to find, so
    "uDeck did not offer the update" would be the lab's failure wearing uDeck's
    name — and the pane, quite correctly, says the check did not finish."""
    prepared(monkeypatch)
    finds(monkeypatch, **{"updates.install": NotThere("waiting", "'updates.install' did not appear")})
    says(monkeypatch, "Installed 0.4.1", "The check did not finish")
    machine.ssh.answers["http_code"] = "000"

    with pytest.raises(LabError, match="stopped answering") as raised:
        checks.check_sparkle(machine, check_dir, lab, BETWEEN_CHECKOUTS)
    assert not isinstance(raised.value, CheckFailed)


def test_uDeck_still_looking_is_a_lab_problem_and_not_a_failure(machine, lab, check_dir, monkeypatch):
    """Nothing finished: the press may not have landed, and that is the lab's own."""
    prepared(monkeypatch)
    finds(monkeypatch, **{"updates.install": NotThere("waiting", "'updates.install' did not appear")})
    says(monkeypatch, "Installed 0.4.1", "Checking…")
    monkeypatch.setattr(app, "installed_version", lambda m: checks.FIRST)

    with pytest.raises(NotThere):
        checks.check_sparkle(machine, check_dir, lab, BETWEEN_CHECKOUTS)


# --- Preparing the machine --------------------------------------------------------------


def test_the_check_ends_the_uDeck_a_previous_check_left_running(machine, lab, check_dir, monkeypatch):
    """--vm per-group and per-run hand over a machine with uDeck installed and running.

    `ditto` would replace the bundle underneath it: the copy keeps running from
    the old one, `open -a` only brings it forward, and the control is then offered
    nothing by an application that has already updated itself.
    """
    monkeypatch.setattr(checks.ui, "open_settings_and_wait", lambda *a, **k: None)
    machine.ssh.answers["pgrep -x uDeck"] = ["777", "", "", "808"]
    machine.ssh.answers["stat -f %Su"] = "admin"
    monkeypatch.setattr(app, "installed_version", lambda m: checks.FIRST)

    feed = updates.Feed(machine, lab.note)
    checks._prepare(machine, check_dir, lab, feed, BETWEEN_CHECKOUTS)

    quit_asked = [i for i, c in enumerate(machine.ssh.commands) if "to quit" in c]
    unpacked = [i for i, c in enumerate(machine.ssh.commands) if "ditto -x -k" in c]
    assert quit_asked and unpacked and quit_asked[0] < unpacked[0]


def test_two_copies_of_uDeck_running_is_a_lab_problem(machine, lab, check_dir, monkeypatch):
    machine.ssh.answers["pgrep -x uDeck"] = ["", "", "101\n202"]
    machine.ssh.answers["stat -f %Su"] = "admin"
    monkeypatch.setattr(app, "installed_version", lambda m: checks.FIRST)

    feed = updates.Feed(machine, lab.note)
    with pytest.raises(LabError, match="2 copies of uDeck are running"):
        checks._prepare(machine, check_dir, lab, feed, BETWEEN_CHECKOUTS)


def test_the_lab_installing_the_wrong_version_is_not_a_verdict_about_uDeck(machine, lab, check_dir, monkeypatch):
    """The lab put it there a second earlier: if it is wrong, the lab is wrong."""
    machine.ssh.answers["stat -f %Su"] = "admin"
    monkeypatch.setattr(app, "installed_version", lambda m: checks.SECOND)

    feed = updates.Feed(machine, lab.note)
    with pytest.raises(LabError, match="the lab installed"):
        checks._prepare(machine, check_dir, lab, feed, BETWEEN_CHECKOUTS)


def test_each_check_builds_into_a_directory_of_its_own(machine, lab, check_dir, monkeypatch):
    """Both checks build the same two versions; the second must not overwrite the first."""
    machine.ssh.answers["pgrep -x uDeck"] = ["", "", "101"]
    machine.ssh.answers["stat -f %Su"] = "admin"
    monkeypatch.setattr(app, "installed_version", lambda m: checks.FIRST)

    feed = updates.Feed(machine, lab.note)
    checks._prepare(machine, check_dir, lab, feed, BETWEEN_CHECKOUTS)
    assert lab.builders == [(feed.url, check_dir.name)]


def test_a_machine_that_never_starts_uDeck_is_a_lab_problem(machine, lab, check_dir, monkeypatch):
    machine.ssh.answers["pgrep -x uDeck"] = ""
    machine.ssh.answers["stat -f %Su"] = "admin"
    monkeypatch.setattr(app, "installed_version", lambda m: checks.FIRST)

    feed = updates.Feed(machine, lab.note)
    with pytest.raises(LabError, match="uDeck was not running within"):
        checks._prepare(machine, check_dir, lab, feed, BETWEEN_CHECKOUTS)
    assert machine.now >= 30


def test_waiting_for_the_relaunch_spends_the_installs_budget_and_not_a_second_one(machine, lab, check_dir, monkeypatch):
    """Sparkle's whole job has one deadline; the relaunch is inside it, never on top.

    The swap takes most of the budget here, exactly as a slow machine would, so
    a relaunch given a fresh deadline of its own would run the check to twice
    what it documents.
    """
    prepared(monkeypatch)
    finds(monkeypatch)
    says(monkeypatch, "Version 0.4.2 is available.")
    reads = []

    def slowly(machine_):
        reads.append(None)
        return checks.SECOND if len(reads) > 20 else checks.FIRST

    monkeypatch.setattr(app, "installed_version", slowly)
    machine.ssh.answers["pgrep -x uDeck"] = "101"  # it never comes back as a new process

    with pytest.raises(CheckFailed, match="did not come back as a new process"):
        checks.check_sparkle(machine, check_dir, lab, BETWEEN_CHECKOUTS)
    assert machine.now >= 100, "the swap has to eat into the budget for this to mean anything"
    assert machine.now <= checks.INSTALL_SECONDS + 5


def test_a_blip_while_uDeck_starts_is_not_uDeck_failing_to_start(machine, lab, check_dir, monkeypatch):
    """Every wait in the lab tolerates one refusal and keeps to its deadline."""
    machine.ssh.answers["pgrep -x uDeck"] = ["", Dropped, "", "303"]
    machine.ssh.answers["stat -f %Su"] = "admin"
    monkeypatch.setattr(app, "installed_version", lambda m: checks.FIRST)

    feed = updates.Feed(machine, lab.note)
    checks._prepare(machine, check_dir, lab, feed, BETWEEN_CHECKOUTS)
    assert "uDeck running" in machine.shots


# --- Looking by itself ------------------------------------------------------------------

UDECK_ASKED = '127.0.0.1 - - [26/Sep/2026 20:45:31] "GET /appcast.xml HTTP/1.1" 200 -'
LAB_ASKED = f'127.0.0.1 - - [26/Sep/2026 20:40:18] "GET /appcast.xml?{updates.LAB_PROBE} HTTP/1.1" 200 -'
SWITCH = ui.Element(checks.AUTOMATIC, 955, 385, 215, 16, role="AXCheckBox", value=checks.SWITCH_OFF)
CHECK_NOW = ui.Element("updates.checkNow", 1027, 450, 88, 20)


def about_tree(value=checks.SWITCH_OFF, identifier=checks.AUTOMATIC):
    """The About pane as the walk prints it — the switch as measured on 2026-09-26, and a button."""
    return "\n".join([
        "0|AXWindow|AXStandardWindow||uDeck Settings|||790;198;|980;648;",
        f"7|AXCheckBox||{identifier}||{value}||955;385;|215;16;",
        "7|AXButton||updates.checkNow||||1027;450;|88;20;",
    ])


class Scene:
    """What the feed has heard, moved on by what the lab does in the window.

    uDeck asks its feed when the switch is clicked or "Check now" is — unless the
    test says it does not — and the lab's own probe is in the log from the start,
    the way `serve` leaves it. The switch reads on once a click has landed on it,
    and Sparkle keeps automatic checks on once a switch that turns them on has been
    clicked: `switch_turns_it_on=False` is a switch that asks for one check instead.
    """

    def __init__(self, monkeypatch, machine, asks_when_switched=True, asks_when_asked=True,
                 asks_by_itself_after=None, value=checks.SWITCH_OFF, identifier=checks.AUTOMATIC,
                 click_lands=True, asks_when_the_window_opens=False, switch_turns_it_on=True):
        self.machine = machine
        self.log = [LAB_ASKED]
        self.switched = []
        self.clicked = []
        self.walks = 0
        self.value = value
        self.identifier = identifier
        self.click_lands = click_lands
        self.asks_when_switched = asks_when_switched
        self.asks_when_asked = asks_when_asked
        self.asks_by_itself_after = asks_by_itself_after
        self.asks_when_the_window_opens = asks_when_the_window_opens
        self.switch_turns_it_on = switch_turns_it_on
        self.kept = None
        self.launched_at = None
        self.window_opened_at = None
        self.check_now_at = None
        self.read_at = []
        # Reads and clicks in the order they happened: at one instant of the fake clock
        # a read can come either side of a click, and only the order tells which.
        self.events = []
        monkeypatch.setattr(checks, "_a_uDeck_that_never_looked", lambda *a, **k: None)
        monkeypatch.setattr(checks, "_open_the_about_pane", self.open_the_about_pane)
        monkeypatch.setattr(app, "launch", self.launch)
        monkeypatch.setattr(app, "automatic_checks", lambda machine, step: self.kept)
        monkeypatch.setattr(ui, "tree", self.tree)
        monkeypatch.setattr(ui, "click", self.click)
        monkeypatch.setattr(ui, "static_texts", lambda machine, step, window=ui.SETTINGS_WINDOW: ["uDeck is up to date."])
        monkeypatch.setattr(updates.Feed, "read_log", self.read_log)
        pointer = machine.click

        def click_at(x, y, step):
            pointer(x, y, step)
            if (x, y) == SWITCH.middle:
                self.switched.append(step)
                if self.click_lands:
                    self.value = "1"
                    if self.switch_turns_it_on:
                        self.kept = checks.KEPT_ON
                if self.asks_when_switched and self.click_lands:
                    self.log.append(UDECK_ASKED)
            if (x, y) == CHECK_NOW.middle:
                self.check_now_at = self.machine.now
                self.events.append(("click", self.machine.now))
                self.clicked.append(CHECK_NOW.identifier)
                if self.asks_when_asked:
                    self.log.append(UDECK_ASKED)

        machine.click = click_at

    def launch(self, machine, step="starting uDeck"):
        self.launched_at = machine.now
        return {"101"}

    def open_the_about_pane(self, machine, check_dir, shot=None):
        """The settings window on the About pane, found with its button — as the check's own helper returns it."""
        self.window_opened_at = machine.now
        if self.asks_when_the_window_opens:
            self.log.append(UDECK_ASKED)
        return CHECK_NOW

    def tree(self, machine, step, window=ui.SETTINGS_WINDOW):
        self.walks += 1
        return about_tree(self.value, self.identifier)

    def click(self, machine, identifier, step, window=ui.SETTINGS_WINDOW):
        self.clicked.append(identifier)
        if identifier == "updates.checkNow" and self.asks_when_asked:
            self.log.append(UDECK_ASKED)
        return ui.Element(identifier, 1027, 450, 88, 20)

    def read_log(self, step):
        self.read_at.append(self.machine.now)
        self.events.append(("read", self.machine.now))
        if (self.asks_by_itself_after is not None and self.launched_at is not None
                and self.machine.now - self.launched_at >= self.asks_by_itself_after
                and UDECK_ASKED not in self.log):
            self.log.append(UDECK_ASKED)
        return "\n".join(self.log)


# The shipped behaviour: it looks by itself, with nothing pressed.


def test_a_uDeck_that_asks_by_itself_straight_after_it_starts_passes(machine, lab, check_dir, monkeypatch):
    scene = Scene(monkeypatch, machine, asks_by_itself_after=2)
    checks.check_it_looks_by_itself(machine, check_dir, lab)
    assert scene.clicked == [] and scene.switched == [], "nothing is pressed: the request is uDeck's own"
    assert scene.window_opened_at is None, "nor is the window opened, which a request could be blamed on"
    assert machine.now - scene.launched_at < checks.LOOKS_SECONDS, "the listening stops when the request comes"
    assert any("asked its feed by itself" in note for note in lab.notes)


def test_a_uDeck_that_ships_with_automatic_checks_off_fails(machine, lab, check_dir, monkeypatch):
    """What `SUEnableAutomaticChecks` false in the plist does: nothing, for as long as anybody listens."""
    scene = Scene(monkeypatch, machine)
    with pytest.raises(CheckFailed, match="feed heard nothing from it") as raised:
        checks.check_it_looks_by_itself(machine, check_dir, lab)
    assert "did not look by itself" in str(raised.value)
    assert machine.now - scene.launched_at >= checks.LOOKS_SECONDS, "silence is judged only after the whole wait"
    assert scene.clicked == [] and scene.window_opened_at is None, "and never broken by pressing Check now"


def test_a_uDeck_that_looks_only_later_than_the_wait_fails(machine, lab, check_dir, monkeypatch):
    """The promise is a look straight after launch; one a minute later is not told from none."""
    Scene(monkeypatch, machine, asks_by_itself_after=checks.LOOKS_SECONDS + 5)
    with pytest.raises(CheckFailed, match="feed heard nothing from it"):
        checks.check_it_looks_by_itself(machine, check_dir, lab)


def test_the_lab_asking_its_own_feed_is_not_uDeck_looking(machine, lab, check_dir, monkeypatch):
    """`serve` asks for the appcast to learn the server is up, and that line is in the log from the start."""
    scene = Scene(monkeypatch, machine)
    scene.log = [LAB_ASKED, LAB_ASKED]
    with pytest.raises(CheckFailed, match="feed heard nothing from it"):
        checks.check_it_looks_by_itself(machine, check_dir, lab)


def test_a_feed_that_died_is_not_a_uDeck_that_did_not_look(machine, lab, check_dir, monkeypatch):
    """A feed that is gone hears nobody, and "uDeck did not look" would be about the lab."""
    Scene(monkeypatch, machine)
    machine.ssh.answers["http_code"] = "000"
    with pytest.raises(LabError, match="stopped answering") as raised:
        checks.check_it_looks_by_itself(machine, check_dir, lab)
    assert not isinstance(raised.value, CheckFailed)
    assert any(updates.LAB_PROBE in c for c in machine.ssh.commands)


def test_a_feed_log_that_cannot_be_read_is_not_silence(machine, lab, check_dir, monkeypatch):
    """Once is enough: a read that failed while listening is a stretch nobody heard, and a
    listener that shrugged it off would call the rest of the wait "nothing heard"."""
    scene = Scene(monkeypatch, machine, asks_by_itself_after=2)
    reads = []

    def once_unreadable(step):
        reads.append(step)
        if len(reads) == 1:
            raise LabError(step, "the guest's server log could not be read: exit 1")
        return scene.read_log(step)

    monkeypatch.setattr(updates.Feed, "read_log", lambda feed, step: once_unreadable(step))
    with pytest.raises(LabError, match="could not be read") as raised:
        checks.check_it_looks_by_itself(machine, check_dir, lab)
    assert not isinstance(raised.value, CheckFailed)


def test_it_starts_uDeck_on_a_machine_that_remembers_nothing(machine, lab, check_dir, monkeypatch):
    """With automatic checks left off by a neighbour, this would be a check of that switch."""
    scene = Scene(monkeypatch, machine, asks_by_itself_after=2)
    prepared = []
    monkeypatch.setattr(checks, "_a_uDeck_that_never_looked", lambda *a, **k: prepared.append(k))
    checks.check_it_looks_by_itself(machine, check_dir, lab)
    assert prepared == [{}], "never switched off: what it ships, and nothing the lab wrote"
    assert scene.launched_at is not None


# The switch.


def test_switched_on_and_heard_passes_without_check_now(machine, lab, check_dir, monkeypatch):
    scene = Scene(monkeypatch, machine)
    checks.check_switched_on_it_looks_by_itself(machine, check_dir, lab)
    assert len(scene.switched) == 1 and scene.switched[0].startswith("turning automatic checks on")
    assert "updates.checkNow" not in scene.clicked, "a request Check now caused would be indistinguishable"
    # Heard, so the switch is not walked again: the walk would only have delayed nothing.
    assert scene.walks == 1
    assert any("after automatic checks were turned on" in note for note in lab.notes)
    assert any(f"{app.AUTOMATIC_CHECKS} = {checks.KEPT_ON}" in note for note in lab.notes)
    assert (check_dir / "about-before-the-switch.txt").read_text() == about_tree()


def test_a_switch_that_makes_one_check_instead_of_turning_checking_on_fails(machine, lab, check_dir, monkeypatch):
    """A setter that calls `checkNow` — or Sparkle's `checkForUpdatesInBackground` — brings the
    same request as one that turns checking on, and leaves uDeck as quiet as it ships from then on."""
    scene = Scene(monkeypatch, machine, switch_turns_it_on=False)
    with pytest.raises(CheckFailed, match="made one check instead of turning checking on") as raised:
        checks.check_switched_on_it_looks_by_itself(machine, check_dir, lab)
    assert "nothing at all" in str(raised.value)
    assert scene.value == "1", "the switch reads on, which is what the operator sees"
    assert "updates.checkNow" not in scene.clicked


def test_sparkles_setting_is_read_until_it_says_on_and_no_longer(machine, lab, check_dir, monkeypatch):
    """Room for the preferences daemon, and nothing more: a value that arrives is taken at once."""
    Scene(monkeypatch, machine)
    answers = [None, None, checks.KEPT_ON]
    monkeypatch.setattr(app, "automatic_checks", lambda m, step: answers.pop(0) if len(answers) > 1 else answers[0])
    began = machine.now
    checks.check_switched_on_it_looks_by_itself(machine, check_dir, lab)
    assert answers == [checks.KEPT_ON]
    assert machine.now - began < checks.SWITCHED_ON_SECONDS + checks.KEPT_SECONDS


def test_a_switch_sparkle_keeps_off_fails(machine, lab, check_dir, monkeypatch):
    scene = Scene(monkeypatch, machine, switch_turns_it_on=False)
    scene.kept = "0"
    with pytest.raises(CheckFailed, match=f"keeps {app.AUTOMATIC_CHECKS} as 0"):
        checks.check_switched_on_it_looks_by_itself(machine, check_dir, lab)


def test_a_feed_that_died_is_not_a_switch_that_reached_nothing(machine, lab, check_dir, monkeypatch):
    """The same question the update asks before it says uDeck found nothing: a feed that is
    gone hears nobody, and "the switch did not reach the updater" would be about the lab."""
    scene = Scene(monkeypatch, machine, asks_when_switched=False)
    machine.ssh.answers["http_code"] = "000"
    with pytest.raises(LabError, match="stopped answering") as raised:
        checks.check_switched_on_it_looks_by_itself(machine, check_dir, lab)
    assert not isinstance(raised.value, CheckFailed)
    assert scene.value == "1", "the switch moved, so only the feed stands between this and a verdict"
    assert any(updates.LAB_PROBE in c for c in machine.ssh.commands)


def test_a_switch_that_reaches_nothing_fails_after_the_measured_wait(machine, lab, check_dir, monkeypatch):
    """The toggle moves and Sparkle is never told: the operator believes it is on."""
    scene = Scene(monkeypatch, machine, asks_when_switched=False)
    with pytest.raises(CheckFailed, match="the switch did not reach the updater"):
        checks.check_switched_on_it_looks_by_itself(machine, check_dir, lab)
    assert machine.now >= checks.SWITCHED_ON_SECONDS
    assert scene.value == "1", "the switch moved: the silence is uDeck's"


def test_a_click_that_missed_the_switch_is_not_uDeck_ignoring_it(machine, lab, check_dir, monkeypatch):
    """A switch still reading off after the click is a pointer that did not land, and uDeck
    was asked nothing: "the switch did not reach the updater" would be about the lab."""
    Scene(monkeypatch, machine, click_lands=False)
    with pytest.raises(LabError, match="the click did not land on it") as raised:
        checks.check_switched_on_it_looks_by_itself(machine, check_dir, lab)
    assert not isinstance(raised.value, CheckFailed)


def test_a_request_before_the_switch_is_uDeck_ignoring_the_switch_off(machine, lab, check_dir, monkeypatch):
    """Sparkle keeps automatic checks off on this machine, so a request before the switch is
    touched is uDeck doing what the operator switched off — and nothing after it could be asked."""
    scene = Scene(monkeypatch, machine)
    scene.log = [LAB_ASKED, UDECK_ASKED]
    with pytest.raises(CheckFailed, match="with automatic checks switched off"):
        checks.check_switched_on_it_looks_by_itself(machine, check_dir, lab)
    assert scene.switched == []


def test_a_switch_reading_on_where_sparkle_keeps_it_off_fails_and_is_not_pressed(machine, lab, check_dir, monkeypatch):
    """The lab wrote off and read it back: a pane showing on is not showing what uDeck does, and
    pressed, it would turn automatic checks off and ask the opposite question."""
    scene = Scene(monkeypatch, machine, value="1")
    with pytest.raises(CheckFailed, match="does not show what uDeck does"):
        checks.check_switched_on_it_looks_by_itself(machine, check_dir, lab)
    assert scene.switched == []


def test_the_switch_check_starts_from_a_machine_whose_operator_switched_it_off(machine, lab, check_dir, monkeypatch):
    Scene(monkeypatch, machine)
    prepared = []
    monkeypatch.setattr(checks, "_a_uDeck_that_never_looked", lambda *a, **k: prepared.append(k))
    checks.check_switched_on_it_looks_by_itself(machine, check_dir, lab)
    assert prepared == [{"switched_off": True}]


def test_a_pane_without_the_switch_is_the_lab_unable_to_find_it(machine, lab, check_dir, monkeypatch):
    scene = Scene(monkeypatch, machine, identifier="updates.somethingElse")
    with pytest.raises(LabError, match=f"0 controls on the About pane carry '{checks.AUTOMATIC}'"):
        checks.check_switched_on_it_looks_by_itself(machine, check_dir, lab)
    assert scene.switched == []


def test_the_switch_is_the_one_uDecks_about_pane_names():
    """The identifier is uDeck's, and it is held against the view that sets it."""
    view = (Path(__file__).resolve().parents[2] / "Sources" / "UDeckKit" / "Views" / "SettingsView.swift").read_text()
    about = view[view.index("private struct AboutSection"):]
    toggle = about[about.index("Toggle(strings(.updatesAutomatically)"):]
    assert toggle.index(f'.accessibilityIdentifier("{checks.AUTOMATIC}")') < toggle.index("Text(")


def test_the_sections_the_lab_clicks_carry_their_tag_on_the_outside():
    """`_open_the_about_pane` clicks `section.about`, and only a row whose tag is its outermost
    trait is one the List can select. Measured on 2026-09-28: with `.badge` after `.tag`, four
    clicks on four sections left the General pane up, and every check that opens About said
    "could not check" about a window that could not be navigated at all.

    This reads the order of two words in SettingsView.swift, and that is all it proves: it is
    a tripwire for the one edit that broke it, not evidence that a section can be chosen. The
    behaviour is proved in the lab, by the checks that click a section and then need what is
    on it — `updates.sparkle`, `updates.wrong-key` and `updates.switched-on-it-looks-by-itself`
    (`_open_the_about_pane` waits for `updates.checkNow`, which only About has), and every
    `plugins.*` check that opens Settings → Plugins (`ui.plugins_pane`)."""
    view = (Path(__file__).resolve().parents[2] / "Sources" / "UDeckKit" / "Views" / "SettingsView.swift").read_text()
    row = view[view.index("List(Section.allCases, selection: $section)"):]
    row = row[:row.index(".accessibilityIdentifier(\"section.")]
    assert ".badge(" in row and row.rindex(".tag(item)") > row.rindex(".badge(")


# Preparing a machine that never looked.


def test_a_machine_that_remembers_a_check_forgets_it_before_uDeck_starts(machine, lab, check_dir, monkeypatch):
    """With --vm per-group the update check before this one pressed "Check now", and Sparkle
    would wait a day from that before looking by itself — so the switch would cause nothing."""
    machine.ssh.answers["stat -f %Su"] = "admin"
    machine.ssh.answers[f"defaults read {app.BUNDLE_ID}"] = [
        '{ SULastCheckTime = "2026-09-26 20:45:31 +0000"; }',
        Failed(1, "Domain place.unicorns.udeck does not exist"),
    ]
    monkeypatch.setattr(app, "installed_version", lambda m: checks.FIRST)
    served = []
    monkeypatch.setattr(updates.Feed, "serve", lambda self, *files: served.extend(files))

    checks._a_uDeck_that_never_looked(machine, check_dir, lab, updates.Feed(machine, lab.note))

    deleted = [i for i, c in enumerate(machine.ssh.commands) if f"defaults delete {app.BUNDLE_ID}" in c]
    unpacked = [i for i, c in enumerate(machine.ssh.commands) if "ditto -x -k" in c]
    assert deleted and unpacked and unpacked[0] < deleted[0]
    assert any("SULastCheckTime" in note for note in lab.notes)
    assert [path.name for path in served] == [updates.APPCAST]
    assert (check_dir / updates.APPCAST).read_text() == updates.empty_appcast()


def test_a_machine_whose_operator_switched_automatic_checks_off_is_written_after_the_forgetting(
        machine, lab, check_dir, monkeypatch):
    """The one preference the lab writes, written after the delete that would take it away,
    and read back before uDeck starts."""
    machine.ssh.answers["stat -f %Su"] = "admin"
    machine.ssh.answers[f"defaults read {app.BUNDLE_ID} {app.AUTOMATIC_CHECKS}"] = "0\n"
    machine.ssh.answers[f"defaults read {app.BUNDLE_ID}"] = [
        '{ SULastCheckTime = "2026-09-26 20:45:31 +0000"; }',
        Failed(1, "Domain place.unicorns.udeck does not exist"),
    ]
    monkeypatch.setattr(app, "installed_version", lambda m: checks.FIRST)

    checks._a_uDeck_that_never_looked(machine, check_dir, lab, updates.Feed(machine, lab.note), switched_off=True)

    commands = machine.ssh.commands
    deleted = [i for i, c in enumerate(commands) if f"defaults delete {app.BUNDLE_ID}" in c]
    written = [i for i, c in enumerate(commands)
               if f"defaults write {app.BUNDLE_ID} {app.AUTOMATIC_CHECKS} -bool false" in c]
    read_back = [i for i, c in enumerate(commands) if f"defaults read {app.BUNDLE_ID} {app.AUTOMATIC_CHECKS}" in c]
    assert deleted and written and read_back and deleted[0] < written[0] < read_back[-1]
    assert any("switched off" in note for note in lab.notes)


def test_a_machine_that_remembers_nothing_is_not_touched(machine, lab, check_dir, monkeypatch):
    machine.ssh.answers["stat -f %Su"] = "admin"
    machine.ssh.answers[f"defaults read {app.BUNDLE_ID}"] = Failed(1, "Domain place.unicorns.udeck does not exist")
    monkeypatch.setattr(app, "installed_version", lambda m: checks.FIRST)

    checks._a_uDeck_that_never_looked(machine, check_dir, lab, updates.Feed(machine, lab.note))
    assert not any("defaults delete" in c for c in machine.ssh.commands)
    assert not any("defaults write" in c for c in machine.ssh.commands), "what uDeck ships, and nothing the lab wrote"


# --- Pairs with a published release ------------------------------------------------------------

from udeck_e2e import config, releases  # noqa: E402


def a_release(tmp_path, version, build, feed=config.LATEST_FEED):
    published = releases.Published(
        f"v{version}", f"https://github.com/iillyyaa1997/udeck/releases/download/v{version}/appcast.xml",
        f"uDeck-{version}.zip", f"https://github.com/iillyyaa1997/udeck/releases/download/v{version}/uDeck-{version}.zip", 9,
    )  # fmt: skip
    archive = tmp_path / "releases" / f"v{version}" / f"uDeck-{version}.zip"
    archive.parent.mkdir(parents=True, exist_ok=True)
    archive.write_bytes(b"released!")
    return releases.Release(
        published=published, version=version, build=build, public_key=f"key-of-{version}=", shipped_feed=feed,
        zip=archive, appcast=archive.with_name("appcast.xml"), enclosure_url=published.zip_url, length=9,
        signature="c2ln", sha256="00",
    )  # fmt: skip


def a_pair(rule, from_end, to_end, asked):
    return pairs.Resolved(asked, True, from_end, to_end)


def release_to_latest(tmp_path):
    return pairs.Resolved(
        pairs.THE_RELEASE_BEFORE_LATEST_TO_LATEST, False, a_release(tmp_path, "0.5.0", "6"), a_release(tmp_path, "0.6.1", "8")
    )


def release_to_a_release_by_name(tmp_path):
    return a_pair(None, a_release(tmp_path, "0.5.0", "6"), a_release(tmp_path, "0.6.1", "8"),
                  pairs.Pair(pairs.Side("0.5.0"), pairs.Side("0.6.1")))  # fmt: skip


def checkout_to_latest(tmp_path):
    latest = a_release(tmp_path, "0.6.1", "8")
    return a_pair(None, pairs.Checkout("0.4.1", "1", key_of=latest), latest,
                  pairs.Pair(pairs.Side("checkout"), pairs.Side("latest")))  # fmt: skip


def release_to_checkout(tmp_path):
    return a_pair(None, a_release(tmp_path, "0.5.0", "6"), pairs.Checkout("0.4.2", "7"),
                  pairs.Pair(pairs.Side("0.5.0"), pairs.Side("checkout")))  # fmt: skip


class GitHubFromTheGuest:
    """`updates.github_answers` as the guest would answer it, and every time it was asked."""

    def __init__(self, monkeypatch, answers=((True, "the guest reaches GitHub"),)):
        self.answers = list(answers)
        self.asked = []
        monkeypatch.setattr(updates, "github_answers", self)

    def __call__(self, machine, release, feed_url, step):
        self.asked.append((release.version, feed_url, step))
        answer = self.answers.pop(0) if len(self.answers) > 1 else self.answers[0]
        if isinstance(answer, BaseException):
            raise answer
        return answer


def a_guest_for_prepare(machine, monkeypatch, there):
    machine.ssh.answers["stat -f %Su"] = "admin"
    machine.ssh.answers["pgrep -x uDeck"] = ["", "", "101"]
    monkeypatch.setattr(app, "installed_version", lambda m: there)


def feed_written(machine):
    return [c for c in machine.ssh.commands if f"defaults write {app.BUNDLE_ID} {app.FEED_URL}" in c]


def test_a_release_offered_latest_asks_the_feed_it_ships_with_untouched(machine, lab, check_dir, monkeypatch, tmp_path):
    pair = release_to_latest(tmp_path)
    a_guest_for_prepare(machine, monkeypatch, ("0.5.0", "6"))
    github = GitHubFromTheGuest(monkeypatch)
    feed = updates.Feed(machine, lab.note)
    offered = checks._prepare(machine, check_dir, lab, feed, pair)

    assert offered == checks.Offered("0.6.1", "8", "uDeck-0.6.1.zip", pair.to, config.LATEST_FEED)
    assert machine.ssh.copied == [("uDeck-0.5.0.zip", "/tmp/uDeck-0.5.0.zip")], "the release's own zip, unpacked in the guest"
    assert feed_written(machine) == [], "the real feed, untouched"
    assert lab.builders == [], "nothing of this checkout is built"
    assert not feed.serving, "the lab serves nothing: it comes from GitHub"
    assert github.asked == [("0.6.1", config.LATEST_FEED, "asking GitHub from inside the guest")]
    assert "uDeck running" in machine.shots
    assert any("the guest reaches GitHub" in note for note in lab.notes)


def test_a_release_named_by_its_version_is_reached_through_its_own_appcast(machine, lab, check_dir, monkeypatch, tmp_path):
    pair = release_to_a_release_by_name(tmp_path)
    a_guest_for_prepare(machine, monkeypatch, ("0.5.0", "6"))
    machine.ssh.answers[f"defaults read {app.BUNDLE_ID} {app.FEED_URL}"] = pair.to.own_appcast
    github = GitHubFromTheGuest(monkeypatch)
    checks._prepare(machine, check_dir, lab, updates.Feed(machine, lab.note), pair)

    (written,) = feed_written(machine)
    assert written.endswith(f"-string {pair.to.own_appcast}")
    forgotten = next(i for i, c in enumerate(machine.ssh.commands) if "defaults read place.unicorns.udeck" in c)
    assert forgotten < machine.ssh.commands.index(written), "written after what the machine kept was read"
    assert github.asked[0][1] == pair.to.own_appcast


def test_a_build_of_this_checkout_going_to_latest_carries_the_releases_key_and_is_pointed_at_the_real_feed(
        machine, lab, check_dir, monkeypatch, tmp_path):
    pair = checkout_to_latest(tmp_path)
    a_guest_for_prepare(machine, monkeypatch, ("0.4.1", "1"))
    machine.ssh.answers[f"defaults read {app.BUNDLE_ID} {app.FEED_URL}"] = config.LATEST_FEED
    GitHubFromTheGuest(monkeypatch)
    feed = updates.Feed(machine, lab.note)
    checks._prepare(machine, check_dir, lab, feed, pair)

    assert lab.builders == [(feed.url, check_dir.name, "key-of-0.6.1=")]
    assert machine.ssh.copied == [("uDeck-0.4.1.zip", "/tmp/uDeck-0.4.1.zip")]
    assert feed_written(machine)[0].endswith(f"-string {config.LATEST_FEED}")


def test_a_release_offered_a_build_of_this_checkout_is_pointed_at_the_labs_feed_and_offered_the_runs_key(
        machine, lab, check_dir, monkeypatch, tmp_path):
    pair = release_to_checkout(tmp_path)
    a_guest_for_prepare(machine, monkeypatch, ("0.5.0", "6"))
    feed = updates.Feed(machine, lab.note)
    machine.ssh.answers[f"defaults read {app.BUNDLE_ID} {app.FEED_URL}"] = feed.url
    signed = []
    monkeypatch.setattr(updates, "sign", lambda zip_path, key, tool: signed.append(key) or "a-signature")
    offered = checks._prepare(machine, check_dir, lab, feed, pair)

    assert offered.release is None and offered.keys == ("0.4.2", "7") and offered.asked_at == feed.url
    assert lab.builders == [(feed.url, check_dir.name)], "the offer carries the run's own key"
    assert signed == [lab.signing_key], "signed with the run's key, which no release trusts"
    assert feed.serving
    assert feed_written(machine)[0].endswith(f"-string {feed.url}")


def test_a_feed_written_that_does_not_read_back_is_the_labs(machine, lab, check_dir, monkeypatch, tmp_path):
    pair = release_to_a_release_by_name(tmp_path)
    a_guest_for_prepare(machine, monkeypatch, ("0.5.0", "6"))
    machine.ssh.answers[f"defaults read {app.BUNDLE_ID} {app.FEED_URL}"] = config.LATEST_FEED
    GitHubFromTheGuest(monkeypatch)
    with pytest.raises(LabError, match="reads back as"):
        checks._prepare(machine, check_dir, lab, updates.Feed(machine, lab.note), pair)


def test_a_guest_that_cannot_reach_github_is_could_not_check_before_udeck_is_started(machine, lab, check_dir, monkeypatch, tmp_path):
    pair = release_to_latest(tmp_path)
    a_guest_for_prepare(machine, monkeypatch, ("0.5.0", "6"))
    GitHubFromTheGuest(monkeypatch, [LabError("asking GitHub", "the guest could not reach github.com: curl: (6) Could not resolve host")])
    with pytest.raises(LabError, match="could not reach github.com") as raised:
        checks._prepare(machine, check_dir, lab, updates.Feed(machine, lab.note), pair)
    assert not isinstance(raised.value, CheckFailed)
    assert not any(c.startswith("open -a") for c in machine.ssh.commands)


def test_github_answering_an_error_is_noted_and_left_for_udeck(machine, lab, check_dir, monkeypatch, tmp_path):
    pair = release_to_latest(tmp_path)
    a_guest_for_prepare(machine, monkeypatch, ("0.5.0", "6"))
    GitHubFromTheGuest(monkeypatch, [(False, "the feed answered the guest 404")])
    checks._prepare(machine, check_dir, lab, updates.Feed(machine, lab.note), pair)
    assert any("404" in note and "what it does with that is the verdict" in note for note in lab.notes)


def offered_from_github(monkeypatch, pair):
    offer = checks.Offered(*pair.to.keys, pair.to.zip.name, pair.to, config.LATEST_FEED)
    monkeypatch.setattr(checks, "_prepare", lambda machine, check_dir, lab, feed, pair, signed_by=None: offer)
    opened = []
    monkeypatch.setattr(checks, "_open_the_about_pane", lambda machine, check_dir, shot=None: opened.append(shot))
    return offer, opened


def test_the_published_release_check_passes_on_the_disk_and_a_new_process(machine, lab, check_dir, monkeypatch, tmp_path):
    pair = release_to_latest(tmp_path)
    _, opened = offered_from_github(monkeypatch, pair)
    finds(monkeypatch)
    says(monkeypatch, "Installed 0.5.0", "Version 0.6.1 is available.")
    monkeypatch.setattr(app, "installed_version", lambda m: ("0.6.1", "8"))
    machine.ssh.answers["pgrep -x uDeck"] = ["101", "202"]
    github = GitHubFromTheGuest(monkeypatch)

    checks.check_a_published_release(machine, check_dir, lab, pair)
    assert github.asked == [], "nothing is asked of GitHub again when nothing is judged against uDeck"
    assert machine.shots[:2] == ["the update is offered", "after the update"]
    assert opened == [None, "the installed version"], "a picture of the version installed, after the verdict"
    assert any("the guest's disk holds 0.6.1 (8)" in note and "from GitHub" in note for note in lab.notes)


def test_a_published_release_that_stays_put_is_red_only_while_the_guest_reaches_github(
        machine, lab, check_dir, monkeypatch, tmp_path):
    pair = release_to_latest(tmp_path)
    offered_from_github(monkeypatch, pair)
    finds(monkeypatch)
    says(monkeypatch, "Version 0.6.1 is available.")
    monkeypatch.setattr(app, "installed_version", lambda m: ("0.5.0", "6"))
    machine.ssh.answers["pgrep -x uDeck"] = ["101", "202"]
    github = GitHubFromTheGuest(monkeypatch)
    with pytest.raises(CheckFailed, match=r"the version on disk is \('0.5.0', '6'\), not \('0.6.1', '8'\)") as raised:
        checks.check_a_published_release(machine, check_dir, lab, pair)
    assert [step for _, _, step in github.asked] == ["asking GitHub from inside the guest before judging"]
    assert "the guest reaches GitHub" in str(raised.value), "what GitHub answered the guest, in the red line"
    assert str(raised.value).endswith("the pane says: Version 0.6.1 is available."), "and what the pane said"


def test_the_red_line_says_what_the_pane_said_so_a_bad_signature_and_a_failed_download_read_apart(
        machine, lab, check_dir, monkeypatch, tmp_path):
    """Evidence only: the verdict is the disk, and a pane that cannot be read changes nothing."""
    pair = release_to_latest(tmp_path)
    offered_from_github(monkeypatch, pair)
    finds(monkeypatch)
    pane = ["Installed 0.5.0", "Latest 0.6.1", "The check did not finish: The update is improperly signed and could not be validated."]
    says(monkeypatch, *pane)
    monkeypatch.setattr(app, "installed_version", lambda m: ("0.5.0", "6"))
    machine.ssh.answers["pgrep -x uDeck"] = ["101"]
    GitHubFromTheGuest(monkeypatch)
    with pytest.raises(CheckFailed, match=re.escape("the pane says: " + " | ".join(pane))):
        checks.check_a_published_release(machine, check_dir, lab, pair)

    read = []

    def readable_once(machine, step, window=ui.SETTINGS_WINDOW):
        # The offer is read, and decides; the window then stops answering.
        read.append(step)
        if len(read) > 1:
            raise LabError(step, "System Events refused: … (-1728)")
        return pane

    monkeypatch.setattr(ui, "static_texts", readable_once)
    with pytest.raises(CheckFailed, match=r"the version on disk is .*the settings window could not be read"):
        checks.check_a_published_release(machine, check_dir, lab, pair)


def test_github_in_trouble_at_judging_is_could_not_check_and_never_red(machine, lab, check_dir, monkeypatch, tmp_path):
    """GitHub's own answers, through the real probe: a 503 for the feed or the archive is the network."""
    pair = release_to_latest(tmp_path)
    offered_from_github(monkeypatch, pair)
    finds(monkeypatch)
    says(monkeypatch, "Installed 0.5.0", "Latest 0.6.1",
         "The check did not finish: An error occurred in retrieving update information (503).")  # fmt: skip
    monkeypatch.setattr(app, "installed_version", lambda m: ("0.5.0", "6"))
    machine.ssh.answers["pgrep -x uDeck"] = ["101"]
    # First, so that it answers before the fake's "http_code" does: curl's own format names it too.
    machine.ssh.answers = {"/usr/bin/curl": "busy\nudeck-e2e-curl 503 0 github.com", **machine.ssh.answers}
    with pytest.raises(LabError, match="GitHub answered the guest 503") as raised:
        checks.check_a_published_release(machine, check_dir, lab, pair)
    assert not isinstance(raised.value, CheckFailed)

    finds(monkeypatch, **{"updates.install": NotThere("waiting", "'updates.install' did not appear")})
    with pytest.raises(LabError, match="GitHub answered the guest 503") as raised:
        checks.check_a_published_release(machine, check_dir, lab, pair)
    assert not isinstance(raised.value, CheckFailed)


def test_a_guest_that_lost_github_is_not_a_release_that_did_not_install(machine, lab, check_dir, monkeypatch, tmp_path):
    pair = release_to_latest(tmp_path)
    offered_from_github(monkeypatch, pair)
    finds(monkeypatch)
    says(monkeypatch, "Version 0.6.1 is available.")
    monkeypatch.setattr(app, "installed_version", lambda m: ("0.5.0", "6"))
    machine.ssh.answers["pgrep -x uDeck"] = ["101", "202"]
    GitHubFromTheGuest(monkeypatch, [LabError("asking GitHub", "the guest could not reach github.com: curl: (7)")])
    with pytest.raises(LabError, match="could not reach github.com") as raised:
        checks.check_a_published_release(machine, check_dir, lab, pair)
    assert not isinstance(raised.value, CheckFailed)


def test_a_release_offered_nothing_while_github_answers_is_red_and_while_it_does_not_is_not(
        machine, lab, check_dir, monkeypatch, tmp_path):
    pair = release_to_latest(tmp_path)
    offered_from_github(monkeypatch, pair)
    finds(monkeypatch, **{"updates.install": NotThere("waiting", "'updates.install' did not appear")})
    says(monkeypatch, "Installed 0.5.0", "uDeck is up to date.")
    GitHubFromTheGuest(monkeypatch)
    with pytest.raises(CheckFailed, match="did not offer 0.6.1"):
        checks.check_a_published_release(machine, check_dir, lab, pair)

    GitHubFromTheGuest(monkeypatch, [LabError("asking GitHub", "the guest could not reach github.com")])
    with pytest.raises(LabError, match="could not reach github.com") as raised:
        checks.check_a_published_release(machine, check_dir, lab, pair)
    assert not isinstance(raised.value, CheckFailed)


def test_a_feed_github_says_is_not_there_is_red_and_never_said_to_still_answer(machine, lab, check_dir, monkeypatch, tmp_path):
    """The latest redirect leading nowhere is what every uDeck meets: the release's, and the line says so."""
    pair = release_to_latest(tmp_path)
    offered_from_github(monkeypatch, pair)
    finds(monkeypatch, **{"updates.install": NotThere("waiting", "'updates.install' did not appear")})
    says(monkeypatch, "Installed 0.5.0", "The check did not finish: An error occurred in retrieving update information (404).")
    GitHubFromTheGuest(monkeypatch, [(False, f"{config.LATEST_FEED} answered the guest 404 from github.com after 1 redirect(s)")])
    with pytest.raises(CheckFailed) as raised:
        checks.check_a_published_release(machine, check_dir, lab, pair)
    assert "did not offer 0.6.1, and GitHub answers the guest: " in str(raised.value)
    assert "answered the guest 404" in str(raised.value)
    assert "still answers" not in str(raised.value)


def test_the_offer_from_github_is_waited_for_longer_than_one_from_the_guests_loopback(
        machine, lab, check_dir, monkeypatch, tmp_path):
    waited = []

    def wait_for(machine, identifier, step, window=ui.SETTINGS_WINDOW, seconds=None):
        waited.append((identifier, seconds))
        return at(machine, identifier)

    pair = release_to_latest(tmp_path)
    offered_from_github(monkeypatch, pair)
    finds(monkeypatch)
    monkeypatch.setattr(ui, "wait_for", wait_for)
    says(monkeypatch, "Version 0.6.1 is available.")
    monkeypatch.setattr(app, "installed_version", lambda m: ("0.6.1", "8"))
    machine.ssh.answers["pgrep -x uDeck"] = ["101", "202"]
    checks.check_a_published_release(machine, check_dir, lab, pair)
    assert ("updates.install", checks.OFFER_FROM_GITHUB_SECONDS) in waited


def test_a_window_that_will_not_show_the_installed_version_changes_no_verdict(machine, lab, check_dir, monkeypatch, tmp_path):
    pair = release_to_latest(tmp_path)
    offered_from_github(monkeypatch, pair)

    def refuse(machine, check_dir, shot=None):
        if shot == "the installed version":
            raise LabError("opening uDeck's settings", "System Events refused: (-1728)")

    monkeypatch.setattr(checks, "_open_the_about_pane", refuse)
    finds(monkeypatch)
    says(monkeypatch, "Version 0.6.1 is available.")
    monkeypatch.setattr(app, "installed_version", lambda m: ("0.6.1", "8"))
    machine.ssh.answers["pgrep -x uDeck"] = ["101", "202"]
    checks.check_a_published_release(machine, check_dir, lab, pair)
    assert any("no screenshot of the installed version" in note for note in lab.notes)


def test_the_wrong_key_control_with_a_real_from_holds_the_disk_to_that_release(machine, lab, check_dir, monkeypatch, tmp_path):
    pair = release_to_checkout(tmp_path)
    keys = []
    offer = checks.Offered("0.4.2", "7", "uDeck-0.4.2.zip", None, "http://127.0.0.1:8765/appcast.xml")
    monkeypatch.setattr(checks, "_prepare", lambda machine, check_dir, lab, feed, pair, signed_by=None:
                        keys.append(signed_by) or offer)  # fmt: skip
    monkeypatch.setattr(checks, "_open_the_about_pane", lambda machine, check_dir, shot=None: None)
    finds(monkeypatch)
    says(monkeypatch, "Installed 0.5.0")
    monkeypatch.setattr(updates.Feed, "collect_log", feed_log('"GET /uDeck-0.4.2.zip HTTP/1.1" 200 -'))

    monkeypatch.setattr(app, "installed_version", lambda m: ("0.5.0", "6"))
    checks.check_wrong_key(machine, check_dir, lab, pair)
    assert keys == [None], "None is the run's own key: no release trusts it"
    assert not (check_dir / "another-key").exists()

    monkeypatch.setattr(app, "installed_version", lambda m: ("0.4.2", "7"))
    with pytest.raises(CheckFailed, match=r"uDeck installed \('0.4.2', '7'\), which was signed with a key it does not trust"):
        checks.check_wrong_key(machine, check_dir, lab, pair)


def test_every_update_check_says_which_pairs_it_takes():
    rules = {name: pairs.rule_of(getattr(checks, name)) for name in dir(checks) if name.startswith("check_")}
    assert rules == {
        "check_sparkle": pairs.THE_WHOLE_UPDATE,
        "check_wrong_key": pairs.THE_WRONG_KEY,
        "check_it_looks_by_itself": pairs.ONLY_THIS_CHECKOUT,
        "check_switched_on_it_looks_by_itself": pairs.ONLY_THIS_CHECKOUT,
        "check_a_published_release": pairs.A_PUBLISHED_RELEASE,
    }


# --- What the pairs read out of this checkout -------------------------------------------------
#
# Here and not beside their modules' own tests: this is the one file of those that
# may read the checkout (test_make_app.py, MAY_READ_THE_CHECKOUT), and it starts
# no process.

import plistlib  # noqa: E402


def test_the_feed_and_the_repository_are_the_ones_udeck_ships_with():
    plist = plistlib.loads((Path(__file__).resolve().parents[2] / "Sources" / "uDeck" / "Support" / "Info.plist").read_bytes())
    assert plist["SUFeedURL"] == config.LATEST_FEED
    assert f"github.com/{config.RELEASES_REPOSITORY}/" in plist["SUFeedURL"]


def test_the_identifiers_read_from_a_releases_source_are_the_ones_the_checks_press():
    """`CHECK_NOW_PATH` is held to what checks/check_updates.py clicks and waits for, and to today's source."""
    source = (Path(__file__).resolve().parents[1] / "checks" / "check_updates.py").read_text()
    for identifier in releases.CHECK_NOW_PATH:
        assert f'"{identifier}"' in source, identifier
    view = (Path(__file__).resolve().parents[2] / "Sources" / "UDeckKit" / "Views" / "SettingsView.swift").read_text()

    def found(needle):
        text, whole = needle
        return re.search(rf"(?<!\w){re.escape(text)}(?!\w)", view) if whole else text in view

    for identifier, ways in releases.CHECK_NOW_PATH.items():
        assert any(all(found(needle) for needle in way) for way in ways), identifier


def test_the_two_builds_between_checkouts_were_never_released():
    """So a lab build can never be mistaken for a release, on a screen or in a report.

    Read from CHANGELOG.md, which has a heading for every version released or
    tagged — CI checks out no tags."""
    changelog = (Path(__file__).resolve().parents[2] / "CHANGELOG.md").read_text()
    assert "## [0.6.1]" in changelog and "## [0.4.0]" in changelog, "the headings the test reads are still there"
    for version, _ in (pairs.CHECKOUT_FROM, pairs.CHECKOUT_TO):
        assert f"## [{version}]" not in changelog
