"""`e2e/run.sh selfcheck`: the accessibility helper reads what System Events read.

Until 2026-10-12 every screen the checks read was walked by System Events, with
AppleScript over SSH; since then by the lab's own helper (`e2e/guest/ax.swift`,
`udeck_e2e.ax`), in a tenth of the time or less. Every sentence a check says
about a control stands on what the walk read, so before the old walks were
taken out of `ui` the two were held against each other here, on the same
screens of the same uDeck in the same guest — and they still are, whenever the
lab is in doubt: a new macOS, a new Tart, a new golden image.

**The screens**: Settings' five panes (General, Opening, Look, Plugins with the
fake GitHub's catalogue in it, About), the **Install from a link…** sheet, the
panel, and General and Plugins again with uDeck in Russian. **The readings**,
each as `ui` reads it: the whole tree (`ui.tree`), the identified controls
(`ui.identified`), the identifiers (`ui.identifiers`), the sentences
(`ui.static_texts`), single controls found by identifier (`ui.find`), uDeck's
windows and its menu; and the two readings of another application's window the
panel checks make (`probes.typed_into`, `probes.move_window`).

**Same means the same parsed controls, in the same order**: role, subrole,
identifier, title, value, description, depth, and the place and size in whole
points. A screen that changed between the two readings — a status line that
counts seconds — would read as a difference, so the helper reads each screen
before and after System Events does, and the old reading is held against the
closer of them. Two things are not differences, and both were measured
(run 20261012-063626Z) rather than assumed: what is inside the window's own
title-bar buttons, where System Events listed one group more and no check
looks; and a control System Events *misread* — SwiftUI hands an AppleScript
client the first of the elements that read alike, so every catalogue row's
"Verified" came back as the first row's, with its identifier and place, where
the helper reads each row's own (`ax.held_against` says exactly when a
difference counts as that). They are written down as misreadings, not hidden. What System Events took and what the helper took are written down beside
it (`comparison.json`, `comparison.txt`), with the guest's own facts — its TCC
grants, its shell — in `guest-facts.txt`.

**The plugin checks' own screens** are a second check
(`ax.cards-and-questions-read-as-system-events-read`), made the way the plugin
checks make them (`checks/check_plugins.py`'s own helpers): the panel with a
plugin's card asking for consent, the card once it has run, and the card after
a failed run (its dot and its line); Settings → Plugins with **More** open on
that run (its last run and the end of its stderr), and with the question
**Remove** asks; and the **Install from a link…** sheet with a pull request
looked up, its plugins listed. The card is one that changes only when the lab
makes it (it runs when the panel is revealed or refreshed, and stays fresh for
an hour), so that the screen the two readers read is one screen.

Anything that differs is the lab's failure, never uDeck's: this check says the
lab can read uDeck's screens, nothing about uDeck.
"""

import importlib.util
import json
import sys
import time
from pathlib import Path

from udeck_e2e import app, ax, config, panel, plugin_repository, probes, ui, updates
from udeck_e2e.errors import LabError

VERSION = ("0.4.1", "6")

# How long one System Events reading is given: a walk of Settings → Plugins took
# 92 s once (`ui`'s history), and this one is about measuring, not hurrying.
OLD_SECONDS = 900

# How many controls of a screen are also found one by one (`ui.find`): System
# Events took up to 20 s for each on Settings → Plugins.
FINDS = 6

# --- The walks the lab made until 2026-10-12, kept here as the yardstick ------------

_FIND = """
on findIt(e, wanted, depth)
  try
    tell application "System Events" to set theId to value of attribute "AXIdentifier" of e
    if theId is wanted then return e
  end try
  if depth < %(depth)d then
    try
      tell application "System Events" to set kids to UI elements of e
      repeat with k in kids
        set found to findIt(k, wanted, depth + 1)
        if found is not missing value then return found
      end repeat
    end try
  end if
  return missing value
end findIt

tell application "System Events" to tell process %(process)s
  set w to first window whose name is %(window)s
end tell
set target to findIt(w, %(identifier)s, 0)
if target is missing value then return "not found"
tell application "System Events"
  set p to value of attribute "AXPosition" of target
  set s to value of attribute "AXSize" of target
end tell
return ((item 1 of p) as text) & "," & ((item 2 of p) as text) & "," & ((item 1 of s) as text) & "," & ((item 2 of s) as text)
"""

