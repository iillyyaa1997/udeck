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
import sys
from pathlib import Path

import pytest
from fakes import Dropped, Failed, Lab, Machine

from udeck_e2e import app, ui, updates
from udeck_e2e.builds import Build
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
    offer = Build(version, number, Path("/tmp") / zip_name)
    monkeypatch.setattr(checks, "_prepare", lambda machine, check_dir, lab, feed, signed_by: offer)
    monkeypatch.setattr(checks, "_open_the_about_pane", lambda machine, check_dir: None)
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
        checks.check_wrong_key(machine, check_dir, lab)
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
        checks.check_wrong_key(machine, check_dir, lab)
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
        checks.check_wrong_key(machine, check_dir, lab)
    assert not isinstance(raised.value, CheckFailed)


def test_the_control_passes_when_the_guest_saw_uDeck_fetch_the_archive(machine, lab, check_dir, monkeypatch):
    """Downloaded and not installed: Sparkle checks the signature after downloading."""
    offer = prepared(monkeypatch)
    finds(monkeypatch)
    says(monkeypatch, "Installed 0.4.1", "Latest 0.4.2")
    monkeypatch.setattr(app, "installed_version", lambda m: checks.FIRST)
    monkeypatch.setattr(updates.Feed, "collect_log", feed_log(f'"GET /{offer.zip.name} HTTP/1.1" 200 -'))

    checks.check_wrong_key(machine, check_dir, lab)
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
        checks.check_wrong_key(machine, check_dir, lab)


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
        checks.check_wrong_key(machine, check_dir, lab)


def test_a_screenshot_that_fails_does_not_hide_an_update_that_installed(machine, lab, check_dir, monkeypatch):
    prepared(monkeypatch)
    finds(monkeypatch)
    says(monkeypatch, "Installed 0.4.2")
    monkeypatch.setattr(app, "installed_version", lambda m: checks.SECOND)
    machine.screenshot_fails = LabError("taking a screenshot", "the machine is gone")
    machine.screenshot_fails_at = "after the refusal"

    with pytest.raises(CheckFailed, match="signed with a key it does not trust"):
        checks.check_wrong_key(machine, check_dir, lab)
    assert any("no screenshot 'after the refusal'" in note for note in lab.notes)


def test_an_install_still_in_flight_is_not_nothing_installed(machine, lab, check_dir, monkeypatch):
    """The wait is a fixed window; a running installer means it was simply too short."""
    offer = prepared(monkeypatch)
    finds(monkeypatch)
    says(monkeypatch, "Installed 0.4.1")
    monkeypatch.setattr(app, "installed_version", lambda m: checks.FIRST)
    monkeypatch.setattr(updates.Feed, "collect_log", feed_log(f'"GET /{offer.zip.name} HTTP/1.1" 200 -'))
    machine.ssh.answers["pgrep -fl"] = "941 /Applications/uDeck.app/Contents/Frameworks/Autoupdate"

    with pytest.raises(LabError, match="still installing"):
        checks.check_wrong_key(machine, check_dir, lab)


def test_a_uDeck_that_died_on_the_press_is_not_a_refusal(machine, lab, check_dir, monkeypatch):
    """"The version on disk did not change" is also true of an application that fell
    over when Install was pressed. Refusing is something uDeck does while carrying on
    being itself."""
    offer = prepared(monkeypatch)
    finds(monkeypatch)
    says(monkeypatch, "Installed 0.4.1")
    monkeypatch.setattr(app, "installed_version", lambda m: checks.FIRST)
    monkeypatch.setattr(updates.Feed, "collect_log", feed_log(f'"GET /{offer.zip.name} HTTP/1.1" 200 -'))
    machine.ssh.answers["pgrep -x uDeck"] = ["404", ""]

    with pytest.raises(CheckFailed, match="did not refuse the update and carry on"):
        checks.check_wrong_key(machine, check_dir, lab)


