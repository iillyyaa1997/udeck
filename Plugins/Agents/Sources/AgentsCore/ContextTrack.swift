import Foundation

/// What Agents keeps of a session's context as it goes (the operator's
/// builder, 11-28): how full it is now, how it grew turn by turn, what in it
/// took the most, how long the cache stays warm, what each compaction left.
///
/// Every call's answer says the size of the prompt it was given — the
/// context, live, not only at a turn's end (claude 2.1.332, measured 11-27).
/// What a tool's result added is the prompt's growth from one call to the
/// next, less the answer in between, shared among the tools called there.
public struct ContextTrack: Sendable, Equatable {
    public struct Point: Sendable, Equatable {
        public let at: Date
        public let tokens: Int
        /// A compaction ended here: the line drops.
        public let compacted: Bool
    }

    /// Something that went into the context: a tool's result, and what it
    /// added — with the id of its entry in the feed.
    public struct Piece: Sendable, Equatable {
        public let id: String
        public let label: String
        public var tokens: Int
    }

    public struct Compaction: Sendable, Equatable {
        public let at: Date
        public let fromTokens: Int?
        public var toTokens: Int?
        /// What the CLI put in the conversation's place.
        public var summary: String?
    }

    /// How full the context is now, after the last call: its prompt and its answer.
    public private(set) var tokens: Int?
    public private(set) var lastCall: Date?
    public private(set) var cacheLife: TimeInterval = 3600
    public private(set) var points: [Point] = []
    /// What each turn added, the newest last.
    public private(set) var growth: [Int] = []
    /// What took the most, most first.
    public private(set) var heavy: [Piece] = []
    public private(set) var compactions: [Compaction] = []
    public private(set) var costUSD: Double?
    public private(set) var wallMs = 0
    public private(set) var apiMs = 0

    private struct Called: Sendable, Equatable { let id: String; let label: String }
    private var pending: [Called] = []
    private var lastPrompt: Int?
    private var lastOutput = 0
    private var turnStart: Int?

    public static let keptPoints = 240
    public static let keptPieces = 5

    public init() {}

    /// A call answered: its prompt is the context; what grew since the last
    /// call is the tools' in between.
    public mutating func call(_ usage: ClaudeCallUsage, at date: Date) {
        if let lastPrompt, !pending.isEmpty {
            let added = usage.prompt - lastPrompt - lastOutput
            if added > 0 {
                let share = added / pending.count
                for tool in pending { note(id: tool.id, label: tool.label, tokens: share) }
            }
        }
        pending.removeAll()
        lastPrompt = usage.prompt
        lastOutput = usage.output
        tokens = usage.prompt + usage.output
        if turnStart == nil { turnStart = usage.prompt }
        lastCall = date
        if let life = usage.cacheLife { cacheLife = life }
    }

    /// A tool was called: its result goes into the next call's prompt.
    public mutating func tool(id: String, label: String) {
        pending.append(Called(id: id, label: label))
    }

    private mutating func note(id: String, label: String, tokens: Int) {
        if let index = heavy.firstIndex(where: { $0.id == id }) {
            heavy[index].tokens += tokens
        } else {
            heavy.append(Piece(id: id, label: label, tokens: tokens))
        }
        heavy.sort { $0.tokens > $1.tokens }
        if heavy.count > Self.keptPieces { heavy.removeLast(heavy.count - Self.keptPieces) }
    }

    /// A turn ended: a point of the line, what it added, its cost and time.
    public mutating func turnEnded(at date: Date, costUSD: Double?, durationMs: Int?, apiMs: Int?) {
        if let tokens {
            points.append(Point(at: date, tokens: tokens, compacted: false))
            if let turnStart, tokens > turnStart { growth.append(tokens - turnStart) }
            turnStart = tokens
        }
        if points.count > Self.keptPoints { points.removeFirst(points.count - Self.keptPoints) }
        if growth.count > 20 { growth.removeFirst(growth.count - 20) }
        if let costUSD { self.costUSD = costUSD }
        wallMs += durationMs ?? 0
        self.apiMs += apiMs ?? 0
    }

    /// The conversation was compacted: what it was before.
    public mutating func compacted(at date: Date, from: Int?) {
        compactions.append(Compaction(at: date, fromTokens: from ?? tokens, toTokens: nil, summary: nil))
        heavy.removeAll()
        pending.removeAll()
        lastPrompt = nil
        turnStart = nil
    }

    /// What the CLI put in its place.
    public mutating func summary(_ text: String) {
        guard !compactions.isEmpty else { return }
        compactions[compactions.count - 1].summary = text
    }

    /// How full the context is, as the CLI measured it when asked: after a
    /// compaction, the first word of what it left.
    public mutating func measured(_ measured: Int, at date: Date) {
        if let last = compactions.indices.last, compactions[last].toTokens == nil {
            compactions[last].toTokens = measured
            points.append(Point(at: date, tokens: measured, compacted: true))
            tokens = measured
            turnStart = measured
        } else if tokens == nil {
            tokens = measured
        }
    }

    /// What a turn adds, lately: the mean of the last eight.
    public var turnGrowth: Int? {
        let recent = growth.suffix(8)
        guard !recent.isEmpty else { return nil }
        return recent.reduce(0, +) / recent.count
    }

    /// When the cache goes cold, if it is warm.
    public func cacheCold(now: Date = Date()) -> Date? {
        guard let lastCall else { return nil }
        let cold = lastCall.addingTimeInterval(cacheLife)
        return cold > now ? cold : nil
    }
}
