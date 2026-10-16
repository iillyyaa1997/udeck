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
database, which is what macOS acts on at login, read with `sfltool dumpbtm` — for what the
record *is* — and the guest's own log, for what was *done* with it: uDeck registering itself,
and the record opening uDeck at login (`login.Witnesses`). The record's generation, which
used to stand in for both, is kept beside them as evidence only: macOS moves it as uDeck
starts and exits, not at either of those (README, "Open at Login").
"""

from udeck_e2e import app, login, targets, ui, updates
from udeck_e2e.errors import CheckFailed, LabError, expect

VERSION = ("0.4.1", "6")
# What uDeck updates itself to in the fourth check. The build number is what Sparkle
# compares; the version people read only has to differ so a person can see it happened.
NEWER = ("0.4.2", "7")

# The copy the record should name, and the copy the card should name — the same one.
THIS_COPY = f"{app.GUEST_APPLICATIONS}/{app.APP}"
# What the card says under the switch, in each of its two tenses. Read rather than
# assumed: the sentence is the only part of this feature the operator actually sees, and
# a card that says "Opens:" on a machine with no login record is a lie the database check
# above it cannot catch.
OPENS = f"Opens: {THIS_COPY}"
WOULD_OPEN = f"Would open: {THIS_COPY}"

# How long a machine is left alone between uDeck quitting and the restart, in the two
# checks that restart one.
#
# macOS reopens applications that were running when the session ended, and a uDeck
# brought back that way is indistinguishable from one the login record opened — which is
# what made an intermittent failure here take two days to name. Quitting uDeck first does
# not stop it, and neither does turning "reopen windows when logging back in" off in any
# of its four spellings. What stops it is time. Measured on 2026-09-21, every run with a
# polite quit that took under a fifth of a second, against this same flow:
#
#     no wait   3 reopens in 10
#     20 s      0 reopens in 10
#     45 s      0 reopens in 10
#     90 s      0 reopens in 10
#
# Twenty is where it already stops; thirty is that with half again on top, because the
# mechanism is not known. It is *not* the database settling — the record usually never
# leaves it at all, 8 times in 10 still there after 90 s — and the likeliest story, that
# loginwindow needs a moment to notice the application went, is a story. The checks read
# the guest's log afterwards either way, so a reopen that gets through this is reported
# rather than believed.
SETTLE_BEFORE_RESTART_SECONDS = 30

# What the two checks that switch the item on from off need, and only a fresh machine
# has: the system keeps uDeck's record across a reinstall, so on a machine one check
# has already switched it on, the next one's click switches it off (measured on a
# GitHub runner, run 38213314297: login.survives-an-update after login.registers
# found the record disabled, generation 2). A Tart clone per check starts without
# one; on `--target here` the runner is one machine for the whole job.
NEVER_SWITCHED_ON = "a machine on which Open at Login has never been switched on"

# After the desktop is up, how long the system is given to open what it was told to open.
OPENS_WITHIN_SECONDS = 60
# And how long a machine that must open nothing is watched before it is believed.
NOTHING_OPENS_SECONDS = 45


@targets.needs_a_vm(NEVER_SWITCHED_ON)
def check_registers(machine, check_dir, lab):
    """Switching it on puts uDeck in the system's database, pointing at this copy."""
    _prepare(machine, check_dir, lab)

    before = login.collect(machine, check_dir, name='login-records-before.txt')
    expect(
        before is None or not before.enabled,
        f"the machine already had a login record before anything was switched on: "
        f"{before.describe() if before else ''}",
    )

    # Read once and judged once: both arguments to `expect` are evaluated whatever the
    # verdict, so asking twice is a second trip to the guest and a second answer, which
    # can be the one the message quotes while the first is the one that decided.
    said = _what_the_card_says(machine)
    expect(WOULD_OPEN in said, f"nothing opens at login, and the card does not say so; it says: {said}")

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
    said = _what_the_card_says(machine)
    expect(OPENS in said,
           f"the system opens this copy at login and the card does not say so; it says: {said}")
    lab.note(f"   the system now has: {after.describe()}")


