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
/// has never been read; a branch of a fork, or a fork's own page, one more
/// first, for the fork's description (`GET /repos/{o}/{r}`), which says
/// whether it is a fork of the official repository at all — and, of its own
/// page, which branch is its default. A listing already in the cache costs
/// nothing, a truncated one a few more. The manifests of the plugins it lists
/// come from the raw host by commit, as the catalogue's do.
///
/// A pull request is read through the official repository, by commit, whoever
/// opened it: its head is there whether it came from a branch of the
/// repository itself or from a fork — even one deleted since — so the copy is
/// recorded as the official repository's, at `pr` and its number, and the
/// fork's name is never something a record depends on. A branch of a fork is
/// another matter: whether GitHub serves a commit of a fork that no pull
/// request names through the official repository was never measured, so it is
/// read from the fork itself — its head, its listing and its files — through
/// a client for the fork on the same host, counted against the same limit
/// (`RepositoryProvider.provider(for:)`), and recorded as the fork's, at
/// `branch` and its name. Only a fork of the official repository is read: a
/// repository of its own, or a fork of anything else, is a source of its own,
/// which comes later, and is refused once its description says so, before
/// anything else is asked of it.
public struct RefResolver: Sendable {
    /// The official repository.
    public let provider: any RepositoryProvider
    public let store: CatalogueStore
    public let limits: RateLimitRecorder
    private let now: @Sendable () -> Date

    public init(provider: any RepositoryProvider, store: CatalogueStore, limits: RateLimitRecorder,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.provider = provider
        self.store = store
        self.limits = limits
        self.now = now
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
        /// The official repository's default branch, as it was known when the
        /// link was read — nil when it was not: whether a pull request merged
        /// was merged into it, where what it merged is in the catalogue, or
        /// into another branch, where nothing is verified (`LinkRefusal.head`).
        public var defaultBranch: String?
        /// The fork the branch is in, `owner/repo` — nil for the official
        /// repository's own branches and pull requests: what a sentence names
        /// after the branch (`PluginOrigin.fork`).
        public var fork: String?
        /// When GitHub answered where the head is: what a read of the
        /// catalogue that heard of the same line later knows better
        /// (`FollowedRefs.keep`). The moment the resolution was made, for one
        /// made without it.
        public var heardAt: Date

        public init(origin: PluginOrigin, commit: String, listing: CommitListing, entries: [CatalogueEntry],
                    pullRequest: PullRequest?, plugin: String? = nil, defaultBranch: String? = nil,
                    fork: String? = nil, heardAt: Date = Date()) {
            self.origin = origin
            self.commit = commit
            self.listing = listing
            self.entries = entries
            self.pullRequest = pullRequest
            self.plugin = plugin
            self.defaultBranch = defaultBranch
            self.fork = fork
            self.heardAt = InstalledPlugins.wholeSeconds(heardAt)
        }

        /// Where a branch's head was heard to be — the commit a copy installed
        /// from it is at, and what is known of that branch from then on
        /// (`FollowedRefs.keep`); nil for a pull request, whose answer says it.
        public var branchHead: String? {
            origin.ref.kind == PluginRef.branchKind ? commit : nil
        }
    }

