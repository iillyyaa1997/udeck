import Foundation
import Testing
@testable import UDeckPluginFormat
import UDeckPluginFormatFixtures

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
                .table(CardTable(columns: [CardTableColumn(title: "c")], rows: [["v"]])),
                .log(["one"]),
            ],
            actions: [CardAction(label: "Go", run: ["true"])],
            ttl: 15
        )
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(Card.self, from: data) == original)
    }
}
