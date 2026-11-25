import Foundation
import UDeckAgents

/// Where a session's name came from, weakest first (11-25). A name is taken
/// over only by one from as strong a source or a stronger one: the person's
/// own `/rename` here beats a name a model made up, which beats the session's
/// own — Claude Code's `custom-title`, Codex's thread name — which beats the
/// first words said in it; the folder is what a session is called before
/// anything is said. The model's is above the session's own because a
/// terminal's status line writes `custom-title` too («operator skill», «ZT-0
/// only slit» — every name of the operator's history, 11-25), and nothing
/// tells it from a /rename (the operator: «1»).
public enum NameSource: Int, Comparable, Sendable, Codable {
    case folder, firstWords, own, model, person

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// What this plugin keeps of the sessions it ran, by `claude:<id>` or
/// `codex:<thread id>`: the name a model made up for one, or the person gave
/// it here — and, for every one, that it is this plugin's: the history lists
/// those although no terminal started them, and leaves out the sessions
/// scripts run (`entrypoint` sdk-…).
///
/// `~/.udeck/agents/names.json`, written whole and atomically; the newest
/// `kept` only.
public struct ChatNames: Sendable, Equatable, Codable {
    public struct Entry: Sendable, Equatable, Codable {
        public var name: String?
        public var byPerson: Bool
        public var at: Date

        public init(name: String? = nil, byPerson: Bool = false, at: Date = Date()) {
            self.name = name
            self.byPerson = byPerson
            self.at = at
        }

        /// The name with where it came from, if there is one.
        public var named: (String, NameSource)? { name.map { ($0, byPerson ? .person : .model) } }
    }

    public var entries: [String: Entry] = [:]
    static let kept = 500

    public init(entries: [String: Entry] = [:]) {
        self.entries = entries
    }

    public static func key(_ provider: Provider, _ id: String) -> String { provider.rawValue + ":" + id }

    public static func file(home: URL) -> URL {
        home.appendingPathComponent(".udeck/agents/names.json")
    }

