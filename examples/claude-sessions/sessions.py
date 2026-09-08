#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""uDeck poll plugin: how many Claude Code sessions are alive, and how many
of them are waiting for the operator right now.

Three local sources, all cheap, none of them sufficient on its own:

1. ``<title_dir>/claude-tab-title-<SID>.txt`` — the terminal tab status line
   written by the ``terminal-status`` skill.  Shape::

       <icon> [N/M ·] [ctx% ·] [extras ·] <name>

   The leading icon is optional: an anchored name such as ``Задачи · тех-стори``
   has no icon at all, and its name legitimately contains the ``·`` separator.
   The parser therefore consumes *known* prefix segments from the left and
   keeps everything after the first unrecognised segment as the name, instead
   of splitting on ``·`` and taking the last field.

2. ``<title_dir>/claude-tab-title-<SID>.meta`` — JSON sidecar with the
   authoritative ``icon`` plus ``icon_since`` (when the session entered its
   current state).  The meta icon wins over the title's first character: the
   title may carry an anchored name with the icon stripped, while the meta is
   always rewritten by the status engine.

3. ``<leases_dir>/<SID>.json`` — the claude-monitor lease registry:
   ``{account_label, config_dir, cwd, heartbeat_ts, pid, started_ts}``.  One
   file per session that has run its SessionStart hook.  This is the only
   source of the account label and the working directory.

None of the three proves liveness by itself, so liveness is decided as:

* a lease counts when its ``heartbeat_ts`` is younger than the stale threshold
  *and* its pid still exists — the shim rewrites the heartbeat every 60 s, so
  a frozen heartbeat is a dead session;
* a session also counts when ``ps`` shows a ``claude --resume <SID>`` process,
  which is how a restored tab looks before its SessionStart hook has run;
* a session also counts when its tab-title keeper is running *and* the tty that
  keeper writes to still hosts a claude process — a keeper can outlive the
  session whose tab was killed rather than closed;
* a title file on its own proves nothing.  Title files survive crashes, and
  counting them would silently inflate every number on this card.

Output: exactly one JSON object on stdout.  Everything else goes to stderr.
Target runtime: macOS system python3 (3.9) and newer, standard library only.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import time
import traceback
from dataclasses import dataclass

# --------------------------------------------------------------------------
# Sanity clamps.  These are deliberately *not* settings: they exist so that a
# pathological file or directory cannot make a plugin that runs every 5 seconds
# block or balloon.  They are far above any real-world value on this machine
# (24 title files, ~200 bytes each, 17 leases of ~200 bytes).
# --------------------------------------------------------------------------
MAX_TITLE_FILES = 500          # newest-first; anything beyond is reported, not read
MAX_TITLE_BYTES = 4096         # a status line is < 200 bytes
MAX_META_BYTES = 16384         # a meta sidecar is < 200 bytes
MAX_LEASE_FILES = 500
MAX_LEASE_BYTES = 65536
MAX_NAME_CHARS = 120           # clamp, not a display choice: the host truncates
# How long the card stays trustworthy.  Four poll intervals: a couple of
# missed ticks must not grey a card that is in fact current, but a wedged
# plugin must stop looking like a healthy one within about a minute.
CARD_TTL_SECS = 20
PS_TIMEOUT_SECS = 2.0          # bounds one external call; see note in read_ps()

TITLE_PREFIX = "claude-tab-title-"
TITLE_SUFFIX = ".txt"
META_SUFFIX = ".meta"
SEPARATOR = " · "         # " · " — the segment separator the engine writes

