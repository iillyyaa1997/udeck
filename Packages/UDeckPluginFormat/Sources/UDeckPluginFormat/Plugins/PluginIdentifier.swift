#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// A plugin's id: the name of its folder, the key for its settings and grants,
/// and the name other people will see when they install it.
///
/// Constrained on purpose. The id becomes a path component and an environment
/// variable suffix, so anything that would be ambiguous in either — a slash, a
/// space, a leading dot — is rejected at the boundary instead of being sanitised
/// somewhere downstream where the two would disagree.
public struct PluginIdentifier: RawRepresentable, Hashable, Sendable, CustomStringConvertible, Comparable {
    public let rawValue: String

    /// Lowercase letters, digits, and `- _ .` between them. 1–64 characters.
    ///
    /// The rule as people read it. It is checked byte by byte (`isIdentifier`),
    /// not through a regular expression: that keeps the check out of ICU, and
    /// a regular expression has opinions of its own — about `$` and a trailing
    /// newline, for one — that nobody reading this line would guess.
    public static let pattern = "^[a-z0-9][a-z0-9._-]{0,63}$"

    public init?(rawValue: String) {
        guard Self.isIdentifier(rawValue) else { return nil }
        // A path component that resolves to a parent directory would let a
        // manifest escape the plugins folder; the pattern already forbids `/`,
        // but `..` on its own still matches, so it is rejected explicitly.
        guard rawValue != "." && rawValue != ".." else { return nil }
        self.rawValue = rawValue
    }

    public var description: String { rawValue }

    /// `pattern`, in bytes: the first a lowercase ASCII letter or a digit, the
    /// rest those or `.`, `_`, `-`, and 64 at most.
    static func isIdentifier(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        guard (1 ... 64).contains(bytes.count), ASCII.isLowercaseLetterOrDigit(bytes[0]) else { return false }
        return bytes.dropFirst().allSatisfy {
            ASCII.isLowercaseLetterOrDigit($0) || $0 == UInt8(ascii: ".") || $0 == UInt8(ascii: "_")
                || $0 == UInt8(ascii: "-")
        }
    }

    public static func < (lhs: PluginIdentifier, rhs: PluginIdentifier) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Used only where a `GridWindow` is fabricated for a geometry calculation
    /// and never rendered.
    public static let placeholder = PluginIdentifier(rawValue: "placeholder")!

    /// The environment-variable suffix for one of this plugin's settings:
    /// `show_waiting_only` becomes `UDECK_SETTING_SHOW_WAITING_ONLY`.
    public static func settingEnvironmentKey(_ key: String) -> String {
        "UDECK_SETTING_" + key.uppercased().map { $0.isLetter || $0.isNumber ? $0 : "_" }
    }
}

extension PluginIdentifier: Codable {
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let id = PluginIdentifier(rawValue: raw) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath,
                      debugDescription: "plugin id \"\(raw)\" must match \(Self.pattern)")
            )
        }
        self = id
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
