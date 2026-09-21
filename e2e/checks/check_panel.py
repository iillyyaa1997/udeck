"""Does the panel open when it should, and close when it should?

Six checks in two halves. The first three are about the panel appearing and by
which path; the last three are about it going away again, and they are where
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
made from this Mac over VNC, where the pointer is placed by naming where it
goes, and the push is made from inside the guest as relative movement through
`IOHIDSystem` — the entry point a mouse driver posts through, where macOS moves
the pointer itself and tells applications the movement, clamping the one and not
the other (Q45).

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

**Closing.** The last three take a panel that is up and put it away by one of
the three means the operator has, and each asks which event uDeck says did it:
`peek -> collapsed on pointerLeft`, `open -> collapsed on closeRequested`,
`… -> collapsed on escape`. The phase they name on the left is as much of the
verdict as the event on the right — a peek closing when the pointer leaves is
the panel working, and a *held* panel doing the same is the one failure this
whole design exists to prevent.

They go through more steps than the opening checks, so they read the log in
steps too (`_Story`): one window opened at the start, sliced by what each action
added to it, and the whole of it kept beside the report as `story.log`. A check
that read only the end could not tell "nothing happened while the pointer was
away" from "it happened and something undid it".
"""

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
        said = story.wait_for("the pointer taken past the panel", panel.closed_on)
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

    And then the last question, which is the one the operator actually asks: what
    does the next gesture bring back? A peek, because a click outside is him
    putting the panel away. The panel that came back whole would mean uDeck had
    read his click as something interrupting him, which is the bug this check was
    written for (the race in `ApplicationSwitch`, fixed 2026-09-21).
    """
    log = _prepare(machine, check_dir, lab)
    story = _Story(machine, log, check_dir, lab.note)
    try:
        _reveal_a_peek(machine, story, "the reveal")
        machine.click(*panel.inside_the_peek(), f"inside the panel at {panel.inside_the_peek()}")
        said = story.wait_for("the click inside the peek", panel.phases)
        expect(
            ("peek", "open", "interacted") in panel.phases(said),
            f"the click inside did not hold the panel open; uDeck says: {_short(said)}",
        )
        machine.screenshot(check_dir, "the panel held open")

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
        said = story.wait_for("the click past the panel", panel.closed_on)
        machine.screenshot(check_dir, "after the click past the panel")
        _expect_it_closed(said, "open", "closeRequested", "the click past the panel")

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


def check_escape(machine, check_dir, lab):
    """Escape closes the panel, and it stays closed.

    Both halves, because the panel can reopen behind its own dismissal. The
    gesture watches the pointer the whole time, and Escape is pressed with the
    pointer wherever the thing that opened the panel left it — for a peek, inside
    the strip that opens it. uDeck has a cooldown for exactly this
    (`GestureTuning.reopenCooldown`), and a check reading only the closing line
    would stay green while the panel bounced straight back up. It has been seen
    to: three panels escaped out of `open` came back 158, 208 and 228 ms later
    (2026-09-21, .build/e2e/20260921-133502Z).

    **Out of a peek and not out of a held panel, and that is measured.** Both
    ways were made in one run (2026-09-21, .build/e2e/20260921-153502Z): four
    escapes out of a peek, and eight out of a held panel — with the pointer left
    at the click, and with it put back in the strip. All twelve closed on
    `escape` and stayed shut, so the choice is not about which one works. It is
    about what else is in the log. Every escape out of `open` is followed by
    `otherAppActivated ignored in collapsed`, eight times out of eight: closing a
    panel that had been clicked into gives up the keyboard, something else comes
    forward, and a second messenger arrives with news of the same event. It is
    ignored only because Escape got there first. That is the same race that made
    a click past the panel mean two different things on different days
    (`ApplicationSwitch`), and a check that has to win a race is a check that
    goes red on a busy machine for a reason that is not uDeck's.

    Out of a peek there is no competitor at all. A peek was never clicked, so
    uDeck never came forward, so nothing is deactivated when it goes: four out of
    four left the escape line, the cooldown, and the gate that refuses to reopen
    (`idle: alreadyFiredThisVisit`) — and nothing else.
    """
    log = _prepare(machine, check_dir, lab)
    story = _Story(machine, log, check_dir, lab.note)
    try:
        _reveal_a_peek(machine, story, "the reveal")
        machine.screenshot(check_dir, "the peek")
        machine.key("esc", "on the machine's keyboard")
        said = story.wait_for("Escape", panel.closed_on)
        machine.screenshot(check_dir, "after Escape")
        _expect_it_closed(said, "peek", "escape", "Escape")

        machine.sleep(config.STAYS_SHUT_SECONDS)
        after = story.take(f"the {config.STAYS_SHUT_SECONDS}s after Escape")
        machine.screenshot(check_dir, "the panel still away")
        expect(
            panel.revealed(after) == [],
            f"the panel came back as {panel.revealed(after)} within {config.STAYS_SHUT_SECONDS}s of Escape, "
            f"with the pointer left where the gesture put it: {_short(after)}",
        )
    finally:
        story.keep()


# --- What all six do ------------------------------------------------------------


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

    `fired by <path>` is written at PanelController.swift:358 and the panel is
    asked to appear on :361, so the line a check would otherwise rest on says
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
    """
    step = "proving uDeck was watching the pointer"
    if not app.running_pids(machine, step):
        raise LabError(step, "uDeck was not running, so nothing could have opened the panel either way")
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
    said = story.wait_for(label, panel.revealed)
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
    """The panel went away, out of the phase named and on the event named.

    Both halves of the arrow, because either on its own passes for the wrong
    reason. `-> collapsed` alone is satisfied by any of the four ways the panel
    closes, and the operator can tell them apart at the next reveal; the event
    alone says nothing about which phase heard it, and "a peek closes when the
    pointer leaves" and "a held panel does" are the difference between the design
    working and the one failure it exists to prevent.
    """
    shut = panel.closed_on(said)
    expect(shut != [], f"{what} did not close the panel; what uDeck says: {_short(said)}")
    expect(
        (was, panel.SHUT, because) in panel.phases(said),
        f"{what} closed the panel as {[m for m in panel.phases(said) if m[1] == panel.SHUT]}, "
        f"not as ('{was}', '{panel.SHUT}', '{because}'): {_short(said)}",
    )


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
    """

    def __init__(self, machine, log, check_dir: Path, note) -> None:
        self.machine = machine
        self.log = log
        self.check_dir = check_dir
        self.note = note
        self.since = log.mark("noting when the panel check begins")
        self.read_so_far = 0
        self.told: list[str] = []

    def take(self, label: str) -> str:
        """What uDeck has added since the last step, and now it is read."""
        return self._cut(self._lines(label), label)

    def wait_for(self, label: str, ready, seconds: float = config.GESTURE_ANSWER_SECONDS) -> str:
        """The same, once `ready` is satisfied by it — or once the time is up.

        Giving up quietly is the point: the check, not this, decides what an
        answer that never came means, and it has the words for it. Nothing here
        is ever the verdict.
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

    def _lines(self, label: str) -> list[str]:
        # The oracle, not the evidence: a log that cannot be read has to raise
        # here, because silence is exactly what "nothing happened" looks like.
        return self.log.read(self.since, f"reading what uDeck says about {label}").splitlines()

    def _cut(self, lines: list[str], label: str) -> str:
        said = "\n".join(lines[self.read_so_far :])
        self.read_so_far = len(lines)
        self.told.append(f"=== {label} ===\n{said or '(nothing)'}")
        return said
