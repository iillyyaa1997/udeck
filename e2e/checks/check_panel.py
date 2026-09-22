"""Does the panel open when it should, and close when it should?

Nine checks in two halves. The first three are about the panel appearing and by
which path; the last six are about it going away again, and they are where
the promise the panel is built on lives — **once the panel is held, the cursor
leaving never closes it**, and everything that does close it is the operator
saying so.

Both halves read the same oracle, uDeck's own log, and both ask the same kind
of question of it: not "did the panel move" but "which thing moved it". Opening
has two paths and a check that accepted either would pass for the wrong one
(Q45); closing has four events and they are not interchangeable either, because
the panel remembers which one it was and the operator sees the difference at
the *next* reveal — a panel he put away comes back as a peek, a panel something
interrupted comes back whole.

**Opening.** The first three, and the third is what makes the first two mean
anything: the pointer resting in the strip at the top of the screen opens the
panel, the pointer already pinned there while the device keeps pushing opens it,
and the pointer in the middle of the screen — held, and pushed at — opens
nothing (Q37).

The two paths are not two ways of saying the same thing. A dwell only needs the
pointer to be somewhere; a push needs movement *reported after the pointer can
move no further*, which nothing that names a position can say. So the dwell is
made from this Mac over VNC, where the pointer is placed by naming where it goes
— a few rows down the strip, never on the top row, where a pointer is pinned and
the jump there was sometimes read as a push — and the push is made from inside
the guest as relative movement through `IOHIDSystem` — the entry point a mouse
driver posts through, where macOS moves the pointer itself and tells
applications the movement, clamping the one and not the other (Q45).

What decides each one is two things uDeck says, and it takes both. Which path
fired — `fired by dwell on …`, `fired by push on …` — and whether the panel then
opened at all — `collapsed -> peek on revealRequested`. The first is written
three lines before uDeck asks the panel to appear, so on its own it would stay
exactly as it is for a panel that never appeared for anybody; the second is
written from inside the change, and only when there was one. Both are kept in
the guest's unified log and read back afterwards.
Never a screenshot: the panel is translucent over whatever is behind it, and
"something changed at the top of the screen" is exactly the evidence that would
pass for the wrong reason. The screenshots are kept as evidence for a person
(Q38), and the log also carries `idle: <reason>` — the gate that stopped the
gesture — which is what makes a run that fires nothing worth reading.

The pointer is thrown at the edge *and* pushed there in one run of one script
inside the guest. It has to be: the dwell is a fraction of a second, so a
pointer put at the edge from this Mac would have fired the dwell long before an
SSH command could push it, and the check would pass by the path it is not about.

**Closing.** The last six take a panel that is up and put it away. Five ask
which event uDeck says did it: `peek -> collapsed on pointerLeft`,
`open -> collapsed on closeRequested` — by either of the two messengers a click
past the panel has — `open -> collapsed on otherAppActivated`, and
`peek -> collapsed on escape`. The phase they name on the left is as much of the
verdict as the event on the right — a peek closing when the pointer leaves is
the panel working, and a *held* panel doing the same is the one failure this
whole design exists to prevent. And the closing line has to be the only one in
the read that heard it, with nothing reopening there either.

The sixth asks the question that follows all of them and that none of them can:
where the keyboard went. A panel that is gone from the log and from the screen
can still be holding it, and the next thing the operator does after putting the
panel away is type. So `panel.the-key-after-escape` types, into a document, and
reads the document back.

They go through more steps than the opening checks, so they read the log in
steps too (`_Story`): one window opened at the start, sliced by what each action
added to it, and the whole of it kept beside the report as `story.log`. A check
that read only the end could not tell "nothing happened while the pointer was
away" from "it happened and something undid it".

An answer that never came is not yet a verdict, and one rule says which verdict
it becomes (`_prove_uDeck_could_have_answered`). A uDeck that was running and is
gone is uDeck failing: every check starts one and waits for it, so a missing
process is a uDeck that died in the middle of what was being watched. A window
on the log holding nothing uDeck said, or a guest clock gone back behind the
start of it, is the lab's, and those are "could not check".
"""

import shlex
from pathlib import Path

from udeck_e2e import app, config, panel, probes, updates
from udeck_e2e.errors import LabError, expect

VERSION = ("0.4.1", "6")


def check_dwell(machine, check_dir, lab):
    """The pointer rests in the strip at the top of the screen, and uDeck says so."""
    log = _prepare(machine, check_dir, lab)
    since = log.mark("noting when the gesture begins")
    try:
        _park_in_the_middle(machine)
        machine.move_pointer(*panel.top_of_the_strip(), "into the strip at the top of the screen")
        said = _wait_for_uDecks_answer(machine, log, since, config.DWELL_SECONDS)
        machine.screenshot(check_dir, "after the dwell")
        fired = panel.fired_by(said)

        expect(fired != [], f"uDeck did not open the panel; what it says of the gesture: {_short(said)}")
        expect(
            fired == ["dwell"],
            f"the panel opened by {fired}, not by the dwell — the pointer was only placed, never pushed",
        )
        _expect_the_panel_opened(said)
    finally:
        log.collect(check_dir, since, "keeping what uDeck said")


