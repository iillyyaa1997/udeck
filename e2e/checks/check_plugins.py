"""Plugins from a repository: the catalogue, installing, updating, removing — and saying no.

Thirty-six checks, one per row of the table in docs/plugin-repository.md ("The
lab's checks"), and all of them against the same two things: a release build of
this checkout, and a fake GitHub served inside the guest
(`plugin_repository.FakeGitHub`, `e2e/guest/fake-github.py`) whose content is
the fixture commits in `e2e/fixtures/plugin-repository/` — `c1` with `uptime`
1.0.0 and three plugins uDeck must refuse, `c2` the same with `uptime` 1.1.0,
asking for what 1.0.0 asks, and `c3` with `uptime` 1.2.0, asking for one
command more.
These checks never talk to github.com; every lab build is pointed at the fake,
and the build step refuses one that is not (`builds.Builder._verify`). (The lab
as a whole does, for the update checks that take a published release —
`releases`, `updates.github_answers` — and never for these.)

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
switch is a click — but for the updates a verified plugin makes by itself
(`plugins.verified-updates-itself`), where nothing is pressed at all, which is
the point. A check that moves `main` and presses **Update** starts uDeck with
**Update verified plugins by themselves** switched off in `settings.json`
(`_prepare(updates_itself=False)`), so that what it moves `main` to is offered
rather than installed before it can press anything. The plugins the lab writes itself — linked working copies
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

# From the card first asking to its standing still (`_once_it_stands_still`): ten
# readings half a second apart, its own time rather than what the wait for the card
# left over. Chosen, not measured; every card of run 38320594808 (18) came to rest
# within the shared deadline it had before.
CARD_SETTLES_SECONDS = 5

# How long uDeck with the catalogue switched off is listened to (the table's own
# two minutes).
SILENCE_SECONDS = 120

# How far ahead the fake says the limit resets. The table asks for "no API
# request before the reset", so the check listens until then: short enough to
# listen to whole, long enough for a Check now, an install and a second Check
# now to happen inside it on a busy guest. Each of those is a walk of Settings
# → Plugins or a search through it, and a walk took 40 to 76 s in R3 — with
# R2's uDeck too (.build/e2e/kept/20261011-142556Z…145510Z, walks.txt, 43
# controls and no Install from a link…). From the limit to the install took
# 100 to 115 s on 2026-10-10 and 159 and 205 s on 2026-10-11, so 150 s left the
# install past the reset twice (20261011-160328Z, -222503Z): seven minutes
# holds five walks of the slowest measured, with room.
LIMIT_SECONDS = 420

# What the rows say, in the guest's English (Q43): English.swift.
AVAILABLE_1_1_0 = "1.1.0 available"
# c3's uptime asks for one command more (catalogueAvailable, catalogueAsksDifferently).
AVAILABLE_1_2_0_ASKS = "1.2.0 available, asks for different permissions"
UPDATED_BY_ITSELF = "Updated by itself on "
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
# Link a folder… over a link, and Update over a link (Russian.swift:
# linkFolderOverLink, catalogueReplaceLinkConfirm): where a link leads is
# written from ~, as the folder chosen is.
RU_OVER_A_LINK = "{id} сейчас — ссылка на ~/"
RU_REPLACING_A_LINK = "{id} здесь — ссылка на ~/"
# Updating by themselves (Russian.swift: pluginUpdatedByItself, catalogueUpdatesByThemselvesHelp,
# catalogueAvailable).
RU_UPDATED_BY_ITSELF = "Обновился сам "
RU_UPDATES_BY_THEMSELVES_HELP = "После каждого чтения каталога проверенный плагин"
RU_AVAILABLE_1_1_0 = "Доступна 1.1.0"

# How long the catalogue is made to look old while uDeck is not running, so that
# the launch reads it again (CatalogueSchedule.refreshesAtLaunch: over a day).
AGED_DAYS = 2
# How long uDeck is listened to after a read that must not install anything: an
# update by itself starts as soon as the folders are hashed after the read, a
# second or two, and its download takes a few more on the guest's loopback.
LEFT_ALONE_SECONDS = 20
# How long an update by itself that waited on a card action may take once the
# action has ended: the minute's tick asks again (`DeckModel.startCatalogueSchedule`,
# a 60-second Timer), and then the update itself.
TICK_SECONDS = 60
# What uDeck says, in its own log (`DeckModel.updateVerifiedPlugins`), of a plugin
# that does not update itself or waits: `AutoUpdate.Reason` and `AutoUpdate.Wait`
# as Swift describes them.
DOES_NOT_UPDATE_ITSELF = "{id} does not update itself: {reason}"
UPDATES_ITSELF_LATER = "{id} updates itself later: {wait}"

# Installing from a link (stage 3). Pull request #3 of the fake's repository is
# the fixture pr3, made on c1 — uptime 1.0.1, asking for what 1.0.0 asks, and
# asks-nothing, new, asking for nothing at all — opened from a fork, whose head
# the base serves by commit as GitHub does (e2e/fixtures/plugin-repository/parents);
# the branch fix/uptime is at the same commit.
ASKS_NOTHING = "asks-nothing"
ASKS_NOTHING_NAME = "Asks nothing"
PULL = "3"
FORK = "someone/udeck-plugins"
BRANCH = "fix/uptime"
PULLS = {
    PULL: {"head": "pr3", "head_repo": FORK, "head_ref": "uptime-1.0.1", "state": "open", "merged": False,
           "merge_commit": None, "title": "uptime 1.0.1, and a plugin that asks for nothing"},
}  # fmt: skip
BRANCHES = {BRANCH: "pr3"}
# As a person pastes them: without a scheme, and into a plugin's folder on a
# branch whose name holds a '/'.
PULL_LINK = f"github.com/{config.PLUGINS_REPOSITORY}/pull/{PULL}"
BRANCH_LINK = f"https://github.com/{config.PLUGINS_REPOSITORY}/tree/{BRANCH}/plugins/{UPTIME}"
# What uDeck says of it, in the guest's English (English.swift: pluginMarkUnverified,
# pluginFromPullRequest, pluginFromBranch, linkHead, catalogueSwitchConfirm with what
# stays after it, permissionsAsksNothingUnverified, permissionsUnverifiedSource,
# catalogueInstalledUnverified, catalogueMissing, linkOff).
UNVERIFIED = "Unverified"
FROM_THE_PULL_REQUEST = "pull request #{number} at {commit}"
FROM_THE_BRANCH = "branch {name} at {commit}"
LINK_HEAD = "Pull request #{number} at {commit}"
SWITCH_FROM_VERIFIED = ("{id} is the verified {old} from github.com/{repository}; installing {new} from "
                        "pull request #{number} at {commit} replaces it. Its windows and settings stay. Nobody verified "
                        "the code that comes: it asks before it runs, unless you allowed exactly that code before.")
SWITCH_TO_VERIFIED = ("{id} is {old} from pull request #{number} at {commit}; installing the verified {new} from "
                      "github.com/{repository} replaces it. Its windows, settings and your permission decision stay.")
ASKS_NOTHING_UNVERIFIED = "{name} asks for nothing, but its code is unverified"
INSTALLED_HERE_UNVERIFIED = "Installed here from {line}: unverified"
NOT_IN_THE_PLUGINS_FOLDER = "{id} is not in ~/.udeck/plugins"
LINK_OFF = "The official catalogue is off, so uDeck makes no request about plugins: switch it on to install from a link."
NOBODY_VERIFIED = "Nobody verified this code: it comes from pull request #{number} of github.com/{repository}"
# What asks-nothing's card says (e2e/fixtures/plugin-repository/pr3/plugins/asks-nothing/run.sh),
# and where it counts its runs.
RAN = "ran {n} times"
# A pull request merged or closed (stage 3: a merged pull request becomes Verified,
# and what else becomes of one). Pull request #3 squash-merged as exactly its head is
# s1, on c1; with a maintainer's change, s2 (uptime 1.0.2); and main moved past s1 is
# m1, s2's content on s1 (e2e/fixtures/plugin-repository/parents). Each a rewrite of
# the fake's state, as GitHub's own merge is one press. NEXT is a branch other than
# the default one, into which a pull request can be merged too: nothing there is verified.
FOLLOWED = f"{UDECK_HOME}/catalogue/official/followed.json"
NEXT = "next"
# What uDeck says of it (English.swift: pluginPullRequestMergedDiffers,
# pluginPullRequestClosed, catalogueMergedDiffers, catalogueClosedUnmerged,
# windowReinstallBrings with the copy's name, catalogueAvailable).
MERGED_DIFFERS = "Pull request #{number} was merged, and the verified version differs — update"
CLOSED_UNMERGED = "Pull request #{number} was closed without being merged; the plugin keeps running"
CATALOGUE_MERGED_DIFFERS = "merged, and the verified version differs"
CATALOGUE_CLOSED = "closed without being merged"
REINSTALL_BRINGS = "Reinstall puts back {version} from branch {name} at {commit}: code nobody verified."
AVAILABLE = "{version} available"
# Following the branch or the pull request a copy came from (stage 3, R5). Pull request #3,
# or the branch fix/uptime, moves on from pr3 to p2 — uptime's script with one paragraph
# more, the same version and the same manifest — or is pushed again as p2x: p2's content
# made on c1, so that it does not continue pr3 (e2e/fixtures/plugin-repository/parents).
# What uDeck says of it (English.swift: pluginRefChangedStill, pluginRefRewritten,
# pluginBranchGone, pluginRefNotCheckedSince, catalogueUpdatesWaiting, catalogueUpdate).
CHANGED_STILL = "Changed in {line}, still {version}"
REWRITTEN = "The history of {line} was rewritten: its new head does not continue what is installed"
BRANCH_GONE = "Branch {name} no longer exists; the plugin keeps running"
NOT_CHECKED_SINCE = "{line} not checked since "
ONE_UPDATE_WAITING = "1 update is waiting"
UPDATE = "Update"
# Two buttons with the same word in the same window are as wide as each other, to the pixel or two.
SAME_WORD_PX = 2
# What the follower writes in uDeck's log of the copies it did not ask about (DeckModel+Repository.swift).
LEFT_AS_THEY_WERE = "left as they were: {ids}"
# uDeck's log of a read of the catalogue that asked nothing: fewer than the reserve left before it began.
LEFT_FOR_LATER = "the official catalogue: leftForLater"
# How many API requests an hour GitHub allows an address without a token, and how many uDeck
# keeps for what the operator presses (RateLimit.swift: reserveForTheOperator) — so that a
# read nobody asked for is left with one fewer than that once the catalogue's own question is
# answered (`_leave_the_reserve`).
HOURLY = 60
RESERVE = 10


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
    tab, in the same place — the card shows 1.1.0's output without asking again,
    since 1.1.0 asks for exactly what 1.0.0 asked for and the decision is carried
    to it (`GrantCarry`; `grants.json` says 1.1.0), and the record's `previous`
    holds 1.0.0. uDeck starts with **Update verified plugins by themselves** off,
    so that 1.1.0 is offered and pressed rather than put in place by itself.

    **Red for**: an update that takes the window with it, one that forgets what
    it replaced, and one after which a plugin asking for nothing new stops until
    somebody agrees again.
    """
    scene = _prepare(machine, check_dir, lab, main="c1", updates_itself=False)
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
        card = _the_card_without_asking(scene, UPTIME, "1.1.0", "after the update")
        expect(card.get(VERSION_ROW) == "1.1.0", f"after the update the card is not 1.1.0's: {card}")
        _expect_the_decision_for(machine, UPTIME, "1.1.0", "after the update")
    finally:
        scene.close()


def check_verified_updates_itself(machine, check_dir, lab):
    """With `main` moved to c2 while uDeck was not running, the next launch updates `uptime` to 1.1.0 with nothing pressed.

    `uptime` 1.0.0 is installed, placed and allowed; uDeck is ended, `main` moved
    to c2 — 1.1.0, asking for exactly what 1.0.0 asks — and the catalogue's
    `state.json` made `AGED_DAYS` old, as a Mac that slept through a day leaves
    it. uDeck is started and nothing is pressed. Then: the fake's log has the
    read at c2 and every file of `plugins/uptime` at c2, fetched by uDeck alone;
    the folder hashes to c2's tree; the record says 1.1.0, `previous` 1.0.0 at c1,
    and `automatic: true`; the window is the one it was; the card runs 1.1.0's
    producer without asking — `grants.json` holds the decision for 1.1.0; and
    the row says *Updated by itself on …* and still offers **Back to 1.0.0**.
    The row is read again with uDeck in Russian, for a person to read.

    The control, in the same scene: 1.0.0 chosen under **Earlier versions…** is
    pinned, and **Check now** — a read the log shows — leaves it at 1.0.0, with
    1.1.0 still offered, not one of its files fetched, and uDeck's own log
    saying it does not update itself because it is pinned.

    **Red for**: a uDeck that only ever offers updates (nothing in place after a
    minute); one that updates and then stops the plugin until somebody agrees
    again to what it already agreed to (the card asks); one that loses the
    window or `previous`; and one that updates a plugin the operator kept at an
    earlier version.
    """
    scene = _prepare(machine, check_dir, lab, main="c1")
    try:
        _the_catalogue_read(scene, since=0, commit="c1")
        _install(scene, UPTIME)
        _place(scene, UPTIME)
        _allow_and_read_the_card(scene, UPTIME, "at 1.0.0")
        before = _the_window(machine, UPTIME, "reading the window before the update")

        app.quit_app(machine, "ending uDeck before main moves")
        scene.github.tell("moving main to c2", main="c2")
        _age_the_catalogue(machine, AGED_DAYS)
        heard_from = _count(scene)
        app.launch(machine)
        machine.screenshot(check_dir, "uDeck started again, nothing pressed")
        record = None
        deadline = machine.clock() + CATALOGUE_SECONDS + OPERATION_SECONDS
        while machine.clock() < deadline:
            record = ((_read_json(machine, INSTALLED) or {}).get("plugins") or {}).get(UPTIME)
            if record and record.get("version") == "1.1.0":
                break
            machine.sleep(2)
        heard = _since(scene, heard_from, "reading the fake's log")
        expect(
            record is not None and record.get("version") == "1.1.0",
            f"{CATALOGUE_SECONDS + OPERATION_SECONDS}s after a launch with main at c2 and nothing pressed, "
            f"installed.json says {record!r}: 1.1.0 asks for what 1.0.0 asks and was not put in place by itself; "
            f"uDeck asked {described(heard)}",
        )
        c1, c2 = scene.github.commit("c1"), scene.github.commit("c2")
        files = scene.github.files("c2", f"plugins/{UPTIME}")
        fetched = {r.raw_file()[1] for r in heard if r.raw_file() and r.raw_file()[0] == c2 and r.status == 200}
        missing = sorted(set(files) - fetched)
        expect(not missing, f"uDeck put 1.1.0 in place without fetching {missing} at c2: {described(heard)}")
        tree = scene.github.tree_in_guest(f"{UDECK_HOME}/plugins/{UPTIME}", "hashing the folder updated by itself")
        expect(tree == scene.github.tree("c2", f"plugins/{UPTIME}"),
               f"the folder updated by itself hashes to {tree}, not c2's plugins/{UPTIME}")  # fmt: skip
        previous = record.get("previous") or {}
        expect(previous.get("version") == "1.0.0" and previous.get("commit") == c1,
               f"after the update by itself, previous is {previous!r}, not 1.0.0 at c1")  # fmt: skip
        expect(record.get("automatic") is True, f"the record of the update by itself does not say so: {record!r}")
        expect(record.get("commit") == c2 and (record.get("verification") or {}).get("status") == "verified",
               f"the record of the update by itself is not c2's, verified: {record!r}")  # fmt: skip
        after = _the_window(machine, UPTIME, "reading the window after the update by itself")
        expect(after == before, f"the update by itself moved or replaced {UPTIME}'s window: {before} → {after}")

        card = _the_card_without_asking(scene, UPTIME, "1.1.0", "after the update by itself")
        expect(card.get(VERSION_ROW) == "1.1.0", f"after the update by itself the card is not 1.1.0's: {card}")
        _expect_the_decision_for(machine, UPTIME, "1.1.0", "after the update by itself")

        ui.plugins_pane(machine, "opening Settings → Plugins")
        said = _wait_until(machine, f"plugin.{UPTIME}.updatedByItself",
                           lambda said: bool(said) and said.startswith(UPDATED_BY_ITSELF), NOTICED_SECONDS)  # fmt: skip
        dump = _keep_the_pane(machine, check_dir, lab, "updated-by-itself.txt")
        expect(said is not None and said.startswith(UPDATED_BY_ITSELF),
               f"the row of a plugin updated by itself says {said!r}, not {UPDATED_BY_ITSELF!r}…")  # fmt: skip
        expect(ui.element(dump, f"plugin.{UPTIME}.backTo") is not None,
               "after an update by itself the row does not offer Back to 1.0.0")  # fmt: skip
        expect(ui.element(dump, f"plugin.{UPTIME}.offer") is None,
               f"after the update by itself the row still offers {ui.says(ui.element(dump, f'plugin.{UPTIME}.offer'))!r}")  # fmt: skip

        # The same row in uDeck's Russian, for a person to read.
        ru = ui.RUSSIAN
        app.quit_app(machine, "ending uDeck to switch it to Russian")
        settings = _read_json(machine, SETTINGS) or {}
        _write(machine, SETTINGS, {**settings, "language": ru.code}, "setting uDeck's language to Russian")
        app.launch(machine)
        ui.plugins_pane(machine, "opening Settings → Plugins in Russian", language=ru)
        said = _wait_until(machine, f"plugin.{UPTIME}.updatedByItself",
                           lambda said: bool(said) and said.startswith(RU_UPDATED_BY_ITSELF), NOTICED_SECONDS,
                           window=ru.settings_window)  # fmt: skip
        help_ = _wait_until(machine, "catalogue.autoUpdateHelp", lambda said: bool(said), NOTICED_SECONDS,
                            window=ru.settings_window)  # fmt: skip
        _keep_the_pane(machine, check_dir, lab, "ru-updated-by-itself.txt", window=ru.settings_window)
        expect(said is not None and said.startswith(RU_UPDATED_BY_ITSELF),
               f"in Russian, the row of a plugin updated by itself says {said!r}")  # fmt: skip
        expect(help_ is not None and help_.startswith(RU_UPDATES_BY_THEMSELVES_HELP),
               f"in Russian, the switch's help says {help_!r}")  # fmt: skip

        # The control: kept at 1.0.0, it is left there by a read that offers 1.1.0.
        window = ru.settings_window
        _press(machine, f"plugin.{UPTIME}.earlier", "opening Earlier versions…", window)
        _wait_until(machine, f"plugin.{UPTIME}.history.1.0.0.install", lambda said: said is not None, OPERATION_SECONDS,
                    window=window, present=True)  # fmt: skip
        record = _operate(scene, f"plugin.{UPTIME}.history.1.0.0.install", "choosing 1.0.0",
                          lambda r: r and r.get("version") == "1.0.0", window=window)  # fmt: skip
        expect(record is not None and record.get("pinned") is True, f"1.0.0 chosen from the history is not pinned: {record!r}")
        expect(not record.get("automatic"), f"1.0.0 chosen by a press is recorded as an update by itself: {record!r}")
        looked_from = _count(scene)
        said_from = scene.log.mark("marking uDeck's log before Check now on the pinned 1.0.0")
        _press(machine, "catalogue.checkNow", "pressing Check now on the pinned 1.0.0", window)
        heard = _left_alone(scene, looked_from)
        looked = [r for r in heard if r.is_api and r.path.endswith("/commits/main") and r.status in (200, 304)]
        if not looked:
            raise LabError("pressing Check now on the pinned 1.0.0", f"uDeck did not read the catalogue: {described(heard)}")
        offer = _wait_until(machine, f"plugin.{UPTIME}.offer", lambda said: said == RU_AVAILABLE_1_1_0, NOTICED_SECONDS,
                            window=window)  # fmt: skip
        _keep_the_pane(machine, check_dir, lab, "ru-pinned-left-alone.txt", window=window)
        downloads = _files_fetched(heard, UPTIME)
        expect(not downloads, f"a read with uptime pinned at 1.0.0 fetched {described(downloads)}")
        record = ((_read_json(machine, INSTALLED) or {}).get("plugins") or {}).get(UPTIME) or {}
        expect(record.get("version") == "1.0.0" and record.get("pinned") is True,
               f"pinned at 1.0.0, uptime was replaced after a read: {record!r}")  # fmt: skip
        expect(offer == RU_AVAILABLE_1_1_0, f"pinned at 1.0.0, the row says {offer!r} and not {RU_AVAILABLE_1_1_0!r}")
        # And it was left there for being pinned, not for any other reason.
        _expect_uDeck_said(scene, said_from, DOES_NOT_UPDATE_ITSELF.format(id=UPTIME, reason="pinned"),
                           "after Check now on the pinned 1.0.0")  # fmt: skip
    finally:
        scene.close()


