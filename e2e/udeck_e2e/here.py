"""`--target here`: the machine running the lab is the guest — on a GitHub-hosted runner, and nowhere else.

A Tart guest is a throwaway macOS the lab drives from outside: SSH for
commands, VNC for the pointer and the screen. A GitHub-hosted macOS runner is a
throwaway macOS too, made for one job and deleted after it, with a logged-in
desktop — but Apple silicon runners offer no nested virtualisation, so there is
no Tart there to make a guest with. Measured on one on 2026-10-12 (runs
38190017851, 38209960064): the job's own processes may use the accessibility
API, post pointer and key events and take screenshots; uDeck installs into
/Applications and runs; `sudo` asks for no password.

So on a runner the runner itself is the guest, and this module is the machine
the checks are handed there. It has the interface of `machine.Machine` —
`ssh.run` and friends, a pointer, a keyboard, screenshots, a clock — made of
local things: a subprocess for each command, the accessibility helper
(`e2e/guest/ax.swift`) for the pointer and the keys, `screencapture` for the
screen.

**It is refused anywhere else** (`refusal`). Everything a check does to its
guest — installing uDeck in /Applications, moving the pointer, typing, changing
the display, asking `sudo` to keep uDeck's log — would be done to the machine
running the lab, and on a person's Mac that is his Mac. Both variables GitHub
sets on its own runners have to say so; nothing on a person's Mac sets them.

What it cannot do is what a virtual machine is for: restart, log out and back
in, start from a machine nothing has run on. A check that needs one of those
says so (`targets.needs_a_vm`) and is reported as not on this target rather
than run (`Outcome.NOT_ON_THIS_TARGET`); a check that asks for a restart
without saying so meets `HereMachine.reboot`, which refuses — and, having done
part of its work on the runner by then, it could not be checked, not skipped.
"""

from __future__ import annotations

import os
import pwd
import re
import shlex
import shutil
import subprocess
import time
from collections.abc import Callable, Mapping
from pathlib import Path
from typing import Any

from udeck_e2e import app, ax, config
from udeck_e2e.errors import LabError, NotOnThisTarget
from udeck_e2e.guest import parse_boot_time
from udeck_e2e.machine import next_number, slug

Note = Callable[[str], None]

# What GitHub sets in every job on its own runners, and nothing on a person's
# Mac does: both have to read exactly this.
RUNNER_VARIABLES = {"GITHUB_ACTIONS": "true", "RUNNER_ENVIRONMENT": "github-hosted"}

# A command run the way SSH runs one in a Tart guest: through a shell, with
# SSH's spare environment rather than the job's. The guest's user logs in with
# zsh, so the commands the lab writes have only ever been read by zsh.
SHELL = "/bin/zsh"
PATH = "/usr/bin:/bin:/usr/sbin:/sbin"

# The largest screen the runner offers: the guest's is 2560 by 1440, and a
# runner's display stops at 1920 by 1080 (measured, run 38209960064). It comes
# up at 1024 by 768, where the settings window is cut off at the bottom.
SCREEN_MODES = ((2560, 1440), (1920, 1080))


def refusal(environ: Mapping[str, str]) -> str | None:
    """Why `--target here` may not run in this environment — or None on a GitHub-hosted runner."""
    if all(environ.get(name) == value for name, value in RUNNER_VARIABLES.items()):
        return None
    said = ", ".join(f"{name}={environ.get(name)!r}" for name in RUNNER_VARIABLES)
    return (
        "--target here makes the machine running the lab the guest: it installs uDeck in /Applications, moves the "
        "pointer, types, changes the display and asks sudo to keep uDeck's log. It runs only on a GitHub-hosted "
        "runner, where GITHUB_ACTIONS=true and RUNNER_ENVIRONMENT=github-hosted — never on a person's Mac. "
        f"Here: {said}."
    )