@targets.needs_a_vm("a restart of the machine")
def check_survives_a_restart(machine, check_dir, lab):
    """A machine that restarts comes back with uDeck running, opened by its login record.

    Who opened it is read where macOS writes it down (`login.Witnesses`): after the boot,
    loginwindow's login items launcher opening this copy by its path, and LaunchServices
    launching uDeck for it with the event a login item is opened with — and, across the
    whole check, no registration from uDeck but the one the switch made.
    """
    since = login.clock(machine)
    _prepare(machine, check_dir, lab)
    switched_on, before = _switch_on(machine, check_dir, lab)

    # Quit before restarting, and the reason is the whole verdict. macOS reopens
    # applications that were running when the session ended — its Transparent App
    # Lifecycle — and a uDeck brought back that way looks exactly like one the
    # login record opened. Measured in a guest on 2026-09-20, in the control
    # below: `loginwindow … persistentAppPreLaunch … bundleID:place.unicorns.udeck`
    # with the record reading `[disabled]` the whole time. Leaving uDeck running
    # here would have given this check a second reason to be green that has
    # nothing to do with what it checks.
    app.quit_app(machine, "quitting uDeck so that only the login record can bring it back")
    # And then left alone, because quitting on its own is not enough: see
    # SETTLE_BEFORE_RESTART_SECONDS for what was measured.
    machine.sleep(SETTLE_BEFORE_RESTART_SECONDS)

    machine.reboot()
    pids = _wait_until_it_opens(machine, OPENS_WITHIN_SECONDS)
    _refuse_if_the_system_reopened_it(machine, "the restart")
    # Nothing that can raise may stand between that measurement and the sentence below
    # that judges it. A machine which lost its login item across a restart is also a
    # machine whose sudo, VNC and SSH are suspect, and a screenshot or a database read
    # that fails here turns "uDeck did not come back" into "could not check" — on exactly
    # the run that had something to say.
    _evidence(machine, check_dir, "after the restart", lab)
    if not pids:
        raise CheckFailed(
            f"the machine restarted and uDeck did not open; the system's record says "
            f"{_record_or_why_not(machine, check_dir)}{_what_the_login_did(machine, check_dir, since, before)}"
        )

    # Nothing in this check launches uDeck after the restart, so the process that is there
    # is the system's doing — and the record is still the one that was switched on. This
    # read is that verdict's oracle rather than its evidence, so a database that cannot be
    # read is the lab failing, and says so.
    rows = login.collect_rows(machine, check_dir, name="login-records-after-the-restart.txt")
    after = login.pick(rows, switched_on.uuid)
    elsewhere = login.enabled_elsewhere(rows, switched_on.uuid)
    expect(
        after is not None,
        "the row that was switched on is gone after the restart"
        + (f", and another copy is set to open at login instead: "
           f"{'; '.join(r.describe() for r in elsewhere)}" if elsewhere else ""),
    )
    expect(
        after.enabled,
        f"uDeck is running but the record that was switched on is {after.describe()}"
        + (f" — what opened at login is another copy: {'; '.join(r.describe() for r in elsewhere)}"
           if elsewhere else ""),
    )
    _expect_the_same_record(after, switched_on, "the restart")

    # Who brought uDeck back, and whether uDeck registered itself on top, used to be read
    # off the generation: "+1 is the record opening it, more is uDeck registering again".
    # Measured on 2026-10-12, it answers neither — it moves on `noteUseOfItem`, which
    # macOS writes as uDeck starts and as it exits, here at the lab's own quit before the
    # restart or not at all — and it failed 6 readings of 28 in the round before, the two
    # whose logs were kept with no registration after the switch (README, "Open at
    # Login"). So both are read in the log, and the generation is only said.
    said = _witnesses(machine, check_dir, since, before, pids, step="reading who opened uDeck after the restart")
    _expect_no_registration_after_the_switch(said)
    _expect_one_login(said, "telling the login record's doing from anything else's across the restart",
                      f"whether the login items launcher opened uDeck cannot be read: {_launches(said)}")
    opened = said.opened_at_login()
    if not opened:
        # uDeck is running and the record did not open it: something else did, and this
        # run says nothing about whether the record would have. The lab's failure.
        raise LabError(
            "telling the login record's doing from anything else's across the restart",
            f"uDeck came back, and the login items launcher did not open it — it opened "
            f"{said.asked_at_login() or 'nothing'} — so the record is not what brought it back, and this run "
            f"says nothing about whether it would have: {_launches(said)}",
        )
    expect(
        opened == [THIS_COPY],
        f"the login record opened {opened} after the restart, not the copy that was switched on ({THIS_COPY})",
    )
    lab.note(
        f"   the login items launcher opened {THIS_COPY} after the restart; the record is at generation "
        f"{after.generation}, up from {switched_on.generation} (evidence only: {said.evidence()})"
    )
    # The pids the wait already read, not a fresh look: an SSH hiccup in a note must not
    # turn a check that has passed both its verdicts into a lab error.
    lab.note(f"   uDeck came back on its own as {sorted(pids)}")


