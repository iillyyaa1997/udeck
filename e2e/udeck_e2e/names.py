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


def select(available: Iterable[str], wanted: Iterable[str], only_when_named: Iterable[str] = ()) -> list[str]:
    """The checks `wanted` names, in the order they are defined.

    Nothing wanted means everything — but for the checks in `only_when_named`,
    which neither nothing nor their group chooses, only their own dotted name
    (`smoke`). Raises CheckNameError for any wanted name that matches no check,
    naming what does exist.
    """
    available = list(available)
    wanted = list(wanted)
    named_only = set(only_when_named)
    if not wanted:
        return [name for name in available if name not in named_only]

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
            members = [name for name in available if group_of(name) == item]
            if all(name in named_only for name in members):
                raise CheckNameError(f"the checks of {item!r} run only when each is named: {', '.join(members)}")
            chosen.update(name for name in members if name not in named_only)
        else:
            unknown.append(item)

    if unknown:
        listing = "\n".join(f"  {name}" for name in available) or "  (there are no checks yet)"
        raise CheckNameError(
            f"no check or group called {', '.join(repr(u) for u in unknown)}. "
            f"What exists:\n{listing}"
        )
    return [name for name in available if name in chosen]


class ShardError(ValueError):
    """A `--shard` that is not `i/n` with 1 ≤ i ≤ n."""


def parse_shard(text: str) -> tuple[int, int]:
    """`i/n` as two numbers: the i-th of n shards, counting from 1."""
    parts = text.split("/")
    if len(parts) != 2 or not all(part.isascii() and part.isdigit() for part in parts):
        raise ShardError(f"--shard is i/n, the i-th of n parts, such as 2/3 — not {text!r}")
    index, count = int(parts[0]), int(parts[1])
    if count < 1 or not 1 <= index <= count:
        raise ShardError(f"--shard {text}: the part has to be between 1 and {max(count, 1)}")
    return index, count


def shard(names: Iterable[str], index: int, count: int) -> list[str]:
    """The checks in part `index` of `count`, in the order they are defined.

    Dealt like cards, the first check to part 1, the second to part 2 and round
    again, so that every check is in exactly one part, the parts differ in size
    by one at most, and a group whose long checks sit together — the plugins
    group's are — is spread across all of them rather than given to one. The
    same names and the same `count` always make the same parts.
    """
    return [name for position, name in enumerate(names) if position % count == index - 1]
