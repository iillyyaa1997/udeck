"""An update check's pair, "from → to": what can be written, what each check refuses, and what it resolves to.

Nothing here reaches GitHub: releases are made in the test (`Release`), and the
catalogue that would have fetched them is a table. What is held is what the run
says before anything starts — which pairs exist, which are refused and why —
and what a pair turns into: the version and build of each end, which key a
build of this checkout carries, and how "to" reaches "from".
"""

import subprocess
from dataclasses import replace
from pathlib import Path

import pytest

from udeck_e2e import config, pairs, releases
from udeck_e2e.pairs import Checkout, Pair, PairDefect, PairError, Side
from udeck_e2e.releases import Published, Release, ReleaseDefect, ReleaseError

ROOT = Path(".")


def a_release(version, build, key="release-key=", feed=config.LATEST_FEED):
    published = Published(
        f"v{version}",
        f"https://github.com/{config.RELEASES_REPOSITORY}/releases/download/v{version}/appcast.xml",
        f"uDeck-{version}.zip", f"https://github.com/x/v{version}/uDeck-{version}.zip", 100,
    )  # fmt: skip
    return Release(
        published=published, version=version, build=build, public_key=key, shipped_feed=feed,
        zip=Path("/cache") / f"v{version}" / f"uDeck-{version}.zip", appcast=Path("/cache") / f"v{version}" / "appcast.xml",
        enclosure_url=published.zip_url, length=100, signature="c2lnbmF0dXJl", sha256="00" * 32,
    )  # fmt: skip


class Catalogue:
    """The releases as on 2026-10-09, without GitHub: 0.4.0 (5), 0.5.0 (6) and 0.6.1 (8), latest."""

    def __init__(self, latest="0.6.1", fails=None, broken=(), latest_broken=None, feeds=None, builds=None, elsewhere=()):
        feeds, builds = feeds or {}, {"0.4.0": "5", "0.5.0": "6", "0.6.1": "8", **(builds or {})}
        self.releases = {
            v: replace(a_release(v, builds[v], feed=feeds.get(v, config.LATEST_FEED)),
                       elsewhere=f"the appcast's item for uDeck-{v}.zip sends uDeck to https://nowhere.invalid/" if v in elsewhere else None)
            for v in ("0.4.0", "0.5.0", "0.6.1")
        }  # fmt: skip
        self.latest_version = latest
        self.fails = fails
        # Releases GitHub serves broken: what `fetch` says of them.
        self.broken = dict(broken)
        # Latest marked on a release without an asset.
        self.latest_broken = latest_broken
        self.fetched = []

    def _check(self):
        if self.fails:
            raise ReleaseError(self.fails)

    def latest_tag(self):
        self._check()
        return f"v{self.latest_version}"

    def published(self):
        """What GitHub lists with both assets, oldest first — 0.4.0 the first, in this table."""
        self._check()
        return sorted((r.published for r in self.releases.values()), key=lambda p: p.order)

    def latest(self):
        self._check()
        if self.latest_broken:
            raise ReleaseDefect(self.latest_broken)
        return self.releases[self.latest_version].published

    def before_latest(self):
        self._check()
        order = sorted(self.releases.values(), key=lambda r: r.published.order)
        older = [r for r in order if r.published.order < self.releases[self.latest_version].published.order]
        return older[-1].published

    def named(self, version):
        self._check()
        if version not in self.releases:
            raise ReleaseError(f"no published release {version}; the published releases are 0.4.0, 0.5.0, 0.6.1 (latest)")
        return self.releases[version].published

    def fetch(self, published, offered=False):
        """As `releases.Catalogue.fetch`: where the appcast sends uDeck is a defect only of the release offered."""
        self.fetched.append(published.tag)
        if published.version in self.broken:
            raise self.broken[published.version]
        release = self.releases[published.version]
        if offered and release.elsewhere:
            raise ReleaseDefect(release.elsewhere, release.build)
        return release


def can_drive(*args, **kwargs):
    """`git` as a checkout that has every tag, each naming the controls the lab presses — all in one file."""
    tag = next((a for a in args[0] if a.startswith("v0.")), "v0.5.0")
    return subprocess.CompletedProcess(args[0], 0, f"{tag}:Sources/UDeckKit/Views/SettingsView.swift\n", "")


def resolve(rule, from_text=None, to_text=None, catalogue=None, run=can_drive):
    pair, given = pairs.asked(rule, from_text, to_text)
    return pairs.resolve(rule, pair, given, catalogue if catalogue is not None else Catalogue(), ROOT, run=run)


# --- Writing a side -------------------------------------------------------------------------