# Status-line icons, per ~/.claude/skills/terminal-status/SKILL.md.
ICON_WORKING = "▶"        # ▶  working
ICON_EXTERNAL = "⏳"       # ⏳ waiting on something external
ICON_USER = "✋"           # ✋ waiting for the user
ICON_DONE = "✅"           # ✅ done-idle
ICON_PAUSED = "⏸"         # ⏸  paused (usage limits)
ICON_COMPACTING = "\U0001f504"  # 🔄 compacting
ICON_IDLE = "\U0001f4a4"       # 💤 display-only idle marker
ICON_CHARS = (
    ICON_WORKING + ICON_EXTERNAL + ICON_USER + ICON_DONE
    + ICON_PAUSED + ICON_COMPACTING + ICON_IDLE
)
VARIATION_SELECTOR_16 = "️"

# Bucket keys, in the order they are listed and ranked.  "waiting" and "paused"
# lead because both mean the session cannot progress without the operator.
BUCKET_WAITING = "waiting"
BUCKET_PAUSED = "paused"
BUCKET_EXTERNAL = "external"
BUCKET_RUNNING = "running"
BUCKET_DONE = "done"
BUCKET_IDLE = "idle"
BUCKET_NOSTATUS = "nostatus"

BUCKET_ORDER = [
    BUCKET_WAITING, BUCKET_PAUSED, BUCKET_EXTERNAL,
    BUCKET_RUNNING, BUCKET_DONE, BUCKET_IDLE, BUCKET_NOSTATUS,
]
BUCKET_RANK = {name: i for i, name in enumerate(BUCKET_ORDER)}

# Labels used in the compact breakdown line.
BUCKET_LABEL = {
    BUCKET_WAITING: "needs you",
    BUCKET_PAUSED: "paused",
    BUCKET_EXTERNAL: "on external",
    BUCKET_RUNNING: "running",
    BUCKET_DONE: "done",
    BUCKET_IDLE: "idle",
    BUCKET_NOSTATUS: "no status",
}

# Row icon per bucket, from the closed uDeck vocabulary
# (ok warn crit wait run idle done pause info dot).
BUCKET_ICON = {
    BUCKET_WAITING: "warn",
    BUCKET_PAUSED: "pause",
    BUCKET_EXTERNAL: "wait",
    BUCKET_RUNNING: "run",
    BUCKET_DONE: "done",
    BUCKET_IDLE: "idle",
    BUCKET_NOSTATUS: "dot",
}

ICON_TO_BUCKET = {
    ICON_WORKING: BUCKET_RUNNING,
    ICON_COMPACTING: BUCKET_RUNNING,
    ICON_EXTERNAL: BUCKET_EXTERNAL,
    ICON_USER: BUCKET_WAITING,
    ICON_DONE: BUCKET_DONE,
    ICON_PAUSED: BUCKET_PAUSED,
    ICON_IDLE: BUCKET_IDLE,
}

# Title segments the parser recognises as prefix metadata rather than name.
RE_PROGRESS = re.compile(r"^\d{1,3}/\d{1,3}$")
# The keeper appends a display-only state timer to the first segment
# ("92% 12м").  It never reaches the file, but tolerating it costs nothing.
RE_CTX = re.compile(r"^(\d{1,3})%(?:\s+\d+\S*)?$")
RE_WATCHERS = re.compile(r"^m\d+$")
RE_RESUME = re.compile(r"--resume\s+([0-9a-f-]{36})")
RE_KEEPER = re.compile(r"claude-tab-title-([0-9a-f-]{36})")
RE_KEEPER_TTY = re.compile(r"/dev/(ttys\d+)")
RE_CONTROL = re.compile(r"[\x00-\x1f\x7f]")


# --------------------------------------------------------------------------
# Settings
# --------------------------------------------------------------------------

# Mirrors manifest.json.  Kept here as the single runtime source of truth so a
# missing or malformed environment variable falls back to the documented
# default instead of crashing.  Order is the manifest order.
SETTING_SPECS = (
    ("waiting_only", "bool", False, None, None),
    ("list_rows", "int", 6, 0, 40),
    ("stale_lease_secs", "int", 180, 30, 3600),
    ("note_source", "enum", "project", None, ("project", "account", "both")),
    ("include_unknown", "bool", True, None, None),
    ("show_accounts", "bool", False, None, None),
    ("leases_dir", "string", "~/.claude/skills/claude-monitor/runtime/leases", None, None),
    ("title_dir", "string", "/tmp", None, None),
    ("focus_app", "string", "Warp", None, None),
)


