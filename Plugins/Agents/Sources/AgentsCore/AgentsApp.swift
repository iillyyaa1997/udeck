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
    public var selection: UUID?
    public private(set) var size = (columns: 6, rows: 4)
    public private(set) var russian = false
    public private(set) var showingHistory = false
    public private(set) var history: [SavedSession] = []
    /// Conversations opened from history only to be read, because their
    /// transcript was written to a moment ago — by when it was last written.
    public private(set) var heldBack: [UUID: Date] = [:]
    /// How recent a write to a saved session means it is open somewhere else.
    static let liveWindow: TimeInterval = 10 * 60
    public let accounts: [ChatAccount]
    public private(set) var account: ChatAccount
    /// The models each provider offered when a session of it last started,
    /// kept for the model menu of a conversation that has not used it yet.
    public private(set) var knownModels: [Provider: [ModelChoice]] = [:]

    /// Where lines for uDeck go (stdout).
    let emit: (String) -> Void
    let home: URL
    private var shellEnvironment: [String: String]?
    private var lastCard = ""
    /// When the saved sessions were last read: the session menu lists them,
    /// and a menu cannot say it is about to open.
    private var historyRead = Date.distantPast
    /// Conversations whose Claude session starts again once its running turn
    /// has finished — a new effort or login chosen mid-turn — and the note.
    private var restartAfterTurn: [UUID: String] = [:]

    public init(home: URL, emit: @escaping (String) -> Void) {
        self.home = home
        self.emit = emit
        accounts = ChatAccount.discover(home: home)
        account = accounts[0]
        knownModels[.claude] = Self.claudeAliases
    }

    /// What the menu offers for Claude before any session said what it has:
    /// the aliases `claude --model` takes.
    static let claudeAliases = [ModelChoice(value: "opus", name: "Opus"), ModelChoice(value: "sonnet", name: "Sonnet"),
                                ModelChoice(value: "haiku", name: "Haiku")]

    // MARK: - Events from uDeck

    public func handle(_ line: String) async {
        guard let event = JSONValue.line(Substring(line)), let kind = event["event"]?.string else { return }
        switch kind {
        case "hello", "size":
            if let columns = event["size"]?["columns"]?.int, let rows = event["size"]?["rows"]?.int {
                size = (columns, rows)
            }
            if let language = event["language"]?.string { russian = language.hasPrefix("ru") }
            if kind == "hello" {
                refreshHistory()
                if knownModels[.codex] == nil { Task { await learnCodexModels() } }
            }
        case "select":
            select(event["id"]?.string ?? "")
        case "press":
            press(event["id"]?.string ?? "")
        case "submit":
            if let text = event["text"]?.string { selected?.send(text) }
        case "folder":
            let id = event["id"]?.string ?? ""
            if id.hasPrefix("new"), let path = event["path"]?.string {
                let provider = Provider(rawValue: String(id.dropFirst(4))) ?? .claude
                await newConversation(in: URL(fileURLWithPath: path, isDirectory: true), provider: provider)
            }
        case "notification":
            if let id = event["id"]?.string, let uuid = UUID(uuidString: id) {
                selection = uuid
                showingHistory = false
            }
        case "choose":
            choose(menu: event["menu"]?.string ?? "", option: event["option"]?.string ?? "")
        default:
            return
        }
        render()
    }

    var selected: Conversation? { conversations.first { $0.id == selection } }

    private func select(_ id: String) {
        if id == "new" || id.hasPrefix("new:") {
            let provider = id.hasPrefix("new:") ? String(id.dropFirst(4)) : "claude"
            send(["pick": ["id": .string("new:" + provider),
                           "prompt": .string(t("Папка для новой сессии", "Choose the folder to work in"))]])
        } else if id == "history" {
            showingHistory.toggle()
            if showingHistory { refreshHistory() }
        } else if id.hasPrefix("s:"), let uuid = UUID(uuidString: String(id.dropFirst(2))) {
            selection = uuid
            showingHistory = false
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
            guard let chosen = accounts.first(where: { $0.name == option }) else { return }
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
        if id == "stop" { selected?.current.interrupt(); return }
        if id == "new" { select("new"); return }
        if id.hasPrefix("here:") || id.hasPrefix("drop:"), let uuid = UUID(uuidString: String(id.dropFirst(5))),
           heldBack[uuid] != nil, let conversation = conversations.first(where: { $0.id == uuid }) {
            heldBack[uuid] = nil
            if id.hasPrefix("here:"), let session = conversation.claude {
                Task { await startClaude(session, resume: session.sessionID) }
            } else if id.hasPrefix("drop:") {
                conversations.removeAll { $0.id == uuid }
                if selection == uuid { selection = conversations.last?.id }
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
            let session = ChatSession(folder: folder, account: account)
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

    private func open(_ saved: SavedSession) {
        if let open = conversations.first(where: { $0.claude?.sessionID == saved.sessionID && !($0.claude?.isEnded ?? true) }) {
            selection = open.id
            showingHistory = false
            return
        }
        let folder = URL(fileURLWithPath: saved.cwd ?? home.path, isDirectory: true)
        let feed = (try? ClaudeTranscript(url: saved.file)).map { SessionHistory.feed(of: $0) } ?? []
        let session = ChatSession(folder: folder, account: account, title: saved.title, resumeID: saved.sessionID,
                                  history: feed)
        let conversation = adopt(.claude(session))
        showingHistory = false
        let written = (try? saved.file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            ?? saved.modified
        if Date().timeIntervalSince(written) < Self.liveWindow {
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
        return conversation
    }

    /// Notifications for an agent's asks and finished turns, and the restart
    /// a Claude session waits for until its turn is done.
    private func watch(_ agent: Agent, in conversation: Conversation) {
        let id = conversation.id
        func asked(_ summary: String) {
            notify(id, title: t("Ждёт ответа — ", "Waiting for you — ") + conversation.title, body: summary)
        }
        func finished(_ words: String) {
            notify(id, title: t("Готово — ", "Done — ") + conversation.title, body: words)
            if let note = restartAfterTurn.removeValue(forKey: id) { restartClaude(conversation, saying: note) }
        }
        switch agent {
        case .claude(let session):
            session.onAsk = { ask in asked(ask.summary) }
            session.onTurnFinished = { words in finished(words) }
        case .codex(let session):
            session.onAsk = { ask in asked(ask.summary) }
            session.onTurnFinished = { words in finished(words) }
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

    private func notify(_ id: UUID, title: String, body: String) {
        send(["notify": ["id": .string(id.uuidString), "title": .string(title), "body": .string(String(body.prefix(240)))]])
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
    private func program(_ name: String, setting: String, path: String) -> (URL, [String])? {
        if let override = Self.setting(ProcessInfo.processInfo.environment[setting]), !override.isEmpty {
            let url = URL(fileURLWithPath: override)
            return url.pathExtension == "py" ? (URL(fileURLWithPath: "/usr/bin/python3"), [override]) : (url, [])
        }
        return ShellEnvironment.resolve(name, path: path).map { ($0, []) }
    }

    private func startClaude(_ session: ChatSession, resume: String?) async {
        let environment = session.account.environment(from: await environment())
        guard let (executable, prefix) = program("claude", setting: "UDECK_SETTING_CLAUDE", path: environment["PATH"] ?? "") else {
            session.fail(t("claude не найден в PATH вашей оболочки", "claude was not found in your shell's PATH"))
            return
        }
        var arguments = prefix + ClaudeOutbound.arguments(model: session.chosenModel, resume: resume, permissionMode: "default")
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
    /// used it yet: one short run of `codex app-server`, no thread.
    private func learnCodexModels() async {
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
        if !models.isEmpty, knownModels[.codex] == nil {
            knownModels[.codex] = models
            render()
        }
    }

    /// The Claude session starts again — a new effort or login — continuing
    /// where it was; after the running turn, if one runs.
    private func restartClaude(_ conversation: Conversation, saying note: String) {
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
            render()
        }
    }

    private func refreshHistory() {
        history = SessionHistory.recent(config: ChatAccount(name: "main", configDir: nil).folder(home: home), limit: 12)
        historyRead = Date()
    }

    // MARK: - The card

    /// Writes the card if it changed since the last one written.
    public func render() {
        if Date().timeIntervalSince(historyRead) > 30 { refreshHistory() }
        guard let line = try? JSONValue.object(["card": AgentsCard.card(for: self)]).encodedLine(),
              line != lastCard
        else { return }
        lastCard = line
        emit(line)
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
