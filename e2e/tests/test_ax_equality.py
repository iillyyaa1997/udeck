"""The accessibility helper against System Events, on the screens they both read in a guest.

Recorded by `e2e/run.sh selfcheck` on 2026-10-12 (run 20261012-063626Z, macOS 27
guest, `e2e/selfcheck/check_ax.py`): each screen walked by System Events with
the AppleScript the lab used until then, and by the helper just before and after.
`ax-equality/` keeps both walks of six of those screens — the Opening screen's
unnamed controls, Look, Plugins with the fake catalogue, the link sheet over it,
Plugins in Russian and the panel — and `comparison-20261012-063626Z.txt` what the
run said of all 76 readings: 66 the same, and 10 different in the one way this
test names.

And by the second self-check, `ax.cards-and-questions-read-as-system-events-read`
(run 20261012-114749Z, macOS 27 guest): the panel with a plugin's card asking
for consent, the card once it had run, and the card after a failed run, its
dot and its line — `comparison-20261012-114749Z.txt`, all 29 readings the same
and nothing misread. That run stopped at the next screen, Settings → Plugins
with **More** open, when the guest stopped answering SSH in the middle of
System Events' walk; the screens after it were not read.

Its next run (20261012-151715Z) read them all — `comparison-20261012-151715Z.txt`,
49 of 59 readings the same — and the three Settings screens it had not reached
are kept here: **More** open on the failed run, the **Install from a link…**
sheet with a pull request looked up, and the question **Remove** asks. System
Events could not read their trees at all: the end of the plugin's standard
error holds a line break, which its tree walk prints as it is, so the line
breaks in two (`_IDENTIFIED` always printed one as ⏎, as the helper does).
And its lists of identified controls came back longer than the helper's, with
copies of rows it had already read. Both are held below, on the recording:
with the line break put back, each tree differs from the helper's only by the
misreading `ax.held_against` names; and each list, its own copies set aside,
is the helper's list less exactly the controls the same screen's tree shows it
misread. The self-check's own comparison pairs rows by place and lets through
nothing else, so it still says those ten readings differ.

What is held here is the comparison itself (`ax.held_against`), on what was
measured: no difference but System Events' own misreadings, each of them a
copy of an earlier row of its own reading, and nothing explained away that is
not one.
"""

from pathlib import Path

import pytest

from udeck_e2e import ax, ui
from udeck_e2e.errors import LabError

RECORDED = Path(__file__).parent / "ax-equality"

# Screen, walk, and how many controls System Events misread on it.
SCREENS = [
    ("settings-opening", "tree", 0),
    ("settings-opening", "identified", 0),
    ("settings-look", "tree", 2),
    ("settings-look", "identified", 0),
    ("settings-plugins", "tree", 8),
    ("settings-plugins", "identified", 3),
    ("install-from-a-link-sheet", "tree", 8),
    ("install-from-a-link-sheet", "identified", 3),
    ("russian-settings-plugins", "tree", 8),
    ("russian-settings-plugins", "identified", 3),
    ("the-panel", "tree", 0),
    ("the-panel", "identified", 0),
    ("the-panel-a-card-asking-for-consent", "tree", 0),
    ("the-panel-a-card-asking-for-consent", "identified", 0),
    ("the-panel-the-card-having-run", "tree", 0),
    ("the-panel-the-card-having-run", "identified", 0),
    ("the-panel-the-card-after-a-failed-run", "tree", 0),
    ("the-panel-the-card-after-a-failed-run", "identified", 0),
]

# The words of every control System Events misread: texts that repeat down the
# catalogue — each row's "Verified", its publisher, its version, "Asks for
# nothing" — and Look's two "100 %".
LIKE_TEXTS = {"Verified", "uDeck lab", "1.0.0", "Asks for nothing", "100 %", "Проверен", "Ничего не просит"}


def rows(name):
    dump = (RECORDED / name).read_text()
    depths = [line.split("|", 1)[0] for line in dump.splitlines() if line.strip()]
    return [
        (depth, c.role, c.subrole, c.identifier, c.title, c.value, c.description, c.x, c.y, c.width, c.height)
        for depth, c in zip(depths, ui.controls(dump))
    ]  # fmt: skip


