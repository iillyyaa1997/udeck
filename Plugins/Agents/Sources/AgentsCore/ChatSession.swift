import Foundation
import Observation
import UDeckAgents

/// A message the person sent while the agent worked, not taken by it yet
/// (11-25). The feed shows it last, waiting, until the agent takes it — after
/// the step it is on, the same turn going on with it, as in the terminal; or,
/// with no step ahead, as the next turn — and it goes into the feed there.
public struct WaitingMessage: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let text: String
}

/// One line of a session's feed, as the chat draws it.
public enum FeedItem: Sendable, Equatable, Identifiable {
    case user(id: UUID, text: String)
    /// The model's words; `streaming` while they are still arriving.
    case assistant(id: UUID, text: String, streaming: Bool)
    /// A tool call, one line: its name and what it was given, then its result.
    case tool(id: String, name: String, summary: String, result: ToolOutcome?)
    /// Something said about the session rather than in it (resumed, stopped…).
    case note(id: UUID, text: String)

    public var id: String {
        switch self {
        case .user(let id, _), .assistant(let id, _, _), .note(let id, _): id.uuidString
        case .tool(let id, _, _, _): "tool-" + id
        }
    }
}

public struct ToolOutcome: Sendable, Equatable {
    public let isError: Bool
    /// The first lines of what the tool returned.
    public let preview: String
}

/// Something the agent waits on the user for: a permission, or questions.
public struct ChatAsk: Sendable, Equatable, Identifiable {
    public let requestID: String
    public let ask: ClaudePermissionAsk
    public var id: String { requestID }

    /// What the ask is about, in one line.
    public var summary: String { ToolSummary.of(name: ask.toolName, input: ask.input) }
}

/// A model the CLI offers: what to ask for, how to call it, and the effort
/// levels it takes (from `initialize`).
public struct ModelChoice: Sendable, Equatable {
    public let value: String
    public let name: String
    public let resolved: String?
    public let efforts: [String]

    public init(value: String, name: String, resolved: String? = nil, efforts: [String] = []) {
        self.value = value
        self.name = name
        self.resolved = resolved
        self.efforts = efforts
    }

    static func list(_ body: JSONValue) -> [ModelChoice] {
        (body["models"]?.array ?? []).compactMap { raw in
            guard let value = raw["value"]?.string else { return nil }
            return ModelChoice(value: value, name: raw["displayName"]?.string ?? value,
                               resolved: raw["resolvedModel"]?.string,
                               efforts: (raw["supportedEffortLevels"]?.array ?? []).compactMap(\.string))
        }
    }
}

/// The chat's view of one Claude Code session: the agent's lines turned into a
/// feed, its asks into cards, the user's input into messages — over any
/// AgentChannel, the process here or one the helper keeps.
@MainActor
@Observable
public final class ChatSession: Identifiable {
    public enum State: Sendable, Equatable {
        case starting
        case idle
        /// A turn is running.
        case working
        case ended(String)
    }

    public let id: UUID
    public let folder: URL
    /// Whose login the session runs on; a move starts it again on another.
    public internal(set) var account: ChatAccount
    public private(set) var state: State = .starting
    public private(set) var items: [FeedItem] = []
    public private(set) var asks: [ChatAsk] = []
    /// Claude Code's own id for the session, once it has said it.
    public private(set) var sessionID: String?
    public private(set) var model: String?
    /// The models the CLI offers, from `initialize`.
    public private(set) var models: [ModelChoice] = []
    /// The model asked for here (a `value` of `models`), nil for the CLI's
    /// own choice.
    public internal(set) var chosenModel: String?
    /// The effort the session runs with, nil for the CLI's own; a change
    /// starts it again with `--effort`, continuing it.
    public internal(set) var effort: String?
    /// How full the context is, after the last turn.
    public private(set) var context: ClaudeContextUsage?
    /// When the running turn began, while one runs.
    public private(set) var turnStartedAt: Date?
    /// The person's messages sent while a turn ran that the CLI has not
    /// taken yet, oldest first. The CLI takes one after the step it is on and
    /// the same turn goes on with it, or, with no step ahead, as the next
    /// turn; its echo says when. Measured with claude 2.1.332 on 11-25: the
    /// echo right after the step's result, the answer heeding it, one result
    /// for both — and the next turn, after the result, when the answer was
    /// already being written.
    public private(set) var waitingMessages: [WaitingMessage] = []
    /// Whether the CLI is in a turn: from the echo of a message it took to
    /// the turn's result.
    public private(set) var inTurn = false
    public var title: String
    /// Where `title` came from: a weaker source does not replace it.
    public internal(set) var titleSource: NameSource

