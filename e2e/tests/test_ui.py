"""Driving the interface: what is asked of the guest, and what is done with the answer."""

import json
import shlex
import subprocess

import pytest

from fakes import as_the_lab_keeps_it, ax_walk
from udeck_e2e import ax, config, ui
from udeck_e2e.errors import LabError, NotThere

AX = "/Users/admin/.udeck-e2e/ax"


def done(args, rc=0, out="", err=""):
    return subprocess.CompletedProcess(args, rc, out, err)


class Clock:
    def __init__(self):
        self.now = 0.0

    def __call__(self):
        return self.now

    def sleep(self, seconds):
        self.now += seconds


def _next(answers):
    """One answer per question, the last one repeating."""
    return answers.pop(0) if len(answers) > 1 else answers[0]


class FakeGuest:
    """The accessibility helper and System Events, answering by what was asked.

    `walks` are screens written as the AppleScript walk printed them, one per
    walk; `windows` the titles of uDeck's windows, one answer per question;
    `presses` what pressing the menu item answers — "pressed" or a refusal as
    (exit code, words). The menu's titles and the guest's own language answer by
    what was asked rather than by their turn: both are read only when the lab
    has already failed, after any number of attempts.
    """

    def __init__(self, walks=None, windows=None, presses=None, menu=None, language="", typed="typed"):
        self.walks = list(walks or [""])
        self.windows = list(windows or [[ui.SETTINGS_WINDOW]])
        self.presses = list(presses or ["pressed"])
        self.menu = menu
        self.language = language
        self.typed = typed
        self.scripts = []
        self.host = "192.168.64.2"

    def run(self, command, step, seconds=None, check=True):
        self.scripts.append(command)
        if command.startswith(AX + " "):
            return self._helper(shlex.split(command)[1:])
        if "AppleLanguages" in command:
            return done([], 0, self.language)
        if command.startswith("osascript "):
            return done([], 0, self.typed)
        raise AssertionError(f"the lab asked the guest something no test expects: {command}")

    def _helper(self, args):
        name = args[0]
        if name == "walk":
            answer = _next(self.walks)
            if isinstance(answer, tuple):
                return done([], answer[0], "", answer[1])
            return done([], 0, ax_walk(answer, window=args[2].removeprefix("title=")))
        if name == "windows":
            titles = _next(self.windows)
            if isinstance(titles, tuple):
                return done([], titles[0], "", titles[1])
            return done([], 0, json.dumps({"windows": [{"title": t, "subrole": "", "frame": None} for t in titles]}))
        if name == "press-menu-item":
            answer = _next(self.presses)
            if isinstance(answer, tuple):
                return done([], answer[0], "", answer[1])
            return done([], 0, json.dumps({"pressed": args[2]}))
        if name == "menu":
            if self.menu is None:
                return done([], 1, "", "ax: uDeck has no menu bar")
            return done([], 0, json.dumps({"titles": self.menu}))
        if name == "place":
            x, y, width, height = (int(n) for n in args[3:7])
            return done([], 0, json.dumps({"frame": [x, y, width, min(height, 1400)]}))
        raise AssertionError(f"the helper was asked something no test expects: {args}")


class FakeMachine:
    def __init__(self, **guest):
        self.name = "udeck-e2e-probe"
        self.ax_path = AX
        self.ssh = FakeGuest(**guest)
        self.clicks = []
        self._clock = Clock()

    def click(self, x, y, step):
        self.clicks.append((x, y))

    def clock(self):
        return self._clock()

    def sleep(self, seconds):
        self._clock.sleep(seconds)

    def helper_calls(self, name):
        return [s for s in self.ssh.scripts if s.startswith(f"{AX} {name} ")]