@pytest.mark.parametrize("screen, walk, misread", SCREENS)
def test_the_helper_reads_what_system_events_read_but_for_what_system_events_misread(screen, walk, misread):
    old = ax.without_the_title_bar(rows(f"{screen}-{walk}-system-events.txt"))
    new = ax.without_the_title_bar(rows(f"{screen}-{walk}-helper.txt"))
    unexplained, explained = ax.held_against(old, new, f"{screen} {walk}", ax.same_control_words)
    assert unexplained == []
    assert len(explained) == misread
    for line in explained:
        assert any(f"'{words}'" in line for words in LIKE_TEXTS), line


@pytest.mark.parametrize("screen", ["settings-look", "settings-plugins", "install-from-a-link-sheet"])
def test_each_misread_control_was_a_copy_of_one_system_events_had_already_read(screen):
    """Same identifier, same place: two controls cannot be that, so System Events'
    row is the misreading — and in the screenshot the helper's places are where
    the words are (run 20261012-063626Z, 04-settings-plugins.png)."""
    old = ax.without_the_title_bar(rows(f"{screen}-tree-system-events.txt"))
    new = ax.without_the_title_bar(rows(f"{screen}-tree-helper.txt"))
    differing = [i for i, (a, b) in enumerate(zip(old, new)) if a != b]
    assert differing
    for index in differing:
        assert old[index] in old[:index]
        assert new[index] not in new[:index], "the helper's row is a control of its own"


def test_what_the_title_bar_holds_is_the_one_place_the_two_walks_list_different_elements():
    old = rows("settings-plugins-tree-system-events.txt")
    new = rows("settings-plugins-tree-helper.txt")
    assert len(old) == len(new) + 1
    dropped = [row for row in old if row not in ax.without_the_title_bar(old)]
    assert dropped and all(int(row[0]) >= 2 and row[1] == "AXGroup" and not row[3] for row in dropped)
    assert len(ax.without_the_title_bar(old)) == len(ax.without_the_title_bar(new))


def test_a_difference_that_is_not_a_misreading_is_a_difference():
    old = ax.without_the_title_bar(rows("settings-plugins-identified-system-events.txt"))
    new = ax.without_the_title_bar(rows("settings-plugins-identified-helper.txt"))
    # A control that reads otherwise in the helper's walk.
    changed = list(new)
    index = next(i for i, row in enumerate(changed) if row[3] == "catalogue.enabled")
    changed[index] = (*changed[index][:5], "0" if changed[index][5] == "1" else "1", *changed[index][6:])
    unexplained, _ = ax.held_against(old, changed, "plugins", ax.same_control_words)
    assert len(unexplained) == 1 and "catalogue.enabled" in unexplained[0]
    # A misread row whose words the helper does not share is not explained either.
    misread = next(i for i, (a, b) in enumerate(zip(old, new)) if a != b)
    other = list(new)
    other[misread] = (*other[misread][:5], "Unverified", *other[misread][6:])
    unexplained, explained = ax.held_against(old, other, "plugins", ax.same_control_words)
    assert any(f"#{misread}:" in line for line in unexplained)
    # And a walk of another length is nothing but differences.
    unexplained, explained = ax.held_against(old, new[:-1], "plugins", ax.same_control_words)
    assert explained == [] and "System Events read" in unexplained[0]


def test_the_recorded_run_said_what_this_test_holds():
    said = (RECORDED / "comparison-20261012-063626Z.txt").read_text()
    lines = [line for line in said.splitlines() if line.startswith(("SAME", "DIFF"))]
    assert len(lines) == 76 and sum(line.startswith("SAME") for line in lines) == 66
    assert all("Look" in line or "Plugins" in line or "link…" in line for line in lines if line.startswith("DIFF"))


def identifier_list(walk_rows):
    """`ui.identifiers` out of a tree walk's rows: `role [identifier]` for each control that has one."""
    return [(f"{row[1]} [{row[3]}]",) for row in walk_rows if row[3]]