@pytest.mark.parametrize("text", ["checkout", "latest", "0.5.0", "10.20.30"])
def test_the_three_kinds_of_side(text):
    assert pairs.side(text) == Side(text)


@pytest.mark.parametrize(
    "text, hint",
    [("0.5", "such as 0.5.0"), ("v0.5.0", "without the v: 0.5.0"), ("previous", "write checkout, latest"),
     ("Latest", "write checkout, latest"), ("", "write checkout, latest")],
)  # fmt: skip
def test_anything_else_is_refused_with_what_to_write(text, hint):
    with pytest.raises(PairError, match=hint):
        pairs.side(text)


def test_what_is_not_given_comes_from_the_checks_own_default():
    assert pairs.asked(pairs.A_PUBLISHED_RELEASE, None, None) == (pairs.THE_RELEASE_BEFORE_LATEST_TO_LATEST, False)
    assert pairs.asked(pairs.A_PUBLISHED_RELEASE, "0.5.0", None) == (Pair(Side("0.5.0"), Side("latest")), True)
    assert pairs.asked(pairs.THE_WHOLE_UPDATE, None, "latest") == (Pair(Side("checkout"), Side("latest")), True)


def test_the_default_of_the_check_by_a_published_release_reads_as_words():
    assert str(pairs.THE_RELEASE_BEFORE_LATEST_TO_LATEST) == "the release before latest → latest"
    assert str(pairs.BETWEEN_CHECKOUTS) == "checkout → checkout"


# --- What each check refuses before anything starts -------------------------------------------


def refusal(rule, from_text, to_text):
    return rule.refusal(pairs.asked(rule, from_text, to_text)[0])


def test_nothing_the_lab_signs_is_what_a_release_installs():
    for rule in (pairs.THE_WHOLE_UPDATE, pairs.A_PUBLISHED_RELEASE):
        said = refusal(rule, "0.5.0", "checkout")
        assert said and "private half lives in GitHub's secrets" in said and "updates.wrong-key" in said
        assert refusal(rule, "latest", "checkout")


def test_the_whole_update_takes_every_pair_that_can_be():
    for from_text, to_text in [("checkout", "checkout"), ("checkout", "latest"), ("checkout", "0.5.0"),
                               ("0.5.0", "latest"), ("0.5.0", "0.6.1")]:  # fmt: skip
        assert refusal(pairs.THE_WHOLE_UPDATE, from_text, to_text) is None


def test_the_check_by_a_published_release_wants_a_release_to_go_to():
    said = refusal(pairs.A_PUBLISHED_RELEASE, "checkout", "checkout")
    assert said and "checkout → checkout is updates.sparkle" in said
    assert refusal(pairs.A_PUBLISHED_RELEASE, "checkout", "latest") is None
    assert refusal(pairs.A_PUBLISHED_RELEASE, "0.5.0", "0.6.1") is None


def test_the_wrong_key_control_is_offered_only_what_the_lab_signs():
    said = refusal(pairs.THE_WRONG_KEY, "checkout", "latest")
    assert said and "the release key, the key every release trusts" in said
    assert refusal(pairs.THE_WRONG_KEY, "0.5.0", "0.6.1")
    assert refusal(pairs.THE_WRONG_KEY, "0.5.0", "checkout") is None
    assert refusal(pairs.THE_WRONG_KEY, "checkout", "checkout") is None


def test_the_checks_about_looking_by_itself_have_only_one_pair():
    for from_text, to_text in [("checkout", "latest"), ("0.6.1", "checkout"), ("latest", "latest")]:
        said = refusal(pairs.ONLY_THIS_CHECKOUT, from_text, to_text)
        assert said and "its only pair is checkout → checkout" in said
    assert refusal(pairs.ONLY_THIS_CHECKOUT, "checkout", "checkout") is None


def test_every_default_is_a_pair_its_own_check_takes():
    for rule in (pairs.THE_WHOLE_UPDATE, pairs.A_PUBLISHED_RELEASE, pairs.THE_WRONG_KEY, pairs.ONLY_THIS_CHECKOUT):
        assert rule.refusal(rule.default) is None, rule


def test_a_check_says_which_rule_it_takes_and_a_function_without_one_takes_none():
    @pairs.takes(pairs.THE_WRONG_KEY)
    def check_something(machine):
        pass

    def check_other(machine):
        pass

    assert pairs.rule_of(check_something) is pairs.THE_WRONG_KEY
    assert pairs.rule_of(check_other) is None
    assert check_something.__name__ == "check_something", "the name the lab derives the check's from stays"


# --- What a pair resolves to ---------------------------------------------------------------------


