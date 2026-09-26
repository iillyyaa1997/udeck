"""Does uDeck update itself — and does it look for an update only when it may?

Two checks, and the second is what makes the first worth trusting: an update
signed with the run's key installs, and one signed with another key does not.

And two more about the question that comes before any of that, which is when
uDeck asks its feed at all. **uDeck ships with automatic checks off**
(`SUEnableAutomaticChecks` is false in Sources/uDeck/Support/Info.plist): it
otherwise makes no network connection of any kind, so the first one it ever
makes should be one the operator chose (commit e00a79a, and the reason is
written again on `SparkleUpdater` and `UpdateChecking.checksAutomatically`).
One check holds uDeck to that, and the other holds the switch in the About pane
to what it says — once the operator turns it on, uDeck looks by itself. Both
are judged on the guest's own access log, which is the traffic and not a
sentence uDeck writes about itself.

Everything is real — a release build of this checkout, Sparkle, an appcast served
inside the machine — and nothing is asked of uDeck that a person could not do:
the settings window is opened from uDeck's own menu, the section is chosen and
the buttons are pressed with the machine's pointer, and what counts as success is
the version on disk afterwards, never what the screen says about itself.

Two rules run through the whole file, both learned from this check:

* A control that proves nothing does not pass. "Nothing installed" is the answer
  to a question nobody asked unless uDeck *tried* the update and refused it, so
  the control ends by showing it tried (Q37).
* Between a measurement and the sentence that judges it, nothing may raise. The
  screenshots and the pane's words there are evidence for a person, and evidence
  that cannot be collected must not turn a failed check into "could not check" —
  the failure the control exists to catch would be the first one lost (Q34).
"""

import re

from udeck_e2e import app, builds, ui, updates
from udeck_e2e.errors import LabError, NotThere, expect

FIRST = ("0.4.1", "6")
SECOND = ("0.4.2", "7")

# From pressing Install to the new version being on disk: Sparkle unpacks the
# archive, swaps the bundle and relaunches uDeck. The relaunch is waited for
# inside this, not on top of it.
INSTALL_SECONDS = 180

# How long the uDeck that came back after an update has to stay before it counts as
# having come back. An application that crashes on launch is running for a moment,
# and one look catches exactly that moment: the pid is new, the check is green, and
# uDeck is gone a second later. Watched throughout rather than read at the end, so
# the sentence can say when it went. Long enough to outlast a crash on launch; paid
# once a run.
RELAUNCH_SETTLE_SECONDS = 10

# How long the control waits for the button on an update it expects to be
# refused only when it is installed, and how long it then watches nothing happen.
OFFER_SECONDS = 60
REFUSAL_SECONDS = 90

# What uDeck says on the About pane once it has an answer of its own. The guest
# runs in English (Q43), and these are its words: `updatesUpToDate` and
# `updatesFailed` in Sources/UDeckCore/Localization/English.swift.
UP_TO_DATE = "is up to date"
DID_NOT_FINISH = "The check did not finish"

# The About pane's switch for automatic checks, by the identifier `AboutSection`
# gives it (Sources/UDeckKit/Views/SettingsView.swift, held against that file by
# the lab's own tests), and what it reads off: the accessibility API gives a
# checkbox's value as "0" or "1" — measured on this switch on 2026-09-26, an
# `AXCheckBox` reading "0" on a machine nobody had configured.
AUTOMATIC = "updates.automatic"
SWITCH_OFF = "0"

# How long the shipped uDeck is listened to after it starts. It is how long a
# uDeck that *does* look takes to ask, with room: with automatic checks forced on
# in the guest's preferences, six launches asked the feed 1.3 to 2.9 s after
# `open -a` was issued (measured 2026-09-26, .build/e2e/20260926-203904Z). Twenty
# seconds is about seven times the slowest — room for a guest sharing the Mac
# with the next check's machine under --jobs 2 — and the whole cost of the check
# is still the build. Listening longer would not reach anything Sparkle does:
# with automatic checks off it schedules nothing at all.
QUIET_SECONDS = 20

# From the click on the switch to the feed hearing uDeck. Sparkle resets its cycle
# one second after the setting changes (`resetUpdateCycleAfterDelay`, SPUUpdaterCycle.m),
# and measured, the guest's clock read 20:45:30.09 just before the click and the
# feed logged uDeck at 20:45:31 (same run). Fifteen seconds is that, several
# times over, with the same room for a busy guest.
SWITCHED_ON_SECONDS = 15