@pytest.mark.parametrize("screen, misread", [("settings-plugins", 3), ("install-from-a-link-sheet", 3), ("settings-look", 0)])
def test_a_list_of_identifiers_differs_only_where_the_same_screens_tree_shows_the_misreading(screen, misread):
    """A list of identifiers has no words to tell a misread control by: a
    difference in one stands only where the tree of the same screen shows
    System Events reading that very identifier for the helper's."""
    old = ax.without_the_title_bar(rows(f"{screen}-tree-system-events.txt"))
    new = ax.without_the_title_bar(rows(f"{screen}-tree-helper.txt"))
    pairs = ax.misread_identifiers(old, new)
    unexplained, explained = ax.held_against(identifier_list(old), identifier_list(new), screen, ax.same_identifier_misread(pairs))
    assert unexplained == [] and len(explained) == misread
    if not misread:
        return
    # The same role with an identifier the tree never showed misread is a difference.
    changed = identifier_list(new)
    index = next(i for i, (a, b) in enumerate(zip(identifier_list(old), changed)) if a != b)
    role = changed[index][0].split(" [", 1)[0]
    changed[index] = (f"{role} [catalogue.somebody-else.verified]",)
    unexplained, _ = ax.held_against(identifier_list(old), changed, screen, ax.same_identifier_misread(pairs))
    assert len(unexplained) == 1 and "somebody-else" in unexplained[0]


def test_a_helper_row_that_repeats_one_of_its_own_is_never_a_misreading():
    """The helper's row has to be a control of its own (met for the first time in
    its reading): a helper that read a control twice is wrong itself, and two
    wrong readings that agree are not let through."""
    old = ax.without_the_title_bar(rows("settings-plugins-tree-system-events.txt"))
    new = ax.without_the_title_bar(rows("settings-plugins-tree-helper.txt"))
    found = ax.misreadings(old, new, ax.same_control_words)
    first, (index, a, _) = next((b, later) for i, (_, _, b) in enumerate(found) for later in found[i + 1:]
                                if ax.same_control_words(later[1], b))  # fmt: skip
    copied = list(new)
    copied[index] = first  # the helper reading the first misread control again, where System Events read another copy
    assert first != a and ax.same_control_words(a, first)
    unexplained, explained = ax.held_against(old, copied, "plugins", ax.same_control_words)
    assert [line for line in unexplained if f"#{index}:" in line] and not [line for line in explained if f"#{index}:" in line]


def test_the_card_screens_hold_what_the_plugin_checks_read_off_them():
    """The recordings are of the screens they are named for: the consent's
    buttons, the card's rows, the failed run's dot and line — the controls
    `_allow_and_read_the_card`, `_read_the_card` and the failed-run check read."""
    def identifiers(name):
        return {row[3] for row in rows(f"{name}-tree-helper.txt")}

    def texts(name):
        return {row[5] for row in rows(f"{name}-tree-helper.txt")}

    assert {"consent.flaky.allow", "consent.flaky.decline"} <= identifiers("the-panel-a-card-asking-for-consent")
    assert {"runs since install", "1", "version", "steady"} <= texts("the-panel-the-card-having-run")
    failed = "the-panel-the-card-after-a-failed-run"
    assert {"card.flaky.failedDot", "card.flaky.lastRunFailed", "card.flaky.valuesFrom"} <= identifiers(failed)
    assert any(text.startswith("Last run failed at ") for text in texts(failed))
    said = (RECORDED / "comparison-20261012-114749Z.txt").read_text().splitlines()
    assert len(said) == 29 and all(line.startswith("SAME") for line in said)


# The three Settings screens the third run of the second self-check reached
# (20261012-151715Z): how many rows of each tree System Events misread, and how
# many controls its list of identified controls lacks for it.
SETTINGS_SCREENS = [
    ("settings-plugins-more-on-a-failed-run", 9, 3),
    ("install-from-a-link-sheet-a-pull-request-looked-up", 18, 5),
    ("settings-plugins-the-question-before-remove", 9, 3),
]

# The words System Events misread there: the catalogue's repeated texts as
# before, and what the pull request's list and the catalogue below it both say.
REPEATED_ON_THE_SETTINGS_SCREENS = LIKE_TEXTS | {
    "Unverified", "Linked", "Uptime", "Ilya Volkov", "Asks to run ./hold.sh, run sysctl",
    "How long this Mac has been up, its load averages, and how many times the card has run since it was installed.",
}  # fmt: skip


