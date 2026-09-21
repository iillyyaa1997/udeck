"""A machine's screen and pointer, from the host, over VNC.

`tart run --vnc-experimental` gives every machine Virtualization.framework's own
VNC server. Through it the pointer moves the machine's virtual pointing device —
the path a physical mouse takes — and a screenshot is the machine's framebuffer,
which asks nothing of the guest: no screen-recording permission, no dialog.

Measured with Tart 2.37.0 on a macOS 27 host, and why this module looks the way
it does:

* The server answers one full-frame request per connection. A second request on
  the same connection gets no reply until something on the screen repaints, and
  vncdotool's threaded client then queues every later call behind it. So each
  action is a connection of its own, in a process of its own with a deadline,
  and a screenshot is always the last thing its connection does.
* Tart prints the address as 127.0.0.1, but the server listens on every
  interface, so while a machine runs its screen can be reached from the local
  network with the password. The lab connects to the loopback address only and
  refuses any other.
* A screen that is not drawn yet answers with the right size but almost no
  content: a black 1280×720 frame right after one boot, and the Apple boot screen
  — 99.8% of it one colour — for half a minute after another. `wait_for_screen`
  therefore waits for a frame with real content in it, not merely for a frame.
* The server does follow what the guest draws: measured over a minute of frames,
  an application opening and closing changed them within a second. But nothing
  here can prove that a frame is *recent*: a still screen is answered with a
  frame identical to the last, and the pointer does not appear in it (measured),
  so there is nothing the lab can change to force a repaint of its own.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import time
from collections.abc import Callable
from dataclasses import dataclass, field
from pathlib import Path

from udeck_e2e import config
from udeck_e2e.errors import LabError

Note = Callable[[str], None]

URL = re.compile(r"VNC server is running at vnc://:(?P<password>[^@\s]*)@(?P<host>[^:/\s]+):(?P<port>\d+)")

LOOPBACK = "127.0.0.1"

# How the address reaches the client process. The environment, not the command
# line: any user on the Mac can read another process's arguments.
SERVER_VARIABLE = "UDECK_E2E_VNC_SERVER"
PASSWORD_VARIABLE = "UDECK_E2E_VNC_PASSWORD"
SECONDS_VARIABLE = "UDECK_E2E_VNC_SECONDS"


@dataclass(frozen=True)
class Address:
    host: str
    port: int
    # Out of repr, so that no report or error message can carry it.
    password: str = field(repr=False)


def find_address(log_text: str) -> Address | None:
    """The VNC address `tart run` printed, the last one if it printed several."""
    matches = list(URL.finditer(log_text))
    if not matches:
        return None
    last = matches[-1]
    return Address(last["host"], int(last["port"]), last["password"])


def without_password(text: str) -> str:
    """Tart's VNC line with the password taken out, for anything a person may read.

    `tart run` prints that line and usually nothing else, so it is the last line
    of the log — which is what the lab quotes when a machine dies unexpectedly.
    """
    return URL.sub(lambda m: f"VNC server is running at vnc://:…@{m['host']}:{m['port']}", text)


@dataclass(frozen=True)
class Frame:
    width: int
    height: int
    # How much of the frame one colour covers, between 0 and 1. A screen that is
    # not drawn yet is one flat colour (1.0); the boot screen — an Apple logo on
    # black — measured 0.998; a desktop measured 0.002.
    uniform: float

    def describe(self) -> str:
        return f"{self.width}×{self.height}, {self.uniform:.1%} of it one colour"


def parse_frame(text: str) -> Frame:
    """The client's report of the frame it saved: one JSON object on stdout."""
    facts = json.loads(text)
    width, height, uniform = facts["width"], facts["height"], facts["uniform"]
    if not (isinstance(width, int) and isinstance(height, int) and isinstance(uniform, (int, float))):
        raise ValueError(f"unexpected types in {facts!r}")
    return Frame(width, height, float(uniform))


