import Foundation
import Observation
import UDeckAgents

/// A Codex thread saved by the CLI, to continue from the session menu.
public struct CodexSaved: Sendable, Equatable {
    public let id: String
    public let title: String
    /// Where `title` came from: the thread's own name, or its first words.
    public var source: NameSource = .firstWords
    public let cwd: String?
    public let updated: Date

    public var folderName: String? { cwd.map { URL(fileURLWithPath: $0).lastPathComponent } }

    static func list(_ result: JSONValue) -> [CodexSaved] {
        (result["data"]?.array ?? []).compactMap { raw -> CodexSaved? in
            guard let id = raw["id"]?.string, raw["ephemeral"]?.bool != true else { return nil }
            let cwd = raw["cwd"]?.string
            let named: (String, NameSource) = if let own = raw["name"]?.string.flatMap({ ChatNames.own($0) }) {
                (own, .own)
            } else if let words = ChatNames.firstWords(raw["preview"]?.string ?? "") {
                (words, .firstWords)
            } else {
                (cwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? id, .folder)
            }
            return CodexSaved(id: id, title: named.0, source: named.1, cwd: cwd,
                              updated: Date(timeIntervalSince1970: raw["updatedAt"]?.number ?? 0))
        }
    }
}

/// An approval Codex waits on the person for.
public struct CodexAsk: Sendable, Equatable, Identifiable {
    public let requestID: String
    public let ask: CodexApprovalAsk
    public var id: String { requestID }

    public var title: String {
        switch ask.kind {
        case .command: "Shell"
        case .fileChange: "Edit"
        case .other(let method): method
        }
    }

    public var summary: String {
        switch ask.kind {
        case .command(let command): command
        case .fileChange: ask.reason ?? ""
        case .other: ask.reason ?? ""
        }
    }
}

/// The chat's view of one Codex thread over `codex app-server`: its items
/// turned into the same feed a Claude session has, its approvals into asks,
/// the person's messages into turns — with the model and the effort given
/// per turn, so either changes from the next message without a restart.
@MainActor
@Observable
public final class CodexSession: Identifiable {
    public let id = UUID()
    public let folder: URL
    public var title: String
    /// Where `title` came from: a weaker source does not replace it.
    public internal(set) var titleSource: NameSource
    public private(set) var state: ChatSession.State = .starting
    public private(set) var items: [FeedItem] = []
    public private(set) var asks: [CodexAsk] = []
    public private(set) var threadID: String?
    public private(set) var models: [ModelChoice] = []
    /// The model the thread runs with, as the server said.
    public private(set) var model: String?
    public internal(set) var chosenModel: String?
    public internal(set) var effort: String?
    public private(set) var context: (tokens: Int, window: Int)?
    public private(set) var turnStartedAt: Date?
    /// What it does now, while a turn runs.
    public private(set) var activity: AgentActivity?
    /// The tokens that came back this turn.
    public private(set) var tokens = TurnTokens()
    /// The thread's output tokens as Codex last said them, and when the turn began.
    @ObservationIgnored private var threadOutput = 0
    @ObservationIgnored private var turnBase = 0
    @ObservationIgnored private var retries = 0
    /// The person's messages sent while a turn ran that Codex has not taken
    /// yet, oldest first. Each is steered into the running turn
    /// (`turn/steer`) and taken after the step it is on, the turn going on
    /// with it; its `userMessage` item, under the id it was sent with, says
    /// when. Measured with codex 0.160 on 11-25: taken right after the command
    /// running, or after the answer being written, one turn for both.
    public private(set) var waitingMessages: [WaitingMessage] = []
    /// Messages a Stop cancelled before Codex took them: kept, oldest first,
    /// until they are sent again or put back into the field.
    public private(set) var unsentMessages: [WaitingMessage] = []
    /// What each unsent message is told, with its pictures.
    @ObservationIgnored private var unsentSent: [UUID: (text: String, pictures: [String])] = [:]
    /// The person pressed Stop: the turn's end leaves what waits unsent.
    @ObservationIgnored private var stopping = false
    /// Waiting messages not steered: sent before the turn had an id, or
    /// refused by it. The first starts the next turn; the rest are steered
    /// into it.
    @ObservationIgnored private var waiting: [(id: UUID, text: String, pictures: [String])] = []
    /// Waiting messages steered into the running turn and not taken yet.
    @ObservationIgnored private var steered: [(id: UUID, text: String, pictures: [String])] = []

