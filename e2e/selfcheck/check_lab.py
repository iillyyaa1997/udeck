"""`e2e/run.sh selfcheck`: does the lab itself work on this Mac?

Not part of a normal run — every check already stands on the same machine and
restart pieces, so a normal run checks the lab on its way. This is for when the
lab is in doubt: after a Tart update, a macOS update, a new golden image.
"""

from udeck_e2e import probes
from udeck_e2e.errors import LabError


def check_machine_is_as_baked(machine):
    probes.verify_golden(machine)


def check_restart_comes_back(machine):
    # Everything here is about the lab, so anything wrong is a LabError — "could
    # not check" — never a verdict that exits 1.
    before = machine.ssh.boot_session()
    machine.reboot()
    after = machine.ssh.boot_session()
    if after == before:
        raise LabError("checking the restart", f"the boot session is still {before}")
    probes.verify_golden(machine)
