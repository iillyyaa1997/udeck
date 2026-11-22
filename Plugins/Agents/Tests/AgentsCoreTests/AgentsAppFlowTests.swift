import Foundation
import Testing
@testable import AgentsCore
import UDeckAgents

/// The app driven by events, over the stand-in CLIs: what the card's buttons
/// and menus do.
@Suite("The app over the stand-ins", .serialized)
@MainActor
struct AgentsAppFlowTests {
    func app() -> (AgentsApp, URL) {
        setenv("UDECK_SETTING_CLAUDE", "\"\(fakeClaude.path)\"", 1)
        setenv("UDECK_SETTING_CODEX", "\"\(fakeCodex.path)\"", 1)
        setenv("FAKE_CLAUDE_DELAY", "0", 1)
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("agents-flow-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return (AgentsApp(home: home) { _ in }, home)
    }

    @Test("a question answered from its button; then the conversation moves to Codex and back, each told what it missed")
    func questionThenHandoff() async throws {
        let (app, home) = app()
        defer { try? FileManager.default.removeItem(at: home) }
        await app.handle(#"{"event":"hello","size":{"columns":8,"rows":6},"language":"en"}"#)
        await app.newConversation(in: home, provider: .claude)
        let conversation = try #require(app.conversations.first)
        guard case .claude(let claude) = conversation.current else { Issue.record("not Claude"); return }
        try await until("idle") { claude.state == .idle }
        conversation.send("Ask me a question")
        try await until("the question") { !claude.asks.isEmpty }
        let request = try #require(claude.asks.first?.requestID)
        await app.handle(#"{"event":"press","id":"opt:\#(request):1"}"#)
        #expect(claude.asks.isEmpty, "the answer took the question away")
        try await until("the turn's end") { claude.state == .idle }
        #expect(claude.lastAnswer.contains("Orange"))

        await app.handle(#"{"event":"choose","row":"message","menu":"model","option":"codex:fake-codex-1"}"#)
        try await until("Codex") { conversation.active == .codex && conversation.codex?.state == .idle }
        #expect(conversation.feed.contains { if case .note(_, let text) = $0.item { text.hasPrefix("handoff:codex|") } else { false } })
        conversation.send("What changed?")
        let codex = try #require(conversation.codex)
        try await until("Codex's approval") { !codex.asks.isEmpty }
        await app.handle(#"{"event":"press","id":"allow:\#(codex.asks[0].requestID)"}"#)
        try await until("Codex's turn") { codex.state == .idle && codex.lastAnswer.contains("Notes.md") }
        #expect(codex.lastAnswer.contains("Notes.md"))

        await app.handle(#"{"event":"choose","row":"message","menu":"model","option":"claude:fake"}"#)
        try await until("Claude again") { conversation.active == .claude }
        let labels = conversation.feed.compactMap(\.label)
        #expect(Set(labels) == ["Claude", "Codex"], "once both answered, each answer says who gave it")
        for agent in conversation.agents.values { await agent.close() }
    }
}
