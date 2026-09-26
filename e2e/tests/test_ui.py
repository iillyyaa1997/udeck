"""Driving the interface: what is asked of the guest, and what is done with the answer."""

import subprocess

import pytest

from udeck_e2e import config, ui
from udeck_e2e.errors import LabError, NotThere


def done(args, rc=0, out="", err=""):
    return subprocess.CompletedProcess(args, rc, out, err)


class Clock:
    def __init__(self):
        self.now = 0.0

    def __call__(self):
        return self.now

    def sleep(self, seconds):
        self.now += seconds


class FakeGuest:
    """Answers the walk in order; a listing and a tree answer separately.

    The tree is told from the listing by `on attr(`, which only the walk asks
    for: both scripts define a handler called `describe`, so the listing's own
    discriminator would catch the walk as well and hand it the wrong answer.

    The menu's titles and the guest's own language answer by what was asked
    rather than by their turn in the queue: both are read only when the lab has
    already failed, after any number of attempts, so a queued answer would
    belong to whichever attempt happened to be last.
    """

    def __init__(self, answers, listing="", tree="", menu="", language=""):
        self.answers = list(answers)
        self.listing = listing
        self.tree = tree
        self.menu = menu
        self.language = language
        self.scripts = []

    def run(self, command, step, seconds=None, check=True):
        self.scripts.append(command)
        if "on attr(" in command:
            tree = self.tree.pop(0) if isinstance(self.tree, list) and len(self.tree) > 1 else self.tree
            return done([], 0, tree[0] if isinstance(tree, list) else tree)
        if "on describe(" in command:
            return done([], 0, self.listing)
        if "name of every menu item" in command:
            return done([], 0, self.menu)
        if "AppleLanguages" in command:
            return done([], 0, self.language)
        answer = self.answers.pop(0) if len(self.answers) > 1 else self.answers[0]
        if isinstance(answer, tuple):
            return done([], answer[0], answer[1], answer[2] if len(answer) > 2 else "")
        return done([], 0, answer)


class FakeMachine:
    def __init__(self, *answers, listing="", tree="", menu="", language=""):
        self.name = "udeck-e2e-probe"
        self.ssh = FakeGuest(answers, listing, tree, menu, language)
        self.clicks = []
        self._clock = Clock()

    def click(self, x, y, step):
        self.clicks.append((x, y))

    def clock(self):
        return self._clock()

    def sleep(self, seconds):
        self._clock.sleep(seconds)


def test_a_control_is_found_by_its_identifier_and_clicked_in_its_middle():
    machine = FakeMachine("808,355,59,17")
    element = ui.click(machine, "section.about", "opening About")
    assert element == ui.Element("section.about", 808, 355, 59, 17)
    assert machine.clicks == [(837, 363)]
    # The identifier is quoted into the script, and the walk is bounded.
    script = machine.ssh.scripts[0]
    assert '"section.about"' in script and f"depth < {ui.MAX_DEPTH}" in script
    assert '"uDeck Settings"' in script


def test_a_control_that_never_appears_says_what_is_there_instead():
    machine = FakeMachine("not found", listing="AXButton [updates.checkNow], AXCheckBox [updates.automatic]")
    with pytest.raises(LabError, match="updates.install' did not appear") as raised:
        ui.wait_for(machine, "updates.install", "installing", seconds=5)
    assert "updates.checkNow" in raised.value.reason
    assert machine._clock.now >= 5


def test_a_control_that_appears_a_moment_later_is_waited_for():
    machine = FakeMachine("not found", "not found", "955,455,83,20")
    element = ui.wait_for(machine, "updates.checkNow", "checking", seconds=30)
    assert element.middle == (996, 465)
    assert 0 < machine._clock.now < 30


def test_an_answer_the_lab_cannot_read_is_a_lab_error():
    with pytest.raises(LabError, match="unexpected answer"):
        ui.find(FakeMachine("955,455"), "updates.checkNow", "checking")


def test_system_events_refusing_is_a_lab_error_not_a_verdict():
    machine = FakeMachine("x")
    machine.ssh.run = lambda command, step, seconds=None, check=True: done(
        [], 1, "", "execution error: System Events got an error: … (-1728)"
    )
    with pytest.raises(LabError, match="System Events refused"):
        ui.identifiers(machine, "listing")


