#!/usr/bin/env python3
"""A stand-in for `claude` in stream-json mode, for uDeck's chat tests and the lab's screenshots.

It speaks the protocol as Claude Code 2.1.330 does (shapes taken from the recordings in
Plugins/Agents/Tests/AgentsCoreTests/Fixtures): it answers `initialize` and `interrupt`, and for every user
message plays one turn — the answer streamed word by word, a Bash call that asks for permission,
its result, and a closing sentence. A message that mentions "question" asks an AskUserQuestion
instead. Nothing here touches the network or the user's files. It exits when stdin closes.

A message that comes while a turn runs is taken as claude 2.1.332 takes one (measured 11-25): one
that came while a step ran is taken right after the step's result — echoed there, and played on
in the same turn, which ends with one result for both; one that comes after the last step starts
the next turn once this one has its result.

Its account is the folder `CLAUDE_CONFIG_DIR` names (`~/.claude` without it). `get_usage`
answers what `fake-usage.json` there says — `{"five_hour": {"utilization": 40, "resets_at": …},
"seven_day": …}` — or a little of both. A `fake-limited` file there makes every turn hit the
limit, as the real one reports it: a `rate_limit_event` rejected, then an error result. A
`fake-limited-wait` file there makes it meet a week's limit as claude 2.1.332 does in a program's
session (measured 11-26): the limit said at once, then «retry in 6 h» again and again, and no result
until an interrupt. A message with "[hang]" in it waits for an interrupt the same way, without a
limit — a model call that takes long. An interrupt's turn ends with the message echoed, «[Request
interrupted by user]» and an error result of two turns; the messages that came meanwhile start the
next turn, unless the interrupt cancelled them (`cancel_queued`).

    fake-claude.py [--resume SESSION_ID] [anything else the real CLI takes]
"""
import json
import os
import queue
import sys
import threading
import time

DELAY = float(os.environ.get("FAKE_CLAUDE_DELAY", "0.02"))
args = sys.argv[1:]
SESSION = args[args.index("--resume") + 1] if "--resume" in args else "fake-session-0001"
REPLAY = "--replay-user-messages" in args
# A run that only names a conversation (the plugin's namer): no tools, nothing kept. It answers a
# name for a message that asks for one with "[name-me]", and nothing for any other — the other
# tests' sessions keep the names they have.
NAMING = "--no-session-persistence" in args and "--tools" in args
# A `fake-claude-log` file in the account's folder gets every run's arguments, one JSON line each.
LOG = os.path.join(os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(os.path.expanduser("~"), ".claude"),
                   "fake-claude-log")
if os.path.exists(LOG):
    with open(LOG, "a") as log:
        log.write(json.dumps(args) + "\n")
CONFIG = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(os.path.expanduser("~"), ".claude")
waiting = []  # lines read while waiting for a particular answer, handled afterwards
counter = {"turn": 0}
# What it says, in the language of the message it answers — as the real one does.
EN = {"look": "I'll look at the folder first.", "found": "There is one file here, notes.md, 42 bytes.",
      "declined": "You declined, so I left the folder alone.", "ask": "Let me ask you one thing first.",
      "chose": "You chose %s, so the badge will be %s."}
RU = {"look": "Сначала посмотрю, что в папке.", "found": "Здесь один файл — notes.md, 42 байта.",
      "declined": "Вы отказали, так что папку я не трогал.", "ask": "Сначала один вопрос.",
      "chose": "Вы выбрали %s — значок будет таким: %s."}


def out(obj):
    sys.stdout.write(json.dumps(obj, ensure_ascii=False) + "\n")
    sys.stdout.flush()


# Every line of stdin, read on a thread of its own: a turn that waits can look for one now and then.
lines = queue.Queue()


def reader():
    for line in sys.stdin:
        lines.put(line)
    lines.put(None)


threading.Thread(target=reader, daemon=True).start()


def next_line(timeout=None):
    """The next line of stdin; None once it has closed — for every reader after, too."""
    line = lines.get(timeout=timeout)
    if line is None:
        lines.put(None)
    return line


def read():
    if waiting:
        return waiting.pop(0)
    line = next_line()
    if not line:
        return None
    try:
        return json.loads(line)
    except ValueError:
        return {}


def answer_to(request_id):
    """Read until the control_response for `request_id`, keeping anything else for later."""
    while True:
        line = next_line()
        if not line:
            return None
        try:
            obj = json.loads(line)
        except ValueError:
            continue
        if obj.get("type") == "control_response" and obj.get("response", {}).get("request_id") == request_id:
            return obj["response"].get("response", {})
        waiting.append(obj)