def check_permissions_change_only_offers(machine, check_dir, lab):
    """An update asking for one command more is only offered, saying so; the switch off offers every update.

    `uptime` 1.0.0 installed, placed and allowed. First the switch: **Update
    verified plugins by themselves** clicked off in Settings → Plugins
    (`settings.json` says `autoUpdateVerified: false`), `main` moved to c2 and
    **Check now** pressed — the row offers *1.1.0 available*, and for
    `LEFT_ALONE_SECONDS` no file of `plugins/uptime` but its manifest is
    fetched. Then the card's **Hold** (`hold.sh`) is pressed and left running,
    and the switch clicked on again: the next **Check now** reads the catalogue
    and, for `LEFT_ALONE_SECONDS`, leaves the plugin as it is — no file of it
    fetched, the record at 1.0.0, the action still running and not once seeing
    its folder change, and uDeck's own log saying it updates itself later for
    the action. The lab ends the action, as one that finishes ends, and within
    the minute's tick and an update (`TICK_SECONDS` + `OPERATION_SECONDS`) 1.1.0
    is in place by itself, with no read of the catalogue in between: the
    control, which shows the switch and the action were what held it. Then
    `main` moved to c3, whose 1.2.0 asks for one command more: after **Check
    now** — which the log shows reading c3's manifest — the row says *1.2.0
    available, asks for different permissions*, nothing of 1.2.0 but its
    manifest is fetched, 1.1.0 stays, and uDeck's log says why. **Update**
    pressed puts 1.2.0 in place, and its card asks for consent before it runs.

    **Red for**: an update by itself of a version asking for different
    permissions, a switch that does not hold updates back — or that holds them
    for good — an update by itself that ends a card action or swaps the folder
    under it, one that waits on an action for good, and a row that offers such
    an update without saying why it waits.
    """
    scene = _prepare(machine, check_dir, lab, main="c1")
    try:
        _the_catalogue_read(scene, since=0, commit="c1")
        _install(scene, UPTIME)
        _place(scene, UPTIME)
        _allow_and_read_the_card(scene, UPTIME, "at 1.0.0")

        ui.plugins_pane(machine, "opening Settings → Plugins")
        _switch(machine, "catalogue.autoUpdate", False, "switching updates by themselves off")
        saved = _wait_for_disk(machine, lambda: (_read_json(machine, SETTINGS) or {}).get("autoUpdateVerified") is False,
                               config.SETTINGS_SAVE_SECONDS)  # fmt: skip
        expect(saved, f"the switch was turned off and {SETTINGS} says {(_read_json(machine, SETTINGS) or {})!r}")
        scene.github.tell("moving main to c2", main="c2")
        looked_from = _count(scene)
        _press(machine, "catalogue.checkNow", "pressing Check now with the switch off")
        offer = _wait_until(machine, f"plugin.{UPTIME}.offer", lambda said: said == AVAILABLE_1_1_0, OPERATION_SECONDS)
        heard = _left_alone(scene, looked_from)
        _keep_the_pane(machine, check_dir, lab, "switched-off-only-offers.txt")
        expect(offer == AVAILABLE_1_1_0, f"with the switch off and main at c2, the row says {offer!r}, not {AVAILABLE_1_1_0!r}")
        downloads = _files_fetched(heard, UPTIME)
        expect(not downloads, f"with the switch off, uDeck fetched {described(downloads)} after Check now")
        record = ((_read_json(machine, INSTALLED) or {}).get("plugins") or {}).get(UPTIME) or {}
        expect(record.get("version") == "1.0.0", f"with the switch off, uptime is {record.get('version')!r} after Check now")

        # A card action running: the update by itself waits for it, and never ends it.
        machine.ssh.run(f"rm -f {HOLD_LOG}", "clearing the action's own log")
        _hold_on_the_card(scene, "with the switch off")
        ui.plugins_pane(machine, "opening Settings → Plugins with Hold running")
        _switch(machine, "catalogue.autoUpdate", True, "switching updates by themselves on again")
        saved = _wait_for_disk(machine, lambda: (_read_json(machine, SETTINGS) or {}).get("autoUpdateVerified") is True,
                               config.SETTINGS_SAVE_SECONDS)  # fmt: skip
        expect(saved, f"the switch was turned on and {SETTINGS} says {(_read_json(machine, SETTINGS) or {})!r}")
        looked_from = _count(scene)
        said_from = scene.log.mark("marking uDeck's log before Check now with Hold running")
        _press(machine, "catalogue.checkNow", "pressing Check now with the switch on and Hold running")
        heard = _left_alone(scene, looked_from)
        looked = [r for r in heard if r.is_api and r.path.endswith("/commits/main") and r.status in (200, 304)]
        if not looked:
            raise LabError("pressing Check now with Hold running", f"uDeck did not read the catalogue: {described(heard)}")
        held = _hold_log(machine)
        _keep(check_dir, "hold-while-it-waited.log", held)
        downloads = _files_fetched(heard, UPTIME)
        expect(not downloads, f"with Hold running, uDeck fetched {described(downloads)} after Check now")
        record = ((_read_json(machine, INSTALLED) or {}).get("plugins") or {}).get(UPTIME) or {}
        expect(record.get("version") == "1.0.0", f"with Hold running, uptime is {record.get('version')!r} after Check now")
        expect("changed under it" not in held, f"with Hold running, its folder was replaced under it: {held[:300]!r}")
        expect("ended" not in held and _hold_is_running(machine),
               f"an update by itself ended the card's action: {held[:300]!r}")  # fmt: skip
        _expect_uDeck_said(scene, said_from, UPDATES_ITSELF_LATER.format(id=UPTIME, wait="actionRunning"),
                           "after Check now with Hold running")  # fmt: skip

        # The action ends, and the minute's tick puts 1.1.0 in place with nothing pressed.
        heard_from = _count(scene)
        machine.ssh.run("/usr/bin/pkill -TERM -f hold.sh", "ending the action, as one that finishes ends")
        if not _wait_for_disk(machine, lambda: not _hold_is_running(machine), NOTICED_SECONDS):
            raise LabError("ending the action", f"hold.sh did not end on SIGTERM: {_hold_log(machine)!r}")
        record = None
        deadline = machine.clock() + TICK_SECONDS + OPERATION_SECONDS
        while machine.clock() < deadline:
            record = ((_read_json(machine, INSTALLED) or {}).get("plugins") or {}).get(UPTIME)
            if record and record.get("version") == "1.1.0":
                break
            machine.sleep(2)
        heard = _since(scene, heard_from, "reading the fake's log after the action ended")
        held = _hold_log(machine)
        _keep(check_dir, "hold.log", held)
        expect(record is not None and record.get("version") == "1.1.0" and record.get("automatic") is True,
               f"{TICK_SECONDS + OPERATION_SECONDS}s after the action ended, uptime did not update itself to 1.1.0: "
               f"{record!r}; uDeck asked {described(heard)}")  # fmt: skip
        read = [r for r in heard if r.is_api and r.path.endswith("/commits/main")]
        expect(not read, f"the update that waited on the action came after another read, not on the tick: {described(read)}")
        expect("changed under it" not in held, f"the folder was replaced while the action ran in it: {held[:300]!r}")

        scene.github.tell("moving main to c3", main="c3")
        looked_from = _count(scene)
        said_from = scene.log.mark("marking uDeck's log before Check now with main at c3")
        _press(machine, "catalogue.checkNow", "pressing Check now with main at c3")
        offer = _wait_until(machine, f"plugin.{UPTIME}.offer", lambda said: said == AVAILABLE_1_2_0_ASKS, OPERATION_SECONDS)
        heard = _left_alone(scene, looked_from)
        _keep_the_pane(machine, check_dir, lab, "asks-for-different-permissions.txt")
        c3 = scene.github.commit("c3")
        read = [r for r in heard if r.raw_file() == (c3, f"plugins/{UPTIME}/manifest.json") and r.status == 200]
        if not read:
            raise LabError("pressing Check now with main at c3", f"uDeck never read c3's manifest: {described(heard)}")
        expect(offer == AVAILABLE_1_2_0_ASKS, f"with main at c3, the row says {offer!r}, not {AVAILABLE_1_2_0_ASKS!r}")
        downloads = _files_fetched(heard, UPTIME)
        expect(not downloads, f"1.2.0 asks for one command more, and uDeck fetched {described(downloads)} by itself")
        record = ((_read_json(machine, INSTALLED) or {}).get("plugins") or {}).get(UPTIME) or {}
        expect(record.get("version") == "1.1.0", f"1.2.0 asks for one command more, and uptime is {record.get('version')!r}")
        _expect_uDeck_said(scene, said_from, DOES_NOT_UPDATE_ITSELF.format(id=UPTIME, reason="asksDifferently"),
                           "after Check now with main at c3")  # fmt: skip

        record = _operate(scene, f"plugin.{UPTIME}.update", "updating to 1.2.0", lambda r: r and r.get("version") == "1.2.0")
        expect(record is not None and not record.get("automatic"), f"after Update, installed.json says {record!r}")
        card = _allow_and_read_the_card(scene, UPTIME, "after the update to 1.2.0", version="1.2.0")
        expect(card.get(VERSION_ROW) == "1.2.0", f"after the update to 1.2.0 the card is not 1.2.0's: {card}")
        grant = _expect_the_decision_for(machine, UPTIME, "1.2.0", "after allowing 1.2.0")
        expect(any(g.get("scope") == "uname" for g in grant.get("granted") or []),
               f"1.2.0 was allowed and its decision does not hold uname: {grant!r}")  # fmt: skip
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
    in Settings → Plugins, the file is read for it, **Install from a link…**
    says why it does nothing, uDeck is ended, its catalogue
    cache is taken away — so that a uDeck that ignored the switch would read the
    catalogue at launch again, rather than stay quiet because it read it a minute
    ago — and uDeck is started and listened to for `SILENCE_SECONDS`. A silence
    counts only if the fake still answers at the end of it.

    **Red for**: a switch that is not saved, **Install from a link…** that does
    not say it is off with it, and a uDeck that reads the catalogue at launch
    whatever the switch says.
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
        said = _wait_until(machine, "link.off", lambda said: said == LINK_OFF, config.UI_CHANGE_SECONDS)
        expect(said == LINK_OFF, f"with the official catalogue off, Install from a link… says {said!r} of why it does nothing")

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

    Two oracles, one after the other. uDeck noticing is read on the disk — its
    record's verification turns `modified` within `NOTICED_SECONDS`, to the
    millisecond by the file's time (0.7 to 0.9 s in R3's six runs,
    `walks.txt`) — and the row is read once that has happened. The order is
    the fix for the lab's own race, measured in R3 (.build/e2e/kept/, the runs
    of 2026-10-11): one walk of Settings → Plugins took 40 to 60 s, longer
    than the deadline, and a walk that crossed the change returned the row
    without its mark, with the old mark, or with the mark several times —
    the next walk read the truth each time (`race.txt`). R2's "mark None
    within 15 s", 2 runs of 6 while the screen and the record said Modified
    locally, was the first of those. A walk begun after the record says so
    starts after the change, and `_wait_until` judges only by a walk begun
    after its deadline.

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
        changed = _guest_time_after(
            machine, f"printf '# a line the operator added\\n' >> {UDECK_HOME}/plugins/{UPTIME}/uptime.sh",
            "changing an installed file",
        )
        noticed = _wait_for_disk(machine, lambda: _status(machine, UPTIME) == "modified", NOTICED_SECONDS)
        took = _mtime_of(machine, INSTALLED) - changed
        _keep(check_dir, "noticed.txt", f"installed.json written {took:+.3f}s after the change; status {_status(machine, UPTIME)!r}\n")
        expect(noticed, f"{NOTICED_SECONDS}s after a line was added to uptime.sh, installed.json still says "
                        f"{_status(machine, UPTIME)!r}: uDeck did not hash the folder again")
        mark = _wait_until(machine, f"plugin.{UPTIME}.mark", lambda said: said and MODIFIED in said, NOTICED_SECONDS)
        _keep_the_pane(machine, check_dir, lab, "after-the-change.txt")
        expect(
            mark is not None and MODIFIED in mark and VERIFIED not in mark,
            f"uDeck recorded uptime as modified {took:.1f}s after a line was added to uptime.sh, and its row's mark "
            f"says {mark!r}, not {MODIFIED!r}",
        )
    finally:
        scene.close()


def check_install_from_a_pull_request(machine, check_dir, lab):
    """A fork's pull request pasted as `github.com/<official>/pull/3`: only its plugins' files, through the base, and Unverified everywhere.

    Pull request #3 comes from a fork, `someone/udeck-plugins`, and uDeck reads
    it through the official repository by commit, never from the fork. The
    log, from **Look up**: one request for the pull request and one for its
    listing, then the manifests of the plugins there that differ from the
    catalogue's head — asks-nothing and uptime, not the two the head has
    alike — at the head's commit; from **Install** on uptime, every file of
    `plugins/uptime/` once, from the base's raw host at the head's commit, and
    no API request. The disk: the folder hashes to pr3's tree, and
    `installed.json` says `ref {pr, "3"}`, `unverified`, by nobody. The screen:
    the link sheet, the row — *Unverified · pull request #3 at …* — and, placed
    on a tab, the card's header saying **Unverified** and its question saying
    where the code comes from.

    **Red for**: a pull request read from the fork, a copy fetched beyond its
    folder, a pull request's copy recorded as the default branch's or as
    Verified, and a card that does not say it is unverified.
    """
    scene = _prepare(machine, check_dir, lab, main="c1", pulls=PULLS)
    try:
        _the_catalogue_read(scene, since=0, commit="c1")
        ui.plugins_pane(machine, "opening Settings → Plugins")
        head = scene.github.commit("pr3")
        looked, dump = _look_up(scene, PULL_LINK, "the pull request")
        said = ui.says(ui.element(dump, "link.head"))
        expect(said == LINK_HEAD.format(number=PULL, commit=head[:7]),
               f"the link sheet says {said!r} of {PULL_LINK}, not {LINK_HEAD.format(number=PULL, commit=head[:7])!r}")  # fmt: skip
        listed = sorted(row.identifier.split(".")[1] for row in ui.controls(dump) if row.identifier.endswith(".install")
                        and row.identifier.startswith("link."))  # fmt: skip
        expect(listed == [ASKS_NOTHING, UPTIME],
               f"the link sheet offers {listed} to install: pr3 differs from c1 in {ASKS_NOTHING} and {UPTIME} only")
        _expect_only(looked, head,
                     api={f"/api/repos/{config.PLUGINS_REPOSITORY}/pulls/{PULL}",
                          f"/api/repos/{config.PLUGINS_REPOSITORY}/git/trees/{head}"},
                     raw={f"plugins/{ASKS_NOTHING}/manifest.json", f"plugins/{UPTIME}/manifest.json"},
                     what="looking up the pull request")  # fmt: skip

        record, asked = _install_from_the_link(scene, UPTIME, "the pull request")
        files = scene.github.files("pr3", f"plugins/{UPTIME}")
        _expect_only(asked, head, api=set(), raw=set(files), what=f"installing {UPTIME} from the pull request",
                     every=True)
        tree = scene.github.tree_in_guest(f"{UDECK_HOME}/plugins/{UPTIME}", "hashing the installed folder")
        expect(tree == scene.github.tree("pr3", f"plugins/{UPTIME}"),
               f"the folder uDeck installed hashes to {tree}, not pr3's plugins/{UPTIME}")
        _expect_an_unverified_record(record, ref={"kind": "pr", "name": PULL}, commit=head, version="1.0.1")

        _close_the_link_sheet(scene, "after installing")
        _expect_the_row_says(scene, UPTIME, FROM_THE_PULL_REQUEST.format(number=PULL, commit=head[:7]), "the row")

        _place(scene, UPTIME)
        _the_card_says_unverified(scene, UPTIME, "placed on an empty tab")
    finally:
        scene.close()


