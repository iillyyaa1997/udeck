"""Plugins from a repository: the catalogue, installing, updating, removing — and saying no.

Sixteen checks, one per row of the table in docs/plugin-repository.md ("The
lab's checks"), and all of them against the same two things: a release build of
this checkout, and a fake GitHub served inside the guest
(`plugin_repository.FakeGitHub`, `e2e/guest/fake-github.py`) whose content is
the fixture commits in `e2e/fixtures/plugin-repository/` — `c1` with `uptime`
1.0.0 and three plugins uDeck must refuse, `c2` the same with `uptime` 1.1.0.
The lab never talks to github.com; every lab build is pointed at the fake, and
the build step refuses one that is not (`builds.Builder._verify`).

**Three oracles, and none of them is what uDeck says about itself.** The fake's
access log is the traffic: what uDeck asked for, and what it did not — a check
about "only this plugin's files" or "no request for two minutes" is a sentence
about that log. The guest's `~/.udeck` is what uDeck did to the disk: the
folder, hashed as git would (by the fake's code, in the guest, against the id
the fake gave the fixture — so Python and uDeck's Swift have to agree),
`installed.json`, `layout.json`, `grants.json`. And the screens — Settings →
Plugins and the panel's card — are read through the accessibility API by the
identifiers uDeck gives every control there, and pressed with the machine's
pointer where the API says they are (`ui`), the way the operator presses them.

**What the lab does by hand, and why each is not a shortcut through uDeck.**
Placing a plugin on a tab is writing `layout.json` while uDeck is not running:
the table asks what uDeck does with a window it has, not how a window is made,
and the tab is empty but for it. The consent is given where the operator gives
it, on the card in the panel. A file changed on disk, and a manifest broken and
mended, are changed over SSH, because that is what "changed on disk" means.
Nothing else is written into the guest: every install, update, removal and
switch is a click.
"""

import json
import shlex
import uuid

from udeck_e2e import app, config, panel, plugin_repository, ui, updates
from udeck_e2e.errors import CheckFailed, LabError, NotThere, expect
from udeck_e2e.plugin_repository import FakeGitHub, described

VERSION = ("0.4.1", "6")

UPTIME = "uptime"
FUTURE_API = "future-api"
FUTURE_UDECK = "future-udeck"
LINKED = "linked"
FIXTURE_PLUGINS = (FUTURE_API, FUTURE_UDECK, LINKED, UPTIME)

UDECK_HOME = "~/.udeck"
INSTALLED = f"{UDECK_HOME}/installed.json"
LAYOUT = f"{UDECK_HOME}/layout.json"
GRANTS = f"{UDECK_HOME}/grants.json"
PLUGIN_SETTINGS = f"{UDECK_HOME}/plugin-settings.json"
SETTINGS = f"{UDECK_HOME}/settings.json"

# The spec's own number: on a fresh guest the catalogue is read "within a minute".
# uDeck waits `CatalogueSchedule.launchDelay`, 5 s, after the panel is ready.
CATALOGUE_SECONDS = 60

# From a press to the thing it does being on disk. An install is a handful of
# small files from the guest's own loopback; a minute is room for a busy guest.
OPERATION_SECONDS = 60

# From the plugin being allowed to its card saying so: the first run starts at
# once and is given `timeout` 2 s by the fixture's manifest.
CARD_SECONDS = 30

# "Within seconds", for a file changed on disk: the folder watcher, a re-read and
# a re-hash. Fifteen is several times what that takes.
NOTICED_SECONDS = 15

# How long uDeck with the catalogue switched off is listened to (the table's own
# two minutes).
SILENCE_SECONDS = 120

# How far ahead the fake says the limit resets. The table asks for "no API
# request before the reset", so the check listens until then: short enough to
# listen to whole, long enough for a Check now, an install and a second Check
# now to happen inside it on a busy guest.
LIMIT_SECONDS = 150

# What the rows say, in the guest's English (Q43): English.swift.
AVAILABLE_1_1_0 = "1.1.0 available"
VERIFIED = "Verified"
MODIFIED = "Modified locally"
LIMIT_USED_UP = "they are used up"
TRASH_WARNING = "Your changes to {id} will be moved to the Trash"
REMOVE_TO_THE_TRASH = "Its folder is moved to the Trash"

# What the fixture's card action writes, in the guest (e2e/fixtures/plugin-repository/*/plugins/uptime/hold.sh).
HOLD_LOG = "/tmp/udeck-e2e-hold.log"
ARRIVED_DIFFERENT = "arrived different from what the repository lists"

# What the fixture's card says, row by row (e2e/fixtures/plugin-repository/*/plugins/uptime/uptime.sh).
RUNS = "runs since install"
VERSION_ROW = "version"

# A linked folder: a plugin of the lab's own, in a working copy outside ~/.udeck,
# linked into the plugins folder (plugins.linked-folder). Its card says the same
# two rows as the fixture's, so that it is read the same way.
LINKED_CARD = "linked-card"
WORK = "~/udeck-e2e-work"

# The working copy written into while the panel is open, as an editor or a build
# writes into one: a file touched every TOUCH_EVERY seconds, TOUCHES times, with
# the plugin polled every TOUCHED_INTERVAL seconds — longer than the touches are
# apart. Each touch reads the plugins folder again; a uDeck that starts every
# interval over on each read runs it not once meanwhile, and one that leaves an
# unchanged plugin's interval alone runs it about every TOUCHED_INTERVAL seconds:
# four times in the 21 s, and at least MINIMUM_RUNS_WHILE_TOUCHED on a busy guest.
TOUCHES = 7
TOUCH_EVERY = 3
TOUCHED_INTERVAL = 5
MINIMUM_RUNS_WHILE_TOUCHED = 3


# --- The checks -------------------------------------------------------------------------


def check_catalogue_on_first_launch(machine, check_dir, lab):
    """On a fresh guest, with nothing pressed, uDeck reads the catalogue within a minute — and only the catalogue.

    The oracle is the fake's log. Within `CATALOGUE_SECONDS` of the launch it has
    to hold the passport and every fixture plugin's `manifest.json`, fetched from
    the raw host by commit, and nothing else from the raw host: no other file of
    any plugin, because building the catalogue downloads no plugin. Nothing is
    opened or pressed until that is judged. Then Settings → Plugins has to list
    all four fixture plugins, which is the same reading seen from the operator's
    side.

    **Red for**: a uDeck that ships with the catalogue off, or does not read it by
    itself at launch (the log stays empty for a minute), and one that fetches
    more than the manifests to build it.
    """
    scene = _prepare(machine, check_dir, lab, main="c1")
    try:
        heard = _the_catalogue_read(scene, since=0, commit="c1")
        raw = [request for request in heard if request.is_raw]
        wanted = _catalogue_files(scene, "c1")
        extra = [request for request in raw if request.raw_file() is None or request.raw_file()[1] not in wanted]
        expect(
            not extra,
            f"building the catalogue, uDeck also fetched {described(extra)} — no plugin is downloaded to build "
            "a catalogue, only the passport and the manifests",
        )
        wrong_commit = [r for r in raw if r.raw_file() and r.raw_file()[0] != scene.github.commit("c1")]
        expect(not wrong_commit, f"uDeck fetched files by something other than the listed commit: {described(wrong_commit)}")
        lab.note(f"   uDeck read the catalogue by itself: {described(heard)}")

        ui.plugins_pane(machine, "opening Settings → Plugins")
        dump = _keep_the_pane(machine, check_dir, lab, "plugins-pane.txt")
        listed = [plugin for plugin in FIXTURE_PLUGINS if _row_of(dump, plugin)]
        expect(
            listed == list(FIXTURE_PLUGINS),
            f"Settings → Plugins lists {listed} of the fixture's {list(FIXTURE_PLUGINS)}: a plugin that silently "
            "does not appear is a support question, and one that cannot be installed is still shown with its reason",
        )
    finally:
        scene.close()


