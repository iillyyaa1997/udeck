import Foundation

/// Why the last refresh of a source did not finish, kept so the settings
/// window can say it — in the operator's language — the moment it opens.
public enum CatalogueError: Codable, Equatable, Sendable {
    /// The API limit is used up, or the host asked for a pause.
    case rateLimited(until: Date)
    /// The raw file host answered `429`.
    case rawRateLimited(until: Date)
    /// No answer at all.
    case unreachable(String)
    /// The repository could not be found, or it is private.
    case notFound
    /// No passport, or one that is not JSON, at the top of the branch.
    case notARepository(branch: String)
    /// A passport from a format this uDeck does not read.
    case futureFormat(declared: Int)
    /// A passport that is JSON and not a passport.
    case invalidPassport(String)
    /// A refusal that is not a limit.
    case refused(status: Int)
    /// An answer that could not be read.
    case badAnswer(String)
    /// A file fetched for the catalogue did not hash to what the listing named.
    case arrivedDifferent(path: String, expected: String, got: String)
    /// The official repository's describe answered another number than the
    /// one this uDeck knows it by (`OfficialRepositoryCheck`): its address now
    /// belongs to a different repository, and it is not read — nor anything
    /// updated by itself — until it answers its own number again. An older
    /// uDeck, which does not know this case, reads the state without it.
    case officialRepositoryChanged
}

/// What one source's catalogue remembers between refreshes and launches.
public struct CatalogueState: Codable, Equatable, Sendable {
    public var defaultBranch: String?
    public var defaultBranchReadAt: Date?
    /// The commit the catalogue shown is built from.
    public var head: String?
    /// The `ETag` that commit was answered with, for the next conditional ask.
    public var etag: String?
    public var lastSuccess: Date?
    public var lastAttempt: Date?
    public var lastError: CatalogueError?
    /// Failed refreshes in a row, which decides when the next one is tried.
    public var failuresInARow: Int
    public var rateLimit: RateLimitState

    public init(
        defaultBranch: String? = nil,
        defaultBranchReadAt: Date? = nil,
        head: String? = nil,
        etag: String? = nil,
        lastSuccess: Date? = nil,
        lastAttempt: Date? = nil,
        lastError: CatalogueError? = nil,
        failuresInARow: Int = 0,
        rateLimit: RateLimitState = RateLimitState()
    ) {
        self.defaultBranch = defaultBranch
        self.defaultBranchReadAt = defaultBranchReadAt
        self.head = head
        self.etag = etag
        self.lastSuccess = lastSuccess
        self.lastAttempt = lastAttempt
        self.lastError = lastError
        self.failuresInARow = failuresInARow
        self.rateLimit = rateLimit
    }

    private enum CodingKeys: String, CodingKey {
        case defaultBranch, defaultBranchReadAt, head, etag, lastSuccess, lastAttempt, lastError
        case failuresInARow, rateLimit
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        defaultBranch = try c.decodeIfPresent(String.self, forKey: .defaultBranch)
        defaultBranchReadAt = try c.decodeIfPresent(Date.self, forKey: .defaultBranchReadAt)
        head = try c.decodeIfPresent(String.self, forKey: .head)
        etag = try c.decodeIfPresent(String.self, forKey: .etag)
        lastSuccess = try c.decodeIfPresent(Date.self, forKey: .lastSuccess)
        lastAttempt = try c.decodeIfPresent(Date.self, forKey: .lastAttempt)
        // An error this build does not know is no reason to lose the rest.
        lastError = try? c.decodeIfPresent(CatalogueError.self, forKey: .lastError)
        failuresInARow = try c.decodeIfPresent(Int.self, forKey: .failuresInARow) ?? 0
        rateLimit = try c.decodeIfPresent(RateLimitState.self, forKey: .rateLimit) ?? RateLimitState()
    }
}

/// A plugin's earlier versions, from its folder's history.
public struct PluginHistory: Codable, Equatable, Sendable {
    public struct Line: Codable, Equatable, Sendable {
        public var version: String
        /// The newest commit that has this version: that version as it finally was.
        public var commit: String
        public var date: Date?
        /// The manifest at that commit, for whether it can run here.
        public var manifest: PluginManifest?

