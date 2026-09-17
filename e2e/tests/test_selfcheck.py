"""The self-check's own body, against a fake machine.

It runs on a real virtual machine, so these tests stand in for the machine and
watch what the check asks of it — that the pointer is read back independently,
and that the screen is proved to follow what the guest draws.
"""

import importlib.util
from pathlib import Path

import pytest

from udeck_e2e.errors import LabError

# Loaded by path and under a name of its own: the plugin's tests copy this file
# into a checks directory of their own, and two modules called `check_lab` in one
# session would shadow each other.
_source = Path(__file__).resolve().parents[1] / "selfcheck" / "check_lab.py"
_spec = importlib.util.spec_from_file_location("selfcheck_check_lab", _source)
check_lab = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(check_lab)


class Clock:
    def __init__(self):
        self.now = 0.0

    def __call__(self):
        return self.now

    def sleep(self, seconds):
        self.now += seconds


class FakeScreen:
    def __init__(self, machine):
        self.machine = machine

    def capture(self, path, step):
        self.machine.captures += 1
        if self.machine.captures > 50:
            # A loop with no deadline would hang the suite instead of failing it.
            raise AssertionError("the check kept capturing with no end in sight")
        path.write_bytes(self.machine.next_frame())


class FakeMachine:
    """Answers like a machine: frames, a pointer, and commands over SSH."""

    def __init__(self, check_dir, frames, pointer=(1280, 720)):
        self.check_dir = check_dir
        self.frames = list(frames)
        self.pointer = pointer
        self.screen = FakeScreen(self)
        self.ssh = self
        self.commands = []
        self.shots = []
        self.captures = 0

    def next_frame(self):
        return self.frames.pop(0) if len(self.frames) > 1 else self.frames[0]

    def screenshot(self, directory, step):
        self.shots.append(step)
        directory.mkdir(parents=True, exist_ok=True)
        path = directory / f"{len(self.shots):02d}-{step.replace(' ', '-')}.png"
        path.write_bytes(self.next_frame())
        return path

    def move_pointer(self, x, y, step):
        self.pointer = (x, y)

    def run(self, command, step, seconds=None, check=True):
        self.commands.append(command)


@pytest.fixture
def machine(tmp_path):
    return FakeMachine(tmp_path, [b"desktop", b"desktop", b"desktop", b"a window", b"a window"])


def instant(monkeypatch):
    """No real waiting in the check's own loops: only this module's clock moves."""
    clock = Clock()
    monkeypatch.setattr(check_lab, "time", type("time", (), {"sleep": staticmethod(clock.sleep), "monotonic": staticmethod(clock)}))
    return clock


def test_the_screen_check_opens_a_window_and_requires_the_frame_to_follow(machine, tmp_path, monkeypatch):
    monkeypatch.setattr(check_lab, "probes", type("probes", (), {"pointer": staticmethod(lambda m: m.pointer)}))
    instant(monkeypatch)
    check_lab.check_screen_and_pointer(machine, tmp_path)
    assert any("open -a Calculator" in c for c in machine.commands)
    assert any("to quit" in c for c in machine.commands)
    assert machine.shots == ["the desktop", "the pointer in the middle", "the window closed again"]
    assert not list(tmp_path.glob(".repaint-probe*"))


def test_a_pointer_that_lands_elsewhere_is_a_lab_error(machine, tmp_path, monkeypatch):
    monkeypatch.setattr(check_lab, "probes", type("probes", (), {"pointer": staticmethod(lambda m: (0, 0))}))
    instant(monkeypatch)
    with pytest.raises(LabError, match="the guest reports"):
        check_lab.check_screen_and_pointer(machine, tmp_path)
    # The window is not left open in the guest.
    assert "open -a Calculator" not in machine.commands


def test_a_screen_stuck_on_one_frame_is_a_lab_error_at_the_deadline(tmp_path):
    clock = Clock()
    stuck = FakeMachine(tmp_path, [b"the same frame"])
    with pytest.raises(LabError, match="the frame was the same"):
        check_lab.wait_for_the_screen_to_change(
            stuck, tmp_path, b"the same frame", seconds=20, sleep=clock.sleep, clock=clock
        )
    assert clock.now >= 20
    assert not list(tmp_path.glob(".repaint-probe*"))


def test_a_screen_that_never_follows_the_guest_fails_the_check(tmp_path, monkeypatch):
    """The whole point of opening a window: a server stuck on one frame must not pass."""
    stuck = FakeMachine(tmp_path, [b"the same frame"])
    monkeypatch.setattr(check_lab, "probes", type("probes", (), {"pointer": staticmethod(lambda m: m.pointer)}))
    instant(monkeypatch)
    with pytest.raises(LabError, match="the frame was the same"):
        check_lab.check_screen_and_pointer(stuck, tmp_path)
    # And the window it opened is closed again even so.
    assert any("to quit" in c for c in stuck.commands)
