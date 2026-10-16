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


# --- Which row a check is asking about ----------------------------------------------


def _row(n, uuid, url, enabled, generation=1):
    disposition = "[enabled, allowed, notified] (0xb)" if enabled else "[disabled, allowed, notified] (0xa)"
    return (
        f" #{n}:\n                 UUID: {uuid}\n                 Name: uDeck\n"
        f"          Disposition: {disposition}\n           Identifier: 2.place.unicorns.udeck\n"
        f"                  URL: {url}\n           Generation: {generation}\n"
        f"    Bundle Identifier: place.unicorns.udeck\n"
    )


LIVE = "/Applications/uDeck.app"
OTHER = "/Users/x/Applications/uDeck.app"


def test_the_row_a_check_switched_on_is_found_by_its_identity_and_not_by_being_enabled():
    """The failure this is here for: a check switched its own row off, and another copy's
    row beside it was enabled. "Whichever uDeck row is enabled" read the other copy's and
    pronounced that uDeck had not switched *its* row off, when it had."""
    dump = _row(1, "A", LIVE, enabled=False) + _row(2, "B", OTHER, enabled=True)
    mine = login.records_for(dump)

    assert login.pick(mine).uuid == "B", "asked about nothing in particular, the enabled one decides"
    picked = login.pick(mine, "A")
    assert picked.uuid == "A" and not picked.enabled, "asked about row A, row A — disabled, as it is"
    assert [r.uuid for r in login.enabled_elsewhere(mine, "A")] == ["B"]


def test_a_row_that_is_gone_is_no_row_rather_than_the_next_one_along():
    """Replaced, the switched-on row must not be answered for by whatever stands in its
    place — that is how a new registration wearing the same path went unseen."""
    mine = login.records_for(_row(1, "B", LIVE, enabled=True))
    assert login.pick(mine, "A") is None


def test_a_dump_that_prints_no_identity_still_answers_the_old_way():
    """The UUID is read out of a report meant for a person. A macOS that stops printing it
    must cost the lab the distinction, not every run — and no two rows can then be told
    apart, so none is reported as enabled elsewhere."""
    dump = (_row(1, "A", LIVE, enabled=False) + _row(2, "B", OTHER, enabled=True)).replace("UUID: A\n", "").replace("UUID: B\n", "")
    dump = "\n".join(line for line in dump.splitlines() if "UUID:" not in line) + "\n"
    mine = login.records_for(dump)
    assert all(not r.uuid for r in mine)
    assert login.pick(mine, "A").url == OTHER, "without identities, the enabled one decides"
    assert login.enabled_elsewhere(mine, "A") == []


def test_the_record_names_one_path_however_sfltool_spells_it():
    """macOS 27 prints a path, macOS 26.6.2 a file URL (run 38213314297): the same copy either way."""
    from udeck_e2e.login import record_path

    assert record_path("/Applications/uDeck.app") == "/Applications/uDeck.app"
    assert record_path("file:///Applications/uDeck.app/") == "/Applications/uDeck.app"
    assert record_path("file:///Users/runner/My%20Apps/uDeck.app/") == "/Users/runner/My Apps/uDeck.app"
    assert record_path("(null)") == "" and record_path("") == ""
    assert record_path("file:///") == "/"


# --- What the guest's log says was done with the record --------------------------------
#
# Lines as they were read in a macOS 27 guest on 2026-10-12 (runs 20261012-180909Z and
# -181746Z), shortened only where `<private>` stood.

