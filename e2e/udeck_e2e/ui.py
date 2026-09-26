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
**That is the rule for every control on these screens, named or not**, and it is
worth saying twice because the unnamed ones look like the place to cheat: an
`AXPress` needs no coordinates and no screen, so a helper that reached for one
would look simpler and would quietly stop selecting anything. The pointer is
also what the operator has. A click made this way goes through the machine's
virtual pointing device, the same device the gesture checks push the panel open
with, so a setting changed here is a setting changed the way he changes it.

**And some of uDeck's controls have no name at all.** On the Opening screen not
one control carries an `AXIdentifier`, an `AXTitle` or an `AXDescription`
(measured 2026-09-25: every row of the walk with all three empty) — SwiftUI
gives a `Toggle` no accessible name of its own, and the label beside it in the
`Grid` is a separate element. The identifiers on that screen belong to the
sidebar and to nothing else. So those controls are found by *where they sit*
among their own kind, in the order `OpeningSettings` draws them, and the order
itself is held against that file by the lab's own tests rather than observed
here. What *is* observed before anything is clicked is that the row is at rest:
it has to read what uDeck's shipped defaults read, or the lab refuses to click.
That catches a pane still being built, a pane that is not this one and a machine
an earlier check left changed — all of them the lab failing to find the control,
never a verdict about uDeck. It does not catch a row laid out in another order,
and it cannot: four switches that all read on read the same however they are
arranged (`config.OPENING_SWITCHES_AT_REST` says so in its own words).

**A click at coordinates can miss, so it is read back.** Everything above
answers *where* a control is at the moment it was asked; the click lands a
moment later, and a window that moved, a pane that was still being built or a
pointer that did not arrive leaves the control exactly as it was. That is the
lab failing to press the control — so `press` walks the screen again and refuses
to return until the control says the click landed. Without it the miss travels:
the check goes on to read a settings file nothing changed and pronounces on
uDeck for a pointer that missed by a few points.
"""

from __future__ import annotations

import shlex
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from udeck_e2e import config
from udeck_e2e.errors import LabError, NotThere

SETTINGS_WINDOW = "uDeck Settings"
PROCESS = "uDeck"

# The section of the settings window the panel's two ways in live on, named as
# `SettingsView.Section` names it. The sidebar is the one part of these screens
# that does carry identifiers, `section.<name>`, and they are identifiers rather
# than titles because every title here is translated and the language is a
# setting inside this same window.
OPENING = "opening"

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

# Every attribute the walk asks for, in the order the dump prints them. Each one
# is a separate Apple event against a separate element, so the list is a budget
# as much as a list: the Opening screen is about sixty elements, and a walk of it
# took roughly two seconds measured.
#
# `AXValue` is what makes an unnamed control recognisable: a checkbox reads "1"
# or "0", so a row of them read together says which row it is.
_TREE = """
on attr(e, n)
  set v to ""
  try
    tell application "System Events" to set v to value of attribute n of e
  end try
  if v is missing value then return ""
  try
    if class of v is list then
      set t to ""
      repeat with one in v
        set t to t & (one as text) & ";"
      end repeat
      return t
    end if
    return v as text
  on error
    return "?"
  end try
end attr

on describe(e, depth)
  set out to {}
  set end of out to (depth as text) & "|" & my attr(e, "AXRole") & "|" & my attr(e, "AXSubrole") ¬
    & "|" & my attr(e, "AXIdentifier") & "|" & my attr(e, "AXTitle") & "|" & my attr(e, "AXValue") ¬
    & "|" & my attr(e, "AXDescription") & "|" & my attr(e, "AXPosition") & "|" & my attr(e, "AXSize")
  if depth < %(depth)d then
    try
      tell application "System Events" to set kids to UI elements of e
      repeat with k in kids
        set out to out & my describe(k, depth + 1)
      end repeat
    end try
  end if
  return out
end describe

tell application "System Events" to tell process %(process)s
  set w to first window whose name is %(window)s
end tell
set report to my describe(w, 0)
set text item delimiters to linefeed
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

_MENU_ITEMS = """
tell application "System Events" to tell process %(process)s
  set titles to name of every menu item of menu 1 of menu bar item 1 of menu bar 1
end tell
set text item delimiters to ", "
return titles as text
"""

# What the lab asks the guest — inside the guest — when the way into the
# settings window is not there. `AppleLanguages` is the list macOS resolves an
# application's language from, and it is the answer to the likeliest reason:
# the menu item is found by its *title*, and every title uDeck draws is
# translated.
_GUEST_LANGUAGE = "defaults read -g AppleLanguages 2>/dev/null | tr -d ' \\n' || true"


