"""Plugins from a repository: the catalogue, installing, updating, removing — and saying no.

Twenty-two checks, one per row of the table in docs/plugin-repository.md ("The
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
switch is a click. The plugins the lab writes itself — linked working copies
outside `~/.udeck`, folders of commands — are written over SSH, as an author
writes them, and linked in by hand where the check is not about linking; a
folder chosen in Settings is chosen in the system's folder panel, by typing its
path (`ui.choose_folder`).
"""

import json
import re
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

# What Settings says of a linked folder and of removing it (English.swift:
# pluginMarkLinked, catalogueRemoveLinkConfirm).
LINKED_MARK = "Linked"
ONLY_THE_LINK = "Only the link goes"

# Link a folder… (plugins.link-a-folder): a working copy linked through Settings,
# with an id nothing has, and one with uptime's id over the installed uptime.
LINK_ME = "link-me"
UPTIME_WORK = "uptime-work"
# English.swift: linkFolderLinked, linkFolderOverInstalled (toTrash: false),
# linkFolderOverLink.
LINKED_TO = "Linked {id} to "
OVER_THE_INSTALLED = "{id} is installed from github.com/{repository}. Linking "
DELETES_THE_COPY = "deletes the installed copy"
OVER_A_LINK = "{id} is a link to "

# The run log (plugins.run-log-switch): a linked plugin that says something on
# standard error every run, polled every RUN_LOG_INTERVAL seconds, and how many
# entries its log has to have once the switch is on.
LOGGED = "logged"
LOGGED_SAYS = "said on standard error"
RUN_LOG_INTERVAL = 2
RUN_LOG_ENTRIES = 2
RUN_LOG_SECONDS = 30

# A failed run on a fresh card (plugins.failed-run-on-a-fresh-card): a linked
# plugin whose card lasts FLAKY_TTL seconds, polled every FLAKY_INTERVAL, that
# fails while a file named FAIL is in its folder (English.swift:
# cardLastRunFailed, cardShowingValuesFrom).
FLAKY = "flaky"
FAIL = "fail"
FLAKY_TTL = 300
FLAKY_INTERVAL = 3
FLAKY_SAYS = "ValueError: told to fail"
LAST_RUN_FAILED = "Last run failed at "
EXITED_3 = "the producer exited with status 3"
VALUES_FROM = "showing values from "
# The panel's own buttons (WorkspaceView.swift: controls) — and no density
# button among them since 2026-10-05: density is set in Settings → Look.
PANEL_BUTTONS = ("panel.fullscreen", "panel.refresh", "panel.sendAway", "panel.settings")

# Install command (plugins.install-command): where the link goes in the guest,
# what it leads to, and what the command says.
COMMAND_LINK = "~/.local/bin/udeck-plugin"
COMMAND_IN_THE_BUNDLE = f"{app.GUEST_APPLICATIONS}/{app.APP}/Contents/Helpers/udeck-plugin"
COMMAND_USAGE = "usage: udeck-plugin check"
# English.swift: commandNotInstalled, commandInstalled, commandForeign.
NOT_INSTALLED = "Not installed."
INSTALLED_COMMAND = "Installed: "
NOT_UDECKS = "is there already, and is not uDeck's"
# What the guest's zsh is told to add (ShellPath.advice), or that it finds it.
ZSH_LINE = 'export PATH="$HOME/.local/bin:$PATH"'
SHELL_SAYS = ("Your shell looks in ", "Your shell (zsh) does not look in ")

# Where to look for commands (plugins.search-path-field): a plugin whose command
# is a bare name, found in either of two folders of the lab's own, each of which
# says which one it is.
GREETER = "greeter"
GREET = "lab-greet"
TOOLS = "~/udeck-e2e-tools"

# The same, in uDeck's Russian (Russian.swift: cardLastRunFailed, pluginMarkLinked,
# catalogueRemoveLinkConfirm, linkFolderOverInstalled, commandInstalled), for
# plugins.screens-in-russian.
RU_LAST_RUN_FAILED = "Последний запуск в "
# Why it failed, in Russian too (Russian.swift: failure): the card's line and
# Settings' last run, its seconds with a comma.
RU_EXITED_3 = "программа плагина завершилась с кодом 3"
RU_A_FAILURE = "сбой: "
RU_LINKED_MARK = "Связанная папка"
RU_ONLY_THE_LINK = "Уйдёт только ссылка"
RU_OVER_THE_INSTALLED = f"{UPTIME} установлен из github.com/{config.PLUGINS_REPOSITORY}"
RU_INSTALLED_COMMAND = "Установлена: "


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

    In Settings its row is marked **Linked** and says where the link leads, and
    **Remove** says first that only the link goes (Q125).

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
    it is touched), that does not say a plugin is linked or warns of a folder
    deleted where only a link goes, or whose removal goes through the link (the
    working copy changed, emptied or in the Trash).
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
        # Settings says it is a link and where it leads (Q125), and Remove says
        # first that only the link goes.
        mark = _wait_until(machine, f"plugin.{LINKED_CARD}.mark", lambda said: said == LINKED_MARK, NOTICED_SECONDS)
        leads = ui.reads(machine, f"plugin.{LINKED_CARD}.linkedTo", "reading where the link leads")
        _keep_the_pane(machine, check_dir, lab, "the-linked-row.txt")
        expect(mark == LINKED_MARK, f"the linked plugin's row is marked {mark!r}, not {LINKED_MARK!r}")
        expect(leads is not None and leads.endswith(f"{WORK.removeprefix('~/')}/{LINKED_CARD}: uDeck runs the plugin from there"),
               f"the linked plugin's row says it leads to {leads!r}")
        _press(machine, f"plugin.{LINKED_CARD}.remove", "pressing Remove")
        warning = _wait_until(machine, f"plugin.{LINKED_CARD}.confirmText", bool, NOTICED_SECONDS)
        _keep_the_pane(machine, check_dir, lab, "the-warning-before-removing-the-link.txt")
        expect(
            warning is not None and ONLY_THE_LINK in warning and f"{WORK.removeprefix('~/')}/{LINKED_CARD}" in warning
            and "Trash" not in warning,
            f"before removing a link, Remove said {warning!r}; it has to say {ONLY_THE_LINK!r}, name the folder, and not the Trash",
        )
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


