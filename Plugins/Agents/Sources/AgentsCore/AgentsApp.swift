import Foundation
import UDeckAgents

/// The Agents plugin: its conversations, and the card it shows uDeck for them.
///
/// uDeck draws the card; this decides what is on it (`AgentsCard`) and turns
/// what the person does on the card — events — into what the agents do. A
/// conversation is answered by Claude, by Codex, or by both in turn.
@MainActor
public final class AgentsApp {
    public private(set) var conversations: [Conversation] = []
    /// One place uDeck shows the card in — its cell on the board, a tab, a
    /// window, a mini window — its size there, and what it shows.
    public struct Place {
        public var size = (columns: 6, rows: 4)
        public var selection: UUID?
        public var showingHistory = false
        /// Where uDeck says it is: `card`, `tab`, `window` or `mini`.
        public var kind = "card"
        /// The session whose ✕ was pressed here: the card asks first.
        public var confirmingClose: UUID?
    }
    /// Every place, by uDeck's name for it (`view`): "" until uDeck names
    /// one, and for good on a uDeck older than places.
    public internal(set) var places: [String: Place] = ["": Place()]
    /// The place an event came from, or the card is drawn for, now.
    public private(set) var here = ""
    public private(set) var russian = false

    /// The conversation shown here.
    public var selection: UUID? {
        get { places[here]?.selection }
        set { places[here, default: Place()].selection = newValue }
    }
    public var size: (columns: Int, rows: Int) { places[here]?.size ?? (6, 4) }
    public private(set) var showingHistory: Bool {
        get { places[here]?.showingHistory ?? false }
        set { places[here, default: Place()].showingHistory = newValue }
    }
    public private(set) var history: [SavedSession] = []
    /// Conversations opened from history only to be read, because their
    /// transcript was written to a moment ago — by when it was last written.
    public private(set) var heldBack: [UUID: Date] = [:]
    /// How recent a write to a saved session means it is open somewhere else.
    static let liveWindow: TimeInterval = 10 * 60
    public let accounts: [ChatAccount]
    public private(set) var account: ChatAccount
    /// What each account's limits were last seen to be, by its name.
    public internal(set) var limits: [String: AccountLimits] = [:]
    /// Whether «Авто» picks the account for a new session and moves a session
    /// whose account ran out of its limit: on, until one is chosen by hand.
    public internal(set) var autoAccount = true
    /// When each account's limits were last asked for by a probe, and the
    /// probes running.
    var probedAt: [String: Date] = [:]
    var probing: Set<String> = []
    var probeLoop: Task<Void, Never>?
    /// The Mac kept awake while an agent works, and the look for a sleep.
    public let keepAwake: KeepAwake
    var sleepLoop: Task<Void, Never>?
    /// The session whose ✕ was pressed here: the card asks before it closes.
    public internal(set) var confirmingClose: UUID? {
        get { places[here]?.confirmingClose }
        set { places[here, default: Place()].confirmingClose = newValue }
    }
    /// The names of sessions this plugin keeps, and how many times a name
    /// was asked of a model for each in this run.
    var names: ChatNames
    /// Messages a Stop left unsent, kept on disk by session.
    var unsent: UnsentStore
    var namingTries: [String: Int] = [:]
    /// The history's sessions being named, one at a time.
    var historyNaming: Task<Void, Never>?
    /// What the transcripts in the history said, by path, until they change.
    var historyGlances: SessionHistory.Glances = [:]
    /// Sessions waiting for a limit to reset, to go on then.
    var waitingForLimit: [UUID: Task<Void, Never>] = [:]
    /// The models each provider offered when a session of it last started,
    /// kept for the model menu of a conversation that has not used it yet.
    public private(set) var knownModels: [Provider: [ModelChoice]] = [:]
    /// Codex threads the CLI saved, for the session menu.
    public private(set) var codexHistory: [CodexSaved] = []

