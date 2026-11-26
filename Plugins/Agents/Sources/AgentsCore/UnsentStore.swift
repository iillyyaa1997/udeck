import Foundation

/// Messages a Stop left unsent, by session (`claude:<id>`, `codex:<thread>`):
/// back when the session is open again — after this plugin started again, as
/// every update of uDeck restarts it (the operator, 11-26: «Терять сообщения
/// нельзя»). `~/.udeck/agents/unsent.json`, written whole and atomically when
/// they change; a session's not opened again within 30 days are dropped.
public struct UnsentStore: Sendable, Equatable, Codable {
    public struct Entry: Sendable, Equatable, Codable {
        public var texts: [String]
        public var at: Date
    }

    public var entries: [String: Entry] = [:]
    static let kept: TimeInterval = 30 * 86_400

    public init(entries: [String: Entry] = [:]) {
        self.entries = entries
    }

    public static func file(home: URL) -> URL {
        home.appendingPathComponent(".udeck/agents/unsent.json")
    }

    public static func load(home: URL) -> UnsentStore {
        guard let data = try? Data(contentsOf: file(home: home)) else { return UnsentStore() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return (try? decoder.decode(UnsentStore.self, from: data)) ?? UnsentStore()
    }

    public func save(home: URL) {
        let file = Self.file(home: home)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(self) else { return }
        try? data.write(to: file, options: .atomic)
    }

    /// `texts` as the session's unsent messages now: none removes it.
    public mutating func set(_ key: String, _ texts: [String], now: Date = Date()) {
        if texts.isEmpty {
            entries[key] = nil
        } else if entries[key]?.texts != texts {
            entries[key] = Entry(texts: texts, at: now)
        }
        entries = entries.filter { now.timeIntervalSince($0.value.at) < Self.kept }
    }
}
