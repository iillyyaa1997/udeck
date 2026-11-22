"""Screenshots of the chat window for the operator — a lab tree's only, never committed.

uDeck opens its chat at launch (`ChatOpenAtLaunch`), starts a session in a folder with a first
message (`ChatLabFolder`, `ChatLabMessage`) against the lab's stand-in CLI
(`ChatClaudeExecutable` → e2e/fixtures/fake-claude.py), in Russian. The shots: the permission
asked, the turn done, a question asked, the question answered.
"""

import json
import shlex
from pathlib import Path

from udeck_e2e import app, ui, updates

VERSION = ("0.4.1", "6")
FAKE = Path(__file__).resolve().parent.parent / "fixtures" / "fake-claude.py"
WINDOW = "Чат uDeck"


def check_shots(machine, check_dir, lab):
    """The chat window: a permission, a finished turn, a question, its answer."""
    feed = updates.Feed(machine, lab.note)
    build = lab.builder(feed.url, check_dir.name).build(*VERSION)
    app.quit_app(machine, "ending any uDeck already running")
    app.install(machine, build.zip, lab.note)
    app.no_installs_by_itself(machine, "leaving updates alone")
    home = machine.ssh.run("printf %s \"$HOME\"", "reading the guest's home").stdout.strip()
    fake = f"{home}/lab-chat/fake-claude.py"
    project = f"{home}/Workspace/udeck"
    machine.ssh.run(
        f"mkdir -p {shlex.quote(project)} ~/.udeck && printf %s {shlex.quote(FAKE.read_text())} > {shlex.quote(fake)}"
        f" && chmod 755 {shlex.quote(fake)} && printf '# Notes\\n' > {shlex.quote(project)}/notes.md"
        f" && printf %s {shlex.quote(json.dumps({'language': 'ru'}))} > ~/.udeck/settings.json",
        "putting the stand-in CLI and a project folder in place",
    )
    bundle = app.BUNDLE_ID
    machine.ssh.run(
        f"defaults write {bundle} ChatOpenAtLaunch -bool true; "
        f"defaults write {bundle} ChatLabFolder -string {shlex.quote(project)}; "
        f"defaults write {bundle} ChatLabMessage -string {shlex.quote('Посмотри, что лежит в папке')}; "
        f"defaults write {bundle} ChatClaudeExecutable -string {shlex.quote(fake)}",
        "pointing the chat at the stand-in CLI",
    )
    app.launch(machine)
    allow = ui.wait_for(machine, "chat.ask.allow", "waiting for the permission card", WINDOW, seconds=90)
    machine.sleep(1.5)
    machine.screenshot(check_dir, "chat — permission asked")
    machine.click(*allow.middle, "allowing the command")
    machine.sleep(3)
    machine.screenshot(check_dir, "chat — turn done")
    field = ui.wait_for(machine, "chat.input", "finding the message field", WINDOW)
    machine.click(*field.middle, "focusing the message field")
    ui.type_text(machine, "Задай мне вопрос про значок", "typing a message")
    ui.press_return(machine, "sending it")
    option = ui.wait_for(machine, "chat.ask.option.Orange", "waiting for the question", WINDOW, seconds=60)
    machine.sleep(1.5)
    machine.screenshot(check_dir, "chat — question asked")
    machine.click(*option.middle, "choosing Orange")
    machine.sleep(3)
    machine.screenshot(check_dir, "chat — question answered")