def check_link_a_folder(machine, check_dir, lab):
    """**Link a folder…** links a free id at once, and over an installed plugin only after it says what becomes of the copy.

    Driven the way a person drives it: the button in Settings → Plugins opens
    the system's folder panel, and the folder is chosen in it by typing its
    path (`ui.choose_folder`). First a working copy whose id nothing has:
    linked at once, and the row says **Linked**. Then one with `uptime`'s id,
    over the `uptime` installed from the catalogue a moment before: nothing
    happens until the warning has said that the installed copy is deleted —
    it is exactly what uDeck installed. The warning is held to what it said:
    the working copy's id changed to `link-me` while it is up, **Link** warns of
    `link-me` — a link elsewhere now — and touches neither; the id back to
    `uptime`, **Link** warns of `uptime` again. Once that is confirmed,
    `plugins/uptime` is a link to the working copy, `installed.json` no longer
    has `uptime`, and the working copy is byte for byte as it was.

    **Red for**: a Settings with no way to link a folder, a link made over an
    installed plugin without a word, a warning that says something else than
    what is done, a confirmation that acts on an id it did not name, and a link
    that writes into the folder it leads to.
    """
    scene = _prepare(machine, check_dir, lab, main="c1")
    try:
        _the_catalogue_read(scene, since=0, commit="c1")
        free = f"{WORK}/{LINK_ME}"
        _a_plugin_folder(machine, free, _manifest(LINK_ME, "./run.sh"), {"run.sh": _card_script("free")})
        ui.plugins_pane(machine, "opening Settings → Plugins")
        chosen = _link_through_settings(scene, free, "a free id")
        said = _wait_until(machine, "plugins.linkFolder.outcome", lambda said: bool(said), NOTICED_SECONDS)
        _keep_the_pane(machine, check_dir, lab, "after-linking-a-free-id.txt")
        expect(said is not None and said.startswith(LINKED_TO.format(id=LINK_ME)),
               f"Link a folder… on {chosen} said {said!r}, not {LINKED_TO.format(id=LINK_ME)!r}…")
        expect(_link_leads(machine, LINK_ME) == chosen,
               f"after Link a folder…, plugins/{LINK_ME} leads to {_link_leads(machine, LINK_ME)!r}, not {chosen!r}")
        mark = _wait_until(machine, f"plugin.{LINK_ME}.mark", lambda said: said == LINKED_MARK, NOTICED_SECONDS)
        expect(mark == LINKED_MARK, f"the plugin linked through Settings is marked {mark!r}")

        _install(scene, UPTIME, pane_open=True)
        installed = _installed_tree(machine)
        over = f"{WORK}/{UPTIME_WORK}"
        machine.ssh.run(f"rm -rf {over} && mkdir -p {WORK} && cp -R {UDECK_HOME}/plugins/{UPTIME} {over} && "
                        f"printf 'TOKEN={uuid.uuid4().hex}\\n' > {over}/.env", "making a working copy of uptime")
        before = _fingerprint(machine, "before the link over uptime", folder=over)
        chosen = _link_through_settings(scene, over, "over the installed uptime")
        warning = _wait_until(machine, "plugins.linkFolder.confirmText", lambda said: bool(said), NOTICED_SECONDS)
        _keep_the_pane(machine, check_dir, lab, "the-warning-before-linking-over-uptime.txt")
        expect(
            warning is not None and OVER_THE_INSTALLED.format(id=UPTIME, repository=config.PLUGINS_REPOSITORY) in warning
            and DELETES_THE_COPY in warning,
            f"Link a folder… over the installed {UPTIME} said {warning!r} first; it has to say "
            f"{OVER_THE_INSTALLED.format(id=UPTIME, repository=config.PLUGINS_REPOSITORY)!r}… {DELETES_THE_COPY!r}",
        )
        expect(_link_leads(machine, UPTIME) is None and _installed_tree(machine) == installed,
               "the installed uptime changed before the warning was confirmed")

        # The warning is held to what it said (ShownPlace): the id changed under it.
        free_leads = _link_leads(machine, LINK_ME)
        manifest = f"{over}/manifest.json"
        kept = f"{WORK}/{UPTIME_WORK}-manifest.json"
        machine.ssh.run(f"cp {manifest} {kept} && sed -i '' 's/\"id\": *\"{UPTIME}\"/\"id\": \"{LINK_ME}\"/' {manifest} "
                        f"&& grep -q '\"{LINK_ME}\"' {manifest}", f"changing the working copy's id to {LINK_ME}")
        _press(machine, "plugins.linkFolder.confirm", f"pressing Link on the warning about {UPTIME}, the id now {LINK_ME}")
        again = _wait_until(machine, "plugins.linkFolder.confirmText",
                            lambda said: bool(said) and said.startswith(OVER_A_LINK.format(id=LINK_ME)), NOTICED_SECONDS)
        _keep_the_pane(machine, check_dir, lab, "the-warning-after-the-id-changed.txt")
        expect(again is not None and again.startswith(OVER_A_LINK.format(id=LINK_ME)),
               f"Link pressed on the warning about {UPTIME}, the id {LINK_ME} now, said {again!r}; it has to warn of "
               f"{OVER_A_LINK.format(id=LINK_ME)!r}…")
        expect(_link_leads(machine, LINK_ME) == free_leads and _link_leads(machine, UPTIME) is None
               and _installed_tree(machine) == installed,
               f"Link on a warning that no longer said what was there changed something: plugins/{LINK_ME} leads to "
               f"{_link_leads(machine, LINK_ME)!r}, plugins/{UPTIME} to {_link_leads(machine, UPTIME)!r}")
        machine.ssh.run(f"cp {kept} {manifest} && rm -f {kept}", f"putting the working copy's id back to {UPTIME}")
        _press(machine, "plugins.linkFolder.confirm", f"pressing Link on the warning about {LINK_ME}, the id {UPTIME} again")
        warning = _wait_until(machine, "plugins.linkFolder.confirmText",
                              lambda said: bool(said) and said.startswith(f"{UPTIME} is installed"), NOTICED_SECONDS)
        expect(warning is not None and DELETES_THE_COPY in warning, f"with the id back, the warning says {warning!r}")
        expect(_link_leads(machine, UPTIME) is None and _installed_tree(machine) == installed,
               "the installed uptime changed before the warning about it was confirmed")

        _press(machine, "plugins.linkFolder.confirm", "confirming the link over uptime")
        linked = _wait_for_disk(machine, lambda: _link_leads(machine, UPTIME) == chosen, OPERATION_SECONDS)
        _keep_the_pane(machine, check_dir, lab, "after-linking-over-uptime.txt")
        expect(linked, f"after the link over uptime was confirmed, plugins/{UPTIME} leads to {_link_leads(machine, UPTIME)!r}")
        expect(UPTIME not in ((_read_json(machine, INSTALLED) or {}).get("plugins") or {}),
               f"a linked folder is in installed.json: {_read_json(machine, INSTALLED)!r}")
        after = _fingerprint(machine, "after the link over uptime", folder=over)
        expect(after == before, f"linking changed the working copy:\n{before[:600]}\nafter:\n{after[:600]}")
    finally:
        scene.close()


