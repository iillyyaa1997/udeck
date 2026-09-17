import signal
from dataclasses import replace
from pathlib import Path

import pytest

from udeck_e2e import config
from udeck_e2e.preflight import (
    VM,
    HostFacts,
    Process,
    assess,
    find_orphans,
    find_tart,
    parse_ps,
    parse_tart_list,
    run_command,
    stop_orphans,
)

GUEST_27 = config.GUESTS["27"]
GUEST_26 = config.GUESTS["26"]


def healthy(**changes) -> HostFacts:
    facts = HostFacts(
        tart=Path("/Users/someone/Applications/tart.app/Contents/MacOS/tart"),
        tart_version=config.TART_VERSION,
        host_macos="27.0",
        free_disk_gb=500,
        memory_gb=48,
        memory_pressure=1,
        vms=[VM(config.GUESTS["27"].golden_vm, running=False)],
        vnc_reachable_from_network=False,
    )
    return replace(facts, **changes)


def problems(facts, guest=GUEST_27, jobs=1):
    return [p.what for p in assess(facts, guest, jobs).problems]


def test_a_healthy_host_has_no_problems_and_nothing_to_note():
    assessment = assess(healthy(), GUEST_27)
    assert assessment.problems == [] and assessment.notes == []


def test_every_problem_says_what_to_do():
    facts = healthy(tart=None, free_disk_gb=1, memory_pressure=4)
    found = assess(facts, GUEST_27).problems
    assert len(found) == 3
    assert all(p.todo for p in found)


def test_missing_tart():
    assert any("Tart was not found" in p for p in problems(healthy(tart=None)))


def test_a_tart_other_than_the_pinned_one_is_refused():
    assert any("pinned" in p for p in problems(healthy(tart_version="2.38.0")))


def test_a_guest_newer_than_the_host_is_refused_but_an_older_one_is_fine():
    older_host = healthy(host_macos="26.6.2")
    assert any("needs a macOS 27 host" in p for p in problems(older_host, GUEST_27))
    assert problems(older_host, GUEST_26) == []


def test_disk_is_counted_per_machine():
    facts = healthy(free_disk_gb=config.MIN_FREE_DISK_GB_PER_VM + 1)
    assert problems(facts, jobs=1) == []
    assert any("GB is free" in p for p in problems(facts, jobs=2))


def test_memory_is_counted_per_machine_plus_the_host():
    enough_for_one = config.VM_MEMORY_GB + config.HOST_MEMORY_RESERVE_GB
    facts = healthy(memory_gb=enough_for_one)
    assert problems(facts, jobs=1) == []
    assert any("of memory" in p for p in problems(facts, jobs=2))


def test_an_unreadable_memory_size_is_not_reported_as_a_small_one():
    assert problems(healthy(memory_gb=0)) == []


def test_critical_memory_pressure_is_refused_and_a_warning_is_not():
    assert problems(healthy(memory_pressure=2)) == []
    assert any("critical memory pressure" in p for p in problems(healthy(memory_pressure=4)))


def test_a_running_machine_the_lab_did_not_create_blocks_the_run_and_a_stopped_one_does_not():
    running = healthy(vms=[VM("udeck-lab", running=True)])
    stopped = healthy(vms=[VM("udeck-lab", running=False)])
    assert any("udeck-lab" in p for p in problems(running))
    assert problems(stopped) == []


def test_a_lab_machine_still_running_after_the_orphans_were_stopped_blocks_the_run():
    facts = healthy(vms=[VM("udeck-e2e-20260916-120000Z-updates.sparkle", running=True)])
    assert any("still running" in p for p in problems(facts))


