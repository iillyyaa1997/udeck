#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// `udeck-plugins.json`: what tells uDeck that a repository was *meant* to be a
/// plugin repository, rather than any repository with a `plugins` folder.
///
/// There is no index in it, on purpose — the repository is the index. It is
/// the one place a future change of layout can be announced before uDeck
/// misreads it, which is why a `format` higher than this uDeck knows refuses
/// the repository as a whole.
public struct RepositoryPassport: Codable, Equatable, Sendable {
    /// The repository format this uDeck reads.
    public static let supportedFormat = 1

    /// Where the passport sits: at the top of the repository.
    public static let path = "udeck-plugins.json"

    public var format: Int
    public var name: String
    public var description: String?

    public init(format: Int = RepositoryPassport.supportedFormat, name: String, description: String? = nil) {
        self.format = format
        self.name = name
        self.description = description
    }

    /// What can be wrong with a passport, each a reason to refuse the whole
    /// repository.
    public enum Problem: Error, Equatable, Sendable {
        /// Not there at the commit read, or not JSON.
        case missing
        /// A layout from the future: guessing at it is how files end up
        /// installed from the wrong place.
        case futureFormat(declared: Int)
        /// JSON, but not a passport: a field missing or of the wrong kind.
        case invalid(String)
    }

    /// Reads a passport, ignoring fields it does not know — the repository's
    /// own check reports those, since in a hand-written file they are usually
    /// typos, but they are no reason for uDeck to refuse anything.
    ///
    /// Read the way uDeck has always read it, which was `JSONSerialization`'s
    /// way: UTF-8, UTF-16 or UTF-32, a field given twice counting the first
    /// time, a comma before a closing bracket, containers 513 deep. With one
    /// difference, on purpose: `format` is
    /// read from the number as written, and only a whole number is one. A
    /// `Double` takes `1.00000000000000001` for 1; the passport does not.
    ///
    /// A passport larger than `maximumBytes` is refused before a byte of it is
    /// read as JSON: uDeck reads the catalogue on its main thread, and what a
    /// repository puts there must not decide how long that takes.
    public static func read(_ data: Data?) -> Result<RepositoryPassport, Problem> {
        if let data, data.count > maximumBytes { return .failure(.invalid(tooLarge(data.count))) }
        guard let data, let text = StrictJSON.utf8(fromAnyUnicode: Array(data)),
              let fields = StrictJSON.parse(text, maximumDepth: serializationDepth, trailingCommas: true).value?.object
        else {
            return .failure(.missing)
        }
        // `format` first: a passport from the future may have changed every
        // other field, and its name is not worth reading if its layout is not.
        guard let format = fields.first("format")?.number?.wholeValue else {
            return .failure(.invalid("\"format\" must be a whole number"))
        }
        guard format >= 1 else { return .failure(.invalid("\"format\" must be 1 or more, got \(format)")) }
        guard format <= supportedFormat else { return .failure(.futureFormat(declared: format)) }
        guard let name = fields.first("name")?.string, (1...64).contains(name.count) else {
            return .failure(.invalid("\"name\" must be text of 1 to 64 characters"))
        }
        var description: String?
        if let value = fields.first("description"), !value.isNull {
            guard let text = value.string, text.count <= 280 else {
                return .failure(.invalid("\"description\" must be text of at most 280 characters"))
            }
            description = text
        }
        return .success(RepositoryPassport(format: format, name: name, description: description))
    }

    /// How deep `JSONSerialization` read, measured on macOS 27: 513 containers,
    /// where `JSONDecoder` stops at 512.
    static let serializationDepth = 513

    /// The largest passport uDeck reads: 64 KiB. A passport is three short
    /// fields — a name of at most 64 characters and a description of at most
    /// 280 — and even written with every character as a `\u` escape pair and
    /// indented generously it stays under 8 KiB. Sixty-four is eight times
    /// that, and small enough that reading it takes no time worth measuring.
    public static let maximumBytes = 64 * 1024

    /// Why a passport of `bytes` is refused, in words that follow its name.
    static func tooLarge(_ bytes: Int) -> String {
        "it is \(bytes) bytes, and a passport may be at most 64 KiB (\(maximumBytes) bytes)"
    }
}