def check_install_fetches_one_folder(machine, check_dir, lab):
    """**Install** fetches that plugin's files at the listed commit and nothing else, and records where it came from.

    Judged three ways. The log, from the click on: only raw requests, each under
    `plugins/uptime/` at the commit the catalogue was built from, every file of
    the folder once, and no API request at all — the listing is already cached.
    The disk: the folder in the guest hashes to the fixture's tree, and
    `installed.json` holds every field docs/plugin-repository.md lists, with the
    values this install has to give them. The screen: the installed row says
    **Verified**.

    **Red for**: an installer that fetches anything outside the plugin's folder,
    or asks the API during an install.
    """
    scene = _prepare(machine, check_dir, lab, main="c1")
    try:
        _the_catalogue_read(scene, since=0, commit="c1")
        record, asked = _install(scene, UPTIME)
        commit = scene.github.commit("c1")
        api = [request for request in asked if request.is_api]
        expect(not api, f"installing {UPTIME} asked the API {described(api)}; the listing was already cached, so none was needed")
        files = scene.github.files("c1", f"plugins/{UPTIME}")
        fetched = [request.raw_file() for request in asked if request.is_raw]
        outside = [f for f in fetched if f is None or f[0] != commit or f[1] not in files]
        expect(
            not outside,
            f"installing {UPTIME} fetched {outside}, which is not a file of plugins/{UPTIME} at {commit[:7]}: "
            f"uDeck downloads exactly that plugin's files at that commit",
        )
        missing = sorted(set(files) - {f[1] for f in fetched if f})
        expect(not missing, f"installing {UPTIME} never fetched {missing}, and yet an install says it is complete")

        tree = scene.github.tree_in_guest(f"{UDECK_HOME}/plugins/{UPTIME}", "hashing the installed folder")
        wanted_tree = scene.github.tree("c1", f"plugins/{UPTIME}")
        expect(
            tree == wanted_tree,
            f"the folder uDeck installed hashes to {tree}, and the fixture's plugins/{UPTIME} is {wanted_tree}",
        )
        _expect_a_whole_record(record, commit=commit, tree=wanted_tree, version="1.0.0", pinned=False, previous=None)

        mark = _wait_until(machine, f"plugin.{UPTIME}.mark", lambda said: said and VERIFIED in said, NOTICED_SECONDS)
        _keep_the_pane(machine, check_dir, lab, "after-the-install.txt")
        expect(mark is not None and VERIFIED in mark, f"the installed row's mark says {mark!r}, not {VERIFIED!r}")
    finally:
        scene.close()


def check_card_reaches_the_panel(machine, check_dir, lab):
    """Placed on an empty tab and allowed, `uptime`'s card appears and says it has run once.

    The whole path from a repository to a card: installed with a click, placed
    (`layout.json`, written while uDeck is not running), allowed where the
    operator allows it — the card's own consent, in the panel — and then read out
    of the panel's accessibility tree. The count is the fixture's own: it lives in
    `UDECK_CACHE_DIR` and says how many times the producer ran.

    **Red for**: a producer that is not handed its `UDECK_CACHE_DIR` — measured
    on 2026-09-29 with that variable renamed in `PollExecutor`: the card said
    `runs since install: unknown` and the check failed on it. An install that
    drops the executable bit is red here too, but earlier and for a better
    reason: the installer's own tree check refuses the folder ("The files of
    uptime do not add up…"), measured the same day.
    """
    scene = _prepare(machine, check_dir, lab, main="c1")
    try:
        _the_catalogue_read(scene, since=0, commit="c1")
        _install(scene, UPTIME)
        _place(scene, UPTIME)
        card = _allow_and_read_the_card(scene, UPTIME, "placed on an empty tab")
        expect(card.get(RUNS) == "1", f"{UPTIME}'s card says it has run {card.get(RUNS)!r} times, not once: {card}")
        expect(card.get(VERSION_ROW) == "1.0.0", f"{UPTIME}'s card is not 1.0.0's: {card}")
    finally:
        scene.close()


def check_update_keeps_the_window(machine, check_dir, lab):
    """With `main` moved to c2, **Check now** offers 1.1.0, and **Update** keeps the window where it was.

    After the update, `layout.json` has the same window — the same id, on the same
    tab, in the same place — the card shows 1.1.0's output after the new consent
    (a new version asks again), and the record's `previous` holds 1.0.0.

    **Red for**: an update that takes the window with it, and one that forgets
    what it replaced.
    """
    scene = _prepare(machine, check_dir, lab, main="c1")
    try:
        _the_catalogue_read(scene, since=0, commit="c1")
        _install(scene, UPTIME)
        _place(scene, UPTIME)
        _allow_and_read_the_card(scene, UPTIME, "before the update")
        before = _the_window(machine, UPTIME, "reading the window before the update")

        scene.github.tell("moving main to c2", main="c2")
        ui.plugins_pane(machine, "opening Settings → Plugins")
        _press(machine, "catalogue.checkNow", "pressing Check now")
        offer = _wait_until(machine, f"plugin.{UPTIME}.offer", lambda said: said == AVAILABLE_1_1_0, OPERATION_SECONDS)
        _keep_the_pane(machine, check_dir, lab, "the-update-offered.txt")
        expect(offer == AVAILABLE_1_1_0, f"after Check now, with main at c2, {UPTIME}'s row says {offer!r} and not {AVAILABLE_1_1_0!r}")

        record = _operate(scene, f"plugin.{UPTIME}.update", "updating uptime", lambda r: r and r.get("version") == "1.1.0")
        expect(record is not None and record.get("version") == "1.1.0", f"after Update, installed.json says {record!r}")
        previous = record.get("previous") or {}
        expect(
            previous.get("version") == "1.0.0" and previous.get("commit") == scene.github.commit("c1"),
            f"after the update, the record's previous is {previous!r}, not 1.0.0 at c1: Back to 1.0.0 would have nothing to go back to",
        )
        after = _the_window(machine, UPTIME, "reading the window after the update")
        expect(
            after == before,
            f"the update moved or replaced {UPTIME}'s window: before it was {before}, after it is {after}",
        )
        card = _allow_and_read_the_card(scene, UPTIME, "after the update")
        expect(card.get(VERSION_ROW) == "1.1.0", f"after the update the card is not 1.1.0's: {card}")
    finally:
        scene.close()


def check_earlier_version(machine, check_dir, lab):
    """**Earlier versions…** lists 1.1.0 and 1.0.0; choosing 1.0.0 installs it, pinned, still offered 1.1.0.

    `main` is at c2 from the start, so **Install** puts 1.1.0 in place and the
    history — the commits that changed `plugins/uptime`, read from the fake — has
    two versions in it.

    Before 1.0.0 is chosen, a `.env` is put into the installed folder over SSH, as
    an operator keeps a token beside a plugin. The folder's hash does not see it,
    so the row still says **Verified** — and the copy still goes to the Trash with
    it, so **Install this version** has to say so first (Q118), and the `.env` has
    to be in the guest's Trash afterwards, not gone.

    **Red for**: an earlier version installed without being pinned, a history
    that is not read from the repository, and a replacement that sends the
    operator's file to the Trash without a word.
    """
    scene = _prepare(machine, check_dir, lab, main="c2")
    try:
        _the_catalogue_read(scene, since=0, commit="c2")
        record, _ = _install(scene, UPTIME)
        expect(record.get("version") == "1.1.0", f"Install with main at c2 put {record.get('version')!r} in place, not 1.1.0")

        before = _count(scene)
        _press(machine, f"plugin.{UPTIME}.earlier", "opening Earlier versions…")
        lines = {}
        for version in ("1.1.0", "1.0.0"):
            lines[version] = _wait_until(machine, f"plugin.{UPTIME}.history.{version}", lambda said: bool(said), OPERATION_SECONDS)
        _keep_the_pane(machine, check_dir, lab, "earlier-versions.txt")
        expect(all(lines.values()), f"Earlier versions… lists {lines}; the history has 1.1.0 and 1.0.0")
        history = [r for r in _since(scene, before, "reading the fake's log")
                   if r.is_api and r.path.endswith("/commits") and "path=plugins%2Fuptime" in r.query.replace("/", "%2F")]
        expect(history, "Earlier versions… listed versions without asking the repository for the folder's history")

        token = _keep_a_dot_env(machine, "before choosing 1.0.0")
        _press(machine, f"plugin.{UPTIME}.history.1.0.0.install", "choosing 1.0.0")
        warning = _wait_until(machine, f"plugin.{UPTIME}.history.confirmText", lambda said: bool(said), NOTICED_SECONDS)
        _keep_the_pane(machine, check_dir, lab, "the-warning.txt")
        expect(
            warning is not None and TRASH_WARNING.format(id=UPTIME) in warning and "1.0.0" in warning,
            f"with a .env in {UPTIME}'s folder, Install this version said {warning!r} before replacing it; it has to "
            f"say {TRASH_WARNING.format(id=UPTIME)!r}… and name 1.0.0",
        )
        record = _operate(scene, f"plugin.{UPTIME}.history.confirm", "confirming 1.0.0",
                          lambda r: r and r.get("version") == "1.0.0")  # fmt: skip
        expect(record is not None and record.get("version") == "1.0.0", f"after choosing 1.0.0, installed.json says {record!r}")
        expect(record.get("commit") == scene.github.commit("c1"), f"1.0.0 was installed from {record.get('commit')}, not c1")
        expect(record.get("pinned") is True, f"1.0.0 chosen from the history is not pinned: {record!r}")
        offer = _wait_until(machine, f"plugin.{UPTIME}.offer", lambda said: said == AVAILABLE_1_1_0, NOTICED_SECONDS)
        _keep_the_pane(machine, check_dir, lab, "after-the-earlier-version.txt")
        expect(offer == AVAILABLE_1_1_0, f"pinned at 1.0.0, the row says {offer!r} and not {AVAILABLE_1_1_0!r}")
        _expect_it_in_the_trash(machine, token, "1.0.0 replaced it")
    finally:
        scene.close()


