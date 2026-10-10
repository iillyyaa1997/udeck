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
> pointer over VNC, a self-check, the builds a check needs, a fake GitHub for
> the plugin catalogue, and fifty-four checks of uDeck itself in five groups
> (`e2e/run.sh --list`). `updates`: the
> update, with its wrong-key control, and when uDeck looks for one at all — by
> itself as it ships, and by itself again once an operator who switched that off
> switches it back on; and a published release updating itself from GitHub, as
> it does on a person's Mac. Every update check takes a pair, "from → to", so
> any version can be tried against any other.
> `panel`: the hover gesture that opens it, with its pointer-in-the-middle
> control and the line between its two paths, the ways of putting it away again,
> and the keyboard shortcut that opens the panel and puts it away — whichever way
> it was opened — with its wrong-chord control and a check that the combination
> dies with uDeck. `login`: "Open at Login", through a restart and an update, and
> switched off. `settings`: two changes made in uDeck's own window, and whether
> they hold across a restart. `plugins`: the twenty-four checks of
> docs/plugin-repository.md — the catalogue, installing, updating, a verified
> plugin updating itself and an update asking for other permissions only
> offered, earlier versions, removing, each refusal, a linked folder, and what Settings offers
> somebody writing a plugin: Link a folder…, the run log's switch, a failed run
> on a fresh card, Install command, Where to look for commands, and all of it
> in Russian — against a fake GitHub in the guest.

## Running it

```sh
e2e/run.sh bake                # once: make the golden image for macOS 27
e2e/run.sh selfcheck           # does the lab work on this Mac?

e2e/run.sh --list              # what checks exist
e2e/run.sh                     # all of them
e2e/run.sh updates             # one group
e2e/run.sh updates.wrong-key   # one check
e2e/run.sh updates.sparkle --from checkout --to latest   # an update check between two others
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

A right click is a click with the other button (`machine.right_click`), which is
how a check opens a context menu; measured on 2026-09-27 it reached uDeck as a
right mouse-down and opened the menu of the tab under it 5 times of 5.

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

An update check needs two real copies of uDeck: one to install and a newer one to
be offered. By default the lab makes both from the checkout it is running in;
with a pair that names a published release (see "Pairs" below) one side, or
both, is that release instead, fetched from GitHub. What the lab makes, it makes
through `Scripts/make-app.sh`, and a lab build differs from a build you would
make by hand in these ways — each of them something a check depends on:

* they go to `.build/e2e/<run>/builds/<check>/<feed>/<version>-<build>/`, never
  `dist/` — a directory per check and per feed (and per key, when the key is a
  published release's), because two checks build the same versions and the
  second must not write over the zips and the build log the first one's report
  is made of;
* they carry the version the lab asked for in both keys, including
  `CFBundleVersion`, which is the one Sparkle compares when it decides whether an
  update is newer;
* they read their plugin catalogue from the fake GitHub the plugin checks serve
  inside the machine (`--test-plugins http://127.0.0.1:8766`), never from
  github.com: uDeck reads the catalogue by itself a few seconds after every
  launch, so this holds for every build, whichever check it is for. A check that
  does not serve the fake leaves nothing listening there, and uDeck reads
  nothing. The lab refuses a build whose `UDeckPluginsAPIBase` or
  `UDeckPluginsRawBase` is anything else, or which lacks
  `NSAllowsLocalNetworking`;
* they stay zips on this Mac. A lab build is the *released* application,
  identifier and all, so an unpacked copy here could take the release's login
  item merely by being launched. It is unpacked inside the machine and nowhere
  else, and the lab reads the bundle's plist out of the zip — in memory — to
  check it got the build it asked for. A bundle that a failed or killed build
  left behind is removed, by the script itself and by the lab after it.

A build is stopped as a whole — the script and the compiler it started share a
process group — so a run that gives up on a build does not leave `swift build`
using the Mac afterwards, and Ctrl-C ends it too.

