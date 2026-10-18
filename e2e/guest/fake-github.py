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

**GitLab projects** (stage 4, R2) are fixture folders under
`sources/gitlab/<host>/<group>/…/<project>/` — a `history`, an optional
`parents`, commit folders and an `id`, GitLab's number for it — and each host
is answered on a port of its own (`serve … gitlab.example.test=8768
gitlab.com=8769`), so that each is an origin of its own, as outside the lab, in
GitLab's API, v4:

    GET /api/v4/projects/{id, or group%2Fproject}       its description, as anonymous gitlab.com answers it: no
                                                        `forked_from_project`; 404 '404 Project Not Found'
    GET /api/v4/projects/{id}/repository/branches/main  its head, with a weak ETag and 304 to exactly that
    GET /api/v4/projects/{id}/repository/tree?ref=&path=&recursive=&per_page=&page=
                                                        a folder's entries — id, name, type, whole path, mode, no
                                                        size — a few to a page (`gitlab_page_size`, 3), with
                                                        x-next-page; 404 '404 Tree Not Found' for a ref and '404
                                                        invalid revision or path Not Found' for a path not there
    GET /api/v4/projects/{id}/repository/files/{path%2F…}/raw?ref={commit}
                                                        one file, with X-Gitlab-Size and X-Gitlab-Blob-Id; 404 '404
                                                        File Not Found'
    GET /api/v4/projects/{id}/repository/commits?ref_name=&path=&per_page=
                                                        the commits that changed a path

gitlab.com counts every request by two limiters, as gitlab.com was seen to,
each answer naming one in turn (`RateLimit-Name`): 500 a minute and 60 an hour,
304s included — and once the hour's are used up, `429` with `Retry-After` until
it resets. A self-hosted GitLab sends no limit at all. A file named
`<name>.generated` in a commit folder is a file `<name>` made when the fake
starts — `{"bytes": …, "line": …}` — and never committed: the file larger than
a plugin's file may be.

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
    {"gitlab": {"gitlab.example.test": {"projects": {"tools/udeck-plugins": {"main": "g2"}},
                                        "served": {"tools/udeck-plugins-2": "tools/udeck-plugins"},
                                        "plain": true},
                "gitlab.com": {"spent": 55}}}
                                                    each GitLab: its projects' main, which path serves which
                                                    project, a web server's plain 404 to everything instead
                                                    of GitLab's answers, and the hour's requests spent by
                                                    something else on the connection
    {"gitlab_page_size": 3}                         the most entries a tree answer's page holds

Moving a branch's head, force-pushing it, merging or closing a pull request is
one rewrite of the file: a head at another fixture commit — one that does not
descend from the one before, for a force push — `state` and `merged` changed, a
branch left out; a fork's branch the same way, inside `forks`.

**It keeps an access log**, one JSON object per line and per request — method,
host, path, query, status, the port it came in on, and the headers that decide
an answer — which is the lab's oracle for what uDeck asked for and, just as
much, for what it did not. The lab's own requests carry `X-UDeck-Lab: 1` and are
logged as the lab's, so that asking the fake whether it is up is never read as
uDeck asking. A line of a GitLab's port names it (`site`), and every line keeps
the path as it was sent, before its `%2F` was decoded (`raw_path`). Each line
says whether the request carried a credential —
`credential`: `none`, `accepted` or `rejected`, and never its value — and no
credential is good for anything yet: one carried is answered `401 Bad
credentials`, as GitHub answers a token it does not know.

    fake-github.py serve ROOT PORT OWNER/REPO LOG [HOST=PORT …]
                                          each HOST=PORT a GitLab, answered on its own port
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

# Where the GitLab projects are: `<host>/<group>/…/<project>/` (stage 4, R2).
GITLAB = os.path.join("sources", "gitlab")
# The GitLab that counts by limiters, and the most entries one of a GitLab's tree pages holds unless the lab says.
GITLAB_COM = "gitlab.com"
GITLAB_PAGE_SIZE = 3

