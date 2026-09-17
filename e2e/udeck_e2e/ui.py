"""Driving uDeck's own interface in the guest, the way a person drives it.

A control is found by the accessibility identifier the application gives it —
titles are translated, and the update buttons had no accessible name at all until
`0a3d785` — and then it is *clicked with the machine's pointer*, at the place the
accessibility API says it is.

Both halves were measured in a guest (2026-09-17) and neither is the obvious one:

* System Events' `entire contents` of uDeck's settings window returns nothing, so
  no `whose value of attribute "AXIdentifier" is …` can reach a control. The tree
  has to be walked child by child; the identifiers sit as deep as level 8.
* Clicking an element through System Events (`click`, or `perform action
  "AXPress"`) does *not* select a section of the settings window — the window
  stays where it was. A real click at the element's own coordinates does, and it
  goes through the same virtual pointing device a person's mouse would (Q15).

So: the accessibility API answers *where*, and the pointer does the pressing.
"""

from __future__ import annotations

import shlex
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from udeck_e2e import config
from udeck_e2e.errors import LabError

SETTINGS_WINDOW = "uDeck Settings"
PROCESS = "uDeck"

# How deep the walk goes. Measured: the sidebar's identifiers are at level 8, the
# About pane's at level 7; twelve leaves room without letting a loop run away.
MAX_DEPTH = 12

_FIND = """
on findIt(e, wanted, depth)
  try
    tell application "System Events" to set theId to value of attribute "AXIdentifier" of e
    if theId is wanted then return e
  end try
  if depth < %(depth)d then
    try
      tell application "System Events" to set kids to UI elements of e
      repeat with k in kids
        set found to findIt(k, wanted, depth + 1)
        if found is not missing value then return found
      end repeat
    end try
  end if
  return missing value
end findIt

tell application "System Events" to tell process %(process)s
  set w to first window whose name is %(window)s
end tell
set target to findIt(w, %(identifier)s, 0)
if target is missing value then return "not found"
tell application "System Events"
  set p to value of attribute "AXPosition" of target
  set s to value of attribute "AXSize" of target
end tell
return ((item 1 of p) as text) & "," & ((item 2 of p) as text) & "," & ((item 1 of s) as text) & "," & ((item 2 of s) as text)
"""

_LIST = """
on describe(e, depth)
  set out to {}
  set theRole to ""
  set theId to ""
  try
    tell application "System Events" to set theRole to role of e
  end try
  try
    tell application "System Events" to set theId to value of attribute "AXIdentifier" of e
  end try
  if theId is not "" and theId is not missing value then set end of out to (theRole & " [" & theId & "]")
  if depth < %(depth)d then
    try
      tell application "System Events" to set kids to UI elements of e
      repeat with k in kids
        set out to out & describe(k, depth + 1)
      end repeat
    end try
  end if
  return out
end describe

tell application "System Events" to tell process %(process)s
  set w to first window whose name is %(window)s
end tell
set report to describe(w, 0)
set text item delimiters to ", "
return report as text
"""

_TEXTS = """
on collect(e, depth)
  set out to {}
  try
    tell application "System Events" to set theRole to role of e
    if theRole is "AXStaticText" then
      set theValue to ""
      try
        tell application "System Events" to set theValue to value of e
      end try
      if theValue is "" or theValue is missing value then
        try
          tell application "System Events" to set theValue to name of e
        end try
      end if
      if theValue is not "" and theValue is not missing value then set end of out to theValue
    end if
  end try
  if depth < %(depth)d then
    try
      tell application "System Events" to set kids to UI elements of e
      repeat with k in kids
        set out to out & collect(k, depth + 1)
      end repeat
    end try
  end if
  return out
end collect

tell application "System Events" to tell process %(process)s
  set w to first window whose name is %(window)s
end tell
set report to collect(w, 0)
set text item delimiters to " | "
return report as text
"""

_OPEN_SETTINGS = """
tell application "System Events" to tell process %(process)s
  click menu item %(item)s of menu 1 of menu bar item 1 of menu bar 1
end tell
return "opened"
"""

