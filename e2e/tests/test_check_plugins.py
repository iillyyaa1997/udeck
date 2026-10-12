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
from udeck_e2e.errors import CheckFailed


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
    # The tick the update that waited comes on.
    assert f"Timer(timeInterval: {checks.TICK_SECONDS}, repeats: true)" in model


def test_every_older_check_that_moves_main_starts_with_updates_by_themselves_off():
    """A check that moves main and then presses Update has to see an offer: with the switch as shipped, uDeck installs c2 by itself first."""
    tree = ast.parse((Path(__file__).resolve().parents[1] / "checks" / "check_plugins.py").read_text())
    new = {"check_verified_updates_itself", "check_permissions_change_only_offers"}
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
    assert 'case .pluginFromBranch(let name, let commit): "' + checks.FROM_THE_BRANCH.format(
        name="\\(name)", commit="\\(commit)") + '"' in english
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
    assert '"' + checks.INSTALLED_HERE_UNVERIFIED.format(line="\\(Self.line(ref))") + '"' in english
    assert 'case .catalogueMissing(let id, let path): "\\(id) is not in \\(path)"' in english
    assert checks.NOT_IN_THE_PLUGINS_FOLDER == "{id} is not in " + checks.UDECK_HOME + "/plugins"
    gone = checks.INSTALLED_HERE_UNVERIFIED.format(line="pull request #3") + " — " + checks.NOT_IN_THE_PLUGINS_FOLDER.format(id="uptime")
    assert f'== "{gone}"' in flat
    assert '"' + checks.LINK_OFF + '"' in english


def test_the_controls_the_link_checks_press_and_read_are_the_views_own():
    views = _source("Sources", "UDeckKit", "Views", "PluginRepositoryViews.swift")
    for identifier in ('"plugins.installFromLink"', '"link.field"', '"link.lookUp"', '"link.close"', '"link.head"',
                       '"link.refused"', '"link.catalogue"', '"link.\\(id).install"', '"link.\\(id).confirm"',
                       '"link.\\(id).confirmText"', '"link.\\(id).problem"', '"plugin.\\(id).switchToVerified"',
                       '"plugin.\\(id).refPage"', '"plugin.\\(id).from"', '"plugin.\\(id).confirmText"',
                       '"catalogue.\\(id).switchToVerified"', '"catalogue.\\(id).state"', '"catalogue.\\(id).reinstall"',
                       '"link.off"'):
        assert identifier in views, identifier
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
    assert 'case .branch(let branch, let commit, let version): "\\(version) from branch \\(branch) at \\(commit)"' in english
    assert checks.REINSTALL_BRINGS == "Reinstall puts back {version} from branch {name} at {commit}: code nobody verified."
    assert 'case .catalogueAvailable(let version): "' + checks.AVAILABLE.format(version="\\(version)") + '"' in english
    assert 'count == 1 ? "1 update is waiting"' in english
    # Swift's own tests hold the same sentences, word for word.
    swift = _source("Tests", "UDeckCoreTests", "AdoptionTests.swift")
    assert f'"{checks.MERGED_DIFFERS.format(number=3)}"' in swift and f'"{checks.CLOSED_UNMERGED.format(number=3)}"' in swift
    assert f'"{checks.REINSTALL_BRINGS.format(version="1.0.1", name="fix/uptime", commit="a1b2c3d")}"' in swift


def test_the_controls_the_merge_and_close_checks_press_and_read_are_the_views_own():
    views = _source("Sources", "UDeckKit", "Views", "PluginRepositoryViews.swift")
    for identifier in ('"plugin.\\(id).pullRequest"', '"plugin.\\(id).update"', '"catalogue.updatesWaiting"',
                       '"plugin.\\(id).mark"', '"plugin.\\(id).offer"', '"plugin.\\(id).remove"', '"catalogue.checkNow"'):
        assert identifier in views, identifier
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
