"""`e2e/run.sh selfcheck`: does the lab itself work on this Mac?

Not part of a normal run — every check already stands on the same machine and
restart pieces, so a normal run checks the lab on its way. This is for when the
lab is in doubt: after a Tart update, a macOS update, a new golden image.
"""

from udeck_e2e import probes
from udeck_e2e.errors import expect


def check_machine_is_as_baked(machine):
    probes.verify_golden(machine)


def check_restart_comes_back(machine):
    before = machine.ssh.boot_time()
    machine.reboot()
    after = machine.ssh.boot_time()
    expect(after > before, f"the boot time did not move forward: {before} → {after}")
