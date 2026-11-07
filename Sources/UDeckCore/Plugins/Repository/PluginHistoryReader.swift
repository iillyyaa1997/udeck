import Foundation

/// A plugin's earlier versions, found in its folder's history.
///
/// A repository keeps every version it ever had in its history, so that is
/// where uDeck looks — there is no list of releases to maintain:
///
/// 1. the commits on the default branch that changed `plugins/<id>`, newest
///    first — one API request;
/// 2. for each, newest first, up to 50, that commit's `manifest.json` — from
///    the raw host on GitHub, a dozen to a request on GitLab
///    (`RepositoryProvider.files(at:commits:)`) — unless the last read found
///    it already (`VersionIndex`): a commit's manifest is what it is for
///    good; a commit where the folder did not exist is skipped;
/// 3. one line per distinct `version`, taken from the newest commit that has
///    it — that version as it finally was — with its date.
///
/// The "newest commit per version" rule is what keeps a half-finished state
/// in a repository that merges with merge commits from being offered as a
/// version. The result is kept while the head commit is unchanged; after the
/// head moves, a read asks for the folder's history and the manifests of the
/// commits it brought.
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

        // What the last read found, held to the blob store: a manifest whose
        // blob is gone, or no longer hashes to its id, is asked for again. And
        // what the catalogue has: a commit whose listing is kept — the head's,
        // most often — names its manifest's blob, which a read of the
        // catalogue has fetched, or refused for its size, already.
        let known = store.versionIndex(id) ?? VersionIndex()
        var index = VersionIndex()
        var manifests: [String: Data] = [:]
        var unknown: [String] = []
        for commit in commits where index.manifests[commit.sha] == nil && !index.absent.contains(commit.sha) {
            let listing = store.listing(commit.sha)
            let listed = listing?.plugins[id]?.file(at: PluginDiscovery.manifestFilename)?.sha
            if known.absent.contains(commit.sha) || (listing != nil && listed == nil) {
                // Not there at that commit: the last read said so, or the
                // listing of it has no manifest for this plugin.
                index.absent.append(commit.sha)
            } else if let blob = known.manifests[commit.sha] ?? listed, let data = store.blob(blob) {
                manifests[commit.sha] = data
            } else if let listed, store.refusedAsTooLarge(listed) != nil {
                index.absent.append(commit.sha)
            } else if !unknown.contains(commit.sha) {
                unknown.append(commit.sha)
            }
        }
        let fetched = unknown.isEmpty ? [:] : try await provider.files(
            at: "\(CommitListing.pluginsFolder)/\(id)/\(PluginDiscovery.manifestFilename)", commits: unknown)
        // The folder did not exist at a commit not fetched, or its manifest
        // was larger than a plugin's file may be.
        index.absent += unknown.filter { fetched[$0] == nil }
        manifests.merge(fetched) { kept, _ in kept }
        // Every manifest of this read stored by its own hash — those found in
        // the store too, which a prune since may have taken — so installing
        // this version later finds the manifest its listing names without
        // asking again, and the next read finds it by its commit: in one step
        // with any pruning (`keep`).
        store.keep(index, adding: manifests, for: id)

        var seen = Set<String>()
        var lines: [PluginHistory.Line] = []
        for commit in commits {
            guard let data = manifests[commit.sha] else { continue }
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
    /// `readsCatalogue` is whether the copy's source can be read now
    /// (`SourceAccess.canRead`). **Reinstall** is a download, so otherwise it
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
