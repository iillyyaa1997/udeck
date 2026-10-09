"""The update an update check is offered: an appcast, signed, served inside the guest.

Sparkle asks a feed what is available, downloads the enclosure and checks its
EdDSA signature against the public key in the running application. When the
offer is a build of this checkout, all three ends of that belong to the run: the
key is made per run (see `builds`), the appcast is written here, and both the
feed and the archive are served from inside the guest on its own loopback
address — so nothing about the check depends on the network, and nothing the lab
serves is reachable from outside the machine.

When the offer is a published release (`pairs`), none of it is the lab's: the
feed is GitHub's, the archive comes from GitHub's asset host, and the key is the
release's. What this module does then is ask, from inside the guest, whether the
guest reaches them at all (`github_answers`) — so that a guest without the
network is the lab's failure and never a verdict about uDeck.

Installing the application itself is not here — that is `app`, which both the
update checks and the panel checks use. This module is the offer: signed,
described in an appcast, and served.

Measured in a guest (2026-09-17): `/usr/bin/python3` is 3.9.6 and works without
the developer tools, so `python3 -m http.server` is enough to serve the feed.
"""

from __future__ import annotations

import re
import shlex
import subprocess
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import urlsplit
from xml.sax.saxutils import quoteattr

from udeck_e2e import config, releases
from udeck_e2e.builds import Build, SigningKey
from udeck_e2e.errors import LabError

Note = Callable[[str], None]

# Where SwiftPM leaves Sparkle's own tools once the package has been fetched.
SIGN_UPDATE = Path(".build") / "artifacts" / "sparkle" / "Sparkle" / "bin" / "sign_update"

# Where the guest keeps what is served.
GUEST_FEED_DIR = "/tmp/udeck-e2e-feed"

# The appcast's name on the feed — and so in every lab build's `SUFeedURL`, which
# is `Feed.url`.
APPCAST = "appcast.xml"

# What the lab adds to its own requests for the appcast, so that the guest's
# access log can tell them apart from uDeck's. Two checks turn on nothing but that
# log — did uDeck ask its feed by itself, or not — and the lab asks the same
# server for the same file to learn whether it is up, so without a mark the lab's
# own asking would be read as uDeck's. `http.server` drops the query when it
# picks the file (`SimpleHTTPRequestHandler.translate_path`), so a request
# carrying it gets the appcast like any other, and the probe still asks what it
# always asked.
LAB_PROBE = "asked-by=the-lab"

# One line of the guest's access log, as `http.server` writes it:
# `127.0.0.1 - - [26/Sep/2026 20:41:07] "GET /appcast.xml HTTP/1.1" 200 -`.
# The method, the query and the protocol are read and not pinned: Sparkle may add
# parameters of its own, and what is being asked is whether the appcast was asked
# for and by whom — never how.
_APPCAST_REQUEST = re.compile(rf'"[A-Z]+ /{re.escape(APPCAST)}(?:\?(?P<query>[^" ]*))? HTTP/[^"]*"')


def find_sign_update(repo_root: Path) -> Path:
    """Sparkle's signing tool from the checkout, never one installed on this Mac."""
    tool = repo_root / SIGN_UPDATE
    if not tool.is_file():
        raise LabError(
            "finding Sparkle's sign_update",
            f"{SIGN_UPDATE} is not in the checkout; build once ('swift build') so SwiftPM fetches Sparkle",
        )
    return tool


def sign(zip_path: Path, key: SigningKey, tool: Path, run: Callable[..., subprocess.CompletedProcess[str]] = subprocess.run) -> str:
    """The EdDSA signature Sparkle will check, from Sparkle's own tool.

    The key is a file, not the keychain: `generate_keys` would leave a private key
    on this Mac for a test that lasts minutes (measured: the file holds the base64
    of the 32-byte seed, and this signature verifies against the public key the
    build carries).
    """
    step = f"signing {zip_path.name}"
    try:
        done = run(
            [str(tool), "--ed-key-file", str(key.private_key_file), "-p", str(zip_path)],
            capture_output=True,
            text=True,
            errors="replace",
            timeout=config.SIGN_SECONDS,
            check=False,
            stdin=subprocess.DEVNULL,
            start_new_session=True,
        )
    except subprocess.TimeoutExpired:
        raise LabError(step, f"sign_update did not finish in {config.SIGN_SECONDS:.0f}s") from None
    except OSError as error:
        raise LabError(step, f"could not run sign_update: {error}") from None
    signature = (done.stdout or "").strip()
    if done.returncode != 0 or not signature:
        lines = (done.stderr or done.stdout or "").strip().splitlines()
        raise LabError(step, f"sign_update exited {done.returncode}: {lines[-1] if lines else 'no output'}")
    return signature


