# Writing a uDeck plugin

A walkthrough, from an empty folder to something on the panel. Ten minutes, no
SDK, no compiler, any language that can print.

The **[plugin contract](plugin-api.md)** is the reference — every field, every
rule, every limit. This is the path through it.

---

## 1. What a plugin is

A folder with two things in it:

```
my-plugin/
  manifest.json   what it is, what it needs, what the operator can change
  run.sh          prints one JSON object and exits
```

uDeck runs the producer on an interval and draws what it printed. That is the
whole model. There is no library to link, nothing to register, and no callback
to implement — if your language can write to standard output, it can write a
uDeck plugin.

---

## 2. Make one that already works

```sh
Scripts/new-plugin.sh my-first-plugin
```

That writes a working plugin into `~/.udeck/plugins/my-first-plugin/`. Run it
the way uDeck will, first, before you change anything:

```sh
~/.udeck/plugins/my-first-plugin/run.sh | python3 -m json.tool
```

Then open the panel and add it to a tab. **You do not have to tell uDeck about
it** — the plugins folder is watched, so it is already in the list.

Change the text it prints, wait five seconds, and watch the card change. That is
the whole development loop. The ⟳ button on the card runs it on demand when five
seconds is too long to wait.

---

## 3. Print a card

```json
{
  "state": "ok",
  "chip": "3 running",
  "rows": [
    { "text": "Something worth knowing." },
    { "kv": ["label", "value", "ok"] },
    { "meter": { "value": 0.42, "label": "Disk", "caption": "42 % full" } }
  ],
  "ttl": 30
}
```

* `state` is `ok`, `warn`, `crit` or `unknown`, and it colours the card *and*
  the island while the panel is away. It is the one field somebody reads from
  across the room.
* `chip` is a couple of words next to the title. Put the headline number in it.
* `rows` is the body. Seven kinds: `text`, `kv`, `meter`, `list`, `spark`,
  `table`, `log`. [`examples/hello-card`](../examples/hello-card) prints one of
  each.
* **`ttl` is the most important field.** It says how long this card can be
  trusted. Past it uDeck greys the card, and past three times it hides the
  values — because a number that stopped being refreshed and looks exactly like
  a number that did not is how a panel stops being believed. Set it to about
  four intervals.

`unknown` is worth using properly: it means *"I could not read my sources"*, not
*"nothing is happening"*. Idle is not broken, and a card that says so is telling
the operator something true.

---

## 4. Read something real

The producer's job is to turn some source into one card. A few rules that come
from watching producers misbehave:

* **Never call anything that can block forever.** The classic is a command that
  touches a network mount whose server has gone away: it does not fail, it
  waits. Bound it with a timeout of your own, restrict it to what cannot hang,
  or read a file the source writes instead.
* **Fail partially, not totally.** One unreadable file out of thirty is one
  unreadable file, not a poisoned card. Say what you lost, on the card, and
  print the rest.
* **Be fast.** A five-second interval means seventeen thousand runs a day.
* **Never raise.** Whatever happens, print a card. An unexpected failure should
  still produce a valid `unknown` card carrying the reason, and exit 0.

---

## 5. Let the operator change things

Declare settings in the manifest and uDeck renders the settings screen for you —
you never ship a preferences window:

```json
"settings": [
  { "key": "rows", "type": "int", "default": 6, "min": 0, "max": 40,
    "label": "How many to list" }
]
```

They reach you as environment variables holding **JSON**:

```
UDECK_SETTING_ROWS=6
UDECK_SETTING_ONLY_FAILING=false
UDECK_SETTING_SORT="name"
```

JSON rather than bare text, so you can tell `false` from `"false"` and `12` from
`"12"`. Read them defensively — a missing or unparseable variable should fall
back to your declared default rather than crash. Keep the defaults in one place
in your code and let everything else read them from there; the examples do this
with a single table mirroring the manifest.

---

## 6. Ask for what you need

```json
"permissions": {
  "read":  ["~/Notes/*.md"],
  "exec":  ["df", "open"]
}
```

