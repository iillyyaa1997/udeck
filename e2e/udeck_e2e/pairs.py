"""Which two versions of uDeck an update check runs between: its pair, "from → to".

Every update check installs one uDeck and asks what happens when it meets the
next. Each end of that is one of three things, written on the command line as
`--from` and `--to`:

* `checkout` — a build of this checkout, made by the lab (`builds`);
* a published release, as its version — `0.5.0`;
* `latest` — the release GitHub marks latest.

A check that takes a pair says so with `@pairs.takes(rule)`, and the rule says
what it asks with nothing given (its default) and which pairs it cannot ask its
question about at all. Those are refused before anything starts, with the reason
— never run and never quietly swapped for something else. Which pair a check ran
with is written into the ledger and under its line in the report, resolved: the
versions and build numbers, and how "to" reaches "from".

**The two builds of this checkout** an update between checkouts is made of are
0.4.1 (6) and 0.4.2 (7), as they always have been; neither was ever released, so
a lab build cannot be mistaken for a release. Beside a release they are numbered
by it, because `CFBundleVersion` is what Sparkle compares: a build of this
checkout going *to* a release is 0.4.1 (1), below every release but the first,
and carries that release's public key — the private half lives only in GitHub's
secrets, so the public half is the only way a build of the lab's can accept what
the release key signed. A build *offered to* a release is 0.4.2, numbered one
above it, and carries the lab's own key.

**What is never possible** is a release going to a build of this checkout that
it accepts: that build would have to be signed by the release key. A release
offered a build signed with the lab's key is exactly the wrong-key control with a
real "from" (`updates.wrong-key --from 0.5.0`), and that is what it is for.

**A "to" that GitHub publishes broken is a finding, not a pair that could not be
resolved.** When the release a check is offered does not hold together — its
appcast's signature does not hold over its zip under the key that zip carries, a
length or a version disagrees, the appcast sends uDeck elsewhere than the zip
GitHub's API lists, latest lacks an asset (`releases.ReleaseDefect`) —
that is exactly what the check by a published release exists to catch, and it is
the check's failure (`PairDefect`), measured on this Mac before any machine is
made. The same of "from" is not a finding: the lab will not install what it
cannot vouch for, and a "from" it cannot vouch for is "could not check".

**"To" not newer than "from" is a refusal of a pair someone gave — and a finding
in the lab's own.** A pair given on the command line whose "to" is not newer
than its "from" by `CFBundleVersion` asks for an update there is none of: it is
refused, broken "to" or whole, before any verdict, and a defect found in that
"to" is said with the refusal, never judged. The lab's own pair, the release
before latest → latest (`THE_RELEASE_BEFORE_LATEST_TO_LATEST`, whose "from"
nobody can type), asks whether what GitHub publishes as latest is an update to
the release before it; a latest that is not newer is GitHub's publishing being
wrong — every uDeck on the release before latest would say it is up to date —
and that is the check's failure, whatever else is broken in latest; a release
before latest that does not hold together is never compared (`_the_labs_own_pair`).
"""

from __future__ import annotations

import re
import subprocess
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from udeck_e2e import config, releases
from udeck_e2e.releases import Release

CHECKOUT = "checkout"
LATEST = "latest"
# The default "from" of the check by a published release. Never typed: on the
# command line a release is named by its version.
BEFORE_LATEST = "before-latest"

_VERSION = re.compile(r"^\d+\.\d+\.\d+$")

# The two builds of this checkout an update between checkouts is made of.
CHECKOUT_FROM = ("0.4.1", "6")
CHECKOUT_TO = ("0.4.2", "7")
# A build of this checkout going to a release: below every release but the first.
CHECKOUT_BELOW_A_RELEASE = ("0.4.1", "1")
# A build of this checkout offered to a release keeps 0.4.2 and is numbered one
# above the release it is offered to.
CHECKOUT_ABOVE_A_RELEASE = "0.4.2"

# What the build of this checkout a check offers is signed with, as the ledger says
# it — apart from the public key a build carries, which is a different question.
SIGNED_WITH_THE_RUNS_KEY = "the run's own key"
SIGNED_WITH_ANOTHER_KEY = 'another key, made for the check, which "from" does not carry'


