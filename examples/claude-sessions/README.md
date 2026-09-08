# Claude sessions

A uDeck poll plugin for people who run a lot of Claude Code at once. It answers
one question at a glance — **how many sessions are waiting for me right now?** —
and backs it with a live count and a short list of the most interesting sessions.

```
┌──────────────────────────────┐
│ Claude sessions   ⟨15 waiting⟩│
│ needs you                  15 │
│ live                       40 │
│ 1 on external · 2 running ·   │
│ 22 no status                  │
│ ⚠ Задачи · тех-стори          │
│    proctor-cyber-work… · 1d17h│
│ ⚠ Личное · цвета табов Warp   │
│    1d17h                      │
│ ⚠ data docker  u-pilot · 1d14h│
│ +34 more                      │
└──────────────────────────────┘
```

## What it reads

Three kinds of local file and one process listing. None of them is sufficient on
its own, and the plugin is mostly about combining them honestly.

| Source | Gives |
|---|---|
| `<title_dir>/claude-tab-title-<SID>.txt` | the tab status line: state icon, context %, step progress, the `!` attention badge, and the session name |
| `<title_dir>/claude-tab-title-<SID>.meta` | the authoritative state icon plus `icon_since`, i.e. how long the session has been in that state |
| `<leases_dir>/<SID>.json` | the claude-monitor lease: account label, working directory, pid, heartbeat |
| `ps -axo pid=,ppid=,command=` | which sessions actually have a process, and which process owns which |

The status line and its sidecar are written by the `terminal-status` skill; the
lease registry is written by the `claude-monitor` skill. Neither is required — the plugin degrades to
whatever it can read and says which source it lost.

### The status line format

```
<icon> [N/M ·] [ctx% ·] [extras ·] <name>
```

Icons: `▶` working, `⏳` waiting on something external, `✋` waiting for you,
`✅` done-idle, `⏸` paused on usage limits, `🔄` compacting, `💤` idle.

Two things about this format bite naive parsers, and the plugin handles both:

* **The icon is optional.** A session with an anchored name writes
  `Задачи · тех-стори` with no icon at all. The meta sidecar still knows the
  state, so the plugin prefers the meta icon and only falls back to the title's
  first character.
* **The name can contain the ` · ` separator.** So the parser consumes *known*
  prefix segments from the left (`3/7`, `42%`, `!`, `m2`) and keeps everything
  from the first unrecognised segment onwards as the name. Splitting on ` · `
  and taking the last field would turn `Личное · цвета табов Warp` into
  `цвета табов Warp`.

The `!` segment is the badge the status engine sets when Claude Code raises a
notification. It means the session wants you *now*, so it counts as waiting
whatever the icon says.

## What counts as alive

A title file lying around in `/tmp` proves nothing — they outlive their sessions
and there are usually several stale ones. A session counts as live when:

* its **lease** has a heartbeat younger than the stale threshold **and** its pid
  still exists. The shim rewrites the heartbeat every 60 s, so a frozen
  heartbeat is a dead session; requiring both guards against pid reuse; or
* `ps` shows a **`claude --resume <SID>`** process — how a restored tab looks
  before its SessionStart hook has run; or
* its **tab-title keeper** is running *and* the tty that keeper writes to still
  hosts a claude process. A keeper survives a tab that was killed rather than
  closed, so the tty cross-check is what stops it from inflating the count.

One subtraction matters as much as the additions. **Resuming a conversation can
mint a new session id.** The lease and the status line carry the new id; the
process command line keeps the id it was launched with, for as long as the tab
lives. Counting both would report one tab as two sessions — on this machine the
live session `1d89ed71` runs inside a process still reading
`claude --resume 01181340`. So the plugin walks up from each lease's shim to the
claude process that owns it, and discards the launched id when it differs from
the lease's own.

Sessions that are live but have no status line land in a **`no status`** bucket
rather than being dropped or guessed at. On a machine that has just restored a
few dozen tabs this is normally the largest bucket, and pretending otherwise
would misreport the machine.

## States

### What counts as "needs you"

Only two things: the `✋` icon, and the `!` badge — the status engine's "Claude
raised a notification", which outranks whatever icon the session is showing.

Nothing else. `✅` done-idle in particular is *not* waiting for you: on a machine
with dozens of tabs it is both common and permanent, and folding it in would put
a number on the card that never went down and therefore never meant anything.
`⏸` (paused on usage limits) and `⏳` (waiting on something external) are the
session waiting on something that is not you, and get their own counts.

| Card | Meaning |
|---|---|
| `ok`, chip `all quiet` | sessions are running, none needs you |
| `ok`, chip `idle` | genuinely nothing running. Idle is not broken |
| `warn`, chip `N waiting` | at least one session is waiting for you |
| `unknown` | a source **directory** could not be read; the reason is on the card |

`unknown` is reserved for "I could not read my sources". A single unreadable
file out of thirty is not that: it is counted, shown as an `unreadable files`
row, and the rest of the card stands.

