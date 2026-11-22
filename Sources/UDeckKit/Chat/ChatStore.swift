import Foundation
import Observation
import UDeckAgentHost
import UDeckAgents
import UDeckChat

/// The chat window's state: the sessions open in it, the saved ones it can
/// resume, the accounts it can start under.
///
/// Where sessions run is `agents`: the helper (`udeck-agentd`), which keeps
/// them running while uDeck is away and gives them back when it returns
/// (`restore`), or uDeck's own process, where they end with it as a
/// terminal's do and are resumed from History.
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
    /// Where agents run; the app sets the helper's once it is registered.
    @ObservationIgnored public var agents: any ChatAgents = LocalAgents()
    /// While the app is settling where agents run (registering the helper),
    /// new sessions wait for it, so none starts in the wrong place.
    @ObservationIgnored public var preparing: Task<Void, Never>?
    @ObservationIgnored private var index: ChatIndex
    @ObservationIgnored private var restored = false

    public init(home: URL = ChatLauncher.realHome) {
        self.home = home
        let accounts = ChatAccount.discover(home: home)
        self.accounts = accounts
        account = accounts[0]
        launcher = ChatLauncher(home: home)
        index = ChatIndex.load(home: home)
    }

    /// Takes back the sessions the helper kept running while uDeck was away:
    /// each drawn again from its transcript up to its run's start and the
    /// helper's journal from there — the feed, the turn under way, the asks
    /// still open. Index entries whose agent is gone are dropped: those are
    /// resumed from History like any saved session. Once per launch.
    public func restore() async {
        guard !restored else { return }
        restored = true
        let survivors = await agents.survivors()
        var kept = ChatIndex()
        for entry in index.entries {
            guard let survivor = survivors.first(where: { $0.session == entry.id }),
                  let id = UUID(uuidString: entry.id),
                  !sessions.contains(where: { $0.id == id })
            else { continue }
            kept.upsert(entry)
            let account = accounts.first { $0.name == entry.account } ?? accounts[0]
            var history: [FeedItem] = []
            if let claude = entry.claudeSessionID,
               let file = SessionHistory.transcript(ofSession: claude, config: account.folder(home: home))
            {
                let started = survivor.startedAt
                history = await Task.detached { () -> [FeedItem] in
                    guard let transcript = try? ClaudeTranscript(url: file) else { return [] }
                    return SessionHistory.feed(of: transcript, before: started)
                }.value
            }
            let session = ChatSession(id: id, folder: URL(fileURLWithPath: entry.folder, isDirectory: true),
                                      account: account, title: entry.title, resumeID: entry.claudeSessionID,
                                      history: history)
            watch(session)
            sessions.append(session)
            if selection == nil { selection = session.id }
            do {
                await session.start(channel: try await agents.attach(entry.id), reattached: true)
            } catch {
                session.fail("could not reach the session in udeck-agentd: \(error)")
            }
        }
        index = kept
        index.save(home: home)
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
            await preparing?.value
            await launcher.start(session, resume: nil, agents: agents)
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
            await preparing?.value
            await launcher.start(session, resume: saved.sessionID, agents: agents)
        }
    }

    public func select(sessionWithID id: String) {
        if let session = sessions.first(where: { $0.id.uuidString == id }) { selection = session.id }
    }

    private func watch(_ session: ChatSession) {
        remember(session)
        session.onRecord = { [weak self, weak session] in
            guard let self, let session else { return }
            remember(session)
        }
        session.onAsk = { [weak self, weak session] ask in
            guard let self, let session else { return }
            onAttention?(session, .ask(ask))
        }
        session.onTurnFinished = { [weak self, weak session] words in
            guard let self, let session else { return }
            onAttention?(session, .finished(words))
        }
    }

    /// What it takes to find the session again after a restart.
    private func remember(_ session: ChatSession) {
        guard agents.keepsAgentsAlive || index.entries.contains(where: { $0.id == session.id.uuidString }) else { return }
        index.upsert(ChatIndex.Entry(id: session.id.uuidString, folder: session.folder.path,
                                     account: session.account.name, title: session.title,
                                     claudeSessionID: session.sessionID))
        index.save(home: home)
    }

    public func close(_ session: ChatSession) {
        index.remove(session.id.uuidString)
        index.save(home: home)
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

    public func start(_ session: ChatSession, resume: String?, agents: any ChatAgents) async {
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
        // At logout or when the helper stops, the agent gets the interrupt
        // first, so a turn ends cleanly and its transcript is whole.
        let stopLine = try? ClaudeOutbound.interrupt(id: "udeck-stop").encodedLine()
        let spec = SpawnSpec(session: session.id.uuidString, executable: executable.path, arguments: arguments,
                             environment: environment, directory: session.folder.path, stopLine: stopLine)
        do {
            let channel = try await agents.spawn(spec)
            await session.start(channel: channel)
        } catch {
            session.fail("could not start claude: \(error)")
        }
    }
}
