import Foundation
import Testing
@testable import AgentsCore
import UDeckAgents

@Suite("Agents card and history")
struct AgentsCardTests {
    @Test("machine-written transcript lines are not the person's words")
    func spoken() {
        #expect(SessionHistory.spoken("hello") == .said("hello"))
        #expect(SessionHistory.spoken("<task-notification>\n<task-id>x</task-id>") == .machine)
        #expect(SessionHistory.spoken("  <system-reminder>be brief</system-reminder>") == .machine)
        #expect(SessionHistory.spoken("<local-command-stdout>ok</local-command-stdout>") == .machine)
        #expect(SessionHistory.spoken("<command-message>plan</command-message>\n<command-name>/plan</command-name>\n<command-args>do it</command-args>")
            == .said("/plan do it"))
        #expect(SessionHistory.spoken("This session is being continued from a previous conversation that ran out of context.")
            == .compacted)
    }

    @Test("a string setting is read as the JSON uDeck passes")
    func setting() {
        #expect(AgentsApp.setting(#""""#) == "")
        #expect(AgentsApp.setting(#""/opt/claude""#) == "/opt/claude")
        #expect(AgentsApp.setting("/bare/path") == "/bare/path")
        #expect(AgentsApp.setting(nil) == nil)
    }

    @Test("a long text is cut, a short one is kept")
    func clipped() {
        #expect(AgentsCard.clipped("short") == "short")
        let long = String(repeating: "a", count: AgentsCard.longest + 50)
        #expect(AgentsCard.clipped(long).count == AgentsCard.longest + 1)
    }

    @MainActor
    @Test("a saved session written a moment ago opens to be read, and is not resumed")
    func heldBack() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("agents-\(UUID().uuidString)")
        let folder = home.appendingPathComponent(".claude/projects/-tmp-work")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let id = UUID().uuidString.lowercased()
        let lines = [
            #"{"type":"user","sessionId":"\#(id)","cwd":"/tmp","message":{"role":"user","content":"look at it"},"timestamp":"2026-11-22T10:00:00Z"}"#,
            #"{"type":"user","sessionId":"\#(id)","cwd":"/tmp","message":{"role":"user","content":"<task-notification>done</task-notification>"},"timestamp":"2026-11-22T10:01:00Z"}"#,
            #"{"type":"last-prompt","lastPrompt":"look at it"}"#,
        ]
        try (lines.joined(separator: "\n") + "\n").write(to: folder.appendingPathComponent("\(id).jsonl"), atomically: true, encoding: .utf8)
        var said: [String] = []
        let app = AgentsApp(home: home) { said.append($0) }
        await app.handle(#"{"event":"hello","size":{"columns":8,"rows":6},"language":"ru"}"#)
        await app.handle(#"{"event":"select","id":"history"}"#)
        await app.handle(#"{"event":"select","id":"h:\#(id)"}"#)
        let session = try #require(app.conversations.first)
        #expect(app.heldBack[session.id] != nil)
        #expect(session.current.state == .starting, "nothing was started")
        // The history is read off the main thread, from the transcript's tail.
        try await until("the history") { session.current.items.contains { if case .user(_, let text) = $0 { text == "look at it" } else { false } } }
        #expect(!session.current.items.contains { if case .user(_, let text) = $0 { text.contains("task-notification") } else { false } })
        let card = try #require(said.last)
        #expect(card.contains("Эта сессия сейчас идёт в другом месте"))
        #expect(card.contains(#""enabled":false"#))
        await app.handle(#"{"event":"press","id":"drop:\#(session.id.uuidString)"}"#)
        #expect(app.conversations.isEmpty)
        #expect(app.heldBack.isEmpty)
    }

    @Test("model names, a turn's clock and Russian question counts")
    func words() {
        #expect(AgentsCard.prettyModel("claude-opus-5-5") == "Opus 5.5")
        #expect(AgentsCard.prettyModel("claude-sonnet-5-5[1m]") == "Sonnet 5.5")
        #expect(AgentsCard.prettyModel("gpt-6-astra") == "gpt-6-astra")
        #expect(AgentsCard.clock(42) == "0:42")
        #expect(AgentsCard.clock(3725) == "1:02:05")
        #expect(AgentsCard.questions(1) == "вопрос")
        #expect(AgentsCard.questions(3) == "вопроса")
        #expect(AgentsCard.questions(11) == "вопросов")
        #expect(AgentsCard.russianCount(1, "действие", "действия", "действий") == "1 действие")
        #expect(AgentsCard.russianCount(3, "сообщение", "сообщения", "сообщений") == "3 сообщения")
    }

    @Test("the models the CLI offers are read from initialize, with their effort levels")
    func models() {
        let body: JSONValue = ["models": [
            ["value": "default", "displayName": "Default (recommended)", "resolvedModel": "claude-opus-5-5"],
            ["value": "sonnet", "displayName": "Sonnet 5.5", "resolvedModel": "claude-sonnet-5-5",
             "supportedEffortLevels": ["low", "high"]],
        ]]
        let models = ModelChoice.list(body)
        #expect(models.map(\.value) == ["default", "sonnet"])
        #expect(models[1].name == "Sonnet 5.5")
        #expect(models[1].efforts == ["low", "high"])
    }

    @MainActor
    @Test("the card opens with a bar: the title, the session menu with the saved sessions, and ＋")
    func header() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("agents-\(UUID().uuidString)")
        let folder = home.appendingPathComponent(".claude/projects/-tmp-work")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let id = UUID().uuidString.lowercased()
        let line = #"{"type":"user","sessionId":"\#(id)","cwd":"/tmp","message":{"role":"user","content":"fix the build"},"timestamp":"2026-11-20T10:00:00Z"}"#
        let file = folder.appendingPathComponent("\(id).jsonl")
        try (line + "\n" + #"{"type":"last-prompt","lastPrompt":"fix the build"}"# + "\n").write(to: file, atomically: true, encoding: .utf8)
        var said: [String] = []
        let app = AgentsApp(home: home) { said.append($0) }
        await app.handle(#"{"event":"hello","size":{"columns":8,"rows":6},"language":"ru"}"#)
        let card = try #require(said.last.flatMap { JSONValue.line(Substring($0)) }?["card"])
        let rows = try #require(card["rows"]?.array)
        let head = try #require(rows.first?["bar"])
        #expect(head["id"]?.string == "head")
        let items = try #require(head["items"]?.array)
        #expect(items.first?["title"]?["text"]?.string == "Agents")
        let options = try #require(items.first(where: { $0["menu"] != nil })?["menu"]?["options"]?.array)
        #expect(options.contains { $0["id"]?.string == "h:" + id && $0["group"]?.string == "История Claude — продолжить" })
        #expect(items.last?["button"]?["id"]?.string == "new")
        // Chosen from the menu it opens — written a moment ago, so to be read,
        // and nothing is started (a test must not run the real CLI).
        await app.handle(#"{"event":"choose","row":"head","menu":"session","option":"h:\#(id)"}"#)
        let session = try #require(app.conversations.first)
        #expect(app.heldBack[session.id] != nil)
        #expect(app.selection == session.id)
        let opened = try #require(said.last.flatMap { JSONValue.line(Substring($0)) }?["card"]?["rows"]?.array)
        #expect(opened.first?["bar"]?["items"]?.array?.first?["title"]?["text"]?.string == "fix the build")
        #expect(opened.dropFirst().first?["bar"]?["id"]?.string == "status")
        // Three rows high — a mini window: what it does goes into the title
        // line, in place of the provider, and the line of badges goes.
        await app.handle(#"{"event":"size","size":{"columns":4,"rows":3}}"#)
        let mini = try #require(said.last.flatMap { JSONValue.line(Substring($0)) }?["card"]?["rows"]?.array)
        let miniHead = try #require(mini.first?["bar"]?["items"]?.array)
        #expect(miniHead.contains { $0["badge"]?["text"]?.string == "Только просмотр" })
        #expect(!miniHead.contains { $0["tag"] != nil })
        #expect(!mini.contains { $0["bar"]?["id"]?.string == "status" })
        #expect(mini.contains { $0["input"] != nil })
    }

    @MainActor
    @Test("handed over: the new provider gets what happened since it last spoke, with the next message")
    func handoffGap() {
        let folder = URL(fileURLWithPath: "/tmp/work")
        let claude = ChatSession(folder: folder, account: ChatAccount(name: "main", configDir: nil), history: [
            .user(id: UUID(), text: "look at the build"),
            .tool(id: "t1", name: "Bash", summary: "swift build", result: ToolOutcome(isError: true, preview: "error")),
            .assistant(id: UUID(), text: "It fails on a missing import.", streaming: false),
        ])
        let conversation = Conversation(.claude(claude))
        let codex = CodexSession(folder: folder)
        conversation.switchTo(.codex, agent: .codex(codex), model: "GPT-6-Astra")
        #expect(conversation.active == .codex)
        #expect(conversation.providers == [.claude, .codex])
        let feed = conversation.feed
        #expect(feed.count == 4, "three items, then the handoff note")
        guard case .note(_, let note) = feed[3].item else { Issue.record("no handoff note"); return }
        #expect(note == "handoff:codex|GPT-6-Astra|2|1|\(Conversation.gap(since: nil, in: conversation.segments, agents: conversation.agents).text.count / 4)"
                || note.hasPrefix("handoff:codex|GPT-6-Astra|2|1|"))
        #expect(feed[2].label == "Claude", "once two have answered, an answer says who gave it")
        let gap = Conversation.gap(since: nil, in: conversation.segments, agents: conversation.agents)
        #expect(gap.text.contains("Person: look at the build"))
        #expect(gap.text.contains("(Claude ran Bash swift build — it failed)"))
        #expect(gap.text.contains("Claude: It fails on a missing import."))
        #expect(gap.messages == 2)
        #expect(gap.actions == 1)
    }

    @Test("Codex's models are read from model/list, hidden ones left out, with their effort levels")
    func codexModels() {
        let list: JSONValue = ["data": [
            ["id": "gpt-6-astra", "model": "gpt-6-astra", "displayName": "GPT-6-Astra",
             "supportedReasoningEfforts": [["reasoningEffort": "low"], ["reasoningEffort": "ultra"]]],
            ["id": "secret", "displayName": "Hidden", "hidden": true],
        ]]
        let models = CodexSession.models(list)
        #expect(models.map(\.value) == ["gpt-6-astra"])
        #expect(models[0].efforts == ["low", "ultra"])
    }

    @Test("a Codex operation reads as one tool line")
    func codexTool() {
        #expect(CodexSession.tool(["id": "c1", "type": "commandExecution", "command": "ls -la"])?.name == "Shell")
        #expect(CodexSession.tool(["id": "f1", "type": "fileChange", "changes": [["path": "/a/b/Notes.md"]]])?.summary == "Notes.md")
        #expect(CodexSession.tool(["id": "m1", "type": "agentMessage"]) == nil)
    }
}

