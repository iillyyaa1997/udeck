import Foundation

/// Where a repository is: the provider, its host, and `owner/repo`.
public struct RepositoryAddress: Codable, Equatable, Hashable, Sendable, CustomStringConvertible {
    /// `github` in stage 1; `gitlab` later.
    public var provider: String
    public var host: String
    /// `owner/repo`.
    public var path: String

    public init(provider: String = "github", host: String = "github.com", path: String) {
        self.provider = provider
        self.host = host
        self.path = path
    }

    /// `github.com/owner/repo`, as the operator reads it.
    public var description: String { "\(host)/\(path)" }

    /// The built-in official source, before `Info.plist` says otherwise.
    public static let official = RepositoryAddress(path: "iillyyaa1997/udeck-plugins")
}

/// Which line of a repository's history a plugin follows.
public struct PluginRef: Codable, Equatable, Hashable, Sendable {
    /// `default` — the source's default branch; `branch` — another branch;
    /// `pr` — a pull request. Reserved for later: `commit`. A kind this uDeck
    /// does not know is read as it is written, and is unverified.
    public var kind: String
    /// The default branch's name (`main`) or null; the branch's name; the
    /// pull request's number, as a string.
    public var name: String?

    public init(kind: String = PluginRef.defaultKind, name: String?) {
        self.kind = kind
        self.name = name
    }

    public static let defaultKind = "default"
    public static let branchKind = "branch"
    public static let pullRequestKind = "pr"

    /// The source's default branch, `name` when it is known.
    public static func defaultBranch(_ name: String?) -> PluginRef { PluginRef(kind: defaultKind, name: name) }
    /// A branch other than the default one.
    public static func branch(_ name: String) -> PluginRef { PluginRef(kind: branchKind, name: name) }
    /// A pull request, by its number.
    public static func pullRequest(_ number: Int) -> PluginRef { PluginRef(kind: pullRequestKind, name: String(number)) }

    /// Whether this is the source's default branch.
    public var isDefault: Bool { kind == Self.defaultKind }

    /// The pull request's number, for a pull request.
    public var pullRequestNumber: Int? {
        guard kind == Self.pullRequestKind, let name, let number = Int(name), number > 0 else { return nil }
        return number
    }

    private enum CodingKeys: String, CodingKey { case kind, name }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        // Written as null rather than left out: the record's shape is part of
        // what docs/plugin-repository.md promises.
        try c.encode(name, forKey: .name)
    }
}

/// What a folder was, the last time uDeck looked.
public struct PluginVerification: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        /// Installed from the default branch of the official repository, and
        /// still exactly what was merged there.
        case verified
        /// The folder no longer hashes to what was installed.
        case modified
        /// Exactly what was installed, from a branch or a pull request: code
        /// nobody verified.
        case unverified
        // `trusted` comes with stage 4.

        /// A status this uDeck does not know — written by a later one — is
        /// read as `modified`: the status is recomputed from the folder anyway
        /// and never decides anything, and a word the file did not have when
        /// this build was made is no reason to read the whole file as broken,
        /// which would stop every install, update and removal.
        public init(from decoder: any Decoder) throws {
            let text = try decoder.singleValueContainer().decode(String.self)
            self = Status(rawValue: text) ?? .modified
        }
    }

    public var status: Status
    /// Whose guarantee it is — `official` — or null when it is nobody's.
    public var by: String?
    /// The commit of the default branch the folder was compared against.
    public var checkedAgainst: String?
    public var checkedAt: Date

    public init(status: Status, by: String?, checkedAgainst: String?, checkedAt: Date) {
        self.status = status
        self.by = by
        self.checkedAgainst = checkedAgainst
        self.checkedAt = InstalledPlugins.wholeSeconds(checkedAt)
    }

    private enum CodingKeys: String, CodingKey { case status, by, checkedAgainst, checkedAt }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(status, forKey: .status)
        try c.encode(by, forKey: .by)
        try c.encode(checkedAgainst, forKey: .checkedAgainst)
        try c.encode(checkedAt, forKey: .checkedAt)
    }

    /// The same finding, whenever it was made.
    public func saysTheSame(as other: PluginVerification) -> Bool {
        status == other.status && by == other.by && checkedAgainst == other.checkedAgainst
    }
}