# From "Check now" to the feed hearing uDeck — the witness that a quiet uDeck
# could have asked. Measured 3.3 to 4.3 s from the lab starting to look for the
# button, the walk that finds it included (same run); here it is counted from the
# click, so it is shorter, and twenty seconds is room and nothing else.
ASKED_SECONDS = 20

# How often the feed's log is read while listening: the log's own clock counts
# in whole seconds, so reading it more often than that would learn nothing more.
LISTEN_EVERY_SECONDS = 1


def check_sparkle(machine, check_dir, lab):
    """The whole update: uDeck finds 0.4.2, installs it, and comes back as 0.4.2."""
    feed = updates.Feed(machine, lab.note)
    try:
        offered = _prepare(machine, check_dir, lab, feed, signed_by=None)
        _open_the_about_pane(machine, check_dir)

        ui.click(machine, "updates.checkNow", "asking uDeck to look for an update")
        install = _wait_until_it_is_offered(machine, check_dir, lab, offered, feed)
        machine.screenshot(check_dir, "the update is offered")
        said = _what_the_pane_says(machine)
        expect(
            offered.version in said,
            f"uDeck offered an update but does not name {offered.version}; it says: {said}",
        )

        before = app.running_pids(machine)
        machine.click(*install.middle, "installing the update")
        deadline = machine.clock() + INSTALL_SECONDS
        version = _the_version_once_it_is(machine, SECOND, deadline)
        after = _wait_for_the_relaunch(machine, before, deadline)
        _evidence(machine, check_dir, "after the update", lab)

        expect(version == SECOND, f"the version on disk is {version}, not {SECOND}")
        expect(
            bool(after - before),
            f"uDeck did not come back as a new process after the update: it was "
            f"{sorted(before) or 'not running'} before and is {sorted(after) or 'not running'} now",
        )
        _expect_the_new_uDeck_stayed(machine, before, after)
    finally:
        feed.collect_log(check_dir)
        feed.stop()


def _expect_the_new_uDeck_stayed(machine, before, after):
    """The uDeck that came back is still there a moment later — and it is the only one.

    `_wait_for_the_relaunch` returns the moment a new pid appears, which is the right
    thing for waiting and the wrong thing for judging: an update that installed a
    uDeck which crashes on launch shows a new pid for as long as the crash takes. So
    the new one is watched for a while, and has to be there every time it is asked.

    And the old one has to be gone. Sparkle replaces the running copy; an old process
    still there beside the new is an update that did not replace what was running,
    whatever the version on disk says.
    """
    fresh = after - before
    now = after
    began = machine.clock()
    while machine.clock() - began < RELAUNCH_SETTLE_SECONDS:
        machine.sleep(1)
        now = app.running_pids(machine, "watching the uDeck that came back after the update")
        expect(
            fresh <= now,
            f"uDeck came back after the update as {sorted(fresh)} and was gone "
            f"{machine.clock() - began:.0f}s later; it is {sorted(now) or 'not running'} now",
        )
    expect(
        not (before & now),
        f"the uDeck that was running before the update is still there as {sorted(before & now)}, "
        f"beside the new {sorted(fresh)} — the update did not replace the copy that was running",
    )


