"""Tart, SSH and the machine lifecycle, against fakes of both programs."""

import subprocess
from pathlib import Path

import pytest

from udeck_e2e import config
from udeck_e2e.errors import LabError
from udeck_e2e.guest import SSH, parse_boot_time
from udeck_e2e.machine import VM_LIMIT_ADVICE, Machine
from udeck_e2e.tart import Tart
from udeck_e2e.vnc import Frame


def done(args, rc=0, out="", err=""):
    return subprocess.CompletedProcess(args, rc, out, err)


class Clock:
    def __init__(self):
        self.now = 0.0

    def __call__(self):
        return self.now

    def sleep(self, seconds):
        self.now += seconds


# --- Tart ------------------------------------------------------------------------


def test_a_tart_call_that_hangs_is_retried_only_when_safe_and_every_retry_is_said():
    notes, calls = [], []

    def hangs(args, **kwargs):
        calls.append(args)
        raise subprocess.TimeoutExpired(args, kwargs["timeout"])

    tart = Tart(Path("/tart"), notes.append, run=hangs)
    with pytest.raises(LabError, match="did not finish"):
        tart.list()
    assert len(calls) == 1 + config.KNOWN_FAILURE_RETRIES
    assert len(notes) == config.KNOWN_FAILURE_RETRIES and all("retry" in n for n in notes)

    calls.clear()
    notes.clear()
    with pytest.raises(LabError, match="cloning x"):
        tart.clone("golden", "x")
    assert len(calls) == 1 and notes == []


def test_a_failing_tart_call_names_the_step_and_what_tart_said():
    tart = Tart(Path("/tart"), print, run=lambda args, **k: done(args, 1, err='the specified VM "x" does not exist'))
    with pytest.raises(LabError) as raised:
        tart.delete("x")
    assert raised.value.step == "deleting x"
    assert "does not exist" in raised.value.reason


def test_asking_whether_one_machine_runs_does_not_read_every_machine():
    """Measured with --jobs 2: `tart list` reads each machine's disk image for its
    size, the image of a running machine cannot be read, and cleaning up one machine
    failed in every check because the next one was already up."""
    seen = []

    def answer(args, **kwargs):
        seen.append(args)
        if args[1] == "list":
            return done(args, 1, err=(
                '"image info --plist /Users/x/.tart/vms/other/disk.img" failed with exit code 1: '
                "Error: Failed to retrieve info for disk image: The operation couldn't be completed. "
                "Resource temporarily unavailable"
            ))
        return done(args, out='{"Running": true, "State": "running"}')

    tart = Tart(Path("/tart"), print, run=answer)
    assert tart.running("mine") is True
    assert [a[1] for a in seen] == ["get"], seen


def test_a_machine_tart_has_never_heard_of_is_not_running():
    tart = Tart(Path("/tart"), print,
                run=lambda args, **k: done(args, 1, err='the specified VM "gone" does not exist'))
    assert tart.running("gone") is False


def test_a_tart_that_cannot_answer_at_all_is_not_read_as_stopped():
    """"Not running" and "could not ask" are different, and a delete that follows a
    wrong "not running" is the one that strands a machine."""
    tart = Tart(Path("/tart"), print, run=lambda args, **k: done(args, 1, err="something else entirely"))
    with pytest.raises(LabError):
        tart.running("mine")


def test_every_tart_call_has_a_deadline():
    seen = []
    tart = Tart(Path("/tart"), print, run=lambda args, **k: seen.append(k["timeout"]) or done(args, out="[]"))
    tart.list()
    tart.clone("a", "b")
    tart.ip("b")
    assert all(isinstance(t, (int, float)) and t > 0 for t in seen) and len(seen) == 3


# --- SSH ---------------------------------------------------------------------------


def test_boot_time_is_read_from_sec_not_from_usec():
    assert parse_boot_time("{ sec = 1789571183, usec = 956652 } Wed Sep 16 15:06:23 2026") == 1789571183
    with pytest.raises(LabError):
        parse_boot_time("usec = 956652")


