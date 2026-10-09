"""A machine made of answers, shared by every test that drives a check.

One fake, not one per test file. The difference that matters lives here — SSH
failing is not the same as a command answering "no" — and a second copy of this
is how that difference gets lost in one place and never tested there.
"""

import base64
import hashlib
import io
import json
import plistlib
import re
import subprocess
import zipfile
from pathlib import Path
from xml.sax.saxutils import quoteattr

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

from udeck_e2e import config
from udeck_e2e.builds import SigningKey
from udeck_e2e.errors import LabError
from udeck_e2e.guest import parse_boot_time
from udeck_e2e.releases import Answer, ReleaseError


def done(out="", rc=0):
    return subprocess.CompletedProcess([], rc, out, "")


# A line as `log show --style compact` prints it, which is how the tests write
# what uDeck said: date, time, type, process[pid:tid], [subsystem:category], words.
_COMPACT = re.compile(
    r"^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d{3}) (Db|I |Df|E |F ) ([^\[]+)\[(\d+):([0-9a-f]+)\] \[([^:\]]+):([^\]]+)\] (.*)$"
)
_TYPE = {"Db": "Debug", "I ": "Info", "Df": "Default", "E ": "Error", "F ": "Fault"}


def ndjson_of(compact):
    """What the tests wrote as compact lines, as `log show --style ndjson` answers.

    The lab reads ndjson (`panel.as_compact`), and the tests say what uDeck said
    the way a person reads it. Each line is its own record — its own tick of the
    clock, so two alike lines stay two events, as they would be in the guest —
    and the column header is left out, as ndjson has none. A line that is not a
    record is passed on as it is, for the reader to refuse.
    """
    records = []
    for index, line in enumerate(compact.splitlines()):
        if not line.strip() or line.startswith("Timestamp "):
            continue
        found = _COMPACT.match(line)
        if not found:
            records.append(line)
            continue
        when, kind, process, pid, tid, subsystem, category, message = found.groups()
        records.append(json.dumps({
            "timestamp": f"{when}000+0000", "messageType": _TYPE[kind], "processImagePath": f"/Applications/uDeck.app/Contents/MacOS/{process}",
            "processID": int(pid), "threadID": int(tid, 16), "machTimestamp": 1_000_000 + index,
            "subsystem": subsystem, "category": category, "eventMessage": message,
        }))  # fmt: skip
    records.append(json.dumps({"count": len(records), "finished": 1}))
    return "\n".join(records) + "\n"


class Dropped:
    """A connection that failed, as each of the two calls sees it.

    `run(check=False)` gets an exit code and no output — which is why a check
    must never read a pid with it — and `ask` turns the same thing into a lab
    failure. A fake that raised from both would let a check swap one for the
    other and never be caught.
    """


class Failed:
    """An answer that is a non-zero exit code, with whatever the command printed.

    `Dropped` is the connection going away; this is the guest answering "no". The
    two used to be the same thing here, and a check that turns a refused command
    into a lab error had no way to be tested at all.
    """

    def __init__(self, code=1, said=""):
        self.code = code
        self.said = said


class Guest:
    """The SSH side: scripted answers by substring, and a record of what was asked.

    An answer may be a string, a list (one per call, the last one repeating),
    `Dropped`, or an exception to raise.
    """

    def __init__(self, answers=None):
        self.answers = dict(answers or {})
        self.commands = []
        self.copied = []

    def _answer(self, command):
        for pattern, answer in self.answers.items():
            if pattern in command:
                if isinstance(answer, list):
                    answer = answer.pop(0) if len(answer) > 1 else answer[0]
                if isinstance(answer, str) and "--style ndjson" in command:
                    return ndjson_of(answer)
                return answer
        return None

    def _knows(self, command):
        return any(pattern in command for pattern in self.answers)

    def run(self, command, step, seconds=None, check=True):
        self.commands.append(command)
        answer = self._answer(command)
        if answer is Dropped:
            if check:
                raise LabError(step, "SSH to 192.168.64.2 failed")
            return done("", rc=255)
        if isinstance(answer, BaseException):
            raise answer
        if isinstance(answer, Failed):
            # A command that ran and said no. Distinct from Dropped, which is the
            # connection going away: this guest answered, and the answer is an exit
            # code — which is how the guest reports a kernel call it was refused.
            if check:
                raise LabError(step, answer.said or f"exit {answer.code}")
            return done(answer.said, rc=answer.code)
        return done(answer or "")

    def ask(self, command, step, seconds=None):
        """A command whose own exit code is the answer: 0 when this guest knows it."""
        self.commands.append(command)
        answer = self._answer(command)
        if answer is Dropped:
            raise LabError(step, "SSH to 192.168.64.2 failed")
        if isinstance(answer, BaseException):
            raise answer
        if isinstance(answer, Failed):
            # `ask` lets a command's own failure through — that is what it is for —
            # so a caller that treats the exit code as an answer has to be able to
            # be handed one that means "no", and one that means "I could not".
            return done(answer.said, rc=answer.code)
        if answer is None:
            return done("", rc=1)
        return done(answer, rc=0 if answer else 1)

    def boot_time(self):
        """Through `run`, and through the real parser, like the guest's own.

        A fake that answered a number of its own would hide both a machine that
        cannot be asked and a `kern.boottime` whose shape changed.
        """
        return parse_boot_time(self.run("sysctl -n kern.boottime", "reading the guest's boot time").stdout)

    def copy_in(self, local, remote, step, seconds=None):
        self.copied.append((Path(local).name, remote))


