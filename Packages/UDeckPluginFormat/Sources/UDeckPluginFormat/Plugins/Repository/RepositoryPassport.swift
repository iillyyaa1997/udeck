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
    public static func read(_ data: Data?) -> Result<RepositoryPassport, Problem> {
        guard let data,
              let object = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .object(let fields) = object else {
            return .failure(.missing)
        }
        // `format` first: a passport from the future may have changed every
        // other field, and its name is not worth reading if its layout is not.
        guard let format = fields["format"]?.wholeNumber else {
            return .failure(.invalid("\"format\" must be a whole number"))
        }
        guard format >= 1 else { return .failure(.invalid("\"format\" must be 1 or more, got \(format)")) }
        guard format <= supportedFormat else { return .failure(.futureFormat(declared: format)) }
        guard case .string(let name)? = fields["name"], (1...64).contains(name.count) else {
            return .failure(.invalid("\"name\" must be text of 1 to 64 characters"))
        }
        var description: String?
        if let value = fields["description"], value != .null {
            guard case .string(let text) = value, text.count <= 280 else {
                return .failure(.invalid("\"description\" must be text of at most 280 characters"))
            }
            description = text
        }
        return .success(RepositoryPassport(format: format, name: name, description: description))
    }
}

/// Any JSON value, as `JSONDecoder` reads it.
///
/// For a file whose fields have to be looked at one by one — the passport —
/// without `JSONSerialization`, which the Linux build does not have. It also
/// tells `true` from `1`, which a value `JSONSerialization` hands back only
/// tells apart through CoreFoundation.
indirect enum JSONValue: Decodable, Equatable, Sendable {
    case null
    case bool(Bool)
    /// A whole number that fits in an `Int` — `JSONDecoder` reads `1.0` as
    /// one too — kept whole, so that a large one is not rounded through a
    /// `Double`.
    case integer(Int)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null; return }
        // In this order: a boolean is never read as a number, and a whole
        // number is never read through a `Double`.
        if let value = try? container.decode(Bool.self) { self = .bool(value); return }
        if let value = try? container.decode(Int.self) { self = .integer(value); return }
        if let value = try? container.decode(Double.self) { self = .number(value); return }
        if let value = try? container.decode(String.self) { self = .string(value); return }
        if let value = try? container.decode([JSONValue].self) { self = .array(value); return }
        self = .object(try container.decode([String: JSONValue].self))
    }

    /// The value as a whole number, when it is a number that is one: `1` and
    /// `1.0` are, `1.5` and `true` are not — what `as? Int` answered of the
    /// numbers `JSONSerialization` hands back. `JSONDecoder` already reads
    /// `1.0` as an `Int`, so a whole number is always `.integer` here.
    var wholeNumber: Int? {
        if case .integer(let value) = self { value } else { nil }
    }
}
