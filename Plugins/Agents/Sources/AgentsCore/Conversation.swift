import Foundation
import Observation
import UDeckAgents

/// Who answers in a conversation.
public enum Provider: String, Sendable, CaseIterable {
    case claude, codex

    public var name: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        }
    }
}

/// One agent's session, whichever provider runs it: what the card and the
/// conversation need of it, read the same way for both.
@MainActor
public enum Agent {
    case claude(ChatSession)
    case codex(CodexSession)

    public var provider: Provider {
        switch self {
        case .claude: .claude
        case .codex: .codex
        }
    }

    public var title: String {
        switch self {
        case .claude(let session): session.title
        case .codex(let session): session.title
        }
    }

    public var titleSource: NameSource {
        switch self {
        case .claude(let session): session.titleSource
        case .codex(let session): session.titleSource
        }
    }

    /// Calls the session `text`, unless its name came from a stronger source.
    @discardableResult
    public func name(_ text: String, from source: NameSource) -> Bool {
        switch self {
        case .claude(let session): session.name(text, from: source)
        case .codex(let session): session.name(text, from: source)
        }
    }

    /// The session's key among the names this plugin keeps: its Claude
    /// session id or its Codex thread, once it has one.
    public var nameKey: String? {
        switch self {
        case .claude(let session): session.sessionID.map { ChatNames.key(.claude, $0) }
        case .codex(let session): session.threadID.map { ChatNames.key(.codex, $0) }
        }
    }

    public var items: [FeedItem] {
        switch self {
        case .claude(let session): session.items
        case .codex(let session): session.items
        }
    }

    public var state: ChatSession.State {
        switch self {
        case .claude(let session): session.state
        case .codex(let session): session.state
        }
    }

    public var isEnded: Bool { if case .ended = state { true } else { false } }

    public var waiting: Int {
        switch self {
        case .claude(let session): session.asks.count
        case .codex(let session): session.asks.count
        }
    }

    public var queued: [UUID] {
        switch self {
        case .claude(let session): session.queued
        case .codex(let session): session.queued
        }
    }

    public var turnStartedAt: Date? {
        switch self {
        case .claude(let session): session.turnStartedAt
        case .codex(let session): session.turnStartedAt
        }
    }

    public var models: [ModelChoice] {
        switch self {
        case .claude(let session): session.models.filter { $0.value != "default" }
        case .codex(let session): session.models
        }
    }

    public var effort: String? {
        switch self {
        case .claude(let session): session.effort
        case .codex(let session): session.effort
        }
    }

    public var contextPercent: Double? {
        switch self {
        case .claude(let session): session.context.map { max(0, min(100, $0.percent)) }
        case .codex(let session): session.contextPercent
        }
    }

    /// The model the session runs with, among those it offers.
    public var currentModel: ModelChoice? {
        switch self {
        case .claude(let session):
            let models = self.models
            if let chosen = session.chosenModel { return models.first { $0.value == chosen } }
            guard let model = session.model else { return nil }
            return models.first { $0.resolved == model || model.hasPrefix($0.resolved ?? "\u{0}") }
        case .codex(let session):
            let wanted = session.chosenModel ?? session.model
            return session.models.first { $0.value == wanted || $0.resolved == wanted }
        }
    }

    /// The model's name, even when it is not among those offered.
    public var modelName: String? {
        if let current = currentModel { return current.name }
        switch self {
        case .claude(let session): return session.chosenModel ?? session.model.map(AgentsCard.prettyModel)
        case .codex(let session): return session.chosenModel ?? session.model
        }
    }

    public var lastAnswer: String {
        switch self {
        case .claude(let session): session.lastAnswer
        case .codex(let session): session.lastAnswer
        }
    }

    public var folder: URL {
        switch self {
        case .claude(let session): session.folder
        case .codex(let session): session.folder
        }
    }

    /// Sends a message: `shown` into the feed, `text` to the agent.
    public func send(_ shown: String, text: String? = nil) {
        switch self {
        case .claude(let session): session.send(shown, payload: text)
        case .codex(let session): session.send(shown, text: text)
        }
    }

    public func interrupt() {
        switch self {
        case .claude(let session): session.interrupt()
        case .codex(let session): session.interrupt()
        }
    }

    public func close() async {
        switch self {
        case .claude(let session): await session.close()
        case .codex(let session): await session.close()
        }
    }

    func note(_ text: String) {
        switch self {
        case .claude(let session): session.note(text)
        case .codex(let session): session.note(text)
        }
    }
}

/// What the card shows as one session: one feed over the agents that have
/// answered in it — Claude, Codex, or both in turn. Each provider keeps its
/// own native session, continued by its own id; switching hands the new one
/// what was said and done since it last took part, with the next message,
/// so a switch costs no turn of its own.
@MainActor
@Observable
public final class Conversation: Identifiable {
    public struct Handoff: Sendable, Equatable {
        public let to: Provider
        public let model: String
        public let messages: Int
        public let actions: Int
        public let tokens: Int
    }

