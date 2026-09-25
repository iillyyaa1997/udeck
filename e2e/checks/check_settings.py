"""Does a setting the operator changed still hold?

Two checks, and between them they close the one path through uDeck that every
other group of checks leaves untouched: the operator opens the settings window,
changes something, and expects it to matter — now, and the next time uDeck
starts.

**Every other check in the lab drives a uDeck that has never been configured.**
The panel checks install a build and use it as it ships; the login checks flip
one switch and then ask the *system's* database about it, never uDeck's own
file. So a uDeck that wrote nothing to disk, or wrote it and never read it back,
or read it back and never told the running application, would be green
everywhere — and the operator would find his shortcut back to ⌃⌥U every morning.
`panel.the-hotkey-dies-with-udeck` says this in so many words about
`HotKeyMonitor.unregister`, which nothing could observe until a setting changed
in a running uDeck.

**The change is made in the window, with the pointer, and never in the file.**
A check that wrote `~/.udeck/settings.json` itself and restarted uDeck would be
a check about `JSONFileStore` and about nothing the operator does: it would be
green on a settings window whose controls were wired to nothing at all, which is
the failure most worth catching, because it is the half of this feature a person
actually touches. So the lab clicks the control, and the file is something it
*reads* afterwards — one of the two halves of the verdict, never the way in.

**Both halves, because neither is the promise on its own.** The file is what
survives uDeck; the behaviour is what the operator asked for. A uDeck that saved
perfectly and ignored what it loaded would pass the first; a uDeck that applied
the change and saved nothing would pass the second and lose it at the next
launch. So each check says what the file holds *and* what uDeck does about it,
and the second half is read out of uDeck's own log rather than off the screen —
the panel is translucent over whatever is behind it, and "something changed at
the top of the screen" is the evidence that passes for the wrong reason.

**Which settings, and why only these two.** Most of what the Opening screen
offers can only be photographed: a dwell that is 60 ms rather than 80, a panel a
little wider. Two of them uDeck answers out loud, and those are the two here.
The shortcut is one — uDeck writes the combination it took from the window
server, and both halves of a change are readable, the old chord dead and the new
one live. "Retract when you switch applications" is the other: the same scene,
made twice, gives `open -> collapsed on otherAppActivated` with it on and
`otherAppActivated ignored in open` with it off, both in the log (measured
2026-09-25, .build/e2e/20260925-004441Z). Density is the one that got away:
its segments carry an `AXDescription`, which nothing else on these screens
does, and they sit at y 948 with the window's lower edge at 846 — below it, and
reachable only after a scroll.

**What each check is red for.** `settings.a-switch-survives-a-restart` catches a
setting that is not saved, or is saved and not read at launch:
`collapseOnAppSwitch` is read live from `settings` every time the panel applies
an event, so once the file is right at launch the behaviour follows.
`settings.the-shortcut-changes-at-once-and-survives` catches the same two and a
third that is nobody else's: `PanelController.settingsChanged` handing the new
combination to the window server. A build that saved the shortcut and left
`HotKeyMonitor` alone writes a perfect file, starts perfectly the next morning,
and does nothing at all for the rest of the day the operator changed it —
measured on 2026-09-25, with `hotKeys.apply` taken out of `settingsChanged`: the
file said ⌃⌥⇧U, 1935 bytes, written in the same 0.29 s as ever
(.build/e2e/20260925-003919Z). No check that reads the file can see that, which
is why both checks read what uDeck *did* as well.

**A restart here is uDeck's, not the machine's.** What is being asked is whether
the file uDeck wrote is the file uDeck reads — `DeckModel.init` loads it once, at
launch — and quitting uDeck and starting it again is exactly that question, at a
tenth of the cost of rebooting a guest. The machine restarting is the login
checks' subject, where the system's own database is what has to come through a
boot.

Both checks read uDeck's log in steps (`panel.Story`) and both rest on the rule
every stretch of quiet in this lab rests on: **a uDeck that was running and is
gone is uDeck failing** (`panel.expect_it_was_still_there`). A machine that
cannot be reached, or a window on the log that never started, is the lab's and
says so.
"""

from udeck_e2e import app, config, panel, ui, updates
from udeck_e2e.errors import LabError, expect

VERSION = ("0.4.1", "6")

# What the switch this check turns off has to read in the file afterwards. It is
# `false` and not merely "different": `collapseOnAppSwitch` ships as true
# (`AppSettings.init`), the control is a `Toggle` bound straight to it
# (`OpeningSettings`), and one press is one change.
SWITCHED_OFF = False