# A settings window as the walk reads it, its About section in the sidebar.
ABOUT = "\n".join([
    "0|AXWindow|AXStandardWindow||uDeck Settings|||790;198;|980;648;",
    "8|AXStaticText||section.about||About||808;355;|59;17;",
    "5|AXButton||updates.checkNow||||955;455;|83;20;",
])  # fmt: skip
WITHOUT_INSTALL = "\n".join([
    "0|AXWindow|AXStandardWindow||uDeck Settings|||790;198;|980;648;",
    "5|AXButton||updates.checkNow||||955;455;|83;20;",
    "5|AXCheckBox||updates.automatic||1||955;485;|83;20;",
])  # fmt: skip


def test_a_control_is_found_by_its_identifier_and_clicked_in_its_middle():
    machine = FakeMachine(walks=[ABOUT])
    element = ui.click(machine, "section.about", "opening About")
    assert (element.identifier, element.x, element.y, element.width, element.height) == ("section.about", 808, 355, 59, 17)
    assert machine.clicks == [(837, 363)]
    # The helper is asked to walk uDeck's settings window, by its title, deep enough —
    # twice, half a second apart, so that the click goes where the control has come to rest.
    walked = machine.helper_calls("walk")
    assert walked == [f"{AX} walk uDeck 'title=uDeck Settings' {ui.MAX_DEPTH}"] * 2
    assert machine._clock.now == ui.SETTLED_SECONDS


def test_a_control_that_never_appears_says_what_is_there_instead():
    machine = FakeMachine(walks=[WITHOUT_INSTALL])
    with pytest.raises(LabError, match="updates.install' did not appear") as raised:
        ui.wait_for(machine, "updates.install", "installing", seconds=5)
    assert "AXButton [updates.checkNow]" in raised.value.reason and "AXCheckBox [updates.automatic]" in raised.value.reason
    assert machine._clock.now >= 5


def test_a_control_that_appears_a_moment_later_is_waited_for():
    machine = FakeMachine(walks=[WITHOUT_INSTALL.replace("updates.checkNow", "x"), WITHOUT_INSTALL])
    element = ui.wait_for(machine, "updates.checkNow", "checking", seconds=30)
    assert element.middle == (996, 465)
    assert 0 < machine._clock.now < 30


def test_an_answer_the_lab_cannot_read_is_a_lab_error():
    """A walk that is not one, from a helper that answered something else: the lab's failure, with the answer."""
    machine = FakeMachine()
    machine.ssh.run = lambda command, step, seconds=None, check=True: done([], 0, '{"elements": [{"depth": 0}]}')
    with pytest.raises(LabError, match="could not be read"):
        ui.find(machine, "updates.checkNow", "checking")
    machine.ssh.run = lambda command, step, seconds=None, check=True: done([], 0, "755,455")
    with pytest.raises(LabError, match="not JSON"):
        ui.find(machine, "updates.checkNow", "checking")


def test_the_helper_refusing_is_a_lab_error_not_a_verdict():
    machine = FakeMachine(walks=[(1, "ax: uDeck has no window called uDeck Settings; its windows: none")])
    with pytest.raises(LabError, match="the accessibility helper refused: ax: uDeck has no window called") as raised:
        ui.identifiers(machine, "listing")
    assert not isinstance(raised.value, NotThere)


def test_the_settings_window_is_opened_from_the_applications_own_menu():
    machine = FakeMachine()
    ui.open_settings(machine, "opening the settings")
    assert machine.ssh.scripts == [f"{AX} press-menu-item uDeck 'Settings…'"]


def test_a_field_is_typed_into_by_system_events_in_udeck():
    """Install from a link…'s field: typed into the way choose_folder types a path, the text quoted as AppleScript."""
    machine = FakeMachine()
    ui.type_text(machine, 'github.com/o/r/pull/3"x', "typing")
    script = machine.ssh.scripts[0]
    assert 'keystroke "github.com/o/r/pull/3\\"x"' in script and 'tell process "uDeck"' in script


