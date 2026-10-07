#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// `.github/udeck-plugin.lock`: the one release of `udeck-plugin` a plugin
/// repository's CI runs — its version, the sha256 of each of its archives, and
/// the digest of its image.
///
/// The CI reads it from the base of the change it checks, as the official
/// repository reads its check today, so that a pull request cannot choose the
/// check that judges it: the file says *what* is run, byte for byte; where it
/// is downloaded from — GitHub, or a mirror for runners that cannot reach it —
/// is a variable of the CI's, which says only *where*. A mirror that hands out
/// other bytes makes the job red rather than running them.
///
/// Five lines, `key=value`, in one order, and nothing else:
///
///     version=0.6.0
///     macos-universal=<sha256 of udeck-plugin-0.6.0-macos-universal.tar.gz>
///     linux-x86_64=<sha256 of udeck-plugin-0.6.0-linux-x86_64.tar.gz>
///     linux-aarch64=<sha256 of udeck-plugin-0.6.0-linux-aarch64.tar.gz>
///     image=sha256:<digest of the image's index>
///
/// No JSON: a CI job reads it with `sed`, and never runs it through `source`.
/// No comment, no blank line, no space, no byte order mark, no carriage
/// return, every line ending in `\n`: a lock file is exactly what `udeck-plugin
/// pin` writes, so that the shell's reading — the five values, then the file
/// compared byte for byte with what they make (docs/plugin-repository.md) —
/// and this one cannot come to different answers. Anything else is refused,
/// and said why.
///
/// One place on GitHub and on GitLab alike: `.github/` means nothing to GitLab,
/// and a repository kept on both, or a template copied to either, holds one
/// file both CIs read, `pin` writes and a Renovate rule finds.
public struct PluginLock: Equatable, Sendable {
    /// Where it is, from the repository's root.
    public static let path = ".github/udeck-plugin.lock"

    /// The archives of a release, by the platform in their names
    /// (`udeck-plugin-<version>-<platform>.tar.gz`), in the order the file
    /// lists them.
    public static let platforms = ["macos-universal", "linux-x86_64", "linux-aarch64"]

    /// Every key, in the one order the file has them.
    public static let keys = ["version"] + platforms + ["image"]

    public var version: SemanticVersion
    /// The sha256 of each archive, 64 lowercase hexadecimal digits, by its
    /// platform.
    public var archives: [String: String]
    /// The image's digest — of the index, both platforms — as `sha256:<64
    /// lowercase hexadecimal digits>`.
    public var image: String

    public init(version: SemanticVersion, archives: [String: String], image: String) {
        self.version = version
        self.archives = archives
        self.image = image
    }

    /// The name of the archive for `platform` of `version`.
    public static func archive(_ platform: String, of version: SemanticVersion) -> String {
        "udeck-plugin-\(version)-\(platform).tar.gz"
    }

    /// The file, as `pin` writes it.
    public var text: String {
        var lines = ["version=\(version)"]
        for platform in Self.platforms { lines.append("\(platform)=\(archives[platform] ?? "")") }
        lines.append("image=\(image)")
        return lines.map { $0 + "\n" }.joined()
    }

    /// Why a file is not a lock file.
    public struct Problem: Error, Equatable, CustomStringConvertible {
        public var description: String
        init(_ description: String) { self.description = description }
    }