/// The copy a plugin replaced: enough to put it back in one click.
public struct PreviousCopy: Codable, Equatable, Sendable {
    public var ref: PluginRef
    public var commit: String
    public var tree: String
    public var version: String
    /// The repository it came from. Absent from every copy recorded before
    /// there were branches and pull requests: those came from the source's
    /// own repository.
    public var repository: RepositoryAddress?

    public init(ref: PluginRef, commit: String, tree: String, version: String, repository: RepositoryAddress? = nil) {
        self.ref = ref
        self.commit = commit
        self.tree = tree
        self.version = version
        self.repository = repository
    }

    /// Where it came from — `source` being the source's own repository,
    /// where a copy recorded without one came from.
    public func origin(source: RepositoryAddress) -> PluginOrigin {
        PluginOrigin(repository: repository ?? source, ref: ref)
    }

    /// Which source this copy is the copy of — `previous` keeps no source of
    /// its own, so that a uDeck from before sources reads and writes it as it
    /// always did — worked out from what it does keep, in this order, `record`
    /// being the record it is the previous copy of, `official` the official
    /// repository and `sources` the sources added:
    ///
    /// 1. no repository, or `record`'s: `record`'s source;
    /// 2. a ref that is not the default branch: the official source — a
    ///    branch, a pull request and a fork's branch are its, and a source of
    ///    one's own has no other refs;
    /// 3. the official repository: the official source;
    /// 4. a source's address as it is now (`OwnSource.isAt`): that source;
    /// 5. anything else is no source any more, and **Back to** is not offered.
    public func source(record: InstalledRecord, official: RepositoryAddress, sources: [OwnSource]) -> PreviousSource {
        let from = repository ?? (record.source == InstalledPlugins.officialSource
            ? official : sources.first { $0.id == record.source }?.address ?? record.repository)
        if repository == nil || repository == record.repository {
            return .source(PluginOrigin(repository: from, ref: ref, source: record.source))
        }
        if !ref.isDefault || from.isTheOfficialRepository(official) {
            return .source(PluginOrigin(repository: from, ref: ref, source: InstalledPlugins.officialSource))
        }
        if let source = sources.first(where: { $0.isAt(from) }) {
            return .source(PluginOrigin(repository: from, ref: ref, source: source.id))
        }
        return .notASource(from)
    }
}

/// Which source a previous copy is of (`PreviousCopy.source`).
public enum PreviousSource: Equatable, Sendable {
    /// Where **Back to** takes it from: its repository and ref, and the source.
    case source(PluginOrigin)
    /// A repository that is no source any more: *"github.com/… is not a
    /// source any more"*, and no **Back to**.
    case notASource(RepositoryAddress)
}

extension RepositoryAddress {
    /// Whether this is `official`, the official repository: its provider and
    /// host, and its path whatever its case, as GitHub reads names.
    public func isTheOfficialRepository(_ official: RepositoryAddress) -> Bool {
        provider == official.provider && host.lowercased() == official.host.lowercased()
            && path.lowercased() == official.path.lowercased()
    }
}

/// Where a copy comes from: a repository, and the line of its history — what
/// an install records, and what **Reinstall** and **Back to** take it from
/// again, so that a copy from a pull request is put back as one, never as
/// the default branch's — and the source it is a copy of: `official`, or the
/// id of a source of one's own (`SourceID`). Not kept anywhere but in the
/// record's `source`: what a button brings carries it (`ShownPlace.Step`), and
/// the install records it (`InstallRequest.source`).
public struct PluginOrigin: Equatable, Sendable {
    public var repository: RepositoryAddress
    public var ref: PluginRef
    public var source: String

    public init(repository: RepositoryAddress, ref: PluginRef, source: String = InstalledPlugins.officialSource) {
        self.repository = repository
        self.ref = ref
        self.source = source
    }