# A fixture file made when the fake starts rather than committed: `<name>.generated`, `{"bytes": …, "line": …}`.
GENERATED = ".generated"

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
            if not os.path.islink(path) and os.path.isfile(path) and name.endswith(GENERATED):
                name = name[: -len(GENERATED)]
                data = generated(path)
                sha = blob_id(data)
                self.blobs[sha] = data
                entries.append((MODE_FILE, name, sha))
                self.paths[prefix + name] = entries[-1][0], entries[-1][2]
                continue
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


def generated(spec: str) -> bytes:
    """The bytes a `<name>.generated` file stands for: `line` over and over, cut at `bytes`."""
    with open(spec) as file:
        said = json.load(file)
    size, line = int(said["bytes"]), str(said["line"]).encode()
    if size < 0 or not line:
        raise ValueError(f"{spec} says {said}: a size of 0 or more and a line to repeat")
    return (line * (size // len(line) + 1))[:size]


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


# --- GitLab (stage 4, R2) -----------------------------------------------------------


class Project:
    """A GitLab project of its own (`sources/gitlab/<host>/<group>/…/<project>/`): its commits, its number, and the
    host it is on — a `history`, an optional `parents`, its commit folders and an `id`, GitLab's number for it."""

    def __init__(self, folder: str, host: str, path: str) -> None:
        self.host = host
        self.path = path
        self.id = read_number(os.path.join(folder, "id"))
        self.repository = Repository(folder)

    @property
    def key(self) -> str:
        return f"{self.host}/{self.path}"

    def facts(self) -> dict:
        return {"id": self.id, "host": self.host, "path": self.path, **self.repository.facts()}


def read_projects(root: str) -> dict[str, Project]:
    """Every GitLab project under the fixture root, by `host/path`: under `sources/gitlab/<host>/`, each folder that
    has a `history` is a project, at whatever depth its groups put it. Two of one number on one host are one project
    twice: refused."""
    found: dict[str, Project] = {}
    base = os.path.join(root, GITLAB)
    if not os.path.isdir(base):
        return found
    for host in sorted(os.listdir(base)):
        top = os.path.join(base, host)
        if host in IGNORED or not os.path.isdir(top):
            continue
        for folder, names, files in os.walk(top):
            names[:] = sorted(name for name in names if name not in IGNORED)
            if "history" not in files:
                continue
            path = os.path.relpath(folder, top).replace(os.sep, "/")
            project = Project(folder, host, path)
            found[project.key] = project
            # A project's commit folders are not projects of their own.
            names[:] = []
        numbers = [project.id for project in found.values() if project.host == host]
        if len(set(numbers)) != len(numbers):
            raise ValueError(f"{top}: two GitLab projects share a number: {sorted(numbers)}")
    return found


class Limiter:
    """One of gitlab.com's counts: `limit` requests in each window of `seconds`, the window starting at its first."""

    def __init__(self, name: str, limit: int, seconds: int) -> None:
        self.name = name
        self.limit = limit
        self.seconds = seconds
        self.used = 0
        self.reset = 0

    def spend(self, now: float) -> None:
        if now >= self.reset:
            self.used = 0
            self.reset = int(now) + self.seconds
        self.used += 1

    def remaining(self, spent: int = 0) -> int:
        return max(0, self.limit - self.used - spent)


class GitLabLimits:
    """gitlab.com's two limiters, as it was seen to count anonymous requests: `throttle_unauthenticated_api`, 500 a
    minute, and `unauthenticated_traffic_per_ip`, 60 an hour — each request spends both, 304s too, and its answer names
    one of them in turn. With the hour's used up — `spent` of it by something else on the connection — the answer is a
    429 naming the hour, with `Retry-After` until it resets."""

    def __init__(self) -> None:
        self.lock = threading.Lock()
        self.minute = Limiter("throttle_unauthenticated_api", 500, 60)
        self.hour = Limiter("unauthenticated_traffic_per_ip", 60, WINDOW_SECONDS)
        self.answers = 0

    def spend(self, now: float, spent: int) -> tuple[bool, dict]:
        """(allowed, the headers that say so) for one request."""
        with self.lock:
            if now >= self.hour.reset:
                self.hour.used, self.hour.reset = 0, int(now) + self.hour.seconds
            if self.hour.remaining(spent) <= 0:
                return False, {**self.headers(self.hour, spent), "Retry-After": str(max(1, int(self.hour.reset - now)))}
            self.minute.spend(now)
            self.hour.spend(now)
            self.answers += 1
            return True, self.headers(self.minute if self.answers % 2 == 1 else self.hour, spent)

    @staticmethod
    def headers(limiter: Limiter, spent: int) -> dict:
        spent = spent if limiter.seconds == WINDOW_SECONDS else 0
        return {
            "RateLimit-Name": limiter.name,
            "RateLimit-Limit": str(limiter.limit),
            "RateLimit-Observed": str(min(limiter.limit, limiter.used + spent)),
            "RateLimit-Remaining": str(limiter.remaining(spent)),
            "RateLimit-Reset": str(limiter.reset),
        }


# --- What the lab says --------------------------------------------------------------


def read_state(root: str, default_main: str) -> dict:
    """The lab's instructions as they stand now; a missing or broken file is the defaults.

    Broken is not guessed at: the lab writes the file whole and renames it into
    place, and reads it back through `/lab/state` before it relies on it.
    """
    state = {"main": default_main, "branches": {}, "pulls": {}, "forks": {}, "limit_until": None, "spent": 0, "alter": [],
             "truncated": False, "official_id": None, "sources": {}, "served": None, "gitlab": {},
             "gitlab_page_size": GITLAB_PAGE_SIZE}
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
        self.projects = read_projects(root)
        self.clock = clock
        self.limit = Limit(clock())
        self.gitlab_limits = GitLabLimits()
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
                                   "sources": {name: source.facts() for name, source in self.sources.items()},
                                   "gitlab": {key: project.facts() for key, project in self.projects.items()}})
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

    # --- Its GitLabs (stage 4, R2) ---------------------------------------------------------

    def gitlab_state(self, site: str, state: dict) -> dict:
        """What the lab says of the GitLab `site`: `plain`, `projects` (each one's `main`), `served`, `spent`."""
        given = (state.get("gitlab") or {}).get(site)
        return given if isinstance(given, dict) else {}

    def gitlab_served(self, site: str, state: dict) -> dict[str, Project]:
        """Which path serves which project on `site` now: each by its own folder's path, unless the lab says."""
        own = {project.path: project for project in self.projects.values() if project.host == site}
        given = self.gitlab_state(site, state).get("served")
        if not isinstance(given, dict):
            return own
        return {str(name): own[str(path)] for name, path in given.items() if str(path) in own}

    def gitlab_project(self, site: str, named: str, state: dict) -> tuple[Project | None, str]:
        """The project `named` names — its number, or its path, decoded — and the path it is served at now."""
        served = self.gitlab_served(site, state)
        if named.isdigit():
            for name, project in served.items():
                if project.id == int(named):
                    return project, name
            return None, ""
        return served.get(named), named

    def gitlab_main(self, project: Project, state: dict) -> dict:
        """A project's `main`, as the lab says it, in the shape `Repository.resolve` reads."""
        given = (self.gitlab_state(project.host, state).get("projects") or {}).get(project.path)
        main = given.get("main") if isinstance(given, dict) else None
        return {"main": main or project.repository.names[0], "branches": {}, "pulls": {}}

    def gitlab(self, site: str, method: str, target: str, headers: dict) -> tuple[int, dict, bytes]:
        """An answer of the GitLab `site`, on its own port: GitLab's API, v4 — or, told `plain`, a web server's 404,
        which no GitLab answers. gitlab.com counts by its two limiters; a self-hosted GitLab sends no limit."""
        state = self.state()
        mine = self.gitlab_state(site, state)
        if mine.get("plain"):
            return 404, {"Content-Type": "text/plain; charset=utf-8"}, b"404 page not found\n"
        if method not in ("GET", "HEAD"):
            return self.json(405, {"message": "405 Method Not Allowed"})
        parsed = urllib.parse.urlsplit(target)
        limits: dict = {}
        if site == GITLAB_COM:
            try:
                spent = max(0, int(mine.get("spent") or 0))
            except (TypeError, ValueError):
                spent = 0
            allowed, limits = self.gitlab_limits.spend(self.clock(), spent)
            if not allowed:
                return 429, {"Content-Type": "text/plain; charset=utf-8", **limits}, b"Retry later\n"
        status, extra, body = self.gitlab_answer(site, parsed.path, urllib.parse.parse_qs(parsed.query), headers, state)
        return status, {**extra, **limits}, body

    def gitlab_answer(self, site: str, raw: str, query: dict, headers: dict, state: dict) -> tuple[int, dict, bytes]:
        segments = raw.split("/")
        # "", "api", "v4", "projects", <id, or the path with its "/" as %2F>, ...
        if segments[:4] != ["", "api", "v4", "projects"] or len(segments) < 5 or not segments[4]:
            return self.json(404, {"error": "404 Not Found"})
        project, name = self.gitlab_project(site, urllib.parse.unquote(segments[4]), state)
        if project is None:
            return self.json(404, {"message": "404 Project Not Found"})
        rest = [urllib.parse.unquote(segment) for segment in segments[5:]]
        own = self.gitlab_main(project, state)
        if rest in ([], [""]):
            return self.json(200, self.gitlab_description(site, project, name))
        if len(rest) == 3 and rest[:2] == ["repository", "branches"]:
            return self.gitlab_branch(site, project, name, rest[2], own, headers)
        if rest == ["repository", "tree"]:
            return self.gitlab_tree(project, query, own, state)
        if len(rest) == 4 and rest[:2] == ["repository", "files"] and rest[3] == "raw":
            return self.gitlab_file(project, rest[2], query, own)
        if rest == ["repository", "commits"]:
            return self.gitlab_history(project, query, own)
        return self.json(404, {"error": "404 Not Found"})

    @staticmethod
    def gitlab_description(site: str, project: Project, name: str) -> dict:
        """`GET /projects/:id` as gitlab.com answers it anonymously: no `forked_from_project`."""
        group, _, last = name.rpartition("/")
        return {"id": project.id, "description": None, "name": last, "name_with_namespace": name.replace("/", " / "),
                "path": last, "path_with_namespace": name, "default_branch": DEFAULT_BRANCH, "visibility": "public",
                "web_url": f"https://{site}/{name}", "namespace": {"full_path": group, "kind": "group"}}

    def gitlab_branch(self, site: str, project: Project, name: str, branch: str, own: dict,
                      headers: dict) -> tuple[int, dict, bytes]:
        """A branch, with the weak `ETag` GitLab derives from its answer and a `304` to exactly that."""
        commit = project.repository.resolve(branch, own) if branch == DEFAULT_BRANCH else None
        if commit is None:
            return self.json(404, {"message": "404 Branch Not Found"})
        status, extra, body = self.json(200, {
            "name": branch, "merged": False, "protected": True, "default": True,
            "commit": {**self.gitlab_commit(commit), "web_url": f"https://{site}/{name}/-/commit/{commit.sha}"},
            "web_url": f"https://{site}/{name}/-/tree/{branch}",
        })
        etag = f'W/"{hashlib.md5(body).hexdigest()}"'  # noqa: S324 — GitLab's own ETag is a digest of its answer
        if headers.get("if-none-match", "") == etag:
            return 304, {"ETag": etag}, b""
        return status, {**extra, "ETag": etag}, body

    @staticmethod
    def gitlab_commit(commit: Commit) -> dict:
        return {"id": commit.sha, "short_id": commit.sha[:8], "title": commit.message, "message": commit.message,
                "authored_date": commit.date, "committed_date": commit.date, "created_at": commit.date,
                "parent_ids": [commit.parent.sha] if commit.parent else []}

    def page_size(self, state: dict, asked: dict) -> int:
        """The entries a page holds: what was asked, at most the lab's (`gitlab_page_size`), so that a listing takes
        more than one page and its client has to follow `x-next-page`."""
        try:
            lab = max(1, int(state.get("gitlab_page_size") or GITLAB_PAGE_SIZE))
        except (TypeError, ValueError):
            lab = GITLAB_PAGE_SIZE
        try:
            wanted = max(1, min(100, int(asked.get("per_page", ["20"])[0])))
        except ValueError:
            wanted = 20
        return min(lab, wanted)

    def gitlab_tree(self, project: Project, query: dict, own: dict, state: dict) -> tuple[int, dict, bytes]:
        """`GET /repository/tree?ref=&path=&recursive=&per_page=&page=`: a folder's entries — every one under it,
        recursively — `id`, `name`, `type`, whole `path` and `mode`, and no size; page by page, offset pagination."""
        commit = project.repository.resolve(query.get("ref", [DEFAULT_BRANCH])[0], own)
        if commit is None:
            return self.json(404, {"message": "404 Tree Not Found"})
        path = query.get("path", [""])[0].strip("/")
        found = commit.snapshot.at(path)
        if found is None or found[0] != MODE_FOLDER:
            return self.json(404, {"message": "404 invalid revision or path Not Found"})
        recursive = query.get("recursive", ["false"])[0] in ("true", "1")
        entries: list = []
        self.gitlab_list(commit.snapshot, found[1], f"{path}/" if path else "", recursive, entries)
        size = self.page_size(state, query)
        try:
            page = max(1, int(query.get("page", ["1"])[0]))
        except ValueError:
            page = 1
        pages = max(1, -(-len(entries) // size))
        status, extra, body = self.json(200, entries[(page - 1) * size: page * size])
        return status, {**extra, "x-page": str(page), "x-per-page": str(size), "x-total": str(len(entries)),
                        "x-total-pages": str(pages), "x-next-page": str(page + 1) if page < pages else "",
                        "x-prev-page": str(page - 1) if page > 1 else ""}, body

    def gitlab_list(self, snapshot: Snapshot, tree_sha: str, prefix: str, recursive: bool, out: list) -> None:
        """A folder's entries as GitLab lists them: its folders first, then the rest, each by name."""
        children = snapshot.trees[tree_sha]
        for mode, name, sha in sorted(children, key=lambda entry: (entry[0] != MODE_FOLDER, entry[1])):
            path = prefix + name
            if mode == MODE_FOLDER:
                out.append({"id": sha, "name": name, "type": "tree", "path": path, "mode": "040000"})
                if recursive:
                    self.gitlab_list(snapshot, sha, path + "/", recursive, out)
            else:
                out.append({"id": sha, "name": name, "type": "blob", "path": path, "mode": mode})

    def gitlab_file(self, project: Project, path: str, query: dict, own: dict) -> tuple[int, dict, bytes]:
        """`GET /repository/files/:path/raw?ref=`: one file at one commit, with what GitLab says of it."""
        commit = project.repository.resolve(query.get("ref", [""])[0], own)
        if commit is None:
            return self.json(404, {"message": "404 Commit Not Found"})
        found = commit.snapshot.at(path)
        if found is None or found[0] == MODE_FOLDER:
            return self.json(404, {"message": "404 File Not Found"})
        data = commit.snapshot.blobs[found[1]]
        return 200, {"Content-Type": "text/plain; charset=utf-8", "X-Gitlab-Size": str(len(data)),
                     "X-Gitlab-Blob-Id": found[1], "X-Gitlab-Commit-Id": commit.sha, "X-Gitlab-File-Path": path,
                     "X-Gitlab-Ref": commit.sha}, data

    def gitlab_history(self, project: Project, query: dict, own: dict) -> tuple[int, dict, bytes]:
        """`GET /repository/commits?ref_name=&path=&per_page=`: the commits on the branch that changed a path, newest first."""
        start = project.repository.resolve(query.get("ref_name", [DEFAULT_BRANCH])[0], own)
        if start is None:
            return self.json(404, {"message": "404 Reference Not Found"})
        path = query.get("path", [""])[0].strip("/")
        try:
            per_page = max(1, min(100, int(query.get("per_page", ["20"])[0])))
        except ValueError:
            per_page = 20
        found = []
        commit = start
        while commit is not None and len(found) < per_page:
            here = commit.snapshot.at(path) if path else None
            before = commit.parent.snapshot.at(path) if (path and commit.parent) else None
            if not path or here != before:
                found.append(self.gitlab_commit(commit))
            commit = commit.parent
        return self.json(200, found)

    @staticmethod
    def json(status: int, value) -> tuple[int, dict, bytes]:
        return status, {"Content-Type": "application/json; charset=utf-8"}, json.dumps(value, indent=1).encode()


def handler_for(fake: Fake, site: str = ""):
    """The handler of one port: GitHub's — the API, the raw host, the lab's own — or, with `site`, that GitLab's."""

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
                    status, extra, body = fake.json(401, {"message": "401 Unauthorized" if site else "Bad credentials"})
                elif site and not urllib.parse.urlsplit(self.path).path.startswith("/lab/"):
                    status, extra, body = fake.gitlab(site, method, self.path, headers)
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
                    "raw_path": parsed.path,
                    "site": site,
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


def serve(root: str, port: int, owner_repo: str, log_path: str, gitlabs: dict[str, int] | None = None) -> None:
    """GitHub on `port` and each GitLab of `gitlabs` on its own — one fake, one log — every socket listening before
    the line that says so."""
    started = time.monotonic()
    fake = Fake(root, owner_repo, log_path)
    # 127.0.0.1 and nothing else: the guest's own network is reachable from the
    # Mac the lab runs on (measured for the update feed), and nothing outside the
    # machine has any business with this.
    server = Server(("127.0.0.1", port), handler_for(fake))
    others = [Server(("127.0.0.1", other), handler_for(fake, site)) for site, other in (gitlabs or {}).items()]
    for other in others:
        threading.Thread(target=other.serve_forever, daemon=True).start()
    # How long it took is part of the line: a fake slow to start is what the lab
    # has to be able to tell from a fake that never answers.
    also = "".join(f", {site} on 127.0.0.1:{other}" for site, other in (gitlabs or {}).items())
    print(
        f"{LISTENING}: {owner_repo} from {root} on 127.0.0.1:{port}{also}, {time.monotonic() - started:.2f}s after it "
        "started",
        flush=True,
    )
    server.serve_forever()


def gitlab_ports(given: list[str]) -> dict[str, int]:
    """`HOST=PORT` arguments, as `serve` takes them."""
    found: dict[str, int] = {}
    for item in given:
        host, _, port = item.partition("=")
        if not host or not port.isdigit():
            raise ValueError(f"{item!r} is not HOST=PORT")
        found[host] = int(port)
    return found


def main(argv: list[str]) -> int:
    if len(argv) >= 5 and argv[0] == "serve":
        serve(argv[1], int(argv[2]), argv[3], argv[4], gitlab_ports(argv[5:]))
        return 0
    if len(argv) == 2 and argv[0] == "tree":
        print(Snapshot(argv[1]).root)
        return 0
    print(__doc__.split("\n\n")[-1] if __doc__ else "", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
