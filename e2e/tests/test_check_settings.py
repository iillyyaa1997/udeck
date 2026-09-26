"""The settings checks: was it saved, was it read back, and was it acted on at once?

Three different failures hide behind "the setting works", and the question asked
of every test here is which of them it would still be green over. A uDeck that
never writes the file loses the change at the next launch; one that writes it
and reads the default back loses it just as completely and says nothing about
it; and one that does both and never tells the running application leaves the
operator with a shortcut that starts working tomorrow. Each check has to be red
for the ones it claims, and each test below removes exactly one thing.

And from the lab's side: the change has to be made *in the window*. A test that
let a check write the file itself would be testing `JSONFileStore` against a
settings screen wired to nothing, which is the half of this feature a person
actually touches — so the first test of each check asserts that nothing here
ever wrote a value into `~/.udeck/settings.json`. Taking away the file a
neighbouring check left behind is the one exception, it happens before uDeck is
started, and it has a test of its own (`wrote_the_file`).

And the click has to have *landed*: a test where the screen reads the same
after the press as before it asks for the lab's failure, not a verdict, because
a miss that nobody read comes back as "the operator's change is nowhere" about
a uDeck nothing was ever asked of.
"""

import importlib.util
import json
import sys
from pathlib import Path

import pytest
from fakes import Dropped, Lab, Machine

from udeck_e2e import app, config, panel, ui
from udeck_e2e.errors import CheckFailed, LabError