@targets.needs_a_vm("a restart of the machine")
def check_off_stays_off(machine, check_dir, lab):
    """Switched on and then off again, a machine that restarts comes back without uDeck.

    The control for the check above, and it is switched *on* first on purpose: a machine
    where nothing was ever registered would also come back without uDeck, and would prove
    only that the lab can watch a machine do nothing.

    It reads the same witness as the check above (`login.Witnesses`), and the witness has
    to be able to say yes in this very boot for its no to mean anything: the login items
    launcher has to be seen running after the restart — it runs at every login, items or
    none — and then not opening uDeck.

    One thing can open uDeck here without uDeck being at fault, and the log tells it apart.
    Measured in a guest on 2026-09-19: unregistering does not remove the row at once — the
    dump shows it `[disabled]` straight after the click and stops showing it about half a
    minute later — while the database file on disk still names uDeck throughout. One run in
    five then came back from the restart with the row *enabled again*: the registration
    that was there before the switch, not a new one. So a record enabled after the restart,
    with no registration from uDeck after the switch, is macOS returning to the state it had
    on disk — the boot never acted on the switching off, the control's premise did not
    hold, and the lab says it could not check. A registration from uDeck after the switch is
    uDeck's to answer for, since it registers only when asked. That used to be told apart by
    the generation, which counts other things too (README, "Open at Login").
    """
    since = login.clock(machine)
    _prepare(machine, check_dir, lab)
    switched_on, before = _switch_on(machine, check_dir, lab)

    ui.click(machine, "general.openAtLogin", "switching Open at Login off again")
    machine.sleep(3)
    machine.screenshot(check_dir, "switched off again")
    # Collected, not merely read: this reading is what the control's whole verdict rests
    # on, and a pass that kept nothing leaves the next person to rebuild the guest to
    # find out what it saw. The only database on disk used to be the one from switching
    # *on*, which shows the record enabled — the opposite of what the check concluded.
    rows = login.collect_rows(machine, check_dir, name="login-records-after-switching-off.txt")
    # The row this check switched on, by its UUID — not "whichever uDeck row is
    # enabled". With another copy's row enabled beside it, the old reading picked that
    # one and pronounced that uDeck had failed to switch *its* row off, when it had.
    off = login.pick(rows, switched_on.uuid)
    elsewhere = login.enabled_elsewhere(rows, switched_on.uuid)
    if elsewhere:
        # Not a verdict either way: another copy is set to open at login, so a machine
        # that comes back with uDeck running says nothing about this one's switch.
        raise LabError(
            "switching Open at Login off again",
            f"another copy of uDeck is set to open at login — "
            f"{'; '.join(r.describe() for r in elsewhere)} — so this machine cannot show "
            f"that switching this one off works",
        )
    expect(
        off is None or not off.enabled,
        f"it was switched off and the system still has {_describe(off)}",
    )

    # The same reason as in the check above, and this is where it was caught: with
    # uDeck left running, macOS reopened it after two restarts in twelve that the
    # login record forbade, and the check called that uDeck's doing.
    app.quit_app(machine, "quitting uDeck so that nothing but the login record could bring it back")
    machine.sleep(SETTLE_BEFORE_RESTART_SECONDS)

    machine.reboot()
    pids = _wait_until_it_opens(machine, NOTHING_OPENS_SECONDS)
    _refuse_if_the_system_reopened_it(machine, "the restart")
    # Same order, same reason: uDeck opening here is the failure this control exists to
    # catch, and neither the screenshot nor the database may be able to swallow it.
    _evidence(machine, check_dir, "after the restart", lab)
    after, record = _collect_or_why_not(machine, check_dir, uuid=switched_on.uuid)
    # The log is the oracle here, and still nothing that can raise may stand between uDeck
    # running and the sentence that says so: a log that cannot be read is said in it.
    try:
        said = _witnesses(machine, check_dir, since, before, pids, step="reading who opened what after the restart")
        unread = ""
    except LabError as error:
        said, unread = None, error.reason
    registered = said.registrations() if said is not None else []
    again = registered[1:]
    expect(
        not again,
        f"uDeck registered itself again after it was switched on, and it registers only when asked: "
        f"{'; '.join(str(line) for line in again)}",
    )
    # Read only from a log that holds one login: with another boot's lines among them, what
    # was opened may be that boot's (`_expect_one_login`, below, says so once uDeck's own
    # life has been read).
    opened = said.opened_at_login() if said is not None and said.launcher_runs() <= 1 else []
    if opened and after is not None and after.enabled:
        # Not a verdict, and the sentence itself is why: the record came back enabled and
        # nothing registered it after the switch, so the boot acted on the database as it
        # stood before the switching off this control is about. Calling that ❌ blames
        # uDeck in the same breath as explaining that uDeck is not the cause.
        raise LabError(
            "watching a machine that was switched off come back",
            f"the login record opened uDeck, and it is enabled again: {record}. "
            + (
                "Nothing registered it after the switch — the log holds the switch's own registration and no "
                "other — so the restart came back with the database as it stood before the switching off, "
                "macOS's doing rather than uDeck's, and the machine never acted on the switching off this "
                "control is about"
                if registered
                else "The log holds no registration from uDeck at all, not even the switch's, so whether "
                "something registered it again cannot be read"
            ),
        )
    expect(
        not opened,
        f"the login record opened {opened} at login although it had been switched off; the record says {record}",
    )
    expect(
        not pids,
        f"uDeck opened at login although it had been switched off, and not by its record: "
        f"{_launches(said) if said is not None else f'the log could not be read ({unread})'}; "
        f"the record says {record}",
    )
    if said is None:
        raise LabError("watching a machine that was switched off come back", f"the guest's log could not be read: {unread}")
    if not registered:
        raise LabError(
            "reading uDeck's registrations in the guest's log",
            "the log holds no `registerLaunchItem` from uDeck since the check began — not even the one the "
            "switch made — so its holding none after the switch says nothing",
        )
    _expect_one_login(said, "watching a machine that was switched off come back",
                      "the login items launcher not opening uDeck is not something this log can show; "
                      f"the record says {record}")
    lab.note(f"   the login items launcher ran and opened {said.asked_at_login() or 'nothing'} ({said.evidence()})")


