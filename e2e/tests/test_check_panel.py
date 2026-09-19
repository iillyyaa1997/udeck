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
# What uDeck says when the panel actually opens — from inside the change, and
# only when there was one. `fired by …` is written three lines earlier.
REVEAL = "18:20:01.460 Db uDeck[404] [place.unicorns.udeck:panel] collapsed -> peek on revealRequested\n"
IGNORED = "18:20:01.460 Db uDeck[404] [place.unicorns.udeck:panel] revealRequested ignored in peek\n"


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

    def prepare(machine_, check_dir, lab, launch=True):
        # `launch` is real: the control starts uDeck itself, after its window on
        # the log has opened, and a stub that swallowed the difference would let
        # that ordering rot without a test noticing.
        machine_.prepared_with_launch = launch
        kept = panel.GestureLog(machine_, lab.note)
        kept.kept = True
        return kept

    monkeypatch.setattr(checks, "_prepare", prepare)
    return machine


# --- The dwell ------------------------------------------------------------------------


def test_the_dwell_passes_when_uDeck_says_the_dwell_fired(monkeypatch, lab, check_dir):
    machine = prepared(monkeypatch, ATTACHED + IDLE + DWELL + REVEAL)
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


def at_the_edge(monkeypatch, where=(1280, 0)):
    """Where the guest says its pointer ended up after the throw."""
    monkeypatch.setattr(checks.probes, "pointer", lambda machine: where)


def pushed_with(machine):
    """The arguments the guest's push script was run with."""
    ran = [c for c in machine.ssh.commands if panel.GUEST_PUSH in c]
    assert ran, "the push is made inside the guest"
    return ran[0].split()[2:]


def test_the_push_passes_when_uDeck_says_the_push_fired(monkeypatch, lab, check_dir):
    at_the_edge(monkeypatch)
    machine = prepared(monkeypatch, ATTACHED + PUSH + REVEAL)
    checks.check_push(machine, check_dir, lab)
    # Thrown at the edge by the same movement that then pushes there.
    assert pushed_with(machine)[0] == str(config.THROW_CAP)
    # The pointer is never *placed* at the edge from this Mac: it would dwell
    # there long before a command could push it, and the panel would open by the
    # path this check is not about.
    assert [(px, py) for px, py, _ in machine.pointer] == [panel.middle_of_the_screen()]


def test_a_throw_that_left_the_pointer_short_of_the_edge_is_not_a_verdict(monkeypatch, lab, check_dir):
    """A push needs an edge to push against. Without one there is nothing to
    report about uDeck — only about the lab, which is "could not check"."""
    at_the_edge(monkeypatch, (1280, 313))
    machine = prepared(monkeypatch, ATTACHED + PUSH)
    with pytest.raises(LabError, match="not against the top edge") as raised:
        checks.check_push(machine, check_dir, lab)
    assert "313" in raised.value.reason
    assert not isinstance(raised.value, CheckFailed)


def test_the_push_check_is_not_satisfied_by_a_dwell(monkeypatch, lab, check_dir):
    """The panel opened, but by the path that only needs the pointer to be
    somewhere — which is what this check exists to tell apart."""
    at_the_edge(monkeypatch)
    machine = prepared(monkeypatch, ATTACHED + DWELL + REVEAL)
    with pytest.raises(CheckFailed, match="opened by dwell first"):
        checks.check_push(machine, check_dir, lab)


def test_a_push_that_uDeck_never_answered_fails(monkeypatch, lab, check_dir):
    """The movement was made and the pointer is pinned, so silence is uDeck's."""
    at_the_edge(monkeypatch)
    machine = prepared(monkeypatch, ATTACHED)
    with pytest.raises(CheckFailed, match="did not open the panel"):
        checks.check_push(machine, check_dir, lab)


