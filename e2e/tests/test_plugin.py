"""The lab's reporting, run against small fake check files.

Each test writes a checks directory, runs a real pytest session over it with
the lab's plugin — the same arguments `e2e/run.sh` uses — and reads what a
person would read: the console lines, the exit code, the ledger.
"""

import io
import json
import re
import threading
import os
import time
from datetime import datetime, timezone
from pathlib import Path
from types import SimpleNamespace

import pytest

from udeck_e2e import config, golden, preflight
from udeck_e2e.errors import LabError
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
        # How many machines the pre-flight was told to size the host for.
        self.preflight_jobs: list[int] = []
        self.state_dir = pytester.path / "state"
        self.vms = [config.GUESTS["27"].golden_vm]
        golden.write(config.GUESTS["27"], "26A5416b", self.state_dir)
        self.machines: list[FakeMachine] = []
        # Everything every machine did, in one order, so a test can say what
        # overlapped with what. The checks write into it too (they are handed a
        # FakeMachine, which knows its lab).
        self.timeline: list[str] = []
        # Which label's boot should fail, for the machines started ahead.
        self.boot_fails_for: str | None = None
        # And which label's boot is parked until `release` is set, so a test can
        # make the next check arrive while the machine is still coming up.
        self.hold_boot_for: str | None = None
        self.release = threading.Event()
        self.slept = "{ sec = 0, usec = 0 }"
        self.mode = "checks"

    def write(self, name: str, source: str) -> None:
        path = self.checks / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(source)

    def fake_preflight(self, guest, note, jobs=1):
        self.preflights += 1
        self.preflight_jobs.append(jobs)
        for text in self.host_notes:
            note(text)
        return preflight.Assessment(list(self.problems), []), {"host_macos": "27.0", "vms": self.vms}

    def wait_for(self, event, seconds=10):
        """Block until `event` is in the timeline — the only honest way to assert
        that something happened on another thread."""
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            if event in self.timeline:
                return True
            time.sleep(0.01)
        raise AssertionError(f"{event!r} never happened; timeline: {self.timeline}")

    def wait_until_warmed(self, label, seconds=10):
        """Block until the thread warming `label` has ended — not only logged its boot.

        The boot is in the timeline a moment before that thread says the machine
        is up, and a check that ends in that moment hands the next one a machine
        still warming, which it then waits for: under load, "up in 40s, waited 20s
        for it" (2026-10-05)."""
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            if not any(thread.name == f"warming-{label}" and thread.is_alive() for thread in threading.enumerate()):
                return True
            time.sleep(0.01)
        raise AssertionError(f"the machine for {label!r} was still warming after {seconds}s")

    def factory(self, **kwargs):
        machine = FakeMachine(self, **kwargs)
        self.machines.append(machine)
        return machine

    def plugin(self, *wanted: str, listing: bool = False, out: io.StringIO | None = None, **options):
        return LabPlugin(
            wanted=list(wanted),
            listing=listing,
            guest=config.GUESTS["27"],
            mode=self.mode,
            machine_factory=self.factory,
            state_dir=self.state_dir,
            slept_at=lambda: self.slept,
            **options,
            repo_root=self.pytester.path,
            checks_dir=self.checks,
            runs_root=self.runs,
            lock_path=self.lock_path,
            stream=out,
            run_preflight=self.fake_preflight,
            now=lambda: datetime(2026, 9, 16, 12, 0, 0, tzinfo=timezone.utc),
        )

    def run(self, *wanted: str, listing: bool = False, out=None, **options):
        out = out if out is not None else io.StringIO()
        plugin = self.plugin(*wanted, listing=listing, out=out, **options)
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


class FakeMachine:
    """Stands in for a Machine: records what the fixture asked of it."""

    def __init__(self, lab, *, name, source, display, label):
        self.lab, self.name, self.source, self.display, self.label = lab, name, source, display, label
        self.events = []
        self.slept_at = ""

    def create(self):
        self.events.append("create")
        self.lab.timeline.append(f"{self.label} create")
        if "create" in getattr(self.lab, "break_machine", ()):
            raise LabError(f"cloning {self.name}", "disk full")

    def boot(self):
        self.events.append("boot")
        if self.lab.hold_boot_for == self.label:
            self.lab.release.wait(10)
        if self.lab.boot_fails_for == self.label:
            # Once: the point of the test that uses this is that the check's own
            # attempt afterwards is an ordinary one that works.
            self.lab.boot_fails_for = None
            self.lab.timeline.append(f"{self.label} boot failed")
            raise LabError(f"starting {self.name}", "the desktop never came up")
        self.lab.timeline.append(f"{self.label} boot")

    def close(self, keep):
        self.events.append(f"close keep={keep}")
        self.lab.timeline.append(f"{self.label} close")
        return list(getattr(self.lab, "close_problems", []))

    def screenshot(self, directory, step):
        self.events.append(f"screenshot {step}")
        if "screenshot" in getattr(self.lab, "break_machine", ()):
            raise LabError(f"taking the screenshot '{step}'", "the VNC capture failed: ConnectionRefusedError")
        directory.mkdir(parents=True, exist_ok=True)
        path = directory / f"01-{step.replace(' ', '-')}.png"
        path.write_bytes(b"png")
        return path


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
    assert "✅ panel.dwell" in out and "stopped while this check's machine was being cleaned up" in out
    assert lab.ledger_checks()["panel.dwell"]["stopped_in_cleanup"] is True


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


# --- Machines -------------------------------------------------------------------------

THREE_CHECKS = (
    "check_panel.py",
    "def check_dwell(machine): pass\n"
    "def check_push(machine):\n    assert False, 'panel stayed closed'\n",
    "check_updates.py",
    "def check_sparkle(machine): pass\n",
)


def write_three(lab):
    lab.write(THREE_CHECKS[0], THREE_CHECKS[1])
    lab.write(THREE_CHECKS[2], THREE_CHECKS[3])


def labels(lab):
    return [m.label for m in lab.machines]