def test_between_checkouts_is_what_the_lab_has_always_built_and_asks_nothing_of_github():
    resolved = pairs.resolve(pairs.THE_WHOLE_UPDATE, pairs.BETWEEN_CHECKOUTS, False, None, ROOT)
    assert (resolved.from_, resolved.to) == (Checkout("0.4.1", "6"), Checkout("0.4.2", "7"))
    assert str(resolved) == (
        "checkout as 0.4.1 (6) → checkout as 0.4.2 (7), signed with the run's own key, via the lab's feed in the guest"
    )


def test_the_default_of_the_check_by_a_published_release_is_the_one_before_latest_to_latest():
    resolved = resolve(pairs.A_PUBLISHED_RELEASE)
    assert (resolved.from_.version, resolved.to.version) == ("0.5.0", "0.6.1")
    assert resolved.to_by_the_latest_feed
    assert str(resolved) == (
        "release 0.5.0 (6), the release before latest → release 0.6.1 (8), latest, via the real feed"
    )
    assert resolved.how_asked() == "default: the release before latest → latest"


def test_a_release_named_by_its_version_is_reached_through_its_own_appcast_even_when_it_is_latest():
    resolved = resolve(pairs.A_PUBLISHED_RELEASE, "0.5.0", "0.6.1")
    assert not resolved.to_by_the_latest_feed
    assert str(resolved) == "release 0.5.0 (6) → release 0.6.1 (8) via its own appcast"
    assert resolved.how_asked() == "--from/--to: 0.5.0 → 0.6.1"


def test_a_build_of_this_checkout_going_to_a_release_carries_its_key_and_is_numbered_below_it():
    resolved = resolve(pairs.THE_WHOLE_UPDATE, "checkout", "latest")
    assert resolved.from_ == Checkout("0.4.1", "1", key_of=resolved.to)
    assert resolved.from_.public_key == "release-key="
    assert str(resolved) == (
        "checkout as 0.4.1 (1) with 0.6.1's public key → release 0.6.1 (8), latest, via the real feed"
    )


def test_a_build_of_this_checkout_offered_to_a_release_is_numbered_above_it_and_carries_the_runs_key():
    resolved = resolve(pairs.THE_WRONG_KEY, "0.5.0", "checkout")
    assert resolved.to == Checkout("0.4.2", "7")
    assert resolved.to.public_key is None
    resolved = resolve(pairs.THE_WRONG_KEY, "0.6.1", "checkout")
    assert resolved.to == Checkout("0.4.2", "9")


def test_to_not_newer_than_from_by_cfbundleversion_is_refused_with_both_numbers():
    with pytest.raises(PairError) as raised:
        resolve(pairs.A_PUBLISHED_RELEASE, "0.6.1", "0.5.0")
    assert "is not newer than release 0.6.1 (8) by CFBundleVersion" in raised.value.reason
    assert "(6 against 8)" in raised.value.reason
    with pytest.raises(PairError, match="8 against 8"):
        resolve(pairs.A_PUBLISHED_RELEASE, "latest", "latest")


def test_a_release_whose_window_the_lab_cannot_drive_is_refused_before_anything_is_fetched():
    def cannot_drive(args, **kwargs):
        # The tag is there; the identifiers are not.
        return subprocess.CompletedProcess(args, 0 if "rev-parse" in args else 1, "", "")

    catalogue = Catalogue()
    with pytest.raises(PairError, match="gives its settings window no section.about"):
        resolve(pairs.A_PUBLISHED_RELEASE, "0.4.0", "0.5.0", catalogue=catalogue, run=cannot_drive)
    assert catalogue.fetched == []


def test_the_wrong_key_control_with_a_real_from_is_refused_for_a_release_it_cannot_drive_too():
    def cannot_drive(args, **kwargs):
        return subprocess.CompletedProcess(args, 0 if "rev-parse" in args else 1, "", "")

    with pytest.raises(PairError, match="no updates.install"):
        resolve(pairs.THE_WRONG_KEY, "0.4.0", "checkout", run=cannot_drive)


def test_github_not_answering_is_a_pair_that_could_not_be_resolved_with_the_reason():
    with pytest.raises(PairError, match="api.github.com/x did not answer this Mac"):
        resolve(pairs.A_PUBLISHED_RELEASE, catalogue=Catalogue(fails="https://api.github.com/x did not answer this Mac"))


def test_a_release_nobody_published_is_refused_with_what_exists():
    with pytest.raises(PairError, match="no published release 0.6.0; the published releases are"):
        resolve(pairs.A_PUBLISHED_RELEASE, "0.6.0", "latest")


