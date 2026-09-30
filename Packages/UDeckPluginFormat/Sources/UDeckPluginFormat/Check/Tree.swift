#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// One path of what is being checked, as `git ls-tree -r -t -l` gives it:
/// what GitHub's tree listing gives uDeck.
struct TreeEntry: Sendable {
    enum Kind: Sendable, Equatable {
        case blob
        case tree
        /// A submodule: a pointer to another repository's commit.
        case commit
        /// On disk only: neither a file, a folder nor a link — a socket, a
        /// device. Git has no word for one, and uDeck would install nothing.
        case other
    }

    /// Where, from the top of what is being checked.
    var path: String
    /// The same, as the bytes git stored — which need not be UTF-8.
    var rawPath: [UInt8]
    /// `100644`, `100755`, `040000`, `120000`, `160000`.
    var mode: String
    var kind: Kind
    /// The object id; empty for a folder read from disk.
    var id: String
    /// Bytes, for a file or a link; nil for anything else.
    var size: Int?

    var name: String { String(path.split(separator: "/", omittingEmptySubsequences: false).last ?? "") }
    var isFile: Bool { kind == .blob && (mode == Self.file || mode == Self.executable) }
    var isLink: Bool { mode == Self.link }
    var isSubmodule: Bool { mode == Self.submodule }

    static let file = "100644"
    static let executable = "100755"
    static let folder = "040000"
    static let link = "120000"
    static let submodule = "160000"
}

/// Everything a check reads: the paths at one commit of a repository, or of a
/// folder on disk, with their contents and attributes on request.
final class Tree {
    enum Source {
        case git(Git, commit: String)
        /// A folder on disk, and the path it has here.
        case disk(URL, as: String)
    }

    let source: Source
    /// Keyed by path.
    let entries: [String: TreeEntry]
    /// Every entry in the order of its path's bytes — Python's order, and git's.
    let ordered: [TreeEntry]
    private var contents: [String: [UInt8]] = [:]

    init(source: Source, entries: [TreeEntry]) {
        self.source = source
        self.ordered = entries.sorted { $0.rawPath.lexicographicallyPrecedes($1.rawPath) }
        self.entries = Dictionary(entries.map { ($0.path, $0) }) { first, _ in first }
    }

    /// The commit read, or nil for a folder on disk.
    var commit: String? {
        if case .git(_, let commit) = source { commit } else { nil }
    }

    /// What is directly inside `folder` ("" for the top).
    func children(of folder: String) -> [TreeEntry] {
        let prefix = folder.isEmpty ? "" : folder + "/"
        return ordered.filter { $0.path.hasPrefix(prefix) && !$0.path.dropFirst(prefix.count).contains("/") && $0.path != folder }
    }

    /// Everything inside `folder`, at any depth.
    func under(_ folder: String) -> [TreeEntry] {
        ordered.filter { $0.path.hasPrefix(folder + "/") }
    }

    /// Reads the contents of these files, once each.
    func load(_ wanted: [TreeEntry]) throws {
        let missing = wanted.filter { $0.kind == .blob && contents[$0.path] == nil }
        guard !missing.isEmpty else { return }
        switch source {
        case .git(let git, _):
            let blobs = try git.blobs(missing.map(\.id))
            for entry in missing {
                guard let bytes = blobs[entry.id] else { throw CheckFailure("git could not read blob \(entry.id)") }
                contents[entry.path] = bytes
            }
        case .disk(let folder, let name):
            for entry in missing {
                let url = folder.appendingPathComponent(String(entry.path.dropFirst(name.count + 1)))
                if entry.isLink {
                    // What git stores for a link: the path it points to.
                    contents[entry.path] = Array((try FileManager.default.destinationOfSymbolicLink(atPath: url.path)).utf8)
                } else {
                    contents[entry.path] = Array(try Data(contentsOf: url))
                }
            }
        }
    }

    /// The bytes `load` read, or nil for a file it did not read.
    func content(_ entry: TreeEntry) -> [UInt8]? { contents[entry.path] }

    /// What `.gitattributes` sets, of `attributes`, for these entries — a
    /// folder asked about with a trailing slash. Nothing on disk, where there
    /// is no commit whose attributes an archive would apply.
    func attributes(_ attributes: [String], of wanted: [TreeEntry]) throws -> [String: [String: String]] {
        guard case .git(let git, let commit) = source else { return [:] }
        let asked = wanted.map { $0.kind == .tree ? $0.rawPath + [UInt8(ascii: "/")] : $0.rawPath }
        let answers = try git.attributes(attributes, at: commit, of: asked)
        var found: [String: [String: String]] = [:]
        for (entry, raw) in zip(wanted, asked) {
            if let set = answers[raw] { found[entry.path] = set }
        }
        return found
    }
}

extension Tree {
    /// The repository at `revision`.
    static func commit(_ revision: String, of git: Git) throws -> Tree {
        let commit = try git.commit(revision)
        return Tree(source: .git(git, commit: commit), entries: try git.listing(commit))
    }

    /// A folder on disk, as git would list it if it were committed: a file is
    /// `100755` when its owner may execute it, `100644` otherwise; a link is a
    /// link and is not followed. Its paths start with `name`, and so do the
    /// findings.
    static func disk(_ folder: URL, as name: String) throws -> Tree {
        var entries = [TreeEntry(path: name, rawPath: Array(name.utf8), mode: TreeEntry.folder, kind: .tree, id: "")]
        func walk(_ url: URL, _ path: String) throws {
            // The Finder writes .DS_Store into any folder somebody opens, and
            // it holds nothing of anybody's; git ignores it in most working
            // copies, and uDeck when it hashes a folder. Any other dot-name is
            // reported (rule 7).
            for child in try FileManager.default.contentsOfDirectory(atPath: url.path).sorted() where child != ".DS_Store" {
                let childURL = url.appendingPathComponent(child)
                let childPath = "\(path)/\(child)"
                let attributes = try FileManager.default.attributesOfItem(atPath: childURL.path)
                let size = GitHash.integer(attributes[.size])
                func add(_ mode: String, _ kind: TreeEntry.Kind, size: Int?) {
                    entries.append(TreeEntry(path: childPath, rawPath: Array(childPath.utf8), mode: mode, kind: kind,
                                             id: "", size: size))
                }
                switch attributes[.type] as? FileAttributeType {
                case .typeDirectory?:
                    add(TreeEntry.folder, .tree, size: nil)
                    try walk(childURL, childPath)
                case .typeRegular?:
                    let permissions = GitHash.integer(attributes[.posixPermissions]) ?? 0
                    add(permissions & 0o100 != 0 ? TreeEntry.executable : TreeEntry.file, .blob, size: size)
                case .typeSymbolicLink?:
                    let target = (try? FileManager.default.destinationOfSymbolicLink(atPath: childURL.path)) ?? ""
                    add(TreeEntry.link, .blob, size: target.utf8.count)
                default:
                    add("0", .other, size: nil)
                }
            }
        }
        try walk(folder, name)
        return Tree(source: .disk(folder, as: name), entries: entries)
    }
}