def check_run_log_switch(machine, check_dir, lab):
    """**Keep a run log for linked folders**, switched on in Settings, writes every run of a linked plugin into `logs/<id>.log`.

    A linked plugin of the lab's own says something on standard error every
    run. Placed, allowed, run: with the switch as uDeck ships it there is no
    log. Switched on in Settings → Plugins — which `settings.json` has to say —
    and polled with the panel open, its log has entries, each saying how the run
    ended and what it came to, with the stderr under it; and **Show the logs**
    is offered.

    **Red for**: no switch, a switch that writes nothing, a log written while it
    is off, an entry without the run's stderr.
    """
    scene = _prepare(machine, check_dir, lab, main="c1", launch=False)
    try:
        folder = f"{WORK}/{LOGGED}"
        _a_plugin_folder(machine, folder, _manifest(LOGGED, "./run.sh", interval=RUN_LOG_INTERVAL),
                         {"run.sh": _card_script("logged", stderr=LOGGED_SAYS)})
        _link_by_hand(machine, folder, LOGGED)
        _place(scene, LOGGED)
        _allow_and_read_the_card(scene, LOGGED, "before the switch")
        log = f"{UDECK_HOME}/logs/{LOGGED}.log"
        expect(not _exists(machine, log), f"with the run log off, as uDeck ships, {log} was written")

        ui.plugins_pane(machine, "opening Settings → Plugins")
        switch = ui.find(machine, "plugins.runLog", "finding the run log's switch")
        if switch is None:
            raise CheckFailed("Settings → Plugins has no run log switch (plugins.runLog)")
        machine.click(*switch.middle, "switching the run log on")
        saved = app.wait_for_settings(machine, "reading settings.json", lambda said: (said or {}).get("linkedFolderRunLog") is True)
        expect((saved or {}).get("linkedFolderRunLog") is True, f"after the switch, settings.json says {saved!r}")
        _open_the_panel(machine, "opening the panel, so that the plugin runs")
        written = _wait_for_disk(machine, lambda: len(_log_entries(machine, log)) >= RUN_LOG_ENTRIES, RUN_LOG_SECONDS)
        _put_the_panel_away(machine, "after the runs")
        text = machine.ssh.ask(f"cat {log} 2>/dev/null || true", "reading the run log").stdout
        try:
            (check_dir / f"{LOGGED}.log").write_text(text)
        except OSError:
            pass
        entries = _log_entries(machine, log)
        expect(written, f"{RUN_LOG_SECONDS}s after the switch, {log} has {len(entries)} entries: {text[:400]!r}")
        expect(all(" s: exit status 0; a card" in entry for entry in entries), f"the entries are {entries}")
        expect(f"  | {LOGGED_SAYS}" in text, f"the run log does not carry the run's stderr: {text[:400]!r}")
        ui.plugins_pane(machine, "opening Settings → Plugins again")
        shown = ui.wait_for(machine, "plugins.runLog.show", "waiting for Show the logs", seconds=NOTICED_SECONDS)
        _keep_the_pane(machine, check_dir, lab, "the-run-log-switched-on.txt")
        expect(shown is not None, "with a run log written, Settings offers no Show the logs")
    except NotThere as error:
        raise CheckFailed(f"Settings does not offer Show the logs once a run log is written: {error.reason}") from None
    finally:
        scene.close()


