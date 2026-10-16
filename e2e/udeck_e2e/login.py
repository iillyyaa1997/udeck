"""The system's own record of what opens at login, read out of the guest.

Three things could stand in for this record and none of them is it:

* **What uDeck says.** The switch in its settings is a reading of the system, which is the
  point of the design — but a check that asks the application whether the application is
  right has asked nothing.
* **`SMAppService.mainApp.status`.** It answers about the running copy and says nothing
  about *which* copy the system has on file, which is the failure this feature exists to
  survive.
* **System Events' "login items".** Measured 2026-09-18: deleting uDeck from that list
  emptied it while `SMAppService` went on reporting exactly as before. They are not the
  same list, and the one that decides what opens at login is not the one AppleScript sees.

So the oracle is `sfltool dumpbtm`, which prints the Background Task Management database —
the real record, with the path of the copy it points at and the generation that counts up
each time it is rewritten.

It is asked for with `sudo`, and the reason is worth writing down because it nearly went
the other way: on this Mac the same command answers without `sudo`, so a probe run here
"proved" it needs no privileges. It does — the shell it ran in had Full Disk Access. In
the guest, which has neither, it answers `authorization failed` and exits 1. The guest
gives `sudo` without a password and is a throwaway clone, so this costs nothing there;
the lesson is that a tool measured on a developer's Mac has been measured under
permissions no ordinary machine has.
"""

from __future__ import annotations

import re
import shlex
from dataclasses import dataclass
from urllib.parse import unquote, urlsplit

from udeck_e2e.errors import LabError

# uDeck's identifier, and the one a lab build carries too: a lab build *is* the released
# application, which is exactly why a stray copy can take the record (Q41).
BUNDLE_ID = "place.unicorns.udeck"

_FIELD = re.compile(r"^\s*([A-Za-z][A-Za-z. ]+?):\s*(.*)$")
# `2.` for an application, `16.` for a legacy daemon, `8.` for an agent.
_TYPE_PREFIX = re.compile(r"^\d+\.")


@dataclass(frozen=True)
class LoginRecord:
    """One item in the system's database, as far as a check needs it."""

    name: str
    identifier: str
    bundle_id: str
    url: str
    disposition: str
    generation: int
    # The row's own identity, which is the only field that says "this is the same
    # record" rather than "a record that looks like it". Measured in a guest on
    # 2026-09-19: it survives both a restart and uDeck updating itself, while the
    # generation moves in one of those and not the other.
    uuid: str = ""

    @property
    def enabled(self) -> bool:
        """Whether the system will act on this record."""
        return "enabled" in self.disposition and "disabled" not in self.disposition

    @property
    def allowed(self) -> bool:
        return "allowed" in self.disposition and "disallowed" not in self.disposition

    def describe(self) -> str:
        return f"{self.identifier} at {self.url or '(no path)'} — {self.disposition}, generation {self.generation}"


def record_path(url: str) -> str:
    """The path a record names, however `sfltool` spells it.

    macOS 27 prints a path, `/Applications/uDeck.app`; macOS 26.6.2 prints a
    file URL, `file:///Applications/uDeck.app/` (measured on a GitHub runner,
    run 38213314297, login.registers). Both are the same copy, and a check
    asking which copy the record names must not read the spelling as an answer.
    """
    url = url.replace("(null)", "").strip()
    if url.startswith("file://"):
        url = unquote(urlsplit(url).path)
        if len(url) > 1:
            url = url.rstrip("/")
    return url


def records(dump: str) -> list[LoginRecord]:
    """Every item in a `sfltool dumpbtm` dump, in the order it printed them.

    The dump is a person's report rather than a format, so this reads the fields it needs
    and ignores everything else: a macOS that adds a line must not make the lab blind.
    """
    found: list[LoginRecord] = []
    fields: dict[str, str] = {}
    for line in dump.splitlines():
        if re.match(r"^\s*#\d+:\s*$", line):
            _keep(found, fields)
            fields = {}
            continue
        match = _FIELD.match(line)
        if match:
            fields[match.group(1).strip()] = match.group(2).strip()
    _keep(found, fields)
    return found


def _keep(found: list[LoginRecord], fields: dict[str, str]) -> None:
    identifier = fields.get("Identifier", "")
    if not identifier:
        return
    generation = fields.get("Generation", "0")
    found.append(
        LoginRecord(
            name=fields.get("Name", ""),
            identifier=identifier,
            bundle_id=fields.get("Bundle Identifier", "").replace("(null)", ""),
            url=record_path(fields.get("URL", "")),
            disposition=fields.get("Disposition", ""),
            generation=int(generation) if generation.isdigit() else 0,
            uuid=fields.get("UUID", ""),
        )
    )


