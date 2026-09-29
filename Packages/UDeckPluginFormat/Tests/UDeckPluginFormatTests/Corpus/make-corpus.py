#!/usr/bin/env python3
"""Freeze what the official repository's Python check says, so Swift can be held to it.

udeck-plugins' .github/scripts/check-repo.py is the check every plugin in the
official repository has passed. Stage 2 replaces it with `udeck-plugin
check-repo`, built from this package, and deletes it. Before it goes, this
script records what it said: every repository its own tests build, and a few
more probes of its edges, each with the findings the script reported. The
result, corpus.json beside this file, is committed; the Swift tests replay it.

    python3 -I -B make-corpus.py --plugins-repo <a clone of udeck-plugins> [--commit 7403916]

It reads check-repo.py, its tests and the repository's LICENSE out of git at
one commit (never from a working tree), copies them into a temporary folder,
and runs the tests there with every repository they commit and every check
they make recorded. Nothing is imported from the checkout. The standard
library only, like the script it records.

Every repository is recorded as the commits that make it -- files, modes,
messages, parents -- in the form `git fast-import` takes, so that the Swift
side can build the same repository and prove it did: the commit ids come out
the same. Findings are recorded as the script printed them; the replay compares
level, rule and path, and keeps the message for whoever reads a failure.
"""

import argparse
import base64
import contextlib
import hashlib
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True

HERE = os.path.dirname(os.path.abspath(__file__))
OUTPUT = os.path.join(HERE, "corpus.json")
BLOBS = os.path.join(HERE, "blobs")
APACHE_BLOB = "Apache-2.0.txt"

# A run of one byte at least this long is written as a repeat, not spelt out.
LONG_RUN = 256

RULES = ["passport"] + [str(n) for n in range(1, 18)]