def check_failed_run_on_a_fresh_card(machine, check_dir, lab):
    """A run that fails while the card is fresh is said on the card at once — the dot and one line — and gone after the next good run.

    A linked plugin of the lab's own whose card lasts `FLAKY_TTL` seconds, and
    which fails — exit 3, a line on stderr — while a file named `fail` is in
    its folder. Placed, allowed, its card is read; then `fail` is put there with
    the panel open, and within a few runs the card, its values still shown,
    has the dot beside its name and the line "Last run failed at …: the producer
    exited with status 3" and "showing values from …". Settings → Plugins, under
    **More**, says the same last run and the end of its stderr. `fail` taken
    away, the panel opened again runs it, and the dot and the line are gone.
    The panel in the screenshot has its own four buttons — refresh, Settings,
    send away, fill the screen — and no density button.

    **Red for**: a card that looks healthy while its producer fails, a dot or a
    line that stays after the plugin recovers, Settings without the stderr, and
    a panel with a button it should not have or without one it should.
    """
    scene = _prepare(machine, check_dir, lab, main="c1", launch=False)
    try:
        folder = f"{WORK}/{FLAKY}"
        _a_plugin_folder(machine, folder, _manifest(FLAKY, "./run.sh", interval=FLAKY_INTERVAL),
                         {"run.sh": _card_script("steady", ttl=FLAKY_TTL, fail_when=FAIL, says=FLAKY_SAYS)})
        _link_by_hand(machine, folder, FLAKY)
        _place(scene, FLAKY)
        _allow_and_read_the_card(scene, FLAKY, "before it fails")

        _open_the_panel(machine, "opening the panel before the failure")
        machine.ssh.run(f"touch {folder}/{FAIL}", "making the plugin fail")
        failed = _wait_for_the_card(machine, lambda found, texts: found.get(f"card.{FLAKY}.failedDot") is not None
                                    and any(text.startswith(LAST_RUN_FAILED) for text in texts), CARD_SECONDS)
        machine.screenshot(check_dir, "the failed run on the fresh card")
        dump, texts = failed
        _keep(check_dir, "the-card-with-the-failed-run.txt", dump + "\n---\n" + "\n".join(texts))
        line = next((text for text in texts if text.startswith(LAST_RUN_FAILED)), None)
        expect(_identified(dump, f"card.{FLAKY}.failedDot"), f"the fresh card of a plugin that failed has no dot: {texts}")
        expect(line is not None and line.endswith(EXITED_3), f"the fresh card says {line!r} of the failed run: {texts}")
        expect(any(text.startswith(VALUES_FROM) for text in texts), f"the card does not say when its values are from: {texts}")
        expect(RUNS in texts, f"the card's values are gone while it is still fresh: {texts}")
        buttons = tuple(sorted(row.identifier for row in ui.controls(dump) if row.identifier.startswith("panel.")))
        expect(buttons == PANEL_BUTTONS, f"the panel's own buttons are {buttons}, not {PANEL_BUTTONS} — no density button")

        _put_the_panel_away(machine, "after the failure")
        ui.plugins_pane(machine, "opening Settings → Plugins on the failed run")
        _press(machine, f"plugin.{FLAKY}.more", "opening More beside the plugin")
        last = _wait_until(machine, f"plugin.{FLAKY}.lastRun", lambda said: bool(said), NOTICED_SECONDS)
        stderr = ui.reads(machine, f"plugin.{FLAKY}.stderr", "reading the end of its stderr")
        _keep_the_pane(machine, check_dir, lab, "settings-on-the-failed-run.txt")
        expect(last is not None and last.startswith("Last run ") and last.endswith(f"a failure: {EXITED_3}"),
               f"Settings says of the last run {last!r}")
        expect(stderr is not None and FLAKY_SAYS in stderr, f"Settings shows the end of its stderr as {stderr!r}")

        machine.ssh.run(f"rm -f {folder}/{FAIL}", "letting the plugin recover")
        _open_the_panel(machine, "opening the panel after the recovery")
        recovered = _wait_for_the_card(machine, lambda found, texts: found.get(f"card.{FLAKY}.failedDot") is None
                                       and not any(text.startswith(LAST_RUN_FAILED) for text in texts) and RUNS in texts,
                                       CARD_SECONDS, expect_it=False)
        machine.screenshot(check_dir, "the card after the next good run")
        dump, texts = recovered
        _keep(check_dir, "the-card-after-the-recovery.txt", dump + "\n---\n" + "\n".join(texts))
        expect(not _identified(dump, f"card.{FLAKY}.failedDot")
               and not any(text.startswith(LAST_RUN_FAILED) for text in texts),
               f"after a good run, the card still says the run failed: {texts}")
        _put_the_panel_away(machine, "after the recovery")
    finally:
        scene.close()


