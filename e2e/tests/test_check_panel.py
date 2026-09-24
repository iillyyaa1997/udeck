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

And from the lab's side: would a closing check pronounce on uDeck when the lab
could not have heard it — uDeck gone, the log's window empty or shrunk, the
guest's clock behind it — or stay green on a uDeck that died, as the escape
check did.
"""

import importlib.util
import re
import sys
from pathlib import Path

import pytest
from fakes import Dropped, Failed, Lab, Machine

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
# The gate a living uDeck names after every collapse, and the one it names while a
# panel is on screen with the pointer in the strip.
GATED = "18:20:12.540 Db uDeck[404] [place.unicorns.udeck:gesture] idle: alreadyFiredThisVisit\n"
VISIBLE = "18:20:01.520 Db uDeck[404] [place.unicorns.udeck:gesture] idle: alreadyVisible\n"
# The workspace's news of a click past the panel, which the click monitor does not write.
NOTIFIED = (
    "18:20:12.300 Db uDeck[404] [place.unicorns.udeck:panel] another application came forward 6 ms after "
    "a click past the panel, so the panel counts it as closed\n"
)
LATE_NEWS = "18:20:12.310 Db uDeck[404] [place.unicorns.udeck:panel] otherAppActivated ignored in collapsed\n"


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


BEFORE_THE_PANEL = config.BEFORE_THE_PANEL_KEY
AND_AFTER_IT_CLOSED = config.BEFORE_THE_PANEL_KEY + config.AFTER_IT_CLOSED_KEY


def a_machine(log_says, running="404", in_front=None, holds=None):
    """A guest whose log says `log_says` and whose uDeck is running.

    `in_front` is what System Events names as the application in front, one
    answer per question. By default: the application a check brought forward
    before the panel, and then the Finder a click on the desktop brought forward.

    `holds` is what the document in that application says, one answer per
    question, and the default is a keyboard that behaved: the control key before
    the panel, and both keys once the panel has been put away.
    """
    return Machine({
        "log show": log_says,
        "log config": KEEPING,
        "date ": "2026-09-18 18:20:00",
        "pgrep -x uDeck": running,
        "stat -f %Su": config.GUEST_USER,
        "frontmost": in_front if in_front is not None else [config.IN_FRONT_BEFORE_THE_PANEL, config.THE_DESKTOP],
        "text area 1": holds if holds is not None else [BEFORE_THE_PANEL, AND_AFTER_IT_CLOSED],
    })  # fmt: skip


@pytest.fixture(autouse=True)
def nothing_real(monkeypatch):
    """No machine, no build, and the version on disk is the one the lab asked for."""
    monkeypatch.setattr(app, "installed_version", lambda machine: checks.VERSION)


def prepared(monkeypatch, log_says, in_front=None, holds=None, running="404"):
    """Skip the preparation — its own tests are at the end — and hand back the log."""
    machine = a_machine(log_says, running=running, in_front=in_front, holds=holds)

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
    PanelController.swift:359 and asks the panel to appear on :362, so a panel
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
        checks.check_a_switch_with_no_click,
        checks.check_a_click_past_a_restored_panel,
        checks.check_escape,
        checks.check_the_key_after_escape,
        checks.check_the_hotkey,
        checks.check_the_hotkey_again,
        checks.check_a_chord_that_is_not_the_hotkey,
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


def test_a_uDeck_that_never_started_leaves_the_control_unable_to_check(monkeypatch, lab, check_dir):
    """"Nothing happened" is free when nothing was running — and a uDeck that never
    started at all is the lab failing to set the control up, which `app.launch`
    says for itself."""
    machine = prepared(monkeypatch, ATTACHED + IDLE)
    machine.ssh.answers["pgrep -x uDeck"] = ""
    with pytest.raises(LabError, match="uDeck was not running within") as raised:
        checks.check_middle_of_the_screen(machine, check_dir, lab)
    assert not isinstance(raised.value, CheckFailed)


def test_a_uDeck_that_died_while_the_control_watched_it_fails(monkeypatch, lab, check_dir):
    """The same rule as everywhere else: it started, it was watched, and it is gone.

    The control's whole claim is that nothing happened *to a uDeck that was
    there*. A uDeck that fell over during the ten seconds satisfies the claim
    and breaks the premise, and it used to be reported as the lab having had a
    bad day.
    """
    machine = prepared(monkeypatch, ATTACHED + IDLE)
    machine.ssh.answers["pgrep -x uDeck"] = ["404", ""]
    with pytest.raises(CheckFailed, match="uDeck was not running at the end of the control"):
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
    machine = prepared(monkeypatch, growing(REVEAL, ESCAPED + GATED, NOTHING))
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


def test_a_uDeck_that_died_on_escape_fails(monkeypatch, lab, check_dir):
    """Measured on 2026-09-21: a build that exits the moment it has handled Escape
    passed this check. The closing line outlives the process in the unified log,
    and the silence after it is exactly what a panel staying shut looks like. A
    uDeck that dies on Escape is uDeck failing, not the lab."""
    machine = prepared(monkeypatch, growing(REVEAL, ESCAPED + GATED, NOTHING))
    machine.ssh.answers["pgrep -x uDeck"] = ""
    with pytest.raises(CheckFailed, match="uDeck was not running") as raised:
        checks.check_escape(machine, check_dir, lab)
    assert f"{config.STAYS_SHUT_SECONDS}s after Escape" in str(raised.value)


def test_a_uDeck_that_stopped_watching_the_pointer_after_escape_fails(monkeypatch, lab, check_dir):
    """Running is not enough: a living uDeck names the gate that holds the panel
    shut after every collapse. The gate it named *before* Escape closed the panel
    — here in the same read — says nothing about after."""
    machine = prepared(monkeypatch, growing(REVEAL, VISIBLE + ESCAPED, NOTHING))
    with pytest.raises(CheckFailed, match="said nothing about the pointer after Escape"):
        checks.check_escape(machine, check_dir, lab)


def test_the_gate_uDeck_names_after_escape_counts_wherever_the_read_was_cut(monkeypatch, lab, check_dir):
    """The read that heard Escape can already hold the gate, and the pause after
    it can hold nothing more: the proof of life is everything after the closing
    line, not only what the pause added."""
    in_the_same_read = prepared(monkeypatch, growing(REVEAL, ESCAPED + GATED, NOTHING))
    checks.check_escape(in_the_same_read, check_dir, lab)
    after_the_pause = prepared(monkeypatch, growing(REVEAL, ESCAPED, GATED))
    checks.check_escape(after_the_pause, check_dir, lab)


def test_a_panel_back_in_the_read_that_saw_escape_close_it_fails(monkeypatch, lab, check_dir):
    """The race the first version of this check lost. `log show` takes long enough
    that the read which hears Escape can already hold the panel coming back, and
    the read after the pause is then empty — green over a panel that bounced."""
    machine = prepared(monkeypatch, growing(REVEAL, ESCAPED + GATED + REVEAL, NOTHING))
    with pytest.raises(CheckFailed, match="came back as"):
        checks.check_escape(machine, check_dir, lab)


# --- Where the keyboard went once the peek was put away ------------------------------------


WITH_THE_KEY = (REVEAL, ESCAPED, NOTHING)


def test_the_key_after_escape_reaches_the_application_that_had_the_keyboard(monkeypatch, lab, check_dir):
    machine = prepared(monkeypatch, growing(*WITH_THE_KEY))
    checks.check_the_key_after_escape(machine, check_dir, lab)
    # One key before the panel, Escape, one key after — in that order, and no
    # click at all: the panel this is about is a peek, never clicked into, which
    # is the case where uDeck holds the keyboard without being in front.
    assert [name for name, _ in machine.keys] == [
        config.BEFORE_THE_PANEL_KEY,
        "esc",
        config.AFTER_IT_CLOSED_KEY,
    ]
    assert machine.clicks == []
    # The document is emptied and opened in the application before any of it.
    commands = machine.ssh.commands
    emptied = next(i for i, c in enumerate(commands) if f": > {config.THE_DOCUMENT}" in c)
    opened = next(i for i, c in enumerate(commands) if f"open -a {config.IN_FRONT_BEFORE_THE_PANEL}" in c)
    assert emptied < opened and config.THE_DOCUMENT in commands[opened]


def test_a_uDeck_that_kept_the_keyboard_after_escape_fails(monkeypatch, lab, check_dir):
    """What `panel.escape` cannot see. The panel is gone from the log and from
    the screen, and the next thing the operator types reaches nobody — which is
    what `releaseKeyboard` without its `NSApp.deactivate()` does, and what a
    hover once did in the field."""
    machine = prepared(monkeypatch, growing(*WITH_THE_KEY), holds=[BEFORE_THE_PANEL])
    with pytest.raises(CheckFailed, match="did not reach the application he was in") as raised:
        checks.check_the_key_after_escape(machine, check_dir, lab)
    assert repr(BEFORE_THE_PANEL) in str(raised.value) and repr(AND_AFTER_IT_CLOSED) in str(raised.value)


def test_a_key_that_never_arrived_before_the_panel_is_the_scene_failing(monkeypatch, lab, check_dir):
    """The control, and the reason it is here: a keystroke the lab did not manage
    to deliver leaves the document exactly as a uDeck holding on to the keyboard
    leaves it. Asked before the panel is ever shown, the difference is the lab's."""
    machine = prepared(monkeypatch, growing(*WITH_THE_KEY), holds=[""])
    with pytest.raises(LabError, match="did not reach") as raised:
        checks.check_the_key_after_escape(machine, check_dir, lab)
    assert not isinstance(raised.value, CheckFailed)
    assert machine.keys == [(config.BEFORE_THE_PANEL_KEY, "into TextEdit, before the panel was ever shown")]


