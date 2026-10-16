"""The accessibility helper, from the lab's side: built once per source, asked, and read exactly."""

import json
import subprocess

import pytest

from fakes import AX, Dropped, Failed, Machine, ax_walk
from udeck_e2e import ax, ui
from udeck_e2e.errors import LabError

# A walk as the helper prints it, measured on a runner (run 38210592133): the
# settings window, its sidebar's About, and a checkbox whose place is a fraction.
WALK = {
    "elements": [
        {"depth": 0, "role": "AXWindow", "subrole": "AXStandardWindow", "identifier": "", "title": "uDeck Settings",
         "value": "", "description": "", "frame": [60, 40, 1500, 961], "enabled": None, "shown": True},
        {"depth": 8, "role": "AXStaticText", "subrole": "", "identifier": "section.about", "title": "",
         "value": "About", "description": "", "frame": [91, 226, 60, 16], "enabled": True, "shown": True},
        {"depth": 5, "role": "AXCheckBox", "subrole": "", "identifier": "general.openAtLogin", "title": "",
         "value": "0", "description": "", "frame": [240, 127.04, 106, 16.08], "enabled": True, "shown": True},
        {"depth": 5, "role": "AXStaticText", "subrole": "", "identifier": "", "title": "",
         "value": "Would open: /Applications/uDeck.app", "description": "", "frame": [240, 149.21, 181, 13],
         "enabled": True, "shown": False},
    ],
    "seconds": 0.05,
}  # fmt: skip


def test_a_walk_is_read_element_by_element():
    found, seconds = ax.parse_walk(json.dumps(WALK))
    assert seconds == 0.05
    assert [w.identifier for w in found] == ["", "section.about", "general.openAtLogin", ""]
    assert found[2].frame == (240.0, 127.04, 106.0, 16.08)
    assert found[3].shown is False and found[0].enabled is None and found[1].enabled is True


@pytest.mark.parametrize(
    "broken, why",
    [
        ({"seconds": 1}, "list of elements"),
        ({"elements": ["x"]}, "not an object"),
        ({"elements": [{"depth": "0"}]}, "no depth"),
        ({"elements": [{"depth": True}]}, "no depth"),
        ({"elements": [{"depth": 0, "role": "AXWindow"}]}, "no text for"),
        ({"elements": [{**WALK["elements"][0], "frame": [1, 2, 3]}]}, "four numbers"),
        ({"elements": [{**WALK["elements"][0], "frame": [1, 2, 3, "4"]}]}, "four numbers"),
        ({"elements": [WALK["elements"][1]]}, "starts at its window"),
    ],
)
def test_a_walk_that_is_not_one_is_refused_with_what_is_wrong(broken, why):
    with pytest.raises(ValueError, match=why):
        ax.parse_walk(json.dumps(broken))


def test_a_walk_is_written_as_the_applescript_walk_wrote_it_and_says_what_a_click_can_reach():
    """Nine fields as System Events printed them — places in whole points, cut
    toward zero, as it did (88.79 read 88 on a runner) — and `shown` after them."""
    found, _ = ax.parse_walk(json.dumps(WALK))
    lines = ax.dump(found).splitlines()
    assert lines[0] == "0|AXWindow|AXStandardWindow||uDeck Settings|||60;40;|1500;961;|shown"
    assert lines[2] == "5|AXCheckBox||general.openAtLogin||0||240;127;|106;16;|shown"
    assert lines[3].endswith("|240;149;|181;13;|hidden")
    # Read back by `ui`, the walk's lines are the elements they were.
    parsed = ui.controls(ax.dump(found))
    assert (parsed[2].identifier, parsed[2].x, parsed[2].y, parsed[2].width, parsed[2].height) == (
        "general.openAtLogin", 240, 127, 106, 16
    )
    assert [p.shown for p in parsed] == [True, True, True, False]


def test_the_identified_controls_are_those_with_an_identifier_and_never_the_window():
    found, _ = ax.parse_walk(json.dumps({"elements": [{**WALK["elements"][0], "identifier": "the-window"}, *WALK["elements"][1:]]}))
    identified = ax.dump(found, identified_only=True).splitlines()
    assert [line.split("|")[3] for line in identified] == ["section.about", "general.openAtLogin"]


