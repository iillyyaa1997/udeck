"""Questions asked of a running guest, shared by the bake and the self-check.

Each answers from the system's own state, not from a setting the lab wrote:
whether Spotlight is indexing, whether a process is running, what size the
screen is. System Events is only ever asked over SSH — the channel the guest
permits to drive the interface — and never Finder, whose AppleEvents over SSH
raise a consent dialog that then sits in the guest until it restarts.
"""

from __future__ import annotations

import json
import shlex

from udeck_e2e import ax, config
from udeck_e2e.errors import LabError
from udeck_e2e.machine import Machine

WIDTH, HEIGHT = config.SCREEN_WIDTH, config.SCREEN_HEIGHT

SCREEN_SCRIPT = (
    'ObjC.import("AppKit");'
    "var s = $.NSScreen.mainScreen;"
    "JSON.stringify({width: s.frame.size.width, height: s.frame.size.height, scale: s.backingScaleFactor})"
)


def screen(machine: Machine) -> tuple[int, int, float]:
    """The main screen in points, and its scale, as the logged-in session sees it.

    Through `tart exec`, which runs inside that session; over SSH AppKit has no
    window server to ask. `system_profiler` prints nothing about displays in a VM.
    """
    step = f"reading {machine.name}'s screen size"
    done = machine.tart.exec(
        machine.name, ["/usr/bin/osascript", "-l", "JavaScript", "-e", SCREEN_SCRIPT], step, seconds=60
    )
    try:
        size = json.loads(done.stdout)
        return int(size["width"]), int(size["height"]), float(size["scale"])
    except (ValueError, KeyError, TypeError):
        raise LabError(step, f"unexpected answer {(done.stdout or done.stderr).strip()!r}") from None


POINTER_SCRIPT = (
    'ObjC.import("AppKit");'
    "var p = $.NSEvent.mouseLocation;"
    "var primary = $.NSScreen.screens.objectAtIndex(0);"
    "JSON.stringify({x: p.x, y: p.y, height: primary.frame.size.height})"
)


def pointer(machine: Machine) -> tuple[int, int]:
    """Where the guest's pointer is, in the coordinates `Machine.move_pointer` takes.

    AppKit counts from the bottom-left corner of the primary screen and in
    fractions (1279.996 for 1280); the lab counts pixels from the top-left, as
    in a screenshot. Through `tart exec`, which runs inside the logged-in session.

    On `--target here` there is no `tart exec` and no need for one: the lab runs
    inside the logged-in session, and the accessibility helper asks the window
    server, which counts from the top-left already.
    """
    step = f"reading where {machine.name}'s pointer is"
    if getattr(machine, "target", "tart") == "here":
        at = ax.ask(machine, ["pointer"], step)
        try:
            return round(float(at["x"])), round(float(at["y"]))
        except (KeyError, TypeError, ValueError):
            raise LabError(step, f"unexpected answer {at!r}") from None
    done = machine.tart.exec(
        machine.name, ["/usr/bin/osascript", "-l", "JavaScript", "-e", POINTER_SCRIPT], step, seconds=60
    )
    try:
        at = json.loads(done.stdout)
        return round(float(at["x"])), round(float(at["height"]) - float(at["y"]))
    except (ValueError, KeyError, TypeError):
        raise LabError(step, f"unexpected answer {(done.stdout or done.stderr).strip()!r}") from None


def spotlight_enabled(machine: Machine) -> bool:
    done = machine.ssh.ask("mdutil -s /", f"asking {machine.name} about Spotlight")
    return "Indexing enabled" in done.stdout


def running(machine: Machine, process: str) -> bool:
    done = machine.ssh.ask(f"pgrep -x {shlex.quote(process)}", f"looking for {process} on {machine.name}")
    return done.returncode == 0


def system_events_allowed(machine: Machine) -> tuple[bool, str]:
    """Whether a command over SSH may ask System Events about the interface."""
    script = (
        'with timeout of 20 seconds\n'
        'tell application "System Events" to get name of every process whose frontmost is true\n'
        'end timeout'
    )
    done = machine.ssh.ask(f"osascript -e {shlex.quote(script)}", f"asking System Events on {machine.name}", seconds=60)
    said = (done.stdout or done.stderr).strip()
    return done.returncode == 0, said


def _ask_system_events(machine: Machine, command: str, step: str) -> str:
    """One AppleScript command to System Events, with a deadline of its own, and its answer.

    The deadline is inside the script as well as around the SSH call: an
    AppleEvent nobody answers otherwise waits out the whole SSH deadline first.
    """
    script = (
        f"with timeout of {config.SYSTEM_EVENTS_SECONDS} seconds\n"
        f'tell application "System Events" to {command}\n'
        "end timeout"
    )
    # `run`, which raises on any exit but 0: a refusal is the lab failing to ask.
    return machine.ssh.run(f"osascript -e {shlex.quote(script)}", step).stdout.strip()


def frontmost(machine: Machine, step: str) -> str:
    """The name of the application in front, as System Events inside the guest sees it.

    The one a click or `open -a` last brought forward — and never uDeck. With
    the panel held open and uDeck holding the keyboard, System Events still named
    the application from before it, TextEdit, while uDeck's own log named uDeck
    as the workspace's frontmost (2026-09-21, .build/e2e/20260921-212357Z). That
    is the question the panel checks ask of it anyway: which *other* application
    the operator is left in.
    """
    name = _ask_system_events(machine, "get name of first application process whose frontmost is true", step)
    if not name:
        raise LabError(step, "System Events named no application in front")
    return name