def check_install_command(machine, check_dir, lab):
    """**Install command** links `~/.local/bin/udeck-plugin` to the command inside uDeck.app, which runs; **Remove command** takes the link alone.

    The command travels inside the bundle (`Contents/Helpers/udeck-plugin`,
    Scripts/make-app.sh), and the bundle's signature covers it: `codesign
    --verify --deep --strict` in the guest. Settings → Plugins says it is not
    installed; **Install command** makes the link — no password asked, the
    folder made — and `~/.local/bin/udeck-plugin --help` and `--version` run
    and answer; the row says it is installed, and what the guest's shell
    makes of `~/.local/bin`. **Remove command** takes the link and leaves the
    command in the bundle. A file of somebody else's put at that place is
    said to be there, and no button offers to replace it.

    **Red for**: a bundle without the command or with a broken seal, a link
    that leads elsewhere or does not run, a removal that takes more than the
    link, and anything of somebody else's replaced.
    """
    scene = _prepare(machine, check_dir, lab, main="c1")
    try:
        verified = machine.ssh.ask(f"codesign --verify --deep --strict --verbose=2 {app.GUEST_APPLICATIONS}/{app.APP}",
                                   "verifying the bundle's signature in the guest")
        _keep(check_dir, "codesign.txt", verified.stdout + verified.stderr)
        expect(verified.returncode == 0, f"the bundle's signature does not hold: {verified.stderr.strip()[-400:]!r}")
        expect(machine.ssh.ask(f"test -x {COMMAND_IN_THE_BUNDLE}", "looking for the command in the bundle").returncode == 0,
               f"the bundle has no {COMMAND_IN_THE_BUNDLE}")
        machine.ssh.run(f"rm -rf ~/.local/bin/udeck-plugin", "making sure nothing is at the command's place")

        ui.plugins_pane(machine, "opening Settings → Plugins")
        state = _wait_until(machine, "command.state", lambda said: bool(said), NOTICED_SECONDS)
        expect(state is not None and state.startswith(NOT_INSTALLED), f"before Install command, the row says {state!r}")
        _press(machine, "command.install", "pressing Install command")
        made = _wait_for_disk(machine, lambda: _link_leads(machine, None, path=COMMAND_LINK, resolve=False) == COMMAND_IN_THE_BUNDLE,
                              OPERATION_SECONDS)
        expect(made, f"after Install command, {COMMAND_LINK} leads to {_link_leads(machine, None, path=COMMAND_LINK, resolve=False)!r}")
        helped = machine.ssh.ask(f"{COMMAND_LINK} --help", "running the command through the link")
        version = machine.ssh.ask(f"{COMMAND_LINK} --version", "asking the command its version")
        _keep(check_dir, "the-command-runs.txt", f"$ {COMMAND_LINK} --help -> {helped.returncode}\n{helped.stdout}\n"
              f"$ {COMMAND_LINK} --version -> {version.returncode}\n{version.stdout}{version.stderr}")
        expect(helped.returncode == 0 and helped.stdout.startswith(COMMAND_USAGE),
               f"{COMMAND_LINK} --help ended {helped.returncode}: {helped.stdout[:200]!r} {helped.stderr[:200]!r}")
        expect(version.returncode == 0 and version.stdout.startswith("udeck-plugin "),
               f"{COMMAND_LINK} --version said {version.stdout!r}")
        state = _wait_until(machine, "command.state", lambda said: bool(said) and said.startswith(INSTALLED_COMMAND), NOTICED_SECONDS)
        shell = _wait_until(machine, "command.shell", lambda said: bool(said), NOTICED_SECONDS)
        line = ui.reads(machine, "command.line", "reading the line the shell is told to add")
        _keep_the_pane(machine, check_dir, lab, "the-command-installed.txt")
        expect(state is not None and state.startswith(INSTALLED_COMMAND), f"after Install command, the row says {state!r}")
        expect(shell is not None and shell.startswith(SHELL_SAYS), f"what the shell finds is said as {shell!r}")
        if shell is not None and shell.startswith(SHELL_SAYS[1]):
            expect(line == ZSH_LINE, f"the guest's zsh is told to add {line!r}, not {ZSH_LINE!r}")

        _press(machine, "command.remove", "pressing Remove command")
        gone = _wait_for_disk(machine, lambda: not _exists(machine, COMMAND_LINK) and not machine.ssh.ask(
            f"test -L {COMMAND_LINK}", "looking for the link").returncode == 0, OPERATION_SECONDS)
        expect(gone, f"after Remove command, {COMMAND_LINK} is still there")
        expect(machine.ssh.ask(f"test -x {COMMAND_IN_THE_BUNDLE}", "looking in the bundle").returncode == 0,
               "Remove command took the command out of the bundle")

        machine.ssh.run(f"printf '#!/bin/sh\\necho mine\\n' > {COMMAND_LINK} && chmod 755 {COMMAND_LINK}",
                        "putting a command of somebody else's at that place")
        ui.click(machine, "section.general", "leaving Plugins")
        ui.plugins_pane(machine, "opening Settings → Plugins on somebody else's file")
        state = _wait_until(machine, "command.state", lambda said: bool(said) and NOT_UDECKS in said, NOTICED_SECONDS)
        dump = _keep_the_pane(machine, check_dir, lab, "somebody-elses-command.txt")
        expect(state is not None and NOT_UDECKS in state, f"over a file of somebody else's, the row says {state!r}")
        expect(ui.element(dump, "command.install") is None, "Install command is offered over a file of somebody else's")
        mine = machine.ssh.ask(f"cat {COMMAND_LINK}", "reading somebody else's file").stdout
        expect(mine == "#!/bin/sh\necho mine\n", f"somebody else's file was changed: {mine!r}")
    finally:
        try:
            machine.ssh.ask(f"rm -f {COMMAND_LINK}", "taking the lab's file away")
        except LabError:
            pass
        scene.close()