def test_a_document_that_cannot_be_read_is_the_labs_failure(monkeypatch, lab, check_dir):
    """"Nothing in it" is what a refused System Events and an empty document look
    like alike, and only one of them says anything about uDeck.

    The step the failure names is the test, not the words in it: a refusal read
    as an *answer* would still trip the control a line later, with the refusal's
    own text quoted inside a sentence about a key that did not arrive — right
    outcome, wrong reason, and a document that stopped being readable half way
    through a check would then pass for a keyboard uDeck kept.
    """
    machine = prepared(
        monkeypatch,
        growing(*WITH_THE_KEY),
        holds=Failed(code=1, said="execution error: Can't get text area 1"),
    )
    with pytest.raises(LabError, match="Can't get text area 1") as raised:
        checks.check_the_key_after_escape(machine, check_dir, lab)
    assert not isinstance(raised.value, CheckFailed)
    assert raised.value.step.startswith("reading what"), raised.value.step


def test_the_key_after_escape_is_pressed_only_once_the_handback_has_had_time(monkeypatch, lab, check_dir):
    """uDeck logs the collapse and gives the keyboard back in the same
    millisecond, but the application it hands to is brought forward by the
    system, which takes its own moment. A key pressed into that moment would be
    a check about timing."""
    machine = prepared(monkeypatch, growing(*WITH_THE_KEY))
    order = []
    sleeping = machine.sleep
    machine.sleep = lambda seconds: order.append(("sleep", seconds)) or sleeping(seconds)
    pressing = machine.key
    machine.key = lambda name, step: order.append(("key", name)) or pressing(name, step)

    checks.check_the_key_after_escape(machine, check_dir, lab)

    after_escape = order[order.index(("key", "esc")) :]
    pressed = after_escape.index(("key", config.AFTER_IT_CLOSED_KEY))
    assert ("sleep", config.SETTLE_SECONDS) in after_escape[:pressed]


def test_the_key_after_escape_is_asked_of_a_peek_and_not_of_a_held_panel(monkeypatch, lab, check_dir):
    """A held panel makes uDeck frontmost, and then the handback restores and the
    question is a different one. The case this check exists for is the peek."""
    machine = prepared(monkeypatch, growing(RESTORED, ESCAPED, NOTHING))
    with pytest.raises(CheckFailed, match="not as a peek"):
        checks.check_the_key_after_escape(machine, check_dir, lab)


def test_the_key_after_escape_needs_escape_to_have_closed_the_peek(monkeypatch, lab, check_dir):
    """Whatever the document holds, the key after a panel that never closed is
    not the question — and a panel closed by something else is a different one."""
    machine = prepared(monkeypatch, growing(REVEAL, POINTER_LEFT, NOTHING))
    with pytest.raises(CheckFailed) as raised:
        checks.check_the_key_after_escape(machine, check_dir, lab)
    assert "('peek', 'collapsed', 'escape')" in str(raised.value)


# --- What every closing check asks of the read that heard it close -----------------------


def test_a_panel_back_in_the_same_read_as_its_closing_fails_every_closing_check(monkeypatch, lab, check_dir):
    """Not only Escape: the closing line has to be the end of that read's story."""
    machine = prepared(monkeypatch, growing(REVEAL, POINTER_LEFT + REVEAL))
    with pytest.raises(CheckFailed, match="in the same read"):
        checks.check_the_pointer_leaves(machine, check_dir, lab)


def test_the_expected_closing_has_to_be_the_only_one_in_its_read(monkeypatch, lab, check_dir):
    """"It closed on this, somewhere in there" is satisfied by a read that also
    holds the panel closing on something else."""
    machine = prepared(monkeypatch, growing(REVEAL, PROMOTED, NOTHING, INTERRUPTED + DISMISSED, REVEAL))
    with pytest.raises(CheckFailed, match="not once as"):
        checks.check_a_click_past_the_panel(machine, check_dir, lab)


def test_an_answer_that_never_came_from_a_uDeck_that_is_gone_is_uDecks_failure(monkeypatch, lab, check_dir):
    """One rule for a dead uDeck, and it is the rule `panel.escape` already had.

    The check started it and waited for it, so a missing process is not an
    absence — it is a uDeck that died in the middle of the thing being watched.
    It was "could not check" on every closing check but Escape, where the same
    death was red; a build that exits on a click past the panel was therefore
    reported as the lab having had a bad day. What it said before it went is
    still kept in story.log.
    """
    up_to_the_silence = [
        (checks.check_the_pointer_leaves, (REVEAL,)),
        (checks.check_a_click_past_the_panel, (REVEAL, PROMOTED, NOTHING, NOTHING)),
        (checks.check_a_switch_with_no_click, (REVEAL, PROMOTED, NOTHING)),
    ]
    for check, steps in up_to_the_silence:
        machine = prepared(monkeypatch, growing(*steps))
        machine.ssh.answers["pgrep -x uDeck"] = ""
        with pytest.raises(CheckFailed, match="uDeck was not running") as raised:
            check(machine, check_dir, lab)
        assert "died in the middle of it" in str(raised.value), check.__name__
        assert machine.now >= config.GESTURE_ANSWER_SECONDS, "and only once the wait is over"


def test_a_window_with_nothing_uDeck_said_is_not_a_verdict(monkeypatch, lab, check_dir):
    """`log show` prints its header whatever it finds. A window with nothing of
    uDeck's in it never started receiving, and that is the lab's to answer for."""
    machine = prepared(monkeypatch, ATTACHED)
    with pytest.raises(LabError, match="holds nothing uDeck said") as raised:
        checks.check_the_pointer_leaves(machine, check_dir, lab)
    assert not isinstance(raised.value, CheckFailed)


