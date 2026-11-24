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


# --- The Opening screen ------------------------------------------------------------
#
# Since the redesign (stage 2, 2026-11-19) every control the lab presses there
# carries an identifier — `opening.<setting>` on each switch, `opening.shortcut`
# on the field — so the lab finds them by name and role. Every test here asks the
# same question: would this still pick the right control if the screen changed
# under it — and the answer has to be no, loudly.

# The screen as the walk read it in the guest (2026-11-19, run 44483491444,
# plugins.gallery, gallery-opening-at-rest.txt), a few rows of it. Deliberately
# not in the order the controls are laid out in: the walk prints them in tree
# order, and nothing here may depend on it.
OPENING = "\n".join([
    "0|AXWindow|AXStandardWindow||uDeck Settings|||60;40;|1500;961;",
    "8|AXStaticText||section.opening||Opening||87;128;|79;20;",
    "6|AXCheckBox|AXSwitch|opening.collapseOnAppSwitch||1||1190;529;|36;16;",
    "6|AXSlider||opening.gesture.dwellDuration||0.08|Wait at the edge|848;217;|187;16;",
    "6|AXCheckBox|AXSwitch|opening.gesture.enabled||1||1190;165;|36;16;",
    "6|AXStaticText||||Open by moving the cursor to the top edge||542;165;|261;16;",
    "6|AXButton||opening.shortcut||⌃⌥U||1046;388;|132;28;",
    "6|AXCheckBox|AXToggle|opening.hotkey.enabled||1||1190;394;|36;16;",
    "6|AXCheckBox|AXSwitch|opening.pollWhileCollapsed||0||1190;603;|36;16;",
    "6|AXCheckBox|AXSwitch|opening.gesture.enabledInFullscreen||1||1190;566;|36;16;",
])  # fmt: skip

EMPTY_PANE = "0|AXWindow|AXStandardWindow||uDeck Settings|||60;40;|1500;961;"


def opened_on_opening(tree=OPENING):
    """A guest with the settings window open and the walk answering: twice to find Opening in the sidebar at rest, then `tree`."""
    return FakeMachine(walks=[OPENING, OPENING, *(tree if isinstance(tree, list) else [tree])])


def test_the_walk_reads_every_attribute_a_click_at_a_control_needs():
    controls = ui.controls(OPENING)
    window = controls[0]
    assert (window.role, window.title) == ("AXWindow", "uDeck Settings")
    assert (window.x, window.y, window.width, window.height) == (60, 40, 1500, 961)
    assert [c.identifier for c in controls if c.identifier.startswith("opening.")] == [
        "opening.collapseOnAppSwitch", "opening.gesture.dwellDuration", "opening.gesture.enabled",
        "opening.shortcut", "opening.hotkey.enabled", "opening.pollWhileCollapsed",
        "opening.gesture.enabledInFullscreen",
    ]
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
    # The screen is read through the same parse, so nothing is lost behind it.
    with pytest.raises(LabError, match="not a control"):
        ui.opening_controls(piped)


def test_the_switches_come_back_in_the_configs_order_and_the_field_beside_them():
    switches, shortcut = ui.opening_controls(OPENING)
    assert [s.identifier for s in switches] == [f"opening.{name}" for name in config.OPENING_SWITCHES]
    assert [s.value for s in switches] == list(config.OPENING_SWITCHES_AT_REST)
    assert (shortcut.role, shortcut.value) == ("AXButton", config.THE_HOTKEY)
    # The shortcut row's switch is drawn as a toggle and is a switch all the same.
    assert switches[config.OPENING_SWITCHES.index("hotkey.enabled")].subrole == "AXToggle"
    # A control of another screen is not one of these: the General screen's login
    # switch is an AXCheckBox with an identifier, and it must never be picked up.
    named = OPENING + "\n5|AXCheckBox|AXSwitch|general.openAtLogin||0||967;281;|104;16;"
    assert ui.opening_controls(named) == (switches, shortcut)