    /// Told of every new ask, and of every turn that finished (with its last
    /// words): for a notification when nobody is looking.
    @ObservationIgnored public var onAsk: ((ChatAsk) -> Void)?
    @ObservationIgnored public var onTurnFinished: ((String) -> Void)?
    /// Told when what identifies the session changes (Claude's id, the title),
    /// for whoever keeps it on disk.
    @ObservationIgnored public var onRecord: (() -> Void)?
    /// Told what the account's limits are: a window as the CLI reports it
    /// during a turn, and the whole picture after each (`get_usage`).
    @ObservationIgnored public var onRateLimit: ((ClaudeRateLimit) -> Void)?
    /// With the account it was asked of: the session may be on another by
    /// the time the answer comes.
    @ObservationIgnored public var onUsage: ((ClaudeUsage, ChatAccount) -> Void)?
    /// Told when a turn stopped at the account's limit, with when it resets
    /// if the CLI said: the message it stopped at is `lastSent`.
    @ObservationIgnored public var onLimit: ((Date?) -> Void)?
    /// The last message sent, as shown and as told: what to send again
    /// where the session goes on after a limit.
    public private(set) var lastSent: (text: String, payload: String?, images: [(mediaType: String, base64: String)])?
    /// A limit the CLI said it refused this turn over.
    @ObservationIgnored private var refused: ClaudeRateLimit?

    /// Messages a stop cancelled before the agent took them — the person's
    /// Stop, or the account's limit: kept, oldest first, until they are sent
    /// again or put back into the field. Never dropped (the operator, 11-26:
    /// «Терять сообщения нельзя»).
    public private(set) var unsentMessages: [WaitingMessage] = []
    /// What each waiting or unsent message is told, with its pictures: sent
    /// again as it was.
    @ObservationIgnored private var outgoing: [UUID: (told: String, images: [(mediaType: String, base64: String)])] = [:]
    /// Why the running turn is being stopped, until its result comes.
    @ObservationIgnored private var stopping: Stop?
    /// Messages that waited behind a turn stopped at the limit: sent after
    /// it where the session goes on, or unsent when it cannot go on now.
    @ObservationIgnored private var heldAtLimit: [WaitingMessage] = []
    enum Stop { case person, limit }

    /// Messages sent from here that the CLI has not repeated back yet, oldest
    /// first, with the waiting message each is, if it waits: an echo of one
    /// says the CLI took it; any other echo is the conversation read back
    /// after a restart.
    @ObservationIgnored private var unconfirmed: [(told: String, waiting: UUID?)] = []

    @ObservationIgnored private var connection: ClaudeCodeConnection?
    @ObservationIgnored private var reader: Task<Void, Never>?
    /// Which start the reader belongs to: a session started again (a new
    /// effort, another login) must not be ended by the old process exiting.
    @ObservationIgnored private var generation = 0
    /// The streaming answer's item, while one is arriving.
    @ObservationIgnored private var streamingIndex: Int?

    public init(id: UUID = UUID(), folder: URL, account: ChatAccount, title: String? = nil,
                titleSource: NameSource? = nil, resumeID: String? = nil, history: [FeedItem] = [])
    {
        self.id = id
        self.folder = folder
        self.account = account
        self.title = title ?? folder.lastPathComponent
        self.titleSource = titleSource ?? (title == nil ? .folder : .firstWords)
        self.sessionID = resumeID
        self.items = history
        if resumeID != nil, !history.isEmpty { items.append(.note(id: UUID(), text: "resumed")) }
    }

