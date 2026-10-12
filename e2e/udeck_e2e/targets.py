"""Where a run's checks run (`--target`), and which checks need a virtual machine to run at all.

`tart`, the default, is a throwaway Tart guest per check (or per group, or per
run): the only target that can restart a machine, log out and back in, or start
from a machine nothing has run on. `here` is the machine running the lab, which
is only ever a GitHub-hosted runner (`here.refusal`).

A check that needs what only a virtual machine gives says so with
`needs_a_vm`, in the words the report will use, and on `--target here` it is
not run: its outcome is "not on this target", counted and listed beside the
others, and neither a pass nor a failure. Saying it up front, before the check
starts, is the point — a check that found out half-way would have done half of
what it does to the runner first.
"""

from __future__ import annotations

from collections.abc import Callable
from typing import Any

TART = "tart"
HERE = "here"
TARGETS = (TART, HERE)


def needs_a_vm(what: str) -> Callable[[Callable[..., Any]], Callable[..., Any]]:
    """Mark a check as one only a virtual machine can run, and say what it needs from one."""

    def mark(check: Callable[..., Any]) -> Callable[..., Any]:
        check.needs_a_vm = what  # type: ignore[attr-defined]
        return check

    return mark


def what_it_needs(check: Any) -> str | None:
    """What a check needs from a virtual machine, or None for one that runs on any target."""
    what = getattr(check, "needs_a_vm", None)
    return what if isinstance(what, str) and what else None


def not_here_because(check: Any, target: str) -> str | None:
    """Why a check is not run on `target` — None when it is."""
    what = what_it_needs(check)
    if target == HERE and what is not None:
        return f"it needs {what}, which only a virtual machine gives"
    return None