def environment(environ: Mapping[str, str], user: pwd.struct_passwd | None = None) -> dict[str, str]:
    """The environment a command over SSH gets: who and where, and the system's own PATH."""
    user = user or pwd.getpwuid(os.getuid())
    env = {
        "HOME": user.pw_dir,
        "USER": user.pw_name,
        "LOGNAME": user.pw_name,
        "SHELL": SHELL,
        "PATH": PATH,
    }
    if environ.get("TMPDIR"):
        env["TMPDIR"] = environ["TMPDIR"]
    return env


class Shell:
    """`guest.SSH`'s interface, for commands run on this machine."""

    def __init__(
        self,
        note: Note,
        run: Callable[..., subprocess.CompletedProcess[str]] = subprocess.run,
        environ: Mapping[str, str] | None = None,
    ) -> None:
        self.note = note
        self._run = run
        self.env = environment(os.environ if environ is None else environ)
        # What `guest.SSH` keeps as the guest's address; there is no other machine.
        self.host = "this machine"
        self.key = None

    def run(
        self,
        command: str,
        step: str,
        seconds: float = config.SSH_COMMAND_SECONDS,
        check: bool = True,
    ) -> subprocess.CompletedProcess[str]:
        try:
            done = self._run(
                [SHELL, "-c", command],
                capture_output=True,
                text=True,
                errors="replace",
                timeout=seconds,
                check=False,
                env=self.env,
                cwd=self.env["HOME"],
                stdin=subprocess.DEVNULL,
                start_new_session=True,
            )
        except subprocess.TimeoutExpired:
            raise LabError(step, f"the command did not finish in {seconds:.0f}s") from None
        except OSError as error:
            raise LabError(step, f"could not run {SHELL}: {error}") from None
        if check and done.returncode != 0:
            raise LabError(step, f"exited {done.returncode}: {_last(done)}")
        return done

    def ask(self, command: str, step: str, seconds: float = config.SSH_COMMAND_SECONDS) -> subprocess.CompletedProcess[str]:
        """A command whose own exit code is the answer, as `guest.SSH.ask`; there is no connection to drop."""
        return self.run(command, step, seconds=seconds, check=False)

    def copy_in(self, local: Path, remote: str, step: str, seconds: float = config.COPY_SECONDS) -> None:
        """A file put where a check would have copied it into the guest."""
        target = Path(os.path.expanduser(remote)) if remote.startswith("~") else Path(remote)
        try:
            shutil.copyfile(local, target)
        except OSError as error:
            raise LabError(step, f"copying {Path(local).name} to {target} failed: {error}") from None

    def wait_up(self, step: str, seconds: float = config.SSH_UP_SECONDS, alive: Callable[[str], None] | None = None) -> None:
        """There is nothing to wait for: the commands run here."""

    def boot_time(self) -> int:
        return parse_boot_time(self.run("sysctl -n kern.boottime", "reading this machine's boot time").stdout)

    def boot_session(self) -> str:
        value = self.run("sysctl -n kern.bootsessionuuid", "reading this machine's boot session").stdout.strip()
        if not re.fullmatch(r"[0-9A-Fa-f-]{36}", value):
            raise LabError("reading this machine's boot session", f"unexpected output {value!r}")
        return value


def _last(done: subprocess.CompletedProcess[str]) -> str:
    lines = (done.stderr or done.stdout or "").strip().splitlines()
    return lines[-1] if lines else f"exit {done.returncode}, no output"


