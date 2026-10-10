import Foundation
import Testing
@testable import UDeckCore
import UDeckPluginFormatFixtures

/// Which verified plugins update themselves (`AutoUpdate`), and the permission
/// decision across a swap of one verified copy for another (`GrantCarry`).
/// Every condition is taken away on its own from a plugin that does update
/// itself, and each one alone has to stop it — with its own reason, which is
/// what tells a condition that holds from one that is never asked.
@Suite("Updating by themselves")
struct AutoUpdateTests {
    static let asks: [Capability] = [.exec("sysctl"), .exec("./hold.sh")]

    static func record(version: String = "1.0.0", pinned: Bool = false) -> InstalledRecord {
        let at = Date(timeIntervalSince1970: 1_790_000_000)
        return InstalledRecord(
            source: "official", repository: .official, ref: PluginRef(name: "main"),
            commit: String(repeating: "c", count: 40), tree: String(repeating: "7", count: 40), version: version,
            installedAt: at, pinned: pinned,
            verification: PluginVerification(status: .verified, by: "official", checkedAgainst: nil, checkedAt: at),
            previous: nil)
    }

    /// `uptime` 1.0.0, verified, uDeck's own copy in place, 1.1.0 at the head
    /// asking for the same: it updates itself.
    static func updating(_ change: (inout AutoUpdate.Plugin) -> Void = { _ in }) -> AutoUpdate.Plugin {
        var plugin = AutoUpdate.Plugin(record: record(), offer: .newer(version: "1.1.0"), standing: .verified,
                                       asksNow: asks, asksAtHead: asks, place: .deleted)
        change(&plugin)
        return plugin
    }

    @Test("a verified plugin whose new version asks for the same updates itself")
    func updates() {
        #expect(AutoUpdate.verdict(Self.updating(), switchedOn: true, busy: false) == .update(version: "1.1.0"))
        let republished = Self.updating { $0.offer = .changedStill(version: "1.0.0") }
        #expect(AutoUpdate.verdict(republished, switchedOn: true, busy: false) == .update(version: "1.0.0"))
        // The order the manifest lists them in, and one listed twice, change nothing.
        let reordered = Self.updating { $0.asksAtHead = [.exec("./hold.sh"), .exec("sysctl"), .exec("sysctl")] }
        #expect(AutoUpdate.verdict(reordered, switchedOn: true, busy: false) == .update(version: "1.1.0"))
        let none = Self.updating { $0.asksNow = []; $0.asksAtHead = [] }
        #expect(AutoUpdate.verdict(none, switchedOn: true, busy: false) == .update(version: "1.1.0"))
    }

