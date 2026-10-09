"""uDeck as GitHub has published it: which releases exist, fetched, and checked before a guest sees one.

An update check's pair (`pairs`) can name a published release on either side — by
its version, as `latest`, or, for `updates.a-published-release` by default, as the
release before latest. This module answers which releases those are and brings
each one's two assets, its zip and its appcast, to this Mac.

**What exists is what GitHub's public API says.** The list of releases leaves out
drafts, pre-releases and anything without both assets, and a tag nobody made a
release of (v0.6.0) is not in it at all. Latest is GitHub's own mark
(`/releases/latest`), never merely the highest number. Asked without a token:
sixty questions an hour from one address, and this Mac asks two a run. They are
not the only ones from that address: a release that reads the plugin catalogue
(0.6.1 does) asks api.github.com from the guest when it starts, through Tart's
NAT — how many questions that is has not been measured.

**A zip is checked before anything uses it**, against its own appcast: the length
the appcast gives, the two version keys, and `sparkle:edSignature` over the zip
under the `SUPublicEDKey` that the zip's own Info.plist carries — the check
Sparkle makes, made here with the standard library (`ed25519`). So the release a
check installs is one the lab has vouched for, and the release a check is offered
is one whose own signature the lab has already seen hold: a guest that refuses it
is refusing it over the key the *installed* uDeck carries, which is the question.
Of the release a check is offered, one thing more: where its appcast sends uDeck
for the zip has to be the zip GitHub's API lists for that release
(`Catalogue.fetch(offered=True)`). Nothing reads that of a release the lab only
installs, so it is not asked of one.

**A release that does not hold together is a finding, not a fetch that failed.**
GitHub not answering, a download cut short, an API that will not say, GitHub in
trouble of its own (403, 429, a 5xx) — those are `ReleaseError`, and the lab could
not check. A zip and its appcast that disagree — a signature that does not hold
under the key the zip carries, another length, another version, no item for the
zip, an Info.plist that cannot be read — an offered release whose item sends uDeck
anywhere but the zip GitHub's API lists for it, a latest release without an asset,
and GitHub answering 404 or 410 for an asset its own API lists, are `ReleaseDefect`:
GitHub serves exactly that to every uDeck that asks, and when it is the release a
check is offered, that check fails on it (`pairs.PairDefect`). The guest holds
GitHub's answers to the same rule (`updates.github_answers`).

**A copy kept on this Mac is held to what GitHub lists now**: the size of each
asset and, where the API gives one, its SHA-256 `digest`. An asset re-published
under the same tag is fetched again rather than vouched for from an old copy —
by the digest, since every release's appcast so far is 932 bytes (read from the
API on 2026-10-09), so a size alone could not tell a new appcast from the old.

**A released zip is not a lab build.** It never goes through `builds.Builder`,
whose rules — the lab's own feed, the fake GitHub, local networking — a release
breaks by design, and those rules are not loosened for it. Like a lab build it is
never unpacked on this Mac: read in memory here, unpacked inside a guest by
`app.install`. The copies live under `.build/e2e/releases/<tag>/`, which git
ignores, and never in `dist/`.
"""

from __future__ import annotations

import base64
import binascii
import hashlib
import http.client
import json
import os
import plistlib
import re
import subprocess
import urllib.error
import urllib.request
import zipfile
import zlib
from collections.abc import Callable
from dataclasses import dataclass, replace
from datetime import datetime, timezone
from pathlib import Path
from typing import Any
from xml.etree import ElementTree
from xml.parsers.expat import ExpatError

from udeck_e2e import config, ed25519
from udeck_e2e.builds import INFO_PLIST

Note = Callable[[str], None]

# A release's tag, which is also how the lab reads its version: `v0.5.0`.
TAG = re.compile(r"^v(\d+)\.(\d+)\.(\d+)$")

# The release's own bundle identifier: a zip that carries another is not uDeck.
BUNDLE_ID = "place.unicorns.udeck"

_SPARKLE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"

# How many pages of the release list the lab reads, a hundred releases each.
_PAGES = 10

# GitHub saying an asset is not there. For an asset its own API lists, that is the
# release's — what every uDeck that asks for it meets — on this Mac and in the guest
# alike (`updates.github_answers`); any other answer but success is the network's.
ASSET_MISSING = (404, 410)

