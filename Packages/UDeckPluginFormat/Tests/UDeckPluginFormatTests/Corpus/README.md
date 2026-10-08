# The corpus of the Python check

What the official repository's check said, frozen so that the Swift check
replacing it can be held to the same answers.

`udeck-plugins/.github/scripts/check-repo.py` checks every plugin that reaches
the official repository. Stage 2 replaces it with `udeck-plugin check-repo`,
built from this package, and deletes it
([docs/plugin-repository.md](../../../../../docs/plugin-repository.md), "The
official repository"). Two implementations of one set of rules drift, and a
rewrite can drift from the start, so before the Python goes this corpus records
what it said: every repository its own tests build, and some more at the edges
of the rules, each with the findings the script reported.

## What is here

* `corpus.json` — the corpus. Generated; do not edit it by hand.
* `make-corpus.py` — what generated it (Python, the standard library only).
* `blobs/Apache-2.0.txt` — the licence text most repositories hold, stored once.

`corpus.json` has, from the top:

* `source` — the udeck-plugins commit whose check was run, the SHA-256 of the
  three files read from it, and the Python and git that ran them.
* `git` — the committer line every commit was made with, and the branch.
* `contents` — every file content any case has, once, under the id git gives
  it as a blob, as segments to join: `text`, `base64`, a `byte` repeated
  `count` times, or a file of `blobs/`.
* `base` — the good repository: a passport, a README and a LICENSE at the top,
  and one plugin, `plugins/sample`, that passes every rule. Path → mode and
  content id.
* `rules` — for the passport and rules 1–17, how many cases break the rule and
  how many that are about it keep it. Every rule is on both sides.
* `cases` — one per line. Each has:
  * `name`, and `source` — the test in `test_check_repo.py` that built it — or
    `probe`: `P01`–`P18` are the edges the stage-2 rules map probed, `A02`,
    `A06`, `A10` and `A15` repositories that keep a rule whose own tests only
    ever break it;
  * `rule` — the rule it is about, when it is about one;
  * `repository` — its commits, each as what it changes in `base` (`set` and
    `remove`), its message, its parent, and the `sha` git gave it — or null for
    a folder that is not a repository at all;
  * `worktree` — files written after the last commit and never committed,
    which the check must not see; `globalAttributes` — a personal
    `core.attributesFile`, which it must ignore;
  * `check` — the arguments: `official`, `ref`, and `base`/`head` for the
    sign-off check, as a commit of the repository or an id it does not have;
  * `expected` — the exit status (0 clean or only warnings, 1 errors, 2 could
    not check), and every finding: `level`, `rule`, `path`, and the Python
    check's `message`;
  * `divergence` — only where the Python check is wrong: `P05`, `P10`, and
    the Python check's own test of `restart`, which builds P10's manifest
    again (`TESTS_THAT_DIVERGE` in `make-corpus.py`). What it does, what the
    Swift check must do instead, and the findings the Swift check must report.

## The two places Python is wrong

* **P05, a `run[0]` that climbs out and back in** —
  `sub/../../sample/run.sh`. Python normalises the path, finds
  `plugins/sample/run.sh`, and passes it. uDeck refuses any relative path that
  leaves the folder on the way (`RepositoryRules.relativePath`), so the Swift
  check must report rule 5.
* **P10, `restart`** — Python calls it a field the contract does not define,
  which uDeck ignores (rule 12). uDeck decodes it as a `RestartPolicy` with four
  required fields; `{"mode": "never"}` does not decode, and uDeck would not load
  the plugin at all. The Swift check must report rule 3 — and, strictly, rule
  12 as Python does, since the contract does not describe `restart`. The same
  manifest, spelt with other spaces, is what check-repo.py's own test
  `Rule12OnlyWhatTheContractDefines.test_in_the_manifest [restart, …]` builds,
  and it carries the same divergence.

## How the Swift side uses it

`CorpusTests` builds every case's repository with `git fast-import`, as the
Python tests did, and checks that each commit gets the id recorded here — the
proof that the repository is byte for byte the one the Python check read. Each
content is checked against its id too.

Then it replays every case: the Swift check (`RepositoryCheck`) runs on the
repository the way the Python check was run — strictly, as the official
repository when `check.official` says so, with the case's base and head — and
its findings are compared with `expected` as level, rule and path, with
`divergence` where there is one, and so is the exit status: 273 of 273, with
no exception. Of the rules the Python check never had, rule 18 adds nothing —
it needs history, which only rule 17's nine cases have, and none of them
changes a plugin — and rule 20 adds nothing. Rule 19 adds a warning to two
cases: three declare a `minUDeck` that is a version, 0.6.0 twice and 99.0.0,
and 0.6.0 is the release that first reads the field, so declaring it does
nothing. A finding of theirs has to be named in `CorpusReplay.newRules`, and a
test holds that list to the `minUDeck` the corpus's manifests declare, read
from the manifests themselves rather than from what the check said.
Every finding's words are read too, in every layer: none may name a Swift type.

## Making it again

Only when the Python check changes, and only while it exists:

```
python3 -I -B make-corpus.py --plugins-repo <a clone of udeck-plugins> --commit <commit>
```

It reads `check-repo.py`, its tests and `LICENSE` out of git at that commit —
never from a working tree — into a temporary folder, runs the tests there with
every commit and every check recorded, and runs the probes. It refuses to write
anything if the tests fail, if a rule lacks a case on either side, or if two
cases share a name. The commit ids come out the same on every run: the commits
are made with a fixed committer and date.
