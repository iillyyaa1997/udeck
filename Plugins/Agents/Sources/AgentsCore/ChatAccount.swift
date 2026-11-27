import Foundation
import UDeckAgents

/// A Claude account as the chat starts sessions under it: the main one is the
/// default config (`~/.claude`, what the terminal uses), every extra one a
/// folder of its own (`~/.claude-<name>`, the operator's mirror layout), passed
/// to the CLI as `CLAUDE_CONFIG_DIR`.
public struct ChatAccount: Sendable, Equatable, Hashable, Identifiable {
    public let name: String
    /// Nil for the main account: the CLI's default, no variable set.
    public let configDir: URL?
    public var id: String { name }

    public init(name: String, configDir: URL?) {
        self.name = name
        self.configDir = configDir
    }

    /// The folder the account's config lives in.
    public func folder(home: URL) -> URL {
        configDir ?? home.appendingPathComponent(".claude", isDirectory: true)
    }

    /// The main account and every `~/.claude-<name>` folder that has a login of
    /// its own (`.claude.json`), main first, the rest by name.
    public static func discover(home: URL, mainName: String = "main") -> [ChatAccount] {
        var accounts = [ChatAccount(name: mainName, configDir: nil)]
        let names = (try? FileManager.default.contentsOfDirectory(atPath: home.path)) ?? []
        for name in names.sorted() where name.hasPrefix(".claude-") {
            let folder = home.appendingPathComponent(name, isDirectory: true)
            guard FileManager.default.fileExists(atPath: folder.appendingPathComponent(".claude.json").path) else {
                continue
            }
            accounts.append(ChatAccount(name: String(name.dropFirst(".claude-".count)), configDir: folder))
        }
        return accounts
    }

    /// The environment a session under this account starts with: the user's
    /// shell environment, without the variables that would bill an API key
    /// instead of the subscription (spec §10.4), with the account's folder and
    /// the marker hooks can check (`UDECK_SESSION`).
    public func environment(from shell: [String: String]) -> [String: String] {
        var environment = shell
        for key in ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL", "CLAUDE_CODE_USE_BEDROCK",
                    "CLAUDE_CODE_USE_VERTEX", "CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT"]
        {
            environment[key] = nil
        }
        environment["CLAUDE_CONFIG_DIR"] = configDir?.path
        environment["UDECK_SESSION"] = "1"
        return environment
    }
}

/// A session saved on disk, as the history list shows it.
public struct SavedSession: Sendable, Equatable, Identifiable {
    public let sessionID: String
    public let file: URL
    public let cwd: String?
    /// The last thing the user typed in it.
    public let lastPrompt: String?
    public let modified: Date
    /// The session's own name: Claude Code's `custom-title` — the
    /// terminal's /rename, or a hook's.
    public var customTitle: String? = nil
    /// The first thing said in it that reads as a subject.
    public var firstWords: String? = nil
    /// What started it: `cli` for a terminal, `sdk-…` for a program.
    public var entrypoint: String? = nil
    public var id: String { sessionID }

    public var folderName: String? { cwd.map { URL(fileURLWithPath: $0).lastPathComponent } }

    /// Its name and where that came from, by what the transcript says (11-25):
    /// its own name, the first words said in it, the last ones, the folder.
    /// The last thing typed alone was «1» or «продолжай» more often than not.
    public var named: (String, NameSource) {
        if let customTitle { return (customTitle, .own) }
        if let firstWords { return (firstWords, .firstWords) }
        if let lastPrompt, let words = ChatNames.firstWords(lastPrompt) { return (words, .firstWords) }
        return (folderName ?? sessionID, .folder)
    }

    public var title: String { named.0 }

    /// Started by a program — a script, an orchestrator — not by a person.
    public var byAProgram: Bool { entrypoint?.hasPrefix("sdk") == true }
}

public enum SessionHistory {
    /// What a transcript says of itself, read from its head and its tail.
    public struct Glance: Sendable, Equatable {
        public var cwd: String?
        public var lastPrompt: String?
        public var customTitle: String?
        public var firstWords: String?
        public var entrypoint: String?
    }

    /// The glances of transcripts read before, by path, with the size and
    /// date they had: one that has not changed is not read again.
    public typealias Glances = [String: (size: Int, modified: Date, glance: Glance)]

    /// The most recently changed sessions in `config/projects`, newest first.
    /// Reads only each file's tail and head, so a transcript of many megabytes
    /// costs no more than a small one; with `glances`, only the files that
    /// changed since.
    public static func recent(config: URL, limit: Int = 60) -> [SavedSession] {
        var glances: Glances = [:]
        return recent(config: config, limit: limit, glances: &glances)
    }