def check_push(machine, check_dir, lab):
    """The pointer is pinned at the top edge and the device keeps pushing upward.

    This could not be checked at all until 2026-09-19, and what changed was not
    the machine but which call the lab makes. Posting the movement as a
    `CGEvent` delta never worked and never could: the window server tells
    applications the movement that actually happened, which against the edge is
    nothing (measured 2026-09-18, fifteen shapes of push on four machines).
    `IOHIDPostEvent` was tried then too and refused — but under `sudo`, and that
    was the refusal: the privilege it asks for is `kIOClientPrivilegeLocalUser`,
    which XNU answers with `CopyConsoleUser(euid)`, and root holds no console
    session. As the logged-in user the same call succeeds, macOS moves the
    pointer itself, and uDeck hears the movement the way it hears a mouse.

    So the check does three things in order, and the middle one is what makes the
    last one mean anything: it throws the pointer at the edge, reads back that
    the pointer is *actually* against it — a push at an edge the pointer never
    reached would prove nothing — and only then asks uDeck which path fired.
    """
    log = _prepare(machine, check_dir, lab)
    since = log.mark("noting when the gesture begins")
    try:
        _park_in_the_middle(machine)
        # Both the throw and the push come from inside the guest, in one run: the
        # dwell would otherwise fire in the time it takes to send a command.
        pushed = panel.push_upward(machine, "throwing the pointer at the top edge and pushing there", throw=True)
        lab.note(f"   {pushed}")
        said = _wait_for_uDecks_answer(machine, log, since, config.DWELL_SECONDS)
        machine.screenshot(check_dir, "after the push")

        at = probes.pointer(machine)
        if at[1] > config.PINNED_TOLERANCE_PIXELS:
            raise LabError(
                "pushing against the top edge",
                f"the throw left the pointer at {at}, not against the top edge, so nothing was pinned to push against",
            )
        fired = panel.fired_by(said)
        expect(fired != [], f"uDeck did not open the panel; what it says of the gesture: {_short(said)}")
        # Named before it is used: the message is built whether or not the check
        # fails, and `fired[0]` on an empty list would raise inside the guard that
        # exists to keep it from ever being empty here.
        opened_by = fired[0] if fired else "nothing"
        expect(
            fired[:1] == ["push"],
            f"the panel opened by {opened_by} first, not by the push — "
            "the movement at the edge was not reported, or the dwell beat it",
        )
        _expect_the_panel_opened(said)
    finally:
        log.collect(check_dir, since, "keeping what uDeck said")


def check_middle_of_the_screen(machine, check_dir, lab):
    """Nothing opens the panel in the middle of the screen — the control for both paths.

    Held there, then pushed at: neither the passage of time nor an upward shove
    means anything away from the edge, and a gesture that fired here would fire
    while the operator was working.

    uDeck is started *inside* the window this reads, and the pointer is parked before
    it starts. The gate uDeck reports is logged only when it *changes*
    (`PanelController.swift`: `reason != lastIdleReason`), and this control is built to
    change nothing — so on 2026-09-19 it reported "could not check" twice in a row,
    including on a machine of its own with nothing else running: uDeck had written
    `idle: outsideStrip` at launch, before the window began, and the pointer stayed in
    the middle, so the line never came again. Starting uDeck after the mark puts its
    first sample — the one that always logs — inside the window, and parking first
    means that sample is taken with the pointer where this check wants it.

    The other way round it would be worse: walking the pointer through the strip to
    force a change is a dwell waiting to fire, which is the one thing this control must
    not do.
    """
    log = _prepare(machine, check_dir, lab, launch=False)
    _park_in_the_middle(machine)
    since = log.mark("noting when the control begins")
    try:
        app.launch(machine)
        machine.screenshot(check_dir, "uDeck running")
        machine.sleep(config.DWELL_SECONDS)
        pushed = panel.push_upward(machine, "pushing up in the middle of the screen")
        lab.note(f"   {pushed}")
        machine.sleep(config.NOTHING_HAPPENS_SECONDS)
        said = log.read(since, "reading what uDeck says of the gesture")
        machine.screenshot(check_dir, "nothing happened")

        expect(
            panel.fired_by(said) == [],
            f"uDeck opened the panel with the pointer in the middle of the screen: {_short(said)}",
        )
        # And the other half of the same sentence: not only was no gesture
        # recognised, nothing opened. A panel revealed by something else here
        # would be exactly as wrong, and the gesture line would not mention it.
        expect(
            panel.revealed(said) == [],
            f"the panel was shown with the pointer in the middle of the screen, "
            f"going to {panel.revealed(said)}: {_short(said)}",
        )
        _prove_uDeck_was_watching(machine, said)
    finally:
        log.collect(check_dir, since, "keeping what uDeck said")


# --- Closing ------------------------------------------------------------------------


def check_the_pointer_leaves(machine, check_dir, lab):
    """A peek closes when the pointer is taken away from it, and uDeck says which.

    The one phase the cursor is allowed to close, and the reason the next check
    exists: `PanelState` collapses on `pointerLeft` only while the panel is a
    peek, so the phase uDeck names on the left of the arrow is half of what is
    being checked here. A `peek -> collapsed` is the panel working; anything else
    closing this way would be the rule broken.

    The pointer goes past the panel altogether rather than merely out of the
    strip, so that "away" means the same thing here as it does to uDeck: what it
    measures is the region that keeps the panel alive, which reaches well beyond
    the panel's own edges and all the way up into the menu bar.
    """
    log = _prepare(machine, check_dir, lab)
    story = _Story(machine, log, check_dir, lab.note)
    try:
        _reveal_a_peek(machine, story, "the reveal")
        machine.screenshot(check_dir, "the peek")
        machine.move_pointer(*panel.past_the_panel(), f"past the panel, to {panel.past_the_panel()}")
        said = _wait_for_it_to_close(machine, story, "the pointer taken past the panel")
        machine.screenshot(check_dir, "after the pointer left")
        _expect_it_closed(said, "peek", "pointerLeft", "the pointer taken past the panel")
    finally:
        story.keep()


