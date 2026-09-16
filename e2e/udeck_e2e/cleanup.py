"""`e2e/run.sh cleanup`: remove the clones the lab kept or left behind.

Only machines named with the lab's prefix, never one that is running, golden
images only with --golden and then only the guests asked for, and with --list
nothing at all — it says what would go.
"""

from __future__ import annotations

from collections.abc import Callable
from pathlib import Path

from udeck_e2e import config, golden
from udeck_e2e.errors import LabError
from udeck_e2e.tart import Tart


def clean(
    tart: Tart,
    say: Callable[[str], None],
    include_golden: bool,
    guests: list[config.Guest] | None = None,
    dry_run: bool = False,
    state_dir: Path = config.STATE_DIR,
) -> int:
    """Delete what is left. Returns the exit code: 0 if everything went, 2 if not."""
    all_goldens = {g.golden_vm: g for g in config.GUESTS.values()}
    wanted_goldens = {g.golden_vm for g in (guests if guests is not None else config.GUESTS.values())}
    vms = [vm for vm in tart.list() if vm.name.startswith(config.VM_PREFIX)]
    targets = [
        vm
        for vm in vms
        if vm.name not in all_goldens or (include_golden and vm.name in wanted_goldens)
    ]
    if not targets:
        say("Nothing to clean up.")
        return 0

    code = 0
    for vm in targets:
        if vm.running:
            say(f"  {vm.name} is running; not touched. Shut it down first.")
            code = 2
            continue
        if dry_run:
            say(f"  would delete {vm.name}")
            continue
        try:
            tart.delete(vm.name)
        except LabError as error:
            say(f"  {error}")
            code = 2
            continue
        if vm.name in all_goldens:
            golden.forget(all_goldens[vm.name], state_dir)
        say(f"  deleted {vm.name}")
    return code
