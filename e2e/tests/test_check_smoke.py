"""The smoke against the real GitHub: what it asks, where it runs, and the words it waits for."""

import importlib.util
import json
import re
import sys
from pathlib import Path

import pytest
from fakes import Lab, Machine

from udeck_e2e import app, config, panel, releases, smoke, targets, ui
from udeck_e2e.errors import CheckFailed, LabError, NotThere


def _load():
    path = Path(__file__).resolve().parents[1] / "checks" / "check_smoke.py"
    spec = importlib.util.spec_from_file_location("check_smoke_under_test", path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


checks = _load()


def _source(*parts):
    return (Path(__file__).resolve().parents[2].joinpath(*parts)).read_text()


def test_it_runs_only_when_named_and_takes_the_pull_request():
    assert smoke.what_it_takes(checks.check_real_pull_request) == smoke.PULL_REQUEST_OPTION
    assert smoke.what_it_takes(lambda: None) is None
    assert smoke.REAL_PULL_REQUEST == "smoke.real-pull-request"


@pytest.mark.parametrize(
    "link, number",
    [
        ("github.com/iillyyaa1997/udeck-plugins/pull/5", 5),
        ("https://github.com/iillyyaa1997/udeck-plugins/pull/12/files", 12),
        ("https://www.github.com/IILLYYAA1997/udeck-plugins/pull/3", 3),
        ("github.com/someone/udeck-plugins/pull/5", None),
        ("github.com/iillyyaa1997/udeck-plugins/tree/fix", None),
        ("github.com/iillyyaa1997/udeck-plugins/pull/0", None),
        ("gitlab.com/iillyyaa1997/udeck-plugins/pull/5", None),
    ],
)
def test_the_pull_request_is_the_official_repositorys(link, number):
    assert smoke.pull_request(link, config.PLUGINS_REPOSITORY) == number


def test_on_a_guest_on_this_mac_it_asks_github_nothing(tmp_path):
    """A Tart guest's GitHub is the operator's address: the smoke runs on a runner only, before anything."""
    lab = Lab(tmp_path)
    lab.pull_request = "github.com/iillyyaa1997/udeck-plugins/pull/5"
    machine = Machine()
    with pytest.raises(LabError, match="only on a GitHub runner"):
        checks.check_real_pull_request(machine, tmp_path, lab)
    assert machine.ssh.commands == [] and lab.builders == []


def test_the_words_the_smoke_waits_for_are_uDecks_own():
    english = _source("Sources", "UDeckCore", "Localization", "English.swift")
    assert f'case .pluginMarkUnverified: "{checks.UNVERIFIED}"' in english
    assert '"' + checks.FROM_THE_PULL_REQUEST.format(number="\\(number)", commit="\\(commit)") + '"' in english
    assert '"' + checks.CLOSED_UNMERGED.format(number="\\(number)") + '"' in english
    swift = _source("Tests", "UDeckCoreTests", "InstallFromLinkTests.swift")
    assert f'== "{checks.LINK_HEAD.format(number=3, commit="a1b2c3d")}"' in swift
    # The catalogue row: catalogueInstalledUnverified with line(_), then what became of the pull request after " — ",
    # as the Swift tests hold the whole row of one merged with changes.
    installed, closed = checks.CLOSED_IN_THE_CATALOGUE.format(number=3).split(" — ")
    assert 'case .catalogueInstalledUnverified(let ref, let fork): "Installed here from \\(Self.line(ref, fork: fork)): unverified"' in english
    assert 'said = "pull request #\\(number)"' in english
    assert installed == "Installed here from pull request #3: unverified"
    assert f'case .catalogueClosedUnmerged: "{closed}"' in english
    adoption = re.sub(r'"\s*\+\s*"', "", _source("Tests", "UDeckCoreTests", "AdoptionTests.swift"))
    assert f'#expect(line == "{installed} — merged, and the verified version differs — uptime is not in ~/.udeck/plugins")' in adoption


def test_the_smoke_has_its_row_in_the_specifications_table():
    table = _source("docs", "plugin-repository.md").split("### The lab's checks", 1)[1].split("\n### ", 1)[0]
    rows = [line.split("`")[1] for line in table.splitlines() if line.startswith("| `smoke.")]
    assert rows == [smoke.REAL_PULL_REQUEST]


# --- The walk on a runner, against GitHub and a uDeck made of answers ------------------------------------------------

NUMBER = 3
HEAD = "e1f5c5c" + "4" * 33
BRANCH = "smoke/stage3-1"
LINK = f"https://github.com/{config.PLUGINS_REPOSITORY}/pull/{NUMBER}"
REPOSITORY = f"{config.GITHUB_API}/repos/{config.PLUGINS_REPOSITORY}"


class RealPullRequest:
    """GitHub as the smoke asks it, and uDeck as it answers the smoke's presses, on the machine's clock.

    As run 38967398779 met them unless a test says otherwise: a pull request open at `HEAD`, changing `uptime`'s
    manifest and the README, closed unmerged `closes_after` seconds after uDeck installed from it — None: never —
    and its branch deleted with it; uDeck's rows saying what uDeck says (English.swift), and `installed.json`
    holding the record an install from a pull request writes — `written` changes it, `rewritten` changes it again
    at Check now. A press on a control that is not on the screen is refused, as `ui.click` refuses it.
    """

    def __init__(self, machine, closes_after=40, merged=False, moved_to=None, open_at_start=True, left=(43,),
                 files=("plugins/uptime/manifest.json", "README.md"), branch_deleted=True, row_says=None,
                 catalogue_says=None, verification=None, listed=True, sheet_says=None, offers="uptime",
                 mark_says="Unverified", from_says=None, writes_record=True, written=None, rewritten=None):  # fmt: skip
        self.machine = machine
        self.closes_after, self.merged, self.moved_to, self.open_at_start = closes_after, merged, moved_to, open_at_start
        self.left, self.files, self.branch_deleted = list(left), files, branch_deleted
        self.row_says, self.catalogue_says = row_says, catalogue_says
        self.verification = verification or {"status": "unverified", "by": None, "checkedAgainst": HEAD,
                                             "checkedAt": "2026-10-16T21:14:11Z"}  # fmt: skip
        self.listed, self.offers = listed, offers
        self.sheet_says = sheet_says or f"Pull request #{NUMBER} at {HEAD[:7]}"
        self.mark_says, self.from_says = mark_says, from_says or f"pull request #{NUMBER} at {HEAD[:7]}"
        self.writes_record, self.written, self.rewritten = writes_record, written or {}, rewritten
        self.record = None
        self.asked = []
        self.presses = []
        self.typed = ""
        self.sheet = self.looked_up = False
        self.installed_at = None
        self.checked_now = None

    # GitHub
    def closed(self):
        if not self.open_at_start:
            return True
        return self.installed_at is not None and self.closes_after is not None and \
            self.machine.now >= self.installed_at + self.closes_after

    def get(self, url, headers, seconds=None, environ=None):
        self.asked.append((url, "token" if environ is None else "no token"))
        if url == f"{REPOSITORY}/pulls/{NUMBER}":
            closed = self.closed()
            head = self.moved_to if closed and self.moved_to else HEAD
            return self._json({"number": NUMBER, "state": "closed" if closed else "open", "merged": closed and self.merged,
                               "head": {"sha": head, "ref": BRANCH}, "closed_at": "2026-10-16T21:18:40Z" if closed else None})
        if url == f"{REPOSITORY}/pulls/{NUMBER}/files?per_page=100":
            return self._json([{"filename": name} for name in self.files])
        if url == f"{config.GITHUB_API}/rate_limit":
            left = self.left.pop(0) if len(self.left) > 1 else self.left[0]
            return self._json({"resources": {"core": {"limit": 60, "remaining": left}}})
        if url == f"{REPOSITORY}/git/ref/heads/{BRANCH}":
            return releases.Answer(404 if self.closed() and self.branch_deleted else 200, {}, b"{}")
        raise AssertionError(f"the smoke asked GitHub {url}, which run 38967398779 never asked")

    @staticmethod
    def _json(value):
        return releases.Answer(200, {}, json.dumps(value).encode())

    # uDeck
    def identified(self, machine, step, window=ui.SETTINGS_WINDOW, depth=ui.IDENTIFIED_DEPTH):
        rows = [("AXButton", "plugins.installFromLink", "Install from a link…", ""),
                ("AXButton", "catalogue.checkNow", "Check now", "")]  # fmt: skip
        if self.listed:
            rows.append(("AXButton", "catalogue.uptime.install", "Install", ""))
        if self.sheet:
            rows += [("AXTextField", "link.field", "", self.typed), ("AXButton", "link.lookUp", "Look up", ""),
                     ("AXButton", "link.close", "Close", "")]  # fmt: skip
            if self.looked_up:
                rows += [("AXStaticText", "link.head", "", self.sheet_says),
                         ("AXButton", f"link.{self.offers}.install", "Install", "")]  # fmt: skip
        if self.installed_at is not None:
            rows += [("AXStaticText", "plugin.uptime.mark", "", self.mark_says),
                     ("AXStaticText", "plugin.uptime.from", "", self.from_says)]  # fmt: skip
            state = f"Installed here from pull request #{NUMBER}: unverified"
            if self.checked_now:
                said = self.row_says or f"Pull request #{NUMBER} was closed without being merged; the plugin keeps running"
                rows.append(("AXStaticText", "plugin.uptime.pullRequest", "", said))
                state = self.catalogue_says or f"{state} — closed without being merged"
            rows.append(("AXStaticText", "catalogue.uptime.state", "", state))
        return "\n".join(f"4|{role}||{identifier}|{title}|{value}||100;{100 + 30 * n};|200;20;"
                         for n, (role, identifier, title, value) in enumerate(rows))  # fmt: skip

    def click(self, machine, identifier, step, window=ui.SETTINGS_WINDOW):
        if ui.element(self.identified(machine, step, window), identifier) is None:
            raise NotThere(step, f"{identifier} is not on the screen")
        self.presses.append(identifier)
        if identifier == "plugins.installFromLink":
            self.sheet = True
        elif identifier == "link.lookUp":
            self.looked_up = self.typed == LINK
        elif identifier == "link.uptime.install":
            self.installed_at = machine.now
            if self.writes_record:
                self._write({"source": "official", "ref": {"kind": "pr", "name": str(NUMBER)}, "commit": HEAD,
                             "repository": {"provider": "github", "host": "github.com", "path": config.PLUGINS_REPOSITORY},
                             "tree": "c911345", "version": "1.0.1", "installedAt": "2026-10-16T21:14:11Z", "pinned": False,
                             "verification": self.verification, "previous": None, **self.written})  # fmt: skip
        elif identifier == "link.close":
            self.sheet = self.looked_up = False
        elif identifier == "catalogue.checkNow":
            self.checked_now = self.closed()
            if self.rewritten and self.record is not None:
                self._write({**self.record, **self.rewritten})
        return ui.Element(identifier, 100, 100, 200, 20)

    def _write(self, record):
        self.record = record
        self.machine.ssh.answers["cat ~/.udeck/installed.json"] = json.dumps({"plugins": {"uptime": record}})

    def wait_for(self, machine, identifier, step, window=ui.SETTINGS_WINDOW, **_):
        return ui.Element(identifier, 100, 100, 200, 20)

    def type_text(self, machine, text, step):
        self.typed = text


class _Log:
    """uDeck's own account, which the smoke only keeps beside its report."""

    def __init__(self, machine, note):
        pass

    def keep(self, step):
        pass

    def mark(self, step):
        return "2026-10-16 21:13:22"

    def collect(self, directory, mark, step, name="gesture.log"):
        return ""


def _run_the_smoke(tmp_path, monkeypatch, **scene):
    machine = Machine()
    world = RealPullRequest(machine, **scene)
    for module, name, value in ((releases, "get", world.get), (ui, "identified", world.identified), (ui, "click", world.click),
                                (ui, "wait_for", world.wait_for), (ui, "type_text", world.type_text),
                                (ui, "plugins_pane", lambda machine, step, language=None: None),
                                (app, "install", lambda machine, archive, note: None),
                                (app, "launch", lambda machine, step="starting uDeck": set()), (panel, "GestureLog", _Log)):  # fmt: skip
        monkeypatch.setattr(module, name, value)
    lab = Lab(tmp_path)
    lab.target = targets.HERE
    lab.pull_request = LINK
    check_dir = tmp_path / smoke.REAL_PULL_REQUEST
    check_dir.mkdir()
    return machine, world, lab, check_dir


def test_on_a_runner_a_pull_request_installed_says_unverified_and_closed_says_so(tmp_path, monkeypatch):
    """The whole walk as run 38967398779 went: GitHub asked first, a build keeping github.com, the sheet, the record,
    the Unverified row; Check now pressed only once GitHub said the pull request was closed, and the rows read then."""
    machine, world, lab, check_dir = _run_the_smoke(tmp_path, monkeypatch)
    checks.check_real_pull_request(machine, check_dir, lab)
    assert lab.real_plugin_builds == [smoke.REAL_PULL_REQUEST]
    assert world.presses == ["plugins.installFromLink", "link.lookUp", "link.uptime.install", "link.close", "catalogue.checkNow"]
    assert world.checked_now is True and machine.now >= world.installed_at + world.closes_after
    assert machine.shots[:3] == ["the-catalogue-from-github", "the-link-sheet", "unverified"]
    assert machine.shots[3:] == ["closed-without-being-merged", "the catalogue row of the closed pull request"]
    # The pull request asked with the job's token; what is left to the address, without one.
    assert {asked for url, asked in world.asked if url.endswith("/rate_limit")} == {"no token"}
    assert {asked for url, asked in world.asked if "/pulls/" in url} == {"token"}
    assert [line.split(":")[0] for line in (check_dir / "rate-limit.txt").read_text().splitlines()] == ["before", "at the end"]
    assert json.loads((check_dir / "pull-request-closed.json").read_text())["state"] == "closed"
    assert json.loads((check_dir / "installed.json").read_text())["plugins"]["uptime"]["ref"] == {"kind": "pr", "name": "3"}
    assert any(f"closed at 2026-10-16T21:18:40Z; branch {BRANCH} deleted" in note for note in lab.notes)


def test_a_pull_request_closed_before_uDeck_could_notice_could_not_check(tmp_path, monkeypatch):
    """Closed by the time the install was made, Check now would read what Look up had heard already: not a question
    this run can answer — and Check now is never pressed."""
    machine, world, lab, check_dir = _run_the_smoke(tmp_path, monkeypatch, closes_after=0)
    with pytest.raises(LabError, match="its closing is not left for uDeck to notice"):
        checks.check_real_pull_request(machine, check_dir, lab)
    assert "catalogue.checkNow" not in world.presses


@pytest.mark.parametrize(
    "scene, said",
    [
        ({"merged": True}, "was merged, not closed unmerged"),
        ({"moved_to": "f" * 40}, f"moved to {'f' * 40} before it was closed"),
        ({"closes_after": None}, f"was still open after {checks.CLOSE_SECONDS}s"),
    ],
)
def test_a_pull_request_that_was_not_closed_unmerged_at_its_head_could_not_check(tmp_path, monkeypatch, scene, said):
    machine, world, lab, check_dir = _run_the_smoke(tmp_path, monkeypatch, **scene)
    with pytest.raises(LabError, match=re.escape(said)):
        checks.check_real_pull_request(machine, check_dir, lab)
    assert "catalogue.checkNow" not in world.presses


def test_a_branch_left_after_the_closing_is_said_and_the_rows_still_read(tmp_path, monkeypatch):
    machine, world, lab, check_dir = _run_the_smoke(tmp_path, monkeypatch, branch_deleted=False)
    checks.check_real_pull_request(machine, check_dir, lab)
    assert any(f"branch {BRANCH} still there after {checks.BRANCH_SECONDS}s" in note for note in lab.notes)


VERIFIED = {"status": "verified", "by": "official", "checkedAgainst": HEAD, "checkedAt": "2026-10-16T21:19:30Z"}


@pytest.mark.parametrize(
    "scene, said, closed",
    [
        # Before the closing: the catalogue, the link sheet, the record the install writes, the row.
        ({"listed": False}, "uDeck lists no uptime from github.com", False),
        ({"sheet_says": f"Pull request #{NUMBER} at fffffff"}, f"the link sheet says 'Pull request #{NUMBER} at fffffff'", False),
        ({"sheet_says": f"Pull request #4 at {HEAD[:7]}"}, "the link sheet says 'Pull request #4", False),
        ({"offers": "clock"}, "offers ['link.clock.install'], not uptime", False),
        ({"writes_record": False}, f"put no record of pull request #{NUMBER}", False),
        ({"written": {"ref": {"kind": "branch", "name": BRANCH}}}, f"put no record of pull request #{NUMBER}", False),
        ({"written": {"ref": {"kind": "pr", "name": "4"}}}, "installed.json says {'ref': {'kind': 'pr', 'name': '4'}}", False),
        ({"written": {"commit": "f" * 40}}, f"installed.json says {{'commit': '{'f' * 40}'}}", False),
        ({"written": {"source": "trusted"}}, "installed.json says {'source': 'trusted'}", False),
        ({"verification": {**VERIFIED, "checkedAt": "2026-10-16T21:14:11Z"}}, "unverified, by nobody", False),
        ({"mark_says": "Verified"}, "uptime's row says 'Verified' ·", False),
        ({"from_says": f"branch {BRANCH} at {HEAD[:7]}"}, f"uptime's row says 'Unverified' · 'branch {BRANCH}", False),
        # After Check now: the row, the catalogue row, the record.
        ({"row_says": f"Pull request #{NUMBER} at {HEAD[:7]}"}, "uptime's row says", True),
        ({"catalogue_says": f"Installed here from pull request #{NUMBER}: unverified"}, "uptime's catalogue row says", True),
        ({"rewritten": {"ref": {"kind": "default", "name": "main"}}}, "closing the pull request changed uptime's record", True),
        ({"rewritten": {"verification": VERIFIED}}, "closing the pull request changed uptime's record", True),
    ],
)
def test_uDeck_saying_anything_else_is_red(tmp_path, monkeypatch, scene, said, closed):
    """What the catalogue lists, the link sheet, the record the install writes and the row before the closing; the
    row after Check now, the catalogue row, and the record then: uDeck's to get right."""
    machine, world, lab, check_dir = _run_the_smoke(tmp_path, monkeypatch, **scene)
    with pytest.raises(CheckFailed, match=re.escape(said)):
        checks.check_real_pull_request(machine, check_dir, lab)
    assert ("catalogue.checkNow" in world.presses) == closed


@pytest.mark.parametrize(
    "scene",
    [
        {"left": (checks.REQUESTS_NEEDED,)},
        # uDeck finding the same again after Check now, at a later time.
        {"rewritten": {"verification": {"status": "unverified", "by": None, "checkedAgainst": HEAD,
                                        "checkedAt": "2026-10-16T21:19:30Z"}}},  # fmt: skip
    ],
)
def test_what_the_walk_takes_as_it_is(tmp_path, monkeypatch, scene):
    """Exactly the requests it needs is enough, and a record looked at again is not a record changed."""
    machine, world, lab, check_dir = _run_the_smoke(tmp_path, monkeypatch, **scene)
    checks.check_real_pull_request(machine, check_dir, lab)
    assert world.presses[-1] == "catalogue.checkNow"


@pytest.mark.parametrize(
    "scene, said",
    [
        ({"row_says": f"Pull request #{NUMBER} at {HEAD[:7]}"}, "the address's hour was spent by then"),
        ({"listed": False}, "the address's hour was spent: ''"),
    ],
)
def test_the_hour_spent_when_uDeck_did_not_say_it_could_not_check(tmp_path, monkeypatch, scene, said):
    """The row not saying it, or the catalogue listing nothing, with nothing left to the address by then, is the
    address's: could not check."""
    machine, world, lab, check_dir = _run_the_smoke(tmp_path, monkeypatch, left=(43, 0), **scene)
    with pytest.raises(LabError, match=re.escape(said)):
        checks.check_real_pull_request(machine, check_dir, lab)


@pytest.mark.parametrize(
    "scene, said",
    [
        ({"open_at_start": False}, "is 'closed', not open"),
        ({"files": ("plugins/uptime/manifest.json", "plugins/clock/manifest.json")}, "this check installs one"),
        ({"files": ("README.md",)}, "this check installs one"),
        ({"left": (checks.REQUESTS_NEEDED - 1,)}, "what it was refused would be the address's"),
    ],
)
def test_what_github_says_before_anything_is_built_can_refuse_the_run(tmp_path, monkeypatch, scene, said):
    """A pull request that is not one open change of one plugin, or an address without the requests uDeck needs:
    could not check, before a build is made or uDeck started."""
    machine, world, lab, check_dir = _run_the_smoke(tmp_path, monkeypatch, **scene)
    with pytest.raises(LabError, match=re.escape(said)):
        checks.check_real_pull_request(machine, check_dir, lab)
    assert lab.builders == [] and world.presses == [] and machine.ssh.commands == []
