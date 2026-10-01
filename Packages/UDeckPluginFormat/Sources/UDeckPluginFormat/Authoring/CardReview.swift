#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// What uDeck forgives in a card without a word — said out loud, for the
/// card's author, by `udeck-plugin run`.
///
/// uDeck is lenient with a card on purpose: a card that is mostly right should
/// still be drawn. The price is that a mistake in one is drawn too, quietly: a
/// key spelt `stat` is not the `state` it was meant to be, so the card is
/// `ok`; `tll` is no `ttl`, so the card goes stale after the host's default; a
/// row type it does not know is a note in its place; and what is past a limit
/// is cut. Each of those is found here from the card the producer printed.
public enum CardReview {
    /// The keys a card is read with, object by object, as its types decode
    /// them. Anything else in one of those objects, uDeck ignores.
    static let cardKeys = Card.CodingKeys.allCases.map(\.rawValue)
    static let rowKinds = CardRow.Kind.allCases.map(\.rawValue)
    static let objectKeys: [String: [String]] = [
        "meter": MeterRow.CodingKeys.allCases.map(\.rawValue),
        "spark": SparkRow.CodingKeys.allCases.map(\.rawValue),
        "table": CardTable.CodingKeys.allCases.map(\.rawValue),
        "canvas": CanvasRow.CodingKeys.allCases.map(\.rawValue),
    ]
    static let listItemKeys = ListItem.CodingKeys.allCases.map(\.rawValue)
    static let columnKeys = CardTableColumn.CodingKeys.allCases.map(\.rawValue)
    static let actionKeys = CardAction.CodingKeys.allCases.map(\.rawValue)

    /// What uDeck reads past in `stdout`, a card it reads: keys it ignores,
    /// row types it does not draw, and keys given twice. Nothing when `stdout`
    /// is not a card.
    public static func forgiven(in stdout: Data) -> [String] {
        let text = Array(Blank.trimmed(String(decoding: stdout, as: UTF8.self)).utf8)
        let document = StrictJSON.parse(text)
        guard let card = document.value?.object else { return [] }
        var said: [String] = []
        for problem in document.problems {
            // "gives the field "x" more than once", of whichever object it is in.
            said.append("the card \(problem) in one object; uDeck reads one of the values and says nothing "
                        + "about the other")
        }
        unknown(in: card, known: cardKeys, at: "", &said)
        for (index, row) in (card.first("rows")?.array ?? []).enumerated() {
            guard let object = row.object, object.keys.count == 1, let kind = object.keys.first else { continue }
            let path = "rows[\(index)]"
            guard rowKinds.contains(kind) else {
                said.append("\(path) is of the type \"\(kind)\", which uDeck does not draw: it shows a note in its place"
                            + suggestion(for: kind, among: rowKinds))
                continue
            }
            let body = object.first(kind)
            switch kind {
            case "list":
                for (item, value) in (body?.array ?? []).enumerated() {
                    if let entry = value.object { unknown(in: entry, known: listItemKeys, at: "\(path).list[\(item)]", &said) }
                }
            case "table":
                guard let table = body?.object else { continue }
                unknown(in: table, known: objectKeys["table"] ?? [], at: "\(path).table", &said)
                for (column, value) in (table.first("columns")?.array ?? []).enumerated() {
                    if let entry = value.object { unknown(in: entry, known: columnKeys, at: "\(path).table.columns[\(column)]", &said) }
                }
            default:
                if let known = objectKeys[kind], let entry = body?.object {
                    unknown(in: entry, known: known, at: "\(path).\(kind)", &said)
                }
            }
        }
        for (index, value) in (card.first("actions")?.array ?? []).enumerated() {
            if let action = value.object { unknown(in: action, known: actionKeys, at: "actions[\(index)]", &said) }
        }
        return said
    }

    /// What the card in `stdout` uses that a uDeck the manifest's `minUDeck`
    /// lets the plugin onto does not have, if anything.
    public static func needsNewerUDeck(_ stdout: Data, manifest: PluginManifest) -> String? {
        let text = Array(Blank.trimmed(String(decoding: stdout, as: UTF8.self)).utf8)
        guard let card = StrictJSON.parse(text).value?.object else { return nil }
        return ContractFeatures.cardNeedsNewerUDeck(card, minUDeck: manifest.minUDeck)
    }