    /// Whether a copy is taken from here for the source whose own repository
    /// is `source`: from a repository on its host, and the default branch
    /// from `source` alone. A copy of the default branch is recorded as the
    /// source's own, which stands Verified (`InstalledRecord.isOfficialDefault`):
    /// another repository's default branch — a fork's — is never taken as one.
    public func mayBeTaken(forSourceAt source: RepositoryAddress) -> Bool {
        guard repository.provider == source.provider, repository.host == source.host else { return false }
        return !ref.isDefault || repository == source
    }
}

/// Where one installed plugin came from, and what it was when it was put there.
public struct InstalledRecord: Codable, Equatable, Sendable {
    /// The source it was installed from: `official` in stage 1.
    public var source: String
    /// A copy of where that source pointed, so the record still says where the
    /// plugin came from after the source is renamed or removed.
    public var repository: RepositoryAddress
    public var ref: PluginRef
    /// The commit the files were taken from.
    public var commit: String
    /// The tree id of `plugins/<id>` at that commit — and so of the folder on
    /// disk, as it was installed.
    public var tree: String
    /// The manifest's `version` at that commit.
    public var version: String
    public var installedAt: Date
    /// The operator chose this version over the newest one. A pinned plugin is
    /// still told about newer versions; **Update** clears it.
    public var pinned: Bool
    public var verification: PluginVerification
    public var previous: PreviousCopy?
    /// True when this copy was put in place by uDeck itself — a verified
    /// plugin updating itself (`AutoUpdate`) — rather than by a press: the row
    /// says *Updated by itself on October 10, 2026*. Absent from the file otherwise,
    /// and from every record written before there were automatic updates.
    public var automatic: Bool?

    public init(
        source: String,
        repository: RepositoryAddress,
        ref: PluginRef,
        commit: String,
        tree: String,
        version: String,
        installedAt: Date,
        pinned: Bool,
        verification: PluginVerification,
        previous: PreviousCopy?,
        automatic: Bool? = nil
    ) {
        self.source = source
        self.repository = repository
        self.ref = ref
        self.commit = commit
        self.tree = tree
        self.version = version
        self.installedAt = InstalledPlugins.wholeSeconds(installedAt)
        self.pinned = pinned
        self.verification = verification
        self.previous = previous
        self.automatic = automatic
    }

    private enum CodingKeys: String, CodingKey {
        case source, repository, ref, commit, tree, version, installedAt, pinned, verification, previous, automatic
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(source, forKey: .source)
        try c.encode(repository, forKey: .repository)
        try c.encode(ref, forKey: .ref)
        try c.encode(commit, forKey: .commit)
        try c.encode(tree, forKey: .tree)
        try c.encode(version, forKey: .version)
        try c.encode(installedAt, forKey: .installedAt)
        try c.encode(pinned, forKey: .pinned)
        try c.encode(verification, forKey: .verification)
        // `null` after a first install, written rather than left out.
        try c.encode(previous, forKey: .previous)
        // Only on a copy uDeck put in place by itself: every other record
        // keeps the shape it always had, and a uDeck from before automatic
        // updates reads this one too, skipping the key it does not know.
        if automatic == true { try c.encode(true, forKey: .automatic) }
    }

    /// This record's own copy, as the one a later install would replace.
    public var asPrevious: PreviousCopy {
        PreviousCopy(ref: ref, commit: commit, tree: tree, version: version, repository: repository)
    }

    /// Where this copy came from, and the source it is a copy of: what
    /// **Reinstall** puts back.
    public var origin: PluginOrigin { PluginOrigin(repository: repository, ref: ref, source: source) }

    /// Whether this copy came from the default branch of the official
    /// source: every commit uDeck installs from there comes from that branch
    /// or its history, and force pushes to it are refused, so the commit is
    /// one somebody merged. Anything else — a branch, a pull request, a kind
    /// of ref this uDeck does not know — is code nobody verified.
    public var isOfficialDefault: Bool {
        source == InstalledPlugins.officialSource && ref.isDefault
    }

