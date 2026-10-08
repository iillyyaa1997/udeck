#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import Crypto

/// The two files of a uDeck release that say what its `udeck-plugin` is:
/// `SHA256SUMS`, over the three archives, the image file and the image's
/// sources, and `udeck-plugin-image.txt`, the image by its digest — both
/// written by Scripts/make-cli.sh, and read here as strictly as that script
/// reads the image file before a release names it.
public enum ReleaseFiles {
    public static let sums = "SHA256SUMS"
    public static let image = "udeck-plugin-image.txt"
    /// The platforms an image is built for, as its file says them.
    public static let imagePlatforms = "linux/amd64,linux/arm64"

    /// The archive of the sources of the image's GPL and LGPL packages, which
    /// a release publishes beside the image and names in `SHA256SUMS`. No lock
    /// file pins it: a CI runs the image, not its sources.
    public static func imageSources(of version: SemanticVersion) -> String {
        "udeck-plugin-image-sources-\(version).tar"
    }

    /// Why a release's files cannot be pinned.
    public struct Problem: Error, Equatable, CustomStringConvertible {
        public var description: String
        init(_ description: String) { self.description = description }
    }

    /// What an image file says.
    public struct Image: Equatable, Sendable {
        /// Where the release pushed it: `ghcr.io/iillyyaa1997/udeck-plugin`.
        public var repository: String
        public var version: SemanticVersion
        /// `sha256:` and 64 lowercase hexadecimal digits: the index's.
        public var digest: String
    }

    /// The image file as `make-cli.sh push` writes it — four lines, in this
    /// order, and nothing else.
    public static func imageText(repository: String, version: SemanticVersion, digest: String) -> String {
        "image=\(repository)\ntag=v\(version)\ndigest=\(digest)\nplatforms=\(imagePlatforms)\n"
    }

    /// Reads an image file and holds it, byte for byte, to what `push` writes:
    /// an image whose name ends in `/udeck-plugin`, a tag `vX.Y.Z`, a whole
    /// digest, both platforms.
    public static func image(_ bytes: [UInt8]) throws -> Image {
        let lines = bytes.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
        func value(_ key: String) -> [UInt8]? {
            let prefix = Array("\(key)=".utf8)
            let found = lines.filter { $0.starts(with: prefix) }
            return found.count == 1 ? Array(found[0].dropFirst(prefix.count)) : nil
        }
        let said = PluginLock.shown(bytes)
        guard let tag = value("tag"), tag.first == UInt8(ascii: "v"),
              let version = SemanticVersion(String(decoding: tag.dropFirst(), as: UTF8.self)),
              ("v" + version.description).utf8.elementsEqual(tag) else {
            throw Problem("\(Self.image) has no line tag=vX.Y.Z: \(said)")
        }
        guard let digest = value("digest"), PluginLock.isDigest(digest) else {
            throw Problem("\(Self.image) has no line digest=sha256:<64 hexadecimal digits>: \(said)")
        }
        guard let repository = value("image"), isRepository(repository) else {
            throw Problem("\(Self.image) has no line image=<registry>/<path>/udeck-plugin: \(said)")
        }
        let image = Image(repository: String(decoding: repository, as: UTF8.self), version: version,
                          digest: String(decoding: digest, as: UTF8.self))
        guard imageText(repository: image.repository, version: version, digest: image.digest).utf8.elementsEqual(bytes) else {
            throw Problem("\(Self.image) says \(said) — not what a release writes: "
                          + PluginLock.shown(Array(imageText(repository: image.repository, version: version,
                                                             digest: image.digest).utf8)))
        }
        return image
    }

