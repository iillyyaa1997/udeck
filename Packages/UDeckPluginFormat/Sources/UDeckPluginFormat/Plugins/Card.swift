#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// How a plugin says it is doing.
public enum CardState: String, Codable, Sendable, CaseIterable {
    case ok
    case warn
    case crit

    /// "I could not find out." Reserved for a real failure to read the source —
    /// never for "there is nothing happening", which is `ok` with an empty body.
    /// Conflating the two is how a panel teaches its owner to ignore it.
    case unknown
}

/// The icon vocabulary a list row may use. Closed on purpose: an open-ended
/// icon name would let one plugin look like a different app inside the panel.
public enum CardIcon: String, Codable, Sendable, CaseIterable {
    case ok, warn, crit, wait, run, idle, done, pause, info, dot
}

public struct KeyValueRow: Equatable, Sendable {
    public var label: String
    public var value: String
    public var state: CardState?

    public init(label: String, value: String, state: CardState? = nil) {
        self.label = label
        self.value = value
        self.state = state
    }
}

public struct MeterRow: Codable, Equatable, Sendable {
    /// 0…1. Clamped on decode rather than rejected: a producer reporting 1.4 is
    /// telling the truth about being over budget, and refusing its whole card
    /// over the presentation detail would lose that.
    public var value: Double
    public var label: String?
    public var caption: String?
    public var state: CardState?
    /// What the bar is made of, in order (0.9.32): each part's share of the
    /// whole bar, drawn one after the other in its tone, and said under it
    /// with its label and note. `value` is then the parts together.
    public var parts: [MeterPart]?

    public init(value: Double, label: String? = nil, caption: String? = nil, state: CardState? = nil,
                parts: [MeterPart]? = nil) {
        self.value = min(max(value, 0), 1)
        self.label = label
        self.caption = caption
        self.state = state
        self.parts = parts.flatMap { $0.isEmpty ? nil : $0 }
    }

    enum CodingKeys: String, CodingKey, CaseIterable { case value, label, caption, state, parts }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            value: try c.decode(Double.self, forKey: .value),
            label: try c.decodeIfPresent(String.self, forKey: .label),
            caption: try c.decodeIfPresent(String.self, forKey: .caption),
            state: try c.decodeIfPresent(CardState.self, forKey: .state),
            parts: try c.decodeIfPresent([MeterPart].self, forKey: .parts)
        )
    }
}

/// One part of a `meter` (0.9.32): its share of the whole bar, 0…1, its
/// label and a note — `232k` — and the tone it is drawn in.
public struct MeterPart: Codable, Equatable, Sendable {
    public var value: Double
    public var label: String
    public var note: String?
    public var tone: CardTone?

    enum CodingKeys: String, CodingKey, CaseIterable { case value, label, note, tone }

    public init(value: Double, label: String, note: String? = nil, tone: CardTone? = nil) {
        self.value = min(max(value, 0), 1)
        self.label = label
        self.note = note
        self.tone = tone
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(value: try c.decode(Double.self, forKey: .value), label: try c.decode(String.self, forKey: .label),
                  note: try c.decodeIfPresent(String.self, forKey: .note),
                  tone: try? c.decodeIfPresent(CardTone.self, forKey: .tone))
    }
}

public struct ListItem: Codable, Equatable, Sendable {
    public var text: String
    public var note: String?
    public var icon: CardIcon?
    public var state: CardState?

    enum CodingKeys: String, CodingKey, CaseIterable { case text, note, icon, state }

    public init(text: String, note: String? = nil, icon: CardIcon? = nil, state: CardState? = nil) {
        self.text = text
        self.note = note
        self.icon = icon
        self.state = state
    }
}

public struct SparkRow: Equatable, Sendable {
    /// The samples to draw. The host stores no history of its own in this
    /// version, so a spark shows exactly what the producer sent and nothing
    /// more — which is why the shape of this row must not change if host-side
    /// history is added later.
    public var values: [Double]
    public var caption: String?

    public init(values: [Double], caption: String? = nil) {
        self.values = values
        self.caption = caption
    }
}

public struct CardTableColumn: Codable, Equatable, Sendable {
    public enum Alignment: String, Codable, Sendable, CaseIterable { case leading, trailing }

    public var title: String
    public var align: Alignment

    public init(title: String, align: Alignment = .leading) {
        self.title = title
        self.align = align
    }

