import Foundation
import Testing
@testable import UDeckCore

@Suite("Feed layout")
struct FeedLayoutTests {
    func tool(_ id: String, _ name: String?, _ text: String = "x") -> FeedEntry {
        FeedEntry(id: id, role: .tool, text: text, name: name)
    }

    @Test("two or more operations in a row fold into one item; one alone stays as it is")
    func folding() {
        let entries = [
            FeedEntry(id: "u", role: .user, text: "look"),
            tool("t1", "Bash"), tool("t2", "Read"), tool("t3", "Bash"),
            FeedEntry(id: "a", role: .assistant, text: "done"),
            tool("t4", "Edit"),
        ]
        let items = FeedLayout.items(entries)
        #expect(items.map(\.id) == ["u", "tools-t1", "a", "t4"])
        guard case .tools(let run) = items[1] else { Issue.record("not folded"); return }
        #expect(run.map(\.id) == ["t1", "t2", "t3"])
    }

    @Test("a folded run is counted by name, in the order names first came")
    func summary() {
        #expect(FeedLayout.toolSummary([tool("1", "Bash"), tool("2", "Read"), tool("3", "Bash"), tool("4", "Read")])
                == "Bash ×2, Read ×2")
        #expect(FeedLayout.toolSummary([tool("1", nil, "Grep pattern"), tool("2", "Edit")]) == "Grep, Edit")
    }

    @Test("markdown blocks: paragraphs, lists, headings, code")
    func blocks() {
        let text = """
        Причина найдена: **ttl**
        и вторая строка

        Чиню:
        - пока процесс работает
        * процесс умер
        1. первое
        12. двенадцатое
        ## Итог
        ```swift
        let x = 1
        ```
        """
        #expect(MarkdownBlock.blocks(text) == [
            .paragraph("Причина найдена: **ttl**\nи вторая строка"),
            .paragraph("Чиню:"),
            .bullet("пока процесс работает"),
            .bullet("процесс умер"),
            .numbered("1.", "первое"),
            .numbered("12.", "двенадцатое"),
            .heading("Итог"),
            .code("let x = 1"),
        ])
    }

    @Test("a fence still open while an answer streams is code so far; 3.5 is no list")
    func openFence() {
        #expect(MarkdownBlock.blocks("Смотри:\n```\nls -la") == [.paragraph("Смотри:"), .code("ls -la")])
        #expect(MarkdownBlock.blocks("3.5 раза") == [.paragraph("3.5 раза")])
    }

    @Test("Russian counts operations with the right ending")
    func russianCount() {
        let ru = Russian()
        #expect(ru(.feedActions(count: 1)) == "1 действие")
        #expect(ru(.feedActions(count: 3)) == "3 действия")
        #expect(ru(.feedActions(count: 5)) == "5 действий")
        #expect(ru(.feedActions(count: 11)) == "11 действий")
        #expect(ru(.feedActions(count: 22)) == "22 действия")
    }

    @Test("a field keeps its key when a question arrives above it, so what is typed in it stays")
    func fieldKeepsItsKey() {
        let before: [CardRow] = [.feed([]), .input(InputRow(id: "message"))]
        let after: [CardRow] = [.feed([]), .ask(AskRow(id: "q1", title: "Which?", buttons: [])), .input(InputRow(id: "message"))]
        let field = { (rows: [CardRow]) in CardRowKeys.keyed(rows).first { if case .input = $0.row { true } else { false } }?.key }
        #expect(field(before) == "input:message")
        #expect(field(after) == "input:message")
        #expect(CardRowKeys.keyed([.text("a"), .text("b")]).map(\.key) == ["row:0", "row:1"])
        #expect(CardRowKeys.keyed([.feed([]), .feed([])]).map(\.key) == ["feed", "feed:1"])
    }
}