def test_a_guest_clock_that_went_back_past_the_window_is_not_a_verdict(monkeypatch, lab, check_dir):
    """The window is `log show --start <mark>` on the guest's clock. A clock stepped
    back behind the mark files everything uDeck says next before the window, and
    the closing it was waiting for never appears — through no fault of uDeck's."""
    machine = prepared(monkeypatch, growing(REVEAL))
    machine.ssh.answers["date "] = ["2026-09-18 18:20:00", "2026-09-18 18:19:50"]
    with pytest.raises(LabError, match="behind the start of the window") as raised:
        checks.check_the_pointer_leaves(machine, check_dir, lab)
    assert not isinstance(raised.value, CheckFailed)


def test_a_uDeck_that_was_there_and_heard_and_said_something_else_fails(monkeypatch, lab, check_dir):
    """The other side of the same question. Running, talking, the clock where it
    was — and still no closing: that silence is uDeck's, and it is red."""
    machine = prepared(monkeypatch, growing(REVEAL, VISIBLE))
    with pytest.raises(CheckFailed, match="did not close the panel"):
        checks.check_the_pointer_leaves(machine, check_dir, lab)


# --- Which application a click past the panel leaves in front ----------------------------


def test_the_application_from_before_the_panel_is_in_front_first_and_out_of_the_way(monkeypatch, lab, check_dir):
    """Without another application in front first, "the Finder is in front after
    the click" is also true of a uDeck that brought back whatever it had —
    because what it had was the Finder."""
    machine = prepared(monkeypatch, growing(REVEAL, PROMOTED, NOTHING, DISMISSED, REVEAL))
    checks.check_a_click_past_the_panel(machine, check_dir, lab)
    commands = machine.ssh.commands
    opened = next(i for i, c in enumerate(commands) if f"open -a {config.IN_FRONT_BEFORE_THE_PANEL}" in c)
    moved = next(i for i, c in enumerate(commands) if "set position" in c)
    first_read = next(i for i, c in enumerate(commands) if "log show" in c)
    assert opened < moved < first_read, "the scene is set before the panel is shown"
    x, y = config.OUT_OF_THE_WAY
    assert f"{{{x}, {y}}}" in commands[moved] and config.IN_FRONT_BEFORE_THE_PANEL in commands[moved]


def test_a_click_past_the_panel_that_gave_the_keyboard_back_to_the_application_from_before_fails(
    monkeypatch, lab, check_dir
):
    """Measured on 2026-09-21 before the fix: TextEdit in front before the panel,
    a click past it onto the desktop — and two seconds later TextEdit was in front
    again, pulled back over the Finder the operator had just clicked."""
    machine = prepared(
        monkeypatch,
        growing(REVEAL, PROMOTED, NOTHING, DISMISSED, REVEAL),
        in_front=[config.IN_FRONT_BEFORE_THE_PANEL, config.IN_FRONT_BEFORE_THE_PANEL],
    )
    with pytest.raises(CheckFailed, match=f"{config.IN_FRONT_BEFORE_THE_PANEL} is in front") as raised:
        checks.check_a_click_past_the_panel(machine, check_dir, lab)
    assert f"not the {config.THE_DESKTOP}" in str(raised.value)


def test_who_is_in_front_is_asked_only_once_the_handback_has_had_time(monkeypatch, lab, check_dir):
    """The application from before comes back a moment after the collapse, not in
    it. Asked straight away, the question would find the Finder in front of a
    uDeck about to pull the other one over it."""
    machine = prepared(monkeypatch, growing(REVEAL, PROMOTED, NOTHING, DISMISSED, REVEAL))
    order = []
    sleeping = machine.sleep
    machine.sleep = lambda seconds: order.append(("sleep", seconds)) or sleeping(seconds)
    clicking = machine.click
    machine.click = lambda x, y, step: order.append(("click", (x, y))) or clicking(x, y, step)
    asking = checks.probes.frontmost
    monkeypatch.setattr(checks.probes, "frontmost", lambda machine_, step: order.append(("front",)) or asking(machine_, step))

    checks.check_a_click_past_the_panel(machine, check_dir, lab)

    after_the_click = order[order.index(("click", panel.past_the_panel())) :]
    asked = after_the_click.index(("front",))
    assert ("sleep", config.SETTLE_SECONDS) in after_the_click[:asked]


def test_an_application_that_would_not_come_forward_is_the_labs_failure(monkeypatch, lab, check_dir):
    """Setting the scene is the lab's job. If the application never comes forward,
    the question about which one the click leaves in front is not asked of uDeck
    at all."""
    machine = prepared(monkeypatch, growing(REVEAL, PROMOTED, NOTHING, DISMISSED, REVEAL), in_front=[config.THE_DESKTOP])
    with pytest.raises(LabError, match=f"not {config.IN_FRONT_BEFORE_THE_PANEL}") as raised:
        checks.check_a_click_past_the_panel(machine, check_dir, lab)
    assert not isinstance(raised.value, CheckFailed)
    assert machine.now >= config.FORWARD_SECONDS
    assert machine.pointer == [] and machine.clicks == [], "and before the panel was ever shown"


# --- A switch with no click ----------------------------------------------------------------


def test_a_held_panel_interrupted_with_no_click_comes_back_whole(monkeypatch, lab, check_dir):
    machine = prepared(monkeypatch, growing(REVEAL, PROMOTED, INTERRUPTED, RESTORED))
    checks.check_a_switch_with_no_click(machine, check_dir, lab)
    # One click, and it was on the panel: the switch itself was made with none.
    assert [(x, y) for x, y, _ in machine.clicks] == [panel.inside_the_peek()]
    switched = [c for c in machine.ssh.commands if f"open -a {config.THE_DESKTOP}" in c]
    assert switched, "the Finder is brought forward over SSH, not by a click"
    # And the pointer was past the panel when it happened — where a click that
    # dismissed it would have been — so only the age of the last click tells them apart.
    assert [(x, y) for x, y, _ in machine.pointer][:3] == [
        panel.middle_of_the_screen(),
        panel.top_of_the_strip(),
        panel.past_the_panel(),
    ]


def test_a_switch_read_as_a_click_fails(monkeypatch, lab, check_dir):
    """A uDeck that took every application coming forward for a click past the
    panel: the operator's unfinished work, thrown away on ⌘-Tab."""
    machine = prepared(monkeypatch, growing(REVEAL, PROMOTED, DISMISSED, REVEAL))
    with pytest.raises(CheckFailed) as raised:
        checks.check_a_switch_with_no_click(machine, check_dir, lab)
    assert "('open', 'collapsed', 'otherAppActivated')" in str(raised.value)
    assert "closeRequested" in str(raised.value)


def test_an_interrupted_panel_that_comes_back_as_a_peek_fails(monkeypatch, lab, check_dir):
    """The right words at the collapse, and the wrong panel at the next reveal."""
    machine = prepared(monkeypatch, growing(REVEAL, PROMOTED, INTERRUPTED, REVEAL))
    with pytest.raises(CheckFailed, match="not whole"):
        checks.check_a_switch_with_no_click(machine, check_dir, lab)


def test_a_switch_that_never_closed_the_held_panel_fails(monkeypatch, lab, check_dir):
    machine = prepared(monkeypatch, growing(REVEAL, PROMOTED, VISIBLE))
    with pytest.raises(CheckFailed, match="the switch with no click did not close the panel"):
        checks.check_a_switch_with_no_click(machine, check_dir, lab)


def test_a_finder_that_never_came_forward_is_the_scene_failing_and_not_a_switch_ignored(
    monkeypatch, lab, check_dir
):
    """`open -a` that started nothing brings no application forward, so the
    workspace announces nothing and uDeck has nothing to collapse on — which
    reads exactly like a uDeck that ignored a switch it was never told about.
    The neighbouring helper has waited for its application since it was written;
    this one waited for nothing, and blamed uDeck for the difference."""
    for check in (checks.check_a_switch_with_no_click, checks.check_a_click_past_a_restored_panel):
        machine = prepared(
            monkeypatch,
            growing(REVEAL, PROMOTED, INTERRUPTED, RESTORED),
            in_front=[config.IN_FRONT_BEFORE_THE_PANEL],
        )
        with pytest.raises(LabError, match=f"not {config.THE_DESKTOP}") as raised:
            check(machine, check_dir, lab)
        assert not isinstance(raised.value, CheckFailed), check.__name__
        assert machine.now >= config.FORWARD_SECONDS, "and it waited for it first"


