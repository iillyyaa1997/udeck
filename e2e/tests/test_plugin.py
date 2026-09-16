"""The lab's reporting, run against small fake check files.

Each test writes a checks directory, runs a real pytest session over it with
the lab's plugin — the same arguments `e2e/run.sh` uses — and reads what a
person would read: the console lines, the exit code, the ledger.
"""

import io
import json
import os
from datetime import datetime
from pathlib import Path

import pytest

from udeck_e2e import config, preflight
from udeck_e2e.cli import E2E_DIR, pytest_args
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
        self.problems: list[preflight.Problem] = []
        self.preflights = 0

    def write(self, name: str, source: str) -> None:
        (self.checks / name).write_text(source)

    def fake_preflight(self, guest):
        self.preflights += 1
        return preflight.Assessment(list(self.problems), []), [], {"host_macos": "27.0"}

    def run(self, *wanted: str, listing: bool = False):
        out = io.StringIO()
        plugin = LabPlugin(
            wanted=list(wanted),
            listing=listing,
            guest=config.GUESTS["27"],
            repo_root=self.pytester.path,
            checks_dir=self.checks,
            runs_root=self.runs,
            stream=out,
            run_preflight=self.fake_preflight,
            now=lambda: datetime(2026, 9, 16, 12, 0, 0),
        )
        self.pytester.inline_run(
            *pytest_args(self.checks, listing), plugins=[plugin], no_reraise_ctrlc=True
        )
        return plugin.exit_code, out.getvalue()

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
    assert events == ["run-start", "preflight", "check", "run-end"]
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
    holder = RunLock(lab.runs / "lab.lock")
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
    assert "never finished: panel.push, panel.mid-screen" in out
    assert lab.ledger()[-1]["interrupted"] is True


def test_old_runs_beyond_the_limit_are_removed(lab):
    lab.write("check_panel.py", "def check_dwell(): pass\n")
    lab.runs.mkdir()
    for minute in range(config.KEEP_RUNS + 3):
        (lab.runs / f"20260915-10{minute:02d}00").mkdir()
    lab.run()
    runs = sorted(p.name for p in lab.runs.iterdir() if p.is_dir())
    assert len(runs) == config.KEEP_RUNS
    assert runs[-1] == "20260916-120000"
