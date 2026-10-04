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

/// Paths as the system resolves them, compared as bytes.
///
/// Bytes, not Swift strings: strings compare by what they mean, so `café`
/// spelt with `é` and with `e` and a combining accent are one string — and on
/// Linux they are two folders. A Mac's `realpath` answers the name a folder
/// has on disk, however it was asked for, so one folder resolves to the same
/// bytes.
public enum FilePaths {
    /// `path` as an absolute path with every link on the way resolved, or nil
    /// and the `errno` it failed with — `ENOENT` for nothing there, `ELOOP`
    /// for links that go round in a circle.
    public static func real(_ path: String) -> (path: String?, failed: Int32) {
        guard let resolved = realpath(path, nil) else { return (nil, errno) }
        defer { free(resolved) }
        return (String(cString: resolved), 0)
    }

    /// `path` resolved as far as it is there: the deepest folder of it that
    /// exists, every link on the way resolved, and the rest of it as written —
    /// where a folder not made yet will be, which is what has to be judged
    /// before it is made.
    public static func resolved(_ path: String) -> String {
        var head = path
        var rest: [String] = []
        while !head.isEmpty, head != "/" {
            if let real = real(head).path { return ([real] + rest.reversed()).joined(separator: "/") }
            let bytes = Array(head.utf8)
            guard let slash = bytes.lastIndex(of: UInt8(ascii: "/")) else { break }
            rest.append(String(decoding: bytes[(slash + 1)...], as: UTF8.self))
            head = slash == 0 ? "/" : String(decoding: bytes[..<slash], as: UTF8.self)
        }
        return path
    }

    /// Whether `path` is `folder` or anything inside it, both resolved.
    public static func contains(_ folder: String, _ path: String) -> Bool {
        let folder = Array(folder.utf8)
        let path = Array(path.utf8)
        if path == folder { return true }
        let prefix = folder.last == UInt8(ascii: "/") ? folder : folder + [UInt8(ascii: "/")]
        return path.starts(with: prefix)
    }
}
