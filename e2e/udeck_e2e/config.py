"""Everything about the lab a person might reasonably want to change.

Nothing here is a secret or specific to one machine. Updating a pin is meant to
be a deliberate commit: a newer Tart or a newer base image changes what "green"
means, so it should arrive as its own change and not as a side effect of
whatever happened to be downloaded that day.
"""

from __future__ import annotations

from dataclasses import dataclass

# Tart is pinned exactly. Its `--vnc-experimental` flag is experimental by name,
# and the lab leans on the exact output of `tart list --format json` and
# `tart run`, so a new version is something to try on purpose.
TART_VERSION = "2.37.0"

TART_INSTALL_HINT = "brew install openai/tools/tart"


@dataclass(frozen=True)
class Guest:
    """One macOS version the lab can run checks on."""

    key: str
    # The Cirrus Labs `-base` image, pinned by digest. `-base` rather than
    # `-vanilla` because it already has SIP off and the privacy grants that let
    # a command over SSH drive the user interface, which a vanilla image does
    # not, and which cannot be granted without clicking through a dialog.
    base_image: str
    # macOS runs a guest only as new as itself.
    min_host_major: int

    @property
    def golden_vm(self) -> str:
        return f"{VM_PREFIX}golden-{self.key}"


GUESTS: dict[str, Guest] = {
    # macOS 27. Built by Cirrus Labs from the 27.0 seed, 26A5416b, not the 27.0
    # release — the guest's build number goes into every run's ledger so that
    # difference stays visible.
    "27": Guest(
        key="27",
        base_image=(
            "ghcr.io/cirruslabs/macos-golden-gate-base"
            "@sha256:972b57b9bcdbf4571581069bd7f0f3266507c0aac124fd121871520f8158456a"
        ),
        min_host_major=27,
    ),
    # macOS 26.6.2, for the systems uDeck supports that are not the newest.
    "26": Guest(
        key="26",
        base_image=(
            "ghcr.io/cirruslabs/macos-tahoe-base"
            "@sha256:1b093499716409d29e8b5336844528e1cae375db97d2ad8e5aeff78cf0da201e"
        ),
        min_host_major=26,
    ),
}

DEFAULT_GUEST = "27"

# Every virtual machine the lab creates carries this prefix, and the lab never
# touches one that does not. Do not name your own machines this way.
VM_PREFIX = "udeck-e2e-"

# A clone kept for inspection with --keep-on-failure. Kept clones are left alone
# by the pre-flight and removed only by the cleanup command.
KEPT_PREFIX = f"{VM_PREFIX}kept-"

# How many runs' reports stay under .build/e2e/. Older ones are deleted by the
# lab at the start of a run.
KEEP_RUNS = 10

# Free space the pre-flight asks for, per machine running at once. A clone is
# copy-on-write and starts at almost nothing; this is room for what a check
# writes inside it — builds, logs, an update — with a margin for the host.
MIN_FREE_DISK_GB_PER_VM = 20

# Memory a guest is given, and what the pre-flight leaves for the host on top.
# The Cirrus images default to 8 GB.
VM_MEMORY_GB = 8
HOST_MEMORY_RESERVE_GB = 8

# macOS's memory pressure level, from `sysctl kern.memorystatus_vm_pressure_level`:
# 1 normal, 2 warning, 4 critical. At critical the pre-flight refuses to start a
# machine, because the host would start killing things to make room.
REFUSE_AT_MEMORY_PRESSURE = 4

# Seconds the pre-flight waits for an orphaned `tart run` to exit after SIGTERM
# before it sends SIGKILL.
ORPHAN_TERM_GRACE_SECONDS = 30