# What the lab presses on the way to an update, by the identifiers uDeck gives
# them: the About section, "Check now" and Install (`_open_the_about_pane`,
# `ui.click("updates.checkNow")` and `ui.wait_for("updates.install")` in
# checks/check_updates.py). A release whose own source names none of them is one
# whose settings window the lab cannot drive — its rows and buttons carry only
# their translated titles, which the lab does not press by. Read from the tags on
# 2026-10-09: v0.5.0 and v0.6.1 name all three, and v0.1.0, v0.2.1, v0.3.0 and
# v0.4.0 name none.
#
# The way into that window is not among them: for every check, release or
# checkout, uDeck's menu item is found by its English title `Settings…` and the
# window by `uDeck Settings` (`ui.open_settings_and_wait`), because the menu item
# carries no identifier. A release's source is not read for those two titles; a
# release that changed them would be "could not check" — no way in — not refused.
#
# Each identifier is found one of the ways listed, and a way is found when every
# needle in it is in one and the same file under Sources/ at the tag. The About
# row has two: spelled out, or — as every release so far writes it — the sidebar's
# `section.\(item)` over an enum of rows that has `case about` (`Section` in
# Sources/UDeckKit/Views/SettingsView.swift). A needle marked whole is matched
# as whole words, so that `case aboutTitle` is not `case about`.
CHECK_NOW_PATH: dict[str, tuple[tuple[tuple[str, bool], ...], ...]] = {
    "section.about": (
        (('accessibilityIdentifier("section.about")', False),),
        (('accessibilityIdentifier("section.\\(item)")', False), ("case about", True)),
    ),
    "updates.checkNow": ((('accessibilityIdentifier("updates.checkNow")', False),),),
    "updates.install": ((('accessibilityIdentifier("updates.install")', False),),),
}


class ReleaseError(Exception):
    """A release the lab could not find, fetch or vouch for — and why, in words."""

    def __init__(self, reason: str, build: str | None = None) -> None:
        super().__init__(reason)
        self.reason = reason
        # The CFBundleVersion the release's appcast offers for its zip, where that
        # much could be read before it failed — the appcast fetched whole, even when
        # the zip was not there — the number Sparkle compares, so what says whether
        # a pair with this release as "to" has an update in it at all
        # (`pairs.resolve`). None when no appcast of it was read: not there, not
        # XML, or no item for the zip that gives one.
        self.build = build


class ReleaseDefect(ReleaseError):
    """A release as GitHub publishes it that does not hold together — a finding about the release.

    Its zip, its appcast and the zip's own Info.plist disagree, the appcast of a
    release a check is offered sends uDeck elsewhere than the zip GitHub's API
    lists for it, or GitHub marks latest a release without one of its assets, or
    answers 404 or 410 for an asset its own API lists. Never a download cut short or a
    server that did not answer: those are the lab failing to look, and stay
    `ReleaseError`.
    """


@dataclass(frozen=True)
class Answer:
    """One answer from GitHub: its status, its headers (names in lower case), its body."""

    status: int
    headers: dict[str, str]
    body: bytes


Get = Callable[[str, dict[str, str]], Answer]


def get(url: str, headers: dict[str, str], seconds: float = config.GITHUB_SECONDS) -> Answer:
    """GET, following redirects, with a deadline.

    Proxies come from the environment only: urllib would otherwise ask macOS for
    the system's proxy settings, and the lab reads nothing of this Mac's
    configuration it does not need.
    """
    opener = urllib.request.build_opener(urllib.request.ProxyHandler(urllib.request.getproxies_environment()))
    try:
        request = urllib.request.Request(url, headers={"User-Agent": "udeck-e2e", **headers})
        with opener.open(request, timeout=seconds) as response:
            return Answer(response.status, _lower(response.headers), response.read())
    except urllib.error.HTTPError as error:
        try:
            body = error.read()
        except (OSError, http.client.HTTPException):
            body = b""
        return Answer(error.code, _lower(error.headers), body)
    except (urllib.error.URLError, OSError) as error:
        reason = getattr(error, "reason", None) or error
        raise ReleaseError(f"{url} did not answer this Mac: {reason}") from None
    except http.client.HTTPException as error:
        # A body cut short (`IncompleteRead`, a zip of six megabytes is long enough
        # for it) or an answer that is not HTTP: the transfer failed, and nothing
        # about the release is known from it.
        raise ReleaseError(f"{url} did not answer this Mac whole: {type(error).__name__}: {error}") from None
    except ValueError as error:
        # An address urllib cannot even ask — what an API answer with a broken
        # download URL leads to.
        raise ReleaseError(f"{url!r} is not an address this Mac can ask: {error}") from None


