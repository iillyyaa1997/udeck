"""The login checks: what they read, and what they refuse to conclude.

A check about opening at login is unusually easy to write so that it proves nothing: the
switch is in uDeck's own window, the system's answer is in a database nobody looks at, and
"it is not running" is the expected outcome of the control *and* of a machine where the
whole thing silently failed. So each test below asks the same question — would this still
pass if the feature were broken?
"""

import importlib.util
import sys
from pathlib import Path

import pytest
from fakes import Dropped, Failed, Lab, Machine
from test_login import AS_A_LOGIN_ITEM, AUTOLAUNCH, LAUNCHED, LAUNCHER, REOPENED

from udeck_e2e import app, login, ui
from udeck_e2e.errors import CheckFailed, LabError


def _load():
    path = Path(__file__).resolve().parents[1] / "checks" / "check_login.py"
    spec = importlib.util.spec_from_file_location("check_login_under_test", path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


checks = _load()

ON = """\
 #1:
                 Name: uDeck
          Disposition: [enabled, allowed, visible, notified] (0xb)
           Identifier: place.unicorns.udeck
                  URL: /Applications/uDeck.app
           Generation: 1
"""
OFF = ON.replace("[enabled, allowed, visible, notified] (0xb)", "[disabled, allowed, visible, notified] (0x2)")
ELSEWHERE = ON.replace("/Applications/uDeck.app", "/Users/x/Applications/uDeck-debug.app")
NOTHING = " Items:\n"
# The same record, registered again rather than restored: a later generation.
ON_AGAIN = ON.replace("Generation: 1", "Generation: 3")
# What an update legitimately does to the row, measured in a guest on 2026-09-19:
# macOS re-files it once because the bundle at the path was replaced.
ON_REFILED = ON.replace("Generation: 1", "Generation: 2")
# What the guest's log says was done with the record (`login.Witnesses`), in the lines
# measured on 2026-10-12 — the pid is the fake's own uDeck, "404". The switch registers
# uDeck once; a registration after it is uDeck registering itself again.
REGISTERED = (
    "2026-10-12 18:11:49.441 Df backgroundtaskmanagementd[291:961] [com.apple.backgroundtaskmanagement:main] "
    "registerLaunchItem: pid=404, uid=501, type=app, url=(null), config=(null)\n"
)
SWITCH = (
    "2026-10-12 18:11:42.472 Df uDeck[404:17dc] [com.apple.runningboard:connection] "
    "Identity resolved as app<application.place.unicorns.udeck.525647.525652(501)>\n" + REGISTERED
)
AGAIN = REGISTERED.replace("18:11:49.441", "18:12:55.000")
# A login that opened uDeck by its record, after the boot (`BOOTED`).
OPENED_AT_LOGIN = LAUNCHER + AUTOLAUNCH + AS_A_LOGIN_ITEM + LAUNCHED
# A login whose launcher ran and opened nothing.
NOTHING_AT_LOGIN = LAUNCHER
BOOTED = "2026-10-12 18:12:37"
# The generation the record came back with across a restart, which is evidence and no
# longer a verdict: it moves at uDeck's starts and exits, measured on 2026-10-12.
ON_OPENED = ON.replace("Generation: 1", "Generation: 2")

# The row's own identity. Two dumps that agree on everything a path can show and
# disagree on this are two different registrations, one of them wearing the other's
# path — which is the failure uDeck's own source calls the main one.
UUID_ONE = "E733CC95-57C0-4903-83CF-37EC936DDF13"
UUID_TWO = "0CA3B98E-AF3F-4D60-B6BC-DE43F0A90D8D"
WITH_UUID = ON.replace(" #1:\n", f" #1:\n                 UUID: {UUID_ONE}\n")
ANOTHER_ROW = WITH_UUID.replace(UUID_ONE, UUID_TWO)


@pytest.fixture
def lab(tmp_path):
    return Lab(tmp_path)


@pytest.fixture
def check_dir(tmp_path):
    path = tmp_path / "login.registers"
    path.mkdir()
    return path


def a_machine(dumps, running="404", log=SWITCH + OPENED_AT_LOGIN):
    """A guest whose login database answers `dumps` in turn, and whose log since the check
    began says `log` — by default the switch's registration and a login that opened uDeck."""
    return Machine({
        "sfltool dumpbtm": dumps,
        "pgrep -x uDeck": running,
        "stat -f %Su": "admin",
        "/usr/bin/log show": "Timestamp               Ty Process[PID:TID]\n" + log if isinstance(log, str) else log,
        "/bin/date -r": BOOTED,
        "/bin/date '+%Y": "2026-10-12 18:11:40",
        "sysctl -n kern.boottime": "{ sec = 1760292757, usec = 0 } Mon Oct 12 18:12:37 2026",
    })  # fmt: skip


@pytest.fixture(autouse=True)
def nothing_real(monkeypatch):
    monkeypatch.setattr(app, "installed_version", lambda machine: checks.VERSION)
    monkeypatch.setattr(app, "install", lambda machine, zip_, note: None)
    monkeypatch.setattr(app, "launch", lambda machine, step="starting uDeck": {"404"})
    # Quitting and asking the guest's log are the two new trips to the machine that
    # the restart checks make. Stubbed here so every other test keeps its shape; the
    # tests that are *about* them replace these with their own.
    monkeypatch.setattr(app, "quit_app", lambda machine, step, seconds=None: None)
    monkeypatch.setattr(app, "the_system_reopened_it", lambda machine, step=None: False)
    monkeypatch.setattr(ui, "open_settings_and_wait", lambda *a, **k: None)
    monkeypatch.setattr(ui, "wait_for", lambda machine, identifier, step, **k: ui.Element(identifier, 1, 2, 3, 4))

    # A card whose sentence follows the switch, because the application's does: the tense
    # is what the checks below read, so a fake that always said the same thing would let
    # a card frozen in one tense pass.
    card = {"opens": False}

    def click(machine, identifier, step, **k):
        if identifier == "general.openAtLogin":
            card["opens"] = not card["opens"]
        return ui.Element(identifier, 1, 2, 3, 4)

    monkeypatch.setattr(ui, "click", click)
    monkeypatch.setattr(ui, "static_texts", lambda machine, step, window=ui.SETTINGS_WINDOW: [
        "Open at Login",
        checks.OPENS if card["opens"] else checks.WOULD_OPEN,
    ])


# --- Switching it on ------------------------------------------------------------------


def test_switching_it_on_is_believed_only_when_the_system_says_so(lab, check_dir):
    machine = a_machine([NOTHING, ON])
    checks.check_registers(machine, check_dir, lab)
    assert any("sfltool dumpbtm" in c for c in machine.ssh.commands)


def test_a_card_that_claims_it_opens_before_anything_is_switched_on_fails(lab, check_dir, monkeypatch):
    """The state every fresh install starts in, and the one the card used to lie about."""
    monkeypatch.setattr(ui, "static_texts", lambda *a, **k: [checks.OPENS])
    with pytest.raises(CheckFailed, match="the card does not say so"):
        checks.check_registers(a_machine([NOTHING, ON]), check_dir, lab)


def test_a_card_still_in_the_conditional_after_switching_on_fails(lab, check_dir, monkeypatch):
    """The other half: a card frozen in one tense passes the first assertion by luck."""
    monkeypatch.setattr(ui, "static_texts", lambda *a, **k: [checks.WOULD_OPEN])
    with pytest.raises(CheckFailed, match="the card does not say so"):
        checks.check_registers(a_machine([NOTHING, ON]), check_dir, lab)


def test_a_switch_the_system_did_not_take_fails(lab, check_dir):
    """The measured way this goes wrong: nothing throws and the record never appears."""
    machine = a_machine([NOTHING, NOTHING])
    with pytest.raises(CheckFailed, match="the system has no record"):
        checks.check_registers(machine, check_dir, lab)


def test_a_record_that_points_at_another_copy_fails(lab, check_dir):
    """The failure this feature exists to survive: the record names a copy that is not
    the one the operator just switched on."""
    machine = a_machine([NOTHING, ELSEWHERE])
    with pytest.raises(CheckFailed, match="not at the copy that was switched on"):
        checks.check_registers(machine, check_dir, lab)


def test_a_machine_that_arrived_already_registered_is_not_checked(lab, check_dir):
    """Otherwise the check passes without the click having done anything — which is what
    a shared machine (--vm per-group) would hand it."""
    machine = a_machine([ON, ON])
    with pytest.raises(CheckFailed, match="already had a login record"):
        checks.check_registers(machine, check_dir, lab)


def test_a_disabled_leftover_is_not_a_registration(lab, check_dir):
    machine = a_machine([OFF, ON])
    checks.check_registers(machine, check_dir, lab)


# --- Surviving a restart --------------------------------------------------------------


def test_uDeck_coming_back_by_itself_passes(lab, check_dir, monkeypatch):
    machine = a_machine([ON, ON_OPENED])
    monkeypatch.setattr(machine, "reboot", lambda: None, raising=False)
    checks.check_survives_a_restart(machine, check_dir, lab)


def test_a_machine_that_comes_back_without_uDeck_fails(lab, check_dir, monkeypatch):
    machine = a_machine([ON, ON], running="")
    monkeypatch.setattr(machine, "reboot", lambda: None, raising=False)
    with pytest.raises(CheckFailed, match="did not open"):
        checks.check_survives_a_restart(machine, check_dir, lab)
    assert machine.now >= checks.OPENS_WITHIN_SECONDS, "it is given the whole window first"


def test_a_screenshot_that_fails_does_not_hide_uDeck_not_coming_back(lab, check_dir, monkeypatch):
    """The verdict is about uDeck, and a camera that failed is not allowed to take it.

    A machine that lost its login item across a restart is the same machine whose VNC and
    sudo are suspect, so the two are likeliest to fail together — and "could not check"
    on that run costs the whole run.
    """
    machine = a_machine([ON, ON], running="")
    monkeypatch.setattr(machine, "reboot", lambda: None, raising=False)
    machine.screenshot_fails = LabError("taking a screenshot", "the machine is gone")
    machine.screenshot_fails_at = "after the restart"
    with pytest.raises(CheckFailed, match="did not open"):
        checks.check_survives_a_restart(machine, check_dir, lab)


def test_an_unreadable_database_does_not_hide_uDeck_not_coming_back(lab, check_dir, monkeypatch):
    """The same for the record: it is quoted in the sentence, not consulted for it."""
    machine = a_machine([ON, Dropped], running="")
    monkeypatch.setattr(machine, "reboot", lambda: None, raising=False)
    with pytest.raises(CheckFailed, match="did not open"):
        checks.check_survives_a_restart(machine, check_dir, lab)


def test_the_restart_check_asks_the_guest_nothing_after_it_has_passed(lab, check_dir, monkeypatch):
    """A note is not worth a lab error: the pids printed are the ones already read — one
    look before the switch (`_switch_on`), one after the restart, and none after that."""
    machine = a_machine([ON, ON_OPENED], running=["404", "404", Dropped])
    monkeypatch.setattr(machine, "reboot", lambda: None, raising=False)
    checks.check_survives_a_restart(machine, check_dir, lab)
    assert any("404" in note for note in lab.notes)


def _watch_the_order(monkeypatch, machine):
    """What the check does to the machine, in the order it does it — and when.

    The clock is the fake's, which moves only when something sleeps, so the gap
    between two entries is exactly the waiting the check asked for.
    """
    order = []
    monkeypatch.setattr(
        app, "quit_app", lambda machine_, step, seconds=None: order.append(("quit", machine.now))
    )
    monkeypatch.setattr(machine, "reboot", lambda: order.append(("reboot", machine.now)), raising=False)
    return order


def test_the_restart_check_quits_uDeck_before_restarting(lab, check_dir, monkeypatch):
    """macOS reopens what was running when the session ended, and a uDeck brought
    back that way is indistinguishable from one the login record opened. Measured
    in a guest on 2026-09-20 — `loginwindow … persistentAppPreLaunch …
    bundleID:place.unicorns.udeck` with the record reading `[disabled]` — which is
    a second reason for this check to be green that has nothing to do with it."""
    machine = a_machine([ON, ON_OPENED])
    order = _watch_the_order(monkeypatch, machine)
    checks.check_survives_a_restart(machine, check_dir, lab)
    assert [what for what, _ in order] == ["quit", "reboot"]


def test_the_control_quits_uDeck_before_restarting(lab, check_dir, monkeypatch):
    """Where it was caught: two restarts in twelve came back with uDeck running and
    the record correctly disabled, and the control called that uDeck's doing."""
    machine = a_machine([ON, OFF, OFF], running="", log=SWITCH + NOTHING_AT_LOGIN)
    order = _watch_the_order(monkeypatch, machine)
    checks.check_off_stays_off(machine, check_dir, lab)
    assert [what for what, _ in order] == ["quit", "reboot"]


def test_both_restart_checks_leave_the_machine_alone_before_restarting(lab, check_dir, monkeypatch):
    """Quitting uDeck is not enough to stop macOS reopening it — measured, 3 reopens in
    10 with no wait and none at all at twenty seconds or more. What the checks buy with
    the wait is the difference between a verdict and a coin toss, so the wait is not a
    tidy-up and has a test."""
    for check, dumps, running, log in (
        (checks.check_survives_a_restart, [ON, ON_OPENED], "404", SWITCH + OPENED_AT_LOGIN),
        (checks.check_off_stays_off, [ON, OFF, OFF], "", SWITCH + NOTHING_AT_LOGIN),
    ):
        machine = a_machine(dumps, running=running, log=log)
        order = _watch_the_order(monkeypatch, machine)
        check(machine, check_dir, lab)
        (_, quit_at), (_, reboot_at) = order[0], order[1]
        assert reboot_at - quit_at >= checks.SETTLE_BEFORE_RESTART_SECONDS, (
            f"{check.__name__} restarted {reboot_at - quit_at}s after quitting uDeck"
        )


# Where the reopens stopped, measured on 2026-09-21 across forty runs of this flow:
# three in ten with no wait at all, and none in ten at each of twenty, forty-five and
# ninety seconds. Written here rather than read from the constant, because a test that
# reads the number it is checking agrees with any number.
MEASURED_CLEAN_AT_SECONDS = 20


def test_the_wait_is_not_shorter_than_the_one_that_was_measured_clean():
    """The constant may be raised for margin — it is, by half — and must never be lowered
    past what was measured, which is the only thing standing behind it. The mechanism is
    not known, so there is nothing else to reason from."""
    assert checks.SETTLE_BEFORE_RESTART_SECONDS >= MEASURED_CLEAN_AT_SECONDS


def _two_copies(first, second):
    """A dump holding this uDeck's row and another copy's, each given as (uuid, url, on)."""
    def row(n, uuid, url, on, generation):
        disposition = "[enabled, allowed, notified] (0xb)" if on else "[disabled, allowed, notified] (0xa)"
        return (f" #{n}:\n                 UUID: {uuid}\n                 Name: uDeck\n"
                f"          Disposition: {disposition}\n           Identifier: 2.place.unicorns.udeck\n"
                f"                  URL: {url}\n           Generation: {generation}\n"
                f"    Bundle Identifier: place.unicorns.udeck\n")
    return row(1, *first) + row(2, *second)


LIVE_ON = ("A", "/Applications/uDeck.app", True, 1)


def test_another_copy_set_to_open_does_not_make_the_control_blame_uDeck(lab, check_dir, monkeypatch):
    """uDeck switched its own row off; another copy's row beside it is enabled. The old
    reading took that one and said uDeck had not switched off, when it had. A machine
    where another copy opens at login cannot show this one's switch working either way."""
    switched_off = _two_copies(("A", "/Applications/uDeck.app", False, 2), ("B", "/Users/x/Applications/uDeck.app", True, 1))
    machine = a_machine([_two_copies(LIVE_ON, ("B", "/Users/x/Applications/uDeck.app", False, 1)), switched_off], running="")
    monkeypatch.setattr(machine, "reboot", lambda: None, raising=False)
    with pytest.raises(LabError, match="another copy of uDeck is set to open at login") as raised:
        checks.check_off_stays_off(machine, check_dir, lab)
    assert not isinstance(raised.value, CheckFailed)


def test_the_control_passes_on_its_own_row_with_another_copy_switched_off_beside_it(lab, check_dir, monkeypatch):
    """The other side: a second copy on the machine is not a reason to stop, only one
    that is set to open."""
    quiet_other = ("B", "/Users/x/Applications/uDeck.app", False, 1)
    machine = a_machine([
        _two_copies(LIVE_ON, quiet_other),
        _two_copies(("A", "/Applications/uDeck.app", False, 2), quiet_other),
        _two_copies(("A", "/Applications/uDeck.app", False, 2), quiet_other),
    ], running="", log=SWITCH + NOTHING_AT_LOGIN)
    monkeypatch.setattr(machine, "reboot", lambda: None, raising=False)
    checks.check_off_stays_off(machine, check_dir, lab)


def test_a_restart_that_opened_another_copy_says_so(lab, check_dir, monkeypatch):
    """uDeck is running and the row that was switched on is disabled: what opened at login
    was a different copy, and the sentence names it rather than calling the row replaced."""
    machine = a_machine([
        _two_copies(LIVE_ON, ("B", "/Users/x/Applications/uDeck.app", False, 1)),
        _two_copies(("A", "/Applications/uDeck.app", False, 2), ("B", "/Users/x/Applications/uDeck.app", True, 2)),
    ])
    monkeypatch.setattr(machine, "reboot", lambda: None, raising=False)
    with pytest.raises(CheckFailed, match="what opened at login is another copy"):
        checks.check_survives_a_restart(machine, check_dir, lab)


def test_a_restart_the_system_reopened_proves_nothing_either_way(lab, check_dir, monkeypatch):
    """Not uDeck's doing, so not uDeck's to answer for — in both checks, and whether
    or not the record says what it should."""
    monkeypatch.setattr(app, "the_system_reopened_it", lambda machine, step=None: True)

    came_back = a_machine([ON, ON])
    monkeypatch.setattr(came_back, "reboot", lambda: None, raising=False)
    with pytest.raises(LabError, match="macOS reopened uDeck by itself") as raised:
        checks.check_survives_a_restart(came_back, check_dir, lab)
    assert not isinstance(raised.value, CheckFailed)

    stayed_off = a_machine([ON, OFF, OFF], running="909")
    monkeypatch.setattr(stayed_off, "reboot", lambda: None, raising=False)
    with pytest.raises(LabError, match="macOS reopened uDeck by itself"):
        checks.check_off_stays_off(stayed_off, check_dir, lab)


def test_a_record_another_copy_has_taken_fails_the_restart(lab, check_dir, monkeypatch):
    """uDeck came back, and what the system opens at login is a different copy of it.

    This is the failure the feature exists to survive — `LoginItemCopies` in uDeck's own
    source calls it the main one: a second copy with the same bundle identifier takes the
    record simply by running. Until this, the check read "there is an enabled record"
    and asked nothing about which copy it named.
    """
    machine = a_machine([ON, ELSEWHERE])
    monkeypatch.setattr(machine, "reboot", lambda: None, raising=False)
    with pytest.raises(CheckFailed, match="another copy has taken it"):
        checks.check_survives_a_restart(machine, check_dir, lab)


def test_a_restart_the_record_did_not_open_is_not_a_verdict(lab, check_dir, monkeypatch):
    """uDeck came back and the login items launcher did not open it: something else did,
    and nothing here is about whether the record would have.

    It used to be told by the generation standing still, and that was the wrong witness:
    measured on 2026-10-12, the generation moves at uDeck's exits — at the lab's own quit
    before the restart — and once not at all across a restart the record did open uDeck."""
    machine = a_machine([ON, ON_OPENED], log=SWITCH + NOTHING_AT_LOGIN)
    monkeypatch.setattr(machine, "reboot", lambda: None, raising=False)
    with pytest.raises(LabError, match="the login items launcher did not open it") as raised:
        checks.check_survives_a_restart(machine, check_dir, lab)
    assert not isinstance(raised.value, CheckFailed)


def test_macOS_putting_uDeck_back_is_not_the_record_opening_it(lab, check_dir, monkeypatch):
    """LaunchServices writes the same `event=aevt/oapp` launch when macOS reopens what was
    running (probe.tal, 2026-10-12): without the launcher naming the copy as a login item,
    that launch is not the record's."""
    machine = a_machine([ON, ON_OPENED], log=SWITCH + LAUNCHER + REOPENED)
    monkeypatch.setattr(machine, "reboot", lambda: None, raising=False)
    with pytest.raises(LabError, match="did not open it"):
        checks.check_survives_a_restart(machine, check_dir, lab)


def test_a_restart_whose_login_is_not_in_the_log_is_not_a_verdict(lab, check_dir, monkeypatch):
    machine = a_machine([ON, ON_OPENED], log=SWITCH + REOPENED)
    monkeypatch.setattr(machine, "reboot", lambda: None, raising=False)
    with pytest.raises(LabError, match="no `LoginItemsLauncher main` after the boot"):
        checks.check_survives_a_restart(machine, check_dir, lab)


def test_a_restart_whose_log_holds_two_logins_is_not_a_verdict(lab, check_dir, monkeypatch):
    """Two runs of the launcher after the boot are another boot's lines read as this one's."""
    other = LAUNCHER.replace("18:12:50.951", "18:12:40.000")
    for check, dumps, running in (
        (checks.check_survives_a_restart, [ON, ON_OPENED], "404"),
        (checks.check_off_stays_off, [ON, OFF, OFF], ""),
    ):
        machine = a_machine(dumps, running=running, log=SWITCH + other + OPENED_AT_LOGIN)
        monkeypatch.setattr(machine, "reboot", lambda: None, raising=False)
        with pytest.raises(LabError, match="2 runs of the login items launcher") as raised:
            check(machine, check_dir, lab)
        assert not isinstance(raised.value, CheckFailed), check.__name__


def test_a_record_registered_again_across_a_restart_fails(lab, check_dir, monkeypatch):
    """uDeck registers only when asked: a registration after the switch's own is it
    registering itself again, whatever the generation says."""
    machine = a_machine([ON, ON_OPENED], log=SWITCH + OPENED_AT_LOGIN + AGAIN)
    monkeypatch.setattr(machine, "reboot", lambda: None, raising=False)
    with pytest.raises(CheckFailed, match="registered itself again"):
        checks.check_survives_a_restart(machine, check_dir, lab)


def test_a_generation_that_moved_more_than_once_is_not_a_registration(lab, check_dir, monkeypatch):
    """The reading that used to fail this check 3 times in 13 (2026-10-12): generation 1 to
    4 across a restart, and no registration from uDeck in the log after the switch."""
    machine = a_machine([ON, ON.replace("Generation: 1", "Generation: 4")])
    monkeypatch.setattr(machine, "reboot", lambda: None, raising=False)
    checks.check_survives_a_restart(machine, check_dir, lab)
    assert any("evidence only" in note and "generation 4" in note for note in lab.notes)


def test_a_log_without_the_switch_s_own_registration_proves_nothing_about_the_rest(lab, check_dir, monkeypatch):
    """Silence after the switch means something only in a log that shows the switch."""
    machine = a_machine([ON, ON_OPENED], log=OPENED_AT_LOGIN)
    monkeypatch.setattr(machine, "reboot", lambda: None, raising=False)
    with pytest.raises(LabError, match="not even the one the switch made") as raised:
        checks.check_survives_a_restart(machine, check_dir, lab)
    assert not isinstance(raised.value, CheckFailed)


def test_the_record_opening_another_copy_fails_the_restart(lab, check_dir, monkeypatch):
    elsewhere = AUTOLAUNCH.replace("/Applications/uDeck.app", "/Users/x/Applications/uDeck.app")
    machine = a_machine([ON, ON_OPENED], log=SWITCH + LAUNCHER + elsewhere + AS_A_LOGIN_ITEM + LAUNCHED)
    monkeypatch.setattr(machine, "reboot", lambda: None, raising=False)
    with pytest.raises(CheckFailed, match="not the copy that was switched on"):
        checks.check_survives_a_restart(machine, check_dir, lab)


def test_the_restart_check_keeps_the_log_it_read(lab, check_dir, monkeypatch):
    machine = a_machine([ON, ON_OPENED])
    monkeypatch.setattr(machine, "reboot", lambda: None, raising=False)
    checks.check_survives_a_restart(machine, check_dir, lab)
    assert "performAutolaunch" in (check_dir / "login-log.txt").read_text()


def test_a_different_row_wearing_the_same_path_fails_the_restart(lab, check_dir, monkeypatch):
    """Same path, same disposition, same generation — and not the same record."""
    machine = a_machine([WITH_UUID, ANOTHER_ROW])
    monkeypatch.setattr(machine, "reboot", lambda: None, raising=False)
    with pytest.raises(CheckFailed, match="the row that was switched on is gone"):
        checks.check_survives_a_restart(machine, check_dir, lab)


def test_a_dump_without_the_row_identity_still_checks_everything_else(lab, check_dir, monkeypatch):
    """The UUID is read out of a report meant for a person. A macOS that stops printing it
    must cost the lab that one sentence, not every run."""
    machine = a_machine([ON, ON_OPENED])
    monkeypatch.setattr(machine, "reboot", lambda: None, raising=False)
    checks.check_survives_a_restart(machine, check_dir, lab)


def test_the_check_refuses_to_restart_a_machine_it_could_not_switch_on(lab, check_dir, monkeypatch):
    """A restart proves nothing when the setting was never recorded, and saying "uDeck did
    not come back" there would be a verdict against the wrong thing."""
    machine = a_machine([NOTHING])
    restarted = []
    monkeypatch.setattr(machine, "reboot", lambda: restarted.append(True), raising=False)
    with pytest.raises(LabError, match="the system did not take it"):
        checks.check_survives_a_restart(machine, check_dir, lab)
    assert not restarted


# --- The control ----------------------------------------------------------------------


def test_switched_off_and_restarted_it_stays_away(lab, check_dir, monkeypatch):
    machine = a_machine([ON, OFF, OFF], running="", log=SWITCH + NOTHING_AT_LOGIN)
    monkeypatch.setattr(machine, "reboot", lambda: None, raising=False)
    checks.check_off_stays_off(machine, check_dir, lab)
    assert machine.now >= checks.NOTHING_OPENS_SECONDS, "nothing happening is only worth something after a while"


def test_the_control_keeps_the_reading_it_decided_on(lab, check_dir, monkeypatch):
    """A pass has to leave behind the database it passed on.

    The reading that decides this control is the one taken after switching off, and the
    only dump it used to keep was the one from switching on — which shows the record
    enabled, the opposite of the verdict.
    """
    machine = a_machine([ON, OFF, OFF], running="", log=SWITCH + NOTHING_AT_LOGIN)
    monkeypatch.setattr(machine, "reboot", lambda: None, raising=False)
    checks.check_off_stays_off(machine, check_dir, lab)
    # Named, not "some file with the right word in it": the run keeps a post-restart dump
    # as well, and an assertion satisfied by that one passes while the reading the verdict
    # rests on is still thrown away (measured — it survived two mutations before this).
    kept = check_dir / "login-records-after-switching-off.txt"
    assert kept.exists(), sorted(path.name for path in check_dir.glob("*.txt"))
    assert "disabled" in kept.read_text()


def test_the_restart_check_keeps_the_database_it_came_back_with(lab, check_dir, monkeypatch):
    machine = a_machine([ON, ON_OPENED])
    monkeypatch.setattr(machine, "reboot", lambda: None, raising=False)
    checks.check_survives_a_restart(machine, check_dir, lab)
    kept = sorted(path.name for path in check_dir.glob("login-records-*.txt"))
    assert "login-records-after-the-restart.txt" in kept, kept


def test_the_control_switches_it_on_first(lab, check_dir, monkeypatch):
    """A machine where nothing was ever registered also comes back without uDeck, and
    proves only that the lab can watch a machine do nothing."""
    machine = a_machine([NOTHING], running="")
    monkeypatch.setattr(machine, "reboot", lambda: None, raising=False)
    with pytest.raises(LabError, match="the system did not take it"):
        checks.check_off_stays_off(machine, check_dir, lab)


def test_a_control_where_uDeck_opens_anyway_fails(lab, check_dir, monkeypatch):
    """uDeck is running after the restart, nothing reopened it and its record did not open
    it: still the failure the control is for, said with what launched it."""
    machine = a_machine([ON, OFF, OFF], running="909", log=SWITCH + NOTHING_AT_LOGIN)
    monkeypatch.setattr(machine, "reboot", lambda: None, raising=False)
    with pytest.raises(CheckFailed, match="although it had been switched off, and not by its record"):
        checks.check_off_stays_off(machine, check_dir, lab)


def test_the_record_opening_uDeck_although_switched_off_fails(lab, check_dir, monkeypatch):
    """The witness of the check above, the other way round: the launcher opened uDeck from a
    record that reads switched off."""
    machine = a_machine([ON, OFF, OFF], running="909", log=SWITCH + OPENED_AT_LOGIN)
    monkeypatch.setattr(machine, "reboot", lambda: None, raising=False)
    with pytest.raises(CheckFailed, match="although it had been switched off; the record says"):
        checks.check_off_stays_off(machine, check_dir, lab)


def test_the_control_has_to_see_the_launcher_run_to_say_it_opened_nothing(lab, check_dir, monkeypatch):
    """A log that holds no login at all says "nothing was opened" of every machine."""
    machine = a_machine([ON, OFF, OFF], running="", log=SWITCH)
    monkeypatch.setattr(machine, "reboot", lambda: None, raising=False)
    with pytest.raises(LabError, match="no `LoginItemsLauncher main` after the boot") as raised:
        checks.check_off_stays_off(machine, check_dir, lab)
    assert not isinstance(raised.value, CheckFailed)


def test_a_log_that_cannot_be_read_does_not_hide_uDeck_opening_when_it_was_off(lab, check_dir, monkeypatch):
    """The log is the control's oracle, and uDeck running after a restart it was switched
    off for is still the failure the control is for when that oracle is gone."""
    machine = a_machine([ON, OFF, OFF], running="909", log=Failed(1, "log: Could not open the store"))
    monkeypatch.setattr(machine, "reboot", lambda: None, raising=False)
    with pytest.raises(CheckFailed, match="the log could not be read"):
        checks.check_off_stays_off(machine, check_dir, lab)


def test_a_log_that_cannot_be_read_is_no_pass_for_the_control(lab, check_dir, monkeypatch):
    machine = a_machine([ON, OFF, OFF], running="", log=Failed(1, "log: Could not open the store"))
    monkeypatch.setattr(machine, "reboot", lambda: None, raising=False)
    with pytest.raises(LabError, match="could not be read") as raised:
        checks.check_off_stays_off(machine, check_dir, lab)
    assert not isinstance(raised.value, CheckFailed)


def test_a_screenshot_that_fails_does_not_hide_uDeck_opening_when_it_was_off(lab, check_dir, monkeypatch):
    """The control's own failure — uDeck opening anyway — must reach the report."""
    machine = a_machine([ON, OFF, OFF], running="909", log=SWITCH + NOTHING_AT_LOGIN)
    monkeypatch.setattr(machine, "reboot", lambda: None, raising=False)
    machine.screenshot_fails = LabError("taking a screenshot", "the machine is gone")
    machine.screenshot_fails_at = "after the restart"
    with pytest.raises(CheckFailed, match="opened at login although"):
        checks.check_off_stays_off(machine, check_dir, lab)


def test_an_unreadable_database_does_not_hide_uDeck_opening_when_it_was_off(lab, check_dir, monkeypatch):
    machine = a_machine([ON, OFF, Dropped], running="909", log=SWITCH + NOTHING_AT_LOGIN)
    monkeypatch.setattr(machine, "reboot", lambda: None, raising=False)
    with pytest.raises(CheckFailed, match="opened at login although"):
        checks.check_off_stays_off(machine, check_dir, lab)


def test_a_record_enabled_again_with_no_registration_is_not_a_verdict_about_uDeck(lab, check_dir, monkeypatch):
    """Measured twice on 2026-09-19: the restart comes back with the row enabled as it was
    *before* the switch-off — the database as it stood on disk, not uDeck registering
    again. The control's premise did not hold, so it checked nothing: the boot acted on a
    database that predates the switching off it is about. What tells it from uDeck
    registering is the log — no registration after the switch's own — where it used to
    be the generation."""
    machine = a_machine([ON, OFF, ON], running="909", log=SWITCH + OPENED_AT_LOGIN)
    monkeypatch.setattr(machine, "reboot", lambda: None, raising=False)
    with pytest.raises(LabError, match="it is enabled again") as raised:
        checks.check_off_stays_off(machine, check_dir, lab)
    assert not isinstance(raised.value, CheckFailed), "a lab failure, never a sentence about uDeck"
    assert "never acted on the switching off" in raised.value.reason


def test_a_registration_after_the_switch_is_still_uDeck_s_to_answer_for(lab, check_dir, monkeypatch):
    """The other half: something registered uDeck after the switch-off. uDeck registers only
    when asked, so that is a bug of its own and must not be explained away as the system
    restoring an old state — whatever the record and its generation say."""
    machine = a_machine([ON, OFF, ON_AGAIN], running="909", log=SWITCH + OPENED_AT_LOGIN + AGAIN)
    monkeypatch.setattr(machine, "reboot", lambda: None, raising=False)
    with pytest.raises(CheckFailed, match="registered itself again"):
        checks.check_off_stays_off(machine, check_dir, lab)


def test_a_switch_off_the_system_ignored_fails_before_the_restart(lab, check_dir, monkeypatch):
    machine = a_machine([ON, ON], running="")
    restarted = []
    monkeypatch.setattr(machine, "reboot", lambda: restarted.append(True), raising=False)
    with pytest.raises(CheckFailed, match="switched off and the system still has"):
        checks.check_off_stays_off(machine, check_dir, lab)
    assert not restarted


# --- Surviving an update ---------------------------------------------------------------


def versions(monkeypatch, *answers):
    """What `installed_version` says, in turn — the preparation reads it before the update
    and the check reads it after, and they are not the same answer."""
    seen = iter(answers)
    last = answers[-1]
    monkeypatch.setattr(app, "installed_version", lambda machine: next(seen, last))


@pytest.fixture
def update_flow(monkeypatch, tmp_path):
    """Everything about updating stubbed: this check is not the one that tests updating."""
    import udeck_e2e.updates as updates_module

    monkeypatch.setattr(updates_module, "sign", lambda *a, **k: "a-signature")
    monkeypatch.setattr(updates_module, "find_sign_update", lambda root: tmp_path / "sign_update")
    monkeypatch.setattr(updates_module.Feed, "serve", lambda self, *a: setattr(self, "serving", True))
    monkeypatch.setattr(updates_module.Feed, "stop", lambda self: None)
    monkeypatch.setattr(updates_module.Feed, "collect_log", lambda self, directory, name="feed-server.log": "")


def test_a_record_that_comes_through_an_update_passes(lab, check_dir, update_flow, monkeypatch):
    machine = a_machine([ON, ON])
    versions(monkeypatch, checks.VERSION, checks.NEWER)
    checks.check_survives_an_update(machine, check_dir, lab)


def test_a_record_the_update_took_with_it_fails(lab, check_dir, update_flow, monkeypatch):
    """What this check exists for: the record names a path, and an update replaces what is
    at that path."""
    machine = a_machine([ON, NOTHING])
    versions(monkeypatch, checks.VERSION, checks.NEWER)
    with pytest.raises(CheckFailed, match="the row that was switched on is gone"):
        checks.check_survives_an_update(machine, check_dir, lab)


def test_the_one_rewrite_an_update_makes_is_not_a_failure(lab, check_dir, update_flow, monkeypatch):
    """Measured in a guest on 2026-09-19: an update moves the generation from 1 to 2 with
    the row's UUID unchanged — macOS re-filing the record because the bundle at the path
    was replaced. A check demanding the generation stand still would call that a bug."""
    machine = a_machine([WITH_UUID, WITH_UUID.replace("Generation: 1", "Generation: 2")])
    versions(monkeypatch, checks.VERSION, checks.NEWER)
    checks.check_survives_an_update(machine, check_dir, lab)


def test_generations_an_update_racked_up_with_no_registration_are_not_a_failure(lab, check_dir, update_flow, monkeypatch):
    """The reading that failed this check 3 times in 15 on 2026-10-12: generation 1 to 4,
    and in the log three `noteUseOfItem` at uDeck's exit racing Sparkle's relaunch and no
    registration from uDeck after the switch. The generation is said, not judged."""
    machine = a_machine([ON, ON.replace("Generation: 1", "Generation: 4")], log=SWITCH)
    versions(monkeypatch, checks.VERSION, checks.NEWER)
    checks.check_survives_an_update(machine, check_dir, lab)
    assert any("evidence only" in note for note in lab.notes)


def test_a_registration_on_top_of_the_update_fails(lab, check_dir, update_flow, monkeypatch):
    """What the docstring has always promised: an application that registers itself again
    on top of the update, which is what makes macOS post "Login Item Added" at every login —
    read where macOS writes it down."""
    machine = a_machine([ON, ON_REFILED], log=SWITCH + AGAIN)
    versions(monkeypatch, checks.VERSION, checks.NEWER)
    with pytest.raises(CheckFailed, match="registered itself again"):
        checks.check_survives_an_update(machine, check_dir, lab)


def test_a_different_row_after_the_update_fails(lab, check_dir, update_flow, monkeypatch):
    machine = a_machine([WITH_UUID, ANOTHER_ROW.replace("Generation: 1", "Generation: 2")])
    versions(monkeypatch, checks.VERSION, checks.NEWER)
    with pytest.raises(CheckFailed, match="the row that was switched on is gone"):
        checks.check_survives_an_update(machine, check_dir, lab)


def test_a_record_left_pointing_elsewhere_after_the_update_fails(lab, check_dir, update_flow, monkeypatch):
    machine = a_machine([ON, ELSEWHERE])
    versions(monkeypatch, checks.VERSION, checks.NEWER)
    with pytest.raises(CheckFailed, match="the record points at"):
        checks.check_survives_an_update(machine, check_dir, lab)


def test_a_hiccup_reading_the_version_does_not_replace_the_verdict(lab, check_dir, update_flow, monkeypatch):
    """The record did not come through, and that verdict must not turn into "could not
    check" because a read nobody needed dropped its connection.

    The version is proven by the time the update has installed — `_install_the_update`
    returns on nothing else — so any read after it is redundant, and this machine answers
    the two that are needed and refuses a third.
    """
    machine = a_machine([ON, NOTHING])
    answers = iter([checks.VERSION, checks.NEWER])

    def reads(machine_):
        try:
            return next(answers)
        except StopIteration:
            raise LabError("reading the version installed", "SSH to 192.168.64.2 failed") from None

    monkeypatch.setattr(app, "installed_version", reads)
    with pytest.raises(CheckFailed, match="the row that was switched on is gone"):
        checks.check_survives_an_update(machine, check_dir, lab)


def test_an_update_that_did_not_happen_is_the_labs_problem(lab, check_dir, update_flow, monkeypatch):
    """Installing the update is a precondition here; `updates.sparkle` is the check that
    pronounces on whether uDeck can update itself at all."""
    machine = a_machine([ON, ON])
    versions(monkeypatch, checks.VERSION)
    with pytest.raises(LabError, match="was still"):
        checks.check_survives_an_update(machine, check_dir, lab)
    assert machine.now >= 240, "it is given the whole window before that is said"


def test_an_update_uDeck_never_offered_is_also_the_labs_problem(lab, check_dir, update_flow, monkeypatch):
    machine = a_machine([ON, ON])
    versions(monkeypatch, checks.VERSION, checks.NEWER)

    def never(machine_, identifier, step, window=None, seconds=None):
        if identifier == "updates.install":
            raise LabError(step, "'updates.install' did not appear")
        return ui.Element(identifier, 1, 2, 3, 4)

    monkeypatch.setattr(ui, "wait_for", never)
    with pytest.raises(LabError, match="did not offer the update"):
        checks.check_survives_an_update(machine, check_dir, lab)
