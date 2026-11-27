import Foundation
import Testing
@testable import AgentsCore
import UDeckAgents

/// Files sent with a message (11-25): a picture goes to the agent as a
/// picture, any other file by its path; the feed says what went.
@Suite("Files with a message", .serialized)
@MainActor
struct AgentsFilesTests {
    final class Awake: SleepHolding {
        func hold(named name: String) -> Bool { true }
        func release() {}
        func others() -> [String] { [] }
        var hasALid: Bool { false }
    }

    /// A folder with a small picture, a big one and a text file.
    func files() throws -> (folder: URL, picture: URL, big: URL, text: URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("agents-files-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let picture = folder.appendingPathComponent("shot.png")
        try Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]).write(to: picture)
        let big = folder.appendingPathComponent("huge.jpg")
        try Data(count: SentFiles.biggestPicture + 1).write(to: big)
        let text = folder.appendingPathComponent("notes.txt")
        try "notes".write(to: text, atomically: true, encoding: .utf8)
        return (folder, picture, big, text)
    }

    @Test("pictures go as pictures, other files and a picture too big by path; the feed names them all")
    func split() throws {
        let (folder, picture, big, text) = try files()
        defer { try? FileManager.default.removeItem(at: folder) }
        let sent = SentFiles(paths: [picture.path, big.path, text.path, "relative/nope.txt"])
        #expect(sent.pictures == [picture])
        #expect(sent.others == [big, text])
        let (shown, told) = sent.message("Look")
        #expect(shown == "Look\n📎 shot.png, huge.jpg, notes.txt")
        #expect(told == "Look\n\nAttached files (read them):\n" + big.path + "\n" + text.path)
        #expect(sent.claudeImages().map(\.mediaType) == ["image/png"])
        #expect(SentFiles(paths: [picture.path]).message("").told == "See the attached picture.")
    }

    func app() async throws -> (AgentsApp, URL) {
        setenv("UDECK_SETTING_CLAUDE", "\"\(fakeClaude.path)\"", 1)
        setenv("UDECK_SETTING_CODEX", "\"\(fakeCodex.path)\"", 1)
        setenv("FAKE_CLAUDE_DELAY", "0", 1)
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("agents-files-home-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let app = AgentsApp(home: home, emit: { _ in }, keepAwake: KeepAwake(holder: Awake()))
        await app.handle(#"{"event":"hello","size":{"columns":8,"rows":8},"language":"en"}"#)
        return (app, home)
    }

    @Test("submitted with files: Claude is shown the picture, told the other file's path")
    func claude() async throws {
        let (folder, picture, _, text) = try files()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (app, home) = try await app()
        defer { try? FileManager.default.removeItem(at: home) }
        await app.newConversation(in: home, provider: .claude)
        let conversation = try #require(app.conversations.first)
        let claude = try #require(conversation.claude)
        try await until("idle") { claude.state == .idle }
        let line = try JSONValue.object(["event": "submit", "row": "message", "text": "What is here?",
                                         "files": [.string(picture.path), .string(text.path)]]).encodedLine()
        await app.handle(line)
        // The message is its text; its files go with it, drawn above it (uDeck 0.9.23).
        let message = try #require(claude.items.first { if case .user(_, "What is here?") = $0 { true } else { false } })
        let id = try #require(message.uuid)
        #expect(conversation.files(of: id) == [picture.path, text.path])
        let feed = try #require(AgentsCard.card(for: app)["rows"]?.array?.compactMap { $0["feed"]?.array }.first)
        let entry = try #require(feed.first { $0["text"]?.string == "What is here?" })
        #expect(entry["files"]?.array?.compactMap(\.string) == [picture.path, text.path])
        #expect(claude.lastSent?.images.count == 1)
        #expect(claude.lastSent?.payload?.contains(text.path) == true)
        try await until("the picture seen") {
            claude.items.contains { if case .assistant(_, let said, _) = $0 { said.contains("I see 1 picture") } else { false } }
        }
        for agent in conversation.agents.values { await agent.close() }
    }

    @Test("submitted with a picture alone: Codex is given it as a local image")
    func codex() async throws {
        let (folder, picture, _, _) = try files()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (app, home) = try await app()
        defer { try? FileManager.default.removeItem(at: home) }
        await app.newConversation(in: home, provider: .codex)
        let conversation = try #require(app.conversations.first)
        try await until("idle") { conversation.current.state == .idle }
        let line = try JSONValue.object(["event": "submit", "row": "message", "text": "",
                                         "files": [.string(picture.path)]]).encodedLine()
        await app.handle(line)
        try await until("the picture seen") {
            conversation.current.items.contains { if case .assistant(_, let said, _) = $0 { said.contains("1 picture") } else { false } }
        }
        // A picture with no words: an empty message, its picture drawn with it.
        let message = try #require(conversation.current.items.first { if case .user = $0 { true } else { false } })
        #expect(message.uuid.flatMap { conversation.files(of: $0) } == [picture.path])
        for agent in conversation.agents.values { await agent.close() }
    }

    @Test("the field takes files while the session can be written to")
    func fieldTakesFiles() async throws {
        let (app, home) = try await app()
        defer { try? FileManager.default.removeItem(at: home) }
        await app.newConversation(in: home, provider: .claude)
        let conversation = try #require(app.conversations.first)
        try await until("idle") { conversation.current.state == .idle }
        let rows = AgentsCard.body(app)
        let input = try #require(rows.compactMap { $0["input"] }.first)
        #expect(input["files"]?.bool == true)
        for agent in conversation.agents.values { await agent.close() }
    }
}
