import Foundation
import UDeckAgents

/// The context on the card, as the operator built it (11-28): a badge —
/// «25% · 249k / 1M», tinted as it fills — and, on a click, what it is made
/// of, how it grew, how many turns are left, what took the most, the cache,
/// the week, the session's cost and time, the model, the account, when it
/// compacts, and buttons. Each part a setting (`ContextLook`).
@MainActor
enum ContextCard {
    /// What is known of a session's context.
    struct Facts {
        var tokens: Int
        var window: Int
        var parts: [ClaudeContextUsage.Part] = []
        var compactsAt: Int?
        var points: [ContextTrack.Point] = []
        var compactions: [ContextTrack.Compaction] = []
        var turnGrowth: Int?
        var heavy: [ContextTrack.Piece] = []
        var cacheCold: Date?
        var cacheWarm = false
        var costUSD: Double?
        var wallMs = 0
        var apiMs = 0
        var model: String?
        var effort: String?
        var account: String?
        var week: UsageWindow?
        var weekPerHour: Double?

        var percent: Double { window > 0 ? Double(tokens) / Double(window) * 100 : 0 }
    }

    static func facts(_ session: Conversation, _ app: AgentsApp) -> Facts? {
        switch session.current {
        case .claude(let claude):
            guard let window = claude.context?.window, window > 0, let tokens = claude.contextTokens else { return nil }
            let track = claude.contextTrack
            let limits = app.limits[claude.account.name]
            return Facts(tokens: tokens, window: window, parts: claude.context?.parts ?? [],
                         compactsAt: claude.context?.compactsAt, points: track.points, compactions: track.compactions,
                         turnGrowth: track.turnGrowth, heavy: track.heavy, cacheCold: track.cacheCold(),
                         cacheWarm: track.lastCall != nil, costUSD: track.costUSD, wallMs: track.wallMs, apiMs: track.apiMs,
                         model: session.current.currentModel?.name, effort: session.current.effort.map { AgentsCard.effortName($0, app) },
                         account: claude.account.name, week: limits?.week, weekPerHour: limits?.weekPerHour())
        case .codex:
            guard let percent = session.current.contextPercent else { return nil }
            return Facts(tokens: Int(percent * 10_000), window: 1_000_000, model: session.current.currentModel?.name,
                         effort: session.current.effort.map { AgentsCard.effortName($0, app) })
        }
    }

    // MARK: - On the card

    /// The badge, by the look chosen — nil for none, or the strip — with its
    /// details when they are shown on a click.
    static func badge(_ facts: Facts, _ look: ContextLook, _ app: AgentsApp) -> JSONValue? {
        let percent = Int(facts.percent.rounded())
        let text: String
        var shorter: [String] = []
        switch look.badge {
        case "none", "strip":
            guard look.details == "click" else { return nil }
            text = "ⓘ"
        case "percent":
            text = app.t("контекст \(percent)%", "context \(percent)%")
            shorter = ["\(percent)%"]
        case "pie":
            text = pie(facts.percent) + " \(percent)%"
        default:
            text = "\(percent)% · \(tokens(facts.tokens)) / \(tokens(facts.window))"
            shorter = ["\(percent)%"]
        }
        var badge: [String: JSONValue] = ["text": .string(text), "tone": .string(tone(facts.percent, look))]
        if look.badge != "none", look.badge != "strip" { badge["fill"] = .number(min(1, facts.percent / 100)) }
        if !shorter.isEmpty { badge["shorter"] = .array(shorter.map { .string($0) }) }
        if look.details == "click" {
            let rows = details(facts, look, app)
            if !rows.isEmpty { badge["details"] = .array(rows) }
        }
        return .object(badge)
    }

    /// Rows under the card's line: the strip, and the details always shown.
    static func rows(_ facts: Facts, _ look: ContextLook, _ app: AgentsApp) -> [JSONValue] {
        var rows: [JSONValue] = []
        if look.badge == "strip" {
            rows.append(["meter": ["value": .number(min(1, facts.percent / 100)),
                                   "state": .string(state(facts.percent, look))]])
        }
        if look.details == "line" { rows.append(["text": .string(line(facts, look, app))]) }
        return rows
    }