_LIST = """
on describe(e, depth)
  set out to {}
  set theRole to ""
  set theId to ""
  try
    tell application "System Events" to set theRole to role of e
  end try
  try
    tell application "System Events" to set theId to value of attribute "AXIdentifier" of e
  end try
  if theId is not "" and theId is not missing value then set end of out to (theRole & " [" & theId & "]")
  if depth < %(depth)d then
    try
      tell application "System Events" to set kids to UI elements of e
      repeat with k in kids
        set out to out & describe(k, depth + 1)
      end repeat
    end try
  end if
  return out
end describe

tell application "System Events" to tell process %(process)s
  set w to first window whose name is %(window)s
end tell
set report to describe(w, 0)
set text item delimiters to ", "
return report as text
"""

_TEXTS = """
on collect(e, depth)
  set out to {}
  try
    tell application "System Events" to set theRole to role of e
    if theRole is "AXStaticText" then
      set theValue to ""
      try
        tell application "System Events" to set theValue to value of e
      end try
      if theValue is "" or theValue is missing value then
        try
          tell application "System Events" to set theValue to name of e
        end try
      end if
      if theValue is not "" and theValue is not missing value then set end of out to theValue
    end if
  end try
  if depth < %(depth)d then
    try
      tell application "System Events" to set kids to UI elements of e
      repeat with k in kids
        set out to out & collect(k, depth + 1)
      end repeat
    end try
  end if
  return out
end collect

tell application "System Events" to tell process %(process)s
  set w to first window whose name is %(window)s
end tell
set report to collect(w, 0)
set text item delimiters to " | "
return report as text
"""

_TREE = """
on attr(e, n)
  set v to ""
  try
    tell application "System Events" to set v to value of attribute n of e
  end try
  if v is missing value then return ""
  try
    if class of v is list then
      set t to ""
      repeat with one in v
        set t to t & (one as text) & ";"
      end repeat
      return t
    end if
    return v as text
  on error
    return "?"
  end try
end attr

on describe(e, depth)
  set out to {}
  set end of out to (depth as text) & "|" & my attr(e, "AXRole") & "|" & my attr(e, "AXSubrole") ¬
    & "|" & my attr(e, "AXIdentifier") & "|" & my attr(e, "AXTitle") & "|" & my attr(e, "AXValue") ¬
    & "|" & my attr(e, "AXDescription") & "|" & my attr(e, "AXPosition") & "|" & my attr(e, "AXSize")
  if depth < %(depth)d then
    try
      tell application "System Events" to set kids to UI elements of e
      repeat with k in kids
        set out to out & my describe(k, depth + 1)
      end repeat
    end try
  end if
  return out
end describe

tell application "System Events" to tell process %(process)s
  set w to first window whose name is %(window)s
end tell
set report to my describe(w, 0)
set text item delimiters to linefeed
return report as text
"""

_IDENTIFIED = """
on oneLine(t)
  set saved to text item delimiters
  set text item delimiters to {return & linefeed, linefeed, return}
  set parts to text items of t
  set text item delimiters to "⏎"
  set t to parts as text
  set text item delimiters to saved
  return t
end oneLine

on txt(v)
  if v is missing value then return ""
  try
    if class of v is list then
      set t to ""
      repeat with one in v
        set t to t & (one as text) & ";"
      end repeat
      return my oneLine(t)
    end if
    return my oneLine(v as text)
  on error
    return "?"
  end try
end txt

on attr(e, n)
  try
    tell application "System Events" to return my txt(value of attribute n of e)
  on error
    return ""
  end try
end attr

on describe(e, depth, out)
  set kids to {}
  try
    tell application "System Events" to set kids to UI elements of e
  end try
  set k to count of kids
  if k is 0 then return out
  set ids to missing value
  try
    tell application "System Events" to set ids to value of attribute "AXIdentifier" of every UI element of e
    if (count of ids) is not k then set ids to missing value
  end try
  repeat with i from 1 to k
    set kid to item i of kids
    if ids is missing value then
      set theId to my attr(kid, "AXIdentifier")
    else
      set theId to my txt(contents of item i of ids)
    end if
    if theId is not "" then
      set fields to {depth as text}
      repeat with n in {"AXRole", "AXSubrole"}
        set end of fields to my attr(kid, n as text)
      end repeat
      set end of fields to theId
      repeat with n in {"AXTitle", "AXValue", "AXDescription", "AXPosition", "AXSize"}
        set end of fields to my attr(kid, n as text)
      end repeat
      set text item delimiters to "|"
      set end of out to (fields as text)
      set text item delimiters to ""
    end if
    if depth < %(depth)d then set out to my describe(kid, depth + 1, out)
  end repeat
  return out
end describe

tell application "System Events" to tell process %(process)s
  set w to first window whose name is %(window)s
end tell
set report to my describe(w, 1, {})
set text item delimiters to linefeed
return report as text
"""

