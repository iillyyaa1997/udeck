"""Driving uDeck's own interface in the guest, the way a person drives it.

A control is found by the accessibility identifier the application gives it —
titles are translated, and the update buttons had no accessible name at all until
`0a3d785` — and then it is *clicked with the machine's pointer*, at the place the
accessibility API says it is.

Both halves were measured in a guest (2026-09-17) and neither is the obvious one:

* The tree has to be walked child by child: System Events' `entire contents` of
  uDeck's settings window returned nothing, and the identifiers sit as deep as
  level 8.
* Clicking an element through the accessibility API (`click` in System Events,
  `AXPress`) does *not* select a section of the settings window — the window
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

**Who answers *where*.** The lab's own accessibility helper (`e2e/guest/ax.swift`,
`udeck_e2e.ax`), run where uDeck runs. Until 2026-10-12 it was System Events,
asked with AppleScript over SSH, one Apple event per attribute per element — on
Settings → Plugins a walk took 40 to 76 s and sometimes longer than the lab
allows. The helper reads what System Events read (the same elements, the same
attributes, the same text; its header says how that was measured, and
`e2e/selfcheck/check_ax.py` holds the two against each other in a guest) and
takes a tenth of a second. What it prints is turned into the lines this module
has always handed its callers (`ax.dump`), so nothing that reads a walk changed.
System Events is still what *types*: a keystroke is not something the
accessibility API can make (`choose_folder`, `type_text`, and the chords in
`probes`).

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

**And on a small screen a control can be out of the pointer's reach.** The walk
says, for each control, whether its middle is inside its window, every scroll
area around it and the screen (`Element.shown`). In a Tart guest every settings
pane the checks press in fits its window, and a click goes where the walk said,
as it always has. On `--target here` the runner's screen is smaller than the
guest's and Settings → Plugins is longer than its window there, so `click`
scrolls the pane until the control is in view before it presses it (`in_view`) —
and says so, as the lab's failure, if scrolling does not bring it there. Only
for a settings window: the panel's own frame trails its animation (measured on
a runner, run 38213314297, a card's Allow outside the frame the panel reported),
and nothing in it scrolls out of reach.
"""

from __future__ import annotations

import shlex
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from udeck_e2e import ax, config
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

# A value of several lines — the end of a plugin's standard error, under More —
# is printed on one, each line break as `⏎`: the line that describes a control
# is one line, and `controls` refuses one that is not.
LINE_BREAK = ax.LINE_BREAK

# How deep `identified` looks. The Plugins pane's controls are at 5 (the dump
# kept in .build/e2e/20260928-215137Z/plugins.install-fetches-one-folder/), the
# panel's cards deeper; one level of room over the deepest seen.
IDENTIFIED_DEPTH = 6

# What the lab asks the guest — inside the guest — when the way into the
# settings window is not there. `AppleLanguages` is the list macOS resolves an
# application's language from, and it is the answer to the likeliest reason:
# the menu item is found by its *title*, and every title uDeck draws is
# translated.
_GUEST_LANGUAGE = "defaults read -g AppleLanguages 2>/dev/null | tr -d ' \\n' || true"


# The panel, as every question here addresses a window: not by a title — it has
# none to find it by — but by the subrole uDeck gives it, `AXSystemDialog`
# (docs/plugin-repository.md, "The lab's checks").
PANEL = "the panel"


def _applescript(script: str, **values: str) -> str:
    """The script with its strings quoted as AppleScript literals — for what System Events still does: typing."""
    quoted = {key: '"' + str(value).replace("\\", "\\\\").replace('"', '\\"') + '"' for key, value in values.items()}
    return script % {"depth": MAX_DEPTH, **quoted}


