import Darwin
import Foundation

/// Where something uDeck did not put there goes when uDeck takes it away.
///
/// A parameter, so tests can hold what was thrown away somewhere of their own
/// instead of in the Trash of whoever runs them.
public protocol PluginTrash: Sendable {
    func discard(_ url: URL) throws
}

/// The Finder's Trash: a folder of the operator's own, or one they changed, is
/// moved there rather than deleted — it may be the author's only copy.
public struct SystemTrash: PluginTrash {
    public init() {}
    public func discard(_ url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }
}

/// The two renames a folder is put in place with, as calls to the system.
///
/// A parameter so the fallback can be tested on a volume that does swap.
public struct FolderRenames: Sendable {
    /// Exchanges two paths in one step. Answers 0, or the `errno` it failed with.
    public var exchange: @Sendable (_ from: URL, _ to: URL) -> Int32
    /// Moves `from` to `to`, failing rather than overwriting what is at `to`.
    public var exclusive: @Sendable (_ from: URL, _ to: URL) -> Int32
    /// One move of the fallback, on a volume that cannot exchange.
    public var move: @Sendable (_ from: URL, _ to: URL) throws -> Void

    public init(exchange: @escaping @Sendable (URL, URL) -> Int32,
                exclusive: @escaping @Sendable (URL, URL) -> Int32,
                move: @escaping @Sendable (URL, URL) throws -> Void = FolderRenames.fileManagerMove) {
        self.exchange = exchange
        self.exclusive = exclusive
        self.move = move
    }

    /// `renamex_np` with `RENAME_SWAP` and `RENAME_EXCL`, and `FileManager`'s move.
    public static let system = FolderRenames(
        exchange: { from, to in
            renamex_np(from.path, to.path, UInt32(RENAME_SWAP)) == 0 ? 0 : errno
        },
        exclusive: { from, to in
            renamex_np(from.path, to.path, UInt32(RENAME_EXCL)) == 0 ? 0 : errno
        }
    )

    public static let fileManagerMove: @Sendable (URL, URL) throws -> Void = { from, to in
        try FileManager.default.moveItem(at: from, to: to)
    }
}

/// One install, update or earlier version to be made: a plugin's folder at one
/// commit, and what to record when it is in place.
public struct InstallRequest: Codable, Equatable, Sendable {
    public enum Operation: String, Codable, Sendable {
        /// A plugin that is not here yet.
        case install
        /// The head, over a copy installed from here: its record moves to
        /// `previous`, and `pinned` goes back to false.
        case update
        /// An earlier version from history, or **Back to** `previous`: marked
        /// pinned.
        case earlier
        /// What the record says was installed, put back — over a copy changed
        /// on disk, or where the folder has gone.
        case reinstall
        /// The repository's copy, over a folder of the operator's own with the
        /// same id.
        case replace
    }

    public var operation: Operation
    public var id: PluginIdentifier
    public var source: String
    public var repository: RepositoryAddress
    public var ref: PluginRef
    public var commit: String
    /// The folder at that commit, as the listing gave it.
    public var folder: PluginListing
    /// The version the catalogue showed. What arrives has to be it.
    public var version: String
    /// The head of the default branch, which the new copy is verified against.
    public var headCommit: String?

    public init(operation: Operation, id: PluginIdentifier, source: String = InstalledPlugins.officialSource,
                repository: RepositoryAddress, ref: PluginRef, commit: String, folder: PluginListing,
                version: String, headCommit: String?) {
        self.operation = operation
        self.id = id
        self.source = source
        self.repository = repository
        self.ref = ref
        self.commit = commit
        self.folder = folder
        self.version = version
        self.headCommit = headCommit
    }
}

/// `intent.json`: a journal of one operation, in its staging folder, so that a
/// crash halfway can be finished or undone at the next launch.
public struct InstallIntent: Codable, Equatable, Sendable {
    public enum Operation: String, Codable, Sendable {
        case install, update, earlier, reinstall, replace, remove
    }

    public var operation: Operation
    public var id: String
    /// The record written if it succeeds. Absent for a removal.
    public var record: InstalledRecord?
    /// Whether the copy this one replaces — or removes — is the operator's: a
    /// folder of their own, or one they changed. Those go to the Trash.
    public var oldCopyIsOperators: Bool

