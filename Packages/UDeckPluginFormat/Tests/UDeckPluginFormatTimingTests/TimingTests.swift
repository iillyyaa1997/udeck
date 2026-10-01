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
        // Four times the keys is four times the lookups, each a little slower
        // once the table outgrows the cache: 7 was measured on CI, where the
        // small run takes 7 ms. A search that read every key would be 16.
        #expect(largeTime / smallTime < 10, "\(smallTime) s, then \(largeTime) s for four times as many keys")
        #expect(large.first("k0000000")?.number?.wholeValue == 0)
        #expect(large.last("k0063999") != nil)
        #expect(large.first("k0064000") == nil)
    }

    /// A repository of `count` plugin folders, each a manifest, a script and
    /// a README, in one commit made by `git fast-import` — answering where.
    static func repository(_ count: Int, in scratch: URL) throws -> URL {
        let folder = scratch.appendingPathComponent("repository-\(count)", isDirectory: true)
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        func git(_ arguments: [String], input: [UInt8] = []) throws {
            let result = try Subprocess.run(["git", "-C", folder.path] + arguments, environment: environment, input: input)
            guard result.status == 0 else {
                throw CheckFailure("git \(arguments.first ?? ""): \(String(decoding: result.errors, as: UTF8.self))")
            }
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try git(["init", "-q", "-b", "main"])
        var stream: [UInt8] = []
        func data(_ text: String) { stream += Array("data \(text.utf8.count)\n\(text)\n".utf8) }
        stream += Array("blob\nmark :1\n".utf8)
        data("#!/bin/sh\necho '{}'\n")
        stream += Array("blob\nmark :2\n".utf8)
        data("# A plugin\n")
        stream += Array("commit refs/heads/main\ncommitter Ada <ada@example.com> 1790000000 +0000\n".utf8)
        data("Many plugins")
        stream += Array("M 100644 inline udeck-plugins.json\n".utf8)
        data(#"{"format": 1, "name": "Many"}"#)
        for index in 0 ..< count {
            let id = "p\(index)"
            stream += Array("M 100755 :1 plugins/\(id)/run.sh\nM 100644 :2 plugins/\(id)/README.md\n".utf8)
            stream += Array("M 100644 inline plugins/\(id)/manifest.json\n".utf8)
            data(#"{"id": "\#(id)", "name": "P", "version": "1.0.0", "api": 1, "kind": "poll", "run": ["./run.sh"], "interval": 5, "timeout": 2}"#)
        }
        try git(["fast-import", "--quiet"], input: stream)
        return folder
    }

    /// Each plugin folder's entries used to be found by reading every path in
    /// the repository, three times over, so a repository of 8,000 plugins
    /// took over twelve times as long to check as one of 2,000. They are found
    /// by halving now: four times the plugins take about four times as long.
    @Test("a repository is checked in time proportional to its plugin folders, not to their square")
    func repositoryIsLinear() throws {
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("udeck-timing-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let small = try Self.repository(1_000, in: scratch)
        let large = try Self.repository(4_000, in: scratch)
        var options = RepositoryCheck.Options(mode: .installable)
        options.gitEnvironment["GIT_CEILING_DIRECTORIES"] = scratch.path
        func check(_ folder: URL, _ count: Int) {
            do {
                let report = try RepositoryCheck.repository(folder.path, options: options)
                #expect(report.pluginFolders == count)
                #expect(report.findings.isEmpty, "\(report.findings.prefix(3))")
            } catch {
                Issue.record("\(error)")
            }
        }
        var smallTime = Double.infinity
        var largeTime = Double.infinity
        for _ in 0 ..< 3 {
            smallTime = min(smallTime, Self.fastest(1) { check(small, 1_000) })
            largeTime = min(largeTime, Self.fastest(1) { check(large, 4_000) })
        }
        #expect(largeTime / smallTime < 6, "\(smallTime) s, then \(largeTime) s for four times as many plugins")
        #expect(largeTime < 60, "\(largeTime) s for 4,000 plugins")
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

#if canImport(Darwin)
/// How long the waits of running a plugin last — here, with the other tests
/// that measure time, and not beside uDeck's test of its CPU.
@Suite("Waiting while a plugin runs")
struct RunningTimingTests {
    /// The pause between a polite signal and the next look at the group: cut
    /// short by a cancellation, a grace period becomes a busy wait, and
    /// `SIGKILL` follows `SIGTERM` at once.
    @Test("a pause a cancellation cannot cut short")
    func pauseOutlastsCancellation() async {
        let task = Task {
            let started = Date()
            await ProcessGroup.sleepIgnoringCancellation(0.3)
            return Date().timeIntervalSince(started)
        }
        task.cancel()
        let slept = await task.value
        #expect(slept >= 0.25, "a cancelled task paused \(slept)s of 0.3s")
        #expect(slept < 5, "a pause of 0.3s took \(slept)s")
    }
}
#endif