def test_per_check_gives_every_check_its_own_machine(lab):
    write_three(lab)
    lab.run(vm_mode="per-check")
    assert labels(lab) == ["panel.dwell", "panel.push", "updates.sparkle"]
    assert all(m.events[:2] == ["create", "boot"] for m in lab.machines)
    assert all(m.source == config.GUESTS["27"].golden_vm for m in lab.machines)


def test_per_group_gives_every_file_one_machine(lab):
    write_three(lab)
    lab.run(vm_mode="per-group")
    assert labels(lab) == ["panel", "updates"]


def test_per_run_gives_the_whole_run_one_machine(lab):
    write_three(lab)
    lab.run(vm_mode="per-run")
    assert labels(lab) == ["run"]


def test_machines_are_named_after_the_run_so_the_pre_flight_knows_whose_they_are(lab):
    write_three(lab)
    lab.run("updates")
    (machine,) = lab.machines
    assert machine.name == "udeck-e2e-20260916-120000Z-updates.sparkle"


@pytest.mark.parametrize(
    "mode, kept",
    [
        ("per-check", {"panel.push"}),
        ("per-group", {"panel"}),
        ("per-run", {"run"}),
    ],
)
def test_keep_on_failure_keeps_only_the_machine_that_saw_a_failure(lab, mode, kept):
    write_three(lab)
    lab.run(vm_mode=mode, keep_on_failure=True)
    assert {m.label for m in lab.machines if "close keep=True" in m.events} == kept
    assert all(m.events[-1].startswith("close") for m in lab.machines)


def test_without_keep_on_failure_every_machine_goes(lab):
    write_three(lab)
    lab.run()
    assert all(m.events[-1] == "close keep=False" for m in lab.machines)


def test_a_machine_that_cannot_be_made_is_closed_and_the_check_could_not_be_checked(lab):
    lab.write("check_panel.py", "def check_dwell(machine): pass\n")
    lab.break_machine = {"create"}
    code, out = lab.run()
    assert code == 2
    assert "could not check" in out and "disk full" in out
    assert lab.machines[0].events == ["create", "close keep=False"]


def test_a_machine_that_cannot_be_cleaned_up_spoils_the_run(lab):
    lab.write("check_panel.py", "def check_dwell(machine): pass\n")
    lab.close_problems = ["did not shut down from inside within 60s"]
    code, out = lab.run()
    assert code == 2
    assert "✅ panel.dwell" in out and "did not shut down" in out


def test_checks_are_refused_without_a_golden_image_and_the_bake_is_not(lab):
    lab.write("check_panel.py", "def check_dwell(machine): pass\n")
    lab.vms = []
    code, out = lab.run()
    assert code == 2
    assert "no golden image for macOS 27" in out and "e2e/run.sh bake --guest 27" in out
    assert lab.machines == []

    lab.mode = "bake"
    code, out = lab.run()
    assert "golden image" not in out


def test_a_golden_image_baked_from_another_base_is_refused(lab):
    import json

    path = golden.metadata_path(config.GUESTS["27"], lab.state_dir)
    record = json.loads(path.read_text())
    record["base_image"] = "ghcr.io/cirruslabs/macos-golden-gate-base@sha256:0000"
    path.write_text(json.dumps(record))
    lab.write("check_panel.py", "def check_dwell(machine): pass\n")
    code, out = lab.run()
    assert code == 2 and "Bake it again" in out


def test_a_mac_that_slept_during_a_check_turns_its_failure_into_could_not_check(lab):
    lab.write(
        "check_panel.py",
        "from udeck_e2e.errors import expect\n"
        "def check_dwell(machine):\n"
        "    expect(False, 'SSH timed out after the pointer moved')\n"
        "def check_push(machine): pass\n",
    )
    marker = lab.pytester.path / "slept"
    marker.write_text("{ sec = 0 }")
    lab.write(
        "check_panel.py",
        "from udeck_e2e.errors import expect\n"
        "def check_dwell(machine):\n"
        f"    open({str(marker)!r}, 'w').write('{{ sec = 1790000000 }}')  # the Mac sleeps\n"
        "    expect(False, 'SSH timed out after the pointer moved')\n"
        "def check_push(machine): pass\n",
    )
    out = io.StringIO()
    plugin = lab.plugin(out=out)
    plugin.slept_at = marker.read_text
    lab.pytester.inline_run(*pytest_args(lab.checks, False), plugins=[plugin])
    text = out.getvalue()
    assert plugin.exit_code == 2
    assert "went to sleep" in text and "✅ panel.push" in text


def test_what_the_lab_says_during_a_check_is_not_captured_by_pytest():
    assert "--capture=no" in pytest_args(E2E_DIR / "checks", False)


def test_a_sleep_during_an_earlier_passing_check_on_a_shared_machine_still_counts(lab):
    marker = lab.pytester.path / "slept"
    marker.write_text("{ sec = 0 }")
    lab.write(
        "check_panel.py",
        "from udeck_e2e.errors import expect\n"
        "def check_dwell(machine):\n"
        f"    open({str(marker)!r}, 'w').write('{{ sec = 1790000000 }}')  # sleeps, but passes\n"
        "def check_push(machine):\n    expect(False, 'the frozen guest missed the pointer')\n",
    )
    out = io.StringIO()
    plugin = lab.plugin(out=out, vm_mode="per-group")
    plugin.slept_at = marker.read_text
    lab.pytester.inline_run(*pytest_args(lab.checks, False), plugins=[plugin])
    assert plugin.exit_code == 2
    assert "went to sleep" in out.getvalue()


def test_a_bake_needs_room_for_the_base_image(lab):
    lab.mode = "bake"
    lab.write("check_golden.py", "def check_bake(lab): pass\n")
    original = lab.fake_preflight

    def little_disk(guest, note):
        assessment, about = original(guest, note)
        return assessment, {**about, "free_disk_gb": 30}

    lab.fake_preflight = little_disk
    code, out = lab.run()
    assert code == 2 and "a bake wants" in out


def test_the_self_check_reports_a_restart_that_did_not_happen_as_could_not_check(lab):
    import shutil

    shutil.copy(E2E_DIR / "selfcheck" / "check_lab.py", lab.checks / "check_lab.py")
    FakeMachine.boot_session = lambda self: "same-session"
    FakeMachine.reboot = lambda self: None
    FakeMachine.ssh = property(lambda self: self)
    try:
        code, out = lab.run("lab.restart-comes-back")
    finally:
        del FakeMachine.boot_session, FakeMachine.reboot, FakeMachine.ssh
    assert code == 2
    assert "could not check: checking the restart" in out