def _applescript(script: str, **values: str) -> str:
    """The script with its strings quoted as AppleScript literals."""
    quoted = {key: '"' + str(value).replace("\\", "\\\\").replace('"', '\\"') + '"' for key, value in values.items()}
    return script % {"depth": MAX_DEPTH, **quoted}


@dataclass(frozen=True)
class Element:
    """Where a control is, in the coordinates a screenshot and the pointer use.

    The position and the size are all a click needs, and all `find` asks for.
    The rest is filled in by `walk`, which reads every attribute of every
    element so that a control carrying no identifier can still be recognised —
    by its role, by what it reads, and by where it sits among its own kind.
    `identifier` is empty for all of those, which is the whole reason the walk
    exists.
    """

    identifier: str
    x: int
    y: int
    width: int
    height: int
    role: str = ""
    subrole: str = ""
    title: str = ""
    value: str = ""
    description: str = ""

    @property
    def middle(self) -> tuple[int, int]:
        return self.x + self.width // 2, self.y + self.height // 2

    def __str__(self) -> str:
        return (
            f"{self.role}/{self.subrole} id={self.identifier!r} title={self.title!r} "
            f"value={self.value!r} at {self.x},{self.y} {self.width}x{self.height}"
        )


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
    """Until the control is there. What is there instead goes into the reason.

    The deadline raises `NotThere`, and only the deadline: a check that reads
    "the control never appeared" as something uDeck did must be able to tell it
    apart from System Events refusing or the machine going away, which keep
    arriving as an ordinary `LabError` through `find`.
    """
    deadline = machine.clock() + seconds
    while True:
        element = find(machine, identifier, step, window)
        if element is not None:
            return element
        if machine.clock() >= deadline:
            raise NotThere(
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
    """uDeck's settings window, opened from its own menu.

    By the item's *title*, which is the one place in this module that depends on
    a translated name — the menu item is what uDeck's status menu offers and it
    carries no identifier to find it by. So a guest that is not in English has
    no way in at all, and `open_settings_and_wait` says exactly that rather than
    timing out with a shrug.
    """
    ask(machine, _applescript(_OPEN_SETTINGS, process=PROCESS, item=item), step)


def menu_items(machine: Any, step: str) -> str:
    """The titles in uDeck's own menu, for a reason — never for a verdict.

    Evidence, so it answers with what went wrong instead of raising: it is read
    only when the lab has already failed to open the settings window, and a
    second failure on top of the first would replace the reason with itself.
    """
    try:
        return ask(machine, _applescript(_MENU_ITEMS, process=PROCESS), step) or "nothing"
    except LabError as error:
        return f"(the menu could not be read: {error.reason})"


def guest_language(machine: Any, step: str) -> str:
    """Which languages the guest is in, asked inside the guest.

    Evidence like `menu_items`, and for the same reason. Asked of the guest and
    never of this Mac: what the lab's own host is set to says nothing about the
    machine the check is running on.
    """
    try:
        said = machine.ssh.run(_GUEST_LANGUAGE, step, check=False).stdout.strip()
    except LabError as error:
        return f"(the guest would not say: {error.reason})"
    return said or "(the guest said nothing)"


def open_settings_and_wait(machine: Any, step: str, item: str = "Settings…",
                           seconds: float = config.UI_APPEAR_SECONDS) -> None:
    """The settings window, opened and there — pressing the menu item again if it is not.

    The press is one shot, and it is made moments after uDeck was launched: a
    status item that has not been put in the menu bar yet makes System Events
    refuse, and a press that lands before the application is ready does nothing
    at all. Both are the lab being early rather than uDeck being wrong, so the
    press is repeated until the window is there — and pressing it again while it
    is open only brings it forward.

    **And the third reason it can fail is the guest's language**, which is worth
    naming because everything else in this module is built on not trusting
    translated names — and this one way in is a translated name. `item` is the
    title of uDeck's menu item, so on a guest that is not in English there is no
    such item, every press refuses, and both settings checks end here with
    nothing to say about uDeck. The reason carries the language the guest
    answers with and the titles its menu does offer, so that what a person reads
    is a lab that cannot reach the screen rather than a uDeck that would not
    open it.
    """
    deadline = machine.clock() + seconds
    last = ""
    while True:
        try:
            open_settings(machine, step, item)
            if SETTINGS_WINDOW in windows(machine, step):
                return
            last = f"'{SETTINGS_WINDOW}' is not among uDeck's windows"
        except LabError as error:
            last = error.reason
        if machine.clock() >= deadline:
            raise LabError(
                step,
                f"uDeck's settings window did not open within {seconds:.0f}s. The only way in is the menu "
                f"item titled '{item}', and that title is translated: the guest answers "
                f"{guest_language(machine, step)} and uDeck's own menu offers {menu_items(machine, step)}. "
                f"Last: {last}",
            )
        machine.sleep(1)


# --- Controls that have no name ---------------------------------------------------


def tree(machine: Any, step: str, window: str = SETTINGS_WINDOW) -> str:
    """Every element of `window` as the walk printed it, one line each.

    Kept beside the check's report as it stands, because it is the evidence for
    every sentence a check says about an unnamed control: which controls were
    there, what they read, and where the click went.
    """
    return ask(machine, _applescript(_TREE, process=PROCESS, window=window), step)


def _pair(text: str) -> tuple[int, int]:
    """`AXPosition` and `AXSize` as the walk prints them: `790;198;`."""
    parts = [part for part in text.split(";") if part.strip()]
    return (int(float(parts[0])), int(float(parts[1]))) if len(parts) >= 2 else (0, 0)


def controls(dump: str, step: str = "reading uDeck's settings window") -> list[Element]:
    """The walk's lines as elements — and a line that will not read is an error.

    The walk prints nine fields separated by `|`, so a control whose text holds
    a `|` or a line break prints as something else: more fields than nine, or
    two lines neither of which is a control. Dropped quietly, such a line is a
    control missing from the screen — and the caller then says the only thing a
    missing control can mean there, which is "the Opening screen did not
    appear". That sentence is about SwiftUI, so the reader goes looking at
    uDeck's views, and the truth was a pipe in a label.

    So a line that cannot be read comes out as the lab's failure with the line
    in it. Nothing here guesses at a broken line either: the rows are recognised
    by what they read, and a row read as something it is not would be clicked in
    the wrong place.
    """
    found = []
    for line in dump.splitlines():
        if not line.strip():
            continue
        parts = line.split("|")
        if len(parts) != 9 or not parts[0].strip().isdigit():
            raise LabError(
                step,
                f"the walk printed a line that is not a control — {len(parts)} fields where every control "
                f"has nine, so a control whose title or value holds a '|' or a line break would be lost "
                f"and the screen would come back one row short: {line!r}",
            )
        x, y = _pair(parts[7])
        width, height = _pair(parts[8])
        found.append(
            Element(
                identifier=parts[3], x=x, y=y, width=width, height=height,
                role=parts[1], subrole=parts[2], title=parts[4], value=parts[5], description=parts[6],
            )
        )  # fmt: skip
    return found


def modifier_buttons(dump: str, step: str = "reading the shortcut's modifiers") -> list[Element]:
    """The shortcut's four modifier buttons, left to right.

    They are the only `AXCheckBox` with the `AXToggle` subrole anywhere on the
    Opening screen — `.toggleStyle(.button)` in `OpeningSettings`, and nothing
    else on that screen is drawn that way — so the role pair finds the row and
    `x` puts them in the order `HotKeyModifier.allCases.sorted()` laid them out.
    """
    buttons = [row for row in controls(dump, step) if row.role == "AXCheckBox" and row.subrole == "AXToggle"]
    return sorted(buttons, key=lambda row: row.x)


def opening_switches(dump: str, step: str = "reading the Opening screen's switches") -> list[Element]:
    """The Opening screen's four plain checkboxes, top to bottom.

    Plain: an `AXCheckBox` with no subrole and no identifier, which on this
    screen is exactly the four `Toggle`s that are not the modifier buttons. `y`
    puts them in the order `OpeningSettings` lays them out.
    """
    found = [
        row for row in controls(dump, step)
        if row.role == "AXCheckBox" and not row.subrole and not row.identifier
    ]  # fmt: skip
    return sorted(found, key=lambda row: row.y)


@dataclass(frozen=True)
class OpeningScreen:
    """uDeck's Opening settings screen, with its unnamed controls placed.

    The two rows a check can reach: the shortcut's modifier buttons and the
    plain switches. Each is named by the setting it writes rather than by the
    sentence beside it, because the sentences are translated and the settings
    are not — `config.HOTKEY_MODIFIER_ROW` and `config.OPENING_SWITCHES` hold
    the two orders, against `OpeningSettings` in SettingsView.swift.

    `dump` is the walk that found them, for the check to keep as evidence.
    """

    dump: str
    modifiers: tuple[Element, ...]
    switches: tuple[Element, ...]

    def modifier(self, name: str) -> Element:
        """One of ⌃⌥⇧⌘, by the name uDeck's settings file spells it with."""
        return self.modifiers[config.HOTKEY_MODIFIER_ROW.index(name)]

    def switch(self, name: str) -> Element:
        """One of the four plain switches, by the setting it writes."""
        return self.switches[config.OPENING_SWITCHES.index(name)]


def opening(machine: Any, step: str, at_rest: bool = True,
            seconds: float = config.UI_APPEAR_SECONDS) -> OpeningScreen:
    """The settings window, open on Opening, walked, with its unnamed controls found.

    The wait is for the screen itself and not for a fixed number of seconds:
    choosing a section in the sidebar is a click, and what follows it is SwiftUI
    building the pane. So the walk is repeated until both rows are there, which
    on a machine that is answering is the first walk.

    `at_rest` is the caller saying it expects uDeck's shipped defaults: the
    modifier row reads on, on, off, off for the default `{control, option}`
    binding, and all four switches read on. A caller that has already changed
    one of them passes False, because the row no longer reads what a default one
    does — and then the shape alone is what names it.

    **What that reading proves, exactly.** That these eight controls are uDeck's
    own and that nothing has moved them yet: a pane still being built, a
    different pane, or a machine a neighbouring check left changed all read
    something else, and then nothing here is clicked. It does *not* prove the
    order within either row, and cannot — all four switches read alike, and the
    modifier row survives swapping its two ons — so `switch` and `modifier`
    below take the order from `config`, which holds it against the source that
    draws the row (`test_the_plain_switches_are_in_the_order_uDeck_lays_them_out`).

    Anything that goes wrong here is the lab's: a screen it could not find the
    controls on is a screen it must not click on, and a check that clicked
    somewhere else would be a sentence about uDeck written from a random pixel.
    """
    open_settings_and_wait(machine, step)
    click(machine, f"section.{OPENING}", f"{step}: choosing {OPENING.capitalize()}")

    deadline = machine.clock() + seconds
    while True:
        dump = tree(machine, step)
        modifiers = modifier_buttons(dump, step)
        switches = opening_switches(dump, step)
        if len(modifiers) == len(config.HOTKEY_MODIFIER_ROW) and len(switches) == len(config.OPENING_SWITCHES):
            break
        if machine.clock() >= deadline:
            raise LabError(
                step,
                f"the Opening screen did not appear within {seconds:.0f}s: {len(modifiers)} modifier buttons "
                f"and {len(switches)} switches, where it has {len(config.HOTKEY_MODIFIER_ROW)} and "
                f"{len(config.OPENING_SWITCHES)}",
            )
        machine.sleep(1)

    if at_rest:
        for found, wanted, what in (
            (modifiers, config.HOTKEY_MODIFIER_ROW_AT_REST, "modifier buttons"),
            (switches, config.OPENING_SWITCHES_AT_REST, "switches"),
        ):
            reads = tuple(row.value for row in found)
            if reads != wanted:
                raise LabError(
                    step,
                    f"the Opening screen's {what} read {reads}, and a machine at rest reads {wanted} — "
                    f"this is not the row, or the machine is not at rest: {[str(row) for row in found]}",
                )
    return OpeningScreen(dump, tuple(modifiers), tuple(switches))


def where_it_was(dump: str, control: Element, step: str) -> Element | None:
    """The control standing where this one stood, as the walk reads it now.

    By place and kind rather than by anything it says: what the caller wants to
    know is whether *that* control changed, and the one thing it must not use to
    recognise it is the value it is asking about.
    """
    for row in controls(dump, step):
        if (row.role, row.subrole, row.x, row.y) == (control.role, control.subrole, control.x, control.y):
            return row
    return None


def press(machine: Any, control: Element, step: str, window: str = SETTINGS_WINDOW,
          seconds: float = config.UI_CHANGE_SECONDS) -> Element:
    """Click a control the walk found, and read it back until it says the click landed.

    The pressing is the same `click` does, for the controls `find` cannot reach
    because they carry no identifier. Why the pointer and not `AXPress` is the
    module's own docstring, and it is the whole reason this is a click at
    coordinates and not an accessibility action.

    **And it is the reason the control is read back.** A click at coordinates is
    aimed at where the accessibility API said the control was a moment earlier,
    and a window that moved, a pane still being laid out or a pointer that did
    not arrive leaves the screen exactly as it was. Nothing about that is uDeck:
    it is the lab failing to press the control, the same failure as not finding
    it. Unread, it becomes a verdict several steps later — the settings file
    holds nothing, and the check says the operator's change is nowhere, about a
    uDeck that was never asked for one.

    So the screen is walked again until the control at that place reads
    something other than what it read, and a control that does not is a
    `LabError` naming where the click went and what it found there. It is *not*
    a statement that uDeck saved anything: what the control reads is the
    control, and what uDeck did about it is the check's own question.
    """
    machine.click(*control.middle, f"{step}: {control}")
    deadline = machine.clock() + seconds
    while True:
        after = where_it_was(tree(machine, step, window), control, step)
        if after is not None and after.value != control.value:
            return after
        if machine.clock() >= deadline:
            x, y = control.middle
            raise LabError(
                step,
                f"the lab clicked {x},{y} for {control} and {seconds:.0f}s later "
                + (
                    f"it still reads {after.value!r}: the click did not land on it"
                    if after is not None
                    else "there is no control there at all: the screen moved under the click"
                ),
            )
        machine.sleep(1)