def test_a_uDeck_that_came_back_as_another_process_is_not_a_refusal(machine, lab, check_dir, monkeypatch):
    """A new pid after the press is an application that was replaced and relaunched,
    which is what installing looks like from outside — and the version on disk is read
    once, at one moment."""
    offer = prepared(monkeypatch)
    finds(monkeypatch)
    says(monkeypatch, "Installed 0.4.1")
    monkeypatch.setattr(app, "installed_version", lambda m: checks.FIRST)
    monkeypatch.setattr(updates.Feed, "collect_log", feed_log(f'"GET /{offer.zip.name} HTTP/1.1" 200 -'))
    machine.ssh.answers["pgrep -x uDeck"] = ["404", "909"]

    with pytest.raises(CheckFailed, match="did not refuse the update and carry on"):
        checks.check_wrong_key(machine, check_dir, lab)


def test_an_archive_the_server_refused_is_not_an_archive_it_served(machine, lab, check_dir, monkeypatch):
    """The witness is the guest's server *answering* for the archive. A request it
    turned away means Sparkle never had the bytes whose signature this is about."""
    offer = prepared(monkeypatch)
    finds(monkeypatch)
    says(monkeypatch, "Installed 0.4.1")
    monkeypatch.setattr(app, "installed_version", lambda m: checks.FIRST)
    monkeypatch.setattr(updates.Feed, "collect_log", feed_log(f'"GET /{offer.zip.name} HTTP/1.1" 404 -'))

    with pytest.raises(LabError, match="never answered for"):
        checks.check_wrong_key(machine, check_dir, lab)


def test_the_archive_is_recognised_whatever_protocol_the_server_logs(machine, lab, check_dir, monkeypatch):
    """The protocol version sits inside the quoted request and is not part of the
    question. Pinning it would make the witness a fact about `http.server`."""
    offer = prepared(monkeypatch)
    finds(monkeypatch)
    says(monkeypatch, "Installed 0.4.1")
    monkeypatch.setattr(app, "installed_version", lambda m: checks.FIRST)
    monkeypatch.setattr(updates.Feed, "collect_log", feed_log(f'"GET /{offer.zip.name} HTTP/1.0" 200 -'))

    checks.check_wrong_key(machine, check_dir, lab)


def test_the_running_installer_is_looked_for_in_a_way_that_cannot_match_the_question(machine, lab, check_dir, monkeypatch):
    """`pgrep -f` reads the arguments of the shell running this very command."""
    offer = prepared(monkeypatch)
    finds(monkeypatch)
    says(monkeypatch, "Installed 0.4.1")
    monkeypatch.setattr(app, "installed_version", lambda m: checks.FIRST)
    monkeypatch.setattr(updates.Feed, "collect_log", feed_log(f'"GET /{offer.zip.name} HTTP/1.1" 200 -'))

    checks.check_wrong_key(machine, check_dir, lab)
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

    checks.check_sparkle(machine, check_dir, lab)
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
        checks.check_sparkle(machine, check_dir, lab)


def test_an_old_uDeck_still_running_beside_the_new_one_is_not_an_update(machine, lab, check_dir, monkeypatch):
    """Sparkle replaces the copy that is running. One still there beside the new is an
    update that did not replace anything, whatever the version on disk says."""
    prepared(monkeypatch)
    finds(monkeypatch)
    says(monkeypatch, "Installed 0.4.1", "Version 0.4.2 is available.")
    monkeypatch.setattr(app, "installed_version", lambda m: checks.SECOND)
    machine.ssh.answers["pgrep -x uDeck"] = ["101", "101 202"]

    with pytest.raises(CheckFailed, match="did not replace the copy that was running"):
        checks.check_sparkle(machine, check_dir, lab)


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
        checks.check_sparkle(machine, check_dir, lab)


def test_a_dropped_connection_never_reads_as_uDeck_is_not_running(machine, lab, check_dir, monkeypatch):
    """"uDeck did not come back" is a verdict; SSH failing is not evidence for it."""
    prepared(monkeypatch)
    finds(monkeypatch)
    says(monkeypatch, "Version 0.4.2 is available.")
    monkeypatch.setattr(app, "installed_version", lambda m: checks.SECOND)
    machine.ssh.answers["pgrep -x uDeck"] = ["101", Dropped]

    with pytest.raises(LabError, match="SSH to 192.168.64.2 failed"):
        checks.check_sparkle(machine, check_dir, lab)


