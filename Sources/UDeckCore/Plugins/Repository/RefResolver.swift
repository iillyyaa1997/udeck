import Foundation

/// A link read (`RepositoryLink`), asked of GitHub: which repository and line
/// of history it names, the commit there now, its listing, and the plugins at
/// that commit that are not what the official catalogue has at its head —
/// new there, or changed — which is what **Install from a link…** lists.
///
/// What it costs, in requests to the API: a pull request, one for the pull
/// request — its head, its state and whether it was merged come together —
/// and one for the listing of its head; a branch, one for its head and one
/// for the listing, and one more for the default branch when the catalogue
/// has never been read. A listing already in the cache costs nothing, a
/// truncated one a few more. The manifests of the plugins it lists come from
/// the raw host by commit, as the catalogue's do.
///
/// A pull request is read through the official repository, by commit, whoever
/// opened it: its head is there whether it came from a branch of the
/// repository itself or from a fork — even one deleted since — so the copy is
/// recorded as the official repository's, at `pr` and its number, and the
/// fork's name is never something a record depends on.
public struct RefResolver: Sendable {
    /// The official repository.
    public let provider: any RepositoryProvider
    public let store: CatalogueStore
    public let limits: RateLimitRecorder

    public init(provider: any RepositoryProvider, store: CatalogueStore, limits: RateLimitRecorder) {
        self.provider = provider
        self.store = store
        self.limits = limits
    }

    /// What a link comes to.
    public enum Outcome: Equatable, Sendable {
        /// The official repository, or its default branch: its catalogue, as
        /// Settings lists it — and the plugin the link went into, if the
        /// catalogue's head has it.
        case catalogue(plugin: String?)
        /// A branch or a pull request.
        case resolved(Resolution)
    }

    /// A branch or a pull request, as it is now.
    public struct Resolution: Equatable, Sendable {
        /// Where a copy installed from it comes from: the repository, and
        /// `branch` or `pr` with its name.
        public var origin: PluginOrigin
        /// The commit its head is at.
        public var commit: String
        public var listing: CommitListing
        /// The plugin folders there that differ from the official catalogue's
        /// head, new or changed, as catalogue rows — by id; only the one the
        /// link went into, when it went into one.
        public var entries: [CatalogueEntry]
        /// The pull request, for a pull request: its state, whether it was
        /// merged, where it came from, its title.
        public var pullRequest: PullRequest?
        /// The plugin whose folder the link went into, if it went into one:
        /// what an empty list is said of (`LinkRefusal.head`).
        public var plugin: String?

        public init(origin: PluginOrigin, commit: String, listing: CommitListing, entries: [CatalogueEntry],
                    pullRequest: PullRequest?, plugin: String? = nil) {
            self.origin = origin
            self.commit = commit
            self.listing = listing
            self.entries = entries
            self.pullRequest = pullRequest
            self.plugin = plugin
        }
    }

    /// Why a link that was read names nothing to install.
    public enum Refusal: Error, Equatable, Sendable {
        /// The branch, or the pull request, is not there — or the branch was
        /// deleted.
        case notFound(RepositoryLink)
        /// A branch of another repository, or its own page: installing from
        /// forks comes later in this stage.
        case forkNotYet(RepositoryAddress)
    }

    /// What `link` names now. `defaultBranch` is the official repository's,
    /// as the catalogue knows it — asked of GitHub when it does not — and
    /// `head` the listing of the catalogue's head, which every plugin found
    /// is compared with (nil when there is none: then every plugin there is
    /// new). Throws a `Refusal`, or what the provider throws.
    public func resolve(_ link: RepositoryLink, defaultBranch: String?, head: CommitListing?,
                        udeck: SemanticVersion?, language: String) async throws -> Outcome {
        let origin: PluginOrigin
        let commit: String
        var pullRequest: PullRequest?
        var plugin: String?
        switch link {
        case .officialRepository:
            return .catalogue(plugin: nil)
        case .forkBranch(let address, _, _), .forkRepository(let address):
            throw Refusal.forkNotYet(address)
        case .pullRequest(let number):
            do {
                pullRequest = try await provider.pull(number)
            } catch ProviderError.notFound {
                throw Refusal.notFound(link)
            }
            origin = PluginOrigin(repository: provider.address, ref: .pullRequest(number))
            commit = pullRequest?.head ?? ""
        case .branch(let name, let named):
            let known: String?
            if let defaultBranch { known = defaultBranch } else { known = try await provider.defaultBranch() }
            // The catalogue's: named only when the catalogue's head has it,
            // so that nothing says a plugin is in the catalogue below when it
            // is not.
            if name == known { return .catalogue(plugin: named.flatMap { head?.plugins[$0] == nil ? nil : $0 }) }
            plugin = named
            let answer: HeadAnswer
            do {
                answer = try await provider.head(of: "refs/heads/\(name)", ifNoneMatch: nil)
            } catch ProviderError.notFound {
                throw Refusal.notFound(link)
            }
            guard case .commit(let sha, _) = answer else {
                throw ProviderError.badAnswer("the head of \(name) was answered as unchanged, and nothing was asked about it before")
            }
            origin = PluginOrigin(repository: provider.address, ref: .branch(name))
            commit = sha
        }

        let refresher = CatalogueRefresher(provider: provider, store: store, limits: limits)
        let listing = try await refresher.listing(commit)
        let ids = Self.differing(listing, from: head, only: plugin)
        try await refresher.fetchManifests(of: listing, folders: ids, language: language)
        let entries = ids.compactMap { id in
            listing.plugins[id].map { Catalogue.entry(id, $0, store: store, udeck: udeck, language: language) }
        }
        return .resolved(Resolution(origin: origin, commit: commit, listing: listing, entries: entries,
                                    pullRequest: pullRequest, plugin: plugin))
    }

    /// The plugin folders of `listing` whose tree is not the one `head` has
    /// for the same id — every one, when there is no head — sorted; only
    /// `plugin`, when the link named one.
    public static func differing(_ listing: CommitListing, from head: CommitListing?, only plugin: String?) -> [String] {
        listing.pluginFolders.filter { id in
            guard plugin == nil || plugin == id, let folder = listing.plugins[id] else { return false }
            return head?.plugins[id]?.tree != folder.tree
        }
    }
}
