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


def check_survives_a_restart(machine, check_dir, lab):
    """A machine that restarts comes back with uDeck running, and nobody started it."""
    _prepare(machine, check_dir, lab)
    switched_on = _switch_on(machine, check_dir, lab)

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
            f"{_record_or_why_not(machine, check_dir)}"
        )

    # Nothing in this check launches uDeck after the restart, so the process that is there
    # is the system's doing — and the record is still the one that was switched on. This
    # read is that verdict's oracle rather than its evidence, so a database that cannot be
    # read is the lab failing, and says so.
    after = login.collect(machine, check_dir, name="login-records-after-the-restart.txt")
    expect(after is not None and after.enabled, f"uDeck is running but the record is {_describe(after)}")
    _expect_the_same_record(after, switched_on, "the restart")
    # Opening an application at login rewrites its record exactly once. Measured on
    # 2026-09-21, six restarts out of six with uDeck quit first and nothing reopened by
    # macOS: generation 1 before, 2 after, the same row. That makes the generation the
    # witness for *who* brought uDeck back, three ways:
    #
    # * unchanged — the record was not acted on, so whatever opened uDeck was not it, and
    #   this run says nothing about whether it would have. The lab's failure, not uDeck's.
    # * one more — the record opened it. What this check is for.
    # * more than that — uDeck registered itself again on top, which it must not do: it
    #   registers only when asked.
    #
    # A correction worth keeping: this used to demand the generation stand still, from a
    # measurement on 2026-09-19 that said 1 before and 1 after. Every one of those runs had
    # left uDeck running across the restart, so the record was never what opened it — the
    # assertion had encoded the wrong reason for the check being green.
    rewrites = after.generation - switched_on.generation
    if rewrites == 0:
        raise LabError(
            "telling the login record's doing from anything else's across the restart",
            f"uDeck came back, and its record was not touched — generation {after.generation} "
            f"before and after — so the record is not what opened it, and this run says nothing "
            f"about whether it would have: {after.describe()}",
        )
    expect(
        rewrites == 1,
        f"the restart left the record at generation {after.generation}, up from "
        f"{switched_on.generation} — opening it at login rewrites it once, so uDeck "
        f"registered itself again on top, and it registers only when asked: {after.describe()}",
    )
    # The pids the wait already read, not a fresh look: an SSH hiccup in a note must not
    # turn a check that has passed both its verdicts into a lab error.
    lab.note(f"   uDeck came back on its own as {sorted(pids)}")


