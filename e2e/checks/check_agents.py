"""Does the chat's helper keep agents alive, and keep everyone else out?

The chat's agents run under `udeck-agentd`, a launchd login agent of the uDeck
bundle reached over XPC (spec 66-llm-chat, §4.1 and §10.1–§10.5), so that a
turn goes on while uDeck quits, crashes or updates. There is no chat to drive
yet, so uDeck is asked to look at the helper itself: with `AgentHelperSelfTest`
written into its defaults — a key only the lab writes — each launch registers
the helper, connects, and appends one JSON line to
`~/.udeck/agents/selftest.jsonl` (`Sources/uDeck/SystemAgentHelper.swift`).

What decides the checks is that file and the guest's own process table, never
uDeck's window. Each check leaves the machine as it found it: uDeck is launched
once more with `AgentHelperUnregister`, which takes the helper's registration
away again, and the helper with it.
"""

import json
import shlex

from pathlib import Path

from udeck_e2e import app, ui, updates
from udeck_e2e.errors import LabError, expect

VERSION = ("0.4.1", "6")
REPORT = "~/.udeck/agents/selftest.jsonl"
HELPER = f"{app.GUEST_APPLICATIONS}/{app.APP}/Contents/Helpers/udeck-agentd"
LABEL = f"{app.BUNDLE_ID}.agentd"
# Registering, launchd starting the helper on the first message, and the probe:
# a few seconds measured locally; a cold guest is given far more.
REPORT_SECONDS = 90
CHAT_WINDOW = "uDeck Chat"
FAKE_CLAUDE = Path(__file__).resolve().parent.parent / "fixtures" / "fake-claude.py"


def check_survives_udeck_being_killed(machine, check_dir, lab):
    """An agent the helper started outlives uDeck killed outright, and the next uDeck finds it, same pid."""
    _prepare(machine, check_dir, lab)
    try:
        app.launch(machine, "starting uDeck with the helper's self-test on")
        first = _wait_for_reports(machine, 1)[-1]
        lab.note(f"   first launch: {_summary(first)}")
        expect("error" not in first, f"the self-test failed: {first.get('error')}")
        expect(first.get("statusAfter") == "enabled",
               f"the helper is not enabled after registering: {first.get('statusAfter')}")
        expect(first.get("sleeperSurvived") is False,
               "a fresh machine already had the self-test's agent running")
        _expect_helper_under_launchd(machine, first)

        # Not a quit: a crash, as far as anyone can tell.
        machine.ssh.run("pkill -9 -x uDeck; exit 0", "killing uDeck", check=False)
        _wait_until_gone(machine)
        sleeper = str(first["sleeperPid"])
        alive = machine.ssh.ask(f"kill -0 {sleeper} && echo alive", "asking whether the agent outlived uDeck")
        expect("alive" in alive.stdout, f"the agent (pid {sleeper}) died with uDeck")
        machine.screenshot(check_dir, "uDeck killed, agent alive")

        app.launch(machine, "starting uDeck again")
        second = _wait_for_reports(machine, 2)[-1]
        lab.note(f"   second launch: {_summary(second)}")
        expect("error" not in second, f"the self-test failed the second time: {second.get('error')}")
        expect(second.get("sleeperSurvived") is True, "the next uDeck did not find the agent running")
        expect(second.get("sleeperPid") == first.get("sleeperPid"),
               f"the agent the next uDeck found is pid {second.get('sleeperPid')}, not {first.get('sleeperPid')}")
        expect(second.get("helperInstance") == first.get("helperInstance"),
               "the helper was restarted between the two launches: its agents could not have survived in it")
        # Full Disk Access is not granted in a lab guest: the probe is expected to
        # be refused, and what matters is that it ran and its refusal reached uDeck.
        lab.note(f"   ~/Documents from an agent: exit {second.get('documentsExit')}, "
                 f"{second.get('documentsError') or 'no error'}")
        expect(isinstance(second.get("documentsExit"), int) and second.get("documentsExit") >= 0,
               f"the ~/Documents probe did not run to an exit: {second.get('documentsExit')}")
    finally:
        _unregister(machine, lab)


