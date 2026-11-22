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
        let waiting = app.conversations.filter { $0.current.waiting > 0 }.count
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
        if let session { items.append(["tag": .string(session.active.name)]) }
        let others = app.conversations.filter { $0.id != session?.id }
        let waiting = others.filter { $0.current.waiting > 0 }.count
        if narrow(app) {
            if waiting > 0 { items.append(["badge": ["text": .string("\(waiting)"), "tone": "wait", "icon": "wait"]]) }
        } else if !others.isEmpty {
            let text = waiting > 0 ? app.t("ещё \(others.count) · \(waiting) ждёт", "\(others.count) more · \(waiting) waiting")
                : app.t("ещё \(others.count)", "\(others.count) more")
            items.append(["badge": ["text": .string(text), "tone": .string(waiting > 0 ? "wait" : "idle")]])
        }
        items.append(["spacer": true])
        items.append(["button": [
            "id": "new", "icon": "plus", "note": .string(app.t("Потом выбор папки", "Then the folder")),
            "options": .array(Provider.allCases.map { provider in
                ["id": .string("new:" + provider.rawValue), "text": .string(provider.name),
                 "group": .string(app.t("Новая сессия", "New session"))]
            }),
        ]])
        return ["bar": ["id": "head", "items": .array(items)]]
    }

    /// The sessions open here, then the saved ones to continue.
    static func sessionMenu(_ app: AgentsApp) -> JSONValue {
        var options: [JSONValue] = app.conversations.map { session in
            ["id": .string("s:" + session.id.uuidString), "text": .string(session.title),
             "group": .string(app.t("Открытые", "Open")), "note": .string(stateWord(session, app)),
             "tone": .string(tone(session, app))]
        }
        let open = Set(app.conversations.compactMap { $0.claude?.sessionID })
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
        guard !app.conversations.isEmpty else { return [["text": .string(app.t("Сессий нет", "No sessions"))]] }
        return [["list": .array(app.conversations.map { session in
            ["text": .string(session.title), "note": .string(stateWord(session, app)), "icon": .string(icon(session))]
        })]]
    }

    static func body(_ app: AgentsApp) -> [JSONValue] {
        guard let session = app.selected else {
            return [["text": .string(app.conversations.isEmpty
                ? app.t("Сессий нет. Новая — ＋ справа вверху, продолжить сохранённую — в меню рядом с названием",
                        "No sessions. Start one with ＋ at the top right, or continue a saved one from the menu by the name")
                : app.t("Выберите сессию в меню рядом с названием", "Choose a session from the menu by the name"))]]
        }
        var rows: [JSONValue] = [status(session, app)]
        // The card is sent whole on every change, five times a second while
        // words stream in, and uDeck lays all of it out: the newest entries
        // only, and no entry longer than a screenful.
        let keep = app.size.rows <= 4 ? 30 : 60
        rows.append(["feed": .array(session.feed.suffix(keep).map { feedEntry($0.item, app, label: $0.label) })])
        let held = app.heldBack[session.id] != nil
        if held { rows.append(["ask": heldRow(session, app)]) }
        switch session.current {
        case .claude(let agent): for ask in agent.asks { rows.append(["ask": askRow(ask, app)]) }
        case .codex(let agent): for ask in agent.asks { rows.append(["ask": codexAskRow(ask, app)]) }
        }
        rows.append(["input": input(session, app, held: held)])
        return rows
    }

    /// What the session is doing, how full its context is, and where it works.
    static func status(_ session: Conversation, _ app: AgentsApp) -> JSONValue {
        var items: [JSONValue] = [["badge": stateBadge(session, app)]]
        if let percent = session.current.contextPercent {
            let tone = percent >= 90 ? "crit" : percent >= 75 ? "warn" : "info"
            items.append(["badge": ["text": .string(app.t("контекст \(Int(percent.rounded()))%", "context \(Int(percent.rounded()))%")),
                                    "tone": .string(tone), "fill": .number(percent / 100)]])
        }
        if !narrow(app) {
            items.append(["badge": ["text": .string(session.folder.lastPathComponent), "icon": "folder"]])
        }
        return ["bar": ["id": "status", "items": .array(items)]]
    }

    static func stateBadge(_ session: Conversation, _ app: AgentsApp) -> JSONValue {
        if app.heldBack[session.id] != nil {
            return ["text": .string(app.t("Только просмотр", "View only")), "tone": "warn", "icon": "info"]
        }
        let agent = session.current
        if agent.waiting > 0 {
            let count = agent.waiting
            let text = narrow(app) ? app.t("Ждёт тебя", "Waiting")
                : app.t("Ждёт тебя · \(count) \(questions(count))", "Waiting for you · \(count) question\(count == 1 ? "" : "s")")
            return ["text": .string(text), "tone": "wait", "icon": "wait"]
        }
        switch agent.state {
        case .working:
            let elapsed = agent.turnStartedAt.map { clock(Date().timeIntervalSince($0)) } ?? ""
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
    /// the model and the effort in one menu on a narrow card. The model menu
    /// lists the other provider's models too: one of them takes the
    /// conversation over.
    static func input(_ session: Conversation, _ app: AgentsApp, held: Bool) -> JSONValue {
        let agent = session.current
        let placeholder = held ? app.t("Только просмотр — сессия идёт в другом месте", "View only — it runs elsewhere")
            : agent.isEnded ? stateWord(session, app)
            : narrow(app) ? app.t("Сообщение", "Message")
            : app.t("Сообщение · Return отправляет, Shift+Return — новая строка",
                    "Message · Return sends, Shift+Return starts a new line")
        var input: [String: JSONValue] = [
            "id": "message",
            "placeholder": .string(placeholder),
            "enabled": .bool(!agent.isEnded && !held),
        ]
        if agent.state == .working { input["stop"] = "stop" }
        guard !held, !agent.isEnded else { return .object(input) }
        var pickers: [JSONValue] = []
        if case .claude(let claude) = agent, app.accounts.count > 1 {
            pickers.append(["id": "account", "text": .string(accountName(claude.account, app)),
                            "selected": .string(claude.account.name),
                            "note": .string(app.t("Сессия переедет на эту учётку и продолжится там",
                                                  "The session moves to this login and continues there")),
                            "options": .array(app.accounts.map {
                                ["id": .string($0.name), "text": .string(accountName($0, app))]
                            })])
        }
        let models = modelOptions(session, app, prefix: narrow(app) ? "m:" : "")
        let efforts = effortLevels(agent)
        let current = agent.currentModel.map { agent.provider.rawValue + ":" + $0.value }
        let modelNote = agent.provider == .claude
            ? app.t("Модель Claude — сразу, в этой же сессии. Модель Codex — разговор перейдёт к нему",
                    "A Claude model right away, in this session. A Codex model — the conversation moves to it")
            : app.t("Модель Codex — со следующего сообщения. Модель Claude — разговор перейдёт к нему",
                    "A Codex model from the next message. A Claude model — the conversation moves to it")
        if narrow(app) {
            var options = models
            options += efforts.map { level in
                ["id": .string("e:" + level),
                 "text": .string(effortName(level, app) + (level == agent.effort ? "  ✓" : "")),
                 "group": .string(app.t("Усилие", "Effort"))]
            }
            var menu: [String: JSONValue] = [
                "id": "me", "text": .string(shortModel(agent) + " · " + (agent.effort.map { effortName($0, app) } ?? app.t("усилие", "effort"))),
                "note": .string(modelNote), "options": .array(options),
            ]
            if let current { menu["selected"] = .string("m:" + current) }
            pickers.append(.object(menu))
        } else {
            var menu: [String: JSONValue] = [
                "id": "model", "icon": "model", "text": .string(agent.modelName ?? app.t("модель", "model")),
                "note": .string(modelNote), "options": .array(models),
            ]
            if let current { menu["selected"] = .string(current) }
            pickers.append(.object(menu))
            var effort: [String: JSONValue] = [
                "id": "effort", "icon": "effort",
                "text": .string(agent.effort.map { effortName($0, app) } ?? app.t("усилие", "effort")),
                "note": .string(agent.provider == .claude
                    ? app.t("Со следующего сообщения: сессия продолжится с ним", "From the next message: the session continues with it")
                    : app.t("Со следующего сообщения", "From the next message")),
                "options": .array(efforts.map { ["id": .string($0), "text": .string(effortName($0, app))] }),
            ]
            if let level = agent.effort { effort["selected"] = .string(level) }
            pickers.append(.object(effort))
        }
        input["pickers"] = .array(pickers)
        return .object(input)
    }

    /// The active provider's models, then the other's, under its name with
    /// what choosing one means.
    static func modelOptions(_ session: Conversation, _ app: AgentsApp, prefix: String) -> [JSONValue] {
        let active = session.active
        var out: [JSONValue] = []
        for provider in [active] + Provider.allCases.filter({ $0 != active }) {
            let models = session.agents[provider]?.models.nonEmpty ?? app.knownModels[provider] ?? []
            let group = provider == active ? provider.name
                : provider.name + app.t(" — разговор перейдёт к нему", " — the conversation moves to it")
            out += models.map { ["id": .string(prefix + provider.rawValue + ":" + $0.value), "text": .string($0.name),
                                 "group": .string(group)] }
        }
        return out
    }

    // MARK: - Words

    /// The model's family alone, for a narrow card: «Opus», «GPT-6-Astra».
    static func shortModel(_ agent: Agent) -> String {
        let name = agent.modelName ?? ""
        if agent.provider == .codex { return name }
        return name.split(separator: " ").first.map(String.init) ?? name
    }

    /// `claude-opus-5-5` → «Opus 5.5»; anything else as it is.
    nonisolated static func prettyModel(_ id: String) -> String {
        let parts = id.split(separator: "[").first.map(String.init)?.split(separator: "-").map(String.init) ?? []
        guard parts.count >= 3, parts[0] == "claude" else { return id }
        let numbers = parts.dropFirst(2).prefix { Int($0) != nil }
        return parts[1].capitalized + (numbers.isEmpty ? "" : " " + numbers.joined(separator: "."))
    }

    static func effortLevels(_ agent: Agent) -> [String] {
        let offered = agent.currentModel?.efforts ?? agent.models.first?.efforts ?? []
        return offered.isEmpty ? ["low", "medium", "high", "xhigh", "max"] : offered
    }

    static func effortName(_ level: String, _ app: AgentsApp) -> String {
        switch level {
        case "none": app.t("без размышлений", "no reasoning")
        case "minimal": app.t("минимальное", "minimal")
        case "low": app.t("низкое", "low")
        case "medium": app.t("среднее", "medium")
        case "high": app.t("высокое", "high")
        case "xhigh": app.t("очень высокое", "very high")
        case "max": app.t("максимум", "max")
        case "ultra": app.t("ультра", "ultra")
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

    nonisolated static func russianCount(_ count: Int, _ one: String, _ few: String, _ many: String) -> String {
        let word = switch count % 10 {
        case 1 where count % 100 != 11: one
        case 2...4 where !(12...14).contains(count % 100): few
        default: many
        }
        return "\(count) \(word)"
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
    static func heldRow(_ session: Conversation, _ app: AgentsApp) -> JSONValue {
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

    static func feedEntry(_ item: FeedItem, _ app: AgentsApp, label: String? = nil) -> JSONValue {
        switch item {
        case .user(let id, let text):
            return ["id": .string(id.uuidString), "role": "user", "text": .string(clipped(text))]
        case .assistant(let id, let text, let streaming):
            var entry: [String: JSONValue] = ["id": .string(id.uuidString), "role": "assistant", "text": .string(clipped(text)),
                                              "streaming": .bool(streaming)]
            if let label { entry["label"] = .string(label) }
            return .object(entry)
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
        func model(_ value: String) -> String {
            for provider in Provider.allCases {
                if let name = (session?.agents[provider]?.models ?? app.knownModels[provider] ?? []).first(where: { $0.value == value })?.name {
                    return name
                }
            }
            return value
        }
        if text.hasPrefix("handoff:") {
            let parts = text.dropFirst(8).split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            if parts.count == 5, let provider = Provider(rawValue: parts[0]) {
                let tokens = (Int(parts[4]) ?? 0)
                let amount = tokens >= 1000 ? app.t("около \(tokens / 1000) тыс. токенов", "about \(tokens / 1000)k tokens")
                    : app.t("около \(tokens) токенов", "about \(tokens) tokens")
                return app.t("Дальше отвечает ", "From here ") + provider.name + app.t("", " answers") + " · " + parts[1] + " — "
                    + app.t("ему передан разговор: \(russianCount(Int(parts[2]) ?? 0, "сообщение", "сообщения", "сообщений")), "
                            + "\(russianCount(Int(parts[3]) ?? 0, "действие", "действия", "действий")), ",
                            "handed the conversation: \(parts[2]) messages, \(parts[3]) actions, ") + amount
            }
        }
        if text.hasPrefix("model-next:") {
            return app.t("Модель: ", "Model: ") + model(String(text.dropFirst(11))) + app.t(" — со следующего сообщения", " — from the next message")
        }
        if text.hasPrefix("effort-next:") {
            return app.t("Усилие: ", "Effort: ") + effortName(String(text.dropFirst(12)), app) + app.t(" — со следующего сообщения", " — from the next message")
        }
        if text == "switch-busy" {
            return app.t("Сменить провайдера можно, когда ход закончится и вопросов нет",
                         "The provider can change once the turn is over and nothing waits")
        }
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

    static func codexAskRow(_ ask: CodexAsk, _ app: AgentsApp) -> JSONValue {
        let short = narrow(app)
        return ["id": .string(ask.requestID),
                "title": .string(app.t("Хочет выполнить ", "Wants to run ") + ask.title),
                "detail": .string(ask.summary),
                "buttons": [
                    ["id": .string("allow:" + ask.requestID), "label": .string(app.t("Разрешить", "Allow")), "primary": true],
                    ["id": .string("always:" + ask.requestID),
                     "label": .string(short ? app.t("В сессии", "Session") : app.t("Разрешать в этой сессии", "Allow this session"))],
                    ["id": .string("deny:" + ask.requestID), "label": .string(app.t("Отклонить", "Deny"))],
                ]]
    }

    static func stateWord(_ session: Conversation, _ app: AgentsApp) -> String {
        if app.heldBack[session.id] != nil { return app.t("просмотр", "view only") }
        if session.current.waiting > 0 { return app.t("ждёт", "waiting") }
        switch session.current.state {
        case .starting: return app.t("запускается", "starting")
        case .working: return app.t("работает", "working")
        case .idle: return app.t("готово", "ready")
        case .ended: return app.t("завершена", "ended")
        }
    }

    static func tone(_ session: Conversation, _ app: AgentsApp) -> String {
        if app.heldBack[session.id] != nil { return "warn" }
        if session.current.waiting > 0 { return "wait" }
        switch session.current.state {
        case .working, .starting: return "run"
        case .idle: return "idle"
        case .ended: return "idle"
        }
    }

    static func icon(_ session: Conversation) -> String {
        if session.current.waiting > 0 { return "wait" }
        switch session.current.state {
        case .working, .starting: return "run"
        case .idle: return "idle"
        case .ended: return "done"
        }
    }
}

extension Array {
    /// Nil when empty: `models.nonEmpty ?? fallback`.
    var nonEmpty: [Element]? { isEmpty ? nil : self }
}