def test_the_switch_is_waited_for_before_uDeck_is_asked_about_it(monkeypatch, lab, check_dir):
    """The scene is settled first and the oracle read after, so that a slow
    `open -a` cannot be the reason a closing line is missing."""
    machine = prepared(monkeypatch, growing(REVEAL, PROMOTED, INTERRUPTED, RESTORED))
    checks.check_a_switch_with_no_click(machine, check_dir, lab)
    commands = machine.ssh.commands
    opened = next(i for i, c in enumerate(commands) if f"open -a {config.THE_DESKTOP}" in c)
    confirmed = next(i for i, c in enumerate(commands[opened:], opened) if "frontmost" in c)
    read_after = next(i for i, c in enumerate(commands[confirmed:], confirmed) if "log show" in c)
    assert opened < confirmed < read_after


# --- A click past a restored panel -------------------------------------------------------


RESTORED_THEN_DISMISSED = (REVEAL, PROMOTED, INTERRUPTED, RESTORED, DISMISSED, NOTHING, REVEAL)


def test_a_click_past_a_restored_panel_closes_it_by_the_monitor_alone(monkeypatch, lab, check_dir):
    machine = prepared(monkeypatch, growing(*RESTORED_THEN_DISMISSED), in_front=[config.THE_DESKTOP])
    checks.check_a_click_past_a_restored_panel(machine, check_dir, lab)
    # Clicked into once, to hold it before the switch — and never again until the
    # click past it: the restored panel is one nobody clicked into.
    assert [(x, y) for x, y, _ in machine.clicks] == [panel.inside_the_peek(), panel.past_the_panel()]


def test_a_uDeck_without_its_click_monitor_fails_rather_than_could_not_check(monkeypatch, lab, check_dir):
    """The click lands on the application already in front, so nothing else tells
    uDeck about it. A uDeck that lost its click monitor never closes the panel —
    running, talking, and silent about the click, which is uDeck's failure. The
    only check in the lab that sees it."""
    machine = prepared(monkeypatch, growing(REVEAL, PROMOTED, INTERRUPTED, RESTORED), in_front=[config.THE_DESKTOP])
    with pytest.raises(CheckFailed, match="the click past the restored panel did not close the panel"):
        checks.check_a_click_past_a_restored_panel(machine, check_dir, lab)


def test_a_click_the_workspace_also_reported_did_not_test_the_monitor(monkeypatch, lab, check_dir):
    """If an application came forward, the workspace's news could have closed the
    panel with the monitor gone — so the check could not isolate the monitor,
    and says so instead of passing."""
    steps = list(RESTORED_THEN_DISMISSED)
    steps[4] = NOTIFIED + DISMISSED
    machine = prepared(monkeypatch, growing(*steps), in_front=[config.THE_DESKTOP])
    with pytest.raises(LabError, match="monitor alone") as raised:
        checks.check_a_click_past_a_restored_panel(machine, check_dir, lab)
    assert not isinstance(raised.value, CheckFailed)


def test_news_that_arrives_after_the_monitor_won_also_means_it_was_not_alone(monkeypatch, lab, check_dir):
    """The monitor can win the race and the workspace's news still come: then a
    uDeck without its monitor would have been closed by the news, and the check
    would have been green over it."""
    steps = list(RESTORED_THEN_DISMISSED)
    steps[5] = LATE_NEWS
    machine = prepared(monkeypatch, growing(*steps), in_front=[config.THE_DESKTOP])
    with pytest.raises(LabError, match="monitor alone"):
        checks.check_a_click_past_a_restored_panel(machine, check_dir, lab)


def test_the_finder_not_in_front_of_the_restored_panel_is_the_labs_failure(monkeypatch, lab, check_dir):
    """A click on the desktop with another application in front brings the Finder
    forward, and the workspace announces it: the scene the check is about is gone.

    The Finder does come forward for the switch — otherwise the scene fails one
    step earlier, where the switch is made — and is gone again by the time the
    restored panel is up."""
    machine = prepared(
        monkeypatch,
        growing(*RESTORED_THEN_DISMISSED),
        in_front=[config.THE_DESKTOP, config.IN_FRONT_BEFORE_THE_PANEL],
    )
    with pytest.raises(LabError, match=f"{config.IN_FRONT_BEFORE_THE_PANEL} is in front, not the"):
        checks.check_a_click_past_a_restored_panel(machine, check_dir, lab)
    assert [(x, y) for x, y, _ in machine.clicks] == [panel.inside_the_peek()], "and nothing was clicked past it"


def test_a_click_past_a_restored_panel_that_moved_the_operator_fails(monkeypatch, lab, check_dir):
    """The same question `panel.a-click-past-the-panel` asks, on the other road.

    There the workspace's news of the click is what uDeck acts on; here its own
    monitor is the only messenger, and nothing asked where the operator was left
    afterwards at all. The click lands on the desktop, which is the Finder's and
    already in front, so afterwards the Finder is where he is — and a uDeck that
    pulls anything else over it has moved him somewhere he did not click.
    """
    machine = prepared(
        monkeypatch,
        growing(*RESTORED_THEN_DISMISSED),
        in_front=[config.THE_DESKTOP, config.THE_DESKTOP, config.IN_FRONT_BEFORE_THE_PANEL],
    )
    with pytest.raises(CheckFailed, match=f"{config.IN_FRONT_BEFORE_THE_PANEL} is in front") as raised:
        checks.check_a_click_past_a_restored_panel(machine, check_dir, lab)
    assert "the only messenger" in str(raised.value)


def test_who_the_restored_panel_left_in_front_is_asked_after_the_handback_has_had_time(
    monkeypatch, lab, check_dir
):
    """The application from before comes back a moment after the collapse, not in
    it — the same reason the other road waits."""
    machine = prepared(monkeypatch, growing(*RESTORED_THEN_DISMISSED), in_front=[config.THE_DESKTOP])
    order = []
    sleeping = machine.sleep
    machine.sleep = lambda seconds: order.append(("sleep", seconds)) or sleeping(seconds)
    clicking = machine.click
    machine.click = lambda x, y, step: order.append(("click", (x, y))) or clicking(x, y, step)
    asking = checks.probes.frontmost
    monkeypatch.setattr(
        checks.probes, "frontmost", lambda machine_, step: order.append(("front",)) or asking(machine_, step)
    )

    checks.check_a_click_past_a_restored_panel(machine, check_dir, lab)

    after_the_click = order[order.index(("click", panel.past_the_panel())) :]
    asked = after_the_click.index(("front",))
    assert ("sleep", config.SETTLE_SECONDS) in after_the_click[:asked]


def test_an_interrupted_panel_that_did_not_come_back_whole_is_no_restored_panel(monkeypatch, lab, check_dir):
    machine = prepared(
        monkeypatch, growing(REVEAL, PROMOTED, INTERRUPTED, REVEAL, POINTER_LEFT), in_front=[config.THE_DESKTOP]
    )
    with pytest.raises(CheckFailed, match="no restored panel to click past"):
        checks.check_a_click_past_a_restored_panel(machine, check_dir, lab)


def test_a_restored_panel_clicked_past_that_comes_back_whole_fails(monkeypatch, lab, check_dir):
    steps = list(RESTORED_THEN_DISMISSED)
    steps[6] = RESTORED
    machine = prepared(monkeypatch, growing(*steps), in_front=[config.THE_DESKTOP])
    with pytest.raises(CheckFailed, match="not as a peek"):
        checks.check_a_click_past_a_restored_panel(machine, check_dir, lab)


# --- The keyboard shortcut ---------------------------------------------------------------


