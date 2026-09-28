import Foundation
@testable import UDeckCore

/// A plugin repository held in memory: files by path, and everything a provider
/// would say about them — blob ids, tree ids, a listing, the files' bytes.
///
/// Its ids come from `GitHash`, which `GitHashTests` holds against vectors made
/// by git itself, so a listing built here is a listing git would have made.
struct FakeRepository {
    struct File {
        var data: Data
        var mode: String

        init(_ text: String, executable: Bool = false) {
            data = Data(text.utf8)
            mode = executable ? "100755" : "100644"
        }

        init(data: Data, mode: String) {
            self.data = data
            self.mode = mode
        }
    }

    /// Paths from the top of the repository.
    var files: [String: File] = [:]
    var commit = String(repeating: "c", count: 40)

    static let passport = #"{ "format": 1, "name": "uDeck plugins" }"#

    /// A good poll plugin, `uptime`-shaped.
    static func manifest(id: String = "uptime", version: String = "1.0.0", api: Int = 1,
                         minUDeck: String? = nil, run: String = "./uptime.sh",
                         permissions: String = #"{ "exec": ["sysctl"] }"#) -> String {
        """
        { "id": "\(id)", "name": "\(id)", "version": "\(version)", "api": \(api), "kind": "poll",
          "run": ["\(run)"], "interval": 60, "timeout": 2, "permissions": \(permissions)\
        \(minUDeck.map { ", \"minUDeck\": \"\($0)\"" } ?? "") }
        """
    }

    static func withUptime(version: String = "1.0.0") -> FakeRepository {
        var repository = FakeRepository()
        repository.files["udeck-plugins.json"] = File(passport)
        repository.addPlugin("uptime", version: version)
        return repository
    }

    mutating func addPlugin(_ id: String, version: String = "1.0.0", manifest: String? = nil) {
        files["plugins/\(id)/manifest.json"] = File(manifest ?? Self.manifest(id: id, version: version))
        files["plugins/\(id)/uptime.sh"] = File("#!/bin/sh\necho '{\"rows\":[{\"text\":\"up \(version)\"}]}'\n",
                                               executable: true)
        files["plugins/\(id)/README.md"] = File("# \(id)\n")
    }

    // MARK: - What a provider says

    /// The tree id of the folder at `prefix` ("" for the root), or nil when
    /// nothing is in it.
    func treeID(_ prefix: String) -> String? {
        let base = prefix.isEmpty ? "" : prefix + "/"
        var children: [String: GitHash.Entry] = [:]
        var folders = Set<String>()
        for (path, file) in files where path.hasPrefix(base) {
            let rest = String(path.dropFirst(base.count))
            let parts = rest.split(separator: "/", maxSplits: 1).map(String.init)
            if parts.count == 1 {
                let kind: GitHash.Entry.Kind = file.mode == "100755" ? .executable : .file
                // Links and submodules are listed but never hashed by uDeck;
                // the fake gives them a blob id so a tree can still be made.
                children[parts[0]] = GitHash.Entry(name: parts[0], kind: kind, sha: GitHash.blob(file.data))
            } else {
                folders.insert(parts[0])
            }
        }
        for folder in folders {
            if let sha = treeID(base + folder) {
                children[folder] = GitHash.Entry(name: folder, kind: .folder, sha: sha)
            }
        }
        return GitHash.tree(Array(children.values))
    }

    /// The whole repository as `git/trees/<commit>?recursive=1` lists it.
    func recursiveTree(truncated: Bool = false) -> GitTree {
        var entries: [GitTree.Entry] = []
        var folders = Set<String>()
        for (path, file) in files {
            let parts = path.split(separator: "/").map(String.init)
            for depth in 1 ..< parts.count { folders.insert(parts[0 ..< depth].joined(separator: "/")) }
            entries.append(GitTree.Entry(path: path, mode: file.mode,
                                         type: file.mode == "160000" ? "commit" : "blob",
                                         sha: GitHash.blob(file.data), size: file.data.count))
        }
        for folder in folders {
            entries.append(GitTree.Entry(path: folder, mode: "040000", type: "tree", sha: treeID(folder) ?? ""))
        }
        return GitTree(sha: treeID("") ?? "", tree: entries.sorted { $0.path < $1.path }, truncated: truncated)
    }

    /// One folder, not recursive, as `git/trees/<tree>` lists it.
    func folderTree(_ prefix: String) -> GitTree {
        let whole = recursiveTree().tree
        let base = prefix.isEmpty ? "" : prefix + "/"
        let entries = whole.filter { $0.path.hasPrefix(base) && !$0.path.dropFirst(base.count).contains("/") }
            .map { GitTree.Entry(path: String($0.path.dropFirst(base.count)), mode: $0.mode, type: $0.type,
                                 sha: $0.sha, size: $0.size) }
        return GitTree(sha: treeID(prefix) ?? "", tree: entries)
    }

    /// One folder, recursive, with paths relative to it.
    func folderTreeRecursive(_ prefix: String) -> GitTree {
        let base = prefix + "/"
        let entries = recursiveTree().tree.filter { $0.path.hasPrefix(base) }
            .map { GitTree.Entry(path: String($0.path.dropFirst(base.count)), mode: $0.mode, type: $0.type,
                                 sha: $0.sha, size: $0.size) }
        return GitTree(sha: treeID(prefix) ?? "", tree: entries)
    }

    var listing: CommitListing { CommitListing(commit: commit, recursive: recursiveTree()) }

    func plugin(_ id: String) -> PluginListing { listing.plugins[id]! }

    /// The raw host: a file at a path.
    func data(at path: String) -> Data? { files[path]?.data }
}

/// Records what a fetch was asked for, and answers from a `FakeRepository`.
final class FetchLog: @unchecked Sendable {
    private let lock = NSLock()
    private var asked: [String] = []
    private var override: [String: Data] = [:]
    private var failing: Set<String> = []
    let repository: FakeRepository

    init(_ repository: FakeRepository) {
        self.repository = repository
    }

    var paths: [String] {
        lock.lock(); defer { lock.unlock() }
        return asked
    }

    /// Answer this path with other bytes.
    func alter(_ path: String, to data: Data) {
        lock.lock(); defer { lock.unlock() }
        override[path] = data
    }

    func fail(_ path: String) {
        lock.lock(); defer { lock.unlock() }
        failing.insert(path)
    }

    var fetch: @Sendable (String, String) async throws -> Data {
        { [self] path, _ in
            let (altered, fails) = lock.withLock { () -> (Data?, Bool) in
                asked.append(path)
                return (override[path], failing.contains(path))
            }
            if fails { throw ProviderError.unreachable("no route") }
            if let altered { return altered }
            guard let data = repository.data(at: path) else { throw ProviderError.notFound }
            return data
        }
    }
}

/// A Trash that keeps what it is given in a folder of the test's own.
final class TestTrash: PluginTrash, @unchecked Sendable {
    let folder: URL
    private let lock = NSLock()
    private var discarded: [String] = []

    init(in directory: URL) {
        folder = directory.appendingPathComponent("Trash", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    var names: [String] {
        lock.lock(); defer { lock.unlock() }
        return discarded
    }

    func discard(_ url: URL) throws {
        let target = folder.appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)")
        try FileManager.default.moveItem(at: url, to: target)
        lock.lock(); defer { lock.unlock() }
        discarded.append(url.lastPathComponent)
    }
}