def test_ssh_never_reads_the_operators_configuration_and_offers_only_the_runs_key(tmp_path):
    seen = []
    ssh = SSH(tmp_path / "key", print, run=lambda args, **k: seen.append(args) or done(args))
    ssh.host = "192.168.64.9"
    ssh.run("true", "testing")
    args = seen[0]
    assert args[args.index("-F") + 1] == "/dev/null"
    assert "IdentitiesOnly=yes" in args and args[args.index("-i") + 1] == str(tmp_path / "key")


def test_an_ssh_connection_failure_is_a_lab_error_and_a_command_failure_says_its_code(tmp_path):
    ssh = SSH(tmp_path / "key", print, run=lambda args, **k: done(args, 255, err="ssh: connect to host: No route to host"))
    ssh.host = "h"
    with pytest.raises(LabError, match="No route to host"):
        ssh.run("true", "testing")
    ssh = SSH(tmp_path / "key", print, run=lambda args, **k: done(args, 3, err="nope"))
    ssh.host = "h"
    with pytest.raises(LabError, match="exited 3: nope"):
        ssh.run("false", "testing")


def test_ssh_refusals_right_after_boot_are_waited_out_and_counted(tmp_path):
    clock, notes = Clock(), []
    answers = iter([done([], 255, err="No route to host"), done([], 255, err="Connection refused"), done([], 0)])
    ssh = SSH(tmp_path / "key", notes.append, run=lambda args, **k: next(answers), sleep=clock.sleep, clock=clock)
    ssh.host = "h"
    ssh.wait_up("waiting")
    assert len(notes) == 1 and "2 refused" in notes[0] and "Connection refused" in notes[0]


def test_ssh_that_never_answers_gives_up_at_the_deadline_with_the_last_answer(tmp_path):
    clock = Clock()
    ssh = SSH(tmp_path / "key", print, run=lambda args, **k: done(args, 255, err="Connection refused"), sleep=clock.sleep, clock=clock)
    ssh.host = "h"
    with pytest.raises(LabError, match="Connection refused"):
        ssh.wait_up("waiting", seconds=30)
    assert clock.now >= 30


# --- Machine -----------------------------------------------------------------------


class FakeProcess:
    def __init__(self, exits_after=None, code=0):
        self.exits_after = exits_after
        self.returncode = None
        self.code = code
        self.polls = 0
        self.killed = False

    def poll(self):
        self.polls += 1
        if self.exits_after is not None and self.polls > self.exits_after:
            self.returncode = self.code
        return self.returncode

    def kill(self):
        self.killed = True
        self.returncode = -9


class FakeTart:
    def __init__(self, host):
        self.host = host
        self.calls = []

    def clone(self, source, name):
        self.calls.append(("clone", source, name))

    def set(self, name, *options):
        self.calls.append(("set", name, *options))

    def start(self, name, log):
        self.calls.append(("start", name))
        process = self.host.next_process()
        if self.host.limit_refusals > 0:
            self.host.limit_refusals -= 1
            log.write(b"Error: The number of VMs exceeds the system limit\n")
            log.flush()
            process = FakeProcess(exits_after=0, code=1)
        else:
            log.write(f"VNC server is running at vnc://:{self.host.vnc_password}@127.0.0.1:61000\n".encode())
            log.flush()
        self.host.process = process
        return process

    def ip(self, name):
        return "192.168.64.5"

    def exec(self, name, argv, step, seconds):
        self.calls.append(("exec", name, argv[0]))
        return done(argv, 0 if self.host.agent_up else 1, err="agent not running")

    def stop(self, name):
        self.calls.append(("stop", name))
        if self.host.process is not None:
            self.host.process.returncode = 0

    def rename(self, name, new):
        self.calls.append(("rename", name, new))

    def delete(self, name):
        self.calls.append(("delete", name))
        if self.host.delete_fails:
            raise LabError(f"deleting {name}", "busy")

    def running(self, name):
        return self.host.still_running