class Machine:
    """Everything a check asks of a machine, with a clock that only moves when it sleeps."""

    def __init__(self, answers=None):
        self.name = "udeck-e2e-probe"
        self.ssh = Guest(answers)
        self.now = 0.0
        self.shots = []
        self.clicks = []
        self.right_clicks = []
        self.keys = []
        self.pointer = []
        self.screenshot_fails = None
        # Which step's screenshot fails; None means every one of them.
        self.screenshot_fails_at = None
        self.click_fails = None

    def clock(self):
        return self.now

    def sleep(self, seconds):
        self.now += seconds

    def screenshot(self, directory, step):
        if self.screenshot_fails is not None and self.screenshot_fails_at in (None, step):
            raise self.screenshot_fails
        self.shots.append(step)
        return Path(directory) / f"{step}.png"

    def click(self, x, y, step):
        if self.click_fails is not None:
            raise self.click_fails
        self.clicks.append((x, y, step))

    def right_click(self, x, y, step):
        if self.click_fails is not None:
            raise self.click_fails
        self.right_clicks.append((x, y, step))

    def key(self, name, step):
        # The name as vncdotool takes it, and the step, because a keystroke names
        # no place: which key was pressed is all a test can read back about it.
        self.keys.append((name, step))

    def move_pointer(self, x, y, step):
        self.pointer.append((x, y, step))


class FakeBuild:
    """A build as a check sees it: a zip on disk that nothing here ever opens."""

    def __init__(self, directory, version, number):
        self.zip = directory / f"uDeck-{version}.zip"
        self.zip.write_bytes(b"x" * 16)
        self.version, self.build_number = version, number


class Builder:
    def __init__(self, directory):
        self.directory = directory

    def build(self, version, number):
        return FakeBuild(self.directory, version, number)


class Lab:
    """The run, as a check sees it."""

    def __init__(self, tmp_path):
        self.notes = []
        # A checkout of its own: nothing here may reach the real one, the way
        # `test_make_app` is the only test allowed to (see its own guard).
        self.repo_root = tmp_path / "repo"
        self.signing_key = SigningKey(tmp_path / "sparkle-key", "public-key")
        self.builders = []
        self._tmp = tmp_path

    def note(self, text):
        self.notes.append(text)

    def builder(self, feed_url, for_check, release_key=None):
        self.builders.append((feed_url, for_check) if release_key is None else (feed_url, for_check, release_key))
        directory = self._tmp / "builds" / for_check
        directory.mkdir(parents=True, exist_ok=True)
        return Builder(directory)


def wobble_output(rows, steps=None, pace=None, start_x=None, sideways=None):
    """What the guest's push script prints after a wobble that went where it was sent.

    Up to the upper row on every even report and back to the lower one on every
    odd one, sliding right by the lab's step, one reading per report and the time
    since the push began — the shape `push-pointer.py` prints, so the lab's own
    reading of it (`panel.Wobble`) is what the tests go through. Each argument
    left out is the lab's own number.
    """
    upper, lower = rows
    steps = config.WOBBLE_STEPS if steps is None else steps
    pace = config.WOBBLE_PAUSE_SECONDS if pace is None else pace
    start_x = config.WOBBLE_START_X if start_x is None else start_x
    sideways = config.WOBBLE_SIDEWAYS if sideways is None else sideways
    track = [
        [start_x + (n + 1) * sideways, upper if n % 2 == 0 else lower, round((n + 1) * pace, 3)]
        for n in range(steps)
    ]
    return json.dumps({"uid": 501, "euid": 501, "push": ["KERN_SUCCESS"], "track": track})


def throw_output(began=(1280.0, 720.0), thrown=12, at=(1280.0, 0.0), pinned=True):
    """What the guest's push script prints after a throw with no push after it.

    By default the throw as it goes: from the middle of the screen, where the lab
    parks the pointer, to the top row in the twelve reports of sixty that takes,
    and stopped there — nothing posted after it, so no push and no track.
    """
    return json.dumps({
        "uid": 501, "euid": 501, "throw": ["KERN_SUCCESS"], "push": [], "thrown": thrown,
        "from": list(began) if began is not None else None, "at": list(at) if at is not None else None,
        "pinned": pinned, "track": [],
    })  # fmt: skip


# --- GitHub, made of answers ------------------------------------------------------------

API = f"{config.GITHUB_API}/repos/{config.RELEASES_REPOSITORY}/releases"
DOWNLOAD = f"https://github.com/{config.RELEASES_REPOSITORY}/releases/download"


class Key:
    """A release key of the test's own: what GitHub's secret is to the real releases."""

    def __init__(self):
        self.private = Ed25519PrivateKey.generate()
        raw = self.private.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
        self.public = base64.b64encode(raw).decode()

    def sign(self, data):
        return base64.b64encode(self.private.sign(data)).decode()


