"""Does uDeck update itself?

Two checks, and the second is what makes the first worth trusting: an update
signed with the run's key installs, and one signed with another key does not.

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


# --- What both checks do ----------------------------------------------------------


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