def typed_into(machine: Machine, process: str, step: str) -> str:
    """What the text in `process`'s front window says: `text area 1 of scroll area 1 of window 1`.

    The one question that can tell where a keystroke landed. Which application
    is in front cannot: with the panel on screen and uDeck holding the keyboard,
    System Events still names the application from before it (see `frontmost`),
    so a key that went to uDeck and a key that went to that application look the
    same from outside. The document does not look the same.

    A window this cannot be read out of is the lab's failure — the helper
    refuses, and `ax.ask` raises — because a check reading "" would take a key
    that never arrived and a key that arrived somewhere unreadable for the same
    thing. Read by the accessibility helper, as System Events read it until
    2026-10-12, and stripped as osascript's answer was.
    """
    answer = ax.ask(machine, ["text", process], step)
    if not isinstance(answer.get("text"), str):
        raise LabError(step, f"the accessibility helper's answer has no text: {answer!r}")
    return answer["text"].strip()


DOCK_ITEMS_SCRIPT = (
    f"with timeout of {config.SYSTEM_EVENTS_SECONDS} seconds\n"
    'tell application "System Events" to tell process "Dock"\n'
    'set out to ""\n'
    "repeat with e in (UI elements of list 1)\n"
    "try\n"
    "set p to position of e\n"
    "set s to size of e\n"
    "set out to out & (name of e as text) & tab & (subrole of e as text) & tab & (item 1 of p) & tab & "
    "(item 2 of p) & tab & (item 1 of s) & tab & (item 2 of s) & linefeed\n"
    "end try\n"
    "end repeat\n"
    "return out\n"
    "end tell\n"
    "end timeout"
)


def dock_items(machine: Machine, step: str) -> list[tuple[str, str, float, float, float, float]]:
    """The Dock's items as System Events lists them: name, subrole, and the frame in screen points.

    The Dock's own row — `list 1` of its process — in its own order. An item
    whose position or size cannot be read is left out, as one that is not on
    the screen. Asked the way the scratch probes of 2026-10-16 asked it, which
    found the separators — `AXSeparatorDockItem`, one after the applications
    kept in the Dock and one before the Downloads stack — on a runner and in a
    Tart guest every time (`probe.dock-gap`, run 38918223759, 20261016-144410Z).
    """
    # `run`, which raises on any exit but 0: a refusal is the lab failing to ask.
    said = machine.ssh.run(f"osascript -e {shlex.quote(DOCK_ITEMS_SCRIPT)}", step).stdout
    items = []
    for line in said.splitlines():
        parts = line.split("\t")
        if len(parts) != 6:
            continue
        try:
            items.append((parts[0], parts[1], *(float(number) for number in parts[2:])))
        except ValueError:
            continue
    return items


def the_docks_separator(items: list[tuple[str, str, float, float, float, float]]) -> tuple[int, int] | None:
    """The middle of the Dock's separator — a place a click opens nothing and brings nothing forward — or None."""
    for _, subrole, x, y, width, height in items:
        if subrole == "AXSeparatorDockItem":
            return round(x + width / 2), round(y + height / 2)
    return None


def press_chord(machine: Machine, key_code: int, modifiers: tuple[str, ...], step: str) -> None:
    """Hold `modifiers` and press the key with `key_code`, from inside the guest.

    A virtual key code and not a character: it is the key in a position on the
    keyboard, which is what a global shortcut is registered for, and it says the
    same thing on both sides of the check (`HotKeyBinding.keyCodes`).

    The lab's other keystrokes are made over VNC, where they arrive at the
    machine's keyboard the way a key on a real one does. A chord cannot be made
    that way in this guest, and `panel.press_the_chord` is where that is
    written down.
    """
    held = ", ".join(f"{modifier} down" for modifier in modifiers)
    _ask_system_events(machine, f"key code {key_code} using {{{held}}}", step)


def move_window(machine: Machine, process: str, to: tuple[int, int], step: str) -> None:
    """Put the top-left corner of `process`'s front window at `to`, in screen points."""
    x, y = to
    ax.ask(machine, ["move-window", process, str(x), str(y)], step)


def guest_build(machine: Machine) -> str:
    return machine.ssh.run("sw_vers -buildVersion", f"reading {machine.name}'s macOS build").stdout.strip()


def languages(machine: Machine) -> tuple[str, str]:
    """The first preferred language and the locale."""
    done = machine.ssh.run(
        "defaults read -g AppleLanguages | sed -n 2p | tr -d ' \",'; defaults read -g AppleLocale",
        f"reading {machine.name}'s language",
    )
    lines = done.stdout.split()
    return (lines[0] if lines else ""), (lines[1] if len(lines) > 1 else "")


def verify_golden(machine: Machine) -> None:
    """Everything the bake sets, read back from the running guest."""
    width, height, scale = screen(machine)
    if (width, height, scale) != (WIDTH, HEIGHT, 1.0):
        raise LabError("checking the screen", f"{width}×{height} at {scale}×, wanted {WIDTH}×{HEIGHT} at 1×")
    if not spotlight_enabled(machine):
        raise LabError("checking Spotlight", "indexing is not enabled after the restart")
    if running(machine, "NotificationCenter"):
        raise LabError("checking notifications", "NotificationCenter is running after the restart")
    if running(machine, "UserNotificationCenter"):
        raise LabError("checking for dialogs", "a system dialog (UserNotificationCenter) is open")
    language, locale = languages(machine)
    if (language, locale) != ("en", "en_US"):
        raise LabError("checking the language", f"{language} / {locale}, wanted en / en_US")
    allowed, said = system_events_allowed(machine)
    if not allowed:
        raise LabError("checking that SSH may drive System Events", said)
