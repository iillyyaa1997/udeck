import Foundation
import UDeckAgents

/// What the Agents card shows, by its size. Pure: the app's state in, the
/// card's JSON out.
///
/// The card opens with a bar uDeck draws as the window's title line: the
/// session's name with a dot of its state, a menu of the other sessions and
/// the saved ones, and ＋. Under it a row of badges — what the session is
/// doing, how full its context is, its folder — then the conversation, its
/// open questions, and the field, with the login, the model and the effort
/// beside Send.
@MainActor
enum AgentsCard {
    static func card(for app: AgentsApp) -> JSONValue {
        let waiting = app.sessions.filter { !$0.asks.isEmpty }.count
        var rows: [JSONValue] = [header(app)]
        if app.size.rows <= 2 {
            rows += tiny(app)
        } else {
            rows += body(app)
        }
        return ["title": "Agents", "state": .string(waiting > 0 ? "warn" : "ok"), "rows": .array(rows)]
    }

    static func narrow(_ app: AgentsApp) -> Bool { app.size.columns <= 4 }

    // MARK: - The title line

    static func header(_ app: AgentsApp) -> JSONValue {
        let session = app.selected
        var items: [JSONValue] = []
        var title: [String: JSONValue] = ["text": .string(session?.title ?? "Agents")]
        if let session { title["tone"] = .string(tone(session, app)) }
        items.append(["title": .object(title)])
        items.append(["menu": sessionMenu(app)])
        if session != nil { items.append(["tag": "Claude"]) }
        let others = app.sessions.filter { $0.id != session?.id }
        let waiting = others.filter { !$0.asks.isEmpty }.count
        if narrow(app) {
            if waiting > 0 { items.append(["badge": ["text": .string("\(waiting)"), "tone": "wait", "icon": "wait"]]) }
        } else if !others.isEmpty {
            let text = waiting > 0 ? app.t("ещё \(others.count) · \(waiting) ждёт", "\(others.count) more · \(waiting) waiting")
                : app.t("ещё \(others.count)", "\(others.count) more")
            items.append(["badge": ["text": .string(text), "tone": .string(waiting > 0 ? "wait" : "idle")]])
        }
        items.append(["spacer": true])
        items.append(["button": ["id": "new", "icon": "plus", "note": .string(app.t("Новая сессия", "New session"))]])
        return ["bar": ["id": "head", "items": .array(items)]]
    }

    /// The sessions open here, then the saved ones to continue.
    static func sessionMenu(_ app: AgentsApp) -> JSONValue {
        var options: [JSONValue] = app.sessions.map { session in
            ["id": .string("s:" + session.id.uuidString), "text": .string(session.title),
             "group": .string(app.t("Открытые", "Open")), "note": .string(stateWord(session, app)),
             "tone": .string(tone(session, app))]
        }
        let open = Set(app.sessions.compactMap(\.sessionID))
        options += app.history.filter { !open.contains($0.sessionID) }.map { saved in
            ["id": .string("h:" + saved.sessionID), "text": .string(saved.title),
             "group": .string(app.t("История — продолжить", "History — continue")),
             "note": .string(ago(saved.modified, app))]
        }
        var menu: [String: JSONValue] = ["id": "session", "text": "", "options": .array(options)]
        if let selection = app.selection { menu["selected"] = .string("s:" + selection.uuidString) }
        return .object(menu)
    }

    // MARK: - The body

    static func tiny(_ app: AgentsApp) -> [JSONValue] {
        guard !app.sessions.isEmpty else { return [["text": .string(app.t("Сессий нет", "No sessions"))]] }
        return [["list": .array(app.sessions.map { session in
            ["text": .string(session.title), "note": .string(stateWord(session, app)), "icon": .string(icon(session))]
        })]]
    }