class FakeGuest:
    """The SSH side: a boot time that moves on restart, a desktop, a shutdown."""

    def __init__(self, lab_host):
        self.lab_host = lab_host
        self.host = None
        self.commands = []
        self.boot = 1000
        self.session = "00000000-0000-0000-0000-000000000001"

    def run(self, command, step, seconds=0, check=True):
        self.commands.append(command)
        if command == "sysctl -n kern.boottime":
            return done([], 0, f"{{ sec = {self.boot}, usec = 5 }} Thu")
        if command == "sysctl -n kern.bootsessionuuid":
            return done([], 0, self.session + "\n")
        if command.startswith("stat -f %Su"):
            return done([], 0, "admin\nfinder\n")
        if "shutdown -r" in command:
            if self.lab_host.restarts:
                self.boot += 60
                self.session = "00000000-0000-0000-0000-000000000002"
            return done([], 255)
        if "shutdown -h" in command:
            if self.lab_host.shuts_down:
                self.lab_host.process.returncode = 0
            return done([], 255)
        return done([], 0)

    def boot_time(self):
        return parse_boot_time(self.run("sysctl -n kern.boottime", "boot time").stdout)

    def boot_session(self):
        return self.run("sysctl -n kern.bootsessionuuid", "boot session").stdout.strip()

    def wait_up(self, step, seconds=0, alive=None):
        self.commands.append("wait_up")
        if alive:
            alive(step)


class FakeScreen:
    """The VNC side: frames and pointer moves, recorded."""

    def __init__(self, lab_host, address):
        self.lab_host = lab_host
        self.address = address
        self.calls = []

    def wait_for_screen(self, scratch, step, alive=None):
        self.calls.append(("wait", step))
        if alive:
            alive(step)

    def capture(self, path, step):
        self.calls.append(("capture", path.name))
        if self.lab_host.capture_fails:
            if self.lab_host.capture_kills_tart:
                self.lab_host.process.returncode = -5
            raise LabError(step, "the VNC capture failed: ConnectionRefusedError: Connection was refused")
        path.write_bytes(b"png")
        return Frame(2560, 1440, False)

    def move(self, x, y, step):
        self.calls.append(("move", x, y))

    def click(self, x, y, step):
        self.calls.append(("click", x, y))


class Host:
    def __init__(self, tmp_path):
        self.clock = Clock()
        self.notes = []
        self.limit_refusals = 0
        self.agent_up = True
        self.restarts = True
        self.shuts_down = True
        self.delete_fails = False
        self.still_running = False
        self.capture_fails = False
        self.capture_kills_tart = False
        self.vnc_password = "anchor-basket-cider-dune"
        self.screens = []
        self.process = None
        self.tart = FakeTart(self)
        self.guest = FakeGuest(self)
        key = tmp_path / "id_ed25519"
        key.write_text("private")
        Path(f"{key}.pub").write_text("ssh-ed25519 AAAA udeck-e2e")
        self.guest.key = key
        self.machine = Machine(
            name="udeck-e2e-20260916-120000Z-panel.dwell",
            source="udeck-e2e-golden-27",
            tart=self.tart,
            ssh=self.guest,
            work_dir=tmp_path / "panel.dwell",
            note=self.notes.append,
            screen_factory=self.make_screen,
            sleep=self.clock.sleep,
            clock=self.clock,
        )

    def make_screen(self, address):
        screen = FakeScreen(self, address)
        self.screens.append(screen)
        return screen

    def next_process(self):
        return FakeProcess()


@pytest.fixture
def host(tmp_path):
    return Host(tmp_path)


def test_a_clone_gets_its_own_serial_number(host):
    host.machine.create()
    assert ("set", host.machine.name, "--random-serial") in host.tart.calls