def check_a_click_past_the_panel(machine, check_dir, lab):
    """A held panel outlives the pointer leaving, and closes on a click outside it.

    Two sentences that have to be checked together, because each one alone can be
    satisfied by the panel being wrong in the other direction. A panel that
    closed when the pointer left would pass "it closed" and break the promise the
    whole design is for; a panel that ignored the click would keep the promise
    and never go away.

    The quiet stretch in the middle is the delicate one: nothing happening is
    free when nothing is running, which is why the control in the middle of the
    screen has `_prove_uDeck_was_watching`. That witness is not available here.
    uDeck names the gate that stopped a gesture only when the gate *changes*, and
    with the panel already up and the pointer already away nothing changes, so
    the log of the stretch is empty by design — measured on 2026-09-21, four
    times out of four.

    The witness used instead is the click that ends the stretch, and it is a
    stronger one: uDeck answers it with `open -> collapsed`, naming the phase the
    panel left. Only a uDeck that was running, that still had the panel open, and
    that was watching the pointer closely enough to hear a click can write that
    line — all three, at the end of the stretch that was supposed to change
    nothing.

    What the stretch holds is the rule as the operator meets it, not each of the
    two places uDeck keeps it. The state machine refuses `pointerLeft` in a held
    panel, and the controller does not even time a departure from one; measured
    on 2026-09-21, breaking either one alone left this check green, because the
    other still refused. Both now read one property,
    `PanelPhase.isDismissibleByPointer`, so the one edit that lets a held panel
    go breaks both — and this check went red on it, on `open -> collapsed on
    pointerLeft` (.build/e2e/20260921-213029Z). The state machine's own half is
    held by the Swift test "once held, the pointer leaving never closes the
    panel" in Tests/UDeckCoreTests/PanelStateTests.swift.

    **Which application the click leaves in front.** The click lands on the
    desktop, and the desktop belongs to the Finder, so the Finder is what the
    operator chose — not the application that was in front before the panel,
    which uDeck pulled back over it until 2026-09-21 (`KeyboardHandback`). So
    another application is put in front first (`config.IN_FRONT_BEFORE_THE_PANEL`),
    and after the click System Events inside the guest is asked who is in front
    now. Without that application there, "the Finder is in front" would be true of
    a uDeck that brought back whatever it had, because it would have had the
    Finder.

    And then the last question, which is the one the operator actually asks: what
    does the next gesture bring back? A peek, because a click outside is him
    putting the panel away. On its own that is only what `PanelState` does after
    `closeRequested`, which the Swift tests hold; what makes it worth asking here
    is panel.a-switch-with-no-click beside it, where the same held panel,
    interrupted instead, has to come back whole. Together they tell a dismissal
    from an interruption, which neither can alone — and a click read as an
    interruption is the bug this check was written for (the race in
    `ApplicationSwitch`, fixed 2026-09-21).
    """
    log = _prepare(machine, check_dir, lab)
    story = _Story(machine, log, check_dir, lab.note)
    try:
        before = _bring_forward_before_the_panel(machine, lab)
        _reveal_a_peek(machine, story, "the reveal")
        _hold_it_open(machine, story, check_dir)

        # The promise: the cursor leaving a held panel changes nothing at all.
        machine.move_pointer(*panel.past_the_panel(), f"past the panel, to {panel.past_the_panel()}")
        machine.sleep(config.NOTHING_HAPPENS_SECONDS)
        away = story.take(f"the pointer past the panel for {config.NOTHING_HAPPENS_SECONDS}s")
        machine.screenshot(check_dir, "the pointer away and the panel still held")
        expect(
            panel.closed_on(away) == [],
            f"the held panel closed on {panel.closed_on(away)} while the pointer was merely taken away "
            f"from it, which is the one thing a held panel must never do: {_short(away)}",
        )

        # And the click that ends the quiet, which is also what proves it was quiet
        # with the panel still open: `open -> …` could not be written otherwise.
        machine.click(*panel.past_the_panel(), f"past the panel, at {panel.past_the_panel()}")
        said = _wait_for_it_to_close(machine, story, "the click past the panel")
        machine.screenshot(check_dir, "after the click past the panel")
        _expect_it_closed(said, "open", "closeRequested", "the click past the panel")

        machine.sleep(config.SETTLE_SECONDS)
        in_front = probes.frontmost(machine, "asking which application the click past the panel left in front")
        lab.note(f"   in front after the click past the panel: {in_front}")
        expect(
            in_front == config.THE_DESKTOP,
            f"{in_front} is in front {config.SETTLE_SECONDS}s after a click past the panel onto the desktop, "
            f"not the {config.THE_DESKTOP} the click brought forward — uDeck handed the keyboard back to "
            f"{before}, which was in front before the panel, over the application the operator had just "
            f"chosen: {_short(said)}",
        )

        said = _reveal(machine, story, "the gesture after the click past the panel")
        came_back = panel.revealed(said)
        expect(
            came_back == ["peek"],
            f"the panel came back as {came_back} after a click outside it, not as a peek — so uDeck "
            "read the operator putting it away as something interrupting him, and gave him back work "
            "he had finished with",
        )
    finally:
        story.keep()


def check_a_switch_with_no_click(machine, check_dir, lab):
    """A held panel interrupted by another application comes back whole.

    The other half of what a collapse remembers. A click past the panel is the
    operator putting it away, and it comes back as a peek; another application
    coming forward *without* a click is something interrupting him, and the
    panel he was working in comes back as he left it. uDeck tells the two apart
    by one reading — how long ago a mouse button last went down — because the
    workspace's news of both is the same notification (`ApplicationSwitch`).

    So the pointer is left past the panel, exactly where a click that dismissed
    it would have been, and the Finder is brought forward over SSH with no click
    at all: only the age of the last click can still say "switch". `open -a` and
    not an AppleScript activation from inside the guest, which was measured
    posting no notification at all (2026-09-21); `open -a Finder` posted it
    every time it was tried, and in this check uDeck logs how old the last click
    was when the news came — 1735 ms, the first time it ran
    (.build/e2e/20260921-215814Z).

    A uDeck that read every activation as a click — the state machine would then
    never see an interruption — closes this panel as `closeRequested` and hands
    back a peek, and this is the only check in the lab that would notice.
    """
    log = _prepare(machine, check_dir, lab)
    story = _Story(machine, log, check_dir, lab.note)
    try:
        _interrupt_a_held_panel(machine, story, check_dir)
        said = _reveal(machine, story, "the gesture after the switch")
        came_back = panel.revealed(said)
        expect(
            came_back == ["open"],
            f"the panel came back as {came_back} after another application interrupted it, not whole — "
            f"the work the operator was in the middle of was thrown away: {_short(said)}",
        )
    finally:
        story.keep()


