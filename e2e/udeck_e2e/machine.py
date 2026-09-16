"""One throwaway virtual machine: made, booted, rebooted, shut down, removed.

This is the shared piece every check stands on, so it is also where the lab
checks itself: a machine that does not come back is reported by the step that
failed — "waiting for SSH after the reboot" — and becomes "could not check",
never a verdict on uDeck.
"""

from __future__ import annotations

import signal
import threading
import time
from collections.abc import Callable, Iterator
from contextlib import contextmanager
from pathlib import Path
from typing import IO, Any

from udeck_e2e import config
from udeck_e2e.errors import LabError
from udeck_e2e.guest import SSH
from udeck_e2e.tart import VM_LIMIT_TEXT, Tart

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
        self._log: IO[bytes] | None = None
        self._sleep = sleep
        self._clock = clock

    # --- Coming up -----------------------------------------------------------

    def create(self) -> None:
        self.tart.clone(self.source, self.name)
        self.created = True
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
        self.ssh.wait_up(f"waiting for SSH on {self.name}")
        self.wait_for_desktop(f"waiting for {self.name}'s desktop")

    def _start(self) -> None:
        self.work_dir.mkdir(parents=True, exist_ok=True)
        if self._log is not None:
            self._log.close()
        self._log = open(self.work_dir / "tart-run.log", "ab")
        self.process = self.tart.start(self.name, self._log)

    def _log_text(self) -> str:
        try:
            return (self.work_dir / "tart-run.log").read_text(errors="replace")
        except OSError:
            return ""

    def _wait_for_address(self) -> str:
        step = f"waiting for {self.name} to get an address"
        deadline = self._clock() + config.BOOT_IP_SECONDS
        while True:
            if self.process.poll() is not None:
                log = self._log_text()
                if VM_LIMIT_TEXT in log:
                    raise _RefusedByLimit()
                tail = log.strip().splitlines()[-1:] or ["(no output)"]
                raise LabError(step, f"'tart run' exited {self.process.returncode}: {tail[0]}")
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
        """Restart from inside, the way a person would, and wait for the desktop."""
        before = self.ssh.boot_time()
        self.ssh.run("sudo -n shutdown -r now", f"restarting {self.name}", seconds=30, check=False)
        step = f"waiting for {self.name} to come back after the restart"
        deadline = self._clock() + config.REBOOT_SECONDS
        while True:
            address = self.tart.ip(self.name)
            if address:
                self.ssh.host = address
                try:
                    now = self.ssh.boot_time()
                except LabError:
                    now = before
                if now != before:
                    break
            if self._clock() >= deadline:
                raise LabError(step, f"the guest's boot time did not change within {config.REBOOT_SECONDS}s")
            self._sleep(3)
        self.wait_for_desktop(f"waiting for {self.name}'s desktop after the restart")

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
        with ctrl_c_deferred(self.note, self.name):
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
            if keep:
                kept = config.KEPT_PREFIX + self.name.removeprefix(config.VM_PREFIX)
                self.tart.rename(self.name, kept)
                self.note(f"   kept for inspection: {kept}")
            else:
                self.tart.delete(self.name)
            self.created = False
        except LabError as error:
            problems.append(str(error))
        return problems


class _RefusedByLimit(Exception):
    pass


# Presses of Ctrl-C during a cleanup before the lab gives up on it.
ABANDON_CLEANUP_AFTER = 3


@contextmanager
def ctrl_c_deferred(note: Note, name: str) -> Iterator[None]:
    """Let a cleanup finish although Ctrl-C is pressed again.

    The first Ctrl-C stops the run and starts the cleanup; an impatient second
    one used to cut the cleanup short and leave the clone running or behind.
    Now further presses are acknowledged, and only the third abandons it.
    """
    if threading.current_thread() is not threading.main_thread():
        yield
        return
    previous = signal.getsignal(signal.SIGINT)
    presses = 0

    def acknowledge(signum: int, frame: object) -> None:
        nonlocal presses
        presses += 1
        if presses >= ABANDON_CLEANUP_AFTER:
            signal.signal(signal.SIGINT, previous)
            raise KeyboardInterrupt
        note(
            f"   still cleaning up {name}; press Ctrl-C {ABANDON_CLEANUP_AFTER - presses} more "
            "time(s) to abandon it and leave the clone behind"
        )

    signal.signal(signal.SIGINT, acknowledge)
    try:
        yield
    finally:
        signal.signal(signal.SIGINT, previous)