def test_the_ledger_has_both_ends_down_to_what_was_installed():
    resolved = resolve(pairs.A_PUBLISHED_RELEASE)
    said = resolved.ledger()
    assert said["text"] == str(resolved)
    assert said["asked"] == "the release before latest → latest" and said["given"] is False
    assert said["from"] == {
        "side": "release", "asked_as": "before-latest", "version": "0.5.0", "build": "6", "tag": "v0.5.0",
        "zip": "uDeck-0.5.0.zip", "zip_sha256": "00" * 32, "zip_bytes": 100, "public_key": "release-key=",
        "appcast": f"https://github.com/{config.RELEASES_REPOSITORY}/releases/download/v0.5.0/appcast.xml",
    }  # fmt: skip
    assert said["to"]["asked_as"] == "latest"
    checkout = resolve(pairs.THE_WHOLE_UPDATE, "checkout", "latest").ledger()["from"]
    assert checkout == {"side": "checkout", "version": "0.4.1", "build": "1", "carries": "the public key of release 0.6.1"}
    between = pairs.resolve(pairs.THE_WHOLE_UPDATE, pairs.BETWEEN_CHECKOUTS, False, None, ROOT).ledger()
    assert between["from"] == {"side": "checkout", "version": "0.4.1", "build": "6",
                               "carries": "the run's own public key"}  # fmt: skip
    assert between["to"] == {"side": "checkout", "version": "0.4.2", "build": "7", "carries": "the run's own public key",
                             "signed_with": "the run's own key"}  # fmt: skip


def test_the_ledger_says_the_controls_offer_is_signed_with_another_key_and_not_the_one_from_trusts():
    """The key a build carries and the key an offered build is signed with are two keys; the control's two differ."""
    control = pairs.resolve(pairs.THE_WRONG_KEY, pairs.BETWEEN_CHECKOUTS, False, None, ROOT)
    said = control.ledger()
    assert said["from"]["carries"] == said["to"]["carries"] == "the run's own public key"
    assert said["to"]["signed_with"] == pairs.SIGNED_WITH_ANOTHER_KEY
    assert "key" not in said["to"], "never one word for both keys"
    assert pairs.signs_with_another_key(control.from_)

    with_a_release = resolve(pairs.THE_WRONG_KEY, "0.5.0", "checkout")
    assert with_a_release.ledger()["to"]["signed_with"] == "the run's own key, which no release trusts"
    assert not pairs.signs_with_another_key(with_a_release.from_)

    # Said where a person reads the run too: before the checks and under each check's line (`str`).
    assert str(control) == (
        'checkout as 0.4.1 (6) → checkout as 0.4.2 (7), signed with another key, made for the check, which "from" '
        "does not carry, via the lab's feed in the guest"
    )
    assert str(with_a_release) == (
        "release 0.5.0 (6) → checkout as 0.4.2 (7), signed with the run's own key, which no release trusts, via the "
        "lab's feed in the guest"
    )

    assert resolve(pairs.A_PUBLISHED_RELEASE).offer_signed_with is None, "a release is signed by the release key"
    assert pairs.resolve(pairs.ONLY_THIS_CHECKOUT, pairs.BETWEEN_CHECKOUTS, False, None, ROOT).offer_signed_with is None


# --- A "to" GitHub publishes broken ----------------------------------------------------------------

SIGNED_BY_ANOTHER = ReleaseDefect(
    "the appcast's edSignature does not hold over uDeck-0.6.1.zip under the SUPublicEDKey its own Info.plist carries (k=)"
)


def test_a_to_that_does_not_hold_together_is_the_checks_failure_and_not_a_pair_that_could_not_be_resolved():
    """What the check by a published release exists to catch: a release key that is not the key the bundles carry."""
    catalogue = Catalogue(broken={"0.6.1": SIGNED_BY_ANOTHER})
    with pytest.raises(PairDefect) as raised:
        resolve(pairs.A_PUBLISHED_RELEASE, catalogue=catalogue)
    assert raised.value.reason == f"latest as GitHub publishes it does not hold together: {SIGNED_BY_ANOTHER.reason}"
    assert catalogue.fetched == ["v0.5.0", "v0.6.1"], "from is vouched for before to is judged"
    with pytest.raises(PairDefect, match="^release 0.6.1 as GitHub publishes it"):
        resolve(pairs.THE_WHOLE_UPDATE, "checkout", "0.6.1", catalogue=Catalogue(broken={"0.6.1": SIGNED_BY_ANOTHER}))


def test_a_latest_without_its_assets_is_the_checks_failure_and_the_release_before_it_still_resolves():
    catalogue = Catalogue(latest_broken="GitHub marks v0.6.1 latest, and it has no appcast.xml among its assets")
    with pytest.raises(PairDefect, match="latest as GitHub publishes it does not hold together: GitHub marks v0.6.1"):
        resolve(pairs.A_PUBLISHED_RELEASE, catalogue=catalogue)


