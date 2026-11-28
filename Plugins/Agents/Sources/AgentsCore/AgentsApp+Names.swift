import Foundation
import UDeckAgents

/// Names of sessions (11-25). A session is called, in order: what the person
/// named it here (`/rename Name` in the field), its own name — Claude Code's
/// `custom-title`, Codex's thread name — a name a model made up after its
/// first answer, and until then the first words said in it.
///
/// The model is the session's own agent, so it is there for whoever has the
/// session: a Claude session is named by Haiku under the session's account,
/// a Codex one by its model at the lowest effort. A short run of its own, no
/// tools, no transcript, none of the person's hooks; a bit of the
/// subscription's limit, no money. Once a session, after a finished turn;
/// setting `name_chats` switches it off.
extension AgentsApp {
    /// Whether a model makes up names (setting `name_chats`, on until
    /// switched off).
    var nameChatsEnabled: Bool {
        settings.bool("name_chats", true)
    }

    /// What the model is told; the folder and the conversation's start are
    /// the message. Tried on the operator's own sessions (11-25): «2 to 6
    /// words, what it is about» gave «Продолжение handoff 009»; the rules and
    /// the bad → good pairs below, with one more try for a name that still
    /// starts with continuing (`namingAgain`), gave eight of eight that say
    /// what the work is.
    static let namingInstructions = """
        You name conversations for a list of chats, the way an email has a subject. The message gives the folder \
        the conversation runs in and its start: what the person said and the agent's first answer.
        Write the name that tells the person, weeks later, which conversation this was:
        - at most 5 words, in the language the person writes in; one subject, no second clause after a colon;
        - the subject itself: what is being made, fixed or decided, and in what — a project, a device, a service. \
        Good: «Уведомления Plane в Telegram», «Кнопка обновления не работает», «Шафл-коробка для принтера», \
        «Flaky login test»;
        - never start with continuing or helping — not «Продолжение», «Продолжаем», «Помощь», «Работа над», \
        «Continue», «Help with». When the person continues earlier work, name that work, taking it from the \
        agent's answer if the person only points at a handoff;
        - leave out the agent's or a skill's name, ticket numbers, file paths and the words handoff, prompt, session.
        Bad → good: «Продолжение работы над ботом: команды» → «Команды бота»; «Помощь с настройкой роутера» → \
        «Настройка роутера»; «Continue the release notes: v2» → «Release notes v2».
        Reply with the name only: no quotes, no full stop, nothing else.
        """

    /// What the model is told once more, about a name that will not do.
    nonisolated static func namingAgain(_ name: String) -> String {
        "«\(name)» does not do: a name says what the work is about, in at most 5 words, with no colon, and never "
            + "starts with continuing or helping. Give the name again, the name only."
    }

    // MARK: - Known names

    /// The session's name as kept here, and that it is this plugin's; a name
    /// the person gave before the session had an id is kept now.
    func applyKnownName(_ conversation: Conversation) {
        let agent = conversation.first
        guard let key = agent.nameKey else { return }
        var changed = names.mark(key)
        if agent.titleSource == .person, names.entries[key]?.byPerson != true {
            names.name(key, agent.title, byPerson: true)
            changed = true
        } else if let (name, source) = names.entries[key]?.named {
            agent.name(name, from: source)
        }
        if changed { names.save(home: home) }
    }

    /// A saved Claude session's name, with the names kept here.
    func name(of saved: SavedSession) -> String {
        let (name, source) = saved.named
        if let (kept, keptSource) = names.entries[ChatNames.key(.claude, saved.sessionID)]?.named, keptSource >= source {
            return kept
        }
        return name
    }

    /// A saved Codex thread's name, with the names kept here.
    func name(of saved: CodexSaved) -> String {
        if let (kept, keptSource) = names.entries[ChatNames.key(.codex, saved.id)]?.named, keptSource >= saved.source {
            return kept
        }
        return saved.title
    }

