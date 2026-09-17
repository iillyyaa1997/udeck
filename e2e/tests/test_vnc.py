"""The screen and the pointer over VNC, against a fake client process."""

import json
import os
import socket
import subprocess
import sys
from pathlib import Path

import pytest
from PIL import Image

from udeck_e2e import probes, vnc_client
from udeck_e2e.errors import LabError
from udeck_e2e.vnc import (
    PASSWORD_VARIABLE,
    SERVER_VARIABLE,
    Address,
    Frame,
    Screen,
    find_address,
)

PASSWORD = "anchor-basket-cider-dune"
LOOPBACK = Address("127.0.0.1", 62979, PASSWORD)


def done(args, rc=0, out="", err=""):
    return subprocess.CompletedProcess(args, rc, out, err)


class Clock:
    def __init__(self):
        self.now = 0.0

    def __call__(self):
        return self.now

    def sleep(self, seconds):
        self.now += seconds


def frame_json(width=2560, height=1440, blank=False):
    return json.dumps({"width": width, "height": height, "blank": blank})


class Client:
    """Stands in for `python -m udeck_e2e.vnc_client`: answers in order, records the calls."""

    def __init__(self, *answers):
        self.answers = list(answers)
        self.calls = []

    def __call__(self, args, **kwargs):
        self.calls.append((args, kwargs))
        answer = self.answers.pop(0) if len(self.answers) > 1 else self.answers[0]
        if isinstance(answer, BaseException):
            raise answer
        rc, out, err = answer
        if args[-2] == "capture":
            Path(args[-1]).write_bytes(b"\x89PNG partial")
        return done(args, rc, out, err)


def screen(client, clock=None):
    clock = clock or Clock()
    return Screen(LOOPBACK, python=Path("/venv/bin/python"), run=client, sleep=clock.sleep, clock=clock)


# --- The address ---------------------------------------------------------------------


def test_the_address_is_read_from_tarts_own_line():
    log = f"VNC server is running at vnc://:{PASSWORD}@127.0.0.1:62979\n"
    assert find_address(log) == LOOPBACK


def test_the_last_address_counts_and_a_log_without_one_has_none():
    log = (
        f"VNC server is running at vnc://:{PASSWORD}@127.0.0.1:62979\n"
        "Error: The number of VMs exceeds the system limit\n"
        "VNC server is running at vnc://:other-words-here-now@127.0.0.1:62990\n"
    )
    assert find_address(log).port == 62990
    assert find_address("guest has stopped the virtual machine\n") is None


def test_the_password_never_shows_in_what_the_lab_prints():
    assert PASSWORD not in repr(LOOPBACK) and PASSWORD not in str(LOOPBACK)


def test_a_screen_on_any_address_but_loopback_is_refused():
    with pytest.raises(LabError, match="127.0.0.1 only"):
        Screen(Address("192.168.100.127", 62979, PASSWORD))


# --- One action, one process ----------------------------------------------------------


def test_the_password_travels_in_the_environment_never_on_the_command_line():
    client = Client((0, "", ""))
    screen(client).move(1280, 0, "to the top edge")
    args, kwargs = client.calls[0]
    assert args == ["/venv/bin/python", "-m", "udeck_e2e.vnc_client", "move", "1280", "0"]
    assert not any(PASSWORD in a for a in args)
    assert kwargs["env"][PASSWORD_VARIABLE] == PASSWORD
    assert kwargs["env"][SERVER_VARIABLE] == "127.0.0.1::62979"
    assert kwargs["timeout"] > 0
    assert kwargs["start_new_session"] is True and kwargs["stdin"] is subprocess.DEVNULL


def test_a_capture_lands_at_its_path_only_when_it_completed(tmp_path):
    good = screen(Client((0, frame_json(), "")))
    assert good.capture(tmp_path / "01-desktop.png", "taking") == Frame(2560, 1440, False)
    assert [p.name for p in tmp_path.iterdir()] == ["01-desktop.png"]

    bad = screen(Client((1, "", "TimeoutError: Timeout while waiting for client response")))
    with pytest.raises(LabError, match="capture failed: TimeoutError"):
        bad.capture(tmp_path / "02-after.png", "taking")
    assert [p.name for p in tmp_path.iterdir()] == ["01-desktop.png"]


def test_a_vnc_action_that_hangs_is_a_lab_error_at_its_deadline():
    hangs = Client(subprocess.TimeoutExpired(["python"], 30))
    with pytest.raises(LabError, match="did not finish in 30s"):
        screen(hangs).move(1, 1, "moving")


