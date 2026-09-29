"""The plugin repository a lab build reads: a fake GitHub, served inside the guest.

What the update feed is to the update checks (`updates.Feed`), this is to the
plugin checks. The server itself is `e2e/guest/fake-github.py` — it runs in the
machine, with the guest's own Python and the standard library only — and its
content is the fixture folders in `e2e/fixtures/plugin-repository/`, one per
commit, which it hashes into real git ids. This module is the lab's hand on it:
putting it in the guest, telling it what to say, and reading back what it was
asked.

**The access log is the oracle.** Every request the fake answers is one JSON line
— method, host, path, query, status — and a lab build of uDeck is the only thing
in the machine that knows the fake's address (`builds.Builder._verify` refuses a
build that carries any other). So a request in that log that is not the lab's own
is uDeck's, and the checks judge on it: what uDeck asked for, and just as much
what it did not. The lab's own requests carry `fake-github.py`'s `LAB_HEADER`
and are logged as the lab's, the way `updates.LAB_PROBE` keeps the lab's probes of
the feed out of uDeck's account.

**The lab drives the fake by rewriting one small file over SSH** (`state.json`
beside it), which the fake reads on every request: which commit `main` points
at, whether the hourly limit is used up and until when, which files to answer
with different bytes, whether to say the listing is truncated. Each change is
read back through the fake itself (`/lab/state`) before a check relies on it: a
state file that did not take would make every sentence after it about the lab.
"""

from __future__ import annotations

import json
import shlex
import tarfile
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path

from udeck_e2e import config
from udeck_e2e.errors import LabError

Note = Callable[[str], None]

E2E_DIR = Path(__file__).resolve().parent.parent
SCRIPT = E2E_DIR / "guest" / "fake-github.py"
FIXTURES = E2E_DIR / "fixtures" / "plugin-repository"

# Where the guest keeps the fake, its content and its log.
GUEST_DIR = "/tmp/udeck-e2e-github"

# The guest's own Python: 3.9 and the standard library, which is all the fake uses.
GUEST_PYTHON = "/usr/bin/python3"

# The header the lab marks its own requests with; `fake-github.py` names it too.
LAB_HEADER = "X-UDeck-Lab"

# What the fixtures leave out whatever the checkout holds, as the fake does.
_LEFT_OUT = {".DS_Store", "__pycache__"}


def base_url(port: int = config.PLUGINS_PORT) -> str:
    """The fake's address, as every lab build carries it (`Scripts/make-app.sh --test-plugins`)."""
    return f"http://127.0.0.1:{port}"


@dataclass(frozen=True)
class Request:
    """One line of the fake's access log."""

    at: float
    method: str
    host: str
    path: str
    query: str
    status: int
    lab: bool
    user_agent: str = ""
    accept: str = ""
    if_none_match: str = ""

    @property
    def is_api(self) -> bool:
        return self.host == "api"

    @property
    def is_raw(self) -> bool:
        return self.host == "raw"

    def raw_file(self, repository: str = config.PLUGINS_REPOSITORY) -> tuple[str, str] | None:
        """(commit, path in the repository) for a raw request of this repository, else None."""
        prefix = f"/raw/{repository}/"
        if not self.is_raw or not self.path.startswith(prefix):
            return None
        commit, _, path = self.path[len(prefix) :].partition("/")
        return commit, path

    def __str__(self) -> str:
        query = f"?{self.query}" if self.query else ""
        return f"{self.method} {self.path}{query} → {self.status}"


def parse_log(text: str) -> list[Request]:
    """Every request in the fake's log, the lab's included, in the order they were answered.

    A last line without its line break is a line still being written — the log
    is read while the fake runs — and is left for the next read rather than
    guessed at. Any other line that is not a request is the lab unable to read
    its own oracle, and says so: a line skipped quietly would be a request of
    uDeck's the verdict never saw.
    """
    lines = text.split("\n")
    complete, _last = lines[:-1], lines[-1]
    found = []
    for line in complete:
        if not line.strip():
            continue
        try:
            entry = json.loads(line)
            found.append(
                Request(
                    at=float(entry["at"]),
                    method=str(entry["method"]),
                    host=str(entry["host"]),
                    path=str(entry["path"]),
                    query=str(entry["query"]),
                    status=int(entry["status"]),
                    lab=bool(entry["lab"]),
                    user_agent=str(entry.get("user_agent", "")),
                    accept=str(entry.get("accept", "")),
                    if_none_match=str(entry.get("if_none_match", "")),
                )
            )
        except (ValueError, KeyError, TypeError) as error:
            raise ValueError(f"a line of the fake's log is not a request ({error}): {line[:200]!r}") from None
    return found


def uDecks(requests: list[Request]) -> list[Request]:
    """The requests that were not the lab's own: in the guest, uDeck's."""
    return [request for request in requests if not request.lab]


