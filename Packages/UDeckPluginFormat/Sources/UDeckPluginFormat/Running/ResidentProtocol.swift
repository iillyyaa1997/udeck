#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// A resident plugin's conversation with uDeck: one JSON object per line, both
/// ways, on the plugin's stdin and stdout, for as long as it runs.
///
/// The plugin says what its card shows — the whole card each time — and may ask
/// for a notification or a folder; uDeck tells it what the person did and how
/// big its card is now. uDeck draws everything; the plugin never does.
public enum ResidentMessage: Equatable, Sendable {
    /// The card as it is now, and which of its places it is for.
    case card(Card, CardPlace)
    /// A macOS notification; clicking it shows the plugin's card and sends a
    /// `notification` event with `id`.
    case notify(id: String, title: String, body: String)
    /// Ask the person for a folder; the answer comes as a `folder` event.
    case pickFolder(id: String, prompt: String?)
    /// Bring the place `view` forward: its window, its mini window, its tab.
    case show(view: String)
    /// Something uDeck does not know: kept out of the way, never fatal.
    case unknown(String)

    /// The longest `keep` uDeck holds for a place, and the longest `name`:
    /// past these a card is still drawn, and they are not kept.
    public static let keepLimit = 1024
    public static let nameLimit = 200

    private struct Envelope: Decodable {
        struct Notify: Decodable { var id: String; var title: String?; var body: String? }
        struct Pick: Decodable { var id: String; var prompt: String? }
        struct Show: Decodable { var view: String }
        var card: Card?
        var view: String?
        var keep: String?
        var name: String?
        var notify: Notify?
        var pick: Pick?
        var show: Show?
    }

    /// One line of the plugin's stdout.
    public init(line: String) {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: Data(line.utf8)) else {
            self = .unknown(String(line.prefix(200)))
            return
        }
        if let card = envelope.card {
            self = .card(card, CardPlace(view: envelope.view.flatMap { $0.isEmpty ? nil : $0 },
                                         keep: envelope.keep.flatMap { $0.count <= Self.keepLimit ? $0 : nil },
                                         name: envelope.name.flatMap { $0.count <= Self.nameLimit ? $0 : nil }))
        } else if let notify = envelope.notify {
            self = .notify(id: notify.id, title: notify.title ?? "", body: notify.body ?? "")
        } else if let pick = envelope.pick {
            self = .pickFolder(id: pick.id, prompt: pick.prompt)
        } else if let show = envelope.show {
            self = .show(view: show.view)
        } else {
            self = .unknown(String(line.prefix(200)))
        }
    }
}

/// Which place a card is for, and what it shows there (uDeck 0.9.9 and
/// later). A plugin may show each of its things in a place of its own: one
/// session in a window, another in a mini window, a third on the board.
public struct CardPlace: Equatable, Sendable {
    /// The place, as uDeck named it in `hello`; nil for the plugin's windows
    /// on the board, as before places had names.
    public var view: String?
    /// A short string of the plugin's own saying what this place shows.
    /// uDeck keeps it with the place, across restarts, and hands it back in
    /// `hello`; a card with one can send that thing to a place of its own.
    public var keep: String?
    /// What the place shows, by name: the title of its window and its tab.
    public var name: String?

    public init(view: String? = nil, keep: String? = nil, name: String? = nil) {
        self.view = view
        self.keep = keep
        self.name = name
    }

    /// Whether the plugin said anything of places: it is told of all of them.
    public var speaksOfPlaces: Bool { view != nil || keep != nil }
}

/// What uDeck tells a resident plugin.
public enum ResidentEvent: Equatable, Sendable {
    /// Sent first, and again when the plugin restarts: its card's size in grid
    /// cells, and uDeck's language. Sent again for every other place the card
    /// is shown in, once the plugin names places (`CardPlace`).
    case hello(columns: Int, rows: Int, language: String)
    /// The card was resized, or shown in another place.
    case size(columns: Int, rows: Int)
    /// A chip was chosen.
    case select(id: String)
    /// A button was pressed (an ask's answer, Stop).
    case press(id: String)
    /// Text was sent from an `input` row.
    case submit(row: String, text: String)
    /// The folder the person chose for a `pick` request; nil when they cancelled.
    case folder(id: String, path: String?)
    /// A notification the plugin asked for was clicked.
    case notification(id: String)
    /// An option of a menu was chosen: the row (a `bar` or an `input`), the
    /// menu (or button) and the option.
    case choose(row: String, menu: String, option: String)
    /// A place of its own was closed. With `to`, the person asked for what it
    /// showed back on the board: show it in the place `to`.
    case closed(to: String?)

    /// Which place an event is about, and what uDeck knows of it.
    public struct About: Equatable, Sendable {
        /// The place's name for the plugin: the same while it exists.
        public var view: String
        /// Where it is: `card` (its cell on the board), `tab`, `window` or
        /// `mini`. Said in `hello` and `size`.
        public var place: String?
        /// What the plugin last said it shows there (`CardPlace.keep`). Said
        /// in `hello` and `closed`.
        public var keep: String?

        public init(view: String, place: String? = nil, keep: String? = nil) {
            self.view = view
            self.place = place
            self.keep = keep
        }
    }

    private struct Wire: Encodable {
        struct Size: Encodable { var columns: Int; var rows: Int }
        var event: String
        var size: Size?
        var language: String?
        var id: String?
        var row: String?
        var text: String?
        var path: String?
        var menu: String?
        var option: String?
        var view: String?
        var place: String?
        var keep: String?
        var to: String?
    }

    /// The event as one line for the plugin's stdin.
    public var line: String { line(about: nil) }

    /// The event as one line, saying which place it is about.
    public func line(about place: About?) -> String {
        var wire: Wire
        switch self {
        case .hello(let columns, let rows, let language):
            wire = Wire(event: "hello", size: .init(columns: columns, rows: rows), language: language)
        case .size(let columns, let rows): wire = Wire(event: "size", size: .init(columns: columns, rows: rows))
        case .select(let id): wire = Wire(event: "select", id: id)
        case .press(let id): wire = Wire(event: "press", id: id)
        case .submit(let row, let text): wire = Wire(event: "submit", row: row, text: text)
        case .folder(let id, let path): wire = Wire(event: "folder", id: id, path: path)
        case .notification(let id): wire = Wire(event: "notification", id: id)
        case .choose(let row, let menu, let option): wire = Wire(event: "choose", row: row, menu: menu, option: option)
        case .closed(let to): wire = Wire(event: "closed", to: to)
        }
        if let place {
            wire.view = place.view
            wire.place = place.place
            wire.keep = place.keep
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(wire)) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}
