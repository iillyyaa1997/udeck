"""The panel checks: which path opened it, what closed it, and what each must prove.

The question behind every test here is the one the panel makes easy to get
wrong. The panel opening is not evidence of anything on its own — two different
gestures open it, and a check that accepts either passes for the wrong reason
(Q45). So each check is asked: would it still be green if the panel opened by
the other path, and would the control still be green if uDeck were not running
at all.

The closing checks are asked the same question from the other end. The panel
has four ways of going away and the operator can tell them apart — he sees a
peek or the whole panel at the next reveal — so a check that accepted "it is
shut" would be green for a panel that closed because something interrupted him.
And each one is asked the question the panel exists to answer: would it still
be green if a *held* panel closed when the cursor left it.
"""

import importlib.util
import sys
from pathlib import Path

import pytest
from fakes import Dropped, Lab, Machine

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
# The panel going away, one line per way it can. Which phase it left is written
# beside what took it: the two together are what a closing check reads.
POINTER_LEFT = "18:20:09.100 Db uDeck[404] [place.unicorns.udeck:panel] peek -> collapsed on pointerLeft\n"
PROMOTED = "18:20:03.200 Db uDeck[404] [place.unicorns.udeck:panel] peek -> open on interacted\n"
DISMISSED = "18:20:12.300 Db uDeck[404] [place.unicorns.udeck:panel] open -> collapsed on closeRequested\n"
INTERRUPTED = "18:20:12.300 Db uDeck[404] [place.unicorns.udeck:panel] open -> collapsed on otherAppActivated\n"
PEEK_DISMISSED = "18:20:12.300 Db uDeck[404] [place.unicorns.udeck:panel] peek -> collapsed on closeRequested\n"
ESCAPED = (
    "18:20:12.300 Db uDeck[404] [place.unicorns.udeck:panel] peek -> collapsed on escape(isEditingText: false)\n"
)
# A panel restored whole, which is what an interrupted one comes back as.
RESTORED = "18:20:20.100 Db uDeck[404] [place.unicorns.udeck:panel] collapsed -> open on revealRequested\n"
NOTHING = ""


def growing(*steps):
    """The guest's log as a check fills it: each read sees one step more than the last.

    A closing check acts several times and reads between each, and what it reads
    is one window growing — `log show` from a single mark, handed back whole
    every time. This is that window after each action, cumulatively, which is
    what the fake guest answers one item per call.
    """
    text = ATTACHED + IDLE
    answers = []
    for step in steps:
        text += step
        answers.append(text)
    return answers


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


def test_a_log_the_check_cannot_read_is_not_a_panel_that_did_not_open(monkeypatch, lab, check_dir):
    """An empty answer and a panel that never opened are the same text. So the checks
    read the log through the oracle, which raises, and not through what is kept for the
    report — otherwise a connection that wobbled becomes a sentence about uDeck.

    Both positive checks and the control, because "nothing fired" is exactly what
    silence looks like to all three."""
    at_the_edge(monkeypatch)
    for check in (
        checks.check_push,
        checks.check_dwell,
        checks.check_middle_of_the_screen,
        checks.check_the_pointer_leaves,
        checks.check_a_click_past_the_panel,
        checks.check_escape,
    ):
        machine = prepared(monkeypatch, Dropped)
        with pytest.raises(LabError, match="SSH") as raised:
            check(machine, check_dir, lab)
        assert not isinstance(raised.value, CheckFailed), check.__name__


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


# --- The pointer leaving a peek -------------------------------------------------------


def test_a_peek_closes_when_the_pointer_is_taken_past_the_panel(monkeypatch, lab, check_dir):
    machine = prepared(monkeypatch, growing(REVEAL, POINTER_LEFT))
    checks.check_the_pointer_leaves(machine, check_dir, lab)
    # Parked, into the strip, and then past the panel — not merely out of the
    # strip, which for a panel on screen is not out of anything.
    assert [(x, y) for x, y, _ in machine.pointer] == [
        panel.middle_of_the_screen(),
        panel.top_of_the_strip(),
        panel.past_the_panel(),
    ]


def test_a_peek_that_never_closed_fails_and_waits_before_it_says_so(monkeypatch, lab, check_dir):
    machine = prepared(monkeypatch, growing(REVEAL))
    with pytest.raises(CheckFailed, match="did not close the panel"):
        checks.check_the_pointer_leaves(machine, check_dir, lab)
    assert machine.now >= config.GESTURE_ANSWER_SECONDS


