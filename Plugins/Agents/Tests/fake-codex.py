#!/usr/bin/env python3
"""A stand-in for `codex app-server` (JSON-RPC over stdio, one message per line), for the
plugin's lab screenshots: it answers initialize, model/list, thread/start and thread/resume,
and for each turn streams an answer, asks to run one command, runs it once allowed, and
finishes the turn with token usage.

    fake-codex.py app-server
"""
import json
import sys
import time
import uuid

DELAY = 0.05
THREAD = "fake-thread-" + uuid.uuid4().hex[:8]
PICTURES = 0  # pictures that came with the turn being played
NAMING = False  # a thread of the plugin's namer: one answer, a name, for a message with "[name-me]"
pending = {}  # server request id -> the turn waiting on it
next_request = 1000


def out(message):
    sys.stdout.write(json.dumps(message) + "\n")
    sys.stdout.flush()


def note(method, params):
    out({"method": method, "params": params})


def read():
    line = sys.stdin.readline()
    if not line:
        return None
    try:
        return json.loads(line)
    except ValueError:
        return {}


def say(turn, text):
    item = "msg-" + uuid.uuid4().hex[:6]
    note("item/started", {"threadId": THREAD, "turnId": turn, "item": {"id": item, "type": "agentMessage", "text": ""}})
    for word in text.split(" "):
        note("item/agentMessage/delta", {"threadId": THREAD, "turnId": turn, "itemId": item, "delta": word + " "})
        time.sleep(DELAY)
    note("item/completed", {"threadId": THREAD, "turnId": turn, "item": {"id": item, "type": "agentMessage", "text": text}})


def start_turn(request_id, text):
    global next_request
    turn = "turn-" + uuid.uuid4().hex[:6]
    out({"id": request_id, "result": {"turn": {"id": turn, "status": "inProgress", "items": []}}})
    note("turn/started", {"threadId": THREAD, "turn": {"id": turn, "status": "inProgress", "items": []}})
    if NAMING:
        if text.startswith("«"):
            say(turn, "Fixing the notes")
        elif "[name-bad]" in text:
            say(turn, "Continue the notes: fixing them")
        else:
            say(turn, "Fixing the notes" if "[name-me]" in text else "")
        note("turn/completed", {"threadId": THREAD, "turn": {"id": turn, "status": "completed", "items": []}})
        return
    note("account/rateLimits/updated", {"rateLimits": {
        "primary": {"usedPercent": 81, "windowDurationMins": 300, "resetsAt": 4102444800},
        "secondary": {"usedPercent": 13, "windowDurationMins": 10080, "resetsAt": 4102444800}}})
    say(turn, "Picking up from what was handed over." if "[This conversation" in text
        else "Looking at it and at %d picture(s)." % PICTURES if PICTURES else "Looking at it.")
    next_request += 1
    pending[next_request] = turn
    out({"id": next_request, "method": "item/commandExecution/requestApproval",
         "params": {"threadId": THREAD, "turnId": turn, "itemId": "cmd-1", "command": "git status --short",
                    "reason": "to see what changed"}})


def finish(turn, decision):
    if decision in ("accept", "acceptForSession"):
        item = {"id": "cmd-" + uuid.uuid4().hex[:6], "type": "commandExecution", "command": "git status --short",
                "status": "inProgress"}
        note("item/started", {"threadId": THREAD, "turnId": turn, "item": item})
        time.sleep(DELAY)
        done = dict(item, status="completed", aggregatedOutput=" M Notes.md\n", exitCode=0)
        note("item/completed", {"threadId": THREAD, "turnId": turn, "item": done})
        say(turn, "One file changed: Notes.md.")
    else:
        say(turn, "All right, I will not run it.")
    note("thread/tokenUsage/updated", {"threadId": THREAD, "turnId": turn, "tokenUsage": {
        "last": {"totalTokens": 41000, "inputTokens": 40000, "cachedInputTokens": 0, "outputTokens": 1000,
                 "reasoningOutputTokens": 0, "cacheWriteInputTokens": 0},
        "total": {"totalTokens": 41000, "inputTokens": 40000, "cachedInputTokens": 0, "outputTokens": 1000,
                  "reasoningOutputTokens": 0, "cacheWriteInputTokens": 0},
        "modelContextWindow": 272000}})
    note("turn/completed", {"threadId": THREAD, "turn": {"id": turn, "status": "completed", "items": []}})