def test_booting_waits_for_address_agent_key_ssh_and_desktop(host):
    host.machine.create()
    host.machine.boot()
    execs = [c for c in host.tart.calls if c[0] == "exec"]
    assert [c[2] for c in execs] == ["/usr/bin/true", "/bin/bash"]
    assert host.guest.host == "192.168.64.5"
    assert host.guest.commands[0] == "wait_up"
    assert any(c.startswith("stat -f %Su") for c in host.guest.commands)


def test_the_vm_limit_is_retried_then_explained(host):
    host.limit_refusals = 1
    host.machine.create()
    host.machine.boot()
    assert sum(1 for c in host.tart.calls if c[0] == "start") == 2
    assert any("virtual machine limit" in n for n in host.notes)


def test_the_vm_limit_that_persists_is_explained_without_restarting_anything(host):
    host.limit_refusals = 1 + config.KNOWN_FAILURE_RETRIES
    host.machine.create()
    with pytest.raises(LabError) as raised:
        host.machine.boot()
    assert raised.value.reason == VM_LIMIT_ADVICE
    assert "restarting the Mac" in VM_LIMIT_ADVICE and "never restarts it" in VM_LIMIT_ADVICE


def test_a_tart_run_that_dies_for_another_reason_is_not_retried(host):
    host.next_process = lambda: FakeProcess(exits_after=0, code=1)
    host.machine.create()
    with pytest.raises(LabError, match="'tart run' exited 1"):
        host.machine.boot()
    assert sum(1 for c in host.tart.calls if c[0] == "start") == 1


def test_an_agent_that_never_answers_is_a_lab_error_at_its_deadline(host):
    host.agent_up = False
    host.machine.create()
    with pytest.raises(LabError, match="guest agent"):
        host.machine.boot()
    assert host.clock.now >= config.AGENT_SECONDS


def test_a_restart_is_proved_by_the_boot_session_changing(host):
    host.machine.create()
    host.machine.boot()
    host.machine.reboot()
    assert host.guest.session.endswith("2")


def test_a_clock_step_that_moves_the_boot_time_is_not_a_restart(host):
    host.restarts = False
    host.machine.create()
    host.machine.boot()
    original = host.guest.run

    def clock_steps(command, step, seconds=0, check=True):
        if "shutdown -r" in command:
            host.guest.boot += 3600  # the clock moved; nothing restarted
        return original(command, step, seconds, check)

    host.guest.run = clock_steps
    with pytest.raises(LabError, match="did not restart"):
        host.machine.reboot()


def test_after_a_restart_the_agent_is_waited_for_again(host):
    host.machine.create()
    host.machine.boot()
    before = sum(1 for c in host.tart.calls if c[0] == "exec")
    host.machine.reboot()
    assert sum(1 for c in host.tart.calls if c[0] == "exec") > before


def test_a_restart_that_never_happens_is_a_lab_error(host):
    host.restarts = False
    host.machine.create()
    host.machine.boot()
    with pytest.raises(LabError, match="did not restart"):
        host.machine.reboot()


def test_shutdown_from_inside_needs_no_tart_stop(host):
    host.machine.create()
    host.machine.boot()
    assert host.machine.close(keep=False) == []
    assert not any(c[0] == "stop" for c in host.tart.calls)
    assert host.tart.calls[-1] == ("delete", host.machine.name)


def test_a_guest_that_will_not_shut_down_is_powered_off_after_a_minute_and_reported(host):
    host.shuts_down = False
    host.machine.create()
    host.machine.boot()
    problems = host.machine.close(keep=False)
    assert any(c[0] == "stop" for c in host.tart.calls)
    assert host.clock.now >= config.SHUTDOWN_SECONDS
    assert len(problems) == 1 and "tart stop" in problems[0]
    assert host.tart.calls[-1] == ("delete", host.machine.name)


def test_keep_renames_the_clone_for_inspection_instead_of_deleting_it(host):
    host.machine.create()
    host.machine.boot()
    assert host.machine.close(keep=True) == []
    assert host.tart.calls[-1] == ("rename", host.machine.name, "udeck-e2e-kept-20260916-120000Z-panel.dwell")
    assert not any(c[0] == "delete" for c in host.tart.calls)