    public init(operation: Operation, id: String, record: InstalledRecord?, oldCopyIsOperators: Bool) {
        self.operation = operation
        self.id = id
        self.record = record
        self.oldCopyIsOperators = oldCopyIsOperators
    }

    static let filename = "intent.json"
}

/// Why an install, update or removal did not happen. Anything before the swap
/// leaves `~/.udeck` exactly as it was.
public enum InstallError: Error, Equatable, Sendable {
    /// The repository's plugin is not one uDeck will put on this machine.
    case refused([RepositoryRefusal])
    /// `installed.json` will not parse, so nothing that would overwrite it runs.
    case recordsBroken(String)
    /// The raw file host asked for a pause.
    case rawRateLimited(until: Date)
    /// The API is blocked and the listing this needs is not cached.
    case rateLimited(until: Date)
    /// A file could not be fetched after the retries.
    case unreachable(path: String, reason: String)
    /// The whole install took longer than five minutes.
    case tookTooLong
    /// The disk said no.
    case cannotWrite(String)
    /// Something of the plugin was still running after it was quieted and its
    /// card actions were ended, so its folder was left as it was.
    case stillRunning(id: String)

    public var refusals: [RepositoryRefusal] {
        if case .refused(let refusals) = self { refusals } else { [] }
    }
}

/// A plugin's files, downloaded, checked and waiting in staging for the swap.
public struct StagedInstall: Sendable {
    public var request: InstallRequest
    /// `~/.udeck/staging/<random>/`.
    public var directory: URL
    /// `~/.udeck/staging/<random>/<id>/`, named after the id so discovery
    /// checks it exactly as it checks `~/.udeck/plugins/<id>/`.
    public var folder: URL
    /// What the check every folder gets made of it. A problem that does not
    /// stop a plugin running travels with it.
    public var plugin: DiscoveredPlugin
}

/// What a crash left in staging, and what was done about it at launch.
public enum RecoveredOperation: Equatable, Sendable {
    /// The swap had happened and the record had not: the record is written.
    case recordWritten(id: String)
    /// The swap never happened: nothing needed undoing.
    case neverSwapped(id: String)
    /// The folder had gone: the rest of the removal is to be finished — the
    /// record and the cache are, and the caller forgets the rest.
    case removalFinished(id: String)
    /// The folder was still there: the removal never started.
    case removalNeverStarted(id: String)
    /// A staging folder with no journal: nothing of the operator's was in it yet.
    case discarded(directory: String)
    /// Something could not be finished — `installed.json` would not parse, or
    /// an old copy could not be put back or moved to the Trash — so staging
    /// and its journal are left as they are for a later launch.
    case leftForLater(id: String, reason: String)
}

/// Installs, updates and removes plugins from a repository, one folder at a
/// time and never half-way.
///
/// 1. The listing is checked against rules 1–8 — no request needed.
/// 2. A staging folder is opened with `intent.json` in it.
/// 3. The plugin's files, and only those, are downloaded from the raw host at
///    the commit, four at a time; each is hashed as it arrives and must match
///    its blob id; each is written with the permissions its mode says.
/// 4. The staged folder is hashed as git would and compared with the listed
///    tree: that proves the set of files is complete and nothing extra is there.
/// 5. `PluginDiscovery.load` checks it — the same function the folder scan
///    calls — and it must come back usable, at the version the catalogue showed.
/// 6. (The caller quiets the plugin.)
/// 7. The folder is swapped into place in one step.
/// 8. The record is written.
/// 9. The old copy is deleted — or moved to the Trash when it was the
///    operator's own or had been changed.
/// 10. Staging is removed. (The caller re-reads the folder and resumes polling.)
public struct PluginInstaller: Sendable {
    public let paths: UDeckPaths
    public let discovery: PluginDiscovery
    public let trash: any PluginTrash
    public let renames: FolderRenames
    private let fetch: @Sendable (_ path: String, _ commit: String) async throws -> Data
    private let now: @Sendable () -> Date