def check_remove_leaves_nothing(machine, check_dir, lab):
    """After **Remove**, nothing of the plugin is left; installed again, it asks again and counts from one.

    The folder, `cache/uptime`, its entries in `grants.json`, `plugin-settings.json`
    and `installed.json`, and its window. The plugin's setting value is the one
    thing the lab puts there itself — `uptime` declares no setting the panel can
    change — and it is put there while uDeck is not running, so that the removal
    has something in that file to take away. Each of the three is read before
    **Remove** is pressed: an entry that was never there proves nothing about
    the removal. Then the plugin is installed and placed again: the card asks
    for consent again, and says it has run once.

    **Red for**: a removal that leaves the cache behind (the count goes on from
    where it was), the grant (the card runs without asking), or the setting value
    (`PluginSettings.forget` doing nothing).
    """
    scene = _prepare(machine, check_dir, lab, main="c1")
    try:
        _the_catalogue_read(scene, since=0, commit="c1")
        _install(scene, UPTIME)
        _place(scene, UPTIME, setting_value=True)
        _allow_and_read_the_card(scene, UPTIME, "before the removal")
        for path, what in ((f"{UDECK_HOME}/cache/{UPTIME}", "its cache"),):
            if not _exists(machine, path):
                raise LabError("before the removal", f"{UPTIME} ran and there is no {path} ({what}) to remove")
        if UPTIME not in ((_read_json(machine, GRANTS) or {}).get("byPlugin") or {}):
            raise LabError("before the removal", f"{UPTIME} was allowed and {GRANTS} has no decision for it")
        # The lab wrote it and uDeck has run since, and saves this file whenever
        # a setting changes: it has to be there still for its going to mean anything.
        kept = ((_read_json(machine, PLUGIN_SETTINGS) or {}).get("values") or {}).get(UPTIME)
        if not kept:
            raise LabError("before the removal", f"the lab left a setting value for {UPTIME} and {PLUGIN_SETTINGS} has none: {kept!r}")

        ui.plugins_pane(machine, "opening Settings → Plugins")
        _press(machine, f"plugin.{UPTIME}.remove", "pressing Remove")
        _press(machine, f"plugin.{UPTIME}.confirm", "confirming the removal")
        gone = _wait_for_disk(machine, lambda: not _exists(machine, f"{UDECK_HOME}/plugins/{UPTIME}"), OPERATION_SECONDS)
        _keep_the_pane(machine, check_dir, lab, "after-the-removal.txt")
        expect(gone, f"after Remove, ~/.udeck/plugins/{UPTIME} is still there")
        left = []
        if _exists(machine, f"{UDECK_HOME}/cache/{UPTIME}"):
            left.append(f"cache/{UPTIME}")
        for path, key in ((GRANTS, "byPlugin"), (PLUGIN_SETTINGS, "values"), (INSTALLED, "plugins")):
            if UPTIME in ((_read_json(machine, path) or {}).get(key) or {}):
                left.append(f"{path} {key}[{UPTIME}]")
        if UPTIME in ((_read_json(machine, PLUGIN_SETTINGS) or {}).get("disabled") or []):
            left.append(f"{PLUGIN_SETTINGS} disabled")
        if _windows_of(_read_json(machine, LAYOUT), UPTIME):
            left.append("a window in layout.json")
        expect(not left, f"after Remove, {UPTIME} left {', '.join(left)} behind")

        _press(machine, f"catalogue.{UPTIME}.install", "installing it again")
        _wait_for_disk(machine, lambda: _exists(machine, f"{UDECK_HOME}/plugins/{UPTIME}/manifest.json"), OPERATION_SECONDS)
        _place(scene, UPTIME)
        card = _allow_and_read_the_card(scene, UPTIME, "installed again")
        expect(card.get(RUNS) == "1", f"installed again, {UPTIME}'s card says it has run {card.get(RUNS)!r} times, not once: {card}")
    finally:
        scene.close()


def check_refuses_what_it_cannot_run(machine, check_dir, lab):
    """`api: 2` and `minUDeck: 99.0.0` are listed with their reasons and no **Install**, and nothing but the manifest is fetched.

    **Red for**: a catalogue that offers either to be installed, and one that
    downloads more of a plugin it will not install than the manifest it read to
    say so.
    """
    scene = _prepare(machine, check_dir, lab, main="c1")
    try:
        heard = _the_catalogue_read(scene, since=0, commit="c1")
        ui.plugins_pane(machine, "opening Settings → Plugins")
        dump = _keep_the_pane(machine, check_dir, lab, "plugins-pane.txt")
        for plugin, reason in (
            (FUTURE_API, "is written for plugin contract api 2; this uDeck speaks api 1"),
            (FUTURE_UDECK, f"needs uDeck 99.0.0 or later; this is uDeck {VERSION[0]}"),
        ):
            said = ui.says(ui.element(dump, f"catalogue.{plugin}.state"))
            expect(reason in said, f"{plugin}'s row says {said!r}; it has to say why it cannot be installed: '…{reason}…'")
            expect(
                ui.element(dump, f"catalogue.{plugin}.install") is None,
                f"{plugin} is offered Install although it cannot run here",
            )
        # The whole run so far: nothing of theirs but the manifest, ever.
        everything = plugin_repository.uDecks(scene.github.read_log("reading the fake's log"))
        for plugin in (FUTURE_API, FUTURE_UDECK):
            theirs = [r for r in everything if r.raw_file() and r.raw_file()[1].startswith(f"plugins/{plugin}/")]
            beyond = [r for r in theirs if r.raw_file()[1] != f"plugins/{plugin}/manifest.json"]
            expect(not beyond, f"uDeck fetched {described(beyond)} of {plugin}, which it cannot run")
        lab.note(f"   uDeck read the catalogue: {described(heard)}")
    finally:
        scene.close()


def check_refuses_changed_files(machine, check_dir, lab):
    """With one file altered on the way, **Install** is refused with the "arrived different" message and leaves nothing.

    The fake answers `plugins/uptime/uptime.sh` with a line more than the listing
    says. The row has to say so; there is no `plugins/uptime` afterwards, and
    nothing in `staging/`.

    **Red for**: an installer that does not check each file against its blob id.
    """
    scene = _prepare(machine, check_dir, lab, main="c1", alter=[f"plugins/{UPTIME}/uptime.sh"])
    try:
        _the_catalogue_read(scene, since=0, commit="c1")
        ui.plugins_pane(machine, "opening Settings → Plugins")
        _press(machine, f"catalogue.{UPTIME}.install", f"installing {UPTIME}")
        problem = _wait_until(
            machine, f"catalogue.{UPTIME}.problem", lambda said: said and ARRIVED_DIFFERENT in said, OPERATION_SECONDS
        )
        dump = _keep_the_pane(machine, check_dir, lab, "after-the-refusal.txt")
        if problem is None:
            problem = " | ".join(ui.says(row) for row in ui.controls(dump) if row.identifier.startswith(f"catalogue.{UPTIME}"))
        expect(
            ARRIVED_DIFFERENT in (problem or "") and f"plugins/{UPTIME}/uptime.sh" in (problem or ""),
            f"with plugins/{UPTIME}/uptime.sh altered on the way, the row says {problem!r}; it has to say the file "
            f"arrived different from what the repository lists",
        )
        expect(not _exists(machine, f"{UDECK_HOME}/plugins/{UPTIME}"), f"a refused install left ~/.udeck/plugins/{UPTIME}")
        staged = machine.ssh.ask(f"ls -A {UDECK_HOME}/staging 2>/dev/null || true", "looking in staging/").stdout.split()
        expect(not staged, f"a refused install left {staged} in ~/.udeck/staging")
    finally:
        scene.close()


def check_refuses_a_link(machine, check_dir, lab):
    """A plugin whose listing has a symbolic link is listed as not installable, naming the path.

    **Red for**: a catalogue that offers it.
    """
    scene = _prepare(machine, check_dir, lab, main="c1")
    try:
        _the_catalogue_read(scene, since=0, commit="c1")
        ui.plugins_pane(machine, "opening Settings → Plugins")
        dump = _keep_the_pane(machine, check_dir, lab, "plugins-pane.txt")
        said = ui.says(ui.element(dump, f"catalogue.{LINKED}.state"))
        expect(
            f"plugins/{LINKED}/lib is a symbolic link" in said,
            f"{LINKED}'s row says {said!r}; it has to name plugins/{LINKED}/lib as a symbolic link",
        )
        expect(ui.element(dump, f"catalogue.{LINKED}.install") is None, f"{LINKED} is offered Install although it holds a link")
    finally:
        scene.close()