MODELS = [
    {"id": "fake-codex-1", "model": "fake-codex-1", "displayName": "Fake Codex 1", "isDefault": True, "hidden": False,
     "supportedReasoningEfforts": [{"reasoningEffort": e} for e in ("low", "medium", "high", "xhigh")]},
    {"id": "fake-codex-mini", "model": "fake-codex-mini", "displayName": "Fake Codex Mini", "isDefault": False,
     "hidden": False, "supportedReasoningEfforts": [{"reasoningEffort": e} for e in ("low", "medium")]},
]

while True:
    message = read()
    if message is None:
        break
    method = message.get("method")
    if method is None and "id" in message and message.get("id") in pending:
        decision = (message.get("result") or {}).get("decision")
        finish(pending.pop(message["id"]), decision if isinstance(decision, str) else "decline")
        continue
    request_id = message.get("id")
    params = message.get("params") or {}
    if method == "initialize":
        out({"id": request_id, "result": {"userAgent": "fake-codex/0", "codexHome": "/tmp", "platformOs": "macos"}})
    elif method == "model/list":
        out({"id": request_id, "result": {"data": MODELS, "nextCursor": None}})
    elif method in ("thread/start", "thread/resume"):
        THREAD = params.get("threadId", THREAD)
        NAMING = params.get("ephemeral") is True
        out({"id": request_id, "result": {"thread": {"id": THREAD}, "model": "fake-codex-1", "reasoningEffort": "medium"}})
    elif method == "turn/start":
        kinds = [part.get("type") for part in params.get("input", [])]
        unknown = [kind for kind in kinds if kind not in ("text", "image", "localImage", "audio", "localAudio", "skill", "mention")]
        if unknown:
            # As the real app server refuses one (codex 0.160).
            out({"id": request_id, "error": {"code": -32600, "message": "Invalid request: unknown variant `%s`" % unknown[0]}})
            continue
        text = " ".join(part.get("text", "") for part in params.get("input", []))
        PICTURES = sum(1 for part in params.get("input", []) if part.get("type") == "localImage" and part.get("path"))
        start_turn(request_id, text)
    elif method == "thread/list":
        out({"id": request_id, "result": {"data": [
            {"id": "saved-thread-1", "name": None, "preview": "Fix the notes\nand more", "cwd": "/tmp",
             "updatedAt": 1795390000, "ephemeral": False},
            {"id": "ephemeral-1", "preview": "x", "ephemeral": True, "updatedAt": 1}]}})
    elif method == "thread/turns/list":
        out({"id": request_id, "result": {"data": [
            {"id": "t2", "items": [{"type": "userMessage", "content": [{"type": "text", "text": "and now?"}]},
                                   {"type": "agentMessage", "text": "Done."}]},
            {"id": "t1", "items": [{"type": "userMessage", "content": [{"type": "text", "text": "Fix the notes"}]},
                                   {"type": "commandExecution", "id": "c1", "command": "ls", "aggregatedOutput": "Notes.md", "exitCode": 0},
                                   {"type": "agentMessage", "text": "Fixed."}]}]}})
    elif method == "thread/name/set":
        out({"id": request_id, "result": {}})
        note("thread/name/updated", {"threadId": params.get("threadId"), "threadName": params.get("name")})
    elif method == "turn/interrupt":
        out({"id": request_id, "result": {}})
    elif method == "account/rateLimits/read":
        out({"id": request_id, "result": {"rateLimits": {
            "primary": {"usedPercent": 34, "windowDurationMins": 300, "resetsAt": 4102444800},
            "secondary": {"usedPercent": 12, "windowDurationMins": 10080, "resetsAt": 4102444800}}}})
    elif request_id is not None:
        out({"id": request_id, "result": {}})
sys.exit(0)
