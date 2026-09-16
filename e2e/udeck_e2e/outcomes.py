"""The three outcomes of a check, and what a run exits with."""

from __future__ import annotations

from collections.abc import Iterable
from enum import Enum


class Outcome(Enum):
    PASSED = "passed"
    FAILED = "failed"
    COULD_NOT_CHECK = "could-not-check"

    @property
    def mark(self) -> str:
        return {"passed": "✅", "failed": "❌", "could-not-check": "⚠️"}[self.value]

    @property
    def words(self) -> str:
        return {"passed": "passed", "failed": "failed", "could-not-check": "could not check"}[
            self.value
        ]


EXIT_PASSED = 0
EXIT_FAILED = 1
EXIT_NOT_CHECKED = 2


def exit_code(outcomes: Iterable[Outcome], lab_problems: int = 0) -> int:
    """0 only when at least one check ran and every check passed.

    A failure wins over anything the lab could not do, because a failure is
    evidence about uDeck and the rest is not. Otherwise anything short of a
    clean run — a check that could not be carried out, a clone that could not
    be cleaned up, or no checks at all — exits 2, never 0.
    """
    outcomes = list(outcomes)
    if Outcome.FAILED in outcomes:
        return EXIT_FAILED
    if not outcomes or Outcome.COULD_NOT_CHECK in outcomes or lab_problems:
        return EXIT_NOT_CHECKED
    return EXIT_PASSED


def summary(outcomes: Iterable[Outcome], seconds: float) -> str:
    outcomes = list(outcomes)
    counts = [
        f"{sum(1 for o in outcomes if o is kind)} {kind.words}"
        for kind in Outcome
        if kind in outcomes
    ]
    return f"{', '.join(counts) or 'nothing checked'} in {duration(seconds)}"


def duration(seconds: float) -> str:
    seconds = int(round(seconds))
    if seconds < 60:
        return f"{seconds}s"
    minutes, seconds = divmod(seconds, 60)
    if minutes < 60:
        return f"{minutes}m{seconds:02d}s"
    hours, minutes = divmod(minutes, 60)
    return f"{hours}h{minutes:02d}m{seconds:02d}s"