REGISTERED = "18:20:00.500 Db uDeck[404] [place.unicorns.udeck:panel] hotkey ⌃⌥U registered\n"
ANOTHER_SHORTCUT = REGISTERED.replace("⌃⌥U", "⌃⌥J")
# The two lines the shortcut answers with, in the order it writes them: shown,
# and promoted to a panel that is being worked in.
OPENED_BY_THE_HOTKEY = REVEAL + PROMOTED


def through_the_shortcut():
    """What the document holds through panel.the-hotkey-again, read by read.

    The control key before the panel was ever shown, the same again after a key
    that must not have reached it, and both keys once the panel has been put
    away. A fresh list each time: the fake guest answers a list one item per
    call and takes them off it, so a shared one would be empty by the second
    test that used it.
    """
    return [BEFORE_THE_PANEL, BEFORE_THE_PANEL, AND_AFTER_IT_CLOSED]


def chords(machine):
    """The key codes the lab pressed inside the guest, in order."""
    pressed = []
    for command in machine.ssh.commands:
        found = re.search(r"key code (\d+) using", command)
        if found:
            pressed.append(int(found.group(1)))
    return pressed


def test_the_hotkey_opens_a_panel_ready_to_be_typed_into(monkeypatch, lab, check_dir):
    machine = prepared(monkeypatch, growing(REGISTERED, OPENED_BY_THE_HOTKEY))
    checks.check_the_hotkey(machine, check_dir, lab)
    # uDeck's own shortcut, pressed inside the guest and never over VNC: a chord
    # made over VNC reached uDeck not once in twelve presses and wedged the
    # guest's keyboard behind it (measured 2026-09-23).
    assert chords(machine) == [config.HOTKEY_KEY_CODE]
    assert machine.keys == []
    # And the pointer parked away from the strip before any of it, so that what
    # opened the panel was the key and not a gesture left over from before.
    assert [(x, y) for x, y, _ in machine.pointer] == [panel.middle_of_the_screen()]


def test_a_uDeck_that_never_took_the_shortcut_fails_before_it_is_pressed(monkeypatch, lab, check_dir):
    """`RegisterEventHotKey` can be refused — another application may hold the
    same combination, and the window server gives it to whoever asked first. Such
    a uDeck is silent for the chord exactly as a uDeck that ignores it is, so the
    check asks uDeck what it holds before it presses anything."""
    machine = prepared(monkeypatch, growing(NOTHING, OPENED_BY_THE_HOTKEY))
    with pytest.raises(CheckFailed, match="uDeck says it holds") as raised:
        checks.check_the_hotkey(machine, check_dir, lab)
    assert config.THE_HOTKEY in str(raised.value)
    assert chords(machine) == [], "and nothing was pressed at a uDeck that would not have heard it"
    assert machine.now >= config.GESTURE_ANSWER_SECONDS


def test_a_uDeck_holding_some_other_shortcut_fails(monkeypatch, lab, check_dir):
    """It said it registered one, and it is not the one the operator is given."""
    machine = prepared(monkeypatch, growing(ANOTHER_SHORTCUT, OPENED_BY_THE_HOTKEY))
    with pytest.raises(CheckFailed, match="uDeck says it holds"):
        checks.check_the_hotkey(machine, check_dir, lab)
    assert chords(machine) == []


def test_a_hotkey_that_opened_nothing_fails(monkeypatch, lab, check_dir):
    machine = prepared(monkeypatch, growing(REGISTERED, NOTHING))
    with pytest.raises(CheckFailed, match="did not open the panel"):
        checks.check_the_hotkey(machine, check_dir, lab)
    assert machine.now >= config.GESTURE_ANSWER_SECONDS


def test_a_hotkey_that_left_a_glance_instead_of_a_panel_fails(monkeypatch, lab, check_dir):
    """The whole reason this is not a third opening path. Someone who reached for
    the keys is not going to reach for the mouse to promote a peek, so the
    shortcut promotes it for him — and a check that accepted `collapsed -> peek`
    would be green for a shortcut that did not."""
    machine = prepared(monkeypatch, growing(REGISTERED, REVEAL))
    with pytest.raises(CheckFailed, match="moved the panel") as raised:
        checks.check_the_hotkey(machine, check_dir, lab)
    assert "('collapsed', 'peek', 'revealRequested')" in str(raised.value)
    assert "interacted" in str(raised.value)


def test_a_panel_that_moved_again_in_the_same_read_fails(monkeypatch, lab, check_dir):
    """Two lines and no more. A panel that opened and went away again in the same
    read is not a panel the operator was left with, and "both lines are in there
    somewhere" would be green over it."""
    machine = prepared(monkeypatch, growing(REGISTERED, OPENED_BY_THE_HOTKEY + DISMISSED))
    with pytest.raises(CheckFailed, match="moved the panel"):
        checks.check_the_hotkey(machine, check_dir, lab)


def how_it_started(monkeypatch, machine, run):
    """Whether the pointer was parked, the window opened and uDeck started — in that order.

    Every shortcut check does those three and in that order, for two reasons
    that meet here: `hotkey ⌃⌥U registered` is written once at launch, so a
    window opened afterwards begins after the only chance to read it; and a
    pointer left in the strip by whatever ran before opens the panel by the
    gesture, which between the launch and the mark is a reveal no check asked
    for and none of them would see.
    """
    order = []
    taking_the_mark = panel.GestureLog.mark
    monkeypatch.setattr(app, "launch",
                        lambda machine_, step="starting uDeck": order.append("launch") or {"404"})
    monkeypatch.setattr(panel.GestureLog, "mark",
                        lambda self, step: (order.append("mark"), taking_the_mark(self, step))[1])
    moving = machine.move_pointer
    machine.move_pointer = lambda x, y, step: order.append("park") or moving(x, y, step)
    run()
    return order


def test_uDeck_is_started_inside_the_window_that_reads_the_shortcut_it_holds(monkeypatch, lab, check_dir):
    """`hotkey ⌃⌥U registered` is written once, at launch. A window opened
    afterwards begins after the only chance to read it — the same ordering, and
    the same reason, as the control in the middle of the screen."""
    machine = prepared(monkeypatch, growing(REGISTERED, OPENED_BY_THE_HOTKEY))
    order = how_it_started(monkeypatch, machine, lambda: checks.check_the_hotkey(machine, check_dir, lab))

    assert machine.prepared_with_launch is False, "the preparation must not start uDeck for this check"
    assert order[:3] == ["park", "mark", "launch"], order


# --- The second press --------------------------------------------------------------------


def test_a_second_press_puts_the_panel_away_and_gives_the_keyboard_back(monkeypatch, lab, check_dir):
    machine = prepared(
        monkeypatch, growing(NOTHING, OPENED_BY_THE_HOTKEY, NOTHING, DISMISSED, NOTHING), holds=through_the_shortcut()
    )
    checks.check_the_hotkey_again(machine, check_dir, lab)
    # The same shortcut twice, and the two keys the document answers for: one
    # pressed at the open panel, which must not reach it, and one after.
    assert chords(machine) == [config.HOTKEY_KEY_CODE, config.HOTKEY_KEY_CODE]
    assert [name for name, _ in machine.keys] == [
        config.BEFORE_THE_PANEL_KEY,
        config.WHILE_THE_PANEL_IS_OPEN_KEY,
        config.AFTER_IT_CLOSED_KEY,
    ]
    assert machine.clicks == [], "nothing was clicked: this panel was opened from the keyboard"


def test_a_panel_the_second_press_left_open_fails(monkeypatch, lab, check_dir):
    """The half of the toggle that is easy to lose: `toggleFromKeyboard` asks the
    panel to close only when it is not already shut. Without that branch the
    operator cannot put away by the key what he opened with it."""
    machine = prepared(
        monkeypatch, growing(NOTHING, OPENED_BY_THE_HOTKEY, NOTHING, NOTHING, NOTHING), holds=through_the_shortcut()
    )
    with pytest.raises(CheckFailed, match="did not close the panel"):
        checks.check_the_hotkey_again(machine, check_dir, lab)


