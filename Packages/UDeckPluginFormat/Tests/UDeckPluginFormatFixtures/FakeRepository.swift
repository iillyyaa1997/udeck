import Foundation
import UDeckPluginFormat

/// A plugin repository held in memory: files by path, and everything a provider
/// would say about them — blob ids, tree ids, a listing, the files' bytes.
///
/// Its ids come from `GitHash`, which `GitHashTests` holds against vectors made
/// by git itself, so a listing built here is a listing git would have made.
public struct FakeRepository {
    public struct File {
        public var data: Data
        public var mode: String

        public init(_ text: String, executable: Bool = false) {
            data = Data(text.utf8)
            mode = executable ? "100755" : "100644"
        }

        public init(data: Data, mode: String) {
            self.data = data
            self.mode = mode
        }
    }

    /// Paths from the top of the repository.
    public var files: [String: File] = [:]
    public var commit = String(repeating: "c", count: 40)

    public init() {}

    public static let passport = #"{ "format": 1, "name": "uDeck plugins" }"#

    /// A good poll plugin, `uptime`-shaped.
    public static func manifest(id: String = "uptime", version: String = "1.0.0", api: Int = 1,
                         minUDeck: String? = nil, run: String = "./uptime.sh",
                         permissions: String = #"{ "exec": ["sysctl"] }"#) -> String {
        """
        { "id": "\(id)", "name": "\(id)", "version": "\(version)", "api": \(api), "kind": "poll",
          "run": ["\(run)"], "interval": 60, "timeout": 2, "permissions": \(permissions)\
        \(minUDeck.map { ", \"minUDeck\": \"\($0)\"" } ?? "") }
        """
    }

    public static func withUptime(version: String = "1.0.0") -> FakeRepository {
        var repository = FakeRepository()
        repository.files["udeck-plugins.json"] = File(passport)
        repository.addPlugin("uptime", version: version)
        return repository
    }

    public mutating func addPlugin(_ id: String, version: String = "1.0.0", manifest: String? = nil) {
        files["plugins/\(id)/manifest.json"] = File(manifest ?? Self.manifest(id: id, version: version))
        files["plugins/\(id)/uptime.sh"] = File("#!/bin/sh\necho '{\"rows\":[{\"text\":\"up \(version)\"}]}'\n",
                                               executable: true)
        files["plugins/\(id)/README.md"] = File("# \(id)\n")
    }

    // MARK: - What a provider says

    /// The tree id of the folder at `prefix` ("" for the root), or nil when
    /// nothing is in it.
    public func treeID(_ prefix: String) -> String? {
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
    public func recursiveTree(truncated: Bool = false) -> GitTree {
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
    public func folderTree(_ prefix: String) -> GitTree {
        let whole = recursiveTree().tree
        let base = prefix.isEmpty ? "" : prefix + "/"
        let entries = whole.filter { $0.path.hasPrefix(base) && !$0.path.dropFirst(base.count).contains("/") }
            .map { GitTree.Entry(path: String($0.path.dropFirst(base.count)), mode: $0.mode, type: $0.type,
                                 sha: $0.sha, size: $0.size) }
        return GitTree(sha: treeID(prefix) ?? "", tree: entries)
    }

    /// One folder, recursive, with paths relative to it.
    public func folderTreeRecursive(_ prefix: String) -> GitTree {
        let base = prefix + "/"
        let entries = recursiveTree().tree.filter { $0.path.hasPrefix(base) }
            .map { GitTree.Entry(path: String($0.path.dropFirst(base.count)), mode: $0.mode, type: $0.type,
                                 sha: $0.sha, size: $0.size) }
        return GitTree(sha: treeID(prefix) ?? "", tree: entries)
    }

    public var listing: CommitListing { CommitListing(commit: commit, recursive: recursiveTree()) }

    public func plugin(_ id: String) -> PluginListing { listing.plugins[id]! }

    /// The raw host: a file at a path.
    public func data(at path: String) -> Data? { files[path]?.data }
}