def test_a_screenshot_that_fails_does_not_hide_an_update_that_did_not_happen(machine, lab, check_dir, monkeypatch):
    prepared(monkeypatch)
    finds(monkeypatch)
    says(monkeypatch, "Version 0.4.2 is available.")
    monkeypatch.setattr(app, "installed_version", lambda m: checks.FIRST)
    machine.ssh.answers["pgrep -x uDeck"] = ["101", "202"]
    machine.screenshot_fails = LabError("taking a screenshot", "the machine is gone")
    machine.screenshot_fails_at = "after the update"

    with pytest.raises(CheckFailed, match=r"the version on disk is \('0.4.1', '6'\)"):
        checks.check_sparkle(machine, check_dir, lab)


def test_uDeck_saying_it_is_up_to_date_is_a_failure(machine, lab, check_dir, monkeypatch):
    """The feed was proved to answer and declares a newer build: this is uDeck's answer."""
    prepared(monkeypatch)
    finds(monkeypatch, **{"updates.install": NotThere("waiting", "'updates.install' did not appear")})
    says(monkeypatch, "Installed 0.4.1", "uDeck is up to date.")
    monkeypatch.setattr(app, "installed_version", lambda m: checks.FIRST)

    with pytest.raises(CheckFailed, match="did not offer 0.4.2"):
        checks.check_sparkle(machine, check_dir, lab)


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
        checks.check_sparkle(machine, check_dir, lab)
    assert not isinstance(raised.value, CheckFailed)


def test_uDeck_still_looking_is_a_lab_problem_and_not_a_failure(machine, lab, check_dir, monkeypatch):
    """Nothing finished: the press may not have landed, and that is the lab's own."""
    prepared(monkeypatch)
    finds(monkeypatch, **{"updates.install": NotThere("waiting", "'updates.install' did not appear")})
    says(monkeypatch, "Installed 0.4.1", "Checking…")
    monkeypatch.setattr(app, "installed_version", lambda m: checks.FIRST)

    with pytest.raises(NotThere):
        checks.check_sparkle(machine, check_dir, lab)


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
    checks._prepare(machine, check_dir, lab, feed, signed_by=None)

    quit_asked = [i for i, c in enumerate(machine.ssh.commands) if "to quit" in c]
    unpacked = [i for i, c in enumerate(machine.ssh.commands) if "ditto -x -k" in c]
    assert quit_asked and unpacked and quit_asked[0] < unpacked[0]


def test_two_copies_of_uDeck_running_is_a_lab_problem(machine, lab, check_dir, monkeypatch):
    machine.ssh.answers["pgrep -x uDeck"] = ["", "", "101\n202"]
    machine.ssh.answers["stat -f %Su"] = "admin"
    monkeypatch.setattr(app, "installed_version", lambda m: checks.FIRST)

    feed = updates.Feed(machine, lab.note)
    with pytest.raises(LabError, match="2 copies of uDeck are running"):
        checks._prepare(machine, check_dir, lab, feed, signed_by=None)


def test_the_lab_installing_the_wrong_version_is_not_a_verdict_about_uDeck(machine, lab, check_dir, monkeypatch):
    """The lab put it there a second earlier: if it is wrong, the lab is wrong."""
    machine.ssh.answers["stat -f %Su"] = "admin"
    monkeypatch.setattr(app, "installed_version", lambda m: checks.SECOND)

    feed = updates.Feed(machine, lab.note)
    with pytest.raises(LabError, match="the lab installed"):
        checks._prepare(machine, check_dir, lab, feed, signed_by=None)


def test_each_check_builds_into_a_directory_of_its_own(machine, lab, check_dir, monkeypatch):
    """Both checks build the same two versions; the second must not overwrite the first."""
    machine.ssh.answers["pgrep -x uDeck"] = ["", "", "101"]
    machine.ssh.answers["stat -f %Su"] = "admin"
    monkeypatch.setattr(app, "installed_version", lambda m: checks.FIRST)

    feed = updates.Feed(machine, lab.note)
    checks._prepare(machine, check_dir, lab, feed, signed_by=None)
    assert lab.builders == [(feed.url, check_dir.name)]


