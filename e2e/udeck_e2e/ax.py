"""The lab's accessibility helper (`e2e/guest/ax.swift`): built, put where uDeck runs, asked, and read.

The helper replaces System Events' AppleScript walks of uDeck's windows: the
same elements, the same attributes, the same text (its own header says how that
was measured), in a tenth of a second instead of up to minutes. This module is
everything the lab does with it on the Python side:

* **building** it — `xcrun swiftc -O`, once per version of the source, kept under
  `.build/e2e/ax/` by the source's sha256, for the one architecture and the
  oldest macOS the lab's guests run (`TARGET`);
* **asking** it — through `machine.ssh.run`, which is SSH into a Tart guest and a
  plain subprocess on `--target here`, so `ui` asks both targets the same way;
* **reading** it — its JSON, checked field by field, and turned into the lines
  `ui` has always handed its callers (`dump`), so that nothing that reads a walk
  had to change.

A walk is the lab's evidence for every sentence a check says about a control,
so a malformed answer is never patched over: it is the lab's failure, with the
answer in it.
"""

from __future__ import annotations

import hashlib
import json
import os
import shlex
import subprocess
from collections.abc import Callable, Iterable
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from udeck_e2e import config
from udeck_e2e.errors import LabError

Note = Callable[[str], None]

SOURCE = Path(__file__).resolve().parent.parent / "guest" / "ax.swift"

# Apple silicon, and the oldest macOS any guest of the lab runs: the Tart guests
# are 26 and 27 (`config.GUESTS`), GitHub's runner is 26.
TARGET = "arm64-apple-macos26.0"

# Where the helper is put inside a Tart guest: the logged-in user's own, so that
# it runs as that user, as everything the checks do there does.
GUEST_PATH = f"/Users/{config.GUEST_USER}/.udeck-e2e/ax"

# A compile of one file, cold: about fifteen seconds on a runner, measured
# (run 38209960064); this is a slow machine's allowance.
BUILD_SECONDS = 300

# One question to the helper. A walk of the busiest pane took 0.09 s on a runner;
# what this allows for is a uDeck that stops answering, which the helper itself
# waits six seconds per question for.
ASK_SECONDS = 60

# ssh's exit code for a connection it could not make (`guest.SSH_FAILED`); the
# helper itself exits 1 or 2.
SSH_FAILED = 255

# How a value of several lines is written on the one line that describes a
# control, as the AppleScript walk wrote it (`ui.LINE_BREAK`).
LINE_BREAK = "⏎"


# --- Building -----------------------------------------------------------------


def digest(source: Path = SOURCE, target: str = TARGET) -> str:
    """The source's sha256, with the target it is compiled for: what a cached binary is kept by."""
    hashed = hashlib.sha256(source.read_bytes())
    hashed.update(f"\0{target}".encode())
    return hashed.hexdigest()


def cached_path(cache_root: Path, source: Path = SOURCE, target: str = TARGET) -> Path:
    """Where the binary for this source and target is kept: `<cache_root>/ax/<digest>/ax`."""
    return cache_root / "ax" / digest(source, target)[:16] / "ax"


def build(
    cache_root: Path,
    note: Note,
    source: Path = SOURCE,
    target: str = TARGET,
    run: Callable[..., subprocess.CompletedProcess[str]] = subprocess.run,
) -> Path:
    """The helper's binary, compiled if this source has not been compiled before.

    Compiled into a file beside the final one and moved into place, so that a
    compile cut short never leaves a binary the next run would take for done.
    """
    step = "building the lab's accessibility helper"
    binary = cached_path(cache_root, source, target)
    if binary.is_file():
        return binary
    try:
        binary.parent.mkdir(parents=True, exist_ok=True)
    except OSError as error:
        raise LabError(step, f"could not prepare {binary.parent}: {error}") from None
    partial = binary.with_name("ax.partial")
    note(f"   building the accessibility helper ({source.name}, {digest(source, target)[:12]})")
    try:
        done = run(
            [
                "/usr/bin/xcrun", "swiftc", "-O", "-target", target,
                # Its own module cache, beside it, rather than one in the user's caches.
                "-module-cache-path", str(binary.parent.parent / "module-cache"),
                str(source), "-o", str(partial),
            ],
            capture_output=True,
            text=True,
            errors="replace",
            timeout=BUILD_SECONDS,
            check=False,
            stdin=subprocess.DEVNULL,
            start_new_session=True,
        )  # fmt: skip
    except subprocess.TimeoutExpired:
        partial.unlink(missing_ok=True)
        raise LabError(step, f"swiftc did not finish in {BUILD_SECONDS}s") from None
    except OSError as error:
        raise LabError(step, f"could not run xcrun swiftc: {error}") from None
    if done.returncode != 0 or not partial.is_file():
        partial.unlink(missing_ok=True)
        lines = (done.stderr or done.stdout or "").strip().splitlines()
        said = next((line for line in lines if "error:" in line), lines[-1] if lines else f"exit {done.returncode}")
        raise LabError(step, f"swiftc refused {source.name}: {said}")
    os.replace(partial, binary)
    return binary


