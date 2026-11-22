import Foundation
import Testing
@testable import UDeckAgentHost
import UDeckAgents

@Suite("The helper's event journal")
struct EventJournalTests {
    @Test("events are numbered from 1 without gaps, and 'after' returns exactly what follows")
    func numbering() {
        var journal = EventJournal()
        for index in 1...5 { _ = journal.append(session: "s", .line("line \(index)")) }
        #expect(journal.lastSeq == 5)
        #expect(journal.firstSeq == 1)
        let (events, gap) = journal.after(3)
        #expect(!gap)
        #expect(events.map(\.seq) == [4, 5])
        #expect(journal.after(5).events.isEmpty)
        #expect(journal.after(0).events.count == 5)
    }

    @Test("bounded by count: the oldest go, and a reader from before them is told of the gap")
    func boundedByCount() {
        var journal = EventJournal(maxEvents: 3)
        for index in 1...10 { _ = journal.append(session: "s", .line("\(index)")) }
        #expect(journal.count == 3)
        #expect(journal.firstSeq == 8)
        let (events, gap) = journal.after(2)
        #expect(gap)
        #expect(events.map(\.seq) == [8, 9, 10])
        let (later, laterGap) = journal.after(8)
        #expect(!laterGap)
        #expect(later.map(\.seq) == [9, 10])
    }

    @Test("bounded by size, yet the newest event is kept however large it is")
    func boundedBySize() {
        var journal = EventJournal(maxEvents: 1000, maxBytes: 1000)
        for _ in 1...10 { _ = journal.append(session: "s", .line(String(repeating: "x", count: 300))) }
        #expect(journal.count == 2) // 2 × (300 + 64) fits in 1000, 3 do not
        _ = journal.append(session: "s", .line(String(repeating: "y", count: 5000)))
        #expect(journal.count == 1)
        #expect(journal.firstSeq == 11)
    }

    @Test("what falls off the front is freed at once, not at the next compaction")
    func droppedTextIsFreed() {
        var journal = EventJournal(maxEvents: 100_000, maxBytes: 1024 * 1024)
        for _ in 1...100 { _ = journal.append(session: "s", .line(String(repeating: "z", count: 256 * 1024))) }
        // 100 × 256 KB went in; about 1 MB may stay.
        #expect(journal.retainedBytes <= 1024 * 1024 + 64 * 1024)
    }

    @Test("a reader ahead of the journal (it knew another run of the helper) gets everything, flagged")
    func readerAhead() {
        var journal = EventJournal()
        _ = journal.append(session: "s", .line("a"))
        let (events, gap) = journal.after(40)
        #expect(gap)
        #expect(events.map(\.seq) == [1])
    }

    @Test("compaction after many drops keeps the numbering and the contents")
    func compaction() {
        var journal = EventJournal(maxEvents: 10)
        for index in 1...20000 { _ = journal.append(session: "s", .line("\(index)")) }
        #expect(journal.firstSeq == 19991)
        #expect(journal.after(19995).events.map(\.seq) == Array(19996...20000))
        if case .line(let text) = journal.after(19999).events.first?.kind { #expect(text == "20000") }
    }

    @Test("every kind of event survives the wire")
    func wire() {
        let at = Date(timeIntervalSince1970: 1_795_300_000.5)
        let kinds: [HostEvent.Kind] = [.started(pid: 4242), .line("{\"type\":\"x\"} ё"), .overlong(bytes: 99),
                                       .input(tag: "msg-1"), .exited(status: 143, stderrTail: "bye\n")]
        for (index, kind) in kinds.enumerated() {
            let event = HostEvent(session: "abc", seq: index + 1, at: at, kind: kind)
            let line = try! event.wire.encodedLine()
            let back = HostEvent(wire: JSONValue.line(Substring(line))!)
            #expect(back == event)
        }
    }
}
