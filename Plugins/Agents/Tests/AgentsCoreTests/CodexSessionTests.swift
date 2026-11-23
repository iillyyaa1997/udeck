import Foundation
import Testing
@testable import AgentsCore
import UDeckAgents

let fakeCodex = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("fake-codex.py")

@Suite("A chat session over a Codex thread", .serialized)
@MainActor
struct CodexSessionTests {
    func started() async throws -> (CodexSession, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("udeck-codex-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let session = CodexSession(folder: folder)
        await session.start(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: [fakeCodex.path, "app-server"],
                            environment: ["PATH": "/usr/bin:/bin"])
        return (session, folder)
    }

    @Test("a turn: the answer streamed, a command asked about, allowed, its output, the closing words, the context")
    func allowedTurn() async throws {
        let (session, folder) = try await started()
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(session.state == .idle)
        #expect(session.models.map(\.value) == ["fake-codex-1", "fake-codex-mini"])
        #expect(session.effort == "medium", "the thread's effort, as the server said")
        session.send("What changed?")
        try await until("the approval") { !session.asks.isEmpty }
        let ask = try #require(session.asks.first)
        #expect(ask.summary == "git status --short")
        session.answer(ask, with: "accept")
        try await until("the turn's end") { session.state == .idle }
        #expect(session.items.contains { if case .tool(_, "Shell", "git status --short", let result) = $0 { result?.preview.contains("Notes.md") == true } else { false } })
        #expect(session.lastAnswer == "One file changed: Notes.md.")
        let percent = try #require(session.contextPercent)
        #expect(abs(percent - 41000.0 / 272000.0 * 100) < 0.01)
        await session.close()
    }

    @Test("what Codex is told can differ from what the feed shows: the conversation handed over")
    func handedText() async throws {
        let (session, folder) = try await started()
        defer { try? FileManager.default.removeItem(at: folder) }
        session.send("Go on", text: "[This conversation was carried on with another assistant…]\n\nGo on")
        try await until("the answer") { session.items.contains { if case .assistant(_, let text, false) = $0 { text.contains("handed over") } else { false } } }
        #expect(session.items.first == .user(id: { if case .user(let id, _) = session.items.first! { id } else { UUID() } }(), text: "Go on"))
        if let ask = session.asks.first { session.answer(ask, with: "decline") }
        try await until("the turn's end") { session.state == .idle }
        await session.close()
    }

    @Test("a saved thread continued: its turns read back oldest first, then the resume noted; the saved list leaves ephemeral ones out")
    func savedThread() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("udeck-codex-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let session = CodexSession(folder: folder, title: "Fix the notes", threadID: "saved-thread-1")
        await session.start(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: [fakeCodex.path, "app-server"],
                            environment: ["PATH": "/usr/bin:/bin"])
        let texts = session.items.map { item -> String in
            switch item {
            case .user(_, let text): "user:" + text
            case .assistant(_, let text, _): "assistant:" + text
            case .tool(_, let name, let summary, _): "tool:" + name + " " + summary
            case .note(_, let text): "note:" + text
            }
        }
        #expect(texts == ["user:Fix the notes", "tool:Shell ls", "assistant:Fixed.", "user:and now?", "assistant:Done.", "note:resumed"])
        let saved = await session.savedThreads()
        #expect(saved.map(\.id) == ["saved-thread-1"])
        #expect(saved.first?.title == "Fix the notes")
        await session.close()
    }
}