def _lower(headers: Any) -> dict[str, str]:
    return {str(name).lower(): str(value) for name, value in (headers.items() if headers else [])}


@dataclass(frozen=True)
class Published:
    """A release as GitHub lists it: its tag, where its two assets are, and what its API says they are.

    The sizes and the SHA-256 digests are what a copy on this Mac is held to
    (`Catalogue.fetch`); a digest the API does not give is None, and not compared.
    """

    tag: str
    appcast_url: str
    zip_name: str
    zip_url: str
    zip_size: int
    zip_digest: str | None = None
    appcast_size: int | None = None
    appcast_digest: str | None = None

    @property
    def version(self) -> str:
        return self.tag.removeprefix("v")

    @property
    def order(self) -> tuple[int, ...]:
        return tuple(int(part) for part in self.version.split("."))


@dataclass(frozen=True)
class Release:
    """A published release on this Mac, checked against its own appcast.

    `version` and `build` are the two keys Sparkle reads — the one people read and
    `CFBundleVersion`, the one it compares — and they are what an update check
    holds the bundle on the guest's disk to.
    """

    published: Published
    version: str
    build: str
    public_key: str
    shipped_feed: str
    zip: Path
    appcast: Path
    enclosure_url: str
    length: int
    signature: str
    sha256: str
    # Why the appcast's item sends uDeck somewhere else than the zip GitHub's API
    # lists for this release — or None when it sends it there. A defect only of a
    # release a check is offered (`Catalogue.fetch(offered=True)`): nothing reads
    # where the appcast of a release the lab only installs sends uDeck.
    elsewhere: str | None = None

    @property
    def tag(self) -> str:
        return self.published.tag

    @property
    def keys(self) -> tuple[str, str]:
        return self.version, self.build

    @property
    def own_appcast(self) -> str:
        """The appcast asset of this release itself, which is where a pair aiming at it by name points uDeck."""
        return self.published.appcast_url


class GitHub:
    """The two questions the lab asks GitHub's API: which releases are published, and which is latest."""

    def __init__(self, get: Get = get, repository: str = config.RELEASES_REPOSITORY, api: str = config.GITHUB_API) -> None:
        self._get = get
        self.repository = repository
        self.api = api.rstrip("/")

    def _ask(self, url: str) -> tuple[Any, dict[str, str]]:
        answer = self._get(url, {"Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28"})
        if answer.status in (403, 429) and answer.headers.get("x-ratelimit-remaining") == "0":
            raise ReleaseError(
                f"GitHub's API will not answer this address again until {_when(answer.headers.get('x-ratelimit-reset'))}: "
                "the sixty questions an hour it allows without a token are used up"
            )
        if answer.status != 200:
            said = answer.body.decode("utf-8", "replace").strip().replace("\n", " ")[:200]
            raise ReleaseError(f"GitHub's API answered {answer.status} for {url}: {said or 'nothing'}")
        try:
            return json.loads(answer.body), answer.headers
        except ValueError:
            raise ReleaseError(f"GitHub's API answered {url} with something that is not JSON") from None

    def latest_tag(self) -> str:
        found, _ = self._ask(f"{self.api}/repos/{self.repository}/releases/latest")
        tag = found.get("tag_name") if isinstance(found, dict) else None
        if not isinstance(tag, str) or not tag:
            raise ReleaseError("GitHub's API named no tag for the latest release")
        return tag

    def releases(self) -> tuple[list[Published], list["LeftOut"]]:
        """The published releases with both assets, oldest first — and what was left out, and why."""
        url: str | None = f"{self.api}/repos/{self.repository}/releases?per_page=100"
        listed: list[Any] = []
        for _ in range(_PAGES):
            if url is None:
                break
            page, headers = self._ask(url)
            if not isinstance(page, list):
                raise ReleaseError(f"GitHub's API answered {url} with something that is not a list of releases")
            listed.extend(page)
            url = _next_page(headers.get("link", ""))
        published: list[Published] = []
        left_out: list[LeftOut] = []
        for item in listed:
            try:
                found = _published(item)
            except (AttributeError, TypeError, ValueError) as error:
                # A shape the lab does not know is GitHub's API saying something
                # else than it did, not a release that is broken.
                tag = item.get("tag_name") if isinstance(item, dict) else None
                raise ReleaseError(f"GitHub's API listed {tag or 'a release'} in a shape the lab cannot read: {error}") from None
            if isinstance(found, LeftOut):
                left_out.append(found)
            else:
                published.append(found)
        return sorted(published, key=lambda p: p.order), left_out