def test_kept_and_left_behind_clones_are_notes_not_problems_and_golden_images_are_neither():
    facts = healthy(
        vms=[
            VM(GUEST_27.golden_vm, running=False),
            VM(GUEST_26.golden_vm, running=False),
            VM(f"{config.KEPT_PREFIX}20260916-120000Z-panel.push", running=False),
            VM("udeck-e2e-20260916-120000Z-updates.sparkle", running=False),
        ]
    )
    assessment = assess(facts, GUEST_27)
    assert assessment.problems == []
    assert len(assessment.notes) == 2
    assert "kept for inspection" in assessment.notes[0]
    assert "left behind" in assessment.notes[1]
    assert not any("golden" in note for note in assessment.notes)


# --- Processes and orphans ---------------------------------------------------

ME = 501
START = "Wed Sep 16 17:04:32 2026"
PS = f"""\
  101   501 {START}     tart             /Users/John Doe/Applications/tart.app/Contents/MacOS/tart run udeck-e2e-20260916-120000Z-panel.push --no-graphics --vnc-experimental
  102   501 {START}     zsh              /bin/zsh -c ~/Applications/tart.app/Contents/MacOS/tart run udeck-e2e-20260916-120000Z-panel.dwell
  103   501 {START}     tart             /Users/someone/Applications/tart.app/Contents/MacOS/tart run udeck-lab --no-graphics
  104   501 {START}     tart             /Users/someone/Applications/tart.app/Contents/MacOS/tart list
  105   501 {START}     tart             tart run udeck-e2e-golden-27
  106   501 {START}     python3.13       python3 -m udeck_e2e tart run udeck-e2e-x
  107   501 {START}     tart             /opt/tart run udeck-e2e-20260916-120000Z-updates.sparkle
  108   501 {START}     tart             tart run udeck-e2e-kept-20260916-120000Z-panel.push
  109   502 {START}     tart             tart run udeck-e2e-20260916-130000Z-panel.dwell
  110   501 {START}     tart             tart run --no-graphics udeck-e2e-20260916-120000Z-panel.edge
garbage line
"""


def test_ps_lines_are_read_with_their_start_time():
    processes = parse_ps(PS)
    assert len(processes) == 10
    first = processes[0]
    assert (first.pid, first.uid, first.started, first.name) == (101, 501, START, "tart")
    assert first.args.endswith("--vnc-experimental")


def test_only_this_users_tart_running_a_lab_clone_is_an_orphan():
    orphans = find_orphans(parse_ps(PS), uid=ME, own_pid=107)
    assert [p.pid for p in orphans] == [101]
    # Not orphans: a shell that mentions tart (102), someone else's machine
    # (103), not a run (104), a golden image (105), not tart (106), this
    # process (107), a kept clone (108), another user's run (109), a run
    # written with options first, which the lab never does (110).


def test_every_tart_run_counts_as_a_running_machine():
    assert [p.pid for p in parse_ps(PS) if p.runs_a_machine] == [101, 103, 105, 107, 108, 109, 110]


class FakeHost:
    """Processes that come and go, a clock, and every signal sent."""

    def __init__(self, processes, ignores_term=()):
        self.table = {p.pid: p for p in processes}
        self.ignores_term = set(ignores_term)
        self.events = []
        self.now = 0.0

    def identify(self, pid):
        return self.table.get(pid)

    def send(self, pid, sig):
        self.events.append(("signal", pid, sig))
        if pid not in self.table:
            raise ProcessLookupError(pid)
        if sig == signal.SIGKILL or pid not in self.ignores_term:
            del self.table[pid]

    def note(self, text):
        self.events.append(("note", text))

    def sleep(self, seconds):
        self.now += seconds

    def stop(self, orphans, **kwargs):
        stop_orphans(
            orphans, self.note, self.identify, send=kwargs.get("send", self.send),
            sleep=kwargs.get("sleep", self.sleep), clock=lambda: self.now, grace=30,
        )

    def signals(self):
        return [(pid, sig) for kind, *rest in self.events if kind == "signal" for pid, sig in [rest]]


def orphan(pid, name="udeck-e2e-a", started=START):
    return Process(pid, ME, started, "tart", f"tart run {name}")


def test_an_orphan_that_exits_on_sigterm_is_not_killed():
    host = FakeHost([orphan(1)])
    host.stop([orphan(1)])
    assert host.signals() == [(1, signal.SIGTERM)]


