import Foundation
import Testing
@testable import UDeckPluginFormat
import UDeckPluginFormatFixtures

#if canImport(Darwin)
/// What running a producer leaves behind and keeps: the pipes, once a run has
/// returned, and the output past the limit. uDeck runs every plugin with this,
/// and `udeck-plugin run` too; uDeck's own tests of it are PollExecutionTests.
@Suite("Running a producer")
struct ProcessRunnerTests {
    /// A plugin of the test's own, in `temp/plugins/<id>`: `script` is all it runs.
    static func plugin(_ temp: TemporaryDirectory, _ id: String, script: String) -> URL {
        temp.writePlugin(folder: id, manifest: """
            { "id": "\(id)", "name": "\(id)", "version": "1.0.0", "api": 1, "kind": "poll",
              "run": ["./run.sh"], "interval": 5, "timeout": 2 }
            """, script: (name: "run.sh", body: "#!/bin/sh\n" + script + "\n", executable: true))
    }

    /// A producer that starts something in a session of its own — `setsid` —
    /// leaves the process group uDeck ends, and what it started keeps the
    /// pipes. The run must not wait for it, and must not leave its own read
    /// ends open when it returns: here the grandchild waits for the run to
    /// return, then writes, and says whether anybody was still reading.
    @Test("a grandchild that left the group and keeps the pipes neither holds the run nor finds them read after it")
    func grandchildOutsideTheGroup() async throws {
        let temp = TemporaryDirectory()
        defer { withExtendedLifetime(temp) {} }
        let scratch = temp.url.appendingPathComponent("scratch", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let folder = Self.plugin(temp, "escaper", script: Escaper.script(in: scratch))
        defer { Escaper.stop(in: scratch) }
        let report = try await PluginTrial.run(folder, options: PluginTrial.Options(environment: [:]))
        guard case .card = report.execution else { Issue.record("\(report.execution)"); return }
        let verdict = Escaper.verdict(in: scratch)
        #expect(verdict == "closed", "the grandchild found its pipe \(verdict ?? "never written to")")
    }

    /// The limit holds standard output and standard error together, and what
    /// goes past it is counted, by stream, where it was dropped.
    @Test("what the limit drops is counted, by stream")
    func droppedCounted() async throws {
        let temp = TemporaryDirectory()
        defer { withExtendedLifetime(temp) {} }
        var runner = ProcessRunner()
        runner.maximumOutputBytes = 1000
        // One write of 1,500 bytes, so that however soon the producer is
        // stopped for it, every byte was sent.
        let flood = Self.plugin(temp, "flood", script: #"printf '{"rows": []}'; /usr/bin/perl -e 'syswrite(STDERR, "e" x 1500) == 1500 or exit 1'"#)
        let flooded = try await PluginTrial.run(flood, options: PluginTrial.Options(environment: [:], runner: runner))
        #expect(flooded.result.standardOutput == Data(#"{"rows": []}"#.utf8))
        #expect(flooded.result.standardError == Data(repeating: UInt8(ascii: "e"), count: 988))
        #expect(flooded.result.standardOutputDropped == 0)
        #expect(flooded.result.standardErrorDropped == 512)

        // And standard output's own tail, when it is what goes past.
        let spill = Self.plugin(temp, "spill", script: #"/usr/bin/perl -e 'syswrite(STDOUT, "o" x 1500) == 1500 or exit 1'"#)
        let spilt = try await PluginTrial.run(spill, options: PluginTrial.Options(environment: [:], runner: runner))
        #expect(spilt.result.standardOutput == Data(repeating: UInt8(ascii: "o"), count: 1000))
        #expect(spilt.result.standardOutputDropped == 500)
        #expect(spilt.result.standardError.isEmpty && spilt.result.standardErrorDropped == 0)
    }
}
#endif