def a_zip(version, build, key, identifier="place.unicorns.udeck", feed=config.LATEST_FEED, plist_version=None):
    plist = {
        "CFBundleIdentifier": identifier,
        "CFBundleShortVersionString": plist_version or version,
        "CFBundleVersion": build,
        "SUFeedURL": feed,
        "SUPublicEDKey": key.public,
    }
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w") as archive:
        archive.writestr("uDeck.app/Contents/Info.plist", plistlib.dumps(plist))
        archive.writestr("uDeck.app/Contents/MacOS/uDeck", b"\xcf\xfa\xed\xfe" + version.encode() * 100)
    return buffer.getvalue()


def an_appcast(version, build, data, signature, length=None, name=None, url=None):
    """The appcast the release workflow publishes; `url` is where its item sends uDeck, the release's own zip unless given."""
    name = name or f"uDeck-{version}.zip"
    url = url if url is not None else f"{DOWNLOAD}/v{version}/{name}"
    return f"""<?xml version="1.0" standalone="yes"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
    <channel>
        <title>uDeck</title>
        <item>
            <title>{version}</title>
            <sparkle:version>{build}</sparkle:version>
            <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
            <enclosure url={quoteattr(url)} length="{length if length is not None else len(data)}" type="application/octet-stream" sparkle:edSignature="{signature}"/>
        </item>
    </channel>
</rss>""".encode()


def a_release(version, assets=("appcast.xml", "zip"), draft=False, prerelease=False, size=1, zip_data=None, appcast=None):
    """A release as GitHub's API lists it. Given the bytes of an asset, its size and digest are theirs, as GitHub
    lists them (measured 2026-10-09: `"digest": "sha256:<hex>"` on every asset); otherwise `size`, and no digest."""
    names = [f"uDeck-{version}.zip" if a == "zip" else a for a in assets]
    data = {f"uDeck-{version}.zip": zip_data, "appcast.xml": appcast}

    def asset(name):
        listed = {"name": name, "browser_download_url": f"{DOWNLOAD}/v{version}/{name}", "size": size}
        if data.get(name) is not None:
            listed["size"] = len(data[name])
            listed["digest"] = "sha256:" + hashlib.sha256(data[name]).hexdigest()
        return listed

    return {"tag_name": f"v{version}", "draft": draft, "prerelease": prerelease, "assets": [asset(n) for n in names]}


class Web:
    """GitHub as a table of answers, and a record of every question."""

    def __init__(self):
        self.answers = {}
        self.asked = []

    def json(self, url, value, status=200, headers=None):
        self.answers[url] = Answer(status, headers or {}, json.dumps(value).encode())

    def file(self, url, body, status=200):
        self.answers[url] = Answer(status, {}, body)

    def __call__(self, url, headers):
        self.asked.append(url)
        answer = self.answers.get(url)
        if answer is None:
            raise ReleaseError(f"{url} did not answer this Mac: [Errno 8] nodename nor servname provided")
        if isinstance(answer, BaseException):
            raise answer
        return answer


class GitHubAsOn20261009:
    """The releases as GitHub listed them on 2026-10-09 — every one with both assets — made and signed here."""

    VERSIONS = [("0.1.0", "1"), ("0.2.1", "3"), ("0.3.0", "4"), ("0.4.0", "5"), ("0.5.0", "6"), ("0.6.1", "8")]

    def __init__(self, latest="0.6.1"):
        self.web = Web()
        self.key = Key()
        self.zips = {}
        listed = []
        for version, build in self.VERSIONS:
            data = a_zip(version, build, self.key)
            self.zips[version] = data
            appcast = an_appcast(version, build, data, self.key.sign(data))
            listed.append(a_release(version, zip_data=data, appcast=appcast))
            self.web.file(f"{DOWNLOAD}/v{version}/uDeck-{version}.zip", data)
            self.web.file(f"{DOWNLOAD}/v{version}/appcast.xml", appcast)
        # Newest first, as the API lists them.
        self.web.json(f"{API}?per_page=100", list(reversed(listed)))
        self.web.json(f"{API}/latest", {"tag_name": f"v{latest}"})

    def publish(self, version, data=None, appcast=None):
        """`version`'s assets published again — new bytes served, and the API listing their sizes and digests, as
        GitHub does when an asset is replaced. What is not given stays as it was."""
        name = f"uDeck-{version}.zip"
        if data is not None:
            self.zips[version] = data
            self.web.file(f"{DOWNLOAD}/v{version}/{name}", data)
        if appcast is not None:
            self.web.file(f"{DOWNLOAD}/v{version}/appcast.xml", appcast)
        listed = json.loads(self.web.answers[f"{API}?per_page=100"].body)
        for item in listed:
            if item["tag_name"] != f"v{version}":
                continue
            for asset in item["assets"]:
                body = self.web.answers[f"{DOWNLOAD}/v{version}/{asset['name']}"].body
                asset["size"] = len(body)
                asset["digest"] = "sha256:" + hashlib.sha256(body).hexdigest()
        self.web.json(f"{API}?per_page=100", listed)
