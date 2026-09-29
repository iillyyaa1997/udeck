"""Plugins from a repository: the catalogue, installing, updating, removing — and saying no.

Thirteen checks, one per row of the table in docs/plugin-repository.md ("The
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
# two minutes), and how long a second **Check now** under a used-up limit is.
SILENCE_SECONDS = 120
BLOCKED_SECONDS = 10

# How far ahead the fake says the limit resets.
LIMIT_MINUTES = 15

# What the rows say, in the guest's English (Q43): English.swift.
AVAILABLE_1_1_0 = "1.1.0 available"
VERIFIED = "Verified"
MODIFIED = "Modified locally"
LIMIT_USED_UP = "they are used up"
ARRIVED_DIFFERENT = "arrived different from what the repository lists"

# What the fixture's card says, row by row (e2e/fixtures/plugin-repository/*/plugins/uptime/uptime.sh).
RUNS = "runs since install"
VERSION_ROW = "version"


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

    **Red for**: an earlier version installed without being pinned, and a
    history that is not read from the repository.
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

        record = _operate(scene, f"plugin.{UPTIME}.history.1.0.0.install", "choosing 1.0.0",
                          lambda r: r and r.get("version") == "1.0.0")  # fmt: skip
        expect(record is not None and record.get("version") == "1.0.0", f"after choosing 1.0.0, installed.json says {record!r}")
        expect(record.get("commit") == scene.github.commit("c1"), f"1.0.0 was installed from {record.get('commit')}, not c1")
        expect(record.get("pinned") is True, f"1.0.0 chosen from the history is not pinned: {record!r}")
        offer = _wait_until(machine, f"plugin.{UPTIME}.offer", lambda said: said == AVAILABLE_1_1_0, NOTICED_SECONDS)
        _keep_the_pane(machine, check_dir, lab, "after-the-earlier-version.txt")
        expect(offer == AVAILABLE_1_1_0, f"pinned at 1.0.0, the row says {offer!r} and not {AVAILABLE_1_1_0!r}")
    finally:
        scene.close()


def check_remove_leaves_nothing(machine, check_dir, lab):
    """After **Remove**, nothing of the plugin is left; installed again, it asks again and counts from one.

    The folder, `cache/uptime`, its entries in `grants.json`, `plugin-settings.json`
    and `installed.json`, and its window. The plugin's setting value is the one
    thing the lab puts there itself — `uptime` declares no setting the panel can
    change — and it is put there while uDeck is not running, so that the removal
    has something in that file to take away. Then the plugin is installed and
    placed again: the card asks for consent again, and says it has run once.

    **Red for**: a removal that leaves the cache behind (the count goes on from
    where it was), or the grant (the card runs without asking).
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
    """With the limit used up, **Check now** says so and when it ends; no API request follows; an install still works.

    The fake answers every API request 403 with `remaining: 0` and a reset
    `LIMIT_MINUTES` ahead. **Check now** has to say why the list is old and when
    uDeck will look again — that reset, in the guest's own clock. A second
    **Check now** then reaches no API at all before the reset, and installing a
    plugin already listed works, because it needs the raw host only.

    **Red for**: a uDeck that does not read the limit from the answer: it keeps
    asking, and says a plain refusal instead of the limit.
    """
    scene = _prepare(machine, check_dir, lab, main="c1")
    try:
        _the_catalogue_read(scene, since=0, commit="c1")
        now = int(machine.ssh.run("/bin/date +%s", "reading the guest's clock").stdout.strip())
        until = now + LIMIT_MINUTES * 60
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
        machine.sleep(BLOCKED_SECONDS)
        asked = [r for r in _since(scene, again, "reading the fake's log") if r.is_api]
        expect(not asked, f"with the limit used up until {at}, Check now still asked the API: {described(asked)}")

        record, during = _install(scene, UPTIME, pane_open=True)
        expect(record.get("version") == "1.0.0", f"installing under a used-up limit put {record!r} in place")
        api = [r for r in during if r.is_api]
        expect(not api, f"installing under a used-up limit asked the API {described(api)}")
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
        for path in (INSTALLED, LAYOUT, GRANTS):
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
