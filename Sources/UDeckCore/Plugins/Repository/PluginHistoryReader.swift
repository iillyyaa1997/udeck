import Foundation

/// A plugin's earlier versions, found in its folder's history.
///
/// A repository keeps every version it ever had in its history, so that is
/// where uDeck looks — there is no list of releases to maintain:
///
/// 1. the commits on the default branch that changed `plugins/<id>`, newest
///    first — one API request;
/// 2. for each, newest first, up to 50, that commit's `manifest.json` from the
///    raw host; a commit where the folder did not exist is skipped;
/// 3. one line per distinct `version`, taken from the newest commit that has
///    it — that version as it finally was — with its date.
///
/// The "newest commit per version" rule is what keeps a half-finished state
/// in a repository that merges with merge commits from being offered as a
/// version. The result is kept while the head commit is unchanged.
public struct PluginHistoryReader: Sendable {
    public let provider: any RepositoryProvider
    public let store: CatalogueStore

    /// The most commits read per plugin.
    public static let deepest = 50

    public init(provider: any RepositoryProvider, store: CatalogueStore) {
        self.provider = provider
        self.store = store
    }

    public func read(_ id: String, branch: String, head: String) async throws -> PluginHistory {
        if let kept = store.history(id), kept.headCommit == head { return kept }
        let commits = Array(try await provider.commits(
            touching: "\(CommitListing.pluginsFolder)/\(id)", on: branch
        ).prefix(Self.deepest))

        // Four at a time, like an install; the order is put back afterwards.
        var manifests: [Int: Data] = [:]
        try await withThrowingTaskGroup(of: (Int, Data?).self) { group in
            var next = 0
            func add() {
                let index = next
                let commit = commits[index]
                next += 1
                group.addTask {
                    do {
                        let data = try await provider.file(
                            at: "\(CommitListing.pluginsFolder)/\(id)/\(PluginDiscovery.manifestFilename)",
                            commit: commit.sha)
                        return (index, data)
                    } catch ProviderError.notFound {
                        // The folder did not exist at that commit.
                        return (index, nil)
                    }
                }
            }
            while next < min(4, commits.count) { add() }
            while let (index, data) = try await group.next() {
                if let data { manifests[index] = data }
                if next < commits.count { add() }
            }
        }

        var seen = Set<String>()
        var lines: [PluginHistory.Line] = []
        for (index, commit) in commits.enumerated() {
            guard let data = manifests[index] else { continue }
            // Stored by its own hash, so installing this version later finds
            // the manifest its listing names without asking again.
            _ = try? store.save(blob: data)
            guard let manifest = try? JSONDecoder().decode(PluginManifest.self, from: data) else { continue }
            guard seen.insert(manifest.version).inserted else { continue }
            lines.append(PluginHistory.Line(version: manifest.version, commit: commit.sha,
                                            date: commit.date, manifest: manifest))
        }
        let history = PluginHistory(id: id, headCommit: head, lines: lines)
        try? store.save(history)
        return history
    }
}

extension PluginHistory.Line {
    /// Why this version cannot run here, if it cannot: the `api` and the
    /// `minUDeck` it declares.
    public func refusal(udeck: SemanticVersion?) -> RepositoryRefusal? {
        guard let manifest else { return .noManifest(path: "manifest.json") }
        let supported = PluginAPI.oldestSupported ... PluginAPI.current
        if !supported.contains(manifest.api) {
            return .apiNotSpoken(name: manifest.name, version: manifest.version, api: manifest.api)
        }
        if let text = manifest.minUDeck {
            guard let required = SemanticVersion(text) else {
                return .minUDeckNotComparable(name: manifest.name, text: text)
            }
            if let udeck, required > udeck {
                return .needsNewerUDeck(name: manifest.name, version: manifest.version,
                                        required: required.description, running: udeck.description)
            }
        }
        if SemanticVersion(manifest.version) == nil {
            return .versionNotComparable(name: manifest.name, version: manifest.version)
        }
        return nil
    }
}

/// Whether a window's plugin is there to run, as the window shows it.
///
/// Windows are never removed because a plugin is missing. A window whose
/// plugin is not in the folder — replaced mid-rename, a manifest saved with a
/// typo, a working copy switched between branches — stays where it is and says
/// so, with **Reinstall** when `installed.json` knows where it came from and
/// **Remove from tab** always. It goes only when the operator removes it, or
/// when the plugin is removed through uDeck.
public enum PluginPresence: Equatable, Sendable {
    /// Found and usable.
    case present
    /// A folder is there under this id, and it will not run: its problems.
    /// `reinstallable` as for `missing`.
    case broken([String], reinstallable: Bool)
    /// No folder under this id at all. `reinstallable` when uDeck installed it
    /// and may ask the repository for it — **Official catalogue** is on.
    case missing(reinstallable: Bool)

    /// Where `id` stands among the folders found and the records kept.
    ///
    /// `readsCatalogue` is the **Official catalogue** switch. Off, uDeck makes
    /// no request about plugins at all, and **Reinstall** is a download, so it
    /// is not offered — as **Back to** and **Earlier versions** are not.
    public static func of(
        _ id: PluginIdentifier,
        plugins: [DiscoveredPlugin],
        installed: InstalledPlugins,
        readsCatalogue: Bool
    ) -> PluginPresence {
        let reinstallable = installed[id] != nil && readsCatalogue
        if let plugin = plugins.first(where: { $0.manifest?.id == id && $0.folderName == id.rawValue }) {
            return plugin.isUsable
                ? .present : .broken(plugin.problems.filter(\.isFatal).map(\.description), reinstallable: reinstallable)
        }
        if let folder = plugins.first(where: { $0.folderName == id.rawValue }) {
            return .broken(folder.problems.filter(\.isFatal).map(\.description), reinstallable: reinstallable)
        }
        return .missing(reinstallable: reinstallable)
    }
}
