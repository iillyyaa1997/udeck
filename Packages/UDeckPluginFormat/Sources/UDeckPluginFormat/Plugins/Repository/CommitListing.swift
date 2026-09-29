#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// One path in a repository at one commit, as a provider lists it.
///
/// The fields GitHub's `git/trees` answer carries for every entry — the path,
/// the mode, the object id, and a size for a file — and nothing uDeck does not
/// use. GitLab's listing (stage 4) has the same four, less the size.
public struct ListedEntry: Codable, Equatable, Sendable {
    /// Relative to the folder it was listed in.
    public var path: String
    /// As the provider spells it: `100644`, `100755`, `040000`, `120000`, `160000`.
    public var mode: String
    /// The blob id of a file, the tree id of a folder, the commit of a submodule.
    public var sha: String
    /// Bytes, for a file. Absent for anything else.
    public var size: Int?

    public init(path: String, mode: String, sha: String, size: Int? = nil) {
        self.path = path
        self.mode = mode
        self.sha = sha
        self.size = size
    }

    public enum Kind: Sendable, Equatable {
        case file
        case executable
        case folder
        case link
        case submodule
        /// A mode git itself would not write; never installed.
        case other
    }

    /// What the mode says this is. A folder's mode arrives as `040000` from
    /// GitHub and as `40000` from git itself; both are a folder.
    public var kind: Kind {
        switch mode {
        case "100644", "100664": .file
        case "100755": .executable
        case "040000", "40000": .folder
        case "120000": .link
        case "160000": .submodule
        default: .other
        }
    }

    public var isFile: Bool { kind == .file || kind == .executable }

    /// The path's parts, for the rules about names and depth.
    public var components: [String] { path.split(separator: "/", omittingEmptySubsequences: false).map(String.init) }
}

/// One plugin's folder at one commit: its tree id and everything in it.
public struct PluginListing: Codable, Equatable, Sendable {
    /// The tree id of `plugins/<id>`. Equal to the last one seen means that not
    /// one byte of the plugin changed, whatever else was merged.
    public var tree: String
    /// Every file, folder, link and submodule in the folder, paths relative to it.
    public var entries: [ListedEntry]

    public init(tree: String, entries: [ListedEntry]) {
        self.tree = tree
        self.entries = entries
    }

    /// The files that would be installed.
    public var files: [ListedEntry] { entries.filter(\.isFile) }

    /// The file at `path`, when the listing has one there.
    public func file(at path: String) -> ListedEntry? {
        entries.first { $0.path == path && $0.isFile }
    }

    public var totalBytes: Int { files.reduce(0) { $0 + ($1.size ?? 0) } }
}

/// A repository at one commit, as uDeck keeps it: what a catalogue is made of.
///
/// Built from one listing of every path at that commit, and cached for good —
/// a commit never changes. Kept deliberately small: the passport's blob id,
/// and for each folder directly under `plugins/` its tree id and its entries.
/// Nothing else in the repository concerns uDeck, and nothing else is kept.
public struct CommitListing: Codable, Equatable, Sendable {
    public var commit: String
    /// The blob id of `udeck-plugins.json`, when there is one.
    public var passport: String?
    /// Keyed by folder name under `plugins/`.
    public var plugins: [String: PluginListing]
    /// Anything directly in `plugins/` that is not a folder. Ignored — rule 2
    /// is the repository check's to enforce — and kept so a person reading the
    /// cache can see what was.
    public var strays: [String]

    public init(commit: String, passport: String?, plugins: [String: PluginListing], strays: [String] = []) {
        self.commit = commit
        self.passport = passport
        self.plugins = plugins
        self.strays = strays
    }

    /// Folder names in the order a person reads them.
    public var pluginFolders: [String] { plugins.keys.sorted() }
}

/// GitHub's answer to `GET /repos/{o}/{r}/git/trees/{sha}`.
public struct GitTree: Decodable, Equatable, Sendable {
    public struct Entry: Decodable, Equatable, Sendable {
        public var path: String
        public var mode: String
        public var type: String
        public var sha: String
        public var size: Int?

        public init(path: String, mode: String, type: String, sha: String, size: Int? = nil) {
            self.path = path
            self.mode = mode
            self.type = type
            self.sha = sha
            self.size = size
        }
    }

    public var sha: String
    public var tree: [Entry]
    public var truncated: Bool

    public init(sha: String, tree: [Entry], truncated: Bool = false) {
        self.sha = sha
        self.tree = tree
        self.truncated = truncated
    }

    private enum CodingKeys: String, CodingKey { case sha, tree, truncated }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sha = try c.decode(String.self, forKey: .sha)
        tree = try c.decode([Entry].self, forKey: .tree)
        truncated = try c.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
    }
}

extension CommitListing {
    public static let pluginsFolder = "plugins"

    /// The listing of a commit from one recursive tree of the whole repository.
    public init(commit: String, recursive tree: GitTree) {
        var passport: String?
        var folderTrees: [String: String] = [:]
        var entries: [String: [ListedEntry]] = [:]
        var strays: [String] = []
        for entry in tree.tree {
            if entry.path == RepositoryPassport.path, entry.type == "blob" {
                passport = entry.sha
                continue
            }
            let parts = entry.path.split(separator: "/", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 2, parts[0] == Self.pluginsFolder else { continue }
            let folder = parts[1]
            if parts.count == 2 {
                if entry.type == "tree" { folderTrees[folder] = entry.sha } else { strays.append(folder) }
            } else {
                entries[folder, default: []].append(
                    ListedEntry(path: parts[2], mode: entry.mode, sha: entry.sha, size: entry.size)
                )
            }
        }
        var plugins: [String: PluginListing] = [:]
        for (folder, sha) in folderTrees {
            plugins[folder] = PluginListing(tree: sha, entries: entries[folder] ?? [])
        }
        self.init(commit: commit, passport: passport, plugins: plugins, strays: strays.sorted())
    }

    /// The listing of a commit put together from pieces, for a repository too
    /// large to list in one answer: the root, the `plugins` folder, and each
    /// plugin folder listed recursively on its own.
    public init(commit: String, root: GitTree, pluginsFolder: GitTree?, folders: [String: GitTree]) {
        let passport = root.tree.first { $0.path == RepositoryPassport.path && $0.type == "blob" }?.sha
        var plugins: [String: PluginListing] = [:]
        var strays: [String] = []
        for entry in pluginsFolder?.tree ?? [] {
            if entry.type == "tree" {
                let listed = folders[entry.path]?.tree.map {
                    ListedEntry(path: $0.path, mode: $0.mode, sha: $0.sha, size: $0.size)
                } ?? []
                plugins[entry.path] = PluginListing(tree: entry.sha, entries: listed)
            } else {
                strays.append(entry.path)
            }
        }
        self.init(commit: commit, passport: passport, plugins: plugins, strays: strays.sorted())
    }
}
