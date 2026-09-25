"""The panel: where to put the pointer, how to push, and what uDeck said about it.

The panel opening is not the check. Two different paths open it — the pointer
resting in the strip at the top of the screen, and the pointer already pinned
there while the device keeps pushing — and a check that only asked "did the
panel open" would pass for the wrong one (Q45). uDeck logs which path fired:

    fired by dwell on <screen>
    fired by push on <screen>

That line is the oracle. It is a `debug` message, which the unified log keeps
nowhere unless it is asked to, so the lab asks the guest to keep this one
subsystem's and reads them back afterwards. The same messages carry `idle:
<reason>` — the gate that stopped the gesture — which is what makes a check that
fires nothing worth reading.

The same log answers the other half of the panel's life, which is how it goes
away again. uDeck writes the phase it left and the event that took it —
`peek -> collapsed on pointerLeft` — and both halves are read, because the panel
has four ways of closing, it remembers which one it was, and the operator sees
the difference at the next reveal.

And the other way in, which needs no pointer at all: the global shortcut. uDeck
says which one it holds (`hotkey ⌃⌥U registered`) and answers it with two phases
rather than one, because a shortcut opens the panel ready to be typed into. The
lab presses it from inside the guest and not over VNC, and the measurement that
settles that is in `press_the_chord` — a chord sent over VNC reaches nobody and
leaves the guest's keyboard wedged behind it.

Geometry: the strip is a few points tall along the very top of the screen,
centred horizontally, and the pointer counts as pinned within a point or two of
the edge (`GestureTuning` in Sources/UDeckCore). The dwell is made a few rows
down the middle of the strip — inside it and short of pinned, so that nothing
the lab does there can be taken for a push — and the middle of the screen is
outside the strip under every setting. The first of those depends on two of
uDeck's numbers, so it is kept in `config` with its reasons and the lab's own
tests read it back against uDeck's defaults. The closing checks need two more
places, a place *on* the panel and a place past it, and both have to know
roughly how big the panel is: measurements kept in `config` the same way, and
read back the same way.

And then the panel as a scene, because more than one group of checks needs to
make it. Showing a peek, holding it open with a click, taking the pointer past
it, interrupting it with another application, reading uDeck's log in steps while
all that happens, and the two sentences every one of those rests on — the panel
closed out of *this* phase on *that* event, and uDeck was still there to have
done it. The panel checks made all of it first; the settings checks need the
same scene to ask whether a setting the operator changed in uDeck's own window
still holds, so it lives here rather than in either check file. One property,
several readers: an edit to what "the panel was interrupted" means reaches every
check that says it.
"""

from __future__ import annotations

import re
import shlex
from collections.abc import Callable
from pathlib import Path

from udeck_e2e import app, config, probes
from udeck_e2e.errors import LabError, expect

Note = Callable[[str], None]

SUBSYSTEM = "place.unicorns.udeck"
GESTURE = "gesture"
# The panel's own category, where uDeck records every phase it moves through.
PANEL = "panel"

# The phases the panel can be in (PanelState.swift). `collapsed` is shut; the
# rest are the panel being shown, in one size or another.
SHUT = "collapsed"

# Where the guest keeps what the lab put there for this check.
GUEST_PUSH = "/tmp/udeck-e2e-push-pointer.py"

PUSH_SCRIPT = Path(__file__).resolve().parent.parent / "guest" / "push-pointer.py"

# Per line: a run holds every message uDeck wrote while the gesture was made.
_FIRED = re.compile(r"fired by (push|dwell) on (.+?)\s*$", re.MULTILINE)
_IDLE = re.compile(r"idle: ([a-zA-Z]+)")
# `collapsed -> peek on revealRequested` (PanelController.swift, `apply`).
_PHASE = re.compile(r"\b([a-z]+) -> ([a-z]+) on ([A-Za-z]+)")
# `hotkey ⌃⌥U registered` (HotKeyMonitor.apply), written only once the window
# server has actually handed the combination over. The same method says
# `hotkey disabled`, `hotkey ⌃⌥U cannot be registered` and `… refused by the
# system` in the cases where it did not, and none of those match this.
_REGISTERED = re.compile(r"hotkey (\S+) registered")

