# Changelog

All notable changes to uDeck are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

The **plugin contract** is versioned separately from the application, by the
`api` field in a plugin manifest. See [docs/plugin-api.md](docs/plugin-api.md)
for what that promises.

## [Unreleased]

- **A debug build is its own application.** `Scripts/make-app.sh --debug` now
  gives the bundle the identifier `place.unicorns.udeck.debug` and no update
  feed. Measured in a virtual machine: a second copy carrying the release's
  identifier takes over the release's login item just by being launched, either
  copy switching it off switches it off for both, and a debug build offered a
  release update installs the release over itself — becoming that second copy
  again.
- **`--test-feed` and `--test-key`** build the release configuration against a
  throwaway appcast and public key, baked into the bundle so they survive
  Sparkle's relaunch, for testing an update end to end without the real feed.

## [0.4.0] — 2026-09-13

The island stops being one appearance. Every situation it can be in — away,
revealed, open, full-screen, and each of those over another application's full
screen — can look its own way, and the ones that should look alike are grouped
by dragging them together. And revealing the panel now takes the keyboard, which
it had been asking for and not receiving since there was a panel.

- **The look travels instead of snapping.** Changing state used to swap the
  colours in one frame while the panel's shape was still moving — quiet island,
  hover, instantly dark, pointer away, instantly transparent, and only then the
  shape leaving. Colours and the material's own alpha now move over the same
  time the panel does: 0.12 s coming back, 0.3 s going away. Sampled mid-collapse
  over one wallpaper: `51,74,89` → `42,93,125` → `62,128,169` at rest.
- **Collapsing actually lets the keyboard go.** The panel does not disappear when
  it collapses — it is the island — so it kept first responder and key status,
  and uDeck kept the keyboard: the operator hovered, moved away, and could no
  longer type in the application he had been typing in. Collapsing gives up the
  responder and deactivates uDeck before handing the keyboard back.
- **Revealing the panel takes the keyboard, and collapsing gives it back.** A
  peek used to be deliberately non-activating, which meant the panel was on
  screen, under the pointer, and typing went into whatever was behind it. Now
  the application that had the keyboard is remembered on the way in and
  activated again on the way out — except over another application's full
  screen, where activating uDeck would not swap a focus ring but switch spaces
  and take the film away.

  It never worked before either: `takeKeyboard` asked `NSApp.isActive`, which
  for an accessory application reads `true` while another application is
  verifiably in front — measured through the panel's own log with Warp
  frontmost. So the activation never ran and nothing was ever restored. It asks
  the workspace who is in front now. Measured across a full cycle: Warp → uDeck
  → Warp.
- **A frame means "together", so one state does not get one.** Clearing
  «Настроить все вместе» left eight lone states in eight frames — eight
  statements about nothing. And clearing it now goes back to the arrangement it
  replaced rather than to that pile: the box remembers what it covered for as
  long as the window is open.
- **«Настроить все вместе» is back**, under the states. Checked means one group
  holding every situation — what uDeck shipped with — and clearing it puts each
  situation on its own, keeping what it looked like a moment before.
- **The settings file names its groups.** A dictionary keyed by anything but a
  string is encoded by Swift as a flat `[id, look, id, look]` array: correct,
  round-trips, and unreadable in the one file uDeck invites a person to open.
- **The island's material follows its state too.** The surface read the theme's
  glass while the text colours came from the state's look, so a state given its
  own material — a ghost island, say — was drawn with the theme's: the sample
  showed one panel and the screen showed another. Measured on the real island
  over the same wallpaper, before `67, 103, 126` and after `62, 128, 169`
  against a wallpaper of `60, 138, 186`.
- **A group is what you point at.** The buttons are gone and so is picking
  individual states: clicking anywhere in a frame sets the controls on that
  whole group, which is what a group is for. Joining and separating happen by
  dragging — onto a frame, or onto the strip below it. Selecting one state out
  of one frame and another out of a second was possible and meant nothing, and
  that is the shape of bug that survives a whole release because everyone
  assumes it is a feature.