    @ObservationIgnored public var onAsk: ((CodexAsk) -> Void)?
    @ObservationIgnored public var onTurnFinished: ((String) -> Void)?

    @ObservationIgnored private var connection: CodexConnection?
    @ObservationIgnored private var reader: Task<Void, Never>?
    @ObservationIgnored private var turnID: String?
    /// Errors this turn already put in the feed: the app server says one and
    /// then fails the turn with the same one.
    @ObservationIgnored private var turnErrors: Set<String> = []
    /// The feed index of each agent message still arriving, by item id.
    @ObservationIgnored private var streaming: [String: Int] = [:]

    public init(folder: URL, title: String? = nil, titleSource: NameSource? = nil, threadID: String? = nil) {
        self.folder = folder
        self.title = title ?? folder.lastPathComponent
        self.titleSource = titleSource ?? (title == nil ? .folder : .firstWords)
        self.threadID = threadID
    }

    /// Calls the session `text`, unless its name came from a stronger
    /// source; true when it changed.
    @discardableResult
    public func name(_ text: String, from source: NameSource) -> Bool {
        guard source >= titleSource, !text.isEmpty, text != title || source != titleSource else { return false }
        title = text
        titleSource = source
        return true
    }

    /// Puts the thread in Codex's archive: out of its history, kept on disk.
    /// For the live check, which leaves no test thread in the person's list.
    func archive() async {
        guard let connection, let threadID else { return }
        _ = try? await connection.request("thread/archive", ["threadId": .string(threadID)], timeout: .seconds(10))
    }

    /// Gives the thread the name `text` in Codex itself — its app and its
    /// thread list show it too. Codex answers with `thread/name/updated`.
    public func setName(_ text: String) async {
        guard let connection, let threadID else { return }
        _ = try? await connection.request("thread/name/set", ["threadId": .string(threadID), "name": .string(text)],
                                          timeout: .seconds(10))
    }

    public var isEnded: Bool { if case .ended = state { true } else { false } }

    /// The signed-in account's windows (5 hours, a week), as Codex last said
    /// them: read when the session starts, and on every update it sends.
    public private(set) var rateLimits: CodexRateLimits?

    public var contextPercent: Double? {
        guard let context, context.window > 0 else { return nil }
        return min(100, Double(context.tokens) / Double(context.window) * 100)
    }

    // MARK: - Starting

    public func start(executable: URL, arguments: [String] = ["app-server"], environment: [String: String]) async {
        do {
            let connection = try CodexConnection(executable: executable, arguments: arguments,
                                                 environment: environment, directory: folder)
            self.connection = connection
            await connection.start()
            let events = connection.events
            reader = Task { [weak self] in
                for await event in events { self?.receive(event) }
                self?.ended()
            }
            _ = try await connection.handshake(client: "udeck-agents", version: "0.1.0")
            if let list = try? await connection.request("model/list", [:], timeout: .seconds(30)) {
                models = Self.models(list)
            }
            let result: JSONValue
            if let threadID {
                result = try await connection.request("thread/resume", ["threadId": .string(threadID)])
            } else {
                // The approval policy and the sandbox are the person's, from
                // their Codex settings: it asks when a command leaves the
                // project, as in the terminal.
                result = try await connection.request("thread/start", ["cwd": .string(folder.path)])
            }
            let resumed = threadID != nil
            if let limits = try? await connection.request("account/rateLimits/read", [:], timeout: .seconds(10)) {
                rateLimits = CodexRateLimits(limits["rateLimits"] ?? .null)
            }
            threadID = result["thread"]?["id"]?.string ?? threadID
            if let own = result["thread"]?["name"]?.string, let name = ChatNames.own(own) {
                self.name(name, from: .own)
            }
            model = result["model"]?.string
            if effort == nil { effort = result["reasoningEffort"]?.string }
            state = .idle
            if resumed, items.isEmpty, let threadID,
               let turns = try? await connection.request("thread/turns/list", ["threadId": .string(threadID), "limit": 30]) {
                let history = Self.history(turns)
                if !history.isEmpty { items = history + [.note(id: UUID(), text: "resumed")] + items }
            }
        } catch {
            fail("could not start: \(error)")
        }
    }