    /// Four files at a time, each retried twice, the whole install at most five
    /// minutes.
    public static let width = 4
    public static let attempts = 3
    public var deadline: TimeInterval = 300

    public init(
        paths: UDeckPaths,
        discovery: PluginDiscovery,
        trash: any PluginTrash = SystemTrash(),
        renames: FolderRenames = .system,
        fetch: @escaping @Sendable (String, String) async throws -> Data,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.paths = paths
        self.discovery = discovery
        self.trash = trash
        self.renames = renames
        self.fetch = fetch
        self.now = now
    }

    private var fileManager: FileManager { .default }
    private var records: JSONFileStore<InstalledPlugins> { .init(url: paths.installedFile) }

    /// The records, or the reason nothing may be written over them.
    public func loadRecords() throws -> InstalledPlugins {
        do {
            return try records.load() ?? InstalledPlugins()
        } catch {
            throw InstallError.recordsBroken("\(error)")
        }
    }

    // MARK: - Steps 1–5

    /// Downloads, checks and stages a plugin. Nothing under `plugins/` changes,
    /// and anything that fails deletes the staging folder.
    ///
    /// `manifest` is the manifest's bytes when the caller already has them from
    /// the catalogue; with them, every rule the catalogue row checks is checked
    /// again before a single file is requested.
    public func stage(_ request: InstallRequest, manifest: Data? = nil) async throws -> StagedInstall {
        _ = try loadRecords()
        let id = request.id.rawValue
        var before = RepositoryRules.listingRefusals(folder: id, listing: request.folder)
        if let manifest {
            before = RepositoryRules.check(folder: id, listing: request.folder, manifest: manifest,
                                           udeck: discovery.udeckVersion).refusals
        }
        guard before.isEmpty else { throw InstallError.refused(before) }

        let directory = paths.staging.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let folder = directory.appendingPathComponent(id, isDirectory: true)
        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            try write(InstallIntent(operation: InstallIntent.Operation(rawValue: request.operation.rawValue)!,
                                    id: id, record: nil, oldCopyIsOperators: false), in: directory)
        } catch {
            try? fileManager.removeItem(at: directory)
            throw InstallError.cannotWrite("\(error)")
        }

