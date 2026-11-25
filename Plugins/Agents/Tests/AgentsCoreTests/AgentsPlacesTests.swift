import Foundation
import Testing
@testable import AgentsCore
import UDeckAgents

/// Each conversation in a place of its own: uDeck names the card's places,
/// each shows one conversation, and none shows a conversation another does.
@Suite("Places: each conversation in a place of its own", .serialized)
@MainActor
struct AgentsPlacesTests {
    final class Said {
        var lines: [String] = []
        /// The newest card written for `view`.
        func card(_ view: String) -> JSONValue? {
            lines.reversed().compactMap { JSONValue.line(Substring($0)) }.first { $0["view"]?.string == view && $0["card"] != nil }
        }
        var shown: [String] { lines.compactMap { JSONValue.line(Substring($0))?["show"]?["view"]?.string } }
    }

    func app() -> (AgentsApp, URL, Said) {
        setenv("UDECK_SETTING_CLAUDE", "\"\(fakeClaude.path)\"", 1)
        setenv("UDECK_SETTING_CODEX", "\"\(fakeCodex.path)\"", 1)
        setenv("FAKE_CLAUDE_DELAY", "0", 1)
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("agents-places-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let said = Said()
        return (AgentsApp(home: home) { said.lines.append($0) }, home, said)
    }

    func hello(_ app: AgentsApp, _ view: String, place: String = "card", keep: String? = nil) async {
        var event: [String: JSONValue] = ["event": "hello", "view": .string(view), "place": .string(place),
                                          "language": "en", "size": ["columns": 8, "rows": 6]]
        if let keep { event["keep"] = .string(keep) }
        await app.handle(try! JSONValue.object(event).encodedLine())
    }

    func conversation(_ app: AgentsApp, in home: URL) async throws -> Conversation {
        let before = Set(app.conversations.map(\.id))
        await app.newConversation(in: home, provider: .claude)
        let made = try #require(app.conversations.first { !before.contains($0.id) })
        try await until("started") { made.claude?.state == .idle }
        // Claude names its session in the first turn; the stand-in asks to
        // run a command in every one.
        made.send("Hello")
        let claude = try #require(made.claude)
        try await until("its question") { !claude.asks.isEmpty }
        claude.answer(claude.asks[0], with: .allow)
        try await until("its session") { claude.state == .idle && claude.sessionID != nil }
        return made
    }

    func close(_ app: AgentsApp) async {
        for conversation in app.conversations {
            for agent in conversation.agents.values { await agent.close() }
        }
    }

    @Test("the first place uDeck names is the card drawn until then; each card says its place, what it keeps and its name")
    func named() async throws {
        let (app, home, said) = app()
        defer { try? FileManager.default.removeItem(at: home) }
        app.render()
        #expect(JSONValue.line(Substring(said.lines.last ?? ""))?["view"] == nil, "before uDeck names a place, none is said")
        await hello(app, "B")
        #expect(app.places.keys.sorted() == ["B"])
        let x = try await conversation(app, in: home)
        app.render()
        let card = try #require(said.card("B"))
        let kept = try #require(card["keep"]?.string.flatMap(Kept.init))
        #expect(kept.id == x.id && kept.claude == x.claude?.sessionID && kept.account == "main")
        #expect(card["name"]?.string == x.title)
        await close(app)
    }

    @Test("a conversation sent to a place of its own leaves the board's, which shows another; choosing it brings its place forward")
    func sentApart() async throws {
        let (app, home, said) = app()
        defer { try? FileManager.default.removeItem(at: home) }
        await hello(app, "B")
        let x = try await conversation(app, in: home)
        let y = try await conversation(app, in: home)
        #expect(app.places["B"]?.selection == y.id, "the newest is shown")

        // uDeck opened a window for what the board showed.
        await hello(app, "W", place: "window", keep: Kept.of(y))
        #expect(app.places["W"]?.selection == y.id)
        #expect(app.places["B"]?.selection == x.id, "one conversation, one place: the board shows the other")
        app.render()
        let menu = try #require(said.card("B")?["card"]?["rows"]?[0]?["bar"]?["items"]?.array?
            .compactMap { $0["menu"] }.first?["options"]?.array)
        let note = menu.first { $0["id"]?.string == "s:" + y.id.uuidString }?["note"]?.string
        #expect(note?.contains(" · in a window · ") == true, "the folder, then where: \(String(describing: note))")

        // Chosen on the board: the window comes forward, the board stays.
        await app.handle(#"{"event":"choose","view":"B","row":"head","menu":"session","option":"s:\#(y.id.uuidString)"}"#)
        #expect(said.shown == ["W"])
        #expect(app.places["B"]?.selection == x.id)

        // A notification of the conversation in the window brings the window.
        await app.handle(#"{"event":"notification","view":"B","id":"\#(y.id.uuidString)"}"#)
        #expect(said.shown == ["W", "W"])

        // Back to the board: the board shows it; the one it showed waits in the menu.
        await app.handle(#"{"event":"closed","view":"W","keep":"","to":"B"}"#)
        #expect(app.places.keys.sorted() == ["B"])
        #expect(app.places["B"]?.selection == y.id)
        await close(app)
    }

    @Test("a place closed without going back leaves the board as it was; with every conversation elsewhere the board lists where")
    func closedAway() async throws {
        let (app, home, said) = app()
        defer { try? FileManager.default.removeItem(at: home) }
        await hello(app, "B")
        let x = try await conversation(app, in: home)
        await hello(app, "M", place: "mini", keep: Kept.of(x))
        #expect(app.places["M"]?.selection == x.id)
        #expect(app.places["B"]?.selection == nil, "nothing else to show")
        app.render()
        let rows = try #require(said.card("B")?["card"]?["rows"]?.array)
        #expect(rows.contains { $0["text"]?.string == "Every session is shown in another place. Choose one to bring it forward" })
        let chip = rows.compactMap { $0["chips"]?.array }.first?.first
        #expect(chip?["id"]?.string == "s:" + x.id.uuidString)
        #expect(chip?["text"]?.string?.contains("in a mini window") == true)

        // ＋ in the mini window: the new conversation opens there.
        await app.handle(#"{"event":"press","view":"M","id":"new"}"#)
        let pick = said.lines.compactMap { JSONValue.line(Substring($0))?["pick"]?["id"]?.string }.last
        #expect(pick == "new:claude@M")

        await app.handle(#"{"event":"closed","view":"M"}"#)
        #expect(app.places.keys.sorted() == ["B"])
        #expect(app.places["B"]?.selection == nil, "closing does not bring it back")
        #expect(app.conversations.map(\.id) == [x.id], "and does not end it")
        await close(app)
    }

    @Test("after a restart a place continues the Claude session uDeck kept for it, not held back")
    func restored() async throws {
        let (app, home, _) = app()
        defer { try? FileManager.default.removeItem(at: home) }
        let id = UUID().uuidString.lowercased()
        let folder = home.appendingPathComponent(".claude/projects/-tmp-work")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let lines = [
            #"{"type":"user","sessionId":"\#(id)","cwd":"\#(home.path)","message":{"role":"user","content":"look at it"},"timestamp":"2026-11-24T10:00:00Z"}"#,
            #"{"type":"last-prompt","lastPrompt":"look at it"}"#,
        ]
        try (lines.joined(separator: "\n") + "\n").write(to: folder.appendingPathComponent("\(id).jsonl"),
                                                         atomically: true, encoding: .utf8)
        await hello(app, "B", keep: Kept(id: UUID(), claude: id, account: "main").text)
        let session = try #require(app.conversations.first)
        #expect(app.places["B"]?.selection == session.id)
        #expect(app.heldBack.isEmpty, "its own session, written a moment ago by this plugin")
        #expect(session.folder.path == home.path)
        try await until("resumed") { session.claude?.state == .idle }
        await close(app)
    }

    @Test("what a place keeps reads back; anything else, or a session id that would leave its folder, does not")
    func kept() throws {
        let id = UUID()
        let kept = Kept(id: id, claude: "abc-123", account: "work", folder: "/tmp/x", title: "Fix it")
        #expect(Kept(kept.text) == kept)
        #expect(Kept(#"{"claude":"../../etc/passwd"}"#) == nil)
        #expect(Kept("not json") == nil)
        #expect(Kept("{}") == nil)
        let long = Kept(id: id, claude: "abc", folder: String(repeating: "f", count: 600), title: String(repeating: "t", count: 600))
        #expect(long.text.count <= Kept.limit)
        #expect(Kept(long.text)?.claude == "abc", "the title goes first, then the folder: the session stays")
    }
}
