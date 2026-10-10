# Security

## Reporting a vulnerability

Please report privately, through
[GitHub's security advisories](https://github.com/iillyyaa1997/udeck/security/advisories/new),
rather than in a public issue. There is no bounty and no formal response time —
this is a one-person project — but reports will be read and acted on.

## The trust model, stated plainly

uDeck runs plugins. A plugin is an ordinary executable that uDeck launches **as
you**, and uDeck is **not sandboxed** — it cannot be, because plugins are
expected to run commands. So:

**Installing a plugin is exactly as dangerous as running the program it
contains.** There is no sandbox. A plugin's manifest declares what it intends to
use, uDeck shows you that before running it, and uDeck will not start it until
you agree — but a permission is a declaration, not a restriction. Nothing
constrains the program once it is running: it can read your files, run commands
and reach the network whether or not it declared any of that.

What uDeck genuinely controls is what uDeck itself does on a plugin's behalf:

- a card's action button is run by uDeck, and refused when that plugin was not
  granted `exec` for that command;
- a plugin whose declared capabilities you decline is never launched;
- uDeck hands plugins **no secrets**. A manifest can declare one it would like
  (`secrets`), and you are asked about it like any other permission, but this
  version of uDeck delivers none — a plugin that needs a token has to get it
  itself, with everything that implies;
- a plugin's environment is built by uDeck, not inherited, so nothing in the
  shell that started uDeck reaches it.

**"Verified" in the plugin catalogue** means the plugin was installed from the
official repository's `main` and the folder on disk is still exactly what was
merged there — a maintainer read it before merging. It is the strongest thing
uDeck can honestly say about a plugin, and it does not mean safe. A plugin
installed from anywhere else, or changed on disk, carries no such mark.

If you would not run a stranger's shell script, do not install a stranger's
plugin.

### What that means for what we will fix

In scope, and treated as vulnerabilities:

- anything letting a plugin get past a gate uDeck does claim to enforce — an
  action running without its `exec` grant, a plugin launching while its
  capabilities are declined;
- uDeck installing plugin files other than the ones the official repository
  lists at the commit it showed — a file that does not match its hash, a folder
  that does not add up — or marking a plugin **Verified** that is not exactly
  what was merged;
- a plugin updating itself when it should only have been offered: a new version
  asking for different permissions than the installed one, a copy that was not
  **Verified**, one you kept at an earlier version, one holding a file of yours,
  or with **Update verified plugins by themselves** switched off — or an update
  carrying your permission decision to a version that asks for more;
- a plugin escaping its folder: `run` resolving outside it, a manifest reading
  or writing files uDeck opens on its behalf outside the declared scope;
- a malformed manifest or card crashing or hanging uDeck, since a hung host
  stops reporting the things you rely on it to report;
- uDeck itself leaking something: writing a plugin's data somewhere unexpected,
  passing its own environment through to a plugin, logging card contents.

Out of scope, because it is the design:

- a plugin you installed and permitted doing something its manifest did not
  mention. That is not a bypass; there is no wall there. See above.

## What uDeck connects to

uDeck makes network requests of its own for two things, both on from the first
launch and both with a switch to turn them off:

- **its own updates** — Sparkle asks
  `https://github.com/iillyyaa1997/udeck/releases/latest/download/appcast.xml`
  after launch when it has not asked in the last day, then once a day; an update
  is downloaded only when you press Install. Off with Settings → About → *Check
  for updates automatically*.
- **the official plugin catalogue** — `api.github.com` and
  `raw.githubusercontent.com`, anonymously, for
  `iillyyaa1997/udeck-plugins`: a few seconds after launch unless it was read in
  the last 24 hours, once a day while uDeck runs, when Settings → Plugins is
  opened on a list more than an hour old, when you press Check now, and the
  plugin's files when you press Install, Update, Reinstall or pick an earlier
  version — and, after a read, the files of a **Verified** plugin whose new
  version asks for exactly the permissions it asks for now: such a plugin
  updates itself, keeping your permission decision. Anything else is only
  offered. Off with Settings → Plugins → *Update verified plugins by
  themselves*, after which every update waits for a press; all of it off with
  Settings → Plugins → *Official catalogue*, after which uDeck makes no request
  about plugins at all.

Neither carries an account, an identifier, a cookie or the list of what you
have installed. The details are in [README.md](README.md#what-udeck-connects-to-and-when)
and [docs/plugin-repository.md](docs/plugin-repository.md#what-udeck-fetches-and-when).
Plugins make whatever connections their authors wrote; see above.

## Signing

Builds are ad-hoc signed and not notarised. A downloaded build will be refused
by Gatekeeper on first launch. If you did not build it yourself and cannot
verify where it came from, do not run it.

## Supported versions

The most recent release, and `main`. There are no long-term support branches.
