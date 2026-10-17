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

**"Verified" in the plugin catalogue** means the folder on disk is exactly what
was merged into the official repository's `main` — a maintainer read it before
merging: installed from there, or installed from a branch or a pull request
whose folder was then merged unchanged, which uDeck tells by the folder's git
tree being the one `main` has, and records as `main`'s without downloading
anything. It is the strongest thing uDeck can honestly say about a plugin, and
it does not mean safe. A plugin installed from anywhere else, or changed on
disk, carries no such mark; one installed from a branch or a pull request of
the official repository, or from a branch of a fork of it — **Install from a
link…** — says **Unverified** in
Settings and on its card until that, and asks before it runs whenever its
content changes.

If you would not run a stranger's shell script, do not install a stranger's
plugin.

### What that means for what we will fix

In scope, and treated as vulnerabilities:

- anything letting a plugin get past a gate uDeck does claim to enforce — an
  action running without its `exec` grant, a plugin launching while its
  capabilities are declined, or code nobody verified — a copy from a branch, a
  fork's branch or a pull request — running on a decision made for other
  content, or before
  you were asked about it (a change counts from when the folder watcher
  reports it, once writes in the folder pause — under a second after one
  write, as measured in the lab);
- uDeck installing plugin files other than the ones the official repository
  — or the fork a branch is in — lists at the commit it showed — a file that
  does not match its hash, a folder that does not add up — or marking a plugin
  **Verified** that is not exactly what was merged, a pull request's or a
  fork's copy included; or reading a repository that is no fork of the official
  one past its description;
- a plugin updating itself when it should only have been offered: a new version
  asking for different permissions than the installed one, a copy that was not
  **Verified** — a new head of the branch or the pull request it came from
  included — one you kept at an earlier version, one holding a file of yours,
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
  `raw.githubusercontent.com`, anonymously, for `iillyyaa1997/udeck-plugins`: a
  few seconds after launch unless it was read in the last 24 hours, once a day
  while uDeck runs, when Settings → Plugins is opened on a list more than an
  hour old, when you press Check now, and the plugin's files when you press
  Install, Update, Reinstall, Back to or Switch to verified or pick an earlier
  version, the pull request or the branch a link names when you press Look up in
  Install from a link… — for a branch of another repository on github.com, first
  whether it is a fork of `iillyyaa1997/udeck-plugins`, and then, only if it is,
  everything after this of the fork itself — its head, its listing and the
  manifests there that are not the catalogue's — in each read, the pull request
  or the branch a plugin installed from one came from, a fork's of the fork,
  unless `main` has it as it is — and, once its head moved, that head's listing
  and the plugin's manifest there, and one comparison with what is installed
  when the plugin changed there — and once it is merged into `main` the listing
  of the commit it was merged as, none of it in a read nobody asked for once
  fewer than ten of the hour's requests are left — and, after a read, the files
  of a **Verified** plugin whose new version asks for exactly the permissions it
  asks for now: such a plugin updates itself, keeping your permission decision.
  Anything else is only offered. Off with Settings → Plugins → *Update verified
  plugins by themselves*, after which every update waits for a press; all of it
  off with Settings → Plugins → *Official catalogue*, after which uDeck makes no
  request about plugins at all.

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
