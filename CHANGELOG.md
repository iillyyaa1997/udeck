# Changelog

All notable changes to uDeck are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

The **plugin contract** is versioned separately from the application, by the
`api` field in a plugin manifest. See [docs/plugin-api.md](docs/plugin-api.md)
for what that promises.

## [Unreleased]

- **About says how to open a downloaded copy on macOS 15 and later.** It said
  right-click → Open, which macOS 15 no longer lets past Gatekeeper for an app
  that is not notarised; the way through there is System Settings → Privacy &
  Security → Open Anyway, after the first refusal. The README's new
  Installing section says the same.
- **A template to start a plugin repository from, and the official one's check
  as it runs now.** docs/plugin-repository.md points to
  [`udeck-plugins-template`](https://github.com/iillyyaa1997/udeck-plugins-template),
  with the check for GitHub Actions and GitLab CI (writing-a-plugin.md links
  it), and says what its CI does
  with a lock file a pull request changes and with a mirror; how the official
  repository's `validate` runs `udeck-plugin check-repo` beside the Python
  check since udeck-plugins#2; and, in the CI example, which commit is the
  base: the first parent of GitHub's merge of the pull request, and the target
  branch's tip on GitLab.

## [0.6.1] — 2026-10-08

What 0.6.0 holds, published. 0.6.0 was tagged, and its release stopped before
it published anything: ghcr.io answered the image's index with 500 Internal
Server Error, twice, because the index was annotated with the image's whole
licence expression — a probe package showed it takes each part of it, a flat
list of twelve licences, and the whole expression as the image's label.

- **The image's licences are its label, not an annotation of its index.** The
  expression is the same, every licence of the command and of the image's
  Alpine packages, and the index carries no annotation of them.
- **The sources of the image read aports from its GitHub mirror**, which a
  GitHub runner can reach (gitlab.alpinelinux.org answers one with 418); every
  object git takes is held to its id. And make-cli reads what it looks for
  whole: under pipefail a `grep -q` that has its answer early could fail a
  release by SIGPIPE, or let `readelf | grep -q INTERP` pass unread.

## [0.6.0] — 2026-10-08 — tagged, not published

Everything below first reaches anybody in 0.6.1.

Plugins come from somewhere now. uDeck lists the official repository's plugins
in Settings and installs, updates, takes back to an earlier version and removes
them — every file checked against the hash the repository lists, the folder
swapped into place in one step, and nothing a person put into a plugin's folder
thrown away without saying so first. Somebody writing a plugin gets
`udeck-plugin`, which checks a plugin with the code uDeck itself runs, inside
uDeck.app, and links a working copy in to run from where it is. And a release
carries more than the app for the first time: the command as archives for
macOS and Linux and as a container image, which a plugin repository's CI pins,
by its digest, in a lock file — with the source of the image's GPL and LGPL
packages beside it.

- **`udeck-plugin pin` and the lock file.** A plugin repository names the one
  release of `udeck-plugin` its CI runs in `.github/udeck-plugin.lock`, on
  GitHub and on GitLab alike: the version, the sha256 of the three archives
  and the image's digest, five `key=value` lines and nothing else, read from
  the base of each change so that a pull request cannot choose the check that
  judges it. `udeck-plugin pin` writes it from a release's `SHA256SUMS` and
  `udeck-plugin-image.txt` — the latest, or `--version X.Y.Z` — once the two
  agree, and `pin --check` exits 1 when the file is not what its release has.
  Releases are GitHub's unless `UDECK_PLUGIN_DOWNLOAD_BASE` names another
  place laid out the same way (`https://` or `file://`, never plain `http://`);
  they are read with the system's curl, which takes its proxy from
  `HTTPS_PROXY` and `NO_PROXY`. A login in that address
  (`https://user:token@…`, as a private GitLab's generic packages ask) is said
  as `***` wherever `pin` says the address, and reaches curl on its standard
  input, never among its arguments, which any process on the machine can
  read. Pinned from anywhere but GitHub, `pin` says that the lock file holds
  what that place serves — two files a mirror serves can agree with each other
  and with nothing GitHub published — and that `pin --check` against GitHub's
  release is what tells. A release from before the command was published —
  0.5.0 and earlier — is said to be one. The specification gives the shell
  reading a CI runs, with `sed` and never `source`, on the lock file of the
  change's base, read out of git rather than from the pull request's checkout;
  a test holds it to the command's own on a corpus of good and bad files, in a
  UTF-8 locale too and with bytes outside ASCII, and the image runs it with its
  own BusyBox on every push. The image now holds curl too, for `pin`.

- **`udeck-plugin` without uDeck.** Every release carries the command for
  whoever has no uDeck to take it from: `udeck-plugin-X.Y.Z-macos-universal.tar.gz`
  (arm64 and x86_64 in one binary, signed as the copy inside uDeck.app),
  `-linux-x86_64` and `-linux-aarch64` (static musl, stripped — nothing else
  to install), `SHA256SUMS` over them, and the container image
  `ghcr.io/iillyyaa1997/udeck-plugin` for linux/amd64 and linux/arm64 — Alpine
  with git, for a plugin repository's CI on GitHub Actions or GitLab CI —
  whose digest is in the release's notes and in `udeck-plugin-image.txt`. The
  command says the release's version, and a release whose command says another
  is not made. Everything goes out in the one `gh release create` that
  publishes the app, since a published release takes no asset afterwards; the
  image is pushed just before it: built once, pulled by its digest from a
  registry of the job's own and run on both platforms — its examples checked
  and a repository made inside it — and only then copied by that digest to
  ghcr.io. CI goes the same way on every push, to the image file, `SHA256SUMS`
  and the release's notes, and publishes nothing — a change to the release is
  proved before a tag needs it. `Scripts/make-cli.sh` makes all of it, for
  both. Each archive carries `THIRD_PARTY_NOTICES`, the licences of what else
  the command is made of (Swift's runtime and Foundation — swift-foundation's
  uuid.c, under a licence of its own, among it — swift-crypto and its
  BoringSSL, LLVM's libc++, musl, fts, mimalloc), and holds nothing of the Mac
  it was made on — no extended attribute, no AppleDouble `._` file; the image
  lists every Alpine package in it with its licence and where its source is,
  and its licenses label names them all.

- **The source of the image's GPL and LGPL packages goes out with it.** Git,
  BusyBox and the other Alpine packages in the image under the GPL or the LGPL
  (on 2026-10-07's index also apk-tools, musl's utilities, scanelf, libidn2,
  libunistring, zstd's library and Alpine's base layout) have their source in
  the same release: `udeck-plugin-image-sources-X.Y.Z.tar`, one asset and one
  line of `SHA256SUMS` — each package's folder of Alpine's aports at the
  commit it was built from, read by git, and the upstream archives its
  APKBUILD names, from Alpine's distfiles, each held to the sha512 the
  APKBUILD gives, with a README and a `SHA512SUMS` of everything in it. It is
  gathered from the package list of the very image that ran, before that
  image is published, and the image's `ALPINE-PACKAGES` and
  `THIRD_PARTY_NOTICES` name it. CI gathers it on every push, as a release
  does, and `udeck-plugin pin` knows it as one of a release's files.

- **`check-repo --strict` fails where rule 18 could not be checked.** A clone
  too shallow to compare a changed plugin's version — the one commit
  `actions/checkout` fetches by default, or a `--base` a shallow clone does not
  hold — got a warning and passed, or exited 2. With `--strict`, and so
  `--official`, it is an error now, exit status 1, that says how to fetch the
  history: `fetch-depth: 0` on GitHub, `GIT_DEPTH: 0` on GitLab — and with
  `--official`, for a base the clone lacks, rule 17's sign-offs too. A first
  commit, which has nothing before it, still passes, and without `--strict`
  nothing changes.

- **Every button that takes a link away says so first.** **Update**, **Switch
  to**, **Reinstall**, **Back to** and **Install this version** over a plugin
  whose place holds a link — one put there while the warning about the copy was
  up included — say first that only the link goes and the folder it leads to
  stays, as **Replace…** says it; they used to take the link away without a
  word. And they are held to the copy that comes, not only its version: a
  repository that published another tree under the version the warning named
  gets the warning again rather than an install of what nobody was shown.

- **Install command takes away only its own link.** Putting the link in place
  over another uDeck's, it puts back anything of somebody else's that appeared
  meanwhile — and now also reads what that putting back took out of the place:
  something written there in between stays, beside it, and Settings says
  where, instead of being deleted unread. Where the command cannot be linked —
  a uDeck run from its download or its disk image, or a development build —
  the button is not offered at all, rather than shown greyed out under the
  line that says why.

- **Link a folder… names both folders the same way.** Over a link, its warning
  wrote the folder chosen as `~/…` and the folder the link leads to as
  `/Users/…`; both are written from the home folder now, and so is a plugin's
  folder under **More**, which was written whole.

- **A plugin that will not load says in Russian that its details are English.**
  Why a manifest or a folder is refused is said in the plugin check's own words
  — those `udeck-plugin check` prints and a plugin's row in Settings shows —
  which are English; in Russian the sentence now says so, *плагин не
  загружается (подробности по-английски, словами проверки плагина): …*, rather
  than trailing off into English unexplained.

- **Settings → Plugins for somebody writing a plugin.** A linked plugin's row
  is marked **Linked** and says where its link leads (or that uDeck does not
  follow it), and **Remove** on it says first that only the link goes — the
  folder it leads to stays exactly as it is — as **Replace…** on a catalogue
  row over it does. **Link a folder…** links a working copy chosen in the
  system's folder panel: an id nothing has at once, and over a plugin uDeck
  installed, a folder of your own or another link only after it has said what
  becomes of what is there — deleted when it is exactly what uDeck installed,
  to the Trash when it holds anything of yours, a link pointed elsewhere — and
  a folder that is no plugin's is refused in so many words. **Keep a run log
  for linked folders** is a switch now, with **Show the logs** once there is
  one. Under **More**, every plugin says its last run whatever it came to —
  when, why, how long, a card or a failure — and the end of its standard
  error, its last eight lines and at most 800 characters of them, with how
  many bytes came before the 64 KiB uDeck keeps. Every text is in English and
  in Russian — why a run failed too, on the card and in Settings, with its
  seconds written the language's way.

- **A warning's button does what the warning said, or says what is there
  now.** **Remove**, **Replace…**, **Update**, **Switch to**, **Reinstall**,
  **Back to**, **Install this version** and **Link a folder…** carry what
  their warning showed — the id, what is at its place, whether it goes to the
  Trash, the version that comes — and, pressed after any of it changed, do
  nothing and warn of what is there now. **Link a folder…** shown over one
  plugin, its manifest's id changed to another before **Link** was pressed,
  used to put the link in the other's place and send its copy to the Trash
  without a word. **Install** on a row that said nothing was there warns first
  of a folder put there since. **Allow** grants nothing the consent card or
  Settings did not list: a manifest that asks for one command more while the
  question is up is asked about again.

- **No density button on the panel.** Density is set in Settings → Look, as it
  always could be.

- **A failed run is said on a card that is still fresh.** A run that fails —
  or prints its card and runs past its `timeout` — while the card before it is
  within its `ttl` puts an amber dot by the card's name and a line under its
  values: *Last run failed at 21:04: the producer exited with status 3*,
  *showing values from 21:03*. It goes with the next run that prints a card;
  a card past its `ttl` says it as before, and the whole standard error is in
  Settings. A card used to look healthy until it went stale.

- **Where to look for commands, in Settings.** The folders a bare command in
  a manifest — `"run": ["python3", …]` — is looked up in are a list under
  Settings → Plugins: **＋ Add a folder…** (first in the list), **−**, **↑**,
  **↓** and **Restore the defaults**, written to `settings.json` at once and
  read by the next run, with no restart. The last folder looked in cannot be
  removed. Only folders written from `/` are looked in, by uDeck and by
  `udeck-plugin run`, and handed to a producer in `PATH`: `bin` or `~/bin`
  written by hand would be read from two different folders by uDeck and by
  the producer's shell, and nothing expands `~` there; the list says so of
  such a folder, and of one that is not there now. A list with no folder
  written from `/` is the default, as an empty one was.

- **`udeck-plugin` inside uDeck.app, and Install command.**
  `Scripts/make-app.sh` builds the command from the same checkout and puts it
  in the bundle at `Contents/Helpers/udeck-plugin`, signed before the bundle
  that seals it, and verifies the whole bundle deep and strict. Settings →
  Plugins → **Install command** links `~/.local/bin/udeck-plugin` to it — the
  account's own folder, no administrator password — so the command is
  whichever uDeck is installed and updates with it; it says whether the
  shell's `PATH` has `~/.local/bin` (asked of the shell itself) and, when it
  does not, the line to add and where, without touching the shell's files. A
  link to another copy of uDeck's command is pointed at this one; anything
  else at that place is said and never replaced — also when it appears
  between uDeck looking and the link going in, which is one step that fails
  rather than replace it — and a uDeck opened where it was downloaded, or on
  its disk image, makes no link to a copy that will go: move it to
  Applications first. **Remove command** takes the link alone.

- **Paths read by their bytes, everywhere a command is resolved.** Whether a
  manifest's `run[0]` is a path from `/`, a path in the plugin's folder or a
  bare name, and whether a path stays inside the folder, were answered by
  Swift's `Character` — a `/` with a combining mark after it is one, which is
  not `/` — and so was what Linux calls a hidden name in the plugins folder,
  whether `udeck-plugin` reads an argument as absolute, and the folder name
  `check` prints. They are read by bytes now, as the system reads them.

- **Quieter in the background.** Hiding the panel while plugins keep running
  no longer starts every plugin's interval over; a hashing of the installed
  plugins made pointless by a later read of the plugins folder stops at its
  next folder instead of running to the end; and when the folders linked
  plugins lead to cannot be watched, uDeck says so in its log and asks again
  on the next read, where it used to take them for watched.

- **uDeck lists a plugin whose folder is a link: a linked folder.** A link in
  the plugins folder, `<id>` → a folder outside uDeck's own, is a plugin named
  after the link, read where it leads by the same rules as any folder, and
  watched there: an edit in the author's working copy reaches the card as an
  edit in `~/.udeck/plugins` always did, and a link pointed elsewhere or taken
  away is noticed too. A change there starts again only the plugin it changed —
  every other plugin's next run stays when it was due, where every read of the
  plugins folder used to start every plugin's interval over — and hashes no
  installed plugin. A link that leads nowhere, to a file, to another link (a
  `/` or `/.` at the end of it included), round in a circle, into `~/.udeck` or
  around it is listed with the reason and not run. Removing a linked plugin, or installing over it from a
  catalogue, takes the link and nothing else — the folder it leads to is never
  deleted, sent to the Trash or written into, `.env`, `installed.json` and
  `cache/` look-alikes in it included — and a linked folder is never in
  `installed.json`. uDeck can put a link in an installed plugin's place itself
  (**Link a folder…** in Settings, above): the plugin
  quieted, the link swapped in the way **Replace…** swaps a
  download, the copy it replaces deleted or sent to the Trash by the usual
  rule — judged once the plugin is quiet, so a file saved into it meanwhile
  sends it to the Trash — its record forgotten, its windows and decisions
  kept, and a crash halfway finished or undone at the next launch.
  `udeck-plugin link` stops saying uDeck skips a link, refuses a folder inside
  uDeck's own or one that holds it, and — like uDeck — finds the home folder in
  the account database rather than `HOME`, and reads `UDECK_HOME=~name/…` as
  Foundation does: `CFFIXED_USER_HOME` when that is set, the account `name`'s
  otherwise.

- **Standard error no longer counts toward the 1 MiB limit, and its end is
  kept.** The limit that stops a run is standard output's alone; a producer
  explaining itself at length is never stopped for it. uDeck keeps the last
  64 KiB of every run's standard error — the end, where an error is, cut on a
  whole character — with the plugin's last run, a card's as much as a
  failure's (it used to drop a good run's). Settings shows the last run's last
  lines, a good one's too, where it showed a failed run's first eight.
  `udeck-plugin run` keeps the same tail and says how much came before it.

- **A linked folder's run log.** With **Keep a run log for linked folders**
  on in Settings → Plugins (`"linkedFolderRunLog": true` in `settings.json`),
  every run of a linked folder is
  an entry in `<uDeck's folder>/logs/<id>.log` — when, why, how long, how it
  ended, what it came to, and its standard error's tail — written off the main
  thread, never inside the folder the link leads to, turned over at 1 MiB with
  one older file kept, and taken away by **Remove**. One that cannot be written
  says why in the system's words.

- **`UDECK_REFRESH_REASON=launch`, as the contract promised.** The first run
  of a plugin after uDeck starts — whatever asked for it — is `launch`, and so
  is every run after it until one prints a card: a plugin added while uDeck
  runs gets it on its first run, and a first run that fails, or times out
  before printing a card, does not use it up.
  Until now only `interval` and `manual` were ever sent.

- **The catalogue is read away from the main thread.** Every manifest in it —
  a file of somebody else's, read, hashed again and parsed strictly — used to
  be read on the main actor at launch and after each refresh, as was the
  manifest an install is checked by; now they are read on the cooperative pool,
  and a debug build stops a reader that slips back. So are the installed
  plugins hashed when the plugins folder is read, and at launch no record's
  verification is written before the catalogue is read: `checkedAgainst` no
  longer goes back to the install's own commit at every start.

- **The search path is said where it is.** The contract promised it was
  "changeable in settings"; it is `pluginExecutableSearchPath` in
  `settings.json`, which **Where to look for commands** in Settings sets
  (above), and says so.
  `udeck-plugin run --home <uDeck folder>` now looks a bare command up on that
  search path and hands it to the producer as `PATH`, as uDeck does.

- **A plugin's name and description are one line each — rule 20.** In
  `manifest.json` and in every translation, `name` and `description` hold no
  control character (C0, DEL, C1, the tab and every line break among them) and
  neither U+2028 nor U+2029: they are what a catalogue row, the plugin list and
  the consent sheet show on one line, and an escape sequence in them acts on
  the terminal that prints them. The contract says so (docs/plugin-api.md,
  "One line"), `check --strict` and `--official` call it an error naming the
  character, and `new` refuses such a `--name` or `--description` by the same
  test. uDeck itself loads such a manifest as it always has — the `api: 1`
  promise holds it to that.

- **`udeck-plugin new`, `run` and `link`: the commands an author works with.**
  `new <id>` makes a plugin that already works and passes `check --strict`:
  inside a plugin repository (`udeck-plugins.json` in the folder or above it)
  as `plugins/<id>/`, anywhere else as `./<id>/`, never in `~/.udeck` — a
  manifest, a Russian translation, a README with what a reviewer reads, an
  executable POSIX `sh` producer that builds its JSON safely, and, where the
  repository's own LICENSE is the Apache License 2.0, a LICENSE of the
  plugin's own, `Copyright <year> <author>` above that text. The author is
  `--author` or git's `user.name`; the author, `--name` and `--description`
  are one line each, with no control character, and the producer holds none of
  them. `run <folder>` (a Mac's command) runs the producer once with uDeck's
  own code — in its folder, with the environment uDeck builds, under its
  `timeout`, in a process group of its own, with the 1 MiB limit, a uDeck
  folder of its own unless `--home` names one — and says how it ended, how
  long it took, its standard error (the end uDeck keeps of it, and how much
  came before), the card as uDeck reads
  it or the failure uDeck would show, and what uDeck would have let pass
  without a word: a field it ignores (`stat`, `tll`), a row type it does not
  draw, what it cuts at a limit, a card printed before a run past its
  deadline, a file written into the plugin's own folder, output dropped at the
  limit — and, once a release adds to what a card can hold, a part of the card
  newer than `minUDeck`, which nothing in a card is yet. Its exit status is 0
  for a card, 1 for a failure — a card printed before a run past its timeout
  is one, as uDeck counts it — and 2 when uDeck would not run the plugin.
  `link <folder>` puts a link, `<uDeck's folder>/plugins/<id>` → the folder —
  `UDECK_HOME` or `~/.udeck`, as uDeck finds it, unless `--home` names another
  — for an id nothing else has taken, and never touches `installed.json`; over
  a plugin uDeck installed it names **Link a folder…** in Settings, which says
  first what happens to the installed copy.
  `run` hands the producer the account's home folder as `HOME`, as uDeck does,
  not the shell's.
  Running a producer moved into the plugin format's package for it — the
  process group, the deadline, the output limit, the environment, and what a
  run comes to — on the standard library, FoundationEssentials and Darwin, and
  uDeck runs every plugin with it, as before: its tests of running plugins are
  unchanged and pass. `Scripts/new-plugin.sh` is gone, and the guides start
  from `udeck-plugin` instead; the contract no longer offers `UDECK_HOME` as
  the way to keep a plugin under version control, and says exactly which
  variables a card's action gets. CI holds the examples to `udeck-plugin check
  --strict`, with no warning, instead of a shape check of its own, and fails
  when the tests leave a `udeck-tests-*` folder behind.

- **The plugin format is a package of its own, and `udeck-plugin` checks
  plugins with it, on a Mac and on Linux.** Stage 2 of
  [docs/plugin-repository.md](docs/plugin-repository.md) begins. Manifests,
  discovery, cards, capabilities, versions, the passport, the listing and
  git's hashes moved from UDeckCore into `Packages/UDeckPluginFormat`, which
  builds with FoundationEssentials and swift-crypto alone; uDeck links it by
  path, so one commit is one version of both. CI builds and tests it on Linux
  as well, x86_64 and aarch64, and links `udeck-plugin` into a static musl
  binary that needs nothing installed.

  `udeck-plugin check <folder>…` and `udeck-plugin check-repo` are every rule
  of the official repository's Python check, in Swift, in three layers: with
  no flag, what uDeck refuses to install, decided by the code uDeck itself
  runs; `--strict`, everything a repository's CI should hold a plugin to; and
  `--official`, the official repository's own rules 14–17, sign-offs only
  there. A repository is read through git at one commit, never through its
  working tree; one folder is read as committed in a working copy, from disk
  elsewhere, and through a link to it. Exit status 0, 1 or 2, as the Python
  check had. The two places the Python check was wrong are right: a `run[0]`
  that climbs out of the folder and back is rule 5, and a `restart` uDeck
  cannot decode is rule 3 — and `restart`, which the contract does not
  describe, is rule 12 under `--strict`, as it was. Held to a frozen corpus of
  what the Python check said about 273 repositories: all 273 agree, three of
  them as their divergence says. A repository is checked in time proportional
  to its plugin folders.

  Two rules are new. **Rule 18**: whenever anything in a plugin's folder
  changed, its `version` went up — against `--base`, the target branch's tip,
  for a pull request, and against the commit before for a push; a clone
  without that history, or without the blobs to compare (`filter: blob:none`),
  gets a warning or an error that says to fetch it, never a silent pass, and a
  clone without any other file the check must read is exit status 2.
  **Rule 19**: `minUDeck` is not below the release that has everything the
  plugin uses, worked out from a registry that dates every part of the
  contract — a test fails on one that is not dated — and one that does
  nothing is a warning.

  Git is told nothing by anybody's configuration, and nothing a repository's
  own configuration names can make it run a program: no clean filter (no
  `git status`), no file-system monitor or hooks, no transport and no fetch of
  a missing object, no `ssh` command; `safe.directory` is opened for the
  repository being checked only, at the path git itself answers for it. Git's
  answers go through files that have no names, so a run that is stopped
  leaves nothing behind but the one folder a strict check makes, in a folder
  of the check's own (`udeck-plugin-<uid>` in the temporary folder), which a
  run an hour later takes away. The passport is read by a JSON reader of the
  format's own, which takes `format` from the number as written — so
  `1.00000000000000000000001` is no format 1 — in time proportional to the
  text; and it has a limit, 64 KiB, past which uDeck refuses it unread, since
  its catalogue is read on the main thread. The words of every finding name
  fields and kinds of JSON values, never a Swift type — and where no field is
  to blame, the manifest, the translation or a producer's output, which uDeck
  says the same way.

- **uDeck installs plugins from the official repository, and says what it
  connects to.** Stage 1 of [docs/plugin-repository.md](docs/plugin-repository.md):
  Settings → Plugins lists the plugins of `github.com/iillyyaa1997/udeck-plugins`,
  read anonymously from `api.github.com` and `raw.githubusercontent.com`, and
  installs one by its files at the commit it showed — each checked against its
  hash, the folder against its tree, swapped into place in one step, recorded in
  `installed.json`. Updates are shown and applied on request, earlier versions
  come from the repository's history, and removal takes the plugin's grants,
  settings, cache and windows with it. The catalogue is read at launch, then once
  a day, and **Official catalogue** turns it off; uDeck's own update checks are
  on by default as well. README and SECURITY.md no longer say that uDeck makes no
  connection unless asked: they say what it asks, where, how often and how to
  turn each off, and — plainly — that plugins have no sandbox, that a permission
  is a declaration and not a wall, and that uDeck hands plugins no secrets. The
  plugin contract gains `minUDeck`, the `MAJOR.MINOR.PATCH` grammar for
  `version`, and the rule that a plugin writes only into `UDECK_CACHE_DIR`.

  What a first review of it found, and what changed:
  - a file whose name starts with `.` — a `.env`, a working copy's `.git` — put
    into an installed plugin's folder was deleted with the old copy on Update,
    **Back to** or **Remove**, because the folder's hash skips such names and the
    copy looked untouched. A copy holding anything the hash does not see now goes
    to the Trash; only the Finder's `.DS_Store` does not count;
  - **Update** and **Switch to** on the catalogue's row replaced a copy changed on
    disk without the warning the installed plugin's row gives; both rows now say
    *"Your changes to uptime will be moved to the Trash…"* first — and so do
    **Back to**, **Install this version** under **Earlier versions…** and
    **Reinstall**, on the row and on a window whose plugin will not run. The
    warning is shown whenever something of the operator's is about to go to the
    Trash, by the one rule the installer decides the Trash by (`OperatorsWork`):
    a copy changed on disk, a folder of their own, or one holding what the hash
    does not see. A `.env` beside a plugin leaves it **Verified** and used to go
    to the Trash without a word;
  - **Reinstall** asked GitHub with **Official catalogue** off. It is not offered
    then, on the plugin's row or on a window whose plugin is missing, and uDeck
    refuses every install, update and reinstall while the switch is off;
  - a card's action could start while its plugin was being swapped or removed.
    Actions are refused while a plugin is quiet, and one already running is
    waited for as long as a poll in flight is — the plugin's `timeout` and a
    second and a half. An action has no timeout of its own, so one still
    running then is ended: it runs in a process group of its own, which gets
    `SIGTERM`, a second, and `SIGKILL`, and only when nothing of it is left is
    the folder swapped or removed. If something will not end, the operation
    stops with *"Something uptime started would not end, so its folder was left
    as it was"*, and the folder is untouched;
  - on a volume that ignores case, a folder spelt `Uptime` was offered **Install**
    rather than **Replace…**, and the swap took it anyway. Whether `plugins/<id>`
    is taken is now asked of the disk, as the swap finds it. And the swap kept
    the name `Uptime`, which discovery refuses for a plugin whose id is
    `uptime`: **Replace…** put in place a plugin that did not run, and
    **Reinstall** did it again. A folder spelt otherwise is now renamed to the
    id before the swap;
  - on a volume that cannot swap folders in one step, a failed move and a failed
    move back threw the staging folder away with the old copy in it. The old copy
    now stays there, beside its journal, and the next launch puts it back — and
    if that launch cannot either, it deleted it on the line after trying. Now
    staging and its journal stay until a launch can; if something else has taken
    `plugins/<id>` meanwhile, the old copy goes to the Trash. A copy a crash left
    in staging is deleted only when it is provably uDeck's own — it hashes to a
    tree uDeck put there and holds nothing the hash does not see — and goes to the
    Trash otherwise. It used to be deleted whenever it hashed to the download: an
    old copy of the same version with a `.env` beside it hashes the same, and a
    removal whose folder had been put back lost the copy it had moved, `.env`
    and all;
  - docs/plugin-api.md said uDeck *"hands over secrets, or does not"*; it hands
    over none, as SECURITY.md says, and now so does the contract. The consent
    sheet said a plugin would *"receive the secret "X" from uDeck"*; it now says
    the plugin asks for the secret and that uDeck does not hand out secrets yet,
    in English and Russian;
  - **Reinstall** on the catalogue's row of a plugin whose folder was missing
    did not ask the Trash rule when pressed, as every other button that replaces
    a folder does; a folder put there since the row was drawn is now replaced
    only after the warning.
  - the settings window's sections could not be chosen at all: the badge that
    counts waiting updates was put on each sidebar row after its `tag`, so the
    List found no tag and selected nothing. Measured in the lab on 2026-09-28,
    four clicks on four sections left the General pane up
    (`.build/e2e/kept/20260928-210038Z`), and every `updates` check that opens
    About could not check (`20260928-205437Z`); with the tag after the badge, a
    click on About shows About (`20260928-210526Z`).

  The lab's `updates.it-does-not-look-by-itself` is now
  `updates.it-looks-by-itself`: uDeck as it ships, with nothing pressed and no
  window opened, has to ask the lab's feed within 20 s. And
  `updates.switched-on-it-looks-by-itself` starts from a machine whose operator
  switched automatic checks off — the one preference the lab writes — and fails
  if uDeck asks before the switch is turned back on. Measured on 2026-09-28: the
  four `updates` checks green at `--jobs 2` (`.build/e2e/20260928-211113Z`), and
  `it-looks-by-itself` red against a plist with automatic checks off
  (`20260928-212410Z`).

  The lab gains the thirteen `plugins` checks of the document, against a fake
  GitHub served inside the guest (`e2e/guest/fake-github.py`) from fixture
  commits (`e2e/fixtures/plugin-repository/`) that it hashes into real git ids
  itself — held against `git` by the lab's own tests, and against uDeck's Swift
  by every install. Every lab build now reads its catalogue from that fake and
  never from github.com (`--test-plugins`), and the build step refuses one that
  would. Each check was measured red against a mutant of its own on 2026-09-29.
  What the checks found on the way:
  - **Earlier versions…** could not be driven by identifier: the identifier on
    the history's box replaced every line's own, so each version and its
    **Install this version** answered to `plugin.<id>.history`. The box is now a
    container of its own.
  - the card's **Allow and run** and **Decline** carry identifiers
    (`consent.<id>.allow`, `consent.<id>.decline`), so the lab allows a plugin
    where the operator does.

  A second review of the checks: `plugins.remove-leaves-nothing` reads the
  setting value in `plugin-settings.json` before **Remove**, so its going means
  something, and keeps the file with the evidence; `plugins.limit-is-explained`
  used to listen for ten seconds after the second **Check now** — the fake's
  limit is now two and a half minutes, the check listens until the reset, and
  after it **Check now** has to reach the API again; `plugins.earlier-version`
  puts a `.env` into the folder first, and **Install this version** has to warn
  before it goes to the Trash.

- **A click past the panel closes it however late the news of it comes.** The
  workspace saying another application came forward is often the first news of
  a click past the panel, and uDeck read it as that click only within 0.15 s of
  the button going down. In a whole lab run at `--jobs 2` it came 232 ms after
  the button, and the operator putting the panel away was read as something
  interrupting him — the next reveal brought back work he had finished with.
  There is no time in the rule now. The news is that click when the pointer is
  past the panel, the last click came after the panel showed, and uDeck has not
  heard that click itself yet. That last condition is what keeps ⌘-Tab an
  interruption after a click inside the panel held it open: that click came
  after the panel showed as well, but it is uDeck's own, and a click uDeck has
  heard has been answered already. uDeck hears its own clicks by three roads:
  its local monitor for clicks on its windows, its global monitor for everybody
  else's — the messenger that arrives late, and the one that forgives a click in
  the margin round the panel — and its own menus. Every activation is logged
  with all four readings, the switch as much as the dismissal, and with how late
  uDeck was handed the last click it heard. Measured in the guest on 2026-09-27:
  twelve clicks past a held panel, the news 5 to 148 ms after the button, all
  twelve read as closed; three switches with no click after a click inside and
  three after a click in the margin, all six read as switches, uDeck having
  been handed that click 7 to 16 ms after the system dated it.
  `panel.a-switch-with-no-click` goes red, 2 times of 2, on a uDeck that takes
  any click since the panel showed for a click past it, and on one whose own
  click monitor notes nothing.

  **A choice in one of uDeck's own menus is a click it heard.** A menu — the
  context menu of a card or a tab, a picker in the settings window — tracks the
  pointer in a loop of its own, so the click that chooses in it reaches neither
  monitor while the system counts it like any other. Measured before the fix: a
  held panel, "Rename" chosen in its tab's menu, the pointer taken past the panel
  and another application brought forward with no click — read as a click past
  the panel and the work thrown away, 3 times of 3. uDeck now counts the click a
  menu lets go on as heard, dated by that click, which is AppKit's current event
  when the menu lets go: the choosing click, carrying the timestamp the system
  gave its last click, in all four choices logged. A menu dismissed by a click
  past it lets go on something that is not a click, and that click still closes
  the panel as dismissed, 2 times of 2 before the fix and 2 of 2 after. The
  status-bar menu is not the same case: with the panel held, a click on uDeck's
  item in the menu bar is a click past the panel by both roads, and puts the
  panel away before the menu opens, 2 times of 2. New lab check:
  `panel.a-switch-after-a-choice-in-a-menu`, red 2 times of 2 on a build that
  does not hear its menus (the lab can right-click now). Whether a picker in the
  settings window lets go the same way is not measured.

  **A click is heard when its button went down, not when uDeck got round to it.**
  The local monitor was handed its click 0.5 to 117 ms after the button, and the
  global one 11 to 321 ms after, in 21 clicks logged at `--jobs 2`.
  Dated by the handing-over, a click on the panel whose monitor ran late counted
  as heard every click made before the monitor ran — a click past the panel
  among them — and its news read as a switch, under the very load the window
  was given up for. Clicks are now dated by the event's own timestamp, which is
  the uptime clock the system dates its last click by: the system's date
  brackets the event's, 15 clicks of 15, and in the 8 switches that followed a
  click uDeck had heard the system's age of it came out 1.3 to 24.8 µs older than
  uDeck's, which is what keeps a tie "heard". The global monitor also decides
  whether its click was past the panel from where the click was, not from where
  the pointer is by the time it runs; the notification cannot, and that is
  written down in docs/open-questions.md.

  **The margin now has a check of its own.** Nothing in the repository held the
  global monitor counting the click it forgives in the margin as heard: the
  controller has no Swift tests, and no lab check clicked in the margin — while
  a build without that line had taken a margin click for a click past the panel
  2 times of 2 in a probe. New lab check:
  `panel.a-switch-after-a-click-in-the-margin`, red 2 times of 2 without that
  line. And a Swift test for the plainest case: a panel nobody has clicked
  into, clicked past, is closed.

- **An arrival at the edge that a timer saw first is still an arrival.** uDeck
  asks where the pointer is on two timers, and the answer can run ahead of the
  movement it has been handed: the window server has moved the pointer and the
  report that moved it is still on its way. A timer that asked in that gap found
  the pointer on the edge, and the report that took it there was counted as a
  push made while pinned. Measured in the lab: the pointer carried into the strip
  five rows short of the edge, left there about as long as the dwell's own timer
  takes to come round, and then one report onto the edge — 20 of 120 opened by
  the push, and every one of the 20 had a timer asking 0.16 to 1.05 ms after the
  arriving report's timestamp, which none of the 100 dwells had. Only a sample
  that moved says where the pointer was before the next report now; 40 of 40
  opened by the dwell afterwards.

- **A throw that stops at the edge is not taken for a push.** Now and then macOS
  hands one movement report to uDeck twice — through its global monitor and
  through its local one — with the movement halved between the two copies, one
  timestamp on both, and both placed where the whole report left the pointer.
  When that was the report arriving at the top edge, the first copy left the
  pointer pinned and the second counted as movement made while pinned: 32.6 to
  42.4 points against a threshold of 24, and the panel opened by the push under a
  hand that had stopped. `panel.a-throw-to-the-edge` was red about one run in
  five for it. The recognizer now reads the parts of one report — samples that
  share a timestamp — against where the pointer was before the report began, so
  both copies of an arrival are the arrival, and both copies of a real push
  still count. It was not `NSEvent.mouseLocation`, which the review that found
  the failure blamed: a build that logged each event's own location beside it
  found the two the same in 39 movements of 39, both copies of every split
  included, so reading the position from the event would have changed nothing.
  36 throws of 36 have opened by the dwell since, and 16 jumps of 16 to the top
  row over VNC, which used to be read as a push 2 times in 16. With the reading
  by report taken out again the throw went to the push 3 times in 16 and the
  jump 2 times in 16 — each time exactly the report that had come in two copies,
  and never one that had not.

- **The settings checks stop turning the lab's own misses into verdicts about
  uDeck.** A click at coordinates is aimed at where the accessibility API said
  the control was a moment earlier, so a window that moved or a pane still being
  laid out left the screen exactly as it was — and nothing read it back. The
  miss travelled: the settings file held nothing, and the check said "the
  operator's change is nowhere" about a uDeck that had never been asked for one.
  `ui.press` now walks the screen again until the control at that place says the
  click landed, and a control that does not is the lab failing to press it, with
  where the click went and what was found there in the reason.

  **A group of them works on a shared machine again.** The preparation refused a
  machine that already had `~/.udeck/settings.json`, and the first of these two
  checks leaves one — so the second could not run under `--vm per-group` or
  `per-run`, which is what a group is meant to be run under. A file a
  neighbouring check left behind is now taken away before uDeck is started, with
  the install having quit the uDeck that was running, and read back to be sure
  it is gone. That is the only thing the lab does to that file: the change
  itself is still a click in uDeck's own window.

  **The file is read whole, not one key deep.** Both checks read back the one
  key they had changed, so a save that kept the operator's change and dropped
  the twelve keys around it was green — and a key a settings file does not hold
  is read back at the next launch as whatever uDeck ships, which is a setting
  silently reset. They now require every key the encoder writes to still be
  there, and a few of them to still read the shipped default.

  **And when the file is not there at all, uDeck is asked why.** It says so when
  the store refuses it — `could not save the settings: …`, written through
  `DeckLog.plugins` — and the window these checks read kept two categories and
  not three, so "could not save" and "did not save" came out as the same
  sentence about two different people's problem. The window keeps that category
  now, and the verdict quotes the line when it is there.

  Four smaller ones with them. A control the walk could not print — a `|` or a
  line break in its text — was dropped silently and came back as "the Opening
  screen did not appear", which sends the reader to SwiftUI for a pipe in a
  label; it is now the lab's failure with the line in it. The only way into
  these screens is a translated menu title, so a guest that is not in English
  now fails saying which language it answers with and which titles its menu
  offers, instead of timing out with a shrug. The row's readings say the row is
  uDeck's and the machine is at rest and can say nothing about the order within
  it — four switches that all read on read the same in any order — so the prose
  that claimed otherwise is corrected, and the unit test that does hold the
  order now counts every `Toggle` on the screen rather than only the ones its
  regex happens to read. And the shortcut check says out loud that it asks two
  of its three sentences after the restart, and why pressing the replaced
  combination a second time would cost ten seconds to witness what the file and
  the line at launch have already said.

- **The lab can check the push.** `panel.push` — the pointer pinned against the
  top edge while the device keeps pushing — reported "could not check" since it
  was written, because no software in a machine could produce the movement.
  Posting a `CGEvent` delta never could: the window server tells applications the
  movement that actually happened, which at the edge is nothing. `IOHIDPostEvent`
  can, and the reason it was written off was the experiment, not the call — it
  had been tried under `sudo`, and the privilege it asks for is
  `kIOClientPrivilegeLocalUser`, which XNU answers with `CopyConsoleUser(euid)`:
  root holds no console session, so `sudo` guaranteed the refusal. As the
  logged-in user it succeeds. The check now throws the pointer at the edge and
  pushes there in one run, reads back that the pointer really is against the
  edge — a push with nothing to push against is "could not check", not a verdict
  — and then asks uDeck which path fired. It needs no driver, no system
  extension and nothing added to the golden image.

  This also measured something uDeck had only assumed: that at an edge the
  position stops changing while the delta keeps arriving. It does.

  **The throw stops at the edge**, and that is the check rather than a detail.
  uDeck counts upward movement made while the pointer was *already* pinned, so a
  throw that runs to a count instead of to the edge is itself a push — at sixty
  points a report it clears the twenty-four-point threshold twice over, the run
  says `fired by push`, and the push the check makes never matters. An audit of
  the lab on 2026-09-19 found exactly that: the first version overshot by 180
  points and the panel opened on the throw. The script now watches the pointer
  and stops when it arrives, so the threshold is left to the push. Measured
  after: twelve reports to reach the edge from the middle of the screen, nothing
  past it, and `fired by push`.

- **The login checks ask about the row they switched on, not whichever uDeck row is
  enabled.** More than one record can carry uDeck's identifier — another copy, a leftover
  — and `record_for` answered with whichever was enabled. Most of what that let through
  had already been closed by comparing the path and the row's UUID, which is worth
  saying: the audit's two named cases were red before this change. What was left was
  worse for being quieter. With uDeck's own row correctly switched off and another copy's
  row enabled beside it, the control read the other copy's and pronounced that uDeck had
  not switched off, when it had.

  After switching on, every check now looks its row up by that row's UUID. A replaced row
  arrives as no row, and says so, rather than being answered for by whatever stands in
  its place. Another copy set to open at login is named for what it is: in the control it
  is "could not check", because a machine where another copy opens at login cannot show
  this one's switch working either way, and after a restart it is named as what opened.
  A dump that prints no UUIDs still answers the old way, since no two rows can then be
  told apart.

- **`updates.sparkle` watches the uDeck that came back, instead of glancing at it.** It
  waited for a new pid after the install and returned the moment one appeared — the right
  thing for waiting, the wrong thing for judging, because an update that installed a uDeck
  which crashes on launch shows a new pid for exactly as long as the crash takes. The new
  process is now watched for ten seconds and has to be there every time it is asked, and
  the old one has to be gone: Sparkle replaces the copy that is running, so an old
  process still beside the new is an update that replaced nothing, whatever the version
  on disk says.

- **A lab that could not look stops counting as uDeck having done nothing.** Two places
  where the three outcomes broke in the direction nobody watches: an unreadable log and
  a dead feed came out as ❌ about uDeck.

  `GestureLog` is now two calls with two jobs. `read` is the oracle and raises — every
  panel verdict is a statement about what uDeck said, and an empty answer satisfies "it
  opened nothing" exactly as a real silence would, so a log that could not be read looked
  precisely like a panel that never opened. It also checks `log show`'s own exit code,
  which `ask` lets through by design: a predicate it will not parse handed back nothing
  at all, with nothing said about why. `collect` stays what it was — evidence for the
  report, and for the sentence a failing check quotes, deciding nothing.

  And `updates.sparkle` asks whether the feed still answers before it says uDeck did not
  find an update. The guest's server is a process the lab left running in a machine it is
  also driving; one that has since died gives uDeck nothing whatever to find, and the
  pane then says the check did not finish — quite correctly, about the lab.

- **`updates.wrong-key` has to see the archive served before it calls anything a
  refusal.** The control took two witnesses that uDeck had reached the signature, and
  the second was the pane saying "The check did not finish" — which uDeck prints for
  any trouble its updater runs into, including never having got as far as the archive.
  With that accepted, the control could pass having offered nothing, pressed nothing and
  downloaded nothing: the exact shape of a control that proves nothing, in the check
  written to be the one that proves something.

  Now the guest's own access log answering 200 for the archive is the only witness —
  Sparkle checks the signature after downloading, so an archive served is a signature
  that was checked and rejected. The pane's words stay in the report and decide nothing.
  An update uDeck was never offered is "could not check", because the appcast is served
  unsigned and the key is checked on download, so a missing offer is about the feed, the
  window or the click. And the control now asks whether uDeck is still there: refusing
  an update is something an application does while carrying on being itself, and "the
  version on disk did not change" is equally true of one that fell over on the press.

- **`login.survives-a-restart` proves the record opened uDeck, and says when it did
  not.** It demanded the generation stand still across the restart, from a measurement on
  2026-09-19 — 1 before, 1 after. Every one of those runs had left uDeck running across
  the restart, so the record was never what opened it, and the assertion had written the
  wrong reason for the check being green into the check. With uDeck quit and the machine
  left alone first, six restarts in six rewrote the record exactly once: 1 before, 2
  after, the same row, nothing reopened by macOS.

  So the generation is now the witness for who brought uDeck back. Unchanged: the record
  was not acted on, whatever opened uDeck was not it, and the run is "could not check".
  One more: the record opened it, which is what the check is for. More than that: uDeck
  registered itself again, which it must not, and that is still a failure.

- **And then leave the machine alone for half a minute, because quitting is not enough.**
  Measured across forty runs of the control, every one with a polite quit that took under
  a fifth of a second: three reopens in ten with no wait, and none in ten at each of
  twenty, forty-five and ninety seconds. Two explanations were measured and are wrong —
  the `pkill` fallback in `quit_app` never fires, and the record usually never leaves the
  database at all (still there after ninety seconds, eight times in ten), so what the
  ninety seconds first bought was the right answer for the wrong reason. What is left is
  the time itself. The wait is thirty seconds, which is where it was measured clean plus
  half again, and the checks still read the guest's log afterwards — a reopen that gets
  through the wait is reported rather than believed.

- **The restart checks quit uDeck first, so that only the login record can bring it
  back.** `login.off-stays-off` failed about one run in six with the record reading
  exactly what it should — `[disabled]`, the same row, the generation the switch-off
  left — and uDeck running anyway. Two days of it were spent on the database, and the
  database was never the cause. A machine caught red on 2026-09-20 said so in one line:

      loginwindow [com.apple.loginwindow.logging:TAL]
        -[PersistentAppsSupport persistentAppPreLaunch] | bundleID:place.unicorns.udeck

  macOS reopens what was running when the session ended, and both restart checks
  restarted the guest with uDeck on screen. So the control was blaming uDeck for the
  system putting back a window, and — the part that matters more —
  `login.survives-a-restart` had a second reason to be green that has nothing to do
  with the login record, on a feature whose whole point is the record.

  Both now quit uDeck before the restart, which rules it out by construction, and then
  read the guest's log to say so: a run macOS reopened into is "could not check", not a
  verdict, because it isolated nothing. "It should not happen" is what let this stand
  for two days, so it is asserted rather than assumed.

- **A control whose premise did not hold says so, instead of blaming uDeck.**
  `login.off-stays-off` fails intermittently in one of two ways, and one of them is the
  system rather than uDeck: the restart comes back with the record enabled at the
  generation it had *before* the switch — the database as it stood on disk, not uDeck
  registering again. The check already told them apart and already said which was which,
  and then reported both as ❌, blaming uDeck in the same sentence that explained uDeck was
  not the cause. That reading is now "could not check": the boot acted on a database that
  predates the switching off, so the control never got to check anything. A record at a
  later generation, or one that cannot be read, is still uDeck's to answer for.

  Seen twice on 2026-09-19 in fifteen runs, with two different signatures — this one, and
  another the check's own test does not cover, where the record after the restart is
  correctly disabled and uDeck is running anyway. The second has no explanation yet.

- **The login checks read the record they were given, not one that looks like it.**
  `login.survives-a-restart` asked only whether *an* enabled record for uDeck existed
  afterwards — not whether it named the copy that had been switched on, and not whether it
  was the same row. Both are what the feature exists to survive: another copy of uDeck with
  the same bundle identifier takes the record simply by running, which uDeck's own source
  calls the main failure, and a row can be replaced while naming the same path.
  `login.survives-an-update` had promised in its own words to catch an application racking
  up generations, and compared nothing.

  Both now compare against the record `_switch_on` returned, and the two checks want
  different things because the system does different things — measured in a guest rather
  than assumed. A restart rewrites nothing: the generation is 1 before and 1 after, so a
  later one is something having registered again. An update rewrites the record exactly
  once, 1 to 2, with the row's UUID unchanged — macOS re-filing it because the bundle at
  the path was replaced — so anything beyond that is uDeck registering itself on top.
  Asserting equality in both, which is the obvious move, would have turned a passing check
  red.

  The row's UUID is parsed for the first time, and it is what "the same record" means. A
  dump that stops printing it costs that one sentence rather than every run.

- **The panel checks ask whether the panel opened.** All three judged by `fired
  by <path>`, which uDeck writes three lines before it asks the panel to appear —
  so a panel that failed to open for everybody left every one of them green. They
  now also require the phase uDeck records from inside the change
  (`collapsed -> peek on revealRequested`), and the control requires its absence:
  a panel shown in the middle of the screen by anything at all is exactly as
  wrong, and the gesture line would never have mentioned it. The window server
  was measured as the stricter oracle and cannot be one: uDeck keeps a single
  window at the status-bar level from launch, and after the first reveal its
  shape does not go back.

## [0.5.0] — 2026-09-19

uDeck opens when you log in, if you ask it to. The setting exists because of a
measured absence: it was installed on 13 September, launched once by hand, and
after the Mac restarted nothing brought it back — for five days, until somebody
noticed it was not running. Around it, an end-to-end lab that checks this sort
of thing inside throwaway virtual machines instead of taking over the screen of
whoever is working.

- **"Open at Login".** A card in General with the switch, the path of the copy
  that would open, and — only when the system disagrees — what it says instead,
  naming the other copy of uDeck on the Mac when there is one. uDeck keeps **no
  copy of the setting**: the switch is a reading taken from the system each time
  there is a reason to take one (the pane appearing, uDeck being activated
  again, the window coming forward), because an application that remembers "the
  operator turned it on" shows a switch that is on while the system has nothing
  recorded. It registers only when asked, never at launch — registering at
  launch silently puts back a row the operator removed and makes macOS post
  "Login Item Added" at every login.

  What it says is kept honest about its own limits, measured in a machine: the
  system will not tell an application which copy holds the record, so a copy
  that exists is named as an explanation and never as proof; "the record went
  away" can only be said by an application that watched it go, because a record
  that was never there and one that was taken away arrive as the same answer;
  and the sentence under the switch follows the state — "Opens:" when it does,
  "Would open:" when it does not. A copy that is not an installed application —
  the bare binary a development build leaves behind, which carries the release
  bundle identifier — cannot register at all, and says so before it is clicked.

- **Four checks in a virtual machine prove it**, against the system's own
  Background Task Management database rather than uDeck's opinion of itself:
  switching it on puts a record there pointing at this copy, a machine that
  restarts comes back with uDeck running, a machine where it was switched off
  again comes back without it — the control, switched *on* first on purpose —
  and the record survives uDeck updating itself. Three oracles were wrong before
  one was right: System Events' "login items" is a different list from the one
  macOS acts on, `sfltool dumpbtm` answers without privileges only on a Mac
  whose shell has Full Disk Access, and the database files an application under
  `2.<bundle id>`.

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
- **`--out`, `--version`, `--build` and `--zip`** in `Scripts/make-app.sh`, for
  the builds the lab tests updates with: somewhere other than `dist/`, a version
  of the caller's choosing in both keys — including `CFBundleVersion`, the one
  Sparkle compares — and the bundle left only as a zip. A lab build carries the
  release's identifier, so an unpacked copy could take the release's login item
  by being launched; it is unpacked inside a test machine and nowhere else. The
  bundle is removed however the script ends — a failed signature, a full disk, a
  signal — and `--zip` refuses to work without `--out`, so it can never empty
  `dist/`.
- **The settings window can be driven without reading its titles.** The sidebar
  sections and the update controls carry accessibility identifiers. The update
  buttons used to reach accessibility with no name at all — System Events read
  them as "button" and they could only be pressed by screen position — and every
  title is translated, so anything scripting the window broke on a language
  change.
- **The gesture says which path opened the panel.** The debug log line is now
  `fired by push on …` or `fired by dwell on …`. The two paths answer different
  input — a dwell only needs the pointer to stay in the strip, a push needs
  upward movement against the edge — and a test that drives the pointer by
  absolute position can open the panel by dwelling alone, so "it opened" is not
  evidence that the push works.

- **An end-to-end lab.** `e2e/run.sh` runs the checks that need a real login
  session inside throwaway macOS virtual machines, so they no longer have to take
  over the screen of whoever is working: a machine per check by default, cloned
  from a golden image, driven over SSH and through its own screen and pointer,
  and put back afterwards whatever happens — including on Ctrl-C. It reports
  three outcomes, not two, because "the lab could not tell" is not "uDeck is
  fine". The first checks are the update, with its wrong-key control, and the
  panel's dwell, with the pointer-in-the-middle control. (The push, the gesture's
  other path, cannot be produced inside a virtual machine — a posted delta is not
  what applications are told, and against the edge the movement is nothing — so
  that check reports "could not check" rather than passing on the dwell.) Not in CI:
  hosted runners have no nested virtualisation. See
  [`e2e/README.md`](e2e/README.md).

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
