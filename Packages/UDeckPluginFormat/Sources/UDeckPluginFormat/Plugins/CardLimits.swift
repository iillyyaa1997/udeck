#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

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

    /// A `feed` keeps its newest entries, each up to this long.
    static let feedEntries = 300
    static let feedTextLength = 20_000
    static let feedFiles = 20
    /// A bar's items, a menu's options, an input's menus.
    static let barItems = 16
    static let menuOptions = 100
    static let pickers = 4
    /// A badge's shorter forms.
    static let badgeForms = 4
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
        // A person's or an agent's words: bound far above a label's.
        func long(_ text: String) -> String {
            guard text.count > CardLimits.feedTextLength else { return text }
            cut = true
            return String(text.prefix(CardLimits.feedTextLength)) + "…"
        }

        func options(_ list: [MenuOption]) -> [MenuOption] {
            if list.count > CardLimits.menuOptions { cut = true }
            return list.prefix(CardLimits.menuOptions).map {
                MenuOption(id: $0.id, text: trim($0.text), group: $0.group.map(trim), note: $0.note.map(trim),
                           tone: $0.tone, button: $0.button.map { MenuOptionButton(id: $0.id, label: trim($0.label)) })
            }
        }

        func menu(_ menu: CardMenu) -> CardMenu {
            CardMenu(id: menu.id, text: trim(menu.text), icon: menu.icon, options: options(menu.options),
                     selected: menu.selected, note: menu.note.map(trim))
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

            case .chips(let items):
                if items.count > limits.listItems { cut = true }
                return .chips(items.prefix(limits.listItems).map {
                    ChipItem(id: $0.id, text: trim($0.text), state: $0.state, selected: $0.selected)
                })

            case .feed(let entries):
                // The newest are what matters; an answer may be long, so its
                // own bound is far above a label's.
                if entries.count > CardLimits.feedEntries { cut = true }
                return .feed(entries.suffix(CardLimits.feedEntries).map {
                    if ($0.files?.count ?? 0) > CardLimits.feedFiles { cut = true }
                    return FeedEntry(id: $0.id, role: $0.role, text: long($0.text), detail: $0.detail.map(long),
                                     streaming: $0.streaming, error: $0.error, name: $0.name.map(trim),
                                     label: $0.label.map(trim),
                                     files: $0.files.map { Array($0.prefix(CardLimits.feedFiles).map(trim)) })
                })

            case .ask(let ask):
                if ask.buttons.count > limits.actions { cut = true }
                return .ask(AskRow(id: ask.id, title: trim(ask.title), detail: ask.detail.map(trim),
                                   buttons: ask.buttons.prefix(limits.actions).map {
                                       AskButton(id: $0.id, label: trim($0.label), primary: $0.primary)
                                   }))

            case .input(let input):
                if (input.pickers?.count ?? 0) > CardLimits.pickers { cut = true }
                // A fill is the person's message given back: long like a feed entry's text.
                return .input(InputRow(id: input.id, placeholder: input.placeholder.map(trim),
                                       enabled: input.enabled, stop: input.stop,
                                       pickers: input.pickers.map { Array($0.prefix(CardLimits.pickers).map(menu)) },
                                       files: input.files,
                                       fill: input.fill.map { InputFill(id: trim($0.id), text: long($0.text)) }))

            case .bar(let bar):
                if bar.items.count > CardLimits.barItems { cut = true }
                if bar.items.contains(where: { item in
                    if case .badge(let badge) = item { (badge.shorter?.count ?? 0) > CardLimits.badgeForms } else { false }
                }) { cut = true }
                return .bar(BarRow(id: bar.id, items: bar.items.prefix(CardLimits.barItems).map { item in
                    switch item {
                    case .title(let title): .title(BarTitle(text: trim(title.text), tone: title.tone))
                    case .tag(let text): .tag(trim(text))
                    case .badge(let badge):
                        .badge(BarBadge(text: trim(badge.text), tone: badge.tone, icon: badge.icon, fill: badge.fill,
                                        busy: badge.busy,
                                        shorter: badge.shorter.map { Array($0.prefix(CardLimits.badgeForms).map(trim)) }))
                    case .menu(let value): .menu(menu(value))
                    case .button(let button):
                        .button(BarButton(id: button.id, icon: button.icon, label: button.label.map(trim),
                                          options: button.options.map(options), note: button.note.map(trim)))
                    case .spacer: .spacer
                    case .unsupported(let kind): .unsupported(kind: trim(kind))
                    }
                }))

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