def test_an_answer_the_lab_cannot_read_is_a_lab_error(tmp_path):
    with pytest.raises(LabError, match="the VNC client answered"):
        screen(Client((0, "saved", ""))).capture(tmp_path / "x.png", "taking")
    assert list(tmp_path.iterdir()) == []


def test_waiting_for_the_screen_passes_over_blank_small_and_failed_frames(tmp_path):
    clock = Clock()
    client = Client(
        (0, frame_json(1280, 720, blank=True), ""),
        (1, "", "ConnectionRefusedError: Connection was refused"),
        (0, frame_json(blank=True), ""),
        (0, frame_json(1024, 768), ""),
        (0, frame_json(), ""),
    )
    frame = screen(client, clock).wait_for_screen(tmp_path / ".probe.png", "waiting")
    assert frame == Frame(2560, 1440, False)
    assert len(client.calls) == 5 and clock.now == 4
    assert list(tmp_path.iterdir()) == []


def test_a_screen_that_never_shows_a_real_frame_gives_up_saying_what_it_last_saw(tmp_path):
    clock = Clock()
    with pytest.raises(LabError, match="every pixel the same colour"):
        screen(Client((0, frame_json(blank=True), "")), clock).wait_for_screen(
            tmp_path / ".probe.png", "waiting", seconds=10
        )
    assert clock.now >= 10


def test_waiting_for_the_screen_stops_at_once_when_the_machine_has_gone(tmp_path):
    client = Client((0, frame_json(blank=True), ""))

    def gone(step):
        raise LabError(step, "the machine stopped: 'tart run' was killed by SIGTRAP")

    with pytest.raises(LabError, match="SIGTRAP"):
        screen(client).wait_for_screen(tmp_path / ".probe.png", "waiting", alive=gone)
    assert client.calls == []


# --- The client process -----------------------------------------------------------------


def test_the_client_knows_a_blank_frame_from_a_real_one(tmp_path):
    Image.new("RGB", (1280, 720), (0, 0, 0)).save(tmp_path / "black.png")
    real = Image.new("RGB", (2560, 1440), (142, 124, 116))
    real.putpixel((2559, 0), (255, 255, 255))
    real.save(tmp_path / "real.png")
    assert vnc_client.frame_of(tmp_path / "black.png") == {"width": 1280, "height": 720, "blank": True}
    assert vnc_client.frame_of(tmp_path / "real.png") == {"width": 2560, "height": 1440, "blank": False}


def test_the_client_takes_exactly_one_action():
    assert vnc_client.parse_action(["move", "1280", "0"]) == ("move", ["1280", "0"])
    assert vnc_client.parse_action(["capture", "/r/01.png"]) == ("capture", ["/r/01.png"])
    for wrong in ([], ["move", "-1", "0"], ["move", "1"], ["capture"], ["capture", "a", "b"], ["click", "1"]):
        assert vnc_client.parse_action(wrong) is None


def test_the_client_started_without_its_server_refuses_with_2(monkeypatch):
    monkeypatch.delenv(SERVER_VARIABLE, raising=False)
    monkeypatch.delenv(PASSWORD_VARIABLE, raising=False)
    assert vnc_client.main(["move", "1", "1"]) == 2


def test_the_client_says_why_it_could_not_connect_and_exits_1():
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        port = probe.getsockname()[1]
    # Nothing listens on the port now. A process of its own: Twisted's reactor
    # cannot be started twice in one.
    result = subprocess.run(
        [sys.executable, "-m", "udeck_e2e.vnc_client", "move", "1", "1"],
        env={**os.environ, SERVER_VARIABLE: f"127.0.0.1::{port}", PASSWORD_VARIABLE: "x"},
        capture_output=True,
        text=True,
        timeout=60,
    )
    assert result.returncode == 1
    assert result.stderr.strip().splitlines()[-1].startswith("ConnectionRefusedError")


# --- Where the pointer is ------------------------------------------------------------------


class ExecOnly:
    def __init__(self, answer):
        self.name = "udeck-e2e-x"
        self.tart = self
        self.answer = answer

    def exec(self, name, argv, step, seconds):
        return done(argv, 0, self.answer)


def test_the_pointer_is_read_back_in_pixels_from_the_top_left_corner():
    # What AppKit said after VNC moved the pointer to (1280, 1) on a 1440-high screen.
    at = ExecOnly(json.dumps({"x": 1279.99609375, "y": 1439.01171875, "height": 1440}))
    assert probes.pointer(at) == (1280, 1)
    at = ExecOnly(json.dumps({"x": 2558.98046875, "y": 1.01171875, "height": 1440}))
    assert probes.pointer(at) == (2559, 1439)
    with pytest.raises(LabError, match="unexpected answer"):
        probes.pointer(ExecOnly("execution error: -1743"))
