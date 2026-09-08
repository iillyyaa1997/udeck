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
contains.** A plugin's manifest declares what it intends to use, uDeck shows you
that before running it, and uDeck will not start it until you agree. None of
that constrains the program once it is running. It can read your files, run
commands and reach the network whether or not it declared any of that.

What uDeck genuinely controls is what uDeck itself does on a plugin's behalf:

- a card's action button is run by uDeck, and refused when that plugin was not
  granted `exec` for that command;
- a secret is handed over by uDeck, or not at all;
- a plugin whose declared capabilities you decline is never launched.

If you would not run a stranger's shell script, do not install a stranger's
plugin.

### What that means for what we will fix

In scope, and treated as vulnerabilities:

- anything letting a plugin get past a gate uDeck does claim to enforce — an
  action running without its `exec` grant, a secret reaching a plugin that was
  not granted it, a plugin launching while its capabilities are declined;
- a plugin escaping its folder: `run` resolving outside it, a manifest reading
  or writing files uDeck opens on its behalf outside the declared scope;
- a malformed manifest or card crashing or hanging uDeck, since a hung host
  stops reporting the things you rely on it to report;
- uDeck itself leaking something: writing a plugin's data somewhere unexpected,
  passing its own environment through to a plugin, logging card contents.

Out of scope, because it is the design:

- a plugin you installed and permitted doing something its manifest did not
  mention. That is not a bypass; there is no wall there. See above.

## Signing

Builds are ad-hoc signed and not notarised. A downloaded build will be refused
by Gatekeeper on first launch. If you did not build it yourself and cannot
verify where it came from, do not run it.

## Supported versions

The most recent release, and `main`. There are no long-term support branches.