def check_install_from_a_branch(machine, check_dir, lab):
    """A branch of the official repository, linked into a plugin's folder: its head, its listing and that plugin's files — nothing else.

    The link goes into `plugins/uptime` on `fix/uptime`, a branch whose name
    holds a `/`, so the sheet lists uptime alone. The log, from **Look up**
    to the end of the install, holds the branch's head, by `refs/heads/`,
    its listing, and files of `plugins/uptime/` at that commit — and nothing
    else at all: not the default branch, not another plugin's manifest. The
    record says `ref {branch, "fix/uptime"}`, `unverified`, by nobody, and the
    row *Unverified · branch fix/uptime at …*. Then its folder is taken away
    over SSH: the catalogue row of uptime still says the copy here is the
    branch's, unverified, and that it is gone, and offers **Switch to
    verified** — on the plugin's own row too — which puts the verified copy
    where nothing is, without a warning, the branch's copy becoming
    `previous`. Before that, its window on a tab says beside **Reinstall**
    what that puts back — *Reinstall puts back 1.0.1 from branch fix/uptime
    at …: code nobody verified* — and Settings does not say *Nothing
    installed yet* above its **Missing** row.

    **Red for**: a branch read as anything but `refs/heads/<name>`, a name with
    a `/` cut at the wrong place, a branch's copy recorded as verified, a gone
    copy's catalogue row that says only that it is missing — under its
    **Verified** — with a **Reinstall** that puts the branch's code back, and a
    window that offers that code back without saying whose it is.
    """
    scene = _prepare(machine, check_dir, lab, main="c1", branches=BRANCHES)
    try:
        _the_catalogue_read(scene, since=0, commit="c1")
        ui.plugins_pane(machine, "opening Settings → Plugins")
        head = scene.github.commit("pr3")
        looked, dump = _look_up(scene, BRANCH_LINK, "the branch")
        listed = sorted(row.identifier.split(".")[1] for row in ui.controls(dump) if row.identifier.endswith(".install")
                        and row.identifier.startswith("link."))  # fmt: skip
        expect(listed == [UPTIME], f"a link into plugins/{UPTIME} on {BRANCH} lists {listed}, not {UPTIME} alone")
        record, asked = _install_from_the_link(scene, UPTIME, "the branch")
        files = scene.github.files("pr3", f"plugins/{UPTIME}")
        _expect_only(looked + asked, head,
                     api={f"/api/repos/{config.PLUGINS_REPOSITORY}/commits/refs/heads/{BRANCH}",
                          f"/api/repos/{config.PLUGINS_REPOSITORY}/git/trees/{head}"},
                     raw=set(files), what="looking up the branch and installing from it")  # fmt: skip
        _expect_an_unverified_record(record, ref={"kind": "branch", "name": BRANCH}, commit=head, version="1.0.1")
        _close_the_link_sheet(scene, "after installing")
        _expect_the_row_says(scene, UPTIME, FROM_THE_BRANCH.format(name=BRANCH, commit=head[:7]), "the row")
        _place(scene, UPTIME)

        machine.ssh.run(f"rm -rf {UDECK_HOME}/plugins/{UPTIME}", "taking the branch's copy away")
        # uDeck reads the folder again within a second; a walk begun before that
        # would cross the change and only cost another walk (`_wait_until`).
        machine.sleep(config.SETTLE_SECONDS)
        _open_the_panel(machine, "opening the panel on the window of the gone copy")
        brings = REINSTALL_BRINGS.format(version="1.0.1", name=BRANCH, commit=head[:7])
        said = f"window.{UPTIME}.reinstallSays"
        walk, texts = _wait_for_the_card(machine, lambda found, texts: ui.says(found.get(said)) == brings, NOTICED_SECONDS)
        machine.screenshot(check_dir, "the window of the gone copy")
        _keep(check_dir, "window-of-the-gone-copy.txt", "\n".join(texts) + "\n\n" + walk)
        _put_the_panel_away(machine, "after reading the window of the gone copy")
        window = ui.says(ui.element(walk, said))
        expect(window == brings, f"the window of the branch's gone copy says {window!r} beside Reinstall, not {brings!r}")
        ui.plugins_pane(machine, "opening Settings → Plugins with the copy gone")
        gone = f"{INSTALLED_HERE_UNVERIFIED.format(line=f'branch {BRANCH}')} — {NOT_IN_THE_PLUGINS_FOLDER.format(id=UPTIME)}"
        state = _wait_until(machine, f"catalogue.{UPTIME}.state", lambda said: said == gone, NOTICED_SECONDS)
        dump = _keep_the_pane(machine, check_dir, lab, "the-folder-gone.txt")
        expect(state == gone, f"with the branch's copy gone, {UPTIME}'s catalogue row says {state!r}, not {gone!r}")
        expect(ui.element(dump, "plugins.nothingInstalled") is None and ui.element(dump, f"plugin.{UPTIME}.mark") is not None,
               "with the branch's copy gone, Settings says Nothing installed yet above its Missing row, or has no such row")
        offered = [f"{row}.{UPTIME}.switchToVerified" for row in ("catalogue", "plugin")]
        expect(all(ui.element(dump, button) is not None for button in offered),
               f"with the branch's copy gone, Switch to verified is not offered on both rows: "
               f"{[row.identifier for row in ui.controls(dump) if UPTIME in row.identifier]}")  # fmt: skip
        expect(ui.element(dump, f"catalogue.{UPTIME}.reinstall") is None,
               f"the catalogue row of {UPTIME}, the branch's copy gone, offers Reinstall")
        verified = _operate(scene, f"catalogue.{UPTIME}.switchToVerified", "Switch to verified, the folder gone",
                            lambda r: r is not None and (r.get("ref") or {}).get("kind") == "default")
        expect(verified is not None and (verified.get("verification") or {}).get("status") == "verified"
               and ((verified.get("previous") or {}).get("ref") or {}).get("kind") == "branch",
               f"Switch to verified, the branch's copy gone, left {_read_json(machine, INSTALLED)!r}: no verified copy "
               f"over the branch's record, or no warning-free install where nothing was")  # fmt: skip
    finally:
        scene.close()


def check_unverified_asks_even_for_nothing(machine, check_dir, lab):
    """The pull request's plugin that asks for nothing does not run until **Allow**, which is held to its tree; a line added asks again.

    asks-nothing, installed from pull request #3 and placed on a tab, asks on
    its card — *Asks nothing asks for nothing, but its code is unverified*,
    with where the code comes from — and its count of runs, kept in uDeck's
    cache of it, is not there: it has not run. **Allow** runs it, and
    `grants.json` holds the decision for its version and for the tree its
    folder hashes to. A line appended to `run.sh` over SSH is new content:
    the card asks again, and **Decline** on it switches it off — a decision
    with nothing in it would let it run (`plugin-settings.json`) — and its
    count of runs, read with the panel away before the edit, is what it was:
    the edited code never ran on the decision made for the code before it.
    Switched on again in Settings, its row asks the same, under **More** —
    *Asks nothing asks for nothing, but its code is unverified*; **Decline**
    there switches it off as the card's does, the count still what it was.
    Switched on once more, the row asks again; **Allow** there records the
    decision for the edited tree, and it runs.

    **Red for**: a gate that lets code nobody verified run because it asks
    for nothing, a decision not held to the tree, an edit that runs on the
    decision made before it, and **Allow** or **Decline** in Settings that do
    not do what they do on the card.
    """
    scene = _prepare(machine, check_dir, lab, main="c1", pulls=PULLS)
    try:
        _the_catalogue_read(scene, since=0, commit="c1")
        ui.plugins_pane(machine, "opening Settings → Plugins")
        _look_up(scene, PULL_LINK, "the pull request")
        record, _ = _install_from_the_link(scene, ASKS_NOTHING, "the pull request")
        _expect_an_unverified_record(record, ref={"kind": "pr", "name": PULL}, commit=scene.github.commit("pr3"),
                                     version="1.0.0", plugin=ASKS_NOTHING)
        _place(scene, ASKS_NOTHING)
        runs = f"{UDECK_HOME}/cache/{ASKS_NOTHING}/runs"

        found, texts = _the_card_asks(scene, ASKS_NOTHING, "before anything was allowed")
        question = ASKS_NOTHING_UNVERIFIED.format(name=ASKS_NOTHING_NAME)
        expect(any(question in text for text in texts), f"{ASKS_NOTHING}'s card does not say {question!r}: {texts}")
        source = ui.says(found.get(f"consent.{ASKS_NOTHING}.source"))
        expect(NOBODY_VERIFIED.format(number=PULL, repository=config.PLUGINS_REPOSITORY) in source,
               f"{ASKS_NOTHING}'s card says {source!r} of where its code comes from")
        expect(not _exists(machine, runs), f"{ASKS_NOTHING} has run before anybody allowed it: {runs} is there")

        machine.click(*found[f"consent.{ASKS_NOTHING}.allow"].middle, f"allowing {ASKS_NOTHING}")
        ran = _wait_for_disk(machine, lambda: _exists(machine, runs), CARD_SECONDS)
        expect(ran, f"{ASKS_NOTHING} was allowed and did not run within {CARD_SECONDS}s")
        tree = scene.github.tree("pr3", f"plugins/{ASKS_NOTHING}")
        grant = ((_read_json(machine, GRANTS) or {}).get("byPlugin") or {}).get(ASKS_NOTHING) or {}
        expect(grant.get("decidedForTree") == tree and grant.get("decidedForVersion") == "1.0.0",
               f"after Allow, {GRANTS} holds {grant!r} for {ASKS_NOTHING}: the decision is held to its version "
               f"and to the tree it was made for, {tree}")
        _, texts = _wait_for_the_card(machine, lambda found, texts: any(RAN.format(n=1) in t for t in texts), CARD_SECONDS)
        machine.screenshot(scene.check_dir, f"{ASKS_NOTHING} allowed")
        expect(any(RAN.format(n=1) in t for t in texts), f"after Allow, {ASKS_NOTHING}'s card says {texts}")
        _put_the_panel_away(machine, "after Allow")
        # With the panel away nothing runs (the switch to keep plugins running
        # is off, as it ships), so this is the count the edited code must not move.
        counted = _count_of_runs(machine, runs)
        expect(counted is not None and counted >= 1, f"after Allow, {runs} says {counted!r}, not a count of its runs")

        machine.ssh.run(f"printf '# a line the operator added\\n' >> {UDECK_HOME}/plugins/{ASKS_NOTHING}/run.sh",
                        "changing the plugin's code")
        found, _ = _the_card_asks(scene, ASKS_NOTHING, "after a line was added")
        machine.click(*found[f"consent.{ASKS_NOTHING}.decline"].middle, f"declining {ASKS_NOTHING} on its card")
        off = _wait_for_disk(machine, lambda: ASKS_NOTHING in (((_read_json(machine, PLUGIN_SETTINGS) or {}).get("disabled")) or []),
                             NOTICED_SECONDS)  # fmt: skip
        expect(off, f"Decline on the card of {ASKS_NOTHING}, which asks for nothing, left it switched on: "
                    f"{_read_json(machine, PLUGIN_SETTINGS)!r}")
        after = _count_of_runs(machine, runs)
        expect(after == counted, f"{ASKS_NOTHING}'s code was changed and nobody allowed it again, and it ran: its count went "
                                 f"from {counted} to {after!r} between the edit and Decline on the card")
        _put_the_panel_away(machine, "after Decline on the card")

        # The same question in Settings, under More — and its Decline and Allow.
        ui.plugins_pane(machine, "opening Settings → Plugins after the edit")
        _switch(machine, f"plugin.{ASKS_NOTHING}.enabled", True, f"switching {ASKS_NOTHING} on in Settings")
        _press(machine, f"plugin.{ASKS_NOTHING}.more", f"opening More on {ASKS_NOTHING}")
        asks = _wait_until(machine, f"plugin.{ASKS_NOTHING}.asksNothing", lambda said: said == question, NOTICED_SECONDS)
        _keep_the_pane(machine, check_dir, lab, "settings-asks-after-the-edit.txt")
        expect(asks == question, f"after the edit, {ASKS_NOTHING}'s row in Settings says {asks!r}, not {question!r}")
        _press(machine, f"plugin.{ASKS_NOTHING}.decline", f"declining {ASKS_NOTHING} in Settings")
        off = _wait_for_disk(machine, lambda: ASKS_NOTHING in (((_read_json(machine, PLUGIN_SETTINGS) or {}).get("disabled")) or []),
                             NOTICED_SECONDS)  # fmt: skip
        expect(off, f"Decline in Settings of {ASKS_NOTHING}, which asks for nothing, left it switched on: "
                    f"{_read_json(machine, PLUGIN_SETTINGS)!r}")
        after = _count_of_runs(machine, runs)
        expect(after == counted, f"{ASKS_NOTHING}'s code was changed and nobody allowed it again, and it ran: its count went "
                                 f"from {counted} to {after!r} between the edit and Decline in Settings")

        _switch(machine, f"plugin.{ASKS_NOTHING}.enabled", True, f"switching {ASKS_NOTHING} on again")
        asks = _wait_until(machine, f"plugin.{ASKS_NOTHING}.asksNothing", lambda said: said == question, NOTICED_SECONDS)
        expect(asks == question, f"switched on again, {ASKS_NOTHING}'s row in Settings says {asks!r}, not {question!r}")
        _press(machine, f"plugin.{ASKS_NOTHING}.allow", f"allowing {ASKS_NOTHING} in Settings")
        edited = scene.github.tree_in_guest(f"{UDECK_HOME}/plugins/{ASKS_NOTHING}", "hashing the edited folder")
        held = _wait_for_disk(machine, lambda: (((_read_json(machine, GRANTS) or {}).get("byPlugin") or {}).get(ASKS_NOTHING)
                                                or {}).get("decidedForTree") == edited, NOTICED_SECONDS)  # fmt: skip
        grant = ((_read_json(machine, GRANTS) or {}).get("byPlugin") or {}).get(ASKS_NOTHING) or {}
        expect(held and grant.get("decidedForVersion") == "1.0.0",
               f"after Allow in Settings, {GRANTS} holds {grant!r}: the decision for the edited tree, {edited}")
        ran = _wait_for_disk(machine, lambda: (_count_of_runs(machine, runs) or 0) > counted, CARD_SECONDS)
        _keep_the_pane(machine, check_dir, lab, "settings-allowed.txt")
        expect(ran, f"allowed in Settings, {ASKS_NOTHING} did not run within {CARD_SECONDS}s: its count is "
                    f"{_count_of_runs(machine, runs)!r}, as it was before, {counted}")
    finally:
        scene.close()


