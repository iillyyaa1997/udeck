import Foundation
import Testing
@testable import AgentsCore
import UDeckAgents

/// Codex's own limits shown on a Codex session's status line (11-25), as the
/// Claude accounts' are in their menu: read at the start, updated as Codex
/// says.
@Suite("Codex's limits", .serialized)
@MainActor
struct AgentsCodexLimitsTests {
    @Test("read when the session starts, said as they change, tinted as they fill")
    func shown() async throws {
        setenv("UDECK_SETTING_CODEX", "\"\(fakeCodex.path)\"", 1)
        setenv("FAKE_CLAUDE_DELAY", "0", 1)
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("agents-codex-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        var lines: [String] = []
        let app = AgentsApp(home: home, emit: { lines.append($0) })
        await app.handle(#"{"event":"hello","size":{"columns":8,"rows":8},"language":"ru"}"#)
        await app.newConversation(in: home, provider: .codex)
        let conversation = try #require(app.conversations.first)
        let codex = try #require(conversation.codex)
        try await until("idle") { codex.state == .idle }

        func badge() -> JSONValue? {
            app.render()
            let rows = lines.compactMap { JSONValue.line(Substring($0))?["card"] }.last?["rows"]?.array ?? []
            let status = rows.compactMap { $0["bar"] }.first { $0["id"]?.string == "status" }
            return status?["items"]?.array?.compactMap { $0["badge"] }.first { $0["icon"]?.string == "account" }
        }
        #expect(badge()?["text"]?.string == "5 ч 34% · неделя 12%")
        #expect(badge()?["tone"]?.string == "info")

        conversation.send("Look at the folder")
        try await until("the update") { codex.rateLimits?.primary?.usage.used == 0.81 }
        #expect(badge()?["text"]?.string == "5 ч 81% · неделя 13%")
        #expect(badge()?["tone"]?.string == "warn")
        for agent in conversation.agents.values { await agent.close() }
    }

    @Test("windows named by their length")
    func names() {
        let app = AgentsApp(home: FileManager.default.temporaryDirectory, emit: { _ in }, keepAwake: KeepAwake(holder: Fake()))
        #expect(AgentsCard.windowName(300, app) == "5h")
        #expect(AgentsCard.windowName(10080, app) == "week")
        #expect(AgentsCard.windowName(2880, app) == "2d")
        #expect(AgentsCard.windowName(nil, app) == "limit")
    }

    final class Fake: SleepHolding {
        func hold(named name: String) -> Bool { true }
        func release() {}
        func others() -> [String] { [] }
        var hasALid: Bool { false }
    }
}
