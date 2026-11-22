import Foundation
import UDeckAgents

/// The Agents plugin: its sessions, and the card it shows uDeck for them.
///
/// uDeck draws the card; this decides what is on it, by the card's size —
/// small: the sessions as a list; larger: the sessions as chips, the chosen
/// one's conversation, its open questions as buttons, and a field to answer —
/// and turns what the person does on the card (events) into what the sessions
/// do.
@MainActor
public final class AgentsApp {
    public private(set) var sessions: [ChatSession] = []
    public var selection: UUID?
    public private(set) var size = (columns: 6, rows: 4)
    public private(set) var russian = false
    public private(set) var showingHistory = false
    public private(set) var history: [SavedSession] = []
    public let accounts: [ChatAccount]
    public private(set) var account: ChatAccount

    /// Where lines for uDeck go (stdout).
    let emit: (String) -> Void
    let home: URL
    private var shellEnvironment: [String: String]?
    private var lastCard = ""

    public init(home: URL, emit: @escaping (String) -> Void) {
        self.home = home
        self.emit = emit
        accounts = ChatAccount.discover(home: home)
        account = accounts[0]
    }

    // MARK: - Events from uDeck

    public func handle(_ line: String) async {
        guard let event = JSONValue.line(Substring(line)), let kind = event["event"]?.string else { return }
        switch kind {
        case "hello", "size":
            if let columns = event["size"]?["columns"]?.int, let rows = event["size"]?["rows"]?.int {
                size = (columns, rows)
            }
            if let language = event["language"]?.string { russian = language.hasPrefix("ru") }
            if kind == "hello" { refreshHistory() }
        case "select":
            select(event["id"]?.string ?? "")
        case "press":
            press(event["id"]?.string ?? "")
        case "submit":
            if let text = event["text"]?.string { selected?.send(text) }
        case "folder":
            if event["id"]?.string == "new", let path = event["path"]?.string {
                await newSession(in: URL(fileURLWithPath: path, isDirectory: true))
            }
        case "notification":
            if let id = event["id"]?.string, let uuid = UUID(uuidString: id) {
                selection = uuid
                showingHistory = false
            }
        default:
            return
        }
        render()
    }

    var selected: ChatSession? { sessions.first { $0.id == selection } }

    private func select(_ id: String) {
        if id == "new" {
            send(["pick": ["id": "new", "prompt": .string(t("Папка для новой сессии", "Choose the folder to work in"))]])
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

    private func press(_ id: String) {
        if id == "stop" { selected?.interrupt(); return }
        let parts = id.split(separator: ":", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else { return }
        let request = parts[1]
        guard let session = sessions.first(where: { $0.asks.contains { $0.requestID == request } }),
              let ask = session.asks.first(where: { $0.requestID == request })
        else { return }
        switch parts[0] {
        case "allow": session.answer(ask, with: .allow)
        case "always": session.answer(ask, with: .allowAlways)
        case "deny": session.answer(ask, with: .deny)
        case "opt":
            guard parts.count == 3, let index = Int(parts[2]), let question = ask.ask.questions?.first,
                  question.options.indices.contains(index)
            else { return }
            session.answer(ask, with: .choices([question.question: [question.options[index].label]]))
        default: return
        }
    }

    // MARK: - Sessions

    public func newSession(in folder: URL, message: String? = nil) async {
        let session = ChatSession(folder: folder, account: account)
        adopt(session)
        await start(session, resume: nil)
        if let message, !message.isEmpty { session.send(message) }
    }

    private func open(_ saved: SavedSession) {
        if let open = sessions.first(where: { $0.sessionID == saved.sessionID && !$0.isEnded }) {
            selection = open.id
            showingHistory = false
            return
        }
        let folder = URL(fileURLWithPath: saved.cwd ?? home.path, isDirectory: true)
        let feed = (try? ClaudeTranscript(url: saved.file)).map { SessionHistory.feed(of: $0) } ?? []
        let session = ChatSession(folder: folder, account: account, title: saved.title, resumeID: saved.sessionID,
                                  history: feed)
        adopt(session)
        showingHistory = false
        Task { await start(session, resume: saved.sessionID) }
    }

    private func adopt(_ session: ChatSession) {
        session.onAsk = { [weak self, weak session] ask in
            guard let self, let session else { return }
            notify(session, title: t("Ждёт ответа — ", "Waiting for you — ") + session.title, body: ask.summary)
        }
        session.onTurnFinished = { [weak self, weak session] words in
            guard let self, let session else { return }
            notify(session, title: t("Готово — ", "Done — ") + session.title, body: words)
        }
        sessions.append(session)
        selection = session.id
    }

    private func notify(_ session: ChatSession, title: String, body: String) {
        send(["notify": ["id": .string(session.id.uuidString), "title": .string(title), "body": .string(String(body.prefix(240)))]])
    }

    func environment() async -> [String: String] {
        if let shellEnvironment { return shellEnvironment }
        let shell = getpwuid(getuid()).flatMap { $0.pointee.pw_shell.map { String(cString: $0) } } ?? "/bin/zsh"
        let captured = (try? await ShellEnvironment.capture(shell: shell, home: home.path, user: NSUserName()))
            ?? ProcessInfo.processInfo.environment
        shellEnvironment = captured
        return captured
    }

    private func start(_ session: ChatSession, resume: String?) async {
        let environment = session.account.environment(from: await environment())
        var arguments = ClaudeOutbound.arguments(resume: resume, permissionMode: "default")
        var executable: URL
        // A path in the plugin's settings (the lab points it at a stand-in).
        if let override = ProcessInfo.processInfo.environment["UDECK_SETTING_CLAUDE"], !override.isEmpty {
            executable = URL(fileURLWithPath: override)
            if executable.pathExtension == "py" {
                arguments.insert(override, at: 0)
                executable = URL(fileURLWithPath: "/usr/bin/python3")
            }
        } else if let found = ShellEnvironment.resolve("claude", path: environment["PATH"] ?? "") {
            executable = found
        } else {
            session.fail(t("claude не найден в PATH вашей оболочки", "claude was not found in your shell's PATH"))
            return
        }
        do {
            let process = try AgentProcess(executable: executable, arguments: arguments, environment: environment,
                                           directory: session.folder)
            await session.start(channel: process)
        } catch {
            session.fail("\(error)")
        }
    }

    private func refreshHistory() {
        history = SessionHistory.recent(config: ChatAccount(name: "main", configDir: nil).folder(home: home), limit: 12)
    }

    // MARK: - The card

    /// Writes the card if it changed since the last one written.
    public func render() {
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
}
