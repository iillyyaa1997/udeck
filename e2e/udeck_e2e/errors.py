"""The two ways a check can stop short of passing, kept apart on purpose.

A check that fails is evidence about uDeck. A check the lab could not carry out
is evidence about the lab — a machine that did not boot, SSH that never came
up, a download that timed out — and says nothing either way about uDeck. The
report never lets the second pass for the first, and never lets it read as
green.
"""

from __future__ import annotations


class CheckFailed(Exception):
    """uDeck did not do what the check expected.

    Deliberately not an AssertionError: an `assert` inside the lab's own
    helpers is a bug in the lab, and must not turn into a verdict on uDeck.
    """


class LabError(Exception):
    """The lab could not do something it needed to do in order to check.

    `step` names what the lab was doing, in words a person reading the report
    can act on — "booting the clone", "waiting for SSH after the reboot".
    """

    def __init__(self, step: str, reason: str) -> None:
        super().__init__(f"{step}: {reason}")
        self.step = step
        self.reason = reason


class NotThere(LabError):
    """A control the lab waited for never appeared.

    Kept apart from every other lab failure on purpose. "uDeck did not offer the
    update" is an observation about uDeck, and a check may act on it; "System
    Events refused", "the click did not go through", "the machine is gone" are
    the lab failing, and must never be read as an observation about uDeck.
    """


def expect(condition: bool, message: str) -> None:
    """Fail the check with `message` unless `condition` holds."""
    if not condition:
        raise CheckFailed(message)