@dataclass(frozen=True)
class Offer:
    """One update in the appcast: a build, its signature, and what it weighs."""

    build: Build
    signature: str
    length: int


def empty_appcast() -> str:
    """A feed that offers nothing.

    For the checks whose question is whether uDeck *asks*, not what it does with
    the answer: a feed with an item in it would need a second build, signed, for
    a question that ends at the request.
    """
    return (
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">\n'
        "  <channel>\n"
        "    <title>uDeck</title>\n"
        "  </channel>\n"
        "</rss>\n"
    )


def asked_for_the_appcast(log: str) -> list[str]:
    """The lines of the guest's access log where the appcast was asked for by anyone but the lab.

    Inside the guest, with the server bound to its loopback and the address baked
    into the one application installed there, that is uDeck: nothing else on the
    machine knows the feed exists. The lab's own requests carry `LAB_PROBE` and
    are left out, whatever else their query says.
    """
    found = []
    for line in log.splitlines():
        match = _APPCAST_REQUEST.search(line)
        if match and LAB_PROBE not in (match.group("query") or "").split("&"):
            found.append(line)
    return found


def appcast(offer: Offer, base_url: str, published: str = "Wed, 17 Sep 2026 10:00:00 +0000") -> str:
    """The feed Sparkle reads, with one item in it.

    `sparkle:version` is the build number, which is what Sparkle compares against
    the running application's CFBundleVersion; the short version is only what a
    person sees.
    """
    url = f"{base_url.rstrip('/')}/{offer.build.zip.name}"
    return (
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">\n'
        "  <channel>\n"
        "    <title>uDeck</title>\n"
        "    <item>\n"
        f"      <title>{offer.build.version}</title>\n"
        f"      <pubDate>{published}</pubDate>\n"
        f"      <sparkle:version>{offer.build.build_number}</sparkle:version>\n"
        f"      <sparkle:shortVersionString>{offer.build.version}</sparkle:shortVersionString>\n"
        "      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>\n"
        f"      <enclosure url={quoteattr(url)}\n"
        f'                 length="{offer.length}"\n'
        '                 type="application/octet-stream"\n'
        f"                 sparkle:edSignature={quoteattr(offer.signature)}/>\n"
        "    </item>\n"
        "  </channel>\n"
        "</rss>\n"
    )


# What the guest's curl is asked to print after an answer, on a line of its own, so
# that the lab can tell the answer from what it says about it.
_CURL_SAID = "udeck-e2e-curl"


def _curl(machine, url: str, step: str, *, body: bool, first_bytes: int | None = None) -> tuple[str, int, int, str]:
    """GitHub asked from inside the guest, redirects followed: what it said, its status, how many redirects, and the host it ended at.

    curl failing — no route, no name, no answer in time — is the lab's: the
    guest could not reach what the check needs, and the reason is curl's own
    words, so it can be acted on.
    """
    # curl reads the two characters `\n` in its own format as a new line.
    said_after = "\\n" + _CURL_SAID + " %{http_code} %{num_redirects} %{url_effective}"
    command = (
        f"/usr/bin/curl -sS -L --max-time {config.GUEST_GITHUB_SECONDS:.0f} "
        + (f"-r 0-{first_bytes - 1} " if first_bytes else "")
        + ("" if body else "-o /dev/null ")
        + f"-w {shlex.quote(said_after)} "
        + shlex.quote(url)
    )
    done = machine.ssh.ask(command, step, seconds=config.GUEST_GITHUB_SECONDS + 30)
    said, _, tail = (done.stdout or "").rpartition(f"\n{_CURL_SAID} ")
    if done.returncode != 0 or not tail:
        why = (done.stderr or "").strip().splitlines()
        raise LabError(
            step,
            f"the guest could not reach {_host(url)} for {url}: "
            f"{why[-1] if why else f'curl exited {done.returncode}'}",
        )
    parts = tail.strip().split(" ", 2)
    try:
        status, redirects = int(parts[0]), int(parts[1])
    except (IndexError, ValueError):
        raise LabError(step, f"the guest's curl said something the lab cannot read about {url}: {tail.strip()[:200]!r}") from None
    return said, status, redirects, _host(parts[2] if len(parts) > 2 else url)


def _host(url: str) -> str:
    return urlsplit(url).hostname or url


