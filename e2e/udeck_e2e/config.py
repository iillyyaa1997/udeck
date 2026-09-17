"""Everything about the lab a person might reasonably want to change.

Nothing here is a secret or specific to one machine. Updating a pin is meant to
be a deliberate commit: a newer Tart or a newer base image changes what "green"
means, so it should arrive as its own change and not as a side effect of
whatever happened to be downloaded that day.
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

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

# Free space a bake asks for: the base image's disk is 40–50 GB when pulled, and
# the lab tells Tart never to delete cached images to make room.
MIN_FREE_DISK_GB_FOR_BAKE = 60

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

# --- The golden image ---------------------------------------------------------

# 2560×1440 at 1×, like the operator's main display. In pixels, not points: in
# points Tart sizes the guest by the host's *main* screen, so the same setting
# would become Retina the day the laptop is used without its monitor.
GOLDEN_DISPLAY = "2560x1440px"

# The same screen in pixels, as a screenshot and the pointer see it.
SCREEN_WIDTH, SCREEN_HEIGHT = (int(n) for n in GOLDEN_DISPLAY.removesuffix("px").split("x"))

# Bump when the bake's steps change. A golden image baked by an older version,
# or from a base image other than the pinned one, is refused by the pre-flight.
BAKE_VERSION = 1

# What the lab remembers about each golden image. Not in the checkout: golden
# images live in Tart's store and are shared by every checkout on this Mac.
STATE_DIR = Path.home() / "Library" / "Application Support" / "udeck-e2e"

# The account Cirrus Labs' images log in as.
GUEST_USER = "admin"

# --- Deadlines, in seconds ------------------------------------------------------
#
# Every call the lab makes has one. The numbers are measured times on an Apple
# Silicon laptop with generous room: a clone boots to an IP in ~7–20 s, answers
# `tart exec` in ~25 s, reboots in ~20 s and shuts down in ~10 s.

TART_CALL_SECONDS = 120
CLONE_SECONDS = 900
PULL_SECONDS = 3 * 3600
BOOT_IP_SECONDS = 240
AGENT_SECONDS = 180
SSH_UP_SECONDS = 180
DESKTOP_SECONDS = 180
REBOOT_SECONDS = 360
SHUTDOWN_SECONDS = 60
SSH_COMMAND_SECONDS = 120
# A 4 MB build over scp takes a moment; a slow machine, a little longer.
COPY_SECONDS = 300
# One VNC action — a pointer move or a screenshot — in its own process: ~0.5 s
# measured, most of it starting Python.
VNC_ACTION_SECONDS = 30
# Until the screen shows a drawn frame after a boot or a restart.
SCREEN_SECONDS = 60
# How much of a frame one colour may cover for the screen to count as drawn.
# Measured: a blank screen 1.0, the Apple boot screen 0.998, a desktop 0.002.
SCREEN_MAX_UNIFORM = 0.98

# A release build of uDeck plus the bundle around it. Minutes from cold, seconds
# when SwiftPM has everything already.
BUILD_SECONDS = 1800
# How long a build that overran its deadline is given to stop before it is killed.
BUILD_STOP_GRACE_SECONDS = 10
# Sparkle's own signing tool, on one zip.
SIGN_SECONDS = 120
# Until the guest's own web server answers on its loopback address.
FEED_UP_SECONDS = 30

# One AppleScript against the guest's interface: a walk of the settings window
# took ~2 s measured, and a slow machine may take longer.
UI_SECONDS = 180
# Until a control appears after something was pressed.
UI_APPEAR_SECONDS = 30

# The port the appcast and its archive are served on, inside the guest. It is
# baked into every lab build (SUFeedURL), so a check and its builds agree on it.
FEED_PORT = 8765

# How often a known lab failure is retried before the check becomes "could not
# check": SSH refusing right after a clone boots, a hung `tart` call, and macOS
# refusing a machine because it believes two are already running.
KNOWN_FAILURE_RETRIES = 2
VM_LIMIT_RETRY_WAIT_SECONDS = 15