_WINDOWS = """
tell application "System Events" to tell process %(process)s to get name of every window
"""


def _applescript(script: str, **values: str) -> str:
    """The script with its strings quoted as AppleScript literals."""
    quoted = {key: '"' + str(value).replace("\\", "\\\\").replace('"', '\\"') + '"' for key, value in values.items()}
    return script % {"depth": MAX_DEPTH, **quoted}


@dataclass(frozen=True)
class Element:
    """Where a control is, in the coordinates a screenshot and the pointer use."""

    identifier: str
    x: int
    y: int
    width: int
    height: int

    @property
    def middle(self) -> tuple[int, int]:
        return self.x + self.width // 2, self.y + self.height // 2


def parse_element(identifier: str, answer: str) -> Element | None:
    """`x,y,width,height` from the script, or None when it found nothing."""
    answer = answer.strip()
    if not answer or answer == "not found":
        return None
    parts = answer.split(",")
    if len(parts) != 4:
        raise ValueError(f"unexpected answer {answer!r}")
    x, y, width, height = (int(float(part)) for part in parts)
    return Element(identifier, x, y, width, height)


def ask(machine: Any, script: str, step: str, seconds: float = config.UI_SECONDS) -> str:
    """Run one AppleScript in the guest, over SSH — the only channel that may drive the interface."""
    done = machine.ssh.run(f"osascript -e {shlex.quote(script)}", step, seconds=seconds, check=False)
    answer = (done.stdout or "").strip()
    if done.returncode != 0:
        said = (done.stderr or "").strip().splitlines()
        raise LabError(step, f"System Events refused: {said[-1] if said else f'exit {done.returncode}'}")
    return answer


def windows(machine: Any, step: str) -> list[str]:
    return [name.strip() for name in ask(machine, _applescript(_WINDOWS, process=PROCESS), step).split(",") if name.strip()]


def identifiers(machine: Any, step: str, window: str = SETTINGS_WINDOW) -> list[str]:
    """Every control in `window` that carries an identifier — for a report, or a reason."""
    answer = ask(machine, _applescript(_LIST, process=PROCESS, window=window), step)
    return [part.strip() for part in answer.split(",") if part.strip()]


def static_texts(machine: Any, step: str, window: str = SETTINGS_WINDOW) -> list[str]:
    """Every sentence the window shows, in order — what a person would read on it."""
    answer = ask(machine, _applescript(_TEXTS, process=PROCESS, window=window), step)
    return [part.strip() for part in answer.split(" | ") if part.strip()]


def find(machine: Any, identifier: str, step: str, window: str = SETTINGS_WINDOW) -> Element | None:
    answer = ask(machine, _applescript(_FIND, process=PROCESS, window=window, identifier=identifier), step)
    try:
        return parse_element(identifier, answer)
    except ValueError as error:
        raise LabError(step, str(error)) from None


def wait_for(machine: Any, identifier: str, step: str, window: str = SETTINGS_WINDOW,
             seconds: float = config.UI_APPEAR_SECONDS) -> Element:
    """Until the control is there. What is there instead goes into the reason."""
    deadline = machine.clock() + seconds
    while True:
        element = find(machine, identifier, step, window)
        if element is not None:
            return element
        if machine.clock() >= deadline:
            raise LabError(
                step,
                f"'{identifier}' did not appear in '{window}' within {seconds:.0f}s; "
                f"what is there: {', '.join(identifiers(machine, step, window)) or 'nothing with an identifier'}",
            )
        machine.sleep(1)


def click(machine: Any, identifier: str, step: str, window: str = SETTINGS_WINDOW) -> Element:
    """Find the control and click it with the machine's pointer, where a person would."""
    element = wait_for(machine, identifier, step, window)
    machine.click(*element.middle, f"{step}: '{identifier}'")
    return element


def open_settings(machine: Any, step: str, item: str = "Settings…") -> None:
    """uDeck's settings window, opened from its own menu."""
    ask(machine, _applescript(_OPEN_SETTINGS, process=PROCESS, item=item), step)