def test_every_question_asks_only_about_udeck():
    machine = FakeMachine(walks=[ABOUT])
    ui.identifiers(machine, "listing")
    ui.find(machine, "updates.checkNow", "finding")
    ui.open_settings(machine, "opening")
    ui.windows(machine, "listing windows")
    for asked in machine.ssh.scripts:
        assert shlex.split(asked)[2] == "uDeck"


def test_only_the_control_never_appearing_is_NotThere():
    """A check may act on "uDeck did not offer it"; it may not act on a refusal.

    Both used to arrive as the same LabError, and the negative control read the
    second as the first: a click the lab could not make became "uDeck did not
    even offer it" and the check passed having pressed nothing.
    """
    machine = FakeMachine(walks=[WITHOUT_INSTALL])
    with pytest.raises(NotThere):
        ui.wait_for(machine, "updates.install", "installing", seconds=5)

    refused = FakeMachine(walks=[(1, "ax: no process called uDeck is running")])
    with pytest.raises(LabError) as raised:
        ui.wait_for(refused, "updates.install", "installing", seconds=5)
    assert not isinstance(raised.value, NotThere)
    # It comes out at once, without waiting the window out: nothing is being waited for.
    assert refused._clock.now == 0


def test_the_settings_window_is_asked_for_again_until_it_is_there():
    """The menu press is made moments after uDeck was launched.

    A status item that is not in the menu bar yet makes the press refused, and
    a press that lands before the application is ready does nothing at all —
    both the lab being early, and both used to end the check as "could not check".
    """
    machine = FakeMachine(
        presses=[(1, "ax: uDeck's menu bar has no item"), "pressed", "pressed"],  # no menu yet
        windows=[["Something Else"], ["uDeck Settings", "Something Else"]],  # pressed, no window; then there
    )
    ui.open_settings_and_wait(machine, "opening uDeck's settings", seconds=30)
    assert len(machine.helper_calls("press-menu-item")) == 3


def test_a_settings_window_that_never_opens_is_a_lab_problem():
    machine = FakeMachine(windows=[["Something Else"]])
    with pytest.raises(LabError, match="did not open within"):
        ui.open_settings_and_wait(machine, "opening uDeck's settings", seconds=5)
    assert machine._clock.now >= 5


def test_a_guest_with_no_such_menu_item_says_which_language_it_is_in():
    """The one way into these screens is a *translated* title.

    Everything else in `ui` is built on not trusting a translated name, and this
    is the exception that has no alternative: the menu item carries no
    identifier. So on a guest that is not in English both settings checks end
    here, and what a person reads has to be that rather than a shrug — the
    language the guest answers with, and the titles it does offer.
    """
    machine = FakeMachine(
        presses=[(1, "ax: uDeck's menu has no item called Settings…")],
        menu=["О приложении uDeck", "Настройки…", "Завершить uDeck"],
        language="(ru,en)",
    )
    with pytest.raises(LabError) as raised:
        ui.open_settings_and_wait(machine, "opening uDeck's settings", seconds=5)
    reason = raised.value.reason
    assert "'Settings…'" in reason and "translated" in reason
    assert "(ru,en)" in reason and "Настройки…" in reason


def test_a_guest_that_will_not_say_which_language_it_is_in_still_gives_a_reason():
    """Both of those are evidence, and evidence may not raise over a reason."""
    machine = FakeMachine(windows=[["Something Else"]], menu=[])
    with pytest.raises(LabError) as raised:
        ui.open_settings_and_wait(machine, "opening uDeck's settings", seconds=5)
    assert "the guest said nothing" in raised.value.reason
    assert "offers nothing" in raised.value.reason
    refused = FakeMachine(windows=[["Something Else"]])
    with pytest.raises(LabError) as raised:
        ui.open_settings_and_wait(refused, "opening uDeck's settings", seconds=5)
    assert "the menu could not be read: the accessibility helper refused: ax: uDeck has no menu bar" in raised.value.reason


# --- Out of the pointer's reach ---------------------------------------------------------