# What GitHub answers when an asset is not there — the one rule for this Mac and
# the guest alike (`releases.ASSET_MISSING`). Every other status that is not
# success — 403, 429, the 5xx of a server in trouble — is GitHub declining or
# failing to answer, which is the network's, never the release's.
ASSET_MISSING = releases.ASSET_MISSING


def _github_in_trouble(step: str, url: str, status: int, at: str, redirects: int) -> LabError:
    return LabError(
        step,
        f"GitHub answered the guest {status} for {url} from {at} after {redirects} redirect(s): GitHub declining or "
        "failing to answer, which says nothing about uDeck or the release",
    )


def github_answers(machine, release: releases.Release, feed_url: str, step: str) -> tuple[bool, str]:
    """Whether the guest reaches what an update from GitHub needs, and what GitHub said — one line for the report.

    Asked from inside the guest, with its own curl, following redirects the way
    Sparkle does: the feed "from" will ask — the real feed through GitHub's latest
    redirect, or the release's own appcast — and the first bytes of the archive it
    names, from wherever GitHub sends them (on 2026-10-09,
    release-assets.githubusercontent.com, one redirect from github.com).

    **No network is the lab's.** curl failing to get an answer at all — no name,
    no route, no answer in time — raises LabError with curl's own words: the check
    could not be made, and says nothing about uDeck. So does GitHub answering with
    trouble of its own — 403, 429, a 5xx, anything but success or a missing asset
    — because that is the network too, at the level of HTTP. So does a feed
    answering with something the lab cannot read as an appcast, or one whose item
    for the zip is not the item the lab checked on this Mac — another build, another
    address or another signature, a release published while the run was starting:
    "to" would no longer be what the check holds the disk to. The rest of the
    appcast is not compared.

    **A missing asset is not the lab's to judge.** GitHub answering 404 or 410 for
    the feed or the archive — a release that has lost an asset since the lab
    fetched it, or a latest redirect that leads nowhere — is what every uDeck that
    looks meets too, so it comes back as `False` with what was said, and the check
    goes on: what uDeck does with it is the verdict. The same answer on this Mac,
    while the lab fetches a "to", is that check's failure before any machine
    (`releases.ReleaseDefect`): one rule on both sides.

    Asked before the check starts, and again before it judges.
    """
    body, status, redirects, at = _curl(machine, feed_url, step, body=True)
    if status in ASSET_MISSING:
        return False, f"{feed_url} answered the guest {status} from {at} after {redirects} redirect(s)"
    if status != 200:
        raise _github_in_trouble(step, feed_url, status, at, redirects)
    try:
        item = releases.appcast_item(body, release.published.zip_name)
    except releases.ReleaseError as error:
        raise LabError(step, f"{feed_url} answered the guest with something the lab cannot use as its appcast: {error.reason}") from None
    if (item["build"], item["url"], item["signature"]) != (release.build, release.enclosure_url, release.signature):
        raise LabError(
            step,
            f"{feed_url} offers the guest {item['version']} ({item['build']}), where the lab checked "
            f"{release.version} ({release.build}) on this Mac — a release published while the run was starting?",
        )
    _, archive_status, archive_redirects, archive_at = _curl(machine, release.enclosure_url, step, body=False, first_bytes=1024)
    said = (
        f"{feed_url} answered the guest {status} from {at} after {redirects} redirect(s), offering "
        f"{item['version']} ({item['build']}); its archive answered {archive_status} from {archive_at} after "
        f"{archive_redirects} redirect(s)"
    )
    if archive_status not in (200, 206, *ASSET_MISSING):
        raise _github_in_trouble(step, release.enclosure_url, archive_status, archive_at, archive_redirects)
    return archive_status in (200, 206), said


