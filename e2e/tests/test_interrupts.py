"""Stopping the lab: Ctrl-C, a closed terminal, `kill` — and the command line."""

import os
import signal
import subprocess

import pytest

from udeck_e2e import cli, interrupts
from udeck_e2e.cli import E2E_DIR


@pytest.fixture(autouse=True)
def restore_handlers():
    saved = {s: signal.getsignal(s) for s in (signal.SIGINT, signal.SIGHUP, signal.SIGTERM)}
    yield
    for s, handler in saved.items():
        signal.signal(s, handler)


def test_a_press_during_a_deferred_block_finishes_the_block_then_stops():
    notes, finished = [], []
    with pytest.raises(KeyboardInterrupt):
        with interrupts.deferred(notes.append, "cleaning up"):
            os.kill(os.getpid(), signal.SIGINT)
            finished.append(True)
    assert finished == [True]
    assert len(notes) == 1 and "stopping once cleaning up is done" in notes[0]


def test_a_block_nobody_interrupted_does_not_stop_anything():
    with interrupts.deferred(print, "cleaning up"):
        pass
    assert signal.getsignal(signal.SIGINT) is signal.default_int_handler


def test_only_the_outermost_block_stops_so_an_inner_one_cannot_cut_the_outer_short():
    steps = []
    with pytest.raises(KeyboardInterrupt):
        with interrupts.deferred(print, "cleaning up"):
            with interrupts.deferred(print, "'tart delete'"):
                os.kill(os.getpid(), signal.SIGINT)
            steps.append("after the inner block")
    assert steps == ["after the inner block"]


def test_pressing_again_and_again_abandons_the_block():
    steps = []
    with pytest.raises(KeyboardInterrupt):
        with interrupts.deferred(print, "cleaning up"):
            for _ in range(interrupts.ABANDON_CLEANUP_AFTER):
                os.kill(os.getpid(), signal.SIGINT)
            steps.append("never reached")
    assert steps == []


@pytest.mark.parametrize("sig", [signal.SIGHUP, signal.SIGTERM])
def test_closing_the_terminal_or_kill_stops_the_lab_like_ctrl_c(sig):
    interrupts.stop_on_hangup_and_terminate()
    with pytest.raises(KeyboardInterrupt):
        os.kill(os.getpid(), sig)
        for _ in range(1000):  # the handler runs between bytecodes
            pass


@pytest.mark.parametrize("sig", [signal.SIGHUP, signal.SIGTERM])
def test_closing_the_terminal_during_a_cleanup_is_deferred_like_ctrl_c(sig):
    interrupts.stop_on_hangup_and_terminate()
    steps = []
    with pytest.raises(KeyboardInterrupt):
        with interrupts.deferred(print, "cleaning up"):
            os.kill(os.getpid(), sig)
            steps.append("finished")
    assert steps == ["finished"]


# --- The command line ----------------------------------------------------------------


@pytest.mark.parametrize(
    "argv",
    [
        ["cleanup", "--keep-on-failure"],
        ["cleanup", "--vm", "per-run"],
        ["bake", "--vm", "per-run"],
        ["bake", "--keep-on-failure"],
        ["--golden"],
        ["panel", "--golden"],
        ["bake", "selfcheck"],
        ["bake", "--jobs", "2"],
        ["cleanup", "--jobs", "2"],
        # Nothing follows the one machine of a whole run, so there is nothing to
        # start ahead of it — and an option that would do nothing is refused.
        ["--jobs", "2", "--vm", "per-run"],
    ],
)
def test_an_option_a_command_would_ignore_is_refused(argv, capsys, monkeypatch):
    # If the refusal ever breaks, this test must not start a real bake or a real
    # cleanup on the Mac running it — which is exactly what it once did.
    def must_not_run(*args, **kwargs):
        raise AssertionError("the command ran although its options should have been refused")

    monkeypatch.setattr(cli, "run_cleanup", must_not_run)
    monkeypatch.setattr(cli, "run_pytest", must_not_run)
    monkeypatch.setattr(interrupts, "stop_on_hangup_and_terminate", lambda: None)
    assert cli.main(argv) == 2
    assert capsys.readouterr().err


def test_cleanup_list_and_guest_reach_the_cleanup(monkeypatch):
    seen = {}

    def fake_run_cleanup(include_golden, guests, dry_run):
        seen.update(golden=include_golden, guests=[g.key for g in guests], dry_run=dry_run)
        return 0

    monkeypatch.setattr(cli, "run_cleanup", fake_run_cleanup)
    monkeypatch.setattr(interrupts, "stop_on_hangup_and_terminate", lambda: None)
    assert cli.main(["cleanup", "--golden", "--guest", "26", "--list"]) == 0
    assert seen == {"golden": True, "guests": ["26"], "dry_run": True}
    assert cli.main(["cleanup"]) == 0
    assert sorted(seen["guests"]) == ["26", "27"] and seen["dry_run"] is False


def test_run_sh_exits_2_not_1_when_uv_cannot_prepare_the_environment(tmp_path):
    fake = tmp_path / "bin"
    fake.mkdir()
    (fake / "uv").write_text("#!/bin/bash\necho 'Failed to download pygments' >&2\nexit 1\n")
    (fake / "uv").chmod(0o755)
    env = {**os.environ, "PATH": f"{fake}:/usr/bin:/bin"}
    done = subprocess.run(
        ["/bin/bash", "e2e/run.sh", "--list"], cwd=E2E_DIR.parent, env=env, capture_output=True, text=True, timeout=60
    )
    assert done.returncode == 2
    assert "could not prepare" in done.stderr


def test_the_command_line_makes_a_closed_terminal_stop_the_lab_like_ctrl_c(monkeypatch):
    monkeypatch.setattr(cli, "run_cleanup", lambda *a, **k: 0)
    signal.signal(signal.SIGTERM, signal.SIG_DFL)
    signal.signal(signal.SIGHUP, signal.SIG_DFL)
    cli.main(["cleanup", "--list"])
    assert callable(signal.getsignal(signal.SIGTERM)) and callable(signal.getsignal(signal.SIGHUP))


def test_jobs_reaches_the_run_and_one_is_the_default(monkeypatch):
    seen = {}

    def fake_run_pytest(plugin, args):
        seen["jobs"] = plugin.jobs
        return 0

    monkeypatch.setattr(cli, "run_pytest", fake_run_pytest)
    monkeypatch.setattr(interrupts, "stop_on_hangup_and_terminate", lambda: None)
    assert cli.main(["--jobs", "2"]) == 0
    assert seen == {"jobs": 2}
    assert cli.main([]) == 0
    assert seen == {"jobs": 1}
