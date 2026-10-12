"""`--target here`: refused on any machine but a GitHub-hosted runner, and a machine made of local things there."""

import json
import pwd
import os
import subprocess
from pathlib import Path

import pytest

from udeck_e2e import cli, config, here, plugin as lab_plugin
from udeck_e2e.errors import LabError, NotOnThisTarget

RUNNER = {"GITHUB_ACTIONS": "true", "RUNNER_ENVIRONMENT": "github-hosted"}


# --- The refusal -----------------------------------------------------------------------------


def test_a_github_hosted_runner_is_the_one_place_here_runs():
    assert here.refusal(RUNNER) is None
    assert here.refusal({**RUNNER, "HOME": "/Users/runner"}) is None


@pytest.mark.parametrize(
    "environ",
    [
        {},  # a person's Mac
        {"GITHUB_ACTIONS": "true"},  # half of it
        {"RUNNER_ENVIRONMENT": "github-hosted"},
        {"GITHUB_ACTIONS": "true", "RUNNER_ENVIRONMENT": "self-hosted"},  # somebody's own runner is somebody's Mac
        {"GITHUB_ACTIONS": "1", "RUNNER_ENVIRONMENT": "github-hosted"},
        {"GITHUB_ACTIONS": "TRUE", "RUNNER_ENVIRONMENT": "github-hosted"},
        {"GITHUB_ACTIONS": "true ", "RUNNER_ENVIRONMENT": "github-hosted"},
        {"CI": "true", "GITHUB_ACTIONS": "", "RUNNER_ENVIRONMENT": "github-hosted"},
    ],
)
def test_anywhere_else_here_is_refused_and_says_why(environ):
    refused = here.refusal(environ)
    assert refused is not None
    assert "GitHub-hosted runner" in refused and "never on a person's Mac" in refused
    assert "GITHUB_ACTIONS=" in refused and "RUNNER_ENVIRONMENT=" in refused


def test_the_command_line_refuses_here_before_it_does_anything(monkeypatch, capsys):
    """No plugin, no pre-flight, no lock: on a person's Mac the run ends at the refusal."""
    for name in here.RUNNER_VARIABLES:
        monkeypatch.delenv(name, raising=False)

    def never(*args, **kwargs):
        raise AssertionError("the lab went on past the refusal")

    monkeypatch.setattr(cli, "LabPlugin", never)
    monkeypatch.setattr(cli, "run_pytest", never)
    assert cli.main(["--target", "here", "plugins"]) == 2
    assert "never on a person's Mac" in capsys.readouterr().err
    assert cli.main(["--target", "here", "--list"]) == 2, "not even a listing"
    assert cli.main(["selfcheck", "--target", "here"]) == 2


@pytest.mark.parametrize("option", [["--vm", "per-group"], ["--jobs", "2"], ["--keep-on-failure"], ["--guest", "26"]])
def test_what_would_do_nothing_beside_here_is_refused_even_on_a_runner(monkeypatch, capsys, option):
    for name, value in RUNNER.items():
        monkeypatch.setenv(name, value)
    monkeypatch.setattr(cli, "run_pytest", lambda *a, **k: (_ for _ in ()).throw(AssertionError("ran")))
    assert cli.main(["--target", "here", *option]) == 2
    assert "does nothing with --target here" in capsys.readouterr().err


def test_bake_and_cleanup_take_no_target(capsys):
    assert cli.main(["bake", "--target", "here"]) == 2
    assert cli.main(["cleanup", "--target", "tart"]) == 2
    assert "--target does nothing with" in capsys.readouterr().err


@pytest.mark.parametrize("shard", ["0/3", "4/3", "x", "1/0"])
def test_a_shard_that_is_not_one_is_refused_before_anything_runs(monkeypatch, capsys, shard):
    monkeypatch.setattr(cli, "run_pytest", lambda *a, **k: (_ for _ in ()).throw(AssertionError("ran")))
    assert cli.main(["plugins", "--shard", shard]) == 2
    assert "--shard" in capsys.readouterr().err


def test_the_preflight_asks_the_refusal_again(tmp_path):
    """Nothing but the refusal decides whether this machine becomes the guest — the
    command line asked it, and the pre-flight asks it again from the environment."""
    notes = []
    assessment, about = lab_plugin.here_preflight(notes.append, None, tmp_path, environ={})
    assert [p.what for p in assessment.problems if "never on a person's Mac" in p.what]
    assessment, about = lab_plugin.here_preflight(notes.append, None, tmp_path, environ=dict(RUNNER))
    assert assessment.problems == [] and about["target"] == "here"


