import Foundation
import Testing
@testable import AgentsCore
import UDeckAgents

/// Against the person's own CLIs, only when asked (`REAL_CODEX=1`): one short
/// turn, to see the real protocol where the stand-in may have simplified it.
@Suite("Real agents", .serialized, .enabled(if: ProcessInfo.processInfo.environment["REAL_CODEX"] == "1"))
@MainActor
struct RealAgentTests {
    @Test("a real Codex turn: the answer streams, the turn completes, the context is reported")
    func realCodexTurn() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("udeck-real-codex-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let shell = try await ShellEnvironment.capture(shell: "/bin/zsh", home: NSHomeDirectory(), user: NSUserName())
        let codex = try #require(ShellEnvironment.resolve("codex", path: shell["PATH"] ?? ""))
        let session = CodexSession(folder: folder)
        session.effort = "low"
        await session.start(executable: codex, environment: shell)
        #expect(session.state == .idle, "\(session.items)")
        print("models:", session.models.map(\.value), "model:", session.model ?? "-", "effort:", session.effort ?? "-")
        session.send("Reply with exactly one word: ok. Do not run any commands.")
        try await until("the real turn", timeout: .seconds(120)) { session.state == .idle && !session.lastAnswer.isEmpty }
        print("answer:", session.lastAnswer, "context:", session.contextPercent.map { String(format: "%.2f%%", $0) } ?? "-")
        print("items:", session.items.map { item -> String in
            switch item {
            case .user: "user"
            case .assistant(_, let text, let streaming): "assistant(\(text.prefix(20)), streaming: \(streaming))"
            case .tool(_, let name, let summary, _): "tool(\(name) \(summary.prefix(30)))"
            case .note(_, let text): "note(\(text.prefix(60)))"
            }
        })
        #expect(session.lastAnswer.lowercased().contains("ok"))
        await session.close()
    }
}
