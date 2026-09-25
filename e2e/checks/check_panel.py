"""Does the panel open when it should, and close when it should?

Fourteen checks in three parts. The first three are about the panel appearing
and by which path; the next six are about it going away again, and they are
where the promise the panel is built on lives — **once the panel is held, the
cursor leaving never closes it**, and everything that does close it is the
operator saying so. The last five are the other way in, which needs no pointer
at all: the keyboard shortcut, which opens the panel and puts it away again.

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

**The shortcut.** The last five are ⌃⌥U, and what makes them a part of their
own rather than a fourth opening path is that the panel it leaves is a
different panel: the gesture gives a peek, the shortcut gives one already
promoted to be typed into, because the hand that pressed it is on the keys
(`panel.OPENED_READY_TO_TYPE`). So it is the only way in whose checks read two
phases, and the only one that also puts the panel away again.

Three of the five are the toggle. `panel.the-hotkey` opens the panel;
`panel.the-hotkey-again` presses it a second time and puts it away; and
`panel.the-hotkey-closes-what-the-gesture-opened` presses it at a panel it did
not open at all. That third one is not a repetition of the second: uDeck's
toggle is written as "shut, or else close" (`PanelController.toggleFromKeyboard`),
and a guard narrowed to the phase the shortcut itself leaves behind would
promote a peek instead of closing it — which both of the other two stay green
over, because one of them starts from a shut panel and the other from a panel
the shortcut had already promoted.

Where the keyboard went is asked of a document rather than of the log, and it is
`panel.the-hotkey-again` alone that asks it — twice, with the panel open where a
key must not reach the document, and after it, where it must — because uDeck
names its first responder once per process and a document can be read as often
as one likes.

The other two are controls, and both are about the combination rather than
about the panel. `panel.a-chord-that-is-not-the-hotkey` presses one uDeck never
registered; `panel.the-hotkey-dies-with-udeck` presses the real one at a machine
uDeck has left, because a global combination that outlived the application would
take that key away from every other application on the Mac and nothing else here
would notice.

What none of them can take for granted is that uDeck was listening at all.
`RegisterEventHotKey` can be refused, and then a uDeck that is running, healthy
and watching the pointer hears no chord whatever. Two answers, and the checks
use both: uDeck says which shortcut it holds at launch, which is why three of
the five start uDeck inside the window on its log and read that line before
they press anything; and the control for the wrong chord presses the real one
straight after its silence, on the same machine, so that "nothing happened" is a
sentence about the combination rather than about a deaf uDeck.

**The pointer is parked before uDeck starts, in all five**, and that is an
ordering and not a detail. A pointer left in the strip by whatever ran before
opens the panel by the gesture, and on a machine shared between checks
(`--vm per-group`, `per-run`) it would fire in the moment between the launch and
the mark — leaving a shortcut check pressing a chord at a panel that was already
up, or reading a reveal nobody asked for. So every one of them does the same
three things in the same order: park, mark, launch.

**What is known about the shortcut and is not checked here.** One thing, in
UDeckKit, which has no test target — the package has one, `UDeckCoreTests`
(Package.swift) — and neither of them reachable from the lab as it stands.

The first is uDeck recognising its own hot key in the Carbon callback
(`HotKeyMonitor.swift:130`, the signature and id guard). uDeck registers exactly
one combination, so every hot key event this process can receive is that one: a
build that answered any hot key at all would behave exactly like this one under
every check here, and under every chord the lab can make.

What used to be listed beside it is the shortcut being registered again when
the operator changes it (`PanelController.settingsChanged`, which calls
`HotKeyMonitor.apply`). No check *here* changes a setting in a running uDeck, so
that path is never taken in this file — it belongs with saving settings and is
now `settings.the-shortcut-changes-at-once-and-survives`, which is also the only
check that makes `HotKeyMonitor.unregister` observable: macOS reclaims a
process's hot keys when the process exits, so `panel.the-hotkey-dies-with-udeck`
is green over a build that never unregisters anything. That is written down
where it was measured, in that check.

Those eleven go through more steps than the three opening checks, so they read
the log in steps too (`panel.Story`): one window opened at the start, sliced by what
each action added to it, and the whole of it kept beside the report as
`story.log`. A check that read only the end could not tell "nothing happened
while the pointer was away" from "it happened and something undid it".

An answer that never came is not yet a verdict, and one rule says which verdict
it becomes (`panel.prove_uDeck_could_have_answered`). A uDeck that was running and is
gone is uDeck failing: every check starts one and waits for it, so a missing
process is a uDeck that died in the middle of what was being watched. A window
on the log holding nothing uDeck said, or a guest clock gone back behind the
start of it, is the lab's, and those are "could not check".
"""

import shlex