    /// Reads `bytes` as a lock file, or says why they are not one.
    public static func read(_ bytes: [UInt8]) throws -> PluginLock {
        let newline = UInt8(ascii: "\n")
        guard !bytes.isEmpty else { throw Problem("is empty") }
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            throw Problem("starts with a byte order mark; it is written without one")
        }
        guard bytes.last == newline else { throw Problem("does not end with a line break") }
        var values: [String: [UInt8]] = [:]
        var lineOf: [String: Int] = [:]
        var order: [String] = []
        for (index, line) in bytes.dropLast().split(separator: newline, omittingEmptySubsequences: false).enumerated() {
            let number = index + 1
            guard !line.isEmpty else { throw Problem("line \(number) is empty; the file has no blank line") }
            if line.contains(UInt8(ascii: "\r")) {
                throw Problem("line \(number) holds a carriage return; lines end in \\n alone, not Windows' \\r\\n")
            }
            if line.contains(UInt8(ascii: " ")) || line.contains(UInt8(ascii: "\t")) {
                throw Problem("line \(number) holds a space or a tab; the file has none, around = or anywhere else")
            }
            guard let equals = line.firstIndex(of: UInt8(ascii: "=")) else {
                throw Problem("line \(number) is not key=value: \(shown(line))")
            }
            let key = String(decoding: line[line.startIndex ..< equals], as: UTF8.self)
            guard keys.contains(where: { $0.utf8.elementsEqual(line[line.startIndex ..< equals]) }) else {
                throw Problem("line \(number): a lock file has no key \(shown(line[line.startIndex ..< equals])); "
                              + "its keys are \(keys.joined(separator: ", "))")
            }
            if let first = lineOf[key] {
                throw Problem("line \(number): \(key) again, after line \(first)")
            }
            lineOf[key] = number
            order.append(key)
            values[key] = Array(line[line.index(after: equals)...])
        }
        for key in keys where values[key] == nil {
            throw Problem("has no line \(key)=…")
        }
        guard order == keys else {
            throw Problem("its lines are not in the order pin writes them: \(keys.joined(separator: ", "))")
        }

        let version = values["version"] ?? []
        guard let parsed = SemanticVersion(String(decoding: version, as: UTF8.self)),
              parsed.description.utf8.elementsEqual(version) else {
            throw Problem("version \(shown(version)) is not X.Y.Z: three whole numbers, none written with a leading zero")
        }
        var archives: [String: String] = [:]
        for platform in platforms {
            let sum = values[platform] ?? []
            guard isHex(sum, count: 64) else {
                throw Problem("\(platform) \(shown(sum)) is not a sha256: 64 lowercase hexadecimal digits")
            }
            archives[platform] = String(decoding: sum, as: UTF8.self)
        }
        let image = values["image"] ?? []
        guard isDigest(image) else {
            throw Problem("image \(shown(image)) is not a digest: sha256: and 64 lowercase hexadecimal digits")
        }
        let lock = PluginLock(version: parsed, archives: archives, image: String(decoding: image, as: UTF8.self))
        // What the checks above let through is the file as pin writes it; said
        // here as well, since that sameness is what the shell's reading rests on.
        guard lock.text.utf8.elementsEqual(bytes) else { throw Problem("is not as pin writes it") }
        return lock
    }

    /// `sha256:` and 64 lowercase hexadecimal digits.
    static func isDigest<Bytes: Collection>(_ bytes: Bytes) -> Bool where Bytes.Element == UInt8 {
        let prefix = Array("sha256:".utf8)
        return bytes.starts(with: prefix) && isHex(bytes.dropFirst(prefix.count), count: 64)
    }

    /// `count` lowercase hexadecimal digits, and nothing else.
    static func isHex<Bytes: Collection>(_ bytes: Bytes, count: Int) -> Bool where Bytes.Element == UInt8 {
        bytes.count == count && bytes.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }
    }

    /// Bytes as a message quotes them: in quotes, with what a terminal would
    /// act on written out, and cut short.
    static func shown<Bytes: Collection>(_ bytes: Bytes) -> String where Bytes.Element == UInt8 {
        var text = ""
        for byte in bytes.prefix(80) {
            switch byte {
            case 0x22: text += "\\\""
            case 0x5C: text += "\\\\"
            case 0x20 ..< 0x7F: text += String(UnicodeScalar(byte))
            default:
                let hex = String(byte, radix: 16)
                text += "\\x" + (hex.count == 1 ? "0" + hex : hex)
            }
        }
        return "\"\(text)\(bytes.count > 80 ? "…" : "")\""
    }
}
