"""The pytest plugin that turns a pytest session into a lab run.

pytest does the collecting, the fixtures and the running. This plugin decides
everything a person reads: which checks were asked for, whether the host is fit
to run them, what each outcome was, and what the run exits with. pytest's own
terminal output is switched off, so there is one voice in the console.
"""

from __future__ import annotations

import shutil
import subprocess
import sys
import time
import traceback
from collections.abc import Callable
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import IO, Any

import pytest

from udeck_e2e import config, golden, names, preflight
from udeck_e2e.config import Guest
from udeck_e2e.errors import CheckFailed, LabError
from udeck_e2e.guest import SSH, make_key
from udeck_e2e.machine import Machine
from udeck_e2e.tart import Tart
from udeck_e2e.ledger import Ledger, RunLock, host_lock_path, mark_started, new_run_dir, prune_runs
from udeck_e2e.outcomes import EXIT_NOT_CHECKED, EXIT_PASSED, Outcome, duration, exit_code, summary

Note = Callable[[str], None]
Preflight = Callable[[Guest, Note], tuple[preflight.Assessment, dict[str, Any]]]


def real_preflight(guest: Guest, note: Note) -> tuple[preflight.Assessment, dict[str, Any]]:
    assessment, facts = preflight.run(guest, note)
    about = {
        "tart": str(facts.tart) if facts.tart else None,
        "tart_version": facts.tart_version,
        "host_macos": facts.host_macos,
        "free_disk_gb": round(facts.free_disk_gb, 1),
        "memory_gb": round(facts.memory_gb, 1),
        "memory_pressure": facts.memory_pressure,
        "running_machines": [p.args for p in facts.machines],
        "framework_machines": facts.framework_machines,
        "vms": [vm.name for vm in facts.vms],
    }
    return assessment, about


def host_slept_at() -> str:
    """When the Mac last went to sleep, from the kernel; changes if it sleeps."""
    try:
        done = subprocess.run(
            ["/usr/sbin/sysctl", "-n", "kern.sleeptime"], capture_output=True, text=True, timeout=10
        )
    except (OSError, subprocess.TimeoutExpired):
        return ""
    return done.stdout.strip()


# How a --vm mode maps onto pytest's fixture scopes: a machine per check, per
# group (a check file) or per run.
VM_SCOPES = {"per-check": "function", "per-group": "module", "per-run": "session"}

MachineFactory = Callable[..., Machine]


@dataclass
class CheckRecord:
    name: str
    started: float
    outcome: Outcome = Outcome.PASSED
    reason: str = ""
    details: list[str] = field(default_factory=list)
    cleanup_problem: str = ""
    # The check's own body ran to an end — passed, or pronounced a verdict. An
    # interrupt after that point does not take the verdict away.
    called: bool = False
    reported: bool = False
    slept_at: str = ""


