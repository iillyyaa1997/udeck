#!/usr/bin/env python3
"""A stand-in for `claude` in stream-json mode, for uDeck's chat tests and the lab's screenshots.

It speaks the protocol as Claude Code 2.1.330 does (shapes taken from the recordings in
Tests/UDeckAgentsTests/Fixtures): it answers `initialize` and `interrupt`, and for every user
message plays one turn — the answer streamed word by word, a Bash call that asks for permission,
its result, and a closing sentence. A message that mentions "question" asks an AskUserQuestion
instead. Nothing here touches the network or the user's files. It exits when stdin closes.

    fake-claude.py [--resume SESSION_ID] [anything else the real CLI takes]
"""
import json
import os
import sys
import time

DELAY = float(os.environ.get("FAKE_CLAUDE_DELAY", "0.02"))
args = sys.argv[1:]
SESSION = args[args.index("--resume") + 1] if "--resume" in args else "fake-session-0001"
REPLAY = "--replay-user-messages" in args
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


def read():
    if waiting:
        return waiting.pop(0)
    line = sys.stdin.readline()
    if not line:
        return None
    try:
        return json.loads(line)
    except ValueError:
        return {}


def answer_to(request_id):
    """Read until the control_response for `request_id`, keeping anything else for later."""
    while True:
        line = sys.stdin.readline()
        if not line:
            return None
        try:
            obj = json.loads(line)
        except ValueError:
            continue
        if obj.get("type") == "control_response" and obj.get("response", {}).get("request_id") == request_id:
            return obj["response"].get("response", {})
        waiting.append(obj)


def say(text):
    """The answer streamed word by word, then whole — as with --include-partial-messages."""
    words = text.split(" ")
    for index, word in enumerate(words):
        piece = word if index == 0 else " " + word
        out({"type": "stream_event", "event": {"type": "content_block_delta", "index": 0,
             "delta": {"type": "text_delta", "text": piece}}, "parent_tool_use_id": None, "session_id": SESSION})
        time.sleep(DELAY)
    out({"type": "assistant", "message": {"id": "msg-%d" % time.time_ns(), "model": "claude-fake", "role": "assistant",
         "content": [{"type": "text", "text": text}]}, "parent_tool_use_id": None, "session_id": SESSION})


def tool_call(tool_id, name, tool_input):
    out({"type": "assistant", "message": {"id": "msg-%d" % time.time_ns(), "model": "claude-fake", "role": "assistant",
         "content": [{"type": "tool_use", "id": tool_id, "name": name, "input": tool_input}]},
         "parent_tool_use_id": None, "session_id": SESSION})


def tool_result(tool_id, text, is_error=False):
    out({"type": "user", "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": tool_id,
         "content": text, "is_error": is_error}]}, "parent_tool_use_id": None, "session_id": SESSION})


def turn(text):
    russian = any("а" <= ch.lower() <= "я" for ch in text)
    words = RU if russian else EN
    counter["turn"] += 1
    n = counter["turn"]
    out({"type": "system", "subtype": "init", "session_id": SESSION, "model": "claude-fake",
         "permissionMode": "default", "cwd": os.getcwd(), "claude_code_version": "2.1.330",
         "slash_commands": ["compact", "review"], "capabilities": []})
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
            say(words["found"])
        else:
            tool_result(tool_id, "The user declined.", is_error=True)
            say(words["declined"])
    out({"type": "result", "subtype": "success", "is_error": False, "num_turns": 2, "result": "done",
         "session_id": SESSION, "total_cost_usd": 0.0012})


while True:
    message = read()
    if message is None:
        break
    kind = message.get("type")
    if kind == "control_request":
        request = message.get("request", {})
        body = {}
        if request.get("subtype") == "initialize":
            body = {"commands": [], "models": [{"value": "claude-fake", "displayName": "Fake"}]}
        out({"type": "control_response", "response": {"subtype": "success", "request_id": message.get("request_id"),
             "response": body}})
    elif kind == "user":
        if REPLAY:
            out({**message, "isReplay": True, "uuid": "echo-%d" % time.time_ns(), "session_id": SESSION})
        content = message.get("message", {}).get("content", [])
        text = " ".join(part.get("text", "") for part in content if isinstance(part, dict) and part.get("type") == "text")
        turn(text)
sys.exit(0)