def check_off_stays_off(machine, check_dir, lab):
    """Switched on and then off again, a machine that restarts comes back without uDeck.

    The control for the check above, and it is switched *on* first on purpose: a machine
    where nothing was ever registered would also come back without uDeck, and would prove
    only that the lab can watch a machine do nothing.

    Two different things can make uDeck open here, and they are told apart by the
    generation. Measured in a guest on 2026-09-19: unregistering does not remove the row
    at once — the dump shows it `[disabled] generation 2` straight after the click and
    stops showing it about half a minute later — while the database file on disk still
    names uDeck throughout. One run in five then came back from the restart with the row
    *enabled at generation 1*: the registration that was there before the switch, not a
    new one. So a record back at the old generation is macOS returning to the state it
    had on disk, and a record at a new generation would be something registering again —
    which for uDeck would be a bug of its own, since it registers only when asked.

    So the two readings get the two different outcomes. The old generation is the lab
    saying it could not check: the boot acted on a database that predates the switch, so
    the control's premise never held and nothing was decided about uDeck either way. A
    later one, or an unreadable record, is uDeck's to answer for.
    """
    _prepare(machine, check_dir, lab)
    switched_on = _switch_on(machine, check_dir, lab)

    ui.click(machine, "general.openAtLogin", "switching Open at Login off again")
    machine.sleep(3)
    machine.screenshot(check_dir, "switched off again")
    # Collected, not merely read: this reading is what the control's whole verdict rests
    # on, and a pass that kept nothing leaves the next person to rebuild the guest to
    # find out what it saw. The only database on disk used to be the one from switching
    # *on*, which shows the record enabled — the opposite of what the check concluded.
    off = login.collect(machine, check_dir, name="login-records-after-switching-off.txt")
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
    after, said = _collect_or_why_not(machine, check_dir)
    if pids and after is not None and after.enabled and after.generation == switched_on.generation:
        # Not a verdict, and the sentence itself is why: it says the database came back as
        # it stood before the switch. A control whose premise did not hold has checked
        # nothing — the boot never acted on the switching off this is about — and calling
        # that ❌ blames uDeck in the same breath as explaining that uDeck is not the
        # cause, which sends the next person hunting a bug that is not there. The other
        # reading is still ❌ below: a record at a *later* generation is something having
        # registered, and uDeck registers only when asked.
        raise LabError(
            "watching a machine that was switched off come back",
            f"uDeck opened, and the system's record is the one from before the switch, "
            f"unchanged: {said}. The restart came back with the database as it stood "
            f"before, not with the change — macOS's doing rather than uDeck registering "
            f"again, which would carry a later generation — so the machine never acted on "
            f"the switching off this control is about",
        )
    expect(
        not pids,
        f"uDeck opened at login although it had been switched off; the record says {said}",
    )


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
    feed = updates.Feed(machine, lab.note)
    try:
        builder = _prepare(machine, check_dir, lab, feed)
        before = _switch_on(machine, check_dir, lab)

        newer = builder.build(*NEWER)
        signature = updates.sign(newer.zip, lab.signing_key, updates.find_sign_update(lab.repo_root))
        appcast = check_dir / "appcast.xml"
        appcast.write_text(
            updates.appcast(updates.Offer(newer, signature, newer.zip.stat().st_size), feed.base_url)
        )
        feed.serve(appcast, newer.zip)
        _install_the_update(machine, check_dir, lab)

        after = login.collect(machine, check_dir, name="login-records-after-the-update.txt")
        machine.screenshot(check_dir, "after the update")

        # No guard on the version here, on purpose. `_install_the_update` returns only
        # once the newer version is the one on disk and otherwise raises, so a guard can
        # fire for one reason alone — a flaky read — and would then report the lab's bad
        # connection as a verdict about uDeck, which the docstring above forbids. It also
        # read the version twice on every pass, either of which could raise between the
        # record and the three sentences that judge it.
        expect(after is not None, f"the update left uDeck with no login record at all; before it was {before.describe()}")
        expect(after.enabled, f"the record did not survive the update: {after.describe()}")
        _expect_the_same_record(after, before, "the update")
        # Unlike a restart, an update *does* move the generation, and by exactly one:
        # measured in a guest on 2026-09-19, 1 before and 2 after, with the row's UUID
        # unchanged — macOS re-filing the record because the bundle at the path was
        # replaced. Anything beyond that is what the docstring above is about: an
        # application registering itself again, which is what makes macOS post "Login Item
        # Added" at every login.
        expect(
            after.generation <= before.generation + 1,
            f"the update left the record at generation {after.generation}, up from "
            f"{before.generation} — an update rewrites it once, so uDeck registered itself "
            f"again on top of it: {after.describe()}",
        )
        lab.note(f"   the record came through as: {after.describe()}")
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
    """Switch it on and refuse to go on unless the system agrees that it is on."""
    ui.click(machine, "general.openAtLogin", "switching Open at Login on")
    machine.sleep(3)
    machine.screenshot(check_dir, "switched on")
    record = login.collect(machine, check_dir, name="login-records-after-switching-on.txt")
    if record is None or not record.enabled:
        # The rest of the check is about what happens to a record that is there.
        raise LabError("switching Open at Login on", f"the system did not take it: {_describe(record)}")
    lab.note(f"   the system now has: {record.describe()}")
    return record


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


def _evidence(machine, check_dir, step, lab):
    """A screenshot as evidence: collected, never raised.

    The same helper the update checks keep, and here for the same reason (Q34, Q38): a
    machine too far gone to photograph must not take the verdict down with it.
    """
    try:
        machine.screenshot(check_dir, step)
    except LabError as error:
        lab.note(f"   no screenshot '{step}': {error.reason}")


def _collect_or_why_not(machine, check_dir, name="login-records-after-the-restart.txt"):
    """The record and a sentence about it, with the database kept — and neither able to raise.

    For the readings that are evidence for a verdict already decided. `login.collect`
    already swallows a failed write, so the only thing left that can throw is the read
    itself, and here it says so in the sentence instead of throwing.
    """
    try:
        record = login.collect(machine, check_dir, name=name)
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

    The UUID is the row. Measured in a guest on 2026-09-19: it is unchanged across a
    restart and across uDeck updating itself, while the generation moves in one of those
    and not the other — so the UUID is what says "the same record", and the generation
    says what happened to it.

    Guarded on both being there: the UUID is read out of a dump meant for a person, and a
    macOS that stops printing it must cost the lab this sentence rather than every run.
    """
    expect(
        after.url == THIS_COPY,
        f"after {what} the record points at {after.url or 'nothing'}, not at the copy that was "
        f"switched on ({THIS_COPY}) — another copy has taken it",
    )
    if before.uuid and after.uuid:
        expect(
            after.uuid == before.uuid,
            f"after {what} the record is a different row: {after.uuid}, and it was {before.uuid}. "
            f"The path is the same, so this is a new registration wearing it",
        )


def _describe(record):
    return record.describe() if record is not None else "nothing at all"