    /// Whether the history lists a saved session: one a person started, in
    /// a terminal or here — not one a program ran.
    func listsInHistory(_ saved: SavedSession) -> Bool {
        !saved.byAProgram || names.entries[ChatNames.key(.claude, saved.sessionID)] != nil
    }

    // MARK: - After a turn

    /// A turn finished: the session's own name read again — a hook or the
    /// terminal may have given it one — and, with none, one made up.
    func nameAfterTurn(_ conversation: Conversation) {
        applyKnownName(conversation)
        let agent = conversation.first
        guard let key = agent.nameKey else { return }
        guard case .claude(let session) = agent, let id = session.sessionID else {
            makeUpName(conversation, key: key)
            return
        }
        let config = session.account.folder(home: home)
        Task {
            let own = await Task.detached(priority: .utility) {
                SessionHistory.transcript(ofSession: id, config: config).flatMap { SessionHistory.glance($0).customTitle }
            }.value
            if let own, session.name(own, from: .own) { render() }
            makeUpName(conversation, key: key)
        }
    }

    /// Tries at making a name up a session gets in a run: one that fails —
    /// the account out of its limit, no answer in time — is tried again after
    /// the next turn.
    static let namingTries = 3

    /// A name made up by the session's own agent, for one with nothing better
    /// than its first words: once it answers, or `namingTries` times.
    func makeUpName(_ conversation: Conversation, key: String) {
        let agent = conversation.first
        guard nameChatsEnabled, agent.titleSource < .model, namingTries[key, default: 0] < Self.namingTries,
              let start = Self.excerpt(agent.items) else { return }
        let excerpt = "Folder: " + conversation.folder.lastPathComponent + "\n\n" + start
        namingTries[key, default: 0] += 1
        Task {
            let answer: String? = switch agent {
            case .claude(let session): await nameByClaude(excerpt, account: session.account)
            case .codex(let session): await nameByCodex(excerpt, like: session)
            }
            guard let answer else { return }
            namingTries[key] = Self.namingTries
            guard let name = ChatNames.cleaned(answer) else { return }
            names.name(key, name, byPerson: false)
            names.save(home: home)
            guard agent.name(name, from: .model) else { return }
            if case .codex(let session) = agent { await session.setName(name) }
            render()
        }
    }

    /// What the model names a session by: the first things the person said
    /// that say anything — a pasted prompt included, which is often the whole
    /// of the task — and the first answer, a few hundred characters of each. Nil while the person has said nothing of the kind.
    nonisolated static func excerpt(_ items: [FeedItem]) -> String? {
        var said: [String] = []
        var answer: String?
        for item in items {
            switch item {
            case .user(_, let text) where said.count < 3:
                if let words = ChatNames.substance(text) { said.append(String(words.prefix(600))) }
            case .assistant(_, let text, _) where answer == nil && !said.isEmpty && !text.isEmpty:
                answer = String(text.prefix(600))
            default:
                continue
            }
            if said.count == 3, answer != nil { break }
        }
        guard !said.isEmpty else { return nil }
        return (said.map { "Person: " + $0 } + (answer.map { ["Agent: " + $0] } ?? [])).joined(separator: "\n\n")
    }

    // MARK: - The history's names

    /// The history's sessions with no name a model made or the person gave,
    /// named one at a time — once a run each — on an account with room in
    /// its limits: a status line's `custom-title` is no name (the operator,
    /// 11-25: «1»). About two thousand tokens a session, once.
    func nameHistory() {
        guard nameChatsEnabled, historyNaming == nil else { return }
        let waiting = history.filter { saved in
            let key = ChatNames.key(.claude, saved.sessionID)
            return names.entries[key]?.name == nil && namingTries[key, default: 0] == 0
        }
        guard !waiting.isEmpty else { return }
        historyNaming = Task { [weak self] in
            for saved in waiting {
                guard let self else { return }
                await self.nameSaved(saved)
            }
            self?.historyNaming = nil
        }
    }

