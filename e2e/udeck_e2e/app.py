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


def forget_settings(machine, step: str) -> None:
    """Take uDeck's settings file away, so the next uDeck starts as a new one would.

    The lab's only hand on that file, and it is worth saying what it is not: a
    check *reads* this file to reach half of its verdict and never writes a
    value into it, because a check that wrote the file and restarted uDeck would
    be a check about `JSONFileStore` and about nothing the operator does. Taking
    away what a neighbouring check left behind is the opposite of that — it puts
    the machine back to the one state every sentence about this file rests on,
    which is a machine nobody has configured.

    Only with uDeck not running: a live one holds its settings in memory and
    writes the whole file on the next change, so a file removed underneath it
    comes back saying what that process believes. Callers quit it first.
    """
    machine.ssh.run(f"rm -f {SETTINGS_FILE}", step)


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


# --- What Sparkle remembers -------------------------------------------------------


def preferences(machine, step: str) -> str | None:
    """What macOS keeps for uDeck's bundle identifier in the guest, or None when it keeps nothing.

    uDeck itself writes nothing there — its own settings are `SETTINGS_FILE` — so
    what this holds is Sparkle's memory and AppKit's: whether automatic checks are
    on (`SUEnableAutomaticChecks`, which the operator's switch writes), when the
    last check was (`SULastCheckTime`, which every check writes, the operator's
    included), and how often to look (`SUScheduledCheckInterval`). Each of those
    overrides what the bundle's Info.plist says, which is why a check about what
    uDeck *ships* has to start from none of them. Measured on 2026-09-26, after
    the switch was turned on and one check made, the domain held
    `SUEnableAutomaticChecks`, `SUHasLaunchedBefore`, `SULastCheckTime` and
    `SUUpdateGroupIdentifier`, all Sparkle's, and nothing else.

    **"Nothing" has two spellings**, and both are None here. On a machine where
    uDeck has never run, `defaults read` says the domain was not found and exits
    1. On one where the domain was deleted — which is what `forget_preferences`
    does — it exits 0 and prints an empty dictionary, `{ }`: measured on
    2026-09-26 with `--vm per-group`, where the update checks before had left
    `SULastCheckTime` behind (.build/e2e/20260926-223522Z). Read as "something
    is kept", that empty dictionary made the lab refuse a machine it had just
    cleaned.

    `ask`, for the reason `running_pids` has: a dropped connection is the lab's,
    and must never read as "nothing is kept".
    """
    done = machine.ssh.ask(f"defaults read {BUNDLE_ID}", step)
    if done.returncode != 0 or "".join(done.stdout.split()) == "{}":
        return None
    return done.stdout


# Sparkle's own name for whether it looks by itself: the key its setter writes into
# uDeck's preferences when the operator's switch changes it, and the key it reads —
# before the plist — every time it decides whether to schedule a check.
AUTOMATIC_CHECKS = "SUEnableAutomaticChecks"


def automatic_checks(machine, step: str) -> str | None:
    """What uDeck's preferences in the guest say about `AUTOMATIC_CHECKS` — `"1"`, `"0"` — or None when nothing.

    One key and not the whole domain (`preferences`), because a check reads this
    one as an answer. `defaults read` of a key nobody wrote fails, and that is
    None — measured in a macOS 27 guest on 2026-09-27, with uDeck running and
    the switch not yet touched: a non-zero exit and `Error: Could not find key
    'SUEnableAutomaticChecks' in domain 'place.unicorns.udeck'.` A domain that is
    not there at all is "does not exist" (`preferences`), and is None too. Anything else that fails
    is the lab unable to read it, never a key that is not there: `ask`, for the
    reason `running_pids` has.
    """
    done = machine.ssh.ask(f"defaults read {BUNDLE_ID} {AUTOMATIC_CHECKS}", step)
    if done.returncode == 0:
        return done.stdout.strip()
    said = f"{done.stdout or ''}\n{done.stderr or ''}"
    if "Could not find key" in said or "does not exist" in said:
        return None
    lines = said.strip().splitlines()
    raise LabError(
        step, f"{AUTOMATIC_CHECKS} could not be read: {lines[-1] if lines else f'exit {done.returncode}'}"
    )


