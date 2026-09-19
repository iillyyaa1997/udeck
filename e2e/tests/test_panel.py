"""The gesture's machinery: where the pointer goes, how the push is made, what uDeck said.

The numbers here are the only place the lab has to agree with uDeck about
something it cannot see — how hard a push has to be, and how long a dwell takes.
The last test in this file is that agreement, checked against uDeck's own
defaults rather than against a comment.
"""

import re
from pathlib import Path

import pytest
from fakes import Dropped, Machine

from udeck_e2e import config, panel
from udeck_e2e.errors import LabError

ATTACHED = "Timestamp               Ty Process[PID:TID]\n"
FIRED = "2026-09-18 18:20:01.123 Db uDeck[404:1a2b] [place.unicorns.udeck:gesture] fired by dwell on Built-in\n"
PUSHED = "2026-09-18 18:20:02.456 Db uDeck[404:1a2b] [place.unicorns.udeck:gesture] fired by push on Built-in\n"
IDLE = "2026-09-18 18:20:00.001 Db uDeck[404:1a2b] [place.unicorns.udeck:gesture] idle: outsideStrip\n"


# --- Reading what uDeck said ---------------------------------------------------------


def test_the_path_that_fired_is_read_from_uDecks_own_words():
    assert panel.fired_by(ATTACHED + IDLE) == []
    assert panel.fired_by(ATTACHED + IDLE + FIRED) == ["dwell"]
    assert panel.fired_by(ATTACHED + PUSHED + FIRED) == ["push", "dwell"]
    # The panel opening is not the check: which path opened it is.
    assert panel.fired_by("the panel is visible") == []


def test_the_gate_that_stopped_the_gesture_is_read_too():
    """A run that fires nothing is only worth reading if uDeck says why."""
    assert panel.idle_reasons(ATTACHED + IDLE) == ["outsideStrip"]
    assert panel.idle_reasons(IDLE + IDLE.replace("outsideStrip", "alreadyVisible")) == [
        "outsideStrip",
        "alreadyVisible",
    ]