def check_limit_is_explained(machine, check_dir, lab):
    """With the limit used up, **Check now** says so and when it ends; no API request comes before the reset; an install still works.

    The fake answers every API request 403 with `remaining: 0` and a reset
    `LIMIT_SECONDS` ahead. **Check now** has to say why the list is old and when
    uDeck will look again — that reset, in the guest's own clock. A second
    **Check now**, and installing a plugin already listed — which needs the raw
    host only — then follow, and the fake is listened to until the reset: no API
    request in all that time. After the reset, **Check now** has to reach the API
    again and be answered, which is what tells a uDeck that waited from one that
    stopped asking for good.

    **Red for**: a uDeck that does not read the limit from the answer: it keeps
    asking, and says a plain refusal instead of the limit; and one that never
    asks again once the limit is over.
    """
    scene = _prepare(machine, check_dir, lab, main="c1")
    try:
        _the_catalogue_read(scene, since=0, commit="c1")
        now = int(machine.ssh.run("/bin/date +%s", "reading the guest's clock").stdout.strip())
        until = now + LIMIT_SECONDS
        # The reset in the lab's own clock, to listen by without asking the guest each time.
        reset_at = machine.clock() + LIMIT_SECONDS
        scene.github.tell("using the limit up", limit_until=until)
        at = machine.ssh.run(f"/bin/date -r {until} +%H:%M", "the reset in the guest's clock").stdout.strip()

        ui.plugins_pane(machine, "opening Settings → Plugins")
        before = _count(scene)
        _press(machine, "catalogue.checkNow", "pressing Check now")
        trouble = _wait_until(machine, "catalogue.trouble", lambda said: said and LIMIT_USED_UP in said, OPERATION_SECONDS)
        _keep_the_pane(machine, check_dir, lab, "the-limit-explained.txt")
        refused = [r for r in _since(scene, before, "reading the fake's log") if r.is_api]
        if not any(r.status == 403 for r in refused):
            raise LabError("pressing Check now", f"the fake never refused uDeck, so no limit was met: {described(refused)}")
        expect(
            trouble is not None and LIMIT_USED_UP in trouble and at in trouble,
            f"with the limit used up until {at}, the catalogue says {trouble!r}; it has to say the limit is used "
            f"up and that uDeck will look again after {at}",
        )

        again = _count(scene)
        _press(machine, "catalogue.checkNow", "pressing Check now again")
        record, during = _install(scene, UPTIME, pane_open=True)
        expect(record.get("version") == "1.0.0", f"installing under a used-up limit put {record!r} in place")
        api = [r for r in during if r.is_api]
        expect(not api, f"installing under a used-up limit asked the API {described(api)}")

        if machine.clock() >= reset_at - 5:
            raise LabError("listening until the reset", f"Check now and the install took past the reset at {at}, so nothing was listened to")
        asked = []
        while machine.clock() < reset_at - 1 and not asked:
            machine.sleep(min(5, max(0.5, reset_at - 1 - machine.clock())))
            asked = [r for r in _since(scene, again, "listening until the reset") if r.is_api]
        expect(
            not asked,
            f"with the limit used up until {at}, uDeck asked the API before the reset: {described(asked)}",
        )
        lab.note(f"   no API request from the second Check now to the reset at {at}")

        while machine.clock() < reset_at + 2:
            machine.sleep(1)
        after = _count(scene)
        _press(machine, "catalogue.checkNow", "pressing Check now after the reset")
        answered = []
        deadline = machine.clock() + OPERATION_SECONDS
        while not answered and machine.clock() < deadline:
            machine.sleep(1)
            answered = [r for r in _since(scene, after, "reading the fake's log") if r.is_api and r.status in (200, 304)]
        _keep_the_pane(machine, check_dir, lab, "after-the-reset.txt")
        expect(
            bool(answered),
            f"after the reset at {at}, Check now did not reach the API: uDeck asked "
            f"{described(_since(scene, after, 'reading the fake log'))} — it stopped asking for good",
        )
    finally:
        scene.close()


def check_catalogue_off_means_no_network(machine, check_dir, lab):
    """Switched off and relaunched, uDeck makes no request to the fake for two minutes.

    The control comes first, on the same machine: switched on, as it ships, the
    fake heard uDeck read the catalogue at launch. Then the switch is turned off
    in Settings → Plugins, the file is read for it, uDeck is ended, its catalogue
    cache is taken away — so that a uDeck that ignored the switch would read the
    catalogue at launch again, rather than stay quiet because it read it a minute
    ago — and uDeck is started and listened to for `SILENCE_SECONDS`. A silence
    counts only if the fake still answers at the end of it.

    **Red for**: a switch that is not saved, and a uDeck that reads the catalogue
    at launch whatever the switch says.
    """
    scene = _prepare(machine, check_dir, lab, main="c1")
    try:
        _the_catalogue_read(scene, since=0, commit="c1")
        ui.plugins_pane(machine, "opening Settings → Plugins")
        switch = ui.element(_read_the_screen(machine, "reading the switch"), "catalogue.enabled")
        if switch is None or switch.value != "1":
            raise LabError("reading the switch", f"the Official catalogue switch is {switch}, not on as it ships")
        machine.click(*switch.middle, "switching the official catalogue off")
        # Read back as `ui.press` does, through the quicker walk: a click that did
        # not land is the lab's, and the file below would be judged for nothing.
        now = _wait_until(machine, "catalogue.enabled", lambda said: said == "0", config.UI_CHANGE_SECONDS)
        if now != "0":
            raise LabError("switching the official catalogue off", f"the lab clicked {switch} and it reads {now!r}")
        saved = _wait_for_disk(machine, lambda: (_read_json(machine, SETTINGS) or {}).get("officialCatalogue") is False,
                               config.SETTINGS_SAVE_SECONDS)  # fmt: skip
        expect(saved, f"the switch was turned off and {SETTINGS} says {(_read_json(machine, SETTINGS) or {}).get('officialCatalogue')!r}")

        app.quit_app(machine, "ending uDeck")
        machine.ssh.run(f"rm -rf {UDECK_HOME}/catalogue", "taking away the catalogue uDeck read")
        before = _count(scene)
        began = machine.clock()
        app.launch(machine)
        machine.screenshot(check_dir, "uDeck running with the catalogue off")
        asked = []
        while machine.clock() - began < SILENCE_SECONDS and not asked:
            machine.sleep(5)
            asked = _since(scene, before, "listening")
        if not asked and not scene.github.answers_now("asking whether the fake is still there"):
            raise LabError("listening", "the fake no longer answers, so its silence says nothing about uDeck")
        expect(
            not asked,
            f"with the official catalogue switched off, uDeck asked {described(asked)} "
            f"{asked[0].at - scene.started_at if asked else 0:.0f}s into its run",
        )
        lab.note(f"   uDeck made no request about plugins for {SILENCE_SECONDS}s with the catalogue off")
    finally:
        scene.close()


def check_modified_locally(machine, check_dir, lab):
    """A line appended to an installed file over SSH makes the row say **Modified locally** within seconds.

    **Red for**: a uDeck that does not hash the folder again when it changes, or
    keeps the **Verified** mark on a folder that is no longer what was merged.
    """
    scene = _prepare(machine, check_dir, lab, main="c1")
    try:
        _the_catalogue_read(scene, since=0, commit="c1")
        _install(scene, UPTIME)
        mark = _wait_until(machine, f"plugin.{UPTIME}.mark", lambda said: said and VERIFIED in said, NOTICED_SECONDS)
        if mark is None or VERIFIED not in mark:
            raise LabError("before the change", f"the installed row's mark is {mark!r}, not {VERIFIED!r}, before anything changed")
        machine.ssh.run(
            f"printf '# a line the operator added\\n' >> {UDECK_HOME}/plugins/{UPTIME}/uptime.sh",
            "changing an installed file",
        )
        mark = _wait_until(machine, f"plugin.{UPTIME}.mark", lambda said: said and MODIFIED in said, NOTICED_SECONDS)
        _keep_the_pane(machine, check_dir, lab, "after-the-change.txt")
        expect(
            mark is not None and MODIFIED in mark and VERIFIED not in mark,
            f"{NOTICED_SECONDS}s after a line was added to uptime.sh, the row's mark says {mark!r}, not {MODIFIED!r}",
        )
    finally:
        scene.close()


def check_window_survives_a_broken_manifest(machine, check_dir, lab):
    """A placed plugin's manifest broken over SSH keeps its window, which says what is wrong; mended, the card comes back.

    **Red for**: a uDeck that drops the window of a plugin it cannot read.
    """
    scene = _prepare(machine, check_dir, lab, main="c1")
    try:
        _the_catalogue_read(scene, since=0, commit="c1")
        _install(scene, UPTIME)
        _place(scene, UPTIME)
        _allow_and_read_the_card(scene, UPTIME, "before the manifest is broken")
        before = _the_window(machine, UPTIME, "reading the window")
        manifest = f"{UDECK_HOME}/plugins/{UPTIME}/manifest.json"
        machine.ssh.run(
            f"cp {manifest} /tmp/udeck-e2e-manifest.json && printf '{{ \"id\": \"uptime\",' > {manifest}.new && mv {manifest}.new {manifest}",
            "breaking the manifest",
        )
        _open_the_panel(machine, "opening the panel on the broken manifest")
        said = _wait_until(machine, f"window.{UPTIME}.missing", lambda text: text is not None, NOTICED_SECONDS, window=ui.PANEL,
                           present=True)  # fmt: skip
        texts = _panel_texts(machine, "reading the panel with the manifest broken")
        machine.screenshot(check_dir, "the manifest broken")
        try:
            (check_dir / "panel-with-the-manifest-broken.txt").write_text("\n".join(texts))
        except OSError:
            pass
        after = _the_window(machine, UPTIME, "reading the window with the manifest broken")
        expect(after == before, f"with {UPTIME}'s manifest broken, its window is {after} where it was {before}")
        expect(
            said is not None and any(f"{UPTIME} will not run" in text for text in texts),
            f"with {UPTIME}'s manifest broken, its window does not say so; the panel says {texts}",
        )
        # The card's rows are gone while it cannot run, so seeing them again below
        # is the card coming back and not a card that never left.
        expect(RUNS not in texts, f"with {UPTIME}'s manifest broken, its card still shows its rows: {texts}")
        machine.ssh.run(f"cp /tmp/udeck-e2e-manifest.json {manifest}.new && mv {manifest}.new {manifest}", "mending the manifest")
        card = _read_the_card(scene, UPTIME, "after the manifest was mended", lambda card: RUNS in card)
        expect(RUNS in card, f"with the manifest mended, {UPTIME}'s card did not come back: {card}")
        again = _the_window(machine, UPTIME, "reading the window after the manifest was mended")
        expect(again == before, f"after the manifest was mended, the window is {again} where it was {before}")
    finally:
        scene.close()


