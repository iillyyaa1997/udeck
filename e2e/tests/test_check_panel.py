"""The panel checks: which path opened it, and what the control has to prove.

The question behind every test here is the one the panel makes easy to get
wrong. The panel opening is not evidence of anything on its own — two different
gestures open it, and a check that accepts either passes for the wrong reason
(Q45). So each check is asked: would it still be green if the panel opened by
the other path, and would the control still be green if uDeck were not running
at all.
"""

import importlib.util
import sys
from pathlib import Path

import pytest
from fakes import Lab, Machine

from udeck_e2e import app, config, panel
from udeck_e2e.errors import CheckFailed, LabError


def _load():
    path = Path(__file__).resolve().parents[1] / "checks" / "check_panel.py"
    spec = importlib.util.spec_from_file_location("check_panel_under_test", path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


checks = _load()

ATTACHED = "Timestamp               Ty Process[PID:TID]\n"
IDLE = "18:20:00.001 Db uDeck[404] [place.unicorns.udeck:gesture] idle: outsideStrip\n"
DWELL = "18:20:01.123 Db uDeck[404] [place.unicorns.udeck:gesture] fired by dwell on Built-in\n"
PUSH = "18:20:01.456 Db uDeck[404] [place.unicorns.udeck:gesture] fired by push on Built-in\n"


@pytest.fixture
def lab(tmp_path):
    return Lab(tmp_path)


@pytest.fixture
def check_dir(tmp_path):
    path = tmp_path / "panel.dwell"
    path.mkdir()
    return path


KEEPING = "Mode for 'place.unicorns.udeck'  DEBUG PERSIST_DEBUG"


def a_machine(log_says, running="404"):
    """A guest whose log says `log_says` and whose uDeck is running."""
    return Machine({
        "log show": log_says,
        "log config": KEEPING,
        "date ": "2026-09-18 18:20:00",
        "pgrep -x uDeck": running,
        "stat -f %Su": config.GUEST_USER,
    })  # fmt: skip


@pytest.fixture(autouse=True)
def nothing_real(monkeypatch):
    """No machine, no build, and the version on disk is the one the lab asked for."""
    monkeypatch.setattr(app, "installed_version", lambda machine: checks.VERSION)


def prepared(monkeypatch, log_says):
    """Skip the preparation — its own tests are at the end — and hand back the log."""
    machine = a_machine(log_says)

    def prepare(machine_, check_dir, lab):
        kept = panel.GestureLog(machine_, lab.note)
        kept.kept = True
        return kept

    monkeypatch.setattr(checks, "_prepare", prepare)
    return machine


# --- The dwell ------------------------------------------------------------------------


def test_the_dwell_passes_when_uDeck_says_the_dwell_fired(monkeypatch, lab, check_dir):
    machine = prepared(monkeypatch, ATTACHED + IDLE + DWELL)
    checks.check_dwell(machine, check_dir, lab)
    # Away from the strip first, then into it: the move is the whole gesture and
    # not the tail of wherever the pointer had been left.
    assert [(x, y) for x, y, _ in machine.pointer] == [panel.middle_of_the_screen(), panel.top_of_the_strip()]


def test_a_panel_that_never_opened_fails_and_says_what_uDeck_saw(monkeypatch, lab, check_dir):
    machine = prepared(monkeypatch, ATTACHED + IDLE)
    with pytest.raises(CheckFailed, match="did not open the panel") as raised:
        checks.check_dwell(machine, check_dir, lab)
    # The gate uDeck named is the first thing a person needs.
    assert "outsideStrip" in str(raised.value)
    assert machine.now >= config.GESTURE_ANSWER_SECONDS


def test_the_dwell_check_is_not_satisfied_by_a_push(monkeypatch, lab, check_dir):
    """The two paths are driven by different input; either one passing proves neither."""
    machine = prepared(monkeypatch, ATTACHED + PUSH)
    with pytest.raises(CheckFailed, match="not by the dwell"):
        checks.check_dwell(machine, check_dir, lab)


# --- The push -------------------------------------------------------------------------


def test_the_push_passes_when_uDeck_says_the_push_fired(monkeypatch, lab, check_dir):
    machine = prepared(monkeypatch, ATTACHED + PUSH)
    checks.check_push(machine, check_dir, lab)
    ran = [c for c in machine.ssh.commands if panel.GUEST_PUSH in c]
    assert ran, "the push is made inside the guest"
    x, y = panel.top_of_the_strip()
    assert f" {x} {y} " in ran[0]
    # The pointer is never *placed* at the edge from this Mac: it would dwell
    # there long before a command could push it, and the panel would open by the
    # path this check is not about.
    assert [(px, py) for px, py, _ in machine.pointer] == [panel.middle_of_the_screen()]


def test_a_push_the_lab_could_not_make_is_not_a_verdict_about_uDeck(monkeypatch, lab, check_dir):
    """Measured: no software inside a machine produces the device movement this path
    needs, so the panel opens by the dwell instead. That is the lab failing to make a
    push, not uDeck failing to answer one — "could not check", never ❌, and never a
    pass on the other path (Q45)."""
    machine = prepared(monkeypatch, ATTACHED + DWELL)
    with pytest.raises(LabError, match="could not make a push") as raised:
        checks.check_push(machine, check_dir, lab)
    assert "dwell" in raised.value.reason
    assert not isinstance(raised.value, CheckFailed)


def test_a_push_that_uDeck_never_saw_is_also_could_not_check(monkeypatch, lab, check_dir):
    machine = prepared(monkeypatch, ATTACHED)
    with pytest.raises(LabError, match="said nothing of the gesture"):
        checks.check_push(machine, check_dir, lab)


# --- The control ----------------------------------------------------------------------


def test_nothing_opens_the_panel_in_the_middle_of_the_screen(monkeypatch, lab, check_dir):
    machine = prepared(monkeypatch, ATTACHED + IDLE)
    checks.check_middle_of_the_screen(machine, check_dir, lab)
    pushed = [c for c in machine.ssh.commands if panel.GUEST_PUSH in c]
    x, y = panel.middle_of_the_screen()
    assert pushed and f" {x} {y} " in pushed[0], "held there and pushed at, so neither path is untried"
    assert machine.now >= config.NOTHING_HAPPENS_SECONDS


def test_a_panel_that_opens_in_the_middle_of_the_screen_fails(monkeypatch, lab, check_dir):
    machine = prepared(monkeypatch, ATTACHED + IDLE + DWELL)
    with pytest.raises(CheckFailed, match="opened the panel with the pointer in the middle"):
        checks.check_middle_of_the_screen(machine, check_dir, lab)


def test_the_control_proves_uDeck_was_there_to_open_anything(monkeypatch, lab, check_dir):
    """"Nothing happened" is free when nothing was running."""
    machine = prepared(monkeypatch, ATTACHED + IDLE)
    machine.ssh.answers["pgrep -x uDeck"] = ""
    with pytest.raises(LabError, match="uDeck was not running"):
        checks.check_middle_of_the_screen(machine, check_dir, lab)


def test_a_control_whose_log_says_nothing_at_all_proves_nothing(monkeypatch, lab, check_dir):
    """uDeck names the gate that stopped the gesture; silence means it never saw the pointer."""
    machine = prepared(monkeypatch, ATTACHED)
    with pytest.raises(LabError, match="says nothing at all about the pointer"):
        checks.check_middle_of_the_screen(machine, check_dir, lab)


# --- Preparing, and what is kept ---------------------------------------------------------


def a_fresh_machine():
    """A guest with no uDeck running yet, which is what a check is handed."""
    return Machine({
        "log show": ATTACHED,
        "log config": KEEPING,
        "date ": "2026-09-18 18:20:00",
        "pgrep -x uDeck": ["", "", "404"],
        "stat -f %Su": config.GUEST_USER,
    })  # fmt: skip


def test_the_guest_is_keeping_uDecks_messages_before_uDeck_is_launched(lab, check_dir):
    """uDeck says what it makes of the pointer from its first sample, and the
    control leans on those lines to show it was watching at all — so the keeping
    has to be in place before there is anything to say."""
    machine = a_fresh_machine()
    checks._prepare(machine, check_dir, lab)
    kept = next(i for i, c in enumerate(machine.ssh.commands) if "log config" in c)
    launched = next(i for i, c in enumerate(machine.ssh.commands) if "open -a" in c)
    assert kept < launched
    assert lab.builders == [(f"http://127.0.0.1:{config.FEED_PORT}", check_dir.name)] or lab.builders[0][1] == check_dir.name


def test_the_lab_installing_the_wrong_version_is_not_a_verdict_about_uDeck(monkeypatch, lab, check_dir):
    machine = a_fresh_machine()
    monkeypatch.setattr(app, "installed_version", lambda machine_: ("0.4.2", "7"))
    with pytest.raises(LabError, match="the lab installed"):
        checks._prepare(machine, check_dir, lab)


def test_what_uDeck_said_is_kept_even_when_the_check_fails(monkeypatch, lab, check_dir):
    machine = prepared(monkeypatch, ATTACHED + IDLE)
    with pytest.raises(CheckFailed):
        checks.check_dwell(machine, check_dir, lab)
    assert (check_dir / "gesture.log").read_text() == ATTACHED + IDLE
