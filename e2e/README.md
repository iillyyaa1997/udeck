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
> of uDeck itself — the update, with its wrong-key control, and the panel's
> hover gesture, with its pointer-in-the-middle control. "Open at Login" and its
> checks follow.

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
and leaves it there. `panel.push` is the other path: upward movement reported
*after* the pointer can move no further. The lab copies a small script into the
guest that posts the arrival and the push in one run, milliseconds apart — the
dwell fires a fraction of a second after the pointer stops, so a pointer placed
from outside and pushed over SSH would open the panel by the wrong path.

**`panel.push` cannot pass inside a virtual machine, and says "could not check"
rather than passing.** Measured on 2026-09-18, fifteen shapes of push on four
machines: a delta posted on a mouse-moved event does not move the pointer (five
events carrying ±30 points at y=400 left it at exactly (1280, 400)), so the
position on the event is what moves it and what applications are told is the
movement that actually happened — which against the top edge is nothing, and
nothing is precisely the signal this path is made of. `IOHIDPostEvent`, which
posts device movement below the window server, is refused even as root
(`kIOReturnNotPrivileged`); unhooking the cursor from the device the way a game
does changes nothing. The check still makes the attempt, because the day a
machine reports real device movement it starts passing — and until then the run
says the lab could not make a push, which is true, instead of passing on the
dwell that opens the panel instead. The push is checked by hand, on a Mac with a
mouse.

`panel.middle-of-the-screen` is their control: the pointer held in the middle of
the screen and pushed at there, where neither the passage of time nor an upward
shove means anything. And because "nothing happened" is free when nothing is
running, the control also requires uDeck to have been watching — its own log
names the gate that stopped the gesture.

What decides all three is uDeck's own record of which path fired — `fired by
dwell on …`, `fired by push on …`. Those are debug messages, which the unified
log keeps nowhere unless it is asked to, so the lab asks the guest to keep this
one subsystem's (`log config`, root, and it dies with the machine) and reads them
back with `log show` from a moment on the guest's own clock. It also checks that
the asking worked: a log nobody is keeping answers every question with silence,
and silence is what a check that proves nothing looks like. The measurement
behind that: `log stream` into a file in the guest delivered the first gesture's
lines and then nothing at all, four gestures in a row, while the kept log held
every one. The same messages carry `idle: <reason>`, which is what makes a
gesture that fired nothing worth reading.

## Reading the result

One line per check, then a summary:

```
✅ updates.sparkle  2m14s
❌ updates.wrong-key  1m02s — Sparkle installed an update signed with the wrong key
   evidence: .build/e2e/20260916-172233/updates.wrong-key/
⚠️ panel.push  0m40s — could not check: waiting for SSH after the reboot: no answer in 240s
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