    /// What the folder is now, given the tree it hashes to on disk and the
    /// commit of the default branch it is being compared against.
    ///
    /// Recomputed every time the plugins folder is read and after every
    /// refresh, and never trusted from the file: the stored value is there so
    /// Settings can show where a plugin stands the moment it opens, not so that
    /// anything is decided on it.
    public func verification(treeOnDisk: String?, headCommit: String?, now: Date) -> PluginVerification {
        guard treeOnDisk == tree else {
            return PluginVerification(status: .modified, by: nil, checkedAgainst: headCommit ?? commit, checkedAt: now)
        }
        if isOfficialDefault {
            return PluginVerification(status: .verified, by: InstalledPlugins.officialSource,
                                      checkedAgainst: headCommit ?? commit, checkedAt: now)
        }
        return PluginVerification(status: .unverified, by: nil, checkedAgainst: headCommit ?? commit, checkedAt: now)
    }
}

/// `~/.udeck/installed.json`: every plugin uDeck installed from a repository.
///
/// Written the same atomic way as the other stores, and a broken copy is
/// reported rather than overwritten — and while it is broken uDeck installs,
/// updates and removes nothing, since any of those would have to overwrite
/// it. Nothing is ever written into a plugin's folder: the folder is exactly
/// the repository's, which is what lets its hash be compared at all.
public struct InstalledPlugins: Codable, Equatable, Sendable {
    public static let officialSource = "official"

    public var version: Int
    public var plugins: [String: InstalledRecord]

    public init(version: Int = 1, plugins: [String: InstalledRecord] = [:]) {
        self.version = version
        self.plugins = plugins
    }

    public subscript(id: PluginIdentifier) -> InstalledRecord? {
        get { plugins[id.rawValue] }
        set { plugins[id.rawValue] = newValue }
    }

    /// Every commit a record points at, current or previous: the listings the
    /// catalogue cache has to keep.
    public var commits: Set<String> {
        Set(plugins.values.flatMap { [$0.commit] + ($0.previous.map { [$0.commit] } ?? []) })
    }

    /// Dates in the file are whole seconds, UTC.
    static func wholeSeconds(_ date: Date) -> Date {
        Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
    }
}

/// Where a plugin on this machine stands, as its row in Settings shows it.
public enum PluginStanding: Equatable, Sendable {
    /// Installed from the official repository and still exactly what was merged.
    case verified
    /// Installed from a branch or a pull request, and still exactly that:
    /// nobody verified it.
    case unverified
    /// Installed from a repository, and changed on disk since.
    case modifiedLocally
    /// Put into the plugins folder by anyone but uDeck. uDeck claims nothing.
    case folderOfYourOwn
    /// uDeck installed it, and its folder is gone.
    case missing

    /// Whether this plugin's row offers **Reinstall**: what the record says was
    /// installed, put back over a copy changed on disk or where the folder has
    /// gone. It is a download, so only while the copy's source can be read
    /// (`readsCatalogue`, `SourceAccess.canRead`).
    public func offersReinstall(readsCatalogue: Bool) -> Bool {
        readsCatalogue && (self == .modifiedLocally || self == .missing)
    }

    /// Where a folder stands, from its record and what its folder hashes to now
    /// (nil when there is no folder).
    public static func of(record: InstalledRecord?, folderExists: Bool, treeOnDisk: String?) -> PluginStanding {
        guard let record else { return .folderOfYourOwn }
        guard folderExists else { return .missing }
        guard treeOnDisk == record.tree else { return .modifiedLocally }
        return record.isOfficialDefault ? .verified : .unverified
    }
}

/// What a plugin's permission decision is held to.
///
/// A verified copy, a folder of the operator's own and a linked working copy
/// are decided once per `version`, as they always were. Code nobody verified —
/// installed from a branch or a pull request — is decided per tree: every new
/// content asks again, even when the plugin asks for nothing, because it
/// changes without anybody reviewing it and there is no sandbox. The record's
/// ref is used only to ask for more, never to allow: whatever it says, a
/// copy that is not the official default branch's is held to its tree.
public enum ConsentBasis: Equatable, Sendable {
    case version
    case tree