def test_a_clone_that_will_not_delete_is_returned_as_a_problem_not_raised(host):
    host.delete_fails = True
    host.machine.create()
    host.machine.boot()
    problems = host.machine.close(keep=False)
    assert problems == ["deleting udeck-e2e-20260916-120000Z-panel.dwell: busy"]


def test_closing_a_machine_that_was_never_cloned_deletes_nothing(host):
    assert host.machine.close(keep=False) == []
    assert host.tart.calls == []


def test_a_hung_agent_attempt_is_not_yet_rather_than_a_failure(host):
    attempts = []

    def slow_then_up(name, argv, step, seconds):
        attempts.append(argv[0])
        if len(attempts) < 3:
            raise LabError(step, f"'tart exec' did not finish in {seconds}s")
        return done(argv, 0)

    host.tart.exec = slow_then_up
    host.machine.create()
    host.machine.boot()
    assert attempts[:3] == ["/usr/bin/true"] * 3


def test_a_machine_that_never_reached_ssh_is_stopped_at_once_not_after_a_minute(host):
    host.agent_up = False
    host.machine.create()
    with pytest.raises(LabError):
        host.machine.boot()
    started = host.clock.now
    problems = host.machine.close(keep=False)
    assert host.clock.now - started < config.SHUTDOWN_SECONDS
    assert len(problems) == 1 and "never answered over SSH" in problems[0]
    assert host.tart.calls[-1] == ("delete", host.machine.name)


def test_ctrl_c_during_cleanup_finishes_the_cleanup_and_then_stops(host):
    import os
    import signal

    host.machine.create()
    host.machine.boot()
    original = host.tart.delete

    def interrupted_delete(name):
        os.kill(os.getpid(), signal.SIGINT)  # Ctrl-C lands mid-cleanup
        original(name)

    host.tart.delete = interrupted_delete
    with pytest.raises(KeyboardInterrupt):
        host.machine.close(keep=False)
    # The cleanup ran to its end before the stop took effect.
    assert host.tart.calls[-1] == ("delete", host.machine.name)
    assert any("stopping once cleaning up" in n for n in host.notes)
    assert signal.getsignal(signal.SIGINT) is signal.default_int_handler


def test_ctrl_c_pressed_again_and_again_abandons_the_cleanup(host):
    import os
    import signal

    from udeck_e2e.interrupts import ABANDON_CLEANUP_AFTER

    host.machine.create()
    host.machine.boot()

    def impatient_delete(name):
        for _ in range(ABANDON_CLEANUP_AFTER):
            os.kill(os.getpid(), signal.SIGINT)

    host.tart.delete = impatient_delete
    with pytest.raises(KeyboardInterrupt):
        host.machine.close(keep=False)
    assert signal.getsignal(signal.SIGINT) is signal.default_int_handler


def test_tart_and_ssh_children_are_out_of_the_terminals_process_group(tmp_path):
    seen = []
    Tart(Path("/tart"), print, run=lambda args, **k: seen.append(k) or done(args, out="[]")).list()
    ssh = SSH(tmp_path / "key", print, run=lambda args, **k: seen.append(k) or done(args))
    ssh.host = "h"
    ssh.run("true", "testing")
    assert [k.get("start_new_session") for k in seen] == [True, True]


# --- Found by the review of the machines ---------------------------------------------


def test_a_state_changing_tart_call_finishes_although_ctrl_c_arrives_then_stops():
    import os
    import signal

    finished = []

    def delete_that_takes_a_while(args, **kwargs):
        os.kill(os.getpid(), signal.SIGINT)
        finished.append(args)
        return done(args)

    tart = Tart(Path("/tart"), print, run=delete_that_takes_a_while)
    with pytest.raises(KeyboardInterrupt):
        tart.delete("x")
    assert finished and finished[0][1:] == ["delete", "x"]