@targets.needs_a_vm(NEVER_SWITCHED_ON)
def check_survives_an_update(machine, check_dir, lab):
    """uDeck updates itself, and the system's record comes through it intact.

    The record names a path, and an update replaces what is at that path — so this is the
    check that would catch a login item pointing at a bundle Sparkle has since swapped, or
    an application that quietly re-registers itself on every launch and racks up
    generations (which is what makes macOS post "Login Item Added" at every login).

    Installing the update is a precondition here, not the thing under test: that it works
    at all is what `updates.sparkle` is for. So a failure to offer or to install is the
    lab being unable to carry this check out, never a verdict about uDeck.
    """
    since = login.clock(machine)
    feed = updates.Feed(machine, lab.note)
    try:
        builder = _prepare(machine, check_dir, lab, feed)
        before, pids = _switch_on(machine, check_dir, lab)

        newer = builder.build(*NEWER)
        signature = updates.sign(newer.zip, lab.signing_key, updates.find_sign_update(lab.repo_root))
        appcast = check_dir / "appcast.xml"
        appcast.write_text(
            updates.appcast(updates.Offer(newer, signature, newer.zip.stat().st_size), feed.base_url)
        )
        feed.serve(appcast, newer.zip)
        _install_the_update(machine, check_dir, lab)

        after = login.collect(machine, check_dir, name="login-records-after-the-update.txt", uuid=before.uuid)
        machine.screenshot(check_dir, "after the update")

        # No guard on the version here, on purpose. `_install_the_update` returns only
        # once the newer version is the one on disk and otherwise raises, so a guard can
        # fire for one reason alone — a flaky read — and would then report the lab's bad
        # connection as a verdict about uDeck, which the docstring above forbids. It also
        # read the version twice on every pass, either of which could raise between the
        # record and the three sentences that judge it.
        expect(
            after is not None,
            f"the row that was switched on is gone after the update; before it was {before.describe()}",
        )
        expect(after.enabled, f"the record did not survive the update: {after.describe()}")
        _expect_the_same_record(after, before, "the update")
        # Whether uDeck registered itself again on top of the update is read where macOS
        # writes it down — what the docstring above is about, and what makes macOS post
        # "Login Item Added" at every login. It used to be read off the generation, "an
        # update rewrites it once": measured on 2026-10-12, an update moves it by one, or
        # by two or three when uDeck's exit races Sparkle's relaunch, with no
        # registration anywhere in the log (README, "Open at Login").
        relaunched = app.running_pids(machine, "reading the pid uDeck came back as after the update")
        said = _witnesses(machine, check_dir, since, pids, relaunched, step="reading what the update did to the record")
        _expect_no_registration_after_the_switch(said)
        lab.note(
            f"   the record came through as: {after.describe()}, up from generation {before.generation} "
            f"(evidence only: {said.evidence()})"
        )
    finally:
        feed.collect_log(check_dir)
        feed.stop()


