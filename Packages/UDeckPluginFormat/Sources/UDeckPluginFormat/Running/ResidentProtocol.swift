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
    /// The card as it is now.
    case card(Card)
    /// A macOS notification; clicking it shows the plugin's card and sends a
    /// `notification` event with `id`.
    case notify(id: String, title: String, body: String)
    /// Ask the person for a folder; the answer comes as a `folder` event.
    case pickFolder(id: String, prompt: String?)
    /// Something uDeck does not know: kept out of the way, never fatal.
    case unknown(String)

    private struct Envelope: Decodable {
        struct Notify: Decodable { var id: String; var title: String?; var body: String? }
        struct Pick: Decodable { var id: String; var prompt: String? }
        var card: Card?
        var notify: Notify?
        var pick: Pick?
    }

    /// One line of the plugin's stdout.
    public init(line: String) {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: Data(line.utf8)) else {
            self = .unknown(String(line.prefix(200)))
            return
        }
        if let card = envelope.card {
            self = .card(card)
        } else if let notify = envelope.notify {
            self = .notify(id: notify.id, title: notify.title ?? "", body: notify.body ?? "")
        } else if let pick = envelope.pick {
            self = .pickFolder(id: pick.id, prompt: pick.prompt)
        } else {
            self = .unknown(String(line.prefix(200)))
        }
    }
}

/// What uDeck tells a resident plugin.
public enum ResidentEvent: Equatable, Sendable {
    /// Sent first, and again when the plugin restarts: its card's size in grid
    /// cells, and uDeck's language.
    case hello(columns: Int, rows: Int, language: String)
    /// The card was resized.
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
    }

    /// The event as one line for the plugin's stdin.
    public var line: String {
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
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(wire)) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}
