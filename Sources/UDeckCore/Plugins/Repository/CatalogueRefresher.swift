import Foundation

/// Reads a repository's catalogue without downloading any plugin.
///
/// One refresh is at most these requests, in this order, and usually only the
/// first two:
///
/// 1. the default branch — at most once a day, and again at once if step 2
///    answers 404, because the branch was renamed;
/// 2. the commit it points at now, asked with the last `ETag`: a `304` ends
///    the refresh there;
/// 3. every path at that commit, once per commit and cached for good — or,
///    for a repository too large to list in one answer, the root, the
///    `plugins` folder, and each plugin folder;
/// 4. the passport, from the raw file host;
/// 5. the manifests of plugins whose folder has not been seen before, and a
///    translation into the panel's language where the listing shows one.
///
/// Every file is fetched by commit, never by branch, and checked against the
/// blob id the listing gave for it before it is used, so a cache or a proxy in
/// between cannot change what uDeck reads without being noticed.
public struct CatalogueRefresher: Sendable {
    public let provider: any RepositoryProvider
    public let store: CatalogueStore
    public let limits: RateLimitRecorder
    private let now: @Sendable () -> Date

    /// How long a default branch is believed before it is asked again.
    public static let defaultBranchLife: TimeInterval = 24 * 3600

    public init(
        provider: any RepositoryProvider,
        store: CatalogueStore,
        limits: RateLimitRecorder,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.provider = provider
        self.store = store
        self.limits = limits
        self.now = now
    }

    /// What one refresh came to.
    public enum Outcome: Equatable, Sendable {
        /// The head was read, and the catalogue is at it.
        case refreshed(head: String, changed: Bool)
        /// A refresh nobody asked for, left for later: the limit's reserve is
        /// all that is left before the reset, or the host is blocked.
        case leftForLater
        /// It did not finish; the catalogue on disk is as it was, and says why.
        case failed(CatalogueError)
    }

    /// Refreshes the catalogue and returns what happened. The state on disk is
    /// saved either way — the limit, the attempt, the error.
    ///
    /// `unrequested` is a refresh the operator did not ask for — at launch, once
    /// a day, a retry — and it does not start while fewer than
    /// `RateLimitState.reserveForTheOperator` requests are left before the reset.
    public func refresh(unrequested: Bool, language: String, installedCommits: Set<String> = []) async -> Outcome {
        var state = store.state()
        if unrequested && !limits.current.allowsUnrequested(now: now()) {
            return .leftForLater
        }
        state.lastAttempt = now()
        let outcome: Outcome
        do {
            let (head, changed) = try await read(&state, language: language)
            state.lastSuccess = now()
            state.lastError = nil
            state.failuresInARow = 0
            outcome = .refreshed(head: head, changed: changed)
        } catch {
            let reason = Self.reason(error, branch: state.defaultBranch)
            state.lastError = reason
            state.failuresInARow += 1
            outcome = .failed(reason)
        }
        state.rateLimit = limits.current
        try? store.save(state)
        store.prune(head: state.head, installedCommits: installedCommits)
        return outcome
    }

    private func read(_ state: inout CatalogueState, language: String) async throws -> (String, Bool) {
        var branch = try await defaultBranch(&state, force: false)
        let known = state.head.flatMap(store.listing) != nil
        let etag = known ? (state.etag ?? state.head.map { "\"\($0)\"" }) : nil

        let answer: HeadAnswer
        do {
            answer = try await provider.head(of: branch, ifNoneMatch: etag)
        } catch ProviderError.notFound {
            // The branch was renamed: ask which one is the default now, once.
            branch = try await defaultBranch(&state, force: true)
            answer = try await provider.head(of: branch, ifNoneMatch: etag)
        }

        switch answer {
        case .unchanged:
            guard let head = state.head else { throw ProviderError.badAnswer("nothing was read before, and the host says nothing changed") }
            try await fetchMissingBlobs(head, language: language)
            return (head, false)
        case .commit(let commit, let newTag):
            let listing = try await listing(commit)
            try passport(of: listing, branch: branch, fetched: try await fetchPassport(listing))
            try await fetchMissingBlobs(listing, language: language)
            let changed = commit != state.head
            state.head = commit
            state.etag = newTag
            return (commit, changed)
        }
    }

    private func defaultBranch(_ state: inout CatalogueState, force: Bool) async throws -> String {
        if !force, let branch = state.defaultBranch, let readAt = state.defaultBranchReadAt,
           now().timeIntervalSince(readAt) < Self.defaultBranchLife, readAt <= now() {
            return branch
        }
        let branch = try await provider.defaultBranch()
        state.defaultBranch = branch
        state.defaultBranchReadAt = now()
        return branch
    }

    /// The listing of a commit: from the cache, or listed once and kept.
    public func listing(_ commit: String) async throws -> CommitListing {
        if let cached = store.listing(commit) { return cached }
        let whole = try await provider.tree(commit, recursive: true)
        let listing: CommitListing
        if whole.truncated {
            let root = try await provider.tree(commit, recursive: false)
            let pluginsTree = root.tree.first { $0.path == CommitListing.pluginsFolder && $0.type == "tree" }
            var plugins: GitTree?
            if let pluginsTree { plugins = try await provider.tree(pluginsTree.sha, recursive: false) }
            var folders: [String: GitTree] = [:]
            for entry in plugins?.tree ?? [] where entry.type == "tree" {
                folders[entry.path] = try await provider.tree(entry.sha, recursive: true)
            }
            listing = CommitListing(commit: commit, root: root, pluginsFolder: plugins, folders: folders)
        } else {
            listing = CommitListing(commit: commit, recursive: whole)
        }
        try store.save(listing)
        return listing
    }

