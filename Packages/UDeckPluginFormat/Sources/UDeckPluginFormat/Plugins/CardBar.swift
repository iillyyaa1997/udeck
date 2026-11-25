#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// The tones a bar's title dot or badge may take. Closed on purpose, like the
/// list icons: an open-ended colour would let one plugin look like another app.
public enum CardTone: String, Codable, Sendable, CaseIterable {
    /// Working now.
    case run
    /// Waiting on the person.
    case wait
    /// Nothing happening.
    case idle
    case ok, warn, crit
    /// Neutral information.
    case info
}

/// The icons a bar may draw. Closed, like `CardIcon`.
public enum BarIcon: String, Codable, Sendable, CaseIterable {
    case plus, history, folder, model, effort, account, gear
    case run, wait, done, idle, info
}

/// A small button at the end of a menu's option (uDeck 0.9.14): a click
/// sends `press` with its `id` — not a `choose` of the option — and the menu
/// stays open, so that several can be pressed in a row: closing sessions from
/// the list of them.
public struct MenuOptionButton: Codable, Equatable, Sendable {
    public var id: String
    /// A word or a sign: `✕`.
    public var label: String

    enum CodingKeys: String, CodingKey, CaseIterable { case id, label }

    public init(id: String, label: String) {
        self.id = id
        self.label = label
    }
}

/// One choice of a menu.
public struct MenuOption: Codable, Equatable, Sendable {
    public var id: String
    public var text: String
    /// Options with the same `group` are drawn together under it, in order.
    public var group: String?
    /// A second, quieter line.
    public var note: String?
    public var tone: CardTone?
    /// A button at its end (uDeck 0.9.14).
    public var button: MenuOptionButton?

    enum CodingKeys: String, CodingKey, CaseIterable { case id, text, group, note, tone, button }

    public init(id: String, text: String, group: String? = nil, note: String? = nil, tone: CardTone? = nil,
                button: MenuOptionButton? = nil)
    {
        self.id = id
        self.text = text
        self.group = group
        self.note = note
        self.tone = tone
        self.button = button
    }

    /// A button that is not one is left out, not the option with it.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(String.self, forKey: .id), text: try c.decode(String.self, forKey: .text),
                  group: try c.decodeIfPresent(String.self, forKey: .group),
                  note: try c.decodeIfPresent(String.self, forKey: .note),
                  tone: try c.decodeIfPresent(CardTone.self, forKey: .tone),
                  button: try? c.decodeIfPresent(MenuOptionButton.self, forKey: .button))
    }
}

/// A button that shows `text` and opens `options`. Choosing one sends the
/// plugin a `choose` event with the row's `id`, the menu's `id` and the
/// option's `id` (resident plugins only).
public struct CardMenu: Codable, Equatable, Sendable {
    public var id: String
    public var text: String
    public var icon: BarIcon?
    public var options: [MenuOption]
    /// The option drawn with a check.
    public var selected: String?
    /// One line under the options: what choosing does.
    public var note: String?

    enum CodingKeys: String, CodingKey, CaseIterable { case id, text, icon, options, selected, note }

    public init(id: String, text: String, icon: BarIcon? = nil, options: [MenuOption], selected: String? = nil,
                note: String? = nil)
    {
        self.id = id
        self.text = text
        self.icon = icon
        self.options = options
        self.selected = selected
        self.note = note
    }
}

/// The bar's name for what it is about, with a dot of its tone.
public struct BarTitle: Codable, Equatable, Sendable {
    public var text: String
    public var tone: CardTone?

    enum CodingKeys: String, CodingKey, CaseIterable { case text, tone }

    public init(text: String, tone: CardTone? = nil) {
        self.text = text
        self.tone = tone
    }
}

/// A small tinted pill: a state, a count, a figure. With `fill` (0…1) it
/// fills from the left like a battery.
public struct BarBadge: Codable, Equatable, Sendable {
    public var text: String
    public var tone: CardTone?
    public var icon: BarIcon?
    public var fill: Double?

    enum CodingKeys: String, CodingKey, CaseIterable { case text, tone, icon, fill }

    public init(text: String, tone: CardTone? = nil, icon: BarIcon? = nil, fill: Double? = nil) {
        self.text = text
        self.tone = tone
        self.icon = icon
        self.fill = fill.map { min(max($0, 0), 1) }
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            text: try c.decode(String.self, forKey: .text),
            tone: try c.decodeIfPresent(CardTone.self, forKey: .tone),
            icon: try c.decodeIfPresent(BarIcon.self, forKey: .icon),
            fill: try c.decodeIfPresent(Double.self, forKey: .fill)
        )
    }
}

/// A small button: an icon, a label or both. Pressing it sends a `press`
/// event with its `id`; with `options` it opens them as a menu instead, and
/// choosing sends `choose`.
public struct BarButton: Codable, Equatable, Sendable {
    public var id: String
    public var icon: BarIcon?
    public var label: String?
    public var options: [MenuOption]?
    public var note: String?

    enum CodingKeys: String, CodingKey, CaseIterable { case id, icon, label, options, note }

    public init(id: String, icon: BarIcon? = nil, label: String? = nil, options: [MenuOption]? = nil,
                note: String? = nil)
    {
        self.id = id
        self.icon = icon
        self.label = label
        self.options = options
        self.note = note
    }
}

/// One thing on a bar, left to right; what follows a `spacer` sits at the
/// right edge.
public enum BarItem: Equatable, Sendable {
    case title(BarTitle)
    case tag(String)
    case badge(BarBadge)
    case menu(CardMenu)
    case button(BarButton)
    case spacer
    /// An item this build does not understand: skipped when drawn.
    case unsupported(kind: String)

    public enum Kind: String, Sendable, CaseIterable { case title, tag, badge, menu, button, spacer }
}

extension BarItem: Codable {
    /// Every item is an object with exactly one key naming it, like a row.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        guard container.allKeys.count == 1, let key = container.allKeys.first else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "a bar item must have exactly one key naming it, e.g. {\"tag\": \"…\"}"))
        }
        switch Kind(rawValue: key.stringValue) {
        case .title?: self = .title(try container.decode(BarTitle.self, forKey: key))
        case .tag?: self = .tag(try container.decode(String.self, forKey: key))
        case .badge?: self = .badge(try container.decode(BarBadge.self, forKey: key))
        case .menu?: self = .menu(try container.decode(CardMenu.self, forKey: key))
        case .button?: self = .button(try container.decode(BarButton.self, forKey: key))
        case .spacer?: self = .spacer
        case nil: self = .unsupported(kind: key.stringValue)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: AnyCodingKey.self)
        switch self {
        case .title(let value): try container.encode(value, forKey: AnyCodingKey("title"))
        case .tag(let value): try container.encode(value, forKey: AnyCodingKey("tag"))
        case .badge(let value): try container.encode(value, forKey: AnyCodingKey("badge"))
        case .menu(let value): try container.encode(value, forKey: AnyCodingKey("menu"))
        case .button(let value): try container.encode(value, forKey: AnyCodingKey("button"))
        case .spacer: try container.encode(true, forKey: AnyCodingKey("spacer"))
        case .unsupported(let kind): try container.encode(true, forKey: AnyCodingKey(kind))
        }
    }
}

/// A line of small things across the card: a title with menus and buttons, or
/// a row of badges (resident plugins only).
public struct BarRow: Codable, Equatable, Sendable {
    public var id: String
    public var items: [BarItem]

    enum CodingKeys: String, CodingKey, CaseIterable { case id, items }

    public init(id: String, items: [BarItem]) {
        self.id = id
        self.items = items
    }
}