# --- What all four do ---------------------------------------------------------------


def _prepare(machine, check_dir, lab, feed=None):
    """A lab build of uDeck installed and running, with its settings open on General.

    The build points at the guest's own loopback, and for three of the four checks nothing
    serves it: a lab build must not be able to update itself against anything real (Q41).
    The fourth passes its own feed in and then serves something on it.
    """
    feed = feed or updates.Feed(machine, lab.note)
    builder = lab.builder(feed.url, check_dir.name)
    build = builder.build(*VERSION)

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
    return builder


def _switch_on(machine, check_dir, lab):
    """Switch it on and refuse to go on unless the system agrees that it is on.

    Answers the record and the pids uDeck ran as when it was switched on: the
    registration that switch makes names uDeck by its pid alone (`login.Witnesses`).
    """
    pids = app.running_pids(machine, "reading the pid uDeck runs as before it is switched on")
    ui.click(machine, "general.openAtLogin", "switching Open at Login on")
    machine.sleep(3)
    machine.screenshot(check_dir, "switched on")
    record = login.collect(machine, check_dir, name="login-records-after-switching-on.txt")
    if record is None or not record.enabled:
        # The rest of the check is about what happens to a record that is there.
        raise LabError("switching Open at Login on", f"the system did not take it: {_describe(record)}")
    lab.note(f"   the system now has: {record.describe()}")
    return record, pids