# --- Asking -------------------------------------------------------------------


def command(path: str, *args: str) -> str:
    """The shell command that asks the helper at `path`."""
    return shlex.join([path, *args])


def ask(machine: Any, args: Iterable[str], step: str, seconds: float = ASK_SECONDS) -> dict[str, Any]:
    """One question to the helper where uDeck runs, and its answer as JSON.

    A refusal is the lab's — the helper's own words go into the reason — and so
    is an answer that is not one JSON object: nothing here guesses at a broken
    answer.
    """
    path = getattr(machine, "ax_path", None)
    if not path:
        raise LabError(step, f"{machine.name} has no accessibility helper (it is put there when the machine starts)")
    done = machine.ssh.run(command(path, *args), step, seconds=seconds, check=False)
    if done.returncode == SSH_FAILED:
        # ssh's own code for a connection that failed: the guest was never asked.
        said = (done.stderr or done.stdout or "").strip().splitlines()
        raise LabError(step, f"SSH to {getattr(machine.ssh, 'host', machine.name)} failed: {said[-1] if said else 'no output'}")
    if done.returncode != 0:
        said = (done.stderr or done.stdout or "").strip().splitlines()
        raise LabError(step, f"the accessibility helper refused: {said[-1] if said else f'exit {done.returncode}'}")
    try:
        answer = json.loads(done.stdout)
    except ValueError:
        raise LabError(step, f"the accessibility helper answered something that is not JSON: {done.stdout.strip()[:300]!r}") from None
    if not isinstance(answer, dict):
        raise LabError(step, f"the accessibility helper answered {answer!r}, not an object")
    return answer


def window_titles(machine: Any, process: str, step: str) -> list[str]:
    """The titles of `process`'s windows, the front one first."""
    answer = ask(machine, ["windows", process], step)
    found = answer.get("windows")
    if not isinstance(found, list) or not all(isinstance(w, dict) and isinstance(w.get("title"), str) for w in found):
        raise LabError(step, f"the accessibility helper's windows could not be read: {answer!r}")
    return [w["title"] for w in found]


def window_spec(window: str, panel: str) -> str:
    """How the helper names a window: the panel by its subrole, any other by its title."""
    return "panel" if window == panel else f"title={window}"


# --- Reading ------------------------------------------------------------------


@dataclass(frozen=True)
class Walked:
    """One element of a walk, as the helper read it."""

    depth: int
    role: str
    subrole: str
    identifier: str
    title: str
    value: str
    description: str
    # x, y, width, height in screen points from the top-left; None when the
    # element has no place.
    frame: tuple[float, float, float, float] | None
    # Whether its middle is inside the window, every scroll area around it and
    # the display: where a click at it lands on it.
    shown: bool
    enabled: bool | None = None


_TEXT_FIELDS = ("role", "subrole", "identifier", "title", "value", "description")