@dataclass(frozen=True)
class LeftOut:
    """A release GitHub lists that the lab leaves out, and why — and whether the reason is an asset it lacks."""

    tag: str
    why: str
    lacks_an_asset: bool = False

    def __str__(self) -> str:
        return f"{self.tag}: {self.why}"


def _published(item: Any) -> "Published | LeftOut":
    tag = str(item.get("tag_name", "")) if isinstance(item, dict) else ""
    if not TAG.match(tag):
        return LeftOut(tag or "a release without a tag", "not a version tag")
    if item.get("draft") or item.get("prerelease"):
        return LeftOut(tag, "a draft" if item.get("draft") else "a pre-release")
    assets = {a.get("name"): a for a in item.get("assets") or [] if isinstance(a, dict)}
    zip_name = f"uDeck-{tag.removeprefix('v')}.zip"
    missing = [name for name in (config.RELEASE_APPCAST, zip_name) if name not in assets]
    if missing:
        return LeftOut(tag, f"no {' and no '.join(missing)} among its assets", lacks_an_asset=True)
    appcast, archive = assets[config.RELEASE_APPCAST], assets[zip_name]
    return Published(
        tag=tag,
        appcast_url=str(appcast.get("browser_download_url", "")),
        zip_name=zip_name,
        zip_url=str(archive.get("browser_download_url", "")),
        zip_size=int(archive.get("size", -1)),
        zip_digest=_digest(archive),
        appcast_size=int(appcast["size"]) if appcast.get("size") is not None else None,
        appcast_digest=_digest(appcast),
    )


def _digest(asset: dict[str, Any]) -> str | None:
    """The asset's SHA-256 as GitHub's API lists it (`"digest": "sha256:<hex>"`), or None when it gives none."""
    digest = asset.get("digest")
    if not isinstance(digest, str) or not digest.startswith("sha256:"):
        return None
    hexdigest = digest.removeprefix("sha256:").lower()
    if not re.fullmatch(r"[0-9a-f]{64}", hexdigest):
        raise ValueError(f"the digest {digest!r} is not a SHA-256")
    return hexdigest


def _next_page(link: str) -> str | None:
    for part in link.split(","):
        match = re.search(r'<([^>]+)>\s*;\s*rel="next"', part)
        if match:
            return match.group(1)
    return None


def _when(reset: str | None) -> str:
    try:
        return datetime.fromtimestamp(int(reset or ""), timezone.utc).strftime("%H:%M UTC")
    except ValueError:
        return "GitHub says when"


