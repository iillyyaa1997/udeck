import Testing
@testable import UDeckCore

/// Quieting a plugin before its folder is swapped or removed: nothing of it
/// starts, polls and card actions alike, and what had started is counted
/// until it ends.
@Suite("Quieting a plugin")
struct PluginQuietTests {
    @Test("a quiet plugin starts nothing until it is resumed")
    func quietRefuses() {
        var runs = PluginQuiet()
        runs.quiet("uptime")
        #expect(runs.isQuiet("uptime"))
        let refused = runs.begin("uptime")
        #expect(!refused, "an action pressed during the swap does not start")
        #expect(!runs.isRunning("uptime"), "and is not counted as running")
        let other = runs.begin("other")
        #expect(other, "another plugin is not quiet")
        runs.resume("uptime")
        let resumed = runs.begin("uptime")
        #expect(resumed)
    }

    @Test("runs that started before the quiet are counted until each ends")
    func inFlightIsCounted() {
        var runs = PluginQuiet()
        let first = runs.begin("uptime"), second = runs.begin("uptime")
        #expect(first && second)
        runs.quiet("uptime")
        #expect(runs.isRunning("uptime"))
        runs.end("uptime")
        #expect(runs.isRunning("uptime"), "one of two has ended")
        runs.end("uptime")
        #expect(!runs.isRunning("uptime"))
        runs.end("uptime")
        #expect(!runs.isRunning("uptime"), "an extra end counts nothing below zero")
        runs.resume("uptime")
        let again = runs.begin("uptime")
        #expect(again && runs.isRunning("uptime"))
    }
}
