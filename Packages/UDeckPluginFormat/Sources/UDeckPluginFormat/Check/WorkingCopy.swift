#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// Whether an author's working copy holds something other than the commit a
/// folder was checked at — asked without `git status`.
///
/// `git status` refreshes the index first, and a refresh hashes every file
/// whose timestamps moved through whatever clean filter the repository's
/// configuration names for it: a program of the repository's choosing, run by
/// the check. So the files are hashed here, as `git hash-object --no-filters`
/// would hash them, and compared with the commit; the index is read as it is
/// (`git ls-files`, which never refreshes it) for what was added to it; and
/// git is asked only which new files it would not ignore.
///
/// A file's executable bit counts only where git counts it: a repository
/// whose `core.fileMode` is false — git's answer for a file system that cannot
/// keep the bit — has git ignore it on disk, and so does this.
///
/// A working copy whose files git converts on the way out — line endings, a
/// smudge filter — reads as changed even when it is not: its bytes on disk are
/// not the committed ones. That costs a note, never a finding; the folder is
/// checked as committed either way.
enum WorkingCopy {
    /// Whether anything under `folder` differs from `tree`, which is the commit
    /// the working copy at `top` has checked out: a file changed or gone, one
    /// added to the index, or a new one git would not ignore. The Finder's
    /// `.DS_Store` does not count, as it does not when the folder is read from
    /// disk.
    static func differs(_ git: Git, top: URL, folder: String, from tree: Tree) throws -> Bool {
        var committed: [String: String] = [:]
        for entry in tree.under(folder) where entry.kind == .blob {
            committed[entry.path] = "\(entry.mode) \(entry.id)"
        }

        // The index as it stands: anything added to it and not committed yet.
        // A merge left halfway lists a path once for each side it has, and
        // the last stands for it; the files on disk say the rest.
        var indexed: [String: String] = [:]
        for record in try git.run(["ls-files", "--stage", "-z", "--", folder]).split(separator: 0) {
            guard let tab = record.firstIndex(of: 0x09) else { continue }
            let meta = String(decoding: record[..<tab], as: UTF8.self).split(separator: " ")
            guard meta.count == 3 else { throw CheckFailure("git ls-files gave a line it should not have") }
            // A submodule is a commit in the index and in the tree alike; only
            // files are compared.
            guard meta[0] != TreeEntry.submodule else { continue }
            indexed[String(decoding: record[record.index(after: tab)...], as: UTF8.self)] = "\(meta[0]) \(meta[1])"
        }
        guard indexed == committed else { return true }

        // Read from the repository's configuration, which starts nothing.
        let fileMode = try git.attempt(["config", "--bool", "--get", "core.fileMode"])
        let bitCounts = !(fileMode.status == 0 && Blank.trimmed(String(decoding: fileMode.output, as: UTF8.self)) == "false")

        // Each committed file on disk, hashed with no filter in between.
        let manager = FileManager.default
        for (path, committedAs) in committed {
            let url = top.appendingPathComponent(path)
            guard let attributes = try? manager.attributesOfItem(atPath: url.path) else { return true }
            let onDisk: String
            switch attributes[.type] as? FileAttributeType {
            case .typeSymbolicLink?:
                let target = try manager.destinationOfSymbolicLink(atPath: url.path)
                onDisk = "\(TreeEntry.link) \(GitHash.blob(Data(target.utf8)))"
            case .typeRegular?:
                let executable = (GitHash.integer(attributes[.posixPermissions]) ?? 0) & 0o100 != 0
                // Where the bit does not count, git keeps the mode it has.
                let mode = bitCounts ? (executable ? TreeEntry.executable : TreeEntry.file)
                    : String(committedAs.prefix { $0 != " " })
                onDisk = "\(mode) \(try GitHash.blob(ofFileAt: url))"
            default:
                return true
            }
            if onDisk != committedAs { return true }
        }

        // Files that are neither committed nor added, and not ignored.
        let untracked = try git.run(["ls-files", "--others", "--exclude-standard", "-z", "--", folder])
        return untracked.split(separator: 0).contains { path in
            path.split(separator: UInt8(ascii: "/")).last.map { Array($0) } != Array(".DS_Store".utf8)
        }
    }
}