class Screen:
    """One machine's VNC server, driven one short connection at a time."""

    def __init__(
        self,
        address: Address,
        python: Path = Path(sys.executable),
        run: Callable[..., subprocess.CompletedProcess[str]] = subprocess.run,
        sleep: Callable[[float], None] = time.sleep,
        clock: Callable[[], float] = time.monotonic,
        seconds: float = config.VNC_ACTION_SECONDS,
    ) -> None:
        if address.host != LOOPBACK:
            raise LabError(
                "connecting to the machine's screen",
                f"Tart printed the address {address.host}; the lab connects to {LOOPBACK} only",
            )
        self.address = address
        self.python = python
        self.seconds = seconds
        self._run = run
        self._sleep = sleep
        self._clock = clock

    def move(self, x: int, y: int, step: str) -> None:
        """Put the pointer at (x, y), in pixels from the screen's top-left corner."""
        self._act(["move", str(x), str(y)], step)

    def click(self, x: int, y: int, step: str) -> None:
        """Click where a person would, through the machine's own pointing device."""
        self._act(["click", str(x), str(y)], step)

    def key(self, name: str, step: str) -> None:
        """Press a key on the machine's keyboard, named as vncdotool names it (`esc`).

        Where it lands is the guest's business: the keystroke arrives at the
        machine's keyboard, and macOS sends it wherever it is sending keystrokes.
        """
        self._act(["key", name], step)

    def capture(self, path: Path, step: str) -> Frame:
        """Save the screen as a PNG at `path`. A capture cut short leaves no file there."""
        partial = path.with_name(f".{path.stem}.partial.png")
        try:
            done = self._act(["capture", str(partial)], step)
            try:
                frame = parse_frame(done.stdout)
            except (ValueError, KeyError, TypeError):
                raise LabError(step, f"the VNC client answered {done.stdout.strip()[-200:]!r}") from None
            try:
                partial.replace(path)
            except OSError as error:
                raise LabError(step, f"could not save the screenshot: {error}") from None
            return frame
        finally:
            partial.unlink(missing_ok=True)

    def wait_for_screen(
        self,
        scratch: Path,
        step: str,
        alive: Callable[[str], None] | None = None,
        seconds: float = config.SCREEN_SECONDS,
        size: tuple[int, int] = (config.SCREEN_WIDTH, config.SCREEN_HEIGHT),
    ) -> Frame:
        """Until the screen shows a drawn frame: the expected size, and content in it.

        `alive` is asked between attempts and raises if the machine itself has
        gone, so a dead `tart run` is reported rather than a refused connection.
        """
        deadline = self._clock() + seconds
        last = "no answer yet"
        try:
            while True:
                if alive is not None:
                    alive(step)
                try:
                    frame = self.capture(scratch, step)
                    if (frame.width, frame.height) == size and frame.uniform <= config.SCREEN_MAX_UNIFORM:
                        return frame
                    last = frame.describe()
                except LabError as error:
                    last = error.reason
                if self._clock() >= deadline:
                    raise LabError(
                        step, f"no {size[0]}×{size[1]} frame with a drawn screen within {seconds:.0f}s; last: {last}"
                    )
                self._sleep(1)
        finally:
            scratch.unlink(missing_ok=True)

    def _act(self, args: list[str], step: str) -> subprocess.CompletedProcess[str]:
        env = {
            **os.environ,
            SERVER_VARIABLE: f"{self.address.host}::{self.address.port}",
            PASSWORD_VARIABLE: self.address.password,
            # The client gives up a little before the lab would kill it, so that
            # it can say why.
            SECONDS_VARIABLE: str(max(1.0, self.seconds - 10)),
        }
        try:
            done = self._run(
                [str(self.python), "-m", "udeck_e2e.vnc_client", *args],
                capture_output=True,
                text=True,
                errors="replace",
                timeout=self.seconds,
                check=False,
                env=env,
                # See Tart.call: never the operator's terminal, and Ctrl-C belongs
                # to the lab, not to its children.
                stdin=subprocess.DEVNULL,
                start_new_session=True,
            )
        except subprocess.TimeoutExpired:
            raise LabError(step, f"the VNC {args[0]} did not finish in {self.seconds:.0f}s") from None
        except OSError as error:
            raise LabError(step, f"could not start the VNC client: {error}") from None
        if done.returncode != 0:
            lines = (done.stderr or done.stdout).strip().splitlines()
            said = lines[-1] if lines else f"exit {done.returncode}, no output"
            raise LabError(step, f"the VNC {args[0]} failed: {said}")
        return done