def test_an_element_with_no_place_has_empty_places_as_the_old_walk_printed_them():
    found, _ = ax.parse_walk(json.dumps({"elements": [{**WALK["elements"][0], "frame": None}]}))
    assert ax.dump(found) == "0|AXWindow|AXStandardWindow||uDeck Settings|||||shown"
    (window,) = ui.controls(ax.dump(found))
    assert (window.x, window.y, window.width, window.height) == (0, 0, 0, 0)


def test_every_line_break_is_written_as_the_walk_wrote_it_so_a_control_stays_one_line():
    found, _ = ax.parse_walk(json.dumps({"elements": [{**WALK["elements"][0], "value": "a\r\nb\nc\rd", "title": "x\ny"}]}))
    (line,) = ax.dump(found).splitlines()
    assert "|x⏎y|a⏎b⏎c⏎d|" in line


def test_the_texts_identifiers_and_the_first_control_are_read_as_system_events_read_them():
    """`ui._TEXTS`: a static text's value, or its title where the value is empty;
    `ui._LIST`: `role [identifier]`, the window included; `ui._FIND`: the first in the walk's order."""
    elements = [
        *WALK["elements"],
        {**WALK["elements"][3], "value": "", "title": "Titled"},
        {**WALK["elements"][3], "value": "   ", "title": ""},
        {**WALK["elements"][1], "frame": [1, 2, 3, 4]},
    ]
    found, _ = ax.parse_walk(json.dumps({"elements": elements}))
    assert ax.static_texts(found) == ["About", "Would open: /Applications/uDeck.app", "Titled", "About"]
    assert ax.identifiers(found) == [
        "AXStaticText [section.about]", "AXCheckBox [general.openAtLogin]", "AXStaticText [section.about]",
    ]  # fmt: skip
    assert ax.first_with(found, "section.about").frame == (91.0, 226.0, 60.0, 16.0)
    assert ax.first_with(found, "nowhere") is None


def test_two_readings_of_one_screen_are_held_against_each_other_row_by_row():
    same = [("a", "1"), ("b", "2")]
    assert ax.differences(same, list(same), "the screen") == []
    problems = ax.differences([("a", "1"), ("b", "2"), ("c", "3")], [("a", "1"), ("b", "X")], "the screen")
    assert problems == [
        "the screen: System Events read 3 and the helper 2",
        "the screen #1: System Events ('b', '2'), the helper ('b', 'X')",
        "the screen #2: only System Events read ('c', '3')",
    ]
    assert ax.differences([], [("a",)], "texts") == ["texts: System Events read 0 and the helper 1", "texts #0: only the helper read ('a',)"]


# --- Asking --------------------------------------------------------------------------------


def test_the_helper_is_asked_by_its_path_with_every_word_quoted():
    machine = Machine({"ax walk": ax_walk("5|AXButton||x||||1;2;|3;4;")})
    ui.walk(machine, "walking", window="Настройки uDeck")
    assert machine.ssh.commands == [f"{AX} walk uDeck 'title=Настройки uDeck' 12"]


def test_what_the_helper_refuses_is_the_labs_failure_with_its_own_words():
    refused = Machine({"ax windows": Failed(code=1, said="ax: no process called uDeck is running")})
    with pytest.raises(LabError, match="the accessibility helper refused: ax: no process called uDeck is running"):
        ax.ask(refused, ["windows", "uDeck"], "listing")
    garbled = Machine({"ax windows": "not json"})
    with pytest.raises(LabError, match="not JSON"):
        ax.ask(garbled, ["windows", "uDeck"], "listing")
    listed = Machine({"ax windows": "[1, 2]"})
    with pytest.raises(LabError, match="not an object"):
        ax.ask(listed, ["windows", "uDeck"], "listing")
    # A connection that dropped never reached the helper, and says so.
    dropped = Machine({"ax windows": Dropped})
    with pytest.raises(LabError, match="SSH"):
        ax.ask(dropped, ["windows", "uDeck"], "listing")


