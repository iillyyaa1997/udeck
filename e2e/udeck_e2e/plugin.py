"""The pytest plugin that turns a pytest session into a lab run.

pytest does the collecting, the fixtures and the running. This plugin decides
everything a person reads: which checks were asked for, whether the host is fit
to run them, what each outcome was, and what the run exits with. pytest's own
terminal output is switched off, so there is one voice in the console.
"""

from __future__ import annotations

import os
import subprocess
import sys
import time
import traceback
from collections.abc import Callable
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import IO, Any

import pytest

from udeck_e2e import config, names, preflight
from udeck_e2e.config import Guest
from udeck_e2e.errors import CheckFailed, LabError
from udeck_e2e.ledger import Ledger, RunLock, new_run_dir, prune_runs
from udeck_e2e.outcomes import EXIT_NOT_CHECKED, EXIT_PASSED, Outcome, duration, exit_code, summary

PreflightResult = tuple[preflight.Assessment, list[str], dict[str, Any]]


def real_preflight(guest: Guest) -> PreflightResult:
    """Stop the lab's orphans, then look at the host. Needs the run lock held."""
    table, problem = preflight.process_table()
    stopped = preflight.stop_orphans(preflight.find_orphans(table or "", os.getpid()))
    facts = preflight.gather()
    if problem:
        facts.gathering.append(problem)
    about = {
        "tart": str(facts.tart) if facts.tart else None,
        "tart_version": facts.tart_version,
        "host_macos": facts.host_macos,
        "free_disk_gb": round(facts.free_disk_gb, 1),
        "memory_gb": round(facts.memory_gb, 1),
        "memory_pressure": facts.memory_pressure,
    }
    return preflight.assess(facts, guest), stopped, about


@dataclass
class CheckRecord:
    name: str
    started: float
    outcome: Outcome = Outcome.PASSED
    reason: str = ""
    details: list[str] = field(default_factory=list)
    cleanup_problem: str = ""
    finished: bool = False