def _is(record: LoginRecord, identifier: str) -> bool:
    """Whether a record is this application's.

    Measured in a guest: the database does not file an application under its bundle
    identifier. uDeck's record reads `Identifier: 2.place.unicorns.udeck` — the type code
    and a dot in front, `16.` for a legacy daemon, `8.` for an agent — and carries the
    plain one in a field of its own, `Bundle Identifier`. A check that matched the obvious
    field found nothing and said uDeck had not registered, while the record sat there
    enabled.
    """
    return record.bundle_id == identifier or _TYPE_PREFIX.sub("", record.identifier) == identifier


def records_for(dump: str, identifier: str = BUNDLE_ID) -> list[LoginRecord]:
    """Every record that is this application's, in the order the dump printed them."""
    return [record for record in records(dump) if _is(record, identifier)]


def pick(mine: list[LoginRecord], uuid: str = "") -> LoginRecord | None:
    """The record a check is asking about, out of this application's.

    Given the UUID of the row a check switched on, that row and no other — which is the
    point. More than one record can carry the identifier: an embedded helper, a leftover
    from a copy that is gone, another copy entirely. Picking "whichever is enabled" let a
    disabled live row hide behind an enabled one belonging to a different copy, and then a
    check about uDeck switching *its* row off read the other copy's and pronounced on it.

    Without a UUID — before anything was switched on, or from a dump that does not print
    one — the one the system acts on is the enabled one, and a disabled leftover is not it.
    """
    if uuid and any(record.uuid for record in mine):
        return next((record for record in mine if record.uuid == uuid), None)
    if not mine:
        return None
    return next((record for record in mine if record.enabled), mine[0])


def record_for(dump: str, identifier: str = BUNDLE_ID, uuid: str = "") -> LoginRecord | None:
    """The record for one application — the row with `uuid` when one is given — or none."""
    return pick(records_for(dump, identifier), uuid)


def enabled_elsewhere(mine: list[LoginRecord], uuid: str) -> list[LoginRecord]:
    """This application's enabled records other than the row with `uuid`.

    What decides whether *some* copy opens at login, as against the one a check switched.
    Empty when the dump prints no UUIDs, because then no two rows can be told apart.
    """
    if not uuid or not any(record.uuid for record in mine):
        return []
    return [record for record in mine if record.enabled and record.uuid != uuid]


def dump(machine, step: str = "reading the system's login records") -> str:
    """The database, as the guest prints it."""
    done = machine.ssh.run("sudo -n /usr/bin/sfltool dumpbtm", step, seconds=120, check=False)
    if done.returncode != 0 or "authorization failed" in (done.stdout + done.stderr):
        said = (done.stderr or done.stdout).strip().splitlines()
        raise LabError(step, f"sfltool would not say: {said[-1] if said else f'exit {done.returncode}'}")
    return done.stdout


def record(machine, identifier: str = BUNDLE_ID, step: str = "reading the system's login records"):
    """What the system has on file about opening this application at login, or nothing."""
    return record_for(dump(machine, step), identifier)


def collect_rows(machine, directory, step: str = "reading the system's login records", name: str = "login-records.txt"):
    """Every record that is uDeck's, with the whole database kept beside the check's
    other evidence (Q38).

    The database is the only place the truth about this feature lives, and a check that
    says "there is no record" without keeping what it read leaves the next person to
    reproduce the whole machine to find out what it saw.
    """
    text = dump(machine, step)
    try:
        (directory / name).write_text(text)
    except OSError:
        pass
    return records_for(text)


def collect(machine, directory, step: str = "reading the system's login records",
            name: str = "login-records.txt", uuid: str = ""):
    """The record — the row with `uuid` when one is given — kept as `collect_rows` keeps it."""
    return pick(collect_rows(machine, directory, step, name), uuid)