uDeck shows the operator exactly this and does not run you until they agree.
Declare honestly: **the declaration is what the operator reads**, and a plugin
that asks for less than it uses is lying to them in a screen built for the
purpose.

Two of these are genuinely enforced rather than advisory. uDeck decides whether
to launch you at all — all of your declared capabilities or none. And uDeck runs
your card's *actions*, so a button whose command you were not granted `exec` for
does nothing and says why, in code you do not control.

---

## 7. Buttons

```json
"actions": [
  { "label": "Open Backup", "run": ["open", "/Volumes/Backup"] },
  { "label": "Empty the cache", "run": ["./tools/purge"],
    "confirm": "Delete every cached file?" }
]
```

uDeck runs the command, not you. `confirm` asks first — use it for anything that
changes something. A relative path is resolved inside your folder with symlinks
followed, so a path the operator agreed to is the file they agreed to.

Twelve buttons is the limit. If you want a thirteenth, what you want is a
window, not a card.

---

## 8. Speak the operator's language

Two things are translated, in two different ways, because they are read at two
different times.

**Your card** is made when you run, so uDeck tells you which language to answer
in and gets out of the way:

```sh
case "$UDECK_LANG" in
  ru) title="Сборки" ;;
  *)  title="Builds" ;;
esac
```

**Your manifest** is read without running you — it is what the operator sees in
the plugin list and in the sheet that asks whether to allow you — so it is
translated on disk. Put `manifest.ru.json` next to `manifest.json` with the
strings and nothing else:

```json
{
  "name": "Место на диске",
  "description": "Сколько места осталось.",
  "settings": { "rows": { "label": "Сколько показывать" } }
}
```

A translation can never change what your plugin does: there is no `run` in that
format, no `permissions`, no `id` — absent, not ignored. The operator agreed to
what the manifest asked for, and a file arriving later must not be able to
change that.

---

## 9. What uDeck does when you misbehave

Each of these shows a different, readable message on the card, so you find out
by looking rather than by guessing:

| What you did | What happens |
|---|---|
| Ran past `timeout` | killed, with the whole process group you started |
| Exited non-zero | reported with the status |
| Printed nothing, or not a card | reported, naming the field that would not parse |
| Printed more than a megabyte | stopped; the first megabyte is kept |
| Printed a card larger than uDeck draws | drawn up to the limit, with a row saying it was cut |
| Kept failing | asked less often — doubling, capped at a minute, reset by the first good card |

The backoff is why the ⟳ button ignores it: the way to test a fix is to press
it, not to wait.

---

## 10. Before you ship

- [ ] The folder name equals the manifest's `id`.
- [ ] `run.sh` is executable (`chmod +x`).
- [ ] Running it by hand prints exactly one JSON object, and nothing else on
      stdout.
- [ ] It prints a valid card when its sources are **missing** — try it with the
      files renamed away.
- [ ] `ttl` is about four intervals, and `timeout` is shorter than `interval`.
- [ ] Every setting has a `label`; the ones whose meaning is not obvious have
      `help`.
- [ ] `permissions` lists everything you actually use, and nothing you do not.
- [ ] Diagnostics go to stderr, never to stdout.
- [ ] It leaves no background children (uDeck ends the group, but a plugin that
      needs one is fighting the runtime).
- [ ] If it holds anything the operator would miss, it is in
      `$UDECK_CACHE_DIR`, which is yours.

---

## 11. Where to look next

* **[The plugin contract](plugin-api.md)** — every field, every rule, the full
  environment, the limits with their numbers, and why each of them is there.
* **[`examples/hello-card`](../examples/hello-card)** — every row type, no
  permissions, twenty lines of shell.
* **[`examples/disk-space`](../examples/disk-space)** — a real plugin: settings
  of four types, permissions, two languages, its own tests, and a README that
  explains the one thing that makes disk space harder to report than it looks.
* **[`examples/slow-plugin`](../examples/slow-plugin)** and
  **[`examples/broken-card`](../examples/broken-card)** — what a deadline and a
  parse error look like from the operator's side.