# --- Screenshots -----------------------------------------------------------------------------


def test_every_check_with_a_machine_leaves_a_screenshot_at_the_end_whatever_its_outcome(lab):
    write_three(lab)
    lab.write("check_notes.py", "def check_plain(): pass\n")
    code, out = lab.run()
    assert code == 1
    (run,) = lab.run_dirs()
    for name in ("panel.dwell", "panel.push", "updates.sparkle"):
        assert (run / name / "01-at-the-end.png").exists(), name
    assert not (run / "notes.plain").exists()
    # Taken before the machine is closed, while it still runs.
    assert all(m.events.index("screenshot at the end") < m.events.index("close keep=False") for m in lab.machines)


def test_a_screenshot_that_cannot_be_taken_at_the_end_is_said_and_changes_no_outcome(lab):
    lab.write("check_panel.py", "def check_dwell(machine): pass\n")
    lab.break_machine = {"screenshot"}
    code, out = lab.run()
    assert code == 0
    assert "✅ panel.dwell" in out and "no screenshot at the end of panel.dwell" in out


def test_every_check_builds_into_a_directory_of_its_own(lab, tmp_path):
    """Both update checks build the same two versions, and one run holds both.

    Without a directory per check the second overwrites the first's zips and its
    build log — the evidence the first check's report is made of (Q38).
    """
    plugin = lab.plugin()
    plugin.run_dir = tmp_path / "run"
    (plugin.run_dir).mkdir()
    feed = "http://127.0.0.1:8765/appcast.xml"
    first = plugin.builder(feed, "updates.sparkle")
    second = plugin.builder(feed, "updates.wrong-key")
    assert first.work_dir != second.work_dir
    assert "updates.sparkle" in str(first.work_dir) and "updates.wrong-key" in str(second.work_dir)
    # One key for the run, not one per check: the builds of both are this run's.
    assert plugin.signing_key is not None


# --- One machine ahead of the next check (--jobs 2) -----------------------------------


TWO_CHECKS = (
    "def check_alpha(machine):\n"
    "    machine.lab.wait_for('%s')\n"
    "    machine.lab.timeline.append('alpha ran')\n"
    "\n"
    "def check_beta(machine):\n"
    "    machine.lab.timeline.append('beta ran')\n"
)


def test_with_one_machine_nothing_is_started_before_the_check_that_wants_it(lab):
    """The default. A second machine appearing early would spend the host's other
    guest slot on a check that has not started."""
    lab.write("check_pair.py",
              "def check_alpha(machine):\n"
              "    assert len(machine.lab.machines) == 1, machine.lab.timeline\n"
              "\n"
              "def check_beta(machine): pass\n")
    code, out = lab.run()
    assert code == 0, out
    assert lab.timeline == ["pair.alpha create", "pair.alpha boot", "pair.alpha close",
                            "pair.beta create", "pair.beta boot", "pair.beta close"]


def test_with_two_machines_the_next_one_boots_while_this_check_runs(lab):
    """What --jobs 2 buys: the overlap itself, asserted rather than assumed — the
    check blocks until the next machine is up, so a lab that warms nothing hangs
    and then fails here."""
    lab.write("check_pair.py", TWO_CHECKS % "pair.beta boot")
    code, out = lab.run(jobs=2)
    assert code == 0, out
    assert lab.timeline.index("pair.beta boot") < lab.timeline.index("pair.alpha close"), lab.timeline
    assert lab.timeline.index("alpha ran") < lab.timeline.index("beta ran")
    # And not before this check's own machine is up: two booting at once, with the
    # previous one not yet gone, is three alive — one past what macOS allows.
    assert lab.timeline.index("pair.alpha boot") < lab.timeline.index("pair.beta create"), lab.timeline


def test_the_machine_started_ahead_is_the_one_the_next_check_uses(lab):
    """Warmed and then thrown away would be worse than not warming: two clones per
    check, and the host's guest limit spent on a machine nobody used."""
    lab.write("check_pair.py", TWO_CHECKS % "pair.beta boot")
    code, out = lab.run(jobs=2)
    assert code == 0, out
    assert [m.label for m in lab.machines] == ["pair.alpha", "pair.beta"]
    assert lab.timeline.count("pair.beta create") == 1 and lab.timeline.count("pair.beta boot") == 1
    assert "was started ahead" in out


def test_the_last_check_starts_nothing_behind_it(lab):
    lab.write("check_pair.py", "def check_alpha(machine): pass\n")
    code, out = lab.run(jobs=2)
    assert code == 0, out
    assert [m.label for m in lab.machines] == ["pair.alpha"]


def test_a_machine_that_did_not_come_up_ahead_of_time_is_not_the_next_check_s_verdict(lab):
    """A background boot that failed says so and is put back; the check then does
    what it would have done without --jobs 2, and passes."""
    lab.write("check_pair.py", TWO_CHECKS % "pair.beta boot failed")
    lab.boot_fails_for = "pair.beta"
    code, out = lab.run(jobs=2)
    assert code == 0, out
    assert "did not come up" in out
    # Put back, and the check made its own — two machines under that one label.
    assert [m.label for m in lab.machines] == ["pair.alpha", "pair.beta", "pair.beta"]
    assert lab.machines[1].events == ["create", "boot", "close keep=False"]


def test_a_machine_started_ahead_and_never_used_is_put_back(lab):
    """Ctrl-C while the next machine is already up: nothing else will ever look for
    that clone, and it is closed on the main thread, where the interrupt shield works."""
    lab.write("check_pair.py",
              "def check_alpha(machine):\n"
              "    machine.lab.wait_for('pair.beta boot')\n"
              "    raise KeyboardInterrupt\n"
              "\n"
              "def check_beta(machine): pass\n")
    code, out = lab.run(jobs=2)
    assert code != 0
    assert "started ahead and not used" in out
    assert lab.machines[1].label == "pair.beta"
    assert "close keep=False" in lab.machines[1].events