    /// A stretch of the feed one provider answered, from `start` in its own
    /// items, up to `end` when another took over.
    struct Segment {
        let provider: Provider
        let start: Int
        var end: Int?
        let handoff: Handoff?
        let noteID = UUID()
    }

    public let id = UUID()
    public let folder: URL
    public private(set) var agents: [Provider: Agent] = [:]
    public private(set) var active: Provider
    private(set) var segments: [Segment]
    /// What the provider is handed with its next message, after a switch.
    @ObservationIgnored private var preamble: [Provider: String] = [:]

    public init(_ agent: Agent) {
        folder = agent.folder
        active = agent.provider
        segments = [Segment(provider: agent.provider, start: 0, end: nil, handoff: nil)]
        agents[agent.provider] = agent
    }

    public var current: Agent { agents[active]! }
    public var title: String { agents[segments[0].provider]?.title ?? current.title }
    /// The agent the conversation began with: its name is the conversation's.
    public var first: Agent { agents[segments[0].provider] ?? current }
    public var providers: Set<Provider> { Set(agents.keys) }

    public var claude: ChatSession? { if case .claude(let session)? = agents[.claude] { session } else { nil } }
    public var codex: CodexSession? { if case .codex(let session)? = agents[.codex] { session } else { nil } }

    /// The feed: each stretch's items, a note where one provider handed over
    /// to another, and — once more than one has answered — who said what.
    public var feed: [(item: FeedItem, label: String?)] {
        let several = agents.count > 1
        var out: [(FeedItem, String?)] = []
        for segment in segments {
            if let handoff = segment.handoff {
                out.append((.note(id: segment.noteID, text: Self.noteText(handoff)), nil))
            }
            guard let items = agents[segment.provider]?.items else { continue }
            let end = min(segment.end ?? items.count, items.count)
            guard segment.start < end else { continue }
            let queued = Set(agents[segment.provider]?.queued ?? [])
            for item in items[segment.start..<end] {
                switch item {
                case .assistant where several: out.append((item, segment.provider.name))
                case .user(let id, _) where queued.contains(id): out.append((item, Self.queuedLabel))
                default: out.append((item, nil))
                }
            }
        }
        return out
    }

    /// The label of a message waiting behind the running turn, for the card
    /// to put in words.
    static let queuedLabel = "\u{0}queued"

    /// The handoff note's text, for the card to put in words.
    static func noteText(_ handoff: Handoff) -> String {
        "handoff:\(handoff.to.rawValue)|\(handoff.model)|\(handoff.messages)|\(handoff.actions)|\(handoff.tokens)"
    }

    /// `provider` answers from now on: `agent` when it has none here yet.
    /// What was said and done since it last took part is handed to it with
    /// the next message.
    public func switchTo(_ provider: Provider, agent: Agent?, model: String) {
        guard provider != active else { return }
        if let agent, agents[provider] == nil { agents[provider] = agent }
        guard let target = agents[provider] else { return }
        segments[segments.count - 1].end = current.items.count
        let gap = Self.gap(since: lastIndex(of: provider), in: segments, agents: agents)
        preamble[provider] = gap.text
        segments.append(Segment(provider: provider, start: target.items.count, end: nil,
                                handoff: Handoff(to: provider, model: model, messages: gap.messages,
                                                 actions: gap.actions, tokens: gap.text.count / 4)))
        active = provider
    }

    private func lastIndex(of provider: Provider) -> Int? {
        segments.lastIndex { $0.provider == provider }
    }

    /// The person's next message, with what the provider was handed.
    public func send(_ text: String) {
        let handed = preamble.removeValue(forKey: active)
        current.send(text, text: handed.map { $0 + "\n\n" + text })
    }

    /// What happened in the segments after `since` — the provider's last
    /// stretch, or all of them for one new here — as text for it to read:
    /// the person's words, the answers, the operations in one line each.
    static func gap(since: Int?, in segments: [Segment], agents: [Provider: Agent], limit: Int = 16_000)
        -> (text: String, messages: Int, actions: Int)
    {
        var lines: [String] = []
        var messages = 0, actions = 0
        for segment in segments[((since ?? -1) + 1)...] {
            guard let items = agents[segment.provider]?.items else { continue }
            let end = min(segment.end ?? items.count, items.count)
            guard segment.start < end else { continue }
            for item in items[segment.start..<end] {
                switch item {
                case .user(_, let text):
                    messages += 1
                    lines.append("Person: " + text)
                case .assistant(_, let text, _):
                    messages += 1
                    lines.append(segment.provider.name + ": " + text)
                case .tool(_, let name, let summary, let result):
                    actions += 1
                    lines.append("(\(segment.provider.name) ran \(name)\(summary.isEmpty ? "" : " " + summary)"
                                 + "\(result?.isError == true ? " — it failed" : ""))")
                case .note:
                    continue
                }
            }
        }
        var body = lines.joined(separator: "\n")
        if body.count > limit { body = "…" + String(body.suffix(limit)) }
        let text = "[This conversation was carried on with another assistant. What was said and done since you "
            + "last took part — read it and continue from it:]\n" + body + "\n[End of what happened meanwhile.]"
        return (text, messages, actions)
    }
}