# What uDeck does when the shortcut is pressed at a shut panel, in order
# (`PanelController.toggleFromKeyboard`): it shows the panel *and* promotes it
# to one that is being worked in, in the same breath. That second line is the
# whole difference from the pointer gesture, which leaves a peek.
OPENED_READY_TO_TYPE = [(SHUT, "peek", "revealRequested"), ("peek", "open", "interacted")]


def top_of_the_strip() -> tuple[int, int]:
    """Where the dwell is made: the middle of the strip across, and a few rows down it.

    Inside the trigger strip and not pinned against the edge
    (`config.INSIDE_THE_STRIP_Y`). The top row itself is pinned, and a pinned
    pointer the VNC jump arrived at was sometimes read as a push.
    """
    return config.SCREEN_WIDTH // 2, config.INSIDE_THE_STRIP_Y


def middle_of_the_screen() -> tuple[int, int]:
    """Far from the strip in both axes — where the negative control puts the pointer."""
    return config.SCREEN_WIDTH // 2, config.SCREEN_HEIGHT // 2


def past_the_panel() -> tuple[int, int]:
    """Outside the region that keeps a peek or a held panel alive.

    A third place, and it exists because the second one is not one. The middle of
    the screen is far from the *strip*, which is all the opening checks ever
    needed — but the open panel reaches 790 points down from the top, 760 of
    content below a 30-point menu bar, so the middle of a 1440-pixel screen is
    *inside* it. A check that took the pointer there and called it "away" would
    be clicking on the panel and asking why the panel did not treat it as a click
    outside.

    This is left of the panel and below it at once (`config.PAST_THE_PANEL`), so
    neither measurement alone has to be right for it to be past. Not past a
    panel in fullscreen, whose keep-alive region is the whole visible screen and
    has no outside to speak of; no check takes it there.
    """
    return config.PAST_THE_PANEL


def inside_the_peek() -> tuple[int, int]:
    """On the panel, and on nothing in it — where a click holds a peek open.

    A click anywhere on the panel promotes a peek to a held panel, and a peek
    draws no controls, so a click well inside its content can only mean that
    (`config.INSIDE_THE_PEEK`). Below the trigger strip, too: a click at the very
    top would be the gesture again rather than an interaction.
    """
    return config.INSIDE_THE_PEEK


def fired_by(lines: str) -> list[str]:
    """Which paths uDeck says fired, in order: `push`, `dwell`."""
    return [match.group(1) for match in _FIRED.finditer(lines)]


def idle_reasons(lines: str) -> list[str]:
    """The gates uDeck says stopped the gesture, in order — why nothing fired."""
    return [match.group(1) for match in _IDLE.finditer(lines)]


def phases(lines: str) -> list[tuple[str, str, str]]:
    """Every phase the panel moved through: `(from, to, because of)`, in order."""
    return [match.groups() for match in _PHASE.finditer(lines)]


def revealed(lines: str) -> list[str]:
    """The phases the panel was shown in, from having been shut.

    This is what "the panel opened" means, and it is a different sentence from
    "the gesture fired". uDeck writes `fired by <path>` three lines before it
    asks the panel to appear (`PanelController.apply(.revealRequested)`), so a
    panel that never appears — for anyone — leaves that line exactly as it is.
    The phase is written from inside `apply`, after the state has changed and
    only when it changed, so it is the first thing uDeck says that could not be
    true of a panel that stayed shut.

    It is still uDeck's own account, not a photograph. What was measured against
    the window server (2026-09-19) is that the window server cannot answer this
    more strictly: uDeck keeps one window at the status-bar level the whole time,
    and after the first reveal its shape does not go back — open and
    shut-again look the same from outside.
    """
    return [to for was, to, _ in phases(lines) if was == SHUT and to != SHUT]


def registered_hotkeys(lines: str) -> list[str]:
    """The shortcuts uDeck says it holds, spelled as it spells them (`⌃⌥U`).

    The premise of every check about the shortcut, and the one uDeck writes down
    for itself: `RegisterEventHotKey` can be refused — another application may
    already hold the combination, and the window server gives it to whoever
    asked first — so a uDeck that is running is not yet a uDeck that would hear
    the key. It is written once, at launch, and the check that reads it starts
    uDeck inside the window on its log for that reason.
    """
    return [match.group(1) for match in _REGISTERED.finditer(lines)]


