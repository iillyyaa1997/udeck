"""Published releases: what GitHub says exists, and what the lab will vouch for before a guest sees it.

GitHub is answers written here — its API as it answered on 2026-10-09, and
release zips made in the test and signed with a key made in the test — so
nothing here reaches the network. What is tested is the part a person cannot
see go wrong: which release "latest" and "the one before" turn out to be, what
is left out of the list and why, and every way a zip can fail to be the release
its appcast describes.
"""

import http.client
import io
import json
import plistlib
import subprocess
import urllib.request
import zipfile
from types import SimpleNamespace

import pytest
from fakes import API, DOWNLOAD, GitHubAsOn20261009, Key, Web, a_release, a_zip, an_appcast

from udeck_e2e import config, releases, updates
from udeck_e2e.releases import Catalogue, GitHub, Published, ReleaseDefect, ReleaseError


@pytest.fixture
def github():
    return GitHubAsOn20261009()


def catalogue(github, tmp_path, notes=None):
    return Catalogue(GitHub(get=github.web), tmp_path / "repo", (notes if notes is not None else []).append, get=github.web)


# --- What GitHub says exists ------------------------------------------------------------


def test_latest_is_githubs_own_mark_and_the_one_before_is_the_next_lower_version(github, tmp_path):
    found = catalogue(github, tmp_path)
    assert found.latest().version == "0.6.1"
    assert found.before_latest().version == "0.5.0"
    assert [p.version for p in found.published()] == ["0.1.0", "0.2.1", "0.3.0", "0.4.0", "0.5.0", "0.6.1"]


def test_latest_is_the_mark_and_not_the_highest_number(tmp_path):
    """A maintainer can mark an older release latest — GitHub's mark is what the real feed follows."""
    github = GitHubAsOn20261009(latest="0.5.0")
    found = catalogue(github, tmp_path)
    assert found.latest().version == "0.5.0"
    assert found.before_latest().version == "0.4.0"


def test_drafts_pre_releases_and_releases_without_both_assets_are_left_out_and_said(tmp_path):
    web = Web()
    web.json(f"{API}?per_page=100", [
        a_release("0.7.0", prerelease=True), a_release("0.6.9", draft=True),
        a_release("0.6.5", assets=("appcast.xml",)), a_release("0.6.4", assets=("zip",)),
        {"tag_name": "nightly", "assets": []}, a_release("0.6.1"),
    ])  # fmt: skip
    published, left_out = GitHub(get=web).releases()
    assert [p.version for p in published] == ["0.6.1"]
    assert [str(entry) for entry in left_out] == [
        "v0.7.0: a pre-release", "v0.6.9: a draft", "v0.6.5: no uDeck-0.6.5.zip among its assets",
        "v0.6.4: no appcast.xml among its assets", "nightly: not a version tag",
    ]  # fmt: skip
    assert [entry.tag for entry in left_out if entry.lacks_an_asset] == ["v0.6.5", "v0.6.4"]


def test_a_list_in_a_shape_the_lab_cannot_read_is_githubs_and_not_a_crash(tmp_path):
    """A field of another type is GitHub's API saying something else — never an exception that ends the run."""
    web = Web()
    broken = a_release("0.6.1")
    broken["assets"][1]["size"] = "six megabytes"
    web.json(f"{API}?per_page=100", [broken])
    with pytest.raises(ReleaseError, match="listed v0.6.1 in a shape the lab cannot read"):
        GitHub(get=web).releases()
    web.json(f"{API}?per_page=100", [{"tag_name": "v0.6.1", "assets": 7}])
    with pytest.raises(ReleaseError, match="in a shape the lab cannot read"):
        GitHub(get=web).releases()


def test_every_page_of_the_list_is_read(tmp_path):
    web = Web()
    web.json(f"{API}?per_page=100", [a_release("0.6.1")], headers={"link": f'<{API}?per_page=100&page=2>; rel="next"'})
    web.json(f"{API}?per_page=100&page=2", [a_release("0.5.0")])
    published, _ = GitHub(get=web).releases()
    assert [p.version for p in published] == ["0.5.0", "0.6.1"]


def test_a_used_up_rate_limit_says_until_when(tmp_path):
    web = Web()
    web.json(f"{API}/latest", {"message": "API rate limit exceeded"}, status=403,
             headers={"x-ratelimit-remaining": "0", "x-ratelimit-reset": "1791519000"})
    with pytest.raises(ReleaseError, match="will not answer this address again until 04:10 UTC"):
        GitHub(get=web).latest_tag()


def test_an_api_that_answers_something_else_says_what(tmp_path):
    web = Web()
    web.json(f"{API}/latest", {"message": "Not Found"}, status=404)
    with pytest.raises(ReleaseError, match="answered 404 for .*Not Found"):
        GitHub(get=web).latest_tag()
    web.file(f"{API}/latest", b"<html>a portal</html>")
    with pytest.raises(ReleaseError, match="not JSON"):
        GitHub(get=web).latest_tag()


