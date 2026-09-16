"""Commands inside a guest, over the system's own `ssh`.

SSH rather than `tart exec` for everything that matters, because what a check
does has to be permitted the way it would be for a person: in Cirrus Labs'
images `sshd-session` may drive System Events, while the same AppleEvents sent
through `tart exec` time out (measured). `tart exec` is used for one thing only,
putting this run's public key into the guest, which needs no password.

The operator's own SSH configuration is never read (`-F /dev/null`), and only
this run's key is offered (`IdentitiesOnly`), so an agent full of keys cannot
exhaust the guest's authentication attempts.
"""

from __future__ import annotations

import re
import subprocess
import time
from collections.abc import Callable
from pathlib import Path

from udeck_e2e import config
from udeck_e2e.errors import LabError

Note = Callable[[str], None]

SSH_OPTIONS = [
    "-F", "/dev/null",
    "-o", "IdentitiesOnly=yes",
    "-o", "StrictHostKeyChecking=no",
    "-o", "UserKnownHostsFile=/dev/null",
    "-o", "BatchMode=yes",
    "-o", "LogLevel=ERROR",
    "-o", "ConnectTimeout=5",
    "-o", "ServerAliveInterval=5",
    "-o", "ServerAliveCountMax=3",
]  # fmt: skip

# ssh's own exit code for "could not connect or authenticate".
SSH_FAILED = 255

BOOT_TIME = re.compile(r"^\{ sec = (\d+), usec = \d+ \}")


def make_key(directory: Path) -> Path:
    """A throwaway ed25519 key for this run. Returns the private key's path."""
    directory.mkdir(parents=True, exist_ok=True)
    key = directory / "id_ed25519"
    try:
        subprocess.run(
            ["/usr/bin/ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "udeck-e2e", "-f", str(key)],
            check=True,
            capture_output=True,
            timeout=30,
        )
    except (OSError, subprocess.SubprocessError) as error:
        raise LabError("making this run's SSH key", str(error)) from None
    return key


def parse_boot_time(text: str) -> int:
    """Seconds since the epoch from `sysctl -n kern.boottime`.

    Anchored on `sec =` at the start: a looser pattern once matched the `sec`
    inside `usec` and "proved" a reboot by comparing microseconds.
    """
    match = BOOT_TIME.match(text.strip())
    if not match:
        raise LabError("reading the guest's boot time", f"unexpected output {text.strip()!r}")
    return int(match.group(1))


class SSH:
    def __init__(
        self,
        key: Path,
        note: Note,
        run: Callable[..., subprocess.CompletedProcess[str]] = subprocess.run,
        sleep: Callable[[float], None] = time.sleep,
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        self.key = key
        self.note = note
        self.host: str | None = None
        self._run = run
        self._sleep = sleep
        self._clock = clock

    def run(
        self,
        command: str,
        step: str,
        seconds: float = config.SSH_COMMAND_SECONDS,
        check: bool = True,
    ) -> subprocess.CompletedProcess[str]:
        if self.host is None:
            raise LabError(step, "the guest has no address yet")
        try:
            done = self._run(
                ["/usr/bin/ssh", *SSH_OPTIONS, "-i", str(self.key), f"{config.GUEST_USER}@{self.host}", command],
                capture_output=True,
                text=True,
                errors="replace",
                timeout=seconds,
                check=False,
                # See Tart.call: Ctrl-C belongs to the lab, not to its children.
                start_new_session=True,
            )
        except subprocess.TimeoutExpired:
            raise LabError(step, f"the command did not finish in {seconds:.0f}s") from None
        except OSError as error:
            raise LabError(step, f"could not run ssh: {error}") from None
        if check and done.returncode == SSH_FAILED:
            raise LabError(step, f"SSH to {self.host} failed: {_last(done)}")
        if check and done.returncode != 0:
            raise LabError(step, f"exited {done.returncode}: {_last(done)}")
        return done

    def wait_up(self, step: str, seconds: float = config.SSH_UP_SECONDS) -> None:
        """Until SSH answers. Refusals right after a boot are expected and counted."""
        deadline = self._clock() + seconds
        refusals = 0
        last = ""
        while True:
            try:
                done = self.run("true", step, seconds=15, check=False)
                answered, said = done.returncode == 0, _last(done)
            except LabError as error:
                answered, said = False, error.reason
            if answered:
                if refusals:
                    self.note(f"   SSH answered after {refusals} refused attempt(s) ({step}); last: {last}")
                return
            refusals += 1
            last = said
            if self._clock() >= deadline:
                raise LabError(step, f"no SSH within {seconds:.0f}s; last answer: {last}")
            self._sleep(3)

    def boot_time(self) -> int:
        return parse_boot_time(self.run("sysctl -n kern.boottime", "reading the guest's boot time").stdout)


def _last(done: subprocess.CompletedProcess[str]) -> str:
    lines = (done.stderr or done.stdout or "").strip().splitlines()
    return lines[-1] if lines else f"exit {done.returncode}, no output"
