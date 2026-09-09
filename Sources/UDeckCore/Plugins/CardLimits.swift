import Foundation

/// How much of a card uDeck will actually draw.
///
/// The output cap in `ProcessRunner` bounds a producer in *bytes*, which is the
/// wrong unit for the thing that hurts. A megabyte of `{"text":"x"}` is about
/// eighty thousand rows — well inside the byte limit, and enough to make the
/// panel stop responding while it lays them out. A single one-megabyte string
/// in one row does the same thing for a different reason.
///
/// So a card is brought within these limits before it is drawn, and told so.
/// Truncating is the right answer rather than rejecting: a card that is mostly
/// useful and slightly too long should show the useful part, and a producer
/// that is wildly over is told plainly enough to go and fix it.
public struct CardLimits: Sendable, Equatable {
    public var rows: Int
    public var listItems: Int
    public var tableRows: Int
    public var tableColumns: Int
    public var logLines: Int
    public var sparkValues: Int

    /// Buttons. A card is a card, not a control panel, and every action is a
    /// SwiftUI button with a label to shape. Thirty thousand of them fit inside
    /// the byte cap comfortably.
    public var actions: Int

    /// Words in one action's command. A grant is matched on the first element,
    /// so the rest is unbounded free text that uDeck would hand to a process.
    public var actionArguments: Int

    /// Longest single piece of text. Generous for anything meant to be read,
    /// and far below what makes text layout expensive.
    public var textLength: Int

    public init(
        rows: Int = 200,
        listItems: Int = 200,
        tableRows: Int = 200,
        tableColumns: Int = 12,
        logLines: Int = 200,
        sparkValues: Int = 512,
        actions: Int = 12,
        actionArguments: Int = 64,
        textLength: Int = 1000
    ) {
        self.rows = rows
        self.listItems = listItems
        self.tableRows = tableRows
        self.tableColumns = tableColumns
        self.logLines = logLines
        self.sparkValues = sparkValues
        self.actions = actions
        self.actionArguments = actionArguments
        self.textLength = textLength
    }

    public static let standard = CardLimits()
}

extension Card {
    /// A copy of this card that uDeck can draw, and a note when anything had to
    /// be cut.
    ///
    /// The note is added as a row rather than logged, because the person who
    /// needs it is the plugin's author, and the card is where they are looking.
    public func withinDrawingLimits(_ limits: CardLimits = .standard) -> Card {
        var cut = false

        func trim(_ text: String) -> String {
            guard text.count > limits.textLength else { return text }
            cut = true
            return String(text.prefix(limits.textLength)) + "…"
        }

        var trimmed = self
        trimmed.title = title.map(trim)
        trimmed.chip = chip.map(trim)

        if rows.count > limits.rows { cut = true }
        trimmed.rows = rows.prefix(limits.rows).map { row in
            switch row {
            case .text(let value):
                return .text(trim(value))

            case .keyValue(let kv):
                return .keyValue(KeyValueRow(label: trim(kv.label), value: trim(kv.value), state: kv.state))

            case .meter(let meter):
                return .meter(MeterRow(
                    value: meter.value, label: meter.label.map(trim),
                    caption: meter.caption.map(trim), state: meter.state
                ))

            case .list(let items):
                if items.count > limits.listItems { cut = true }
                return .list(items.prefix(limits.listItems).map {
                    ListItem(text: trim($0.text), note: $0.note.map(trim), icon: $0.icon, state: $0.state)
                })

            case .spark(let spark):
                if spark.values.count > limits.sparkValues { cut = true }
                return .spark(SparkRow(
                    values: Array(spark.values.prefix(limits.sparkValues)),
                    caption: spark.caption.map(trim)
                ))

            case .table(let table):
                if table.rows.count > limits.tableRows || table.columns.count > limits.tableColumns {
                    cut = true
                }
                let columns = table.columns.prefix(limits.tableColumns).map {
                    CardTableColumn(title: trim($0.title), align: $0.align)
                }
                return .table(CardTable(
                    columns: Array(columns),
                    rows: table.rows.prefix(limits.tableRows).map { row in
                        row.prefix(columns.count).map(trim)
                    }
                ))

            case .log(let lines):
                if lines.count > limits.logLines { cut = true }
                return .log(lines.prefix(limits.logLines).map(trim))

            case .canvas(let canvas):
                return .canvas(CanvasRow(
                    kind: trim(canvas.kind),
                    payload: canvas.payload.map(trim),
                    height: canvas.height
                ))

            case .unsupported(let kind):
                // The diagnostic is drawn, and a row's *name* comes straight
                // out of the plugin's JSON: a 900 KB key was a 900 KB string to
                // shape, through the one door the trimming did not cover.
                return .unsupported(kind: trim(kind))
            }
        }

        if actions.count > limits.actions { cut = true }
        trimmed.actions = actions.prefix(limits.actions).map { action in
            if action.run.count > limits.actionArguments { cut = true }
            return CardAction(
                label: trim(action.label),
                run: action.run.prefix(limits.actionArguments).map(trim),
                confirm: action.confirm.map(trim)
            )
        }

        if cut {
            trimmed.rows.append(.text(
                "this card is longer than uDeck will draw and has been cut short"
            ))
        }
        return trimmed
    }
}
