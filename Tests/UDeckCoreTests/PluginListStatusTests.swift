import Testing
@testable import UDeckCore

@Suite("An installed plugin's line in the list")
struct PluginListStatusTests {
    typealias Facts = PluginListStatus.Facts

    @Test("a plugin with nothing to say runs")
    func runs() {
        #expect(PluginListStatus.of(Facts()) == .runs)
        #expect(!PluginListStatus.runs.isTrouble)
    }

    @Test("the most pressing thing wins, in order")
    func order() {
        // Everything at once, then one thing less each time: each line names
        // the most pressing of what is left.
        var facts = Facts(folderGone: true, wontLoad: true, asksPermission: true, declined: true, enabled: false,
                          failed: true, updateWaits: true, newerVersion: "1.3.0")
        #expect(PluginListStatus.of(facts) == .folderGone)
        facts.folderGone = false
        #expect(PluginListStatus.of(facts) == .wontLoad)
        facts.wontLoad = false
        #expect(PluginListStatus.of(facts) == .off)
        facts.enabled = true
        #expect(PluginListStatus.of(facts) == .asksPermission)
        facts.asksPermission = false
        #expect(PluginListStatus.of(facts) == .declined)
        facts.declined = false
        #expect(PluginListStatus.of(facts) == .failed)
        facts.failed = false
        #expect(PluginListStatus.of(facts) == .update(version: "1.3.0"))
        facts.updateWaits = false
        #expect(PluginListStatus.of(facts) == .runs)
    }

    @Test("an update with no newer version — the same version changed — says there is one")
    func updateWithoutVersion() {
        #expect(PluginListStatus.of(Facts(updateWaits: true)) == .update(version: nil))
        let english = Strings(.english)
        #expect(english(PluginListStatus.update(version: nil).phrase) == "update available")
        #expect(english(PluginListStatus.update(version: "1.3.0").phrase) == "1.3.0 available")
        #expect(Strings(.russian)(PluginListStatus.update(version: "1.3.0").phrase) == "есть 1.3.0")
    }

    @Test("what the operator has to act on is said in the warning colour, and nothing else is")
    func trouble() {
        #expect(PluginListStatus.folderGone.isTrouble)
        #expect(PluginListStatus.wontLoad.isTrouble)
        #expect(PluginListStatus.asksPermission.isTrouble)
        #expect(PluginListStatus.failed.isTrouble)
        #expect(!PluginListStatus.declined.isTrouble)
        #expect(!PluginListStatus.off.isTrouble)
        #expect(!PluginListStatus.update(version: "2.0.0").isTrouble)
    }
}
