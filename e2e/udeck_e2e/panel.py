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
"""

from __future__ import annotations

import re
import shlex
from collections.abc import Callable
from pathlib import Path

from udeck_e2e import config, probes
from udeck_e2e.errors import LabError

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


def press_the_chord(machine, key_code: int, step: str) -> None:
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
    on three fresh machines, and uDeck's line 0.9 to 1.4 s after the command,
    round trip included — well inside `config.GESTURE_ANSWER_SECONDS`.

    Which key is the caller's business: the shortcut uDeck registered, and the
    chord that is not it, are both pressed through here so that the control
    differs from the check in the key alone.
    """
    probes.press_chord(machine, key_code, config.HOTKEY_MODIFIERS, step)