def _hidden(dump, identifier):
    """The same screen with one control out of reach, as the helper says of it."""
    walked = json.loads(ax_walk(dump))
    for element in walked["elements"]:
        if element["identifier"] == identifier:
            element["shown"] = False
    return json.dumps(walked)


def test_on_a_machine_that_cannot_scroll_a_control_is_clicked_where_the_walk_said_as_it_always_was():
    """A Tart guest: every pane the checks press in fits its window, and nothing
    about a click changed with the helper — it goes where the walk said."""
    machine = FakeMachine()
    machine.ssh._helper = lambda args: done([], 0, _hidden(ABOUT, "updates.checkNow")) if args[0] == "walk" else None
    ui.click(machine, "updates.checkNow", "checking")
    assert machine.clicks == [(996, 465)]
    # And a control read out of a kept walk keeps what the walk said of it.
    (element,) = [e for e in ui.controls(ax.dump(ax.parse_walk(_hidden(ABOUT, "updates.checkNow"))[0])) if not e.shown]
    assert element.identifier == "updates.checkNow" and element.middle == (996, 465)


def test_the_panel_is_never_scrolled_even_where_the_machine_can_scroll():
    """The panel's frame trails its animation (run 38213314297): what it reports
    of its own reach is not a reason to scroll it, and nothing in it scrolls."""
    machine = FakeMachine()
    machine.ssh._helper = lambda args: done([], 0, _hidden(ABOUT, "updates.checkNow")) if args[0] == "walk" else None
    machine.scroll = lambda *a: (_ for _ in ()).throw(AssertionError("scrolled the panel"))
    ui.click(machine, "updates.checkNow", "allowing", ui.PANEL)
    assert machine.clicks == [(996, 465)]


def test_a_pane_that_scrolling_does_not_bring_the_control_into_is_the_labs_failure():
    pane = "\n".join([
        "0|AXWindow|AXStandardWindow||uDeck Settings|||60;40;|1500;961;",
        "4|AXScrollArea||||||208;72;|1352;929;",
        "5|AXButton||catalogue.uptime.install||||228;1200;|80;24;",
    ])  # fmt: skip
    machine = FakeMachine()
    machine.ssh._helper = lambda args: done([], 0, _hidden(pane, "catalogue.uptime.install"))
    scrolled = []
    machine.scroll = lambda x, y, distance, step: scrolled.append(distance)
    with pytest.raises(LabError, match="stayed outside what 'uDeck Settings' shows after 6 scrolls") as raised:
        ui.click(machine, "catalogue.uptime.install", "installing")
    assert not isinstance(raised.value, NotThere) and machine.clicks == [] and len(scrolled) == ui.SCROLLS


def test_a_control_out_of_reach_is_scrolled_into_view_where_the_machine_can_scroll():
    """`--target here`: the runner's screen is smaller than the guest's, and the
    pane under the control is scrolled until the walk says it can be reached."""
    pane = "\n".join([
        "0|AXWindow|AXStandardWindow||uDeck Settings|||60;40;|1500;961;",
        "4|AXScrollArea||||||208;72;|1352;929;",
        "5|AXButton||catalogue.uptime.install||||228;1200;|80;24;",
    ])  # fmt: skip
    moved = pane.replace("228;1200;", "228;700;")
    answers = [_hidden(pane, "catalogue.uptime.install")] * 3 + [ax_walk(moved)]
    machine = FakeMachine()
    machine.ssh._helper = lambda args: done([], 0, answers.pop(0) if len(answers) > 1 else answers[0])
    scrolled = []
    machine.scroll = lambda x, y, distance, step: scrolled.append((x, y, distance))
    element = ui.click(machine, "catalogue.uptime.install", "installing")
    assert (element.x, element.y) == (228, 700)
    assert machine.clicks == [(268, 712)]
    # At the pane's middle, and upward — the content moved up to bring a control below into view.
    assert scrolled == [(884, 536, -675)]