def forget_preferences(machine, step: str) -> None:
    """Take away what macOS keeps for uDeck, so the next uDeck starts as a new one would.

    **Sparkle decides whether and when to look for an update out of this**, not
    out of the bundle alone: a check the operator ran — or a neighbouring check
    ran, on a machine shared with `--vm per-group` — leaves `SULastCheckTime`
    behind, and Sparkle then waits a day from it before it looks by itself; a
    switch turned on leaves `SUEnableAutomaticChecks` behind, and that wins over
    the plist. Either one would make a check about what uDeck ships into a check
    about what the machine remembers.

    Only with uDeck not running, as `forget_settings`: callers quit it first. And
    read back, because a machine that keeps them is one the next sentence cannot
    be about.
    """
    machine.ssh.run(f"defaults delete {BUNDLE_ID} >/dev/null 2>&1; exit 0", step)
    left = preferences(machine, step)
    if left is not None:
        raise LabError(
            step,
            f"macOS still keeps preferences for {BUNDLE_ID} after the lab deleted them: "
            f"{' '.join(left.split())[:300]}",
        )


def switch_automatic_checks_off(machine, step: str) -> None:
    """Leave the machine as an operator who switched automatic checks off leaves it.

    uDeck ships with them on, so the check that turns the switch on needs a
    machine where somebody turned it off — and doing that in the window would
    first cost a check, whose last-check date then stops the switch from causing
    another for a day. So the lab writes what the switch's setter writes,
    `AUTOMATIC_CHECKS` as false, which Sparkle reads before the plist; nothing
    else. Only with uDeck not running, as `forget_preferences`, and read back:
    a machine where it did not take would make "the switch turned it on" a
    sentence about nothing.
    """
    machine.ssh.run(f"defaults write {BUNDLE_ID} {AUTOMATIC_CHECKS} -bool false", step)
    kept = automatic_checks(machine, step)
    if kept != "0":
        raise LabError(
            step,
            f"the lab wrote {AUTOMATIC_CHECKS} as false for {BUNDLE_ID}, and it reads back as "
            f"{kept if kept is not None else 'nothing at all'}",
        )


# Sparkle's own name for where uDeck asks for an update: the key in the bundle's
# Info.plist, and a key it reads from uDeck's preferences *first*
# (`-[SUHost objectForKey:ofClass:]`, user defaults before the plist, in Sparkle
# 2.9.6 as Package.resolved pins it; `-[SPUUpdater retrieveFeedURL:]` takes it from
# there, and uDeck gives Sparkle no `feedURLStringForUpdater:` that would come
# before it). Every published release carries GitHub's latest feed and the lab's
# own builds carry the lab's feed in the guest; a pair whose "to" is anywhere else
# is reached by writing this into the guest's preferences — never this Mac's.
FEED_URL = "SUFeedURL"


def point_the_feed_at(machine, url: str, step: str) -> None:
    """Make the uDeck in the guest ask `url` for its updates, and read it back.

    The second of the two preferences the lab ever writes (the other is
    `switch_automatic_checks_off`), and only for a pair whose "to" is not where
    "from"'s own Info.plist points: a release offered a build of this checkout
    (the lab's feed), a build of this checkout or a release offered a release by
    name (that release's own appcast), a build of this checkout offered the latest
    release (the real feed). Only with uDeck not running, after
    `forget_preferences` — which would take it away again — and read back, because
    a uDeck still asking its own feed would make the check a question about that
    feed.
    """
    machine.ssh.run(f"defaults write {BUNDLE_ID} {FEED_URL} -string {shlex.quote(url)}", step)
    kept = machine.ssh.ask(f"defaults read {BUNDLE_ID} {FEED_URL}", step)
    if kept.returncode != 0 or kept.stdout.strip() != url:
        said = (kept.stdout or kept.stderr or "").strip().splitlines()
        raise LabError(
            step,
            f"the lab wrote {FEED_URL} = {url} for {BUNDLE_ID}, and it reads back as "
            f"{said[-1] if said else 'nothing at all'}",
        )