def test_a_second_press_that_closed_it_for_another_reason_fails(monkeypatch, lab, check_dir):
    """`-> collapsed` alone is satisfied by all four ways the panel goes away, and
    the operator sees the difference at the next reveal."""
    machine = prepared(
        monkeypatch, growing(NOTHING, OPENED_BY_THE_HOTKEY, NOTHING, INTERRUPTED, NOTHING), holds=through_the_shortcut()
    )
    with pytest.raises(CheckFailed) as raised:
        checks.check_the_hotkey_again(machine, check_dir, lab)
    assert "('open', 'collapsed', 'closeRequested')" in str(raised.value)


def test_a_key_that_reached_the_document_while_the_panel_was_open_fails(monkeypatch, lab, check_dir):
    """The panel the shortcut opens is one to type into, and this is the only
    question that can tell that from a panel merely on screen: uDeck names its
    first responder once per process, and a document can be read as often as one
    likes."""
    reached = [BEFORE_THE_PANEL, BEFORE_THE_PANEL + config.WHILE_THE_PANEL_IS_OPEN_KEY, AND_AFTER_IT_CLOSED]
    machine = prepared(
        monkeypatch, growing(NOTHING, OPENED_BY_THE_HOTKEY, NOTHING, DISMISSED, NOTHING), holds=reached
    )
    with pytest.raises(CheckFailed, match="reached TextEdit") as raised:
        checks.check_the_hotkey_again(machine, check_dir, lab)
    assert "does not have the keyboard" in str(raised.value)


def test_a_key_after_the_panel_was_put_away_that_reached_nobody_fails(monkeypatch, lab, check_dir):
    """The mirror of it, and the failure that matters to the operator: the panel
    is gone from the log and from the screen, and the next thing he types reaches
    nobody because uDeck kept the keyboard."""
    kept = [BEFORE_THE_PANEL, BEFORE_THE_PANEL, BEFORE_THE_PANEL]
    machine = prepared(monkeypatch, growing(NOTHING, OPENED_BY_THE_HOTKEY, NOTHING, DISMISSED, NOTHING), holds=kept)
    with pytest.raises(CheckFailed, match="did not reach the application he was in") as raised:
        checks.check_the_hotkey_again(machine, check_dir, lab)
    assert repr(AND_AFTER_IT_CLOSED) in str(raised.value)


def test_a_document_TextEdit_recapitalised_is_still_the_keys_arriving(monkeypatch, lab, check_dir):
    """The trap this check would otherwise fall into. TextEdit rewrites the text
    by itself: measured on 2026-09-23, a document holding "ay" was read back as
    "Ay" with no key pressed in between. So each key is looked for on its own and
    what is read at the end is compared without regard to case."""
    rewritten = [BEFORE_THE_PANEL, BEFORE_THE_PANEL.upper(), AND_AFTER_IT_CLOSED.capitalize()]
    machine = prepared(
        monkeypatch, growing(NOTHING, OPENED_BY_THE_HOTKEY, NOTHING, DISMISSED, NOTHING), holds=rewritten
    )
    checks.check_the_hotkey_again(machine, check_dir, lab)


def test_the_key_after_the_panel_is_pressed_only_once_the_handback_has_had_time(monkeypatch, lab, check_dir):
    """uDeck gives the keyboard back in the millisecond it logs the collapse, but
    the application it hands to is brought forward by the system, which takes its
    own moment. A key pressed into that moment would be a check about timing."""
    machine = prepared(
        monkeypatch, growing(NOTHING, OPENED_BY_THE_HOTKEY, NOTHING, DISMISSED, NOTHING), holds=through_the_shortcut()
    )
    order = []
    sleeping = machine.sleep
    machine.sleep = lambda seconds: order.append(("sleep", seconds)) or sleeping(seconds)
    pressing = machine.key
    machine.key = lambda name, step: order.append(("key", name)) or pressing(name, step)
    # The chord too, and from it the slice is taken: the key pressed at the open
    # panel is followed by a wait of its own, so a slice starting there would be
    # satisfied by that one and say nothing about the handback.
    chording = panel.press_the_chord
    monkeypatch.setattr(
        panel, "press_the_chord",
        lambda machine_, key_code, step: order.append(("chord", key_code)) or chording(machine_, key_code, step),
    )

    checks.check_the_hotkey_again(machine, check_dir, lab)

    chords_pressed = [i for i, what in enumerate(order) if what == ("chord", config.HOTKEY_KEY_CODE)]
    assert len(chords_pressed) == 2, order
    after_it_closed = order[chords_pressed[1] :]
    pressed = after_it_closed.index(("key", config.AFTER_IT_CLOSED_KEY))
    assert ("sleep", config.SETTLE_SECONDS) in after_it_closed[:pressed]


def test_a_document_that_came_back_empty_with_the_panel_open_proves_nothing(monkeypatch, lab, check_dir):
    """The positive control inside a negative reading. "The key I pressed is not
    in this text" is true of every empty string there is, and System Events hands
    an empty window back the same way it hands back a full one — `probes.typed_into`
    raises only when the question is refused. So the letter that reached the
    document before the panel was ever shown has to still be in the same read."""
    empty = [BEFORE_THE_PANEL, "", AND_AFTER_IT_CLOSED]
    machine = prepared(
        monkeypatch, growing(NOTHING, OPENED_BY_THE_HOTKEY, NOTHING, DISMISSED, NOTHING), holds=empty
    )
    with pytest.raises(CheckFailed, match="without the") as raised:
        checks.check_the_hotkey_again(machine, check_dir, lab)
    assert repr(config.BEFORE_THE_PANEL_KEY) in str(raised.value)
    assert "says nothing about where the next key went" in str(raised.value)


def test_the_second_press_parks_the_pointer_before_uDeck_starts(monkeypatch, lab, check_dir):
    """The ordering `panel.the-hotkey` has, and this check used to have the other
    way round: on a machine shared between checks (`--vm per-group`, `per-run`) a
    pointer left in the strip fires the gesture between the launch and the mark."""
    machine = prepared(
        monkeypatch, growing(NOTHING, OPENED_BY_THE_HOTKEY, NOTHING, DISMISSED, NOTHING),
        holds=through_the_shortcut(),
    )
    order = how_it_started(monkeypatch, machine, lambda: checks.check_the_hotkey_again(machine, check_dir, lab))

    assert machine.prepared_with_launch is False
    assert order[:3] == ["park", "mark", "launch"], order


# --- The shortcut at a panel it did not open -----------------------------------------------

# The gesture's peek, and then the chord: the third face of a toggle written as
# "shut, or else close", and the only one either of the two checks above can be
# green without.
CLOSED_BY_THE_HOTKEY = PEEK_DISMISSED


def test_the_hotkey_closes_a_peek_the_gesture_opened(monkeypatch, lab, check_dir):
    machine = prepared(monkeypatch, growing(REGISTERED, REVEAL, CLOSED_BY_THE_HOTKEY))
    checks.check_the_hotkey_closes_what_the_gesture_opened(machine, check_dir, lab)
    # One chord, and the panel it was pressed at was opened by the pointer: the
    # move into the strip is the only other thing this check does to the machine.
    assert chords(machine) == [config.HOTKEY_KEY_CODE]
    assert machine.keys == [], "nothing is typed here, and nothing is pressed over VNC"
    assert [(x, y) for x, y, _ in machine.pointer] == [
        panel.middle_of_the_screen(), panel.middle_of_the_screen(), panel.top_of_the_strip(),
    ]


