# Changelog

All notable changes to uDeck are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

The **plugin contract** is versioned separately from the application, by the
`api` field in a plugin manifest. See `docs/plugin-api.md` for what that promises.

## [Unreleased]

### Added

- **The panel.** A non-activating `NSPanel` hanging below the menu bar at the
  top centre of whichever screen the cursor is on, with four states — a pill, a
  peek, a working panel and fullscreen — and the pointer gesture that opens it.
  It retracts when another application is activated, and comes back as it was
  when the interruption is over.
- **Tabs and the 12-column grid.** Windows are dragged by their title bar and
  resized from a corner, in whole cells; neighbours make room and everything
  settles upward. The arrangement is a file, so it survives a restart.
- **Card rendering** for all seven row types, three densities, and the glass
  look, with staleness drawn rather than described.
- **The empty state**, which is what an install with no plugins shows.
- **A settings window**: how the panel opens, density, and — the largest part —
  what is installed, what each plugin asked for, and the settings each plugin
  declared, rendered by the host so no plugin has to ship a settings screen.
- **Logging** through the unified logging system, so the gate that stopped a
  gesture or the reason a panel closed can be read after the fact:
  `log stream --predicate 'subsystem == "place.unicorns.udeck"' --level debug`.

- **Core model** (`UDeckCore`) — screen and panel geometry, the pointer-gesture
  recognizer, the four panel states, the 12-column grid, the plugin manifest and
  card formats, the permission model, and the on-disk stores. Foundation only,
  no AppKit, so all of it is tested without a window server.
- **Plugin runtime for `poll` producers** — discovery from `~/.udeck/plugins/`,
  a host-enforced deadline, an output cap, and a legible failure for every way a
  producer can fail.
- **The bundled plugin, "Claude sessions"** — how many Claude Code sessions are
  alive on this machine and how many are waiting for the operator, read from the
  status lines, the lease registry and the process list, with liveness decided
  from three sources because none of them is sufficient alone.
- **Documentation**: the [plugin contract](docs/plugin-api.md), a README, a
  contributing guide and a contributor licence agreement.
- **CI** on GitHub Actions: build, the Swift tests, and the plugin's own tests.
- **Example plugins** in `examples/`: `hello-card` (every row type),
  `slow-plugin` (hangs on purpose) and `broken-card` (prints something that is
  not a card). They are the test fixtures as well as the documentation.
