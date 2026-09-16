import json
import os
from datetime import datetime

from udeck_e2e.ledger import Ledger, RunLock, new_run_dir, prune_runs


def test_a_second_run_in_the_same_second_gets_its_own_directory(tmp_path):
    moment = datetime(2026, 9, 16, 17, 22, 33)
    first = new_run_dir(tmp_path, moment)
    second = new_run_dir(tmp_path, moment)
    assert (first.name, second.name) == ("20260916-172233", "20260916-172233-2")


def make_runs(root, names):
    for name in names:
        (root / name).mkdir()


def test_pruning_keeps_the_newest_runs_and_only_touches_runs(tmp_path):
    runs = [f"20260916-1200{i:02d}" for i in range(12)]
    make_runs(tmp_path, runs)
    (tmp_path / "venv").mkdir()
    (tmp_path / "lab.lock").write_text("123")
    current = tmp_path / runs[-1]

    removed = prune_runs(tmp_path, keep=10, current=current)

    assert sorted(p.name for p in removed) == runs[:2]
    left = sorted(p.name for p in tmp_path.iterdir())
    assert left == sorted(runs[2:] + ["venv", "lab.lock"])


def test_a_numbered_run_sorts_by_number_not_by_text(tmp_path):
    # As text, "-10" sorts before "-2"; pruning must still remove "-2" first.
    make_runs(tmp_path, ["20260916-120000", "20260916-120000-2", "20260916-120000-10"])
    removed = prune_runs(tmp_path, keep=1, current=tmp_path / "20260916-120000-10")
    assert sorted(p.name for p in removed) == ["20260916-120000", "20260916-120000-2"]


def test_pruning_never_removes_the_current_run_or_follows_a_symlink(tmp_path):
    make_runs(tmp_path, ["20260916-120000", "20260916-120001"])
    outside = tmp_path.parent / f"{tmp_path.name}-outside"
    outside.mkdir()
    (outside / "precious").write_text("keep me")
    os.symlink(outside, tmp_path / "20260916-110000")

    removed = prune_runs(tmp_path, keep=0, current=tmp_path / "20260916-120000")

    assert [p.name for p in removed] == ["20260916-120001"]
    assert (tmp_path / "20260916-120000").is_dir()
    assert (outside / "precious").read_text() == "keep me"


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


def test_only_one_run_holds_the_lock(tmp_path):
    first, second = RunLock(tmp_path / "lab.lock"), RunLock(tmp_path / "lab.lock")
    assert first.acquire() is None
    assert second.acquire() == os.getpid()
    first.release()
    assert second.acquire() is None
    second.release()
