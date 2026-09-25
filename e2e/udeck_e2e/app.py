"""uDeck itself, inside the guest: installed, launched, ended, and read off the disk.

The application's life in the machine, kept apart from what any one check does
with it. Both the update checks and the panel checks need a uDeck in
/Applications, running, and exactly the one they put there — and getting that
wrong is not a small mistake: a check that drives the copy a previous check left
behind is a check about the wrong application.

Installing is how a person installs (Q47): the zip unpacked with `ditto -x -k`
into /Applications, owned by the logged-in user, with no quarantine attribute.
Nothing here unpacks anything on this Mac — the unpacking happens in the guest,
over SSH (Q41).
"""

from __future__ import annotations

import json
import shlex
from collections.abc import Callable
from pathlib import Path

from udeck_e2e import config
from udeck_e2e.errors import LabError

Note = Callable[[str], None]

# Where the guest keeps the application, and where a build is put before it.
GUEST_APPLICATIONS = "/Applications"
APP = "uDeck.app"

# And where uDeck keeps the operator's own settings, as `UDeckPaths` resolves it
# (Sources/UDeckCore/Paths.swift): `~/.udeck/settings.json`, unless `UDECK_HOME`
# says otherwise, which nothing in the lab sets — the guest runs the released
# application exactly as a person's Mac does.
SETTINGS_FILE = "~/.udeck/settings.json"


def running_pids(machine, step: str = "looking for uDeck") -> set[str]:
    """The pids uDeck has in the guest — empty when it is not running.

    `ask`, never `run(..., check=False)`: a connection that dropped would
    otherwise answer "nothing is running", and a check would pronounce that
    about uDeck.
    """
    return set(machine.ssh.ask("pgrep -x uDeck || true", step).stdout.split())


def quit_app(machine, step: str, seconds: float = config.QUIT_SECONDS) -> None:
    """End any uDeck running in the guest, and prove it ended.

    A running copy is replaced by `ditto` underneath itself: it keeps running
    from the bundle that was deleted, so `open -a` afterwards only brings it
    forward and the check drives the *old* application. On a shared machine
    (--vm per-group, per-run) that copy belongs to the previous check, and the
    negative control would then be offered nothing by an application that has
    already updated itself — and pass having checked no signature at all.

    Asked first, killed second. A copy that will not go is the lab failing to
    prepare the machine, never a verdict about uDeck.
    """
    if not running_pids(machine, step):
        return
    machine.ssh.run(
        # Guarded by System Events: a bare `tell application "uDeck" to quit`
        # asks LaunchServices for the bundle, which is the one about to go.
        'osascript -e \'tell application "System Events" to if exists process "uDeck" '
        'then tell application "uDeck" to quit\' >/dev/null 2>&1; exit 0',
        step,
        check=False,
    )
    killed = False
    deadline = machine.clock() + seconds
    while True:
        pids = running_pids(machine, step)
        if not pids:
            return
        if machine.clock() >= deadline:
            raise LabError(step, f"uDeck was still running in the guest as {sorted(pids)} after {seconds:.0f}s")
        if not killed and machine.clock() >= deadline - seconds / 2:
            machine.ssh.run("pkill -x uDeck 2>/dev/null; exit 0", step, check=False)
            killed = True
        machine.sleep(1)


def install(machine, archive: Path, note: Note) -> None:
    """Install a lab build inside the guest, the way a person installs one (Q47).

    `ditto -x -k` into /Applications, owned by the logged-in user, and no
    quarantine attribute: an ad-hoc signed build carrying one would need a person
    to right-click it.

    Whatever was running goes first: the bundle is about to be replaced.
    """
    step = f"installing {archive.name} in {machine.name}"
    quit_app(machine, f"quitting the uDeck already running in {machine.name}")
    remote = f"/tmp/{archive.name}"
    machine.ssh.copy_in(archive, remote, step)
    machine.ssh.run(
        f"rm -rf {shlex.quote(GUEST_APPLICATIONS)}/{APP} && "
        f"ditto -x -k {shlex.quote(remote)} {shlex.quote(GUEST_APPLICATIONS)}",
        step,
    )
    app = f"{GUEST_APPLICATIONS}/{APP}"
    owner = machine.ssh.run(f"stat -f %Su {shlex.quote(app)}", step).stdout.strip()
    if owner != config.GUEST_USER:
        raise LabError(step, f"{app} belongs to {owner}, not to {config.GUEST_USER}")
    quarantined = machine.ssh.ask(f"xattr -p com.apple.quarantine {shlex.quote(app)}", step)
    if quarantined.returncode == 0:
        raise LabError(step, f"{app} carries a quarantine attribute: {quarantined.stdout.strip()}")
    note(f"   installed {archive.name} in {machine.name}")


def installed_version(machine) -> tuple[str, str]:
    """What is on disk in the guest: the version people read, and the one Sparkle compares."""
    step = f"reading the version installed in {machine.name}"
    app = f"{GUEST_APPLICATIONS}/{APP}/Contents/Info"
    done = machine.ssh.run(
        f"defaults read {shlex.quote(app)} CFBundleShortVersionString; "
        f"defaults read {shlex.quote(app)} CFBundleVersion",
        step,
    )
    lines = done.stdout.split()
    if len(lines) < 2:
        raise LabError(step, f"unexpected answer {done.stdout.strip()!r}")
    return lines[0], lines[1]