def test_a_machine_that_never_starts_uDeck_is_a_lab_problem(machine, lab, check_dir, monkeypatch):
    machine.ssh.answers["pgrep -x uDeck"] = ""
    machine.ssh.answers["stat -f %Su"] = "admin"
    monkeypatch.setattr(app, "installed_version", lambda m: checks.FIRST)

    feed = updates.Feed(machine, lab.note)
    with pytest.raises(LabError, match="uDeck was not running within"):
        checks._prepare(machine, check_dir, lab, feed, signed_by=None)
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
        checks.check_sparkle(machine, check_dir, lab)
    assert machine.now >= 100, "the swap has to eat into the budget for this to mean anything"
    assert machine.now <= checks.INSTALL_SECONDS + 5


def test_a_blip_while_uDeck_starts_is_not_uDeck_failing_to_start(machine, lab, check_dir, monkeypatch):
    """Every wait in the lab tolerates one refusal and keeps to its deadline."""
    machine.ssh.answers["pgrep -x uDeck"] = ["", Dropped, "", "303"]
    machine.ssh.answers["stat -f %Su"] = "admin"
    monkeypatch.setattr(app, "installed_version", lambda m: checks.FIRST)

    feed = updates.Feed(machine, lab.note)
    checks._prepare(machine, check_dir, lab, feed, signed_by=None)
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
        monkeypatch.setattr(checks, "_a_uDeck_that_never_looked", lambda *a: None)
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

    def open_the_about_pane(self, machine, check_dir):
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


# The shipped behaviour: quiet until asked.


def test_a_uDeck_that_stays_quiet_and_asks_when_asked_passes(machine, lab, check_dir, monkeypatch):
    scene = Scene(monkeypatch, machine)
    checks.check_it_does_not_look_by_itself(machine, check_dir, lab)
    assert scene.clicked == ["updates.checkNow"]
    assert any("heard nothing from it" in note for note in lab.notes)


def test_it_listens_for_the_whole_quiet_window_before_it_asks(machine, lab, check_dir, monkeypatch):
    """The witness is pressed after the window, never inside it: a request it caused would be
    indistinguishable in the log from one uDeck made by itself."""
    scene = Scene(monkeypatch, machine)
    checks.check_it_does_not_look_by_itself(machine, check_dir, lab)
    assert machine.now - scene.launched_at >= checks.QUIET_SECONDS
    assert max(scene.read_at) - scene.launched_at >= checks.QUIET_SECONDS


def test_a_uDeck_that_asks_its_feed_by_itself_fails(machine, lab, check_dir, monkeypatch):
    """What a build shipping with automatic checks on does: it asks straight after launch."""
    scene = Scene(monkeypatch, machine, asks_by_itself_after=2)
    with pytest.raises(CheckFailed, match="asked its feed for an update by itself .* after it started, before"):
        checks.check_it_does_not_look_by_itself(machine, check_dir, lab)
    assert scene.clicked == [], "the witness must never be what the verdict is about"
    assert scene.window_opened_at is None, "said as soon as it was heard, before the window is opened"


def test_a_uDeck_that_asks_when_its_settings_window_opens_fails(machine, lab, check_dir, monkeypatch):
    """Opening the window is something the operator does, not something he asks uDeck to look with.

    The first version of this check took the witness's mark before it opened the
    window, so this request was counted as the button's and the check was green."""
    scene = Scene(monkeypatch, machine, asks_when_the_window_opens=True)
    with pytest.raises(CheckFailed, match="by itself .* with its settings window open, before anyone pressed Check now"):
        checks.check_it_does_not_look_by_itself(machine, check_dir, lab)
    assert scene.clicked == [], "Check now is never pressed once uDeck has asked by itself"


def test_a_request_after_the_quiet_window_and_before_the_click_is_still_uDeck_asking(
        machine, lab, check_dir, monkeypatch):
    """A uDeck that looks twenty-odd seconds after it starts, while the lab opens its window."""
    scene = Scene(monkeypatch, machine, asks_by_itself_after=checks.QUIET_SECONDS + 1)
    with pytest.raises(CheckFailed, match="with its settings window open"):
        checks.check_it_does_not_look_by_itself(machine, check_dir, lab)
    assert scene.clicked == []