    /// A saved thread's turns, newest first as the server lists them, as the
    /// feed shows them, oldest first.
    nonisolated static func history(_ turns: JSONValue) -> [FeedItem] {
        var out: [FeedItem] = []
        for turn in (turns["data"]?.array ?? []).reversed() {
            for item in turn["items"]?.array ?? [] {
                switch item["type"]?.string {
                case "userMessage":
                    let text = (item["content"]?.array ?? []).compactMap { $0["text"]?.string }.joined(separator: "\n")
                    if !text.isEmpty { out.append(.user(id: UUID(), text: text)) }
                case "agentMessage":
                    if let text = item["text"]?.string, !text.isEmpty { out.append(.assistant(id: UUID(), text: text, streaming: false)) }
                default:
                    guard let tool = tool(item) else { continue }
                    let output = item["aggregatedOutput"]?.string ?? ""
                    let failed = (item["exitCode"]?.int).map { $0 != 0 } ?? false
                    out.append(.tool(id: tool.id, name: tool.name, summary: tool.summary,
                                     result: ToolOutcome(isError: failed, preview: String(output.prefix(600)))))
                }
            }
        }
        return Array(out.suffix(400))
    }

    /// The threads the CLI saved, newest first.
    public func savedThreads(limit: Int = 10) async -> [CodexSaved] {
        guard let connection, let list = try? await connection.request("thread/list", ["limit": .number(Double(limit))]) else { return [] }
        return CodexSaved.list(list)
    }

    nonisolated static func models(_ list: JSONValue) -> [ModelChoice] {
        (list["data"]?.array ?? []).compactMap { raw in
            guard raw["hidden"]?.bool != true, let value = raw["id"]?.string ?? raw["model"]?.string else { return nil }
            let efforts = (raw["supportedReasoningEfforts"]?.array ?? []).compactMap { $0["reasoningEffort"]?.string ?? $0.string }
            return ModelChoice(value: value, name: raw["displayName"]?.string ?? value, resolved: raw["model"]?.string,
                               efforts: efforts)
        }
    }

    // MARK: - From the person

    /// A turn: `shown` is what the feed shows, `text` what Codex is given
    /// (the conversation so far, when it has just been handed over).
    /// `pictures`: paths of pictures that go with it, which Codex looks at.
    public func send(_ shown: String, text: String? = nil, pictures: [String] = []) {
        let shown = shown.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !shown.isEmpty, let connection, let threadID, !isEnded else { return }
        let id = UUID()
        if titleSource < .firstWords, let words = ChatNames.firstWords(shown) { name(words, from: .firstWords) }
        if state == .working {
            waitingMessages.append(WaitingMessage(id: id, text: shown))
            waiting.append((id, text ?? shown, pictures))
            steerWaiting()
            return
        }
        items.append(.user(id: id, text: shown))
        startTurn(text ?? shown, pictures: pictures, connection: connection, threadID: threadID)
    }

    private static func input(_ text: String, pictures: [String]) -> JSONValue {
        // `localImage`, as the app server names it (a live turn, 11-25: `local_image` is
        // «unknown variant»).
        .array([["type": "text", "text": .string(text)]] + pictures.map { ["type": "localImage", "path": .string($0)] })
    }