    /// Why a link that was read names nothing to install.
    public enum Refusal: Error, Equatable, Sendable {
        /// The branch, or the pull request, is not there — or the branch was
        /// deleted; of a fork's own page (`RepositoryLink.forkRepository`),
        /// the repository itself is not there, or it is private, which GitHub
        /// answers the same way.
        case notFound(RepositoryLink)
        /// Another repository that is not a fork of the official one — a
        /// repository of its own, or a fork of something else: a source of its
        /// own, which comes later.
        case notAFork(RepositoryAddress)
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
        let heardAt: Date
        // Where the line's files are read: the official repository, or the fork.
        var line = provider
        var pullRequest: PullRequest?
        var plugin: String?
        var known = defaultBranch
        switch link {
        case .officialRepository:
            return .catalogue(plugin: nil)
        case .forkBranch(let address, let name, let named):
            let fork = try await self.fork(address)
            line = fork.provider
            plugin = named
            commit = try await self.head(of: name, in: fork.provider,
                                         refused: .forkBranch(fork.provider.address, branch: name, plugin: named))
            heardAt = now()
            origin = PluginOrigin(repository: fork.provider.address, ref: .branch(name))
        case .forkRepository(let address):
            let fork = try await self.fork(address)
            line = fork.provider
            let name = fork.description.defaultBranch
            commit = try await self.head(of: name, in: fork.provider,
                                         refused: .forkBranch(fork.provider.address, branch: name, plugin: nil))
            heardAt = now()
            origin = PluginOrigin(repository: fork.provider.address, ref: .branch(name))
        case .pullRequest(let number):
            do {
                pullRequest = try await provider.pull(number)
            } catch ProviderError.notFound {
                throw Refusal.notFound(link)
            }
            heardAt = now()
            origin = PluginOrigin(repository: provider.address, ref: .pullRequest(number))
            commit = pullRequest?.head ?? ""
        case .branch(let name, let named):
            if known == nil { known = try await provider.defaultBranch() }
            // The catalogue's: named only when the catalogue's head has it,
            // so that nothing says a plugin is in the catalogue below when it
            // is not.
            if name == known { return .catalogue(plugin: named.flatMap { head?.plugins[$0] == nil ? nil : $0 }) }
            plugin = named
            commit = try await self.head(of: name, in: provider, refused: link)
            heardAt = now()
            origin = PluginOrigin(repository: provider.address, ref: .branch(name))
        }

        let refresher = CatalogueRefresher(provider: line, store: store, limits: limits)
        let listing = try await refresher.listing(commit)
        let ids = Self.differing(listing, from: head, only: plugin)
        try await refresher.fetchManifests(of: listing, folders: ids, language: language)
        let entries = ids.compactMap { id in
            listing.plugins[id].map { Catalogue.entry(id, $0, store: store, udeck: udeck, language: language) }
        }
        return .resolved(Resolution(origin: origin, commit: commit, listing: listing, entries: entries,
                                    pullRequest: pullRequest, plugin: plugin, defaultBranch: known,
                                    fork: origin.fork(official: provider.address), heardAt: heardAt))
    }

    /// The fork at `address`, asked of GitHub — one request, its description
    /// — and its client, named as GitHub names it now: a fork of the official
    /// repository, or `Refusal.notAFork`; not there at all, `notFound`.
    private func fork(_ address: RepositoryAddress) async throws
        -> (provider: any RepositoryProvider, description: RepositoryDescription) {
        guard let asked = provider.provider(for: address) else { throw Refusal.notAFork(address) }
        let description: RepositoryDescription
        do {
            description = try await asked.describe()
        } catch ProviderError.notFound {
            throw Refusal.notFound(.forkRepository(address))
        }
        guard description.isFork(of: provider.address) else { throw Refusal.notAFork(address) }
        // Renamed, or spelt in another case: GitHub's own name from now on —
        // the one the record keeps and every request after this one asks.
        if let name = description.fullName, name != address.path,
           let renamed = provider.provider(for: RepositoryAddress(provider: address.provider, host: address.host, path: name)) {
            return (renamed, description)
        }
        return (asked, description)
    }

    /// The commit branch `name` of `repository` is at, asked by `refs/heads/`
    /// — a branch that is not there is `Refusal.notFound(refused)`.
    private func head(of name: String, in repository: any RepositoryProvider, refused: RepositoryLink) async throws -> String {
        let answer: HeadAnswer
        do {
            answer = try await repository.head(of: "refs/heads/\(name)", ifNoneMatch: nil)
        } catch ProviderError.notFound {
            throw Refusal.notFound(refused)
        }
        guard case .commit(let sha, _) = answer else {
            throw ProviderError.badAnswer("the head of \(name) was answered as unchanged, and nothing was asked about it before")
        }
        return sha
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
