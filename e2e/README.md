# The end-to-end lab

`swift test` checks uDeck's decisions without a window server. Some things can
only be checked on a real Mac with a real login session — that an update
installs, that the panel opens when the pointer reaches the top edge, that
"Open at Login" survives a reboot — and checking them on the Mac you are working
on means the tests take over your screen. The lab runs them inside throwaway
macOS virtual machines instead, headless, and puts everything back afterwards.

The checks run on an Apple Silicon Mac only, and not in GitHub CI: hosted
runners do not offer nested virtualisation. The lab's own tests do run there —
see the last section.

> **Being built.** What exists today: the command, its pre-flight and report,
> the machines and the golden image they are cloned from, their screen and
> pointer over VNC, a self-check, the builds a check needs, and the first checks
> of uDeck itself — the update, with its wrong-key control, and the panel: the
> hover gesture that opens it, with its pointer-in-the-middle control, the ways
> of putting it away again, and the keyboard shortcut that does both, with its
> wrong-chord control. "Open at Login" and its checks follow.

## Running it

```sh
e2e/run.sh bake                # once: make the golden image for macOS 27
e2e/run.sh selfcheck           # does the lab work on this Mac?

e2e/run.sh --list              # what checks exist
e2e/run.sh                     # all of them
e2e/run.sh updates             # one group
e2e/run.sh updates.wrong-key   # one check
e2e/run.sh --guest 26          # on macOS 26 instead of 27 (bake it first)
e2e/run.sh --vm per-group      # one machine per group instead of per check
e2e/run.sh --keep-on-failure   # keep a failed check's machine to look at
e2e/run.sh --jobs 2            # boot the next check's machine while this one runs
e2e/run.sh cleanup --list      # what cleanup would remove, removing nothing
e2e/run.sh cleanup             # remove kept or left-behind clones
e2e/run.sh cleanup --golden --guest 26   # …and macOS 26's golden image
```

An option a command would ignore is refused rather than ignored.