class Catalogue:
    """The releases one run talks about: asked of GitHub once, and each fetched and checked at most once."""

    def __init__(self, github: GitHub, repo_root: Path, note: Note, get: Get = get) -> None:
        self.github = github
        self.repo_root = repo_root
        self.cache = repo_root / config.RELEASES_CACHE
        self.note = note
        self._get = get
        self._published: list[Published] | None = None
        self._left_out: list[LeftOut] = []
        self._latest_tag: str | None = None
        self._latest: Published | None = None
        self._fetched: dict[str, Release] = {}
        # What could not be fetched or vouched for, so that a second check with
        # the same release is told the same thing without GitHub being asked again.
        self._failed: dict[str, ReleaseError] = {}

    def published(self) -> list[Published]:
        if self._published is None:
            self._published, self._left_out = self.github.releases()
            if not self._published:
                raise ReleaseError(f"GitHub lists no published release of {self.github.repository} with both its assets")
        return self._published

    def latest_tag(self) -> str:
        if self._latest_tag is None:
            self._latest_tag = self.github.latest_tag()
        return self._latest_tag

    def latest(self) -> Published:
        """The release GitHub marks latest — and, when that release lacks an asset, a defect of it.

        The feed every release ships with is GitHub's redirect to the latest
        release's own appcast, so a latest without its appcast or its zip is what
        every uDeck that looks is sent to.
        """
        if self._latest is None:
            tag = self.latest_tag()
            found = [p for p in self.published() if p.tag == tag]
            if not found:
                lacking = next((entry for entry in self._left_out if entry.tag == tag and entry.lacks_an_asset), None)
                if lacking is not None:
                    raise ReleaseDefect(
                        f"GitHub marks {tag} latest, and it has {lacking.why}: the feed every release ships with "
                        f"leads every uDeck that looks to an asset that is not there"
                    )
                raise ReleaseError(
                    f"GitHub marks {tag} latest, and it is not among the releases with both assets: "
                    f"{self.what_exists()}"
                )
            self._latest = found[0]
        return self._latest

    def before_latest(self) -> Published:
        """The published release just below the one GitHub marks latest — by the mark alone.

        Only the latest tag's version is needed, not its assets: a latest that
        lacks one is "to"'s defect, and must not take "from" down with it.
        """
        tag = self.latest_tag()
        match = TAG.match(tag)
        if match is None:
            raise ReleaseError(f"GitHub marks {tag} latest, which is not a version the lab can order releases by")
        order = tuple(int(part) for part in match.groups())
        older = [p for p in self.published() if p.order < order]
        if not older:
            raise ReleaseError(f"there is no published release before latest {tag.removeprefix('v')}: {self.what_exists()}")
        return older[-1]

    def named(self, version: str) -> Published:
        found = [p for p in self.published() if p.version == version]
        if found:
            return found[0]
        tag = f"v{version}"
        why = f"no published release {version}"
        # What GitHub says about the tag comes first: a draft, a pre-release or a
        # release without its assets is a tag too, and "a tag nobody made a
        # release of" would be wrong about it.
        listed = next((entry for entry in self._left_out if entry.tag == tag), None)
        if listed is not None:
            why += f" — {listed}"
        elif _tag_exists(self.repo_root, tag):
            why += f" — {tag} is a tag nobody made a release of"
        raise ReleaseError(f"{why}; {self.what_exists()}")

    def what_exists(self) -> str:
        published = self._published or []
        latest = self._latest.tag if self._latest else self._latest_tag
        names = [p.version + (" (latest)" if p.tag == latest else "") for p in published]
        return "the published releases are " + (", ".join(names) or "none")

    def fetch(self, published: Published, offered: bool = False) -> Release:
        """The release's two assets on this Mac, checked against each other — from the cache when they still check.

        Raises `ReleaseDefect` when the copy GitHub serves, fetched afresh, does
        not hold together, and `ReleaseError` when it could not be fetched; either
        is remembered for the rest of the run. `offered` is for the release a check
        is offered — "to" — and holds its appcast to one rule more: its item has to
        send uDeck to the zip GitHub's API lists for it (`Release.elsewhere`), or
        that is its defect. A release that is only installed is never asked it.
        """
        release = self._release(published)
        if offered and release.elsewhere is not None:
            raise ReleaseDefect(release.elsewhere, release.build)
        return release

    def _release(self, published: Published) -> Release:
        if published.tag in self._fetched:
            return self._fetched[published.tag]
        if published.tag in self._failed:
            failed = self._failed[published.tag]
            raise type(failed)(failed.reason, failed.build)
        try:
            release = self._fetch(published)
        except ReleaseError as error:
            self._failed[published.tag] = error
            raise
        self._fetched[published.tag] = release
        return release

    def _fetch(self, published: Published) -> Release:
        directory = self.cache / published.tag
        appcast, archive = directory / config.RELEASE_APPCAST, directory / published.zip_name
        try:
            # What GitHub lists now first: a copy that still checks against its
            # own appcast may be of an asset that has since been published again.
            _as_listed(published, appcast, archive)
            release = verify(published, appcast, archive)
            if release.elsewhere is not None:
                # Said of GitHub's own copy, never of one kept from before.
                raise ReleaseError(release.elsewhere)
            self.note(
                f"   {published.tag}: the copy in {self._shown(directory)} is what GitHub's API lists, and still "
                "checks against its appcast"
            )
        except ReleaseError as stale:
            if appcast.exists() or archive.exists():
                self.note(f"   {published.tag}: the copy in {self._shown(directory)} does not check ({stale.reason}); fetching it again")
            self._download(published.appcast_url, appcast, published.appcast_size, published.appcast_digest)
            try:
                self._download(published.zip_url, archive, published.zip_size, published.zip_digest)
            except ReleaseDefect as missing:
                # The appcast is on this Mac, fetched whole: what it offers for the
                # zip is known, though the zip is not there.
                raise ReleaseDefect(missing.reason, _offered_build(appcast, published.zip_name)) from None
            kept = f"(GitHub's copies are kept in {self._shown(directory)}/)"
            try:
                release = verify(published, appcast, archive)
            except ReleaseDefect as defect:
                # Fetched afresh and whole, so this is what GitHub serves — kept
                # where a person can look at it.
                raise ReleaseDefect(f"{defect.reason} {kept}", defect.build) from None
            self.note(
                f"   {published.tag}: fetched {published.zip_name} ({release.length:,} bytes) and its appcast from GitHub; "
                f"the signature holds under the key in its own Info.plist"
            )
            if release.elsewhere is not None:
                release = replace(release, elsewhere=f"{release.elsewhere} {kept}")
                self.note(
                    f"   {published.tag}: its appcast sends uDeck to {release.enclosure_url}, not to the zip GitHub's API "
                    "lists — the defect of a release a check is offered, and nothing a check reads of one it installs"
                )
        return release

    def _download(self, url: str, path: Path, size: int | None, digest: str | None) -> None:
        answer = self._get(url, {})
        if answer.status in ASSET_MISSING:
            raise ReleaseDefect(
                f"GitHub answered {answer.status} for {url}, an asset its own API lists: every uDeck that asks "
                "for it meets the same"
            )
        if answer.status != 200:
            raise ReleaseError(f"GitHub answered {answer.status} for {url}")
        if size is not None and len(answer.body) != size:
            raise ReleaseError(f"GitHub served {len(answer.body):,} bytes for {url}, where its API says {size:,}")
        if digest is not None and hashlib.sha256(answer.body).hexdigest() != digest:
            raise ReleaseError(
                f"GitHub served {url} with another SHA-256 than the digest its API lists ({digest[:12]}…): not "
                "the asset it lists, or not whole"
            )
        try:
            path.parent.mkdir(parents=True, exist_ok=True)
            partial = path.with_name(path.name + ".part")
            with open(os.open(partial, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o644), "wb") as file:
                file.write(answer.body)
            os.replace(partial, path)
        except OSError as error:
            raise ReleaseError(f"could not keep {path.name} in {self._shown(path.parent)}: {error}") from None

    def _shown(self, path: Path) -> str:
        try:
            return str(path.relative_to(self.repo_root))
        except ValueError:
            return str(path)