class PairError(Exception):
    """A pair the lab cannot run, or could not resolve — and why, in one sentence."""

    def __init__(self, reason: str) -> None:
        super().__init__(reason)
        self.reason = reason


class PairDefect(PairError):
    """A pair whose "to" is a release GitHub publishes wrong: the check's failure, found on this Mac.

    Broken — a release that does not hold together — or, in the lab's own pair, a
    latest that is not newer than the release before it. `headline` is what the
    report's pair line says of it, the reason in a few words.
    """

    def __init__(self, reason: str, headline: str = 'its "to" as GitHub publishes it does not hold together') -> None:
        super().__init__(reason)
        self.headline = headline


NOT_NEWER_THAN_THE_ONE_BEFORE = "latest as GitHub publishes it is not newer than the release before it"


@dataclass(frozen=True)
class Side:
    """One end of an update as it was asked for, before anything is fetched or built."""

    name: str

    @property
    def is_checkout(self) -> bool:
        return self.name == CHECKOUT

    def __str__(self) -> str:
        return "the release before latest" if self.name == BEFORE_LATEST else self.name


def side(text: str) -> Side:
    """One end of an update, as `--from` and `--to` take it: checkout, latest, or a release's version."""
    if text in (CHECKOUT, LATEST) or _VERSION.match(text):
        return Side(text)
    hint = f" — without the v: {text[1:]}" if re.match(r"^v\d+\.\d+\.\d+$", text) else ""
    raise PairError(
        f"{text!r} is not one end of an update{hint}: write checkout, latest, "
        "or a published release as its version, such as 0.5.0"
    )


@dataclass(frozen=True)
class Pair:
    from_: Side
    to: Side

    def __str__(self) -> str:
        return f"{self.from_} → {self.to}"


BETWEEN_CHECKOUTS = Pair(Side(CHECKOUT), Side(CHECKOUT))
THE_RELEASE_BEFORE_LATEST_TO_LATEST = Pair(Side(BEFORE_LATEST), Side(LATEST))

# Why a release can never go to a build of this checkout that it installs.
_RELEASE_TO_CHECKOUT = (
    "a release installs only what the release key signed, and its private half lives in GitHub's secrets, so "
    "the lab cannot sign a build of this checkout that a release would install; a release offered a build signed "
    "with the lab's key is updates.wrong-key's control"
)


@dataclass(frozen=True)
class Rule:
    """What one check asks with nothing given, and which pairs it cannot ask its question about."""

    default: Pair
    # Whether the check presses "Check now" and Install in "from"'s own window, so
    # that a release can be "from" only if the lab can drive its window.
    presses_check_now: bool = True
    # Whether "to" is ever offered. The two checks about looking by itself end at
    # uDeck's request, to a feed that offers nothing, and their pair says so
    # rather than name a build that is never made.
    offers: bool = True

    def refusal(self, pair: Pair) -> str | None:  # pragma: no cover — every rule says its own
        raise NotImplementedError

    def offer_signed_with(self, from_: End) -> str:
        """What the build of this checkout this check offers "from" is signed with."""
        return SIGNED_WITH_THE_RUNS_KEY


@dataclass(frozen=True)
class TheWholeUpdate(Rule):
    """`updates.sparkle`: an update installs and uDeck comes back as it — between any two that can be."""

    def refusal(self, pair: Pair) -> str | None:
        if not pair.from_.is_checkout and pair.to.is_checkout:
            return _RELEASE_TO_CHECKOUT
        return None


@dataclass(frozen=True)
class APublishedRelease(Rule):
    """`updates.a-published-release`: the update is a release, and reaches uDeck from GitHub."""

    def refusal(self, pair: Pair) -> str | None:
        if pair.to.is_checkout and not pair.from_.is_checkout:
            return _RELEASE_TO_CHECKOUT
        if pair.to.is_checkout:
            return (
                'its "to" is a build of this checkout, and this check is about a published release reaching '
                "uDeck from GitHub; checkout → checkout is updates.sparkle"
            )
        return None


