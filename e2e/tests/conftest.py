"""What every one of the lab's own tests can count on.

Ctrl-C is the lab's own subject, and several tests send themselves SIGINT. A
shell that starts pytest in the background leaves SIGINT ignored in the child —
POSIX job control — and those tests then fail, or wait forever for a signal that
is never delivered. Each test starts from the ordinary handler instead, so the
suite says the same thing whether it runs in a terminal, in the background or in
CI.
"""

import signal

import pytest


@pytest.fixture(autouse=True)
def ordinary_interrupts():
    before = signal.getsignal(signal.SIGINT)
    signal.signal(signal.SIGINT, signal.default_int_handler)
    try:
        yield
    finally:
        signal.signal(signal.SIGINT, before)
