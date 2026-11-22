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
        let session = try #require(app.sessions.first)
        #expect(app.heldBack[session.id] != nil)
        #expect(session.state == .starting, "nothing was started")
        #expect(session.items.contains { if case .user(_, let text) = $0 { text == "look at it" } else { false } })
        #expect(!session.items.contains { if case .user(_, let text) = $0 { text.contains("task-notification") } else { false } })
        let card = try #require(said.last)
        #expect(card.contains("Эта сессия сейчас идёт в другом месте"))
        #expect(card.contains(#""enabled":false"#))
        await app.handle(#"{"event":"press","id":"drop:\#(session.id.uuidString)"}"#)
        #expect(app.sessions.isEmpty)
        #expect(app.heldBack.isEmpty)
    }
}