def opened_ready_to_type(lines: str) -> bool:
    """Whether the panel was both shown and promoted, and nothing else moved it.

    `revealed` is not enough here, and that is the point of the shortcut: the
    operator who reached for the keys is not going to reach for the mouse to
    promote a peek, so `toggleFromKeyboard` does it for him. A check that
    accepted "the panel appeared" would be green for a shortcut that left him a
    glance he then had to click into.
    """
    return phases(lines) == OPENED_READY_TO_TYPE


def closed_on(lines: str) -> list[str]:
    """What shut the panel, in order — the events it went back to `collapsed` on.

    The mirror of `revealed`, and the oracle for every check about the panel
    closing. It is the event and not merely the fact, because the panel has four
    ways to close and they are not interchangeable: `pointerLeft` and
    `closeRequested` and `escape(…)` are the operator putting it away, and
    `otherAppActivated` is something interrupting him. uDeck remembers which,
    and the operator sees the difference at the *next* reveal — a dismissed panel
    comes back as a peek, an interrupted one comes back whole.

    So a check that only asked "is it shut" would pass on the wrong reason, in
    the exact way the panel checks were already careful about at the other end
    (Q45): the panel opening is not the check either, and which path opened it
    is. `escape(isEditingText: false)` is read as `escape` — the phase line's
    event is matched by its name, and what it carries is not part of it.
    """
    return [because for _, to, because in phases(lines) if to == SHUT]


def after_it_closed(lines: str) -> str:
    """What uDeck said after the first line in which the panel closed — nothing, if it never did.

    A check that watches a panel stay shut has to watch from the closing line
    on, and the closing line does not start a read of its own: the read that
    heard the panel close can already hold what came after it.
    """
    split = lines.splitlines()
    for index, line in enumerate(split):
        if closed_on(line):
            return "\n".join(split[index + 1 :])
    return ""


def said_by_uDeck(lines: str) -> list[str]:
    """The lines uDeck itself wrote, as against what `log show` puts around them.

    `log show` prints its column header whether or not anything matched, so a
    window that holds nothing uDeck said is not an empty string.
    """
    return [line for line in lines.splitlines() if f"[{SUBSYSTEM}:" in line]


# How uDeck starts the line it writes when the workspace tells it another
# application came forward while the panel was on screen — whether it then reads
# that as a click past the panel or as a switch (`handleApplicationActivated`).
CAME_FORWARD = "another application came forward"
# And the event the same news becomes when it is read as a switch, or when it
# arrives with nothing on screen: `otherAppActivated ignored in collapsed`.
OTHER_APP = "otherAppActivated"


def news_of_another_application(lines: str) -> list[str]:
    """Every line in which uDeck says the workspace told it another application came forward.

    There are two messengers of a click past the panel, uDeck's own click monitor
    and this one, and the monitor writes no line of its own — so a click this
    says nothing about was brought by the monitor alone.
    """
    return [line for line in lines.splitlines() if CAME_FORWARD in line or OTHER_APP in line]


