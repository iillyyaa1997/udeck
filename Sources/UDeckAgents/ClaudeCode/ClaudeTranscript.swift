import Foundation

/// A Claude Code session as it is saved on disk, read back for the chat's feed.
///
/// `--resume` continues a session but does not replay it, so a session opened
/// in uDeck — one started earlier in a terminal, or before uDeck restarted —
/// is drawn from its transcript: `projects/<folder>/<session id>.jsonl` in the
/// account's config. The file holds much more than the conversation (requests,
/// attachments, bookkeeping of many kinds, changing between versions); only the
/// conversation is read here, everything else is skipped, so a new kind of entry
/// never breaks reading an old session.
public struct ClaudeTranscript: Sendable, Equatable {
    public enum Entry: Sendable, Equatable {
        case userText(String, at: Date?)
        case assistant(ClaudeAssistantMessage, at: Date?)
        case toolResults([ClaudeToolResult], at: Date?)
    }

    public let sessionID: String
    public let cwd: String?
    public let gitBranch: String?
    /// The last thing the user typed, as Claude Code keeps it for its resume list.
    public let lastPrompt: String?
    /// The conversation of the main thread, in file order; subagents' turns
    /// (sidechains) are not in it.
    public let entries: [Entry]

    public init(contents: String) {
        var sessionID = "", cwd: String?, branch: String?, lastPrompt: String?
        var entries: [Entry] = []
        for line in contents.split(separator: "\n") {
            guard let raw = JSONValue.line(line) else { continue }
            if let id = raw["sessionId"]?.string, sessionID.isEmpty { sessionID = id }
            switch raw["type"]?.string {
            case "last-prompt":
                lastPrompt = raw["lastPrompt"]?.string ?? lastPrompt
            case "user" where raw["isSidechain"]?.bool != true:
                cwd = raw["cwd"]?.string ?? cwd
                branch = raw["gitBranch"]?.string ?? branch
                let at = raw["timestamp"]?.string.flatMap(parseDate)
                let content = raw["message"]?["content"]
                if let text = content?.string {
                    entries.append(.userText(text, at: at))
                } else if let blocks = content?.array {
                    let results = ClaudeToolResult.all(in: raw)
                    if !results.isEmpty {
                        entries.append(.toolResults(results, at: at))
                    } else {
                        let text = blocks.compactMap { $0["type"]?.string == "text" ? $0["text"]?.string : nil }
                            .joined(separator: "\n")
                        if !text.isEmpty { entries.append(.userText(text, at: at)) }
                    }
                }
            case "assistant" where raw["isSidechain"]?.bool != true:
                entries.append(.assistant(ClaudeAssistantMessage(raw), at: raw["timestamp"]?.string.flatMap(parseDate)))
            default:
                continue
            }
        }
        self.sessionID = sessionID
        self.cwd = cwd
        self.gitBranch = branch
        self.lastPrompt = lastPrompt
        self.entries = entries
    }

    public init(url: URL) throws {
        self.init(contents: try String(contentsOf: url, encoding: .utf8))
    }
}
