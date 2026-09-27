"""The script the lab runs inside the guest to push the pointer.

It is the one piece of the lab that cannot run on this Mac: it posts movement
through `IOHIDSystem`, which would move the operator's own cursor. So the two
calls that reach the kernel are the seam — `iokit()` and `pointer_reader()` —
and everything this file tests is the part between them, which is where the
mistakes have actually been.

The mistake it is mostly about: the throw must stop when the pointer arrives.
uDeck counts upward movement made while the pointer was *already* pinned, so a
throw that runs to a count instead of to the edge is itself a push — the run
says `fired by push` and the push the check makes never mattered. That was
measured on 2026-09-19 and is why the throw watches the pointer.
"""

import importlib.util
import json
import sys
from pathlib import Path

import pytest

SCRIPT = Path(__file__).resolve().parents[1] / "guest" / "push-pointer.py"


def _load():
    spec = importlib.util.spec_from_file_location("push_pointer_under_test", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


push_pointer = _load()


@pytest.fixture(autouse=True)
def never_the_real_kernel(monkeypatch):
    """Nothing in this file may post a real event.

    This is not belt and braces. Written without it, one test in this file called
    `main` with a valid argument count and no fakes — and the script did what it
    is for: it posted to `IOHIDSystem` on the machine running the tests and moved
    the operator's own pointer. A guard that has to be remembered in each test is
    a guard that will be forgotten, so it is applied to all of them and the tests
    that want a fake kernel replace these with their own.
    """
    def refuse(*args, **kwargs):
        raise AssertionError(
            "this test reached the real kernel: fake `iokit`, `post` and `pointer_reader` "
            "before calling main()"
        )

    monkeypatch.setattr(push_pointer, "iokit", refuse)
    monkeypatch.setattr(push_pointer, "post", refuse)
    monkeypatch.setattr(push_pointer, "pointer_reader", refuse)


class FakeKernel:
    """Every report the script posts, and what the kernel says back."""

    def __init__(self, answers=None):
        self.posted = []
        self.sideways = []
        self.answers = list(answers) if answers else None
        self.closed = False

    # The three calls the script makes on the connection.
    def IOServiceMatching(self, name):  # noqa: N802 — the C name
        return 1

    def IOServiceGetMatchingService(self, port, matching):  # noqa: N802
        return 7

    def IOServiceOpen(self, service, task, kind, connect):  # noqa: N802
        connect._obj.value = 42
        return 0

    def IOObjectRelease(self, service):  # noqa: N802
        return 0

    def IOServiceClose(self, connect):  # noqa: N802
        self.closed = True
        return 0


# Where every run but the wobble begins: the middle of the screen, where the lab parks it.
MIDDLE = (1280.0, 720.0)


def run(monkeypatch, capsys, argv, positions, answers=None, start=MIDDLE):
    """Run the script with the kernel faked, the pointer at `start` before anything is posted,
    and at `positions` in turn after each report."""
    kernel = FakeKernel(answers)
    seen = iter([start, *positions])
    last = [positions[-1] if positions else None]

    def post(library, connect, delta, sideways=0):
        kernel.posted.append(delta)
        kernel.sideways.append(sideways)
        return kernel.answers.pop(0) if kernel.answers else 0

    def where():
        try:
            last[0] = next(seen)
        except StopIteration:
            pass
        return last[0]

    monkeypatch.setattr(push_pointer, "iokit", lambda: kernel)
    monkeypatch.setattr(push_pointer, "post", post)
    monkeypatch.setattr(push_pointer, "pointer_reader", lambda: where)
    monkeypatch.setattr(push_pointer.time, "sleep", lambda seconds: None)
    # ctypes still builds the argument the fake connection is passed.
    code = push_pointer.main(["push-pointer.py", *[str(a) for a in argv]])
    printed = capsys.readouterr().out.strip()
    return code, (json.loads(printed) if printed.startswith("{") else printed), kernel


DESCENT = [(1280.0, y) for y in (660, 600, 540, 480, 420, 360, 300, 240, 180, 120, 60, 0)]


def test_the_throw_stops_the_moment_the_pointer_is_pinned(monkeypatch, capsys):
    """The whole point. One report past the edge is already twice uDeck's push
    threshold, so a throw that overshoots fires the gesture it came to set up."""
    code, said, kernel = run(monkeypatch, capsys, [30, -60, 0, 2, 5, -12, 0, 0, 0], DESCENT)
    assert code == 0
    assert said["thrown"] == 12, "twelve reports of sixty reach the edge from the middle"
    assert said["pinned"] is True and said["at"] == [1280.0, 0.0]
    # Twelve of the throw and five of the push, and nothing between them.
    assert kernel.posted == [-60] * 12 + [-12] * 5


def test_the_cap_is_a_cap_and_running_out_of_it_is_said_rather_than_raised(monkeypatch, capsys):
    """Where the pointer got to is the measurement. The check reads the position
    back itself before it says anything about uDeck, so this only has to be honest."""
    code, said, kernel = run(monkeypatch, capsys, [3, -60, 0, 2, 5, -12, 0, 0, 0], DESCENT)
    assert code == 0
    assert said["thrown"] == 3
    assert said["pinned"] is False
    # Read once more when the cap runs out, which is the next step of the descent.
    assert said["at"] == [1280.0, 480.0]
    assert kernel.posted == [-60] * 3 + [-12] * 5, "the push is made either way"


def test_where_the_pointer_was_before_anything_is_posted_is_printed(monkeypatch, capsys):
    """How many reports the throw needed depends on where it began, and only then does
    the count it sent say whether it kept going after the pointer arrived."""
    code, said, _ = run(monkeypatch, capsys, [30, -60, 0, 2, 5, -12, 0, 0, 0], DESCENT)
    assert code == 0
    assert said["from"] == [1280.0, 720.0]
    assert said["thrown"] == 12


def test_the_throw_alone_posts_nothing_once_the_pointer_has_arrived(monkeypatch, capsys):
    """`panel.a-throw-to-the-edge`: the pointer carried to the edge and left there. Not one
    report after the one that arrived — any of them would be a push, and uDeck would be right."""
    code, said, kernel = run(monkeypatch, capsys, [30, -60, 0, 2, 0, -12, 0, 0, 0], DESCENT)
    assert code == 0
    assert kernel.posted == [-60] * 12
    assert said["pinned"] is True and said["at"] == [1280.0, 0.0]
    assert said["push"] == [] and said["track"] == []


def test_a_refused_throw_is_a_non_zero_exit_too(monkeypatch, capsys):
    """With nothing after it, the throw is the whole run, and a kernel that refused part of it
    must not come back as a run that went through."""
    refusal = -536870207  # kIOReturnNotPrivileged
    code, said, _ = run(monkeypatch, capsys, [30, -60, 0, 2, 0, -12, 0, 0, 0], DESCENT, [0] * 11 + [refusal])
    assert code == 1
    assert said["throw"] == ["KERN_SUCCESS", "kIOReturnNotPrivileged"]


def test_a_run_that_posted_nothing_is_not_a_run_that_went_through(monkeypatch, capsys):
    code, said, kernel = run(monkeypatch, capsys, [0, -60, 0, 2, 0, -12, 0, 0, 0], [MIDDLE])
    assert code == 1
    assert kernel.posted == []


def test_the_control_takes_no_throw_at_all(monkeypatch, capsys):
    """A throw would carry the pointer in the middle of the screen to the very
    edge — the one place its verdict would stop being about anything."""
    code, said, kernel = run(monkeypatch, capsys, [0, -60, 0, 2, 5, -12, 0, 0, 0], [(1280.0, 720.0)])
    assert code == 0
    assert said["thrown"] == 0 and said["throw"] == [] and said["pinned"] is None
    assert kernel.posted == [-12] * 5


def test_a_refused_report_comes_back_as_a_non_zero_exit(monkeypatch, capsys):
    """The lab runs this with `check=True`, so the exit code is the only thing
    standing between a kernel that refused and a check that reports about uDeck."""
    refusal = -536870207  # kIOReturnNotPrivileged
    answers = [0] * 12 + [refusal] * 5
    code, said, _ = run(monkeypatch, capsys, [30, -60, 0, 2, 5, -12, 0, 0, 0], DESCENT, answers)
    assert code == 1
    assert said["push"] == ["kIOReturnNotPrivileged"]
    assert said["throw"] == ["KERN_SUCCESS"]


def test_running_as_root_is_said_out_loud(monkeypatch, capsys):
    """`sudo` is what made this call look closed for three weeks: the privilege it
    asks for is the console user's, and root holds no console session."""
    class RootKernel(FakeKernel):
        pass

    monkeypatch.setattr(push_pointer.ctypes, "CDLL", _system_faking_root(push_pointer))
    code, said, _ = run(monkeypatch, capsys, [0, -60, 0, 2, 1, -12, 0, 0, 0], [(1280.0, 720.0)])
    assert said["euid"] == 0
    assert "console session" in said["warning"]


def _system_faking_root(module):
    """A libSystem whose getuid/geteuid answer 0, and nothing else changed."""
    real = module.ctypes.CDLL

    class Root:
        def __init__(self, inner):
            self._inner = inner

        def __getattr__(self, name):
            if name in ("getuid", "geteuid"):
                return lambda: 0
            return getattr(self._inner, name)

    def cdll(path=None, *args, **kwargs):
        return Root(real(path, *args, **kwargs)) if path is None else real(path, *args, **kwargs)

    return cdll


def test_the_arguments_are_counted_and_the_usage_line_is_the_real_one():
    assert push_pointer.main(["push-pointer.py", "1", "2", "3"]) == 2
    assert push_pointer.usage().startswith("push-pointer.py <throw-cap>")
    # Nine arguments after the name, in the order the lab sends them.
    assert push_pointer.usage().count("<") == 9


def test_a_delta_is_a_whole_number_of_points():
    """A HID report carries no fractions, and the lab's own numbers are floats."""
    assert push_pointer.whole("-12.0") == -12
    assert push_pointer.whole("-60") == -60
    assert push_pointer.whole("-12.6") == -13


def test_the_kernels_answers_are_named_where_there_is_a_name():
    assert push_pointer.named(0) == "KERN_SUCCESS"
    assert push_pointer.named(-536870207) == "kIOReturnNotPrivileged"
    assert push_pointer.named(0xE00002E2) == "kIOReturnNotPermitted"
    # An answer with no name is printed rather than guessed at.
    assert push_pointer.named(0xE0000999) == "0xe0000999"


@pytest.mark.parametrize("count", [0, 1, 4, 6, 7, 8, 10, 11])
def test_the_wrong_number_of_arguments_never_posts_anything(count):
    """Nine arguments after the name is the only count that runs. Everything else
    must stop before the kernel — and the guard above proves it stopped, because a
    call that got that far would raise instead of posting. Seven is in the list
    on purpose: it is what the lab sent before the wobble, and a copy of the lab
    that old must be told so rather than push with the two new ones missing."""
    assert push_pointer.main(["push-pointer.py", *["1"] * count]) == 2


# --- The wobble ---------------------------------------------------------------------

ROCKING = [(1140.0 + 3 * (n + 1), 4.0 if n % 2 == 0 else 6.0) for n in range(6)]
# Where the wobble is placed from outside before the script runs: left of the strip, on the lower row.
PLACED = (1140.0, 6.0)


def test_the_wobble_sends_every_other_report_back_down_and_slides_on_every_one(monkeypatch, capsys):
    """Up by two rows, down by two, and three pixels to the right each time.

    The pointer has two rows between the strip's lower edge and the rows uDeck
    counts as pinned, so upward travel that adds up to anything inside them has to
    come back down between the ups — and it has to slide while it does, or the
    dwell fires in the middle of it and the push path is never asked.
    """
    code, said, kernel = run(monkeypatch, capsys, [0, -60, 0, 2, 6, -2, 0, 3, 1], ROCKING, start=PLACED)
    assert code == 0
    assert kernel.posted == [-2, 2, -2, 2, -2, 2]
    assert kernel.sideways == [3] * 6
    assert said["thrown"] == 0, "the wobble is placed from outside and needs no throw"


def test_without_the_wobble_every_report_goes_the_same_way_and_nothing_slides(monkeypatch, capsys):
    """What the push at the edge and the control in the middle of the screen send,
    which is what they sent before the wobble existed."""
    code, said, kernel = run(monkeypatch, capsys, [0, -60, 0, 2, 5, -12, 0, 0, 0], [(1280.0, 720.0)])
    assert code == 0
    assert kernel.posted == [-12] * 5
    assert kernel.sideways == [0] * 5


def test_where_the_pointer_went_after_every_report_of_the_push_is_printed(monkeypatch, capsys):
    """For the wobble the path is the measurement: which rows it rocked between,
    and how much upward travel it made inside the strip in how long. So every
    report of the push is followed by a reading of the pointer and the time since
    the push began, and the throw before it is not in the track."""
    # A clock that does not start at zero, so a time since anything other than the
    # start of the push shows up as a different number.
    ticks = iter(1 + float(n) / 100 for n in range(100))
    monkeypatch.setattr(push_pointer.time, "monotonic", lambda: next(ticks))
    code, said, _ = run(monkeypatch, capsys, [0, -60, 0, 2, 6, -2, 0, 3, 1], ROCKING, start=PLACED)
    assert code == 0
    assert [entry[:2] for entry in said["track"]] == [list(at) for at in ROCKING]
    # One clock reading when the push begins, then one per report.
    assert [entry[2] for entry in said["track"]] == [0.01, 0.02, 0.03, 0.04, 0.05, 0.06]

    thrown = run(monkeypatch, capsys, [30, -60, 0, 2, 5, -12, 0, 0, 0], DESCENT)[1]
    assert len(thrown["track"]) == 5, "the throw is not part of the track, only the push after it"