SCROLLED_PANE = "\n".join([
    "0|AXWindow|AXStandardWindow||uDeck Settings|||60;40;|1500;961;",
    "4|AXScrollArea||||||208;72;|1352;929;",
    "5|AXButton||catalogue.uptime.install||||228;1200;|80;24;",
])  # fmt: skip
REBUILT_PANE = "\n".join([
    "0|AXWindow|AXStandardWindow||uDeck Settings|||60;40;|1500;961;",
    "4|AXScrollArea||||||208;72;|1352;929;",
])  # fmt: skip


def test_a_walk_that_misses_a_control_wait_for_just_saw_is_walked_again():
    """SwiftUI rebuilding the pane between `wait_for` and the scroll (R3 saw a
    walk come back with the panel half-made): the walk is taken again, and the
    control is reached when it is back — not a ❌ about uDeck."""
    answers = [_hidden(SCROLLED_PANE, "catalogue.uptime.install"), ax_walk(REBUILT_PANE), ax_walk(REBUILT_PANE),
               ax_walk(SCROLLED_PANE.replace("228;1200;", "228;700;"))]
    machine = FakeMachine()
    machine.ssh._helper = lambda args: done([], 0, answers.pop(0) if len(answers) > 1 else answers[0])
    scrolled = []
    machine.scroll = lambda x, y, distance, step: scrolled.append(distance)
    element = ui.in_view(machine, "catalogue.uptime.install", "installing")
    assert (element.x, element.y) == (228, 700) and len(scrolled) == 1


def test_a_control_that_goes_while_the_lab_scrolls_to_it_is_the_labs_failure_not_NotThere():
    """`NotThere` is `wait_for`'s deadline and nothing else: the checks read it
    as "uDeck does not offer it", and this control was offered a moment ago."""
    answers = [_hidden(SCROLLED_PANE, "catalogue.uptime.install"), ax_walk(REBUILT_PANE)]
    machine = FakeMachine()
    machine.ssh._helper = lambda args: done([], 0, answers.pop(0) if len(answers) > 1 else answers[0])
    machine.scroll = lambda *a: None
    with pytest.raises(LabError, match="went from it while the lab scrolled to it") as raised:
        ui.click(machine, "catalogue.uptime.install", "installing")
    assert not isinstance(raised.value, NotThere) and machine.clicks == []


# --- Controls that have no name -----------------------------------------------------
#
# The Opening screen carries no accessibility identifier on any control, so the
# lab finds them by where they sit and checks that finding against what they
# read. Every test here asks the same question: would this still pick the right
# control if the screen changed under it — and the answer has to be no, loudly.

# The screen as the walk read it in the guest (2026-09-25,
# .build/e2e/20260925-005230Z). Deliberately not in the order the controls are
# laid out in: the walk prints them in tree order, and what puts them in the
# operator's order is `x` and `y`.
OPENING = "\n".join([
    "0|AXWindow|AXStandardWindow||uDeck Settings|||790;198;|980;648;",
    "8|AXStaticText||section.opening||Opening||807;269;|77;18;",
    "5|AXCheckBox||||1||1124;470;|221;16;",
    "5|AXCheckBox|AXToggle|||0||1234;403;|28;20;",
    "5|AXCheckBox||||1||1124;246;|328;16;",
    "5|AXCheckBox|AXToggle|||1||1124;403;|28;20;",
    "5|AXSlider||||0.08||1124;272;|230;20;",
    "5|AXCheckBox|AXToggle|||0||1197;403;|29;20;",
    "5|AXCheckBox||||1||1124;448;|303;16;",
    "5|AXPopUpButton||||U||1270;403;|110;20;",
    "5|AXCheckBox|AXToggle|||1||1160;403;|29;20;",
    "5|AXCheckBox||||1||1124;377;|205;16;",
])  # fmt: skip