def test_a_mac_without_the_network_says_so(tmp_path):
    nowhere = Web()
    with pytest.raises(ReleaseError, match="did not answer this Mac"):
        Catalogue(GitHub(get=nowhere), tmp_path, lambda text: None, get=nowhere).latest()


def test_the_real_get_turns_a_refused_connection_into_a_sentence():
    """Port 9 on this Mac's own loopback: refused at once, and nothing leaves the machine."""
    with pytest.raises(ReleaseError, match="http://127.0.0.1:9/ did not answer this Mac"):
        releases.get("http://127.0.0.1:9/", {}, seconds=5)


class _CutShort:
    """An answer whose body ends early, as a six-megabyte zip's can: `read` raises what http.client raises."""

    status = 200
    headers = {}

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False

    def read(self):
        raise http.client.IncompleteRead(b"x" * 10, 6026082)


def test_the_real_get_turns_a_body_cut_short_into_a_sentence_and_not_an_exception_that_ends_the_run(monkeypatch):
    """`IncompleteRead` is not an OSError: before, it escaped the lab's resolution as an INTERNALERROR."""
    opener = SimpleNamespace(open=lambda request, timeout: _CutShort())
    monkeypatch.setattr(urllib.request, "build_opener", lambda *handlers: opener)
    with pytest.raises(ReleaseError, match="did not answer this Mac whole: IncompleteRead"):
        releases.get("https://github.com/x/uDeck-0.6.1.zip", {})

    def bad_status(request, timeout):
        raise http.client.BadStatusLine("SSH-2.0-OpenSSH")

    monkeypatch.setattr(urllib.request, "build_opener", lambda *handlers: SimpleNamespace(open=bad_status))
    with pytest.raises(ReleaseError, match="BadStatusLine"):
        releases.get("https://github.com/x/appcast.xml", {})


def test_an_address_urllib_cannot_ask_is_a_sentence_too():
    with pytest.raises(ReleaseError, match="is not an address this Mac can ask"):
        releases.get("", {})


def test_a_release_nobody_published_names_what_exists_and_a_tag_without_a_release(github, tmp_path):
    repo = tmp_path / "repo"
    repo.mkdir()
    git = ["git", "-C", str(repo), "-c", "user.email=lab@example.com", "-c", "user.name=lab", "-c", "commit.gpgsign=false"]
    subprocess.run([*git, "init", "-q"], check=True)
    subprocess.run([*git, "commit", "-q", "--allow-empty", "-m", "c"], check=True)
    subprocess.run([*git, "tag", "v0.6.0"], check=True)
    found = catalogue(github, tmp_path)
    with pytest.raises(ReleaseError) as raised:
        found.named("0.6.0")
    assert "v0.6.0 is a tag nobody made a release of" in raised.value.reason
    assert "the published releases are 0.1.0, 0.2.1, 0.3.0, 0.4.0, 0.5.0, 0.6.1" in raised.value.reason
    with pytest.raises(ReleaseError, match="no published release 9.9.9; the published releases are"):
        found.named("9.9.9")


def test_a_tag_github_lists_as_a_draft_is_said_as_that_and_not_as_a_tag_without_a_release(tmp_path):
    """The tag exists in the checkout too, but what GitHub says about it is the more exact sentence."""
    repo = tmp_path / "repo"
    repo.mkdir()
    git = ["git", "-C", str(repo), "-c", "user.email=lab@example.com", "-c", "user.name=lab", "-c", "commit.gpgsign=false"]
    subprocess.run([*git, "init", "-q"], check=True)
    subprocess.run([*git, "commit", "-q", "--allow-empty", "-m", "c"], check=True)
    subprocess.run([*git, "tag", "v0.6.2"], check=True)
    web = Web()
    web.json(f"{API}?per_page=100", [a_release("0.6.2", draft=True), a_release("0.6.1")])
    with pytest.raises(ReleaseError) as raised:
        Catalogue(GitHub(get=web), repo, lambda text: None, get=web).named("0.6.2")
    assert "no published release 0.6.2 — v0.6.2: a draft" in raised.value.reason
    assert "nobody made a release of" not in raised.value.reason


def test_latest_without_its_assets_is_a_defect_of_latest_and_not_taken_for_another(tmp_path):
    """The real feed leads every uDeck to latest's own appcast: a latest without one is the release's fault."""
    web = Web()
    web.json(f"{API}?per_page=100", [a_release("0.7.0", assets=("zip",)), a_release("0.6.1")])
    web.json(f"{API}/latest", {"tag_name": "v0.7.0"})
    found = Catalogue(GitHub(get=web), tmp_path, lambda text: None, get=web)
    with pytest.raises(ReleaseDefect, match="marks v0.7.0 latest, and it has no appcast.xml among its assets"):
        found.latest()
    assert found.before_latest().version == "0.6.1", "the release before latest needs only latest's version"