def check_every_replacement_warns_first(machine, check_dir, lab):
    """Reinstall, Update on the catalogue row, Back to and Remove, each over a folder with a `.env`, each warns first.

    `plugins.earlier-version` asks this of **Install this version**; the other
    buttons that replace or remove the folder ask the same rule (Q118), and each
    is pressed here in turn, in one scene: every time a fresh `.env` is put into
    the installed folder over SSH, the button is pressed, the warning has to be
    on the screen before anything happens, and once it is confirmed the `.env`
    has to be in the guest's Trash and no longer in the folder.

    **Reinstall** is offered only on a folder that is not what was installed, so
    for it `uptime.sh` gets a line of the operator's as well; **Back to 1.0.0**
    follows the update to 1.1.0 that **Update** on the catalogue row made.

    **Red for**: a button that replaces or removes a folder holding the
    operator's `.env` without saying first that it goes to the Trash, and a
    `.env` that does not reach the Trash.
    """
    scene = _prepare(machine, check_dir, lab, main="c1")
    try:
        _the_catalogue_read(scene, since=0, commit="c1")
        _install(scene, UPTIME)
        mark = _wait_until(machine, f"plugin.{UPTIME}.mark", lambda said: said and VERIFIED in said, NOTICED_SECONDS)
        if mark is None or VERIFIED not in mark:
            raise LabError("before the first .env", f"the installed row's mark is {mark!r}, not {VERIFIED!r}")

        # Reinstall, on a folder changed by the operator and holding a .env.
        token = _keep_a_dot_env(machine, "before Reinstall")
        machine.ssh.run(f"printf '# a line the operator added\\n' >> {UDECK_HOME}/plugins/{UPTIME}/uptime.sh",
                        "changing an installed file")  # fmt: skip
        _wait_until(machine, f"plugin.{UPTIME}.reinstall", lambda said: said is not None, NOTICED_SECONDS, present=True)
        before = (_read_json(machine, INSTALLED) or {}).get("plugins", {}).get(UPTIME, {}).get("installedAt")
        _warned_then_confirmed(scene, f"plugin.{UPTIME}.reinstall", f"plugin.{UPTIME}", "Reinstall", "1.0.0",
                               lambda r: r and r.get("installedAt") != before and r.get("version") == "1.0.0")  # fmt: skip
        _expect_it_in_the_trash(machine, token, "Reinstall")

        # Update, on the catalogue row, with main moved to c2.
        scene.github.tell("moving main to c2", main="c2")
        _press(machine, "catalogue.checkNow", "pressing Check now")
        offer = _wait_until(machine, f"plugin.{UPTIME}.offer", lambda said: said == AVAILABLE_1_1_0, OPERATION_SECONDS)
        if offer != AVAILABLE_1_1_0:
            raise CheckFailed(f"after Check now, with main at c2, {UPTIME}'s row says {offer!r}, not {AVAILABLE_1_1_0!r}")
        token = _keep_a_dot_env(machine, "before Update")
        _warned_then_confirmed(scene, f"catalogue.{UPTIME}.update", f"catalogue.{UPTIME}", "Update on the catalogue row",
                               "1.1.0", lambda r: r and r.get("version") == "1.1.0")  # fmt: skip
        _expect_it_in_the_trash(machine, token, "Update on the catalogue row")

        # Back to 1.0.0.
        token = _keep_a_dot_env(machine, "before Back to")
        _warned_then_confirmed(scene, f"plugin.{UPTIME}.backTo", f"plugin.{UPTIME}", "Back to 1.0.0", "1.0.0",
                               lambda r: r and r.get("version") == "1.0.0")  # fmt: skip
        _expect_it_in_the_trash(machine, token, "Back to 1.0.0")

        # Remove.
        token = _keep_a_dot_env(machine, "before Remove")
        _press(machine, f"plugin.{UPTIME}.remove", "pressing Remove")
        said = _wait_until(machine, f"plugin.{UPTIME}.confirmText", lambda text: bool(text), NOTICED_SECONDS)
        _keep_the_pane(machine, check_dir, lab, "the-warning-before-remove.txt")
        expect(
            said is not None and REMOVE_TO_THE_TRASH in said,
            f"with a .env in {UPTIME}'s folder, Remove said {said!r} before removing it; it has to say "
            f"{REMOVE_TO_THE_TRASH!r}",
        )
        _press(machine, f"plugin.{UPTIME}.confirm", "confirming the removal")
        gone = _wait_for_disk(machine, lambda: not _exists(machine, f"{UDECK_HOME}/plugins/{UPTIME}"), OPERATION_SECONDS)
        expect(gone, f"after Remove was confirmed, ~/.udeck/plugins/{UPTIME} is still there")
        _expect_it_in_the_trash(machine, token, "Remove")
    finally:
        scene.close()


def check_an_update_ends_a_running_action(machine, check_dir, lab):
    """An update pressed while the card's action runs ends the action first, and only then replaces the folder.

    The fixture's card has one action, **Hold** (`hold.sh`), which runs until it
    is ended and writes down, five times a second, whether the manifest at its
    plugin's place is still the one it started with — and, on `SIGTERM`, that it
    was ended. It is pressed on the card, and then **Update** is pressed in
    Settings while it runs. uDeck quiets the plugin (Q117): the action is given
    as long as a poll could take, then its process group is ended, and the
    folder is swapped after that (`DeckModel.quiet`, `PluginQuiet.quiet`).

    **Red for**: an update that swaps the folder while the action is still
    running in it (the action writes "changed under it"), and one that never
    ends the action (it is still running afterwards, or the update does not
    happen).
    """
    scene = _prepare(machine, check_dir, lab, main="c1")
    try:
        _the_catalogue_read(scene, since=0, commit="c1")
        _install(scene, UPTIME)
        _place(scene, UPTIME)
        machine.ssh.run(f"rm -f {HOLD_LOG}", "clearing the action's own log")
        _allow_and_read_the_card(scene, UPTIME, "before the action")

        scene.github.tell("moving main to c2", main="c2")
        ui.plugins_pane(machine, "opening Settings → Plugins")
        _press(machine, "catalogue.checkNow", "pressing Check now")
        offer = _wait_until(machine, f"plugin.{UPTIME}.offer", lambda said: said == AVAILABLE_1_1_0, OPERATION_SECONDS)
        if offer != AVAILABLE_1_1_0:
            raise CheckFailed(f"after Check now, with main at c2, {UPTIME}'s row says {offer!r}, not {AVAILABLE_1_1_0!r}")

        _open_the_panel(machine, "opening the panel to press Hold")
        hold = f"card.{UPTIME}.action.0"
        try:
            button = ui.wait_for(machine, hold, "waiting for the card's Hold", ui.PANEL)
        except NotThere as error:
            raise CheckFailed(f"{UPTIME}'s card offers no Hold action: {error.reason}") from None
        machine.click(*button.middle, "pressing Hold on the card")
        started = _wait_for_disk(machine, lambda: "started" in _hold_log(machine), NOTICED_SECONDS)
        if not started:
            raise CheckFailed(f"Hold was pressed and the action never started: {_hold_log(machine)!r}")
        _put_the_panel_away(machine, "after pressing Hold")
        if not _hold_is_running(machine):
            raise LabError("before the update", f"the action ended by itself before the update: {_hold_log(machine)!r}")

        ui.plugins_pane(machine, "opening Settings → Plugins")
        record = _operate(scene, f"plugin.{UPTIME}.update", "updating uptime while Hold runs",
                          lambda r: r and r.get("version") == "1.1.0")  # fmt: skip
        # The action looks at its folder five times a second, so it is given
        # time to have seen a swap made under it — and it ends within that time
        # only if something ended it, which is the other half of the verdict.
        # Read at once, a swap under it 0.3 s before could go unwritten
        # (measured: a uDeck that swapped without ending it read as "started"
        # and nothing more, .build/e2e/20260929-122337Z).
        _wait_for_disk(machine, lambda: not _hold_is_running(machine), NOTICED_SECONDS)
        said = _hold_log(machine)
        try:
            (check_dir / "hold.log").write_text(said)
        except OSError:
            pass
        expect(record is not None, f"with Hold running, Update did not put 1.1.0 in place; the action's log: {said[:300]!r}")
        expect(
            "changed under it" not in said,
            f"the folder was replaced while the action was still running in it: {said[:300]!r}",
        )
        expect("ended" in said, f"the update replaced the folder and the action was never ended: {said[:300]!r}")
        expect(not _hold_is_running(machine), f"the action is still running after the update: {said[:300]!r}")
    finally:
        scene.close()