    /// A saved session named by its opening, once.
    func nameSaved(_ saved: SavedSession) async {
        let key = ChatNames.key(.claude, saved.sessionID)
        guard names.entries[key]?.name == nil, namingTries[key, default: 0] == 0 else { return }
        namingTries[key] = Self.namingTries
        let file = saved.file
        let items = await Task.detached(priority: .utility) { SessionHistory.opening(of: file) }.value
        guard let start = Self.excerpt(items) else { return }
        let excerpt = "Folder: " + (saved.folderName ?? "") + "\n\n" + start
        guard let answer = await nameByClaude(excerpt, account: autoPick()?.account ?? account),
              let name = ChatNames.cleaned(answer) else { return }
        names.name(key, name, byPerson: false)
        names.save(home: home)
        conversations.first { $0.claude?.sessionID == saved.sessionID }?.first.name(name, from: .model)
        render()
    }

    // MARK: - The person's own name

    /// `/rename Name` typed in the field: the session is called that, over
    /// any other name; in Codex too. True when the text was that.
    func renameFromTheField(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased() == "/rename" || trimmed.lowercased().hasPrefix("/rename ") else { return false }
        guard let conversation = selected else { return true }
        guard let name = ChatNames.own(String(trimmed.dropFirst("/rename".count))) else {
            conversation.current.note("rename-how")
            return true
        }
        let agent = conversation.first
        agent.name(name, from: .person)
        if let key = agent.nameKey {
            names.name(key, name, byPerson: true)
            names.save(home: home)
        }
        conversation.current.note("renamed:" + name)
        if case .codex(let session) = agent { Task { await session.setName(name) } }
        return true
    }

    // MARK: - The runs that make a name up