def test_a_from_that_does_not_hold_together_is_the_labs_and_never_the_checks_failure():
    """The lab installs "from" itself, and will not install what it cannot vouch for: "could not check"."""
    with pytest.raises(PairError) as raised:
        resolve(pairs.A_PUBLISHED_RELEASE, catalogue=Catalogue(broken={"0.5.0": SIGNED_BY_ANOTHER}))
    assert not isinstance(raised.value, PairDefect)
    with pytest.raises(PairError) as raised:
        resolve(pairs.THE_WRONG_KEY, "0.5.0", "checkout", catalogue=Catalogue(broken={"0.5.0": SIGNED_BY_ANOTHER}))
    assert not isinstance(raised.value, PairDefect)


def test_a_to_that_could_not_be_fetched_is_could_not_check_and_not_a_defect():
    cut_short = ReleaseError("https://github.com/x/uDeck-0.6.1.zip did not answer this Mac whole: IncompleteRead")
    with pytest.raises(PairError) as raised:
        resolve(pairs.A_PUBLISHED_RELEASE, catalogue=Catalogue(broken={"0.6.1": cut_short}))
    assert not isinstance(raised.value, PairDefect) and "IncompleteRead" in raised.value.reason


def test_a_pair_that_would_be_refused_is_refused_even_when_its_to_is_broken():
    """A refusal is about the pair; a defect is about a release the pair could have run with."""
    def cannot_drive(args, **kwargs):
        return subprocess.CompletedProcess(args, 0 if "rev-parse" in args else 1, "", "")

    broken = Catalogue(broken={"0.5.0": SIGNED_BY_ANOTHER})
    with pytest.raises(PairError) as raised:
        resolve(pairs.A_PUBLISHED_RELEASE, "0.6.1", "0.5.0", catalogue=broken)
    assert not isinstance(raised.value, PairDefect)
    assert "release 0.5.0 is not newer than release 0.6.1" in raised.value.reason and "said by version" in raised.value.reason
    with pytest.raises(PairError, match="no section.about") as raised:
        resolve(pairs.A_PUBLISHED_RELEASE, "0.4.0", "latest", catalogue=Catalogue(broken={"0.6.1": SIGNED_BY_ANOTHER}),
                run=cannot_drive)  # fmt: skip
    assert not isinstance(raised.value, PairDefect)


def test_a_broken_to_that_is_not_newer_than_a_checkout_is_refused_and_never_judged():
    """The skeptic's probe of 2026-10-09: `--from checkout --to 0.1.0` was refused with 0.1.0 whole, and red
    with 0.1.0 broken — a verdict on a pair the lab never runs. A build of this checkout going to a release is
    numbered 1; where the broken release's appcast says its number, that number decides, as it does for a
    release that holds together."""
    numbered_1 = ReleaseDefect("the appcast's edSignature does not hold over uDeck-0.4.0.zip", "1")
    with pytest.raises(PairError) as raised:
        resolve(pairs.THE_WHOLE_UPDATE, "checkout", "0.4.0", catalogue=Catalogue(broken={"0.4.0": numbered_1}))
    assert not isinstance(raised.value, PairDefect)
    assert raised.value.reason.startswith(
        "release 0.4.0 (1) is not newer than checkout as 0.4.1 (1) by CFBundleVersion, the number Sparkle compares "
        "(1, as its appcast offers it, against 1): there would be no update to check"
    )
    assert "does not hold over uDeck-0.4.0.zip" in raised.value.reason, "the defect is said, not lost"

    numbered_5 = ReleaseDefect("the appcast's edSignature does not hold over uDeck-0.4.0.zip", "5")
    with pytest.raises(PairDefect, match="^release 0.4.0 as GitHub publishes it does not hold together"):
        resolve(pairs.THE_WHOLE_UPDATE, "checkout", "0.4.0", catalogue=Catalogue(broken={"0.4.0": numbered_5}))