def test_a_name_on_a_control_of_another_kind_is_not_the_control():
    """By role as well as name: an identifier that landed on the row's group, or a
    field drawn as something that is not a button, is not what the lab presses."""
    grouped = OPENING.replace("6|AXCheckBox|AXSwitch|opening.gesture.enabled||1||1190;165;|36;16;",
                              "5|AXGroup||opening.gesture.enabled||||532;155;|704;165;")
    switches, _ = ui.opening_controls(grouped)
    assert switches[0] is None
    as_text = OPENING.replace("6|AXButton||opening.shortcut||⌃⌥U||1046;388;|132;28;",
                              "6|AXStaticText||opening.shortcut||⌃⌥U||1046;388;|132;28;")
    assert ui.opening_controls(as_text)[1] is None


def test_a_name_found_twice_is_the_labs_error():
    """Two controls carrying one name: a click on either could be a click on the
    other, so the lab refuses rather than choosing."""
    twice = OPENING + "\n6|AXCheckBox|AXSwitch|opening.gesture.enabled||1||1190;700;|36;16;"
    with pytest.raises(LabError, match="2 controls carry 'opening.gesture.enabled'"):
        ui.opening_controls(twice)


def test_the_screen_names_each_control_by_the_setting_it_writes():
    screen = ui.opening(opened_on_opening(), "opening the settings")
    assert screen.switch(config.THE_SWITCH).y == 529
    assert screen.switch(config.OPENING_SWITCHES[0]).y == 165
    assert screen.switch("pollWhileCollapsed").value == "0"
    assert (screen.shortcut.x, screen.shortcut.y, screen.shortcut.width) == (1046, 388, 132)
    assert screen.dump == as_the_lab_keeps_it(OPENING)


def test_a_screen_that_does_not_read_uDecks_defaults_is_not_at_rest():
    """A screen where the switches or the field do not read what a machine at rest
    reads is either not this screen or not at rest, and clicking on it would be a
    sentence about uDeck written from a random pixel."""
    switched = OPENING.replace("6|AXCheckBox|AXSwitch|opening.collapseOnAppSwitch||1||1190;529;|36;16;",
                               "6|AXCheckBox|AXSwitch|opening.collapseOnAppSwitch||0||1190;529;|36;16;")
    with pytest.raises(LabError, match="switches read") as raised:
        ui.opening(opened_on_opening(switched), "opening the settings")
    assert "not at rest" in raised.value.reason

    changed = OPENING.replace("|opening.shortcut||⌃⌥U|", f"|opening.shortcut||{config.THE_NEW_HOTKEY}|")
    with pytest.raises(LabError, match="the shortcut field reads"):
        ui.opening(opened_on_opening(changed), "opening the settings")


def test_a_screen_already_changed_is_taken_on_its_controls_alone():
    """A caller that has already changed one of them says so, because the screen
    no longer reads what a default one does."""
    changed = OPENING.replace("|opening.shortcut||⌃⌥U|", f"|opening.shortcut||{config.THE_NEW_HOTKEY}|")
    screen = ui.opening(opened_on_opening(changed), "opening the settings", at_rest=False)
    assert screen.shortcut.value == config.THE_NEW_HOTKEY


def test_a_screen_the_controls_never_appeared_on_is_the_labs_failure():
    """A pane still being built answers with a tree that has none of them in it,
    and a check that clicked anyway would be clicking on the section before it."""
    machine = opened_on_opening(EMPTY_PANE)
    with pytest.raises(LabError, match="did not appear within") as raised:
        ui.opening(machine, "opening the settings", seconds=5)
    assert "opening.gesture.enabled" in raised.value.reason and config.OPENING_SHORTCUT in raised.value.reason
    assert machine._clock.now >= 5
    assert not isinstance(raised.value, NotThere)


def test_the_screen_is_waited_for_rather_than_slept_at():
    """One walk when the pane is there, more when it is not — and never a fixed
    pause, which would be a number nothing measured."""
    machine = opened_on_opening([EMPTY_PANE, OPENING])
    ui.opening(machine, "opening the settings")
    assert len(machine.helper_calls("walk")) == 4, "two to find Opening in the sidebar at rest, two of the screen"
    assert machine._clock.now == 1 + ui.SETTLED_SECONDS


# The same screen with the retract switch off, which is what the walk reads
# after the click on it has landed.
THE_SWITCH_PRESSED = OPENING.replace("6|AXCheckBox|AXSwitch|opening.collapseOnAppSwitch||1||1190;529;|36;16;",
                                     "6|AXCheckBox|AXSwitch|opening.collapseOnAppSwitch||0||1190;529;|36;16;")