def test_a_peek_that_closed_for_some_other_reason_is_not_the_pointer_leaving(monkeypatch, lab, check_dir):
    """The panel went away and the check is still wrong. `-> collapsed` alone is
    satisfied by any of the four ways it closes, and the operator can tell them
    apart, so the event has to be named."""
    machine = prepared(monkeypatch, growing(REVEAL, ESCAPED))
    with pytest.raises(CheckFailed) as raised:
        checks.check_the_pointer_leaves(machine, check_dir, lab)
    assert "('peek', 'collapsed', 'pointerLeft')" in str(raised.value)
    assert "escape" in str(raised.value)


def test_a_closing_check_that_did_not_get_a_peek_says_so_before_it_checks_anything(monkeypatch, lab, check_dir):
    """A peek and a held panel are closed by different things, so a check that
    began from whichever it happened to get would be a different check on
    different days."""
    machine = prepared(monkeypatch, growing(RESTORED, POINTER_LEFT))
    with pytest.raises(CheckFailed, match="not as a peek"):
        checks.check_the_pointer_leaves(machine, check_dir, lab)


# --- A click past the panel -----------------------------------------------------------


def test_a_held_panel_outlives_the_pointer_leaving_and_closes_on_a_click_outside(monkeypatch, lab, check_dir):
    machine = prepared(monkeypatch, growing(REVEAL, PROMOTED, NOTHING, DISMISSED, REVEAL))
    checks.check_a_click_past_the_panel(machine, check_dir, lab)
    # On the panel first, then past it, and the pointer was taken away before the
    # second click — so nothing but the click itself could have closed it.
    assert [(x, y) for x, y, _ in machine.clicks] == [panel.inside_the_peek(), panel.past_the_panel()]
    assert [(x, y) for x, y, _ in machine.pointer] == [
        panel.middle_of_the_screen(),
        panel.top_of_the_strip(),
        panel.past_the_panel(),
        panel.middle_of_the_screen(),
        panel.top_of_the_strip(),
    ]
    assert machine.now >= config.NOTHING_HAPPENS_SECONDS


def test_a_held_panel_that_closed_while_the_pointer_was_merely_away_fails(monkeypatch, lab, check_dir):
    """The one failure the whole design exists to prevent, and the reason the
    check spends ten seconds watching nothing: a panel that closes itself while
    the operator is typing into it loses what he typed, and the keystrokes after
    it go to whatever was in front before."""
    machine = prepared(monkeypatch, growing(REVEAL, PROMOTED, POINTER_LEFT, DISMISSED, REVEAL))
    with pytest.raises(CheckFailed, match="while the pointer was merely taken away"):
        checks.check_a_click_past_the_panel(machine, check_dir, lab)


def test_a_click_outside_read_as_an_interruption_fails(monkeypatch, lab, check_dir):
    """The bug this check was written for. The same click closed the panel either
    way; what changed was which of two messengers got to uDeck first, and the
    operator saw it in the panel he was handed next."""
    machine = prepared(monkeypatch, growing(REVEAL, PROMOTED, NOTHING, INTERRUPTED, RESTORED))
    with pytest.raises(CheckFailed) as raised:
        checks.check_a_click_past_the_panel(machine, check_dir, lab)
    assert "otherAppActivated" in str(raised.value)


def test_a_panel_that_comes_back_whole_after_a_click_outside_fails(monkeypatch, lab, check_dir):
    """uDeck said the right words and gave the operator the wrong panel. The
    reason is the only thing a collapse carries, and this is where he sees it."""
    machine = prepared(monkeypatch, growing(REVEAL, PROMOTED, NOTHING, DISMISSED, RESTORED))
    with pytest.raises(CheckFailed, match="not as a peek"):
        checks.check_a_click_past_the_panel(machine, check_dir, lab)


def test_the_quiet_stretch_is_witnessed_by_the_click_that_ends_it(monkeypatch, lab, check_dir):
    """"Nothing happened" is free when nothing is there, and the witness the
    control in the middle of the screen uses is not available here: uDeck names
    the gate that stopped a gesture only when the gate changes, and with the
    panel up and the pointer away nothing changes.

    So the witness is the phase uDeck names when the click finally closes it. A
    panel that had quietly dropped back to a peek during the quiet would still
    close on the click, and the stretch would have proved nothing — and this is
    what that looks like."""
    machine = prepared(monkeypatch, growing(REVEAL, PROMOTED, NOTHING, PEEK_DISMISSED, REVEAL))
    with pytest.raises(CheckFailed) as raised:
        checks.check_a_click_past_the_panel(machine, check_dir, lab)
    assert "('open', 'collapsed', 'closeRequested')" in str(raised.value)