def test_every_signal_is_noted_before_it_is_sent():
    host = FakeHost([orphan(2)], ignores_term={2})
    host.stop([orphan(2)])
    kinds = [event[0] for event in host.events]
    assert host.signals() == [(2, signal.SIGTERM), (2, signal.SIGKILL)]
    assert kinds.index("signal") > 0 and kinds[kinds.index("signal") - 1] == "note"
    last_signal = len(kinds) - 1 - kinds[::-1].index("signal")
    assert kinds[last_signal - 1] == "note"
    assert host.now >= 30


def test_an_orphan_that_is_already_gone_is_skipped_quietly():
    host = FakeHost([])
    host.stop([orphan(3)])
    assert host.events == []


def test_a_pid_reused_by_another_process_is_never_signalled():
    # Listed as the orphan; by the time of the signal the pid is someone else.
    host = FakeHost([Process(4, ME, "Thu Sep 17 09:00:00 2026", "Safari", "/Applications/Safari.app")])
    host.stop([orphan(4)])
    assert host.signals() == []


def test_a_pid_reused_while_waiting_for_sigterm_is_not_sigkilled():
    host = FakeHost([orphan(5)], ignores_term={5})

    def sleep_and_reuse(seconds):
        host.now += seconds
        host.table[5] = Process(5, ME, "Thu Sep 17 09:00:00 2026", "Safari", "/Applications/Safari.app")

    host.stop([orphan(5)], sleep=sleep_and_reuse)
    assert host.signals() == [(5, signal.SIGTERM)]


def test_a_signal_that_is_not_permitted_is_noted_not_raised():
    host = FakeHost([orphan(6)])

    def refuse(pid, sig):
        raise PermissionError(1, "Operation not permitted")

    host.stop([orphan(6)], send=refuse)
    assert any("Not allowed" in e[1] for e in host.events if e[0] == "note")


# --- Machines seen in ps -----------------------------------------------------


def test_a_tart_run_from_another_tart_home_blocks_the_run():
    facts = healthy(vms=[], machines=[Process(9, ME, START, "tart", "tart run --no-graphics elsewhere")])
    assert any("elsewhere" in p for p in problems(facts))


def test_another_users_lab_machine_is_foreign_not_an_orphan_to_report_as_stuck():
    machine = Process(9, 502, START, "tart", "tart run udeck-e2e-20260916-130000Z-panel.dwell")
    found = problems(healthy(vms=[], machines=[machine], uid=ME))
    assert any("Another virtual machine" in p and "uid 502" in p for p in found)
    assert not any("still running" in p for p in found)


def test_a_kept_clone_or_golden_image_opened_by_hand_blocks_but_is_named_as_such():
    facts = healthy(
        vms=[VM(f"{config.KEPT_PREFIX}20260916-120000Z-panel.push", running=True)],
        machines=[Process(9, ME, START, "tart", f"tart run {GUEST_27.golden_vm}")],
        uid=ME,
    )
    found = problems(facts)
    assert len(found) == 1 and "kept clone or a golden image is running" in found[0]


# --- Finding Tart ----------------------------------------------------------


def make_binary(path: Path) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("#!/bin/sh\n")
    path.chmod(0o755)
    return path


def test_tart_is_looked_for_in_the_environment_then_path_then_the_app(tmp_path):
    explicit = make_binary(tmp_path / "explicit" / "tart")
    on_path = make_binary(tmp_path / "bin" / "tart")
    app_dir = tmp_path / "Applications"
    in_app = make_binary(app_dir / "tart.app" / "Contents" / "MacOS" / "tart")
    path = str(tmp_path / "bin")

    assert find_tart({"TART": str(explicit), "PATH": path}, (app_dir,)) == explicit
    assert find_tart({"PATH": path}, (app_dir,)) == on_path
    assert find_tart({"PATH": ""}, (app_dir,)) == in_app
    assert find_tart({"PATH": ""}, (tmp_path / "nowhere",)) is None


