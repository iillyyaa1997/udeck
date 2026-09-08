#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Tests for the claude-sessions uDeck plugin.

Everything runs against a fabricated filesystem root — a tmpdir holding fake
title/meta/lease files and a canned ``ps`` listing — so the suite says the same
thing on a machine with forty live sessions and on one with none.

    python3 -m unittest discover -s examples/claude-sessions -p 'test_*.py'
"""

import contextlib
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import sessions  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "sessions.py")
MANIFEST = os.path.join(HERE, "manifest.json")

# A pid far above macOS's PID_MAX (99998): kill(2) answers ESRCH for it, so
# os.kill raises ProcessLookupError deterministically.
DEAD_PID = 2 ** 30


def read_manifest():
    with open(MANIFEST) as handle:
        return json.load(handle)


ICON_VOCABULARY = {"ok", "warn", "crit", "wait", "run",
                   "idle", "done", "pause", "info", "dot"}
TINTS = {"ok", "warn", "crit", "unknown"}
ROW_KEYS = {"text", "kv", "meter", "list", "spark", "table", "log"}


# --------------------------------------------------------------------------
# Card validator — an independent reading of the schema in the plugin brief.
# --------------------------------------------------------------------------

def validate_card(card):
    """Return a list of schema violations; empty means the card is valid."""
    problems = []

    def bad(message):
        problems.append(message)

    if not isinstance(card, dict):
        return ["card is %s, not an object" % type(card).__name__]

    allowed_top = {"state", "title", "chip", "rows", "actions", "ttl"}
    for key in card:
        if key not in allowed_top:
            bad("unknown top-level key %r" % key)

    if card.get("state") not in TINTS:
        bad("state %r is not one of %s" % (card.get("state"), sorted(TINTS)))
    for key in ("title", "chip"):
        if key in card and not isinstance(card[key], str):
            bad("%s must be a string" % key)
    if "ttl" in card:
        ttl = card["ttl"]
        if isinstance(ttl, bool) or not isinstance(ttl, (int, float)) or ttl <= 0:
            bad("ttl must be a positive number, got %r" % (ttl,))

    rows = card.get("rows", [])
    if not isinstance(rows, list):
        bad("rows must be a list")
        rows = []
    for index, row in enumerate(rows):
        where = "row %d" % index
        if not isinstance(row, dict):
            bad("%s is %s, not an object" % (where, type(row).__name__))
            continue
        present = [key for key in row if key in ROW_KEYS]
        unknown = [key for key in row if key not in ROW_KEYS]
        if unknown:
            bad("%s has unknown key(s) %s" % (where, unknown))
        if len(present) != 1:
            bad("%s must have exactly one row-type key, has %s" % (where, present))
            continue
        _validate_row(row, present[0], where, bad)

    actions = card.get("actions", [])
    if not isinstance(actions, list):
        bad("actions must be a list")
        actions = []
    for index, action in enumerate(actions):
        where = "action %d" % index
        if not isinstance(action, dict):
            bad("%s is not an object" % where)
            continue
        for key in action:
            if key not in {"label", "run", "confirm"}:
                bad("%s has unknown key %r" % (where, key))
        if not isinstance(action.get("label"), str) or not action.get("label"):
            bad("%s needs a non-empty label" % where)
        run = action.get("run")
        if not isinstance(run, list) or not run or \
                not all(isinstance(part, str) for part in run):
            bad("%s run must be a non-empty list of strings" % where)
        if "confirm" in action and not isinstance(action["confirm"], str):
            bad("%s confirm must be a string" % where)
    return problems


def _validate_row(row, kind, where, bad):
    value = row[kind]
    if kind == "text":
        if not isinstance(value, str):
            bad("%s text must be a string" % where)
    elif kind == "kv":
        if not isinstance(value, list) or len(value) not in (2, 3):
            bad("%s kv must be a 2- or 3-element list" % where)
            return
        if not all(isinstance(part, str) for part in value[:2]):
            bad("%s kv label and value must be strings" % where)
        if len(value) == 3 and value[2] not in TINTS:
            bad("%s kv tint %r is not a state" % (where, value[2]))
    elif kind == "meter":
        if not isinstance(value, dict):
            bad("%s meter must be an object" % where)
            return
        number = value.get("value")
        if isinstance(number, bool) or not isinstance(number, (int, float)) \
                or not 0.0 <= number <= 1.0:
            bad("%s meter value must be between 0 and 1" % where)
        for key in ("label", "caption"):
            if key in value and not isinstance(value[key], str):
                bad("%s meter %s must be a string" % (where, key))
        if "state" in value and value["state"] not in TINTS:
            bad("%s meter state %r is not a state" % (where, value["state"]))
    elif kind == "list":
        if not isinstance(value, list):
            bad("%s list must be a list" % where)
            return
        for index, item in enumerate(value):
            spot = "%s item %d" % (where, index)
            if not isinstance(item, dict):
                bad("%s is not an object" % spot)
                continue
            for key in item:
                if key not in {"text", "note", "icon", "state"}:
                    bad("%s has unknown key %r" % (spot, key))
            if not isinstance(item.get("text"), str):
                bad("%s needs a text string" % spot)
            if "note" in item and not isinstance(item["note"], str):
                bad("%s note must be a string" % spot)
            if "icon" in item and item["icon"] not in ICON_VOCABULARY:
                bad("%s icon %r is outside the vocabulary" % (spot, item["icon"]))
            if "state" in item and item["state"] not in TINTS:
                bad("%s state %r is not a state" % (spot, item["state"]))
    elif kind == "spark":
        values = value.get("values") if isinstance(value, dict) else value
        if not isinstance(values, list) or \
                not all(isinstance(v, (int, float)) and not isinstance(v, bool)
                        for v in values):
            bad("%s spark needs a list of numbers" % where)
        if isinstance(value, dict):
            for key in value:
                if key not in {"values", "caption"}:
                    bad("%s spark has unknown key %r" % (where, key))
    elif kind == "table":
        if not isinstance(value, dict):
            bad("%s table must be an object" % where)
            return
        columns = value.get("columns")
        if not isinstance(columns, list) or not columns:
            bad("%s table needs columns" % where)
            columns = []
        for column in columns:
            if not isinstance(column, dict) or not isinstance(column.get("title"), str):
                bad("%s table column needs a title" % where)
            elif column.get("align") not in (None, "left", "right", "center"):
                bad("%s table column align %r is invalid" % (where, column.get("align")))
        table_rows = value.get("rows")
        if not isinstance(table_rows, list):
            bad("%s table needs rows" % where)
        else:
            for table_row in table_rows:
                if not isinstance(table_row, list) or \
                        not all(isinstance(cell, str) for cell in table_row):
                    bad("%s table row must be a list of strings" % where)
                elif columns and len(table_row) != len(columns):
                    bad("%s table row width does not match the columns" % where)
    elif kind == "log":
        if not isinstance(value, list) or \
                not all(isinstance(line, str) for line in value):
            bad("%s log must be a list of strings" % where)


# --------------------------------------------------------------------------
# Fake machine
# --------------------------------------------------------------------------

class FakePs(object):
    """Stands in for ``read_ps``; records which field lists were asked for."""

    def __init__(self, commands="", tty=""):
        self.commands = commands
        self.tty = tty
        self.calls = []

    def __call__(self, fields="command="):
        self.calls.append(fields)
        return self.tty if fields.startswith("tty=") else self.commands


class FailingPs(object):
    def __init__(self, error):
        self.error = error

    def __call__(self, fields="command="):
        raise self.error


def keeper_line(sid, tty="ttys001"):
    return ('bash -c F=/tmp/claude-tab-title-%s.txt; '
            'printf "x" > /dev/%s; sleep 5' % (sid, tty))


def claude_line(sid=None, tty="ttys001"):
    return "%s   claude%s" % (tty, (" --resume " + sid) if sid else "")


class FakeMachine(object):
    """A tmpdir with a title directory and a lease directory."""

    def __init__(self):
        self.root = tempfile.mkdtemp(prefix="udeck-claude-sessions-")
        self.title_dir = os.path.join(self.root, "tmp")
        self.leases_dir = os.path.join(self.root, "leases")
        os.makedirs(self.title_dir)
        os.makedirs(self.leases_dir)

    def cleanup(self):
        shutil.rmtree(self.root, ignore_errors=True)

    def title(self, sid, line, mtime=None):
        path = os.path.join(self.title_dir, "claude-tab-title-%s.txt" % sid)
        with open(path, "w") as handle:
            handle.write(line + "\n")
        if mtime is not None:
            os.utime(path, (mtime, mtime))
        return path

    def meta(self, sid, **fields):
        path = os.path.join(self.title_dir, "claude-tab-title-%s.meta" % sid)
        with open(path, "w") as handle:
            json.dump(fields, handle)
        return path

    def raw_meta(self, sid, blob):
        path = os.path.join(self.title_dir, "claude-tab-title-%s.meta" % sid)
        with open(path, "w") as handle:
            handle.write(blob)
        return path

    def lease(self, sid, account="pers", cwd="/Users/x/Workspace/u-pilot",
              pid=None, heartbeat_age=0.0, started_age=3600.0, now=None):
        now = time.time() if now is None else now
        path = os.path.join(self.leases_dir, "%s.json" % sid)
        with open(path, "w") as handle:
            json.dump({
                "account_label": account,
                "config_dir": "/Users/x/.claude",
                "cwd": cwd,
                "heartbeat_ts": now - heartbeat_age,
                "pid": os.getpid() if pid is None else pid,
                "started_ts": now - started_age,
            }, handle)
        return path

    def raw_lease(self, sid, blob):
        path = os.path.join(self.leases_dir, "%s.json" % sid)
        with open(path, "w") as handle:
            handle.write(blob)
        return path

    def settings(self, **overrides):
        base = sessions.load_settings(env={})
        base["title_dir"] = self.title_dir
        base["leases_dir"] = self.leases_dir
        base.update(overrides)
        return base


SID_A = "aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa"
SID_B = "bbbbbbbb-2222-4222-8222-bbbbbbbbbbbb"
SID_C = "cccccccc-3333-4333-8333-cccccccccccc"
SID_D = "dddddddd-4444-4444-8444-dddddddddddd"


class MachineTestCase(unittest.TestCase):
    def setUp(self):
        self.machine = FakeMachine()
        self.addCleanup(self.machine.cleanup)
        self.now = time.time()

    def card(self, ps=None, **overrides):
        settings = self.machine.settings(**overrides)
        card = sessions.gather(settings, self.now, ps_reader=ps or FakePs())
        self.assertEqual([], validate_card(card),
                         "card violates the row schema: %s" % validate_card(card))
        return card

    @contextlib.contextmanager
    def expect_stderr(self, *fragments):
        """Capture the plugin's diagnostics and assert what they said.

        Every test that reaches here feeds the plugin deliberately broken data,
        so a silent run would be the bug: the contract is that the reason lands
        on stderr while stdout keeps carrying a usable card.
        """
        buffer = io.StringIO()
        with contextlib.redirect_stderr(buffer):
            yield buffer
        written = buffer.getvalue()
        for fragment in fragments:
            self.assertIn(fragment, written)

    def rows_of(self, card, kind):
        return [row[kind] for row in card["rows"] if kind in row]

    def text_of(self, card):
        return "\n".join(self.rows_of(card, "text"))


# --------------------------------------------------------------------------
# Title parsing
# --------------------------------------------------------------------------

class TitleParsingTests(unittest.TestCase):

    def parse(self, line):
        icon, name, ctx, progress, bang = sessions.parse_title_line(line)
        return {"icon": icon, "name": name, "ctx": ctx,
                "progress": progress, "bang": bang}

    def test_icon_and_ctx(self):
        got = self.parse("▶ 30% · AP-11112 прогон развести")
        self.assertEqual("▶", got["icon"])
        self.assertEqual("AP-11112 прогон развести", got["name"])
        self.assertEqual(30, got["ctx"])
        self.assertFalse(got["bang"])

    def test_no_icon_keeps_a_name_containing_the_separator(self):
        # Live file on the operator's machine: an anchored name, no icon, and
        # a "·" that belongs to the name.  Splitting on "·" would mangle it.
        got = self.parse("Задачи · тех-стори")
        self.assertEqual("", got["icon"])
        self.assertEqual("Задачи · тех-стори", got["name"])
        self.assertIsNone(got["ctx"])

    def test_no_icon_long_anchored_name(self):
        got = self.parse("Личное · цвета табов Warp")
        self.assertEqual("", got["icon"])
        self.assertEqual("Личное · цвета табов Warp", got["name"])

    def test_bang_and_watchers(self):
        got = self.parse("✋ 54% · ! · m2 · u-flow всегда")
        self.assertEqual("✋", got["icon"])
        self.assertTrue(got["bang"])
        self.assertEqual(54, got["ctx"])
        self.assertEqual("u-flow всегда", got["name"])

    def test_progress(self):
        got = self.parse("▶ 3/7 · 42% · AP-1 build the thing")
        self.assertEqual("3/7", got["progress"])
        self.assertEqual(42, got["ctx"])
        self.assertEqual("AP-1 build the thing", got["name"])

    def test_watchers_without_ctx(self):
        got = self.parse("⏳ m3 · data docker")
        self.assertEqual("⏳", got["icon"])
        self.assertEqual("data docker", got["name"])

    def test_bare_name(self):
        got = self.parse("session")
        self.assertEqual("", got["icon"])
        self.assertEqual("session", got["name"])

    def test_variation_selector_after_the_icon(self):
        got = self.parse("⏸️ 12% · paused on limits")
        self.assertEqual("⏸", got["icon"])
        self.assertEqual("paused on limits", got["name"])

    def test_a_name_that_merely_starts_with_a_percentage_is_kept(self):
        got = self.parse("▶ 50% быстрее чем было")
        self.assertIsNone(got["ctx"])
        self.assertEqual("50% быстрее чем было", got["name"])

    def test_display_only_state_timer_is_tolerated(self):
        # The keeper renders "✋ 92% 12м · …" to the terminal.  It never reaches
        # the file, but a stray copy must not eat the name.
        got = self.parse("✋ 92% 12м · u-flow всегда")
        self.assertEqual(92, got["ctx"])
        self.assertEqual("u-flow всегда", got["name"])

    def test_dup_marked_name(self):
        got = self.parse("✋ 34% · ! · ⚠AP-12753 integration-adapter moni①")
        self.assertTrue(got["bang"])
        self.assertEqual("⚠AP-12753 integration-adapter moni①", got["name"])

    def test_control_characters_are_stripped(self):
        got = self.parse("▶ 10% · na\x07me\x00")
        self.assertEqual("name", got["name"])

    def test_empty_line(self):
        got = self.parse("")
        self.assertEqual("", got["icon"])
        self.assertEqual("", got["name"])

    def test_icon_only(self):
        got = self.parse("✋")
        self.assertEqual("✋", got["icon"])
        self.assertEqual("", got["name"])

    def test_absurdly_long_name_is_clamped(self):
        got = self.parse("▶ 10% · " + ("x" * 5000))
        self.assertEqual(sessions.MAX_NAME_CHARS, len(got["name"]))


# --------------------------------------------------------------------------
# Meta sidecar
# --------------------------------------------------------------------------

class MetaTests(MachineTestCase):

    def read(self):
        problems = sessions.Problems()
        titles = sessions.read_titles(self.machine.title_dir, problems)
        return titles, problems

    def test_meta_icon_wins_over_the_title(self):
        self.machine.title(SID_A, "Задачи · тех-стори")
        self.machine.meta(SID_A, icon="✋", icon_since=self.now - 600,
                          engine_name="AP-12480 relates redoc")
        titles, problems = self.read()
        self.assertEqual("✋", titles[SID_A].icon)
        # ...without touching the anchored name.
        self.assertEqual("Задачи · тех-стори", titles[SID_A].name)
        self.assertEqual(0, problems.file_errors)

    def test_meta_icon_wins_when_the_two_disagree(self):
        self.machine.title(SID_A, "▶ 30% · work")
        self.machine.meta(SID_A, icon="✅", icon_since=self.now - 60)
        titles, _ = self.read()
        self.assertEqual("✅", titles[SID_A].icon)

    def test_missing_meta_falls_back_to_the_title_icon(self):
        self.machine.title(SID_A, "▶ 30% · work")
        titles, problems = self.read()
        self.assertEqual("▶", titles[SID_A].icon)
        # A missing sidecar is normal, not an error.
        self.assertEqual(0, problems.file_errors)

    def test_meta_icon_since_beats_the_file_mtime(self):
        self.machine.title(SID_A, "✋ 10% · work", mtime=self.now - 5)
        self.machine.meta(SID_A, icon="✋", icon_since=self.now - 7200)
        titles, _ = self.read()
        self.assertAlmostEqual(self.now - 7200, titles[SID_A].state_since, places=3)

    def test_mtime_is_used_when_meta_has_no_icon_since(self):
        self.machine.title(SID_A, "✋ 10% · work", mtime=self.now - 900)
        self.machine.meta(SID_A, icon="✋")
        titles, _ = self.read()
        self.assertAlmostEqual(self.now - 900, titles[SID_A].state_since, places=0)

    def test_corrupt_meta_is_counted_and_the_title_still_parses(self):
        self.machine.title(SID_A, "▶ 30% · work")
        self.machine.raw_meta(SID_A, "{not json")
        with self.expect_stderr("meta %s" % SID_A, "Expecting property name"):
            titles, problems = self.read()
        self.assertEqual("▶", titles[SID_A].icon)
        self.assertEqual(1, problems.file_errors)
        self.assertEqual([], problems.fatal)

    def test_meta_with_a_nonsense_icon_is_ignored(self):
        self.machine.title(SID_A, "▶ 30% · work")
        self.machine.meta(SID_A, icon="Q")
        titles, _ = self.read()
        self.assertEqual("▶", titles[SID_A].icon)

    def test_engine_name_is_the_fallback_when_the_title_has_no_name(self):
        self.machine.title(SID_A, "✋ 92%")
        self.machine.meta(SID_A, icon="✋", engine_name="u-flow всегда")
        titles, _ = self.read()
        self.assertEqual("", titles[SID_A].name)
        self.assertEqual("u-flow всегда", titles[SID_A].engine_name)


# --------------------------------------------------------------------------
# Liveness
# --------------------------------------------------------------------------

class PidTests(unittest.TestCase):

    def test_own_pid_is_alive(self):
        self.assertTrue(sessions.pid_alive(os.getpid()))

    def test_pid_one_is_alive_even_though_it_is_not_ours(self):
        # launchd: kill(1, 0) fails with EPERM, which still proves it exists.
        self.assertTrue(sessions.pid_alive(1))

    def test_nonexistent_pid_is_dead(self):
        self.assertFalse(sessions.pid_alive(DEAD_PID))

    def test_reaped_child_is_dead(self):
        child = subprocess.Popen([sys.executable, "-c", "pass"])
        child.wait()
        self.assertFalse(sessions.pid_alive(child.pid))

    def test_rubbish_pids(self):
        for value in (0, -1, None, "123", True, 1.5):
            self.assertFalse(sessions.pid_alive(value), repr(value))


class LivenessTests(MachineTestCase):

    def test_stale_lease_is_not_live(self):
        # Fresh-looking in every way except the heartbeat, and with a pid that
        # really is alive (our own) — the heartbeat alone must condemn it.
        self.machine.title(SID_A, "✋ 20% · long gone")
        self.machine.lease(SID_A, heartbeat_age=10000, now=self.now)
        card = self.card()
        self.assertEqual("ok", card["state"])
        self.assertIn("No Claude Code sessions running", self.text_of(card))

    def test_lease_just_inside_the_threshold_is_live(self):
        self.machine.title(SID_A, "✋ 20% · here")
        self.machine.lease(SID_A, heartbeat_age=179, now=self.now)
        card = self.card(stale_lease_secs=180)
        self.assertEqual(["needs you", "1", "warn"], self.rows_of(card, "kv")[0])

    def test_stale_threshold_is_a_setting(self):
        self.machine.title(SID_A, "✋ 20% · here")
        self.machine.lease(SID_A, heartbeat_age=400, now=self.now)
        self.assertEqual("idle", self.card(stale_lease_secs=180)["chip"])
        self.assertEqual("1 waiting", self.card(stale_lease_secs=600)["chip"])

    def test_fresh_lease_with_a_dead_pid_is_not_live(self):
        self.machine.title(SID_A, "✋ 20% · shim died")
        self.machine.lease(SID_A, heartbeat_age=1, pid=DEAD_PID, now=self.now)
        self.assertEqual("idle", self.card()["chip"])

    def test_title_file_without_a_process_is_not_live(self):
        # The trap: title files outlive their sessions.  Counting them would
        # inflate every number on the card.
        for sid in (SID_A, SID_B, SID_C):
            self.machine.title(sid, "✋ 50% · ghost")
            self.machine.meta(sid, icon="✋", icon_since=self.now - 60)
        card = self.card()
        self.assertEqual("ok", card["state"])
        self.assertEqual("idle", card["chip"])
        self.assertIn("No Claude Code sessions running", self.text_of(card))

    def test_a_resume_process_makes_a_leaseless_session_live(self):
        self.machine.title(SID_A, "✋ 50% · restored tab")
        self.machine.meta(SID_A, icon="✋", icon_since=self.now - 60)
        card = self.card(ps=FakePs(commands=claude_line(SID_A, "ttys004")))
        self.assertEqual("1 waiting", card["chip"])

    def test_a_keeper_on_a_live_tty_counts(self):
        self.machine.title(SID_A, "▶ 50% · fresh session")
        ps = FakePs(
            commands="\n".join([keeper_line(SID_A, "ttys007"), "claude"]),
            tty="\n".join(["ttys007  claude", keeper_line(SID_A, "ttys007")]),
        )
        card = self.card(ps=ps)
        self.assertEqual(["live", "1"], self.rows_of(card, "kv")[1])
        # The keeper was the only evidence, so the tty listing had to be read.
        self.assertEqual(["command=", "tty=,command="], ps.calls)

    def test_a_keeper_that_outlived_its_tty_does_not_count(self):
        self.machine.title(SID_A, "▶ 50% · killed tab")
        ps = FakePs(
            commands=keeper_line(SID_A, "ttys007"),
            tty="ttys009  claude\n" + keeper_line(SID_A, "ttys007"),
        )
        self.assertEqual("idle", self.card(ps=ps)["chip"])

    def test_the_keepers_own_line_does_not_prove_its_tty(self):
        # The keeper writes to /dev/ttys007 and says so; that must not be read
        # back as "a claude process lives on ttys007".
        self.machine.title(SID_A, "▶ 50% · killed tab")
        ps = FakePs(
            commands=keeper_line(SID_A, "ttys007"),
            tty="ttys007  " + keeper_line(SID_A, "ttys007"),
        )
        self.assertEqual("idle", self.card(ps=ps)["chip"])

    def test_the_tty_listing_is_skipped_when_every_keeper_is_already_proven(self):
        # ps -axo tty= costs ~77 ms more than the plain listing; it is only
        # worth paying when a keeper is the sole evidence for a session.
        self.machine.title(SID_A, "▶ 50% · leased")
        self.machine.lease(SID_A, heartbeat_age=1, now=self.now)
        ps = FakePs(commands=keeper_line(SID_A, "ttys007"))
        self.card(ps=ps)
        self.assertEqual(["command="], ps.calls)

    def test_ps_failure_leaves_the_lease_counts_intact(self):
        self.machine.title(SID_A, "✋ 20% · leased")
        self.machine.lease(SID_A, heartbeat_age=1, now=self.now)
        with self.expect_stderr("ps failed", "ps: no such file"):
            card = self.card(ps=FailingPs(OSError("ps: no such file")))
        self.assertEqual("1 waiting", card["chip"])
        self.assertIn("ps unavailable", self.text_of(card))

    def test_a_lease_with_no_heartbeat_falls_back_to_the_pid(self):
        self.machine.raw_lease(SID_A, json.dumps(
            {"account_label": "pers", "cwd": "/w/u-pilot", "pid": os.getpid()}))
        self.machine.title(SID_A, "✋ 20% · no heartbeat")
        self.assertEqual("1 waiting", self.card()["chip"])

        self.machine.raw_lease(SID_B, json.dumps(
            {"account_label": "pers", "cwd": "/w/u-pilot", "pid": DEAD_PID}))
        self.machine.title(SID_B, "✋ 20% · no heartbeat, dead pid")
        self.assertEqual("1 waiting", self.card()["chip"])


class PsScanTests(unittest.TestCase):

    def test_resume_uuids_are_found(self):
        text = "\n".join([
            "claude --resume %s" % SID_A,
            "/Users/x/.local/bin/claude --resume %s" % SID_B,
            "grep --resume not-a-uuid",
        ])
        resume, keepers = sessions.scan_commands(text)
        self.assertEqual({SID_A, SID_B}, resume)
        self.assertEqual({}, keepers)

    def test_keeper_lines_are_not_mistaken_for_resume_lines(self):
        resume, keepers = sessions.scan_commands(keeper_line(SID_A, "ttys003"))
        self.assertEqual(set(), resume)
        self.assertEqual({SID_A: "ttys003"}, keepers)

    def test_claude_ttys_exclude_keepers(self):
        text = "\n".join([
            "ttys001  claude --resume %s" % SID_A,
            "ttys002  " + keeper_line(SID_B, "ttys002"),
            "ttys003  -zsh",
            "??       some-daemon claude-ish",
        ])
        self.assertEqual({"ttys001"}, sessions.scan_claude_ttys(text))


# --------------------------------------------------------------------------
# Card composition
# --------------------------------------------------------------------------

class CardTests(MachineTestCase):

    def populate(self):
        """One session per interesting state, all genuinely live."""
        fixtures = [
            (SID_A, "✋ 54% · ! · m2 · u-flow всегда", "✋", 3600, "u-flow-workspace", "pers"),
            (SID_B, "▶ 30% · AP-11112 прогон", "▶", 120, "proctor-cyber-workspaces", "work2"),
            (SID_C, "⏳ 24% · data docker", "⏳", 900, "u-pilot", "pers"),
            (SID_D, "✅ 21% · AP-12221 done", "✅", 60, "u-pilot", "work"),
        ]
        for sid, line, icon, age, project, account in fixtures:
            self.machine.title(sid, line)
            self.machine.meta(sid, icon=icon, icon_since=self.now - age)
            self.machine.lease(sid, account=account, cwd="/Users/x/Workspace/" + project,
                               heartbeat_age=1, now=self.now)

    def test_zero_sessions_is_a_calm_ok(self):
        card = self.card()
        self.assertEqual("ok", card["state"])
        self.assertEqual("idle", card["chip"])
        self.assertIn("No Claude Code sessions running", self.text_of(card))
        # An idle machine is not an error and must not hide behind "unknown".
        self.assertNotIn(card["state"], ("crit", "unknown"))

    def test_no_action_is_offered_when_nothing_is_running(self):
        self.assertNotIn("actions", self.card())

    def test_waiting_drives_the_state_and_the_chip(self):
        self.populate()
        card = self.card()
        self.assertEqual("warn", card["state"])
        self.assertEqual("1 waiting", card["chip"])
        self.assertEqual(["needs you", "1", "warn"], self.rows_of(card, "kv")[0])
        self.assertEqual(["live", "4"], self.rows_of(card, "kv")[1])

    def test_nothing_waiting_stays_ok_and_calm(self):
        self.machine.title(SID_B, "▶ 30% · working away")
        self.machine.meta(SID_B, icon="▶", icon_since=self.now - 30)
        self.machine.lease(SID_B, heartbeat_age=1, now=self.now)
        card = self.card()
        self.assertEqual("ok", card["state"])
        self.assertEqual("all quiet", card["chip"])
        self.assertEqual(["needs you", "0", "ok"], self.rows_of(card, "kv")[0])

    def test_the_breakdown_line_omits_empty_buckets(self):
        self.populate()
        text = self.text_of(self.card())
        self.assertIn("1 running", text)
        self.assertIn("1 on external", text)
        self.assertIn("1 done", text)
        self.assertNotIn("paused", text)
        self.assertNotIn("0 ", text)

    def test_the_bang_badge_alone_means_waiting(self):
        # "!" is the notification badge; it outranks the icon.
        self.machine.title(SID_A, "▶ 30% · ! · needs a decision")
        self.machine.meta(SID_A, icon="▶", icon_since=self.now - 30)
        self.machine.lease(SID_A, heartbeat_age=1, now=self.now)
        card = self.card()
        self.assertEqual("warn", card["state"])
        self.assertEqual("1 waiting", card["chip"])

    def test_waiting_sessions_lead_the_list_longest_first(self):
        self.populate()
        # A second, more recent waiter must still rank below the older one.
        self.machine.title(SID_D, "✋ 21% · newer waiter")
        self.machine.meta(SID_D, icon="✋", icon_since=self.now - 30)
        items = self.rows_of(self.card(), "list")[0]
        self.assertEqual(["u-flow всегда", "newer waiter"],
                         [item["text"] for item in items[:2]])
        self.assertEqual(["warn", "warn"], [item["icon"] for item in items[:2]])
        # ...and the rest follow behind them.
        self.assertEqual({"wait", "run"}, set(item["icon"] for item in items[2:]))

    def test_the_note_carries_the_project_and_the_age(self):
        self.populate()
        items = self.rows_of(self.card(), "list")[0]
        self.assertEqual("u-flow-workspace · 1h", items[0]["note"])

    def test_the_note_can_show_the_account_instead(self):
        self.populate()
        items = self.rows_of(self.card(note_source="account"), "list")[0]
        self.assertEqual("pers · 1h", items[0]["note"])

    def test_the_note_can_show_both(self):
        self.populate()
        items = self.rows_of(self.card(note_source="both"), "list")[0]
        self.assertEqual("pers", items[0]["note"].split(" · ")[1])

    def test_progress_appears_in_the_note(self):
        self.machine.title(SID_A, "▶ 3/7 · 30% · AP-1 stepping")
        self.machine.meta(SID_A, icon="▶", icon_since=self.now - 60)
        self.machine.lease(SID_A, heartbeat_age=1, now=self.now)
        items = self.rows_of(self.card(), "list")[0]
        self.assertIn("3/7", items[0]["note"])

    def test_waiting_only_filters_the_list_but_not_the_counts(self):
        self.populate()
        card = self.card(waiting_only=True)
        items = self.rows_of(card, "list")[0]
        self.assertEqual(1, len(items))
        self.assertEqual(["live", "4"], self.rows_of(card, "kv")[1])

    def test_waiting_only_says_so_when_nothing_waits(self):
        self.machine.title(SID_B, "▶ 30% · working away")
        self.machine.meta(SID_B, icon="▶", icon_since=self.now - 30)
        self.machine.lease(SID_B, heartbeat_age=1, now=self.now)
        card = self.card(waiting_only=True)
        self.assertEqual([], self.rows_of(card, "list"))
        self.assertIn("Nothing is waiting for you", self.text_of(card))

    def test_list_rows_limits_and_reports_the_remainder(self):
        self.populate()
        card = self.card(list_rows=2)
        self.assertEqual(2, len(self.rows_of(card, "list")[0]))
        self.assertIn("+2 more", self.text_of(card))

    def test_list_rows_zero_omits_the_list_entirely(self):
        self.populate()
        card = self.card(list_rows=0)
        self.assertEqual([], self.rows_of(card, "list"))
        self.assertEqual(["live", "4"], self.rows_of(card, "kv")[1])

    def test_a_leaseless_session_is_named_and_kept(self):
        self.machine.title(SID_A, "✋ 50% · Личное · цвета табов Warp")
        self.machine.meta(SID_A, icon="✋", icon_since=self.now - 120)
        items = self.rows_of(
            self.card(ps=FakePs(commands=claude_line(SID_A, "ttys004"))), "list")[0]
        self.assertEqual("Личное · цвета табов Warp", items[0]["text"])
        self.assertEqual("2m", items[0]["note"])  # no lease, so no project

    def test_a_statusless_session_still_counts(self):
        ps = FakePs(commands=claude_line(SID_A, "ttys004"))
        card = self.card(ps=ps)
        self.assertEqual(["live", "1"], self.rows_of(card, "kv")[1])
        self.assertIn("1 no status", self.text_of(card))
        self.assertEqual("all quiet", card["chip"])

    def test_statusless_sessions_can_be_excluded(self):
        self.machine.title(SID_B, "▶ 30% · working")
        self.machine.meta(SID_B, icon="▶", icon_since=self.now - 30)
        self.machine.lease(SID_B, heartbeat_age=1, now=self.now)
        ps = FakePs(commands=claude_line(SID_A, "ttys004"))
        card = self.card(ps=ps, include_unknown=False)
        self.assertEqual(["live", "1"], self.rows_of(card, "kv")[1])
        self.assertNotIn("no status", self.text_of(card))

    def test_excluding_every_session_does_not_claim_the_machine_is_idle(self):
        ps = FakePs(commands=claude_line(SID_A, "ttys004"))
        card = self.card(ps=ps, include_unknown=False)
        self.assertEqual("ok", card["state"])
        self.assertEqual("no status", card["chip"])
        self.assertIn("No session is reporting a status", self.text_of(card))
        self.assertIn("1 live, not counted", self.text_of(card))

    def test_a_leased_session_with_no_title_is_named_after_its_project(self):
        self.machine.lease(SID_A, cwd="/Users/x/Workspace/u-pilot",
                           heartbeat_age=1, now=self.now)
        items = self.rows_of(self.card(), "list")[0]
        self.assertEqual("u-pilot", items[0]["text"])
        self.assertEqual("dot", items[0]["icon"])

    def test_the_account_breakdown_is_opt_in(self):
        self.populate()
        self.assertNotIn("pers 2", self.text_of(self.card()))
        self.assertIn("pers 2", self.text_of(self.card(show_accounts=True)))

    def test_the_account_breakdown_puts_the_nameless_ones_last(self):
        self.populate()
        ps = FakePs(commands=claude_line(SID_A.replace("a", "e"), "ttys004"))
        line = [text for text in self.rows_of(self.card(ps=ps, show_accounts=True),
                                              "text") if " 1" in text or " 2" in text]
        self.assertEqual("pers 2 · work 1 · work2 1 · ? 1", line[-1])

    def test_the_focus_action_follows_its_setting(self):
        self.populate()
        card = self.card()
        self.assertEqual([{"label": "Focus Warp", "run": ["open", "-a", "Warp"]}],
                         card["actions"])
        self.assertEqual([{"label": "Focus iTerm", "run": ["open", "-a", "iTerm"]}],
                         self.card(focus_app="iTerm")["actions"])
        self.assertNotIn("actions", self.card(focus_app="   "))

    def test_ttl_is_present_and_outlives_the_poll_interval(self):
        card = self.card()
        interval = read_manifest()["interval"]
        self.assertGreater(card["ttl"], interval)


class HumanAgeTests(unittest.TestCase):

    def test_scales(self):
        self.assertEqual("0s", sessions.human_age(0))
        self.assertEqual("59s", sessions.human_age(59.9))
        self.assertEqual("1m", sessions.human_age(60))
        self.assertEqual("59m", sessions.human_age(3599))
        self.assertEqual("1h", sessions.human_age(3600))
        self.assertEqual("1h1m", sessions.human_age(3660))
        self.assertEqual("1d", sessions.human_age(86400))
        self.assertEqual("1d17h", sessions.human_age(86400 + 17 * 3600))

    def test_unknown_and_negative(self):
        self.assertEqual("", sessions.human_age(None))
        self.assertEqual("", sessions.human_age(-5))


# --------------------------------------------------------------------------
# Failure handling
# --------------------------------------------------------------------------

class SourceFailureTests(MachineTestCase):

    def test_an_unreadable_title_directory_is_unknown_with_a_reason(self):
        blocker = os.path.join(self.machine.root, "not-a-directory")
        with open(blocker, "w") as handle:
            handle.write("")
        settings = self.machine.settings(title_dir=blocker)
        card = sessions.gather(settings, self.now, ps_reader=FakePs())
        self.assertEqual([], validate_card(card))
        self.assertEqual("unknown", card["state"])
        self.assertIn(blocker, self.text_of(card))
        self.assertIn("cannot list", self.text_of(card))

    def test_an_unreadable_lease_directory_is_unknown_with_a_reason(self):
        blocker = os.path.join(self.machine.root, "also-not-a-directory")
        with open(blocker, "w") as handle:
            handle.write("")
        settings = self.machine.settings(leases_dir=blocker)
        card = sessions.gather(settings, self.now, ps_reader=FakePs())
        self.assertEqual("unknown", card["state"])
        self.assertIn(blocker, self.text_of(card))

    @unittest.skipIf(os.geteuid() == 0, "root ignores directory permissions")
    def test_a_permission_denied_directory_is_unknown(self):
        walled = os.path.join(self.machine.root, "walled")
        os.makedirs(walled)
        os.chmod(walled, 0o000)
        self.addCleanup(os.chmod, walled, 0o755)
        settings = self.machine.settings(leases_dir=walled)
        card = sessions.gather(settings, self.now, ps_reader=FakePs())
        self.assertEqual("unknown", card["state"])
        self.assertIn("Permission denied", self.text_of(card))

    def test_an_unknown_card_hides_the_counts(self):
        self.machine.title(SID_A, "✋ 20% · here")
        self.machine.lease(SID_A, heartbeat_age=1, now=self.now)
        blocker = os.path.join(self.machine.root, "blocker")
        with open(blocker, "w") as handle:
            handle.write("")
        settings = self.machine.settings(title_dir=blocker)
        card = sessions.gather(settings, self.now, ps_reader=FakePs())
        self.assertEqual([], self.rows_of(card, "kv"))
        self.assertEqual([], self.rows_of(card, "list"))

    def test_both_directories_missing_is_unknown_not_idle(self):
        settings = self.machine.settings(
            title_dir=os.path.join(self.machine.root, "gone-a"),
            leases_dir=os.path.join(self.machine.root, "gone-b"),
        )
        card = sessions.gather(settings, self.now, ps_reader=FakePs())
        self.assertEqual("unknown", card["state"])
        self.assertIn("neither the title directory nor the lease registry",
                      self.text_of(card))

    def test_one_missing_directory_still_produces_counts(self):
        # claude-monitor simply not installed: titles plus ps are still enough.
        self.machine.title(SID_A, "✋ 20% · here")
        self.machine.meta(SID_A, icon="✋", icon_since=self.now - 60)
        settings = self.machine.settings(
            leases_dir=os.path.join(self.machine.root, "gone"))
        card = sessions.gather(settings, self.now,
                               ps_reader=FakePs(commands=claude_line(SID_A, "ttys004")))
        self.assertEqual([], validate_card(card))
        self.assertEqual("warn", card["state"])
        self.assertEqual("1 waiting", card["chip"])
        self.assertIn("no lease registry", self.text_of(card))

    def test_one_unreadable_file_out_of_many_does_not_poison_the_card(self):
        for sid in (SID_A, SID_B, SID_C):
            self.machine.title(sid, "✋ 20% · fine")
            self.machine.meta(sid, icon="✋", icon_since=self.now - 60)
            self.machine.lease(sid, heartbeat_age=1, now=self.now)
        self.machine.raw_lease(SID_D, "{ broken json")
        self.machine.title(SID_D, "✋ 20% · broken lease")

        with self.expect_stderr("lease %s" % SID_D):
            card = self.card()
        self.assertEqual("warn", card["state"])
        self.assertEqual("3 waiting", card["chip"])
        self.assertIn(["unreadable files", "1", "warn"], self.rows_of(card, "kv"))

    def test_a_lease_holding_a_json_array_is_a_file_error(self):
        self.machine.raw_lease(SID_A, "[1, 2, 3]")
        problems = sessions.Problems()
        with self.expect_stderr("expected an object, got list"):
            leases = sessions.read_leases(self.machine.leases_dir, problems)
        self.assertEqual({}, leases)
        self.assertEqual(1, problems.file_errors)
        self.assertEqual([], problems.fatal)

    def test_a_lease_with_wrongly_typed_fields_degrades_field_by_field(self):
        self.machine.raw_lease(SID_A, json.dumps({
            "account_label": 7, "cwd": None, "pid": "61442",
            "heartbeat_ts": "now", "started_ts": 1.0,
        }))
        problems = sessions.Problems()
        leases = sessions.read_leases(self.machine.leases_dir, problems)
        self.assertEqual(0, problems.file_errors)
        lease = leases[SID_A]
        self.assertEqual("", lease.account)
        self.assertEqual("", lease.cwd)
        self.assertIsNone(lease.pid)
        self.assertIsNone(lease.heartbeat_ts)

    def test_a_title_file_that_is_a_directory_is_a_file_error(self):
        os.makedirs(os.path.join(self.machine.title_dir,
                                 "claude-tab-title-%s.txt" % SID_A))
        problems = sessions.Problems()
        with self.expect_stderr("Is a directory"):
            titles = sessions.read_titles(self.machine.title_dir, problems)
        self.assertEqual({}, titles)
        self.assertEqual(1, problems.file_errors)
        self.assertEqual([], problems.fatal)


# --------------------------------------------------------------------------
# Settings
# --------------------------------------------------------------------------

class SettingsTests(unittest.TestCase):

    def test_defaults_when_the_environment_is_empty(self):
        got = sessions.load_settings(env={})
        self.assertEqual(False, got["waiting_only"])
        self.assertEqual(6, got["list_rows"])
        self.assertEqual(180, got["stale_lease_secs"])
        self.assertEqual("project", got["note_source"])
        self.assertEqual(True, got["include_unknown"])
        self.assertEqual("/tmp", got["title_dir"])

    def test_json_values_are_parsed(self):
        got = sessions.load_settings(env={
            "UDECK_SETTING_WAITING_ONLY": "true",
            "UDECK_SETTING_LIST_ROWS": "12",
            "UDECK_SETTING_STALE_LEASE_SECS": "300",
            "UDECK_SETTING_NOTE_SOURCE": '"account"',
            "UDECK_SETTING_INCLUDE_UNKNOWN": "false",
            "UDECK_SETTING_TITLE_DIR": '"/private/tmp"',
        })
        self.assertEqual(True, got["waiting_only"])
        self.assertEqual(12, got["list_rows"])
        self.assertEqual(300, got["stale_lease_secs"])
        self.assertEqual("account", got["note_source"])
        self.assertEqual(False, got["include_unknown"])
        self.assertEqual("/private/tmp", got["title_dir"])

    def test_garbage_falls_back_to_the_default_and_warns(self):
        warnings = []
        got = sessions.load_settings(
            env={"UDECK_SETTING_LIST_ROWS": "not json at all"},
            warn=warnings.append)
        self.assertEqual(6, got["list_rows"])
        self.assertEqual(1, len(warnings))
        self.assertIn("list_rows", warnings[0])

    def test_a_wrongly_typed_value_falls_back(self):
        warnings = []
        got = sessions.load_settings(env={
            "UDECK_SETTING_LIST_ROWS": '"twelve"',
            "UDECK_SETTING_WAITING_ONLY": "1",
            "UDECK_SETTING_TITLE_DIR": "42",
        }, warn=warnings.append)
        self.assertEqual(6, got["list_rows"])
        self.assertEqual(False, got["waiting_only"])
        self.assertEqual("/tmp", got["title_dir"])
        self.assertEqual(3, len(warnings))

    def test_a_bool_is_not_accepted_as_an_int(self):
        got = sessions.load_settings(env={"UDECK_SETTING_LIST_ROWS": "true"})
        self.assertEqual(6, got["list_rows"])

    def test_ints_are_clamped_to_the_manifest_range(self):
        warnings = []
        got = sessions.load_settings(env={
            "UDECK_SETTING_LIST_ROWS": "9999",
            "UDECK_SETTING_STALE_LEASE_SECS": "-5",
        }, warn=warnings.append)
        self.assertEqual(40, got["list_rows"])
        self.assertEqual(30, got["stale_lease_secs"])
        self.assertEqual(2, len(warnings))

    def test_a_bare_string_is_accepted_for_string_settings(self):
        # A host that forwards the raw value rather than a JSON string.
        got = sessions.load_settings(env={"UDECK_SETTING_FOCUS_APP": "Ghostty"})
        self.assertEqual("Ghostty", got["focus_app"])

    def test_an_unknown_enum_member_falls_back(self):
        warnings = []
        got = sessions.load_settings(
            env={"UDECK_SETTING_NOTE_SOURCE": '"branch"'}, warn=warnings.append)
        self.assertEqual("project", got["note_source"])
        self.assertIn("note_source", warnings[0])

    def test_an_empty_value_is_honoured_for_strings(self):
        got = sessions.load_settings(env={"UDECK_SETTING_FOCUS_APP": '""'})
        self.assertEqual("", got["focus_app"])

    def test_the_specs_agree_with_the_manifest(self):
        manifest = read_manifest()
        declared = {entry["key"]: entry for entry in manifest["settings"]}
        specs = {key: (kind, default, lo, hi)
                 for key, kind, default, lo, hi in sessions.SETTING_SPECS}
        self.assertEqual(sorted(declared), sorted(specs),
                         "manifest settings and SETTING_SPECS have drifted")
        for key, entry in declared.items():
            kind, default, lo, hi = specs[key]
            self.assertEqual(entry["type"], kind, key)
            self.assertEqual(entry["default"], default, key)
            for field in ("label", "help"):
                self.assertTrue(entry.get(field), "%s is missing a %s" % (key, field))
            if kind == "int":
                self.assertEqual(entry["min"], lo, key)
                self.assertEqual(entry["max"], hi, key)
                self.assertLessEqual(lo, default)
                self.assertLessEqual(default, hi)
            if kind == "enum":
                self.assertEqual([option["value"] for option in entry["options"]],
                                 list(hi), key)
                self.assertIn(default, hi, key)


class ManifestTests(unittest.TestCase):

    def test_the_manifest_is_well_formed(self):
        manifest = read_manifest()
        self.assertEqual("claude-sessions", manifest["id"])
        self.assertEqual(1, manifest["api"])
        self.assertEqual("poll", manifest["kind"])
        self.assertEqual(["./sessions.py"], manifest["run"])
        self.assertGreater(manifest["interval"], 0)
        self.assertGreater(manifest["timeout"], 0)
        window = manifest["window"]
        self.assertLessEqual(window["minWidth"], window["defaultWidth"])
        self.assertLessEqual(window["minHeight"], window["defaultHeight"])
        self.assertLessEqual(window["defaultWidth"], 12)

    def test_the_declared_permissions_cover_what_the_script_uses(self):
        manifest = read_manifest()
        self.assertIn("ps", manifest["permissions"]["exec"])
        self.assertIn("open", manifest["permissions"]["exec"])
        reads = manifest["permissions"]["read"]
        self.assertTrue(any(sessions.TITLE_PREFIX in path for path in reads))
        self.assertTrue(any("leases" in path for path in reads))

    def test_the_script_is_executable(self):
        self.assertTrue(os.access(SCRIPT, os.X_OK), "sessions.py is not executable")


# --------------------------------------------------------------------------
# The script as the host runs it
# --------------------------------------------------------------------------

class EndToEndTests(MachineTestCase):

    def run_script(self, **env_overrides):
        env = dict(os.environ)
        env.update({
            "UDECK_API": "1",
            "UDECK_APPEARANCE": "dark",
            "UDECK_REFRESH_REASON": "interval",
            "UDECK_PLUGIN_DIR": HERE,
            "UDECK_CACHE_DIR": self.machine.root,
            "UDECK_SETTING_TITLE_DIR": json.dumps(self.machine.title_dir),
            "UDECK_SETTING_LEASES_DIR": json.dumps(self.machine.leases_dir),
            # The real machine's `ps` is visible to a subprocess.  Its sessions
            # have no title or lease inside this tmpdir, so they all land in the
            # "no status" bucket; dropping that bucket makes these assertions
            # independent of how busy the machine happens to be.
            "UDECK_SETTING_INCLUDE_UNKNOWN": "false",
        })
        env.update(env_overrides)
        return subprocess.run(
            [sys.executable, SCRIPT], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            encoding="utf-8", env=env, timeout=30, check=False)

    def test_stdout_is_exactly_one_json_object(self):
        self.machine.title(SID_A, "✋ 54% · ! · m2 · u-flow всегда")
        self.machine.meta(SID_A, icon="✋", icon_since=self.now - 3600)
        self.machine.lease(SID_A, heartbeat_age=1, now=self.now)

        result = self.run_script()
        self.assertEqual(0, result.returncode, result.stderr)
        card = json.loads(result.stdout)          # one object, nothing around it
        self.assertIsInstance(card, dict)
        self.assertEqual([], validate_card(card))
        self.assertEqual(1, result.stdout.count("{\"state\""))

    def test_non_ascii_names_survive_the_round_trip(self):
        self.machine.title(SID_A, "✋ 54% · Задачи · тех-стори")
        self.machine.meta(SID_A, icon="✋", icon_since=self.now - 60)
        self.machine.lease(SID_A, heartbeat_age=1, now=self.now)
        card = json.loads(self.run_script().stdout)
        listed = [row["list"] for row in card["rows"] if "list" in row]
        self.assertEqual([["Задачи · тех-стори"]],
                         [[item["text"] for item in items] for items in listed])

    def test_diagnostics_go_to_stderr_only(self):
        result = self.run_script(UDECK_SETTING_LIST_ROWS="rubbish")
        self.assertIn("list_rows", result.stderr)
        json.loads(result.stdout)  # stdout stayed clean

    def test_a_broken_source_still_prints_a_valid_card_and_exits_zero(self):
        blocker = os.path.join(self.machine.root, "blocker")
        with open(blocker, "w") as handle:
            handle.write("")
        result = self.run_script(UDECK_SETTING_TITLE_DIR=json.dumps(blocker))
        self.assertEqual(0, result.returncode, result.stderr)
        card = json.loads(result.stdout)
        self.assertEqual("unknown", card["state"])
        self.assertEqual([], validate_card(card))

    def test_it_finishes_well_inside_the_declared_timeout(self):
        self.machine.title(SID_A, "✋ 54% · u-flow всегда")
        self.machine.lease(SID_A, heartbeat_age=1, now=self.now)
        budget = read_manifest()["timeout"]
        started = time.time()
        result = self.run_script()
        elapsed = time.time() - started
        self.assertEqual(0, result.returncode, result.stderr)
        # Generous: this includes interpreter start-up and a real `ps`.
        self.assertLess(elapsed, budget,
                        "took %.2fs of a %ss budget" % (elapsed, budget))


if __name__ == "__main__":
    unittest.main()