def test_tart_never_prunes_cached_images_and_never_reads_the_terminal():
    seen = []
    tart = Tart(
        Path("/tart"),
        print,
        run=lambda args, **k: seen.append(k) or done(args, out="[]"),
        popen=lambda args, **k: seen.append(k) or FakeProcess(),
    )
    tart.list()
    tart.start("x", log=None)
    assert all(k["env"]["TART_NO_AUTO_PRUNE"] == "1" for k in seen)
    assert all(k["stdin"] is subprocess.DEVNULL for k in seen)


def test_ssh_never_reads_the_terminal_and_ask_still_raises_when_ssh_itself_fails(tmp_path):
    seen = []
    ssh = SSH(tmp_path / "key", print, run=lambda args, **k: seen.append(k) or done(args, 255, err="Connection closed"))
    ssh.host = "h"
    with pytest.raises(LabError, match="Connection closed"):
        ssh.ask("pgrep -x uDeck", "looking for uDeck")
    assert seen[0]["stdin"] is subprocess.DEVNULL
    ssh = SSH(tmp_path / "key", print, run=lambda args, **k: done(args, 1))
    ssh.host = "h"
    assert ssh.ask("pgrep -x uDeck", "looking for uDeck").returncode == 1


def test_a_probe_does_not_read_a_dropped_connection_as_not_running(host):
    from udeck_e2e import probes

    host.machine.create()
    host.machine.boot()
    host.machine.ssh = SSH(host.guest.key, print, run=lambda args, **k: done(args, 255, err="Connection reset"))
    host.machine.ssh.host = "h"
    with pytest.raises(LabError):
        probes.running(host.machine, "NotificationCenter")


def test_a_later_different_failure_is_not_blamed_on_an_earlier_limit_refusal(host):
    host.limit_refusals = 1
    starts = []
    original = host.tart.start

    def start(name, log):
        process = original(name, log)
        starts.append(process)
        if len(starts) == 2:
            log.write(b"Error: disk image is corrupt\n")
            log.flush()
            process = FakeProcess(exits_after=0, code=1)
            host.process = process
        return process

    host.tart.start = start
    host.machine.create()
    with pytest.raises(LabError) as raised:
        host.machine.boot()
    assert "disk image is corrupt" in raised.value.reason
    assert raised.value.reason != VM_LIMIT_ADVICE
    assert len(starts) == 2


def test_a_machine_that_dies_after_getting_an_address_is_reported_at_once(host):
    host.agent_up = False
    host.next_process = lambda: FakeProcess(exits_after=2, code=1)
    host.machine.create()
    with pytest.raises(LabError, match="the machine stopped"):
        host.machine.boot()
    assert host.clock.now < config.AGENT_SECONDS


def test_a_clone_that_failed_half_way_is_still_deleted(host):
    def clone_fails(source, name):
        raise LabError(f"cloning {name}", "did not finish in 900s")

    host.tart.clone = clone_fails
    with pytest.raises(LabError):
        host.machine.create()
    assert host.machine.close(keep=False) == []
    assert host.tart.calls[-1] == ("delete", host.machine.name)


def test_a_clone_that_never_reached_tarts_store_is_not_a_cleanup_problem(host):
    host.machine.create()

    def gone(name):
        raise LabError(f"deleting {name}", 'the specified VM "x" does not exist')

    host.tart.delete = gone
    assert host.machine.close(keep=False) == []


def test_a_machine_still_running_without_a_known_process_is_stopped_before_delete(host):
    host.machine.create()
    host.still_running = True
    problems = host.machine.close(keep=False)
    names = [c[0] for c in host.tart.calls]
    assert names.index("stop") < names.index("delete")
    assert len(problems) == 1 and "still running" in problems[0]


# --- The screen and the pointer --------------------------------------------------------


def test_booting_finds_the_screen_tart_printed_and_waits_for_a_real_frame(host):
    host.machine.create()
    host.machine.boot()
    (screen,) = host.screens
    assert screen.address.port == 61000 and screen.address.password == host.vnc_password
    assert screen.calls == [("wait", f"waiting for {host.machine.name}'s screen")]


