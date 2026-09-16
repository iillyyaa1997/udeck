"""`e2e/run.sh cleanup`: remove the clones the lab kept or left behind.

Only machines named with the lab's prefix, never one that is running, and the
golden images only when asked for by name.
"""

from __future__ import annotations

from collections.abc import Callable
from pathlib import Path

from udeck_e2e import config, golden
from udeck_e2e.errors import LabError
from udeck_e2e.tart import Tart


def clean(
    tart: Tart, say: Callable[[str], None], include_golden: bool, state_dir: Path = config.STATE_DIR
) -> int:
    """Delete what is left. Returns the exit code: 0 if everything went, 2 if not."""
    goldens = {g.golden_vm: g for g in config.GUESTS.values()}
    vms = [vm for vm in tart.list() if vm.name.startswith(config.VM_PREFIX)]
    targets = [vm for vm in vms if vm.name not in goldens or include_golden]
    if not targets:
        say("Nothing to clean up.")
        return 0

    code = 0
    for vm in targets:
        if vm.running:
            say(f"  {vm.name} is running; not touched. Shut it down first.")
            code = 2
            continue
        try:
            tart.delete(vm.name)
        except LabError as error:
            say(f"  {error}")
            code = 2
            continue
        if vm.name in goldens:
            golden.forget(goldens[vm.name], state_dir)
        say(f"  deleted {vm.name}")
    return code