def load_settings(env=None, warn=None):
    """Read UDECK_SETTING_* out of the environment into a plain dict.

    Every value arrives JSON-serialised.  A missing variable, a value that is
    not JSON, a value of the wrong type, an out-of-range int or an unknown enum
    member all fall back to the manifest default and are reported through
    ``warn`` — never raised.
    """
    if env is None:
        env = os.environ
    if warn is None:
        def warn(_message):
            return None

    out = {}
    for key, kind, default, lo, hi in SETTING_SPECS:
        out[key] = default
        raw = env.get("UDECK_SETTING_" + key.upper())
        if raw is None:
            continue

        try:
            value = json.loads(raw)
        except (ValueError, TypeError):
            # A host that forwards a bare string rather than a JSON string is
            # still unambiguous for string/enum settings; anything else is not.
            if kind in ("string", "enum"):
                value = raw
            else:
                warn("setting %s: %r is not JSON, using default %r" % (key, raw, default))
                continue

        if kind == "bool":
            if isinstance(value, bool):
                out[key] = value
            else:
                warn("setting %s: expected a bool, got %r; using %r" % (key, value, default))
        elif kind == "int":
            # bool is a subclass of int; a bool here is a host bug, not an int.
            if isinstance(value, int) and not isinstance(value, bool):
                clamped = min(hi, max(lo, value))
                if clamped != value:
                    warn("setting %s: %d out of range [%d, %d], clamped to %d"
                         % (key, value, lo, hi, clamped))
                out[key] = clamped
            else:
                warn("setting %s: expected an int, got %r; using %r" % (key, value, default))
        elif kind == "enum":
            if isinstance(value, str) and value in hi:
                out[key] = value
            else:
                warn("setting %s: %r is not one of %s; using %r"
                     % (key, value, ", ".join(hi), default))
        else:  # string
            if isinstance(value, str):
                out[key] = value
            else:
                warn("setting %s: expected a string, got %r; using %r"
                     % (key, value, default))
    return out


# --------------------------------------------------------------------------
# Source readers
# --------------------------------------------------------------------------

class Problems:
    """Accumulates why the card is less complete than it should be.

    A *directory* that cannot be listed is fatal for the counts — the card goes
    ``unknown`` rather than reporting a number it cannot stand behind.  A single
    unreadable file out of thirty is not: it is counted, mentioned, and the rest
    of the card stands.
    """

    def __init__(self):
        self.fatal = []        # human-readable reasons the counts are unusable
        self.file_errors = 0   # per-file read/parse failures
        self.notes = []        # degradations that do not invalidate the counts
        self.missing = set()   # source directories that simply are not there

    def add_fatal(self, reason):
        if reason not in self.fatal:
            self.fatal.append(reason)

    def add_note(self, note):
        if note not in self.notes:
            self.notes.append(note)

    def add_missing(self, source, note):
        self.missing.add(source)
        self.add_note(note)


def _expand(path):
    return os.path.abspath(os.path.expanduser(os.path.expandvars(path)))


def _read_capped(path, limit):
    """Read at most ``limit`` bytes and decode leniently."""
    with open(path, "rb") as handle:
        blob = handle.read(limit)
    return blob.decode("utf-8", "replace")