def check_a_click_past_a_restored_panel(machine, check_dir, lab):
    """A click past a panel that came back whole closes it, heard by uDeck's own monitor alone.

    One click past the panel reaches uDeck by two roads: the workspace saying
    another application came forward, and uDeck's global click monitor. The
    first road exists only when the click brings an application forward, and a
    click on the application that is already in front brings nothing forward — so
    then the monitor is the only messenger (PanelController's
    `outsideClickMonitor`), and a uDeck that had lost it would never close the
    panel. panel.a-click-past-the-panel cannot see that: its click activates the
    Finder, and the workspace's news of it wins the race.

    So the Finder is put in front first, by the same switch with no click as
    panel.a-switch-with-no-click, and the panel that switch interrupted is shown
    again — restored straight to `open`, never clicked. The click past it lands
    on the desktop, which is the Finder's, already in front. Measured in the
    guest on 2026-09-21: four clicks past a panel restored after an interruption
    with the Finder in front, four `closeRequested` and no second line (a probe
    whose runs are no longer kept); and in this check's own first run, the same,
    with nothing from the workspace in the two seconds after the click
    (.build/e2e/20260921-215814Z).

    That the monitor really was alone is checked, not assumed: if uDeck says the
    workspace told it anything in the moments after the click, the check could
    not isolate the monitor, and says so rather than passing.

    **Where the operator is left is asked here too**, because that is what the
    closing work is about — not "did the panel go" but "is he where he clicked"
    — and nothing asked it on this road at all. What it cannot catch here is an
    unconditional handback, and that is the scene rather than the check: the
    Finder has to be in front *before* the click, or the click brings it forward
    and the workspace carries the news and the monitor is no longer alone. So
    the application uDeck would hand back to is the Finder, and handing it back
    cannot be told from leaving it. Measured on 2026-09-22 with the rule from
    before ca3374e (`reason == .dismissed` alone): uDeck wrote `gave the
    keyboard back after dismissed with Finder in front, so bringing back Finder`
    and this check stayed green, while `panel.a-click-past-the-panel`, where the
    application from before the panel is TextEdit, goes red on the same build.
    The scene cannot be arranged the other way either: for uDeck to be holding
    TextEdit while the Finder is in front, the switch to the Finder must not
    collapse the panel — and it is that collapse that makes the panel a restored
    one. So this assertion holds the promise on this road, and the handback is
    held by the check next door.
    """
    log = _prepare(machine, check_dir, lab)
    story = _Story(machine, log, check_dir, lab.note)
    try:
        _interrupt_a_held_panel(machine, story, check_dir)
        said = _reveal(machine, story, "the gesture after the switch")
        restored = panel.revealed(said)
        expect(
            restored == ["open"],
            f"the panel came back as {restored} after another application interrupted it, not whole, so "
            f"there is no restored panel to click past: {_short(said)}",
        )
        in_front = probes.frontmost(machine, "asking which application is in front of the restored panel")
        if in_front != config.THE_DESKTOP:
            raise LabError(
                "putting the Finder in front of the restored panel",
                f"{in_front} is in front, not the {config.THE_DESKTOP}, so a click on the desktop would bring "
                "an application forward and the workspace would carry the news of it too",
            )
        machine.screenshot(check_dir, "the restored panel")

        machine.click(*panel.past_the_panel(), f"past the restored panel, at {panel.past_the_panel()}")
        said = _wait_for_it_to_close(machine, story, "the click past the restored panel")
        machine.screenshot(check_dir, "after the click past the restored panel")
        _expect_it_closed(said, "open", "closeRequested", "the click past the restored panel")

        machine.sleep(config.SETTLE_SECONDS)
        after = story.take(f"the {config.SETTLE_SECONDS}s after the click")
        news = panel.news_of_another_application(said + "\n" + after)
        if news:
            raise LabError(
                "hearing the click past the restored panel by uDeck's own monitor alone",
                "the workspace also told uDeck another application came forward, so this click did not rest on "
                f"the monitor alone: {_short(chr(10).join(news))}",
            )

        in_front = probes.frontmost(machine, "asking which application the click past the restored panel left in front")
        lab.note(f"   in front after the click past the restored panel: {in_front}")
        expect(
            in_front == config.THE_DESKTOP,
            f"{in_front} is in front {config.SETTLE_SECONDS}s after a click past the restored panel onto the "
            f"desktop, not the {config.THE_DESKTOP} whose desktop it is — uDeck moved the operator somewhere "
            f"he did not click, on the road where its own monitor is the only messenger: {_short(said)}",
        )

        said = _reveal(machine, story, "the gesture after the click past the restored panel")
        came_back = panel.revealed(said)
        expect(
            came_back == ["peek"],
            f"the panel came back as {came_back} after a click outside it, not as a peek — uDeck read the "
            "operator putting it away as something interrupting him",
        )
    finally:
        story.keep()