def verify(published: Published, appcast_path: Path, zip_path: Path) -> Release:
    """The release, if its zip checks against its appcast — or why it does not.

    The appcast's item for this zip gives the length, the two version keys, the
    signature and where uDeck downloads it from; the zip's own Info.plist gives
    the key the signature must hold under, and must say the same versions. All in
    memory: nothing is unpacked. Where the item sends uDeck is not a defect here
    but `Release.elsewhere`, said when it is not the zip GitHub's API lists for
    this release, `browser_download_url` (`same_address`): a defect only of a
    release a check is offered (`Catalogue.fetch`).
    """
    try:
        appcast_text = appcast_path.read_bytes()
        data = zip_path.read_bytes()
    except OSError as error:
        raise ReleaseError(f"{published.tag} is not on this Mac yet ({error.strerror or error})") from None
    item = appcast_item(appcast_text, published.zip_name)

    def defect(reason: str) -> ReleaseDefect:
        return ReleaseDefect(reason, item["build"])

    elsewhere = None
    if not same_address(item["url"], published.zip_url):
        # Where Sparkle downloads the update from is the enclosure's URL and
        # nothing else: an item that names the zip but points at another host,
        # another tag, plain http, or the release's own address tucked into
        # another's query is a release whose every offer is fetched from there —
        # never the asset the lab vouched for, and, for a host that does not
        # answer, a failure the guest would read as the network's.
        elsewhere = (
            f"the appcast's item for {published.zip_name} sends uDeck to {item['url']}, not to the asset GitHub's "
            f"API lists for {published.tag} ({published.zip_url}): every uDeck offered it downloads from there"
        )
    if len(data) != item["length"]:
        raise defect(f"{published.zip_name} is {len(data):,} bytes and its appcast says {item['length']:,}")
    try:
        with zipfile.ZipFile(zip_path) as archive:
            plist = plistlib.loads(archive.read(INFO_PLIST))
    except OSError as error:
        raise ReleaseError(f"{published.zip_name} could not be read on this Mac: {error}") from None
    except (KeyError, ValueError, plistlib.InvalidFileException, ExpatError, zipfile.BadZipFile, zlib.error, EOFError,
            NotImplementedError) as error:
        # What the zip as GitHub serves it is made of: no Info.plist, one that is
        # not a plist (malformed XML is expat's error, not a ValueError), an entry
        # that will not inflate. Every uDeck would be offered exactly that.
        raise defect(f"{published.zip_name} has no readable {INFO_PLIST}: {type(error).__name__}: {error}") from None
    if not isinstance(plist, dict):
        raise defect(f"{published.zip_name}'s {INFO_PLIST} is a {type(plist).__name__}, not a dictionary")
    wanted = {
        "CFBundleIdentifier": BUNDLE_ID,
        "CFBundleShortVersionString": published.version,
        "CFBundleVersion": item["build"],
    }
    wrong = [f"{key} is {plist.get(key)!r}, not {value!r}" for key, value in wanted.items() if plist.get(key) != value]
    if item["version"] != published.version:
        wrong.append(f"its appcast offers {item['version']!r} under the tag {published.tag}")
    if wrong:
        raise defect(f"{published.zip_name} is not the release its tag and appcast name: " + "; ".join(wrong))
    key_text = plist.get("SUPublicEDKey")
    try:
        key = base64.b64decode(str(key_text), validate=True)
        signature = base64.b64decode(item["signature"], validate=True)
    except (binascii.Error, ValueError):
        raise defect(f"{published.zip_name}'s SUPublicEDKey {key_text!r} or its appcast's signature is not base64") from None
    if not ed25519.verify(key, data, signature):
        raise defect(
            f"the appcast's edSignature does not hold over {published.zip_name} under the SUPublicEDKey "
            f"its own Info.plist carries ({key_text})"
        )
    return Release(
        published=published,
        version=published.version,
        build=item["build"],
        public_key=str(key_text),
        shipped_feed=str(plist.get("SUFeedURL", "")),
        zip=zip_path,
        appcast=appcast_path,
        enclosure_url=item["url"],
        length=item["length"],
        signature=item["signature"],
        sha256=hashlib.sha256(data).hexdigest(),
        elsewhere=elsewhere,
    )


