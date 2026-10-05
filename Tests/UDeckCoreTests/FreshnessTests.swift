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

/// A run that fails while the card before it is still fresh is said on that
/// card at once — an amber dot by its name and one line — and is gone after
/// the next run that prints one (Q128).
@Suite("A failed run on a fresh card")
struct FailureOnAFreshCardTests {
    let plugin = PluginIdentifier(rawValue: "p")!
    let start = Date(timeIntervalSince1970: 1_000_000)

    func run(_ result: PluginRun.Result, at date: Date) -> PluginRun {
        PluginRun(startedAt: date, reason: .interval, termination: .exited(code: 3), duration: 0.2, result: result,
                  standardError: "Traceback\nValueError: no\n")
    }

    /// A card from `start`, with a ttl of 120 s, and the run after it at `failedAt`.
    func failedAfterACard(_ execution: PollExecution, at failedAt: Date) -> PluginSnapshot {
        var s = PluginSnapshot(pluginID: plugin)
        s.record(PollAttempt(execution: .card(Card(rows: [.text("value")], ttl: 120)), run: run(.card, at: start)), at: start)
        let result: PluginRun.Result = switch execution {
        case .card: .card
        case .lateCard(_, let failure): .lateCard(failure.reason)
        case .failure(let failure): .failure(failure.reason)
        }
        s.record(PollAttempt(execution: execution, run: run(result, at: failedAt)), at: failedAt)
        return s
    }

    @Test("said while the card is fresh: when it failed, why, and when the values shown are from")
    func said() {
        let failedAt = start.addingTimeInterval(61)
        let s = failedAfterACard(.failure(PluginFailure(reason: .exited(code: 3), occurredAt: failedAt)), at: failedAt)
        let said = s.failureOnAFreshCard(now: failedAt.addingTimeInterval(1), defaultTTL: 60, silentMultiplier: 3)
        #expect(said == FailureOnAFreshCard(failedAt: failedAt, reason: .exited(code: 3), valuesFrom: start))
    }

    @Test("gone after the next run that prints a card")
    func goneAfterAGoodRun() {
        let failedAt = start.addingTimeInterval(61)
        var s = failedAfterACard(.failure(PluginFailure(reason: .exited(code: 3), occurredAt: failedAt)), at: failedAt)
        let later = failedAt.addingTimeInterval(5)
        s.record(PollAttempt(execution: .card(Card(rows: [.text("back")], ttl: 120)), run: run(.card, at: later)), at: later)
        #expect(s.failureOnAFreshCard(now: later, defaultTTL: 60, silentMultiplier: 3) == nil)
    }

    @Test("not said on a card past its ttl, which says it itself, nor on one long past it, which shows no values")
    func onlyWhileFresh() {
        let failedAt = start.addingTimeInterval(61)
        let s = failedAfterACard(.failure(PluginFailure(reason: .exited(code: 3), occurredAt: failedAt)), at: failedAt)
        #expect(s.failureOnAFreshCard(now: start.addingTimeInterval(121), defaultTTL: 60, silentMultiplier: 3) == nil)
        #expect(s.failureOnAFreshCard(now: start.addingTimeInterval(400), defaultTTL: 60, silentMultiplier: 3) == nil)
        #expect(s.failureOnAFreshCard(now: start.addingTimeInterval(119), defaultTTL: 60, silentMultiplier: 3) != nil)
    }

    @Test("a card printed before the run went past its timeout is said too, and its values are from that run")
    func lateCard() {
        let failedAt = start.addingTimeInterval(61)
        let s = failedAfterACard(.lateCard(Card(rows: [.text("late")], ttl: 120),
                                           PluginFailure(reason: .timedOut(after: 2), occurredAt: failedAt)), at: failedAt)
        let said = s.failureOnAFreshCard(now: failedAt, defaultTTL: 60, silentMultiplier: 3)
        #expect(said == FailureOnAFreshCard(failedAt: failedAt, reason: .timedOut(after: 2), valuesFrom: failedAt))
    }

    /// A plugin switched off, or not permitted, runs nothing: its window says
    /// so in place of the card, and no run failed.
    @Test("not said when nothing ran, nor when no card was ever drawn")
    func nothingRan() {
        var s = PluginSnapshot(pluginID: plugin)
        s.record(PollAttempt(execution: .card(Card(rows: [.text("value")], ttl: 120)), run: run(.card, at: start)), at: start)
        s.record(PollAttempt(execution: .failure(PluginFailure(reason: .notPermitted(.disabled))), run: nil),
                 at: start.addingTimeInterval(5))
        #expect(s.failure != nil)
        #expect(s.failureOnAFreshCard(now: start.addingTimeInterval(6), defaultTTL: 60, silentMultiplier: 3) == nil)

        var never = PluginSnapshot(pluginID: plugin)
        never.record(PollAttempt(execution: .failure(PluginFailure(reason: .exited(code: 1))),
                                 run: run(.failure(.exited(code: 1)), at: start)), at: start)
        #expect(never.failureOnAFreshCard(now: start, defaultTTL: 60, silentMultiplier: 3) == nil)
    }
}
