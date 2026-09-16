"""What has to be true about the host before the lab starts a virtual machine.

Everything here is a question asked of the host — which Tart, which macOS, how
much disk and memory, which machines are running — and every problem comes back
with what to do about it. The only thing the pre-flight changes is the lab's own
orphans: a `tart run` for a `udeck-e2e-` machine that outlived the run that
started it. Nothing else on the host is touched: not its sleep settings, not
machines the lab did not create, not a clone kept for inspection.
"""

from __future__ import annotations

import json
import os
import re
import shutil
import signal
import subprocess
import time
from collections.abc import Callable
from dataclasses import dataclass, field
from pathlib import Path

from udeck_e2e import config
from udeck_e2e.config import Guest

# Every call out to another program gets a deadline; a hung `tart` is one of
# the lab's known failures.
COMMAND_DEADLINE_SECONDS = 60


@dataclass(frozen=True)
class Problem:
    what: str
    todo: str

    def render(self) -> str:
        return f"{self.what}\n    → {self.todo}"


@dataclass(frozen=True)
class VM:
    name: str
    running: bool


@dataclass
class HostFacts:
    tart: Path | None
    tart_version: str | None
    host_macos: str
    free_disk_gb: float
    memory_gb: float
    memory_pressure: int
    vms: list[VM]
    # Problems met while gathering the facts themselves.
    gathering: list[Problem] = field(default_factory=list)


@dataclass
class Assessment:
    problems: list[Problem]
    notes: list[str]


def assess(facts: HostFacts, guest: Guest, jobs: int = 1) -> Assessment:
    problems = list(facts.gathering)
    notes: list[str] = []

    if facts.tart is None:
        problems.append(
            Problem(
                "Tart was not found. The lab looks at $TART when it is set, and "
                "otherwise on PATH, then in ~/Applications/tart.app and "
                "/Applications/tart.app.",
                f"Install it with '{config.TART_INSTALL_HINT}', or point TART at the "
                "tart binary.",
            )
        )
    elif facts.tart_version != config.TART_VERSION:
        problems.append(
            Problem(
                f"Tart {facts.tart_version} is installed at {facts.tart}; the lab is "
                f"pinned to {config.TART_VERSION}.",
                f"Install Tart {config.TART_VERSION}, or update the pin in "
                "e2e/udeck_e2e/config.py as a change of its own after the lab passes "
                "with the new version.",
            )
        )

    host_major = _major(facts.host_macos)
    if host_major is not None and host_major < guest.min_host_major:
        problems.append(
            Problem(
                f"A macOS {guest.key} guest needs a macOS {guest.min_host_major} host; "
                f"this Mac runs {facts.host_macos}.",
                "Run the checks on an older guest with --guest.",
            )
        )

    need_disk = config.MIN_FREE_DISK_GB_PER_VM * jobs
    if facts.free_disk_gb < need_disk:
        problems.append(
            Problem(
                f"Only {facts.free_disk_gb:.0f} GB is free where Tart keeps its machines; "
                f"the lab wants {need_disk} GB.",
                "Free some space. 'e2e/run.sh cleanup' removes clones the lab kept "
                "or left behind.",
            )
        )

    need_memory = config.VM_MEMORY_GB * jobs + config.HOST_MEMORY_RESERVE_GB
    # Zero means the size could not be read, which is already a gathering problem.
    if 0 < facts.memory_gb < need_memory:
        problems.append(
            Problem(
                f"This Mac has {facts.memory_gb:.0f} GB of memory; {jobs} machine(s) at "
                f"{config.VM_MEMORY_GB} GB plus {config.HOST_MEMORY_RESERVE_GB} GB for "
                f"the host needs {need_memory} GB.",
                "Run one machine at a time.",
            )
        )
    if facts.memory_pressure >= config.REFUSE_AT_MEMORY_PRESSURE:
        problems.append(
            Problem(
                "macOS reports critical memory pressure.",
                "Close something memory-hungry and run the lab again.",
            )
        )

    ours = [vm for vm in facts.vms if vm.name.startswith(config.VM_PREFIX)]
    foreign_running = [vm.name for vm in facts.vms if vm.running and vm not in ours]
    if foreign_running:
        problems.append(
            Problem(
                "Another virtual machine is running: " + ", ".join(foreign_running) + ". "
                "macOS runs at most two macOS guests at once, and the lab does not stop "
                "machines it did not create.",
                "Stop it, or run the lab once it is done.",
            )
        )
    still_running = [vm.name for vm in ours if vm.running]
    if still_running:
        problems.append(
            Problem(
                "A lab machine is still running after its orphaned process was stopped: "
                + ", ".join(still_running)
                + ".",
                "Run 'tart stop <name>' for it, then run the lab again.",
            )
        )

    kept = [vm.name for vm in ours if vm.name.startswith(config.KEPT_PREFIX)]
    golden = {g.golden_vm for g in config.GUESTS.values()}
    leftover = [
        vm.name for vm in ours if not vm.running and vm.name not in golden and vm.name not in kept
    ]
    if kept:
        notes.append(
            f"{len(kept)} clone(s) kept for inspection: {', '.join(kept)}. "
            "'e2e/run.sh cleanup' removes them."
        )
    if leftover:
        notes.append(
            f"{len(leftover)} clone(s) left behind by an interrupted run: "
            f"{', '.join(leftover)}. 'e2e/run.sh cleanup' removes them."
        )

    return Assessment(problems, notes)