def check_a_switch_survives_a_restart(machine, check_dir, lab):
    """A switch turned off in uDeck's own window is still off after uDeck is restarted.

    The switch is "retract when you switch applications"
    (`config.THE_SWITCH` → `collapseOnAppSwitch`), and it is chosen because uDeck
    answers it in words. With it on, a panel the operator is working in goes
    away when something else comes forward; with it off, it stays. Both are
    lines in uDeck's log, and neither is a screenshot of a translucent panel.

    **The scene is made twice over and the switch is the only thing that
    differs.** Once before the change, which is the control: the same held
    panel, the same application brought forward with no click, and uDeck closing
    it on `otherAppActivated`. Without that, "the panel stayed" would be an
    empty kind of green — a scene that never worked leaves exactly the same
    silence as a setting that was obeyed. Once after the change and after uDeck
    has been restarted, which is the check. And the news of the switch has to
    have reached uDeck both times, or nothing was asked of the setting at all
    (`panel.news_of_another_application`).

    **The quiet after the interruption is uDeck's quiet.** The wait inside
    `panel.interrupt_a_held_panel` gives uDeck the ten seconds an answer would
    have had and then asks whether it could have given one — still running, its
    log still receiving, the guest's clock still ahead of the window's start. A
    uDeck that fell over during the stretch is uDeck failing, not a panel that
    obediently stayed.

    **What it is red for**, and both were measured on 2026-09-25: a uDeck that
    does not save the change (the file never says `false`, and the first half
    fails), and one that saves it and does not read it at launch (the file is
    right, the restarted uDeck retracts the panel anyway, and the second half
    fails). The living half — a uDeck that ignores the change until it is
    restarted — this check does not ask, and does not have to: the panel reads
    `settings.collapseOnAppSwitch` afresh every time it applies an event
    (`PanelController.apply`), so there is nothing between the file and the
    behaviour to break. The shortcut is the setting where there is, and the
    check next door is about exactly that.
    """
    log = _prepare(machine, check_dir, lab)
    story = panel.Story(machine, log, check_dir, lab.note)
    try:
        # The control: the switch as uDeck ships it, and what it does to the scene.
        said = _interrupt_a_held_panel(machine, story, check_dir, lab, " with the switch as it ships")
        panel.expect_it_closed(
            said, "open", "otherAppActivated", "another application coming forward, with the switch on"
        )

        # The change, made where the operator makes it.
        screen = ui.opening(machine, "opening uDeck's settings on Opening")
        _keep(check_dir, "opening-before-the-change.txt", screen.dump, lab)
        story.take("opening uDeck's settings")
        ui.press(machine, screen.switch(config.THE_SWITCH), f"turning '{config.THE_SWITCH}' off")
        machine.screenshot(check_dir, "the switch turned off")

        # The first half: what uDeck wrote down.
        wrote = _what_uDeck_saved(machine, check_dir, lab, lambda saved: _says(saved) is SWITCHED_OFF)
        expect(
            wrote is not None,
            f"one control was clicked in uDeck's own settings window and {app.SETTINGS_FILE} is still not "
            f"there {config.SETTINGS_SAVE_SECONDS:.0f}s later: the operator's change is nowhere, and the "
            "next uDeck he starts has never heard of it",
        )
        expect(
            _says(wrote) is SWITCHED_OFF,
            f"{app.SETTINGS_FILE} says '{config.THE_SWITCH}' is {_says(wrote)!r} and not {SWITCHED_OFF!r} "
            f"after the switch was turned off in uDeck's own window: what uDeck saved is not what the "
            f"operator chose",
        )
        lab.note(f"   uDeck saved '{config.THE_SWITCH}' = {_says(wrote)!r}")

        # And the second: what the uDeck that reads that file does about it.
        _end_uDeck(machine, story, lab)
        app.launch(machine)
        machine.screenshot(check_dir, "uDeck running again")
        story.take("uDeck starting again")
        said = _interrupt_a_held_panel(machine, story, check_dir, lab, " after uDeck was restarted")
        expect(
            panel.closed_on(said) == [],
            f"the held panel closed on {panel.closed_on(said)} when another application came forward, "
            f"after '{config.THE_SWITCH}' had been turned off in uDeck's own window and uDeck restarted: "
            f"the operator turned retracting off and the panel he was working in was taken away anyway — "
            f"{panel.short(said)}",
        )
    finally:
        story.keep()