def check_switch_to_verified_names_both(machine, check_dir, lab):
    """A pull request's copy over the verified one, and back with **Switch to verified**: each warning names both, nothing changes until it is confirmed.

    The verified uptime 1.0.0 is installed from the catalogue, placed with a
    setting value, and allowed. **Install** on uptime listed from pull request
    #3 warns first — *uptime is the verified 1.0.0 from github.com/…;
    installing 1.0.1 from pull request #3 at … replaces it* — and while the
    warning is up the folder and the record are what they were. Confirmed, the
    record is the pull request's and its `previous` the verified copy.
    **Switch to verified 1.0.0** on its row warns the other way round, and
    again nothing changes until it is confirmed. Then the row says
    **Verified**, the record is the default branch's at c1, the window is the
    one it was, the setting value is kept, and the card runs 1.0.0 without
    asking — the decision made for that version holds again.

    **Red for**: a switch of source made without a word, or with a warning
    that names one copy only, a button that acts before it is confirmed, and a
    switch that loses the window, the settings or the decision.
    """
    scene = _prepare(machine, check_dir, lab, main="c1", pulls=PULLS)
    try:
        _the_catalogue_read(scene, since=0, commit="c1")
        _install(scene, UPTIME)
        _place(scene, UPTIME, setting_value=True)
        _allow_and_read_the_card(scene, UPTIME, "the verified copy")
        window = _the_window(machine, UPTIME, "reading the window before the switches")
        values = ((_read_json(machine, PLUGIN_SETTINGS) or {}).get("values") or {}).get(UPTIME)
        head = scene.github.commit("pr3")
        c1 = scene.github.commit("c1")

        ui.plugins_pane(machine, "opening Settings → Plugins")
        _look_up(scene, PULL_LINK, "the pull request")
        _expect_a_warning_that_changes_nothing(
            scene, f"link.{UPTIME}", "Install on the pull request's uptime",
            SWITCH_FROM_VERIFIED.format(id=UPTIME, old="1.0.0", repository=config.PLUGINS_REPOSITORY, new="1.0.1",
                                        number=PULL, commit=head[:7]),
            tree=scene.github.tree("c1", f"plugins/{UPTIME}"))  # fmt: skip
        record = _operate(scene, f"link.{UPTIME}.confirm", "confirming the switch to the pull request",
                          lambda r: r is not None and (r.get("ref") or {}).get("kind") == "pr")
        expect(record is not None, f"the switch to the pull request was confirmed and installed.json says {_read_json(machine, INSTALLED)!r}")
        previous = record.get("previous") or {}
        expect(previous.get("commit") == c1 and (previous.get("ref") or {}).get("kind") == "default"
               and previous.get("version") == "1.0.0",
               f"after the switch, the record's previous is {previous!r}, not the verified 1.0.0 at c1")  # fmt: skip
        _close_the_link_sheet(scene, "after the switch")
        _keep_the_pane(machine, check_dir, lab, "the-pull-requests-copy.txt")

        _expect_a_warning_that_changes_nothing(
            scene, f"plugin.{UPTIME}", "Switch to verified",
            SWITCH_TO_VERIFIED.format(id=UPTIME, old="1.0.1", number=PULL, commit=head[:7], new="1.0.0",
                                      repository=config.PLUGINS_REPOSITORY),
            tree=scene.github.tree("pr3", f"plugins/{UPTIME}"), button=f"plugin.{UPTIME}.switchToVerified")  # fmt: skip
        record = _operate(scene, f"plugin.{UPTIME}.confirm", "confirming Switch to verified",
                          lambda r: r is not None and (r.get("ref") or {}).get("kind") == "default")
        expect(record is not None and record.get("commit") == c1
               and (record.get("verification") or {}).get("status") == "verified",
               f"after Switch to verified, installed.json says {record!r}")  # fmt: skip
        mark = _wait_until(machine, f"plugin.{UPTIME}.mark", lambda said: said == VERIFIED, NOTICED_SECONDS)
        _keep_the_pane(machine, check_dir, lab, "verified-again.txt")
        expect(mark == VERIFIED, f"after Switch to verified, the row's mark says {mark!r}")
        expect(_the_window(machine, UPTIME, "reading the window after the switches") == window,
               f"the switches moved or replaced {UPTIME}'s window")
        kept = ((_read_json(machine, PLUGIN_SETTINGS) or {}).get("values") or {}).get(UPTIME)
        expect(kept == values and values, f"the switches lost {UPTIME}'s setting values: {values!r} before, {kept!r} after")
        _the_card_without_asking(scene, UPTIME, "1.0.0", "verified again")
    finally:
        scene.close()


def check_a_merged_pull_request_becomes_verified(machine, check_dir, lab):
    """Pull request #3 squash-merged as exactly its head: **Check now**, and its copy is **Verified** — nothing downloaded, nothing swapped, nothing asked.

    uptime installed from pull request #3, placed and allowed, runs as 1.0.1;
    what **Look up** heard of the pull request — open, at pr3 — is in
    `followed.json` from the install on, and GitHub was asked about it once,
    by **Look up**. The fake then merges it the way GitHub squash-merges: `main` moves to s1,
    a new commit on c1 whose every plugin folder has pr3's tree, and the pull
    request is closed and merged as s1. After **Check now**: `installed.json`
    says the default branch's `main` at s1, Verified by the official source,
    the tree and version it had; the row says **Verified**; the folder is the
    very one that was there, every file's inode and time unchanged; the log
    holds no file of uptime and no question about the pull request — the head
    having its tree is the whole proof — and what uDeck had heard of the pull
    request is gone; the window is the one it was, the decision is as it was,
    and the card runs 1.0.1 without asking and without **Unverified** in its
    header.

    **Red for**: a merged copy left Unverified, adopted by downloading it again
    or by swapping its folder, a question asked again about code that did not
    change, and a merge that costs a request when the head says it all.
    """
    scene = _prepare(machine, check_dir, lab, main="c1", pulls=PULLS)
    try:
        _the_catalogue_read(scene, since=0, commit="c1")
        ui.plugins_pane(machine, "opening Settings → Plugins")
        head = scene.github.commit("pr3")
        _look_up(scene, PULL_LINK, "the pull request")
        record, _ = _install_from_the_link(scene, UPTIME, "the pull request")
        _expect_an_unverified_record(record, ref={"kind": "pr", "name": PULL}, commit=head, version="1.0.1")
        _close_the_link_sheet(scene, "after installing")
        _place(scene, UPTIME)
        _the_card_says_unverified(scene, UPTIME, "the pull request's copy")
        window = _the_window(machine, UPTIME, "reading the window before the merge")
        grant = _expect_the_decision_for(machine, UPTIME, "1.0.1", "before the merge")
        folder = _identity(machine, UPTIME, "before the merge")
        # What Look up heard, kept at install: the only question about the pull request so far is Look up's.
        _wait_for_disk(machine, lambda: _followed(machine, UPTIME) is not None, NOTICED_SECONDS)
        seeded = _followed(machine, UPTIME) or {}
        asked = [r for r in _since(scene, 0) if r.is_api and r.path == f"/api/repos/{config.PLUGINS_REPOSITORY}/pulls/{PULL}"]
        expect((seeded.get("number"), seeded.get("state"), seeded.get("merged"), seeded.get("head")) == (int(PULL), "open", False, head)
               and len(asked) == 1,
               f"what Look up heard of pull request #3 was not kept at install: {FOLLOWED} holds {_read_json(machine, FOLLOWED)!r}, "
               f"and uDeck asked about the pull request {len(asked)} times")  # fmt: skip

        _merge(scene, "s1", "squash-merging pull request #3 as exactly its head")
        ui.plugins_pane(machine, "opening Settings → Plugins after the merge")
        before = _count(scene)
        _press(machine, "catalogue.checkNow", "pressing Check now after the merge")
        adopted = _wait_for_disk(machine, lambda: ((_record(machine, UPTIME) or {}).get("ref") or {}).get("kind") == "default",
                                 OPERATION_SECONDS)  # fmt: skip
        heard = _since(scene, before)
        record = _record(machine, UPTIME) or {}
        expect(adopted, f"pull request #3 was merged as exactly uptime's copy, and after Check now installed.json still says "
                        f"{record!r}: the copy was not recorded as what was merged")
        s1 = scene.github.commit("s1")
        _expect_a_whole_record(record, commit=s1, tree=scene.github.tree("pr3", f"plugins/{UPTIME}"), version="1.0.1",
                               pinned=False, previous=None)
        expect(not _files_fetched(heard, UPTIME), f"the merged copy was adopted by fetching {described(_files_fetched(heard, UPTIME))}")
        asked = [r for r in heard if r.is_api and "/pulls/" in r.path]
        expect(not asked, f"the head has uptime's tree, and uDeck still asked {described(asked)}")
        mark = _wait_until(machine, f"plugin.{UPTIME}.mark", lambda said: said == VERIFIED, NOTICED_SECONDS)
        _keep_the_pane(machine, check_dir, lab, "verified-by-the-merge.txt")
        expect(mark == VERIFIED, f"uptime's copy is what was merged, and its row says {mark!r}")
        expect(_identity(machine, UPTIME, "after the merge") == folder,
               "adopting the merged copy replaced its folder or a file in it: an inode or a time changed")
        expect(UPTIME not in ((_read_json(machine, FOLLOWED) or {}).get("pulls") or {}),
               f"uptime is the default branch's now, and {FOLLOWED} still follows its pull request: {_read_json(machine, FOLLOWED)!r}")
        expect(_the_window(machine, UPTIME, "reading the window after the merge") == window, "the merge moved or replaced uptime's window")
        expect(_expect_the_decision_for(machine, UPTIME, "1.0.1", "after the merge") == grant,
               "adopting the merged copy changed the permission decision")
        _the_card_without_asking(scene, UPTIME, "1.0.1", "verified by the merge")
        _the_card_header_says_nothing(scene, UPTIME, "verified by the merge")
    finally:
        scene.close()


def check_merged_with_changes_offers_the_verified(machine, check_dir, lab):
    """Pull request #3 merged with a maintainer's change: the row says *the verified version differs — update*, and **Update** makes it Verified.

    uptime 1.0.1 installed from pull request #3; the fake then squash-merges
    it as s2, where a maintainer made uptime 1.0.2 — the head and the commit it
    was merged as have another tree than the copy. After **Check now**: the
    log holds the question about pull request #3, and no file of uptime; the
    copy is as it was, the pull request's, Unverified; its row says *Pull
    request #3 was merged, and the verified version differs — update* with
    **Update**, the catalogue row of uptime that it was merged, and Settings
    counts one update waiting. **Update** first names both copies — the pull
    request's going, the verified 1.0.2 coming — and changes nothing until it
    is confirmed; then the record is `main`'s at s2, Verified, 1.0.2, with the
    pull request's copy as `previous`.

    **Red for**: a merge with changes made by itself — what comes is not what
    was allowed — or adopted as if it were the copy, an offer nobody can see,
    and one press called two names — the catalogue row's button says
    **Update**, as the plugin's row does.
    """
    scene = _prepare(machine, check_dir, lab, main="c1", pulls=PULLS)
    try:
        _the_catalogue_read(scene, since=0, commit="c1")
        ui.plugins_pane(machine, "opening Settings → Plugins")
        head = scene.github.commit("pr3")
        _look_up(scene, PULL_LINK, "the pull request")
        installed, _ = _install_from_the_link(scene, UPTIME, "the pull request")
        _close_the_link_sheet(scene, "after installing")

        _merge(scene, "s2", "squash-merging pull request #3 with uptime made 1.0.2")
        before = _count(scene)
        _press(machine, "catalogue.checkNow", "pressing Check now after the merge")
        said = _wait_until(machine, f"plugin.{UPTIME}.pullRequest", lambda said: said == MERGED_DIFFERS.format(number=PULL),
                           CATALOGUE_SECONDS)  # fmt: skip
        heard = _since(scene, before)
        dump = _keep_the_pane(machine, check_dir, lab, "merged-with-changes.txt")
        expect(said == MERGED_DIFFERS.format(number=PULL),
               f"pull request #3 was merged as something else, and uptime's row says {said!r}; uDeck asked {described(heard)}")
        asked = [r for r in heard if r.is_api and r.path == f"/api/repos/{config.PLUGINS_REPOSITORY}/pulls/{PULL}"]
        expect(len(asked) == 1, f"after Check now uDeck asked about pull request #3 {len(asked)} times: {described(heard)}")
        expect(not _files_fetched(heard, UPTIME), f"the merge with changes fetched {described(_files_fetched(heard, UPTIME))} by itself")
        expect(_the_copy(_record(machine, UPTIME)) == _the_copy(installed) and _status(machine, UPTIME) == "unverified",
               f"the merge with changes changed the copy's record: {_record(machine, UPTIME)!r}")
        state = ui.says(ui.element(dump, f"catalogue.{UPTIME}.state"))
        wanted = f"{INSTALLED_HERE_UNVERIFIED.format(line=f'pull request #{PULL}')} — {CATALOGUE_MERGED_DIFFERS}"
        expect(state == wanted, f"uptime's catalogue row says {state!r}, not {wanted!r}")
        waiting = ui.says(ui.element(dump, "catalogue.updatesWaiting"))
        expect(waiting == "1 update is waiting", f"Settings says {waiting!r} of the updates waiting, not that one is")
        expect(ui.element(dump, f"plugin.{UPTIME}.update") is not None, "the row says to update, and offers no Update")
        # One press, one name: the catalogue row's button for the verified copy says what the plugin's row's says,
        # **Update**. The walk reads no button's words — a SwiftUI button lists neither AXTitle nor AXDescription,
        # and the helper reads what System Events reads (e2e/guest/ax.swift) — so the word is told by the button's
        # width, which is the plugin row's Update's: *Switch to verified 1.0.2* is more than twice as wide (69
        # against 159 to 161 px, run 38318972153). A screenshot of the row is kept for a person to read.
        button = ui.element(dump, f"catalogue.{UPTIME}.switchToVerified")
        update = ui.element(dump, f"plugin.{UPTIME}.update")
        expect(button is not None and update is not None and abs(button.width - update.width) <= SAME_WORD_PX,
               f"the plugin's row says to update, and the catalogue row's button for the same press is "
               f"{button.width if button else 'not there'} px wide against the {update.width if update else '?'} px of "
               f"{UPDATE}: not the same word")  # fmt: skip
        _show_the_catalogue_row(scene, f"catalogue.{UPTIME}.switchToVerified", "the catalogue row merged with changes")

        _expect_a_warning_that_changes_nothing(
            scene, f"plugin.{UPTIME}", "Update to the verified version",
            SWITCH_TO_VERIFIED.format(id=UPTIME, old="1.0.1", number=PULL, commit=head[:7], new="1.0.2",
                                      repository=config.PLUGINS_REPOSITORY),
            tree=scene.github.tree("pr3", f"plugins/{UPTIME}"), button=f"plugin.{UPTIME}.update")  # fmt: skip
        record = _operate(scene, f"plugin.{UPTIME}.confirm", "confirming the update to the verified version",
                          lambda r: r is not None and (r.get("ref") or {}).get("kind") == "default")
        s2 = scene.github.commit("s2")
        expect(record is not None, f"the update to the verified version was confirmed, and installed.json says {_read_json(machine, INSTALLED)!r}")
        previous = record.get("previous") or {}
        _expect_a_whole_record(record, commit=s2, tree=scene.github.tree("s2", f"plugins/{UPTIME}"), version="1.0.2",
                               pinned=False, previous=previous)
        expect((previous.get("ref") or {}) == {"kind": "pr", "name": PULL} and previous.get("commit") == head,
               f"after the update, previous is {previous!r}, not pull request #3's copy")
        mark = _wait_until(machine, f"plugin.{UPTIME}.mark", lambda said: said == VERIFIED, NOTICED_SECONDS)
        _keep_the_pane(machine, check_dir, lab, "the-verified-version.txt")
        expect(mark == VERIFIED, f"after the update to the verified version, the row's mark says {mark!r}")
    finally:
        scene.close()


def check_merged_then_moved_on_becomes_verified(machine, check_dir, lab):
    """Pull request #3 merged as exactly its head, and `main` moved past it: the copy is recorded at the commit it was merged as, and the head's version offered.

    uptime 1.0.1 installed from pull request #3, uDeck started with **Update
    verified plugins by themselves** off. The fake squash-merges it as s1 and
    moves `main` on to m1, where uptime is 1.0.2: the head has another tree,
    the commit the pull request was merged as has the copy's. After **Check
    now** the log holds the question about pull request #3 and the listing of
    s1, and no file of uptime; `installed.json` says `main` at s1, Verified,
    1.0.1, the tree it had; the row says **Verified** and *1.0.2 available* —
    the update the head has, as for any verified copy — and what uDeck had
    heard of the pull request is gone. Then **Update verified plugins by
    themselves** is clicked on, and after the next **Check now** the copy
    updates itself to m1's 1.0.2, with nothing pressed for it, the copy
    recorded at s1 as its `previous`.

    **Red for**: a merge missed because the default branch moved before uDeck
    looked, a copy recorded at a commit that does not have it, and an adopted
    copy that does not go on as any verified copy does.
    """
    scene = _prepare(machine, check_dir, lab, main="c1", updates_itself=False, pulls=PULLS)
    try:
        _the_catalogue_read(scene, since=0, commit="c1")
        ui.plugins_pane(machine, "opening Settings → Plugins")
        _look_up(scene, PULL_LINK, "the pull request")
        _install_from_the_link(scene, UPTIME, "the pull request")
        _close_the_link_sheet(scene, "after installing")
        folder = _identity(machine, UPTIME, "before the merge")

        _merge(scene, "s1", "squash-merging pull request #3 as exactly its head, and main moving on to m1", main="m1")
        before = _count(scene)
        _press(machine, "catalogue.checkNow", "pressing Check now after the merge")
        adopted = _wait_for_disk(machine, lambda: ((_record(machine, UPTIME) or {}).get("ref") or {}).get("kind") == "default",
                                 CATALOGUE_SECONDS)  # fmt: skip
        heard = _since(scene, before)
        record = _record(machine, UPTIME) or {}
        expect(adopted, f"pull request #3 was merged as exactly uptime's copy at s1, and after Check now installed.json says "
                        f"{record!r}; uDeck asked {described(heard)}")
        s1 = scene.github.commit("s1")
        _expect_a_whole_record(record, commit=s1, tree=scene.github.tree("pr3", f"plugins/{UPTIME}"), version="1.0.1",
                               pinned=False, previous=None, against=scene.github.commit("m1"))
        api = f"/api/repos/{config.PLUGINS_REPOSITORY}"
        expect(any(r.is_api and r.path == f"{api}/pulls/{PULL}" for r in heard),
               f"uDeck knew the pull request was merged as s1 without asking about it: {described(heard)}")
        expect(any(r.is_api and r.path == f"{api}/git/trees/{s1}" for r in heard),
               f"uDeck recorded the copy at s1 without listing s1: {described(heard)}")
        expect(not _files_fetched(heard, UPTIME), f"the merged copy was adopted by fetching {described(_files_fetched(heard, UPTIME))}")
        expect(_identity(machine, UPTIME, "after the merge") == folder, "adopting the merged copy replaced its folder or a file in it")
        offer = _wait_until(machine, f"plugin.{UPTIME}.offer", lambda said: said == AVAILABLE.format(version="1.0.2"),
                            NOTICED_SECONDS)  # fmt: skip
        dump = _keep_the_pane(machine, check_dir, lab, "verified-at-the-merge.txt")
        mark = ui.says(ui.element(dump, f"plugin.{UPTIME}.mark"))
        expect(mark == VERIFIED and offer == AVAILABLE.format(version="1.0.2"),
               f"recorded at s1, uptime's row says {mark!r} · {offer!r}, not {VERIFIED!r} · {AVAILABLE.format(version='1.0.2')!r}")
        expect(UPTIME not in ((_read_json(machine, FOLLOWED) or {}).get("pulls") or {}),
               f"uptime is the default branch's now, and {FOLLOWED} still follows its pull request: {_read_json(machine, FOLLOWED)!r}")

        # A verified copy like any other: switched on, the next read updates it by itself.
        _switch(machine, "catalogue.autoUpdate", True, "switching Update verified plugins by themselves on")
        _press(machine, "catalogue.checkNow", "pressing Check now with updates by themselves on")
        m1 = scene.github.commit("m1")
        updated = _wait_for_disk(machine, lambda: (_record(machine, UPTIME) or {}).get("commit") == m1, OPERATION_SECONDS)
        record = _record(machine, UPTIME) or {}
        _keep_the_pane(machine, check_dir, lab, "updated-by-itself.txt")
        expect(updated and record.get("automatic") is True and record.get("version") == "1.0.2",
               f"the copy adopted at s1 did not update itself to m1's 1.0.2: installed.json says {record!r}")
        previous = record.get("previous") or {}
        expect(previous.get("commit") == s1 and (previous.get("ref") or {}).get("kind") == "default",
               f"after updating itself, previous is {previous!r}, not the copy recorded at s1")
    finally:
        scene.close()


