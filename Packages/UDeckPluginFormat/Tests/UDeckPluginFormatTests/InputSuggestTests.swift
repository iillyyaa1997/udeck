import Foundation
import Testing
@testable import UDeckPluginFormat

/// What a field suggests (0.9.25): read, held to the drawing limits, dated,
/// and the `suggest` event a searched tab sends.
@Suite("A field's suggestions")
struct InputSuggestTests {
    static let json = #"""
    {"rows":[{"input":{"id":"message","suggest":{
      "tabs":[{"id":"commands","title":"Команды","trigger":"/","start":true},
              {"id":"files","title":"Файлы","trigger":"@","search":true}],
      "items":[{"id":"c:compact","tab":"commands","text":"/compact","detail":"сжать разговор","note":"claude"}],
      "recent":["c:compact"],
      "found":{"tab":"files","query":"grid","items":[{"id":"f:0","tab":"files","text":"@GridRows.swift",
        "title":"GridRows.swift","detail":"Sources/Layout"}]}}}}]}
    """#

    @Test("read whole: tabs with their triggers, items, recent ones, what was found")
    func reads() throws {
        let card = try JSONDecoder().decode(Card.self, from: Data(Self.json.utf8))
        guard case .input(let input) = card.rows[0], let suggest = input.suggest else { Issue.record("no suggest"); return }
        #expect(suggest.tabs.map(\.id) == ["commands", "files"])
        #expect(suggest.tabs[0].trigger == "/" && suggest.tabs[0].start == true && suggest.tabs[1].search == true)
        #expect(suggest.items?.first?.detail == "сжать разговор" && suggest.items?.first?.note == "claude")
        #expect(suggest.recent == ["c:compact"])
        #expect(suggest.found?.query == "grid" && suggest.found?.items.first?.title == "GridRows.swift")
        let again = try JSONDecoder().decode(Card.self, from: JSONEncoder().encode(card))
        #expect(again == card)
    }

    @Test("held to the drawing limits: 500 items, 100 found, 20 recent, 8 tabs")
    func limits() throws {
        let items = (0..<600).map { SuggestItem(id: "i\($0)", tab: "commands", text: "/c\($0)") }
        let found = SuggestFound(tab: "files", query: "", items: (0..<150).map { SuggestItem(id: "f\($0)", tab: "files", text: "@f\($0)") })
        let tabs = (0..<10).map { SuggestTab(id: "t\($0)", title: "T\($0)") }
        let suggest = InputSuggest(tabs: tabs, items: items, recent: (0..<30).map { "i\($0)" }, found: found)
        let card = Card(rows: [.input(InputRow(id: "message", suggest: suggest))]).withinDrawingLimits()
        guard case .input(let input) = card.rows[0], let kept = input.suggest else { Issue.record("no suggest"); return }
        #expect(kept.items?.count == 500 && kept.found?.items.count == 100 && kept.recent?.count == 20 && kept.tabs.count == 8)
        #expect(card.rows.count == 2, "the cut said in a row")
    }

    @Test("dated to the next release, every field of it")
    func dated() throws {
        let object = try #require(StrictJSON.parse(Array(Self.json.utf8)).value?.object)
        let used = ContractFeatures.used(byCard: object)
        for feature: ContractFeature in [.rowField(row: "input", field: "suggest"), .rowField(row: "input.suggest", field: "found"),
                                         .rowField(row: "input.suggest.tabs", field: "trigger"),
                                         .rowField(row: "input.suggest.items", field: "note"),
                                         .rowField(row: "input.suggest.found", field: "query")] {
            #expect(used.contains(feature), "\(feature)")
            #expect(ContractFeatures.release(of: feature) == .next, "\(feature)")
        }
    }

    @Test("the suggest event: the row, the tab as its id, the query as its text")
    func event() throws {
        let line = ResidentEvent.suggest(row: "message", tab: "files", query: "grid").line
        #expect(line == #"{"event":"suggest","id":"files","row":"message","text":"grid"}"#)
    }
}