    /// Calls the session `text`, unless its name came from a stronger
    /// source; true when it changed.
    @discardableResult
    public func name(_ text: String, from source: NameSource) -> Bool {
        guard source >= titleSource, !text.isEmpty, text != title || source != titleSource else { return false }
        title = text
        titleSource = source
        onRecord?()
        return true
    }

    /// Starts the agent over `channel` and says hello to it — or, for an agent
    /// already running (`reattached`, after uDeck restarted and the helper kept
    /// it), only listens: the channel replays what the session said, and the
    /// feed, the asks still open and the turn under way are rebuilt from it.
    public func start(channel: any AgentChannel, reattached: Bool = false) async {
        generation += 1
        let mine = generation
        reader?.cancel()
        let connection = ClaudeCodeConnection(channel: channel)
        self.connection = connection
        await connection.start()
        let events = connection.events
        reader = Task { [weak self] in
            for await event in events {
                guard self?.generation == mine else { return }
                self?.receive(event)
            }
            if self?.generation == mine { self?.ended() }
        }
        if reattached {
            if state == .starting { state = .idle }
            return
        }
        do {
            let answer = try await connection.request({ ClaudeOutbound.initialize(id: $0) }, timeout: .seconds(60))
            let offered = ModelChoice.list(answer.body)
            if !offered.isEmpty { models = offered }
            if state == .starting { state = .idle }
            refreshContext()
        } catch {
            state = .ended("could not start: \(error)")
        }
    }

    /// Says the session is starting again — a new effort, another login —
    /// and why, in the feed. The caller closes and starts it.
    /// The conversation read back from its transcript, put before what the
    /// session has said since: read off the main thread, as a transcript can
    /// be a hundred megabytes.
    func prependHistory(_ history: [FeedItem]) {
        guard !history.isEmpty else { return }
        items = history + [.note(id: UUID(), text: "resumed")] + items.filter {
            if case .note(_, "loading-history") = $0 { false } else { true }
        }
    }

    func beginRestart(_ note: String) {
        // The process about to be closed is no longer this session's: its
        // reader ending must not end the session started again after it.
        generation += 1
        state = .starting
        turnStartedAt = nil
        inTurn = false
        stopping = nil
        asks.removeAll()
        items.append(.note(id: UUID(), text: note))
    }

    /// Switches the model in the running session (`set_model`).
    public func switchModel(to value: String) {
        guard let connection, !isEnded else { return }
        Task {
            do {
                let answer = try await connection.request({ ClaudeOutbound.setModel(id: $0, value) }, timeout: .seconds(20))
                if answer.succeeded {
                    chosenModel = value
                    note("model:" + value)
                } else {
                    note("model-failed:" + value)
                }
            } catch {
                note("model-failed:" + value)
            }
        }
    }

    /// Asks how full the context is (`get_context_usage`).
    /// Asks what the account's limits are now (`get_usage`, which spends
    /// nothing).
    func refreshUsage() {
        guard let connection, !isEnded else { return }
        let asked = account
        Task {
            guard let answer = try? await connection.request({ ClaudeOutbound.usage(id: $0) }, timeout: .seconds(20)),
                  answer.succeeded else { return }
            onUsage?(ClaudeUsage(answer.body), asked)
        }
    }

    /// Whether what a failed turn said is the account's limit.
    nonisolated static func isLimit(_ text: String) -> Bool {
        let text = text.lowercased()
        return text.contains("limit") && (text.contains("reached") || text.contains("hit your") || text.contains("resets"))
    }