- **The pane scrolls to its own end.** Scrolled to the very bottom, with the
  scroll bar at 1.0, the last control was still cut by the window's edge.
- **The notch note follows the panel's screen**, not whichever screen has the
  keyboard: it appeared and disappeared while the settings window had not moved.
- **The sample is the state you are editing.** It takes that state's shape —
  the island is an island, the open panel is a panel — fades to that state's
  «Видно», and over "another application full-screen" the two backdrops give way
  to a dark one, because the question there is whether the island is still
  findable on a film rather than whether it survives a white document.
- **States can be dragged.** Onto a frame to join it, onto the strip below to
  stand on their own; the buttons still do the same thing for anyone who would
  rather select and click.
- **A collapsed state says when it cannot be seen.** On a screen with a notch
  the hardware plays the island and nothing is drawn, so those two states carry
  a note saying so — and keep their controls, because an external monitor is
  where they apply.
- **Presets land where the knobs point.** Pouring one in changes the link being
  edited rather than always the theme, and saving one keeps what is on screen.
  Values marked as the same everywhere are left alone: a preset is about the
  character of the panel, not about undoing that decision.
- **«Вид» is two columns, and a value can be marked as the same everywhere.**
  The situations stay put on the left; the right half — what is being edited,
  the sample, the knobs — changes under them, so the sample sits directly above
  the controls that move it rather than a window away. Each value carries a
  small link switch: on, it is taken from the theme's own look whatever state is
  selected, and that beats any grouping. Both directions are written so nothing
  on screen moves at the click: switching it on makes the value you are looking
  at the one everybody gets, switching it off writes that same value into every
  group that had one of its own.
- **«Вид» has a states editor.** The eight situations are drawn as chips; the
  ones set up together sit in a frame. Click to select, «Связать» puts the
  selection in one frame, «Разъединить» takes states out of it — and a state
  that leaves keeps the look it had rather than snapping back to the theme's.
  Everything below the row edits whatever is selected, and a line under it says
  so in words. A selection that spans two frames edits nothing and says that
  too, instead of silently picking one of them.

  Not yet: dragging states between frames, and the per-value «как везде»
  switches. Both are the next slice.
- **The island has eight situations, and each can look its own way.** A state is
  a phase — away, revealed, open, full-screen — and what is behind it: ordinary
  windows, or another application holding the whole screen. States are grouped
  into links, and a link is a set of states edited together; every state belongs
  to exactly one. Values are per theme, because a Mac that switches itself at
  dusk needs both halves of the day set up; the grouping is shared, because it
  is structure rather than colour. Individual values can be marked as the same
  everywhere, and that beats any link.

  Nothing changes yet: out of the box one link holds all eight states and gives
  none of them a look of its own, which resolves to the panel that was already
  there. The editor for all of this is the next step; this one is the model
  underneath it, the resolution, and the panel drawing per state.
- **How much of the island is there is a value of the look, per state.** «Видно»
  says what share of the island — surface, tint and mark together — is on screen
  in that situation; five percent is the floor, because an island nobody can see
  is one the pointer cannot find, and that is how it comes back. It fades in
  0.3 s and wakes in 0.12 s: coming back answers something the operator just
  did, and going quiet answers nothing.

  This began as a switch of its own — «Приглушать остров», one number for every
  situation at once — and that switch is gone. A settings file that still has it
  becomes what it always meant: the two collapsed states, linked, at that much
  presence. One mechanism instead of two.
- **`Scripts/make-app.sh --install` puts the built bundle in `~/Applications`.**
  An application outside an Applications folder does not get its icon
  everywhere: measured, the same ad-hoc signed bundle shows the system's
  placeholder tile in Stage Manager's strip when it is run from a build
  directory and its own icon when it is run from `~/Applications` — identifier
  and contents unchanged, only the path.
