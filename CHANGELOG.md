# Changelog

All notable changes to uDeck are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

The **plugin contract** is versioned separately from the application, by the
`api` field in a plugin manifest. See [docs/plugin-api.md](docs/plugin-api.md)
for what that promises.

## [0.2.0] — 2026-09-10

The first update anybody can install, and the screen it is installed from.

- **No window.** Sparkle's standard driver answers a check with a modal alert,
  and the commonest answer is "you are up to date" — an interruption to deliver
  the least interesting thing the check could have found, in a window uDeck did
  not draw and cannot translate. A custom `SPUUserDriver` writes what happened
  into the settings screen instead: installed version, latest version, and one
  sentence beside the button. Two numbers rather than a claim — "up to date"
  asks to be believed, "installed 0.1.0, latest 0.2.0" can be checked.
- **The settings window is in the ⌘-Tab switcher** while it is open. uDeck is an
  accessory application, which is right for a panel at the edge of the screen
  and wrong for a window somebody is working in: a window you cannot switch back
  to is a window you have to close and reopen. The policy is `.regular` for
  exactly as long as the window is open, Dock icon and all.
- **Relative times follow the panel's language, not the system's.** Without the
  locale the sentence came out half-translated — "Проверено 35 seconds ago" —
  and a check that has just finished says so in words, because the formatter
  rounds the zero and picks the future tense for it.

## [0.1.0] — 2026-09-10

The first working version: the shell, the plugin runtime, and one plugin.

### The application

- **The panel.** A non-activating `NSPanel` at the top centre of whichever
  screen the cursor is on, growing out of an island. On the built-in display
  that island is the notch itself and the panel hangs below it; on a screen with
  no notch uDeck draws its own — the same size as a real one, welded to the top
  edge — because an island that stops one menu bar short of the corner reads as
  a window near the corner. Four states: the island, a peek, a working panel and
  fullscreen. It retracts when another application is activated, and a panel
  that was being worked in comes back as it was.
- **The pointer gesture.** Two ways in: keep pushing after the cursor has
  stopped at the top edge, or rest there for a moment. Suppressed while a button
  is down, while a system menu is open, over fullscreen applications, just after
  a menu-bar click, and just after the panel closed.
- **A keyboard shortcut**, `⌃⌥U` by default and configurable. It opens the
  panel ready to type in rather than as a glance, and closes it again. Carbon's
  `RegisterEventHotKey` rather than a global event monitor, so uDeck still asks
  macOS for no permissions: one registered combination is handed to the
  application, which is not the same thing as watching the keyboard.
- **Tabs and a 12-column grid.** Windows are dragged by their title bar and
  resized from a corner, in whole cells; neighbours make room and everything
  settles upward. The arrangement is a file, so it survives a restart and can be
  copied between machines.
- **Card rendering** for all seven row types, in three densities, in the glass
  look — with staleness drawn rather than described.
- **The empty state**, which is what an install with no plugins shows: a plugin
  picker that also lists the folders that failed to load, and why.
- **A settings window**: how the panel opens, density, and — the largest part —
  what is installed, what each plugin asked for, and the settings each plugin
  declared, rendered by the host so no plugin has to ship a settings screen.
- **A menu-bar item**, which is the only way to quit an application with no Dock
  icon, and a second way to open the panel.

### The plugin runtime

- **Discovery** from `~/.udeck/plugins/`, relocatable with `UDECK_HOME`. A
  folder that fails to load is shown with its reason rather than skipped.
- **`poll` producers** run under a deadline the host enforces, because a stock
  macOS has neither `timeout` nor `gtimeout` and a shell producer cannot police
  itself. Killing one kills what it started.
- **An output cap**, so a producer stuck in a printing loop is stopped.
- **A legible failure for every way a producer can fail** — timed out, crashed,
  printed nothing, printed something that is not a card, printed too much, could
  not be started, was never permitted.
- **Staleness**: a card past its `ttl` is dimmed and dated; past a multiple of
  it, its values are hidden. "The source is quiet" looks like neither "fine" nor
  "broken".
- **Permissions** declared by the manifest, decided by the operator, and honest
  about which of them the host can genuinely hold.
- **`resident` plugins are described by the manifest format** and not
  implemented, so that adding them later cannot break plugins written today.

### The examples are one shape

- **Every example has a manifest, a translation beside it, a README saying what
  it demonstrates and what you should see, and an executable producer** — and CI
  checks all four, because otherwise the shape is a convention and a convention
  is whatever the last person to add an example happened to do.
- **[examples/README.md](examples/README.md)** says which example answers which
  question, so the four stop being a pile to read in order.

### Writing a plugin

- **A walkthrough**, [docs/writing-a-plugin.md](docs/writing-a-plugin.md): an
  empty folder to something on the panel, then a card, a source, settings,
  permissions, buttons, two languages, what the host does when a producer
  misbehaves, and a checklist to run before shipping. The contract stays what it
  was and is now named as the reference rather than the starting point.
- **`Scripts/new-plugin.sh`** writes a plugin that already works into the folder
  uDeck watches. The point is not saving twenty lines of manifest: it is that a
  first plugin should *run* before it is edited, so that when it stops working
  its author knows which of their own changes did it.

### A plugin that will not run says so where you are looking

- **The menu-bar item carries it.** A plugin's problems were already written
  down — in the settings screen and next to the plugin in the picker — and both
  of those need somebody to go and look. The menu-bar item is the only part of
  uDeck on screen without being asked for, so the icon takes a warning badge and
  the first row of the menu says how many will not run and opens the screen that
  says why. It clears itself when the plugin is fixed or removed, because the
  folder is watched.

### uDeck updates itself