class GestureLog:
    """uDeck's own account of the gesture, kept in the guest's log and read back.

    Debug messages are the only place uDeck says which path fired, and the
    unified log keeps none of them: they have to be asked for. Two ways were
    measured on the same gestures (2026-09-18), and only one of them can be
    believed.

    `log stream` into a file in the guest delivered the first gesture's lines and
    then nothing at all — four gestures in a row, each of which the kept log
    holds. A check reading that file would have read an empty file as "nothing
    fired", which is the one mistake a check must not make.

    So the lab asks the guest to keep this one subsystem's debug messages
    (`log config`, which needs root and lasts as long as the machine — one
    check), and reads them back with `log show` from a moment it wrote down. It
    also *checks that the asking worked*: a log nobody is keeping answers every
    question with silence, and silence is what a check that proves nothing looks
    like.
    """

    def __init__(self, machine, note: Note) -> None:
        self.machine = machine
        self.note = note
        self.kept = False

    def keep(self, step: str) -> None:
        """Ask the guest to keep uDeck's debug messages, and make sure it did."""
        said = self.machine.ssh.run(
            f"sudo -n /usr/bin/log config --subsystem {shlex.quote(SUBSYSTEM)} "
            f"--mode 'level:debug,persist:debug' && "
            f"sudo -n /usr/bin/log config --status --subsystem {shlex.quote(SUBSYSTEM)}",
            step,
        ).stdout
        if "PERSIST_DEBUG" not in said:
            raise LabError(step, f"the guest is not keeping uDeck's debug messages: {said.strip() or 'nothing said'}")
        self.kept = True

    def mark(self, step: str) -> str:
        """The guest's own clock, in the form `log show --start` takes.

        Its clock, not this Mac's: the two can differ by seconds, and a window
        that starts a second late begins after the gesture it is there to catch.
        """
        return self.machine.ssh.run("/bin/date '+%Y-%m-%d %H:%M:%S'", step).stdout.strip()

    def read(self, mark: str, step: str) -> str:
        """Everything uDeck said about the gesture since `mark`, as an oracle.

        This raises, and that is why it exists beside `collect`. Every verdict the
        panel checks reach is a statement about what uDeck said: "it fired by the
        push", "it opened nothing". An empty answer satisfies the second and
        contradicts the first, so a log that could not be read *looks exactly like*
        a panel that never opened — and a check that took it for one would be
        pronouncing on uDeck because the lab's own connection wobbled.

        `ask` already refuses to let a dropped connection pass for an answer. The
        exit code is checked here too, because `log show` can fail on its own — a
        predicate it will not parse, a log daemon that is not there — and hand back
        nothing at all, with nothing said about why.
        """
        if not self.kept:
            raise LabError(step, "nothing asked the guest to keep uDeck's messages, so its log proves nothing")
        # Both categories: the gesture says which path fired, the panel says
        # whether anything opened, and a check needs the two together.
        predicate = f'subsystem == "{SUBSYSTEM}" AND (category == "{GESTURE}" OR category == "{PANEL}")'
        done = self.machine.ssh.ask(
            f"/usr/bin/log show --start {shlex.quote(mark)} --predicate {shlex.quote(predicate)} "
            f"--debug --info --style compact",
            step,
        )
        if done.returncode != 0:
            said = (done.stderr or done.stdout).strip().splitlines()
            raise LabError(
                step,
                f"the guest would not read uDeck's log: {said[-1] if said else f'exit {done.returncode}'}",
            )
        return done.stdout

    def _read_or_say_why_not(self, mark: str, step: str) -> str:
        """The same, as evidence: a read that fails says so and hands back nothing.

        For the report, and for the sentence a failing check quotes. Nothing that
        decides an outcome comes through here.
        """
        try:
            return self.read(mark, step)
        except LabError as error:
            self.note(f"   uDeck's log could not be read: {error.reason}")
            return ""

    def collect(self, directory: Path, mark: str, step: str, name: str = "gesture.log") -> str:
        """What uDeck said, kept with the check's report (Q38), and returned."""
        text = self._read_or_say_why_not(mark, step)
        try:
            (directory / name).write_text(text)
        except OSError as error:
            self.note(f"   uDeck's log could not be written to {directory / name}: {error}")
        return text


def push_upward(
    machine,
    step: str,
    throw: bool = False,
    steps: int = config.PUSH_STEPS,
    delta: float = config.PUSH_DELTA,
    pause: float = config.PUSH_PAUSE_SECONDS,
) -> str:
    """Push from inside the guest: relative movement, reported as a device reports it.

    The push happens where the pointer already is, because relative movement
    names no place — which is the whole reason this is the path that works.
    Whoever calls this has put the pointer there.

    `throw` first carries the pointer to the top edge and stops there: the check
    that pushes at the edge cannot be *placed* there, because a pointer resting
    in the strip opens the panel by the dwell within a fraction of a second, long
    before an SSH command could push it. Stopping is as important as throwing —
    uDeck counts upward movement made while the pointer was already pinned, so a
    throw that overshoots is itself a push and the real one never matters. The
    script watches the pointer and stops at the edge rather than counting reports.

    The control in the middle of the screen takes no throw — it pushes where it
    was parked, and 60 points of movement leave it 660 below the strip.

    `steps × |delta|` has to clear uDeck's threshold inside its window — both are
    in `GestureTuning`, and the lab's numbers are chosen with room.
    """
    machine.ssh.copy_in(PUSH_SCRIPT, GUEST_PUSH, step)
    throw_cap = config.THROW_CAP if throw else 0
    done = machine.ssh.run(
        f"/usr/bin/python3 {shlex.quote(GUEST_PUSH)} "
        f"{throw_cap} {config.THROW_DELTA} {config.THROW_PAUSE_SECONDS} {config.PINNED_TOLERANCE_PIXELS} "
        f"{steps} {delta} {pause}",
        step,
    )
    return done.stdout.strip()


