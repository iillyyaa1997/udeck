import json
import os
import stat
from datetime import datetime, timedelta, timezone

from udeck_e2e.ledger import (
    STARTED_MARKER,
    Ledger,
    RunLock,
    host_lock_path,
    mark_started,
    new_run_dir,
    prune_runs,
)

UTC = timezone.utc


def test_a_second_run_in_the_same_second_gets_its_own_directory(tmp_path):
    moment = datetime(2026, 9, 16, 17, 22, 33, tzinfo=UTC)
    first = new_run_dir(tmp_path, moment)
    second = new_run_dir(tmp_path, moment)
    assert (first.name, second.name) == ("20260916-172233Z", "20260916-172233Z-2")


def test_runs_are_named_in_utc_so_a_clock_change_cannot_reorder_them(tmp_path):
    # 02:30 in Belgrade before the October change, and 02:10 an hour later
    # after the clocks went back: in local time the later run sorts first.
    before = datetime(2026, 10, 25, 2, 30, tzinfo=timezone(timedelta(hours=2)))
    after = datetime(2026, 10, 25, 2, 10, tzinfo=timezone(timedelta(hours=1)))
    assert new_run_dir(tmp_path, before).name < new_run_dir(tmp_path, after).name


def make_runs(root, names, started=True):
    for name in names:
        (root / name).mkdir()
        if started:
            mark_started(root / name)


def test_pruning_keeps_the_newest_runs_and_only_touches_runs(tmp_path):
    runs = [f"20260916-1200{i:02d}Z" for i in range(12)]
    make_runs(tmp_path, runs)
    (tmp_path / "venv").mkdir()
    (tmp_path / "lab.lock").write_text("123")
    current = tmp_path / runs[-1]

    removed, failures = prune_runs(tmp_path, keep=10, current=current)

    assert failures == []
    assert sorted(p.name for p in removed) == runs[:2]
    left = sorted(p.name for p in tmp_path.iterdir())
    assert left == sorted(runs[2:] + ["venv", "lab.lock"])


def test_refused_runs_do_not_push_out_the_evidence_of_runs_that_checked(tmp_path):
    checked = ["20260916-100000Z"]
    refused = [f"20260916-11{i:02d}00Z" for i in range(12)]
    make_runs(tmp_path, checked)
    make_runs(tmp_path, refused, started=False)
    current = tmp_path / "20260916-120000Z"
    make_runs(tmp_path, [current.name])

    removed, _ = prune_runs(tmp_path, keep=10, current=current)

    assert sorted(p.name for p in removed) == refused[:2]
    assert (tmp_path / checked[0]).is_dir()


def test_a_numbered_run_sorts_by_number_not_by_text(tmp_path):
    # As text, "-10" sorts before "-2"; pruning must still remove "-2" first.
    make_runs(tmp_path, ["20260916-120000Z", "20260916-120000Z-2", "20260916-120000Z-10"])
    removed, _ = prune_runs(tmp_path, keep=1, current=tmp_path / "20260916-120000Z-10")
    assert sorted(p.name for p in removed) == ["20260916-120000Z", "20260916-120000Z-2"]


def test_pruning_never_removes_the_current_run_or_follows_a_symlink(tmp_path):
    make_runs(tmp_path, ["20260916-120000Z", "20260916-120001Z"])
    outside = tmp_path.parent / f"{tmp_path.name}-outside"
    outside.mkdir()
    (outside / "precious").write_text("keep me")
    mark_started(outside)
    os.symlink(outside, tmp_path / "20260916-110000Z")

    removed, _ = prune_runs(tmp_path, keep=0, current=tmp_path / "20260916-120000Z")

    assert [p.name for p in removed] == ["20260916-120001Z"]
    assert (tmp_path / "20260916-120000Z").is_dir()
    assert (outside / "precious").read_text() == "keep me"


def test_an_old_run_with_a_read_only_directory_is_still_removed(tmp_path):
    make_runs(tmp_path, ["20260916-110000Z", "20260916-120000Z"])
    locked = tmp_path / "20260916-110000Z" / "panel.dwell" / "copied-from-guest"
    locked.mkdir(parents=True)
    (locked / "log.txt").write_text("x")
    locked.chmod(stat.S_IRUSR | stat.S_IXUSR)
    try:
        removed, failures = prune_runs(tmp_path, keep=1, current=tmp_path / "20260916-120000Z")
    finally:
        if locked.exists():
            locked.chmod(stat.S_IRWXU)
    assert failures == []
    assert [p.name for p in removed] == ["20260916-110000Z"]


def test_a_run_that_cannot_be_removed_is_reported_not_raised(tmp_path, monkeypatch):
    make_runs(tmp_path, ["20260916-110000Z", "20260916-120000Z"])

    def refuse(*args, **kwargs):
        raise PermissionError(1, "Operation not permitted")

    monkeypatch.setattr(os, "chmod", refuse)
    monkeypatch.setattr(os, "rmdir", refuse)
    monkeypatch.setattr(os, "unlink", refuse)
    removed, failures = prune_runs(tmp_path, keep=1, current=tmp_path / "20260916-120000Z")
    monkeypatch.undo()

    assert removed == []
    assert len(failures) == 1 and "20260916-110000Z" in failures[0]


def test_the_ledger_is_json_lines_on_disk_as_soon_as_written(tmp_path):
    ledger = Ledger(tmp_path / "ledger.jsonl")
    ledger.write("run-start", checks=["updates.sparkle"])
    # Read before close: a run that is killed must still leave its record.
    lines = (tmp_path / "ledger.jsonl").read_text().splitlines()
    ledger.write("run-end", exit_code=0)
    ledger.close()

    assert len(lines) == 1
    first = json.loads(lines[0])
    assert first["event"] == "run-start" and first["checks"] == ["updates.sparkle"]
    assert "at" in first
    assert len((tmp_path / "ledger.jsonl").read_text().splitlines()) == 2
    assert ledger.error is None


def test_a_ledger_that_cannot_be_written_remembers_why_instead_of_raising(tmp_path, monkeypatch):
    ledger = Ledger(tmp_path / "ledger.jsonl")

    def full(fd):
        raise OSError(28, "No space left on device")

    monkeypatch.setattr(os, "fsync", full)
    ledger.write("run-start")
    ledger.write("run-end")
    ledger.close()
    assert ledger.error is not None and "No space left on device" in ledger.error


def test_text_that_is_not_utf8_is_escaped_not_fatal(tmp_path):
    ledger = Ledger(tmp_path / "ledger.jsonl")
    ledger.write("check", reason="guest said \udcff")
    ledger.close()
    assert ledger.error is None
    assert "udcff" in (tmp_path / "ledger.jsonl").read_text()


def test_only_one_run_holds_the_lock(tmp_path):
    first, second = RunLock(tmp_path / "lab.lock"), RunLock(tmp_path / "lab.lock")
    assert first.acquire() is None
    assert second.acquire() == os.getpid()
    first.release()
    assert second.acquire() is None
    second.release()


def test_the_lock_is_per_user_on_the_host_not_per_checkout(tmp_path):
    # Two checkouts — the main one and a worktree — must share one lock, or the
    # second run's pre-flight would stop the first run's machines as orphans.
    path = host_lock_path(home=tmp_path)
    assert path == tmp_path / "Library" / "Caches" / "udeck-e2e" / "lab.lock"
    assert ".build" not in path.parts
    assert STARTED_MARKER.startswith(".")
