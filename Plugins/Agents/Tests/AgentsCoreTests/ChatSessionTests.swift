import Foundation
import Testing
@testable import AgentsCore
import UDeckAgents

/// The stand-in `claude` the lab's screenshots use too.
let fakeClaude = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("fake-claude.py")

@MainActor
func startFake(resume: String? = nil, history: [FeedItem] = []) async throws -> (ChatSession, URL) {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("udeck-chat-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    var arguments = [fakeClaude.path, "--replay-user-messages"]
    if let resume { arguments += ["--resume", resume] }
    let process = try AgentProcess(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: arguments,
                                   environment: ["PATH": "/usr/bin:/bin", "FAKE_CLAUDE_DELAY": "0"], directory: folder)
    let session = ChatSession(folder: folder, account: ChatAccount(name: "main", configDir: nil),
                              resumeID: resume, history: history)
    await session.start(channel: process)
    return (session, folder)
}

@MainActor
func until(_ what: String, timeout: Duration = .seconds(10), _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else { throw ChatTestError("timed out waiting for \(what)") }
        try await Task.sleep(for: .milliseconds(20))
    }
}

struct ChatTestError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

@Suite("A chat session over a Claude Code agent", .serialized)
@MainActor
struct ChatSessionTests {
    @Test("a turn: the answer streamed, a tool call asked about, allowed, its result, the closing words")
    func allowedTurn() async throws {
        let (session, folder) = try await startFake()
        defer { try? FileManager.default.removeItem(at: folder) }
        try await until("ready") { session.state == .idle }
        session.send("Look at the folder")
        #expect(session.state == .working)
        try await until("the permission ask") { session.asks.count == 1 }
        let ask = try #require(session.asks.first)
        #expect(ask.ask.toolName == "Bash")
        #expect(ask.summary == "ls -la")
        #expect(ask.ask.offersAlways)
        session.answer(ask, with: .allow)
        #expect(session.asks.isEmpty)
        try await until("the turn's end") { session.state == .idle }
        #expect(session.sessionID == "fake-session-0001")
        #expect(session.title == "Look at the folder")
        let texts = session.items.compactMap { item -> String? in
            if case .assistant(_, let text, let streaming) = item { #expect(!streaming); return text }
            return nil
        }
        #expect(texts == ["I'll look at the folder first.", "There is one file here, notes.md, 42 bytes."])
        guard case .tool(_, let name, let summary, let result)? = session.items.first(where: {
            if case .tool = $0 { true } else { false }
        }) else { Issue.record("no tool line"); return }
        #expect(name == "Bash" && summary == "ls -la")
        #expect(result?.isError == false)
        #expect(result?.preview.contains("notes.md") == true)
        if case .user(_, let text)? = session.items.first { #expect(text == "Look at the folder") }
        await session.close()
    }

    @Test("whoever watches is told of each ask and of each finished turn, with its last words")
    func attentionHooks() async throws {
        let (session, folder) = try await startFake()
        defer { try? FileManager.default.removeItem(at: folder) }
        var asked: [String] = [], finished: [String] = []
        session.onAsk = { asked.append($0.ask.toolName) }
        session.onTurnFinished = { finished.append($0) }
        try await until("ready") { session.state == .idle }
        session.send("Look at the folder")
        try await until("the permission ask") { session.asks.count == 1 }
        #expect(asked == ["Bash"])
        #expect(finished.isEmpty)
        session.answer(session.asks[0], with: .allow)
        try await until("the turn's end") { session.state == .idle }
        #expect(finished == ["There is one file here, notes.md, 42 bytes."])
        await session.close()
    }

    @Test("a declined tool call comes back as an error and the agent goes on")
    func declinedTurn() async throws {
        let (session, folder) = try await startFake()
        defer { try? FileManager.default.removeItem(at: folder) }
        try await until("ready") { session.state == .idle }
        session.send("Look at the folder")
        try await until("the permission ask") { session.asks.count == 1 }
        session.answer(session.asks[0], with: .deny)
        try await until("the turn's end") { session.state == .idle }
        let tool = session.items.compactMap { item -> ToolOutcome? in
            if case .tool(_, _, _, let result) = item { return result }
            return nil
        }.first
        #expect(tool?.isError == true)
        if case .assistant(_, let text, _)? = session.items.last {
            #expect(text == "You declined, so I left the folder alone.")
        }
        await session.close()
    }

    @Test("a question is answered with one of its options")
    func question() async throws {
        let (session, folder) = try await startFake()
        defer { try? FileManager.default.removeItem(at: folder) }
        try await until("ready") { session.state == .idle }
        session.send("Ask me a question")
        try await until("the question") { session.asks.count == 1 }
        let ask = session.asks[0]
        let questions = try #require(ask.ask.questions)
        #expect(questions.first?.options.map(\.label) == ["Blue", "Orange"])
        session.answer(ask, with: .choices([questions[0].question: ["Orange"]]))
        try await until("the turn's end") { session.state == .idle }
        if case .assistant(_, let text, _)? = session.items.last {
            #expect(text == "You chose Orange, so the badge will be orange.")
        }
        await session.close()
    }

    @Test("a message sent while a turn runs waits behind it, and both finish")
    func queued() async throws {
        let (session, folder) = try await startFake()
        defer { try? FileManager.default.removeItem(at: folder) }
        try await until("ready") { session.state == .idle }
        session.send("Look at the folder")
        session.send("Ask me a question")
        #expect(session.pendingTurns == 2)
        try await until("the first ask") { session.asks.count == 1 }
        session.answer(session.asks[0], with: .allow)
        try await until("the second ask") { session.asks.first?.ask.toolName == "AskUserQuestion" }
        #expect(session.state == .working)
        let ask = session.asks[0]
        session.answer(ask, with: .choices([ask.ask.questions![0].question: ["Blue"]]))
        try await until("both turns' ends") { session.state == .idle }
        #expect(session.pendingTurns == 0)
        await session.close()
    }

    @Test("a result of zero turns — what a resume reports first — ends nothing of the user's")
    func zeroTurnResult() async throws {
        let (session, folder) = try await startFake()
        defer { try? FileManager.default.removeItem(at: folder) }
        try await until("ready") { session.state == .idle }
        session.send("Look at the folder")
        session.receive(ClaudeInbound(["type": "result", "subtype": "success", "is_error": false, "num_turns": 0,
                                       "result": "", "session_id": "fake-session-0001"]))
        #expect(session.state == .working)
        #expect(session.pendingTurns == 1)
        try await until("the permission ask") { session.asks.count == 1 }
        session.answer(session.asks[0], with: .allow)
        try await until("the turn's end") { session.state == .idle }
        await session.close()
    }

    @Test("read back after a restart: the feed rebuilt from the replay, an answered ask gone, an open one still open")
    func rebuiltFromReplay() async throws {
        let session = ChatSession(folder: URL(fileURLWithPath: "/tmp"), account: ChatAccount(name: "main", configDir: nil))
        let lines: [JSONValue] = [
            ["type": "user", "isReplay": true, "message": ["role": "user", "content": [["type": "text", "text": "first"]]]],
            ["type": "assistant", "message": ["id": "m1", "content": [["type": "text", "text": "On it."],
                                                                      ["type": "tool_use", "id": "t1", "name": "Bash", "input": ["command": "ls"]]]]],
            ["type": "control_request", "request_id": "p1", "request": ["subtype": "can_use_tool", "tool_name": "Bash",
                                                                         "input": ["command": "ls"], "tool_use_id": "t1"]],
            ["type": "user", "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "t1", "content": "a"]]]],
            ["type": "result", "subtype": "success", "is_error": false, "num_turns": 2, "result": "", "session_id": "s"],
            ["type": "user", "isReplay": true, "message": ["role": "user", "content": [["type": "text", "text": "second"]]]],
            ["type": "assistant", "message": ["id": "m2", "content": [["type": "tool_use", "id": "t2", "name": "Bash", "input": ["command": "rm x"]]]]],
            ["type": "control_request", "request_id": "p2", "request": ["subtype": "can_use_tool", "tool_name": "Bash",
                                                                         "input": ["command": "rm x"], "tool_use_id": "t2"]],
        ]
        for line in lines { session.receive(ClaudeInbound(line)) }
        let users = session.items.compactMap { item -> String? in if case .user(_, let text) = item { return text }; return nil }
        #expect(users == ["first", "second"])
        #expect(session.asks.map(\.requestID) == ["p2"])
        #expect(session.state == .working)
        #expect(session.pendingTurns == 1)
    }

    @Test("a resumed session starts with its history and the resume noted, under its own id")
    func resumed() async throws {
        let history: [FeedItem] = [.user(id: UUID(), text: "earlier"),
                                   .assistant(id: UUID(), text: "an earlier answer", streaming: false)]
        let (session, folder) = try await startFake(resume: "abc-123", history: history)
        defer { try? FileManager.default.removeItem(at: folder) }
        try await until("ready") { session.state == .idle }
        #expect(session.items.count == 3)
        if case .note(_, let text)? = session.items.last { #expect(text == "resumed") }
        session.send("Look at the folder")
        try await until("the permission ask") { session.asks.count == 1 }
        #expect(session.sessionID == "abc-123")
        session.answer(session.asks[0], with: .allow)
        try await until("the turn's end") { session.state == .idle }
        await session.close()
    }

    @Test("when the agent exits, the session says so, and its open asks go")
    func agentExits() async throws {
        let (session, folder) = try await startFake()
        defer { try? FileManager.default.removeItem(at: folder) }
        try await until("ready") { session.state == .idle }
        session.send("Look at the folder")
        try await until("the permission ask") { session.asks.count == 1 }
        await session.close()
        try await until("ended") { session.isEnded }
        #expect(session.asks.isEmpty)
    }
}

@Suite("Accounts and saved sessions for the chat")
struct ChatAccountTests {
    @Test("the main account and every ~/.claude-<name> with a login of its own")
    func discover() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("udeck-home-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        for name in [".claude", ".claude-pers2", ".claude-old"] {
            try FileManager.default.createDirectory(at: home.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        try Data("{}".utf8).write(to: home.appendingPathComponent(".claude-pers2/.claude.json"))
        let accounts = ChatAccount.discover(home: home, mainName: "pers")
        #expect(accounts.map(\.name) == ["pers", "pers2"])
        #expect(accounts[0].configDir == nil)
        #expect(accounts[1].configDir?.lastPathComponent == ".claude-pers2")
    }

    @Test("a subscription session's environment drops API-key billing and names its account")
    func environment() {
        let shell = ["PATH": "/usr/bin", "ANTHROPIC_API_KEY": "k", "ANTHROPIC_BASE_URL": "u", "HOME": "/Users/x"]
        let main = ChatAccount(name: "pers", configDir: nil).environment(from: shell)
        #expect(main["ANTHROPIC_API_KEY"] == nil && main["ANTHROPIC_BASE_URL"] == nil)
        #expect(main["CLAUDE_CONFIG_DIR"] == nil)
        #expect(main["UDECK_SESSION"] == "1" && main["PATH"] == "/usr/bin")
        let extra = ChatAccount(name: "pers2", configDir: URL(fileURLWithPath: "/Users/x/.claude-pers2"))
            .environment(from: shell)
        #expect(extra["CLAUDE_CONFIG_DIR"] == "/Users/x/.claude-pers2")
    }

    @Test("saved sessions newest first, with their folder and last prompt, read from head and tail")
    func history() throws {
        let config = FileManager.default.temporaryDirectory.appendingPathComponent("udeck-config-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: config) }
        let project = config.appendingPathComponent("projects/-Users-x-Workspace-udeck", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let older = project.appendingPathComponent("aaa.jsonl")
        let newer = project.appendingPathComponent("bbb.jsonl")
        try """
        {"type":"user","cwd":"/Users/x/Workspace/udeck","sessionId":"aaa","message":{"role":"user","content":"hello"}}
        {"type":"last-prompt","lastPrompt":"fix the tests","sessionId":"aaa"}
        """.write(to: older, atomically: true, encoding: .utf8)
        try """
        {"type":"user","cwd":"/Users/x/Workspace/warren","sessionId":"bbb","message":{"role":"user","content":"hi"}}
        """.write(to: newer, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: older.path)
        let saved = SessionHistory.recent(config: config)
        #expect(saved.map(\.sessionID) == ["bbb", "aaa"])
        #expect(saved[1].title == "fix the tests")
        #expect(saved[1].cwd == "/Users/x/Workspace/udeck")
        #expect(saved[0].title == "warren")
    }

    @Test("a transcript becomes feed items: words, tool lines with their results")
    func transcriptFeed() {
        let transcript = ClaudeTranscript(contents: """
        {"type":"user","sessionId":"s","message":{"role":"user","content":"list it"}}
        {"type":"assistant","sessionId":"s","message":{"id":"m","model":"x","content":[{"type":"text","text":"Sure."},{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls"}}]}}
        {"type":"user","sessionId":"s","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"a\\nb","is_error":false}]}}
        """)
        let items = SessionHistory.feed(of: transcript)
        #expect(items.count == 3)
        if case .tool(_, let name, let summary, let result) = items[2] {
            #expect(name == "Bash" && summary == "ls" && result?.preview == "a\nb")
        } else {
            Issue.record("no tool line: \(items)")
        }
    }

    /// The race this guards (lab gallery-11): the old process exited, and its
    /// reader ended the session, before the new start took its place.
    @MainActor
    @Test("started again — a new effort — the session goes on: the old process's exit ends nothing")
    func restartGoesOn() async throws {
        let (session, folder) = try await startFake()
        defer { try? FileManager.default.removeItem(at: folder) }
        try await until("idle") { session.state == .idle }
        session.beginRestart("effort:high")
        await session.close()
        try await Task.sleep(for: .milliseconds(200))
        #expect(!session.isEnded, "the old process's exit ended the session")
        var arguments = [fakeClaude.path, "--replay-user-messages", "--resume", session.sessionID ?? "fake-session-0001"]
        arguments += ["--effort", "high"]
        let process = try AgentProcess(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: arguments,
                                       environment: ["PATH": "/usr/bin:/bin", "FAKE_CLAUDE_DELAY": "0"], directory: folder)
        await session.start(channel: process)
        try await until("idle again") { session.state == .idle }
        session.send("Look at the folder")
        try await until("an ask after the restart") { !session.asks.isEmpty }
        #expect(session.items.contains { if case .note(_, let text) = $0 { text == "effort:high" } else { false } })
        await session.close()
    }
}

