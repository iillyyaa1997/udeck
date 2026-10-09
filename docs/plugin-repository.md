# Plugin repositories

This is the specification for how plugins reach uDeck from a repository: the
format every plugin repository shares, the two manifest fields that give
versions and compatibility a meaning, the catalogue uDeck shows, and what
installing, updating and removing a plugin does on disk. What a plugin *is* —
what it prints, how it is run, what it may ask for — is
**[the plugin contract](plugin-api.md)**, and this document changes it only
where it says so.

One thing does not change at all: **on disk, a plugin is still one folder,
`~/.udeck/plugins/<id>/`.** A folder copied in by hand keeps working exactly as
it does today. What is new is where folders can come from, and a record of
where each one came from.

---

## What is built now, and what is not

uDeck gets this in five stages, each of which ships something that works on its
own (see [Stages](#stages)). **Everything in this document without a mark is
stage 1 and is being built now.** Anything that belongs to a later stage is
marked where it appears:

> **Later — stage 3.** Text like this describes something that is not built
> yet.

Later stages are written down so that stage 1 does not close a door they need —
a field reserved in a file, a rule that has to hold from the first plugin
published — not as work for stage 1.

Where this document says **measured**, it was measured on 2026-09-28 against
github.com. Where it says **by memory**, it was not checked and the first
builder to touch it confirms it.

---

## The whole path, in one paragraph

A plugin repository is a GitHub repository (later also GitLab) with a small
file at the top, `udeck-plugins.json`, and one folder per plugin under
`plugins/`. uDeck builds its catalogue by listing the repository's files at one
commit and reading each plugin's `manifest.json` — nothing else is downloaded
until somebody presses **Install**. Installing downloads exactly that plugin's
files at that commit, checks every file against the hash the repository listed
for it, checks the folder with the same code that checks a folder dropped in by
hand, and swaps it into `~/.udeck/plugins/<id>/` in one step.
`~/.udeck/installed.json` records where it came from. Whether the plugin has
changed since is a comparison of two hashes and costs no download.

There is no index file to publish and no release step: the repository *is* the
index, and a pull request merged into the default branch is published.

---

## A plugin repository

Every repository uDeck reads has the same format — the official one,
somebody's own, public or private. A person who can write one plugin folder can
write a repository, and a repository that works on GitHub will work on GitLab
unchanged.

### Layout

```
udeck-plugins.json          the repository's passport — see below
README.md                   for people; uDeck never reads it
plugins/
  uptime/
    manifest.json
    manifest.ru.json
    README.md
    LICENSE
    uptime.sh
  another-plugin/
    …
```

Plugins live **directly** under `plugins/`, one level deep. Not
`plugins/<group>/<id>/`: the folder on a machine is flat — every window, grant
and setting is keyed by the bare id — and a repository that grouped its plugins
would be describing a layout no machine has.

Everything else at the top of the repository — a licence, `CONTRIBUTING.md`,
`.github/`, `.gitlab-ci.yml`, scripts — is the repository's own business. uDeck
never reads it and never downloads it.

### `udeck-plugins.json`

```json
{
  "format": 1,
  "name": "uDeck plugins",
  "description": "Plugins for uDeck. Everything merged here was read by a maintainer first."
}
```

| Field | Type | Required | Meaning |
|---|---|---|---|
| `format` | integer | yes | The version of the repository format this document describes. Currently `1`. |
| `name` | string, 1–64 characters | yes | What uDeck calls the repository in its catalogue and, later, in the "Trusted source" mark. |
| `description` | string, up to 280 characters | no | Shown under the name. |

There is no index, so why a file at all? Because it is what tells uDeck that a
repository was *meant* to be a plugin repository, rather than being any
repository that happens to have a `plugins` folder — and because it is the one
place a future change of format can be announced before uDeck misreads it.

`format` and a plugin's `api` are independent numbers. `format` is how the
repository is laid out; `api` is the contract between one plugin and uDeck. A
format-1 repository can hold plugins of any `api`.

What uDeck does with the file:

* **Missing, or not valid JSON, at the commit being read** — the repository is
  refused as a whole: *"github.com/owner/repo is not a uDeck plugin repository:
  there is no udeck-plugins.json at the top of main."*
* **`format` higher than uDeck knows** — refused as a whole, naming both
  numbers, the same way a manifest's `api` is refused. Guessing at a layout
  from the future is how files end up installed from the wrong place.
* **A field it does not know** — ignored. The repository check (below) reports
  it, because an unknown field in a hand-written file is usually a typo.
* **Larger than 64 KiB** — refused as a whole, before a byte of it is read as
  JSON: *"github.com/owner/repo has a udeck-plugins.json that uDeck cannot
  read: it is 70000 bytes, and a passport may be at most 64 KiB (65536
  bytes)."* A passport is three short fields — a name of at most 64 characters
  and a description of at most 280 — and even with every character written as
  a `\u` escape pair and indented generously it stays under 8 KiB; 64 KiB is
  eight times that. uDeck reads the catalogue on its main thread, and how long
  that takes must not be up to what a repository puts in the file. The
  repository check refuses it too, in every layer.

### A plugin's folder

A plugin's folder in a repository is exactly the folder that will sit in
`~/.udeck/plugins/<id>/` on the machine: the same `manifest.json`, the same
producer, the same translations, as the [plugin contract](plugin-api.md)
describes. Nothing is added to it on the way, and nothing in it is specific to
the repository.

| File | Required | Why |
|---|---|---|
| `manifest.json` | yes | As in the contract. `id` equals the folder name; `version` is `MAJOR.MINOR.PATCH` — see [Versions](#versions-and-compatibility). |
| The producer | yes, when `run[0]` is a relative path | Committed as executable (git mode `100755`). The executable bit travels through git, and uDeck restores it on install. |
| `README.md` | yes | What the card shows, what the plugin needs on the machine, what it runs. It is what a reviewer and an installer read first. |
| `manifest.<lang>.json` | recommended | A plugin with none still installs; the repository check warns. |
| `LICENSE` | in the official repository | See [The official repository](#the-official-repository). Elsewhere, the repository owner's choice. |

**A plugin is self-contained.** Only its own folder is installed. A script that
sources `../common/lib.sh` works in the repository and fails on every machine,
so there is no such thing as code shared between plugins — copy it.

### What a folder may contain

Two different places enforce these rules, for two different reasons. **uDeck**
refuses, at install time, what would make an installed folder unsafe,
different from what the repository says it is, or impossible to update — a new
path, so these refusals take nothing away from any folder that works today.
**The repository check** — run in the repository's CI — refuses that too, and
also what makes a plugin hard to review or likely to break. uDeck only ignores
or notes those: the `api: 1` promise forbids it to start refusing a manifest it
used to accept, and a repository's CI is under no such promise.

| # | Rule | uDeck, at install | Repository check |
|---|---|---|---|
| 1 | Plugins sit directly under `plugins/`, and each folder's name is a valid plugin id (`^[a-z0-9][a-z0-9._-]{0,63}$`). | not installable | error |
| 2 | Nothing but folders directly inside `plugins/`. | ignored | error |
| 3 | `manifest.json` is present, decodes, its `id` equals the folder name, and it has no manifest problems. | refused | error |
| 4 | `version` is `MAJOR.MINOR.PATCH`; so is `minUDeck` when present. | refused | error |
| 5 | A relative `run[0]` names a file inside the folder that is committed as executable (`100755`). | refused | error |
| 6 | Only files and folders: no symbolic links (mode `120000`), no submodules (mode `160000`). | refused | error |
| 7 | Every file and folder name uses only `A–Z a–z 0–9 . _ -`, does not start with `.`, is at most 255 bytes, and no two names in one folder differ only in letter case. | refused | error |
| 8 | At most 200 files, 10 MiB in total, 5 MiB for any one file, folders nested at most 8 deep. | refused | error |
| 9 | No Git LFS pointer files; no `export-ignore`, `export-subst` or `filter` attribute applies to anything under `plugins/`. | refuses LFS pointers (it cannot see attributes) | error |
| 10 | `README.md` in the folder. | — | error |
| 11 | At least one `manifest.<lang>.json`. | — | warning |
| 12 | No field in `manifest.json` or in a translation that the contract does not define — `restart` included. | ignored (`restart` is decoded) | error |
| 13 | An executable file contains no carriage return (`\r`). | — | error |
| 18 | Whenever anything in a plugin's folder changed, its `version` went up. | — | error, given a base to compare with |
| 19 | `minUDeck` is not below the uDeck release that has everything the plugin uses. | — | error; a `minUDeck` that does nothing is a warning |
| 20 | `name` and `description`, in `manifest.json` and in every translation, are one line each: no control character (C0, DEL, C1) and neither U+2028 nor U+2029. | — | error |

Why each of the less obvious ones:

* **Links (6)** are paths that can be repointed after somebody read them, and a
  link out of the folder reaches the rest of the disk. A submodule is a pointer
  to another repository, not content: uDeck would install nothing.
* **Names (7).** A name starting with a dot is how macOS litters a folder —
  `.DS_Store` appears the moment somebody opens it in Finder — and uDeck
  ignores dot-names when it hashes an installed folder (see
  [Git's two hashes](#gits-two-hashes-computed-by-udeck)), so they must not
  carry anything. The default macOS volume is case-insensitive: `Run.sh` and
  `run.sh` are two files in git and one on the Mac. Non-ASCII names are stored
  in different Unicode forms by different volumes, and a name that changed
  bytes on disk no longer matches its hash. Spaces and shell characters in
  names are bugs waiting in every script that forgets to quote.
* **Limits (8).** A plugin is a producer and its data, not a package manager.
  Each file is one download, and a plugin of three hundred files is a plugin
  that should be something else.
* **LFS and attributes (9).** An LFS file is stored in the repository as a
  three-line pointer, and uDeck would install the pointer. The export
  attributes change what an *archive* of the repository contains without
  changing the repository, so a GitLab archive (stage 4) would disagree with
  the tree it came from.
* **`restart` (12).** uDeck's decoder reads it — for resident plugins, which
  no uDeck runs yet — and the contract ([plugin-api.md](plugin-api.md)) does
  not describe it. So uDeck installs a plugin with a whole `restart` and
  refuses one whose `restart` does not decode (rule 3, in every layer), and the
  strict check calls the field what it calls any field outside the contract.
  The day the contract describes it, it leaves rule 12 and joins the release
  registry with the release that does.
* **Carriage returns (13).** A script saved with Windows line endings fails on
  a Mac with *bad interpreter: /bin/sh^M*, which nobody reading the card will
  guess.
* **Versions go up (18).** A version names one content wherever it is
  installed from: "1.2.0" on one machine is "1.2.0" on every other, and uDeck's
  **Earlier versions** keeps one entry per version. Which plugins changed is
  read against where the change branched off; the new version is held to the
  target branch's tip, so that of two pull requests that both take a plugin to
  1.1.0, the second to be checked against the tip that has the first goes on to
  1.1.1. A new plugin needs no more than a version that parses. The version is
  read as uDeck reads it, by uDeck's own decoder — a manifest the strict reader
  refuses and uDeck installs (a byte order mark, `1e400` in a field nobody
  reads) is held to the rule all the same; one uDeck cannot read at all is rule
  3's error already.
* **`minUDeck` (19).** Worked out from what the manifest and its translations
  use, dated by the registry of which release first had each part of the
  contract. Declared lower, it lets an older uDeck install a plugin it cannot
  run; left out when it is needed, the same. Declared no higher than the
  release that first reads the field, it does nothing — every uDeck that reads
  it meets it — and the check says it can go. Declared higher than the plugin
  needs, it is the author's call: something changed in how uDeck behaves that
  no part of the contract names, and the check leaves it alone.
* **One line (20).** A name and a description are what a catalogue row, the
  plugin list and the consent sheet show, each on its line; a line break
  splits it, and an escape sequence acts on whatever terminal prints the name
  — a CI log, `udeck-plugin` itself. uDeck loads such a manifest as it always
  has — the `api: 1` promise holds it to that — so the check is what keeps one
  out of a repository. The characters are listed in
  [One line](plugin-api.md#one-line).

### The check

`udeck-plugin check-repo` checks a repository and `udeck-plugin check` one
plugin folder, built from the library uDeck itself runs, `UDeckPluginFormat`.
Three layers, each the one before and more:

| Flags | Rules | Meaning |
|---|---|---|
| none | the passport, 1, 3–8, LFS pointers (9) | uDeck will install it — decided by the code uDeck runs when it lists a catalogue and installs |
| `--strict` | also 2, the attributes of 9, 10–13, 19, 20, fields the passport does not define, and JSON read strictly: no field twice, no byte order mark, a whole number written as one | the rule for any repository's CI |
| `--official` | also 14–16, and 17 with `--base` and `--head` | the official repository |

`--base <target branch's tip> --head <commit>` adds rule 18, in any layer, and
rule 17 with `--official` — only there: the sign-offs are the official
repository's rule, not something a base brings. Without them `check-repo`
compares versions with the commit before `HEAD`, which on a branch that is
only ever squash-merged into is the branch as it was.

Rule 18 needs history, and a CI checkout has one commit unless told otherwise.
What the clone lacks is said, never passed, and a strict check — `--strict`,
and so `--official` — does not pass what it could not check. Without `--base`,
a `HEAD` whose parent the clone left out gets a warning — *"rule 18 not
checked: HEAD has no parent here — fetch history (fetch-depth: 2 or 0)"* — and
in a strict check an error: *"rule 18 not checked: HEAD has no parent here,
and a strict check does not pass what it could not check — fetch full history
(fetch-depth: 0 on GitHub, GIT_DEPTH: 0 on GitLab)"*. A first commit, which
has no parent anywhere, gets nothing in either. With `--base`, a base whose
history does not meet the head's in the clone is an error in every layer —
*"cannot compare with origin/main: no common history here — fetch full history
(fetch-depth: 0 on GitHub, GIT_DEPTH: 0 on GitLab)"* — rather than every
plugin looking changed. A base a shallow clone does not hold at all is, in a
strict check, an error of rule 18 too — *"rule 18 not checked: origin/main is
not in this clone, which is shallow, …"* — and of rule 17 with `--official`;
outside a strict check it is a check that could not be made, exit status 2, as
is a base that a clone with its whole history does not have. A clone without
blobs (`filter: blob:none`) has every commit and tree and only the files it
checked out, and the check fetches nothing: a manifest the base lists and the
clone does not hold is an error too — *"cannot compare with origin/main:
plugins/uptime/manifest.json is not in this clone — fetch without a blob
filter"* — rather than the plugin passing as new. Any other file the check
must read and the clone does not hold, the passport first, makes it exit 2:
the check could not be made.

A repository is read through git at one commit, never through its working
tree. One plugin folder is read the same way when it is committed in a git
working copy — and the check says when the working copy holds changes it did
not see, counting a file's executable bit only where git does (not with
`core.fileMode` false) — and from disk when it is not, where there are no
attributes. A link
to a folder is followed, and the findings name the path as it was given: a
folder linked into uDeck's plugins folder is such a link. Exit status: 0 when
there are no errors (warnings do not fail the check), 1 when there are, 2 when
nothing could be checked.

#### Where the command comes from

The command a repository's CI runs is published with uDeck, in the same
release and under the same version — `udeck-plugin --version` says the
release's number, and a release whose command says another is not made. Every
release from 0.6.1 on carries, besides uDeck itself:

| Asset | What it is |
|---|---|
| `udeck-plugin-X.Y.Z-macos-universal.tar.gz` | arm64 and x86_64 in one binary, signed as the copy inside uDeck.app (ad-hoc, hardened runtime) — for a Mac without uDeck, and a macOS runner |
| `udeck-plugin-X.Y.Z-linux-x86_64.tar.gz`, `-linux-aarch64.tar.gz` | a static musl binary, stripped: no dynamic loader, no shared library — any Linux of its architecture runs it with nothing installed |
| `SHA256SUMS` | the sha256 of the three archives and of the two files below |
| `udeck-plugin-image.txt` | the container image: `image=ghcr.io/iillyyaa1997/udeck-plugin`, `tag=vX.Y.Z`, `digest=sha256:…` (of the index), `platforms=linux/amd64,linux/arm64` — the digest is also in the release's notes, on their third line |
| `udeck-plugin-image-sources-X.Y.Z.tar` | the source of every Alpine package in the image under the GPL or the LGPL: one folder with each package's folder of Alpine's aports at the commit it was built from, the upstream archives its APKBUILD names, a README that lists the packages, and `SHA512SUMS` |

Each archive is one folder, `udeck-plugin-X.Y.Z-<platform>/`, with the
command, `LICENSE`, `NOTICE` and `THIRD_PARTY_NOTICES` — what else the
command is made of (on Linux, statically: Swift's runtime and Foundation,
swift-crypto and its BoringSSL, LLVM's libc++, musl, fts and mimalloc) and
under what licences. The image is Alpine, pinned by digest, with git, curl and
the same static binary at `/usr/local/bin/udeck-plugin`, and no `ENTRYPOINT`:
GitLab CI hands a job's script to the image's shell, the check starts git, and
`pin` curl. Its `/usr/share/licenses/udeck-plugin/` holds the same three texts and
`ALPINE-PACKAGES`: every Alpine package in it — git and BusyBox among them,
under the GPL — with its version, its licence and its folder in aports at the
commit it was built from; its `org.opencontainers.image.licenses` label names
every licence there (a label of the image, not an annotation of the index:
ghcr.io refuses an index annotated with that expression). The source of every package there under the GPL or the
LGPL is the release's `udeck-plugin-image-sources-X.Y.Z.tar`, which
`ALPINE-PACKAGES` and `THIRD_PARTY_NOTICES` name: `make-cli.sh sources` reads
the list out of the image that ran, takes each package's aports folder by git
at its commit — so each file is the one that commit holds — and the upstream
archives its APKBUILD names from Alpine's distfiles, each held to the sha512
the APKBUILD gives, before the image is published. Pull it by its digest — a
tag can be moved, a digest cannot:

```sh
docker run --rm --network none -v "$PWD:/repo:ro" \
  ghcr.io/iillyyaa1997/udeck-plugin@sha256:<digest from udeck-plugin-image.txt> \
  udeck-plugin check-repo --repo /repo --strict
```

Read-only and without a network is how it is meant to run: the check needs
neither, and opens git's `safe.directory` for the mounted repository itself.
It does need history, and `--strict` requires it: rule 18 compares HEAD with
the commit before it, and on a clone that has only HEAD — what
`actions/checkout` fetches by default — `check-repo --strict` exits 1, *"rule
18 not checked: HEAD has no parent here, …"*; without `--strict` a warning
says so and the exit status is 0. GitLab CI fetches the last 20 commits of a
new project by default (its *Git shallow clone* setting, which the variable
`GIT_DEPTH` overrides): enough while the commit to compare with is among them,
and not for a merge request whose base is further back. Give
`actions/checkout` `fetch-depth: 0`, and set `GIT_DEPTH: "0"` in GitLab CI —
with `--strict`, the rule for any repository's CI, that is a requirement, not
advice. `--base` and `--head` choose which commit HEAD is compared with when
the clone holds it — the target branch's tip for a pull request — and do not
make up for history the clone lacks: a `--base` a shallow clone does not have
fails a strict check, exit status 1, and without `--strict` is *"not a commit
in … — a pull request's checkout needs fetch-depth: 0"*, exit status 2.

A repository of one's own starts from the [template
repository](https://github.com/iillyyaa1997/udeck-plugins-template): the
layout, the [lock file](#the-lock-file), and both CI files ready —
`.github/workflows/validate.yml` for GitHub Actions and `.gitlab-ci.yml` for
GitLab CI, with variables for a mirror and its login, and the proxy the runner
gives taken as it is. It has no plugin of its own: `udeck-plugin new` makes the
first.

Everything is made by `Scripts/make-cli.sh` and published by `release.yml` in
the one `gh release create` that publishes the app — uDeck's releases are
immutable, so a release cannot take an asset afterwards — with the image
pushed before it: built once from the same archives, pushed to a registry of
the release job's own, pulled from it by its digest and run on both
platforms (`--version`, `check` and `check-repo` on the examples, and `pin` on
a release on the image's own disk), its sources gathered, and only then copied
by that digest to ghcr.io, byte for byte. `ci.yml` does all of it on every
push — the sources downloaded afresh each time, with no cache, since a
release downloads them too; the copy to a second registry of the job's own,
which asks for a login as ghcr.io does — and writes the image file,
`SHA256SUMS` and the notes as a release does, then pins that release as a
plugin repository would and reads the lock file as its CI will, publishing
nothing.

#### The lock file

A plugin repository's CI runs one release of the command, and the repository
names it in `.github/udeck-plugin.lock`. The CI reads the file from the base
of the change it checks — the target branch, not the pull request — so that a
pull request cannot choose the check that judges it: a new lock file takes
effect once it is merged, as the official repository's check does today. On
GitLab the file is in the same place: `.github/` means nothing to GitLab, and
one place serves a repository kept on both, a template copied to either, the
`pin` that writes it and a Renovate rule that finds it.

Five lines, `key=value`, in this order:

```
version=0.6.0
macos-universal=<sha256 of udeck-plugin-0.6.0-macos-universal.tar.gz>
linux-x86_64=<sha256 of udeck-plugin-0.6.0-linux-x86_64.tar.gz>
linux-aarch64=<sha256 of udeck-plugin-0.6.0-linux-aarch64.tar.gz>
image=sha256:<the digest of the image's index>
```

| Key | Value |
|---|---|
| `version` | the release, `X.Y.Z`: three whole numbers of at most nine digits, none written with a leading zero, and no `v` |
| `macos-universal`, `linux-x86_64`, `linux-aarch64` | the archive's sha256 as the release's `SHA256SUMS` has it: 64 lowercase hexadecimal digits |
| `image` | the image's digest as `udeck-plugin-image.txt` has it: `sha256:` and 64 lowercase hexadecimal digits |

And nothing else: no comment, no blank line, no space anywhere, no byte order
mark, no carriage return, every line ending in `\n`, every key once. A lock
file is exactly what `udeck-plugin pin` writes, byte for byte, and anything
else is refused with what is wrong with it — so that a CI job can read it with
`sed`, never running it through `source`, and come to the answer
`udeck-plugin` comes to. That is why it is not JSON.

Where the files come from is not in it. The image is pulled as
`$UDECK_PLUGIN_REGISTRY/udeck-plugin@<image>`, the registry being
`ghcr.io/iillyyaa1997` unless a CI variable names a mirror; an archive is
downloaded from `$UDECK_PLUGIN_DOWNLOAD_BASE/v<version>/`, GitHub's
`https://github.com/iillyyaa1997/udeck/releases/download` unless a variable
names another place laid out the same way. The variable says where, the file
says what: a mirror that hands out other bytes makes the job red rather than
running them — as long as the file holds GitHub's sums. A lock file `pin`
wrote from a mirror holds the mirror's, whatever they are, so it is checked
against GitHub's release before it is merged ([`udeck-plugin
pin`](#udeck-plugin-pin)).

The [template
repository](https://github.com/iillyyaa1997/udeck-plugins-template)'s two CI
files go further than the snippets below. On GitLab CI a job's `image:` is
part of `.gitlab-ci.yml`, which a merge request brings, and cannot be read
from a file: there the digest is named a second time, in `.gitlab-ci.yml`. The
job holds the image `.gitlab-ci.yml` names for it (the digest at the end of
`CI_JOB_IMAGE`) and that image's `udeck-plugin --version` to a lock file, and
fails when they differ: to the base's; or, in a merge request that changes the
lock file, to the new one — and only after the base's `udeck-plugin` has held
the new one to its release and given its own verdict on the merge request.
That is its image mode, the default; on a shell executor, which runs no image,
`UDECK_PLUGIN_FROM` set to `archive` has it download the release's archive
instead. Whether a pull request changes the lock file is read out of git too:
the file it commits, not the checkout's, which a `.gitattributes` line can make
differ, and a checkout whose lock file is not the committed one is refused. A
mirror's login is never part of `UDECK_PLUGIN_DOWNLOAD_BASE`, which GitHub
shows in a job's log as it is, and the job refuses one there: it is a secret of
its own — on GitLab a masked variable, with variable expansion off — that the
job joins to the address only for curl and `pin`. A pull request that changes
the lock file is judged by the release the base names, and before the release
the new lock file names runs — on GitHub, before anything the new lock file
names is downloaded — the base's `udeck-plugin` holds the new lock file to its
release with `udeck-plugin pin --check`: to the mirror's, where there is one,
and to GitHub's wherever GitHub's releases answer. A job with a mirror first
asks whether they answer, for a release file at a fixed address that no lock
file chooses,
`https://github.com/iillyyaa1997/udeck/releases/download/v0.6.1/SHA256SUMS`,
which GitHub sends on, as every release file, to the host `pin --check`
downloads from too. There a lock file that is not what GitHub's release has is
refused, and so is a release GitHub does not have. A runner that does not reach
GitHub's releases has only the mirror, and trusts it, as a mirror is trusted:
the job warns, for the reviewer to check the lock file where GitHub can be
reached — on GitLab, once both checks have passed, with exit status 75, which
the job's `allow_failure: exit_codes` makes GitLab's warning — and on GitHub's
own runners, which always reach GitHub, it is an error instead. Once merged,
such a lock file is the base's, and no job holds it to GitHub's release again.
Either way the release the new lock file names runs last, once the base's
verdict is in and printed, from a folder of its own and held to its sha256
like any download; in GitLab's image mode it is the image's own, held to its
digest. It runs with the job's rights, as anything the job runs does: what it
is trusted on is that check of the lock file. On GitLab, on an executor that
runs an image, the job itself runs in the one the merge request names, its
shell and its curl too, so there the check is as sound as the registry that
image is pulled from.

This is how a CI job reads it: the five values by `sed`, then the file held
to the five lines they make, byte for byte. A test holds it to
`udeck-plugin`'s own reading on a corpus of good and bad files, run by `sh` and
by `bash`, with a Mac's sed and with GNU's:

<!-- lock-reader -->
```sh
# Reads a lock file as udeck-plugin reads it: the five lines `udeck-plugin pin`
# writes, byte for byte, or nothing. Sets version, macos_universal,
# linux_x86_64, linux_aarch64 and image; never runs the file.
read_udeck_plugin_lock() {
    udeck_lock_value() {
        LC_ALL=C sed -En "s/^$1=($2)\$/\\1/p" "$3"
    }
    version=$(udeck_lock_value version '(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})' "$1")
    macos_universal=$(udeck_lock_value macos-universal '[0-9a-f]{64}' "$1")
    linux_x86_64=$(udeck_lock_value linux-x86_64 '[0-9a-f]{64}' "$1")
    linux_aarch64=$(udeck_lock_value linux-aarch64 '[0-9a-f]{64}' "$1")
    image=$(udeck_lock_value image 'sha256:[0-9a-f]{64}' "$1")
    udeck_lock_expected=$(mktemp) || return 1
    printf 'version=%s\nmacos-universal=%s\nlinux-x86_64=%s\nlinux-aarch64=%s\nimage=%s\n' \
        "$version" "$macos_universal" "$linux_x86_64" "$linux_aarch64" "$image" > "$udeck_lock_expected"
    # Each value matched, and the file is the five lines they make: an empty
    # value is one that did not match, and a key twice gives two lines.
    if [ -n "$version" ] && [ -n "$macos_universal" ] && [ -n "$linux_x86_64" ] \
        && [ -n "$linux_aarch64" ] && [ -n "$image" ] && cmp -s "$1" "$udeck_lock_expected"; then
        rm -f "$udeck_lock_expected"
        return 0
    fi
    rm -f "$udeck_lock_expected"
    echo "$1 is not a lock file as udeck-plugin pin writes it; udeck-plugin pin --check says why" >&2
    return 1
}
```
<!-- /lock-reader -->

And with it, the Linux archive a job runs — the lock file read out of git at
the base, never from the checkout, which holds the pull request's:

```sh
# BASE_SHA: the commit the change is checked against, which the clone must
# hold. On GitHub Actions, for a pull request: the first parent of the merge
# actions/checkout checks out by default, refs/pull/N/merge — the target
# branch as GitHub merged the pull request into it, the base rule 18 needs.
# HEAD^1 is that commit only when HEAD is that merge, so the job checks the
# merge's second parent first, with PR_HEAD_SHA set from
# ${{ github.event.pull_request.head.sha }} in the step's env:
#
#   test -n "$PR_HEAD_SHA" &&
#     test "$(git rev-parse --verify --quiet 'HEAD^2^{commit}')" = "$PR_HEAD_SHA" ||
#     exit 1
#   BASE_SHA=$(git rev-parse --verify 'HEAD^1^{commit}')
#
# A checkout of the head itself — `ref:
# ${{ github.event.pull_request.head.sha }}` — has at HEAD^1 the commit
# before the head, which the pull request chose, and a checkout of the
# target branch, pull_request_target's default, has an older commit of the
# branch there; neither passes that check. A job that checks out anything
# but the merge takes ${{ github.event.pull_request.base.sha }} instead,
# which can lag behind the branch, so that rule 18 may compare with an older
# version than the branch has. For a push to the default branch,
# ${{ github.sha }}, whose lock file is the merged one. On GitLab CI, in a
# merge request pipeline, the target branch's tip, fetched by name — git
# fetch origin "+refs/heads/$CI_MERGE_REQUEST_TARGET_BRANCH_NAME", then
# FETCH_HEAD, with "$CI_MERGE_REQUEST_PROJECT_URL.git" in place of origin in
# a pipeline that runs in a fork — or $CI_MERGE_REQUEST_TARGET_BRANCH_SHA in
# a merged results pipeline; not $CI_MERGE_REQUEST_DIFF_BASE_SHA, where the
# merge request branched off, which rule 18 must not compare with. And
# $CI_COMMIT_SHA only in a pipeline of the default branch ($CI_COMMIT_BRANCH
# == $CI_DEFAULT_BRANCH), whose lock file is the merged one. A branch
# pipeline of a merge request's branch has no base to read it from — its own
# lock file would choose the check that judges it: run the check in merge
# request pipelines, not there.
lock="$(mktemp)"
git show "$BASE_SHA:.github/udeck-plugin.lock" > "$lock" || exit 1
read_udeck_plugin_lock "$lock" || exit 1
base="${UDECK_PLUGIN_DOWNLOAD_BASE:-https://github.com/iillyyaa1997/udeck/releases/download}"
archive="udeck-plugin-$version-linux-x86_64.tar.gz"
curl -fsSLO "$base/v$version/$archive"
echo "$linux_x86_64  $archive" | sha256sum -c -
tar -xzf "$archive"
```

A base with no lock file — before the first one is merged — has chosen no
release, and the job stops there. (The official repository's `validate` made
one exception, for the one pull request that brought its first lock file
together with the comparison of the two checks: the Python check from the base
was still the gate there, so that pull request's own lock file was used once,
with a warning in the log, and held to its release with `udeck-plugin pin
--check`. A repository whose CI runs only `udeck-plugin` has nothing to fall
back on.) `git show` needs the base in the clone, which is the history a strict
check requires for rule 18 as well (`fetch-depth: 0`, `GIT_DEPTH: "0"`). A login in `UDECK_PLUGIN_DOWNLOAD_BASE`
would be in this `curl`'s arguments, where every process on the runner can
read it; give it to curl another way there — `--netrc-file`, or a `--config`
on standard input, as `pin` does.

#### `udeck-plugin pin`

```sh
udeck-plugin pin                          # the latest release
udeck-plugin pin --version 0.6.0          # that one
udeck-plugin pin --check                  # is the lock file what its release has?
udeck-plugin pin --check --version latest # ... and is it the latest?
```

`pin` writes the lock file of the repository it is run in — the folder that
holds `udeck-plugins.json`, here or above — or of `--repo <path>`. It reads
the release's `SHA256SUMS` and `udeck-plugin-image.txt` and holds them to one
another before it writes anything: the image file exactly as a release writes
it (`image=…/udeck-plugin`, `tag=vX.Y.Z` of the release asked for, a whole
`digest=`, both platforms, nothing more), the sums one line for each of the
three archives, the image file and the image's sources and for nothing else,
and the image file the very one the sums name, by its sha256. Two files that
disagree are not two halves of one release, and nothing is written. A lock
file that is already what the release has is left untouched.

`--check` writes nothing. It exits 0 when the lock file is exactly what `pin`
would write for the release, and 1 when it is not, saying which line differs —
or when there is no lock file, or one that does not read. Without `--version`
it checks the lock file against the release it names, which a pull request's
CI can do without turning red the day uDeck releases again; `--version
latest` asks whether it is also the newest, which is what a scheduled job
wants. Exit status 2, for `pin` and `--check` alike, is a release that could
not be read: none there, a network that did not answer, two files that
disagree. Status 2 does not say which of them it was; a CI job that has to
tell a release GitHub does not have from a GitHub it cannot reach asks GitHub
first, as [the lock file](#the-lock-file) says, and wherever GitHub answers it
counts a 2 as a refusal.

A pull request that changes the lock file is judged by the base's, so the
release it names has not checked anything yet. CI holds the new lock file to
that release with `pin --check` before it is merged, and runs the release on
the pull request as well: the template repository's CI files as [the lock
file](#the-lock-file) says, and the official repository's as [its
CI](#the-official-repository) says, on the repository as the merge leaves it
too.

Renovate can notice a release and change the `version=` line. The four other
lines hang on that one version, and `pin` reads them from the release and holds
them to each other, which is simpler and surer than a pattern rule for each.
The template repository's `renovate.json5` has Renovate change `version=` and
run `udeck-plugin pin --version <new>` after it, where its admin allows the
command (`allowedCommands`) and `udeck-plugin` is on its `PATH`; Renovate that
runs no commands opens a pull request whose check fails until `pin` is run on
its branch. On GitLab, `.gitlab-ci.yml` names the image by the lock file's
digest too, and Renovate does not change it: copy the new digest into
`.gitlab-ci.yml` on the same branch, since in its image mode, the default, the
job fails while the two differ.

A release from before the command was published with uDeck's — 0.5.0 and
earlier — has neither file, and `pin` says so: *"release v0.5.0 has no
SHA256SUMS and no udeck-plugin-image.txt at …: uDeck 0.5.0 and the releases
before it were made before udeck-plugin was published with them"*.

**Where it reads from.** The latest release is GitHub's
`…/releases/latest/download/udeck-plugin-image.txt`, which says its version;
the sums are then read from that version's own folder, so a release published
between the two requests is a refusal, never a lock of two releases.
`UDECK_PLUGIN_DOWNLOAD_BASE` moves `pin` too: an `https://` or a `file://`
address laid out as GitHub's — `v<version>/` for each release, and
`…/latest/download/` beside a `…/download` for the latest — and never plain
`http://`, since `pin` writes what it reads into the file a CI trusts. It may
carry a login, `https://user:token@host/…`, as a private GitLab's generic
packages ask: `pin` says the address with the login as `***` wherever it says
it, and hands it to curl on standard input.

**A mirror is trusted for what it serves.** `pin` holds a release's two files
to each other, and two files a mirror serves can agree with each other and
not with anything GitHub published: a lock file written from a mirror holds
the mirror's sums, and a job that reads it later checks downloads against
those. So `pin` says so whenever it reads from anywhere but GitHub — *"note:
UDECK_PLUGIN_DOWNLOAD_BASE is https://\*\*\*@gitlab.example/udeck, not GitHub's
releases: the lock file holds what that place serves — check it against
GitHub's release with udeck-plugin pin --check, UDECK_PLUGIN_DOWNLOAD_BASE
unset, where GitHub can be reached"* — and a lock file written from a mirror
is checked that way, by a job that reaches GitHub or by its author, before it
is merged.

**How it reads.** With curl, the system's, started as `curl` on the `PATH`:
there on every Mac and every GitHub runner, and in the image. Curl takes its
proxy from the environment as its manual says — `https_proxy` or
`HTTPS_PROXY`, else `all_proxy` or `ALL_PROXY`, and `no_proxy` or `NO_PROXY`
for the hosts it reaches directly — so a runner that reaches GitHub only
through a proxy needs nothing but those variables. `pin` asks for nothing over
plain HTTP, so `http_proxy` and `HTTP_PROXY` never apply. Curl is told only
how to fetch, in its arguments (`-q`: no `.curlrc`; redirects followed to
`https://` only, at most ten; three tries on what curl calls transient; at
most 1 MiB), and the address on its standard input, a one-line config (`--config
-`): never among the arguments, which every process on the machine can read
while curl runs. Not Foundation's URLSession: it lives in FoundationNetworking,
which the static Linux binary leaves out — it would bring the rest of
Foundation, ICU and libcurl into every copy, and nothing here proves the
Static Linux SDK links it. The tests go on no network: they hand `pin` a fake
release, a fake curl that says what it was given and read, and the real curl
a `file://` release.

**What git is told, and what it is not.** Git runs with nobody's global or
system configuration and no `GIT_` variable inherited. A repository's own
configuration is still read — and it names programs git runs in more places
than one: a clean filter run on every file whose timestamps moved when the
index is refreshed (as `git status` does), a file-system monitor, hooks, a
pager, diff drivers, and in a partial clone a fetch of a missing object over
whatever transport and `ssh` command it names. None of them runs: no command
the check gives refreshes the index, diffs or checks anything out — whether a
working copy has changes is found by hashing its files as they are and reading
the index as it is — the monitor and the hooks are switched off, no transport
of any kind is allowed and no missing object is fetched, the `ssh` command is
emptied besides, no pager is started and no signature verified. A
repository's configuration can make the check fail; it is not a way to make it
run a program — the tests try a clean filter, a file-system monitor, and a
partial clone's fetch over `ssh` and over a transport that is a command of its
own.

That is what makes it safe to open git's `safe.directory` — its refusal to read
a repository another user owns — and it is opened for the one repository being
checked, by the path git compares, never for `*`. Which path that is, git
answers: asked once where the repository is, with the folder being checked and
each folder above it opened — the only paths git can compare for a repository
it finds from there — and told only its answer after that. A plugin folder
that merely holds files named `HEAD`, `objects` and `refs` is no bare
repository unless git says so. In CI the checkout is often
made by one user and read by another: a job in a container runs as root over a
workspace the runner made, and git would refuse it. The two places the check
runs are a repository's CI, reading the clone it just made of itself, and an
author's machine, reading their own working copy; in neither is the repository
a stranger's to the one who asked for the check, and in both, what git reads is
data and nothing more.

### The official repository

`github.com/iillyyaa1997/udeck-plugins`. It is built into uDeck and, in
stage 1, is the only source there is.

It follows every rule above and a few more of its own, because **"Verified"
means a maintainer read the plugin before merging it** — so everything in it
has to be readable, and everybody's rights in it have to be clear.

| # | Rule | Why |
|---|---|---|
| 14 | Every file in a plugin's folder is UTF-8 text: valid UTF-8, no NUL byte — with two exceptions, both PNG and never executable: `icon.png`, at most 512×512, and up to three screenshots `screenshot-1.png` … `screenshot-3.png`, at most 1 MiB each. A PNG is recognised by its signature, not its name. | A binary cannot be read by a reviewer, so it cannot be verified. That rules out compiled programs, libraries and archives. A picture is the one exception worth its weight: the catalogue is much clearer with an icon and a screenshot, and uDeck only ever *shows* a PNG, never runs it. SVG is not allowed — it can carry script. Other repositories may hold whatever their owners choose. |
| 15 | `author` is set in the manifest. | The name the copyright belongs to. |
| 16 | The folder has a `LICENSE`: first the line `Copyright <year> <author>` — the same `author` as the manifest — then a blank line, then the unmodified text of the Apache License, Version 2.0. | Every plugin is Apache-2.0 and **its author keeps the copyright**: the licence file travels with the folder onto every machine, and it says whose the plugin is. |
| 17 | Every commit in a pull request carries a `Signed-off-by:` line (the [Developer Certificate of Origin](https://developercertificate.org)). | The author certifies they have the right to submit the code. No rights move to the repository's owner, and there is no CLA to sign. |

The repository's own files in stage 1:

```
udeck-plugins.json
README.md                         what this is, how to install from it, what "Verified" does and does not mean
LICENSE                           the Apache License 2.0 (already there)
CONTRIBUTING.md                   how to add a plugin, git commit -s, what review looks at
.github/CODEOWNERS                * @iillyyaa1997
.github/workflows/validate.yml
.github/scripts/check-repo.py
plugins/uptime/
```

**CI.** `validate.yml` runs on `pull_request` into `main` and on `push` to
`main` — never on `pull_request_target`, which would run a stranger's code with
the repository's secrets. It runs two checks of one commit side by side:
`.github/scripts/check-repo.py --official`, which implements rules 1–17 with
nothing but the Python standard library, and `udeck-plugin check-repo --strict
--official` from the release `.github/udeck-plugin.lock` names;
`.github/scripts/compare-checks.py` holds them to the same findings — level,
rule and path — for the passport and rules 1–17, and the job fails when either
finds an error or could not check, or the two disagree. For a pull request both
read its head, and
the sign-off of every commit between the base and the head. The base is the
first parent of the merge `actions/checkout` checks out, `refs/pull/N/merge` —
`main` as GitHub merged the pull request into it — once the job has checked
that the merge's second parent is the pull request's head; not the event's
`base.sha`, which can lag behind `main`. The copies that run — the scripts with
their tests, and the lock file — are the base's, read out of git into a folder
of their own, each file of `.github/scripts/` under its exact name; only the
pull request that brought the check into `main` was checked by its own copy,
and the one that brought the lock file and the comparison by its own of those.
What a pull request changes is what that merge changes against the base, so a
branch that only lags behind `main` changes nothing `main` has taken since. A
pull request whose merge changes the lock file is also checked by the release
that lock file names, which has to pass and agree, and the lock file is held to
that release with `udeck-plugin pin --check`. One whose merge changes
`.github/scripts/`, `LICENSE` or the lock file has the merge's copies tried
last, after the verdict, where the pull request's own code can add a failure and
cannot take one away: their tests, beside the merge's lock file, and the
merge's `check-repo.py` and `compare-checks.py` beside the release that lock
file names — on the merge, as the push to `main` will check it, and on the
head, as the next pull request will be checked — so that copies or a release
which would fail `main`'s next run, or pull requests like this one, fail the
pull request that brings them. One whose merge would take the scripts, their
tests, the lock file or `LICENSE` off `main`, or leave one of them a file of
zero bytes, a folder or a symbolic link, fails, and so does a name in
`.github/scripts/` that uses anything but `A–Z a–z 0–9 . _ -` or starts with
`.`. Python runs isolated (`-I`) from those folders, not from the checkout, so
a `unittest/` or a `tempfile.py` at the top of a pull request is never imported
in place of the standard library's, and no step takes the check's path from an
environment an earlier step could write. What the workflow cannot guard is
itself: GitHub runs a `pull_request` workflow as it is in that merge — `main`'s
copy when the pull request leaves the file alone, the pull request's change
applied to it when it changes it. That rests on the review below.

> **Later — stage 2.** The script is replaced by `udeck-plugin check-repo
> --official` ([The check](#the-check)), built from the same Swift library uDeck
> uses, and the script is deleted rather than kept alongside: two
> implementations of one set of rules drift, which is exactly what happened to
> the bash check in uDeck's own CI. Rules 18, 19 and 20 — the version check,
> `minUDeck` and one-line names — which the script does not have, the official
> repository has had since udeck-plugins#2, through `udeck-plugin`.
>
> What is there already: every uDeck release from 0.6.1 on carries
> the command itself ([Where the command comes from](#where-the-command-comes-from)),
> and [the lock file](#the-lock-file) that names one release, read from the
> base as the script is read now, with `udeck-plugin pin`, which writes it.
> Since [udeck-plugins#2](https://github.com/iillyyaa1997/udeck-plugins/pull/2):
> `validate` runs the binary the base's lock file pins beside the script, on a
> checkout with its whole history, which `--official` requires for rules 17 and
> 18, and fails when the two disagree; the script goes once they have agreed
> long enough.

**Branch protection is what "Verified" rests on.** On `main`: a pull request
is required, with no exception for administrators; `validate` must pass; force
pushes and deletion are refused; merging is squash-only, so every merged pull
request is one commit on `main` and a plugin's history reads one entry per
change. Only the maintainers can merge, and **merging is the review** — not an
approval button: GitHub does not let anyone approve their own pull request, so
a required approval would stop a sole maintainer from merging his own plugins.
`CODEOWNERS` names who is asked to review. uDeck cannot see any of these
settings and relies on them; they are set on GitHub by the repository's owner.

**Merging is publishing.** There is no release step and no index to rebuild:
the moment a pull request lands on `main`, it is in every uDeck's catalogue at
its next refresh.

**The first plugin, `uptime`.** Its job is to exercise the system, not to be
useful: it proves the whole path from a repository to a card, and it leaves
traces the lab can check.

* `run: ["./uptime.sh"]`, POSIX `sh`, nothing that a stock macOS lacks.
* It prints how long the machine has been up (`/usr/sbin/sysctl -n
  kern.boottime`), the load averages (`sysctl -n vm.loadavg`), and **how many
  times it has run since it was installed**, kept in a file in
  `UDECK_CACHE_DIR`. That counter is what shows that removing a plugin removed
  its cache: reinstalled, it starts again from 1.
* It declares `"permissions": { "exec": ["sysctl"] }` — honestly, since it runs
  it — which means installing it walks through the consent sheet, and every
  new version asks again.
* `version` `1.0.0`, `api` `1`, no `minUDeck`; `interval` 60, `timeout` 2, card
  `ttl` 120; `manifest.ru.json`; `README.md`; `LICENSE` naming its author.

---

## Versions and compatibility

A manifest carries three fields about versions. `version` and `api` exist
today; `minUDeck` is new. Between them they answer three different questions:
*which* release of the plugin this is, *which contract* it is written against,
and *which uDeck* first had everything it uses.

### `version`

```
MAJOR.MINOR.PATCH        each part a whole number: 0, or 1–999999999 with no leading zero
```

`1.2.0`, `0.1.0` and `10.0.3` are versions. `1.2`, `v1.2.0`, `1.2.0-beta` and
`01.2.0` are not.

Two versions compare part by part, as numbers, left to right: `1.10.0` is newer
than `1.9.0`, and `2.0.0` is newer than both. Two versions with the same three
numbers are the same version.

Three numbers and no suffix, on purpose. A plugin under test is installed from
a branch or a pull request (stage 3) and is identified by its commit, not by a
label in its version, so a `-beta` would add precedence rules nobody needs yet.
The grammar can widen later without breaking a single manifest; it could never
narrow.

What a bump means, as guidance for authors:

* **PATCH** — a fix; nothing the operator sees changes shape.
* **MINOR** — something new: a setting, a row, a permission.
* **MAJOR** — something the operator relied on changes: a setting's `key` is
  renamed or removed (their stored value stops applying), or the card starts
  to mean something different.

Any change of `version` re-asks the permission question, as it always has.

Where the grammar is enforced:

* **Installing from a repository** — refused if `version` does not parse. uDeck
  cannot say "1.3.0 is available" or roll anything back without comparing
  versions, so a repository plugin has to have one it can compare.
* **The repository check** — an error.
* **A folder of your own in `~/.udeck/plugins`** — never refused. A version
  that does not parse is a note in Settings next to the plugin (*"version
  "draft" is not MAJOR.MINOR.PATCH — fine for a folder of your own, required to
  publish it in a repository"*), and the plugin runs as it did.

The repository check requires `version` to go up whenever anything in the
plugin's folder changed (rule 18), so "changed, but still 1.2.0" cannot happen
in a checked repository.

### `api`

Unchanged: required, an integer, the version of [the plugin
contract](plugin-api.md#versioning) the plugin is written against. This uDeck
speaks `1`. The number changes only when the contract breaks.

What uDeck does with an `api` it does not speak:

| Where | What happens |
|---|---|
| A folder on disk | Refused, naming both numbers — as today. |
| A catalogue row | Shown, with **Install** unavailable and the reason: *"uptime 2.0.0 is written for plugin contract api 2; this uDeck speaks api 1. Update uDeck to install it."* Nothing of the plugin is downloaded. |
| An update of an installed plugin | Not offered. The row says *"2.0.0 needs a newer uDeck (api 2)"*, and the installed version keeps running. |

> **Later — stage 5.** Instead of only saying no, uDeck offers the newest
> version of the plugin whose `api` it speaks, found in the repository's
> history.

This document needs no `api: 2`. `minUDeck` is a new *optional* field, and
new optional fields are exactly what the `api: 1` promise allows.

### `minUDeck`

```json
"minUDeck": "0.8.0"
```

Optional, the same `MAJOR.MINOR.PATCH` grammar, compared with the running
uDeck's own version (`CFBundleShortVersionString`, `0.6.1` at the time of
writing). Absent means "any uDeck that speaks my `api`".

`api` and `minUDeck` answer different questions. `api` says which *contract*;
it moves rarely and only by breaking something. `minUDeck` says which *release*
first had something the plugin uses inside that contract — a new row type, a
new setting type, a new environment variable — and it moves with features.

| Where | What happens when `minUDeck` is newer than this uDeck |
|---|---|
| A catalogue row | **Install** unavailable: *"uptime 1.4.0 needs uDeck 0.8.0 or later; this is uDeck 0.6.0. Update uDeck (Settings → About) to install it."* |
| An update | Not offered; the row says so, and the installed version keeps running. |
| A folder on disk | Refused, like an unknown `api`: *"needs uDeck 0.8.0 or later; this is 0.6.0"*. A folder copied in by hand is held to what its author said. |

A uDeck older than this field ignores it, as it ignores any field it does not
know. So `minUDeck` protects from the release that introduces it onwards — and
installing from a repository needs that release anyway. A `minUDeck` lower than
that release means the same as leaving it out.

If the running uDeck's own version does not parse (a build somebody stamped by
hand), the comparison is skipped and logged rather than refusing every plugin.

In stage 1 an author writes `minUDeck` by hand, or leaves it out.

The repository check works it out (rule 19). It knows which uDeck release
introduced each manifest field, setting type and permission kind — every part
of the contract is dated, the variables a producer and a card's action are
handed included, and a test fails on one that is not — reads the manifest,
and tells the author the lowest `minUDeck` that is true. Every part of the
contract today came in uDeck 0.1.0, before 0.6.0, the first release that reads
`minUDeck`, so no plugin needs one yet. A plugin that declares 0.6.0 or lower
is told it does nothing: every uDeck that reads the field meets it (below
0.1.0 it is an error: nothing of the contract was there). A higher one is the
author's to set, and is left alone.

What a producer *prints* — which row types its cards use — cannot be seen
without running it, so the check does not see it. `udeck-plugin run` sees one
card, and reckons it the same way: a part of it newer than the declared
`minUDeck` — or, with none declared, newer than the release that first reads
`minUDeck` — is a warning. Every part of a card today came in uDeck 0.1.0,
like the rest of the contract, so no card gets that warning yet; the first
release that adds to what a card can hold is the first one it can say.

> **Later — stage 5.** An older uDeck installs the newest version of the plugin
> whose `minUDeck` it meets, from the repository's history, instead of refusing.

### Manifests written before this document

* **`version` is any string**, as the contract allowed. Such a plugin keeps
  loading and running, and its grants are still keyed by that string. It gets
  the note described above, and it cannot be published in a repository until
  the version parses. The four `examples/` already say `0.1.0`.
* **No `minUDeck`** — no constraint.
* **Unknown fields** — still ignored when loading, as the contract promises.

---

## The catalogue

The catalogue is the list of plugins one repository offers, as uDeck shows it
in **Settings → Plugins**. It is built from two things: the repository's list of
files at one commit, and each plugin's `manifest.json`. **No plugin is
downloaded to build it**, however many there are.

### Reading a repository without downloading it

For a GitHub repository `owner/repo`, one refresh is at most these requests,
in this order, and usually only the first two:

1. **The default branch.** `GET https://api.github.com/repos/{owner}/{repo}` →
   `default_branch`. Read at most once a day per repository, and again at once
   if step 2 answers 404 (the branch was renamed).

2. **The commit it points at now.**
   `GET https://api.github.com/repos/{owner}/{repo}/commits/{branch}` with
   `Accept: application/vnd.github.sha` and `If-None-Match: "<commit from last
   time>"`. The body is the 40-character commit SHA, and the `ETag` is that SHA
   in quotes (**measured**). `304 Not Modified` means nothing changed, and the
   refresh ends here.

3. **Every path at that commit.**
   `GET https://api.github.com/repos/{owner}/{repo}/git/trees/{commit}?recursive=1`.
   It accepts a commit SHA (**measured**) and returns every file with its
   `mode`, its blob `sha` and its `size`, and every folder with its tree `sha`.
   A commit never changes, so this is fetched once per commit and cached for
   good.
   If the answer says `"truncated": true` — a repository too large to list in
   one answer (by memory, around 100 000 entries) — uDeck lists the root
   (`git/trees/{commit}`), then the `plugins` folder by its tree SHA, then each
   plugin folder with `?recursive=1`: two requests plus one per plugin.

4. **The passport**, `udeck-plugins.json`, from the raw file host (below).

5. **The manifests** — but only of plugins whose folder tree SHA uDeck has not
   seen before. A folder with the same tree SHA as last time has, byte for byte,
   the same manifest. For each new one: `manifest.json`, and
   `manifest.<lang>.json` for the language the panel is speaking *if the
   listing shows one* — never guessed at.

Files — the passport, manifests, and later a plugin's files — come from the raw
file host, not from the API:

```
https://raw.githubusercontent.com/{owner}/{repo}/{commit}/{path}
```

Always by commit, never by branch name, so the file is the one at the commit
that was listed. Raw requests do not count against the API limit (their answers
carry no rate-limit headers — **measured**). Every file fetched is checked
against the blob SHA the listing gave for it (see [Git's two
hashes](#gits-two-hashes-computed-by-udeck)) before it is used, so a cache or a
proxy in between cannot change what uDeck reads without being noticed.

Every request carries `User-Agent: uDeck/<version>` (GitHub refuses requests
without one), API requests also `Accept: application/vnd.github+json` (except
step 2) and `X-GitHub-Api-Version: 2022-11-28`. In stage 1 nothing carries a
token or a cookie. Each request gives up after 30 seconds.

Measured on 2026-09-28 against `iillyyaa1997/udeck` at `f5a0ca3`, to show the
mechanism holds: the `ETag` of step 2 was the commit SHA; step 3 with a commit
SHA answered 200 with `mode`, `sha` and `size` on every blob; the raw copy of
`examples/hello-card/hello.sh` hashed to exactly the blob SHA the listing gave
(`bbb88658…`); and the tree hash computed from the listing's four entries for
`examples/hello-card` came out as the listing's own SHA for that folder
(`44fccaa893276f9d6ee963108fb0a66f59534351`).

### What is cached

```
~/.udeck/catalogue/<source>/                 <source> is "official" in stage 1
  state.json               default branch and when it was read; the head commit and its ETag;
                           when the last refresh succeeded; the last error; the rate-limit state
  trees/<commit>.json      the listing of one commit, as uDeck keeps it: the passport's blob SHA,
                           and for each plugins/<id> its tree SHA and its files (path, mode, blob SHA, size)
  blobs/<blob sha>         passports, manifests and translations, stored under their own hash
  history/<id>.json        a plugin's earlier versions, valid while the head commit is unchanged
```

The catalogue does not live under `~/.udeck/cache/`, because every folder in
there belongs to a plugin of the same name, and a plugin called `catalogue` is
a legal id.

A listing is kept while it is the head of its source, or while a plugin in
`installed.json` was installed from that commit (as its current or its previous
version). Blobs are kept while a kept listing names them. Everything else is
pruned after each refresh. The whole directory is small: listings are a few
kilobytes each, and only manifests are stored.

Because it is on disk, **the catalogue appears at once when Settings opens**,
before any request answers, with the time it was read: *"github.com/iillyyaa1997/udeck-plugins
· checked 14:02"*.

### GitHub's limits

Without signing in, GitHub allows **60 API requests an hour per network
address** — not per application: everything behind the same connection shares
them, and a `304` answer costs one as well unless it carries a token
(**measured** by the research for this plan; GitHub's documentation says the
same). Raw file requests are counted separately, and GitHub publishes no
figures for them.

What one refresh and one install cost in API requests:

| Operation | API requests | Raw files |
|---|---|---|
| A refresh when nothing changed | 1 (2 once a day) | 0 |
| A refresh after something was merged | 2–3 | the passport, plus a manifest (and one translation) per changed plugin |
| Installing or updating a plugin in the catalogue | **0** — the listing is already cached | one per file in that plugin |
| Listing a plugin's earlier versions | 1 | one manifest per commit examined, at most 50 |
| Installing an earlier version | 1 (its commit's listing) | one per file |

So an ordinary day costs one to three requests, and installing costs none.

uDeck reads `x-ratelimit-remaining` and `x-ratelimit-reset` from every API
answer, and keeps them in `state.json` so that a relaunch does not start by
spending what is left.

* **A refresh nobody asked for** (at launch, once a day) does not start while
  fewer than 10 requests are left before the reset. The rest is kept for what
  the operator presses, and for whatever else shares the connection.
* **`403` or `429` with `x-ratelimit-remaining: 0`** — no API request goes to
  that host until `x-ratelimit-reset`. The catalogue stays, from the cache,
  with the reason: *"GitHub allows 60 requests an hour from this network
  without signing in, and they are used up — by uDeck or by something else on
  the same connection. The list below is from 14:02; uDeck will look again
  after 15:07."*
* **`403` or `429` with `Retry-After`** (GitHub's secondary limit) — the same,
  for that many seconds.
* **A `403` with neither** — it is not a limit; it is reported as the refusal
  it is.
* **A raw file host answering `429`** — no raw request for an hour, and the
  install that was running stops with the reason. Its limits are not published,
  so uDeck does not guess at a schedule.

While the API is blocked, a plugin whose listing is cached can still be
installed or updated: that needs raw files only.

> **Later — stage 4.** A token — pasted by hand, or from "Sign in with GitHub" —
> raises the limit to 5 000 an hour for that person, and makes `304` answers
> free.

### A catalogue row

Everything a row shows comes from the listing and the manifest, so none of it
costs a download:

* the plugin's `name` and `description`, in the panel's language where the
  plugin has a translation;
* its `version`, and its `author` if it has one;
* the mark of where it comes from — **Verified** for the official repository
  (see [Verified, trusted, unverified](#verified-trusted-unverified));
* what it asks for, in the same words as the consent sheet (*"Asks to run
  sysctl"*), or *"Asks for nothing"*;
* its size, from the listing: *"4 files · 6 KB"*;
* a link to the folder on GitHub at that commit —
  `https://github.com/{owner}/{repo}/tree/{commit}/plugins/{id}` — which opens
  in the browser and is where the README is read;
* its state, and the one button that goes with it:

| State | Row says | Button |
|---|---|---|
| Not installed | — | **Install** |
| Installed from here, same tree | *Installed* | — |
| Installed from here, the repository has a newer version | *1.3.0 available* | **Update** |
| Installed, a folder of your own with the same id | *A folder of your own named uptime is installed* | **Replace…** |
| Cannot run here | the first reason, e.g. *needs uDeck 0.8.0 or later* | none; every reason under "Details" |

Before offering **Install**, uDeck checks everything it can without the files:
the manifest decodes, its `id` is the folder name, it has no manifest problems,
`version` and `minUDeck` parse, `api` and `minUDeck` fit this uDeck, a relative
`run[0]` is in the listing with mode `100755`, and the listing obeys rules 1–8
(an LFS pointer, rule 9, shows only in a file's content, so it is caught when
the files arrive).
A plugin that fails any of them is still shown — with the reason. A plugin that
silently does not appear is a support question.

Rows are sorted by name, as the operator reads it.

### GitLab

> **Later — stage 4.** The same reading, through GitLab's API (gitlab.com and
> self-hosted). The project is addressed by its URL-encoded path
> (`group%2Fproject`). Endpoints below are from GitLab's documentation and were
> not exercised with a token.
>
> | Step | GitHub | GitLab |
> |---|---|---|
> | Default branch | `GET /repos/{o}/{r}` → `default_branch` | `GET /api/v4/projects/{id}` → `default_branch` |
> | Head commit, conditional | `GET /repos/{o}/{r}/commits/{branch}`, `Accept: application/vnd.github.sha` | `GET /api/v4/projects/{id}/repository/branches/{branch}` → `commit.id`; answers `304` to `If-None-Match` (measured) |
> | Every path at a commit | `GET /repos/{o}/{r}/git/trees/{commit}?recursive=1` | `GET /api/v4/projects/{id}/repository/tree?ref={commit}&path=plugins&recursive=true&per_page=100`, paginated; each entry has `id` (the blob or tree SHA — measured to equal git's), `type`, `path` and `mode` |
> | One file | `raw.githubusercontent.com/{o}/{r}/{commit}/{path}` | `GET /api/v4/projects/{id}/repository/blobs/{blob sha}/raw` |
> | A folder's history | `GET /repos/{o}/{r}/commits?sha={branch}&path=plugins/{id}` | `GET /api/v4/projects/{id}/repository/commits?ref_name={branch}&path=plugins/{id}` |
> | A whole folder in one request (optional) | not possible | `GET /api/v4/projects/{id}/repository/archive.tar.gz?sha={commit}&path=plugins/{id}` — limited to 5 a minute on gitlab.com |
> | Token | `Authorization: Bearer <token>` | `PRIVATE-TOKEN: <token>` |
>
> GitLab's listing does not give sizes, so the size limit is checked while the
> files arrive rather than before. A private GitHub source is read through the
> API's blob endpoint (`GET /repos/{o}/{r}/git/blobs/{sha}` with `Accept:
> application/vnd.github.raw+json`) rather than the raw host, since how the raw
> host treats a token is not documented. Tokens are kept in the Keychain, sent
> only to their own host, and never followed across a redirect.

---

## Installing a plugin

### What happens when Install is pressed

The row names one commit — the head the catalogue was built from — and uDeck
installs exactly that commit, even if the repository has moved on since the
catalogue was read. What the operator saw is what they get.

1. **Check the listing** for that plugin against rules 1–8 and the manifest
   checks of the catalogue row. No request is needed: the listing is cached.
2. **Open a staging folder**, `~/.udeck/staging/<random>/`, and write
   `intent.json` into it: what is being done, to which id, and the record that
   will be written if it succeeds (see [Recovering from a crash
   halfway](#recovering-from-a-crash-halfway)). Staging sits on the same volume
   as `plugins/`, so the final move is a rename, and outside `plugins/`, so the
   folder watcher never sees a half-written plugin.
3. **Download the plugin's files, and only those** — every blob under
   `plugins/<id>/` in the listing, from the raw host at that commit, up to four
   at a time. Each file is hashed as it arrives and must match its blob SHA.
   Each is written to `staging/<random>/<id>/<path>` with the permissions its
   mode says: `0755` for `100755`, `0644` for `100644`. A file that turns out
   to be a Git LFS pointer stops the install. Nothing else in the repository is
   requested. A failed request is retried twice; the whole
   install gives up after five minutes.
4. **Hash the staged folder** as git would, and compare it with the tree SHA
   the listing gave for `plugins/<id>`. This is what proves that the set of
   files is complete and nothing extra is there, not only that each file is
   right.
5. **Check it with the code that checks every plugin**:
   `PluginDiscovery.load(staging/<random>/<id>)` — the same function the folder
   scan calls for `~/.udeck/plugins/<id>`, which is why the staged folder is
   named after the id. It must come back usable. A problem that does not stop
   a plugin running — a translation that will not parse — travels with it and
   is shown next to it, as it would be for any folder. Its `version` must be
   the one the catalogue showed.
6. **Quiet the plugin** if a copy of it is installed: stop scheduling its polls,
   refuse its card actions, and wait for a run in flight to end — as long as a
   poll can take, its `timeout` and a second and a half. A card's action has no
   timeout of its own, so one still running when that wait is up is **ended**:
   `SIGTERM` to its process group (an action runs in a group of its own, so
   whatever it started goes with it), a second, then `SIGKILL`, and a further
   wait for it to be gone. Only then is the folder touched. If anything of the
   plugin still runs after that, the operation stops with *"Something uptime
   started would not end, so its folder was left as it was"*, the staged copy
   is thrown away, and `plugins/<id>` is exactly as it was: uDeck never swaps
   or removes a folder under a live process.
7. **Swap the folder into place** in one step (see [Replacing a folder without
   losing its window](#replacing-a-folder-without-losing-its-window)). On a
   volume that ignores case, a folder spelt `Uptime` is where the swap for
   `uptime` lands, and a swap keeps the name a folder had — while discovery
   holds a folder's name to its id exactly. So a folder spelt otherwise is
   first renamed to the id, in place, and the swap lands on the exact name.
8. **Write the record** into `installed.json`.
9. **Dispose of the old copy**, which the swap left in staging: deleted, or
   moved to the Trash when it holds anything of the operator's — see [What
   goes to the Trash](#what-goes-to-the-trash) — because uDeck never destroys
   something it did not put there.
10. **Remove the staging folder**, re-read the plugins folder, and let polling
    resume.

Anything that fails before step 7 deletes the staging folder and leaves
`~/.udeck` exactly as it was, with the reason in the row: *"plugins/uptime/uptime.sh
arrived different from what the repository lists (expected 1a2b3c4, got
5d6e7f8); nothing was installed."*

Installing does not add the plugin to a tab, and does not run it. It appears in
the list a new tab offers, as a folder dropped in by hand does. Consent works
as it does today: the first time it is placed, a plugin that asks for anything
asks, and a new `version` asks again.

One install, update or removal runs at a time. They are rare, and doing them
one after another is what keeps `installed.json` and the plugins folder from
ever being written by two of them at once.

### Git's two hashes, computed by uDeck

uDeck identifies content the way git does, because that is what both GitHub and
GitLab report, and it computes the hashes itself — there is no git on a stock
Mac. Both are SHA-1:

* **A file (blob):** SHA-1 of `blob <size in decimal>\0` followed by the file's
  bytes.
* **A folder (tree):** SHA-1 of `tree <size in decimal>\0` followed by one
  entry per child, sorted: `<mode> <name>\0<the child's 20-byte binary hash>`.
  The mode is written without a leading zero: `100644` for a file, `100755` for
  an executable file, `40000` for a folder (the API spells that one `040000`).
  Children are sorted by their names' bytes, with a folder compared as if its
  name ended in `/`. A folder with nothing in it does not exist in git and is
  skipped.

On disk, a file is `100755` when its owner's execute bit is set, and `100644`
otherwise. Entries whose names start with `.` are skipped, which is why rule 7
keeps them out of repositories: `.DS_Store` must not turn an installed plugin
into a modified one. A symbolic link never gets hashed, because it is never
installed.

The hash is not a signature. What makes the content trustworthy is that the
listing came from the provider over TLS; what the hash adds is the certainty
that the files on disk are exactly the files that listing named, no more and no
fewer. The arithmetic is `Insecure.SHA1` from swift-crypto, which on a Mac is
CryptoKit's own type re-exported, and on Linux an implementation of its own.

### Replacing a folder without losing its window

Today, whenever the plugins folder is re-read, a window whose plugin was not
found is removed from the layout, and the layout is saved
(`DeckModel.discoverPlugins` → `DeckLayout.pruneWindows`). "Not found" includes
*a folder whose manifest does not parse*, since only plugins with a manifest
are counted. So a folder replaced in two steps — the old one moved out, the new
one moved in — loses its window if the watcher reads the folder in between, and
a typo saved in a manifest loses it too. Three changes close this, and each one
alone would not be enough:

1. **The swap is one step.** `renamex_np(staged, live, RENAME_SWAP)` exchanges
   the two folders atomically: at no moment is there no `plugins/<id>`. A fresh
   install uses `renamex_np(staged, live, RENAME_EXCL)`, which fails rather
   than overwrite a folder that appeared in the meantime. On a volume that
   cannot swap (an unusual `UDECK_HOME`), uDeck falls back to two renames — and
   change 3 makes the gap harmless.
2. **The plugin is quiet while it happens.** Nothing of it runs across the
   swap, so no run starts in one version's folder and reads the other's.
3. **Windows are never removed because a plugin is missing.** A window whose
   plugin is not in the folder stays where it is and says so: *"uptime is not
   in ~/.udeck/plugins"*, with **Reinstall** when `installed.json` knows where it
   came from, and **Remove from tab** always. A window is removed when the
   operator removes it, or when the plugin is removed through uDeck. This also
   ends the lost window after a manifest typo, and after switching a working
   copy between branches.

Which windows to keep becomes a pure function in UDeckCore, so it is tested;
UDeckKit has no tests.

### `installed.json`

`~/.udeck/installed.json` records every plugin uDeck installed from a
repository. It sits beside `grants.json` and `plugin-settings.json`, is written
the same atomic way, and a broken copy is reported rather than overwritten, like
theirs — and while it is broken, uDeck installs, updates and removes nothing,
since any of those would have to overwrite it. **Nothing is ever written into a
plugin's folder**: the folder is exactly the repository's, which is what lets
its hash be compared at all.

```json
{
  "version": 1,
  "plugins": {
    "uptime": {
      "source": "official",
      "repository": {
        "provider": "github",
        "host": "github.com",
        "path": "iillyyaa1997/udeck-plugins"
      },
      "ref": { "kind": "default", "name": "main" },
      "commit": "5c3e0d2f9b8a7c6d5e4f3a2b1c0d9e8f7a6b5c4d",
      "tree": "9a1f4e7c2b8d3f6a5e0c9b4d7a2f1e8c3b6d5a40",
      "version": "1.1.0",
      "installedAt": "2026-10-02T09:14:03Z",
      "pinned": false,
      "verification": {
        "status": "verified",
        "by": "official",
        "checkedAgainst": "5c3e0d2f9b8a7c6d5e4f3a2b1c0d9e8f7a6b5c4d",
        "checkedAt": "2026-10-02T09:14:03Z"
      },
      "previous": {
        "ref": { "kind": "default", "name": "main" },
        "commit": "0b7d6c5e4f3a2b1c0d9e8f7a6b5c4d3e2f1a0b9c",
        "tree": "3e8d1c6b5a4f9e2d7c0b3a6f5e8d1c4b7a2f9e60",
        "version": "1.0.0"
      }
    }
  }
}
```

| Field | Type | Meaning |
|---|---|---|
| `version` | integer | The format of this file. Currently `1`. |
| `plugins` | object | Keyed by plugin id — the same id as the folder. |
| `source` | string | The source it was installed from. `official` in stage 1. |
| `repository` | object | Where that source pointed when the plugin was installed: `provider` (`github`; later `gitlab`), `host`, and `path` (`owner/repo`). A copy, so that the record still says where the plugin came from after the source is renamed or removed. |
| `ref.kind` | string | `default` — the source's default branch. Reserved for later: `branch`, `pr`, `commit`. |
| `ref.name` | string or null | The branch name (`main`); later the branch, or the pull request's number as a string. |
| `commit` | 40 hex characters | The commit the files were taken from. |
| `tree` | 40 hex characters | The tree SHA of `plugins/<id>` at that commit — and so of the folder on disk, as it was installed. |
| `version` | string | The manifest's `version` at that commit. |
| `installedAt` | ISO-8601 time, UTC, whole seconds | When this copy was put in place. |
| `pinned` | boolean | `true` when the operator chose this version over the newest one — an earlier version, or **Back to 1.0.0**. A pinned plugin is still told about newer versions; later, automatic updates leave it alone. **Update** clears it. |
| `verification.status` | string | What the folder was, the last time uDeck looked: `verified`, `modified` (stage 1); `trusted`, `unverified` (later). |
| `verification.by` | string or null | Whose guarantee it is: `official`, or (later) the trusted source's id; `null` when nobody's. |
| `verification.checkedAgainst` | 40 hex characters or null | The commit of the default branch the folder was compared against. |
| `verification.checkedAt` | ISO-8601 time | When. |
| `previous` | object or null | The copy this one replaced — `ref`, `commit`, `tree`, `version` — so that **Back to 1.0.0** is one click. `null` after a first install. |

**`verification` is recorded, not trusted.** It is recomputed every time the
plugins folder is read, and after every refresh; uDeck writes it back only when
it changed. It is kept so that Settings can show where a plugin stands the
moment it opens, and so that "verified as of this commit" can be read back
later. Nothing — least of all a consent decision — is ever taken from the
stored value alone.

How it is computed in stage 1:

* The folder's tree SHA, hashed now, differs from `tree` → **`modified`**, by
  nobody.
* Otherwise, `source` is `official` and `ref.kind` is `default` → **`verified`**,
  by `official`. Every commit uDeck installs from the official source comes
  either from resolving its default branch or from that branch's history, and
  force pushes to it are refused, so the commit is one somebody merged.

A folder in `~/.udeck/plugins` with no record is **a folder of your own**:
uDeck claims nothing about it, as today. A record whose folder is gone is
**missing**; its windows say so and offer **Reinstall**.

A plugin that writes into its own folder — which is its working directory —
makes itself `modified` every time it runs. The contract's place for anything a
plugin writes is `UDECK_CACHE_DIR`; the [plugin contract](plugin-api.md)
gains a sentence saying so.

### Recovering from a crash halfway

`intent.json` in the staging folder is a journal of one operation. At launch,
before the plugins folder is first read, uDeck looks in `~/.udeck/staging/`:

* **An install, update or earlier version** — if `plugins/<id>` now hashes to
  the tree in the intent, the swap happened and the record did not: the record
  is written. Otherwise the record is not written:
  * an old copy the two-rename fallback moved aside goes back to
    `plugins/<id>`. If it cannot be moved back, the staging folder and its
    journal stay exactly as they are and the next launch tries again; if
    something else is at `plugins/<id>` by then, the old copy goes to the Trash
    rather than over it. It is never deleted: it may be the operator's only
    copy.
* **A removal** — if `plugins/<id>` is gone, the rest of the removal is
  finished; if it is still there, the removal never started.

Whatever copy is then left in staging under the id is the one that lost, and
which copy it is — the new download, or the old folder after an exchange — is
not taken on trust after a crash. It is deleted only when it is provably
uDeck's own by the same rule the warning uses (see *What goes to the Trash*):
it hashes to a tree uDeck put there — the intent's, or the one `installed.json`
recorded for the id — and holds nothing the hash does not see, `.DS_Store`
aside — and, when the copy is the old folder after a removal or an exchange,
the intent did not say it was the operator's. (When the swap never happened,
the copy under the id is the download, and the intent's word about the *old*
copy says nothing about it.) Anything else goes to the Trash. A download of the same version as a folder with the operator's
`.env` beside it hashes the same as that folder; the `.env` is what tells them
apart. The one exception is a journal written before its download finished,
which has no record yet: the swap it would precede never began, so what is
under the id is the raw host's files, whole or in part, and they are deleted
when nothing the hash does not see is among them.

A staging folder with no journal at all is deleted: the operation died before
it wrote one, when nothing of the operator's had been moved in. One whose
journal is there but cannot be read — a newer uDeck wrote it, or it was cut
short — or which holds an old copy moved aside, goes to the Trash whole.

Without this, a crash between the swap and the record would leave a plugin that
looks modified by its own owner.

### One id, one copy

A machine has one copy of a plugin per id, and every store in `~/.udeck` stays
keyed by the bare id. Installing an id that is already there from somewhere
else replaces it in place — layout, settings and grants stay — and never
silently:

**Over a folder of your own**, the row offers **Replace…**, which says what
will happen: *"A folder of your own named uptime is in ~/.udeck/plugins.
Installing moves it to the Trash and puts the repository's uptime in its
place."* **Over a linked folder** — a link to a working copy — it says that only
the link goes: *"uptime here is a link to ~/src/uptime. Installing takes the
link away — the folder it leads to stays exactly as it is — and puts the
repository's uptime in its place."*

**Link a folder…** in Settings puts a link to a working copy where something
already is only after it has said what becomes of it, by the same rule: over
a plugin uDeck installed, *"uptime is installed from
github.com/iillyyaa1997/udeck-plugins. Linking ~/src/uptime in its place
deletes the installed copy — it is exactly what uDeck installed — and keeps its
windows, settings and your permission decision."* (or that the copy, holding
changes of yours, goes to the Trash); over a folder of your own, that it goes
to the Trash; over another link, that the link is pointed at the new folder and
the one it led to stays as it is.

> **Later — stages 3 and 4.** Over a copy from another source, a branch or a
> pull request, the same confirmation names both sources, and the Settings row
> always says where the copy on disk came from.

---

## Updates

### Knowing that a plugin changed

After every refresh, for each plugin in `installed.json` from that source,
uDeck compares the record's `tree` with the tree SHA of `plugins/<id>` at the
new head. Equal means nothing in the plugin changed, whatever else was merged —
and it is known without downloading anything.

When they differ, the new head's manifest (already fetched for the catalogue)
says what changed:

| At the head | The Settings row says | Offered |
|---|---|---|
| A newer version | *1.3.0 available* · *What changed* | **Update** |
| The same version, different files | *Changed in the repository, still 1.2.0* · *What changed* | **Update** |
| An older version (the repository went back) | *The repository now has 1.1.0* | **Switch to 1.1.0** |
| A newer version that cannot run here | *1.3.0 needs uDeck 0.8.0* | nothing |
| No folder any more | *No longer in the repository* | **Remove**; the plugin keeps running |

*What changed* opens
`https://github.com/{owner}/{repo}/compare/{installed commit}...{head}` in the
browser. Nothing pops up and nothing is installed by itself: in stage 1 the
operator updates when they choose.

The same line appears on the plugin's row in the catalogue, and the Plugins
pane of Settings shows how many updates are waiting.

### Updating

An update is an install of the plugin at the head commit, with every step above
— downloaded, hashed, checked, swapped in, the window kept. The record's
current values move to `previous`, and `pinned` goes back to `false`. A new
`version` re-asks the permission question when the plugin asks for anything,
as it always has.

A plugin whose copy holds anything of the operator's is not updated over
without a word: *"Your changes to uptime will be moved to the Trash and
replaced with 1.3.0."* — see [What goes to the Trash](#what-goes-to-the-trash).

### What goes to the Trash

One rule decides whether the copy an operation replaces or removes goes to the
Trash or is deleted, and the same rule decides whether the button says so
first. A copy is the operator's when

* there is no record of uDeck putting it there (a folder of their own), or
* it no longer hashes to what was put there (**Modified locally**), or
* it holds something the hash does not see — a name starting with `.`, such as
  a `.env` or a working copy's `.git`, or anything that is neither a file nor a
  folder. The Finder's `.DS_Store` does not count.

The third case is why the row's mark is not the rule: a `.env` put beside a
plugin leaves it **Verified**, and it still goes to the Trash with the copy.
Every button that replaces or removes the folder asks the rule, of the disk, when
it is pressed — **Update** and **Switch to** on either row, **Back to**, **Install
this version** under **Earlier versions…**, **Reinstall** (on the plugin's row,
on the catalogue's row of a plugin whose folder is missing, and on a window
whose plugin will not run), and **Remove** — and, when it says yes, shows
*"Your changes to uptime will be moved to the Trash and replaced with 1.0.0."*
(for **Remove**, that the folder goes to the Trash) before anything happens.
The rule is `OperatorsWork` in UDeckCore, and the installer decides the Trash
by the same function. A linked folder's link never goes to the Trash — it is
unlinked, and the folder it leads to is not touched — so **Remove** on a linked
plugin says that instead: *"Remove the link uptime? Only the link goes: the
folder it leads to, ~/src/uptime, stays exactly as it is."* Every other button
that would take a link away says first that only the link goes, as
**Replace…** says it — **Update**, **Switch to**, **Reinstall**, **Back to**
and **Install this version** too, a link put where the copy was while the
warning about the copy was up included. Which warning a button shows is
`PlaceWarning` in UDeckCore, tested there.

A warning's button acts on what the warning said, and on nothing else. It
carries what was shown — what is at the plugin's place (a link and where it
leads, the operator's work, uDeck's own copy, nothing), the version that comes,
and which copy of it: the plugin folder's tree at the catalogue's head for
**Install** and **Update**, the commit for a button that installs at a commit,
since a version is only what a manifest says and a repository can publish
another tree under the same one — and when it is pressed, the disk and the
catalogue are asked again: if anything differs, byte for byte, nothing is done
and the warning says what is there now (or, when nothing there needs a warning
any more, the button does what it does unwarned). **Link a folder…** holds its
warning the same way, to the id the manifest gives, what is at that id and
whether it goes to the Trash: a manifest whose id is changed while the warning
is up gets a warning of its own before anything of the new id is touched. **Install** on a row that
said nothing is there warns first of a folder or a link put there since. The
rule is `ShownPlace` in UDeckCore, tested there.

### Earlier versions

The row's menu has **Earlier versions…**, and after an update the row offers
**Back to 1.0.0**, which is the same thing for `previous`. Over a copy holding
anything of the operator's, both say first that it goes to the Trash, as
**Update** does.

A repository keeps every version it ever had in its history, so that is where
uDeck looks for them — there is no list of releases to maintain:

1. `GET https://api.github.com/repos/{owner}/{repo}/commits?sha={default branch}&path=plugins/{id}&per_page=100`
   lists the commits that changed the plugin's folder, newest first (**measured**).
2. For each, newest first, up to 50 commits, uDeck reads that commit's
   `plugins/{id}/manifest.json` from the raw host. A commit where the folder
   did not exist is skipped.
3. One line per distinct `version` — taken from the newest commit that has it,
   which is that version as it finally was — with its date, and whether it can
   run here (`api`, `minUDeck`). The installed one is marked.

The result is kept in `history/<id>.json` while the head commit is unchanged.
Choosing a line installs the plugin at that commit — one more request, for its
listing — and marks it `pinned`.

The official repository merges squash-only, so there each line is one merged
pull request. A repository that merges with merge commits shows its
intermediate commits too, and the "newest commit per version" rule is what
keeps a half-finished state from being offered as a version.

> **Later — stage 5.** The same history is how an older uDeck finds the newest
> version it can run: of the versions whose `api` it speaks and whose
> `minUDeck` it meets, the highest.

### Changed on disk

A folder that no longer hashes to its record is **Modified locally**. It runs
as it is, loses its **Verified** mark, and the row offers **Reinstall 1.2.0**,
which puts back what was installed and moves the changed copy to the Trash.

### Automatic updates, and consent for unverified code

> **Later — stage 3.** Verified plugins update themselves once a day, unless the
> new version asks for different permissions — then uDeck asks first. An
> unverified plugin (a branch, a pull request) is only ever offered an update,
> with *What changed*, and its consent is tied to its tree SHA rather than its
> `version`: every new content asks again, even when the plugin asks for
> nothing, because code on a branch changes without review and there is no
> sandbox. `PluginGrant` gains a `decidedForTree` for this; for verified and
> local plugins consent stays tied to `version`, as today. A pinned plugin is
> never updated automatically.

---

## Removing a plugin

**Remove** is on every installed plugin's row in Settings, with a confirmation
that says what goes. For a plugin installed from a repository:

| What | Where | Removed |
|---|---|---|
| The plugin's folder | `~/.udeck/plugins/<id>/` | yes — moved into staging in one rename, so it is gone from the plugins folder at once, then deleted |
| Its scratch directory | `~/.udeck/cache/<id>/` | yes |
| The operator's permission decision | `grants.json`, `byPlugin[<id>]` | yes |
| Its setting values, and whether it was switched off | `plugin-settings.json`, `values[<id>]` and `disabled` | yes (`PluginSettings.forget`) |
| Its record | `installed.json`, `plugins[<id>]` | yes |
| Every window of it, on every tab | `layout.json` | yes, and the layout is saved |
| Its last card | in memory | yes |
| Its catalogue data | `~/.udeck/catalogue/` | no — it belongs to the repository, and pruning takes care of it |

It is quieted first, like an update — a card action still running is ended —
so nothing of it is running while its folder goes; if something of it will not
end, nothing is removed.

Removing everything matters. Today a plugin deleted by hand leaves its grants
behind, and putting the same version back runs it at once with the answers
given to the old copy.

**A folder of your own** — or any copy holding something of the operator's, by
the rule in [What goes to the Trash](#what-goes-to-the-trash) — is moved to the
Trash, not deleted: it may be the author's only copy. Everything else in the
table goes the same way.

---

## Verified, trusted, unverified

A plugin runs as the operator, with everything the operator can do; uDeck does
not sandbox it (see [Permissions](plugin-api.md#permissions)). So the question
that matters before installing is not what the plugin asks for, but *who has
read it*. That is what these marks answer — and each says whose word it is.

| Mark | When | Stage |
|---|---|---|
| **Verified** — `checkmark.seal.fill` | Installed from the default branch of the official repository, and the folder on disk is still exactly what was merged there. A maintainer of the official repository read it before merging. | 1 |
| **A folder of your own** — `folder` | Put into `~/.udeck/plugins` by anyone but uDeck. uDeck claims nothing about it. | 1 |
| **Modified locally** — `pencil` | Installed from a repository, but the folder has changed since. Whatever mark it had is gone. | 1 |
| **Trusted source: \<name\>** — `checkmark.shield` | Installed from the default branch of a repository the operator explicitly trusted (**Trust** on the source, as `brew trust` works for Homebrew). The guarantee is that source's owner's, not uDeck's — a different mark, so nobody mistakes one for the other. | 4 |
| **Unverified** — `exclamationmark.triangle` | From a branch, a pull request, a fork, a specific commit, or the default branch of a source nobody trusted. Nobody vouches for it. Shown on the card's header as well as in Settings. | 3, 4 |

In the official repository **only what is merged is verified**; its branches and
pull requests are unverified like anybody else's.

**"Verified" does not mean safe.** It means a person read the code and merged
it. It is the strongest thing uDeck can honestly say about a plugin, and
nothing more than that.

So that the seal means one thing only: the **"Asks for nothing"** line in
Settings, which today wears a `checkmark.seal`, loses it and becomes plain text.
A plugin asking for nothing is not a plugin somebody checked.

> **Later — stage 3.** Verified is computed from content, not from a ref: a
> plugin installed from a pull request becomes **Verified** the moment the tree
> SHA of its folder appears at the head of the default branch — squash merges
> and rebases included, with no new download — and uDeck starts following the
> default branch for it. Merged with changes: *"The verified version differs —
> update"*. Closed unmerged: a warning, and the plugin keeps running.

---

## What uDeck fetches, and when

The official catalogue is on for everybody from the first launch, because it is
what makes uDeck convenient to someone who has never heard of a plugin
repository. What that means, exactly:

* **At launch**, a few seconds after the panel is ready, uDeck reads the
  official catalogue — unless it read it successfully in the last 24 hours.
  This is what happens on the very first launch, before the operator has done
  anything.
* **While it runs**, once every 24 hours.
* **When Settings → Plugins is opened**, if the catalogue is more than an hour
  old; and whenever **Check now** is pressed.
* **When the operator presses Install, Update or Earlier versions**, the files
  that needs.

Nothing else. A refresh reads only what [the catalogue](#reading-a-repository-without-downloading-it)
reads, usually one or two requests; no plugin is downloaded or installed by
itself. A failed refresh is tried again after an hour, then daily as usual.

It talks to two hosts, `api.github.com` and `raw.githubusercontent.com`. What
reaches GitHub is what any HTTPS request carries: the network address, the
`User-Agent: uDeck/<version>` header, the repository and the files asked for —
and so, when something is installed, which plugin. No account, no identifier,
no cookie, no list of what is installed.

**Settings → Plugins → Official catalogue** turns it off. Off, uDeck makes no
request about plugins at all; installed plugins keep running, and uDeck stops
knowing about their updates.

`README.md` promises today that uDeck makes no network connection of any kind
unless updates are switched on. That stops being true the day stage 1 ships, so
README and `SECURITY.md` are rewritten **in the same release** to say what is
above.

Alongside this work, and not part of it: uDeck's own update checks are also on
by default from now on — Sparkle asks
`github.com/iillyyaa1997/udeck/releases/latest/download/appcast.xml` once a day
— and the rewritten README lists both.

---

## What the operator sees when uDeck says no

Every refusal names the plugin, what is wrong, and what would fix it. They are
shown in the row, in English and Russian like the rest of Settings.

| What happened | What the operator sees |
|---|---|
| `api` not spoken here | *uptime 2.0.0 is written for plugin contract api 2; this uDeck speaks api 1. Update uDeck to install it.* |
| `minUDeck` newer than this uDeck | *uptime 1.4.0 needs uDeck 0.8.0 or later; this is uDeck 0.6.0. Update uDeck (Settings → About) to install it.* |
| `version` does not parse | *uptime's version "1.2" is not MAJOR.MINOR.PATCH, so uDeck cannot tell it from another version; it cannot be installed from a repository.* |
| No passport | *github.com/owner/repo is not a uDeck plugin repository: there is no udeck-plugins.json at the top of main.* |
| Passport from the future | *This repository is in format 2; this uDeck reads format 1. Update uDeck.* |
| A link or submodule | *plugins/uptime/lib is a symbolic link; a plugin from a repository may contain only files and folders.* |
| A file changed on the way | *plugins/uptime/uptime.sh arrived different from what the repository lists (expected 1a2b3c4, got 5d6e7f8); nothing was installed.* |
| The folder as a whole does not match | *The files of uptime do not add up to the folder the repository lists; nothing was installed.* |
| Too large | *uptime is 14 MB in 312 files; uDeck installs plugins of up to 10 MB and 200 files.* |
| A name uDeck will not write | *plugins/uptime/Run Me.sh: names may use only letters, digits, ".", "_" and "-", and may not start with "."* |
| An LFS pointer | *plugins/uptime/data.bin is a Git LFS pointer, not the file; uDeck does not fetch LFS content.* |
| The folder fails the usual checks | the same text a folder dropped in by hand would get — e.g. *uptime.sh is not executable — try chmod +x* |
| API limit used up | *GitHub allows 60 requests an hour from this network without signing in, and they are used up — by uDeck or by something else on the same connection. The list below is from 14:02; uDeck will look again after 15:07.* |
| No network | *Could not reach GitHub: \<reason\>. The list below is from 14:02.* |
| Repository gone or private | *github.com/owner/repo could not be found, or it is private.* |

---

## Testing it

### The fake repository in the guest

The plugin checks never talk to github.com: no account, no limits, and nothing
that depends on somebody else's server. (The update checks given a published
release do, since that is what they check — `updates.a-published-release` by
default, which installs a published release in the guest and lets it update
itself from GitHub: e2e/README.md, "The update by a published release".) Like
the update feed it already serves
(`e2e/udeck_e2e/updates.py`), a fake GitHub runs **inside the guest** on its
loopback address, with the guest's own `/usr/bin/python3` and nothing but the
standard library.

* **Its content is fixture folders, one per commit** — for example
  `c1/` (`uptime` 1.0.0 and the refusal fixtures), `c2/` (`uptime` 1.1.0), a
  file saying which commit `main` points at, and the order of history. The
  fake computes real git blob, tree and commit ids from them itself; there is
  no git in the guest. Because its hashing is Python and uDeck's is Swift, two
  independent implementations have to agree before any check passes.
* **It answers the subset of the API uDeck uses:** `GET /repos/{o}/{r}`;
  `GET /repos/{o}/{r}/commits/{ref}` with `Accept: application/vnd.github.sha`,
  an `ETag`, and `304`; `GET /repos/{o}/{r}/git/trees/{sha}` with and without
  `recursive=1`; `GET /repos/{o}/{r}/commits?sha=&path=`; and raw files at
  `/{o}/{r}/{commit}/{path}` under a second prefix standing in for the raw
  host. API answers carry `x-ratelimit-remaining` and `x-ratelimit-reset`, and
  the remaining count goes down.
* **The lab drives it** by rewriting a small state file over SSH: which commit
  `main` is at; "the limit is used up until T" (`403` with `remaining: 0`);
  "answer this file with different bytes"; "say the listing is truncated".
* **It keeps an access log** of every request — method, path, query, status —
  which is the oracle for what uDeck asked for and, just as much, for what it
  did not.

**A lab build is pointed at it through `Info.plist`**, the way it is pointed at
its own update feed, because the lab tests the release build and a relaunch
does not keep environment variables:

| Key | Shipping value | Lab value |
|---|---|---|
| `UDeckPluginsAPIBase` | `https://api.github.com` | `http://127.0.0.1:<port>/api` |
| `UDeckPluginsRawBase` | `https://raw.githubusercontent.com` | `http://127.0.0.1:<port>/raw` |
| `UDeckPluginsRepository` | `iillyyaa1997/udeck-plugins` | the same |

`Scripts/make-app.sh` gains `--test-plugins <base URL>`, which sets the first two
and adds `NSAllowsLocalNetworking`, as `--test-feed` does; the lab's build step
verifies the keys in the zip as it already verifies `SUFeedURL`.

### The lab's checks

Each check reads the card through the panel's accessibility tree (window 1 of
the uDeck process, subrole `AXSystemDialog`), Settings through its own, and the
guest's `~/.udeck` over SSH.

| Check | Proves |
|---|---|
| `plugins.catalogue-on-first-launch` | On a fresh guest, with nothing pressed, the fake's log shows the catalogue being read within a minute — and no file requested but the passport and manifests. Settings lists the fixture plugins. |
| `plugins.install-fetches-one-folder` | **Install** on `uptime` requests only files under `plugins/uptime/` at the listed commit, and no API request at all. The folder in the guest hashes to the fixture's tree; the record in `installed.json` has every field above; the row says **Verified**. |
| `plugins.card-reaches-the-panel` | Placed on an empty tab and allowed, `uptime`'s card appears, and says it has run once. |
| `plugins.update-keeps-the-window` | With `main` moved to `c2`, **Check now** shows *1.1.0 available*; after **Update**, `layout.json` has the same window (same id, same place), the card shows 1.1.0's output after the new consent, and `previous` holds 1.0.0. |
| `plugins.earlier-version` | **Earlier versions…** lists 1.1.0 and 1.0.0; with a `.env` put into the folder over SSH, choosing 1.0.0 first says *"Your changes to uptime will be moved to the Trash…"*; confirmed, it installs 1.0.0, `pinned` is `true`, the row still says *1.1.0 available*, and the `.env` is in the guest's Trash. |
| `plugins.remove-leaves-nothing` | Before **Remove**, `cache/uptime`, the grant and a setting value are there to be taken; after it: no folder, no `cache/uptime`, no entry in `grants.json`, `plugin-settings.json` or `installed.json`, no window. Installed again, it asks for consent again and its card says it has run once. |
| `plugins.refuses-what-it-cannot-run` | Fixtures with `api: 2` and `minUDeck: "99.0.0"` are listed with their reasons and no **Install**, and nothing of theirs but the manifest was ever requested. |
| `plugins.refuses-changed-files` | With the fake altering one file, the install is refused with the "arrived different" message; there is no `plugins/uptime` and nothing left in `staging/`. |
| `plugins.refuses-a-link` | A fixture whose listing has a symbolic link is listed as not installable, naming the path. |
| `plugins.limit-is-explained` | With the limit used up for two and a half minutes, **Check now** shows the message and the reset time; after a second **Check now** and an install of a plugin already listed — which works — the log shows no API request until the reset; after it, **Check now** reaches the API again. |
| `plugins.catalogue-off-means-no-network` | Switched off and relaunched, uDeck makes no request to the fake for two minutes. |
| `plugins.modified-locally` | A line appended to an installed file over SSH makes the row say **Modified locally** within seconds, and **Verified** is gone. |
| `plugins.window-survives-a-broken-manifest` | A placed plugin's manifest broken over SSH keeps its window in `layout.json`, which says what is wrong; fixed, the card comes back without being added again. |
| `plugins.every-replacement-warns-first` | Over a folder with a `.env` put in over SSH — for **Reinstall**, also a line appended to `uptime.sh` — **Reinstall**, **Update** on the catalogue row, **Back to 1.0.0** and **Remove** each say first that the copy goes to the Trash; confirmed, each does what it says, and every `.env` is in the guest's Trash and no longer in the folder. |
| `plugins.an-update-ends-a-running-action` | With the fixture card's **Hold** action running, **Update** ends it before it replaces the folder: the action wrote that it was ended and never that its folder changed under it, nothing of it runs afterwards, and 1.1.0 is in place. |
| `plugins.linked-folder` | A plugin in a working copy outside `~/.udeck` — beside a `.git`, a `.env`, files named like `installed.json` and `cache/`, and a link — linked into `~/.udeck/plugins` is listed: placed and allowed, its card comes; its manifest changed in the working copy to run another producer, the card says that producer's word; polled every 5 s, with a file in the working copy touched every 3 s for 21 s and the panel open, it runs at least three times; in Settings its row is marked **Linked** and says where the link leads, and **Remove** says first that only the link goes and names the folder, with no word of the Trash; after it the link is gone, uDeck's cache of it too, and the working copy is byte for byte as it was, its `.env` not in the Trash. |
| `plugins.link-a-folder` | **Link a folder…** in Settings → Plugins, the folder chosen in the system's folder panel by typing its path (⌘⇧G): a working copy whose id nothing has is linked at once — the outcome says *Linked <id> to …*, `plugins/<id>` leads to the folder, the row says **Linked**; one with `uptime`'s id, over the `uptime` just installed from the catalogue, first says *"uptime is installed from github.com/iillyyaa1997/udeck-plugins. Linking … deletes the installed copy"* and changes nothing; the working copy's id changed to `link-me` while that warning is up, **Link** warns of `link-me` — *"link-me is a link to …"* — and changes nothing, and with the id back to `uptime` it warns of `uptime` again; confirmed, `plugins/uptime` leads to the working copy, `installed.json` has no `uptime`, and the working copy is byte for byte as it was. |
| `plugins.run-log-switch` | A linked plugin that says a line on stderr every run: with the switch as shipped, no `logs/<id>.log`; **Keep a run log for linked folders** switched on in Settings — `settings.json` says `linkedFolderRunLog: true` — and the panel open, the log has at least two entries, each *exit status 0; a card*, with the stderr line under it, and **Show the logs** is offered. |
| `plugins.failed-run-on-a-fresh-card` | A linked plugin whose card lasts 300 s fails (exit 3, a line on stderr) while a file is in its folder: with the panel open, the fresh card keeps its values and gets the amber dot by its name and the lines *Last run failed at …: the producer exited with status 3* and *showing values from …*; Settings → Plugins, under **More**, says *Last run … a failure: …* and the end of its stderr; the file taken away and the panel opened again, the dot and the line are gone. The panel's own buttons are refresh, Settings, send away and fill the screen — no density button. |
| `plugins.install-command` | The bundle carries `Contents/Helpers/udeck-plugin` and `codesign --verify --deep --strict` holds in the guest; the row says it is not installed; **Install command** makes `~/.local/bin/udeck-plugin` a link to it, and `--help` and `--version` run through the link; the row says it is installed and what the guest's zsh makes of `~/.local/bin` (the line to add, when it does not look there); **Remove command** takes the link and leaves the command in the bundle; a file of somebody else's at that place is said, left as it is, and not offered **Install command**. |
| `plugins.search-path-field` | A linked plugin running the bare `lab-greet`, on no folder of the default list: its window says it was not found. **＋ Add a folder…** (the folder chosen in the panel) puts a folder of the lab's at the top of **Where to look for commands** and in `settings.json`, and the card, allowed, says that folder's word; a second folder added says its word; **↓** on it, the first folder's word again — each from the next run, without a restart; **Restore the defaults** puts the default list back in `settings.json`. |
| `plugins.screens-in-russian` | With uDeck in Russian (`language` in `settings.json`), a failed run on a fresh card, the **Linked** row and its Remove warning, **Link a folder…** over the installed `uptime` and its warning, the last run under **More**, the run log switch, **Where to look for commands** and **Install command** are each there and say uDeck's Russian words — why the run failed too, *программа плагина завершилась с кодом 3*, with the last run's seconds written with a comma; **Link a folder…** over a link writes both folders from `~`; **Update** over a link put where the installed `uptime` was says first *uptime здесь — ссылка на ~/…* and leaves the link until that is confirmed; a screenshot of each is kept for a person to read. |

### Unit tests

Everything that decides something lives in UDeckCore, or in the plugin format
it links (`Packages/UDeckPluginFormat`, which builds on Linux as well), where
`swift test` can reach it; UDeckKit has no tests. The GitHub client takes its transport as a
parameter, so tests answer it with recorded responses (a stub `URLProtocol`),
never the network. What they cover:

* versions: the grammar, including what it refuses, and the ordering;
* the passport: every field, a missing file, a higher `format`, one past 64
  KiB, and the time its reader takes — four times the text, about four times as
  long;
* the repository check: the corpus of what the Python check said about 273
  repositories, replayed in every layer, and the words of every finding; rule
  18 against a base, against the commit before, in a clone of one commit (a
  warning, and in a strict check an error) and of two, with a base a shallow
  clone does not hold, on a first commit, without a common history and in a
  clone without blobs; rule 19 against a
  registry every part of the contract is dated in; rule 20 against every kind
  of character it refuses, at both ends of each range, and the ones beside
  them; git reading a repository whose configuration names a clean filter, a
  partial clone's fetch over `ssh`, or another owner, without running anything
  — and another owner's plugin folder that holds files named like a bare
  repository's; and the time a check takes, four times the plugin folders
  taking about four times as long;
* git hashing, against vectors made with `git hash-object` and `git mktree` —
  including one frozen copy of `examples/hello-card` from `f5a0ca3`, whose tree
  is `44fccaa893276f9d6ee963108fb0a66f59534351`;
* turning a listing into catalogue rows, rules 1–9 each refused, a truncated
  listing;
* the installer: a clean install; a file whose hash is wrong; a file missing or
  extra; a link, a submodule, an LFS pointer, a name out of rule, a folder too
  big; a folder that appeared before the rename; the swap and its fallback; a
  folder spelt `Uptime` on a volume that ignores case, replaced and reinstalled;
  each branch of the recovery at launch, including an old copy that cannot be
  moved back and one whose place has been taken;
* what goes to the Trash: one rule, held against what the installer does, for a
  folder as installed, with `.DS_Store`, with a `.env`, with a `.git`, changed,
  and of the operator's own;
* quieting, decided whole in UDeckCore (`PluginQuiet.quiet`): a run that ends
  within a poll's `timeout` and the second and a half after it is waited for
  and not ended, a card action that outlasts that wait is ended with its
  process group, the swap happens only after it has ended, and a plugin that
  will not end leaves its folder as it was;
* recovery by the rule: a copy left in staging with a `.env` goes to the Trash
  whether it hashes like the download or the journal calls it uDeck's, and what
  is provably uDeck's own is deleted;
* the rate-limit state: blocking, resetting, the reserve for unrequested
  refreshes;
* `installed.json`: reading and writing, and the status computation;
* which windows the layout keeps;
* what Settings → Plugins decides before it draws: which warning **Remove**,
  **Replace…**, **Update**, **Reinstall**, **Back to**, **Install this
  version** and **Link a folder…** show over a link, the operator's work and
  uDeck's own copy, every folder in it written from `~` (`PlaceWarning`); what
  **Where to look for commands** does to the list and says of each folder
  (`SearchPathList`); **Install command** on a bundle and a `~/.local/bin` of
  the test's own — installed, another copy's link, somebody else's file left
  alone — and a shell of the test's own asked for its `PATH` (`CommandInstall`,
  `ShellPath`) — a file put at the command's place between the look and the
  rename, in place of the link before Remove takes it, and between the
  exchange and the exchange back, left there and said; which of its buttons is
  offered where (`CommandInstall.buttons`); where uDeck runs from
  (`BundlePlace`); when a warning's button acts and when it says what is there
  now instead — another version, another copy of the same version, a link put
  in the copy's place (`ShownPlace`); and when a failed run is said on a fresh
  card (`PluginSnapshot.failureOnAFreshCard`).
* what `Scripts/make-cli.sh` makes and refuses, and what `release.yml` may do
  and in which order, in the lab's own tests (`e2e/tests/test_make_cli.py`):
  the archives and their names, the signature of the Mac's, a static and
  stripped binary for Linux, `SHA256SUMS`, the image run on both platforms
  before anything is pushed, and the one `gh release create`.

---

## Where the code goes

A suggestion, so that the two builders and the reviewer are looking in the same
places:

* **UDeckCore**
  * `Paths.swift` — `installedFile` (`installed.json`), `catalogue`
    (`catalogue/`), `staging` (`staging/`).
  * `Plugins/PluginManifest.swift` — `minUDeck: String?`; a problem for a
    `minUDeck` this uDeck does not meet (fatal), and a note for a `version`
    that does not parse (not fatal). Discovery is told the running uDeck's
    version rather than reading the bundle itself, so tests can set it.
  * `Plugins/Repository/` — the version type, the passport, git hashing, the
    listing and catalogue model, the GitHub client behind a protocol the
    GitLab client will also implement, the catalogue store, the rate-limit
    state, `installed.json`, and the installer with its journal.
  * The windows-to-keep rule, next to `DeckLayout`.
* **UDeckKit** — `DeckModel`: quieting one plugin, the new rule for windows,
  install/update/remove wired to the installer, the refresh schedule;
  `SettingsView`: the catalogue, the marks, the menus, **Official catalogue**;
  the placeholder for a window whose plugin is missing; every new string in
  English and Russian.
* **The app** — the three `Info.plist` keys; `Scripts/make-app.sh
  --test-plugins`.
* **The lab** — the fake repository and its fixtures under `e2e/`, the checks
  in a new `e2e/checks/check_plugins.py`.
* **Docs** — [the plugin contract](plugin-api.md) gains `minUDeck`, the
  `version` grammar and the note about writing only to `UDECK_CACHE_DIR`;
  README and `SECURITY.md` say what uDeck fetches; CHANGELOG.

---

## Stages

### Stage 1 — the shortest path (now)

**The official repository** gets its passport, README, CONTRIBUTING with the
DCO, CODEOWNERS, the CI with its temporary check script, and `uptime`. Its
owner sets the branch protection.

**uDeck** gets:

* `minUDeck`, and the `version` grammar where repositories need it;
* the built-in official source, read through GitHub's API and raw host without
  git, anonymously;
* the catalogue: listed from the tree at one commit, manifests read one by one,
  cached by commit, shown at once from disk, careful with the hourly limit;
* installing exactly one plugin's files at a commit, hashed, checked by
  `PluginDiscovery.load`, swapped in one step, recorded in `installed.json`,
  with a journal for crashes;
* updates shown and applied on request, earlier versions from history, **Back
  to** the previous version;
* removal that takes grants, settings, cache, record and windows with it;
* windows that are never dropped because a plugin is missing;
* the marks **Verified**, **A folder of your own**, **Modified locally**, and
  the seal taken off "Asks for nothing";
* refusals for an unknown `api` and a `minUDeck` newer than this uDeck;
* the catalogue on by default, with its switch, and README and SECURITY saying
  so;
* the fake repository in the guest and the lab checks above.

### Later stages

* **Stage 2 — one validator and a template.** The rules move into a Swift
  library, `UDeckPluginFormat`, that builds on macOS and Linux; the
  `udeck-plugin` command (`check`, `check-repo`, `new`, `run`) is shipped as
  release assets and a container image (built: [Where the command comes
  from](#where-the-command-comes-from)), and a repository pins one release
  in a lock file `udeck-plugin pin` writes (built: [The lock
  file](#the-lock-file)); uDeck links the same library; CI
  templates for GitHub Actions and GitLab CI, with a variable for a mirror of
  the image (built: in the template repository below); the version-bump and `minUDeck` checks; a template repository
  anyone can start from (built:
  [`udeck-plugins-template`](https://github.com/iillyyaa1997/udeck-plugins-template),
  with the check for GitHub Actions and GitLab CI); a plugin folder that is a
  link to a working copy, for development; a run log and the standard error of
  successful runs for authors. The bash check in uDeck's CI and the official
  repository's Python script go.
* **Stage 3 — branches, pull requests, verified.** Installing from a branch or a
  pull request, forks included; **Unverified**, on the card too; consent for
  every new content; **Verified** computed from content, with the switch to
  the merged version when a pull request lands; automatic daily updates for
  verified plugins; history rewritten on a branch detected and asked about.
* **Stage 4 — own and private sources.** `~/.udeck/sources.json`; GitLab,
  gitlab.com and self-hosted; tokens pasted from a pre-filled creation page, or
  **Sign in** — GitHub and gitlab.com by device flow, a self-hosted GitLab with
  its own application or a token; the Keychain; **Trust** per source and the
  **Trusted source** mark; plain messages for 401, 404 and limits.
* **Stage 5 — polish.** `udeck://install` links; the newest compatible version
  for an older uDeck, from history; Developer ID signing, which also ends the
  Keychain's question after every update; a list of revoked versions.

Deliberately later than all of these: a sandbox and enforced permissions;
secrets handed to plugins by uDeck; signed indexes; a website catalogue with
search and ratings; two copies of one plugin side by side; installing a
plugin's dependencies; compiled and notarised plugins; resident plugins;
Bitbucket, Gitea and GitHub Enterprise.
