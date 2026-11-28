import Foundation
import UDeckAgents

/// What a place shows, as uDeck keeps it for the place (`keep`): enough to
/// find the conversation while it is open, and to continue its session after
/// uDeck or this plugin started again. A short JSON object, under uDeck's
/// 1024 characters.
struct Kept: Equatable {
    var id: UUID?
    var claude: String?
    var account: String?
    var codex: String?
    var folder: String?
    var title: String?
    /// The model and the effort chosen on the card for its Claude session:
    /// without them a session continued after the plugin started again ran
    /// with the CLI's own, and the card said «модель» (the operator, 11-28:
    /// «Модель как будто сбросилась после перезагрузки»).
    var model: String?
    var effort: String?

    static let limit = 1024

    init(id: UUID? = nil, claude: String? = nil, account: String? = nil, codex: String? = nil,
         folder: String? = nil, title: String? = nil, model: String? = nil, effort: String? = nil) {
        self.id = id
        self.claude = claude
        self.account = account
        self.codex = codex
        self.folder = folder
        self.title = title
        self.model = model
        self.effort = effort
    }

    /// Read back; nil for anything else. A session id is a file's name in
    /// the transcripts folder, so one that could leave that folder is not
    /// one.
    init?(_ text: String) {
        guard let value = JSONValue.line(Substring(text)), case .object = value else { return nil }
        id = value["id"]?.string.flatMap(UUID.init(uuidString:))
        claude = value["claude"]?.string.flatMap { Self.isName($0) ? $0 : nil }
        account = value["account"]?.string
        codex = value["codex"]?.string.flatMap { Self.isName($0) ? $0 : nil }
        folder = value["folder"]?.string
        title = value["title"]?.string
        model = value["model"]?.string.flatMap { Self.isModel($0) ? $0 : nil }
        effort = value["effort"]?.string.flatMap { Self.isName($0) ? $0 : nil }
        guard id != nil || claude != nil || codex != nil else { return nil }
    }

    static func isName(_ text: String) -> Bool {
        !text.isEmpty && text.count <= 128
            && text.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" }
    }

    /// A model's name as the CLI takes it: `opus`, `claude-opus-5-5[1m]`.
    static func isModel(_ text: String) -> Bool {
        !text.isEmpty && text.count <= 128
            && text.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || "-_.[]".unicodeScalars.contains($0) }
    }

    /// What `conversation` is, kept: its first provider's session.
    @MainActor static func of(_ conversation: Conversation) -> String {
        var kept = Kept(id: conversation.id, folder: conversation.folder.path,
                        title: String(conversation.title.prefix(80)))
        if let session = conversation.claude, let id = session.sessionID {
            kept.claude = id
            kept.account = session.account.name
            kept.model = session.chosenModel
            kept.effort = session.effort
        }
        if let thread = conversation.codex?.threadID { kept.codex = thread }
        return kept.text
    }

    var text: String {
        func encoded(_ kept: Kept) -> String {
            var object: [String: JSONValue] = [:]
            if let id { object["id"] = .string(id.uuidString) }
            if let claude = kept.claude { object["claude"] = .string(claude) }
            if let account = kept.account { object["account"] = .string(account) }
            if let codex = kept.codex { object["codex"] = .string(codex) }
            if let folder = kept.folder { object["folder"] = .string(folder) }
            if let title = kept.title { object["title"] = .string(title) }
            if let model = kept.model { object["model"] = .string(model) }
            if let effort = kept.effort { object["effort"] = .string(effort) }
            return (try? JSONValue.object(object).encodedLine()) ?? "{}"
        }
        // The title goes first, then the folder: the session is what counts.
        var kept = self
        var line = encoded(kept)
        if line.count > Self.limit { kept.title = nil; line = encoded(kept) }
        if line.count > Self.limit { kept.folder = nil; line = encoded(kept) }
        return line
    }
}
