"""The lab's reporting, run against small fake check files.

Each test writes a checks directory, runs a real pytest session over it with
the lab's plugin — the same arguments `e2e/run.sh` uses — and reads what a
person would read: the console lines, the exit code, the ledger.
"""

import io
import json
import os
from datetime import datetime, timezone
from pathlib import Path

import pytest

from udeck_e2e import config, preflight
from udeck_e2e.cli import E2E_DIR, pytest_args, run_pytest
from udeck_e2e.ledger import RunLock
from udeck_e2e.plugin import LabPlugin

REAL_INI = (E2E_DIR / "checks" / "pytest.ini").read_text()


class Lab:
    def __init__(self, pytester: pytest.Pytester):
        self.pytester = pytester
        self.checks = pytester.path / "checks"
        self.checks.mkdir()
        (self.checks / "pytest.ini").write_text(REAL_INI)
        self.runs = pytester.path / "runs"
        self.lock_path = pytester.path / "lock" / "lab.lock"
        self.problems: list[preflight.Problem] = []
        self.host_notes: list[str] = []
        self.preflights = 0

    def write(self, name: str, source: str) -> None:
        path = self.checks / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(source)

    def fake_preflight(self, guest, note):
        self.preflights += 1
        for text in self.host_notes:
            note(text)
        return preflight.Assessment(list(self.problems), []), {"host_macos": "27.0"}

    def plugin(self, *wanted: str, listing: bool = False, out: io.StringIO | None = None):
        return LabPlugin(
            wanted=list(wanted),
            listing=listing,
            guest=config.GUESTS["27"],
            repo_root=self.pytester.path,
            checks_dir=self.checks,
            runs_root=self.runs,
            lock_path=self.lock_path,
            stream=out,
            run_preflight=self.fake_preflight,
            now=lambda: datetime(2026, 9, 16, 12, 0, 0, tzinfo=timezone.utc),
        )

    def run(self, *wanted: str, listing: bool = False, out=None):
        out = out if out is not None else io.StringIO()
        plugin = self.plugin(*wanted, listing=listing, out=out)
        self.pytester.inline_run(
            *pytest_args(self.checks, listing), plugins=[plugin], no_reraise_ctrlc=True
        )
        if isinstance(out, io.TextIOWrapper):
            out.flush()
            return plugin.exit_code, out.buffer.getvalue().decode("utf-8")
        return plugin.exit_code, out.getvalue()

    def run_via_cli(self, *wanted: str):
        """Through cli.run_pytest, which maps whatever escapes pytest."""
        out = io.StringIO()
        plugin = self.plugin(*wanted, out=out)
        code = run_pytest(plugin, pytest_args(self.checks, False))
        return code, out.getvalue()

    def run_dirs(self) -> list[Path]:
        if not self.runs.exists():
            return []
        return sorted(p for p in self.runs.iterdir() if p.is_dir())

    def ledger(self) -> list[dict]:
        (run,) = self.run_dirs()
        return [json.loads(line) for line in (run / "ledger.jsonl").read_text().splitlines()]

    def ledger_checks(self) -> dict[str, dict]:
        return {e["name"]: e for e in self.ledger() if e["event"] == "check"}


@pytest.fixture
def lab(pytester):
    return Lab(pytester)


def test_listing_prints_names_in_definition_order_and_touches_nothing(lab):
    lab.write("check_updates.py", "def check_sparkle(): pass\ndef check_wrong_key(): pass\n")
    lab.write("check_panel.py", "def check_dwell(): pass\n")
    code, out = lab.run(listing=True)
    assert code == 0
    assert out.splitlines() == ["panel.dwell", "updates.sparkle", "updates.wrong-key"]
    assert lab.preflights == 0 and lab.run_dirs() == []


def test_a_passing_run_exits_0_and_leaves_a_ledger(lab):
    lab.write("check_updates.py", "def check_sparkle(): pass\n")
    code, out = lab.run()
    assert code == 0
    assert "✅ updates.sparkle" in out
    assert "1 passed in" in out
    events = [e["event"] for e in lab.ledger()]
    assert events == ["run-start", "preflight", "pruned", "check", "run-end"]
    assert lab.ledger_checks()["updates.sparkle"]["outcome"] == "passed"
    assert lab.ledger()[-1]["exit_code"] == 0