# --- What the guest's log says was done with the record -------------------------------
#
# The database says what the record *is*; it cannot say who acted on it. The checks used to
# read that off its generation — "+1 across a restart is the record opening uDeck", "more
# than +1 is uDeck registering itself again" — and that was measured wrong on 2026-10-12:
# macOS moves the generation on `noteUseOfItem`, which it writes when uDeck starts and when
# it exits — once usually, three times when the exit races Sparkle's relaunch — and across a
# restart it moved at the lab's own quit, before the restart, or not at all (README, "Open at
# Login"). So the record's acts are read where macOS writes them down, in the guest's
# unified log, and the generation is kept only as evidence.
#
# Every line below was read in a macOS 27 guest on 2026-10-12 (runs 20261012-180909Z and
# -181746Z, the lab's own probes, not kept in the repository):
#
# * uDeck registering: `backgroundtaskmanagementd` writes
#   `registerLaunchItem: pid=809, uid=501, type=app, url=(null), config=(null)` — the
#   application asking for itself (`SMAppService.mainApp.register()`), named by its pid
#   alone. The switch writes exactly one, switching it off writes `unregisterLaunchItem`,
#   and an update and a restart write none. A build of uDeck that registered again at
#   every launch while switched on (never committed) wrote one more at the login after the
#   restart, from the pid the record had just opened (2026-10-16, run 20261016-041921Z).
# * The record opening uDeck at login, three lines in a row. `loginwindow`'s login items
#   launcher writes `-[LoginItemsLauncher main] | enter` at every login, and for an item
#   it opens `LaunchItemsInSharedFileListRef | performAutolaunch, launching:
#   /Applications/uDeck.app` — the copy, by its path. It asks LaunchServices to open it as
#   a login item: `LSOpenApplication(… flags=0x800201 … event=<… 'aevt'\134'oapp'{
#   'prdt':'lgit' }>)`, the open event carrying `keyAELaunchedAsLogInItem`. And
#   LaunchServices launches uDeck, through `CoreServicesUIAgent` on loginwindow's behalf:
#   `_LSLaunchRB(place.unicorns.udeck <private>, event=aevt/oapp, args=- 0x810200/dontSwitch async …`.
#   `LSOpenApplication` names no application: it is the record's by being the next thing
#   loginwindow says after the launcher names the copy, and the launch by its flags.
# * What is *not* the record. The `_LSLaunchRB` line on its own is not: macOS reopening
#   uDeck because it was running at the restart (`persistentAppPreLaunch`, caught in
#   -181746Z, probe.tal) writes the same `event=aevt/oapp`, with `args=- 0x801100/` and an
#   open event of `{ ~'rsto':'yes ' }`, and no `performAutolaunch`. The lab's own `open -a`
#   is `_LSLaunchRB(place.unicorns.udeck …, event=-, args=- 0x8000000/ …` and Sparkle's
#   relaunch after an update `… event=-, args=- 0x48000040/ …`. Switched off, the launcher
#   still runs and opens nothing: `LaunchItemsInSharedFileListRef | count = 0` (probe.off).
#
# LaunchServices' lines are Info, which macOS keeps in memory only, so they are read in the
# boot they were written in; loginwindow's and the registrations are Default, kept on disk,
# and read across the restart.

LOG_PREDICATE = (
    '(process == "backgroundtaskmanagementd" AND (eventMessage BEGINSWITH "registerLaunchItem: pid=" '
    'OR eventMessage BEGINSWITH "noteUseOfItemWithIdentifier: identifier=2.place.unicorns.udeck")) '
    'OR (process == "loginwindow" AND (eventMessage CONTAINS "LoginItemsLauncher main] | enter" '
    'OR eventMessage CONTAINS "performAutolaunch, launching: " '
    'OR eventMessage BEGINSWITH "LSOpenApplication(" '
    'OR eventMessage CONTAINS "persistentAppPreLaunch] | --- Index")) '
    'OR (process == "CoreServicesUIAgent" AND eventMessage CONTAINS "place.unicorns.udeck" '
    'AND (eventMessage BEGINSWITH "_LSLaunchRB(" OR eventMessage CONTAINS "Successful launched")) '
    'OR ((process == "uDeck" OR process == "ThemeWidgetControlViewService") '
    'AND eventMessage BEGINSWITH "Identity resolved as ")'
)