    static func body(_ app: AgentsApp) -> [JSONValue] {
        guard let session = app.selected else {
            return [["text": .string(app.sessions.isEmpty
                ? app.t("Сессий нет. Новая — ＋ справа вверху, продолжить сохранённую — в меню рядом с названием",
                        "No sessions. Start one with ＋ at the top right, or continue a saved one from the menu by the name")
                : app.t("Выберите сессию в меню рядом с названием", "Choose a session from the menu by the name"))]]
        }
        var rows: [JSONValue] = [status(session, app)]
        // The card is sent whole on every change, five times a second while
        // words stream in, and uDeck lays all of it out: the newest entries
        // only, and no entry longer than a screenful.
        let keep = app.size.rows <= 4 ? 30 : 60
        rows.append(["feed": .array(session.items.suffix(keep).map { feedEntry($0, app) })])
        let held = app.heldBack[session.id] != nil
        if held { rows.append(["ask": heldRow(session, app)]) }
        for ask in session.asks { rows.append(["ask": askRow(ask, app)]) }
        rows.append(["input": input(session, app, held: held)])
        return rows
    }

    /// What the session is doing, how full its context is, and where it works.
    static func status(_ session: ChatSession, _ app: AgentsApp) -> JSONValue {
        var items: [JSONValue] = [["badge": stateBadge(session, app)]]
        if let context = session.context {
            let percent = max(0, min(100, context.percent))
            let tone = percent >= 90 ? "crit" : percent >= 75 ? "warn" : "info"
            items.append(["badge": ["text": .string(app.t("контекст \(Int(percent.rounded()))%", "context \(Int(percent.rounded()))%")),
                                    "tone": .string(tone), "fill": .number(percent / 100)]])
        }
        if !narrow(app) {
            items.append(["badge": ["text": .string(session.folder.lastPathComponent), "icon": "folder"]])
        }
        return ["bar": ["id": "status", "items": .array(items)]]
    }

    static func stateBadge(_ session: ChatSession, _ app: AgentsApp) -> JSONValue {
        if app.heldBack[session.id] != nil {
            return ["text": .string(app.t("Только просмотр", "View only")), "tone": "warn", "icon": "info"]
        }
        if !session.asks.isEmpty {
            let count = session.asks.count
            let text = narrow(app) ? app.t("Ждёт тебя", "Waiting")
                : app.t("Ждёт тебя · \(count) \(questions(count))", "Waiting for you · \(count) question\(count == 1 ? "" : "s")")
            return ["text": .string(text), "tone": "wait", "icon": "wait"]
        }
        switch session.state {
        case .working:
            let elapsed = session.turnStartedAt.map { clock(Date().timeIntervalSince($0)) } ?? ""
            let text = narrow(app) ? elapsed : app.t("Работает", "Working") + (elapsed.isEmpty ? "" : " " + elapsed)
            return ["text": .string(text.isEmpty ? app.t("Работает", "Working") : text), "tone": "run", "icon": "run"]
        case .starting:
            return ["text": .string(app.t("Запускается", "Starting")), "tone": "info", "icon": "run"]
        case .idle:
            return ["text": .string(app.t("Готово", "Ready")), "tone": "idle", "icon": "done"]
        case .ended:
            return ["text": .string(app.t("Завершена", "Ended")), "tone": "idle", "icon": "idle"]
        }
    }