# An absolute address as an appcast writes it: scheme, authority, and the rest.
# Nothing is stripped first — an address with a space before it is not this one.
_ADDRESS = re.compile(r"([A-Za-z][A-Za-z0-9+.-]*)://([^/?#]*)(.*)", re.DOTALL)

# The port an address names by leaving it out.
_DEFAULT_PORT = {"https": "443", "http": "80"}


def same_address(written: str, listed: str) -> bool:
    """Whether an appcast's enclosure `written` is the address `listed` — as Sparkle reads an address.

    Sparkle 2.9.6 (`SUAppcastItem.m`) takes the enclosure as an `NSURL`, resolved
    against the feed it was read from, and accepts its scheme as http or https in
    any case. An address's scheme and host are not case-sensitive, and a scheme's
    own port means the same written or left out (RFC 3986, 6.2.2.1 and 6.2.3), so
    those three are compared that way — and nothing else is: a user part, the
    path, the query and anything after them must be exactly as GitHub's API lists
    them. An address that is not absolute is never `listed`: a relative enclosure
    would be resolved against whichever feed it was read from, through the latest
    redirect or not, and one with a space before it Sparkle reads as `%20…`.
    """
    return _as_sparkle_reads(written) == _as_sparkle_reads(listed)


def _as_sparkle_reads(url: str) -> str:
    match = _ADDRESS.fullmatch(url)
    if match is None:
        return url
    scheme, authority, rest = match.groups()
    scheme = scheme.lower()
    if "@" in authority or "[" in authority:
        # A user part, or an IPv6 host: kept as written, case and all.
        return f"{scheme}://{authority}{rest}"
    host, colon, port = authority.partition(":")
    if colon and port == _DEFAULT_PORT.get(scheme):
        colon = port = ""
    return f"{scheme}://{host.lower()}{colon}{port}{rest}"


def _offered_build(appcast_path: Path, zip_name: str) -> str | None:
    """The CFBundleVersion the appcast on this Mac offers for `zip_name` — or None when it cannot say."""
    try:
        return str(appcast_item(appcast_path.read_bytes(), zip_name)["build"])
    except (OSError, ReleaseError):
        return None


def _as_listed(published: Published, appcast_path: Path, zip_path: Path) -> None:
    """Nothing, if both copies on this Mac are the size — and, where the API gives one, the SHA-256 — GitHub lists now."""
    for path, size, digest in (
        (appcast_path, published.appcast_size, published.appcast_digest),
        (zip_path, published.zip_size, published.zip_digest),
    ):
        try:
            here = path.stat().st_size
            if size is not None and here != size:
                raise ReleaseError(f"{path.name} is {here:,} bytes here, and GitHub's API lists {size:,} now")
            if digest is not None and hashlib.sha256(path.read_bytes()).hexdigest() != digest:
                raise ReleaseError(f"{path.name} here is not the SHA-256 GitHub's API lists now ({digest[:12]}…)")
        except OSError as error:
            raise ReleaseError(f"{published.tag} is not on this Mac yet ({error.strerror or error})") from None


