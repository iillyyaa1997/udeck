#!/usr/bin/env python3
"""A fake GitHub, served inside the guest: the plugin repository a lab build reads.

This runs *in the machine*, not on this Mac, with the guest's own
`/usr/bin/python3` (3.9 on the golden images, measured 2026-09-17) and nothing
but the standard library. It is the plugin catalogue's counterpart of the
update feed `updates.Feed` serves: the plugin checks never talk to github.com —
no account, no limit shared with the rest of the network, nothing that depends
on somebody else's server (only the update checks that take a published release
do) — so a lab build of uDeck is pointed here through its
`Info.plist` (`UDeckPluginsAPIBase` = `<base>/api`, `UDeckPluginsRawBase` =
`<base>/raw`; `builds.Builder._verify` refuses a build that says anything else).

**Its content is fixture folders, one per commit** (`e2e/fixtures/plugin-repository/`):
a folder per commit, a file listing the main line oldest first (`history`),
each the parent of the next, and a file naming the commits off it with the
commit each was made on (`parents`) — a pull request's head, a branch's commit,
a squash merge — and, where it is another commit's content again, the folder
it takes it from: a pull request squash-merged as exactly its head is a new
commit, on another parent, with the same tree.
The fake computes real git blob, tree and commit ids from them itself — there
is no git in the guest — so a plugin installed from it hashes, in uDeck's
Swift, to the id this Python gave it, or the install is refused. Two
independent implementations of git's hashing have to agree before any check
passes; the lab's own tests hold this one against git itself.

**It answers the subset of GitHub uDeck uses** (docs/plugin-repository.md,
"Reading a repository without downloading it"):

    GET /api/repos/{o}/{r}                               the default branch
    GET /api/repos/{o}/{r}/commits/{ref}                 a commit; the bare SHA, an ETag and 304
                                                         with Accept: application/vnd.github.sha. {ref}
                                                         is main, a branch — bare or refs/heads/{b} —
                                                         refs/pull/{n}/head, or any commit's id
    GET /api/repos/{o}/{r}/commits?sha=&path=&per_page=  the commits that changed a path, parent by parent
    GET /api/repos/{o}/{r}/git/trees/{sha}[?recursive=1] a listing, of any commit, on the main line or off it
    GET /api/repos/{o}/{r}/pulls/{n}                     a pull request: its head, state, merge, the
                                                         repository it came from; an ETag and 304
    GET /api/repos/{o}/{r}/compare/{base}...{head}       two commits compared through their parents:
                                                         ahead, behind, identical or diverged, and by how
                                                         many; a commit that is not there is 404
    GET /raw/{o}/{r}/{commit}/{path}                     one file, standing in for raw.githubusercontent.com

A fork the lab names (`forks` below) answers on the same host, from the same
commits — a fork shares its network's objects — with branches of its own:

    GET /api/repos/{fork}                                its description: `fork`, and the repository it was
                                                         forked from (`parent`) and its network's root
                                                         (`source`) — or `fork` false, a repository of its own
    GET /api/repos/{fork}/commits/{ref}                  its branches' heads, with the ETag and 304, and any
                                                         commit's id
    GET /api/repos/{fork}/git/trees/{sha}[?recursive=1]  a listing
    GET /api/repos/{fork}/compare/{base}...{head}        two commits compared
    GET /raw/{fork}/{commit}/{path}                      one file

**Repositories of their own** — each with its own history and its own number —
are the fixture folders `sources/github/<owner>/<repo>/` (stage 4): each a
`history`, an optional `parents`, its commit folders and an `id`, the number
GitHub gives it. Each is served by its name and by its number, as GitHub serves
a repository:

    GET /api/repos/{o}/{r}[/…]                           by its name, as it is called now
    GET /api/repositories/{id}[/…]                       by its number: its description (with `full_name`, as
                                                         it is called now), its head with the ETag and 304, a
                                                         folder's history, a listing, a comparison
    GET /raw/{o}/{r}/{commit}/{path}                     one file, by its name now

Which name each is called by is the lab's to say (`served`), so that a
repository can be renamed — its number the same — and another one, with a
number of its own, made at its old name.

Every request to any of them spends the same hourly limit, as GitHub counts what
an address asks whichever repository it asks about. A repository the lab does
not name is 404.

API answers carry `x-ratelimit-remaining` and `x-ratelimit-reset`, and the
remaining count goes down with every API request, as GitHub's does. Raw answers
carry none, as GitHub's do not (measured, per the document).

**The lab drives it** by rewriting `state.json` beside it over SSH, which is read
afresh on every request:

    {"main": "c2"}                                  which commit main points at
    {"branches": {"fix/uptime": "pr3"}}             the other branches, each at a fixture commit;
                                                    one left out is deleted (422, as GitHub's)
    {"pulls": {"3": {"head": "pr3", "head_repo": "someone/udeck-plugins", "head_ref": "fix",
                     "state": "open", "merged": false, "merge_commit": null, "title": "…"}}}
                                                    pull requests by number, each head at a fixture
                                                    commit; head_repo null is a deleted fork, absent
                                                    the repository itself; merge_commit is read only
                                                    when merged; refs/pull/{n}/head follows head
    {"forks": {"someone/udeck-plugins": {"branches": {"x": "pr3"}}}}
                                                    other repositories on the host, each a fork of this
                                                    one with branches of its own, each at a fixture
                                                    commit (one left out is deleted); "fork": false makes
                                                    it a repository of its own, "source" and "parent" a
                                                    fork of something else, "default_branch" names its
                                                    default (main)
    {"limit_until": 1790000000}                     the hourly limit is used up until then:
                                                    403 with remaining 0 and that reset
    {"spent": 50}                                   that many of the hour's requests already spent by
                                                    something else on the connection: what is left
                                                    says so, and runs out that much sooner
    {"alter": ["plugins/uptime/uptime.sh"]}         answer these files with different bytes
    {"truncated": true}                             say the whole-repository listing is truncated
    {"official_id": 12345}                          the number the official repository's description
                                                    answers (its `id` file's otherwise)
    {"sources": {"someone/team-plugins": {"main": "t2"}}}
                                                    which commit each repository of its own's main points
                                                    at, by its fixture folder (its first commit otherwise)
    {"served": {"someone/team-plugins-2": "someone/team-plugins",
                "someone/team-plugins": "someone/squatter"}}
                                                    which name serves which repository of its own: every
                                                    one by its own folder's name unless the lab says

Moving a branch's head, force-pushing it, merging or closing a pull request is
one rewrite of the file: a head at another fixture commit — one that does not
descend from the one before, for a force push — `state` and `merged` changed, a
branch left out; a fork's branch the same way, inside `forks`.

**It keeps an access log**, one JSON object per line and per request — method,
host, path, query, status, the port it came in on, and the headers that decide
an answer — which is the lab's oracle for what uDeck asked for and, just as
much, for what it did not. The lab's own requests carry `X-UDeck-Lab: 1` and are
logged as the lab's, so that asking the fake whether it is up is never read as
uDeck asking. Each line says whether the request carried a credential —
`credential`: `none`, `accepted` or `rejected`, and never its value — and no
credential is good for anything yet: one carried is answered `401 Bad
credentials`, as GitHub answers a token it does not know.

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

# Where the repositories of their own are, under the fixture root: `<owner>/<repo>/`.
SOURCES = os.path.join("sources", "github")

# The headers a credential travels in, GitHub's and GitLab's.
CREDENTIAL_HEADERS = ("authorization", "private-token")

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


def read_lines(path: str) -> list[str]:
    """A fixture list's lines, comments and blank lines left out; none when there is no file."""
    try:
        with open(path) as file:
            return [line.strip() for line in file if line.strip() and not line.lstrip().startswith("#")]
    except FileNotFoundError:
        return []