def check_merged_into_another_branch_stays_unverified(machine, check_dir, lab):
    """Pull request #3 merged as exactly its head, but into `next`, not `main`: its copy stays **Unverified**, and that merge is never listed.

    uptime 1.0.1 installed from pull request #3. The fake merges the pull
    request into `next` — a branch other than the default one — as s1, whose
    uptime is exactly the pull request's, and `main` stays at c1. After
    **Check now** `followed.json` keeps that it was merged into `next`, with
    no commit and no tree; the log holds the question about pull request #3,
    no listing of s1 and no file of uptime, and in the twenty seconds after,
    the record stays the pull request's, Unverified, as it was installed. The
    row says **Unverified** and nothing of the pull request, **Switch to
    verified** is there, and the catalogue row says only *Installed here from
    pull request #3: unverified*.

    **Red for**: a merge into a branch nobody verifies taken for a merge into
    the default branch — the copy recorded as `main`'s at a commit `main` does
    not have, and shown **Verified** — and a merge said that verified nothing.
    """
    scene = _prepare(machine, check_dir, lab, main="c1", pulls=PULLS)
    try:
        _the_catalogue_read(scene, since=0, commit="c1")
        ui.plugins_pane(machine, "opening Settings → Plugins")
        _look_up(scene, PULL_LINK, "the pull request")
        installed, _ = _install_from_the_link(scene, UPTIME, "the pull request")
        _close_the_link_sheet(scene, "after installing")

        _merge(scene, "s1", f"merging pull request #3 into {NEXT} as exactly its head, main staying at c1", main="c1", into=NEXT)
        before = _count(scene)
        _press(machine, "catalogue.checkNow", f"pressing Check now after the merge into {NEXT}")
        heard_of = _wait_for_disk(machine, lambda: (_followed(machine, UPTIME) or {}).get("merged") is True, CATALOGUE_SECONDS)
        followed = _followed(machine, UPTIME) or {}
        expect(heard_of and followed.get("base") == NEXT and "mergeCommit" not in followed and "mergeTree" not in followed,
               f"pull request #3 was merged into {NEXT}, and {FOLLOWED} keeps {followed!r}: not that it was merged there, "
               f"with nothing of the commit")  # fmt: skip
        # An adoption follows the asking within a second or two, when the folders are hashed after the read.
        heard = _left_alone(scene, before)
        record = _record(machine, UPTIME)
        expect(_the_copy(record) == _the_copy(installed) and _status(machine, UPTIME) == "unverified",
               f"pull request #3 was merged into {NEXT}, not main, and installed.json says {record!r}")
        api = f"/api/repos/{config.PLUGINS_REPOSITORY}"
        s1 = scene.github.commit("s1")
        expect(any(r.is_api and r.path == f"{api}/pulls/{PULL}" for r in heard),
               f"after Check now uDeck did not ask about pull request #3: {described(heard)}")
        listed = [r for r in heard if r.is_api and r.path == f"{api}/git/trees/{s1}"]
        expect(not listed, f"uDeck listed s1, the commit pull request #3 was merged into {NEXT} as: {described(listed)}")
        expect(not _files_fetched(heard, UPTIME), f"the merge into {NEXT} fetched {described(_files_fetched(heard, UPTIME))}")
        mark = _wait_until(machine, f"plugin.{UPTIME}.mark", lambda said: said == UNVERIFIED, NOTICED_SECONDS)
        dump = _keep_the_pane(machine, check_dir, lab, "merged-into-next.txt")
        expect(mark == UNVERIFIED, f"pull request #3 was merged into {NEXT}, and uptime's row says {mark!r}")
        said = ui.element(dump, f"plugin.{UPTIME}.pullRequest")
        expect(said is None, f"a merge into {NEXT} verified nothing, and uptime's row says {ui.says(said)!r} of it")
        expect(ui.element(dump, f"plugin.{UPTIME}.switchToVerified") is not None,
               f"the copy is Unverified and is not offered Switch to verified: "
               f"{[c.identifier for c in ui.controls(dump) if UPTIME in c.identifier]}")  # fmt: skip
        state = ui.says(ui.element(dump, f"catalogue.{UPTIME}.state"))
        wanted = INSTALLED_HERE_UNVERIFIED.format(line=f"pull request #{PULL}")
        expect(state == wanted, f"uptime's catalogue row says {state!r}, not {wanted!r}")
    finally:
        scene.close()


def check_a_closed_pull_request_keeps_running(machine, check_dir, lab):
    """Pull request #3 closed without being merged: its row says so, the plugin keeps running, nothing is removed; opened again, it is not said.

    uptime installed from pull request #3, placed and allowed, has run. The
    fake closes the pull request, unmerged. After **Check now** the row says
    *Pull request #3 was closed without being merged; the plugin keeps
    running*, the catalogue row says it was closed, and **Switch to verified**
    and **Remove** are there; the folder, the record, the window and the
    decision are as they were, and the card runs again, its count of runs
    going up. Opened again, and **Check now**: uDeck asks about it again,
    `followed.json` says it is open, and the row says **Unverified** and
    nothing more.

    **Red for**: a closed pull request's copy removed, stopped or switched
    without a press, a warning nobody sees, and one that outlives the pull
    request being opened again.
    """
    scene = _prepare(machine, check_dir, lab, main="c1", pulls=PULLS)
    try:
        _the_catalogue_read(scene, since=0, commit="c1")
        ui.plugins_pane(machine, "opening Settings → Plugins")
        _look_up(scene, PULL_LINK, "the pull request")
        installed, _ = _install_from_the_link(scene, UPTIME, "the pull request")
        _close_the_link_sheet(scene, "after installing")
        _place(scene, UPTIME)
        card = _the_card_says_unverified(scene, UPTIME, "the pull request's copy")
        window = _the_window(machine, UPTIME, "reading the window before the pull request was closed")
        grant = _expect_the_decision_for(machine, UPTIME, "1.0.1", "before the pull request was closed")
        folder = _identity(machine, UPTIME, "before the pull request was closed")

        scene.github.tell("closing pull request #3 without merging it", pulls={PULL: {**PULLS[PULL], "state": "closed"}})
        ui.plugins_pane(machine, "opening Settings → Plugins after the pull request was closed")
        _press(machine, "catalogue.checkNow", "pressing Check now after the pull request was closed")
        said = _wait_until(machine, f"plugin.{UPTIME}.pullRequest", lambda said: said == CLOSED_UNMERGED.format(number=PULL),
                           CATALOGUE_SECONDS)  # fmt: skip
        dump = _keep_the_pane(machine, check_dir, lab, "closed.txt")
        expect(said == CLOSED_UNMERGED.format(number=PULL), f"pull request #3 was closed, and uptime's row says {said!r}")
        state = ui.says(ui.element(dump, f"catalogue.{UPTIME}.state"))
        wanted = f"{INSTALLED_HERE_UNVERIFIED.format(line=f'pull request #{PULL}')} — {CATALOGUE_CLOSED}"
        expect(state == wanted, f"uptime's catalogue row says {state!r}, not {wanted!r}")
        offered = [f"plugin.{UPTIME}.switchToVerified", f"plugin.{UPTIME}.remove"]
        expect(all(ui.element(dump, button) is not None for button in offered),
               f"a closed pull request's copy is not offered {offered}: {[c.identifier for c in ui.controls(dump) if UPTIME in c.identifier]}")
        expect(_the_copy(_record(machine, UPTIME)) == _the_copy(installed) and _status(machine, UPTIME) == "unverified",
               f"closing the pull request changed the copy's record: {_record(machine, UPTIME)!r}")
        expect(_identity(machine, UPTIME, "after the pull request was closed") == folder, "closing the pull request touched the copy")
        expect(_the_window(machine, UPTIME, "reading the window after the pull request was closed") == window,
               "closing the pull request moved or removed uptime's window")
        expect(_expect_the_decision_for(machine, UPTIME, "1.0.1", "after the pull request was closed") == grant,
               "closing the pull request changed the permission decision")
        runs = int(card[RUNS])
        _open_the_panel(machine, "opening the panel after the pull request was closed")
        later = _read_the_card(scene, UPTIME, "after the pull request was closed",
                               lambda card: card.get(RUNS, "").isdigit() and int(card[RUNS]) > runs,
                               f"it had run more than {runs} times")  # fmt: skip
        _put_the_panel_away(machine, "after the pull request was closed")
        expect(int(later[RUNS]) > runs, f"the closed pull request's copy stopped: its card says {later!r}")

        scene.github.tell("opening pull request #3 again", pulls=PULLS)
        ui.plugins_pane(machine, "opening Settings → Plugins after the pull request was opened again")
        before = _count(scene)
        _press(machine, "catalogue.checkNow", "pressing Check now after the pull request was opened again")
        reopened = _wait_for_disk(machine, lambda: (_followed(machine, UPTIME) or {}).get("state") == "open", CATALOGUE_SECONDS)
        heard = _since(scene, before)
        asked = [r for r in heard if r.is_api and r.path == f"/api/repos/{config.PLUGINS_REPOSITORY}/pulls/{PULL}"]
        expect(reopened and asked, f"pull request #3 was opened again, and after Check now {FOLLOWED} keeps "
                                   f"{_followed(machine, UPTIME)!r}; uDeck asked {described(heard)}")
        _wait_until(machine, f"plugin.{UPTIME}.pullRequest", lambda said: said is None, NOTICED_SECONDS)
        dump = _keep_the_pane(machine, check_dir, lab, "opened-again.txt")
        # The row itself is there, and says no more than it is Unverified.
        mark = ui.says(ui.element(dump, f"plugin.{UPTIME}.mark"))
        said = ui.element(dump, f"plugin.{UPTIME}.pullRequest")
        expect(mark == UNVERIFIED and said is None,
               f"pull request #3 was opened again, and uptime's row says {mark!r} · {ui.says(said) if said else None!r}, "
               f"not {UNVERIFIED!r} and nothing of the pull request")  # fmt: skip
    finally:
        scene.close()