def test_a_hotkey_that_promoted_the_peek_instead_of_closing_it_fails(monkeypatch, lab, check_dir):
    """The mutation both of the other shortcut checks stay green over. Narrow
    `toggleFromKeyboard`'s guard to the phase the shortcut itself leaves behind
    and a peek takes the other branch: `revealRequested` is ignored at a panel
    already showing, `interacted` is not, and the key the operator reached for to
    put the panel away promotes it into a working one instead."""
    machine = prepared(monkeypatch, growing(REGISTERED, REVEAL, PROMOTED))
    with pytest.raises(CheckFailed, match="did not close the panel") as raised:
        checks.check_the_hotkey_closes_what_the_gesture_opened(machine, check_dir, lab)
    assert config.THE_HOTKEY in str(raised.value)
    assert machine.now >= config.GESTURE_ANSWER_SECONDS, "and it waited for an answer before saying so"


def test_a_peek_the_hotkey_closed_for_another_reason_is_not_this_check(monkeypatch, lab, check_dir):
    """`-> collapsed` alone is satisfied by all four ways the panel goes away, and
    the pointer leaving is the one a peek does by itself."""
    machine = prepared(monkeypatch, growing(REGISTERED, REVEAL, POINTER_LEFT))
    with pytest.raises(CheckFailed) as raised:
        checks.check_the_hotkey_closes_what_the_gesture_opened(machine, check_dir, lab)
    assert "('peek', 'collapsed', 'closeRequested')" in str(raised.value)


def test_the_hotkey_at_a_gesture_panel_needs_a_peek_before_it_presses_anything(monkeypatch, lab, check_dir):
    """A peek and a held panel are closed by different things, so a check that
    took whichever panel it happened to get would be a different check on
    different days."""
    machine = prepared(monkeypatch, growing(REGISTERED, RESTORED, CLOSED_BY_THE_HOTKEY))
    with pytest.raises(CheckFailed, match="not as a peek"):
        checks.check_the_hotkey_closes_what_the_gesture_opened(machine, check_dir, lab)
    assert chords(machine) == [], "and nothing was pressed at a panel this check is not about"


def test_the_hotkey_at_a_gesture_panel_reads_the_shortcut_uDeck_holds_first(monkeypatch, lab, check_dir):
    machine = prepared(monkeypatch, growing(NOTHING, REVEAL, CLOSED_BY_THE_HOTKEY))
    with pytest.raises(CheckFailed, match="uDeck says it holds"):
        checks.check_the_hotkey_closes_what_the_gesture_opened(machine, check_dir, lab)
    assert chords(machine) == []


def test_the_hotkey_at_a_gesture_panel_parks_the_pointer_before_uDeck_starts(monkeypatch, lab, check_dir):
    machine = prepared(monkeypatch, growing(REGISTERED, REVEAL, CLOSED_BY_THE_HOTKEY))
    order = how_it_started(
        monkeypatch, machine, lambda: checks.check_the_hotkey_closes_what_the_gesture_opened(machine, check_dir, lab)
    )

    assert machine.prepared_with_launch is False
    assert order[:3] == ["park", "mark", "launch"], order


# --- A chord that is not the shortcut ------------------------------------------------------


def test_a_chord_that_is_not_the_shortcut_moves_nothing_and_the_shortcut_still_answers(
    monkeypatch, lab, check_dir
):
    machine = prepared(monkeypatch, growing(NOTHING, NOTHING, OPENED_BY_THE_HOTKEY))
    checks.check_a_chord_that_is_not_the_hotkey(machine, check_dir, lab)
    # The control first and the witness after it, both made the same way, so what
    # the silence is about is the combination and not how the lab pressed it.
    assert chords(machine) == [config.NOT_THE_HOTKEY_KEY_CODE, config.HOTKEY_KEY_CODE]
    assert machine.now >= config.NOTHING_HAPPENS_SECONDS
    assert [(x, y) for x, y, _ in machine.pointer] == [panel.middle_of_the_screen()]


def test_a_panel_that_moved_on_a_chord_uDeck_never_registered_fails(monkeypatch, lab, check_dir):
    """Every phase and not only the reveals: a chord uDeck never took must not
    open the panel, and must not close one either."""
    machine = prepared(monkeypatch, growing(NOTHING, OPENED_BY_THE_HOTKEY, OPENED_BY_THE_HOTKEY))
    with pytest.raises(CheckFailed, match=f"{config.NOT_THE_HOTKEY} moved the panel") as raised:
        checks.check_a_chord_that_is_not_the_hotkey(machine, check_dir, lab)
    assert "never registered" in str(raised.value)


def test_a_control_whose_uDeck_is_deaf_to_the_real_shortcut_proves_nothing(monkeypatch, lab, check_dir):
    """The emptiest kind of green, and what this control exists to refuse: a uDeck
    that registered nothing, or lost the combination to another application, is
    silent for *every* chord. So the real one is pressed after the silence, on the
    same machine, and has to open the panel."""
    machine = prepared(monkeypatch, growing(NOTHING, NOTHING, NOTHING))
    with pytest.raises(CheckFailed, match="did not open the panel") as raised:
        checks.check_a_chord_that_is_not_the_hotkey(machine, check_dir, lab)
    assert "listening all along" in str(raised.value)


def test_the_wrong_chord_parks_the_pointer_before_uDeck_starts(monkeypatch, lab, check_dir):
    """The stretch this control calls silent has to begin before uDeck does. A
    pointer left in the strip opens the panel by the gesture in a fraction of a
    second, and a reveal between the launch and the mark is one no read here
    would ever see."""
    machine = prepared(monkeypatch, growing(NOTHING, NOTHING, OPENED_BY_THE_HOTKEY))
    order = how_it_started(
        monkeypatch, machine, lambda: checks.check_a_chord_that_is_not_the_hotkey(machine, check_dir, lab)
    )

    assert machine.prepared_with_launch is False
    assert order[:3] == ["park", "mark", "launch"], order


# --- The combination after uDeck has gone --------------------------------------------------

# uDeck alive for the witness press and the press that puts the panel away, and
# gone by the time the chord is pressed at nobody.
GONE_AFTER_THE_PANEL_WAS_PUT_AWAY = ["404", "404", ""]


def ended_uDeck(machine):
    """Whether the lab asked the uDeck in the guest to quit."""
    return [command for command in machine.ssh.commands if 'to quit' in command]


THE_CHORD_AND_THE_LETTER_AFTER_IT = (
    BEFORE_THE_PANEL + config.THE_CHORD_IN_A_DOCUMENT + config.AFTER_IT_CLOSED_KEY
)


def through_the_combination():
    """What the document holds through panel.the-hotkey-dies-with-udeck, read by read.

    The control letter before the panel; the same again after two presses that
    uDeck took out of the keyboard, which is what holding a combination means;
    and then the chord itself and the letter after it, once nobody holds it. A
    fresh list each time, because the fake guest takes its answers off the one
    it is given.
    """
    return [BEFORE_THE_PANEL, BEFORE_THE_PANEL, THE_CHORD_AND_THE_LETTER_AFTER_IT]


def test_the_combination_dies_with_uDeck(monkeypatch, lab, check_dir):
    machine = prepared(
        monkeypatch, growing(REGISTERED, OPENED_BY_THE_HOTKEY, DISMISSED, NOTHING),
        running=list(GONE_AFTER_THE_PANEL_WAS_PUT_AWAY), holds=through_the_combination(),
    )
    checks.check_the_hotkey_dies_with_udeck(machine, check_dir, lab)
    # Three presses of the same chord: one to show it works, one to put the panel
    # away while uDeck can still hear it, and one at a machine uDeck has left.
    assert chords(machine) == [config.HOTKEY_KEY_CODE] * 3
    assert ended_uDeck(machine)
    # And the two keys the document answers for: the control before the panel,
    # and the ordinary letter after the chord nobody was there to hear — the
    # chord itself is in that document too, which is the verdict.
    assert [name for name, _ in machine.keys] == [config.BEFORE_THE_PANEL_KEY, config.AFTER_IT_CLOSED_KEY]


