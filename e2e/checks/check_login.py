"""Does uDeck open when the operator logs in?

The setting exists because of a measured absence: uDeck was installed on the operator's
Mac on 13 September, launched once by hand, and after the next restart nothing brought it
back — for five days.

Three checks, and the third is what makes the first two mean anything: switching it on
puts a record in the system's own database, a machine that restarts comes back with uDeck
running, and a machine where it was switched off again comes back without it.

What decides them is never the switch in uDeck's window — an application asked whether it
is right has been asked nothing — and never System Events' list of "login items", which is
a different list (measured 2026-09-18: deleting uDeck from it emptied it while
`SMAppService` went on reporting exactly as before). It is the Background Task Management
database, which is what macOS acts on at login, read with `sfltool dumpbtm`.
"""

from udeck_e2e import app, login, ui, updates
from udeck_e2e.errors import LabError, expect

VERSION = ("0.4.1", "6")

# After the desktop is up, how long the system is given to open what it was told to open.
OPENS_WITHIN_SECONDS = 60
# And how long a machine that must open nothing is watched before it is believed.
NOTHING_OPENS_SECONDS = 45


def check_registers(machine, check_dir, lab):
    """Switching it on puts uDeck in the system's database, pointing at this copy."""
    _prepare(machine, check_dir, lab)

    before = login.collect(machine, check_dir, name='login-records-before.txt')
    expect(
        before is None or not before.enabled,
        f"the machine already had a login record before anything was switched on: "
        f"{before.describe() if before else ''}",
    )

    ui.click(machine, "general.openAtLogin", "switching Open at Login on")
    machine.sleep(3)
    machine.screenshot(check_dir, "switched on")

    after = login.collect(machine, check_dir, name='login-records-after.txt')
    expect(after is not None, "uDeck was switched on and the system has no record of it")
    expect(after.enabled, f"the system's record is not enabled: {after.describe()}")
    expect(
        after.url == f"{app.GUEST_APPLICATIONS}/{app.APP}",
        f"the record points at {after.url or 'nothing'}, not at the copy that was switched on",
    )
    lab.note(f"   the system now has: {after.describe()}")


def check_survives_a_restart(machine, check_dir, lab):
    """A machine that restarts comes back with uDeck running, and nobody started it."""
    _prepare(machine, check_dir, lab)
    _switch_on(machine, check_dir, lab)

    machine.reboot()
    running = _wait_until_it_opens(machine, OPENS_WITHIN_SECONDS)
    machine.screenshot(check_dir, "after the restart")
    # Read once, and used by both sentences below: a message is built whether or not it is
    # needed, so a record fetched inside one costs a trip to the guest on every pass.
    after = login.record(machine)

    expect(running, f"the machine restarted and uDeck did not open; the system's record says {_describe(after)}")
    # Nothing in this check launches uDeck after the restart, so the process that is there
    # is the system's doing — and the record is still the one that was switched on.
    expect(after is not None and after.enabled, f"uDeck is running but the record is {_describe(after)}")
    lab.note(f"   uDeck came back on its own as {sorted(app.running_pids(machine))}")


def check_off_stays_off(machine, check_dir, lab):
    """Switched on and then off again, a machine that restarts comes back without uDeck.

    The control for the check above, and it is switched *on* first on purpose: a machine
    where nothing was ever registered would also come back without uDeck, and would prove
    only that the lab can watch a machine do nothing.
    """
    _prepare(machine, check_dir, lab)
    _switch_on(machine, check_dir, lab)

    ui.click(machine, "general.openAtLogin", "switching Open at Login off again")
    machine.sleep(3)
    machine.screenshot(check_dir, "switched off again")
    off = login.record(machine)
    expect(
        off is None or not off.enabled,
        f"it was switched off and the system still has {_describe(off)}",
    )

    machine.reboot()
    running = _wait_until_it_opens(machine, NOTHING_OPENS_SECONDS)
    machine.screenshot(check_dir, "after the restart")
    after = login.record(machine)

    expect(
        not running,
        f"uDeck opened at login although it had been switched off; the record says {_describe(after)}",
    )


# --- What all three do --------------------------------------------------------------


def _prepare(machine, check_dir, lab):
    """A lab build of uDeck installed and running, with its settings open on General.

    The build carries a feed nobody serves, on the guest's own loopback: a lab build must
    not be able to update itself against anything real (Q41), and none of these checks is
    about updating.
    """
    feed = updates.Feed(machine, lab.note)
    build = lab.builder(feed.url, check_dir.name).build(*VERSION)

    app.install(machine, build.zip, lab.note)
    there = app.installed_version(machine)
    if there != VERSION:
        raise LabError("preparing the machine", f"the lab installed {VERSION}, but the machine has {there}")

    app.launch(machine)
    ui.open_settings_and_wait(machine, "opening uDeck's settings")
    ui.wait_for(machine, "section.general", "waiting for the settings window")
    ui.click(machine, "section.general", "choosing General")
    ui.wait_for(machine, "general.openAtLogin", "waiting for the login card")
    machine.screenshot(check_dir, "uDeck running")


def _switch_on(machine, check_dir, lab):
    """Switch it on and refuse to go on unless the system agrees that it is on."""
    ui.click(machine, "general.openAtLogin", "switching Open at Login on")
    machine.sleep(3)
    machine.screenshot(check_dir, "switched on")
    record = login.collect(machine, check_dir, name="login-records-after-switching-on.txt")
    if record is None or not record.enabled:
        # The rest of the check is about what happens to a record that is there.
        raise LabError("switching Open at Login on", f"the system did not take it: {_describe(record)}")
    lab.note(f"   the system now has: {record.describe()}")


def _wait_until_it_opens(machine, seconds):
    """Whether uDeck is running, given `seconds` for the system to get round to it.

    Waiting the whole time when nothing opens is the point in the control: "it did not
    open" is worth something only after long enough for it to have opened.
    """
    deadline = machine.clock() + seconds
    while True:
        if app.running_pids(machine, "looking for uDeck after the restart"):
            return True
        if machine.clock() >= deadline:
            return False
        machine.sleep(5)


def _describe(record):
    return record.describe() if record is not None else "nothing at all"