def check_unverified_only_offers(machine, check_dir, lab):
    """Pull request #3 moves on: its copy is offered **Update** and *What changed*, by **Check now** and by a read at launch — never installed by itself.

    uptime 1.0.1 installed from pull request #3, placed and allowed. The fake
    moves the pull request's head from pr3 to p2 — the same version, the same
    manifest, one paragraph more in its script. After **Check now** the log
    holds the question about the pull request, the listing of p2 and one
    comparison of pr3 with p2, and not one request to the raw host — nothing
    of p2 is new to uDeck but its listing; the record and the folder are as
    they were; the row says *Changed in pull request #3, still 1.0.1* with
    **Update** and *What changed*, and nothing of a rewritten history, and
    Settings counts one update waiting. Then uDeck is ended and started again
    with the catalogue two days old and all but nine of the hour's requests
    spent elsewhere on the connection (the fake's `spent`): the read at launch
    reads the catalogue and does not ask about the pull request — the reserve
    is the operator's — and its row says *Pull request #3 not checked since …*
    and still offers **Update**; **Check now**, a read asked for, asks again,
    the comparison not repeated, and that line goes. Ended and started again
    with the catalogue two days old once more, nothing spent elsewhere, the read
    at launch asks about the pull request by itself, and the row offers
    **Update** and *What changed*. **Update**, pressed: the record is the pull
    request's at p2, unverified, with pr3's copy as `previous`, and the card
    asks before it runs. Last, a read left for later whole: **Check now** with
    all but nine of the hour's requests spent elsewhere leaves fewer than the
    reserve, uDeck is ended and started again with the catalogue two days old,
    and the read at launch asks nothing at all — not even the catalogue's head
    — uDeck's log says the catalogue was left for later and the pull request
    left as it was, and `followed.json` says since when; Settings → Plugins
    opened with the hour's requests all spent, its own read refused by the
    limit, the row says *Pull request #3 not checked since …*.

    **Red for**: an unverified copy updated without a press, an offer only
    **Check now** finds, an offer said against the catalogue's head instead of
    its own line's, a read that spends the reserve on what nobody asked for and
    one that does not say so — whether it stopped at the pull request or before
    the catalogue — and an update that runs new code on the old decision.
    """
    scene = _prepare(machine, check_dir, lab, main="c1", pulls=PULLS)
    try:
        _the_catalogue_read(scene, since=0, commit="c1")
        ui.plugins_pane(machine, "opening Settings → Plugins")
        pr3, p2 = scene.github.commit("pr3"), scene.github.commit("p2")
        _look_up(scene, PULL_LINK, "the pull request")
        installed, _ = _install_from_the_link(scene, UPTIME, "the pull request")
        _close_the_link_sheet(scene, "after installing")
        _place(scene, UPTIME)
        _the_card_says_unverified(scene, UPTIME, "the pull request's copy")
        folder = _identity(machine, UPTIME, "before the pull request moved on")

        _move_the_pull_request(scene, "p2", "moving pull request #3 on to p2")
        ui.plugins_pane(machine, "opening Settings → Plugins after the pull request moved on")
        before = _count(scene)
        _press(machine, "catalogue.checkNow", "pressing Check now after the pull request moved on")
        changed = CHANGED_STILL.format(line=f"pull request #{PULL}", version="1.0.1")
        offer = _wait_until(machine, f"plugin.{UPTIME}.offer", lambda said: said == changed, CATALOGUE_SECONDS)
        heard = _since(scene, before)
        dump = _keep_the_pane(machine, check_dir, lab, "offered-along-the-pull-request.txt")
        expect(offer == changed, f"pull request #3 moved on to p2, and after Check now uptime's row says {offer!r}, "
                                 f"not {changed!r}; uDeck asked {described(heard)}")
        api = f"/api/repos/{config.PLUGINS_REPOSITORY}"
        compared = [r for r in heard if r.is_api and r.path == f"{api}/compare/{pr3}...{p2}"]
        expect(any(r.is_api and r.path == f"{api}/pulls/{PULL}" for r in heard)
               and any(r.is_api and r.path == f"{api}/git/trees/{p2}" for r in heard) and len(compared) == 1,
               f"after Check now uDeck did not ask about pull request #3, list p2 and compare pr3 with p2 once: "
               f"{described(heard)}")  # fmt: skip
        raw = [r for r in heard if r.is_raw]
        expect(not raw, f"nothing of p2 is new to uDeck but its listing, and it fetched {described(raw)}")
        expect(ui.element(dump, f"plugin.{UPTIME}.update") is not None and ui.element(dump, f"plugin.{UPTIME}.whatChanged") is not None,
               f"the row offers {changed!r} without Update and What changed: "
               f"{[c.identifier for c in ui.controls(dump) if UPTIME in c.identifier]}")  # fmt: skip
        expect(ui.element(dump, f"plugin.{UPTIME}.rewritten") is None,
               f"p2 continues pr3, and the row says {ui.says(ui.element(dump, f'plugin.{UPTIME}.rewritten'))!r}")
        waiting = ui.says(ui.element(dump, "catalogue.updatesWaiting"))
        expect(waiting == ONE_UPDATE_WAITING, f"Settings says {waiting!r} of the updates waiting, not {ONE_UPDATE_WAITING!r}")
        _expect_the_copy_as_it_was(scene, installed, folder, "after the pull request moved on")
        followed = _followed(machine, UPTIME) or {}
        expect(followed.get("head") == p2 and (followed.get("history") or {}).get("rewritten") is False
               and (followed.get("history") or {}).get("from") == pr3,
               f"{FOLLOWED} keeps {followed!r} of pull request #3: not its head at p2, continuing pr3")  # fmt: skip

        # The reserve: a read nobody asked for leaves the pull request unasked, and says so.
        app.quit_app(machine, "ending uDeck before the reserve is all that is left")
        _age_the_catalogue(machine, AGED_DAYS)
        before = _count(scene)
        _leave_the_reserve(scene, "all but nine of the hour's requests spent elsewhere")
        mark = scene.log.mark("marking the launch with the reserve all that is left")
        app.launch(machine)
        heard = _the_launch_read(scene, before)
        asked = [r for r in heard if r.is_api and r.path == f"{api}/pulls/{PULL}"]
        expect(not asked, f"the read at launch, nobody asking, with the reserve all that was left, asked {described(asked)}")
        _expect_uDeck_said(scene, mark, LEFT_AS_THEY_WERE.format(ids=UPTIME), "after the read at launch within the reserve")
        expect(UPTIME in ((_read_json(machine, FOLLOWED) or {}).get("notCheckedSince") or {}),
               f"{FOLLOWED} does not say uptime's pull request was not checked: {_read_json(machine, FOLLOWED)!r}")
        ui.plugins_pane(machine, "opening Settings → Plugins after the read within the reserve")
        unchecked = NOT_CHECKED_SINCE.format(line=f"Pull request #{PULL}")
        said = _wait_until(machine, f"plugin.{UPTIME}.notChecked", lambda said: (said or "").startswith(unchecked),
                           NOTICED_SECONDS)  # fmt: skip
        dump = _keep_the_pane(machine, check_dir, lab, "not-checked-since.txt")
        expect((said or "").startswith(unchecked), f"the read at launch did not ask about pull request #3, and its row says "
                                                    f"{said!r}, not {unchecked!r}…")
        expect(ui.says(ui.element(dump, f"plugin.{UPTIME}.offer")) == changed and ui.element(dump, f"plugin.{UPTIME}.update"),
               "not checked, the row no longer offers what was heard before")

        # Asked for, a read asks within the reserve; what was found of p2 is not asked again.
        scene.github.tell("nothing spent elsewhere any more", spent=0)
        before = _count(scene)
        _press(machine, "catalogue.checkNow", "pressing Check now within the reserve")
        gone = _wait_until(machine, f"plugin.{UPTIME}.notChecked", lambda said: said is None, CATALOGUE_SECONDS)
        heard = _since(scene, before)
        expect(gone is None and any(r.is_api and r.path == f"{api}/pulls/{PULL}" for r in heard),
               f"Check now, a read asked for, did not ask about pull request #3, or its row still says {gone!r}: "
               f"{described(heard)}")  # fmt: skip
        again = [r for r in heard if r.is_api and ("/compare/" in r.path or r.path == f"{api}/git/trees/{p2}")]
        expect(not again, f"p2 was compared with pr3 and listed before, and uDeck asked {described(again)} again")

        # By itself: the read at launch asks about the pull request, and the row offers it.
        app.quit_app(machine, "ending uDeck before a read at launch")
        _age_the_catalogue(machine, AGED_DAYS)
        before = _count(scene)
        app.launch(machine)
        heard = _the_launch_read(scene, before)
        expect(any(r.is_api and r.path == f"{api}/pulls/{PULL}" for r in heard) and not [r for r in heard if r.is_raw],
               f"the read at launch, nobody asking, did not ask about pull request #3, or fetched files: {described(heard)}")
        ui.plugins_pane(machine, "opening Settings → Plugins after the read at launch")
        offer = _wait_until(machine, f"plugin.{UPTIME}.offer", lambda said: said == changed, NOTICED_SECONDS)
        dump = _keep_the_pane(machine, check_dir, lab, "offered-after-a-read-at-launch.txt")
        expect(offer == changed and ui.element(dump, f"plugin.{UPTIME}.update") is not None
               and ui.element(dump, f"plugin.{UPTIME}.whatChanged") is not None,
               f"after the read at launch uptime's row says {offer!r}, with "
               f"{[c.identifier for c in ui.controls(dump) if UPTIME in c.identifier]}")  # fmt: skip
        _expect_the_copy_as_it_was(scene, installed, folder, "after the read at launch")

        before = _count(scene)
        record = _operate(scene, f"plugin.{UPTIME}.update", "pressing Update along the pull request",
                          lambda r: r is not None and r.get("commit") == p2)
        heard = _since(scene, before)
        expect(record is not None, f"Update was pressed, and installed.json says {_read_json(machine, INSTALLED)!r}")
        _expect_an_unverified_record(record, ref={"kind": "pr", "name": PULL}, commit=p2, version="1.0.1")
        previous = record.get("previous") or {}
        expect((previous.get("ref") or {}) == {"kind": "pr", "name": PULL} and previous.get("commit") == pr3,
               f"after the update, previous is {previous!r}, not pull request #3's copy at pr3")
        _expect_only(heard, p2, api=set(), raw=set(scene.github.files("p2", f"plugins/{UPTIME}")),
                     what="updating uptime along the pull request", every=True)
        tree = scene.github.tree_in_guest(f"{UDECK_HOME}/plugins/{UPTIME}", "hashing the folder after the update")
        expect(tree == scene.github.tree("p2", f"plugins/{UPTIME}"), f"after the update the folder hashes to {tree}, not p2's")
        _the_card_asks(scene, UPTIME, "after the update along the pull request")
        _put_the_panel_away(machine, "after the card asked")

        # Left for later whole: fewer than the reserve left before the read at launch begins — it asks nothing at all.
        ui.plugins_pane(machine, "opening Settings → Plugins before the reserve is all that is left")
        _leave_the_reserve(scene, "all but nine of the hour's requests spent elsewhere once more")
        before = _count(scene)
        _press(machine, "catalogue.checkNow", "pressing Check now, which leaves less than the reserve")
        asked = _wait_for_disk(machine, lambda: any(r.is_api and r.path == f"{api}/pulls/{PULL}" for r in _since(scene, before)),
                               CATALOGUE_SECONDS)  # fmt: skip
        expect(asked, f"Check now did not ask about pull request #3: {described(_since(scene, before))}")
        _left_alone(scene, before)
        app.quit_app(machine, "ending uDeck with less than the reserve left")
        _age_the_catalogue(machine, AGED_DAYS)
        before = _count(scene)
        mark = scene.log.mark("marking the launch with less than the reserve left before it")
        app.launch(machine)
        unchecked_kept = _wait_for_disk(
            machine, lambda: UPTIME in ((_read_json(machine, FOLLOWED) or {}).get("notCheckedSince") or {}), CATALOGUE_SECONDS
        )
        heard = [r for r in _left_alone(scene, before) if r.is_api]
        expect(not heard, f"the read at launch, less than the reserve left before it began, asked {described(heard)}")
        _expect_uDeck_said(scene, mark, LEFT_FOR_LATER, "after the read at launch was left for later")
        _expect_uDeck_said(scene, mark, LEFT_AS_THEY_WERE.format(ids=UPTIME), "after the read at launch was left for later")
        expect(unchecked_kept, f"the read at launch was left for later, and {FOLLOWED} does not say uptime's pull request "
                               f"was not checked: {_read_json(machine, FOLLOWED)!r}")  # fmt: skip
        scene.github.tell("the hour's requests all spent elsewhere", spent=HOURLY)
        before = _count(scene)
        ui.plugins_pane(machine, "opening Settings → Plugins with the hour's requests all spent")
        refused = _wait_for_disk(machine, lambda: any(r.is_api and r.status == 403 for r in _since(scene, before)),
                                 NOTICED_SECONDS)  # fmt: skip
        if not refused:
            # The minute's clock was reading as Settings opened, and Settings' own read did not start: Check now.
            _press(machine, "catalogue.checkNow", "pressing Check now with the hour's requests all spent")
            refused = _wait_for_disk(machine, lambda: any(r.is_api and r.status == 403 for r in _since(scene, before)),
                                     CATALOGUE_SECONDS)  # fmt: skip
        said = _wait_until(machine, f"plugin.{UPTIME}.notChecked", lambda said: (said or "").startswith(unchecked),
                           NOTICED_SECONDS)  # fmt: skip
        _keep_the_pane(machine, check_dir, lab, "not-checked-since-a-read-left-for-later.txt")
        expect(refused, f"Settings → Plugins opened with the hour's requests all spent, and no read was refused: "
                        f"{described(_since(scene, before))}")  # fmt: skip
        expect((said or "").startswith(unchecked), f"the read at launch was left for later and the next one refused, and "
                                                    f"uptime's row says {said!r}, not {unchecked!r}…")
    finally:
        scene.close()


def check_force_push_is_said(machine, check_dir, lab):
    """Pull request #3 pushed again with its history rewritten: the row says so, with **Update** offered and nothing installed.

    uptime 1.0.1 installed from pull request #3, placed and allowed. First the
    control: `main` moves on alone, to c2 — **Check now** asks about the pull
    request, whose head is still the commit installed, and compares nothing.
    Then the fake moves the pull request's head to p2x, which was made on c1
    and does not continue pr3. After **Check now** the log holds one comparison
    of pr3 with p2x, and no file of uptime; the record and the folder are as
    they were; the row says *The history of pull request #3 was rewritten: its
    new head does not continue what is installed* and *Changed in pull request
    #3, still 1.0.1*, with **Update**. **Update**, pressed: the record is the
    pull request's at p2x, unverified, and the card asks before it runs.

    **Red for**: a rewritten history said of nothing, or not said; a head that
    does not continue the copy installed by itself; a comparison with the
    default branch, against which every squash merge goes another way too.
    """
    # main moves on in the control: nothing of this copy updates itself, and every check that moves main starts so.
    scene = _prepare(machine, check_dir, lab, main="c1", updates_itself=False, pulls=PULLS)
    try:
        _the_catalogue_read(scene, since=0, commit="c1")
        ui.plugins_pane(machine, "opening Settings → Plugins")
        pr3, p2x = scene.github.commit("pr3"), scene.github.commit("p2x")
        _look_up(scene, PULL_LINK, "the pull request")
        installed, _ = _install_from_the_link(scene, UPTIME, "the pull request")
        _close_the_link_sheet(scene, "after installing")
        _place(scene, UPTIME)
        _the_card_says_unverified(scene, UPTIME, "the pull request's copy")
        folder = _identity(machine, UPTIME, "before the push")
        api = f"/api/repos/{config.PLUGINS_REPOSITORY}"

        # The control: main moves on alone; the pull request's head is the commit installed.
        scene.github.tell("moving main on to c2 alone", main="c2")
        ui.plugins_pane(machine, "opening Settings → Plugins after main moved on")
        before = _count(scene)
        _press(machine, "catalogue.checkNow", "pressing Check now after main moved on alone")
        asked = _wait_for_disk(machine, lambda: any(r.is_api and r.path == f"{api}/pulls/{PULL}" for r in _since(scene, before)),
                               NOTICED_SECONDS)  # fmt: skip
        heard = _left_alone(scene, before)
        compared = [r for r in heard if r.is_api and "/compare/" in r.path]
        expect(asked and not compared, f"main moved on alone, and after Check now uDeck asked {described(heard)}: "
                                       f"the pull request's head did not move, and nothing is compared")
        dump = _keep_the_pane(machine, check_dir, lab, "main-moved-on-alone.txt")
        expect(ui.element(dump, f"plugin.{UPTIME}.rewritten") is None and ui.element(dump, f"plugin.{UPTIME}.offer") is None,
               f"main moved on alone, and uptime's row says "
               f"{[ui.says(c) for c in ui.controls(dump) if c.identifier in (f'plugin.{UPTIME}.rewritten', f'plugin.{UPTIME}.offer')]}")

        _move_the_pull_request(scene, "p2x", "pushing pull request #3 again as p2x, made on c1")
        before = _count(scene)
        _press(machine, "catalogue.checkNow", "pressing Check now after the push")
        rewritten = REWRITTEN.format(line=f"pull request #{PULL}")
        said = _wait_until(machine, f"plugin.{UPTIME}.rewritten", lambda said: said == rewritten, CATALOGUE_SECONDS)
        heard = _since(scene, before)
        dump = _keep_the_pane(machine, check_dir, lab, "history-rewritten.txt")
        expect(said == rewritten, f"pull request #3 was pushed again as p2x, which does not continue pr3, and uptime's row "
                                  f"says {said!r}; uDeck asked {described(heard)}")
        compared = [r for r in heard if r.is_api and "/compare/" in r.path]
        expect([r.path for r in compared] == [f"{api}/compare/{pr3}...{p2x}"],
               f"uDeck compared {described(compared)}, not pr3 with p2x once")
        expect(not _files_fetched(heard, UPTIME), f"the push fetched {described(_files_fetched(heard, UPTIME))} by itself")
        changed = CHANGED_STILL.format(line=f"pull request #{PULL}", version="1.0.1")
        offer = ui.says(ui.element(dump, f"plugin.{UPTIME}.offer"))
        expect(offer == changed and ui.element(dump, f"plugin.{UPTIME}.update") is not None,
               f"the row says {offer!r} beside the rewritten history, not {changed!r} with Update")
        _expect_the_copy_as_it_was(scene, installed, folder, "after the push")
        followed = _followed(machine, UPTIME) or {}
        expect((followed.get("history") or {}).get("rewritten") is True and followed.get("head") == p2x,
               f"{FOLLOWED} keeps {followed!r}: not that p2x rewrote the history of what is installed")

        record = _operate(scene, f"plugin.{UPTIME}.update", "pressing Update after the push",
                          lambda r: r is not None and r.get("commit") == p2x)
        expect(record is not None, f"Update was pressed, and installed.json says {_read_json(machine, INSTALLED)!r}")
        _expect_an_unverified_record(record, ref={"kind": "pr", "name": PULL}, commit=p2x, version="1.0.1")
        _the_card_asks(scene, UPTIME, "after the update to the pushed head")
        _put_the_panel_away(machine, "after the card asked")
    finally:
        scene.close()


