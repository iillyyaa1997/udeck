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
# How often the lab takes a frame nobody asked for, to keep Tart's VNC server in
# use. Measured: a connection made after ~60 s with none crashes it (0 s and 30 s
# are fine), and the crash takes the machine with it.
SCREEN_HEARTBEAT_SECONDS = 20
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
# How long a uDeck already running in the guest is given to quit before its
# bundle is replaced. It matters on a shared machine (--vm per-group, per-run),
# where what is running is the previous check's copy.
QUIT_SECONDS = 30
# Until uDeck is running after `open -a`.
LAUNCH_SECONDS = 30

# One AppleScript against the guest's interface: a walk of the settings window
# took ~2 s measured, and a slow machine may take longer.
UI_SECONDS = 180

# --- The panel's gesture --------------------------------------------------------
#
# uDeck's own numbers are in Sources/UDeckCore/Configuration/GestureTuning.swift:
# the push needs 24 points of upward movement inside 0.25 s while the pointer is
# pinned, and the dwell needs the pointer to rest in the strip for 0.06 s (0.18 s
# when it arrived travelling sideways). What follows clears those with room, so
# that a check failing means the gesture did not fire rather than that the lab
# was a fraction too slow.

# Until `log stream` in the guest says it has attached. Anything uDeck logs
# before that is not in the file.
LOG_STREAM_SECONDS = 30
# The push: five events of twelve points each, five milliseconds apart — sixty
# points inside a fortieth of a second. Both numbers are chosen against the
# *dwell*, not only against the push threshold: the dwell fires 0.06 s after the
# pointer stops in the strip, so the push has to be over its own threshold well
# before then or the panel opens by the wrong path and the check proves nothing.
PUSH_STEPS = 5
# Negative is upward. The lab posts these as relative movement through
# IOHIDSystem, where the sign is the HID convention — measured in a clone on
# 2026-09-19: a positive delta moved the pointer down the screen, six reports of
# 40 taking it exactly 240 pixels.
PUSH_DELTA = -12.0
PUSH_PAUSE_SECONDS = 0.005

# The throw that puts the pointer against the top edge before the push, for the
# check that pushes there. It starts in the middle of the screen, 720 pixels
# below the edge, and stops the moment the pointer is pinned — so this is a cap,
# not a count, and it only has to be generous enough to cross the screen even if
# pointer acceleration works against it.
#
# **The throw must not overshoot**, and that is the whole reason it watches the
# pointer instead of counting reports. uDeck does not count the movement that
# *arrives* at the edge, but it counts everything after it — so a throw that
# keeps going once it is there is itself a push, and a large one: at sixty points
# a report it clears the 24-point threshold twice over. The run would still say
# `fired by push`, with the push that follows having mattered to nothing, and the
# check would be green while testing a gesture it never made. Measured in the
# audit of 2026-09-19, before this: fifteen reports of sixty from the middle of a
# 1440-pixel screen overshot by 180 points, and the panel opened on the throw.
THROW_CAP = 30
THROW_DELTA = -60.0
THROW_PAUSE_SECONDS = 0.002

# How far from the top edge the pointer may be and still count as pinned, when
# the push check reads back where its throw left it. uDeck's own `pinnedEpsilon`
# is 2 points, and the lab must not be stricter than the thing it checks: a
# pointer uDeck would push from, reported as short of the edge, would turn a
# real pass into "could not check".
PINNED_TOLERANCE_PIXELS = 2

