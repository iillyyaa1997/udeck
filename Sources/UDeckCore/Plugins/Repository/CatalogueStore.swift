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
/// trees/<commit>.json   the listing of one commit
/// blobs/<blob sha>      passports, manifests and translations, stored under their own hash
/// history/<id>.json     a plugin's earlier versions, valid while the head commit is unchanged
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
    private var trees: URL { directory.appendingPathComponent("trees", isDirectory: true) }
    private var blobs: URL { directory.appendingPathComponent("blobs", isDirectory: true) }
    private var histories: URL { directory.appendingPathComponent("history", isDirectory: true) }

    // MARK: - State

    /// The state, or a fresh one when there is none. A state file that will
    /// not parse is started over rather than reported: nothing in it is the
    /// operator's, all of it can be asked for again.
    public func state() -> CatalogueState {
        (try? stateStore.load()) ?? CatalogueState()
    }

    public func save(_ state: CatalogueState) throws {
        try stateStore.save(state)
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

    // MARK: - History

    public func history(_ id: String) -> PluginHistory? {
        try? JSONFileStore<PluginHistory>(url: histories.appendingPathComponent("\(id).json")).load()
    }

    public func save(_ history: PluginHistory) throws {
        try JSONFileStore<PluginHistory>(url: histories.appendingPathComponent("\(history.id).json")).save(history)
    }

    // MARK: - Pruning

    /// Keeps a listing while it is the head, or while a plugin in
    /// `installed.json` was installed from it (as its current or its previous
    /// copy); keeps a blob while a kept listing names it; keeps a history while
    /// its head is the head. Everything else goes.
    public func prune(head: String?, installedCommits: Set<String>) {
        let keptCommits = installedCommits.union(head.map { [$0] } ?? [])
        var keptBlobs = Set<String>()

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