def check_search_path_field(machine, check_dir, lab):
    """**Where to look for commands** changes where a bare command is found, from the next run and without a restart.

    A linked plugin of the lab's own runs `lab-greet`, a bare name found in
    neither of the default folders: its window says it will not run. Two
    folders of the lab's own each hold a `lab-greet` that says which folder it
    is. Added in Settings — **＋ Add a folder…**, the folder chosen in the
    system's panel — the first is at the top of the list, `settings.json` has
    it, and the card, allowed, says `a`; the second added is above it, and the
    card says `b`; moved down with **↓**, `a` again. **Restore the defaults**
    puts the default list back.

    **Red for**: a field that does not change what runs, a change that needs a
    restart, and a list that is not what settings.json says.
    """
    scene = _prepare(machine, check_dir, lab, main="c1", launch=False)
    try:
        step = "making the lab's two folders of commands"
        machine.ssh.run(f"rm -rf {TOOLS} && mkdir -p {TOOLS}/a {TOOLS}/b", step)
        for which in ("a", "b"):
            _write_file(machine, f"{TOOLS}/{which}/{GREET}", _card_script(which), executable=True)
        folder = f"{WORK}/{GREETER}"
        _a_plugin_folder(machine, folder, _manifest(GREETER, GREET), {})
        _link_by_hand(machine, folder, GREETER)
        _place(scene, GREETER)
        _open_the_panel(machine, "opening the panel on a command not found")
        missing = _wait_until(machine, f"window.{GREETER}.missing", lambda text: text is not None, NOTICED_SECONDS,
                              window=ui.PANEL, present=True)
        texts = _panel_texts(machine, "reading the panel with the command not found")
        machine.screenshot(check_dir, "the command not found")
        _keep(check_dir, "the-command-not-found.txt", "\n".join(texts))
        expect(missing is not None and any(f"{GREET} was not found on" in text for text in texts),
               f"with {GREET} on no folder of the search path, the window says {texts}")
        _put_the_panel_away(machine, "before Settings")

        ui.plugins_pane(machine, "opening Settings → Plugins")
        first = _add_a_folder(scene, f"{TOOLS}/a", "the first folder")
        saved = app.wait_for_settings(machine, "reading settings.json", lambda said: ((said or {}).get("pluginExecutableSearchPath") or [""])[0] == first)
        expect(((saved or {}).get("pluginExecutableSearchPath") or [""])[0] == first,
               f"after the folder was added, settings.json says {saved!r}")
        dump = _keep_the_pane(machine, check_dir, lab, "the-first-folder-added.txt")
        shown = [ui.says(ui.element(dump, f"searchPath.folder.{index}")) for index in range(2)]
        expect(shown[0].endswith("udeck-e2e-tools/a") and shown[1] == "/usr/local/bin",
               f"the list's first two folders read {shown}")
        card = _allow_and_read_the_card(scene, GREETER, "with the first folder added")
        expect(card.get(VERSION_ROW) == "a", f"with {first} first, the card says {card}")

        ui.plugins_pane(machine, "opening Settings → Plugins again")
        second = _add_a_folder(scene, f"{TOOLS}/b", "the second folder")
        _keep_the_pane(machine, check_dir, lab, "both-folders-added.txt")
        _open_the_panel(machine, "opening the panel with the second folder first")
        card = _read_the_card(scene, GREETER, "with the second folder first", lambda card: card.get(VERSION_ROW) == "b")
        expect(card.get(VERSION_ROW) == "b", f"with {second} first, the card says {card}")
        _put_the_panel_away(machine, "before moving it down")

        ui.plugins_pane(machine, "opening Settings → Plugins to move it")
        _press(machine, "searchPath.row.0", "choosing the first folder")
        _press(machine, "searchPath.down", "moving it down")
        saved = app.wait_for_settings(machine, "reading settings.json", lambda said: ((said or {}).get("pluginExecutableSearchPath") or [""])[:2] == [first, second])
        expect(((saved or {}).get("pluginExecutableSearchPath") or [])[:2] == [first, second],
               f"after ↓, settings.json says {saved!r}")
        _open_the_panel(machine, "opening the panel with the first folder first again")
        card = _read_the_card(scene, GREETER, "with the first folder first again", lambda card: card.get(VERSION_ROW) == "a")
        expect(card.get(VERSION_ROW) == "a", f"with {first} moved back to the top, the card says {card}")
        _put_the_panel_away(machine, "before restoring the defaults")

        ui.plugins_pane(machine, "opening Settings → Plugins to restore the defaults")
        _press(machine, "searchPath.restore", "pressing Restore the defaults")
        saved = app.wait_for_settings(machine, "reading settings.json", lambda said: first not in ((said or {}).get("pluginExecutableSearchPath") or [first]))
        _keep_the_pane(machine, check_dir, lab, "the-defaults-restored.txt")
        expect(first not in ((saved or {}).get("pluginExecutableSearchPath") or [first])
               and second not in ((saved or {}).get("pluginExecutableSearchPath") or [second]),
               f"after Restore the defaults, settings.json says {saved!r}")
    finally:
        scene.close()


def check_screens_in_russian(machine, check_dir, lab):
    """Every new part of Settings → Plugins and the failed run on a card, with uDeck in Russian.

    uDeck is set to Russian before it starts (`language` in `settings.json`,
    the guest stays English), and the lab walks what C2b added and keeps a
    screenshot of each — for a person to read: the **Linked** row and the
    warning before removing a link, **Link a folder…** over an installed plugin
    and its warning, the run log switch, **Where to look for commands**,
    **Install command**, the last run under **More**, and a failed run on a
    fresh card. Each is found by its identifier, and its words are uDeck's
    Russian ones (Russian.swift) — why the run failed too, on the card and in
    the last run, whose seconds are written with a comma; nothing is confirmed.

    **Red for**: a part that is not there in Russian, or that says it in
    English.
    """
    scene = _prepare(machine, check_dir, lab, main="c1", launch=False)
    ru = ui.RUSSIAN
    window = ru.settings_window
    try:
        machine.ssh.run(f"mkdir -p {UDECK_HOME}", "making uDeck's folder")
        _write(machine, SETTINGS, {"language": ru.code}, "setting uDeck's language to Russian")
        folder = f"{WORK}/{FLAKY}"
        _a_plugin_folder(machine, folder, _manifest(FLAKY, "./run.sh", interval=FLAKY_INTERVAL),
                         {"run.sh": _card_script("steady", ttl=FLAKY_TTL, fail_when=FAIL, says=FLAKY_SAYS)})
        _link_by_hand(machine, folder, FLAKY)
        _place(scene, FLAKY)
        _allow_and_read_the_card(scene, FLAKY, "in Russian")
        _open_the_panel(machine, "opening the panel before the failure")
        machine.ssh.run(f"touch {folder}/{FAIL}", "making the plugin fail")
        dump, texts = _wait_for_the_card(machine, lambda found, texts: found.get(f"card.{FLAKY}.failedDot") is not None
                                         and any(text.startswith(RU_LAST_RUN_FAILED) for text in texts), CARD_SECONDS)
        machine.screenshot(check_dir, "ru — a failed run on a fresh card")
        _keep(check_dir, "ru-card.txt", "\n".join(texts))
        line = next((text for text in texts if text.startswith(RU_LAST_RUN_FAILED)), None)
        expect(line is not None and line.endswith(RU_EXITED_3), f"the card in Russian says {line!r} of the failed run: {texts}")
        _put_the_panel_away(machine, "after the failure")

        ui.plugins_pane(machine, "opening Settings → Plugins in Russian", language=ru)
        _the_catalogue_read(scene, since=0, commit="c1")
        # The catalogue first: it is at the foot of the pane, and everything
        # opened above it — More, a warning — pushes its buttons further down.
        _install(scene, UPTIME, pane_open=True, window=window)
        over = f"{WORK}/{UPTIME_WORK}"
        machine.ssh.run(f"rm -rf {over} && cp -R {UDECK_HOME}/plugins/{UPTIME} {over}", "making a working copy of uptime")
        _link_through_settings(scene, over, "over the installed uptime, in Russian", window=window)
        warning = _wait_until(machine, "plugins.linkFolder.confirmText", lambda said: bool(said), NOTICED_SECONDS, window=window)
        _keep_the_pane(machine, check_dir, lab, "ru-the-warning-before-linking-over-uptime.txt", window=window)
        expect(warning is not None and RU_OVER_THE_INSTALLED in warning, f"Link a folder… in Russian says {warning!r}")
        _press(machine, "plugins.linkFolder.cancel", "leaving it as it is", window=window)

        mark = _wait_until(machine, f"plugin.{FLAKY}.mark", lambda said: said == RU_LINKED_MARK, NOTICED_SECONDS, window=window)
        expect(mark == RU_LINKED_MARK, f"the linked row is marked {mark!r} in Russian")
        _press(machine, f"plugin.{FLAKY}.more", "opening More", window=window)
        last = _wait_until(machine, f"plugin.{FLAKY}.lastRun", lambda said: bool(said), NOTICED_SECONDS, window=window)
        _keep_the_pane(machine, check_dir, lab, "ru-plugins-pane.txt", window=window)
        expect(last is not None and RU_A_FAILURE + RU_EXITED_3 in last and re.search(r"\d+,\d\d с", last) is not None
               and "the producer" not in last, f"the last run in Russian says {last!r}")
        _press(machine, f"plugin.{FLAKY}.remove", "pressing Remove", window=window)
        warning = _wait_until(machine, f"plugin.{FLAKY}.confirmText", lambda said: bool(said), NOTICED_SECONDS, window=window)
        _keep_the_pane(machine, check_dir, lab, "ru-the-warning-before-removing-the-link.txt", window=window)
        expect(warning is not None and RU_ONLY_THE_LINK in warning, f"the warning in Russian says {warning!r}")

        machine.ssh.run("rm -rf ~/.local/bin/udeck-plugin", "making sure nothing is at the command's place")
        _press(machine, "command.install", "pressing Install command", window=window)
        state = _wait_until(machine, "command.state", lambda said: bool(said) and said.startswith(RU_INSTALLED_COMMAND),
                            NOTICED_SECONDS, window=window)
        _wait_until(machine, "command.shell", lambda said: bool(said), NOTICED_SECONDS, window=window)
        dump = _keep_the_pane(machine, check_dir, lab, "ru-search-path-and-the-command.txt", window=window)
        expect(state is not None and state.startswith(RU_INSTALLED_COMMAND), f"the command's row in Russian says {state!r}")
        for part in ("plugins.runLog", "plugins.linkFolder", "searchPath.row.0", "searchPath.add", "searchPath.restore"):
            expect(ui.element(dump, part) is not None, f"Settings → Plugins in Russian has no {part}")
        _press(machine, "command.remove", "pressing Remove command", window=window)
    finally:
        try:
            machine.ssh.ask("rm -f ~/.local/bin/udeck-plugin", "taking the command away")
        except LabError:
            pass
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


