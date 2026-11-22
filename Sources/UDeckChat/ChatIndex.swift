import Foundation

/// What the chat remembers of its sessions across its own restarts: enough to
/// find a session the helper kept running and draw it again — its folder,
/// account, title and Claude Code's id for it. The conversation is not here: it
/// is in the helper's journal and Claude Code's transcript.
///
/// `~/.udeck/agents/chat-sessions.json`, written whole and atomically.
public struct ChatIndex: Sendable, Equatable, Codable {
    public struct Entry: Sendable, Equatable, Codable {
        /// The chat's id for the session, which is also the helper's.
        public var id: String
        public var folder: String
        public var account: String
        public var title: String
        public var claudeSessionID: String?

        public init(id: String, folder: String, account: String, title: String, claudeSessionID: String?) {
            self.id = id
            self.folder = folder
            self.account = account
            self.title = title
            self.claudeSessionID = claudeSessionID
        }
    }

    public var entries: [Entry] = []

    public init(entries: [Entry] = []) {
        self.entries = entries
    }

    public static func file(home: URL) -> URL {
        home.appendingPathComponent(".udeck/agents/chat-sessions.json")
    }

    public static func load(home: URL) -> ChatIndex {
        guard let data = try? Data(contentsOf: file(home: home)),
              let index = try? JSONDecoder().decode(ChatIndex.self, from: data)
        else { return ChatIndex() }
        return index
    }

    public func save(home: URL) {
        let file = Self.file(home: home)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self) else { return }
        try? data.write(to: file, options: .atomic)
    }

    public mutating func upsert(_ entry: Entry) {
        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[index] = entry
        } else {
            entries.append(entry)
        }
    }

    public mutating func remove(_ id: String) {
        entries.removeAll { $0.id == id }
    }
}

extension SessionHistory {
    /// A saved session's transcript by Claude Code's id, wherever its project
    /// folder is.
    public static func transcript(ofSession id: String, config: URL) -> URL? {
        let projects = config.appendingPathComponent("projects", isDirectory: true)
        guard let folders = try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)
        else { return nil }
        for folder in folders {
            let file = folder.appendingPathComponent(id + ".jsonl")
            if FileManager.default.fileExists(atPath: file.path) { return file }
        }
        return nil
    }
}
