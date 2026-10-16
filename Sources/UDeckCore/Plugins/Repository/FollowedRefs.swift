import Foundation

/// What uDeck last heard of the pull request a copy came from: its head,
/// whether it was merged or closed, the branch it was opened against, and —
/// once it was merged into the default branch — the tree the copy's folder
/// has at the commit it was merged as. Asked at the catalogue's
/// own moments (`RefFollower`), kept in
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
    /// Whether its head continues the commit the copy was installed at, once
    /// the head moved off it and the copy's folder there is another
    /// (`HistoryRewrite`) — nil until that was asked, and for a head that is
    /// the commit installed.
    public var history: HeadHistory?

    public init(number: Int, head: String, state: PullRequest.State, merged: Bool, base: String?, mergeCommit: String?,
                mergeTree: String?, checkedAt: Date, history: HeadHistory? = nil) {
        self.number = number
        self.head = head
        self.state = state
        self.merged = merged
        self.base = base
        self.mergeCommit = mergeCommit
        self.mergeTree = mergeTree
        self.checkedAt = InstalledPlugins.wholeSeconds(checkedAt)
        self.history = history
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

/// What uDeck last heard of the branch a copy installed from one came from:
/// where its head is, or that it is not there any more. Kept beside the pull
/// requests (`FollowedRefs`), by plugin id; asked at the catalogue's own moments
/// (`RefFollower`).
public struct FollowedBranch: Codable, Equatable, Sendable {
    /// The branch's name, as the record has it.
    public var name: String
    /// The repository it is in, as the record has it: the official one's, or
    /// a fork's — a fork's branch called `fix` is another branch than the
    /// official repository's `fix`. Absent from what was heard before
    /// branches of forks were followed, when every branch was the official
    /// repository's.
    public var repository: RepositoryAddress?
    /// The commit its head was at — nil: GitHub said the branch is not there,
    /// deleted after its merge or by hand. The copy keeps running, and its row
    /// says so.
    public var head: String?
    /// Whether that head continues the commit the copy was installed at, once
    /// it moved off it (`HeadHistory`).
    public var history: HeadHistory?
    public var checkedAt: Date

    public init(name: String, repository: RepositoryAddress? = nil, head: String?, history: HeadHistory? = nil,
                checkedAt: Date) {
        self.name = name
        self.repository = repository
        self.head = head
        self.history = history
        self.checkedAt = InstalledPlugins.wholeSeconds(checkedAt)
    }
}

/// `~/.udeck/catalogue/official/followed.json`: what uDeck last heard of the
/// branch or the pull request each copy installed from one came from, by
/// plugin id — and which of them the last read that could have asked left
/// unasked. A file that will not parse is started over, as the catalogue's
/// state is: nothing in it is the operator's, and all of it can be asked again.
public struct FollowedRefs: Codable, Equatable, Sendable {
    public var version: Int
    public var pulls: [String: FollowedPull]
    public var branches: [String: FollowedBranch]
    /// The copies whose branch or pull request the last read did not ask
    /// about — a read nobody asked for while the reserve for the operator is
    /// all that is left, a limit reached, a request that failed, a read of
    /// the catalogue that did not get as far as them — with when it
    /// was last asked about (or the copy installed, when it never was): what
    /// was heard before stands, and the row says *not checked since*. Gone
    /// once it is asked about again.
    public var notCheckedSince: [String: Date]

    public init(version: Int = 1, pulls: [String: FollowedPull] = [:], branches: [String: FollowedBranch] = [:],
                notCheckedSince: [String: Date] = [:]) {
        self.version = version
        self.pulls = pulls
        self.branches = branches
        self.notCheckedSince = notCheckedSince
    }

    private enum CodingKeys: String, CodingKey { case version, pulls, branches, notCheckedSince }

    /// A file from before branches were followed — pull requests alone —
    /// reads as it is, with nothing heard of any branch.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        pulls = try c.decodeIfPresent([String: FollowedPull].self, forKey: .pulls) ?? [:]
        branches = try c.decodeIfPresent([String: FollowedBranch].self, forKey: .branches) ?? [:]
        notCheckedSince = try c.decodeIfPresent([String: Date].self, forKey: .notCheckedSince) ?? [:]
    }

    /// What is known of the pull request `record`'s copy of `id` came from —
    /// nil for a copy of anything else, and for what was heard of another pull
    /// request at the same id.
    public func pull(of id: String, record: InstalledRecord?) -> FollowedPull? {
        guard let record, !record.isOfficialDefault, let number = record.ref.pullRequestNumber,
              let followed = pulls[id], followed.number == number else { return nil }
        return followed
    }

    /// What is known of the branch `record`'s copy of `id` came from — nil for
    /// a copy of anything else, and for what was heard of another branch: one
    /// of another name, or of the same name in another repository.
    public func branch(of id: String, record: InstalledRecord?) -> FollowedBranch? {
        guard let record, !record.isOfficialDefault, record.ref.kind == PluginRef.branchKind,
              let followed = branches[id], ShownPlace.same(followed.name, record.ref.name ?? ""),
              followed.repository.map({ $0 == record.repository }) ?? true else { return nil }
        return followed
    }

    /// The head the branch or the pull request `record`'s copy of `id` came
    /// from was last heard at, and what was found of it — nil while nothing
    /// was heard, for a branch that is not there any more, and for a pull
    /// request merged into the default branch (`defaultBranch`), whose head is
    /// no longer what it offers: what was merged is (`PullRequestLifecycle`).
    public func head(of id: String, record: InstalledRecord?, defaultBranch: String?) -> (commit: String, history: HeadHistory?)? {
        if let pull = pull(of: id, record: record) {
            return pull.mergedInto(defaultBranch) ? nil : (pull.head, pull.history)
        }
        if let branch = branch(of: id, record: record), let head = branch.head {
            return (head, branch.history)
        }
        return nil
    }

    /// Every head a branch or a pull request was last heard at: the listings
    /// the catalogue's cache keeps for them (`CatalogueStore.prune`), so that
    /// what a moved head offers is read again without asking.
    public var heads: Set<String> {
        Set(pulls.values.map(\.head)).union(branches.values.compactMap(\.head))
    }

    /// Everything kept of `id`, gone: the copy was removed, adopted, or is
    /// the default branch's now.
    public mutating func forget(_ id: String) {
        pulls[id] = nil
        branches[id] = nil
        notCheckedSince[id] = nil
    }

    /// Whether anything is kept of `id`.
    public func holds(_ id: String) -> Bool {
        pulls[id] != nil || branches[id] != nil || notCheckedSince[id] != nil
    }

    /// What **Look up** heard of the pull request `record`'s copy of `id` was
    /// just installed from — `pull`, nil when it was not looked up — kept as
    /// what is known of it, so that its row says at once what became of it
    /// (`PullRequestLifecycle`): open, closed, or merged — into
    /// `defaultBranch`, with what it was merged as when `mergeListing`, the
    /// cached listing of that commit, says it; when it does not, what was
    /// known stays, and the next read of the catalogue asks. Of a branch,
    /// **Look up** heard its head — `branchHead`, the commit just installed;
    /// nil when it was not looked up. Either is kept as heard when **Look up**
    /// heard it, `heardAt` — `now` when it does not say — and is what is
    /// known of that line from then on unless a read of the catalogue heard
    /// of the same line after it: the sheet can stay open across a read, and
    /// what that read heard — another head, the branch deleted, the pull
    /// request closed — is newer than the head installed from, and stands.
    /// What a read heard before **Look up** — an older head, no branch at
    /// all — goes. Put back or updated along it, what was heard of the line
    /// stands. What was heard of a pull request goes once the copy is anything
    /// else's: the default branch's, a branch's — and what was heard of a
    /// branch, once it is not a branch's. A copy just put in place was just
    /// read: *not checked since* goes with it.
    public mutating func keep(_ pull: PullRequest?, branchHead: String?, heardAt: Date? = nil,
                              heardAtInstall record: InstalledRecord, of id: String, defaultBranch: String?,
                              mergeListing: CommitListing?, now: Date) {
        guard !record.isOfficialDefault else {
            forget(id)
            return
        }
        notCheckedSince[id] = nil
        let heard = InstalledPlugins.wholeSeconds(heardAt ?? now)
        if record.ref.kind != PluginRef.branchKind {
            branches[id] = nil
        } else if let branchHead, let name = record.ref.name,
                  !(branch(of: id, record: record).map { $0.checkedAt > heard } ?? false) {
            branches[id] = FollowedBranch(name: name, repository: record.repository, head: branchHead, checkedAt: heard)
        }
        guard let number = record.ref.pullRequestNumber else {
            pulls[id] = nil
            return
        }
        guard let pull, pull.number == number, !(self.pull(of: id, record: record).map { $0.checkedAt > heard } ?? false),
              let lookedUp = FollowedPull.of(pull, id: id, defaultBranch: defaultBranch, mergeListing: mergeListing,
                                             knownBefore: pulls[id], now: heard) else { return }
        pulls[id] = lookedUp
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

/// Asks after the branch or the pull request every copy installed from one of
/// the official repository's — or from a branch of one of its forks — came
/// from, at the catalogue's own moments — in the read of the catalogue, after
/// the catalogue itself — and keeps what it heard (`FollowedRefs`). A pull
/// request is asked of the official repository, whoever opened it; a branch
/// of the repository it is in: the official one, or the fork, through the same
/// host's client for it, counted against the same limit
/// (`RepositoryProvider.provider(for:)`) — its head, its listing and the
/// comparison all asked of the fork.
///
/// What it costs, in requests to the API, for each such copy whose tree the
/// catalogue's head does not already have (a copy whose tree is at the head
/// is what was merged, and becomes **Verified** without a question:
/// `Adoption`):
///
/// * a pull request: `GET /repos/{o}/{r}/pulls/{n}`, one request, which says
///   its head, its state and its merge together; once it was merged into the
///   default branch, the listing of the commit it was merged as — once per
///   commit. A merge into any other branch verifies nothing, and its commit is
///   not listed;
/// * a branch: its head, `GET /repos/{o}/{r}/commits/refs/heads/{b}` — of the
///   fork, for a fork's branch, and so its listing and its comparison — asked
///   with `If-None-Match` and the commit installed — GitHub's `ETag` for a
///   head is its commit — so a branch that did not move answers `304`, which
///   still costs one; a branch that is not there answers `422` and is said;
/// * and once the head moved off the commit installed — a pull request not
///   merged into the default branch, or a branch — the listing of the new head,
///   once per commit, the copy's manifest there from the raw host unless it is
///   stored, and, when the copy's folder there is another tree, one comparison
///   of the commit installed with the new head (`HistoryRewrite`) — once for
///   that pair, then from what was kept. Never a comparison with the default
///   branch.
///
/// A read nobody asked for asks nothing while the reserve for the operator is
/// all that is left (`RateLimitState.reserveForTheOperator`) — looked at before
/// each copy, and again before a listing or a comparison it needs — and keeps
/// what it heard last, saying since when
/// (`FollowedRefs.notCheckedSince`); a limit reached stops it there, and a
/// request that fails leaves that copy as it was, the same way. A read of the
/// catalogue that did not get as far as this — left for later for the reserve,
/// or failed — asks nothing at all, and leaves every copy the same way
/// (`follow(_:headTrees:unrequested:asking:)`).
public struct RefFollower: Sendable {
    /// The official repository, through which every pull request and every
    /// branch of its own is read — and the same host's client for each fork
    /// (`RepositoryProvider.provider(for:)`).
    public let provider: any RepositoryProvider
    public let store: CatalogueStore
    public let limits: RateLimitRecorder
    /// The panel's language: the translation of a manifest fetched at a moved
    /// head, as the catalogue fetches it.
    public let language: String
    private let now: @Sendable () -> Date

    public init(provider: any RepositoryProvider, store: CatalogueStore, limits: RateLimitRecorder,
                language: String = Language.english.rawValue, now: @escaping @Sendable () -> Date = { Date() }) {
        self.provider = provider
        self.store = store
        self.limits = limits
        self.language = language
        self.now = now
    }

    /// What one asking came to.
    public struct Outcome: Equatable, Sendable {
        /// What is known now, as it was saved.
        public var followed: FollowedRefs
        /// The plugins whose branch or pull request was asked about.
        public var asked: [String]
        /// The plugins whose branch or pull request was not asked about — the
        /// reserve, a limit, a request that failed — and what was heard before
        /// stands.
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
            let ids = Set(current.pulls.keys).union(current.branches.keys).union(current.notCheckedSince.keys)
                .union(followed.pulls.keys).union(followed.branches.keys).union(followed.notCheckedSince.keys)
                .union(snapshot.plugins.keys)
            for id in ids where Self.sameCopy(snapshot.plugins[id], installed.plugins[id]) {
                result.pulls[id] = followed.pulls[id]
                result.branches[id] = followed.branches[id]
                result.notCheckedSince[id] = followed.notCheckedSince[id]
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

    /// Asks after the branch or the pull request of every copy in `installed`
    /// that came from one of the official repository's or a fork's branch,
    /// `headTrees` being the trees the catalogue's head has by plugin id, and
    /// `unrequested` whether nobody asked for this read. `asking` false is a
    /// read of the catalogue
    /// that did not get as far as this — left for later, or failed: nothing
    /// is asked, and every such copy is left as it was, saying since when it
    /// was not checked. What is kept of any other id is dropped.
    public func follow(_ installed: InstalledPlugins, headTrees: [String: String], unrequested: Bool,
                       asking: Bool = true) async -> Outcome {
        let before = store.followed()
        // The default branch, as the read of the catalogue just before this
        // asking found it.
        let defaultBranch = store.state().defaultBranch
        var kept = FollowedRefs()
        var asked: [String] = []
        var left: [String] = []
        var stopped = !asking
        for id in installed.plugins.keys.sorted() {
            guard let record = installed.plugins[id], !record.isOfficialDefault,
                  record.source == InstalledPlugins.officialSource, let line = line(of: record) else { continue }
            let number = record.ref.pullRequestNumber
            let branch = record.ref.kind == PluginRef.branchKind ? record.ref.name.flatMap { $0.isEmpty ? nil : $0 } : nil
            guard number != nil || branch != nil else { continue }
            let oldPull = before.pull(of: id, record: record)
            let oldBranch = before.branch(of: id, record: record)
            if headTrees[id] == record.tree {
                // What was merged: nothing to ask (`Adoption`).
                Self.keep(oldPull, oldBranch, of: id, in: &kept)
                continue
            }
            if stopped || (unrequested && !limits.current.allowsUnrequested(now: now())) {
                Self.leave(id, record: record, oldPull, oldBranch, before: before, in: &kept)
                left.append(id)
                continue
            }
            do {
                if let number {
                    if let heard = try await askAbout(pull: number, of: id, record: record, before: oldPull,
                                                      defaultBranch: defaultBranch, unrequested: unrequested) {
                        kept.pulls[id] = heard
                    } else if let oldPull {
                        kept.pulls[id] = oldPull
                    }
                } else if let branch {
                    kept.branches[id] = try await askAbout(branch: branch, in: line, of: id, record: record,
                                                           before: oldBranch, unrequested: unrequested)
                }
                asked.append(id)
            } catch {
                // The reserve reached (`LeftForTheReserve`) stops the rest by
                // the question above; a limit, here.
                if case ProviderError.rateLimited = error { stopped = true }
                Self.leave(id, record: record, oldPull, oldBranch, before: before, in: &kept)
                left.append(id)
            }
        }
        if kept != before { try? store.save(followed: kept) }
        return Outcome(followed: kept, asked: asked, leftAsTheyWere: left)
    }

    /// A read nobody asked for, come to the reserve halfway through a copy:
    /// that copy is left as it was, what it heard on the way not kept.
    private struct LeftForTheReserve: Error {}

    /// Where `record`'s line is asked: a pull request, and a branch of the
    /// official repository, of the official repository; a fork's branch, of
    /// the fork, through the same host's client for it — nil for a pull
    /// request recorded as another repository's, which none is, and for a
    /// repository on another host.
    private func line(of record: InstalledRecord) -> (any RepositoryProvider)? {
        if record.repository == provider.address { return provider }
        guard record.ref.kind == PluginRef.branchKind else { return nil }
        return provider.provider(for: record.repository)
    }

    /// Whether the next request may go: never, in a read nobody asked for,
    /// while the reserve for the operator is all that is left.
    private func mayAsk(unrequested: Bool) throws {
        if unrequested && !limits.current.allowsUnrequested(now: now()) { throw LeftForTheReserve() }
    }

    /// What was heard before of `id`'s line, kept as it was.
    private static func keep(_ pull: FollowedPull?, _ branch: FollowedBranch?, of id: String, in kept: inout FollowedRefs) {
        if let pull { kept.pulls[id] = pull }
        if let branch { kept.branches[id] = branch }
    }

    /// `id`'s line not asked about: what was heard before stands, and since
    /// when it was not checked — when it was last asked about, or the copy
    /// installed when it never was.
    private static func leave(_ id: String, record: InstalledRecord, _ pull: FollowedPull?, _ branch: FollowedBranch?,
                              before: FollowedRefs, in kept: inout FollowedRefs) {
        keep(pull, branch, of: id, in: &kept)
        kept.notCheckedSince[id] = pull?.checkedAt ?? branch?.checkedAt ?? before.notCheckedSince[id] ?? record.installedAt
    }

    /// What GitHub says of pull request `number`, which `record`'s copy of
    /// `id` came from — nil when nothing can be said of it yet (merged, as a
    /// commit whose listing is not to be had).
    private func askAbout(pull number: Int, of id: String, record: InstalledRecord, before old: FollowedPull?,
                          defaultBranch: String?, unrequested: Bool) async throws -> FollowedPull? {
        let pull = try await provider.pull(number)
        var mergeListing: CommitListing?
        if pull.merged, pull.base != nil, pull.base == defaultBranch, let mergeCommit = pull.mergeCommit,
           old?.mergeCommit != mergeCommit || old?.mergeTree == nil {
            // Once per commit it was merged as: what was read of it is kept
            // with the rest, and its listing is not.
            if store.listing(mergeCommit) == nil { try mayAsk(unrequested: unrequested) }
            mergeListing = try await refresher.listing(mergeCommit)
        }
        guard var heard = FollowedPull.of(pull, id: id, defaultBranch: defaultBranch, mergeListing: mergeListing,
                                          knownBefore: old, now: now()) else { return nil }
        // Merged into the default branch, it offers what was merged, not its
        // head (`PullRequestLifecycle`).
        if !heard.mergedInto(defaultBranch) {
            heard.history = try await history(of: id, in: provider, record: record, head: heard.head,
                                              known: old?.history, unrequested: unrequested)
        }
        return heard
    }

    /// What GitHub says of branch `name` of `line` — the official repository,
    /// or the fork it is in — which `record`'s copy of `id` came from: its
    /// head, asked with the commit installed — `304` when it is still there —
    /// or that it is not there any more.
    private func askAbout(branch name: String, in line: any RepositoryProvider, of id: String, record: InstalledRecord,
                          before old: FollowedBranch?, unrequested: Bool) async throws -> FollowedBranch {
        let answer: HeadAnswer
        do {
            answer = try await line.head(of: "refs/heads/\(name)", ifNoneMatch: "\"\(record.commit)\"")
        } catch ProviderError.notFound {
            return FollowedBranch(name: name, repository: record.repository, head: nil, checkedAt: now())
        }
        let head: String
        switch answer {
        case .unchanged: head = record.commit
        case .commit(let commit, _): head = commit
        }
        return FollowedBranch(name: name, repository: record.repository, head: head,
                              history: try await history(of: id, in: line, record: record, head: head,
                                                         known: old?.history, unrequested: unrequested),
                              checkedAt: now())
    }

    /// What was found of `head`, the head `record`'s line moved to: nothing
    /// when it did not move, or when the copy's folder there is the copy's —
    /// nothing is offered, so nothing is compared; otherwise whether it
    /// continues the commit installed (`HistoryRewrite`), from what was found
    /// before (`known`) when that was of the same two commits. The new head's
    /// listing, and the copy's manifest there, are read on the way, for what
    /// the row offers (`RefHead`). In a read nobody asked for, neither the
    /// listing nor the comparison is asked once the reserve is all that is
    /// left (`mayAsk`). All of it is asked of `line`, the repository the line
    /// is in.
    private func history(of id: String, in line: any RepositoryProvider, record: InstalledRecord, head: String,
                         known: HeadHistory?, unrequested: Bool) async throws -> HeadHistory? {
        guard head != record.commit else { return nil }
        let lister = refresher(asking: line)
        if store.listing(head) == nil { try mayAsk(unrequested: unrequested) }
        let listing = try await lister.listing(head)
        let folder = listing.plugins[id]
        if folder != nil {
            try await lister.fetchManifests(of: listing, folders: [id], language: language)
        }
        guard folder?.tree != record.tree else { return nil }
        if let known, known.holds(installed: record.commit, head: head) { return known }
        try mayAsk(unrequested: unrequested)
        let answer: Result<Comparison, ProviderError>
        do {
            answer = .success(try await line.compare(record.commit, head))
        } catch let error as ProviderError {
            answer = .failure(error)
        }
        guard let rewritten = HistoryRewrite.rewritten(answer) else {
            // Nothing known: what was heard before stands, and the next read
            // asks again.
            if case .failure(let error) = answer { throw error }
            return nil
        }
        return HeadHistory(from: record.commit, to: head, rewritten: rewritten, checkedAt: now())
    }

    private var refresher: CatalogueRefresher { refresher(asking: provider) }

    /// What lists a commit and fetches its manifests, asking `line`.
    private func refresher(asking line: any RepositoryProvider) -> CatalogueRefresher {
        CatalogueRefresher(provider: line, store: store, limits: limits, now: now)
    }
}

/// The head the branch or the pull request a copy of code nobody verified came
/// from moved to, as the catalogue's cache holds it: its commit, and the copy's
/// folder there as a catalogue row reads it — the listing, the manifest, every
/// rule checked (`Catalogue.entry`) — nil when the folder is not there. What the
/// plugin's row offers is decided of it (`RefOffer`), and **Update** takes the
/// folder from it.
public struct RefHead: Equatable, Sendable {
    public var commit: String
    public var entry: CatalogueEntry?

    public init(commit: String, entry: CatalogueEntry?) {
        self.commit = commit
        self.entry = entry
    }

    /// Every moved head's, by plugin id, read from what the asking left in the
    /// cache — the listing of the head and the manifest in the blob store —
    /// away from the main thread, as the catalogue itself is read
    /// (`Catalogue.read`): `followed` being what was heard, `installed` the
    /// records and `defaultBranch` the official source's. A head whose listing
    /// is not in the cache is left out: nothing is offered of it until a read
    /// lists it.
    public static func read(from store: CatalogueStore, followed: FollowedRefs, installed: InstalledPlugins,
                            defaultBranch: String?, udeck: SemanticVersion?, language: String) async -> [String: RefHead] {
        var heads: [String: RefHead] = [:]
        for (id, record) in installed.plugins {
            guard let head = followed.head(of: id, record: record, defaultBranch: defaultBranch)?.commit,
                  head != record.commit, let listing = store.listing(head) else { continue }
            heads[id] = RefHead(commit: head, entry: listing.plugins[id].map {
                Catalogue.entry(id, $0, store: store, udeck: udeck, language: language)
            })
        }
        return heads
    }
}