def launch(machine, step: str = "starting uDeck") -> set[str]:
    """Start uDeck in the guest, and answer with the one pid it is running as.

    Exactly one, because `open -a` brings a copy that is already running forward
    instead of starting one: a check that did not look would be driving whatever
    was there before it, which on a shared machine is the previous check's uDeck
    (--vm per-group, per-run).
    """
    machine.ssh.run(f"open -a {shlex.quote(GUEST_APPLICATIONS)}/{APP}", step)
    running = wait_until_running(machine)
    if len(running) != 1:
        raise LabError(step, f"{len(running)} copies of uDeck are running in the guest: {sorted(running)}")
    return running


def wait_until_running(machine, seconds: float = config.LAUNCH_SECONDS) -> set[str]:
    """The pids uDeck has once it is running.

    A failure while it is starting is "not yet" — `SSH.wait_up` and
    `Machine.wait_for_desktop` treat theirs the same way — but one that lasts the
    whole window belongs to the lab and comes out as the lab's.
    """
    deadline = machine.clock() + seconds
    last = ""
    while True:
        try:
            pids = running_pids(machine)
            if pids:
                return pids
        except LabError as error:
            last = f"; last: {error.reason}"
        if machine.clock() >= deadline:
            raise LabError("starting uDeck", f"uDeck was not running within {seconds:.0f}s{last}")
        machine.sleep(2)


# What macOS logs when it reopens an application because it was running when the
# session ended — its Transparent App Lifecycle, the "reopen windows when logging
# back in" setting. Measured in a guest on 2026-09-20, from a machine caught with
# uDeck running after a restart its login record forbade:
#
#   loginwindow[167] [com.apple.loginwindow.logging:TAL]
#     -[PersistentAppsSupport persistentAppPreLaunch] | --- Index:0,
#     bundleID:place.unicorns.udeck
#
# This has nothing to do with the login record, which read `[disabled]` throughout.
REOPENED = "persistentAppPreLaunch"
BUNDLE_ID = "place.unicorns.udeck"


def the_system_reopened_it(machine, step: str = "asking whether macOS reopened uDeck by itself") -> bool:
    """Whether macOS reopened uDeck at this login because it had been running.

    Asked of the boot the guest is in now, from its own clock. A check that
    restarts a machine with uDeck running cannot otherwise tell the login record's
    doing from this — and the two look identical from outside, which is what made
    an intermittent failure take two days to name.

    Evidence, not an oracle, on the reading side: a log that cannot be read says
    "no" and leaves the caller's own verdict to stand, because a check must not
    turn a bad connection into a sentence. What it *is* an oracle for is the
    caller's isolation, and callers raise on a true.
    """
    try:
        boot = machine.ssh.boot_time()
        since = machine.ssh.run(f"/bin/date -r {boot} '+%Y-%m-%d %H:%M:%S'", step).stdout.strip()
        said = machine.ssh.ask(
            f"/usr/bin/log show --start {shlex.quote(since)} "
            f"--predicate {shlex.quote(f'eventMessage CONTAINS \"{REOPENED}\"')} "
            f"--debug --info --style compact",
            step,
        ).stdout
    except LabError:
        return False
    return any(REOPENED in line and BUNDLE_ID in line for line in said.splitlines())


# --- What uDeck wrote down ------------------------------------------------------


def settings(machine, step: str):
    """What uDeck's settings file in the guest says, or None when there is no file.

    None is a real answer rather than an absence to be papered over. **uDeck
    writes no settings file at all until something is changed** — measured on
    2026-09-25: missing before the install, missing after the first launch, and
    still missing after every one of the five sections of the settings window
    had been opened and walked (.build/e2e/20260925-005230Z). So "there is no
    file" is exactly what a machine nobody has touched looks like, which is what
    makes a value read out of it a value the operator put there.

    `ask` and never `run(check=False)`, for the reason `running_pids` has: a
    connection that dropped would otherwise come back as an empty file, and a
    check would read that as uDeck having saved nothing.

    A file that is there and is not JSON is the lab unable to answer, not an
    answer: no check here pronounces on what uDeck writes when it cannot write
    properly, and one that did would need to say so in its own words.
    """
    return read_settings(settings_text(machine, step), step)


def settings_text(machine, step: str) -> str:
    """The settings file exactly as it stands in the guest, or "" when there is none.

    Apart from `settings` because a check keeps what it read beside its report,
    and what it keeps has to be what it judged: two reads of the same file are
    two answers, and the one quoted in the report would not be the one the
    verdict was reached on.
    """
    return machine.ssh.ask(f"cat {SETTINGS_FILE} 2>/dev/null || true", step).stdout


def read_settings(text: str, step: str):
    """That text as what it says, or None when there is no file at all."""
    if not text.strip():
        return None
    try:
        return json.loads(text)
    except ValueError as error:
        raise LabError(
            step, f"uDeck's settings file is not JSON ({error}): {text.strip()[:200]!r}"
        ) from None


def wait_for_settings(machine, step: str, until, seconds: float = config.SETTINGS_SAVE_SECONDS):
    """The settings file once `until` is satisfied by it — or as it stands when the time is up.

    Giving up quietly, the way `Story.wait_for` does and for the same reason:
    what a file that never said the right thing means is the check's to say, and
    the check has the words for it. A wait that decided anything here would
    turn "uDeck did not save the operator's change" into a lab failure, which is
    the one reading it must not have.

    It does not need to be long. Measured on 2026-09-25, the file is written
    inside the click that changes a setting — `DeckModel.update` saves from the
    control's own setter — and was there in the first `stat` after the click
    returned, 0.26 to 0.29 s after it was issued. `config.SETTINGS_SAVE_SECONDS`
    is that with room for a slow machine.
    """
    deadline = machine.clock() + seconds
    while True:
        said = settings(machine, step)
        if until(said) or machine.clock() >= deadline:
            return said
        machine.sleep(1)