def parse_title_line(line):
    """Split a status line into ``(icon, name, ctx_pct, progress, bang)``.

    ``icon`` is "" when the line does not start with one — an anchored name such
    as ``Личное · цвета табов Warp`` is returned whole, separators and all.
    """
    text = RE_CONTROL.sub("", line).strip()
    icon = ""
    if text and text[0] in ICON_CHARS:
        icon = text[0]
        text = text[1:]
        if text.startswith(VARIATION_SELECTOR_16):
            text = text[1:]
        text = text.lstrip()

    segments = text.split(SEPARATOR)
    ctx_pct = None
    progress = None
    bang = False
    index = 0
    while index < len(segments):
        segment = segments[index].strip()
        ctx_match = RE_CTX.match(segment)
        if progress is None and RE_PROGRESS.match(segment):
            progress = segment
        elif ctx_pct is None and ctx_match:
            ctx_pct = int(ctx_match.group(1))
        elif segment == "!":
            bang = True
        elif RE_WATCHERS.match(segment):
            pass  # watcher count: parsed so it cannot be mistaken for the name
        else:
            break
        index += 1

    name = SEPARATOR.join(segments[index:]).strip()
    return icon, name[:MAX_NAME_CHARS], ctx_pct, progress, bang


@dataclass
class Title:
    sid: str
    icon: str = ""
    name: str = ""
    ctx_pct: "int | None" = None
    progress: "str | None" = None
    bang: bool = False
    state_since: "float | None" = None
    engine_name: str = ""


def read_titles(title_dir, problems):
    """Read every ``claude-tab-title-<SID>.txt`` plus its ``.meta`` sidecar."""
    directory = _expand(title_dir)
    try:
        entries = os.listdir(directory)
    except FileNotFoundError:
        # Not an error on its own: the status-line skill simply is not
        # installed here.  Fatal only if the lease registry is missing too.
        problems.add_missing("titles", "no title directory at %s" % directory)
        return {}
    except OSError as exc:
        problems.add_fatal("cannot list %s: %s" % (directory, exc.strerror or exc))
        return {}

    names = [
        n for n in entries
        if n.startswith(TITLE_PREFIX) and n.endswith(TITLE_SUFFIX)
    ]
    paths = [os.path.join(directory, n) for n in names]
    if len(paths) > MAX_TITLE_FILES:
        # Keep the freshest ones; a machine with 500+ title files has a
        # /tmp-cleanup problem, and saying so beats silently reading them all.
        def _mtime(path):
            try:
                return os.path.getmtime(path)
            except OSError:
                return 0.0
        paths.sort(key=_mtime, reverse=True)
        problems.add_note("%d title files, reading the newest %d"
                          % (len(paths), MAX_TITLE_FILES))
        paths = paths[:MAX_TITLE_FILES]

    titles = {}
    for path in paths:
        sid = os.path.basename(path)[len(TITLE_PREFIX):-len(TITLE_SUFFIX)]
        if not sid:
            continue
        try:
            raw = _read_capped(path, MAX_TITLE_BYTES)
        except OSError as exc:
            problems.file_errors += 1
            log("title %s: %s" % (sid, exc))
            continue

        line = ""
        for candidate in raw.splitlines():
            if candidate.strip():
                line = candidate
                break

        icon, name, ctx_pct, progress, bang = parse_title_line(line)
        title = Title(sid=sid, icon=icon, name=name, ctx_pct=ctx_pct,
                      progress=progress, bang=bang)

        try:
            title.state_since = os.path.getmtime(path)
        except OSError:
            pass

        meta_path = path[:-len(TITLE_SUFFIX)] + META_SUFFIX
        try:
            meta = json.loads(_read_capped(meta_path, MAX_META_BYTES))
        except FileNotFoundError:
            meta = None
        except (OSError, ValueError) as exc:
            problems.file_errors += 1
            log("meta %s: %s" % (sid, exc))
            meta = None

        if isinstance(meta, dict):
            # The meta icon is written by the status engine on every state
            # change; the title's first character can be missing entirely
            # because the name was anchored.  Meta wins.
            meta_icon = meta.get("icon")
            if isinstance(meta_icon, str) and meta_icon:
                candidate = meta_icon.replace(VARIATION_SELECTOR_16, "")[:1]
                if candidate in ICON_CHARS:
                    title.icon = candidate
            since = meta.get("icon_since")
            if isinstance(since, (int, float)) and not isinstance(since, bool):
                title.state_since = float(since)
            engine_name = meta.get("engine_name")
            if isinstance(engine_name, str):
                title.engine_name = RE_CONTROL.sub("", engine_name).strip()[:MAX_NAME_CHARS]

        titles[sid] = title
    return titles