def check_escape(machine, check_dir, lab):
    """Escape closes the panel, it stays closed, and uDeck is alive to have kept it so.

    Pressed at a peek, with the pointer left in the strip that opened it. What
    keeps the panel shut there is the gesture refusing to fire twice in one visit
    to the strip — every collapse sets that, and only the pointer leaving the
    strip clears it (`idle: alreadyFiredThisVisit`) — and *not* uDeck's
    `GestureTuning.reopenCooldown`, which guards the pointer leaving and coming
    straight back. A build with the cooldown at zero passed this check
    (2026-09-21, .build/e2e/20260921-202329Z), so the cooldown is not checked
    here, and nowhere in the lab yet (see `config.STAYS_SHUT_SECONDS`).

    What the watch after Escape does catch is the panel coming back at all, which
    it has been seen to: three panels escaped out of `open` came back 158, 208 and
    228 ms later (2026-09-21, .build/e2e/20260921-133502Z). It is counted over
    everything uDeck said after the closing line, the rest of the read that heard
    the panel close included: that first read can already hold the panel coming
    back, and a check that looked only at the reads after the pause would miss it.

    **"It stayed shut" is free when nothing is running.** A build that exits the
    moment it has handled Escape passed this check (2026-09-21,
    .build/e2e/20260921-202146Z): the closing line outlives the process in the
    unified log, and the silence after it reads exactly like a panel staying
    away. So after the pause the check asks for proof of life — uDeck still
    running, and still watching the pointer: it names the gate that holds the
    panel shut (`idle: reopenCooldown`, then `idle: alreadyFiredThisVisit`), which
    every living uDeck this check has seen wrote after the escape line. A uDeck
    that died on Escape is uDeck failing, and the check is red.

    **Out of a peek and not out of a held panel, and that is measured.** Both
    ways were made in one run (2026-09-21, .build/e2e/20260921-153502Z): four
    escapes out of a peek, and eight out of a held panel — with the pointer left
    at the click, and with it put back in the strip. All twelve closed on
    `escape` and stayed shut, so the choice is not about which one works. It is
    about what else is in the log. Every escape out of `open` is followed by
    `otherAppActivated ignored in collapsed`, eight times out of eight: the click
    that held the panel made uDeck the frontmost application, closing it gives
    that up, something else comes forward, and a second messenger arrives with
    news of the same event. It is ignored only because Escape got there first.
    That is the same race that made a click past the panel mean two different
    things on different days (`ApplicationSwitch`), and a check that has to win a
    race is a check that goes red on a busy machine for a reason that is not
    uDeck's.

    Out of a peek there is no competitor — and not because a peek never takes the
    keyboard: it does, and says so (`took the keyboard: … activated=true`). What
    it does not do is become the workspace's frontmost application. When Escape
    closes it, uDeck's own account of giving the keyboard back names another
    application as in front (`gave the keyboard back after dismissed with
    Accessibility in front`, .build/e2e/20260921-213422Z), so nothing changes
    hands and nothing is announced: four escapes out of four brought no news of
    another application at all (.build/e2e/20260921-153502Z).

    **Where the keyboard went is not asked here**, and cannot be: everything
    above is satisfied by a uDeck that closed the panel and kept the keyboard,
    which is what `panel.the-key-after-escape` next door is for. Measured on
    2026-09-22: a build with `NSApp.deactivate()` taken out of `releaseKeyboard`
    passes this check — the panel closes on `escape`, stays shut for three
    seconds, and uDeck is alive and naming its gates at the end of it — and
    fails that one.
    """
    log = _prepare(machine, check_dir, lab)
    story = _Story(machine, log, check_dir, lab.note)
    try:
        _reveal_a_peek(machine, story, "the reveal")
        machine.screenshot(check_dir, "the peek")
        machine.key("esc", "on the machine's keyboard")
        said = _wait_for_it_to_close(machine, story, "Escape")
        machine.screenshot(check_dir, "after Escape")
        _expect_it_closed(said, "peek", "escape", "Escape")

        machine.sleep(config.STAYS_SHUT_SECONDS)
        after = story.take(f"the {config.STAYS_SHUT_SECONDS}s after Escape")
        machine.screenshot(check_dir, "the panel still away")
        since_it_closed = panel.after_it_closed(said) + "\n" + after
        expect(
            panel.revealed(since_it_closed) == [],
            f"the panel came back as {panel.revealed(since_it_closed)} within {config.STAYS_SHUT_SECONDS}s of "
            f"Escape, with the pointer left where the gesture put it: {_short(since_it_closed)}",
        )
        _expect_uDeck_lived_through_it(machine, since_it_closed, "Escape")
    finally:
        story.keep()


def check_the_key_after_escape(machine, check_dir, lab):
    """Escape at a peek leaves the keyboard with the application that had it.

    The question `panel.escape` cannot ask. It watches the panel go away and
    stay away, which a uDeck holding on to the keyboard does just as well — and
    holding on to it is the failure that matters here, because the next thing
    the operator does after putting the panel away is type. Which application is
    in front cannot answer it either: with the panel on screen System Events
    names the application from before it whatever uDeck has done
    (`probes.frontmost`). So this check types, and reads the document.

    **A peek, and that is the whole point.** uDeck takes the keyboard for a peek
    and says so (`took the keyboard: … activated=true`), but it does not become
    the workspace's frontmost application: its own account of giving the keyboard
    back names the other application as in front, in every run the lab has kept.
    Since ca3374e the handback therefore restores nothing after a peek —
    `KeyboardHandback` asks whether uDeck is in front, and it is not — and the
    prose of that commit said Escape was unaffected because "uDeck is in front
    for those", which is true of a panel that was clicked into and false of a
    peek.

    Measured on 2026-09-22 rather than argued, TextEdit in front on a document,
    a peek opened by the gesture and Escape pressed at it, then one key:
    TextEdit held both keys — on this build (`… so leaving it there`) and on one
    carrying the rule from before ca3374e (`… so bringing back TextEdit`). The
    behaviour is the same because at a peek there is nothing to bring back: the
    application uDeck would restore is the one already in front. ⌘W, the other
    key that dismisses a peek, was measured the same way and the same twice
    over. So ca3374e changed nothing here, and what was wrong was the sentence
    about it. This check is what keeps that from having to be argued again.

    A uDeck that keeps the keyboard is what it is red for, and that was measured
    too, on 2026-09-22: with `NSApp.deactivate()` taken out of `releaseKeyboard`,
    the panel still closes on Escape and stays shut — `panel.escape` passes on
    that build — and the document is left holding one key instead of two. It is
    the failure that method's own comment already records from the field, where
    after a hover the frontmost application was one thing and the system's
    focused application was nobody.
    """
    log = _prepare(machine, check_dir, lab)
    story = _Story(machine, log, check_dir, lab.note)
    try:
        application = _a_document_in_front(machine, lab)
        _reveal_a_peek(machine, story, "the reveal")
        machine.screenshot(check_dir, "the peek")
        machine.key("esc", "on the machine's keyboard")
        said = _wait_for_it_to_close(machine, story, "Escape")
        machine.screenshot(check_dir, "after Escape")
        _expect_it_closed(said, "peek", "escape", "Escape")

        # The handback happens in the millisecond the collapse is logged, but
        # the application it hands to is brought forward by the system, which
        # takes its own moment — the same one `panel.a-click-past-the-panel`
        # waits out before asking who is in front.
        machine.sleep(config.SETTLE_SECONDS)
        machine.key(config.AFTER_IT_CLOSED_KEY, "after Escape closed the peek")
        machine.sleep(config.SETTLE_SECONDS)
        story.take(f"the key pressed {config.SETTLE_SECONDS}s after Escape")
        holds = probes.typed_into(machine, application, f"reading what {application} holds after Escape")
        lab.note(f"   {application} holds after Escape: {holds!r}")
        machine.screenshot(check_dir, "after the key that followed Escape")
        wanted = config.BEFORE_THE_PANEL_KEY + config.AFTER_IT_CLOSED_KEY
        expect(
            holds == wanted,
            f"{application} holds {holds!r} and not {wanted!r} after a key pressed once Escape had closed the "
            f"peek: the key the operator typed next did not reach the application he was in, and uDeck's own "
            f"account of giving the keyboard back is in {_short(said)}",
        )
    finally:
        story.keep()