def test_a_tart_variable_pointing_nowhere_does_not_fall_back_to_another_tart(tmp_path):
    app_dir = tmp_path / "Applications"
    make_binary(app_dir / "tart.app" / "Contents" / "MacOS" / "tart")
    assert find_tart({"TART": str(tmp_path / "missing"), "PATH": ""}, (app_dir,)) is None


def test_tart_list_json_is_read_including_escaped_slashes():
    text = (
        '[{"Name":"ghcr.io\\/cirruslabs\\/macos-golden-gate-base@sha256:972b","Running":false,'
        '"State":"stopped"},{"Name":"udeck-lab","Running":true,"State":"running"}]'
    )
    assert parse_tart_list(text) == [
        VM("ghcr.io/cirruslabs/macos-golden-gate-base@sha256:972b", False),
        VM("udeck-lab", True),
    ]


@pytest.mark.parametrize("text", ["not json", '[{"Running": true}]'])
def test_unreadable_tart_list_output_raises(text):
    with pytest.raises((ValueError, KeyError)):
        parse_tart_list(text)


def test_a_command_printing_bytes_that_are_not_utf8_does_not_stop_the_lab():
    out, problem = run_command(["/usr/bin/printf", "ok \\377\\376 done"], "printing")
    assert problem is None
    assert out.startswith("ok ") and out.endswith(" done")


def test_machines_of_other_virtualization_apps_are_a_note_not_a_refusal():
    # Docker Desktop's Linux machine is one of these; only macOS guests count
    # against the limit, and the lab cannot tell them apart from the outside.
    tart_run = Process(9, ME, START, "tart", "tart run udeck-e2e-20260916-120000Z-panel.dwell")
    facts = healthy(vms=[], machines=[tart_run], framework_machines=2, uid=ME)
    assessment = assess(facts, GUEST_27)
    assert any("another app" in note for note in assessment.notes)
    assert not any("another app" in p.what for p in assessment.problems)
    quiet = assess(healthy(vms=[], machines=[tart_run], framework_machines=1, uid=ME), GUEST_27)
    assert not any("another app" in note for note in quiet.notes)


# --- Tart's VNC and the firewall -----------------------------------------------------------


def test_the_firewall_is_read_from_socketfilterfws_own_words():
    from udeck_e2e.preflight import reachable_through_firewall as reachable

    on, off, block_state = "Firewall is enabled. (State = 1)", "Firewall is disabled. (State = 0)", "Firewall is blocking all non-essential incoming connections. (State = 2)"
    no_block_all, block_all = "Firewall has block all state set to disabled.", "Firewall has block all state set to enabled."
    permitted = "Incoming connection to /Users/x/Applications/tart.app/Contents/MacOS/tart is permitted."
    blocked = "Incoming connection to /Users/x/Applications/tart.app/Contents/MacOS/tart is blocked."
    assert reachable(off, no_block_all, blocked) is True
    assert reachable(on, no_block_all, permitted) is True
    assert reachable(on, no_block_all, blocked) is False
    assert reachable(on, block_all, permitted) is False
    assert reachable(block_state, no_block_all, permitted) is False
    assert reachable(on, no_block_all, "The application is not part of the firewall") is None
    assert reachable("", "", "") is None


def test_the_run_says_the_screen_is_reachable_from_the_network_unless_the_firewall_blocks_tart():
    (reachable,) = assess(healthy(vnc_reachable_from_network=True), GUEST_27).notes
    assert "local network can reach it" in reachable and "Firewall → Options" in reachable
    (unknown,) = assess(healthy(vnc_reachable_from_network=None), GUEST_27).notes
    assert "could not be read" in unknown and "every network interface" in unknown
    assert assess(healthy(vnc_reachable_from_network=False), GUEST_27).notes == []
    assert not any("VNC" in n for n in assess(healthy(tart=None, vnc_reachable_from_network=True), GUEST_27).notes)