def check_the_shortcut_changes_at_once_and_survives(machine, check_dir, lab):
    """A shortcut changed in uDeck's window works at once, and still works after a restart.

    Three sentences about one press of one button, and each of them fails on a
    different build.

    **At once**, which is the part nothing else in the lab reaches.
    `RegisterEventHotKey` hands a combination to one process until it gives it
    back, so changing the shortcut is two operations and not one: the old
    registration has to go and the new one has to be taken
    (`HotKeyMonitor.apply`, called from `PanelController.settingsChanged`). Both
    halves are read — the old combination moves the panel not at all, the new
    one opens it ready to be typed into — and so is uDeck's own line saying it
    took the new one, because a uDeck that re-registered and a uDeck that cannot
    hear are different failures and only that line tells them apart.

    **The old combination has to be dead**, and that is not a nicety: while a
    registration stands the window server delivers that key to that process and
    to nobody else, so a uDeck still holding ⌃⌥U has taken a key out of every
    other application on the Mac — which is the same thing
    `panel.the-hotkey-dies-with-udeck` is about from the other end, and the only
    thing in the lab that can see `HotKeyMonitor.unregister` work. Measured on
    2026-09-25 with `unregister()` taken out of `apply`: uDeck said it had
    registered ⌃⌥⇧U, the file was perfect, and the old ⌃⌥U went on opening the
    panel (.build/e2e/20260925-004113Z).

    **"Nothing happened" is free**, so the silence of the old combination is
    witnessed by the new one straight after it, on the same machine, in the same
    breath — a uDeck that heard no chords at all, or that had lost the
    registration to another application, would be silent for both. The same
    shape as `panel.a-chord-that-is-not-the-hotkey`, and for the same reason:
    what is being controlled for is the combination and not the way the lab
    presses it, so both chords are made the same way, inside the guest
    (`panel.press_the_chord`).

    **And after a restart**, which is the file's half. uDeck reads its settings
    once, in `DeckModel.init`, so what a restarted uDeck says it holds is what
    the file says — and the check reads both: the file, and then the line the
    new process writes at launch, and then the chord actually opening the panel.
    A build that saves the shortcut and reads the default back is green on
    everything above and loses the operator's choice every time he closes his
    laptop.

    **uDeck is started inside the window on its own log, and the pointer is
    parked first**, for the reasons all five shortcut checks have them: the line
    that says which combination uDeck holds is written once, at launch, so a
    window opened afterwards begins after the only chance to read it — and a
    pointer left in the strip opens the panel by the gesture in the moment
    between the launch and the mark.
    """
    log = _prepare(machine, check_dir, lab, launch=False)
    panel.park_in_the_middle(machine)
    story = panel.Story(machine, log, check_dir, lab.note)
    try:
        _a_uDeck_holding(machine, story, check_dir, config.THE_HOTKEY, "uDeck starting")

        # The change, made where the operator makes it: one modifier added to the
        # combination, which differs from uDeck's own by exactly that one press.
        screen = ui.opening(machine, "opening uDeck's settings on Opening")
        _keep(check_dir, "opening-before-the-change.txt", screen.dump, lab)
        story.take("opening uDeck's settings")
        ui.press(
            machine,
            screen.modifier(config.THE_ADDED_MODIFIER),
            f"adding {config.THE_ADDED_MODIFIER} to the shortcut",
        )
        machine.screenshot(check_dir, "the shortcut changed")

        # The running uDeck took the new combination out of the window server.
        # Said before either chord is pressed: a uDeck that never re-registered
        # and one that re-registered and cannot hear are two different failures,
        # and only this line tells them apart.
        said = panel.answer(machine, story, "the shortcut changed", panel.registered_hotkeys)
        panel.expect_it_holds(said, config.THE_NEW_HOTKEY)

        # What uDeck wrote down, which is what the restart below will read.
        wrote = _what_uDeck_saved(machine, check_dir, lab, lambda saved: _hotkey_in(saved) == config.THE_NEW_HOTKEY)
        expect(
            wrote is not None,
            f"the shortcut was changed in uDeck's own settings window and {app.SETTINGS_FILE} is still not "
            f"there {config.SETTINGS_SAVE_SECONDS:.0f}s later: the combination the operator chose is nowhere, "
            "and the next uDeck he starts will hold the one he replaced",
        )
        expect(
            _hotkey_in(wrote) == config.THE_NEW_HOTKEY,
            f"{app.SETTINGS_FILE} says the shortcut is {_hotkey_in(wrote)} and not {config.THE_NEW_HOTKEY} "
            f"after it was changed in uDeck's own window: what uDeck saved is not what the operator chose",
        )
        lab.note(f"   uDeck saved the shortcut as {_hotkey_in(wrote)}")

        # The old combination, first: a panel the new one had opened would be in
        # the way of asking anything about the old.
        panel.park_in_the_middle(machine)
        panel.press_the_chord(
            machine, config.HOTKEY_KEY_CODE,
            f"{config.THE_HOTKEY}, the combination that was replaced", config.HOTKEY_MODIFIERS,
        )
        machine.sleep(config.NOTHING_HAPPENS_SECONDS)
        old = story.take(f"{config.THE_HOTKEY}, the combination that was replaced")
        machine.screenshot(check_dir, "after the combination that was replaced")
        expect(
            panel.phases(old) == [],
            f"{config.THE_HOTKEY} still moved the panel {panel.phases(old)} after the shortcut was changed "
            f"to {config.THE_NEW_HOTKEY}: the combination the operator gave up is still taken out of every "
            f"other application's keyboard, and he cannot get it back without ending uDeck — {panel.short(old)}",
        )

        # And the new one, which is also what makes that silence worth anything.
        _press_the_new_chord(machine, story, check_dir, "in the uDeck it was chosen in")

        _end_uDeck(machine, story, lab)
        _a_uDeck_holding(machine, story, check_dir, config.THE_NEW_HOTKEY, "uDeck starting again")
        _press_the_new_chord(machine, story, check_dir, "after uDeck was restarted")
    finally:
        story.keep()