    /// The details in one line: what fits of each part chosen.
    static func line(_ facts: Facts, _ look: ContextLook, _ app: AgentsApp) -> String {
        var bits = ["\(Int(facts.percent.rounded()))% · \(tokens(facts.tokens))/\(tokens(facts.window))"]
        if look.turns, let left = turnsLeft(facts, look) { bits.append(app.t("≈\(left) ходов", "≈\(left) turns")) }
        if look.cache, let cold = facts.cacheCold {
            bits.append(app.t("кэш \(minutes(cold.timeIntervalSinceNow)) мин", "cache \(minutes(cold.timeIntervalSinceNow)) min"))
        }
        if look.week, let rate = facts.weekPerHour { bits.append(app.t("+\(share(rate))% недели/ч", "+\(share(rate))% of the week/h")) }
        if look.cost, let cost = facts.costUSD { bits.append(String(format: "$%.2f", cost)) }
        if look.model, let model = facts.model { bits.append([model, facts.effort].compactMap { $0 }.joined(separator: " ")) }
        if look.account, let account = facts.account {
            bits.append(account + (facts.week.map { app.t(" · неделя \(Int(($0.used * 100).rounded()))%", " · week \(Int(($0.used * 100).rounded()))%") } ?? ""))
        }
        return bits.joined(separator: " · ")
    }

