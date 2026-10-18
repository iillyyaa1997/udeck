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
built** — stages 1, 2 and 3, which [Stages](#stages) lists, all but one step of
stage 2 marked in [The official repository](#the-official-repository): its
script deleted once `udeck-plugin check-repo` has agreed with it long enough —
and the first two parts of stage 4: a public GitHub repository, and a public
GitLab project — gitlab.com's or one's own GitLab's — added as a source of its
own ([Sources of one's own](#sources-of-ones-own)).
Anything that belongs to a later stage and is not built yet is marked where it
appears:

> **Later — stage 4.** Text like this describes something that is not built
> yet.

Later stages are written down so that stage 1 does not close a door they need —
a field reserved in a file, a rule that has to hold from the first plugin
published — not as work for stage 1.

Where this document says **measured**, it was measured on 2026-09-28 against
github.com. Where it says **by memory**, it was not checked and the first
builder to touch it confirms it.

---

## The whole path, in one paragraph

A plugin repository is a GitHub repository or a GitLab project with a small
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
to the five lines they make, byte for byte — through a file of its own, made
from a template in `TMPDIR` (`/tmp` without one), which puts it there whichever
`mktemp` makes it, and taken away whatever the answer. A test holds it to
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
    udeck_lock_expected=$(mktemp "${TMPDIR:-/tmp}/udeck-lock.XXXXXX") || return 1
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
lock="$(mktemp "${TMPDIR:-/tmp}/udeck-lock.XXXXXX")"
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
  new version that asks for something else asks again.
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

Any change of `version` re-asks the permission question — except when one
**Verified** copy replaces another and the new one asks for exactly what the old
one did: then the decision is carried to the new version
([Updating](#updating)).

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
uDeck's own version (`CFBundleShortVersionString`, `0.7.0` at the time of
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
  followed.json            what was last heard of the branch or the pull request each copy installed from one
                           came from — its head, merged or closed, gone, whether its new head continues what is
                           installed — and which of them the last read did not ask about
```

The catalogue does not live under `~/.udeck/cache/`, because every folder in
there belongs to a plugin of the same name, and a plugin called `catalogue` is
a legal id.

A listing is kept while it is the head of its source, while a plugin in
`installed.json` was installed from that commit (as its current or its previous
version), or while it is the head a branch or a pull request a copy came from
was last heard at (`followed.json`), so that what that head offers is read
again without asking. Blobs are kept while a kept listing names them. Everything else is
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
| Following a copy installed from a branch or a pull request, in each read — none for a copy the head already has | 1 (a `304` costs one too) | 0 |
| …its head moved | 1, once per commit: the head's listing | the copy's manifest there, unless it is stored |
| …and the copy is another tree there | 1, once for those two commits: a comparison with the commit installed | 0 |
| …a pull request merged into the default branch | 1, once: the listing of the commit it was merged as | 0 |

So an ordinary day costs one to three requests, one more for each copy of a
branch or a pull request, and installing costs none. Ten copies followed are
about ten requests a day, of the sixty an hour; a read nobody asked for asks
about none of them while the reserve below is all that is left.

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
* its size, from the listing: *"4 files · 6 KB"* — of a GitLab project, whose
  listing gives no sizes, *"4 files"*;
* a link to the folder on GitHub at that commit —
  `https://github.com/{owner}/{repo}/tree/{commit}/plugins/{id}`, or on its
  GitLab, `https://{host}/{path}/-/tree/{commit}/plugins/{id}` — which opens in
  the browser and is where the README is read: *Open on GitHub*, or *Open on
  gitlab.example*, on the host the page is on, whatever a test build reads its
  API from;
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

A GitLab project — on gitlab.com, or on a GitLab of one's own, at
`https://<host>/api/v4` — is read the same way, through GitLab's API, v4
(stage 4: [Sources of one's own](#sources-of-ones-own)). Every endpoint below
was **measured** anonymously on gitlab.com, and read-only on a self-hosted
GitLab 18.8.2, when stage 4 was designed. After **Look up** a project is always
asked for by its number, `/projects/{id}`; its path, URL-encoded with its `/` as
`%2F`, is used once, by **Look up** itself.

| Step | GitHub | GitLab |
|---|---|---|
| The project, by its path (**Look up** alone) | `GET /repos/{o}/{r}` | `GET /api/v4/projects/{group%2Fproject}` → `id`, `path_with_namespace`, `default_branch`; `404 Project Not Found` when it is not there, or private |
| Default branch, and its path now | `GET /repositories/{id}` → `default_branch`, `full_name` | `GET /api/v4/projects/{id}` → `default_branch`, `path_with_namespace` — and `forked_from_project` when the answer gives it, which anonymous gitlab.com's do not |
| Head commit, conditional | `GET /repositories/{id}/commits/{branch}`, `Accept: application/vnd.github.sha` | `GET /api/v4/projects/{id}/repository/branches/{branch}`, the name escaped whole, `/` too → `commit.id`; a weak `ETag` (`W/"…"`), and `304` to exactly that |
| Every path at a commit | `GET /repositories/{id}/git/trees/{commit}?recursive=1` | `GET /api/v4/projects/{id}/repository/tree?ref={commit}&per_page=100` — the root — and, only when the root has a `plugins` folder, `…&path=plugins&recursive=true&per_page=100`; each followed page by page by its `x-next-page`, until it names none. Each entry has `id` (the blob or tree SHA — git's own, measured), `type`, `path` (the whole path) and `mode`, and no size. A root without `plugins` is a repository that offers no plugins yet, and the second listing is never asked for: GitLab answers it `404 invalid revision or path Not Found` (measured) |
| One file | `raw.githubusercontent.com/{o}/{r}/{commit}/{path}` | `GET /api/v4/projects/{id}/repository/files/{path, escaped whole}/raw?ref={commit}`, with `X-Gitlab-Size` |
| A folder's history | `GET /repositories/{id}/commits?sha={branch}&path=plugins/{id}` | `GET /api/v4/projects/{id}/repository/commits?ref_name={branch}&path=plugins/{id}&per_page=100` → `id`, `committed_date` |
| A merge request | `GET /repos/{o}/{r}/pulls/{n}` | `GET /api/v4/projects/{id}/merge_requests/{iid}`: `opened` is open, `closed` and `locked` closed, `merged` closed and merged, as `merge_commit_sha` — or `squash_commit_sha` (not asked in stage 4) |
| Two commits compared | `GET …/compare/{base}...{head}` | `GET /api/v4/projects/{id}/repository/merge_base?refs[]={base}&refs[]={head}`: the same commit is identical, a merge base that is `base` ahead, one that is `head` behind, anything else diverged, with no counts; `400 Could not find ref` is a commit not there (not asked in stage 4) |
| A folder's page | `https://github.com/{o}/{r}/tree/{commit}/plugins/{id}` | `https://{host}/{path}/-/tree/{commit}/plugins/{id}`, and `…/-/compare/{a}...{b}`, `…/-/merge_requests/{n}`, `…/-/tree/{branch}` |

Every file is a request to the API — GitLab has no raw host to read a commit's
file from anonymously — and every one is hashed against the listing's `id`
before it is used, as GitHub's are. So **Earlier versions…** of a GitLab
source's copy costs up to 51 requests to the API — the folder's history and one
manifest per commit examined, at most 50 — where GitHub's raw host carries the
manifests. Every request carries `User-Agent: uDeck/<version>` and `Accept:
application/json`, from a session that keeps nothing; nothing carries a token
yet.

**A listing gives no sizes**, so rule 8 is held as the files arrive instead of
before: a row says how many files a plugin has, *"4 files"*, and no bytes; a
file that arrives larger than 5 MB — refused before it is read when GitLab says
its size, and read no further than one byte past 5 MB when it does not — stops
the install with *"plugins/gl-big/big.bin is 6.0 MB; one file of a plugin may
be up to 5 MB."*, and once the files that arrived add up to more than 10 MB the
rest is not asked for; either way staging is thrown away and nothing is
installed. A manifest larger than 5 MB is its plugin's alone: the catalogue is
read, and that row says its manifest could not be fetched. The number of files,
the names and the depth are still checked from the listing.

**What an answer's status says:** a success, and a `304` only for the head;
`404` not found; a `400` not found only where the endpoint answers a missing
ref or file so — the files endpoint, and the merge base's *Could not find ref*
— and a refusal anywhere else, so that a request uDeck got wrong never reads as
*"… or it is private"*; `401` and a `403` naming `insufficient_scope` are kept
apart for tokens; other `403`s and `429`s are the limit; a `3xx` that comes
back is a move; anything else a refusal. A request without a token follows a
redirect, as uDeck's session always has — so a `3xx` comes back today only when
it names nowhere to go — and a description that came through a redirect is
believed only when it names the project's number, and then its path is taken
as a rename; one naming another number, or none, is refused, and every file is
hashed against the listing. A request with a token never follows one (later in stage 4).

**GitLab's limits** come without the `x-` — `ratelimit-remaining`,
`ratelimit-reset` in Unix seconds, `ratelimit-name` (measured) — and gitlab.com
counts by more than one limiter, naming the one each answer was counted by:
`throttle_unauthenticated_api`, which resets each minute, and
`unauthenticated_traffic_per_ip`, which resets on the hour — from 2026-10-19 60
an hour per network address without a token, `304`s counted (GitLab's own
announcement; not measured). So each limiter's pair is kept apart, by its name,
in the source's own `state.json`, and a read nobody asked for goes by the one
with the least left that has not reset: the reserve of ten is kept of that one.
A `429` with `Retry-After` stops every request of that source until then, and
the source says *"gitlab.com asked uDeck to wait: its limit of requests from
this network, or for this token, is used up. The list below is from 14:02; uDeck
will look again after 15:07. Without a token gitlab.com allows only a few
requests an hour from one network; a token raises the limit."* — the last
sentence for gitlab.com read without a token alone. A self-hosted GitLab sends no
limit at all (measured), and there only a `429` counts. Each GitLab source has a
limit of its own — a GitHub block never stops a GitLab, nor one GitLab another
— and two anonymous gitlab.com sources each keep their own count, though the
network's is one.

> **Later — stage 4.** Tokens: `PRIVATE-TOKEN: <token>` for a pasted GitLab
> token, `Authorization: Bearer <token>` for GitHub's. A private GitHub source
> is read through the API's contents endpoint rather than the raw host. Tokens
> are kept in the Keychain, bound to the address they were checked against, sent
> only to their own host, and never followed across a redirect.

---

## Sources of one's own

Beside the official catalogue, the operator can add a repository of their own
— or a team's — as a **source**: its default branch is a catalogue of its own,
with **Install**, **Update**, **Earlier versions**, **Back to**, **Reinstall**
and **Remove** as the official one has them. Nobody vouches for it: its
plugins are **Unverified**, and ask before they run, whenever their code
changes ([Consent for unverified code](#consent-for-unverified-code)).

> **Later — stage 4.** Private sources read with a token kept in the Keychain
> or by **Sign in**, and **Trust…** with the **Trusted source** mark. Today a
> source is a public repository on github.com, or a public project on a GitLab
> — gitlab.com, or one's own at `https://<host>/api/v4`.

### `sources.json`

`~/.udeck/sources.json` lists the sources added, in the order Settings shows
them. The official source is not in it: it stays built in, from `Info.plist`.
It is written atomically, like `installed.json`, and it never holds a secret.

```json
{"version": 1, "sources": [
  {"id": "github.com-team-plugins-87a735c2", "provider": "github", "host": "github.com",
   "path": "someone/team-plugins", "remoteID": 123456789, "access": "none",
   "trustedAt": null, "addedAt": "2026-10-20T11:00:00Z"}]}
```

| Field | Meaning |
|---|---|
| `id` | What every record of a copy of the source says it came from (`installed.json`'s `source`), the name of its cache, `~/.udeck/catalogue/<id>/`, and later the key of its token: `<slug>-<hash8>`. `hash8` is the first 8 hexadecimal digits of SHA-256 over `<provider>\n<lowercased host>\n<remoteID>`, so a renamed repository keeps it and a new repository made at the old name gets another. `slug` — the host, `-` and the path's last segment when it was added, lowercased, every character outside `[a-z0-9.-]` a `-`, at most 40 — is only for a person reading `~/.udeck`. An id always matches `^[a-z0-9][a-z0-9.-]{0,40}-[0-9a-f]{8}$`: never `official`, always a safe folder name. |
| `provider`, `host` | `github` and `github.com`, or `gitlab` and a GitLab's host — `gitlab.com`, or one's own, lowercased, with a port when it has one other than 443. |
| `path` | `owner/repo`, or `group/…/project`, as the host spells it now: for the pages a person opens and for GitHub's raw host. Written back whenever a describe of it, by its number, says another. |
| `remoteID` | The number GitHub knows the repository by, or GitLab the project, which neither a rename nor a transfer changes. Every request after **Look up** addresses it by that number. |
| `access` | What the Keychain is expected to hold for it: `none` today. |
| `trustedAt` | `null` today; when it was trusted, later. |
| `addedAt` | When it was added. |

A key uDeck does not know is ignored, and written back as it was. An entry it
cannot use — a provider it does not know, no `remoteID`, a host or a path it
would not read as an address — is left out, said on the group's problem line,
and written back as it was. The whole file is **broken** when an entry's id is
not the one derived from its provider, host and `remoteID`, when two entries
share an id or a repository — entries left out counted — or when it does not
parse: it is said, and never written over, and while it is broken no source is
read, added or removed, and every copy of one is held to its tree.

`sources.json` is not a boundary against plugins: a plugin runs as the operator
and can write it, as it can write `grants.json` and the plugin folders.

### Adding a source

Settings → Plugins gets a group after **Official catalogue**, **Your sources**,
which starts with **Add a source…**. It opens a sheet in the pane, as **Install
from a link…** does, with one field — *github.com/owner/repo or
gitlab.com/group/project* — and **Look up**. The address is read as a browser
shows it, `https://` and `www.` or not, and any page of a repository comes to
the repository (`SourceLink`). Refused before any request, each saying what to
paste instead: `http://` (*"Sources are read over HTTPS only…"*), git's SSH
address, an address with a login in it, a github.com page that is no
repository, and the official repository itself (*"That is
github.com/iillyyaa1997/udeck-plugins, the official catalogue…"*). Any other
host is a GitLab's — gitlab.com, `www.` or not, or one's own, with a port if it
has one: the project is the path before GitLab's separator `/-/`, `.git`
dropped, 2 to 20 segments, nested groups and all, so
`https://gitlab.example/group/sub/team/-/tree/main` is `group/sub/team`.

**Look up** asks github.com anonymously, three requests (`SourceLookUp`):

1. `GET /repos/{owner}/{repo}` — the one request ever addressed by its name —
   which says its number (`id`), its name as GitHub spells it and its default
   branch;
2. `GET /repositories/{id}/commits/{branch}` with `Accept:
   application/vnd.github.sha` — its head, by its number;
3. `udeck-plugins.json` at that commit, from the raw host.

Of a GitLab project it asks the GitLab's API anonymously, three requests:

1. `GET /api/v4/projects/{group%2Fproject}` — the one request ever addressed by
   its path — which says its number (`id`), its path as GitLab spells it and its
   default branch;
2. `GET /api/v4/projects/{id}/repository/branches/{branch}` — its head;
3. `GET /api/v4/projects/{id}/repository/files/udeck-plugins.json/raw?ref={commit}`.

A host whose `404` is not GitLab's — a web server's own page, no GitLab behind
it — says *"gitlab.example did not answer as GitLab. uDeck reads sources on
github.com and on GitLab — gitlab.com or your own."*, and offers nothing. A
project GitLab answers with no default branch — an empty repository, or one
whose code only its members may read (what GitLab answers then is not measured)
— is said as one not found or private.

The sheet shows the passport's name — cleaned, inside an isolate, or the
address instead ([What a source is called](#what-a-source-is-called)) — its
description and the address, with **Add**. A repository that is added already
is said so once its number is known (*"Team plugins (github.com/…) is added
already."*); one with no passport at the top of its default branch is *"… is
not a uDeck plugin repository: there is no udeck-plugins.json at the top of
main."*, and one that is not there, or private, *"… could not be found, or it is
private. If it is private, uDeck needs a token for it: Token…"*; none of them
offers **Add**. Nothing is added until **Add** is pressed.

**Add** writes the entry with the id derived from its number, keeps the default
branch and the passport **Look up** heard in `~/.udeck/catalogue/<id>/`, and
reads its catalogue at once. Its block shows its name and its address, *"Not
trusted: nobody vouches for these plugins — each asks again whenever its code
changes."*, when it was read or why it was not — naming its host and its
address — **Check now**, **Remove…**, and its catalogue's rows, drawn as the
official ones are, marked **Unverified**, never **Verified**. A build that
reads github.com, or any host, from somewhere else than the build as shipped —
the lab's — says so under **Your sources**: *"Test build: api.github.com is
read from http://127.0.0.1:8766/api."*, and for each host `UDeckPluginsHostMap`
sends elsewhere, *"Test build: gitlab.example.test is read from
http://127.0.0.1:8768."*

**Remove…** says first what it does — *"Remove Team plugins
(github.com/someone/team-plugins)? uDeck stops reading it and forgets its token.
What was installed from it stays and keeps running; …"* — and then takes the
entry and `~/.udeck/catalogue/<id>/` away. Nothing more is asked of it. What
was installed from it stays and runs, its row saying *"From github.com/… — a
source no longer added"*, and nothing updates, reinstalls or puts it back until
the source is added again: added again, it gets the same id, and its copies are
its own again.

**Install from a link…** of a repository that is no fork of the official one
says *"github.com/someone/team-plugins is not a fork of
github.com/iillyyaa1997/udeck-plugins. To install from it, add it as a source of
its own."*, with **Add as a source…**, which opens **Add a source…** with the
repository's address filled in; and of a link to another host, *"gitlab.example
is not GitHub. A GitLab project can be added as a source of its own."* — with
**Add as a source…** and the project's page filled in when the link reads as a
GitLab project's, a port and all. A link into a source added — a branch of
it, its page, a pull request; of a GitLab project, a branch, its page, a merge
request — is refused before any request: *"Installing from a
branch or a merge request of a source is not possible yet; add the project and
install from its default branch."*

### Reading a source

A source is read as the official catalogue is
([Reading a repository without downloading it](#reading-a-repository-without-downloading-it)),
with its own cache, `~/.udeck/catalogue/<id>/`, and every API request
addressed by its number: `/repositories/{id}`, `…/commits/{branch}`,
`…/git/trees/{commit}`, `…/commits?sha=&path=` — never `/repos/{owner}/{repo}/…`
(GitHub answered all of them anonymously when stage 4 was designed,
**measured**). Raw files come from the raw host by the name it has now, at a
commit, and each is hashed against the listing asked by its number, so a
repository made later at an old name can serve nothing that passes. When the
daily describe — `GET /repositories/{id}` — says the repository is called
something else now, that name is written back to `sources.json` under the same
id, and from then on its files are asked by it. A source read without a token
counts against the official source's hourly limit, as GitHub counts what an
address asks whatever the repository.

A GitLab project is read the same way through its GitLab's API
([GitLab](#gitlab)), every request to `/api/v4/projects/{id}/…`: its describe
writes its path back as GitHub's does, its files come from the files API, each
hashed against the listing, and it is counted against a limit of its own, kept
in its `state.json`.

A source is read on the official source's schedule
([What uDeck fetches, and when](#what-udeck-fetches-and-when)), each by its own
state: a few seconds after launch unless it was read in the last day, then
once a day, a failure again after an hour, when Settings → Plugins is opened
and its list is more than an hour old, and when **Check now** on its block is
pressed. Reads go one at a time, the official source first, then each source
in `sources.json`'s order. **Official catalogue** governs the official
repository alone: a source added is read until it is removed, whatever the
switch says, and a copy of it is updated, reinstalled, put back and given its
earlier versions from it, through its own client — never the official one's.

**The official repository's number.** The official source stays addressed by
its path, as in stage 3 — its forks are found by theirs — and its daily
describe is held to the number the build knows it by (`UDeckPluginsRepositoryID`,
1393324153 as shipped): one that answers another number, or none, is the
official address belonging to a different repository now. The read stops there,
before anything of that repository is read; Settings says *"The address of the
official catalogue now belongs to a different repository. uDeck stopped reading
it, and nothing updates by itself; installed plugins keep running."*; every
later read asks the number again first, and one that fails before a describe
answers leaves that sentence standing; and until a describe answers the
official number again, nothing else is asked of the official address: no verified
copy updates itself, the catalogue's rows read before are taken off the screen,
its copies are offered no **Update**, **Reinstall** or **Earlier versions…**,
and no **Back to** a copy of the official repository, and **Install from a link…** says the same sentence before any
request.

### What a source is called

A source's name is its passport's `name`, somebody else's text: characters of
the Unicode categories Cc, Cf, Zl and Zp — controls, the zero-width and
bidirectional ones among them — are taken out, and what is left is shown inside
an isolate (U+2068 … U+2069), so that it cannot reorder the address beside it.
The address is shown instead when no passport has been read, when nothing is
left of the name, and when it is — trimmed, whatever its case — the official
passport's name or `uDeck plugins`: a passport cannot dress up as the official
one. Every row and every warning names the address too.

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
asks, and a new `version` asks again — unless it replaced a **Verified** copy
asking for exactly what that one asked ([Updating](#updating)).

One install, update or removal runs at a time. They are rare, and doing them
one after another is what keeps `installed.json` and the plugins folder from
ever being written by two of them at once.

### Installing from a branch or a pull request

**Install from a link…** in Settings → Plugins, next to **Link a folder…**,
takes a github.com link pasted as the browser shows it — `https://` and `www.`
or not — and reads what it names before anything is asked of GitHub
(`RepositoryLink` in UDeckCore):

* a pull request of the official repository, `github.com/<official>/pull/3`,
  and any page under it — `…/files`, `…/commits`;
* a branch of it, `…/tree/<branch>`, and any folder under it: the branch is
  everything before the last `plugins/<id>`, so `…/tree/fix/uptime/plugins/uptime`
  is `uptime` on `fix/uptime` — a name holding a `/` reads as itself — and
  only that plugin is listed; when it is what the catalogue has, or is not
  there at all, the sheet says that of it — *"uptime in branch fix/uptime is
  what the catalogue already has"*, *"Branch fix/uptime has no
  plugins/uptime"* — not of every plugin on the branch;
* its own page, or its default branch: that is the catalogue, and the sheet
  says so — *"That is the default branch of github.com/…: its plugins are the
  catalogue below, verified."*;
* a branch of a fork of it, `github.com/<owner>/<repo>/tree/<branch>`, and
  any folder under it, read the same way — and a fork's own page,
  `github.com/<owner>/<repo>`, which stands for its default branch.

Everything else is refused before a request, each refusal saying what the link
is and what to paste instead: one commit — `…/commit/<sha>`, or `…/tree/<sha>`,
GitHub's *Browse files* at a commit (*"Installing a single commit is not
possible yet"*, stage 5); another host; another repository's pull request —
*"… Paste the link of its branch instead: a branch of a fork of
github.com/iillyyaa1997/udeck-plugins can be installed from."*; a name git does
not allow for a branch; a page that names no branch and no pull request.
Whether another repository is a fork of the official one only GitHub can say,
so that is asked first (below), and a repository that is not — one of its
own, or a fork of something else — is refused once it has said so:
*"github.com/someone/elsewhere is not a fork of
github.com/iillyyaa1997/udeck-plugins. To install from it, add it as a source of
its own."*, with **Add as a source…** ([Adding a source](#adding-a-source)).

**Look up** then asks GitHub (`RefResolver`) — through the official
repository, for its pull requests and its branches: for a pull request `GET
/repos/{o}/{r}/pulls/{n}`, which says its head, its state and whether it was
merged in one answer; for a branch its head, `GET
/repos/{o}/{r}/commits/refs/heads/<branch>`; then the listing of that commit,
unless the cache has it, and from the raw host, at that commit, the manifests
of the plugins there whose tree is not the one the catalogue's head has for
the same id — new there, or changed. Two requests to the API, and nothing for
the default branch, which the catalogue already knows. A pull request opened
from a fork is read the same way, by commit, through the official repository:
its head is there whoever opened it, even after the fork is deleted, so
nothing is ever asked of the fork, and the fork's name is not recorded.

**A branch of a fork** is read from the fork itself: whether GitHub serves a
commit of a fork that no pull request names through the official repository
was never measured. First `GET /repos/{owner}/{repo}`, one request, whose
answer says whether it is a fork and of which network — `fork` true, and
`source.full_name` the official repository, however many forks deep it is
(fields **measured** when stage 3 was designed: `AmanShaikhTech10/Hello-World`
answers `fork` true and `octocat/Hello-World` as its `parent` and its
`source`); anything else is refused there, and nothing more is asked of it.
Then the fork's branch's head, `GET /repos/{owner}/{repo}/commits/refs/heads/<branch>`
— of a fork's own page, the default branch its description names — its
listing, and the manifests from the raw host, at
`{owner}/{repo}/<commit>/<path>`: three requests to the API, all of the fork,
through a client for it on the same host that counts against the same limit,
since GitHub counts what an address asks whichever repository it asks about
(`GitHubClient.client(for:)`). The fork is named as GitHub names it in that
answer — renamed, or spelt in another case, its own name from then on.

**The sheet** under the button says the line of history and the commit it was
read at — *Pull request #3 at a1b2c3d*, *Branch fix/uptime at a1b2c3d*,
*Branch x of someone/udeck-plugins at a1b2c3d* — with a link to its page, a
pull request's title as its author wrote it, and whether
it was merged or closed without being merged; then *"Nobody verified what is
listed here: it is not what the repository merged…"*, and one row per plugin,
each marked **Unverified**, with what it asks for and **Install**. **Install**
takes the plugin's folder at that commit, exactly as **Install** on a
catalogue row takes it — [the same steps](#what-happens-when-install-is-pressed),
from `plugins/<id>/` at the commit, from the raw host of the repository the
line is in — the official one's, or the fork's — and no API request — and
records `ref` `pr` and the number, or `branch` and its name, `unverified`, by
nobody, with `repository` the fork for a fork's branch. Installed, the plugin
asks before it runs, even when it asks for nothing, and again whenever its code
changes ([Consent for unverified code](#consent-for-unverified-code)).

**Over a copy from another line of history** — the verified copy, most often —
**Install** says first what goes and what comes, both sources and the ref:
*"uptime is the verified 1.0.0 from github.com/iillyyaa1997/udeck-plugins;
installing 1.0.1 from pull request #3 at a1b2c3d replaces it. Its windows and
settings stay. Nobody verified the code that comes: it asks before it runs,
unless you allowed exactly that code before."* — the decision there was stays
in `grants.json`, but code nobody verified runs only on a decision made for
its tree ([Consent for unverified code](#consent-for-unverified-code)). Nothing
changes until that is confirmed, and only while it still says what is there
(`ShownPlace.Switch`).
The verified copy becomes `previous`, so **Back to 1.0.0** puts it back — with
the same warning the other way round. The same pull request at a later head is
the same line: no warning, an update.

**Switch to verified.** The catalogue row of an id installed from a branch or a
pull request says *"Installed here from pull request #3: unverified"* and
offers **Switch to verified 1.0.0** — on the plugin's own row too — which puts
the catalogue's copy in its place after the warning that names both: *"uptime
is 1.0.1 from pull request #3 at a1b2c3d; installing the verified 1.0.0 from
github.com/iillyyaa1997/udeck-plugins replaces it. Its windows, settings and
your permission decision stay."* The pull request's copy becomes `previous`.
Its folder gone, the catalogue row still says so — *"Installed here from pull
request #3: unverified — uptime is not in ~/.udeck/plugins"* — and **Switch to
verified** puts the verified copy where nothing is, without a warning, since
nothing there is replaced; the row never offers **Reinstall**, which would put
the pull request's code back under its **Verified**. **Reinstall** on the
plugin's own row does that, beside *pull request #3 at a1b2c3d*. **Earlier versions…** on such a copy lists the default
branch's history, and choosing a line is the same switch, said the same way.
Nothing offers such a copy an update against the catalogue's head: a branch's
or a pull request's copy is not an older version of the verified one, and it
never updates by itself. What it is offered is what its own branch or pull
request has ([Following the branch or the pull request a copy came
from](#following-the-branch-or-the-pull-request-a-copy-came-from)) — and, once
its pull request is merged, what was merged, below.

**Official catalogue** governs this as it governs every request to the
official repository and its forks: off, **Install from a link…** is greyed out
and says why, and plugins installed from a link keep running.

**A fork's copy** is named with its fork wherever its line of history is
named — *Unverified · branch x of someone/udeck-plugins at a1b2c3d* on its row,
*Installed here from branch x of someone/udeck-plugins: unverified* on the
catalogue's, *Changed in branch x of someone/udeck-plugins, still 1.0.1*, a
warning's *1.0.1 from branch x of someone/udeck-plugins at a1b2c3d* — so that
the official repository's `x` and a fork's `x` are never one name: one in the
place of the other is a switch of source, and its warning names both. It is
followed in the fork ([Following the branch or the pull request a copy came
from](#following-the-branch-or-the-pull-request-a-copy-came-from)), its *What
changed* opens the fork's compare page, and **Back to** puts a fork's copy back
from the fork, by the `repository` its `previous` keeps. A fork's copy whose
folder is exactly what the catalogue's head has is what was merged, and becomes
the default branch's, **Verified**, like any other (`Adoption`). A fork's
default branch is never taken as the official one's (`PluginOrigin.mayBeTaken`).

Other repositories — one of their own, or a fork of something else — are
sources of their own ([Sources of one's own](#sources-of-ones-own)).

> **Later — stage 4.** **Trust** on a source.

### When the pull request is merged or closed

**Verified is computed from content, not from a ref.** A copy installed from a
pull request — or a branch — of the official repository becomes **Verified**
the moment the tree of its folder is the one the default branch's head has for
its id: that is what a maintainer merged, squash merges and rebases included,
since a folder's tree is git's hash of exactly its files. Each time the plugin
folders are hashed once the catalogue has been read — after every read of it,
at launch, after anything in the plugins folder changes — a copy whose folder
still hashes to the tree it was installed as, and whose tree the head has, is
**adopted**, unless an install, update or removal is running, which the
hashing after it asks again: its record alone is rewritten — the official
source, its own repository, `ref` the default branch, `commit` the head,
`verified` by `official` — with nothing downloaded and nothing swapped: the
folder, its windows, its cache, `previous` and its permission decision stay as
they are, and the decision holds for its version, as any verified copy's does,
so the card does not ask again. From then on the copy
follows the default branch like any verified copy; what uDeck had heard of its
pull request is forgotten. A copy changed on disk since it was installed is not adopted:
nobody merged what it is now. The rule is `Adoption` in UDeckCore, tested
there; the installer applies the same rule, so that **Reinstall**, **Back to**
or **Install** of a branch's or a pull request's copy that is exactly what the
head has records it as the default branch's at once.

**What became of the pull request** is asked at the catalogue's own moments,
in the same read, after the catalogue: for each copy installed from a pull
request whose tree the new head does not have, `GET /repos/{o}/{r}/pulls/{n}`,
one request, which says whether it is open, closed or merged, the branch it was
opened against and merged into (`base`), and the commit it was merged as; once
it is merged into the default branch, the listing of that commit, once per
commit and then from what was kept. A pull request merged into any other
branch verifies nothing — only the default branch is protected and validated —
so that commit is never listed and the copy never adopted there; its row says
what an open one's does, **Unverified** and nothing more, and it is asked about
again at the next read. A read nobody asked for asks nothing while the
[reserve](#githubs-limits) is all that is left, and what was heard before
stands. What was heard is kept in `catalogue/official/followed.json`, by plugin
id — not in `installed.json`, which says where a copy came from and not what
became of it (`RefFollower`, `FollowedPull`). The asking runs away from
the main thread: a copy installed, adopted or removed while it waits keeps what
that said of it (`RefFollower.Outcome.merged`). The same answer says where the
pull request's head is now: a head that moved is offered as an update until
the pull request is merged into the default branch ([Following the branch or
the pull request a copy came
from](#following-the-branch-or-the-pull-request-a-copy-came-from)).

* **Merged into the default branch, which moved on before uDeck looked** — the head
  has another tree, the commit the pull request was merged as has the copy's:
  the copy is adopted at that commit, which lies on the default branch, and the
  update the head has for it follows as for any verified copy — [by
  itself](#automatic-updates), or offered.
* **Merged as something else** — a maintainer changed it before merging, and
  neither the head nor the commit it was merged as has the copy's tree: its row
  says *"Pull request #3 was merged, and the verified version differs —
  update"*, with *What changed* and **Update**, which puts the catalogue's copy
  in its place after the warning that names both, as **Switch to verified**
  does; it counts among the updates waiting, and is never made by itself — the
  copy on disk is still code nobody verified, and what comes is not what was
  allowed. The catalogue row says *"Installed here from pull request #3:
  unverified — merged, and the verified version differs"*, and its button for
  that copy says **Update** too: one press, one name on both rows
  (`UnverifiedRow.verifiedButton`). With no verified
  version to offer — the catalogue does not have the plugin, cannot install it
  here, or is switched off — the row says instead *"Pull request #3 was merged;
  no verified version is offered here, and the plugin keeps running"*, with
  nothing to press for it, and nothing is counted as waiting.
* **Closed without being merged**: its row says *"Pull request #3 was closed
  without being merged; the plugin keeps running"*, and so it does — nothing is
  removed or switched; **Switch to verified** and **Remove** are there. The
  catalogue row says *"… unverified — closed without being merged"*. Opened
  again, it is not said any more.

Installing from a pull request already merged or closed: the sheet says so
(*"This pull request was merged. … what the repository merged is in the
catalogue."*, *"This pull request was closed without being merged."*) — and,
merged into another branch than the default one, that nothing of it is
verified: *"This pull request was merged into next, not the default branch:
what is listed is its head, and nothing of it is verified."* (a merge into a
branch GitHub did not name, or while the default branch is not known, is said
as a merge; `LinkRefusal.head`) — and what
**Look up** heard is kept with the copy (`FollowedRefs.keep`), so that its row
says what became of it — a closed one at once, a merged one at once when uDeck
has the listing of the commit it was merged as, and otherwise at the next read
of the catalogue — and a copy that is what the head has is the default
branch's from the start. Which of these a copy comes to is `PullRequestLifecycle` in
UDeckCore, tested there.

### Following the branch or the pull request a copy came from

A copy installed from a branch or a pull request is offered what its own line
of history has now — never the catalogue's head, which is another line — and
never anything by itself. It is asked at the catalogue's own moments, in the
same read, after the catalogue and its pull request's state — a pull request,
and a branch of the official repository, through the official repository; a
fork's branch through the fork, its head, its listing and its comparison
alike, counted against the same limit (`RefFollower`):

* **A pull request**: the same `GET /repos/{o}/{r}/pulls/{n}` that says
  whether it was merged or closed says where its head is.
* **A branch**: `GET /repos/{o}/{r}/commits/refs/heads/{branch}` with
  `Accept: application/vnd.github.sha` and `If-None-Match: "<the commit
  installed>"` — GitHub's `ETag` for a head is its commit (**measured** when
  stage 3 was designed), so nothing is stored for it: a branch that did not move
  answers `304`, which costs one request all the same; one that is not there
  answers `422`, and its row says *"Branch fix/uptime no longer exists; the
  plugin keeps running"* — and so it does, with **Switch to verified** and
  **Remove** there, and nothing offered along it.
* **When the head moved off the commit installed** — a branch, or a pull
  request not merged into the default branch — the new head's listing (once
  per commit), and the copy's manifest there from the raw host unless it is
  stored. A head whose folder for the copy is the copy's offers nothing.
  Otherwise its row offers it, as the catalogue's rows offer theirs: *"Changed
  in pull request #3, still 1.0.1"*, *"1.0.2 available in branch fix/uptime"*,
  *"Pull request #3 now has 1.0.0"* (**Switch to 1.0.0**), *"uptime is no
  longer in pull request #3; the plugin keeps running"*, or why the version
  there cannot run here — with *What changed*, which opens
  `https://github.com/{owner}/{repo}/compare/{installed commit}...{head}` in
  the line's repository, and **Update**. A newer version or other files count
  among the updates waiting.
* **Whether the new head continues what is installed** is one more request,
  once for that pair of commits, then kept:
  `GET /repos/{o}/{r}/compare/{installed commit}...{new head}`. `ahead` — it
  continues it — is an ordinary offer; `behind` (the branch went back),
  `diverged` (pushed again over it), or the commit installed not there any more
  (`404`) is history rewritten, and the row says so above the offer: *"The
  history of pull request #3 was rewritten: its new head does not continue what
  is installed"*. Nothing is installed either way. The default branch is never
  compared with: a pull request merged by a squash has gone another way from it
  too (`b8bdbba...7403916`, diverged, **measured** when stage 3 was designed),
  and that rewrote nothing. uDeck keeps no copy of what was rewritten away: a
  later **Back to** or **Reinstall** of that commit fetches it from GitHub, and
  once GitHub has let it go it changes nothing and says why — *"a1b2c3d is no
  longer on GitHub — the history it was on may have been rewritten — so
  nothing can be installed from it; nothing was changed."* (said of any install
  at a commit whose listing GitHub no longer has, an earlier version
  included), or, its listing still in the cache, which file could not be
  fetched. Which of these a comparison
  says is `HistoryRewrite` in UDeckCore, tested there; GitHub answers a
  comparison with every file that differs, however few commits are asked for
  (161 053 bytes for one squash merge, **measured** when stage 3 was
  designed), so uDeck asks for one commit (`per_page=1`) and reads three
  fields. Measured on 2026-10-13 against `iillyyaa1997/udeck`, through `gh`
  (with a token): a branch's head asked as one escaped path segment, as uDeck
  asks it — `commits/refs%2Fheads%2Flab%2Fr5-2` — answered its commit, with
  that commit in quotes as the `ETag`, and `304` when asked with it; a
  comparison answered `ahead` of a commit made on the other, `diverged`
  (ahead 1, behind 1) of two commits made on the same parent, and `404` for a
  commit that is not there.
* **Update**, pressed, installs the head's folder from that line, exactly as
  any install does — `previous` is the copy it replaces, so **Back to** puts
  it back — and the card asks before it runs: new code nobody verified is
  asked about whatever it asks for ([Consent for unverified
  code](#consent-for-unverified-code)). Over the operator's work or a link,
  the warning comes first, as for any update; there is no switch of source to
  name.
* **A read nobody asked for** — at launch, once a day — asks about none of
  this while the [reserve](#githubs-limits) is all that is left, looked at
  before each copy and again before a listing or a comparison one needs: what
  was heard before stands, still offered, and the row says since when it was
  not checked — *"Pull request #3 not checked since 14:02"* — until a read
  asks again; **Check now** asks within the reserve. A limit reached, or a
  request that failed, leaves the copy the same way — and so does a read of
  the catalogue that did not get as far as these questions: one left for
  later because the reserve was all that was left before it began, or one
  that failed.
* **A copy installed from a branch through [Install from a
  link…](#installing-from-a-branch-or-a-pull-request)** is followed from the
  head **Look up** heard — the commit installed — as heard when **Look up**
  heard it, whatever a read heard of the branch before that: an older head,
  or no branch at all. What a read heard after it — the sheet can stay open
  across the daily read — is newer and stands: the branch deleted, or at
  another head, which its row offers. A pull request's the same way: closed
  after **Look up**, it is said closed (`FollowedRefs.keep`). Put back or
  updated along it, what was heard of the line stands. What was heard of a
  branch is held to its repository: the official repository's `x` is not a
  fork's `x`.

What was heard is kept in `catalogue/official/followed.json` beside what was
heard of pull requests — a branch's head, or that it is gone; whether a new
head continues the commit installed, held for exactly those two commits; and
the copies not checked, with since when (`FollowedBranch`, `HeadHistory`,
`FollowedRefs`). **Earlier versions…** of such a copy lists the default
branch's history, as before: a commit of a pull request is not a version.
What a copy's row says and offers is `RefOffer` and `UnverifiedRow` in
UDeckCore, tested there.

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
        "version": "1.0.0",
        "repository": {
          "provider": "github",
          "host": "github.com",
          "path": "iillyyaa1997/udeck-plugins"
        }
      }
    }
  }
}
```

| Field | Type | Meaning |
|---|---|---|
| `version` | integer | The format of this file. Currently `1`. |
| `plugins` | object | Keyed by plugin id — the same id as the folder. |
| `source` | string | The source it was installed from: `official`, or the id of a source of one's own ([`sources.json`](#sourcesjson)). |
| `repository` | object | Where that source pointed when the plugin was installed: `provider` (`github`; later `gitlab`), `host`, and `path` (`owner/repo`) — for a source of one's own, as it was named then; the copy is read again through the source, by its number, whatever it is called now. A copy, so that the record still says where the plugin came from after the source is renamed or removed. For a copy of a branch of a fork, the fork — as GitHub named it when it was looked up — on the source's host; the `source` is still `official`. |
| `ref.kind` | string | `default` — the source's default branch; `branch` — another branch; `pr` — a pull request. Reserved for later: `commit`. A kind uDeck does not know is read as it is written, and is unverified. |
| `ref.name` | string or null | The default branch's name (`main`); the branch's name; the pull request's number, as a string. |
| `commit` | 40 hex characters | The commit the files were taken from. |
| `tree` | 40 hex characters | The tree SHA of `plugins/<id>` at that commit — and so of the folder on disk, as it was installed. |
| `version` | string | The manifest's `version` at that commit. |
| `installedAt` | ISO-8601 time, UTC, whole seconds | When this copy was put in place. |
| `pinned` | boolean | `true` when the operator chose this version over the newest one — an earlier version, or **Back to 1.0.0**. A pinned plugin is still told about newer versions, and [updates by themselves](#automatic-updates) leave it alone. **Update** clears it. |
| `verification.status` | string | What the folder was, the last time uDeck looked: `verified`, `modified`, `unverified`; `trusted` later. A status uDeck does not know — a later uDeck's — is read as `modified`, rather than making the whole file unreadable: it is recomputed anyway. |
| `verification.by` | string or null | Whose guarantee it is: `official`, or (later) the trusted source's id; `null` when nobody's. |
| `verification.checkedAgainst` | 40 hex characters or null | The commit of the default branch the folder was compared against. |
| `verification.checkedAt` | ISO-8601 time | When. |
| `previous` | object or null | The copy this one replaced — `ref`, `commit`, `tree`, `version`, and the `repository` it came from — so that **Back to 1.0.0** is one click, from where that copy came: a pull request's copy goes back as the pull request's. `null` after a first install. A copy recorded before there were branches and pull requests has no `repository`: it came from the source's own. |
| `automatic` | `true`, or absent | Present only on a copy uDeck put in place by itself — a verified plugin [updating itself](#automatic-updates) — and the row says *Updated by itself on October 10, 2026*. Any press that installs writes the record without it. A uDeck from before automatic updates reads the record and skips the key. |

**`verification` is recorded, not trusted.** It is recomputed every time the
plugins folder is read, and after every refresh; uDeck writes it back only when
it changed. It is kept so that Settings can show where a plugin stands the
moment it opens, and so that "verified as of this commit" can be read back
later. Nothing — least of all a consent decision — is ever taken from the
stored value alone.

How it is computed:

* The folder's tree SHA, hashed now, differs from `tree` → **`modified`**, by
  nobody.
* Otherwise, `source` is `official` and `ref.kind` is `default` → **`verified`**,
  by `official`. Every commit uDeck installs from the official source comes
  either from resolving its default branch or from that branch's history, and
  force pushes to it are refused, so the commit is one somebody merged.
* Otherwise — a branch, a pull request, a kind of ref uDeck does not know, the
  default branch of a source of one's own — **`unverified`**, by nobody:
  exactly what was installed, and code nobody verified. Its row says **Unverified**, not *Modified locally*. Unless that
  is exactly what was merged: then the record itself becomes the default
  branch's ([When the pull request is merged or
  closed](#when-the-pull-request-is-merged-or-closed)).

The ref is carried through every button that puts a copy back: **Reinstall**
puts back the record's own copy from its own repository and ref, and **Back
to** the previous copy from its `repository` and `ref`, so a pull request's
copy put back is recorded as the pull request's again — never as the default
branch's, which would make it **Verified** — unless the folder it puts back is
exactly the one the catalogue's head has for that id, which is what was merged:
then it is recorded as the default branch's, at the head (`Adoption`, applied
by the installer itself) — and its warning names it so, the verified copy it
becomes, not code nobody verified (`ShownPlace.recordedAs`). An earlier version is a version the
default branch had, and is installed as the default branch's. A default
branch's copy is taken from the source's own repository and from nowhere else:
a `previous` whose `repository` is another — a fork — and whose ref is the
default branch is refused, as not found, before anything is fetched
(`PluginOrigin.mayBeTaken`), since it would be recorded as the source's own.

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

Over a copy from another line of history — a branch's or a pull request's copy
in the verified copy's place, or the other way round — every button that would
replace it says first what goes and what comes, both sources and the ref
([Installing from a branch or a pull request](#installing-from-a-branch-or-a-pull-request)),
and the Settings row says where the copy on disk came from: *From
github.com/iillyyaa1997/udeck-plugins at 5c3e0d2*, or **Unverified** · *pull
request #3 at a1b2c3d*, with a link to its page.

**Across sources**, the same: one copy per id, whichever source it came from.
In a source's catalogue, the row of an id installed from elsewhere — the
official source, or another source — says *"Installed here: the verified 1.0.0
from github.com/iillyyaa1997/udeck-plugins"* and offers **Install from here…**,
whose warning names both copies first: *"uptime is the verified 1.0.0 from
github.com/iillyyaa1997/udeck-plugins; installing 1.0.0 from
github.com/someone/team-plugins: unverified replaces it. Its windows and settings
stay. Nobody verified the code that comes: it asks before it runs, unless you
allowed exactly that code before."* In the official catalogue, the row of an id
installed from a source says *"Installed here from
github.com/someone/team-plugins: unverified"* with **Switch to verified**, whose
warning names both the other way round. Two default branches are one line only
within one source: a copy of one source's default branch never takes another's
place unsaid, an update is offered from the copy's own source's head alone, and
**Back to** takes the copy it replaced from the source that copy was of.

---

## Updates

### Knowing that a plugin changed

After every refresh, for each plugin in `installed.json` from that source,
uDeck compares the record's `tree` with the tree SHA of `plugins/<id>` at the
new head. Equal means nothing in the plugin changed, whatever else was merged —
and it is known without downloading anything. A copy installed from a branch
or a pull request is compared the same way with the head of its own line
instead ([Following the branch or the pull request a copy came
from](#following-the-branch-or-the-pull-request-a-copy-came-from)).

When they differ, the new head's manifest (already fetched for the catalogue)
says what changed:

| At the head | The Settings row says | Offered |
|---|---|---|
| A newer version | *1.3.0 available* · *What changed* | **Update** |
| The same version, different files | *Changed in the repository, still 1.2.0* · *What changed* | **Update** |
| An older version (the repository went back) | *The repository now has 1.1.0* | **Switch to 1.1.0** |
| A newer version that cannot run here | *1.3.0 needs uDeck 0.8.0* | nothing |
| No folder any more | *No longer in the repository* | **Remove**; the plugin keeps running |
| A newer version asking for different permissions | *1.3.0 available, asks for different permissions* · *What changed* | **Update**, and the card asks before it runs |
| The same version, different files, asking for different permissions | *Changed in the repository, still 1.2.0, asks for different permissions* · *What changed* | **Update**, and the card asks before it runs |

*What changed* opens
`https://github.com/{owner}/{repo}/compare/{installed commit}...{head}` in the
browser. Nothing pops up. A verified plugin whose new version asks for exactly
what the installed one asks for does not wait on its row: it
[updates itself](#automatic-updates) after the read that found it. Everything
else in the table waits for the operator to press it.

The same line appears on the plugin's row in the catalogue, and the Plugins
pane of Settings shows how many updates are waiting.

### Updating

An update is an install of the plugin at the head commit, with every step above
— downloaded, hashed, checked, swapped in, the window kept. The record's
current values move to `previous`, and `pinned` goes back to `false`.

The permission decision is held to the `version` it was made for, so that a new
version asking for more asks again. When a **Verified** copy is replaced by
another **Verified** copy — **Update**, **Switch to**, **Back to**, an earlier
version, or an update by itself — and the new manifest asks for exactly what
the old one asked for, every capability compared byte for byte as a set, the
decision is carried to the new version as it was, a refusal included, and the
card does not ask again. Anything else — a new or a dropped permission, a copy
that was not **Verified**, a decision made for another version — leaves the
decision as it was, and a new `version` asks on the card, as it always has.
Carrying grants nothing: the gate still holds every capability the new
manifest asks for against what the decision holds. If uDeck stops between the
swap and writing the decision, the plugin asks again. The rule is `GrantCarry`
in UDeckCore, tested there.

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

### Automatic updates

A verified plugin updates itself, with nothing pressed, after a read of the
catalogue that finds a newer version — or the same version with other files —
asking for exactly what the installed one asks for. It is the update
**Update** makes, every step of it, run by uDeck one plugin at a time: the
files of that one plugin downloaded at the head, hashed, checked, swapped in,
its window kept, `previous` written, and its permission decision carried to
the new version ([Updating](#updating)), so that the card goes on running
without asking. The record says `automatic: true`, and the row *Updated by
itself on October 10, 2026*, with **Back to 1.0.0** as after any update.

It happens only when all of these hold, and the row offers the update as usual
when any does not:

* **Update verified plugins by themselves**, under Settings → Plugins → Official
  catalogue, is on. It is on as uDeck ships (`autoUpdateVerified` in
  `settings.json`, absent until it is switched off), and does nothing while
  **Official catalogue** is off;
* the installed copy stands **Verified** — not **Modified locally**, not a
  folder of the operator's own, not a linked folder;
* it is not `pinned`: an earlier version the operator chose stays;
* the new version asks for the same permissions, every capability compared
  byte for byte as a set. One more, one fewer or another, and the row says
  *1.3.0 available, asks for different permissions*: the operator presses
  **Update**, and the card asks;
* nothing of the operator's is at its place — nothing that would go to the
  Trash by the [rule every button warns by](#what-goes-to-the-trash), such as a
  `.env`, and no link: an update by itself has nobody to warn. This is asked
  again at the swap, after the download: a `.env`, an edit or a link put there
  meanwhile — or the folder gone — leaves the folder exactly as it is, and the
  update waits on the row;
* it has not failed since the last read. A failure is said on the row —
  *Updating to 1.3.0 by itself did not work* and why — until the next read or
  the next install, update or removal of that plugin, and tried again after
  the next read. A plugin left as it was — by a card action, the switch, the
  operator's work at its place — has not failed.

When the reads happen is [What uDeck fetches, and when](#what-udeck-fetches-and-when):
a few seconds after launch when the last read is over a day old, once a day
while uDeck runs, when Settings → Plugins is opened on a list over an hour old,
and on **Check now** — and each read that succeeds is followed by the updates
it found, once the plugin folders are hashed again. An update by itself never
ends anything the plugin is doing: while one of its card actions runs, the
update waits, and uDeck asks again every minute; it waits the same way while
another install, update or removal runs. A card action that starts while the
update downloads leaves the folder as it was, and so does **Update verified
plugins by themselves** or **Official catalogue** switched off meanwhile.
Which plugins update themselves is `AutoUpdate` in UDeckCore, and when they
are asked `AutoUpdateSchedule` beside it, both tested there.

### Consent for unverified code

The permission decision of code nobody verified — a copy whose record is not
the official source's default branch — is tied to its tree SHA, not to its
`version`: every new content asks again, even when the plugin asks for nothing,
because code on a branch changes without review and there is no sandbox. For a
verified copy, a folder of the operator's own and a linked working copy it
stays tied to `version`, as it is. The record's ref is used only to ask for
more, never to allow: whatever it says, a copy that is not the default
branch's is held to its tree (`ConsentBasis` in UDeckCore).

* `grants.json` keeps the tree the decision was made for beside the version,
  as `decidedForTree`; a decision written before has none, and holds for no
  tree. **Allow** records both, for the tree the folder last hashed to — the
  one the card was drawn for — and only while nothing in the plugins folder
  has changed since: a press between a change and its hashing records
  nothing, and the card is drawn again for what is there.
* The tree is the one uDeck hashed the folder to (`HashedTrees` in UDeckCore).
  A folder never hashed — at launch, after a plugin's first install — waits,
  and its card asks nothing: nothing is asked about content nobody has hashed.
  After anything changes in the plugins folder — an edit, an update, a copy
  put back — a run of a plugin held to its tree is skipped, not run and not a
  failure, until the folder is hashed again; its poll loop and its card stay
  as they were meanwhile, so a hashing that finds the same tree changes
  nothing, and new content stops the loop and asks. A change counts from when
  the folder watcher reports it, once writes in the folder pause — in the lab,
  0.7 to 0.9 s after one line was appended, as `installed.json` said it
  (`plugins.modified-locally`, 2026-10-11) — and a run that starts before then
  runs on the decision before it. A copy
  uDeck puts in place counts as changed from that moment, and runs only on a
  decision for its own tree.
* A folder that would not hash — a file in it cannot be read — is never
  decided for: its card says *"uDeck could not read every file in asks-nothing's
  folder, so it does not run it"*.
* While `installed.json` cannot be read, nothing says where any copy came
  from: every folder but a link is held to its tree, and asks — a broken file
  only ever asks for more.
* The card says where the code comes from, above what it asks: *"Nobody
  verified this code: it comes from pull request #3 of
  github.com/iillyyaa1997/udeck-plugins, not from what the repository merged.
  uDeck asks again whenever it changes."* — *branch fix/uptime* for a branch,
  *changed on this Mac since* once it was edited — and the window's header
  says **Unverified** whatever the card shows ([Verified, trusted,
  unverified](#verified-trusted-unverified)). While `installed.json` cannot be
  read it says that nothing says where the code came from.
* A plugin that asks for nothing is asked too: *"asks-nothing asks for
  nothing, but its code is unverified"*, with **Allow and run** and **Decline**
  on its card, and **Allow** and **Decline** under its row's **More** in
  Settings. **Decline** switches it off, since a decision with nothing in it
  would let it run; switched on again, it asks again.
* A local edit to an unverified copy asks again, as any new content does.

The gate is `PermissionGate.launchDecision` and `mayRun` in the plugin format,
given the tree required (`requiredTree`); without one — `udeck-plugin run`, a
verified plugin — it is the rule it always was.

Installing such a copy is [Installing from a branch or a pull
request](#installing-from-a-branch-or-a-pull-request).

**Update** to the head its branch or pull request moved to is new content like
any other, and asks ([Following the branch or the pull request a copy came
from](#following-the-branch-or-the-pull-request-a-copy-came-from)).

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
| **Verified** — `checkmark.seal.fill` | Installed from the default branch of the official repository — or from its pull request or branch, once exactly that folder was merged — and the folder on disk is still exactly what was merged there. A maintainer of the official repository read it before merging. | 1; 3 |
| **A folder of your own** — `folder` | Put into `~/.udeck/plugins` by anyone but uDeck. uDeck claims nothing about it. | 1 |
| **Modified locally** — `pencil` | Installed from a repository, but the folder has changed since. Whatever mark it had is gone. | 1 |
| **Trusted source: \<name\>** — `checkmark.shield` | Installed from the default branch of a repository the operator explicitly trusted (**Trust** on the source, as `brew trust` works for Homebrew). The guarantee is that source's owner's, not uDeck's — a different mark, so nobody mistakes one for the other. | 4 |
| **Unverified** — `exclamationmark.triangle` | From a branch, a pull request, a fork, a specific commit, or the default branch of a source nobody trusted. Nobody vouches for it. Shown on the card's header as well as in Settings. | 3 (a branch or a pull request of the official repository, a branch of a fork of it); 4 (the default branch of a source nobody trusted — on its rows, its copies' rows and their cards, its block saying *Not trusted…*) |

In the official repository **only what is merged is verified**; its branches and
pull requests are unverified like anybody else's.

**"Verified" does not mean safe.** It means a person read the code and merged
it. It is the strongest thing uDeck can honestly say about a plugin, and
nothing more than that.

**Where Unverified is said**, for a copy installed from a branch or a pull
request: on its row in Settings — **Unverified** · *pull request #3 at
a1b2c3d*, *branch fix/uptime at a1b2c3d*, or — a fork's — *branch x of
someone/udeck-plugins at a1b2c3d*, with a link to that page; a copy
changed on disk since is marked **Modified locally** there instead, beside the
same *pull request #3 at a1b2c3d* — that mark takes the place of every other —
and a copy whose folder has gone **Missing**; on every row **Install from a
link…** lists; on the catalogue row of the same id, *"Installed here from pull
request #3: unverified"*, its folder there or not, beside **Switch to
verified**; on the header of each of its windows, changed on disk or not —
a window of a copy whose folder has gone says that it is not in
~/.udeck/plugins and, beside **Reinstall**, what that puts back: *"Reinstall
puts back 1.0.1 from pull request #3 at a1b2c3d: code nobody verified."*; and
on its card's question, which says where the code comes from.
`CatalogueRowState`, `PluginStanding.cardSaysUnverified`,
`InstalledRecord.reinstallSays` and `ConsentSource` in UDeckCore decide the
last three.

So that the seal means one thing only: the **"Asks for nothing"** line in
Settings, which today wears a `checkmark.seal`, loses it and becomes plain text.
A plugin asking for nothing is not a plugin somebody checked.

Verified is computed from content, not from a ref: a plugin installed from a
pull request becomes **Verified** the moment the tree of its folder is at the
head of the default branch — squash merges and rebases included, with no new
download — and from then on follows the default branch. Until then it follows
its branch or pull request, which is only ever offered, never installed by
itself — history rewritten said. Merged with changes:
*"The verified version differs — update"*. Closed unmerged: a warning, and the
plugin keeps running ([When the pull request is merged or
closed](#when-the-pull-request-is-merged-or-closed)).

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
* **When the operator presses Install, Update, Reinstall, Back to, Switch to
  verified or Earlier versions**, the files that needs — from the repository the
  copy comes from, a fork's from the fork — and, for **Earlier versions**, the
  default branch's history of that plugin's folder.
* **When the operator presses Look up in Install from a link…**, the pull
  request or the branch the link names, its listing unless it is cached, and
  the manifests of the plugins there that are not the catalogue's — through
  the official repository, two requests to the API; of a fork's branch, of the
  fork, three, the first asking whether it is a fork of the official
  repository at all ([Installing from a branch or a pull
  request](#installing-from-a-branch-or-a-pull-request)) — and, when
  **Install** is pressed there, that plugin's files, from the repository the
  line is in.
* **After a read of the catalogue**, for each copy installed from a branch or
  a pull request whose tree the new head does not have, that pull request, or
  that branch's head asked with the commit installed — of the fork, for a
  fork's branch, and so its listing and its comparison — one request to the API
  each ([When the pull request is merged or
  closed](#when-the-pull-request-is-merged-or-closed)); once a head moved, its
  listing, once, and the copy's manifest there from the raw host, and when the
  copy is another tree there, one comparison of that head with the commit
  installed, once ([Following the branch or the pull request a copy came
  from](#following-the-branch-or-the-pull-request-a-copy-came-from)); once a
  pull request is merged, the listing of the commit it was merged as, once. In
  a read nobody asked for, none of it while the reserve for the operator is all
  that is left.
* **After a read that finds an update a verified plugin makes by itself**
  ([Automatic updates](#automatic-updates)), that plugin's files at the head —
  no more than **Update** would fetch, and only while **Update verified plugins
  by themselves** is on. Switched off while one downloads, that download finishes
  and nothing of it is put in place.

* **For each source of one's own**, on the same schedule — at launch unless
  read in the last day, once a day, when Settings → Plugins is opened and its
  list is more than an hour old, and when **Check now** on its block is pressed
  — what the catalogue reads, by the repository's number; when **Look up** is
  pressed in **Add a source…**, the repository's description by its name, its
  head by its number and its passport; and, when a button is pressed for a copy
  of it, the files that needs, from it ([Sources of one's
  own](#sources-of-ones-own)).

Nothing else. A refresh reads only what [the catalogue](#reading-a-repository-without-downloading-it)
reads, usually one or two requests, and one more for each copy of a branch or
a pull request not merged as it is — one or two more, once, when its head
moved; the only plugin downloaded without a press
is a verified one updating itself, and only when its new version asks for
exactly what it asks for now. A failed refresh is tried again after an hour,
then daily as usual.

For the official catalogue it talks to two hosts, `api.github.com` and
`raw.githubusercontent.com`; a GitLab project added as a source of its own is
read from its own host's API, `https://<host>/api/v4`. What reaches GitHub — or
that GitLab — is what any HTTPS request carries: the network address, the
`User-Agent: uDeck/<version>` header, the repository and the files asked for —
and so, when something is installed, which plugin. No account, no identifier,
no cookie, no list of what is installed.

**Settings → Plugins → Official catalogue** turns it off. Off, uDeck makes no
request to the official repository — its catalogue, **Install from a link…**,
its forks, the lines its copies came from; the sources added are read until
they are removed, and installed plugins keep running. Without a source added,
that is no request about plugins at all.

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
  `c1/` (`uptime` 1.0.0 and the refusal fixtures), `c2/` (`uptime` 1.1.0,
  asking for the same), `c3/` (`uptime` 1.2.0, asking for one command more),
  the main line's order (`history`), and the commits off it with the commit
  each was made on (`parents`): `pr3/`, a pull request's head made on `c1`,
  with `uptime` 1.0.1 asking for the same and `asks-nothing`, a new plugin
  asking for no permission; `s1`, that pull request squash-merged onto `c1` as
  exactly its head — a third name in `parents` gives a commit another's
  content, so `s1` has `pr3`'s tree and no folder of its own; `s2/`, the same
  merge with a maintainer's change, `uptime` 1.0.2; and `m1`, `s2`'s content
  made on `s1`, the default branch moved on past the merge; `p2/`, the pull
  request's next commit, made on `pr3` — `uptime`'s script with one paragraph
  more, the same version and the same manifest — and `p2x`, `p2`'s content made
  on `c1`: the pull request pushed again with its history rewritten. The fake
  computes real git blob, tree and commit ids from them itself, parents
  included; there is no git in the guest.
  Because its hashing is Python and uDeck's is Swift, two independent
  implementations have to agree before any check passes.
* **It answers the subset of the API uDeck uses:** `GET /repos/{o}/{r}`;
  `GET /repos/{o}/{r}/commits/{ref}` with `Accept: application/vnd.github.sha`,
  an `ETag`, and `304`, `{ref}` being `main`, another branch (bare or
  `refs/heads/{b}`), `refs/pull/{n}/head` or any commit's id; `GET
  /repos/{o}/{r}/pulls/{n}` with its head, state, merge commit, the
  repository it came from and its base — `main`, or the branch the lab names —
  an `ETag` and `304`; `GET /repos/{o}/{r}/compare/{base}...{head}` —
  `ahead`, `behind`, `identical` or `diverged`, and by how many commits,
  through the commits' parents; a commit that is not there is `404`; `GET
  /repos/{o}/{r}/git/trees/{sha}` with and without `recursive=1`, for a commit
  on the main line or off it; `GET /repos/{o}/{r}/commits?sha=&path=`, parent
  by parent; and raw files at `/{o}/{r}/{commit}/{path}` under a second prefix
  standing in for the raw host. API answers carry `x-ratelimit-remaining` and
  `x-ratelimit-reset`, and the remaining count goes down — a `304` too. A fork
  the lab names answers on the same host, from the same commits — a fork shares
  its network's objects — with branches of its own: its description (`fork`,
  `parent`, `source`, or `fork` false for a repository of its own), its
  branches' heads, any listing, comparison and raw file; every request to it
  spends the same hourly count. **Repositories of their own** — stage 4's
  sources, fixture folders under `sources/github/<owner>/<repo>/`, each with
  its own history and an `id` file, the number GitHub gives it — answer by
  their name (`GET /repos/{o}/{r}/…`) and by their number (`GET
  /repositories/{id}/…`): their description with `id` and `full_name`, their
  head with its `ETag` and `304`, a folder's history, a listing, a comparison,
  and raw files by the name they are called now. The official repository's
  description says its number too, the fixture's own (`id`, 900000001) unless
  the lab names another. A repository the lab names none of is `404`.
* **It answers as two GitLabs too** (stage 4), each on a port of its own of the
  same process, so that each is an origin of its own as it is outside the lab:
  `gitlab.example.test`, a self-hosted GitLab that sends no limit, on 8768, and
  `gitlab.com` on 8769, in GitLab's API, v4 ([GitLab](#gitlab)) — a project by
  its encoded path or its number, its description without
  `forked_from_project`, its branch's head with a weak `ETag` and `304`, a
  tree's entries three to a page whatever is asked, with `x-next-page`, a file
  through the files API with `X-Gitlab-Size` and `X-Gitlab-Blob-Id`, a folder's
  history, and GitLab's own `404` bodies. The projects are fixture folders
  under `sources/gitlab/<host>/<group>/…/<project>/`, each with its history and
  its `id`; a file `<name>.generated` is a file made when the fake starts, never
  committed — `gl-big`'s 6 MB `big.bin`. gitlab.com counts each request by its
  two limiters, 500 a minute and 60 an hour, each answer naming one in turn, and
  `429`s with `Retry-After` once the hour is spent.
* **The lab drives it** by rewriting a small state file over SSH: which commit
  `main` is at; which commit each other branch is at, a branch left out being
  deleted; each pull request's head, state, merge commit and the repository it
  came from — a deleted fork's is none; the forks on the host, each with its
  branches, and which of them is a repository of its own instead, or a fork of
  something else; "the limit is used up until T" (`403`
  with `remaining: 0`); "this many of the hour's requests were spent by
  something else on the connection" (`spent`: what is left says so, and runs
  out that much sooner); "answer this file with different bytes"; "say the
  listing is truncated"; which commit each repository of its own's `main` is
  at; which name serves which of them — a repository renamed, and another made
  at its old name; "the official repository's description answers this
  number"; and of each GitLab, its projects' `main`, which path serves which
  project, how much of gitlab.com's hour was spent elsewhere, and "answer as a
  web server with no GitLab behind it" (`plain`). Moving a head, force-pushing — a head at a commit that does not
  continue the one before — merging and closing are each one rewrite.
* **It keeps an access log** of every request — method, path — decoded, and as
  it was sent, its `%2F` kept — query, status, the port it came in on and the
  GitLab it is, and whether it carried a credential (`none`,
  `accepted`, `rejected`, never its value; any credential is answered `401`
  today) — which is the oracle for what uDeck asked for and, just as much, for
  what it did not.

**A lab build is pointed at it through `Info.plist`**, the way it is pointed at
its own update feed, because the lab tests the release build and a relaunch
does not keep environment variables:

| Key | Shipping value | Lab value |
|---|---|---|
| `UDeckPluginsAPIBase` | `https://api.github.com` | `http://127.0.0.1:<port>/api` |
| `UDeckPluginsRawBase` | `https://raw.githubusercontent.com` | `http://127.0.0.1:<port>/raw` |
| `UDeckPluginsRepository` | `iillyyaa1997/udeck-plugins` | the same |
| `UDeckPluginsRepositoryID` | `1393324153` | `900000001`, the fake's |
| `UDeckPluginsHostMap` | none | `{"gitlab.example.test": "http://127.0.0.1:8768", "gitlab.com": "http://127.0.0.1:8769"}` |

`Scripts/make-app.sh` gains `--test-plugins <base URL>`, which sets the first two
and the number, writes the host map — each GitLab the fake answers as, on its
own port of the base URL's host — and adds `NSAllowsLocalNetworking`, as
`--test-feed` does; the lab's build step verifies the keys in the zip as it
already verifies `SUFeedURL`, holds the build as shipped and the smoke's to
GitHub's own number, and refuses a host map in either and a lab build without
its own. A build that carries a map says so under **Your sources**; what it
changes is only where a host's requests go — the pages a person opens keep the
real host.

### The lab's checks

Each check reads the card through the panel's accessibility tree (window 1 of
the uDeck process, subrole `AXSystemDialog`), Settings through its own, and the
guest's `~/.udeck` over SSH.

| Check | Proves |
|---|---|
| `plugins.catalogue-on-first-launch` | On a fresh guest, with nothing pressed, the fake's log shows the catalogue being read within a minute — and no file requested but the passport and manifests. Settings lists the fixture plugins. |
| `plugins.install-fetches-one-folder` | **Install** on `uptime` requests only files under `plugins/uptime/` at the listed commit, and no API request at all. The folder in the guest hashes to the fixture's tree; the record in `installed.json` has every field above; the row says **Verified**. |
| `plugins.card-reaches-the-panel` | Placed on an empty tab and allowed, `uptime`'s card appears, and says it has run once. |
| `plugins.update-keeps-the-window` | With **Update verified plugins by themselves** off and `main` moved to `c2`, **Check now** shows *1.1.0 available*; after **Update**, `layout.json` has the same window (same id, same place), the card shows 1.1.0's output without asking again — 1.1.0 asks for what 1.0.0 asked, and `grants.json` holds the decision for 1.1.0 — and `previous` holds 1.0.0. |
| `plugins.verified-updates-itself` | `uptime` 1.0.0 installed, placed and allowed; uDeck ended, `main` moved to `c2` and the catalogue's `state.json` made two days old; started again with nothing pressed, uDeck reads `c2` and fetches every file of `plugins/uptime` there by itself: the folder hashes to `c2`'s tree, the record says 1.1.0, `previous` 1.0.0 and `automatic: true`, the window is the same, the card runs 1.1.0 without asking (`grants.json` holds the decision for 1.1.0), and the row says *Updated by itself on …* — in Russian too, kept as a screenshot — and offers **Back to 1.0.0**. The control: 1.0.0 chosen under **Earlier versions…** is pinned, and **Check now** leaves it there, 1.1.0 offered, none of its files fetched, and uDeck's log saying it is pinned. |
| `plugins.permissions-change-only-offers` | **Update verified plugins by themselves** clicked off (`settings.json` says so), `main` moved to `c2`: **Check now** offers *1.1.0 available* and fetches no file of `uptime` but its manifest. The card's **Hold** pressed and left running, the switch clicked on again: the next **Check now** reads the catalogue and leaves `uptime` at 1.0.0 — no file of it fetched, the action still running and never seeing its folder change, uDeck's log saying it waits for the action; the action ended, the minute's tick puts 1.1.0 in place by itself, with no read in between. `main` moved to `c3`, whose 1.2.0 asks for one command more: after **Check now** reads `c3`, the row says *1.2.0 available, asks for different permissions*, nothing of 1.2.0 but its manifest is fetched, 1.1.0 stays and uDeck's log says why; **Update** puts 1.2.0 in place, and its card asks for consent before it runs. |
| `plugins.earlier-version` | **Earlier versions…** lists 1.1.0 and 1.0.0; with a `.env` put into the folder over SSH, choosing 1.0.0 first says *"Your changes to uptime will be moved to the Trash…"*; confirmed, it installs 1.0.0, `pinned` is `true`, the row still says *1.1.0 available*, and the `.env` is in the guest's Trash. |
| `plugins.remove-leaves-nothing` | Before **Remove**, `cache/uptime`, the grant and a setting value are there to be taken; after it: no folder, no `cache/uptime`, no entry in `grants.json`, `plugin-settings.json` or `installed.json`, no window. Installed again, it asks for consent again and its card says it has run once. |
| `plugins.refuses-what-it-cannot-run` | Fixtures with `api: 2` and `minUDeck: "99.0.0"` are listed with their reasons and no **Install**, and nothing of theirs but the manifest was ever requested. |
| `plugins.refuses-changed-files` | With the fake altering one file, the install is refused with the "arrived different" message; there is no `plugins/uptime` and nothing left in `staging/`. |
| `plugins.refuses-a-link` | A fixture whose listing has a symbolic link is listed as not installable, naming the path. |
| `plugins.limit-is-explained` | With the limit used up for seven minutes — five walks of the slowest measured, 76 s — **Check now** shows the message and the reset time; after a second **Check now** and an install of a plugin already listed — which works — the log shows no API request until the reset; after it, **Check now** reaches the API again. |
| `plugins.catalogue-off-means-no-network` | Switched off, **Install from a link…** says why it does nothing; relaunched, uDeck makes no request to the fake for two minutes. |
| `plugins.modified-locally` | A line appended to an installed file over SSH makes `installed.json` say `modified` within seconds — 0.7 to 0.9 s, measured — and then the row **Modified locally**, with **Verified** gone. The disk is read first: one walk of Settings → Plugins takes 40 to 76 s, and a walk that crosses the change returns the row's mark as it was, several times, or not at all — R2's two failures of six — while the walk after it reads the truth (e2e/README.md). |
| `plugins.install-from-a-pull-request` | Pull request #3, opened from the fork `someone/udeck-plugins`, pasted as `github.com/iillyyaa1997/udeck-plugins/pull/3` into **Install from a link…**: the sheet says *Pull request #3 at …* and lists `asks-nothing` and `uptime` — what differs from the catalogue's head — and the log holds the pull request, its listing and those two manifests at its head, through the official repository; **Install** on `uptime` fetches every file of `plugins/uptime/` once, from the base's raw host at the head's commit, and asks the API nothing; nothing is asked of the fork. The folder hashes to `pr3`'s tree, `installed.json` says `ref {pr, "3"}`, `unverified`, by `null`; the row says **Unverified** · *pull request #3 at …* with a link to its page; placed on a tab, the card's header says **Unverified**, and its question says where the code comes from. Screenshots of the sheet, the row and the card. |
| `plugins.install-from-a-branch` | The link into `plugins/uptime` on `fix/uptime`, a branch whose name holds a `/`: the sheet lists `uptime` alone, and from **Look up** to the end of the install the log holds the branch's head by `refs/heads/fix/uptime`, its listing and files of `plugins/uptime/` at its commit — nothing else; the record says `ref {branch, "fix/uptime"}`, `unverified`, by `null`, and the row **Unverified** · *branch fix/uptime at …*. Placed on a tab and its folder taken away over SSH, its window says beside **Reinstall** *Reinstall puts back 1.0.1 from branch fix/uptime at …: code nobody verified.*; Settings does not say *Nothing installed yet* above its **Missing** row; the catalogue row says *Installed here from branch fix/uptime: unverified — uptime is not in ~/.udeck/plugins* and offers **Switch to verified** — the plugin's row too — and no **Reinstall**; pressed, the verified copy goes in without a warning, with the branch's as `previous`. |
| `plugins.install-from-a-fork-branch` | The control first: a link into `plugins/uptime` on `x` of `someone/elsewhere`, a repository of its own, is refused — *"github.com/someone/elsewhere is not a fork of github.com/iillyyaa1997/udeck-plugins. To install from it, add it as a source of its own."* — and the log holds its description, `GET /repos/someone/elsewhere`, and nothing after it: no head, no listing, no file. Then the link into `plugins/uptime` on `x` of the fork `someone/udeck-plugins`, at `pr3` — the official repository has no `x`: from **Look up** to the end of the install the log holds the fork's description, the head of its `x` by `refs/heads/x`, its listing and files of `plugins/uptime/` at that commit from the fork's raw host — every file once on **Install** — and nothing of the official repository; the sheet says *Branch x of someone/udeck-plugins at …*; the folder hashes to `pr3`'s tree; the record says `repository` the fork, `ref {branch, "x"}`, `unverified`, by `null`; the row **Unverified** · *branch x of someone/udeck-plugins at …*. The fork moves `x` on to `p2`: **Check now** asks the fork for `x` with `If-None-Match` and `pr3`, lists `p2` there and compares `pr3...p2` there once, asks the official repository nothing about it, and the row says *Changed in branch x of someone/udeck-plugins, still 1.0.1* with **Update** and *What changed*; **Update** takes every file of `plugins/uptime/` at `p2` once, from the fork, and the row says *… at* `p2`. Screenshots of the refusal, the sheet, the row and the offer. |
| `plugins.unverified-asks-even-for-nothing` | `asks-nothing`, installed from the pull request and placed on a tab: its card asks — *Asks nothing asks for nothing, but its code is unverified*, and where the code comes from — and its count of runs is not in its cache: it has not run. **Allow** runs it, and `grants.json` holds the decision for 1.0.0 and for its tree; a line appended to `run.sh` over SSH asks again, and **Decline** on the card switches it off (`plugin-settings.json`), its count of runs what it was before the edit: the changed code never ran. Switched on in Settings, its row asks the same under **More**, and **Decline** there switches it off again, the count unchanged; switched on once more, **Allow** there holds the decision for the edited tree and runs it. |
| `plugins.a-merged-pull-request-becomes-verified` | `uptime` installed from pull request #3, placed and allowed — `followed.json` holding what **Look up** heard, open at `pr3`, and the log one question about the pull request, **Look up**'s; the fake squash-merges it as `s1` — `main` there, the pull request closed and merged as `s1`, every plugin folder with `pr3`'s tree. After **Check now**: `installed.json` says `main` at `s1`, **Verified** by `official`, the tree and version it had; the row says **Verified**; every file of the folder has the inode and the time it had; the log holds no file of `uptime` and no question about the pull request; `followed.json` no longer holds it; the window and the decision are as they were, and the card runs 1.0.1 without asking, with no **Unverified** in its header. |
| `plugins.merged-with-changes-offers-the-verified` | `uptime` installed from pull request #3; the fake squash-merges it as `s2`, `uptime` 1.0.2. After **Check now** the log holds one question about the pull request and no file of `uptime`, and the record is as it was; the row says *Pull request #3 was merged, and the verified version differs — update* with **Update**, the catalogue row *… unverified — merged, and the verified version differs* with its button saying **Update** as well — as wide as the plugin row's, since the walk reads no button's words, and kept as a screenshot — and Settings *1 update is waiting*. **Update** first names both copies and changes nothing until it is confirmed; then the record is `main`'s at `s2`, **Verified**, 1.0.2, with the pull request's copy as `previous`. |
| `plugins.merged-then-moved-on-becomes-verified` | `uptime` installed from pull request #3, uDeck started with **Update verified plugins by themselves** off; the fake merges it as `s1` and moves `main` on to `m1`, `uptime` 1.0.2. After **Check now** the log holds the question about the pull request and the listing of `s1`, and no file of `uptime`; the record says `main` at `s1`, **Verified**, 1.0.1, checked against `m1`; the folder is the one it was; the row says **Verified** and *1.0.2 available*; `followed.json` no longer holds it. **Update verified plugins by themselves** clicked on, the next **Check now** updates it by itself to `m1`'s 1.0.2, the copy at `s1` its `previous`. |
| `plugins.merged-into-another-branch-stays-unverified` | `uptime` installed from pull request #3; the fake merges the pull request into `next`, not `main`, as `s1` — exactly its head — and `main` stays at `c1`. After **Check now** `followed.json` keeps that it was merged into `next`, with no commit and no tree; the log holds the question about the pull request, no listing of `s1` and no file of `uptime`, and twenty seconds on the record is the pull request's, **Unverified**, as installed; the row says **Unverified** and nothing of the pull request, **Switch to verified** is there, and the catalogue row says only *Installed here from pull request #3: unverified*. |
| `plugins.unverified-only-offers` | `uptime` installed from pull request #3, placed and allowed; the fake moves the pull request's head from `pr3` to `p2`. After **Check now** the log holds the question about the pull request, the listing of `p2` and one comparison of `pr3` with `p2`, and no request to the raw host at all; the record and the folder are as they were; the row says *Changed in pull request #3, still 1.0.1* with **Update** and *What changed*, and nothing of a rewritten history; Settings *1 update is waiting*; `followed.json` keeps the head at `p2`, continuing `pr3`. Ended, and started again with the catalogue two days old and all but nine of the hour's requests spent elsewhere (the fake's `spent`): the read at launch does not ask about the pull request, uDeck's log says it was left as it was, `followed.json` says since when, and the row says *Pull request #3 not checked since …* and still offers **Update**; **Check now** asks about it again, compares nothing again, and that line goes. Ended and started again, the catalogue two days old, nothing spent elsewhere: the read at launch asks about the pull request by itself, fetches no file, and the row offers **Update** and *What changed*. **Update**, pressed: the record is the pull request's at `p2`, unverified, `previous` the copy at `pr3`; the files of `plugins/uptime/` at `p2` fetched once each and nothing else; the folder hashes to `p2`'s tree; the card asks before it runs. Last, **Check now** with all but nine of the hour's requests spent elsewhere leaves fewer than the reserve; ended, and started again with the catalogue two days old, the read at launch asks nothing at all, uDeck's log says the catalogue was left for later and the pull request left as it was, and `followed.json` says since when; Settings → Plugins opened with the hour's requests all spent, its own read refused, the row says *Pull request #3 not checked since …*. |
| `plugins.force-push-is-said` | `uptime` installed from pull request #3, placed and allowed, uDeck started with **Update verified plugins by themselves** off. The control: `main` moved on alone to `c2`, **Check now** asks about the pull request — its head still the commit installed — and compares nothing, and the row says nothing of it. The fake moves the pull request's head to `p2x`, made on `c1`, which does not continue `pr3`. After **Check now** the log holds exactly one comparison, of `pr3` with `p2x`, and no file of `uptime`; the row says *The history of pull request #3 was rewritten: its new head does not continue what is installed* and *Changed in pull request #3, still 1.0.1* with **Update**; the record and the folder are as they were; `followed.json` keeps the head at `p2x`, rewritten. **Update**, pressed: the record is the pull request's at `p2x`, unverified, and the card asks before it runs. |
| `plugins.a-branch-is-followed` | `uptime` installed from the branch `fix/uptime`, at `pr3`, placed and allowed. **Check now**: the log holds the branch's head by `refs/heads/fix/uptime` once, asked with `If-None-Match` and `pr3`, answered `304`, and no listing or comparison. The fake moves the branch on to `p2`: after **Check now** the head is answered `200`, `p2` is listed and compared with `pr3` once, the row says *Changed in branch fix/uptime, still 1.0.1* with **Update** and *What changed*, and Settings *1 update is waiting*. The fake deletes the branch: after **Check now** the head is answered `422`, the row says *Branch fix/uptime no longer exists; the plugin keeps running* and offers **Switch to verified** and **Remove** and no **Update**; the record and the folder are as they were throughout, and the card runs again, its count of runs going up. The fake makes the branch again at `p2`, and `uptime` is installed from it through **Look up**: the record is the branch's at `p2`, `followed.json` keeps the head **Look up** heard, and — no request about the branch since — the row says nothing of a branch gone and offers nothing. |
| `plugins.a-closed-pull-request-keeps-running` | `uptime` installed from pull request #3, placed and allowed; the fake closes the pull request unmerged. After **Check now** the row says *Pull request #3 was closed without being merged; the plugin keeps running*, the catalogue row *… unverified — closed without being merged*, and **Switch to verified** and **Remove** are there; the record, the folder, the window and the decision are as they were, and the card's count of runs goes on growing. Opened again, after **Check now** uDeck asks about it again, `followed.json` says it is open, and the row says **Unverified** and nothing of it. |
| `plugins.switch-to-verified-names-both` | The verified `uptime` 1.0.0 installed, placed with a setting value and allowed; **Install** on the pull request's `uptime` first says *uptime is the verified 1.0.0 from github.com/…; installing 1.0.1 from pull request #3 at … replaces it. Its windows and settings stay. Nobody verified the code that comes: it asks before it runs…*, and while that is up the folder and the record are as they were; confirmed, the record is the pull request's, with the verified copy as `previous`. **Switch to verified 1.0.0** on the row warns the other way round and again changes nothing until it is confirmed; then the row says **Verified**, the record is `main`'s at `c1`, the window and the setting value are where they were, and the card runs 1.0.0 without asking. |
| `plugins.window-survives-a-broken-manifest` | A placed plugin's manifest broken over SSH keeps its window in `layout.json`, which says what is wrong; fixed, the card comes back without being added again. |
| `plugins.every-replacement-warns-first` | Over a folder with a `.env` put in over SSH — for **Reinstall**, also a line appended to `uptime.sh` — **Reinstall**, **Update** on the catalogue row, **Back to 1.0.0** and **Remove** each say first that the copy goes to the Trash; confirmed, each does what it says, and every `.env` is in the guest's Trash and no longer in the folder. |
| `plugins.an-update-ends-a-running-action` | With the fixture card's **Hold** action running, **Update** ends it before it replaces the folder: the action wrote that it was ended and never that its folder changed under it, nothing of it runs afterwards, and 1.1.0 is in place. |
| `plugins.linked-folder` | A plugin in a working copy outside `~/.udeck` — beside a `.git`, a `.env`, files named like `installed.json` and `cache/`, and a link — linked into `~/.udeck/plugins` is listed: placed and allowed, its card comes; its manifest changed in the working copy to run another producer, the card says that producer's word; polled every 5 s, with a file in the working copy touched every 3 s for 21 s and the panel open, it runs at least three times; in Settings its row is marked **Linked** and says where the link leads, and **Remove** says first that only the link goes and names the folder, with no word of the Trash; after it the link is gone, uDeck's cache of it too, and the working copy is byte for byte as it was, its `.env` not in the Trash. |
| `plugins.link-a-folder` | **Link a folder…** in Settings → Plugins, the folder chosen in the system's folder panel by typing its path (⌘⇧G): a working copy whose id nothing has is linked at once — the outcome says *Linked <id> to …*, `plugins/<id>` leads to the folder, the row says **Linked**; one with `uptime`'s id, over the `uptime` just installed from the catalogue, first says *"uptime is installed from github.com/iillyyaa1997/udeck-plugins. Linking … deletes the installed copy"* and changes nothing; the working copy's id changed to `link-me` while that warning is up, **Link** warns of `link-me` — *"link-me is a link to …"* — and changes nothing, and with the id back to `uptime` it warns of `uptime` again; confirmed, `plugins/uptime` leads to the working copy, `installed.json` has no `uptime`, and the working copy is byte for byte as it was. |
| `plugins.run-log-switch` | A linked plugin that says a line on stderr every run: with the switch as shipped, no `logs/<id>.log`; **Keep a run log for linked folders** switched on in Settings — `settings.json` says `linkedFolderRunLog: true` — and the panel open, the log has at least two entries, each *exit status 0; a card*, with the stderr line under it, and **Show the logs** is offered. |
| `plugins.failed-run-on-a-fresh-card` | A linked plugin whose card lasts 300 s fails (exit 3, a line on stderr) while a file is in its folder: with the panel open, the fresh card keeps its values and gets the amber dot by its name and the lines *Last run failed at …: the producer exited with status 3* and *showing values from …*; Settings → Plugins, under **More**, says *Last run … a failure: …* and the end of its stderr; the file taken away and the panel opened again, the dot and the line are gone. The panel's own buttons are refresh, Settings, send away and fill the screen — no density button. |
| `plugins.install-command` | The bundle carries `Contents/Helpers/udeck-plugin` and `codesign --verify --deep --strict` holds in the guest; the row says it is not installed; **Install command** makes `~/.local/bin/udeck-plugin` a link to it, and `--help` and `--version` run through the link; the row says it is installed and what the guest's zsh makes of `~/.local/bin` (the line to add, when it does not look there); **Remove command** takes the link and leaves the command in the bundle; a file of somebody else's at that place is said, left as it is, and not offered **Install command**. |
| `plugins.search-path-field` | A linked plugin running the bare `lab-greet`, on no folder of the default list: its window says it was not found. **＋ Add a folder…** (the folder chosen in the panel) puts a folder of the lab's at the top of **Where to look for commands** and in `settings.json`, and the card, allowed, says that folder's word; a second folder added says its word; **↓** on it, the first folder's word again — each from the next run, without a restart; **Restore the defaults** puts the default list back in `settings.json`. |
| `plugins.screens-in-russian` | With uDeck in Russian (`language` in `settings.json`), a failed run on a fresh card, the **Linked** row and its Remove warning, **Link a folder…** over the installed `uptime` and its warning, the last run under **More**, the run log switch, **Where to look for commands** and **Install command** are each there and say uDeck's Russian words — why the run failed too, *программа плагина завершилась с кодом 3*, with the last run's seconds written with a comma; **Link a folder…** over a link writes both folders from `~`; **Update** over a link put where the installed `uptime` was says first *uptime здесь — ссылка на ~/…* and leaves the link until that is confirmed. Then, in a uDeck started afresh in Russian with updates by themselves on, the screens of stage 3 a person meets along the way say Russian.swift's words: *Обновился сам …* after `main` moved to `c2`; the link sheet — the refusal of `someone/elsewhere`, and the head, **Не проверен** and note of the fork's branch, of `fix/uptime` and of pull request #3; the warnings of **Install** over the verified copy, **Switch to verified** and **Back to** the pull request's copy, each naming both; the **Не проверен** row, *запрос на слияние #3, коммит …*, and the catalogue row; the cards of `uptime` and `asks-nothing` asking — the header, where the code comes from, *… ничего не просит, но его код не проверен*; history rewritten; *Запрос на слияние #3 не проверялся с …*; closed without being merged; merged with changes; merged with nothing offered. A screenshot of each is kept for a person to read. Not read in Russian yet, among others: a new version along the copy's line, a deleted branch or plugin, an update that asks for different permissions or failed, the link sheet's other answers — merged, merged elsewhere, closed, nothing differs, not there, not found, a commit gone — **Switch to verified**'s own label, a window's **Reinstall** warning and a fork's branch on its row. |
| `plugins.source-add-github` | **Add a source…** of `github.com/someone/team-plugins`, a repository of its own in the fake with a number of its own: from **Look up** on, the log holds `GET /repos/someone/team-plugins` once — the one request ever addressed by its name — then `/repositories/<id>/commits/main` and the passport at that commit from the raw host, and nothing else; the sheet shows the passport's name, and the line a test build carries says where `api.github.com` and `raw.githubusercontent.com` are read from. After **Add**, the block is named *Team plugins* from its passport, says *Not trusted: nobody vouches for these plugins — each asks again whenever its code changes.*, and its rows say **Unverified**; its catalogue was read by its number alone; `sources.json` holds the id derived from the number, the number, `access: none` and `trustedAt: null`. No request carries a credential. |
| `plugins.source-install-unverified` | **Install** of `team-clock` from the source's block fetches every file of `plugins/team-clock/` at `t1` once, from `/raw/someone/team-plugins/…`, and nothing else; the folder hashes to the fixture's tree; `installed.json` says `source` the source's id, `repository` someone/team-plugins, `ref {default, "main"}`, `unverified` by `null`; the row says **Unverified**. Placed on a tab, its card asks — it asks for nothing — with **Unverified** in its header and *Nobody verified this code: it comes from the default branch of github.com/someone/team-plugins, a source you have not trusted. uDeck asks again whenever it changes.*; **Allow** runs it. |
| `plugins.source-same-id-switch` | The official `uptime` 1.0.0 installed, placed and allowed: the source's row of its own `uptime` 1.0.0 — other files, the same permissions — says *Installed here: the verified 1.0.0 from github.com/iillyyaa1997/udeck-plugins* and offers **Install from here…**, whose warning names both copies; confirmed, the record is the source's with the official copy as `previous`, and the card asks again, its copy held to its tree. **Earlier versions…** left open over the official copy goes with it, and opened again lists the source's own history, asked by its number. The official row then says *Installed here from github.com/someone/team-plugins: unverified* with **Switch to verified 1.0.0**, whose warning names both; confirmed, the record is the official one's, **Verified**. |
| `plugins.source-update-and-back` | The source's main moved to `t2`: **Check now** on its block asks the source alone, by its number, and `team-clock`'s row offers *1.1.0 available* from the source's own head; **Update** takes `t2`'s files from the source, recorded as the source's; **Back to 1.0.0** returns to `t1` from the source, the source's, pinned. |
| `plugins.source-reinstall-and-earlier` | `team-clock` 1.1.0 from the source at `t2`, changed on disk: **Reinstall**, after its Trash warning, puts `t2`'s copy back, asking only `/repositories/<id>/…` and the source's raw files. **Earlier versions…** asks the history of the source's own default branch by its number and lists 1.0.0; installing it puts `t1`'s copy in place, still the source's, pinned. |
| `plugins.source-official-off` | **Official catalogue** switched off with a source added: Settings says *The official catalogue is off: uDeck makes no request to the official repository, nor to its forks for Install from a link…, and does not look for updates of what was installed from them. Sources you added are still read; installed plugins keep running.*, and **Install from a link…** that it makes no request to the official repository, nor to its forks for a link. uDeck ended, the source's state made two days old and its main moved to `t2`, started again — it reads the source at launch, by its number, its log saying so. Ended again, the state made a minute and a half short of a day old and uDeck started with Settings closed: no read at launch, and the minute's clock reads it once it is due (*on schedule*). **Update**, **Back to**, **Earlier versions…** and **Reinstall** of its copy each work, from the source; from the switch on, no request reaches the official repository's paths. |
| `plugins.source-renamed` | The fake renames someone/team-plugins to someone/team-plugins-2, its number the same, and serves another repository, someone/squatter, with another number and a team-clock 9.0.0, at the old name. With the source's default branch a day old, **Check now** describes it by its number: `sources.json` says the new name under the same id, and the block shows it. From the rename on, nothing asks the old name, through the API or its raw host, and nothing the other repository has is offered. |
| `plugins.official-id-mismatch` | uptime 1.0.0 installed, verified; uDeck ended, main moved to `c2` and the official repository's description answering another number, the catalogue two days old: started again, uDeck describes the official repository and reads nothing of it after that — no head, no listing, no file — uptime stays 1.0.0, and Settings says *The address of the official catalogue now belongs to a different repository. uDeck stopped reading it, and nothing updates by itself; installed plugins keep running.* Meanwhile uptime's row offers no **Earlier versions…**, the catalogue's rows read before are gone, and **Install from a link…** on a branch of it says the same sentence with no request. **Check now** describes it again and stops again; with its own number back, **Check now** reads on, and **Earlier versions…** is offered again. Before all that, while uDeck runs with the official number: uptime's **Earlier versions…** open listing 1.0.0 and **Install from a link…** of `fix/uptime` listing uptime — the address answering another number and **Check now** read, the list goes from the screen and the sheet says the same sentence in place of the branch's plugins. |
| `plugins.source-downgrade-to-0-7-0` | `team-clock` installed from the source and placed; uDeck ended, `officialCatalogue: false` written into `settings.json`, and the released 0.7.0, as GitHub publishes it, installed and started, its update feed one nobody serves: its Settings say **Unverified** of `team-clock`, and its card asks before it runs. 0.7.0 ended, `sources.json` and every file of `catalogue/<id>/` are byte for byte as they were, and the record's `source` is still the source's id. This build started again, **Check now** on the source reads it by its number, and the row says the copy is from it. GitHub not giving 0.7.0: it could not check. |
| `plugins.source-remove` | **Remove…** on the source, after its warning: the entry and `catalogue/<id>/` go; `team-clock` stays, and its row says *From github.com/someone/team-plugins — a source no longer added*, with no **Reinstall**, **Back to**, **Update** or **Earlier versions…**; Settings opened again, nothing more is asked of the source. |
| `plugins.source-refusals` | **Look up** refuses, each with its sentence and no **Add**: `http://`, git's SSH address and the official repository before any request; `github.com/someone/missing` after its description's 404 (*… could not be found, or it is private. If it is private, uDeck needs a token for it: Token…*); `someone/not-plugins`, with no passport at its default branch, after its description, its head and the passport's 404; and someone/team-plugins once it is added, after its description, *Team plugins (github.com/someone/team-plugins) is added already.* |
| `plugins.link-offers-a-source` | **Install from a link…** on a branch of someone/team-plugins, no fork of the official repository: *github.com/someone/team-plugins is not a fork of github.com/iillyyaa1997/udeck-plugins. To install from it, add it as a source of its own.*, after its description alone, and **Add as a source…**, which opens **Add a source…** with `https://github.com/someone/team-plugins` in its field and adds nothing until **Add** is pressed. Added, the same link is refused before any request: *Installing from a branch or a merge request of a source is not possible yet; add the project and install from its default branch.* |
| `plugins.source-add-gitlab` | **Add a source…** of `https://gitlab.example.test/group/sub/team/-/tree/main`, a project three groups down in the fake's self-hosted GitLab: it comes to `group/sub/team`, and from **Look up** on the log holds, on gitlab.example.test's own port and nowhere else, `GET /api/v4/projects/group%2Fsub%2Fteam` — `%2F` as it was sent, the one request ever addressed by its path — then `/projects/9/repository/branches/main` and the passport at that commit through the files API; the sheet shows the passport's name, and the test build's line says where gitlab.example.test and gitlab.com are read from. After **Add**, every request of it is to `/api/v4/projects/9/…`, on its port; the block is named *Team on GitLab* with its address, its row says **Unverified**, and `sources.json` holds `gitlab`, the host, the path, `remoteID` 9 and the id derived from them. No request carries a credential. |
| `plugins.source-gitlab-install` | `tools/udeck-plugins` added: the read after **Add** lists `plugins/` page after page — three entries to a page, `gl-hello` has six — and `gl-hello`'s row says *4 files*, no bytes, its **Open on gitlab.example.test** carrying `https://gitlab.example.test/tools/udeck-plugins/-/tree/<g1>/plugins/gl-hello`. **Install**: the log holds each of the plugin's four files once, through `/api/v4/projects/7/repository/files/…/raw?ref=<g1>`, and nothing else; the folder hashes to the fixture's tree; `installed.json` says the source's id, `gitlab` on gitlab.example.test at `tools/udeck-plugins`, the default branch, `unverified` by `null`; the row says *From gitlab.example.test/tools/udeck-plugins at …*. **Earlier versions…** lists 1.0.0, asking `/api/v4/projects/7/repository/commits?ref_name=main&path=plugins/gl-hello` and the manifest at `g1` through the files API, nothing else. |
| `plugins.source-gitlab-renamed` | `gl-hello` installed from `tools/udeck-plugins`; the fake serves project 7 as `tools/udeck-plugins-2`. With its default branch a day old, **Check now** describes it by its number: `sources.json` says the new path under the same id and number, the block and `gl-hello`'s page show it, every request is to `/api/v4/projects/7…`, and the copy's record is still the source's. |
| `plugins.source-gitlab-too-large` | `tools/udeck-plugins` at `g2`: `gl-big`'s row offers **Install**, no size listed to refuse it by; **Install**: its 6 MB `big.bin`, made when the fake started, is asked once and refused as it arrives — *plugins/gl-big/big.bin is 6.0 MB; one file of a plugin may be up to 5 MB.* — and there is no `plugins/gl-big`, no record and nothing in `~/.udeck/staging`. |
| `plugins.source-gitlab-empty` | `tools/empty`, a passport and no `plugins/`: its block says *The repository offers no plugins yet.*; the read after **Add** made one tree request, the root's, with no `path=plugins`, and **Check now** asks none either. |
| `plugins.source-gitlab-com-limit` | `someone/gl-plugins` on the fake's gitlab.com, added: its `state.json` keeps both of gitlab.com's limiters by name. The fake says the hour was spent elsewhere; **Check now** gets one `429` naming the hour, and the block says *gitlab.com asked uDeck to wait: … Without a token gitlab.com allows only a few requests an hour from one network; a token raises the limit.*, the hour's remaining 0 and the minute's in the hundreds. **Check now** again, **Install** of `gl-com` — whose row says the same — and twenty seconds: nothing reaches gitlab.com's port; the official catalogue's **Check now** reads it, with no trouble said. |
| `plugins.source-gitlab-not-gitlab` | The fake answers gitlab.example.test's port as a web server with no GitLab behind it, `404 page not found` in plain text: **Look up** of `https://gitlab.example.test/tools/udeck-plugins` asks once and says *gitlab.example.test did not answer as GitLab. uDeck reads sources on github.com and on GitLab — gitlab.com or your own.*, offering no **Add**. |
| `plugins.link-offers-gitlab-source` | **Install from a link…** of `https://gitlab.example.test/group/sub/team/-/tree/main` says *gitlab.example.test is not GitHub. A GitLab project can be added as a source of its own.* with no request; **Add as a source…** opens **Add a source…** with `https://gitlab.example.test/group/sub/team` in its field, adds nothing, and **Look up** there finds the project. Added, the same link says *Installing from a branch or a merge request of a source is not possible yet; …*, with no request and no **Add as a source…**. |
| `smoke.real-pull-request` | Runs only when named, with `--pull-request <link>`, and only on a GitHub runner, against the real GitHub: a lab build that keeps the shipped addresses reads the official catalogue from github.com; the link of an open pull request of the official repository that changes one plugin, typed into **Install from a link…**, says *Pull request #N at …*; **Install** records `ref {pr, "N"}` at its head, `unverified`, by `null`, and the row says **Unverified** · *pull request #N at …*; once somebody has closed the pull request unmerged and deleted its branch, **Check now**, and the row says *Pull request #N was closed without being merged; the plugin keeps running*, the catalogue row *… unverified — closed without being merged*, the record as it was. Fewer than fifteen of the hour's sixty left to the runner's address, a pull request merged or closed before the install: it could not check. Screenshots of each. |

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
* `installed.json`: reading and writing, and the status computation — a file
  from 0.6, a status a later uDeck writes read as `modified` with the file
  whole, a branch's and a pull request's record written as read, and verified,
  unverified and modified by the source, the ref and the tree on disk;
* the permission gate, held to a version or to a tree (`PermissionGate`, in
  the plugin format, run on Linux too): a table of the two bases — no
  decision, one for this tree, for another tree, from before there were trees,
  for another version, a refusal, a folder not hashed yet, nothing asked for —
  and that a required tree only ever asks for more; what the decision is held
  to (`ConsentBasis`), an `installed.json` that cannot be read included; a
  hashing that finds the same tree keeping a poll loop, another tree stopping
  it, and the runs between a change and its hashing skipped (`HashedTrees`);
  **Allow** granting only for the tree the card showed; a pull request's copy
  put back by **Reinstall** and **Back to** as the pull request's, unverified,
  an earlier version as the default branch's, and a fork's default branch
  never taken as the source's (`ShownPlace`, `PluginInstaller`);
* a github.com link, read (`RepositoryLink`): every form it accepts — a pull
  request and the pages under it, a branch whose name holds `/` with and
  without a plugin's folder after it, a repository's own page — and every one
  it refuses, with what it is; what a link comes to once GitHub is asked
  (`RefResolver`), against a provider of the test's own that counts its
  requests; and a pull request as GitHub answers it, through the client's own
  transport (`GitHubClient.pull`);
* installing from a link (`InstallFromLinkTests`): **Install** on a row the
  link listed — onto nothing at once, recorded as the pull request's or the
  branch's, unverified; over the verified copy, the warning that names both
  sources and the ref, nothing changed until it is confirmed, the verified
  copy kept as `previous`; over a folder of the operator's own or a link,
  their own warnings; which lines of history are the same and so no switch;
  the catalogue row of an id installed from a pull request and its **Switch
  to verified**, its warning, and no update offered against the head; where
  a copy came from as its row says it, and its page; when the card's header
  says **Unverified**; what the card says of where the code comes from, never
  *sandbox*; why a link names nothing to install, in both languages; and a
  run held to its tree not started on a decision for another tree, or before
  its folder is hashed (`PollExecutionTests`); what the window of such a copy
  whose folder has gone says beside **Reinstall** (`reinstallSays`), and when
  Settings says nothing is installed (`PluginsPane`);
* a copy of a branch or a pull request becoming **Verified** (`AdoptionTests`):
  the truth table — exactly what the head has, adopted at the head; what the
  commit its pull request was merged into the default branch as has, adopted
  there; merged into another branch, changed on disk, not hashed, another
  tree, another source, another pull request's merge, not merged — the record
  rewritten and nothing else, the decision holding with no question, the
  update the head has then offered or made by itself, and the installer
  recording such a copy as the default branch's at once; what became of the
  pull request (`PullRequestLifecycle`) — the verified version offered, or
  none to offer — what **Look up** heard kept at install (`FollowedRefs.keep`),
  and what is asked of GitHub about it (`PullRequestFollower`), against a
  provider of the test's own that counts its requests — once per copy not at
  the head, nothing in a read nobody asked for while the reserve is all that
  is left, the listing of a merge commit into the default branch once and of
  any other never, what was heard kept and read back, and joined with what an
  install, an adoption or a removal said meanwhile;
* following the branch or the pull request a copy came from
  (`RefFollowerTests`): GitHub's comparison read, and asked through the
  client's own transport (`GitHubClient.compare`); whether a head continues
  what is installed (`HistoryRewrite`) — ahead, identical, behind, diverged,
  the commit gone, and nothing known without an answer — and held for exactly
  those two commits; what is asked, against a provider of the test's own that
  counts its requests (`RefFollower`) — a pull request whose head moved,
  listed and compared once and then kept; pushed again, rewritten; a
  comparison with no answer left as it was and said not checked; a head with
  the copy as it was compared with nothing; a pull request merged into the
  default branch whose head is not listed, and the default branch never
  compared with; a branch asked with the commit installed, a `304` asking
  nothing more, moved, deleted; copies never asked about; the reserve, said
  since when; `followed.json` from before branches read as it is; what the
  cache holds of a moved head (`RefHead`); what a copy's row offers along its
  line (`RefOffer`) and says and offers whole (`UnverifiedRow`) — the verified
  copy offered here or not (the catalogue off, not there, unable to run), the
  verified copy's one name on both rows, what counts as waiting, the lines in
  order, in both languages; **Update** along the line (`ShownPlace.alongTheLine`);
  **Back to** and **Reinstall** of a pull request's copy the head has, named as
  the verified copy they are recorded as (`ShownPlace.recordedAs`); and a pull
  request merged into another branch as the link sheet says it
  (`LinkRefusal.head`), and a commit GitHub no longer has, put back, as it is
  said (`InstallFromLinkTests`); what **Look up** heard kept at install only
  over what a read heard before it, and as heard when it heard it — a branch
  deleted, or moved on, or a pull request closed by a read after it, standing
  (`keptAtInstall`);
* branches of forks (`ForkTests`): GitHub's description of a repository read,
  and whether it is a fork of the official repository — a fork of a fork, the
  name in another case, a fork of another network, one of its own, no source
  named; a client for a fork on the same host, none for another host or a path
  that is not `owner/repo`, and one limit for both, through the client's own
  transport (`GitHubClient.client(for:)`); a fork's link asked of the fork and
  nothing of the official repository — its branch, its own page's default
  branch, renamed — and refused after one question when it is no fork, not
  there, or its branch is not; the installer fetching every file from the
  fork, and never a fork's default branch; a fork's branch followed in the
  fork, what was heard held to its repository; and the fork named in every
  sentence that names its line, in both languages, in the warnings of a switch
  across lines — **Switch to verified**, an earlier version, **Reinstall** —
  and in **Back to** from the fork; and *What changed* opening the fork's own
  compare page;
* the temporary folder a run was given (`TemporaryFolderTests`, and the
  `home:` line of `udeck-plugin run` in `RunPluginTests`): `TMPDIR` when it
  names a folder by its full path, the system's otherwise — and the `TMPDIR` a
  plugin is handed; the lock file's reader making its file from a template in
  `TMPDIR` (`PluginLockTests`);
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
  card (`PluginSnapshot.failureOnAFreshCard`);
* which plugins update themselves (`AutoUpdate`): each condition — the switch,
  an update waiting, **Verified**, `pinned`, the permissions, the operator's
  work at the place, a failure since the last read, a card action running,
  another operation — taken away alone from a plugin that does, each with its
  own reason, and the permissions compared byte for byte as a set; and the
  decision across a swap (`GrantCarry`): carried from one verified copy to
  another asking for the same, a refusal included, left as it was otherwise,
  and the gate running the new version on a carried decision and asking on one
  left as it was; when they are asked (`AutoUpdateSchedule`): only after a read
  that succeeded, only on folders hashed after it, again on the minute's tick
  while one waits, a failure said until the next read and a folder left as it
  was no failure; and, at the swap, an update by itself refusing a place that
  holds the operator's work by then (`PluginInstaller`);
* sources of one's own, underneath (stage 4 — nothing in Settings reads or
  offers them yet): `~/.udeck/sources.json` read and written (`SourcesTests`)
  — keys it does not know ignored and written back as they were, each entry
  uDeck cannot use left out with its reason and written back as it was, and
  the whole file broken by an id that is not the one derived from the entry's
  provider, host and `remoteID`, by two entries of one id or of one repository
  — entries left out counted, and Add refused beside one — or by a file that
  does not parse, and then never written over; a source's id — a rename keeps
  it, a new repository at the old name gets another, and the pattern holds
  whatever the host and the path; an address as a browser shows it
  (`SourceLinkTests`), every GitHub and GitLab form and every refusal; what a
  source is called, its passport's name cleaned and isolated or its address; a
  row of one source's catalogue of a copy from another
  (`CatalogueRowState.fromElsewhere`), an update offered only from a copy's
  own source's head, and two default branches one line only within one source
  (`CatalogueRowTests`, `ShownPlaceTests`); which source a previous copy is of
  (`PreviousCopy.source`), a check against each copy's own source's head, and
  what the card, the window and the row say of a source's copy
  (`UnverifiedCodeTests`); one schedule of updates by themselves per source
  (`AutoUpdateTests`); the GitHub client asking `/repositories/{id}/…`, and,
  so addressed, nothing of any other repository (`ForkTests`); and the files
  0.7.0 wrote read and written back byte for byte, `settings.json` but for the
  order of a set (`FilesFrom070Tests`);
* a public GitHub repository as a source (`SourceReadingTests`): **Look up**'s
  three requests — the repository by its name once, its head by its number,
  the passport from the raw host — and what it comes to for an address refused
  before any request, a repository not there, one with no passport, one with
  no number, one added already under any name, the official repository by its
  number and an entry left out that is the same repository; a source's client
  answering for its number alone, taking the name a describe gives it and
  asking raw files by it, and believing no describe of another number; the
  official repository's describe held to its number, another or none stopping
  the read before its head, and standing — asked again first, kept by a read
  that fails before a describe answers — with nothing else of the official
  repository read meanwhile; a read that does not finish naming the
  repository as GitHub spells it; a copy's earlier versions standing, and
  installing, only for a copy of the source they were read from; what may be
  read with **Official catalogue** off,
  when each source is read, what a read that did not finish says for each
  host, the test build's line, and a link into a source refused; **Reinstall**
  of a copy of a source no longer added giving nothing (`ShownPlaceTests`);
* GitLab projects as sources (`GitLabClientTests`, `GitLabSourceTests`), against
  stub answers shaped like the ones recorded: **Look up** by the encoded path —
  GitLab's own `404`, and one that is not GitLab's — and everything after it by
  the project's number; describe with and without `forked_from_project`, and one
  of another number, or of none, not believed; the head with a weak `ETag` and its `304`; the
  listing put together from the root and `plugins/` page after page, as git's
  own tree less the sizes, an empty root asking once, and a next page that does
  not go on; a file from the files API, refused by `X-Gitlab-Size` and cut one
  byte past 5 MB; a folder's history; every merge request state; the merge
  base's four answers and its `400`; every status — `401`, `403`
  `insufficient_scope`, other `403`s, `404`, `429`, `3xx`, a `400` from the
  files endpoint and from anywhere else; gitlab.com's two limiters each kept by
  its name, the reserve kept of the one with the least left, and states with
  and without them read back; the host map, its pages on the real host, and a
  test build's line for it; item 9 and item 13 in both languages; **Install
  from a link…** of a GitLab project's page, of one with a port, and of a link
  into a GitLab project already added; a manifest past 5 MB refusing its own
  row only; a listing without sizes in
  `RepositoryRules` (`CatalogueTests`) and in a catalogue row; the installer
  holding such a listing to rule 8 as the files arrive (`PluginInstallerTests`)
  — a file past 5 MB, files past 10 MB, a file the provider refuses, a limit
  that is not retried — and keeping a previous copy under the name its source
  has now, matched to it by its id; and one write of a catalogue's state at a
  time;
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

### Stage 1 — the shortest path (built)

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

### Stage 2 — one validator and a template (built but for one step)

The rules move into a Swift library, `UDeckPluginFormat`, that builds on macOS
and Linux; the `udeck-plugin` command (`check`, `check-repo`, `new`, `run`)
is shipped as release assets and a container image ([Where the command comes
from](#where-the-command-comes-from)), and a repository pins one release in a
lock file `udeck-plugin pin` writes ([The lock file](#the-lock-file)); uDeck
links the same library; CI templates for GitHub Actions and GitLab CI, with a
variable for a mirror of the image (in the template repository below); the
version-bump and `minUDeck` checks; a template repository anyone can start from
([`udeck-plugins-template`](https://github.com/iillyyaa1997/udeck-plugins-template),
with the check for GitHub Actions and GitLab CI); a plugin folder that is a link
to a working copy, for development; a run log and the standard error of
successful runs for authors. The bash check in uDeck's CI goes; the official
repository's Python script runs beside `udeck-plugin check-repo` until the two
have agreed long enough ([The official repository](#the-official-repository)).

### Stage 3 — branches, pull requests, verified (built)

* **Install from a link…**: a pull request or a branch of the official
  repository, or a branch of a fork of it, read through `RepositoryLink` and
  `RefResolver`, its plugins that are not the catalogue's listed and installed,
  recorded with their ref, and every button that puts a copy back keeping it
  ([Installing from a branch or a pull request](#installing-from-a-branch-or-a-pull-request),
  [`installed.json`](#installedjson)); a repository that is no fork of the
  official one refused once GitHub has said so; **Switch to verified**, and
  every switch between copies of two lines of history naming both.
* **Unverified**, on the plugin's row, in the list it came from, on the
  catalogue row of the same id and on the card's header and question
  ([Where Unverified is said](#verified-trusted-unverified)).
* Consent for every new content of code nobody verified, a plugin that asks for
  nothing included ([Consent for unverified code](#consent-for-unverified-code)).
* **Verified** computed from content: a copy whose folder is what was merged
  becomes the default branch's with nothing downloaded; a pull request merged
  with changes offered the verified version, one closed unmerged said ([When the
  pull request is merged or closed](#when-the-pull-request-is-merged-or-closed)).
* Verified plugins updating themselves after a read of the catalogue, with the
  permission decision carried across a swap of one verified copy for another
  ([Automatic updates](#automatic-updates), [Updating](#updating)).
* The branch or the pull request a copy came from followed at the catalogue's
  moments — its new head offered with *What changed*, history rewritten on it
  said, a deleted branch said, and since when it was not checked — and a fork's
  branch read, installed, followed and named from the fork itself ([Following
  the branch or the pull request a copy came
  from](#following-the-branch-or-the-pull-request-a-copy-came-from)).
* Every screen of it in English and Russian, and the lab's checks of them,
  `smoke.real-pull-request` against the real GitHub among them ([The lab's
  checks](#the-labs-checks)).

### Later stages

* **Stage 4 — own and private sources** (begun: a public GitHub repository and
  a public GitLab project as a source of its own — [Sources of one's
  own](#sources-of-ones-own)).
  `~/.udeck/sources.json`; GitLab,
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
