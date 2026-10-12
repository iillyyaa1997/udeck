import Foundation

/// What uDeck last heard of the pull request a copy came from: its head,
/// whether it was merged or closed, the branch it was opened against, and —
/// once it was merged into the default branch — the tree the copy's folder
/// has at the commit it was merged as. Asked at the catalogue's
/// own moments (`PullRequestFollower`), kept in
/// `~/.udeck/catalogue/official/followed.json` by plugin id, since there is one
/// copy per id; never in `installed.json`, which says where a copy came from and
/// not what became of it.
public struct FollowedPull: Codable, Equatable, Sendable {
    public var number: Int
    /// The commit its head was at.
    public var head: String
    public var state: PullRequest.State
    public var merged: Bool
    /// The branch it was opened against — and merged into, when it was
    /// merged; nil when GitHub did not say.
    public var base: String?
    /// The commit it was merged as — only when it was merged into the default
    /// branch: a merge into any other branch verifies nothing, and what it
    /// was merged as there is not read.
    public var mergeCommit: String?
    /// The tree of `plugins/<id>` at `mergeCommit`, read from that commit's
    /// listing; empty when the folder is not there. Nil when there is no merge
    /// commit to read. A merged pull request is never kept without it when it
    /// has a merge commit: what it was merged as decides whether the copy is
    /// what was merged (`Adoption`) or differs from it
    /// (`PullRequestLifecycle.mergedDiffers`).
    public var mergeTree: String?
    public var checkedAt: Date

    public init(number: Int, head: String, state: PullRequest.State, merged: Bool, base: String?, mergeCommit: String?,
                mergeTree: String?, checkedAt: Date) {
        self.number = number
        self.head = head
        self.state = state
        self.merged = merged
        self.base = base
        self.mergeCommit = mergeCommit
        self.mergeTree = mergeTree
        self.checkedAt = InstalledPlugins.wholeSeconds(checkedAt)
    }

    /// Whether it was merged into `defaultBranch`, the official source's
    /// default branch — the only merge that is what was verified. Not when
    /// either branch is not known.
    public func mergedInto(_ defaultBranch: String?) -> Bool {
        merged && base != nil && base == defaultBranch
    }

    /// What GitHub said of `pull`, for the copy of `id`, `defaultBranch` being
    /// the official source's: once it was merged into it, with the listing of
    /// the commit it was merged as (`mergeListing`) or what was read of that
    /// commit before (`knownBefore`) — nil when neither says anything of it:
    /// then what it was merged as is not known, and nothing is said of it yet.
    /// Merged into another branch, nothing of the commit is kept.
    public static func of(_ pull: PullRequest, id: String, defaultBranch: String?, mergeListing: CommitListing?,
                          knownBefore: FollowedPull? = nil, now: Date) -> FollowedPull? {
        let intoTheDefault = pull.merged && pull.base != nil && pull.base == defaultBranch
        var mergeTree: String?
        if intoTheDefault, let mergeCommit = pull.mergeCommit {
            if let mergeListing, mergeListing.commit == mergeCommit {
                mergeTree = mergeListing.plugins[id]?.tree ?? ""
            } else if let knownBefore, knownBefore.number == pull.number, knownBefore.mergeCommit == mergeCommit,
                      let known = knownBefore.mergeTree {
                mergeTree = known
            } else {
                return nil
            }
        }
        return FollowedPull(number: pull.number, head: pull.head, state: pull.state, merged: pull.merged, base: pull.base,
                            mergeCommit: intoTheDefault ? pull.mergeCommit : nil, mergeTree: mergeTree, checkedAt: now)
    }
}

/// `~/.udeck/catalogue/official/followed.json`: what uDeck last heard of the
/// pull request each copy installed from one came from, by plugin id. A file
/// that will not parse is started over, as the catalogue's state is: nothing
/// in it is the operator's, and all of it can be asked again.
public struct FollowedRefs: Codable, Equatable, Sendable {
    public var version: Int
    public var pulls: [String: FollowedPull]

    public init(version: Int = 1, pulls: [String: FollowedPull] = [:]) {
        self.version = version
        self.pulls = pulls
    }

    /// What is known of the pull request `record`'s copy of `id` came from —
    /// nil for a copy of anything else, and for what was heard of another pull
    /// request at the same id.
    public func pull(of id: String, record: InstalledRecord?) -> FollowedPull? {
        guard let record, !record.isOfficialDefault, let number = record.ref.pullRequestNumber,
              let followed = pulls[id], followed.number == number else { return nil }
        return followed
    }

