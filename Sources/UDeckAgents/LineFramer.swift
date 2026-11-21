import Foundation

/// Cuts a byte stream into lines, the framing both agents use on stdio.
///
/// A pipe hands over whatever the kernel had, so one read can end in the middle
/// of a line — or in the middle of a multi-byte character inside it. The framer
/// keeps the tail until its newline arrives and decodes only whole lines, so a
/// Cyrillic letter split across two reads is never turned into two replacement
/// characters.
///
/// A line longer than `limit` is dropped whole and reported, rather than kept
/// growing: an agent that prints a 2 GB line has failed, and uDeck should say
/// so instead of running out of memory reading it. The default is far above the
/// largest real message measured (a long transcript resume, a few megabytes).
public struct LineFramer: Sendable {
    public enum Piece: Sendable, Equatable {
        case line(String)
        /// A line went past the limit and was thrown away; `bytes` is how much of
        /// it was seen before the next newline.
        case overlong(bytes: Int)
    }

    public let limit: Int
    private var pending = Data()
    private var discarding = false
    private var discarded = 0

    public init(limit: Int = 64 * 1024 * 1024) {
        self.limit = limit
    }

    /// Feeds one chunk; returns every line it completed, in order.
    public mutating func feed(_ chunk: Data) -> [Piece] {
        var pieces: [Piece] = []
        var start = chunk.startIndex
        while let newline = chunk[start...].firstIndex(of: 0x0A) {
            let part = chunk[start..<newline]
            if discarding {
                pieces.append(.overlong(bytes: discarded + part.count))
                discarding = false
                discarded = 0
            } else if pending.count + part.count > limit {
                pieces.append(.overlong(bytes: pending.count + part.count))
                pending.removeAll(keepingCapacity: false)
            } else {
                pending.append(part)
                pieces.append(.line(Self.text(pending)))
                pending.removeAll(keepingCapacity: true)
            }
            start = chunk.index(after: newline)
        }
        let rest = chunk[start...]
        if discarding {
            discarded += rest.count
        } else if pending.count + rest.count > limit {
            discarding = true
            discarded = pending.count + rest.count
            pending.removeAll(keepingCapacity: false)
        } else {
            pending.append(rest)
        }
        return pieces
    }

    /// The stream ended: a last line without a newline still counts.
    public mutating func finish() -> [Piece] {
        defer {
            pending.removeAll()
            discarding = false
            discarded = 0
        }
        if discarding { return [.overlong(bytes: discarded)] }
        if pending.isEmpty { return [] }
        return [.line(Self.text(pending))]
    }

    private static func text(_ data: Data) -> String {
        var bytes = data
        if bytes.last == 0x0D { bytes.removeLast() }
        return String(decoding: bytes, as: UTF8.self)
    }
}
