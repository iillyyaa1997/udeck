#!/usr/bin/env python3
"""A fake GitHub, served inside the guest: the plugin repository a lab build reads.

This runs *in the machine*, not on this Mac, with the guest's own
`/usr/bin/python3` (3.9 on the golden images, measured 2026-09-17) and nothing
but the standard library. It is the plugin catalogue's counterpart of the
update feed `updates.Feed` serves: the lab never talks to github.com — no
account, no limit shared with the rest of the network, nothing that depends on
somebody else's server — so a lab build of uDeck is pointed here through its
`Info.plist` (`UDeckPluginsAPIBase` = `<base>/api`, `UDeckPluginsRawBase` =
`<base>/raw`; `builds.Builder._verify` refuses a build that says anything else).

**Its content is fixture folders, one per commit** (`e2e/fixtures/plugin-repository/`):
a folder per commit, a file listing them oldest first (`history`), and nothing
else. The fake computes real git blob, tree and commit ids from them itself —
there is no git in the guest — so a plugin installed from it hashes, in uDeck's
Swift, to the id this Python gave it, or the install is refused. Two
independent implementations of git's hashing have to agree before any check
passes; the lab's own tests hold this one against git itself.

**It answers the subset of GitHub uDeck uses** (docs/plugin-repository.md,
"Reading a repository without downloading it"):

    GET /api/repos/{o}/{r}                               the default branch
    GET /api/repos/{o}/{r}/commits/{ref}                 a commit; the bare SHA, an ETag and 304
                                                         with Accept: application/vnd.github.sha
    GET /api/repos/{o}/{r}/commits?sha=&path=&per_page=  the commits that changed a path
    GET /api/repos/{o}/{r}/git/trees/{sha}[?recursive=1] a listing
    GET /raw/{o}/{r}/{commit}/{path}                     one file, standing in for raw.githubusercontent.com

API answers carry `x-ratelimit-remaining` and `x-ratelimit-reset`, and the
remaining count goes down with every API request, as GitHub's does. Raw answers
carry none, as GitHub's do not (measured, per the document).

**The lab drives it** by rewriting `state.json` beside it over SSH, which is read
afresh on every request:

    {"main": "c2"}                                  which commit main points at
    {"limit_until": 1790000000}                     the hourly limit is used up until then:
                                                    403 with remaining 0 and that reset
    {"alter": ["plugins/uptime/uptime.sh"]}         answer these files with different bytes
    {"truncated": true}                             say the whole-repository listing is truncated

**It keeps an access log**, one JSON object per line and per request — method,
host, path, query, status, and the headers that decide an answer — which is the
lab's oracle for what uDeck asked for and, just as much, for what it did not.
The lab's own requests carry `X-UDeck-Lab: 1` and are logged as the lab's, so
that asking the fake whether it is up is never read as uDeck asking.

    fake-github.py serve ROOT PORT OWNER/REPO LOG
    fake-github.py tree FOLDER            the git tree id of a folder on disk
"""

from __future__ import annotations

import hashlib
import http.server
import json
import os
import socketserver
import sys
import threading
import time
import urllib.parse

# The branch every fixture repository calls its default, as the official one does.
DEFAULT_BRANCH = "main"

# The header the lab marks its own requests with.
LAB_HEADER = "X-UDeck-Lab"

# What GitHub allows without signing in, per network address and hour.
LIMIT = 60
WINDOW_SECONDS = 3600

# What a fixture commit is dated: a fixed day, one day apart, so that ids never
# depend on when the lab ran.
FIRST_COMMIT_TIME = 1788256800  # 2026-09-01T10:00:00Z
COMMIT_SPACING = 86400
AUTHOR = "uDeck lab <lab@udeck.invalid>"

# Left out of a fixture folder whatever the checkout holds: Finder's litter and
# Python's. Nothing in a fixture is meant to start with a dot.
IGNORED = {".DS_Store", "__pycache__"}

# What the lab adds to a file it was told to answer differently.
ALTERATION = b"\n# changed on the way by the lab\n"

MODE_FILE = "100644"
MODE_EXECUTABLE = "100755"
MODE_LINK = "120000"
# As git writes it into a tree object; the API spells it "040000".
MODE_FOLDER = "40000"


# --- Git's hashing ----------------------------------------------------------------


def blob_id(data: bytes) -> str:
    """SHA-1 of `blob <size>\\0` and the bytes: git's id for a file."""
    return hashlib.sha1(b"blob %d\0" % len(data) + data).hexdigest()