def _major(version: str) -> int | None:
    head = version.split(".", 1)[0]
    return int(head) if head.isdigit() else None


# --- Orphans ---------------------------------------------------------------

_TART_RUN = re.compile(r"(?:^|/)tart run (" + re.escape(config.VM_PREFIX) + r"\S+)(?:\s|$)")


def find_orphans(ps_output: str, own_pid: int) -> list[tuple[int, str]]:
    """`(pid, machine)` for each `tart run` of a lab machine.

    `ps_output` is `ps -axww -o pid=,ucomm=,args=`. The process's own name has
    to be `tart`: matching the arguments alone would also catch a shell whose
    command line merely mentions `tart run udeck-e2e-…`, and the pre-flight
    must never signal a process that is not a lab machine.

    Called only while holding the run lock, so any such process belongs to a
    run that is no longer alive. Clones kept for inspection are shut down by
    the run that keeps them and never appear here.
    """
    orphans = []
    for line in ps_output.splitlines():
        fields = line.split(None, 2)
        if len(fields) < 3 or not fields[0].isdigit():
            continue
        pid, name, args = int(fields[0]), fields[1], fields[2]
        if name != "tart" or pid == own_pid:
            continue
        match = _TART_RUN.search(args)
        if match:
            orphans.append((pid, match.group(1)))
    return orphans


