"""uDeck against the real GitHub: a check that runs only when it is named.

One check, `smoke.real-pull-request`, and it is the only check whose lab build
keeps the plugin catalogue's shipped addresses (`builds.Builder`,
`real_plugins`), so that its uDeck reads plugins from `api.github.com` and
`raw.githubusercontent.com` itself, anonymous, from the address of the GitHub
runner it runs on. (A published release an update check installs reads the
catalogue from GitHub too, and no check reads what it got.) Everything it
asks of uDeck the plugin checks ask of a fake GitHub with an access log; what
this one adds is GitHub itself answering: a pull request it serves, its head,
its listing and its files, and the state it says the pull request is in once
somebody has closed it.

So it is never part of a run that did not name it (`smoke`), it takes the pull
request it is about as `--pull-request <link>`, and it waits — up to
`CLOSE_SECONDS` — for a person, or the session that opened it, to close that
pull request without merging it and delete its branch. Its oracles are uDeck's
screens, read through the accessibility API by the identifiers the plugin
checks read, and `~/.udeck/installed.json`; GitHub itself, asked by the lab
with the job's read-only token, says what the pull request is, which plugin it
changes and when it was closed.
"""

import hashlib
import json
import os
import shlex
import stat
import time

from udeck_e2e import app, config, panel, releases, smoke, targets, ui, updates
from udeck_e2e.errors import CheckFailed, LabError, NotThere, expect

VERSION = ("0.4.1", "6")

UDECK_HOME = "~/.udeck"
INSTALLED = f"{UDECK_HOME}/installed.json"

# The official catalogue, read from github.com a few seconds after uDeck starts; a minute is the spec's own number.
CATALOGUE_SECONDS = 60
# From a press to the thing it does: GitHub's own hosts, from a runner.
OPERATION_SECONDS = 60
# How long the check waits for the pull request to be closed, asking GitHub every `CLOSE_POLL_SECONDS`.
CLOSE_SECONDS = 30 * 60
CLOSE_POLL_SECONDS = 15
# And for its branch to be deleted after that.
BRANCH_SECONDS = 5 * 60
# How many of the address's sixty an hour the check needs uDeck to have: the read at launch, Look up, and Check now
# — commits, a listing, the pull request, twice over — with room.
REQUESTS_NEEDED = 15

# What uDeck says (English.swift: pluginMarkUnverified, pluginFromPullRequest, linkHead, pluginPullRequestClosed,
# catalogueInstalledUnverified, catalogueClosedUnmerged).
UNVERIFIED = "Unverified"
FROM_THE_PULL_REQUEST = "pull request #{number} at {commit}"
LINK_HEAD = "Pull request #{number} at {commit}"
CLOSED_UNMERGED = "Pull request #{number} was closed without being merged; the plugin keeps running"
CLOSED_IN_THE_CATALOGUE = "Installed here from pull request #{number}: unverified — closed without being merged"