SWITCHED_ON = (
    "2026-10-12 18:11:49.441 Df backgroundtaskmanagementd[291:961] [com.apple.backgroundtaskmanagement:main] "
    "registerLaunchItem: pid=809, uid=501, type=app, url=(null), config=(null)\n"
)
SWITCHED_OFF = (
    "2026-10-12 18:22:35.672 Df backgroundtaskmanagementd[261:1aef] [com.apple.backgroundtaskmanagement:main] "
    "unregisterLaunchItem: pid=809, uid=501, type=app, url=(null)\n"
)
UDECK_STARTED = (
    "2026-10-12 18:11:42.472 Df uDeck[809:17dc] [com.apple.runningboard:connection] "
    "Identity resolved as app<application.place.unicorns.udeck.525647.525652(501)>\n"
)
LAUNCHER = (
    "2026-10-12 18:12:50.951 Df loginwindow[167:515] [com.apple.loginwindow.logging:Standard] "
    "-[LoginItemsLauncher main] | enter, safeboot = 0\n"
)
AUTOLAUNCH = (
    "2026-10-12 18:12:50.975 Df loginwindow[167:515] [com.apple.loginwindow.logging:Standard] "
    "LaunchItemsInSharedFileListRef |                 performAutolaunch, launching: /Applications/uDeck.app, shouldHide: 0\n"
)
AS_A_LOGIN_ITEM = (
    "2026-10-12 18:12:50.977 I  loginwindow[167:515] [com.apple.launchservices:entrypoint] LSOpenApplication(appParameters(v=1 "
    "flags=0x800201 appRef=NULL-FSRef refCon=0x0 env=(null) args=(null) event=<NSAppleEventDescriptor: 'aevt'\\134'oapp'{ 'prdt':'lgit' }>)\n"
)
LAUNCHED = (
    "2026-10-12 18:12:51.063 I  CoreServicesUIAgent[347:801] [com.apple.launchservices:open] _LSLaunchRB(place.unicorns.udeck "
    "<private>, event=aevt/oapp, args=- 0x810200/dontSwitch async  opts=LSOpen2Options(preferRunning )\n"
)
# macOS putting back what was running at the restart (probe.tal): the same LaunchServices
# event, another open event, and no login items launcher naming the copy.
REOPENED = (
    "2026-10-12 18:25:52.863 I  loginwindow[165:349] [com.apple.launchservices:entrypoint] LSOpenApplication(appParameters(v=1 "
    "flags=0x801100 appRef=NULL-FSRef refCon=0x0 env=(null) args=(null) event=<NSAppleEventDescriptor: 'aevt'\\134'oapp'{ ~'rsto':'yes ' }>)\n"
    "2026-10-12 18:25:52.910 I  CoreServicesUIAgent[344:818] [com.apple.launchservices:open] _LSLaunchRB(place.unicorns.udeck "
    "<private>, event=aevt/oapp, args=- 0x801100/ opts=LSOpen2Options(preferRunning )\n"
)
BOOT = "2026-10-12 18:12:37"


def _seen(text, known=(), boot=BOOT):
    return login.Witnesses(tuple(login.log_lines("Timestamp               Ty Process[PID:TID]\n" + text)), frozenset(known), boot)


def test_a_line_is_read_without_the_subsystem_in_front_of_what_was_said():
    (line,) = login.log_lines(SWITCHED_ON)
    assert (line.process, line.pid) == ("backgroundtaskmanagementd", 291)
    assert line.said.startswith("registerLaunchItem: pid=809")


def test_a_registration_is_uDecks_by_its_pid_whether_the_lab_or_the_log_knew_it():
    assert _seen(SWITCHED_ON, known={809}).registrations()
    assert _seen(UDECK_STARTED + SWITCHED_ON).registrations(), "uDeck's own start names its pid"
    assert not _seen(SWITCHED_ON).registrations(), "a pid nothing says is uDeck's is not uDeck"
    assert _seen(SWITCHED_ON).others_registering()


def test_switching_it_off_is_not_a_registration():
    """`unregisterLaunchItem` ends with the same words; counted, the control would call
    switching off a second registration."""
    assert len(_seen(SWITCHED_ON + SWITCHED_OFF, known={809}).registrations()) == 1


def test_the_record_opening_uDeck_is_three_lines_in_a_row_after_the_boot():
    seen = _seen(SWITCHED_ON + LAUNCHER + AUTOLAUNCH + AS_A_LOGIN_ITEM + LAUNCHED, known={809})
    assert seen.launcher_ran()
    assert seen.opened_at_login() == ["/Applications/uDeck.app"]
    assert seen.asked_at_login() == ["/Applications/uDeck.app"]


