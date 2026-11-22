import Foundation
import Observation
import UDeckAgents

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

    public let id = UUID()
    public let folder: URL
    public let account: ChatAccount
    public private(set) var state: State = .starting
    public private(set) var items: [FeedItem] = []
    public private(set) var asks: [ChatAsk] = []
    /// Claude Code's own id for the session, once it has said it.
    public private(set) var sessionID: String?
    public private(set) var model: String?
    /// Messages sent that no turn has finished yet: more than one means the
    /// rest are queued behind the running turn.
    public private(set) var pendingTurns = 0
    public var title: String

    /// Told of every new ask, and of every turn that finished (with its last
    /// words): for a notification when nobody is looking.
    @ObservationIgnored public var onAsk: ((ChatAsk) -> Void)?
    @ObservationIgnored public var onTurnFinished: ((String) -> Void)?

    @ObservationIgnored private var connection: ClaudeCodeConnection?
    @ObservationIgnored private var reader: Task<Void, Never>?
    /// The streaming answer's item, while one is arriving.
    @ObservationIgnored private var streamingIndex: Int?

    public init(folder: URL, account: ChatAccount, title: String? = nil, resumeID: String? = nil,
                history: [FeedItem] = [])
    {
        self.folder = folder
        self.account = account
        self.title = title ?? folder.lastPathComponent
        self.sessionID = resumeID
        self.items = history
        if resumeID != nil, !history.isEmpty { items.append(.note(id: UUID(), text: "resumed")) }
    }

    /// Starts the agent over `channel` and says hello to it.
    public func start(channel: any AgentChannel) async {
        let connection = ClaudeCodeConnection(channel: channel)
        self.connection = connection
        await connection.start()
        let events = connection.events
        reader = Task { [weak self] in
            for await event in events {
                self?.receive(event)
            }
            self?.ended()
        }
        do {
            _ = try await connection.request({ ClaudeOutbound.initialize(id: $0) }, timeout: .seconds(60))
            if state == .starting { state = .idle }
        } catch {
            state = .ended("could not start: \(error)")
        }
    }

    // MARK: - From the user

    /// Sends a message; while a turn runs it queues behind it, as in the terminal.
    public func send(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let connection, !isEnded else { return }
        items.append(.user(id: UUID(), text: text))
        pendingTurns += 1
        state = .working
        if title == folder.lastPathComponent { title = String(text.prefix(40)) }
        Task {
            do {
                try await connection.send(ClaudeOutbound.userMessage(text))
            } catch {
                self.note("not sent: the session has ended")
            }
        }
    }

    /// Stops the running turn; messages queued behind it run next.
    public func interrupt() {
        guard let connection, state == .working else { return }
        Task { _ = try? await connection.request({ ClaudeOutbound.interrupt(id: $0) }, timeout: .seconds(10)) }
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
    }

    // MARK: - From the agent

    func receive(_ event: ClaudeInbound) {
        switch event {
        case .sessionStarted(let info, _):
            sessionID = info.sessionID
            model = info.model
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
        case .toolResults(let results, _):
            for result in results {
                guard let index = items.firstIndex(where: { $0.id == "tool-" + result.toolUseID }),
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
            guard result.turns > 0 || pendingTurns == 0 else { return }
            pendingTurns = max(0, pendingTurns - 1)
            if result.isError, !result.result.isEmpty { note(result.result) }
            if pendingTurns == 0, !isEnded {
                state = .idle
                onTurnFinished?(lastAnswer)
            }
        case .request(let request):
            if let permission = request.permission {
                let ask = ChatAsk(requestID: request.requestID, ask: permission)
                asks.append(ask)
                onAsk?(ask)
            }
        case .cancelled(let requestID, _):
            asks.removeAll { $0.requestID == requestID }
        case .response, .rateLimit, .system, .other:
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

    private func note(_ text: String) {
        items.append(.note(id: UUID(), text: text))
    }

    private func ended() {
        finishStreaming(with: nil)
        asks.removeAll()
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