@smoke.only_when_named(smoke.PULL_REQUEST_OPTION)
def check_real_pull_request(machine, check_dir, lab):
    """A plugin installed from a draft pull request on github.com says Unverified; closed unmerged, its row says so.

    The pull request is `--pull-request`'s, of the official repository, open, and
    changing one plugin's folder — its head is what uDeck installs. First GitHub
    is asked, by the lab with the job's token, what the pull request is, and,
    without a token, how many of the hour's sixty requests the runner's address
    has left: fewer than `REQUESTS_NEEDED` and the check could not check, for no
    reason of uDeck's.

    Then a lab build that keeps GitHub's own addresses, installed and started
    afresh: its catalogue read from github.com lists the plugin; the link typed
    into **Install from a link…** and looked up, the sheet says *Pull request #N
    at <head>*, and **Install** on the plugin puts in `installed.json` a record of
    `ref {pr, "N"}` at the head, `unverified`, by nobody, and its row says
    **Unverified** · *pull request #N at <head>*. Screenshots of both.

    Then it waits for the pull request to be closed without being merged and its
    branch deleted, asking GitHub every fifteen seconds; **Check now**; and the
    plugin's row says *Pull request #N was closed without being merged; the plugin
    keeps running*, the catalogue row *Installed here from pull request #N:
    unverified — closed without being merged*, and the record is as it was.

    **Red for** a pull request read wrong from GitHub — another head, no plugin
    listed — a copy recorded as anything but the pull request's and unverified,
    and a closing GitHub says that uDeck does not. A pull request merged, or
    closed before the install, is not this check's question: could not check.
    """
    if lab.target != targets.HERE:
        raise LabError(
            "asking the real GitHub",
            "this check asks github.com from the machine uDeck runs on, and the lab does that only on a GitHub runner "
            "(--target here) — never from a guest on this Mac, whose address is the operator's",
        )
    number = smoke.pull_request(lab.pull_request or "", config.PLUGINS_REPOSITORY)
    if number is None:
        raise LabError("reading --pull-request", f"{lab.pull_request!r} is not a pull request of {config.PLUGINS_REPOSITORY}")
    api = f"{config.GITHUB_API}/repos/{config.PLUGINS_REPOSITORY}"
    pull = _github(f"{api}/pulls/{number}", f"asking GitHub about pull request #{number}")
    _keep(check_dir, "pull-request-before.json", pull)
    if pull.get("state") != "open":
        raise LabError("asking GitHub about the pull request", f"pull request #{number} is {pull.get('state')!r}, not open")
    head = str((pull.get("head") or {}).get("sha") or "")
    branch = str((pull.get("head") or {}).get("ref") or "")
    files = _github(f"{api}/pulls/{number}/files?per_page=100", f"asking GitHub which files pull request #{number} changes")
    plugins = sorted({str(f.get("filename", "")).split("/")[1] for f in files if str(f.get("filename", "")).startswith("plugins/")
                      and str(f.get("filename", "")).count("/") >= 2})  # fmt: skip
    if len(head) != 40 or len(plugins) != 1:
        raise LabError("asking GitHub about the pull request",
                       f"pull request #{number} is at {head!r} and changes the plugins {plugins}: this check installs one")
    plugin = plugins[0]
    left = _left_to_the_address(machine, check_dir, "before")
    if left < REQUESTS_NEEDED:
        raise LabError("asking GitHub how many requests this address has left",
                       f"{left} of the hour's sixty are left to the runner's address without a token, and uDeck needs "
                       f"about {REQUESTS_NEEDED} here: what it was refused would be the address's, not uDeck's")
    lab.note(f"   pull request #{number} at {head[:7]}, branch {branch}, plugin {plugin}; {left} requests left to the address")

    feed = updates.Feed(machine, lab.note)
    build = lab.builder(feed.url, check_dir.name, real_plugins=True).build(*VERSION)
    app.install(machine, build.zip, lab.note)
    machine.ssh.run(f"rm -rf {UDECK_HOME}", "starting uDeck with nothing of its own")
    log = panel.GestureLog(machine, lab.note)
    log.keep("asking the guest to keep uDeck's own account")
    mark = log.mark("marking the start")
    try:
        app.launch(machine)
        ui.plugins_pane(machine, "opening Settings → Plugins")
        listed = _wait_until(machine, f"catalogue.{plugin}.install", lambda said: said is not None, CATALOGUE_SECONDS, present=True)
        dump = _keep_the_pane(machine, check_dir, lab, "the-catalogue-from-github.txt")
        if listed is None:
            trouble = ui.says(ui.element(dump, "catalogue.trouble"))
            if _left_to_the_address(machine, check_dir, "after the catalogue") == 0:
                raise LabError("reading the catalogue from github.com", f"the address's hour was spent: {trouble!r}")
            raise CheckFailed(f"{CATALOGUE_SECONDS}s after it started, uDeck lists no {plugin} from github.com: "
                              f"{trouble or ui.says(ui.element(dump, 'catalogue.status'))!r}")

        link = lab.pull_request.strip()
        dump = _look_up(machine, check_dir, lab, link)
        said = ui.says(ui.element(dump, "link.head"))
        wanted = LINK_HEAD.format(number=number, commit=head[:7])
        expect(said == wanted, f"the link sheet says {said!r} of {link}, not {wanted!r}")
        offered = [row.identifier for row in ui.controls(dump) if row.identifier.startswith("link.") and row.identifier.endswith(".install")]
        expect(f"link.{plugin}.install" in offered, f"the link sheet of pull request #{number} offers {offered}, not {plugin}")
        _press(machine, f"link.{plugin}.install", f"installing {plugin} from pull request #{number}")
        record = _wait_for_the_record(machine, plugin, lambda r: (r.get("ref") or {}).get("kind") == "pr")
        expect(record is not None, f"Install on {plugin} put no record of pull request #{number} in installed.json: "
                                   f"{_read_json(machine, INSTALLED)!r}")
        _expect_the_pull_requests(record, number, head, plugin)
        _press(machine, "link.close", "closing the link sheet")
        machine.sleep(config.SETTLE_SECONDS)
        mark_said = _wait_until(machine, f"plugin.{plugin}.mark", lambda said: said == UNVERIFIED, OPERATION_SECONDS)
        dump = _keep_the_pane(machine, check_dir, lab, "unverified.txt")
        source = ui.says(ui.element(dump, f"plugin.{plugin}.from"))
        wanted = FROM_THE_PULL_REQUEST.format(number=number, commit=head[:7])
        expect(mark_said == UNVERIFIED and source == wanted,
               f"{plugin}'s row says {mark_said!r} · {source!r}, not {UNVERIFIED!r} · {wanted!r}")
        # The closing has to come after this, or what Check now says of it is what Look up had heard already.
        still = _github(f"{api}/pulls/{number}", f"asking GitHub whether pull request #{number} is still open")
        if still.get("state") != "open":
            raise LabError("installing from the pull request",
                           f"pull request #{number} was {still.get('state')!r} by the time uDeck had installed from it: "
                           "its closing is not left for uDeck to notice")

        lab.note(f"   waiting for pull request #{number} to be closed without being merged and {branch} deleted")
        closed = _wait_for_the_closing(machine, api, number, head)
        _keep(check_dir, "pull-request-closed.json", closed)
        gone = _wait_for_the_branch_to_go(machine, api, branch)
        lab.note(f"   pull request #{number} closed at {closed.get('closed_at')}; branch {branch} "
                 + ("deleted" if gone else f"still there after {BRANCH_SECONDS}s"))

        ui.plugins_pane(machine, "opening Settings → Plugins after the pull request was closed")
        _press(machine, "catalogue.checkNow", "pressing Check now after the pull request was closed")
        wanted = CLOSED_UNMERGED.format(number=number)
        said = _wait_until(machine, f"plugin.{plugin}.pullRequest", lambda said: said == wanted, CATALOGUE_SECONDS)
        dump = _keep_the_pane(machine, check_dir, lab, "closed-without-being-merged.txt")
        if said != wanted and _left_to_the_address(machine, check_dir, "after Check now") == 0:
            raise LabError("asking GitHub through uDeck after the closing", "the address's hour was spent by then")
        expect(said == wanted, f"pull request #{number} was closed without being merged, and {plugin}'s row says {said!r}, "
                               f"not {wanted!r}")
        state = ui.says(ui.element(dump, f"catalogue.{plugin}.state"))
        wanted = CLOSED_IN_THE_CATALOGUE.format(number=number)
        expect(state == wanted, f"{plugin}'s catalogue row says {state!r}, not {wanted!r}")
        if getattr(machine, "scroll", None) is not None:
            ui.in_view(machine, f"catalogue.{plugin}.state", "bringing the catalogue row into view")
        machine.screenshot(check_dir, "the catalogue row of the closed pull request")
        after = ((_read_json(machine, INSTALLED) or {}).get("plugins") or {}).get(plugin) or {}
        expect({k: v for k, v in after.items() if k != "verification"} == {k: v for k, v in record.items() if k != "verification"}
               and (after.get("verification") or {}).get("status") == "unverified",
               f"closing the pull request changed {plugin}'s record: {after!r}")
        _left_to_the_address(machine, check_dir, "at the end")
    finally:
        log.collect(check_dir, mark, "collecting uDeck's own account", name="udeck.log")
        try:
            text = machine.ssh.ask(f"cat {INSTALLED} 2>/dev/null || true", "collecting installed.json").stdout
            if text:
                (check_dir / "installed.json").write_text(text)
        except (LabError, OSError):
            pass