    /// The rows the badge shows when clicked, the parts chosen, in order.
    static func details(_ facts: Facts, _ look: ContextLook, _ app: AgentsApp) -> [JSONValue] {
        var rows: [JSONValue] = []
        let caption = app.t("\(tokens(facts.tokens)) из \(tokens(facts.window)) · \(Int(facts.percent.rounded()))%",
                            "\(tokens(facts.tokens)) of \(tokens(facts.window)) · \(Int(facts.percent.rounded()))%")
        let title = app.t("Контекст", "Context")
        if look.parts, !facts.parts.isEmpty {
            rows.append(["meter": ["value": .number(min(1, facts.percent / 100)), "label": .string(title),
                                   "caption": .string(caption), "parts": .array(parts(facts, app))]])
        } else {
            rows.append(["meter": ["value": .number(min(1, facts.percent / 100)), "label": .string(title),
                                   "caption": .string(caption), "state": .string(state(facts.percent, look))]])
        }
        if look.graph, facts.points.count >= 2 {
            let values = facts.points.suffix(60).map { JSONValue.number(facts.window > 0 ? Double($0.tokens) / Double(facts.window) : 0) }
            var said = app.t("Как рос за сессию", "How it grew this session")
            if let last = facts.compactions.last, let from = last.fromTokens, let to = last.toTokens, facts.window > 0 {
                said += app.t(" · сжат в \(clock(last.at)): \(pct(from, facts.window))% → \(pct(to, facts.window))%",
                              " · compacted at \(clock(last.at)): \(pct(from, facts.window))% → \(pct(to, facts.window))%")
            }
            rows.append(["spark": ["values": .array(Array(values)), "caption": .string(said)]])
        }
        if look.turns, let left = turnsLeft(facts, look), let growth = facts.turnGrowth {
            rows.append(["text": .string(app.t("≈ \(left) \(turnsWord(left)) до сжатия — сейчас ход добавляет ~\(tokens(growth))",
                                               "≈ \(left) turns to compaction — a turn adds ~\(tokens(growth)) now"))])
        }
        if look.heavy, !facts.heavy.isEmpty {
            rows.append(["text": .string(app.t("Больше всего заняли", "What took the most"))])
            rows.append(["list": .array(facts.heavy.prefix(4).map { piece in
                ["text": .string(String(piece.label.prefix(60))), "note": .string(tokens(piece.tokens))]
            })])
        }
        var pairs: [(String, String, String?)] = []
        if look.cache, facts.cacheWarm {
            if let cold = facts.cacheCold {
                pairs.append((app.t("Кэш", "Cache"), app.t("тёплый ещё \(minutes(cold.timeIntervalSinceNow)) мин",
                                                             "warm for \(minutes(cold.timeIntervalSinceNow)) more min"), "ok"))
            } else {
                pairs.append((app.t("Кэш", "Cache"), app.t("остыл: следующий ход прочтёт всё заново", "cold: the next turn reads it all again"), "warn"))
            }
        }
        if look.week, let rate = facts.weekPerHour {
            pairs.append((app.t("Неделя", "Week"), app.t("+\(share(rate))% за последний час", "+\(share(rate))% in the last hour"),
                          rate >= 0.02 ? "warn" : nil))
        }
        if look.cost, (facts.costUSD ?? 0) > 0 || facts.wallMs > 0 {
            var said = facts.costUSD.flatMap { $0 > 0 ? String(format: "$%.2f", $0) : nil } ?? ""
            if facts.wallMs > 0 {
                let spent = app.t("ходы \(duration(facts.wallMs, app)), модель \(duration(facts.apiMs, app))",
                                  "turns \(duration(facts.wallMs, app)), model \(duration(facts.apiMs, app))")
                said = said.isEmpty ? spent : said + " · " + spent
            }
            pairs.append((app.t("Сессия", "Session"), said, nil))
        }
        if look.model, let model = facts.model {
            pairs.append((app.t("Модель", "Model"), [model, facts.effort].compactMap { $0 }.joined(separator: " · "), nil))
        }
        if look.account, let account = facts.account {
            var said = account
            if let week = facts.week {
                said += app.t(" · неделя \(Int((week.used * 100).rounded()))%", " · week \(Int((week.used * 100).rounded()))%")
                // A week resets within a week: anything further is a misreading.
                if let reset = week.resetsAt, reset > Date(), reset.timeIntervalSinceNow < 8 * 86_400 {
                    said += app.t(", сброс через ", ", resets in ") + until(reset, app)
                }
            }
            pairs.append((app.t("Аккаунт", "Account"), said, (facts.week?.used ?? 0) >= 0.9 ? "crit" : nil))
        }
        for (label, value, state) in pairs {
            var kv: [JSONValue] = [.string(label), .string(value)]
            if let state { kv.append(.string(state)) }
            rows.append(["kv": .array(kv)])
        }
        if look.auto {
            let cli = facts.compactsAt.map { app.t("claude сам — при \(pct($0, facts.window))%", "claude itself at \(pct($0, facts.window))%") }
            let said = look.pause
                ? [app.t("Сожму в паузе при \(look.pauseAt)%", "Compacted in the pause at \(look.pauseAt)%"), cli].compactMap { $0 }.joined(separator: " · ")
                : (cli.map { app.t("Сожмётся сам посреди работы: ", "Compacts by itself mid-turn: ") + $0 } ?? "")
            if !said.isEmpty { rows.append(["text": .string(said)]) }
        }
        var buttons: [JSONValue] = []
        // Short: three side by side in a popover 320 wide.
        if look.compactNow { buttons.append(["button": ["id": "ctx:compact", "label": .string(app.t("Сжать", "Compact"))]]) }
        if look.compactHint { buttons.append(["button": ["id": "ctx:hint", "label": .string(app.t("С подсказкой…", "With a hint…"))]]) }
        if look.fresh { buttons.append(["button": ["id": "ctx:fresh", "label": .string(app.t("Новый с итогом", "New, with a summary"))]]) }
        if !buttons.isEmpty { rows.append(["bar": ["id": "ctx", "items": .array(buttons)]]) }
        return rows
    }