def test_a_broken_first_release_whose_number_could_not_be_read_is_refused_to_a_checkout_by_the_order_alone():
    """No appcast read — a zip GitHub says is not there — and the release is the first GitHub publishes, which
    is the one a build of this checkout, numbered below every release but the first, has no update to."""
    unread = ReleaseDefect("GitHub answered 404 for https://github.com/x/v0.4.0/uDeck-0.4.0.zip, an asset its own API lists")
    with pytest.raises(PairError) as raised:
        resolve(pairs.THE_WHOLE_UPDATE, "checkout", "0.4.0", catalogue=Catalogue(broken={"0.4.0": unread}))
    assert not isinstance(raised.value, PairDefect)
    assert raised.value.reason.startswith(
        "release 0.4.0 is the first release GitHub publishes, and a build of this checkout going to a release is "
        "numbered 1, below every release but the first, so there would be no update to check"
    )
    for later in ("0.5.0", "0.6.1"):
        with pytest.raises(PairDefect):
            resolve(pairs.THE_WHOLE_UPDATE, "checkout", later, catalogue=Catalogue(broken={later: unread}))
    with pytest.raises(PairDefect, match="^latest as GitHub publishes it"):
        resolve(pairs.THE_WHOLE_UPDATE, "checkout", "latest", catalogue=Catalogue(latest_broken="no appcast.xml"))
    with pytest.raises(PairError) as raised:
        resolve(pairs.THE_WHOLE_UPDATE, "checkout", "latest",
                catalogue=Catalogue(latest="0.4.0", latest_broken="GitHub marks v0.4.0 latest, and it has no zip"))  # fmt: skip
    assert not isinstance(raised.value, PairDefect) and "0.4.0 is the first release GitHub publishes" in raised.value.reason


def test_a_broken_to_whose_appcast_numbers_it_below_a_release_from_is_refused_by_that_number():
    numbered_6 = ReleaseDefect("uDeck-0.5.0.zip is 99 bytes and its appcast says 100", "6")
    with pytest.raises(PairError) as raised:
        resolve(pairs.A_PUBLISHED_RELEASE, "0.6.1", "0.5.0", catalogue=Catalogue(broken={"0.5.0": numbered_6}))
    assert not isinstance(raised.value, PairDefect)
    assert "release 0.5.0 (6) is not newer than release 0.6.1 (8) by CFBundleVersion" in raised.value.reason
    assert "(6, as its appcast offers it, against 8)" in raised.value.reason
    with pytest.raises(PairDefect):
        resolve(pairs.A_PUBLISHED_RELEASE, "0.5.0", "0.6.1",
                catalogue=Catalogue(broken={"0.6.1": ReleaseDefect("a length disagrees", "8")}))  # fmt: skip


def test_a_broken_to_whose_appcast_number_is_no_number_is_refused_as_one_that_holds_would_be():
    garbled = ReleaseDefect("the appcast's edSignature does not hold over uDeck-0.6.1.zip", "eight")
    with pytest.raises(PairError) as raised:
        resolve(pairs.A_PUBLISHED_RELEASE, "0.5.0", "0.6.1", catalogue=Catalogue(broken={"0.6.1": garbled}))
    assert not isinstance(raised.value, PairDefect)
    assert raised.value.reason.startswith("0.6.1's CFBundleVersion 'eight', as its appcast offers it, is not a number")


# --- Not newer: a refusal of a pair someone gave, a finding in the lab's own -----------------------
#
# The skeptic's probes of 2026-10-09 (P1, P2), on the lab's own pair with 0.5.0 (6) the release before latest: a
# latest numbered 6 again — whole, or broken with its zip saying 9 and its appcast 6 — was "could not check".
# Every uDeck 0.5.0 would say it is up to date: GitHub publishing that is what the check exists to catch.

NOT_BUMPED = {"0.6.1": "6"}

LATEST_NOT_NEWER = (
    "latest, release 0.6.1 (6), is not newer than the release before it, release 0.5.0 (6), by CFBundleVersion, the "
    "number Sparkle compares (6 against 6): every uDeck 0.5.0 that looks would say it is up to date, and never be "
    "offered 0.6.1"
)


def test_in_the_labs_own_pair_a_latest_not_newer_than_the_one_before_is_the_checks_failure():
    """P1: latest whole, its CFBundleVersion never raised above the release before it."""
    with pytest.raises(PairDefect) as raised:
        resolve(pairs.A_PUBLISHED_RELEASE, catalogue=Catalogue(builds=NOT_BUMPED))
    assert raised.value.reason == LATEST_NOT_NEWER
    assert raised.value.headline == pairs.NOT_NEWER_THAN_THE_ONE_BEFORE
    with pytest.raises(PairDefect, match=r"\(5 against 6\): every uDeck 0\.5\.0"):
        resolve(pairs.A_PUBLISHED_RELEASE, catalogue=Catalogue(builds={"0.6.1": "5"}))


def test_the_labs_own_pair_asked_with_to_latest_alone_is_the_same_question_and_the_same_failure():
    """Nobody types the release before latest: with `--to latest` alone, "from" is still the lab's choice."""
    pair, given = pairs.asked(pairs.A_PUBLISHED_RELEASE, None, "latest")
    assert pair == pairs.THE_RELEASE_BEFORE_LATEST_TO_LATEST and given
    with pytest.raises(PairDefect) as raised:
        resolve(pairs.A_PUBLISHED_RELEASE, None, "latest", catalogue=Catalogue(builds=NOT_BUMPED))
    assert raised.value.reason == LATEST_NOT_NEWER


