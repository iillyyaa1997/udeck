import Foundation
import Testing
@testable import AgentsCore
import UDeckAgents

/// Stop, and a week's limit (11-26). claude 2.1.332 does not end a turn at a
/// limit: it waits hours for the reset, and the card said «Working»; Stop
/// reached it, but what was written meanwhile ran right after and met the
/// same limit. Now Stop stops everything and leaves what waited unsent — sent
/// again on «Send all», or put back into the field — and a limit stops the
/// turn at once, to go on elsewhere or later. Nothing is lost.
@Suite("Stop, unsent messages and a week's limit", .serialized)
@MainActor
struct AgentsStopTests {
    func fake(config: URL? = nil) async throws -> (ChatSession, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("udeck-stop-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var environment = ["PATH": "/usr/bin:/bin", "FAKE_CLAUDE_DELAY": "0"]
        if let config { environment["CLAUDE_CONFIG_DIR"] = config.path }
        let process = try AgentProcess(executable: URL(fileURLWithPath: "/usr/bin/python3"),
                                       arguments: [fakeClaude.path, "--replay-user-messages"],
                                       environment: environment, directory: folder)
        let session = ChatSession(folder: folder, account: ChatAccount(name: "main", configDir: nil))
        await session.start(channel: process)
        return (session, folder)
    }

    func users(_ session: ChatSession) -> [String] {
        session.items.compactMap { if case .user(_, let text) = $0 { text } else { nil } }
    }

    @Test("Stop stops everything: what waited is unsent and nothing runs after; «Send all» sends it, oldest first")
    func stopLeavesUnsent() async throws {
        let (session, folder) = try await fake()
        defer { try? FileManager.default.removeItem(at: folder) }
        session.send("[hang] look")
        try await until("the turn") { session.state == .working }
        try await Task.sleep(for: .milliseconds(200))
        session.send("second")
        session.send("third")
        #expect(session.waitingMessages.map(\.text) == ["second", "third"])
        session.interrupt()
        try await until("the stop") { session.state == .idle }
        #expect(session.unsentMessages.map(\.text) == ["second", "third"])
        #expect(session.waitingMessages.isEmpty)
        #expect(session.items.contains { if case .note(_, "stopped") = $0 { true } else { false } })
        // Before, the CLI ran them right after the stop: now nothing runs.
        try await Task.sleep(for: .milliseconds(500))
        #expect(session.state == .idle)
        #expect(!session.items.contains { if case .assistant = $0 { true } else { false } })
        session.sendUnsent()
        #expect(session.unsentMessages.isEmpty)
        try await until("both answered", timeout: .seconds(20)) {
            for ask in session.asks { session.answer(ask, with: .allow) }
            return session.state == .idle && session.waitingMessages.isEmpty && session.asks.isEmpty
        }
        #expect(users(session) == ["[hang] look", "second", "third"])
        await session.close()
    }

    @Test("«Into the field» takes the unsent ones out; none is left anywhere else")
    func takeUnsent() async throws {
        let (session, folder) = try await fake()
        defer { try? FileManager.default.removeItem(at: folder) }
        session.send("[hang] look")
        try await until("the turn") { session.state == .working }
        try await Task.sleep(for: .milliseconds(200))
        session.send("second")
        session.interrupt()
        try await until("the stop") { session.state == .idle && !session.unsentMessages.isEmpty }
        #expect(session.takeUnsent().map(\.text) == ["second"])
        #expect(session.unsentMessages.isEmpty)
        await session.close()
    }

    @Test("a week's limit stops the turn at once — not «working» for hours; what waited behind it waits for the person")
    func weekLimit() async throws {
        let config = FileManager.default.temporaryDirectory.appendingPathComponent("udeck-week-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: config) }
        try Data().write(to: config.appendingPathComponent("fake-limited-wait"))
        let (session, folder) = try await fake(config: config)
        defer { try? FileManager.default.removeItem(at: folder) }
        var resets: [Date?] = []
        session.onLimit = { resets.append($0) }
        session.send("look")
        try await Task.sleep(for: .milliseconds(100))
        session.send("second")
        try await until("the limit", timeout: .seconds(5)) { resets.count == 1 }
        #expect(session.state == .idle)
        let reset = try #require(resets.first ?? nil)
        #expect(reset.timeIntervalSinceNow > 5 * 86_400, "the week's reset, as the CLI said it")
        #expect(session.lastSent?.text == "look", "what goes again where it goes on")
        #expect(users(session) == ["look"])
        // Nothing to go on under now: what waited behind it is the person's.
        session.keepHeldAsUnsent()
        #expect(session.unsentMessages.map(\.text) == ["second"])
        await session.close()
    }

    @Test("Codex: Stop ends the turn, and what was steered and not taken is unsent")
    func codexStop() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("udeck-codex-stop-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let session = CodexSession(folder: folder)
        await session.start(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: [fakeCodex.path, "app-server"],
                            environment: ["PATH": "/usr/bin:/bin"])
        session.send("What changed?")
        try await until("the approval") { !session.asks.isEmpty }
        session.send("Also say which file")
        try await Task.sleep(for: .milliseconds(300))
        session.interrupt()
        try await until("the stop") { session.state == .idle }
        #expect(session.unsentMessages.map(\.text) == ["Also say which file"])
        #expect(session.waitingMessages.isEmpty)
        #expect(session.asks.isEmpty)
        #expect(session.items.contains { if case .note(_, "stopped") = $0 { true } else { false } })
        await session.close()
    }

    final class Said {
        var lines: [String] = []
        var lastCard: JSONValue? { lines.reversed().compactMap { JSONValue.line(Substring($0))?["card"] }.first }
    }

    @Test("the card: unsent messages labelled, «Send all» and «Into the field» under the feed; the field gets their text until sent from it")
    func card() async throws {
        setenv("UDECK_SETTING_CLAUDE", "\"\(fakeClaude.path)\"", 1)
        setenv("FAKE_CLAUDE_DELAY", "0", 1)
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("agents-unsent-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let said = Said()
        let app = AgentsApp(home: home) { said.lines.append($0) }
        await app.handle(#"{"event":"hello","size":{"columns":8,"rows":10},"language":"ru"}"#)
        await app.newConversation(in: home, provider: .claude)
        let conversation = try #require(app.conversations.first)
        let claude = try #require(conversation.claude)
        try await until("idle") { claude.state == .idle }
        await app.handle(#"{"event":"submit","row":"message","text":"[hang] look"}"#)
        try await until("the turn") { claude.state == .working }
        try await Task.sleep(for: .milliseconds(200))
        // Above the field, what it does: a call out, nothing back yet.
        app.render()
        let live = try #require(said.lastCard?["rows"]?.array?.compactMap { $0["bar"] }.first { $0["id"]?.string == "live" })
        let doing = live["items"]?.array?.first?["badge"]?["text"]?.string ?? ""
        #expect(doing.hasPrefix("✻ Отправляет запрос… · 0:0"), "\(doing)")
        await app.handle(#"{"event":"submit","row":"message","text":"second"}"#)
        await app.handle(#"{"event":"submit","row":"message","text":"third"}"#)
        await app.handle(#"{"event":"press","id":"stop"}"#)
        try await until("the stop") { claude.state == .idle && claude.unsentMessages.count == 2 }
        app.render()
        func rows() throws -> [JSONValue] { try #require(said.lastCard?["rows"]?.array) }
        let feed = try #require(try rows().compactMap { $0["feed"]?.array }.first)
        let unsent = feed.filter { $0["label"]?.string == "не отправлено" }.compactMap { $0["text"]?.string }
        #expect(unsent == ["second", "third"])
        #expect(feed.contains { $0["role"]?.string == "note" && $0["text"]?.string == "Остановлено" })
        #expect(try rows().allSatisfy { $0["bar"]?["id"]?.string != "live" }, "nothing runs")
        let bar = try #require(try rows().compactMap { $0["bar"] }.first { $0["id"]?.string == "unsent" })
        let items = bar["items"]?.array ?? []
        #expect(items.compactMap { $0["badge"]?["text"]?.string } == ["2 сообщения не отправлены"])
        #expect(items.compactMap { $0["button"]?["id"]?.string } == ["unsent:send", "unsent:field"])
        // Kept on disk: an update of uDeck restarts this plugin.
        let kept = UnsentStore.load(home: home)
        #expect(kept.entries.values.map(\.texts) == [["second", "third"]])
        await app.handle(#"{"event":"press","id":"unsent:field"}"#)
        let input = try #require(try rows().compactMap { $0["input"] }.first)
        #expect(input["fill"]?["text"]?.string == "second\nthird")
        #expect(try rows().allSatisfy { $0["bar"]?["id"]?.string != "unsent" })
        #expect(UnsentStore.load(home: home).entries.isEmpty)
        // Sent from the field: the fill is the person's text now, and goes.
        await app.handle(#"{"event":"submit","row":"message","text":"second and third, edited"}"#)
        let after = try #require(try rows().compactMap { $0["input"] }.first)
        #expect(after["fill"] == nil)
        for agent in conversation.agents.values { await agent.close() }
    }

    @Test("unsent messages come back when the session is open again — after this plugin started again")
    func restoredAfterARestart() async throws {
        setenv("UDECK_SETTING_CLAUDE", "\"\(fakeClaude.path)\"", 1)
        setenv("FAKE_CLAUDE_DELAY", "0", 1)
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("agents-unsent-back-" + UUID().uuidString)
        let folder = home.appendingPathComponent(".claude/projects/-tmp")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let id = UUID().uuidString.lowercased()
        let transcript = folder.appendingPathComponent("\(id).jsonl")
        try (#"{"type":"user","sessionId":"\#(id)","cwd":"/tmp","message":{"role":"user","content":"look at it"},"timestamp":"2026-11-22T10:00:00Z"}"#
            + "\n").write(to: transcript, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: transcript.path)
        var store = UnsentStore()
        store.set(ChatNames.key(.claude, id), ["second", "third"])
        store.save(home: home)
        let app = AgentsApp(home: home) { _ in }
        await app.handle(#"{"event":"select","id":"history"}"#)
        await app.handle(#"{"event":"select","id":"h:\#(id)"}"#)
        let conversation = try #require(app.conversations.first)
        #expect(conversation.unsentMessages.map(\.text) == ["second", "third"])
        for agent in conversation.agents.values { await agent.close() }
    }
}

/// The line above the field (the operator's «1», 11-26): what the agent
/// does, the turn's time and its tokens, as the terminal shows them.
@Suite("What the agent does now", .serialized)
@MainActor
struct AgentsLiveLineTests {
    @Test("a turn's activities in order, its tokens counted, nothing once it ends")
    func activities() async throws {
        let (session, folder) = try await startFake(delay: 0.02)
        defer { try? FileManager.default.removeItem(at: folder) }
        var seen: [AgentActivity] = []
        func look() { if let now = session.activity, seen.last != now { seen.append(now) } }
        session.send("Look at the folder")
        try await until("the ask") { look(); return !session.asks.isEmpty }
        #expect(session.activity == .asking)
        #expect(session.tokens.counted > 0, "the call's own count")
        session.answer(try #require(session.asks.first), with: .allow)
        try await until("the turn's end") { look(); return session.state == .idle }
        #expect(session.activity == nil)
        #expect(seen.first == .requesting)
        #expect(seen.contains(.writing))
        #expect(seen.contains(.preparing("Bash")) || seen.contains(.tool("Bash")))
        #expect(seen.contains(.asking))
        await session.close()
    }

    @Test("a call tried again is said: why, which attempt, when — not «working»")
    func retrying() async throws {
        let (session, folder) = try await startFake()
        defer { try? FileManager.default.removeItem(at: folder) }
        session.send("[retry] Look at the folder")
        try await until("the retry") {
            if case .retrying = session.activity { true } else { false }
        }
        guard case .retrying(let status, _, let attempt, let next)? = session.activity else { return }
        #expect(status == 529 && attempt == 1)
        #expect((next?.timeIntervalSinceNow ?? 0) > 5)
        try await until("going on") { session.activity != nil && !{ if case .retrying = session.activity { true } else { false } }() }
        try await until("the ask") { !session.asks.isEmpty }
        session.answer(try #require(session.asks.first), with: .deny)
        try await until("the turn's end") { session.state == .idle }
        await session.close()
    }

    @Test("the card's line: words, time and tokens; a retry in its own words")
    func line() throws {
        let app = AgentsApp(home: FileManager.default.temporaryDirectory) { _ in }
        #expect(AgentsCard.retryReason(status: 529, error: "overloaded_error", app) == "The server is overloaded (529)")
        #expect(AgentsCard.retryReason(status: nil, error: "", app) == "No connection to the server")
        var tokens = TurnTokens()
        tokens.call(87_200)
        #expect(AgentsCard.tokenCount(tokens, app) == "↓ 87.2k tokens")
        tokens.streamed(String(repeating: "a", count: 400))
        #expect(AgentsCard.tokenCount(tokens, app) == "↓ ~87.3k tokens")
        var few = TurnTokens()
        few.streamed("abcdefgh")
        #expect(AgentsCard.tokenCount(few, app) == "↓ ~2 tokens")
    }
}
