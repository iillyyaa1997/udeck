import Foundation

/// A copy of code nobody verified becoming **Verified** because what it is was
/// merged: decided here, whole, where it is tested.
///
/// Verified is said of content, not of a ref. A copy installed from a pull
/// request — or a branch — of the official repository whose folder is, byte
/// for byte, what the default branch has for its id now, is what a maintainer
/// merged: squash merges and rebases included, since the tree of a folder is
/// git's hash of exactly its files. So when its folder on disk hashes to the
/// tree it was installed as, and that tree is the one the catalogue's head has
/// for its id, the record alone is rewritten — the official source's default
/// branch, at the head — and the copy stands **Verified**: nothing is
/// downloaded, nothing is swapped, its windows and its cache stay, and its
/// permission decision holds for its version, as any verified copy's does
/// (`ConsentBasis`), so the card does not ask again. From
/// then on the copy follows the default branch, as any verified copy does,
/// and what was heard of its pull request is forgotten.
///
/// A pull request merged into the default branch while that branch has moved
/// past the commit it was merged as has, at the head, another tree; so the
/// commit it was merged as (`FollowedPull.mergeCommit`) is tried too, and a
/// copy that is what was merged there is recorded at that commit — which
/// lies on the default branch — and the update the head has for it follows
/// as for any verified copy, by itself or offered (`AutoUpdate`). A pull
/// request merged into any other branch is not tried: nothing there is
/// verified.
///
/// Never for a copy changed on disk since it was installed, a folder not
/// hashed or gone, a copy of another source, or a tree neither commit has.
public enum Adoption {
    /// What one copy comes to.
    public enum Verdict: Equatable, Sendable {
        /// Recorded as the default branch's copy, at `commit`.
        case adopt(commit: String)
        /// Left as it is, for `reason`.
        case not(Reason)
    }

    public enum Reason: Equatable, Sendable {
        /// The copy is the default branch's already.
        case verifiedAlready
        /// Another source's copy: only the official repository's merges verify.
        case anotherSource
        /// Its folder has not been hashed, would not hash, or is gone.
        case notHashed
        /// Its folder no longer is what was installed: whatever it is now,
        /// nobody merged that.
        case changedOnDisk
        /// Neither the head nor the commit its pull request was merged into
        /// the default branch as has its tree.
        case notMerged
    }

    /// The default branch of the official source, as the catalogue last read
    /// it: where an adopted copy is recorded, and the tree each plugin's
    /// folder has at its head.
    public struct DefaultBranch: Equatable, Sendable {
        /// The official source's own repository.
        public var repository: RepositoryAddress
        /// Its name, `main`, when it is known.
        public var name: String?
        /// The commit at its head.
        public var head: String
        /// The tree of `plugins/<id>` at the head, by id.
        public var trees: [String: String]

        public init(repository: RepositoryAddress, name: String?, head: String, trees: [String: String]) {
            self.repository = repository
            self.name = name
            self.head = head
            self.trees = trees
        }

        /// The catalogue's head.
        public init(_ catalogue: Catalogue) {
            self.init(repository: catalogue.address, name: catalogue.branch, head: catalogue.commit,
                      trees: Dictionary(catalogue.entries.map { ($0.id, $0.listing.tree) }, uniquingKeysWith: { one, _ in one }))
        }
    }

    /// What `record`'s copy of `id` comes to, its folder hashing to
    /// `treeOnDisk` (nil when it was not hashed, would not hash or is gone),
    /// the default branch being `branch`, and `pull` what was last heard of
    /// the pull request it came from.
    public static func verdict(_ id: String, record: InstalledRecord, treeOnDisk: String?, branch: DefaultBranch,
                               pull: FollowedPull?) -> Verdict {
        guard !record.isOfficialDefault else { return .not(.verifiedAlready) }
        guard record.source == InstalledPlugins.officialSource else { return .not(.anotherSource) }
        guard let treeOnDisk else { return .not(.notHashed) }
        guard treeOnDisk == record.tree else { return .not(.changedOnDisk) }
        if branch.trees[id] == record.tree { return .adopt(commit: branch.head) }
        if let pull, pull.number == record.ref.pullRequestNumber, pull.mergedInto(branch.name),
           let mergeCommit = pull.mergeCommit, pull.mergeTree == record.tree {
            return .adopt(commit: mergeCommit)
        }
        return .not(.notMerged)
    }

    /// `record` recorded as the copy of `branch` at `commit`: the official
    /// source's own repository and its default branch, **Verified** as checked
    /// against the head. Its tree, version, `installedAt`, `pinned`,
    /// `previous` and whether it was put there by itself stay what they were:
    /// nothing on disk changed.
    public static func adopted(_ record: InstalledRecord, at commit: String, branch: DefaultBranch,
                               now: Date) -> InstalledRecord {
        var adopted = record
        adopted.source = InstalledPlugins.officialSource
        adopted.repository = branch.repository
        adopted.ref = .defaultBranch(branch.name)
        adopted.commit = commit
        adopted.verification = PluginVerification(status: .verified, by: InstalledPlugins.officialSource,
                                                  checkedAgainst: branch.head, checkedAt: now)
        return adopted
    }

    /// Every copy of `installed` that is what was merged, adopted, with the
    /// commit each was recorded at — `trees` being what each installed folder
    /// hashed to (`Reverification.trees`), and `followed` what was heard of
    /// the pull requests. A plugin missing from `trees` is not hashed.
    public static func apply(_ installed: InstalledPlugins, trees: [String: String?], branch: DefaultBranch,
                             followed: FollowedRefs, now: Date) -> (installed: InstalledPlugins, adopted: [String: String]) {
        var records = installed
        var commits: [String: String] = [:]
        for (id, record) in installed.plugins {
            let tree = trees[id] ?? nil
            guard case .adopt(let commit) = verdict(id, record: record, treeOnDisk: tree, branch: branch,
                                                   pull: followed.pull(of: id, record: record)) else { continue }
            records.plugins[id] = adopted(record, at: commit, branch: branch, now: now)
            commits[id] = commit
        }
        return (records, commits)
    }
}