def with_the_line_breaks_put_back(dump):
    """System Events' tree walk with each value it printed across two lines joined again, as ⏎."""
    lines = []
    for line in dump.splitlines():
        if lines and line.count("|") < 8 and lines[-1].count("|") < 8:
            lines[-1] = f"{lines[-1]}⏎{line}"
        else:
            lines.append(line)
    return "\n".join(lines)


def rows_of(dump):
    depths = [line.split("|", 1)[0] for line in dump.splitlines() if line.strip()]
    return [
        (depth, c.role, c.subrole, c.identifier, c.title, c.value, c.description, c.x, c.y, c.width, c.height)
        for depth, c in zip(depths, ui.controls(dump))
    ]  # fmt: skip


@pytest.mark.parametrize("screen", [screen for screen, _, _ in SETTINGS_SCREENS])
def test_system_events_tree_walk_could_not_read_a_value_holding_a_line_break(screen):
    """The end of the failed run's standard error ends in a line break: the old
    tree walk printed it as it was and its line came out in two, which `ui`
    refuses to guess at — the helper prints it as ⏎."""
    with pytest.raises(LabError, match="plugin.flaky.stderr"):
        rows(f"{screen}-tree-system-events.txt")
    stderr = next(row for row in rows(f"{screen}-tree-helper.txt") if row[3] == "plugin.flaky.stderr")
    assert stderr[5] == "ValueError: told to fail⏎"


@pytest.mark.parametrize("screen, misread, _", SETTINGS_SCREENS)
def test_with_the_line_break_put_back_each_tree_differs_only_by_what_system_events_misread(screen, misread, _):
    old = ax.without_the_title_bar(rows_of(with_the_line_breaks_put_back((RECORDED / f"{screen}-tree-system-events.txt").read_text())))
    new = ax.without_the_title_bar(rows(f"{screen}-tree-helper.txt"))
    unexplained, explained = ax.held_against(old, new, f"{screen} tree", ax.same_control_words)
    assert unexplained == []
    assert len(explained) == misread
    for line in explained:
        assert any(f"'{words}'" in line for words in REPEATED_ON_THE_SETTINGS_SCREENS), line


@pytest.mark.parametrize("screen, _, lacking", SETTINGS_SCREENS)
def test_each_list_is_the_helpers_less_what_the_tree_shows_misread_once_its_own_copies_are_set_aside(screen, _, lacking):
    """System Events' list of identified controls came back longer than the
    helper's: it holds rows it had already read — the same identifier at the
    same place, which two controls cannot be. Set aside, what is left is the
    helper's list in the helper's order, less only controls whose identifiers
    the same screen's tree shows System Events reading as another's."""
    old = rows(f"{screen}-identified-system-events.txt")
    new = rows(f"{screen}-identified-helper.txt")
    assert len(old) > len(new)
    copies = [i for i, row in enumerate(old) if any(row[3] == seen[3] and row[7:] == seen[7:] for seen in old[:i])]
    assert copies
    left = [row for i, row in enumerate(old) if i not in copies]
    remaining = iter(new)
    assert all(any(row == theirs for theirs in remaining) for row in left), "in the helper's order"
    missing = [row for row in new if row not in left]
    assert len(missing) == lacking
    tree_old = ax.without_the_title_bar(rows_of(with_the_line_breaks_put_back((RECORDED / f"{screen}-tree-system-events.txt").read_text())))
    tree_new = ax.without_the_title_bar(rows(f"{screen}-tree-helper.txt"))
    misread_by_the_helper_side = {helper for _, helper in ax.misread_identifiers(tree_old, tree_new)}
    assert all(row[3] in misread_by_the_helper_side for row in missing)


def test_the_third_run_said_what_these_tests_hold():
    said = (RECORDED / "comparison-20261012-151715Z.txt").read_text()
    lines = [line for line in said.splitlines() if line.startswith(("SAME", "DIFF"))]
    assert len(lines) == 59 and sum(line.startswith("SAME") for line in lines) == 49
    differing = [line for line in lines if line.startswith("DIFF")]
    assert all("Settings → Plugins" in line or "a pull request looked up" in line for line in differing)
    assert all(line.startswith("SAME") for line in lines if "the panel" in line)

