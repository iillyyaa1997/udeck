"""Does uDeck update itself?

Two checks, and the second is what makes the first worth trusting: an update
signed with the run's key installs, and one signed with another key does not.

Everything is real — a release build of this checkout, Sparkle, an appcast served
inside the machine — and nothing is asked of uDeck that a person could not do:
the settings window is opened from uDeck's own menu, the section is chosen and
the buttons are pressed with the machine's pointer, and what counts as success is
the version on disk afterwards, never what the screen says about itself.
"""

from udeck_e2e import builds, ui, updates
from udeck_e2e.errors import LabError, expect

FIRST = ("0.4.1", "6")
SECOND = ("0.4.2", "7")

# From pressing Install to the new version being on disk: Sparkle unpacks the
# archive, swaps the bundle and relaunches uDeck.
INSTALL_SECONDS = 180


def check_sparkle(machine, check_dir, lab):
    """The whole update: uDeck finds 0.4.2, installs it, and comes back as 0.4.2."""
    feed = updates.Feed(machine, lab.note)
    try:
        offered = _prepare(machine, check_dir, lab, feed, signed_by=None)
        _open_the_about_pane(machine, check_dir)

        ui.click(machine, "updates.checkNow", "asking uDeck to look for an update")
        ui.wait_for(machine, "updates.install", "waiting for uDeck to offer the update")
        machine.screenshot(check_dir, "the update is offered")
        said = _the_panes_words(machine)
        expect(
            offered.version in said,
            f"uDeck offered an update but does not name {offered.version}; it says: {said}",
        )

        before = _pid(machine)
        ui.click(machine, "updates.install", "installing the update")
        version = _wait_for_the_version_on_disk(machine, SECOND, "installing the update")
        machine.screenshot(check_dir, "after the update")

        expect(version == SECOND, f"the version on disk is {version}, not {SECOND}")
        after = _pid(machine)
        expect(after != "", "uDeck is not running after the update")
        expect(after != before, f"uDeck did not restart: it is still pid {before}")
    finally:
        feed.stop()


def check_wrong_key(machine, check_dir, lab):
    """An update signed with another key is refused — the control for the check above."""
    feed = updates.Feed(machine, lab.note)
    try:
        _prepare(machine, check_dir, lab, feed, signed_by=builds.make_key(check_dir / "another-key"))
        _open_the_about_pane(machine, check_dir)

        ui.click(machine, "updates.checkNow", "asking uDeck to look for an update")
        # It may still be offered — the signature is checked when it is installed —
        # so the check presses Install when it appears and waits either way.
        try:
            ui.wait_for(machine, "updates.install", "waiting for what uDeck does with it", seconds=60)
            ui.click(machine, "updates.install", "trying to install an update signed with another key")
        except LabError:
            lab.note("   uDeck did not even offer it")
        version = _the_version_after(machine, 90)
        machine.screenshot(check_dir, "after the refusal")
        said = _the_panes_words(machine)

        expect(
            version == FIRST,
            f"uDeck installed {version}, which was signed with a key it does not trust; the pane says: {said}",
        )
    finally:
        feed.stop()


# --- What both checks do ----------------------------------------------------------


def _prepare(machine, check_dir, lab, feed, signed_by):
    """Two builds, the older one installed and running, the newer one offered."""
    builder = lab.builder(feed.url)
    installed = builder.build(*FIRST)
    offered = builder.build(*SECOND)

    updates.install(machine, installed.zip, lab.note)
    expect(
        updates.installed_version(machine) == FIRST,
        f"the machine starts with {updates.installed_version(machine)} installed, not {FIRST}",
    )

    key = signed_by or lab.signing_key
    signature = updates.sign(offered.zip, key, updates.find_sign_update(lab.repo_root))
    appcast = check_dir / "appcast.xml"
    appcast.write_text(updates.appcast(updates.Offer(offered, signature, offered.zip.stat().st_size), feed.base_url))
    feed.serve(appcast, offered.zip)

    machine.ssh.run("open -a /Applications/uDeck.app", "starting uDeck")
    _wait_until_running(machine)
    machine.screenshot(check_dir, "uDeck running")
    return offered


def _open_the_about_pane(machine, check_dir):
    ui.open_settings(machine, "opening uDeck's settings")
    ui.wait_for(machine, "section.about", "waiting for the settings window")
    ui.click(machine, "section.about", "choosing the About section")
    element = ui.wait_for(machine, "updates.checkNow", "waiting for the About section")
    machine.screenshot(check_dir, "the About section")
    return element


def _the_panes_words(machine):
    """Every sentence the settings window shows — for a reason a person can read."""
    return " | ".join(ui.static_texts(machine, "reading what the pane says"))


def _pid(machine):
    return machine.ssh.run("pgrep -x uDeck || true", "looking for uDeck", check=False).stdout.strip()


def _wait_until_running(machine, seconds=30):
    deadline = machine.clock() + seconds
    while True:
        if _pid(machine):
            return
        if machine.clock() >= deadline:
            raise LabError("starting uDeck", f"it was not running within {seconds:.0f}s")
        machine.sleep(2)


def _wait_for_the_version_on_disk(machine, wanted, step, seconds=INSTALL_SECONDS):
    """The version on disk once it is `wanted`, or what it still is at the deadline."""
    deadline = machine.clock() + seconds
    while True:
        version = updates.installed_version(machine)
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
    return updates.installed_version(machine)