def read_number(path: str) -> int:
    """The number an `id` file gives, its comments and blank lines left out."""
    lines = read_lines(path)
    if len(lines) != 1 or not lines[0].isdigit() or int(lines[0]) <= 0:
        raise ValueError(f"{path} does not say one number above 0: {lines}")
    return int(lines[0])


class Repository:
    """Every fixture commit with its parent: the main line in the order `history`
    gives, each the parent of the next, and the commits `parents` names off it —
    each line `<commit> <made on> [<content>]`, the content being the folder of
    the commit's own name unless a third name says whose folder it is."""

    def __init__(self, root: str) -> None:
        names = read_lines(os.path.join(root, "history"))
        if not names:
            raise ValueError(f"{root}/history names no commits")
        self.commits: dict[str, Commit] = {}
        self.by_sha: dict[str, Commit] = {}
        parent = None
        for index, name in enumerate(names):
            parent = self._add(root, name, parent, FIRST_COMMIT_TIME + index * COMMIT_SPACING)
        self.names = names
        # Off the main line: dated after all of it, one day apart, in the
        # order the file gives — each made on a commit named before it.
        self.parents: dict[str, str] = {}
        # The folder each commit off the main line takes its content from,
        # where that is not its own.
        self.contents: dict[str, str] = {}
        for index, line in enumerate(read_lines(os.path.join(root, "parents"))):
            fields = line.split()
            if len(fields) not in (2, 3):
                raise ValueError(f"{root}/parents: {line!r} is not a commit and the commit it was made on")
            name, on = fields[0], fields[1]
            content = fields[2] if len(fields) == 3 else name
            if name in self.commits:
                raise ValueError(f"{root}/parents: {name} is named twice")
            if on not in self.commits:
                raise ValueError(f"{root}/parents: {name} is made on {on}, which no line before it names")
            if not os.path.isdir(os.path.join(root, content)):
                raise ValueError(f"{root}/parents: {name} takes its content from {content}, which is no folder here")
            self._add(root, name, self.commits[on], FIRST_COMMIT_TIME + (len(names) + index) * COMMIT_SPACING, content)
            self.parents[name] = on
            if content != name:
                self.contents[name] = content

    def _add(self, root: str, name: str, parent: Commit | None, when: int, content: str | None = None) -> Commit:
        commit = Commit(name, Snapshot(os.path.join(root, content or name)), parent, when)
        self.commits[name] = commit
        self.by_sha[commit.sha] = commit
        return commit

    def resolve(self, ref: str, state: dict) -> Commit | None:
        """`main`, another branch — bare or as `refs/heads/{b}` — `refs/pull/{n}/head`,
        or a commit id, as GitHub resolves a ref, with the branches and pull
        requests the lab's state names."""
        branches = state.get("branches") or {}
        pulls = state.get("pulls") or {}
        name = ref
        if ref.startswith("refs/pull/") and ref.endswith("/head"):
            pull = pulls.get(ref[len("refs/pull/") : -len("/head")])
            return self.commits.get(str(pull.get("head"))) if isinstance(pull, dict) else None
        if ref.startswith("refs/heads/"):
            name = ref[len("refs/heads/") :]
        elif ref.startswith("refs/"):
            return None
        if name == DEFAULT_BRANCH:
            return self.commits.get(str(state.get("main")))
        if name in branches:
            return self.commits.get(str(branches[name]))
        return None if name != ref else self.by_sha.get(ref)

    def resolve_in_fork(self, ref: str, fork: dict) -> Commit | None:
        """A ref of a fork, as GitHub resolves one there: its own branches — bare or as `refs/heads/{b}` — or any
        commit's id; a fork's pull requests are not the lab's to name."""
        branches = fork.get("branches") or {}
        name = ref[len("refs/heads/") :] if ref.startswith("refs/heads/") else ref
        if ref.startswith("refs/") and not ref.startswith("refs/heads/"):
            return None
        if name in branches:
            return self.commits.get(str(branches[name]))
        return None if name != ref else self.by_sha.get(ref)

    def compare(self, base: Commit, head: Commit) -> tuple[str, int, int, Commit | None]:
        """(status, ahead_by, behind_by, merge base) as GitHub's compare says them, through the parents: `ahead` when
        `head` continues `base`, `behind` when `base` continues `head`, `identical`, or `diverged` from the newest
        commit both have — none, when they have none."""
        base_line = self.line(base)
        head_line = self.line(head)
        on_head = {commit.sha: index for index, commit in enumerate(head_line)}
        for behind, commit in enumerate(base_line):
            if commit.sha in on_head:
                ahead = on_head[commit.sha]
                status = "identical" if ahead == behind == 0 else "ahead" if behind == 0 else "behind" if ahead == 0 else "diverged"
                return status, ahead, behind, commit
        return "diverged", len(head_line), len(base_line), None

    @staticmethod
    def line(commit: Commit) -> list[Commit]:
        """A commit and every commit before it, newest first: one parent each."""
        found = []
        while commit is not None:
            found.append(commit)
            commit = commit.parent
        return found

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
            "parents": self.parents,
            "contents": self.contents,
            "commits": {
                name: {
                    "sha": commit.sha,
                    "tree": commit.snapshot.root,
                    "paths": {path: {"mode": mode, "sha": sha} for path, (mode, sha) in commit.snapshot.paths.items()},
                }
                for name, commit in self.commits.items()
            },
        }