        do {
            try await withDeadline(deadline) { try await download(request, into: folder) }
            try checkStaged(request, folder: folder)
            let plugin = discovery.load(folder)
            guard plugin.isUsable, let manifest = plugin.manifest else {
                let detail = plugin.problems.first(where: \.isFatal)?.description ?? "it is not usable"
                throw InstallError.refused([.failsTheUsualChecks(id: id, detail: detail)])
            }
            let after = RepositoryRules.manifestRefusals(manifest, folder: id, listing: request.folder,
                                                         udeck: discovery.udeckVersion)
            guard after.isEmpty else { throw InstallError.refused(after) }
            guard manifest.version == request.version else {
                throw InstallError.refused([.notTheVersionShown(id: id, shown: request.version,
                                                                arrived: manifest.version)])
            }
            return StagedInstall(request: request, directory: directory, folder: folder, plugin: plugin)
        } catch {
            try? fileManager.removeItem(at: directory)
            throw error
        }
    }

    /// Gives up on a staged install: its staging folder goes, and nothing else
    /// changes.
    public func abandon(_ staged: StagedInstall) {
        try? fileManager.removeItem(at: staged.directory)
    }

    private func download(_ request: InstallRequest, into folder: URL) async throws {
        let files = request.folder.files
        let base = "\(CommitListing.pluginsFolder)/\(request.id.rawValue)"
        try await withThrowingTaskGroup(of: Void.self) { group in
            var next = 0
            func add() {
                let entry = files[next]
                next += 1
                group.addTask {
                    let data = try await fetchWithRetries("\(base)/\(entry.path)", commit: request.commit)
                    try place(data, as: entry, in: folder, base: base)
                }
            }
            while next < min(Self.width, files.count) { add() }
            while try await group.next() != nil {
                if next < files.count { add() }
            }
        }
    }

    private func fetchWithRetries(_ path: String, commit: String) async throws -> Data {
        var last = ""
        for attempt in 1...Self.attempts {
            try Task.checkCancellation()
            do {
                return try await fetch(path, commit)
            } catch ProviderError.rawRateLimited(let until) {
                throw InstallError.rawRateLimited(until: until)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                last = (error as? ProviderError).map(Self.describe) ?? "\(error)"
                if attempt < Self.attempts { try? await Task.sleep(nanoseconds: 300_000_000 * UInt64(attempt)) }
            }
        }
        throw InstallError.unreachable(path: path, reason: last)
    }

    private func place(_ data: Data, as entry: ListedEntry, in folder: URL, base: String) throws {
        let path = "\(base)/\(entry.path)"
        let got = GitHash.blob(data)
        guard got == entry.sha else {
            throw InstallError.refused([.arrivedDifferent(path: path, expected: String(entry.sha.prefix(7)),
                                                          got: String(got.prefix(7)))])
        }
        if let size = entry.size, data.count > size {
            throw InstallError.refused([.arrivedLarger(path: path, bytes: data.count)])
        }
        // The pointer hashes to exactly the blob the listing names — it *is*
        // that blob — so this is checked after the hash, not instead of it.
        if RepositoryRules.isLFSPointer(data) {
            throw InstallError.refused([.lfsPointer(path: path)])
        }
        guard let relative = RepositoryRules.relativePath(entry.path), relative == entry.path else {
            throw InstallError.refused([.nameNotAllowed(path: path)])
        }
        let target = folder.appendingPathComponent(relative)
        do {
            try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o755])
            try data.write(to: target, options: .withoutOverwriting)
            try fileManager.setAttributes([.posixPermissions: entry.kind == .executable ? 0o755 : 0o644],
                                          ofItemAtPath: target.path)
        } catch {
            throw InstallError.cannotWrite("\(target.path): \(error.localizedDescription)")
        }
    }

    /// Step 4: the staged folder, hashed as git would, has to be the listed
    /// tree — the files are each right, and they are all of them.
    private func checkStaged(_ request: InstallRequest, folder: URL) throws {
        let tree = try? GitHash.tree(ofDirectoryAt: folder)
        guard tree == request.folder.tree else {
            throw InstallError.refused([.folderDoesNotAddUp(id: request.id.rawValue)])
        }
    }

    // MARK: - Steps 6–10

    /// Step 6, then the rest: `quiet` is the caller quieting the plugin, and
    /// answers whether nothing of it is running any more. Only then is the
    /// staged plugin put in place; when something of it would not end, the
    /// folder is left exactly as it was and the staged copy goes. uDeck never
    /// swaps a folder under a live process.
    @discardableResult
    public func commit(_ staged: StagedInstall, once quiet: @Sendable () async -> Bool) async throws -> InstalledRecord {
        guard await quiet() else {
            abandon(staged)
            throw InstallError.stillRunning(id: staged.request.id.rawValue)
        }
        return try commit(staged)
    }

    /// Puts a staged plugin in place and records it. The caller has quieted
    /// the plugin first, so nothing of it runs across the swap.
    @discardableResult
    public func commit(_ staged: StagedInstall) throws -> InstalledRecord {
        var records = try loadRecords()
        let request = staged.request
        let id = request.id.rawValue
        let live = paths.plugins.appendingPathComponent(id, isDirectory: true)
        let existing = records.plugins[id]
        let liveExists = folderIsTaken(id)
        let operators = OperatorsWork.goesToTrash(id, in: paths, record: existing)

        let record = makeRecord(request, existing: existing)
        do {
            try write(InstallIntent(operation: InstallIntent.Operation(rawValue: request.operation.rawValue)!,
                                    id: id, record: record, oldCopyIsOperators: operators),
                      in: staged.directory)
            try fileManager.createDirectory(at: paths.plugins, withIntermediateDirectories: true)
        } catch {
            abandon(staged)
            throw InstallError.cannotWrite("\(error)")
        }
        if liveExists {
            do {
                try spellExactly(id)
            } catch {
                abandon(staged)
                throw error
            }
        }

        let displaced = try swap(staged.folder, into: live, liveExists: liveExists, staging: staged.directory, id: id)

        records.plugins[id] = record
        do {
            try self.records.save(records)
        } catch {
            // The folder is in place and the record is not: exactly what the
            // journal is for. The staging folder stays, and the next launch
            // writes the record.
            throw InstallError.cannotWrite("\(error)")
        }
        dispose(displaced, operators: operators)
        try? fileManager.removeItem(at: staged.directory)
        return record
    }

    private func makeRecord(_ request: InstallRequest, existing: InstalledRecord?) -> InstalledRecord {
        let previous: PreviousCopy?
        let pinned: Bool
        switch request.operation {
        case .install, .replace:
            previous = existing?.asPrevious
            pinned = false
        case .update:
            previous = existing?.asPrevious
            pinned = false
        case .earlier:
            previous = existing?.asPrevious
            pinned = true
        case .reinstall:
            previous = existing?.previous
            pinned = existing?.pinned ?? false
        }
        let at = now()
        return InstalledRecord(
            source: request.source, repository: request.repository, ref: request.ref,
            commit: request.commit, tree: request.folder.tree, version: request.version,
            installedAt: at, pinned: pinned,
            verification: PluginVerification(
                status: request.source == InstalledPlugins.officialSource && request.ref.kind == "default"
                    ? .verified : .modified,
                by: request.source == InstalledPlugins.officialSource && request.ref.kind == "default"
                    ? InstalledPlugins.officialSource : nil,
                checkedAgainst: request.headCommit ?? request.commit, checkedAt: at),
            previous: previous
        )
    }

    /// Step 7. With a copy in place: exchanged in one step, so at no moment is
    /// there no `plugins/<id>`. Without one: moved in, failing rather than
    /// overwriting a folder that appeared meanwhile. On a volume that cannot
    /// exchange, two renames — and windows that are never dropped for a missing
    /// plugin make the gap harmless.
    ///
    /// Answers where the old copy went, if there was one.
    private func swap(_ staged: URL, into live: URL, liveExists: Bool, staging: URL, id: String) throws -> URL? {
        if !liveExists {
            let failed = renames.exclusive(staged, live)
            if failed == 0 { return nil }
            abandon(at: staging)
            if failed == EEXIST || failed == ENOTEMPTY {
                throw InstallError.refused([.folderAppeared(id: id)])
            }
            throw InstallError.cannotWrite("moving \(id) into place: \(String(cString: strerror(failed)))")
        }
        let failed = renames.exchange(staged, live)
        if failed == 0 { return staged }
        guard failed == ENOTSUP || failed == EINVAL || failed == EXDEV || failed == ENOSYS else {
            abandon(at: staging)
            throw InstallError.cannotWrite("swapping \(id) into place: \(String(cString: strerror(failed)))")
        }
        let displaced = staging.appendingPathComponent("displaced", isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
        do {
            try fileManager.createDirectory(at: displaced.deletingLastPathComponent(), withIntermediateDirectories: true)
            try renames.move(live, displaced)
        } catch {
            abandon(at: staging)
            throw InstallError.cannotWrite("moving the old \(id) aside: \(error.localizedDescription)")
        }
        do {
            try renames.move(staged, live)
        } catch {
            // Put the old copy back rather than leave nothing at all.
            do {
                try renames.move(displaced, live)
            } catch {
                // The old copy is still in staging, beside the journal, and
                // may be the operator's only one: staging stays as it is, and
                // the next launch puts it back (`recover`). Throwing the
                // staging folder away here would delete it.
                throw InstallError.cannotWrite(
                    "moving \(id) into place, and then back: \(error.localizedDescription); the old copy is kept in "
                    + "\(displaced.path) and goes back at the next launch")
            }
            abandon(at: staging)
            throw InstallError.cannotWrite("moving \(id) into place: \(error.localizedDescription)")
        }
        return displaced
    }

    /// On a volume that ignores case — which is how a Mac ships —
    /// `plugins/Uptime` is where the swap for `uptime` lands. The swap
    /// exchanges what the two names hold and keeps the names, so the new copy
    /// would sit under `Uptime`, and discovery holds a folder's name to its
    /// plugin's id exactly: the install would put in place a plugin that does
    /// not run, and **Reinstall** would do it again. So a folder spelt otherwise
    /// is first renamed to the id, in place, and the swap then lands on the
    /// exact name.
    private func spellExactly(_ id: String) throws {
        let names = (try? fileManager.contentsOfDirectory(atPath: paths.plugins.path)) ?? []
        guard !names.contains(id),
              let spelt = names.first(where: { $0.lowercased() == id.lowercased() }) else { return }
        let from = paths.plugins.appendingPathComponent(spelt, isDirectory: true)
        let to = paths.plugins.appendingPathComponent(id, isDirectory: true)
        guard rename(from.path, to.path) == 0 else {
            throw InstallError.cannotWrite("renaming \(spelt) to \(id): \(String(cString: strerror(errno)))")
        }
    }

    private func abandon(at staging: URL) {
        try? fileManager.removeItem(at: staging)
    }

    /// Step 9: the copy that lost. Deleted — or to the Trash when it was the
    /// operator's: uDeck never destroys something it did not put there.
    private func dispose(_ old: URL?, operators: Bool) {
        guard let old, fileManager.fileExists(atPath: old.path) else { return }
        if operators {
            do {
                try trash.discard(old)
                return
            } catch {
                // A Trash that will not take it: keep it rather than delete
                // what is not uDeck's, where the operator can find it.
                let kept = paths.root.appendingPathComponent("replaced-\(old.lastPathComponent)-\(Int(now().timeIntervalSince1970))")
                try? fileManager.moveItem(at: old, to: kept)
                return
            }
        }
        try? fileManager.removeItem(at: old)
    }

    // MARK: - Removal

    /// A removal under way: the folder is out of `plugins/`, and the rest is
    /// still to go.
    public struct Removal: Sendable {
        public var id: PluginIdentifier
        public var directory: URL
        public var oldCopyIsOperators: Bool
    }

    /// Starts removing a plugin once `quiet` says nothing of it is running:
    /// the journal, then its folder moved into staging in one rename, so it is
    /// gone from the plugins folder at once. When something of it would not
    /// end, nothing is touched. The caller forgets its grants, settings,
    /// windows and card before calling `finishRemoval`.
    public func beginRemoval(_ id: PluginIdentifier, once quiet: @Sendable () async -> Bool) async throws -> Removal {
        guard await quiet() else { throw InstallError.stillRunning(id: id.rawValue) }
        return try beginRemoval(id)
    }

    /// `beginRemoval(_:once:)` for a caller that has quieted the plugin itself.
    public func beginRemoval(_ id: PluginIdentifier) throws -> Removal {
        let records = try loadRecords()
        let live = paths.plugins.appendingPathComponent(id.rawValue, isDirectory: true)
        let existing = records[id]
        let liveExists = folderIsTaken(id.rawValue)
        let operators = OperatorsWork.goesToTrash(id.rawValue, in: paths, record: existing)

        let directory = paths.staging.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try write(InstallIntent(operation: .remove, id: id.rawValue, record: nil, oldCopyIsOperators: operators),
                      in: directory)
            if liveExists {
                try fileManager.moveItem(at: live, to: directory.appendingPathComponent(id.rawValue, isDirectory: true))
            }
        } catch {
            try? fileManager.removeItem(at: directory)
            throw InstallError.cannotWrite("\(error)")
        }
        return Removal(id: id, directory: directory, oldCopyIsOperators: operators)
    }

    /// Finishes a removal: the record, the cache, the folder itself (deleted,
    /// or to the Trash when it was the operator's), and the staging folder.
    public func finishRemoval(_ removal: Removal) throws {
        try forgetRecordAndCache(removal.id.rawValue)
        dispose(removal.directory.appendingPathComponent(removal.id.rawValue, isDirectory: true),
                operators: removal.oldCopyIsOperators)
        try? fileManager.removeItem(at: removal.directory)
    }

    private func forgetRecordAndCache(_ id: String) throws {
        var records = try loadRecords()
        if records.plugins.removeValue(forKey: id) != nil {
            do { try self.records.save(records) } catch { throw InstallError.cannotWrite("\(error)") }
        }
        if let identifier = PluginIdentifier(rawValue: id) {
            try? fileManager.removeItem(at: paths.cache(forPlugin: identifier))
        }
    }

    // MARK: - Recovering from a crash halfway

    /// Looks in `~/.udeck/staging/` at launch, before the plugins folder is
    /// first read, and finishes or undoes what a crash interrupted.
    ///
    /// * An install, update or earlier version — if `plugins/<id>` now hashes to
    ///   the tree in the intent, the swap happened and the record did not: the
    ///   record is written. Otherwise the swap never happened. Either way the
    ///   staging folder goes — its contents are the copy that lost: deleted, or
    ///   to the Trash if the intent says it was the operator's.
    /// * A removal — if `plugins/<id>` is gone, the rest of the removal is
    ///   finished; if it is still there, the removal never started.
    public func recover() -> [RecoveredOperation] {
        let entries = (try? fileManager.contentsOfDirectory(
            at: paths.staging, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        var done: [RecoveredOperation] = []
        for directory in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let intentURL = directory.appendingPathComponent(InstallIntent.filename)
            guard let data = try? Data(contentsOf: intentURL),
                  let intent = try? JSONDecoder.iso8601.decode(InstallIntent.self, from: data),
                  PluginIdentifier(rawValue: intent.id) != nil else {
                // No journal: the operation died before it wrote one, when
                // nothing of the operator's had been moved in yet.
                try? fileManager.removeItem(at: directory)
                done.append(.discarded(directory: directory.lastPathComponent))
                continue
            }
            done.append(recover(intent, in: directory))
        }
        return done
    }

    private func recover(_ intent: InstallIntent, in directory: URL) -> RecoveredOperation {
        let id = intent.id
        let live = paths.plugins.appendingPathComponent(id, isDirectory: true)
        let inStaging = directory.appendingPathComponent(id, isDirectory: true)
        let displaced = directory.appendingPathComponent("displaced", isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
        let liveExists = fileManager.fileExists(atPath: live.path)

        if intent.operation == .remove {
            guard !liveExists else {
                try? fileManager.removeItem(at: directory)
                return .removalNeverStarted(id: id)
            }
            do {
                try forgetRecordAndCache(id)
            } catch {
                return .leftForLater(id: id, reason: "\(error)")
            }
            dispose(inStaging, operators: intent.oldCopyIsOperators)
            try? fileManager.removeItem(at: directory)
            return .removalFinished(id: id)
        }

        let tree = liveExists ? (try? GitHash.tree(ofDirectoryAt: live)) ?? nil : nil
        if let record = intent.record, tree == record.tree {
            do {
                var records = try loadRecords()
                if records.plugins[id] != record {
                    records.plugins[id] = record
                    try self.records.save(records)
                }
            } catch {
                return .leftForLater(id: id, reason: "\(error)")
            }
            dispose(inStaging, operators: intent.oldCopyIsOperators)
            dispose(displaced, operators: intent.oldCopyIsOperators)
            try? fileManager.removeItem(at: directory)
            return .recordWritten(id: id)
        }

        // The folder is not the one the intent would record. Nothing in staging
        // is deleted unless it is known to be uDeck's own download.
        //
        // An old copy moved aside by the two-rename fallback goes back where it
        // was. If it cannot, staging and its journal stay as they are and the
        // next launch tries again; if something else is at `plugins/<id>` now,
        // the old copy goes to the Trash rather than over it. Either way it is
        // never deleted: it may be the operator's only copy.
        if fileManager.fileExists(atPath: displaced.path) {
            if !liveExists {
                do {
                    try fileManager.createDirectory(at: paths.plugins, withIntermediateDirectories: true)
                    try renames.move(displaced, live)
                } catch {
                    return .leftForLater(id: id, reason: "putting the old copy back: \(error.localizedDescription)")
                }
            } else {
                do {
                    try trash.discard(displaced)
                } catch {
                    return .leftForLater(id: id, reason: "moving the old copy to the Trash: \(error.localizedDescription)")
                }
            }
        }
        // What is under the id in staging is the new download when the swap
        // never happened: it hashes to the intended tree, and goes. After an
        // exchange whose record was never written, and a folder changed since,
        // it is the old copy instead — the copy that lost, disposed of as the
        // intent says, never simply deleted when it was the operator's.
        if let record = intent.record, fileManager.fileExists(atPath: inStaging.path),
           ((try? GitHash.tree(ofDirectoryAt: inStaging)) ?? nil) != record.tree {
            dispose(inStaging, operators: intent.oldCopyIsOperators)
        }
        try? fileManager.removeItem(at: directory)
        return .neverSwapped(id: id)
    }

    // MARK: - Pieces

    /// Whether something already sits at `plugins/<id>` — asked of the disk,
    /// as the swap will find it, and not of a list of folders read earlier.
    ///
    /// On a volume that ignores case, which is how a Mac ships, `plugins/Uptime`
    /// is `plugins/uptime` to the rename that puts a plugin in place, whatever
    /// its spelling. A row that compared names exactly would offer **Install**
    /// over it without a word, and the swap would take it anyway.
    public func folderIsTaken(_ id: String) -> Bool {
        Self.folderIsTaken(id, in: paths)
    }

    public static func folderIsTaken(_ id: String, in paths: UDeckPaths) -> Bool {
        FileManager.default.fileExists(atPath: paths.plugins.appendingPathComponent(id, isDirectory: true).path)
    }

    private func write(_ intent: InstallIntent, in directory: URL) throws {
        let data = try JSONEncoder.iso8601.encode(intent)
        try data.write(to: directory.appendingPathComponent(InstallIntent.filename), options: .atomic)
    }

    private func withDeadline(_ seconds: TimeInterval, _ body: @escaping @Sendable () async throws -> Void) async throws {
        try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask { try await body(); return true }
            group.addTask {
                try await Task.sleep(nanoseconds: Seconds.nanoseconds(seconds))
                return false
            }
            let finished = try await group.next() ?? false
            group.cancelAll()
            if !finished { throw InstallError.tookTooLong }
        }
    }

    static func describe(_ error: ProviderError) -> String {
        switch error {
        case .rateLimited(let until), .rawRateLimited(let until): "limited until \(until)"
        case .notFound: "404 not found"
        case .refused(let status): "HTTP \(status)"
        case .unreachable(let reason): reason
        case .badAnswer(let reason): reason
        }
    }
}