    /// One row per condition: the plugin that updates itself with that one
    /// thing changed, and what it comes to.
    static let table: [(String, AutoUpdate.Plugin, Bool, Bool, AutoUpdate.Verdict)] = [
        ("the switch off", updating(), false, false, .not(.switchedOff)),
        ("no catalogue", updating { $0.offer = nil }, true, false, .not(.nothingWaiting)),
        ("current", updating { $0.offer = .current }, true, false, .not(.nothingWaiting)),
        ("the repository went back", updating { $0.offer = .older(version: "0.9.0") }, true, false, .not(.nothingWaiting)),
        ("cannot run here", updating {
            $0.offer = .cannotRun(version: "2.0.0", reason: .apiNotSpoken(name: "uptime", version: "2.0.0", api: 2))
        }, true, false, .not(.nothingWaiting)),
        ("gone from the repository", updating { $0.offer = .goneFromRepository }, true, false, .not(.nothingWaiting)),
        ("modified locally", updating { $0.standing = .modifiedLocally }, true, false, .not(.notVerified)),
        ("missing", updating { $0.standing = .missing }, true, false, .not(.notVerified)),
        ("a folder of the operator's own, or a link", updating { $0.standing = .folderOfYourOwn }, true, false,
         .not(.notVerified)),
        ("not hashed yet", updating { $0.standing = nil }, true, false, .not(.notVerified)),
        ("pinned", updating { $0.record = record(pinned: true) }, true, false, .not(.pinned)),
        ("one command more", updating { $0.asksAtHead = asks + [.exec("uname")] }, true, false, .not(.asksDifferently)),
        ("one command fewer", updating { $0.asksAtHead = [.exec("sysctl")] }, true, false, .not(.asksDifferently)),
        ("another command", updating { $0.asksAtHead = [.exec("sysctl"), .exec("./other.sh")] }, true, false,
         .not(.asksDifferently)),
        ("a read for an exec", updating { $0.asksAtHead = [.exec("sysctl"), .read("./hold.sh")] }, true, false,
         .not(.asksDifferently)),
        ("asking where it asked nothing", updating { $0.asksNow = []; $0.asksAtHead = [.screen] }, true, false,
         .not(.asksDifferently)),
        ("the head's manifest unread", updating { $0.asksAtHead = nil }, true, false, .not(.asksDifferently)),
        ("the manifest on disk unread", updating { $0.asksNow = nil }, true, false, .not(.asksDifferently)),
        ("a .env beside it, or the copy changed since it was hashed", updating { $0.place = .toTrash }, true, false,
         .not(.operatorsWork)),
        ("a link put where the copy was", updating { $0.place = .linkGoes(leadsTo: "/Users/x/src/uptime") }, true, false,
         .not(.operatorsWork)),
        ("nothing there any more", updating { $0.place = .nothing }, true, false, .not(.operatorsWork)),
        ("failed since the last read", updating { $0.failedSinceTheLastRead = true }, true, false,
         .not(.failedSinceTheLastRead)),
        ("a card action running", updating { $0.actionRunning = true }, true, false, .later(.actionRunning)),
        ("another operation running", updating(), true, true, .later(.busy)),
    ]

    @Test("each condition alone stops it, with its own reason", arguments: 0..<table.count)
    func eachCondition(row: Int) {
        let (what, plugin, switchedOn, busy, wanted) = Self.table[row]
        #expect(AutoUpdate.verdict(plugin, switchedOn: switchedOn, busy: busy) == wanted, "\(what)")
    }

    /// Byte for byte, as **Allow** compares what was shown: one spelling of a
    /// path is not another the system happens to treat alike.
    @Test("what a manifest asks for is compared byte for byte, as a set")
    func capabilitiesByTheByte() {
        let composed = "/Users/x/caf\u{E9}.sh", decomposed = "/Users/x/cafe\u{301}.sh"
        #expect(composed == decomposed, "Swift's own == calls them the same")
        #expect(AutoUpdate.asksDifferently([.exec(composed)], [.exec(decomposed)]))
        #expect(!AutoUpdate.asksDifferently([.exec(composed), .screen], [.screen, .exec(composed), .screen]))
        #expect(AutoUpdate.asksDifferently([.exec("a")], [.exec("a"), .exec("b")]))
        #expect(AutoUpdate.asksDifferently([.exec("a"), .exec("b")], [.exec("a")]))
        #expect(!AutoUpdate.asksDifferently([], []))
    }

    // MARK: - The decision across a swap

    static let decided = Date(timeIntervalSince1970: 1_790_000_000)

    static func grant(for version: String = "1.0.0", allowed: Bool = true) -> PluginGrant {
        PluginGrant(granted: allowed ? Set(asks) : [], denied: allowed ? [] : Set(asks), decidedForVersion: version,
                    decidedAt: decided)
    }

    static let old = GrantCarry.Copy(version: "1.0.0", asks: asks, verified: true)
    static let new = GrantCarry.Copy(version: "1.1.0", asks: asks, verified: true)

    @Test("a verified copy for a verified copy asking for the same carries the decision, and nothing else changes")
    func carried() throws {
        let carried = try #require(GrantCarry.after(Self.grant(), old: Self.old, new: Self.new))
        #expect(carried == PluginGrant(granted: Set(Self.asks), decidedForVersion: "1.1.0", decidedAt: Self.decided))
        // A refusal is a decision too: the plugin that was declined stays declined.
        let declined = try #require(GrantCarry.after(Self.grant(allowed: false), old: Self.old, new: Self.new))
        #expect(declined.decidedForVersion == "1.1.0" && declined.denied == Set(Self.asks) && declined.granted.isEmpty)
        // Back to an earlier version is a swap like any other.
        let back = GrantCarry.after(Self.grant(for: "1.1.0"), old: Self.new, new: Self.old)
        #expect(back?.decidedForVersion == "1.0.0")
    }