    public static func load(home: URL) -> ChatNames {
        guard let data = try? Data(contentsOf: file(home: home)) else { return ChatNames() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return (try? decoder.decode(ChatNames.self, from: data)) ?? ChatNames()
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

    /// The session is this plugin's; true when that is news.
    @discardableResult
    public mutating func mark(_ key: String) -> Bool {
        guard entries[key] == nil else { return false }
        entries[key] = Entry()
        prune()
        return true
    }

    /// The session's name: a model's, or the person's — which a model's
    /// never replaces.
    public mutating func name(_ key: String, _ name: String, byPerson: Bool) {
        if !byPerson, entries[key]?.byPerson == true { return }
        entries[key] = Entry(name: name, byPerson: byPerson)
        prune()
    }

    private mutating func prune() {
        guard entries.count > Self.kept else { return }
        let newest = entries.sorted { $0.value.at > $1.value.at }.prefix(Self.kept)
        entries = Dictionary(uniqueKeysWithValues: newest.map { ($0.key, $0.value) })
    }
}

// MARK: - Names out of words

extension ChatNames {
    /// What a session is called by the first thing said in it, if that reads
    /// as a subject: its first line — pasted blocks and tags left out, a
    /// leading option number too — cut at a word. Nil for a bare answer
    /// («1», «да», «продолжай»), a command, or nothing left.
    public static func firstWords(_ text: String, limit: Int = 48) -> String? {
        var text = text.replacingOccurrences(of: #"<pasted_content[^>]*>[\s\S]*?</pasted_content>"#, with: " ",
                                             options: .regularExpression)
        text = text.replacingOccurrences(of: #"<[^<>\n]{1,200}>"#, with: " ", options: .regularExpression)
        guard let line = text.split(separator: "\n").lazy.map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { !$0.isEmpty }) else { return nil }
        guard !line.hasPrefix("/") else { return nil }
        let words = line.replacingOccurrences(of: #"^\d+[.)]?(\s+|$)"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        let letters = words.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
        guard letters >= 3 else { return nil }
        let bare = words.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
        guard !Self.bareAnswers.contains(bare) else { return nil }
        return cut(words, limit: limit)
    }

    /// Answers and greetings that say nothing of what a session is about.
    static let bareAnswers: Set<String> = [
        "да", "нет", "ок", "окей", "ага", "угу", "давай", "продолжай", "продолжи", "дальше", "го", "спасибо",
        "да давай", "давай дальше", "yes", "no", "ok", "okay", "sure", "yep", "nope", "continue", "go", "go on",
        "next", "thanks", "thank you",
        // Greetings: nothing of a subject either.
        "привет", "здравствуй", "здравствуйте", "добрый день", "hello", "hi", "hey",
    ]

    /// A session's own name as it was given — by the terminal's /rename, a
    /// hook, Codex: its first line, within `limit`.
    public static func own(_ text: String, limit: Int = 80) -> String? {
        guard let line = text.split(separator: "\n").lazy.map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { !$0.isEmpty }) else { return nil }
        return cut(line, limit: limit)
    }

    /// Whether a model's name will not do: it starts with continuing or
    /// helping — «Продолжение…», «Помощь с…», «Continue…» — or runs past six
    /// words. Such a name is asked for once more.
    public static func willNotDo(_ name: String) -> Bool {
        let words = name.trimmingCharacters(in: CharacterSet(charactersIn: "«»\"' ").union(.whitespacesAndNewlines))
        let lowered = words.lowercased()
        let starts = ["продолж", "помощь", "помоги", "работа над", "continu", "help"]
        return starts.contains { lowered.hasPrefix($0) } || words.split(separator: " ").count > 6
    }

    /// A name that still will not do after the second try, made to: what is
    /// after «Продолжение …:» when there is a colon, what is before the first
    /// colon or comma of one too long.
    static func tidied(_ name: String) -> String {
        guard willNotDo(name) else { return name }
        let lowered = name.lowercased()
        let continuing = ["продолж", "помощь", "помоги", "работа над", "continu", "help"].contains { lowered.hasPrefix($0) }
        if continuing, let colon = name.firstIndex(of: ":") {
            let rest = name[name.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if !rest.isEmpty { return rest.prefix(1).uppercased() + rest.dropFirst() }
        }
        if name.split(separator: " ").count > 6, let cut = name.firstIndex(where: { $0 == ":" || $0 == "," }) {
            let head = name[..<cut].trimmingCharacters(in: .whitespaces)
            if !head.isEmpty { return head }
        }
        return name
    }

    /// A model's answer as a name: its first line, without quotes, a label
    /// («Title:») or a closing full stop. Nil for nothing, or for more than a
    /// name — a model that answered the conversation instead.
    public static func cleaned(_ answer: String, limit: Int = 60) -> String? {
        guard var line = answer.split(separator: "\n").lazy.map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { !$0.isEmpty }) else { return nil }
        line = line.replacingOccurrences(of: #"^(?i)(title|name|название|имя)\s*:\s*"#, with: "",
                                         options: .regularExpression)
        line = line.trimmingCharacters(in: CharacterSet(charactersIn: "\"'«»“”„`*#").union(.whitespaces))
        while let last = line.last, ".。!".contains(last) { line.removeLast() }
        line = line.trimmingCharacters(in: CharacterSet(charactersIn: "\"'«»“”„`*").union(.whitespaces))
        line = tidied(line)
        guard !line.isEmpty, line.split(separator: " ").count <= 10 else { return nil }
        return cut(line, limit: limit)
    }

    /// `text` within `limit` characters: cut at the last word that fits, «…» after.
    static func cut(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        var cut = String(text.prefix(limit))
        if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) > limit / 2 {
            cut = String(cut[..<space])
        }
        cut = cut.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: ",;:—-–")))
        return cut + "…"
    }
}
