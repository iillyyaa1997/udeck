# Contributing to uDeck

Thanks for looking. This is a small project with a clear shape, so the most
useful thing you can do before writing code is to check that what you have in
mind fits it.

## The shape

**Everything the operator sees is a plugin.** The application is a shell: a
window, tabs, a grid, settings and a plugin runtime. If you are adding a
feature, the first question is whether it belongs in the shell at all or whether
it is a plugin — and the answer is usually "a plugin". Features that ship inside
uDeck itself have to earn it by being something no plugin could do.

**The plugin contract is public and versioned.** Other people's plugins depend
on it. See [docs/plugin-api.md](docs/plugin-api.md#versioning) for what `api: 1`
promises. A change that would break a plugin written today needs a very good
reason and a new contract version.

**Logic lives in `UDeckCore`, which has no AppKit.** The interesting decisions —
geometry, the pointer gesture, the panel's states, the grid, the card format —
are all in there precisely so they can be tested without a window server. If you
find yourself putting a decision in a view or in a window controller, it
probably belongs one layer down.

## Getting started

```sh
swift build          # builds
swift test           # runs the tests
.build/debug/uDeck   # runs it; the binary is already a menu-bar app
```

macOS 14 or later. Xcode is not required to build, but the Swift toolchain that
ships with it is the one this is developed against.

## What a good change looks like

* **A test for anything with a decision in it.** The pointer gesture is driven
  by a fabricated event stream; the geometry is checked against the two real
  screens it was designed for; the plugin runtime runs the real fixture plugins
  in `examples/`. Follow whichever of those fits.
* **Comments that say why, not what.** Several things in this codebase look
  wrong until you know what broke without them — the keep-alive region reaching
  into the menu bar, the runtime calibration of mouse deltas, the process-tree
  kill. Each of those carries the reason next to it. Please keep that up.
* **No new configuration constants in the middle of code.** Numbers that a
  person might reasonably want to change live in `Configuration/` with a
  documented default.
* **Errors that say what to do.** "Could not load plugin" is not good enough;
  "`run.sh` is not executable — try chmod +x" is.

## What to avoid

* Silent failure. No empty `catch`, no `try?` that discards something the
  operator needed to know.
* Anything that makes the panel close itself while somebody might be typing in
  it. This is the one bug class that would make uDeck untrustworthy for its main
  job, and there are tests guarding it.
* Asking macOS for a permission. uDeck currently needs none, and that is a
  feature. If a change needs one, it has to be optional and attached to exactly
  one thing.

## Commits and pull requests

* One logical change per commit, with a message that explains the reasoning
  rather than restating the diff.
* Run `swift test` before pushing.
* Describe what you verified by hand — especially for anything touching the
  window, since much of that cannot be unit-tested.

## The contributor licence agreement

Contributions are accepted under the CLA in [docs/cla.md](docs/cla.md). It is
short: you keep the copyright in your work, and you grant the project a licence
broad enough to keep distributing it and to relicense it later if that becomes
necessary.

Until the CLA bot is installed, say in your pull request that you have read
`docs/cla.md` and agree to it. Once the bot is set up it will ask you on your
first pull request instead.

## Reporting a bug in the panel itself

The panel's behaviour depends on your screen arrangement, on how your pointer
reports movement, and on what else is on screen. None of that is visible from a
screenshot, so please include the output of **Copy diagnostics** in uDeck's
menu-bar menu.