    static let kept: [(String, PluginGrant?, GrantCarry.Copy?, GrantCarry.Copy)] = [
        ("never decided", nil, old, new),
        ("the old copy unread", grant(), nil, new),
        ("the old copy not verified", grant(), GrantCarry.Copy(version: "1.0.0", asks: asks, verified: false), new),
        ("the new copy not verified", grant(), old, GrantCarry.Copy(version: "1.1.0", asks: asks, verified: false)),
        ("decided for another version", grant(for: "0.9.0"), old, new),
        ("one command more", grant(), old, GrantCarry.Copy(version: "1.1.0", asks: asks + [.exec("uname")], verified: true)),
        ("one command fewer", grant(), old, GrantCarry.Copy(version: "1.1.0", asks: [.exec("sysctl")], verified: true)),
    ]

    @Test("anything else leaves the decision as it was", arguments: 0..<kept.count)
    func notCarried(row: Int) {
        let (what, grant, old, new) = Self.kept[row]
        #expect(GrantCarry.after(grant, old: old, new: new) == grant, "\(what)")
    }

    /// What the carry is for: the gate lets the new version run without
    /// asking — and, uncarried, it asks — and carrying grants nothing the
    /// decision did not hold.
    @Test("the gate runs the new version on a carried decision, and asks on one left as it was")
    func theGateAgrees() throws {
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: Data(FakeRepository.manifest(
            version: "1.1.0", permissions: #"{ "exec": ["sysctl", "./hold.sh"] }"#).utf8))
        let carried = GrantCarry.after(Self.grant(), old: Self.old, new: Self.new)
        #expect(PermissionGate.launchDecision(for: manifest, grant: carried, enabled: true) == .allowed)
        #expect(PermissionGate.launchDecision(for: manifest, grant: Self.grant(), enabled: true)
                == .awaitingDecision(pending: manifest.permissions.capabilities))
        let more = try JSONDecoder().decode(PluginManifest.self, from: Data(FakeRepository.manifest(
            version: "1.1.0", permissions: #"{ "exec": ["sysctl", "./hold.sh", "uname"] }"#).utf8))
        let notCarried = GrantCarry.after(Self.grant(), old: Self.old, new: GrantCarry.Copy(
            version: "1.1.0", asks: more.permissions.capabilities, verified: true))
        #expect(PermissionGate.launchDecision(for: more, grant: notCarried, enabled: true)
                == .awaitingDecision(pending: more.permissions.capabilities))
    }

    // MARK: - The switch

    @Test("the switch is on as uDeck ships, and the file says nothing until it is turned off")
    func theSwitch() throws {
        #expect(AppSettings().updatesVerifiedByThemselves)
        #expect(try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8)).autoUpdateVerified == nil)
        let off = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"autoUpdateVerified": false}"#.utf8))
        #expect(!off.updatesVerifiedByThemselves)
        let written = try JSONSerialization.jsonObject(with: JSONEncoder().encode(AppSettings())) as? [String: Any]
        #expect(written?["autoUpdateVerified"] == nil)
        let again = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(off))
        #expect(again.autoUpdateVerified == false)
    }

    /// What `AutoUpdate.verdict` is given as `switchedOn`: the switch and the
    /// catalogue's own, each as it stands — nil is the shipped answer, on.
    static let switches: [(Bool?, Bool?, Bool)] = [
        (nil, nil, true), (true, nil, true), (nil, true, true), (true, true, true),
        (false, nil, false), (false, true, false), (nil, false, false), (true, false, false), (false, false, false),
    ]

    @Test("it takes the switch and the official catalogue both", arguments: 0..<switches.count)
    func bothSwitches(row: Int) {
        let (catalogue, itself, wanted) = Self.switches[row]
        let settings = AppSettings(officialCatalogue: catalogue, autoUpdateVerified: itself)
        #expect(settings.verifiedPluginsUpdateThemselves == wanted, "catalogue \(String(describing: catalogue)), switch \(String(describing: itself))")
    }

    // MARK: - When the plugins are asked

    /// A schedule as it is after a read that succeeded, with the hashing
    /// after it numbered 4, and applied.
    static func afterARead() -> AutoUpdateSchedule {
        var schedule = AutoUpdateSchedule()
        schedule.read(succeeded: true, hashing: 4)
        schedule.hashed(4)
        return schedule
    }

    @Test("only a read that succeeded makes the plugins due, and only once the folders are hashed after it")
    func afterTheRead() {
        var schedule = AutoUpdateSchedule()
        #expect(!schedule.asks, "before any read")
        schedule.read(succeeded: false, hashing: 1)
        schedule.hashed(1)
        #expect(!schedule.asks, "a read that failed, or was left for later, changes nothing")

        schedule.read(succeeded: true, hashing: 4)
        #expect(schedule.due && !schedule.asks, "not on standings from before the read")
        schedule.hashed(3)
        #expect(!schedule.asks, "a hashing started before the read is not the one")
        schedule.hashed(5)
        #expect(schedule.asks, "a later hashing stands in for one it superseded")
        schedule.hashed(2)
        #expect(schedule.asks, "an older hashing applied late does not undo it")
    }

    @Test("asked, they stay due while one waits or one started, and not otherwise")
    func stayingDue() {
        var schedule = Self.afterARead()
        schedule.asked(started: false, waits: true)
        #expect(schedule.asks, "a card action, or another operation, held one: the tick asks again")
        schedule.asked(started: true, waits: false)
        #expect(schedule.asks, "one started: when it ends, the others are asked")
        schedule.asked(started: false, waits: false)
        #expect(!schedule.asks && !schedule.due, "none waits: not before the next read")
        schedule.hashed(9)
        #expect(!schedule.asks, "a hashing is no read")
        schedule.read(succeeded: true, hashing: 10)
        schedule.hashed(10)
        #expect(schedule.asks)
    }

    /// What an update by itself that threw comes to — and what its row says.
    static let endings: [(String, any Error, AutoUpdateSchedule.Ending)] = [
        ("a card action still running when it was quieted, or the switch gone off",
         InstallError.stillRunning(id: "uptime"), .leftAsItWas),
        ("the operator's work come to the place", AutoUpdate.OperatorsWorkCame(id: "uptime"), .leftAsItWas),
        ("unreachable", InstallError.unreachable(path: "plugins/uptime/uptime.sh", reason: "timed out"), .failed),
        ("refused", InstallError.refused([.folderDoesNotAddUp(id: "uptime")]), .failed),
        ("took too long", InstallError.tookTooLong, .failed),
        ("the disk said no", InstallError.cannotWrite("full"), .failed),
        ("the listing", CatalogueError.notFound, .failed),
        ("cancelled", CancellationError(), .failed),
    ]

    @Test("a failure is said and kept until the next read; the folder left as it was is no failure",
          arguments: 0..<endings.count)
    func eachEnding(row: Int) {
        let (what, error, wanted) = Self.endings[row]
        var schedule = Self.afterARead()
        #expect(schedule.ended("uptime", version: "1.1.0", throwing: error) == wanted, "\(what)")
        #expect(schedule.failures == (wanted == .failed ? ["uptime": "1.1.0"] : [:]), "\(what)")
    }

    @Test("a read forgets the failures, and so does the next operation on that plugin")
    func failuresGo() {
        var schedule = Self.afterARead()
        schedule.ended("uptime", version: "1.1.0", throwing: InstallError.tookTooLong)
        schedule.ended("other", version: "2.0.0", throwing: InstallError.tookTooLong)
        schedule.read(succeeded: false, hashing: 5)
        #expect(schedule.failures == ["uptime": "1.1.0", "other": "2.0.0"], "a read that failed forgets nothing")
        schedule.began("other")
        #expect(schedule.failures == ["uptime": "1.1.0"], "a press on another plugin leaves this one's")
        schedule.read(succeeded: true, hashing: 6)
        #expect(schedule.failures.isEmpty, "each failed update is tried again once per read")
    }
}