    /// Where lines for uDeck go (stdout).
    let emit: (String) -> Void
    let home: URL
    private var shellEnvironment: [String: String]?
    /// The card last written for each place.
    private var lastCards: [String: String] = [:]
    /// When the saved sessions were last read: the session menu lists them,
    /// and a menu cannot say it is about to open.
    private var historyRead = Date.distantPast
    /// Conversations whose Claude session starts again once its running turn
    /// has finished — a new effort or login chosen mid-turn — and the note.
    var restartAfterTurn: [UUID: String] = [:]

    public init(home: URL, emit: @escaping (String) -> Void, keepAwake: KeepAwake? = nil) {
        self.home = home
        self.emit = emit
        self.keepAwake = keepAwake ?? KeepAwake()
        accounts = ChatAccount.discover(home: home)
        account = accounts[0]
        names = ChatNames.load(home: home)
        unsent = UnsentStore.load(home: home)
        knownModels[.claude] = Self.claudeAliases
    }

    /// What the menu offers for Claude before any session said what it has:
    /// the aliases `claude --model` takes.
    static let claudeAliases = [ModelChoice(value: "opus", name: "Opus"), ModelChoice(value: "sonnet", name: "Sonnet"),
                                ModelChoice(value: "haiku", name: "Haiku")]

    // MARK: - Events from uDeck

    public func handle(_ line: String) async {
        guard let event = JSONValue.line(Substring(line)), let kind = event["event"]?.string else { return }
        if let view = event["view"]?.string, !view.isEmpty {
            if places[view] == nil {
                guard kind != "closed" else { return }
                // The first place uDeck names is the one drawn until then.
                if let unnamed = places.removeValue(forKey: "") {
                    places[view] = unnamed
                    lastCards[""] = nil
                } else {
                    places[view] = Place()
                }
            }
            here = view
        }
        switch kind {
        case "hello", "size":
            if let columns = event["size"]?["columns"]?.int, let rows = event["size"]?["rows"]?.int {
                places[here, default: Place()].size = (columns, rows)
            }
            if let place = event["place"]?.string { places[here, default: Place()].kind = place }
            if let language = event["language"]?.string { russian = language.hasPrefix("ru") }
            if kind == "hello" {
                // uDeck took this plugin back after it started again, or saw
                // the place for the first time: the card is written again.
                lastCards[here] = nil
                watchLimits()
                watchSleep()
                refreshHistory()
                if knownModels[.codex] == nil || codexHistory.isEmpty { Task { await learnCodex() } }
                if let keep = event["keep"]?.string { restore(keep) }
            }
        case "closed":
            closed(here, to: event["to"]?.string)
        case "select":
            select(event["id"]?.string ?? "")
        case "press":
            press(event["id"]?.string ?? "")
        case "submit":
            let text = event["text"]?.string ?? ""
            let files = (event["files"]?.array ?? []).compactMap(\.string)
            if files.isEmpty, renameFromTheField(text) { break }
            // Sent from the field: what was put back into it is the person's now.
            selected?.fill = nil
            selected?.send(text, files: files)
        case "folder":
            let id = event["id"]?.string ?? ""
            if id.hasPrefix("new"), let path = event["path"]?.string {
                // `new:<provider>@<place>`: the session opens where ＋ was pressed.
                let parts = id.dropFirst(4).split(separator: "@", maxSplits: 1).map(String.init)
                if parts.count == 2, places[parts[1]] != nil { here = parts[1] }
                let provider = Provider(rawValue: parts.first ?? "") ?? .claude
                await newConversation(in: URL(fileURLWithPath: path, isDirectory: true), provider: provider)
            }
        case "notification":
            if let id = event["id"]?.string, let uuid = UUID(uuidString: id) {
                // A button of the notification: the answer it names, as on
                // the card — nothing, for a question answered meanwhile.
                if let action = event["action"]?.string {
                    press(action)
                    break
                }
                // A reply written in it: the question's answer, or a message.
                if let text = event["text"]?.string {
                    reply(text, to: uuid)
                    break
                }
                // Shown in a place of its own: that place comes forward.
                if let other = place(showing: uuid) {
                    send(["show": ["view": .string(other)]])
                } else {
                    take(uuid)
                }
            }
        case "choose":
            choose(menu: event["menu"]?.string ?? "", option: event["option"]?.string ?? "")
        default:
            return
        }
        render()
    }