def check_linked_folder(machine, check_dir, lab):
    """A link in `~/.udeck/plugins` to a working copy elsewhere is a plugin: its card comes, an edit there reaches it, writing into it does not stop its polls, and **Remove** takes the link alone.

    The lab makes a plugin of its own in `~/udeck-e2e-work/linked-card` — a
    working copy beside a `.git`, a `.env` with a token of its own, files named
    like uDeck's `installed.json` and `cache/`, and a link inside it — and links
    it in while uDeck is not running, as `udeck-plugin link` would. Placed on an
    empty tab and allowed, its card has to come and say `first`. Then the
    manifest *in the working copy* is changed to run another producer, which
    says `second`: only a uDeck that watches where the link leads reads the
    manifest again, so the card saying `second` is the watch working, not just
    the next run. Then, the panel still open and the plugin polled every
    `TOUCHED_INTERVAL` seconds, a file in the working copy is touched every
    `TOUCH_EVERY` seconds for `TOUCHES` touches: the plugin's own count of its
    runs, in uDeck's cache of it, has to go up by `MINIMUM_RUNS_WHILE_TOUCHED`
    at least. Then **Remove**, and the oracle is the disk: the link gone,
    uDeck's own cache of the plugin gone, and the working copy — every name,
    every byte, the link inside it — exactly as it was, and its `.env` not in
    the Trash.

    **Red for**: a uDeck that skips a link (no card), that does not watch the
    folder a link leads to (the card keeps saying `first`), that starts a
    plugin's interval over on every change in the working copy (no run while
    it is touched), or whose removal goes through the link (the working copy
    changed, emptied or in the Trash).
    """
    scene = _prepare(machine, check_dir, lab, main="c1", launch=False)
    try:
        token = _a_working_copy(machine)
        machine.ssh.run(
            f"mkdir -p {UDECK_HOME}/plugins && ln -s {WORK}/{LINKED_CARD} {UDECK_HOME}/plugins/{LINKED_CARD}",
            "linking the working copy into uDeck",
        )
        _place(scene, LINKED_CARD)
        card = _allow_and_read_the_card(scene, LINKED_CARD, "through the link")
        expect(card.get(VERSION_ROW) == "first", f"{LINKED_CARD}'s card, through the link, says {card}, not version first")

        _write_into_the_working_copy(machine, "run2.sh", _card_script("second"), executable=True)
        _write_into_the_working_copy(machine, "manifest.json", _linked_manifest("./run2.sh"))
        # Open, so that the plugin is polled: a panel out of sight runs nothing.
        _open_the_panel(machine, "opening the panel after the edit")
        card = _read_the_card(scene, LINKED_CARD, "after the edit", lambda card: card.get(VERSION_ROW) == "second")
        expect(card.get(VERSION_ROW) == "second", f"after its manifest was changed in the working copy, the card says {card}")

        _write_into_the_working_copy(machine, "manifest.json", _linked_manifest("./run2.sh", interval=TOUCHED_INTERVAL))
        before = _runs_counted(machine, "before the touches")
        machine.ssh.run(
            f"for i in $(seq {TOUCHES}); do touch {WORK}/{LINKED_CARD}/touched; sleep {TOUCH_EVERY}; done",
            "touching the working copy while the panel is open",
            seconds=TOUCHES * TOUCH_EVERY + 60,
        )
        after = _runs_counted(machine, "after the touches")
        # Still open, or the count says nothing: a panel out of sight polls nothing.
        _panel_texts(machine, "reading the panel after the touches")
        try:
            (check_dir / "runs-while-touched.txt").write_text(
                f"interval {TOUCHED_INTERVAL} s, touched every {TOUCH_EVERY} s {TOUCHES} times: runs {before} -> {after}\n"
            )
        except OSError:
            pass
        expect(
            after - before >= MINIMUM_RUNS_WHILE_TOUCHED,
            f"polled every {TOUCHED_INTERVAL} s, the plugin ran {after - before} times while its working copy was "
            f"touched every {TOUCH_EVERY} s for {TOUCHES * TOUCH_EVERY} s",
        )
        _put_the_panel_away(machine, "after the edit")

        before = _fingerprint(machine, "before the removal")
        ui.plugins_pane(machine, "opening Settings → Plugins")
        _press(machine, f"plugin.{LINKED_CARD}.remove", "pressing Remove")
        _press(machine, f"plugin.{LINKED_CARD}.confirm", "confirming the removal")
        link = f"{UDECK_HOME}/plugins/{LINKED_CARD}"
        gone = _wait_for_disk(machine, lambda: machine.ssh.ask(f"test -L {link} || test -e {link}", "looking for the link").returncode != 0,
                              OPERATION_SECONDS)  # fmt: skip
        _keep_the_pane(machine, check_dir, lab, "after-the-removal.txt")
        expect(gone, f"after Remove, {link} is still there")
        after = _fingerprint(machine, "after the removal")
        try:
            (check_dir / "working-copy-before.txt").write_text(before)
            (check_dir / "working-copy-after.txt").write_text(after)
        except OSError:
            pass
        expect(after == before, f"Remove changed the working copy the link led to; before:\n{before[:600]}\nafter:\n{after[:600]}")
        looked = machine.ssh.ask(f"grep -rl {token} ~/.Trash", "looking in the Trash")
        if looked.returncode > 1:
            raise LabError("looking in the Trash", f"the guest's Trash could not be read: {looked.stderr.strip()!r}")
        expect(not looked.stdout.split(), f"the working copy's .env is in the Trash after Remove: {looked.stdout.split()}")
        expect(not _exists(machine, f"{UDECK_HOME}/cache/{LINKED_CARD}"), f"after Remove, uDeck's cache/{LINKED_CARD} is still there")
        expect(
            LINKED_CARD not in ((_read_json(machine, INSTALLED) or {}).get("plugins") or {}),
            f"a linked folder is in installed.json: {_read_json(machine, INSTALLED)!r}",
        )
    finally:
        scene.close()


# --- What the checks share ------------------------------------------------------------------


class Scene:
    """One check's machine: uDeck installed and running, the fake serving, uDeck's log kept."""

    def __init__(self, machine, check_dir, lab, github, log, mark, started_at):
        self.machine = machine
        self.check_dir = check_dir
        self.lab = lab
        self.github = github
        self.log = log
        self.mark = mark
        self.started_at = started_at

    def close(self):
        """Evidence, then the fake stopped. Never raises: the verdict is already made."""
        # The last screenshot is the lab's own ("at the end"), taken for every check.
        self.github.collect_log(self.check_dir)
        self.log.collect(self.check_dir, self.mark, "collecting uDeck's own account", name="udeck.log")
        for path in (INSTALLED, LAYOUT, GRANTS, PLUGIN_SETTINGS):
            try:
                text = self.machine.ssh.ask(f"cat {path} 2>/dev/null || true", "collecting uDeck's files").stdout
                if text:
                    (self.check_dir / path.rsplit("/", 1)[-1]).write_text(text)
            except (LabError, OSError):
                pass
        self.github.stop()


def _prepare(machine, check_dir, lab, main, launch=True, **state):
    """A lab build installed on a machine with nothing of uDeck's in it, the fake serving, and uDeck started.

    The feed is one nobody serves, as for the settings checks: a lab build must
    not be able to update itself against anything real (Q41). `~/.udeck` is taken
    away before uDeck starts — a fresh guest has none, and one shared with an
    earlier check (`--vm per-group`) must not lend this one its plugins.
    """
    feed = updates.Feed(machine, lab.note)
    build = lab.builder(feed.url, check_dir.name).build(*VERSION)
    app.install(machine, build.zip, lab.note)
    step = "preparing the machine for a plugin check"
    there = app.installed_version(machine)
    if there != VERSION:
        raise LabError(step, f"the lab installed {VERSION}, but the machine has {there}")
    machine.ssh.run(f"rm -rf {UDECK_HOME} /tmp/udeck-e2e-manifest.json", step)

    github = FakeGitHub(machine, lab.note)
    github.serve(check_dir, main=main, **state)
    log = panel.GestureLog(machine, lab.note)
    log.keep("asking the guest to keep uDeck's own account")
    mark = log.mark("marking the start")
    started_at = float(machine.ssh.run("/bin/date +%s", step).stdout.strip())
    if launch:
        app.launch(machine)
        machine.screenshot(check_dir, "uDeck running")
    return Scene(machine, check_dir, lab, github, log, mark, started_at)


def _catalogue_files(scene, commit):
    """The paths building the catalogue at `commit` needs: the passport and every plugin's manifest."""
    folders = sorted({path.split("/")[1] for path in scene.github.facts()["commits"][commit]["paths"] if path.startswith("plugins/") and path.count("/") == 1})
    return {"udeck-plugins.json", *(f"plugins/{folder}/manifest.json" for folder in folders)}