def signs_with_another_key(from_: End) -> bool:
    """Whether `updates.wrong-key` signs its offer with a key of its own: "from" a build of this checkout, which
    carries the run's key. A release trusts only the release key, so the run's own key is already the wrong one."""
    return isinstance(from_, Checkout)


@dataclass(frozen=True)
class TheWrongKey(Rule):
    """`updates.wrong-key`: the same offer, signed with a key "from" does not trust, is refused."""

    def offer_signed_with(self, from_: End) -> str:
        if signs_with_another_key(from_):
            return SIGNED_WITH_ANOTHER_KEY
        return f"{SIGNED_WITH_THE_RUNS_KEY}, which no release trusts"

    def refusal(self, pair: Pair) -> str | None:
        if not pair.to.is_checkout:
            return (
                "a published release is signed with the release key, the key every release trusts, and comes from "
                "GitHub, where the guest's own server — this control's witness that uDeck fetched the archive — never "
                'sees it; the control\'s "to" is a build of this checkout signed with a key "from" does not trust'
            )
        return None


@dataclass(frozen=True)
class OnlyThisCheckout(Rule):
    """The two checks about uDeck looking by itself: they end at a request, so only checkout → checkout."""

    def refusal(self, pair: Pair) -> str | None:
        if pair.from_.is_checkout and pair.to.is_checkout:
            return None
        return (
            "this check ends at uDeck asking the lab's own feed on the guest's loopback — nothing is offered or "
            'installed, so there is no "to" to choose — and asks it of what this checkout ships, so its only pair '
            "is checkout → checkout"
        )


THE_WHOLE_UPDATE = TheWholeUpdate(BETWEEN_CHECKOUTS)
A_PUBLISHED_RELEASE = APublishedRelease(THE_RELEASE_BEFORE_LATEST_TO_LATEST)
THE_WRONG_KEY = TheWrongKey(BETWEEN_CHECKOUTS)
ONLY_THIS_CHECKOUT = OnlyThisCheckout(BETWEEN_CHECKOUTS, presses_check_now=False, offers=False)


def takes(rule: Rule) -> Callable[[Callable[..., Any]], Callable[..., Any]]:
    """Mark a check as one that takes a pair, under `rule`."""

    def mark(check: Callable[..., Any]) -> Callable[..., Any]:
        check.pair_rule = rule  # type: ignore[attr-defined]
        return check

    return mark


def rule_of(check: Any) -> Rule | None:
    rule = getattr(check, "pair_rule", None)
    return rule if isinstance(rule, Rule) else None


def asked(rule: Rule, from_text: str | None, to_text: str | None) -> tuple[Pair, bool]:
    """The pair a check is asked to run with — what was given, the rest from its default — and whether anything was given."""
    from_ = side(from_text) if from_text is not None else rule.default.from_
    to = side(to_text) if to_text is not None else rule.default.to
    return Pair(from_, to), from_text is not None or to_text is not None


@dataclass(frozen=True)
class Checkout:
    """A build of this checkout the lab will make: its two version keys, and whose public key it carries."""

    version: str
    build: str
    # The release whose public key it carries; None for the run's own key.
    key_of: Release | None = None

    @property
    def keys(self) -> tuple[str, str]:
        return self.version, self.build

    @property
    def public_key(self) -> str | None:
        return self.key_of.public_key if self.key_of is not None else None


End = Checkout | Release