    enum CodingKeys: String, CodingKey, CaseIterable { case title, align }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            title: try c.decode(String.self, forKey: .title),
            align: try c.decodeIfPresent(Alignment.self, forKey: .align) ?? .leading
        )
    }
}

public struct CardTable: Codable, Equatable, Sendable {
    public var columns: [CardTableColumn]
    public var rows: [[String]]

    enum CodingKeys: String, CodingKey, CaseIterable { case columns, rows }

    public init(columns: [CardTableColumn], rows: [[String]]) {
        self.columns = columns
        self.rows = rows
    }
}

/// The escape hatch: a card drawing itself.
///
/// Described by the format from the start, so that adding it later does not
/// have to change a format other people's plugins already depend on, and
/// deliberately not rendered in this version.
///
/// The intention when it arrives is that it is drawn inside a frame uDeck owns,
/// so that it reads as the plugin's own drawing rather than as part of the
/// panel. That is a design decision, not a property of any code that exists —
/// there is nothing here to enforce it yet.
public struct CanvasRow: Codable, Equatable, Sendable {
    public var kind: String
    public var payload: String?
    public var height: Double?

    enum CodingKeys: String, CodingKey, CaseIterable { case kind, payload, height }

    public init(kind: String, payload: String? = nil, height: Double? = nil) {
        self.kind = kind
        self.payload = payload
        self.height = height
    }
}

/// One chip of a `chips` row: a choice among several things the plugin keeps
/// (sessions, tabs, accounts), one of them selected. Pressing it sends the
/// plugin a `select` event with its `id` (resident plugins only).
public struct ChipItem: Codable, Equatable, Sendable {
    public var id: String
    public var text: String
    public var state: CardState?
    public var selected: Bool?

    enum CodingKeys: String, CodingKey, CaseIterable { case id, text, state, selected }

    public init(id: String, text: String, state: CardState? = nil, selected: Bool? = nil) {
        self.id = id
        self.text = text
        self.state = state
        self.selected = selected
    }
}

/// One entry of a `feed` row: a conversation or a running log, newest last.
public struct FeedEntry: Codable, Equatable, Sendable {
    public enum Role: String, Codable, Sendable, CaseIterable {
        /// What the person said — drawn on the right.
        case user
        /// What the other side said — plain text with inline markdown.
        case assistant
        /// One line about an operation, which opens to `detail`.
        case tool
        /// A line about the conversation rather than in it.
        case note
    }

    public var id: String
    public var role: Role
    public var text: String
    /// What a `tool` entry opens to (its result).
    public var detail: String?
    /// Still arriving: drawn with a caret.
    public var streaming: Bool?
    /// The operation failed: drawn as an error.
    public var error: Bool?
    /// A `tool` entry's operation, short (`Bash`, `Read`): consecutive tool
    /// entries fold into one line that counts them by it.
    public var name: String?
    /// A small label above an `assistant` entry: who said it, when more than
    /// one side can.
    public var label: String?
    /// The files that went with a `user` entry, absolute paths (uDeck 0.9.23):
    /// pictures drawn above it — one larger — any other file as its icon and
    /// name; a click opens them in Quick Look.
    public var files: [String]?

    enum CodingKeys: String, CodingKey, CaseIterable { case id, role, text, detail, streaming, error, name, label, files }

    public init(id: String, role: Role, text: String, detail: String? = nil, streaming: Bool? = nil,
                error: Bool? = nil, name: String? = nil, label: String? = nil, files: [String]? = nil)
    {
        self.files = files
        self.id = id
        self.role = role
        self.text = text
        self.detail = detail
        self.streaming = streaming
        self.error = error
        self.name = name
        self.label = label
    }
}

/// One button of an `ask` row.
public struct AskButton: Codable, Equatable, Sendable {
    public var id: String
    public var label: String
    public var primary: Bool?

    enum CodingKeys: String, CodingKey, CaseIterable { case id, label, primary }

    public init(id: String, label: String, primary: Bool? = nil) {
        self.id = id
        self.label = label
        self.primary = primary
    }
}

/// A question the plugin waits on the person for: a title, what it is about,
/// and the answers as buttons. A press sends the plugin a `press` event with
/// the button's `id` (resident plugins only).
public struct AskRow: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var detail: String?
    public var buttons: [AskButton]

    enum CodingKeys: String, CodingKey, CaseIterable { case id, title, detail, buttons }

    public init(id: String, title: String, detail: String? = nil, buttons: [AskButton]) {
        self.id = id
        self.title = title
        self.detail = detail
        self.buttons = buttons
    }
}