def _the_catalogue_read(scene, since, commit, seconds=CATALOGUE_SECONDS):
    """uDeck's requests from `since` on, once they hold the whole catalogue at `commit` — or a failure.

    Not reading the catalogue at launch is uDeck's failure, whichever check
    notices it first: every check here starts from a uDeck that read it by itself.
    """
    wanted = _catalogue_files(scene, commit)
    sha = scene.github.commit(commit)
    deadline = scene.machine.clock() + seconds
    while True:
        heard = _since(scene, since, "listening to the fake")
        got = {r.raw_file()[1] for r in heard if r.raw_file() and r.raw_file()[0] == sha and r.status == 200}
        if wanted <= got:
            return heard
        if scene.machine.clock() >= deadline:
            if not scene.github.answers_now("asking whether the fake is still there"):
                raise LabError("listening to the fake", "the fake no longer answers, so what uDeck did not ask says nothing")
            panel.expect_it_was_still_there(scene.machine, "listening to the fake", "uDeck was gone before it read the catalogue")
            raise CheckFailed(
                f"{seconds}s after it started, with nothing pressed, uDeck had not read the catalogue at {commit}: "
                f"it fetched {sorted(got)} of {sorted(wanted)}; everything it asked: {described(heard)}"
            )
        scene.machine.sleep(1)


def _count(scene, step="reading the fake's log"):
    """Where the fake's log stands now: every request so far, the lab's included."""
    return len(scene.github.read_log(step))


def _since(scene, before, step="reading the fake's log"):
    """uDeck's requests after the first `before` lines of the log (`_count`)."""
    return plugin_repository.uDecks(scene.github.read_log(step)[before:])


def _press(machine, identifier, what, window=ui.SETTINGS_WINDOW):
    """A control uDeck has to offer, pressed — and one it does not offer is uDeck's failure, not the lab's."""
    try:
        return ui.click(machine, identifier, what, window)
    except NotThere as error:
        raise CheckFailed(f"{what}: uDeck does not offer it — {error.reason}") from None


def _wait_until(machine, identifier, satisfied, seconds, window=ui.SETTINGS_WINDOW, present=False):
    """What the control says once `satisfied` by it — or what it last said when the time is up (None when absent)."""
    deadline = machine.clock() + seconds
    while True:
        dump = _read_the_screen(machine, f"reading {identifier}", window)
        found = ui.element(dump, identifier)
        said = None if found is None else (ui.says(found) if not present else ui.says(found) or identifier)
        if satisfied(said) or machine.clock() >= deadline:
            return said
        machine.sleep(1)


def _read_the_screen(machine, step, window=ui.SETTINGS_WINDOW):
    """Every control with an identifier on a screen (`ui.identified`): the panel is small, and walked deeper."""
    return ui.identified(machine, step, window, depth=ui.MAX_DEPTH if window == ui.PANEL else ui.IDENTIFIED_DEPTH)


def _row_of(dump, plugin):
    """The controls of `plugin`'s catalogue row that are on the screen.

    By prefix, and not by one identifier every row has: SwiftUI hands the
    accessibility API one element for texts that read alike, so the **Verified**
    label of every catalogue row came back as the installed row's
    `plugin.uptime.mark`, at its place (.build/e2e/20260928-215137Z,
    plugins.install-fetches-one-folder/after-the-install.txt). What a row always
    has of its own is its state, its button or its **Details**.
    """
    return [row for row in ui.controls(dump) if row.identifier.startswith(f"catalogue.{plugin}.")]


def _wait_for_disk(machine, satisfied, seconds):
    deadline = machine.clock() + seconds
    while True:
        if satisfied():
            return True
        if machine.clock() >= deadline:
            return False
        machine.sleep(1)


def _read_json(machine, path, step="reading uDeck's files"):
    text = machine.ssh.ask(f"cat {path} 2>/dev/null || true", step).stdout
    if not text.strip():
        return None
    try:
        return json.loads(text)
    except ValueError as error:
        raise LabError(step, f"{path} is not JSON ({error}): {text[:200]!r}") from None


def _exists(machine, path, step="looking in ~/.udeck"):
    return machine.ssh.ask(f"test -e {path}", step).returncode == 0


def _keep_the_pane(machine, check_dir, lab, name):
    """The settings window's walk, kept beside the report, and returned."""
    dump = _read_the_screen(machine, "reading Settings → Plugins")
    try:
        (check_dir / name).write_text(dump)
    except OSError as error:
        lab.note(f"   {name} could not be written: {error}")
    machine.screenshot(check_dir, name.removesuffix(".txt"))
    return dump


def _install(scene, plugin, pane_open=False):
    """**Install** pressed on a catalogue row: the record it left, and uDeck's requests from the click on."""
    machine = scene.machine
    if not pane_open:
        ui.plugins_pane(machine, "opening Settings → Plugins")
    before = _count(scene)
    record = _operate(scene, f"catalogue.{plugin}.install", f"installing {plugin}", lambda r: r is not None, plugin)
    asked = _since(scene, before, "reading the fake's log")
    if record is None:
        problem = ui.reads(machine, f"catalogue.{plugin}.problem", "reading why it was not installed")
        raise CheckFailed(f"Install on {plugin} put nothing in installed.json within {OPERATION_SECONDS}s; the row says {problem!r}; uDeck asked {described(asked)}")
    return record, asked


def _operate(scene, identifier, what, done, plugin=UPTIME):
    """A button pressed, and `installed.json`'s record of `plugin` once `done` says it is what the press was for."""
    _press(scene.machine, identifier, what)
    record = None
    deadline = scene.machine.clock() + OPERATION_SECONDS
    while True:
        record = ((_read_json(scene.machine, INSTALLED) or {}).get("plugins") or {}).get(plugin)
        if done(record) or scene.machine.clock() >= deadline:
            return record if done(record) else None
        scene.machine.sleep(1)


def _keep_a_dot_env(machine, step):
    """A `.env` of the operator's, with a token of its own, put into the installed folder: the token."""
    # Its own each time: a guest shared with an earlier check keeps its Trash.
    token = f"TOKEN={uuid.uuid4().hex}"
    machine.ssh.run(f"printf '%s\\n' {token} > {UDECK_HOME}/plugins/{UPTIME}/.env", f"keeping a .env beside the plugin {step}")
    return token


def _warned_then_confirmed(scene, button, row, what, version, done):
    """`button` pressed; the warning on `row` says the Trash and `version`; confirmed; the record `done` wants."""
    machine = scene.machine
    _press(machine, button, f"pressing {what}")
    warning = _wait_until(machine, f"{row}.confirmText", lambda said: bool(said), NOTICED_SECONDS)
    _keep_the_pane(machine, scene.check_dir, scene.lab, f"the-warning-before-{what.split()[0].lower()}.txt")
    expect(
        warning is not None and TRASH_WARNING.format(id=UPTIME) in warning and version in warning,
        f"with a .env in {UPTIME}'s folder, {what} said {warning!r} before replacing it; it has to say "
        f"{TRASH_WARNING.format(id=UPTIME)!r}… and name {version}",
    )
    record = _operate(scene, f"{row}.confirm", f"confirming {what}", done)
    expect(record is not None, f"{what} was confirmed and installed.json never showed it: {_read_json(machine, INSTALLED)!r}")
    return record


def _expect_it_in_the_trash(machine, token, what):
    """The `.env` with `token` is in the guest's Trash, and no longer in the folder."""
    looked = machine.ssh.ask(f"grep -rl {token} ~/.Trash", "looking in the Trash")
    if looked.returncode > 1:
        raise LabError("looking in the Trash", f"the guest's Trash could not be read: {looked.stderr.strip()!r}")
    expect(looked.stdout.split(), f"the .env that was in {UPTIME}'s folder is not in the Trash after {what}")
    expect(
        not _exists(machine, f"{UDECK_HOME}/plugins/{UPTIME}/.env"),
        f"the .env is still in {UPTIME}'s folder after {what}: it was not what {what} replaced",
    )


def _hold_log(machine):
    return machine.ssh.ask(f"cat {HOLD_LOG} 2>/dev/null || true", "reading the action's own log").stdout


def _hold_is_running(machine):
    return machine.ssh.ask("/usr/bin/pgrep -f hold.sh", "asking whether the action runs").returncode == 0


def _expect_a_whole_record(record, commit, tree, version, pinned, previous):
    """Every field of an `installed.json` record, as docs/plugin-repository.md lists them."""
    wanted = {
        "source": "official",
        "repository": {"provider": "github", "host": "github.com", "path": config.PLUGINS_REPOSITORY},
        "ref": {"kind": "default", "name": "main"},
        "commit": commit,
        "tree": tree,
        "version": version,
        "pinned": pinned,
        "previous": previous,
    }
    wrong = {key: record.get(key, "(missing)") for key, value in wanted.items() if record.get(key, "(missing)") != value}
    expect(not wrong, f"installed.json says {wrong}, where the install has to have written {({k: wanted[k] for k in wrong})}")
    verification = record.get("verification") or {}
    expect(
        verification.get("status") == "verified" and verification.get("by") == "official"
        and verification.get("checkedAgainst") == commit and bool(verification.get("checkedAt")),
        f"installed.json's verification is {verification!r}",
    )  # fmt: skip
    expect(bool(record.get("installedAt")), f"installed.json has no installedAt: {record!r}")