    public static func recent(config: URL, limit: Int, keep: (SavedSession) -> Bool = { _ in true },
                              looked: Int? = nil, glances: inout Glances) -> [SavedSession] {
        let projects = SessionHistory.projects(of: config)
        let manager = FileManager.default
        guard let folders = try? manager.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil) else {
            return []
        }
        var files: [(URL, Date, Int)] = []
        for folder in folders {
            guard let entries = try? manager.contentsOfDirectory(at: folder,
                                                                 includingPropertiesForKeys: [.contentModificationDateKey,
                                                                                              .fileSizeKey])
            else { continue }
            for file in entries where file.pathExtension == "jsonl" {
                let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                files.append((file, values?.contentModificationDate ?? .distantPast, values?.fileSize ?? 0))
            }
        }
        files.sort { $0.1 > $1.1 }
        var out: [SavedSession] = []
        var seen: Set<String> = []
        for (file, date, size) in files.prefix(looked ?? limit) {
            let glance: Glance
            if let known = glances[file.path], known.size == size, known.modified == date {
                glance = known.glance
            } else {
                glance = Self.glance(file)
                glances[file.path] = (size, date, glance)
            }
            seen.insert(file.path)
            let saved = SavedSession(sessionID: file.deletingPathExtension().lastPathComponent, file: file,
                                     cwd: glance.cwd, lastPrompt: glance.lastPrompt, modified: date,
                                     customTitle: glance.customTitle, firstWords: glance.firstWords,
                                     entrypoint: glance.entrypoint)
            if keep(saved) { out.append(saved) }
            if out.count == limit { break }
        }
        glances = glances.filter { seen.contains($0.key) }
        return out
    }

    /// An account's transcripts folder, its link followed: a mirrored
    /// account's `projects` links to the main one's, and a directory listing
    /// of the link itself fails («couldn't be opened», measured 11-27) — no
    /// session of `pers2` was found to continue after a restart.
    public static func projects(of config: URL) -> URL {
        config.appendingPathComponent("projects", isDirectory: true).resolvingSymlinksInPath()
    }

    /// The saved session `sessionID` of the account whose folder is `config`,
    /// wherever its project is; nil when there is none.
    public static func saved(_ sessionID: String, config: URL) -> SavedSession? {
        let projects = SessionHistory.projects(of: config)
        let manager = FileManager.default
        guard Kept.isName(sessionID),
              let folders = try? manager.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil) else { return nil }
        for folder in folders {
            let file = folder.appendingPathComponent(sessionID + ".jsonl")
            guard manager.fileExists(atPath: file.path) else { continue }
            let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            let glance = glance(file)
            return SavedSession(sessionID: sessionID, file: file, cwd: glance.cwd, lastPrompt: glance.lastPrompt,
                                modified: date ?? .distantPast, customTitle: glance.customTitle,
                                firstWords: glance.firstWords, entrypoint: glance.entrypoint)
        }
        return nil
    }

    /// The working folder, what started the session and the first words said
    /// in it (from the head); its last prompt and its own name (from the
    /// tail, where Claude Code writes them again as they change).
    public static func glance(_ file: URL) -> Glance {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return Glance() }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 64 * 1024)) ?? Data()
        let size = (try? handle.seekToEnd()) ?? 0
        let tailStart = size > 256 * 1024 ? size - 256 * 1024 : 0
        try? handle.seek(toOffset: tailStart)
        let tail = (try? handle.readToEnd()) ?? Data()
        var glance = Glance()
        let headLines = String(decoding: head, as: UTF8.self).split(separator: "\n")
        for line in headLines {
            guard let value = JSONValue.line(line) else { continue }
            if glance.cwd == nil, let found = value["cwd"]?.string { glance.cwd = found }
            if glance.entrypoint == nil, let found = value["entrypoint"]?.string { glance.entrypoint = found }
            if value["type"]?.string == "custom-title", let found = value["customTitle"]?.string {
                glance.customTitle = ChatNames.own(found)
            }
            if glance.firstWords == nil, value["type"]?.string == "user", value["isMeta"]?.bool != true,
               let text = userText(value), case .said(let words) = spoken(text) {
                glance.firstWords = ChatNames.firstWords(words)
            }
        }
        let tailLines = String(decoding: tail, as: UTF8.self).split(separator: "\n")
        // The newest of each, from the end: a later custom-title replaces
        // the one in the head.
        var lastPrompt: String?
        var newestTitle: String?
        for line in tailLines.reversed() {
            if lastPrompt != nil, newestTitle != nil { break }
            guard line.contains("\"last-prompt\"") || line.contains("\"custom-title\""),
                  let value = JSONValue.line(line) else { continue }
            if lastPrompt == nil, value["type"]?.string == "last-prompt", let found = value["lastPrompt"]?.string {
                lastPrompt = found
            }
            if newestTitle == nil, value["type"]?.string == "custom-title", let found = value["customTitle"]?.string {
                newestTitle = ChatNames.own(found)
            }
        }
        glance.lastPrompt = lastPrompt
        if let newestTitle { glance.customTitle = newestTitle }
        if glance.cwd == nil {
            for line in tailLines {
                if let value = JSONValue.line(line), let found = value["cwd"]?.string { glance.cwd = found; break }
            }
        }
        return glance
    }

    /// How a saved session began, as feed items, from the head of its
    /// transcript: what a model names it by.
    public static func opening(of file: URL, bytes: Int = 400_000) -> [FeedItem] {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return [] }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: bytes)) ?? Data()
        return feed(of: ClaudeTranscript(contents: String(decoding: head, as: UTF8.self)), limit: 60)
    }

    /// The text of a transcript's user line: what was typed, not tool results.
    static func userText(_ value: JSONValue) -> String? {
        let content = value["message"]?["content"]
        if let text = content?.string { return text }
        let texts = (content?.array ?? []).compactMap { block -> String? in
            block["type"]?.string == "text" ? block["text"]?.string : nil
        }
        return texts.isEmpty ? nil : texts.joined(separator: "\n")
    }

    /// A saved session's conversation as feed items, for the feed of a resume.
    /// With `before`, only what was said before then: for a session the helper
    /// kept running, the run it journals replays the rest.
    /// The feed of a saved session from the last `bytes` of its transcript:
    /// the newest of it is what the card shows, and the whole of a long
    /// session's file is a hundred megabytes.
    public static func tailFeed(of file: URL, bytes: Int = 3_000_000) -> [FeedItem] {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(bytes) ? size - UInt64(bytes) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return [] }
        var text = String(decoding: data, as: UTF8.self)
        // A tail starts mid-line: what is before the first newline is not a line.
        if start > 0, let newline = text.firstIndex(of: "\n") { text = String(text[text.index(after: newline)...]) }
        return feed(of: ClaudeTranscript(contents: text))
    }

    public static func feed(of transcript: ClaudeTranscript, before: Date? = nil, limit: Int = 400) -> [FeedItem] {
        var items: [FeedItem] = []
        for entry in transcript.entries {
            if let before {
                let at: Date? = switch entry {
                case .userText(_, let at), .assistant(_, let at), .toolResults(_, let at): at
                }
                if let at, at >= before { break }
            }
            switch entry {
            case .userText(let text, _):
                switch spoken(text) {
                case .said(let words): items.append(.user(id: UUID(), text: words))
                case .compacted: items.append(.note(id: UUID(), text: "compacted"))
                case .machine: continue
                }
            case .assistant(let message, _):
                for block in message.blocks {
                    switch block {
                    case .text(let text) where !text.isEmpty:
                        items.append(.assistant(id: UUID(), text: text, streaming: false))
                    case .toolUse(let id, let name, let input):
                        items.append(.tool(id: id, name: name, summary: ToolSummary.of(name: name, input: input),
                                           result: nil))
                    default:
                        continue
                    }
                }
            case .toolResults(let results, _):
                for result in results {
                    guard let index = items.lastIndex(where: { $0.id == "tool-" + result.toolUseID }),
                          case .tool(let id, let name, let summary, _) = items[index]
                    else { continue }
                    let preview = result.text.split(separator: "\n", omittingEmptySubsequences: false).prefix(6)
                        .joined(separator: "\n")
                    items[index] = .tool(id: id, name: name, summary: summary,
                                         result: ToolOutcome(isError: result.isError, preview: String(preview.prefix(600))))
                }
            }
        }
        return Array(items.suffix(limit))
    }

    enum Spoken: Equatable {
        case said(String)
        /// The summary Claude Code writes in place of a compacted conversation.
        case compacted
        /// Written into the transcript by the tool, not typed by the person:
        /// background-task notices, reminders, local command output.
        case machine
    }

    /// What a user line of a transcript is: the person's words (a slash
    /// command shown as they typed it), the compaction summary, or something
    /// the tool wrote there.
    static func spoken(_ text: String) -> Spoken {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("This session is being continued from a previous conversation") { return .compacted }
        if trimmed.hasPrefix("<command-name>") || trimmed.hasPrefix("<command-message>") {
            let name = tag("command-name", in: trimmed) ?? ""
            let args = tag("command-args", in: trimmed) ?? ""
            let typed = [name, args].filter { !$0.isEmpty }.joined(separator: " ")
            return typed.isEmpty ? .machine : .said(typed)
        }
        let machinePrefixes = ["<task-notification>", "<system-reminder>", "<local-command-", "<bash-input>",
                               "<bash-stdout>", "<bash-stderr>", "<user-prompt-submit-hook>",
                               "Caveat: The messages below were generated by the user while running local commands",
                               // A skill's text, put in as it loads: the person did not type it.
                               "Base directory for this skill:"]
        if machinePrefixes.contains(where: trimmed.hasPrefix) { return .machine }
        return .said(text)
    }

    private static func tag(_ name: String, in text: String) -> String? {
        guard let open = text.range(of: "<\(name)>"),
              let close = text.range(of: "</\(name)>", range: open.upperBound..<text.endIndex)
        else { return nil }
        return String(text[open.upperBound..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
