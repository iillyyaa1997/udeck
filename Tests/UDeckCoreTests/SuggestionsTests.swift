import Foundation
import Testing
import UDeckCore
import UDeckPluginFormat

@Suite("A field's suggestions")
struct SuggestionsTests {
    let tabs = [SuggestTab(id: "commands", title: "Команды", trigger: "/", start: true),
                SuggestTab(id: "skills", title: "Скилы", trigger: "/", start: true),
                SuggestTab(id: "files", title: "Файлы", trigger: "@", search: true)]

    @Test("«/» opens the tabs it is the trigger of only at the start; «@» after a space anywhere; a space ends it")
    func token() throws {
        let slash = try #require(Suggestions.token(in: "/co", caret: 3, tabs: tabs))
        #expect(slash.trigger == "/" && Set(slash.tabs) == ["commands", "skills"] && slash.query == "co")
        #expect(slash.range == NSRange(location: 0, length: 3))
        #expect(Suggestions.token(in: "  /co", caret: 5, tabs: tabs)?.range == NSRange(location: 2, length: 3))
        #expect(Suggestions.token(in: "look /co", caret: 8, tabs: tabs) == nil, "a command only at the start")
        #expect(Suggestions.token(in: "/compact now", caret: 12, tabs: tabs) == nil, "a space ends it")
        let at = try #require(Suggestions.token(in: "почини @grid", caret: 12, tabs: tabs))
        #expect(at.tabs == ["files"] && at.query == "grid")
        #expect(at.range == NSRange(location: 7, length: 5))
        #expect(Suggestions.token(in: "mail@host", caret: 9, tabs: tabs) == nil, "inside a word it is not a trigger")
        let empty = try #require(Suggestions.token(in: "@", caret: 1, tabs: tabs))
        #expect(empty.query == "")
        // The caret in the middle: what is before it counts.
        #expect(Suggestions.token(in: "/co rest", caret: 3, tabs: tabs)?.query == "co")
    }

    @Test("ranked: a name that starts with it, a word that does, a name that has it, a line that has it")
    func rank() {
        let items = [SuggestItem(id: "1", tab: "skills", text: "/code-review", detail: "Review the current diff"),
                     SuggestItem(id: "2", tab: "commands", text: "/context", detail: "сколько занято контекста"),
                     SuggestItem(id: "3", tab: "commands", text: "/compact", detail: "сжать разговор"),
                     SuggestItem(id: "4", tab: "skills", text: "/u-place-dev:u-place-dev", detail: "deploys"),
                     SuggestItem(id: "5", tab: "skills", text: "/simplify", detail: "for reuse and review")]
        #expect(Suggestions.rank(items, query: "co", triggers: ["/"]).map(\.id) == ["1", "2", "3"])
        #expect(Suggestions.rank(items, query: "REVIEW", triggers: ["/"]).map(\.id) == ["1", "5"])
        #expect(Suggestions.rank(items, query: "place", triggers: ["/"]).map(\.id) == ["4"])
        #expect(Suggestions.rank(items, query: "ntex", triggers: ["/"]).map(\.id) == ["2"])
        #expect(Suggestions.rank(items, query: "", triggers: ["/"]).count == 5)
    }

    @Test("a pick replaces the token and leaves a space; with none, a command goes first and a file at the caret")
    func insert() {
        let command = SuggestItem(id: "c", tab: "commands", text: "/compact")
        let file = SuggestItem(id: "f", tab: "files", text: "@Sources/Layout/GridRows.swift")
        let token = Suggestions.token(in: "/co", caret: 3, tabs: tabs)
        #expect(Suggestions.insert(command, into: "/co", caret: 3, token: token, atStart: true) == ("/compact ", 9))
        let at = Suggestions.token(in: "почини @gr тут", caret: 10, tabs: tabs)
        let picked = Suggestions.insert(file, into: "почини @gr тут", caret: 10, token: at, atStart: false)
        #expect(picked.text == "почини @Sources/Layout/GridRows.swift тут")
        #expect(picked.caret == ("почини @Sources/Layout/GridRows.swift" as NSString).length)
        #expect(Suggestions.insert(command, into: "сожми всё", caret: 3, token: nil, atStart: true) == ("/compact сожми всё", 9))
        #expect(Suggestions.insert(file, into: "почини", caret: 6, token: nil, atStart: false).text
            == "почини @Sources/Layout/GridRows.swift ")
        #expect(Suggestions.insert(file, into: "", caret: 0, token: nil, atStart: false).text == "@Sources/Layout/GridRows.swift ")
    }
}