def test_the_shortcut_is_shown_to_work_before_uDeck_is_ended(monkeypatch, lab, check_dir):
    """"Nothing happened" is free on a lab that cannot press chords at all. The
    witness is the same chord, on the same machine, minutes earlier — so it has
    to be pressed, and answered, while uDeck is still there."""
    machine = prepared(
        monkeypatch, growing(REGISTERED, OPENED_BY_THE_HOTKEY, DISMISSED, NOTHING),
        running=list(GONE_AFTER_THE_PANEL_WAS_PUT_AWAY), holds=through_the_combination(),
    )
    checks.check_the_hotkey_dies_with_udeck(machine, check_dir, lab)

    commands = machine.ssh.commands
    quit_at = next(i for i, command in enumerate(commands) if 'to quit' in command)
    pressed = [i for i, command in enumerate(commands) if f"key code {config.HOTKEY_KEY_CODE} using" in command]
    assert len(pressed) == 3, commands
    assert pressed[1] < quit_at < pressed[2], commands


def test_a_shortcut_that_opened_nothing_while_uDeck_lived_stops_the_check(monkeypatch, lab, check_dir):
    """If the witness press proves nothing, what follows it proves nothing either,
    and uDeck is never ended: this check would otherwise read its own inability
    to press a chord as a combination that died politely."""
    machine = prepared(
        monkeypatch, growing(REGISTERED, NOTHING, NOTHING, NOTHING),
        running=list(GONE_AFTER_THE_PANEL_WAS_PUT_AWAY),
    )
    with pytest.raises(CheckFailed, match="did not open the panel"):
        checks.check_the_hotkey_dies_with_udeck(machine, check_dir, lab)
    assert ended_uDeck(machine) == [], "and uDeck was left alone, because the witness never happened"


def test_a_panel_that_moved_on_the_chord_after_uDeck_had_gone_fails(monkeypatch, lab, check_dir):
    """A phase written after the process ended is the one thing uDeck's own log
    can still say here, and it would say that something is holding the
    combination on uDeck's behalf."""
    machine = prepared(
        monkeypatch, growing(REGISTERED, OPENED_BY_THE_HOTKEY, DISMISSED, OPENED_BY_THE_HOTKEY),
        running=list(GONE_AFTER_THE_PANEL_WAS_PUT_AWAY), holds=through_the_combination(),
    )
    with pytest.raises(CheckFailed, match="the panel moved"):
        checks.check_the_hotkey_dies_with_udeck(machine, check_dir, lab)


def test_a_combination_that_outlived_uDeck_fails(monkeypatch, lab, check_dir):
    """The reading that carries this check, and it is a presence and not an
    absence. `RegisterEventHotKey` takes the combination out of the keyboard, so
    while it stands the application in front never sees the keystroke; once it is
    gone the same keystroke lands in the document. A leak leaves that document
    exactly as empty of the chord as a living uDeck leaves it."""
    still_held = [BEFORE_THE_PANEL, BEFORE_THE_PANEL, AND_AFTER_IT_CLOSED]
    machine = prepared(
        monkeypatch, growing(REGISTERED, OPENED_BY_THE_HOTKEY, DISMISSED, NOTHING),
        running=list(GONE_AFTER_THE_PANEL_WAS_PUT_AWAY), holds=still_held,
    )
    with pytest.raises(CheckFailed, match="did not go back to the keyboard") as raised:
        checks.check_the_hotkey_dies_with_udeck(machine, check_dir, lab)
    assert repr(THE_CHORD_AND_THE_LETTER_AFTER_IT) in str(raised.value)


def test_a_chord_that_ate_the_key_after_it_fails(monkeypatch, lab, check_dir):
    """The other half of the same reading. A combination that outlived uDeck is
    not only a key that opens nothing — it is a key nobody receives, and a
    modifier left down behind one takes the rest of the keyboard with it, which
    is exactly what one ⌃⌥U over VNC did to this guest (2026-09-23)."""
    ate_it = [BEFORE_THE_PANEL, BEFORE_THE_PANEL, BEFORE_THE_PANEL + config.THE_CHORD_IN_A_DOCUMENT]
    machine = prepared(
        monkeypatch, growing(REGISTERED, OPENED_BY_THE_HOTKEY, DISMISSED, NOTHING),
        running=list(GONE_AFTER_THE_PANEL_WAS_PUT_AWAY), holds=ate_it,
    )
    with pytest.raises(CheckFailed, match="did not go back to the keyboard"):
        checks.check_the_hotkey_dies_with_udeck(machine, check_dir, lab)


def test_a_chord_that_reached_the_document_while_uDeck_held_it_fails(monkeypatch, lab, check_dir):
    """The half read while uDeck is still there, and without it the other half
    says nothing: a machine where the chord reaches the document either way
    cannot tell a combination uDeck has from one nobody has."""
    leaked_through = [
        BEFORE_THE_PANEL,
        BEFORE_THE_PANEL + config.THE_CHORD_IN_A_DOCUMENT,
        THE_CHORD_AND_THE_LETTER_AFTER_IT,
    ]
    machine = prepared(
        monkeypatch, growing(REGISTERED, OPENED_BY_THE_HOTKEY, DISMISSED, NOTHING),
        running=list(GONE_AFTER_THE_PANEL_WAS_PUT_AWAY), holds=leaked_through,
    )
    with pytest.raises(CheckFailed, match="cannot tell a combination uDeck has"):
        checks.check_the_hotkey_dies_with_udeck(machine, check_dir, lab)
    assert ended_uDeck(machine) == [], "and uDeck was left alone, because the scene was already wrong"


def test_a_uDeck_that_would_not_end_is_the_scene_failing(monkeypatch, lab, check_dir):
    """A uDeck still running is not a combination outliving it — there is nothing
    to ask this question of yet — so it is the lab failing to set the scene and
    not a verdict."""
    machine = prepared(
        monkeypatch, growing(REGISTERED, OPENED_BY_THE_HOTKEY, DISMISSED, NOTHING),
        running="404", holds=through_the_combination(),
    )
    with pytest.raises(LabError, match="still running"):
        checks.check_the_hotkey_dies_with_udeck(machine, check_dir, lab)


def test_the_combination_check_parks_the_pointer_before_uDeck_starts(monkeypatch, lab, check_dir):
    machine = prepared(
        monkeypatch, growing(REGISTERED, OPENED_BY_THE_HOTKEY, DISMISSED, NOTHING),
        running=list(GONE_AFTER_THE_PANEL_WAS_PUT_AWAY), holds=through_the_combination(),
    )
    order = how_it_started(
        monkeypatch, machine, lambda: checks.check_the_hotkey_dies_with_udeck(machine, check_dir, lab)
    )

    assert machine.prepared_with_launch is False
    assert order[:3] == ["park", "mark", "launch"], order


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


def test_a_log_that_got_shorter_is_the_labs_failure_and_not_a_quiet_step(lab, check_dir):
    """Counting lines is exact only while the window grows. A read shorter than
    what was already read would hand every later step an empty slice — and an
    empty slice is what "the held panel stayed open" and "the panel stayed shut"
    look like."""
    whole = growing(REVEAL, PROMOTED)[-1]
    machine = a_machine([whole, ATTACHED + IDLE])
    story = a_story(machine, check_dir, lab)
    story.take("the reveal and the click")
    with pytest.raises(LabError, match="got shorter") as raised:
        story.take("the pointer away")
    assert not isinstance(raised.value, CheckFailed)


def test_a_log_that_got_shorter_while_a_step_was_waiting_stops_the_wait(lab, check_dir):
    """Not ten seconds later, as a slice that never became ready: at once."""
    whole = growing(REVEAL, PROMOTED)[-1]
    machine = a_machine([whole, ATTACHED])
    story = a_story(machine, check_dir, lab)
    story.take("the reveal and the click")
    with pytest.raises(LabError, match="got shorter"):
        story.wait_for("the closing", panel.closed_on)
    assert machine.now < config.GESTURE_ANSWER_SECONDS


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