class Source:
    """A repository of its own (`sources/github/<owner>/<repo>/`): its commits, and its number."""

    def __init__(self, folder: str, name: str) -> None:
        self.name = name
        self.id = read_number(os.path.join(folder, "id"))
        self.repository = Repository(folder)

    def facts(self) -> dict:
        return {"id": self.id, **self.repository.facts()}


def read_sources(root: str) -> dict[str, Source]:
    """Every repository of its own under the fixture root, by its folder's `owner/repo`; none without the folder.

    Two of one number, or one with the official repository's, would be one repository twice: refused."""
    found: dict[str, Source] = {}
    base = os.path.join(root, SOURCES)
    if not os.path.isdir(base):
        return found
    for owner in sorted(os.listdir(base)):
        if owner in IGNORED or not os.path.isdir(os.path.join(base, owner)):
            continue
        for repo in sorted(os.listdir(os.path.join(base, owner))):
            folder = os.path.join(base, owner, repo)
            if repo in IGNORED or not os.path.isdir(folder):
                continue
            found[f"{owner}/{repo}"] = Source(folder, f"{owner}/{repo}")
    numbers = [source.id for source in found.values()]
    if len(set(numbers)) != len(numbers):
        raise ValueError(f"{base}: two repositories of their own share a number: {sorted(numbers)}")
    return found