# --- A real token (stage 4, R3c) -----------------------------------------------------------

# The public repository the token smoke adds as a source: the template one's own plugins start from, its number and
# its passport's name (measured 2026-11-13; S4-22).
TEMPLATE = "iillyyaa1997/udeck-plugins-template"
TEMPLATE_ID = 1412415366
TEMPLATE_NAME = "My uDeck plugins"
SOURCES = f"{UDECK_HOME}/sources.json"
SETTINGS = f"{UDECK_HOME}/settings.json"
# What GitHub allows an address without a token in an hour: a read with a token says more is left than that.
ANONYMOUS_HOURLY = 60
# The isolates a passport's name is shown inside (`SourceName`).
ISOLATES = ("\u2068", "\u2069")
# What `security find-generic-password` exits with when there is no such item (errSecItemNotFound).
NO_SUCH_ITEM = 44


def _the_token_file():
    """The file the lab's secret job wrote the job's token to, as `TOKEN_FILE_VARIABLE` names it: a regular file only
    its owner reads, holding something — or the lab could not check. Its value is never read here: uDeck is given it
    by `ui.enter_secret`, from the file."""
    step = "finding the job's token"
    named = os.environ.get(smoke.TOKEN_FILE_VARIABLE, "")
    if not named:
        raise LabError(step, f"{smoke.REAL_GITHUB_TOKEN} runs only in the lab workflow's secret job, which names the "
                             f"file it wrote the job's token to in {smoke.TOKEN_FILE_VARIABLE}")  # fmt: skip
    try:
        status = os.lstat(named)
    except OSError as error:
        raise LabError(step, f"{smoke.TOKEN_FILE_VARIABLE} names {named}, which cannot be read: {error}") from None
    if not stat.S_ISREG(status.st_mode) or status.st_mode & 0o077 or status.st_uid != os.getuid() or status.st_size == 0:
        raise LabError(step, f"{named} is not a non-empty file of this user's that only its owner reads "
                             f"(mode {stat.filemode(status.st_mode)})")  # fmt: skip
    return named


