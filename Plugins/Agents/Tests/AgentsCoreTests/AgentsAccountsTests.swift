import Foundation
import Testing
@testable import AgentsCore
import UDeckAgents

/// Accounts: their limits, «Авто»'s pick, and a session going on under
/// another account — or later — when its own ran out (spec §10.7, §10.18).
@Suite("Accounts, limits and Auto", .serialized)
@MainActor
struct AgentsAccountsTests {
    /// A home with the main account; `pers2` and `pers3`, mirrors of it whose
    /// sessions are the main one's (`projects` linked); and `solo`, an account
    /// of its own. The stand-in reads its limits from the account's folder —
    /// the main one's is the real `~/.claude`, so the tests limit the mirrors.
    func home() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("agents-accounts-" + UUID().uuidString)
        let manager = FileManager.default
        let main = home.appendingPathComponent(".claude")
        try manager.createDirectory(at: main.appendingPathComponent("projects"), withIntermediateDirectories: true)
        for name in ["pers2", "pers3", "solo"] {
            let folder = home.appendingPathComponent(".claude-" + name)
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: folder.appendingPathComponent(".claude.json"))
        }
        for name in ["pers2", "pers3"] {
            try manager.createSymbolicLink(at: home.appendingPathComponent(".claude-\(name)/projects"),
                                           withDestinationURL: main.appendingPathComponent("projects"))
        }
        try manager.createDirectory(at: home.appendingPathComponent(".claude-solo/projects"), withIntermediateDirectories: true)
        return home
    }

    func app(_ home: URL, said: Said = Said()) -> AgentsApp {
        setenv("UDECK_SETTING_CLAUDE", "\"\(fakeClaude.path)\"", 1)
        setenv("FAKE_CLAUDE_DELAY", "0", 1)
        unsetenv("UDECK_SETTING_ACCOUNT_MODE")
        return AgentsApp(home: home) { said.lines.append($0) }
    }

    final class Said {
        var lines: [String] = []
        var lastCard: JSONValue? {
            lines.reversed().compactMap { JSONValue.line(Substring($0))?["card"] }.first
        }
    }

    func usage(_ five: Double, _ week: Double, resets: Date = Date().addingTimeInterval(7200)) -> ClaudeUsage {
        let iso = ISO8601DateFormatter().string(from: resets)
        return ClaudeUsage(["rate_limits": ["five_hour": ["utilization": .number(five), "resets_at": .string(iso)],
                                            "seven_day": ["utilization": .number(week), "resets_at": .string(iso)]]])
    }

    @Test("limits are kept from what a turn says and what get_usage says, and a refusal holds until it resets")
    func limits() {
        let now = Date()
        var limits = AccountLimits()
        limits.note(ClaudeRateLimit(["status": "allowed", "rateLimitType": "five_hour", "utilization": 0.4]), at: now)
        #expect(limits.fiveHour?.used == 0.4)
        limits.note(ClaudeRateLimit(["status": "allowed", "rateLimitType": "seven_day_opus", "utilization": 0.7]), at: now)
        limits.note(ClaudeRateLimit(["status": "allowed", "rateLimitType": "seven_day", "utilization": 0.5]), at: now)
        #expect(limits.week?.used == 0.7, "a model's own week counts when it is the fuller one")
        let resets = now.addingTimeInterval(1800)
        limits.note(ClaudeRateLimit(["status": "rejected", "rateLimitType": "five_hour", "utilization": 1.0,
                                     "resetsAt": .number(resets.timeIntervalSince1970)]), at: now)
        #expect(limits.isLimited(at: now))
        #expect(!limits.isLimited(at: resets.addingTimeInterval(1)))
        #expect(limits.windows(now: now).contains { $0.name == "limit" && $0.used == 1 })
        limits.note(usage(20, 30), at: resets.addingTimeInterval(5))
        #expect(limits.limitedUntil == nil && limits.fiveHour?.used == 0.2)
    }

    @Test("Auto picks among the accounts, and a session goes on only where its sessions are shared")
    func pick() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home) }
        let app = app(home)
        #expect(app.accounts.map(\.name) == ["main", "pers2", "pers3", "solo"])
        let main = app.accounts[0], pers2 = app.accounts[1], solo = app.accounts[3]
        app.limits["pers3"] = AccountLimits(limitedUntil: Date().addingTimeInterval(600))
        #expect(app.sharesSessions(main, pers2))
        #expect(!app.sharesSessions(main, solo))
        app.limits["main"] = AccountLimits(fiveHour: UsageWindow(used: 0.9, resetsAt: nil), week: UsageWindow(used: 0.7, resetsAt: nil))
        app.limits["pers2"] = AccountLimits(fiveHour: UsageWindow(used: 0.1, resetsAt: nil), week: UsageWindow(used: 0.3, resetsAt: nil))
        app.limits["solo"] = AccountLimits(fiveHour: UsageWindow(used: 0.0, resetsAt: nil), week: UsageWindow(used: 0.0, resetsAt: nil))
        setenv("UDECK_SETTING_ACCOUNT_MODE", "\"headroom\"", 1)
        defer { unsetenv("UDECK_SETTING_ACCOUNT_MODE") }
        #expect(app.autoPick()?.account == solo, "the most left")
        #expect(app.autoPick(excluding: ["main"], sharingWith: main)?.account == pers2, "solo does not share main's sessions")
        app.limits["pers2"]?.limitedUntil = Date().addingTimeInterval(600)
        #expect(app.autoPick(excluding: ["main"], sharingWith: main) == nil, "nothing to go on under")
    }

    @Test("with Auto on, a session whose account ran out goes on under a mirror, the message sent again and not shown twice")
    func movesOnTheLimit() async throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home) }
        // pers2 and solo at their limits, as the stand-in says to whoever asks.
        for name in ["pers2", "solo"] { try Data().write(to: home.appendingPathComponent(".claude-\(name)/fake-limited")) }
        let said = Said()
        let app = app(home, said: said)
        setenv("UDECK_SETTING_ACCOUNT_MODE", "\"spareMain\"", 1)
        defer { unsetenv("UDECK_SETTING_ACCOUNT_MODE") }
        await app.newConversation(in: home, provider: .claude)
        let conversation = try #require(app.conversations.first)
        let claude = try #require(conversation.claude)
        #expect(claude.account.name == "pers2", "the main one spared; nothing known yet: the user's order")
        try await until("idle") { claude.state == .idle }
        conversation.send("Look at the folder")
        // pers2 refuses; the session goes on under pers3 — not solo, whose
        // sessions are not pers2's, nor main, which is spared.
        try await until("going on under pers3") { claude.account.name == "pers3" && !claude.asks.isEmpty }
        let users = claude.items.filter { if case .user(_, "Look at the folder") = $0 { true } else { false } }
        #expect(users.count == 1)
        #expect(claude.items.contains { if case .note(_, let text) = $0 { text.hasPrefix("limit-move:pers2|pers3|") } else { false } })
        #expect(app.limits["pers2"]?.isLimited(at: Date()) == true)
        app.render()
        let note = try #require(said.lastCard.flatMap { card in
            card["rows"]?.array?.compactMap { $0["feed"]?.array }.first?.compactMap { $0["text"]?.string }
                .first { $0.contains("ran out of its limit") }
        })
        #expect(note.contains("pers2 ran out") && note.contains("went on under pers3"))
        claude.answer(claude.asks[0], with: .allow)
        try await until("the turn's end") { claude.state == .idle }
        for agent in conversation.agents.values { await agent.close() }
    }

    @Test("a week's limit met as claude 2.1.332 meets it — waiting for hours: the turn stops at once and goes on under a mirror, with what waited behind it")
    func movesOnAWeekLimit() async throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home) }
        try Data().write(to: home.appendingPathComponent(".claude-pers2/fake-limited-wait"))
        try Data().write(to: home.appendingPathComponent(".claude-solo/fake-limited"))
        let app = app(home)
        setenv("UDECK_SETTING_ACCOUNT_MODE", "\"spareMain\"", 1)
        defer { unsetenv("UDECK_SETTING_ACCOUNT_MODE") }
        await app.newConversation(in: home, provider: .claude)
        let conversation = try #require(app.conversations.first)
        let claude = try #require(conversation.claude)
        #expect(claude.account.name == "pers2")
        try await until("idle") { claude.state == .idle }
        conversation.send("Look at the folder")
        try await Task.sleep(for: .milliseconds(100))
        conversation.send("And the size?")
        try await until("going on under pers3", timeout: .seconds(15)) { claude.account.name == "pers3" }
        try await until("both answered", timeout: .seconds(20)) {
            for ask in claude.asks { claude.answer(ask, with: .allow) }
            return claude.state == .idle && claude.waitingMessages.isEmpty && claude.asks.isEmpty
        }
        let users = claude.items.compactMap { if case .user(_, let text) = $0 { text } else { nil } }
        #expect(users == ["Look at the folder", "And the size?"], "each once, in order")
        #expect(claude.unsentMessages.isEmpty)
        for agent in conversation.agents.values { await agent.close() }
    }

    @Test("a session continued from the history goes on under the account Auto picks, not the main one")
    func historyUnderAuto() async throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home) }
        let folder = home.appendingPathComponent(".claude/projects/-tmp")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let id = UUID().uuidString.lowercased()
        let transcript = folder.appendingPathComponent("\(id).jsonl")
        try (#"{"type":"user","sessionId":"\#(id)","cwd":"/tmp","message":{"role":"user","content":"look at it"},"timestamp":"2026-11-22T10:00:00Z"}"#
            + "\n").write(to: transcript, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: transcript.path)
        // The main account's week spent, as on 11-26; the mirrors with room.
        let week = { (used: Int) in #"{"five_hour":{"utilization":10,"resets_at":"2099-01-01T00:00:00Z"},"seven_day":{"utilization":\#(used),"resets_at":"2099-01-07T00:00:00Z"}}"# }
        try week(100).write(to: home.appendingPathComponent(".claude/fake-usage.json"), atomically: true, encoding: .utf8)
        try week(30).write(to: home.appendingPathComponent(".claude-pers2/fake-usage.json"), atomically: true, encoding: .utf8)
        try week(60).write(to: home.appendingPathComponent(".claude-pers3/fake-usage.json"), atomically: true, encoding: .utf8)
        let app = app(home)
        setenv("UDECK_SETTING_ACCOUNT_MODE", "\"headroom\"", 1)
        defer { unsetenv("UDECK_SETTING_ACCOUNT_MODE") }
        app.limits["main"] = AccountLimits(fiveHour: UsageWindow(used: 0.1, resetsAt: nil), week: UsageWindow(used: 1.0, resetsAt: nil))
        app.limits["pers2"] = AccountLimits(fiveHour: UsageWindow(used: 0.1, resetsAt: nil), week: UsageWindow(used: 0.3, resetsAt: nil))
        app.limits["pers3"] = AccountLimits(fiveHour: UsageWindow(used: 0.1, resetsAt: nil), week: UsageWindow(used: 0.6, resetsAt: nil))
        await app.handle(#"{"event":"select","id":"history"}"#)
        await app.handle(#"{"event":"select","id":"h:\#(id)"}"#)
        let claude = try #require(app.conversations.first?.claude)
        #expect(claude.account.name == "pers2", "Auto's pick among those that share the main one's sessions")
        for conversation in app.conversations { for agent in conversation.agents.values { await agent.close() } }
    }

    @Test("an account chosen by hand stays: the session waits for the reset and says so")
    func waitsWhenChosenByHand() async throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home) }
        try Data().write(to: home.appendingPathComponent(".claude-pers2/fake-limited"))
        let app = app(home)
        await app.handle(#"{"event":"hello","size":{"columns":8,"rows":6},"language":"en"}"#)
        await app.handle(#"{"event":"choose","row":"message","menu":"account","option":"pers2"}"#)
        #expect(!app.autoAccount)
        await app.newConversation(in: home, provider: .claude)
        let conversation = try #require(app.conversations.first)
        let claude = try #require(conversation.claude)
        try await until("idle") { claude.state == .idle }
        conversation.send("Look at the folder")
        try await until("the wait") {
            claude.items.contains { if case .note(_, let text) = $0 { text.hasPrefix("limit-stop:pers2|") } else { false } }
        }
        #expect(claude.account.name == "pers2")
        #expect(app.waitingForLimit[conversation.id] != nil)
        await app.handle(#"{"event":"choose","row":"message","menu":"account","option":"auto"}"#)
        #expect(app.autoAccount)
        for agent in conversation.agents.values { await agent.close() }
    }

    @Test("an account no session runs on is asked for its limits by a short run that sends nothing")
    func probe() async throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home) }
        let json = #"{"five_hour":{"utilization":64,"resets_at":"2099-01-01T00:00:00Z"},"seven_day":{"utilization":12,"resets_at":"2099-01-07T00:00:00Z"}}"#
        try Data(json.utf8).write(to: home.appendingPathComponent(".claude-pers2/fake-usage.json"))
        let said = Said()
        let app = app(home, said: said)
        await app.refreshOtherLimits(force: true)
        #expect(app.limits["pers2"]?.fiveHour?.used == 0.64)
        #expect(app.limits["pers2"]?.week?.used == 0.12)
        #expect(app.limits["main"]?.week?.used == 0.2, "the stand-in's own default")
        await app.handle(#"{"event":"hello","size":{"columns":8,"rows":6},"language":"ru"}"#)
        await app.newConversation(in: home, provider: .claude)
        let conversation = try #require(app.conversations.first)
        try await until("idle") { conversation.claude?.state == .idle }
        app.render()
        let pickers = try #require(said.lastCard?["rows"]?.array?.compactMap { $0["input"]?["pickers"]?.array }.first)
        let menu = try #require(pickers.first { $0["id"]?.string == "account" })
        #expect(menu["selected"]?.string == "auto")
        #expect(menu["text"]?.string?.hasPrefix("Авто · ") == true)
        let options = try #require(menu["options"]?.array)
        #expect(options.compactMap { $0["id"]?.string } == ["auto", "main", "pers2", "pers3", "solo"])
        #expect(options[0]["note"]?.string?.hasPrefix("сейчас ") == true)
        #expect(options[2]["note"]?.string == "5 ч 64% · неделя 12%")
        for agent in conversation.agents.values { await agent.close() }
    }
}
