"""Tart, called the way the lab needs: with a deadline on every call.

Every failure becomes a LabError naming the step, so a check that cannot get a
machine reports "could not check", never "failed". Only calls that are safe to
repeat — reading a list, a configuration, an address — are retried when Tart
hangs, and each retry is said out loud.
"""

from __future__ import annotations

import json
import os
import subprocess
from collections.abc import Callable
from pathlib import Path
from typing import IO, Any

from udeck_e2e import config
from udeck_e2e.errors import LabError
from udeck_e2e.preflight import VM, parse_tart_list

Note = Callable[[str], None]

VM_LIMIT_TEXT = "exceeds the system limit"


class Tart:
    def __init__(
        self,
        binary: Path,
        note: Note,
        run: Callable[..., subprocess.CompletedProcess[str]] = subprocess.run,
        popen: Callable[..., subprocess.Popen[Any]] = subprocess.Popen,
    ) -> None:
        self.binary = binary
        self.note = note
        self._run = run
        self._popen = popen

    def call(
        self,
        args: list[str],
        step: str,
        seconds: float = config.TART_CALL_SECONDS,
        retry_if_hung: bool = False,
        check: bool = True,
    ) -> subprocess.CompletedProcess[str]:
        attempts = 1 + (config.KNOWN_FAILURE_RETRIES if retry_if_hung else 0)
        shown = "tart " + " ".join(args)
        for attempt in range(1, attempts + 1):
            try:
                done = self._run(
                    [str(self.binary), *args],
                    capture_output=True,
                    text=True,
                    errors="replace",
                    timeout=seconds,
                    check=False,
                    env={**os.environ, "LC_ALL": "C"},
                    # Out of the terminal's process group: Ctrl-C is for the lab
                    # to handle, and must not kill the `tart stop` or `tart
                    # delete` of the cleanup it starts.
                    start_new_session=True,
                )
            except subprocess.TimeoutExpired:
                if attempt < attempts:
                    self.note(f"   retry {attempt}/{attempts - 1}: '{shown}' hung for {seconds:.0f}s ({step})")
                    continue
                raise LabError(step, f"'{shown}' did not finish in {seconds:.0f}s") from None
            except OSError as error:
                raise LabError(step, f"could not run tart: {error}") from None
            if check and done.returncode != 0:
                raise LabError(step, f"'{shown}' exited {done.returncode}: {last_line(done)}")
            return done
        raise AssertionError("unreachable")

    # --- The calls the lab makes ---------------------------------------------

    def list(self) -> list[VM]:
        done = self.call(["list", "--format", "json"], "listing machines", retry_if_hung=True)
        try:
            return parse_tart_list(done.stdout)
        except (ValueError, KeyError, TypeError) as error:
            raise LabError("listing machines", f"unreadable output: {error}") from None

    def exists(self, name: str) -> bool:
        return any(vm.name == name for vm in self.list())

    def get(self, name: str) -> dict[str, Any]:
        done = self.call(["get", name, "--format", "json"], f"reading {name}'s settings", retry_if_hung=True)
        try:
            return json.loads(done.stdout)
        except ValueError as error:
            raise LabError(f"reading {name}'s settings", f"unreadable output: {error}") from None

    def pull(self, image: str) -> None:
        self.call(["pull", image], f"downloading {image}", seconds=config.PULL_SECONDS)

    def clone(self, source: str, name: str) -> None:
        self.call(["clone", source, name], f"cloning {name}", seconds=config.CLONE_SECONDS)

    def set(self, name: str, *options: str) -> None:
        self.call(["set", name, *options], f"configuring {name}")

    def rename(self, name: str, new_name: str) -> None:
        self.call(["rename", name, new_name], f"renaming {name} to {new_name}")

    def delete(self, name: str) -> None:
        self.call(["delete", name], f"deleting {name}")

    def stop(self, name: str) -> None:
        self.call(["stop", name], f"stopping {name}")

    def ip(self, name: str) -> str | None:
        """The machine's address now, or None while it has none."""
        done = self.call(["ip", name], f"asking {name}'s address", retry_if_hung=True, check=False)
        address = done.stdout.strip()
        return address if done.returncode == 0 and address else None

    def exec(self, name: str, argv: list[str], step: str, seconds: float) -> subprocess.CompletedProcess[str]:
        return self.call(["exec", name, *argv], step, seconds=seconds, check=False)

    def start(self, name: str, log: IO[bytes]) -> subprocess.Popen[Any]:
        """`tart run` headless with VNC, in its own session.

        Its own session, so that Ctrl-C in the terminal reaches the lab and not
        Tart: Tart answers SIGINT by powering the machine off, and the lab wants
        to shut it down from inside first. The machine's name comes straight
        after `run`, which is what the pre-flight's orphan search expects.
        """
        try:
            return self._popen(
                [str(self.binary), "run", name, "--no-graphics", "--vnc-experimental"],
                stdout=log,
                stderr=subprocess.STDOUT,
                start_new_session=True,
            )
        except OSError as error:
            raise LabError(f"starting {name}", f"could not run tart: {error}") from None


def last_line(done: subprocess.CompletedProcess[str]) -> str:
    lines = (done.stderr or done.stdout or "").strip().splitlines()
    return lines[-1] if lines else "(no output)"