class LabPlugin:
    def __init__(
        self,
        *,
        wanted: list[str],
        listing: bool,
        guest: Guest,
        mode: str = "checks",
        vm_mode: str = "per-check",
        keep_on_failure: bool = False,
        machine_factory: MachineFactory | None = None,
        state_dir: Path = config.STATE_DIR,
        slept_at: Callable[[], str] = host_slept_at,
        repo_root: Path,
        checks_dir: Path,
        runs_root: Path,
        lock_path: Path | None = None,
        stream: IO[str] | None = None,
        run_preflight: Preflight = real_preflight,
        now: Callable[[], datetime] = lambda: datetime.now(timezone.utc),
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        self.wanted = wanted
        self.listing = listing
        self.guest = guest
        self.mode = mode
        self.vm_mode = vm_mode
        self.keep_on_failure = keep_on_failure
        self.machine_factory = machine_factory
        self.state_dir = state_dir
        self.slept_at = slept_at
        self.tart: Tart | None = None
        self.ssh_key: Path | None = None
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
        self.lock = RunLock(lock_path or host_lock_path())

    @property
    def saw_failure(self) -> bool:
        """Whether any check has pronounced a verdict against uDeck so far."""
        return any(
            record.outcome is Outcome.FAILED and record.called for record in self.records.values()
        )

    # --- Output ------------------------------------------------------------

    def say(self, text: str = "") -> None:
        # A message can carry anything a guest printed; escape what the
        # console cannot encode rather than lose the line.
        safe = text.encode("utf-8", "backslashreplace").decode("utf-8")
        try:
            print(safe, file=self.stream, flush=True)
        except (OSError, ValueError):
            pass

    def shown(self, path: Path) -> str:
        try:
            return str(path.relative_to(self.repo_root))
        except ValueError:
            return str(path)

    def stop(self, code: int) -> None:
        self.blocked = True
        self.exit_code = code

    def record_event(self, event: str, **fields: Any) -> None:
        if self.ledger is not None:
            self.ledger.write(event, **fields)

    def note(self, text: str) -> None:
        """Something the lab did or retried, for the console and the ledger."""
        self.say(text)
        self.record_event("lab", text=text)

    # --- Machines ----------------------------------------------------------

    def new_machine(self, label: str, source: str | None = None, display: str | None = None) -> Machine:
        """A machine for this run, named so the pre-flight can tell whose it is."""
        if self.run_dir is None:
            raise LabError("making a machine", "there is no run in progress")
        name = f"{config.VM_PREFIX}{self.run_dir.name}-{label}"
        source = source or self.guest.golden_vm
        if self.machine_factory is not None:
            return self.machine_factory(name=name, source=source, display=display, label=label)
        if self.tart is None or self.ssh_key is None:
            raise LabError("making a machine", "the pre-flight did not find Tart")
        return Machine(
            name=name,
            source=source,
            tart=self.tart,
            ssh=SSH(self.ssh_key, self.note),
            work_dir=self.run_dir / label,
            note=self.note,
            display=display,
        )

    def failed_in(self, scope: str, request: pytest.FixtureRequest) -> bool:
        """Whether any check that used this scope's machine did not pass."""
        if scope == "function":
            nodeids = [request.node.nodeid]
        elif scope == "module":
            prefix = f"{request.node.nodeid}::"
            nodeids = [n for n in self.records if n.startswith(prefix)]
        else:
            nodeids = list(self.records)
        return any(
            self.records[n].outcome is not Outcome.PASSED for n in nodeids if n in self.records
        )

    # --- Collection --------------------------------------------------------

    def pytest_collectreport(self, report: pytest.CollectReport) -> None:
        where = report.nodeid or "checks"
        if report.failed:
            self.collection_errors.append(f"{where}:\n{report.longreprtext}")
        elif report.skipped:
            # A skip at file level would silently drop a whole group — from the
            # run and from --list — and the run could still exit 0.
            reason = report.longrepr[2] if isinstance(report.longrepr, tuple) else report.longreprtext
            self.collection_errors.append(
                f"{where}: the whole file skipped itself ({reason}). A check file must "
                "not skip; a check that cannot run raises LabError, so it is reported."
            )

    def pytest_collection_modifyitems(
        self, session: pytest.Session, config: pytest.Config, items: list[pytest.Item]
    ) -> None:
        by_name: dict[str, pytest.Item] = {}
        for item in items:
            path = Path(str(item.path)).resolve()
            if path.parent != self.checks_dir:
                self.collection_errors.append(
                    f"{path}: check files live directly in {self.shown(self.checks_dir)}/, "
                    "not in a subdirectory"
                )
                continue
            function = getattr(item, "originalname", item.name)
            try:
                name = names.check_name(path.stem, function)
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

        try:
            holder = self.lock.acquire()
        except OSError as error:
            self.say(f"The lab could not take its run lock at {self.lock.path}: {error}")
            self.stop(EXIT_NOT_CHECKED)
            return
        if holder is not None:
            self.say(
                "Another lab run is in progress"
                + (f" (pid {holder})" if holder > 0 else "")
                + ". Wait for it to finish; the lab runs one at a time."
            )
            self.stop(EXIT_NOT_CHECKED)
            return

        try:
            self.run_dir = new_run_dir(self.runs_root, self.now())
        except OSError as error:
            self.say(f"The lab could not create its report directory under {self.runs_root}: {error}")
            self.stop(EXIT_NOT_CHECKED)
            return
        self.ledger = Ledger(self.run_dir / "ledger.jsonl")
        self.record_event(
            "run-start",
            argv=sys.argv[1:],
            guest=self.guest.key,
            base_image=self.guest.base_image,
            checks=list(self.names.values()),
            repo=_git_state(self.repo_root),
        )

        def note(text: str) -> None:
            # Written before the thing it describes is done, so a run cut off
            # half-way still says what it did to the host.
            self.say(text)
            self.record_event("host", text=text)

        try:
            assessment, about = self.run_preflight(self.guest, note)
        except Exception as error:  # noqa: BLE001 — reported, never swallowed
            assessment = preflight.Assessment(
                [preflight.Problem(f"The pre-flight itself failed: {error!r}.", "This is a bug in the lab.")],
                [],
            )
            about = {}
        self.record_event(
            "preflight",
            host=about,
            problems=[{"what": p.what, "todo": p.todo} for p in assessment.problems],
            notes=assessment.notes,
        )
        for line in assessment.notes:
            self.say(line)
        if not assessment.problems and self.mode != "bake":
            missing = golden.problem(self.guest, about.get("vms", []), self.state_dir)
            if missing:
                assessment.problems.append(missing)
        if not assessment.problems and self.machine_factory is None:
            try:
                self.tart = Tart(Path(about["tart"]), self.note)
                self.ssh_key = make_key(self.run_dir / "ssh")
            except (KeyError, TypeError, LabError) as error:
                assessment.problems.append(
                    preflight.Problem(f"Preparing the run failed: {error}.", "This is a bug in the lab.")
                )
        if assessment.problems:
            self.say("The lab cannot start:")
            for problem in assessment.problems:
                self.say(f"  • {problem.render()}")
            self.stop(EXIT_NOT_CHECKED)
            return

        try:
            mark_started(self.run_dir)
            removed, failures = prune_runs(self.runs_root, config.KEEP_RUNS, self.run_dir)
        except OSError as error:
            removed, failures = [], [f"could not look at old runs: {error}"]
        for failure in failures:
            self.say(f"Note: {failure}")
        self.record_event("pruned", removed=[p.name for p in removed], failures=failures)

        count = len(self.names)
        what = {"checks": "check", "selfcheck": "self-check", "bake": "bake"}[self.mode]
        self.say(
            f"Running {count} {what}{'' if count == 1 else 's'} on macOS {self.guest.key}"
            + (f", a machine {self.vm_mode.replace('-', ' ')}" if self.mode == "checks" else "")
            + f" — report in {self.shown(self.run_dir)}/"
        )

    def pytest_runtestloop(self, session: pytest.Session) -> bool | None:
        return True if self.blocked else None

    # --- Running -----------------------------------------------------------

    @pytest.fixture
    def check_dir(self, request: pytest.FixtureRequest) -> Path:
        """This check's directory in the run's report, for whatever it collects."""
        if self.run_dir is None:
            raise LabError("preparing the check's report directory", "there is no run directory")
        path = self.run_dir / self.names[request.node.nodeid]
        path.mkdir(exist_ok=True)
        return path

    @pytest.fixture
    def lab(self) -> "LabPlugin":
        """The run itself, for the bake and anything else that makes its own machines."""
        return self

    @pytest.fixture(scope=lambda fixture_name, config: VM_SCOPES[_lab(config).vm_mode])
    def machine(self, request: pytest.FixtureRequest) -> Any:
        """A clone of the golden image, booted to the desktop, removed afterwards.

        One per check, per group or per run, as --vm says. The check that uses it
        does not know which: in the chained modes it must find out what state the
        machine is in, never assume it.
        """
        scope = VM_SCOPES[self.vm_mode]
        if scope == "function":
            label = self.names[request.node.nodeid]
        elif scope == "module":
            label = names.group_of(names.check_name(Path(str(request.node.path)).stem, "check_x"))
        else:
            label = "run"
        machine = self.new_machine(label)
        try:
            machine.create()
            machine.boot()
        except BaseException:
            for problem in machine.close(keep=False):
                self.note(f"   ⚠️ cleaning up after a machine that did not start: {problem}")
            raise
        yield machine
        keep = self.keep_on_failure and self.failed_in(scope, request)
        problems = machine.close(keep=keep)
        if problems:
            raise LabError(f"cleaning up {machine.name}", "; ".join(problems))

    def pytest_runtest_logstart(self, nodeid: str, location: Any) -> None:
        self.records[nodeid] = CheckRecord(self.names[nodeid], self.clock(), slept_at=self.slept_at())

    @pytest.hookimpl(wrapper=True)
    def pytest_runtest_makereport(self, item: pytest.Item, call: pytest.CallInfo[None]) -> Any:
        report = yield
        record = self.records[item.nodeid]
        if call.when == "call":
            record.called = True
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
        if not excinfo.errisinstance(AssertionError):
            return False
        innermost = Path(str(excinfo.traceback[-1].path)).resolve()
        return innermost.parent == self.checks_dir and innermost.name.startswith("check_")

    def pytest_runtest_logfinish(self, nodeid: str, location: Any) -> None:
        self._report(self.records[nodeid], finished=True)

    def _report(self, record: CheckRecord, finished: bool) -> None:
        record.reported = True
        if record.outcome is not Outcome.PASSED and self.slept_at() != record.slept_at:
            # A sleeping Mac freezes the guest mid-step; nothing that went wrong
            # afterwards is evidence about uDeck.
            record.details.append(f"(originally: {record.outcome.words}: {record.reason})")
            record.outcome = Outcome.COULD_NOT_CHECK
            record.reason = "the Mac went to sleep during this check — run it again"
        seconds = self.clock() - record.started
        evidence = self.run_dir / record.name if self.run_dir else None
        if record.details and evidence is not None:
            try:
                evidence.mkdir(exist_ok=True)
                (evidence / "error.txt").write_text(
                    "\n\n".join(record.details), encoding="utf-8", errors="backslashreplace"
                )
            except OSError as error:
                self.lab_problems.append(f"{record.name}: could not save its evidence: {error}")

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

        self.record_event(
            "check",
            name=record.name,
            outcome=record.outcome.value,
            finished=finished,
            seconds=round(seconds, 1),
            reason=record.reason,
            cleanup_problem=record.cleanup_problem,
            evidence=self.shown(evidence) if evidence is not None and evidence.exists() else None,
        )

    def pytest_keyboard_interrupt(self, excinfo: pytest.ExceptionInfo[BaseException]) -> None:
        self.interrupted = True

    # --- The end -----------------------------------------------------------

    @pytest.hookimpl(wrapper=True)
    def pytest_sessionfinish(self, session: pytest.Session, exitstatus: int) -> Any:
        # A wrapper, so that everything else finishes first. After Ctrl-C the
        # fixtures of the interrupted check — the clone, its VM — are torn down
        # by pytest's own sessionfinish, and the lock must still be held and the
        # ledger still open while that happens.
        teardown_error: BaseException | None = None
        try:
            return (yield)
        except BaseException as error:  # noqa: BLE001 — recorded as a lab problem below
            teardown_error = error
            return None
        finally:
            self._finish_run(teardown_error)

    def _finish_run(self, teardown_error: BaseException | None) -> None:
        try:
            if self.run_dir is None:
                return
            if teardown_error is not None:
                problem = (
                    f"cleaning up after the run: {type(teardown_error).__name__}: "
                    f"{_first_line(teardown_error)}"
                )
                self.lab_problems.append(problem)
                self.say(f"⚠️ {problem}")
            if self.interrupted:
                self.say("Interrupted.")

            never_started: list[str] = []
            for nodeid, name in self.names.items():
                record = self.records.get(nodeid)
                if record is None:
                    never_started.append(name)
                    continue
                if record.reported:
                    continue
                # Cut off by Ctrl-C. A verdict already pronounced stands; so does a
                # pass whose cleanup was interrupted, which is a lab problem.
                if record.called and record.outcome is Outcome.PASSED:
                    record.cleanup_problem = record.cleanup_problem or "interrupted while cleaning up"
                elif not record.called and record.outcome is Outcome.PASSED:
                    record.outcome = Outcome.COULD_NOT_CHECK
                    record.reason = "interrupted before it finished"
                self._report(record, finished=False)

            outcomes = [record.outcome for record in self.records.values()]
            outcomes += [Outcome.COULD_NOT_CHECK] * len(never_started)
            seconds = self.clock() - self.started
            if not self.blocked:
                line = summary(outcomes, seconds)
                if never_started:
                    line += f" ({len(never_started)} never started: {', '.join(never_started)})"
                self.say(line)
            if self.ledger is not None and self.ledger.error:
                self.lab_problems.append(self.ledger.error)
            if not self.blocked:
                self.exit_code = exit_code(outcomes, len(self.lab_problems))
            self.record_event(
                "run-end",
                exit_code=self.exit_code,
                seconds=round(seconds, 1),
                interrupted=self.interrupted,
                never_started=never_started,
                lab_problems=self.lab_problems,
            )
        finally:
            if self.ssh_key is not None:
                # The key opens only this run's clones, which are gone; it goes too.
                shutil.rmtree(self.ssh_key.parent, ignore_errors=True)
            if self.ledger is not None:
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
                # --no-optional-locks: a plain `git status` refreshes the index and
                # takes index.lock, which would break a commit the operator is
                # making at that moment.
                ["git", "--no-optional-locks", "-C", str(root), *args],
                capture_output=True,
                text=True,
                errors="replace",
                timeout=10,
            )
        except (OSError, subprocess.TimeoutExpired):
            return None
        return done.stdout.strip() if done.returncode == 0 else None

    status = git("status", "--porcelain")
    return {"commit": git("rev-parse", "HEAD"), "dirty": bool(status) if status is not None else None}


def _lab(config: pytest.Config) -> LabPlugin:
    for plugin in config.pluginmanager.get_plugins():
        if isinstance(plugin, LabPlugin):
            return plugin
    raise LabError("finding the lab", "the lab's plugin is not loaded")