- **Sparkle**, and it is the project's first dependency. The parts of updating
  an application that look easy — checking a feed, downloading, replacing a
  bundle that is currently running, relaunching — are the parts that fail
  quietly, on the machine of somebody who is not watching.
- **Automatic checks are off until switched on.** uDeck otherwise makes no
  network connection at all and asks macOS for no permissions, so the first
  outbound connection this application ever makes is one the operator chose.
  The switch says what it will start doing rather than just "check".
- **A tag is the whole release.** `.github/workflows/release.yml` builds on
  `v*`, refuses a tag that disagrees with `CFBundleShortVersionString`, runs the
  tests, assembles the bundle, archives it with `ditto` (which keeps the
  symlinks a signed bundle is made of), signs the archive with an EdDSA key from
  the repository's secrets, and publishes the archive and the appcast as release
  assets. The feed is `releases/latest/download/appcast.xml` — a stable URL that
  needs no hosting.
- **`Scripts/adhoc.entitlements`** exists because of one rule: the hardened
  runtime turns on library validation, which requires every loaded library to be
  signed by the same team as the application — and ad-hoc signing expresses no
  team, so an ad-hoc app and an ad-hoc framework are not the same team but two
  things with no team. dyld refuses the framework and the application does not
  start. Scoped to ad-hoc, so a Developer ID build keeps library validation.

### The plugins folder is watched

- **Adding or removing a plugin no longer needs telling.** The list used to be
  whatever was on disk when uDeck started: a plugin copied in did nothing until
  the operator found the "Look again" button, and one taken out stayed in the
  picker offering to add something that was not there. FSEvents rather than a
  directory source, because half of what matters happens *inside* a plugin's
  folder — a manifest edited in place, a translation dropped beside it, a
  producer made executable. Coalesced twice, so expanding an archive is one
  re-read rather than one per file.

### uDeck is a platform a plugin cannot break

An audit of what a plugin could still do to the host, and what it found:

- **Two traps a manifest could reach.** `"interval": 1e308` is correctly
  rejected and the settings row for the plugin it rejected still formatted it —
  `Int(someDouble)` traps outside `Int`'s range. A setting declaring only
  `"min": 9223372036854775807` overflowed computing its editing range. A trap
  cannot be caught; both took the process.
- **Three ways to freeze the panel that the card limits did not cover.**
  `actions` were unbounded in count, label and argv; `canvas` and `unsupported`
  rows walked past the trimming, so a 900 KB row *name* was a 900 KB string to
  shape; and the output cap bounded what was noticed rather than what was kept,
  so a fast producer could make a 1 MiB limit retain hundreds of megabytes.
- **Consent that outlived what it was given for.** A grant is decided against a
  version; an action consulted only the stored grant, so a new version that
  asks for nothing still ran the old version's commands. And an action's
  relative path was contained lexically while a manifest's `run` was contained
  with symlinks resolved — two copies of one rule, one of them decoration.
  There is one resolver now.
- **A floor on the durations.** `"interval": 1e-12` is positive, finite and
  inside the ceiling, and truncates to a zero-length sleep.
- **Backoff for a failing poll plugin**, doubling to a minute, reset by the
  first card. Manual refresh ignores it.
- **A refresh no longer queues behind its slowest producer**, four at a time.
- **A window hint taller than the grid draws is refused** rather than silently
  clamped.
- **Every run gets a process group of its own.** Foundation's `Process` cannot
  ask for one, so the producer is spawned by hand. What it buys: the old cleanup
  had to enumerate the process tree *before* signalling — once the direct child
  dies its children belong to `launchd` — and it only ever ran on a deadline or
  an output overrun, so a producer that started something detached and exited
  *successfully* left it behind on every poll. Ending a group has no such
  window. The escalation to `SIGKILL` no longer stops when the direct child
  exits, either: its comment said "nothing left to kill", which was true only of
  a producer that had started nothing.
- **Signal dispositions are reset in the child.** They survive `exec`, so a
  producer inherited the host's — and a shell cannot trap a signal that was
  already ignored when it started. The polite `SIGTERM` was reaching producers
  that could not act on it, and every well-behaved one cost the full grace
  period and then a `SIGKILL`.

### The bundled plugin

- **Disk space** — how much room is left, counted per disk rather than per
  mount. A `df` line is not a disk: the five APFS volumes of one container all
  report the same free pool, so listing them shows the same 657 GB five times
  and summing them claims three terabytes on a one-terabyte disk. Free space is
  taken once, used space is summed, and fullness is measured against what the
  disk can still hold rather than against a total the operator can never
  reach.

### Around the code

- **`UDeckCore`** holds every decision that can be made without AppKit, so the
  gesture can be tested against a fabricated event stream and the geometry
  against real screens. 143 tests.
- **Documentation**: the [plugin contract](docs/plugin-api.md), a README, a
  contributing guide, and a contributor licence agreement.
- **CI** on GitHub Actions: the build, the Swift tests, and the plugin's own
  Python tests.
- **`Scripts/make-app.sh`** assembles `uDeck.app` from a release build and signs
  it. Ad-hoc by default; `--sign` takes a Developer ID when there is one, and the
  hardened runtime is on from the start so notarisation is a step rather than a
  refactor.
- **Logging** through the unified logging system, so the gate that stopped a
  gesture or the reason a panel closed can be read afterwards:
  `log stream --predicate 'subsystem == "place.unicorns.udeck"' --level debug`.
- **Example plugins** in `examples/`: `hello-card` (every row type),
  `slow-plugin` (hangs on purpose) and `broken-card` (prints something that is
  not a card). They are the test fixtures as well as the documentation.

### Deliberately not here

Resident plugins and the terminal they exist for; the `canvas` row a plugin
would draw itself; a plugin registry; the application
switcher, which would need Accessibility; host-side history for sparklines; and
notarisation.