def test_the_window_is_listened_to_before_the_click_and_the_mark_is_read_straight_before_it(
        machine, lab, check_dir, monkeypatch):
    """What the witness counts from is the read that ends the listening, with nothing between it
    and the click but the click itself — a `ui.click` there would walk the window for the button
    first, and a request in that walk would be counted as the button's."""
    scene = Scene(monkeypatch, machine)
    checks.check_it_does_not_look_by_itself(machine, check_dir, lab)
    assert scene.check_now_at - scene.window_opened_at >= checks.WINDOW_QUIET_SECONDS
    clicked = scene.events.index(("click", scene.check_now_at))
    assert scene.events[clicked - 1] == ("read", scene.check_now_at), "the last read before the click is at the click"
    assert scene.walks == 0, "the button is the one the pane was found with, not looked for again"
    assert any("of quiet up to the click on Check now" in note for note in lab.notes)


def test_a_request_late_in_the_window_is_still_uDeck_asking(machine, lab, check_dir, monkeypatch):
    Scene(monkeypatch, machine, asks_by_itself_after=checks.QUIET_SECONDS - 1)
    with pytest.raises(CheckFailed, match="asked its feed"):
        checks.check_it_does_not_look_by_itself(machine, check_dir, lab)


def test_the_lab_asking_its_own_feed_is_not_uDeck_asking(machine, lab, check_dir, monkeypatch):
    """`serve` asks for the appcast to learn the server is up, and that line is in the log from the start."""
    scene = Scene(monkeypatch, machine)
    scene.log = [LAB_ASKED, LAB_ASKED]
    checks.check_it_does_not_look_by_itself(machine, check_dir, lab)


def test_quiet_from_a_uDeck_that_does_not_ask_when_asked_proves_nothing(machine, lab, check_dir, monkeypatch):
    """A uDeck that cannot reach its feed is exactly as quiet as one that chose not to ask."""
    Scene(monkeypatch, machine, asks_when_asked=False)
    with pytest.raises(LabError, match="the quiet before proves nothing") as raised:
        checks.check_it_does_not_look_by_itself(machine, check_dir, lab)
    assert not isinstance(raised.value, CheckFailed)


def test_a_feed_log_that_cannot_be_read_is_not_silence(machine, lab, check_dir, monkeypatch):
    """Once is enough: a read that failed while listening is a stretch nobody heard, and a
    listener that shrugged it off would call the rest of the window "quiet"."""
    scene = Scene(monkeypatch, machine)
    reads = []

    def once_unreadable(step):
        reads.append(step)
        if len(reads) == 1:
            raise LabError(step, "the guest's server log could not be read: exit 1")
        return scene.read_log(step)

    monkeypatch.setattr(updates.Feed, "read_log", lambda feed, step: once_unreadable(step))
    with pytest.raises(LabError, match="could not be read") as raised:
        checks.check_it_does_not_look_by_itself(machine, check_dir, lab)
    assert not isinstance(raised.value, CheckFailed)
    assert scene.clicked == [], "the listening itself has to stop there, before any witness"


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


def test_a_request_before_the_switch_leaves_the_switch_nothing_to_start(machine, lab, check_dir, monkeypatch):
    """That request set the last-check date, and a switch turned on after it causes nothing for a
    day — a failure that belongs to the other check, not this one."""
    scene = Scene(monkeypatch, machine)
    scene.log = [LAB_ASKED, UDECK_ASKED]
    with pytest.raises(LabError, match="before automatic checks were turned on") as raised:
        checks.check_switched_on_it_looks_by_itself(machine, check_dir, lab)
    assert not isinstance(raised.value, CheckFailed)
    assert scene.switched == []


def test_a_switch_already_on_is_not_pressed(machine, lab, check_dir, monkeypatch):
    """Pressed, it would turn automatic checks off, and the check would be asking the opposite question."""
    scene = Scene(monkeypatch, machine, value="1")
    with pytest.raises(LabError, match="pressing it would turn automatic checks off"):
        checks.check_switched_on_it_looks_by_itself(machine, check_dir, lab)
    assert scene.switched == []


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


def test_a_machine_that_remembers_nothing_is_not_touched(machine, lab, check_dir, monkeypatch):
    machine.ssh.answers["stat -f %Su"] = "admin"
    machine.ssh.answers[f"defaults read {app.BUNDLE_ID}"] = Failed(1, "Domain place.unicorns.udeck does not exist")
    monkeypatch.setattr(app, "installed_version", lambda m: checks.FIRST)

    checks._a_uDeck_that_never_looked(machine, check_dir, lab, updates.Feed(machine, lab.note))
    assert not any("defaults delete" in c for c in machine.ssh.commands)