def _load():
    path = Path(__file__).resolve().parents[1] / "checks" / "check_settings.py"
    spec = importlib.util.spec_from_file_location("check_settings_under_test", path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


checks = _load()


# --- What the guest says ---------------------------------------------------------------

ATTACHED = "Timestamp               Ty Process[PID:TID]\n"
KEEPING = "Mode for 'place.unicorns.udeck'  DEBUG PERSIST_DEBUG"


def _said(category, text):
    return f"18:20:00.001 Db uDeck[404] [place.unicorns.udeck:{category}] {text}\n"


REGISTERED = _said("panel", f"hotkey {config.THE_HOTKEY} registered")
REGISTERED_NEW = _said("panel", f"hotkey {config.THE_NEW_HOTKEY} registered")
REVEAL = _said("panel", "collapsed -> peek on revealRequested")
PROMOTED = _said("panel", "peek -> open on interacted")
OPENED_BY_THE_CHORD = REVEAL + PROMOTED
# The workspace's news of another application, which both halves of the switch
# carry: it is what says uDeck was told at all.
NEWS = _said(
    "panel",
    "another application came forward 3630 ms after the last click, with the pointer past the panel, "
    "so the panel counts it as a switch",
)
RETRACTED = NEWS + _said("panel", "open -> collapsed on otherAppActivated")
STAYED = NEWS + _said("panel", "otherAppActivated ignored in open")
# The same news with the panel taken away and nothing saying it was: a uDeck
# that heard nothing looks like a uDeck that obeyed the switch.
HEARD_NOTHING = _said("gesture", "idle: alreadyFiredThisVisit")
NOTHING = ""


def growing(*steps):
    """The guest's log as a check fills it: each read sees one step more than the last.

    Cumulative, because that is what `log show` from one mark hands back, and the
    last entry answers every read after it — which is how a step that waits out
    its whole window is written here.
    """
    text = ATTACHED
    answers = []
    for step in steps:
        text += step
        answers.append(text)
    return answers


def saved(**over):
    """uDeck's settings file as it writes it: every key, every time.

    All thirteen top-level keys, which is what one click on one control wrote in
    every file these checks have left — 1921 bytes for the switch and 1935 for
    the shortcut, on 2026-09-25 and again on 2026-09-26
    (.build/e2e/20260926-142454Z). A file holding only the key that was clicked
    is *not* a file uDeck wrote, and one of the checks' verdicts is about
    exactly that, so the fake has to be able to be both.

    The nested values are sketches of the real ones: nothing here reads inside
    `theme`, `look`, `gesture` or `panel`, and the last two are `{}` in the real
    file anyway when nothing in them has been changed.
    """
    settings = {
        "version": 1,
        "density": "normal",
        "gesture": {},
        "panel": {},
        "hotkey": {"enabled": True, "key": "U", "modifiers": ["option", "control"]},
        "theme": {"source": "system", "manualIsDark": False},
        "look": {"ink": "dark", "presence": 1},
        "resolvedIsDark": False,
        "collapseOnAppSwitch": True,
        "defaultCardTTL": 60,
        "silentTTLMultiplier": 3,
        "pluginExecutableSearchPath": ["/usr/local/bin", "/opt/homebrew/bin"],
        "pollWhileCollapsed": False,
    }
    settings.update(over)
    return json.dumps(settings)


def saved_without(key, **over):
    """The same file with one key gone — a uDeck whose encoder dropped it."""
    settings = json.loads(saved(**over))
    del settings[key]
    return json.dumps(settings)


THE_SWITCH_OFF = saved(collapseOnAppSwitch=False)
THE_NEW_SHORTCUT = saved(hotkey={"enabled": True, "key": "U", "modifiers": ["shift", "option", "control"]})


# The Opening screen as the walk reads it, taken from the run that measured it
# (.build/e2e/20260925-005230Z, settings.survey/tree-opening.txt). Not one of
# these controls carries an identifier, a title or a description: the four
# `AXToggle` checkboxes are the shortcut's modifiers, left to right, and the
# four plain ones are the switches, top to bottom.
OPENING_TREE = "\n".join([
    "0|AXWindow|AXStandardWindow||uDeck Settings|||790;198;|980;648;",
    "8|AXStaticText||section.opening||Opening||807;269;|77;18;",
    "5|AXStaticText||||Gesture||1063;246;|48;16;",
    "5|AXCheckBox||||1||1124;246;|328;16;",
    "5|AXSlider||||0.08||1124;272;|230;20;",
    "5|AXStaticText||||Shortcut||1058;377;|53;16;",
    "5|AXCheckBox||||1||1124;377;|205;16;",
    "5|AXCheckBox|AXToggle|||1||1124;403;|28;20;",
    "5|AXCheckBox|AXToggle|||1||1160;403;|29;20;",
    "5|AXCheckBox|AXToggle|||0||1197;403;|29;20;",
    "5|AXCheckBox|AXToggle|||0||1234;403;|28;20;",
    "5|AXPopUpButton||||U||1270;403;|110;20;",
    "5|AXCheckBox||||1||1124;448;|303;16;",
    "5|AXCheckBox||||1||1124;470;|221;16;",
    "1|AXButton|AXCloseButton|||||800;205;|12;14;",
])  # fmt: skip

# Where a click on the retract switch and on the shift modifier has to land,
# from that same walk: the middle of the third plain checkbox and of the third
# toggle.
THE_RETRACT_SWITCH = (1124 + 303 // 2, 448 + 16 // 2)
THE_SHIFT_BUTTON = (1197 + 29 // 2, 403 + 20 // 2)

# And the same screen after each of those clicks has landed, which is what the
# lab walks the screen again to see (`ui.press`): a click that changed nothing
# is the lab having missed the control, and must not travel into a verdict
# about what uDeck saved.
THE_SWITCH_PRESSED = OPENING_TREE.replace("5|AXCheckBox||||1||1124;448;|303;16;",
                                          "5|AXCheckBox||||0||1124;448;|303;16;")
THE_SHIFT_PRESSED = OPENING_TREE.replace("5|AXCheckBox|AXToggle|||0||1197;403;|29;20;",
                                         "5|AXCheckBox|AXToggle|||1||1197;403;|29;20;")


def a_machine(log_says, settings_says, running="404", in_front=None, pressed=THE_SWITCH_PRESSED):
    return Machine({
        "log show": log_says,
        "log config": KEEPING,
        "date ": "2026-09-18 18:20:00",
        "pgrep -x uDeck": running,
        "stat -f %Su": config.GUEST_USER,
        "cat ~/.udeck": settings_says,
        "on attr(": [OPENING_TREE, pressed],
        "on findIt(": "935,226,144,28",
        "click menu item": "opened",
        "get name of every window": ui.SETTINGS_WINDOW,
        # TextEdit before each panel, the Finder brought over it: one answer per
        # question, the last repeating.
        "frontmost is true": in_front or [
            config.IN_FRONT_BEFORE_THE_PANEL, config.THE_DESKTOP,
            config.IN_FRONT_BEFORE_THE_PANEL, config.THE_DESKTOP,
        ],
    })  # fmt: skip


@pytest.fixture
def lab(tmp_path):
    return Lab(tmp_path)


@pytest.fixture
def check_dir(tmp_path):
    path = tmp_path / "settings.a-switch-survives-a-restart"
    path.mkdir()
    return path


@pytest.fixture(autouse=True)
def nothing_real(monkeypatch):
    """No machine and no build, and uDeck goes away when it is asked to.

    `quit_app` is the one thing stubbed rather than answered: it reads the pid
    list until it is empty, and a fake that made the same question mean two
    things at two moments would be answering the check's *other* readings of it
    as well. What quitting does has its own tests, in `test_app`.
    """
    monkeypatch.setattr(app, "installed_version", lambda machine: checks.VERSION)
    quits = []
    monkeypatch.setattr(app, "quit_app", lambda machine, step, **kw: quits.append(step))
    return quits


def prepared(monkeypatch, machine):
    """Skip the preparation — its own tests are at the end — and hand back the log."""

    def prepare(machine_, check_dir, lab, launch=True):
        machine_.prepared_with_launch = launch
        kept = panel.GestureLog(machine_, lab.note)
        kept.kept = True
        if launch:
            app.launch(machine_)
        return kept

    monkeypatch.setattr(checks, "_prepare", prepare)
    return machine


def wrote_the_file(machine):
    """Whether anything in the check put a value into the settings file itself.

    Two things may touch that path and neither of them chooses a setting:
    reading it, which is half of every verdict here, and taking away the one a
    neighbouring check left behind, which `_prepare` does before uDeck starts
    (`app.forget_settings`). Anything else is the lab writing the operator's
    change instead of clicking it.
    """
    return [
        c for c in machine.ssh.commands
        if app.SETTINGS_FILE in c and "cat " not in c and "rm -f " not in c
    ]  # fmt: skip


# --- The switch -------------------------------------------------------------------------

# The scene made twice with the change in between: a peek, a click into it, the
# interruption — and then the same again once uDeck has been restarted, where
# the last entry answers every read the ten-second watch makes.
#
# Made afresh per test rather than kept in a constant: the fake guest answers a
# list by taking from it, so a shared one would leave the next test reading
# whatever the last one did not use.
def a_switch_that_held():
    return growing(REVEAL, PROMOTED, RETRACTED, NOTHING, NOTHING, NOTHING, REVEAL, PROMOTED, STAYED)


def a_switch_that_did_not():
    return growing(REVEAL, PROMOTED, RETRACTED, NOTHING, NOTHING, NOTHING, REVEAL, PROMOTED, RETRACTED)


def test_a_switch_turned_off_in_the_window_is_still_off_after_uDeck_is_restarted(
    monkeypatch, lab, check_dir, nothing_real
):
    machine = prepared(monkeypatch, a_machine(a_switch_that_held(), ["", THE_SWITCH_OFF]))
    checks.check_a_switch_survives_a_restart(machine, check_dir, lab)

    # The change was made where the operator makes it: a click on the third
    # plain checkbox of the Opening screen, and nothing wrote the file.
    assert THE_RETRACT_SWITCH in [(x, y) for x, y, _ in machine.clicks]
    assert wrote_the_file(machine) == []
    # And uDeck really was ended in between, or the second half asks nothing.
    assert nothing_real, "uDeck has to be restarted between the two halves"
    assert (check_dir / "settings.json").read_text() == THE_SWITCH_OFF


def test_a_switch_the_operator_turned_off_and_uDeck_never_saved_fails(monkeypatch, lab, check_dir):
    """The file is the half that survives uDeck, and there is no file at all.

    The behaviour afterwards is uDeck's own doing in this run — it applied the
    change it never wrote — so a check reading only what the panel did would be
    green over a machine that forgets the setting the moment it is closed.
    """
    machine = prepared(monkeypatch, a_machine(a_switch_that_held(), ""))
    with pytest.raises(CheckFailed, match="is still not there") as raised:
        checks.check_a_switch_survives_a_restart(machine, check_dir, lab)
    assert machine.now >= config.SETTINGS_SAVE_SECONDS
    # And uDeck kept quiet about it, which is half of what the verdict says.
    assert "never said it could not save" in str(raised.value)


# What uDeck writes when the store refuses it: `DeckModel.save` → `record` →
# `DeckLog.plugins.error`. The `plugins` category, which is why the window both
# checks read keeps more than the panel's and the gesture's.
COULD_NOT_SAVE = _said(
    "plugins",
    'could not save the settings: Error Domain=NSCocoaErrorDomain Code=513 "You don’t have permission"',
)


def test_a_uDeck_that_says_it_could_not_save_is_not_a_uDeck_that_did_not_try(monkeypatch, lab, check_dir):
    """Both leave the same empty place where the file should be, and they are two
    different people's problem: a home directory that cannot be written is the
    machine's, a control that asks nothing to be saved is uDeck's. uDeck says
    which, and the verdict repeats what it said."""
    # The scene, the window, and then the line uDeck writes instead of the file.
    said = growing(REVEAL, PROMOTED, RETRACTED, NOTHING, COULD_NOT_SAVE)
    machine = prepared(monkeypatch, a_machine(said, ""))
    with pytest.raises(CheckFailed, match="is still not there") as raised:
        checks.check_a_switch_survives_a_restart(machine, check_dir, lab)
    assert "uDeck said it could not" in str(raised.value)
    assert "NSCocoaErrorDomain Code=513" in str(raised.value)


def test_the_shortcut_check_says_it_too(monkeypatch, lab, check_dir):
    """The same sentence about the same absence, from the other check."""
    said = growing(REGISTERED, NOTHING, REGISTERED_NEW, COULD_NOT_SAVE)
    machine = prepared(monkeypatch, a_shortcut_machine(said, ""))
    with pytest.raises(CheckFailed, match="is still not there") as raised:
        checks.check_the_shortcut_changes_at_once_and_survives(machine, check_dir, lab)
    assert "uDeck said it could not" in str(raised.value)


def test_a_click_that_landed_on_nothing_is_the_labs_failure_and_not_a_verdict(monkeypatch, lab, check_dir):
    """The screen after the click reads exactly what it read before it.

    That is the lab having missed the control — a window that moved, a pane
    still being laid out, a pointer that did not arrive — and unread it travels:
    the settings file holds nothing, and the check pronounces "the operator's
    change is nowhere" about a uDeck that was never asked for one.
    """
    for check, machine in (
        (checks.check_a_switch_survives_a_restart,
         a_machine(a_switch_that_held(), ["", THE_SWITCH_OFF], pressed=OPENING_TREE)),
        (checks.check_the_shortcut_changes_at_once_and_survives,
         a_machine(a_shortcut_that_held(), ["", THE_NEW_SHORTCUT], pressed=OPENING_TREE)),
    ):
        with pytest.raises(LabError, match="the click did not land on it") as raised:
            check(prepared(monkeypatch, machine), check_dir, lab)
        assert not isinstance(raised.value, CheckFailed), check.__name__


def test_a_file_that_lost_the_keys_the_operator_never_touched_fails(monkeypatch, lab, check_dir):
    """uDeck saved what was clicked and dropped the rest.

    The quietest failure this file has: what a settings file does not say is
    read back as the shipped default (`AppSettings.init(from:)`), so the
    operator's theme comes back as uDeck's own at the next launch with nothing
    anywhere saying it had gone. A check that read back only the key it clicked
    is green over exactly that.
    """
    lost = saved_without("theme", collapseOnAppSwitch=False)
    machine = prepared(monkeypatch, a_machine(a_switch_that_held(), ["", lost]))
    with pytest.raises(CheckFailed, match="has no theme in it") as raised:
        checks.check_a_switch_survives_a_restart(machine, check_dir, lab)
    assert "silently reset" in str(raised.value)

    forgot = saved_without("panel", hotkey={"enabled": True, "key": "U",
                                            "modifiers": ["shift", "option", "control"]})
    machine = prepared(monkeypatch, a_shortcut_machine(a_shortcut_that_held(), ["", forgot]))
    with pytest.raises(CheckFailed, match="has no panel in it"):
        checks.check_the_shortcut_changes_at_once_and_survives(machine, check_dir, lab)


def test_a_file_where_a_setting_nobody_touched_moved_fails(monkeypatch, lab, check_dir):
    """A key that is there holding something else is the same loss as a key that
    is gone, and one press of one control may not move a second setting."""
    moved = saved(collapseOnAppSwitch=False, density="cozy")
    machine = prepared(monkeypatch, a_machine(a_switch_that_held(), ["", moved]))
    with pytest.raises(CheckFailed, match="a setting nobody touched moved with it") as raised:
        checks.check_a_switch_survives_a_restart(machine, check_dir, lab)
    assert "'density': 'cozy'" in str(raised.value)


def test_a_file_that_says_the_switch_is_still_on_fails(monkeypatch, lab, check_dir):
    """uDeck saved, and saved the wrong thing — the control was clicked and the
    value did not move."""
    machine = prepared(monkeypatch, a_machine(a_switch_that_held(), ["", saved()]))
    with pytest.raises(CheckFailed, match="not what the operator chose"):
        checks.check_a_switch_survives_a_restart(machine, check_dir, lab)


def test_a_restarted_uDeck_that_retracts_the_panel_anyway_fails(monkeypatch, lab, check_dir):
    """The file is perfect and the new uDeck never read it. This is the half no
    reading of the file can reach, and it is the whole reason the check makes the
    scene a second time."""
    machine = prepared(monkeypatch, a_machine(a_switch_that_did_not(), ["", THE_SWITCH_OFF]))
    with pytest.raises(CheckFailed, match="taken away anyway"):
        checks.check_a_switch_survives_a_restart(machine, check_dir, lab)


def test_a_switch_that_does_nothing_with_the_setting_on_fails_before_the_change(monkeypatch, lab, check_dir):
    """The control, and it is the reason "the panel stayed" means anything later.

    With the switch as uDeck ships it, a held panel has to go away when another
    application comes forward. A machine where it never does is a machine where
    the second half is green for nothing.
    """
    machine = prepared(monkeypatch, a_machine(growing(REVEAL, PROMOTED, STAYED), ["", THE_SWITCH_OFF]))
    with pytest.raises(CheckFailed, match="did not close the panel"):
        checks.check_a_switch_survives_a_restart(machine, check_dir, lab)


def test_a_switch_uDeck_was_never_told_about_proves_nothing_either_way(monkeypatch, lab, check_dir):
    """A panel that stayed because nothing came forward is not a setting obeyed.

    `open -a` for an application that is already in front brings nothing
    forward and the workspace posts nothing, so the log is silent for the same
    reason a setting being obeyed is — and that is the lab failing to make the
    scene, never a verdict.
    """
    silent = growing(REVEAL, PROMOTED, RETRACTED, NOTHING, NOTHING, NOTHING, REVEAL, PROMOTED, HEARD_NOTHING)
    machine = prepared(monkeypatch, a_machine(silent, ["", THE_SWITCH_OFF]))
    with pytest.raises(LabError, match="never told uDeck") as raised:
        checks.check_a_switch_survives_a_restart(machine, check_dir, lab)
    assert not isinstance(raised.value, CheckFailed)


def test_a_uDeck_that_died_while_the_panel_was_watched_is_uDecks_failure(monkeypatch, lab, check_dir):
    """The rule every stretch of quiet in this lab keeps: it was started, it was
    watched, and it is gone. A panel stays put for free once nothing can show it."""
    machine = prepared(monkeypatch, a_machine(a_switch_that_held(), ["", THE_SWITCH_OFF]))
    # The third reading is the witness after the watch: uDeck is started once
    # before the change and once after it, and then asked whether it is still
    # there at the end of the stretch that was supposed to change nothing.
    machine.ssh.answers["pgrep -x uDeck"] = ["404", "404", ""]
    with pytest.raises(CheckFailed, match="died in the middle of it"):
        checks.check_a_switch_survives_a_restart(machine, check_dir, lab)


# --- The shortcut -----------------------------------------------------------------------


def a_shortcut_machine(log_says, settings_says, **rest):
    """The same guest, walking back a screen where the *shift* button was pressed."""
    return a_machine(log_says, settings_says, pressed=THE_SHIFT_PRESSED, **rest)


# Launch, the window, the change, the old chord's silence, the new chord, the
# restart, and the new chord again.
def a_shortcut_that_held():
    return growing(
        REGISTERED, NOTHING, REGISTERED_NEW, NOTHING, OPENED_BY_THE_CHORD,
        NOTHING, REGISTERED_NEW, OPENED_BY_THE_CHORD,
    )


def test_a_shortcut_changed_in_the_window_works_at_once_and_after_a_restart(
    monkeypatch, lab, check_dir, nothing_real
):
    machine = prepared(monkeypatch, a_shortcut_machine(a_shortcut_that_held(), ["", THE_NEW_SHORTCUT]))
    checks.check_the_shortcut_changes_at_once_and_survives(machine, check_dir, lab)

    assert THE_SHIFT_BUTTON in [(x, y) for x, y, _ in machine.clicks]
    assert wrote_the_file(machine) == []
    assert nothing_real, "uDeck has to be restarted before the last half"
    # Both combinations, made the same way, so that what the control controls
    # for is the combination and not how the lab presses it — and the new one
    # twice, once in the uDeck that was told and once in the one that read it.
    held = [
        c.split("using {")[1].split("}")[0]
        for c in machine.ssh.commands
        if f"key code {config.HOTKEY_KEY_CODE} using" in c
    ]
    assert held == [
        "control down, option down",
        "control down, option down, shift down",
        "control down, option down, shift down",
    ]
    assert machine.keys == [], "the chord is never a key over VNC"


def test_a_running_uDeck_that_never_took_the_new_combination_fails(monkeypatch, lab, check_dir):
    """The file is written and the window server was never told.

    This is the failure nothing else in the lab can see: `settingsChanged`
    without `hotKeys.apply` writes a perfect settings file in the same fraction
    of a second as ever, and every reading of that file is green.
    """
    # It stops where uDeck stops saying anything: every read after the last
    # entry sees the same window, which is what a uDeck with nothing to add
    # looks like.
    never = growing(REGISTERED, NOTHING, NOTHING)
    machine = prepared(monkeypatch, a_shortcut_machine(never, ["", THE_NEW_SHORTCUT]))
    with pytest.raises(CheckFailed, match="uDeck says it holds") as raised:
        checks.check_the_shortcut_changes_at_once_and_survives(machine, check_dir, lab)
    assert config.THE_NEW_HOTKEY in str(raised.value)


def test_a_shortcut_the_operator_chose_and_uDeck_never_saved_fails(monkeypatch, lab, check_dir):
    machine = prepared(monkeypatch, a_shortcut_machine(a_shortcut_that_held(), ""))
    with pytest.raises(CheckFailed, match="is still not there"):
        checks.check_the_shortcut_changes_at_once_and_survives(machine, check_dir, lab)


def test_a_file_that_says_the_old_combination_fails(monkeypatch, lab, check_dir):
    """uDeck took the new one and wrote down the old one, so tomorrow it is gone."""
    machine = prepared(monkeypatch, a_shortcut_machine(a_shortcut_that_held(), ["", saved()]))
    with pytest.raises(CheckFailed, match="is not what the operator chose") as raised:
        checks.check_the_shortcut_changes_at_once_and_survives(machine, check_dir, lab)
    assert config.THE_HOTKEY in str(raised.value)


def test_an_old_combination_that_still_opens_the_panel_fails(monkeypatch, lab, check_dir):
    """The new registration was taken and the old one never given back.

    While it stands the window server delivers that key to uDeck and to nobody
    else, so the operator has lost it everywhere — and this is the only check in
    the lab that can see `HotKeyMonitor.unregister` do its work.
    """
    still_live = growing(REGISTERED, NOTHING, REGISTERED_NEW, OPENED_BY_THE_CHORD)
    machine = prepared(monkeypatch, a_shortcut_machine(still_live, ["", THE_NEW_SHORTCUT]))
    with pytest.raises(CheckFailed, match="still moved the panel"):
        checks.check_the_shortcut_changes_at_once_and_survives(machine, check_dir, lab)


def test_a_new_combination_that_opens_nothing_fails(monkeypatch, lab, check_dir):
    """And that is what makes the old one's silence worth reading: a uDeck that
    hears no chord at all is silent for both."""
    deaf = growing(REGISTERED, NOTHING, REGISTERED_NEW, NOTHING, NOTHING)
    machine = prepared(monkeypatch, a_shortcut_machine(deaf, ["", THE_NEW_SHORTCUT]))
    with pytest.raises(CheckFailed, match="did not open the panel"):
        checks.check_the_shortcut_changes_at_once_and_survives(machine, check_dir, lab)


def test_a_new_combination_that_leaves_only_a_glance_fails(monkeypatch, lab, check_dir):
    """A shortcut has to leave a panel ready to be typed into, here as everywhere."""
    a_glance = growing(REGISTERED, NOTHING, REGISTERED_NEW, NOTHING, REVEAL)
    machine = prepared(monkeypatch, a_shortcut_machine(a_glance, ["", THE_NEW_SHORTCUT]))
    with pytest.raises(CheckFailed, match="moved the panel"):
        checks.check_the_shortcut_changes_at_once_and_survives(machine, check_dir, lab)


def test_a_restarted_uDeck_that_holds_the_combination_it_replaced_fails(monkeypatch, lab, check_dir):
    """Saved, applied, and read back as the default: the operator loses his
    choice every time he closes his laptop, and the file says he never should."""
    forgot = growing(REGISTERED, NOTHING, REGISTERED_NEW, NOTHING, OPENED_BY_THE_CHORD,
                     NOTHING, REGISTERED)
    machine = prepared(monkeypatch, a_shortcut_machine(forgot, ["", THE_NEW_SHORTCUT]))
    with pytest.raises(CheckFailed, match="uDeck says it holds") as raised:
        checks.check_the_shortcut_changes_at_once_and_survives(machine, check_dir, lab)
    assert config.THE_HOTKEY in str(raised.value)


def test_a_restarted_uDeck_whose_combination_opens_nothing_fails(monkeypatch, lab, check_dir):
    """It says it holds the combination and the panel never comes: the line at
    launch is the premise, not the verdict."""
    silent = growing(REGISTERED, NOTHING, REGISTERED_NEW, NOTHING, OPENED_BY_THE_CHORD,
                     NOTHING, REGISTERED_NEW, NOTHING)
    machine = prepared(monkeypatch, a_shortcut_machine(silent, ["", THE_NEW_SHORTCUT]))
    with pytest.raises(CheckFailed, match="did not open the panel"):
        checks.check_the_shortcut_changes_at_once_and_survives(machine, check_dir, lab)


# --- What neither of them may turn into a verdict ----------------------------------------


def test_a_log_neither_check_can_read_is_not_a_setting_that_did_nothing(monkeypatch, lab, check_dir):
    """An empty answer and a uDeck that did nothing are the same text, and only
    one of them is about uDeck."""
    for check in (checks.check_a_switch_survives_a_restart,
                  checks.check_the_shortcut_changes_at_once_and_survives):
        machine = prepared(monkeypatch, a_machine(Dropped, ["", THE_SWITCH_OFF]))
        with pytest.raises(LabError, match="SSH") as raised:
            check(machine, check_dir, lab)
        assert not isinstance(raised.value, CheckFailed), check.__name__


def test_a_settings_file_that_cannot_be_read_is_not_a_setting_uDeck_never_saved(monkeypatch, lab, check_dir):
    """The file read goes through `ask`, so a dropped connection raises instead of
    coming back as "uDeck wrote nothing" — which is a verdict."""
    machine = prepared(monkeypatch, a_machine(a_switch_that_held(), Dropped))
    with pytest.raises(LabError, match="SSH") as raised:
        checks.check_a_switch_survives_a_restart(machine, check_dir, lab)
    assert not isinstance(raised.value, CheckFailed)


# --- Preparing --------------------------------------------------------------------------


def a_fresh_machine(settings_says=""):
    return Machine({
        "log show": ATTACHED,
        "log config": KEEPING,
        "date ": "2026-09-18 18:20:00",
        "pgrep -x uDeck": "404",
        "stat -f %Su": config.GUEST_USER,
        "cat ~/.udeck": settings_says,
    })  # fmt: skip


def test_a_settings_file_the_check_before_left_behind_is_taken_away_first(lab, check_dir, monkeypatch):
    """On a shared machine (--vm per-group, per-run) the check before this one
    leaves a settings file, and what is read out of it afterwards would not be
    this check's own change.

    Refusing the machine made the second check of the group impossible in the
    two modes the README recommends for a group, so it is removed instead —
    before uDeck starts, and with the install above having quit the uDeck that
    was running. Removing is the one thing the lab does to that file: the change
    itself is still a click in uDeck's own window.
    """
    monkeypatch.setattr(app, "installed_version", lambda machine: checks.VERSION)
    machine = a_fresh_machine([saved(), ""])
    checks._prepare(machine, check_dir, lab)

    touched = [c for c in machine.ssh.commands if app.SETTINGS_FILE in c]
    assert [c for c in touched if "rm -f" in c] != [], "the file a neighbour left has to go"
    assert all("cat " in c or "rm -f" in c for c in touched), "nothing may write a value into it"
    removed = next(i for i, c in enumerate(machine.ssh.commands) if "rm -f" in c)
    launched = next(i for i, c in enumerate(machine.ssh.commands) if "open -a" in c)
    assert removed < launched, "a live uDeck would write the file back from memory"
    assert any("taking it away" in note for note in lab.notes)


def test_a_settings_file_that_will_not_go_away_is_the_labs_failure(lab, check_dir, monkeypatch):
    """And the machine still cannot answer, which is the lab's to say — the check
    would otherwise read the neighbour's file as the operator's own change."""
    monkeypatch.setattr(app, "installed_version", lambda machine: checks.VERSION)
    machine = a_fresh_machine(saved())
    with pytest.raises(LabError, match="still there after the lab removed it") as raised:
        checks._prepare(machine, check_dir, lab)
    assert not isinstance(raised.value, CheckFailed)


def test_the_guest_is_keeping_uDecks_messages_before_uDeck_is_launched(lab, check_dir, monkeypatch):
    """The line saying which combination uDeck took is written once, at launch."""
    monkeypatch.setattr(app, "installed_version", lambda machine: checks.VERSION)
    machine = a_fresh_machine()
    checks._prepare(machine, check_dir, lab)
    kept = next(i for i, c in enumerate(machine.ssh.commands) if "log config" in c)
    launched = next(i for i, c in enumerate(machine.ssh.commands) if "open -a" in c)
    assert kept < launched


def test_the_shortcut_check_reads_the_launch_line_because_it_starts_uDeck_itself(
    monkeypatch, lab, check_dir, nothing_real
):
    """`_prepare(launch=False)`, then park, then launch: the window on the log has
    to be open before the only line that says which shortcut uDeck holds."""
    machine = prepared(monkeypatch, a_shortcut_machine(a_shortcut_that_held(), ["", THE_NEW_SHORTCUT]))
    checks.check_the_shortcut_changes_at_once_and_survives(machine, check_dir, lab)
    assert machine.prepared_with_launch is False
    assert machine.pointer[0][:2] == panel.middle_of_the_screen()


# --- How the file is read ----------------------------------------------------------------


def test_the_shortcut_is_read_out_of_the_file_the_way_uDeck_spells_it():
    """The file keeps the modifiers as an unordered set, and uDeck writes them in
    macOS's order — so the order is put back rather than taken from the file."""
    scrambled = {"hotkey": {"key": "u", "modifiers": ["shift", "option", "control"]}}
    assert checks._hotkey_in(scrambled) == config.THE_NEW_HOTKEY
    assert checks._hotkey_in({"hotkey": {"key": "U", "modifiers": ["option", "control"]}}) == config.THE_HOTKEY
    # A file with no shortcut in it says so, rather than reading as some chord.
    assert checks._hotkey_in({}) == "(no shortcut in the file)"
    assert checks._hotkey_in(None) == "(no shortcut in the file)"


def test_the_switch_is_read_out_of_the_file_and_a_missing_key_is_not_a_false():
    assert checks._says(json.loads(THE_SWITCH_OFF)) is False
    assert checks._says(json.loads(saved())) is True
    # `None` and `False` are different answers: uDeck writes every key whenever
    # it saves at all, so a file without this one is not a file it wrote here.
    assert checks._says({}) is None
    assert checks._says(None) is None


def test_the_lab_installing_the_wrong_version_is_not_a_verdict_about_uDeck(monkeypatch, lab, check_dir):
    """A check that drove the copy something else left behind would be a check
    about the wrong application, and that is the lab's mistake."""
    monkeypatch.setattr(app, "installed_version", lambda machine_: ("0.4.2", "7"))
    with pytest.raises(LabError, match="the lab installed") as raised:
        checks._prepare(a_fresh_machine(), check_dir, lab)
    assert not isinstance(raised.value, CheckFailed)


def test_what_uDeck_said_is_kept_even_when_a_check_fails(monkeypatch, lab, check_dir):
    """The story and the settings file both, because a check that pronounced on
    what uDeck saved and kept nothing leaves the next person to rebuild the guest."""
    machine = prepared(monkeypatch, a_machine(a_switch_that_did_not(), ["", THE_SWITCH_OFF]))
    with pytest.raises(CheckFailed):
        checks.check_a_switch_survives_a_restart(machine, check_dir, lab)
    assert "the reveal with the switch as it ships" in (check_dir / "story.log").read_text()
    assert (check_dir / "settings.json").read_text() == THE_SWITCH_OFF
    assert (check_dir / "opening-before-the-change.txt").read_text() == OPENING_TREE