def appcast_item(text: bytes | str, zip_name: str) -> dict[str, Any]:
    """The appcast's item whose enclosure is `zip_name`: its url, length, signature and both version keys."""
    try:
        root = ElementTree.fromstring(text)
    except ElementTree.ParseError as error:
        raise ReleaseDefect(f"the appcast is not XML: {error}") from None
    for item in root.iter("item"):
        enclosure = item.find("enclosure")
        if enclosure is None:
            continue
        url = enclosure.get("url", "")
        if url.rsplit("/", 1)[-1] != zip_name:
            continue
        build = _child_or_attribute(item, enclosure, "version")
        version = _child_or_attribute(item, enclosure, "shortVersionString")
        signature = enclosure.get(f"{_SPARKLE}edSignature", "")
        length = enclosure.get("length", "")
        if not (build and version and signature and length.isdigit()):
            raise ReleaseDefect(f"the appcast's item for {zip_name} lacks a version, a length or an edSignature")
        return {"url": url, "build": build, "version": version, "signature": signature, "length": int(length)}
    raise ReleaseDefect(f"the appcast has no item whose enclosure is {zip_name}")


def _child_or_attribute(item: ElementTree.Element, enclosure: ElementTree.Element, name: str) -> str:
    child = item.find(f"{_SPARKLE}{name}")
    if child is not None and (child.text or "").strip():
        return (child.text or "").strip()
    return enclosure.get(f"{_SPARKLE}{name}", "").strip()


def _tag_exists(repo_root: Path, tag: str, run: Callable[..., subprocess.CompletedProcess[str]] = subprocess.run) -> bool:
    done = _git(repo_root, ["rev-parse", "--verify", "--quiet", f"refs/tags/{tag}^{{commit}}"], run)
    return done is not None and done.returncode == 0


def _git(repo_root: Path, args: list[str], run: Callable[..., subprocess.CompletedProcess[str]]) -> subprocess.CompletedProcess[str] | None:
    try:
        return run(
            ["git", "--no-optional-locks", "-C", str(repo_root), *args],
            capture_output=True, text=True, errors="replace", timeout=30, check=False, stdin=subprocess.DEVNULL,
        )  # fmt: skip
    except (OSError, subprocess.TimeoutExpired):
        return None


def _files_naming(repo_root: Path, tag: str, needle: tuple[str, bool],
                  run: Callable[..., subprocess.CompletedProcess[str]]) -> set[str] | str:
    """The files under Sources/ at `tag` that contain the needle — or what git said instead."""
    text, whole = needle
    done = _git(repo_root, ["grep", "-l", "-F", *(["-w"] if whole else []), "-e", text, tag, "--", "Sources"], run)
    if done is None or done.returncode not in (0, 1):
        return (done.stderr.strip().splitlines() or ["no answer"])[-1] if done is not None else "git did not answer"
    return set(done.stdout.split("\n")) - {""} if done.returncode == 0 else set()


def check_now_problem(repo_root: Path, published: Published,
                      run: Callable[..., subprocess.CompletedProcess[str]] = subprocess.run) -> str | None:
    """Why the lab cannot drive this release to "Check now" and Install — or None when it can.

    Read from the release's own source, at its tag in this checkout: the
    identifiers the lab presses by (`CHECK_NOW_PATH`). A tag this checkout does
    not have is a reason too, and says how to get it.
    """
    if not _tag_exists(repo_root, published.tag, run):
        return (
            f"{published.tag} is not a tag in this checkout, and the lab reads from a release's own source whether "
            f"it can press its way to an update; 'git fetch --tags' brings it"
        )
    missing = []
    files: dict[tuple[str, bool], set[str]] = {}
    for identifier, ways in CHECK_NOW_PATH.items():
        found = False
        for way in ways:
            together: set[str] | None = None
            for needle in way:
                if needle not in files:
                    named = _files_naming(repo_root, published.tag, needle, run)
                    if isinstance(named, str):
                        return f"the lab could not read {published.tag}'s source: {named}"
                    files[needle] = named
                together = files[needle] if together is None else together & files[needle]
            if together:
                found = True
                break
        if not found:
            missing.append(identifier)
    if not missing:
        return None
    return (
        f"{published.version}'s own source at {published.tag} gives its settings window no "
        f"{', no '.join(missing)}, and once that window is open the lab presses its way to an update by those "
        f"identifiers, never by translated titles; a release can be \"from\" only when its source names all "
        f"{len(CHECK_NOW_PATH)}"
    )