    /// What uDeck cuts from `card` to draw it (`Card.withinDrawingLimits`),
    /// one sentence for each limit a part of it is past. Empty exactly when
    /// uDeck draws the card as it is.
    public static func cut(from card: Card, limits: CardLimits = .standard) -> [String] {
        var said: [String] = []
        var longTexts: [String] = []
        func text(_ value: String?, _ path: String) {
            guard let value, value.count > limits.textLength else { return }
            longTexts.append("\(path) (\(value.count))")
        }
        text(card.title, "title")
        text(card.chip, "chip")
        if card.rows.count > limits.rows {
            said.append("the card has \(card.rows.count) rows, and uDeck draws the first \(limits.rows)")
        }
        for (index, row) in card.rows.prefix(limits.rows).enumerated() {
            let path = "rows[\(index)]"
            switch row {
            case .text(let value):
                text(value, "\(path).text")
            case .keyValue(let kv):
                text(kv.label, "\(path).kv[0]")
                text(kv.value, "\(path).kv[1]")
            case .meter(let meter):
                text(meter.label, "\(path).meter.label")
                text(meter.caption, "\(path).meter.caption")
            case .list(let items):
                if items.count > limits.listItems {
                    said.append("\(path) lists \(items.count) items, and uDeck draws the first \(limits.listItems)")
                }
                for (item, entry) in items.prefix(limits.listItems).enumerated() {
                    text(entry.text, "\(path).list[\(item)].text")
                    text(entry.note, "\(path).list[\(item)].note")
                }
            case .spark(let spark):
                if spark.values.count > limits.sparkValues {
                    said.append("\(path) has \(spark.values.count) values, and uDeck draws the first \(limits.sparkValues)")
                }
                text(spark.caption, "\(path).spark.caption")
            case .table(let table):
                if table.columns.count > limits.tableColumns {
                    said.append("\(path) has \(table.columns.count) columns, and uDeck draws the first \(limits.tableColumns)")
                }
                if table.rows.count > limits.tableRows {
                    said.append("\(path) has \(table.rows.count) table rows, and uDeck draws the first \(limits.tableRows)")
                }
                let columns = min(table.columns.count, limits.tableColumns)
                for (column, entry) in table.columns.prefix(limits.tableColumns).enumerated() {
                    text(entry.title, "\(path).table.columns[\(column)].title")
                }
                for (line, cells) in table.rows.prefix(limits.tableRows).enumerated() {
                    if cells.count > columns {
                        said.append("\(path).table.rows[\(line)] has \(cells.count) cells for \(columns) "
                                    + "column\(columns == 1 ? "" : "s"), and uDeck draws \(columns)")
                    }
                    for (cell, value) in cells.prefix(columns).enumerated() {
                        text(value, "\(path).table.rows[\(line)][\(cell)]")
                    }
                }
            case .log(let lines):
                if lines.count > limits.logLines {
                    said.append("\(path) has \(lines.count) log lines, and uDeck draws the first \(limits.logLines)")
                }
                for (line, value) in lines.prefix(limits.logLines).enumerated() {
                    text(value, "\(path).log[\(line)]")
                }
            case .canvas(let canvas):
                text(canvas.kind, "\(path).canvas.kind")
                text(canvas.payload, "\(path).canvas.payload")
            case .unsupported(let kind):
                text(kind, "the name of the type of \(path)")
            }
        }
        if card.actions.count > limits.actions {
            said.append("the card has \(card.actions.count) actions, and uDeck draws the first \(limits.actions)")
        }
        for (index, action) in card.actions.prefix(limits.actions).enumerated() {
            let path = "actions[\(index)]"
            if action.run.count > limits.actionArguments {
                said.append("\(path).run has \(action.run.count) words, and uDeck keeps the first \(limits.actionArguments)")
            }
            text(action.label, "\(path).label")
            text(action.confirm, "\(path).confirm")
            for (word, value) in action.run.prefix(limits.actionArguments).enumerated() {
                text(value, "\(path).run[\(word)]")
            }
        }
        if !longTexts.isEmpty {
            let shown = longTexts.prefix(5).joined(separator: ", ")
            let more = longTexts.count > 5 ? ", and \(longTexts.count - 5) more" : ""
            said.append("uDeck draws at most \(limits.textLength) characters of a piece of text, and cuts the rest of "
                        + "\(shown)\(more)")
        }
        return said
    }

    /// Each key of `object` that is not one of `known`, said with the key it
    /// was probably meant to be.
    static func unknown(in object: StrictJSON.Object, known: [String], at path: String, _ said: inout [String]) {
        for key in object.keys where !known.contains(key) {
            let field = path.isEmpty ? key : "\(path).\(key)"
            said.append("\"\(field)\" is not a field uDeck reads, and it is ignored" + suggestion(for: key, among: known))
        }
    }

    /// ` -- did you mean "state"?`, for the known name a mistyped one is
    /// closest to — within two edits, and fewer than it has letters — or
    /// nothing.
    static func suggestion(for name: String, among known: [String]) -> String {
        let typed = Array(name.unicodeScalars)
        var best: (name: String, distance: Int)?
        for candidate in known {
            let distance = editDistance(typed, Array(candidate.unicodeScalars))
            if distance <= 2, distance < typed.count, distance < (best?.distance ?? .max) { best = (candidate, distance) }
        }
        return best.map { " -- did you mean \"\($0.name)\"?" } ?? ""
    }

    /// Levenshtein's distance, with a swap of two neighbours as one edit:
    /// `tll` is one from `ttl`.
    static func editDistance(_ a: [Unicode.Scalar], _ b: [Unicode.Scalar]) -> Int {
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var table = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 0 ... a.count { table[i][0] = i }
        for j in 0 ... b.count { table[0][j] = j }
        for i in 1 ... a.count {
            for j in 1 ... b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                table[i][j] = min(table[i - 1][j] + 1, table[i][j - 1] + 1, table[i - 1][j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    table[i][j] = min(table[i][j], table[i - 2][j - 2] + 1)
                }
            }
        }
        return table[a.count][b.count]
    }
}
