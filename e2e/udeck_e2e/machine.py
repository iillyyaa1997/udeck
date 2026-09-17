"""One throwaway virtual machine: made, booted, rebooted, shut down, removed.

This is the shared piece every check stands on, so it is also where the lab
checks itself: a machine that does not come back is reported by the step that
failed — "waiting for SSH after the reboot" — and becomes "could not check",
never a verdict on uDeck.
"""

from __future__ import annotations

import re
import signal
import time
from collections.abc import Callable
from pathlib import Path
from typing import IO, Any

from udeck_e2e import config, interrupts
from udeck_e2e.errors import LabError
from udeck_e2e.guest import SSH
from udeck_e2e.tart import VM_LIMIT_TEXT, Tart
from udeck_e2e.vnc import Address, Screen, find_address, without_password

Note = Callable[[str], None]

VM_LIMIT_ADVICE = (
    "macOS refused to start another virtual machine because it counts two already "
    "running, and the pre-flight found none of the lab's. Tart has a known leak "
    "(openai/tart#1217, #445, #967) where macOS keeps counting machines that are "
    "gone. The only cure reported is restarting the Mac — when you choose to; the "
    "lab never restarts it."
)


class Machine:
    def __init__(
        self,
        *,
        name: str,
        source: str,
        tart: Tart,
        ssh: SSH,
        work_dir: Path,
        note: Note,
        display: str | None = None,
        screen_factory: Callable[[Address], Screen] = Screen,
        sleep: Callable[[float], None] = time.sleep,
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        self.name = name
        self.source = source
        self.tart = tart
        self.ssh = ssh
        self.work_dir = work_dir
        self.note = note
        self.display = display
        self.process: Any = None
        self.created = False
        # The machine's VNC server, known once it has booted.
        self.screen: Screen | None = None
        self._screen_factory = screen_factory
        # Where the Mac's sleep marker stood when this machine was made, so a
        # sleep during any check that shared it is noticed (see the plugin).
        self.slept_at = ""
        self._log: IO[bytes] | None = None
        self._log_start = 0
        self._sleep = sleep
        self._clock = clock

    # --- Coming up -----------------------------------------------------------

    def create(self) -> None:
        # Marked before cloning: a clone interrupted or failed half-way may still
        # have left the machine in Tart's store, and close() must try to delete it.
        self.created = True
        self.tart.clone(self.source, self.name)
        # Clones of one image share a serial number, and with it an identity
        # macOS services key on; each clone gets its own.
        options = ["--random-serial"]
        if self.display:
            options += ["--display", self.display, "--no-display-refit"]
        self.tart.set(self.name, *options)

    def boot(self) -> None:
        """Start it and wait until a person could use it: SSH up, desktop shown."""
        for attempt in range(1, config.KNOWN_FAILURE_RETRIES + 2):
            self._start()
            try:
                address = self._wait_for_address()
                break
            except _RefusedByLimit:
                if attempt > config.KNOWN_FAILURE_RETRIES:
                    raise LabError(f"starting {self.name}", VM_LIMIT_ADVICE) from None
                self.note(
                    f"   retry {attempt}/{config.KNOWN_FAILURE_RETRIES}: macOS refused {self.name} "
                    f"(virtual machine limit); waiting {config.VM_LIMIT_RETRY_WAIT_SECONDS}s"
                )
                self._sleep(config.VM_LIMIT_RETRY_WAIT_SECONDS)
        self._wait_for_agent()
        self._install_key()
        self.ssh.host = address
        self.ssh.wait_up(f"waiting for SSH on {self.name}", alive=self.ensure_running)
        self.wait_for_desktop(f"waiting for {self.name}'s desktop")
        self._find_screen()
        self.wait_for_screen(f"waiting for {self.name}'s screen")

    def _start(self) -> None:
        self.work_dir.mkdir(parents=True, exist_ok=True)
        if self._log is not None:
            self._log.close()
        self._log = open(self.work_dir / "tart-run.log", "ab")
        # One log for all attempts, read from where this attempt began: the limit
        # message of a refused first attempt must not explain a later, different
        # failure.
        self._log_start = self._log.tell()
        self.process = self.tart.start(self.name, self._log)

    def _log_text(self) -> str:
        try:
            with open(self.work_dir / "tart-run.log", "rb") as log:
                log.seek(self._log_start)
                return log.read().decode(errors="replace")
        except OSError:
            return ""

    def _last_log_line(self) -> str:
        """What `tart run` said last, without the password.

        Tart prints the VNC address and, at a clean end, one line more; a machine
        that dies otherwise leaves that address as the last line — and this line
        is quoted into the report, the console and the ledger.
        """
        lines = self._log_text().strip().splitlines()
        return without_password(lines[-1]) if lines else "(no output)"

    def ensure_running(self, step: str) -> None:
        """Raise at once if `tart run` has exited, with what it said."""
        if self.process is not None and self.process.poll() is not None:
            raise LabError(
                step,
                f"the machine stopped: 'tart run' {ended(self.process.returncode)}: {self._last_log_line()}",
            )

    def _wait_for_address(self) -> str:
        step = f"waiting for {self.name} to get an address"
        deadline = self._clock() + config.BOOT_IP_SECONDS
        while True:
            if self.process.poll() is not None:
                log = self._log_text()
                if VM_LIMIT_TEXT in log:
                    raise _RefusedByLimit()
                raise LabError(step, f"'tart run' {ended(self.process.returncode)}: {self._last_log_line()}")
            address = self.tart.ip(self.name)
            if address:
                return address
            if self._clock() >= deadline:
                raise LabError(step, f"no address within {config.BOOT_IP_SECONDS}s")
            self._sleep(2)

    def _wait_for_agent(self) -> None:
        step = f"waiting for the guest agent on {self.name}"
        deadline = self._clock() + config.AGENT_SECONDS
        while True:
            self.ensure_running(step)
            # Until the agent is up, `tart exec` does not fail — it waits (measured:
            # more than 30 s on a first boot). A single attempt that runs out of
            # time is "not yet", not an answer.
            try:
                done = self.tart.exec(self.name, ["/usr/bin/true"], step, seconds=20)
                if done.returncode == 0:
                    return
                lines = (done.stderr or done.stdout).strip().splitlines()
                last = lines[-1] if lines else f"exit {done.returncode}"
            except LabError as error:
                last = error.reason
            if self._clock() >= deadline:
                raise LabError(step, f"no answer within {config.AGENT_SECONDS}s; last: {last}")
            self._sleep(2)

    def _install_key(self) -> None:
        public = Path(f"{self.ssh.key}.pub").read_text().strip()
        script = (
            "umask 077; mkdir -p ~/.ssh && "
            f"printf '%s\\n' '{public}' >> ~/.ssh/authorized_keys"
        )
        done = self.tart.exec(
            self.name, ["/bin/bash", "-c", script], f"giving {self.name} this run's SSH key", seconds=60
        )
        if done.returncode != 0:
            lines = (done.stderr or done.stdout).strip().splitlines()
            raise LabError(f"giving {self.name} this run's SSH key", lines[-1] if lines else f"exit {done.returncode}")

    def wait_for_desktop(self, step: str) -> None:
        """Until the user is logged in at the console and Finder is running."""
        deadline = self._clock() + config.DESKTOP_SECONDS
        while True:
            self.ensure_running(step)
            try:
                done = self.ssh.run(
                    "stat -f %Su /dev/console; pgrep -x Finder >/dev/null && echo finder",
                    step,
                    seconds=30,
                    check=False,
                )
                words = done.stdout.split()
                ready = done.returncode == 0 and words[:1] == [config.GUEST_USER] and "finder" in words
            except LabError as error:
                words, ready = [error.reason], False
            if ready:
                return
            if self._clock() >= deadline:
                raise LabError(step, f"not at the desktop within {config.DESKTOP_SECONDS}s: {' '.join(words)}")
            self._sleep(2)

    # --- Rebooting -----------------------------------------------------------

    def reboot(self) -> None:
        """Restart from inside, the way a person would, and wait until it is usable again.

        Proved by the boot session changing — a UUID macOS makes on every boot —
        not by the boot time, which a clock change moves without a restart.
        """
        before = self.ssh.boot_session()
        self.ssh.run("sudo -n shutdown -r now", f"restarting {self.name}", seconds=30, check=False)
        step = f"waiting for {self.name} to come back after the restart"
        deadline = self._clock() + config.REBOOT_SECONDS
        while True:
            self.ensure_running(step)
            address = self.tart.ip(self.name)
            if address:
                self.ssh.host = address
                try:
                    now = self.ssh.boot_session()
                except LabError:
                    now = before
                if now != before:
                    break
            if self._clock() >= deadline:
                raise LabError(step, f"the guest did not restart within {config.REBOOT_SECONDS}s")
            self._sleep(3)
        self.wait_for_desktop(f"waiting for {self.name}'s desktop after the restart")
        # The agent starts late after a restart too, and the lab reads the screen through it.
        self._wait_for_agent()
        self.wait_for_screen(f"waiting for {self.name}'s screen after the restart")

    # --- The screen and the pointer -----------------------------------------

    def _find_screen(self) -> None:
        address = find_address(self._log_text())
        if address is None:
            raise LabError(f"finding {self.name}'s screen", "'tart run' did not print the address of its VNC server")
        self.screen = self._screen_factory(address)

    def wait_for_screen(self, step: str) -> None:
        """Until a screenshot is the golden size and not one flat colour."""
        screen = self._screen_for(step)
        screen.wait_for_screen(self.work_dir / ".screen-probe.png", step, alive=self.ensure_running)

    def screenshot(self, directory: Path, step: str) -> Path:
        """The screen now, saved in `directory` as `<NN>-<step>.png`, numbered in the order taken.

        Screenshots are evidence for a person reading the report, never a verdict.
        """
        what = f"taking the screenshot '{step}'"
        screen = self._screen_for(what)
        try:
            directory.mkdir(parents=True, exist_ok=True)
            path = directory / f"{next_number(directory):02d}-{slug(step)}.png"
        except OSError as error:
            raise LabError(what, f"could not prepare {directory}: {error}") from None
        self._on_screen(what, lambda: screen.capture(path, what))
        return path

    def move_pointer(self, x: int, y: int, step: str) -> None:
        """Put the pointer at (x, y): pixels from the screen's top-left corner, as in a screenshot."""
        what = f"moving the pointer {step}"
        screen = self._screen_for(what)
        if not (0 <= x < config.SCREEN_WIDTH and 0 <= y < config.SCREEN_HEIGHT):
            raise LabError(what, f"({x}, {y}) is off the {config.SCREEN_WIDTH}×{config.SCREEN_HEIGHT} screen")
        self._on_screen(what, lambda: screen.move(x, y, what))

    def _screen_for(self, step: str) -> Screen:
        if self.screen is None:
            raise LabError(step, f"{self.name} has not booted, so the lab does not know its screen yet")
        return self.screen

    def _on_screen(self, step: str, action: Callable[[], Any]) -> Any:
        self.ensure_running(step)
        try:
            return action()
        except LabError:
            # A VNC connection refused because Tart itself went away is about the
            # machine, and that is the story to tell.
            self.ensure_running(step)
            raise

    # --- Going away ----------------------------------------------------------

    def shut_down(self) -> str | None:
        """Shut down from inside and wait for `tart run` to exit. Returns a problem, if any.

        `tart stop` is a power-off: it once lost a login item macOS had not yet
        written to disk. So it is used only after a minute of silence, and then
        reported.
        """
        if self.process is None or self.process.poll() is not None:
            return None
        if self.ssh.host is None:
            # It never got as far as SSH, so there is no inside to ask.
            problem = f"{self.name} never answered over SSH, so it was stopped with 'tart stop' (a power-off)"
        else:
            try:
                self.ssh.run("sudo -n shutdown -h now", f"shutting {self.name} down", seconds=30, check=False)
            except LabError:
                pass
            if self._wait_exit(config.SHUTDOWN_SECONDS):
                return None
            problem = (
                f"{self.name} did not shut down from inside within {config.SHUTDOWN_SECONDS}s, "
                "so it was stopped with 'tart stop' (a power-off)"
            )
        try:
            self.tart.stop(self.name)
        except LabError as error:
            self.note(f"   {error}")
        if not self._wait_exit(30):
            self.process.kill()
            self._wait_exit(10)
            problem += "; 'tart run' then had to be killed"
        return problem

    def _wait_exit(self, seconds: float) -> bool:
        deadline = self._clock() + seconds
        while self.process.poll() is None:
            if self._clock() >= deadline:
                return False
            self._sleep(1)
        return True

    def close(self, keep: bool) -> list[str]:
        """Shut down, then delete the clone — or keep it, renamed, for a look.

        Every step is attempted even if an earlier one failed; what went wrong
        comes back as a list, empty when all is well.
        """
        with interrupts.deferred(self.note, f"cleaning up {self.name}"):
            return self._close(keep)

    def _close(self, keep: bool) -> list[str]:
        problems = []
        try:
            problem = self.shut_down()
            if problem:
                problems.append(problem)
        except Exception as error:  # noqa: BLE001 — reported by the caller
            problems.append(f"shutting {self.name} down: {error}")
        if self._log is not None:
            self._log.close()
            self._log = None
        if not self.created:
            return problems
        try:
            # A `tart run` the lab lost track of — started, but interrupted before
            # it was remembered — would keep the machine running and refuse the delete.
            if self.tart.running(self.name):
                problems.append(f"{self.name} was still running with no process the lab knew of; stopped with 'tart stop'")
                self.tart.stop(self.name)
        except LabError as error:
            problems.append(str(error))
        try:
            if keep:
                kept = config.KEPT_PREFIX + self.name.removeprefix(config.VM_PREFIX)
                self.tart.rename(self.name, kept)
                self.note(f"   kept for inspection: {kept}")
            else:
                self.tart.delete(self.name)
            self.created = False
        except LabError as error:
            if "does not exist" in error.reason:
                self.created = False  # the clone never got as far as Tart's store
            else:
                problems.append(str(error))
        return problems


class _RefusedByLimit(Exception):
    pass


def ended(returncode: int) -> str:
    """How a process ended, in words: a signal is named, and a crash says where its report is."""
    if returncode >= 0:
        return f"exited {returncode}"
    try:
        name = signal.Signals(-returncode).name
    except ValueError:
        name = f"signal {-returncode}"
    words = f"was killed by {name}"
    if -returncode in CRASH_SIGNALS:
        words += " (a crash; macOS keeps its report in ~/Library/Logs/DiagnosticReports/)"
    return words


CRASH_SIGNALS = frozenset({signal.SIGTRAP, signal.SIGABRT, signal.SIGSEGV, signal.SIGBUS, signal.SIGILL})

_NUMBERED = re.compile(r"^(\d+)-.*\.png$")


def next_number(directory: Path) -> int:
    """One more than the highest numbered screenshot already in `directory`."""
    numbers = [int(m.group(1)) for p in directory.iterdir() if (m := _NUMBERED.match(p.name))]
    return max(numbers, default=0) + 1


def slug(step: str) -> str:
    """A step's words as a file name: `after the update` → `after-the-update`."""
    words = re.sub(r"[^a-z0-9]+", "-", step.lower()).strip("-")
    return words[:60].rstrip("-") or "screen"