    var selected: Conversation? { conversations.first { $0.id == selection } }

    /// A reply written in a notification of `id`: the answer to its open
    /// question, or else a message — taken by the agent as it works.
    private func reply(_ text: String, to id: UUID) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let conversation = conversations.first(where: { $0.id == id }),
              heldBack[id] == nil else { return }
        if let session = conversation.claude, conversation.active == .claude,
           let ask = session.asks.first(where: { $0.ask.questions?.first != nil }),
           let question = ask.ask.questions?.first {
            session.answer(ask, with: .choices([question.question: [text]]))
            unnotify(id)
            return
        }
        conversation.send(text)
    }

    // MARK: - Places

    /// The place other than here that shows `id`.
    public func place(showing id: UUID) -> String? {
        places.keys.sorted().first { $0 != here && places[$0]?.selection == id }
    }

    /// Shows the conversation `id` here — or, shown in another place
    /// already, brings that place forward: one conversation, one place.
    func show(_ id: UUID) {
        if let other = place(showing: id) {
            send(["show": ["view": .string(other)]])
            return
        }
        selection = id
        showingHistory = false
    }

    /// Shows `id` here, and another place that showed it something else.
    private func take(_ id: UUID) {
        selection = id
        showingHistory = false
        for name in places.keys.sorted() where name != here && places[name]?.selection == id {
            let next = unshown()
            places[name]?.selection = next
        }
    }

    /// The newest conversation no place shows.
    /// Takes the conversation off the list: a place that showed it shows
    /// another one not shown elsewhere, or none.
    func forget(_ id: UUID) {
        conversations.removeAll { $0.id == id }
        heldBack[id] = nil
        restartAfterTurn[id] = nil
        waitingForLimit.removeValue(forKey: id)?.cancel()
        for name in places.keys.sorted() where places[name]?.selection == id {
            places[name]?.selection = nil
            let next = unshown()
            places[name]?.selection = next
        }
    }

    private func unshown() -> UUID? {
        let shown = Set(places.values.compactMap(\.selection))
        return conversations.last { !shown.contains($0.id) }?.id
    }

    /// uDeck closed the place `view`; with `to`, what it showed goes there.
    private func closed(_ view: String, to: String?) {
        guard let gone = places.removeValue(forKey: view) else { return }
        lastCards[view] = nil
        if places.isEmpty { places[""] = Place() }
        guard let to, places[to] != nil else {
            here = places.keys.sorted().first ?? ""
            return
        }
        here = to
        if let selection = gone.selection, conversations.contains(where: { $0.id == selection }) {
            take(selection)
        }
    }

    /// What a place showed before, by what uDeck kept of it (`keep`): the
    /// conversation, while it is open; otherwise its Claude session or its
    /// Codex thread, continued — after uDeck or this plugin started again.
    private func restore(_ keep: String) {
        guard let kept = Kept(keep) else { return }
        let found = conversations.first { kept.id != nil && $0.id == kept.id }
            ?? conversations.first { kept.claude != nil && $0.claude?.sessionID == kept.claude }
            ?? conversations.first { kept.codex != nil && $0.codex?.threadID == kept.codex }
        if let found {
            take(found.id)
            return
        }
        if let sessionID = kept.claude {
            let login = accounts.first { $0.name == kept.account } ?? account
            guard let saved = SessionHistory.saved(sessionID, config: login.folder(home: home)) else { return }
            // Its own, a moment ago: no other program has it open.
            open(saved, account: login, holdIfRecent: false)
        } else if let threadID = kept.codex {
            let folder = URL(fileURLWithPath: kept.folder ?? home.path, isDirectory: true)
            let session = CodexSession(folder: folder, title: kept.title, threadID: threadID)
            adopt(.codex(session))
            Task {
                await startCodex(session)
                render()
            }
        }
    }

    private func select(_ id: String) {
        if id == "new" || id.hasPrefix("new:") {
            let provider = id.hasPrefix("new:") ? String(id.dropFirst(4)) : "claude"
            send(["pick": ["id": .string("new:" + provider + (here.isEmpty ? "" : "@" + here)),
                           "prompt": .string(t("Папка для новой сессии", "Choose the folder to work in"))]])
        } else if id == "history" {
            showingHistory.toggle()
            if showingHistory { refreshHistory() }
        } else if id.hasPrefix("s:"), let uuid = UUID(uuidString: String(id.dropFirst(2))) {
            show(uuid)
        } else if id.hasPrefix("ch:") {
            let threadID = String(id.dropFirst(3))
            if let open = conversations.first(where: { $0.codex?.threadID == threadID }) {
                show(open.id)
            } else if let saved = codexHistory.first(where: { $0.id == threadID }) {
                let folder = URL(fileURLWithPath: saved.cwd ?? home.path, isDirectory: true)
                let session = CodexSession(folder: folder, title: name(of: saved), titleSource: saved.source,
                                           threadID: saved.id)
                adopt(.codex(session))
                Task {
                    await startCodex(session)
                    render()
                }
            }
        } else if id.hasPrefix("h:") {
            let sessionID = String(id.dropFirst(2))
            if let saved = history.first(where: { $0.sessionID == sessionID }) { open(saved) }
        } else if id.hasPrefix("acct:"), let chosen = accounts.first(where: { $0.name == String(id.dropFirst(5)) }) {
            account = chosen
        }
    }

    /// An option of a menu on the card: the session menu, the new-session
    /// button, or the field's account, model and effort.
    private func choose(menu: String, option: String) {
        switch menu {
        case "session", "new":
            select(option)
        case "account":
            if option == "auto" {
                autoAccount = true
                return
            }
            guard let chosen = accounts.first(where: { $0.name == option }) else { return }
            autoAccount = false
            account = chosen
            if let conversation = selected, let session = conversation.claude, conversation.active == .claude,
               session.account != chosen {
                session.account = chosen
                restartClaude(conversation, saying: "account:" + chosen.name)
            }
        case "model":
            if let conversation = selected { chooseModel(option, in: conversation) }
        case "effort":
            if let conversation = selected { chooseEffort(option, in: conversation) }
        case "me":
            if option.hasPrefix("m:") { choose(menu: "model", option: String(option.dropFirst(2))) }
            if option.hasPrefix("e:") { choose(menu: "effort", option: String(option.dropFirst(2))) }
        default:
            return
        }
    }

    /// `provider:value` — the active provider's model changes; another's
    /// takes the conversation over.
    private func chooseModel(_ option: String, in conversation: Conversation) {
        let parts = option.split(separator: ":", maxSplits: 1).map(String.init)
        let provider = parts.count == 2 ? Provider(rawValue: parts[0]) ?? conversation.active : conversation.active
        let value = parts.count == 2 ? parts[1] : option
        if provider == conversation.active {
            switch conversation.current {
            case .claude(let session): session.switchModel(to: value)
            case .codex(let session):
                session.chosenModel = value
                session.note("model-next:" + value)
            }
            return
        }
        guard conversation.current.waiting == 0, conversation.current.state != .working else {
            conversation.current.note("switch-busy")
            return
        }
        Task { await switchProvider(conversation, to: provider, model: value) }
    }

    private func chooseEffort(_ level: String, in conversation: Conversation) {
        switch conversation.current {
        case .claude(let session):
            guard session.effort != level else { return }
            session.effort = level
            restartClaude(conversation, saying: "effort:" + level)
        case .codex(let session):
            guard session.effort != level else { return }
            session.effort = level
            session.note("effort-next:" + level)
        }
    }

    private func press(_ id: String) {
        defer { withdrawAnswered() }
        if id == "stop" { selected?.current.interrupt(); return }
        if id == "unsent:send" { selected?.sendUnsent(); return }
        if id == "unsent:field" { selected?.putUnsentIntoField(); return }
        if pressClose(id) { return }
        if id == "new" { select("new"); return }
        if id.hasPrefix("here:") || id.hasPrefix("drop:"), let uuid = UUID(uuidString: String(id.dropFirst(5))),
           heldBack[uuid] != nil, let conversation = conversations.first(where: { $0.id == uuid }) {
            heldBack[uuid] = nil
            if id.hasPrefix("here:"), let session = conversation.claude {
                Task { await startClaude(session, resume: session.sessionID) }
            } else if id.hasPrefix("drop:") {
                forget(uuid)
            }
            return
        }
        let parts = id.split(separator: ":", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else { return }
        let request = parts[1]
        for conversation in conversations {
            if let session = conversation.claude, let ask = session.asks.first(where: { $0.requestID == request }) {
                switch parts[0] {
                case "allow": session.answer(ask, with: .allow)
                case "always": session.answer(ask, with: .allowAlways)
                case "deny": session.answer(ask, with: .deny)
                case "opt":
                    guard parts.count == 3, let index = Int(parts[2]), let question = ask.ask.questions?.first,
                          question.options.indices.contains(index) else { return }
                    session.answer(ask, with: .choices([question.question: [question.options[index].label]]))
                default: return
                }
                return
            }
            if let session = conversation.codex, let ask = session.asks.first(where: { $0.requestID == request }) {
                switch parts[0] {
                case "allow": session.answer(ask, with: "accept")
                case "always": session.answer(ask, with: "acceptForSession")
                case "deny": session.answer(ask, with: "decline")
                default: return
                }
                return
            }
        }
    }

    // MARK: - Conversations

    public func newConversation(in folder: URL, provider: Provider = .claude, message: String? = nil) async {
        switch provider {
        case .claude:
            let session = ChatSession(folder: folder, account: autoAccount ? (autoPick()?.account ?? account) : account)
            let conversation = adopt(.claude(session))
            await startClaude(session, resume: nil)
            if let message, !message.isEmpty { conversation.send(message) }
        case .codex:
            let session = CodexSession(folder: folder)
            let conversation = adopt(.codex(session))
            await startCodex(session)
            if let message, !message.isEmpty { conversation.send(message) }
        }
    }

    /// Kept for the tests and the lab: a new Claude conversation.
    public func newSession(in folder: URL, message: String? = nil) async {
        await newConversation(in: folder, provider: .claude, message: message)
    }

    /// A saved session, continued here. One its transcript was written to a
    /// moment ago may be open in another program, and is held back to be
    /// read first — unless it is this plugin's own (`restore`).
    private func open(_ saved: SavedSession, account: ChatAccount? = nil, holdIfRecent: Bool = true) {
        if let open = conversations.first(where: { $0.claude?.sessionID == saved.sessionID && !($0.claude?.isEnded ?? true) }) {
            show(open.id)
            return
        }
        let folder = URL(fileURLWithPath: saved.cwd ?? home.path, isDirectory: true)
        let (title, source) = saved.named
        let session = ChatSession(folder: folder, account: account ?? historyAccount(for: saved), title: title,
                                  titleSource: source, resumeID: saved.sessionID)
        session.note("loading-history")
        let conversation = adopt(.claude(session))
        showingHistory = false
        // Read off the main thread, and only the transcript's tail: a long
        // session's is a hundred megabytes, and reading it whole here froze
        // the card for seconds after «continue» (0.9.5).
        let file = saved.file
        Task {
            let feed = await Task.detached(priority: .userInitiated) { SessionHistory.tailFeed(of: file) }.value
            session.prependHistory(feed)
            render()
        }
        let written = (try? saved.file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            ?? saved.modified
        if holdIfRecent, Date().timeIntervalSince(written) < Self.liveWindow {
            heldBack[conversation.id] = written
            return
        }
        Task { await startClaude(session, resume: saved.sessionID) }
    }

    @discardableResult
    private func adopt(_ agent: Agent) -> Conversation {
        let conversation = Conversation(agent)
        watch(agent, in: conversation)
        conversations.append(conversation)
        selection = conversation.id
        applyKnownName(conversation)
        // Left unsent when it was open before: back, to be sent or edited.
        if let key = agent.nameKey, let kept = unsent.entries[key], agent.unsentMessages.isEmpty {
            agent.restoreUnsent(kept.texts)
        }
        return conversation
    }

    /// The open conversations' unsent messages, on disk when they change.
    func keepUnsent() {
        var store = unsent
        for conversation in conversations {
            guard let key = conversation.first.nameKey else { continue }
            store.set(key, conversation.unsentMessages.map(\.text))
        }
        guard store != unsent else { return }
        unsent = store
        store.save(home: home)
    }

    /// Notifications for an agent's asks and finished turns, and the restart
    /// a Claude session waits for until its turn is done. Each can be
    /// answered where it shows: an ask by its buttons — a question's options,
    /// or a field for an answer of one's own — and a finished turn by a
    /// message written in it.
    private func watch(_ agent: Agent, in conversation: Conversation) {
        let id = conversation.id
        func asked(_ body: String, actions: [JSONValue], reply: JSONValue? = nil) {
            notify(id, title: t("Ждёт ответа — ", "Waiting for you — ") + conversation.title, body: body,
                   actions: actions, reply: reply)
        }
        func finished(_ words: String) {
            notify(id, title: t("Готово — ", "Done — ") + conversation.title, body: words, actions: [],
                   reply: ["button": .string(t("Ответить", "Reply")), "placeholder": .string(t("Сообщение", "Message"))])
            if let note = restartAfterTurn.removeValue(forKey: id) { restartClaude(conversation, saying: note) }
            nameAfterTurn(conversation)
        }
        func action(_ id: String, _ text: String) -> JSONValue { ["id": .string(id), "text": .string(text)] }
        switch agent {
        case .claude(let session):
            session.onAsk = { [weak self] ask in
                guard let self else { return }
                if let question = ask.ask.questions?.first {
                    asked(question.question,
                          actions: question.options.prefix(2).enumerated().map { index, option in
                              action("opt:\(ask.requestID):\(index)", option.label)
                          },
                          reply: ["button": .string(t("Свой ответ…", "Own answer…")), "placeholder": .string(t("Ответ", "Answer"))])
                    return
                }
                var actions = [action("allow:" + ask.requestID, t("Разрешить", "Allow"))]
                if ask.ask.offersAlways { actions.append(action("always:" + ask.requestID, t("Разрешать в сессии", "Allow in session"))) }
                actions.append(action("deny:" + ask.requestID, t("Отклонить", "Deny")))
                asked(t("Хочет запустить: ", "Wants to run: ") + ask.summary, actions: actions)
            }
            session.onTurnFinished = { words in finished(words) }
            session.onRateLimit = { [weak self, weak session] limit in
                guard let self, let session else { return }
                limits[session.account.name, default: AccountLimits()].note(limit, at: Date())
            }
            session.onUsage = { [weak self] usage, account in
                guard let self else { return }
                limits[account.name, default: AccountLimits()].note(usage, at: Date())
                render()
            }
            session.onLimit = { [weak self, weak session] resets in
                guard let self, let session else { return }
                reachedTheLimit(conversation, session, resets: resets)
            }
        case .codex(let session):
            session.onAsk = { [weak self] ask in
                guard let self else { return }
                asked(t("Хочет запустить: ", "Wants to run: ") + ask.summary, actions: [
                    action("allow:" + ask.requestID, t("Разрешить", "Allow")),
                    action("always:" + ask.requestID, t("Разрешать в сессии", "Allow in session")),
                    action("deny:" + ask.requestID, t("Отклонить", "Deny")),
                ])
            }
            session.onTurnFinished = { [weak self, weak session] words in
                finished(words)
                guard let self, let session else { return }
                Task {
                    let saved = await session.savedThreads()
                    if !saved.isEmpty { self.codexHistory = saved; self.render() }
                }
            }
        }
    }

    /// The conversation goes on with `provider`, its own session started (or
    /// continued) in the same folder, with `model`.
    private func switchProvider(_ conversation: Conversation, to provider: Provider, model: String) async {
        let name = (knownModels[provider] ?? []).first { $0.value == model }?.name ?? model
        switch provider {
        case .claude:
            if let session = conversation.claude {
                session.chosenModel = model
                conversation.switchTo(.claude, agent: nil, model: name)
                if session.isEnded || session.state == .starting, let id = session.sessionID {
                    await startClaude(session, resume: id)
                } else {
                    session.switchModel(to: model)
                }
            } else {
                let session = ChatSession(folder: conversation.folder, account: account)
                session.chosenModel = model
                let agent = Agent.claude(session)
                watch(agent, in: conversation)
                conversation.switchTo(.claude, agent: agent, model: name)
                await startClaude(session, resume: nil)
            }
        case .codex:
            if let session = conversation.codex {
                session.chosenModel = model
                conversation.switchTo(.codex, agent: nil, model: name)
                if session.isEnded, session.threadID != nil { await startCodex(session) }
            } else {
                let session = CodexSession(folder: conversation.folder)
                session.chosenModel = model
                let agent = Agent.codex(session)
                watch(agent, in: conversation)
                conversation.switchTo(.codex, agent: agent, model: name)
                await startCodex(session)
            }
        }
        render()
    }

    /// Conversations whose «waiting for you» notification may still show.
    private var notifiedWaiting: Set<UUID> = []

    private func notify(_ id: UUID, title: String, body: String, actions: [JSONValue] = [], reply: JSONValue? = nil) {
        var notice: [String: JSONValue] = ["id": .string(id.uuidString), "title": .string(title),
                                           "body": .string(String(body.prefix(240)))]
        if !actions.isEmpty { notice["actions"] = .array(actions) }
        if let reply { notice["reply"] = reply }
        if actions.isEmpty { notifiedWaiting.remove(id) } else { notifiedWaiting.insert(id) }
        send(["notify": .object(notice)])
    }

    /// The notification of `id` is not wanted any more.
    private func unnotify(_ id: UUID) {
        notifiedWaiting.remove(id)
        send(["unnotify": ["id": .string(id.uuidString)]])
    }

    /// A conversation answered on the card, or in its notification, waits
    /// for nothing now: its «waiting for you» leaves Notification Centre, and
    /// its buttons with it.
    private func withdrawAnswered() {
        for id in notifiedWaiting {
            guard let conversation = conversations.first(where: { $0.id == id }) else {
                unnotify(id)
                continue
            }
            if conversation.current.waiting == 0 { unnotify(id) }
        }
    }

    func environment() async -> [String: String] {
        if let shellEnvironment { return shellEnvironment }
        let shell = getpwuid(getuid()).flatMap { $0.pointee.pw_shell.map { String(cString: $0) } } ?? "/bin/zsh"
        let captured = (try? await ShellEnvironment.capture(shell: shell, home: home.path, user: NSUserName()))
            ?? ProcessInfo.processInfo.environment
        shellEnvironment = captured
        return captured
    }

    /// The program to run for `name`: the path in the plugin's settings (the
    /// lab points it at a stand-in; a `.py` runs with python3), or the one
    /// the shell finds.
    func program(_ name: String, setting: String, path: String) -> (URL, [String])? {
        if let override = Self.setting(ProcessInfo.processInfo.environment[setting]), !override.isEmpty {
            let url = URL(fileURLWithPath: override)
            return url.pathExtension == "py" ? (URL(fileURLWithPath: "/usr/bin/python3"), [override]) : (url, [])
        }
        return ShellEnvironment.resolve(name, path: path).map { ($0, []) }
    }

    func startClaude(_ session: ChatSession, resume: String?) async {
        let environment = session.account.environment(from: await environment())
        guard let (executable, prefix) = program("claude", setting: "UDECK_SETTING_CLAUDE", path: environment["PATH"] ?? "") else {
            session.fail(t("claude не найден в PATH вашей оболочки", "claude was not found in your shell's PATH"))
            return
        }
        // No permission mode of the plugin's own: the person's settings decide
        // (theirs is `auto`), as in the terminal — a forced `default` asked
        // about every operation.
        var arguments = prefix + ClaudeOutbound.arguments(model: session.chosenModel, resume: resume)
        if let effort = session.effort { arguments += ["--effort", effort] }
        do {
            let process = try AgentProcess(executable: executable, arguments: arguments, environment: environment,
                                           directory: session.folder)
            await session.start(channel: process)
            if !session.models.isEmpty { knownModels[.claude] = session.models.filter { $0.value != "default" } }
        } catch {
            session.fail("\(error)")
        }
    }

    private func startCodex(_ session: CodexSession) async {
        let environment = await environment()
        guard let (executable, prefix) = program("codex", setting: "UDECK_SETTING_CODEX", path: environment["PATH"] ?? "") else {
            session.fail(t("codex не найден в PATH вашей оболочки", "codex was not found in your shell's PATH"))
            return
        }
        await session.start(executable: executable, arguments: prefix + ["app-server"], environment: environment)
        if !session.models.isEmpty { knownModels[.codex] = session.models }
    }

    /// The models Codex offers, for the menu of a conversation that has not
    /// used it yet, and the threads it saved: one short run of
    /// `codex app-server`, no thread of its own.
    private func learnCodex() async {
        let environment = await environment()
        guard let (executable, prefix) = program("codex", setting: "UDECK_SETTING_CODEX", path: environment["PATH"] ?? ""),
              let connection = try? CodexConnection(executable: executable, arguments: prefix + ["app-server"],
                                                    environment: environment, directory: home)
        else { return }
        await connection.start()
        defer { Task { _ = await connection.close(grace: .seconds(2)) } }
        guard (try? await connection.handshake(client: "udeck-agents", version: "0.1.0")) != nil,
              let list = try? await connection.request("model/list", [:], timeout: .seconds(20)) else { return }
        let models = CodexSession.models(list)
        if !models.isEmpty, knownModels[.codex] == nil { knownModels[.codex] = models }
        if let threads = try? await connection.request("thread/list", ["limit": 10], timeout: .seconds(20)) {
            codexHistory = CodexSaved.list(threads)
        }
        render()
    }

    /// The Claude session starts again — a new effort or login — continuing
    /// where it was; after the running turn, if one runs.
    func restartClaude(_ conversation: Conversation, saying note: String, then: (() -> Void)? = nil) {
        guard let session = conversation.claude, heldBack[conversation.id] == nil, session.sessionID != nil,
              !session.isEnded else { return }
        if session.state == .working {
            restartAfterTurn[conversation.id] = note
            return
        }
        session.beginRestart(note)
        Task {
            await session.close()
            await startClaude(session, resume: session.sessionID)
            then?()
            render()
        }
    }

    func refreshHistory() {
        // Sessions scripts ran are left out: more are looked at, to list twelve.
        history = SessionHistory.recent(config: ChatAccount(name: "main", configDir: nil).folder(home: home), limit: 12,
                                        keep: listsInHistory, looked: 60, glances: &historyGlances)
        nameHistory()
        historyRead = Date()
    }

    // MARK: - The card

    /// Writes each place's card if it changed since the last one written:
    /// the place's name, and what it shows (`keep`, `name`) for uDeck to keep
    /// with it and to carry to a place of its own.
    public func render() {
        if Date().timeIntervalSince(historyRead) > 30 { refreshHistory() }
        keepUnsent()
        updateKeepAwake()
        let current = here
        defer { here = current }
        for name in places.keys.sorted() {
            here = name
            var message: [String: JSONValue] = ["card": AgentsCard.card(for: self)]
            if !name.isEmpty { message["view"] = .string(name) }
            if let conversation = selected {
                message["keep"] = .string(Kept.of(conversation))
                message["name"] = .string(String(conversation.title.prefix(120)))
            }
            guard let line = try? JSONValue.object(message).encodedLine(), line != lastCards[name] else { continue }
            lastCards[name] = line
            emit(line)
        }
    }

    private func send(_ value: JSONValue) {
        if let line = try? value.encodedLine() { emit(line) }
    }

    func t(_ russian: String, _ english: String) -> String { self.russian ? russian : english }

    /// A string setting as uDeck passes it: JSON, so an empty one arrives as
    /// `""`, not as nothing. Bare text (an older uDeck, a hand-run) is taken
    /// as it is.
    nonisolated static func setting(_ raw: String?) -> String? {
        guard let raw else { return nil }
        if let decoded = try? JSONDecoder().decode(String.self, from: Data(raw.utf8)) { return decoded }
        return raw
    }
}
