import Foundation
import Observation
import UDeckAgents
import UDeckChat

/// The chat window's state: the sessions open in it, the saved ones it can
/// resume, the accounts it can start under.
///
/// Sessions run here, in uDeck's process, for now: closing uDeck ends them the
/// way closing a terminal does, and each is resumed by its id from History. The
/// helper (`udeck-agentd`), which keeps them running, comes next.
@MainActor
@Observable
public final class ChatStore {
    public private(set) var sessions: [ChatSession] = []
    public var selection: ChatSession.ID?
    public private(set) var history: [SavedSession] = []
    public private(set) var loadingHistory = false
    public let accounts: [ChatAccount]
    /// The account new sessions start under.
    public var account: ChatAccount

    /// A session wants the user (an ask) or has finished a turn: the app
    /// decides whether anyone is looking and notifies if not.
    @ObservationIgnored public var onAttention: ((ChatSession, ChatAttention) -> Void)?

    @ObservationIgnored let launcher: ChatLauncher
    @ObservationIgnored private let home: URL

    public init(home: URL = ChatLauncher.realHome) {
        self.home = home
        let accounts = ChatAccount.discover(home: home)
        self.accounts = accounts
        account = accounts[0]
        launcher = ChatLauncher(home: home)
    }

    public var selected: ChatSession? { sessions.first { $0.id == selection } }

    /// A new session in `folder` under the chosen account, and the first
    /// message if there is one.
    @discardableResult
    public func newSession(in folder: URL, message: String? = nil) -> ChatSession {
        let session = ChatSession(folder: folder, account: account)
        watch(session)
        sessions.append(session)
        selection = session.id
        Task {
            await launcher.start(session, resume: nil)
            if let message, !message.isEmpty { session.send(message) }
        }
        return session
    }

    /// Opens a saved session: its conversation read back, then the CLI resumed
    /// on it. One already open is only brought forward.
    public func open(_ saved: SavedSession) {
        if let open = sessions.first(where: { $0.sessionID == saved.sessionID && !$0.isEnded }) {
            selection = open.id
            return
        }
        let folder = URL(fileURLWithPath: saved.cwd ?? home.path, isDirectory: true)
        let account = self.account
        Task {
            let file = saved.file
            let feed = await Task.detached { () -> [FeedItem] in
                guard let transcript = try? ClaudeTranscript(url: file) else { return [] }
                return SessionHistory.feed(of: transcript)
            }.value
            let session = ChatSession(folder: folder, account: account, title: saved.title, resumeID: saved.sessionID,
                                      history: feed)
            watch(session)
            sessions.append(session)
            selection = session.id
            await launcher.start(session, resume: saved.sessionID)
        }
    }

    public func select(sessionWithID id: String) {
        if let session = sessions.first(where: { $0.id.uuidString == id }) { selection = session.id }
    }

    private func watch(_ session: ChatSession) {
        session.onAsk = { [weak self, weak session] ask in
            guard let self, let session else { return }
            onAttention?(session, .ask(ask))
        }
        session.onTurnFinished = { [weak self, weak session] words in
            guard let self, let session else { return }
            onAttention?(session, .finished(words))
        }
    }

    public func close(_ session: ChatSession) {
        sessions.removeAll { $0.id == session.id }
        if selection == session.id { selection = sessions.last?.id }
        Task { await session.close() }
        refreshHistory()
    }

    /// Sessions are shared between the accounts (mirrors link `projects/`), so
    /// History reads the main account's folder.
    public func refreshHistory() {
        loadingHistory = true
        let config = ChatAccount(name: "main", configDir: nil).folder(home: home)
        Task {
            let saved = await Task.detached { SessionHistory.recent(config: config) }.value
            history = saved
            loadingHistory = false
        }
    }

    /// Ends every session cleanly, for uDeck quitting.
    public func closeAll() async {
        for session in sessions { await session.close() }
    }
}

/// Why a session wants the user.
public enum ChatAttention: Sendable {
    case ask(ChatAsk)
    /// A turn finished; its last words.
    case finished(String)
}

/// Starts the user's own `claude` for a session: found through their login
/// shell's PATH, with that shell's environment (spec §4.3, §10.4).
@MainActor
public final class ChatLauncher {
    private let home: URL
    private var environment: [String: String]?

    /// A lab-only override of the CLI (`defaults write … ChatClaudeExecutable
    /// /path/fake-claude.py`): the lab's machines have no `claude` and no login.
    public static let executableOverrideKey = "ChatClaudeExecutable"

    public static var realHome: URL {
        guard let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir else {
            return FileManager.default.homeDirectoryForCurrentUser
        }
        return URL(fileURLWithPath: String(cString: directory), isDirectory: true)
    }

    public init(home: URL) {
        self.home = home
    }

    func shellEnvironment() async -> [String: String] {
        if let environment { return environment }
        let shell = getpwuid(getuid()).flatMap { $0.pointee.pw_shell.map { String(cString: $0) } } ?? "/bin/zsh"
        let captured = (try? await ShellEnvironment.capture(shell: shell, home: home.path, user: NSUserName()))
            ?? ProcessInfo.processInfo.environment
        environment = captured
        return captured
    }

    public func start(_ session: ChatSession, resume: String?) async {
        let environment = session.account.environment(from: await shellEnvironment())
        var executable: URL
        var arguments = ClaudeOutbound.arguments(resume: resume, permissionMode: "default")
        if let override = UserDefaults.standard.string(forKey: Self.executableOverrideKey), !override.isEmpty {
            executable = URL(fileURLWithPath: override)
            if executable.pathExtension == "py" {
                arguments.insert(override, at: 0)
                executable = URL(fileURLWithPath: "/usr/bin/python3")
            }
        } else if let found = ShellEnvironment.resolve("claude", path: environment["PATH"] ?? "") {
            executable = found
        } else {
            session.fail("claude was not found in your shell's PATH")
            return
        }
        do {
            let process = try AgentProcess(executable: executable, arguments: arguments, environment: environment,
                                           directory: session.folder)
            await session.start(channel: process)
        } catch {
            session.fail("could not start claude: \(error)")
        }
    }
}
