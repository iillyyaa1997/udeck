"""uDeck, built for the lab: the release configuration, a throwaway feed and key.

An update check has to be run against real builds — the thing Sparkle downloads
and installs is an application bundle, and nothing smaller proves it works. So
the lab builds uDeck itself, twice, from the checkout it is running in: one
version to install and a newer one to be offered.

Three things make a lab build different from a build a person makes, and each
was decided rather than assumed:

* It goes to a directory of the run's own, never `dist/`, where the copies a
  person builds and uses live.
* It carries a version of the lab's choosing, in both keys — the one people read
  and `CFBundleVersion`, which is the one Sparkle compares.
* It stays a zip on this Mac and is unpacked only inside a machine. A lab build
  carries the release's bundle identifier, so an unpacked copy here could take
  the release's login item merely by being launched. Nothing in this module
  unpacks one.

The signing key is made here and thrown away with the run. Sparkle's own
`generate_keys` would put a private key in the login keychain — a permanent
change to this Mac for a test that lasts minutes — so the key is generated in
Python and handed to `sign_update` as a file. Measured: that file holds the
base64 of the 32-byte seed, and a signature `sign_update` makes with it verifies
against the matching public key.
"""

from __future__ import annotations

import base64
import hashlib
import os
import plistlib
import shutil
import signal
import subprocess
import time
import zipfile
from collections.abc import Callable
from dataclasses import dataclass, field
from pathlib import Path

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

from udeck_e2e import config
from udeck_e2e.errors import LabError

Note = Callable[[str], None]

MAKE_APP = Path("Scripts") / "make-app.sh"

# Where the bundle's plist sits inside the zip the script makes.
INFO_PLIST = "uDeck.app/Contents/Info.plist"


@dataclass(frozen=True)
class SigningKey:
    """A key pair for one run: the file `sign_update` signs with, and what the bundle carries."""

    private_key_file: Path = field(repr=False)
    public_key: str