def check_a_branch_is_followed(machine, check_dir, lab):
    """The branch a copy came from: asked with the commit installed, a `304` while it stays; moved on, offered; deleted, said; made again and installed from, not said.

    uptime 1.0.1 installed from the branch fix/uptime, at pr3, placed and
    allowed. **Check now**: the log holds the branch's head by `refs/heads/`,
    asked with `If-None-Match` and pr3, answered `304`, and nothing more about
    it. The fake moves the branch on to p2: after **Check now** the head is
    answered p2, p2 is listed and compared with pr3 once, and the row says
    *Changed in branch fix/uptime, still 1.0.1* with **Update** and *What
    changed*. The fake deletes the branch: after **Check now** the head is
    answered `422`, the row says *Branch fix/uptime no longer exists; the plugin
    keeps running*, offers **Switch to verified** and **Remove** and no
    **Update**, the record and the folder are as they were, and the card runs
    again, its count of runs going up. The fake makes the branch again, at p2,
    and uptime is installed from it through **Look up**: the record is the
    branch's at p2, `followed.json` keeps the head **Look up** heard, and — no
    read having asked about the branch since — the row says nothing of a branch
    gone and offers nothing.

    **Red for**: a branch never asked about, asked about by name in a way
    GitHub cannot answer with `304`, a moved head offered against the catalogue
    instead of the branch, a deleted branch that removes, stops or says
    nothing, and a branch installed from again that its row still says is gone.
    """
    scene = _prepare(machine, check_dir, lab, main="c1", branches=BRANCHES)
    try:
        _the_catalogue_read(scene, since=0, commit="c1")
        ui.plugins_pane(machine, "opening Settings → Plugins")
        pr3, p2 = scene.github.commit("pr3"), scene.github.commit("p2")
        _look_up(scene, BRANCH_LINK, "the branch")
        installed, _ = _install_from_the_link(scene, UPTIME, "the branch")
        _close_the_link_sheet(scene, "after installing")
        _place(scene, UPTIME)
        found, _ = _the_card_asks(scene, UPTIME, "the branch's copy")
        machine.click(*found[f"consent.{UPTIME}.allow"].middle, "allowing uptime: the branch's copy")
        card = _read_the_card(scene, UPTIME, "the branch's copy", lambda card: RUNS in card and card[RUNS] not in ("", "unknown"))
        _put_the_panel_away(machine, "the branch's copy")
        ui.plugins_pane(machine, "opening Settings → Plugins after the card ran")
        folder = _identity(machine, UPTIME, "before the branch moved")
        api = f"/api/repos/{config.PLUGINS_REPOSITORY}"
        head = f"{api}/commits/refs/heads/{BRANCH}"

        before = _count(scene)
        _press(machine, "catalogue.checkNow", "pressing Check now with the branch where it was")
        _wait_for_disk(machine, lambda: any(r.is_api and r.path == head for r in _since(scene, before)), CATALOGUE_SECONDS)
        heard = _left_alone(scene, before)
        asked = [r for r in heard if r.is_api and r.path == head]
        expect(len(asked) == 1 and asked[0].status == 304 and asked[0].if_none_match == f'"{pr3}"',
               f"Check now asked about the branch {described(asked)}: not once, with the commit installed, answered 304")
        more = [r for r in heard if r.is_api and (f"/git/trees/{pr3}" in r.path or "/compare/" in r.path)]
        expect(not more, f"the branch did not move, and uDeck asked {described(more)}")

        scene.github.tell("moving the branch on to p2", branches={BRANCH: "p2"})
        before = _count(scene)
        _press(machine, "catalogue.checkNow", "pressing Check now after the branch moved on")
        changed = CHANGED_STILL.format(line=f"branch {BRANCH}", version="1.0.1")
        offer = _wait_until(machine, f"plugin.{UPTIME}.offer", lambda said: said == changed, CATALOGUE_SECONDS)
        heard = _since(scene, before)
        dump = _keep_the_pane(machine, check_dir, lab, "offered-along-the-branch.txt")
        expect(offer == changed, f"the branch moved on to p2, and uptime's row says {offer!r}, not {changed!r}; "
                                 f"uDeck asked {described(heard)}")
        asked = [r for r in heard if r.is_api and r.path == head]
        expect(len(asked) == 1 and asked[0].status == 200
               and any(r.is_api and r.path == f"{api}/git/trees/{p2}" for r in heard)
               and [r.path for r in heard if r.is_api and "/compare/" in r.path] == [f"{api}/compare/{pr3}...{p2}"],
               f"the branch moved on, and uDeck asked {described(heard)}: not its head, p2's listing and one comparison")  # fmt: skip
        expect(ui.element(dump, f"plugin.{UPTIME}.update") is not None and ui.element(dump, f"plugin.{UPTIME}.whatChanged") is not None,
               "the row offers the branch's head without Update and What changed")
        expect(ui.says(ui.element(dump, "catalogue.updatesWaiting")) == ONE_UPDATE_WAITING,
               f"Settings says {ui.says(ui.element(dump, 'catalogue.updatesWaiting'))!r} of the updates waiting")
        _expect_the_copy_as_it_was(scene, installed, folder, "after the branch moved on")

        scene.github.tell("deleting the branch", branches={})
        before = _count(scene)
        _press(machine, "catalogue.checkNow", "pressing Check now after the branch was deleted")
        gone = BRANCH_GONE.format(name=BRANCH)
        said = _wait_until(machine, f"plugin.{UPTIME}.branchGone", lambda said: said == gone, CATALOGUE_SECONDS)
        heard = _since(scene, before)
        dump = _keep_the_pane(machine, check_dir, lab, "branch-deleted.txt")
        expect(said == gone, f"the branch was deleted, and uptime's row says {said!r}; uDeck asked {described(heard)}")
        asked = [r for r in heard if r.is_api and r.path == head]
        expect(len(asked) == 1 and asked[0].status == 422, f"the branch was deleted, and uDeck asked {described(asked)}")
        offered = {c.identifier for c in ui.controls(dump) if UPTIME in c.identifier}
        expect({f"plugin.{UPTIME}.switchToVerified", f"plugin.{UPTIME}.remove"} <= offered
               and f"plugin.{UPTIME}.update" not in offered and f"plugin.{UPTIME}.offer" not in offered,
               f"the branch's copy, its branch gone, is offered {sorted(offered)}: Switch to verified and Remove, "
               f"and no Update")  # fmt: skip
        _expect_the_copy_as_it_was(scene, installed, folder, "after the branch was deleted")
        runs = int(card[RUNS])
        _open_the_panel(machine, "opening the panel after the branch was deleted")
        later = _read_the_card(scene, UPTIME, "after the branch was deleted",
                               lambda card: card.get(RUNS, "").isdigit() and int(card[RUNS]) > runs,
                               f"it had run more than {runs} times")  # fmt: skip
        _put_the_panel_away(machine, "after the branch was deleted")
        expect(int(later[RUNS]) > runs, f"the deleted branch's copy stopped: its card says {later!r}")

        # Made again at p2, and installed from: what Look up heard stands, and nothing of a branch gone is said.
        scene.github.tell("making the branch again, at p2", branches={BRANCH: "p2"})
        ui.plugins_pane(machine, "opening Settings → Plugins after the branch was made again")
        _look_up(scene, BRANCH_LINK, "the branch made again")
        before = _count(scene)
        record = _operate(scene, f"link.{UPTIME}.install", "installing uptime from the branch made again",
                          lambda r: r is not None and r.get("commit") == p2)
        expect(record is not None, f"Install was pressed on the branch made again, and installed.json says "
                                   f"{_read_json(machine, INSTALLED)!r}")
        _expect_an_unverified_record(record, ref={"kind": "branch", "name": BRANCH}, commit=p2, version="1.0.1")
        _close_the_link_sheet(scene, "after installing from the branch made again")
        kept = _wait_for_disk(machine, lambda: (((_read_json(machine, FOLLOWED) or {}).get("branches") or {}).get(UPTIME)
                                                or {}).get("head") == p2, NOTICED_SECONDS)  # fmt: skip
        expect(kept, f"uptime was installed from the branch made again at p2, and {FOLLOWED} keeps "
                     f"{((_read_json(machine, FOLLOWED) or {}).get('branches') or {}).get(UPTIME)!r} of it")
        said = _wait_until(machine, f"plugin.{UPTIME}.branchGone", lambda said: said is None, NOTICED_SECONDS)
        dump = _keep_the_pane(machine, check_dir, lab, "installed-from-the-branch-made-again.txt")
        heard = _since(scene, before)
        asked = [r for r in heard if r.is_api and r.path == head]
        expect(not asked, f"a read asked about the branch after the install, so the row says what it heard: {described(asked)}")
        offered = {c.identifier for c in ui.controls(dump) if UPTIME in c.identifier}
        expect(said is None and f"plugin.{UPTIME}.offer" not in offered and f"plugin.{UPTIME}.update" not in offered,
               f"uptime was installed from the branch made again, and its row says {said!r} and offers "
               f"{sorted(offered)}: nothing of a branch gone, nothing along it")  # fmt: skip
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
    scene = _prepare(machine, check_dir, lab, main="c1", updates_itself=False)
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
    scene = _prepare(machine, check_dir, lab, main="c1", updates_itself=False)
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

        _hold_on_the_card(scene, "before the update")

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

    Then two warnings C2b2's review changed: **Link a folder…** over a link,
    which names the folder chosen and the folder the link leads to both from
    `~`; and **Update** over a link put where the installed `uptime` was, which
    says first that only the link goes, as **Replace…** says it — it used to
    take the link away without a word.

    **Red for**: a part that is not there in Russian, or that says it in
    English; a warning that writes a folder as `/Users/…`; **Update** over a
    link without that warning.
    """
    scene = _prepare(machine, check_dir, lab, main="c1", launch=False, updates_itself=False)
    ru = ui.RUSSIAN
    window = ru.settings_window
    try:
        machine.ssh.run(f"mkdir -p {UDECK_HOME}", "making uDeck's folder")
        # Updates by themselves off, as `_prepare` leaves them: main moves to c2 below.
        _write(machine, SETTINGS, {"language": ru.code, "autoUpdateVerified": False}, "setting uDeck's language to Russian")
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

        # Link a folder… over a link: a second working copy with flaky's id,
        # over the link to the first. Both folders are written from ~.
        again = f"{WORK}/{FLAKY}-again"
        machine.ssh.run(f"rm -rf {again} && cp -R {folder} {again} && rm -f {again}/{FAIL}",
                        "making a second working copy of flaky")  # fmt: skip
        _link_through_settings(scene, again, "over the link flaky, in Russian", window=window)
        over_a_link = RU_OVER_A_LINK.format(id=FLAKY)
        warning = _wait_until(machine, "plugins.linkFolder.confirmText",
                              lambda said: bool(said) and said.startswith(over_a_link), NOTICED_SECONDS, window=window)  # fmt: skip
        _keep_the_pane(machine, check_dir, lab, "ru-the-warning-before-linking-over-a-link.txt", window=window)
        expect(warning is not None and warning.startswith(over_a_link) and "/Users/" not in warning,
               f"Link a folder… over a link in Russian says {warning!r}; both folders have to be written from ~")
        _press(machine, "plugins.linkFolder.cancel", "leaving the link as it is", window=window)

        # Update over a link: uptime's copy replaced by a link to a working
        # copy by hand, its update offered, Update pressed — the warning first.
        machine.ssh.run(f"rm -rf {UDECK_HOME}/plugins/{UPTIME} && ln -s {over} {UDECK_HOME}/plugins/{UPTIME}",
                        "putting a link where uptime's copy was")  # fmt: skip
        scene.github.tell("moving main to c2", main="c2")
        _press(machine, "catalogue.checkNow", "pressing Check now", window=window)
        offered = _wait_until(machine, f"plugin.{UPTIME}.update", lambda said: said is not None, OPERATION_SECONDS,
                              window=window, present=True)  # fmt: skip
        expect(offered is not None, f"with main at c2, {UPTIME}'s row offers no Update")
        if offered is not None:
            _press(machine, f"plugin.{UPTIME}.update", "pressing Update over the link", window=window)
            replacing = RU_REPLACING_A_LINK.format(id=UPTIME)
            warning = _wait_until(machine, f"plugin.{UPTIME}.confirmText",
                                  lambda said: bool(said) and said.startswith(replacing), NOTICED_SECONDS, window=window)  # fmt: skip
            _keep_the_pane(machine, check_dir, lab, "ru-the-warning-before-updating-over-a-link.txt", window=window)
            expect(warning is not None and warning.startswith(replacing) and "/Users/" not in warning,
                   f"Update over a link in Russian says {warning!r} first; it has to say {replacing!r}…")
            expect(_link_leads(machine, UPTIME) is not None, "Update over a link took the link away before its warning was confirmed")
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


def _prepare(machine, check_dir, lab, main, launch=True, updates_itself=True, **state):
    """A lab build installed on a machine with nothing of uDeck's in it, the fake serving, and uDeck started.

    The feed is one nobody serves, as for the settings checks: a lab build must
    not be able to update itself against anything real (Q41). `~/.udeck` is taken
    away before uDeck starts — a fresh guest has none, and one shared with an
    earlier check (`--vm per-group`) must not lend this one its plugins.

    `updates_itself` False starts uDeck with **Update verified plugins by
    themselves** off (`settings.json`, `autoUpdateVerified: false`): a check that
    moves `main` to press **Update** on what it offers would otherwise see it
    put in place by itself first.
    """
    feed = updates.Feed(machine, lab.note)
    build = lab.builder(feed.url, check_dir.name).build(*VERSION)
    app.install(machine, build.zip, lab.note)
    step = "preparing the machine for a plugin check"
    there = app.installed_version(machine)
    if there != VERSION:
        raise LabError(step, f"the lab installed {VERSION}, but the machine has {there}")
    machine.ssh.run(f"rm -rf {UDECK_HOME} /tmp/udeck-e2e-manifest.json", step)
    if not updates_itself:
        machine.ssh.run(f"mkdir -p {UDECK_HOME}", step)
        _write(machine, SETTINGS, {"autoUpdateVerified": False}, "starting uDeck with updates by themselves off")

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
    """What the control says once `satisfied` by it — or what it said in a walk begun after the time was up (None when absent).

    A verdict against the control comes only from a walk that began at or
    after the deadline. One walk of Settings → Plugins took System Events 40 to
    60 s, much longer than the deadlines here (the accessibility helper takes a
    tenth of a second since 2026-10-12, and the rule stands: a walk still reads
    a pane's controls one after another), and a walk takes the list of a pane's
    controls when it reaches it and reads each one after: a walk begun before
    uDeck changed the control and read after it returns the control as it
    was, twice over, or not at all. Measured in R3 (.build/e2e/kept/,
    `plugins.modified-locally`, `race.txt`): a line appended to `uptime.sh`
    at a chosen moment inside one walk left that walk without the row's mark,
    with the old mark, or with the mark several times, while the next walk
    read **Modified locally** each time. So the deadline is as fine as the
    walk: the control has to say it by the time a walk begun after the
    deadline reads it.
    """
    deadline = machine.clock() + seconds
    while True:
        began = machine.clock()
        dump = _read_the_screen(machine, f"reading {identifier}", window)
        found = ui.element(dump, identifier)
        said = None if found is None else (ui.says(found) if not present else ui.says(found) or identifier)
        if satisfied(said) or began >= deadline:
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


def _count_of_runs(machine, path):
    """The count a plugin keeps of its runs at `path`, as a number; None when there is none, or it is not a number."""
    text = machine.ssh.ask(f"cat {path} 2>/dev/null || true", "reading the plugin's count of its runs").stdout.strip()
    return int(text) if text.isascii() and text.isdigit() else None


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


def _hold_on_the_card(scene, label):
    """**Hold** pressed on `uptime`'s card in the panel, and left running — one the card does not offer is uDeck's failure."""
    machine = scene.machine
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
        raise LabError(label, f"the action ended by itself: {_hold_log(machine)!r}")


def _expect_uDeck_said(scene, mark, words, label, seconds=NOTICED_SECONDS):
    """uDeck's own log, from `mark`, holding `words` — the reason it gives for what it did — or the check fails.

    What a control shows from outside (nothing fetched, the row's words) is the
    same for every reason a plugin does not update itself; this is the one place
    uDeck says which reason it was.
    """
    deadline = scene.machine.clock() + seconds
    while True:
        said = scene.log.read(mark, f"reading uDeck's log {label}")
        if words in said or scene.machine.clock() >= deadline:
            break
        scene.machine.sleep(2)
    lines = [line for line in said.splitlines() if "itself" in line]
    expect(words in said, f"{label}, uDeck's log does not say {words!r}; of updating by itself it says {lines[-6:]!r}")


def _hold_log(machine):
    return machine.ssh.ask(f"cat {HOLD_LOG} 2>/dev/null || true", "reading the action's own log").stdout


def _hold_is_running(machine):
    return machine.ssh.ask("/usr/bin/pgrep -f hold.sh", "asking whether the action runs").returncode == 0


def _status(machine, plugin):
    """`installed.json`'s verification status of `plugin`, or None."""
    record = ((_read_json(machine, INSTALLED) or {}).get("plugins") or {}).get(plugin) or {}
    return (record.get("verification") or {}).get("status")


def _look_up(scene, link, label):
    """`link` typed into **Install from a link…** and looked up: uDeck's requests from the press on, and the walk once it says what it came to."""
    machine = scene.machine
    dump = _read_the_screen(machine, f"looking for the link sheet: {label}")
    if ui.element(dump, "link.field") is None:
        _press(machine, "plugins.installFromLink", f"pressing Install from a link…: {label}")
    try:
        field = ui.wait_for(machine, "link.field", f"waiting for the link field: {label}")
    except NotThere as error:
        raise CheckFailed(f"Install from a link… offers no field to paste a link into: {error.reason}") from None
    machine.click(*field.middle, f"putting the cursor in the link field: {label}")
    ui.type_text(machine, link, f"typing {link}: {label}")
    typed = _wait_until(machine, "link.field", lambda said: said == link, config.UI_CHANGE_SECONDS)
    if typed != link:
        raise LabError(f"typing the link: {label}", f"the field reads {typed!r} after {link!r} was typed into it")
    before = _count(scene)
    _press(machine, "link.lookUp", f"pressing Look up: {label}")
    deadline = machine.clock() + OPERATION_SECONDS
    while True:
        dump = _read_the_screen(machine, f"reading what the link came to: {label}")
        found = {row.identifier for row in ui.controls(dump)}
        if found & {"link.head", "link.refused", "link.catalogue"} or machine.clock() >= deadline:
            break
        machine.sleep(1)
    _keep_the_pane(machine, scene.check_dir, scene.lab, f"the-link-sheet-{label.replace(' ', '-')}.txt")
    if "link.head" not in found:
        said = ui.says(ui.element(dump, "link.refused")) or ui.says(ui.element(dump, "link.catalogue"))
        raise CheckFailed(f"{link} came to {said or 'nothing'} within {OPERATION_SECONDS}s; uDeck asked "
                          f"{described(_since(scene, before))}")
    return _since(scene, before), dump


def _install_from_the_link(scene, plugin, label):
    """**Install** pressed on `plugin`'s row in the link sheet: the record it left, and uDeck's requests from the click on."""
    before = _count(scene)
    record = _operate(scene, f"link.{plugin}.install", f"installing {plugin} from the link: {label}",
                      lambda r: r is not None and not ((r.get("ref") or {}).get("kind") in (None, "default")), plugin)
    asked = _since(scene, before)
    if record is None:
        problem = ui.reads(scene.machine, f"link.{plugin}.problem", "reading why it was not installed")
        raise CheckFailed(f"Install on {plugin} from {label} put no record of it in installed.json within "
                          f"{OPERATION_SECONDS}s; the row says {problem!r}; uDeck asked {described(asked)}")
    return record, asked


def _close_the_link_sheet(scene, label):
    """The link sheet closed, so that the rows below it are read alone (`_row_of`)."""
    _press(scene.machine, "link.close", f"closing the link sheet: {label}")
    scene.machine.sleep(config.SETTLE_SECONDS)


def _expect_only(heard, commit, api, raw, what, every=False):
    """uDeck's requests `heard` are the API paths `api` and the raw files `raw` of the official repository at `commit` — nothing else, from no other repository; `every` raw file once, when asked."""
    stray = []
    files = []
    for request in heard:
        if request.is_api and request.path in api:
            continue
        found = request.raw_file()
        if found is not None and found[0] == commit and found[1] in raw:
            files.append(found[1])
            continue
        stray.append(request)
    expect(not stray, f"{what}, uDeck also asked {described(stray)}; it asks for {sorted(api)} and the files "
                      f"{sorted(raw)} at {commit[:7]}, through {config.PLUGINS_REPOSITORY}, and nothing else")
    if every:
        missing = sorted(set(raw) - set(files))
        twice = sorted({path for path in files if files.count(path) > 1})
        expect(not missing and not twice,
               f"{what}, uDeck never fetched {missing} and fetched {twice} more than once")  # fmt: skip


def _expect_an_unverified_record(record, ref, commit, version, plugin=UPTIME):
    """A record of the official source's copy from a branch or a pull request: where it came from, and nobody's guarantee."""
    wanted = {"source": "official", "ref": ref, "commit": commit, "version": version,
              "repository": {"provider": "github", "host": "github.com", "path": config.PLUGINS_REPOSITORY}}  # fmt: skip
    wrong = {key: record.get(key, "(missing)") for key, value in wanted.items() if record.get(key, "(missing)") != value}
    expect(not wrong, f"installed.json says {wrong} of {plugin}, where the install from the link has to have written "
                      f"{({k: wanted[k] for k in wrong})}")
    verification = record.get("verification") or {}
    expect(verification.get("status") == "unverified" and "by" in verification and verification.get("by") is None,
           f"installed.json's verification of {plugin} is {verification!r}: unverified, by nobody")  # fmt: skip


def _expect_the_row_says(scene, plugin, source, label):
    """`plugin`'s row in Settings: **Unverified**, and where the copy came from."""
    machine = scene.machine
    mark = _wait_until(machine, f"plugin.{plugin}.mark", lambda said: said == UNVERIFIED, NOTICED_SECONDS)
    dump = _keep_the_pane(machine, scene.check_dir, scene.lab, f"{label.replace(' ', '-')}.txt")
    said = ui.says(ui.element(dump, f"plugin.{plugin}.from"))
    expect(mark == UNVERIFIED and said == source,
           f"{plugin}'s row says {mark!r} · {said!r}, not {UNVERIFIED!r} · {source!r}")  # fmt: skip
    expect(ui.element(dump, f"plugin.{plugin}.refPage") is not None,
           f"{plugin}'s row offers no link to the page it came from")


def _the_card_asks(scene, plugin, label):
    """The panel opened, and `plugin`'s card read once it asks for consent and stands still: its controls by identifier, and its texts.

    Still, because the checks click **Allow** and **Decline** where this read
    them, and the panel grows from the shortcut on a spring: a card read while
    it grows is read where it is passing through (`ui._settled`, the same rule
    for one control). Measured on GitHub runners on 2026-10-12, once the lab's
    helper stopped walking into the settings window's title-bar buttons, the
    readings that failed read the card 26 to 36 points right of where it came to
    rest, and the click meant for the 66-point **Decline** landed past its edge:
    4 readings of 7 of `plugins.unverified-asks-even-for-nothing` (runs
    38317811235, 38318963221), against 0 of 6 on the tree before (38319657054),
    where the card was read within 11 points of rest. Why the panel was still
    moving later than before is not measured; the likeliest difference is the
    three `ThemeWidgetControlViewService` those walks used to start in uDeck
    first (README, "The accessibility helper"). A card still moving after
    `CARD_SETTLES_SECONDS` of its own is not clicked at all.
    """
    machine = scene.machine
    _open_the_panel(machine, f"opening the panel: {label}")
    allow = f"consent.{plugin}.allow"
    dump, texts = _wait_for_the_card(machine, lambda found, texts: allow in found, CARD_SECONDS + NOTICED_SECONDS)
    dump, texts = _once_it_stands_still(machine, dump, texts, allow, machine.clock() + CARD_SETTLES_SECONDS)
    machine.screenshot(scene.check_dir, f"{plugin} asks: {label}")
    _keep(scene.check_dir, f"card-{label.replace(' ', '-')}.txt", "\n".join(texts) + "\n\n" + dump)
    found = {row.identifier: row for row in ui.controls(dump) if row.identifier}
    expect(allow in found, f"{plugin}, {label}, does not ask for consent on its card; the panel says {texts}")
    header = ui.says(found.get(f"card.{plugin}.unverified"))
    expect(header == UNVERIFIED, f"{plugin}'s card, {label}, says {header!r} in its header, not {UNVERIFIED!r}")
    return found, texts


def _the_card_says_unverified(scene, plugin, label):
    """`plugin`'s card asks, saying where its code comes from and **Unverified** in its header; allowed, it runs and still says so."""
    found, texts = _the_card_asks(scene, plugin, label)
    source = ui.says(found.get(f"consent.{plugin}.source"))
    expect(NOBODY_VERIFIED.format(number=PULL, repository=config.PLUGINS_REPOSITORY) in source,
           f"{plugin}'s card says {source!r} of where its code comes from")
    scene.machine.click(*found[f"consent.{plugin}.allow"].middle, f"allowing {plugin}: {label}")
    card = _read_the_card(scene, plugin, label, lambda card: RUNS in card and card[RUNS] not in ("", "unknown"))
    dump = ui.identified(scene.machine, "reading the card's header", ui.PANEL, depth=ui.MAX_DEPTH)
    header = ui.says(ui.element(dump, f"card.{plugin}.unverified"))
    scene.machine.screenshot(scene.check_dir, f"{plugin}'s card header: {label}")
    _put_the_panel_away(scene.machine, label)
    expect(header == UNVERIFIED, f"{plugin}'s card, allowed and running, says {header!r} in its header, not {UNVERIFIED!r}")
    return card


def _expect_a_warning_that_changes_nothing(scene, row, what, words, tree, button=None):
    """`button` (the row's Install) pressed: its warning says `words`, and the folder, which hashes to `tree`, and the record are as they were."""
    machine = scene.machine
    before = _read_json(machine, INSTALLED)
    _press(machine, button or f"{row}.install", f"pressing {what}")
    warning = _wait_until(machine, f"{row}.confirmText", lambda said: bool(said), NOTICED_SECONDS)
    _keep_the_pane(machine, scene.check_dir, scene.lab, f"the-warning-{what.split()[0].lower()}.txt")
    expect(warning is not None and words in warning, f"{what} said {warning!r} before replacing anything; it has to say {words!r}")
    expect(_read_json(machine, INSTALLED) == before, f"while the warning of {what} was up, installed.json changed")
    now = scene.github.tree_in_guest(f"{UDECK_HOME}/plugins/{UPTIME}", "hashing the folder under the warning")
    expect(now == tree, f"while the warning of {what} was up, the folder became {now}, not {tree}")


def _expect_a_whole_record(record, commit, tree, version, pinned, previous, against=None):
    """Every field of an `installed.json` record, as docs/plugin-repository.md lists them — verified against `commit`, or the head `against`."""
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
        and verification.get("checkedAgainst") == (against or commit) and bool(verification.get("checkedAt")),
        f"installed.json's verification is {verification!r}",
    )  # fmt: skip
    expect(bool(record.get("installedAt")), f"installed.json has no installedAt: {record!r}")


def _merge(scene, commit, step, main=None, into=None):
    """Pull request #3 squash-merged as `commit`, the way GitHub merges one: closed, merged as that commit, its branch
    gone — and `main` at it, or at `main`, moved on past it; or, merged into the branch `into`, that branch at it and
    `main` at `main`."""
    merged = {**PULLS[PULL], "state": "closed", "merged": True, "merge_commit": commit}
    if into is None:
        scene.github.tell(step, main=main or commit, branches={}, pulls={PULL: merged})
    else:
        if main is None:
            raise ValueError("a merge into another branch says where main is")
        scene.github.tell(step, main=main, branches={into: commit}, pulls={PULL: {**merged, "base": into}})


def _show_the_catalogue_row(scene, identifier, label):
    """The catalogue row holding `identifier`, scrolled into view where the screen is too short for the pane (a
    runner's), and a screenshot of it kept for a person to read what the walk cannot."""
    machine = scene.machine
    if getattr(machine, "scroll", None) is not None:
        ui.in_view(machine, identifier, f"bringing {identifier} into view")
    machine.screenshot(scene.check_dir, label)


def _move_the_pull_request(scene, head, step):
    """Pull request #3's head at the fixture commit `head` — a push to its branch; open, as it was."""
    scene.github.tell(step, pulls={PULL: {**PULLS[PULL], "head": head}})


def _leave_the_reserve(scene, step):
    """The fake told that all but `RESERVE - 1` of the hour's requests will be spent once uDeck asks one more: what
    the read at launch is left with once the catalogue's own question is answered, so that it asks nothing more."""
    used = sum(1 for request in scene.github.read_log(step) if request.is_api and request.status != 403)
    scene.github.tell(step, spent=max(0, HOURLY - used - 1 - (RESERVE - 1)))


def _the_launch_read(scene, before):
    """uDeck's requests from `before` on, once the read at launch has asked for the default branch's head and what
    follows it has had `LEFT_ALONE_SECONDS` — a failure when it never asks."""
    machine = scene.machine
    main = f"/api/repos/{config.PLUGINS_REPOSITORY}/commits/main"
    read = _wait_for_disk(machine, lambda: any(r.is_api and r.path == main for r in _since(scene, before)),
                          CATALOGUE_SECONDS)  # fmt: skip
    if not read:
        panel.expect_it_was_still_there(machine, "waiting for the read at launch", "uDeck was gone before it read the catalogue")
        raise CheckFailed(f"{CATALOGUE_SECONDS}s after a launch with the catalogue {AGED_DAYS} days old, uDeck had not "
                          f"read it: {described(_since(scene, before))}")
    return _left_alone(scene, before)


def _expect_the_copy_as_it_was(scene, installed, folder, label):
    """`uptime`'s record the copy `installed` was, unverified, and its folder the very one `folder` read."""
    machine = scene.machine
    record = _record(machine, UPTIME)
    expect(_the_copy(record) == _the_copy(installed) and _status(machine, UPTIME) == "unverified",
           f"{label}, installed.json says {record!r}: the copy was changed without a press")
    expect(_identity(machine, UPTIME, label) == folder, f"{label}, uptime's folder or a file in it was replaced")


def _record(machine, plugin):
    """`installed.json`'s record of `plugin`, or None."""
    return ((_read_json(machine, INSTALLED) or {}).get("plugins") or {}).get(plugin)


def _followed(machine, plugin):
    """What `followed.json` keeps of the pull request `plugin`'s copy came from, or None."""
    return ((_read_json(machine, FOLLOWED) or {}).get("pulls") or {}).get(plugin)


def _the_copy(record):
    """What a record says of the copy — everything but `verification`, which is what was found the last time uDeck
    looked, against the head of the time, and is written again whenever the head moves."""
    return {key: value for key, value in (record or {}).items() if key != "verification"}


def _identity(machine, plugin, label):
    """Every name in `plugin`'s installed folder with its inode and when it was last written: the same text is the
    same folder and the same files, none of them replaced or written."""
    folder = f"{UDECK_HOME}/plugins/{plugin}"
    said = machine.ssh.ask(f"cd {folder} && find . -exec /usr/bin/stat -f '%i %Fm %N' {{}} + | LC_ALL=C sort",
                           f"reading the inodes of {folder} {label}")
    if said.returncode != 0 or not said.stdout.strip():
        raise CheckFailed(f"{folder} could not be read {label} — is it gone? {said.stderr.strip()!r}")
    return said.stdout


def _the_card_header_says_nothing(scene, plugin, label):
    """The panel opened, and `plugin`'s card, drawn, with no **Unverified** in its header."""
    machine = scene.machine
    _open_the_panel(machine, f"opening the panel: {label}")
    mark = f"card.{plugin}.unverified"
    dump, texts = _wait_for_the_card(machine, lambda found, texts: mark not in found and RUNS in texts, CARD_SECONDS)
    machine.screenshot(scene.check_dir, f"{plugin}'s card header: {label}")
    _keep(scene.check_dir, f"card-header-{label.replace(' ', '-')}.txt", "\n".join(texts) + "\n\n" + dump)
    _put_the_panel_away(machine, label)
    said = ui.says(ui.element(dump, mark))
    expect(ui.element(dump, mark) is None, f"{plugin}'s card, {label}, says {said!r} in its header")
    expect(RUNS in texts, f"{plugin}'s card, {label}, was never drawn: the panel says {texts}")


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


def _allow_and_read_the_card(scene, plugin, label, version=None):
    """The panel opened, the plugin allowed on its card, and the card read once it has run — as `version`, if given.

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
    # A card that has run already says how many runs it has made — and after an
    # update it still shows the last run of the version before until the new
    # one has run (run 38213314297, permissions-change-only-offers: 1.0.0's rows
    # read 0.2 s after Allow on 1.2.0). Read through System Events the read
    # itself took long enough to hide that; read in a tenth of a second it does
    # not, so a caller that asks about a version waits for that version's card.
    card = _read_the_card(
        scene, plugin, label,
        lambda card: RUNS in card and card[RUNS] not in ("", "unknown") and (version is None or card.get(VERSION_ROW) == version),
        "it had run" if version is None else f"it had run as {version}",
    )  # fmt: skip
    _put_the_panel_away(machine, label)
    return card


def _the_card_without_asking(scene, plugin, version, label):
    """The panel opened, and `plugin`'s card read once it shows `version` — a consent asked for instead is uDeck's failure.

    For a copy whose permission decision was carried to it (`GrantCarry`): it
    asks for exactly what the copy before it asked for, and the operator
    already answered that.
    """
    machine = scene.machine
    _open_the_panel(machine, f"opening the panel: {label}")
    consent = f"consent.{plugin}.allow"

    def card_of(texts):
        return {texts[i]: texts[i + 1] for i in range(len(texts) - 1) if texts[i] in (RUNS, VERSION_ROW, "up")}

    def ready(found, texts):
        card = card_of(texts)
        return consent in found or (card.get(VERSION_ROW) == version and card.get(RUNS) not in (None, "", "unknown"))

    dump, texts = _wait_for_the_card(machine, ready, CARD_SECONDS)
    machine.screenshot(scene.check_dir, f"{plugin}'s card: {label}")
    _keep(scene.check_dir, f"card-{label.replace(' ', '-')}.txt", "\n".join(texts))
    asked = ui.element(dump, consent) is not None
    _put_the_panel_away(machine, label)
    expect(not asked, f"{plugin} {version}, {label}, asks for consent on its card although it asks for what it asked before: {texts}")
    card = card_of(texts)
    if card.get(VERSION_ROW) != version or card.get(RUNS) in (None, "", "unknown"):
        raise CheckFailed(f"{plugin}'s card {label} never said it had run as {version}: the panel says {texts}")
    return card


def _expect_the_decision_for(machine, plugin, version, label):
    """`grants.json`'s decision for `plugin` is for `version`: the decision, as it is there."""
    grant = ((_read_json(machine, GRANTS) or {}).get("byPlugin") or {}).get(plugin) or {}
    expect(grant.get("decidedForVersion") == version,
           f"{label}, {GRANTS} holds {plugin}'s decision for {grant.get('decidedForVersion')!r}, not {version}: {grant!r}")  # fmt: skip
    return grant


# The catalogue's state file, and what makes it look `argv[2]` days old: its last
# read, and its last attempt, moved back by that much, in the ISO 8601 uDeck writes
# (`JSONFileStore`), written beside it for a `mv` over it. Run by the guest's own
# Python, which the fake already runs on.
CATALOGUE_STATE = f"{UDECK_HOME}/catalogue/official/state.json"
AGE_THE_CATALOGUE = """\
import json, sys, time
path = sys.argv[1]
with open(path) as file:
    state = json.load(file)
then = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() - float(sys.argv[2]) * 86400))
state["lastSuccess"] = state["lastAttempt"] = then
with open(path + ".new", "w") as file:
    json.dump(state, file, indent=2)
print(then)
"""


def _age_the_catalogue(machine, days):
    """The catalogue's `state.json` made `days` old, as a Mac that was off for them leaves it — uDeck not running."""
    state = CATALOGUE_STATE
    said = machine.ssh.run(f"/usr/bin/python3 -c {shlex.quote(AGE_THE_CATALOGUE)} {state} {days} && mv {state}.new {state}",
                           f"making the catalogue {days} days old")  # fmt: skip
    if not said.stdout.strip():
        raise LabError(f"making the catalogue {days} days old", f"{state} was not rewritten: {said.stderr.strip()!r}")


def _left_alone(scene, before):
    """uDeck's requests from `before` on, listened to for `LEFT_ALONE_SECONDS` — long enough for an update by itself to begin."""
    machine = scene.machine
    until = machine.clock() + LEFT_ALONE_SECONDS
    while machine.clock() < until:
        machine.sleep(min(2, max(0.5, until - machine.clock())))
    return _since(scene, before, "listening for an update by itself")


def _files_fetched(heard, plugin):
    """The requests for `plugin`'s files other than its manifest — what a download of it fetches, and a read of the catalogue never does."""
    prefix = f"plugins/{plugin}/"
    return [r for r in heard if r.raw_file() and r.raw_file()[1].startswith(prefix)
            and r.raw_file()[1] not in (f"{prefix}manifest.json", f"{prefix}manifest.ru.json")]  # fmt: skip


def _switch(machine, identifier, on, step, window=ui.SETTINGS_WINDOW):
    """A switch in Settings set `on` by a click, and read back — one uDeck does not offer is uDeck's failure."""
    wanted = "1" if on else "0"
    switch = ui.element(_read_the_screen(machine, step, window), identifier)
    if switch is None:
        raise CheckFailed(f"{step}: Settings → Plugins has no {identifier}")
    if switch.value == wanted:
        return
    machine.click(*switch.middle, step)
    now = _wait_until(machine, identifier, lambda said: said == wanted, config.UI_CHANGE_SECONDS, window)
    if now != wanted:
        raise LabError(step, f"the lab clicked {switch} and it reads {now!r}")


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


def _once_it_stands_still(machine, dump, texts, identifier, deadline):
    """The panel read again, half a second apart, until `identifier` stands where it stood.

    `ui._settled`'s rule, for a reading of the whole card rather than of one
    control: the dump and the texts that come back are one reading, taken with
    the control where the one before had it. Unlike `ui._settled` it does not
    take a card still moving at the deadline where it was last: the checks click
    Allow and Decline where this read them, and a click that misses becomes a
    sentence about uDeck ("Decline … left it switched on"). That is the lab not
    knowing where the card is, so "could not check".
    """

    def place(reading):
        found = ui.element(reading, identifier)
        return None if found is None else (found.x, found.y, found.width, found.height)

    while machine.clock() < deadline:
        machine.sleep(ui.SETTLED_SECONDS)
        again = ui.identified(machine, "reading the panel again", ui.PANEL, depth=ui.MAX_DEPTH)
        again_texts = _panel_texts(machine, "reading the panel's texts again")
        if place(again) is not None and place(again) == place(dump):
            return again, again_texts
        dump, texts = again, again_texts
    raise LabError(
        f"waiting for {identifier} to stand still",
        f"the card was still moving when the time for it ran out — {identifier} last at {place(dump)} — so "
        "where Allow and Decline are, which the check clicks, is not known",
    )


def _read_the_card(scene, plugin, label, ready, waited_for="it had run"):
    """The card's rows as label → value, once `ready` says they are there, read out of the panel.

    `waited_for` is what `ready` waits for, in the words the failure says it never said.
    """
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
        raise CheckFailed(f"{plugin}'s card {label} never said {waited_for}: the panel says {texts}")
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


def _guest_time_after(machine, command, step):
    """The guest's clock, to the millisecond, read right after `command` ran there."""
    said = machine.ssh.run(f"{command} >/dev/null && /usr/bin/python3 -c 'import time; print(\"%.3f\" % time.time())'", step)
    return float(said.stdout.strip())


def _mtime_of(machine, path):
    """When `path` in the guest was last written, by the guest's clock, to the millisecond."""
    return float(machine.ssh.run(f"/usr/bin/stat -f %Fm {path}", f"reading when {path} was written").stdout.strip())


def _keep(check_dir, name, text):
    try:
        (check_dir / name).write_text(text)
    except OSError:
        pass


def _log_entries(machine, log):
    """The entries of a run log: its lines that are not a run's stderr under one."""
    text = machine.ssh.ask(f"cat {log} 2>/dev/null || true", "reading the run log").stdout
    return [line for line in text.splitlines() if line and not line.startswith("  ")]