    /// What **Look up** heard of the pull request `record`'s copy of `id` was
    /// just installed from — `pull`, nil when it was not looked up — kept as
    /// what is known of it, so that its row says at once what became of it
    /// (`PullRequestLifecycle`): open, closed, or merged — into
    /// `defaultBranch`, with what it was merged as when `mergeListing`, the
    /// cached listing of that commit, says it; when it does not, what was
    /// known stays, and the next read of the catalogue asks. What was heard of
    /// a pull request goes once the copy is anything else's: the default
    /// branch's, a branch's.
    public mutating func keep(_ pull: PullRequest?, heardAtInstall record: InstalledRecord, of id: String,
                              defaultBranch: String?, mergeListing: CommitListing?, now: Date) {
        guard !record.isOfficialDefault, let number = record.ref.pullRequestNumber else {
            pulls[id] = nil
            return
        }
        guard let pull, pull.number == number,
              let heard = FollowedPull.of(pull, id: id, defaultBranch: defaultBranch, mergeListing: mergeListing,
                                          knownBefore: pulls[id], now: now) else { return }
        pulls[id] = heard
    }
}

/// What has become of the pull request a copy of code nobody verified came
/// from, as its rows say it. Merged as exactly what the copy is, the copy is
/// **Verified** (`Adoption`) and none of this is said.
public enum PullRequestLifecycle: Equatable, Sendable {
    /// Open, as far as uDeck knows — or merged into another branch than the
    /// default one, which verifies nothing: the copy is **Unverified**,
    /// nothing more.
    case open
    /// Merged into the default branch, as something else than the copy on
    /// disk — at the head and at the commit it was merged as: *the verified
    /// version differs — update*, offered and never made by itself, since the
    /// copy on disk is still code nobody verified, and what comes is not what
    /// was allowed.
    case mergedDiffers
    /// Merged into the default branch, with no verified version to offer
    /// here — the catalogue does not have the plugin, cannot install it here,
    /// or is switched off: said, with nothing to press for it, and the plugin
    /// keeps running.
    case mergedNothingOffered
    /// Closed without being merged: said on the row as a warning; the plugin
    /// keeps running, and **Switch to verified** and **Remove** are there.
    /// Opened again, it is `open` again.
    case closed

    /// What became of the pull request `record`'s copy came from, as
    /// `followed` last heard it, `defaultBranch` being the official source's
    /// and `verifiedOffered` whether the catalogue's verified copy can be put
    /// in its place here (`CatalogueRowState.unverified`, the catalogue
    /// switched on) — nil for a copy of anything else, or when nothing was
    /// heard yet.
    public static func of(_ record: InstalledRecord?, followed: FollowedPull?, defaultBranch: String?,
                          verifiedOffered: Bool) -> PullRequestLifecycle? {
        guard let record, !record.isOfficialDefault, let number = record.ref.pullRequestNumber,
              let followed, followed.number == number else { return nil }
        if followed.mergedInto(defaultBranch) { return verifiedOffered ? .mergedDiffers : .mergedNothingOffered }
        if followed.merged { return .open }
        return followed.state == .closed ? .closed : .open
    }

    /// What the plugin's own row says of it, under its mark: nothing for an
    /// open one.
    public func rowPhrase(number: Int) -> Phrase? {
        switch self {
        case .open: nil
        case .mergedDiffers: .pluginPullRequestMergedDiffers(number: number)
        case .mergedNothingOffered: .pluginPullRequestMergedNothingOffered(number: number)
        case .closed: .pluginPullRequestClosed(number: number)
        }
    }

    /// What the catalogue row of the same id says of it, after *Installed here
    /// from pull request #3: unverified*.
    public var cataloguePhrase: Phrase? {
        switch self {
        case .open: nil
        case .mergedDiffers, .mergedNothingOffered: .catalogueMergedDiffers
        case .closed: .catalogueClosedUnmerged
        }
    }
}

/// Asks after the pull request every copy installed from one came from, at
/// the catalogue's own moments — in the read of the catalogue, after the
/// catalogue itself — and keeps what it heard (`FollowedRefs`).
///
/// What it costs, in requests to the API: one `GET /repos/{o}/{r}/pulls/{n}`
/// for each such copy whose tree the catalogue's head does not already have
/// (a copy whose tree is at the head is what was merged, and becomes
/// **Verified** without a question: `Adoption`), and, once it was merged into
/// the default branch, one for the listing of the commit it was merged as —
/// once per commit, cached. A merge into any other branch verifies nothing,
/// and its commit is not listed.
/// A read nobody asked for asks nothing while the reserve for the operator is
/// all that is left (`RateLimitState.reserveForTheOperator`), and keeps what it
/// heard last; a limit reached stops it there.
public struct PullRequestFollower: Sendable {
    /// The official repository, through which every pull request is read.
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