def test_a_click_that_did_not_hold_the_panel_open_is_caught_before_anything_else(monkeypatch, lab, check_dir):
    """Everything after it is about a held panel, so a peek that stayed a peek
    has to fail here rather than three steps later as something else."""
    machine = prepared(monkeypatch, growing(REVEAL, NOTHING, NOTHING, DISMISSED, REVEAL))
    with pytest.raises(CheckFailed, match="did not hold the panel open"):
        checks.check_a_click_past_the_panel(machine, check_dir, lab)


# --- Escape ---------------------------------------------------------------------------


def test_escape_closes_the_panel_and_it_stays_closed(monkeypatch, lab, check_dir):
    machine = prepared(monkeypatch, growing(REVEAL, ESCAPED, NOTHING))
    checks.check_escape(machine, check_dir, lab)
    assert machine.keys == [("esc", "on the machine's keyboard")]
    # Out of a peek, which is what nothing having been clicked says: a peek never
    # brought uDeck forward, so no application is deactivated when it goes and
    # nothing races the keystroke to the panel (measured 2026-09-21).
    assert machine.clicks == []
    assert machine.now >= config.STAYS_SHUT_SECONDS


def test_a_panel_that_ignored_escape_fails(monkeypatch, lab, check_dir):
    machine = prepared(monkeypatch, growing(REVEAL, NOTHING))
    with pytest.raises(CheckFailed, match="Escape did not close the panel"):
        checks.check_escape(machine, check_dir, lab)


def test_a_panel_that_came_straight_back_after_escape_fails(monkeypatch, lab, check_dir):
    """Measured on 2026-09-21: three panels escaped out of `open` with the pointer
    left in the strip came back 158, 208 and 228 ms later, by the gesture that had
    opened them. A check reading only the closing line was green for all three."""
    machine = prepared(monkeypatch, growing(REVEAL, ESCAPED, REVEAL))
    with pytest.raises(CheckFailed, match="came back as"):
        checks.check_escape(machine, check_dir, lab)


def test_escape_that_closed_the_wrong_phase_is_not_this_check(monkeypatch, lab, check_dir):
    """Named after the peek as much as after the key: `open -> collapsed on
    escape` is a different sentence, and the check that makes it has to make the
    panel open first."""
    machine = prepared(monkeypatch, growing(REVEAL, ESCAPED.replace("peek ->", "open ->"), NOTHING))
    with pytest.raises(CheckFailed) as raised:
        checks.check_escape(machine, check_dir, lab)
    assert "('peek', 'collapsed', 'escape')" in str(raised.value)


# --- Reading the log in steps -----------------------------------------------------------


def a_story(machine, check_dir, lab):
    log = panel.GestureLog(machine, lab.note)
    log.kept = True
    return checks._Story(machine, log, check_dir, lab.note)


def test_the_story_opens_one_window_and_cuts_it_by_how_much_has_been_read(lab, check_dir):
    """One mark for the whole check, not one per step. The guest's clock answers
    to the second, and a window taken between two actions would sometimes begin
    inside the answer to the one before it — which is the check reading an event
    twice, or not at all."""
    machine = a_machine(growing(REVEAL, PROMOTED))
    story = a_story(machine, check_dir, lab)
    assert "collapsed -> peek" in story.take("the reveal")
    added = story.take("the click inside")
    assert added.strip() == PROMOTED.strip(), "a step sees what it added, not everything so far"
    assert len([c for c in machine.ssh.commands if "/bin/date" in c]) == 1


def test_a_step_that_added_nothing_is_kept_as_having_added_nothing(lab, check_dir):
    """The steps where uDeck says nothing are the ones a person reading a check
    about a panel that must *not* close needs to see, so they are written down
    rather than left out."""
    machine = a_machine(growing(REVEAL, NOTHING))
    story = a_story(machine, check_dir, lab)
    story.take("the reveal")
    assert story.take("the pointer away") == ""
    story.keep()
    told = (check_dir / "story.log").read_text()
    assert "=== the pointer away ===\n(nothing)" in told
    assert "collapsed -> peek" in told
    # And the whole log too, where every other check keeps it.
    assert "collapsed -> peek" in (check_dir / "gesture.log").read_text()


def test_the_story_gives_up_waiting_rather_than_deciding_anything(lab, check_dir):
    """Nothing here is ever the verdict: the check decides what an answer that
    never came means, and it has the words for it."""
    machine = a_machine(growing(REVEAL))
    story = a_story(machine, check_dir, lab)
    story.take("the reveal")
    assert story.wait_for("the closing", panel.closed_on) == ""
    assert machine.now >= config.GESTURE_ANSWER_SECONDS


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