def stop_orphans(
    orphans: list[tuple[int, str]],
    send: Callable[[int, int], None] = os.kill,
    alive: Callable[[int], bool] | None = None,
    sleep: Callable[[float], None] = time.sleep,
    clock: Callable[[], float] = time.monotonic,
    grace: float = config.ORPHAN_TERM_GRACE_SECONDS,
) -> list[str]:
    """SIGTERM each orphan, SIGKILL whatever is left after `grace`. Says what it did."""
    alive = alive or _alive
    report = []
    for pid, name in orphans:
        try:
            send(pid, signal.SIGTERM)
        except ProcessLookupError:
            continue
        deadline = clock() + grace
        while alive(pid) and clock() < deadline:
            sleep(0.5)
        if alive(pid):
            try:
                send(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            report.append(f"Killed the orphaned 'tart run {name}' (pid {pid}); it ignored SIGTERM.")
        else:
            report.append(f"Stopped the orphaned 'tart run {name}' (pid {pid}).")
    return report


def _alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


# --- Gathering -------------------------------------------------------------


TART_APP_DIRS = (Path.home() / "Applications", Path("/Applications"))


def find_tart(
    env: dict[str, str] | None = None, app_dirs: tuple[Path, ...] = TART_APP_DIRS
) -> Path | None:
    """TART if set, then PATH, then the two places the Tart app is installed."""
    env = os.environ if env is None else env
    if env.get("TART"):
        path = Path(env["TART"])
        return path if path.is_file() else None
    on_path = shutil.which("tart", path=env.get("PATH", ""))
    if on_path:
        return Path(on_path)
    for app in app_dirs:
        binary = app / "tart.app" / "Contents" / "MacOS" / "tart"
        if binary.is_file():
            return binary
    return None


def parse_tart_list(text: str) -> list[VM]:
    return [VM(name=entry["Name"], running=bool(entry["Running"])) for entry in json.loads(text)]


def run_command(args: list[str], step: str) -> tuple[str | None, Problem | None]:
    try:
        done = subprocess.run(
            args, capture_output=True, text=True, timeout=COMMAND_DEADLINE_SECONDS, check=False
        )
    except subprocess.TimeoutExpired:
        return None, Problem(
            f"{step}: '{' '.join(args)}' did not finish in {COMMAND_DEADLINE_SECONDS}s.",
            "If it is tart that hangs, quit any Tart processes and run the lab again.",
        )
    except OSError as error:
        return None, Problem(f"{step}: could not run '{args[0]}': {error}.", "Check it is installed.")
    if done.returncode != 0:
        said = (done.stderr or done.stdout).strip().splitlines()
        return None, Problem(
            f"{step}: '{' '.join(args)}' exited {done.returncode}"
            + (f": {said[-1]}" if said else "."),
            "Run the command by hand to see why.",
        )
    return done.stdout, None


def gather() -> HostFacts:
    gathering: list[Problem] = []

    tart = find_tart()
    tart_version = None
    vms: list[VM] = []
    if tart is not None:
        out, problem = run_command([str(tart), "--version"], "asking Tart its version")
        tart_version = out.strip() if out else None
        gathering += [problem] if problem else []
        out, problem = run_command([str(tart), "list", "--format", "json"], "listing machines")
        if out is not None:
            try:
                vms = parse_tart_list(out)
            except (ValueError, KeyError, TypeError) as error:
                gathering.append(
                    Problem(
                        f"listing machines: 'tart list --format json' printed something the "
                        f"lab cannot read ({error}).",
                        "Check that the pinned Tart version is installed.",
                    )
                )
        gathering += [problem] if problem else []

    out, problem = run_command(["/usr/bin/sw_vers", "-productVersion"], "reading the macOS version")
    host_macos = out.strip() if out else "unknown"
    gathering += [problem] if problem else []

    tart_home = Path(os.environ.get("TART_HOME") or Path.home() / ".tart")
    free = shutil.disk_usage(tart_home if tart_home.exists() else Path.home()).free / 1e9

    out, problem = run_command(["/usr/sbin/sysctl", "-n", "hw.memsize"], "reading memory size")
    memory_gb = int(out) / 2**30 if out and out.strip().isdigit() else 0.0
    gathering += [problem] if problem else []

    out, problem = run_command(
        ["/usr/sbin/sysctl", "-n", "kern.memorystatus_vm_pressure_level"], "reading memory pressure"
    )
    pressure = int(out) if out and out.strip().isdigit() else 1
    gathering += [problem] if problem else []

    return HostFacts(
        tart=tart,
        tart_version=tart_version,
        host_macos=host_macos,
        free_disk_gb=free,
        memory_gb=memory_gb,
        memory_pressure=pressure,
        vms=vms,
        gathering=gathering,
    )


def process_table() -> tuple[str | None, Problem | None]:
    return run_command(["/bin/ps", "-axww", "-o", "pid=,ucomm=,args="], "listing processes")