@pytest.mark.parametrize(
    "lines, why",
    [
        (LAUNCHER + AUTOLAUNCH + LAUNCHED, "not asked for as a login item"),
        (LAUNCHER + AUTOLAUNCH + AS_A_LOGIN_ITEM, "never launched"),
        (LAUNCHER + AS_A_LOGIN_ITEM + LAUNCHED, "no launcher naming the copy"),
        (LAUNCHER + REOPENED, "macOS putting back what was running"),
        (LAUNCHED + LAUNCHER + AUTOLAUNCH + AS_A_LOGIN_ITEM, "the launch came first"),
    ],
)
def test_anything_less_is_not_the_record_opening_uDeck(lines, why):
    assert _seen(lines).opened_at_login() == [], why


def test_the_record_opening_uDeck_is_held_to_the_login_item_s_flags_and_to_coming_next():
    """The launch has to carry the login item's flags, not macOS putting back what was
    running (`0x801100/`), and LaunchServices has to be asked as a login item by the next
    thing loginwindow says after the launcher names the copy — `LSOpenApplication` names
    no application, so coming next is what ties it to the copy."""
    tal_launch = LAUNCHED.replace("args=- 0x810200/dontSwitch async", "args=- 0x801100/")
    assert _seen(LAUNCHER + AUTOLAUNCH + AS_A_LOGIN_ITEM + tal_launch).opened_at_login() == []
    # The first launch of uDeck after the ask is the one read, and it is the putting back.
    assert _seen(LAUNCHER + AUTOLAUNCH + AS_A_LOGIN_ITEM + tal_launch + LAUNCHED).opened_at_login() == []
    between = LAUNCHER.replace("18:12:50.951", "18:12:50.976")
    assert _seen(LAUNCHER + AUTOLAUNCH + between + AS_A_LOGIN_ITEM + LAUNCHED).opened_at_login() == []


def test_two_logins_after_the_boot_are_counted_as_two():
    """A guest's clock can be anywhere (one in the series read 2026-09-17): the lines of
    another boot read as this one's show up as a second run of the launcher."""
    assert _seen(LAUNCHER).launcher_runs() == 1
    assert _seen(LAUNCHER + LAUNCHER.replace("18:12:50.951", "18:13:10.000")).launcher_runs() == 2
    assert _seen("").launcher_runs() == 0


def test_only_what_happened_after_the_boot_counts():
    """The login of the boot before the check is not this one."""
    before = AUTOLAUNCH.replace("18:12:50.975", "18:10:00.000") + AS_A_LOGIN_ITEM.replace("18:12:50.977", "18:10:00.001")
    seen = _seen(LAUNCHER.replace("18:12:50.951", "18:09:59.000") + before + LAUNCHED.replace("18:12:51.063", "18:10:00.002"))
    assert not seen.launcher_ran() and seen.opened_at_login() == [] and seen.launches() == []


def test_the_generation_s_movers_are_counted_as_evidence():
    use = (
        "2026-10-12 18:11:54.256 Df backgroundtaskmanagementd[291:961] [com.apple.backgroundtaskmanagement:main] "
        "noteUseOfItemWithIdentifier: identifier=2.place.unicorns.udeck, uid=501\n"
    )
    theme = (
        "2026-10-12 18:11:43.954 Df ThemeWidgetControlViewService[836:185e] [com.apple.runningboard:connection] Identity "
        "resolved as xpcservice<com.apple.appkit.xpc.ThemeWidgetControlViewService([app<application.place.unicorns.udeck.1.2(501)>:809])>\n"
    )
    seen = _seen(SWITCHED_ON + use * 3 + theme, known={809})
    assert (seen.uses(), seen.theme_widgets()) == (3, 1)
    assert seen.evidence() == "1 registration(s) by uDeck, 3 noteUseOfItem, 1 ThemeWidgetControlViewService started for uDeck"


def test_the_log_is_asked_for_exactly_the_lines_the_witnesses_read():
    """Each kind of line the witnesses read is in the predicate the guest is asked with."""
    for words in ("registerLaunchItem: pid=", "LoginItemsLauncher main] | enter", "performAutolaunch, launching: ",
                  "LSOpenApplication(", "_LSLaunchRB(", "Identity resolved as ", "noteUseOfItemWithIdentifier"):
        assert words in login.LOG_PREDICATE, words