    /// The messages waiting, steered into the running turn once it has an
    /// id. One the turn refuses — it has just ended — waits for the next.
    private func steerWaiting() {
        guard let connection, let threadID, let turn = turnID, !waiting.isEmpty else { return }
        let messages = waiting
        waiting.removeAll()
        steered += messages
        for message in messages {
            let params: JSONValue = ["threadId": .string(threadID), "expectedTurnId": .string(turn),
                                     "clientUserMessageId": .string(message.id.uuidString),
                                     "input": Self.input(message.text, pictures: message.pictures)]
            Task {
                do {
                    _ = try await connection.request("turn/steer", params)
                } catch {
                    // Refused by a turn that has just ended: into the turn after it — one
                    // under way already, or one it starts now. The `turn/completed` still
                    // to come for this turn starts it otherwise.
                    guard let index = steered.firstIndex(where: { $0.id == message.id }) else { return }
                    waiting.append(steered.remove(at: index))
                    if let now = turnID, now != turn {
                        steerWaiting()
                    } else if state != .working {
                        startWaiting()
                    }
                }
            }
        }
    }

    /// The unsent messages sent again, oldest first, as if typed now.
    public func sendUnsent() {
        let messages = unsentMessages
        unsentMessages.removeAll()
        for message in messages {
            let sent = unsentSent.removeValue(forKey: message.id)
            send(message.text, text: sent.flatMap { $0.text == message.text ? nil : $0.text }, pictures: sent?.pictures ?? [])
        }
    }

    /// The unsent messages, taken out — to be put back into the field.
    public func takeUnsent() -> [WaitingMessage] {
        let messages = unsentMessages
        unsentMessages.removeAll()
        for message in messages { unsentSent[message.id] = nil }
        return messages
    }

    public func restoreUnsent(_ texts: [String]) {
        unsentMessages += texts.map { WaitingMessage(id: UUID(), text: $0) }
    }

    /// A waiting message Codex took: into the feed here.
    private func taken(_ id: UUID) {
        steered.removeAll { $0.id == id }
        guard let index = waitingMessages.firstIndex(where: { $0.id == id }) else { return }
        let message = waitingMessages.remove(at: index)
        items.append(.user(id: message.id, text: message.text))
    }

    /// The first message waiting starts a turn; the rest are steered into it.
    private func startWaiting() {
        guard !waiting.isEmpty, let connection, let threadID else { return }
        let next = waiting.removeFirst()
        taken(next.id)
        turnStartedAt = nil
        startTurn(next.text, pictures: next.pictures, connection: connection, threadID: threadID)
    }

    private func startTurn(_ text: String, pictures: [String] = [], connection: CodexConnection, threadID: String) {
        state = .working
        if turnStartedAt == nil {
            turnStartedAt = Date()
            tokens = TurnTokens()
            turnBase = threadOutput
            retries = 0
        }
        activity = .requesting
        var params: [String: JSONValue] = [
            "threadId": .string(threadID),
            "input": Self.input(text, pictures: pictures),
        ]
        if let chosenModel { params["model"] = .string(chosenModel) }
        if let effort { params["effort"] = .string(effort) }
        Task {
            do {
                let result = try await connection.request("turn/start", .object(params))
                if let id = result["turn"]?["id"]?.string, turnID == nil, state == .working {
                    turnID = id
                    steerWaiting()
                }
            } catch {
                note("not sent: \(error)")
                if state == .working, asks.isEmpty { state = .idle; turnStartedAt = nil; activity = nil }
            }
        }
    }

    /// «Отправить сейчас»: the turn is stopped and the messages waiting go
    /// at once — the turn's end starts them (`turn/completed`).
    public func sendNow() {
        guard let connection, let threadID, let turnID, state == .working, !waitingMessages.isEmpty else { return }
        Task { _ = try? await connection.request("turn/interrupt", ["threadId": .string(threadID), "turnId": .string(turnID)]) }
    }