from udeck_e2e import app, config, panel, probes, updates
from udeck_e2e.errors import LabError, expect

VERSION = ("0.4.1", "6")


def check_dwell(machine, check_dir, lab):
    """The pointer rests in the strip at the top of the screen, and uDeck says so."""
    log = _prepare(machine, check_dir, lab)
    since = log.mark("noting when the gesture begins")
    try:
        panel.park_in_the_middle(machine)
        machine.move_pointer(*panel.top_of_the_strip(), "into the strip at the top of the screen")
        said = _wait_for_uDecks_answer(machine, log, since, config.DWELL_SECONDS)
        machine.screenshot(check_dir, "after the dwell")
        fired = panel.fired_by(said)

        expect(fired != [], f"uDeck did not open the panel; what it says of the gesture: {panel.short(said)}")
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
        panel.park_in_the_middle(machine)
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
        expect(fired != [], f"uDeck did not open the panel; what it says of the gesture: {panel.short(said)}")
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
    panel.park_in_the_middle(machine)
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
            f"uDeck opened the panel with the pointer in the middle of the screen: {panel.short(said)}",
        )
        # And the other half of the same sentence: not only was no gesture
        # recognised, nothing opened. A panel revealed by something else here
        # would be exactly as wrong, and the gesture line would not mention it.
        expect(
            panel.revealed(said) == [],
            f"the panel was shown with the pointer in the middle of the screen, "
            f"going to {panel.revealed(said)}: {panel.short(said)}",
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
    story = panel.Story(machine, log, check_dir, lab.note)
    try:
        panel.reveal_a_peek(machine, story, "the reveal")
        machine.screenshot(check_dir, "the peek")
        machine.move_pointer(*panel.past_the_panel(), f"past the panel, to {panel.past_the_panel()}")
        said = panel.wait_for_it_to_close(machine, story, "the pointer taken past the panel")
        machine.screenshot(check_dir, "after the pointer left")
        panel.expect_it_closed(said, "peek", "pointerLeft", "the pointer taken past the panel")
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
    story = panel.Story(machine, log, check_dir, lab.note)
    try:
        before = panel.bring_forward_before_the_panel(machine, lab.note)
        panel.reveal_a_peek(machine, story, "the reveal")
        panel.hold_it_open(machine, story, check_dir)

        # The promise: the cursor leaving a held panel changes nothing at all.
        machine.move_pointer(*panel.past_the_panel(), f"past the panel, to {panel.past_the_panel()}")
        machine.sleep(config.NOTHING_HAPPENS_SECONDS)
        away = story.take(f"the pointer past the panel for {config.NOTHING_HAPPENS_SECONDS}s")
        machine.screenshot(check_dir, "the pointer away and the panel still held")
        expect(
            panel.closed_on(away) == [],
            f"the held panel closed on {panel.closed_on(away)} while the pointer was merely taken away "
            f"from it, which is the one thing a held panel must never do: {panel.short(away)}",
        )

        # And the click that ends the quiet, which is also what proves it was quiet
        # with the panel still open: `open -> …` could not be written otherwise.
        machine.click(*panel.past_the_panel(), f"past the panel, at {panel.past_the_panel()}")
        said = panel.wait_for_it_to_close(machine, story, "the click past the panel")
        machine.screenshot(check_dir, "after the click past the panel")
        panel.expect_it_closed(said, "open", "closeRequested", "the click past the panel")

        machine.sleep(config.SETTLE_SECONDS)
        in_front = probes.frontmost(machine, "asking which application the click past the panel left in front")
        lab.note(f"   in front after the click past the panel: {in_front}")
        expect(
            in_front == config.THE_DESKTOP,
            f"{in_front} is in front {config.SETTLE_SECONDS}s after a click past the panel onto the desktop, "
            f"not the {config.THE_DESKTOP} the click brought forward — uDeck handed the keyboard back to "
            f"{before}, which was in front before the panel, over the application the operator had just "
            f"chosen: {panel.short(said)}",
        )

        said = panel.reveal(machine, story, "the gesture after the click past the panel")
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
    story = panel.Story(machine, log, check_dir, lab.note)
    try:
        said = panel.interrupt_a_held_panel(machine, story, check_dir)
        panel.expect_it_closed(said, "open", "otherAppActivated", "the switch with no click")
        said = panel.reveal(machine, story, "the gesture after the switch")
        came_back = panel.revealed(said)
        expect(
            came_back == ["open"],
            f"the panel came back as {came_back} after another application interrupted it, not whole — "
            f"the work the operator was in the middle of was thrown away: {panel.short(said)}",
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
    story = panel.Story(machine, log, check_dir, lab.note)
    try:
        said = panel.interrupt_a_held_panel(machine, story, check_dir)
        panel.expect_it_closed(said, "open", "otherAppActivated", "the switch with no click")
        said = panel.reveal(machine, story, "the gesture after the switch")
        restored = panel.revealed(said)
        expect(
            restored == ["open"],
            f"the panel came back as {restored} after another application interrupted it, not whole, so "
            f"there is no restored panel to click past: {panel.short(said)}",
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
        said = panel.wait_for_it_to_close(machine, story, "the click past the restored panel")
        machine.screenshot(check_dir, "after the click past the restored panel")
        panel.expect_it_closed(said, "open", "closeRequested", "the click past the restored panel")

        machine.sleep(config.SETTLE_SECONDS)
        after = story.take(f"the {config.SETTLE_SECONDS}s after the click")
        news = panel.news_of_another_application(said + "\n" + after)
        if news:
            raise LabError(
                "hearing the click past the restored panel by uDeck's own monitor alone",
                "the workspace also told uDeck another application came forward, so this click did not rest on "
                f"the monitor alone: {panel.short(chr(10).join(news))}",
            )

        in_front = probes.frontmost(machine, "asking which application the click past the restored panel left in front")
        lab.note(f"   in front after the click past the restored panel: {in_front}")
        expect(
            in_front == config.THE_DESKTOP,
            f"{in_front} is in front {config.SETTLE_SECONDS}s after a click past the restored panel onto the "
            f"desktop, not the {config.THE_DESKTOP} whose desktop it is — uDeck moved the operator somewhere "
            f"he did not click, on the road where its own monitor is the only messenger: {panel.short(said)}",
        )

        said = panel.reveal(machine, story, "the gesture after the click past the restored panel")
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
    story = panel.Story(machine, log, check_dir, lab.note)
    try:
        panel.reveal_a_peek(machine, story, "the reveal")
        machine.screenshot(check_dir, "the peek")
        machine.key("esc", "on the machine's keyboard")
        said = panel.wait_for_it_to_close(machine, story, "Escape")
        machine.screenshot(check_dir, "after Escape")
        panel.expect_it_closed(said, "peek", "escape", "Escape")

        machine.sleep(config.STAYS_SHUT_SECONDS)
        after = story.take(f"the {config.STAYS_SHUT_SECONDS}s after Escape")
        machine.screenshot(check_dir, "the panel still away")
        since_it_closed = panel.after_it_closed(said) + "\n" + after
        expect(
            panel.revealed(since_it_closed) == [],
            f"the panel came back as {panel.revealed(since_it_closed)} within {config.STAYS_SHUT_SECONDS}s of "
            f"Escape, with the pointer left where the gesture put it: {panel.short(since_it_closed)}",
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
    story = panel.Story(machine, log, check_dir, lab.note)
    try:
        application = _a_document_in_front(machine, lab)
        panel.reveal_a_peek(machine, story, "the reveal")
        machine.screenshot(check_dir, "the peek")
        machine.key("esc", "on the machine's keyboard")
        said = panel.wait_for_it_to_close(machine, story, "Escape")
        machine.screenshot(check_dir, "after Escape")
        panel.expect_it_closed(said, "peek", "escape", "Escape")

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
            f"account of giving the keyboard back is in {panel.short(said)}",
        )
    finally:
        story.keep()


# --- The keyboard shortcut ------------------------------------------------------------


def check_the_hotkey(machine, check_dir, lab):
    """⌃⌥U opens the panel, and opens it ready to be typed into.

    The other way in, and the one that works with the cursor nowhere near the
    top of the screen. What makes it a check of its own rather than a third
    opening path is what uDeck does *after* showing the panel: someone who
    reached for a shortcut has his hands on the keys and is not going to move
    the mouse over to promote a peek, so `toggleFromKeyboard` promotes it for
    him — `collapsed -> peek on revealRequested`, then `peek -> open on
    interacted`. Both lines, in that order and with nothing else between them,
    are the verdict (`panel.OPENED_READY_TO_TYPE`). A check that accepted the
    first alone would be green for a shortcut that left him a glance.

    **uDeck is started inside the window on its own log**, for a reason the
    control in the middle of the screen already has: the line this check rests
    its premise on is written once, at launch. `RegisterEventHotKey` can be
    refused — another application may hold the same combination, and the window
    server gives it to whoever asked first — so a running uDeck is not yet one
    that would hear the key, and `hotkey ⌃⌥U registered` is uDeck saying it
    would. Measured on 2026-09-23: that line arrived on each of five fresh
    machines, in the panel category, which is the same window the phases come
    in (.build/e2e/20260923-212036Z, three machines, and -212549Z, two).

    The pointer is parked in the middle of the screen before any of it, and
    before the window opens. Not only because a pointer left in the strip by
    whatever ran before would open the panel by the gesture and leave this check
    pressing a shortcut at a panel that was already up — but because with the
    panel open the pointer is *inside* it, which is where a pointer that changes
    nothing belongs.

    How the chord is pressed, and why not over VNC like every other key the lab
    sends, is in `panel.press_the_chord`: measured the same day, twelve presses
    over VNC reached uDeck not once and left the guest's keyboard wedged.

    **Where the keyboard went is not asked here.** This check presses the chord
    and reads two phases out of uDeck's log; it types nothing and reads no
    document, so a uDeck that showed the panel and left the keyboard where it
    was would pass it. `panel.the-hotkey-again` is the one that types, and the
    one sentence about the keyboard the shortcut checks make is its. What this
    check does hold about keys is narrower and is in its test: it presses no key
    over VNC at all, so the only keystroke in it is the chord made inside the
    guest.
    """
    log = _prepare(machine, check_dir, lab, launch=False)
    panel.park_in_the_middle(machine)
    story = panel.Story(machine, log, check_dir, lab.note)
    try:
        _a_uDeck_holding_the_hotkey(machine, story, check_dir)
        said = _press_the_hotkey(machine, story, "to open the panel", panel.opened_ready_to_type)
        machine.screenshot(check_dir, "after the hotkey")
        panel.expect_it_opened_ready_to_type(said, config.THE_HOTKEY)
    finally:
        story.keep()


def check_the_hotkey_again(machine, check_dir, lab):
    """A second press puts the panel away, and hands the keyboard back with it.

    The shortcut is a toggle, and the half that is easy to get wrong is this
    one: `toggleFromKeyboard` asks the panel to close only when it is not
    already shut, so a build that lost that branch leaves the operator with a
    panel he cannot put away by the key he opened it with. The verdict is the
    phase and the event together, as everywhere else the panel closes — `open ->
    collapsed on closeRequested`, once, with nothing reopening in the same read.

    **And two keystrokes, which are stronger than the log.** The panel the
    shortcut opens is one to type into, so the question that follows it is where
    the keyboard is, and the log cannot answer that twice: uDeck says `first
    responder while typing` once per process (`loggedResponderTypes.insert`), so
    it is an oracle a check can read only on the first machine it ever runs on.
    A document can be read as often as one likes. One key is pressed with the
    panel open and must *not* reach it — measured on 2026-09-23, three cycles
    out of three — and one after the panel is away, which must. Together they
    say the shortcut took the keyboard and gave it back, which is what the
    operator feels.

    **A key that did not arrive and a document that cannot be read look the
    same**, and only one of them is about uDeck. `probes.typed_into` raises when
    System Events refuses the question, but an answer of `""` is not a refusal —
    it is the window read as empty — and "the key I pressed is not in this text"
    is satisfied by every empty string there is. So the same reading is asked
    both ways: the letter that reached the document before the panel was ever
    shown must still be there, *and* the letter pressed at the open panel must
    not be. A document that comes back empty then goes red on the first of those
    — naming a read that proves nothing — instead of passing the second by
    holding nothing at all.

    **Not by comparing the whole text**, because TextEdit rewrites it: measured
    in the same run, a document holding "ay" was read back as "Ay" with no key
    pressed in between. So each key is a letter of its own
    (`config.WHILE_THE_PANEL_IS_OPEN_KEY`), the one pressed at the open panel is
    looked for rather than the text compared, and what is read at the end is
    compared without regard to case.

    Where the operator is left is not asked here, and can be: uDeck's own
    account says it hands the keyboard back to the application from before —
    `gave the keyboard back after dismissed with uDeck in front, so bringing
    back TextEdit`, three times out of three in the run that measured the cycles
    (.build/e2e/20260923-212549Z), and once in every run of this check the lab
    has kept. That the key then arrives in that application's document is the
    stronger form of the same question, and it is the one this check asks.

    **The pointer is parked before uDeck starts**, for the reason
    `panel.the-hotkey` has it: a pointer left in the strip by whatever ran
    before opens the panel by the gesture, and between the launch and the mark
    that reveal would be outside the window this check reads.
    """
    log = _prepare(machine, check_dir, lab, launch=False)
    panel.park_in_the_middle(machine)
    story = panel.Story(machine, log, check_dir, lab.note)
    try:
        app.launch(machine)
        machine.screenshot(check_dir, "uDeck running")
        story.take("uDeck starting")
        application = _a_document_in_front(machine, lab)
        said = _press_the_hotkey(machine, story, "to open the panel", panel.opened_ready_to_type)
        machine.screenshot(check_dir, "the panel the hotkey opened")
        panel.expect_it_opened_ready_to_type(said, config.THE_HOTKEY)

        machine.key(config.WHILE_THE_PANEL_IS_OPEN_KEY, "with the panel the shortcut opened on screen")
        machine.sleep(config.SETTLE_SECONDS)
        story.take("the key pressed with the panel open")
        while_open = probes.typed_into(machine, application, f"reading what {application} holds with the panel open")
        lab.note(f"   {application} holds with the panel open: {while_open!r}")
        # The positive half of this one reading, and it is what makes the other
        # half mean anything: "the key is not in the text" is true of every
        # empty answer, and System Events hands back an empty window as readily
        # as it hands back a full one.
        expect(
            config.BEFORE_THE_PANEL_KEY in while_open.lower(),
            f"{application} holds {while_open!r} with the panel open, without the "
            f"{config.BEFORE_THE_PANEL_KEY!r} that reached it before the panel was ever shown: this read says "
            "nothing about where the next key went, because a document that holds nothing holds no key either",
        )
        expect(
            config.WHILE_THE_PANEL_IS_OPEN_KEY not in while_open.lower(),
            f"a key pressed with the panel open reached {application}, which holds {while_open!r}: the panel "
            f"{config.THE_HOTKEY} opened does not have the keyboard, so it is not the panel ready to be typed "
            "into that the shortcut promises",
        )

        said = _press_the_hotkey(machine, story, "a second time", panel.closed_on)
        machine.screenshot(check_dir, "after the second press")
        panel.expect_it_closed(said, "open", "closeRequested", f"{config.THE_HOTKEY} a second time")

        # The handback happens in the millisecond the collapse is logged, and the
        # application it hands to is brought forward by the system, which takes
        # its own moment — the same one every other closing check waits out.
        machine.sleep(config.SETTLE_SECONDS)
        machine.key(config.AFTER_IT_CLOSED_KEY, "after the shortcut put the panel away")
        machine.sleep(config.SETTLE_SECONDS)
        story.take("the key pressed after the panel was put away")
        holds = probes.typed_into(machine, application, f"reading what {application} holds afterwards")
        lab.note(f"   {application} holds after the panel was put away: {holds!r}")
        machine.screenshot(check_dir, "after the key that followed")
        wanted = config.BEFORE_THE_PANEL_KEY + config.AFTER_IT_CLOSED_KEY
        expect(
            holds.lower() == wanted.lower(),
            f"{application} holds {holds!r} and not {wanted!r} after a key pressed once {config.THE_HOTKEY} had "
            f"put the panel away: the key the operator typed next did not reach the application he was in, and "
            f"uDeck's own account of giving the keyboard back is in {panel.short(said)}",
        )
    finally:
        story.keep()


def check_the_hotkey_closes_what_the_gesture_opened(machine, check_dir, lab):
    """The shortcut puts away a panel it did not open: a peek the pointer earned.

    The third face of the toggle, and the one neither of the other two can see.
    uDeck's rule is "shut, or else close" — `toggleFromKeyboard` guards on
    `state.phase == .collapsed` and everything else goes to `closeRequested`
    (`PanelController.swift`) — so the shortcut is the operator's way out of
    *any* panel on screen, not only out of the one he opened with it. That is
    the part the operator meets first: he brushes the top of the screen by
    accident, a panel appears, and the key he knows is the key he reaches for.

    **What goes wrong if the guard is narrowed to the phase the shortcut leaves
    behind.** `panel.the-hotkey` starts from a shut panel and `panel.the-hotkey-again`
    from one the shortcut had already promoted, so a build that closed on `.open`
    alone answers both of them exactly as an unbroken one does. At a peek it takes
    the other branch instead: `revealRequested` at a panel already showing is
    ignored, `interacted` is not, and the shortcut would *promote* the glance
    into a working panel — the opposite of what was asked of it, and green
    everywhere else in the lab. So the verdict here is the pair, as at every
    other closing: `peek -> collapsed on closeRequested`, once, with nothing
    reopening in the same read.

    The panel is opened by the gesture and not by the shortcut, which is the
    whole point, so it is a peek — `panel.reveal_a_peek` refuses anything else before
    the chord is pressed, because a check that took whatever panel it happened
    to get would be a different check on different days.

    The pointer is left where the gesture put it, in the strip. Nothing reopens
    the panel there: every collapse tells the gesture not to fire again until
    the pointer has left the strip (`idle: alreadyFiredThisVisit`), which is
    what `panel.escape` rests on next door.
    """
    log = _prepare(machine, check_dir, lab, launch=False)
    panel.park_in_the_middle(machine)
    story = panel.Story(machine, log, check_dir, lab.note)
    try:
        _a_uDeck_holding_the_hotkey(machine, story, check_dir)
        panel.reveal_a_peek(machine, story, "the gesture")
        machine.screenshot(check_dir, "the peek the gesture opened")
        said = _press_the_hotkey(machine, story, "at the peek the gesture opened", panel.closed_on)
        machine.screenshot(check_dir, "after the hotkey")
        panel.expect_it_closed(
            said, "peek", "closeRequested", f"{config.THE_HOTKEY} at a peek the gesture had opened"
        )
    finally:
        story.keep()


def check_a_chord_that_is_not_the_hotkey(machine, check_dir, lab):
    """⌃⌥J does nothing — to a uDeck that answers ⌃⌥U a moment later.

    The control for every shortcut check, and on its own it would be the
    emptiest kind of green. "Nothing happened" is free when nothing was
    listening: a uDeck that registered no shortcut at all, or registered one and
    lost it to another application, is silent for *every* chord, and this check
    would be exactly as green over it.

    So the witness is in the same check, on the same machine, moments later: the
    real shortcut is pressed after the silence, and has to open the panel ready
    to be typed into. That is a uDeck that was running, holding the combination
    and hearing chords made this way — all three, at the end of the stretch it
    was supposed to have ignored. If it fails, the silence before it proved
    nothing, and the check says so rather than passing.

    The two chords differ in the key alone — the same ⌃ and ⌥ held over "J"
    instead of "U" (`config.NOT_THE_HOTKEY_KEY_CODE`) — so what is controlled
    for is the combination and not the way the lab presses it. Measured on 2026-09-23: ⌃⌥J
    left uDeck's log empty for ten seconds, made both ways it can be made
    (.build/e2e/20260923-212036Z, hotkey.wrong-chord).

    Every phase is read and not only the reveals, because the sentence is that a
    chord uDeck never registered does not move the panel *at all*.

    **The pointer is parked before uDeck starts**, the same order as every other
    shortcut check. A pointer left in the strip by whatever ran before opens the
    panel by the gesture in a fraction of a second, and a reveal that landed
    between the launch and the mark would leave this control reading a stretch
    that was never silent — or, worse, reading it as silent while a panel it
    never saw open sat on the screen.
    """
    log = _prepare(machine, check_dir, lab, launch=False)
    panel.park_in_the_middle(machine)
    story = panel.Story(machine, log, check_dir, lab.note)
    try:
        app.launch(machine)
        machine.screenshot(check_dir, "uDeck running")
        story.take("uDeck starting")
        panel.press_the_chord(
            machine, config.NOT_THE_HOTKEY_KEY_CODE, f"{config.NOT_THE_HOTKEY}, which uDeck never registered"
        )
        machine.sleep(config.NOTHING_HAPPENS_SECONDS)
        said = story.take(f"{config.NOT_THE_HOTKEY}, and the {config.NOTHING_HAPPENS_SECONDS}s after it")
        machine.screenshot(check_dir, "after the chord that is not the hotkey")
        moved = panel.phases(said)
        expect(
            moved == [],
            f"{config.NOT_THE_HOTKEY} moved the panel {moved} — a chord uDeck never registered reached it and "
            f"was acted on, so the operator's own shortcuts are not his: {panel.short(said)}",
        )

        heard = _press_the_hotkey(
            machine, story, "pressed to show uDeck was listening all along", panel.opened_ready_to_type
        )
        machine.screenshot(check_dir, "after the shortcut itself")
        panel.expect_it_opened_ready_to_type(
            heard, f"{config.THE_HOTKEY}, pressed to show uDeck was listening all along and so that the silence "
            f"after {config.NOT_THE_HOTKEY} means something,"
        )
    finally:
        story.keep()


def check_the_hotkey_dies_with_udeck(machine, check_dir, lab):
    """The combination goes back to the Mac when uDeck does.

    A global shortcut is not uDeck's to keep. `RegisterEventHotKey` asks the
    window server to deliver one combination to one process, and for as long as
    that registration stands **no other application on the Mac sees that key**.
    So a uDeck that is gone and still holds ⌃⌥U is not a uDeck bug the operator
    could shrug at: it is a key taken out of his keyboard, in every application,
    until he logs out. Nothing in the lab looked at that, and nothing in uDeck's
    own tests can — the registration lives in the window server and not in
    uDeck.

    **The shape is: it worked, then uDeck left, then the same press lands in a
    document instead.** The first press is the witness. It has to open the panel
    ready to be typed into, on this machine, in this run, with this uDeck — so
    that what the press does afterwards is a sentence about a combination that
    was demonstrably live a moment before, and not about a lab that cannot press
    chords. A second press puts the panel away before uDeck goes, so that the
    keyboard is back where the operator left it and the reading at the end is
    about the chord rather than about a uDeck that died holding the keys.

    **And then "nothing happened" would be worth nothing.** A machine with
    nothing running on it is silent in exactly the way this check would want the
    chord to be silent. uDeck's log says no more after uDeck has ended, of
    course it does; and the panel is never read off a screenshot here, because it
    is translucent over whatever is behind it (see the opening checks). So the
    verdict is not an absence at all. It is a **presence**, and it is in the
    document:

    `RegisterEventHotKey` takes the combination out of the keyboard. While the
    registration stands the window server delivers ⌃⌥U to uDeck and to nobody
    else, so the application behind the panel never sees the keystroke — and
    once the registration is gone the same keystroke goes where every other one
    goes. Both halves are read here, of the same document, minutes apart:

    - while uDeck holds it, two presses leave the document exactly as it was,
      holding the one letter that reached it before the panel was ever shown;
    - once uDeck has ended, one press puts `0x15` into it — the control
      character the layout gives for Control over "U"
      (`config.THE_CHORD_IN_A_DOCUMENT`) — and an ordinary letter after that
      arrives too.

    Measured in the guest on 2026-09-24, at the first run of this check: with
    uDeck gone the document read back `'a\\x15x'`, the chord and then the letter
    (.build/e2e/20260924-230410Z). A combination that outlived uDeck would leave
    that document holding `'ax'`, as empty of the chord as a living uDeck leaves
    it — which is what this check goes red on, and it is the only reading in the
    lab that could tell the two apart.

    The letter after the chord is in the same sentence for a reason of its own.
    A leaked registration is not only a key that opens nothing: it is a key
    nobody receives, and a modifier left down behind one takes the rest of the
    keyboard with it. That is not hypothetical in this guest — measured on
    2026-09-23, one ⌃⌥U sent over VNC wedged its keyboard, and afterwards no key
    at all reached a document that had taken one moments before
    (.build/e2e/20260923-212833Z).

    **What this is red for, and what it is not.** It is red for a uDeck that
    holds the combination somewhere its own process does not end: a helper, a
    login item, an input tap installed for it. It is *not* red for
    `HotKeyMonitor.unregister` and `stop()` being emptied out — macOS reclaims a
    process's hot keys when the process exits, so a build that never unregisters
    anything gives the combination back exactly as this one does. That was
    measured and not argued: with both of those methods emptied, this check
    passed and the document read back the same `0x15` and the letter after it
    (2026-09-24, .build/e2e/20260924-233513Z). The tidying in `stop()` is
    therefore held by no check here, and
    cannot be until something asks uDeck to give the key up while it is still
    running — the settings screen changing the shortcut, which is the other
    thing this file lists as known and unchecked.
    """
    log = _prepare(machine, check_dir, lab, launch=False)
    panel.park_in_the_middle(machine)
    story = panel.Story(machine, log, check_dir, lab.note)
    try:
        _a_uDeck_holding_the_hotkey(machine, story, check_dir)
        application = _a_document_in_front(machine, lab)

        said = _press_the_hotkey(machine, story, "while uDeck is there to hear it", panel.opened_ready_to_type)
        machine.screenshot(check_dir, "the panel the hotkey opened")
        panel.expect_it_opened_ready_to_type(said, config.THE_HOTKEY)

        said = _press_the_hotkey(machine, story, "to put the panel away before uDeck goes", panel.closed_on)
        machine.screenshot(check_dir, "the panel put away before uDeck goes")
        panel.expect_it_closed(said, "open", "closeRequested", f"{config.THE_HOTKEY} a second time")

        # Half of the sentence, and the half that is read while uDeck is still
        # there: a combination uDeck holds is one the application behind it
        # never sees.
        machine.sleep(config.SETTLE_SECONDS)
        while_held = probes.typed_into(
            machine, application, f"reading what {application} holds while uDeck has the shortcut"
        )
        lab.note(f"   {application} holds while uDeck has the shortcut: {while_held!r}")
        expect(
            while_held.lower() == config.BEFORE_THE_PANEL_KEY,
            f"{application} holds {while_held!r} and not {config.BEFORE_THE_PANEL_KEY!r} after two presses of "
            f"{config.THE_HOTKEY} at a uDeck that holds it: the keystroke reached the application behind the "
            "panel, so this machine cannot tell a combination uDeck has from one nobody has",
        )

        # Setting the scene and not a verdict: a uDeck that would not end leaves
        # nothing to ask this check's question of.
        app.quit_app(machine, "ending the uDeck that holds the shortcut")
        lab.note("   uDeck has ended, and the shortcut is pressed again")
        machine.screenshot(check_dir, "uDeck gone")

        panel.press_the_chord(
            machine, config.HOTKEY_KEY_CODE, f"{config.THE_HOTKEY}, with uDeck no longer there"
        )
        machine.sleep(config.NOTHING_HAPPENS_SECONDS)
        after = story.take(
            f"{config.THE_HOTKEY} with uDeck gone, and the {config.NOTHING_HAPPENS_SECONDS}s after it"
        )
        machine.screenshot(check_dir, "after the chord with uDeck gone")
        moved = panel.phases(after)
        expect(
            moved == [],
            f"the panel moved {moved} on {config.THE_HOTKEY} after uDeck had ended: {panel.short(after)}",
        )

        machine.key(config.AFTER_IT_CLOSED_KEY, f"after {config.THE_HOTKEY} at a machine uDeck has left")
        machine.sleep(config.SETTLE_SECONDS)
        holds = probes.typed_into(
            machine, application, f"reading what {application} holds after the chord uDeck did not hear"
        )
        lab.note(f"   {application} holds after the chord uDeck did not hear: {holds!r}")
        machine.screenshot(check_dir, "after the key that followed the chord")
        wanted = (
            config.BEFORE_THE_PANEL_KEY + config.THE_CHORD_IN_A_DOCUMENT + config.AFTER_IT_CLOSED_KEY
        )
        expect(
            holds.lower() == wanted.lower(),
            f"{application} holds {holds!r} and not {wanted!r} after {config.THE_HOTKEY} was pressed at a "
            f"machine uDeck has left and an ordinary key after it: the combination did not go back to the "
            f"keyboard when uDeck did — something is still holding it, and the operator has lost that key "
            "in every application he has",
        )
    finally:
        story.keep()


# --- What all fourteen do -----------------------------------------------------------


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
        f"'{panel.SHUT}'. What it says of the panel: {panel.short(said)}",
    )


def _a_uDeck_holding_the_hotkey(machine, story, check_dir):
    """uDeck started inside the window on its log, and saying which shortcut it holds.

    The premise every shortcut check rests on, and it is not free: the window
    server hands a combination to whoever asked for it first, so
    `RegisterEventHotKey` can be refused and uDeck says so instead
    (`HotKeyMonitor.apply`). A uDeck that never got the key is silent for the
    chord in exactly the way a uDeck that ignores it is.

    Started here rather than in `_prepare` because that line is written once, at
    launch: a window opened afterwards begins after the only chance to read it.
    The same ordering, and the same reason, as the control in the middle of the
    screen.
    """
    app.launch(machine)
    machine.screenshot(check_dir, "uDeck running")
    said = panel.answer(machine, story, "uDeck starting", panel.registered_hotkeys)
    panel.expect_it_holds(said, config.THE_HOTKEY)
    return said


def _press_the_hotkey(machine, story, label, ready):
    """uDeck's own shortcut, pressed inside the guest, and what uDeck said of it.

    `label` is what the story calls this press, because a check presses it more
    than once and the two mean different things.
    """
    what = f"{config.THE_HOTKEY} {label}"
    panel.press_the_chord(machine, config.HOTKEY_KEY_CODE, what)
    return panel.answer(machine, story, what, ready)


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

    The same rule as `panel.prove_uDeck_could_have_answered`, read from the one
    place it is written (`panel.expect_it_was_still_there`): this control starts
    uDeck itself and then watches it do nothing, so a uDeck that is gone by the
    end is one that died while being watched, and that is uDeck failing. Asked
    before the log, because a uDeck that died at once would leave the log empty
    too, and "the window never started" would then be the lab blaming itself for
    a uDeck that fell over.
    """
    step = "proving uDeck was watching the pointer"
    panel.expect_it_was_still_there(
        machine,
        step,
        "uDeck was not running at the end of the control: it was started by this check and died while it "
        "was being watched, so nothing could have opened the panel either way",
    )
    if not panel.idle_reasons(said):
        raise LabError(
            step,
            "uDeck's log says nothing at all about the pointer, so the control proves nothing; "
            f"it holds: {panel.short(said)}",
        )


def _expect_uDeck_lived_through_it(machine, since_it_closed, what):
    """Proof of life after a stretch that was supposed to change nothing.

    A panel stays shut for free when nothing is running. uDeck still running,
    and still watching the pointer — naming the gate that holds the panel shut —
    is what makes the quiet uDeck's doing.
    """
    step = f"asking whether uDeck lived through {what}"
    panel.expect_it_was_still_there(
        machine,
        step,
        f"uDeck was not running {config.STAYS_SHUT_SECONDS}s after {what}: the panel only stayed away "
        "because there was nothing left to show it",
    )
    expect(
        panel.idle_reasons(since_it_closed) != [],
        f"uDeck said nothing about the pointer after {what} closed the panel, where a living uDeck names "
        f"the gate holding it shut — it was not watching: {panel.short(since_it_closed)}",
    )


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
    panel.bring_forward_before_the_panel(machine, lab.note, document=config.THE_DOCUMENT)

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