@smoke.only_when_named(secret=True)
def check_real_github_token(machine, check_dir, lab):
    """uDeck given a real token for a public repository of github.com, and reading it with it.

    The lab job's own github.token, which reads and nothing else, written by the job to a file only it reads. A lab
    build with GitHub's own addresses starts with iillyyaa1997/udeck-plugins-template listed as a source without a
    token and the official catalogue off — written into `~/.udeck` as **Add** writes them, since a runner's address
    often has none of the hour's sixty left to look anything up without a token (run 43511904754). The token is typed
    under **Token…** from the file, the focus proven on the secure field, never in an argument; the check of it and
    every read after go with the token alone. Kept, the source is read with it: `sources.json` says `access: token`,
    a read succeeds after it was kept, its block is named *My uDeck plugins*, and its `state.json` says GitHub left it
    more of the hour than the sixty an address has without one. **Forget the token**: `access: none`, and uDeck's
    Keychain item of tokens gone with its last token.

    It runs only in the secret job (`TOKEN_FILE_VARIABLE`), whose artifact is the report alone and which fails if the
    token's value is anywhere in the run's directory, and only on a GitHub runner; it takes no picture of the screen.

    **Red for**: a real token uDeck does not keep, does not read with, or keeps after Forget.
    """
    if lab.target != targets.HERE:
        raise LabError("asking the real GitHub with a token",
                       "this check gives uDeck a real token, and the lab does that only on a GitHub runner (--target here)")
    secret = _the_token_file()
    _left_to_the_address(machine, check_dir, "before")

    feed = updates.Feed(machine, lab.note)
    build = lab.builder(feed.url, check_dir.name, real_plugins=True).build(*VERSION)
    app.install(machine, build.zip, lab.note)
    sid = _source_id(TEMPLATE, TEMPLATE_ID)
    listed = {"version": 1, "sources": [{"id": sid, "provider": "github", "host": "github.com", "path": TEMPLATE,
                                         "remoteID": TEMPLATE_ID, "access": "none", "trustedAt": None,
                                         "addedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}]}
    step = "starting uDeck with the template as a source and the official catalogue off"
    machine.ssh.run(f"rm -rf {UDECK_HOME} && mkdir -p {UDECK_HOME} && "
                    f"printf %s {shlex.quote(json.dumps(listed, indent=2))} > {SOURCES} && "
                    f"printf %s {shlex.quote(json.dumps({'officialCatalogue': False}))} > {SETTINGS}", step)  # fmt: skip
    log = panel.GestureLog(machine, lab.note)
    log.keep("asking the guest to keep uDeck's own account")
    mark = log.mark("marking the start")
    try:
        app.launch(machine)
        ui.plugins_pane(machine, "opening Settings → Plugins")
        # The read at launch without a token, to its end — whatever the address had left — since Token… is not
        # offered while it runs; and when it last succeeded, if it did.
        state = f"{UDECK_HOME}/catalogue/{sid}/state.json"
        tried = _wait_for(machine, lambda: (_read_json(machine, state) or {}).get("lastAttempt"))
        if tried is None:
            # The lab's own sources.json refused — a format uDeck no longer reads — is the lab's problem, not uDeck's.
            dump = _keep_the_walk(machine, check_dir, lab, "the-template-not-read.txt")
            refused = ui.says(ui.element(dump, "sources.problem"))
            if refused:
                raise LabError("starting uDeck with the template written by hand", f"uDeck refused the lab's sources.json: {refused!r}")
        expect(tried is not None, f"uDeck did not read the template at launch: {_read_json(machine, state)!r}")
        anonymous = (_read_json(machine, state) or {}).get("lastSuccess")
        machine.sleep(1.1)  # the state's times are whole seconds: the next read's is another

        _open_token(machine, sid, "on the template")
        ui.enter_secret(machine, f"source.{sid}.token.tokenField", secret, "typing the job's token under Token…")
        ui.press_return(machine, "pressing Return in Token…'s field")
        kept = _wait_for(machine, lambda: (_the_source(machine) or {}).get("access") == "token" or None)
        dump = _keep_the_walk(machine, check_dir, lab, "the-token-kept.txt")
        if not kept:
            said = [ui.says(ui.element(dump, f"source.{sid}.{part}")) for part in ("notice", "problem", "state")]
            if any("Keychain" in s for s in said if s):
                raise LabError("keeping the job's token", f"this runner's Keychain refused uDeck: {said!r}")
            raise CheckFailed(f"the job's token under Token… was not kept: {SOURCES} says {_the_source(machine)!r}; "
                              f"the block says {[s for s in said if s]!r}")
        # Read again with it, to its end: a read that succeeded after the token was kept, and the hour GitHub left it
        # more than an address has without one.
        tokened = _wait_for(machine, lambda: _read_with_the_token(machine, state, anonymous, ANONYMOUS_HOURLY))
        _keep(check_dir, "state-with-the-token.json", _read_json(machine, state))
        expect(tokened is not None, f"read with the job's token, {state} says {_read_json(machine, state)!r}: no read "
                                    f"succeeded after it was kept with more of the hour left than {ANONYMOUS_HOURLY}")  # fmt: skip
        said = _wait_until(machine, f"source.{sid}.name", lambda said: _bare(said) == TEMPLATE_NAME, OPERATION_SECONDS)
        _keep_the_walk(machine, check_dir, lab, "read-with-the-token.txt")
        expect(_bare(said) == TEMPLATE_NAME, f"read with the token, the template's block is named {said!r}")

        _open_token(machine, sid, "to forget the token")
        _press(machine, f"source.{sid}.token.forget", "pressing Forget the token")
        gone = _wait_for(machine, lambda: (_the_source(machine) or {}).get("access") == "none" or None)
        expect(gone, f"after Forget the token, {SOURCES} says {_the_source(machine)!r}")
        step = "asking the Keychain for uDeck's item of tokens by its metadata"
        item = machine.ssh.run(f"security find-generic-password -s {app.BUNDLE_ID}.sources -a tokens >/dev/null", step,
                               seconds=20, check=False)  # fmt: skip
        if item.returncode not in (0, NO_SUCH_ITEM):
            raise LabError(step, f"security exited {item.returncode}: {item.stderr.strip()!r}")
        expect(item.returncode == NO_SUCH_ITEM, "its last token forgotten, uDeck's Keychain item of tokens is still there")
        _left_to_the_address(machine, check_dir, "at the end")
    finally:
        log.collect(check_dir, mark, "collecting uDeck's own account", name="udeck.log")
        try:
            os.remove(secret)
        except OSError:
            pass


def _open_token(machine, sid, label):
    """**Token…** on the source pressed until its field is there: the button is not offered while the source is read,
    and a press then lands on nothing."""
    for attempt in range(1, 4):
        _press(machine, f"source.{sid}.token", f"opening Token… {label} (try {attempt})")
        if _wait_until(machine, f"source.{sid}.token.tokenField", lambda said: said is not None, 15, present=True) is not None:
            return
    raise CheckFailed(f"Token… {label} opened no field to paste a token into")


def _source_id(path, remote_id, host="github.com", provider="github"):
    """A source's id as uDeck derives it (`SourceID.derive`), as the plugin checks derive it: the host and the path's
    last segment, then 8 hexadecimal digits of SHA-256 over provider, host and number."""
    slug = ""
    for character in f"{host}-{path.split('/')[-1]}".lower():
        kept = character if character in "abcdefghijklmnopqrstuvwxyz0123456789.-" else "-"
        if kept == "-" and slug.endswith("-"):
            continue
        slug += kept
    slug = slug.lstrip("-.")[:40].rstrip("-") or "source"
    identity = "\n".join((provider, host.lower(), str(remote_id)))
    return f"{slug}-{hashlib.sha256(identity.encode()).hexdigest()[:8]}"


def _keep_the_walk(machine, check_dir, lab, name):
    """Settings → Plugins as the walk reads it, kept beside the report — without a screenshot: a check that carries a
    real secret keeps no picture a byte search could not look into (S4-22)."""
    dump = ui.identified(machine, "reading Settings → Plugins", ui.SETTINGS_WINDOW, depth=ui.IDENTIFIED_DEPTH)
    try:
        (check_dir / name).write_text(dump)
    except OSError as error:
        lab.note(f"   {name} could not be written: {error}")
    return dump


def _bare(text):
    """`text` without the isolates a passport's name is shown inside."""
    for mark in ISOLATES:
        text = (text or "").replace(mark, "")
    return text


def _the_source(machine):
    """The one source `sources.json` lists, or None."""
    listed = (_read_json(machine, SOURCES) or {}).get("sources") or []
    return listed[0] if len(listed) == 1 else None


def _wait_for(machine, found, seconds=OPERATION_SECONDS):
    """What `found` gives once it gives something, or None after `seconds`."""
    deadline = machine.clock() + seconds
    while True:
        value = found()
        if value or machine.clock() >= deadline:
            return value or None
        machine.sleep(1)


def _read_with_the_token(machine, state, before, floor):
    """The source's state once a read after `before` succeeded with no error and GitHub left it more than `floor` of
    the hour — else None."""
    said = _read_json(machine, state) or {}
    left = (said.get("rateLimit") or {}).get("remaining")
    success = said.get("lastSuccess")
    if success and success != before and said.get("lastError") is None and isinstance(left, int) and left > floor:
        return said
    return None


# --- GitHub, asked by the lab ---------------------------------------------------------


def _github(url, step, token=True):
    """GitHub's JSON answer to `url` — with the job's token, unless `token` is False — or the lab's failure."""
    try:
        answer = releases.get(url, {"Accept": "application/vnd.github+json"}, environ=None if token else {})
    except releases.ReleaseError as error:
        raise LabError(step, str(error)) from None
    if answer.status != 200:
        raise LabError(step, f"GitHub answered {answer.status} to {url}: {answer.body[:200]!r}")
    try:
        return json.loads(answer.body)
    except ValueError:
        raise LabError(step, f"GitHub's answer to {url} is not JSON: {answer.body[:200]!r}") from None


def _left_to_the_address(machine, check_dir, when):
    """How many of the hour's sixty the runner's address has left without a token — what uDeck has — kept beside the report.

    `/rate_limit` is not counted against it.
    """
    said = _github(f"{config.GITHUB_API}/rate_limit", f"asking GitHub what is left to this address {when}", token=False)
    core = (said.get("resources") or {}).get("core") or {}
    try:
        with (check_dir / "rate-limit.txt").open("a") as kept:
            kept.write(f"{when}: {json.dumps(core)}\n")
    except OSError:
        pass
    return int(core.get("remaining", 0))


def _wait_for_the_closing(machine, api, number, head):
    """The pull request as GitHub says it is once it is closed — not merged — or the lab's failure after `CLOSE_SECONDS`."""
    deadline = machine.clock() + CLOSE_SECONDS
    while True:
        pull = _github(f"{api}/pulls/{number}", f"asking GitHub whether pull request #{number} was closed")
        if pull.get("state") == "closed":
            break
        if machine.clock() >= deadline:
            raise LabError("waiting for the pull request to be closed", f"pull request #{number} was still open after {CLOSE_SECONDS}s")
        machine.sleep(CLOSE_POLL_SECONDS)
    if pull.get("merged"):
        raise LabError("waiting for the pull request to be closed", f"pull request #{number} was merged, not closed unmerged")
    if (pull.get("head") or {}).get("sha") != head:
        raise LabError("waiting for the pull request to be closed",
                       f"pull request #{number} moved to {(pull.get('head') or {}).get('sha')} before it was closed")
    return pull


def _wait_for_the_branch_to_go(machine, api, branch):
    """Whether the pull request's branch was deleted within `BRANCH_SECONDS`."""
    deadline = machine.clock() + BRANCH_SECONDS
    while True:
        try:
            answer = releases.get(f"{api}/git/ref/heads/{branch}", {"Accept": "application/vnd.github+json"})
        except releases.ReleaseError as error:
            raise LabError("asking GitHub whether the branch was deleted", str(error)) from None
        if answer.status == 404:
            return True
        if machine.clock() >= deadline:
            return False
        machine.sleep(CLOSE_POLL_SECONDS)


# --- uDeck's screens and files -----------------------------------------------------------


def _look_up(machine, check_dir, lab, link):
    """`link` typed into **Install from a link…** and looked up: the walk once the sheet says what it came to."""
    _press(machine, "plugins.installFromLink", "pressing Install from a link…")
    try:
        field = ui.wait_for(machine, "link.field", "waiting for the link field")
    except NotThere as error:
        raise CheckFailed(f"Install from a link… offers no field to paste a link into: {error.reason}") from None
    machine.click(*field.middle, "putting the cursor in the link field")
    ui.type_text(machine, link, f"typing {link}")
    typed = _wait_until(machine, "link.field", lambda said: said == link, config.UI_CHANGE_SECONDS)
    if typed != link:
        raise LabError("typing the link", f"the field reads {typed!r} after {link!r} was typed into it")
    _press(machine, "link.lookUp", "pressing Look up")
    deadline = machine.clock() + OPERATION_SECONDS
    while True:
        dump = ui.identified(machine, "reading what the link came to", ui.SETTINGS_WINDOW, depth=ui.IDENTIFIED_DEPTH)
        found = {row.identifier for row in ui.controls(dump)}
        if found & {"link.head", "link.refused", "link.catalogue"} or machine.clock() >= deadline:
            break
        machine.sleep(1)
    dump = _keep_the_pane(machine, check_dir, lab, "the-link-sheet.txt")
    if "link.head" not in {row.identifier for row in ui.controls(dump)}:
        said = ui.says(ui.element(dump, "link.refused")) or ui.says(ui.element(dump, "link.catalogue"))
        raise CheckFailed(f"{link} came to {said or 'nothing'} within {OPERATION_SECONDS}s")
    return dump


def _expect_the_pull_requests(record, number, head, plugin):
    """A record of the official source's copy from pull request `number` at `head`: nobody's guarantee."""
    wanted = {"source": "official", "ref": {"kind": "pr", "name": str(number)}, "commit": head,
              "repository": {"provider": "github", "host": "github.com", "path": config.PLUGINS_REPOSITORY}}  # fmt: skip
    wrong = {key: record.get(key, "(missing)") for key, value in wanted.items() if record.get(key, "(missing)") != value}
    expect(not wrong, f"installed.json says {wrong} of {plugin}, where the install from pull request #{number} has to have "
                      f"written {({k: wanted[k] for k in wrong})}")
    verification = record.get("verification") or {}
    expect(verification.get("status") == "unverified" and "by" in verification and verification.get("by") is None,
           f"installed.json's verification of {plugin} is {verification!r}: unverified, by nobody")  # fmt: skip


def _wait_for_the_record(machine, plugin, done):
    deadline = machine.clock() + OPERATION_SECONDS
    while True:
        record = ((_read_json(machine, INSTALLED) or {}).get("plugins") or {}).get(plugin)
        if (record is not None and done(record)) or machine.clock() >= deadline:
            return record if record is not None and done(record) else None
        machine.sleep(1)


def _press(machine, identifier, what):
    try:
        return ui.click(machine, identifier, what)
    except NotThere as error:
        raise CheckFailed(f"{what}: uDeck does not offer it — {error.reason}") from None


def _wait_until(machine, identifier, satisfied, seconds, present=False):
    """What the control says once `satisfied`, or what a walk begun after the deadline read (None when absent)."""
    deadline = machine.clock() + seconds
    while True:
        began = machine.clock()
        dump = ui.identified(machine, f"reading {identifier}", ui.SETTINGS_WINDOW, depth=ui.IDENTIFIED_DEPTH)
        found = ui.element(dump, identifier)
        said = None if found is None else (ui.says(found) or (identifier if present else ""))
        if satisfied(said) or began >= deadline:
            return said
        machine.sleep(1)


def _keep_the_pane(machine, check_dir, lab, name):
    dump = ui.identified(machine, "reading Settings → Plugins", ui.SETTINGS_WINDOW, depth=ui.IDENTIFIED_DEPTH)
    try:
        (check_dir / name).write_text(dump)
    except OSError as error:
        lab.note(f"   {name} could not be written: {error}")
    machine.screenshot(check_dir, name.removesuffix(".txt"))
    return dump


def _read_json(machine, path):
    text = machine.ssh.ask(f"cat {path} 2>/dev/null || true", "reading uDeck's files").stdout
    if not text.strip():
        return None
    try:
        return json.loads(text)
    except ValueError as error:
        raise LabError("reading uDeck's files", f"{path} is not JSON ({error}): {text[:200]!r}") from None


def _keep(check_dir, name, value):
    try:
        (check_dir / name).write_text(json.dumps(value, indent=1))
    except (OSError, TypeError):
        pass
