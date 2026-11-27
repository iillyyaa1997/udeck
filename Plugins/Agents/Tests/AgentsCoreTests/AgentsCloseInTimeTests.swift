import Foundation
import Testing
import UDeckAgents
@testable import AgentsCore

/// A CLI that will not go when its stdin closes is stopped after the grace,
/// not waited for: Agents held uDeck's update 21 s waiting for one (11-27).
@Suite("Closing within the grace")
struct AgentsCloseInTimeTests {
    @Test("close(grace:) returns within the grace and the 3 s of SIGTERM, the CLI gone")
    func lingering() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("agents-linger-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let process = try AgentProcess(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: [fakeClaude.path],
                                       environment: ["PATH": "/usr/bin:/bin", "FAKE_CLAUDE_LINGER": "60"], directory: folder)
        let connection = ClaudeCodeConnection(channel: process)
        await connection.start()
        let started = ContinuousClock.now
        _ = await connection.close(grace: .milliseconds(500))
        let took = ContinuousClock.now - started
        #expect(took < .seconds(3), "SIGTERM ends the fake at once: \(took)")
        #expect(!process.isRunning)
    }

    @Test("exit(within:) gives nil after the limit while the program runs, its exit once it ends")
    func within() async throws {
        let sleeper = try AgentProcess(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"],
                                       environment: [:], directory: FileManager.default.temporaryDirectory)
        let started = ContinuousClock.now
        let none = await sleeper.exit(within: .milliseconds(300))
        #expect(none == nil)
        #expect(ContinuousClock.now - started < .seconds(2))
        _ = await sleeper.terminate(grace: .seconds(1))
        let quick = try AgentProcess(executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: [],
                                     environment: [:], directory: FileManager.default.temporaryDirectory)
        #expect(await quick.exit(within: .seconds(5)) != nil)
    }

    @Test("Names.within: nil after the limit even when the work never ends")
    func namesWithin() async {
        let started = ContinuousClock.now
        let answer = await AgentsApp.within(.milliseconds(200)) {
            await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
            return "never"
        }
        #expect(answer == nil)
        #expect(ContinuousClock.now - started < .seconds(2))
    }
}

/// What the CLI puts in as a user message itself — a background task's
/// notice — is a quiet note, not the person's bubble (the operator, 11-27).
@Suite("The CLI's own messages")
@MainActor
struct AgentsMachineMessagesTests {
    @Test("a task notice replayed is a note with its summary; the person's words stay a bubble")
    func taskNotice() async throws {
        let (session, folder) = try await startFake()
        defer { try? FileManager.default.removeItem(at: folder) }
        try await until("idle") { session.state == .idle }
        let notice = """
        <task-notification>
        <task-id>bug3s3zwy</task-id>
        <status>completed</status>
        <summary>Background command "Записать работу uDeck" completed (exit code 0)</summary>
        </task-notification>
        """
        session.receive(.userEcho(text: notice, raw: .null))
        #expect(!session.items.contains { if case .user = $0 { true } else { false } }, "no bubble of the person's")
        #expect(session.items.contains {
            if case .note(_, let text) = $0 { text == "task:Background command \"Записать работу uDeck\" completed (exit code 0)" } else { false }
        })
        session.receive(.userEcho(text: "<system-reminder>x</system-reminder>", raw: .null))
        #expect(!session.items.contains { if case .user = $0 { true } else { false } }, "a reminder is nothing at all")
        session.receive(.userEcho(text: "Посмотри логи", raw: .null))
        #expect(session.items.contains { if case .user(_, "Посмотри логи") = $0 { true } else { false } })
        let app = AgentsApp(home: folder) { _ in }
        #expect(AgentsCard.noteText("task:", app) == "A background task ended")
        await session.close()
    }
}
