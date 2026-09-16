import pytest

from udeck_e2e.names import CheckNameError, check_name, select


def test_the_name_comes_from_the_file_and_the_function():
    assert check_name("check_updates", "check_wrong_key") == "updates.wrong-key"
    assert check_name("check_open_at_login", "check_after_reboot") == "open-at-login.after-reboot"


@pytest.mark.parametrize(
    "module, function",
    [
        ("updates", "check_wrong_key"),  # file without the prefix
        ("check_updates", "wrong_key"),  # function without the prefix
        ("check_Updates", "check_wrong_key"),  # capitals
        ("check_updates", "check_wrong__key"),  # an empty word
        ("check_updates", "check_2fast"),  # starts with a digit
        ("check_bake", "check_anything"),  # a command of the lab
    ],
)
def test_names_that_break_the_rules_are_refused(module, function):
    with pytest.raises(CheckNameError):
        check_name(module, function)


AVAILABLE = ["updates.sparkle", "updates.wrong-key", "panel.dwell", "panel.push"]


def test_nothing_asked_for_means_everything_in_definition_order():
    assert select(AVAILABLE, []) == AVAILABLE


def test_a_group_picks_its_checks():
    assert select(AVAILABLE, ["panel"]) == ["panel.dwell", "panel.push"]


def test_a_group_does_not_pick_a_group_whose_name_merely_starts_the_same():
    assert select(["panel.dwell", "panel-edge.dwell"], ["panel"]) == ["panel.dwell"]


def test_a_dotted_name_picks_one_check():
    assert select(AVAILABLE, ["updates.wrong-key"]) == ["updates.wrong-key"]


def test_the_order_is_the_definition_order_not_the_command_line_order():
    # Asked for in the opposite order, and one of them twice.
    assert select(AVAILABLE, ["panel.push", "updates", "panel.push"]) == [
        "updates.sparkle",
        "updates.wrong-key",
        "panel.push",
    ]


@pytest.mark.parametrize(
    "wanted",
    [
        ["update"],  # a prefix of a group is not a group
        ["updates.wrong"],  # a prefix of a check is not a check
        ["wrong-key"],  # a check without its group is not a group
        ["updates.dwell"],  # a real check in another group
        ["panel", "nonsense"],  # one bad name spoils the run
    ],
)
def test_anything_that_matches_nothing_is_an_error_listing_what_exists(wanted):
    with pytest.raises(CheckNameError) as raised:
        select(AVAILABLE, wanted)
    for name in AVAILABLE:
        assert name in str(raised.value)


def test_asking_for_a_check_when_there_are_none_says_so():
    with pytest.raises(CheckNameError, match="no checks yet"):
        select([], ["updates"])
