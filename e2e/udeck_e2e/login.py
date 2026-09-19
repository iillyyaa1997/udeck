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
from dataclasses import dataclass

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
            url=fields.get("URL", "").replace("(null)", ""),
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


def record_for(dump: str, identifier: str = BUNDLE_ID) -> LoginRecord | None:
    """The record for one application, or none.

    More than one record can carry the identifier — an embedded helper, a leftover from a
    copy that is gone — so the one that decides what opens is the one the system is acting
    on, and a disabled leftover is not it.
    """
    mine = [record for record in records(dump) if _is(record, identifier)]
    if not mine:
        return None
    return next((record for record in mine if record.enabled), mine[0])


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


def collect(machine, directory, step: str = "reading the system's login records", name: str = "login-records.txt"):
    """The record, with the whole database kept beside the check's other evidence (Q38).

    The database is the only place the truth about this feature lives, and a check that
    says "there is no record" without keeping what it read leaves the next person to
    reproduce the whole machine to find out what it saw.
    """
    text = dump(machine, step)
    try:
        (directory / name).write_text(text)
    except OSError:
        pass
    return record_for(text)