    /// What one asking came to.
    public struct Outcome: Equatable, Sendable {
        /// What is known now, as it was saved.
        public var followed: FollowedRefs
        /// The plugins whose pull request was asked about.
        public var asked: [String]
        /// The plugins whose pull request was not asked about — the reserve,
        /// a limit, a request that failed — and what was heard before stands.
        public var leftAsTheyWere: [String]

        /// What is known once this asking is over, `current` being what is
        /// known now and `installed` the records now: its word for every id
        /// whose copy is the one it asked about (`askedAbout`), and what is
        /// known now of an id whose copy was installed, adopted or removed
        /// while it asked — which said its own: a copy installed meanwhile
        /// keeps what **Look up** heard, one adopted or removed is forgotten.
        public func merged(into current: FollowedRefs, askedAbout snapshot: InstalledPlugins,
                           installed: InstalledPlugins) -> FollowedRefs {
            var result = current
            let ids = Set(current.pulls.keys).union(followed.pulls.keys).union(snapshot.plugins.keys)
            for id in ids where Self.sameCopy(snapshot.plugins[id], installed.plugins[id]) {
                result.pulls[id] = followed.pulls[id]
            }
            return result
        }

        /// The same copy from the same place: what the asking was about.
        static func sameCopy(_ one: InstalledRecord?, _ other: InstalledRecord?) -> Bool {
            switch (one, other) {
            case (nil, nil): true
            case let (one?, other?):
                one.source == other.source && one.repository == other.repository && one.ref == other.ref
                    && one.commit == other.commit && one.tree == other.tree
            default: false
            }
        }
    }

    /// Asks after the pull request of every copy in `installed` that came from
    /// one of the official repository's, `headTrees` being the trees the
    /// catalogue's head has by plugin id, and `unrequested` whether nobody
    /// asked for this read. What is kept of any other id is dropped.
    public func follow(_ installed: InstalledPlugins, headTrees: [String: String], unrequested: Bool) async -> Outcome {
        let before = store.followed()
        // The default branch, as the read of the catalogue just before this
        // asking found it.
        let defaultBranch = store.state().defaultBranch
        var kept = FollowedRefs()
        var asked: [String] = []
        var left: [String] = []
        var stopped = false
        for id in installed.plugins.keys.sorted() {
            guard let record = installed.plugins[id], !record.isOfficialDefault,
                  record.source == InstalledPlugins.officialSource, record.repository == provider.address,
                  let number = record.ref.pullRequestNumber else { continue }
            let old = before.pulls[id].flatMap { $0.number == number ? $0 : nil }
            if headTrees[id] == record.tree {
                // What was merged: nothing to ask (`Adoption`).
                if let old { kept.pulls[id] = old }
                continue
            }
            if stopped || (unrequested && !limits.current.allowsUnrequested(now: now())) {
                if let old { kept.pulls[id] = old }
                left.append(id)
                continue
            }
            do {
                let pull = try await provider.pull(number)
                var mergeListing: CommitListing?
                if pull.merged, pull.base != nil, pull.base == defaultBranch, let mergeCommit = pull.mergeCommit,
                   old?.mergeCommit != mergeCommit || old?.mergeTree == nil {
                    // Once per commit it was merged as: what was read of it is
                    // kept with the rest, and its listing is not.
                    mergeListing = try await CatalogueRefresher(provider: provider, store: store, limits: limits)
                        .listing(mergeCommit)
                }
                asked.append(id)
                if let heard = FollowedPull.of(pull, id: id, defaultBranch: defaultBranch, mergeListing: mergeListing,
                                               knownBefore: old, now: now()) {
                    kept.pulls[id] = heard
                } else if let old {
                    kept.pulls[id] = old
                }
            } catch {
                if case ProviderError.rateLimited = error { stopped = true }
                if let old { kept.pulls[id] = old }
                left.append(id)
            }
        }
        if kept != before { try? store.save(followed: kept) }
        return Outcome(followed: kept, asked: asked, leftAsTheyWere: left)
    }
}