    /// Stops the running turn; the messages waiting stay unsent (11-26).
    public func interrupt() {
        guard let connection, let threadID, let turnID, state == .working else { return }
        stopping = true
        Task { _ = try? await connection.request("turn/interrupt", ["threadId": .string(threadID), "turnId": .string(turnID)]) }
    }

    /// `accept`, `acceptForSession` or `decline`.
    public func answer(_ ask: CodexAsk, with decision: String) {
        guard let connection else { return }
        asks.removeAll { $0.requestID == ask.requestID }
        Task { try? await connection.send(CodexOutbound.decide(ask.ask, .string(decision))) }
    }

    public func close() async {
        guard let connection else { return }
        _ = await connection.close(grace: .seconds(5))
    }

    public func fail(_ reason: String) {
        state = .ended(reason)
        items.append(.note(id: UUID(), text: reason))
    }

    func note(_ text: String) { items.append(.note(id: UUID(), text: text)) }

    // MARK: - From Codex

    func receive(_ event: CodexInbound) {
        if let approval = event.approval {
            let ask = CodexAsk(requestID: Self.key(approval.id), ask: approval)
            asks.append(ask)
            activity = .asking
            onAsk?(ask)
            return
        }
        guard case .notification(let method, let params) = event else { return }
        switch method {
        case "turn/started":
            turnID = params["turn"]?["id"]?.string ?? turnID
            steerWaiting()
        case "item/agentMessage/delta":
            guard let itemID = params["itemId"]?.string, let delta = params["delta"]?.string else { return }
            tokens.streamed(delta)
            if state == .working { activity = .writing }
            if let index = streaming[itemID], case .assistant(let id, let text, _) = items[index] {
                items[index] = .assistant(id: id, text: text + delta, streaming: true)
            } else {
                items.append(.assistant(id: UUID(), text: delta, streaming: true))
                streaming[itemID] = items.count - 1
            }
        case "item/started":
            let item = params["item"] ?? .null
            if item["type"]?.string == "userMessage", let client = item["clientId"]?.string, let id = UUID(uuidString: client) {
                taken(id)
            } else if let tool = Self.tool(item) {
                items.append(.tool(id: tool.id, name: tool.name, summary: tool.summary, result: nil))
                if state == .working { activity = .tool(tool.name) }
            } else if item["type"]?.string == "reasoning", state == .working {
                activity = .thinking
            }
        case "item/completed":
            let item = params["item"] ?? .null
            if Self.tool(item) != nil, state == .working, asks.isEmpty { activity = .requesting }
            complete(item)
        case "turn/completed":
            for (_, index) in streaming {
                if case .assistant(let id, let text, _) = items[index] { items[index] = .assistant(id: id, text: text, streaming: false) }
            }
            streaming.removeAll()
            turnID = nil
            if let error = params["turn"]?["error"]?["message"]?.string, !error.isEmpty, !turnErrors.contains(error) { note(error) }
            turnErrors.removeAll()
            // Steered and not taken — the turn stopped first — they wait for
            // the next, oldest first.
            waiting = steered + waiting
            steered.removeAll()
            if stopping {
                stopping = false
                for message in waiting {
                    if let at = waitingMessages.firstIndex(where: { $0.id == message.id }) {
                        unsentMessages.append(waitingMessages.remove(at: at))
                        unsentSent[message.id] = (message.text, message.pictures)
                    }
                }
                waiting.removeAll()
                if !isEnded { note("stopped") }
            }
            if !isEnded {
                if !waiting.isEmpty, connection != nil, threadID != nil {
                    startWaiting()
                    return
                }
                state = .idle
                turnStartedAt = nil
                activity = nil
                onTurnFinished?(lastAnswer)
            }
        case "thread/tokenUsage/updated":
            let usage = params["tokenUsage"] ?? .null
            if let window = usage["modelContextWindow"]?.int, window > 0 {
                context = (usage["last"]?["totalTokens"]?.int ?? 0, window)
            }
            if let output = usage["total"]?["outputTokens"]?.int {
                threadOutput = output
                if turnStartedAt != nil { tokens.countedSoFar(output - turnBase) }
            }
        case "account/rateLimits/updated":
            rateLimits = CodexRateLimits(params["rateLimits"] ?? .null)
        case "thread/name/updated":
            guard params["threadId"]?.string == threadID else { return }
            if let own = params["threadName"]?.string, let name = ChatNames.own(own) {
                self.name(name, from: .own)
            }
        case "serverRequest/resolved":
            if let id = params["requestId"] { asks.removeAll { $0.requestID == Self.key(id) } }
        case "error":
            guard let message = params["error"]?["message"]?.string ?? params["message"]?.string else { return }
            // One Codex tries again is said on the line above the field, not in the feed.
            if params["willRetry"]?.bool == true, state == .working {
                retries += 1
                activity = .retrying(status: params["error"]?["codexErrorInfo"]?.object?.values.first?["httpStatusCode"]?.int,
                                     error: message, attempt: retries, next: nil)
                return
            }
            if turnErrors.insert(message).inserted { note(message) }
        default:
            return
        }
    }

