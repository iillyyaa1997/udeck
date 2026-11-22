import Foundation
import UDeckAgents

/// What the Agents card shows, by its size. Pure: the app's state in, the
/// card's JSON out.
@MainActor
enum AgentsCard {
    static func card(for app: AgentsApp) -> JSONValue {
        let waiting = app.sessions.filter { !$0.asks.isEmpty }.count
        var card: [String: JSONValue] = [
            "title": "Agents",
            "state": .string(waiting > 0 ? "warn" : "ok"),
            "rows": .array(app.size.columns <= 4 || app.size.rows <= 2 ? small(app) : large(app)),
        ]
        if waiting > 0 { card["chip"] = .string(app.t("ждут: \(waiting)", "\(waiting) waiting")) }
        return .object(card)
    }

    /// The sessions as a list, and a way to start one.
    static func small(_ app: AgentsApp) -> [JSONValue] {
        var rows: [JSONValue] = []
        if app.sessions.isEmpty {
            rows.append(["text": .string(app.t("Сессий нет", "No sessions"))])
        } else {
            rows.append(["list": .array(app.sessions.map { session in
                ["text": .string(session.title), "note": .string(stateWord(session, app)), "icon": .string(icon(session))]
            })])
        }
        rows.append(["chips": .array(sessionChips(app) + [chip("new", "＋")])])
        return rows
    }

    static func large(_ app: AgentsApp) -> [JSONValue] {
        var rows: [JSONValue] = []
        var chips = sessionChips(app)
        chips.append(chip("new", app.t("＋ Новая", "＋ New")))
        chips.append(chip("history", app.t("История", "History"), selected: app.showingHistory))
        rows.append(["chips": .array(chips)])
        if app.accounts.count > 1 {
            rows.append(["chips": .array(app.accounts.map { account in
                chip("acct:" + account.name, account.configDir == nil ? app.t("основная", "main") : account.name,
                     selected: account == app.account)
            })])
        }
        if app.showingHistory {
            rows.append(["text": .string(app.t("Открыть и продолжить:", "Open and continue:"))])
            rows.append(["chips": .array(app.history.map { chip("h:" + $0.sessionID, $0.title) })])
            return rows
        }
        guard let session = app.selected else {
            rows.append(["text": .string(app.t("Выберите сессию или начните новую: ＋", "Choose a session, or start one: ＋"))])
            return rows
        }
        // The card is sent whole on every change, five times a second while
        // words stream in, and uDeck lays all of it out: the newest entries
        // only, and no entry longer than a screenful.
        let keep = app.size.rows <= 4 ? 30 : 60
        rows.append(["feed": .array(session.items.suffix(keep).map { feedEntry($0, app) })])
        let held = app.heldBack[session.id] != nil
        if held { rows.append(["ask": heldRow(session, app)]) }
        for ask in session.asks { rows.append(["ask": askRow(ask, app)]) }
        let placeholder = held ? app.t("Только просмотр — сессия идёт в другом месте", "View only — it runs elsewhere")
            : session.isEnded ? stateWord(session, app)
            : app.t("Сообщение — Return отправляет", "Message — Return sends")
        var input: [String: JSONValue] = [
            "id": "message",
            "placeholder": .string(placeholder),
            "enabled": .bool(!session.isEnded && !held),
        ]
        if session.state == .working { input["stop"] = "stop" }
        rows.append(["input": .object(input)])
        return rows
    }

    static func sessionChips(_ app: AgentsApp) -> [JSONValue] {
        app.sessions.map { session in
            var item: [String: JSONValue] = ["id": .string("s:" + session.id.uuidString), "text": .string(session.title),
                                             "selected": .bool(session.id == app.selection)]
            if !session.asks.isEmpty { item["state"] = "warn" }
            return .object(item)
        }
    }