def test_a_gesture_that_fired_and_opened_nothing_fails(monkeypatch, lab, check_dir):
    """The reason this oracle exists. uDeck writes `fired by …` at
    PanelController.swift:358 and asks the panel to appear on :361, so a panel
    that never appears — for anyone — leaves that line exactly as it is, and the
    check that rested on it alone stayed green."""
    at_the_edge(monkeypatch)
    machine = prepared(monkeypatch, ATTACHED + PUSH)
    with pytest.raises(CheckFailed, match="the panel did not open"):
        checks.check_push(machine, check_dir, lab)

    dwelt = prepared(monkeypatch, ATTACHED + IDLE + DWELL)
    with pytest.raises(CheckFailed, match="the panel did not open"):
        checks.check_dwell(dwelt, check_dir, lab)


def test_a_reveal_the_panel_refused_does_not_count_as_opening(monkeypatch, lab, check_dir):
    """uDeck logs the refusal too — `revealRequested ignored in peek` — and that
    line is not a phase changing. A parser matching "the words are there" would
    take it for one."""
    at_the_edge(monkeypatch)
    machine = prepared(monkeypatch, ATTACHED + PUSH + IGNORED)
    with pytest.raises(CheckFailed, match="the panel did not open"):
        checks.check_push(machine, check_dir, lab)


# --- The control ----------------------------------------------------------------------


def test_nothing_opens_the_panel_in_the_middle_of_the_screen(monkeypatch, lab, check_dir):
    machine = prepared(monkeypatch, ATTACHED + IDLE)
    checks.check_middle_of_the_screen(machine, check_dir, lab)
    # Held there and pushed at, so neither path is untried — and never thrown,
    # which would carry the pointer out of the middle this control is about.
    assert pushed_with(machine)[0] == "0"
    assert [(px, py) for px, py, _ in machine.pointer] == [panel.middle_of_the_screen()]
    assert machine.now >= config.NOTHING_HAPPENS_SECONDS


def test_a_panel_that_opens_in_the_middle_of_the_screen_fails(monkeypatch, lab, check_dir):
    machine = prepared(monkeypatch, ATTACHED + IDLE + DWELL + REVEAL)
    with pytest.raises(CheckFailed, match="opened the panel with the pointer in the middle"):
        checks.check_middle_of_the_screen(machine, check_dir, lab)


def test_a_panel_shown_here_by_anything_at_all_fails_the_control(monkeypatch, lab, check_dir):
    """No gesture was recognised and the panel is on screen anyway. The gesture
    line would never mention it, and a control that only reads that line would
    call this quiet."""
    machine = prepared(monkeypatch, ATTACHED + IDLE + REVEAL)
    with pytest.raises(CheckFailed, match="the panel was shown with the pointer in the middle"):
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


def test_the_control_starts_uDeck_inside_the_window_it_reads(monkeypatch, lab, check_dir):
    """The gate uDeck reports is logged only when it changes, and this control is built
    to change nothing: on 2026-09-19 it reported "could not check" twice in a row because
    the only line uDeck ever wrote — the first gate it saw — fell before the window
    began. The launch belongs after the mark, and the parking before it."""
    machine = prepared(monkeypatch, ATTACHED + IDLE)
    # One list, so the three are ordered against each other rather than each being
    # merely present. The clock cannot do it: nothing sleeps between the mark and the
    # launch, so both fall at the same second.
    order = []
    taking_the_mark = panel.GestureLog.mark
    monkeypatch.setattr(app, "launch",
                        lambda machine_, step="starting uDeck": order.append("launch") or {"404"})
    monkeypatch.setattr(panel.GestureLog, "mark",
                        lambda self, step: (order.append("mark"), taking_the_mark(self, step))[1])
    moving = machine.move_pointer
    machine.move_pointer = lambda x, y, step: order.append("park") or moving(x, y, step)

    checks.check_middle_of_the_screen(machine, check_dir, lab)

    assert machine.prepared_with_launch is False, "the preparation must not start uDeck for this control"
    # Parked, then marked, then started: the first sample uDeck takes is the one it
    # always logs, it has to fall inside the window, and it has to be taken with the
    # pointer already in the middle.
    assert order[:3] == ["park", "mark", "launch"], order
    assert "middle of the screen" in machine.pointer[0][2]
