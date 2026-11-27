import Foundation
import UDeckAgents

/// What survives this plugin starting again — every update of uDeck restarts
/// it: every open conversation, not only the one a place shows (11-27,
/// «чаты сбросились»: 0.9.20 installed itself at night, and of two sessions
/// only the one a window kept could come back), and the effort a Claude
/// session runs with when none was chosen here.
extension AgentsApp {
    static func openFile(home: URL) -> URL {
        home.appendingPathComponent(".udeck/agents/open.json")
    }

    /// The open conversations as `Kept` lines, oldest first, as last written.
    static func loadOpen(home: URL) -> [String] {
        guard let data = try? Data(contentsOf: openFile(home: home)),
              let lines = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return lines.filter { Kept($0) != nil }
    }

    /// The open conversations, on disk when they change — once those of the
    /// last run have come back, so that a start does not write them away.
    func keepOpen() {
        guard openRestored else { return }
        let lines = conversations.filter { !$0.current.isEnded || $0.claude?.sessionID != nil || $0.codex?.threadID != nil }
            .map { Kept.of($0) }
            .filter { line in Kept(line).map { $0.claude != nil || $0.codex != nil } ?? false }
        guard lines != openLines else { return }
        openLines = lines
        let file = Self.openFile(home: home)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        guard let data = try? JSONEncoder().encode(lines) else { return }
        try? data.write(to: file, options: .atomic)
    }

    /// The last run's open conversations, back — after the places have taken
    /// theirs (`keep`), without changing what any place shows.
    func restoreOpen() {
        guard !openRestored else { return }
        let shown = places.mapValues(\.selection)
        let current = here
        for line in Self.loadOpen(home: home) {
            guard let kept = Kept(line) else { continue }
            let open = conversations.contains { conversation in
                (kept.claude != nil && conversation.claude?.sessionID == kept.claude)
                    || (kept.codex != nil && conversation.codex?.threadID == kept.codex)
            }
            if !open { restore(line) }
        }
        here = current
        for (name, selection) in shown {
            guard let selection, places[name] != nil else { continue }
            places[name]?.selection = selection
        }
        openRestored = true
        keepOpen()
        render()
    }

    /// The effort the card says: the one chosen here, or else the one the CLI
    /// runs with — the account's `effortLevel` in its settings — rather than
    /// the bare word «усилие» (11-27).
    func effortShown(_ agent: Agent) -> String? {
        if let chosen = agent.effort { return chosen }
        guard case .claude(let session) = agent else { return nil }
        let file = session.account.folder(home: home).appendingPathComponent("settings.json")
        let now = Date()
        if let cached = settingsEffort[file.path], now.timeIntervalSince(cached.at) < 30 { return cached.level }
        let level = (try? Data(contentsOf: file)).flatMap { JSONValue.line(Substring(String(decoding: $0, as: UTF8.self))) }?["effortLevel"]?.string
        settingsEffort[file.path] = (level, now)
        return level
    }
}
