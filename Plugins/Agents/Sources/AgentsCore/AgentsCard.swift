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
        var card: [String: JSONValue] = ["title": "Agents", "state": .string(waiting > 0 ? "warn" : "ok"),
                                         "rows": .array(rows)]
        if let attention = attention(app) { card["attention"] = attention }
        return .object(card)
    }

    /// What waits for the person across every session (`attention`): how
    /// many questions and permissions, and the first session's first one,
    /// named after its session — uDeck shows it first when the panel is
    /// peeked at, and its buttons come back as `press`, which answers it
    /// wherever the session is shown.
    static func attention(_ app: AgentsApp) -> JSONValue? {
        let count = app.conversations.reduce(0) { $0 + $1.current.waiting }
        guard count > 0 else { return nil }
        var attention: [String: JSONValue] = ["count": .number(Double(count))]
        if let conversation = app.conversations.first(where: { $0.current.waiting > 0 }) {
            let row: JSONValue? = switch conversation.current {
            case .claude(let session): session.asks.first.map { askRow($0, app) }
            case .codex(let session): session.asks.first.map { codexAskRow($0, app) }
            }
            if let row, let id = row["id"]?.string, let buttons = row["buttons"] {
                let what = [row["title"]?.string, row["detail"]?.string].compactMap { $0 }.filter { !$0.isEmpty }
                attention["ask"] = ["id": .string(id),
                                    "title": .string(app.t("Ждёт тебя — ", "Waiting for you — ") + conversation.title),
                                    "detail": .string(clipped(what.joined(separator: ": "), 200)),
                                    "buttons": buttons]
            }
        }
        return .object(attention)
    }

    static func narrow(_ app: AgentsApp) -> Bool { app.size.columns <= 4 }

    /// Low enough that a line of badges and the menus by the field would
    /// leave the conversation no room — a mini window above the other
    /// windows: what the session is doing goes into the title line, and the
    /// field is a field.
    static func compact(_ app: AgentsApp) -> Bool { app.size.rows == 3 }

    // MARK: - The title line

    static func header(_ app: AgentsApp) -> JSONValue {
        let session = app.selected
        var items: [JSONValue] = []
        var title: [String: JSONValue] = ["text": .string(session?.title ?? "Agents")]
        if let session { title["tone"] = .string(tone(session, app)) }
        items.append(["title": .object(title)])
        items.append(["menu": sessionMenu(app)])
        if let session {
            if compact(app) {
                items.append(["badge": stateBadge(session, app)])
            } else {
                items.append(["tag": .string(session.active.name)])
            }
        }
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
        if session != nil {
            items.append(["button": ["id": "close", "label": "✕",
                                     "note": .string(app.t("Закрыть эту сессию — она останется в истории",
                                                           "Close this session — it stays in the history"))]])
        }
        return ["bar": ["id": "head", "items": .array(items)]]
    }

    /// The sessions open here, then the saved ones to continue.
    static func sessionMenu(_ app: AgentsApp) -> JSONValue {
        var options: [JSONValue] = app.conversations.map { session in
            ["id": .string("s:" + session.id.uuidString), "text": .string(session.title),
             "group": .string(app.t("Открытые", "Open")),
             "note": .string(session.folder.lastPathComponent + " · " + placeNote(session, app)),
             "tone": .string(tone(session, app)),
             // uDeck 0.9.14 draws it; an older one draws the option alone.
             "button": ["id": .string("close:" + session.id.uuidString), "label": "✕"]]
        }
        let open = Set(app.conversations.compactMap { $0.claude?.sessionID })
        options += app.history.filter { !open.contains($0.sessionID) }.map { saved in
            ["id": .string("h:" + saved.sessionID), "text": .string(app.name(of: saved)),
             "group": .string(app.t("История Claude — продолжить", "Claude history — continue")),
             "note": .string(savedNote(saved.folderName, saved.modified, app))]
        }
        let openThreads = Set(app.conversations.compactMap { $0.codex?.threadID })
        options += app.codexHistory.filter { !openThreads.contains($0.id) }.map { saved in
            ["id": .string("ch:" + saved.id), "text": .string(app.name(of: saved)),
             "group": .string(app.t("История Codex — продолжить", "Codex history — continue")),
             "note": .string(savedNote(saved.folderName, saved.updated, app))]
        }
        var menu: [String: JSONValue] = ["id": "session", "text": "", "options": .array(options)]
        if let selection = app.selection { menu["selected"] = .string("s:" + selection.uuidString) }
        return .object(menu)
    }

    // MARK: - The body

    /// The question before a session closes, here: for the one shown, or one
    /// whose ✕ was pressed in the menu.
    static func closeAsk(_ app: AgentsApp) -> JSONValue? {
        guard let id = app.confirmingClose, let closing = app.conversations.first(where: { $0.id == id }) else { return nil }
        return app.closeAskRow(closing)
    }

    static func tiny(_ app: AgentsApp) -> [JSONValue] {
        guard !app.conversations.isEmpty else { return [["text": .string(app.t("Сессий нет", "No sessions"))]] }
        return [["list": .array(app.conversations.map { session in
            ["text": .string(session.title), "note": .string(stateWord(session, app)), "icon": .string(icon(session))]
        })]]
    }

    static func body(_ app: AgentsApp) -> [JSONValue] {
        guard let session = app.selected else {
            guard !app.conversations.isEmpty else {
                return [["text": .string(app.t(
                    "Сессий нет. Новая — ＋ справа вверху, продолжить сохранённую — в меню рядом с названием",
                    "No sessions. Start one with ＋ at the top right, or continue a saved one from the menu by the name"))]]
            }
            // Each session where it is: choosing one shows it — here, or
            // in the place it has of its own.
            let everywhere = app.conversations.allSatisfy { app.place(showing: $0.id) != nil }
            return (closeAsk(app).map { [["ask": $0]] } ?? []) + [
                ["text": .string(everywhere
                    ? app.t("Все сессии открыты в других местах. Выберите, чтобы показать",
                            "Every session is shown in another place. Choose one to bring it forward")
                    : app.t("Выберите сессию", "Choose a session"))],
                ["chips": .array(app.conversations.map { session in
                    ["id": .string("s:" + session.id.uuidString),
                     "text": .string(String(session.title.prefix(40)) + " · " + placeNote(session, app))]
                })],
            ]
        }
        var rows: [JSONValue] = compact(app) ? [] : [status(session, app)] + app.keepAwakeRows()
        // The card is sent whole on every change, five times a second while
        // words stream in, and uDeck lays all of it out: the newest entries
        // only, and no entry longer than a screenful.
        let keep = app.size.rows <= 4 ? 30 : 60
        rows.append(["feed": .array(session.feed.suffix(keep).map {
            feedEntry($0.item, app, label: $0.label, files: $0.item.uuid.flatMap { session.files(of: $0) },
                      folder: session.folder)
        })])
        let held = app.heldBack[session.id] != nil
        if held { rows.append(["ask": heldRow(session, app)]) }
        if let closing = closeAsk(app) { rows.append(["ask": closing]) }
        if let unsent = unsentRow(session, app) { rows.append(["bar": unsent]) }
        if let waiting = waitingRow(session, app) { rows.append(["bar": waiting]) }
        switch session.current {
        case .claude(let agent): for ask in agent.asks { rows.append(["ask": askRow(ask, app)]) }
        case .codex(let agent): for ask in agent.asks { rows.append(["ask": codexAskRow(ask, app)]) }
        }
        if !held, let live = liveRow(session, app) { rows.append(["bar": live]) }
        rows.append(["input": input(session, app, held: held)])
        return rows
    }

    /// Above the field while a turn runs, as the terminal's «✻ Crafting…
    /// (18m 43s · ↓ 87.2k tokens)»: what the agent does, the turn's time and
    /// the tokens that came; a call tried again says why and when (the
    /// operator's «1», 11-26).
    /// After this long without a word from the agent — outside a running
    /// tool, which says nothing until it ends — the line says so.
    static let silenceShown: TimeInterval = 30

    /// The line above the field while the agent works (the operator's «1»,
    /// 11-27): what it does and for how long this step, how long it has said
    /// nothing when that is long, the whole turn's time and its tokens — in
    /// forms that get shorter for a narrow card, the step always kept. uDeck
    /// turns a ✻ before it (`busy`), so that a step of minutes is seen alive.
    static func liveRow(_ session: Conversation, _ app: AgentsApp, now: Date = Date()) -> JSONValue? {
        let agent = session.current
        guard agent.state == .working, let activity = agent.activity else { return nil }
        let elapsed = agent.turnStartedAt.map { clock(now.timeIntervalSince($0)) }
        var forms: [[String]]
        let tone: String
        var busy = true
        switch activity {
        case .retrying(let status, let error, let attempt, let next):
            let reason = "↻ " + retryReason(status: status, error: error, app)
            let tryNumber = app.t("попытка \(attempt)", "attempt \(attempt)")
            var again: String?
            if let next {
                let wait = max(0, Int(next.timeIntervalSince(now).rounded()))
                again = app.t("снова через ", "again in ") + (wait >= 120 ? clock(TimeInterval(wait)) : app.t("\(wait) с", "\(wait)s"))
            }
            forms = [[reason, tryNumber, again, elapsed].compactMap { $0 },
                     [reason, again].compactMap { $0 },
                     [reason]]
            tone = "warn"
            busy = false
        default:
            let stepTime = clock(now.timeIntervalSince(agent.activitySince))
            let step = doing(activity, app) + " " + stepTime
            let silent = now.timeIntervalSince(agent.lastHeard)
            let quietIsTheTool: Bool = switch activity {
            case .tool, .asking: true
            default: false
            }
            let silence = !quietIsTheTool && silent >= silenceShown ? app.t("тишина ", "silent ") + clock(silent) : nil
            let total = elapsed.map { app.t("всего ", "in all ") + $0 }
            let tokens = agent.tokens.total > 0 ? agent.tokens : nil
            forms = [[step, silence, total, tokens.map { tokenCount($0, app) }].compactMap { $0 },
                     [step, silence, total, tokens.map { tokenCount($0, app, short: true) }].compactMap { $0 },
                     [step, silence, tokens.map { tokenCount($0, app, short: true) }].compactMap { $0 },
                     [step, silence].compactMap { $0 },
                     // The narrowest, cut at its end by uDeck: what matters
                     // most first — the silence, else the step's time — so
                     // that a long tool's name is what is cut (lab 45989126124:
                     // «Отправляет запрос 0:36 · ти…»).
                     [silence.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? stepTime, doing(activity, app)]]
            tone = silence == nil ? "run" : "warn"
            if case .asking = activity { busy = false }
        }
        var texts: [String] = []
        for form in forms.map({ $0.joined(separator: " · ") }) where !texts.contains(form) { texts.append(form) }
        var badge: [String: JSONValue] = ["text": .string(texts[0]), "tone": .string(tone)]
        if busy { badge["busy"] = true }
        if texts.count > 1 { badge["shorter"] = .array(texts.dropFirst().map { .string($0) }) }
        return ["id": "live", "items": [["badge": .object(badge)]]]
    }

    static func doing(_ activity: AgentActivity, _ app: AgentsApp) -> String {
        switch activity {
        case .requesting: app.t("Отправляет запрос", "Asking the model")
        case .thinking: app.t("Думает", "Thinking")
        case .writing: app.t("Пишет ответ", "Writing")
        case .preparing(let tool): app.t("Готовит \(tool)", "Preparing \(tool)")
        case .tool(let tool): app.t("Выполняет \(tool)", "Running \(tool)")
        case .asking: app.t("Ждёт твоего ответа", "Waiting for you")
        case .retrying: app.t("Повторяет запрос", "Trying again")
        }
    }

    /// Why a call is tried again, in words.
    static func retryReason(status: Int?, error: String, _ app: AgentsApp) -> String {
        let code = status.map { " (\($0))" } ?? ""
        switch status {
        case 529?: return app.t("Сервер перегружен", "The server is overloaded") + code
        case 429?: return app.t("Лимит запросов", "Too many requests") + code
        case let value? where value >= 500: return app.t("Ошибка сервера", "A server error") + code
        case let value? where value >= 400: return app.t("Запрос отклонён", "The request was refused") + code
        default:
            if error.lowercased().contains("overload") { return app.t("Сервер перегружен", "The server is overloaded") }
            if error.isEmpty || error.lowercased().contains("connect") || error.lowercased().contains("network") {
                return app.t("Нет связи с сервером", "No connection to the server")
            }
            return clipped(error, 120)
        }
    }

    /// «↓ ~1,4 тыс. токенов» — the tilde while part of it is an estimate.
    /// «↓ ~30,7 тыс. токенов», and short, «↓ ~30,7 тыс.».
    static func tokenCount(_ tokens: TurnTokens, _ app: AgentsApp, short: Bool = false) -> String {
        let about = tokens.estimated ? "~" : ""
        let total = tokens.total
        guard total >= 1000 else {
            return "↓ " + about + (short ? "\(total)" : app.t("\(total) токенов", "\(total) tokens"))
        }
        let thousands = (Double(total) / 1000 * 10).rounded() / 10
        let number = thousands >= 100 ? String(Int(thousands.rounded())) : String(format: "%.1f", thousands)
        let russian = number.replacingOccurrences(of: ".", with: ",") + (short ? " тыс." : " тыс. токенов")
        return "↓ " + about + app.t(russian, number + (short ? "k" : "k tokens"))
    }

    /// Under the feed while messages wait for the step the agent is on: how
    /// many, and «Отправить сейчас» — the step stopped, they go at once (the
    /// operator, 11-27: a message queued, and nothing to send it with).
    static func waitingRow(_ session: Conversation, _ app: AgentsApp) -> JSONValue? {
        let agent = session.current
        let count = agent.waitingMessages.count
        guard count > 0, agent.state == .working else { return nil }
        let said = app.t(russianCount(count, "сообщение ждёт", "сообщения ждут", "сообщений ждут"),
                         count == 1 ? "1 message waits" : "\(count) messages wait")
        return ["id": "waiting", "items": [
            ["badge": ["text": .string(said), "tone": "info"]],
            ["spacer": true],
            ["button": ["id": "waiting:now", "label": .string(app.t("Отправить сейчас", "Send now"))]],
        ]]
    }

    /// Under the feed while a Stop left messages unsent: how many, and the
    /// two ways on — all sent, oldest first, or their text into the field
    /// (the operator's «1», 11-26).
    static func unsentRow(_ session: Conversation, _ app: AgentsApp) -> JSONValue? {
        let count = session.unsentMessages.count
        guard count > 0, !session.current.isEnded else { return nil }
        let said = app.t(russianCount(count, "сообщение не отправлено", "сообщения не отправлены", "сообщений не отправлено"),
                         count == 1 ? "1 message not sent" : "\(count) messages not sent")
        return ["id": "unsent", "items": [
            ["badge": ["text": .string(said), "tone": "wait"]],
            ["spacer": true],
            ["button": ["id": "unsent:send", "label": .string(app.t("Отправить все", "Send all"))]],
            ["button": ["id": "unsent:field", "label": .string(app.t("В поле", "Into the field"))]],
        ]]
    }

    /// What the session is doing, how full its context is, and where it works.
    static func status(_ session: Conversation, _ app: AgentsApp) -> JSONValue {
        var items: [JSONValue] = [["badge": stateBadge(session, app)]]
        if let percent = session.current.contextPercent {
            let tone = percent >= 90 ? "crit" : percent >= 75 ? "warn" : "info"
            items.append(["badge": ["text": .string(app.t("контекст \(Int(percent.rounded()))%", "context \(Int(percent.rounded()))%")),
                                    "tone": .string(tone), "fill": .number(percent / 100)]])
        }
        if case .codex(let codex) = session.current, let limits = codex.rateLimits, let badge = codexLimits(limits, app) {
            items.append(["badge": badge])
        }
        if !narrow(app) {
            items.append(["badge": ["text": .string(session.folder.lastPathComponent), "icon": "folder"]])
        }
        return ["bar": ["id": "status", "items": .array(items)]]
    }

    /// Codex's own limits for the account it runs on, as the Claude accounts'
    /// are said in their menu: «5 ч 34% · неделя 12%», tinted as they fill.
    static func codexLimits(_ limits: CodexRateLimits, _ app: AgentsApp) -> JSONValue? {
        let windows = [limits.primary, limits.secondary].compactMap { $0 }
        guard !windows.isEmpty else { return nil }
        let text = windows.map { window in
            windowName(window.minutes, app) + " " + "\(Int((window.usage.used * 100).rounded()))%"
        }.joined(separator: " · ")
        let fullest = windows.map(\.usage.used).max() ?? 0
        let tone = fullest >= 0.9 ? "crit" : fullest >= 0.75 ? "warn" : "info"
        return ["text": .string(text), "tone": .string(tone), "icon": "account"]
    }

    static func windowName(_ minutes: Int?, _ app: AgentsApp) -> String {
        guard let minutes else { return app.t("лимит", "limit") }
        if minutes == 7 * 24 * 60 { return app.t("неделя", "week") }
        if minutes % (24 * 60) == 0 { return app.t("\(minutes / (24 * 60)) д", "\(minutes / (24 * 60))d") }
        if minutes % 60 == 0 { return app.t("\(minutes / 60) ч", "\(minutes / 60)h") }
        return app.t("\(minutes) мин", "\(minutes)m")
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
            : agent.state == .working ? (narrow(app) ? app.t("По ходу", "Mid-turn")
                : app.t("Работает · сообщение войдёт после текущего шага", "Working · a message goes in after the current step"))
            : narrow(app) ? app.t("Сообщение", "Message")
            : app.t("Сообщение · Return отправляет, Shift+Return — новая строка",
                    "Message · Return sends, Shift+Return starts a new line")
        var input: [String: JSONValue] = [
            "id": "message",
            "placeholder": .string(placeholder),
            "enabled": .bool(!agent.isEnded && !held),
        ]
        if agent.state == .working { input["stop"] = "stop" }
        // Files go with a message: pictures as pictures, the rest by path (uDeck 0.9.17).
        if !held, !agent.isEnded { input["files"] = true }
        // Unsent messages put back to be edited: in the field until sent from it (uDeck 0.9.19).
        if let fill = session.fill { input["fill"] = ["id": .string(fill.id), "text": .string(fill.text)] }
        // Commands, skills and files on «/» and «@» (uDeck 0.9.25).
        if !held, !agent.isEnded {
            var suggest: [String: JSONValue] = ["tabs": .array(AgentsSuggest.tabs(app)),
                                                "items": .array(AgentsSuggest.items(agent, app))]
            let recent = app.recentCommands[agent.provider.rawValue] ?? []
            if !recent.isEmpty { suggest["recent"] = .array(recent.map { .string($0) }) }
            if let found = app.foundFiles[app.here] {
                suggest["found"] = ["tab": "files", "query": .string(found.query),
                                    "items": .array(found.files.enumerated().map { index, path in
                                        ["id": .string("f:\(index):" + path), "tab": "files", "text": .string("@" + path),
                                         "title": .string((path as NSString).lastPathComponent),
                                         "detail": .string((path as NSString).deletingLastPathComponent)]
                                    })]
            }
            input["suggest"] = .object(suggest)
        }
        guard !held, !agent.isEnded, !compact(app) else { return .object(input) }
        var pickers: [JSONValue] = []
        if case .claude(let claude) = agent, app.accounts.count > 1 {
            pickers.append(accountMenu(claude, app))
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
                 "text": .string(effortName(level, app) + (level == app.effortShown(agent) ? "  ✓" : "")),
                 "group": .string(app.t("Усилие", "Effort"))]
            }
            var menu: [String: JSONValue] = [
                "id": "me", "text": .string(shortModel(agent) + " · " + (app.effortShown(agent).map { effortName($0, app) } ?? app.t("усилие", "effort"))),
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
                "text": .string(app.effortShown(agent).map { effortName($0, app) } ?? app.t("усилие", "effort")),
                "note": .string(agent.provider == .claude
                    ? app.t("Со следующего сообщения: сессия продолжится с ним", "From the next message: the session continues with it")
                    : app.t("Со следующего сообщения", "From the next message")),
                "options": .array(efforts.map { ["id": .string($0), "text": .string(effortName($0, app))] }),
            ]
            if let level = app.effortShown(agent) { effort["selected"] = .string(level) }
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

    /// The account menu by the field: «Авто» and why it picks what it picks,
    /// then each account with its limits — picking one moves the session.
    static func accountMenu(_ session: ChatSession, _ app: AgentsApp) -> JSONValue {
        let now = Date()
        let group = app.t("Учётка", "Account")
        var options: [JSONValue] = [["id": "auto", "text": .string(app.t("Авто", "Auto")), "group": .string(group),
                                     "note": .string(autoReason(app, now: now))]]
        for account in app.accounts {
            var option: [String: JSONValue] = ["id": .string(account.name), "text": .string(accountName(account, app)),
                                               "group": .string(group), "note": .string(limitsText(account, app, now: now))]
            let limits = app.limits[account.name]
            if limits?.isLimited(at: now) == true || (limits?.fiveHour?.used ?? 0) >= 0.9 || (limits?.week?.used ?? 0) >= 0.9 {
                option["tone"] = "warn"
            }
            options.append(.object(option))
        }
        let text = app.autoAccount ? app.t("Авто · ", "Auto · ") + accountName(session.account, app)
            : accountName(session.account, app)
        return ["id": "account", "text": .string(text), "icon": "account",
                "selected": .string(app.autoAccount ? "auto" : session.account.name),
                "note": .string(app.t("Выбор учётки здесь переносит эту сессию на неё сразу. «Авто» выбирает для новых сессий и переносит сессию, когда у учётки кончился лимит",
                                      "Choosing an account here moves this session to it now. Auto picks for new sessions and moves a session when its account runs out")),
                "options": .array(options)]
    }

    /// Why «Авто» picks what it would pick now.
    static func autoReason(_ app: AgentsApp, now: Date) -> String {
        guard let (account, pick) = app.autoPick(now: now) else {
            return app.t("сейчас все учётки упёрлись в лимит", "every account is at its limit now")
        }
        let name = accountName(account, app)
        let why: String = switch pick.reason {
        case .mostHeadroom:
            app.t("больше всего запаса", "the most left")
        case .burnsSoonest:
            app.t("её неделя сгорит раньше", "its week expires first")
        case .fewestSessions:
            app.t("меньше всего сессий", "the fewest sessions")
        case .onlyTheMainLeft:
            app.t("других не осталось", "nothing else is left")
        }
        return app.t("сейчас ", "now ") + name + ": " + why + (pick.estimated && app.limits.isEmpty ? app.t(" (оценка)", " (a guess)") : "")
    }

    /// An account's limits in a line: «5 ч 92% · неделя 71% · сброс в 18:40».
    static func limitsText(_ account: ChatAccount, _ app: AgentsApp, now: Date) -> String {
        guard let limits = app.limits[account.name] else { return app.t("лимиты ещё не известны", "limits not known yet") }
        var parts: [String] = []
        if let five = limits.fiveHour { parts.append(app.t("5 ч ", "5 h ") + percent(five.used)) }
        if let week = limits.week { parts.append(app.t("неделя ", "week ") + percent(week.used)) }
        if limits.isLimited(at: now), let until = limits.limitedUntil {
            parts.append(app.t("лимит до ", "limit until ") + time(until, app, now: now))
        } else if let five = limits.fiveHour, five.used >= 0.8, let resets = five.resetsAt {
            parts.append(app.t("сброс ", "resets ") + when(resets, app, now: now))
        }
        return parts.isEmpty ? app.t("лимиты ещё не известны", "limits not known yet") : parts.joined(separator: " · ")
    }

    static func percent(_ fraction: Double) -> String { "\(Int((max(0, min(1, fraction)) * 100).rounded()))%" }

    /// «в 18:40» today, «пт 18:40» another day.
    static func when(_ date: Date, _ app: AgentsApp, now: Date) -> String {
        Calendar.current.isDate(date, inSameDayAs: now) ? app.t("в ", "at ") + time(date, app, now: now)
            : time(date, app, now: now)
    }

    static func time(_ date: Date, _ app: AgentsApp, now: Date) -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: app.russian ? "ru_RU" : "en_US")
        format.dateFormat = Calendar.current.isDate(date, inSameDayAs: now) ? "HH:mm" : "EE HH:mm"
        return format.string(from: date)
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

    /// A saved session's folder and when it was last written to.
    static func savedNote(_ folder: String?, _ date: Date, _ app: AgentsApp) -> String {
        [folder, ago(date, app)].compactMap { $0 }.joined(separator: " · ")
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

    static func feedEntry(_ item: FeedItem, _ app: AgentsApp, label: String? = nil, files: [String]? = nil,
                          folder: URL? = nil) -> JSONValue {
        switch item {
        case .user(let id, let text):
            var entry: [String: JSONValue] = ["id": .string(id.uuidString), "role": "user", "text": .string(clipped(text))]
            // Drawn above the message, opened by a click (uDeck 0.9.23).
            if let files, !files.isEmpty { entry["files"] = .array(files.map { .string($0) }) }
            if label == Conversation.waitingLabel {
                entry["label"] = .string(app.t("войдёт после текущего шага", "goes in after the current step"))
            } else if label == Conversation.unsentLabel {
                entry["label"] = .string(app.t("не отправлено", "not sent"))
            } else if label == Conversation.startingLabel {
                entry["label"] = .string(app.t("уйдёт, когда сессия запустится", "goes once the session is up"))
            }
            return .object(entry)
        case .assistant(let id, let text, let streaming):
            // A finished answer's paths to files are links (uDeck 0.9.27).
            let shown = !streaming && folder != nil ? PathLinks.link(clipped(text), folder: folder!) : clipped(text)
            var entry: [String: JSONValue] = ["id": .string(id.uuidString), "role": "assistant", "text": .string(shown),
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
        if text == "stopped" { return app.t("Остановлено", "Stopped") }
        if text == "not-sent" {
            return app.t("Сообщение не дошло до агента — оно внизу, в «не отправлено»",
                         "The message did not reach the agent — it is below, not sent")
        }
        if text == "not sent: the session has ended" {
            return app.t("Не отправлено: сессия завершилась", "Not sent: the session has ended")
        }
        if text.hasPrefix("renamed:") { return app.t("Сессия называется «", "The session is called “") + text.dropFirst(8) + app.t("»", "”") }
        if text == "rename-how" {
            return app.t("Чтобы переименовать, напиши /rename и новое имя", "To rename it, write /rename and the new name")
        }
        if text == "loading-history" { return app.t("Читаю историю…", "Reading the history…") }
        if text == "compact" { return app.t("Сжимаю разговор…", "Compacting the thread…") }
        if text == "compact-failed" { return app.t("Не удалось сжать разговор", "Could not compact the thread") }
        if text == "review-failed" { return app.t("Не удалось начать ревью", "Could not start the review") }
        if text == "model-how" {
            return app.t("Чтобы сменить модель, напиши /model и её имя — или выбери в меню модели",
                         "To change the model, write /model and its name — or pick it in the model menu")
        }
        if text.hasPrefix("model-unknown:") {
            return app.t("Нет такой модели: ", "No such model: ") + text.dropFirst(14)
        }
        if text == "effort-how" {
            return app.t("Чтобы сменить усилие, напиши /effort и уровень — или выбери в меню усилия",
                         "To change the effort, write /effort and a level — or pick it in the effort menu")
        }
        if text == "compacted" { return app.t("Здесь контекст был сжат", "The context was compacted here") }
        if text.hasPrefix("model:") { return app.t("Модель: ", "Model: ") + model(String(text.dropFirst(6))) }
        if text.hasPrefix("model-failed:") {
            return app.t("Не удалось сменить модель на ", "Could not switch the model to ") + model(String(text.dropFirst(13)))
        }
        if text.hasPrefix("effort:") {
            return app.t("Усилие: ", "Effort: ") + effortName(String(text.dropFirst(7)), app)
                + app.t(" — сессия продолжена с ним", " — the session continues with it")
        }
        if text.hasPrefix("limit-move:") || text.hasPrefix("limit-wait:") || text.hasPrefix("limit-stop:") {
            let parts = text.split(separator: ":", maxSplits: 1).last.map { $0.split(separator: "|").map(String.init) } ?? []
            func named(_ name: String) -> String {
                app.accounts.first { $0.name == name }.map { accountName($0, app) } ?? name
            }
            // «Лимит основной учётки», «на основную учётку»; a named one as it is.
            func whose(_ name: String) -> String {
                app.accounts.first { $0.name == name }?.configDir == nil && app.russian ? "основной учётки" : named(name)
            }
            func onto(_ name: String) -> String {
                app.accounts.first { $0.name == name }?.configDir == nil && app.russian ? "основную учётку" : named(name)
            }
            let epoch = parts.last.flatMap(Double.init).map { Date(timeIntervalSince1970: $0) } ?? Date()
            let at = time(epoch, app, now: Date())
            if text.hasPrefix("limit-move:"), parts.count == 3 {
                return app.t("Лимит \(whose(parts[0])) кончился, сброс в \(at) — сессия продолжилась на \(onto(parts[1]))",
                             "\(named(parts[0])) ran out of its limit, resets at \(at) — the session went on under \(named(parts[1]))")
            }
            if text.hasPrefix("limit-wait:"), parts.count == 2 {
                return app.t("Лимит кончился у всех учёток. Ближайший сброс — у \(whose(parts[0])) в \(at), тогда продолжу сам",
                             "Every account is at its limit. The first to reset is \(named(parts[0])) at \(at); it goes on then")
            }
            if parts.count == 2 {
                return app.t("Лимит \(whose(parts[0])) кончился, сброс в \(at) — тогда продолжу сам",
                             "\(named(parts[0])) ran out of its limit, resets at \(at); it goes on then")
            }
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

    /// What a session is doing, and where it is shown when that is another
    /// place than this one: «в окне · работает».
    static func placeNote(_ session: Conversation, _ app: AgentsApp) -> String {
        let state = stateWord(session, app)
        guard let other = app.place(showing: session.id), let kind = app.places[other]?.kind else { return state }
        let place = switch kind {
        case "tab": app.t("во вкладке", "in a tab")
        case "window": app.t("в окне", "in a window")
        case "mini": app.t("в мини-окне", "in a mini window")
        default: app.t("на доске", "on the board")
        }
        return place + " · " + state
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
