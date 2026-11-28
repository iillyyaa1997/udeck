import Foundation
import UDeckAgents

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
    /// The model the last answer came from, as the transcript says.
    public private(set) var model: String?
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

extension ContextTrack {
    /// The track as the session's transcript tells it, its last `tail` bytes:
    /// each answer's tokens and time, the tools called, where the person spoke
    /// (a turn's end before it) and the compactions — so that a session
    /// continued after Agents started again shows its line, its turns, what
    /// took the most and its cache at once, not after turns of its own (the
    /// operator, 11-28: the details empty after an update).
    public static func rebuilt(from file: URL, tail: Int = 6_000_000) -> ContextTrack {
        var track = ContextTrack()
        guard let handle = try? FileHandle(forReadingFrom: file) else { return track }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(tail) ? size - UInt64(tail) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return track }
        var lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        if start > 0, !lines.isEmpty { lines.removeFirst() }
        let dates = ISO8601DateFormatter()
        dates.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var spoke = false
        for line in lines {
            guard let entry = JSONValue.line(Substring(decoding: line, as: UTF8.self)) else { continue }
            let at = entry["timestamp"]?.string.flatMap(dates.date(from:)) ?? Date()
            switch entry["type"]?.string {
            case "user" where entry["isSidechain"]?.bool != true:
                // The person's words, not a tool's result: the turn before it ended.
                let content = entry["message"]?["content"]
                let said = content?.string != nil
                    || (content?.array ?? []).contains { $0["type"]?.string == "text" }
                if said, entry["isMeta"]?.bool != true, entry["isCompactSummary"]?.bool != true {
                    if spoke { track.turnEnded(at: at, costUSD: nil, durationMs: nil, apiMs: nil) }
                    spoke = true
                }
            case "assistant" where entry["isSidechain"]?.bool != true:
                let message = entry["message"] ?? .null
                if let model = message["model"]?.string, !model.isEmpty, !model.hasPrefix("<") { track.model = model }
                if let usage = message["usage"].flatMap(ClaudeCallUsage.init), usage.prompt > 0 {
                    track.compactionLeft(usage.prompt, at: at)
                    track.call(usage, at: at)
                }
                for block in message["content"]?.array ?? [] where block["type"]?.string == "tool_use" {
                    let name = block["name"]?.string ?? ""
                    let summary = ToolSummary.of(name: name, input: block["input"] ?? .null)
                    track.tool(id: "tool-" + (block["id"]?.string ?? ""), label: summary.isEmpty ? name : name + " " + summary)
                }
            case "system" where entry["subtype"]?.string == "compact_boundary":
                track.compacted(at: at, from: entry["compactMetadata"]?["preTokens"]?.int)
            default:
                break
            }
        }
        return track
    }

    /// The first call after a compaction says what it left.
    mutating func compactionLeft(_ tokens: Int, at date: Date) {
        guard let last = compactions.indices.last, compactions[last].toTokens == nil else { return }
        measured(tokens, at: date)
    }

    /// Whether anything is known yet.
    public var isEmpty: Bool { tokens == nil && points.isEmpty && compactions.isEmpty }
}
