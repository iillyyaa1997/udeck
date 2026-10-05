"""The plugin checks' own reasoning: which files a catalogue needs, what a whole record is, where a window is.

The checks themselves run against a guest; what can be held here is every
sentence they reach without one. Each test removes one thing the check relies on
and asks whether the check would still be green — a record with a field
missing, a window moved, a catalogue that fetched one file more.
"""

import importlib.util
import json
import re
import sys
from pathlib import Path

import pytest

from udeck_e2e import config, plugin_repository, ui
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
    for commit in ("c1", "c2"):
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
    script = ui._applescript(ui._FIND, process="uDeck", window=ui.PANEL, identifier="consent.uptime.allow")
    assert 'first window whose subrole is "AXSystemDialog"' in script and "whose name is" not in script
    script = ui._applescript(ui._FIND, process="uDeck", window=ui.SETTINGS_WINDOW, identifier="x")
    assert 'first window whose name is "uDeck Settings"' in script


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