**A build of this checkout that goes to a published release carries that
release's public key** (`builds.PublicKey`), read out of the release's own
Info.plist, and is numbered below it — 0.4.1 (1). The private half of that key
lives only in GitHub's secrets, so this is the one way a build of the lab's can
accept what the release key signed; nothing is ever signed with it. Every other
rule above holds for it unchanged: its feed is still the lab's own in its plist
(the guest's preferences point it elsewhere, see "Pairs"), its plugin catalogue
still the fake, `NSAllowsLocalNetworking` still there. A build offered *to* a
release keeps 0.4.2 and is numbered one above it.

**A published release is not a lab build.** Its zip never goes through
`Scripts/make-app.sh` or `Builder._verify`, whose rules every release breaks —
the real feed, the real plugin catalogue, no `NSAllowsLocalNetworking` — and
those rules are not loosened for it. The lab
fetches the zip and the appcast from the release's assets into
`.build/e2e/releases/<tag>/` (never `dist/`), and checks them against each other
before anything uses them: the length the appcast gives, both version keys, the
bundle identifier, and `sparkle:edSignature` over the zip under the
`SUPublicEDKey` the zip's own Info.plist carries — the check Sparkle makes, made
with the standard library (`udeck_e2e/ed25519.py`, RFC 8032's reference code,
held to the RFC's test vectors by the lab's tests). Of the release a check is
offered, also where the appcast sends uDeck for the zip: the zip GitHub's API
lists for that release. A copy that
still checks — and is still the size and the SHA-256 `digest` GitHub's API lists
for the asset, so that an asset published again under the same tag is fetched
again (by the digest: every release's appcast so far is 932 bytes) — is used
again; one that does not is fetched again, a fresh download that is not what the
API lists is "could not check", and a release that still does not check is not
run: as "from" that check could not check, as
"to" it has failed (see "What it is red for" under "The update by a published
release"). Like a lab build it stays a zip on this Mac, read in memory, unpacked
only inside a guest.

An update the lab serves is signed with a key made for the run and deleted with
it. Sparkle's own `generate_keys` would leave a private key in your login
keychain; the lab generates the key itself and hands `sign_update` a file
holding the base64 of the 32-byte seed (measured: that is the form it reads, and
its signatures verify against the public key baked into the bundle).

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
has to show that uDeck *tried*: the guest's own access log has to name the
archive — Sparkle checks the signature after downloading it. What the pane says
("The check did not finish") is kept as evidence and decides nothing: uDeck
prints it for any trouble its updater runs into, including never reaching the
archive. No archive in the log, and the run says so rather than passing.

With a published release as "from" (`updates.wrong-key --from 0.5.0`) the control
gets a real one: the release trusts only the release key, so the offer is a build
of this checkout — 0.4.2, numbered one above the release — signed with the run's
own key, served from the guest's loopback as always, and the release is pointed
at that feed through the guest's preferences (see "Pairs"). The witness is the
same: the guest's own server names the archive, or the control does not pass.
Measured on 2026-10-09, green: the released 0.5.0, whose Info.plist carries no
`NSAllowsLocalNetworking` at all, asked the lab's plain-HTTP feed on 127.0.0.1
and fetched the archive from it — the guest's log reads `"GET /uDeck-0.4.2.zip
HTTP/1.1" 200` — refused it ("The update is improperly signed and could not be
validated"), and was still 0.5.0 (6), the same process, 90 s later
(`.build/e2e/20261009-040538Z`), and the same again after the first round of
fixes to the pairs (`-063109Z`: `"GET /uDeck-0.4.2.zip HTTP/1.1" 200`, the pane
saying the update is improperly signed, 0.5.0 still installed); not run again on
the code as it is now. Both kept in `.build/e2e/kept/`.

### Pairs

Every update check runs between two copies of uDeck, "from → to", and the
command line can choose them with `--from` and `--to`: each is `checkout` (a
build of this checkout), `latest` (the release GitHub marks latest) or a
published release by its version (`0.5.0`). An end that is not given is the
check's own default:

| check | by default | can also take |
|---|---|---|
| `updates.sparkle` | checkout → checkout | any pair but a release → checkout |
| `updates.wrong-key` | checkout → checkout | a release → checkout |
| `updates.it-looks-by-itself`, `updates.switched-on-it-looks-by-itself` | checkout → checkout | nothing else |
| `updates.a-published-release` | the release before latest → latest | any pair whose "to" is a release |

So a run without arguments asks the first four what they asked before pairs
existed, and the fifth its own question — with one change: `updates.sparkle` and
`updates.wrong-key` now start, as the two checks about looking by itself always
did, from a machine that remembers none of uDeck's preferences, because a
neighbouring check with a pair may have written a `SUFeedURL` there. On a fresh
machine (`--vm per-check`, the default) there is nothing to forget, so the
question is the same; under `--vm per-group` or `per-run` whatever an earlier
check left is taken away first and said in the report. `e2e/run.sh --list`
prints each check's default beside its name. Measured on 2026-10-09, `e2e/run.sh
updates` after the second round of fixes to the pairs: all five green in 14m15s
(`.build/e2e/20261009-152607Z`); the group has not run since, on the code as it
is now — only `updates.a-published-release` has (see "The update by a published
release"). Earlier the same day, after the first round, all five green in 11m31s
(`-060923Z`); before any, all five green (`-041950Z`), and once with
`updates.sparkle` "could not check" — the guest stopped answering SSH while its
feed was being served — and green on its own straight after (`-050034Z`,
`-052057Z`). All kept in `.build/e2e/kept/`.

```sh
e2e/run.sh updates.a-published-release                       # 0.5.0 → 0.6.1 today
e2e/run.sh updates.a-published-release --from checkout --to 0.5.0
e2e/run.sh updates.wrong-key --from 0.5.0                     # the control, with a real "from"
e2e/run.sh updates.sparkle --from checkout --to latest
```

**A pair that cannot be run is refused before anything starts**, with the
reason, and the run checks nothing:

* a release going to a build of this checkout it would install: a release
  installs only what the release key signed, and its private half lives in
  GitHub's secrets. A release offered a build signed with the lab's key is the
  wrong-key control with a real "from", and that is what it is for;
* a pair given on the command line whose "to" is not newer than its "from" by
  `CFBundleVersion`, the number Sparkle compares (`--from 0.6.1 --to 0.5.0`,
  `--from latest --to latest`, `--from 0.5.0` with latest numbered no higher
  than 0.5.0): an update there is none of. The lab's own pair is the exception
  (below);
* a pair a check cannot ask its question about: the wrong-key control offered a
  published release — signed with the right key, and fetched from GitHub, where
  the guest's own server, the control's witness, never sees it; anything but
  checkout → checkout for the two checks about looking by itself, which end at
  a request to the lab's own feed and install nothing; and a "to" of this
  checkout for `updates.a-published-release`, which is `updates.sparkle`'s;
* a "from" release whose settings window the lab cannot drive (below);
* a release offered `latest` that does not itself ship the latest feed as its
  `SUFeedURL`: it is asked through the feed it ships with, untouched, so the
  pair would not prove the latest redirect;
* `--from` or `--to` beside a check that takes no pair, or beside `--list`; a
  side that is not one (`v0.5.0`, `0.5`); a release nobody published — the
  error lists what is published, and says so when the version is a tag without
  a release, as v0.6.0 is.

Which releases exist is what GitHub's public API says, drafts, pre-releases and
anything without both an `appcast.xml` and a `uDeck-X.Y.Z.zip` left out, and
"latest" is GitHub's own mark, not the highest number. It is asked without a
token — two questions a run from this Mac, of the sixty an hour GitHub allows one
address — and a used-up limit says until when. Those two are not all that address
asks: the 0.6.1 a check installs reads the plugin catalogue from api.github.com by
itself when it starts, from the guest through Tart's NAT, so most likely from the
same public address. How many questions that adds is not measured. A pair given on the command line that cannot be
resolved, GitHub not answering this Mac included, refuses the run; a check's own
default that cannot be resolved — GitHub not answering, a download cut short, an
API answer the lab cannot read — is that check's "could not check", with the
reason, and costs no machine: none is made for it, and with `--jobs 2` none is
started ahead for it either. That holds under every `--vm`: the check stops
before pytest sets up any of its fixtures, the machine its group or its run
shares among them, so a check that cannot run neither boots the shared machine
nor takes it, and a shared machine is never kept by `--keep-on-failure` for a
check that never used it. The rest of the run goes on.

A "to" that GitHub publishes **broken** is neither: it is that check's failure,
given or not (see "What it is red for" below). A pair given on the command line
whose "to" is not newer than "from" is refused before any verdict, broken "to"
or whole, and a defect found in that "to" is said with the refusal: by the
CFBundleVersion "to"'s appcast offers, where that much could be read — the
appcast fetched whole, its zip there or not — as for a "to" that holds
together; otherwise by version, and a build of this checkout, numbered 1, has no
update to the first release GitHub publishes. A "from" that does not hold
together is "could not check" — the lab does not install what it cannot vouch
for.

**The lab's own pair is asked the other way round.** The release before latest →
latest — what a run asks with nothing given, and with `--to latest` alone, since
nobody types the release before latest — asks whether what GitHub publishes as
latest is an update to the release before it. A latest that is not newer than
the release before it by `CFBundleVersion` is GitHub's publishing being wrong:
every uDeck on the release before latest would say it is up to date. So it is
that check's failure, before any machine, whatever else is broken in latest —
latest's number read from its appcast where it does not hold together, since
the appcast's number is the one Sparkle compares, and its defects said in the
same line. The release before latest is compared only when it holds together:
Sparkle compares with the installed bundle's own number, the one in its zip,
and a release whose zip and appcast do not hold together does not vouch for
it. Then a latest broken on its own. Only then what the lab cannot do: a release before latest it cannot
vouch for, cannot press its way to an update in, or that does not ship the
latest feed, is "could not check". Both releases are fetched before the lab asks
whether it can drive the one before latest, since the finding needs no window
driven.

**Which releases can be "from" is read from each release's own source**, at its
tag in this checkout. Once the settings window is open, the lab presses its way
to an update by the identifiers uDeck gives the controls — `section.about`,
`updates.checkNow`, `updates.install` (`releases.CHECK_NOW_PATH`) — never by
translated titles, and a release whose source names none of them has a window
the lab cannot drive. The way into that window is the exception every check
shares: uDeck's menu item, which carries no identifier, is found by its English
title `Settings…` and the window by `uDeck Settings` (see "The one thing the lab
trusts a translated name for is the way in" under "The settings the operator
changed"). A release's source is not read for those two titles; a release that
changed them would be "could not check" — no way in — rather than refused.
`section.about` counts when it is spelled out, or when — as every release so far
writes it — the sidebar's `section.\(item)` and an enum of rows with `case about`
are in the same file; `section.\(item)` alone names whatever rows there are.
Read on 2026-10-09: 0.5.0 and 0.6.1 name all three; 0.1.0, 0.2.1, 0.3.0 and 0.4.0
name none — their About pane has a "Check now" button, with no identifier on it
or on the sidebar's rows. So "from" can be 0.5.0 or newer, and its tag has to be
in the checkout (`git fetch --tags`, which the refusal says). "to" needs no
window driven, so it can be any published release newer than "from" — for a
build of this checkout, numbered 0.4.1 (1), that is every release but the first:
`--from checkout --to 0.4.0` works as well as `--to 0.5.0`.

**How "to" reaches "from".** Sparkle reads `SUFeedURL` from uDeck's preferences
before its Info.plist (`-[SUHost objectForKey:ofClass:]` in Sparkle 2.9.6, and
uDeck gives it no `feedURLStringForUpdater:` that would come first), so the lab
writes it there — in the guest, never on this Mac — whenever "to" is not where
"from"'s own plist points: a release offered a build of this checkout (the lab's
feed on the guest's loopback), a build of this checkout offered the latest
release (the real feed), anything offered a release by its version (that
release's own `appcast.xml` asset). A release offered `latest` asks the feed it
ships with, untouched — which is what proves the latest redirect. The write
comes after the machine has forgotten what it remembered, and is read back. With
`SUEnableAutomaticChecks` below, it is one of the two preferences the lab ever
writes.

**Which pair a check ran with cannot be missed.** Resolved — both ends down to
version and build, the release whose public key a build of this checkout
carries when it carries one, what a build of this checkout that is offered is
signed with (the control's: another key, made for the check), and how "to"
reaches "from"; for the two checks about looking by itself, that nothing is
offered at all — it is said before the checks start, under each check's line in
the report, and in the ledger: a `pairs` event with each release's tag, zip,
SHA-256 and public key, and which public key each build of this checkout
carries — the run's own, when the line names none — and a `pair` in every
`check` event.

```
✅ updates.a-published-release  3m41s
   pair: release 0.5.0 (6), the release before latest → release 0.6.1 (8), latest, via the real feed (default: the release before latest → latest)
```

### The update by a published release

`updates.sparkle` and its control serve their own feed and sign with their own
key, so neither can say whether the release key's private half — only in
GitHub's secrets — signs what the `SUPublicEDKey` baked into released bundles
accepts, nor whether Sparkle's real way works: the latest redirect, the download
from GitHub's asset host, the install and the relaunch.

`updates.a-published-release` is that way, driven exactly like
`updates.sparkle` — the two share every step — and by default from the release
before latest to latest: today 0.5.0 (6) to 0.6.1 (8). The release's zip,
fetched and checked on this Mac, is unpacked in the guest and started; Settings
→ About → "Check now" is pressed with the machine's pointer, since 0.5.0 ships
with automatic checks off; the offer of "to" appears and is installed. What
counts is the bundle on the guest's disk — `CFBundleShortVersionString` and
`CFBundleVersion` as "to"'s own zip carries them — and a new process that stays,
with a screenshot of the offer and one of the new uDeck's About pane: never
uDeck's log, never what the pane says.

**On the default pairs it is the one check that talks to github.com** — that
is what it checks — from inside the guest, through Tart's own network: the
appcast through the latest redirect, and the archive from GitHub's asset host. The 0.6.1 it installs also reads the real
plugin catalogue from api.github.com when it starts, as it ships — harmless, and
nothing the verdict reads. `updates.sparkle` given a published release as "to"
talks to GitHub from the guest the same way. A release only as "from"
(`updates.wrong-key --from 0.5.0`) is fetched by this Mac alone: the guest is
offered the lab's own build on its loopback, and talks to GitHub only if the
release it starts reads the plugin catalogue itself (0.6.1 and later do; 0.5.0
does not).

**No network from the guest is "could not check", never red.** Before uDeck is
started the guest itself asks for exactly what the check needs, with its own
curl, following redirects as Sparkle does (`updates.github_answers`): the feed
"from" will ask, whose item for the zip has to offer the build, the address and
the signature the lab checked on this Mac (the rest of the appcast is not
compared), and the first bytes of the archive at that address. Measured from the
guest on 2026-10-09, the latest feed is two redirects from github.com and the
archive one, both landing on release-assets.githubusercontent.com. Before the
check says anything against uDeck the guest is asked again. curl getting no
answer at all — no name, no route, no answer in time — is the lab's, with curl's
words, and so is GitHub answering with trouble of its own — 403, 429, a 5xx —
which is the network at the level of HTTP: "could not check", with what GitHub
answered. Only GitHub saying an asset is not there (404, 410) is what every
uDeck that looks would meet too, so it is noted, left for the verdict, and named
in the red line; the line never says the feed "still answers" unless it did.
This Mac holds GitHub to the same rule while it fetches a release
(`releases.ASSET_MISSING`): a 404 or 410 for an asset GitHub's API lists is the
release's — red before any machine when it is "to", "could not check" when it is
"from" — and 403, 429 or a 5xx is "could not check" on either side.

**What it is red for.** On this Mac, before any machine is made, from what
GitHub serves (`releases.ReleaseDefect`, `pairs.PairDefect`): a "to" whose
appcast's `edSignature` does not hold over its zip under the `SUPublicEDKey`
that very zip carries — the release key's private half no longer the key
released bundles carry; a zip and an appcast that disagree on length, version or
bundle; an appcast that is not XML, has no item for the zip, or whose item lacks
a version, a length or an `edSignature`; an item that sends uDeck anywhere but
the zip GitHub's API lists for that release (`browser_download_url`: another
host, another port, another repository or tag, plain http, a relative address,
the release's own address tucked into another's query — measured on 2026-10-09,
every published release's enclosure is exactly that address); a zip whose
Info.plist cannot be read (malformed XML included); a latest without its appcast
or its zip, which the real feed leads every uDeck to; GitHub answering 404 or
410 for an asset its own API lists; and, in the lab's own pair, a latest not
newer than the release before it (see "The lab's own pair is asked the other way
round" under "Pairs"). The address is read as Sparkle reads it only where that
leaves no doubt: the scheme and the host in any case, and https's port 443
written or not, are the same address (RFC 3986, 6.2.2.1 and 6.2.3; Sparkle 2.9.6
takes the scheme in any case). Everything else is compared exactly, so an
address Sparkle might still resolve to the same asset — a relative one, a path
with `..` in it — is red too. The line is red with the reason,
the pair line says `not run` and what was wrong, and the ledger's `pairs` event
carries the `defect`. Where the defect is in the two assets as GitHub served
them, both fetched whole, the reason ends with where GitHub's copies stay —
`.build/e2e/releases/<tag>/`; a 404 or 410 and a latest without an asset leave
no such pair of copies. The same of a "from" is "could not check", except where
its appcast sends uDeck: nothing reads that of a release the lab only installs —
it installs "from"'s zip itself, and Sparkle downloads "to" — so it is not
asked. A guest would make none of it less true, and a flaky guest would only
turn it into "could not check", so none is booted — under any `--vm`: the check
stops before pytest sets up the machine its group or its run shares. Held by the
lab's own tests against a GitHub made of answers, for each `--vm` mode with the
machine it would have had set to fail its boot; no published release has been
broken, so no run has met it.

In the guest: "from" not taking "to" — the disk keeps "from", and the red line
carries what GitHub answered the guest just before and what the pane said, so a
refused signature and a failed download read apart; uDeck saying it is up to
date or that the check did not finish while its feed declares "to"; and
everything `updates.sparkle` is red for — another version on disk, no new
process, one that dies, an old copy left running.

What the guest's own probe cannot tell apart: GitHub in trouble *during* uDeck's
own fetch — a 5xx, a reset — that has healed by the time the guest asks again
before the verdict. The probe then says GitHub answers, and the check is red
("did not finish", or the disk keeping "from"). The red line carries what GitHub
answered and the pane's words, so a red with a fine probe and a pane naming a
network error reads as one; running it again is the answer. Not retried by the
lab.

Measured on 2026-10-09, green: 0.5.0 (6) to 0.6.1 (8) through the real feed in
1m34s, the guest reaching the feed in two redirects and the archive in one, and
uDeck back as 0.6.1 (8), automatic checks on as it ships
(`.build/e2e/20261009-040328Z`). Two attempts before it could not check — the
clone's guest agent never answered within 180 s, while another application's
virtual machine was running on the Mac (`-034551Z`, `-035233Z`) — and the
self-check between them passed (`-035704Z`); nothing about uDeck was asked in
either. From a build of this checkout carrying the release's key, green too: to
0.5.0 through its own appcast, `--from checkout --to 0.5.0`, in 3m25s
(`-041358Z`), and `updates.sparkle --from checkout --to latest` to 0.6.1 in
2m01s (`-041734Z`).

After the first round of fixes, all green: the default pair in the group run, in
1m24s (`-060923Z`); `--from checkout --to 0.5.0` in 1m48s (`-062104Z`);
`--from checkout --to 0.4.0` in 7m44s with the build (`-062308Z`) — 0.4.0 (5)
on the disk and a new process that stayed, carrying the same `SUPublicEDKey` as
0.5.0 and 0.6.1, and no picture of its About pane, because 0.4.0's window has
no identifiers to open it by (said in the report, verdict unchanged); and
`updates.sparkle --from checkout --to latest` in 1m31s (`-063359Z`). Of these,
only the default pair has run again since: after the second round, alone, green
in 1m22s (`-152204Z`) — the copies of 0.5.0 and 0.6.1 kept on this Mac matched
the size and SHA-256 GitHub's API lists — and in the group run in 1m39s
(`-152607Z`); after the third round, with each appcast held to the zip GitHub's
API lists byte for byte, alone, green in 2m21s (`-170702Z`), on that round's
code except `releases.py`, edited 33 s after the run had started — a comment,
its author said; no copy of the file before the edit was kept to compare.

After the fourth round — the lab's own pair red for a latest not newer than the
release before it, the address compared as Sparkle reads one and asked only of
the release offered — alone, green in 1m33s (`-175401Z`, the run 1m36s, exit 0).
On the code as it is now — that, and a release before latest that does not hold
together never compared by its appcast's number — alone, green in 4m50s
(`-182211Z`, exit 0; the code's SHA-256 the same before and after the run): the
kept copies of 0.5.0 and 0.6.1 still checked, the guest reached the latest feed
in two redirects and the archive in one, both at
release-assets.githubusercontent.com, offering 0.6.1 (8), and uDeck came back as
0.6.1 (8) in a new process. Its screenshots show the offer — installed 0.5.0,
latest 0.6.1, "Update to 0.6.1" — and 0.6.1 installed, automatic checks on,
"Checked just now". The red of the lab's own pair has met
no published release — their numbers rise, 1, 3, 4, 5, 6 and 8 from 0.1.0 to
0.6.1, read from their appcasts on 2026-10-09 — and is held by the lab's own
tests.

And no machine for a "to" published broken, under `--vm per-run` and
`per-group` alike, measured after the second round with the real lab and a
defect injected for the occasion — a `sitecustomize.py` outside the repository, never committed, that
makes the fetch of 0.6.1 say it does not hold together, in words that say they
were injected. `updates.a-published-release` was red in 0s each time, the whole
run over in 3 s and 2 s, and its run directory holds the ledger, the reason and
the lab's start mark, and nothing else: no clone, no screenshot (`-154047Z`,
`-154057Z`).

And red where it should be, measured once against a copy of the check file —
never committed — in which a build of this checkout going to a release carries
the run's own key instead of the release's: the shape of a "from" that carries a
key the release was not signed with. The pane then read "The update is
improperly signed and could not be validated" — that Sparkle fetched 0.6.1 for
it is inferred from those words; nothing in the guest witnessed the download —
the disk kept 0.4.1 (1), the guest still reached GitHub when it was asked before
the verdict, and the check said `the version on disk is ('0.4.1', '1'), not
('0.6.1', '8')` (`-044950Z`). Its first run could not check: the guest stopped
answering SSH while the version was being read (`-043920Z`). A release published
broken is a different shape, found on this Mac before any machine (above). All
of the runs named here are kept in `.build/e2e/kept/`.

### Not in the full run

**The control with a published release as "from".** A run gives each check one
pair — its default, or the one `--from` and `--to` give — and
`updates.wrong-key`'s default is checkout → checkout: the same offer signed with
another key, refused. So a run without arguments holds the control between two
builds of this checkout, and the control with a published release as "from" is
the same check with another pair, which runs only when it is named with a
release as `--from`:

```
e2e/run.sh updates.wrong-key --from 0.5.0
```

So a full run's green `updates.a-published-release` does not come with a control
of its own release, and when the default "from" moves on — to 0.6.1 at the next
release — nothing re-checks by itself that the new "from" refuses an offer
signed with another key; that is the command above with the new version.
Whether the full run should hold it too is not settled.

### Looking for an update by itself

uDeck ships with automatic checks **on** — `SUEnableAutomaticChecks` is true
in `Sources/uDeck/Support/Info.plist`, the operator's decision recorded in
`docs/plugin-repository.md` ("What uDeck fetches, and when") and said in the
README: once a day uDeck asks its feed for a newer version, the first time
straight after its first launch. Until the plugin catalogue came it shipped with
them off, and the first of these checks held it to the opposite.

`updates.it-looks-by-itself` starts uDeck as it ships, on a machine that
remembers nothing about updates, presses nothing and opens nothing, and listens
to the feed: uDeck must ask it within 20 s. Nothing is pressed so that the
request cannot be "Check now"'s, and no window is opened so that it cannot be
one a window caused. The feed is the lab's, on the guest's loopback — a lab
build whose `SUFeedURL` is anything else is refused when it is built
(`Builder._verify`) — so a request heard there is one that did not go to
github.com, and a build left pointing at the real feed is red here. When the
feed hears nothing, it is asked whether it still answers before that silence is
uDeck's.

`updates.switched-on-it-looks-by-itself` needs a switch to turn on, so it starts
from a machine whose operator turned it off: after forgetting everything, the
lab writes `SUEnableAutomaticChecks` false into uDeck's preferences — what the
switch's setter writes, and one of the two preferences the lab ever writes (the
other is `SUFeedURL`, for a pair; see "Pairs") — and reads it back before uDeck
starts. Turning it off in the window instead would first
cost a check, and that check's date would keep the switch from causing another
for a day. uDeck must then stay quiet until the switch is touched (a request
before it is uDeck ignoring the operator's off, and a failure), the switch must
read off (reading on, the pane is not showing what uDeck does), and after the
switch is turned on with the pointer, with nothing else pressed, the feed must
hear uDeck within 15 s and Sparkle's own setting in the guest must read on — a
switch that makes one check instead of turning checking on brings the very same
request. When the feed hears nothing, two things are asked before that is
uDeck's: the switch is read back — still off is a click that missed, and the
lab's — and the feed is asked whether it still answers, because a feed that
died hears nobody.

**What the first is red for**: `SUEnableAutomaticChecks` false in the plist, as
uDeck shipped before — the feed hears nothing for the whole 20 s. The lab's own
tests drive that shape (`test_a_uDeck_that_ships_with_automatic_checks_off_fails`),
and the whole check, run against such a build on 2026-09-28, failed after
listening 22 s (`.build/e2e/20260928-212410Z`); against the plist as it ships
it passed, the feed hearing uDeck 2 and 9 s after it started
(`20260928-205437Z`, `20260928-211113Z`). All three are kept in `.build/e2e/kept/`.

**What each was red for before**, when uDeck shipped with automatic checks off
and the first check was `updates.it-does-not-look-by-itself`, which required
the feed to hear nothing until "Check now" was pressed. Each was measured on
2026-09-26 by breaking uDeck and running the check. `SUEnableAutomaticChecks` switched to true in the plist:
`it-does-not-look-by-itself` failed — the feed heard uDeck at 21:06:01, and the
check said so within 10 s of starting it — and `switched-on-it-looks-by-itself`
could not check, because the switch already read on
(`.build/e2e/20260926-210440Z`). `checksAutomatically`'s setter emptied in
`SparkleUpdater`, and separately the About pane's toggle no longer passing its
value to the updater: `switched-on-it-looks-by-itself` failed both times, with
the switch reading on and the feed hearing nothing (`20260926-210840Z`,
`20260926-211106Z`). And "Check now" no longer calling Sparkle: the quiet check
said *could not check*, because a uDeck that asks nothing when asked makes the
quiet before it worthless (`20260926-211336Z`).

And three more on 2026-09-27, for what the first versions let through. A uDeck
that looks when its settings window appears — `updater?.checkNow()` in
`SettingsView`'s `onAppear` — and one that looks when the About pane appears:
`it-does-not-look-by-itself` failed on both, the feed having heard uDeck 30 and
32 s after launch with the window open (`20260927-134954Z`, `-135200Z`). A
switch whose setter asks for one check instead of turning checking on
(`updater.checkNow()` in the About pane's binding): `switched-on-it-looks-by-itself`
failed, the feed having heard uDeck within the second and Sparkle keeping no
`SUEnableAutomaticChecks` at all (`20260927-135358Z`). On the build as it shipped
then the same read says `1` straight after the request, and a restart then asks the
feed nothing for 30 s, because the last check is a second old — which is why the
setting is read rather than proved by a restart (`20260927-132223Z`,
`probe.switch-then-restart`). And the two check files as they were before, run
against the first and the third of these, were green on both
(`20260927-141653Z`, `-141823Z`) — which is what the new sentences are for. All
of these runs are in `.build/e2e/kept/`.

**The oracle is the feed's log, not uDeck's.** The guest's `http.server` writes
one line per request, and nothing else on the machine knows the feed's address.
The lab asks the same server whether it is up, so its own requests carry
`?asked-by=the-lab` (`http.server` drops the query when it picks the file) and
are left out. uDeck's own log is no witness: measured, the 400 lines around
the switch's request hold nothing from Sparkle — only CFNetwork and the network
stack opening a connection to port 8765 over `lo0`, and an ATS warning about
plain HTTP — so a check reading it would be reading the network stack's diary.

**Why seconds are enough**, measured on 2026-09-26 with a throwaway check file
that is not kept (`.build/e2e/20260926-203904Z`, and the run itself has since
been rotated out without a copy, so the numbers in this list stand as they were
written), and read against the source of Sparkle 2.9.6, the version
`Package.resolved` pins:

* With automatic checks off, Sparkle schedules nothing at all
  (`scheduleNextUpdateCheckFiringImmediately:` returns). uDeck as it shipped
  then, with them off, was started and listened to for 255 s, and the feed
  heard nothing.
* With them on, a uDeck that has never looked is overdue: with no
  `SULastCheckTime`, Sparkle counts from `distantPast` and looks at once. Forced
  on in the guest's preferences, six launches asked the feed between 1.3 and
  2.9 s after `open -a` — which is what a build shipping with the switch on
  does, and why 20 s of listening is enough to hear it.
* Turning the switch on posts a settings change, and Sparkle resets its cycle
  after one second (`resetUpdateCycleAfterDelay`). The guest's clock read
  20:45:30.09 just before the click, and the feed logged uDeck at 20:45:31.
* "Check now" reached the feed 3.3–4.3 s after the lab started looking for the
  button, the walk that finds it included.

**Both checks start from a machine that remembers nothing**
(`app.forget_preferences`) — the switch's check then writes its one key. Sparkle reads `SUEnableAutomaticChecks`,
`SULastCheckTime` and `SUScheduledCheckInterval` from the preferences before the
plist, and the remembered date matters most: measured, the switch turned off and
on again three minutes after a check caused no request in the minute after the
click, because the next check was then a day away. So on a shared machine
(`--vm per-group`, `per-run`) the check before would have silenced this one —
and it does leave that date behind: with `--vm per-group`, both checks found
`SULastCheckTime` from the check before them and took it away, and both passed
(`.build/e2e/20260926-224017Z`). Right after the delete, `defaults read` answers
with an empty dictionary rather than "not found", and the lab reads both as
nothing kept.

**What cannot be checked in a lab run is the next check a day later.** It is
`SUScheduledCheckInterval` — 86400 s in the plist — after the last one, and
Sparkle will not go below an hour: `minimumUpdateCheckInterval` returns 3600 in
a release build (the one-minute interval exists only in Sparkle's own debug
builds, behind `_SUEnableDebugUpdateCheckIntervals`). Measured, not only read:
with `SUScheduledCheckInterval` set to 60 in the guest's preferences, a uDeck
whose last check was at 20:49:14 said nothing to the feed up to 20:53:47, and
one whose last check was at 19:53:58 asked at 20:53:59 — an hour, not a minute.
So a scheduled check cannot be had in less than an hour of waiting, and the lab
does not wait an hour.

The honest way to check it would be to move `SULastCheckTime` back rather than
wait: Sparkle counts from that date, and its own timer does the rest. Measured
the same way, a last check written as 2026-09-25 20:54:09 and uDeck started at
20:54:01 the next day made the feed hear it at 20:54:09 — exactly the plist's
day after, 8 s after launch. It changes a date and not a setting, but it does
write into Sparkle's memory, and no check does it today.

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

### Upward movement short of the edge

Two more, and they are about the line between the dwell and the push, which
none of the three above draws. uDeck counts upward movement as a push only while
the pointer is pinned, and was pinned before it
(`HoverGestureRecognizer.updatePushWindow`) — and the strip is taller than the
pinned rows. Rows 0 to 6 are in it and rows 0 to 3 are pinned, so a pointer on
rows 4, 5 or 6 can move up inside the strip and still not be against anything.
`panel.dwell` moves nothing once it has placed the pointer, `panel.push` moves up
only against the edge, and the control moves up far from the strip.

**The first attempt placed the pointer on row 5 and moved it up from there, and
it measured nothing.** A pointer placed in the strip over VNC opens the panel by
the dwell before any command reaches the guest: 14 placements out of 14 on
2026-09-26, the dwell 24 to 127 ms before push-pointer.py had even started —
eight with a nudge of one row after it, six with a throw to the edge and a push
there (.build/e2e/20260926-185410Z). Whatever the movement then was, it met a
panel that was already open. And a pointer that only goes up from row 5 is
pinned after two rows, so upward travel short of pinned that adds up to anything
has to come back down between the ups.

So `panel.a-wobble-short-of-the-edge` slides the pointer along the strip from
left of it, rocking between rows 4 and 6 — up two rows, down two, two pixels to
the right each time, a hundred reports with a 2 ms pause after each (0.31 to
0.33 s for the hundred, with the pointer read back after every one, in the four
wobbles of `.build/e2e/20260927-140526Z` and `-141957Z`), all of it one run of
push-pointer.py inside the guest. The slide is what keeps the dwell away while it happens: uDeck restarts
the dwell whenever the pointer slides, so the push path
gets the whole wobble to be wrong about. When the pointer stops, at rest in the
strip, the dwell fires, and that is the verdict *and* the witness: `fired by
dwell` is uDeck saying it saw the pointer in the strip, saw it stop, and never
took the rocking for a push — which the control in the middle of the screen has
to go looking for separately. `panel.the-same-wobble-at-the-edge` is its pair:
the same rocking four rows higher, between rows 0 and 2, every row of it pinned,
and there it has to be the push. One movement in two places, and the only thing
that differs is the one the guard is about. Without the pair, "not a push" would
be as true of a rocking whose ups never reached uDeck.

The lab reads back where the pointer went after every report, and three things
about that path decide whether there is a verdict at all (`panel.Wobble`). It
stayed between its two rows; it came to rest inside the strip; and, before "not
a push" may count, it made enough upward travel inside the strip within one of
uDeck's push windows that a uDeck counting it would have had to fire — twice
uDeck's 24 points, because uDeck may read this movement at half a point per
unit. That last one is **why the pace is what it is.** uDeck reads upward
movement as `NSEvent.deltaY` times a scale it learns from free movement
(`PointerDeltaCalibration`), and in this guest the lab's own moves teach it
anything from one point per unit down to half: a VNC jump of 718 rows came back
as a deltaY of 717 once and 1434 or 1436 another time, and every 60-pixel report
of the throw as 120, while the rocking's 2-pixel reports come back as 2. At the
first pace tried, 3 pixels sideways every 5 ms, the rocking at the edge opened
the panel by the push six times of six on one machine and then 2 times of 6,
twice, on others (.build/e2e/20260926-185410Z, -191139Z, -191601Z); a build that
logged every movement it heard is where the numbers above come from
(-192056Z, -192517Z, never committed). At the throw's own pace, six times in
each place on a machine of its own: the dwell six times of six between rows 4
and 6, and the push six times of six between rows 0 and 2 (-192908Z).

None of the runs named so far in this section is on this Mac any more — they
were rotated out before anything copied them — so what they measured stands as
written and cannot be checked again. What can be is what every run of the two
checks writes into its ledger (`Wobble.summary`). In the runs of a build as it
ships kept in `.build/e2e/kept/` — `20260926-211629Z`, `-220316Z`, `-225415Z`,
`20260927-140526Z` and `-141957Z` — the upward travel inside the strip within
one window was 76, 78, 76, 82 and 82 points short of the edge, against the 48
asked of it, and 52, 62, 60, 68 and 58 at it, with the dwell and the push every
time.

The travel is asked only of a wobble that was not taken for a push. Once the
push opens the panel the pointer does not always keep following the reports — in
three of six trials uDeck heard nothing for 0.12 to 0.22 s after the panel
opened while the script was still posting (-192517Z, gone like the rest) — so at
the edge the track read back holds less, 52 to 68 points against 76 to 82 short
of it in the runs kept, and a check that asked first could call a working push
"could not check". A push short of the edge is wrong however little the track
says it carried.

Measured against broken builds of uDeck on 2026-09-26, one run each, the two
checks and the three opening checks:

| uDeck built with | wobble short of the edge | wobble at the edge | `panel.dwell` | `panel.push` | middle |
|---|---|---|---|---|---|
| any upward movement in the strip a push | ❌ push | ✅ | ❌ push | ✅ | ✅ |
| `pinnedEpsilon` 6, as tall as the strip | ❌ push | ✅ | ❌ push | ✅ | ✅ |
| no push ever counted | ✅ | ❌ dwell | | | |
| no dwell ever firing | ❌ nothing opened | ✅ | | | |

(.build/e2e/20260926-193702Z, -193959Z, -194444Z, -194748Z; the unbroken build,
both green, -193525Z — all rotated out since, and not kept.) `panel.dwell` went
red on the first two as well, once each, and why is known only in part. Its log says `fired by push` for a pointer
that was only placed, and the build that logged every movement showed a VNC
jump into the strip arriving with a deltaY of 717 or 1434, sometimes as two
events — upward movement the first mutant counts on arrival, and the second can
count from its second event. That is the same accident that used to make the
top row read as a push, and how often it would catch either mutant is not
measured. The wobble goes red on them by construction.

### The throw on its own

The guard has a second half, and neither wobble draws it: uDeck counts upward
movement only while the pointer is pinned *and was pinned before it*, because the
movement that arrives at the edge is the throw itself — uDeck's own comment on
`wasPinned` calls a throw at a menu-bar target the most common false positive
there is. The wobble at the edge is pinned before every report it makes, and
short of the edge nothing is pinned at all, so a uDeck without that condition is
green on both — and on `panel.push` too, which is a push whichever report fires
it.

`panel.a-throw-to-the-edge` is `panel.push` without the push: the same throw
from the middle of the screen, stopped the moment the pointer is pinned, and
nothing posted after it (push-pointer.py with no steps). The pointer comes to
rest against the edge, in the strip, and the panel has to open by the dwell.
Before uDeck is asked anything, the lab reads back two things (`panel.Throw`).
The pointer is against the edge. And the throw stopped there: it stops when it
reads the pointer pinned, and a reading one report late would let through a
report made against the edge, which is a real push. A report moves the pointer
exactly its own size, so from where the throw began the number it needed is
known — twelve of sixty from row 720 — and one more is the lab's push, not
uDeck's mistake.

Against a build of uDeck with that condition taken out (`wasPinned &&` removed
from `updatePushWindow`), on 2026-09-27, the six opening checks:

| uDeck built with | throw | wobble short of the edge | wobble at the edge | `panel.dwell` | `panel.push` | middle |
|---|---|---|---|---|---|---|
| the arrival counted as a push | ❌ push | ✅ | ✅ | ✅ | ✅ | ✅ |

(`.build/e2e/20260927-135536Z`, one run each; and six more throws on the same
build, each on a fresh machine, all `fired by push`: `-140142Z`. Both kept.)

**uDeck up to 7d56860 was red here about one time in five, and it was uDeck.**
Measured on 2026-09-27, each throw on a fresh machine and every one stopped at
the edge after exactly twelve reports: `fired by push` 2 times in 8
(`.build/e2e/20260927-131004Z`) and neither time in this check's runs in the
panel group and the whole lab (`-140526Z`, `-141957Z`); and with the throw
slowed to a report every 50 ms, 1 in 10 and 3 in 12 (`-132223Z`, `-133243Z`) —
6 in 32 in all. `-133243Z` was a build that logged every movement it handled
near the top of the screen (never committed), and in all three of its pushes the
report that arrived came as two equal movements with one timestamp, both at the
edge: the first reads as the arrival, the second as movement made while already
pinned — 32.6 to 42.4 points, over the 24 — and it counts.

Why both were at the edge was put down at first to uDeck reading the position
from `NSEvent.mouseLocation` rather than from the event, and that was wrong. A
second build that logged every movement, with each event's own location beside
it and which of uDeck's two monitors heard it (`-154333Z`, 16 throws, 11 with a
verdict, never committed): the two locations were the same in 39 movements of
39. A split report is one report heard twice — through the global monitor and
through the local one — with the movement halved between the copies (60 each,
where a whole report said 120) and both copies placed on the edge by the event
itself. Its three pushes were exactly the three throws whose arriving report
came in two copies; reports that came in two copies further down the screen —
twice in one throw that opened by the dwell, once in one of the pushes — did no
harm. So
the fix is in the recognizer, not in where the position is read: the parts of
one report — samples with one timestamp — are read against where the pointer
was before the report began (`HoverGestureRecognizer.wasPinned`), so both
copies of an arrival are the arrival and both copies of a real push still count.
On that build 36 throws of 36 opened by the dwell (`-163126Z`, 32 of them, one
"could not check" on a screenshot taken after uDeck had said `fired by dwell`;
`-165246Z`, 4). With the reading by report taken out again, on a build that
logged every movement: 3 of 16 by the push, exactly the three whose arriving
report came in two copies (`-182236Z`).

The same splitting was suspected of what used to make a VNC jump to the top row
read as a push (`panel.dwell`, above, and `config.INSIDE_THE_STRIP_Y`: 2 of 16),
and it was that. A probe made the jump 16 times, eight on each of two fresh
machines. On the fixed build all 16 opened by the dwell (`-165246Z`,
probe.row0-a and -b); on the build with the reading by report taken out and every
movement logged, 2 of 16 by the push, and those two were exactly the jumps that
came in two copies — 720 each, where a jump in one piece said 1440 (`-182236Z`).
The checks still dwell on row 5; nothing here asks them to move. Whether a real
mouse on a real Mac is ever split like that is not measured. All of these runs
are kept in `.build/e2e/kept/`.

### The panel closing

Eight more. Seven of them read the same log from the other end; the eighth asks
the question that follows all of them and that the log cannot answer, which is
where the keyboard went. The line the seven take as the verdict is the phase and the
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
gesture. The workspace's news of both is the same notification, and uDeck tells
them apart by the order of three things — the panel showing, the last click
anywhere, and the last click uDeck heard itself (`ApplicationSwitch`). It used to
be one reading, how long ago a mouse button last went down, against 0.15 s; the
news of a click past the panel came 232 ms after it once, in a whole lab run
(`.build/e2e/kept/20260926-211629Z`), and there is no time in the rule since. A
uDeck that read every activation as a click would throw the operator's
unfinished work away on ⌘-Tab, and this check and the two after it are the
only ones in the lab that see it — as this one sees a uDeck that took any click
since the panel showed for a click past it, or whose own click monitor noted
nothing: the click that held the panel open is after it showed, and it is
uDeck's own. Both measured red, 2 times of 2 each
(`.build/e2e/kept/20260927-182236Z`, `-184219Z`). The switch is `open -a` and
not an AppleScript activation from inside the guest, which was measured posting
no notification at all.

uDeck hears its own clicks by three roads, and the two after it are the other
two. `panel.a-switch-after-a-choice-in-a-menu` holds the panel open, then
right-clicks its first tab and chooses "Rename" in the menu that opens
(`config.THE_FIRST_TAB`, `config.RENAME_IN_THE_TABS_MENU`), then makes the
same switch. A menu tracks the pointer in a loop of its own, so a choice in it
reaches neither of uDeck's click monitors while the system counts it like any
other click: on a uDeck that heard only its monitors, the choice was taken for a
click past the panel and the held panel came back as a peek, 3 times of 3
(`.build/e2e/kept/20260927-193950Z`, `-194310Z`, probe.tab-menu-1 to -3). uDeck
now counts a click as heard when one of its menus lets go on it, and says so —
and that line is the check's witness that there was a menu to let go at all,
because a right click that opened nothing would leave "Rename" clicked on the
panel itself, which uDeck hears anyway. It is asked after the verdict, so that a
uDeck that never hears its menus is red rather than "could not check" — as it
was, 2 times of 2 (`.build/e2e/kept/20260927-202433Z`). Not the
status-bar menu: with the panel held, a click on uDeck's item in the menu bar is
a click past the panel by both roads — the global monitor hears it and another
application comes forward, the Finder where the build named it — and the panel
was put away before the menu opened, 2 times of 2 (probe.status-menu-1 and -2 in
the same runs).

`panel.a-switch-after-a-click-in-the-margin` is the third road: a click
outside uDeck that is not past the panel, in the 24-point margin below it
(`config.IN_THE_MARGIN`), which the global monitor hears and forgives. It makes
`panel.a-click-past-a-restored-panel`'s scene — a restored panel with the
Finder in front, so a click on the desktop brings nothing forward — clicks in
the margin, requires uDeck to say it heard a click outside it that was not past
the panel and to close nothing, then takes the pointer past the panel and
brings TextEdit forward with no click. A monitor that forgave the margin click
without counting it as heard took it for a click past the panel when the switch
came, 2 times of 2 (`.build/e2e/kept/20260927-183705Z`), and this check goes
red on that build 2 times of 2 (`-202433Z`); until it, nothing in the
repository held that line.

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

All eight act several times with reads in between, so they read the log in steps
(`panel.Story`): one window opened at the start and never moved —
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

Five more, and they are about the other way in: ⌃⌥U, which works with the
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
Measured on 2026-09-23: that line arrived on each of five fresh machines, in the
`panel` category, which is the window the phases come in too — three machines in
`.build/e2e/20260923-212036Z` and two in `-212549Z`.

It also **parks the pointer before uDeck starts**, and so do the other four. A
pointer left in the strip by whatever ran before opens the panel by the gesture
in a fraction of a second, and on a machine shared between checks (`--vm
per-group`, `per-run`) that reveal lands between the launch and the mark, where
no read here would ever see it — leaving a shortcut check pressing a chord at a
panel that was already up. Park, mark, launch, in all five.

What `panel.the-hotkey` does **not** ask is where the keyboard went: it presses
the chord and reads two phases, types nothing and reads no document, so a uDeck
that showed the panel and kept the keys would pass it. That question belongs to
`panel.the-hotkey-again` alone.

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
of 9 on two fresh machines — six cycles on one and three on the other — with
uDeck's line 0.9 to 1.4 s after the command, the SSH round trip and the `log
show` included. The key code is uDeck's own: 32 is "U" in
`HotKeyBinding.keyCodes`, an ANSI table that is a fixed hardware-layout ABI
rather than anything derived from the keyboard layout, and the lab's tests read
it back out of that file rather than trusting a number written down twice.

**"Never over VNC" is a rule about that one helper**, and a test of it holds it:
what `press_the_chord` does is a command over SSH and never a key over VNC. It
is not a rule about the checks that call it. `panel.the-hotkey` and
`panel.the-hotkey-closes-what-the-gesture-opened` send no VNC key at all and
each says so in its own test; `panel.the-hotkey-again` and
`panel.the-hotkey-dies-with-udeck` press plain letters over VNC on purpose,
because a letter is how they ask where the keyboard went.

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

And the reading at the open panel is asked **both ways in the same breath**,
because "the key I pressed is not in this text" is true of every empty string
there is. `probes.typed_into` raises when System Events refuses the question,
but an empty answer is not a refusal — it is a window read as holding nothing —
so the letter that reached the document before the panel was ever shown has to
still be there. A document that comes back empty goes red on that instead of
passing by holding nothing at all.

`panel.the-hotkey-closes-what-the-gesture-opened` presses the shortcut at a
panel it did not open: the peek the pointer earned. uDeck's toggle is written as
"shut, or else close" (`PanelController.toggleFromKeyboard`), so the shortcut is
the way out of *any* panel on screen — which is the part the operator meets
first, brushing the top of the screen by accident and reaching for the key he
knows. Neither of the two checks above can see it. `panel.the-hotkey` starts
from a shut panel and `panel.the-hotkey-again` from one the shortcut had already
promoted, so a build whose guard was narrowed to that promoted phase answers
both of them exactly as a correct one does — and at a peek it would take the
other branch, where `revealRequested` is ignored and `interacted` is not, and
*promote* the glance instead of closing it. The verdict here is the pair, as at
every other closing: `peek -> collapsed on closeRequested`, once, with nothing
reopening in the same read.

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

`panel.the-hotkey-dies-with-udeck` is the other control, and it is about the
Mac rather than about the panel. `RegisterEventHotKey` asks the window server to
deliver one combination to one process, and while that registration stands **no
other application sees that key** — so a uDeck that is gone and still holds ⌃⌥U
has taken a key out of the operator's keyboard, everywhere, until he logs out.
The shape is: it worked, then uDeck left, then the same press lands in a
document instead. The first press has to open the panel ready to be typed into,
on this machine, in this run, so that what the press does afterwards is about a
combination that was demonstrably live and not about a lab that cannot press
chords; a second press puts the panel away before uDeck goes, so the keyboard is
back where the operator left it.

And then the verdict is **not an absence at all**. uDeck's log saying nothing
once uDeck has ended is free, and the panel is never read off a screenshot here,
so what the check reads is a *presence*, in the document. While the registration
stands the window server delivers ⌃⌥U to uDeck and to nobody else, so the
application behind the panel never sees the keystroke; once it is gone the same
keystroke goes where every other one goes. Both halves are read, of the same
document: while uDeck holds the shortcut two presses leave the document exactly
as it was, and once uDeck has ended one press puts `0x15` into it — the control
character the layout gives for Control over "U" — with an ordinary letter after
it arriving too. Measured on 2026-09-24, at this check's first run: the document
read back `'a\x15x'`. A combination that outlived uDeck would leave it holding
`'ax'`, as empty of the chord as a living uDeck leaves it, and that is what the
check goes red on.

The letter after the chord is in the same sentence for a reason of its own: a
leaked registration is not only a key that opens nothing — it is a key nobody
receives, and a modifier left down behind one takes the rest of the keyboard
with it, which is exactly what one ⌃⌥U over VNC did to this guest on 2026-09-23.

It is red for a uDeck that holds the combination somewhere its own process does
not end — a helper, a login item, an input tap installed for it. It is **not**
red for `HotKeyMonitor.unregister` and `stop()` being emptied out: macOS
reclaims a process's hot keys when the process exits, so a build that never
unregisters anything gives the combination back exactly as this one does. That
was measured rather than argued — with both methods emptied the check passed and
the document read back the same control character and the letter after it
(2026-09-24). The tidying in `HotKeyMonitor.stop()` is therefore held by no
check in the lab, and cannot be until something asks uDeck to give the key up
while it is still running.

**One more thing about the shortcut is known and checked nowhere**, in UDeckKit,
which has no test target — the package has one, `UDeckCoreTests`. uDeck
recognises its own hot key in the Carbon callback before it acts on it
(`HotKeyMonitor.swift`, the signature and id guard), and uDeck registers exactly
one combination, so every hot key event this process can receive is that one: a
build that answered any hot key at all behaves here exactly like this one. What
used to be listed beside it — the shortcut being registered again when the
operator changes it (`PanelController.settingsChanged`) — is now
`settings.the-shortcut-changes-at-once-and-survives`, below.

### The settings the operator changed

Two, and they are about the one path through uDeck every other group of checks
leaves alone. The panel checks install a build and use it as it ships; the login
checks flip one switch and then ask the *system's* database about it, never
uDeck's own file. So a uDeck that wrote nothing to disk, or wrote it and never
read it back, or read it back and never told the running application, is green
everywhere else — and the operator finds his shortcut back to ⌃⌥U every morning.

**The change is made in the window, with the pointer, and never in the file.** A
check that wrote `~/.udeck/settings.json` itself and restarted uDeck would be a
check about `JSONFileStore` and about nothing a person does: it would stay green
over a settings screen whose controls were wired to nothing at all, which is the
half of this feature the operator actually touches. The file is what the check
*reads* afterwards — one of the two halves of every verdict here, never the way
in. Both halves, because neither is the promise on its own: the file is what
survives uDeck, the behaviour is what was asked for, and a uDeck that saved
perfectly and ignored what it loaded satisfies the first while losing the
setting at every launch.

**Which settings, and why only these two.** Most of the Opening screen can only
be photographed — a dwell of 60 ms rather than 80, a panel a little wider — and
a photograph is exactly the evidence that passes for the wrong reason here,
because the panel is translucent over whatever is behind it. Two settings uDeck
answers out loud, and those are the two. Density, the obvious third, has an
`AXDescription` of its own and would otherwise be the easiest of the lot — and
it sits at y 948 with the window's lower edge at 846, so it has to be scrolled
to before it can be clicked (measured 2026-09-25).

`settings.a-switch-survives-a-restart` turns off "retract when you switch
applications" (`collapseOnAppSwitch`) and makes the same scene twice over with
the switch as the only difference: a held panel, the pointer taken past it,
another application brought forward with no click. With the switch on — before
anything is changed, which is the control — uDeck writes `open -> collapsed on
otherAppActivated`; with it off, after uDeck has been restarted, it writes
`otherAppActivated ignored in open` and the panel stays. Without the control
first, "the panel stayed" would be an empty green: a scene that never worked
leaves the same silence as a setting that was obeyed. And uDeck has to have been
*told* both times — `another application came forward …` — or nothing was asked
of the setting at all, which is the lab's failure and not a verdict.

`settings.the-shortcut-changes-at-once-and-survives` adds ⇧ to ⌃⌥U and asks
three things of that one press. That the running uDeck took the new combination
from the window server, which is its own line (`hotkey ⌃⌥⇧U registered`) and the
only thing that tells a uDeck which never re-registered from one which did and
cannot hear. That the old combination is dead and the new one opens the panel
ready to be typed into — both halves, because while a registration stands the
window server delivers that key to that process and to nobody else, so a uDeck
still holding ⌃⌥U has taken it out of every other application on the Mac. And
that a uDeck started again afterwards holds the new one, which is the file's
half. "Nothing happened" is free, so the old combination's silence is witnessed
by the new one straight after it, on the same machine — the same shape as
`panel.a-chord-that-is-not-the-hotkey`, and both chords are made the same way,
inside the guest, so what is controlled for is the combination and not how the
lab presses it.

After the restart it asks two of those three, and the old combination is not
pressed again. It is pressed once, in the uDeck that was told, which is the only
uDeck that had a registration to give back. The restarted one never held it:
`HotKeyMonitor.apply` takes one combination, from the file, and says which at
launch — and the check reads the file and that line before it presses anything.
A second silence would cost ten seconds of deliberate waiting plus a chord and a
read of the log, every run, to witness what those two have already said.

**A restart here is uDeck's, not the machine's.** What is asked is whether the
file uDeck wrote is the file uDeck reads — `DeckModel.init` loads it once, at
launch — and quitting uDeck and starting it again is exactly that question at a
tenth of the cost. A machine restarting is the login checks' subject, where it
is the system's own memory of uDeck that has to come through a boot.

**Nothing on the Opening screen has a name.** Not one control there carries an
`AXIdentifier`, an `AXTitle` or an `AXDescription` — SwiftUI gives a `Toggle` no
accessible name and the label beside it in the `Grid` is a separate element — so
the identifiers on that screen belong to the sidebar and to nothing else. The
lab finds those controls by where they sit among their own kind (the four
`AXToggle` checkboxes are the shortcut's modifiers, left to right; the four
plain ones are the switches, top to bottom) and then reads the row back before
it clicks: it has to read what uDeck's shipped defaults read — on, on, off, off
and on, on, on, on — or nothing is clicked at all. That guard catches a pane
still being built, a pane that is not this one, and a machine an earlier check
left changed; it does not catch a row laid out in another order, and cannot,
because all four switches read alike and the modifier row survives swapping its
two ons. So the order is not observed on the screen at all: it comes from
`OpeningSettings`, and what holds it is the lab's own tests reading that file
back — including a count of every `Toggle` on the screen, so that one declared
in some other form fails the test rather than slipping past it. The two orders
and the two readings are in `config` with their reasons, read back out of
`OpeningSettings`, `HotKeyModifier` and the defaults of `AppSettings`,
`GestureTuning` and `HotKeyBinding` — the way the gesture's numbers and the
shortcut's are held.

**The one thing the lab trusts a translated name for is the way in.** uDeck's
menu item is found by its title (`Settings…`), because it carries no identifier
— so on a guest that is not in English there is no way into these screens at
all. That is a lab that cannot reach the window rather than a uDeck that would
not open it, and the failure says so in those words, with the language the guest
answers with and the titles its own menu offers.

And then the control is pressed **with the machine's pointer**, at the
coordinates the accessibility API reports, like every other control the lab
drives (`ui.press`). An `AXPress` needs no coordinates and no screen, so it is
the obvious shortcut — and it does not select anything (measured 2026-09-17,
which is why `ui`'s whole docstring exists). It is also not what the operator
has: a click through the virtual pointing device is the same device the gesture
checks push the panel open with, so a setting changed this way is a setting
changed the way he changes it.

And the click is read back before anything is made of it. A click goes to where
the accessibility API said the control was a moment earlier, so a window that
moved or a pane still being laid out leaves the screen exactly as it was — and a
miss nobody read would travel: the file would hold nothing, and the check would
say the operator's change is nowhere about a uDeck that was never asked for one.
So `ui.press` walks the screen again until the control says the click landed,
and a control that does not is the lab failing to press it, with the place it
clicked and what it found there in the reason.

Where the file comes in is afterwards. uDeck writes no settings file at all
until something is changed — measured 2026-09-25: missing before the install,
after the first launch, and after all five sections of the settings window had
been opened and walked — so the file these checks read holds the operator's own
change and nothing else. A file a neighbouring check left behind (which is what
`--vm per-group` and `per-run` make possible, and what the first of these two
checks leaves) is **removed** before uDeck is started, with the install having
quit the uDeck that was running: refusing the machine instead would have made
the second check of the group impossible in exactly the two modes a group is
meant to be run in. Removing it is the only thing the lab does to that file from
outside — the change itself is still a click in uDeck's own window.

It is written inside the click, all thirteen keys of it — 1921 bytes for the
switch and 1935 for the shortcut, measured again on 2026-09-26 — 0.26–0.29 s
from the click being issued; nothing is flushed on the way out, and the file's
time across a quit was identical to the fraction of a second. Both checks read back all thirteen: what a settings
file does not say is read back as the shipped default
(`AppSettings.init(from:)`), so a save that keeps the operator's one change and
drops the twelve keys around it resets his density, his theme and his panel
sizes at the next launch with nothing anywhere to say it happened — and a check
that read back only what it clicked would be green over exactly that. When the
file is not there at all, uDeck is asked why: it writes `could not save the
settings: <error>` when the store refuses it (`DeckModel.save`, in the `plugins`
category, which is why the window these checks read keeps three categories and
not two), and the verdict names that line when it is there and says it was
absent when it is not — a home directory that cannot be written and a control
wired to nothing leave the same empty place, and they are two different people's
problem.

### Plugins from a repository

Twenty-four checks, one per row of the table in docs/plugin-repository.md ("The
lab's checks"). None of them talks to github.com — in the lab only the update
checks given a published release do, `updates.a-published-release` by default.
A fake GitHub runs inside the guest (`e2e/guest/fake-github.py`, the guest's
own Python and the standard library only, on `127.0.0.1:8766`), answering the
part of the API uDeck uses — the default branch, the head with its `ETag` and
`304`, a tree with and without `recursive=1`, a folder's history — and a raw
file host beside it. Its content
is the fixture commits in `e2e/fixtures/plugin-repository/`: `c1` holds
`uptime` 1.0.0 and the three plugins uDeck must refuse (`future-api` with
`api: 2`, `future-udeck` with `minUDeck: 99.0.0`, `linked` with a symbolic
link), `c2` the same with `uptime` 1.1.0, asking for what 1.0.0 asks, and `c3`
with `uptime` 1.2.0, asking for one command more. The fake hashes them into real git
blob, tree and commit ids itself — there is no git in the guest — and the lab's
own tests hold its hashing against `git hash-object`, `git write-tree` and `git
commit-tree`. uDeck's Swift then has to agree with it, file by file and folder
by folder, or nothing installs.

**The lab drives the fake by rewriting a small state file over SSH**: which
commit `main` is at, "the limit is used up until T" (`403` with
`x-ratelimit-remaining: 0`), "answer this file with different bytes", "say the
listing is truncated". Each change is read back through the fake before a check
relies on it.

**Three oracles, none of them what uDeck says about itself.** The fake's access
log — one JSON line per request — is the traffic: what uDeck asked for, and what
it did not. The lab's own requests carry `X-UDeck-Lab: 1` and are never counted
as uDeck's. The guest's `~/.udeck` is what uDeck did to the disk: the installed
folder hashed as git would (by the fake's code, in the guest, against the id the
fake gave the fixture), `installed.json`, `layout.json`, `grants.json`. And the
screens — Settings → Plugins and the card in the panel, found by its subrole
`AXSystemDialog` — are read through the identifiers uDeck gives every control
there, and pressed with the machine's pointer. The settings window is moved and
sized to most of the guest's screen first (`ui.place_settings`): the Plugins
pane is one long scroll, and a control below the window's edge has a place and
no pixel to click.

**What the lab does by hand.** Placing a plugin on a tab is writing
`layout.json` while uDeck is not running — the table asks what uDeck does with a
window it has, not how windows are made. Consent is given where the operator
gives it, on the card (`consent.<id>.allow`). A file changed on disk and a
manifest broken and mended are changed over SSH, because that is what "changed
on disk" means. A check that moves `main` and presses **Update** on what it
offers starts uDeck with **Update verified plugins by themselves** off — one
key in `settings.json`, written before uDeck starts — or uDeck would put `c2`
in place by itself before anything could be pressed; the two checks of updates
by themselves start it as it ships. `plugins.verified-updates-itself` makes the
catalogue look two days old while uDeck is not running — the guest's own Python
moves `lastSuccess` back in `~/.udeck/catalogue/official/state.json` — so that
the launch reads it again, as after a Mac that was off for a day, and then
presses nothing at all. `plugins.permissions-change-only-offers` presses the
card's **Hold** and later ends it with `SIGTERM` over SSH, as an action that
finishes ends, to see the update by itself that waited on it come on the
minute's tick. Where a plugin is left alone, the two read uDeck's own log for
the reason it gives (`pinned`, `asksDifferently`, `actionRunning`): from outside,
every reason looks the same. One value is left in `plugin-settings.json` before a removal,
so that the removal has something there to take away. A linked folder
(`plugins.linked-folder`) is a working copy the lab makes outside `~/.udeck`
and links in by hand while uDeck is not running, as `udeck-plugin link` would;
a file in it is touched over SSH every few seconds while the plugin's own count
of its runs is read before and after; its removal is a click, and what it
leaves of the working copy is read over SSH before and after, every name and
every byte. Every install, update, earlier
version, removal and switch is a click.

**What Settings offers somebody writing a plugin**, one check each, every one a
row of the same table:

* `plugins.link-a-folder` presses **Link a folder…** and chooses the folder in
  the system's own folder panel the way a person types one: ⌘⇧G, the path,
  Return, Return — sent from inside the guest through System Events
  (`ui.choose_folder`), as every chord the lab makes is, since a chord over VNC
  does not survive the trip. Then the oracle is the disk: where
  `plugins/<id>` leads, `installed.json`, the working copy before and after.
  The working copy's id is changed under the warning over SSH (`sed` on its
  `manifest.json`, the original kept beside the copy and put back), so that
  **Link** on a warning that no longer says what is there is seen to warn
  again and change nothing.
* `plugins.run-log-switch` clicks the switch and reads `settings.json` and
  `~/.udeck/logs/<id>.log` over SSH.
* `plugins.failed-run-on-a-fresh-card` makes its plugin fail by putting a file
  into its folder over SSH, and reads the panel's walk for the dot
  (`card.<id>.failedDot`) and its texts for the line; then Settings, under
  **More**. The same walk says which of the panel's own buttons are there, by
  their identifiers (`panel.refresh`, `panel.settings`, `panel.sendAway`,
  `panel.fullscreen`).
* `plugins.install-command` runs `codesign --verify --deep --strict` on the
  installed bundle and the command through the link, `--help` and
  `--version`, inside the guest; the guest's zsh is what Settings asks about
  `~/.local/bin`. A file of the lab's own put at the command's place is taken
  away again at the end.
* `plugins.search-path-field` writes two folders of commands over SSH, adds
  them through the field and its folder panel, and reads which one the card
  ran.
* `plugins.screens-in-russian` sets uDeck — not the guest — to Russian in
  `settings.json` before it starts, reaches Settings by its Russian menu item
  and window title (`ui.RUSSIAN`), and keeps a screenshot of every part the
  others check, in Russian, for a person to read — and of two warnings over a
  link: **Link a folder…** over the linked `flaky`, and **Update** over a link
  put by hand where the installed `uptime` was.

## Reading the result

One line per check, then a summary:

```
✅ updates.sparkle  2m14s
   pair: checkout as 0.4.1 (6) → checkout as 0.4.2 (7), signed with the run's own key, via the lab's feed in the guest (default: checkout → checkout)
❌ updates.wrong-key  1m02s — Sparkle installed an update signed with the wrong key
   pair: checkout as 0.4.1 (6) → checkout as 0.4.2 (7), signed with another key, made for the check, which "from" does not carry, via the lab's feed in the guest (default: checkout → checkout)
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

So a run this file or a check's comments name as evidence may be gone by the
time anyone looks for it, and a number quoted from a run that is gone can no
longer be checked. The pruning touches nothing under `.build/e2e/` that is not
named like a run, so runs worth keeping are copied to `.build/e2e/kept/`, where
the ten of 2026-09-26 from 21:04 to 22:54 UTC and the runs of the review of
2026-09-27 are. A run named here that is in neither place was rotated out, and
where a number rests on one, the text says so.

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