    /// What the context is made of, in words of the card's language.
    static func parts(_ facts: Facts, _ app: AgentsApp) -> [JSONValue] {
        var merged: [(label: String, tokens: Int, tone: String)] = []
        func add(_ label: String, _ tokens: Int, _ tone: String) {
            if let index = merged.firstIndex(where: { $0.label == label }) { merged[index].tokens += tokens } else { merged.append((label, tokens, tone)) }
        }
        for part in facts.parts {
            switch part.id {
            case "messages": add(app.t("Разговор", "Conversation"), part.tokens, "warn")
            case "skills": add(app.t("Скилы", "Skills"), part.tokens, "ok")
            case "system_prompt": add(app.t("Системные указания", "System prompt"), part.tokens, "info")
            case "memory_files": add(app.t("Память (CLAUDE.md)", "Memory (CLAUDE.md)"), part.tokens, "wait")
            case "autocompact_buffer": add(app.t("Запас на сжатие", "Kept for compaction"), part.tokens, "idle")
            default: add(app.t("Инструменты, агенты, MCP", "Tools, agents, MCP"), part.tokens, "run")
            }
        }
        // The conversation grew since it was asked: what is said is now.
        let measured = facts.parts.filter { !$0.isBuffer }.reduce(0) { $0 + $1.tokens }
        if facts.tokens > measured, let index = merged.firstIndex(where: { $0.tone == "warn" }) {
            merged[index].tokens += facts.tokens - measured
        }
        return merged.map { part in
            ["value": .number(facts.window > 0 ? Double(part.tokens) / Double(facts.window) : 0), "label": .string(part.label),
             "note": .string(tokens(part.tokens)), "tone": .string(part.tone)]
        }
    }

    // MARK: - Words and numbers

    static func turnsLeft(_ facts: Facts, _ look: ContextLook) -> Int? {
        guard let growth = facts.turnGrowth, growth > 0 else { return nil }
        let limit = look.pause ? facts.window * look.pauseAt / 100 : (facts.compactsAt ?? facts.window)
        return max(0, (limit - facts.tokens) / growth)
    }

    static func tone(_ percent: Double, _ look: ContextLook) -> String {
        guard look.tone else { return "info" }
        return percent >= 90 ? "crit" : percent >= 75 ? "warn" : "info"
    }

    static func state(_ percent: Double, _ look: ContextLook) -> String {
        guard look.tone else { return "ok" }
        return percent >= 90 ? "crit" : percent >= 75 ? "warn" : "ok"
    }

    static func pie(_ percent: Double) -> String {
        switch percent {
        case ..<12.5: "○"
        case ..<37.5: "◔"
        case ..<62.5: "◑"
        case ..<87.5: "◕"
        default: "●"
        }
    }

    nonisolated static func tokens(_ count: Int) -> String {
        if count >= 1_000_000 {
            let millions = Double(count) / 1_000_000
            return millions == millions.rounded() ? "\(Int(millions))M" : String(format: "%.1fM", millions)
        }
        if count >= 10_000 { return "\(Int((Double(count) / 1000).rounded()))k" }
        if count >= 1000 { return String(format: "%.1fk", Double(count) / 1000) }
        return "\(count)"
    }

    static func pct(_ tokens: Int, _ window: Int) -> Int {
        window > 0 ? Int((Double(tokens) / Double(window) * 100).rounded()) : 0
    }

    static func share(_ rate: Double) -> String {
        let value = rate * 100
        return value >= 10 ? String(Int(value.rounded())) : String(format: "%.1f", value)
    }

    static func minutes(_ seconds: TimeInterval) -> Int { max(1, Int((seconds / 60).rounded())) }

    static func clock(_ date: Date) -> String {
        let format = DateFormatter()
        format.dateFormat = "HH:mm"
        return format.string(from: date)
    }

    static func duration(_ ms: Int, _ app: AgentsApp) -> String {
        let minutes = ms / 60_000
        if minutes < 60 { return app.t("\(max(minutes, ms > 0 ? 1 : 0)) мин", "\(max(minutes, ms > 0 ? 1 : 0)) min") }
        return app.t("\(minutes / 60) ч \(minutes % 60) мин", "\(minutes / 60) h \(minutes % 60) min")
    }

    static func until(_ date: Date, _ app: AgentsApp) -> String {
        let minutes = Int(date.timeIntervalSinceNow / 60)
        if minutes >= 24 * 60 { return app.t("\(minutes / 1440) д \(minutes % 1440 / 60) ч", "\(minutes / 1440) d \(minutes % 1440 / 60) h") }
        if minutes >= 60 { return app.t("\(minutes / 60) ч \(minutes % 60) мин", "\(minutes / 60) h \(minutes % 60) min") }
        return app.t("\(max(1, minutes)) мин", "\(max(1, minutes)) min")
    }