# --- What both do -------------------------------------------------------------------


def _prepare(machine, check_dir, lab, launch=True):
    """A lab build of uDeck installed and running, and its own messages being kept.

    The same preparation the panel checks make, and the same feed nobody serves:
    a lab build must not be able to update itself against anything real (Q41).

    It also settles what every sentence here rests on, which is that the machine
    has never been configured. uDeck writes no settings file until something is
    changed — measured 2026-09-25, missing after the install, after the first
    launch and after all five sections of the settings window had been walked —
    so the file these checks read afterwards holds the operator's own change and
    nothing else. `--vm per-group` and `per-run` share a machine between checks,
    though, and the check before this one may have left a file behind, so it is
    refused rather than assumed.
    """
    feed = updates.Feed(machine, lab.note)
    builder = lab.builder(feed.url, check_dir.name)
    build = builder.build(*VERSION)

    app.install(machine, build.zip, lab.note)
    there = app.installed_version(machine)
    if there != VERSION:
        raise LabError(
            "preparing the machine for the settings check",
            f"the lab installed {VERSION}, but the machine has {there}",
        )

    step = "making sure nothing has configured this machine before"
    already = app.settings(machine, step)
    if already is not None:
        raise LabError(
            step,
            f"{app.SETTINGS_FILE} is already there before anything was changed, holding "
            f"{sorted(already)} — what this check reads out of it afterwards would not be its own change",
        )

    log = panel.GestureLog(machine, lab.note)
    log.keep("asking the guest to keep uDeck's own account of the panel")
    if launch:
        app.launch(machine)
        machine.screenshot(check_dir, "uDeck running")
    return log


def _a_uDeck_holding(machine, story, check_dir, wanted, label):
    """uDeck started inside the window on its log, and saying which shortcut it holds.

    The premise every check about the shortcut rests on, here on both sides of a
    restart: the combination uDeck says it took at launch is the one the file
    gave it, and `panel.expect_it_holds` is where that sentence lives.
    """
    app.launch(machine)
    machine.screenshot(check_dir, f"uDeck running: {label}")
    said = panel.answer(machine, story, label, panel.registered_hotkeys)
    panel.expect_it_holds(said, wanted)
    return said


def _end_uDeck(machine, story, lab):
    """uDeck ended, and the pointer parked before the next one starts.

    Half of the question these checks ask of the file, and the caller makes the
    other half by starting uDeck again — differently, because one of them has a
    line to read at that launch and the other has not.

    uDeck reads its settings once, in `DeckModel.init`, so a new process is what
    turns "the file says this" into "uDeck believes this". The machine is not
    restarted: what would be asked of a boot is the *system's* memory of uDeck,
    which is the login checks' subject, and it costs four minutes to ask.

    The pointer is parked before the new uDeck starts, for the reason every
    shortcut check parks it: one left in the strip opens the panel by the
    gesture within a fraction of a second of the launch.
    """
    app.quit_app(machine, "ending uDeck, so that the next one starts from the file")
    story.take("uDeck ending")
    panel.park_in_the_middle(machine)
    lab.note("   uDeck ended; what the next one starts with is what it saved")


