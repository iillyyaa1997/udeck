"""The gesture's machinery: where the pointer goes, how the push is made, what uDeck said.

The numbers here are the only place the lab has to agree with uDeck about
something it cannot see — how hard a push has to be, how long a dwell takes, and
where the panel ends so that "past it" means past it. The last two sections are
that agreement, read out of uDeck's own defaults rather than described in a
comment, because every way of getting it wrong is silent: too small a push and
the panel never opens, too slow a push and it opens by the *dwell*, and a place
that drifted inside the panel would make "the pointer left" a pointer that never
left.
"""

import re
from pathlib import Path

import pytest
from fakes import Dropped, Failed, Machine

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


PHASE = "2026-09-18 18:20:01.460 Db uDeck[404:1a2b] [place.unicorns.udeck:panel] collapsed -> peek on revealRequested\n"
SHUT_AGAIN = "2026-09-18 18:20:09.100 Db uDeck[404:1a2b] [place.unicorns.udeck:panel] peek -> collapsed on pointerLeft\n"
REFUSED = "2026-09-18 18:20:01.460 Db uDeck[404:1a2b] [place.unicorns.udeck:panel] revealRequested ignored in peek\n"


def test_whether_the_panel_opened_is_a_different_question_from_which_path_fired():
    """uDeck writes `fired by …` three lines before it asks the panel to appear,
    so the two sentences can disagree — and a check resting on the first alone
    would stay green for a panel that never opened for anybody."""
    assert panel.revealed(ATTACHED + PUSHED) == [], "firing is not opening"
    assert panel.revealed(ATTACHED + PUSHED + PHASE) == ["peek"]
    # Shutting again is a phase too, and it is not the panel opening.
    assert panel.revealed(PHASE + SHUT_AGAIN) == ["peek"]
    assert panel.phases(PHASE + SHUT_AGAIN) == [
        ("collapsed", "peek", "revealRequested"),
        ("peek", "collapsed", "pointerLeft"),
    ]


def test_a_reveal_the_panel_refused_is_not_the_panel_opening():
    """uDeck logs the refusal in the same category and with the same words in it.
    It is not a phase changing, and reading it as one would put the oracle back
    where it started."""
    assert panel.revealed(REFUSED) == []
    assert panel.phases(REFUSED) == []


def test_the_gate_that_stopped_the_gesture_is_read_too():
    """A run that fires nothing is only worth reading if uDeck says why."""
    assert panel.idle_reasons(ATTACHED + IDLE) == ["outsideStrip"]
    assert panel.idle_reasons(IDLE + IDLE.replace("outsideStrip", "alreadyVisible")) == [
        "outsideStrip",
        "alreadyVisible",
    ]


CLOSED_BY_THE_POINTER = (
    "2026-09-18 18:20:09.100 Db uDeck[404:1a2b] [place.unicorns.udeck:panel] peek -> collapsed on pointerLeft\n"
)
CLOSED_BY_A_CLICK = (
    "2026-09-18 18:20:09.100 Db uDeck[404:1a2b] [place.unicorns.udeck:panel] open -> collapsed on closeRequested\n"
)
INTERRUPTED = (
    "2026-09-18 18:20:09.100 Db uDeck[404:1a2b] [place.unicorns.udeck:panel] open -> collapsed on otherAppActivated\n"
)
ESCAPED = (
    "2026-09-18 18:20:09.100 Db uDeck[404:1a2b] [place.unicorns.udeck:panel] "
    "peek -> collapsed on escape(isEditingText: false)\n"
)


def test_what_closed_the_panel_is_read_the_way_what_opened_it_is():
    """The mirror of `revealed`, and it has to name the event and not only the fact.

    The panel has four ways of closing and the operator can tell them apart: it
    remembers which one it was, and gives him back a peek or the whole panel
    accordingly. So "it is shut" is the answer to a question no check is asking.
    """
    assert panel.closed_on(PHASE) == [], "opening is not closing"
    assert panel.closed_on(CLOSED_BY_THE_POINTER) == ["pointerLeft"]
    assert panel.closed_on(CLOSED_BY_A_CLICK) == ["closeRequested"]
    assert panel.closed_on(INTERRUPTED) == ["otherAppActivated"]
    # The event carries whether a field was being edited; the event is `escape`.
    assert panel.closed_on(ESCAPED) == ["escape"]
    assert panel.closed_on(PHASE + CLOSED_BY_THE_POINTER + PHASE) == ["pointerLeft"]
    # And a refusal is not a phase changing, here as everywhere else.
    assert panel.closed_on(REFUSED) == []


def test_the_phase_the_panel_left_is_readable_beside_what_closed_it():
    """Which phase heard the event is half of every closing check: a peek closing
    when the pointer leaves is the panel working, and a held panel doing the same
    is the one failure the whole design exists to prevent."""
    assert panel.phases(CLOSED_BY_THE_POINTER) == [("peek", "collapsed", "pointerLeft")]
    assert panel.phases(ESCAPED) == [("peek", "collapsed", "escape")]