@dataclass
class Lease:
    sid: str
    account: str = ""
    cwd: str = ""
    pid: "int | None" = None
    heartbeat_ts: "float | None" = None
    started_ts: "float | None" = None


def read_leases(leases_dir, problems):
    """Read the claude-monitor lease registry."""
    directory = _expand(leases_dir)
    try:
        entries = os.listdir(directory)
    except FileNotFoundError:
        problems.add_missing("leases", "no lease registry at %s" % directory)
        return {}
    except OSError as exc:
        problems.add_fatal("cannot list %s: %s" % (directory, exc.strerror or exc))
        return {}

    paths = [os.path.join(directory, n) for n in entries if n.endswith(".json")]
    if len(paths) > MAX_LEASE_FILES:
        problems.add_note("%d lease files, reading %d"
                          % (len(paths), MAX_LEASE_FILES))
        paths = paths[:MAX_LEASE_FILES]

    leases = {}
    for path in paths:
        sid = os.path.basename(path)[:-len(".json")]
        if not sid:
            continue
        try:
            data = json.loads(_read_capped(path, MAX_LEASE_BYTES))
        except (OSError, ValueError) as exc:
            problems.file_errors += 1
            log("lease %s: %s" % (sid, exc))
            continue
        if not isinstance(data, dict):
            problems.file_errors += 1
            log("lease %s: expected an object, got %s" % (sid, type(data).__name__))
            continue

        lease = Lease(sid=sid)
        account = data.get("account_label")
        if isinstance(account, str):
            lease.account = RE_CONTROL.sub("", account).strip()[:64]
        cwd = data.get("cwd")
        if isinstance(cwd, str):
            lease.cwd = RE_CONTROL.sub("", cwd).strip()[:512]
        pid = data.get("pid")
        if isinstance(pid, int) and not isinstance(pid, bool):
            lease.pid = pid
        for source, target in (("heartbeat_ts", "heartbeat_ts"), ("started_ts", "started_ts")):
            value = data.get(source)
            if isinstance(value, (int, float)) and not isinstance(value, bool):
                setattr(lease, target, float(value))
        leases[sid] = lease
    return leases


def pid_alive(pid):
    """True when the pid exists.  EPERM means it exists and is not ours."""
    if not isinstance(pid, int) or isinstance(pid, bool) or pid <= 0:
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    except OSError as exc:
        log("pid %d: %s" % (pid, exc))
        return True
    return True


def read_ps(fields="command=", timeout=PS_TIMEOUT_SECS):
    """One ``ps`` snapshot.

    The host owns the plugin's deadline and kills the process at ``timeout``
    seconds, so this script never times *itself* out.  The bound here is a
    different thing: it stops one external command from blocking forever inside
    a script that runs every five seconds.  ``ps -axo command=`` measures at
    ~32 ms on this machine, so two seconds is ~60x headroom.
    """
    return subprocess.run(
        ["ps", "-axo", fields],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        encoding="utf-8", errors="replace",
        timeout=timeout, check=False,
    ).stdout