def test_the_two_places_the_pointer_goes_are_the_two_the_gesture_is_about():
    assert panel.top_of_the_strip() == (config.SCREEN_WIDTH // 2, 0)
    assert panel.middle_of_the_screen() == (config.SCREEN_WIDTH // 2, config.SCREEN_HEIGHT // 2)
    # Far enough from the top that no setting of the strip's height reaches it.
    assert panel.middle_of_the_screen()[1] > 100


# --- The oracle ------------------------------------------------------------------------


def test_the_guest_is_asked_to_keep_uDecks_debug_messages():
    """`log show` finds nothing otherwise: the unified log keeps no debug messages."""
    machine = Machine({"log config": "Mode for 'place.unicorns.udeck'  DEBUG PERSIST_DEBUG"})
    log = panel.GestureLog(machine, note=lambda text: None)
    log.keep("keeping")
    asked = machine.ssh.commands[0]
    assert "sudo -n" in asked and "--mode 'level:debug,persist:debug'" in asked
    assert panel.SUBSYSTEM in asked
    assert log.kept


def test_a_guest_that_did_not_start_keeping_them_is_a_lab_problem():
    """A log nobody keeps answers every question with silence, and a check reading
    silence would call it "nothing fired" — which is how a check proves nothing."""
    machine = Machine({"log config": "Mode for 'place.unicorns.udeck'  DEFAULT"})
    with pytest.raises(LabError, match="not keeping uDeck's debug messages"):
        panel.GestureLog(machine, note=lambda text: None).keep("keeping")


def test_nothing_is_read_from_a_log_nobody_was_keeping():
    machine = Machine({"log show": "fired by dwell on Built-in"})
    with pytest.raises(LabError, match="proves nothing"):
        panel.GestureLog(machine, note=lambda text: None).since("2026-09-18 18:20:00", "reading")


def test_the_window_starts_at_the_guests_own_clock():
    """This Mac's clock and the guest's differ, and a window that starts a second
    late begins after the gesture it is there to catch."""
    machine = Machine({"date ": "2026-09-18 18:20:00\n", "log show": ATTACHED + FIRED})
    log = panel.GestureLog(machine, note=lambda text: None)
    log.kept = True
    when = log.mark("noting the time")
    assert when == "2026-09-18 18:20:00"
    said = log.since(when, "reading")
    shown = [c for c in machine.ssh.commands if "log show" in c][0]
    assert f"--start '{when}'" in shown and "--debug" in shown
    assert panel.fired_by(said) == ["dwell"]


def test_what_uDeck_said_is_evidence_and_never_raises(tmp_path):
    machine = Machine({"log show": Dropped})
    said = []
    log = panel.GestureLog(machine, note=said.append)
    log.kept = True
    assert log.since("2026-09-18 18:20:00", "reading") == ""
    assert any("could not be read" in note for note in said)

    kept = Machine({"log show": ATTACHED + FIRED})
    keeping = panel.GestureLog(kept, note=said.append)
    keeping.kept = True
    text = keeping.collect(tmp_path, "2026-09-18 18:20:00", "keeping")
    assert "fired by dwell" in text
    assert "fired by dwell" in (tmp_path / "gesture.log").read_text()


# --- The push ------------------------------------------------------------------------


def _default(name):
    """One of uDeck's own gesture defaults, read from its source.

    Read rather than copied: these are the only numbers the lab has to agree
    with uDeck about, and a copy here would go stale silently — too small a push
    and the panel never opens, too slow a push and it opens by the *dwell*, and
    then the check passes while proving nothing about the path it is named after.
    """
    tuning = (
        Path(panel.__file__).resolve().parents[2] / "Sources" / "UDeckCore" / "Configuration" / "GestureTuning.swift"
    ).read_text()
    found = re.search(rf"\b{name}: (?:CGFloat|TimeInterval) = ([0-9.]+)", tuning)
    assert found, f"{name} is no longer a default in GestureTuning.swift"
    return float(found.group(1))


def test_the_push_is_made_inside_the_guest_by_the_script_the_lab_ships():
    """From this Mac the pointer can only be *placed*, and a place is what a push
    at the edge has none of: it is movement, and only a device reports that."""
    machine = Machine({"push-pointer": '{"push": ["KERN_SUCCESS"]}'})
    said = panel.push_upward(machine, "pushing")
    assert machine.ssh.copied == [("push-pointer.py", panel.GUEST_PUSH)]
    ran = [c for c in machine.ssh.commands if panel.GUEST_PUSH in c][0]
    assert ran.split()[1:] == [
        panel.GUEST_PUSH,
        "0",
        str(config.THROW_DELTA),
        str(config.THROW_PAUSE_SECONDS),
        str(config.PUSH_STEPS),
        str(config.PUSH_DELTA),
        str(config.PUSH_PAUSE_SECONDS),
    ]
    assert "/usr/bin/python3" in ran, "the guest has no other Python, and needs none"
    assert "KERN_SUCCESS" in said


def test_only_the_push_at_the_edge_throws_the_pointer_there_first():
    """The control pushes where it was parked. A throw would carry it to the very
    edge, which is the one place its verdict — that nothing fires away from the
    strip — would stop being about anything."""
    parked = Machine({"push-pointer": '{"push": ["KERN_SUCCESS"]}'})
    panel.push_upward(parked, "pushing in the middle")
    thrown = Machine({"push-pointer": '{"push": ["KERN_SUCCESS"]}'})
    panel.push_upward(thrown, "pushing at the edge", throw=True)

    def steps(machine):
        return [c for c in machine.ssh.commands if panel.GUEST_PUSH in c][0].split()[2]

    assert steps(parked) == "0"
    assert steps(thrown) == str(config.THROW_STEPS)


def test_the_push_and_the_throw_the_lab_sends_are_both_upward():
    """A movement sent the other way is a downward jiggle: the pointer leaves the
    strip, and uDeck logs nothing at all."""
    assert config.PUSH_DELTA < 0
    assert config.THROW_DELTA < 0


def test_the_throw_reaches_the_edge_and_the_push_alone_never_does():
    """Two numbers that have to stay on opposite sides of the same distance.

    The throw starts in the middle of the screen and has to pin the pointer
    against the top — anything less and the check pushes in mid-air. The push on
    its own must not come close, or the control in the middle of the screen would
    carry itself into the strip and fire the dwell it exists to rule out.
    """
    to_the_edge = config.SCREEN_HEIGHT // 2
    assert config.THROW_STEPS * abs(config.THROW_DELTA) > to_the_edge
    assert config.PUSH_STEPS * abs(config.PUSH_DELTA) < to_the_edge / 4


def test_the_lab_is_not_stricter_about_being_pinned_than_uDeck_is():
    """Read back after the throw, "not at the edge" is the lab saying it could not
    check. Demanding more than uDeck does would say that about a pointer uDeck
    would happily have pushed from."""
    assert config.PINNED_TOLERANCE_PIXELS >= _default("pinnedEpsilon")


def test_the_labs_push_clears_uDecks_thresholds_and_beats_its_dwell():
    """The one place the lab has to agree with uDeck about a number it cannot see.

    Read from uDeck's own defaults rather than from a comment here, because the
    failure is silent in the worst way: too small a push and the panel never
    opens, too slow a push and it opens by the *dwell* — and then the check
    passes while proving nothing about the path it is named after.
    """
    push = config.PUSH_STEPS * abs(config.PUSH_DELTA)
    spent = config.PUSH_STEPS * config.PUSH_PAUSE_SECONDS
    assert push >= _default("edgePushDistance") * 2, "the push has to clear the threshold with room"
    assert spent <= _default("edgePushWindow") / 2, "and all of it has to land inside uDeck's window"
    assert spent < _default("dwellDuration"), "and be over before the dwell would fire instead"