# How far down the screen the pointer is put to open the panel by the dwell:
# inside the trigger strip, and *not* pinned against the top edge.
#
# Not the top row, which is where it used to go. A pointer on the top row is
# pinned, and uDeck counts upward movement made while pinned as a push — and the
# jump there over VNC was sometimes reported as exactly that. Counted over the
# lab's own logs on 2026-09-21: 7 of 45 reveals that were meant to be dwells
# fired by push (the review of that day, flakiness-7), and 2 of the 20 kept after
# it, one of them a machine's very first reveal (.build/e2e/20260921-213422Z,
# panel.a-click-past-the-panel). A pointer that is not pinned cannot push.
#
# uDeck's numbers, in rows from the top of this 1× screen (`GestureTuning`,
# `PanelGeometry`): the strip is `stripHeight` = 6 points tall and closed at the
# top, so rows 0 to 6 are in it, row 6 on its lower edge; and the pointer is
# pinned within `pinnedEpsilon` = 2 points of the row macOS clamps it to, which
# is one below the top — rows 0 to 3. That leaves rows 4, 5 and 6 in the strip
# and short of pinned, and 5 is the one with a row to spare on either side. (The
# push check's own PINNED_TOLERANCE_PIXELS counts one row fewer as pinned than
# uDeck does, so 5 is clear of it as well.) The lab's tests read the two numbers
# out of uDeck and hold this between them.
#
# Measured in the guest on 2026-09-21, with a probe that opens a peek eight times
# on each of two fresh machines and puts it away in between: on row 5, 16 of 16
# by the dwell (.build/e2e/20260921-220254Z), and 10 of 10 in each of the two
# panel group runs around it (-215814Z, -221300Z); the same probe on the top
# row, 2 of 16 by push, the second reveal of a fresh machine among them
# (-220939Z).
INSIDE_THE_STRIP_Y = 5

# --- The panel closing ----------------------------------------------------------
#
# Where the pointer goes, and where a click lands, when a check needs to be past
# the panel altogether — outside the region that keeps it alive, so that leaving
# is really leaving and a click there is really a click outside.
#
# It has to be a third place, because the two the opening checks use are not
# outside anything: the strip is where the panel hangs from, and the middle of
# the screen is *inside* the open one. The open panel is the largest a check
# makes — at most 1100 wide and 760 points of content, centred on the anchor
# (`PanelMetrics.swift`) — and the content hangs *below* the menu bar, with the
# panel's frame reaching up over the menu bar to the top of the screen
# (`PanelGeometry.topOverhang`). The menu bar in the guest is 30 points: the two
# panels measured there on 2026-09-21 agree on it, the peek as x 870…1690,
# y 0…126 (96 of content) and the open panel as x 730…1830, y 0…790 (760 of
# content). What keeps a panel alive is its frame grown by 24 points on every
# side (`GestureTuning.peekKeepAliveInset`), which for the open panel on this
# screen is the band between x 706 and x 1854, from the top of the screen down
# to y 814 — 30 + 760 + 24.
#
# This point is left of that region *and* below it, so neither of the two
# measurements alone has to stay where it is for the point to stay outside. It is
# also well clear of the Dock along the bottom edge, so a click here lands on the
# desktop rather than launching something. Measured in a guest on 2026-09-21: the
# pointer held here left a held panel alone eleven times out of eleven, and a
# click here closed it eight times out of eight.
#
# Past a peek and a held panel, and not past a panel in fullscreen: that one's
# keep-alive region is the whole visible screen grown by the same 24 points, and
# this point is inside it. No check takes the panel to fullscreen.
PAST_THE_PANEL = (200, 1100)