def check_wrong_key(machine, check_dir, lab):
    """An update signed with another key is refused — the control for the check above."""
    feed = updates.Feed(machine, lab.note)
    try:
        offered = _prepare(machine, check_dir, lab, feed, signed_by=builds.make_key(check_dir / "another-key"))
        _open_the_about_pane(machine, check_dir)

        ui.click(machine, "updates.checkNow", "asking uDeck to look for an update")
        # The signature is checked when the update is installed, not when it is
        # offered, so the control has to press Install — and an update it was
        # never offered is one whose signature was never reached. That is the lab
        # failing to set the question up, not uDeck answering it.
        step = "waiting for what uDeck does with an update signed by another key"
        try:
            install = ui.wait_for(machine, "updates.install", step, seconds=OFFER_SECONDS)
        except NotThere:
            raise LabError(
                step,
                "uDeck never offered the update, so nothing ever reached its signature. The "
                "appcast is served unsigned and Sparkle checks the key when it downloads, so "
                "the offer not appearing is about the feed, the window or the click — never "
                "about the key this control is named after",
            ) from None
        # The pids before the press. uDeck refusing an update carries on running as
        # itself; a uDeck that installed one comes back as a new process, and a
        # uDeck that died leaves none.
        before = app.running_pids(machine, "reading uDeck's pids before Install is pressed")
        machine.click(*install.middle, "pressing Install on an update signed with another key")

        version = _the_version_after(machine, REFUSAL_SECONDS)
        _evidence(machine, check_dir, "after the refusal", lab)
        said = _what_the_pane_says_or_why_not(machine)
        log = feed.collect_log(check_dir)

        expect(
            version == FIRST,
            f"uDeck installed {version}, which was signed with a key it does not trust; the pane says: {said}",
        )
        _nothing_is_still_installing(machine)
        _expect_it_is_the_same_uDeck(machine, before, said)
        _prove_it_fetched_and_refused(offered, log, said)
    finally:
        feed.collect_log(check_dir)
        feed.stop()


def check_it_does_not_look_by_itself(machine, check_dir, lab):
    """uDeck as it ships does not ask its feed for anything until somebody asks it to.

    **The oracle is the feed, not uDeck.** The guest's own server writes a line
    for every request it answers, and the lab marks its own (`updates.LAB_PROBE`),
    so a request for the appcast that is not the lab's is uDeck's — the address is
    baked into the one application on the machine and served on the guest's
    loopback. What uDeck says on its pane is a sentence about itself; this is the
    traffic.

    **How long it watches is how long uDeck takes when it does look**, and not a
    round number. Sparkle schedules nothing at all while automatic checks are off
    (`scheduleNextUpdateCheck…` returns at once — SPUUpdater.m at the revision in
    Package.resolved), and while they are on, a uDeck that has never looked is
    overdue and looks straight after launch. `QUIET_SECONDS` is that delay, as
    measured with automatic checks forced on in the guest's preferences, with
    room for a slow machine — so the failure this check exists for, a build that
    ships with automatic checks on, shows up well inside it. What it does not
    reach is a check something else in uDeck might start later than that; today
    the only caller of `checkForUpdates` is the "Check now" button
    (`SparkleUpdater.checkNow`, called from `AboutSection` alone).

    **Nothing heard is worth something only from a uDeck that asks when asked.**
    A uDeck that cannot reach its feed — a wrong address, a transport it may not
    use, an updater that failed to start — is exactly as quiet as one that
    chose not to ask. So the check ends by pressing "Check now" and requiring the
    feed to hear it; without that the silence is the lab's to explain, and says
    "could not check" (the same rule `_prove_it_fetched_and_refused` keeps, Q37).

    **What it is red for**, measured on 2026-09-26 with `SUEnableAutomaticChecks`
    set to true in the plist: red within 10 s of starting uDeck, the feed having
    heard it at 21:06:01 (.build/e2e/20260926-210440Z). And with "Check now"
    no longer calling Sparkle, "could not check" rather than green
    (.build/e2e/20260926-211336Z) — the witness doing its job.

    **The machine forgets what it remembered first** (`app.forget_preferences`):
    Sparkle reads whether to look, and when it last did, out of the preferences
    before it reads the plist, so a check a neighbouring check left a switch or a
    date behind for would be about that machine and not about what uDeck ships.
    """
    feed = updates.Feed(machine, lab.note)
    try:
        _a_uDeck_that_never_looked(machine, check_dir, lab, feed)
        began = machine.clock()
        app.launch(machine)
        machine.screenshot(check_dir, "uDeck running")
        asked = _uDeck_asks(machine, feed, [], QUIET_SECONDS, "listening to the feed while uDeck runs as it ships")
        expect(
            not asked,
            f"uDeck asked its feed for an update by itself within {machine.clock() - began:.0f}s of starting, with "
            f"automatic checks as it ships them — off, until the operator turns them on: {asked[:1]}",
        )
        lab.note(f"   uDeck ran {machine.clock() - began:.0f}s and its feed heard nothing from it")
        _prove_it_asks_when_asked(machine, check_dir, feed, lab)
    finally:
        feed.collect_log(check_dir)
        feed.stop()


