#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// A folder of the command's own, for the three things that need one: the
/// index `Git.attributes` reads a commit's attributes through, the uDeck folder
/// `udeck-plugin run` hands a plugin when it is given none, and the file curl
/// writes a release's asset to for `udeck-plugin pin`. It sits in
/// `udeck-plugin-<uid>` in the temporary folder — one of the command's own, so
/// that taking away what stopped runs left reads that folder and not the
/// whole temporary folder, which on a busy machine holds tens of thousands of
/// entries; one per user, since on Linux the temporary folder is shared.
///
/// It is taken away when the command is done with it — and not when the
/// command is stopped first, by a signal or a CI job's timeout. So its name
/// says whose it is, `udeck-plugin-index-<pid>-<uuid>`,
/// `udeck-plugin-run-<pid>-<uuid>` or `udeck-plugin-pin-<pid>-<uuid>`, and `udeck-plugin` starts by taking away
/// what stopped runs left (`RepositoryCheck.sweepTemporaryFolder`): a folder of
/// such a name whose process is gone, that belongs to this user, and that
/// nothing has changed for an hour. A process with that number alive (or
/// another container's, which looks gone from here, at work on it this past
/// hour), and anybody else's folder, are left alone.
enum ScratchFolder {
    static let prefix = "udeck-plugin-index-"
    /// The uDeck folder of one `udeck-plugin run`.
    static let runPrefix = "udeck-plugin-run-"
    /// The folder of one file `udeck-plugin pin` fetches.
    static let pinPrefix = "udeck-plugin-pin-"
    static let prefixes = [prefix, runPrefix, pinPrefix]
    /// Seconds since a folder last changed before it counts as left behind.
    static let leftAfter: Double = 3600

    /// Where the check keeps its folders: `udeck-plugin-<uid>` in the
    /// temporary folder.
    static var home: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("udeck-plugin-\(getuid())", isDirectory: true)
    }

    /// A new folder in `parent`, its name starting with `prefix`.
    static func make(_ prefix: String = prefix, in parent: URL = home) throws -> URL {
        let folder = parent.appendingPathComponent("\(prefix)\(getpid())-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Takes away the folders in `parent` that stopped runs of the check left,
    /// if they belong to `owner`.
    static func sweep(_ parent: URL = home, now: Date = Date(), owner: Int = Int(getuid())) {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: parent.path) else { return }
        for name in names {
            guard let prefix = prefixes.first(where: { name.utf8.starts(with: $0.utf8) }) else { continue }
            let rest = String(decoding: name.utf8.dropFirst(prefix.utf8.count), as: UTF8.self)
            guard let dash = rest.firstIndex(of: "-"), let pid = Int32(rest[..<dash]),
                  UUID(uuidString: String(rest[rest.index(after: dash)...])) != nil else { continue }
            // Gone — not merely another user's to ask about (EPERM). Number 0
            // is this process's own group, never gone.
            guard kill(pid, 0) != 0, errno == ESRCH else { continue }
            let path = parent.appendingPathComponent(name).path
            guard let attributes = try? manager.attributesOfItem(atPath: path),
                  attributes[.type] as? FileAttributeType == .typeDirectory,
                  GitHash.integer(attributes[.ownerAccountID]) == owner,
                  let changed = attributes[.modificationDate] as? Date,
                  now.timeIntervalSince(changed) > leftAfter else { continue }
            try? manager.removeItem(atPath: path)
        }
    }
}