def scan_commands(ps_text):
    """Parse ``ps -axo command=`` into ``(resume_sids, {keeper_sid: tty})``.

    Two independent signals: ``claude --resume <SID>`` names its session
    outright, while a session started fresh shows up only through its tab-title
    keeper, whose command line names both the session and the tty it writes to.
    """
    resume_sids = set()
    keepers = {}
    for line in ps_text.splitlines():
        keeper = RE_KEEPER.search(line)
        if keeper:
            tty_match = RE_KEEPER_TTY.search(line)
            keepers[keeper.group(1)] = tty_match.group(1) if tty_match else None
            continue
        for match in RE_RESUME.finditer(line):
            resume_sids.add(match.group(1))
    return resume_sids, keepers


def scan_claude_ttys(ps_text):
    """Ttys that still host a claude process, from ``ps -axo tty=,command=``.

    The keeper's own line must not be what proves its tty is alive, so it is
    excluded here.
    """
    ttys = set()
    for line in ps_text.splitlines():
        parts = line.split(None, 1)
        if len(parts) != 2:
            continue
        tty, command = parts
        if tty.startswith("ttys") and "claude" in command and TITLE_PREFIX not in command:
            ttys.add(tty)
    return ttys


def ps_evidence(already_live, ps_reader=read_ps):
    """Session ids vouched for by a live process.

    A keeper can outlive its session — the tab was killed, not closed — so a
    keeper only counts while the tty it writes to still hosts a claude process.
    Proving that needs ``ps -axo tty=``, which costs ~77 ms more than the plain
    command listing because ps resolves a device name per process.  That second
    call is therefore made only when a keeper is the *sole* evidence for some
    session; when every keeper belongs to a session already proven live by its
    lease or by ``--resume``, the answer cannot change and the call is skipped.
    """
    resume_sids, keepers = scan_commands(ps_reader("command="))
    sids = set(resume_sids)

    unproven = [sid for sid in keepers if sid not in already_live and sid not in sids]
    if not unproven:
        return sids

    live_ttys = scan_claude_ttys(ps_reader("tty=,command="))
    for sid in unproven:
        keeper_tty = keepers[sid]
        if keeper_tty is None or keeper_tty in live_ttys:
            sids.add(sid)
    return sids


# --------------------------------------------------------------------------
# Assembly
# --------------------------------------------------------------------------

@dataclass
class Session:
    sid: str
    bucket: str = BUCKET_NOSTATUS
    name: str = ""
    group: str = ""
    account: str = ""
    progress: "str | None" = None
    state_since: "float | None" = None


def classify(title):
    """Map a parsed title onto a bucket.

    ``!`` is the status engine's "Claude raised a notification" badge, cleared
    on the next prompt: it means the session wants the operator now, whatever
    its icon says, so it outranks the icon.
    """
    if title is None:
        return BUCKET_NOSTATUS
    if title.bang:
        return BUCKET_WAITING
    if not title.icon:
        return BUCKET_NOSTATUS
    return ICON_TO_BUCKET.get(title.icon, BUCKET_NOSTATUS)


def human_age(seconds):
    if seconds is None or seconds < 0:
        return ""
    seconds = int(seconds)
    if seconds < 60:
        return "%ds" % seconds
    minutes = seconds // 60
    if minutes < 60:
        return "%dm" % minutes
    hours, minutes = divmod(minutes, 60)
    if hours < 24:
        return "%dh%dm" % (hours, minutes) if minutes else "%dh" % hours
    days, hours = divmod(hours, 24)
    return "%dd%dh" % (days, hours) if hours else "%dd" % days


def filter_live_leases(leases, now, stale_after):
    """Leases whose session is still running.

    The shim rewrites ``heartbeat_ts`` every 60 s, so a heartbeat older than the
    threshold means the shim is gone and the session with it — whatever the pid
    says, which guards against pid reuse.  The pid check is the second gate: it
    catches a shim that died seconds ago, before its heartbeat has aged out.
    """
    live = {}
    for sid, lease in leases.items():
        if lease.heartbeat_ts is None:
            # A lease with no heartbeat cannot be aged; the pid is all we have.
            if lease.pid is not None and pid_alive(lease.pid):
                live[sid] = lease
            continue
        if now - lease.heartbeat_ts > stale_after:
            continue
        if lease.pid is not None and not pid_alive(lease.pid):
            continue
        live[sid] = lease
    return live


