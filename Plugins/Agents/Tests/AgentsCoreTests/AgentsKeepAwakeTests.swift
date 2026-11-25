import Foundation
import Testing
@testable import AgentsCore
import UDeckAgents

/// The Mac kept awake while an agent works, let go while it waits or is done,
/// and a sleep said in the feed of the session it stopped (11-25).
@Suite("Keeping the Mac awake", .serialized)
@MainActor
struct AgentsKeepAwakeTests {
    final class Holder: SleepHolding {
        var held = false
        var holds = 0
        var releases = 0
        var holders: [String] = ["Amphetamine", "caffeinate"]
        var lid = true
        func hold(named name: String) -> Bool {
            holds += 1
            held = true
            return true
        }
        func release() {
            releases += 1
            held = false
        }
        func others() -> [String] { holders }
        var hasALid: Bool { lid }
    }

    final class Clock {
        var wall = Date(timeIntervalSince1970: 1_800_000_000)
        var uptime: TimeInterval = 1000
        func awake(_ seconds: TimeInterval) {
            wall += seconds
            uptime += seconds
        }
        func asleep(_ seconds: TimeInterval) { wall += seconds }
    }

    final class Said {
        var lines: [String] = []
        var cards: [JSONValue] { lines.compactMap { JSONValue.line(Substring($0))?["card"] } }
        var lastCard: String { cards.last.flatMap { try? $0.encodedLine() } ?? "" }
    }

    func app(_ holder: Holder, _ clock: Clock) -> (AgentsApp, URL, Said) {
        setenv("UDECK_SETTING_CLAUDE", "\"\(fakeClaude.path)\"", 1)
        setenv("FAKE_CLAUDE_DELAY", "0.25", 1)
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("agents-awake-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let said = Said()
        let keepAwake = KeepAwake(holder: holder, clock: { (clock.wall, clock.uptime) })
        return (AgentsApp(home: home, emit: { said.lines.append($0) }, keepAwake: keepAwake), home, said)
    }

    @Test("held while a turn runs, said on the card with who else holds and the lid; let go when it asks")
    func heldWhileWorking() async throws {
        let holder = Holder()
        let (app, home, said) = app(holder, Clock())
        defer { try? FileManager.default.removeItem(at: home) }
        await app.handle(#"{"event":"hello","size":{"columns":8,"rows":8},"language":"en"}"#)
        await app.newConversation(in: home, provider: .claude)
        let conversation = try #require(app.conversations.first)
        let claude = try #require(conversation.claude)
        try await until("idle") { claude.state == .idle }
        app.render()
        #expect(!holder.held, "nothing works yet")

        conversation.send("Look at the folder")
        try await until("working") { claude.state == .working }
        app.render()
        #expect(holder.held)
        #expect(said.lastCard.contains("☕ The Mac stays awake while 1 session works"))
        #expect(said.lastCard.contains("Also keeping it awake: Amphetamine, caffeinate · Close the lid and it sleeps anyway"))

        try await until("the ask") { !claude.asks.isEmpty }
        app.render()
        #expect(!holder.held, "a question waits through a sleep: let go")
        #expect(!said.lastCard.contains("☕"))
        #expect(holder.holds == 1 && holder.releases == 1)
        for agent in conversation.agents.values { await agent.close() }
    }

    @Test("switched off in the plugin's settings: never held")
    func switchedOff() async throws {
        setenv("UDECK_SETTING_KEEP_AWAKE", "false", 1)
        defer { unsetenv("UDECK_SETTING_KEEP_AWAKE") }
        let holder = Holder()
        let (app, home, said) = app(holder, Clock())
        defer { try? FileManager.default.removeItem(at: home) }
        await app.handle(#"{"event":"hello","size":{"columns":8,"rows":8},"language":"en"}"#)
        await app.newConversation(in: home, provider: .claude)
        let conversation = try #require(app.conversations.first)
        let claude = try #require(conversation.claude)
        try await until("idle") { claude.state == .idle }
        conversation.send("Look at the folder")
        try await until("working") { claude.state == .working }
        app.render()
        #expect(holder.holds == 0)
        #expect(!said.lastCard.contains("☕"))
        for agent in conversation.agents.values { await agent.close() }
    }

    @Test("a sleep while a turn ran is said in that session's feed, in Russian too")
    func sleepSaid() async throws {
        let holder = Holder()
        let clock = Clock()
        let (app, home, _) = app(holder, clock)
        defer { try? FileManager.default.removeItem(at: home) }
        await app.handle(#"{"event":"hello","size":{"columns":8,"rows":8},"language":"ru"}"#)
        await app.newConversation(in: home, provider: .claude)
        let conversation = try #require(app.conversations.first)
        let claude = try #require(conversation.claude)
        try await until("idle") { claude.state == .idle }
        conversation.send("Look at the folder")
        try await until("working") { claude.state == .working }

        clock.awake(30)
        app.lookForASleep()  // a look while it works
        clock.awake(10)
        clock.asleep(45 * 60)
        app.lookForASleep()
        let notes = conversation.feed.compactMap { entry -> String? in
            if case .note(_, let text) = entry.item { text } else { nil }
        }
        #expect(notes.contains { $0.hasPrefix("💤 Мак спал 45 мин (") && $0.hasSuffix(") — агент стоял") }, "\(notes)")
        for agent in conversation.agents.values { await agent.close() }
    }

    @Test("a look running late is not a sleep; a sleep starts at the last look and stopped what worked then")
    func looks() throws {
        let clock = Clock()
        let keepAwake = KeepAwake(holder: Holder(), clock: { (clock.wall, clock.uptime) })
        let one = UUID()
        #expect(keepAwake.look(working: [one]) == nil)
        clock.awake(30)
        clock.asleep(40)
        #expect(keepAwake.look(working: []) == nil, "40 s behind is a late look")
        let before = clock.wall
        clock.asleep(80 * 60)
        clock.awake(5)
        let slept = keepAwake.look(working: [])
        #expect(slept?.from == before)
        let length = try #require(slept.map { $0.to.timeIntervalSince($0.from) })
        #expect(abs(length - 80 * 60) < 0.001, "\(length)")
        #expect(slept?.stopped == [], "nothing worked at the look before it")
    }

    @Test("how long, said: minutes, then hours and minutes")
    func lengths() {
        let app = AgentsApp(home: FileManager.default.temporaryDirectory, emit: { _ in },
                            keepAwake: KeepAwake(holder: Holder()))
        let from = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(app.sleptNote(from: from, to: from + 80 * 60).contains(" 1 h 20 min ("))
        #expect(app.sleptNote(from: from, to: from + 120 * 60).contains(" 2 h ("))
        #expect(AgentsApp.sessions(1) == "сессия" && AgentsApp.sessions(3) == "сессии" && AgentsApp.sessions(11) == "сессий")
    }
}