def _place(scene, plugin, setting_value=False):
    """`plugin` on a tab of its own, written into `layout.json` while uDeck is not running, and uDeck started again."""
    machine = scene.machine
    app.quit_app(machine, "ending uDeck before placing a plugin")
    tab = str(uuid.uuid4()).upper()
    layout = {
        "version": 1,
        "columns": 12,
        "selectedTabID": tab,
        "tabs": [
            {
                "id": tab,
                "name": "Lab",
                "windows": [
                    {"id": str(uuid.uuid4()).upper(), "pluginID": plugin, "column": 0, "row": 0, "width": 6, "height": 6}
                ],
            }
        ],
    }
    _write(machine, LAYOUT, layout, f"placing {plugin} on an empty tab")
    if setting_value:
        _write(machine, PLUGIN_SETTINGS, {"version": 1, "values": {plugin: {"lab": "a value"}}, "disabled": []},
               f"leaving a setting value for {plugin}")  # fmt: skip
    app.launch(machine)


def _write(machine, path, value, step):
    text = json.dumps(value, indent=1)
    machine.ssh.run(f"printf %s {shlex.quote(text)} > {path}.new && mv {path}.new {path}", step)


def _open_the_panel(machine, step):
    panel.park_in_the_middle(machine)
    panel.press_the_chord(machine, config.HOTKEY_KEY_CODE, step)


def _allow_and_read_the_card(scene, plugin, label):
    """The panel opened, the plugin allowed on its card, and the card read once it has run.

    Every plugin placed here asks for something — the fixture declares
    `exec: sysctl` — and has not been allowed at this version, so a card that
    does not ask is uDeck's failure: it runs a plugin nobody allowed, or it
    cannot run it at all. What the panel says instead is quoted, which tells the
    two apart. The panel itself not opening is the lab's, and the hotkey that
    opens it has checks of its own (`panel.the-hotkey`).
    """
    machine = scene.machine
    _open_the_panel(machine, f"opening the panel: {label}")
    identifier = f"consent.{plugin}.allow"
    try:
        allow = ui.wait_for(machine, identifier, f"waiting for {plugin} to ask: {label}", ui.PANEL)
    except NotThere as error:
        machine.screenshot(scene.check_dir, f"{plugin} did not ask: {label}")
        texts = _panel_texts(machine, f"reading the panel: {label}")
        raise CheckFailed(
            f"{plugin}, {label}, did not ask for consent on its card; the panel says {texts} ({error.reason})"
        ) from None
    machine.screenshot(scene.check_dir, f"{plugin} asks: {label}")
    machine.click(*allow.middle, f"allowing {plugin}: {label}")
    card = _read_the_card(scene, plugin, label, lambda card: RUNS in card and card[RUNS] not in ("", "unknown"))
    _put_the_panel_away(machine, label)
    return card


def _put_the_panel_away(machine, label):
    """The panel closed by the shortcut that opened it, so that it covers nothing the lab clicks next.

    Left open, it lies over the top of the settings window, and a click on the
    sidebar's Plugins row lands on the panel instead — measured on 2026-09-29
    (.build/e2e/20260928-224559Z, plugins.update-keeps-the-window: three clicks,
    General still up, the panel over it in the last screenshot).
    """
    panel.park_in_the_middle(machine)
    panel.press_the_chord(machine, config.HOTKEY_KEY_CODE, f"putting the panel away: {label}")
    machine.sleep(config.SETTLE_SECONDS)


def _panel_texts(machine, step):
    return ui.static_texts(machine, step, ui.PANEL)


def _read_the_card(scene, plugin, label, ready):
    """The card's rows as label → value, once `ready` says they are there, read out of the panel."""
    machine = scene.machine
    deadline = machine.clock() + CARD_SECONDS
    card = {}
    while True:
        try:
            texts = _panel_texts(machine, f"reading {plugin}'s card: {label}")
        except LabError:
            _open_the_panel(machine, f"opening the panel again: {label}")
            texts = _panel_texts(machine, f"reading {plugin}'s card: {label}")
        card = {texts[i]: texts[i + 1] for i in range(len(texts) - 1) if texts[i] in (RUNS, VERSION_ROW, "up")}
        if ready(card) or machine.clock() >= deadline:
            break
        machine.sleep(1)
    machine.screenshot(scene.check_dir, f"{plugin}'s card: {label}")
    try:
        (scene.check_dir / f"card-{label.replace(' ', '-')}.txt").write_text("\n".join(texts))
    except OSError:
        pass
    if not ready(card):
        raise CheckFailed(f"{plugin}'s card {label} never said it had run: the panel says {texts}")
    return card


def _linked_manifest(run, interval=2):
    """The manifest of the lab's linked plugin, running `run` every `interval` seconds. It asks for `exec: sysctl`, as the fixture does, so that its card asks for consent."""
    return json.dumps({
        "id": LINKED_CARD, "name": "Linked card", "version": "1.0.0", "api": 1, "kind": "poll",
        "run": [run], "interval": interval, "timeout": 1, "permissions": {"exec": ["sysctl"]},
    }, indent=1)  # fmt: skip


def _runs_counted(machine, step):
    """How many times the linked plugin has run, as it counts them in uDeck's cache of it (`_card_script`)."""
    said = machine.ssh.ask(f"cat {UDECK_HOME}/cache/{LINKED_CARD}/runs", f"reading the linked plugin's count of its runs {step}")
    try:
        return int(said.stdout.strip())
    except ValueError:
        raise CheckFailed(f"the linked plugin's count of its runs {step} is {said.stdout.strip()!r}: {said.stderr.strip()!r}") from None


def _card_script(version):
    """A producer whose card says, like the fixture's, how many times it ran — counted in its cache, uDeck's — and `version`."""
    return (
        "#!/bin/sh\n"
        'count=$(( $(cat "$UDECK_CACHE_DIR/runs" 2>/dev/null || echo 0) + 1 ))\n'
        'echo "$count" > "$UDECK_CACHE_DIR/runs"\n'
        f"printf '{{\"rows\": [{{\"kv\": [\"{RUNS}\", \"%s\"]}}, {{\"kv\": [\"{VERSION_ROW}\", \"{version}\"]}}]}}' \"$count\"\n"
    )


def _a_working_copy(machine):
    """The lab's plugin in `WORK`, with what a working copy holds beside it: the `.env`'s token."""
    step = "making a working copy outside ~/.udeck"
    token = f"TOKEN={uuid.uuid4().hex}"
    folder = f"{WORK}/{LINKED_CARD}"
    machine.ssh.run(
        f"rm -rf {WORK} && mkdir -p {folder}/.git {folder}/cache/{LINKED_CARD} && "
        f"printf 'ref: refs/heads/main\\n' > {folder}/.git/HEAD && "
        f"printf '%s\\n' {token} > {folder}/.env && "
        f"printf '{{\"version\": 1, \"plugins\": {{}}}}' > {folder}/installed.json && "
        f"printf 'kept' > {folder}/cache/{LINKED_CARD}/state && "
        f"ln -s run.sh {folder}/latest",
        step,
    )
    _write_into_the_working_copy(machine, "manifest.json", _linked_manifest("./run.sh"))
    _write_into_the_working_copy(machine, "run.sh", _card_script("first"), executable=True)
    return token


def _write_into_the_working_copy(machine, name, text, executable=False):
    """A file of the working copy written whole, as an editor saves one: beside it, then moved over it."""
    path = f"{WORK}/{LINKED_CARD}/{name}"
    mode = f" && chmod 755 {path}.new" if executable else ""
    machine.ssh.run(f"printf %s {shlex.quote(text)} > {path}.new{mode} && mv {path}.new {path}", f"writing {name} in the working copy")


def _fingerprint(machine, step):
    """Every name in the working copy, what each link says, and every file's hash: the same text is the same folder."""
    folder = f"{WORK}/{LINKED_CARD}"
    said = machine.ssh.ask(
        f"cd {folder} && find . -print | LC_ALL=C sort && find . -type l -exec readlink {{}} \\; && "
        "find . -type f -exec shasum -a 256 {} + | LC_ALL=C sort",
        f"reading the working copy {step}",
    )
    if said.returncode != 0 or not said.stdout.strip():
        raise CheckFailed(f"the working copy {step} could not be read — is it gone? {said.stderr.strip()!r}")
    return said.stdout


def _windows_of(layout, plugin):
    """Every window of `plugin` in a layout, with the tab it is on."""
    found = []
    for tab in (layout or {}).get("tabs") or []:
        for window in tab.get("windows") or []:
            if window.get("pluginID") == plugin:
                found.append({"tab": tab.get("id"), **window})
    return found


def _the_window(machine, plugin, step):
    windows = _windows_of(_read_json(machine, LAYOUT, step), plugin)
    return windows[0] if len(windows) == 1 else windows
