import Foundation

/// How a feed is laid out before it is drawn: entries in order, with two or
/// more operations in a row folded into one line that counts them. Pure, so
/// it is tested here rather than through the panel.
public enum FeedLayout {
    public enum Item: Identifiable, Equatable, Sendable {
        case entry(FeedEntry)
        case tools([FeedEntry])

        public var id: String {
            switch self {
            case .entry(let entry): entry.id
            case .tools(let entries): "tools-" + (entries.first?.id ?? "")
            }
        }
    }

    public static func items(_ entries: [FeedEntry]) -> [Item] {
        var items: [Item] = []
        var run: [FeedEntry] = []
        func flush() {
            if run.count >= 2 { items.append(.tools(run)) } else { items += run.map(Item.entry) }
            run = []
        }
        for entry in entries {
            if entry.role == .tool { run.append(entry); continue }
            flush()
            items.append(.entry(entry))
        }
        flush()
        return items
    }

    /// «Bash ×2, Read ×2»: the operations of a folded run by name, in the
    /// order they first came. An entry without a `name` is named by its
    /// text's first word.
    public static func toolSummary(_ entries: [FeedEntry]) -> String {
        var order: [String] = []
        var counts: [String: Int] = [:]
        for entry in entries {
            let name = entry.name ?? String(entry.text.split(separator: " ").first ?? "")
            if counts[name] == nil { order.append(name) }
            counts[name, default: 0] += 1
        }
        return order.map { counts[$0, default: 0] > 1 ? "\($0) ×\(counts[$0, default: 0])" : $0 }
            .joined(separator: ", ")
    }
}

/// Markdown as a feed draws it: paragraphs, bullet and numbered lists — nested
/// by their indent — headings, fenced code with its language, tables, quotes
/// and rules (0.9.27; tables, quotes and rules were drawn as their raw text
/// before, «| Что | Статус |»). Inline emphasis, code and links stay in the
/// text, for the view to read.
public enum MarkdownBlock: Equatable, Sendable {
    case paragraph(String)
    case bullet(String, level: Int = 0)
    case numbered(String, String, level: Int = 0)
    case heading(String, level: Int = 1)
    case code(String, language: String = "")
    /// A table: its header's cells, then each row's, as many as the header
    /// has — a row with fewer is filled, one with more cut.
    case table(header: [String], rows: [[String]])
    case quote(String)
    case rule

