"""A machine made of answers, shared by every test that drives a check.

One fake, not one per test file. The difference that matters lives here — SSH
failing is not the same as a command answering "no" — and a second copy of this
is how that difference gets lost in one place and never tested there.
"""

import subprocess
from pathlib import Path

from udeck_e2e.builds import SigningKey
from udeck_e2e.errors import LabError
from udeck_e2e.guest import parse_boot_time


def done(out="", rc=0):
    return subprocess.CompletedProcess([], rc, out, "")


class Dropped:
    """A connection that failed, as each of the two calls sees it.

    `run(check=False)` gets an exit code and no output — which is why a check
    must never read a pid with it — and `ask` turns the same thing into a lab
    failure. A fake that raised from both would let a check swap one for the
    other and never be caught.
    """


class Failed:
    """An answer that is a non-zero exit code, with whatever the command printed.

    `Dropped` is the connection going away; this is the guest answering "no". The
    two used to be the same thing here, and a check that turns a refused command
    into a lab error had no way to be tested at all.
    """

    def __init__(self, code=1, said=""):
        self.code = code
        self.said = said


class Guest:
    """The SSH side: scripted answers by substring, and a record of what was asked.

    An answer may be a string, a list (one per call, the last one repeating),
    `Dropped`, or an exception to raise.
    """

    def __init__(self, answers=None):
        self.answers = dict(answers or {})
        self.commands = []
        self.copied = []

    def _answer(self, command):
        for pattern, answer in self.answers.items():
            if pattern in command:
                if isinstance(answer, list):
                    return answer.pop(0) if len(answer) > 1 else answer[0]
                return answer
        return None

    def _knows(self, command):
        return any(pattern in command for pattern in self.answers)

    def run(self, command, step, seconds=None, check=True):
        self.commands.append(command)
        answer = self._answer(command)
        if answer is Dropped:
            if check:
                raise LabError(step, "SSH to 192.168.64.2 failed")
            return done("", rc=255)
        if isinstance(answer, BaseException):
            raise answer
        if isinstance(answer, Failed):
            # A command that ran and said no. Distinct from Dropped, which is the
            # connection going away: this guest answered, and the answer is an exit
            # code — which is how the guest reports a kernel call it was refused.
            if check:
                raise LabError(step, answer.said or f"exit {answer.code}")
            return done(answer.said, rc=answer.code)
        return done(answer or "")

    def ask(self, command, step, seconds=None):
        """A command whose own exit code is the answer: 0 when this guest knows it."""
        self.commands.append(command)
        answer = self._answer(command)
        if answer is Dropped:
            raise LabError(step, "SSH to 192.168.64.2 failed")
        if isinstance(answer, BaseException):
            raise answer
        if isinstance(answer, Failed):
            # `ask` lets a command's own failure through — that is what it is for —
            # so a caller that treats the exit code as an answer has to be able to
            # be handed one that means "no", and one that means "I could not".
            return done(answer.said, rc=answer.code)
        if answer is None:
            return done("", rc=1)
        return done(answer, rc=0 if answer else 1)

    def boot_time(self):
        """Through `run`, and through the real parser, like the guest's own.

        A fake that answered a number of its own would hide both a machine that
        cannot be asked and a `kern.boottime` whose shape changed.
        """
        return parse_boot_time(self.run("sysctl -n kern.boottime", "reading the guest's boot time").stdout)

    def copy_in(self, local, remote, step, seconds=None):
        self.copied.append((Path(local).name, remote))


class Machine:
    """Everything a check asks of a machine, with a clock that only moves when it sleeps."""

    def __init__(self, answers=None):
        self.name = "udeck-e2e-probe"
        self.ssh = Guest(answers)
        self.now = 0.0
        self.shots = []
        self.clicks = []
        self.keys = []
        self.pointer = []
        self.screenshot_fails = None
        # Which step's screenshot fails; None means every one of them.
        self.screenshot_fails_at = None
        self.click_fails = None

    def clock(self):
        return self.now

    def sleep(self, seconds):
        self.now += seconds

    def screenshot(self, directory, step):
        if self.screenshot_fails is not None and self.screenshot_fails_at in (None, step):
            raise self.screenshot_fails
        self.shots.append(step)
        return Path(directory) / f"{step}.png"

    def click(self, x, y, step):
        if self.click_fails is not None:
            raise self.click_fails
        self.clicks.append((x, y, step))

    def key(self, name, step):
        # The name as vncdotool takes it, and the step, because a keystroke names
        # no place: which key was pressed is all a test can read back about it.
        self.keys.append((name, step))

    def move_pointer(self, x, y, step):
        self.pointer.append((x, y, step))


class FakeBuild:
    """A build as a check sees it: a zip on disk that nothing here ever opens."""

    def __init__(self, directory, version, number):
        self.zip = directory / f"uDeck-{version}.zip"
        self.zip.write_bytes(b"x" * 16)
        self.version, self.build_number = version, number


class Builder:
    def __init__(self, directory):
        self.directory = directory

    def build(self, version, number):
        return FakeBuild(self.directory, version, number)


class Lab:
    """The run, as a check sees it."""

    def __init__(self, tmp_path):
        self.notes = []
        # A checkout of its own: nothing here may reach the real one, the way
        # `test_make_app` is the only test allowed to (see its own guard).
        self.repo_root = tmp_path / "repo"
        self.signing_key = SigningKey(tmp_path / "sparkle-key", "public-key")
        self.builders = []
        self._tmp = tmp_path

    def note(self, text):
        self.notes.append(text)

    def builder(self, feed_url, for_check):
        self.builders.append((feed_url, for_check))
        directory = self._tmp / "builds" / for_check
        directory.mkdir(parents=True, exist_ok=True)
        return Builder(directory)