def check_switched_on_it_looks_by_itself(machine, check_dir, lab):
    """Once the operator turns automatic checks on, uDeck asks its feed without being asked again.

    The switch is the one on the About pane (`AUTOMATIC`), turned on with the
    machine's pointer, and nothing else is pressed afterwards: "Check now" is
    exactly what this check must not touch, because a request it caused would be
    indistinguishable in the log.

    **The feed is listened to first and the switch read back after**, the other
    way round from `ui.press`. Reading a control back is a walk of the whole
    window: measured on 2026-09-26 (.build/e2e/20260926-203904Z), `ui.press` on
    this switch returned 38 s after the guest's clock read 20:45:30.09 just before
    the click, and the guest's server had logged the request at 20:45:31 — so a
    wait counted from the read-back would be counting the walk. The walk is made
    only when the feed heard nothing, and then it decides whose that silence is:
    a switch still reading off is a click that did not land, which is the lab's;
    a switch reading on is uDeck's.

    **Why it answers in seconds and not in a day.** Sparkle looks by itself when
    `SUScheduledCheckInterval` (86400 in the plist; never less than an hour, which
    is Sparkle's own floor) has passed since `SULastCheckTime` — and a uDeck that
    has never looked has no such date, so the moment it may look it is overdue,
    and Sparkle looks at once (`scheduleNextUpdateCheckFiringImmediately:` with no
    last check falls back to `distantPast`). Turning the switch on is that moment:
    the setter posts `SUUpdateAutomaticCheckSettingChangedNotification`, and the
    updater resets its cycle one second later (`resetUpdateCycleAfterDelay`). So
    the check starts from a machine that has forgotten any previous check
    (`app.forget_preferences`), and `SWITCHED_ON_SECONDS` is the measured delay
    with room for a slow machine.

    **What it is red for**: a switch that is not wired to the updater — a toggle
    that moves and tells Sparkle nothing, or a `checksAutomatically` that does not
    set `automaticallyChecksForUpdates`. Both measured red on 2026-09-26, with the
    switch reading on and the feed silent for the whole wait
    (.build/e2e/20260926-211106Z and 20260926-210840Z). What it does not reach is
    the next check a day later; that is Sparkle's own timer and not something a
    lab can wait for (README, "Looking for an update by itself").

    **A request before the switch is touched** leaves this check nothing to ask:
    it is `updates.it-does-not-look-by-itself`'s failure, and here it would have
    set the last-check date that stops the switch from causing another. So it is
    "could not check", with the line.
    """
    feed = updates.Feed(machine, lab.note)
    try:
        _a_uDeck_that_never_looked(machine, check_dir, lab, feed)
        app.launch(machine)
        _open_the_about_pane(machine, check_dir)
        switch = _the_switch_as_it_ships(machine, check_dir, lab)

        step = "reading the feed's log before the switch is turned on"
        before = updates.asked_for_the_appcast(feed.read_log(step))
        if before:
            raise LabError(
                step,
                f"uDeck had asked its feed before automatic checks were turned on, so there is nothing "
                f"left for the switch to start — that is updates.it-does-not-look-by-itself's to judge: "
                f"{before[:1]}",
            )
        began = machine.clock()
        machine.click(*switch.middle, f"turning automatic checks on: {switch}")
        asked = _uDeck_asks(machine, feed, before, SWITCHED_ON_SECONDS, "listening to the feed after the switch")
        took = machine.clock() - began
        _evidence(machine, check_dir, "automatic checks turned on", lab)
        said = _what_the_pane_says_or_why_not(machine)
        if not asked:
            _expect_the_click_landed(machine, switch)

        expect(
            bool(asked),
            f"automatic checks were turned on in uDeck's own window and its feed heard nothing from uDeck "
            f"in {SWITCHED_ON_SECONDS:.0f}s. A uDeck that has never looked is overdue the moment it may "
            f"look, so the switch did not reach the updater; the pane says: {said}",
        )
        lab.note(f"   uDeck asked its feed {took:.0f}s after automatic checks were turned on: {asked[0].strip()}")
    finally:
        feed.collect_log(check_dir)
        feed.stop()


# --- What the two about looking by itself do ---------------------------------------