def make_key(directory: Path) -> SigningKey:
    """A throwaway EdDSA key for this run. Never the keychain, never the repository."""
    step = "making this run's signing key"
    try:
        directory.mkdir(parents=True, exist_ok=True)
        key = Ed25519PrivateKey.generate()
        seed = key.private_bytes(
            serialization.Encoding.Raw, serialization.PrivateFormat.Raw, serialization.NoEncryption()
        )
        public = key.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
        path = directory / "sparkle-key"
        # Written before anyone else can read it, not written and then narrowed.
        with open(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w") as file:
            file.write(base64.b64encode(seed).decode())
    except OSError as error:
        raise LabError(step, str(error)) from None
    return SigningKey(path, base64.b64encode(public).decode())


@dataclass(frozen=True)
class Build:
    """One lab build, as it sits on this Mac: a zip, never unpacked here."""

    version: str
    build_number: str
    zip: Path


class Builder:
    """Makes lab builds from the checkout the lab is running in."""

    def __init__(
        self,
        *,
        repo_root: Path,
        work_dir: Path,
        feed_url: str,
        key: SigningKey,
        note: Note,
        popen: Callable[..., subprocess.Popen[str]] = subprocess.Popen,
        seconds: float = config.BUILD_SECONDS,
        sleep: Callable[[float], None] = time.sleep,
        clock: Callable[[], float] = time.monotonic,
        killpg: Callable[[int, int], None] = os.killpg,
        getpgid: Callable[[int], int] = os.getpgid,
    ) -> None:
        self.repo_root = repo_root
        # A directory per feed: two checks serving their own appcast build the same
        # versions, and the second must not overwrite what the first is still using.
        self.work_dir = work_dir / hashlib.sha256(feed_url.encode()).hexdigest()[:8]
        self.feed_url = feed_url
        self.key = key
        self.note = note
        self.seconds = seconds
        self._popen = popen
        self._sleep = sleep
        self._clock = clock
        self._killpg = killpg
        self._getpgid = getpgid

    def build(self, version: str, build_number: str) -> Build:
        """uDeck at `version`, zipped, pointed at this run's feed and key."""
        step = f"building uDeck {version} ({build_number}) for the lab"
        out = self.work_dir / f"{version}-{build_number}"
        self.note(f"   building uDeck {version} — the first one takes a few minutes")
        try:
            out.mkdir(parents=True, exist_ok=True)
        except OSError as error:
            raise LabError(step, f"could not prepare {out}: {error}") from None
        zip_path = out / f"uDeck-{version}.zip"
        try:
            self._call(
                [
                    str(self.repo_root / MAKE_APP),
                    "--out", str(out),
                    "--version", version,
                    "--build", build_number,
                    "--zip",
                    "--test-feed", self.feed_url,
                    "--test-key", self.key.public_key,
                ],
                step,
                out / "build.log",
            )  # fmt: skip
            if not zip_path.is_file():
                raise LabError(step, f"{MAKE_APP} said it was done, but {zip_path.name} is not there")
            # Q41: nothing unpacked stays on this Mac. A bundle here would carry the
            # release's identifier and could take its login item by being launched.
            if (out / "uDeck.app").exists():
                raise LabError(step, f"{MAKE_APP} left {out / 'uDeck.app'} unpacked on this Mac")
            self._verify(zip_path, version, build_number, step)
        finally:
            # A build that died between assembling the bundle and zipping it —
            # a failed signature, a full disk, the deadline — leaves that bundle
            # behind. It carries the release's identifier, so it goes, whatever
            # else happened.
            self._remove_bundle(out / "uDeck.app")
        self.note(f"   built {self.shown(zip_path)} ({zip_path.stat().st_size // 1_000_000} MB)")
        return Build(version, build_number, zip_path)

    def _remove_bundle(self, bundle: Path) -> None:
        if not bundle.exists():
            return
        try:
            shutil.rmtree(bundle)
            self.note(f"   removed the bundle {self.shown(bundle)} that the build left behind")
        except OSError as error:
            self.note(f"   ⚠️ could not remove {self.shown(bundle)}, which carries the release's identifier: {error}")

    def _verify(self, zip_path: Path, version: str, build_number: str, step: str) -> None:
        """Read the bundle's plist out of the zip and check it is the build that was asked for.

        In memory: nothing is extracted here. A build that silently ignored an
        option would otherwise be found only by a check failing for the wrong
        reason — an update that is not newer, a feed nobody serves.
        """
        try:
            with zipfile.ZipFile(zip_path) as archive:
                plist = plistlib.loads(archive.read(INFO_PLIST))
        except (OSError, KeyError, ValueError, zipfile.BadZipFile) as error:
            raise LabError(step, f"could not read {INFO_PLIST} from the build: {error}") from None
        wanted = {
            "CFBundleShortVersionString": version,
            # The one Sparkle compares.
            "CFBundleVersion": build_number,
            "SUFeedURL": self.feed_url,
            "SUPublicEDKey": self.key.public_key,
        }
        wrong = [f"{key} is {plist.get(key)!r}, not {value!r}" for key, value in wanted.items() if plist.get(key) != value]
        identifier = str(plist.get("CFBundleIdentifier", ""))
        if identifier.endswith(".debug"):
            # A lab build has to be the application that is released, identifier
            # and all; a debug identifier would test something nobody ships.
            wrong.append(f"CFBundleIdentifier is {identifier!r}, which is the debug application")
        if wrong:
            raise LabError(step, "the build is not the one that was asked for: " + "; ".join(wrong))

    def shown(self, path: Path) -> str:
        try:
            return str(path.relative_to(self.repo_root))
        except ValueError:
            return str(path)

    def _call(self, args: list[str], step: str, log: Path) -> None:
        """Run the build, and make sure nothing of it outlives this call.

        The script is a shell that starts a compiler: killing the shell alone
        leaves `swift build` running — reparented, still compiling into the
        checkout, still holding SwiftPM's lock — after the lab has given up on it.
        So the build gets a session of its own (which also keeps Ctrl-C for the
        lab) and is ended by its process group: the shell and everything it
        started, together.
        """
        try:
            process = self._popen(
                args,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                errors="replace",
                cwd=str(self.repo_root),
                # See Tart.call: never the operator's terminal, and Ctrl-C belongs
                # to the lab, not to its children.
                stdin=subprocess.DEVNULL,
                start_new_session=True,
            )
        except OSError as error:
            raise LabError(step, f"could not run '{MAKE_APP}': {error}") from None
        try:
            out, err = process.communicate(timeout=self.seconds)
            timed_out = False
        except subprocess.TimeoutExpired:
            self._end_the_build(process)
            out, err = process.communicate()
            timed_out = True
        except BaseException:
            # Ctrl-C, or anything else that unwinds through here: the build does
            # not go on using the Mac after the lab has stopped.
            self._end_the_build(process)
            process.communicate()
            raise
        self._save(log, (out or "") + (err or "") + ("\n… killed at the deadline\n" if timed_out else ""))
        if timed_out:
            raise LabError(step, f"'{MAKE_APP}' did not finish in {self.seconds:.0f}s; its log says how far it got")
        if process.returncode != 0:
            lines = (err or out or "").strip().splitlines()
            said = lines[-1] if lines else f"exit {process.returncode}, no output"
            raise LabError(step, f"'{MAKE_APP}' exited {process.returncode}: {said}")

    def _end_the_build(self, process: subprocess.Popen[str]) -> None:
        """Stop the shell and everything it started, by their process group."""
        try:
            group = self._getpgid(process.pid)
        except OSError:
            return
        for sig, grace in ((signal.SIGTERM, config.BUILD_STOP_GRACE_SECONDS), (signal.SIGKILL, 0.0)):
            try:
                self._killpg(group, sig)
            except OSError:
                return
            deadline = self._clock() + grace
            while process.poll() is None and self._clock() < deadline:
                self._sleep(0.2)
            if process.poll() is not None:
                return

    def _save(self, log: Path, text: str) -> None:
        try:
            log.write_text(text, encoding="utf-8", errors="backslashreplace")
        except OSError as error:
            self.note(f"   could not save the build log: {error}")