`ttl` is 20 s — four poll intervals. Past it the host greys the card; past 3×
it hides the values, which is exactly right for numbers that stopped being
refreshed.

## Install

```sh
mkdir -p ~/.udeck/plugins/claude-sessions
cp manifest.json sessions.py ~/.udeck/plugins/claude-sessions/
chmod +x ~/.udeck/plugins/claude-sessions/sessions.py
```

Then add the plugin from uDeck. It polls every 5 s with a 3 s deadline.

Requirements: macOS and Python 3.9+ (the system `python3` is enough — the script
is standard library only and installs nothing).

## Settings

| Key | Type | Default | What it does |
|---|---|---|---|
| `waiting_only` | bool | `false` | List only the sessions waiting for you. The counts stay complete either way |
| `list_rows` | int | `6` | How many sessions to list. `0` shows the counts only |
| `stale_lease_secs` | int | `180` | How old a lease heartbeat may be before its session counts as dead |
| `note_source` | enum | `project` | Show the project directory, the account, or both next to each session |
| `include_unknown` | bool | `true` | Count live sessions that have not written a status line |
| `show_accounts` | bool | `false` | Add a per-account line (`pers 9 · work 5 · work2 3`) |
| `leases_dir` | string | `~/.claude/skills/claude-monitor/runtime/leases` | Lease registry location |
| `title_dir` | string | `/tmp` | Where the status lines live |
| `focus_app` | string | `Warp` | Terminal the **Focus** action brings forward. Empty removes the action |

### Why `stale_lease_secs` defaults to 180

That is claude-monitor's own `LEASE_TTL_SECS`, against a 60 s heartbeat: three
missed heartbeats. Matching it means this card and the monitor never disagree
about who is alive. Lowering it makes the card notice a crashed session sooner
at the cost of flagging a briefly-stalled one as dead; raising it does the
reverse. The pid check catches most crashes immediately anyway, so the
threshold only really matters when a session dies in a way that leaves its pid
occupied.

### Why `leases_dir` is under `~/.claude` and not `$CLAUDE_CONFIG_DIR`

claude-monitor runs one host-wide daemon for every account, so its runtime tree
is deliberately pinned to `~/.claude` no matter which account's session spawned
it. Deriving this path from `CLAUDE_CONFIG_DIR` would break the plugin for every
session that is not on the default account.

## Cost

One `ps` and two small directory listings per poll. Measured on the author's
machine (40 live sessions, 24 title files, 17 leases, ~900 processes):
**60–70 ms** wall clock per run, of which ~33 ms is `ps` and ~17 ms is
interpreter start-up.

The `ppid` column is free — ps already holds it — which is what makes the
superseded-id check above cost nothing. The `tty` column is not: it costs
another ~76 ms because ps resolves a device name for every process. That second
listing is therefore only requested when a keeper is the *sole* evidence for
some session; when every keeper belongs to a session already proven live, the
answer cannot change and the call is skipped.

## Output contract

Exactly one JSON object on stdout, nothing else. Diagnostics — a setting that
would not parse, a lease file that would not read, `ps` failing — go to stderr
and show up in the plugin's error log. The script never raises: an unexpected
failure still prints a valid `unknown` card carrying the exception, and exits 0.

## Tests

```sh
python3 -m unittest discover -s examples/claude-sessions -p 'test_*.py'
```

105 tests, no network, no dependencies, and nothing that reads the real machine's
title or lease directories — every case runs against a fabricated filesystem
root and a canned `ps` listing, so the suite behaves the same on a busy machine
and an empty one. The suite includes an independent validator for the card
schema, which every card the tests build is checked against.

## Known limits

Things this plugin does not do, or does approximately, that a future reader
should know before trusting a number on the card.

- **Keeper detection has never been exercised end to end.** A session whose only
  evidence is a running tab-title keeper is covered by unit tests and by nothing
  else, because on the machine this was written against every live keeper also
  had a lease. The code path is therefore correct as designed and unproven in
  the field.
- **"How long in this state" falls back to file modification time** when a meta
  sidecar has no `icon_since`. That tracks the last write to the file rather
  than the last change of state, so it can read younger than the truth.
- **A superseded session id with no lease of its own is undetectable.** If a
  resumed conversation minted a new id and no lease was ever written for it,
  the plugin cannot tell which id is current. The *count* stays right — the
  session is counted exactly once either way — but the identity shown is the
  old one. Such a session has no status line either, so it renders as an
  unnamed `no status` row regardless.
- **No transcript parsing.** Session transcripts hold richer state — the real
  context percentage, the last message — and are multi-megabyte files, of which
  there are hundreds. Nothing that runs every five seconds should open them.
- **No per-tab focus.** The action brings the terminal application forward.
  Focusing the *specific* tab would need AppleScript and tab ids from the
  launch configuration; a button that looks like it does that and does not
  would be worse than no button.
