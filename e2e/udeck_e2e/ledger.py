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
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import IO, Any

# Runs are named by their start in UTC. Local time would let a daylight-saving
# change or a flight name a newer run so that it sorts before an older one, and
# pruning would then delete the newest evidence.
RUN_NAME = re.compile(r"^\d{8}-\d{6}Z(-\d+)?$")

# Written into a run's directory once its pre-flight has passed. Runs the
# pre-flight refused are kept and pruned separately, so ten refused attempts in
# a row cannot push out the evidence of the last run that actually checked.
STARTED_MARKER = ".checks-started"


def new_run_dir(root: Path, now: datetime) -> Path:
    """A fresh directory for this run, named by its start time in UTC."""
    root.mkdir(parents=True, exist_ok=True)
    base = now.astimezone(timezone.utc).strftime("%Y%m%d-%H%M%SZ")
    candidate = root / base
    suffix = 2
    while True:
        try:
            candidate.mkdir()
            return candidate
        except FileExistsError:
            candidate = root / f"{base}-{suffix}"
            suffix += 1


def mark_started(run_dir: Path) -> None:
    (run_dir / STARTED_MARKER).touch()


def prune_runs(root: Path, keep: int, current: Path) -> tuple[list[Path], list[str]]:
    """Keep the newest `keep` runs that checked something, `current` among them,
    and the newest `keep` runs the pre-flight refused. Delete the rest.

    Returns what was deleted, and a description of anything that could not be.
    Only directories named like a run are considered, so nothing else the lab
    keeps under the same root — its Python environment, for one — can be
    mistaken for an old report; symlinks are never followed or removed. A
    directory that will not delete is reported, not raised: an old report is
    never a reason for a new run not to start.
    """
    runs = [
        p
        for p in root.iterdir()
        if RUN_NAME.match(p.name) and p.is_dir() and not p.is_symlink() and p != current
    ]
    started = sorted((p for p in runs if (p / STARTED_MARKER).exists()), key=_run_sort_key)
    refused = sorted((p for p in runs if not (p / STARTED_MARKER).exists()), key=_run_sort_key)
    doomed = started[: max(0, len(started) - (keep - 1))] + refused[: max(0, len(refused) - keep)]

    removed, failures = [], []
    for path in doomed:
        failure = _remove_tree(path)
        if failure:
            failures.append(failure)
        else:
            removed.append(path)
    return removed, failures


def _remove_tree(path: Path) -> str | None:
    """rmtree that makes read-only directories writable once before giving up."""
    failures: list[str] = []

    def retry_writable(function: Any, target: str, error: BaseException) -> None:
        try:
            parent = os.path.dirname(target)
            # Never loosen anything outside the run being deleted.
            if os.path.commonpath([parent, str(path)]) == str(path):
                os.chmod(parent, 0o700)
            if os.path.isdir(target) and not os.path.islink(target):
                os.chmod(target, 0o700)
            function(target)
        except OSError as again:
            failures.append(f"{target}: {again.strerror or again}")

    shutil.rmtree(path, onexc=retry_writable)
    if failures or path.exists():
        return f"could not delete the old run {path.name}: " + (failures[0] if failures else "still there")
    return None


def _run_sort_key(path: Path) -> tuple[str, int]:
    # "20260916-172233Z-2" sorts after "20260916-172233Z": a plain string sort
    # would put "-10" before "-2".
    day, time, *suffix = path.name.split("-")
    return f"{day}-{time}", int(suffix[0]) if suffix else 1


class Ledger:
    """Append-only JSON lines, one event each, flushed to disk as written.

    A write that fails — a full disk — does not stop the run. The first failure
    is kept in `error` and said on stderr once; the run reports it as a lab
    problem, so a run whose record is incomplete never exits 0.
    """

    def __init__(self, path: Path) -> None:
        self.path = path
        self.error: str | None = None
        self._file: IO[str] | None = None
        try:
            # backslashreplace: a message carrying bytes that are not UTF-8 is
            # written escaped rather than failing the write.
            self._file = open(path, "a", encoding="utf-8", errors="backslashreplace")
        except OSError as error:
            self._fail(error)

    def write(self, event: str, **fields: Any) -> None:
        if self._file is None:
            return
        record = {"at": datetime.now(timezone.utc).isoformat(timespec="seconds"), "event": event}
        record.update(fields)
        try:
            self._file.write(json.dumps(record, ensure_ascii=False, default=str) + "\n")
            self._file.flush()
            os.fsync(self._file.fileno())
        except (OSError, ValueError) as error:
            self._fail(error)

    def _fail(self, error: BaseException) -> None:
        if self.error is None:
            self.error = f"the ledger {self.path} could not be written: {error}"
            print(self.error, file=sys.stderr)

    def close(self) -> None:
        if self._file is not None:
            try:
                self._file.close()
            except OSError as error:
                self._fail(error)
            self._file = None


def host_lock_path(home: Path | None = None) -> Path:
    """One lock for all of this user's lab runs on this Mac.

    Not under the checkout's `.build/`: the pre-flight stops orphaned lab
    machines host-wide, so a run in a second clone or a worktree must see the
    first run's lock, or it would stop that run's machines as orphans. And
    `rm -rf .build` in the middle of a run would otherwise free the lock.
    """
    home = Path.home() if home is None else home
    return home / "Library" / "Caches" / "udeck-e2e" / "lab.lock"


class RunLock:
    """Only one lab run at a time for this user on this Mac.

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