- **The settings sidebar no longer has a toggle.** The button
  `NavigationSplitView` adds by default had nothing to anchor to in a window
  without a toolbar: it sat beside the title while the sidebar was open and
  jumped to the far right corner when it closed. It is removed rather than
  repositioned — its whole effect was to hide the window's only navigation and
  leave no way back to it.
- **`Scripts/make-app.sh --debug` bundles the debug build**, into
  `dist/uDeck-debug.app`. A bare `.build/debug/uDeck` is not an application as
  far as macOS is concerned — no Resources, so the generic executable tile
  wherever an icon is asked for, and only the embedded `Info.plist` to go on —
  which means the copy being developed did not behave like the copy being
  shipped. Now it does, and a released uDeck can stay installed beside it.

## [0.3.0] — 2026-09-10

A mark of its own, and the glass under it is the system's rather than a drawing
of one.

### uDeck has a mark of its own

- **`ū` — the first letter of the name and the bar the panel hangs from**, which
  happen to be the same shape. It replaces two placeholders: the SwiftPM
  executable's `exec` tile in the Dock, and the system's
  `rectangle.topthird.inset.filled` in the menu bar — accurate, and
  indistinguishable from every other rectangle up there.
- **Both are drawn, not stored.** `Scripts/icon/draw-mark.swift` is where the
  letter's geometry lives and `Scripts/make-icon.sh` turns it into the icon, so
  changing the weight of the letter is a line and a re-run rather than a round
  trip through an image editor. The menu-bar mark is drawn at whatever size
  AppKit asks for, because the menu bar's height is not a constant.
- **The warning state is the same mark with a dot**, rather than a different
  symbol. An icon that changes shape when something is wrong reads as a
  different application, and the operator has to learn two silhouettes instead
  of noticing one dot.

### The icon is glass the system draws, not a picture of glass

- **The icon is an Icon Composer document**, `Sources/uDeck/Support/uDeck.icon`
  — a JSON file and two SVGs. macOS draws the tile, its thickness, the light
  along the top edge and the shadow under the mark, and derives six appearances
  from the one document: light, dark, two clear and two tinted. A painted icon
  can only ever be one of those six.
- **Written as text, not in a window.** Icon Composer is a GUI application, but
  it ships `ictool`, which renders any appearance from the command line, and
  `actool` compiles the document into what a bundle carries. Nothing about the
  icon has to be opened in an editor to be changed or reviewed.
- **A painted tile was paying for a border twice.** Measured: macOS composites
  its own tile behind any `.icns`, scales the artwork to 80.5% of the canvas and
  masks it with its own corner radius — so the tile and lit edge we drew sat
  just inside the system's own. A fully transparent source comes back on that
  same tile, which is why "no tile at all" was never available.
- **The mark is an outlined path rather than a stroke.** As an SVG stroke, the
  letter's counter filled in when the system derived the dark appearance and ū
  became a blob. `draw-mark.swift` states the geometry once and converts the pen
  stroke into an outline, which every appearance reads the same way.
- **The tile is `#1A2A3E`, and the number is load-bearing.** The dark appearance
  repaints a white mark, and how it repaints it depends on how light the tile is:
  above roughly `#223650` the letter takes the tile's own colour and goes muddy
  against near-black, below it the letter stays white. The blue is the deepest
  one that keeps a white ū in the dark.
- **Two files are committed, both built by `Scripts/make-icon.sh`.**
  `Assets.car` is what macOS 26 and later read; `uDeck.icns` is the same icon
  flattened, for macOS 14 through 25. An ordinary build needs neither Xcode nor
  a rendering step.

## [0.2.1] — 2026-09-10

The first update anybody can install, and the screen it is installed from.

There is no 0.2.0. Its tag was pushed against a commit whose `Info.plist` still
said 0.1.0 — the version bump had been written and then lost to a failed script
— and the release refused to build, which is the whole reason that check is the
first step. The number is skipped rather than the tag moved: a tag that has
been pushed means one commit forever, even when nothing consumed it.

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