def test_the_host_is_sized_for_the_machines_that_will_be_alive_at_once(lab):
    lab.write("check_pair.py", "def check_alpha(machine): pass\ndef check_beta(machine): pass\n")
    lab.run(jobs=2)
    assert lab.preflight_jobs == [2]
    lab.preflight_jobs.clear()
    lab.run()
    assert lab.preflight_jobs == [1]


def test_a_machine_that_comes_back_later_in_the_run_is_never_started_ahead(lab):
    """Warming is planned from the order of distinct machines. A label that returns
    after another one has been in between names a clone that has already been deleted
    once, and a new one under that name could collide with the old one shutting down."""
    plugin = lab.plugin()
    plugin.names = {"a::x": "one.x", "b::y": "two.y", "c::z": "one.x"}
    items = [SimpleNamespace(nodeid=nodeid, path=Path("/checks/check_one.py")) for nodeid in plugin.names]
    plugin._plan_the_warming(items)
    assert plugin.next_label == {"one.x": "two.y"}


def test_a_machine_that_was_ready_in_time_is_reported_without_a_wait(lab):
    """Ready in time is made certain rather than hoped for: the first check ends
    only once the thread warming the next machine has ended. Its boot in the
    timeline is not that — the thread still has to say the machine is up — and a
    check that ended in between had the next one wait for it, which a loaded host
    made happen (2026-10-05)."""
    import itertools

    lab.write("check_pair.py",
              "def check_alpha(machine):\n"
              "    machine.lab.wait_for('pair.beta boot')\n"
              "    machine.lab.wait_until_warmed('pair.beta')\n"
              "\n"
              "def check_beta(machine): pass\n")
    code, out = lab.run(jobs=2, clock=itertools.count(0, 10).__next__)
    assert code == 0, out
    assert re.search(r"was started ahead \(up in \d+s\)", out), out
    assert "waited" not in out, out


def test_a_check_that_waited_for_its_machine_is_told_how_long(lab):
    """One number flatters the option. A guest booting beside a running check slows
    that check down, and a check that still had to wait for it gained less than the
    boot time — so the line says how long it took *and* how long it was waited for.

    The wait is made certain rather than hoped for: the background thread is still
    working when the check reaches for its machine."""
    import itertools

    out = io.StringIO()
    plugin = lab.plugin(jobs=2, out=out, clock=itertools.count(0, 10).__next__)
    machine = FakeMachine(lab, name="udeck-e2e-probe", source="golden", display=None, label="pair.beta")

    def still_coming_up():
        time.sleep(0.05)
        with plugin._warm_lock:
            plugin._warm_seconds["pair.beta"] = 42.0
            plugin._warming_label = None

    plugin._warm["pair.beta"] = machine
    plugin._warming_label = "pair.beta"
    plugin._warming = threading.Thread(target=still_coming_up)
    plugin._warming.start()

    assert plugin._take_the_warm_one("pair.beta") is machine
    assert re.search(r"was started ahead \(up in 42s, waited \d+s for it\)", out.getvalue()), out.getvalue()


# --- Pairs ------------------------------------------------------------------------------------

from fakes import GitHubAsOn20261009, Web  # noqa: E402 — the GitHub made of answers the pair tests share

PAIRED = """
from udeck_e2e import pairs

@pairs.takes(pairs.THE_WHOLE_UPDATE)
def check_sparkle(machine, pair):
    record(pair)

@pairs.takes(pairs.A_PUBLISHED_RELEASE)
def check_a_published_release(machine, pair):
    record(pair)

def record(pair):
    import json, os
    with open(os.environ["PAIRS_SEEN"], "a") as seen:
        seen.write(json.dumps(pair.ledger()) + "\\n")
"""


def write_paired(lab, monkeypatch):
    lab.write("check_updates.py", PAIRED)
    lab.write("check_panel.py", "def check_dwell(machine): pass\n")
    seen = lab.pytester.path / "pairs-seen.jsonl"
    monkeypatch.setenv("PAIRS_SEEN", str(seen))
    return seen


def seen_pairs(seen):
    return [json.loads(line) for line in seen.read_text().splitlines()] if seen.exists() else []


def test_the_list_says_each_update_checks_default_pair_and_asks_github_nothing(lab, monkeypatch):
    write_paired(lab, monkeypatch)
    nowhere = Web()
    code, out = lab.run(listing=True, web=nowhere)
    assert code == 0
    assert out.splitlines() == [
        "panel.dwell",
        "updates.sparkle  checkout → checkout",
        "updates.a-published-release  the release before latest → latest",
    ]
    assert nowhere.asked == []


def test_a_pair_given_to_a_check_that_takes_none_is_refused_before_anything_starts(lab, monkeypatch):
    write_paired(lab, monkeypatch)
    code, out = lab.run("panel.dwell", "updates.sparkle", from_side="checkout", to_side="latest")
    assert code == 2
    assert "--from and --to do nothing with panel.dwell: only an update check takes a pair" in out
    assert "updates.sparkle, updates.a-published-release" in out
    assert lab.preflights == 0 and lab.run_dirs() == []


def test_a_pair_a_check_cannot_ask_its_question_about_is_refused_with_the_reason(lab, monkeypatch):
    write_paired(lab, monkeypatch)
    code, out = lab.run("updates", from_side="0.5.0", to_side="checkout")
    assert code == 2
    assert "updates.sparkle cannot run 0.5.0 → checkout: a release installs only what the release key signed" in out
    assert "updates.a-published-release cannot run 0.5.0 → checkout" in out
    assert lab.preflights == 0 and lab.run_dirs() == []


def test_a_side_that_is_not_one_is_refused_with_what_to_write(lab, monkeypatch):
    write_paired(lab, monkeypatch)
    code, out = lab.run("updates.sparkle", to_side="v0.6.1")
    assert code == 2
    assert "'v0.6.1' is not one end of an update — without the v: 0.6.1" in out


