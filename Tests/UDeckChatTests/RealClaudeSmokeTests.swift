import Foundation
import Testing
@testable import UDeckChat
import UDeckAgents

/// The chat against the user's real `claude`, the way the chat window starts it:
/// the login shell's environment, `claude` found on its PATH, the user's own
/// settings and hooks. Runs only when asked (UDECK_REAL_CLAUDE=1) — it spends a
/// little of the account's limit, on the cheapest model.
@Suite("The chat against the real Claude Code", .enabled(if: ProcessInfo.processInfo.environment["UDECK_REAL_CLAUDE"] == "1"))
@MainActor
struct RealClaudeSmokeTests {
    @Test("a real turn: started as the window starts it, answered, finished")
    func realTurn() async throws {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let captured = try await ShellEnvironment.capture(shell: shell, home: home.path, user: NSUserName())
        let account = ChatAccount(name: "main", configDir: nil)
        let environment = account.environment(from: captured)
        let claude = try #require(ShellEnvironment.resolve("claude", path: environment["PATH"] ?? ""))
        let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["UDECK_REAL_CLAUDE_DIR"]
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("udeck-real-" + UUID().uuidString).path)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let arguments = ClaudeOutbound.arguments(model: "haiku", permissionMode: "default")
        let process = try AgentProcess(executable: claude, arguments: arguments, environment: environment, directory: folder)
        let session = ChatSession(folder: folder, account: account)
        await session.start(channel: process)
        try await until("ready", timeout: .seconds(60)) { session.state == .idle }
        session.send("Reply with exactly one word: hello")
        try await until("the turn's end", timeout: .seconds(120)) {
            if let ask = session.asks.first { session.answer(ask, with: .deny) }
            return session.state == .idle
        }
        print("real claude:", session.model ?? "?", session.sessionID ?? "?", "→", session.lastAnswer)
        #expect(!session.lastAnswer.isEmpty)
        #expect(session.sessionID != nil)
        await session.close()
    }
}
