import Foundation
import Testing
@testable import AgentsCore
import UDeckAgents

/// A message written while the agent works (11-25): the card shows it last,
/// waiting, and then where the agent took it.
@Suite("Messages written while the agent works", .serialized)
@MainActor
struct AgentsWaitingTests {
    final class Awake: SleepHolding {
        func hold(named name: String) -> Bool { true }
        func release() {}
        func others() -> [String] { [] }
        var hasALid: Bool { false }
    }

    func app() async throws -> (AgentsApp, URL) {
        setenv("UDECK_SETTING_CLAUDE", "\"\(fakeClaude.path)\"", 1)
        setenv("UDECK_SETTING_CODEX", "\"\(fakeCodex.path)\"", 1)
        setenv("FAKE_CLAUDE_DELAY", "0", 1)
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("agents-waiting-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let app = AgentsApp(home: home, emit: { _ in }, keepAwake: KeepAwake(holder: Awake()))
        await app.handle(#"{"event":"hello","size":{"columns":8,"rows":8},"language":"en"}"#)
        return (app, home)
    }

    func feed(_ app: AgentsApp) throws -> [JSONValue] {
        let feeds = AgentsCard.body(app).compactMap { $0["feed"]?.array }
        return try #require(feeds.first)
    }

    func submit(_ app: AgentsApp, _ text: String) async throws {
        await app.handle(try JSONValue.object(["event": "submit", "row": "message", "text": .string(text)]).encodedLine())
    }

    @Test("the message waits last in the feed, said to go in after the current step, then stands where it was taken")
    func waitingThenTaken() async throws {
        let (app, home) = try await app()
        defer { try? FileManager.default.removeItem(at: home) }
        await app.newConversation(in: home, provider: .claude)
        let conversation = try #require(app.conversations.first)
        let claude = try #require(conversation.claude)
        try await until("idle") { claude.state == .idle }
        try await submit(app, "Look at the folder")
        try await until("the ask") { claude.asks.count == 1 }
        try await submit(app, "Ask me a question")
        let last = try #require(try feed(app).last)
        #expect(last["role"]?.string == "user" && last["text"]?.string == "Ask me a question")
        #expect(last["label"]?.string == "goes in after the current step")
        claude.answer(claude.asks[0], with: .allow)
        try await until("the question") { claude.asks.first?.ask.toolName == "AskUserQuestion" }
        let entries = try feed(app)
        let taken = try #require(entries.firstIndex { $0["text"]?.string == "Ask me a question" })
        #expect(entries[taken]["label"] == nil, "taken: no longer waiting")
        #expect(entries[taken - 1]["role"]?.string == "tool", "after the step it waited for")
        let ask = claude.asks[0]
        claude.answer(ask, with: .choices([ask.ask.questions![0].question: ["Blue"]]))
        try await until("the turn's end") { claude.state == .idle }
        for agent in conversation.agents.values { await agent.close() }
    }
}