    /// A registry and a path, lowercase, the last part `udeck-plugin`: what a
    /// CI puts its mirror's address before.
    static func isRepository(_ bytes: [UInt8]) -> Bool {
        let suffix = Array("/udeck-plugin".utf8)
        guard bytes.count > suffix.count, bytes.count <= 255, Array(bytes.suffix(suffix.count)) == suffix else { return false }
        guard let first = bytes.first, (first >= 0x61 && first <= 0x7A) || (first >= 0x30 && first <= 0x39) else { return false }
        let allowed = Set(Array("abcdefghijklmnopqrstuvwxyz0123456789._-:/".utf8))
        guard bytes.allSatisfy({ allowed.contains($0) }) else { return false }
        // No empty part: `ghcr.io//udeck-plugin` names nothing.
        return !bytes.split(separator: UInt8(ascii: "/"), omittingEmptySubsequences: false).contains { $0.isEmpty }
    }

    /// Reads `SHA256SUMS` of `version`, as `sha256sum` writes it — a line of
    /// 64 lowercase hexadecimal digits, two spaces and a name for each file —
    /// and answers the sum of each. It must name exactly the three archives,
    /// the image file and the image's sources of that version, each once: a
    /// release with an asset this command does not know is one for a newer
    /// `udeck-plugin` to pin.
    public static func sums(_ bytes: [UInt8], of version: SemanticVersion) throws -> [String: String] {
        guard bytes.last == UInt8(ascii: "\n") else {
            throw Problem("\(Self.sums) of v\(version) does not end with a line break")
        }
        let expected = PluginLock.platforms.map { PluginLock.archive($0, of: version) } + [Self.image, imageSources(of: version)]
        var found: [String: String] = [:]
        for (index, line) in bytes.dropLast().split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false).enumerated() {
            let sum = line.prefix(64)
            let gap = line.dropFirst(64).prefix(2)
            let name = line.dropFirst(66)
            guard PluginLock.isHex(sum, count: 64), Array(gap) == Array("  ".utf8), !name.isEmpty else {
                throw Problem("\(Self.sums) of v\(version), line \(index + 1), is not <sha256>  <name>: \(PluginLock.shown(line))")
            }
            let named = String(decoding: name, as: UTF8.self)
            guard expected.contains(where: { $0.utf8.elementsEqual(name) }) else {
                throw Problem("\(Self.sums) of v\(version) names \(PluginLock.shown(name)), which udeck-plugin "
                              + "\(UDeckRelease.version) does not know: a newer udeck-plugin pins this release")
            }
            guard found[named] == nil else {
                throw Problem("\(Self.sums) of v\(version) names \(named) twice")
            }
            found[named] = String(decoding: sum, as: UTF8.self)
        }
        for name in expected where found[name] == nil {
            throw Problem("\(Self.sums) of v\(version) names no \(name)")
        }
        return found
    }

    /// The lock file for the release whose `SHA256SUMS` and image file these
    /// are — once the two agree: the image file is the one the sums name, by
    /// its sha256, and of the version they are. `version` is the release
    /// asked for; nil takes the image file's.
    public static func lock(sums: [UInt8], image: [UInt8], version asked: SemanticVersion?) throws -> (lock: PluginLock, image: Image) {
        let read = try Self.image(image)
        if let asked, asked != read.version {
            throw Problem("\(Self.image) of v\(asked) is of v\(read.version)")
        }
        let listed = try Self.sums(sums, of: read.version)
        let hashed = sha256(image)
        guard let named = listed[Self.image], named == hashed else {
            throw Problem("\(Self.image) is not the file \(Self.sums) names: its sha256 is \(hashed), "
                          + "\(Self.sums) says \(listed[Self.image] ?? "nothing") — the two are not of one release")
        }
        var archives: [String: String] = [:]
        for platform in PluginLock.platforms {
            archives[platform] = listed[PluginLock.archive(platform, of: read.version)]
        }
        return (PluginLock(version: read.version, archives: archives, image: read.digest), read)
    }

    /// Lowercase hexadecimal, as `sha256sum` prints it.
    public static func sha256(_ bytes: [UInt8]) -> String {
        SHA256.hash(data: bytes).map { byte in
            let hex = String(byte, radix: 16)
            return hex.count == 1 ? "0" + hex : hex
        }.joined()
    }
}
