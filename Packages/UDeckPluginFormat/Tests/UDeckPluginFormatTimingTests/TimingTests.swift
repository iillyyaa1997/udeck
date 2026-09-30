import Foundation
import Testing
@testable import UDeckPluginFormat

/// How long reading takes, as a function of how much there is to read.
///
/// A target of its own, which uDeck's top-level `swift test` does not build:
/// these tests keep every core busy for seconds, and uDeck's own tests include
/// one that measures the whole process's CPU time while a plugin sleeps — run
/// side by side, the one reads the other's work as its own. CI runs them in a
/// step of their own, on the Mac and on Linux.
@Suite("Time in proportion to the text")
struct TimingTests {

    /// An object of `count` fields, `{"k0000000":0,…}`, and a list of `count`
    /// numbers: 13 bytes a field, 2 an item.
    static func object(_ count: Int) -> [UInt8] {
        var bytes: [UInt8] = [UInt8(ascii: "{")]
        bytes.reserveCapacity(count * 13 + 2)
        for index in 0 ..< count {
            if index > 0 { bytes.append(UInt8(ascii: ",")) }
            let digits = String(index)
            bytes += Array(("\"k" + String(repeating: "0", count: 7 - digits.count) + digits + "\":0").utf8)
        }
        return bytes + [UInt8(ascii: "}")]
    }

    static func list(_ count: Int) -> [UInt8] {
        Array(("[" + Array(repeating: "0", count: count).joined(separator: ",") + "]").utf8)
    }

    /// The fastest of `runs` readings, in seconds — the least disturbed by
    /// whatever else the machine was doing.
    static func fastest(_ runs: Int, _ work: () -> Void) -> Double {
        let clock = ContinuousClock()
        var best = Duration.seconds(1_000_000)
        for _ in 0 ..< runs {
            let start = clock.now
            work()
            best = min(best, clock.now - start)
        }
        return Double(best.components.seconds) + Double(best.components.attoseconds) / 1e18
    }

    /// A container used to be copied whole every time a value was added to
    /// it, and a passport of 256,000 fields took over two minutes to read.
    /// Four times the text now takes about four times as long — and the
    /// 256,000 fields, 3.4 MB, take seconds even in a debug build on a busy
    /// machine; a minute is the limit, half of what the old reader took when
    /// it was built for speed.
    @Test("reading takes time in proportion to the text, not to its square")
    func linear() {
        for (what, make) in [("an object", Self.object), ("a list", Self.list)] as [(String, (Int) -> [UInt8])] {
            let small = make(64_000)
            let large = make(256_000)
            var smallTime = Double.infinity
            var largeTime = Double.infinity
            // Taken in turns, so that a busy moment weighs on both alike.
            for _ in 0 ..< 3 {
                smallTime = min(smallTime, Self.fastest(1) { #expect(StrictJSON.parse(small).value != nil) })
                largeTime = min(largeTime, Self.fastest(1) { #expect(StrictJSON.parse(large).value != nil) })
            }
            #expect(largeTime / smallTime < 6, "\(what): \(smallTime) s, then \(largeTime) s for four times as much")
            #expect(largeTime < 60, "\(what): \(largeTime) s for \(large.count) bytes")
        }
        #expect(Self.object(256_000).count > 3_300_000)
    }

    /// Asking an object for a field costs the same however many it has, so a
    /// check that asks for every key of a translation is linear too.
    @Test("a field is found in the same time in a large object as in a small one")
    func fieldsAreFoundAtOnce() throws {
        func object(_ count: Int) throws -> StrictJSON.Object {
            try #require(StrictJSON.parse(Self.object(count)).value?.object)
        }
        func askEveryKey(_ object: StrictJSON.Object) {
            var found = 0
            for key in object.keys where object.first(key) != nil && object.last(key) != nil { found += 1 }
            #expect(found == object.keys.count)
        }
        let small = try object(16_000)
        let large = try object(64_000)
        var smallTime = Double.infinity
        var largeTime = Double.infinity
        for _ in 0 ..< 3 {
            smallTime = min(smallTime, Self.fastest(1) { askEveryKey(small) })
            largeTime = min(largeTime, Self.fastest(1) { askEveryKey(large) })
        }
        #expect(largeTime / smallTime < 6, "\(smallTime) s, then \(largeTime) s for four times as many keys")
        #expect(large.first("k0000000")?.number?.wholeValue == 0)
        #expect(large.last("k0063999") != nil)
        #expect(large.first("k0064000") == nil)
    }

    /// The strict check asks a translation for every setting it translates;
    /// with fields found at once, four times the settings take about four
    /// times as long.
    @Test("a translation is checked in time proportional to its settings")
    func translationIsLinear() throws {
        func translation(_ count: Int) throws -> StrictJSON.Value {
            let text = "{\"settings\":{" + (0 ..< count).map { "\"k\($0)\":{\"label\":\"L\"}" }.joined(separator: ",") + "}}"
            return try #require(StrictJSON.parse(Array(text.utf8)).value)
        }
        let small = try translation(16_000)
        let large = try translation(64_000)
        var smallTime = Double.infinity
        var largeTime = Double.infinity
        for _ in 0 ..< 3 {
            smallTime = min(smallTime, Self.fastest(1) { #expect(ManifestShape.translationProblems(of: small, manifest: nil).isEmpty) })
            largeTime = min(largeTime, Self.fastest(1) { #expect(ManifestShape.translationProblems(of: large, manifest: nil).isEmpty) })
        }
        #expect(largeTime / smallTime < 6, "\(smallTime) s, then \(largeTime) s for four times as many settings")
    }
}