def tree_id(entries: list[tuple[str, str, str]]) -> str:
    """Git's id for a folder, from its children as (mode, name, id).

    Sorted by the names' bytes, a folder compared as if its name ended in "/";
    each entry `<mode> <name>\\0<20-byte id>`.
    """

    def key(entry: tuple[str, str, str]) -> bytes:
        mode, name, _ = entry
        return name.encode() + (b"/" if mode == MODE_FOLDER else b"")

    body = b"".join(
        mode.encode() + b" " + name.encode() + b"\0" + bytes.fromhex(sha) for mode, name, sha in sorted(entries, key=key)
    )
    return hashlib.sha1(b"tree %d\0" % len(body) + body).hexdigest()


def commit_text(tree: str, parent: str | None, when: int, message: str) -> bytes:
    lines = [f"tree {tree}"]
    if parent:
        lines.append(f"parent {parent}")
    lines.append(f"author {AUTHOR} {when} +0000")
    lines.append(f"committer {AUTHOR} {when} +0000")
    lines.append("")
    lines.append(message)
    return ("\n".join(lines) + "\n").encode()


def commit_id(tree: str, parent: str | None, when: int, message: str) -> str:
    text = commit_text(tree, parent, when, message)
    return hashlib.sha1(b"commit %d\0" % len(text) + text).hexdigest()


# --- A folder as git sees it --------------------------------------------------------


class Snapshot:
    """One folder, hashed as git would store it: every blob and tree, by id and by path."""

    def __init__(self, folder: str) -> None:
        # id -> bytes, for blobs.
        self.blobs: dict[str, bytes] = {}
        # id -> [(mode, name, id)], for trees.
        self.trees: dict[str, list[tuple[str, str, str]]] = {}
        # path -> (mode, id), for everything under the root.
        self.paths: dict[str, tuple[str, str]] = {}
        root = self._hash(folder, "")
        if root is None:
            raise ValueError(f"{folder} has nothing in it")
        self.root = root

    def _hash(self, folder: str, prefix: str) -> str | None:
        entries = []
        for name in sorted(os.listdir(folder)):
            if name in IGNORED:
                continue
            path = os.path.join(folder, name)
            relative = prefix + name
            if os.path.islink(path):
                data = os.readlink(path).encode()
                sha = blob_id(data)
                self.blobs[sha] = data
                entries.append((MODE_LINK, name, sha))
            elif os.path.isdir(path):
                sha = self._hash(path, relative + "/")
                if sha is None:
                    # A folder with nothing in it does not exist in git.
                    continue
                entries.append((MODE_FOLDER, name, sha))
            else:
                with open(path, "rb") as file:
                    data = file.read()
                sha = blob_id(data)
                self.blobs[sha] = data
                mode = MODE_EXECUTABLE if os.stat(path).st_mode & 0o100 else MODE_FILE
                entries.append((mode, name, sha))
            self.paths[relative] = entries[-1][0], entries[-1][2]
        if not entries:
            return None
        sha = tree_id(entries)
        self.trees[sha] = entries
        return sha

    def at(self, path: str) -> tuple[str, str] | None:
        """(mode, id) of whatever is at `path`; the root for ""."""
        if path.strip("/") == "":
            return MODE_FOLDER, self.root
        return self.paths.get(path.strip("/"))


class Commit:
    def __init__(self, name: str, snapshot: Snapshot, parent: Commit | None, when: int) -> None:
        self.name = name
        self.snapshot = snapshot
        self.parent = parent
        self.when = when
        self.message = f"The lab's {name}"
        self.sha = commit_id(snapshot.root, parent.sha if parent else None, when, self.message)

    @property
    def date(self) -> str:
        return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(self.when))


class Repository:
    """Every fixture commit, in the order `history` gives, each with its parent."""

    def __init__(self, root: str) -> None:
        with open(os.path.join(root, "history")) as file:
            names = [line.strip() for line in file if line.strip() and not line.startswith("#")]
        if not names:
            raise ValueError(f"{root}/history names no commits")
        self.commits: dict[str, Commit] = {}
        self.by_sha: dict[str, Commit] = {}
        parent = None
        for index, name in enumerate(names):
            commit = Commit(name, Snapshot(os.path.join(root, name)), parent, FIRST_COMMIT_TIME + index * COMMIT_SPACING)
            self.commits[name] = commit
            self.by_sha[commit.sha] = commit
            parent = commit
        self.names = names

    def resolve(self, ref: str, main: str) -> Commit | None:
        """A branch name, a fixture's own name, or a commit id — as GitHub resolves a ref."""
        if ref == DEFAULT_BRANCH:
            return self.commits.get(main)
        return self.by_sha.get(ref)

    def tree_owner(self, sha: str) -> Snapshot | None:
        """The snapshot that holds this tree, or whose commit this is."""
        if sha in self.by_sha:
            return self.by_sha[sha].snapshot
        for commit in self.commits.values():
            if sha in commit.snapshot.trees:
                return commit.snapshot
        return None

    def facts(self) -> dict:
        """What the lab needs to know to judge uDeck: every commit's id and every folder's tree."""
        return {
            "default_branch": DEFAULT_BRANCH,
            "history": self.names,
            "commits": {
                name: {
                    "sha": commit.sha,
                    "tree": commit.snapshot.root,
                    "paths": {path: {"mode": mode, "sha": sha} for path, (mode, sha) in commit.snapshot.paths.items()},
                }
                for name, commit in self.commits.items()
            },
        }