def press_the_chord(machine, key_code: int, step: str, modifiers: tuple[str, ...] = config.HOTKEY_MODIFIERS) -> None:
    """Press uDeck's modifiers and one key, from inside the guest over SSH.

    Every other key the lab presses goes over VNC (`Machine.key`), where it
    arrives at the machine's keyboard the way a key on a real one does. **The
    chord cannot be made that way in this guest, and trying it is worse than
    useless.** Measured on 2026-09-23 (.build/e2e/20260923-212036Z,
    hotkey.vnc-chord): twelve `ctrl-alt-u` presses over VNC, with uDeck running
    and saying it held the shortcut, produced not one line — and three
    screenshots identical to the byte. On a machine of its own the same chord
    then *wedged the keyboard*: after it, neither a plain letter over VNC, nor
    one through System Events, nor one after the lone modifiers had been pressed
    and released reached the document that had taken a letter moments before
    (run-3 of the measurement). It reads exactly like a modifier left stuck
    down, and the lab must never send one.

    So the chord is made inside the guest instead, as a virtual key code with
    the modifiers named — the same call the lab already uses to drive the
    interface (`probes`). Measured the same day: 9 opens and 9 closes out of 9,
    on two fresh machines — six cycles on one (.build/e2e/20260923-212036Z,
    hotkey.osascript-chord) and three on the other (-212549Z,
    hotkey.the-key-after-the-hotkey) — with uDeck's line 0.9 to 1.4 s after the
    command, round trip included, well inside `config.GESTURE_ANSWER_SECONDS`.

    **What "the lab must never send one" is held by, and what it is not.** The
    rule lives here and a test of this function holds it: what `press_the_chord`
    does is a command over SSH and never a key over VNC. It is not a rule about
    the checks that use it — `panel.the-hotkey-again` and
    `panel.the-hotkey-dies-with-udeck` press plain letters over VNC on purpose,
    because a letter is how they ask where the keyboard went. Two checks send no
    VNC key at all, `panel.the-hotkey` and
    `panel.the-hotkey-closes-what-the-gesture-opened`, and each says so in its
    own test rather than here.

    Which combination is the caller's business, and the default is uDeck's own:
    the shortcut it registered, the chord that is not it, and the one the
    operator changed it to are all pressed through here, so that a control
    differs from the check it controls in the combination alone and in nothing
    about how the lab presses it.
    """
    probes.press_chord(machine, key_code, modifiers, step)


# --- The panel as a scene ---------------------------------------------------------


def park_in_the_middle(machine) -> None:
    """The pointer starts wherever the last thing left it — ten pixels from the corner
    after a boot, which is neither in the strip nor usefully out of it.

    Every check begins from the same place, far from the edge, so that the move
    that follows is the whole gesture and not the tail of another one.
    """
    machine.move_pointer(*middle_of_the_screen(), "to the middle of the screen, away from the strip")
    machine.sleep(1)


def reveal(machine, story, label):
    """The gesture, and a panel at the end of it, from wherever the pointer was.

    `park_in_the_middle` first, for the reason every check does it: the move
    into the strip has to be the whole gesture and not the tail of another one.
    Which path fired is not a closing check's business — a dwell and a push leave
    the same panel — so this asks only that something opened.
    """
    park_in_the_middle(machine)
    machine.move_pointer(*top_of_the_strip(), "into the strip at the top of the screen")
    machine.sleep(config.DWELL_SECONDS)
    said = answer(machine, story, label, revealed)
    expect(
        revealed(said) != [],
        f"the panel did not open for '{label}'; what uDeck says: {short(said)}",
    )
    return said


def reveal_a_peek(machine, story, label):
    """The same, and a peek specifically — which is where each closing check starts.

    A peek and a held panel are closed by different things, so a closing check
    that began from whichever one it happened to get would be a different check
    on different days. It is a peek whenever uDeck was installed and started
    afresh: a panel that has never been put away has nothing to restore.
    """
    said = reveal(machine, story, label)
    shown = revealed(said)
    expect(
        shown == ["peek"],
        f"'{label}' brought the panel back as {shown}, not as a peek, so the check that follows "
        f"would be about a phase it was not written for: {short(said)}",
    )
    return said


def hold_it_open(machine, story, check_dir):
    """A click on the peek, and a held panel — which everything after it is about."""
    machine.click(*inside_the_peek(), f"inside the panel at {inside_the_peek()}")
    said = answer(machine, story, "the click inside the peek", phases)
    expect(
        ("peek", "open", "interacted") in phases(said),
        f"the click inside did not hold the panel open; uDeck says: {short(said)}",
    )
    machine.screenshot(check_dir, "the panel held open")


