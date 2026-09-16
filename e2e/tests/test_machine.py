"""Tart, SSH and the machine lifecycle, against fakes of both programs."""

import subprocess
from pathlib import Path

import pytest

from udeck_e2e import config
from udeck_e2e.errors import LabError
from udeck_e2e.guest import SSH, parse_boot_time
from udeck_e2e.machine import VM_LIMIT_ADVICE, Machine
from udeck_e2e.tart import Tart


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
        self.host.process = process
        return process

    def ip(self, name):
        return "192.168.64.5"

    def exec(self, name, argv, step, seconds):
        self.calls.append(("exec", name, argv[0]))
        return done(argv, 0 if self.host.agent_up else 1, err="agent not running")

    def stop(self, name):
        self.calls.append(("stop", name))
        self.host.process.returncode = 0

    def rename(self, name, new):
        self.calls.append(("rename", name, new))

    def delete(self, name):
        self.calls.append(("delete", name))
        if self.host.delete_fails:
            raise LabError(f"deleting {name}", "busy")


class FakeGuest:
    """The SSH side: a boot time that moves on restart, a desktop, a shutdown."""

    def __init__(self, lab_host):
        self.lab_host = lab_host
        self.host = None
        self.commands = []
        self.boot = 1000

    def run(self, command, step, seconds=0, check=True):
        self.commands.append(command)
        if command == "sysctl -n kern.boottime":
            return done([], 0, f"{{ sec = {self.boot}, usec = 5 }} Thu")
        if command.startswith("stat -f %Su"):
            return done([], 0, "admin\nfinder\n")
        if "shutdown -r" in command:
            if self.lab_host.restarts:
                self.boot += 60
            return done([], 255)
        if "shutdown -h" in command:
            if self.lab_host.shuts_down:
                self.lab_host.process.returncode = 0
            return done([], 255)
        return done([], 0)

    def boot_time(self):
        return parse_boot_time(self.run("sysctl -n kern.boottime", "boot time").stdout)

    def wait_up(self, step, seconds=0):
        self.commands.append("wait_up")


class Host:
    def __init__(self, tmp_path):
        self.clock = Clock()
        self.notes = []
        self.limit_refusals = 0
        self.agent_up = True
        self.restarts = True
        self.shuts_down = True
        self.delete_fails = False
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
            sleep=self.clock.sleep,
            clock=self.clock,
        )

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


def test_a_restart_is_proved_by_the_boot_time_moving(host):
    host.machine.create()
    host.machine.boot()
    host.machine.reboot()
    assert host.guest.boot == 1060


def test_a_restart_that_never_happens_is_a_lab_error(host):
    host.restarts = False
    host.machine.create()
    host.machine.boot()
    with pytest.raises(LabError, match="boot time did not change"):
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


def test_ctrl_c_during_cleanup_does_not_cut_it_short(host):
    import os
    import signal

    host.machine.create()
    host.machine.boot()
    original = host.tart.delete

    def interrupted_delete(name):
        os.kill(os.getpid(), signal.SIGINT)  # Ctrl-C lands mid-cleanup
        original(name)

    host.tart.delete = interrupted_delete
    assert host.machine.close(keep=False) == []
    assert host.tart.calls[-1] == ("delete", host.machine.name)
    assert any("still cleaning up" in n for n in host.notes)
    assert signal.getsignal(signal.SIGINT) is signal.default_int_handler


def test_ctrl_c_pressed_again_and_again_abandons_the_cleanup(host):
    import os
    import signal

    from udeck_e2e.machine import ABANDON_CLEANUP_AFTER

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
