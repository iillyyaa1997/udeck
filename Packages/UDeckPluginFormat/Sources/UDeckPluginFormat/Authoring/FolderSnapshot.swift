#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// What a folder holds, everything in it, hidden names included — taken before
/// a run and after it, to say whether the run wrote into its own folder.
///
/// A producer runs in its own folder, and the contract asks it never to write
/// there (`UDECK_CACHE_DIR` is its own place to write). uDeck does not stop
/// one that does: an installed plugin is then **Modified locally** after every
/// run, which its author never sees on their own machine, where the folder is
/// theirs anyway. Files are compared by content and executable bit — what git
/// keeps, and so what makes a folder differ from its repository — not by the
/// time they were touched.
struct FolderSnapshot: Equatable {
    enum Entry: Equatable {
        case folder
        case file(blob: String, executable: Bool)
        /// Where it points, by its bytes too.
        case link([UInt8])
        case other
    }

    /// Paths below the folder, `a/b.txt`, and what each is — keyed by the
    /// path's bytes, not by the path as a Swift string: strings compare by
    /// what they mean, so a name spelt with `é` and one spelt with `e` and a
    /// combining accent would be one key, and on Linux they are two files.
    var entries: [[UInt8]: Entry]

    /// More than this many entries and the folder is not compared: a plugin
    /// folder is at most 200 files (rule 8).
    static let maximumEntries = 10_000

    /// The folder at `url`, or nil when it holds more than `maximumEntries`
    /// or cannot be read.
    static func of(_ url: URL) -> FolderSnapshot? {
        var entries: [[UInt8]: Entry] = [:]
        var pending = [""]
        let manager = FileManager.default
        while let relative = pending.popLast() {
            let folder = relative.isEmpty ? url.path : url.path + "/" + relative
            guard let names = try? manager.contentsOfDirectory(atPath: folder) else { return nil }
            for name in names {
                let path = relative.isEmpty ? name : relative + "/" + name
                let key = Array(path.utf8)
                let full = folder + "/" + name
                guard let attributes = try? manager.attributesOfItem(atPath: full) else { return nil }
                switch attributes[.type] as? FileAttributeType {
                case .typeDirectory?:
                    entries[key] = .folder
                    pending.append(path)
                case .typeRegular?:
                    guard let blob = try? GitHash.blob(ofFileAt: URL(fileURLWithPath: full)) else { return nil }
                    let mode = GitHash.integer(attributes[.posixPermissions]) ?? 0
                    entries[key] = .file(blob: blob, executable: mode & 0o111 != 0)
                case .typeSymbolicLink?:
                    entries[key] = .link(Array(((try? manager.destinationOfSymbolicLink(atPath: full)) ?? "").utf8))
                default:
                    entries[key] = .other
                }
                if entries.count > maximumEntries { return nil }
            }
        }
        return FolderSnapshot(entries: entries)
    }

    /// What is in `after` and not here, what is here and not in `after`, and
    /// what is in both and differs — each sorted by its bytes.
    func changes(to after: FolderSnapshot) -> (added: [String], removed: [String], changed: [String]) {
        func sorted(_ paths: [[UInt8]]) -> [String] {
            paths.sorted { $0.lexicographicallyPrecedes($1) }.map { String(decoding: $0, as: UTF8.self) }
        }
        let added = after.entries.keys.filter { entries[$0] == nil }
        let removed = entries.keys.filter { after.entries[$0] == nil }
        let changed = entries.keys.filter { path in after.entries[path].map { $0 != entries[path] } ?? false }
        return (sorted(Array(added)), sorted(Array(removed)), sorted(Array(changed)))
    }
}
