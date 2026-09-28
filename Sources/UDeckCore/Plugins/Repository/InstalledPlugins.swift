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
    /// `default` — the source's default branch. Reserved for later: `branch`,
    /// `pr`, `commit`.
    public var kind: String
    /// The branch's name (`main`), or null.
    public var name: String?

    public init(kind: String = "default", name: String?) {
        self.kind = kind
        self.name = name
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
        // `trusted` and `unverified` come with stages 3 and 4.
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

    public init(ref: PluginRef, commit: String, tree: String, version: String) {
        self.ref = ref
        self.commit = commit
        self.tree = tree
        self.version = version
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
        previous: PreviousCopy?
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
    }

    private enum CodingKeys: String, CodingKey {
        case source, repository, ref, commit, tree, version, installedAt, pinned, verification, previous
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
    }

    /// This record's own copy, as the one a later install would replace.
    public var asPrevious: PreviousCopy {
        PreviousCopy(ref: ref, commit: commit, tree: tree, version: version)
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
        // Every commit uDeck installs from the official source comes from its
        // default branch or that branch's history, and force pushes to it are
        // refused, so the commit is one somebody merged.
        if source == InstalledPlugins.officialSource && ref.kind == "default" {
            return PluginVerification(status: .verified, by: InstalledPlugins.officialSource,
                                      checkedAgainst: headCommit ?? commit, checkedAt: now)
        }
        return PluginVerification(status: .modified, by: nil, checkedAgainst: headCommit ?? commit, checkedAt: now)
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
    /// Installed from a repository, and changed on disk since.
    case modifiedLocally
    /// Put into the plugins folder by anyone but uDeck. uDeck claims nothing.
    case folderOfYourOwn
    /// uDeck installed it, and its folder is gone.
    case missing

    /// Where a folder stands, from its record and what its folder hashes to now
    /// (nil when there is no folder).
    public static func of(record: InstalledRecord?, folderExists: Bool, treeOnDisk: String?) -> PluginStanding {
        guard let record else { return .folderOfYourOwn }
        guard folderExists else { return .missing }
        guard treeOnDisk == record.tree else { return .modifiedLocally }
        return record.source == InstalledPlugins.officialSource && record.ref.kind == "default"
            ? .verified : .modifiedLocally
    }
}