class HereMachine:
    """This runner, as the checks' machine: commands, the pointer, the keys and the screen, all local."""

    target = "here"

    def __init__(
        self,
        *,
        name: str,
        work_dir: Path,
        note: Note,
        helper: Path,
        shell: Shell | None = None,
        sleep: Callable[[float], None] = time.sleep,
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        self.name = name
        self.work_dir = work_dir
        self.note = note
        self.helper = helper
        self.ax_path: str | None = str(helper)
        self.ssh: Any = shell or Shell(note)
        # Who the checks' files and uDeck belong to here: the runner's user,
        # where a Tart guest has `config.GUEST_USER`.
        self.user = pwd.getpwuid(os.getuid()).pw_name
        self.created = False
        self.process = None
        self.screen = None
        self.slept_at = ""
        self.width, self.height = config.SCREEN_WIDTH, config.SCREEN_HEIGHT
        self._sleep = sleep
        self._clock = clock

    # --- Coming up -------------------------------------------------------------

    def create(self) -> None:
        """Nothing to clone: the machine is this one."""
        self.created = True

    def boot(self) -> None:
        """This runner made ready the way the bake makes a golden image ready, as far as it can be.

        The desktop has to be there, the helper trusted, the screen as large as
        the runner allows — and the screen's places the checks aim at worked out
        for that size (`config.use_screen`) — and notifications silenced, as the
        bake silences them: a banner lands at the top of the screen, where the
        panel checks point.
        """
        self.work_dir.mkdir(parents=True, exist_ok=True)
        self.wait_for_desktop(f"waiting for {self.name}'s desktop")
        trusted = ax.ask(self, ["trusted"], "asking whether this runner lets the accessibility helper read the screen")
        if trusted.get("trusted") is not True:
            raise LabError(
                "preparing this runner",
                f"the job may not use the accessibility API here ({trusted!r}), so nothing on the screen can be read",
            )
        self._largest_screen()
        self.ssh.run(
            "launchctl disable gui/$(id -u)/com.apple.notificationcenterui.agent && "
            "{ launchctl bootout gui/$(id -u)/com.apple.notificationcenterui.agent || true; }",
            "silencing notifications",
            check=False,
        )
        # A click on the bare desktop brings the Finder forward in the guest and
        # sweeps nothing aside (panel.a-click-past-the-panel, every Tart run of it).
        # On a runner the first one swept every window aside and put up "Click
        # Wallpaper to Show Desktop Items" (run 38213314297): macOS's "click
        # wallpaper to reveal desktop", turned off here before any check clicks there.
        self.ssh.run(
            "defaults write com.apple.WindowManager EnableStandardClickToShowDesktop -bool false && "
            "{ killall WindowManager 2>/dev/null || true; }",
            "making a click on the desktop a click on the desktop",
            check=False,
        )

    def _largest_screen(self) -> None:
        step = "making this runner's screen as large as it goes"
        for width, height in SCREEN_MODES:
            try:
                ax.ask(self, ["set-mode", str(width), str(height)], step)
                break
            except LabError:
                continue
        screen = ax.ask(self, ["screen"], step)
        try:
            self.width, self.height = (int(n) for n in screen["points"])
            menu_bar = int(screen.get("menuBar", config.MENU_BAR))
            visible_bottom = int(screen.get("visibleBottom", self.height))
        except (KeyError, TypeError, ValueError):
            raise LabError(step, f"the screen could not be read: {screen!r}") from None
        config.use_screen(self.width, self.height, menu_bar=menu_bar, visible_bottom=visible_bottom)
        self.note(
            f"   this runner's screen is {self.width}×{self.height} (menu bar {menu_bar}, windows end at "
            f"{visible_bottom}); the guest's is {config.GOLDEN_WIDTH}×{config.GOLDEN_HEIGHT}"
        )

    def wait_for_desktop(self, step: str) -> None:
        """Until this user is the one at the console and Finder is running."""
        me = self.user
        deadline = self._clock() + config.DESKTOP_SECONDS
        while True:
            done = self.ssh.run("stat -f %Su /dev/console; pgrep -x Finder >/dev/null && echo finder", step, seconds=30, check=False)
            words = done.stdout.split()
            if done.returncode == 0 and words[:1] == [me] and "finder" in words:
                return
            if self._clock() >= deadline:
                raise LabError(step, f"not at the desktop within {config.DESKTOP_SECONDS}s: {' '.join(words)}")
            self._sleep(2)

    def ensure_running(self, step: str) -> None:
        """This machine is running for as long as the lab is."""

    def keep_the_screen_in_use(self, interval: float = 0) -> None:
        """Nothing to keep alive: there is no VNC server here."""

    def reboot(self) -> None:
        """Refused: restarting the runner would end the job, and the lab with it."""
        raise NotOnThisTarget("a restart of the machine, which on a runner would end the job")

    # --- The screen, the pointer and the keyboard -----------------------------------

    def clock(self) -> float:
        return self._clock()

    def sleep(self, seconds: float) -> None:
        self._sleep(seconds)

    def screenshot(self, directory: Path, step: str) -> Path:
        """The screen now, saved in `directory` as `<NN>-<step>.png`, as `Machine.screenshot` names them."""
        what = f"taking the screenshot '{step}'"
        try:
            directory.mkdir(parents=True, exist_ok=True)
            path = directory / f"{next_number(directory):02d}-{slug(step)}.png"
        except OSError as error:
            raise LabError(what, f"could not prepare {directory}: {error}") from None
        self.ssh.run(f"/usr/sbin/screencapture -x -t png {shlex.quote(str(path))}", what, seconds=config.VNC_ACTION_SECONDS)
        if not path.is_file():
            raise LabError(what, "screencapture saved nothing")
        return path

    def _refuse_off_screen(self, x: int, y: int, what: str) -> None:
        if not (0 <= x < self.width and 0 <= y < self.height):
            raise LabError(what, f"({x}, {y}) is off the {self.width}×{self.height} screen")

    def _post(self, args: list[str], what: str) -> None:
        """One event posted by the helper — and a button it found still held, let go of first and said.

        No check holds a button, so one the system takes for held before an
        action is a release that went missing: measured on a runner (run
        38227384436), one click left the left button held, and every gesture
        after it, in every check after it, was `idle: buttonDown`. The helper lets
        go of it before it acts, and the lab says so.
        """
        answer = ax.ask(self, args, what)
        released = [str(b) for b in answer.get("released") or []]
        again = answer.get("released again") or 0
        if released:
            self.note(f"   the {' and '.join(released)} button was still held; let go of before {what}")
        if again:
            self.note(f"   the system took the button for held after {what}; its release was posted {again} more time(s)")
        modifiers = [str(m) for m in answer.get("modifiers held") or []]
        if modifiers:
            self.note(f"   the system took {' and '.join(modifiers)} for held when {what}; the key was sent without them")

    def move_pointer(self, x: int, y: int, step: str) -> None:
        what = f"moving the pointer {step}"
        self._refuse_off_screen(x, y, what)
        self._post(["move", str(x), str(y)], what)

    def click(self, x: int, y: int, step: str) -> None:
        what = f"clicking {step}"
        self._refuse_off_screen(x, y, what)
        self._post(["click", str(x), str(y)], what)

    def right_click(self, x: int, y: int, step: str) -> None:
        what = f"right-clicking {step}"
        self._refuse_off_screen(x, y, what)
        self._post(["right-click", str(x), str(y)], what)

    def key(self, name: str, step: str) -> None:
        self._post(["key", name], f"pressing {name} {step}")

    def scroll(self, x: int, y: int, distance: int, step: str) -> None:
        """The pane under (x, y) scrolled by `distance` points — positive moves its content down."""
        self._refuse_off_screen(x, y, step)
        self._post(["scroll", str(x), str(y), str(distance)], step)

    # --- Going away -----------------------------------------------------------------

    def shut_down(self) -> str | None:
        return None

    def close(self, keep: bool) -> list[str]:
        """uDeck ended, so the job's next step finds nothing of the checks still running. Problems come back as a list."""
        problems = []
        try:
            app.quit_app(self, f"ending uDeck on {self.name}")
        except LabError as error:
            problems.append(str(error))
        self.created = False
        return problems