# --- Commands, as SSH would run them -------------------------------------------------------


def test_a_command_runs_through_zsh_with_the_environment_ssh_gives_one():
    asked = []

    def run(args, **kwargs):
        asked.append((args, kwargs))
        return subprocess.CompletedProcess(args, 0, "out\n", "")

    shell = here.Shell(lambda text: None, run=run, environ={"PATH": "/opt/homebrew/bin:/usr/bin", "TMPDIR": "/t/", "SECRET": "x"})
    assert shell.run("echo $HOME", "echoing").stdout == "out\n"
    (args, kwargs), = asked
    assert args == ["/bin/zsh", "-c", "echo $HOME"]
    me = pwd.getpwuid(os.getuid())
    assert kwargs["env"] == {
        "HOME": me.pw_dir, "USER": me.pw_name, "LOGNAME": me.pw_name, "SHELL": "/bin/zsh",
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TMPDIR": "/t/",
    }  # fmt: skip
    assert kwargs["stdin"] == subprocess.DEVNULL and kwargs["start_new_session"] is True and kwargs["cwd"] == me.pw_dir


def test_a_command_that_fails_is_said_as_ssh_said_it_and_ask_hands_the_code_back():
    def run(args, **kwargs):
        return subprocess.CompletedProcess(args, 3, "", "no such thing\n")

    shell = here.Shell(lambda text: None, run=run)
    with pytest.raises(LabError, match="exited 3: no such thing"):
        shell.run("false", "failing")
    assert shell.run("false", "failing", check=False).returncode == 3
    assert shell.ask("pgrep -x uDeck", "looking").returncode == 3

    def slow(args, **kwargs):
        raise subprocess.TimeoutExpired(args, kwargs["timeout"])

    with pytest.raises(LabError, match="did not finish in 5s"):
        here.Shell(lambda text: None, run=slow).run("sleep 9", "waiting", seconds=5)


def test_a_file_is_copied_where_a_check_would_have_copied_it_into_the_guest(tmp_path, monkeypatch):
    monkeypatch.setenv("HOME", str(tmp_path))
    source = tmp_path / "plugin-repository.tar.gz"
    source.write_bytes(b"tar")
    shell = here.Shell(lambda text: None)
    shell.copy_in(source, str(tmp_path / "copied.tar.gz"), "copying")
    assert (tmp_path / "copied.tar.gz").read_bytes() == b"tar"
    shell.copy_in(source, "~/home-copy.tar.gz", "copying")
    assert (tmp_path / "home-copy.tar.gz").read_bytes() == b"tar"
    with pytest.raises(LabError, match="copying plugin-repository.tar.gz"):
        shell.copy_in(source, str(tmp_path / "no" / "such" / "folder" / "x"), "copying")


# --- The machine -------------------------------------------------------------------------------


class Commands:
    """This runner's shell, answering by what was asked: the helper's JSON, the desktop, screencapture."""

    def __init__(self, screen=None, modes_refused=()):
        self.asked = []
        self.screen = screen or {"points": [1920, 1080], "pixels": [1920, 1080], "menuBar": 24, "visibleBottom": 1006}
        self.modes_refused = modes_refused
        self.host = "this machine"

    def run(self, command, step, seconds=None, check=True):
        self.asked.append(command)
        words = command.split()
        if words[0].endswith("/ax"):
            name = words[1]
            if name == "set-mode" and tuple(map(int, words[2:4])) in self.modes_refused:
                return subprocess.CompletedProcess(words, 1, "", "ax: the main display has no mode of that size")
            answers = {"trusted": {"trusted": True}, "screen": self.screen, "set-mode": self.screen}
            return subprocess.CompletedProcess(words, 0, json.dumps(answers.get(name, {"ok": True})), "")
        if command.startswith("stat -f %Su /dev/console"):
            return subprocess.CompletedProcess(words, 0, f"{pwd.getpwuid(os.getuid()).pw_name}\nfinder\n", "")
        if command.startswith("/usr/sbin/screencapture"):
            Path(words[-1].strip("'")).write_bytes(b"png")
        return subprocess.CompletedProcess(words, 0, "", "")

    def ask(self, command, step, seconds=None):
        return self.run(command, step, check=False)


