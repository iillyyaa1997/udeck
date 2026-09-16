"""Stopping the lab without leaving machines behind.

Ctrl-C, closing the terminal (SIGHUP) and `kill` (SIGTERM) all mean "stop", and
all take the same path: a KeyboardInterrupt, so every cleanup the lab has in
`finally` blocks and fixture teardowns runs. Without that, SIGHUP and SIGTERM
killed the lab outright while its `tart run` — in its own session, so the
signal never reached it — kept an 8 GB virtual machine running.

A cleanup, once started, is not cut short by the next press. The press is
remembered and acknowledged, the cleanup finishes, and *then* the lab stops —
the stop is never swallowed. Only pressing again and again abandons a cleanup.
"""

from __future__ import annotations

import signal
import threading
from collections.abc import Callable, Iterator
from contextlib import contextmanager

# Presses during a cleanup before the lab gives up on finishing it.
ABANDON_CLEANUP_AFTER = 3

_state = {"depth": 0, "presses": 0}


def stop_on_hangup_and_terminate() -> None:
    """Make SIGHUP and SIGTERM behave like Ctrl-C. Call once, from the main thread."""

    def as_ctrl_c(signum: int, frame: object) -> None:
        handler = signal.getsignal(signal.SIGINT)
        if callable(handler):
            handler(signal.SIGINT, frame)
        else:
            raise KeyboardInterrupt

    signal.signal(signal.SIGHUP, as_ctrl_c)
    signal.signal(signal.SIGTERM, as_ctrl_c)


@contextmanager
def deferred(note: Callable[[str], None], what: str) -> Iterator[None]:
    """Run the block to its end even if the lab is told to stop meanwhile.

    Nested blocks share one count, and only the outermost raises the deferred
    KeyboardInterrupt, so a protected `tart delete` inside a protected cleanup
    does not end the cleanup early.
    """
    if threading.current_thread() is not threading.main_thread():
        yield
        return

    outermost = _state["depth"] == 0
    if outermost:
        _state["presses"] = 0
    previous = signal.getsignal(signal.SIGINT)

    def acknowledge(signum: int, frame: object) -> None:
        _state["presses"] += 1
        if _state["presses"] >= ABANDON_CLEANUP_AFTER:
            signal.signal(signal.SIGINT, signal.default_int_handler)
            raise KeyboardInterrupt
        left = ABANDON_CLEANUP_AFTER - _state["presses"]
        note(
            f"   stopping once {what} is done; press Ctrl-C {left} more time(s) to abandon it "
            "and leave the machine behind"
        )

    _state["depth"] += 1
    signal.signal(signal.SIGINT, acknowledge)
    try:
        yield
    finally:
        _state["depth"] -= 1
        signal.signal(signal.SIGINT, previous)
    if outermost and _state["presses"]:
        _state["presses"] = 0
        raise KeyboardInterrupt
