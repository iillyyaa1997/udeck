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

/// Markdown as a feed draws it: paragraphs, bullet and numbered lists,
/// headings and fenced code. Inline emphasis, code and links stay in the
/// text, for the view to read.
public enum MarkdownBlock: Equatable, Sendable {
    case paragraph(String)
    case bullet(String)
    case numbered(String, String)
    case heading(String)
    case code(String)

    public static func blocks(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var code: [String]?
        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))) }
            paragraph = []
        }
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if let lines = code {
                    blocks.append(.code(lines.joined(separator: "\n")))
                    code = nil
                } else {
                    flush()
                    code = []
                }
                continue
            }
            if code != nil { code?.append(raw); continue }
            if line.isEmpty { flush(); continue }
            if let rest = ["- ", "* ", "• "].lazy.compactMap({ line.hasPrefix($0) ? String(line.dropFirst($0.count)) : nil }).first {
                flush()
                blocks.append(.bullet(rest))
                continue
            }
            if let dot = line.firstIndex(of: "."), dot != line.startIndex, line[..<dot].allSatisfy(\.isNumber),
               line.index(after: dot) < line.endIndex, line[line.index(after: dot)] == " " {
                flush()
                blocks.append(.numbered(String(line[...dot]), String(line[line.index(dot, offsetBy: 2)...])))
                continue
            }
            if line.hasPrefix("#") {
                flush()
                blocks.append(.heading(line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)))
                continue
            }
            paragraph.append(raw)
        }
        // A fence still open — an answer streaming in — is code so far.
        if let lines = code { blocks.append(.code(lines.joined(separator: "\n"))) }
        flush()
        return blocks
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
