"""The update an update check is offered: an appcast, signed, served inside the guest.

Sparkle asks a feed what is available, downloads the enclosure and checks its
EdDSA signature against the public key in the running application. All three ends
of that belong to the run: the key is made per run (see `builds`), the appcast is
written here, and both the feed and the archive are served from inside the guest
on its own loopback address — so nothing about the check depends on the network,
and nothing the lab serves is reachable from outside the machine.

Measured in a guest (2026-09-17): `/usr/bin/python3` is 3.9.6 and works without
the developer tools, so `python3 -m http.server` is enough to serve the feed;
`ditto -x -k` unpacks a lab build into /Applications owned by the logged-in user
with no quarantine attribute, and the build launches (ad-hoc signature, the
release's bundle identifier).
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

# Where the guest keeps what is served, and the application it installs into.
GUEST_FEED_DIR = "/tmp/udeck-e2e-feed"
GUEST_APPLICATIONS = "/Applications"
APP = "uDeck.app"


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


def running_pids(machine, step: str = "looking for uDeck") -> set[str]:
    """The pids uDeck has in the guest — empty when it is not running.

    `ask`, never `run(..., check=False)`: a connection that dropped would
    otherwise answer "nothing is running", and a check would pronounce that
    about uDeck.
    """
    return set(machine.ssh.ask("pgrep -x uDeck || true", step).stdout.split())


def quit_app(machine, step: str, seconds: float = config.QUIT_SECONDS) -> None:
    """End any uDeck running in the guest, and prove it ended.

    A running copy is replaced by `ditto` underneath itself: it keeps running
    from the bundle that was deleted, so `open -a` afterwards only brings it
    forward and the check drives the *old* application. On a shared machine
    (--vm per-group, per-run) that copy belongs to the previous check, and the
    negative control would then be offered nothing by an application that has
    already updated itself — and pass having checked no signature at all.

    Asked first, killed second. A copy that will not go is the lab failing to
    prepare the machine, never a verdict about uDeck.
    """
    if not running_pids(machine, step):
        return
    machine.ssh.run(
        # Guarded by System Events: a bare `tell application "uDeck" to quit`
        # asks LaunchServices for the bundle, which is the one about to go.
        'osascript -e \'tell application "System Events" to if exists process "uDeck" '
        'then tell application "uDeck" to quit\' >/dev/null 2>&1; exit 0',
        step,
        check=False,
    )
    killed = False
    deadline = machine.clock() + seconds
    while True:
        pids = running_pids(machine, step)
        if not pids:
            return
        if machine.clock() >= deadline:
            raise LabError(step, f"uDeck was still running in the guest as {sorted(pids)} after {seconds:.0f}s")
        if not killed and machine.clock() >= deadline - seconds / 2:
            machine.ssh.run("pkill -x uDeck 2>/dev/null; exit 0", step, check=False)
            killed = True
        machine.sleep(1)


def install(machine, archive: Path, note: Note) -> None:
    """Install a lab build inside the guest, the way a person installs one (Q47).

    `ditto -x -k` into /Applications, owned by the logged-in user, and no
    quarantine attribute: an ad-hoc signed build carrying one would need a person
    to right-click it.

    Whatever was running goes first: the bundle is about to be replaced.
    """
    step = f"installing {archive.name} in {machine.name}"
    quit_app(machine, f"quitting the uDeck already running in {machine.name}")
    remote = f"/tmp/{archive.name}"
    machine.ssh.copy_in(archive, remote, step)
    machine.ssh.run(
        f"rm -rf {shlex.quote(GUEST_APPLICATIONS)}/{APP} && "
        f"ditto -x -k {shlex.quote(remote)} {shlex.quote(GUEST_APPLICATIONS)}",
        step,
    )
    app = f"{GUEST_APPLICATIONS}/{APP}"
    owner = machine.ssh.run(f"stat -f %Su {shlex.quote(app)}", step).stdout.strip()
    if owner != config.GUEST_USER:
        raise LabError(step, f"{app} belongs to {owner}, not to {config.GUEST_USER}")
    quarantined = machine.ssh.ask(f"xattr -p com.apple.quarantine {shlex.quote(app)}", step)
    if quarantined.returncode == 0:
        raise LabError(step, f"{app} carries a quarantine attribute: {quarantined.stdout.strip()}")
    note(f"   installed {archive.name} in {machine.name}")


def installed_version(machine) -> tuple[str, str]:
    """What is on disk in the guest: the version people read, and the one Sparkle compares."""
    step = f"reading the version installed in {machine.name}"
    app = f"{GUEST_APPLICATIONS}/{APP}/Contents/Info"
    done = machine.ssh.run(
        f"defaults read {shlex.quote(app)} CFBundleShortVersionString; "
        f"defaults read {shlex.quote(app)} CFBundleVersion",
        step,
    )
    lines = done.stdout.split()
    if len(lines) < 2:
        raise LabError(step, f"unexpected answer {done.stdout.strip()!r}")
    return lines[0], lines[1]