def _install_the_update(machine, check_dir, lab, seconds=240):
    """Drive uDeck's own About pane until the newer version is the one on disk.

    Every step here is a precondition, so every failure is the lab's: that uDeck can
    update itself is checked by `updates.sparkle`, and a check about login records must
    not pronounce on it.
    """
    step = "installing the update uDeck is offered"
    ui.click(machine, "section.about", "choosing the About section")
    ui.wait_for(machine, "updates.checkNow", "waiting for the About section")
    ui.click(machine, "updates.checkNow", "asking uDeck to look for an update")
    try:
        install = ui.wait_for(machine, "updates.install", "waiting for uDeck to offer the update", seconds=60)
    except LabError as error:
        raise LabError(step, f"uDeck did not offer the update: {error.reason}") from None
    machine.screenshot(check_dir, "the update is offered")
    machine.click(*install.middle, "installing the update")

    deadline = machine.clock() + seconds
    while True:
        if app.installed_version(machine) == NEWER:
            lab.note(f"   uDeck updated itself to {NEWER[0]}")
            return
        if machine.clock() >= deadline:
            raise LabError(step, f"uDeck was still {app.installed_version(machine)} after {seconds:.0f}s")
        machine.sleep(5)


def _wait_until_it_opens(machine, seconds):
    """The pids uDeck is running as, given `seconds` for the system to get round to it.

    Waiting the whole time when nothing opens is the point in the control: "it did not
    open" is worth something only after long enough for it to have opened. The pids
    themselves come back so that a caller wanting to name them does not have to ask the
    guest a second time, after its verdicts have already passed.
    """
    deadline = machine.clock() + seconds
    while True:
        pids = app.running_pids(machine, "looking for uDeck after the restart")
        if pids:
            return pids
        if machine.clock() >= deadline:
            return set()
        machine.sleep(5)


def _witnesses(machine, check_dir, since, *pids, step="reading the guest's log"):
    """What the guest's log says was done with the record since the check began (`login.Witnesses`).

    Kept beside the check's other evidence as `login-log.txt`, and read with every pid
    the lab itself saw uDeck run as; the boot is the guest's last, so "after the
    restart" means after it.
    """
    known = frozenset(int(pid) for group in pids for pid in group if str(pid).isdigit())
    return login.witnesses(machine, check_dir, since, step, known=known, boot=login.boot_clock(machine))


def _expect_no_registration_after_the_switch(said):
    """uDeck registered itself exactly once: when it was switched on.

    The switch's own registration has to be there for the absence of any other to
    mean anything — a log that holds no registration at all is a log that cannot
    show one, and that is the lab's failure, not a pass.
    """
    registered = said.registrations()
    if not registered:
        raise LabError(
            "reading uDeck's registrations in the guest's log",
            "the log holds no `registerLaunchItem` from uDeck since the check began — not even the one the "
            "switch made — so its holding none after the switch says nothing",
        )
    again = registered[1:]
    expect(
        not again,
        f"uDeck registered itself again after it was switched on, and it registers only when asked: "
        f"{'; '.join(str(line) for line in again)} (the switch's own: {registered[0]})",
    )


def _expect_one_login(said, step, otherwise):
    """The log since the boot holds exactly one login: the launcher ran once, after the boot.

    None is a log that cannot show what the login did. More than one is another boot's
    login read as this one's — "after the boot" is read on the guest's clock, which can
    be anywhere (`login.Witnesses.launcher_runs`) — and what it opened or did not open
    could be that boot's.
    """
    runs = said.launcher_runs()
    if runs == 0:
        raise LabError(step, f"the guest's log has no `LoginItemsLauncher main` after the boot, so {otherwise}")
    if runs > 1:
        raise LabError(
            step,
            f"the guest's log has {runs} runs of the login items launcher after the boot, where one login "
            f"writes one: lines of another boot are read as this one's, so {otherwise}",
        )


def _launches(said):
    """Every launch of uDeck the log holds after the boot, for a sentence."""
    launches = said.launches()
    return "LaunchServices launched uDeck " + ("; ".join(line.said for line in launches) if launches else "never")