def parse_walk(text: str) -> tuple[list[Walked], float]:
    """A walk's elements and how long it took, or ValueError naming what is wrong."""
    answer = json.loads(text) if isinstance(text, str) else text
    if not isinstance(answer, dict) or not isinstance(answer.get("elements"), list):
        raise ValueError(f"a walk has a list of elements, and this has none: {str(answer)[:200]!r}")
    found = []
    for index, raw in enumerate(answer["elements"]):
        if not isinstance(raw, dict):
            raise ValueError(f"element {index} is {raw!r}, not an object")
        depth = raw.get("depth")
        if not isinstance(depth, int) or isinstance(depth, bool) or depth < 0:
            raise ValueError(f"element {index} has no depth: {raw!r}")
        texts = {name: raw.get(name) for name in _TEXT_FIELDS}
        wrong = [name for name, value in texts.items() if not isinstance(value, str)]
        if wrong:
            raise ValueError(f"element {index} has no text for {', '.join(wrong)}: {raw!r}")
        frame = raw.get("frame")
        if frame is not None:
            if (
                not isinstance(frame, list)
                or len(frame) != 4
                or not all(isinstance(n, (int, float)) and not isinstance(n, bool) for n in frame)
            ):
                raise ValueError(f"element {index} has a frame that is not four numbers: {frame!r}")
            frame = tuple(float(n) for n in frame)
        enabled = raw.get("enabled")
        found.append(
            Walked(
                depth=depth,
                frame=frame,
                shown=raw.get("shown") is True,
                enabled=enabled if isinstance(enabled, bool) else None,
                **texts,
            )
        )
    if found and found[0].depth != 0:
        raise ValueError(f"a walk starts at its window, at depth 0, and this one starts at {found[0].depth}")
    seconds = answer.get("seconds", 0.0)
    return found, float(seconds) if isinstance(seconds, (int, float)) and not isinstance(seconds, bool) else 0.0


def _point(numbers: tuple[float, float] | None) -> str:
    """A pair as System Events printed it: whole points, cut toward zero, each followed by `;`.

    Measured on a runner: an element at y 88.79 read `88` there (run 38209960064).
    """
    return "" if numbers is None else f"{int(numbers[0])};{int(numbers[1])};"


def line(element: Walked) -> str:
    """One element as the AppleScript walk wrote it — nine fields between `|`, one line — and a tenth.

    The tenth is `shown` or `hidden` (`Walked.shown`), which System Events never
    said, so that a control read out of a dump still knows whether a click can
    reach it (`ui.Element.middle`). `ui.controls` reads both shapes.
    """
    position = None if element.frame is None else element.frame[:2]
    size = None if element.frame is None else element.frame[2:]
    fields = [
        str(element.depth), element.role, element.subrole, element.identifier, element.title,
        element.value, element.description, _point(position), _point(size),
    ]  # fmt: skip
    return "|".join([*(one_line(field) for field in fields), "shown" if element.shown else "hidden"])


def one_line(text: str) -> str:
    """Line breaks written as `LINE_BREAK`, the way the walk that kept only identified controls wrote them."""
    return text.replace("\r\n", LINE_BREAK).replace("\n", LINE_BREAK).replace("\r", LINE_BREAK)


def dump(elements: Iterable[Walked], identified_only: bool = False) -> str:
    """The walk as `ui.tree` (everything) or `ui.identified` (controls with an identifier, the window left out) returns it."""
    rows = [
        element for element in elements
        if not identified_only or (element.identifier and element.depth >= 1)
    ]  # fmt: skip
    return "\n".join(line(element) for element in rows)


def static_texts(elements: Iterable[Walked]) -> list[str]:
    """Every AXStaticText's words, in order: its value, or its title where the value is empty (`ui._TEXTS`)."""
    found = []
    for element in elements:
        if element.role != "AXStaticText":
            continue
        words = (element.value or element.title).strip()
        if words:
            found.append(words)
    return found


def identifiers(elements: Iterable[Walked]) -> list[str]:
    """`role [identifier]` for every element that carries one, the window included (`ui._LIST`)."""
    return [f"{element.role} [{element.identifier}]" for element in elements if element.identifier]


def first_with(elements: Iterable[Walked], identifier: str) -> Walked | None:
    """The first element in the walk's order with this identifier, the window included (`ui._FIND`)."""
    return next((element for element in elements if element.identifier == identifier), None)


# --- Two walks of one screen, held against each other ---------------------------


def differences(old: list[tuple[str, ...]], new: list[tuple[str, ...]], what: str) -> list[str]:
    """Row by row, where two readings of one screen disagree — empty when they are the same.

    Each row is whatever the caller compares by (`comparable`). The rows are
    compared in order, because the order is part of what a check reads: the
    Opening screen's switches are told apart by where they sit among their own
    kind.
    """
    problems = []
    if len(old) != len(new):
        problems.append(f"{what}: System Events read {len(old)} and the helper {len(new)}")
    for index, (a, b) in enumerate(zip(old, new)):
        if a != b:
            problems.append(f"{what} #{index}: System Events {a!r}, the helper {b!r}")
    for index, extra in enumerate(old[len(new):], len(new)):
        problems.append(f"{what} #{index}: only System Events read {extra!r}")
    for index, extra in enumerate(new[len(old):], len(old)):
        problems.append(f"{what} #{index}: only the helper read {extra!r}")
    return problems


