#if canImport(Darwin)
import Foundation
import Testing
import UDeckPluginCommand
@testable import UDeckPluginFormat
import UDeckPluginFormatFixtures

/// `udeck-plugin run` of a producer that prints its card and then runs on
/// past its timeout: uDeck draws the card and counts a failure, and the
/// command says both.
///
/// Here, and not with the other tests of `run`: what it proves needs the card
/// printed before the timeout, and that is a race between a shell starting
/// and a clock. With a timeout of half a second, beside every other test of
/// uDeck's `swift test`, the shell once had not printed a byte when the
/// clock ran out. This target runs one test at a time (`--no-parallel`), and
/// the timeout is two seconds: what is proved is the same, and only a machine
/// that cannot start a shell in two seconds is too slow for it.
@Suite("A card printed before the timeout")
struct LateCardTests {
    @Test("a card printed before the timeout is a card uDeck draws and a failure it counts")
    func lateCard() async throws {
        let temp = TemporaryDirectory()
        defer { withExtendedLifetime(temp) {} }
        temp.writePlugin(folder: "late", manifest: """
            { "id": "late", "name": "late", "version": "1.0.0", "api": 1, "kind": "poll",
              "run": ["./run.sh"], "interval": 5, "timeout": 2 }
            """, script: (name: "run.sh", body: #"#!/bin/sh"# + "\n" + #"printf '{"rows": [{"text": "early"}]}'; sleep 30"# + "\n",
                          executable: true))
        var output: [String] = []
        var errors: [String] = []
        let home = temp.url.path
        let status = await Command.run(
            ["run", "plugins/late"],
            environment: ["PATH": "/usr/bin:/bin", "HOME": home, "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"],
            currentDirectory: home, homes: UserHomes(current: { home }, named: { _ in nil }),
            output: { output.append($0) }, errors: { errors.append($0) })
        #expect(status == 1, "\(output) \(errors)")
        #expect(output.contains("ended: stopped by uDeck after 2 s, its timeout"), "\(output)")
        #expect(output.contains("uDeck draws the card, and counts a failure: the producer did not answer within 2s and was stopped"),
                "\(output)")
        #expect(output.contains { $0.hasPrefix("warning: the producer printed its card and then ran on past its timeout") })
        #expect(output.last == "ran plugins/late: a failure, 1 warning", "\(output)")
    }
}
#endif