def _what_the_login_did(machine, check_dir, since, before):
    """For the sentence that says uDeck did not come back: what the login items launcher did.

    Evidence, so it says what went wrong instead of raising (`_record_or_why_not`).
    """
    try:
        said = _witnesses(machine, check_dir, since, before, step="reading what the login did")
    except LabError as error:
        return f" (the guest's log could not be read: {error.reason})"
    runs = said.launcher_runs()
    launcher = "is not in the log" if runs == 0 else "ran" if runs == 1 else f"ran {runs} times, another boot's among them"
    return f"; the login items launcher {launcher} and opened {said.asked_at_login() or 'nothing'}"


def _evidence(machine, check_dir, step, lab):
    """A screenshot as evidence: collected, never raised.

    The same helper the update checks keep, and here for the same reason (Q34, Q38): a
    machine too far gone to photograph must not take the verdict down with it.
    """
    try:
        machine.screenshot(check_dir, step)
    except LabError as error:
        lab.note(f"   no screenshot '{step}': {error.reason}")


def _collect_or_why_not(machine, check_dir, name="login-records-after-the-restart.txt", uuid=""):
    """The record and a sentence about it, with the database kept — and neither able to raise.

    For the readings that are evidence for a verdict already decided. `login.collect`
    already swallows a failed write, so the only thing left that can throw is the read
    itself, and here it says so in the sentence instead of throwing.
    """
    try:
        record = login.collect(machine, check_dir, name=name, uuid=uuid)
    except LabError as error:
        return None, f"(the record could not be read: {error.reason})"
    return record, _describe(record)


def _record_or_why_not(machine, check_dir, name="login-records-after-the-restart.txt"):
    return _collect_or_why_not(machine, check_dir, name)[1]


def _what_the_card_says(machine):
    """Every sentence the login card shows — when a verdict turns on them."""
    return " | ".join(ui.static_texts(machine, "reading what the login card says"))


def _refuse_if_the_system_reopened_it(machine, what: str) -> None:
    """macOS reopening uDeck by itself makes this run prove nothing either way.

    Both restart checks quit uDeck first so that it cannot happen. This is the
    part that says it did not — because "it should not have" is exactly the
    reasoning that let an intermittent reopen pass for the login record's work for
    two days, and because a setting or a macOS release can put it back.

    Not a verdict: nothing here is about uDeck. The run could not isolate what it
    was isolating, which is the lab's failure to carry the check out.
    """
    if app.the_system_reopened_it(machine):
        raise LabError(
            f"telling the login record's doing from the system's across {what}",
            "macOS reopened uDeck by itself — its log says `persistentAppPreLaunch` for "
            "place.unicorns.udeck — so whatever uDeck did here cannot be told from the "
            "system putting back what was running. uDeck was quit before the restart "
            "precisely so this could not happen",
        )


def _expect_the_same_record(after, before, what: str) -> None:
    """The record is the one that was switched on, not one that merely looks like it.

    Two failures hide behind "there is an enabled record for uDeck", and both are what
    this feature exists to survive. The path: another copy of uDeck with the same bundle
    identifier takes the record simply by running, and the system then opens *it* —
    uDeck's own source calls that the main one. And the identity: the row itself can be
    replaced, which a path alone cannot see, because the replacement names the same path.

    The identity is settled before this is called: the checks look the row up by the UUID
    it had when it was switched on (`login.pick`), which is unchanged across a restart and
    across uDeck updating itself — measured in a guest on 2026-09-19 — while the generation
    moves in one of those and not the other. So a replaced row arrives here as no row at
    all, and is reported where it is looked up. What is left to ask is the path.
    """
    expect(
        after.url == THIS_COPY,
        f"after {what} the record points at {after.url or 'nothing'}, not at the copy that was "
        f"switched on ({THIS_COPY}) — another copy has taken it",
    )


def _describe(record):
    return record.describe() if record is not None else "nothing at all"