def interrupt_a_held_panel(machine, story, check_dir, label=""):
    """A held panel, and another application brought forward over it with no click.

    The pointer is taken past the panel first — exactly where a click that
    dismissed it would have been — so that only the age of the last click is
    left to tell uDeck this was not one. The Finder comes forward by `open -a`
    over SSH, which posted the workspace's notification every time it was
    measured; an AppleScript activation from inside the guest posted none.

    And the lab waits for it to be there before it waits for uDeck to answer,
    which is the difference between the two failures. A `open -a` that started
    nothing leaves no application coming forward, no notification, and therefore
    no collapse — and this read exactly as uDeck having ignored a switch it was
    never told about. That is the scene failing, so it is a `LabError` here,
    the way it already is in `bring_forward_before_the_panel`.

    What it does *not* say is what the interruption should do to the panel: that
    depends on `collapseOnAppSwitch`, which is a setting the operator can turn
    off, so the sentence belongs to the check that made this scene.

    And when it must do nothing, the wait at the end is where that is made safe:
    `wait_for_it_to_close` gives uDeck the same ten seconds an answer would have
    had and then, having heard none, asks whether uDeck could have given one —
    still running, its log still receiving, the guest's clock still ahead of the
    mark. A check that reads the silence afterwards is reading uDeck's silence.

    `label` is what the story calls this scene, because a check that makes it
    twice means two different things by it.
    """
    reveal_a_peek(machine, story, f"the reveal{label}")
    hold_it_open(machine, story, check_dir)
    machine.move_pointer(*past_the_panel(), f"past the panel, to {past_the_panel()}")
    bring_forward(machine, config.THE_DESKTOP, f"bringing the {config.THE_DESKTOP} forward with no click")
    said = wait_for_it_to_close(machine, story, f"the switch with no click{label}")
    machine.screenshot(check_dir, f"after the switch with no click{label}")
    return said


def bring_forward(machine, application, step, document=None):
    """`open -a`, and the lab waits until that application really is in front.

    Setting the scene, never a verdict: an application that would not come
    forward is the lab failing to arrange what the check is about, and every
    question after it would be asked of a machine that is not in the state the
    check describes.

    `document` is opened in it, for the checks that read what the keyboard
    reached rather than which application is in front. It is named so that the
    window read afterwards is the one this check made, and not whatever untitled
    thing the application would otherwise have offered.
    """
    opening = f"/usr/bin/open -a {shlex.quote(application)}"
    if document is not None:
        opening += f" {shlex.quote(document)}"
    machine.ssh.run(opening, step)
    deadline = machine.clock() + config.FORWARD_SECONDS
    while True:
        in_front = probes.frontmost(machine, step)
        if in_front == application:
            return in_front
        if machine.clock() >= deadline:
            raise LabError(step, f"{in_front} is in front after {config.FORWARD_SECONDS}s, not {application}")
        machine.sleep(1)


def bring_forward_before_the_panel(machine, note, document=None):
    """Another application in front before the panel is shown, with its window out of the way.

    The scene, not the check: an application that would not come forward is the
    lab failing to set it, never a verdict about uDeck.
    """
    application = config.IN_FRONT_BEFORE_THE_PANEL
    bring_forward(machine, application, f"bringing {application} forward before the panel", document=document)
    probes.move_window(machine, application, config.OUT_OF_THE_WAY, f"putting {application}'s window out of the way")
    note(f"   in front before the panel: {application}")
    return application


# --- What uDeck said about it, and whether it could have said anything ------------


def expect_it_closed(said, was, because, what):
    """The panel went away, out of the phase named and on the event named — and only that.

    Both halves of the arrow, because either on its own passes for the wrong
    reason. `-> collapsed` alone is satisfied by any of the four ways the panel
    closes, and the operator can tell them apart at the next reveal; the event
    alone says nothing about which phase heard it, and "a peek closes when the
    pointer leaves" and "a held panel does" are the difference between the design
    working and the one failure it exists to prevent.

    And the only closing in the read, with nothing reopened in it. The read that
    hears the panel close is whatever the log held by the time it was asked, and
    `log show` takes long enough that it can already hold what came next — the
    panel coming straight back, or closing a second time for another reason. A
    check that asked only whether the expected line was somewhere in it would be
    green over both.
    """
    closings = [phase for phase in phases(said) if phase[1] == SHUT]
    expect(closings != [], f"{what} did not close the panel; what uDeck says: {short(said)}")
    expect(
        closings == [(was, SHUT, because)],
        f"{what} closed the panel as {closings}, not once as ('{was}', '{SHUT}', '{because}'): "
        f"{short(said)}",
    )
    expect(
        revealed(said) == [],
        f"the panel came back as {revealed(said)} in the same read that saw {what} close it: "
        f"{short(said)}",
    )