@pytest.mark.parametrize(("from_text", "to_text"), [("0.5.0", None), ("0.5.0", "latest"), ("0.5.0", "0.6.1")])
def test_a_given_pair_whose_to_is_not_newer_is_refused_and_never_judged(from_text, to_text):
    """The same two releases, named by whoever runs the lab: a request for an update there is none of."""
    with pytest.raises(PairError) as raised:
        resolve(pairs.A_PUBLISHED_RELEASE, from_text, to_text, catalogue=Catalogue(builds=NOT_BUMPED))
    assert not isinstance(raised.value, PairDefect)
    assert "is not newer than release 0.5.0 (6) by CFBundleVersion" in raised.value.reason
    assert "(6 against 6): uDeck would say it is up to date, and there would be no update to check" in raised.value.reason


# P2: latest broken, its zip saying 9 and its appcast 6 — the number Sparkle compares is the appcast's.
BROKEN_AND_NOT_NEWER = ReleaseDefect(
    "uDeck-0.6.1.zip is not the release its tag and appcast name: CFBundleVersion is '9', not '6' "
    "(GitHub's copies are kept in .build/e2e/releases/v0.6.1/)",
    "6",
)


def test_in_the_labs_own_pair_a_broken_latest_not_newer_is_the_checks_failure_saying_both():
    """P2 exactly: red, never "could not check", and the defect said with it."""
    with pytest.raises(PairDefect) as raised:
        resolve(pairs.A_PUBLISHED_RELEASE, catalogue=Catalogue(broken={"0.6.1": BROKEN_AND_NOT_NEWER}))
    assert raised.value.reason == (
        "latest, release 0.6.1 (6), is not newer than the release before it, release 0.5.0 (6), by CFBundleVersion, "
        "the number Sparkle compares (6, as its appcast offers it, against 6): every uDeck 0.5.0 that looks would say "
        f"it is up to date, and never be offered 0.6.1 — and 0.6.1 as GitHub publishes it does not hold together: "
        f"{BROKEN_AND_NOT_NEWER.reason}"
    )
    assert raised.value.headline == pairs.NOT_NEWER_THAN_THE_ONE_BEFORE


def test_a_given_pair_whose_broken_to_is_not_newer_is_refused_with_the_defect_said():
    with pytest.raises(PairError) as raised:
        resolve(pairs.A_PUBLISHED_RELEASE, "0.5.0", catalogue=Catalogue(broken={"0.6.1": BROKEN_AND_NOT_NEWER}))
    assert not isinstance(raised.value, PairDefect)
    assert raised.value.reason.startswith("release 0.6.1 (6) is not newer than release 0.5.0 (6) by CFBundleVersion")
    assert "CFBundleVersion is '9', not '6'" in raised.value.reason


def test_in_the_labs_own_pair_a_broken_release_before_latest_is_never_compared_by_its_appcast():
    """Sparkle compares the offer with the installed bundle's own number — the zip's — and a release before latest
    that does not hold together does not vouch for it: its appcast's number may not be its zip's (skeptic 5 of
    2026-10-09: an appcast saying 8 over a zip saying 6 made a latest numbered 8 red). It is the lab's, as any "from"
    it cannot vouch for, whatever its appcast says."""
    for appcast_says in ("8", "9", "6", None):
        defect = ReleaseDefect("uDeck-0.5.0.zip is not the release its tag and appcast name: CFBundleVersion is '6'",
                               appcast_says)
        with pytest.raises(PairError) as raised:
            resolve(pairs.A_PUBLISHED_RELEASE, catalogue=Catalogue(broken={"0.5.0": defect}))
        assert not isinstance(raised.value, PairDefect), appcast_says
        assert raised.value.reason == defect.reason

    # A latest broken on its own is still the check's failure, however broken the release before it is.
    broken_before = ReleaseDefect("the appcast's edSignature does not hold over uDeck-0.5.0.zip", "8")
    with pytest.raises(PairDefect, match="^latest as GitHub publishes it does not hold together"):
        resolve(pairs.A_PUBLISHED_RELEASE,
                catalogue=Catalogue(broken={"0.5.0": broken_before, "0.6.1": SIGNED_BY_ANOTHER}))  # fmt: skip


