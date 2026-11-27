import Foundation
import Testing
@testable import UDeckPluginFormat

/// Bars, menus, badges, an input with menus, and the `choose` event: what a
/// resident plugin's card may say about itself beyond a feed (0.9.4).
@Suite("Bars and menus")
struct BarRowTests {
    static let header = #"""
    {"rows":[
      {"bar":{"id":"head","items":[
        {"title":{"text":"Screenshot","tone":"run"}},
        {"menu":{"id":"session","text":"Sessions","options":[
          {"id":"s:1","text":"Screenshot","group":"Open","tone":"run"},
          {"id":"h:2","text":"Old one","group":"History","note":"yesterday"}],"selected":"s:1"}},
        {"tag":"Claude"},
        {"badge":{"text":"1","tone":"wait"}},
        {"spacer":true},
        {"button":{"id":"new","icon":"plus","options":[{"id":"new:claude","text":"Claude"}]}}]}},
      {"bar":{"id":"status","items":[
        {"badge":{"text":"Working 0:42","tone":"run","icon":"run"}},
        {"badge":{"text":"context 14%","tone":"info","fill":1.7}}]}},
      {"feed":[
        {"id":"t1","role":"tool","text":"Bash  ls","name":"Bash"},
        {"id":"a1","role":"assistant","text":"**Done**","label":"Codex"}]},
      {"input":{"id":"message","pickers":[
        {"id":"model","text":"Opus 5.5","icon":"model","options":[{"id":"opus","text":"Opus 5.5"}],
         "selected":"opus","note":"right away"}]}}
    ]}
    """#

    func card() throws -> Card {
        try JSONDecoder().decode(Card.self, from: Data(Self.header.utf8))
    }

    @Test("a bar reads its title, menu, tag, badge, spacer and button in order")
    func barReads() throws {
        guard case .bar(let bar) = try card().rows[0] else { Issue.record("not a bar"); return }
        #expect(bar.id == "head")
        #expect(bar.items.count == 6)
        #expect(bar.items[0] == .title(BarTitle(text: "Screenshot", tone: .run)))
        guard case .menu(let menu) = bar.items[1] else { Issue.record("not a menu"); return }
        #expect(menu.options.map(\.group) == ["Open", "History"])
        #expect(menu.selected == "s:1")
        #expect(bar.items[2] == .tag("Claude"))
        #expect(bar.items[4] == .spacer)
        guard case .button(let button) = bar.items[5] else { Issue.record("not a button"); return }
        #expect(button.icon == .plus)
        #expect(button.options?.first?.id == "new:claude")
    }

    @Test("a badge's fill is held to 0…1, as a meter's value is")
    func fillIsClamped() throws {
        guard case .bar(let bar) = try card().rows[1], case .badge(let badge) = bar.items[1] else {
            Issue.record("not a badge"); return
        }
        #expect(badge.fill == 1)
    }

    @Test("a feed entry carries a tool's name and an answer's label; an input carries its menus")
    func feedAndInput() throws {
        let rows = try card().rows
        guard case .feed(let entries) = rows[2], case .input(let input) = rows[3] else {
            Issue.record("rows out of place"); return
        }
        #expect(entries[0].name == "Bash")
        #expect(entries[1].label == "Codex")
        #expect(input.pickers?.first?.note == "right away")
        #expect(input.pickers?.first?.icon == .model)
    }

    @Test("an item uDeck does not know is kept as unsupported, not a failure of the whole card")
    func unknownItem() throws {
        let json = #"{"rows":[{"bar":{"id":"b","items":[{"slider":{"value":1}},{"tag":"x"}]}}]}"#
        let card = try JSONDecoder().decode(Card.self, from: Data(json.utf8))
        guard case .bar(let bar) = card.rows[0] else { Issue.record("not a bar"); return }
        #expect(bar.items == [.unsupported(kind: "slider"), .tag("x")])
    }

    @Test("a bar round-trips through encoding")
    func roundTrip() throws {
        let card = try card()
        let again = try JSONDecoder().decode(Card.self, from: JSONEncoder().encode(card))
        #expect(again == card)
    }

    @Test("a choose event names the row, the menu and the option")
    func chooseLine() {
        let line = ResidentEvent.choose(row: "message", menu: "model", option: "opus").line
        #expect(line == #"{"event":"choose","menu":"model","option":"opus","row":"message"}"#)
    }

    @Test("too many items, options or pickers are cut, and the card says so")
    func limits() {
        let options = (0..<150).map { MenuOption(id: "o\($0)", text: "o\($0)") }
        let items = (0..<20).map { BarItem.tag("t\($0)") }
        let pickers = (0..<6).map { CardMenu(id: "p\($0)", text: "p", options: options) }
        let card = Card(rows: [.bar(BarRow(id: "b", items: items + [.menu(CardMenu(id: "m", text: "m", options: options))])),
                               .input(InputRow(id: "i", pickers: pickers))])
        let drawn = card.withinDrawingLimits()
        guard case .bar(let bar) = drawn.rows[0], case .input(let input) = drawn.rows[1] else {
            Issue.record("rows out of place"); return
        }
        #expect(bar.items.count == CardLimits.barItems)
        #expect(input.pickers?.count == CardLimits.pickers)
        #expect(input.pickers?.first?.options.count == CardLimits.menuOptions)
        #expect(drawn.rows.last == .text("this card is longer than uDeck will draw and has been cut short"))
    }

    @Test("a feed entry's files: read, cut to twenty by the drawing limits, a contract field of 0.9.23")
    func feedFiles() throws {
        let json = #"{"rows":[{"feed":[{"id":"1","role":"user","text":"look","files":["/tmp/a.png","/tmp/b.txt"]}]}]}"#
        let card = try JSONDecoder().decode(Card.self, from: Data(json.utf8))
        guard case .feed(let entries) = card.rows[0] else {
            Issue.record("not a feed")
            return
        }
        #expect(entries.first?.files == ["/tmp/a.png", "/tmp/b.txt"])
        #expect(card.withinDrawingLimits() == card)
        let many = Card(rows: [.feed([FeedEntry(id: "1", role: .user, text: "x", files: (0..<25).map { "/tmp/\($0).png" })])])
        guard case .feed(let cut) = many.withinDrawingLimits().rows[0] else {
            Issue.record("not a feed")
            return
        }
        #expect(cut.first?.files?.count == 20)
        let object = try #require(StrictJSON.parse(Array(json.utf8)).value?.object)
        #expect(ContractFeatures.used(byCard: object).contains(.rowField(row: "feed", field: "files")))
        #expect(ContractFeatures.release(of: .rowField(row: "feed", field: "files")) == .released(SemanticVersion(major: 0, minor: 9, patch: 23)))
    }

    @Test("an input's fill: read, kept through the drawing limits with its files, and a new contract field")
    func inputFill() throws {
        let json = #"{"rows":[{"input":{"id":"message","files":true,"fill":{"id":"unsent-3","text":"one\ntwo"}}}]}"#
        let card = try JSONDecoder().decode(Card.self, from: Data(json.utf8))
        guard case .input(let input) = card.rows[0] else {
            Issue.record("not an input")
            return
        }
        #expect(input.fill == InputFill(id: "unsent-3", text: "one\ntwo"))
        // The limits used to rebuild an input without its `files` (0.9.17–0.9.18).
        #expect(card.withinDrawingLimits() == card)
        let long = Card(rows: [.input(InputRow(id: "i", fill: InputFill(id: "f", text: String(repeating: "a", count: 30_000))))])
        guard case .input(let cut) = long.withinDrawingLimits().rows[0] else {
            Issue.record("not an input")
            return
        }
        #expect(cut.fill?.text.count == CardLimits.feedTextLength + 1)
        let object = try #require(StrictJSON.parse(Array(json.utf8)).value?.object)
        let used = ContractFeatures.used(byCard: object)
        #expect(used.contains(.rowField(row: "input", field: "fill")))
        #expect(used.contains(.rowField(row: "input.fill", field: "text")))
        #expect(ContractFeatures.release(of: .rowField(row: "input.fill", field: "id")) == .released(SemanticVersion(major: 0, minor: 9, patch: 19)))
    }

    @Test("an input that takes files says so; submit carries their paths, and only when there are some")
    func inputFiles() throws {
        let json = #"{"rows":[{"input":{"id":"message","placeholder":"Message","files":true}}]}"#
        let card = try JSONDecoder().decode(Card.self, from: Data(json.utf8))
        guard case .input(let input) = card.rows[0] else {
            Issue.record("not an input")
            return
        }
        #expect(input.files == true)
        #expect(ResidentEvent.submit(row: "message", text: "look", files: ["/tmp/a.png", "/tmp/b.txt"]).line
                    == #"{"event":"submit","files":["\/tmp\/a.png","\/tmp\/b.txt"],"row":"message","text":"look"}"#)
        #expect(ResidentEvent.submit(row: "message", text: "look").line == #"{"event":"submit","row":"message","text":"look"}"#)
        let object = try #require(StrictJSON.parse(Array(json.utf8)).value?.object)
        #expect(ContractFeatures.used(byCard: object).contains(.rowField(row: "input", field: "files")))
    }

    @Test("a menu option's button reads with it; one that is not a button is left out, the option kept")
    func optionButton() throws {
        let json = #"""
        {"rows":[{"bar":{"id":"head","items":[{"menu":{"id":"session","text":"","options":[
          {"id":"s:1","text":"One","button":{"id":"close:1","label":"✕"}},
          {"id":"s:2","text":"Two","button":"✕"}]}}]}}]}
        """#
        let card = try JSONDecoder().decode(Card.self, from: Data(json.utf8))
        guard case .bar(let bar) = card.rows[0], case .menu(let menu) = bar.items[0] else {
            Issue.record("not a bar with a menu")
            return
        }
        #expect(menu.options[0].button == MenuOptionButton(id: "close:1", label: "✕"))
        #expect(menu.options[1].button == nil && menu.options[1].text == "Two")
        let again = try JSONDecoder().decode(Card.self, from: JSONEncoder().encode(card))
        #expect(again == card)
        let object = try #require(StrictJSON.parse(Array(json.utf8)).value?.object)
        let used = ContractFeatures.used(byCard: object)
        #expect(used.contains(.rowField(row: "menu.options", field: "button")))
        #expect(used.contains(.rowField(row: "menu.options.button", field: "label")))
    }

    @Test("a badge that is busy and has shorter forms: read, kept to four forms, dated to the release that brought them")
    func busyAndShorter() throws {
        let json = #"""
        {"rows":[{"bar":{"id":"live","items":[{"badge":{"text":"Думает 0:41 · всего 32:26 · ↓ ~30,7 тыс. токенов",
          "tone":"run","busy":true,"shorter":["Думает 0:41 · всего 32:26 · ↓ ~30,7 тыс.","Думает 0:41 · ↓ ~30,7 тыс.",
          "Думает 0:41","","a","b"]}}]}}]}
        """#
        let card = try JSONDecoder().decode(Card.self, from: Data(json.utf8))
        guard case .bar(let bar) = card.rows[0], case .badge(let badge) = bar.items[0] else {
            Issue.record("not a badge"); return
        }
        #expect(badge.busy == true)
        #expect(badge.shorter?.count == 6)
        #expect(badge.forms.count == 6, "the text and its forms, an empty one left out")
        let drawn = card.withinDrawingLimits()
        guard case .bar(let kept) = drawn.rows[0], case .badge(let cut) = kept.items[0] else {
            Issue.record("not a badge"); return
        }
        #expect(cut.shorter == ["Думает 0:41 · всего 32:26 · ↓ ~30,7 тыс.", "Думает 0:41 · ↓ ~30,7 тыс.", "Думает 0:41", ""])
        #expect(cut.busy == true)
        let object = try #require(StrictJSON.parse(Array(json.utf8)).value?.object)
        let used = ContractFeatures.used(byCard: object)
        #expect(used.contains(.rowField(row: "bar.badge", field: "busy")))
        #expect(used.contains(.rowField(row: "bar.badge", field: "shorter")))
        #expect(ContractFeatures.release(of: .rowField(row: "bar.badge", field: "busy")) == .released(SemanticVersion(major: 0, minor: 9, patch: 24)))
    }

    @Test("a card with a bar needs the release that brought bars")
    func barIsDated() throws {
        let object = try #require(StrictJSON.parse(Array(Self.header.utf8)).value?.object)
        let used = ContractFeatures.used(byCard: object)
        #expect(used.contains(.row("bar")))
        #expect(used.contains(.rowField(row: "bar.items", field: "menu")))
        #expect(used.contains(.rowField(row: "menu.options", field: "group")))
        #expect(used.contains(.rowField(row: "bar.badge", field: "fill")))
        #expect(used.contains(.rowField(row: "input", field: "pickers")))
        #expect(used.contains(.rowField(row: "feed", field: "label")))
        #expect(used.contains(.tone("wait")))
        #expect(used.contains(.barIcon("plus")))
        #expect(ContractFeatures.release(of: .row("bar")) == .released(SemanticVersion(major: 0, minor: 9, patch: 4)))
    }
}