def test_the_settings_window_is_opened_from_the_applications_own_menu():
    machine = FakeMachine("opened")
    ui.open_settings(machine, "opening the settings")
    script = machine.ssh.scripts[0]
    assert '"Settings…"' in script and "menu bar item 1 of menu bar 1" in script


def test_every_script_asks_only_about_udeck():
    machine = FakeMachine("", "", "")
    ui.identifiers(machine, "listing")
    ui.find(machine, "updates.checkNow", "finding")
    ui.open_settings(machine, "opening")
    for script in machine.ssh.scripts:
        assert '"uDeck"' in script


def test_only_the_control_never_appearing_is_NotThere():
    """A check may act on "uDeck did not offer it"; it may not act on a refusal.

    Both used to arrive as the same LabError, and the negative control read the
    second as the first: a click the lab could not make became "uDeck did not
    even offer it" and the check passed having pressed nothing.
    """
    machine = FakeMachine("not found", listing="AXButton [updates.checkNow]")
    with pytest.raises(NotThere):
        ui.wait_for(machine, "updates.install", "installing", seconds=5)

    refused = FakeMachine((1, "", "execution error: System Events got an error: … (-1728)"))
    with pytest.raises(LabError) as raised:
        ui.wait_for(refused, "updates.install", "installing", seconds=5)
    assert not isinstance(raised.value, NotThere)
    # It comes out at once, without waiting the window out: nothing is being waited for.
    assert refused._clock.now == 0


def test_the_settings_window_is_asked_for_again_until_it_is_there():
    """The menu press is made moments after uDeck was launched.

    A status item that is not in the menu bar yet makes System Events refuse, and
    a press that lands before the application is ready does nothing at all —
    both the lab being early, and both used to end the check as "could not check".
    """
    machine = FakeMachine(
        (1, "", "execution error: System Events got an error: … (-1728)"),  # no menu yet
        "opened",
        "Something Else",                                                   # pressed, no window
        "opened",
        "uDeck Settings, Something Else",
    )
    ui.open_settings_and_wait(machine, "opening uDeck's settings", seconds=30)
    assert len([s for s in machine.ssh.scripts if "click menu item" in s]) == 3


def test_a_settings_window_that_never_opens_is_a_lab_problem():
    machine = FakeMachine("opened", "Something Else")
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
        (1, "", "execution error: System Events got an error: Can't get menu item \"Settings…\". (-1719)"),
        menu="О приложении uDeck, Настройки…, Завершить uDeck",
        language="(ru,en)",
    )
    with pytest.raises(LabError) as raised:
        ui.open_settings_and_wait(machine, "opening uDeck's settings", seconds=5)
    reason = raised.value.reason
    assert "'Settings…'" in reason and "translated" in reason
    assert "(ru,en)" in reason and "Настройки…" in reason


def test_a_guest_that_will_not_say_which_language_it_is_in_still_gives_a_reason():
    """Both of those are evidence, and evidence may not raise over a reason."""
    machine = FakeMachine("opened", "Something Else")
    machine.ssh.menu = ""
    with pytest.raises(LabError) as raised:
        ui.open_settings_and_wait(machine, "opening uDeck's settings", seconds=5)
    assert "the guest said nothing" in raised.value.reason
    assert "offers nothing" in raised.value.reason


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

# What the sidebar's own identifier answers, so that choosing the section is a
# click at coordinates like every other one.
THE_SIDEBAR_ROW = "935,226,144,28"


def opened_on_opening(tree=OPENING):
    """A guest with the settings window open and the walk answering."""
    return FakeMachine("opened", ui.SETTINGS_WINDOW, THE_SIDEBAR_ROW, tree=tree)


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
    assert screen.dump == OPENING


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
    machine = FakeMachine("opened", ui.SETTINGS_WINDOW, THE_SIDEBAR_ROW,
                          tree=["0|AXWindow|AXStandardWindow||uDeck Settings|||790;198;|980;648;", OPENING])
    ui.opening(machine, "opening the settings")
    assert len([s for s in machine.ssh.scripts if "on attr(" in s]) == 2
    assert machine._clock.now == 1


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
    assert not any("AXPress" in script for script in machine.ssh.scripts)
    # And what the control reads now, which is what says the click landed.
    assert (after.x, after.y, after.value) == (1124, 448, "0")
    assert machine._clock.now == 0, "the control answered on the first walk after the click"


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