def pack(fixtures: Path, into: Path) -> Path:
    """The fixture commits and their history as one archive, symbolic links and modes kept.

    One archive rather than a copy per file: a fixture holds a symbolic link, and
    the executable bits are what the fake hashes into modes, so both have to
    arrive as they are in the checkout — which `scp` of single files would not
    do for the link.
    """

    def keep(member: tarfile.TarInfo) -> tarfile.TarInfo | None:
        if Path(member.name).name in _LEFT_OUT:
            return None
        member.uid = member.gid = 0
        member.uname = member.gname = ""
        return member

    archive = into / "plugin-repository.tar.gz"
    with tarfile.open(archive, "w:gz") as tar:
        tar.add(fixtures, arcname="repository", filter=keep)
    return archive


class FakeGitHub:
    """The fake, in one machine: served on the guest's loopback, told what to say, and listened to."""

    def __init__(
        self,
        machine,
        note: Note,
        port: int = config.PLUGINS_PORT,
        fixtures: Path = FIXTURES,
        guest_dir: str = GUEST_DIR,
        python: str = GUEST_PYTHON,
    ) -> None:
        self.machine = machine
        self.note = note
        self.port = port
        self.fixtures = fixtures
        self.dir = guest_dir
        self.python = python
        self.script = f"{guest_dir}/fake-github.py"
        self.root = f"{guest_dir}/repository"
        self.log = f"{guest_dir}/requests.jsonl"
        self.state_file = f"{self.root}/state.json"
        self.serving = False
        self._facts: dict | None = None

    @property
    def base_url(self) -> str:
        return base_url(self.port)

    # --- Serving --------------------------------------------------------------------

    def serve(self, work_dir: Path, **state) -> None:
        """Put the fake and its fixtures in the guest, say what it says first, and start it.

        `state` is the first `state.json` — `main="c1"` and the like — written
        before the fake starts, so that nothing uDeck asks can be answered from a
        state the check did not choose.
        """
        step = f"serving the fake GitHub in {self.machine.name}"
        archive = pack(self.fixtures, work_dir)
        ssh = self.machine.ssh
        ssh.run(f"rm -rf {shlex.quote(self.dir)} && mkdir -p {shlex.quote(self.dir)}", step)
        ssh.copy_in(SCRIPT, self.script, step)
        ssh.copy_in(archive, f"{self.dir}/{archive.name}", step)
        ssh.run(f"cd {shlex.quote(self.dir)} && tar -xzf {shlex.quote(archive.name)}", step)
        self._write_state(state, step)
        ssh.run(
            f"cd {shlex.quote(self.dir)} && "
            f"({shlex.quote(self.python)} {shlex.quote(self.script)} serve {shlex.quote(self.root)} {self.port} "
            f"{shlex.quote(config.PLUGINS_REPOSITORY)} {shlex.quote(self.log)} >server.out 2>&1 & echo $! >server.pid)",
            step,
        )
        self.serving = True
        self._wait_until_it_answers(step)
        self._expect_state(state, step)

    def _wait_until_it_answers(self, step: str) -> None:
        deadline = self.machine.clock() + config.PLUGINS_UP_SECONDS
        while True:
            if self.answers_now(step):
                return
            if self.machine.clock() >= deadline:
                said = self.machine.ssh.ask(f"tail -5 {shlex.quote(self.dir)}/server.out", step).stdout.strip()
                raise LabError(
                    step, f"the fake GitHub did not answer within {config.PLUGINS_UP_SECONDS:.0f}s: {said or 'it said nothing'}"
                )
            self.machine.sleep(1)

    def _ask(self, what: str, step: str) -> tuple[int, str]:
        """One request of the lab's own to the fake — marked, so the log never counts it as uDeck's."""
        done = self.machine.ssh.ask(
            f"/usr/bin/curl -s -H {shlex.quote(LAB_HEADER + ': 1')} -w '\\n%{{http_code}}' "
            f"{shlex.quote(self.base_url + what)}",
            step,
            seconds=30,
        )
        body, _, code = (done.stdout or "").rpartition("\n")
        try:
            return int(code.strip()), body
        except ValueError:
            return 0, done.stdout or ""

    def answers_now(self, step: str) -> bool:
        """Whether the fake is still there, asked once — for a check about to judge a silence."""
        try:
            status, _ = self._ask("/lab/alive", step)
        except LabError:
            return False
        return status == 200

    # --- Telling it what to say -------------------------------------------------------

    def _write_state(self, state: dict, step: str) -> None:
        text = json.dumps(state, sort_keys=True)
        self.machine.ssh.run(
            f"printf %s {shlex.quote(text)} > {shlex.quote(self.state_file)}.new && "
            f"mv {shlex.quote(self.state_file)}.new {shlex.quote(self.state_file)}",
            step,
        )

    def _expect_state(self, wanted: dict, step: str) -> dict:
        status, body = self._ask("/lab/state", step)
        try:
            said = json.loads(body) if status == 200 else None
        except ValueError:
            said = None
        if not isinstance(said, dict) or any(said.get(key) != value for key, value in wanted.items()):
            raise LabError(step, f"the fake was told {wanted} and says its state is {said if said is not None else body[:200]!r}")
        return said

    def tell(self, step: str, **changes) -> dict:
        """Change what the fake says, and read it back through the fake before anything relies on it."""
        status, body = self._ask("/lab/state", step)
        try:
            state = json.loads(body) if status == 200 else None
        except ValueError:
            state = None
        if not isinstance(state, dict):
            raise LabError(step, f"the fake would not say what it is saying now: {status} {body[:200]!r}")
        state.update(changes)
        self._write_state(state, step)
        return self._expect_state(changes, step)

    # --- What it holds ----------------------------------------------------------------

    def facts(self, step: str = "asking the fake what its commits are") -> dict:
        """Every fixture commit's id, and every path's mode and id in it, as the fake hashed them."""
        if self._facts is None:
            status, body = self._ask("/lab/facts", step)
            try:
                self._facts = json.loads(body) if status == 200 else None
            except ValueError:
                self._facts = None
            if not isinstance(self._facts, dict):
                raise LabError(step, f"the fake would not say what it holds: {status} {body[:200]!r}")
        return self._facts

    def commit(self, name: str) -> str:
        """The id the fake gave fixture commit `name`."""
        return self.facts()["commits"][name]["sha"]

    def tree(self, name: str, path: str) -> str:
        """The id of the folder at `path` in fixture commit `name`."""
        return self.facts()["commits"][name]["paths"][path]["sha"]

    def files(self, name: str, folder: str) -> dict[str, str]:
        """Every file under `folder` in fixture commit `name`, path → mode."""
        paths = self.facts()["commits"][name]["paths"]
        return {path: entry["mode"] for path, entry in paths.items() if path.startswith(folder + "/") and entry["mode"] != "40000"}

    def tree_in_guest(self, folder: str, step: str) -> str:
        """The git tree id of a folder in the guest, hashed by the fake's own code, in the guest."""
        done = self.machine.ssh.ask(f"{shlex.quote(self.python)} {shlex.quote(self.script)} tree {folder}", step)
        said = (done.stdout or "").strip()
        if done.returncode != 0 or len(said) != 40:
            raise LabError(step, f"the folder {folder} could not be hashed in the guest: {(done.stderr or said).strip()[:200]}")
        return said

    # --- What it was asked ------------------------------------------------------------

    def read_log(self, step: str) -> list[Request]:
        """Every request so far, the lab's included — as an oracle, so it raises rather than read as empty."""
        done = self.machine.ssh.ask(f"cat {shlex.quote(self.log)} 2>/dev/null || true", step)
        if done.returncode != 0:
            raise LabError(step, f"the fake's log could not be read: exit {done.returncode}")
        try:
            return parse_log(done.stdout or "")
        except ValueError as error:
            raise LabError(step, str(error)) from None

    def uDecks_requests(self, step: str) -> list[Request]:
        return uDecks(self.read_log(step))

    def collect_log(self, directory: Path, name: str = "github-requests.jsonl") -> str:
        """The fake's log, kept beside the report. Evidence: never raises."""
        try:
            text = self.machine.ssh.ask(f"cat {shlex.quote(self.log)} 2>/dev/null || true", "collecting the fake's log").stdout
        except LabError as error:
            self.note(f"   the fake GitHub's log could not be read: {error.reason}")
            return ""
        try:
            (directory / name).write_text(text)
        except OSError as error:
            self.note(f"   the fake GitHub's log could not be written to {directory / name}: {error}")
        return text

    def stop(self) -> None:
        """Stop serving. Said, not raised: a check's verdict does not turn on this."""
        if not self.serving:
            return
        try:
            self.machine.ssh.run(
                f"kill $(cat {shlex.quote(self.dir)}/server.pid) 2>/dev/null; exit 0",
                f"stopping the fake GitHub in {self.machine.name}",
                check=False,
            )
            self.serving = False
        except LabError as error:
            self.note(f"   the fake GitHub in {self.machine.name} could not be stopped: {error}")


def described(requests: list[Request]) -> str:
    """Requests as a report says them, one after another."""
    return "; ".join(str(request) for request in requests) or "none"


def tar_names(archive: Path) -> list[str]:
    """What an archive `pack` made holds — for the lab's own tests."""
    with tarfile.open(archive) as tar:
        return tar.getnames()