def _a_uDeck_that_never_looked(machine, check_dir, lab, feed):
    """One lab build installed, nothing remembered about updates, and a feed that offers nothing.

    One build and not two: both checks end at the request, and what the feed
    would have offered is not part of either question (`updates.empty_appcast`).

    The preferences are read before they are forgotten, and said when there were
    any — a machine another check used is not a fault, but what it remembered is
    worth a line in the report.
    """
    builder = lab.builder(feed.url, check_dir.name)
    installed = builder.build(*FIRST)
    app.install(machine, installed.zip, lab.note)
    step = "preparing the machine for a check about looking by itself"
    there = app.installed_version(machine)
    if there != FIRST:
        raise LabError(step, f"the lab installed {FIRST}, but the machine has {there}")

    kept = app.preferences(machine, step)
    if kept is not None:
        lab.note(
            f"   macOS kept preferences for uDeck from before this check, taking them away: "
            f"{' '.join(kept.split())[:200]}"
        )
        app.forget_preferences(machine, step)

    appcast = check_dir / updates.APPCAST
    appcast.write_text(updates.empty_appcast())
    feed.serve(appcast)


def _uDeck_asks(machine, feed, before, seconds, step):
    """uDeck's requests for the appcast beyond `before` — as soon as there is one, or none after `seconds`.

    Read as it goes rather than once at the end: the check that expects silence
    can say when the silence broke, and the one that expects a request stops
    waiting when it comes. The log only grows, so what is new is what follows the
    requests already seen.
    """
    deadline = machine.clock() + seconds
    while True:
        asked = updates.asked_for_the_appcast(feed.read_log(step))[len(before):]
        if asked or machine.clock() >= deadline:
            return asked
        machine.sleep(LISTEN_EVERY_SECONDS)


def _prove_it_asks_when_asked(machine, check_dir, feed, lab):
    """The witness for the silence: "Check now" pressed, and the feed hearing it.

    Raised as the lab's when it does not: a uDeck that cannot reach its feed is
    quiet whatever it ships, so the silence before it proves nothing — and whether
    "Check now" works at all is `updates.sparkle`'s to judge, not this check's.
    """
    step = "asking uDeck to look, to show the quiet was its own"
    before = updates.asked_for_the_appcast(feed.read_log(step))
    _open_the_about_pane(machine, check_dir)
    ui.click(machine, "updates.checkNow", "asking uDeck to look for an update")
    asked = _uDeck_asks(machine, feed, before, ASKED_SECONDS, step)
    if not asked:
        raise LabError(
            step,
            f"uDeck was asked to look for an update and its feed heard nothing from it in "
            f"{ASKED_SECONDS:.0f}s, so the quiet before proves nothing — a uDeck that cannot reach its "
            f"feed is quiet whatever it ships; the pane says: {_what_the_pane_says_or_why_not(machine)}",
        )
    lab.note(f"   and asked when it was asked to: {asked[0].strip()}")


def _the_switch_as_it_ships(machine, check_dir, lab):
    """The About pane's switch for automatic checks, reading off — or the lab says why not.

    Found by its identifier in a walk of the window, because `ui.find` answers
    where a control is and not what it reads, and what it reads is the precondition:
    a switch already on would be turned *off* by the press. That is a machine or
    a build this check cannot ask its question of — and whether uDeck ships it on
    is `updates.it-does-not-look-by-itself`'s to say — so it is the lab's.
    """
    step = "finding the switch for automatic checks"
    dump = ui.tree(machine, step)
    try:
        (check_dir / "about-before-the-switch.txt").write_text(dump)
    except OSError as error:
        lab.note(f"   the About pane's walk could not be kept: {error}")
    found = [control for control in ui.controls(dump, step) if control.identifier == AUTOMATIC]
    if len(found) != 1:
        raise LabError(step, f"{len(found)} controls on the About pane carry '{AUTOMATIC}', where there is one")
    switch = found[0]
    if switch.value != SWITCH_OFF:
        raise LabError(
            step,
            f"the switch reads {switch.value!r} before the lab touched it, where a uDeck that has never been "
            f"configured reads {SWITCH_OFF!r}: pressing it would turn automatic checks off, not on",
        )
    return switch


