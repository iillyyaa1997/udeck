import Foundation
import Testing
@testable import AgentsCore
import UDeckAgents

/// Notifications that can be answered where they show: an ask's buttons, a
/// question's options and an answer of one's own, a message after a turn.
@Suite("Answered from a notification", .serialized)
@MainActor
struct AgentsNoticeTests {
    final class Said {
        var lines: [String] = []
        var values: [JSONValue] { lines.compactMap { JSONValue.line(Substring($0)) } }
        var notices: [JSONValue] { values.compactMap { $0["notify"] } }
        var withdrawn: [String] { values.compactMap { $0["unnotify"]?["id"]?.string } }
    }

    func app() -> (AgentsApp, URL, Said) {
        setenv("UDECK_SETTING_CLAUDE", "\"\(fakeClaude.path)\"", 1)
        setenv("UDECK_SETTING_CODEX", "\"\(fakeCodex.path)\"", 1)
        setenv("FAKE_CLAUDE_DELAY", "0", 1)
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("agents-notice-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let said = Said()
        return (AgentsApp(home: home) { said.lines.append($0) }, home, said)
    }

    @Test("a permission asked: Allow, Allow in session and Deny in the notification; pressed there, it is answered and withdrawn")
    func permission() async throws {
        let (app, home, said) = app()
        defer { try? FileManager.default.removeItem(at: home) }
        await app.handle(#"{"event":"hello","size":{"columns":8,"rows":6},"language":"en"}"#)
        await app.newConversation(in: home, provider: .claude)
        let conversation = try #require(app.conversations.first)
        let claude = try #require(conversation.claude)
        try await until("idle") { claude.state == .idle }
        conversation.send("Look at the folder")
        try await until("the ask") { !claude.asks.isEmpty }
        let request = claude.asks[0].requestID
        let notice = try #require(said.notices.last)
        #expect(notice["id"]?.string == conversation.id.uuidString)
        #expect(notice["actions"]?.array?.compactMap { $0["id"]?.string } == ["allow:\(request)", "always:\(request)", "deny:\(request)"])
        #expect(notice["actions"]?.array?.compactMap { $0["text"]?.string } == ["Allow", "Allow in session", "Deny"])
        #expect(notice["reply"] == nil)

        await app.handle(#"{"event":"notification","id":"\#(conversation.id.uuidString)","action":"allow:\#(request)"}"#)
        #expect(claude.asks.isEmpty, "answered from the notification")
        #expect(said.withdrawn == [conversation.id.uuidString], "and the notification taken away")
        #expect(app.selection == conversation.id)
        try await until("the turn's end") { claude.state == .idle }

        // Pressed again — an old notification: nothing happens.
        await app.handle(#"{"event":"notification","id":"\#(conversation.id.uuidString)","action":"deny:\#(request)"}"#)
        #expect(claude.state == .idle)

        // Done: a field to reply in; a reply is the next message.
        let done = try #require(said.notices.last)
        #expect(done["actions"] == nil)
        #expect(done["reply"]?["button"]?.string == "Reply")
        await app.handle(#"{"event":"notification","id":"\#(conversation.id.uuidString)","text":"  Look again  "}"#)
        try await until("the next turn's ask") { !claude.asks.isEmpty }
        #expect(conversation.feed.contains { if case .user(_, let text) = $0.item { text == "Look again" } else { false } })
        for agent in conversation.agents.values { await agent.close() }
    }

    @Test("a question asked: two options and a field; an answer of one's own written there answers it")
    func question() async throws {
        let (app, home, said) = app()
        defer { try? FileManager.default.removeItem(at: home) }
        await app.handle(#"{"event":"hello","size":{"columns":8,"rows":6},"language":"ru"}"#)
        await app.newConversation(in: home, provider: .claude)
        let conversation = try #require(app.conversations.first)
        let claude = try #require(conversation.claude)
        try await until("idle") { claude.state == .idle }
        conversation.send("Ask me a question")
        try await until("the question") { !claude.asks.isEmpty }
        let request = claude.asks[0].requestID
        let notice = try #require(said.notices.last)
        #expect(notice["body"]?.string == "Which colour should the badge be?")
        #expect(notice["actions"]?.array?.compactMap { $0["id"]?.string } == ["opt:\(request):0", "opt:\(request):1"])
        #expect(notice["actions"]?.array?.compactMap { $0["text"]?.string } == ["Blue", "Orange"])
        #expect(notice["reply"]?["button"]?.string == "Свой ответ…")

        await app.handle(#"{"event":"notification","id":"\#(conversation.id.uuidString)","text":"Green"}"#)
        #expect(claude.asks.isEmpty)
        #expect(said.withdrawn.contains(conversation.id.uuidString))
        try await until("the answer") { claude.state == .idle && claude.lastAnswer.contains("Green") }
        for agent in conversation.agents.values { await agent.close() }
    }
}
