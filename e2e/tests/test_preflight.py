import signal
from dataclasses import replace
from pathlib import Path

import pytest

from udeck_e2e import config
from udeck_e2e.preflight import (
    VM,
    HostFacts,
    assess,
    find_orphans,
    find_tart,
    parse_tart_list,
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
    facts = healthy(vms=[VM("udeck-e2e-20260916-120000-updates.sparkle", running=True)])
    assert any("still running" in p for p in problems(facts))


def test_kept_and_left_behind_clones_are_notes_not_problems_and_golden_images_are_neither():
    facts = healthy(
        vms=[
            VM(GUEST_27.golden_vm, running=False),
            VM(GUEST_26.golden_vm, running=False),
            VM(f"{config.KEPT_PREFIX}20260916-120000-panel.push", running=False),
            VM("udeck-e2e-20260916-120000-updates.sparkle", running=False),
        ]
    )
    assessment = assess(facts, GUEST_27)
    assert assessment.problems == []
    assert len(assessment.notes) == 2
    assert "kept for inspection" in assessment.notes[0]
    assert "left behind" in assessment.notes[1]
    assert not any("golden" in note for note in assessment.notes)


# --- Orphans ---------------------------------------------------------------

PS = """\
  101 tart             /Users/John Doe/Applications/tart.app/Contents/MacOS/tart run udeck-e2e-20260916-120000-panel.push --no-graphics --vnc-experimental
  102 zsh              /bin/zsh -c ~/Applications/tart.app/Contents/MacOS/tart run udeck-e2e-20260916-120000-panel.dwell
  103 tart             /Users/someone/Applications/tart.app/Contents/MacOS/tart run udeck-lab --no-graphics
  104 tart             /Users/someone/Applications/tart.app/Contents/MacOS/tart list
  105 tart             tart run udeck-e2e-golden-27
  106 python3.13       python3 -m udeck_e2e tart run udeck-e2e-x
  107 tart             /opt/tart run udeck-e2e-20260916-120000-updates.sparkle
"""


def test_only_tart_processes_running_a_lab_machine_are_orphans():
    assert find_orphans(PS, own_pid=107) == [
        (101, "udeck-e2e-20260916-120000-panel.push"),
        (105, "udeck-e2e-golden-27"),
    ]


class FakeProcesses:
    def __init__(self, ignores_term=()):
        self.alive = {1, 2, 3}
        self.ignores_term = set(ignores_term)
        self.sent = []
        self.now = 0.0

    def send(self, pid, sig):
        self.sent.append((pid, sig))
        if pid not in self.alive:
            raise ProcessLookupError(pid)
        if sig == signal.SIGKILL or pid not in self.ignores_term:
            self.alive.discard(pid)

    def sleep(self, seconds):
        self.now += seconds


def test_an_orphan_that_exits_on_sigterm_is_not_killed():
    fake = FakeProcesses()
    report = stop_orphans(
        [(1, "udeck-e2e-a")], send=fake.send, alive=fake.alive.__contains__,
        sleep=fake.sleep, clock=lambda: fake.now, grace=30,
    )
    assert fake.sent == [(1, signal.SIGTERM)]
    assert report == ["Stopped the orphaned 'tart run udeck-e2e-a' (pid 1)."]


def test_an_orphan_that_ignores_sigterm_is_killed_after_the_grace_period():
    fake = FakeProcesses(ignores_term={2})
    report = stop_orphans(
        [(2, "udeck-e2e-b")], send=fake.send, alive=fake.alive.__contains__,
        sleep=fake.sleep, clock=lambda: fake.now, grace=30,
    )
    assert fake.sent == [(2, signal.SIGTERM), (2, signal.SIGKILL)]
    assert fake.now >= 30
    assert "Killed" in report[0]


def test_an_orphan_that_is_already_gone_is_skipped_quietly():
    fake = FakeProcesses()
    fake.alive.clear()
    report = stop_orphans(
        [(3, "udeck-e2e-c")], send=fake.send, alive=fake.alive.__contains__,
        sleep=fake.sleep, clock=lambda: fake.now,
    )
    assert report == []


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