class Feed:
    """The appcast and its archive, served inside one machine on its own loopback.

    Nothing leaves the machine: the server listens on 127.0.0.1 inside the guest,
    which is also the address baked into every lab build.
    """

    def __init__(self, machine, note: Note, port: int = config.FEED_PORT) -> None:
        self.machine = machine
        self.note = note
        self.port = port
        self.serving = False
        # Whether the lab ever served anything here. A check whose "to" is a
        # published release serves nothing, and has no log of the lab's to collect.
        self.served = False

    @property
    def base_url(self) -> str:
        return f"http://127.0.0.1:{self.port}"

    @property
    def url(self) -> str:
        return f"{self.base_url}/{APPCAST}"

    @property
    def probe_url(self) -> str:
        """The appcast as the lab asks for it: the same file, marked as the lab's in the log."""
        return f"{self.url}?{LAB_PROBE}"

    def serve(self, appcast_file: Path, *archives: Path) -> None:
        """Put the feed and its archives in the guest and start serving them."""
        step = f"serving the update feed in {self.machine.name}"
        self.machine.ssh.run(f"rm -rf {shlex.quote(GUEST_FEED_DIR)} && mkdir -p {shlex.quote(GUEST_FEED_DIR)}", step)
        for path in (appcast_file, *archives):
            self.machine.ssh.copy_in(path, f"{GUEST_FEED_DIR}/{path.name}", step)
        self.machine.ssh.run(
            f"cd {shlex.quote(GUEST_FEED_DIR)} && "
            # --bind, or it would listen on every address the guest has: the
            # machine's own network is reachable from this Mac (measured).
            f"(/usr/bin/python3 -m http.server {self.port} --bind 127.0.0.1 >server.log 2>&1 & echo $! >server.pid)",
            step,
        )
        self.serving = True
        self.served = True
        self._wait_until_it_answers(step)

    def _wait_until_it_answers(self, step: str) -> None:
        deadline = self.machine.clock() + config.FEED_UP_SECONDS
        while True:
            done = self.machine.ssh.ask(
                f"/usr/bin/curl -s -o /dev/null -w '%{{http_code}}' {shlex.quote(self.probe_url)}", step, seconds=30
            )
            if done.stdout.strip() == "200":
                return
            if self.machine.clock() >= deadline:
                said = self.machine.ssh.ask(f"tail -3 {shlex.quote(GUEST_FEED_DIR)}/server.log", step).stdout.strip()
                raise LabError(step, f"the guest's own server did not answer within {config.FEED_UP_SECONDS:.0f}s: {said}")
            self.machine.sleep(1)

    def answers_now(self, step: str) -> bool:
        """Whether the feed is still there, asked once, for a check about to judge.

        `serve` proves the feed answers before anything else happens; this is for
        the moment a check is about to say uDeck did not find an update. A feed
        that has since died gives uDeck nothing to find, and the sentence would be
        about the lab wearing uDeck's name.
        """
        try:
            done = self.machine.ssh.ask(
                f"/usr/bin/curl -s -o /dev/null -w '%{{http_code}}' {shlex.quote(self.probe_url)}", step, seconds=30
            )
        except LabError:
            return False
        return done.stdout.strip() == "200"

    def read_log(self, step: str) -> str:
        """The guest's access log as it stands, for a check whose verdict turns on it.

        `collect_log` never raises, because there the log is evidence. Here it is
        the oracle, and "nobody asked for the appcast" read out of a log that could
        not be read would be a verdict about uDeck made of a dropped connection or
        a server that never wrote one. So both are the lab's, and say so.
        """
        done = self.machine.ssh.ask(f"cat {shlex.quote(GUEST_FEED_DIR)}/server.log", step)
        if done.returncode != 0:
            said = (done.stderr or done.stdout or "").strip()
            raise LabError(step, f"the guest's server log could not be read: {said or f'exit {done.returncode}'}")
        return done.stdout

    def collect_log(self, directory: Path, name: str = "feed-server.log") -> str:
        """The guest's own access log, brought back as evidence (Q38), and returned.

        What the pane says is a sentence uDeck writes about itself; this is the
        traffic. It is the only record of what Sparkle actually fetched — and
        for the negative control, fetching the archive *is* the proof that the
        signature was checked, because Sparkle checks it after downloading.

        Evidence, so it never raises: a check's verdict must not turn on whether
        its artefacts could be collected.
        """
        if not self.served:
            return ""
        step = f"collecting the feed's log from {self.machine.name}"
        try:
            text = self.machine.ssh.ask(f"cat {shlex.quote(GUEST_FEED_DIR)}/server.log", step).stdout
        except LabError as error:
            self.note(f"   the feed's log could not be read: {error.reason}")
            return ""
        try:
            (directory / name).write_text(text)
        except OSError as error:
            self.note(f"   the feed's log could not be written to {directory / name}: {error}")
        return text

    def stop(self) -> None:
        """Stop serving. Said, not raised: a check's verdict does not turn on this."""
        if not self.serving:
            return
        try:
            self.machine.ssh.run(
                f"kill $(cat {shlex.quote(GUEST_FEED_DIR)}/server.pid) 2>/dev/null; exit 0",
                f"stopping the update feed in {self.machine.name}",
                check=False,
            )
            self.serving = False
        except LabError as error:
            self.note(f"   the update feed in {self.machine.name} could not be stopped: {error}")
