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
    public var id: String { sessionID }

    public var title: String {
        if let lastPrompt, !lastPrompt.isEmpty { return String(lastPrompt.prefix(80)) }
        return cwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? sessionID
    }
}

public enum SessionHistory {
    /// The most recently changed sessions in `config/projects`, newest first.
    /// Reads only each file's tail and head, so a transcript of many megabytes
    /// costs no more than a small one.
    public static func recent(config: URL, limit: Int = 60) -> [SavedSession] {
        let projects = config.appendingPathComponent("projects", isDirectory: true)
        let manager = FileManager.default
        guard let folders = try? manager.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil) else {
            return []
        }
        var files: [(URL, Date)] = []
        for folder in folders {
            guard let entries = try? manager.contentsOfDirectory(at: folder,
                                                                 includingPropertiesForKeys: [.contentModificationDateKey])
            else { continue }
            for file in entries where file.pathExtension == "jsonl" {
                let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                files.append((file, date ?? .distantPast))
            }
        }
        files.sort { $0.1 > $1.1 }
        return files.prefix(limit).map { file, date in
            let (cwd, prompt) = glance(file)
            return SavedSession(sessionID: file.deletingPathExtension().lastPathComponent, file: file, cwd: cwd,
                                lastPrompt: prompt, modified: date)
        }
    }

    /// The working folder (from the head) and the last prompt (from the tail).
    static func glance(_ file: URL) -> (cwd: String?, lastPrompt: String?) {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return (nil, nil) }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 64 * 1024)) ?? Data()
        let size = (try? handle.seekToEnd()) ?? 0
        let tailStart = size > 256 * 1024 ? size - 256 * 1024 : 0
        try? handle.seek(toOffset: tailStart)
        let tail = (try? handle.readToEnd()) ?? Data()
        var cwd: String?
        for line in String(decoding: head, as: UTF8.self).split(separator: "\n") {
            if let value = JSONValue.line(line), let found = value["cwd"]?.string { cwd = found; break }
        }
        var prompt: String?
        for line in String(decoding: tail, as: UTF8.self).split(separator: "\n").reversed() {
            guard let value = JSONValue.line(line) else { continue }
            if value["type"]?.string == "last-prompt", let found = value["lastPrompt"]?.string { prompt = found; break }
        }
        if cwd == nil {
            for line in String(decoding: tail, as: UTF8.self).split(separator: "\n") {
                if let value = JSONValue.line(line), let found = value["cwd"]?.string { cwd = found; break }
            }
        }
        return (cwd, prompt)
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
                               "Caveat: The messages below were generated by the user while running local commands"]
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
