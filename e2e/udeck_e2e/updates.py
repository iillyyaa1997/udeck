"""The update an update check is offered: an appcast, signed, served inside the guest.

Sparkle asks a feed what is available, downloads the enclosure and checks its
EdDSA signature against the public key in the running application. All three ends
of that belong to the run: the key is made per run (see `builds`), the appcast is
written here, and both the feed and the archive are served from inside the guest
on its own loopback address — so nothing about the check depends on the network,
and nothing the lab serves is reachable from outside the machine.

Installing the application itself is not here — that is `app`, which both the
update checks and the panel checks use. This module is the offer: signed,
described in an appcast, and served.

Measured in a guest (2026-09-17): `/usr/bin/python3` is 3.9.6 and works without
the developer tools, so `python3 -m http.server` is enough to serve the feed.
"""

from __future__ import annotations

import shlex
import subprocess
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path
from xml.sax.saxutils import quoteattr

from udeck_e2e import config
from udeck_e2e.builds import Build, SigningKey
from udeck_e2e.errors import LabError

Note = Callable[[str], None]

# Where SwiftPM leaves Sparkle's own tools once the package has been fetched.
SIGN_UPDATE = Path(".build") / "artifacts" / "sparkle" / "Sparkle" / "bin" / "sign_update"

# Where the guest keeps what is served.
GUEST_FEED_DIR = "/tmp/udeck-e2e-feed"


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

    @property
    def base_url(self) -> str:
        return f"http://127.0.0.1:{self.port}"

    @property
    def url(self) -> str:
        return f"{self.base_url}/appcast.xml"

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
        self._wait_until_it_answers(step)

    def _wait_until_it_answers(self, step: str) -> None:
        deadline = self.machine.clock() + config.FEED_UP_SECONDS
        while True:
            done = self.machine.ssh.ask(
                f"/usr/bin/curl -s -o /dev/null -w '%{{http_code}}' {shlex.quote(self.url)}", step, seconds=30
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
                f"/usr/bin/curl -s -o /dev/null -w '%{{http_code}}' {shlex.quote(self.url)}", step, seconds=30
            )
        except LabError:
            return False
        return done.stdout.strip() == "200"

    def collect_log(self, directory: Path, name: str = "feed-server.log") -> str:
        """The guest's own access log, brought back as evidence (Q38), and returned.

        What the pane says is a sentence uDeck writes about itself; this is the
        traffic. It is the only record of what Sparkle actually fetched — and
        for the negative control, fetching the archive *is* the proof that the
        signature was checked, because Sparkle checks it after downloading.

        Evidence, so it never raises: a check's verdict must not turn on whether
        its artefacts could be collected.
        """
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
