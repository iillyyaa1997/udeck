import Crypto
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

/// Git's two hashes, computed by uDeck.
///
/// uDeck identifies content the way git does, because that is what GitHub (and
/// later GitLab) report, and it computes the hashes itself: there is no git on
/// a stock Mac. Both are SHA-1.
///
/// * A file (blob): SHA-1 of `blob <size in decimal>\0` followed by the bytes.
/// * A folder (tree): SHA-1 of `tree <size in decimal>\0` followed by one entry
///   per child, sorted: `<mode> <name>\0<the child's 20-byte hash>`, the mode
///   with no leading zero (`100644`, `100755`, `40000`). Children are sorted by
///   their names' bytes, a folder compared as if its name ended in `/`. A folder
///   with nothing in it does not exist in git and is skipped.
///
/// The hash is not a signature. What makes content trustworthy is that the
/// listing came from the provider over TLS; what the hash adds is the certainty
/// that the files on disk are exactly the files that listing named, no more and
/// no fewer.
public enum GitHash {
    /// One child of a tree, as the tree hash needs it.
    public struct Entry: Sendable, Equatable {
        public enum Kind: Sendable, Equatable {
            case file
            case executable
            case folder

            /// The mode as git writes it inside a tree object — `40000`, never
            /// the `040000` the GitHub API spells.
            var mode: String {
                switch self {
                case .file: "100644"
                case .executable: "100755"
                case .folder: "40000"
                }
            }
        }

        public var name: String
        public var kind: Kind
        /// Forty lowercase hex characters.
        public var sha: String

        public init(name: String, kind: Kind, sha: String) {
            self.name = name
            self.kind = kind
            self.sha = sha
        }
    }

    /// The blob id of `data`.
    public static func blob(_ data: Data) -> String {
        var hasher = Insecure.SHA1()
        hasher.update(data: Data("blob \(data.count)\0".utf8))
        hasher.update(data: data)
        return hex(hasher.finalize())
    }

