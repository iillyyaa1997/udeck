"""The fake GitHub the plugin checks read: its hashing, its answers, and the lab's hand on it.

Its hashing is held against git itself — `git hash-object`, `git write-tree` and
`git commit-tree` on a copy of each fixture commit — because the fake is one of
the two implementations the plugin checks set against each other: a Python that
agreed with nothing would make every "the folder hashes to the fixture's tree"
a sentence about the lab. Its answers are asked over real HTTP, from a server
run on this Mac's loopback for the length of one test. And `FakeGitHub` is
driven through a machine whose SSH runs commands here, in a temporary folder,
so that what the lab writes into the guest and reads back is the real shell
and the real curl, not a scripted answer.
"""

import importlib.util
import json
import os
import shutil
import socket
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
from pathlib import Path

import pytest

from udeck_e2e import config, plugin_repository
from udeck_e2e.errors import LabError
from udeck_e2e.plugin_repository import FakeGitHub, Request, parse_log, uDecks

from fakes import Machine as FakeMachine

REPOSITORY = config.PLUGINS_REPOSITORY


def load_fake():
    spec = importlib.util.spec_from_file_location("fake_github", plugin_repository.SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


fake_github = load_fake()


def git(*args, cwd, env=None, data=None):
    done = subprocess.run(
        ["git", *args], cwd=cwd, capture_output=True, text=data is None, input=data, check=True,
        env={**os.environ, "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null", **(env or {})},
    )  # fmt: skip
    return done.stdout.strip() if isinstance(done.stdout, str) else done.stdout


needs_git = pytest.mark.skipif(shutil.which("git") is None, reason="git is not installed")


# --- The fixtures -------------------------------------------------------------------------


def test_the_fixtures_are_what_the_checks_are_written_against():
    """c1 has uptime 1.0.0 and the refusal fixtures, c2 the same with uptime 1.1.0, c3 with 1.2.0 asking for one command more."""
    root = plugin_repository.FIXTURES
    assert fake_github.Repository(str(root)).names == ["c1", "c2", "c3"]
    same = ["sysctl", "./hold.sh"]
    # c2 asks for exactly what c1 does, so it updates itself (plugins.verified-updates-itself);
    # c3 asks for one command more, so it is only offered (plugins.permissions-change-only-offers).
    for commit, version, asks in (("c1", "1.0.0", same), ("c2", "1.1.0", same), ("c3", "1.2.0", [*same, "uname"])):
        plugins = root / commit / "plugins"
        assert sorted(p.name for p in plugins.iterdir()) == ["future-api", "future-udeck", "linked", "uptime"]
        manifest = json.loads((plugins / "uptime" / "manifest.json").read_text())
        assert manifest["version"] == version and manifest["permissions"] == {"exec": asks}
        # The card says which version it is, so a check can tell 1.0.0's output from 1.1.0's.
        producer = (plugins / "uptime" / "uptime.sh").read_text()
        assert f"version={version}\n" in producer
        assert os.access(plugins / "uptime" / "uptime.sh", os.X_OK)
        # And it offers the action plugins.an-update-ends-a-running-action presses, granted by name.
        assert '"actions": [ { "label": "Hold", "run": ["./hold.sh"] } ]' in producer
        hold = (plugins / "uptime" / "hold.sh").read_text()
        assert os.access(plugins / "uptime" / "hold.sh", os.X_OK)
        assert "trap" in hold and "ended" in hold and "changed under it" in hold
        assert json.loads((plugins / "future-api" / "manifest.json").read_text())["api"] == 2
        assert json.loads((plugins / "future-udeck" / "manifest.json").read_text())["minUDeck"] == "99.0.0"
        assert (plugins / "linked" / "lib").is_symlink()
        assert json.loads((root / commit / "udeck-plugins.json").read_text())["format"] == 1


def test_pull_request_3s_head_is_c1_with_uptime_changed_and_a_plugin_that_asks_for_nothing():
    """`pr3`, made on c1: uptime 1.0.1 asking for what 1.0.0 asks, and asks-nothing, asking for no permission at all."""
    root = plugin_repository.FIXTURES
    repository = fake_github.Repository(str(root))
    assert repository.parents["pr3"] == "c1"
    assert repository.commits["pr3"].parent is repository.commits["c1"]
    plugins = root / "pr3" / "plugins"
    assert sorted(p.name for p in plugins.iterdir()) == ["asks-nothing", "future-api", "future-udeck", "linked", "uptime"]
    uptime = json.loads((plugins / "uptime" / "manifest.json").read_text())
    assert uptime["version"] == "1.0.1" and uptime["permissions"] == {"exec": ["sysctl", "./hold.sh"]}
    assert "version=1.0.1\n" in (plugins / "uptime" / "uptime.sh").read_text()
    nothing = json.loads((plugins / "asks-nothing" / "manifest.json").read_text())
    assert nothing["id"] == "asks-nothing" and "permissions" not in nothing and nothing["run"] == ["./run.sh"]
    assert os.access(plugins / "asks-nothing" / "run.sh", os.X_OK)
    assert (plugins / "asks-nothing" / "README.md").is_file()
    # Everything else is c1's, byte for byte: the folders' trees say so.
    c1, pr3 = repository.commits["c1"].snapshot, repository.commits["pr3"].snapshot
    for path in ("udeck-plugins.json", "plugins/future-api", "plugins/future-udeck", "plugins/linked"):
        assert c1.at(path) == pr3.at(path), path
    for path in ("plugins/uptime/README.md", "plugins/uptime/hold.sh", "plugins/uptime/manifest.ru.json"):
        assert c1.at(path) == pr3.at(path), path
    assert c1.at("plugins/uptime") != pr3.at("plugins/uptime")


def test_pull_request_3_merged_squashed_as_its_head_with_a_change_and_main_moving_on():
    """s1: pr3's content on c1. s2: pr3 with uptime 1.0.2, asking for what 1.0.1 asks. m1: s2's content on s1."""
    root = plugin_repository.FIXTURES
    repository = fake_github.Repository(str(root))
    assert {name: repository.parents[name] for name in ("pr3", "s1", "s2", "m1")} == {"pr3": "c1", "s1": "c1", "s2": "c1", "m1": "s1"}
    assert {name: repository.contents[name] for name in ("s1", "m1")} == {"s1": "pr3", "m1": "s2"}, \
        "s1 and m1 have no folder of their own"
    assert not (root / "s1").exists() and not (root / "m1").exists()
    commits = repository.commits
    # Squashed as exactly its head: another commit, on another parent, with the same tree.
    assert commits["s1"].snapshot.root == commits["pr3"].snapshot.root and commits["s1"].sha != commits["pr3"].sha
    assert commits["s1"].parent is commits["c1"] and commits["m1"].parent is commits["s1"]
    # Squashed with a maintainer's change: uptime alone differs from pr3's, as 1.0.2 asking for the same.
    pr3, s2 = commits["pr3"].snapshot, commits["s2"].snapshot
    differ = {path.split("/")[1] for path in set(pr3.paths) | set(s2.paths)
              if path.startswith("plugins/") and pr3.at(path) != s2.at(path)}  # fmt: skip
    assert differ == {"uptime"}
    uptime = json.loads((root / "s2" / "plugins" / "uptime" / "manifest.json").read_text())
    assert uptime["version"] == "1.0.2" and uptime["permissions"] == {"exec": ["sysctl", "./hold.sh"]}
    assert "version=1.0.2\n" in (root / "s2" / "plugins" / "uptime" / "uptime.sh").read_text()
    assert commits["m1"].snapshot.root == s2.root


def test_pull_request_3_moves_on_as_p2_and_is_pushed_again_as_p2x_with_its_history_rewritten():
    """p2: made on pr3, uptime's script alone changed — the same version, the same manifest. p2x: p2's content on c1."""
    root = plugin_repository.FIXTURES
    repository = fake_github.Repository(str(root))
    assert repository.parents["p2"] == "pr3" and repository.parents["p2x"] == "c1"
    assert repository.contents["p2x"] == "p2" and "p2" not in repository.contents and not (root / "p2x").exists()
    commits = repository.commits
    pr3, p2, p2x = commits["pr3"].snapshot, commits["p2"].snapshot, commits["p2x"].snapshot
    differ = {path for path in set(pr3.paths) | set(p2.paths) if pr3.at(path) != p2.at(path)}
    assert differ == {"plugins", "plugins/uptime", "plugins/uptime/uptime.sh"}, "the script alone, and the folders it is in"
    # Nothing a read of p2 fetches is new: its manifests are pr3's, byte for byte.
    for path in ("plugins/uptime/manifest.json", "plugins/uptime/manifest.ru.json", "plugins/asks-nothing/manifest.json"):
        assert pr3.at(path) == p2.at(path), path
    assert "version=1.0.1\n" in (root / "p2" / "plugins" / "uptime" / "uptime.sh").read_text()
    # Pushed again: another commit, on c1 rather than on pr3, with p2's tree.
    assert p2x.root == p2.root and commits["p2x"].sha != commits["p2"].sha
    assert commits["p2"].parent is commits["pr3"] and commits["p2x"].parent is commits["c1"]


def test_a_parents_file_that_names_what_is_not_there_is_refused(tmp_path):
    root = tmp_path / "repository"
    shutil.copytree(plugin_repository.FIXTURES, root, symlinks=True)
    for text, complaint in (
        ("pr3 c9\n", "which no line before it names"),
        ("pr3\n", "is not a commit and the commit it was made on"),
        ("pr3 c1 pr3 c2\n", "is not a commit and the commit it was made on"),
        ("pr3 c1\npr3 c1\n", "named twice"),
        ("c2 c1\n", "named twice"),
        ("s9 c1 nowhere\n", "takes its content from nowhere, which is no folder here"),
        ("s9 c1\n", "takes its content from s9, which is no folder here"),
    ):
        (root / "parents").write_text(text)
        with pytest.raises(ValueError, match=complaint):
            fake_github.Repository(str(root))
    (root / "parents").unlink()
    assert fake_github.Repository(str(root)).parents == {}, "no file: no commit off the main line"


# --- Git's hashing, against git ------------------------------------------------------------


@needs_git
def test_a_blob_id_is_what_git_hash_object_says(tmp_path):
    for data in (b"", b"hello\n", bytes(range(256)) * 3):
        file = tmp_path / "f"
        file.write_bytes(data)
        assert fake_github.blob_id(data) == git("hash-object", "--no-filters", str(file), cwd=tmp_path)


@needs_git
def test_every_fixture_commit_hashes_as_git_hashes_it(tmp_path):
    """Trees, modes, a symbolic link, commits and their parents: all of it git's own ids."""
    repository = fake_github.Repository(str(plugin_repository.FIXTURES))
    work = tmp_path / "work"
    work.mkdir()
    git("init", "-q", cwd=work)
    git("config", "core.fileMode", "true", cwd=work)
    git("config", "core.symlinks", "true", cwd=work)
    parent = None
    for name in repository.names:
        commit = repository.commits[name]
        for child in work.iterdir():
            if child.name != ".git":
                shutil.rmtree(child) if child.is_dir() and not child.is_symlink() else child.unlink()
        shutil.copytree(plugin_repository.FIXTURES / name, work, symlinks=True, dirs_exist_ok=True)
        git("add", "-A", cwd=work)
        tree = git("write-tree", cwd=work)
        assert commit.snapshot.root == tree, name
        for path in ("plugins", "plugins/uptime", "plugins/linked"):
            assert commit.snapshot.at(path)[1] == git("rev-parse", f"{tree}:{path}", cwd=work), (name, path)
        assert commit.snapshot.at("plugins/linked/lib")[0] == "120000"
        assert commit.snapshot.at("plugins/uptime/uptime.sh")[0] == "100755"
        assert commit.snapshot.at("plugins/uptime/manifest.json")[0] == "100644"
        stamp = f"{commit.when} +0000"
        env = {
            "GIT_AUTHOR_NAME": "uDeck lab", "GIT_AUTHOR_EMAIL": "lab@udeck.invalid", "GIT_AUTHOR_DATE": stamp,
            "GIT_COMMITTER_NAME": "uDeck lab", "GIT_COMMITTER_EMAIL": "lab@udeck.invalid", "GIT_COMMITTER_DATE": stamp,
        }  # fmt: skip
        args = ["commit-tree", tree, "-m", commit.message] + (["-p", parent] if parent else [])
        made = git(*args, cwd=work, env=env)
        assert commit.sha == made, name
        parent = made
    # Off the main line: each with the commit it was made on as its parent, and
    # its content from its own folder or the one `parents` names.
    assert repository.parents, "the fixtures have commits off the main line"
    for name, on in repository.parents.items():
        commit = repository.commits[name]
        for child in work.iterdir():
            if child.name != ".git":
                shutil.rmtree(child) if child.is_dir() and not child.is_symlink() else child.unlink()
        shutil.copytree(plugin_repository.FIXTURES / repository.contents.get(name, name), work, symlinks=True,
                        dirs_exist_ok=True)
        git("add", "-A", cwd=work)
        tree = git("write-tree", cwd=work)
        assert commit.snapshot.root == tree, name
        stamp = f"{commit.when} +0000"
        env = {
            "GIT_AUTHOR_NAME": "uDeck lab", "GIT_AUTHOR_EMAIL": "lab@udeck.invalid", "GIT_AUTHOR_DATE": stamp,
            "GIT_COMMITTER_NAME": "uDeck lab", "GIT_COMMITTER_EMAIL": "lab@udeck.invalid", "GIT_COMMITTER_DATE": stamp,
        }  # fmt: skip
        made = git("commit-tree", tree, "-m", commit.message, "-p", repository.commits[on].sha, cwd=work, env=env)
        assert commit.sha == made, name
        assert commit.when > max(repository.commits[main].when for main in repository.names)


def test_a_folder_sorts_as_if_its_name_ended_in_a_slash():
    """Git compares a folder as its name and "/": `a-b` (0x2d), then `a.c` (0x2e), then `a/` (0x2f)."""
    import hashlib

    blob = fake_github.blob_id(b"x")
    given = [("40000", "a", blob), ("100644", "a.c", blob), ("100644", "a-b", blob)]
    in_gits_order = [given[2], given[1], given[0]]
    body = b"".join(f"{mode} {name}".encode() + b"\0" + bytes.fromhex(sha) for mode, name, sha in in_gits_order)
    assert fake_github.tree_id(given) == hashlib.sha1(b"tree %d\0" % len(body) + body).hexdigest()


def test_the_tree_command_hashes_a_folder_on_disk_as_its_fixture(tmp_path, capsys):
    """How a check hashes the folder uDeck installed in the guest."""
    uptime = plugin_repository.FIXTURES / "c1" / "plugins" / "uptime"
    copy = tmp_path / "uptime"
    shutil.copytree(uptime, copy, symlinks=True)
    assert fake_github.main(["tree", str(copy)]) == 0
    said = capsys.readouterr().out.strip()
    repository = fake_github.Repository(str(plugin_repository.FIXTURES))
    assert said == repository.commits["c1"].snapshot.at("plugins/uptime")[1]
    # One byte more, anywhere, is another folder.
    with open(copy / "uptime.sh", "a") as file:
        file.write("# changed\n")
    fake_github.main(["tree", str(copy)])
    assert capsys.readouterr().out.strip() != said


# --- The fake's answers, over HTTP ---------------------------------------------------------


class Served:
    """The fake, on this Mac's loopback for one test, over a copy of the fixtures."""

    def __init__(self, tmp_path, clock=time.time):
        self.root = tmp_path / "repository"
        shutil.copytree(plugin_repository.FIXTURES, self.root, symlinks=True)
        self.log = tmp_path / "requests.jsonl"
        self.fake = fake_github.Fake(str(self.root), REPOSITORY, str(self.log), clock=clock)
        self.server = fake_github.Server(("127.0.0.1", 0), fake_github.handler_for(self.fake))
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.base = f"http://127.0.0.1:{self.server.server_address[1]}"

    def state(self, **state):
        (self.root / "state.json").write_text(json.dumps(state))

    def get(self, path, headers=None):
        request = urllib.request.Request(self.base + path, headers=headers or {})
        try:
            with urllib.request.urlopen(request, timeout=10) as answer:
                return answer.status, dict(answer.headers), answer.read()
        except urllib.error.HTTPError as error:
            return error.code, dict(error.headers), error.read()

    def json(self, path, headers=None):
        status, headers, body = self.get(path, headers)
        return status, headers, json.loads(body)

    def requests(self):
        return parse_log(self.log.read_text())

    def close(self):
        self.server.shutdown()
        self.server.server_close()


@pytest.fixture
def served(tmp_path):
    served = Served(tmp_path)
    yield served
    served.close()


API = f"/api/repos/{REPOSITORY}"
RAW = f"/raw/{REPOSITORY}"


def test_the_default_branch_is_main(served):
    status, _, body = served.json(API)
    assert status == 200 and body["default_branch"] == "main"


def test_the_head_is_a_bare_sha_with_its_etag_and_304_when_it_did_not_move(served):
    facts = served.fake.repository.facts()
    c1, c2 = facts["commits"]["c1"]["sha"], facts["commits"]["c2"]["sha"]
    served.state(main="c1")
    sha_only = {"Accept": "application/vnd.github.sha"}
    status, headers, body = served.get(f"{API}/commits/main", sha_only)
    assert status == 200 and body.decode() == c1 and headers["ETag"] == f'"{c1}"'
    status, _, body = served.get(f"{API}/commits/main", {**sha_only, "If-None-Match": f'"{c1}"'})
    assert status == 304 and body == b""
    # The lab moves main; the same question now answers the new commit.
    served.state(main="c2")
    status, headers, body = served.get(f"{API}/commits/main", {**sha_only, "If-None-Match": f'"{c1}"'})
    assert status == 200 and body.decode() == c2
    # A commit that does not exist is GitHub's 422.
    assert served.get(f"{API}/commits/{'0' * 40}", sha_only)[0] == 422


def test_the_listing_of_a_commit_has_every_path_with_its_mode_id_and_size(served):
    facts = served.fake.repository.facts()["commits"]["c1"]
    status, _, body = served.json(f"{API}/git/trees/{facts['sha']}?recursive=1")
    assert status == 200 and body["truncated"] is False and body["sha"] == facts["tree"]
    entries = {entry["path"]: entry for entry in body["tree"]}
    assert entries["plugins/uptime"] == {
        "path": "plugins/uptime", "mode": "040000", "type": "tree", "sha": facts["paths"]["plugins/uptime"]["sha"],
    }  # fmt: skip
    script = entries["plugins/uptime/uptime.sh"]
    assert script["mode"] == "100755" and script["type"] == "blob"
    assert script["size"] == (plugin_repository.FIXTURES / "c1/plugins/uptime/uptime.sh").stat().st_size
    assert entries["plugins/linked/lib"]["mode"] == "120000"
    assert "udeck-plugins.json" in entries and "history" not in entries and "state.json" not in entries
    # One folder by its own id, not recursive: its children only.
    status, _, body = served.json(f"{API}/git/trees/{facts['paths']['plugins']['sha']}")
    assert sorted(entry["path"] for entry in body["tree"]) == ["future-api", "future-udeck", "linked", "uptime"]


def test_a_listing_said_to_be_truncated_is_the_top_level_and_the_flag(served):
    facts = served.fake.repository.facts()["commits"]["c1"]
    served.state(truncated=True)
    _, _, body = served.json(f"{API}/git/trees/{facts['sha']}?recursive=1")
    assert body["truncated"] is True
    assert sorted(entry["path"] for entry in body["tree"]) == ["plugins", "udeck-plugins.json"]
    # A plugin folder listed by its own tree is whole: that is the long way round.
    _, _, body = served.json(f"{API}/git/trees/{facts['paths']['plugins/uptime']['sha']}?recursive=1")
    assert body["truncated"] is False and "uptime.sh" in [entry["path"] for entry in body["tree"]]


def test_a_folders_history_is_the_commits_that_changed_it_newest_first(served):
    facts = served.fake.repository.facts()["commits"]
    served.state(main="c2")
    _, _, body = served.json(f"{API}/commits?sha=main&path=plugins/uptime&per_page=100")
    assert [commit["sha"] for commit in body] == [facts["c2"]["sha"], facts["c1"]["sha"]]
    assert body[0]["commit"]["committer"]["date"] == "2026-09-02T10:00:00Z"
    # linked did not change in c2.
    _, _, body = served.json(f"{API}/commits?sha=main&path=plugins/linked")
    assert [commit["sha"] for commit in body] == [facts["c1"]["sha"]]
    # With main at c3, c3 is first.
    served.state(main="c3")
    _, _, body = served.json(f"{API}/commits?sha=main&path=plugins/uptime")
    assert [commit["sha"] for commit in body] == [facts["c3"]["sha"], facts["c2"]["sha"], facts["c1"]["sha"]]
    # With main at c1, c2 is not in the history at all.
    served.state(main="c1")
    _, _, body = served.json(f"{API}/commits?sha=main&path=plugins/uptime")
    assert [commit["sha"] for commit in body] == [facts["c1"]["sha"]]


def test_a_raw_file_is_the_one_at_that_commit_and_hashes_to_its_listed_id(served):
    facts = served.fake.repository.facts()["commits"]
    for name in ("c1", "c2", "c3"):
        status, headers, body = served.get(f"{RAW}/{facts[name]['sha']}/plugins/uptime/manifest.json")
        assert status == 200
        assert fake_github.blob_id(body) == facts[name]["paths"]["plugins/uptime/manifest.json"]["sha"]
        # The raw host carries no rate-limit headers (measured, per the document).
        assert not any(key.lower().startswith("x-ratelimit") for key in headers)
    assert served.get(f"{RAW}/{facts['c1']['sha']}/plugins/uptime/nothing")[0] == 404
    assert served.get(f"{RAW}/{'0' * 40}/udeck-plugins.json")[0] == 404
    assert served.get(f"/raw/somebody/else/{facts['c1']['sha']}/udeck-plugins.json")[0] == 404


def test_a_file_the_lab_says_to_alter_arrives_different_and_nothing_else_does(served):
    facts = served.fake.repository.facts()["commits"]["c1"]
    served.state(alter=["plugins/uptime/uptime.sh"])
    _, _, body = served.get(f"{RAW}/{facts['sha']}/plugins/uptime/uptime.sh")
    assert fake_github.blob_id(body) != facts["paths"]["plugins/uptime/uptime.sh"]["sha"]
    _, _, body = served.get(f"{RAW}/{facts['sha']}/plugins/uptime/manifest.json")
    assert fake_github.blob_id(body) == facts["paths"]["plugins/uptime/manifest.json"]["sha"]


def test_every_api_answer_spends_the_hourly_limit_and_says_what_is_left(served):
    remaining = []
    for _ in range(3):
        status, headers, _ = served.get(API)
        assert status == 200 and headers["x-ratelimit-limit"] == "60"
        remaining.append(int(headers["x-ratelimit-remaining"]))
    assert remaining == [59, 58, 57]
    # Raw requests are counted elsewhere, and not here.
    facts = served.fake.repository.facts()["commits"]["c1"]
    served.get(f"{RAW}/{facts['sha']}/udeck-plugins.json")
    assert served.get(API)[1]["x-ratelimit-remaining"] == "56"


def test_a_limit_used_up_is_403_with_nothing_left_and_the_reset_the_lab_chose(served):
    until = int(time.time()) + 600
    served.state(limit_until=until)
    status, headers, body = served.get(f"{API}/commits/main", {"Accept": "application/vnd.github.sha"})
    assert status == 403
    assert headers["x-ratelimit-remaining"] == "0" and headers["x-ratelimit-reset"] == str(until)
    assert b"rate limit exceeded" in body
    # The raw host is not the API: a plugin already listed still installs.
    facts = served.fake.repository.facts()["commits"]["c1"]
    assert served.get(f"{RAW}/{facts['sha']}/plugins/uptime/uptime.sh")[0] == 200
    # And the limit ends when the lab says.
    served.state(limit_until=int(time.time()) - 1)
    assert served.get(API)[0] == 200


def test_the_limit_runs_out_by_itself_after_sixty_requests(tmp_path):
    now = [1_800_000_000.0]
    served = Served(tmp_path, clock=lambda: now[0])
    try:
        for _ in range(60):
            assert served.get(API)[0] == 200
        status, headers, _ = served.get(API)
        assert status == 403 and headers["x-ratelimit-remaining"] == "0"
        now[0] += 3600
        assert served.get(API)[0] == 200
    finally:
        served.close()


def test_every_request_is_logged_and_the_labs_own_are_marked(served):
    served.get("/lab/alive", {plugin_repository.LAB_HEADER: "1"})
    served.get(API, {"User-Agent": "uDeck/0.4.1"})
    served.get(f"{API}/commits/main", {"Accept": "application/vnd.github.sha", "If-None-Match": '"x"'})
    served.get("/raw/nobody/nothing/0/x")
    logged = served.requests()
    assert [(r.host, r.lab) for r in logged] == [("lab", True), ("api", False), ("api", False), ("raw", False)]
    assert logged[1].user_agent == "uDeck/0.4.1" and logged[1].status == 200
    assert logged[2].accept == "application/vnd.github.sha" and logged[2].if_none_match == '"x"'
    assert logged[3].status == 404
    assert [r.path for r in uDecks(logged)] == [API, f"{API}/commits/main", "/raw/nobody/nothing/0/x"]


def test_the_lab_can_ask_the_fake_what_it_holds_and_what_it_was_told(served):
    served.state(main="c2", alter=["x"])
    _, _, state = served.json("/lab/state")
    assert state["main"] == "c2" and state["alter"] == ["x"] and state["limit_until"] is None
    _, _, facts = served.json("/lab/facts")
    assert facts["history"] == ["c1", "c2", "c3"] and len(facts["commits"]["c2"]["sha"]) == 40
    assert facts["parents"] == {"pr3": "c1", "s1": "c1", "s2": "c1", "m1": "s1", "p2": "pr3", "p2x": "c1"}
    assert len(facts["commits"]["pr3"]["sha"]) == 40
    assert facts["contents"] == {"s1": "pr3", "m1": "s2", "p2x": "p2"}
    assert state["branches"] == {} and state["pulls"] == {}


# --- Branches, pull requests, commits off the main line -----------------------------------


SHA_ONLY = {"Accept": "application/vnd.github.sha"}


def test_a_branch_is_its_head_by_name_or_refs_heads_with_its_etag_and_304(served):
    facts = served.fake.repository.facts()["commits"]
    pr3, c1 = facts["pr3"]["sha"], facts["c1"]["sha"]
    served.state(main="c1", branches={"fix/uptime": "pr3"})
    # uDeck asks refs/heads/{branch} as one path segment, the slashes escaped.
    for ref in ("refs%2Fheads%2Ffix%2Fuptime", "refs/heads/fix/uptime", "fix%2Fuptime", "fix/uptime"):
        status, headers, body = served.get(f"{API}/commits/{ref}", SHA_ONLY)
        assert (status, body.decode(), headers["ETag"]) == (200, pr3, f'"{pr3}"'), ref
    status, _, body = served.get(f"{API}/commits/refs%2Fheads%2Ffix%2Fuptime", {**SHA_ONLY, "If-None-Match": f'"{pr3}"'})
    assert status == 304 and body == b""
    # The default branch by its full name too; and a branch that is not there is GitHub's 422.
    assert served.get(f"{API}/commits/refs%2Fheads%2Fmain", SHA_ONLY)[2].decode() == c1
    assert served.get(f"{API}/commits/refs%2Fheads%2Fgone", SHA_ONLY)[0] == 422
    assert served.get(f"{API}/commits/refs%2Fheads%2F{c1}", SHA_ONLY)[0] == 422, "an id is no branch's name"
    assert served.get(f"{API}/commits/refs%2Ftags%2Fv1", SHA_ONLY)[0] == 422
    # The lab moves the branch, or deletes it: the same question, another answer.
    served.state(main="c1", branches={"fix/uptime": "c1"})
    status, _, body = served.get(f"{API}/commits/refs%2Fheads%2Ffix%2Fuptime", {**SHA_ONLY, "If-None-Match": f'"{pr3}"'})
    assert status == 200 and body.decode() == c1
    served.state(main="c1")
    assert served.get(f"{API}/commits/refs%2Fheads%2Ffix%2Fuptime", SHA_ONLY)[0] == 422


def test_a_pull_requests_head_is_refs_pull_n_head_even_when_its_branch_is_gone(served):
    facts = served.fake.repository.facts()["commits"]
    pr3 = facts["pr3"]["sha"]
    served.state(main="c1", pulls={"3": {"head": "pr3", "head_repo": "someone/udeck-plugins", "head_ref": "fix"}})
    status, headers, body = served.get(f"{API}/commits/refs%2Fpull%2F3%2Fhead", SHA_ONLY)
    assert (status, body.decode(), headers["ETag"]) == (200, pr3, f'"{pr3}"')
    assert served.get(f"{API}/commits/refs%2Fpull%2F3%2Fhead", {**SHA_ONLY, "If-None-Match": f'"{pr3}"'})[0] == 304
    assert served.get(f"{API}/commits/refs%2Fpull%2F4%2Fhead", SHA_ONLY)[0] == 422


def test_a_pull_request_says_its_head_its_state_its_merge_and_where_it_came_from(served):
    facts = served.fake.repository.facts()["commits"]
    pr3, c1, c2 = facts["pr3"]["sha"], facts["c1"]["sha"], facts["c2"]["sha"]
    served.state(main="c1", pulls={"3": {"head": "pr3", "head_repo": "someone/udeck-plugins", "head_ref": "fix",
                                         "title": "Uptime 1.0.1, and a plugin that asks for nothing"}})  # fmt: skip
    status, headers, body = served.json(f"{API}/pulls/3")
    assert status == 200 and headers["x-ratelimit-remaining"] == "59", "a pull request is one API request"
    assert body["number"] == 3 and body["state"] == "open" and body["merged"] is False
    assert body["merge_commit_sha"] is None and body["merged_at"] is None
    assert body["head"]["sha"] == pr3 and body["head"]["ref"] == "fix"
    assert body["head"]["repo"] == {"full_name": "someone/udeck-plugins", "fork": True}
    assert body["base"]["ref"] == "main" and body["base"]["sha"] == c1
    assert body["title"] == "Uptime 1.0.1, and a plugin that asks for nothing"
    # Asked again with its ETag, unchanged: 304, which spends the limit as GitHub's does without a token.
    status, again, _ = served.get(f"{API}/pulls/3", {"If-None-Match": headers["ETag"]})
    assert status == 304 and again["x-ratelimit-remaining"] == "58"
    # Merged as c2; and from the repository itself, the fork's name absent.
    served.state(main="c2", pulls={"3": {"head": "pr3", "state": "closed", "merged": True, "merge_commit": "c2"}})
    _, _, body = served.json(f"{API}/pulls/3")
    assert body["state"] == "closed" and body["merged"] is True and body["merge_commit_sha"] == c2
    assert body["head"]["repo"] == {"full_name": REPOSITORY, "fork": False} and body["merged_at"]
    # Closed unmerged: no merge commit, whatever the lab wrote; a deleted fork: no repository.
    served.state(main="c1", pulls={"3": {"head": "pr3", "state": "closed", "merged": False, "merge_commit": "c2",
                                         "head_repo": None}})  # fmt: skip
    _, _, body = served.json(f"{API}/pulls/3")
    assert body["merged"] is False and body["merge_commit_sha"] is None and body["head"]["repo"] is None
    assert body["head"]["sha"] == pr3, "its head is still read through the repository it was opened against"
    # A pull request the lab did not name, or one that is no number.
    assert served.get(f"{API}/pulls/9")[0] == 404
    assert served.get(f"{API}/pulls/three")[0] == 404


def test_a_commit_off_the_main_line_is_served_by_its_id_listing_files_and_history(served):
    facts = served.fake.repository.facts()["commits"]
    pr3, c1 = facts["pr3"], facts["c1"]["sha"]
    served.state(main="c1")
    status, _, body = served.json(f"{API}/git/trees/{pr3['sha']}?recursive=1")
    entries = {entry["path"]: entry for entry in body["tree"]}
    assert status == 200 and body["sha"] == pr3["tree"]
    assert entries["plugins/asks-nothing"]["sha"] == pr3["paths"]["plugins/asks-nothing"]["sha"]
    assert entries["plugins/asks-nothing/run.sh"]["mode"] == "100755"
    status, _, data = served.get(f"{RAW}/{pr3['sha']}/plugins/asks-nothing/manifest.json")
    assert status == 200 and fake_github.blob_id(data) == pr3["paths"]["plugins/asks-nothing/manifest.json"]["sha"]
    # Not on main, so not in main's files.
    assert served.get(f"{RAW}/{c1}/plugins/asks-nothing/manifest.json")[0] == 404
    _, _, body = served.json(f"{API}/commits/{pr3['sha']}")
    assert body["parents"] == [{"sha": c1}]
    # Its history, parent by parent: uptime changed at pr3 and at c1, and c2 is not on the way.
    _, _, body = served.json(f"{API}/commits?sha={pr3['sha']}&path=plugins/uptime")
    assert [commit["sha"] for commit in body] == [pr3["sha"], c1]
    _, _, body = served.json(f"{API}/commits?sha=main&path=plugins/asks-nothing")
    assert body == []


def test_a_pull_request_merged_and_main_moved_past_it(served):
    """The squash merge is one rewrite: main at m1, pull request #3 closed and merged as s1, the commit before m1."""
    facts = served.fake.repository.facts()["commits"]
    pr3, s1, m1 = facts["pr3"], facts["s1"], facts["m1"]
    served.state(main="m1", pulls={"3": {"head": "pr3", "state": "closed", "merged": True, "merge_commit": "s1"}})
    assert served.get(f"{API}/commits/main", SHA_ONLY)[2].decode() == m1["sha"]
    _, _, body = served.json(f"{API}/pulls/3")
    assert body["merged"] is True and body["merge_commit_sha"] == s1["sha"] and body["head"]["sha"] == pr3["sha"]
    # The commit it was merged as is listed as any commit is, with the head's tree of uptime.
    status, _, body = served.json(f"{API}/git/trees/{s1['sha']}?recursive=1")
    entries = {entry["path"]: entry for entry in body["tree"]}
    assert status == 200 and entries["plugins/uptime"]["sha"] == pr3["paths"]["plugins/uptime"]["sha"]
    assert m1["paths"]["plugins/uptime"]["sha"] != pr3["paths"]["plugins/uptime"]["sha"]
    # And main's history passes through it: uptime changed at m1, at s1 and at c1.
    _, _, body = served.json(f"{API}/commits?sha=main&path=plugins/uptime")
    assert [commit["sha"] for commit in body] == [m1["sha"], s1["sha"], facts["c1"]["sha"]]
    # Merged into another branch than main: its base is that branch, at the commit it was merged as.
    served.state(main="c1", branches={"next": "s1"},
                 pulls={"3": {"head": "pr3", "state": "closed", "merged": True, "merge_commit": "s1", "base": "next"}})
    _, _, body = served.json(f"{API}/pulls/3")
    assert body["merged"] is True and body["merge_commit_sha"] == s1["sha"]
    assert body["base"]["ref"] == "next" and body["base"]["sha"] == s1["sha"] and body["base"]["label"].endswith(":next")
    assert served.get(f"{API}/commits/main", SHA_ONLY)[2].decode() == facts["c1"]["sha"], "main where it was"
    # Closed unmerged, and opened again: one rewrite each.
    served.state(main="c1", pulls={"3": {"head": "pr3", "state": "closed", "merged": False}})
    assert served.json(f"{API}/pulls/3")[2]["state"] == "closed"
    served.state(main="c1", pulls={"3": {"head": "pr3", "state": "open", "merged": False}})
    assert served.json(f"{API}/pulls/3")[2]["state"] == "open"


def test_two_commits_are_compared_through_their_parents(served):
    """Ahead when the head continues the base, behind when the base continues it, identical, diverged — and 404."""
    facts = served.fake.repository.facts()["commits"]
    sha = {name: facts[name]["sha"] for name in ("c1", "pr3", "p2", "p2x", "s1", "m1")}
    served.state(main="c1", branches={"fix/uptime": "p2"})
    for base, head, wanted in (
        ("pr3", "p2", ("ahead", 1, 0)),  # the pull request moved on
        ("pr3", "p2x", ("diverged", 1, 1)),  # pushed again, its history rewritten
        ("p2", "pr3", ("behind", 0, 1)),  # gone back
        ("pr3", "pr3", ("identical", 0, 0)),
        ("c1", "m1", ("ahead", 2, 0)),
        ("pr3", "s1", ("diverged", 1, 1)),  # a squash merge against the head it was made from
    ):
        status, headers, body = served.json(f"{API}/compare/{sha[base]}...{sha[head]}?per_page=1")
        assert status == 200 and (body["status"], body["ahead_by"], body["behind_by"]) == wanted, (base, head)
        assert body["files"] == [] and len(body["commits"]) == wanted[1]
        assert body["merge_base_commit"]["sha"] == (sha["c1"] if wanted[0] == "diverged" and head != "m1" else
                                                    sha[base] if wanted[0] in ("ahead", "identical") else sha[head])
    # Refs as GitHub takes them; a commit that is not there is 404.
    _, _, body = served.json(f"{API}/compare/main...fix/uptime")
    assert (body["status"], body["ahead_by"]) == ("ahead", 2)
    assert served.get(f"{API}/compare/{'0' * 40}...{sha['p2']}")[0] == 404
    assert served.get(f"{API}/compare/{sha['pr3']}")[0] == 404, "no three dots: nothing compared"
    assert served.requests()[-1].path == f"{API}/compare/{sha['pr3']}" and served.requests()[-1].is_api


def test_requests_spent_elsewhere_leave_less_and_run_out_sooner(tmp_path):
    """`spent`: what something else on the connection took of the hour — said in what is left, and refused at none."""
    now = [1_800_000_000.0]
    served = Served(tmp_path, clock=lambda: now[0])
    try:
        assert served.get(API)[1]["x-ratelimit-remaining"] == "59"
        served.state(spent=50)
        assert served.get(API)[1]["x-ratelimit-remaining"] == "8", "58 left, 50 of them spent elsewhere"
        for _ in range(8):
            assert served.get(API)[0] == 200
        status, headers, _ = served.get(API)
        assert status == 403 and headers["x-ratelimit-remaining"] == "0"
        served.state()
        assert served.get(API)[1]["x-ratelimit-remaining"] == "49", "nothing spent elsewhere: the fake's own count"
        served.state(spent="many")
        assert served.get(API)[0] == 200, "a spent the lab did not write as a number is none"
    finally:
        served.close()


FORK = "someone/udeck-plugins"
FORK_API = f"/api/repos/{FORK}"


def test_a_fork_is_described_as_one_and_a_repository_of_its_own_as_none(served):
    """`GET /repos/{fork}`: `fork`, `parent` and `source` as GitHub says them (the official repository unless the lab says
    otherwise); a repository of its own, `fork` false and neither; one the lab does not name, 404."""
    served.state(main="c1", forks={FORK: {"branches": {"x": "pr3"}}, "someone/elsewhere": {"fork": False},
                                   "someone/other": {"source": "somebody/else", "parent": "somebody/else", "default_branch": "trunk"}})
    status, _, body = served.json(FORK_API)
    assert status == 200 and body == {"full_name": FORK, "default_branch": "main", "private": False, "fork": True,
                                      "parent": {"full_name": REPOSITORY}, "source": {"full_name": REPOSITORY}}
    _, _, own = served.json("/api/repos/someone/elsewhere")
    assert own["fork"] is False and "source" not in own and "parent" not in own
    _, _, other = served.json("/api/repos/someone/other")
    assert other["source"]["full_name"] == "somebody/else" and other["default_branch"] == "trunk"
    assert served.get("/api/repos/someone/unknown")[0] == 404
    assert served.get(f"/api/repos/{REPOSITORY}-x")[0] == 404, "no repository by a prefix of the official one's name"
    assert served.json(API)[2]["fork"] is False, "the official repository is no fork"


def test_a_forks_branch_is_its_own_and_its_listing_files_and_comparisons_are_the_networks(served):
    """A fork's `x` is the fork's, not the official repository's `x`; by `refs/heads/`, with its ETag and 304, and 422 once
    deleted; any commit of the network is listed, served raw and compared through it; its pull requests are not modelled."""
    facts = served.fake.repository.facts()["commits"]
    c1, pr3, p2 = facts["c1"]["sha"], facts["pr3"]["sha"], facts["p2"]["sha"]
    served.state(main="c1", branches={"x": "c1"}, forks={FORK: {"branches": {"x": "pr3"}}})
    status, headers, body = served.get(f"{FORK_API}/commits/refs%2Fheads%2Fx", SHA_ONLY)
    assert (status, body.decode(), headers["ETag"]) == (200, pr3, f'"{pr3}"')
    assert served.get(f"{FORK_API}/commits/refs%2Fheads%2Fx", {**SHA_ONLY, "If-None-Match": f'"{pr3}"'})[0] == 304
    assert served.get(f"{API}/commits/refs%2Fheads%2Fx", SHA_ONLY)[2].decode() == c1, "the official repository's x is another"
    assert served.get(f"{FORK_API}/commits/refs%2Fheads%2Fgone", SHA_ONLY)[0] == 422
    assert served.get(f"{FORK_API}/commits/refs%2Fheads%2Fmain", SHA_ONLY)[0] == 422, "the fork's main only when the lab names it"
    assert served.get(f"{FORK_API}/commits/refs%2Fpull%2F3%2Fhead", SHA_ONLY)[0] == 422
    assert served.get(f"{FORK_API}/commits/{c1}", SHA_ONLY)[2].decode() == c1, "any commit of the network by its id"
    status, _, listing = served.json(f"{FORK_API}/git/trees/{pr3}?recursive=1")
    assert status == 200 and {"plugins/asks-nothing/manifest.json", "plugins/uptime/uptime.sh"} <= {e["path"] for e in listing["tree"]}
    status, _, data = served.get(f"/raw/{FORK}/{pr3}/plugins/asks-nothing/manifest.json")
    assert status == 200 and fake_github.blob_id(data) == facts["pr3"]["paths"]["plugins/asks-nothing/manifest.json"]["sha"]
    assert served.get(f"/raw/someone/unknown/{pr3}/udeck-plugins.json")[0] == 404
    served.state(main="c1", forks={FORK: {"branches": {"x": "p2"}}})
    _, _, compared = served.json(f"{FORK_API}/compare/{pr3}...{p2}?per_page=1")
    assert (compared["status"], compared["ahead_by"], compared["behind_by"]) == ("ahead", 1, 0)
    assert served.json(f"{FORK_API}/compare/{pr3}...x")[2]["status"] == "ahead", "the fork's own ref"
    assert served.get(f"{FORK_API}/compare/{pr3}...fix%2Fuptime")[0] == 404, "the official repository's branches are not the fork's"
    assert served.get(f"{FORK_API}/pulls/3")[0] == 404
    assert served.get(f"{FORK_API}/commits?path=plugins/uptime")[0] == 404
    served.state(main="c1", forks={FORK: {"branches": {}}})
    assert served.get(f"{FORK_API}/commits/refs%2Fheads%2Fx", SHA_ONLY)[0] == 422, "deleted"
    assert [r.path for r in served.requests()][:2] == [f"{FORK_API}/commits/refs/heads/x"] * 2


def test_a_forks_requests_spend_the_same_hour(tmp_path):
    """GitHub counts what an address asks whichever repository it asks about: the fork's answers spend the official
    repository's hour, a 404 included; raw files spend none."""
    now = [1_800_000_000.0]
    served = Served(tmp_path, clock=lambda: now[0])
    try:
        served.state(forks={FORK: {"branches": {"x": "pr3"}}})
        assert served.get(API)[1]["x-ratelimit-remaining"] == "59"
        assert served.get(FORK_API)[1]["x-ratelimit-remaining"] == "58"
        assert served.get(f"{FORK_API}/commits/x", SHA_ONLY)[1]["x-ratelimit-remaining"] == "57"
        assert served.get("/api/repos/someone/unknown")[1]["x-ratelimit-remaining"] == "56"
        pr3 = served.fake.repository.facts()["commits"]["pr3"]["sha"]
        assert "x-ratelimit-remaining" not in served.get(f"/raw/{FORK}/{pr3}/udeck-plugins.json")[1]
        assert served.get(API)[1]["x-ratelimit-remaining"] == "55"
        served.state(forks={FORK: {"branches": {"x": "pr3"}}}, limit_until=int(now[0]) + 600)
        assert served.get(FORK_API)[0] == 403, "the limit used up is the fork's too"
    finally:
        served.close()


@needs_git
def test_every_two_fixture_commits_compare_as_git_compares_them(tmp_path):
    """The fake's compare, held against `git rev-list --left-right --count` on the same commits, every pair."""
    repository = fake_github.Repository(str(plugin_repository.FIXTURES))
    work = tmp_path / "work"
    work.mkdir()
    git("init", "-q", cwd=work)
    # The graph alone is compared: every commit one empty tree, its own message, its own parent — made by the lab,
    # as the fixtures are, never by whoever git would guess runs the test.
    empty = git("mktree", cwd=work, data=b"").decode().strip()
    env = {
        "GIT_AUTHOR_NAME": "uDeck lab", "GIT_AUTHOR_EMAIL": "lab@udeck.invalid",
        "GIT_COMMITTER_NAME": "uDeck lab", "GIT_COMMITTER_EMAIL": "lab@udeck.invalid",
    }  # fmt: skip
    made = {}
    ordered = list(repository.names) + list(repository.parents)
    for name in ordered:
        commit = repository.commits[name]
        parents = ["-p", made[commit.parent.name]] if commit.parent else []
        made[name] = git("commit-tree", empty, "-m", name, *parents, cwd=work, env=env)
    for base in ordered:
        for head in ordered:
            behind, ahead = (int(n) for n in git("rev-list", "--left-right", "--count", f"{made[base]}...{made[head]}",
                                                cwd=work).split())  # fmt: skip
            status = "identical" if ahead == behind == 0 else "ahead" if behind == 0 else "behind" if ahead == 0 else "diverged"
            said = repository.compare(repository.commits[base], repository.commits[head])
            assert said[:3] == (status, ahead, behind), (base, head)


# --- Repositories of their own (stage 4) ------------------------------------------------------


TEAM = "someone/team-plugins"
TEAM_ID = 900000101
SOURCES = plugin_repository.FIXTURES / "sources" / "github"


def test_the_repositories_of_their_own_are_what_the_source_checks_are_written_against():
    """someone/team-plugins: t1 with team-clock 1.0.0 asking for nothing, team-ping 1.0.0 asking for one command and an
    uptime 1.0.0 of its own asking for what the official c1's asks; t2 with 1.1.0 of both asking the same; t3 with
    team-clock 1.2.0 asking for one command more. someone/not-plugins without a passport; someone/squatter another
    repository, with another number. And the official repository's own number."""
    team = fake_github.Source(str(SOURCES / TEAM), TEAM)
    assert team.id == TEAM_ID and team.repository.names == ["t1", "t2", "t3"] and not team.repository.parents
    for commit, clock, clock_asks, ping in (("t1", "1.0.0", None, "1.0.0"), ("t2", "1.1.0", None, "1.1.0"),
                                            ("t3", "1.2.0", {"exec": ["sysctl"]}, "1.1.0")):
        plugins = SOURCES / TEAM / commit / "plugins"
        assert sorted(p.name for p in plugins.iterdir()) == ["team-clock", "team-ping", "uptime"]
        manifest = json.loads((plugins / "team-clock" / "manifest.json").read_text())
        assert manifest["version"] == clock and manifest.get("permissions") == clock_asks, commit
        manifest = json.loads((plugins / "team-ping" / "manifest.json").read_text())
        assert manifest["version"] == ping and manifest["permissions"] == {"exec": ["sysctl"]}, commit
        ours = json.loads((plugins / "uptime" / "manifest.json").read_text())
        official = json.loads((plugin_repository.FIXTURES / "c1" / "plugins" / "uptime" / "manifest.json").read_text())
        assert ours["version"] == official["version"] == "1.0.0" and ours["permissions"] == official["permissions"]
        assert team.repository.commits[commit].snapshot.at("plugins/uptime") != fake_github.Repository(
            str(plugin_repository.FIXTURES)).commits["c1"].snapshot.at("plugins/uptime"), "a clash of ids, not a copy"
        for plugin in ("team-clock", "team-ping"):
            script = plugins / plugin / "run.sh"
            assert os.access(script, os.X_OK) and "<<" not in script.read_text(), "no here-document"
        assert json.loads((SOURCES / TEAM / commit / "udeck-plugins.json").read_text())["name"] == "Team plugins"
    bare = fake_github.Source(str(SOURCES / "someone" / "not-plugins"), "someone/not-plugins")
    assert bare.repository.commits["n1"].snapshot.at("udeck-plugins.json") is None
    squatter = fake_github.Source(str(SOURCES / "someone" / "squatter"), "someone/squatter")
    assert squatter.id != team.id and fake_github.read_number(str(plugin_repository.FIXTURES / "id")) == config.PLUGINS_REPOSITORY_ID
    found = fake_github.read_sources(str(plugin_repository.FIXTURES))
    assert sorted(found) == ["someone/not-plugins", "someone/squatter", TEAM]


def test_two_repositories_of_their_own_with_one_number_are_refused(tmp_path):
    root = tmp_path / "repository"
    shutil.copytree(plugin_repository.FIXTURES, root, symlinks=True)
    (root / "sources" / "github" / "someone" / "squatter" / "id").write_text(f"{TEAM_ID}\n")
    with pytest.raises(ValueError, match="share a number"):
        fake_github.read_sources(str(root))
    (root / "sources" / "github" / "someone" / "squatter" / "id").write_text(f"{config.PLUGINS_REPOSITORY_ID}\n")
    with pytest.raises(ValueError, match="official repository's number"):
        fake_github.Fake(str(root), REPOSITORY, str(tmp_path / "log"))


@needs_git
def test_every_commit_of_a_repository_of_its_own_hashes_as_git_hashes_it(tmp_path):
    """The hashes the source checks judge uDeck's Swift by: git's own, for every commit of every repository of its own."""
    for folder in sorted(p for p in SOURCES.glob("*/*") if p.is_dir()):
        repository = fake_github.Repository(str(folder))
        work = tmp_path / folder.name
        work.mkdir()
        git("init", "-q", cwd=work)
        git("config", "core.fileMode", "true", cwd=work)
        parent = None
        for name in repository.names:
            commit = repository.commits[name]
            for child in work.iterdir():
                if child.name != ".git":
                    shutil.rmtree(child) if child.is_dir() else child.unlink()
            shutil.copytree(folder / name, work, symlinks=True, dirs_exist_ok=True)
            git("add", "-A", cwd=work)
            tree = git("write-tree", cwd=work)
            assert commit.snapshot.root == tree, (folder.name, name)
            stamp = f"{commit.when} +0000"
            env = {
                "GIT_AUTHOR_NAME": "uDeck lab", "GIT_AUTHOR_EMAIL": "lab@udeck.invalid", "GIT_AUTHOR_DATE": stamp,
                "GIT_COMMITTER_NAME": "uDeck lab", "GIT_COMMITTER_EMAIL": "lab@udeck.invalid", "GIT_COMMITTER_DATE": stamp,
            }  # fmt: skip
            made = git("commit-tree", tree, "-m", commit.message, *(["-p", parent] if parent else []), cwd=work, env=env)
            assert commit.sha == made, (folder.name, name)
            parent = made


def test_a_repository_of_its_own_is_served_by_its_name_and_by_its_number(served):
    """`/repos/{o}/{r}` once, and `/repositories/{id}/…` for everything after, as GitHub serves a repository; its raw
    files by its name; its main where the lab says; another number is 404."""
    facts = served.json("/lab/facts")[2]
    team = facts["sources"][TEAM]
    t1, t2 = team["commits"]["t1"]["sha"], team["commits"]["t2"]["sha"]
    assert team["id"] == TEAM_ID and facts["id"] == config.PLUGINS_REPOSITORY_ID
    served.state(sources={TEAM: {"main": "t1"}})
    status, _, by_name = served.json(f"/api/repos/{TEAM}")
    _, _, by_number = served.json(f"/api/repositories/{TEAM_ID}")
    assert status == 200 and by_name == by_number == {
        "id": TEAM_ID, "full_name": TEAM, "default_branch": "main", "private": False, "fork": False,
        "owner": {"login": "someone", "type": "User"}}
    assert served.json("/api/repos/Someone/Team-Plugins")[2]["full_name"] == TEAM, "GitHub's names whatever their case"
    status, headers, body = served.get(f"/api/repositories/{TEAM_ID}/commits/main", SHA_ONLY)
    assert (status, body.decode(), headers["ETag"]) == (200, t1, f'"{t1}"')
    assert served.get(f"/api/repositories/{TEAM_ID}/commits/main", {**SHA_ONLY, "If-None-Match": f'"{t1}"'})[0] == 304
    status, _, listing = served.json(f"/api/repositories/{TEAM_ID}/git/trees/{t1}?recursive=1")
    paths = {entry["path"]: entry for entry in listing["tree"]}
    assert status == 200 and paths["plugins/team-clock/run.sh"]["mode"] == "100755"
    status, _, data = served.get(f"/raw/{TEAM}/{t1}/plugins/team-clock/manifest.json")
    assert status == 200 and fake_github.blob_id(data) == paths["plugins/team-clock/manifest.json"]["sha"]
    status, _, passport = served.json(f"/raw/{TEAM}/{t1}/udeck-plugins.json")
    assert status == 200 and passport["name"] == "Team plugins"
    served.state(sources={TEAM: {"main": "t2"}})
    assert served.get(f"/api/repositories/{TEAM_ID}/commits/main", SHA_ONLY)[2].decode() == t2
    _, _, history = served.json(f"/api/repositories/{TEAM_ID}/commits?sha=main&path=plugins/team-clock&per_page=100")
    assert [entry["sha"] for entry in history] == [t2, t1]
    assert served.json(f"/api/repositories/{TEAM_ID}/compare/{t1}...{t2}")[2]["status"] == "ahead"
    assert served.get(f"/api/repositories/{TEAM_ID}/pulls/1")[0] == 404
    assert served.get("/api/repositories/1")[0] == 404 and served.get("/api/repositories/x")[0] == 404
    assert served.get(f"/raw/{TEAM}/{t1}/plugins")[0] == 404, "a folder is no file"
    assert served.get(f"/raw/someone/not-plugins/{t1}/udeck-plugins.json")[0] == 404, "another repository's commit"
    n1 = facts["sources"]["someone/not-plugins"]["commits"]["n1"]["sha"]
    assert served.get(f"/raw/someone/not-plugins/{n1}/udeck-plugins.json")[0] == 404, "no passport"


def test_a_renamed_repository_keeps_its_number_and_another_takes_its_old_name(served):
    """The lab renames someone/team-plugins (the same number) and makes someone/squatter at the old name: by its number
    it says its new name, by the old name it is the other one, and its raw files go by the name it has now."""
    facts = served.json("/lab/facts")[2]
    t1 = facts["sources"][TEAM]["commits"]["t1"]["sha"]
    q1 = facts["sources"]["someone/squatter"]["commits"]["q1"]["sha"]
    squatter_id = facts["sources"]["someone/squatter"]["id"]
    served.state(served={"someone/team-plugins-2": TEAM, TEAM: "someone/squatter"})
    _, _, renamed = served.json(f"/api/repositories/{TEAM_ID}")
    assert renamed["full_name"] == "someone/team-plugins-2" and renamed["id"] == TEAM_ID
    _, _, at_the_old_name = served.json(f"/api/repos/{TEAM}")
    assert at_the_old_name["id"] == squatter_id != TEAM_ID and at_the_old_name["full_name"] == TEAM
    assert served.get(f"/api/repositories/{TEAM_ID}/commits/main", SHA_ONLY)[2].decode() == t1, "its own head, by number"
    assert served.get(f"/api/repos/{TEAM}/commits/main", SHA_ONLY)[2].decode() == q1, "the other one's, by the old name"
    assert served.get(f"/raw/someone/team-plugins-2/{t1}/udeck-plugins.json")[0] == 200
    assert served.get(f"/raw/{TEAM}/{t1}/udeck-plugins.json")[0] == 404, "the old name serves the other repository"
    served.state(served={"someone/squatter": "someone/squatter"})
    assert served.get(f"/api/repositories/{TEAM_ID}")[0] == 404, "served by no name: gone"


def test_the_official_description_says_its_number_and_the_lab_can_give_it_another(served):
    _, _, described = served.json(API)
    assert described["id"] == config.PLUGINS_REPOSITORY_ID and described["full_name"] == REPOSITORY
    served.state(official_id=12345)
    assert served.json(API)[2]["id"] == 12345


def test_a_credential_is_refused_and_logged_as_one_never_by_its_value(served):
    """No token is good for anything yet: one carried, in either provider's header, is 401 — and the log says
    `rejected`, never what it was; an anonymous request says `none`, and the port it came in on."""
    assert served.get(API)[0] == 200
    status, _, body = served.get(API, {"Authorization": "Bearer ghp_the-labs-own-value"})
    assert status == 401 and json.loads(body) == {"message": "Bad credentials"}
    assert served.get(f"/raw/{REPOSITORY}/x/y", {"PRIVATE-TOKEN": "glpat-the-labs-own-value"})[0] == 401
    logged = served.requests()
    assert [r.credential for r in logged] == ["none", "rejected", "rejected"]
    assert {r.port for r in logged} == {served.server.server_address[1]}
    text = served.log.read_text()
    assert "the-labs-own-value" not in text and "ghp_" not in text and "glpat-" not in text


def test_repositories_of_their_own_spend_the_same_hour(tmp_path):
    """GitHub counts what an address asks whatever the repository: by name or by number, the official hour."""
    now = [1_800_000_000.0]
    served = Served(tmp_path, clock=lambda: now[0])
    try:
        assert served.get(API)[1]["x-ratelimit-remaining"] == "59"
        assert served.get(f"/api/repos/{TEAM}")[1]["x-ratelimit-remaining"] == "58"
        assert served.get(f"/api/repositories/{TEAM_ID}/commits/main", SHA_ONLY)[1]["x-ratelimit-remaining"] == "57"
        assert served.get("/api/repositories/1")[1]["x-ratelimit-remaining"] == "56"
        served.state(limit_until=int(now[0]) + 600)
        assert served.get(f"/api/repositories/{TEAM_ID}")[0] == 403
    finally:
        served.close()


def test_a_line_of_an_older_fake_reads_as_no_credential_on_no_port():
    (request,) = parse_log(line() + "\n")
    assert request.credential == "none" and request.port == 0
    (request,) = parse_log(line(credential="rejected", port=8766) + "\n")
    assert request.credential == "rejected" and request.port == 8766


# --- Reading the log -----------------------------------------------------------------------


def line(**fields):
    base = {"at": 1.0, "method": "GET", "host": "api", "path": "/api/x", "query": "", "status": 200, "lab": False}
    return json.dumps({**base, **fields})


def test_a_last_line_still_being_written_is_left_for_the_next_read():
    text = line(path="/api/a") + "\n" + line(path="/api/b")[:20]
    assert [r.path for r in parse_log(text)] == ["/api/a"]


def test_a_line_that_is_not_a_request_is_the_lab_unable_to_read_its_oracle():
    with pytest.raises(ValueError, match="not a request"):
        parse_log(line() + "\n" + "garbage\n")


def test_a_raw_request_says_which_commit_and_path_it_was_for():
    request = Request(0, "GET", "raw", f"/raw/{REPOSITORY}/{'a' * 40}/plugins/uptime/uptime.sh", "", 200, False)
    assert request.raw_file() == ("a" * 40, "plugins/uptime/uptime.sh")
    assert Request(0, "GET", "api", f"/api/repos/{REPOSITORY}", "", 200, False).raw_file() is None
    # A fork's raw file is the fork's, asked by name: never taken for the official repository's.
    fork = Request(0, "GET", "raw", f"/raw/{FORK}/{'a' * 40}/plugins/uptime/uptime.sh", "", 200, False)
    assert fork.raw_file() is None and fork.raw_file(FORK) == ("a" * 40, "plugins/uptime/uptime.sh")


def test_the_fixtures_travel_as_one_archive_with_their_link_and_modes(tmp_path):
    archive = plugin_repository.pack(plugin_repository.FIXTURES, tmp_path)
    import tarfile

    with tarfile.open(archive) as tar:
        members = {member.name: member for member in tar.getmembers()}
    assert "repository/history" in members
    link = members["repository/c1/plugins/linked/lib"]
    assert link.issym() and link.linkname == "run.sh"
    assert members["repository/c1/plugins/uptime/uptime.sh"].mode & 0o100
    assert not members["repository/c1/plugins/uptime/manifest.json"].mode & 0o100
    assert not any(Path(name).name in (".DS_Store", "__pycache__") for name in members)


# --- The lab's hand on it: a machine whose SSH runs here -------------------------------------


class HereSSH:
    """SSH to a guest that is this Mac and a temporary folder: the real shell, the real curl."""

    def __init__(self):
        self.commands = []

    def run(self, command, step, seconds=60, check=True):
        self.commands.append(command)
        done = subprocess.run(["/bin/sh", "-c", command], capture_output=True, text=True, timeout=seconds)
        if check and done.returncode != 0:
            raise LabError(step, f"exited {done.returncode}: {done.stderr.strip()}")
        return done

    def ask(self, command, step, seconds=60):
        return self.run(command, step, seconds, check=False)

    def copy_in(self, local, remote, step, seconds=None):
        shutil.copy(local, remote)


class Here:
    name = "this-mac"

    def __init__(self):
        self.ssh = HereSSH()

    def clock(self):
        return time.monotonic()

    def sleep(self, seconds):
        time.sleep(seconds)


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


@pytest.fixture
def here(tmp_path):
    machine = Here()
    github = FakeGitHub(
        machine, note=lambda text: None, port=free_port(), guest_dir=str(tmp_path / "guest"), python=sys.executable
    )
    yield machine, github
    github.stop()


def test_the_lab_serves_the_fake_tells_it_what_to_say_and_reads_what_it_was_asked(here, tmp_path):
    machine, github = here
    work = tmp_path / "work"
    work.mkdir()
    github.serve(work, main="c1")
    assert github.answers_now("asking")
    c1, c2 = github.commit("c1"), github.commit("c2")
    head = subprocess.run(
        ["curl", "-s", "-H", "Accept: application/vnd.github.sha", f"{github.base_url}{API}/commits/main"],
        capture_output=True, text=True, check=True,
    ).stdout  # fmt: skip
    assert head == c1
    github.tell("moving main", main="c2")
    head = subprocess.run(
        ["curl", "-s", "-H", "Accept: application/vnd.github.sha", f"{github.base_url}{API}/commits/main"],
        capture_output=True, text=True, check=True,
    ).stdout  # fmt: skip
    assert head == c2
    # What the lab asked is the lab's; what curl asked without the mark is "uDeck's".
    asked = github.uDecks_requests("reading")
    assert [r.path for r in asked] == [f"{API}/commits/main", f"{API}/commits/main"]
    assert all(r.lab for r in github.read_log("reading") if r.host == "lab")
    # The folder a check hashes in the guest, with the fake's own code.
    copy = tmp_path / "uptime"
    shutil.copytree(plugin_repository.FIXTURES / "c2/plugins/uptime", copy, symlinks=True)
    assert github.tree_in_guest(str(copy), "hashing") == github.tree("c2", "plugins/uptime")
    assert set(github.files("c1", "plugins/uptime")) == {
        "plugins/uptime/README.md", "plugins/uptime/manifest.json", "plugins/uptime/manifest.ru.json",
        "plugins/uptime/uptime.sh", "plugins/uptime/hold.sh",
    }  # fmt: skip
    kept = github.collect_log(tmp_path)
    assert kept and (tmp_path / "github-requests.jsonl").read_text() == kept


def test_a_state_that_did_not_take_is_the_labs_failure(here, tmp_path):
    machine, github = here
    github.serve(tmp_path, main="c1")
    # Something in the guest keeps the file from being replaced.
    os.chmod(tmp_path / "guest" / "repository", 0o500)
    try:
        with pytest.raises(LabError):
            github.tell("moving main", main="c2")
    finally:
        os.chmod(tmp_path / "guest" / "repository", 0o700)


def test_a_fake_that_never_answers_is_a_lab_error_with_what_it_said(tmp_path):
    machine = Here()
    github = FakeGitHub(machine, note=lambda text: None, port=free_port(), guest_dir=str(tmp_path / "guest"),
                        python="/bin/false")  # fmt: skip
    clock = [0.0]
    machine.clock = lambda: clock[0]
    machine.sleep = lambda seconds: clock.__setitem__(0, clock[0] + seconds)
    with pytest.raises(LabError, match="did not answer within"):
        github.serve(tmp_path)


def test_the_fake_is_asked_nothing_before_it_says_it_listens():
    """A question sent while its port is bound and not listening is dropped unanswered."""
    machine = FakeMachine({"tail -5": ["", "", f"{plugin_repository.LISTENING}: on 127.0.0.1"], "/usr/bin/curl": "alive\n\n200"})
    github = FakeGitHub(machine, note=lambda text: None)
    github._wait_until_it_answers("waiting")
    asked = [c for c in machine.ssh.commands if "tail -5" in c or "/usr/bin/curl" in c]
    assert ["curl" in c for c in asked] == [False, False, False, True]


def test_the_fake_and_the_lab_name_the_same_line():
    assert fake_github.LISTENING == plugin_repository.LISTENING


def test_the_fake_does_not_look_its_own_name_up_between_bind_and_listen(monkeypatch):
    """`HTTPServer.server_bind` would; while it did, the port dropped every question."""
    looked_up = []
    monkeypatch.setattr(socket, "getfqdn", lambda name="": looked_up.append(name) or name)
    server = fake_github.Server(("127.0.0.1", 0), fake_github.handler_for(None))
    try:
        assert looked_up == [] and server.server_name == "127.0.0.1"
    finally:
        server.server_close()


STAND_IN = """#!{python}
# Stands in for the fake: says it listens, and then does not answer.
import socket, sys, time
port = int(sys.argv[4])  # stand-in, fake-github.py, serve, ROOT, PORT
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", port))
if sys.argv[0].endswith("silent"):
    s.listen(1)  # the connection is taken by the system and never answered
print("listening: a stand-in", flush=True)
time.sleep(120)
"""


@pytest.mark.parametrize("how", ["bound", "silent"])
def test_a_question_the_fake_never_answers_is_a_lab_error_in_seconds_with_what_curl_said(tmp_path, monkeypatch, how):
    """Bound and not listening: no connection. Listening and silent: no answer. Neither holds the lab."""
    monkeypatch.setattr(config, "PLUGINS_CONNECT_SECONDS", 1)
    monkeypatch.setattr(config, "PLUGINS_ASK_SECONDS", 20)
    monkeypatch.setattr(config, "PLUGINS_UP_SECONDS", 2)
    if how == "silent":
        monkeypatch.setattr(config, "PLUGINS_ASK_SECONDS", 1)
    stand_in = tmp_path / f"stand-in-{how}"
    stand_in.write_text(STAND_IN.format(python=sys.executable))
    stand_in.chmod(0o755)
    machine = Here()
    guest = tmp_path / "guest"
    github = FakeGitHub(machine, note=lambda text: None, port=free_port(), guest_dir=str(guest), python=str(stand_in))
    started = time.monotonic()
    try:
        with pytest.raises(LabError, match="did not answer within.*listening: a stand-in.*no answer.*curl: \\(28\\)"):
            github.serve(tmp_path)
    finally:
        github.stop()
    # Bound and not listening, curl on its own gives up only after some 8 s: the
    # lab's --connect-timeout is what brings it under that.
    assert time.monotonic() - started < (6 if how == "bound" else 15)


SLOW_NAMES = """import socket, time
def _slow(name=""):
    time.sleep(10)
    return name
socket.getfqdn = _slow
"""


def test_the_real_fake_listens_at_once_and_only_then_says_so(tmp_path):
    """The fake itself, not its Server class alone: with name lookups taking 10 s,
    the `listening` line comes within seconds, and a connection made right after
    it is taken."""
    (tmp_path / "site").mkdir()
    (tmp_path / "site" / "sitecustomize.py").write_text(SLOW_NAMES)
    port = free_port()
    env = dict(os.environ, PYTHONPATH=str(tmp_path / "site"), PYTHONDONTWRITEBYTECODE="1")
    fake = subprocess.Popen(
        [sys.executable, str(plugin_repository.SCRIPT), "serve", str(plugin_repository.FIXTURES), str(port),
         "iillyyaa1997/udeck-plugins", str(tmp_path / "log.jsonl")],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=env,
    )
    started = time.monotonic()
    try:
        said = []
        reader = threading.Thread(target=lambda: said.append(fake.stdout.readline()), daemon=True)
        reader.start()
        reader.join(8)
        assert said and said[0].startswith(fake_github.LISTENING), f"no listening line within 8 s: {said}"
        assert time.monotonic() - started < 8
        with socket.create_connection(("127.0.0.1", port), timeout=1):
            pass
    finally:
        fake.kill()
        fake.wait()
