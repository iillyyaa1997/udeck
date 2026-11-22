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
        let keep = app.size.rows <= 4 ? 40 : 300
        rows.append(["feed": .array(session.items.suffix(keep).map { feedEntry($0, app) })])
        for ask in session.asks { rows.append(["ask": askRow(ask, app)]) }
        var input: [String: JSONValue] = [
            "id": "message",
            "placeholder": .string(session.isEnded ? stateWord(session, app)
                : app.t("Сообщение — Return отправляет", "Message — Return sends")),
            "enabled": .bool(!session.isEnded),
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

    static func chip(_ id: String, _ text: String, selected: Bool = false) -> JSONValue {
        ["id": .string(id), "text": .string(text), "selected": .bool(selected)]
    }

    static func feedEntry(_ item: FeedItem, _ app: AgentsApp) -> JSONValue {
        switch item {
        case .user(let id, let text):
            return ["id": .string(id.uuidString), "role": "user", "text": .string(text)]
        case .assistant(let id, let text, let streaming):
            return ["id": .string(id.uuidString), "role": "assistant", "text": .string(text), "streaming": .bool(streaming)]
        case .tool(let id, let name, let summary, let result):
            var entry: [String: JSONValue] = ["id": .string("tool-" + id), "role": "tool",
                                              "text": .string(summary.isEmpty ? name : name + "  " + summary)]
            if let result {
                entry["detail"] = .string(result.preview)
                if result.isError { entry["error"] = true }
            }
            return .object(entry)
        case .note(let id, let text):
            return ["id": .string(id.uuidString), "role": "note",
                    "text": .string(text == "resumed" ? app.t("Продолжено из истории", "Resumed from history") : text)]
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
