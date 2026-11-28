import Foundation
import Testing
@testable import AgentsCore
import UDeckAgents

/// The context on the card as the operator built it (11-28), each part a
/// setting: what is kept of it as a session goes, the badge and its details,
/// the settings told while Agents runs, the preview for Settings, and when it
/// compacts in the pause.
@Suite("The context, as the operator built it")
@MainActor
struct AgentsContextTests {
    @Test("settings: from the environment as JSON, then as the settings event says; his set by default")
    func settings() {
        var settings = AgentsSettings(environment: ["UDECK_SETTING_CTX_BADGE": "\"percent\"", "UDECK_SETTING_CTX_PAUSE_AT": "80",
                                                    "UDECK_SETTING_KEEP_AWAKE": "false", "PATH": "/usr/bin"])
        #expect(settings.context.badge == "percent")
        #expect(settings.context.pauseAt == 80)
        #expect(settings.bool("keep_awake", true) == false)
        settings.update(.object(["ctx_badge": .string("tokens"), "ctx_pause_at": .number(20), "sleep_show": .string("two")]))
        #expect(settings.context.badge == "tokens")
        #expect(settings.context.pauseAt == 40, "kept inside the declared range")
        #expect(settings.sleepShown == "two")
        let standard = AgentsSettings().context
        #expect(standard.badge == "tokens" && standard.tone && standard.details == "click")
        #expect([standard.parts, standard.graph, standard.turns, standard.heavy, standard.cache, standard.week, standard.cost,
                 standard.model, standard.account, standard.auto, standard.compactNow, standard.compactHint, standard.fresh,
                 standard.pause, standard.mark].allSatisfy { $0 })
        #expect(standard.pauseAt == 70)
        #expect(AgentsSettings().sleepShown == "icon")
    }

    @Test("the track: live from each call, a tool's share of the growth, a turn's growth, a compaction and what it left")
    func track() {
        var track = ContextTrack()
        let start = Date()
        track.call(ClaudeCallUsage(input: 2, cacheRead: 40_000, cacheWritten: 8_000, output: 500), at: start)
        #expect(track.tokens == 48_502)
        track.tool(id: "tool-1", label: "Read agents.log")
        track.tool(id: "tool-2", label: "Bash swift test")
        track.call(ClaudeCallUsage(input: 2, cacheRead: 48_000, cacheWritten: 30_500, output: 300), at: start.addingTimeInterval(5))
        // 78 502 − 48 002 − 500 = 30 000, shared by the two.
        #expect(track.heavy.map(\.tokens) == [15_000, 15_000])
        track.turnEnded(at: start.addingTimeInterval(6), costUSD: 1.5, durationMs: 6000, apiMs: 4000)
        #expect(track.points.count == 1)
        #expect(track.growth == [78_802 - 48_002], "from the first call of the turn")
        #expect(track.costUSD == 1.5 && track.wallMs == 6000 && track.apiMs == 4000)
        #expect(track.cacheCold(now: start.addingTimeInterval(60)) != nil, "an hour's cache, warm a minute after")
        #expect(track.cacheCold(now: start.addingTimeInterval(4000)) == nil)

        track.compacted(at: start.addingTimeInterval(10), from: 78_802)
        track.summary("This session is being continued from a previous conversation…")
        track.measured(9_000, at: start.addingTimeInterval(20))
        #expect(track.compactions.count == 1)
        #expect(track.compactions[0].fromTokens == 78_802 && track.compactions[0].toTokens == 9_000)
        #expect(track.compactions[0].summary?.hasPrefix("This session") == true)
        #expect(track.tokens == 9_000)
        #expect(track.points.last?.compacted == true)
        #expect(track.heavy.isEmpty, "what took the most was compacted away")
    }

    @Test("a continued session's track from its transcript: turns, the line, what took the most, a compaction, the cache")
    func rebuilt() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("transcript-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: file) }
        func usage(_ read: Int, _ out: Int) -> String {
            #"{"input_tokens":2,"cache_read_input_tokens":\#(read),"cache_creation_input_tokens":100,"output_tokens":\#(out),"cache_creation":{"ephemeral_1h_input_tokens":100,"ephemeral_5m_input_tokens":0}}"#
        }
        let now = Date()
        let stamp = { (minutes: Double) in
            let format = ISO8601DateFormatter()
            format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return format.string(from: now.addingTimeInterval(minutes * 60))
        }
        let lines = [
            #"{"type":"user","timestamp":"\#(stamp(-50))","message":{"role":"user","content":"look at the log"}}"#,
            #"{"type":"assistant","timestamp":"\#(stamp(-49))","message":{"usage":\#(usage(20_000, 100)),"content":[{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":"/tmp/agents.log"}}]}}"#,
            #"{"type":"user","timestamp":"\#(stamp(-49))","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"..."}]}}"#,
            #"{"type":"assistant","timestamp":"\#(stamp(-48))","message":{"usage":\#(usage(60_000, 300)),"content":[{"type":"text","text":"it says…"}]}}"#,
            #"{"type":"assistant","isSidechain":true,"timestamp":"\#(stamp(-47))","message":{"usage":\#(usage(900_000, 1)),"content":[]}}"#,
            #"{"type":"user","timestamp":"\#(stamp(-40))","message":{"role":"user","content":"and now?"}}"#,
            #"{"type":"assistant","timestamp":"\#(stamp(-39))","message":{"usage":\#(usage(70_000, 200)),"content":[{"type":"text","text":"now…"}]}}"#,
            #"{"type":"system","subtype":"compact_boundary","timestamp":"\#(stamp(-30))","compactMetadata":{"trigger":"manual","preTokens":70300}}"#,
            #"{"type":"user","timestamp":"\#(stamp(-29))","isCompactSummary":true,"message":{"role":"user","content":"This session is being continued…"}}"#,
            #"{"type":"user","timestamp":"\#(stamp(-20))","message":{"role":"user","content":"go on"}}"#,
            #"{"type":"assistant","timestamp":"\#(stamp(-19))","message":{"model":"claude-opus-5-5","usage":\#(usage(9_000, 100)),"content":[{"type":"text","text":"on it"}]}}"#,
            #"{"type":"assistant","timestamp":"\#(stamp(-18))","message":{"model":"<synthetic>","content":[{"type":"text","text":"No response requested."}]}}"#,
        ]
        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        // Before the compaction: what the Read added.
        try (lines.prefix(7).joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        let before = ContextTrack.rebuilt(from: file)
        #expect(before.heavy.first?.label.hasPrefix("Read") == true, "\(before.heavy)")
        #expect(before.heavy.first?.tokens == 60_102 - 20_102 - 100)
        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        let track = ContextTrack.rebuilt(from: file)
        #expect(track.points.filter { !$0.compacted }.count == 2, "two turns ended before the last words: \(track.points)")
        #expect(track.heavy.isEmpty, "what took the most was compacted away")
        #expect(track.compactions.count == 1)
        #expect(track.compactions.first?.fromTokens == 70_300)
        #expect(track.compactions.first?.toTokens == 9_102)
        #expect(track.tokens == 9_202, "the last call: its prompt and its answer")
        #expect(track.cacheCold(now: now) != nil, "an hour's cache from a call 19 minutes ago")
        #expect(!track.isEmpty)
        #expect(track.model == "claude-opus-5-5", "the last real answer's model, not a synthetic one's")
        #expect(ContextTrack.rebuilt(from: file.appendingPathExtension("missing")).isEmpty)
    }

    @Test("with nothing known yet every part chosen is still there, saying when it will be")
    func nothingYet() throws {
        let app = app()
        let bare = ContextCard.Facts(tokens: 250_000, window: 1_000_000, model: "Opus 5.5", account: "main")
        let rows = try #require(ContextCard.badge(bare, ContextLook.standard, app)?["details"]?.array)
        let labels = rows.compactMap { $0["kv"]?[0]?.string }
        for label in ["How it grew", "To compaction", "Cache", "Week", "Session", "Model", "Account"] {
            #expect(labels.contains(label), "\(label) missing: \(labels)")
        }
        #expect(rows.contains { $0["text"]?.string == "nothing large yet" })
        #expect(rows.contains { $0["kv"]?[1]?.string == "main · its limit after a turn" })
    }

    func app() -> AgentsApp {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("agents-context-" + UUID().uuidString)
        return AgentsApp(home: home) { _ in }
    }

    func facts(percent: Int) -> ContextCard.Facts {
        ContextCard.Facts(tokens: percent * 10_000, window: 1_000_000,
                          parts: [.init(id: "messages", name: "", tokens: percent * 10_000 - 5_000, isBuffer: false),
                                  .init(id: "skills", name: "", tokens: 5_000, isBuffer: false),
                                  .init(id: "autocompact_buffer", name: "", tokens: 33_000, isBuffer: true)],
                          compactsAt: 967_000, turnGrowth: 24_000,
                          heavy: [.init(id: "a", label: "Read agents.log", tokens: 38_000)],
                          cacheCold: Date().addingTimeInterval(41 * 60), cacheWarm: true, costUSD: 114.5,
                          wallMs: 3_600_000, apiMs: 600_000, model: "Opus 5.5", effort: "xhigh", account: "pers2",
                          week: UsageWindow(used: 0.96, resetsAt: Date().addingTimeInterval(3600 * 30)), weekPerHour: 0.03)
    }

    @Test("the badge: each look, its tone as it fills, and on a click every part chosen, buttons last")
    func badge() throws {
        let app = app()
        var look = ContextLook.standard
        let badge = try #require(ContextCard.badge(facts(percent: 25), look, app))
        #expect(badge["text"]?.string == "25% · 250k / 1M")
        #expect(badge["shorter"]?.array?.first?.string == "25%")
        #expect(badge["tone"]?.string == "info")
        #expect(ContextCard.badge(facts(percent: 80), look, app)?["tone"]?.string == "warn")
        #expect(ContextCard.badge(facts(percent: 92), look, app)?["tone"]?.string == "crit")
        let details = try #require(badge["details"]?.array)
        #expect(details.first?["meter"]?["parts"]?.array?.count == 3)
        #expect(details.contains { $0["list"] != nil }, "what took the most")
        #expect(details.contains { $0["kv"]?[0]?.string == "Cache" })
        #expect(details.contains { $0["kv"]?[0]?.string == "Account" && $0["kv"]?[2]?.string == "crit" })
        #expect(details.last?["bar"]?["items"]?.array?.compactMap { $0["button"]?["id"]?.string }
                == ["ctx:compact", "ctx:hint", "ctx:fresh"])
        #expect(details.contains { $0["text"]?.string?.hasPrefix("≈ 18 turns") == true }, "(700k − 250k) / 24k at 70%")

        look.tone = false
        #expect(ContextCard.badge(facts(percent: 92), look, app)?["tone"]?.string == "info")
        look.badge = "percent"
        #expect(ContextCard.badge(facts(percent: 25), look, app)?["text"]?.string == "context 25%")
        look.badge = "pie"
        #expect(ContextCard.badge(facts(percent: 25), look, app)?["text"]?.string == "◔ 25%")
        look.badge = "strip"
        #expect(ContextCard.badge(facts(percent: 25), look, app)?["text"]?.string == "ⓘ", "the details still a click away")
        #expect(ContextCard.rows(facts(percent: 25), look, app).first?["meter"] != nil, "the strip under the line")
        look.details = "line"
        #expect(ContextCard.badge(facts(percent: 25), look, app) == nil)
        let line = try #require(ContextCard.rows(facts(percent: 25), look, app).last?["text"]?.string)
        #expect(line.hasPrefix("25% · 250k/1M") && line.contains("$114.50") && line.contains("pers2"), "\(line)")
        look.details = "off"
        look.badge = "none"
        #expect(ContextCard.badge(facts(percent: 25), look, app) == nil)
        #expect(ContextCard.rows(facts(percent: 25), look, app).isEmpty)

        var some = ContextLook.standard
        some.parts = false; some.graph = false; some.turns = false; some.heavy = false; some.cache = false
        some.week = false; some.cost = false; some.model = false; some.account = false; some.auto = false
        some.compactNow = false; some.compactHint = false; some.fresh = false
        let bare = try #require(ContextCard.badge(facts(percent: 25), some, app)?["details"]?.array)
        #expect(bare.count == 1 && bare[0]["meter"]?["parts"] == nil, "only how full it is")
    }

    @Test("compacted in the pause: on, idle, nothing waiting, past the share, not again within five minutes")
    func pause() {
        let look = ContextLook.standard
        func asks(_ idle: Bool = true, waiting: Int = 0, tokens: Int = 750, last: Date? = nil, _ change: (inout ContextLook) -> Void = { _ in }) -> Int? {
            var look = look
            change(&look)
            return AgentsApp.compactsInThePause(look: look, idle: idle, waiting: waiting, tokens: tokens, window: 1000,
                                                lastCompaction: last)
        }
        #expect(asks() == 75)
        #expect(asks(tokens: 690) == nil)
        #expect(asks(false) == nil)
        #expect(asks(waiting: 1) == nil)
        #expect(asks(last: Date().addingTimeInterval(-60)) == nil)
        #expect(asks(last: Date().addingTimeInterval(-600)) == 75)
        #expect(asks { $0.pause = false } == nil)
        #expect(asks { $0.pauseAt = 80 } == nil)
    }

    @Test("Settings is told what the context group does, and the settings event changes it at once")
    func previewAndSettings() async throws {
        final class Said { var lines: [String] = [] }
        let said = Said()
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("agents-preview-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let app = AgentsApp(home: home) { said.lines.append($0) }
        await app.handle(#"{"event":"preview","id":"context"}"#)
        let previews = said.lines.compactMap { JSONValue.line(Substring($0))?["preview"] }
        let preview = try #require(previews.last)
        #expect(preview["group"]?.string == "context")
        let rows = try #require(preview["card"]?["rows"]?.array)
        let status = try #require(rows.first { $0["bar"]?["id"]?.string == "status" })
        let badges = status["bar"]?["items"]?.array?.compactMap { $0["badge"]?["text"]?.string } ?? []
        #expect(badges.contains("25% · 249k / 1M"), "\(badges)")
        #expect(badges.contains("☕"))
        #expect(rows.contains { $0["meter"]?["parts"] != nil }, "the details, shown under it")

        said.lines.removeAll()
        await app.handle(#"{"event":"settings","settings":{"ctx_badge":"pie","sleep_show":"none","ctx_details":"line"}}"#)
        #expect(app.settings.context.badge == "pie")
        await app.handle(#"{"event":"preview","id":"context"}"#)
        let answers = said.lines.compactMap { JSONValue.line(Substring($0))?["preview"] }
        let again = try #require(answers.last)
        let shown = again["card"]?["rows"]?.array ?? []
        let texts = shown.compactMap { $0["bar"]?["items"]?.array }.flatMap { $0 }.compactMap { $0["badge"]?["text"]?.string }
        #expect(texts.contains("◔ 25%") && !texts.contains("☕"), "\(texts)")
        #expect(shown.contains { $0["text"]?.string?.hasPrefix("25% · 249k/1M") == true }, "the line")
        said.lines.removeAll()
        await app.handle(#"{"event":"preview","id":"sleep"}"#)
        #expect(said.lines.isEmpty, "the sleep group draws no preview")
    }
}