_WINDOWS = """
tell application "System Events" to tell process %(process)s to get name of every window
"""

_MENU_ITEMS = """
tell application "System Events" to tell process %(process)s
  set titles to name of every menu item of menu 1 of menu bar item 1 of menu bar 1
end tell
set text item delimiters to ", "
return titles as text
"""


_NAMED_WINDOW = "first window whose name is %(window)s"
_PANEL_WINDOW = 'first window whose subrole is "AXSystemDialog"'

_TEXT_OF = (
    'tell application "System Events" to tell process %(process)s to get value of text area 1 of scroll area 1 of window 1'
)
_POSITION_OF = 'tell application "System Events" to tell process %(process)s to get position of window 1'


def _script(script, **values):
    """`ui._applescript` as it was: strings quoted, and the panel found by its subrole."""
    if values.get("window") == ui.PANEL:
        script = script.replace(_NAMED_WINDOW, _PANEL_WINDOW)
        values = {key: value for key, value in values.items() if key != "window"}
    quoted = {key: '"' + str(value).replace("\\", "\\\\").replace('"', '\\"') + '"' for key, value in values.items()}
    return script % {"depth": ui.MAX_DEPTH, **quoted}


def _timed(call):
    started = time.monotonic()
    answer = call()
    return answer, round(time.monotonic() - started, 3)


def _old(machine, script, step, **values):
    return _timed(lambda: ui.ask(machine, _script(script, process=ui.PROCESS, **values), step, seconds=OLD_SECONDS))


def _rows(dump, step):
    """A walk's controls as what is compared: everything a check reads of one, `shown` aside."""
    return [
        (c.role, c.subrole, c.identifier, c.title, c.value, c.description, c.x, c.y, c.width, c.height)
        for c in ui.controls(dump, step)
    ]  # fmt: skip


def _depths(dump):
    return [line.split("|", 1)[0] for line in dump.splitlines() if line.strip()]


class Comparison:
    """Every reading of every screen, both ways, kept as evidence and summed up."""

    def __init__(self, check_dir, note):
        self.check_dir = check_dir
        self.note = note
        self.rows = []

    def add(self, screen, what, old, new, old_seconds, new_seconds, problems, explained=()):
        self.rows.append({
            "screen": screen, "what": what, "system_events_seconds": old_seconds, "helper_seconds": new_seconds,
            "count": len(new) if isinstance(new, list) else None, "same": not problems, "differences": problems,
            "system_events_misread": list(explained),
        })  # fmt: skip
        verdict = "same" if not problems else f"{len(problems)} difference(s)"
        if explained:
            verdict += f", and {len(explained)} control(s) System Events misread"
        self.note(f"   {screen} — {what}: {verdict}; System Events {old_seconds}s, the helper {new_seconds}s")

    def keep(self, name, text):
        try:
            (self.check_dir / name).write_text(text)
        except OSError as error:
            self.note(f"   {name} could not be written: {error}")

    def write(self):
        self.keep("comparison.json", json.dumps(self.rows, indent=1, ensure_ascii=False))
        lines = []
        for row in self.rows:
            lines.append(
                f"{'SAME' if row['same'] else 'DIFF'}  {row['screen']} — {row['what']}: "
                f"System Events {row['system_events_seconds']}s, helper {row['helper_seconds']}s"
                + (f", {row['count']} items" if row["count"] is not None else "")
            )
            lines += [f"      {problem}" for problem in row["differences"]]
            lines += [f"      (misread) {line}" for line in row["system_events_misread"]]
        self.keep("comparison.txt", "\n".join(lines) + "\n")

    def problems(self):
        return [f"{row['screen']} — {row['what']}: {row['differences'][0]}" for row in self.rows if not row["same"]]


