import Foundation
import Observation
import UDeckAgents

/// A Codex thread saved by the CLI, to continue from the session menu.
public struct CodexSaved: Sendable, Equatable {
    public let id: String
    public let title: String
    public let cwd: String?
    public let updated: Date

    static func list(_ result: JSONValue) -> [CodexSaved] {
        (result["data"]?.array ?? []).compactMap { raw in
            guard let id = raw["id"]?.string, raw["ephemeral"]?.bool != true else { return nil }
            let preview = raw["preview"]?.string ?? ""
            let title = raw["name"]?.string ?? preview.split(separator: "\n").first.map(String.init) ?? id
            return CodexSaved(id: id, title: String(title.prefix(80)), cwd: raw["cwd"]?.string,
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
    /// Messages sent while a turn ran, oldest first, with what Codex is to
    /// be told: each starts a turn when the one before it is done.
    public private(set) var queued: [UUID] = []
    @ObservationIgnored private var waiting: [(id: UUID, text: String)] = []

    @ObservationIgnored public var onAsk: ((CodexAsk) -> Void)?
    @ObservationIgnored public var onTurnFinished: ((String) -> Void)?

    @ObservationIgnored private var connection: CodexConnection?
    @ObservationIgnored private var reader: Task<Void, Never>?
    @ObservationIgnored private var turnID: String?
    /// The feed index of each agent message still arriving, by item id.
    @ObservationIgnored private var streaming: [String: Int] = [:]

    public init(folder: URL, title: String? = nil, threadID: String? = nil) {
        self.folder = folder
        self.title = title ?? folder.lastPathComponent
        self.threadID = threadID
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
    public func send(_ shown: String, text: String? = nil) {
        let shown = shown.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !shown.isEmpty, let connection, let threadID, !isEnded else { return }
        let id = UUID()
        items.append(.user(id: id, text: shown))
        if title == folder.lastPathComponent { title = String(shown.prefix(40)) }
        if state == .working {
            queued.append(id)
            waiting.append((id, text ?? shown))
            return
        }
        startTurn(text ?? shown, connection: connection, threadID: threadID)
    }

    private func startTurn(_ text: String, connection: CodexConnection, threadID: String) {
        state = .working
        if turnStartedAt == nil { turnStartedAt = Date() }
        var params: [String: JSONValue] = [
            "threadId": .string(threadID),
            "input": [["type": "text", "text": .string(text)]],
        ]
        if let chosenModel { params["model"] = .string(chosenModel) }
        if let effort { params["effort"] = .string(effort) }
        Task {
            do {
                let result = try await connection.request("turn/start", .object(params))
                if let id = result["turn"]?["id"]?.string { turnID = id }
            } catch {
                note("not sent: \(error)")
                if state == .working, asks.isEmpty { state = .idle; turnStartedAt = nil }
            }
        }
    }

    public func interrupt() {
        guard let connection, let threadID, let turnID, state == .working else { return }
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
            onAsk?(ask)
            return
        }
        guard case .notification(let method, let params) = event else { return }
        switch method {
        case "turn/started":
            turnID = params["turn"]?["id"]?.string ?? turnID
        case "item/agentMessage/delta":
            guard let itemID = params["itemId"]?.string, let delta = params["delta"]?.string else { return }
            if let index = streaming[itemID], case .assistant(let id, let text, _) = items[index] {
                items[index] = .assistant(id: id, text: text + delta, streaming: true)
            } else {
                items.append(.assistant(id: UUID(), text: delta, streaming: true))
                streaming[itemID] = items.count - 1
            }
        case "item/started":
            let item = params["item"] ?? .null
            if let tool = Self.tool(item) { items.append(.tool(id: tool.id, name: tool.name, summary: tool.summary, result: nil)) }
        case "item/completed":
            complete(params["item"] ?? .null)
        case "turn/completed":
            for (_, index) in streaming {
                if case .assistant(let id, let text, _) = items[index] { items[index] = .assistant(id: id, text: text, streaming: false) }
            }
            streaming.removeAll()
            turnID = nil
            if let error = params["turn"]?["error"]?["message"]?.string, !error.isEmpty { note(error) }
            if !isEnded {
                if !waiting.isEmpty, let connection, let threadID {
                    let next = waiting.removeFirst()
                    queued.removeAll { $0 == next.id }
                    turnStartedAt = nil
                    startTurn(next.text, connection: connection, threadID: threadID)
                    return
                }
                state = .idle
                turnStartedAt = nil
                onTurnFinished?(lastAnswer)
            }
        case "thread/tokenUsage/updated":
            let usage = params["tokenUsage"] ?? .null
            if let window = usage["modelContextWindow"]?.int, window > 0 {
                context = (usage["last"]?["totalTokens"]?.int ?? 0, window)
            }
        case "account/rateLimits/updated":
            rateLimits = CodexRateLimits(params["rateLimits"] ?? .null)
        case "serverRequest/resolved":
            if let id = params["requestId"] { asks.removeAll { $0.requestID == Self.key(id) } }
        case "error":
            if let message = params["error"]?["message"]?.string ?? params["message"]?.string { note(message) }
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
        if !isEnded { state = .ended("the session ended") }
    }
}