# A line as `log show --style compact` prints it: date, time, type, process[pid:tid],
# the subsystem and category in brackets when there are any, and what was said.
_LOG_LINE = re.compile(
    r"^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d{3}) (?:\S\S|\S ) ([^\[\]]+)\[(\d+):[0-9a-f]+\] (?:\[[^\]]*\] )?(.*)$"
)
# Not `unregisterLaunchItem`, which the switch writes when it is turned off.
_REGISTERED = re.compile(r"^registerLaunchItem: pid=(\d+), uid=\d+, type=app\b")
_AS_A_LOGIN_ITEM = "'prdt':'lgit'"
# The flags LaunchServices launched uDeck with for the login item, in every restart of
# the series (31 of 31); macOS putting back what was running writes `0x801100/`.
_AS_A_LOGIN_ITEM_LAUNCH = "args=- 0x810200/"
_AUTOLAUNCH = re.compile(r"performAutolaunch, launching: (.+?), shouldHide:")
_LAUNCHED_PID = re.compile(r"Successful launched \S+ pid=(\d+) " + re.escape(BUNDLE_ID) + r"\b")
_UDECK_IDENTITY = "Identity resolved as app<application." + BUNDLE_ID + "."


@dataclass(frozen=True)
class LogLine:
    """One line of the guest's log: when, which process, and what it said."""

    when: str
    process: str
    pid: int
    said: str

    def __str__(self) -> str:
        return f"{self.when} {self.process}[{self.pid}] {self.said}"


def log_lines(text: str) -> list[LogLine]:
    """The lines of a compact `log show` that have a process — the header and the rest left out."""
    found = []
    for line in text.splitlines():
        match = _LOG_LINE.match(line)
        if match:
            when, process, pid, said = match.groups()
            found.append(LogLine(when, process.strip(), int(pid), said))
    return found


@dataclass(frozen=True)
class Witnesses:
    """What the guest's log says was done with uDeck's login record, since a moment and since the boot.

    `known` is the pids the lab itself saw uDeck run as; the log's own are added to them
    (`udeck_pids`), because a registration names nothing but a pid.
    """

    lines: tuple[LogLine, ...]
    known: frozenset[int] = frozenset()
    boot: str = ""

    def udeck_pids(self) -> set[int]:
        pids = set(self.known)
        for line in self.lines:
            if line.process == "uDeck" and line.said.startswith(_UDECK_IDENTITY):
                pids.add(line.pid)
            launched = _LAUNCHED_PID.search(line.said) if line.process == "CoreServicesUIAgent" else None
            if launched:
                pids.add(int(launched.group(1)))
        return pids

    def registrations(self) -> list[LogLine]:
        """uDeck asking the system for its own login item, oldest first."""
        mine = self.udeck_pids()
        return [
            line for line in self.lines
            if line.process == "backgroundtaskmanagementd"
            and (found := _REGISTERED.search(line.said)) and int(found.group(1)) in mine
        ]  # fmt: skip

    def others_registering(self) -> list[LogLine]:
        """Applications that are not uDeck asking for their own — evidence, never a verdict."""
        mine = self.udeck_pids()
        return [
            line for line in self.lines
            if line.process == "backgroundtaskmanagementd"
            and (found := _REGISTERED.search(line.said)) and int(found.group(1)) not in mine
        ]  # fmt: skip

    def _since_the_boot(self) -> list[LogLine]:
        return [line for line in self.lines if not self.boot or line.when >= self.boot]

    def launcher_ran(self) -> bool:
        """loginwindow's login items launcher ran after the boot: the log of the login was read."""
        return self.launcher_runs() > 0

    def launcher_runs(self) -> int:
        """How many times the login items launcher ran after the boot — once per login.

        More than once is lines of another boot read as this one's. "After the boot" is a
        comparison of the log's times with the boot's on the guest's clock, and a guest's
        clock can be anywhere: one of the series' machines read 2026-09-17 while the others
        read 10-12, and its window held the launcher of its first boot as well, left out
        only because that boot's times were earlier (20261012-200502Z, login.off-stays-off).
        """
        return sum(
            1 for line in self._since_the_boot()
            if line.process == "loginwindow" and "LoginItemsLauncher main] | enter" in line.said
        )  # fmt: skip

    def opened_at_login(self) -> list[str]:
        """The paths of uDeck the login items launcher opened after the boot.

        Each one three lines in a row: the launcher naming the copy; the next thing
        loginwindow says, LaunchServices asked to open it as a login item
        (`'prdt':'lgit'`); and the next launch of uDeck LaunchServices writes, with the
        open event and the login item's flags (`event=aevt/oapp, args=- 0x810200/`). The
        launch alone is also what macOS reopening uDeck writes, with `0x801100/`; the
        first two and the flags are the record's. `LSOpenApplication` names no
        application, so it is held to the launcher by coming next.
        """
        opened = []
        lines = self._since_the_boot()
        for index, line in enumerate(lines):
            found = _AUTOLAUNCH.search(line.said) if line.process == "loginwindow" else None
            if not found or not found.group(1).rstrip("/").endswith("/uDeck.app"):
                continue
            later = lines[index + 1:]
            asked = next((i for i, each in enumerate(later) if each.process == "loginwindow"), None)
            if (
                asked is None
                or not later[asked].said.startswith("LSOpenApplication(")
                or _AS_A_LOGIN_ITEM not in later[asked].said
            ):
                continue
            launched = next(
                (each for each in later[asked + 1:]
                 if each.process == "CoreServicesUIAgent" and each.said.startswith(f"_LSLaunchRB({BUNDLE_ID} ")),
                None,
            )  # fmt: skip
            if launched is not None and "event=aevt/oapp" in launched.said and _AS_A_LOGIN_ITEM_LAUNCH in launched.said:
                opened.append(found.group(1).rstrip("/"))
        return opened

    def asked_at_login(self) -> list[str]:
        """The paths the login items launcher asked to open after the boot, uDeck or not."""
        return [
            found.group(1).rstrip("/")
            for line in self._since_the_boot()
            if line.process == "loginwindow" and (found := _AUTOLAUNCH.search(line.said))
        ]  # fmt: skip

    def launches(self) -> list[LogLine]:
        """Every launch of uDeck LaunchServices wrote down after the boot, whoever asked for it."""
        return [
            line for line in self._since_the_boot()
            if line.process == "CoreServicesUIAgent" and line.said.startswith(f"_LSLaunchRB({BUNDLE_ID} ")
        ]  # fmt: skip

    def uses(self) -> int:
        """`noteUseOfItem` for uDeck's record: what moves its generation (evidence only)."""
        return sum(1 for line in self.lines if line.said.startswith("noteUseOfItemWithIdentifier: identifier=2." + BUNDLE_ID))

    def theme_widgets(self) -> int:
        """AppKit's ThemeWidgetControlViewService started for uDeck (evidence only, `windowButtons` in ax.swift)."""
        return sum(
            1 for line in self.lines
            if line.process == "ThemeWidgetControlViewService" and BUNDLE_ID in line.said
        )  # fmt: skip

    def evidence(self) -> str:
        """One line for the report: the readings that used to be the verdict, now only beside it."""
        return (
            f"{len(self.registrations())} registration(s) by uDeck, {self.uses()} noteUseOfItem, "
            f"{self.theme_widgets()} ThemeWidgetControlViewService started for uDeck"
        )


