import Foundation
import Testing
@testable import UDeckPluginFormat

/// A badge that says more when clicked, and a meter made of parts (0.9.32):
/// the context badge of Agents, «25% · 249k / 1M», and what it is made of.
@Suite("A badge's details, and a meter's parts")
struct BadgeDetailsTests {
    let card = """
    {"rows":[{"bar":{"id":"status","items":[{"badge":{"text":"25% · 249k / 1M","fill":0.25,"details":[
      {"meter":{"value":0.27,"label":"Context","caption":"249k of 1M","parts":[
        {"value":0.232,"label":"Conversation","note":"232k","tone":"warn"},
        {"value":0.009,"label":"Skills","note":"9k","tone":"info"},
        {"value":0.033,"label":"Kept for compaction","note":"33k"}]}},
      {"kv":["Session","$114.5 · 25 h"]},
      {"bar":{"id":"context","items":[{"button":{"id":"compact","label":"Compact now"}},
                                      {"badge":{"text":"inner","details":[{"text":"never shown"}]}}]}}]}}]}}]}
    """

    func decode(_ text: String) throws -> Card {
        try JSONDecoder().decode(Card.self, from: Data(text.utf8))
    }

    func badge(_ card: Card) throws -> BarBadge {
        guard case .bar(let bar) = card.rows.first, case .badge(let badge)? = bar.items.first else {
            throw CardTestError("no badge")
        }
        return badge
    }

    @Test("a badge's details are rows, and a meter's parts each a share, a label, a note and a tone")
    func read() throws {
        let badge = try badge(try decode(card))
        let details = try #require(badge.details)
        #expect(details.count == 3)
        guard case .meter(let meter) = details[0] else { throw CardTestError("not a meter") }
        #expect(meter.parts?.map(\.label) == ["Conversation", "Skills", "Kept for compaction"])
        #expect(meter.parts?.map(\.note) == ["232k", "9k", "33k"])
        #expect(meter.parts?.map(\.tone) == [.warn, .info, nil])
        #expect(MeterPart(value: 1.4, label: "over").value == 1, "a share is clamped, as a meter's value is")
        #expect(BarBadge(text: "x", details: []).details == nil, "no rows, no details")
    }

    @Test("drawn within limits: one level of details, at most 24 rows, at most 12 parts")
    func limits() throws {
        let drawn = try decode(card).withinDrawingLimits()
        let details = try #require(try badge(drawn).details)
        guard case .bar(let inner) = details[2], case .badge(let nested)? = inner.items.last else {
            throw CardTestError("no inner badge")
        }
        #expect(nested.details == nil, "a badge in the rows a badge shows shows none")
        #expect(!drawn.rows.contains(.text("this card is longer than uDeck will draw and has been cut short")))

        let many = (0 ..< 30).map { _ in #"{"text":"row"}"# }.joined(separator: ",")
        let parts = (0 ..< 15).map { #"{"value":0.01,"label":"p\#($0)"}"# }.joined(separator: ",")
        let long = try decode(#"{"rows":[{"bar":{"id":"s","items":[{"badge":{"text":"b","details":[\#(many)]}}]}},"#
                              + #"{"meter":{"value":0.15,"parts":[\#(parts)]}}]}"#).withinDrawingLimits()
        #expect(try badge(long).details?.count == 24)
        guard case .meter(let meter) = long.rows[1] else { throw CardTestError("no meter") }
        #expect(meter.parts?.count == 12)
        #expect(long.rows.last == .text("this card is longer than uDeck will draw and has been cut short"))
    }

    @Test("what a card uses inside a badge's details is dated too")
    func used() throws {
        let object = try #require(StrictJSON.parse(Array(card.utf8)).value?.object)
        let used = ContractFeatures.used(byCard: object)
        for feature: ContractFeature in [.rowField(row: "bar.badge", field: "details"), .rowField(row: "meter", field: "parts"),
                                         .rowField(row: "meter.parts", field: "note"), .rowField(row: "bar.button", field: "label"),
                                         .row("kv")] {
            #expect(used.contains(feature), "\(feature)")
        }
    }
}

struct CardTestError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
