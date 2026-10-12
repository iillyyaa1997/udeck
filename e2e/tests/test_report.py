"""The verdict table GitHub's job summary shows, read back out of a run's ledger."""

import json

from udeck_e2e import report

LEDGER = [
    {"event": "run-start", "target": "here", "shard": [2, 3], "checks": ["plugins.a", "plugins.b", "plugins.c", "login.r", "plugins.d"]},
    {"event": "preflight", "problems": []},
    {"event": "check", "name": "plugins.a", "outcome": "passed", "seconds": 61.2, "reason": ""},
    {"event": "check", "name": "plugins.b", "outcome": "failed", "seconds": 5, "reason": "the row | said nothing\nat all"},
    {"event": "check", "name": "plugins.c", "outcome": "could-not-check", "seconds": 3, "reason": "SSH failed"},
    {"event": "check", "name": "login.r", "outcome": "not-on-this-target", "seconds": 0, "reason": "it needs a restart"},
    {"event": "run-end", "exit_code": 1, "seconds": 3723, "lab_problems": []},
]


def test_every_check_is_a_row_and_one_that_never_started_is_one_too():
    table = report.table(LEDGER, title="plugins 2/3")
    lines = table.splitlines()
    assert lines[0] == "### plugins 2/3"
    assert lines[1] == "target `here`, part 2 of 3: 1 passed, 1 failed, 1 could not check, 1 not on this target, 1 never started in 1h02m03s, exit 1"
    rows = [line for line in lines if line.startswith("| ") and "`" in line]
    assert [row.split("`")[1] for row in rows] == ["plugins.a", "plugins.b", "plugins.c", "login.r", "plugins.d"]
    assert "| ✅ | `plugins.a` | passed | 1m01s |  |" in table
    # A reason is one cell: its column breaks and line breaks cannot split the row.
    assert "| ❌ | `plugins.b` | failed | 5s | the row \\| said nothing at all |" in table
    assert "| ⏭️ | `login.r` | not on this target | 0s | it needs a restart |" in table
    assert "| ⚠️ | `plugins.d` | never started |  | never started |" in table


def test_a_run_that_could_not_start_says_why_and_one_that_never_ended_says_so():
    events = [
        {"event": "run-start", "checks": ["panel.dwell"]},
        {"event": "preflight", "problems": [{"what": "--target here runs only on a GitHub-hosted runner", "todo": ""}]},
    ]
    table = report.table(events)
    assert "the run did not finish" in table and "could not start: --target here runs only on a GitHub-hosted runner" in table
    assert "target `tart`" in table


def test_the_newest_run_is_the_one_reported_and_a_missing_ledger_is_said(tmp_path, capsys):
    for name in ("20261012-080000Z", "20261012-090000Z"):
        (tmp_path / name).mkdir()
        (tmp_path / name / "ledger.jsonl").write_text("\n".join(json.dumps(e) for e in LEDGER) + "\nnot json\n")
    (tmp_path / "kept").mkdir()
    assert report.newest_run(tmp_path) == tmp_path / "20261012-090000Z"
    assert report.main([str(tmp_path / "20261012-090000Z"), "plugins", "2/3"]) == 0
    out = capsys.readouterr().out
    assert out.startswith("### plugins 2/3") and "1 line(s) of the ledger could not be read" in out
    assert report.main([str(tmp_path / "kept")]) == 2
    assert "nothing to report" in capsys.readouterr().out


def test_each_check_not_on_this_target_is_a_warning_on_the_runs_page(tmp_path, capsys):
    """A job green on what it ran still says what it did not run (`--annotations`)."""
    events = LEDGER + [{"event": "check", "name": "login.off", "outcome": "not-on-this-target", "seconds": 0,
                        "reason": "it needs a restart, 100% of one:\nreally"}]
    assert report.annotations(events) == [
        "::warning title=Not on this target%3A login.r::login.r did not run here, and neither passed nor failed: it needs a restart",
        "::warning title=Not on this target%3A login.off::login.off did not run here, and neither passed nor failed: "
        "it needs a restart, 100%25 of one:%0Areally",
    ]
    assert report.annotations([e for e in LEDGER if e.get("outcome") != "not-on-this-target"]) == []
    (tmp_path / "20261012-090000Z").mkdir()
    (tmp_path / "20261012-090000Z" / "ledger.jsonl").write_text("\n".join(json.dumps(e) for e in LEDGER))
    assert report.main(["--annotations", str(tmp_path / "20261012-090000Z")]) == 0
    assert capsys.readouterr().out == (
        "::warning title=Not on this target%3A login.r::login.r did not run here, and neither passed nor failed: it needs a restart\n"
    )
    assert report.main(["--annotations", str(tmp_path / "kept")]) == 2
    assert capsys.readouterr().out == ""
