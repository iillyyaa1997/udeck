import Foundation

/// An extra Claude account as a mirror of the main one.
///
/// Measured on the operator's Mac (2026-11-21): his second account's folder links
/// every entry to `~/.claude` except the account's own login state — so settings,
/// skills, plugins, memory and the sessions themselves (`projects/`) are shared,
/// two logins run side by side, and a session continues under the other account
/// with `--resume`. A new account uDeck sets up is laid out the same way, and
/// `reconcile` keeps it so as the main folder grows new entries.
///
/// Never touched: the account's own entries, and anything already in the mirror
/// that is not a link — a real file or folder there is the user's, and uDeck does
/// not replace it.
public enum AccountMirror {
    /// Entries that belong to one account and are never shared: the login state
    /// (`.claude.json` holds the signed-in account and per-account trust and MCP
    /// state; `.credentials.json` is where Linux keeps the token), its backups,
    /// and the lock and log files Claude Code writes per process.
    public static let ownEntries: Set<String> = [".claude.json", ".credentials.json", "backups"]

    public enum Step: Sendable, Equatable {
        case link(name: String, to: URL)
        /// A link pointing somewhere other than the main folder's entry.
        case relink(name: String, to: URL)
        /// A real file or folder where a link would go: left alone, reported.
        case keep(name: String)
    }

    /// What it would take to make `mirror` a mirror of `main`. Pure: reads both
    /// folders, changes nothing.
    public static func plan(main: URL, mirror: URL) throws -> [Step] {
        let manager = FileManager.default
        let names = try manager.contentsOfDirectory(atPath: main.path).filter { !ownEntries.contains($0) }.sorted()
        return names.compactMap { name in
            let source = main.appendingPathComponent(name)
            let target = mirror.appendingPathComponent(name)
            guard let attributes = try? manager.attributesOfItem(atPath: target.path) else {
                return .link(name: name, to: source)
            }
            if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                let destination = try? manager.destinationOfSymbolicLink(atPath: target.path)
                let resolved = destination.map { URL(fileURLWithPath: $0, relativeTo: mirror).standardizedFileURL.path }
                return resolved == source.standardizedFileURL.path ? nil : .relink(name: name, to: source)
            }
            return .keep(name: name)
        }
    }

    /// Creates `mirror` if needed and carries out `plan`. Returns the steps taken;
    /// `.keep` steps are returned too, so the caller can say what it left alone.
    @discardableResult
    public static func reconcile(main: URL, mirror: URL) throws -> [Step] {
        let manager = FileManager.default
        try manager.createDirectory(at: mirror, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        let steps = try plan(main: main, mirror: mirror)
        for step in steps {
            switch step {
            case .link(let name, let source):
                try manager.createSymbolicLink(at: mirror.appendingPathComponent(name), withDestinationURL: source)
            case .relink(let name, let source):
                let target = mirror.appendingPathComponent(name)
                try manager.removeItem(at: target) // a link: removing it removes the link, not what it points to
                try manager.createSymbolicLink(at: target, withDestinationURL: source)
            case .keep:
                continue
            }
        }
        return steps
    }
}