def clock(machine, step: str = "reading the guest's clock") -> str:
    """The guest's time now, as `log show --start` takes it."""
    said = machine.ssh.run("/bin/date '+%Y-%m-%d %H:%M:%S'", step).stdout.strip()
    if not re.fullmatch(r"\d{4}-\d\d-\d\d \d\d:\d\d:\d\d", said):
        raise LabError(step, f"the guest's clock said {said!r}")
    return said


def boot_clock(machine, step: str = "reading when the guest booted") -> str:
    """When the guest booted, by its own clock, as `clock` writes it."""
    boot = machine.ssh.boot_time()
    return clock_at(machine, boot, step)


def clock_at(machine, epoch: int, step: str) -> str:
    said = machine.ssh.run(f"/bin/date -r {int(epoch)} '+%Y-%m-%d %H:%M:%S'", step).stdout.strip()
    if not re.fullmatch(r"\d{4}-\d\d-\d\d \d\d:\d\d:\d\d", said):
        raise LabError(step, f"the guest's clock said {said!r}")
    return said


def witnesses(machine, directory, since: str, step: str, name: str = "login-log.txt",
              known: frozenset[int] = frozenset(), boot: str = "") -> Witnesses:
    """The guest's log since `since`, kept beside the check's other evidence, and read.

    An answer that is not a log is the lab's failure: every verdict that reads this would
    otherwise be a verdict about an empty page.
    """
    done = machine.ssh.run(
        f"/usr/bin/log show --start {shlex.quote(since)} --info --style compact --predicate {shlex.quote(LOG_PREDICATE)}",
        step, seconds=180, check=False,
    )
    if done.returncode != 0:
        said = (done.stderr or done.stdout or "").strip().splitlines()
        raise LabError(step, f"the guest's log could not be read: {said[-1] if said else f'exit {done.returncode}'}")
    try:
        (directory / name).write_text(done.stdout)
    except OSError:
        pass
    return Witnesses(tuple(log_lines(done.stdout)), frozenset(known), boot)