/// A text field. Return sends the plugin a `submit` event with the row's `id`
/// and the text, Shift-Return starts a new line; with `stop`, a Stop button
/// (and Escape) sends a `press` event with that id. With `pickers` the field
/// is a panel: the menus sit under the text, beside Stop and Send, and
/// choosing sends `choose` with the row's `id` (resident plugins only).
public struct InputRow: Codable, Equatable, Sendable {
    public var id: String
    public var placeholder: String?
    public var enabled: Bool?
    public var stop: String?
    public var pickers: [CardMenu]?
    /// Files may go with the text (0.9.17): dragged onto the field, pasted
    /// with ⌘V — a screenshot too — or chosen with 📎. They are shown above
    /// the text and sent with it in `submit` as `files`, absolute paths; a
    /// pasted picture is written to a file first.
    public var files: Bool?
    /// Text the plugin puts into the field, once (0.9.19): messages it gives
    /// back to be edited and sent again.
    public var fill: InputFill?
    /// What the field suggests (0.9.25): commands, skills, files — a list over
    /// the field, opened by typing a tab's trigger, by the field's «/» button,
    /// by ⌘/ or from the field's menu. Picking one puts its `text` in.
    public var suggest: InputSuggest?

    enum CodingKeys: String, CodingKey, CaseIterable { case id, placeholder, enabled, stop, pickers, files, fill, suggest }

    public init(id: String, placeholder: String? = nil, enabled: Bool? = nil, stop: String? = nil,
                pickers: [CardMenu]? = nil, files: Bool? = nil, fill: InputFill? = nil, suggest: InputSuggest? = nil)
    {
        self.id = id
        self.placeholder = placeholder
        self.enabled = enabled
        self.stop = stop
        self.pickers = pickers
        self.files = files
        self.fill = fill
        self.suggest = suggest
    }
}

/// What a field suggests (uDeck 0.9.25), in tabs: uDeck adds one of its own
/// before them, «All», of every tab that is not searched.
public struct InputSuggest: Codable, Equatable, Sendable {
    public var tabs: [SuggestTab]
    /// The suggestions of the tabs that are given whole.
    public var items: [SuggestItem]?
    /// Items used lately, newest first, by `id`: shown first while nothing
    /// is typed.
    public var recent: [String]?
    /// What the plugin found for a searched tab's query — its answer to a
    /// `suggest` event.
    public var found: SuggestFound?

    enum CodingKeys: String, CodingKey, CaseIterable { case tabs, items, recent, found }

    public init(tabs: [SuggestTab], items: [SuggestItem]? = nil, recent: [String]? = nil, found: SuggestFound? = nil) {
        self.tabs = tabs
        self.items = items
        self.recent = recent
        self.found = found
    }
}

/// One tab of suggestions.
public struct SuggestTab: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    /// Typing this opens the list on this tab: «/», «@». What is typed after
    /// it, up to the caret, is the query.
    public var trigger: String?
    /// The trigger counts only at the start of the text, as a command's «/».
    public var start: Bool?
    /// Its items are the plugin's to find for each query — files — and asked
    /// for with a `suggest` event, rather than given whole in `items`.
    public var search: Bool?

    enum CodingKeys: String, CodingKey, CaseIterable { case id, title, trigger, start, search }

    public init(id: String, title: String, trigger: String? = nil, start: Bool? = nil, search: Bool? = nil) {
        self.id = id
        self.title = title
        self.trigger = trigger
        self.start = start
        self.search = search
    }
}

/// One suggestion.
public struct SuggestItem: Codable, Equatable, Sendable {
    public var id: String
    /// The tab it is in.
    public var tab: String
    /// What picking it puts into the field, in place of the trigger and what
    /// was typed after it.
    public var text: String
    /// What the list shows of it, when not its `text`.
    public var title: String?
    /// A line about it, after the title.
    public var detail: String?
    /// A word at the end of its line: where it goes, what kind it is.
    public var note: String?

    enum CodingKeys: String, CodingKey, CaseIterable { case id, tab, text, title, detail, note }

    public init(id: String, tab: String, text: String, title: String? = nil, detail: String? = nil, note: String? = nil) {
        self.id = id
        self.tab = tab
        self.text = text
        self.title = title
        self.detail = detail
        self.note = note
    }
}