def test_the_places_the_pointer_goes_are_the_ones_the_panel_is_about():
    assert panel.top_of_the_strip() == (config.SCREEN_WIDTH // 2, 0)
    assert panel.middle_of_the_screen() == (config.SCREEN_WIDTH // 2, config.SCREEN_HEIGHT // 2)
    # Far enough from the top that no setting of the strip's height reaches it.
    assert panel.middle_of_the_screen()[1] > 100
    for place in (panel.past_the_panel(), panel.inside_the_peek()):
        assert 0 <= place[0] < config.SCREEN_WIDTH and 0 <= place[1] < config.SCREEN_HEIGHT


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
        panel.GestureLog(machine, note=lambda text: None).read("2026-09-18 18:20:00", "reading")


def test_the_window_starts_at_the_guests_own_clock():
    """This Mac's clock and the guest's differ, and a window that starts a second
    late begins after the gesture it is there to catch."""
    machine = Machine({"date ": "2026-09-18 18:20:00\n", "log show": ATTACHED + FIRED})
    log = panel.GestureLog(machine, note=lambda text: None)
    log.kept = True
    when = log.mark("noting the time")
    assert when == "2026-09-18 18:20:00"
    said = log.read(when, "reading")
    shown = [c for c in machine.ssh.commands if "log show" in c][0]
    assert f"--start '{when}'" in shown and "--debug" in shown
    # Both categories: which path fired, and whether anything opened.
    assert f'category == "{panel.GESTURE}"' in shown and f'category == "{panel.PANEL}"' in shown
    assert panel.fired_by(said) == ["dwell"]


def test_a_log_that_cannot_be_read_is_the_labs_failure_and_not_uDecks(tmp_path):
    """The verdicts here are statements about what uDeck said, and an empty answer
    satisfies "it opened nothing" exactly as a real silence would. So the oracle
    raises rather than handing back nothing that a check would then pronounce on."""
    dropped = Machine({"log show": Dropped})
    log = panel.GestureLog(dropped, note=lambda text: None)
    log.kept = True
    with pytest.raises(LabError, match="SSH"):
        log.read("2026-09-18 18:20:00", "reading")

    # And the same for `log show` failing on its own, which `ask` lets through: it
    # answers with an exit code rather than with a dropped connection.
    refused = Machine({"log show": Failed(code=64, said="log: unrecognized predicate")})
    refused_log = panel.GestureLog(refused, note=lambda text: None)
    refused_log.kept = True
    with pytest.raises(LabError, match="would not read uDeck's log"):
        refused_log.read("2026-09-18 18:20:00", "reading")


def test_what_is_kept_for_the_report_is_evidence_and_never_raises(tmp_path):
    """The other half of the same split: what goes in the report, and into the
    sentence a failing check quotes, must not be able to change the outcome."""
    machine = Machine({"log show": Dropped})
    said = []
    log = panel.GestureLog(machine, note=said.append)
    log.kept = True
    assert log.collect(tmp_path, "2026-09-18 18:20:00", "keeping") == ""
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
        str(config.PINNED_TOLERANCE_PIXELS),
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
    assert steps(thrown) == str(config.THROW_CAP)


def test_a_kernel_that_refused_the_push_is_a_lab_failure_and_not_a_verdict():
    """The guest's script exits non-zero when the kernel refuses a report, and the
    lab runs it with `check=True`. That exit code is the whole distance between a
    machine that would not take the movement and a sentence about uDeck.

    The commonest way to earn the refusal is running it under `sudo`, which the
    script also says out loud — the privilege is the console user's, and root
    holds no console session."""
    refused = Machine({"push-pointer": Failed(
        code=1,
        said='{"uid": 0, "euid": 0, "push": ["kIOReturnNotPrivileged"], '
             '"warning": "running as root, which has no console session; the kernel refuses these"}',
    )})
    with pytest.raises(LabError, match="kIOReturnNotPrivileged"):
        panel.push_upward(refused, "pushing")


def test_the_push_and_the_throw_the_lab_sends_are_both_upward():
    """A movement sent the other way is a downward jiggle: the pointer leaves the
    strip, and uDeck logs nothing at all."""
    assert config.PUSH_DELTA < 0
    assert config.THROW_DELTA < 0


def test_the_throw_can_reach_the_edge_and_the_push_alone_never_does():
    """Two numbers that have to stay on opposite sides of the same distance.

    The throw starts in the middle of the screen and has to be able to pin the
    pointer against the top — anything less and the check pushes in mid-air. The
    push on its own must not come close, or the control in the middle of the
    screen would carry itself into the strip and fire the dwell it exists to rule
    out.
    """
    to_the_edge = config.SCREEN_HEIGHT // 2
    assert config.THROW_CAP * abs(config.THROW_DELTA) > to_the_edge
    assert config.PUSH_STEPS * abs(config.PUSH_DELTA) < to_the_edge / 4


def test_the_throw_is_a_cap_and_the_push_is_what_clears_uDecks_threshold():
    """The failure this is here to prevent is a green check that tested nothing.

    uDeck counts upward movement made while the pointer was *already* pinned. A
    throw that keeps reporting once it has arrived is therefore a push, and at the
    throw's own step size a single extra report clears the threshold twice over —
    the run says `fired by push` and the push the check actually makes never
    mattered. That is what the audit of 2026-09-19 found here.

    So the throw is bounded by the pointer, not by a count: the script stops at
    the edge. What this asserts is the part a count *could* still get wrong —
    that one report of the throw is too big to be a safe overshoot, which is why
    it must never be allowed to become one.
    """
    tuning_path = (
        Path(panel.__file__).resolve().parents[2] / "Sources" / "UDeckCore" / "Configuration" / "GestureTuning.swift"
    )
    assert tuning_path.exists()
    assert abs(config.THROW_DELTA) > _default("edgePushDistance"), (
        "one throw report already clears uDeck's push threshold, so the throw must stop at the edge "
        "rather than run to a count — see push-pointer.py"
    )
    # And the push, which is what the check is about, clears it on its own.
    assert config.PUSH_STEPS * abs(config.PUSH_DELTA) >= _default("edgePushDistance") * 2


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


# --- The two places the closing checks need -------------------------------------------
#
# Both are read against uDeck's own metrics rather than described in a comment,
# for the reason the push's numbers are: the failure is silent. A point that
# drifted inside the panel would make "the pointer left" a pointer that never
# left, and the check would go red about uDeck for something the lab did.


def _metric(name):
    """One of uDeck's own panel measurements, read from its source."""
    metrics = (
        Path(panel.__file__).resolve().parents[2] / "Sources" / "UDeckCore" / "Configuration" / "PanelMetrics.swift"
    ).read_text()
    found = re.search(rf"\b{name}: CGFloat = ([0-9.]+)", metrics)
    assert found, f"{name} is no longer a default in PanelMetrics.swift"
    return float(found.group(1))


def _biggest_panel():
    """How wide and how tall the open panel can be on the lab's screen."""
    return (
        min(config.SCREEN_WIDTH * _metric("openWidthFraction"), _metric("openMaxWidth")),
        min(config.SCREEN_HEIGHT * _metric("openHeightFraction"), _metric("openMaxHeight")),
    )


# The menu bar the panel hangs below is not measured anywhere in this repository,
# and every vertical edge here moves with it. So the numbers below allow it a
# tenth of the screen — four times what macOS has ever drawn — rather than
# pretending to know it.
GENEROUS_MENU_BAR = config.SCREEN_HEIGHT / 10


def test_the_place_past_the_panel_is_outside_the_biggest_panel_uDeck_can_draw():
    """Outside on both axes at once, which is the point of it.

    The keep-alive region is the panel's frame grown by `peekKeepAliveInset` on
    every side, and it is what uDeck measures a click and a departure against —
    not the panel's own edges. Left of it *and* below it, so that a change to the
    width or to the height alone cannot quietly bring this point back inside.
    """
    x, y = panel.past_the_panel()
    inset = _default("peekKeepAliveInset")
    width, height = _biggest_panel()
    # The panel is centred on the anchor, which is the middle of the screen's top edge.
    assert x < config.SCREEN_WIDTH / 2 - width / 2 - inset, "not clear of the panel to the left"
    assert y > GENEROUS_MENU_BAR + height + inset, "not clear of the panel below"


def test_the_middle_of_the_screen_is_inside_the_open_panel_which_is_why_there_is_a_third_place():
    """The trap this helper exists for. The middle of the screen is the lab's
    "away from the strip", and the opening checks need nothing more — but the open
    panel reaches most of the way down the screen, so a closing check that took
    the pointer there would be leaving it *on* the panel and asking why the panel
    did not notice it leave."""
    _, height = _biggest_panel()
    assert panel.middle_of_the_screen()[1] < height
    assert panel.past_the_panel() != panel.middle_of_the_screen()


def test_the_click_that_holds_the_panel_open_lands_on_the_peek_and_below_the_strip():
    """A peek draws no controls, so anywhere on it means the same thing — but it
    has to be *on* it, and below the strip: a click at the very top of the screen
    is another go at the gesture, not an interaction with the panel."""
    x, y = panel.inside_the_peek()
    peek_width = min(config.SCREEN_WIDTH * _metric("peekWidthFraction"), _metric("peekMaxWidth"))
    assert abs(x - config.SCREEN_WIDTH / 2) < peek_width / 2
    assert _default("stripHeight") < y < _metric("peekHeight")