    /// The basis of a plugin with `record` — none for a folder uDeck did not
    /// install — whose folder is a link (`linked`) or not. A link is the
    /// operator's own working copy, whatever record is left at its id.
    ///
    /// `recordsReadable` is whether `installed.json` could be read. While it
    /// cannot, nothing says where any copy came from, and every folder that
    /// is not a link is held to its tree: a broken file only ever asks for
    /// more, never lets a branch's copy run on its version.
    public static func of(_ record: InstalledRecord?, linked: Bool, recordsReadable: Bool) -> ConsentBasis {
        guard !linked else { return .version }
        guard recordsReadable else { return .tree }
        guard let record, !record.isOfficialDefault else { return .version }
        return .tree
    }

    /// The tree `PermissionGate` requires: none for a decision held to the
    /// version; for one held to the tree, the tree its folder hashes to —
    /// `hashed`, nil while it has not been hashed or would not hash — or,
    /// until then, one no decision holds for, so that the plugin waits.
    public func requiredTree(hashed: String?) -> String? {
        switch self {
        case .version: nil
        case .tree: hashed ?? PermissionGate.treeNotHashedYet
        }
    }
}

/// What each plugin folder hashed to, for the decisions held to a tree
/// (`ConsentBasis`) — and whether the plugins folder may have changed since.
///
/// Two questions, two answers. Whether a plugin's poll loop runs, and what
/// its card shows, go by the tree last hashed (`lastHashed`): a change in the
/// plugins folder that hashes to the same tree again stops no loop and
/// changes no card. Whether a run starts now, and what a decision is made
/// for, go by the folder as it is now (`now`): from a change the watcher saw
/// until its hashing lands, nothing held to its tree runs or is decided —
/// such a run is skipped, not failed (`skipsRun`).
public struct HashedTrees: Equatable, Sendable {
    /// By folder name: the tree, or nil for a folder that would not hash.
    public private(set) var trees: [String: String?]
    /// Whether the plugins folder was read to be hashed again, or a copy was
    /// put in place, and that hashing has not landed.
    public private(set) var inQuestion: Bool

    public init(trees: [String: String?] = [:], inQuestion: Bool = false) {
        self.trees = trees
        self.inQuestion = inQuestion
    }

    /// Something in the plugins folder changed, or a copy was put in place:
    /// until the next hashing lands, nothing held to its tree runs.
    public mutating func mayHaveChanged() {
        inQuestion = true
    }

    /// A hashing landed: what the folders hash to now.
    public mutating func hashed(_ trees: [String: String?]) {
        self.trees = trees
        inQuestion = false
    }

    /// The tree the gate requires of `id`, held to `basis`, as last hashed:
    /// what its loop is planned on and its card shows.
    public func lastHashed(_ id: String, basis: ConsentBasis) -> String? {
        basis.requiredTree(hashed: trees[id] ?? nil)
    }

    /// The same for a run that starts now, or a decision made now: while
    /// the folder may have changed since it was hashed, one no decision
    /// holds for.
    public func now(_ id: String, basis: ConsentBasis) -> String? {
        guard basis == .tree, inQuestion else { return lastHashed(id, basis: basis) }
        return PermissionGate.treeNotHashedYet
    }

    /// Whether a run of `id` that starts now is skipped — not run, and not
    /// recorded as a failure: its folder is held to its tree and is not
    /// hashed, or may have changed since. Its card says why it waits.
    public func skipsRun(_ id: String, basis: ConsentBasis) -> Bool {
        now(id, basis: basis) == PermissionGate.treeNotHashedYet
    }

    /// Whether `id`'s folder was hashed and would not hash — a file that
    /// cannot be read: no decision can be held to it.
    public func wouldNotHash(_ id: String) -> Bool {
        guard let tree = trees[id] else { return false }
        return tree == nil
    }
}