def collect(settings, now, titles, live_leases, ps_sids):
    """Fold the three sources into the live session list."""
    live_sids = set(live_leases) | set(ps_sids)

    sessions = []
    for sid in live_sids:
        title = titles.get(sid)
        lease = live_leases.get(sid)
        session = Session(sid=sid, bucket=classify(title))

        if title is not None and title.name:
            session.name = title.name
        elif title is not None and title.engine_name:
            session.name = title.engine_name
        elif lease is not None and lease.cwd:
            session.name = os.path.basename(lease.cwd.rstrip("/")) or lease.cwd
        else:
            session.name = sid[:8]

        if lease is not None:
            session.account = lease.account
            if lease.cwd:
                session.group = os.path.basename(lease.cwd.rstrip("/")) or lease.cwd
        if title is not None:
            session.progress = title.progress
            session.state_since = title.state_since

        sessions.append(session)
    return sessions


def note_for(session, settings, now):
    parts = []
    source = settings["note_source"]
    if source in ("project", "both") and session.group:
        parts.append(session.group)
    if source in ("account", "both") and session.account:
        parts.append(session.account)
    if session.progress:
        parts.append(session.progress)
    if session.state_since is not None:
        age = human_age(now - session.state_since)
        if age:
            parts.append(age)
    return SEPARATOR.join(parts)


def build_card(settings, now, titles, live_leases, ps_sids, problems):
    """Compose the card.  Never raises for data reasons."""
    if problems.fatal:
        rows = [{"text": reason} for reason in problems.fatal[:4]]
        rows.insert(0, {"text": "Could not read the session sources."})
        return {
            "state": "unknown",
            "chip": "no data",
            "rows": rows,
            "ttl": CARD_TTL_SECS,
        }

    sessions = collect(settings, now, titles, live_leases, ps_sids)

    uncounted = 0
    if not settings["include_unknown"]:
        kept = [s for s in sessions if s.bucket != BUCKET_NOSTATUS]
        uncounted = len(sessions) - len(kept)
        sessions = kept

    counts = {bucket: 0 for bucket in BUCKET_ORDER}
    for session in sessions:
        counts[session.bucket] += 1
    waiting = counts[BUCKET_WAITING]
    live = len(sessions)

    rows = []
    if live == 0:
        # Idle is not broken.  Say so plainly and stay green.  "Nothing is
        # running" and "nothing is reporting" are different facts, though, and
        # the card must not pass the second off as the first.
        if uncounted:
            rows.append({"text": "No session is reporting a status "
                                 "(%d live, not counted)." % uncounted})
        else:
            rows.append({"text": "No Claude Code sessions running."})
    else:
        rows.append({"kv": ["needs you", str(waiting), "warn" if waiting else "ok"]})
        rows.append({"kv": ["live", str(live)]})

        breakdown = [
            "%d %s" % (counts[bucket], BUCKET_LABEL[bucket])
            for bucket in BUCKET_ORDER
            if bucket != BUCKET_WAITING and counts[bucket]
        ]
        if breakdown:
            rows.append({"text": SEPARATOR.join(breakdown)})

        if settings["show_accounts"]:
            per_account = {}
            for session in sessions:
                label = session.account or "?"
                per_account[label] = per_account.get(label, 0) + 1
            # Named accounts first, alphabetically; the sessions with no lease
            # to name an account for them go last rather than leading the line.
            rows.append({"text": SEPARATOR.join(
                "%s %d" % (label, count)
                for label, count in sorted(per_account.items(),
                                           key=lambda pair: (pair[0] == "?", pair[0]))
            )})

        listed = sessions
        if settings["waiting_only"]:
            listed = [s for s in listed if s.bucket == BUCKET_WAITING]
        # Waiting first, then longest in the current state first.  A session
        # with no known state timestamp sorts last within its bucket.
        listed.sort(key=lambda s: (
            BUCKET_RANK.get(s.bucket, len(BUCKET_ORDER)),
            -(now - s.state_since) if s.state_since is not None else 0.0,
            s.name.lower(),
        ))

        limit = settings["list_rows"]
        if limit and listed:
            items = []
            for session in listed[:limit]:
                item = {
                    "text": session.name,
                    "icon": BUCKET_ICON.get(session.bucket, "dot"),
                    "state": "warn" if session.bucket == BUCKET_WAITING else "ok",
                }
                note = note_for(session, settings, now)
                if note:
                    item["note"] = note
                items.append(item)
            rows.append({"list": items})
            hidden = len(listed) - len(items)
            if hidden > 0:
                rows.append({"text": "+%d more" % hidden})
        elif limit and settings["waiting_only"]:
            rows.append({"text": "Nothing is waiting for you."})

    if problems.file_errors:
        rows.append({"kv": [
            "unreadable files", str(problems.file_errors), "warn",
        ]})
    for note in problems.notes[:2]:
        rows.append({"text": note})

    if waiting:
        state = "warn"
        chip = "%d waiting" % waiting
    else:
        state = "ok"
        # "idle" and "nothing is reporting" are different claims; the chip
        # must not make the second sound like the first either.
        chip = "all quiet" if live else ("no status" if uncounted else "idle")

    card = {"state": state, "chip": chip, "rows": rows, "ttl": CARD_TTL_SECS}

    focus_app = settings["focus_app"].strip()
    if focus_app and live:
        card["actions"] = [{"label": "Focus " + focus_app, "run": ["open", "-a", focus_app]}]
    return card


