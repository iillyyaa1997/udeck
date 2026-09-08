import Foundation

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

    public init(value: Double, label: String? = nil, caption: String? = nil, state: CardState? = nil) {
        self.value = min(max(value, 0), 1)
        self.label = label
        self.caption = caption
        self.state = state
    }

    private enum CodingKeys: String, CodingKey { case value, label, caption, state }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            value: try c.decode(Double.self, forKey: .value),
            label: try c.decodeIfPresent(String.self, forKey: .label),
            caption: try c.decodeIfPresent(String.self, forKey: .caption),
            state: try c.decodeIfPresent(CardState.self, forKey: .state)
        )
    }
}

public struct ListItem: Codable, Equatable, Sendable {
    public var text: String
    public var note: String?
    public var icon: CardIcon?
    public var state: CardState?

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

public struct TableColumn: Codable, Equatable, Sendable {
    public enum Alignment: String, Codable, Sendable { case leading, trailing }

    public var title: String
    public var align: Alignment

    public init(title: String, align: Alignment = .leading) {
        self.title = title
        self.align = align
    }

    private enum CodingKeys: String, CodingKey { case title, align }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            title: try c.decode(String.self, forKey: .title),
            align: try c.decodeIfPresent(Alignment.self, forKey: .align) ?? .leading
        )
    }
}

public struct TableRow: Codable, Equatable, Sendable {
    public var columns: [TableColumn]
    public var rows: [[String]]

    public init(columns: [TableColumn], rows: [[String]]) {
        self.columns = columns
        self.rows = rows
    }
}

/// The escape hatch: a card drawing itself.
///
/// Described by the format from the start so that adding it cannot break
/// existing plugins, and deliberately not rendered in this version. When it does
/// arrive it will be drawn inside a frame the host owns, so that a card drawing
/// itself can never be mistaken for one the host drew.
public struct CanvasRow: Codable, Equatable, Sendable {
    public var kind: String
    public var payload: String?
    public var height: Double?

    public init(kind: String, payload: String? = nil, height: Double? = nil) {
        self.kind = kind
        self.payload = payload
        self.height = height
    }
}

/// One line of a card's body.
public enum CardRow: Equatable, Sendable {
    case text(String)
    case keyValue(KeyValueRow)
    case meter(MeterRow)
    case list([ListItem])
    case spark(SparkRow)
    case table(TableRow)
    case log([String])
    case canvas(CanvasRow)

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

    public init(
        state: CardState = .ok,
        title: String? = nil,
        chip: String? = nil,
        rows: [CardRow] = [],
        actions: [CardAction] = [],
        ttl: TimeInterval? = nil
    ) {
        self.state = state
        self.title = title
        self.chip = chip
        self.rows = rows
        self.actions = actions
        self.ttl = ttl
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

    private enum CodingKeys: String, CodingKey { case label, run, confirm }
}