@dataclass(frozen=True)
class Element:
    """Where a control is, in the coordinates a screenshot and the pointer use.

    The position and the size are all a click needs, and all `find` asks for.
    The rest is filled in by the walk, which reads every attribute of every
    element so that a control carrying no identifier can still be recognised —
    by its role, by what it reads, and by where it sits among its own kind.
    `identifier` is empty for all of those, which is the whole reason the walk
    exists.

    `shown` is whether its middle was inside its window, every scroll area
    around it and the screen when the walk read it (`in_view`). True where
    nothing said otherwise — a walk recorded before the lab knew.
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
    shown: bool = True

    @property
    def middle(self) -> tuple[int, int]:
        return self.x + self.width // 2, self.y + self.height // 2

    def __str__(self) -> str:
        return (
            f"{self.role}/{self.subrole} id={self.identifier!r} title={self.title!r} "
            f"value={self.value!r} at {self.x},{self.y} {self.width}x{self.height}"
        )


def _element(found: ax.Walked) -> Element:
    x, y, width, height = (int(n) for n in (found.frame or (0, 0, 0, 0)))
    return Element(
        identifier=found.identifier, x=x, y=y, width=width, height=height, role=found.role,
        subrole=found.subrole, title=found.title, value=found.value, description=found.description,
        shown=found.shown,
    )  # fmt: skip


def ask(machine: Any, script: str, step: str, seconds: float = config.UI_SECONDS) -> str:
    """Run one AppleScript in the guest — what the helper cannot do, which is type."""
    done = machine.ssh.run(f"osascript -e {shlex.quote(script)}", step, seconds=seconds, check=False)
    answer = (done.stdout or "").strip()
    if done.returncode != 0:
        said = (done.stderr or "").strip().splitlines()
        raise LabError(step, f"System Events refused: {said[-1] if said else f'exit {done.returncode}'}")
    return answer


def walk(machine: Any, step: str, window: str = SETTINGS_WINDOW, depth: int = MAX_DEPTH) -> list[ax.Walked]:
    """Every element of `window`, in the walk's order, the window itself first."""
    answer = ax.ask(machine, ["walk", PROCESS, ax.window_spec(window, PANEL), str(depth)], step)
    try:
        found, _ = ax.parse_walk(answer)
    except ValueError as error:
        raise LabError(step, f"the accessibility helper's walk could not be read: {error}") from None
    return found


def windows(machine: Any, step: str) -> list[str]:
    """The titles of uDeck's windows."""
    return [title.strip() for title in ax.window_titles(machine, PROCESS, step) if title.strip()]


def identifiers(machine: Any, step: str, window: str = SETTINGS_WINDOW) -> list[str]:
    """Every control in `window` that carries an identifier — for a report, or a reason."""
    return ax.identifiers(walk(machine, step, window))


def static_texts(machine: Any, step: str, window: str = SETTINGS_WINDOW) -> list[str]:
    """Every sentence the window shows, in order — what a person would read on it."""
    return ax.static_texts(walk(machine, step, window))


def find(machine: Any, identifier: str, step: str, window: str = SETTINGS_WINDOW) -> Element | None:
    """The first control with this identifier, in the walk's order, or None."""
    found = ax.first_with(walk(machine, step, window), identifier)
    return None if found is None else _element(found)


def wait_for(machine: Any, identifier: str, step: str, window: str = SETTINGS_WINDOW,
             seconds: float = config.UI_APPEAR_SECONDS) -> Element:
    """Until the control is there. What is there instead goes into the reason.

    The deadline raises `NotThere`, and only the deadline: a check that reads
    "the control never appeared" as something uDeck did must be able to tell it
    apart from the helper refusing or the machine going away, which keep
    arriving as an ordinary `LabError` through `find`.
    """
    deadline = machine.clock() + seconds
    while True:
        element = find(machine, identifier, step, window)
        if element is not None:
            return _settled(machine, element, step, window, deadline)
        if machine.clock() >= deadline:
            raise NotThere(
                step,
                f"'{identifier}' did not appear in '{window}' within {seconds:.0f}s; "
                f"what is there: {', '.join(identifiers(machine, step, window)) or 'nothing with an identifier'}",
            )
        machine.sleep(1)


# How far apart two walks have to be that put a control in the same place
# before the lab aims at it (`_settled`).
SETTLED_SECONDS = 0.5


def _settled(machine: Any, element: Element, step: str, window: str, deadline: float) -> Element:
    """The control once it has stopped moving: two walks half a second apart put it in the same place.

    The panel grows from a peek on a spring, and a sheet slides down, and a
    control read while they move is read where it is passing through. Through
    System Events a walk took seconds, which no animation outlasts; the helper
    reads one in a tenth of a second, inside it — measured on a runner (run
    38224850163, plugins.permissions-change-only-offers): Hold read as the panel
    opened, clicked where it had been, and the action never started. A control
    still moving at the deadline is taken where it was last.
    """
    while machine.clock() < deadline:
        machine.sleep(SETTLED_SECONDS)
        again = find(machine, element.identifier, step, window)
        if again is None:
            continue
        if (again.x, again.y, again.width, again.height) == (element.x, element.y, element.width, element.height):
            return again
        element = again
    return element