# --- What all nine do -------------------------------------------------------------


def _prepare(machine, check_dir, lab, launch=True):
    """A lab build of uDeck installed and running, and its own messages being kept.

    The build carries a feed nobody serves, on the guest's own loopback: a lab
    build must not be able to update itself against anything real (Q41), and the
    panel does not care either way. What it costs is one failed update check at
    launch, which uDeck says on a pane nobody here reads.
    """
    feed = updates.Feed(machine, lab.note)
    builder = lab.builder(feed.url, check_dir.name)
    build = builder.build(*VERSION)

    app.install(machine, build.zip, lab.note)
    there = app.installed_version(machine)
    if there != VERSION:
        raise LabError("preparing the machine for the panel check", f"the lab installed {VERSION}, but the machine has {there}")

    log = panel.GestureLog(machine, lab.note)
    log.keep("asking the guest to keep uDeck's own account of the gesture")
    # The control starts uDeck itself, after its window on the log has opened, so that
    # the one line uDeck always writes — the first gate it sees — is inside it.
    if launch:
        app.launch(machine)
        machine.screenshot(check_dir, "uDeck running")
    return log


def _expect_the_panel_opened(said):
    """The gesture fired — now did anything happen?

    `fired by <path>` is written at PanelController.swift:359 and the panel is
    asked to appear on :362, so the line a check would otherwise rest on says
    only that the recognizer was satisfied. The phase comes out of `apply`,
    after the state changed and only if it did.
    """
    shown = panel.revealed(said)
    expect(
        shown != [],
        "uDeck recognised the gesture and the panel did not open: it never left "
        f"'{panel.SHUT}'. What it says of the panel: {_short(said)}",
    )


def _park_in_the_middle(machine):
    """The pointer starts wherever the last thing left it — ten pixels from the corner
    after a boot, which is neither in the strip nor usefully out of it.

    Every check begins from the same place, far from the edge, so that the move
    that follows is the whole gesture and not the tail of another one.
    """
    machine.move_pointer(*panel.middle_of_the_screen(), "to the middle of the screen, away from the strip")
    machine.sleep(1)


def _wait_for_uDecks_answer(machine, log, since, holding, seconds=config.GESTURE_ANSWER_SECONDS):
    """Hold the gesture, then wait until uDeck has said something about it.

    The dwell is a fraction of a second and the push is faster, so anything this
    waits for beyond them is the machine being slow, not the gesture being slow.
    """
    machine.sleep(holding)
    deadline = machine.clock() + seconds
    while True:
        said = log.read(since, "reading what uDeck says of the gesture")
        if panel.fired_by(said) or machine.clock() >= deadline:
            return said
        machine.sleep(1)


def _prove_uDeck_was_watching(machine, said):
    """The control must not pass because uDeck was not there to open anything.

    "Nothing fired" is the answer to a question nobody asked unless uDeck was
    running and seeing the pointer. Its own log says it saw one — it names the
    gate that stopped the gesture — and its process is still there.

    The same rule as `_prove_uDeck_could_have_answered`: this control starts
    uDeck itself and then watches it do nothing, so a uDeck that is gone by the
    end is one that died while being watched, and that is uDeck failing. Asked
    before the log, because a uDeck that died at once would leave the log empty
    too, and "the window never started" would then be the lab blaming itself for
    a uDeck that fell over.
    """
    step = "proving uDeck was watching the pointer"
    expect(
        bool(app.running_pids(machine, step)),
        "uDeck was not running at the end of the control: it was started by this check and died while it "
        "was being watched, so nothing could have opened the panel either way",
    )
    if not panel.idle_reasons(said):
        raise LabError(
            step,
            "uDeck's log says nothing at all about the pointer, so the control proves nothing; "
            f"it holds: {_short(said)}",
        )


def _reveal(machine, story, label):
    """The gesture, and a panel at the end of it, from wherever the pointer was.

    `_park_in_the_middle` first, for the reason every check here does it: the move
    into the strip has to be the whole gesture and not the tail of another one.
    Which path fired is not a closing check's business — a dwell and a push leave
    the same panel — so this asks only that something opened.
    """
    _park_in_the_middle(machine)
    machine.move_pointer(*panel.top_of_the_strip(), "into the strip at the top of the screen")
    machine.sleep(config.DWELL_SECONDS)
    said = _answer(machine, story, label, panel.revealed)
    expect(
        panel.revealed(said) != [],
        f"the panel did not open for '{label}'; what uDeck says: {_short(said)}",
    )
    return said


def _reveal_a_peek(machine, story, label):
    """The same, and a peek specifically — which is where each closing check starts.

    A peek and a held panel are closed by different things, so a closing check
    that began from whichever one it happened to get would be a different check
    on different days. It is a peek here because `_prepare` installs and starts
    uDeck afresh: a panel that has never been put away has nothing to restore.
    """
    said = _reveal(machine, story, label)
    shown = panel.revealed(said)
    expect(
        shown == ["peek"],
        f"'{label}' brought the panel back as {shown}, not as a peek, so the check that follows "
        f"would be about a phase it was not written for: {_short(said)}",
    )
    return said


