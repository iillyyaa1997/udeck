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
    """Answers the walk in order; a listing of what is there answers separately."""

    def __init__(self, answers, listing=""):
        self.answers = list(answers)
        self.listing = listing
        self.scripts = []

    def run(self, command, step, seconds=None, check=True):
        self.scripts.append(command)
        if "on describe(" in command:
            return done([], 0, self.listing)
        answer = self.answers.pop(0) if len(self.answers) > 1 else self.answers[0]
        if isinstance(answer, tuple):
            return done([], answer[0], answer[1], answer[2] if len(answer) > 2 else "")
        return done([], 0, answer)


class FakeMachine:
    def __init__(self, *answers, listing=""):
        self.name = "udeck-e2e-probe"
        self.ssh = FakeGuest(answers, listing)
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