    /// A folder of its own for the runs: no project of the person's, so no
    /// project settings and no CLAUDE.md of one.
    private func namingFolder() -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("agents-name", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Haiku's name for `excerpt`, under `account`: `claude` without the
    /// person's settings (their hooks would run for it), tools, MCP servers
    /// or a transcript.
    func nameByClaude(_ excerpt: String, account: ChatAccount) async -> String? {
        let environment = account.environment(from: await environment())
        guard let (executable, prefix) = program("claude", setting: "UDECK_SETTING_CLAUDE", path: environment["PATH"] ?? "")
        else { return nil }
        let arguments = prefix + ClaudeOutbound.arguments(model: "haiku")
            + ["--setting-sources", "project", "--no-session-persistence", "--tools", "", "--strict-mcp-config",
               "--system-prompt", Self.namingInstructions]
        guard let process = try? AgentProcess(executable: executable, arguments: arguments, environment: environment,
                                              directory: namingFolder()) else { return nil }
        let connection = ClaudeCodeConnection(channel: process)
        await connection.start()
        defer { Task { _ = await connection.close(grace: .seconds(2)) } }
        guard (try? await connection.request({ ClaudeOutbound.initialize(id: $0) }, timeout: .seconds(30))) != nil,
              (try? await connection.send(ClaudeOutbound.userMessage(excerpt))) != nil else { return nil }
        let events = connection.events
        return await Self.within(.seconds(90)) {
            var triedAgain = false
            for await event in events {
                switch event {
                case .turnFinished(let result, _):
                    guard !result.isError else { return nil }
                    if !triedAgain, ChatNames.willNotDo(result.result) {
                        triedAgain = true
                        try? await connection.send(ClaudeOutbound.userMessage(Self.namingAgain(result.result)))
                        continue
                    }
                    return result.result
                case .rateLimit(let limit, _) where limit.status == "rejected":
                    // Out of its limit: the CLI would wait hours to try again.
                    return nil
                case .system("api_retry", _):
                    return nil
                case .request(let request):
                    // Nothing to run for a name.
                    try? await connection.send(ClaudeOutbound.deny(request.requestID, message: "Only a name is wanted."))
                default:
                    continue
                }
            }
            return nil
        }
    }

    /// Codex's name for `excerpt`, by the model `session` runs with at its
    /// lowest effort: a thread of its own that is not saved.
    func nameByCodex(_ excerpt: String, like session: CodexSession) async -> String? {
        let environment = await environment()
        guard let (executable, prefix) = program("codex", setting: "UDECK_SETTING_CODEX", path: environment["PATH"] ?? ""),
              let connection = try? CodexConnection(executable: executable, arguments: prefix + ["app-server"],
                                                    environment: environment, directory: namingFolder())
        else { return nil }
        await connection.start()
        defer { Task { _ = await connection.close(grace: .seconds(2)) } }
        let events = connection.events
        let model = session.chosenModel ?? session.model
        var thread: [String: JSONValue] = ["cwd": .string(namingFolder().path), "ephemeral": true,
                                           "developerInstructions": .string(Self.namingInstructions)]
        if let model { thread["model"] = .string(model) }
        guard (try? await connection.handshake(client: "udeck-agents", version: "0.1.0")) != nil,
              let started = try? await connection.request("thread/start", .object(thread), timeout: .seconds(30)),
              let threadID = started["thread"]?["id"]?.string else { return nil }
        var turn: [String: JSONValue] = ["threadId": .string(threadID),
                                         "input": [["type": "text", "text": .string(excerpt)]]]
        if let effort = Self.lowestEffort(of: session.models.first { $0.value == model }?.efforts ?? []) {
            turn["effort"] = .string(effort)
        }
        guard (try? await connection.request("turn/start", .object(turn), timeout: .seconds(30))) != nil else { return nil }
        let effort = turn["effort"]
        return await Self.within(.seconds(90)) {
            var answer: String?
            var triedAgain = false
            for await event in events {
                if let approval = event.approval {
                    try? await connection.send(CodexOutbound.decide(approval, "decline"))
                    continue
                }
                guard case .notification(let method, let params) = event,
                      params["threadId"]?.string == threadID else { continue }
                if method == "item/completed", params["item"]?["type"]?.string == "agentMessage",
                   let text = params["item"]?["text"]?.string, !text.isEmpty {
                    answer = text
                }
                guard method == "turn/completed" else { continue }
                if !triedAgain, let named = answer, ChatNames.willNotDo(named) {
                    triedAgain = true
                    var again: [String: JSONValue] = ["threadId": .string(threadID),
                                                      "input": [["type": "text", "text": .string(Self.namingAgain(named))]]]
                    if let effort { again["effort"] = effort }
                    _ = try? await connection.request("turn/start", .object(again), timeout: .seconds(30))
                    continue
                }
                return answer
            }
            return answer
        }
    }

    /// The lowest of a model's efforts: a name needs no thinking.
    nonisolated static func lowestEffort(of efforts: [String]) -> String? {
        ["none", "minimal", "low", "medium", "high", "xhigh", "max"].first { efforts.contains($0) }
    }

    /// `work`'s answer, or nil when it takes longer than `limit` — really
    /// then: a task group waits for `work` to end however it is cancelled.
    nonisolated static func within(_ limit: Duration, _ work: @escaping @Sendable () async -> String?) async -> String? {
        let once = OnceAnswer()
        return await withCheckedContinuation { continuation in
            once.set(continuation)
            Task { once.finish(await work()) }
            Task {
                try? await Task.sleep(for: limit)
                once.finish(nil)
            }
        }
    }
}

/// A continuation resumed once, whichever answers first.
final class OnceAnswer: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String?, Never>?

    func set(_ continuation: CheckedContinuation<String?, Never>) {
        lock.withLock { self.continuation = continuation }
    }

    func finish(_ value: String?) {
        let waiting = lock.withLock { () -> CheckedContinuation<String?, Never>? in
            defer { continuation = nil }
            return continuation
        }
        waiting?.resume(returning: value)
    }
}
