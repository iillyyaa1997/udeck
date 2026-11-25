import AppKit
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
        await session.archive()
        await session.close()
    }

    final class Awake: SleepHolding {
        func hold(named name: String) -> Bool { true }
        func release() {}
        func others() -> [String] { [] }
        var hasALid: Bool { false }
    }

    /// A picture with `number` written on it, as a PNG.
    static func picture(_ number: String, at url: URL) throws {
        let image = NSImage(size: NSSize(width: 240, height: 120))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 240, height: 120).fill()
        (number as NSString).draw(at: NSPoint(x: 70, y: 25), withAttributes: [
            .font: NSFont.boldSystemFont(ofSize: 64), .foregroundColor: NSColor.black,
        ])
        image.unlockFocus()
        let tiff = try #require(image.tiffRepresentation)
        let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        try png.write(to: url)
    }

    @Test("Codex for real through Agents' code: its limits read, a picture seen, a name made and given to the thread")
    func realCodexThroughAgents() async throws {
        unsetenv("UDECK_SETTING_CODEX")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("udeck-real-codex-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let picture = folder.appendingPathComponent("number.png")
        try Self.picture("73", at: picture)
        let shell = try await ShellEnvironment.capture(shell: "/bin/zsh", home: NSHomeDirectory(), user: NSUserName())
        let codex = try #require(ShellEnvironment.resolve("codex", path: shell["PATH"] ?? ""))
        let session = CodexSession(folder: folder)
        session.effort = "low"
        await session.start(executable: codex, environment: shell)
        #expect(session.state == .idle, "\(session.items)")
        print("limits:", session.rateLimits.map { "\($0)" } ?? "none")
        #expect(session.rateLimits != nil, "account/rateLimits/read answered")

        let sent = SentFiles(paths: [picture.path])
        let (shown, told) = sent.message("What number is written on the attached picture? Reply with the number only. Do not run any commands.")
        session.send(shown, text: told, pictures: sent.pictures.map(\.path))
        try? await until("the real turn", timeout: .seconds(120)) { session.state == .idle && !session.lastAnswer.isEmpty }
        print("state:", session.state, "answer:", session.lastAnswer)
        print("items:", session.items.map { item -> String in
            switch item {
            case .user(_, let text): "user(\(text.prefix(40)))"
            case .assistant(_, let text, let streaming): "assistant(\(text.prefix(60)), streaming: \(streaming))"
            case .tool(_, let name, let summary, _): "tool(\(name) \(summary.prefix(40)))"
            case .note(_, let text): "note(\(text.prefix(200)))"
            }
        }, "asks:", session.asks.map(\.summary))
        #expect(session.lastAnswer.contains("73"), "the picture went as a local image and was seen")

        let app = AgentsApp(home: URL(fileURLWithPath: NSHomeDirectory()), emit: { _ in }, keepAwake: KeepAwake(holder: Awake()))
        let answer = await app.nameByCodex("Folder: notes\n\nPerson: Посмотри, почему падает тест логина в CI\n\nAgent: Смотрю логи CI",
                                           like: session)
        print("name:", answer ?? "none")
        let name = try #require(answer.flatMap { ChatNames.cleaned($0) })
        await session.setName(name)
        try await until("Codex says the thread's name back", timeout: .seconds(20)) { session.title == name }
        let listed = await session.savedThreads(limit: 20)
        print("listed:", listed.first { $0.id == session.threadID }.map { "\($0.title) \($0.source)" } ?? "not listed")
        await session.archive()
        await session.close()
    }
}