def test_expect_and_a_plain_assert_in_a_check_are_failures(lab):
    lab.write(
        "check_updates.py",
        "from udeck_e2e.errors import expect\n"
        "def check_sparkle():\n    expect(False, 'version on disk is still 0.4.1')\n"
        "def check_wrong_key():\n    assert 1 == 2, 'the update was installed'\n",
    )
    code, out = lab.run()
    assert code == 1
    assert "❌ updates.sparkle" in out and "version on disk is still 0.4.1" in out
    assert "❌ updates.wrong-key" in out and "the update was installed" in out
    checks = lab.ledger_checks()
    assert {checks[n]["outcome"] for n in checks} == {"failed"}
    (run,) = lab.run_dirs()
    assert "version on disk is still 0.4.1" in (run / "updates.sparkle" / "error.txt").read_text()


def test_an_assert_outside_a_check_file_is_the_lab_failing_not_udeck(lab):
    lab.write("helpers.py", "def wait_for_ssh():\n    assert False, 'helper gave up'\n")
    lab.write(
        "check_panel.py",
        "from helpers import wait_for_ssh\ndef check_dwell():\n    wait_for_ssh()\n",
    )
    code, out = lab.run()
    assert code == 2
    assert "⚠️ panel.dwell" in out and "could not check" in out
    assert lab.ledger_checks()["panel.dwell"]["outcome"] == "could-not-check"


def test_a_lab_error_names_its_step(lab):
    lab.write(
        "check_panel.py",
        "from udeck_e2e.errors import LabError\n"
        "def check_dwell():\n    raise LabError('waiting for SSH after the reboot', 'no answer in 240s')\n",
    )
    code, out = lab.run()
    assert code == 2
    assert "could not check: waiting for SSH after the reboot: no answer in 240s" in out


def test_any_other_exception_in_a_check_is_the_lab_failing(lab):
    lab.write("check_panel.py", "def check_dwell():\n    {}['missing']\n")
    code, out = lab.run()
    assert code == 2
    assert "the lab itself raised KeyError" in out


def test_a_fixture_that_cannot_prepare_is_could_not_check(lab):
    lab.write(
        "conftest.py",
        "import pytest\n@pytest.fixture\ndef vm():\n    raise RuntimeError('clone failed')\n",
    )
    lab.write("check_panel.py", "def check_dwell(vm):\n    pass\n")
    code, out = lab.run()
    assert code == 2
    assert "preparing the check raised RuntimeError" in out and "clone failed" in out


def test_a_skip_is_never_green(lab):
    lab.write("check_panel.py", "import pytest\ndef check_dwell():\n    pytest.skip('no display')\n")
    code, out = lab.run()
    assert code == 2
    assert "could not check: skipped: no display" in out


def test_a_failure_outranks_what_could_not_be_checked(lab):
    lab.write(
        "check_panel.py",
        "from udeck_e2e.errors import LabError, expect\n"
        "def check_dwell():\n    expect(False, 'panel stayed closed')\n"
        "def check_push():\n    raise LabError('moving the pointer', 'VNC refused')\n",
    )
    code, out = lab.run()
    assert code == 1
    assert "1 failed, 1 could not check" in out


def test_a_cleanup_failure_after_a_pass_keeps_the_pass_but_spoils_the_exit_code(lab):
    lab.write(
        "conftest.py",
        "import pytest\n@pytest.fixture\ndef vm():\n    yield\n    raise RuntimeError('clone would not delete')\n",
    )
    lab.write("check_panel.py", "def check_dwell(vm):\n    pass\n")
    code, out = lab.run()
    assert code == 2
    assert "✅ panel.dwell" in out
    assert "clone would not delete" in out
    assert lab.ledger()[-1]["lab_problems"]