    /// When a limit resets, from what the CLI said: `…|<epoch seconds>`.
    nonisolated static func resetTime(_ text: String) -> Date? {
        guard let tail = text.split(separator: "|").last, let seconds = Double(tail), seconds > 1_000_000_000 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    func refreshContext() {
        guard let connection, !isEnded else { return }
        Task {
            guard let answer = try? await connection.request({ ClaudeOutbound.contextUsage(id: $0) }, timeout: .seconds(20)),
                  answer.succeeded else { return }
            let usage = ClaudeContextUsage(answer.body)
            if usage.window > 0 { context = usage }
        }
    }

    // MARK: - From the user

    /// Sends a message; while a turn runs it waits for the CLI to take it,
    /// after the step it is on, as in the terminal.
    /// `payload`, when given, is what the agent is told instead of what the
    /// feed shows — the conversation so far, when it has just been handed
    /// over.
    public func send(_ text: String, payload: String? = nil, images: [(mediaType: String, base64: String)] = []) {
        send(text, payload: payload, images: images, again: false)
    }

    /// The message a turn stopped at, sent again where the session goes on —
    /// already in the feed, so not put there twice.
    public func sendAgain() {
        guard let lastSent else { return }
        send(lastSent.text, payload: lastSent.payload, images: lastSent.images, again: true)
    }

    private func send(_ text: String, payload: String?, images: [(mediaType: String, base64: String)], again: Bool) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let connection, !isEnded else { return }
        let told = payload ?? text
        let id = UUID()
        let waits = state == .working && !again
        if waits {
            waitingMessages.append(WaitingMessage(id: id, text: text))
            outgoing[id] = (told, images)
        } else {
            if !again { items.append(.user(id: id, text: text)) }
            lastSent = (text, payload, images)
        }
        unconfirmed.append((told, waits ? id : nil))
        state = .working
        if turnStartedAt == nil { turnStartedAt = Date() }
        if titleSource < .firstWords, let words = ChatNames.firstWords(text) { name(words, from: .firstWords) }
        Task {
            do {
                try await connection.send(ClaudeOutbound.userMessage(told, images: images))
            } catch {
                self.note("not sent: the session has ended")
            }
        }
    }

    /// Stops the running turn, and with it the messages waiting: they stay
    /// in the feed, unsent, for the person to send or put back into the field
    /// (the operator's «2» and «1», 11-26).
    public func interrupt() { stop(.person) }

    private func stop(_ reason: Stop) {
        guard let connection, state == .working, stopping == nil else { return }
        stopping = reason
        // Without `cancel_queued` the CLI runs what is queued right after the
        // stop (measured 11-26): the messages written while it waited at a
        // limit went to the same limit, and Stop seemed to do nothing.
        Task { _ = try? await connection.request({ ClaudeOutbound.interrupt(id: $0, cancelQueued: true) }, timeout: .seconds(10)) }
    }

    /// The unsent messages sent again, oldest first, as if typed now one
    /// after another: the first starts a turn, the rest wait for their step.
    public func sendUnsent() {
        let messages = unsentMessages
        unsentMessages.removeAll()
        resend(messages)
    }

    private func resend(_ messages: [WaitingMessage]) {
        for message in messages {
            let sent = outgoing.removeValue(forKey: message.id)
            let payload = sent.flatMap { $0.told == message.text ? nil : $0.told }
            send(message.text, payload: payload, images: sent?.images ?? [], again: false)
        }
    }

    /// Where the session goes on after a limit: the message it stopped at
    /// again, then those that waited behind it, in order.
    public func sendAgainAfterLimit() {
        sendAgain()
        let held = heldAtLimit
        heldAtLimit.removeAll()
        resend(held)
    }

    /// No account to go on under now: the messages that waited behind the
    /// stopped one are the person's to send.
    public func keepHeldAsUnsent() {
        unsentMessages += heldAtLimit
        heldAtLimit.removeAll()
    }

    /// The unsent messages, taken out — to be put back into the field.
    public func takeUnsent() -> [WaitingMessage] {
        let messages = unsentMessages
        unsentMessages.removeAll()
        for message in messages { outgoing[message.id] = nil }
        return messages
    }

    /// Unsent messages kept on disk, back after the plugin started again.
    public func restoreUnsent(_ texts: [String]) {
        unsentMessages += texts.map { WaitingMessage(id: UUID(), text: $0) }
    }

    public enum Answer: Sendable, Equatable {
        case allow
        /// Allow, and the rule the CLI proposed for next time.
        case allowAlways
        case deny
        /// AskUserQuestion: question text → chosen option labels.
        case choices([String: [String]])
    }