def opened_on_opening(tree=OPENING):
    """A guest with the settings window open and the walk answering: twice to find Opening in the sidebar at rest, then `tree`."""
    return FakeMachine(walks=[OPENING, OPENING, *(tree if isinstance(tree, list) else [tree])])


def test_the_walk_reads_every_attribute_a_click_at_an_unnamed_control_needs():
    controls = ui.controls(OPENING)
    window = controls[0]
    assert (window.role, window.title) == ("AXWindow", "uDeck Settings")
    assert (window.x, window.y, window.width, window.height) == (790, 198, 980, 648)
    # The identifiers that do exist are read too, so the sidebar can be told
    # from the pane it opens.
    assert [c.identifier for c in controls if c.identifier] == ["section.opening"]
    # Blank lines are not controls and are not pretending to be.
    assert ui.controls("\n" + OPENING + "\n") == controls


def test_a_control_the_walk_could_not_print_is_a_lab_error_with_the_line_in_it():
    """A control whose text holds a `|` prints as ten fields, not nine.

    Dropped quietly it is a control missing from the screen, and the caller then
    says the only thing a missing control can mean there — "the Opening screen
    did not appear", which sends the reader to SwiftUI for a pipe in a label. So
    the line comes out whole, as the lab's own failure.
    """
    piped = OPENING + "\n5|AXCheckBox||||1|on | off|1124;500;|100;16;"
    with pytest.raises(LabError, match="not a control") as raised:
        ui.controls(piped, "walking the Opening screen")
    assert "on | off" in raised.value.reason and "10 fields" in raised.value.reason
    # And the halves a line break leaves behind, neither of which is a control.
    with pytest.raises(LabError, match="not a control"):
        ui.controls(OPENING + "\n5|AXStaticText||||two\n lines||1124;520;|100;16;")
    # The rows are read through the same parse, so nothing is lost behind them.
    with pytest.raises(LabError, match="not a control"):
        ui.opening_switches(piped)
    with pytest.raises(LabError, match="not a control"):
        ui.modifier_buttons(piped)


def test_the_shortcuts_modifier_buttons_come_back_in_the_order_they_are_laid_out():
    """Left to right, which is `HotKeyModifier.allCases.sorted()` — ⌃⌥⇧⌘."""
    buttons = ui.modifier_buttons(OPENING)
    assert [b.x for b in buttons] == [1124, 1160, 1197, 1234]
    assert [b.value for b in buttons] == list(config.HOTKEY_MODIFIER_ROW_AT_REST)
    # The plain checkboxes and the key's popup are not modifier buttons.
    assert all(b.subrole == "AXToggle" for b in buttons)


def test_the_plain_switches_come_back_top_to_bottom_and_without_the_toggles():
    switches = ui.opening_switches(OPENING)
    assert [s.y for s in switches] == [246, 377, 448, 470]
    assert [s.value for s in switches] == list(config.OPENING_SWITCHES_AT_REST)
    assert all(not s.subrole for s in switches)
    # A control that *has* a name is not one of these: the General screen's login
    # switch is an AXCheckBox with an identifier, and it must never be picked up.
    named = OPENING + "\n5|AXCheckBox||general.openAtLogin||0||967;281;|104;16;"
    assert ui.opening_switches(named) == switches


def test_the_screen_names_each_control_by_the_setting_it_writes():
    screen = ui.opening(opened_on_opening(), "opening the settings")
    assert screen.modifier(config.THE_ADDED_MODIFIER).x == 1197
    assert screen.switch(config.THE_SWITCH).y == 448
    # The first of each row, so the order is the one the config states and not
    # whatever the walk happened to print.
    assert screen.modifier(config.HOTKEY_MODIFIER_ROW[0]).x == 1124
    assert screen.switch(config.OPENING_SWITCHES[0]).y == 246
    assert screen.dump == as_the_lab_keeps_it(OPENING)