def test_check_dir_is_the_checks_own_directory_in_the_run(lab):
    lab.write(
        "check_panel.py",
        "def check_dwell(check_dir):\n    (check_dir / 'step-1.png').write_bytes(b'png')\n",
    )
    code, _ = lab.run()
    (run,) = lab.run_dirs()
    assert code == 0
    assert (run / "panel.dwell" / "step-1.png").read_bytes() == b"png"


def test_selection_runs_only_what_was_asked_for(lab):
    lab.write("check_updates.py", "def check_sparkle():\n    raise SystemError('must not run')\n")
    lab.write("check_panel.py", "def check_dwell(): pass\ndef check_push(): pass\n")
    code, out = lab.run("panel")
    assert code == 0
    assert "updates.sparkle" not in out
    assert set(lab.ledger_checks()) == {"panel.dwell", "panel.push"}


def test_an_unknown_name_runs_nothing_and_lists_what_exists(lab):
    lab.write("check_panel.py", "def check_dwell(): pass\n")
    code, out = lab.run("panel.dwel")
    assert code == 2
    assert "no check or group called 'panel.dwel'" in out and "panel.dwell" in out
    assert lab.preflights == 0 and lab.run_dirs() == []


def test_a_badly_named_check_file_is_an_error_not_a_silent_skip(lab):
    lab.write("check_Panel.py", "def check_dwell(): pass\n")
    code, out = lab.run()
    assert code == 2
    assert "lowercase" in out


def test_a_check_file_that_does_not_import_is_an_error(lab):
    lab.write("check_panel.py", "def check_dwell(:\n")
    code, out = lab.run()
    assert code == 2
    assert "SyntaxError" in out
    assert lab.preflights == 0


def test_pre_flight_problems_stop_the_run_before_any_check(lab):
    marker = lab.pytester.path / "ran"
    lab.write("check_panel.py", f"def check_dwell():\n    open({str(marker)!r}, 'w').close()\n")
    lab.problems = [preflight.Problem("Tart is not installed.", "Install it.")]
    code, out = lab.run()
    assert code == 2
    assert "The lab cannot start" in out and "Install it." in out
    assert not marker.exists()
    ledger = lab.ledger()
    assert ledger[1]["problems"] == [{"what": "Tart is not installed.", "todo": "Install it."}]
    assert "check" not in [e["event"] for e in ledger]


def test_a_second_run_while_one_holds_the_lock_does_nothing(lab):
    lab.write("check_panel.py", "def check_dwell(): pass\n")
    holder = RunLock(lab.lock_path)
    assert holder.acquire() is None
    try:
        code, out = lab.run()
    finally:
        holder.release()
    assert code == 2
    assert f"pid {os.getpid()}" in out
    assert lab.preflights == 0


def test_ctrl_c_in_a_check_counts_it_and_the_rest_as_not_checked(lab):
    lab.write(
        "check_panel.py",
        "def check_dwell(): pass\n"
        "def check_push():\n    raise KeyboardInterrupt\n"
        "def check_mid_screen(): pass\n",
    )
    code, out = lab.run()
    assert code == 2
    assert "Interrupted." in out
    assert "1 passed, 2 could not check" in out
    assert "⚠️ panel.push" in out and "interrupted before it finished" in out
    assert "never started: panel.mid-screen" in out
    assert lab.ledger()[-1]["interrupted"] is True


def test_old_runs_beyond_the_limit_are_removed(lab):
    lab.write("check_panel.py", "def check_dwell(): pass\n")
    lab.runs.mkdir()
    for minute in range(config.KEEP_RUNS + 3):
        (lab.runs / f"20260915-10{minute:02d}00Z").mkdir()
        (lab.runs / f"20260915-10{minute:02d}00Z" / ".checks-started").touch()
    lab.run()
    runs = sorted(p.name for p in lab.runs.iterdir() if p.is_dir())
    assert len(runs) == config.KEEP_RUNS
    assert runs[-1] == "20260916-120000Z"


# --- Found by the review of the first version ---------------------------------