    private func complete(_ item: JSONValue) {
        let parsed = CodexItem(item)
        switch parsed.type {
        case "agentMessage":
            if let index = streaming.removeValue(forKey: parsed.id), case .assistant(let id, _, _) = items[index] {
                items[index] = .assistant(id: id, text: parsed.text, streaming: false)
            } else if !parsed.text.isEmpty {
                items.append(.assistant(id: UUID(), text: parsed.text, streaming: false))
            }
        default:
            guard let tool = Self.tool(item),
                  let index = items.lastIndex(where: { $0.id == "tool-" + tool.id }),
                  case .tool(let id, let name, let summary, _) = items[index] else { return }
            let output = item["aggregatedOutput"]?.string ?? item["status"]?.string ?? ""
            let failed = (item["exitCode"]?.int).map { $0 != 0 } ?? (item["status"]?.string == "failed")
            let preview = output.split(separator: "\n", omittingEmptySubsequences: false).prefix(6).joined(separator: "\n")
            items[index] = .tool(id: id, name: name, summary: summary,
                                 result: ToolOutcome(isError: failed, preview: String(preview.prefix(600))))
        }
    }

    /// An operation of a turn as one tool line: what it is and what it was given.
    nonisolated static func tool(_ item: JSONValue) -> (id: String, name: String, summary: String)? {
        guard let id = item["id"]?.string else { return nil }
        switch item["type"]?.string {
        case "commandExecution":
            return (id, "Shell", item["command"]?.string ?? "")
        case "fileChange":
            let paths = (item["changes"]?.array ?? []).compactMap { $0["path"]?.string }
            return (id, "Edit", paths.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: ", "))
        case "mcpToolCall":
            return (id, item["tool"]?.string ?? "Tool", item["server"]?.string ?? "")
        case "webSearch":
            return (id, "Search", item["query"]?.string ?? "")
        default:
            return nil
        }
    }

    nonisolated static func key(_ id: JSONValue) -> String {
        if let text = id.string { return text }
        if let number = id.int { return String(number) }
        return "\(id)"
    }

    public var lastAnswer: String {
        for item in items.reversed() { if case .assistant(_, let text, _) = item { return text } }
        return ""
    }

    private func ended() {
        asks.removeAll()
        // Messages Codex never took: in the feed, and said to be unsent.
        if !waitingMessages.isEmpty {
            items += waitingMessages.map { FeedItem.user(id: $0.id, text: $0.text) }
            waitingMessages.removeAll()
            note("not sent: the session has ended")
        }
        waiting.removeAll()
        steered.removeAll()
        if !isEnded { state = .ended("the session ended") }
    }
}
