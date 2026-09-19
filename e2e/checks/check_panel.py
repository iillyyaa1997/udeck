"""Does the panel open when it should — and by the path it was asked to?

Three checks, and the third is what makes the first two mean anything: the
pointer resting in the strip at the top of the screen opens the panel, the
pointer already pinned there while the device keeps pushing opens it, and the
pointer in the middle of the screen — held, and pushed at — opens nothing (Q37).

The two paths are not two ways of saying the same thing. A dwell only needs the
pointer to be somewhere; a push needs movement *reported after the pointer can
move no further*, which nothing that names a position can say. So the dwell is
made from this Mac over VNC, where the pointer is placed by naming where it
goes, and the push is made from inside the guest as relative movement through
`IOHIDSystem` — the entry point a mouse driver posts through, where macOS moves
the pointer itself and tells applications the movement, clamping the one and not
the other (Q45).

What decides each one is uDeck's own record of which path fired — `fired by
dwell on …`, `fired by push on …` — kept in the guest's unified log and read
back afterwards.
Never a screenshot: the panel is translucent over whatever is behind it, and
"something changed at the top of the screen" is exactly the evidence that would
pass for the wrong reason. The screenshots are kept as evidence for a person
(Q38), and the log also carries `idle: <reason>` — the gate that stopped the
gesture — which is what makes a run that fires nothing worth reading.

The pointer is thrown at the edge *and* pushed there in one run of one script
inside the guest. It has to be: the dwell is a fraction of a second, so a
pointer put at the edge from this Mac would have fired the dwell long before an
SSH command could push it, and the check would pass by the path it is not about.
"""

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
        said = log.since(since, "reading what uDeck says of the gesture")
        machine.screenshot(check_dir, "nothing happened")

        expect(
            panel.fired_by(said) == [],
            f"uDeck opened the panel with the pointer in the middle of the screen: {_short(said)}",
        )
        _prove_uDeck_was_watching(machine, said)
    finally:
        log.collect(check_dir, since, "keeping what uDeck said")


# --- What all three do ------------------------------------------------------------


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
        said = log.since(since, "reading what uDeck says of the gesture")
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


def _short(said):
    """The tail of what uDeck said, for a reason a person reads in one line."""
    return said.strip().replace("\n", " / ")[-400:] or "nothing"