def check_turns_away_everyone_else(machine, check_dir, lab):
    """A program that is not uDeck, run by the same user in the same session, is turned away by the helper."""
    _prepare(machine, check_dir, lab)
    try:
        app.launch(machine, "starting uDeck with the helper's self-test on")
        first = _wait_for_reports(machine, 1)[-1]
        expect("error" not in first, f"the self-test failed: {first.get('error')}")
        # The helper's own binary as a client: same user, same login session,
        # signed — and not uDeck. Run in the login session's bootstrap, where
        # the helper's Mach service lives, not in the SSH session's.
        user = machine.ssh.run("id -u; id -un", "reading the guest's user").stdout.split()
        said = machine.ssh.run(
            f"sudo -n /bin/launchctl asuser {user[0]} sudo -n -u {shlex.quote(user[1])} "
            f"{shlex.quote(HELPER)} hello",
            "connecting to the helper as a program that is not uDeck",
            seconds=40,
            check=False,
        )
        answer = (said.stdout + said.stderr).strip()
        lab.note(f"   the helper's answer to a stranger: {answer}")
        expect("refused" in answer and "admitted" not in answer,
               f"a program that is not uDeck was not turned away: {answer}")
        # "Closed" alone would also be what a lookup that found no service
        # says. The helper's own log tells them apart: it took the connection
        # from that pid, and then let it go.
        pid = next((line.split()[-1] for line in answer.splitlines() if line.startswith("client pid ")), "")
        if not pid:
            raise LabError("connecting as a stranger", f"udeck-agentd hello did not say its pid: {answer}")
        log = machine.ssh.ask(
            "/usr/bin/log show --style compact --last 5m "
            f"--predicate 'subsystem == \"place.unicorns.udeck.agentd\"' 2>&1 | tail -200",
            "reading the helper's log",
            seconds=90,
        ).stdout
        (check_dir / "helper-log.txt").write_text(log)
        expect(f"connected: pid {pid}" in log,
               f"the helper's log shows no connection from the stranger (pid {pid}): the refusal was not the helper's")
        expect(f"disconnected: pid {pid}" in log,
               f"the helper took the stranger's connection (pid {pid}) and did not drop it")
        # And nothing on disk to connect to instead: no socket in ~/.udeck.
        sockets = machine.ssh.ask("find ~/.udeck -type s 2>/dev/null", "looking for sockets in ~/.udeck")
        expect(not sockets.stdout.strip(), f"sockets in ~/.udeck: {sockets.stdout.strip()}")
    finally:
        _unregister(machine, lab)


def check_chat_session_survives_udeck(machine, check_dir, lab):
    """A chat session waiting on a permission outlives uDeck killed outright: the next uDeck shows it, ask and all, and the answer goes through."""
    fake, folder = _prepare_chat(machine, check_dir, lab)
    try:
        app.launch(machine, "starting uDeck with a chat session to start")
        allow = ui.wait_for(machine, "chat.ask.allow", "waiting for the session's permission ask", CHAT_WINDOW, seconds=90)
        machine.screenshot(check_dir, "asked, before the kill")
        agent = machine.ssh.ask(f"pgrep -f {shlex.quote(fake)}", "finding the agent's process").stdout.split()
        expect(len(agent) == 1, f"one agent expected for the session, found {agent}")
        _expect_agent_under_the_helper(machine, agent[0])

        machine.ssh.run("pkill -9 -x uDeck; exit 0", "killing uDeck", check=False)
        _wait_until_gone(machine)
        still = machine.ssh.ask(f"kill -0 {agent[0]} && echo alive", "asking whether the agent outlived uDeck")
        expect("alive" in still.stdout, f"the agent (pid {agent[0]}) died with uDeck")

        # The next launch starts nothing new: it is to take back what is there.
        machine.ssh.run(f"defaults delete {app.BUNDLE_ID} ChatLabFolder >/dev/null 2>&1; exit 0",
                        "leaving the next launch nothing to start")
        app.launch(machine, "starting uDeck again")
        allow = ui.wait_for(machine, "chat.ask.allow", "waiting for the ask to come back", CHAT_WINDOW, seconds=60)
        machine.screenshot(check_dir, "the ask back after the restart")
        machine.click(*allow.middle, "allowing the command")
        deadline = machine.clock() + 30
        while ui.find(machine, "chat.stop", "watching the turn finish", CHAT_WINDOW) is not None:
            expect(machine.clock() < deadline, "the turn did not finish within 30 s of the answer")
            machine.sleep(1)
        machine.screenshot(check_dir, "the turn finished in the restored session")
        same = machine.ssh.ask(f"pgrep -f {shlex.quote(fake)}", "finding the agent again").stdout.split()
        expect(same == agent, f"the restored session runs on another agent: {same} instead of {agent}")
    finally:
        machine.ssh.run(
            f"for key in ChatOpenAtLaunch ChatLabFolder ChatLabMessage ChatClaudeExecutable; do "
            f"defaults delete {app.BUNDLE_ID} $key >/dev/null 2>&1; done; exit 0",
            "switching the chat's lab keys off",
        )
        _unregister(machine, lab)


def _prepare_chat(machine, check_dir, lab):
    """A lab build installed, not running, its chat pointed at the stand-in CLI with a session to start."""
    feed = updates.Feed(machine, lab.note)
    build = lab.builder(feed.url, check_dir.name).build(*VERSION)
    app.quit_app(machine, "ending any uDeck already running")
    app.install(machine, build.zip, lab.note)
    app.no_installs_by_itself(machine, "leaving what uDeck finds for Install")
    home = machine.ssh.run('printf %s "$HOME"', "reading the guest's home").stdout.strip()
    fake = f"{home}/lab-chat/fake-claude.py"
    folder = f"{home}/lab-chat/project"
    machine.ssh.run(
        f"mkdir -p {shlex.quote(folder)} && printf %s {shlex.quote(FAKE_CLAUDE.read_text())} > {shlex.quote(fake)}"
        f" && chmod 755 {shlex.quote(fake)} && printf '# Notes\\n' > {shlex.quote(folder)}/notes.md"
        f" && rm -f ~/.udeck/agents/chat-sessions.json",
        "putting the stand-in CLI and a project folder in place",
    )
    machine.ssh.run(
        f"defaults write {app.BUNDLE_ID} ChatOpenAtLaunch -bool true; "
        f"defaults write {app.BUNDLE_ID} ChatLabFolder -string {shlex.quote(folder)}; "
        f"defaults write {app.BUNDLE_ID} ChatLabMessage -string 'Look at the folder'; "
        f"defaults write {app.BUNDLE_ID} ChatClaudeExecutable -string {shlex.quote(fake)}",
        "pointing the chat at the stand-in CLI",
    )
    return fake, folder


