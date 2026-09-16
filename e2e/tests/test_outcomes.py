import pytest

from udeck_e2e.outcomes import Outcome, duration, exit_code, summary

P, F, N = Outcome.PASSED, Outcome.FAILED, Outcome.COULD_NOT_CHECK


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
    ],
)
def test_exit_code(outcomes, lab_problems, expected):
    assert exit_code(outcomes, lab_problems) == expected


def test_summary_counts_each_outcome_that_happened():
    assert summary([P, P, F, N], 754) == "2 passed, 1 failed, 1 could not check in 12m34s"
    assert summary([P], 5) == "1 passed in 5s"
    assert summary([], 1) == "nothing checked in 1s"


@pytest.mark.parametrize(
    "seconds, text", [(0, "0s"), (59.4, "59s"), (60, "1m00s"), (3599, "59m59s"), (3723, "1h02m03s")]
)
def test_duration(seconds, text):
    assert duration(seconds) == text