@dataclass(frozen=True)
class Resolved:
    """A pair as a check runs it: both ends known down to their build numbers."""

    asked: Pair
    given: bool
    from_: End
    # None when nothing is offered: the lab's feed in the guest is empty (`Rule.offers`).
    to: End | None
    # What "to" is signed with when it is a build of this checkout (`Rule.offer_signed_with`); None otherwise.
    offer_signed_with: str | None = None

    @property
    def to_by_the_latest_feed(self) -> bool:
        """Whether "to" was asked as latest — and so reaches "from" through the real feed, untouched."""
        return self.asked.to.name == LATEST

    def __str__(self) -> str:
        return f"{self._from_text()} → {self._to_text()}"

    def how_asked(self) -> str:
        return f"{'--from/--to' if self.given else 'default'}: {self.asked}"

    def _from_text(self) -> str:
        end = self.from_
        if isinstance(end, Checkout):
            key = f" with {end.key_of.version}'s public key" if end.key_of is not None else ""
            return f"checkout as {end.version} ({end.build}){key}"
        return f"release {end.version} ({end.build}){self._which(self.asked.from_)}"

    def _to_text(self) -> str:
        end = self.to
        if end is None:
            return "nothing offered: the lab's feed in the guest is empty, and the check ends at uDeck asking it"
        if isinstance(end, Checkout):
            signed = f", signed with {self.offer_signed_with}," if self.offer_signed_with is not None else ""
            return f"checkout as {end.version} ({end.build}){signed} via the lab's feed in the guest"
        via = "the real feed" if self.to_by_the_latest_feed else "its own appcast"
        which = self._which(self.asked.to)
        return f"release {end.version} ({end.build}){which}{',' if which else ''} via {via}"

    @staticmethod
    def _which(asked_as: Side) -> str:
        return {LATEST: ", latest", BEFORE_LATEST: ", the release before latest"}.get(asked_as.name, "")

    def ledger(self) -> dict[str, Any]:
        return {
            "text": str(self),
            "asked": str(self.asked),
            "given": self.given,
            "from": _end_for_ledger(self.from_, self.asked.from_),
            "to": _end_for_ledger(self.to, self.asked.to, self.offer_signed_with),
        }


def _end_for_ledger(end: End | None, asked_as: Side, signed_with: str | None = None) -> dict[str, Any]:
    if end is None:
        return {"side": CHECKOUT, "offered": False, "feed": "the lab's own, empty"}
    if isinstance(end, Checkout):
        # "carries": the SUPublicEDKey in the build's own Info.plist — what it
        # trusts. "signed_with": what an offered build is signed with — what it is
        # trusted by. Two keys, said apart, so the control's offer never reads as
        # one signed with the key "from" trusts.
        said = {
            "side": CHECKOUT,
            "version": end.version,
            "build": end.build,
            "carries": (f"the public key of release {end.key_of.version}" if end.key_of is not None
                        else "the run's own public key"),
        }  # fmt: skip
        if signed_with is not None:
            said["signed_with"] = signed_with
        return said
    return {
        "side": "release",
        "asked_as": asked_as.name,
        "version": end.version,
        "build": end.build,
        "tag": end.tag,
        "zip": end.zip.name,
        "zip_sha256": end.sha256,
        "zip_bytes": end.length,
        "public_key": end.public_key,
        "appcast": end.own_appcast,
    }