def _expect_it_closed(said, was, because, what):
    """The panel went away, out of the phase named and on the event named — and only that.

    Both halves of the arrow, because either on its own passes for the wrong
    reason. `-> collapsed` alone is satisfied by any of the four ways the panel
    closes, and the operator can tell them apart at the next reveal; the event
    alone says nothing about which phase heard it, and "a peek closes when the
    pointer leaves" and "a held panel does" are the difference between the design
    working and the one failure it exists to prevent.

    And the only closing in the read, with nothing reopened in it. The read that
    hears the panel close is whatever the log held by the time it was asked, and
    `log show` takes long enough that it can already hold what came next — the
    panel coming straight back, or closing a second time for another reason. A
    check that asked only whether the expected line was somewhere in it would be
    green over both.
    """
    closings = [phase for phase in panel.phases(said) if phase[1] == panel.SHUT]
    expect(closings != [], f"{what} did not close the panel; what uDeck says: {_short(said)}")
    expect(
        closings == [(was, panel.SHUT, because)],
        f"{what} closed the panel as {closings}, not once as ('{was}', '{panel.SHUT}', '{because}'): "
        f"{_short(said)}",
    )
    expect(
        panel.revealed(said) == [],
        f"the panel came back as {panel.revealed(said)} in the same read that saw {what} close it: "
        f"{_short(said)}",
    )


def _wait_for_it_to_close(machine, story, label):
    """What uDeck said once the panel closed, or once the time is up and uDeck is shown to have been able to say it."""
    return _answer(machine, story, label, panel.closed_on)


def _answer(machine, story, label, ready):
    """`story.wait_for`, and a wait that ran out is not a verdict until uDeck could have answered.

    A slow machine, a uDeck that is no longer there, a log whose window has
    stopped receiving: each leaves exactly the silence a panel that did nothing
    leaves, and only one of them is about the panel.
    """
    said = story.wait_for(label, ready)
    if not ready(said):
        _prove_uDeck_could_have_answered(machine, story, label)
    return said


def _prove_uDeck_could_have_answered(machine, story, label):
    """Why the answer never came: uDeck's doing, or the lab's.

    One rule, and it is the same one `_prove_uDeck_was_watching` and
    `_expect_uDeck_lived_through_it` keep. **A uDeck that was running and is
    gone is uDeck failing.** Every closing check starts one and waits for it, so
    a missing process is not an absence — it is a uDeck that died in the middle
    of the thing the check was watching, and it was "could not check" here while
    the same death on Escape was already red. The guest answering the question
    at all is what makes that reading safe: `running_pids` is a command over
    SSH, and a machine that is gone raises before it can be read as an empty
    answer.

    What stays the lab's: its log holding nothing uDeck said since the check
    began, which is a window that never started rather than a uDeck that went
    quiet; and the guest's clock behind the start of that window, because the
    window is `log show --start <mark>` on the guest's clock, so a clock stepped
    back past the mark files everything uDeck says afterwards before it, where
    no read will look. Both are asked *after* uDeck's own life, because a uDeck
    that died would explain either one and neither would explain it.
    """
    step = f"making sure uDeck could have answered {label}"
    expect(
        bool(app.running_pids(machine, step)),
        f"uDeck was not running when its answer to {label} did not come: it was started by this check and "
        "died in the middle of it, so there was nothing left to answer; what it said before is in story.log",
    )
    if not story.heard_from_uDeck():
        raise LabError(
            step,
            "uDeck's log holds nothing uDeck said since the check began, so it is the window on the log "
            f"that is silent and not uDeck: {_short(chr(10).join(story.window))}",
        )
    now = story.log.mark(step)
    if now < story.since:
        raise LabError(
            step,
            f"the guest's clock is at {now}, behind the start of the window on uDeck's log at {story.since}, "
            "so what uDeck said since the clock went back is outside the window",
        )


def _expect_uDeck_lived_through_it(machine, since_it_closed, what):
    """Proof of life after a stretch that was supposed to change nothing.

    A panel stays shut for free when nothing is running. uDeck still running,
    and still watching the pointer — naming the gate that holds the panel shut —
    is what makes the quiet uDeck's doing.
    """
    step = f"asking whether uDeck lived through {what}"
    expect(
        bool(app.running_pids(machine, step)),
        f"uDeck was not running {config.STAYS_SHUT_SECONDS}s after {what}: the panel only stayed away "
        "because there was nothing left to show it",
    )
    expect(
        panel.idle_reasons(since_it_closed) != [],
        f"uDeck said nothing about the pointer after {what} closed the panel, where a living uDeck names "
        f"the gate holding it shut — it was not watching: {_short(since_it_closed)}",
    )


def _hold_it_open(machine, story, check_dir):
    """A click on the peek, and a held panel — which everything after it is about."""
    machine.click(*panel.inside_the_peek(), f"inside the panel at {panel.inside_the_peek()}")
    said = _answer(machine, story, "the click inside the peek", panel.phases)
    expect(
        ("peek", "open", "interacted") in panel.phases(said),
        f"the click inside did not hold the panel open; uDeck says: {_short(said)}",
    )
    machine.screenshot(check_dir, "the panel held open")


def _interrupt_a_held_panel(machine, story, check_dir):
    """A held panel, and another application brought forward over it with no click.

    The pointer is taken past the panel first — exactly where a click that
    dismissed it would have been — so that only the age of the last click is
    left to tell uDeck this was not one. The Finder comes forward by `open -a`
    over SSH, which posted the workspace's notification every time it was
    measured; an AppleScript activation from inside the guest posted none.

    And the lab waits for it to be there before it waits for uDeck to answer,
    which is the difference between the two failures. A `open -a` that started
    nothing leaves no application coming forward, no notification, and therefore
    no collapse — and this read exactly as uDeck having ignored a switch it was
    never told about. That is the scene failing, so it is a `LabError` here,
    the way it already is in `_bring_forward_before_the_panel`.
    """
    _reveal_a_peek(machine, story, "the reveal")
    _hold_it_open(machine, story, check_dir)
    machine.move_pointer(*panel.past_the_panel(), f"past the panel, to {panel.past_the_panel()}")
    _bring_forward(machine, config.THE_DESKTOP, f"bringing the {config.THE_DESKTOP} forward with no click")
    said = _wait_for_it_to_close(machine, story, "the switch with no click")
    machine.screenshot(check_dir, "after the switch with no click")
    _expect_it_closed(said, "open", "otherAppActivated", "the switch with no click")


