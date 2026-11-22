import Foundation
import UDeckAgents

/// Something that happened to one agent, as the helper journals it.
///
/// Every session numbers its events from 1, without gaps, for its whole life
/// in the helper — across restarts of the agent under the same session id too —
/// so uDeck, reconnecting, asks for "everything after 412" and gets exactly
/// what it missed.
public struct HostEvent: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// The agent was started (or started again, under the same session).
        case started(pid: Int32)
        /// One line the agent wrote on stdout.
        case line(String)
        /// A line went past the framer's limit and was thrown away.
        case overlong(bytes: Int)
        /// uDeck wrote a line to the agent. Only its tag is kept, not the text:
        /// it is how uDeck, after a crash, tells a message that reached the
        /// agent from one that may not have.
        case input(tag: String)
        /// The agent exited.
        case exited(status: Int32, stderrTail: String)

        public var isExit: Bool { if case .exited = self { true } else { false } }
        public var isStart: Bool { if case .started = self { true } else { false } }
    }

    public let session: String
    public let seq: Int
    /// When the helper saw it, to the millisecond.
    public let at: Date
    public let kind: Kind

    public init(session: String, seq: Int, at: Date, kind: Kind) {
        self.session = session
        self.seq = seq
        self.at = at
        self.kind = kind
    }

    /// Roughly what keeping the event costs, for the journal's bound.
    var weight: Int {
        switch kind {
        case .line(let text): return text.utf8.count + 64
        case .input(let tag): return tag.utf8.count + 64
        case .exited(_, let tail): return tail.utf8.count + 64
        case .started, .overlong: return 64
        }
    }
}

extension HostEvent {
    var wire: JSONValue {
        var fields: [String: JSONValue] = [
            "session": .string(session),
            "seq": .number(Double(seq)),
            "t": .number((at.timeIntervalSince1970 * 1000).rounded()),
        ]
        switch kind {
        case .started(let pid):
            fields["ev"] = "started"
            fields["pid"] = .number(Double(pid))
        case .line(let text):
            fields["ev"] = "line"
            fields["line"] = .string(text)
        case .overlong(let bytes):
            fields["ev"] = "overlong"
            fields["bytes"] = .number(Double(bytes))
        case .input(let tag):
            fields["ev"] = "input"
            fields["tag"] = .string(tag)
        case .exited(let status, let tail):
            fields["ev"] = "exited"
            fields["status"] = .number(Double(status))
            fields["stderrTail"] = .string(tail)
        }
        return .object(fields)
    }

    init?(wire value: JSONValue) {
        guard let session = value["session"]?.string, let seq = value["seq"]?.int,
              let millis = value["t"]?.number
        else { return nil }
        let kind: Kind
        switch value["ev"]?.string {
        case "started":
            guard let pid = value["pid"]?.int else { return nil }
            kind = .started(pid: Int32(pid))
        case "line":
            guard let text = value["line"]?.string else { return nil }
            kind = .line(text)
        case "overlong":
            kind = .overlong(bytes: value["bytes"]?.int ?? 0)
        case "input":
            guard let tag = value["tag"]?.string else { return nil }
            kind = .input(tag: tag)
        case "exited":
            kind = .exited(status: Int32(value["status"]?.int ?? -1), stderrTail: value["stderrTail"]?.string ?? "")
        default:
            return nil
        }
        self.init(session: session, seq: seq, at: Date(timeIntervalSince1970: millis / 1000), kind: kind)
    }
}

/// A session's events, newest last, bounded in count and in size: an agent
/// that runs for days must not grow the helper without limit. What falls off
/// the front is gone from the helper — the agent's own transcript still has
/// the conversation — and a reader asking for it is told there is a gap.
public struct EventJournal: Sendable {
    public let maxEvents: Int
    public let maxBytes: Int
    private var events: [HostEvent] = []
    /// Index of the oldest kept event in `events`; the array is compacted now
    /// and then instead of shifting it on every drop.
    private var head = 0
    private var bytes = 0
    public private(set) var lastSeq = 0

    public init(maxEvents: Int = 100_000, maxBytes: Int = 64 * 1024 * 1024) {
        self.maxEvents = maxEvents
        self.maxBytes = maxBytes
    }

    public var count: Int { events.count - head }

    /// What the array really holds, dropped slots included: the bound is
    /// about memory, not about what `after` returns.
    var retainedBytes: Int { events.reduce(0) { $0 + $1.weight } - (head * 64) }

    /// The oldest event still kept; `lastSeq + 1` when there is none.
    public var firstSeq: Int { head < events.count ? events[head].seq : lastSeq + 1 }

    public mutating func append(session: String, at: Date = Date(), _ kind: HostEvent.Kind) -> HostEvent {
        lastSeq += 1
        let event = HostEvent(session: session, seq: lastSeq, at: at, kind: kind)
        events.append(event)
        bytes += event.weight
        // Always keep the newest event, however large. A dropped event's slot
        // is emptied at once, so its text is freed now and not at the next
        // compaction.
        while count > 1, count > maxEvents || bytes > maxBytes {
            bytes -= events[head].weight
            events[head] = HostEvent(session: "", seq: events[head].seq, at: events[head].at, kind: .overlong(bytes: 0))
            head += 1
        }
        if head > 4096, head * 2 > events.count {
            events.removeFirst(head)
            head = 0
        }
        return event
    }

    /// Everything after `seq`. `gap` is true when some of it is no longer kept
    /// (what is returned then starts at `firstSeq`).
    public func after(_ seq: Int) -> (events: ArraySlice<HostEvent>, gap: Bool) {
        let first = firstSeq
        // Asking from before the oldest kept event, or from past the newest
        // (a reader that knew another run of the helper): all that is kept.
        if seq + 1 < first || seq > lastSeq { return (events[head...], true) }
        let offset = max(0, seq + 1 - first)
        let start = min(events.count, head + offset)
        return (events[start...], false)
    }
}