    /// The blob id of a file on disk, read in pieces so a large file is never
    /// held whole.
    ///
    /// Read with the system's own `open` and `read`, not `FileHandle`, which the
    /// Linux build does not have: the same bytes, a piece at a time.
    public static func blob(ofFileAt url: URL) throws -> String {
        let size = integer(try FileManager.default.attributesOfItem(atPath: url.path)[.size]) ?? 0
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { throw cannotRead(url) }
        defer { _ = close(descriptor) }
        var hasher = Insecure.SHA1()
        hasher.update(data: Data("blob \(size)\0".utf8))
        var buffer = [UInt8](repeating: 0, count: 1 << 16)
        var total = 0
        while true {
            let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
            if count < 0 {
                if errno == EINTR { continue }
                throw cannotRead(url)
            }
            if count == 0 { break }
            buffer.withUnsafeBytes { hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0.prefix(count))) }
            total += count
        }
        // A file that changed length while it was read would hash as a blob of
        // one size holding bytes of another, which matches nothing — but say
        // why rather than produce a number that looks like an answer.
        guard total == size else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [filePathKey: url.path])
        }
        return hex(hasher.finalize())
    }

    private static func cannotRead(_ url: URL) -> CocoaError {
        CocoaError(.fileReadUnknown, userInfo: [filePathKey: url.path])
    }

    /// `NSFilePathErrorKey`, which the Linux build has only by its value.
    private static var filePathKey: String {
        #if canImport(FoundationEssentials)
        return "NSFilePath"
        #else
        return NSFilePathErrorKey
        #endif
    }

    /// A number `attributesOfItem` handed back. An `NSNumber` on a Mac, a plain
    /// `UInt` where there is no `NSNumber`: asked as an `Int` alone, the second
    /// is not one, and every file would have seemed empty.
    static func integer(_ value: Any?) -> Int? {
        guard let value else { return nil }
        if let number = value as? Int { return number }
        // Any other integer, boxed however this Foundation boxes it, prints as
        // its digits — and one past `Int` does not read back as an `Int`.
        return Int("\(value)")
    }

    /// The tree id of these children, or nil when there are none — git has no
    /// empty folder, so an empty one is left out of its parent altogether.
    public static func tree(_ entries: [Entry]) -> String? {
        guard !entries.isEmpty else { return nil }
        var body = Data()
        for entry in entries.sorted(by: { sortKey($0).lexicographicallyPrecedes(sortKey($1)) }) {
            body.append(contentsOf: Array("\(entry.kind.mode) \(entry.name)".utf8))
            body.append(0)
            body.append(contentsOf: bytes(ofHex: entry.sha))
        }
        var hasher = Insecure.SHA1()
        hasher.update(data: Data("tree \(body.count)\0".utf8))
        hasher.update(data: body)
        return hex(hasher.finalize())
    }

    /// The tree id of a folder on disk, as git would record it.
    ///
    /// A file is `100755` when its owner's execute bit is set and `100644`
    /// otherwise. Names that start with `.` are skipped — `.DS_Store` appears the
    /// moment somebody opens a folder in Finder, and must not turn an installed
    /// plugin into a modified one; a repository's own rules keep dot-names out,
    /// so they can carry nothing. A symbolic link is skipped too: it is never
    /// installed, so it is never part of what was installed. Nil when there is
    /// nothing to hash at all.
    public static func tree(ofDirectoryAt url: URL) throws -> String? {
        let fileManager = FileManager.default
        let names = try fileManager.contentsOfDirectory(atPath: url.path)
        var entries: [Entry] = []
        for name in names where !name.hasPrefix(".") {
            let child = url.appendingPathComponent(name)
            let attributes = try fileManager.attributesOfItem(atPath: child.path)
            switch attributes[.type] as? FileAttributeType {
            case .typeDirectory:
                if let sha = try tree(ofDirectoryAt: child) {
                    entries.append(Entry(name: name, kind: .folder, sha: sha))
                }
            case .typeRegular:
                let permissions = integer(attributes[.posixPermissions]) ?? 0
                let kind: Entry.Kind = permissions & 0o100 != 0 ? .executable : .file
                entries.append(Entry(name: name, kind: kind, sha: try blob(ofFileAt: child)))
            default:
                // Links, sockets, anything else: never installed, never hashed.
                continue
            }
        }
        return tree(entries)
    }

    /// What in a folder on disk the tree id leaves out, as paths relative to it:
    /// dot-names at any depth (`.git`, `.env`, `.venv`) and anything that is
    /// neither a file nor a folder — the entries `tree(ofDirectoryAt:)` skips.
    ///
    /// The hash skipping them is what keeps `.DS_Store` from making a plugin
    /// modified, and the same skip would let a folder holding the operator's
    /// `.env` pass for exactly what uDeck installed. Whoever throws such a folder
    /// away asks this first: uDeck never destroys something it did not put
    /// there. `.DS_Store` itself is left out of the answer — the Finder writes
    /// it into any folder somebody opens, and it holds nothing of anybody's.
    public static func unhashed(inDirectoryAt url: URL) -> [String] {
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: url.path) else { return [] }
        var found: [String] = []
        for name in names.sorted() where name != ".DS_Store" {
            let child = url.appendingPathComponent(name)
            let type = (try? fileManager.attributesOfItem(atPath: child.path))?[.type] as? FileAttributeType
            if name.hasPrefix(".") || (type != .typeDirectory && type != .typeRegular) {
                found.append(name)
            } else if type == .typeDirectory {
                found += unhashed(inDirectoryAt: child).map { "\(name)/\($0)" }
            }
        }
        return found
    }

    /// Whether `text` is forty lowercase hexadecimal characters.
    public static func isObjectID(_ text: String) -> Bool {
        text.utf8.count == 40 && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    // MARK: - Pieces

    private static func sortKey(_ entry: Entry) -> [UInt8] {
        Array(entry.name.utf8) + (entry.kind == .folder ? [UInt8(ascii: "/")] : [])
    }

    private static func hex(_ digest: Insecure.SHA1Digest) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var text: [UInt8] = []
        text.reserveCapacity(40)
        for byte in digest {
            text.append(digits[Int(byte >> 4)])
            text.append(digits[Int(byte & 0x0F)])
        }
        return String(decoding: text, as: UTF8.self)
    }

    private static func bytes(ofHex hex: String) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(20)
        var iterator = hex.utf8.makeIterator()
        while let high = iterator.next(), let low = iterator.next() {
            out.append(nibble(high) << 4 | nibble(low))
        }
        return out
    }

    private static func nibble(_ byte: UInt8) -> UInt8 {
        switch byte {
        case 48...57: byte - 48
        case 97...102: byte - 87
        case 65...70: byte - 55
        default: 0
        }
    }
}
