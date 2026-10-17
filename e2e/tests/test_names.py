import pytest

from udeck_e2e.names import CheckNameError, ShardError, check_name, parse_shard, select, shard


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


def test_a_check_run_only_when_named_is_chosen_by_its_own_name_alone():
    """The smoke against the real GitHub: never in a run without names, nor in its group's."""
    available = ["panel.dwell", "smoke.real-pull-request", "plugins.install", "plugins.real"]
    named_only = {"smoke.real-pull-request", "plugins.real"}
    assert select(available, [], named_only) == ["panel.dwell", "plugins.install"]
    assert select(available, ["plugins"], named_only) == ["plugins.install"]
    assert select(available, ["smoke.real-pull-request", "panel"], named_only) == ["panel.dwell", "smoke.real-pull-request"]
    with pytest.raises(CheckNameError, match="run only when each is named: smoke.real-pull-request"):
        select(available, ["smoke"], named_only)


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


# --- Shards -------------------------------------------------------------------------------

PLUGINS = [f"plugins.check-{n}" for n in range(28)]


@pytest.mark.parametrize("count", [1, 2, 3, 4, 5, 28, 29])
def test_every_check_is_in_exactly_one_shard(count):
    parts = [shard(PLUGINS, index, count) for index in range(1, count + 1)]
    dealt = [name for part in parts for name in part]
    assert sorted(dealt) == sorted(PLUGINS) and len(dealt) == len(set(dealt))
    sizes = [len(part) for part in parts]
    assert max(sizes) - min(sizes) <= 1


def test_a_shard_keeps_the_definition_order_and_is_the_same_every_time():
    assert shard(PLUGINS, 2, 3) == [PLUGINS[i] for i in range(1, 28, 3)]
    assert shard(PLUGINS, 2, 3) == shard(list(PLUGINS), 2, 3)
    # Dealt in turn, so neighbours — a group's long checks often sit together — go to different parts.
    assert shard(PLUGINS[:3], 1, 3) == [PLUGINS[0]] and shard(PLUGINS[:3], 3, 3) == [PLUGINS[2]]


def test_a_shard_of_one_is_everything_and_more_shards_than_checks_leaves_some_empty():
    assert shard(PLUGINS, 1, 1) == PLUGINS
    assert shard(PLUGINS[:2], 3, 3) == []


@pytest.mark.parametrize("text, parsed", [("1/3", (1, 3)), ("3/3", (3, 3)), ("1/1", (1, 1))])
def test_a_shard_is_written_i_of_n(text, parsed):
    assert parse_shard(text) == parsed


@pytest.mark.parametrize("text", ["0/3", "4/3", "1/0", "3", "1/3/4", "a/3", "-1/3", "1 /3", "１/3", ""])
def test_a_shard_that_is_not_one_of_its_parts_is_refused(text):
    with pytest.raises(ShardError):
        parse_shard(text)