You need [Tart](https://tart.run) — exactly the version pinned in
[`udeck_e2e/config.py`](udeck_e2e/config.py) — and
[uv](https://docs.astral.sh/uv/). The lab finds `tart` through `$TART`, then
`PATH`, then `~/Applications/tart.app` and `/Applications/tart.app`.

Before starting anything, the pre-flight checks the Tart version, that the host
can run the guest, free disk and memory, and that no other virtual machine is
running — macOS runs at most two macOS guests at once, so a `tart run` from
another Tart home or another user counts too. It stops only the lab's own
orphans: your `tart run udeck-e2e-…` of a clone left behind by a run that died,
identified again by pid and start time right before each signal. A kept clone
or a golden image you opened yourself is never stopped; the run refuses to start
until you close it. Nothing else is touched, and the lab does not keep your Mac
awake: if the Mac sleeps during a run, the run is interrupted.

Only one run at a time for your user on this Mac, whichever checkout or
worktree it starts from: the lock is `~/Library/Caches/udeck-e2e/lab.lock`.

## Machines

Every machine is an APFS clone of a **golden image**: Cirrus Labs' pinned
`-base` image with the lab's settings baked in once by `e2e/run.sh bake` — a
2560×1440 screen at 1×, Spotlight on, notifications silenced, English — and
read back after a restart before the image is kept. The golden image lives in
Tart's store as `udeck-e2e-golden-<guest>`, shared by every checkout; a note of
what it was baked from sits in `~/Library/Application Support/udeck-e2e/`, and a
golden image baked from another base image or by an older bake is refused. A
bake wants 60 GB free, and the lab never lets Tart delete cached images to make
room; a new golden image replaces the old one only once it holds the name.

A clone gets its own serial number, boots headless, receives this run's
throwaway SSH key through Tart's guest agent, and is ready when SSH answers and
the desktop is up. Commands go over the system's `ssh` with your SSH
configuration ignored; System Events is driven only that way, because the image
permits it for SSH and not for Tart's agent. A restart is proved by the boot
session changing — a UUID macOS makes on every boot — not by the boot time,
which a clock change moves. A machine is shut down from inside; `tart stop`, which is a
power-off, is used only after a minute of silence and is reported. With
`--vm per-check` (the default) every check gets its own clone; `per-group` and
`per-run` share one, so a check must find out the state it needs rather than
assume it.

`--jobs 2` means two machines alive, never two checks running. The checks stay
in one serial loop — so the console, the ledger and Ctrl-C work exactly as they
do at `--jobs 1` — and what overlaps is the next check's guest cloning and
booting while the current one is still being used. It begins only once the
current check has its machine, because two booting at the same time as one still
shutting down would be three at once, one past what macOS allows. A machine that
does not come up in the background is not a verdict: it is put back and the check
boots its own, exactly as it would have. With `--vm per-run` there is no next
machine, so `--jobs 2` is refused there rather than quietly doing nothing.

What it is worth, on the four login checks on one Mac (48 GB, macOS 27): 5m16s
and 5m26s at one machine; 3m20s and 4m03s at two, with each background boot
taking 26–29s and no check having to wait for its machine. A third run at two
machines took 5m30s — slower than serial, unexplained, and the reason this is an
option rather than the default. The saving is not the boot time: a guest booting
beside a running check slows that check down, so the line each check prints says
both how long its machine took to come up and how long the check still waited
for it. Two numbers, because one of them alone flatters the option.

If the Mac goes to sleep during a check, anything that went wrong in it becomes
"could not check".

## Screen and pointer

Every machine runs with Tart's VNC server, which is Virtualization.framework's
own: moving the pointer through it moves the machine's virtual pointing device,
the way a physical mouse does, and a screenshot is the machine's framebuffer, so
nothing in the guest needs a screen-recording permission. A machine is ready
only once a screenshot shows a drawn screen: 2560×1440, with no single colour
covering nearly all of it. That rules out the two ways a screen answers before it
is ready — a flat black frame, and the Apple boot screen, which measured 99.8%
one colour half a minute after the desktop was up.

What a screenshot cannot prove is that it is *recent*. A still screen is answered
with the same frame as before, and the pointer is not drawn into it, so the lab
has no way to force a repaint and check that the picture followed. It does check
that the server follows the guest at all: the self-check opens a window inside
the guest and requires the next frame to differ. Read a screenshot as "the screen
as of the last thing that was drawn on it".

Each pointer move and each screenshot is a connection of its own, in a short
process with a deadline (about half a second each). The server answers one
full frame per connection — a second request on the same connection waits until
something on the screen repaints — so the lab never asks twice. Coordinates are
pixels from the top-left corner, as in a screenshot. After a restart macOS puts
the pointer near the top-left corner, 10 pixels below the top edge, so a check
that cares where the pointer is puts it there first.

A key can be pressed the same way (`machine.key("esc", …)`, named as vncdotool
names them), and it is the one action with no coordinates: it arrives at the
machine's keyboard and macOS delivers it wherever it is delivering keystrokes.
So a check that presses one has to have put the keyboard where it wants it, and
to say what proves the key landed there — a keystroke that went somewhere else
looks exactly like a keystroke nothing responded to.

**A chord is the one keystroke the lab does not send this way.** Held modifiers
do not survive the trip in this guest: measured on 2026-09-23, ⌃⌥U over VNC
reached uDeck not once in twelve presses and left the guest's keyboard taking
nothing at all afterwards, and ⌘W had already been seen arriving as a plain
letter. Chords are made inside the guest instead — see the panel's keyboard
shortcut below.

**While a machine runs, its screen can be reached from your local network**, not
only from this Mac. Tart prints the address as `127.0.0.1`, but the server
listens on every interface, and macOS's firewall lets the notarized Tart in by
default. It asks for a password made for that machine, of which VNC checks the
first 8 characters, and it exists only while the machine does — minutes per
check. The lab connects to `127.0.0.1` only and says this before every run. To
keep the screen to this Mac, block incoming connections for tart in System
Settings → Network → Firewall → Options; the lab reads that setting — for the
`tart.app` bundle and for the binary inside it, since macOS may hold the block
against either — and stops saying it. The password stays out of the lab's console, ledger and command
lines; it is in `tart-run.log` in the run's report, as Tart printed it.

**A connection made after about a minute of silence crashes Tart's VNC server**
and takes the machine with it — `_VZVNCServer` asserting while it sets its
accessor up again. Measured on purpose, three times: a screenshot at 0 s of
silence is fine, at 30 s fine, at 60 s fatal. It killed a check that waits
ninety seconds to prove nothing installs, twice. So every machine takes a frame
nobody asked for every twenty seconds while it lives, under the same lock as
every other VNC action; a heartbeat that fails is said once and changes no
verdict, and it stops with the machine. If the server does crash anyway, the
check that was running says the machine was killed by SIGTRAP and where macOS
keeps the crash report.

## Builds

An update check needs two real builds of uDeck: one to install and a newer one to
be offered. The lab makes them from the checkout it is running in, through
`Scripts/make-app.sh`, and they differ from a build you would make by hand in
three ways — each of them something a check depends on:

* they go to `.build/e2e/<run>/builds/<check>/<feed>/<version>-<build>/`, never
  `dist/` — a directory per check and per feed, because two checks build the same
  versions and the second must not write over the zips and the build log the
  first one's report is made of;
* they carry the version the lab asked for in both keys, including
  `CFBundleVersion`, which is the one Sparkle compares when it decides whether an
  update is newer;
* they stay zips on this Mac. A lab build is the *released* application,
  identifier and all, so an unpacked copy here could take the release's login
  item merely by being launched. It is unpacked inside the machine and nowhere
  else, and the lab reads the bundle's plist out of the zip — in memory — to
  check it got the build it asked for. A bundle that a failed or killed build
  left behind is removed, by the script itself and by the lab after it.

A build is stopped as a whole — the script and the compiler it started share a
process group — so a run that gives up on a build does not leave `swift build`
using the Mac afterwards, and Ctrl-C ends it too.

The update is signed with a key made for the run and deleted with it. Sparkle's
own `generate_keys` would leave a private key in your login keychain; the lab
generates the key itself and hands `sign_update` a file holding the base64 of the
32-byte seed (measured: that is the form it reads, and its signatures verify
against the public key baked into the bundle).

## The checks

### The update

`updates.sparkle` builds two real copies of uDeck, installs the older one,
serves the newer one from inside the machine, and drives uDeck's own settings
window — the section is chosen and the buttons pressed with the machine's
pointer, at the coordinates the accessibility API reports for them. What counts
is the version of the bundle on disk afterwards and a new process: never what
the pane says about itself.

`updates.wrong-key` is the control, and it is the reason the first one is worth
anything: the same offer, signed with a different key, must not install. But
"nothing installed" is what a broken check looks like too, so the control also
has to show that uDeck *tried*: either the guest's own access log names the
archive — Sparkle checks the signature after downloading it — or uDeck says on
its pane that its check did not finish. Neither, and the run says so rather than
passing.

### The panel

`panel.dwell` puts the pointer in the strip at the top of the screen over VNC
and leaves it there — five rows down, not on the top row. A pointer on the top
row is pinned against the edge, and the VNC jump there was sometimes reported as
upward movement *at* the edge, which is a push: on 2026-09-21, 7 of 45 reveals
meant as dwells fired by push. Row 5 is inside uDeck's 6-point strip and short
of the rows it counts as pinned (`config.INSIDE_THE_STRIP_Y`, held against
uDeck's own defaults by the lab's tests); measured the same day, 36 reveals
there all fired by the dwell, where the same probe on the top row saw 2 pushes
in 16. `panel.push` is the other path: upward movement reported *after* the
pointer can move no further. The lab copies a small script into the guest that
throws the pointer at the edge and keeps pushing in one run, milliseconds apart
— the dwell fires a fraction of a second after the pointer stops, so a pointer
placed from outside and pushed over SSH would open the panel by the wrong path.

**`panel.push` could not pass inside a virtual machine until 2026-09-19, and
what changed was which call the lab makes.** Posting the movement as a `CGEvent`
delta never worked and never could: measured on 2026-09-18, fifteen shapes of
push on four machines, five events carrying ±30 points at y=400 left the pointer
at exactly (1280, 400) — the position on the event is what moves it, and what
applications are told is the movement that actually happened, which against the
top edge is nothing.

`IOHIDPostEvent` is the call that works, and the reason it was written off is
worth keeping: it was tried under `sudo`. The privilege it asks for is
`kIOClientPrivilegeLocalUser`, which XNU answers with `CopyConsoleUser(euid)`,
and root holds no console session — so `sudo` *guarantees* the
`kIOReturnNotPrivileged` that was recorded as "refused even as root". Run as the
logged-in user, which is how the lab reaches the guest anyway, the same call
returns `KERN_SUCCESS`, macOS moves the pointer itself, and the movement reaches
applications the way a mouse's does: at the edge the position clamps and the
delta keeps coming, which is the signal this path is made of. Measured in a
clone on 2026-09-19, both halves — six reports of 40 moved the pointer exactly
240 pixels down, and a throw-and-push at the top edge made uDeck log `fired by
push`.

This needs no driver, no system extension and nothing in the golden image. It
does need the push to be run as the console user: `sudo` would break it, and the
script says so rather than failing quietly.

Before it asks uDeck anything, the check reads back where the pointer ended up.
A push against an edge the pointer never reached would prove nothing, and that
is a lab failure — "could not check" — not a verdict about uDeck.

`panel.middle-of-the-screen` is their control: the pointer held in the middle of
the screen and pushed at there, where neither the passage of time nor an upward
shove means anything. And because "nothing happened" is free when nothing is
running, the control also requires uDeck to have been watching — its own log
names the gate that stopped the gesture.

What decides all three takes two sentences from uDeck, and the second was added
on 2026-09-19 after an audit found the first insufficient on its own. Which path
fired — `fired by dwell on …`, `fired by push on …` — and whether the panel then
opened — `collapsed -> peek on revealRequested`. uDeck writes the first three
lines *before* it asks the panel to appear (`PanelController.swift:359` against
`:362`), so a panel that failed to open for everybody would leave every one of
these checks green; the phase is written from inside the change and only when
there was one. The control needs both too: a panel shown in the middle of the
screen by anything at all is exactly as wrong, and the gesture line would never
mention it.

It is uDeck's own account and not a photograph, and that is measured rather than
settled for: the window server cannot answer more strictly. uDeck keeps one
window at the status-bar level from launch onwards, and after the first reveal
its shape does not go back — open and shut-again look identical from outside
(`CGWindowListCopyWindowInfo` in a guest, 2026-09-19: 820×128 at the top in both).

Those are debug messages, which the unified
log keeps nowhere unless it is asked to, so the lab asks the guest to keep this
one subsystem's (`log config`, root, and it dies with the machine) and reads them
back with `log show` from a moment on the guest's own clock. It also checks that
the asking worked: a log nobody is keeping answers every question with silence,
and silence is what a check that proves nothing looks like. The measurement
behind that: `log stream` into a file in the guest delivered the first gesture's
lines and then nothing at all, four gestures in a row, while the kept log held
every one. The same messages carry `idle: <reason>`, which is what makes a
gesture that fired nothing worth reading.

### The panel closing

Six more. Five of them read the same log from the other end; the sixth asks the
question that follows all of them and that the log cannot answer, which is where
the keyboard went. The line the five take as the verdict is the phase and the
event together — `peek -> collapsed on pointerLeft`, `open -> collapsed on
closeRequested`, `open -> collapsed on otherAppActivated`, `peek -> collapsed on
escape` — and both halves of it are the check. The event, because the panel has
four ways of going away and they are not interchangeable: it remembers which one
it was, and the operator sees the difference at the *next* reveal, where a panel
he put away comes back as a peek and a panel something interrupted comes back
whole. The phase, because **once the panel is held, the cursor leaving must
never close it** — a peek closing when the pointer leaves is the panel working,
and a held panel doing the same is the one failure this design exists to
prevent. And that line has to be the only
closing in the read that heard it, with nothing reopening there: `log show`
takes long enough that the read which hears the panel close can already hold
what came next.

`panel.the-pointer-leaves` opens a peek and takes the pointer past the panel.
Past it, not merely out of the strip: what uDeck measures a departure against is
the keep-alive region, which is the panel's frame grown by 24 points on every
side and reaching up into the menu bar. The middle of the screen — the lab's
"away from the strip", which is all the opening checks ever needed — is *inside*
the open panel, so the closing checks have a third place of their own
(`panel.past_the_panel()`, left of the panel and below it at once).

`panel.a-click-past-the-panel` is two sentences that have to be checked
together, because each one alone is satisfied by the panel being wrong in the
other direction. It promotes a peek to a held panel with a click on it, takes
the pointer away and watches ten seconds of nothing, and only then clicks
outside. "Nothing happened" is free when nothing is running, and the witness the
control in the middle of the screen uses — uDeck naming the gate that stopped
the gesture — is not available here: that line is written only when the gate
*changes*, and with the panel up and the pointer away nothing changes, so the
log of the quiet stretch is empty by design (measured, four times out of four).
The witness instead is the click that ends it: uDeck answers with `open ->
collapsed`, naming the phase the panel left, and only a uDeck that was running,
that still had the panel open, and that was watching the pointer closely enough
to hear a click can write that line.

What the quiet stretch holds is the rule as the operator meets it, not each of
the two places uDeck keeps it. uDeck states the rule twice — the state machine
refuses `pointerLeft` in a held panel, and the controller does not even time a
departure from one — and on 2026-09-21 breaking either one alone left this check
green, because the other still refused. Both now read one property,
`PanelPhase.isDismissibleByPointer`, so the edit that lets a held panel go
breaks both, and this check goes red on it (`open -> collapsed on pointerLeft`,
.build/e2e/20260921-213029Z). The state machine's own half is held by the Swift
test "once held, the pointer leaving never closes the panel", in
`Tests/UDeckCoreTests/PanelStateTests.swift`.

It also asks which application the click leaves in front. The click lands on
the desktop, which is the Finder's, so the Finder is what the operator chose —
and until 2026-09-21 uDeck pulled the application from before the panel back
over it. So TextEdit is brought forward before the panel is shown, its window
put out of the way, and after the click System Events *inside the guest* is
asked who is in front: the Finder, or the check is red. Without TextEdit there
first, a uDeck that brought back whatever it had would pass, because what it had
was the Finder. The last question is the next gesture, which has to bring back a
peek — on its own only what `PanelState` does after `closeRequested`, and worth
asking beside the next check, where the same held panel interrupted instead has
to come back whole.

`panel.a-switch-with-no-click` is that check. The panel is held, the pointer is
left past it — exactly where a click that dismissed it would have been — and the
Finder is brought forward over SSH with `open -a` and no click at all. The
panel has to close on `otherAppActivated` and come back `open` at the next
gesture. uDeck tells a switch from a click by one reading, how long ago a mouse
button last went down, because the workspace's news of both is the same
notification; a uDeck that read every activation as a click would throw the
operator's unfinished work away on ⌘-Tab, and this is the lab's only check that
sees it. The switch is `open -a` and not an AppleScript activation from inside
the guest, which was measured posting no notification at all.

`panel.a-click-past-a-restored-panel` is the other road a click takes. One click
past the panel reaches uDeck by two roads that race — the workspace saying
another application came forward, and uDeck's own global click monitor — and the
first exists only when the click brings an application forward. So this check
interrupts a held panel the same way, which leaves the Finder in front, shows
the panel again — restored straight to `open`, never clicked — and clicks past
it onto the desktop, the Finder's, already in front. Nothing comes forward, the
monitor is the only messenger, and a uDeck that had lost it never closes the
panel: `panel.a-click-past-the-panel` cannot see that, because there the
workspace's news wins the race. That the monitor really was alone is checked
rather than assumed — if uDeck says the workspace told it anything in the two
seconds after the click, the check says it could not isolate the monitor instead
of passing.

**Both of those came out of the same click meaning two different things on
different days.** Which road wins is decided by whether the click brings an
application forward: measured on 2026-09-21, a click on the desktop brought the
notification 2–32 ms after the button went down, ahead of the monitor, whenever
the Finder was not already in front — after a peek had been clicked into, and
after a panel restored over TextEdit alike — and none at all when it was.
`ApplicationSwitch` in `UDeckCore` now reads the news rather than taking it at
face value, so both roads mean the same dismissal, and these two checks hold
each road down from the outside.

`panel.escape` presses a key, which is the lab's only action with no
coordinates, and asks three things of it: `peek -> collapsed on escape`, that
the panel is still away three seconds later, and that uDeck is alive at the end
of it. What keeps the panel away there is **not** uDeck's `reopenCooldown`.
Escape is pressed with the pointer still in the strip, every collapse tells the
gesture not to fire again until the pointer has left the strip (`idle:
alreadyFiredThisVisit`), and the pointer never leaves it — a build with the
cooldown at zero passed this check (.build/e2e/20260921-202329Z). The cooldown
guards the pointer leaving and coming straight back, which no check in the lab
makes yet. What the watch does catch is the panel coming back at all, which it
has been seen to do: three panels escaped out of `open` came back 158, 208 and
228 ms later (.build/e2e/20260921-133502Z). It counts from the closing line on,
the rest of the read that heard it included.

"It stayed away" is free when nothing is running, and a build that exits the
moment it has handled Escape passed the first version of this check
(.build/e2e/20260921-202146Z): the closing line outlives the process in the
unified log, and the silence after it is exactly what a panel staying shut looks
like. So after the pause uDeck has to still be running and still watching the
pointer — naming the gate that holds the panel shut, which every living uDeck
this check has seen did after the escape. A uDeck that died on Escape fails.

It is pressed at a **peek** rather than at a held panel, and that was measured
rather than assumed: four escapes out of a peek and eight out of a held panel —
with the pointer left at the click, and with it put back in the strip — and all
twelve closed on `escape` and stayed shut, so the choice is not about which one
works. It is about what else is in the log. Every escape out of `open` is
followed by `otherAppActivated ignored in collapsed`, eight times out of eight:
the click that held the panel made uDeck the frontmost application, closing it
gives that up, something else comes forward, and a second messenger arrives with
news of the same event, ignored only because Escape got there first. A check
that has to win a race goes red on a busy machine for a reason that is not
uDeck's. A peek takes the keyboard too, but it never becomes the workspace's
frontmost application — uDeck's own log names another application as in front
when Escape closes it — so nothing changes hands and nothing is announced.

`panel.the-key-after-escape` is the sixth, and it types. A panel that is gone
from the log and from the screen can still be holding the keyboard, and the next
thing the operator does after putting it away is type — so this one opens
TextEdit on an empty document, presses one key into it before anything else
(the control: a keystroke the lab failed to deliver leaves the document exactly
as a uDeck holding on to the keyboard leaves it), opens a peek, presses Escape,
and presses one more key. Then it reads the document. Which application is in
front cannot answer this: with the panel on screen System Events names the
application from before it whatever uDeck has done.

It is a **peek** for the same reason `panel.escape` is, and here it also decides
what is being checked. A peek takes the keyboard without making uDeck the
frontmost application, so since ca3374e the handback restores nothing after one
— and the commit said Escape was unaffected "because uDeck is in front for
those", which is true of a panel that was clicked into and false of a peek.
Measured on 2026-09-22 on both builds: TextEdit held both keys either way, so
the behaviour never changed and only the sentence about it was wrong. There is
nothing to bring back at a peek, because the application that would be brought
back never lost the front. ⌘W was measured the same way, and the same twice
over — through System Events, because a Command chord made over VNC arrives in
this guest as a plain letter, which promotes the peek instead of closing it.

All six act several times with reads in between, so they read the log in steps
(`_Story` in `check_panel.py`): one window opened at the start and never moved —
the guest's clock answers to the second, and a fresh mark between two actions
would sometimes begin inside the answer to the one before — cut by how much has
already been read, which is exact only while the window grows, so a read that
comes back shorter is the lab's failure on the spot. Every step is written to
`story.log` beside the report, labelled, including the steps where uDeck said
nothing, which for a check about a panel that must *not* close is the part a
person needs to see.

An answer that never came is not yet a verdict, and which kind of verdict it
becomes is one rule. **A uDeck that was running and is gone is uDeck failing.**
Every check starts one and waits for it, so a missing process is not an absence
but a uDeck that died in the middle of what was being watched, and the guest
answering the question at all is what makes that safe to read — a machine that
is gone raises before the answer can be mistaken for "nothing is running". That
death was already red on `panel.escape` and "could not check" everywhere else,
so a build that fell over on a click past the panel was reported as the lab
having had a bad day. What stays the lab's: its log holding nothing uDeck said
since the check began, which is a window that never started, and the guest's
clock gone back behind the start of that window, which files everything said
since outside it.

### The panel's keyboard shortcut

Three more, and they are about the other way in: ⌃⌥U, which works with the
cursor nowhere near the top of the screen. It is not a third opening path,
because the panel it leaves is a different panel. The gesture gives a peek — the
glance the cursor being right there has earned — and the shortcut gives one
already promoted to be worked in, because the hand that pressed it is on the
keys and is not going to reach for the mouse to promote a glance
(`PanelController.toggleFromKeyboard`). So uDeck answers it with two lines and
not one, `collapsed -> peek on revealRequested` then `peek -> open on
interacted`, and both of them in that order with nothing else between them are
the verdict (`panel.OPENED_READY_TO_TYPE`). A check that took the first alone
would be green for a shortcut that left the operator a glance.

`panel.the-hotkey` is that check, and it starts uDeck **inside** the window on
its own log — the ordering `panel.middle-of-the-screen` already uses, for a
reason of its own here. What no shortcut check may take for granted is that
uDeck was listening at all: `RegisterEventHotKey` hands a combination to
whoever asked for it first, so it can be refused, and a uDeck that never got the
key is silent for the chord in exactly the way a uDeck that ignores it is. uDeck
says which one it holds — `hotkey ⌃⌥U registered` — and it says it once, at
launch, so a window opened afterwards begins after the only chance to read it.
Measured on 2026-09-23: that line arrived on each of six fresh machines, in the
`panel` category, which is the window the phases come in too.

**How the lab presses it, and why not the way it presses every other key.**
Everything else goes over VNC, where a keystroke arrives at the machine's
keyboard the way one on a real keyboard does. The chord cannot be made that way
in this guest, and trying it is worse than useless: measured on 2026-09-23,
twelve `ctrl-alt-u` presses over VNC produced not one line from a uDeck that was
running and said it held the shortcut, and three screenshots identical to the
byte. On a machine of its own the same chord then *wedged the keyboard* — after
it, neither a plain letter over VNC, nor one through System Events, nor one
after the lone modifiers had been pressed and released reached a document that
had taken a letter moments before. It reads like a modifier left stuck down. It
is the same thing the ⌘W measurement had already seen from the other side, where
a Command chord over VNC arrived as a plain letter.

So the chord is made inside the guest, as a virtual key code with the modifiers
named, through the System Events channel the lab already drives the interface
with (`panel.press_the_chord`). Measured the same day: 9 opens and 9 closes out
of 9 on three fresh machines, with uDeck's line 0.9 to 1.4 s after the command,
the SSH round trip and the `log show` included. The key code is uDeck's own:
32 is "U" in `HotKeyBinding.keyCodes`, an ANSI table that is a fixed
hardware-layout ABI rather than anything derived from the keyboard layout, and
the lab's tests read it back out of that file rather than trusting a number
written down twice.

`panel.the-hotkey-again` presses it a second time, which has to put the panel
away — `open -> collapsed on closeRequested`, once, with nothing reopening in
the same read. And it types, twice, because the panel a shortcut opens is one to
type into and the log cannot answer that twice: uDeck names its first responder
once per process (`loggedResponderTypes.insert`), so that line is an oracle only
on the first machine a check ever runs on. A document can be read as often as
one likes. One key is pressed with the panel open and must **not** reach it —
measured three cycles out of three — and one after the panel is away, which
must. Together they say the shortcut took the keyboard and gave it back.

Not by comparing the whole text, though, and that is a trap the measurement
walked into first: **TextEdit rewrites what is in it.** A document holding "ay"
was read back as "Ay" with no key pressed in between. So each of the three keys
is a letter of its own (`config.WHILE_THE_PANEL_IS_OPEN_KEY`), the one pressed
at the open panel is looked for rather than the text compared, and what is read
at the end is compared without regard to case.

`panel.a-chord-that-is-not-the-hotkey` is the control, and on its own it would
be the emptiest kind of green: a uDeck that registered nothing is silent for
every chord, and the check would be exactly as green over it. So the witness is
in the same check — the real shortcut is pressed after the silence, on the same
machine, and has to open the panel ready to be typed into. That is a uDeck that
was running, holding the combination, and hearing chords made this way, all
three, at the end of the stretch it was supposed to have ignored. The two chords
differ in the key alone, so what is being controlled for is the combination and
not the way the lab presses it. Measured: ⌃⌥J left uDeck's log empty for ten
seconds, made both ways it can be made.

## Reading the result

One line per check, then a summary:

```
✅ updates.sparkle  2m14s
❌ updates.wrong-key  1m02s — Sparkle installed an update signed with the wrong key
   evidence: .build/e2e/20260916-172233/updates.wrong-key/
⚠️ panel.dwell  0m40s — could not check: waiting for SSH after the reboot: no answer in 240s
1 passed, 1 failed, 1 could not check in 3m56s
```

There are three outcomes, and they are kept apart on purpose:

| | means | exit code |
|---|---|---|
| ✅ passed | uDeck did what the check expected | 0 when every check passed |
| ❌ failed | uDeck did not — this is evidence about uDeck | 1 if any check failed |
| ⚠️ could not check | the lab could not carry the check out — a machine that did not boot, SSH that never answered — and says nothing either way about uDeck | 2 otherwise |

A run that checked nothing exits 2, never 0. So does a run where every check
passed but a clone could not be cleaned up.

Each run leaves `.build/e2e/<run>/`, named by its start in UTC: `ledger.jsonl`,
one JSON line per event written as it happens — including every signal the
pre-flight sends, before it sends it — and a directory per check with what it
collected. The last ten runs that checked something are kept, and separately the
last ten the pre-flight refused, so retrying a refused run cannot delete the
evidence of a real one.

Ctrl-C stops the run and still cleans up, and so do closing the terminal and
`kill`: the interrupted check's machine is shut down from inside and deleted
while the lock is held, a verdict the check had already reached stands, anything
unfinished counts as "could not check", and a stopped run never exits 0. A
cleanup that has started is finished before the lab stops — pressing Ctrl-C
again is acknowledged, not obeyed, until the third press, which abandons the
machine.

## Writing a check

A check is a function named `check_<name>` in `checks/check_<group>.py`, and is
called `<group>.<name>` on the command line — `check_wrong_key` in
`check_updates.py` is `updates.wrong-key`.

* Say that uDeck failed with `expect(condition, message)` from
  `udeck_e2e.errors`, or a plain `assert` in the check itself.
* When the lab cannot do something it needs — rather than uDeck getting it
  wrong — raise `LabError(step, reason)`. Any other exception, and any `assert`
  outside a check file, is also treated as the lab failing, never as uDeck
  failing.
* The `check_dir` fixture is the check's own directory in the run's report.
* `machine.screenshot(check_dir, "after the update")` saves the screen there as
  `01-after-the-update.png`, numbered in the order taken. Take one after every
  step that changes what is on screen; they are kept whether the check passes
  or not, and the lab adds `…-at-the-end.png` itself before the machine is shut
  down. A screenshot is evidence for a person, never a verdict.
* `machine.move_pointer(x, y, "to the top edge")` puts the pointer at a pixel;
  `probes.pointer(machine)` reads back where the guest has it.
* Check files live directly in `checks/`, and a file must not skip itself — a
  skipped file would silently drop its whole group. An exception in a thread the
  check started makes the check "could not check".

## The lab's own tests

```sh
UV_PROJECT_ENVIRONMENT="$PWD/.build/e2e/venv" uv run --frozen --project e2e pytest e2e/tests
```

From the repository's root. The path must be absolute: uv reads a relative one
from `e2e/`, and would quietly make a second environment there.

They need neither Tart nor a virtual machine, so they run in CI on every push —
unlike the checks, which need a machine to drive. That is the part worth running
everywhere: a mistake in the harness is invisible, because a check that proves
nothing looks exactly like a check that passed.

## Deliberately not here

**Booting from a snapshot** (`--boot cold|snapshot`, planned as Q49). Tart can
suspend a machine and start it again in about a third of the time, and that was
worth having while a cold boot stood between every check and its work. It no
longer does: `--jobs 2` boots the next check's guest behind the current check,
and in the runs measured on 2026-09-19 no check waited for its machine at all —
the 26–29s boot was entirely hidden. A snapshot would shorten something that is
no longer on the critical path.

What it would cost is not nothing, from reading Tart 2.37.0's own source and
issues: `--suspendable` drops the USB screen-coordinate pointing device and
leaves the trackpad (probably harmless — Apple's header says macOS 13+ guests
use the trackpad anyway, so the lab's 26 and 27 guests already do — but
unmeasured through Virtualization's VNC server); suspended clones share one
machine identity, and `tart set --random-serial` against a suspended clone has
undefined effect; and a VM-limit refusal on a snapshot start *consumes the
snapshot*, because `tart run` deletes `state.vzvmsave` before starting, with an
error whose wording the lab's limit detection does not match. Two machines at
once is exactly when that refusal is most likely.

If a future run finds checks waiting on boots again — many short checks, or a
slower Mac — this is the thing to build, and the pointer question is the first
measurement to take.
