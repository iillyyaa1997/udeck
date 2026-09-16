"""Where a run leaves its evidence, and the one-run-at-a-time lock.

Every run gets `.build/e2e/<run>/`: a `ledger.jsonl` describing the run, and a
directory per check holding whatever that check collected. The ledger is
appended and flushed line by line as things happen, not written at the end, so
a run that is killed still leaves a record of how far it got.
"""

from __future__ import annotations

import fcntl
import json
import os
import re
import shutil
from datetime import datetime, timezone
from pathlib import Path
from typing import IO, Any

RUN_NAME = re.compile(r"^\d{8}-\d{6}(-\d+)?$")


def new_run_dir(root: Path, now: datetime) -> Path:
    """A fresh directory for this run, named by its local start time."""
    root.mkdir(parents=True, exist_ok=True)
    base = now.strftime("%Y%m%d-%H%M%S")
    candidate = root / base
    suffix = 2
    while True:
        try:
            candidate.mkdir()
            return candidate
        except FileExistsError:
            candidate = root / f"{base}-{suffix}"
            suffix += 1


def prune_runs(root: Path, keep: int, current: Path) -> list[Path]:
    """Delete all but the newest `keep` runs, never `current`. Returns what went.

    Only directories named like a run are considered, so nothing else the lab
    keeps under the same root — its Python environment, for one — can be
    mistaken for an old report. Symlinks are never followed or removed.
    """
    runs = sorted(
        (p for p in root.iterdir() if RUN_NAME.match(p.name) and p.is_dir() and not p.is_symlink()),
        key=_run_sort_key,
    )
    doomed = [p for p in runs[: max(0, len(runs) - keep)] if p != current]
    for path in doomed:
        shutil.rmtree(path)
    return doomed


def _run_sort_key(path: Path) -> tuple[str, int]:
    # "20260916-172233-2" sorts after "20260916-172233": a plain string sort
    # would put "-10" before "-2".
    day, time, *suffix = path.name.split("-")
    return f"{day}-{time}", int(suffix[0]) if suffix else 1


class Ledger:
    """Append-only JSON lines, one event each, flushed to disk as written."""

    def __init__(self, path: Path) -> None:
        self.path = path
        self._file: IO[str] = open(path, "a", encoding="utf-8")

    def write(self, event: str, **fields: Any) -> None:
        record = {"at": datetime.now(timezone.utc).isoformat(timespec="seconds"), "event": event}
        record.update(fields)
        self._file.write(json.dumps(record, ensure_ascii=False, default=str) + "\n")
        self._file.flush()
        os.fsync(self._file.fileno())

    def close(self) -> None:
        self._file.close()


class RunLock:
    """Only one lab run at a time on a machine.

    The pre-flight treats any lab virtual machine it finds running as an orphan
    of a run that died, and stops it. That is only safe if no other run is
    alive, which is what this lock establishes. It is an flock on a file, so the
    kernel releases it however the holder exits, crash included.
    """

    def __init__(self, path: Path) -> None:
        self.path = path
        self._file: IO[str] | None = None

    def acquire(self) -> int | None:
        """Take the lock. Returns None on success, or the holder's pid if busy."""
        self.path.parent.mkdir(parents=True, exist_ok=True)
        handle = open(self.path, "a+", encoding="utf-8")
        try:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            handle.seek(0)
            holder = handle.read().strip()
            handle.close()
            return int(holder) if holder.isdigit() else -1
        handle.seek(0)
        handle.truncate()
        handle.write(str(os.getpid()))
        handle.flush()
        self._file = handle
        return None

    def release(self) -> None:
        if self._file is not None:
            fcntl.flock(self._file, fcntl.LOCK_UN)
            self._file.close()
            self._file = None
