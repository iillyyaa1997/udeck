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
        // The approval comes after the answer's words: waited for, not looked for once.
        try await until("the approval") { !session.asks.isEmpty }
        session.answer(try #require(session.asks.first), with: "decline")
        try await until("the turn's end") { session.state == .idle }
        await session.close()
    }

    func index(_ session: CodexSession, _ match: (FeedItem) -> Bool) throws -> Int {
        let found = session.items.firstIndex(where: match)
        return try #require(found)
    }

    func answers(_ session: CodexSession, _ text: String) -> Int {
        session.items.filter { if case .assistant(_, text, false) = $0 { true } else { false } }.count
    }

    @Test("a message sent while a command waits is steered into the turn: it waits, goes in after the command, one turn")
    func steered() async throws {
        let (session, folder) = try await started()
        defer { try? FileManager.default.removeItem(at: folder) }
        session.send("What changed?")
        try await until("the approval") { !session.asks.isEmpty }
        session.send("Also say which file")
        #expect(session.waitingMessages.map(\.text) == ["Also say which file"])
        try await Task.sleep(for: .milliseconds(300))
        session.answer(try #require(session.asks.first), with: "accept")
        try await until("the turn's end") { session.state == .idle }
        #expect(session.waitingMessages.isEmpty)
        let command = try index(session) { if case .tool(_, "Shell", _, let result) = $0 { result != nil } else { false } }
        let taken = try index(session) { if case .user(_, "Also say which file") = $0 { true } else { false } }
        let closing = try index(session) { if case .assistant(_, "One file changed: Notes.md.", false) = $0 { true } else { false } }
        #expect(command < taken && taken < closing, "after the command, before the words that follow it")
        #expect(answers(session, "Looking at it.") == 1, "one turn")
        await session.close()
    }

    @Test("a message the turn refuses to take waits for its end, and starts the next turn")
    func refusedSteer() async throws {
        let (session, folder) = try await started()
        defer { try? FileManager.default.removeItem(at: folder) }
        session.send("What changed?")
        try await until("the approval") { !session.asks.isEmpty }
        session.send("[refuse] and then?")
        try await Task.sleep(for: .milliseconds(300))
        #expect(session.waitingMessages.map(\.text) == ["[refuse] and then?"])
        session.answer(try #require(session.asks.first), with: "accept")
        try await until("the next turn's approval") { answers(session, "Looking at it.") == 2 && !session.asks.isEmpty }
        let closing = try index(session) { if case .assistant(_, "One file changed: Notes.md.", false) = $0 { true } else { false } }
        let taken = try index(session) { if case .user(_, "[refuse] and then?") = $0 { true } else { false } }
        #expect(closing < taken, "after the first turn")
        session.answer(try #require(session.asks.first), with: "decline")
        try await until("the second turn's end") { session.state == .idle }
        #expect(session.waitingMessages.isEmpty)
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