def resolve(
    rule: Rule,
    pair: Pair,
    given: bool,
    catalogue: releases.Catalogue | None,
    repo_root: Path,
    run: Callable[..., subprocess.CompletedProcess[str]] = subprocess.run,
) -> Resolved:
    """Both ends of `pair`, known: releases found, fetched and checked; builds of this checkout numbered.

    Raises PairError for a pair that cannot be run — said in a sentence a person
    can act on, whether the reason is GitHub not answering, a release that does
    not exist, a "to" that is not newer, or a "from" whose window the lab cannot
    drive. Raises PairDefect, once everything that would refuse the pair has been
    asked, when "to" is a release GitHub publishes broken (`releases.ReleaseDefect`):
    a broken "to" is still asked whether it is newer than "from"
    (`_refused_whatever_to_holds`), so the verdict never lands on a pair the lab
    would not run. The lab's own pair, the release before latest → latest, is
    asked the other way round (`_the_labs_own_pair`): what is wrong with what
    GitHub publishes first, a latest not newer than the release before it among
    it, and only then what the lab cannot do.
    """
    refused = rule.refusal(pair)
    if refused:
        raise PairError(refused)
    if pair.from_.is_checkout and pair.to.is_checkout:
        from_checkout = Checkout(*CHECKOUT_FROM)
        if not rule.offers:
            return Resolved(pair, given, from_checkout, None)
        return Resolved(pair, given, from_checkout, Checkout(*CHECKOUT_TO), rule.offer_signed_with(from_checkout))
    if catalogue is None:
        raise PairError("this run has no way to ask GitHub about releases")
    if pair == THE_RELEASE_BEFORE_LATEST_TO_LATEST:
        return _the_labs_own_pair(rule, pair, given, catalogue, repo_root, run)
    defect: releases.ReleaseDefect | None = None
    to_published: releases.Published | None = None
    to_release: Release | None = None
    try:
        from_published = _published(catalogue, pair.from_)
        try:
            to_published = _published(catalogue, pair.to)
        except releases.ReleaseDefect as broken:
            defect = broken
        if from_published is not None and rule.presses_check_now:
            problem = releases.check_now_problem(repo_root, from_published, run)
            if problem:
                raise PairError(problem)
        # "from" is what the lab installs itself, so a "from" it cannot vouch
        # for is the lab's to say, defect or not.
        from_release = catalogue.fetch(from_published) if from_published is not None else None
        if from_release is not None and pair.to.name == LATEST:
            no_redirect = _proves_no_latest_redirect(from_release)
            if no_redirect:
                raise PairError(no_redirect)
        if to_published is not None:
            try:
                to_release = catalogue.fetch(to_published, offered=True)
            except releases.ReleaseDefect as broken:
                defect = broken
        refused = _refused_whatever_to_holds(catalogue, from_release, to_published, defect) if defect else None
    except releases.ReleaseError as error:
        raise PairError(error.reason) from None

    if defect is not None:
        if refused:
            raise PairError(refused)
        raise PairDefect(f"{_asked_as_words(pair.to)} as GitHub publishes it does not hold together: {defect.reason}")

    # One of the two is a release: two builds of this checkout returned above.
    from_end: End = from_release or Checkout(*CHECKOUT_BELOW_A_RELEASE, key_of=to_release)
    to_end: End = to_release or Checkout(CHECKOUT_ABOVE_A_RELEASE, str(_number(from_end.build, from_end) + 1))
    resolved = Resolved(pair, given, from_end, to_end,
                        rule.offer_signed_with(from_end) if isinstance(to_end, Checkout) else None)  # fmt: skip
    if _order(to_end.build, to_end) <= _order(from_end.build, from_end):
        raise PairError(
            f"{resolved._to_text()} is not newer than {resolved._from_text()} by CFBundleVersion, the number Sparkle "
            f"compares ({to_end.build} against {from_end.build}): uDeck would say it is up to date, and there would "
            "be no update to check"
        )
    return resolved