def test_a_check_runs_with_its_pair_and_the_report_and_the_ledger_say_which(lab, monkeypatch):
    seen = write_paired(lab, monkeypatch)
    code, out = lab.run("updates.sparkle")
    assert code == 0
    assert [p["text"] for p in seen_pairs(seen)] == [
        "checkout as 0.4.1 (6) → checkout as 0.4.2 (7), signed with the run's own key, via the lab's feed in the guest"
    ]
    lines = out.splitlines()
    result = next(i for i, line in enumerate(lines) if line.startswith("✅ updates.sparkle"))
    assert lines[result + 1] == (
        "   pair: checkout as 0.4.1 (6) → checkout as 0.4.2 (7), signed with the run's own key, via the lab's feed in "
        "the guest (default: checkout → checkout)"
    )
    assert "   updates.sparkle: checkout as 0.4.1 (6) → checkout as 0.4.2 (7)" in out, "said before it runs too"
    events = [e["event"] for e in lab.ledger()]
    assert events == ["run-start", "pairs", "preflight", "pruned", "check", "run-end"]
    pairs_event = next(e for e in lab.ledger() if e["event"] == "pairs")
    assert pairs_event["pairs"]["updates.sparkle"]["given"] is False
    assert lab.ledger_checks()["updates.sparkle"]["pair"].startswith("checkout as 0.4.1 (6) → checkout as 0.4.2 (7)")


def test_a_given_pair_reaches_the_check_resolved_against_github(lab, monkeypatch):
    seen = write_paired(lab, monkeypatch)
    github = GitHubAsOn20261009()
    code, out = lab.run("updates.sparkle", to_side="latest", web=github.web)
    assert code == 0, out
    (pair,) = seen_pairs(seen)
    assert pair["given"] is True
    assert pair["from"] == {"side": "checkout", "version": "0.4.1", "build": "1", "carries": "the public key of release 0.6.1"}
    assert pair["to"]["version"] == "0.6.1" and pair["to"]["build"] == "8" and pair["to"]["asked_as"] == "latest"
    assert (lab.pytester.path / ".build" / "e2e" / "releases" / "v0.6.1" / "uDeck-0.6.1.zip").is_file()
    assert "(--from/--to: checkout → latest)" in out


def test_a_given_pair_that_cannot_be_resolved_refuses_the_run_before_the_pre_flight(lab, monkeypatch):
    write_paired(lab, monkeypatch)
    code, out = lab.run("updates.sparkle", to_side="latest", web=Web())
    assert code == 2
    assert "The lab cannot start:" in out
    assert "updates.sparkle cannot run checkout → latest:" in out and "did not answer this Mac" in out
    assert lab.preflights == 0 and lab.machines == []
    pairs_event = next(e for e in lab.ledger() if e["event"] == "pairs")
    assert pairs_event["refused"] and "did not answer this Mac" in pairs_event["refused"][0]


def test_a_default_pair_that_cannot_be_resolved_is_could_not_check_without_a_machine_and_the_rest_runs(lab, monkeypatch):
    seen = write_paired(lab, monkeypatch)
    code, out = lab.run(web=Web())
    assert code == 2
    assert "⚠️ updates.a-published-release" in out
    assert "could not check: resolving the pair the release before latest → latest:" in out
    assert "did not answer this Mac" in out
    assert "✅ updates.sparkle" in out and "✅ panel.dwell" in out
    assert "updates.a-published-release" not in labels(lab), "no machine is made for a check that cannot run"
    assert lab.preflights == 1
    assert [p["text"].split(" → ")[0] for p in seen_pairs(seen)] == ["checkout as 0.4.1 (6)"]
    assert "   pair: the release before latest → latest, not resolved (default: the release before latest → latest)" in out
    problem = next(e for e in lab.ledger() if e["event"] == "pairs")["pairs"]["updates.a-published-release"]
    assert problem["given"] is False and "did not answer this Mac" in problem["problem"]


def a_latest_signed_by_a_key_its_bundles_do_not_carry():
    """GitHub as on 2026-10-09, but 0.6.1's appcast signed by a key nobody's uDeck carries: the release
    key's private half no longer the key released bundles trust."""
    from fakes import Key, an_appcast

    github = GitHubAsOn20261009()
    data = github.zips["0.6.1"]
    github.publish("0.6.1", appcast=an_appcast("0.6.1", "8", data, Key().sign(data)))
    return github


def every_release_can_be_driven(monkeypatch):
    """The pytester checkout has no tags; what the release's source says is test_releases.py's to hold."""
    from udeck_e2e import releases

    monkeypatch.setattr(releases, "check_now_problem", lambda *a, **k: None)


def test_a_to_github_publishes_broken_is_red_without_a_machine_and_the_rest_runs(lab, monkeypatch):
    """The defect the check by a published release exists to catch is its failure — never "could not check"."""
    seen = write_paired(lab, monkeypatch)
    every_release_can_be_driven(monkeypatch)
    code, out = lab.run(web=a_latest_signed_by_a_key_its_bundles_do_not_carry().web)
    assert code == 1, out
    assert ("❌ updates.a-published-release  0s — latest as GitHub publishes it does not hold together: the appcast's "
            "edSignature does not hold over uDeck-0.6.1.zip under the SUPublicEDKey its own Info.plist carries") in out
    assert "✅ updates.sparkle" in out and "✅ panel.dwell" in out
    assert "updates.a-published-release" not in labels(lab), "measured on this Mac: no machine is made for it"
    assert [p["text"].split(" → ")[0] for p in seen_pairs(seen)] == ["checkout as 0.4.1 (6)"], "its body never ran"
    assert ('   pair: the release before latest → latest, not run: its "to" as GitHub publishes it does not hold '
            "together (default: the release before latest → latest)") in out
    check = lab.ledger_checks()["updates.a-published-release"]
    assert check["outcome"] == "failed" and "does not hold over uDeck-0.6.1.zip" in check["reason"]
    defect = next(e for e in lab.ledger() if e["event"] == "pairs")["pairs"]["updates.a-published-release"]
    assert "does not hold over uDeck-0.6.1.zip" in defect["defect"] and defect["problem"] is None