# How many times the lab scrolls a pane to bring a control into view before it
# gives up on reaching it.
SCROLLS = 6


def in_view(machine: Any, identifier: str, step: str, window: str = SETTINGS_WINDOW) -> Element:
    """The control, scrolled into view on a machine that can scroll (`HereMachine.scroll`).

    A pane is scrolled by most of its height at a time towards the control,
    and walked again, until the walk says the control's middle is inside it. A
    control it cannot bring there is the lab's failure, said with where it was.
    A walk without the control — `wait_for` has just seen it, so a walk taken
    while SwiftUI rebuilds the pane — is walked again until the control is
    back; one still gone at the deadline is the lab's failure too, never
    `NotThere`, which only `wait_for`'s own deadline raises.
    """
    deadline = machine.clock() + config.UI_APPEAR_SECONDS
    attempt = 0
    while True:
        found = walk(machine, step, window)
        target = ax.first_with(found, identifier)
        if target is None:
            if machine.clock() >= deadline:
                raise LabError(
                    step,
                    f"'{identifier}' was in '{window}' and went from it while the lab scrolled to it, "
                    f"not back within {config.UI_APPEAR_SECONDS:.0f}s; what is there: "
                    f"{', '.join(ax.identifiers(found)) or 'nothing with an identifier'}",
                )
            machine.sleep(1)
            continue
        if target.shown:
            return _element(target)
        if attempt == SCROLLS:
            break
        scroll = getattr(machine, "scroll", None)
        area = _pane_around(found, target)
        if scroll is None or area is None or area.frame is None or target.frame is None:
            raise LabError(
                step,
                f"'{identifier}' is at {_element(target).x},{_element(target).y}, outside what '{window}' shows, "
                f"and {machine.name} cannot scroll it into view",
            )
        x, y, width, height = area.frame
        middle_y = target.frame[1] + target.frame[3] / 2
        # Content moves down for a positive distance: a control below the
        # pane's middle wants a negative one. A pane's height at most at a time.
        distance = max(-height * 0.8, min(height * 0.8, (y + height / 2) - middle_y))
        scroll(int(x + width / 2), int(y + height / 2), int(distance), f"{step}: scrolling to '{identifier}'")
        attempt += 1
    raise LabError(step, f"'{identifier}' stayed outside what '{window}' shows after {SCROLLS} scrolls")


def _pane_around(found: list[ax.Walked], target: ax.Walked) -> ax.Walked | None:
    """The innermost scroll area the walk passed through on its way to `target`."""
    ancestors: list[ax.Walked] = []
    for element in found:
        del ancestors[element.depth:]
        if element is target:
            return next((a for a in reversed(ancestors) if a.role == "AXScrollArea"), None)
        ancestors.append(element)
    return None


def click(machine: Any, identifier: str, step: str, window: str = SETTINGS_WINDOW) -> Element:
    """Find the control and click it with the machine's pointer, where a person would.

    Scrolled into view first where the machine can scroll and the control is
    out of reach in a settings window — the runner's small screen (`in_view`).
    """
    element = wait_for(machine, identifier, step, window)
    if not element.shown and window != PANEL and getattr(machine, "scroll", None) is not None:
        element = in_view(machine, identifier, step, window)
    machine.click(*element.middle, f"{step}: '{identifier}'")
    return element


def open_settings(machine: Any, step: str, item: str = "Settings…") -> None:
    """uDeck's settings window, opened from its own menu.

    By the item's *title*, which is the one place in this module that depends on
    a translated name — the menu item is what uDeck's status menu offers and it
    carries no identifier to find it by. So a guest that is not in English has
    no way in at all, and `open_settings_and_wait` says exactly that rather than
    timing out with a shrug.

    Pressed through the accessibility API, as System Events' `click menu item`
    pressed it: a menu's item has no place on the screen until the menu is open,
    and what is asked here is the window, not the menu.
    """
    ax.ask(machine, ["press-menu-item", PROCESS, item], step)