def test_latest_left_out_for_another_reason_is_the_labs_not_to_vouch_for(tmp_path):
    web = Web()
    web.json(f"{API}?per_page=100", [a_release("0.6.1")])
    web.json(f"{API}/latest", {"tag_name": "nightly"})
    found = Catalogue(GitHub(get=web), tmp_path, lambda text: None, get=web)
    with pytest.raises(ReleaseError) as raised:
        found.latest()
    assert not isinstance(raised.value, ReleaseDefect)
    with pytest.raises(ReleaseError, match="not a version the lab can order releases by"):
        found.before_latest()


def test_nothing_before_the_first_release(tmp_path):
    github = GitHubAsOn20261009(latest="0.1.0")
    with pytest.raises(ReleaseError, match="no published release before latest 0.1.0"):
        catalogue(github, tmp_path).before_latest()


def test_github_is_asked_twice_a_run_whatever_is_resolved(github, tmp_path):
    found = catalogue(github, tmp_path)
    found.latest(), found.before_latest(), found.named("0.4.0"), found.latest()
    assert sorted(url for url in github.web.asked if url.startswith(config.GITHUB_API)) == [f"{API}/latest", f"{API}?per_page=100"]


# --- What the lab vouches for -------------------------------------------------------------


def test_a_fetched_release_is_kept_under_build_e2e_and_checked_against_its_own_appcast(github, tmp_path):
    notes = []
    found = catalogue(github, tmp_path, notes)
    release = found.fetch(found.latest())
    assert release.zip == tmp_path / "repo" / ".build" / "e2e" / "releases" / "v0.6.1" / "uDeck-0.6.1.zip"
    assert release.zip.read_bytes() == github.zips["0.6.1"]
    assert (release.version, release.build) == ("0.6.1", "8")
    assert release.public_key == github.key.public
    assert release.shipped_feed == config.LATEST_FEED
    assert release.own_appcast == f"{DOWNLOAD}/v0.6.1/appcast.xml"
    assert "dist" not in release.zip.parts
    assert any("the signature holds under the key in its own Info.plist" in note for note in notes)