def _either(old, before, after, compare):
    """(differences, misreadings) between `old` and whichever of the two new readings it is closer to."""
    first, second = compare(old, before), compare(old, after)
    return first if len(first[0]) <= len(second[0]) else second


def _plain(compare_rows):
    """A comparison with nothing to explain: every difference is one."""
    return lambda a, b: (compare_rows(a, b), [])


def compare_screen(machine, comparison, screen, window=ui.SETTINGS_WINDOW, identified_depth=ui.IDENTIFIED_DEPTH):
    """One screen read every way `ui` reads one, by System Events and by the helper."""
    step = f"reading {screen}"
    keep_name = screen.lower().replace(" ", "-").replace("→", "").replace("—", "").replace("…", "").replace("--", "-")

    # The whole tree.
    before, new_seconds = _timed(lambda: ui.tree(machine, step, window))
    old, old_seconds = _old(machine, _TREE, step, window=window)
    after = ui.tree(machine, step, window)
    comparison.keep(f"{keep_name}-tree-system-events.txt", old)
    comparison.keep(f"{keep_name}-tree-helper.txt", before)

    def walk_rows(dump):
        return ax.without_the_title_bar([(d, *r) for d, r in zip(_depths(dump), _rows(dump, step))])

    def trees(a, b):
        try:
            rows_a = walk_rows(a)
        except LabError as error:
            return [f"System Events' walk could not be read: {error.reason}"], []
        return ax.held_against(rows_a, walk_rows(b), "control", ax.same_control_words)

    comparison.add(screen, "every element (ui.tree)", None, _rows(before, step), old_seconds, new_seconds, *_either(old, before, after, trees))
    # The controls System Events misread in this screen's tree: the only
    # differences a list of identifiers may have (`ax.same_identifier_misread`).
    try:
        misread = ax.misread_identifiers(walk_rows(old), walk_rows(before)) | ax.misread_identifiers(walk_rows(old), walk_rows(after))
    except LabError:
        misread = set()

    # The identified controls.
    before, new_seconds = _timed(lambda: ui.identified(machine, step, window, depth=identified_depth))
    old, old_seconds = _old(machine, _IDENTIFIED.replace("%(depth)d", str(identified_depth)), step, window=window)
    after = ui.identified(machine, step, window, depth=identified_depth)
    comparison.keep(f"{keep_name}-identified-system-events.txt", old)
    comparison.keep(f"{keep_name}-identified-helper.txt", before)
    comparison.add(screen, f"identified controls to depth {identified_depth} (ui.identified)", None, _rows(before, step),
                   old_seconds, new_seconds, *_either(old, before, after, trees))  # fmt: skip
    found = [c.identifier for c in ui.controls(before, step)]

    # The identifiers, as a reason lists them.
    before, new_seconds = _timed(lambda: ui.identifiers(machine, step, window))
    old, old_seconds = _old(machine, _LIST, step, window=window)
    after = ui.identifiers(machine, step, window)
    old_list = [part.strip() for part in old.split(",") if part.strip()]
    comparison.add(screen, "identifiers (ui.identifiers)", old_list, before, old_seconds, new_seconds,
                   *_either(old_list, before, after, lambda a, b: ax.held_against([(x,) for x in a], [(x,) for x in b], "identifier",
                                                                                  ax.same_identifier_misread(misread))))  # fmt: skip

    # The sentences.
    before, new_seconds = _timed(lambda: ui.static_texts(machine, step, window))
    old, old_seconds = _old(machine, _TEXTS, step, window=window)
    after = ui.static_texts(machine, step, window)
    old_texts = [part.strip() for part in old.split(" | ") if part.strip()]
    comparison.add(screen, "sentences (ui.static_texts)", old_texts, before, old_seconds, new_seconds,
                   *_either(old_texts, before, after, _plain(lambda a, b: ax.differences([(x,) for x in a], [(x,) for x in b], "sentence"))))  # fmt: skip

    # Single controls, found by their identifier.
    unique = list(dict.fromkeys(found))
    chosen = unique if len(unique) <= FINDS else [unique[round(i * (len(unique) - 1) / (FINDS - 1))] for i in range(FINDS)]
    for identifier in chosen:
        before, new_seconds = _timed(lambda: ui.find(machine, identifier, step, window))
        old, old_seconds = _old(machine, _FIND, step, window=window, identifier=identifier)
        after = ui.find(machine, identifier, step, window)
        place = lambda e: None if e is None else (e.x, e.y, e.width, e.height)  # noqa: E731
        old_place = None if old.strip() == "not found" else tuple(int(float(n)) for n in old.strip().split(","))
        comparison.add(screen, f"'{identifier}' found (ui.find)", None, None, old_seconds, new_seconds,
                       [] if old_place in (place(before), place(after)) else [f"System Events {old_place}, the helper {place(before)}"])  # fmt: skip


