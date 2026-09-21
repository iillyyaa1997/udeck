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
from fakes import Dropped, Lab, Machine

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
