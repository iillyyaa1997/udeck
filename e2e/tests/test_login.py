"""Reading the system's login database, which is the only honest oracle for this feature.

The fixture below is a real `sfltool dumpbtm` dump — the shape it actually prints on
macOS 27, taken from this Mac — with a uDeck record written into it in the same shape.
Everything the checks decide is decided from text like this, so the parsing is where a
mistake would be silent: a record read as "not there" when it is there makes a check that
proves the opposite of what it says.
"""

import pytest

from udeck_e2e import login

# The uDeck block below is verbatim from a guest (2026-09-18), which is how the shape that
# broke the first version of this parser got into the fixture: the database files an
# application under `2.<bundle id>` and keeps the plain one in `Bundle Identifier`.
DUMP = """\
========================
 Records for UID -2 : FFFFEEEE-DDDD-CCCC-BBBB-AAAAFFFFFFFE
========================

 ServiceManagement migrated: true
 LaunchServices registered: false

 Items:

 #1:
                 UUID: EEE834D9-2346-423E-A7F3-74A1DF32C045
                 Name: Docker
       Developer Name: Docker
                 Type: developer (0x20)
                Flags: [ curated ] (0x4)
          Disposition: [disabled, allowed, not notified] (0x2)
           Identifier: Docker
                  URL: (null)
           Generation: 0
  Embedded Item Identifiers:
    #1: 16.com.docker.vmnetd

========================
 Records for UID 501 : 11112222-3333-4444-5555-666677778888
========================

 Items:

 #1:
                 UUID: CFCA1AB8-A002-498C-BDD0-24C6E2802585
                 Name: uDeck
       Developer Name: (null)
                 Type: app (0x2)
                Flags: [  ] (0)
          Disposition: [enabled, allowed, notified] (0xb)
           Identifier: 2.place.unicorns.udeck
                  URL: /Applications/uDeck.app
           Generation: 1
    Bundle Identifier: place.unicorns.udeck

 #2:
                 UUID: 9A9A9A9A-7777-8888-9999-000011112222
                 Name: Amphetamine
                 Type: app (0x10002)
          Disposition: [enabled, allowed, visible, notified] (0xb)
           Identifier: com.if.Amphetamine
                  URL: /Applications/Amphetamine.app
           Generation: 4
"""


def test_every_record_is_read_with_the_fields_a_check_needs():
    found = login.records(DUMP)
    assert [record.identifier for record in found] == [
        "Docker", "2.place.unicorns.udeck", "com.if.Amphetamine",
    ]  # fmt: skip
    udeck = found[1]
    assert udeck.name == "uDeck"
    assert udeck.bundle_id == "place.unicorns.udeck"
    assert udeck.url == "/Applications/uDeck.app"
    assert udeck.generation == 1
    assert udeck.enabled and udeck.allowed


def test_a_disabled_record_is_not_read_as_enabled():
    """"disabled" contains "enabled", which is exactly the kind of thing that makes a
    check pass while the system opens nothing."""
    docker = login.records(DUMP)[0]
    assert not docker.enabled
    assert docker.allowed
    assert docker.url == "", "a record with no path prints (null), which is not a path"


def test_an_application_is_found_although_the_database_renames_it():
    """The bug this file is here for: `Identifier` is `2.place.unicorns.udeck`, so a check
    matching the bundle identifier found nothing and said uDeck had not registered while
    its record sat there enabled."""
    assert login.record_for(DUMP) is not None
    without_bundle_field = DUMP.replace("    Bundle Identifier: place.unicorns.udeck\n", "")
    assert login.record_for(without_bundle_field) is not None, "the type prefix alone is enough"


def test_the_record_for_uDeck_is_found_by_identifier():
    record = login.record_for(DUMP)
    assert record is not None
    assert record.url == "/Applications/uDeck.app"
    assert login.record_for(DUMP, "com.example.nothing") is None


def test_nothing_is_found_in_a_dump_with_no_such_application():
    without = DUMP.replace("place.unicorns.udeck", "place.unicorns.something-else")
    assert login.record_for(without) is None


def test_the_record_that_counts_is_the_one_the_system_acts_on():
    """A copy that is gone leaves its record behind, disabled — Apple keeps it "to
    preserve user intent". A check that read the leftover would call a working login item
    broken, or a broken one working."""
    two = DUMP.replace(
        "           Generation: 1\n",
        "           Generation: 1\n\n #3:\n"
        "                 Name: uDeck\n"
        "          Disposition: [disabled, allowed, visible, notified] (0x2)\n"
        "           Identifier: 2.place.unicorns.udeck\n"
        "                  URL: /Users/x/Applications/uDeck-debug.app\n"
        "           Generation: 7\n",
        1,
    )
    record = login.record_for(two)
    assert record is not None
    assert record.url == "/Applications/uDeck.app", "the enabled one decides"

    off = two.replace("[enabled, allowed, notified] (0xb)\n           Identifier: 2.place.unicorns.udeck",
                      "[disabled, allowed, notified] (0x2)\n           Identifier: 2.place.unicorns.udeck", 1)
    leftover = login.record_for(off)
    assert leftover is not None and not leftover.enabled, "with none enabled, the first is still reported"


def test_a_dump_from_a_macOS_that_prints_more_does_not_go_blind():
    """The dump is a report, not a format. A line nobody has seen before must not make the
    lab read the record as absent."""
    newer = DUMP.replace(
        "           Generation: 1\n",
        "           Generation: 1\n          Something New: whatever it says\n", 1,
    )
    record = login.record_for(newer)
    assert record is not None and record.enabled


def test_an_empty_dump_is_no_record_rather_than_a_crash():
    assert login.records("") == []
    assert login.record_for("") is None
    assert login.record_for("sfltool: command not found") is None


class Guest:
    def __init__(self, text):
        self.text = text
        self.commands = []

    def run(self, command, step, seconds=None, check=True):
        self.commands.append(command)
        import subprocess
        if self.text is None:
            return subprocess.CompletedProcess([], 1, "", "sfltool[915:7291] authorization failed")
        return subprocess.CompletedProcess([], 0, self.text, "")


class Machine:
    def __init__(self, text):
        self.name = "udeck-e2e-probe"
        self.ssh = Guest(text)


def test_the_guest_is_asked_for_its_own_database():
    machine = Machine(DUMP)
    record = login.record(machine)
    assert record is not None and record.url == "/Applications/uDeck.app"
    assert machine.ssh.commands == ["sudo -n /usr/bin/sfltool dumpbtm"]


def test_a_refusal_is_a_lab_failure_and_not_an_empty_database():
    """Measured in a guest: without privileges `sfltool` prints "authorization failed" and
    exits 1. Read as an empty dump — which is what a plain parse would do — that reads as
    "nothing is registered", and a check would pass while learning nothing."""
    from udeck_e2e.errors import LabError

    with pytest.raises(LabError, match="sfltool would not say"):
        login.record(Machine(None))
