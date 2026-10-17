"""Checks against the real GitHub, which run only when they are named.

Every other plugin check reads a fake GitHub in the guest, and every lab build is
pointed at it (`builds.Builder._verify`). One question the fake cannot answer is
whether uDeck reads the real one as the fake says it does: a pull request
GitHub serves, its head and its listing as `api.github.com` lists them, its
files from `raw.githubusercontent.com`, and the state GitHub says it is in once
somebody closes it. `smoke.real-pull-request` asks that, with a lab build that
carries the shipped addresses, anonymously, as a person's uDeck asks.

So such a check is never part of a run that did not name it — not of a run
without names, not of its group's — because it needs a pull request somebody
opened for it and will close while it waits, and it spends the hour's sixty
requests of the address it runs from. It takes the pull request as
`--pull-request <link>`, which nothing else takes, and it runs only on a GitHub
runner (`--target here`): the Tart guests on this Mac would ask GitHub from the
operator's own address.
"""

from __future__ import annotations

import re
from collections.abc import Callable
from typing import Any

# The option the smoke takes its pull request from (`cli`), and the check that takes it.
PULL_REQUEST_OPTION = "--pull-request"
REAL_PULL_REQUEST = "smoke.real-pull-request"

# A pull request of a repository on github.com, as a browser shows its link: the scheme and `www.` or not, and any
# page under it (`…/files`, `…/commits`).
_PULL_REQUEST = re.compile(r"^(?:https?://)?(?:www\.)?github\.com/([^/\s]+/[^/\s]+)/pull/([1-9][0-9]{0,8})(?:/[^\s]*)?$")


def only_when_named(takes: str) -> Callable[[Callable[..., Any]], Callable[..., Any]]:
    """Mark a check as one that runs only when its own name is given, and say which option it takes."""

    def mark(check: Callable[..., Any]) -> Callable[..., Any]:
        check.only_when_named = takes  # type: ignore[attr-defined]
        return check

    return mark


def what_it_takes(check: Any) -> str | None:
    """The option a check run only when named takes, or None for any other check."""
    takes = getattr(check, "only_when_named", None)
    return takes if isinstance(takes, str) and takes else None


def pull_request(link: str, repository: str) -> int | None:
    """The number of the pull request `link` names in `repository` — None when it names anything else."""
    found = _PULL_REQUEST.match(link.strip())
    if found is None or found.group(1).lower() != repository.lower():
        return None
    return int(found.group(2))
