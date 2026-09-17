"""What has to be true about the host before the lab starts a virtual machine.

Everything here is a question asked of the host — which Tart, which macOS, how
much disk and memory, which machines are running — and every problem comes back
with what to do about it. The only thing the pre-flight changes is the lab's own
orphans: a `tart run` of a lab clone, started by this user, that outlived the run
that started it. Nothing else on the host is touched: not its sleep settings,
not machines the lab did not create, not a kept clone or a golden image someone
opened by hand, not another user's processes.
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


@dataclass(frozen=True)
class Process:
    """One line of `ps`, as much of it as the pre-flight needs."""

    pid: int
    uid: int
    # `lstart`, the start time. With the pid it identifies a process: a pid can
    # be reused by the time a signal is sent, a pid and a start time cannot.
    started: str
    name: str
    args: str

    @property
    def runs_a_machine(self) -> bool:
        return self.name == "tart" and _TART_RUN_ANY.search(self.args) is not None

    @property
    def lab_machine(self) -> str | None:
        """The lab clone this process runs, if it is `tart run udeck-e2e-…` exactly.

        The name has to follow `run` directly, which is how the lab starts its
        machines; anything written differently is not recognised as the lab's
        and is never signalled.
        """
        if self.name != "tart":
            return None
        match = _TART_RUN_LAB.search(self.args)
        return match.group(1) if match else None


_TART_RUN_ANY = re.compile(r"(?:^|/)tart run(?:\s|$)")
_TART_RUN_LAB = re.compile(r"(?:^|/)tart run (" + re.escape(config.VM_PREFIX) + r"\S+)(?:\s|$)")


def protected(name: str) -> bool:
    """Lab machines a person may have opened on purpose: never an orphan."""
    golden = {g.golden_vm for g in config.GUESTS.values()}
    return name.startswith(config.KEPT_PREFIX) or name in golden


@dataclass
class HostFacts:
    tart: Path | None
    tart_version: str | None
    host_macos: str
    free_disk_gb: float
    memory_gb: float
    memory_pressure: int
    vms: list[VM]
    # `tart run` processes of any user, whatever Tart home they use.
    machines: list[Process] = field(default_factory=list)
    # Virtualization.framework machines of any app, Tart's included.
    framework_machines: int = 0
    # Whether other machines on the network can reach a running machine's VNC
    # server, as far as the firewall says; None when it could not be read, and
    # then `firewall_unreadable` says what went wrong.
    vnc_reachable_from_network: bool | None = None
    firewall_unreadable: str = ""
    uid: int = field(default_factory=os.getuid)
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

    # Running machines, from both sources: `tart list` knows names in this Tart
    # home, `ps` sees every `tart run` on the host — another Tart home, another
    # user — and every one of them counts against macOS's two-guest limit.
    running: dict[str, str] = {}
    for vm in facts.vms:
        if vm.running:
            running[vm.name] = "this user"
    for process in facts.machines:
        name = process.lab_machine or _machine_name(process.args)
        owner = "this user" if process.uid == facts.uid else f"uid {process.uid}"
        running.setdefault(name, owner)

    foreign = sorted(
        f"{name} ({owner})"
        for name, owner in running.items()
        if not name.startswith(config.VM_PREFIX) or owner != "this user"
    )
    opened = sorted(
        name
        for name, owner in running.items()
        if owner == "this user" and name.startswith(config.VM_PREFIX) and protected(name)
    )
    stuck = sorted(
        name
        for name, owner in running.items()
        if owner == "this user" and name.startswith(config.VM_PREFIX) and not protected(name)
    )
    if foreign:
        problems.append(
            Problem(
                "Another virtual machine is running: " + ", ".join(foreign) + ". "
                "macOS runs at most two macOS guests at once, and the lab does not stop "
                "machines it did not create.",
                "Stop it, or run the lab once it is done.",
            )
        )
    if opened:
        problems.append(
            Problem(
                "A kept clone or a golden image is running: " + ", ".join(opened) + ". "
                "The lab never stops these; somebody opened them on purpose.",
                "Shut it down from inside, or 'tart stop <name>', when you are done with it.",
            )
        )
    if stuck:
        problems.append(
            Problem(
                "A lab machine is still running after its orphaned process was stopped: "
                + ", ".join(stuck)
                + ".",
                "Run 'tart stop <name>' for it, then run the lab again.",
            )
        )

    others = facts.framework_machines - len(facts.machines)
    if others > 0:
        # Not a refusal: Docker Desktop's Linux machine is one of these, and only
        # macOS guests count against the limit.
        notes.append(
            f"{others} virtual machine(s) of another app are running (Docker Desktop, UTM, "
            "Parallels…). If one is a macOS guest, macOS may refuse the lab's machine."
        )

    if facts.tart is not None and facts.vnc_reachable_from_network is not False:
        notes.append(
            "While a machine runs, Tart shares its screen over VNC on every network interface, "
            "not only on this Mac, behind a password made for that machine (VNC checks its "
            "first 8 characters). "
            + (
                "The firewall lets tart in, so the local network can reach it. "
                if facts.vnc_reachable_from_network
                else f"Whether the firewall lets tart in could not be read ({facts.firewall_unreadable}). "
                if facts.firewall_unreadable
                else "Whether the firewall lets tart in could not be read. "
            )
            + "To keep it to this Mac, block incoming connections for tart in System Settings "
            "→ Network → Firewall → Options."
        )

    ours = [vm for vm in facts.vms if vm.name.startswith(config.VM_PREFIX)]
    kept = [vm.name for vm in ours if vm.name.startswith(config.KEPT_PREFIX)]
    leftover = [vm.name for vm in ours if not vm.running and not protected(vm.name)]
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


def _machine_name(args: str) -> str:
    """Best effort at the machine a `tart run` names, options allowed before it."""
    after = _TART_RUN_ANY.split(args, maxsplit=1)[-1].split()
    names = [word for word in after if not word.startswith("-")]
    return names[0] if names else "(unnamed)"


# --- Processes and orphans ---------------------------------------------------

PS_COLUMNS = "pid=,uid=,lstart=,ucomm=,args="


def parse_ps(text: str) -> list[Process]:
    """Parse `ps -axww -o pid=,uid=,lstart=,ucomm=,args=` run with LC_ALL=C.

    `lstart` is five words in the C locale ("Wed Sep 16 17:04:32 2026").
    """
    processes = []
    for line in text.splitlines():
        fields = line.split(None, 8)
        if len(fields) < 9 or not fields[0].isdigit() or not fields[1].isdigit():
            continue
        processes.append(
            Process(
                pid=int(fields[0]),
                uid=int(fields[1]),
                started=" ".join(fields[2:7]),
                name=fields[7],
                args=fields[8],
            )
        )
    return processes


def find_orphans(processes: list[Process], uid: int, own_pid: int) -> list[Process]:
    """This user's `tart run udeck-e2e-…` processes, except kept and golden machines.

    Called only while holding the run lock, which is one per user on the host,
    so any such process belongs to a run that is no longer alive.
    """
    return [
        p
        for p in processes
        if p.uid == uid
        and p.pid != own_pid
        and p.lab_machine is not None
        and not protected(p.lab_machine)
    ]


def stop_orphans(
    orphans: list[Process],
    note: Callable[[str], None],
    identify: Callable[[int], Process | None],
    send: Callable[[int, int], None] = os.kill,
    sleep: Callable[[float], None] = time.sleep,
    clock: Callable[[], float] = time.monotonic,
    grace: float = config.ORPHAN_TERM_GRACE_SECONDS,
) -> None:
    """SIGTERM each orphan, SIGKILL whatever is left after `grace`.

    `note` hears about every signal *before* it is sent, so a run interrupted
    half-way still leaves a record of what it did to the host. Before each
    signal the process is identified again, and a pid that now belongs to a
    different process — or to nobody — is left alone.
    """
    for orphan in orphans:
        name = orphan.lab_machine
        if identify(orphan.pid) != orphan:
            continue
        note(f"Stopping the orphaned 'tart run {name}' (pid {orphan.pid}) with SIGTERM.")
        if not _signal(orphan, signal.SIGTERM, send, note):
            continue
        deadline = clock() + grace
        while identify(orphan.pid) == orphan and clock() < deadline:
            sleep(0.5)
        if identify(orphan.pid) != orphan:
            note(f"The orphaned 'tart run {name}' (pid {orphan.pid}) has exited.")
            continue
        note(
            f"The orphaned 'tart run {name}' (pid {orphan.pid}) ignored SIGTERM for "
            f"{grace:.0f}s; sending SIGKILL."
        )
        _signal(orphan, signal.SIGKILL, send, note)


def _signal(
    orphan: Process, sig: int, send: Callable[[int, int], None], note: Callable[[str], None]
) -> bool:
    try:
        send(orphan.pid, sig)
    except ProcessLookupError:
        return False
    except PermissionError:
        note(f"Not allowed to signal pid {orphan.pid}; leaving it alone.")
        return False
    return True


def identify(pid: int) -> Process | None:
    """The process that has `pid` right now, or None."""
    out, _ = run_command(["/bin/ps", "-ww", "-o", PS_COLUMNS, "-p", str(pid)], "identifying a process")
    if not out:
        return None
    found = [p for p in parse_ps(out) if p.pid == pid]
    return found[0] if found else None


def process_table() -> tuple[list[Process], Problem | None]:
    out, problem = run_command(["/bin/ps", "-axww", "-o", PS_COLUMNS], "listing processes")
    return (parse_ps(out) if out else []), problem


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


def run_command(
    args: list[str], step: str, seconds: float = COMMAND_DEADLINE_SECONDS
) -> tuple[str | None, Problem | None]:
    try:
        done = subprocess.run(
            args,
            capture_output=True,
            text=True,
            # A process list can hold any bytes at all; one argument that is not
            # UTF-8 must not stop the lab.
            errors="replace",
            timeout=seconds,
            check=False,
            # `ps` prints start times in the locale's words; the parser reads C.
            env={**os.environ, "LC_ALL": "C"},
        )
    except subprocess.TimeoutExpired:
        return None, Problem(
            f"{step}: '{' '.join(args)}' did not finish in {seconds:.0f}s.",
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


def gather(machines: list[Process]) -> HostFacts:
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
    try:
        free = shutil.disk_usage(tart_home if tart_home.is_dir() else Path.home()).free / 1e9
    except OSError as error:
        free = 0.0
        gathering.append(
            Problem(f"reading free disk space: {error}.", "Check that TART_HOME is a directory.")
        )

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
        machines=machines,
        gathering=gathering,
    )


FIREWALL = "/usr/libexec/ApplicationFirewall/socketfilterfw"

# Three local reads; a second each is generous, and the pre-flight must not sit
# here while a person waits for their machines.
FIREWALL_SECONDS = 10

_FIREWALL_STATE = re.compile(r"\(State = (\d+)\)")


def reachable_through_firewall(global_state: str, block_all: str, apps: list[str]) -> bool | None:
    """Whether the firewall lets other machines connect to Tart, from `socketfilterfw`'s words.

    Its read-only answers: `--getglobalstate` ("Firewall is enabled. (State = 1)";
    0 is off, 2 blocks everything), `--getblockall` ("… block all state set to
    enabled."), and `--getappblocked <path>` ("Incoming connection to … is
    permitted."). The last is asked for more than one path — the firewall's own
    list holds Tart as the `.app` bundle while the lab runs the binary inside it —
    and one "is blocked" among them settles it. `--getappblocked` answers
    "permitted" for a path it has never heard of too, which is the truth while
    macOS allows signed software in by itself. None when the words are not ones
    the lab knows.
    """
    state = _FIREWALL_STATE.search(global_state)
    if state is None:
        return None
    if state.group(1) == "0":
        return True
    if state.group(1) == "2" or "set to enabled" in block_all:
        return False
    if any("is blocked" in app for app in apps):
        return False
    if any("is permitted" in app for app in apps):
        return True
    return None


def firewall_paths(tart: Path) -> list[Path]:
    """The paths the firewall may hold Tart under: the binary, and its .app bundle."""
    binary = tart.resolve()
    bundle = next((p for p in binary.parents if p.suffix == ".app"), None)
    return [binary] if bundle is None else [binary, bundle]


def firewall_lets_tart_in(tart: Path) -> tuple[bool | None, str]:
    """(what the firewall says, why it could not be read)."""
    answers = []
    for args in (["--getglobalstate"], ["--getblockall"]):
        out, problem = run_command([FIREWALL, *args], "asking the firewall about Tart", FIREWALL_SECONDS)
        if problem is not None:
            return None, problem.what
        answers.append(out or "")
    apps = []
    for path in firewall_paths(tart):
        out, problem = run_command(
            [FIREWALL, "--getappblocked", str(path)], "asking the firewall about Tart", FIREWALL_SECONDS
        )
        if problem is not None:
            return None, problem.what
        apps.append(out or "")
    return reachable_through_firewall(answers[0], answers[1], apps), ""


FRAMEWORK_MACHINE = "/com.apple.Virtualization.VirtualMachine.xpc/"


def run(guest: Guest, note: Callable[[str], None]) -> tuple[Assessment, HostFacts]:
    """The whole pre-flight: stop the lab's orphans, then look at the host.

    Needs the run lock held.
    """
    processes, problem = process_table()
    stop_orphans(find_orphans(processes, os.getuid(), os.getpid()), note, identify)
    if problem is None:
        processes, problem = process_table()
    facts = gather([p for p in processes if p.runs_a_machine])
    facts.framework_machines = sum(1 for p in processes if FRAMEWORK_MACHINE in p.args)
    if facts.tart is not None:
        facts.vnc_reachable_from_network, facts.firewall_unreadable = firewall_lets_tart_in(facts.tart)
    if problem:
        facts.gathering.append(problem)
    return assess(facts, guest), facts