def transcript(text):
    """With a `fake-transcripts` file in the account's folder (the lab's), the session's transcript where the real
    one keeps it — projects/<the folder, / and . as ->/<session>.jsonl — for a plugin to continue it from."""
    if not os.path.exists(os.path.join(CONFIG, "fake-transcripts")):
        return
    folder = os.path.join(CONFIG, "projects", os.getcwd().replace("/", "-").replace(".", "-"))
    os.makedirs(folder, exist_ok=True)
    with open(os.path.join(folder, SESSION + ".jsonl"), "a", encoding="utf-8") as f:
        f.write(json.dumps({"type": "user", "sessionId": SESSION, "cwd": os.getcwd(), "entrypoint": "sdk-cli",
                            "message": {"role": "user", "content": text},
                            "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}, ensure_ascii=False) + "\n")


def calling():
    """A call to the model goes out (claude 2.1.332 says so before each)."""
    out({"type": "system", "subtype": "status", "status": "requesting", "session_id": SESSION})


def tokens(count):
    """The call's own count of the tokens it returned, said at its end (measured 11-26)."""
    out({"type": "stream_event", "event": {"type": "message_delta", "delta": {"stop_reason": "end_turn"},
         "usage": {"output_tokens": count}}, "parent_tool_use_id": None, "session_id": SESSION})


def say(text):
    """The answer streamed word by word, then whole — as with --include-partial-messages."""
    words = text.split(" ")
    out({"type": "stream_event", "event": {"type": "content_block_start", "index": 0,
         "content_block": {"type": "text", "text": ""}}, "parent_tool_use_id": None, "session_id": SESSION})
    for index, word in enumerate(words):
        piece = word if index == 0 else " " + word
        out({"type": "stream_event", "event": {"type": "content_block_delta", "index": 0,
             "delta": {"type": "text_delta", "text": piece}}, "parent_tool_use_id": None, "session_id": SESSION})
        time.sleep(DELAY)
    out({"type": "assistant", "message": {"id": "msg-%d" % time.time_ns(), "model": "claude-fake-1-0", "role": "assistant",
         "content": [{"type": "text", "text": text}]}, "parent_tool_use_id": None, "session_id": SESSION})
    tokens(len(words) * 2)


def tool_call(tool_id, name, tool_input):
    out({"type": "stream_event", "event": {"type": "content_block_start", "index": 1,
         "content_block": {"type": "tool_use", "id": tool_id, "name": name, "input": {}}},
         "parent_tool_use_id": None, "session_id": SESSION})
    out({"type": "assistant", "message": {"id": "msg-%d" % time.time_ns(), "model": "claude-fake-1-0", "role": "assistant",
         "content": [{"type": "tool_use", "id": tool_id, "name": name, "input": tool_input}]},
         "parent_tool_use_id": None, "session_id": SESSION})


def tool_result(tool_id, text, is_error=False):
    out({"type": "user", "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": tool_id,
         "content": text, "is_error": is_error}]}, "parent_tool_use_id": None, "session_id": SESSION})


def limited():
    return os.path.exists(os.path.join(CONFIG, "fake-limited"))