        public init(version: String, commit: String, date: Date?, manifest: PluginManifest?) {
            self.version = version
            self.commit = commit
            self.date = date
            self.manifest = manifest
        }
    }

    public var id: String
    /// The head it was read at. Valid while the head commit is unchanged.
    public var headCommit: String
    /// Newest first.
    public var lines: [Line]

    public init(id: String, headCommit: String, lines: [Line]) {
        self.id = id
        self.headCommit = headCommit
        self.lines = lines
    }
}

/// `~/.udeck/catalogue/<source>/`: everything a catalogue is made of, on disk.
///
/// ```
/// state.json            default branch, head and its ETag, the last refresh, the last error, the limit
/// followed.json         what was last heard of the pull request each copy installed from one came from
/// trees/<commit>.json   the listing of one commit
/// blobs/<blob sha>      passports, manifests and translations, stored under their own hash
/// too-large/<blob sha>  a blob refused as larger than a plugin's file may be: its size
/// history/<id>.json     a plugin's earlier versions, valid while the head commit is unchanged
/// versions/<id>.json    the manifest each commit of a plugin's history had, by blob, for the next read
/// ```
///
/// Not under `~/.udeck/cache/`: every folder there belongs to the plugin of the
/// same name, and a plugin called `catalogue` is a legal id.
public struct CatalogueStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public init(paths: UDeckPaths, source: String = InstalledPlugins.officialSource) {
        self.init(directory: paths.catalogue.appendingPathComponent(source, isDirectory: true))
    }

    private var fileManager: FileManager { .default }
    private var stateStore: JSONFileStore<CatalogueState> { .init(url: directory.appendingPathComponent("state.json")) }
    private var followedStore: JSONFileStore<FollowedRefs> { .init(url: directory.appendingPathComponent("followed.json")) }
    private var trees: URL { directory.appendingPathComponent("trees", isDirectory: true) }
    private var blobs: URL { directory.appendingPathComponent("blobs", isDirectory: true) }
    private var histories: URL { directory.appendingPathComponent("history", isDirectory: true) }
    private var tooLarge: URL { directory.appendingPathComponent("too-large", isDirectory: true) }
    private var versionIndexes: URL { directory.appendingPathComponent("versions", isDirectory: true) }

    // MARK: - State

    /// The state, or a fresh one when there is none. A state file that will
    /// not parse is started over rather than reported: nothing in it is the
    /// operator's, all of it can be asked for again.
    public func state() -> CatalogueState {
        (try? stateStore.load()) ?? CatalogueState()
    }

    public func save(_ state: CatalogueState) throws {
        try Self.stateLock.withLock { try stateStore.save(state) }
    }

    /// Every write of a catalogue's `state.json`, in this process, one at a
    /// time: a read writes its whole state when it ends, on whatever thread it
    /// ran (`CatalogueRefresher`), and keeping the limit after a request reads
    /// the state, changes it and writes it (`updateState`). Without one lock
    /// over both, the second could read the state from before the read's own
    /// write and write it back over it — the head, the error, the official
    /// repository's number answered wrongly, all of it lost.
    private static let stateLock = NSLock()

    /// `change` made to the state as it is on disk now, and written, in one
    /// step with every other write of a state (`save`): what keeping the limit
    /// after a request does. Answers the state as changed.
    @discardableResult
    public func updateState(_ change: (inout CatalogueState) -> Void) -> CatalogueState {
        Self.stateLock.withLock {
            var state = self.state()
            change(&state)
            try? stateStore.save(state)
            return state
        }
    }

    // MARK: - Followed pull requests

    /// What was last heard of the pull request each copy installed from one
    /// came from, or nothing. A file that will not parse is started over, as
    /// the state is.
    public func followed() -> FollowedRefs {
        (try? followedStore.load()) ?? FollowedRefs()
    }

    public func save(followed: FollowedRefs) throws {
        try followedStore.save(followed)
    }

    // MARK: - Listings

    public func listing(_ commit: String) -> CommitListing? {
        guard GitHash.isObjectID(commit) else { return nil }
        return try? JSONFileStore<CommitListing>(url: trees.appendingPathComponent("\(commit).json")).load()
    }

    public func save(_ listing: CommitListing) throws {
        try JSONFileStore<CommitListing>(url: trees.appendingPathComponent("\(listing.commit).json")).save(listing)
    }

    // MARK: - Blobs

    /// A stored blob — read back and hashed again, so a file changed on disk
    /// is a miss rather than an answer.
    ///
    /// Never on the main thread: a blob is a manifest of somebody else's, of
    /// any size the rules allow, and reading and hashing it there holds the
    /// panel. uDeck reads blobs through `Catalogue.read` and `manifest(of:)`,
    /// which run on the cooperative pool; a build that keeps assertions stops
    /// a caller that slips back onto the main thread.
    public func blob(_ sha: String) -> Data? {
        assert(!Thread.isMainThread, "a catalogue blob was read and hashed on the main thread")
        guard GitHash.isObjectID(sha),
              let data = try? Data(contentsOf: blobs.appendingPathComponent(sha)),
              GitHash.blob(data) == sha else { return nil }
        return data
    }

    /// The manifest of a plugin folder of a listing, from the blob store,
    /// away from the main thread (`blob`).
    public func manifest(of folder: PluginListing) async -> Data? {
        folder.file(at: PluginDiscovery.manifestFilename).flatMap { blob($0.sha) }
    }

    @discardableResult
    public func save(blob data: Data) throws -> String {
        let sha = GitHash.blob(data)
        try fileManager.createDirectory(at: blobs, withIntermediateDirectories: true)
        try data.write(to: blobs.appendingPathComponent(sha), options: .atomic)
        return sha
    }

    /// How large a blob was said or found to be when it was refused for being
    /// larger than a plugin's file may be — nil for one never refused. A
    /// blob's id is its content's hash, so what was too large once always is,
    /// and it is not asked for again while a kept listing names it.
    public func refusedAsTooLarge(_ sha: String) -> Int? {
        guard GitHash.isObjectID(sha),
              let text = try? String(contentsOf: tooLarge.appendingPathComponent(sha), encoding: .utf8),
              let bytes = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)), bytes > 0 else { return nil }
        return bytes
    }

    /// Remembers that the blob `sha` was refused at `bytes`.
    public func refuseAsTooLarge(_ sha: String, bytes: Int) throws {
        guard GitHash.isObjectID(sha) else { return }
        try fileManager.createDirectory(at: tooLarge, withIntermediateDirectories: true)
        try Data(String(bytes).utf8).write(to: tooLarge.appendingPathComponent(sha), options: .atomic)
    }

    // MARK: - History

    public func history(_ id: String) -> PluginHistory? {
        try? JSONFileStore<PluginHistory>(url: histories.appendingPathComponent("\(id).json")).load()
    }

    public func save(_ history: PluginHistory) throws {
        try JSONFileStore<PluginHistory>(url: histories.appendingPathComponent("\(history.id).json")).save(history)
    }

    /// What the last read of `id`'s history found at each commit it examined
    /// (`VersionIndex`), or nothing.
    public func versionIndex(_ id: String) -> VersionIndex? {
        try? JSONFileStore<VersionIndex>(url: versionIndexes.appendingPathComponent("\(id).json")).load()
    }

    public func save(_ index: VersionIndex, for id: String) throws {
        try JSONFileStore<VersionIndex>(url: versionIndexes.appendingPathComponent("\(id).json")).save(index)
    }

    /// What a read of `id`'s history found, kept in one step with every
    /// pruning (`prune`): each of `fetched`'s manifests — every one the read
    /// has, those it found in the store as well — stored under its own hash
    /// and named in `index` by its commit, and the index written. So no index
    /// names a blob a prune deleted while the read went on, and no prune
    /// deletes a blob an index written meanwhile names. Answers the index as
    /// written; a manifest that could not be stored is left out of it, and
    /// asked for again by the next read.
    @discardableResult
    public func keep(_ index: VersionIndex, adding fetched: [String: Data], for id: String) -> VersionIndex {
        Self.blobLock.withLock {
            var kept = index
            for (commit, data) in fetched {
                if let blob = try? save(blob: data) { kept.manifests[commit] = blob }
            }
            try? save(kept, for: id)
            return kept
        }
    }

    /// Every prune, and every keeping of a read history (`keep`), in this
    /// process, one at a time.
    private static let blobLock = NSLock()

    // MARK: - Pruning

    /// Keeps a listing while it is the head, or while a plugin in
    /// `installed.json` was installed from it (as its current or its previous
    /// copy); keeps a blob while a kept listing or a kept version index names
    /// it, and a too-large mark while a kept listing names its blob; keeps a
    /// history while its head is the head, and a version index while the
    /// head's listing has its plugin — or while no listing of the head is
    /// kept to say. Everything else goes.
    public func prune(head: String?, installedCommits: Set<String>) {
        Self.blobLock.withLock { pruneNow(head: head, installedCommits: installedCommits) }
    }

    private func pruneNow(head: String?, installedCommits: Set<String>) {
        let keptCommits = installedCommits.union(head.map { [$0] } ?? [])
        var keptBlobs = Set<String>()
        var listed = Set<String>()

        for name in (try? fileManager.contentsOfDirectory(atPath: trees.path)) ?? [] {
            let commit = (name as NSString).deletingPathExtension
            guard keptCommits.contains(commit), let listing = listing(commit) else {
                try? fileManager.removeItem(at: trees.appendingPathComponent(name))
                continue
            }
            if let passport = listing.passport { keptBlobs.insert(passport) }
            for plugin in listing.plugins.values {
                for entry in plugin.files where entry.path.hasPrefix("manifest") && entry.path.hasSuffix(".json") {
                    keptBlobs.insert(entry.sha)
                }
            }
        }
        for name in (try? fileManager.contentsOfDirectory(atPath: tooLarge.path)) ?? [] where !keptBlobs.contains(name) {
            try? fileManager.removeItem(at: tooLarge.appendingPathComponent(name))
        }
        let headListing = head.flatMap { listing($0) }
        if let headListing { listed = Set(headListing.plugins.keys) }
        for name in (try? fileManager.contentsOfDirectory(atPath: versionIndexes.path)) ?? [] {
            let id = (name as NSString).deletingPathExtension
            guard headListing == nil || listed.contains(id), let index = versionIndex(id) else {
                try? fileManager.removeItem(at: versionIndexes.appendingPathComponent(name))
                continue
            }
            keptBlobs.formUnion(index.manifests.values)
        }
        for name in (try? fileManager.contentsOfDirectory(atPath: blobs.path)) ?? [] where !keptBlobs.contains(name) {
            try? fileManager.removeItem(at: blobs.appendingPathComponent(name))
        }
        for name in (try? fileManager.contentsOfDirectory(atPath: histories.path)) ?? [] {
            let id = (name as NSString).deletingPathExtension
            if history(id)?.headCommit != head {
                try? fileManager.removeItem(at: histories.appendingPathComponent(name))
            }
        }
    }
}

/// What a read of a plugin's history found at each commit it examined, kept
/// so the next read asks only about commits it has not seen
/// (`PluginHistoryReader`): a commit's manifest is what it is for good, as
/// its blob id says. The commits of the last read alone — at most
/// `PluginHistoryReader.deepest` — so it never grows past one read.
public struct VersionIndex: Codable, Equatable, Sendable {
    /// Each commit whose folder had a manifest, and that manifest's blob id
    /// — the blob kept in the store while this index is.
    public var manifests: [String: String]
    /// Each commit where the folder, or its manifest, was not there.
    public var absent: [String]

    public init(manifests: [String: String] = [:], absent: [String] = []) {
        self.manifests = manifests
        self.absent = absent
    }
}