def expect_it_holds(said, wanted):
    """uDeck says which shortcut it took from the window server, and it is this one.

    The premise every check about the shortcut rests on, and it is not free:
    `RegisterEventHotKey` hands a combination to whoever asked for it first, so
    it can be refused, and a uDeck that never got the key is silent for the
    chord in exactly the way a uDeck that ignores it is (`HotKeyMonitor.apply`).

    uDeck writes this line at launch, and again whenever the operator changes the
    shortcut and `PanelController.settingsChanged` hands the new binding over —
    which is why both the panel checks and the settings checks read it.
    """
    holds = registered_hotkeys(said)
    expect(
        holds == [wanted],
        f"uDeck says it holds {holds}, not ['{wanted}'] — the shortcut the operator is given is "
        f"not the one the lab is about to press, or the system refused it to uDeck: {short(said)}",
    )


def expect_it_opened_ready_to_type(said, what):
    """The panel was shown *and* promoted, in that order, and nothing else moved it.

    Two sentences, because the second is what tells the shortcut from the
    gesture and the first is what tells either from nothing at all. A panel that
    never appeared and a panel that appeared as a glance are different failures,
    and a person reading the report needs to be told which one he has.
    """
    moved = phases(said)
    expect(moved != [], f"{what} did not open the panel; what uDeck says: {short(said)}")
    expect(
        moved == OPENED_READY_TO_TYPE,
        f"{what} moved the panel {moved}, not {OPENED_READY_TO_TYPE}: the shortcut has to leave a panel "
        f"ready to be typed into, and a peek is a glance the operator would have to reach for the mouse to "
        f"promote: {short(said)}",
    )

def wait_for_it_to_close(machine, story, label):
    """What uDeck said once the panel closed, or once the time is up and uDeck is shown to have been able to say it."""
    return answer(machine, story, label, closed_on)


def answer(machine, story, label, ready):
    """`story.wait_for`, and a wait that ran out is not a verdict until uDeck could have answered.

    A slow machine, a uDeck that is no longer there, a log whose window has
    stopped receiving: each leaves exactly the silence a panel that did nothing
    leaves, and only one of them is about the panel.
    """
    said = story.wait_for(label, ready)
    if not ready(said):
        prove_uDeck_could_have_answered(machine, story, label)
    return said


def prove_uDeck_could_have_answered(machine, story, label):
    """Why the answer never came: uDeck's doing, or the lab's.

    One rule, and every check about a stretch that was supposed to change
    nothing keeps it. **A uDeck that was running and is gone is uDeck failing.**
    Every check starts one and waits for it, so a missing process is not an
    absence — it is a uDeck that died in the middle of the thing the check was
    watching, and it was "could not check" here while the same death on Escape
    was already red. The guest answering the question at all is what makes that
    reading safe: `running_pids` is a command over SSH, and a machine that is
    gone raises before it can be read as an empty answer.

    What stays the lab's: its log holding nothing uDeck said since the check
    began, which is a window that never started rather than a uDeck that went
    quiet; and the guest's clock behind the start of that window, because the
    window is `log show --start <mark>` on the guest's clock, so a clock stepped
    back past the mark files everything uDeck says afterwards before it, where
    no read will look. Both are asked *after* uDeck's own life, because a uDeck
    that died would explain either one and neither would explain it.
    """
    step = f"making sure uDeck could have answered {label}"
    expect_it_was_still_there(
        machine,
        step,
        f"uDeck was not running when its answer to {label} did not come: it was started by this check and "
        "died in the middle of it, so there was nothing left to answer; what it said before is in story.log",
    )
    if not story.heard_from_uDeck():
        raise LabError(
            step,
            "uDeck's log holds nothing uDeck said since the check began, so it is the window on the log "
            f"that is silent and not uDeck: {short(chr(10).join(story.window))}",
        )
    now = story.log.mark(step)
    if now < story.since:
        raise LabError(
            step,
            f"the guest's clock is at {now}, behind the start of the window on uDeck's log at {story.since}, "
            "so what uDeck said since the clock went back is outside the window",
        )