# --- What the lab says --------------------------------------------------------------


def read_state(root: str, default_main: str) -> dict:
    """The lab's instructions as they stand now; a missing or broken file is the defaults.

    Broken is not guessed at: the lab writes the file whole and renames it into
    place, and reads it back through `/lab/state` before it relies on it.
    """
    state = {"main": default_main, "limit_until": None, "alter": [], "truncated": False}
    try:
        with open(os.path.join(root, "state.json")) as file:
            given = json.load(file)
        if isinstance(given, dict):
            state.update(given)
    except (OSError, ValueError):
        pass
    return state


class Limit:
    """GitHub's hourly allowance, counted down by every API request uDeck makes."""

    def __init__(self, now: float) -> None:
        self.lock = threading.Lock()
        self.remaining = LIMIT
        self.reset = int(now) + WINDOW_SECONDS

    def spend(self, now: float, used_up_until: int | None) -> tuple[bool, int, int]:
        """(allowed, remaining, reset) for one API request."""
        with self.lock:
            if used_up_until is not None and now < used_up_until:
                return False, 0, int(used_up_until)
            if now >= self.reset:
                self.remaining = LIMIT
                self.reset = int(now) + WINDOW_SECONDS
            if self.remaining <= 0:
                return False, 0, self.reset
            self.remaining -= 1
            return True, self.remaining, self.reset


# --- The server ---------------------------------------------------------------------


