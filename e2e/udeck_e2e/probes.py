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

from udeck_e2e import config
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
    """
    step = f"reading where {machine.name}'s pointer is"
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