def test_a_tart_run_that_prints_no_vnc_address_leaves_the_machine_unusable(host):
    host.tart.start = lambda name, log: setattr(host, "process", FakeProcess()) or host.process
    host.machine.create()
    with pytest.raises(LabError, match="did not print the address of its VNC server"):
        host.machine.boot()


def test_a_restart_waits_for_the_screen_again(host):
    host.machine.create()
    host.machine.boot()
    host.machine.reboot()
    assert host.screens[0].calls[-1] == ("wait", f"waiting for {host.machine.name}'s screen after the restart")


def test_screenshots_are_numbered_in_the_order_taken_and_named_by_their_step(host, tmp_path):
    host.machine.create()
    host.machine.boot()
    report = tmp_path / "report" / "panel.dwell"
    first = host.machine.screenshot(report, "the desktop")
    second = host.machine.screenshot(report, "After the update!")
    assert (first.name, second.name) == ("01-the-desktop.png", "02-after-the-update.png")
    (report / "07-by-hand.png").write_bytes(b"")
    assert host.machine.screenshot(report, "later").name == "08-later.png"


def test_the_screen_is_unknown_until_the_machine_has_booted(host, tmp_path):
    with pytest.raises(LabError, match="has not booted"):
        host.machine.screenshot(tmp_path, "too early")


def test_a_pointer_off_the_screen_is_refused_without_a_connection(host):
    host.machine.create()
    host.machine.boot()
    for x, y in ((config.SCREEN_WIDTH, 0), (0, config.SCREEN_HEIGHT), (-1, 5)):
        with pytest.raises(LabError, match="off the 2560×1440 screen"):
            host.machine.move_pointer(x, y, "nowhere")
    host.machine.move_pointer(config.SCREEN_WIDTH - 1, 0, "to the top-right corner")
    assert [c for c in host.screens[0].calls if c[0] == "move"] == [("move", 2559, 0)]


def test_a_screenshot_lost_because_tart_crashed_says_so_and_where_the_report_is(host, tmp_path):
    host.machine.create()
    host.machine.boot()
    host.capture_fails = host.capture_kills_tart = True
    with pytest.raises(LabError) as raised:
        host.machine.screenshot(tmp_path, "the desktop")
    assert "the machine stopped: 'tart run' was killed by SIGTRAP" in raised.value.reason
    assert "DiagnosticReports" in raised.value.reason


def test_a_screenshot_lost_on_a_running_machine_is_reported_as_it_happened(host, tmp_path):
    host.machine.create()
    host.machine.boot()
    host.capture_fails = True
    with pytest.raises(LabError, match="Connection was refused") as raised:
        host.machine.screenshot(tmp_path, "the desktop")
    assert raised.value.step == "taking the screenshot 'the desktop'"


def test_a_machine_that_dies_is_quoted_without_the_vnc_password(host, tmp_path):
    host.machine.create()
    host.machine.boot()
    # Tart prints the VNC address and nothing else while a machine lives, so on a
    # crash that address is the last line of its log.
    host.process.returncode = -5
    with pytest.raises(LabError) as raised:
        host.machine.screenshot(tmp_path, "the desktop")
    assert host.vnc_password not in raised.value.reason
    assert "vnc://:…@127.0.0.1:61000" in raised.value.reason


def test_a_machine_that_never_starts_is_quoted_without_the_vnc_password(host):
    host.next_process = lambda: FakeProcess(exits_after=0, code=1)
    host.machine.create()
    with pytest.raises(LabError) as raised:
        host.machine.boot()
    assert host.vnc_password not in raised.value.reason