def compare_windows_and_menu(machine, comparison, screen, window_titles_must_include):
    step = f"reading uDeck's windows: {screen}"
    before, new_seconds = _timed(lambda: ui.windows(machine, step))
    old, old_seconds = _timed(lambda: ui.ask(machine, _script(_WINDOWS, process=ui.PROCESS), step, seconds=OLD_SECONDS))
    old_titles = [name.strip() for name in old.split(",") if name.strip()]
    comparison.add(screen, "uDeck's windows (ui.windows)", old_titles, before, old_seconds, new_seconds,
                   ax.differences([(t,) for t in old_titles], [(t,) for t in before], "window"))  # fmt: skip
    if window_titles_must_include not in before:
        raise LabError(step, f"'{window_titles_must_include}' is not among uDeck's windows: {before}")
    new_menu, new_seconds = _timed(lambda: ui.menu_items(machine, step))
    old_menu, old_seconds = _timed(lambda: ui.ask(machine, _script(_MENU_ITEMS, process=ui.PROCESS), step, seconds=OLD_SECONDS))
    # System Events wrote a separator's missing name as "missing value".
    old_menu = ", ".join("" if part == "missing value" else part for part in old_menu.split(", "))
    comparison.add(screen, "uDeck's menu (ui.menu_items)", None, None, old_seconds, new_seconds,
                   [] if old_menu == new_menu else [f"System Events {old_menu!r}, the helper {new_menu!r}"])  # fmt: skip


def compare_another_applications_window(machine, comparison, check_dir):
    """`probes.typed_into` and `probes.move_window`, on TextEdit, as the panel checks use them."""
    document = "/tmp/udeck-e2e-ax-equality.txt"
    machine.ssh.run(f"printf 'what the lab wrote\\nin two lines' > {document} && open -a TextEdit {document}", "opening a document")
    deadline = machine.clock() + config.FORWARD_SECONDS
    while True:
        try:
            new, new_seconds = _timed(lambda: probes.typed_into(machine, "TextEdit", "reading the document"))
            break
        except LabError:
            if machine.clock() >= deadline:
                raise
            machine.sleep(1)
    old, old_seconds = _timed(lambda: ui.ask(machine, _script(_TEXT_OF, process="TextEdit"), "reading the document"))
    comparison.add("TextEdit", "what the document holds (probes.typed_into)", None, None, old_seconds, new_seconds,
                   [] if old == new else [f"System Events {old!r}, the helper {new!r}"])  # fmt: skip
    _, new_seconds = _timed(lambda: probes.move_window(machine, "TextEdit", (300, 300), "moving the window"))
    old, old_seconds = _timed(lambda: ui.ask(machine, _script(_POSITION_OF, process="TextEdit"), "reading where it is"))
    comparison.add("TextEdit", "the window moved (probes.move_window)", None, None, old_seconds, new_seconds,
                   [] if old.replace(" ", "") == "300,300" else [f"System Events reads the window at {old!r} after the helper put it at 300, 300"])  # fmt: skip
    machine.ssh.run(f"pkill -x TextEdit; rm -f {document}", "closing the document", check=False)


