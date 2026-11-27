import Foundation
import Testing
import UDeckAgents
@testable import AgentsCore

/// What the field suggests on «/» and «@» (uDeck 0.9.25, the operator's «1» to
/// questions 197–199): claude's commands and skills, Codex's skills, the
/// folder's files; and what the card does itself with a command.
@Suite("The field's suggestions", .serialized)
@MainActor
struct AgentsSuggestTests {
    final class Awake: SleepHolding {
        func hold(named name: String) -> Bool { true }
        func release() {}
        func others() -> [String] { [] }
        var hasALid: Bool { false }
    }

    func app(language: String = "ru") async throws -> (AgentsApp, URL) {
        setenv("UDECK_SETTING_CLAUDE", "\"\(fakeClaude.path)\"", 1)
        setenv("UDECK_SETTING_CODEX", "\"\(fakeCodex.path)\"", 1)
        setenv("FAKE_CLAUDE_DELAY", "0", 1)
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("agents-suggest-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home.appendingPathComponent("Sources/Layout"), withIntermediateDirectories: true)
        try "rows".write(to: home.appendingPathComponent("Sources/Layout/GridRows.swift"), atomically: true, encoding: .utf8)
        try "notes".write(to: home.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
        let app = AgentsApp(home: home, emit: { _ in }, keepAwake: KeepAwake(holder: Awake()))
        await app.handle(#"{"event":"hello","size":{"columns":8,"rows":8},"language":"\#(language)"}"#)
        return (app, home)
    }

    func suggest(_ app: AgentsApp) throws -> JSONValue {
        let rows = try #require(AgentsCard.card(for: app)["rows"]?.array)
        return try #require(rows.compactMap { $0["input"] }.first?["suggest"])
    }

    func items(_ suggest: JSONValue, tab: String) -> [String] {
        (suggest["items"]?.array ?? []).filter { $0["tab"]?.string == tab }.compactMap { $0["text"]?.string }
    }

    @Test("claude: its commands in Russian, the card's marked, the dead and the paid left out; its skills by their first sentence")
    func claude() async throws {
        let (app, home) = try await app()
        defer { try? FileManager.default.removeItem(at: home) }
        await app.newConversation(in: home, provider: .claude)
        let claude = try #require(app.conversations.first?.claude)
        try await until("idle") { claude.state == .idle }
        let suggest = try suggest(app)
        #expect(suggest["tabs"]?.array?.compactMap { $0["id"]?.string } == ["commands", "skills", "files"])
        #expect(suggest["tabs"]?.array?.first?["trigger"]?.string == "/")
        #expect(suggest["tabs"]?.array?.last?["search"] == true)
        let commands = items(suggest, tab: "commands")
        #expect(commands == ["/compact", "/context", "/model", "/effort", "/clear"])
        #expect(!commands.contains("/color") && !commands.contains("/ultrareview"), "dead in a card, or paid")
        let all = suggest["items"]?.array ?? []
        let compact = try #require(all.first { $0["text"]?.string == "/compact" })
        #expect(compact["detail"]?.string == "сжать разговор, освободить контекст  <optional custom summarization instructions>")
        #expect(all.first { $0["text"]?.string == "/model" }?["note"]?.string == "карточка")
        #expect(items(suggest, tab: "skills") == ["/code-review", "/planning-workflow"])
        #expect(all.first { $0["text"]?.string == "/code-review" }?["detail"]?.string
            == "Review the current diff for correctness bugs  [low|medium|high]")
        await claude.close()
    }

    @Test("«@»: the folder's files for the query, into the card; the best first")
    func files() async throws {
        let (app, home) = try await app()
        defer { try? FileManager.default.removeItem(at: home) }
        await app.newConversation(in: home, provider: .claude)
        let claude = try #require(app.conversations.first?.claude)
        try await until("idle") { claude.state == .idle }
        await app.handle(#"{"event":"suggest","row":"message","id":"files","text":"grid"}"#)
        try await until("found") { (try? suggest(app)["found"]) != nil }
        let found = try #require(try suggest(app)["found"])
        #expect(found["query"]?.string == "grid" && found["tab"]?.string == "files")
        #expect(found["items"]?.array?.first?["text"]?.string == "@Sources/Layout/GridRows.swift")
        #expect(found["items"]?.array?.first?["title"]?.string == "GridRows.swift")
        #expect(FileSearch.rank(["a/notes.md", "docs/long/notes-old.md", "src/grid.swift"], query: "notes", limit: 5)
            == ["a/notes.md", "docs/long/notes-old.md"])
        #expect(FileSearch.rank(["Sources/GridRows.swift"], query: "sgr", limit: 5) == ["Sources/GridRows.swift"],
                "letters in order")
        await claude.close()
    }

    @Test("the card's own: /model and /effort as its menus, /clear a new chat, a bad one said; recent ones first")
    func byTheCard() async throws {
        let (app, home) = try await app()
        defer { try? FileManager.default.removeItem(at: home) }
        await app.newConversation(in: home, provider: .claude)
        let conversation = try #require(app.conversations.first)
        let claude = try #require(conversation.claude)
        try await until("idle") { claude.state == .idle }
        await app.handle(#"{"event":"submit","row":"message","text":"/model quick"}"#)
        try await until("the model") { claude.chosenModel == "quick" }
        #expect(!claude.items.contains { if case .user = $0 { true } else { false } }, "not sent to claude")
        await app.handle(#"{"event":"submit","row":"message","text":"/model nothing-like-it"}"#)
        #expect(claude.items.contains { if case .note(_, "model-unknown:nothing-like-it") = $0 { true } else { false } })
        await app.handle(#"{"event":"submit","row":"message","text":"/effort low"}"#)
        try await until("the effort") { conversation.claude?.effort == "low" }
        // A command sent: first among the recent ones, kept on disk.
        let now = try #require(conversation.claude)
        try await until("idle again") { now.state == .idle }
        await app.handle(#"{"event":"submit","row":"message","text":"/compact keep the plan"}"#)
        #expect(app.recentCommands["claude"]?.first == "c:compact")
        #expect(try suggest(app)["recent"]?.array?.first?.string == "c:compact")
        #expect(RecentCommands.load(home: home)["claude"]?.first == "c:compact")
        await app.handle(#"{"event":"submit","row":"message","text":"/clear"}"#)
        #expect(app.conversations.count == 2, "a new chat; this one stays")
        for conversation in app.conversations { for agent in conversation.agents.values { await agent.close() } }
    }

    @Test("Codex: its skills on «/» as «$name», sent as skills; /compact and /review its own calls")
    func codex() async throws {
        let (app, home) = try await app(language: "en")
        defer { try? FileManager.default.removeItem(at: home) }
        await app.newConversation(in: home, provider: .codex)
        let codex = try #require(app.conversations.first?.codex)
        try await until("codex started") { codex.state == .idle }
        try await until("its skills") { !codex.skills.isEmpty }
        let suggest = try suggest(app)
        #expect(items(suggest, tab: "skills") == ["$lint"], "the one switched off left out")
        #expect(items(suggest, tab: "commands") == ["/model", "/effort", "/compact", "/review", "/new", "/rename"])
        #expect((suggest["items"]?.array ?? []).first { $0["text"]?.string == "$lint" }?["detail"]?.string == "Run the linter")
        let input = CodexSession.input("$lint the notes", pictures: [], skills: codex.skills)
        #expect(input.array?.last?["type"]?.string == "skill" && input.array?.last?["name"]?.string == "lint")
        await app.handle(#"{"event":"submit","row":"message","text":"$lint the notes"}"#)
        try await until("the answer") {
            codex.items.contains { if case .assistant(_, let said, _) = $0 { said.contains("with the skill lint") } else { false } }
        }
        #expect(app.recentCommands["codex"]?.first == "s:lint")
        try await until("its ask") { !codex.asks.isEmpty }
        codex.answer(try #require(codex.asks.first), with: "decline")
        try await until("the turn's end") { codex.state == .idle }
        await app.handle(#"{"event":"submit","row":"message","text":"/compact"}"#)
        #expect(codex.items.contains { if case .note(_, "compact") = $0 { true } else { false } })
        await app.handle(#"{"event":"submit","row":"message","text":"/review"}"#)
        try await Task.sleep(for: .milliseconds(300))
        #expect(!codex.items.contains { if case .note(_, "review-failed") = $0 { true } else { false } })
        await codex.close()
    }
}