    public static func blocks(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var quote: [String] = []
        var code: (language: String, lines: [String])?
        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))) }
            paragraph = []
            if !quote.isEmpty { blocks.append(.quote(quote.joined(separator: "\n"))) }
            quote = []
        }
        let lines = text.components(separatedBy: "\n")
        var index = 0
        while index < lines.count {
            let raw = lines[index]
            index += 1
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if let open = code {
                    blocks.append(.code(open.lines.joined(separator: "\n"), language: open.language))
                    code = nil
                } else {
                    flush()
                    code = (String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces), [])
                }
                continue
            }
            if code != nil { code?.lines.append(raw); continue }
            if line.isEmpty { flush(); continue }
            // A table: a row of cells, then the line under its header.
            if line.hasPrefix("|"), index < lines.count, isTableRule(lines[index]) {
                flush()
                let header = cells(line)
                index += 1
                var rows: [[String]] = []
                while index < lines.count {
                    let next = lines[index].trimmingCharacters(in: .whitespaces)
                    guard next.hasPrefix("|") else { break }
                    var row = cells(next)
                    if row.count < header.count { row += Array(repeating: "", count: header.count - row.count) }
                    rows.append(Array(row.prefix(header.count)))
                    index += 1
                }
                blocks.append(.table(header: header, rows: rows))
                continue
            }
            if isRule(line) { flush(); blocks.append(.rule); continue }
            if line.hasPrefix(">") {
                if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph = [] }
                quote.append(String(line.dropFirst()).trimmingCharacters(in: .whitespaces))
                continue
            }
            let level = indentLevel(raw)
            if let rest = ["- ", "* ", "• "].lazy.compactMap({ line.hasPrefix($0) ? String(line.dropFirst($0.count)) : nil }).first {
                flush()
                blocks.append(.bullet(rest, level: level))
                continue
            }
            if let dot = line.firstIndex(of: "."), dot != line.startIndex, line[..<dot].allSatisfy(\.isNumber),
               line.index(after: dot) < line.endIndex, line[line.index(after: dot)] == " " {
                flush()
                blocks.append(.numbered(String(line[...dot]), String(line[line.index(dot, offsetBy: 2)...]), level: level))
                continue
            }
            if line.hasPrefix("#") {
                flush()
                let hashes = line.prefix(while: { $0 == "#" }).count
                blocks.append(.heading(line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces),
                                       level: min(max(hashes, 1), 6)))
                continue
            }
            if !quote.isEmpty { flush() }
            paragraph.append(raw)
        }
        // A fence still open — an answer streaming in — is code so far.
        if let open = code { blocks.append(.code(open.lines.joined(separator: "\n"), language: open.language)) }
        flush()
        return blocks
    }

    /// `---`, `***` or `___`, three or more, alone on the line.
    static func isRule(_ line: String) -> Bool {
        let bare = line.replacingOccurrences(of: " ", with: "")
        guard bare.count >= 3, let first = bare.first, "-*_".contains(first) else { return false }
        return bare.allSatisfy { $0 == first }
    }

    /// The line under a table's header: `|---|:--:|`.
    static func isTableRule(_ raw: String) -> Bool {
        let line = raw.trimmingCharacters(in: .whitespaces)
        guard line.hasPrefix("|") || line.hasPrefix("-") || line.hasPrefix(":") else { return false }
        let parts = cells(line)
        return !parts.isEmpty && parts.allSatisfy { cell in
            let bare = cell.replacingOccurrences(of: ":", with: "")
            return bare.count >= 1 && bare.allSatisfy { $0 == "-" }
        }
    }

    /// A table row's cells: split at `|`, not at an escaped `\|`.
    static func cells(_ line: String) -> [String] {
        var body = line.trimmingCharacters(in: .whitespaces)
        if body.hasPrefix("|") { body.removeFirst() }
        if body.hasSuffix("|"), !body.hasSuffix("\\|") { body.removeLast() }
        var cells: [String] = []
        var current = ""
        var escaped = false
        for character in body {
            if escaped { current.append(character); escaped = false; continue }
            if character == "\\" { escaped = true; continue }
            if character == "|" { cells.append(current.trimmingCharacters(in: .whitespaces)); current = ""; continue }
            current.append(character)
        }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }

    /// How deep a list item sits: two spaces, or a tab, a level.
    static func indentLevel(_ raw: String) -> Int {
        var spaces = 0
        for character in raw {
            if character == " " { spaces += 1 } else if character == "\t" { spaces += 4 } else { break }
        }
        return min(spaces / 2, 4)
    }
}

/// The rows of a card with a key that stays with each from one card to the
/// next: a row that takes input keeps its own (`input:message`), so a
/// question arriving above the field does not make it a new field and throw
/// away what is being typed — which keying by position did (0.9.5).
public enum CardRowKeys {
    public static func keyed(_ rows: [CardRow]) -> [(key: String, row: CardRow)] {
        var seen: Set<String> = []
        return rows.enumerated().map { index, row in
            var key: String
            switch row {
            case .input(let input): key = "input:" + input.id
            case .ask(let ask): key = "ask:" + ask.id
            case .bar(let bar): key = "bar:" + bar.id
            case .feed: key = "feed"
            default: key = "row:\(index)"
            }
            if seen.contains(key) { key += ":\(index)" }
            seen.insert(key)
            return (key, row)
        }
    }
}
