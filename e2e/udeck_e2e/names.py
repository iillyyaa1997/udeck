"""How a check is named, and how names on the command line choose checks.

A check is `<group>.<name>`: the group from its file, `check_updates.py` →
`updates`, and the name from its function, `check_wrong_key` → `wrong-key`. The
name is derived rather than declared so that it cannot drift from the code.

Selection is exact. A dotted name picks one check, a bare name picks a group,
and anything that matches nothing is an error that lists what exists — never a
run of zero checks that exits as if all was well. Numbers and substrings were
considered and rejected: numbers shift when a check is added, and a substring
quietly picks up the next check someone writes.
"""

from __future__ import annotations

import re
from collections.abc import Iterable

_PART = re.compile(r"^[a-z][a-z0-9]*(-[a-z0-9]+)*$")

# Words that name something other than a check and so cannot be a group.
RESERVED = frozenset({"list", "bake", "selfcheck", "cleanup"})


class CheckNameError(ValueError):
    """A check name that does not follow the rules, or matches nothing."""


def check_name(module_stem: str, function_name: str) -> str:
    """The dotted name of the check in `module_stem`.py, `function_name`."""
    if not module_stem.startswith("check_") or not function_name.startswith("check_"):
        raise CheckNameError(
            f"{module_stem}.py::{function_name}: checks live in check_<group>.py "
            "as functions named check_<name>"
        )
    group = module_stem.removeprefix("check_").replace("_", "-")
    name = function_name.removeprefix("check_").replace("_", "-")
    for part, what in ((group, "group"), (name, "check")):
        if not _PART.match(part):
            raise CheckNameError(
                f"{module_stem}.py::{function_name}: the {what} name '{part}' must be "
                "lowercase letters and digits, words joined by underscores"
            )
    if group in RESERVED:
        raise CheckNameError(
            f"{module_stem}.py: '{group}' is a command of the lab and cannot be a group"
        )
    return f"{group}.{name}"


def group_of(name: str) -> str:
    return name.split(".", 1)[0]


def select(available: Iterable[str], wanted: Iterable[str]) -> list[str]:
    """The checks `wanted` names, in the order they are defined.

    Nothing wanted means everything. Raises CheckNameError for any wanted name that
    matches no check, naming what does exist.
    """
    available = list(available)
    wanted = list(wanted)
    if not wanted:
        return available

    chosen: set[str] = set()
    unknown: list[str] = []
    groups = {group_of(name) for name in available}
    for item in wanted:
        if "." in item:
            if item in available:
                chosen.add(item)
            else:
                unknown.append(item)
        elif item in groups:
            chosen.update(name for name in available if group_of(name) == item)
        else:
            unknown.append(item)

    if unknown:
        listing = "\n".join(f"  {name}" for name in available) or "  (there are no checks yet)"
        raise CheckNameError(
            f"no check or group called {', '.join(repr(u) for u in unknown)}. "
            f"What exists:\n{listing}"
        )
    return [name for name in available if name in chosen]