def test_a_copy_that_still_checks_is_not_fetched_again_and_one_that_does_not_is(github, tmp_path):
    first = catalogue(github, tmp_path)
    release = first.fetch(first.latest())
    github.web.asked.clear()
    notes = []
    second = catalogue(github, tmp_path, notes)
    second.fetch(second.latest())
    assert not [url for url in github.web.asked if url.startswith(DOWNLOAD)]
    assert any("still checks" in note for note in notes)

    damaged = bytearray(release.zip.read_bytes())
    damaged[len(damaged) // 2] ^= 0x01
    release.zip.write_bytes(bytes(damaged))
    notes.clear()
    third = catalogue(github, tmp_path, notes)
    again = third.fetch(third.latest())
    assert again.zip.read_bytes() == github.zips["0.6.1"]
    assert any("does not check" in note and "fetching it again" in note for note in notes)


def put(github, version, data, appcast):
    """GitHub serving these two assets for `version`, its API listing their sizes and digests."""
    github.publish(version, data, appcast)


def refused(github, tmp_path, version="0.6.1", defect=True, offered=True):
    """Why `version`, fetched as the release a check is offered unless said otherwise, is not vouched for."""
    found = catalogue(github, tmp_path)
    with pytest.raises(ReleaseError) as raised:
        found.fetch(found.named(version), offered=offered)
    assert isinstance(raised.value, ReleaseDefect) is defect, (
        "what GitHub serves broken is the release's defect; what it does not serve whole is the lab's"
    )
    return raised.value.reason


def test_a_zip_signed_by_another_key_than_the_one_it_carries_is_refused(github, tmp_path):
    data = a_zip("0.6.1", "8", github.key)
    put(github, "0.6.1", data, an_appcast("0.6.1", "8", data, Key().sign(data)))
    said = refused(github, tmp_path)
    assert "does not hold over uDeck-0.6.1.zip under the SUPublicEDKey its own Info.plist carries" in said
    assert "GitHub's copies are kept in .build/e2e/releases/v0.6.1/" in said


def test_a_defect_is_remembered_and_github_is_not_asked_again_in_the_same_run(github, tmp_path):
    data = a_zip("0.6.1", "8", github.key)
    put(github, "0.6.1", data, an_appcast("0.6.1", "8", data, Key().sign(data)))
    found = catalogue(github, tmp_path)
    with pytest.raises(ReleaseDefect) as first:
        found.fetch(found.latest())
    github.web.asked.clear()
    with pytest.raises(ReleaseDefect, match="does not hold") as again:
        found.fetch(found.latest())
    assert github.web.asked == []
    assert first.value.build == again.value.build == "8", "the build its appcast offers is remembered with it"


def test_a_defect_says_the_build_its_appcast_offers_where_that_much_was_read(github, tmp_path):
    """What a pair with this release as "to" is asked whether it is newer by (`pairs.resolve`)."""
    data = a_zip("0.6.1", "7", github.key)
    put(github, "0.6.1", data, an_appcast("0.6.1", "8", data, github.key.sign(data)))
    found = catalogue(github, tmp_path)
    with pytest.raises(ReleaseDefect) as raised:
        found.fetch(found.named("0.6.1"))
    assert raised.value.build == "8", "the appcast's number, which Sparkle compares — not the zip's"

    github = GitHubAsOn20261009()
    github.web.file(f"{DOWNLOAD}/v0.6.1/uDeck-0.6.1.zip", b"", status=404)
    found = catalogue(github, tmp_path / "missing")
    with pytest.raises(ReleaseDefect, match="GitHub answered 404") as raised:
        found.fetch(found.named("0.6.1"))
    assert raised.value.build == "8", "the appcast is on this Mac, fetched whole, though the zip is not there"
    with pytest.raises(ReleaseDefect) as again:
        found.fetch(found.named("0.6.1"))
    assert again.value.build == "8", "and remembered with it"

    github = GitHubAsOn20261009()
    github.web.file(f"{DOWNLOAD}/v0.6.1/appcast.xml", b"", status=404)
    found = catalogue(github, tmp_path / "no-appcast")
    with pytest.raises(ReleaseDefect, match="GitHub answered 404") as raised:
        found.fetch(found.named("0.6.1"))
    assert raised.value.build is None, "no appcast, no number"

    github = GitHubAsOn20261009()
    github.publish("0.6.1", appcast=b"<rss><channel></channel></rss>")
    github.web.file(f"{DOWNLOAD}/v0.6.1/uDeck-0.6.1.zip", b"", status=410)
    found = catalogue(github, tmp_path / "no-item")
    with pytest.raises(ReleaseDefect, match="GitHub answered 410") as raised:
        found.fetch(found.named("0.6.1"))
    assert raised.value.build is None, "an appcast with no item for the zip says no number"


def test_a_zip_of_another_length_than_its_appcast_says_is_refused(github, tmp_path):
    data = a_zip("0.6.1", "8", github.key)
    put(github, "0.6.1", data, an_appcast("0.6.1", "8", data, github.key.sign(data), length=len(data) + 1))
    assert f"is {len(data):,} bytes and its appcast says {len(data) + 1:,}" in refused(github, tmp_path)


def test_a_zip_whose_bundle_says_another_version_is_refused(github, tmp_path):
    data = a_zip("0.6.1", "8", github.key, plist_version="0.6.0")
    put(github, "0.6.1", data, an_appcast("0.6.1", "8", data, github.key.sign(data)))
    assert "CFBundleShortVersionString is '0.6.0', not '0.6.1'" in refused(github, tmp_path)


def test_a_zip_whose_build_number_is_not_the_appcasts_is_refused(github, tmp_path):
    data = a_zip("0.6.1", "7", github.key)
    put(github, "0.6.1", data, an_appcast("0.6.1", "8", data, github.key.sign(data)))
    assert "CFBundleVersion is '7', not '8'" in refused(github, tmp_path)


def test_a_zip_that_is_not_udeck_is_refused(github, tmp_path):
    data = a_zip("0.6.1", "8", github.key, identifier="place.unicorns.udeck.debug")
    put(github, "0.6.1", data, an_appcast("0.6.1", "8", data, github.key.sign(data)))
    assert "CFBundleIdentifier is 'place.unicorns.udeck.debug'" in refused(github, tmp_path)


OWN_ZIP = f"{DOWNLOAD}/v0.6.1/uDeck-0.6.1.zip"


def test_an_appcast_that_sends_udeck_to_the_releases_own_zip_is_vouched_for(github, tmp_path):
    """The real releases' appcasts, as on 2026-10-09: every enclosure is the API's `browser_download_url`."""
    found = catalogue(github, tmp_path)
    published = found.latest()
    release = found.fetch(published)
    assert release.enclosure_url == published.zip_url == OWN_ZIP


@pytest.mark.parametrize(
    "url",
    [
        "https://nowhere.invalid/iillyyaa1997/udeck/releases/download/v0.6.1/uDeck-0.6.1.zip",  # another host
        "https://github.com.example.net/iillyyaa1997/udeck/releases/download/v0.6.1/uDeck-0.6.1.zip",  # a look-alike
        "https://github.com@example.net/iillyyaa1997/udeck/releases/download/v0.6.1/uDeck-0.6.1.zip",  # user@host
        f"https://github.com/{config.RELEASES_REPOSITORY}-fork/releases/download/v0.6.1/uDeck-0.6.1.zip",  # another repo
        f"{DOWNLOAD}/v0.6.0/uDeck-0.6.1.zip",  # another tag
        f"{DOWNLOAD}/v0.6.1/../../v0.5.0/uDeck-0.6.1.zip",  # a path that walks out of the tag
        OWN_ZIP.replace("https://", "http://"),  # plain http
        f"https://example.net/?{OWN_ZIP}",  # the release's own address as a query
        "https://example.net/download?next=a&file=/uDeck-0.6.1.zip",  # a query that ends in the zip's name
        f" {OWN_ZIP}",  # the own address, one space off
        OWN_ZIP.replace("github.com", "github.com:8443"),  # another port
        OWN_ZIP.replace("https://", "http://").replace("github.com", "github.com:443"),  # http, on https's port
        OWN_ZIP.replace(config.RELEASES_REPOSITORY, config.RELEASES_REPOSITORY.upper()),  # the path in another case
        "uDeck-0.6.1.zip",  # relative: resolved against whichever feed it was read from
    ],
)
def test_an_appcast_that_sends_udeck_anywhere_but_the_releases_own_zip_is_the_releases_defect(github, tmp_path, url):
    """Where Sparkle downloads from is the enclosure's URL: an item that names the zip and points elsewhere is a
    release whose every offer comes from there — and a host that does not answer would read as the network's."""
    data = github.zips["0.6.1"]
    put(github, "0.6.1", data, an_appcast("0.6.1", "8", data, github.key.sign(data), url=url))
    said = refused(github, tmp_path, defect=True)
    assert f"the appcast's item for uDeck-0.6.1.zip sends uDeck to {url}, not to the asset GitHub's API lists for v0.6.1 ({OWN_ZIP})" in said
    assert "GitHub's copies are kept in .build/e2e/releases/v0.6.1/" in said


@pytest.mark.parametrize(
    "url",
    [
        OWN_ZIP.replace("https://", "HTTPS://"),  # the scheme in another case
        OWN_ZIP.replace("github.com", "GitHub.com"),  # the host in another case
        OWN_ZIP.replace("github.com", "github.com:443"),  # https's own port, written
        OWN_ZIP.replace("https://github.com", "Https://GITHUB.COM:443"),  # all three
    ],
)
def test_an_address_that_differs_only_where_addresses_never_differ_is_the_releases_own_zip(github, tmp_path, url):
    """Scheme and host in any case, and https's own port written or not, name the same asset (RFC 3986, 6.2.2.1 and
    6.2.3) — and Sparkle takes the scheme in any case. Red for those would be a verdict against an appcast that
    sends every uDeck to the right place."""
    data = github.zips["0.6.1"]
    put(github, "0.6.1", data, an_appcast("0.6.1", "8", data, github.key.sign(data), url=url))
    found = catalogue(github, tmp_path)
    release = found.fetch(found.named("0.6.1"), offered=True)
    assert release.elsewhere is None and release.enclosure_url == url
    assert releases.same_address(url, OWN_ZIP) and releases.same_address(OWN_ZIP, url)


def test_where_the_appcast_sends_udeck_is_a_defect_only_of_the_release_a_check_is_offered(github, tmp_path):
    """A release only installed is never offered its own zip: nothing reads where its appcast sends uDeck."""
    data = github.zips["0.6.1"]
    url = OWN_ZIP.replace("github.com", "nowhere.invalid")
    put(github, "0.6.1", data, an_appcast("0.6.1", "8", data, github.key.sign(data), url=url))
    notes = []
    found = catalogue(github, tmp_path, notes)
    installed = found.fetch(found.named("0.6.1"))
    assert installed.enclosure_url == url and installed.build == "8"
    assert installed.elsewhere and f"sends uDeck to {url}, not to the asset GitHub's API lists" in installed.elsewhere
    assert any("the defect of a release a check is offered" in note for note in notes), notes
    github.web.asked.clear()
    with pytest.raises(ReleaseDefect) as raised:
        found.fetch(found.named("0.6.1"), offered=True)
    assert raised.value.reason == installed.elsewhere and raised.value.build == "8"
    assert "GitHub's copies are kept in .build/e2e/releases/v0.6.1/" in raised.value.reason
    assert github.web.asked == [], "the same copy, asked as the one offered: GitHub is not asked again"


@pytest.mark.parametrize("url", [f"{OWN_ZIP}?mirror=example.net", f"{OWN_ZIP}#x", f"{OWN_ZIP}/"])
def test_the_zips_own_address_with_anything_after_it_names_no_item_for_the_zip(github, tmp_path, url):
    """By its file name an item is found; whatever follows the name makes it no item for the zip — a defect too."""
    data = github.zips["0.6.1"]
    put(github, "0.6.1", data, an_appcast("0.6.1", "8", data, github.key.sign(data), url=url))
    assert "has no item whose enclosure is uDeck-0.6.1.zip" in refused(github, tmp_path, defect=True)


def test_a_copy_kept_from_before_whose_appcast_sends_udeck_elsewhere_is_fetched_again(tmp_path):
    """The cached appcast is held to the rule too — shown where nothing else would catch it: an API with no
    digest, and a copy of the very size it lists. It does not check, and GitHub's own replaces it."""
    github = GitHubAsOn20261009()
    listed = json.loads(github.web.answers[f"{API}?per_page=100"].body)
    for item in listed:
        for asset in item["assets"]:
            asset.pop("digest")
    github.web.json(f"{API}?per_page=100", listed)
    found = catalogue(github, tmp_path)
    release = found.fetch(found.latest())
    data = github.zips["0.6.1"]
    elsewhere = an_appcast("0.6.1", "8", data, github.key.sign(data), url=OWN_ZIP.replace("github.com", "gitlab.com"))
    assert len(elsewhere) == release.appcast.stat().st_size, "the same size: only the address tells them apart"
    release.appcast.write_bytes(elsewhere)
    notes = []
    again = catalogue(github, tmp_path, notes)
    assert again.fetch(again.latest()).enclosure_url == OWN_ZIP
    assert any("does not check" in note and "sends uDeck to https://gitlab.com/" in note and "fetching it again" in note
               for note in notes), notes  # fmt: skip


def test_an_appcast_without_an_item_for_the_zip_is_refused(github, tmp_path):
    data = github.zips["0.6.1"]
    put(github, "0.6.1", data, an_appcast("0.6.1", "8", data, github.key.sign(data), name="uDeck-0.6.2.zip"))
    assert "has no item whose enclosure is uDeck-0.6.1.zip" in refused(github, tmp_path)


def test_github_serving_a_zip_of_another_size_than_its_api_says_is_refused(github, tmp_path):
    """A download cut short: the lab did not get the release, which says nothing about it."""
    github.web.file(f"{DOWNLOAD}/v0.6.1/uDeck-0.6.1.zip", github.zips["0.6.1"][:-10])
    assert "where its API says" in refused(github, tmp_path, defect=False)


@pytest.mark.parametrize("status", [404, 410])
@pytest.mark.parametrize("asset", ["appcast.xml", "uDeck-0.6.1.zip"])
def test_an_asset_its_api_lists_that_github_says_is_not_there_is_the_releases_defect(github, tmp_path, status, asset):
    """The guest's rule too (`updates.github_answers`): every uDeck that asks for that asset meets the same."""
    github.web.file(f"{DOWNLOAD}/v0.6.1/{asset}", b"", status=status)
    said = refused(github, tmp_path, defect=True)
    assert f"GitHub answered {status} for {DOWNLOAD}/v0.6.1/{asset}, an asset its own API lists" in said
    assert releases.ASSET_MISSING == updates.ASSET_MISSING == (404, 410), "one rule on this Mac and in the guest"


@pytest.mark.parametrize("status", [403, 429, 500, 502, 503, 301])
def test_github_in_trouble_for_an_asset_is_the_labs_could_not_check(github, tmp_path, status):
    github.web.file(f"{DOWNLOAD}/v0.6.1/uDeck-0.6.1.zip", b"", status=status)
    assert f"GitHub answered {status} for {DOWNLOAD}/v0.6.1/uDeck-0.6.1.zip" in refused(github, tmp_path, defect=False)


def plist_zip(info_plist):
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w") as archive:
        archive.writestr("uDeck.app/Contents/Info.plist", info_plist)
    return buffer.getvalue()


@pytest.mark.parametrize(
    ("info_plist", "said"),
    [
        (b'<?xml version="1.0"?><plist version="1.0"><dict><key>a</key><string>b</dict></plist>', "ExpatError"),
        (b"bplist00 not a binary plist", "InvalidFileException"),
        (plistlib.dumps(["not", "a", "dictionary"]), "is a list, not a dictionary"),
    ],
)
def test_an_info_plist_that_cannot_be_read_is_the_releases_defect(github, tmp_path, info_plist, said):
    """Malformed XML is expat's error, not a ValueError: it used to escape as "could not check"."""
    data = plist_zip(info_plist)
    put(github, "0.6.1", data, an_appcast("0.6.1", "8", data, github.key.sign(data)))
    assert said in refused(github, tmp_path, defect=True)


def test_an_entry_that_will_not_inflate_is_the_releases_defect(github, tmp_path):
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        archive.writestr("uDeck.app/Contents/Info.plist", plistlib.dumps({"a": "b" * 4000}))
    data = bytearray(buffer.getvalue())
    start = data.index(b"Info.plist") + len(b"Info.plist")
    data[start + 5 : start + 25] = b"\xff" * 20  # inside the deflated stream, past the local header
    data = bytes(data)
    put(github, "0.6.1", data, an_appcast("0.6.1", "8", data, github.key.sign(data)))
    said = refused(github, tmp_path, defect=True)
    assert "has no readable uDeck.app/Contents/Info.plist" in said


# --- A copy on this Mac, held to what GitHub lists now ------------------------------------------


def test_a_copy_of_an_asset_published_again_with_another_size_is_fetched_again(github, tmp_path):
    first = catalogue(github, tmp_path)
    first.fetch(first.latest())
    again = a_zip("0.6.1", "8", github.key, feed=config.LATEST_FEED + "?again")
    github.publish("0.6.1", again, an_appcast("0.6.1", "8", again, github.key.sign(again)))
    notes = []
    second = catalogue(github, tmp_path, notes)
    release = second.fetch(second.latest())
    assert release.zip.read_bytes() == again
    assert any("GitHub's API lists" in note and "fetching it again" in note for note in notes), notes


def test_a_copy_of_an_appcast_published_again_at_the_same_size_is_fetched_again_by_its_digest(github, tmp_path):
    """Every real appcast so far is 932 bytes: a size cannot tell a new one from the old."""
    first = catalogue(github, tmp_path)
    old = first.fetch(first.latest())
    data = github.zips["0.6.1"]
    resigned = an_appcast("0.6.1", "8", data, github.key.sign(data)).replace(b"<title>0.6.1</title>", b"<title>0.6.X</title>")
    assert len(resigned) == old.appcast.stat().st_size
    github.publish("0.6.1", appcast=resigned)
    notes = []
    second = catalogue(github, tmp_path, notes)
    release = second.fetch(second.latest())
    assert release.appcast.read_bytes() == resigned
    assert any("not the SHA-256 GitHub's API lists now" in note and "fetching it again" in note for note in notes), notes


def test_a_copy_that_is_what_github_lists_is_used_again_without_a_download(github, tmp_path):
    first = catalogue(github, tmp_path)
    first.fetch(first.latest())
    github.web.asked.clear()
    notes = []
    second = catalogue(github, tmp_path, notes)
    second.fetch(second.latest())
    assert not [url for url in github.web.asked if url.startswith(DOWNLOAD)]
    assert any("is what GitHub's API lists, and still checks" in note for note in notes)


def test_a_download_whose_sha256_is_not_the_digest_github_lists_is_refused_as_the_labs(github, tmp_path):
    """Same size, other bytes: not the asset GitHub lists, or not whole — nothing about the release is known."""
    data = bytearray(github.zips["0.6.1"])
    data[-1] ^= 0x01
    github.web.file(f"{DOWNLOAD}/v0.6.1/uDeck-0.6.1.zip", bytes(data))
    assert "with another SHA-256 than the digest its API lists" in refused(github, tmp_path, defect=False)


def test_an_api_that_lists_no_digest_is_held_to_the_size_alone(tmp_path):
    github = GitHubAsOn20261009()
    listed = json.loads(github.web.answers[f"{API}?per_page=100"].body)
    for item in listed:
        for asset in item["assets"]:
            asset.pop("digest")
    github.web.json(f"{API}?per_page=100", listed)
    found = catalogue(github, tmp_path)
    published = found.latest()
    assert published.zip_digest is None and published.appcast_digest is None
    assert published.appcast_size == len(github.web.answers[f"{DOWNLOAD}/v0.6.1/appcast.xml"].body)
    assert found.fetch(published).zip.read_bytes() == github.zips["0.6.1"]


def test_a_digest_that_is_not_a_sha256_is_githubs_api_in_a_shape_the_lab_cannot_read(tmp_path):
    web = Web()
    listed = a_release("0.6.1")
    listed["assets"][0]["digest"] = "sha256:nothex"
    web.json(f"{API}?per_page=100", [listed])
    with pytest.raises(ReleaseError, match="in a shape the lab cannot read: the digest 'sha256:nothex'"):
        GitHub(get=web).releases()


def test_the_real_releases_appcast_reads_as_the_lab_expects():
    """The shape of the appcast the release workflow publishes, as v0.6.1's was on 2026-10-09."""
    appcast = b"""<?xml version="1.0" standalone="yes"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
    <channel>
        <title>uDeck</title>
        <item>
            <title>0.6.1</title>
            <pubDate>Thu, 08 Oct 2026 13:30:54 +0000</pubDate>
            <link>https://github.com/iillyyaa1997/udeck</link>
            <sparkle:version>8</sparkle:version>
            <sparkle:shortVersionString>0.6.1</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
            <sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>
            <enclosure url="https://github.com/iillyyaa1997/udeck/releases/download/v0.6.1/uDeck-0.6.1.zip" length="6026092" type="application/octet-stream" sparkle:edSignature="rtOXnxBc2P7ZG2oytqVPW+kXhqJitxw2hMrz3jwfbDkTBJ7h0rGMtWeEwiSBnGKE8aT5W8oE13TsbsdDPNU9AA=="/>
        </item>
    </channel>
</rss>"""
    item = releases.appcast_item(appcast, "uDeck-0.6.1.zip")
    assert (item["version"], item["build"], item["length"]) == ("0.6.1", "8", 6026092)
    assert item["signature"].startswith("rtOXnxBc") and item["url"].endswith("/v0.6.1/uDeck-0.6.1.zip")


# --- Which releases the lab can start from ------------------------------------------------


def a_repository(tmp_path, tags):
    """A checkout whose tags hold a settings view with or without the identifiers the lab presses by."""
    repo = tmp_path / "repo"
    (repo / "Sources" / "UDeckKit" / "Views").mkdir(parents=True)
    git = ["git", "-C", str(repo), "-c", "user.email=lab@example.com", "-c", "user.name=lab", "-c", "commit.gpgsign=false"]
    subprocess.run([*git, "init", "-q"], check=True)
    for tag, identifiers, *more in tags:
        view = "\n".join([f'Button("x").accessibilityIdentifier("{name}")' for name in identifiers] + list(more))
        (repo / "Sources" / "UDeckKit" / "Views" / "SettingsView.swift").write_text(view + "\n")
        subprocess.run([*git, "add", "-A"], check=True)
        subprocess.run([*git, "commit", "-q", "-m", tag], check=True)
        subprocess.run([*git, "tag", tag], check=True)
    return repo


def published(version):
    return Published(f"v{version}", "", f"uDeck-{version}.zip", "", 0)


# The sidebar as every release so far writes it: one identifier per row, over an enum
# of rows (`Section` in SettingsView.swift).
ROWS = ["enum Section: String {", "    case general", "    case about", "}"]


def test_a_release_whose_source_names_the_controls_can_be_from(tmp_path):
    repo = a_repository(tmp_path, [
        ("v0.5.0", ['section.\\(item)', "updates.checkNow", "updates.install"], *ROWS),
        ("v0.5.1", ["section.about", "updates.checkNow", "updates.install"]),
    ])  # fmt: skip
    assert releases.check_now_problem(repo, published("0.5.0")) is None
    assert releases.check_now_problem(repo, published("0.5.1")) is None, "the About row spelled out"


def test_the_about_row_is_one_of_the_sidebars_rows_and_not_any_section(tmp_path):
    """`section.\\(item)` alone names every row the sidebar has, and none of them need be About."""
    repo = a_repository(tmp_path, [
        ("v0.5.0", ['section.\\(item)', "updates.checkNow", "updates.install"]),
        ("v0.5.1", ['section.\\(item)', "updates.checkNow", "updates.install"],
         "enum Section: String {", "    case aboutTitle", "}"),
    ])  # fmt: skip
    for version in ("0.5.0", "0.5.1"):
        said = releases.check_now_problem(repo, published(version))
        assert said and "no section.about" in said and "updates.checkNow" not in said, version


def test_the_rows_enum_has_to_be_where_the_rows_get_their_identifiers(tmp_path):
    """A `case about` in some other file — a phrase, a menu — is not the sidebar having an About row."""
    repo = a_repository(tmp_path, [("v0.5.0", ['section.\\(item)', "updates.checkNow", "updates.install"])])
    git = ["git", "-C", str(repo), "-c", "user.email=lab@example.com", "-c", "user.name=lab", "-c", "commit.gpgsign=false"]
    (repo / "Sources" / "UDeckCore").mkdir(parents=True)
    (repo / "Sources" / "UDeckCore" / "Phrase.swift").write_text("enum Phrase {\n    case about\n}\n")
    subprocess.run([*git, "add", "-A"], check=True)
    subprocess.run([*git, "commit", "-q", "-m", "v0.5.1"], check=True)
    subprocess.run([*git, "tag", "v0.5.1"], check=True)
    said = releases.check_now_problem(repo, published("0.5.1"))
    assert said and "no section.about" in said


def test_a_release_whose_source_names_none_of_them_is_refused_with_which(tmp_path):
    repo = a_repository(tmp_path, [
        ("v0.4.0", []),
        ("v0.4.5", ['section.\\(item)', "updates.checkNow"], *ROWS),
    ])  # fmt: skip
    none = releases.check_now_problem(repo, published("0.4.0"))
    assert "no section.about, no updates.checkNow, no updates.install" in none
    assert "never by translated titles" in none
    one = releases.check_now_problem(repo, published("0.4.5"))
    assert "no updates.install," in one and "section.about" not in one


def test_a_tag_this_checkout_does_not_have_says_how_to_get_it(tmp_path):
    repo = a_repository(tmp_path, [("v0.5.0", [])])
    assert "git fetch --tags" in releases.check_now_problem(repo, published("0.6.1"))