    static func turnsWord(_ count: Int) -> String {
        switch count % 10 {
        case 1 where count % 100 != 11: "ход"
        case 2...4 where !(12...14).contains(count % 100): "хода"
        default: "ходов"
        }
    }
}

/// What a group of Agents' settings does, drawn for Settings beside them
/// (uDeck 0.9.32): a sample session's card, its context badge and — not
/// to be clicked there — the details it would show, under it.
@MainActor
enum AgentsPreview {
    static func card(_ group: String, _ app: AgentsApp) -> JSONValue? {
        guard group == "context" else { return nil }
        let look = app.settings.context
        let now = Date()
        let window = 1_000_000
        let points = [40_000, 120_000, 260_000, 430_000, 610_000, 790_000, 20_000, 120_000, 190_000, 249_000]
            .enumerated().map { ContextTrack.Point(at: now.addingTimeInterval(Double($0.offset - 10) * 900), tokens: $0.element,
                                                   compacted: $0.offset == 6) }
        let facts = ContextCard.Facts(
            tokens: 249_000, window: window,
            parts: [.init(id: "system_prompt", name: "", tokens: 3_500, isBuffer: false),
                    .init(id: "system_tools", name: "", tokens: 2_600, isBuffer: false),
                    .init(id: "memory_files", name: "", tokens: 1_700, isBuffer: false),
                    .init(id: "skills", name: "", tokens: 8_700, isBuffer: false),
                    .init(id: "messages", name: "", tokens: 232_500, isBuffer: false),
                    .init(id: "autocompact_buffer", name: "", tokens: 33_000, isBuffer: true)],
            compactsAt: 967_000, points: points,
            compactions: [ContextTrack.Compaction(at: now.addingTimeInterval(-3600), fromTokens: 790_000, toTokens: 20_000, summary: nil)],
            turnGrowth: 24_000,
            heavy: [.init(id: "a", label: app.t("Read agents.log", "Read agents.log"), tokens: 38_000),
                    .init(id: "b", label: "Bash swift test", tokens: 21_000),
                    .init(id: "c", label: app.t("Снимки экрана (×4)", "Screenshots (×4)"), tokens: 18_000)],
            cacheCold: now.addingTimeInterval(41 * 60), cacheWarm: true, costUSD: 114.5,
            wallMs: (25 * 60 + 30) * 60_000, apiMs: (2 * 60 + 7) * 60_000, model: "Opus 5.5",
            effort: AgentsCard.effortName("xhigh", app), account: "pers2",
            week: UsageWindow(used: 0.96, resetsAt: now.addingTimeInterval((2 * 24 + 7) * 3600)), weekPerHour: 0.03)
        var items: [JSONValue] = [["badge": ["text": .string(app.t("Работает 5:02", "Working 5:02")), "tone": "run", "busy": true]]]
        if let badge = ContextCard.badge(facts, look, app) {
            var shown = badge.object ?? [:]
            shown["details"] = nil
            items.append(["badge": .object(shown)])
        }
        if app.settings.sleepShown == "icon" { items.append(["badge": ["text": "☕"]]) }
        items.append(["badge": ["text": "u-pilot", "icon": "folder"]])
        var rows: [JSONValue] = [
            ["bar": ["id": "head", "items": [["title": ["text": .string(app.t("Плагины uDeck: этап 4", "uDeck plugins: stage 4")), "tone": "run"]],
                                             ["tag": "Claude"]]]],
            ["bar": ["id": "status", "items": .array(items)]],
        ]
        rows += ContextCard.rows(facts, look, app)
        if look.details == "click" {
            rows.append(["text": .string(app.t("По клику на значок:", "A click on the badge shows:"))])
            rows += ContextCard.details(facts, look, app)
        }
        return ["title": "Agents", "rows": .array(rows)]
    }
}