class Fake:
    def __init__(self, root: str, owner_repo: str, log_path: str, clock=time.time) -> None:
        self.root = root
        self.owner_repo = owner_repo
        self.repository = Repository(root)
        self.clock = clock
        self.limit = Limit(clock())
        self.log_lock = threading.Lock()
        self.log_path = log_path

    def state(self) -> dict:
        return read_state(self.root, self.repository.names[0])

    def log(self, entry: dict) -> None:
        line = json.dumps(entry, sort_keys=True) + "\n"
        with self.log_lock:
            with open(self.log_path, "a") as file:
                file.write(line)
                file.flush()

    # Each answer is (status, headers, body).

    def answer(self, method: str, target: str, headers: dict) -> tuple[int, dict, bytes]:
        parsed = urllib.parse.urlsplit(target)
        path = urllib.parse.unquote(parsed.path)
        query = urllib.parse.parse_qs(parsed.query)
        if method not in ("GET", "HEAD"):
            return self.json(405, {"message": "Method Not Allowed"})
        if path.startswith("/lab/"):
            return self.lab(path)
        if path.startswith("/api/"):
            return self.api(path[len("/api") :], query, headers)
        if path.startswith("/raw/"):
            return self.raw(path[len("/raw/") :])
        return self.json(404, {"message": "Not Found"})

    def lab(self, path: str) -> tuple[int, dict, bytes]:
        if path == "/lab/alive":
            return 200, {"Content-Type": "text/plain"}, b"alive\n"
        if path == "/lab/state":
            return self.json(200, self.state())
        if path == "/lab/facts":
            return self.json(200, self.repository.facts())
        return self.json(404, {"message": "Not Found"})

    def api(self, path: str, query: dict, headers: dict) -> tuple[int, dict, bytes]:
        state = self.state()
        allowed, remaining, reset = self.limit.spend(self.clock(), state.get("limit_until"))
        limits = {
            "x-ratelimit-limit": str(LIMIT),
            "x-ratelimit-remaining": str(remaining),
            "x-ratelimit-reset": str(reset),
            "x-ratelimit-used": str(LIMIT - remaining),
            "x-ratelimit-resource": "core",
        }
        if not allowed:
            status, extra, body = self.json(
                403,
                {
                    "message": "API rate limit exceeded for 127.0.0.1. (But here's the good news: Authenticated "
                    "requests get a higher rate limit.)",
                    "documentation_url": "https://docs.github.com/rest/overview/rate-limits-for-the-rest-api",
                },
            )
            return status, {**extra, **limits}, body
        status, extra, body = self.api_answer(path, query, headers, state)
        return status, {**extra, **limits}, body

    def api_answer(self, path: str, query: dict, headers: dict, state: dict) -> tuple[int, dict, bytes]:
        prefix = f"/repos/{self.owner_repo}"
        if path != prefix and not path.startswith(prefix + "/"):
            return self.json(404, {"message": "Not Found"})
        rest = path[len(prefix) :]
        main = str(state.get("main"))
        if rest in ("", "/"):
            return self.json(
                200, {"full_name": self.owner_repo, "default_branch": DEFAULT_BRANCH, "private": False}
            )
        if rest == "/commits":
            return self.history(query, main)
        if rest.startswith("/commits/"):
            return self.commit(rest[len("/commits/") :], headers, main)
        if rest.startswith("/git/trees/"):
            recursive = query.get("recursive", ["0"])[0] not in ("", "0", "false")
            return self.tree(rest[len("/git/trees/") :], recursive, bool(state.get("truncated")))
        return self.json(404, {"message": "Not Found"})

    def commit(self, ref: str, headers: dict, main: str) -> tuple[int, dict, bytes]:
        commit = self.repository.resolve(ref, main)
        if commit is None:
            return self.json(422, {"message": f"No commit found for SHA: {ref}"})
        etag = f'"{commit.sha}"'
        if "application/vnd.github.sha" in headers.get("accept", ""):
            if headers.get("if-none-match", "") == etag:
                return 304, {"ETag": etag}, b""
            return 200, {"Content-Type": "application/vnd.github.sha; charset=utf-8", "ETag": etag}, commit.sha.encode()
        status, extra, body = self.json(200, self.describe(commit))
        return status, {**extra, "ETag": etag}, body

    def describe(self, commit: Commit) -> dict:
        person = {"name": "uDeck lab", "email": "lab@udeck.invalid", "date": commit.date}
        return {
            "sha": commit.sha,
            "commit": {"message": commit.message, "author": person, "committer": person, "tree": {"sha": commit.snapshot.root}},
            "parents": [{"sha": commit.parent.sha}] if commit.parent else [],
        }

    def history(self, query: dict, main: str) -> tuple[int, dict, bytes]:
        start = self.repository.resolve(query.get("sha", [DEFAULT_BRANCH])[0], main)
        if start is None:
            return self.json(422, {"message": "No commit found"})
        path = query.get("path", [""])[0].strip("/")
        try:
            per_page = max(1, min(100, int(query.get("per_page", ["30"])[0])))
        except ValueError:
            per_page = 30
        found = []
        commit = start
        while commit is not None and len(found) < per_page:
            here = commit.snapshot.at(path) if path else None
            before = commit.parent.snapshot.at(path) if (path and commit.parent) else None
            if not path or here != before:
                found.append(self.describe(commit))
            commit = commit.parent
        return self.json(200, found)

    def tree(self, sha: str, recursive: bool, truncated: bool) -> tuple[int, dict, bytes]:
        snapshot = self.repository.tree_owner(sha)
        if snapshot is None:
            return self.json(404, {"message": "Not Found"})
        tree_sha = snapshot.root if sha in self.repository.by_sha else sha
        entries = []
        self.list_into(snapshot, tree_sha, "", recursive, entries)
        cut = truncated and recursive and tree_sha == snapshot.root
        if cut:
            # What GitHub does when a repository is too large to list in one
            # answer: part of it, and a flag saying so. The top level only is
            # enough to make uDeck take the long way round.
            entries = [entry for entry in entries if "/" not in entry["path"]]
        return self.json(200, {"sha": tree_sha, "tree": entries, "truncated": cut})

    def list_into(self, snapshot: Snapshot, tree_sha: str, prefix: str, recursive: bool, out: list) -> None:
        for mode, name, sha in snapshot.trees[tree_sha]:
            path = prefix + name
            if mode == MODE_FOLDER:
                out.append({"path": path, "mode": "040000", "type": "tree", "sha": sha})
                if recursive:
                    self.list_into(snapshot, sha, path + "/", recursive, out)
            else:
                out.append(
                    {"path": path, "mode": mode, "type": "blob", "sha": sha, "size": len(snapshot.blobs[sha])}
                )

    def raw(self, rest: str) -> tuple[int, dict, bytes]:
        parts = rest.split("/")
        owner_repo = "/".join(parts[:2])
        if owner_repo != self.owner_repo or len(parts) < 4:
            return 404, {"Content-Type": "text/plain; charset=utf-8"}, b"404: Not Found"
        state = self.state()
        commit = self.repository.resolve(parts[2], str(state.get("main")))
        path = "/".join(parts[3:])
        found = commit.snapshot.at(path) if commit else None
        if found is None or found[0] == MODE_FOLDER:
            return 404, {"Content-Type": "text/plain; charset=utf-8"}, b"404: Not Found"
        data = commit.snapshot.blobs[found[1]]
        if path in (state.get("alter") or []):
            data = data + ALTERATION
        return 200, {"Content-Type": "text/plain; charset=utf-8"}, data

    @staticmethod
    def json(status: int, value) -> tuple[int, dict, bytes]:
        return status, {"Content-Type": "application/json; charset=utf-8"}, json.dumps(value, indent=1).encode()


