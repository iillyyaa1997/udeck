"""A run's verdicts as one Markdown table, read back out of its ledger — for GitHub's job summary.

    python -m udeck_e2e.report [RUN_DIR] >> "$GITHUB_STEP_SUMMARY"
    python -m udeck_e2e.report --annotations [RUN_DIR]

The ledger (`ledger.jsonl` in the run's directory) is what the lab wrote while it
ran, so the table says what the console said: every check with its outcome, how
long it took and, for anything but a pass, why. A check that never started is a
row too, and so is a run that stopped before any check — a table that leaves a
check out reads as a check that passed.

Without RUN_DIR it takes the newest run under `.build/e2e/` of the checkout.

`--annotations` prints, instead, a `::warning::` workflow command for each check
that was not on this target: such a check leaves the exit code to the checks
that ran, so a job can be green without having run it, and the warning says on
the run's own page which ones it did not run and why.
"""

from __future__ import annotations

import json
import sys
from collections.abc import Iterable
from pathlib import Path
from typing import Any

from udeck_e2e.outcomes import Outcome, duration

E2E_ROOT = Path(__file__).resolve().parent.parent.parent / ".build" / "e2e"


def read_ledger(path: Path) -> list[dict[str, Any]]:
    """The ledger's events; a line that is not one is skipped, and the table says how many were."""
    events = []
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        try:
            event = json.loads(line)
        except ValueError:
            event = {"event": "unreadable"}
        if isinstance(event, dict):
            events.append(event)
    return events


def _cell(text: str) -> str:
    """Text a Markdown table cell can hold: one line, no column breaks."""
    return " ".join(str(text).split()).replace("|", "\\|")


def table(events: Iterable[dict[str, Any]], title: str = "") -> str:
    """The verdicts of one run as Markdown: a count line, then a row per check."""
    events = list(events)
    start = next((e for e in events if e.get("event") == "run-start"), {})
    end = next((e for e in events if e.get("event") == "run-end"), None)
    checks: dict[str, dict[str, Any]] = {}
    for event in events:
        if event.get("event") == "check" and isinstance(event.get("name"), str):
            checks[event["name"]] = event
    words = {outcome.value: outcome for outcome in Outcome}

    lines = [f"### {_cell(title)}" if title else "### The lab"]
    target = start.get("target") or "tart"
    shard = start.get("shard")
    about = f"target `{target}`" + (f", part {shard[0]} of {shard[1]}" if isinstance(shard, list) and len(shard) == 2 else "")
    counts: dict[str, int] = {}
    rows = []
    for name in start.get("checks") or list(checks):
        event = checks.get(name)
        if event is None:
            outcome, seconds, reason = None, None, "never started"
        else:
            outcome = words.get(event.get("outcome"))
            seconds = event.get("seconds")
            reason = event.get("reason") or ""
        label = outcome.words if outcome else "never started"
        counts[label] = counts.get(label, 0) + 1
        mark = outcome.mark if outcome else "⚠️"
        took = duration(seconds) if isinstance(seconds, (int, float)) else ""
        rows.append(f"| {mark} | `{_cell(name)}` | {label} | {took} | {_cell(reason)} |")
    summary = ", ".join(f"{count} {label}" for label, count in counts.items()) or "no checks"
    if end is not None:
        summary += f" in {duration(end.get('seconds') or 0)}, exit {end.get('exit_code')}"
        problems = end.get("lab_problems") or []
        if problems:
            summary += f"; lab problems: {_cell('; '.join(map(str, problems)))}"
    else:
        summary += " — the run did not finish"
    for event in events:
        if event.get("event") == "preflight":
            for problem in event.get("problems") or []:
                what = problem.get("what") if isinstance(problem, dict) else problem
                summary += f"; could not start: {_cell(str(what))}"
    lines += [f"{about}: {summary}", "", "| | check | outcome | took | why |", "|---|---|---|---|---|", *rows]
    if not rows:
        lines.append("| ⚠️ | — | nothing ran | | the ledger names no check |")
    unreadable = sum(1 for e in events if e.get("event") == "unreadable")
    if unreadable:
        lines.append(f"\n{unreadable} line(s) of the ledger could not be read.")
    return "\n".join(lines) + "\n"


def _command_data(text: str) -> str:
    """Text a workflow command's message can carry: GitHub's own escapes."""
    return str(text).replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")


def _command_property(text: str) -> str:
    """Text a workflow command's property (its title) can carry."""
    return _command_data(text).replace(":", "%3A").replace(",", "%2C")


def annotations(events: Iterable[dict[str, Any]]) -> list[str]:
    """A `::warning::` workflow command for every check of the run that was not on this target."""
    checks: dict[str, dict[str, Any]] = {}
    for event in events:
        if event.get("event") == "check" and isinstance(event.get("name"), str):
            checks[event["name"]] = event
    return [
        f"::warning title={_command_property(f'Not on this target: {name}')}::"
        + _command_data(f"{name} did not run here, and neither passed nor failed: {event.get('reason') or 'it needs a virtual machine'}")
        for name, event in checks.items()
        if event.get("outcome") == Outcome.NOT_ON_THIS_TARGET.value
    ]


def newest_run(root: Path = E2E_ROOT) -> Path | None:
    """The newest run's directory under `root` — they are named by the time they started."""
    runs = sorted(p for p in root.glob("[0-9]*-[0-9]*Z") if (p / "ledger.jsonl").is_file())
    return runs[-1] if runs else None


def main(argv: list[str] | None = None) -> int:
    args = list(sys.argv[1:] if argv is None else argv)
    warnings = bool(args) and args[0] == "--annotations"
    if warnings:
        args = args[1:]
    run = Path(args[0]) if args else newest_run()
    if run is None or not (run / "ledger.jsonl").is_file():
        if not warnings:
            print("### The lab\n\nNo run of the lab left a ledger, so there is nothing to report.")
        return 2
    if warnings:
        for line in annotations(read_ledger(run / "ledger.jsonl")):
            print(line)
        return 0
    print(table(read_ledger(run / "ledger.jsonl"), title=" ".join(args[1:])), end="")
    return 0


if __name__ == "__main__":
    sys.exit(main())