/// What a plugin found for a searched tab's query.
public struct SuggestFound: Codable, Equatable, Sendable {
    public var tab: String
    public var query: String
    public var items: [SuggestItem]

    enum CodingKeys: String, CodingKey, CaseIterable { case tab, query, items }

    public init(tab: String, query: String, items: [SuggestItem]) {
        self.tab = tab
        self.query = query
        self.items = items
    }
}

/// Text put into a field once (uDeck 0.9.19). `id` names this fill: a fill the
/// field has had is not put there again — the same card sent twice, a restart
/// of uDeck — so a new fill takes a new `id`. The text goes after what is
/// typed there already, on a line of its own, and is the person's to edit.
public struct InputFill: Codable, Equatable, Sendable {
    public var id: String
    public var text: String

    enum CodingKeys: String, CodingKey, CaseIterable { case id, text }

    public init(id: String, text: String) {
        self.id = id
        self.text = text
    }
}

/// One line of a card's body.
public enum CardRow: Equatable, Sendable {
    case text(String)
    case keyValue(KeyValueRow)
    case meter(MeterRow)
    case list([ListItem])
    case spark(SparkRow)
    case table(CardTable)
    case log([String])
    case canvas(CanvasRow)
    /// Interactive rows, for resident plugins (0.9.1).
    case chips([ChipItem])
    case feed([FeedEntry])
    case ask(AskRow)
    case input(InputRow)
    /// A line of titles, menus, buttons and badges (0.9.4).
    case bar(BarRow)

    /// A row this build does not understand.
    ///
    /// Kept rather than dropped, and rendered as a visible diagnostic. Silently
    /// discarding it would leave a plugin author staring at a card with a hole
    /// in it and no explanation.
    case unsupported(kind: String)
}

/// What a plugin prints on stdout.
public struct Card: Equatable, Sendable {
    public var state: CardState
    public var title: String?
    public var chip: String?
    public var rows: [CardRow]
    public var actions: [CardAction]

    /// How long this card stays trustworthy, in seconds.
    ///
    /// The single most important field in the format. Past it the card is shown
    /// as stale — values still visible, but marked, with the time it last spoke.
    /// Past a multiple of it the values are hidden entirely and the card reads
    /// `unknown`. Without this, a source that legitimately goes quiet at night
    /// looks exactly like a source that broke, and a panel that cries wolf gets
    /// ignored, which is the one failure that kills a thing like this.
    public var ttl: TimeInterval?

    /// Something here waits for the person (uDeck 0.9.10 and later): uDeck
    /// says so on the island — ears beside a notch, a glow — and shows `ask`
    /// first when the panel is peeked at.
    public var attention: CardAttention?

    public init(
        state: CardState = .ok,
        title: String? = nil,
        chip: String? = nil,
        rows: [CardRow] = [],
        actions: [CardAction] = [],
        ttl: TimeInterval? = nil,
        attention: CardAttention? = nil
    ) {
        self.state = state
        self.title = title
        self.chip = chip
        self.rows = rows
        self.actions = actions
        self.ttl = ttl
        self.attention = attention
    }
}

/// What waits for the person on a card: how many things, and the one to
/// answer first — an `ask` uDeck draws when the panel is peeked at, its
/// buttons sent back as `press`, as on the card.
public struct CardAttention: Codable, Equatable, Sendable {
    public var count: Int
    public var ask: AskRow?

    enum CodingKeys: String, CodingKey, CaseIterable { case count, ask }

    public init(count: Int, ask: AskRow? = nil) {
        self.count = max(0, count)
        self.ask = ask
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(count: (try? c.decodeIfPresent(Int.self, forKey: .count)) ?? 0,
                  ask: try? c.decodeIfPresent(AskRow.self, forKey: .ask))
    }
}

/// A button on a card.
///
/// The host runs the command, not the plugin — which is what makes the `exec`
/// grant mean something: an action from a plugin that was never granted `exec`
/// is refused at the point of the click, by code the plugin does not control.
public struct CardAction: Codable, Equatable, Sendable, Identifiable {
    public var label: String
    public var run: [String]

    /// When present, the operator is asked this question before the command runs.
    public var confirm: String?

    public var id: String { label + "\u{0}" + run.joined(separator: "\u{0}") }

    public init(label: String, run: [String], confirm: String? = nil) {
        self.label = label
        self.run = run
        self.confirm = confirm
    }

    enum CodingKeys: String, CodingKey, CaseIterable { case label, run, confirm }
}
