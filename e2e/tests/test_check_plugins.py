"""The plugin checks' own reasoning: which files a catalogue needs, what a whole record is, where a window is.

The checks themselves run against a guest; what can be held here is every
sentence they reach without one. Each test removes one thing the check relies on
and asks whether the check would still be green — a record with a field
missing, a window moved, a catalogue that fetched one file more.
"""

import ast
import calendar
import importlib.util
import json
import re
import sys
import time
from pathlib import Path

import pytest

from udeck_e2e import ax, config, plugin_repository, ui
from udeck_e2e.errors import CheckFailed, LabError


def _load():
    path = Path(__file__).resolve().parents[1] / "checks" / "check_plugins.py"
    spec = importlib.util.spec_from_file_location("check_plugins_under_test", path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


checks = _load()


def _fake():
    spec = importlib.util.spec_from_file_location("fake_github_for_checks", plugin_repository.SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


FACTS = _fake().Repository(str(plugin_repository.FIXTURES)).facts()


class GitHub:
    """What a check asks the fake about its own content, answered from the real fixtures."""

    def facts(self):
        return FACTS

    def commit(self, name):
        return FACTS["commits"][name]["sha"]


class Scene:
    github = GitHub()


def test_building_the_catalogue_needs_the_passport_and_one_manifest_per_plugin():
    assert checks._catalogue_files(Scene(), "c1") == {
        "udeck-plugins.json",
        "plugins/future-api/manifest.json",
        "plugins/future-udeck/manifest.json",
        "plugins/linked/manifest.json",
        "plugins/uptime/manifest.json",
    }


def test_the_checks_name_the_fixture_plugins_there_are():
    assert sorted(checks.FIXTURE_PLUGINS) == sorted(
        path.split("/")[1] for path in FACTS["commits"]["c1"]["paths"] if path.count("/") == 1 and path.startswith("plugins/")
    )


def test_the_action_the_check_presses_writes_where_the_check_reads():
    """plugins.an-update-ends-a-running-action reads what the fixture's Hold writes, in the words it writes."""
    for commit in FACTS["history"]:
        hold = (plugin_repository.FIXTURES / commit / "plugins" / "uptime" / "hold.sh").read_text()
        assert f"log={checks.HOLD_LOG}\n" in hold
        assert 'echo "ended ' in hold and 'echo "changed under it ' in hold and 'echo "started ' in hold


def test_the_remove_warning_the_check_waits_for_is_uDecks_own_words():
    english = (Path(__file__).resolve().parents[2] / "Sources" / "UDeckCore" / "Localization" / "English.swift").read_text()
    assert checks.REMOVE_TO_THE_TRASH in english
    assert checks.TRASH_WARNING.format(id="\\(id)") in english


def test_every_check_has_its_row_in_the_table_and_every_row_its_check():
    """docs/plugin-repository.md ("The lab's checks") and check_plugins.py name the same checks."""
    table = (Path(__file__).resolve().parents[2] / "docs" / "plugin-repository.md").read_text()
    section = table.split("### The lab's checks", 1)[1].split("\n### ", 1)[0]
    rows = sorted(line.split("`")[1] for line in section.splitlines() if line.startswith("| `plugins."))
    defined = sorted("plugins." + name.removeprefix("check_").replace("_", "-") for name in dir(checks) if name.startswith("check_"))
    assert rows == defined


def test_the_linked_plugin_asks_and_says_what_the_check_reads():
    """plugins.linked-folder reads the linked card as it reads the fixture's: it asks for consent, and says the two rows."""
    manifest = json.loads(checks._linked_manifest("./run.sh"))
    assert manifest["id"] == checks.LINKED_CARD and manifest["run"] == ["./run.sh"]
    assert manifest["permissions"] == {"exec": ["sysctl"]}
    assert manifest["timeout"] < manifest["interval"]
    script = checks._card_script("first")
    assert script.startswith("#!/bin/sh\n")
    assert f'"{checks.RUNS}"' in script and f'"{checks.VERSION_ROW}", "first"' in script
    assert '"$UDECK_CACHE_DIR/runs"' in script, "counted in uDeck's cache, never in the working copy"


def test_the_working_copy_is_touched_more_often_than_the_plugin_is_polled():
    """plugins.linked-folder's touches come faster than the plugin's interval, and the runs it asks for fit in the time."""
    touched = json.loads(checks._linked_manifest("./run2.sh", interval=checks.TOUCHED_INTERVAL))
    assert touched["interval"] == checks.TOUCHED_INTERVAL > checks.TOUCH_EVERY
    assert touched["timeout"] < touched["interval"]
    window = checks.TOUCHES * checks.TOUCH_EVERY
    assert checks.MINIMUM_RUNS_WHILE_TOUCHED < window // checks.TOUCHED_INTERVAL
    assert json.loads(checks._linked_manifest("./run.sh"))["interval"] == 2


def _record(**changes):
    commit, tree = "a" * 40, "b" * 40
    record = {
        "source": "official",
        "repository": {"provider": "github", "host": "github.com", "path": config.PLUGINS_REPOSITORY},
        "ref": {"kind": "default", "name": "main"},
        "commit": commit,
        "tree": tree,
        "version": "1.0.0",
        "installedAt": "2026-10-02T09:14:03Z",
        "pinned": False,
        "verification": {"status": "verified", "by": "official", "checkedAgainst": commit, "checkedAt": "2026-10-02T09:14:03Z"},
        "previous": None,
    }
    record.update(changes)
    return record


def _judge(record):
    checks._expect_a_whole_record(record, commit="a" * 40, tree="b" * 40, version="1.0.0", pinned=False, previous=None)


def test_a_whole_record_passes():
    _judge(_record())


@pytest.mark.parametrize(
    "change",
    [
        {"source": "somewhere"},
        {"ref": {"kind": "branch", "name": "main"}},
        {"tree": "c" * 40},
        {"pinned": True},
        {"installedAt": ""},
        {"verification": {"status": "modified", "by": None, "checkedAgainst": "a" * 40, "checkedAt": "x"}},
    ],
)
def test_a_record_with_one_field_wrong_is_red(change):
    with pytest.raises(CheckFailed):
        _judge(_record(**change))


@pytest.mark.parametrize("field", ["previous", "ref", "verification", "repository"])
def test_a_record_with_one_field_missing_is_red(field):
    """`previous` is written as null after a first install — left out, the record is not the documented one."""
    record = _record()
    del record[field]
    with pytest.raises(CheckFailed):
        _judge(record)


LAYOUT = {
    "version": 1,
    "tabs": [
        {"id": "T1", "windows": [{"id": "W1", "pluginID": "uptime", "column": 0, "row": 0, "width": 6, "height": 6}]},
        {"id": "T2", "windows": [{"id": "W2", "pluginID": "other", "column": 0, "row": 0, "width": 1, "height": 1}]},
    ],
}


def test_a_window_is_its_id_its_tab_and_its_place():
    (window,) = checks._windows_of(LAYOUT, "uptime")
    assert window == {"tab": "T1", "id": "W1", "pluginID": "uptime", "column": 0, "row": 0, "width": 6, "height": 6}
    moved = json.loads(json.dumps(LAYOUT))
    moved["tabs"][0]["windows"][0]["row"] = 1
    assert checks._windows_of(moved, "uptime") != [window]
    replaced = json.loads(json.dumps(LAYOUT))
    replaced["tabs"][0]["windows"][0]["id"] = "W9"
    assert checks._windows_of(replaced, "uptime") != [window]
    assert checks._windows_of(None, "uptime") == [] and checks._windows_of({"tabs": []}, "uptime") == []


def test_the_panel_is_found_by_its_subrole_and_a_settings_window_by_its_name():
    """The helper is asked for `panel` — the window whose subrole is AXSystemDialog — or a window by its title."""
    assert ax.window_spec(ui.PANEL, ui.PANEL) == "panel"
    assert ax.window_spec(ui.SETTINGS_WINDOW, ui.PANEL) == "title=uDeck Settings"
    assert ax.window_spec(ui.RUSSIAN.settings_window, ui.PANEL) == "title=Настройки uDeck"


def test_a_control_says_its_value_its_title_or_its_description():
    dump = "\n".join(
        [
            "9|AXStaticText||catalogue.uptime.state||uptime 2.0.0 is written for api 2||10;20;|30;40;",
            "9|AXGroup||plugin.uptime.mark|Verified|||10;20;|30;40;",
            "9|AXImage||plugin.x.mark|||Modified locally|10;20;|30;40;",
        ]
    )
    assert ui.says(ui.element(dump, "catalogue.uptime.state")) == "uptime 2.0.0 is written for api 2"
    assert ui.says(ui.element(dump, "plugin.uptime.mark")) == "Verified"
    assert ui.says(ui.element(dump, "plugin.x.mark")) == "Modified locally"
    assert ui.element(dump, "nothing") is None and ui.says(None) == ""


def _source(*parts):
    return (Path(__file__).resolve().parents[2].joinpath(*parts)).read_text()


def test_the_words_the_c2b_checks_wait_for_are_uDecks_own():
    """What the checks of Linked, Link a folder…, the failed run, the command and the search path read, in English.swift."""
    english = _source("Sources", "UDeckCore", "Localization", "English.swift")
    assert f'case .pluginMarkLinked: "{checks.LINKED_MARK}"' in english
    assert checks.ONLY_THE_LINK in english
    assert checks.LINKED_TO.format(id="\\(id)") + "\\(target)." in english
    assert checks.OVER_THE_INSTALLED.format(id="uptime", repository="o/r") == "uptime is installed from github.com/o/r. Linking "
    assert '"\\(id) is installed from \\(source). Linking \\(folder) in its place ' + checks.DELETES_THE_COPY in english
    assert f'"{checks.LAST_RUN_FAILED}\\(at): \\(self(.failureReason(reason)))"' in english
    assert '"\\(id) is a link to \\(destination) now.' in english and checks.OVER_A_LINK.format(id="\\(id)") in english
    assert f'"{checks.VALUES_FROM}\\(time)"' in english
    assert f'"{checks.NOT_INSTALLED} Install command puts' in english
    assert f'"{checks.INSTALLED_COMMAND}\\(path) leads' in english
    assert checks.NOT_UDECKS in english
    assert f'"{checks.SHELL_SAYS[0]}\\(folder)' in english
    assert '"Your shell (\\(shell)) does not look in \\(folder).' in english
    assert checks.EXITED_3.replace("3", "\\(code)") in _source(
        "Packages", "UDeckPluginFormat", "Sources", "UDeckPluginFormat", "Running", "PollExecution.swift")


def test_the_russian_words_are_uDecks_own():
    russian = _source("Sources", "UDeckCore", "Localization", "Russian.swift")
    assert f'"{checks.RU_LAST_RUN_FAILED}\\(at) упал' in russian
    assert f'"{checks.RU_EXITED_3.replace("3", "")}\\(code)"' in russian
    assert f'"{checks.RU_A_FAILURE}\\(self(.failureReason(failure)))"' in russian
    assert f'case .pluginMarkLinked: "{checks.RU_LINKED_MARK}"' in russian
    assert checks.RU_ONLY_THE_LINK in russian
    assert '"\\(id) установлен из \\(source).' in russian
    assert checks.RU_OVER_THE_INSTALLED == f"uptime установлен из github.com/{checks.config.PLUGINS_REPOSITORY}"
    assert f'"{checks.RU_INSTALLED_COMMAND}\\(path)' in russian
    assert f'"{ui.RUSSIAN.settings_item}"' in russian and f'"{ui.RUSSIAN.settings_window}"' in russian


def test_the_russian_words_of_stage_3_are_uDecks_own():
    """plugins.screens-in-russian's second half reads Russian.swift's sentences — held to its templates, and to the
    Russian the Swift tests hold them to word for word wherever those say a whole sentence."""
    russian = _source("Sources", "UDeckCore", "Localization", "Russian.swift")
    tests = "\n".join(_source("Tests", "UDeckCoreTests", name) for name in
                      ("RefFollowerTests.swift", "ForkTests.swift", "InstallFromLinkTests.swift", "AdoptionTests.swift"))
    flat = re.sub(r'"\s*\+\s*"', "", tests)
    official = checks.config.PLUGINS_REPOSITORY

    def said_by_swift(text):
        return f'"{text}"' in flat

    assert f'case .pluginMarkUnverified: "{checks.RU_UNVERIFIED}"' in russian
    assert said_by_swift(checks.RU_FROM_THE_PULL_REQUEST.format(number=3, commit="a1b2c3d"))
    # The sheet's head: line(_, capitalised: true) and the commit — a pull request, a branch, a fork's branch.
    assert '"\\(Self.line(ref, capitalised: true, fork: fork)), коммит \\(commit)"' in russian
    assert 'said = "запрос на слияние #\\(number)"' in russian and 'said = "ветка \\(ref.name ?? "")" + of(fork)' in russian
    assert 'fork.map { " репозитория \\($0)" } ?? ""' in russian
    assert checks.RU_PULL_REQUEST_HEAD.format(number=3, commit="c") == "Запрос на слияние #3, коммит c"
    assert checks.RU_BRANCH_HEAD.format(name="fix/uptime", commit="c") == "Ветка fix/uptime, коммит c"
    assert said_by_swift(checks.RU_FORK_HEAD.format(name="x", fork="someone/udeck-plugins", commit="a1b2c3d"))
    template = checks.RU_NOT_A_FORK.replace("github.com/{repository}", "\\(repository)").replace("github.com/{official}", "\\(official)")
    assert f'"{template}"' in russian
    assert f'"{checks.RU_NOBODY_VERIFIED_LISTED}"' in russian
    # The switch, both ways: catalogueSwitchConfirm with copy(_) and staysAfterSwitching(to:).
    assert '"Сейчас \\(id) — \\(Self.copy(from)). На её место встанет \\(Self.copy(to)). "' in russian
    verified = "проверенная версия {v} из {r}"
    pull = "версия {v} из запроса на слияние #{n}, коммит {c}"
    assert '"проверенная версия \\(version) из \\(repository)"' in russian
    assert '"версия \\(version) из запроса на слияние #\\(number), коммит \\(commit)"' in russian
    stays_verified = "Окна плагина, его настройки и ваше решение о разрешениях останутся."
    stays_unverified = ("Окна плагина и его настройки останутся. Код, который встанет, никто не проверял: плагин спросит "
                        "разрешения перед запуском, если только вы уже не разрешали именно этот код.")
    assert f'"{stays_verified}"' in russian and f'"{stays_unverified}"' in russian
    assert checks.RU_SWITCH_FROM_VERIFIED.format(id="uptime", old="1.1.0", repository=official, new="1.0.1", number=3,
                                                 commit="a1b2c3d") == (
        f"Сейчас uptime — {verified.format(v='1.1.0', r='github.com/' + official)}. На её место встанет "
        f"{pull.format(v='1.0.1', n=3, c='a1b2c3d')}. {stays_unverified}")
    assert checks.RU_SWITCH_TO_VERIFIED.format(id="uptime", old="1.0.1", number=3, commit="a1b2c3d", new="1.1.0",
                                               repository=official) == (
        f"Сейчас uptime — {pull.format(v='1.0.1', n=3, c='a1b2c3d')}. На её место встанет "
        f"{verified.format(v='1.1.0', r='github.com/' + official)}. {stays_verified}")
    # The catalogue row, and what became of the pull request.
    assert said_by_swift(f"{checks.RU_INSTALLED_HERE_UNVERIFIED.format(number=3)} — {checks.RU_CATALOGUE_MERGED_DIFFERS} — uptime нет в ~/.udeck/plugins")
    assert f'case .catalogueClosedUnmerged: "{checks.RU_CATALOGUE_CLOSED}"' in russian
    assert f'case .catalogueMergedDiffers: "{checks.RU_CATALOGUE_MERGED_DIFFERS}"' in russian
    for sentence in (checks.RU_MERGED_DIFFERS, checks.RU_MERGED_NOTHING_OFFERED, checks.RU_CLOSED_UNMERGED, checks.RU_REWRITTEN):
        assert said_by_swift(sentence.format(number=3)), sentence
    assert said_by_swift(checks.RU_CHANGED_STILL.format(number=3, version="1.0.1"))
    assert said_by_swift(checks.RU_NOT_CHECKED_SINCE.format(number=3) + "14:02")
    # The card: where the code comes from, and a plugin that asks for nothing.
    assert '"Этот код никто не проверял: он из \\(Self.lineFrom(ref)) репозитория \\(repository)"' in russian
    assert '", а не из того, что репозиторий влил. uDeck спросит снова, как только он изменится."' in russian
    assert checks.RU_NOBODY_VERIFIED.format(number=3, repository=official) == (
        f"Этот код никто не проверял: он из запроса на слияние #3 репозитория github.com/{official}, а не из того, что "
        "репозиторий влил. uDeck спросит снова, как только он изменится.")
    assert 'return "запроса на слияние #\\(number)"' in russian
    asks_nothing = checks.RU_ASKS_NOTHING_UNVERIFIED.format(name="\\(name)")
    assert f'"{asks_nothing}"' in russian


def _the_cards_in_russian(leave_out=(), english_header=None):
    """The two copies' cards as a walk of the panel hands them over: one card each, as run 38966347071 kept them."""
    source = checks.RU_NOBODY_VERIFIED.format(number=checks.PULL, repository=checks.config.PLUGINS_REPOSITORY)
    lines = []
    for x, plugin in ((854, checks.UPTIME), (1385, checks.ASKS_NOTHING)):
        header = "Unverified" if plugin == english_header else checks.RU_UNVERIFIED
        lines += [f"3|AXStaticText||card.{plugin}.unverified||{header}||{x};85;|88;13;",
                  f"4|AXStaticText||consent.{plugin}.source||{source}||{x};120;|300;40;",
                  f"4|AXButton||consent.{plugin}.allow||||{x};232;|152;23;"]  # fmt: skip
    return "\n".join(line for line in lines if not any(f"|{gone}|" in line for gone in leave_out))


def test_each_card_of_the_pull_requests_copies_asks_in_russian():
    """The second half's cards are read card by card: one card asking, or one header said in English, is red — it
    used to take either card's words for both."""
    asks = [checks.RU_ASKS_NOTHING_UNVERIFIED.format(name=checks.ASKS_NOTHING_NAME)]
    official = checks.config.PLUGINS_REPOSITORY
    checks._the_cards_ask_in_russian(_the_cards_in_russian(), asks, official)
    for gone in (f"consent.{checks.UPTIME}.allow", f"consent.{checks.ASKS_NOTHING}.allow",
                 f"card.{checks.UPTIME}.unverified", f"consent.{checks.ASKS_NOTHING}.source"):  # fmt: skip
        with pytest.raises(CheckFailed):
            checks._the_cards_ask_in_russian(_the_cards_in_russian(leave_out=(gone,)), asks, official)
    for plugin in (checks.UPTIME, checks.ASKS_NOTHING):
        with pytest.raises(CheckFailed, match=f"{plugin}'s card says 'Unverified'"):
            checks._the_cards_ask_in_russian(_the_cards_in_russian(english_header=plugin), asks, official)
    with pytest.raises(CheckFailed, match="does not say"):
        checks._the_cards_ask_in_russian(_the_cards_in_russian(), ["Asks nothing asks for nothing"], official)


def test_the_panel_buttons_the_check_expects_are_the_panels_own():
    """plugins.failed-run-on-a-fresh-card reads the panel's buttons by the identifiers WorkspaceView gives them."""
    workspace = _source("Sources", "UDeckKit", "Views", "WorkspaceView.swift")
    assert sorted(re.findall(r'identifier: "(panel\.[A-Za-z]+)"', workspace)) == list(checks.PANEL_BUTTONS)
    assert "rectangle.compress.vertical" not in workspace and "controlDensity" not in workspace


def test_the_command_is_where_the_bundle_and_uDeck_put_it():
    """plugins.install-command looks for the command where make-app.sh puts it and CommandInstall links to."""
    assert checks.COMMAND_IN_THE_BUNDLE == "/Applications/uDeck.app/Contents/Helpers/udeck-plugin"
    assert 'cp "$COMMAND" "$APP/Contents/Helpers/udeck-plugin"' in _source("Scripts", "make-app.sh")
    command = _source("Sources", "UDeckCore", "Command", "CommandInstall.swift")
    assert 'static let inBundle = "Contents/Helpers/udeck-plugin"' in command
    assert 'case "zsh": return ("~/.zshrc", #"' + checks.ZSH_LINE + '"#)' in command
    assert checks.COMMAND_LINK == "~/.local/bin/udeck-plugin"
    assert checks.COMMAND_USAGE in _source("Packages", "UDeckPluginFormat", "Sources", "UDeckPluginCommand", "Command.swift")


def test_the_flaky_plugin_fails_only_while_the_file_is_there_and_its_card_outlives_the_wait():
    script = checks._card_script("steady", ttl=checks.FLAKY_TTL, fail_when=checks.FAIL, says=checks.FLAKY_SAYS)
    first, failing = script.splitlines()[:2]
    assert first == "#!/bin/sh"
    assert failing == f'if [ -f "$UDECK_PLUGIN_DIR/{checks.FAIL}" ]; then echo \'{checks.FLAKY_SAYS}\' >&2; exit 3; fi'
    assert f'"ttl": {checks.FLAKY_TTL}' in script
    # Fresh for the whole of the check's waits: the card is read, then the
    # failure waited for, then Settings, all well inside the card's ttl.
    assert checks.FLAKY_INTERVAL * 3 + checks.CARD_SECONDS * 2 + checks.NOTICED_SECONDS < checks.FLAKY_TTL
    manifest = json.loads(checks._manifest(checks.FLAKY, "./run.sh", interval=checks.FLAKY_INTERVAL))
    assert manifest["timeout"] < manifest["interval"] == checks.FLAKY_INTERVAL


def test_the_logged_plugin_says_something_on_stderr_and_runs_often_enough():
    script = checks._card_script("logged", stderr=checks.LOGGED_SAYS)
    assert f"echo '{checks.LOGGED_SAYS}' >&2" in script
    assert checks.RUN_LOG_INTERVAL * (checks.RUN_LOG_ENTRIES + 1) < checks.RUN_LOG_SECONDS


def test_the_greeter_runs_a_bare_name_and_each_folder_says_which_it_is():
    manifest = json.loads(checks._manifest(checks.GREETER, checks.GREET))
    assert manifest["run"] == [checks.GREET] and "/" not in checks.GREET
    for which in ("a", "b"):
        assert f'"{checks.VERSION_ROW}", "{which}"' in checks._card_script(which)


# --- Updating by themselves ----------------------------------------------------------------


def test_the_words_the_update_checks_wait_for_are_uDecks_own():
    """plugins.verified-updates-itself and plugins.permissions-change-only-offers read uDeck's own sentences."""
    english = _source("Sources", "UDeckCore", "Localization", "English.swift")
    assert 'case .catalogueAvailable(let version): "\\(version) available"' in english
    assert 'case .catalogueAsksDifferently: "asks for different permissions"' in english
    assert checks.AVAILABLE_1_2_0_ASKS == "1.2.0 available" + ", " + "asks for different permissions"
    assert f'"{checks.UPDATED_BY_ITSELF}\\(date)"' in english
    russian = _source("Sources", "UDeckCore", "Localization", "Russian.swift")
    assert f'"{checks.RU_UPDATED_BY_ITSELF}\\(date)"' in russian
    assert checks.RU_UPDATES_BY_THEMSELVES_HELP in russian
    assert 'case .catalogueAvailable(let version): "Доступна \\(version)"' in russian
    assert checks.RU_AVAILABLE_1_1_0 == "Доступна 1.1.0"
    # The row joins the two (OfferText), and the identifiers the checks read are the views' own.
    views = _source("Sources", "UDeckKit", "Views", "PluginRepositoryViews.swift")
    assert '", " + strings(.catalogueAsksDifferently)' in views
    for identifier in ('"catalogue.autoUpdate"', '"catalogue.autoUpdateHelp"', '"plugin.\\(id).updatedByItself"'):
        assert identifier in views


def test_the_reasons_the_checks_read_in_uDecks_log_are_the_ones_it_writes():
    """The controls read uDeck's own log for why a plugin was left alone: the sentence, and each reason's name, are uDeck's."""
    model = _source("Sources", "UDeckKit", "Plugins", "DeckModel+Repository.swift")
    swift = {
        checks.DOES_NOT_UPDATE_ITSELF: '"\\(id, privacy: .public) does not update itself: \\(String(describing: reason), privacy: .public)"',
        checks.UPDATES_ITSELF_LATER: '"\\(id, privacy: .public) updates itself later: \\(String(describing: wait), privacy: .public)"',
    }
    for words, written in swift.items():
        assert written in model, f"DeckModel no longer writes {words!r}"
        assert words.format(id="", reason="", wait="").strip() in written
    decider = _source("Sources", "UDeckCore", "Plugins", "Repository", "AutoUpdate.swift")
    for reason in ("pinned", "asksDifferently", "actionRunning"):
        assert re.search(rf"^\s+case {reason}$", decider, re.M), f"AutoUpdate has no case {reason}"
    # The tick the update that waited comes on: the minute's clock, which runs while any source can be read.
    sources = _source("Sources", "UDeckKit", "Plugins", "DeckModel+Sources.swift")
    assert f"Timer(timeInterval: {checks.TICK_SECONDS}, repeats: true)" in sources
    assert "func tick() {\n        updateVerifiedPlugins()" in sources


def test_every_older_check_that_moves_main_starts_with_updates_by_themselves_off():
    """A check that moves main and then presses Update has to see an offer: with the switch as shipped, uDeck installs c2 by itself first."""
    tree = ast.parse((Path(__file__).resolve().parents[1] / "checks" / "check_plugins.py").read_text())
    # The ones whose point is what happens by itself after main moved — an update made, or, the official address
    # another repository's, none made.
    new = {"check_verified_updates_itself", "check_permissions_change_only_offers", "check_official_id_mismatch"}
    moving = []
    for function in tree.body:
        if not isinstance(function, ast.FunctionDef) or not function.name.startswith("check_"):
            continue
        source = ast.unparse(function)
        if "main='c2'" in source.replace("main=\"c2\"", "main='c2'") and "tell(" in source:
            moving.append(function.name)
            if function.name not in new:
                assert "updates_itself=False" in source, f"{function.name} moves main and starts uDeck updating by itself"
    assert {"check_update_keeps_the_window", "check_every_replacement_warns_first",
            "check_an_update_ends_a_running_action", "check_screens_in_russian"} <= set(moving)
    russian = ast.unparse(next(f for f in tree.body if isinstance(f, ast.FunctionDef) and f.name == "check_screens_in_russian"))
    assert "'autoUpdateVerified': False" in russian, "the Russian check writes settings.json itself, after _prepare"


def test_aging_the_catalogue_moves_its_last_read_back_and_keeps_the_rest(tmp_path, monkeypatch, capsys):
    """The script the guest's Python runs, run here in this process — this file runs nothing of its own."""
    state = tmp_path / "state.json"
    state.write_text(json.dumps({"head": "abc", "lastSuccess": "2026-10-10T08:00:00Z", "lastAttempt": "2026-10-10T08:00:00Z",
                                 "failuresInARow": 0, "rateLimit": {"remaining": 59}}))
    monkeypatch.setattr(sys, "argv", ["-c", str(state), "2"])
    exec(compile(checks.AGE_THE_CATALOGUE, "<the guest's python3 -c>", "exec"), {"__name__": "__main__"})
    said = capsys.readouterr().out
    aged = json.loads((tmp_path / "state.json.new").read_text())
    then = calendar.timegm(time.strptime(aged["lastSuccess"], "%Y-%m-%dT%H:%M:%SZ"))
    assert abs(time.time() - then - 2 * 86400) < 120
    assert aged["lastAttempt"] == aged["lastSuccess"] == said.strip()
    assert {k: v for k, v in aged.items() if not k.startswith("last")} == {"head": "abc", "failuresInARow": 0, "rateLimit": {"remaining": 59}}
    assert checks.AGED_DAYS > 1, "over a day, or the launch does not read the catalogue (CatalogueSchedule.refreshesAtLaunch)"
    assert checks.CATALOGUE_STATE == "~/.udeck/catalogue/official/state.json"


def _request(path, host="raw", status=200, lab=False):
    return plugin_repository.Request(at=0, method="GET", host=host, path=path, query="", status=status, lab=lab)


def test_a_download_is_a_plugins_files_and_not_its_manifest():
    """What _files_fetched counts: a read of the catalogue fetches manifests, a download every other file."""
    raw = f"/raw/{config.PLUGINS_REPOSITORY}/{'c' * 40}"
    heard = [
        _request(f"{raw}/plugins/uptime/manifest.json"),
        _request(f"{raw}/plugins/uptime/manifest.ru.json"),
        _request(f"{raw}/udeck-plugins.json"),
        _request(f"{raw}/plugins/other/run.sh"),
        _request(f"/api/repos/{config.PLUGINS_REPOSITORY}/commits/main", host="api"),
    ]
    assert checks._files_fetched(heard, "uptime") == []
    fetched = [_request(f"{raw}/plugins/uptime/uptime.sh"), _request(f"{raw}/plugins/uptime/hold.sh", status=404)]
    assert checks._files_fetched(heard + fetched, "uptime") == fetched


# --- Installing from a link (stage 3) --------------------------------------------------------


def test_the_pull_request_and_the_branch_the_checks_paste_are_the_fixtures_pr3():
    """pr3 is made on c1 and differs from it in uptime and asks-nothing alone: the two the link sheet lists."""
    assert FACTS["parents"]["pr3"] == "c1"
    assert checks.PULLS[checks.PULL]["head"] == "pr3" and checks.BRANCHES[checks.BRANCH] == "pr3"
    assert checks.PULLS[checks.PULL]["head_repo"] == checks.FORK != config.PLUGINS_REPOSITORY, "a fork's pull request"
    paths = {name: FACTS["commits"][name]["paths"] for name in ("c1", "pr3")}
    folders = {name: {p.split("/")[1] for p in found if p.startswith("plugins/") and p.count("/") == 1} for name, found in paths.items()}
    assert folders["pr3"] - folders["c1"] == {checks.ASKS_NOTHING}
    differ = {f for f in folders["pr3"] if paths["c1"].get(f"plugins/{f}", {}).get("sha") != paths["pr3"][f"plugins/{f}"]["sha"]}
    assert differ == {checks.ASKS_NOTHING, checks.UPTIME}
    assert "/" in checks.BRANCH and checks.BRANCH_LINK.endswith(f"/tree/{checks.BRANCH}/plugins/{checks.UPTIME}")
    assert not checks.PULL_LINK.startswith("http"), "pasted as a person copies it from an address bar, without the scheme"


def test_the_asks_nothing_plugin_says_what_the_check_reads():
    manifest = json.loads((plugin_repository.FIXTURES / "pr3" / "plugins" / checks.ASKS_NOTHING / "manifest.json").read_text())
    assert manifest["name"] == checks.ASKS_NOTHING_NAME and "permissions" not in manifest
    script = (plugin_repository.FIXTURES / "pr3" / "plugins" / checks.ASKS_NOTHING / "run.sh").read_text()
    assert 'count_file="${UDECK_CACHE_DIR:-/tmp}/runs"' in script, "counted in uDeck's cache, which the check reads"
    assert checks.RAN.format(n="%s") in script


def test_the_words_the_link_checks_wait_for_are_uDecks_own():
    """What the four checks of installing from a link read: in English.swift, or held equal to it by the Swift tests."""
    english = _source("Sources", "UDeckCore", "Localization", "English.swift")
    assert f'case .pluginMarkUnverified: "{checks.UNVERIFIED}"' in english
    assert 'case .pluginFromPullRequest(let number, let commit): "' + checks.FROM_THE_PULL_REQUEST.format(
        number="\\(number)", commit="\\(commit)") + '"' in english
    assert 'case .pluginFromBranch(let name, let commit, let fork): "' + checks.FROM_THE_BRANCH.format(
        name="\\(name)\\(Self.of(fork))", commit="\\(commit)") + '"' in english
    assert 'fork.map { " of \\($0)" } ?? ""' in english, "nothing after the official repository's own branch"
    assert '"' + checks.ASKS_NOTHING_UNVERIFIED.format(name="\\(name)") + '"' in english
    assert '"Nobody verified this code: it comes from \\(Self.line(ref)) of \\(repository)"' in english
    assert 'said = "pull request #\\(number)"' in english
    # The sentences Swift's own tests hold the English to, word for word.
    swift = _source("Tests", "UDeckCoreTests", "InstallFromLinkTests.swift")
    assert f'== "{checks.LINK_HEAD.format(number=3, commit="a1b2c3d")}"' in swift
    official = config.PLUGINS_REPOSITORY
    from_verified = checks.SWITCH_FROM_VERIFIED.format(id="uptime", old="1.0.0", repository=official, new="1.0.1",
                                                       number=3, commit="a1b2c3d")
    to_verified = checks.SWITCH_TO_VERIFIED.format(id="uptime", old="1.0.1", number=3, commit="a1b2c3d", new="1.0.0",
                                                   repository=official)
    flat = re.sub(r'"\s*\+\s*"', "", swift)
    assert from_verified in flat and to_verified in flat
    # The catalogue row of a copy whose folder has gone, and the link sheet with the catalogue off.
    assert '"' + checks.INSTALLED_HERE_UNVERIFIED.format(line="\\(Self.line(ref, fork: fork))") + '"' in english
    assert 'case .catalogueMissing(let id, let path): "\\(id) is not in \\(path)"' in english
    assert checks.NOT_IN_THE_PLUGINS_FOLDER == "{id} is not in " + checks.UDECK_HOME + "/plugins"
    gone = checks.INSTALLED_HERE_UNVERIFIED.format(line="pull request #3") + " — " + checks.NOT_IN_THE_PLUGINS_FOLDER.format(id="uptime")
    assert f'== "{gone}"' in flat
    assert '"' + checks.LINK_OFF + '"' in english and '"' + checks.CATALOGUE_OFF + '"' in english


def test_the_controls_the_link_checks_press_and_read_are_the_views_own():
    views = _source("Sources", "UDeckKit", "Views", "PluginRepositoryViews.swift")
    for identifier in ('"plugins.installFromLink"', '"link.field"', '"link.lookUp"', '"link.close"', '"link.head"',
                       '"link.refused"', '"link.catalogue"', '"link.\\(id).install"', '"link.\\(id).confirm"',
                       '"link.\\(id).confirmText"', '"link.\\(id).problem"', '"plugin.\\(id).switchToVerified"',
                       '"plugin.\\(id).refPage"', '"plugin.\\(id).from"', '"plugin.\\(id).confirmText"',
                       '"catalogue.\\(id).switchToVerified"', '"\\(named).state"', '"\\(named).reinstall"',
                       '"link.off"', '"link.addAsASource"'):
        assert identifier in views, identifier
    # A catalogue row's controls are `catalogue.<id>.*` in the official catalogue, `source.<sid>.plugin.<id>.*` in a
    # source's (S4-06).
    assert 'isOfficial ? "catalogue.\\(id)" : "source.\\(source).plugin.\\(id)"' in views
    assert '"card.\\(window.pluginID.rawValue).unverified"' in _source("Sources", "UDeckKit", "Views", "DeckWindowView.swift")
    assert '"consent.\\(pluginID.rawValue).source"' in _source("Sources", "UDeckKit", "Views", "PermissionRequestView.swift")


def test_only_the_requests_named_pass_and_every_file_once_when_asked():
    commit = "e" * 40
    raw = f"/raw/{config.PLUGINS_REPOSITORY}/{commit}"
    api = f"/api/repos/{config.PLUGINS_REPOSITORY}/pulls/3"
    heard = [_request(api, host="api"), _request(f"{raw}/plugins/uptime/uptime.sh"), _request(f"{raw}/plugins/uptime/hold.sh")]
    checks._expect_only(heard, commit, api={api}, raw={"plugins/uptime/uptime.sh", "plugins/uptime/hold.sh"},
                        what="x", every=True)
    for stray in (_request(f"/raw/{checks.FORK}/{commit}/plugins/uptime/uptime.sh"),
                  _request(f"/raw/{config.PLUGINS_REPOSITORY}/{'f' * 40}/plugins/uptime/uptime.sh"),
                  _request(f"{raw}/plugins/cpu/manifest.json"),
                  _request(f"/api/repos/{config.PLUGINS_REPOSITORY}/commits/main", host="api")):
        with pytest.raises(CheckFailed):
            checks._expect_only(heard + [stray], commit, api={api},
                                raw={"plugins/uptime/uptime.sh", "plugins/uptime/hold.sh"}, what="x")
    with pytest.raises(CheckFailed):
        checks._expect_only(heard[:2], commit, api={api}, raw={"plugins/uptime/uptime.sh", "plugins/uptime/hold.sh"},
                            what="x", every=True)
    with pytest.raises(CheckFailed):
        checks._expect_only(heard + heard[1:2], commit, api={api},
                            raw={"plugins/uptime/uptime.sh", "plugins/uptime/hold.sh"}, what="x", every=True)


def test_only_the_named_requests_of_the_fork_pass_when_a_check_names_the_fork():
    commit = "e" * 40
    fork_raw = f"/raw/{checks.FORK}/{commit}"
    fork_api = f"/api/repos/{checks.FORK}"
    heard = [_request(fork_api, host="api"), _request(f"{fork_raw}/plugins/uptime/uptime.sh")]
    checks._expect_only(heard, commit, api={fork_api}, raw={"plugins/uptime/uptime.sh"}, what="x", every=True,
                        repository=checks.FORK)
    for stray in (_request(f"/raw/{config.PLUGINS_REPOSITORY}/{commit}/plugins/uptime/uptime.sh"),
                  _request(f"/api/repos/{config.PLUGINS_REPOSITORY}/commits/refs/heads/x", host="api")):
        with pytest.raises(CheckFailed):
            checks._expect_only(heard + [stray], commit, api={fork_api}, raw={"plugins/uptime/uptime.sh"}, what="x",
                                repository=checks.FORK)


def test_an_unverified_record_is_the_official_sources_at_its_ref_and_nobodys_guarantee():
    record = _record(ref={"kind": "pr", "name": "3"}, version="1.0.1",
                     verification={"status": "unverified", "by": None, "checkedAgainst": "a" * 40, "checkedAt": "x"})
    checks._expect_an_unverified_record(record, ref={"kind": "pr", "name": "3"}, commit="a" * 40, version="1.0.1")
    for change in ({"verification": {"status": "verified", "by": "official"}},
                   {"verification": {"status": "unverified"}},
                   {"ref": {"kind": "default", "name": "main"}},
                   {"repository": {"provider": "github", "host": "github.com", "path": checks.FORK}}):
        with pytest.raises(CheckFailed):
            checks._expect_an_unverified_record({**record, **change}, ref={"kind": "pr", "name": "3"}, commit="a" * 40,
                                                version="1.0.1")
    # A fork's branch: the official source's, at the fork.
    forked = {**record, "ref": {"kind": "branch", "name": "x"},
              "repository": {"provider": "github", "host": "github.com", "path": checks.FORK}}  # fmt: skip
    checks._expect_an_unverified_record(forked, ref={"kind": "branch", "name": "x"}, commit="a" * 40, version="1.0.1",
                                        repository=checks.FORK)
    with pytest.raises(CheckFailed):
        checks._expect_an_unverified_record(forked, ref={"kind": "branch", "name": "x"}, commit="a" * 40, version="1.0.1")


class _Shell:
    """A guest whose `cat` of one file answers `text`."""

    def __init__(self, text):
        self.text = text
        self.asked = []

    def ask(self, command, step):
        self.asked.append(command)
        return type("Done", (), {"stdout": self.text, "returncode": 0})()


def test_a_count_of_runs_is_a_number_or_nothing():
    """What the asks-nothing check compares across the edit: the plugin's own count, read as a number."""
    for text, count in (("1\n", 1), ("12", 12), ("", None), ("x\n", None), ("-1", None), ("١", None)):
        machine = type("Guest", (), {"ssh": _Shell(text)})()
        assert checks._count_of_runs(machine, "~/.udeck/cache/asks-nothing/runs") == count, text
        assert machine.ssh.asked == ["cat ~/.udeck/cache/asks-nothing/runs 2>/dev/null || true"]


def test_the_limit_holds_five_of_the_slowest_walks_measured():
    """Check now, its message, the pane kept, Check now again and the install: five walks of 76 s, R3's slowest."""
    assert checks.LIMIT_SECONDS >= 5 * 76


class _Walks:
    """A machine whose screen is read from a list of walks, each taking `seconds`."""

    def __init__(self, walks, seconds=40):
        self.walks = list(walks)
        self.seconds = seconds
        self.now = 0.0
        self.read = 0

    def clock(self):
        return self.now

    def sleep(self, seconds):
        self.now += seconds


def test_a_verdict_at_the_deadline_comes_from_a_walk_begun_after_it(monkeypatch):
    """R3's measurement: one walk outlasts the deadline, and a walk that crossed a change returns the control
    it replaced as it was, or not at all — so a walk begun before the deadline decides nothing against it."""
    mark = "5|AXStaticText||plugin.uptime.mark||Modified locally||226;279;|93;13;"
    stale = "5|AXStaticText||plugin.uptime.mark||Verified||226;279;|93;13;"

    def read(machine, step, window=None):
        machine.read += 1
        found = machine.walks.pop(0) if len(machine.walks) > 1 else machine.walks[0]
        machine.now += machine.seconds
        return found

    monkeypatch.setattr(checks, "_read_the_screen", read)
    modified = lambda said: said == "Modified locally"  # noqa: E731
    for first in ("", stale):
        machine = _Walks([first, mark])
        assert checks._wait_until(machine, "plugin.uptime.mark", modified, 15) == "Modified locally" and machine.read == 2, \
            "missing, or as it was: the walk crossed the change"
    machine = _Walks([""])
    assert checks._wait_until(machine, "plugin.uptime.mark", modified, 15) is None and machine.read == 2, \
        "still missing in a walk begun after the deadline: believed"
    machine = _Walks([stale])
    assert checks._wait_until(machine, "plugin.uptime.mark", modified, 15) == "Verified" and machine.read == 2
    machine = _Walks([mark])
    assert checks._wait_until(machine, "plugin.uptime.mark", modified, 15) == "Modified locally" and machine.read == 1, \
        "satisfied at once: no walk more"
    machine = _Walks([stale], seconds=2)
    assert checks._wait_until(machine, "plugin.uptime.mark", modified, 15) == "Verified"
    assert machine.now >= 15 and machine.read == 6, "short walks go on until one begins at the deadline"


# --- A pull request merged or closed (stage 3) ------------------------------------------------


def test_the_merges_the_checks_make_are_the_fixtures():
    """s1 is pr3 squashed onto c1 — every plugin folder pr3's; s2 changes uptime alone; m1 is s2's content on s1."""
    paths = {name: FACTS["commits"][name]["paths"] for name in ("pr3", "s1", "s2", "m1")}
    assert FACTS["parents"]["s1"] == FACTS["parents"]["s2"] == "c1" and FACTS["parents"]["m1"] == "s1"
    plugins = lambda name: {p: e["sha"] for p, e in paths[name].items() if p.startswith("plugins/") and p.count("/") == 1}  # noqa: E731
    assert plugins("s1") == plugins("pr3"), "merged as exactly its head"
    differ = {p for p in plugins("s2") if plugins("s2")[p] != plugins("pr3").get(p)}
    assert differ == {"plugins/uptime"}, "merged with a change to uptime alone"
    assert plugins("m1") == plugins("s2") and FACTS["commits"]["m1"]["sha"] != FACTS["commits"]["s2"]["sha"]
    manifest = json.loads((plugin_repository.FIXTURES / "s2" / "plugins" / "uptime" / "manifest.json").read_text())
    assert manifest["version"] == "1.0.2", "what AVAILABLE and the update to the verified version name"


class _Telling:
    def __init__(self):
        self.told = []

    def tell(self, step, **changes):
        self.told.append(changes)


def test_a_merge_is_the_pull_request_closed_merged_as_the_commit_and_its_branch_gone():
    scene = type("Scene", (), {"github": _Telling()})()
    checks._merge(scene, "s1", "squash-merging")
    checks._merge(scene, "s1", "and moving on", main="m1")
    first, second = scene.github.told
    assert first["main"] == "s1" and second["main"] == "m1" and first["branches"] == {} == second["branches"]
    for told in (first, second):
        pull = told["pulls"][checks.PULL]
        assert (pull["state"], pull["merged"], pull["merge_commit"], pull["head"]) == ("closed", True, "s1", "pr3")
        assert pull["head_repo"] == checks.FORK, "the rest of the pull request as it was"
        assert "base" not in pull, "into main, as the fake says when nothing else is named"
    # Into another branch: that branch at the commit, main where the check says, the pull request's base that branch.
    checks._merge(scene, "s1", "merging into next", main="c1", into=checks.NEXT)
    third = scene.github.told[-1]
    assert third["main"] == "c1" and third["branches"] == {checks.NEXT: "s1"}
    assert third["pulls"][checks.PULL]["base"] == checks.NEXT and third["pulls"][checks.PULL]["merge_commit"] == "s1"
    with pytest.raises(ValueError):
        checks._merge(scene, "s1", "merging into next with main not said", into=checks.NEXT)


def test_the_words_the_merge_and_close_checks_wait_for_are_uDecks_own():
    english = _source("Sources", "UDeckCore", "Localization", "English.swift")
    assert '"' + checks.MERGED_DIFFERS.format(number="\\(number)") + '"' in english
    assert '"' + checks.CLOSED_UNMERGED.format(number="\\(number)") + '"' in english
    assert f'case .catalogueMergedDiffers: "{checks.CATALOGUE_MERGED_DIFFERS}"' in english
    assert f'case .catalogueClosedUnmerged: "{checks.CATALOGUE_CLOSED}"' in english
    assert 'case .windowReinstallBrings(let copy): "Reinstall puts back \\(Self.copy(copy)): code nobody verified."' in english
    # The official repository's own branch: nothing after its name (`of`).
    assert 'case .branch(let branch, let commit, let version, let fork): "\\(version) from branch \\(branch)\\(of(fork)) at \\(commit)"' in english
    assert checks.REINSTALL_BRINGS == "Reinstall puts back {version} from branch {name} at {commit}: code nobody verified."
    assert 'case .catalogueAvailable(let version): "' + checks.AVAILABLE.format(version="\\(version)") + '"' in english
    assert 'count == 1 ? "1 update is waiting"' in english
    # Swift's own tests hold the same sentences, word for word.
    swift = _source("Tests", "UDeckCoreTests", "AdoptionTests.swift")
    assert f'"{checks.MERGED_DIFFERS.format(number=3)}"' in swift and f'"{checks.CLOSED_UNMERGED.format(number=3)}"' in swift
    assert f'"{checks.REINSTALL_BRINGS.format(version="1.0.1", name="fix/uptime", commit="a1b2c3d")}"' in swift


def test_the_controls_the_merge_and_close_checks_press_and_read_are_the_views_own():
    views = _source("Sources", "UDeckKit", "Views", "PluginRepositoryViews.swift")
    for identifier in ('"plugin.\\(id).update"', '"catalogue.updatesWaiting"',
                       '"plugin.\\(id).mark"', '"plugin.\\(id).offer"', '"plugin.\\(id).remove"', '"catalogue.checkNow"'):
        assert identifier in views, identifier
    # What became of the pull request is one of the lines the row says of code nobody verified, each identified by
    # the end UDeckCore gives it (`UnverifiedRow.said`).
    assert '"plugin.\\(id).\\(said.suffix)"' in views
    assert 'Said(suffix: "pullRequest"' in _source("Sources", "UDeckCore", "Plugins", "Repository", "UnverifiedCopies.swift")
    settings = _source("Sources", "UDeckKit", "Views", "SettingsView.swift")
    for identifier in ('"plugins.nothingInstalled"', '"plugin.\\(plugin.folderName).enabled"', '"plugin.\\(plugin.folderName).more"',
                       '"plugin.\\(manifest.id).allow"', '"plugin.\\(manifest.id).decline"', '"plugin.\\(manifest.id).asksNothing"'):
        assert identifier in settings, identifier
    assert '"window.\\(window.pluginID.rawValue).reinstallSays"' in _source("Sources", "UDeckKit", "Views", "DeckWindowView.swift")
    store = _source("Sources", "UDeckCore", "Plugins", "Repository", "CatalogueStore.swift")
    assert checks.FOLLOWED == checks.UDECK_HOME + "/catalogue/official/followed.json"
    assert 'appendingPathComponent("followed.json")' in store and "paths: UDeckPaths, source: String = InstalledPlugins.officialSource" in store


def test_a_folder_read_twice_unchanged_is_the_same_text():
    """`_identity` reads every name with its inode and time, sorted: the same command each time, and a folder gone is red."""
    asked = []

    class Shell:
        def __init__(self, stdout, returncode=0):
            self.stdout, self.returncode = stdout, returncode

        def ask(self, command, step):
            asked.append(command)
            return type("Done", (), {"stdout": self.stdout, "returncode": self.returncode, "stderr": ""})()

    machine = type("Guest", (), {"ssh": Shell("12 1.5 .\n13 1.5 ./uptime.sh\n")})()
    assert checks._identity(machine, "uptime", "before") == "12 1.5 .\n13 1.5 ./uptime.sh\n"
    assert asked[-1] == "cd ~/.udeck/plugins/uptime && find . -exec /usr/bin/stat -f '%i %Fm %N' {} + | LC_ALL=C sort"
    machine = type("Guest", (), {"ssh": Shell("", returncode=1)})()
    with pytest.raises(CheckFailed):
        checks._identity(machine, "uptime", "after")


def test_the_copy_a_record_says_is_all_of_it_but_what_was_last_found():
    record = {"ref": {"kind": "pr", "name": "3"}, "commit": "c", "tree": "t", "version": "1.0.1",
              "verification": {"status": "unverified", "checkedAgainst": "h1"}}
    moved = {**record, "verification": {"status": "unverified", "checkedAgainst": "h2"}}
    assert checks._the_copy(record) == checks._the_copy(moved), "the head moved: the same copy"
    assert checks._the_copy({**record, "commit": "d"}) != checks._the_copy(record)
    assert checks._the_copy(None) == {}


# --- Following a branch or a pull request (stage 3, R5) --------------------------------------


def test_the_heads_the_follow_checks_move_to_are_the_fixtures():
    """p2 continues pr3 with uptime changed and its manifest not; p2x is p2's content made on c1, which does not."""
    commits = FACTS["commits"]
    assert FACTS["parents"]["p2"] == "pr3" and FACTS["parents"]["p2x"] == "c1" and FACTS["contents"]["p2x"] == "p2"
    for path in ("plugins/uptime/manifest.json", "plugins/uptime/manifest.ru.json"):
        assert commits["p2"]["paths"][path] == commits["pr3"]["paths"][path], "nothing a read of p2 fetches is new"
    assert commits["p2"]["paths"]["plugins/uptime"] != commits["pr3"]["paths"]["plugins/uptime"], "uptime is another tree"
    assert commits["p2x"]["paths"]["plugins/uptime"] == commits["p2"]["paths"]["plugins/uptime"]
    assert checks.BRANCHES == {checks.BRANCH: "pr3"} and checks.PULLS[checks.PULL]["head"] == "pr3", "both start at pr3"


def test_moving_the_pull_request_keeps_the_rest_of_it():
    scene = type("Scene", (), {"github": _Telling()})()
    checks._move_the_pull_request(scene, "p2x", "pushing again")
    pull = scene.github.told[-1]["pulls"][checks.PULL]
    assert pull == {**checks.PULLS[checks.PULL], "head": "p2x"} and pull["state"] == "open" and pull["merged"] is False


def test_leaving_the_reserve_spends_what_the_read_at_launch_would_need_beyond_the_catalogue():
    """After the requests the log holds, one more — the catalogue's own question — leaves one fewer than the reserve."""
    log = [plugin_repository.Request(1.0, "GET", host, f"/{host}/x", "", status, False)
           for host, status in (("api", 200), ("api", 304), ("raw", 200), ("lab", 200), ("api", 403), ("api", 200))]  # fmt: skip

    class GitHub(_Telling):
        def read_log(self, step):
            return log

    scene = type("Scene", (), {"github": GitHub()})()
    checks._leave_the_reserve(scene, "leaving the reserve")
    spent = scene.github.told[-1]["spent"]
    used = 3  # three API answers spent the hour's requests; a refusal and the raw and lab hosts did not
    assert spent == checks.HOURLY - used - 1 - (checks.RESERVE - 1)
    assert checks.HOURLY - used - 1 - spent == checks.RESERVE - 1, "what the next answer says is left: one below the reserve"
    fake = _fake()
    assert checks.HOURLY == fake.LIMIT
    swift = _source("Sources", "UDeckCore", "Plugins", "Repository", "RateLimit.swift")
    assert f"public static let reserveForTheOperator = {checks.RESERVE}\n" in swift


def test_the_words_the_follow_checks_wait_for_are_uDecks_own():
    english = _source("Sources", "UDeckCore", "Localization", "English.swift")
    line = "\\(Self.line(ref, fork: fork))"
    assert '"' + checks.CHANGED_STILL.format(line=line, version="\\(version)") + '"' in english
    assert '"' + checks.REWRITTEN.format(line=line) + '"' in english
    assert '"' + checks.BRANCH_GONE.format(name="\\(name)\\(Self.of(fork))") + '"' in english
    assert '"' + checks.NOT_CHECKED_SINCE.format(line="\\(Self.line(ref, capitalised: true, fork: fork))") + '\\(at)"' in english
    assert 'count == 1 ? "' + checks.ONE_UPDATE_WAITING + '"' in english
    assert f'case .catalogueUpdate: "{checks.UPDATE}"' in english
    model = _source("Sources", "UDeckKit", "Plugins", "DeckModel+Repository.swift")
    assert "left as they were: \\(outcome.leftAsTheyWere.joined(separator: \", \")" in model
    assert checks.LEFT_AS_THEY_WERE.format(ids="uptime") == "left as they were: uptime"
    # A read of the catalogue left for later is logged as its outcome, by the case's own name.
    assert 'info("the official catalogue: \\(String(describing: outcome), privacy: .public)")' in model
    refresher = _source("Sources", "UDeckCore", "Plugins", "Repository", "CatalogueRefresher.swift")
    assert "        case leftForLater\n" in refresher
    assert checks.LEFT_FOR_LATER == "the official catalogue: " + "leftForLater"
    # Swift's own tests hold the same sentences, word for word.
    swift = _source("Tests", "UDeckCoreTests", "RefFollowerTests.swift")
    for sentence in (checks.CHANGED_STILL.format(line="pull request #3", version="1.0.1"),
                     checks.CHANGED_STILL.format(line="branch fix/uptime", version="1.0.1"),
                     checks.REWRITTEN.format(line="pull request #3"), checks.BRANCH_GONE.format(name="fix/uptime"),
                     checks.NOT_CHECKED_SINCE.format(line="Pull request #3") + "14:02"):  # fmt: skip
        assert f'"{sentence}"' in swift, sentence


def test_the_controls_the_follow_checks_press_and_read_are_the_views_own():
    views = _source("Sources", "UDeckKit", "Views", "PluginRepositoryViews.swift")
    for identifier in ('"plugin.\\(id).\\(said.suffix)"', '"plugin.\\(id).whatChanged"', '"plugin.\\(id).update"',
                       '"plugin.\\(id).switchToVerified"', '"catalogue.\\(id).switchToVerified"'):
        assert identifier in views, identifier
    core = _source("Sources", "UDeckCore", "Plugins", "Repository", "UnverifiedCopies.swift")
    for suffix in ("pullRequest", "branchGone", "rewritten", "offer", "notChecked"):
        assert f'Said(suffix: "{suffix}"' in core, suffix
    # One press, one name: both rows take the verified copy's button from UDeckCore (`UnverifiedRow.verifiedButton`).
    assert views.count("model.unverifiedRow(of: id)?.verifiedButton ?? .catalogueSwitchToVerified(version: version)") == 2
    assert "unverified.verifiedIsAnUpdate, let label = unverified.verifiedButton" in views
    assert "!unverified.verifiedIsAnUpdate, let label = unverified.verifiedButton" in views
    assert checks.SAME_WORD_PX < (159 - 69) // 2, "the widths measured of Update and Switch to verified 1.0.x are far apart"
    store = _source("Sources", "UDeckCore", "Plugins", "Repository", "FollowedRefs.swift")
    for key in ("branches", "notCheckedSince", "history"):
        assert f"public var {key}:" in store, key


def test_the_card_is_clicked_where_it_came_to_rest_not_where_it_was_passing(monkeypatch):
    """Measured on runners (runs 38317811235, 38318963221): the card read while the panel
    was still growing put Decline 26 to 36 points right of where it came to rest, and the
    click meant for it landed past its edge, 4 readings of 7. The card is read again half a
    second apart until Allow stands where it stood, and that reading is the one returned."""

    def card(x):
        return (
            f"4|AXButton||consent.asks-nothing.allow||||{x};215;|103;23;|hidden\n"
            f"4|AXButton||consent.asks-nothing.decline||||{x + 110};215;|66;23;|hidden"
        )

    readings = [card(577), card(560), card(541), card(541)]
    machine = type("Guest", (), {"now": 0.0})()
    machine.clock = lambda: machine.now
    machine.sleep = lambda seconds: setattr(machine, "now", machine.now + seconds)
    monkeypatch.setattr(ui, "identified", lambda m, step, window, depth: readings.pop(0))
    monkeypatch.setattr(checks, "_panel_texts", lambda m, step: ["Asks nothing"])
    dump, texts = checks._once_it_stands_still(machine, readings.pop(0), [], "consent.asks-nothing.allow", 10)
    assert ui.element(dump, "consent.asks-nothing.decline").x == 651 and texts == ["Asks nothing"]
    assert machine.now == 3 * ui.SETTLED_SECONDS, "three readings after the first: 560, then 541 twice"

    readings = [card(577), card(560), card(545), card(530)]
    machine.now = 0.0
    with pytest.raises(LabError, match="still moving") as raised:
        checks._once_it_stands_still(machine, readings.pop(0), [], "consent.asks-nothing.allow", 1.0)
    assert not isinstance(raised.value, CheckFailed), "a card the lab cannot aim at is not uDeck's failure"
    assert "545" in raised.value.reason


def test_the_fork_and_the_repository_of_its_own_the_fork_check_pastes_are_the_fixtures():
    """x of the fork is pr3 — what the official repository has no branch of — and the control a repository of its own."""
    assert checks.FORKS[checks.FORK]["branches"] == {checks.FORK_BRANCH: "pr3"} and checks.FORKS[checks.FORK].get("fork", True)
    assert checks.FORKS[checks.NOT_A_FORK]["fork"] is False and checks.FORKS[checks.NOT_A_FORK]["branches"] == {checks.FORK_BRANCH: "pr3"}
    assert checks.FORK_BRANCH not in checks.BRANCHES, "the official repository has no branch x: nothing of x could come from it"
    assert len({checks.FORK, checks.NOT_A_FORK, config.PLUGINS_REPOSITORY}) == 3
    assert checks.FORK_LINK == f"https://github.com/{checks.FORK}/tree/{checks.FORK_BRANCH}/plugins/{checks.UPTIME}"
    assert checks.NOT_A_FORK_LINK.endswith(f"/{checks.NOT_A_FORK}/tree/{checks.FORK_BRANCH}/plugins/{checks.UPTIME}")
    assert FACTS["parents"]["p2"] == "pr3", "the fork's branch moves on to a commit that continues pr3"


def test_the_words_the_fork_check_waits_for_are_uDecks_own():
    english = _source("Sources", "UDeckCore", "Localization", "English.swift")
    assert 'said = "branch \\(ref.name ?? "")" + of(fork)' in english
    assert 'case .linkHead(let ref, let commit, let fork): "\\(Self.line(ref, capitalised: true, fork: fork)) at \\(commit)"' in english
    # The phrase is handed `github.com/owner/repo` for both; the check reads it as the screen says it.
    sentence = checks.NOT_A_FORK_SAYS.format(repository="\\(repository)", official="\\(official)").replace("github.com/", "")
    assert f'"{sentence}"' in english, sentence
    # Swift's own tests hold the same sentences, word for word.
    swift = re.sub(r'"\s*\+\s*"', "", _source("Tests", "UDeckCoreTests", "ForkTests.swift"))
    fork = checks.FORK
    for said in (checks.FROM_THE_FORK.format(name="x", fork=fork, commit="a1b2c3d"),
                 checks.FORK_HEAD.format(name="x", fork=fork, commit="a1b2c3d"),
                 checks.CHANGED_STILL.format(line=checks.OF_THE_FORK.format(name="x", fork=fork), version="1.0.1"),
                 checks.NOT_A_FORK_SAYS.format(repository="someone/elsewhere", official=config.PLUGINS_REPOSITORY)):
        assert f'"{said}"' in swift, said


def test_the_fake_serves_the_forks_the_fork_check_names():
    """Every key of FORKS is a repository the fake answers for, and the official one is none of them."""
    fake = _fake()
    state = fake.read_state(str(plugin_repository.FIXTURES), "c1")
    assert state["forks"] == {}, "no fork unless the check names one"
    assert config.PLUGINS_REPOSITORY not in checks.FORKS


# --- Sources of one's own (stage 4, R1b) -------------------------------------------------------


def test_a_sources_id_is_the_one_uDeck_derives():
    """`_source_id`, held against SourcesTests.swift's ids — made with `shasum -a 256`, not with uDeck's code."""
    assert checks._source_id("someone/team-plugins", 123456789) == "github.com-team-plugins-87a735c2"
    assert checks._source_id("someone/Team_Plugins", 123456789, host="GitHub.com") == "github.com-team-plugins-87a735c2"
    assert checks._source_id("tools/udeck-plugins", 48, host="gitlab.unicorns.place", provider="gitlab") == \
        "gitlab.unicorns.place-udeck-plugins-cbe44e4d"
    assert checks._source_id("a/b", 7, host="gitlab.example:8443", provider="gitlab") == "gitlab.example-8443-b-cd486683"
    swift = _source("Tests", "UDeckCoreTests", "SourcesTests.swift")
    for said in ("github.com-team-plugins-87a735c2", "gitlab.unicorns.place-udeck-plugins-cbe44e4d", "gitlab.example-8443-b-cd486683"):
        assert f'"{said}"' in swift


def test_the_source_checks_name_the_fixtures_there_are():
    """team-plugins has t1, t2, t3 and the plugins the checks install; not-plugins and squatter are there; the fake's
    numbers are the ones the builds and the checks use."""
    facts = _fake().Fake(str(plugin_repository.FIXTURES), config.PLUGINS_REPOSITORY, "/dev/null")
    assert sorted(facts.sources) == sorted([checks.TEAM, checks.NOT_PLUGINS, checks.SQUATTER])
    assert checks.MISSING not in facts.sources and checks.TEAM_RENAMED not in facts.sources
    team = facts.sources[checks.TEAM].repository
    assert team.names == ["t1", "t2", "t3"]
    for plugin in (checks.TEAM_CLOCK, checks.TEAM_PING, checks.UPTIME):
        assert team.commits["t1"].snapshot.at(f"plugins/{plugin}") is not None
    assert facts.official_id == config.PLUGINS_REPOSITORY_ID != checks.ANOTHER_REPOSITORY
    assert checks.BEFORE_SOURCES == "0.7.0"
    assert checks.TEAM_BRANCH_LINK.startswith(checks.TEAM_PAGE + "/tree/main/")


def test_the_words_the_source_checks_wait_for_are_uDecks_own():
    """Every sentence the stage-4 checks compare a screen with is English.swift's, word for word."""
    english = _source("Sources", "UDeckCore", "Localization", "English.swift")
    flat = re.sub(r'"\s*\+\s*"', "", english)

    def swift(text, **values):
        return text.format(**{name: f"\\({value})" for name, value in values.items()})

    assert f'"{checks.NOT_TRUSTED}"' in flat
    assert '"Nobody verified this code: it comes from the default branch of \\(address), a source you have not trusted"' in flat
    assert '". uDeck asks again whenever it changes."' in flat
    assert checks.UNTRUSTED_SOURCE.format(repository="o/r") == (
        "Nobody verified this code: it comes from the default branch of github.com/o/r, a source you have not trusted. "
        "uDeck asks again whenever it changes.")
    assert 'case .catalogueInstalledFromElsewhere(let copy): "Installed here: \\(Self.copy(copy))"' in english
    assert 'case .verified(let version, let repository): "the verified \\(version) from \\(repository)"' in english
    assert checks.FROM_ELSEWHERE.format(version="1.0.0", official="o/r") == "Installed here: the verified 1.0.0 from github.com/o/r"
    assert '": unverified"' in english and '"\\(id) is \\(Self.copy(from)); installing \\(Self.copy(to)) replaces it. "' in english
    assert 'case .catalogueInstalledFromSource(let address): "Installed here from \\(address): unverified"' in english
    assert 'case .pluginFrom(let source, let commit): "From \\(source) at \\(commit)"' in english
    assert 'case .sourceNoLongerAdded(let address): "From \\(address) — a source no longer added"' in english
    assert swift(checks.REMOVE_THE_SOURCE, name="name", repository="address").replace("github.com/", "") in english
    assert '"\\(name) (\\(address)) is added already."' in english
    assert '"\\(source) is not a uDeck plugin repository: there is no udeck-plugins.json at the top of \\(branch)."' in english
    assert '"\\(address) could not be found, or it is private. If it is private, uDeck needs a token for it: Token…"' in english
    assert f'"{checks.HTTPS_ONLY}"' in english and f'"{checks.OVER_SSH}"' in english
    assert '"That is \\(official), the official catalogue: its plugins are listed above, verified."' in english
    assert f'"{checks.BRANCH_NOT_YET}"' in flat and f'"{checks.OFFICIAL_CHANGED}"' in flat
    assert 'case .sourcesTestBuild(let host, let base): "Test build: \\(host) is read from \\(base)."' in english
    assert checks.TEST_BUILD.format(host="api.github.com", port=8766, path="api") == \
        "Test build: api.github.com is read from http://127.0.0.1:8766/api."
    # The isolates a passport's name is shown inside, which the checks take out.
    assert checks._strip("\u2068Team plugins\u2069") == "Team plugins" and checks.ISOLATES == ("\u2068", "\u2069")
    assert '"\\u{2068}"' in _source("Sources", "UDeckCore", "Plugins", "Repository", "Sources.swift")


def test_the_controls_the_source_checks_press_and_read_are_the_views_own():
    """S4-06's identifiers, in SourceViews.swift and PluginRepositoryViews.swift as the checks press and read them."""
    sources = _source("Sources", "UDeckKit", "Views", "SourceViews.swift")
    for identifier in ('"sources.add"', '"sources.add.field"', '"sources.add.lookUp"', '"sources.add.close"',
                       '"sources.add.result"', '"sources.add.confirm"', '"sources.testBuild"', '"sources.problem"',
                       '"source.\\(sid).name"', '"source.\\(sid).address"', '"source.\\(sid).mark"',
                       '"source.\\(sid).state"', '"source.\\(sid).checkNow"', '"source.\\(sid).remove"',
                       '"source.\\(sid).confirm"', '"source.\\(sid).confirmText"'):
        assert identifier in sources, identifier
    views = _source("Sources", "UDeckKit", "Views", "PluginRepositoryViews.swift")
    for identifier in ('"\\(named).mark"', '"\\(named).install"', '"\\(named).installFromHere"', '"\\(named).confirmText"',
                       '"\\(named).confirm"', '"\\(named).problem"', '"plugin.\\(id).backTo"', '"plugin.\\(id).earlier"',
                       '"plugin.\\(id).history.\\(line.version).install"', '"link.addAsASource"'):
        assert identifier in views, identifier


def test_the_fakes_number_is_one_number_in_make_app_the_fixture_and_the_lab():
    """Scripts/make-app.sh writes the number the fake answers, and the shipped plist and uDeck's own default are GitHub's."""
    import plistlib

    script = _source("Scripts", "make-app.sh")
    assert f"TEST_PLUGINS_REPOSITORY_ID={config.PLUGINS_REPOSITORY_ID}\n" in script
    assert 'Set :UDeckPluginsRepositoryID $TEST_PLUGINS_REPOSITORY_ID' in script
    fixture = [line for line in (plugin_repository.FIXTURES / "id").read_text().splitlines() if line and not line.startswith("#")]
    assert fixture == [str(config.PLUGINS_REPOSITORY_ID)]
    shipped = plistlib.loads(_source("Sources", "uDeck", "Support", "Info.plist").encode())
    assert shipped["UDeckPluginsRepositoryID"] == config.SHIPPED_REPOSITORY_ID != config.PLUGINS_REPOSITORY_ID
    swift = _source("Sources", "UDeckCore", "Plugins", "Repository", "GitHubClient.swift")
    assert "officialRepositoryID = 1_393_324_153" in swift and f"{config.SHIPPED_REPOSITORY_ID:_}" == "1_393_324_153"


def test_a_state_is_aged_by_the_keys_named_and_nothing_else(tmp_path, monkeypatch, capsys):
    """The script `_age_a_state` runs in the guest, run here in this process on a copy: the keys named moved back, every
    other kept."""
    state = tmp_path / "state.json"
    state.write_text(json.dumps({"head": "a" * 40, "lastSuccess": "2026-10-18T10:00:00Z", "defaultBranchReadAt": "2026-10-18T10:00:00Z"}))
    monkeypatch.setattr(sys, "argv", ["age", str(state), "2", "defaultBranchReadAt"])
    exec(compile(checks.AGE_A_STATE, "age", "exec"), {"__name__": "__main__"})
    then = capsys.readouterr().out.strip()
    aged = json.loads((tmp_path / "state.json.new").read_text())
    assert aged["head"] == "a" * 40 and aged["lastSuccess"] == "2026-10-18T10:00:00Z"
    assert aged["defaultBranchReadAt"] == then != "2026-10-18T10:00:00Z"