def test_a_to_github_publishes_broken_is_red_when_the_pair_was_given_too(lab, monkeypatch):
    """A given pair that cannot be resolved refuses the run; one whose "to" is broken has found something."""
    write_paired(lab, monkeypatch)
    code, out = lab.run("updates.sparkle", from_side="checkout", to_side="latest",
                        web=a_latest_signed_by_a_key_its_bundles_do_not_carry().web)  # fmt: skip
    assert code == 1, out
    assert "❌ updates.sparkle" in out and "latest as GitHub publishes it does not hold together" in out
    assert "The lab cannot start" not in out and lab.preflights == 1
    assert lab.machines == []


A_PUBLISHED_RELEASE_ALONE = """
from udeck_e2e import pairs

@pairs.takes(pairs.A_PUBLISHED_RELEASE)
def check_a_published_release(machine, pair):
    raise AssertionError("its body never runs")
"""

# The machine each --vm mode would give updates.a-published-release, written alone in check_updates.py.
ITS_MACHINE = {"per-check": "updates.a-published-release", "per-group": "updates", "per-run": "run"}


@pytest.mark.parametrize("vm_mode", ["per-check", "per-group", "per-run"])
def test_a_to_github_publishes_broken_is_red_without_a_machine_in_every_vm_mode(lab, monkeypatch, vm_mode):
    """Under per-group and per-run the shared machine is a wider fixture than any check's own, so pytest
    would make and boot it before a function-scoped one. The defect is found before any fixture; and the
    machine it would have had is set to fail its boot, which would turn the red into "could not check"."""
    lab.write("check_updates.py", A_PUBLISHED_RELEASE_ALONE)
    every_release_can_be_driven(monkeypatch)
    lab.boot_fails_for = ITS_MACHINE[vm_mode]
    code, out = lab.run(vm_mode=vm_mode, web=a_latest_signed_by_a_key_its_bundles_do_not_carry().web)
    assert code == 1, out
    assert "❌ updates.a-published-release  0s — latest as GitHub publishes it does not hold together" in out
    assert "could not check" not in out and "the desktop never came up" not in out
    assert lab.machines == [] and lab.timeline == [], "no machine is made, so none can fail to boot"
    check = lab.ledger_checks()["updates.a-published-release"]
    assert check["outcome"] == "failed" and "does not hold over uDeck-0.6.1.zip" in check["reason"]


@pytest.mark.parametrize("vm_mode", ["per-check", "per-group", "per-run"])
def test_a_default_pair_that_cannot_be_resolved_makes_no_machine_in_any_vm_mode(lab, monkeypatch, vm_mode):
    lab.write("check_updates.py", A_PUBLISHED_RELEASE_ALONE)
    lab.boot_fails_for = ITS_MACHINE[vm_mode]
    code, out = lab.run(vm_mode=vm_mode, web=Web())
    assert code == 2, out
    assert "⚠️ updates.a-published-release" in out
    assert "could not check: resolving the pair the release before latest → latest:" in out
    assert "did not answer this Mac" in out and "the desktop never came up" not in out
    assert lab.machines == [] and lab.timeline == []


@pytest.mark.parametrize(
    ("vm_mode", "machines"),
    [("per-check", ["panel.dwell", "updates.sparkle"]), ("per-group", ["panel", "updates"]), ("per-run", ["run"])],
)
def test_a_broken_to_beside_checks_that_run_costs_their_machines_nothing(lab, monkeypatch, vm_mode, machines):
    """The broken check shares its group with updates.sparkle, and its run with panel.dwell: it neither
    makes a machine of its own nor takes the shared one, and the others run on theirs as before."""
    seen = write_paired(lab, monkeypatch)
    every_release_can_be_driven(monkeypatch)
    code, out = lab.run(vm_mode=vm_mode, web=a_latest_signed_by_a_key_its_bundles_do_not_carry().web)
    assert code == 1, out
    assert "❌ updates.a-published-release  0s — latest as GitHub publishes it does not hold together" in out
    assert "✅ panel.dwell" in out and "✅ updates.sparkle" in out
    assert labels(lab) == machines
    assert all(m.events.count("create") == 1 for m in lab.machines)
    assert [p["text"].split(" → ")[0] for p in seen_pairs(seen)] == ["checkout as 0.4.1 (6)"], "its body never ran"
    (run,) = lab.run_dirs()
    assert list((run / "updates.a-published-release").glob("*.png")) == [], "no screen of a machine it never used"
    assert sum(event == "screenshot at the end" for m in lab.machines for event in m.events) == 2


def test_a_to_whose_zip_github_says_is_not_there_is_red_without_a_machine(lab, monkeypatch):
    """404 for an asset GitHub's API lists: the guest leaves it to the verdict, and so does this Mac."""
    from fakes import DOWNLOAD

    lab.write("check_updates.py", A_PUBLISHED_RELEASE_ALONE)
    every_release_can_be_driven(monkeypatch)
    github = GitHubAsOn20261009()
    github.web.file(f"{DOWNLOAD}/v0.6.1/uDeck-0.6.1.zip", b"Not Found", status=404)
    code, out = lab.run(web=github.web)
    assert code == 1, out
    assert "❌ updates.a-published-release  0s — latest as GitHub publishes it does not hold together: GitHub answered 404" in out
    assert lab.machines == []


def test_a_to_whose_info_plist_is_not_xml_is_red_and_not_the_labs_exception(lab, monkeypatch):
    """The skeptic's probe of 2026-10-09: expat's error used to escape as "the lab itself raised ExpatError"."""
    import io
    import zipfile

    from fakes import an_appcast

    lab.write("check_updates.py", A_PUBLISHED_RELEASE_ALONE)
    every_release_can_be_driven(monkeypatch)
    github = GitHubAsOn20261009()
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w") as archive:
        archive.writestr("uDeck.app/Contents/Info.plist", b'<?xml version="1.0"?><plist><dict><key>a</key><string>b</dict></plist>')
    data = buffer.getvalue()
    github.publish("0.6.1", data, an_appcast("0.6.1", "8", data, github.key.sign(data)))
    code, out = lab.run(web=github.web)
    assert code == 1, out
    assert "❌ updates.a-published-release" in out and "has no readable uDeck.app/Contents/Info.plist: ExpatError" in out
    assert "the lab itself raised" not in out and lab.machines == []