def usage():
    if limited():
        return {"five_hour": {"utilization": 100, "resets_at": "2099-01-01T00:00:00Z"},
                "seven_day": {"utilization": 60, "resets_at": "2099-01-07T00:00:00Z"}}
    try:
        with open(os.path.join(CONFIG, "fake-usage.json"), encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return {"five_hour": {"utilization": 5, "resets_at": "2099-01-01T00:00:00Z"},
                "seven_day": {"utilization": 20, "resets_at": "2099-01-07T00:00:00Z"}}


def hit_the_limit():
    resets = int(time.time()) + 3600
    out({"type": "system", "subtype": "init", "session_id": SESSION, "model": "claude-fake-1-0",
         "permissionMode": "default", "cwd": os.getcwd(), "claude_code_version": "2.1.330",
         "slash_commands": [], "capabilities": []})
    out({"type": "rate_limit_event", "rate_limit_info": {"status": "rejected", "rateLimitType": "five_hour",
         "utilization": 1.0, "resetsAt": resets}, "session_id": SESSION})
    out({"type": "result", "subtype": "success", "is_error": True, "num_turns": 1,
         "result": "Claude AI usage limit reached|%d" % resets, "session_id": SESSION, "total_cost_usd": 0})


def limited_wait():
    return os.path.exists(os.path.join(CONFIG, "fake-limited-wait"))


def control_answer(message):
    """The answer to a control request that is not an interrupt."""
    request = message.get("request", {})
    body = {}
    subtype = request.get("subtype")
    if subtype == "initialize":
        body = {"commands": [], "models": [
            {"value": "default", "displayName": "Default (recommended)", "resolvedModel": "claude-fake-1-0",
             "supportedEffortLevels": ["low", "medium", "high", "xhigh", "max"]},
            {"value": "fake", "displayName": "Fake 1.0", "resolvedModel": "claude-fake-1-0",
             "supportedEffortLevels": ["low", "medium", "high", "xhigh", "max"]},
            {"value": "quick", "displayName": "Quick 1.0", "resolvedModel": "claude-quick-1-0",
             "supportedEffortLevels": ["low", "medium", "high"]}]}
    elif subtype == "get_context_usage":
        body = {"totalTokens": 28000, "maxTokens": 200000, "percentage": 14, "model": "claude-fake-1-0"}
    elif subtype == "get_usage":
        body = {"subscription_type": "max", "rate_limits": usage()}
    elif subtype == "interrupt":
        body = {"still_queued": []}
    out({"type": "control_response", "response": {"subtype": "success", "request_id": message.get("request_id"),
         "response": body}})


def wait_for_interrupt(message, limit):
    """A turn that goes nowhere until it is interrupted: at a week's limit, or a long model call."""
    out({"type": "system", "subtype": "init", "session_id": SESSION, "model": "claude-fake-1-0",
         "permissionMode": "default", "cwd": os.getcwd(), "claude_code_version": "2.1.332",
         "slash_commands": [], "capabilities": []})
    out({"type": "system", "subtype": "status", "status": "requesting", "session_id": SESSION})
    if limit:
        time.sleep(0.5)  # as long as the real one took to say it
        out({"type": "rate_limit_event", "rate_limit_info": {"status": "rejected", "rateLimitType": "seven_day",
             "resetsAt": int(time.time()) + 6 * 86400, "overageStatus": "rejected", "isUsingOverage": False},
             "session_id": SESSION})
    queued = []
    while True:
        if limit:
            out({"type": "system", "subtype": "api_retry", "attempt": 1, "max_retries": 300,
                 "retry_delay_ms": 21600000, "error_status": 429, "error": "rate_limit", "session_id": SESSION})
        try:
            line = next_line(timeout=0.2)
        except queue.Empty:
            continue
        if not line:
            return
        try:
            obj = json.loads(line)
        except ValueError:
            continue
        if obj.get("type") == "user":
            queued.append(obj)
            continue
        if obj.get("type") != "control_request":
            continue
        request = obj.get("request", {})
        if request.get("subtype") != "interrupt":
            control_answer(obj)
            continue
        cancel = request.get("cancel_queued") is True
        out({"type": "control_response", "response": {"subtype": "success", "request_id": obj.get("request_id"),
             "response": {"still_queued": [], **({"cancelled": []} if cancel else {})}}})
        if limit:
            echo(message)
        out({"type": "user", "message": {"role": "user", "content": [{"type": "text", "text": "[Request interrupted by user]"}]},
             "parent_tool_use_id": None, "session_id": SESSION})
        out({"type": "result", "subtype": "error_during_execution", "is_error": True, "num_turns": 2, "result": None,
             "session_id": SESSION, "total_cost_usd": 0})
        if not cancel:
            waiting[:0] = queued
        return


def name(text):
    russian = any("а" <= ch.lower() <= "я" for ch in text)
    if text.startswith("«"):
        # Asked again about a name that would not do.
        words = "Заметки в папке" if "Продолжение" in text else "Notes in the folder"
    elif "[name-bad]" in text:
        words = "Продолжение работы над папкой заметок" if russian else "Continuing the work on the notes"
    else:
        words = ("Осмотр папки с заметками" if russian else "Looking at the notes folder") if "[name-me]" in text else ""
    out({"type": "result", "subtype": "success", "is_error": False, "num_turns": 1, "result": words,
         "session_id": SESSION, "total_cost_usd": 0})


def echo(message):
    if REPLAY:
        out({**message, "isReplay": True, "uuid": "echo-%d" % time.time_ns(), "session_id": SESSION})


def said(message):
    """A user message's text and how many pictures came with it."""
    content = message.get("message", {}).get("content", [])
    text = " ".join(part.get("text", "") for part in content if isinstance(part, dict) and part.get("type") == "text")
    return text, sum(1 for part in content if isinstance(part, dict) and part.get("type") == "image")


def take_waiting():
    """The messages that came while a step ran, taken after its result: echoed now, played on in this turn."""
    taken = [message for message in waiting if message.get("type") == "user"]
    for message in taken:
        waiting.remove(message)
        echo(message)
    return [said(message) for message in taken]


def turn(text, pictures=0):
    if NAMING:
        name(text)
        return
    if limited():
        hit_the_limit()
        return
    out({"type": "system", "subtype": "init", "session_id": SESSION, "model": "claude-fake-1-0",
         "permissionMode": "default", "cwd": os.getcwd(), "claude_code_version": "2.1.330",
         "slash_commands": ["compact", "review"], "capabilities": []})
    if "[retry]" in text:
        # The call failed and is tried again: overloaded, as the API says it.
        calling()
        out({"type": "system", "subtype": "api_retry", "attempt": 1, "max_retries": 10, "retry_delay_ms": 8000,
             "error_status": 529, "error": "overloaded_error", "session_id": SESSION})
        time.sleep(float(os.environ.get("FAKE_CLAUDE_RETRY", "0.5")))
    calling()
    playing = [(text, pictures)]
    while playing:
        playing += play(*playing.pop(0))
    out({"type": "result", "subtype": "success", "is_error": False, "num_turns": 2, "result": "done",
         "session_id": SESSION, "total_cost_usd": 0.0012})


def play(text, pictures):
    """One message's part of a turn; what it returns are the messages taken after its step."""
    russian = any("а" <= ch.lower() <= "я" for ch in text)
    words = RU if russian else EN
    counter["turn"] += 1
    n = counter["turn"]
    taken = []
    if pictures:
        say(("Вижу картинок: %d." if russian else "I see %d picture(s).") % pictures)
    if "question" in text.lower() or "вопрос" in text.lower():
        tool_id = "toolu_q%d" % n
        questions = [{"question": "Which colour should the badge be?", "header": "Colour", "multiSelect": False,
                      "options": [{"label": "Blue", "description": "Like the other badges"},
                                  {"label": "Orange", "description": "Stands out"}]}]
        say(words["ask"])
        tool_call(tool_id, "AskUserQuestion", {"questions": questions})
        out({"type": "control_request", "request_id": "perm-q%d" % n, "request": {
            "subtype": "can_use_tool", "tool_name": "AskUserQuestion", "display_name": "AskUserQuestion",
            "input": {"questions": questions}, "permission_suggestions": [], "tool_use_id": tool_id}})
        reply = answer_to("perm-q%d" % n) or {}
        chosen = (reply.get("updatedInput") or {}).get("answers", {}).get(questions[0]["question"], "nothing")
        tool_result(tool_id, "User answered: %s" % chosen)
        taken = take_waiting()
        calling()
        say(words["chose"] % (chosen, chosen.lower()))
    else:
        tool_id = "toolu_b%d" % n
        command = "ls -la"
        say(words["look"])
        tool_call(tool_id, "Bash", {"command": command, "description": "List the folder"})
        out({"type": "control_request", "request_id": "perm-b%d" % n, "request": {
            "subtype": "can_use_tool", "tool_name": "Bash", "display_name": "Bash",
            "input": {"command": command, "description": "List the folder"}, "tool_use_id": tool_id,
            "permission_suggestions": [{"type": "addRules", "rules": [{"toolName": "Bash", "ruleContent": "ls:*"}],
                                        "behavior": "allow", "destination": "localSettings"}]}})
        reply = answer_to("perm-b%d" % n) or {}
        if reply.get("behavior") == "allow":
            tool_result(tool_id, "total 8\ndrwxr-xr-x  3 me  staff   96 .\n-rw-r--r--  1 me  staff   42 notes.md")
            taken = take_waiting()
            calling()
            say(words["found"])
        else:
            tool_result(tool_id, "The user declined.", is_error=True)
            taken = take_waiting()
            calling()
            say(words["declined"])
    return taken


while True:
    message = read()
    if message is None:
        break
    kind = message.get("type")
    if kind == "control_request":
        control_answer(message)
    elif kind == "user":
        text = said(message)[0]
        if not NAMING:
            transcript(text)
        if not NAMING and (limited_wait() or "[hang]" in text):
            # At a limit the real one echoes the message only when interrupted.
            if not limited_wait():
                echo(message)
            wait_for_interrupt(message, limited_wait())
            continue
        echo(message)
        turn(*said(message))
sys.exit(0)