def handler_for(fake: Fake):
    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def do_GET(self) -> None:  # noqa: N802 — http.server's name
            self.respond("GET")

        def do_HEAD(self) -> None:  # noqa: N802
            self.respond("HEAD")

        def respond(self, method: str) -> None:
            headers = {key.lower(): value for key, value in self.headers.items()}
            try:
                status, extra, body = fake.answer(method, self.path, headers)
            except Exception as error:  # noqa: BLE001 — a fake that dies answers nobody
                status, extra, body = 500, {"Content-Type": "text/plain"}, f"the fake failed: {error!r}".encode()
            parsed = urllib.parse.urlsplit(self.path)
            fake.log(
                {
                    "at": round(fake.clock(), 3),
                    "method": method,
                    "host": parsed.path.split("/")[1] if parsed.path.count("/") >= 1 else "",
                    "path": urllib.parse.unquote(parsed.path),
                    "query": parsed.query,
                    "status": status,
                    "lab": LAB_HEADER.lower() in headers,
                    "user_agent": headers.get("user-agent", ""),
                    "accept": headers.get("accept", ""),
                    "if_none_match": headers.get("if-none-match", ""),
                }
            )
            self.send_response(status)
            for key, value in extra.items():
                self.send_header(key, value)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            if method != "HEAD" and status != 304:
                self.wfile.write(body)

        def log_message(self, format: str, *args) -> None:  # noqa: A002 — http.server's name
            # The JSON log above is the record; stderr stays for the fake's own failures.
            pass

    return Handler


# The line the fake prints once its socket is listening, and not before: the lab
# asks nothing of it until the line is there (`FakeGitHub._wait_until_it_answers`).
LISTENING = "listening"


class Server(http.server.ThreadingHTTPServer):
    """http.server's own, without the name lookup it makes between bind and listen.

    `HTTPServer.server_bind` asks `socket.getfqdn` for the address it bound, and
    until that returns the port is bound and not listening. macOS drops a
    connection attempt to such a port without an answer — no refusal — so a
    client that asked in that window waits on its own retransmissions: 1, 2, 3,
    4, 5, 7, 11, 19 and 35 seconds after it asked (measured on the lab's Mac with
    curl, against a port that began to listen 20 seconds after it was bound: the
    answer came 35 seconds after the question). The name is never used — no
    answer here is built with it — so it is not looked up.
    """

    daemon_threads = True

    def server_bind(self) -> None:
        socketserver.TCPServer.server_bind(self)
        self.server_name, self.server_port = self.server_address[:2]


def serve(root: str, port: int, owner_repo: str, log_path: str) -> None:
    started = time.monotonic()
    fake = Fake(root, owner_repo, log_path)
    # 127.0.0.1 and nothing else: the guest's own network is reachable from the
    # Mac the lab runs on (measured for the update feed), and nothing outside the
    # machine has any business with this.
    server = Server(("127.0.0.1", port), handler_for(fake))
    # How long it took is part of the line: a fake slow to start is what the lab
    # has to be able to tell from a fake that never answers.
    print(
        f"{LISTENING}: {owner_repo} from {root} on 127.0.0.1:{port}, {time.monotonic() - started:.2f}s after it started",
        flush=True,
    )
    server.serve_forever()


def main(argv: list[str]) -> int:
    if len(argv) == 5 and argv[0] == "serve":
        serve(argv[1], int(argv[2]), argv[3], argv[4])
        return 0
    if len(argv) == 2 and argv[0] == "tree":
        print(Snapshot(argv[1]).root)
        return 0
    print(__doc__.split("\n\n")[-1] if __doc__ else "", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
