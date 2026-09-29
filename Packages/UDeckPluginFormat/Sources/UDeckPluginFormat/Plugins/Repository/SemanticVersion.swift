#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// A plugin's `version`, or a `minUDeck`, once it has been read as three numbers.
///
/// `MAJOR.MINOR.PATCH`, each part 0 or a whole number from 1 to 999 999 999
/// with no leading zero, and nothing else: no `v`, no suffix, no fourth part.
/// Three numbers and no suffix on purpose — a plugin under test is identified
/// by its commit, not by a label in its version, and a grammar that starts
/// narrow can widen later without breaking a single manifest, where one that
/// starts wide can never narrow.
///
/// Compared part by part, as numbers: `1.10.0` is newer than `1.9.0`. Two
/// versions with the same three numbers are the same version.
public struct SemanticVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    /// The largest value one part may have. Nine digits keeps every part inside
    /// an `Int` on any platform and every comparison exact.
    public static let largestPart = 999_999_999

    public init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// Reads `text` as a version, or answers nil when it is not one.
    ///
    /// ASCII digits only, read byte by byte rather than through a regular
    /// expression: `\d` and `Int(_:)` both have opinions about what a digit is,
    /// and a version that looks like `1.2.0` in one script and is not
    /// `1.2.0` in bytes would compare as something nobody wrote.
    public init?(_ text: String) {
        let parts = text.utf8.split(separator: UInt8(ascii: "."), omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard let number = Self.part(Array(part)) else { return nil }
            numbers.append(number)
        }
        self.init(major: numbers[0], minor: numbers[1], patch: numbers[2])
    }

    private static func part(_ bytes: [UInt8]) -> Int? {
        guard !bytes.isEmpty, bytes.count <= 9 else { return nil }
        guard bytes.allSatisfy({ $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") }) else { return nil }
        // "0" is a part; "00" and "01" are not.
        if bytes.count > 1 && bytes[0] == UInt8(ascii: "0") { return nil }
        let value = bytes.reduce(0) { $0 * 10 + Int($1 - UInt8(ascii: "0")) }
        return value <= largestPart ? value : nil
    }

    public var description: String { "\(major).\(minor).\(patch)" }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}