    /// The field, with the login, the model and the effort beside Send —
    /// the model and the effort in one menu on a narrow card.
    static func input(_ session: ChatSession, _ app: AgentsApp, held: Bool) -> JSONValue {
        let placeholder = held ? app.t("Только просмотр — сессия идёт в другом месте", "View only — it runs elsewhere")
            : session.isEnded ? stateWord(session, app)
            : narrow(app) ? app.t("Сообщение", "Message")
            : app.t("Сообщение · Return отправляет, Shift+Return — новая строка",
                    "Message · Return sends, Shift+Return starts a new line")
        var input: [String: JSONValue] = [
            "id": "message",
            "placeholder": .string(placeholder),
            "enabled": .bool(!session.isEnded && !held),
        ]
        if session.state == .working { input["stop"] = "stop" }
        guard !held, !session.isEnded else { return .object(input) }
        var pickers: [JSONValue] = []
        if app.accounts.count > 1 {
            pickers.append(["id": "account", "text": .string(accountName(session.account, app)),
                            "selected": .string(session.account.name),
                            "note": .string(app.t("Сессия переедет на эту учётку и продолжится там",
                                                  "The session moves to this login and continues there")),
                            "options": .array(app.accounts.map {
                                ["id": .string($0.name), "text": .string(accountName($0, app))]
                            })])
        }
        let models = session.models.filter { $0.value != "default" }
        let efforts = effortLevels(session)
        if narrow(app) {
            var options: [JSONValue] = models.map {
                ["id": .string("m:" + $0.value), "text": .string($0.name), "group": .string(app.t("Модель", "Model"))]
            }
            options += efforts.map { level in
                ["id": .string("e:" + level),
                 "text": .string(effortName(level, app) + (level == session.effort ? "  ✓" : "")),
                 "group": .string(app.t("Усилие", "Effort"))]
            }
            var menu: [String: JSONValue] = [
                "id": "me", "text": .string(shortModel(session) + " · " + (session.effort.map { effortName($0, app) } ?? app.t("усилие", "effort"))),
                "note": .string(app.t("Модель — сразу, усилие — со следующего сообщения",
                                      "The model right away, the effort from the next message")),
                "options": .array(options),
            ]
            if let current = currentModel(session) { menu["selected"] = .string("m:" + current.value) }
            pickers.append(.object(menu))
        } else {
            if !models.isEmpty {
                var menu: [String: JSONValue] = [
                    "id": "model", "icon": "model", "text": .string(modelName(session, app)),
                    "note": .string(app.t("Сразу, в этой же сессии", "Right away, in this session")),
                    "options": .array(models.map { ["id": .string($0.value), "text": .string($0.name)] }),
                ]
                if let current = currentModel(session) { menu["selected"] = .string(current.value) }
                pickers.append(.object(menu))
            }
            var effort: [String: JSONValue] = [
                "id": "effort", "icon": "effort",
                "text": .string(session.effort.map { effortName($0, app) } ?? app.t("усилие", "effort")),
                "note": .string(app.t("Со следующего сообщения: сессия продолжится с ним",
                                      "From the next message: the session continues with it")),
                "options": .array(efforts.map { ["id": .string($0), "text": .string(effortName($0, app))] }),
            ]
            if let level = session.effort { effort["selected"] = .string(level) }
            pickers.append(.object(effort))
        }
        input["pickers"] = .array(pickers)
        return .object(input)
    }

    // MARK: - Words

    static func currentModel(_ session: ChatSession) -> ModelChoice? {
        let models = session.models.filter { $0.value != "default" }
        if let chosen = session.chosenModel { return models.first { $0.value == chosen } }
        guard let model = session.model else { return nil }
        return models.first { $0.resolved == model || model.hasPrefix($0.resolved ?? "\u{0}") }
    }

    static func modelName(_ session: ChatSession, _ app: AgentsApp) -> String {
        if let current = currentModel(session) { return current.name }
        if let chosen = session.chosenModel { return chosen }
        if let model = session.model { return prettyModel(model) }
        return app.t("модель", "model")
    }

    /// The model's family alone, for a narrow card: «Opus».
    static func shortModel(_ session: ChatSession) -> String {
        let name = currentModel(session)?.name ?? session.model.map(prettyModel) ?? ""
        return name.split(separator: " ").first.map(String.init) ?? name
    }

    /// `claude-opus-5-5` → «Opus 5.5»; anything else as it is.
    nonisolated static func prettyModel(_ id: String) -> String {
        let parts = id.split(separator: "[").first.map(String.init)?.split(separator: "-").map(String.init) ?? []
        guard parts.count >= 3, parts[0] == "claude" else { return id }
        let numbers = parts.dropFirst(2).prefix { Int($0) != nil }
        return parts[1].capitalized + (numbers.isEmpty ? "" : " " + numbers.joined(separator: "."))
    }

    static func effortLevels(_ session: ChatSession) -> [String] {
        let offered = currentModel(session)?.efforts ?? session.models.first(where: { $0.value == "default" })?.efforts ?? []
        return offered.isEmpty ? ["low", "medium", "high", "xhigh", "max"] : offered
    }

    static func effortName(_ level: String, _ app: AgentsApp) -> String {
        switch level {
        case "low": app.t("низкое", "low")
        case "medium": app.t("среднее", "medium")
        case "high": app.t("высокое", "high")
        case "xhigh": app.t("очень высокое", "very high")
        case "max": app.t("максимум", "max")
        default: level
        }
    }

    static func accountName(_ account: ChatAccount, _ app: AgentsApp) -> String {
        account.configDir == nil ? app.t("основная", "main") : account.name
    }