def a_runner(tmp_path, **commands):
    return here.HereMachine(
        name="this runner", work_dir=tmp_path / "run", note=lambda text: None, helper=Path("/runner/ax"),
        shell=Commands(**commands), sleep=lambda s: None, clock=lambda: 0.0,
    )  # fmt: skip


@pytest.fixture
def restored_screen():
    """`config.use_screen` changes the lab's places for the rest of the process; put the guest's back."""
    before = config.places(config.GOLDEN_WIDTH, config.GOLDEN_HEIGHT, config.MENU_BAR, 1370)
    yield
    config.use_screen(config.GOLDEN_WIDTH, config.GOLDEN_HEIGHT, config.MENU_BAR, 1370)
    assert config.places(config.GOLDEN_WIDTH, config.GOLDEN_HEIGHT, config.MENU_BAR, 1370) == before


def test_the_runner_is_made_ready_as_the_bake_makes_a_guest_ready(tmp_path, restored_screen):
    machine = a_runner(tmp_path, modes_refused={(2560, 1440)})
    machine.create()
    machine.boot()
    asked = machine.ssh.asked
    assert asked[0].startswith("stat -f %Su /dev/console")
    assert "/runner/ax trusted" in asked
    # The guest's size first, and the largest the runner has when it has not that.
    assert asked.index("/runner/ax set-mode 2560 1440") < asked.index("/runner/ax set-mode 1920 1080")
    assert any("com.apple.notificationcenterui.agent" in a for a in asked), "notifications silenced"
    # And the places the panel checks aim at are this screen's.
    assert (machine.width, machine.height) == (1920, 1080)
    assert config.SCREEN_WIDTH == 1920 and config.STRIP_COLUMNS == (844, 1076)


def test_a_restart_is_not_on_this_target(tmp_path):
    with pytest.raises(NotOnThisTarget, match="a restart of the machine"):
        a_runner(tmp_path).reboot()


def test_the_pointer_and_the_keys_go_through_the_helper_and_never_off_the_screen(tmp_path):
    machine = a_runner(tmp_path)
    machine.width, machine.height = 1920, 1080
    machine.move_pointer(960, 5, "into the strip")
    machine.click(200, 906, "past the panel")
    machine.right_click(553, 48, "on the first tab")
    machine.key("esc", "on the keyboard")
    machine.scroll(884, 536, -675, "to the install button")
    assert machine.ssh.asked == [
        "/runner/ax move 960 5", "/runner/ax click 200 906", "/runner/ax right-click 553 48",
        "/runner/ax key esc", "/runner/ax scroll 884 536 -675",
    ]  # fmt: skip
    with pytest.raises(LabError, match=r"\(200, 1100\) is off the 1920×1080 screen"):
        machine.click(200, 1100, "past the panel")


def test_a_screenshot_is_numbered_as_the_guests_are(tmp_path):
    machine = a_runner(tmp_path)
    first = machine.screenshot(tmp_path / "check", "uDeck running")
    second = machine.screenshot(tmp_path / "check", "at the end")
    assert (first.name, second.name) == ("01-udeck-running.png", "02-at-the-end.png")
    assert machine.ssh.asked[0].startswith("/usr/sbin/screencapture -x -t png ")


def test_the_runners_own_user_owns_what_is_installed():
    assert a_runner(Path("/nonexistent")).user == pwd.getpwuid(os.getuid()).pw_name


def test_a_button_the_system_still_took_for_held_is_said_when_the_helper_lets_go_of_it(tmp_path):
    """One click on a runner left the left button held for every check after it (run 38227384436)."""
    notes = []
    machine = here.HereMachine(
        name="this runner", work_dir=tmp_path, note=notes.append, helper=Path("/runner/ax"), shell=Commands(),
        sleep=lambda s: None, clock=lambda: 0.0,
    )  # fmt: skip
    machine.width, machine.height = 1920, 1080
    machine.ssh.run = lambda command, step, seconds=None, check=True: subprocess.CompletedProcess(
        [], 0, json.dumps({"moved": [1, 2], "released": ["left"], "released again": 0}), ""
    )
    machine.move_pointer(960, 540, "to the middle")
    assert notes == ["   the left button was still held; let go of before moving the pointer to the middle"]
