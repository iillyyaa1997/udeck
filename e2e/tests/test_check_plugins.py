"""The plugin checks' own reasoning: which files a catalogue needs, what a whole record is, where a window is.

The checks themselves run against a guest; what can be held here is every
sentence they reach without one. Each test removes one thing the check relies on
and asks whether the check would still be green — a record with a field
missing, a window moved, a catalogue that fetched one file more.
"""

import importlib.util
import json
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