def test_a_machine_without_the_helper_is_said_before_anything_is_asked():
    machine = Machine({})
    machine.ax_path = None
    with pytest.raises(LabError, match="has no accessibility helper"):
        ax.ask(machine, ["trusted"], "asking")
    assert machine.ssh.commands == []


def test_the_panel_is_asked_for_by_its_subrole_and_every_other_window_by_its_title():
    assert ax.window_spec(ui.PANEL, ui.PANEL) == "panel"
    assert ax.window_spec("uDeck Settings", ui.PANEL) == "title=uDeck Settings"


# --- Building ------------------------------------------------------------------------------


def test_the_helper_is_compiled_once_per_source_and_kept_by_its_digest(tmp_path):
    source = tmp_path / "ax.swift"
    source.write_text("print(1)\n")
    calls = []

    def swiftc(args, **kwargs):
        calls.append(args)
        out = args[args.index("-o") + 1]
        with open(out, "w") as binary:
            binary.write("binary")
        return subprocess.CompletedProcess(args, 0, "", "")

    built = ax.build(tmp_path / "cache", lambda text: None, source=source, run=swiftc)
    assert built == ax.cached_path(tmp_path / "cache", source) and built.read_text() == "binary"
    assert calls[0][:5] == ["/usr/bin/xcrun", "swiftc", "-O", "-target", ax.TARGET]
    assert not (built.parent / "ax.partial").exists()
    # The same source again: nothing compiled.
    assert ax.build(tmp_path / "cache", lambda text: None, source=source, run=swiftc) == built and len(calls) == 1
    # A changed source, or another target, is another binary.
    source.write_text("print(2)\n")
    assert ax.cached_path(tmp_path / "cache", source) != built
    assert ax.digest(source, "arm64-apple-macos27.0") != ax.digest(source)


def test_a_compile_that_fails_leaves_nothing_the_next_run_would_take_for_done(tmp_path):
    source = tmp_path / "ax.swift"
    source.write_text("broken\n")

    def swiftc(args, **kwargs):
        with open(args[args.index("-o") + 1], "w") as binary:
            binary.write("half")
        return subprocess.CompletedProcess(args, 1, "", "ax.swift:1:1: error: cannot find 'broken' in scope\n1 error")

    with pytest.raises(LabError, match="cannot find 'broken' in scope"):
        ax.build(tmp_path / "cache", lambda text: None, source=source, run=swiftc)
    binary = ax.cached_path(tmp_path / "cache", source)
    assert not binary.exists() and not (binary.parent / "ax.partial").exists()


def test_the_helper_source_is_the_one_in_the_guest_folder():
    assert ax.SOURCE.name == "ax.swift" and ax.SOURCE.parent.name == "guest" and ax.SOURCE.is_file()
    assert ax.TARGET.startswith("arm64-apple-macos")


def test_the_helper_never_goes_inside_the_buttons_the_comparison_leaves_out():
    """Asking the full-screen button for its children makes uDeck start three
    `ThemeWidgetControlViewService` and keep them until it exits (run
    20261012-181746Z), so the helper's walk lists the window's own buttons and
    stops there. The buttons it stops at are the ones `without_the_title_bar`
    takes out of both readings when the two walks are compared — one list in two
    languages, held together here — and the walk returns before it asks a
    button's `AXChildren`, which is the request that starts them."""
    source = ax.SOURCE.read_text()
    declared = source.split("let windowButtons: Set<String> = [", 1)[1].split("]", 1)[0]
    assert {name.strip().strip('"') for name in declared.split(",")} == set(ax.WINDOW_BUTTONS)
    walk = source.split("func walk(", 1)[1].split("\n}\n", 1)[0]
    stop, children = walk.index("windowButtons.contains"), walk.index("children(element)")
    assert stop < children, "the walk asks a title-bar button for its children before it stops"
    # And the condition ends the visit: its body is a bare `return`, so a walk that
    # only looked at the subrole and went on would not pass.
    body = walk[stop:].split("{", 1)[1].split("}", 1)[0]
    assert body.strip() == "return", f"the title-bar button's visit goes on: {body.strip()!r}"