def test_a_file_that_skips_itself_is_an_error_not_a_missing_group(lab):
    lab.write(
        "check_updates.py",
        "import pytest\npytest.skip('no feed yet', allow_module_level=True)\ndef check_sparkle(): pass\n",
    )
    lab.write("check_panel.py", "def check_dwell(): pass\n")
    code, out = lab.run()
    assert code == 2 and "skipped itself" in out and "no feed yet" in out
    listed, out = lab.run(listing=True)
    assert listed == 2


def test_a_check_file_in_a_subdirectory_is_refused(lab):
    lab.write("updates/check_sparkle.py", "def check_installs():\n    assert False\n")
    code, out = lab.run()
    assert code == 2
    assert "not in a subdirectory" in out


def test_an_exception_in_a_thread_the_check_started_is_never_green(lab):
    lab.write(
        "check_panel.py",
        "import threading\n"
        "def check_dwell():\n"
        "    t = threading.Thread(target=lambda: 1 / 0)\n    t.start()\n    t.join()\n",
    )
    code, out = lab.run()
    assert code == 2
    assert "⚠️ panel.dwell" in out


def test_a_failure_message_that_is_not_utf8_is_still_reported(lab):
    lab.write(
        "check_panel.py",
        "from udeck_e2e.errors import expect\n"
        "def check_dwell():\n    expect(False, 'guest said \\udcff')\n"
        "def check_push(): pass\n",
    )
    # A console that really encodes, as a terminal does; StringIO would accept anything.
    console = io.TextIOWrapper(io.BytesIO(), encoding="utf-8")
    code, out = lab.run(out=console)
    assert code == 1
    assert "❌ panel.dwell" in out and "✅ panel.push" in out
    (run,) = lab.run_dirs()
    assert "udcff" in (run / "panel.dwell" / "error.txt").read_text()


def test_host_notes_from_the_pre_flight_reach_the_console_and_the_ledger(lab):
    lab.write("check_panel.py", "def check_dwell(): pass\n")
    lab.host_notes = ["Stopping the orphaned 'tart run udeck-e2e-x' (pid 7) with SIGTERM."]
    code, out = lab.run()
    assert "Stopping the orphaned" in out
    assert any(e["event"] == "host" and "pid 7" in e["text"] for e in lab.ledger())


def test_ctrl_c_during_cleanup_keeps_the_verdict_already_reached(lab):
    lab.write(
        "conftest.py",
        "import pytest\n@pytest.fixture\ndef vm():\n    yield\n    raise KeyboardInterrupt\n",
    )
    lab.write(
        "check_panel.py",
        "from udeck_e2e.errors import expect\n"
        "def check_dwell(vm):\n    expect(False, 'panel stayed closed')\n",
    )
    code, out = lab.run()
    assert code == 1
    assert "❌ panel.dwell" in out and "panel stayed closed" in out
    (run,) = lab.run_dirs()
    assert (run / "panel.dwell" / "error.txt").exists()
    assert lab.ledger_checks()["panel.dwell"]["outcome"] == "failed"


def test_ctrl_c_during_cleanup_of_a_passing_check_keeps_the_pass_and_spoils_the_exit(lab):
    lab.write(
        "conftest.py",
        "import pytest\n@pytest.fixture\ndef vm():\n    yield\n    raise KeyboardInterrupt\n",
    )
    lab.write("check_panel.py", "def check_dwell(vm): pass\n")
    code, out = lab.run()
    assert code == 2
    assert "✅ panel.dwell" in out and "interrupted while cleaning up" in out


def test_after_ctrl_c_the_lock_is_held_until_fixtures_are_torn_down_and_their_errors_count(lab):
    witness = lab.pytester.path / "lock-during-teardown"
    lab.write(
        "conftest.py",
        "import pytest\n"
        "from udeck_e2e.ledger import RunLock\n"
        "@pytest.fixture\ndef vm():\n    yield\n"
        f"    other = RunLock(__import__('pathlib').Path({str(lab.lock_path)!r}))\n"
        f"    open({str(witness)!r}, 'w').write('free' if other.acquire() is None else 'held')\n"
        "    other.release()\n"
        "    raise RuntimeError('clone would not delete')\n",
    )
    lab.write("check_panel.py", "def check_dwell(vm):\n    raise KeyboardInterrupt\n")
    code, out = lab.run_via_cli()
    assert witness.read_text() == "held"
    assert code == 2
    assert "clone would not delete" in out
    assert any("clone would not delete" in p for p in lab.ledger()[-1]["lab_problems"])