def test_a_row_that_does_not_read_uDecks_defaults_is_not_the_row():
    """The whole identification: eight unnamed controls become *these* controls
    only because they read what a machine at rest reads. A screen where they do
    not is either not this screen or not at rest, and clicking on it would be a
    sentence about uDeck written from a random pixel."""
    moved = OPENING.replace("5|AXCheckBox|AXToggle|||0||1197;403;|29;20;",
                            "5|AXCheckBox|AXToggle|||1||1197;403;|29;20;")
    with pytest.raises(LabError, match="not the row, or the machine is not at rest") as raised:
        ui.opening(opened_on_opening(moved), "opening the settings")
    assert "modifier buttons" in raised.value.reason

    switched = OPENING.replace("5|AXCheckBox||||1||1124;448;|303;16;",
                               "5|AXCheckBox||||0||1124;448;|303;16;")
    with pytest.raises(LabError, match="switches read"):
        ui.opening(opened_on_opening(switched), "opening the settings")


def test_a_screen_whose_row_has_already_been_changed_is_taken_on_its_shape_alone():
    """A caller that has already moved one of them says so, because the row no
    longer reads what a default one does."""
    moved = OPENING.replace("5|AXCheckBox|AXToggle|||0||1197;403;|29;20;",
                            "5|AXCheckBox|AXToggle|||1||1197;403;|29;20;")
    screen = ui.opening(opened_on_opening(moved), "opening the settings", at_rest=False)
    assert screen.modifier(config.THE_ADDED_MODIFIER).value == "1"


def test_a_screen_the_controls_never_appeared_on_is_the_labs_failure():
    """A pane still being built answers with a tree that has neither row in it,
    and a check that clicked anyway would be clicking on the section before it."""
    machine = opened_on_opening("0|AXWindow|AXStandardWindow||uDeck Settings|||790;198;|980;648;")
    with pytest.raises(LabError, match="did not appear within") as raised:
        ui.opening(machine, "opening the settings", seconds=5)
    assert "0 modifier buttons" in raised.value.reason
    assert machine._clock.now >= 5
    assert not isinstance(raised.value, NotThere)


def test_the_screen_is_waited_for_rather_than_slept_at():
    """One walk when the pane is there, more when it is not — and never a fixed
    pause, which would be a number nothing measured."""
    machine = opened_on_opening(["0|AXWindow|AXStandardWindow||uDeck Settings|||790;198;|980;648;", OPENING])
    ui.opening(machine, "opening the settings")
    assert len(machine.helper_calls("walk")) == 4, "two to find Opening in the sidebar at rest, two of the screen"
    assert machine._clock.now == 1 + ui.SETTLED_SECONDS


# The same screen with the retract switch off, which is what the walk reads
# after the click on it has landed.
THE_SWITCH_PRESSED = OPENING.replace("5|AXCheckBox||||1||1124;448;|303;16;",
                                     "5|AXCheckBox||||0||1124;448;|303;16;")