def _expect_the_click_landed(machine, switch):
    """The switch reads on after the click — or the silence that followed is the lab's.

    Asked only when the feed heard nothing, because only then does it decide
    anything: a click that missed leaves the switch off and uDeck with nothing to
    do, and "uDeck did not look" would be a sentence about a pointer.
    """
    step = "reading the switch back after the click"
    after = ui.where_it_was(ui.tree(machine, step), switch, step)
    if after is None or after.value == switch.value:
        raise LabError(
            step,
            f"the lab clicked {switch.middle} for {switch} and it "
            + (f"still reads {after.value!r}: the click did not land on it" if after is not None
               else "is no longer there: the pane moved under the click"),
        )


# --- What the update and its control do --------------------------------------------


def _prepare(machine, check_dir, lab, feed, signed_by):
    """Two builds, the older one installed and running, the newer one offered.

    The machine may not be fresh: with --vm per-group or per-run the previous
    check left its own uDeck installed and running, so this establishes the
    state rather than assuming it (Q17).
    """
    builder = lab.builder(feed.url, check_dir.name)
    installed = builder.build(*FIRST)
    offered = builder.build(*SECOND)

    app.install(machine, installed.zip, lab.note)
    step = "preparing the machine for the update check"
    there = app.installed_version(machine)
    if there != FIRST:
        # The lab installed it a moment ago: this is the lab, not uDeck.
        raise LabError(step, f"the lab installed {FIRST}, but the machine has {there}")

    key = signed_by or lab.signing_key
    signature = updates.sign(offered.zip, key, updates.find_sign_update(lab.repo_root))
    appcast = check_dir / "appcast.xml"
    appcast.write_text(updates.appcast(updates.Offer(offered, signature, offered.zip.stat().st_size), feed.base_url))
    feed.serve(appcast, offered.zip)

    app.launch(machine)
    machine.screenshot(check_dir, "uDeck running")
    return offered


def _open_the_about_pane(machine, check_dir):
    ui.open_settings_and_wait(machine, "opening uDeck's settings")
    ui.wait_for(machine, "section.about", "waiting for the settings window")
    ui.click(machine, "section.about", "choosing the About section")
    element = ui.wait_for(machine, "updates.checkNow", "waiting for the About section")
    machine.screenshot(check_dir, "the About section")
    return element


def _wait_until_it_is_offered(machine, check_dir, lab, offered, feed):
    """Until uDeck offers the update — or says something that means it will not.

    The button never appearing is not by itself uDeck being wrong: the press may
    not have landed, or uDeck may still be looking. What the pane says decides
    which it is. A finished answer — "up to date", "the check did not finish" —
    against a feed that answers and an appcast that declares a newer build is
    uDeck getting it wrong, and a failure. Anything else is the lab's own, and
    stays "could not check".

    "A feed that answers" is asked again here, and not taken from the fact that it
    answered when it was started. The guest's server is a process the lab left
    running in a machine it is also driving, and a feed that has since died gives
    uDeck nothing whatever to find — so the sentence "uDeck did not offer the
    update" would be about the lab, wearing uDeck's name.
    """
    try:
        return ui.wait_for(machine, "updates.install", "waiting for uDeck to offer the update")
    except NotThere:
        _evidence(machine, check_dir, "no update offered", lab)
        said = _what_the_pane_says_or_why_not(machine)
        step = "asking whether the feed uDeck was given is still answering"
        if not feed.answers_now(step):
            raise LabError(
                step,
                "the guest's own server stopped answering, so there was nothing for uDeck to "
                f"find and nothing to say about it; the pane says: {said}",
            ) from None
        expect(
            UP_TO_DATE not in said and DID_NOT_FINISH not in said,
            f"uDeck did not offer {offered.version}, although the feed it was given declares it "
            f"and still answers; the pane says: {said}",
        )
        raise


def _expect_it_is_the_same_uDeck(machine, before, said):
    """The application that refused the update is the one that was asked to install it.

    "The version on disk did not change" is also true of a uDeck that died on the
    press, and of one that was never running to begin with. Refusing is something
    an application does while carrying on being itself.
    """
    step = "looking for uDeck after the refusal"
    after = app.running_pids(machine, step)
    expect(
        after == before,
        f"uDeck was running as {sorted(before)} when Install was pressed and is "
        f"{('running as ' + str(sorted(after))) if after else 'not running'} now — it did not "
        f"refuse the update and carry on; the pane says: {said}",
    )