def _keep_the_pane(machine, check_dir, lab, name, window=ui.SETTINGS_WINDOW):
    """The settings window's walk, kept beside the report, and returned."""
    dump = _read_the_screen(machine, "reading Settings → Plugins", window)
    try:
        (check_dir / name).write_text(dump)
    except OSError as error:
        lab.note(f"   {name} could not be written: {error}")
    machine.screenshot(check_dir, name.removesuffix(".txt"))
    return dump


def _install(scene, plugin, pane_open=False, window=ui.SETTINGS_WINDOW):
    """**Install** pressed on a catalogue row: the record it left, and uDeck's requests from the click on."""
    machine = scene.machine
    if not pane_open:
        ui.plugins_pane(machine, "opening Settings → Plugins")
    before = _count(scene)
    record = _operate(scene, f"catalogue.{plugin}.install", f"installing {plugin}", lambda r: r is not None, plugin, window)
    asked = _since(scene, before, "reading the fake's log")
    if record is None:
        problem = ui.reads(machine, f"catalogue.{plugin}.problem", "reading why it was not installed", window)
        raise CheckFailed(f"Install on {plugin} put nothing in installed.json within {OPERATION_SECONDS}s; the row says {problem!r}; uDeck asked {described(asked)}")
    return record, asked


def _operate(scene, identifier, what, done, plugin=UPTIME, window=ui.SETTINGS_WINDOW):
    """A button pressed, and `installed.json`'s record of `plugin` once `done` says it is what the press was for."""
    _press(scene.machine, identifier, what, window)
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
    return _manifest(LINKED_CARD, run, interval)


def _manifest(plugin, run, interval=2):
    """The manifest of a plugin of the lab's own, `plugin`, running `run` every `interval` seconds, asking for `exec: sysctl`."""
    return json.dumps({
        "id": plugin, "name": plugin.replace("-", " ").capitalize(), "version": "1.0.0", "api": 1, "kind": "poll",
        "run": [run], "interval": interval, "timeout": 1, "permissions": {"exec": ["sysctl"]},
    }, indent=1)  # fmt: skip


def _runs_counted(machine, step):
    """How many times the linked plugin has run, as it counts them in uDeck's cache of it (`_card_script`)."""
    said = machine.ssh.ask(f"cat {UDECK_HOME}/cache/{LINKED_CARD}/runs", f"reading the linked plugin's count of its runs {step}")
    try:
        return int(said.stdout.strip())
    except ValueError:
        raise CheckFailed(f"the linked plugin's count of its runs {step} is {said.stdout.strip()!r}: {said.stderr.strip()!r}") from None