# And with the field recording, which is what it reads once a click on it landed.
RECORDING = OPENING.replace("|opening.shortcut||⌃⌥U|", "|opening.shortcut||Press keys…|")


def test_a_control_is_pressed_with_the_pointer_and_never_through_the_api():
    """The rule for every control on these screens. `AXPress` needs no
    coordinates and would look simpler; it also does not select anything
    (2026-09-17), and it is not what the operator has."""
    machine = opened_on_opening([OPENING, THE_SWITCH_PRESSED])
    screen = ui.opening(machine, "opening the settings")
    after = ui.press(machine, screen.switch(config.THE_SWITCH), "turning the switch off")
    assert machine.clicks[-1] == (1190 + 36 // 2, 529 + 16 // 2)
    assert not any(" click " in script or "AXPress" in script for script in machine.ssh.scripts)
    # And what the control reads now, which is what says the click landed.
    assert (after.x, after.y, after.value) == (1190, 529, "0")
    assert machine._clock.now == ui.SETTLED_SECONDS, "the control answered on the first walk after the click"


def test_a_click_on_the_field_is_read_back_as_it_starting_to_record():
    """The field keeps its place and size while it records, so the read-back that
    tells a landed click from a missed one finds it where it was, reading the
    prompt instead of the shortcut."""
    machine = opened_on_opening([OPENING, RECORDING])
    screen = ui.opening(machine, "opening the settings")
    after = ui.press(machine, screen.shortcut, "clicking the shortcut field")
    assert machine.clicks[-1] == (1046 + 132 // 2, 388 + 28 // 2)
    assert after.value == "Press keys…"


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
    assert "1208,537" in raised.value.reason and "value='1'" in raised.value.reason
    assert machine._clock.now >= 5


def test_a_control_that_is_no_longer_on_the_screen_after_the_click_says_so():
    """The other way a click lands nowhere: the screen moved out from under it."""
    machine = opened_on_opening([OPENING, EMPTY_PANE])
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


def test_the_focus_is_read_as_its_identifier_and_subrole():
    machine = FakeMachine(typed="sources.add.tokenField|AXSecureTextField")
    assert ui.focused(machine, "reading the focus") == ("sources.add.tokenField", "AXSecureTextField")
    assert 'value of attribute "AXFocusedUIElement"' in machine.ssh.scripts[0]
    assert 'tell process "uDeck"' in machine.ssh.scripts[0]
    # No variable named for a property of a process: inside `tell process`, setting one sets the process's.
    for word in ("subrole", "focused", "identifier", "role", "value", "name", "title"):
        assert f"set {word} to" not in machine.ssh.scripts[0], word
    assert ui.focused(FakeMachine(typed="|"), "reading the focus") == ("", "")


def _secret_scene(monkeypatch, focus):
    """`enter_secret` with the focus read from `focus` in turn, and every click and every script asked recorded."""
    answers = iter(focus)
    monkeypatch.setattr(ui, "focused", lambda machine, step: next(answers))
    clicks = []
    monkeypatch.setattr(ui, "click", lambda machine, identifier, step, window=ui.SETTINGS_WINDOW: clicks.append(identifier))
    machine = FakeMachine()
    return machine, clicks


SECURE = ("sources.add.tokenField", ui.SECURE_FIELD)
SECRET_FILE = "/Users/runner/.udeck-e2e-secrets/gitlab-private"


def _typed(machine):
    return [script for script in machine.ssh.scripts if "keystroke" in script]


def test_a_secret_is_typed_only_once_its_secure_field_has_the_focus(monkeypatch):
    """Run 42335961364: the click left the focus in the address field, and the token was typed there, in the clear."""
    machine, clicks = _secret_scene(monkeypatch, [("sources.add.field", "AXTextField"), SECURE, SECURE])
    ui.enter_secret(machine, "sources.add.tokenField", SECRET_FILE, "typing the token")
    assert clicks == ["sources.add.tokenField"] and len(_typed(machine)) == 1


def test_a_secret_is_typed_from_its_file_and_its_value_is_in_no_command(monkeypatch):
    """S4-22: the script names the file and reads it in the guest — the value is never in `osascript -e`'s argument."""
    machine, _ = _secret_scene(monkeypatch, [SECURE, SECURE])
    ui.enter_secret(machine, "sources.add.tokenField", SECRET_FILE, "typing the token")
    [script] = _typed(machine)
    assert f'read (POSIX file "{SECRET_FILE}")' in script
    assert "keystroke theSecret" in script and 'tell process "uDeck"' in script
    # Its variable is no process's property, and it is set outside `tell process`.
    assert script.index("set theSecret to") < script.index("tell application")


def test_a_secret_is_never_typed_into_a_field_that_shows_it(monkeypatch):
    machine, clicks = _secret_scene(monkeypatch, [("sources.add.field", "AXTextField")] * ui.SECRET_FOCUS_TRIES)
    with pytest.raises(LabError, match="never took the focus"):
        ui.enter_secret(machine, "sources.add.tokenField", SECRET_FILE, "typing the token")
    assert _typed(machine) == [] and clicks == ["sources.add.tokenField"] * ui.SECRET_FOCUS_TRIES


def test_the_right_identifier_in_a_field_that_shows_its_text_is_not_enough(monkeypatch):
    plain = ("sources.add.tokenField", "")
    machine, _ = _secret_scene(monkeypatch, [plain] * ui.SECRET_FOCUS_TRIES)
    with pytest.raises(LabError, match="never took the focus"):
        ui.enter_secret(machine, "sources.add.tokenField", SECRET_FILE, "typing the token")
    assert _typed(machine) == []


def test_the_focus_leaving_while_typing_is_a_lab_problem(monkeypatch):
    machine, _ = _secret_scene(monkeypatch, [SECURE, ("sources.add.field", "AXTextField")])
    with pytest.raises(LabError, match="left sources.add.tokenField"):
        ui.enter_secret(machine, "sources.add.tokenField", SECRET_FILE, "typing the token")
    assert len(_typed(machine)) == 1


class _Pasteboard(FakeGuest):
    """A guest whose shell answers the pasteboard's commands, recording them."""

    def __init__(self, compared=0):
        super().__init__()
        self.compared = compared

    def run(self, command, step, seconds=None, check=True):
        if command.startswith(("pbcopy ", "pbpaste ")):
            self.scripts.append(command)
            return done([], self.compared if command.startswith("pbpaste") else 0, "")
        return super().run(command, step, seconds, check)


def test_a_pasted_secret_goes_from_its_file_to_the_pasteboard_and_in_with_command_v_where_the_focus_is(monkeypatch):
    machine, clicks = _secret_scene(monkeypatch, [("sources.add.field", "AXTextField"), SECURE, SECURE])
    machine.ssh = _Pasteboard()
    ui.paste_secret(machine, "sources.add.tokenField", SECRET_FILE, "pasting the token")
    copied, compared, pasted = machine.ssh.scripts
    assert copied == f"pbcopy < {SECRET_FILE}"
    assert compared == f"pbpaste | cmp -s - {SECRET_FILE}"
    assert 'keystroke "v" using command down' in pasted
    assert clicks == ["sources.add.tokenField"]


def test_a_copy_that_left_the_pasteboard_without_the_secret_pastes_nothing(monkeypatch):
    """A ⌘V into an empty field says something of uDeck only when the pasteboard held the token first."""
    machine, clicks = _secret_scene(monkeypatch, [SECURE, SECURE])
    machine.ssh = _Pasteboard(compared=1)
    with pytest.raises(LabError, match="does not hold the secret after pbcopy"):
        ui.paste_secret(machine, "sources.add.tokenField", SECRET_FILE, "pasting the token")
    assert not [script for script in machine.ssh.scripts if "command down" in script] and clicks == []


def test_a_secret_is_not_pasted_into_a_field_that_shows_it(monkeypatch):
    machine, _ = _secret_scene(monkeypatch, [("sources.add.field", "AXTextField")] * ui.SECRET_FOCUS_TRIES)
    machine.ssh = _Pasteboard()
    with pytest.raises(LabError, match="never took the focus"):
        ui.paste_secret(machine, "sources.add.tokenField", SECRET_FILE, "pasting the token")
    assert not [script for script in machine.ssh.scripts if "command down" in script]


def test_the_pasteboard_is_compared_with_the_secret_in_the_guest_never_read_out():
    machine = FakeMachine()
    machine.ssh = _Pasteboard(compared=0)
    assert ui.pasteboard_holds(machine, SECRET_FILE, "reading the pasteboard")
    assert machine.ssh.scripts == [f"pbpaste | cmp -s - {SECRET_FILE}"]
    machine.ssh = _Pasteboard(compared=1)
    assert not ui.pasteboard_holds(machine, SECRET_FILE, "reading the pasteboard")


class _Shell(FakeGuest):
    def run(self, command, step, seconds=None, check=True):
        self.scripts.append(command)
        return done([], 0, "/Users/runner/.udeck-e2e-secrets\n")


def test_a_fixture_secret_is_kept_in_a_file_its_owner_alone_reads_at_an_absolute_path():
    machine = FakeMachine()
    machine.ssh = _Shell()
    path = ui.keep_secret(machine, "gitlab-private", "glpat-fixture", "keeping the token")
    assert path == SECRET_FILE
    [command] = machine.ssh.scripts
    assert command.startswith("umask 077 && ") and "glpat-fixture" in command
    with pytest.raises(LabError, match="letters, digits and dashes"):
        ui.keep_secret(machine, "../escape", "x", "keeping the token")


def test_return_is_pressed_in_the_focused_field_by_its_key_code():
    machine = FakeMachine(typed="pressed")
    ui.press_return(machine, "ending the token")
    assert "key code 36" in machine.ssh.scripts[0] and 'tell process "uDeck"' in machine.ssh.scripts[0]


# --- Which section holds uDeck's updates (`ui.open_updates_pane`) ----------------------------

SECTIONS_HEAD = "0|AXWindow|AXStandardWindow||uDeck Settings|||790;198;|980;648;"
GENERAL_ROW = "8|AXStaticText||section.general||General||808;330;|59;17;"
ABOUT_ROW = "8|AXStaticText||section.about||About||808;355;|59;17;"
LOGIN_SWITCH = "5|AXCheckBox||general.openAtLogin||0||955;300;|83;20;"
CHECK_NOW = "5|AXButton||updates.checkNow||||955;455;|83;20;"


class SectionsGuest(FakeGuest):
    """A settings window whose pane follows the sidebar clicked — `stale` walks late after each click."""

    def __init__(self, panes, showing, stale=0, general=True):
        super().__init__()
        self.panes, self.showing, self.stale, self.general = panes, showing, stale, general
        self.wanted, self.late = showing, 0

    def _helper(self, args):
        if args[0] != "walk":
            return super()._helper(args)
        if self.late > 0:
            self.late -= 1
        else:
            self.showing = self.wanted
        rows = [SECTIONS_HEAD, *([GENERAL_ROW] if self.general else []), ABOUT_ROW, *self.panes[self.showing]]
        return done([], 0, ax_walk("\n".join(rows), window=args[2].removeprefix("title=")))


class SectionsMachine(FakeMachine):
    def __init__(self, panes, showing="general", stale=0, general=True):
        super().__init__()
        self.ssh = SectionsGuest(panes, showing, stale, general)
        self.sections = []

    def click(self, x, y, step):
        super().click(x, y, step)
        section = "general" if y < 343 else "about"
        self.sections.append(section)
        self.ssh.wanted, self.ssh.late = section, self.ssh.stale


def test_a_uDeck_since_the_redesign_has_its_updates_in_General():
    machine = SectionsMachine({"general": [LOGIN_SWITCH, CHECK_NOW], "about": []})
    assert ui.open_updates_pane(machine, "choosing the updates").identifier == "updates.checkNow"
    assert machine.sections == ["general"]


def test_a_release_before_it_has_them_in_About():
    machine = SectionsMachine({"general": [LOGIN_SWITCH], "about": [CHECK_NOW]})
    assert ui.open_updates_pane(machine, "choosing the updates").identifier == "updates.checkNow"
    assert machine.sections == ["general", "about"]
    assert machine.ssh.showing == "about"


def test_a_walk_taken_before_General_showed_is_not_read_as_General():
    """Codex, 2026-11-18: About still on screen right after General was clicked holds About's Check now."""
    machine = SectionsMachine({"general": [LOGIN_SWITCH], "about": [CHECK_NOW]}, showing="about", stale=3)
    ui.open_updates_pane(machine, "choosing the updates")
    assert machine.sections == ["general", "about"]


def test_a_release_from_before_General_goes_straight_to_About():
    """Fable, 2026-11-18: a release whose sidebar has no General is not refused by a click on it."""
    machine = SectionsMachine({"general": [], "about": [CHECK_NOW]}, showing="about", general=False)
    assert ui.open_updates_pane(machine, "choosing the updates").identifier == "updates.checkNow"
    assert machine.sections == ["about"]


CHECK_AND_INSTALL = "5|AXButton||updates.checkAndInstall||||955;455;|83;20;"
UPDATE = "5|AXButton||updates.install||||955;455;|83;20;"


def test_one_press_in_General_is_found_as_the_updates():
    """0.9.12: Check now is gone, Check and update is the press — General is still told by it."""
    machine = SectionsMachine({"general": [LOGIN_SWITCH, CHECK_AND_INSTALL], "about": []})
    assert ui.open_updates_pane(machine, "choosing the updates").identifier == ui.CHECK_AND_INSTALL
    assert machine.sections == ["general"]


def test_a_version_waiting_on_one_button_is_found_as_the_updates():
    """With one button a found version shows only Update: that is the updates showing, not a pane without them."""
    machine = SectionsMachine({"general": [LOGIN_SWITCH, UPDATE], "about": []})
    assert ui.open_updates_pane(machine, "choosing the updates").identifier == "updates.install"
    assert machine.sections == ["general"]


# --- The Plugins pane's tabs -----------------------------------------------------------

TABS = [
    "6|AXButton||plugins.tab.installed||||900;250;|120;30;",
    "6|AXButton||plugins.tab.catalogue||||1030;250;|100;30;",
    "6|AXButton||plugins.tab.sources||||1140;250;|100;30;",
    "6|AXButton||plugins.tab.developers||||1250;250;|140;30;",
]
INSTALLED_PAGE = "\n".join(["0|AXWindow|AXStandardWindow||uDeck Settings|||790;198;|980;648;", *TABS,
    "6|AXStaticText||plugins.page.installed||What is installed||900;290;|300;16;",
    "7|AXButton||plugins.row.uptime||||900;330;|230;40;",
    "7|AXButton||plugins.row.team.clock||||900;372;|230;40;",
    "7|AXStaticText||plugins.card.uptime||Uptime||1150;330;|100;20;",
    "7|AXButton||plugin.uptime.remove||||1500;600;|60;20;",
])  # fmt: skip
CLOCK_CARD = INSTALLED_PAGE.replace("plugins.card.uptime||Uptime", "plugins.card.team.clock||team-clock").replace(
    "plugin.uptime.remove", "plugin.team.clock.remove")
CATALOGUE_PAGE = "\n".join(["0|AXWindow|AXStandardWindow||uDeck Settings|||790;198;|980;648;", *TABS,
    "6|AXStaticText||plugins.page.catalogue||Plugins from the official catalogue||900;290;|300;16;",
    "7|AXButton||catalogue.checkNow||||1500;320;|80;20;",
    "7|AXStaticText||catalogue.uptime.state||Installed||1000;360;|200;16;",
])  # fmt: skip
OLD_PANE = "\n".join([
    "0|AXWindow|AXStandardWindow||uDeck Settings|||790;198;|980;648;",
    "5|AXCheckBox||catalogue.enabled||1||955;300;|20;20;",
    "5|AXButton||plugin.uptime.remove||||955;400;|60;20;",
])  # fmt: skip


@pytest.mark.parametrize(("identifier", "tab"), [
    ("plugin.uptime.remove", ui.INSTALLED), ("plugin.uptime.history.1.0.0.install", ui.INSTALLED),
    ("plugins.nothingInstalled", ui.INSTALLED), ("catalogue.enabled", ui.CATALOGUE), ("catalogue.uptime.install", ui.CATALOGUE),
    ("catalogue.updateAll", ui.CATALOGUE), ("source.github.com-team-1a2b3c4d.plugin.team-clock.install", ui.CATALOGUE),
    ("source.github.com-team-1a2b3c4d.empty", ui.CATALOGUE), ("source.github.com-team-1a2b3c4d.mark", ui.SOURCES),
    ("source.github.com-team-1a2b3c4d.token.tokenField", ui.SOURCES), ("sources.add.field", ui.SOURCES),
    ("link.field", ui.SOURCES), ("plugins.installFromLink", ui.SOURCES), ("plugins.linkFolder.confirm", ui.DEVELOPERS),
    ("plugins.runLog", ui.DEVELOPERS), ("searchPath.add", ui.DEVELOPERS), ("command.install", ui.DEVELOPERS),
    ("plugins.tab.sources", None), ("plugins.row.uptime", None), ("section.plugins", None), ("updates.checkNow", None),
])  # fmt: skip
def test_every_control_of_the_plugins_pane_is_on_its_tab(identifier, tab):
    assert ui.plugins_tab_of(identifier) == tab


def test_a_plugin_with_dots_in_its_id_is_told_from_one_whose_id_it_starts_with():
    ids = ["plugins.row.team", "plugins.row.team.clock"]
    assert ui._plugin_of("plugin.team.clock.remove", ids) == "team.clock"
    assert ui._plugin_of("plugin.team.remove", ids) == "team"
    assert ui._plugin_of("plugin.uptime.remove", ids) is None


def test_a_control_on_another_tab_is_found_there_after_one_click_on_its_tab():
    machine = FakeMachine(walks=[INSTALLED_PAGE, CATALOGUE_PAGE])
    found = ui.find(machine, "catalogue.uptime.state", "reading uptime's catalogue row")
    assert found is not None and found.identifier == "catalogue.uptime.state"
    # The Catalogue tab, in its middle — once.
    assert machine.clicks == [(1080, 265)]


def test_an_installed_plugins_control_is_found_on_its_card():
    machine = FakeMachine(walks=[INSTALLED_PAGE, INSTALLED_PAGE, CLOCK_CARD])
    found = ui.find(machine, "plugin.team.clock.remove", "reading team-clock's Remove")
    assert found is not None and found.identifier == "plugin.team.clock.remove"
    # team-clock's row in the list, and not uptime's.
    assert machine.clicks == [(1015, 392)]


def test_a_control_absent_from_its_own_tab_and_card_is_absent_with_nothing_clicked():
    machine = FakeMachine(walks=[CATALOGUE_PAGE])
    assert ui.find(machine, "catalogue.uptime.install", "looking for Install") is None
    assert machine.clicks == []


def test_a_release_from_before_the_tabs_is_never_switched():
    machine = FakeMachine(walks=[OLD_PANE])
    assert ui.find(machine, "catalogue.checkNow", "looking for Check now") is None
    assert ui.find(machine, "plugin.uptime.remove", "finding Remove").identifier == "plugin.uptime.remove"
    assert machine.clicks == []
    ui.wait_for_plugins_pane(machine, "waiting for the pane")


def test_a_walk_of_one_tab_asked_for_a_control_of_another_is_read_again_there():
    machine = FakeMachine(walks=[INSTALLED_PAGE, INSTALLED_PAGE, CATALOGUE_PAGE, CATALOGUE_PAGE])
    dump = ui.identified(machine, "reading the pane")
    assert ui.element(dump, "plugin.uptime.remove") is not None
    state = ui.element(dump, "catalogue.uptime.state")
    assert state is not None and ui.says(state) == "Installed"
    assert machine.clicks == [(1080, 265)]
    # A control of the tab the walk is of, absent, is absent: nothing is read again.
    assert ui.element(ui.showing(dump, "catalogue.uptime.state"), "catalogue.uptime.install") is None


def test_a_tab_that_never_shows_its_page_is_the_labs_failure():
    machine = FakeMachine(walks=[INSTALLED_PAGE])
    with pytest.raises(LabError, match="plugins.tab.catalogue' was clicked 3 times"):
        ui.find(machine, "catalogue.checkNow", "looking for Check now")
    assert len(machine.clicks) == ui.TAB_CLICKS


def test_a_source_on_a_host_with_plugin_in_its_name_keeps_its_own_controls_on_sources():
    sid = "gitlab.plugin.example-tools-1a2b3c4d"
    assert ui.plugins_tab_of(f"source.{sid}.trust") == ui.SOURCES
    assert ui.plugins_tab_of(f"source.{sid}.token.forget") == ui.SOURCES
    assert ui.plugins_tab_of(f"source.{sid}.plugin.team-clock.install") == ui.CATALOGUE
    assert ui.plugins_tab_of(f"source.{sid}.empty") == ui.CATALOGUE