def test_a_ledger_that_cannot_be_written_never_lets_the_run_exit_0(lab, monkeypatch):
    lab.write("check_panel.py", "def check_dwell(): pass\n")

    def full(fd):
        raise OSError(28, "No space left on device")

    monkeypatch.setattr(os, "fsync", full)
    code, out = lab.run_via_cli()
    assert code == 2
    assert "✅ panel.dwell" in out


def test_an_exception_escaping_pytest_after_a_failure_exits_1_and_otherwise_2(lab, monkeypatch):
    lab.write(
        "check_panel.py",
        "from udeck_e2e.errors import expect\n"
        "def check_dwell():\n    expect(False, 'panel stayed closed')\n",
    )
    plugin = lab.plugin(out=io.StringIO())
    original = plugin._finish_run

    def broken(teardown_error):
        original(teardown_error)
        raise RuntimeError("bug in the lab")

    monkeypatch.setattr(plugin, "_finish_run", broken)
    assert run_pytest(plugin, pytest_args(lab.checks, False)) == 1


def test_a_run_refused_by_the_pre_flight_does_not_count_against_real_runs(lab):
    lab.write("check_panel.py", "def check_dwell(): pass\n")
    lab.runs.mkdir()
    real = lab.runs / "20260915-090000Z"
    real.mkdir()
    (real / ".checks-started").touch()
    (real / "evidence.txt").write_text("keep")
    lab.problems = [preflight.Problem("A foreign VM is running.", "Stop it.")]
    for minute in range(config.KEEP_RUNS + 2):
        plugin = lab.plugin(out=io.StringIO())
        plugin.now = lambda minute=minute: datetime(2026, 9, 16, 12, minute, tzinfo=timezone.utc)
        lab.pytester.inline_run(*pytest_args(lab.checks, False), plugins=[plugin])
    lab.problems = []
    lab.run()
    assert (real / "evidence.txt").read_text() == "keep"


def test_git_state_does_not_touch_the_index(pytester):
    import subprocess

    from udeck_e2e.plugin import _git_state

    repo = pytester.path / "repo"
    repo.mkdir()
    git = ["git", "-C", str(repo), "-c", "user.email=a@b", "-c", "user.name=a"]
    subprocess.run([*git, "init", "-q"], check=True)
    (repo / "f").write_text("1")
    subprocess.run([*git, "add", "f"], check=True)
    subprocess.run([*git, "commit", "-qm", "x"], check=True)
    os.utime(repo / "f", (1, 1))  # makes a plain `git status` want to refresh the index
    before = (repo / ".git" / "index").stat().st_mtime_ns
    state = _git_state(repo)
    assert state["commit"]
    assert (repo / ".git" / "index").stat().st_mtime_ns == before


def test_without_an_explicit_lock_the_plugin_uses_the_host_wide_lock(lab):
    from udeck_e2e.ledger import host_lock_path

    plugin = LabPlugin(
        wanted=[], listing=True, guest=config.GUESTS["27"], repo_root=lab.pytester.path,
        checks_dir=lab.checks, runs_root=lab.runs,
    )
    assert plugin.lock.path == host_lock_path()


def test_run_sh_works_with_cdpath_exported(tmp_path):
    import subprocess

    env = {**os.environ, "CDPATH": f".:{tmp_path}"}
    env.pop("UV_PROJECT_ENVIRONMENT", None)
    done = subprocess.run(
        # Relative, as a person types it: CDPATH is only searched for relative paths.
        ["/bin/bash", "e2e/run.sh", "--list"],
        cwd=E2E_DIR.parent, env=env, capture_output=True, text=True, timeout=120,
    )
    assert done.returncode == 0, done.stderr