# --------------------------------------------------------------------------
# Entry point
# --------------------------------------------------------------------------

def log(message):
    """Diagnostics go to stderr; stdout carries the card and nothing else."""
    sys.stderr.write("claude-sessions: %s\n" % message)


def gather(settings, now, ps_reader=read_ps):
    problems = Problems()
    titles = read_titles(settings["title_dir"], problems)
    leases = read_leases(settings["leases_dir"], problems)
    live = filter_live_leases(leases, now, settings["stale_lease_secs"])

    ps_sids = set()
    try:
        ps_sids = ps_evidence(set(live), ps_reader)
    except (OSError, subprocess.SubprocessError) as exc:
        # Losing ps costs us the sessions that have no lease yet; the leases
        # themselves are unaffected, so the counts stay usable.
        log("ps failed: %s" % exc)
        problems.add_note("ps unavailable, process evidence missing")

    if {"titles", "leases"} <= problems.missing:
        # Neither source directory exists.  That is not "zero sessions", it is
        # "this plugin has nothing to read", and the two must not look alike.
        problems.add_fatal("neither the title directory nor the lease registry "
                           "exists on this machine")

    return build_card(settings, now, titles, live, ps_sids, problems)


def main():
    warnings = []
    try:
        settings = load_settings(warn=warnings.append)
        for warning in warnings:
            log(warning)
        card = gather(settings, time.time())
    except Exception as exc:  # noqa: BLE001 - last resort; the host needs a card
        traceback.print_exc(file=sys.stderr)
        card = {
            "state": "unknown",
            "chip": "plugin error",
            "rows": [
                {"text": "The plugin failed to read its sources."},
                {"text": "%s: %s" % (type(exc).__name__, exc)},
            ],
            "ttl": CARD_TTL_SECS,
        }

    try:
        sys.stdout.reconfigure(encoding="utf-8")
        text = json.dumps(card, ensure_ascii=False)
    except Exception:  # noqa: BLE001 - fall back to a pure-ASCII payload
        text = json.dumps(card, ensure_ascii=True)
    sys.stdout.write(text)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