def test_a_file_copied_into_the_guest_travels_over_the_runs_key_with_a_deadline(tmp_path):
    seen = []
    ssh = SSH(tmp_path / "key", print, run=lambda args, **k: seen.append((args, k)) or done(args))
    ssh.host = "192.168.64.9"
    build = tmp_path / "uDeck-0.4.1.zip"
    build.write_bytes(b"x")
    ssh.copy_in(build, "/tmp/uDeck-0.4.1.zip", "installing")
    args, kwargs = seen[0]
    assert args[0] == "/usr/bin/scp" and args[-2:] == [str(build), "admin@192.168.64.9:/tmp/uDeck-0.4.1.zip"]
    assert args[args.index("-i") + 1] == str(tmp_path / "key")
    assert "-F" in args and args[args.index("-F") + 1] == "/dev/null"
    assert isinstance(kwargs["timeout"], (int, float)) and kwargs["timeout"] > 0
    assert kwargs["stdin"] is subprocess.DEVNULL and kwargs["start_new_session"] is True


def test_a_copy_into_the_guest_that_fails_or_hangs_is_a_lab_error(tmp_path):
    ssh = SSH(tmp_path / "key", print, run=lambda args, **k: done(args, 1, err="scp: /tmp: No space left on device"))
    ssh.host = "h"
    source = tmp_path / "uDeck.zip"
    source.write_bytes(b"x")
    with pytest.raises(LabError, match="No space left"):
        ssh.copy_in(source, "/tmp/uDeck.zip", "installing")

    def hangs(args, **kwargs):
        raise subprocess.TimeoutExpired(args, kwargs["timeout"])

    ssh = SSH(tmp_path / "key", print, run=hangs)
    ssh.host = "h"
    with pytest.raises(LabError, match="took longer than 60s"):
        ssh.copy_in(source, "/tmp/uDeck.zip", "installing", seconds=60)


def test_a_click_off_the_screen_is_refused_and_one_on_it_goes_through(host):
    host.machine.create()
    host.machine.boot()
    with pytest.raises(LabError, match="off the 2560×1440 screen"):
        host.machine.click(2560, 10, "nowhere")
    host.machine.click(2559, 1439, "the corner")
    assert ("click", 2559, 1439) in host.screens[0].calls


# --- Keeping Tart's VNC server in use ---------------------------------------------------


def test_the_screen_is_used_often_enough_that_tarts_server_does_not_crash(host):
    """Measured: a connection after ~60 s with none kills the machine."""
    import time as real_time

    host.machine.create()
    host.machine.boot()
    # boot() already started it at the real interval; this test wants a fast one.
    host.machine._stop_the_heartbeat()
    host.machine.keep_the_screen_in_use(interval=0.05)
    deadline = real_time.monotonic() + 5
    while len([c for c in host.screens[0].calls if c[0] == "capture"]) < 3:
        if real_time.monotonic() > deadline:
            raise AssertionError(f"the screen was used {host.screens[0].calls} times")
        real_time.sleep(0.05)
    assert config.SCREEN_HEARTBEAT_SECONDS < 60


def test_the_heartbeat_stops_with_the_machine_and_leaves_nothing_behind(host, tmp_path):
    import time as real_time

    host.machine.create()
    host.machine.boot()
    # boot() already started it at the real interval; this test wants a fast one.
    host.machine._stop_the_heartbeat()
    host.machine.keep_the_screen_in_use(interval=0.05)
    real_time.sleep(0.2)
    host.machine.close(keep=False)
    taken = len([c for c in host.screens[0].calls if c[0] == "capture"])
    real_time.sleep(0.3)
    assert len([c for c in host.screens[0].calls if c[0] == "capture"]) == taken
    assert not (host.machine.work_dir / ".screen-in-use.png").exists()


def test_a_heartbeat_that_fails_is_said_once_and_changes_no_verdict(host):
    import time as real_time

    host.machine.create()
    host.machine.boot()
    host.capture_fails = True
    host.machine._stop_the_heartbeat()
    host.machine.keep_the_screen_in_use(interval=0.05)
    real_time.sleep(0.3)
    host.machine._stop_the_heartbeat()
    complaints = [n for n in host.notes if "could not keep" in n]
    assert len(complaints) == 1, host.notes