def _interrupt_a_held_panel(machine, story, check_dir, lab, label):
    """The scene the retract switch decides, with the application it is interrupted by.

    Another application is put in front *before* the panel, and its window out of
    the way, so that the Finder this scene brings forward is really coming
    forward: `open -a` for the application that is already frontmost brings
    nothing forward at all, the workspace posts nothing, and uDeck would be read
    as ignoring a switch it was never told about (the trap
    `panel.a-switch-with-no-click` names).

    And uDeck having been told is checked here rather than assumed, both times
    this scene is made. Otherwise the half of this check that watches a panel
    stay would be satisfied by a machine where nothing happened at all.
    """
    panel.bring_forward_before_the_panel(machine, lab.note)
    said = panel.interrupt_a_held_panel(machine, story, check_dir, label)
    news = panel.news_of_another_application(said)
    lab.note(f"   uDeck's news of the switch{label}: {news or 'nothing'}")
    if not news:
        raise LabError(
            f"interrupting a held panel{label}",
            "the workspace never told uDeck that another application came forward, so nothing was asked "
            f"of '{config.THE_SWITCH}' either way: {panel.short(said)}",
        )
    return said


def _press_the_new_chord(machine, story, check_dir, label):
    """The combination the operator chose, pressed, and the panel it has to open.

    Ready to be typed into and not merely shown, which is what every check about
    the shortcut asks of it (`panel.OPENED_READY_TO_TYPE`): the hand that
    reached for a key is not going to reach for the mouse to promote a glance.
    """
    what = f"{config.THE_NEW_HOTKEY} {label}"
    panel.park_in_the_middle(machine)
    panel.press_the_chord(machine, config.HOTKEY_KEY_CODE, what, config.NEW_HOTKEY_MODIFIERS)
    said = panel.answer(machine, story, what, panel.opened_ready_to_type)
    machine.screenshot(check_dir, f"after {config.THE_NEW_HOTKEY} {label}")
    panel.expect_it_opened_ready_to_type(said, what)
    return said


def _what_uDeck_saved(machine, check_dir, lab, until):
    """uDeck's settings file once it says what was asked of it, and kept beside the report.

    Kept whatever it says: a check that failed on what uDeck wrote leaves the
    next person the file it wrote, and a check that passed leaves the evidence
    that it did.
    """
    step = f"waiting for uDeck to save the change to {app.SETTINGS_FILE}"
    app.wait_for_settings(machine, step, until)
    # Read once, kept and judged: a second read is a second answer, and the file
    # quoted in the report would not be the one the verdict was reached on.
    text = app.settings_text(machine, step)
    _keep(check_dir, "settings.json", text, lab)
    return app.read_settings(text, step)


def _says(saved):
    """What the settings file says about the switch, or None when it says nothing.

    None is its own answer: every key in that file is written by the encoder
    whenever uDeck saves at all (measured 2026-09-25, thirteen keys and 1935
    bytes after one click), so a file with no `collapseOnAppSwitch` in it is not
    a file uDeck wrote for this change.
    """
    return None if saved is None else saved.get(config.THE_SWITCH)


def _hotkey_in(saved):
    """What the settings file says the shortcut is, spelled as uDeck spells it.

    `HotKeyBinding.displayName` reads the modifiers in macOS's order and then
    the key, and the file keeps them as an unordered set — so the order is put
    back from `config.HOTKEY_MODIFIER_ROW`, which is that same order, rather
    than from however the encoder happened to write them out.
    """
    binding = (saved or {}).get("hotkey")
    if not isinstance(binding, dict):
        return "(no shortcut in the file)"
    symbols = dict(zip(config.HOTKEY_MODIFIER_ROW, ("⌃", "⌥", "⇧", "⌘")))
    named = sorted(
        (name for name in binding.get("modifiers", []) if name in symbols),
        key=config.HOTKEY_MODIFIER_ROW.index,
    )
    return "".join(symbols[name] for name in named) + str(binding.get("key", "")).upper()


def _keep(check_dir, name, text, lab):
    """Evidence beside the report, which nothing here may fail on."""
    try:
        (check_dir / name).write_text(text)
    except OSError as error:
        lab.note(f"   {name} could not be written to {check_dir}: {error}")