def menu_items(machine: Any, step: str) -> str:
    """The titles in uDeck's own menu, for a reason — never for a verdict.

    Evidence, so it answers with what went wrong instead of raising: it is read
    only when the lab has already failed to open the settings window, and a
    second failure on top of the first would replace the reason with itself.
    """
    try:
        titles = ax.ask(machine, ["menu", PROCESS], step).get("titles")
    except LabError as error:
        return f"(the menu could not be read: {error.reason})"
    if not isinstance(titles, list):
        return "(the menu could not be read)"
    return ", ".join(str(title) for title in titles) or "nothing"


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
                           seconds: float = config.UI_APPEAR_SECONDS, window: str = SETTINGS_WINDOW) -> None:
    """The settings window, opened and there — pressing the menu item again if it is not.

    The press is one shot, and it is made moments after uDeck was launched: a
    status item that has not been put in the menu bar yet makes the press
    refused, and a press that lands before the application is ready does nothing
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

    `window` is the window's title, translated too: a check that runs uDeck in
    another language names both (`RUSSIAN`).
    """
    deadline = machine.clock() + seconds
    last = ""
    while True:
        try:
            open_settings(machine, step, item)
            if window in windows(machine, step):
                return
            last = f"'{window}' is not among uDeck's windows"
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


def identified(machine: Any, step: str, window: str = SETTINGS_WINDOW, depth: int = IDENTIFIED_DEPTH) -> str:
    """The controls of `window` that carry an identifier, as `tree` prints them — and nothing else.

    No deeper than `depth`, the window itself left out. `controls`, `element`
    and `says` read it exactly as they read `tree`.
    """
    return ax.dump(walk(machine, step, window, depth), identified_only=True)


def tree(machine: Any, step: str, window: str = SETTINGS_WINDOW) -> str:
    """Every element of `window` as the walk printed it, one line each.

    Kept beside the check's report as it stands, because it is the evidence for
    every sentence a check says about an unnamed control: which controls were
    there, what they read, and where the click went.
    """
    return ax.dump(walk(machine, step, window))


def _pair(text: str) -> tuple[int, int]:
    """`AXPosition` and `AXSize` as the walk prints them: `790;198;`."""
    parts = [part for part in text.split(";") if part.strip()]
    return (int(float(parts[0])), int(float(parts[1]))) if len(parts) >= 2 else (0, 0)


def controls(dump: str, step: str = "reading uDeck's settings window") -> list[Element]:
    """The walk's lines as elements — and a line that will not read is an error.

    The walk prints nine fields separated by `|` — ten since the helper, the
    tenth `shown` or `hidden` (`Element.shown`) — so a control whose text holds
    a `|` prints as something else: more fields than that. Dropped quietly, such
    a line is a control missing from the screen — and the caller then says the
    only thing a missing control can mean there, which is "the Opening screen
    did not appear". That sentence is about SwiftUI, so the reader goes looking
    at uDeck's views, and the truth was a pipe in a label.

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
        shown = True
        if len(parts) == 10 and parts[9] in ("shown", "hidden"):
            shown = parts.pop() == "shown"
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
                shown=shown,
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


# --- The plugin screens -----------------------------------------------------------
#
# Settings → Plugins and the panel's cards carry identifiers on everything the
# plugin checks press or read (`PluginRepositoryViews.swift`, `DeckWindowView`,
# `PermissionRequestView`), so here nothing is found by where it sits: the walk
# is read for the control with that identifier, and what it says is its value,
# its title or its description, whichever the accessibility API filled in.

PLUGINS = "plugins"

# Where the settings window is put before the plugin screens are read. The
# Plugins pane is one long scroll — the installed plugins, then the catalogue —
# and a control below the window's lower edge has a place the accessibility API
# will report and a click there lands on nothing. The guest's screen is 2560 by
# 1440 (`config.GOLDEN_DISPLAY`); this is most of it.
SETTINGS_FRAME = (60, 40, 1500, 1360)

def place_settings(machine: Any, step: str, frame: tuple[int, int, int, int] = SETTINGS_FRAME,
                   window: str = SETTINGS_WINDOW) -> Element:
    """The settings window moved and sized to `frame`, and where it says it ended up.

    The system keeps a window on its screen, so on a screen smaller than the
    frame the window ends up smaller — and a control below its edge is then out
    of a click's reach until its pane is scrolled (`in_view`).
    """
    x, y, width, height = frame
    answer = ax.ask(machine, ["place", PROCESS, ax.window_spec(window, PANEL), *(str(n) for n in (x, y, width, height))], step)
    placed = answer.get("frame")
    if not (isinstance(placed, list) and len(placed) == 4 and all(isinstance(n, (int, float)) for n in placed)):
        raise LabError(step, f"the settings window could not be placed: {answer!r}")
    px, py, pw, ph = (int(n) for n in placed)
    return Element(window, px, py, pw, ph)


# How many times the Plugins section is clicked before the lab gives up on it.
PLUGINS_CLICKS = 3


def plugins_pane(machine: Any, step: str, language: "Language | None" = None) -> Element:
    """The settings window, open on Plugins and placed so that its long scroll fits.

    **The section is clicked again when the first click did not take.** Measured
    on 2026-09-29 (.build/e2e/20260928-221216Z, plugins.update-keeps-the-window
    and plugins.remove-leaves-nothing): right after the panel had been open, the
    settings window came up on General and one click on Plugins left it there —
    the click that brings uDeck's window forward is not always the one that
    chooses a row in it. A pane that never comes is still the lab's failure,
    after `PLUGINS_CLICKS` clicks: every one of them landed on the row the
    accessibility API placed.

    `language` is uDeck's when it is not English (`RUSSIAN`): the menu item and
    the window's title are translated, and every identifier is not.
    """
    item, window = (language.settings_item, language.settings_window) if language else ("Settings…", SETTINGS_WINDOW)
    open_settings_and_wait(machine, step, item=item, window=window)
    wait_for(machine, f"section.{PLUGINS}", f"{step}: waiting for the settings window", window)
    for attempt in range(1, PLUGINS_CLICKS + 1):
        click(machine, f"section.{PLUGINS}", f"{step}: choosing {PLUGINS.capitalize()}", window)
        try:
            wait_for(machine, "catalogue.enabled", f"{step}: waiting for the Plugins section", window,
                     seconds=config.UI_CHANGE_SECONDS)  # fmt: skip
            break
        except NotThere:
            if attempt == PLUGINS_CLICKS:
                raise
    return place_settings(machine, step, window=window)


@dataclass(frozen=True)
class Language:
    """uDeck in a language other than the guest's English: the two translated names the lab reaches the settings window by."""

    code: str
    settings_item: str
    settings_window: str