    public func answer(_ ask: ChatAsk, with answer: Answer) {
        guard let connection else { return }
        asks.removeAll { $0.requestID == ask.requestID }
        let message: JSONValue
        switch answer {
        case .allow: message = ClaudeOutbound.allow(ask.requestID, input: ask.ask.input)
        case .allowAlways: message = ClaudeOutbound.allow(ask.requestID, input: ask.ask.input, rules: ask.ask.suggestions)
        case .deny: message = ClaudeOutbound.deny(ask.requestID, message: "The user declined.")
        case .choices(let chosen): message = ClaudeOutbound.answers(ask.requestID, to: ask.ask, chosen: chosen)
        }
        Task { try? await connection.send(message) }
    }

    /// Ends the session the way closing the terminal would: stdin closed, the
    /// CLI finishes and exits. It can be resumed later by its id.
    public func close() async {
        guard let connection else { return }
        _ = await connection.close(grace: .seconds(5))
    }

    public var isEnded: Bool { if case .ended = state { true } else { false } }

    /// The session could not start at all (no `claude`, a folder gone).
    public func fail(_ reason: String) {
        state = .ended(reason)
        // Said in the feed too: a card's placeholder has no room for why.
        items.append(.note(id: UUID(), text: reason))
    }

    // MARK: - From the agent

    func receive(_ event: ClaudeInbound) {
        switch event {
        case .sessionStarted(let info, _):
            let changed = sessionID != info.sessionID
            sessionID = info.sessionID
            model = info.model
            if changed { onRecord?() }
        case .partial(let event, _):
            guard event.parentToolUseID == nil, case .text(let delta)? = event.delta else { return }
            appendStreaming(delta)
        case .assistant(let message, _):
            guard message.parentToolUseID == nil else { return }
            for block in message.blocks {
                switch block {
                case .text(let text):
                    finishStreaming(with: text)
                case .toolUse(let id, let name, let input):
                    finishStreaming(with: nil)
                    items.append(.tool(id: id, name: name, summary: ToolSummary.of(name: name, input: input),
                                       result: nil))
                case .thinking, .other:
                    continue
                }
            }
        case .userEcho(let text, _):
            if let index = unconfirmed.firstIndex(where: { $0.told == text }) {
                // Taken: a message that waited goes into the feed here, after
                // the step it waited for, or at the start of its own turn.
                if let id = unconfirmed.remove(at: index).waiting,
                   let at = waitingMessages.firstIndex(where: { $0.id == id }) {
                    let message = waitingMessages.remove(at: at)
                    items.append(.user(id: message.id, text: message.text))
                    // One that starts a turn of its own is what a limit sends again.
                    if let sent = outgoing.removeValue(forKey: id), !inTurn {
                        lastSent = (message.text, sent.told == message.text ? nil : sent.told, sent.images)
                    }
                }
            } else {
                // Not one of ours: the conversation read back from the journal.
                finishStreaming(with: nil)
                items.append(.user(id: UUID(), text: text))
                state = .working
                if turnStartedAt == nil { turnStartedAt = Date() }
            }
            inTurn = true
        case .toolResults(let results, _):
            for result in results {
                // A tool's result answers the ask about it, whoever answered.
                asks.removeAll { $0.ask.toolUseID == result.toolUseID }
                guard let index = items.lastIndex(where: { $0.id == "tool-" + result.toolUseID }),
                      case .tool(let id, let name, let summary, _) = items[index]
                else { continue }
                let preview = result.text.split(separator: "\n", omittingEmptySubsequences: false).prefix(6)
                    .joined(separator: "\n")
                items[index] = .tool(id: id, name: name, summary: summary,
                                     result: ToolOutcome(isError: result.isError, preview: String(preview.prefix(600))))
            }
        case .turnFinished(let result, _):
            finishStreaming(with: nil)
            // After a resume, or a background task's notice, the CLI reports a
            // result of zero turns before the real one (spec §10.20): it ends
            // nothing of the user's.
            let stopped = stopping
            guard stopped != nil || result.turns > 0 || (!inTurn && unconfirmed.isEmpty) else { return }
            stopping = nil
            inTurn = false
            // A stop cancelled what the CLI had not taken: unsent now.
            if stopped != nil {
                unconfirmed.removeAll()
                if stopped == .limit { heldAtLimit += waitingMessages } else { unsentMessages += waitingMessages }
                waitingMessages.removeAll()
            }
            // Stopped at the account's limit: not an error to read, but a
            // session to go on elsewhere, or later (`onLimit`).
            let limit = result.isError && (refused != nil || Self.isLimit(result.result))
            let resets = refused?.usage.resetsAt ?? Self.resetTime(result.result)
            refused = nil
            if result.isError, !result.result.isEmpty, !limit { note(result.result) }
            if stopped == .person, !limit { note("stopped") }
            // A message the CLI has not taken yet starts the next turn: the
            // session works on until it has.
            if unconfirmed.isEmpty, !isEnded {
                state = .idle
                turnStartedAt = nil
                refreshContext()
                refreshUsage()
                if limit {
                    onLimit?(resets)
                } else {
                    keepHeldAsUnsent()
                    onTurnFinished?(lastAnswer)
                }
            }
        case .request(let request):
            if let permission = request.permission {
                let ask = ChatAsk(requestID: request.requestID, ask: permission)
                asks.append(ask)
                onAsk?(ask)
            }
        case .cancelled(let requestID, _):
            asks.removeAll { $0.requestID == requestID }
        case .rateLimit(let limit, _):
            onRateLimit?(limit)
            if limit.status == "rejected" {
                refused = limit
                // claude 2.1.332 does not end a turn at a limit: it waits for
                // the reset — hours, a week's — saying «retry» every 30 s, and
                // the card said «Working» all along (measured 11-26). Stopped
                // here, the turn goes on under another account, or later.
                stop(.limit)
            }
        case .response, .system, .other:
            return
        }
    }