# --- What the lab says --------------------------------------------------------------


def read_state(root: str, default_main: str) -> dict:
    """The lab's instructions as they stand now; a missing or broken file is the defaults.

    Broken is not guessed at: the lab writes the file whole and renames it into
    place, and reads it back through `/lab/state` before it relies on it.
    """
    state = {"main": default_main, "branches": {}, "pulls": {}, "forks": {}, "limit_until": None, "spent": 0, "alter": [],
             "truncated": False, "official_id": None, "sources": {}, "served": None}
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

    def spend(self, now: float, used_up_until: int | None, spent: int = 0) -> tuple[bool, int, int]:
        """(allowed, remaining, reset) for one API request, `spent` of the hour's requests having gone to something
        else on the same connection."""
        with self.lock:
            if used_up_until is not None and now < used_up_until:
                return False, 0, int(used_up_until)
            if now >= self.reset:
                self.remaining = LIMIT
                self.reset = int(now) + WINDOW_SECONDS
            if self.remaining - spent <= 0:
                return False, 0, self.reset
            self.remaining -= 1
            return True, self.remaining - spent, self.reset


# --- The server ---------------------------------------------------------------------


class Fake:
    def __init__(self, root: str, owner_repo: str, log_path: str, clock=time.time) -> None:
        self.root = root
        self.owner_repo = owner_repo
        self.repository = Repository(root)
        # The official repository's number: its `id` file beside `history`, or none.
        self.official_id = read_number(os.path.join(root, "id")) if os.path.exists(os.path.join(root, "id")) else None
        self.sources = read_sources(root)
        if self.official_id is not None and self.official_id in {source.id for source in self.sources.values()}:
            raise ValueError(f"{root}: a repository of its own has the official repository's number {self.official_id}")
        self.clock = clock
        self.limit = Limit(clock())
        self.log_lock = threading.Lock()
        self.log_path = log_path

    def state(self) -> dict:
        return read_state(self.root, self.repository.names[0])

    def served(self, state: dict) -> dict[str, str]:
        """Which name serves which repository of its own now: each by its own folder's name, unless the lab says."""
        given = state.get("served")
        if not isinstance(given, dict):
            return {name: name for name in self.sources}
        return {str(name): str(folder) for name, folder in given.items() if str(folder) in self.sources}

    def source_named(self, owner_repo: str, state: dict) -> Source | None:
        """The repository of its own `owner/repo` serves now — GitHub's names are one whatever their case."""
        for name, folder in self.served(state).items():
            if name.lower() == owner_repo.lower():
                return self.sources[folder]
        return None

    def name_of(self, source: Source, state: dict) -> str | None:
        """What a repository of its own is called now — None when no name serves it, which GitHub answers 404 for."""
        return next((name for name, folder in self.served(state).items() if folder == source.name), None)

    def source_state(self, source: Source, state: dict) -> dict:
        """A repository of its own's `main`, as the lab says it, in the shape `Repository.resolve` reads."""
        given = (state.get("sources") or {}).get(source.name)
        main = given.get("main") if isinstance(given, dict) else None
        return {"main": main or source.repository.names[0], "branches": {}, "pulls": {}}

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
            return self.json(200, {**self.repository.facts(), "id": self.official_id,
                                   "sources": {name: source.facts() for name, source in self.sources.items()}})
        return self.json(404, {"message": "Not Found"})

    def api(self, path: str, query: dict, headers: dict) -> tuple[int, dict, bytes]:
        state = self.state()
        try:
            spent = max(0, int(state.get("spent") or 0))
        except (TypeError, ValueError):
            spent = 0
        allowed, remaining, reset = self.limit.spend(self.clock(), state.get("limit_until"), spent)
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

    def fork(self, owner_repo: str, state: dict) -> dict | None:
        """What the lab says of `owner/repo` as another repository on the host — None when it names none."""
        given = (state.get("forks") or {}).get(owner_repo)
        return given if isinstance(given, dict) else None

    def api_answer(self, path: str, query: dict, headers: dict, state: dict) -> tuple[int, dict, bytes]:
        parts = path.split("/")
        # "", "repositories", id, ...: a repository of its own by its number.
        if len(parts) >= 3 and parts[1] == "repositories":
            source = next((s for s in self.sources.values() if parts[2].isdigit() and s.id == int(parts[2])), None)
            name = self.name_of(source, state) if source else None
            if source is None or name is None:
                return self.json(404, {"message": "Not Found"})
            return self.source_answer(source, name, path[len(f"/repositories/{parts[2]}") :], query, headers, state)
        # "", "repos", owner, repo, ...
        if len(parts) < 4 or parts[1] != "repos":
            return self.json(404, {"message": "Not Found"})
        owner_repo = f"{parts[2]}/{parts[3]}"
        rest = path[len(f"/repos/{owner_repo}") :]
        if owner_repo != self.owner_repo:
            source = self.source_named(owner_repo, state)
            if source is not None:
                return self.source_answer(source, self.name_of(source, state) or owner_repo, rest, query, headers, state)
            fork = self.fork(owner_repo, state)
            if fork is None:
                return self.json(404, {"message": "Not Found"})
            return self.fork_answer(owner_repo, fork, rest, query, headers, state)
        if rest in ("", "/"):
            # Its number, as GitHub's description of a repository says it: its `id` file's, unless the lab says
            # another — the official address taken by a different repository (plugins.official-id-mismatch).
            number = state.get("official_id") or self.official_id
            return self.json(
                200,
                {**({"id": number} if number is not None else {}), "full_name": self.owner_repo,
                 "default_branch": DEFAULT_BRANCH, "private": False, "fork": False},
            )
        if rest == "/commits":
            return self.history(query, state)
        if rest.startswith("/commits/"):
            return self.commit(rest[len("/commits/") :], headers, state)
        if rest.startswith("/git/trees/"):
            recursive = query.get("recursive", ["0"])[0] not in ("", "0", "false")
            return self.tree(rest[len("/git/trees/") :], recursive, bool(state.get("truncated")))
        if rest.startswith("/pulls/"):
            return self.pull(rest[len("/pulls/") :], headers, state)
        if rest.startswith("/compare/"):
            return self.compare(rest[len("/compare/") :], state)
        return self.json(404, {"message": "Not Found"})

    def fork_answer(self, owner_repo: str, fork: dict, rest: str, query: dict, headers: dict,
                    state: dict) -> tuple[int, dict, bytes]:
        """A fork's answers: its description, its branches' heads, any listing and comparison of the network's
        commits. Its pull requests, and its folders' histories, are not the lab's: 404."""
        if rest in ("", "/"):
            description = {"full_name": owner_repo, "default_branch": str(fork.get("default_branch") or DEFAULT_BRANCH),
                           "private": False, "fork": bool(fork.get("fork", True))}  # fmt: skip
            if description["fork"]:
                description["parent"] = {"full_name": str(fork.get("parent") or self.owner_repo)}
                description["source"] = {"full_name": str(fork.get("source") or self.owner_repo)}
            return self.json(200, description)
        if rest.startswith("/commits/"):
            return self.commit(rest[len("/commits/") :], headers, state, fork=fork)
        if rest.startswith("/git/trees/"):
            recursive = query.get("recursive", ["0"])[0] not in ("", "0", "false")
            return self.tree(rest[len("/git/trees/") :], recursive, bool(state.get("truncated")))
        if rest.startswith("/compare/"):
            return self.compare(rest[len("/compare/") :], state, fork=fork)
        return self.json(404, {"message": "Not Found"})

    def source_answer(self, source: Source, name: str, rest: str, query: dict, headers: dict,
                      state: dict) -> tuple[int, dict, bytes]:
        """A repository of its own's answers, by its name or its number: its description — its number, and what it is
        called now — its head, a folder's history, a listing, a comparison. Its pull requests are not the lab's: 404."""
        own = self.source_state(source, state)
        repository = source.repository
        if rest in ("", "/"):
            owner = name.split("/")[0]
            return self.json(200, {"id": source.id, "full_name": name, "default_branch": DEFAULT_BRANCH, "private": False,
                                   "fork": False, "owner": {"login": owner, "type": "User"}})  # fmt: skip
        if rest == "/commits":
            return self.history(query, own, repository=repository)
        if rest.startswith("/commits/"):
            return self.commit(rest[len("/commits/") :], headers, own, repository=repository)
        if rest.startswith("/git/trees/"):
            recursive = query.get("recursive", ["0"])[0] not in ("", "0", "false")
            return self.tree(rest[len("/git/trees/") :], recursive, False, repository=repository)
        if rest.startswith("/compare/"):
            return self.compare(rest[len("/compare/") :], own, repository=repository)
        return self.json(404, {"message": "Not Found"})

    def resolved(self, ref: str, state: dict, fork: dict | None, repository: Repository | None = None) -> Commit | None:
        repository = repository or self.repository
        return repository.resolve(ref, state) if fork is None else repository.resolve_in_fork(ref, fork)

    def commit(self, ref: str, headers: dict, state: dict, fork: dict | None = None,
               repository: Repository | None = None) -> tuple[int, dict, bytes]:
        commit = self.resolved(ref, state, fork, repository)
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

    def pull(self, number: str, headers: dict, state: dict) -> tuple[int, dict, bytes]:
        """A pull request as GitHub's `GET /pulls/{n}` answers it — the fields uDeck reads, and the head and base
        GitHub always sends: the base is `main` unless the lab names another branch (`base`), the one it was opened
        against and merged into. A number the lab did not name is 404."""
        given = (state.get("pulls") or {}).get(number) if number.isdigit() else None
        head = self.repository.commits.get(str(given.get("head"))) if isinstance(given, dict) else None
        if head is None:
            return self.json(404, {"message": "Not Found"})
        merged = bool(given.get("merged"))
        merge = self.repository.commits.get(str(given.get("merge_commit"))) if merged else None
        head_repo = given.get("head_repo", self.owner_repo)
        head_ref = str(given.get("head_ref") or f"pull-{number}")
        base_ref = str(given.get("base") or DEFAULT_BRANCH)
        base = self.repository.resolve(base_ref, state)
        body = {
            "number": int(number),
            "state": str(given.get("state") or "open"),
            "title": str(given.get("title") or f"The lab's pull request #{number}"),
            "draft": False,
            "merged": merged,
            "merged_at": merge.date if merge else None,
            # GitHub names a test merge for an open pull request too; uDeck
            # reads the field only when `merged` is true, and here there is
            # none to name.
            "merge_commit_sha": merge.sha if merge else None,
            "head": {
                "label": f"{(head_repo or 'ghost').split('/')[0]}:{head_ref}",
                "ref": head_ref,
                "sha": head.sha,
                "repo": {"full_name": head_repo, "fork": head_repo != self.owner_repo} if head_repo else None,
            },
            "base": {
                "label": f"{self.owner_repo.split('/')[0]}:{base_ref}",
                "ref": base_ref,
                "sha": base.sha if base else None,
                "repo": {"full_name": self.owner_repo, "fork": False},
            },
        }
        status, extra, data = self.json(200, body)
        etag = f'"{hashlib.sha256(data).hexdigest()}"'
        if headers.get("if-none-match", "") == etag:
            return 304, {"ETag": etag}, b""
        return status, {**extra, "ETag": etag}, data

    def compare(self, spec: str, state: dict, fork: dict | None = None,
                repository: Repository | None = None) -> tuple[int, dict, bytes]:
        """`GET /compare/{base}...{head}` as GitHub answers it: the status, how many commits each side has that the
        other does not, the newest commit both have, the commits `head` has — and no files, which uDeck does not read.
        Either side a commit id or a ref — of the fork, asked of a fork; one that is not there is 404, as GitHub's."""
        repository = repository or self.repository
        base_ref, dots, head_ref = spec.partition("...")
        base = self.resolved(base_ref, state, fork, repository) if dots else None
        head = self.resolved(head_ref, state, fork, repository) if dots else None
        if base is None or head is None:
            return self.json(404, {"message": "Not Found"})
        status, ahead, behind, merge_base = repository.compare(base, head)
        return self.json(
            200,
            {
                "status": status,
                "ahead_by": ahead,
                "behind_by": behind,
                "total_commits": ahead,
                "base_commit": self.describe(base),
                "merge_base_commit": self.describe(merge_base) if merge_base else None,
                "commits": [self.describe(commit) for commit in reversed(repository.line(head)[:ahead])],
                "files": [],
            },
        )

    def history(self, query: dict, state: dict, repository: Repository | None = None) -> tuple[int, dict, bytes]:
        start = (repository or self.repository).resolve(query.get("sha", [DEFAULT_BRANCH])[0], state)
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

    def tree(self, sha: str, recursive: bool, truncated: bool,
             repository: Repository | None = None) -> tuple[int, dict, bytes]:
        repository = repository or self.repository
        snapshot = repository.tree_owner(sha)
        if snapshot is None:
            return self.json(404, {"message": "Not Found"})
        tree_sha = snapshot.root if sha in repository.by_sha else sha
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
        state = self.state()
        # A repository of its own by the name it is called now, and its commits only.
        source = None if owner_repo == self.owner_repo else self.source_named(owner_repo, state)
        if source is not None:
            if len(parts) < 4:
                return 404, {"Content-Type": "text/plain; charset=utf-8"}, b"404: Not Found"
            commit = source.repository.resolve(parts[2], self.source_state(source, state))
            path = "/".join(parts[3:])
            found = commit.snapshot.at(path) if commit else None
            if found is None or found[0] == MODE_FOLDER:
                return 404, {"Content-Type": "text/plain; charset=utf-8"}, b"404: Not Found"
            return 200, {"Content-Type": "text/plain; charset=utf-8"}, commit.snapshot.blobs[found[1]]
        fork = None if owner_repo == self.owner_repo else self.fork(owner_repo, state)
        if (owner_repo != self.owner_repo and fork is None) or len(parts) < 4:
            return 404, {"Content-Type": "text/plain; charset=utf-8"}, b"404: Not Found"
        commit = self.resolved(parts[2], state, fork)
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
            # No credential is good for anything yet: one carried is GitHub's 401, and the log says so, never its value.
            credential = "rejected" if any(name in headers for name in CREDENTIAL_HEADERS) else "none"
            try:
                if credential == "rejected":
                    status, extra, body = fake.json(401, {"message": "Bad credentials"})
                else:
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
                    "port": self.server.server_address[1],
                    "credential": credential,
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
    client that asked in that window waits instead of being told no. On CI's
    macos-26 runner two tests hung in curl for their whole 30 s against the
    http.server version of this fake (runs 36536857958 and 36562389702) and
    passed once the lookup was gone (run 36576951064); that a slow lookup was
    the cause is the likeliest reading, not a measurement. How long a client
    waits varies: on one Mac curl gave up by itself after about 8 s. The name is
    never used — no answer here is built with it — so it is not looked up.
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