def _the_labs_own_pair(
    rule: Rule,
    pair: Pair,
    given: bool,
    catalogue: releases.Catalogue,
    repo_root: Path,
    run: Callable[..., subprocess.CompletedProcess[str]],
) -> Resolved:
    """The release before latest → latest: whether what GitHub publishes as latest is an update to the one before it.

    Nobody types the release before latest, so this pair is always the lab's
    question — asked with nothing given, or with `--to latest` alone — and what
    is wrong with what GitHub publishes is its answer before anything the lab
    cannot do:

    1. a latest not newer than the release before it by CFBundleVersion, which
       leaves every uDeck on the release before latest saying it is up to date —
       the check's failure (`PairDefect`) whatever else is broken in latest,
       latest's number read from its appcast where it does not hold together —
       the number Sparkle compares is the offer's — and its defects said with
       it. The release before latest is compared only when it holds together:
       Sparkle compares with the installed bundle's own number, its zip's,
       which a broken release does not vouch for (its appcast's may differ);
    2. latest broken on its own — the check's failure;
    3. only then the lab's, "could not check": a release before latest it cannot
       vouch for, cannot press its way to an update in, or that does not ship
       the latest feed, and a number it cannot compare.

    GitHub not answering is the lab's at once: what it would have served is not
    known. Both releases are fetched before the lab asks whether it can drive the
    one before latest, since the answer to 1 and 2 needs no window driven.
    """
    latest_published: releases.Published | None = None
    latest_release: Release | None = None
    latest_defect: releases.ReleaseDefect | None = None
    before_release: Release | None = None
    before_defect: releases.ReleaseDefect | None = None
    try:
        before_published = catalogue.before_latest()
        try:
            latest_published = catalogue.latest()
        except releases.ReleaseDefect as broken:
            latest_defect = broken
        try:
            before_release = catalogue.fetch(before_published)
        except releases.ReleaseDefect as broken:
            before_defect = broken
        if latest_published is not None:
            try:
                latest_release = catalogue.fetch(latest_published, offered=True)
            except releases.ReleaseDefect as broken:
                latest_defect = broken
        latest_version = latest_published.version if latest_published else catalogue.latest_tag().removeprefix("v")
    except releases.ReleaseError as error:
        raise PairError(error.reason) from None
    before_version = before_published.version

    latest_build, latest_by_its_appcast = _the_number_published(latest_release, latest_defect)
    # Only a release before latest that holds together: the number Sparkle compares with is the installed bundle's,
    # its zip's, and a broken one's appcast may say another.
    before_build = before_release.build if before_release is not None else None
    broken = [
        f"{latest_version} as GitHub publishes it does not hold together: {latest_defect.reason}"
    ] if latest_defect is not None else []
    if _not_newer(latest_build, before_build):
        by_its_appcast = ", as its appcast offers it"
        not_newer = (
            f"latest, release {latest_version} ({latest_build}), is not newer than the release before it, release "
            f"{before_version} ({before_build}), by CFBundleVersion, the number Sparkle compares ({latest_build}"
            f"{by_its_appcast + ',' if latest_by_its_appcast else ''} against {before_build}): every uDeck "
            f"{before_version} that looks would say "
            f"it is up to date, and never be offered {latest_version}"
        )
        raise PairDefect(" — and ".join([not_newer, *broken]), NOT_NEWER_THAN_THE_ONE_BEFORE)
    if latest_defect is not None:
        raise PairDefect(f"latest as GitHub publishes it does not hold together: {latest_defect.reason}")
    if before_defect is not None:
        # "from" is what the lab installs itself: one it cannot vouch for is the lab's to say.
        raise PairError(before_defect.reason)
    if before_release is None or latest_release is None:  # pragma: no cover — every path without one raised above
        raise PairError("the lab lost a release it had fetched")
    if rule.presses_check_now:
        problem = releases.check_now_problem(repo_root, before_published, run)
        if problem:
            raise PairError(problem)
    no_redirect = _proves_no_latest_redirect(before_release)
    if no_redirect:
        raise PairError(no_redirect)
    # A number the lab cannot compare is its own to say, as for any pair.
    _order(latest_release.build, latest_release)
    _order(before_release.build, before_release)
    return Resolved(pair, given, before_release, latest_release)


def _the_number_published(release: Release | None, defect: releases.ReleaseDefect | None) -> tuple[str | None, bool]:
    """A release's CFBundleVersion as GitHub publishes it — None when it is not known — and whether its appcast alone says it.

    A release that holds together is its zip's number, which its appcast says
    too; one that does not is the number its appcast offers, where that much
    was read (`releases.ReleaseError.build`).
    """
    if release is not None:
        return release.build, False
    if defect is not None and defect.build is not None:
        return defect.build, True
    return None, False


def _not_newer(to_build: str | None, from_build: str | None) -> bool:
    """Whether "to" is known to be no newer than "from" by CFBundleVersion — False when either is not a number."""
    if to_build is None or from_build is None:
        return False
    try:
        to_order = tuple(int(part) for part in to_build.split("."))
        from_order = tuple(int(part) for part in from_build.split("."))
    except ValueError:
        return False
    return to_order <= from_order


def _proves_no_latest_redirect(from_release: Release) -> str | None:
    """Why a release offered latest would not prove the latest redirect — or None when it ships the latest feed."""
    if from_release.shipped_feed == config.LATEST_FEED:
        return None
    return (
        f"{from_release.version} ships with {from_release.shipped_feed or 'no SUFeedURL'} as its feed, not "
        f"the latest feed ({config.LATEST_FEED}); a release offered latest is asked through the feed it "
        "ships with, untouched, and this one's would not prove the latest redirect"
    )