extension JSONEncoder {
    static var iso8601: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// Whether replacing or removing a plugin's folder sends something of the
/// operator's to the Trash.
///
/// One rule, and two readers: the installer decides by it whether the copy
/// that loses goes to the Trash or is deleted, and every button that replaces
/// or removes a folder — **Update**, **Switch to**, **Back to**, **Earlier
/// versions…**, **Reinstall**, **Remove** — decides by it whether to say so
/// first. A warning decided by anything else would be silent exactly when the
/// two disagree, which is when it is needed.
public enum OperatorsWork {
    /// Whether a folder holds anything of the operator's: there is no record
    /// of uDeck putting it there, it no longer hashes to what was put there
    /// (`treeOnDisk`), or it holds something the hash does not see — a
    /// `.env`, a `.git` (`unhashed`) — which the hash matching says nothing
    /// about.
    public static func isAtStake(record: InstalledRecord?, treeOnDisk: String?, unhashed: [String]) -> Bool {
        guard let record else { return true }
        return treeOnDisk != record.tree || !unhashed.isEmpty
    }

    /// The same, of the folder at `folder` as it is on disk now.
    public static func isAtStake(in folder: URL, record: InstalledRecord?) -> Bool {
        isAtStake(record: record, treeOnDisk: (try? GitHash.tree(ofDirectoryAt: folder)) ?? nil,
                  unhashed: GitHash.unhashed(inDirectoryAt: folder))
    }

    /// Whether replacing or removing `plugins/<id>` now would send something
    /// of the operator's to the Trash: there is a folder there, asked as the
    /// swap will find it, and it holds something of theirs.
    public static func goesToTrash(_ id: String, in paths: UDeckPaths, record: InstalledRecord?) -> Bool {
        guard PluginInstaller.folderIsTaken(id, in: paths) else { return false }
        return isAtStake(in: paths.plugins.appendingPathComponent(id, isDirectory: true), record: record)
    }
}