def _expect_agent_under_the_helper(machine, pid):
    """The agent's parent is udeck-agentd (python3 runs the stand-in), not uDeck."""
    parent = machine.ssh.ask(f"ps -o ppid= -p {pid}", "asking who started the agent").stdout.strip()
    name = machine.ssh.ask(f"ps -o comm= -p {parent}", "naming the agent's parent").stdout.strip()
    expect(name.endswith("udeck-agentd"), f"the agent (pid {pid}) is a child of {name or parent}, not of udeck-agentd")


def _prepare(machine, check_dir, lab):
    """A lab build installed, not running, with the self-test switched on and no old reports."""
    feed = updates.Feed(machine, lab.note)
    builder = lab.builder(feed.url, check_dir.name)
    build = builder.build(*VERSION)
    app.quit_app(machine, "ending any uDeck already running")
    app.install(machine, build.zip, lab.note)
    there = app.installed_version(machine)
    if there != VERSION:
        raise LabError("preparing the machine", f"the lab installed {VERSION}, but the machine has {there}")
    app.no_installs_by_itself(machine, "leaving what uDeck finds for Install")
    machine.ssh.run(
        f"rm -f {REPORT}; defaults write {app.BUNDLE_ID} AgentHelperSelfTest -bool true; "
        f"defaults delete {app.BUNDLE_ID} AgentHelperUnregister >/dev/null 2>&1; exit 0",
        "switching the helper's self-test on",
    )


def _reports(machine, step):
    done = machine.ssh.ask(f"cat {REPORT} 2>/dev/null", step)
    reports = []
    for line in done.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            reports.append(json.loads(line))
        except json.JSONDecodeError as error:
            raise LabError(step, f"a line of {REPORT} is not JSON ({error}): {line[:200]}") from None
    return reports


def _wait_for_reports(machine, count, seconds=REPORT_SECONDS):
    deadline = machine.clock() + seconds
    while True:
        reports = _reports(machine, "reading the helper's self-test")
        if len(reports) >= count:
            return reports
        if machine.clock() >= deadline:
            raise LabError("waiting for the helper's self-test",
                           f"{len(reports)} report(s) in {seconds}s, wanted {count}")
        machine.sleep(2)


def _wait_until_gone(machine, seconds=20):
    deadline = machine.clock() + seconds
    while app.running_pids(machine, "waiting for the killed uDeck to be gone"):
        if machine.clock() >= deadline:
            raise LabError("killing uDeck", f"uDeck was still running {seconds}s after SIGKILL")
        machine.sleep(1)


def _expect_helper_under_launchd(machine, report):
    pid = str(report.get("helperPid", ""))
    parent = machine.ssh.ask(f"ps -o ppid= -p {shlex.quote(pid)}", "asking who started the helper").stdout.strip()
    expect(parent == "1", f"the helper (pid {pid}) was not started by launchd: parent {parent or 'none'}")
    job = machine.ssh.ask(f"/bin/launchctl print gui/$(id -u)/{LABEL} 2>&1 | head -40", "reading the helper's job")
    expect("state = running" in job.stdout, f"launchd does not show the helper running:\n{job.stdout}")


def _unregister(machine, lab):
    """Take the helper's registration away again, through uDeck, as the lab found the machine."""
    try:
        app.quit_app(machine, "ending uDeck before unregistering the helper")
        before = len(_reports(machine, "counting the self-test's reports"))
        machine.ssh.run(
            f"defaults write {app.BUNDLE_ID} AgentHelperUnregister -bool true; "
            f"defaults delete {app.BUNDLE_ID} AgentHelperSelfTest >/dev/null 2>&1; exit 0",
            "asking uDeck to unregister the helper",
        )
        app.launch(machine, "starting uDeck to unregister the helper")
        last = _wait_for_reports(machine, before + 1)[-1]
        lab.note(f"   unregistered: {last.get('unregistered')}, now {last.get('statusAfter')}")
        app.quit_app(machine, "ending uDeck after unregistering the helper")
        machine.ssh.run(f"defaults delete {app.BUNDLE_ID} AgentHelperUnregister >/dev/null 2>&1; exit 0",
                        "switching the unregistering off")
    except LabError as error:
        lab.note(f"   could not unregister the helper: {error}")


def _summary(report):
    keys = ("statusBefore", "statusAfter", "helperPid", "sleeperPid", "sleeperSurvived", "documentsExit")
    return ", ".join(f"{key}={report.get(key)}" for key in keys)