# The guest's server is `python3 -m http.server`, whose log line reads
# `"GET /uDeck-0.4.2.zip HTTP/1.1" 200 -`. The status is there; the byte count is
# not — that trailing `-` is what it always writes — so what can be required is
# that the archive was asked for and answered, never how much of it arrived. The
# protocol version sits inside the quoted request and is not part of the question.
def _served(log, name):
    """The lines where the guest's server answered 200 for `name`."""
    asked_for = re.compile(rf'"[^"]*/{re.escape(name)}[^"]*"\s+200\b')
    return [line for line in log.splitlines() if asked_for.search(line)]


def _prove_it_fetched_and_refused(offered, log, said):
    """The control has to show uDeck reached the signature, not merely that nothing happened.

    One witness, and it is the guest's own access log answering for the archive:
    Sparkle checks the signature *after* downloading, so an archive served is a
    signature that was checked and rejected. It is language-independent, and it is
    about the update rather than about uDeck's mood.

    What used to be accepted beside it was the pane saying "The check did not
    finish" — which uDeck prints for any trouble the updater runs into, including
    never having got as far as the archive. With that as a witness the control
    could pass having pressed nothing and downloaded nothing, which is the shape
    of a control that proves nothing (Q34, Q37). The pane's words stay in the
    report, as evidence for a person, and decide nothing.
    """
    if _served(log, offered.zip.name):
        return
    raise LabError(
        "proving the update was refused",
        f"the guest's server never answered for {offered.zip.name}, so nothing reached the "
        f"signature this control is about; it saw: {log.strip()[-300:] or 'nothing'}; "
        f"the pane says: {said}",
    )


def _nothing_is_still_installing(machine):
    """Nothing may be mid-install when the control says nothing installed.

    The verdict is the version on disk after a fixed wait, which on its own is
    only true of the moment it was read. Sparkle installs through a helper of its
    own, so one still running means the wait was simply too short and the control
    has not measured what it claims to measure.
    """
    step = "looking for an install still in flight"
    # The pattern is broken up so that this command's own shell in the guest,
    # whose arguments `pgrep -f` also reads, cannot match it.
    running = machine.ssh.ask("pgrep -fl '[A]utoupdate|[o]rg.sparkle-project' || true", step).stdout.strip()
    if running:
        raise LabError(step, f"something was still installing after {REFUSAL_SECONDS:.0f}s: {running}")


def _evidence(machine, check_dir, step, lab):
    """A screenshot as evidence: collected, never raised.

    Anything that can raise between a measurement and the sentence that judges it
    turns a failed check into "could not check" (Q34) — and takes the artefact
    with it, which is the one Q38 wants most.
    """
    try:
        machine.screenshot(check_dir, step)
    except LabError as error:
        lab.note(f"   no screenshot '{step}': {error.reason}")


def _what_the_pane_says(machine):
    """Every sentence the settings window shows — when the verdict turns on them."""
    return " | ".join(ui.static_texts(machine, "reading what the pane says"))


def _what_the_pane_says_or_why_not(machine):
    """The same, where they are only evidence: a window that cannot be read is not a verdict."""
    try:
        return _what_the_pane_says(machine)
    except LabError as error:
        return f"(the settings window could not be read: {error.reason})"


def _wait_for_the_relaunch(machine, before, deadline):
    """The pids uDeck has once one of them is new: Sparkle relaunches after the swap.

    Read once, the moment the version changes, this catches uDeck mid-relaunch
    and pronounces "it did not come back" against an update that worked. The
    deadline is the install's own — what the check gives the whole install is
    what it gives the relaunch inside it, never a second budget on top.
    """
    while True:
        now = app.running_pids(machine)
        if now - before or machine.clock() >= deadline:
            return now
        machine.sleep(2)


def _the_version_once_it_is(machine, wanted, deadline):
    """The version on disk once it is `wanted`, or what it still is at the deadline."""
    while True:
        version = app.installed_version(machine)
        if version == wanted or machine.clock() >= deadline:
            return version
        machine.sleep(5)


def _the_version_after(machine, seconds):
    """What is installed after `seconds` of watching.

    The negative control waits the whole time on purpose: "nothing happened" is
    worth something only after long enough for something to have happened.
    """
    deadline = machine.clock() + seconds
    while machine.clock() < deadline:
        machine.sleep(5)
    return app.installed_version(machine)