def _plugin_checks():
    """`checks/check_plugins.py`, for the screens it makes: its scene, its plugin of the lab's own, its panel."""
    path = Path(__file__).resolve().parents[1] / "checks" / "check_plugins.py"
    spec = importlib.util.spec_from_file_location("check_plugins_for_the_selfcheck", path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


# How long the card of the second check lasts and how often it runs by itself:
# longer than the check, so that it runs only when the panel is revealed or
# refreshed, and both readers read the card the lab made.
STILL_SECONDS = 3600


GUEST_FACTS = (
    "id; echo \"shell: $0, SHELL=$SHELL\"; dscl . -read /Users/$(id -un) UserShell; "
    "echo '--- the environment a command over SSH has'; env | sort; "
    "echo '--- who is responsible for it'; ps -o pid,ppid,comm -p $$ -p $PPID; "
    "echo '--- the system TCC database'; "
    "sudo -n sqlite3 '/Library/Application Support/com.apple.TCC/TCC.db' "
    "'select service, client, client_type, auth_value, auth_reason from access order by client, service'; "
    "echo '--- the user TCC database'; "
    "sudo -n sqlite3 \"$HOME/Library/Application Support/com.apple.TCC/TCC.db\" "
    "'select service, client, client_type, auth_value, auth_reason from access order by client, service'; true"
)


def check_the_helper_reads_what_system_events_read(machine, check_dir, lab):
    comparison = Comparison(check_dir, lab.note)
    facts = machine.ssh.run(GUEST_FACTS, "reading the guest's own facts", check=False)
    comparison.keep("guest-facts.txt", (facts.stdout or "") + (facts.stderr or ""))
    trusted = ax.ask(machine, ["trusted"], "asking whether the helper is trusted")
    comparison.keep("helper-trusted.json", json.dumps(trusted))

    feed = updates.Feed(machine, lab.note)
    build = lab.builder(feed.url, check_dir.name).build(*VERSION)
    app.install(machine, build.zip, lab.note)
    machine.ssh.run("rm -rf ~/.udeck", "starting from a uDeck nothing has configured")
    github = plugin_repository.FakeGitHub(machine, lab.note)
    github.serve(check_dir, main="c1")
    try:
        app.launch(machine)
        ui.open_settings_and_wait(machine, "opening the settings")
        compare_windows_and_menu(machine, comparison, "Settings open", ui.SETTINGS_WINDOW)
        ui.place_settings(machine, "placing the settings window")
        for section in ("general", "opening", "look", "plugins", "about"):
            ui.click(machine, f"section.{section}", f"choosing {section}")
            machine.sleep(config.SETTLE_SECONDS)
            machine.screenshot(check_dir, f"settings {section}")
            compare_screen(machine, comparison, f"Settings → {section.capitalize()}")

        ui.click(machine, f"section.{ui.PLUGINS}", "choosing Plugins")
        ui.click(machine, "plugins.installFromLink", "opening Install from a link…")
        ui.wait_for(machine, "link.field", "waiting for the link sheet")
        machine.screenshot(check_dir, "the link sheet")
        compare_screen(machine, comparison, "Install from a link… sheet")
        ui.click(machine, "link.close", "closing the link sheet")

        panel.park_in_the_middle(machine)
        panel.press_the_chord(machine, config.HOTKEY_KEY_CODE, "opening the panel")
        ui.wait_for(machine, "panel.settings", "waiting for the panel", ui.PANEL)
        machine.screenshot(check_dir, "the panel")
        compare_screen(machine, comparison, "the panel", window=ui.PANEL, identified_depth=ui.MAX_DEPTH)
        compare_windows_and_menu(machine, comparison, "the panel open", ui.SETTINGS_WINDOW)
        panel.press_the_chord(machine, config.HOTKEY_KEY_CODE, "putting the panel away")
        machine.sleep(config.SETTLE_SECONDS)

        compare_another_applications_window(machine, comparison, check_dir)

        app.quit_app(machine, "quitting uDeck to start it in Russian")
        machine.ssh.run("mkdir -p ~/.udeck && printf '%s' '{\"language\": \"ru\"}' > ~/.udeck/settings.json", "setting uDeck's language to Russian")
        app.launch(machine)
        ru = ui.RUSSIAN
        ui.open_settings_and_wait(machine, "opening the settings in Russian", item=ru.settings_item, window=ru.settings_window)
        ui.place_settings(machine, "placing the settings window", window=ru.settings_window)
        for section in ("general", "plugins"):
            ui.click(machine, f"section.{section}", f"choosing {section} in Russian", ru.settings_window)
            machine.sleep(config.SETTLE_SECONDS)
            machine.screenshot(check_dir, f"ru settings {section}")
            compare_screen(machine, comparison, f"Russian Settings → {section.capitalize()}", window=ru.settings_window)
    finally:
        comparison.write()
        github.stop()
    problems = comparison.problems()
    if problems:
        raise LabError(
            "holding the helper's readings against System Events'",
            f"{len(problems)} of {len(comparison.rows)} readings differ (comparison.txt): " + "; ".join(problems[:5]),
        )


def check_cards_and_questions_read_as_system_events_read(machine, check_dir, lab):
    cp = _plugin_checks()
    comparison = Comparison(check_dir, lab.note)
    plugin, folder = cp.FLAKY, f"{cp.WORK}/{cp.FLAKY}"
    scene = cp._prepare(machine, check_dir, lab, main="c1", launch=False, pulls=cp.PULLS)
    try:
        cp._a_plugin_folder(machine, folder, cp._manifest(plugin, "./run.sh", interval=STILL_SECONDS),
                            {"run.sh": cp._card_script("steady", ttl=STILL_SECONDS, fail_when=cp.FAIL, says=cp.FLAKY_SAYS)})  # fmt: skip
        cp._link_by_hand(machine, folder, plugin)
        cp._place(scene, plugin)

        cp._open_the_panel(machine, "opening the panel on a card that asks")
        allow = ui.wait_for(machine, f"consent.{plugin}.allow", "waiting for the card to ask", ui.PANEL)
        machine.screenshot(check_dir, "the card asks")
        compare_screen(machine, comparison, "the panel — a card asking for consent", window=ui.PANEL, identified_depth=ui.MAX_DEPTH)

        machine.click(*allow.middle, "allowing the plugin")
        cp._read_the_card(scene, plugin, "after Allow", lambda card: card.get(cp.RUNS) not in (None, "", "unknown"))
        compare_screen(machine, comparison, "the panel — the card having run", window=ui.PANEL, identified_depth=ui.MAX_DEPTH)

        machine.ssh.run(f"touch {folder}/{cp.FAIL}", "making the plugin fail")
        ui.click(machine, "panel.refresh", "refreshing the panel", ui.PANEL)
        cp._wait_for_the_card(machine, lambda found, texts: found.get(f"card.{plugin}.failedDot") is not None
                              and any(text.startswith(cp.LAST_RUN_FAILED) for text in texts), cp.CARD_SECONDS)  # fmt: skip
        machine.screenshot(check_dir, "the card after a failed run")
        compare_screen(machine, comparison, "the panel — the card after a failed run", window=ui.PANEL, identified_depth=ui.MAX_DEPTH)
        cp._put_the_panel_away(machine, "after the failed run")

        ui.plugins_pane(machine, "opening Settings → Plugins")
        ui.click(machine, f"plugin.{plugin}.more", "opening More beside the plugin")
        ui.wait_for(machine, f"plugin.{plugin}.stderr", "waiting for the end of its stderr")
        machine.screenshot(check_dir, "More on the failed run")
        compare_screen(machine, comparison, "Settings → Plugins — More on a failed run")

        cp._look_up(scene, cp.PULL_LINK, "the pull request")
        machine.screenshot(check_dir, "the link sheet with a pull request")
        compare_screen(machine, comparison, "Install from a link… sheet — a pull request looked up")
        cp._close_the_link_sheet(scene, "after the comparison")

        ui.click(machine, f"plugin.{plugin}.remove", "pressing Remove")
        ui.wait_for(machine, f"plugin.{plugin}.confirmText", "waiting for the question Remove asks")
        machine.screenshot(check_dir, "the question before Remove")
        compare_screen(machine, comparison, "Settings → Plugins — the question before Remove")
    finally:
        comparison.write()
        scene.close()
    problems = comparison.problems()
    if problems:
        raise LabError(
            "holding the helper's readings of the plugin screens against System Events'",
            f"{len(problems)} of {len(comparison.rows)} readings differ (comparison.txt): " + "; ".join(problems[:5]),
        )
