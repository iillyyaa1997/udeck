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

import json
import math
import re
from pathlib import Path

import pytest
from fakes import Dropped, Failed, Machine, throw_output, wobble_output

from udeck_e2e import config, panel, probes
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
    assert panel.top_of_the_strip() == (config.SCREEN_WIDTH // 2, config.INSIDE_THE_STRIP_Y)
    assert panel.middle_of_the_screen() == (config.SCREEN_WIDTH // 2, config.SCREEN_HEIGHT // 2)
    # Far enough from the top that no setting of the strip's height reaches it.
    assert panel.middle_of_the_screen()[1] > 100


def test_what_uDeck_said_after_the_panel_closed_starts_at_the_closing_line():
    """A stretch that has to stay quiet starts where the panel closed, and the read
    that heard it close may hold lines from before it too."""
    gate_before = IDLE.replace("outsideStrip", "alreadyVisible")
    gate_after = IDLE.replace("outsideStrip", "alreadyFiredThisVisit")
    assert panel.after_it_closed(gate_before + ESCAPED + gate_after).strip() == gate_after.strip()
    assert panel.idle_reasons(panel.after_it_closed(gate_before + ESCAPED)) == []
    # Never closed: nothing after it.
    assert panel.after_it_closed(gate_before + PHASE) == ""
    # From the first closing on, the later ones included.
    assert panel.closed_on(panel.after_it_closed(ESCAPED + PHASE + SHUT_AGAIN)) == ["pointerLeft"]


def test_what_uDeck_said_is_told_apart_from_what_log_show_prints_around_it():
    """`log show` prints its header whatever it finds, so a window holding nothing of
    uDeck's is not an empty string — and must not count as uDeck having spoken."""
    assert panel.said_by_uDeck(ATTACHED) == []
    assert panel.said_by_uDeck(ATTACHED + IDLE) == [IDLE.strip()]


NOTIFIED = (
    "2026-09-18 18:20:09.090 Db uDeck[404:1a2b] [place.unicorns.udeck:panel] another application came forward "
    "6 ms after a click past the panel, so the panel counts it as closed\n"
)
SWITCH_NOTED = (
    "2026-09-18 18:20:09.090 Db uDeck[404:1a2b] [place.unicorns.udeck:panel] another application came forward "
    "1212 ms after the last click, with the pointer past the panel, so the panel counts it as a switch\n"
)
LATE = "2026-09-18 18:20:09.110 Db uDeck[404:1a2b] [place.unicorns.udeck:panel] otherAppActivated ignored in collapsed\n"


def test_news_of_another_application_is_every_line_the_workspace_brought():
    """The click monitor writes nothing of its own, so a click past the panel was
    heard by the monitor alone exactly when none of these is there: the news read
    as a click, read as a switch, arriving too late to matter, or closing the panel."""
    assert panel.news_of_another_application(CLOSED_BY_A_CLICK) == []
    assert panel.news_of_another_application(IDLE + PHASE + CLOSED_BY_THE_POINTER) == []
    for line in (NOTIFIED, SWITCH_NOTED, LATE, INTERRUPTED):
        assert panel.news_of_another_application(CLOSED_BY_A_CLICK + line) == [line.strip()], line


# --- The oracle ------------------------------------------------------------------------


# One record as `log show --style ndjson` printed it in a guest (.build/e2e/20260929-120510Z,
# logprobe.reads), trimmed to the fields the lab reads and a few it does not, and the
# line `--style compact` printed for the same record.
RECORD = {
    "timezoneName": "", "messageType": "Debug", "eventType": "logEvent", "formatString": "idle: %{public}s",
    "subsystem": "place.unicorns.udeck", "category": "gesture", "threadID": 7592,
    "processImagePath": "/Applications/uDeck.app/Contents/MacOS/uDeck", "timestamp": "2026-09-29 12:09:40.943740+0000",
    "machTimestamp": 6435470946, "eventMessage": "idle: alreadyVisible", "traceID": 10620182846374404,
    "processID": 943,
}  # fmt: skip
RECORD_AS_COMPACT = "2026-09-29 12:09:40.943 Db uDeck[943:1da8] [place.unicorns.udeck:gesture] idle: alreadyVisible"


def ndjson(*records):
    return "\n".join(json.dumps(record) for record in records) + '\n{"count": %d, "finished": 1}\n' % len(records)


def test_a_record_reads_as_compact_printed_it():
    assert panel.as_compact(ndjson(RECORD)).splitlines() == [panel.COMPACT_HEADER, RECORD_AS_COMPACT]


def test_a_record_the_store_answered_twice_is_read_once():
    """.build/e2e/20260929-080845Z: every line of a read doubled, the same record twice;
    the same window read later held each once. One peek must not read as two."""
    later = {**RECORD, "machTimestamp": RECORD["machTimestamp"] + 5000, "eventMessage": "collapsed -> peek on revealRequested",
             "category": "panel"}  # fmt: skip
    said = panel.as_compact(ndjson(RECORD, RECORD, later, later))
    assert said == panel.as_compact(ndjson(RECORD, later))
    assert panel.revealed(said) == ["peek"]


def test_two_alike_messages_on_their_own_ticks_are_two_events():
    """Words, thread and millisecond alike, and still two: only the clock's own tick says it is one record."""
    again = {**RECORD, "machTimestamp": RECORD["machTimestamp"] + 1}
    other_thread = {**RECORD, "threadID": RECORD["threadID"] + 1}
    lines = panel.as_compact(ndjson(RECORD, again, other_thread)).splitlines()[1:]
    assert lines == [RECORD_AS_COMPACT, RECORD_AS_COMPACT, RECORD_AS_COMPACT.replace(":1da8]", ":1da9]")]


def test_an_answer_that_is_not_records_is_the_lab_unable_to_read_its_log():
    for broken in ("Timestamp  Ty Process[PID:TID]\n", "[1, 2]\n", json.dumps({"eventMessage": "x"}) + "\n"):
        with pytest.raises(ValueError):
            panel.as_compact(broken)
    machine = Machine({"log show": "not json at all"})
    log = panel.GestureLog(machine, note=lambda text: None)
    log.kept = True
    with pytest.raises(LabError, match="not a record"):
        log.read("2026-09-18 18:20:00", "reading")
    assert "--style ndjson" in [c for c in machine.ssh.commands if "log show" in c][0]


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


def test_the_window_holds_the_category_uDeck_says_it_could_not_save_in():
    """`could not save the settings: …` is written through `DeckLog.plugins`, not
    the panel's own logger, so a window on two categories cannot see it — and a
    check reading that window cannot tell a uDeck that could not save the
    operator's change from one that never tried."""
    machine = Machine({"date ": "2026-09-18 18:20:00", "log show": ATTACHED})
    log = panel.GestureLog(machine, note=lambda text: None)
    log.kept = True
    log.read(log.mark("noting the time"), "reading")
    shown = [c for c in machine.ssh.commands if "log show" in c][0]
    for name in panel.CATEGORIES:
        assert f'category == "{name}"' in shown
    assert panel.PLUGINS in panel.CATEGORIES


def test_what_uDeck_says_when_the_store_refuses_it_is_read_out_of_that_window():
    """The line itself, as `DeckModel.save` writes it. Its absence is an answer
    too: a check that read it as "uDeck could not save" from silence would be
    blaming a full disk for a control wired to nothing."""
    refused = (
        "2026-09-18 18:20:00.001 Db uDeck[404:1a2b] [place.unicorns.udeck:plugins] could not save the settings: "
        'Error Domain=NSCocoaErrorDomain Code=513 "You don’t have permission"'
    )
    assert panel.could_not_save(ATTACHED + refused + "\n") == [refused]
    assert panel.could_not_save(ATTACHED + FIRED) == []
    # The same sentence is written about the layout and the plugin settings, and
    # neither is the operator's settings file.
    layout = refused.replace("could not save the settings", "could not save the layout")
    assert panel.could_not_save(ATTACHED + layout) == []


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
        # Nothing sideways and no wobble: the push goes straight up, as it did
        # before the wobble existed.
        "0",
        "0",
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


def test_the_dwell_is_made_inside_the_strip_and_short_of_pinned():
    """Where `panel.top_of_the_strip()` puts the pointer, read against uDeck's own numbers.

    Rows from the top of the 1× screen. uDeck's strip is closed at the top and
    `stripHeight` tall, so rows 0 to `stripHeight` are in it, the last one on its
    lower edge; the pointer is pinned within `pinnedEpsilon` of the row macOS
    clamps it to, one below the top, so rows 0 to `pinnedEpsilon + 1` are pinned.
    Strictly between the two, a pointer is in the strip and cannot push — and the
    VNC jump to a pinned row was sometimes read as a push, which is why the dwell
    stopped going to the top row (2026-09-21).
    """
    y = panel.top_of_the_strip()[1]
    assert y > _default("pinnedEpsilon") + 1, "pinned: the jump there can be read as a push"
    assert y < _default("stripHeight"), "on or past the strip's lower edge: the dwell may never start"


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


# --- Upward movement that never reaches the edge ---------------------------------------
#
# The wobble is the one movement the lab makes inside the strip that is not a
# place: rocking between two rows while sliding along it. Every number it rests
# on is one of uDeck's, and each way of getting one wrong is silent in the same
# way the push's are — a band that strayed into the pinned rows makes a push of
# what was meant not to be one, and a wobble too slow or too small makes "not a
# push" of a movement no build would ever have counted.


def _strip_edges():
    """uDeck's strip across the lab's screen, from its own defaults: [left, right)."""
    half = _default("virtualAnchorWidth") / 2 + _default("stripSideMargin")
    return config.SCREEN_WIDTH / 2 - half, config.SCREEN_WIDTH / 2 + half


def test_the_strip_the_lab_reads_the_wobble_against_is_uDecks():
    """Whole columns inside uDeck's strip, which is closed on the left and open on
    the right (`PanelGeometry.containsPointer`)."""
    left, right = _strip_edges()
    first, last = config.STRIP_COLUMNS
    assert first == math.ceil(left) and first - 1 < left
    assert last < right <= last + 1


def test_the_push_threshold_the_lab_reads_the_wobble_against_is_uDecks():
    assert config.EDGE_PUSH_DISTANCE == _default("edgePushDistance")
    assert config.EDGE_PUSH_WINDOW_SECONDS == _default("edgePushWindow")


def test_the_wobble_short_of_the_edge_rocks_inside_the_strip_and_never_pinned():
    """Rows from the top, as for `INSIDE_THE_STRIP_Y`: rows 0 to `stripHeight` are in
    the strip, rows 0 to `pinnedEpsilon + 1` are pinned. Both rows of the band are
    strictly between — otherwise the check is about a pointer that was pinned, or
    one that had left the strip."""
    upper, lower = config.SHORT_OF_THE_EDGE_ROWS
    assert upper > _default("pinnedEpsilon") + 1, "the upper row is pinned: the rocking there is a real push"
    assert lower <= _default("stripHeight"), "the lower row is out of the strip: every rock ends the visit"
    assert upper < lower


def test_the_same_wobble_at_the_edge_is_pinned_in_every_row():
    """Pinned by uDeck's measure and by the lab's own, which is the stricter one."""
    upper, lower = config.AT_THE_EDGE_ROWS
    assert upper == 0
    assert lower <= _default("pinnedEpsilon") + 1
    assert lower <= config.PINNED_TOLERANCE_PIXELS


def test_the_two_wobbles_are_one_movement_in_two_places():
    """The pair means something only if the rows are the one thing that differs."""
    short = config.SHORT_OF_THE_EDGE_ROWS[1] - config.SHORT_OF_THE_EDGE_ROWS[0]
    edge = config.AT_THE_EDGE_ROWS[1] - config.AT_THE_EDGE_ROWS[0]
    assert short == edge
    assert config.WOBBLE_DELTA == -short, "each report goes up, or back down, by the whole band"


def test_the_wobble_starts_outside_the_strip_and_comes_to_rest_inside_it():
    """Outside, because a pointer placed in the strip from this Mac opens the panel
    by the dwell before any command reaches the guest; inside at the end, because
    that is where the dwell that is the verdict has to fire."""
    first, last = config.STRIP_COLUMNS
    assert config.WOBBLE_START_X < first
    assert first <= config.WOBBLE_START_X + config.WOBBLE_STEPS * config.WOBBLE_SIDEWAYS <= last


def test_the_wobble_slides_fast_enough_to_hold_the_dwell_off():
    """uDeck restarts the dwell when the pointer slides at `dwellHorizontalSpeedLimit`
    or has slid `dwellHorizontalTolerance` since the last restart. The first, at the
    nominal pace, with room; and the second even at twice the nominal pace, which is
    slower than the wobble was measured at — so the dwell cannot fire mid-wobble on
    either rule."""
    speed = config.WOBBLE_SIDEWAYS / config.WOBBLE_PAUSE_SECONDS
    assert speed >= 2 * _default("dwellHorizontalSpeedLimit")
    reports_per_restart = math.ceil(_default("dwellHorizontalTolerance") / config.WOBBLE_SIDEWAYS)
    assert reports_per_restart * 2 * config.WOBBLE_PAUSE_SECONDS < _default("dwellDuration")


def test_the_wobble_carries_what_the_check_demands_of_it_at_its_own_pace():
    """Read with the lab's own reading of a track, on the track the lab's numbers
    make at their nominal pace: a wobble the lab sends must not be one its own
    check then refuses as too small to have been a push."""
    wobble = panel.Wobble(wobble_output(config.SHORT_OF_THE_EDGE_ROWS), config.SHORT_OF_THE_EDGE_ROWS, "reading")
    assert wobble.upward_in_the_strip() >= config.WOBBLE_MARGIN * _default("edgePushDistance")
    wobble.expect_it_could_have_been_a_push()


def test_the_wobble_is_sent_as_a_rocking_slide_from_left_of_the_strip():
    machine = Machine({"push-pointer": wobble_output(config.SHORT_OF_THE_EDGE_ROWS)})
    panel.wobble_along_the_strip(machine, "wobbling", config.SHORT_OF_THE_EDGE_ROWS)
    # Placed on the lower row of the band, left of the strip.
    assert [(x, y) for x, y, _ in machine.pointer] == [(config.WOBBLE_START_X, config.SHORT_OF_THE_EDGE_ROWS[1])]
    ran = [c for c in machine.ssh.commands if panel.GUEST_PUSH in c][0]
    assert ran.split()[2:] == [
        "0",
        str(config.THROW_DELTA),
        str(config.THROW_PAUSE_SECONDS),
        str(config.PINNED_TOLERANCE_PIXELS),
        str(config.WOBBLE_STEPS),
        str(config.WOBBLE_DELTA),
        str(config.WOBBLE_PAUSE_SECONDS),
        str(config.WOBBLE_SIDEWAYS),
        "1",
    ]


def _track(*points):
    """A track by hand: `(x, row, seconds)` per report."""
    return json.dumps({"track": [list(point) for point in points]})


IN = config.STRIP_COLUMNS[0]
OUT = config.STRIP_COLUMNS[0] - 1


def test_upward_travel_is_counted_only_between_two_readings_inside_the_strip():
    """The report that carries the pointer in from outside is not counted: uDeck's
    visit begins there, and what it summed before is forgotten when the pointer
    leaves."""
    rows = config.SHORT_OF_THE_EDGE_ROWS
    wobble = panel.Wobble(_track((OUT, 6, 0.0), (IN, 4, 0.01), (IN + 1, 6, 0.02), (IN + 2, 4, 0.03)), rows, "r")
    assert wobble.upward_in_the_strip() == 2
    # Down is not up.
    assert panel.Wobble(_track((IN, 4, 0.0), (IN + 1, 6, 0.01)), rows, "r").upward_in_the_strip() == 0


def test_upward_travel_is_counted_within_one_of_uDecks_push_windows():
    """The window slides the way uDeck's does: an entry exactly one window old is in it."""
    rows = config.SHORT_OF_THE_EDGE_ROWS
    window = config.EDGE_PUSH_WINDOW_SECONDS
    # Times a binary fraction can hold exactly: with 0.1 and 0.35 the difference
    # comes out a hair under the window, and the boundary is never tested at all.
    first, later = 0.25, 1 / 64
    exactly = panel.Wobble(_track((IN, 6, 0.0), (IN, 4, first), (IN, 6, 0.375), (IN, 4, first + window)), rows, "r")
    assert exactly.upward_in_the_strip() == 4
    beyond = panel.Wobble(
        _track((IN, 6, 0.0), (IN, 4, first), (IN, 6, 0.375), (IN, 4, first + window + later)), rows, "r"
    )
    assert beyond.upward_in_the_strip() == 2


def test_a_wobble_that_left_its_rows_is_the_labs_failure():
    """Above the band short of the edge is a pinned row, and rocking there is a real
    push; the verdict would then be about something else."""
    track = wobble_output(config.SHORT_OF_THE_EDGE_ROWS).replace(", 4, ", ", 3, ", 1)
    wobble = panel.Wobble(track, config.SHORT_OF_THE_EDGE_ROWS, "wobbling")
    with pytest.raises(LabError, match=r"reached rows \[3\]"):
        wobble.expect_it_stayed_in_its_rows()
    # And below the band at the edge is past what the lab itself calls pinned.
    below = wobble_output(config.AT_THE_EDGE_ROWS).replace(", 2, ", ", 3, ", 1)
    with pytest.raises(LabError, match=r"reached rows \[3\]"):
        panel.Wobble(below, config.AT_THE_EDGE_ROWS, "wobbling").expect_it_stayed_in_its_rows()


def test_a_wobble_that_stopped_outside_the_strip_is_the_labs_failure():
    """The reveal is owed only where the pointer comes to rest in the strip."""
    track = wobble_output(config.SHORT_OF_THE_EDGE_ROWS, start_x=config.STRIP_COLUMNS[1])
    wobble = panel.Wobble(track, config.SHORT_OF_THE_EDGE_ROWS, "wobbling")
    with pytest.raises(LabError, match="outside the strip"):
        wobble.expect_it_came_to_rest_in_the_strip()


def test_a_wobble_too_slow_to_have_been_a_push_is_the_labs_failure():
    """Not being counted proves nothing about a movement that could not have been.
    The same wobble at a tenth of the pace carries too little inside one window."""
    slow = panel.Wobble(
        wobble_output(config.SHORT_OF_THE_EDGE_ROWS, pace=config.WOBBLE_PAUSE_SECONDS * 10),
        config.SHORT_OF_THE_EDGE_ROWS,
        "wobbling",
    )
    with pytest.raises(LabError, match="could not have been a push"):
        slow.expect_it_could_have_been_a_push()
    # And the same for a pointer that never moved up at all — what a machine that
    # ate every report would leave.
    still = panel.Wobble(
        _track(*[(IN + n, 6, n * 0.002) for n in range(100)]), config.SHORT_OF_THE_EDGE_ROWS, "wobbling"
    )
    with pytest.raises(LabError, match="could not have been a push"):
        still.expect_it_could_have_been_a_push()


def test_the_margin_is_the_threshold_times_what_uDeck_may_discount():
    """Exactly `WOBBLE_MARGIN` times uDeck's threshold is enough, and a point less is
    not: the lab asks for the margin and nothing more."""
    rows = config.SHORT_OF_THE_EDGE_ROWS
    needed = int(config.WOBBLE_MARGIN * config.EDGE_PUSH_DISTANCE)
    rises = needed // 2
    enough = [(IN, 6, 0.0)] + [(IN, 4 if n % 2 == 0 else 6, 0.001 * (n + 1)) for n in range(2 * rises)]
    panel.Wobble(_track(*enough), rows, "r").expect_it_could_have_been_a_push()
    short = enough[:-2]
    with pytest.raises(LabError, match="could not have been a push"):
        panel.Wobble(_track(*short), rows, "r").expect_it_could_have_been_a_push()


def test_the_wobble_the_lab_asks_for_is_the_movement_asked_for():
    """The other side of the refusals: the track the lab's own numbers make passes
    all three questions, in both places."""
    for rows in (config.SHORT_OF_THE_EDGE_ROWS, config.AT_THE_EDGE_ROWS):
        wobble = panel.Wobble(wobble_output(rows), rows, "wobbling")
        wobble.expect_it_stayed_in_its_rows()
        wobble.expect_it_came_to_rest_in_the_strip()
        wobble.expect_it_could_have_been_a_push()


def test_the_wobble_is_asked_where_it_went_before_anyone_asks_uDeck():
    """Rows and rest are the lab's questions about its own movement, and they are
    answered where the movement is made — a check cannot forget them."""
    strayed = Machine({"push-pointer": wobble_output(config.SHORT_OF_THE_EDGE_ROWS).replace(", 4, ", ", 3, ", 1)})
    with pytest.raises(LabError, match="reached rows"):
        panel.wobble_along_the_strip(strayed, "wobbling", config.SHORT_OF_THE_EDGE_ROWS)
    away = Machine({"push-pointer": wobble_output(config.SHORT_OF_THE_EDGE_ROWS, start_x=config.STRIP_COLUMNS[1])})
    with pytest.raises(LabError, match="outside the strip"):
        panel.wobble_along_the_strip(away, "wobbling", config.SHORT_OF_THE_EDGE_ROWS)


def test_what_the_guest_printed_is_read_or_refused():
    """A script that printed nothing readable leaves the path unknown, and the path
    is the measurement."""
    for said in ("", "Traceback (most recent call last):", '{"push": ["KERN_SUCCESS"]}'):
        with pytest.raises(LabError, match="cannot read"):
            panel.Wobble(said, config.SHORT_OF_THE_EDGE_ROWS, "wobbling")
    empty = panel.Wobble('{"track": []}', config.SHORT_OF_THE_EDGE_ROWS, "wobbling")
    with pytest.raises(LabError, match="no position"):
        empty.expect_it_stayed_in_its_rows()


# --- The throw on its own --------------------------------------------------------------


def test_the_throw_on_its_own_is_the_push_checks_throw_with_nothing_after_it():
    """The same script, the same throw, and `steps` 0: the movement that arrives, and no more."""
    machine = Machine({"push-pointer": throw_output()})
    thrown = panel.throw_to_the_edge(machine, "throwing")
    ran = [c for c in machine.ssh.commands if panel.GUEST_PUSH in c][0].split()[2:]
    assert ran[:4] == [
        str(config.THROW_CAP), str(config.THROW_DELTA), str(config.THROW_PAUSE_SECONDS),
        str(config.PINNED_TOLERANCE_PIXELS),
    ]  # fmt: skip
    assert ran[4] == "0"
    assert thrown.began == (1280, 720) and thrown.at == (1280, 0) and thrown.thrown == 12


def test_the_throw_on_its_own_is_the_push_checks_throw_and_the_arrival_is_a_push_if_counted():
    """Only the report that arrives lands in the strip, so nothing before it can start a dwell,
    and that one report is well over uDeck's push threshold even at the half a point per unit
    uDeck may read it at — the one report a uDeck counting arrivals would count."""
    alone = Machine({"push-pointer": throw_output()})
    panel.throw_to_the_edge(alone, "throwing")
    pushed = Machine({"push-pointer": '{"push": ["KERN_SUCCESS"]}'})
    panel.push_upward(pushed, "pushing at the edge", throw=True)

    def throw(machine):
        return [c for c in machine.ssh.commands if panel.GUEST_PUSH in c][0].split()[2:6]

    assert throw(alone) == throw(pushed)
    assert abs(config.THROW_DELTA) > _default("stripHeight")
    assert abs(config.THROW_DELTA) >= config.WOBBLE_MARGIN * _default("edgePushDistance")


def test_the_reports_a_throw_needs_are_counted_from_where_it_began():
    """Each report moves the pointer its own size, so the count that reaches the edge is known:
    from the middle of the screen twelve of sixty, and a thirteenth would be made against it."""
    assert panel.Throw(throw_output(), "t").needed() == 12
    assert panel.Throw(throw_output(began=(1280.0, 722.0)), "t").needed() == 12
    assert panel.Throw(throw_output(began=(1280.0, 723.0), thrown=13), "t").needed() == 13
    assert panel.Throw(throw_output(began=(1280.0, 1.0), thrown=0), "t").needed() == 0


def test_a_throw_that_went_one_report_past_the_edge_is_the_labs_failure():
    with pytest.raises(LabError, match="1 of them were made against it"):
        panel.Throw(throw_output(thrown=13), "t").expect_it_stopped_there()
    panel.Throw(throw_output(thrown=12), "t").expect_it_stopped_there()


def test_a_throw_short_of_the_edge_is_the_labs_failure():
    for said in (
        throw_output(thrown=30, at=(1280.0, 313.0), pinned=False),
        throw_output(at=(1280.0, config.PINNED_TOLERANCE_PIXELS + 1.0)),
        throw_output(at=None, pinned=False),
    ):
        with pytest.raises(LabError, match="not against the top edge"):
            panel.Throw(said, "t").expect_it_reached_the_edge()
    panel.Throw(throw_output(at=(1280.0, config.PINNED_TOLERANCE_PIXELS)), "t").expect_it_reached_the_edge()


def test_a_throw_that_does_not_say_where_it_began_cannot_be_held_to_its_count():
    with pytest.raises(LabError, match="did not say where the pointer began"):
        panel.Throw(throw_output(began=None), "t").expect_it_stopped_there()


def test_the_throw_is_asked_where_it_went_before_anyone_asks_uDeck():
    for said, reason in ((throw_output(thrown=13), "made against it"),
                         (throw_output(pinned=False, at=(1280.0, 60.0)), "not against the top edge")):
        with pytest.raises(LabError, match=reason):
            panel.throw_to_the_edge(Machine({"push-pointer": said}), "throwing")
    for said in ("", "Traceback (most recent call last):", '{"push": ["KERN_SUCCESS"]}'):
        with pytest.raises(LabError, match="cannot read"):
            panel.Throw(said, "throwing")


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


# The menu bar the panel hangs below was measured once, 30 points in the macOS 27
# guest (the two panels measured there agree on it, see `config.PAST_THE_PANEL`),
# but not on every guest, and every vertical edge here moves with it. So the
# numbers below allow it a tenth of the screen — four times what macOS has ever
# drawn — rather than pretending to know it everywhere.
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


def test_both_places_the_closing_checks_use_are_on_the_screen():
    """The other bound on them, and the one the tests around it do not give.

    Each point is held against uDeck's own panel above and below — past it, on
    it — and both of those are satisfied by a point far off the right-hand edge
    of the screen, which is nowhere at all. `Machine._refuse_off_screen` catches
    that, but only at the moment a check moves the pointer there: inside a
    booted guest, minutes into a run, as "could not check" — the outcome that
    says nothing happened and nothing was learnt. Here it is one line and a
    second of pytest, before a machine is ever started.
    """
    for place in (
        panel.past_the_panel(), panel.inside_the_peek(), config.IN_THE_MARGIN,
        config.THE_FIRST_TAB, config.RENAME_IN_THE_TABS_MENU,
    ):
        x, y = place
        assert 0 <= x < config.SCREEN_WIDTH, f"{place} is off the side of the screen"
        assert 0 <= y < config.SCREEN_HEIGHT, f"{place} is off the bottom of the screen"


# The menu bar the open panel's content hangs below, as measured in the macOS 27
# guest (see `config.PAST_THE_PANEL`). The margin below the panel is only 24 points
# deep, so this one test cannot afford `GENEROUS_MENU_BAR`: it is held to the guest
# the lab runs, and says so.
MEASURED_MENU_BAR = 30


def test_the_click_in_the_margin_is_below_the_open_panel_and_inside_what_keeps_it():
    """Not on the panel — a click there is uDeck's own and reaches the other
    monitor — and not past the region either, where a click closes the panel.
    The one place a click is outside uDeck and forgiven."""
    x, y = config.IN_THE_MARGIN
    inset = _default("peekKeepAliveInset")
    width, height = _biggest_panel()
    assert abs(x - config.SCREEN_WIDTH / 2) < width / 2, "not under the panel across"
    assert MEASURED_MENU_BAR + height < y, "on the panel, not below it"
    assert y < MEASURED_MENU_BAR + height + inset, "past the region that keeps the panel, not in its margin"


def test_the_middle_of_the_screen_is_inside_the_open_panel_which_is_why_there_is_a_third_place():
    """The trap this helper exists for. The middle of the screen is the lab's
    "away from the strip", and the opening checks need nothing more — but the open
    panel reaches most of the way down the screen, so a closing check that took
    the pointer there would be leaving it *on* the panel and asking why the panel
    did not notice it leave."""
    _, height = _biggest_panel()
    assert panel.middle_of_the_screen()[1] < height


def test_the_click_that_holds_the_panel_open_lands_on_the_peek_and_below_the_strip():
    """A peek draws no controls, so anywhere on it means the same thing — but it
    has to be *on* it, and below the strip: a click at the very top of the screen
    is another go at the gesture, not an interaction with the panel."""
    x, y = panel.inside_the_peek()
    peek_width = min(config.SCREEN_WIDTH * _metric("peekWidthFraction"), _metric("peekMaxWidth"))
    assert abs(x - config.SCREEN_WIDTH / 2) < peek_width / 2
    assert _default("stripHeight") < y < _metric("peekHeight")


# --- Which application is in front ----------------------------------------------------


def test_which_application_is_in_front_is_asked_of_system_events_inside_the_guest():
    """Over SSH, inside the guest, and with a deadline inside the script as well: an
    AppleEvent nobody answers would otherwise sit out the whole SSH deadline."""
    machine = Machine({"frontmost": "Finder\n"})
    assert probes.frontmost(machine, "asking") == "Finder"
    asked = machine.ssh.commands[0]
    assert asked.startswith("osascript -e ") and '"System Events"' in asked
    assert f"with timeout of {config.SYSTEM_EVENTS_SECONDS} seconds" in asked


def test_a_system_events_that_would_not_say_is_the_labs_failure():
    """Refused, or answering with nobody: either way the lab has no answer, and a
    check must not read "nobody" as an application uDeck left in front."""
    refused = Machine({"frontmost": Failed(code=1, said="execution error: Not authorized to send Apple events")})
    with pytest.raises(LabError, match="Not authorized"):
        probes.frontmost(refused, "asking")
    silent = Machine({"frontmost": "\n"})
    with pytest.raises(LabError, match="named no application"):
        probes.frontmost(silent, "asking")


def test_a_window_is_moved_by_its_process_and_to_the_place_named():
    machine = Machine({})
    probes.move_window(machine, "TextEdit", (1900, 900), "moving")
    moved = machine.ssh.commands[0]
    assert 'tell process "TextEdit" to set position of window 1 to {1900, 900}' in moved
    refused = Machine({"set position": Failed(code=1, said="Invalid index")})
    with pytest.raises(LabError, match="Invalid index"):
        probes.move_window(refused, "TextEdit", (1900, 900), "moving")


# --- The keyboard shortcut ------------------------------------------------------------


HOTKEY_REGISTERED = (
    "2026-09-18 18:20:00.500 Db uDeck[404:1a2b] [place.unicorns.udeck:panel] hotkey ⌃⌥U registered\n"
)
HOTKEY_DISABLED = "2026-09-18 18:20:00.500 Db uDeck[404:1a2b] [place.unicorns.udeck:panel] hotkey disabled\n"
HOTKEY_UNREGISTERABLE = (
    "2026-09-18 18:20:00.500 Db uDeck[404:1a2b] [place.unicorns.udeck:panel] hotkey ⌃⌥U cannot be registered\n"
)
HOTKEY_TAKEN = (
    "2026-09-18 18:20:00.500 Db uDeck[404:1a2b] [place.unicorns.udeck:panel] hotkey ⌃⌥U refused by the system "
    "(status -9878) — most likely already taken by another application\n"
)
PROMOTED = "2026-09-18 18:20:01.470 Db uDeck[404:1a2b] [place.unicorns.udeck:panel] peek -> open on interacted\n"


def test_the_shortcut_uDeck_says_it_holds_is_read_from_its_own_words():
    """The premise of every shortcut check, and it is not free.

    `RegisterEventHotKey` can be refused — the window server gives a combination
    to whoever asked first — and uDeck says so in the same category, with the
    same words around it. A uDeck that never got the key is silent for the chord
    in exactly the way a uDeck that ignores it is, so the three ways of *not*
    holding it must not read as holding it.
    """
    assert panel.registered_hotkeys(ATTACHED + HOTKEY_REGISTERED) == ["⌃⌥U"]
    assert panel.registered_hotkeys(ATTACHED + IDLE) == []
    for said in (HOTKEY_DISABLED, HOTKEY_UNREGISTERABLE, HOTKEY_TAKEN):
        assert panel.registered_hotkeys(said) == [], said


def test_the_panel_the_shortcut_leaves_is_promoted_and_not_a_glance():
    """What tells the shortcut from the gesture, and the whole of this oracle.

    `toggleFromKeyboard` shows the panel and promotes it in the same breath,
    because the hand that pressed the key is on the keys. A check that read only
    the reveal would be green for a shortcut that left a peek — the glance the
    operator would have to reach for the mouse to promote.
    """
    assert panel.opened_ready_to_type(PHASE + PROMOTED)
    assert not panel.opened_ready_to_type(PHASE), "a peek is not a panel ready to type into"
    assert not panel.opened_ready_to_type(PROMOTED), "promoted from nothing is not the panel opening"
    assert not panel.opened_ready_to_type(PROMOTED + PHASE), "and the order is the sentence"
    # And nothing else moved it in the same read: a panel that opened and went
    # away again is not a panel the operator was left with.
    assert not panel.opened_ready_to_type(PHASE + PROMOTED + CLOSED_BY_A_CLICK)


def test_the_chord_is_pressed_inside_the_guest_and_never_over_vnc():
    """Measured on 2026-09-23: over VNC the chord reached uDeck not once in twelve
    presses, and then wedged the guest's keyboard — after it no key at all
    reached a document that had taken one moments before. So it is made inside
    the guest, as a virtual key code with uDeck's own modifiers held."""
    machine = Machine({})
    panel.press_the_chord(machine, config.HOTKEY_KEY_CODE, "pressing the shortcut")
    asked = machine.ssh.commands[0]
    assert asked.startswith("osascript -e ") and '"System Events"' in asked
    assert f"key code {config.HOTKEY_KEY_CODE} using {{control down, option down}}" in asked
    assert f"with timeout of {config.SYSTEM_EVENTS_SECONDS} seconds" in asked
    assert machine.keys == [], "the lab's one keystroke that does not go over VNC"


def test_a_system_events_that_would_not_press_the_chord_is_the_labs_failure():
    """A chord nobody pressed and a chord uDeck ignored leave the same empty log,
    and only one of them is about uDeck."""
    refused = Machine({"key code": Failed(code=1, said="execution error: Not authorized to send Apple events")})
    with pytest.raises(LabError, match="Not authorized"):
        panel.press_the_chord(refused, config.HOTKEY_KEY_CODE, "pressing the shortcut")


# --- The shortcut the lab presses, against the one uDeck registers ---------------------
#
# Read out of uDeck's source rather than described here, for the reason the
# gesture's numbers are: every way of getting it wrong is silent. A chord uDeck
# never registered opens nothing, and the check would be red about uDeck for a
# number the lab got wrong.


def _hotkey_source():
    return (
        Path(panel.__file__).resolve().parents[2] / "Sources" / "UDeckCore" / "Configuration" / "HotKeyBinding.swift"
    ).read_text()


def _key_code(name):
    """The virtual key code uDeck binds `name` to, out of `HotKeyBinding.keyCodes`."""
    found = re.search(rf'"{name}": (\d+)', _hotkey_source())
    assert found, f"{name} is no longer a bindable key in HotKeyBinding.swift"
    return int(found.group(1))


def test_the_lab_presses_the_shortcut_uDeck_actually_registers():
    """The key, the modifiers and the name uDeck writes in its log — all three.

    The name matters as much as the code: the check reads `hotkey ⌃⌥U
    registered` back and requires it to be *this* shortcut, so a lab spelling it
    any other way would call a healthy uDeck a failure.
    """
    source = _hotkey_source()
    key = re.search(r'key: String = "(\w+)"', source)
    modifiers = re.search(r"modifiers: Set<HotKeyModifier> = \[([^\]]*)\]", source)
    assert key and modifiers, "HotKeyBinding no longer has a default key and modifiers"
    wanted = tuple(name.strip().removeprefix(".") for name in modifiers.group(1).split(","))
    assert config.HOTKEY_MODIFIERS == wanted
    assert config.HOTKEY_KEY_CODE == _key_code(key.group(1))
    symbols = "".join(
        re.search(rf'case \.{modifier}: "(.+)"', source).group(1) for modifier in config.HOTKEY_MODIFIERS
    )
    assert config.THE_HOTKEY == symbols + key.group(1), "not how uDeck spells it in the line the check reads"


def test_the_chord_that_is_not_the_shortcut_differs_in_the_key_alone():
    """The control has to be a chord uDeck could have registered and did not.

    Both are pressed through the same call with the same modifiers held, so what
    the silence is about is the combination and not the way the lab makes it.
    """
    assert config.NOT_THE_HOTKEY_KEY_CODE != config.HOTKEY_KEY_CODE
    assert config.NOT_THE_HOTKEY_KEY_CODE == _key_code("J"), "not a key uDeck can bind at all"
    assert config.NOT_THE_HOTKEY == config.THE_HOTKEY.replace("U", "J"), "the same chord, another key"


def test_the_three_keys_typed_into_the_document_are_told_apart():
    """One letter per question, because the text as a whole answers none of them:
    TextEdit rewrites it by itself (measured 2026-09-23, "ay" read back as "Ay").
    So each key is looked for on its own, and two of them being the same letter
    would make "it arrived" and "it did not" the same reading."""
    keys = (config.BEFORE_THE_PANEL_KEY, config.WHILE_THE_PANEL_IS_OPEN_KEY, config.AFTER_IT_CLOSED_KEY)
    assert len(set(keys)) == len(keys)
    for key in keys:
        assert key.isalpha() and key == key.lower() and len(key) == 1, f"{key!r} is not one plain letter"


def test_the_chord_leaves_a_mark_of_its_own_in_a_document():
    """The shortcut is the fourth thing that can land in that document, and
    `panel.the-hotkey-dies-with-udeck` reads it as the combination having gone
    back to the keyboard. It has to be one character, and not one of the three
    letters, or "the chord arrived" and "a letter arrived" would be the same
    reading — and it has to survive the lowercasing the reads are compared
    under, because TextEdit rewrites what it holds."""
    mark = config.THE_CHORD_IN_A_DOCUMENT
    assert len(mark) == 1 and not mark.isprintable(), f"{mark!r} is not one control character"
    assert mark == mark.lower()
    assert mark not in (
        config.BEFORE_THE_PANEL_KEY, config.WHILE_THE_PANEL_IS_OPEN_KEY, config.AFTER_IT_CLOSED_KEY
    )


def test_a_chord_the_operator_chose_is_pressed_the_same_way_uDecks_own_is():
    """The combination is the caller's business and nothing else changes with it.

    A control that differed from the check in *how* the lab pressed it would
    control for nothing, and a shortcut the operator has just changed to is
    exactly that case: it has to be pressed by the one path that works in this
    guest, over SSH and never over VNC.
    """
    machine = Machine({})
    panel.press_the_chord(
        machine, config.HOTKEY_KEY_CODE, "pressing the new shortcut", config.NEW_HOTKEY_MODIFIERS
    )
    asked = machine.ssh.commands[0]
    assert asked.startswith("osascript -e ") and '"System Events"' in asked
    assert f"key code {config.HOTKEY_KEY_CODE} using {{control down, option down, shift down}}" in asked
    assert machine.keys == []
    # And the default is still uDeck's own, so nothing that does not ask changes.
    plain = Machine({})
    panel.press_the_chord(plain, config.HOTKEY_KEY_CODE, "pressing the shortcut")
    assert "{control down, option down}" in plain.ssh.commands[0]


# --- The settings window, against the screen uDeck actually draws ----------------------
#
# The same rule as the gesture's numbers and the shortcut's, and here it is
# sharper: not one control on the Opening screen has a name, so the lab clicks
# by position in a row and identifies the row by what it reads. Every way of
# getting that wrong is a click somewhere else on the screen — which is a
# sentence about uDeck written from a random pixel.


def _settings_view():
    return (
        Path(panel.__file__).resolve().parents[2] / "Sources" / "UDeckKit" / "Views" / "SettingsView.swift"
    ).read_text()


def _defaults(swift_file, type_name):
    """The default arguments of `type_name`'s `init`, as `name: value` pairs."""
    source = (Path(panel.__file__).resolve().parents[2] / "Sources" / "UDeckCore" / "Configuration" / swift_file).read_text()
    body = source[source.index(f"public struct {type_name}"):]
    body = body[body.index("public init("):]
    body = body[: body.index("\n    ) {")]
    return dict(re.findall(r"(\w+): [\w<>\[\]. ]+ = ([\w.\[\]\"', ]+?),?\n", body))


def test_the_modifier_row_is_in_the_order_uDeck_lays_it_out():
    """`ForEach(HotKeyModifier.allCases.sorted())`, and `sorted` is
    `HotKeyModifier.order` — which is macOS's own order for ⌃⌥⇧⌘."""
    source = _hotkey_source()
    cases = re.findall(r"^    case (\w+)$", source, re.MULTILINE)
    order = {name: int(n) for name, n in re.findall(r"case \.(\w+): (\d+)", source)}
    assert set(cases) >= set(order), "HotKeyModifier no longer orders its own cases"
    assert config.HOTKEY_MODIFIER_ROW == tuple(sorted(order, key=order.get))
    assert "HotKeyModifier.allCases.sorted()" in _settings_view(), "the row is no longer laid out in that order"


def test_the_modifier_row_reads_uDecks_default_binding_at_rest():
    """What turns four unnamed toggles in a row into *the* row: on, on, off, off."""
    at_rest = tuple("1" if name in config.HOTKEY_MODIFIERS else "0" for name in config.HOTKEY_MODIFIER_ROW)
    assert config.HOTKEY_MODIFIER_ROW_AT_REST == at_rest


def test_the_modifier_the_lab_adds_is_one_uDeck_does_not_already_hold():
    """A press that turned a modifier *off* would leave a combination uDeck might
    still register, and the two chords would no longer differ by one press."""
    assert config.THE_ADDED_MODIFIER in config.HOTKEY_MODIFIER_ROW
    assert config.THE_ADDED_MODIFIER not in config.HOTKEY_MODIFIERS
    assert config.NEW_HOTKEY_MODIFIERS == tuple(
        name for name in config.HOTKEY_MODIFIER_ROW
        if name in (*config.HOTKEY_MODIFIERS, config.THE_ADDED_MODIFIER)
    )


def test_the_new_shortcut_is_spelled_the_way_uDeck_will_write_it():
    """The check reads `hotkey ⌃⌥⇧U registered` back and requires it to be this
    combination, so a lab spelling it any other way calls a healthy uDeck a
    failure. `HotKeyBinding.displayName`: modifiers in macOS's order, then the key."""
    source = _hotkey_source()
    symbols = "".join(
        re.search(rf'case \.{modifier}: "(.+)"', source).group(1) for modifier in config.NEW_HOTKEY_MODIFIERS
    )
    assert config.THE_NEW_HOTKEY == symbols + config.THE_HOTKEY[-1]
    assert config.THE_NEW_HOTKEY != config.THE_HOTKEY


def test_the_plain_switches_are_in_the_order_uDeck_lays_them_out():
    """Top to bottom on the Opening screen: the gesture, the shortcut, and the
    two under "Also". The lab clicks the third of them by counting, and the row
    it counts in reads the same in any order — all four are on — so *this* is
    where the order is held, against the file that draws them.

    Which makes what the regex does not read a hole rather than a detail: a
    `Toggle` written some other way would be drawn on the screen, counted by the
    lab and missed here, and the assertion below would still pass over a row
    whose third switch is no longer this one. So every `Toggle` on the screen
    has to be one this reads.
    """
    view = _settings_view()
    opening = view[view.index("private struct OpeningSettings"):]
    opening = opening[: opening.index("\n    private func label(")]
    drawn = re.findall(r"isOn: (?:binding\(\\\.([\w.]+)\)|Binding\()", opening)
    assert len(drawn) == opening.count("Toggle("), (
        "a Toggle on the Opening screen is declared in a form this test does not read, "
        "so the order of the row the lab counts in is no longer held by anything"
    )
    # One of them is the modifier row's, inside a `ForEach` over a binding of
    # its own; the rest are the plain switches, in the order they are drawn.
    assert [name for name in drawn if not name] == [""]
    assert tuple(name for name in drawn if name) == config.OPENING_SWITCHES


def test_the_plain_switches_all_read_on_at_rest():
    """Every one of the four is true by default, which is what says the walk found
    this row and not another — and that a machine reading otherwise is not at rest."""
    # Each switch is named by the setting it writes, and each setting's default
    # lives with the type that owns it.
    owners = {
        "gesture.": _defaults("GestureTuning.swift", "GestureTuning"),
        "hotkey.": _defaults("HotKeyBinding.swift", "HotKeyBinding"),
        "": _defaults("AppSettings.swift", "AppSettings"),
    }
    for name, reads in zip(config.OPENING_SWITCHES, config.OPENING_SWITCHES_AT_REST):
        prefix = next(p for p in owners if name.startswith(p))
        default = owners[prefix][name.removeprefix(prefix)]
        assert default == ("true" if reads == "1" else "false"), f"{name} no longer ships {reads}"


def _app_settings_source():
    return (
        Path(panel.__file__).resolve().parents[2] / "Sources" / "UDeckCore" / "Configuration" / "AppSettings.swift"
    ).read_text()


def test_the_settings_file_carries_every_key_uDeck_encodes():
    """What the checks require to still be in the file after one control was clicked.

    `AppSettings` has a hand-written decoder and a synthesised encoder, so what
    it writes is exactly its stored properties — every one of them, every time.
    The optional ones say nothing until the operator chooses, so they are the
    ones a file may honestly be without.
    """
    stored = re.findall(r"^    public var (\w+): ([^\n{]+)$", _app_settings_source(), re.MULTILINE)
    assert stored, "AppSettings no longer declares its properties this way"
    written = tuple(name for name, kind in stored if not kind.strip().endswith("?"))
    optional = [name for name, kind in stored if kind.strip().endswith("?")]
    assert config.SETTINGS_KEYS == written
    assert optional == ["textSize", "language", "officialCatalogue"]


def test_the_defaults_the_file_has_to_still_carry_are_uDecks_own():
    """And a few of them read back, because a key holding something else is the
    same loss as a key that is gone. None of them is a setting either check
    changes, or the check would be requiring the file not to hold its own
    change."""
    defaults = _defaults("AppSettings.swift", "AppSettings")
    for key, value in config.SETTINGS_AT_REST.items():
        assert key in config.SETTINGS_KEYS
        written = "true" if value is True else "false" if value is False else (
            f".{value}" if isinstance(value, str) else str(value)
        )
        assert defaults[key] == written, f"{key} no longer ships {value!r}"
    assert config.THE_SWITCH not in config.SETTINGS_AT_REST
    assert "hotkey" not in config.SETTINGS_AT_REST


def test_the_switch_the_lab_changes_is_one_of_them_and_is_uDecks_own_key():
    """And the key it is named by is the key uDeck writes in the settings file,
    so what the check reads out of that file is the setting it clicked."""
    assert config.THE_SWITCH in config.OPENING_SWITCHES
    assert f"public var {config.THE_SWITCH}: Bool" in (
        Path(panel.__file__).resolve().parents[2] / "Sources" / "UDeckCore" / "Configuration" / "AppSettings.swift"
    ).read_text()
