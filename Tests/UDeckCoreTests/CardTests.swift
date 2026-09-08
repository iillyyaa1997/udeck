import Foundation
import Testing
@testable import UDeckCore

@Suite("Card format")
struct CardTests {
    func card(_ json: String) throws -> Card {
        try JSONDecoder().decode(Card.self, from: Data(json.utf8))
    }

    @Test("every row type in the contract decodes")
    func allRowTypes() throws {
        let c = try card("""
        { "state": "warn", "chip": "17 waiting", "ttl": 30,
          "rows": [
            { "text": "a line" },
            { "kv": ["label", "value"] },
            { "kv": ["label", "value", "crit"] },
            { "meter": { "value": 0.32, "label": "week", "caption": "32%", "state": "ok" } },
            { "list": [ { "text": "print-lab", "note": "Personal", "icon": "wait", "state": "warn" } ] },
            { "spark": [30, 52, 41] },
            { "spark": { "values": [1, 2], "caption": "last hour" } },
            { "table": { "columns": [ {"title":"branch"}, {"title":"min","align":"trailing"} ],
                         "rows": [ ["release/1043", "12"] ] } },
            { "log": ["04:14 restic ok"] },
            { "canvas": { "kind": "svg", "payload": "<svg/>", "height": 80 } }
          ],
          "actions": [ { "label": "Open", "run": ["udeck-open", "42"], "confirm": "Sure?" } ] }
        """)
        #expect(c.state == .warn)
        #expect(c.chip == "17 waiting")
        #expect(c.ttl == 30)
        #expect(c.rows.count == 10)
        #expect(c.actions.first?.confirm == "Sure?")

        guard case .keyValue(let kv) = c.rows[2] else { Issue.record("expected a kv row"); return }
        #expect(kv.state == .crit)

        guard case .spark(let bare) = c.rows[5], case .spark(let named) = c.rows[6] else {
            Issue.record("expected two spark rows"); return
        }
        #expect(bare.values == [30, 52, 41])
        #expect(named.caption == "last hour")
    }

    @Test("a minimal card is legal: everything but the rows has a default")
    func minimalCard() throws {
        let c = try card("{}")
        #expect(c.state == .ok)
        #expect(c.rows.isEmpty)
        #expect(c.ttl == nil)
    }

    @Test("an unknown row type is kept as a visible diagnostic, not dropped")
    func unknownRowKept() throws {
        let c = try card("""
        { "rows": [ { "text": "before" }, { "hologram": {"x": 1} }, { "text": "after" } ] }
        """)
        #expect(c.rows.count == 3)
        guard case .unsupported(let kind) = c.rows[1] else { Issue.record("expected unsupported"); return }
        #expect(kind == "hologram")
    }

    @Test("a row with two type keys is an error, not a guess")
    func ambiguousRowRejected() {
        #expect(throws: DecodingError.self) {
            _ = try card(#"{ "rows": [ { "text": "one", "kv": ["a","b"] } ] }"#)
        }
    }

    @Test("a row with no type key is an error")
    func emptyRowRejected() {
        #expect(throws: DecodingError.self) {
            _ = try card(#"{ "rows": [ {} ] }"#)
        }
    }

    @Test("a meter outside 0…1 is clamped rather than rejecting the whole card")
    func meterClamped() throws {
        let c = try card(#"{ "rows": [ { "meter": { "value": 1.4 } }, { "meter": { "value": -2 } } ] }"#)
        guard case .meter(let high) = c.rows[0], case .meter(let low) = c.rows[1] else {
            Issue.record("expected two meters"); return
        }
        #expect(high.value == 1)
        #expect(low.value == 0)
    }

    @Test("a bad state name is rejected with a message that lists the legal ones")
    func badStateRejected() {
        #expect(throws: DecodingError.self) {
            _ = try card(#"{ "state": "catastrophic" }"#)
        }
    }

    @Test("an unknown icon is rejected rather than silently drawn as something else")
    func badIconRejected() {
        #expect(throws: DecodingError.self) {
            _ = try card(#"{ "rows": [ { "list": [ { "text": "x", "icon": "rocket" } ] } ] }"#)
        }
    }

    @Test("a card survives a round trip through JSON")
    func roundTrip() throws {
        let original = Card(
            state: .crit,
            chip: "1 failed",
            rows: [
                .text("hello"),
                .keyValue(KeyValueRow(label: "a", value: "b", state: .warn)),
                .meter(MeterRow(value: 0.5, label: "l")),
                .list([ListItem(text: "x", note: "n", icon: .wait)]),
                .spark(SparkRow(values: [1, 2, 3])),
                .table(TableRow(columns: [TableColumn(title: "c")], rows: [["v"]])),
                .log(["one"]),
            ],
            actions: [CardAction(label: "Go", run: ["true"])],
            ttl: 15
        )
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(Card.self, from: data) == original)
    }
}

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