def _refused_whatever_to_holds(
    catalogue: releases.Catalogue,
    from_release: Release | None,
    to_published: releases.Published | None,
    defect: releases.ReleaseDefect,
) -> str | None:
    """Why a given pair would be refused even had "to" held together — or None, and the defect is the check's verdict.

    "To" not newer than "from" in a pair someone gave is a pair the lab never
    runs, whatever the release is; a defect found in it would be a verdict on a
    pair nobody may ask. (The lab's own pair is asked the other way round:
    `_the_labs_own_pair`.) Asked of what is known without "to" holding together: the
    CFBundleVersion its appcast offers for the zip, where that much was read
    (`ReleaseDefect.build`) — the number Sparkle compares, the same rule as
    for a "to" that holds; otherwise its version. A build of this checkout
    going to a release is numbered below every release but the first
    (`CHECKOUT_BELOW_A_RELEASE`), so by version alone it has no update to the
    first release GitHub publishes.
    """
    if to_published is not None:
        to_version, to_order = to_published.version, to_published.order
    else:
        # Only latest is a defect before its assets are known: one it lacks.
        match = releases.TAG.match(catalogue.latest_tag())
        if match is None:
            return None
        to_version, to_order = ".".join(match.groups()), tuple(int(part) for part in match.groups())
    from_end: End = from_release or Checkout(*CHECKOUT_BELOW_A_RELEASE)
    from_text = (f"release {from_end.version} ({from_end.build})" if from_release is not None
                 else f"checkout as {from_end.version} ({from_end.build})")  # fmt: skip
    if defect.build is not None:
        try:
            to_build = tuple(int(part) for part in defect.build.split("."))
        except ValueError:
            # Beside a "to" that holds, a number the lab cannot compare refuses the pair; so it does here.
            raise PairError(
                f"{to_version}'s CFBundleVersion {defect.build!r}, as its appcast offers it, is not a number the lab "
                f"can compare — and {to_version} as GitHub publishes it does not hold together: {defect.reason}"
            ) from None
        # "from"'s own number not being one refuses the pair too, as it does beside a "to" that holds.
        if to_build > _order(from_end.build, from_end):
            return None
        return (
            f"release {to_version} ({defect.build}) is not newer than {from_text} by CFBundleVersion, the number "
            f"Sparkle compares ({defect.build}, as its appcast offers it, against {from_end.build}): there would be no "
            f"update to check — and {to_version} as GitHub publishes it does not hold together: {defect.reason}"
        )
    if from_release is not None:
        if to_order > from_release.published.order:
            return None
        return (
            f"release {to_version} is not newer than release {from_release.version}, so there would be no update to "
            f"check — said by version, because {to_version}'s CFBundleVersion could not be read: {defect.reason}"
        )
    if any(published.order < to_order for published in catalogue.published()):
        return None
    return (
        f"release {to_version} is the first release GitHub publishes, and a build of this checkout going to a release "
        f"is numbered {from_end.build}, below every release but the first, so there would be no update to check — "
        f"said by the order of the releases, because {to_version}'s CFBundleVersion could not be read: {defect.reason}"
    )


def _asked_as_words(asked_as: Side) -> str:
    return {LATEST: "latest", BEFORE_LATEST: "the release before latest"}.get(asked_as.name, f"release {asked_as.name}")


def _published(catalogue: releases.Catalogue, asked_as: Side) -> releases.Published | None:
    if asked_as.is_checkout:
        return None
    if asked_as.name == LATEST:
        return catalogue.latest()
    if asked_as.name == BEFORE_LATEST:
        return catalogue.before_latest()
    return catalogue.named(asked_as.name)


def _order(build: str, end: End) -> tuple[int, ...]:
    try:
        return tuple(int(part) for part in build.split("."))
    except ValueError:
        raise PairError(f"{end.version}'s CFBundleVersion {build!r} is not a number the lab can compare") from None


def _number(build: str, end: End) -> int:
    order = _order(build, end)
    if len(order) != 1:
        raise PairError(f"{end.version}'s CFBundleVersion {build!r} is not one whole number, and the lab numbers its build above it")
    return order[0]
