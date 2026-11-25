import Foundation
import Testing
@testable import AgentsCore
import UDeckAgents

/// Closing a session: ✕ in the title line and by each open session in the
/// menu; every ✕ asks first (11-25)
@Suite("Closing a session", .serialized)
@MainActor
struct AgentsCloseTests {
    final class Said {
        var lines: [String] = []
        var cards: [JSONValue] { lines.compactMap { JSONValue.line(Substring($0))?["card"] } }
    }

    func app(delay: String = "0") -> (AgentsApp, URL, Said) {
        setenv("UDECK_SETTING_CLAUDE", "\"\(fakeClaude.path)\"", 1)
        setenv("FAKE_CLAUDE_DELAY", delay, 1)
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("agents-close-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let said = Said()
        return (AgentsApp(home: home, emit: { said.lines.append($0) }), home, said)
    }

    func head(_ said: Said) -> [JSONValue] {
        said.cards.last?["rows"]?.array?.first?["bar"]?["items"]?.array ?? []
    }

    func closeAsk(_ said: Said, for conversation: Conversation) -> JSONValue? {
        let rows = said.cards.last?["rows"]?.array ?? []
        return rows.compactMap { $0["ask"] }.first { $0["id"]?.string == "close-" + conversation.id.uuidString }
    }

    @Test("✕ in the title line and by each open session in the menu; every ✕ asks here, naming the session")
    func asksFirst() async throws {
        let (app, home, said) = app()
        defer { try? FileManager.default.removeItem(at: home) }
        await app.handle(#"{"event":"hello","size":{"columns":8,"rows":8},"language":"en"}"#)
        await app.newConversation(in: home, provider: .claude)
        await app.newConversation(in: home, provider: .claude)
        let first = try #require(app.conversations.first)
        let second = try #require(app.conversations.last)
        let claude = try #require(first.claude)
        try await until("idle") { claude.state == .idle && second.claude?.state == .idle }
        app.render()

        let items = head(said)
        #expect(items.contains { $0["button"]?["id"]?.string == "close" && $0["button"]?["label"]?.string == "✕" })
        let menu = try #require(items.compactMap { $0["menu"] }.first)
        let buttons = menu["options"]?.array?.compactMap { $0["button"]?["id"]?.string } ?? []
        #expect(Set(buttons) == ["close:" + first.id.uuidString, "close:" + second.id.uuidString])

        // By the menu: the one not shown — asked about here, without switching to it.
        let shown = try #require(app.selected?.id)
        let other = shown == first.id ? second : first
        await app.handle(#"{"event":"press","id":"close:\#(other.id.uuidString)"}"#)
        #expect(app.conversations.contains { $0.id == other.id }, "not closed without asking")
        #expect(app.selected?.id == shown, "the one shown stays shown")
        let asked = try #require(closeAsk(said, for: other))
        #expect(asked["title"]?.string == "Close «" + other.title + "»?")
        #expect(asked["buttons"]?.array?.compactMap { $0["label"]?.string } == ["Close", "Keep it"])
        await app.handle(#"{"event":"press","id":"closenow:\#(other.id.uuidString)"}"#)
        #expect(!app.conversations.contains { $0.id == other.id })
        try await until("the closed one's CLI ends") { other.claude?.isEnded == true }

        // By the title line: the one shown.
        await app.handle(#"{"event":"press","id":"close"}"#)
        #expect(app.conversations.count == 1)
        await app.handle(#"{"event":"press","id":"closenow:\#(shown.uuidString)"}"#)
        #expect(app.conversations.isEmpty)
        #expect(app.selected == nil)
        app.render()
        #expect(!head(said).contains { $0["button"]?["id"]?.string == "close" }, "nothing to close: no ✕")
    }

    @Test("a session in a turn asks first: Keep it keeps it, Stop and close closes it")
    func asksWhileWorking() async throws {
        let (app, home, said) = app(delay: "0.3")
        defer { try? FileManager.default.removeItem(at: home) }
        await app.handle(#"{"event":"hello","size":{"columns":8,"rows":8},"language":"ru"}"#)
        await app.newConversation(in: home, provider: .claude)
        let conversation = try #require(app.conversations.first)
        let claude = try #require(conversation.claude)
        try await until("idle") { claude.state == .idle }
        conversation.send("Look at the folder")
        try await until("working") { claude.state == .working }

        await app.handle(#"{"event":"press","id":"close"}"#)
        #expect(app.conversations.count == 1, "not closed in a turn without asking")
        app.render()
        let ask = try #require(closeAsk(said, for: conversation))
        #expect(ask["title"]?.string == "«" + conversation.title + "» сейчас работает — остановить и закрыть?")
        #expect(ask["buttons"]?.array?.compactMap { $0["id"]?.string }
                    == ["closenow:" + conversation.id.uuidString, "keepopen:" + conversation.id.uuidString])

        await app.handle(#"{"event":"press","id":"keepopen:\#(conversation.id.uuidString)"}"#)
        #expect(app.confirmingClose == nil && app.conversations.count == 1)

        await app.handle(#"{"event":"press","id":"close"}"#)
        await app.handle(#"{"event":"press","id":"closenow:\#(conversation.id.uuidString)"}"#)
        #expect(app.conversations.isEmpty)
        try await until("its CLI ends") { claude.isEnded }
    }
}