def _card_script(version, stderr=None, ttl=None, fail_when=None, says=None):
    """A producer whose card says, like the fixture's, how many times it ran — counted in its cache, uDeck's — and `version`.

    `stderr` is a line it says on standard error every run; `ttl`, how long its
    card lasts; `fail_when`, a file whose presence in its folder makes it fail
    instead — `says` on standard error, and exit 3.
    """
    failing = (
        f'if [ -f "$UDECK_PLUGIN_DIR/{fail_when}" ]; then echo {shlex.quote(says or "failing")} >&2; exit 3; fi\n'
        if fail_when else ""
    )
    saying = f"echo {shlex.quote(stderr)} >&2\n" if stderr else ""
    lasting = f", \"ttl\": {ttl}" if ttl else ""
    return (
        "#!/bin/sh\n"
        + failing
        + 'count=$(( $(cat "$UDECK_CACHE_DIR/runs" 2>/dev/null || echo 0) + 1 ))\n'
        'echo "$count" > "$UDECK_CACHE_DIR/runs"\n'
        + saying
        + f"printf '{{\"rows\": [{{\"kv\": [\"{RUNS}\", \"%s\"]}}, {{\"kv\": [\"{VERSION_ROW}\", \"{version}\"]}}]{lasting}}}' \"$count\"\n"
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


def _fingerprint(machine, step, folder=f"{WORK}/{LINKED_CARD}"):
    """Every name in the working copy, what each link says, and every file's hash: the same text is the same folder."""
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


def _a_plugin_folder(machine, folder, manifest, scripts):
    """A plugin folder of the lab's own at `folder`, made anew: its manifest, and each script executable."""
    machine.ssh.run(f"rm -rf {folder} && mkdir -p {folder}", f"making {folder}")
    _write_file(machine, f"{folder}/manifest.json", manifest)
    for name, text in scripts.items():
        _write_file(machine, f"{folder}/{name}", text, executable=True)


def _write_file(machine, path, text, executable=False):
    """A file written whole, as an editor saves one: beside it, then moved over it."""
    mode = f" && chmod 755 {path}.new" if executable else ""
    machine.ssh.run(f"printf %s {shlex.quote(text)} > {path}.new{mode} && mv {path}.new {path}", f"writing {path}")


def _link_by_hand(machine, folder, plugin):
    """`folder` linked into the plugins folder as `plugin`, the way `udeck-plugin link` makes the link."""
    machine.ssh.run(f"mkdir -p {UDECK_HOME}/plugins && ln -s \"$(cd {folder} && pwd -P)\" {UDECK_HOME}/plugins/{plugin}",
                    f"linking {folder} into uDeck by hand")


def _guest_path(machine, folder, step):
    """`folder` as an absolute path in the guest, every link on the way resolved — what the panel is given."""
    said = machine.ssh.run(f"cd {folder} && pwd -P", step).stdout.strip()
    if not said.startswith("/"):
        raise LabError(step, f"{folder} is not a folder in the guest: {said!r}")
    return said


def _choose_through(scene, button, folder, label, window=ui.SETTINGS_WINDOW):
    """`button` pressed, and `folder` chosen in the folder panel it opens: the path chosen, as the guest spells it."""
    machine = scene.machine
    path = _guest_path(machine, folder, f"finding {folder}: {label}")
    _press(machine, button, f"pressing {button}: {label}", window)
    machine.sleep(config.SETTLE_SECONDS)
    machine.screenshot(scene.check_dir, f"the folder panel: {label}")
    try:
        (scene.check_dir / f"windows-{label.replace(' ', '-')}.txt").write_text("\n".join(ui.windows(machine, "reading uDeck's windows")))
    except (OSError, LabError):
        pass
    ui.choose_folder(machine, path, f"choosing {path} in the folder panel: {label}")
    machine.sleep(config.SETTLE_SECONDS)
    return path


def _link_through_settings(scene, folder, label, window=ui.SETTINGS_WINDOW):
    """**Link a folder…** on `folder`: the path chosen."""
    return _choose_through(scene, "plugins.linkFolder", folder, label, window)


def _add_a_folder(scene, folder, label):
    """**＋ Add a folder…** under Where to look for commands, on `folder`: the path chosen."""
    return _choose_through(scene, "searchPath.add", folder, label)


def _link_leads(machine, plugin, path=None, resolve=True):
    """Where the link `plugins/<plugin>` — or `path` — leads, as it says it; None when it is not a link."""
    at = path or f"{UDECK_HOME}/plugins/{plugin}"
    said = machine.ssh.ask(f"test -L {at} && readlink {at}", f"reading the link {at}")
    return said.stdout.strip() if said.returncode == 0 and said.stdout.strip() else None


def _installed_tree(machine):
    """The installed `uptime` as its files and their hashes, or None when it is not a folder."""
    folder = f"{UDECK_HOME}/plugins/{UPTIME}"
    if machine.ssh.ask(f"test -d {folder} && ! test -L {folder}", "looking at the installed uptime").returncode != 0:
        return None
    return _fingerprint(machine, "reading the installed uptime", folder=folder)


def _wait_for_the_card(machine, ready, seconds, expect_it=True):
    """The panel's identified walk and its texts once `ready(found, texts)` says so — or as they last were."""
    deadline = machine.clock() + seconds
    while True:
        try:
            dump = ui.identified(machine, "reading the panel", ui.PANEL, depth=ui.MAX_DEPTH)
            texts = _panel_texts(machine, "reading the panel's texts")
        except LabError:
            _open_the_panel(machine, "opening the panel again")
            dump = ui.identified(machine, "reading the panel", ui.PANEL, depth=ui.MAX_DEPTH)
            texts = _panel_texts(machine, "reading the panel's texts")
        found = {row.identifier: row for row in ui.controls(dump) if row.identifier}
        if ready(found, texts) or machine.clock() >= deadline:
            return dump, texts
        machine.sleep(1)


def _identified(dump, identifier):
    return ui.element(dump, identifier) is not None


def _keep(check_dir, name, text):
    try:
        (check_dir / name).write_text(text)
    except OSError:
        pass


def _log_entries(machine, log):
    """The entries of a run log: its lines that are not a run's stderr under one."""
    text = machine.ssh.ask(f"cat {log} 2>/dev/null || true", "reading the run log").stdout
    return [line for line in text.splitlines() if line and not line.startswith("  ")]
