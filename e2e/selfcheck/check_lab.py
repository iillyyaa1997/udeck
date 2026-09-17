"""`e2e/run.sh selfcheck`: does the lab itself work on this Mac?

Not part of a normal run — every check already stands on the same machine and
restart pieces, so a normal run checks the lab on its way. This is for when the
lab is in doubt: after a Tart update, a macOS update, a new golden image.
"""

import time

from udeck_e2e import config, probes
from udeck_e2e.errors import LabError

# Where the pointer is put and read back: the middle, the corners, the top edge
# the panel checks aim at.
POINTS = [
    (config.SCREEN_WIDTH // 2, config.SCREEN_HEIGHT // 2),
    (0, 0),
    (config.SCREEN_WIDTH - 1, config.SCREEN_HEIGHT - 1),
    (config.SCREEN_WIDTH // 2, 0),
    (config.SCREEN_WIDTH // 2, config.SCREEN_HEIGHT // 2),
]


def check_machine_is_as_baked(machine):
    probes.verify_golden(machine)


def check_screen_and_pointer(machine, check_dir):
    # The boot already waited for a real frame; this one is saved for the report.
    machine.screenshot(check_dir, "the desktop")
    for x, y in POINTS:
        machine.move_pointer(x, y, f"to ({x}, {y})")
        at = pointer_settles_at(machine, (x, y))
        if at != (x, y):
            raise LabError("checking the pointer", f"moved to ({x}, {y}); the guest reports {at}")
    machine.screenshot(check_dir, "the pointer in the middle")


def pointer_settles_at(machine, wanted, seconds=10):
    """The pointer's position once it is where it was sent, or the last one read."""
    deadline = time.monotonic() + seconds
    while True:
        at = probes.pointer(machine)
        if at == wanted or time.monotonic() >= deadline:
            return at
        time.sleep(1)


def check_restart_comes_back(machine):
    # Everything here is about the lab, so anything wrong is a LabError — "could
    # not check" — never a verdict that exits 1.
    before = machine.ssh.boot_session()
    machine.reboot()
    after = machine.ssh.boot_session()
    if after == before:
        raise LabError("checking the restart", f"the boot session is still {before}")
    probes.verify_golden(machine)