def expect_it_was_still_there(machine, step, message):
    """**A uDeck that was running and is gone is uDeck failing.**

    The one place that rule is written, so that every check which watches a
    stretch of quiet reads the same property. Each of them starts uDeck and
    waits for it, so a missing process at the end is not an absence but a uDeck
    that died in the middle of what was being watched — and "nothing happened"
    is free once nothing is running.

    Asked through `app.running_pids`, which is a command over SSH: a guest that
    has gone raises rather than answering "nothing is running", so the reading
    cannot turn a dead machine into a verdict about uDeck.
    """
    expect(bool(app.running_pids(machine, step)), message)


def short(said):
    """The tail of what uDeck said, for a reason a person reads in one line."""
    return said.strip().replace("\n", " / ")[-400:] or "nothing"


class Story:
    """uDeck's log read in steps: what each action added, and all of it kept.

    One window, opened once and never moved, because the guest's clock has a
    second's resolution and a check that took a fresh mark between two actions
    would sometimes start the next window inside the answer to the last one.
    What separates the steps instead is how much has already been read, which is
    exact.

    Everything goes into `story.log` beside the report, step by step and labelled
    — including the steps where uDeck said nothing, which for a check about a
    panel that must *not* close is the part a person needs to see.

    Counting lines is exact only while the window only grows, and nothing else
    would make it grow: a read that comes back shorter than what has already been
    read is the lab's failure, raised on the spot. Taken quietly, it would leave
    every later step an empty slice — and an empty slice is exactly what "the
    held panel did not close" and "the panel stayed shut" look like.
    """

    def __init__(self, machine, log, check_dir: Path, note) -> None:
        self.machine = machine
        self.log = log
        self.check_dir = check_dir
        self.note = note
        self.since = log.mark("noting when the panel check begins")
        self.read_so_far = 0
        self.told: list[str] = []
        # The whole window as the last read saw it, for the question of whether
        # uDeck has said anything in it at all.
        self.window: list[str] = []

    def take(self, label: str) -> str:
        """What uDeck has added since the last step, and now it is read."""
        return self._cut(self._lines(label), label)

    def wait_for(self, label: str, ready, seconds: float = config.GESTURE_ANSWER_SECONDS) -> str:
        """The same, once `ready` is satisfied by it — or once the time is up.

        Giving up quietly is the point: the check, not this, decides what an
        answer that never came means, and it has the words for it — after asking
        whether uDeck could have given one (`answer`). Nothing here is ever the
        verdict.
        """
        deadline = self.machine.clock() + seconds
        while True:
            lines = self._lines(label)
            if ready("\n".join(lines[self.read_so_far :])) or self.machine.clock() >= deadline:
                return self._cut(lines, label)
            self.machine.sleep(1)

    def keep(self) -> None:
        """Both files: the whole log as every other check keeps it, and the story."""
        self.log.collect(self.check_dir, self.since, "keeping what uDeck said")
        try:
            (self.check_dir / "story.log").write_text("\n\n".join(self.told))
        except OSError as error:
            self.note(f"   what uDeck said could not be written to {self.check_dir / 'story.log'}: {error}")

    def heard_from_uDeck(self) -> bool:
        """Whether the window, as last read, holds anything uDeck itself said."""
        return said_by_uDeck("\n".join(self.window)) != []

    def _lines(self, label: str) -> list[str]:
        # The oracle, not the evidence: a log that cannot be read has to raise
        # here, because silence is exactly what "nothing happened" looks like.
        step = f"reading what uDeck says about {label}"
        lines = self.log.read(self.since, step).splitlines()
        if len(lines) < self.read_so_far:
            raise LabError(
                step,
                f"uDeck's log got shorter — {len(lines)} lines where {self.read_so_far} had already been read — "
                "so what is missing could no longer be told from what never happened",
            )
        self.window = lines
        return lines

    def _cut(self, lines: list[str], label: str) -> str:
        said = "\n".join(lines[self.read_so_far :])
        self.read_so_far = len(lines)
        self.told.append(f"=== {label} ===\n{said or '(nothing)'}")
        return said
