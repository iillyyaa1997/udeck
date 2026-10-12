import pytest

from udeck_e2e.outcomes import Outcome, duration, exit_code, summary

P, F, N = Outcome.PASSED, Outcome.FAILED, Outcome.COULD_NOT_CHECK
T = Outcome.NOT_ON_THIS_TARGET


@pytest.mark.parametrize(
    "outcomes, lab_problems, expected",
    [
        ([P, P], 0, 0),
        ([], 0, 2),  # nothing checked is never green
        ([P, N], 0, 2),
        ([P, F], 0, 1),
        ([F, N], 0, 1),  # a verdict on uDeck outranks what the lab could not do
        ([P], 1, 2),  # a clone that could not be cleaned up spoils a green run
        ([F], 1, 1),
        # A check not for this target did not run: it neither spoils a green run…
        ([P, T], 0, 0),
        # …nor makes a red one green, nor a run that could not check clean…
        ([F, T], 0, 1),
        ([N, T], 0, 2),
        # …and a run of nothing else has checked nothing.
        ([T, T], 0, 2),
    ],
)
def test_exit_code(outcomes, lab_problems, expected):
    assert exit_code(outcomes, lab_problems) == expected


def test_summary_counts_each_outcome_that_happened():
    assert summary([P, P, F, N], 754) == "2 passed, 1 failed, 1 could not check in 12m34s"
    assert summary([P, T, T], 61) == "1 passed, 2 not on this target in 1m01s"
    assert summary([P], 5) == "1 passed in 5s"
    assert summary([], 1) == "nothing checked in 1s"


@pytest.mark.parametrize(
    "seconds, text", [(0, "0s"), (59.4, "59s"), (60, "1m00s"), (3599, "59m59s"), (3723, "1h02m03s")]
)
def test_duration(seconds, text):
    assert duration(seconds) == text


def test_not_on_this_target_has_its_own_mark_and_words():
    """Listed beside the others and never mistaken for a pass, a failure or the lab failing."""
    assert T.words == "not on this target"
    assert T.mark not in {P.mark, F.mark, N.mark}
    assert T.value == "not-on-this-target"