class LabPlugin:
    def __init__(
        self,
        *,
        wanted: list[str],
        listing: bool,
        guest: Guest,
        repo_root: Path,
        checks_dir: Path,
        runs_root: Path,
        stream: IO[str] | None = None,
        run_preflight: Callable[[Guest], PreflightResult] = real_preflight,
        now: Callable[[], datetime] = datetime.now,
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        self.wanted = wanted
        self.listing = listing
        self.guest = guest
        self.repo_root = repo_root
        self.checks_dir = checks_dir.resolve()
        self.runs_root = runs_root
        self.stream = stream or sys.stdout
        self.run_preflight = run_preflight
        self.now = now
        self.clock = clock

        self.exit_code = EXIT_NOT_CHECKED
        self.blocked = False
        self.started = clock()
        self.names: dict[str, str] = {}
        self.records: dict[str, CheckRecord] = {}
        self.collection_errors: list[str] = []
        self.lab_problems: list[str] = []
        self.interrupted = False
        self.run_dir: Path | None = None
        self.ledger: Ledger | None = None
        self.lock = RunLock(runs_root / "lab.lock")

    # --- Output ------------------------------------------------------------

    def say(self, text: str = "") -> None:
        print(text, file=self.stream, flush=True)

    def shown(self, path: Path) -> str:
        try:
            return str(path.relative_to(self.repo_root))
        except ValueError:
            return str(path)

    def stop(self, code: int) -> None:
        self.blocked = True
        self.exit_code = code

    # --- Collection --------------------------------------------------------

    def pytest_collectreport(self, report: pytest.CollectReport) -> None:
        if report.failed:
            self.collection_errors.append(f"{report.nodeid or 'checks'}:\n{report.longreprtext}")

    def pytest_collection_modifyitems(
        self, session: pytest.Session, config: pytest.Config, items: list[pytest.Item]
    ) -> None:
        by_name: dict[str, pytest.Item] = {}
        for item in items:
            function = getattr(item, "originalname", item.name)
            try:
                name = names.check_name(Path(str(item.path)).stem, function)
            except names.CheckNameError as error:
                self.collection_errors.append(str(error))
                continue
            if getattr(item, "callspec", None) is not None:
                self.collection_errors.append(
                    f"{name}: a check is not parametrised — write one check per case, "
                    "so each has its own name on the command line"
                )
                continue
            if name in by_name:
                self.collection_errors.append(f"{name}: defined twice")
                continue
            by_name[name] = item

        try:
            chosen = names.select(by_name, self.wanted)
        except names.CheckNameError as error:
            self.collection_errors.append(str(error))
            chosen = []

        keep = [by_name[name] for name in chosen]
        dropped = [item for item in items if item not in keep]
        if dropped:
            config.hook.pytest_deselected(items=dropped)
        items[:] = keep
        self.names = {by_name[name].nodeid: name for name in chosen}

    def pytest_collection_finish(self, session: pytest.Session) -> None:
        if self.collection_errors:
            for error in self.collection_errors:
                self.say(error)
            self.stop(EXIT_NOT_CHECKED)
            return

        if self.listing:
            for name in self.names.values():
                self.say(name)
            if not self.names:
                self.say("There are no checks yet.")
            self.stop(EXIT_PASSED)
            return

        if not self.names:
            self.say("There are no checks to run.")
            self.stop(EXIT_NOT_CHECKED)
            return

        holder = self.lock.acquire()
        if holder is not None:
            self.say(
                "Another lab run is in progress"
                + (f" (pid {holder})" if holder > 0 else "")
                + ". Wait for it to finish; the lab runs one at a time."
            )
            self.stop(EXIT_NOT_CHECKED)
            return

        self.run_dir = new_run_dir(self.runs_root, self.now())
        self.ledger = Ledger(self.run_dir / "ledger.jsonl")
        removed = prune_runs(self.runs_root, config.KEEP_RUNS, self.run_dir)
        self.ledger.write(
            "run-start",
            argv=sys.argv[1:],
            guest=self.guest.key,
            base_image=self.guest.base_image,
            checks=list(self.names.values()),
            repo=_git_state(self.repo_root),
            pruned_runs=[p.name for p in removed],
        )

        assessment, stopped, about = self.run_preflight(self.guest)
        self.ledger.write(
            "preflight",
            host=about,
            orphans_stopped=stopped,
            problems=[{"what": p.what, "todo": p.todo} for p in assessment.problems],
            notes=assessment.notes,
        )
        for line in stopped + assessment.notes:
            self.say(line)
        if assessment.problems:
            self.say("The lab cannot start:")
            for problem in assessment.problems:
                self.say(f"  • {problem.render()}")
            self.stop(EXIT_NOT_CHECKED)
            return

        count = len(self.names)
        self.say(
            f"Running {count} check{'' if count == 1 else 's'} on macOS {self.guest.key} — "
            f"report in {self.shown(self.run_dir)}/"
        )

    def pytest_runtestloop(self, session: pytest.Session) -> bool | None:
        return True if self.blocked else None

    # --- Running -----------------------------------------------------------

    @pytest.fixture
    def check_dir(self, request: pytest.FixtureRequest) -> Path:
        """This check's directory in the run's report, for whatever it collects."""
        assert self.run_dir is not None, "check_dir is only available during a run"
        path = self.run_dir / self.names[request.node.nodeid]
        path.mkdir(exist_ok=True)
        return path

    def pytest_runtest_logstart(self, nodeid: str, location: Any) -> None:
        self.records[nodeid] = CheckRecord(self.names[nodeid], self.clock())

    @pytest.hookimpl(wrapper=True)
    def pytest_runtest_makereport(
        self, item: pytest.Item, call: pytest.CallInfo[None]
    ) -> Any:
        report = yield
        record = self.records[item.nodeid]
        excinfo = call.excinfo
        if excinfo is None:
            return report

        text = report.longreprtext
        if call.when == "teardown":
            record.cleanup_problem = _first_line(excinfo.value) or excinfo.typename
            record.details.append(f"while cleaning up:\n{text}")
            return report

        # Setup and call cannot both fail: a check whose setup failed is not called.
        record.details.append(text)
        if call.when == "call" and self._is_verdict(excinfo):
            record.outcome = Outcome.FAILED
            record.reason = _first_line(excinfo.value) or excinfo.exconly()
        else:
            record.outcome = Outcome.COULD_NOT_CHECK
            record.reason = _lab_reason(call.when, excinfo)
        return report

    def _is_verdict(self, excinfo: pytest.ExceptionInfo[BaseException]) -> bool:
        """A failure is a verdict on uDeck only if a check itself pronounced it.

        That is `CheckFailed` from anywhere, or a plain `assert` whose innermost
        frame is in a check file. An `assert` in the lab's own code, or any other
        exception, is the lab failing to check — never uDeck failing.
        """
        if excinfo.errisinstance(CheckFailed):
            return True
        if not excinfo.errisinstance(AssertionError) or excinfo.errisinstance(
            pytest.skip.Exception
        ):
            return False
        innermost = Path(str(excinfo.traceback[-1].path)).resolve()
        return innermost.parent == self.checks_dir and innermost.name.startswith("check_")

    def pytest_runtest_logfinish(self, nodeid: str, location: Any) -> None:
        record = self.records[nodeid]
        record.finished = True
        seconds = self.clock() - record.started
        evidence = self.run_dir / record.name if self.run_dir else None
        if record.details and evidence is not None:
            evidence.mkdir(exist_ok=True)
            (evidence / "error.txt").write_text("\n\n".join(record.details), encoding="utf-8")

        line = f"{record.outcome.mark} {record.name}  {duration(seconds)}"
        if record.outcome is Outcome.FAILED:
            line += f" — {record.reason}"
        elif record.outcome is Outcome.COULD_NOT_CHECK:
            line += f" — could not check: {record.reason}"
        self.say(line)
        if record.outcome is not Outcome.PASSED and evidence is not None and evidence.exists():
            self.say(f"   evidence: {self.shown(evidence)}/")
        if record.cleanup_problem:
            self.lab_problems.append(f"{record.name}: {record.cleanup_problem}")
            self.say(f"   ⚠️ cleanup failed: {record.cleanup_problem}")

        assert self.ledger is not None
        self.ledger.write(
            "check",
            name=record.name,
            outcome=record.outcome.value,
            seconds=round(seconds, 1),
            reason=record.reason,
            cleanup_problem=record.cleanup_problem,
            evidence=self.shown(evidence) if evidence is not None and evidence.exists() else None,
        )

    def pytest_keyboard_interrupt(self, excinfo: pytest.ExceptionInfo[BaseException]) -> None:
        self.interrupted = True

    # --- The end -----------------------------------------------------------

    def pytest_sessionfinish(self, session: pytest.Session, exitstatus: int) -> None:
        if self.run_dir is None:
            self.lock.release()
            return

        # A check that never finished — Ctrl-C arrived in the middle of it, or
        # before it started — was not checked, whatever its record says so far.
        finished = [record for record in self.records.values() if record.finished]
        unfinished = [name for nodeid, name in self.names.items()
                      if nodeid not in self.records or not self.records[nodeid].finished]
        outcomes = [record.outcome for record in finished]
        outcomes += [Outcome.COULD_NOT_CHECK] * len(unfinished)
        if not self.blocked:
            self.exit_code = exit_code(outcomes, len(self.lab_problems))
        if self.interrupted:
            self.say("Interrupted.")

        seconds = self.clock() - self.started
        if not self.blocked:
            line = summary(outcomes, seconds)
            if unfinished:
                line += f" ({len(unfinished)} never finished: {', '.join(unfinished)})"
            self.say(line)
        assert self.ledger is not None
        self.ledger.write(
            "run-end",
            exit_code=self.exit_code,
            seconds=round(seconds, 1),
            interrupted=self.interrupted,
            never_finished=unfinished,
            lab_problems=self.lab_problems,
        )
        self.ledger.close()
        self.lock.release()


def _first_line(value: BaseException) -> str:
    text = str(value).strip()
    return text.splitlines()[0] if text else ""


def _lab_reason(when: str, excinfo: pytest.ExceptionInfo[BaseException]) -> str:
    value = excinfo.value
    if isinstance(value, LabError):
        return str(value)
    if excinfo.errisinstance(pytest.skip.Exception):
        return f"skipped: {_first_line(value) or 'no reason given'}"
    where = "preparing the check" if when == "setup" else "the lab itself"
    frame = traceback.extract_tb(value.__traceback__)[-1] if value.__traceback__ else None
    at = f" at {Path(frame.filename).name}:{frame.lineno}" if frame else ""
    return f"{where} raised {excinfo.typename}{at}: {_first_line(value)}"


def _git_state(root: Path) -> dict[str, Any]:
    def git(*args: str) -> str | None:
        try:
            done = subprocess.run(
                ["git", "-C", str(root), *args], capture_output=True, text=True, timeout=10
            )
        except (OSError, subprocess.TimeoutExpired):
            return None
        return done.stdout.strip() if done.returncode == 0 else None

    status = git("status", "--porcelain")
    return {"commit": git("rev-parse", "HEAD"), "dirty": bool(status) if status is not None else None}