# uDeck's own words for them, in Russian.swift: `menuSettings` and `settingsWindowTitle`.
RUSSIAN = Language(code="ru", settings_item="Настройки…", settings_window="Настройки uDeck")


# --- The system's folder panel ------------------------------------------------------

_CHOOSE_FOLDER = """
tell application "System Events" to tell process %(process)s
  set frontmost to true
  keystroke "g" using {command down, shift down}
  delay 1.5
  keystroke %(path)s
  delay 1
  key code 36
  delay 2
  key code 36
end tell
return "chosen"
"""


def choose_folder(machine: Any, path: str, step: str) -> None:
    """In the folder panel uDeck has open, `path` chosen the way a person types one.

    ⌘⇧G opens the panel's "Go to the folder" field, the path is typed into it,
    Return goes there, and Return again presses the panel's own default button,
    which chooses the folder it is in. All of it from inside the guest through
    System Events, as every chord here is made (`panel.press_the_chord`): a chord
    over VNC does not survive the trip. What the panel did is for the caller to
    read back — the link made, the folder in the list — never this function's to
    assume.
    """
    ask(machine, _applescript(_CHOOSE_FOLDER, process=PROCESS, path=path), step, seconds=config.UI_APPEAR_SECONDS)


# --- A field typed into ---------------------------------------------------------------

_TYPE = """
tell application "System Events" to tell process %(process)s
  set frontmost to true
  keystroke %(text)s
end tell
return "typed"
"""


def type_text(machine: Any, text: str, step: str) -> None:
    """`text` typed into the field uDeck has focused, the way a person types it.

    From inside the guest through System Events, as every chord and the folder
    panel's path are (`choose_folder`): keys over VNC do not survive the trip.
    The field is focused first by a click of the pointer at it (`click`), and
    what it holds afterwards is for the caller to read back — its value is in
    the walk — never this function's to assume.
    """
    ask(machine, _applescript(_TYPE, process=PROCESS, text=text), step, seconds=config.UI_APPEAR_SECONDS)


def element(dump: str, identifier: str, step: str = "reading the screen") -> Element | None:
    """The control with this identifier in a walk, or None."""
    for row in controls(dump, step):
        if row.identifier == identifier:
            return row
    return None


def says(control: Element | None) -> str:
    """What a control says: its value, its title or its description, whichever is there."""
    if control is None:
        return ""
    return control.value or control.title or control.description


def reads(machine: Any, identifier: str, step: str, window: str = SETTINGS_WINDOW) -> str | None:
    """What the control with this identifier says now, or None when it is not there."""
    found = element(identified(machine, step, window), identifier, step)
    return None if found is None else says(found)
