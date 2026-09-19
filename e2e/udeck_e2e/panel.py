"""The panel's hover gesture: where to put the pointer, how to push, and what uDeck said.

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

Geometry: the strip is a few points tall along the very top of the screen,
centred horizontally, and the pointer counts as pinned within a point or two of
the edge (`GestureTuning` in Sources/UDeckCore). The middle of the top row is
inside it under every setting; the middle of the screen is outside it under
every setting. The lab uses only those two places, so it depends on the shape of
the gesture and not on its numbers.
"""

from __future__ import annotations

import re
import shlex
from collections.abc import Callable
from pathlib import Path

from udeck_e2e import config
from udeck_e2e.errors import LabError

Note = Callable[[str], None]

SUBSYSTEM = "place.unicorns.udeck"
GESTURE = "gesture"

# Where the guest keeps what the lab put there for this check.
GUEST_PUSH = "/tmp/udeck-e2e-push-pointer.py"

PUSH_SCRIPT = Path(__file__).resolve().parent.parent / "guest" / "push-pointer.py"

# Per line: a run holds every message uDeck wrote while the gesture was made.
_FIRED = re.compile(r"fired by (push|dwell) on (.+?)\s*$", re.MULTILINE)
_IDLE = re.compile(r"idle: ([a-zA-Z]+)")


def top_of_the_strip() -> tuple[int, int]:
    """The middle of the screen's top row: inside the trigger strip on any setting."""
    return config.SCREEN_WIDTH // 2, 0


def middle_of_the_screen() -> tuple[int, int]:
    """Far from the strip in both axes — where the negative control puts the pointer."""
    return config.SCREEN_WIDTH // 2, config.SCREEN_HEIGHT // 2


def fired_by(lines: str) -> list[str]:
    """Which paths uDeck says fired, in order: `push`, `dwell`."""
    return [match.group(1) for match in _FIRED.finditer(lines)]


def idle_reasons(lines: str) -> list[str]:
    """The gates uDeck says stopped the gesture, in order — why nothing fired."""
    return [match.group(1) for match in _IDLE.finditer(lines)]


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

    def since(self, mark: str, step: str) -> str:
        """Everything uDeck said about the gesture since `mark`.

        Evidence, so a read that fails says so rather than raising: a verdict
        must not turn on whether the log could be read — except through
        `keep`, which is what makes the reading mean anything at all.
        """
        if not self.kept:
            raise LabError(step, "nothing asked the guest to keep uDeck's messages, so its log proves nothing")
        predicate = f'subsystem == "{SUBSYSTEM}" AND category == "{GESTURE}"'
        try:
            return self.machine.ssh.ask(
                f"/usr/bin/log show --start {shlex.quote(mark)} --predicate {shlex.quote(predicate)} "
                f"--debug --info --style compact",
                step,
            ).stdout
        except LabError as error:
            self.note(f"   uDeck's log could not be read: {error.reason}")
            return ""

    def collect(self, directory: Path, mark: str, step: str, name: str = "gesture.log") -> str:
        """What uDeck said, kept with the check's report (Q38), and returned."""
        text = self.since(mark, step)
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