# The window's own buttons in its title bar. What System Events listed inside
# them differs from `AXChildren` by one group in the full-screen button
# (measured in a guest, run 20261012-063626Z), and none of it is uDeck's: no
# check reads the title bar.
WINDOW_BUTTONS = frozenset({"AXCloseButton", "AXMinimizeButton", "AXFullScreenButton", "AXZoomButton"})


def without_the_title_bar(rows: list[tuple[str, ...]]) -> list[tuple[str, ...]]:
    """Walk rows — depth, role, subrole first — without what is inside the window's own buttons."""
    kept: list[tuple[str, ...]] = []
    inside: int | None = None
    for row in rows:
        depth = int(row[0])
        if inside is not None and depth > inside:
            continue
        inside = depth if row[1] == "AXButton" and row[2] in WINDOW_BUTTONS else None
        kept.append(row)
    return kept


def misreadings(
    old: list[tuple[str, ...]], new: list[tuple[str, ...]], same_words: Callable[[tuple, tuple], bool]
) -> list[tuple[int, tuple, tuple]]:
    """(index, System Events' row, the helper's row) for every row where System Events misread the control.

    One way System Events is wrong was measured, and only that one is let
    through: SwiftUI hands an AppleScript client *the first element* for
    elements that read alike, so every "Verified" of the catalogue came back
    as the first row's, with its identifier and its place (`_row_of` in the
    plugin checks was written around it). Such a row is a copy of an earlier
    row of System Events' own reading — the same identifier at the same place,
    which two controls cannot be — and the helper's row there is a control of
    its own, met for the first time in its reading, that says the same words
    from its own place: the helper read the control System Events misread, as
    the screenshot shows (run 20261012-063626Z, 04-settings-plugins.png).
    Readings of different lengths have no rows to pair, and nothing in them is
    a misreading.
    """
    if len(old) != len(new):
        return []
    return [
        (index, a, b)
        for index, (a, b) in enumerate(zip(old, new))
        if a != b and a in old[:index] and b not in new[:index] and same_words(a, b)
    ]


def held_against(
    old: list[tuple[str, ...]], new: list[tuple[str, ...]], what: str, same_words: Callable[[tuple, tuple], bool]
) -> tuple[list[str], list[str]]:
    """System Events' reading against the helper's, row by row: (what differs, what differs because System Events was wrong).

    What System Events was wrong about is `misreadings`, and nothing else:
    anything else that differs is a difference.
    """
    if len(old) != len(new):
        return differences(old, new, what), []
    misread = {index for index, _, _ in misreadings(old, new, same_words)}
    unexplained, explained = [], []
    for index, (a, b) in enumerate(zip(old, new)):
        if a == b:
            continue
        line = f"{what} #{index}: System Events {a!r}, the helper {b!r}"
        if index in misread:
            explained.append(line + " — System Events read an earlier element again")
        else:
            unexplained.append(line)
    return unexplained, explained


def same_control_words(a: tuple, b: tuple) -> bool:
    """Two walk rows — depth, role, subrole, identifier, title, value, description, place — that say the same words."""
    return (a[1], a[2], a[4], a[5], a[6]) == (b[1], b[2], b[4], b[5], b[6])


def misread_identifiers(old_rows: list[tuple[str, ...]], new_rows: list[tuple[str, ...]]) -> set[tuple[str, str]]:
    """(System Events' identifier, the helper's) of each control System Events misread in a walk of the whole tree.

    Walk rows as `same_control_words` takes them — depth, role, subrole,
    identifier first. A list of identifiers (`ui.identifiers`) carries no
    words to tell a misread control by, so a difference in one is explained
    only when the same screen's tree shows that very misreading
    (`same_identifier_misread`).
    """
    return {(a[3], b[3]) for _, a, b in misreadings(old_rows, new_rows, same_control_words)}


def same_identifier_misread(pairs: set[tuple[str, str]]) -> Callable[[tuple, tuple], bool]:
    """Two `role [identifier]` entries of the same role whose identifiers are a misreading the tree showed (`pairs`)."""

    def same(a: tuple, b: tuple) -> bool:
        role_a, _, id_a = a[0].partition(" [")
        role_b, _, id_b = b[0].partition(" [")
        return role_a == role_b and (id_a.removesuffix("]"), id_b.removesuffix("]")) in pairs

    return same
