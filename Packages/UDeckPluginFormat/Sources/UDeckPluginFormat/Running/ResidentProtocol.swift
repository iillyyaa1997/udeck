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
    /// `notification` event with `id`, as does a button of it or a reply
    /// written in it (`PluginNotice`).
    case notify(PluginNotice)
    /// The notification `id` is not wanted any more — answered on the card:
    /// it leaves Notification Centre.
    case unnotify(id: String)
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
        struct Notify: Decodable {
            var id: String
            var title: String?
            var body: String?
            var actions: [PluginNotice.Action]?
            var reply: PluginNotice.Reply?
        }
        struct Unnotify: Decodable { var id: String }
        struct Pick: Decodable { var id: String; var prompt: String? }
        struct Show: Decodable { var view: String }
        var card: Card?
        var view: String?
        var keep: String?
        var name: String?
        var notify: Notify?
        var unnotify: Unnotify?
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
            self = .notify(PluginNotice(id: notify.id, title: notify.title ?? "", body: notify.body ?? "",
                                        actions: notify.actions ?? [], reply: notify.reply))
        } else if let unnotify = envelope.unnotify {
            self = .unnotify(id: unnotify.id)
        } else if let pick = envelope.pick {
            self = .pickFolder(id: pick.id, prompt: pick.prompt)
        } else if let show = envelope.show {
            self = .show(view: show.view)
        } else {
            self = .unknown(String(line.prefix(200)))
        }
    }
}

/// A notification a resident plugin asks for: macOS draws it, with up to
/// three buttons and a field to write a reply in (uDeck 0.9.9 and later).
/// What the person pressed or wrote comes back as a `notification` event —
/// without the panel opening: an answer, given where it was asked.
public struct PluginNotice: Equatable, Sendable {
    public struct Action: Codable, Equatable, Sendable {
        public var id: String
        public var text: String

        public init(id: String, text: String) {
            self.id = id
            self.text = text
        }
    }

    /// A field to write in: the button that opens it, and what it says while
    /// empty.
    public struct Reply: Codable, Equatable, Sendable {
        public var button: String
        public var placeholder: String?

        public init(button: String, placeholder: String? = nil) {
            self.button = button
            self.placeholder = placeholder
        }
    }

    /// The most buttons a notice carries, and the longest anything in it
    /// may be: macOS cuts a long title short, and a long id is no one's.
    public static let actionLimit = 3
    public static let textLimit = 60
    public static let idLimit = 200

    public var id: String
    public var title: String
    public var body: String
    public var actions: [Action]
    public var reply: Reply?

    /// The notice as uDeck holds it: at most three buttons, each with an id
    /// and a text of its own; anything too long cut or left out.
    public init(id: String, title: String, body: String, actions: [Action] = [], reply: Reply? = nil) {
        func cut(_ text: String) -> String { String(text.prefix(Self.textLimit)) }
        self.id = id
        self.title = title
        self.body = body
        var seen = Set<String>()
        self.actions = Array(actions.filter { action in
            !action.id.isEmpty && action.id.count <= Self.idLimit && !action.text.isEmpty && seen.insert(action.id).inserted
        }.prefix(Self.actionLimit)).map { Action(id: $0.id, text: cut($0.text)) }
        self.reply = reply.flatMap { $0.button.isEmpty ? nil : Reply(button: cut($0.button), placeholder: $0.placeholder.map(cut)) }
    }

    /// Whether it carries anything to press or write in.
    public var answers: Bool { !actions.isEmpty || reply != nil }
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
    /// Text was sent from an `input` row, and the files sent with it: absolute
    /// paths, for a row that takes files (`InputRow.files`, 0.9.17).
    case submit(row: String, text: String, files: [String] = [])
    /// The folder the person chose for a `pick` request; nil when they cancelled.
    case folder(id: String, path: String?)
    /// A notification the plugin asked for was clicked — or one of its
    /// buttons pressed, `action`, or a reply written in it, `text`.
    case notification(id: String, action: String? = nil, text: String? = nil)
    /// An option of a menu was chosen: the row (a `bar` or an `input`), the
    /// menu (or button) and the option.
    case choose(row: String, menu: String, option: String)
    /// A searched tab of an input's suggestions wants items for what is
    /// typed (0.9.25): the row, the tab and the query. The plugin answers with
    /// its card, the items in the input's `suggest.found`.
    case suggest(row: String, tab: String, query: String)
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
        var action: String?
        var view: String?
        var place: String?
        var keep: String?
        var to: String?
        var files: [String]?
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
        case .submit(let row, let text, let files):
            wire = Wire(event: "submit", row: row, text: text)
            if !files.isEmpty { wire.files = files }
        case .folder(let id, let path): wire = Wire(event: "folder", id: id, path: path)
        case .notification(let id, let action, let text):
            wire = Wire(event: "notification", id: id, text: text)
            wire.action = action
        case .choose(let row, let menu, let option): wire = Wire(event: "choose", row: row, menu: menu, option: option)
        case .closed(let to): wire = Wire(event: "closed", to: to)
        case .suggest(let row, let tab, let query): wire = Wire(event: "suggest", id: tab, row: row, text: query)
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