def an_appcast_sending_udeck_elsewhere(github, version):
    """`version`'s appcast published again, its item for the zip sending uDeck to a host that does not resolve."""
    from fakes import DOWNLOAD, an_appcast

    data = github.zips[version]
    elsewhere = f"{DOWNLOAD}/v{version}/uDeck-{version}.zip".replace("github.com", "nowhere.invalid")
    github.publish(version, appcast=an_appcast(version, dict(github.VERSIONS)[version], data, github.key.sign(data),
                                               url=elsewhere))  # fmt: skip
    return elsewhere


def test_a_to_whose_appcast_sends_udeck_elsewhere_is_red_without_a_machine(lab, monkeypatch):
    """The skeptic's probe of 2026-10-09: such a "to" was vouched for, and the guest's curl failing on the host
    it names read as "could not check" — for a release every uDeck would fail to download."""
    lab.write("check_updates.py", A_PUBLISHED_RELEASE_ALONE)
    every_release_can_be_driven(monkeypatch)
    github = GitHubAsOn20261009()
    elsewhere = an_appcast_sending_udeck_elsewhere(github, "0.6.1")
    code, out = lab.run(web=github.web)
    assert code == 1, out
    assert "❌ updates.a-published-release  0s — latest as GitHub publishes it does not hold together" in out
    assert f"sends uDeck to {elsewhere}, not to the asset GitHub's API lists for v0.6.1" in out
    assert lab.machines == [] and lab.timeline == []


def test_a_from_whose_appcast_sends_udeck_elsewhere_runs_since_nothing_reads_where_it_sends_udeck(lab, monkeypatch):
    """The lab installs "from"'s zip itself and Sparkle downloads "to": where "from"'s own appcast sends uDeck is
    read by nobody, so it neither fails the check nor stops it."""
    seen = write_paired(lab, monkeypatch)
    every_release_can_be_driven(monkeypatch)
    github = GitHubAsOn20261009()
    an_appcast_sending_udeck_elsewhere(github, "0.5.0")
    code, out = lab.run("updates.a-published-release", web=github.web)
    assert code == 0, out
    assert "✅ updates.a-published-release" in out and "❌" not in out and "⚠️" not in out
    (pair,) = seen_pairs(seen)
    assert pair["from"]["version"] == "0.5.0" and pair["to"]["version"] == "0.6.1"
    assert "the defect of a release a check is offered, and nothing a check reads of one it installs" in out


@pytest.mark.parametrize("broken", ["signed by another key", "its zip not there", "its appcast not there"])
def test_a_broken_to_a_checkout_has_no_update_to_is_refused_and_never_red(lab, monkeypatch, broken):
    """The skeptic's probe of 2026-10-09, `--from checkout --to 0.1.0`: refused with 0.1.0 whole, red with it
    broken. 0.1.0 is numbered 1, as the build of this checkout going to it is — by its appcast when that was read,
    its zip there or not, and by being the first release GitHub publishes when no appcast was."""
    from fakes import DOWNLOAD, Key, an_appcast

    write_paired(lab, monkeypatch)
    github = GitHubAsOn20261009()
    if broken == "signed by another key":
        data = github.zips["0.1.0"]
        github.publish("0.1.0", appcast=an_appcast("0.1.0", "1", data, Key().sign(data)))
    elif broken == "its zip not there":
        github.web.file(f"{DOWNLOAD}/v0.1.0/uDeck-0.1.0.zip", b"Not Found", status=404)
    else:
        github.web.file(f"{DOWNLOAD}/v0.1.0/appcast.xml", b"Not Found", status=404)
    code, out = lab.run("updates.sparkle", from_side="checkout", to_side="0.1.0", web=github.web)
    assert code == 2, out
    assert "The lab cannot start:" in out and "updates.sparkle cannot run checkout → 0.1.0:" in out
    assert "❌" not in out and lab.preflights == 0 and lab.machines == []
    said = {"signed by another key": "(1, as its appcast offers it, against 1)",
            "its zip not there": "(1, as its appcast offers it, against 1)",
            "its appcast not there": "0.1.0 is the first release GitHub publishes"}[broken]  # fmt: skip
    assert said in out


# --- Not newer: red in the lab's own pair, a refusal in a pair someone gave ------------------------
#
# The skeptic's probes of 2026-10-09 on the lab's own pair, the release before latest (0.5.0, numbered 6) → latest:
# P1, a latest whole but numbered 6 again; P2, a latest broken, its zip saying 9 and its appcast 6. Both were
# "could not check" (exit 2); every uDeck 0.5.0 would say it is up to date, which is the check's to catch.


def a_latest_numbered_6(github, broken):
    from fakes import a_zip, an_appcast

    data = a_zip("0.6.1", "9" if broken else "6", github.key)
    github.publish("0.6.1", data, an_appcast("0.6.1", "6", data, github.key.sign(data)))
    return github


@pytest.mark.parametrize("broken", [False, True], ids=["P1 whole", "P2 broken"])
@pytest.mark.parametrize("to_side", [None, "latest"], ids=["nothing given", "--to latest alone"])
def test_in_the_labs_own_pair_a_latest_not_newer_than_the_one_before_is_red_without_a_machine(lab, monkeypatch,
                                                                                               broken, to_side):
    lab.write("check_updates.py", A_PUBLISHED_RELEASE_ALONE)
    every_release_can_be_driven(monkeypatch)
    github = a_latest_numbered_6(GitHubAsOn20261009(), broken)
    code, out = lab.run(to_side=to_side, web=github.web)
    assert code == 1, out
    by = "6, as its appcast offers it," if broken else "6"
    assert (f"❌ updates.a-published-release  0s — latest, release 0.6.1 (6), is not newer than the release before it, "
            f"release 0.5.0 (6), by CFBundleVersion, the number Sparkle compares ({by} against 6): every uDeck 0.5.0 "
            "that looks would say it is up to date, and never be offered 0.6.1") in out
    assert ("— and 0.6.1 as GitHub publishes it does not hold together: uDeck-0.6.1.zip is not the release its tag "
            "and appcast name: CFBundleVersion is '9', not '6'" in out) is broken
    assert "⚠️" not in out and "The lab cannot start" not in out
    how = "--from/--to" if to_side else "default"
    assert (f"   pair: the release before latest → latest, not run: latest as GitHub publishes it is not newer than "
            f"the release before it ({how}: the release before latest → latest)") in out
    assert lab.machines == [] and lab.timeline == [], "measured on this Mac: no machine is made for it"
    check = lab.ledger_checks()["updates.a-published-release"]
    assert check["outcome"] == "failed" and "is not newer than the release before it" in check["reason"]
    defect = next(e for e in lab.ledger() if e["event"] == "pairs")["pairs"]["updates.a-published-release"]
    assert "every uDeck 0.5.0 that looks would say it is up to date" in defect["defect"] and defect["problem"] is None