# And where a check clicks to hold the panel open: on the peek's content, which is
# the one place a click is sure to land on the panel and on nothing in it. The
# peek is 96 points of content below the 30-point menu bar, at most 820 wide and
# centred on the anchor (`PanelMetrics.swift`) — measured, as above, as the
# rectangle x 870…1690, y 0…126, of which the content is y 30…126 — and it draws
# no controls at all (`PeekView` in DeckRootView.swift is two pieces of text).
# y 70 is 40 points into that content and 56 short of its lower edge, and far
# below the 6-point trigger strip along the very top, so this is a click on the
# panel and not another go at the gesture. Measured: it produced
# `peek -> open on interacted` and nothing else, six times in four runs.
INSIDE_THE_PEEK = (SCREEN_WIDTH // 2, 70)

# The application a check brings forward before the panel is shown, when what it
# asks is which application the panel leaves in front once it is gone: any
# ordinary application with a window, as long as it is not the one a click on the
# desktop brings forward. TextEdit is on every Mac. It is what the measurement of
# 2026-09-21 used, and on the build that handed the keyboard back to it
# unconditionally it was in front again after every click past the panel it was
# asked about.
IN_FRONT_BEFORE_THE_PANEL = "TextEdit"
# What a click on the bare desktop brings forward, which PAST_THE_PANEL is.
THE_DESKTOP = "Finder"
# Where that application's window is put, so that nothing a check clicks or
# points at lands on it: right of the open panel, which ends at x 1830, below it,
# which ends at y 790, and far from PAST_THE_PANEL. The same place the
# measurement used, where every click past the panel landed on the desktop.
OUT_OF_THE_WAY = (1900, 900)
# The document IN_FRONT_BEFORE_THE_PANEL is opened on when a check asks where the
# keyboard went rather than which application is in front. It has to be a
# document, because a key is the only question that tells the two apart: with
# the panel on screen System Events names the application from before it either
# way (`probes.frontmost`), so only what the window holds can say whether the
# keystroke reached it. Emptied by the check before it is opened, so that what
# is in it is what this run typed.
THE_DOCUMENT = "/tmp/udeck-e2e-where-the-keyboard-went.txt"
# The two keys it presses, and they are two: the first is the control — a key
# that reaches the document before the panel has ever been shown, which is what
# makes "the second one did not" a sentence about uDeck rather than about a
# keystroke the lab never delivered. Letters, because what is read back is the
# text of the window; `esc` and the rest leave nothing to read.
BEFORE_THE_PANEL_KEY = "a"
AFTER_IT_CLOSED_KEY = "x"
# And a third, for the check that asks the same question while the panel is
# *open*: a key pressed then must reach uDeck and not the document behind it,
# which is what "ready to be typed into" means. A letter of its own, so that
# "did this key arrive" is a question about this key rather than about the whole
# text — TextEdit rewrites that by itself, and this is the trap the check would
# otherwise fall into: measured on 2026-09-23, a document holding "ay" became
# "Ay" between two reads with no key pressed in between (run-2 of the
# measurement, .build/e2e/20260923-212549Z). So the three letters are distinct
# and what is read back is compared without regard to case.
WHILE_THE_PANEL_IS_OPEN_KEY = "z"
# Until an application started with `open -a` is the one in front. The
# measurement waited three seconds and found TextEdit there every time; this is
# a slow machine's allowance on top.
FORWARD_SECONDS = 30
# One question to System Events about which application is in front. The bake
# allows the same when it asks whether SSH may drive the interface at all.
SYSTEM_EVENTS_SECONDS = 20

# How long the pointer rests in the strip for the dwell, and how long the lab
# then waits for uDeck to say something.
DWELL_SECONDS = 2
GESTURE_ANSWER_SECONDS = 10
# How long a negative control watches nothing happen: the pointer held in the
# middle of the screen, and a chord that is not the shortcut. Ten seconds is the
# same allowance `GESTURE_ANSWER_SECONDS` gives an answer that does come, so
# nothing is called silent sooner than an answer would be called late.
NOTHING_HAPPENS_SECONDS = 10
# How long panel.escape watches a panel it has just put away, to see whether it
# comes back by itself — and to see uDeck still alive and watching the pointer
# at the end of it.
#
# What keeps that panel shut is not the cooldown. Escape is pressed at a peek
# with the pointer still in the strip where the gesture left it, and every
# collapse tells the gesture not to fire again until the pointer has left the
# strip (`suppressUntilPointerLeaves`, which uDeck reports as `idle:
# alreadyFiredThisVisit`). The pointer never leaves it here, so a correct uDeck
# cannot reopen the panel in this check however long it waits. uDeck's own
# `reopenCooldown` (0.15 s) guards a different case — the pointer leaving the
# strip and coming straight back — which this check never makes. Measured on
# 2026-09-21: a build with `reopenCooldown = 0` passed panel.escape, its log going
# from the escape straight to `idle: alreadyFiredThisVisit`
# (.build/e2e/20260921-202329Z); on an unbroken build `idle: reopenCooldown` holds
# the first 0.2 s or so and the other gate the rest. So a broken cooldown is not
# caught here, and no check in the lab catches it yet.
#
# What the watch does catch is the panel coming back at all, which it has been
# seen to do: three panels escaped out of `open` in an earlier measurement came
# back 158, 208 and 228 ms after the line that closed them
# (.build/e2e/20260921-133502Z; why, is not established). This is thirteen times
# the slowest of them, which is room for a loaded machine without making every
# escape check wait for nothing.
STAYS_SHUT_SECONDS = 3
# How long after the panel closed a check waits before asking what else came of
# it: which application is in front, and whether a second messenger followed the
# first. uDeck gives the keyboard back in the same millisecond it logs the
# collapse (every `gave the keyboard back` line of 2026-09-21), and the
# workspace's news of a click arrives 2 to 32 ms after the click — the
# measurements are in `ApplicationSwitchTests.slowestClickCausedActivation`
# (Tests/UDeckCoreTests/PanelStateTests.swift), which is where the slowest of
# them is written down. Not `ApplicationSwitch.clickWindow`, which this comment
# used to name for them: that is 0.15 s, the line uDeck draws from those
# measurements, and it would still be 0.15 s if every one of them changed. On
# the build that brought the application from before the panel back
# unconditionally, that application was in front after this long in every run
# that asked (.build/e2e/20260921-201212Z, -210835Z, -211147Z).
SETTLE_SECONDS = 2
# Until a control appears after something was pressed.
UI_APPEAR_SECONDS = 30
# Until a control the lab clicked reads back as changed (`ui.press`).
#
# A click at coordinates can miss — the window moved, the pane was still being
# built, the pointer was not where the accessibility API said the control was —
# and a miss that nobody read back becomes a verdict about uDeck further down
# the check. So the control is walked again until it says the click landed. One
# walk of the Opening screen took roughly two seconds measured (`ui`'s own
# docstring), so this is room for several of them on a machine that is busy
# drawing, and it is spent only when the click did *not* land.
UI_CHANGE_SECONDS = 10

# --- The panel's keyboard shortcut ------------------------------------------------
#
# uDeck registers one global shortcut and opens the panel on it, ready to be
# typed into (`HotKeyBinding`, `PanelController.toggleFromKeyboard`). Everything
# here is uDeck's own default, written down so the lab can press exactly what
# uDeck registered — and read back against uDeck's source by the lab's tests,
# the way the gesture's numbers are, because every way of getting it wrong is
# silent: a chord uDeck never registered opens nothing, and a check that pressed
# it would be red about uDeck for the lab's mistake.

# How uDeck spells the shortcut when it says it has taken it from the window
# server: `hotkey ⌃⌥U registered` (`HotKeyBinding.displayName`, modifiers in
# macOS's order, then the key).
THE_HOTKEY = "⌃⌥U"
# The modifiers held down, by the names System Events takes in `key code … using
# {control down, option down}` — and the modifiers of uDeck's default binding.
HOTKEY_MODIFIERS = ("control", "option")
# The key itself, as a virtual key code, because that is what a key press made
# inside the guest names. 32 is "U" in `HotKeyBinding.keyCodes`: ANSI codes, a
# fixed hardware-layout ABI rather than anything derived from the keyboard
# layout, which is why the same number means the same key in both places.
HOTKEY_KEY_CODE = 32

# The control: the same two modifiers and a key uDeck never registered. 38 is
# "J" in the same table — next to "U" on the keyboard and nowhere near it in the
# codes, so a lab that muddled the two would not land on this by accident.
# Measured on 2026-09-23: ⌃⌥J made this way left uDeck's log empty for ten
# seconds, twice over (.build/e2e/20260923-212036Z, hotkey.wrong-chord).
NOT_THE_HOTKEY = "⌃⌥J"
NOT_THE_HOTKEY_KEY_CODE = 38

# What the shortcut leaves in a document when *nobody* holds the combination.
#
# `RegisterEventHotKey` takes a combination out of the keyboard: while the
# registration stands the window server delivers it to that process and to no
# other, so the application in front never sees the keystroke at all. Once the
# registration is gone the same keystroke goes where every other one goes — to
# whatever is in front — and the text system inserts what the layout gives for
# Control held over "U", which is 0x15, NAK, that letter's ASCII control code.
# The guest is pinned to en / en_US by the bake and `probes.verify_golden` reads
# that back, so the layout is not something a run can drift into.
#
# So this is the difference `panel.the-hotkey-dies-with-udeck` reads, and it is
# a presence rather than an absence: with uDeck holding the shortcut the
# document behind the panel gains nothing from a press, and with uDeck gone it
# gains exactly this. A combination that outlived uDeck would leave the document
# as empty of it as a living uDeck does. Measured in the guest on 2026-09-24,
# with uDeck ended and then one ordinary letter pressed after the chord: the
# document read back 'a\x15x' (.build/e2e/20260924-230410Z).
THE_CHORD_IN_A_DOCUMENT = "\x15"

# The port the appcast and its archive are served on, inside the guest. It is
# baked into every lab build (SUFeedURL), so a check and its builds agree on it.
FEED_PORT = 8765

# How often a known lab failure is retried before the check becomes "could not
# check": SSH refusing right after a clone boots, a hung `tart` call, and macOS
# refusing a machine because it believes two are already running.
KNOWN_FAILURE_RETRIES = 2
VM_LIMIT_RETRY_WAIT_SECONDS = 15

# --- The settings window ----------------------------------------------------------
#
# What the operator changes, changed the way he changes it. Nothing here is a
# coordinate: the controls on the Opening screen carry no accessibility
# identifier, no title and no description (measured 2026-09-25,
# .build/e2e/20260925-005230Z), so the lab finds them by where they sit among
# their own kind — which is what the two orders below are for — and reads the
# row back before it clicks anything (`ui.opening`).
#
# The two readings beside them are a *guard*, and it is worth being exact about
# what they can catch. They say that the row found is a row of uDeck's own
# controls on a machine nobody has touched: a screen still being built, a pane
# that is not this one, or a machine some earlier check left changed all read
# something else and the lab refuses to click. They cannot say which control in
# the row is which — four switches that all read on read the same in any order,
# and on, on, off, off survives swapping the two ons — so the order itself is
# not observed here at all. It comes from the source that draws the row
# (`OpeningSettings` in SettingsView.swift), and what holds it is the lab's own
# tests reading that file back: `test_the_plain_switches_are_in_the_order_uDeck_lays_them_out`
# and `test_the_modifier_row_is_in_the_order_uDeck_lays_it_out`.

# The shortcut's four modifier buttons, left to right, by the names uDeck's
# settings file spells them with. The order is `HotKeyModifier.allCases.sorted()`
# — `HotKeyModifier.order`, which is macOS's own order for the symbols ⌃⌥⇧⌘ —
# laid out by `ForEach` in `OpeningSettings` (SettingsView.swift).
HOTKEY_MODIFIER_ROW = ("control", "option", "shift", "command")
# What that row reads on a machine nothing has changed: uDeck's default binding
# is {control, option} (`HotKeyBinding.init`), so the row reads on, on, off,
# off. It is a guard against a screen that is not at rest and not a way of
# telling the four apart — the same four values in the other order read the
# same.
HOTKEY_MODIFIER_ROW_AT_REST = ("1", "1", "0", "0")

# The Opening screen's four plain checkboxes, top to bottom, by the setting each
# one writes: the gesture, the shortcut, "retract when you switch applications"
# and "while another application is full screen" (`OpeningSettings`).
OPENING_SWITCHES = ("gesture.enabled", "hotkey.enabled", "collapseOnAppSwitch", "gesture.enabledInFullscreen")
# And what they read on a machine at rest: every one of the four is true by
# default (`AppSettings.init`, `GestureTuning.init`). All four alike, so this
# reading says the row is untouched and says nothing whatever about which of
# them is which.
OPENING_SWITCHES_AT_REST = ("1", "1", "1", "1")

# The switch a check changes when it asks whether a setting survives uDeck being
# restarted, and the key it writes in the settings file.
#
# It is this one of the four because it is one of the two settings uDeck answers
# *with something the lab can read*, and the only one of those that is not the
# shortcut. A setting whose effect can only be photographed is no use here: the
# panel is translucent over whatever is behind it, and "something changed at the
# top of the screen" is exactly the evidence that passes for the wrong reason.
# This one changes what a held panel does when another application comes
# forward, and uDeck writes the answer either way — `open -> collapsed on
# otherAppActivated` with it on, `otherAppActivated ignored in open` with it off
# (measured 2026-09-25, .build/e2e/20260925-004441Z).
THE_SWITCH = "collapseOnAppSwitch"

# The modifier a check adds to the shortcut, and what the shortcut becomes.
#
# Shift because it is the one modifier the default binding does not use and the
# one macOS spells third, so the new combination differs from the old by exactly
# one press and neither contains the other as a prefix the window server could
# confuse. uDeck spells the result `⌃⌥⇧U` (`HotKeyBinding.displayName`:
# modifiers in macOS's order, then the key), which is how it says it has taken
# it — measured 2026-09-25, `hotkey ⌃⌥⇧U registered`
# (.build/e2e/20260925-003726Z).
THE_ADDED_MODIFIER = "shift"
THE_NEW_HOTKEY = "⌃⌥⇧U"
# The modifiers the lab holds down to press it, by the names System Events takes.
NEW_HOTKEY_MODIFIERS = ("control", "option", "shift")

# How long the lab waits for uDeck to write its settings file after a control on
# that screen was clicked.
#
# Measured on 2026-09-25: the file is written *inside the click*. The click was
# issued between 1790296693.217 and 1790296693.597 on the guest's clock and the
# file's mtime is 1790296693.503, and the first `stat` after the click returned
# already found it — four runs, 0.258 to 0.292 s from the click being issued,
# the SSH round trip included (.build/e2e/20260925-003726Z and the runs beside
# it). So anything this waits for beyond a moment is the machine being slow, and
# a file that is still not there at the end of it is uDeck not having saved.
SETTINGS_SAVE_SECONDS = 20

# Everything the operator did *not* touch, which the file has to carry too.
#
# A check that reads back the one key it changed is green over a uDeck that
# saves that key and drops the rest — and dropping the rest is not a small
# failure: what a settings file does not say is read back as the shipped
# default (`AppSettings.init(from:)` decodes every key with `decodeIfPresent`),
# so a lost key is a setting silently reset on the next launch with nothing
# anywhere to say it happened.
#
# Every non-optional stored property of `AppSettings`, which is exactly what the
# synthesised encoder writes; the two optional ones (`textSize`, `language`) say
# nothing until the operator chooses, so they are not required to be there.
# Thirteen keys after one click, in every file these checks have left: 1921
# bytes for the switch and 1935 for the shortcut on 2026-09-25 and again on
# 2026-09-26 (.build/e2e/20260926-142454Z). `test_the_settings_file_carries_every_key_uDeck_encodes`
# holds this list against AppSettings.swift.
SETTINGS_KEYS = (
    "version",
    "density",
    "gesture",
    "panel",
    "hotkey",
    "theme",
    "look",
    "resolvedIsDark",
    "collapseOnAppSwitch",
    "defaultCardTTL",
    "silentTTLMultiplier",
    "pluginExecutableSearchPath",
    "pollWhileCollapsed",
)
# And a few of them read back, because a key that is there holding something
# else is the same loss as a key that is gone. These are uDeck's own defaults
# (`AppSettings.init`) and none of them is a setting either check changes, so
# every one of them still reads its default after the operator's one click.
SETTINGS_AT_REST = {
    "version": 1,
    "density": "normal",
    "defaultCardTTL": 60,
    "silentTTLMultiplier": 3,
    "pollWhileCollapsed": False,
}