def git_show(repo, commit, path):
    done = subprocess.run(["git", "-C", repo, "show", "{}:{}".format(commit, path)],
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if done.returncode != 0:
        sys.exit("could not read {} at {}: {}".format(path, commit, done.stderr.decode().strip()))
    return done.stdout


def full_commit(repo, commit):
    done = subprocess.run(["git", "-C", repo, "rev-parse", "--verify", commit + "^{commit}"],
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if done.returncode != 0:
        sys.exit("{} is not a commit in {}".format(commit, repo))
    return done.stdout.decode().strip()


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


# --- content, written compactly -------------------------------------------------

class Content:
    """Every distinct file content once, under its git blob id, as segments the Swift side joins back.

    A segment is text, base64, one byte repeated, or a file of blobs/. Most
    repositories differ from the good one in a file or two, so storing each
    content once, by the id git itself would give it, keeps the corpus small --
    and lets the Swift side check each content against its id with GitHash.
    """

    def __init__(self, apache):
        self.apache = apache.encode("utf-8")
        self.table = {}

    def store(self, data):
        blob = hashlib.sha1(b"blob %d\0" % len(data) + data).hexdigest()
        if blob not in self.table:
            self.table[blob] = self.encode(data)
        return blob

    def encode(self, data):
        segments = []
        rest = data
        while True:
            at = rest.find(self.apache) if self.apache else -1
            if at < 0:
                segments += self._plain(rest)
                break
            segments += self._plain(rest[:at])
            segments.append({"blob": APACHE_BLOB})
            rest = rest[at + len(self.apache):]
        return segments

    def _plain(self, data):
        segments = []
        start = 0
        index = 0
        while index < len(data):
            end = index
            while end < len(data) and data[end] == data[index]:
                end += 1
            if end - index >= LONG_RUN:
                segments += self._literal(data[start:index])
                segments.append({"byte": data[index], "count": end - index})
                start = end
            index = end
        segments += self._literal(data[start:])
        return segments

    @staticmethod
    def _literal(data):
        if not data:
            return []
        try:
            return [{"text": data.decode("utf-8")}]
        except UnicodeDecodeError:
            return [{"base64": base64.b64encode(data).decode("ascii")}]


# --- recording ------------------------------------------------------------------

class Recorder:
    def __init__(self, tcr, check_repo, content):
        self.tcr = tcr
        self.check_repo = check_repo
        self.content = content
        self.repositories = {}   # path -> [commit]
        self.cases = []
        self.test = None
        self.subtests = []
        self.counts = {}

    def install(self):
        recorder = self
        original_init = self.tcr.Repository.__init__
        original_commit = self.tcr.Repository.commit
        original_check = self.check_repo.check
        original_subtest = unittest.TestCase.subTest

        def init(repository, test):
            original_init(repository, test)
            recorder.repositories[repository.path] = []

        def commit(repository, files, message=self.tcr.SIGNED, parent=None):
            sha = original_commit(repository, files, message=message, parent=parent)
            commits = recorder.repositories[repository.path]
            parents = [i for i, c in enumerate(commits) if c["sha"] == parent] if parent else []
            commits.append({
                "files": recorder.tree(files),
                "message": message,
                "parent": parents[0] if parents else None,
                "sha": sha,
            })
            return sha

        def check(repo=".", ref="HEAD", official=False, base=None, head=None):
            try:
                snapshot, report = original_check(repo, ref, official, base, head)
            except recorder.check_repo.CheckFailed as failure:
                recorder.record(repo, ref, official, base, head, None, str(failure))
                raise
            recorder.record(repo, ref, official, base, head, report, None)
            return snapshot, report

        @contextlib.contextmanager
        def sub_test(test, msg=None, **params):
            recorder.subtests.append(describe_subtest(msg, params))
            try:
                with original_subtest(test, msg, **params):
                    yield
            finally:
                recorder.subtests.pop()

        self.tcr.Repository.__init__ = init
        self.tcr.Repository.commit = commit
        self.check_repo.check = check
        unittest.TestCase.subTest = sub_test

    def tree(self, files):
        tree = {}
        for path, content in sorted(files.items()):
            mode, content = content if isinstance(content, tuple) else (self.tcr.FILE, content)
            if mode == self.tcr.SUBMODULE:
                tree[path] = {"mode": mode, "commit": content}
            else:
                tree[path] = {"mode": mode, "blob": self.content.store(content)}
        return tree

    def record(self, repo, ref, official, base, head, report, failure):
        # A folder no test committed to is recorded as no repository at all.
        commits = self.repositories.get(repo)

        def commit_ref(sha):
            if sha is None:
                return None
            for index, entry in enumerate(commits or []):
                if entry["sha"] == sha:
                    return {"commit": index}
            return {"sha": sha}

        name = self.name()
        case = {
            "name": name,
            "source": self.test,
            "rule": target_rule(self.test),
            "repository": None if commits is None else {"commits": [dict(c) for c in commits]},
            "check": {
                "official": bool(official),
                "ref": ref,
                "base": commit_ref(base),
                "head": commit_ref(head),
            },
            "expected": {},
        }
        worktree = self.worktree(repo) if commits is not None else {}
        if worktree:
            case["worktree"] = worktree
        global_config = os.environ.get("GIT_CONFIG_GLOBAL")
        if global_config and global_config != os.devnull:
            case["globalAttributes"] = self.global_attributes(global_config)
        if failure is not None:
            case["expected"] = {"exit": 2, "couldNotCheck": failure.replace(repo, "<repository>"), "findings": []}
        else:
            findings = [{"level": f.level, "rule": f.rule, "path": f.path, "message": f.message}
                        for f in report.findings]
            errors = [f for f in findings if f["level"] == "error"]
            case["expected"] = {"exit": 1 if errors else 0, "findings": findings}
        self.cases.append(case)

    def worktree(self, repo):
        """Files written into the checkout after the commit -- never committed, so never checked."""
        found = {}
        for folder, directories, files in os.walk(repo):
            directories[:] = [d for d in directories if not (folder == repo and d == ".git")]
            for name in files:
                path = os.path.join(folder, name)
                with open(path, "rb") as handle:
                    found[os.path.relpath(path, repo)] = self.content.store(handle.read())
        return found

    def global_attributes(self, config):
        with open(config) as handle:
            text = handle.read()
        prefix = "attributesFile = "
        for line in text.splitlines():
            if prefix in line:
                with open(line.split(prefix, 1)[1].strip(), "rb") as handle:
                    return self.content.store(handle.read())
        sys.exit("a global git configuration without core.attributesFile: {}".format(text))

    def name(self):
        test = self.test.split(".")[-2:] if self.test else ["?"]
        label = ".".join(test)
        if self.subtests:
            label += " [" + "; ".join(self.subtests) + "]"
        self.counts[label] = self.counts.get(label, 0) + 1
        if self.counts[label] > 1:
            label += " #{}".format(self.counts[label])
        return label


def describe_subtest(msg, params):
    removed = getattr(sys.modules.get("tcr"), "REMOVE", None)
    parts = []
    if msg is not None:
        parts.append(str(msg))
    for key, value in params.items():
        if value is removed:
            text = "REMOVE"  # its repr is an address, which would change from run to run
        elif isinstance(value, str):
            text = json.dumps(value, ensure_ascii=False)
        else:
            text = repr(value)
        if len(text) > 60:
            text = text[:57] + "..."
        parts.append("{}={}".format(key, text))
    return ", ".join(parts)


def target_rule(test):
    """The rule a test class is about, from its name: Rule7Names -> "7", Passport -> "passport"."""
    if not test:
        return None
    cls = test.split(".")[-2]
    if cls == "Passport":
        return "passport"
    if cls.startswith("Rule"):
        digits = ""
        for ch in cls[4:]:
            if not ch.isdigit():
                break
            digits += ch
        return digits or None
    if cls == "Probes":
        return None
    return None


class Result(unittest.TextTestResult):
    recorder = None

    def startTest(self, test):
        Result.recorder.test = test.id()
        Result.recorder.counts = {}
        super().startTest(test)


# --- the probes: the edges the rules map found (report 10, P01-P18) -------------

def acceptances(tcr):
    """Repositories that keep a rule whose own tests only ever break it.

    check-repo.py's tests show rules 2, 6, 10 and 15 only failing; the good
    repository passes them, but a case about the rule says what passing means.
    """
    author = "Ада Лавлейс"
    return [
        ("A02 plugins/ holds two plugin folders and nothing else", "2",
         dict(tcr.repository(), **tcr.plugin("plugins/second", **{"manifest.json": tcr.manifest(id="second")}))),
        ("A06 a plugin with a folder of its own files", "6",
         tcr.repository(**{"lib/helper.sh": (tcr.EXECUTABLE, tcr.RUN_SH), "lib/data/table.txt": b"a\tb\n"})),
        ("A10 README.md written in another language", "10",
         tcr.repository(**{"README.md": "# Образец\n\nПлагин, который существует, чтобы его проверяли.\n".encode()})),
        ("A15 an author outside ASCII, and the LICENSE naming the same", "15",
         tcr.repository(**{"manifest.json": tcr.manifest(author=author),
                           "LICENSE": tcr.licence(first="Copyright 2026 " + author)})),
    ]


def probes(tcr):
    good = json.loads(tcr.manifest())

    def m(**changes):
        value = dict(good)
        value.update(changes)
        return json.dumps(value).encode()

    return [
        ("P01 passport name blank", dict(tcr.repository(), **{"udeck-plugins.json": tcr.passport(name="   ")}), None),
        ("P02 passport format 1.0", dict(tcr.repository(), **{"udeck-plugins.json": b'{"format": 1.0, "name": "x"}'}), None),
        ("P03 manifest id with trailing newline", tcr.repository(**{"manifest.json": m(id="sample\n")}), None),
        ("P04 manifest with UTF-8 BOM", tcr.repository(**{"manifest.json": b"\xef\xbb\xbf" + tcr.manifest()}), None),
        ("P05 run climbs out and back in", tcr.repository(**{"manifest.json": m(run=["sub/../../sample/run.sh"])}), {
            "python": "passes it: it normalises the path to plugins/sample/run.sh, which is there and executable",
            "swift": "refuses it under rule 5, as uDeck does: a relative run[0] may not leave the folder on the "
                     "way, and RepositoryRules.relativePath refuses sub/../.. before it comes back",
            "findings": [{"level": "error", "rule": "5", "path": "plugins/sample/manifest.json"}],
        }),
        ("P06 LFS pointer spec v2", tcr.repository(**{"data.txt": b"version https://git-lfs.github.com/spec/v2\noid sha256:00\nsize 1\n"}), None),
        ("P07 LFS pointer hawser", tcr.repository(**{"data.txt": b"version https://hawser.github.com/spec/v1\noid sha256:00\nsize 1\n"}), None),
        ("P08 LFS pointer v1 padded past 1024 bytes", tcr.repository(**{"data.txt": b"version https://git-lfs.github.com/spec/v1\n" + b"x" * 2000 + b"\n"}), None),
        ("P09 bare-name run[0] jq", tcr.repository(**{"manifest.json": m(run=["jq", "."])}), None),
        ("P10 restart field", tcr.repository(**{"manifest.json": m(restart={"mode": "never"})}), {
            "python": "calls restart a field the contract does not define, which uDeck ignores (rule 12)",
            "swift": "refuses the manifest under rule 3: uDeck does not ignore restart, it decodes it as a "
                     "RestartPolicy with four required fields, and {\"mode\": \"never\"} does not decode, so "
                     "uDeck would not load this plugin at all",
            "findings": [{"level": "error", "rule": "3", "path": "plugins/sample/manifest.json"}],
        }),
        ("P11 window defaultWidth 4.0", tcr.repository(**{"manifest.json": m(window={"defaultWidth": 4.0})}), None),
        ("P12 minUDeck 99.0.0", tcr.repository(**{"manifest.json": m(minUDeck="99.0.0")}), None),
        ("P13 settings key with trailing newline", tcr.repository(**{
            "manifest.json": m(settings=[{"key": "rows\n", "type": "int", "default": 3, "label": "Rows"}]),
            "manifest.ru.json": tcr.translation(settings={})}), None),
        ("P14 run[0] newline only", tcr.repository(**{"manifest.json": m(run=["\n"])}), None),
        ("P15 interval 1e400", tcr.repository(**{"manifest.json": tcr.manifest().decode().replace(
            '"interval": 60', '"interval": 1e400').encode()}), None),
        ("P16 setting default 3.0 for int", tcr.repository(**{
            "manifest.json": m(settings=[{"key": "rows", "type": "int", "default": 3.0, "label": "Rows"}]),
            "manifest.ru.json": tcr.translation(settings={})}), None),
        ("P17 translation file manifest.backup.json only", tcr.repository(**{
            "manifest.ru.json": tcr.REMOVE, "manifest.backup.json": b"{}"}), None),
        ("P18 executable in subfolder bin/run", tcr.repository(**{
            "manifest.json": m(run=["bin/run"]), "bin/run": (tcr.EXECUTABLE, tcr.RUN_SH)}), None),
    ]


def probe_suite(tcr, recorder):
    cases = probes(tcr)
    accepted = acceptances(tcr)

    class Probes(tcr.CheckTestCase):
        def test_acceptances(self):
            for name, rule, files in accepted:
                recorder.subtests.append(name)
                try:
                    self.assertClean(files)
                finally:
                    recorder.subtests.pop()
                case = recorder.cases[-1]
                case["name"] = name
                case["probe"] = name.split(" ", 1)[0]
                case["rule"] = rule

        def test_probes(self):
            for name, files, divergence in cases:
                recorder.subtests.append(name)
                try:
                    self.check(files, official=True)
                finally:
                    recorder.subtests.pop()
                case = recorder.cases[-1]
                case["name"] = name
                case["probe"] = name.split(" ", 1)[0]
                if divergence:
                    case["divergence"] = divergence

    Probes.__module__ = "probes"
    return unittest.defaultTestLoader.loadTestsFromTestCase(Probes)


# --- the whole run --------------------------------------------------------------

def verdicts(cases):
    """For each rule: how many cases break it, and how many that were about it pass it."""
    table = {rule: {"breaks": 0, "passes": 0} for rule in RULES}
    for case in cases:
        reported = {f["rule"] for f in case["expected"]["findings"]}
        rule = case.get("rule")
        for each in reported:
            if each in table:
                table[each]["breaks"] += 1
        if rule in table and rule not in reported and "couldNotCheck" not in case["expected"]:
            table[rule]["passes"] += 1
    return table


def against_the_good_repository(cases):
    """Rewrites every commit as what it changes in the good repository, which is stored once.

    Nearly every case is the good repository with one thing changed; written
    out whole, each would repeat it. As `set` and `remove`, a case shows only
    the thing it is about.
    """
    good = [case for case in cases
            if case["source"] and case["source"].endswith("TheGoodRepository.test_passes_as_the_official_repository")]
    if len(good) != 1 or good[0]["expected"]["findings"]:
        sys.exit("the good repository is not one clean case")
    base = good[0]["repository"]["commits"][0]["files"]
    for case in cases:
        for commit in (case["repository"] or {}).get("commits", []):
            files = commit.pop("files")
            commit["set"] = {path: entry for path, entry in files.items() if base.get(path) != entry}
            commit["remove"] = sorted(path for path in base if path not in files)
    return base


def write(corpus, handle):
    """JSON with one case, and one content, to a line: a change to the check shows as the lines it changed."""
    def one(value):
        return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))

    handle.write("{\n")
    keys = sorted(corpus)
    for index, key in enumerate(keys):
        value = corpus[key]
        handle.write(" {}: ".format(one(key)))
        if key == "cases":
            handle.write("[\n" + ",\n".join("  " + one(case) for case in value) + "\n ]")
        elif key in ("contents", "base"):
            handle.write("{\n" + ",\n".join("  {}: {}".format(one(name), one(value[name]))
                                              for name in sorted(value)) + "\n }")
        else:
            handle.write(json.dumps(value, ensure_ascii=False, sort_keys=True, indent=1).replace("\n", "\n "))
        handle.write(",\n" if index < len(keys) - 1 else "\n")
    handle.write("}\n")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    parser.add_argument("--plugins-repo", required=True, help="a clone of udeck-plugins")
    parser.add_argument("--commit", default="7403916", help="the commit whose check to record (default: 7403916)")
    arguments = parser.parse_args(argv)

    repo = os.path.abspath(arguments.plugins_repo)
    commit = full_commit(repo, arguments.commit)
    work = tempfile.mkdtemp(prefix="udeck-corpus-")
    try:
        scripts = os.path.join(work, ".github", "scripts")
        os.makedirs(scripts)
        sources = {}
        for path in (".github/scripts/check-repo.py", ".github/scripts/test_check_repo.py", "LICENSE"):
            data = git_show(repo, commit, path)
            sources[path] = hashlib.sha256(data).hexdigest()
            with open(os.path.join(work, path), "wb") as handle:
                handle.write(data)

        tcr = load("tcr", os.path.join(scripts, "test_check_repo.py"))
        check_repo = tcr.check_repo
        with open(os.path.join(work, "LICENSE"), encoding="utf-8") as handle:
            apache = handle.read()

        recorder = Recorder(tcr, check_repo, Content(apache))
        recorder.install()
        Result.recorder = recorder

        suite = unittest.TestSuite()
        suite.addTests(unittest.defaultTestLoader.loadTestsFromModule(tcr))
        suite.addTests(probe_suite(tcr, recorder))
        runner = unittest.TextTestRunner(stream=sys.stderr, verbosity=1, resultclass=Result)
        outcome = runner.run(suite)
        if not outcome.wasSuccessful():
            sys.exit("check-repo.py's own tests did not pass here, so nothing they recorded is worth keeping")

        cases = recorder.cases
        base = against_the_good_repository(cases)
        table = verdicts(cases)
        missing = [rule for rule, counts in table.items() if not counts["breaks"] or not counts["passes"]]
        if missing:
            sys.exit("no case that breaks, or none that passes, rule(s) {}".format(", ".join(missing)))
        names = [case["name"] for case in cases]
        if len(set(names)) != len(names):
            sys.exit("two cases share a name")

        os.makedirs(BLOBS, exist_ok=True)
        with open(os.path.join(BLOBS, APACHE_BLOB), "w", encoding="utf-8", newline="") as handle:
            handle.write(apache)

        corpus = {
            "about": "What udeck-plugins' check-repo.py reported for each repository, frozen for the Swift "
                     "check to be held to. Made by make-corpus.py; do not edit by hand.",
            "contents": recorder.content.table,
            "base": base,
            "source": {
                "repository": "https://github.com/iillyyaa1997/udeck-plugins",
                "commit": commit,
                "sha256": sources,
                "python": "{}.{}.{}".format(*sys.version_info[:3]),
                "git": subprocess.run(["git", "--version"], stdout=subprocess.PIPE).stdout.decode().strip(),
            },
            "git": {
                "committer": "Ada Lovelace <ada@example.com> 1790596800 +0000",
                "branch": "main",
            },
            "blobs": [APACHE_BLOB],
            "rules": table,
            "cases": cases,
        }
        with open(OUTPUT, "w", encoding="utf-8") as handle:
            write(corpus, handle)
        print("{} cases from {} at {}; every rule broken and passed: {}".format(
            len(cases), arguments.plugins_repo, commit[:12],
            ", ".join("{} {}/{}".format(r, c["breaks"], c["passes"]) for r, c in table.items())))
    finally:
        shutil.rmtree(work, True)


if __name__ == "__main__":
    main()