def _bring_forward(machine, application, step, document=None):
    """`open -a`, and the lab waits until that application really is in front.

    Setting the scene, never a verdict: an application that would not come
    forward is the lab failing to arrange what the check is about, and every
    question after it would be asked of a machine that is not in the state the
    check describes.

    `document` is opened in it, for the one check that reads what the keyboard
    reached rather than which application is in front. It is named so that the
    window read afterwards is the one this check made, and not whatever untitled
    thing the application would otherwise have offered.
    """
    opening = f"/usr/bin/open -a {shlex.quote(application)}"
    if document is not None:
        opening += f" {shlex.quote(document)}"
    machine.ssh.run(opening, step)
    deadline = machine.clock() + config.FORWARD_SECONDS
    while True:
        in_front = probes.frontmost(machine, step)
        if in_front == application:
            return in_front
        if machine.clock() >= deadline:
            raise LabError(step, f"{in_front} is in front after {config.FORWARD_SECONDS}s, not {application}")
        machine.sleep(1)


def _bring_forward_before_the_panel(machine, lab, document=None):
    """Another application in front before the panel is shown, with its window out of the way.

    The scene, not the check: an application that would not come forward is the
    lab failing to set it, never a verdict about uDeck.
    """
    application = config.IN_FRONT_BEFORE_THE_PANEL
    _bring_forward(machine, application, f"bringing {application} forward before the panel", document=document)
    probes.move_window(machine, application, config.OUT_OF_THE_WAY, f"putting {application}'s window out of the way")
    lab.note(f"   in front before the panel: {application}")
    return application


def _a_document_in_front(machine, lab):
    """The application from before the panel, open on an empty document it can be typed into.

    And one key into it before anything else happens, which is the control. A
    key that does not arrive looks exactly like a keyboard uDeck kept; without
    this the check would say uDeck kept the keyboard whenever the lab's own
    keystroke went nowhere — a VNC connection that dropped the press, a window
    that never took focus. Here that is the scene failing, and it says so.
    """
    application = config.IN_FRONT_BEFORE_THE_PANEL
    step = f"giving {application} a document to be typed into"
    machine.ssh.run(f": > {shlex.quote(config.THE_DOCUMENT)}", step)
    _bring_forward_before_the_panel(machine, lab, document=config.THE_DOCUMENT)

    machine.key(config.BEFORE_THE_PANEL_KEY, f"into {application}, before the panel was ever shown")
    machine.sleep(config.SETTLE_SECONDS)
    holds = probes.typed_into(machine, application, f"reading what {application} holds before the panel")
    lab.note(f"   {application} holds before the panel: {holds!r}")
    if holds != config.BEFORE_THE_PANEL_KEY:
        raise LabError(
            step,
            f"a key pressed before the panel was shown did not reach {application}, which holds {holds!r}: "
            "the lab cannot tell where the keyboard went afterwards either",
        )
    return application


def _short(said):
    """The tail of what uDeck said, for a reason a person reads in one line."""
    return said.strip().replace("\n", " / ")[-400:] or "nothing"


class _Story:
    """uDeck's log read in steps: what each action added, and all of it kept.

    One window, opened once and never moved, because the guest's clock has a
    second's resolution and a check that took a fresh mark between two actions
    would sometimes start the next window inside the answer to the last one.
    What separates the steps instead is how much has already been read, which is
    exact.

    Everything goes into `story.log` beside the report, step by step and labelled
    — including the steps where uDeck said nothing, which for a check about a
    panel that must *not* close is the part a person needs to see.

    Counting lines is exact only while the window only grows, and nothing else
    would make it grow: a read that comes back shorter than what has already been
    read is the lab's failure, raised on the spot. Taken quietly, it would leave
    every later step an empty slice — and an empty slice is exactly what "the
    held panel did not close" and "the panel stayed shut" look like.
    """

    def __init__(self, machine, log, check_dir: Path, note) -> None:
        self.machine = machine
        self.log = log
        self.check_dir = check_dir
        self.note = note
        self.since = log.mark("noting when the panel check begins")
        self.read_so_far = 0
        self.told: list[str] = []
        # The whole window as the last read saw it, for the question of whether
        # uDeck has said anything in it at all.
        self.window: list[str] = []

    def take(self, label: str) -> str:
        """What uDeck has added since the last step, and now it is read."""
        return self._cut(self._lines(label), label)

    def wait_for(self, label: str, ready, seconds: float = config.GESTURE_ANSWER_SECONDS) -> str:
        """The same, once `ready` is satisfied by it — or once the time is up.

        Giving up quietly is the point: the check, not this, decides what an
        answer that never came means, and it has the words for it — after asking
        whether uDeck could have given one (`_answer`). Nothing here is ever the
        verdict.
        """
        deadline = self.machine.clock() + seconds
        while True:
            lines = self._lines(label)
            if ready("\n".join(lines[self.read_so_far :])) or self.machine.clock() >= deadline:
                return self._cut(lines, label)
            self.machine.sleep(1)

    def keep(self) -> None:
        """Both files: the whole log as every other check keeps it, and the story."""
        self.log.collect(self.check_dir, self.since, "keeping what uDeck said")
        try:
            (self.check_dir / "story.log").write_text("\n\n".join(self.told))
        except OSError as error:
            self.note(f"   what uDeck said could not be written to {self.check_dir / 'story.log'}: {error}")

    def heard_from_uDeck(self) -> bool:
        """Whether the window, as last read, holds anything uDeck itself said."""
        return panel.said_by_uDeck("\n".join(self.window)) != []

    def _lines(self, label: str) -> list[str]:
        # The oracle, not the evidence: a log that cannot be read has to raise
        # here, because silence is exactly what "nothing happened" looks like.
        step = f"reading what uDeck says about {label}"
        lines = self.log.read(self.since, step).splitlines()
        if len(lines) < self.read_so_far:
            raise LabError(
                step,
                f"uDeck's log got shorter — {len(lines)} lines where {self.read_so_far} had already been read — "
                "so what is missing could no longer be told from what never happened",
            )
        self.window = lines
        return lines

    def _cut(self, lines: list[str], label: str) -> str:
        said = "\n".join(lines[self.read_so_far :])
        self.read_so_far = len(lines)
        self.told.append(f"=== {label} ===\n{said or '(nothing)'}")
        return said
