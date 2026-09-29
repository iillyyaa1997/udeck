import Foundation
import Testing
@testable import UDeckCore

@Suite("Freshness")
struct FreshnessTests {
    let plugin = PluginIdentifier(rawValue: "p")!
    let start = Date(timeIntervalSince1970: 1_000_000)

    func snapshot(ttl: TimeInterval?, state: CardState = .ok) -> PluginSnapshot {
        var s = PluginSnapshot(pluginID: plugin)
        s.record(card: Card(state: state, rows: [.text("value")], ttl: ttl), at: start)
        return s
    }

    @Test("inside its ttl a card is shown as it is")
    func freshCard() {
        let p = snapshot(ttl: 30).presentation(now: start.addingTimeInterval(10),
                                               defaultTTL: 60, silentMultiplier: 3)
        #expect(p.freshness == .fresh)
        #expect(p.card != nil)
        #expect(p.state == .ok)
        #expect(p.note == nil)
    }

    @Test("just past its ttl the values are still shown, but marked and dated")
    func staleCardKeepsItsValues() {
        let p = snapshot(ttl: 30).presentation(now: start.addingTimeInterval(45),
                                               defaultTTL: 60, silentMultiplier: 3)
        guard case .stale(let age) = p.freshness else { Issue.record("expected stale"); return }
        #expect(age == 45)
        #expect(p.card != nil)
        #expect(p.note?.contains("last spoke") == true)
    }

    /// The failure that kills a panel like this: a stale "everything is fine"
    /// that still looks fine.
    @Test("long past its ttl the values are hidden and the card reads unknown")
    func silentCardHidesItsValues() {
        let p = snapshot(ttl: 30).presentation(now: start.addingTimeInterval(200),
                                               defaultTTL: 60, silentMultiplier: 3)
        guard case .silent = p.freshness else { Issue.record("expected silent"); return }
        #expect(p.card == nil, "a number nobody can vouch for must not be on screen")
        #expect(p.state == .unknown)
        #expect(p.lastSpokeAt == start)
    }

    @Test("a card with no ttl of its own uses the host's default")
    func defaultTTLApplies() {
        let s = snapshot(ttl: nil)
        #expect(s.presentation(now: start.addingTimeInterval(30), defaultTTL: 60, silentMultiplier: 3).freshness == .fresh)
        guard case .stale = s.presentation(now: start.addingTimeInterval(90), defaultTTL: 60, silentMultiplier: 3).freshness else {
            Issue.record("expected stale past the default ttl"); return
        }
    }

    @Test("a plugin that has never produced a card says so, rather than looking healthy")
    func neverSpoke() {
        let p = PluginSnapshot(pluginID: plugin)
            .presentation(now: start, defaultTTL: 60, silentMultiplier: 3)
        #expect(p.freshness == .neverSpoke)
        #expect(p.state == .unknown)
        #expect(p.card == nil)
    }

    @Test("a failure right after a good card shows the card and says what just broke")
    func freshCardWithARecentFailure() {
        var s = snapshot(ttl: 30)
        s.record(failure: PluginFailure(reason: .timedOut(after: 3)))
        let p = s.presentation(now: start.addingTimeInterval(5), defaultTTL: 60, silentMultiplier: 3)
        #expect(p.card != nil)
        #expect(p.freshness == .fresh)
        #expect(p.note?.contains("did not answer within 3s") == true)
    }

    @Test("a good run clears the previous failure")
    func recoveryClearsFailure() {
        var s = snapshot(ttl: 30)
        s.record(failure: PluginFailure(reason: .exited(code: 1)))
        #expect(s.consecutiveFailures == 1)
        s.record(card: Card(rows: [.text("back")], ttl: 30), at: start.addingTimeInterval(5))
        #expect(s.failure == nil)
        #expect(s.consecutiveFailures == 0)
    }

    /// A source going quiet on purpose is not a source that broke. The machine
    /// this was built for has one that exits five minutes after the last
    /// session closes, so its files are legitimately stale every night.
    @Test("an idle source and a broken one produce different cards")
    func idleIsNotBroken() {
        let idle = Card(state: .ok, chip: "no sessions", rows: [.text("nothing running")], ttl: 30)
        var idleSnapshot = PluginSnapshot(pluginID: plugin)
        idleSnapshot.record(card: idle, at: start)

        var brokenSnapshot = snapshot(ttl: 30)
        brokenSnapshot.record(failure: PluginFailure(reason: .timedOut(after: 3)))

        let idlePresentation = idleSnapshot.presentation(now: start.addingTimeInterval(5), defaultTTL: 60, silentMultiplier: 3)
        let brokenPresentation = brokenSnapshot.presentation(now: start.addingTimeInterval(5), defaultTTL: 60, silentMultiplier: 3)

        #expect(idlePresentation.state == .ok)
        #expect(idlePresentation.note == nil)
        #expect(brokenPresentation.note != nil)
    }
}
