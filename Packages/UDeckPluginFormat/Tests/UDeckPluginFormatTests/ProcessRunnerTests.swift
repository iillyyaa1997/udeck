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

    /// The limit is standard output's alone, and what goes past it is
    /// counted where it was dropped; standard error keeps its tail.
    @Test("what the limit drops of standard output, and what standard error keeps of its end, are counted")
    func droppedCounted() async throws {
        let temp = TemporaryDirectory()
        defer { withExtendedLifetime(temp) {} }
        var runner = ProcessRunner()
        runner.maximumOutputBytes = 1000
        runner.standardErrorTail = 1000
        // One write of 1,500 bytes of each, so that however soon the producer
        // is stopped, every byte was sent.
        let flood = Self.plugin(temp, "flood", script: #"printf '{"rows": []}'; /usr/bin/perl -e 'syswrite(STDERR, "a" x 500 . "e" x 1000) == 1500 or exit 1'"#)
        let flooded = try await PluginTrial.run(flood, options: PluginTrial.Options(environment: [:], runner: runner))
        #expect(flooded.result.termination == .exited(code: 0), "standard error is no output the limit stops a run for")
        #expect(flooded.result.standardOutput == Data(#"{"rows": []}"#.utf8))
        #expect(flooded.result.standardError == Data(repeating: UInt8(ascii: "e"), count: 1000), "its end, not its beginning")
        #expect(flooded.result.standardOutputDropped == 0)
        #expect(flooded.result.standardErrorDropped == 500)

        // And standard output's own tail, when it is what goes past.
        let spill = Self.plugin(temp, "spill", script: #"/usr/bin/perl -e 'syswrite(STDOUT, "o" x 1500) == 1500 or exit 1'"#)
        let spilt = try await PluginTrial.run(spill, options: PluginTrial.Options(environment: [:], runner: runner))
        #expect(spilt.result.standardOutput == Data(repeating: UInt8(ascii: "o"), count: 1000))
        #expect(spilt.result.standardOutputDropped == 500)
        #expect(spilt.result.standardError.isEmpty && spilt.result.standardErrorDropped == 0)
    }

    /// A producer that writes megabytes to standard error is a producer
    /// explaining itself at length: it is not stopped for it, its card is
    /// drawn, and uDeck holds no more of it than the tail. Written over a
    /// third of a second, so that the watch on the output limit — which looks
    /// every 25 ms — sees it many times past the limit while it runs.
    @Test("a flood of standard error neither stops the run nor is held past its tail")
    func standardErrorFlood() async throws {
        let temp = TemporaryDirectory()
        defer { withExtendedLifetime(temp) {} }
        var runner = ProcessRunner()
        runner.maximumOutputBytes = 4096
        let chatty = Self.plugin(temp, "chatty", script: #"/usr/bin/perl -e 'for (1 .. 32) { syswrite(STDERR, "e" x 65535 . "\n"); select(undef, undef, undef, 0.01) }'; printf '{"rows": [{"text": "said"}]}'"#)
        let said = try await PluginTrial.run(chatty, options: PluginTrial.Options(environment: [:], runner: runner))
        #expect(said.result.termination == .exited(code: 0))
        guard case .card(let card) = said.execution else { Issue.record("\(said.execution)"); return }
        #expect(card.rows.count == 1)
        #expect(said.result.standardError.count == ProcessRunner.defaultStandardErrorTail)
        #expect(said.result.standardErrorDropped == 32 * 65536 - ProcessRunner.defaultStandardErrorTail)
        #expect(said.result.standardError.last == UInt8(ascii: "\n"))
    }

    /// A tail cut in the middle of a character would open on half of one, and
    /// the text shown would start with a replacement mark: the cut moves to
    /// where the next character starts.
    @Test("the tail of standard error starts on a whole character", arguments: [
        ("é", 999, 998), ("€", 1000, 999), ("😀", 1003, 1000), ("a", 1000, 1000),
    ])
    func tailOnACharacter(_ character: String, _ tail: Int, _ kept: Int) async throws {
        let temp = TemporaryDirectory()
        defer { withExtendedLifetime(temp) {} }
        var runner = ProcessRunner()
        runner.standardErrorTail = tail
        let bytes = Array(character.utf8)
        let hex = bytes.map { String($0, radix: 16) }.map { "\\x" + $0 }.joined()
        let wide = Self.plugin(temp, "wide", script: "/usr/bin/perl -e 'syswrite(STDERR, \"\(hex)\" x 1000)'; printf '{\"rows\": []}'")
        let said = try await PluginTrial.run(wide, options: PluginTrial.Options(environment: [:], runner: runner))
        #expect(said.result.standardError.count == kept, "\(character)")
        #expect(said.result.standardErrorDropped == 1000 * bytes.count - kept, "\(character)")
        let text = String(decoding: said.result.standardError, as: UTF8.self)
        #expect(text == String(repeating: character, count: kept / bytes.count), "\(character)")
    }
}
#endif