    private func fetchPassport(_ listing: CommitListing) async throws -> Data? {
        guard let sha = listing.passport else { return nil }
        return try await blob(sha, path: RepositoryPassport.path, commit: listing.commit)
    }

    private func passport(of listing: CommitListing, branch: String, fetched: Data?) throws {
        switch RepositoryPassport.read(fetched) {
        case .success: return
        case .failure(.missing): throw CatalogueError.notARepository(branch: branch)
        case .failure(.futureFormat(let declared)): throw CatalogueError.futureFormat(declared: declared)
        case .failure(.invalid(let reason)): throw CatalogueError.invalidPassport(reason)
        }
    }

    private func fetchMissingBlobs(_ commit: String, language: String) async throws {
        guard let listing = store.listing(commit) else { return }
        try await fetchMissingBlobs(listing, language: language)
    }

    /// Each plugin's manifest, and its translation into `language` when the
    /// listing shows one — never guessed at — unless the blob is already
    /// stored. A folder with the same tree as before has, byte for byte, the
    /// same manifest, so a refresh after one merge fetches one manifest.
    private func fetchMissingBlobs(_ listing: CommitListing, language: String) async throws {
        for folder in listing.pluginFolders {
            guard let plugin = listing.plugins[folder] else { continue }
            for name in [PluginDiscovery.manifestFilename, "manifest.\(language.lowercased()).json"] {
                guard let file = plugin.file(at: name), store.blob(file.sha) == nil else { continue }
                _ = try await blob(file.sha, path: "\(CommitListing.pluginsFolder)/\(folder)/\(name)",
                                   commit: listing.commit)
            }
        }
    }

    /// A file by commit, checked against its blob id and stored under it.
    private func blob(_ sha: String, path: String, commit: String) async throws -> Data {
        if let stored = store.blob(sha) { return stored }
        let data = try await provider.file(at: path, commit: commit)
        let got = GitHash.blob(data)
        guard got == sha else {
            throw CatalogueError.arrivedDifferent(path: path, expected: String(sha.prefix(7)), got: String(got.prefix(7)))
        }
        try store.save(blob: data)
        return data
    }

    static func reason(_ error: any Error, branch: String?) -> CatalogueError {
        switch error {
        case let error as CatalogueError: return error
        case let error as ProviderError:
            switch error {
            case .rateLimited(let until): return .rateLimited(until: until)
            case .rawRateLimited(let until): return .rawRateLimited(until: until)
            case .notFound: return .notFound
            case .refused(let status): return .refused(status: status)
            case .unreachable(let reason): return .unreachable(reason)
            case .badAnswer(let reason): return .badAnswer(reason)
            }
        default: return .badAnswer("\(error)")
        }
    }
}

extension CatalogueError: Error {}

/// When a refresh is due. Pure, so it is tested; the application only asks.
///
/// * At launch, a few seconds after the panel is ready — unless the catalogue
///   was read successfully in the last 24 hours.
/// * While uDeck runs, once every 24 hours.
/// * When Settings → Plugins opens, if the catalogue is more than an hour old.
/// * Whenever **Check now** is pressed.
///
/// A failed refresh is tried again after an hour, then daily as usual. None of
/// this applies while the official catalogue is switched off.
public enum CatalogueSchedule {
    public static let daily: TimeInterval = 24 * 3600
    public static let settingsFreshness: TimeInterval = 3600
    public static let retryAfterFailure: TimeInterval = 3600
    /// How long after the panel is ready the launch refresh waits.
    public static let launchDelay: TimeInterval = 5

    /// Whether the refresh at launch happens at all.
    public static func refreshesAtLaunch(_ state: CatalogueState, now: Date) -> Bool {
        guard let success = state.lastSuccess, success <= now else { return true }
        return now.timeIntervalSince(success) >= daily
    }

    /// Whether opening Settings → Plugins refreshes.
    public static func refreshesWhenSettingsOpen(_ state: CatalogueState, now: Date) -> Bool {
        guard let success = state.lastSuccess, success <= now else { return true }
        return now.timeIntervalSince(success) > settingsFreshness
    }

    /// When the next refresh nobody asked for is due, while uDeck runs.
    ///
    /// The first failure in a row is tried again after an hour; after that,
    /// daily as usual — a machine that is offline for a week asks once a day,
    /// not every hour.
    public static func nextDue(_ state: CatalogueState, now: Date) -> Date {
        let lastSuccess = state.lastSuccess.map { min($0, now) }
        if state.lastError != nil, let attempt = state.lastAttempt.map({ min($0, now) }),
           lastSuccess.map({ attempt > $0 }) ?? true {
            return attempt.addingTimeInterval(state.failuresInARow <= 1 ? retryAfterFailure : daily)
        }
        guard let lastSuccess else { return now }
        return lastSuccess.addingTimeInterval(daily)
    }
}