@pytest.mark.parametrize("broken", [False, True], ids=["P1 whole", "P2 broken"])
@pytest.mark.parametrize("to_side", [None, "latest", "0.6.1"])
def test_a_given_pair_whose_to_is_not_newer_is_refused_before_anything_starts_and_never_red(lab, monkeypatch,
                                                                                            broken, to_side):
    """The same two releases, "from" named on the command line: a request for an update there is none of."""
    lab.write("check_updates.py", A_PUBLISHED_RELEASE_ALONE)
    every_release_can_be_driven(monkeypatch)
    github = a_latest_numbered_6(GitHubAsOn20261009(), broken)
    code, out = lab.run(from_side="0.5.0", to_side=to_side, web=github.web)
    assert code == 2, out
    assert "The lab cannot start:" in out and "updates.a-published-release cannot run 0.5.0 → " in out
    assert "is not newer than release 0.5.0 (6) by CFBundleVersion" in out
    assert "❌" not in out and lab.preflights == 0 and lab.machines == []


def test_a_check_stopped_before_its_machine_meets_no_other_setup_hook(lab, monkeypatch):
    """The gate is the first `pytest_runtest_setup` (tryfirst): a hook registered after the lab's — a conftest
    beside the checks is — would otherwise run before it, and anything it set up would come before the verdict."""
    write_paired(lab, monkeypatch)
    every_release_can_be_driven(monkeypatch)
    met = lab.pytester.path / "setup-hooks-met"
    lab.write("conftest.py", f"""
def pytest_runtest_setup(item):
    with open({str(met)!r}, "a") as file:
        file.write(item.name + "\\n")
""")
    code, out = lab.run(web=a_latest_signed_by_a_key_its_bundles_do_not_carry().web)
    assert code == 1, out
    assert "❌ updates.a-published-release" in out
    assert met.read_text().split() == ["check_dwell", "check_sparkle"], "the stopped check met no hook after the gate"


@pytest.mark.parametrize("vm_mode", ["per-group", "per-run"])
def test_a_shared_machine_is_not_kept_for_a_check_that_never_used_it(lab, monkeypatch, vm_mode):
    """--keep-on-failure keeps a shared machine a check failed on; the broken "to" failed on this Mac."""
    write_paired(lab, monkeypatch)
    every_release_can_be_driven(monkeypatch)
    code, out = lab.run(vm_mode=vm_mode, keep_on_failure=True,
                        web=a_latest_signed_by_a_key_its_bundles_do_not_carry().web)  # fmt: skip
    assert code == 1, out
    assert lab.machines and all(m.events[-1] == "close keep=False" for m in lab.machines), [
        (m.label, m.events) for m in lab.machines
    ]


def test_a_download_cut_short_is_one_checks_could_not_check_and_never_every_checks_never_started(lab, monkeypatch):
    """An exception the transfer raises that is not an OSError used to escape as INTERNALERROR."""
    import http.client

    write_paired(lab, monkeypatch)
    every_release_can_be_driven(monkeypatch)
    github = GitHubAsOn20261009()

    def web(url, headers):
        if url.endswith(".zip"):
            raise http.client.IncompleteRead(b"x" * 10, 6026082)
        return github.web(url, headers)

    code, out = lab.run(web=web)
    assert code == 2, out
    assert "⚠️ updates.a-published-release" in out
    assert "the lab itself raised IncompleteRead resolving it" in out
    assert "✅ updates.sparkle" in out and "✅ panel.dwell" in out
    assert "never started" not in out and "INTERNALERROR" not in out
    problem = next(e for e in lab.ledger() if e["event"] == "pairs")["pairs"]["updates.a-published-release"]
    assert "IncompleteRead" in problem["problem"]


def test_a_check_that_stops_before_its_machine_has_none_booted_for_it_ahead_either(lab, monkeypatch):
    """`--jobs 2` warms the next check's machine; the next check here will never want one."""
    write_paired(lab, monkeypatch)
    lab.write("check_zz.py", "def check_last(machine): pass\n")
    code, out = lab.run(jobs=2, web=Web())
    assert "⚠️ updates.a-published-release" in out and "✅ zz.last" in out
    assert "updates.a-published-release" not in labels(lab), labels(lab)
    assert labels(lab) == ["panel.dwell", "updates.sparkle", "zz.last"]


def test_a_check_that_asks_for_a_pair_without_taking_one_is_the_labs_mistake(lab):
    lab.write("check_updates.py", "def check_sparkle(machine, pair): pass\n")
    code, out = lab.run()
    assert code == 2
    assert "could not check: finding the check's pair: updates.sparkle takes no pair" in out


def test_a_build_for_a_release_carries_its_public_key_and_every_other_build_the_runs(lab, tmp_path):
    from udeck_e2e import builds

    plugin = lab.plugin()
    plugin.run_dir = tmp_path / "run"
    ordinary = plugin.builder("http://127.0.0.1:8765/appcast.xml", "updates.sparkle")
    for_a_release = plugin.builder("http://127.0.0.1:8765/appcast.xml", "updates.sparkle", release_key="cmVsZWFzZQ==")
    assert ordinary.key is plugin.signing_key and isinstance(ordinary.key, builds.SigningKey)
    assert for_a_release.key == builds.PublicKey("cmVsZWFzZQ==")
    assert ordinary.work_dir != for_a_release.work_dir