    /// The model's last words in the feed.
    public var lastAnswer: String {
        for item in items.reversed() {
            if case .assistant(_, let text, _) = item { return text }
        }
        return ""
    }

    private func appendStreaming(_ delta: String) {
        if let index = streamingIndex, case .assistant(let id, let text, true) = items[index] {
            items[index] = .assistant(id: id, text: text + delta, streaming: true)
        } else {
            items.append(.assistant(id: UUID(), text: delta, streaming: true))
            streamingIndex = items.count - 1
        }
    }

    /// The streamed answer is complete: `text` is its whole, as the CLI sent
    /// it (nil when the stream ended without one, e.g. before a tool call).
    private func finishStreaming(with text: String?) {
        if let index = streamingIndex, case .assistant(let id, let streamed, _) = items[index] {
            items[index] = .assistant(id: id, text: text ?? streamed, streaming: false)
            streamingIndex = nil
        } else if let text, !text.isEmpty {
            items.append(.assistant(id: UUID(), text: text, streaming: false))
        }
    }

    func note(_ text: String) {
        items.append(.note(id: UUID(), text: text))
    }

    private func ended() {
        finishStreaming(with: nil)
        asks.removeAll()
        // Messages the CLI never took: in the feed, and said to be unsent.
        if !waitingMessages.isEmpty {
            items += waitingMessages.map { FeedItem.user(id: $0.id, text: $0.text) }
            waitingMessages.removeAll()
            note("not sent: the session has ended")
        }
        unconfirmed.removeAll()
        inTurn = false
        if !isEnded { state = .ended("the session ended") }
    }
}

/// A tool call in one line: what it was given that a person would recognise.
public enum ToolSummary {
    public static func of(name: String, input: JSONValue) -> String {
        for key in ["command", "file_path", "path", "pattern", "url", "query", "description", "prompt"] {
            if let value = input[key]?.string, !value.isEmpty {
                return value.split(separator: "\n").first.map(String.init) ?? value
            }
        }
        if let questions = input["questions"]?.array, let first = questions.first?["question"]?.string {
            return first
        }
        return ""
    }
}