    /// A saved session written to a moment ago is open somewhere else (a
    /// terminal, another window): resuming it here would make two writers of
    /// one conversation. It opens to be read, and continues here only when
    /// asked to.
    static func heldRow(_ session: ChatSession, _ app: AgentsApp) -> JSONValue {
        let minutes = app.heldBack[session.id].map { max(0, Int(Date().timeIntervalSince($0) / 60)) } ?? 0
        let when = minutes == 0 ? app.t("только что", "just now") : app.t("\(minutes) мин назад", "\(minutes) min ago")
        return ["id": .string("held-" + session.id.uuidString),
                "title": .string(app.t("Эта сессия сейчас идёт в другом месте", "This session is running elsewhere")),
                "detail": .string(app.t("Последняя запись — \(when). Продолжить здесь значит писать в неё вдвоём",
                                        "Last written \(when). Continuing here means two writers in one conversation")),
                "buttons": [
                    ["id": .string("here:" + session.id.uuidString), "label": .string(app.t("Продолжить здесь", "Continue here"))],
                    ["id": .string("drop:" + session.id.uuidString), "label": .string(app.t("Закрыть", "Close")), "primary": true],
                ]]
    }

    nonisolated static let longest = 4_000

    nonisolated static func clipped(_ text: String, _ limit: Int = longest) -> String {
        text.count <= limit ? text : String(text.prefix(limit)) + "…"
    }

    static func chip(_ id: String, _ text: String, selected: Bool = false) -> JSONValue {
        ["id": .string(id), "text": .string(text), "selected": .bool(selected)]
    }

    static func feedEntry(_ item: FeedItem, _ app: AgentsApp) -> JSONValue {
        switch item {
        case .user(let id, let text):
            return ["id": .string(id.uuidString), "role": "user", "text": .string(clipped(text))]
        case .assistant(let id, let text, let streaming):
            return ["id": .string(id.uuidString), "role": "assistant", "text": .string(clipped(text)), "streaming": .bool(streaming)]
        case .tool(let id, let name, let summary, let result):
            var entry: [String: JSONValue] = ["id": .string("tool-" + id), "role": "tool",
                                              "text": .string(clipped(summary.isEmpty ? name : name + "  " + summary, 300))]
            if let result {
                entry["detail"] = .string(clipped(result.preview, 1_200))
                if result.isError { entry["error"] = true }
            }
            return .object(entry)
        case .note(let id, let text):
            return ["id": .string(id.uuidString), "role": "note",
                    "text": .string(text == "resumed" ? app.t("Продолжено из истории", "Resumed from history")
                        : text == "compacted" ? app.t("Здесь контекст был сжат", "The context was compacted here")
                        : clipped(text, 600))]
        }
    }

    static func askRow(_ ask: ChatAsk, _ app: AgentsApp) -> JSONValue {
        if let question = ask.ask.questions?.first {
            return ["id": .string(ask.requestID), "title": .string(question.question),
                    "buttons": .array(question.options.enumerated().map { index, option in
                        ["id": .string("opt:\(ask.requestID):\(index)"), "label": .string(option.label)]
                    })]
        }
        var buttons: [JSONValue] = [["id": .string("allow:" + ask.requestID), "label": .string(app.t("Разрешить", "Allow")),
                                     "primary": true]]
        if ask.ask.offersAlways {
            buttons.append(["id": .string("always:" + ask.requestID), "label": .string(app.t("Разрешать всегда", "Always allow"))])
        }
        buttons.append(["id": .string("deny:" + ask.requestID), "label": .string(app.t("Отклонить", "Deny"))])
        return ["id": .string(ask.requestID),
                "title": .string(app.t("Хочет использовать ", "Wants to use ") + ask.ask.displayName),
                "detail": .string(ask.summary), "buttons": .array(buttons)]
    }

    static func stateWord(_ session: ChatSession, _ app: AgentsApp) -> String {
        if app.heldBack[session.id] != nil { return app.t("просмотр", "view only") }
        if !session.asks.isEmpty { return app.t("ждёт", "waiting") }
        switch session.state {
        case .starting: return app.t("запускается", "starting")
        case .working: return app.t("работает", "working")
        case .idle: return app.t("готово", "ready")
        case .ended: return app.t("завершена", "ended")
        }
    }

    static func icon(_ session: ChatSession) -> String {
        if !session.asks.isEmpty { return "wait" }
        switch session.state {
        case .working, .starting: return "run"
        case .idle: return "idle"
        case .ended: return "done"
        }
    }
}