def test_an_unnamed_control_is_pressed_with_the_pointer_and_never_through_the_api():
    """The rule for every control on these screens. `AXPress` needs no
    coordinates and would look simpler; it also does not select anything
    (2026-09-17), and it is not what the operator has."""
    machine = opened_on_opening([OPENING, THE_SWITCH_PRESSED])
    screen = ui.opening(machine, "opening the settings")
    after = ui.press(machine, screen.switch(config.THE_SWITCH), "turning the switch off")
    assert machine.clicks[-1] == (1124 + 303 // 2, 448 + 16 // 2)
    assert not any(" click " in script or "AXPress" in script for script in machine.ssh.scripts)
    # And what the control reads now, which is what says the click landed.
    assert (after.x, after.y, after.value) == (1124, 448, "0")
    assert machine._clock.now == ui.SETTLED_SECONDS, "the control answered on the first walk after the click"


def test_a_click_that_left_the_control_as_it_was_is_the_labs_failure():
    """A click at coordinates can miss — a window that moved, a pane still being
    laid out, a pointer that did not arrive — and a miss nobody read back
    becomes a verdict several steps later: the settings file holds nothing, and
    the check says the operator's change is nowhere about a uDeck that was never
    asked for one."""
    machine = opened_on_opening()
    screen = ui.opening(machine, "opening the settings")
    with pytest.raises(LabError, match="the click did not land on it") as raised:
        ui.press(machine, screen.switch(config.THE_SWITCH), "turning the switch off", seconds=5)
    assert not isinstance(raised.value, NotThere)
    # Where the click went and what was found there, both in the reason.
    assert "1275,456" in raised.value.reason and "value='1'" in raised.value.reason
    assert machine._clock.now >= 5


def test_a_control_that_is_no_longer_on_the_screen_after_the_click_says_so():
    """The other way a click lands nowhere: the screen moved out from under it."""
    machine = opened_on_opening([OPENING, "0|AXWindow|AXStandardWindow||uDeck Settings|||790;198;|980;648;"])
    screen = ui.opening(machine, "opening the settings")
    with pytest.raises(LabError, match="no control there at all"):
        ui.press(machine, screen.switch(config.THE_SWITCH), "turning the switch off", seconds=5)


def test_a_value_of_several_lines_is_walked_on_one_line():
    """A plugin's stderr, under More, is a value of several lines; the walk prints each control on one line."""
    walked = json.loads(ax_walk("5|AXStaticText||plugin.flaky.stderr||x||233;400;|300;26;"))
    walked["elements"][1]["value"] = "Traceback\r\nValueError: told to fail\nand\rmore"
    dump = ax.dump(ax.parse_walk(json.dumps(walked))[0], identified_only=True)
    assert len(dump.splitlines()) == 1
    (control,) = ui.controls(dump)
    assert ui.says(control) == f"Traceback{ui.LINE_BREAK}ValueError: told to fail{ui.LINE_BREAK}and{ui.LINE_BREAK}more"
    # And a line the old walk wrote, nine fields, still reads.
    row = f"5|AXStaticText||plugin.flaky.stderr||Traceback{ui.LINE_BREAK}ValueError: told to fail||233;400;|300;26;"
    (control,) = ui.controls(row)
    assert ui.says(control) == f"Traceback{ui.LINE_BREAK}ValueError: told to fail" and control.shown


def test_the_settings_window_is_reached_by_its_russian_names_when_uDeck_speaks_russian():
    assert ui.RUSSIAN.code == "ru"
    assert ui.RUSSIAN.settings_item == "Настройки…" and ui.RUSSIAN.settings_window == "Настройки uDeck"


def test_a_folder_is_chosen_by_typing_its_path_into_go_to_folder():
    script = ui._applescript(ui._CHOOSE_FOLDER, process=ui.PROCESS, path="/Users/admin/udeck-e2e-work/it's mine")
    assert 'keystroke "g" using {command down, shift down}' in script
    assert 'keystroke "/Users/admin/udeck-e2e-work/it\'s mine"' in script
    assert script.count("key code 36") == 2, "Return to go there, Return for the panel's own button"


def test_a_control_still_moving_is_aimed_at_only_once_it_has_come_to_rest():
    """The panel grows on a spring and a sheet slides down: a control read while
    they move is read where it is passing through (run 38224850163)."""
    moving = [ABOUT.replace("808;355;", f"808;{y};") for y in (300, 330, 355, 355)]
    machine = FakeMachine(walks=moving)
    element = ui.click(machine, "section.about", "opening About")
    assert element.y == 355 and machine.clicks == [(837, 363)]
    assert len(machine.helper_calls("walk")) == 4
    # And one that never stops moving is taken where it was last, at the deadline.
    restless = FakeMachine(walks=[ABOUT.replace("808;355;", f"808;{y};") for y in range(300, 400)])
    element = ui.wait_for(restless, "section.about", "opening About", seconds=2)
    assert restless._clock.now >= 2 and element.y < 400