def test_in_the_labs_own_pair_what_the_lab_cannot_do_comes_after_what_github_publishes_wrong():
    """A release before latest whose window the lab cannot drive, or that ships another feed, is "could not check"
    — after the finding, which needs no window driven."""
    def cannot_drive(args, **kwargs):
        return subprocess.CompletedProcess(args, 0 if "rev-parse" in args else 1, "", "")

    elsewhere = "https://example.com/appcast.xml"
    for catalogue, run in [(Catalogue(builds=NOT_BUMPED), cannot_drive),
                           (Catalogue(builds=NOT_BUMPED, feeds={"0.5.0": elsewhere}), can_drive)]:  # fmt: skip
        with pytest.raises(PairDefect, match="^latest, release 0.6.1 \\(6\\), is not newer"):
            resolve(pairs.A_PUBLISHED_RELEASE, catalogue=catalogue, run=run)
    with pytest.raises(PairDefect, match="^latest as GitHub publishes it does not hold together"):
        resolve(pairs.A_PUBLISHED_RELEASE, catalogue=Catalogue(broken={"0.6.1": SIGNED_BY_ANOTHER}), run=cannot_drive)
    with pytest.raises(PairError, match="gives its settings window no section.about") as raised:
        resolve(pairs.A_PUBLISHED_RELEASE, run=cannot_drive)
    assert not isinstance(raised.value, PairDefect)


def test_in_the_labs_own_pair_a_number_the_lab_cannot_compare_is_the_labs_and_a_latest_without_one_is_judged_alone():
    with pytest.raises(PairError, match="0.6.1's CFBundleVersion 'eight' is not a number the lab can compare") as raised:
        resolve(pairs.A_PUBLISHED_RELEASE, catalogue=Catalogue(builds={"0.6.1": "eight"}))
    assert not isinstance(raised.value, PairDefect)
    # A latest whose number was never read — its zip and appcast not there — is judged by its defect alone.
    unread = ReleaseDefect("GitHub answered 404 for https://github.com/x/v0.6.1/appcast.xml, an asset its own API lists")
    with pytest.raises(PairDefect, match="^latest as GitHub publishes it does not hold together: GitHub answered 404"):
        resolve(pairs.A_PUBLISHED_RELEASE, catalogue=Catalogue(broken={"0.6.1": unread}))


def test_where_an_appcast_sends_udeck_is_asked_only_of_the_release_offered():
    """Nothing reads the enclosure of "from": the lab installs its zip, and Sparkle downloads "to"."""
    resolved = resolve(pairs.A_PUBLISHED_RELEASE, catalogue=Catalogue(elsewhere=("0.5.0",)))
    assert resolved.from_.version == "0.5.0" and resolved.from_.elsewhere
    assert str(resolve(pairs.A_PUBLISHED_RELEASE, "0.5.0", "0.6.1", catalogue=Catalogue(elsewhere=("0.5.0",))))
    with pytest.raises(PairDefect, match="sends uDeck to https://nowhere.invalid/"):
        resolve(pairs.A_PUBLISHED_RELEASE, catalogue=Catalogue(elsewhere=("0.6.1",)))
    with pytest.raises(PairDefect, match="^release 0.6.1 as GitHub publishes it does not hold together: the appcast"):
        resolve(pairs.THE_WHOLE_UPDATE, "checkout", "0.6.1", catalogue=Catalogue(elsewhere=("0.6.1",)))


def test_a_release_offered_latest_has_to_ship_the_latest_feed_or_the_pair_proves_no_redirect():
    """"via the real feed" is said of a pair only when it is true: "from" asks it untouched, so "from" must carry it."""
    elsewhere = "https://example.com/appcast.xml"
    with pytest.raises(PairError) as raised:
        resolve(pairs.A_PUBLISHED_RELEASE, catalogue=Catalogue(feeds={"0.5.0": elsewhere}))
    assert f"0.5.0 ships with {elsewhere} as its feed, not the latest feed" in raised.value.reason
    assert not isinstance(raised.value, PairDefect)
    named = resolve(pairs.A_PUBLISHED_RELEASE, "0.5.0", "0.6.1", catalogue=Catalogue(feeds={"0.5.0": elsewhere}))
    assert str(named).endswith("via its own appcast"), "by name, the feed is written into the guest anyway"


def test_the_checks_about_looking_by_itself_say_nothing_is_offered_rather_than_name_a_build_never_made():
    resolved = pairs.resolve(pairs.ONLY_THIS_CHECKOUT, pairs.BETWEEN_CHECKOUTS, False, None, ROOT)
    assert resolved.from_ == Checkout("0.4.1", "6") and resolved.to is None
    assert str(resolved) == (
        "checkout as 0.4.1 (6) → nothing offered: the lab's feed in the guest is empty, "
        "and the check ends at uDeck asking it"
    )
    assert resolved.ledger()["to"] == {"side": "checkout", "offered": False, "feed": "the lab's own, empty"}