    nonisolated static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let hours = total / 3600, minutes = total % 3600 / 60, rest = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, rest) : String(format: "%d:%02d", minutes, rest)
    }

    nonisolated static func questions(_ count: Int) -> String {
        switch count % 10 {
        case 1 where count % 100 != 11: "вопрос"
        case 2...4 where !(12...14).contains(count % 100): "вопроса"
        default: "вопросов"
        }
    }

    static func ago(_ date: Date, _ app: AgentsApp) -> String {
        let minutes = max(0, Int(Date().timeIntervalSince(date) / 60))
        if minutes < 1 { return app.t("только что", "just now") }
        if minutes < 60 { return app.t("\(minutes) мин назад", "\(minutes) min ago") }
        if minutes < 24 * 60 { return app.t("\(minutes / 60) ч назад", "\(minutes / 60) h ago") }
        return app.t("\(minutes / (24 * 60)) дн назад", "\(minutes / (24 * 60)) d ago")
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

    static func feedEntry(_ item: FeedItem, _ app: AgentsApp) -> JSONValue {
        switch item {
        case .user(let id, let text):
            return ["id": .string(id.uuidString), "role": "user", "text": .string(clipped(text))]
        case .assistant(let id, let text, let streaming):
            return ["id": .string(id.uuidString), "role": "assistant", "text": .string(clipped(text)), "streaming": .bool(streaming)]
        case .tool(let id, let name, let summary, let result):
            var entry: [String: JSONValue] = ["id": .string("tool-" + id), "role": "tool", "name": .string(name),
                                              "text": .string(clipped(summary.isEmpty ? name : name + "  " + summary, 300))]
            if let result {
                entry["detail"] = .string(clipped(result.preview, 1_200))
                if result.isError { entry["error"] = true }
            } else {
                entry["streaming"] = true
            }
            return .object(entry)
        case .note(let id, let text):
            return ["id": .string(id.uuidString), "role": "note", "text": .string(noteText(text, app))]
        }
    }

    /// The notes the session keeps by name, in the card's language.
    static func noteText(_ text: String, _ app: AgentsApp) -> String {
        let session = app.selected
        func model(_ value: String) -> String { session?.models.first { $0.value == value }?.name ?? value }
        if text == "resumed" { return app.t("Продолжено из истории", "Resumed from history") }
        if text == "compacted" { return app.t("Здесь контекст был сжат", "The context was compacted here") }
        if text.hasPrefix("model:") { return app.t("Модель: ", "Model: ") + model(String(text.dropFirst(6))) }
        if text.hasPrefix("model-failed:") {
            return app.t("Не удалось сменить модель на ", "Could not switch the model to ") + model(String(text.dropFirst(13)))
        }
        if text.hasPrefix("effort:") {
            return app.t("Усилие: ", "Effort: ") + effortName(String(text.dropFirst(7)), app)
                + app.t(" — сессия продолжена с ним", " — the session continues with it")
        }
        if text.hasPrefix("account:") {
            let name = String(text.dropFirst(8))
            let account = app.accounts.first { $0.name == name }
            return app.t("Сессия переехала на учётку ", "The session moved to the login ")
                + (account.map { accountName($0, app) } ?? name)
        }
        return clipped(text, 600)
    }

    static func askRow(_ ask: ChatAsk, _ app: AgentsApp) -> JSONValue {
        if let question = ask.ask.questions?.first {
            return ["id": .string(ask.requestID), "title": .string(question.question),
                    "buttons": .array(question.options.enumerated().map { index, option in
                        ["id": .string("opt:\(ask.requestID):\(index)"), "label": .string(option.label)]
                    })]
        }
        let short = narrow(app)
        var buttons: [JSONValue] = [["id": .string("allow:" + ask.requestID), "label": .string(app.t("Разрешить", "Allow")),
                                     "primary": true]]
        if ask.ask.offersAlways {
            buttons.append(["id": .string("always:" + ask.requestID),
                            "label": .string(short ? app.t("Всегда", "Always") : app.t("Разрешать всегда", "Always allow"))])
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

    static func tone(_ session: ChatSession, _ app: AgentsApp) -> String {
        if app.heldBack[session.id] != nil { return "warn" }
        if !session.asks.isEmpty { return "wait" }
        switch session.state {
        case .working, .starting: return "run"
        case .idle: return "idle"
        case .ended: return "idle"
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
