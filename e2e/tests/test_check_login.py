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
from fakes import Lab, Machine

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


@pytest.fixture
def lab(tmp_path):
    return Lab(tmp_path)


@pytest.fixture
def check_dir(tmp_path):
    path = tmp_path / "login.registers"
    path.mkdir()
    return path


def a_machine(dumps, running="404"):
    """A guest whose login database answers `dumps` in turn."""
    return Machine({
        "sfltool dumpbtm": dumps,
        "pgrep -x uDeck": running,
        "stat -f %Su": "admin",
    })  # fmt: skip


@pytest.fixture(autouse=True)
def nothing_real(monkeypatch):
    monkeypatch.setattr(app, "installed_version", lambda machine: checks.VERSION)
    monkeypatch.setattr(app, "install", lambda machine, zip_, note: None)
    monkeypatch.setattr(app, "launch", lambda machine, step="starting uDeck": {"404"})
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
    machine = a_machine([ON, ON])
    monkeypatch.setattr(machine, "reboot", lambda: None, raising=False)
    checks.check_survives_a_restart(machine, check_dir, lab)


def test_a_machine_that_comes_back_without_uDeck_fails(lab, check_dir, monkeypatch):
    machine = a_machine([ON, ON], running="")
    monkeypatch.setattr(machine, "reboot", lambda: None, raising=False)
    with pytest.raises(CheckFailed, match="did not open"):
        checks.check_survives_a_restart(machine, check_dir, lab)
    assert machine.now >= checks.OPENS_WITHIN_SECONDS, "it is given the whole window first"


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
    machine = a_machine([ON, OFF, OFF], running="")
    monkeypatch.setattr(machine, "reboot", lambda: None, raising=False)
    checks.check_off_stays_off(machine, check_dir, lab)
    assert machine.now >= checks.NOTHING_OPENS_SECONDS, "nothing happening is only worth something after a while"


def test_the_control_switches_it_on_first(lab, check_dir, monkeypatch):
    """A machine where nothing was ever registered also comes back without uDeck, and
    proves only that the lab can watch a machine do nothing."""
    machine = a_machine([NOTHING], running="")
    monkeypatch.setattr(machine, "reboot", lambda: None, raising=False)
    with pytest.raises(LabError, match="the system did not take it"):
        checks.check_off_stays_off(machine, check_dir, lab)


def test_a_control_where_uDeck_opens_anyway_fails(lab, check_dir, monkeypatch):
    machine = a_machine([ON, OFF, OFF], running="909")
    monkeypatch.setattr(machine, "reboot", lambda: None, raising=False)
    with pytest.raises(CheckFailed, match="opened at login although it had been switched off"):
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
    with pytest.raises(CheckFailed, match="no login record at all"):
        checks.check_survives_an_update(machine, check_dir, lab)


def test_a_record_left_pointing_elsewhere_after_the_update_fails(lab, check_dir, update_flow, monkeypatch):
    machine = a_machine([ON, ELSEWHERE])
    versions(monkeypatch, checks.VERSION, checks.NEWER)
    with pytest.raises(CheckFailed, match="the record points at"):
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
