import Foundation

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
              let object = try? JSONSerialization.jsonObject(with: data),
              let fields = object as? [String: Any] else {
            return .failure(.missing)
        }
        // `format` first: a passport from the future may have changed every
        // other field, and its name is not worth reading if its layout is not.
        guard let raw = fields["format"], !JSONValue.isBoolean(raw), let format = raw as? Int else {
            return .failure(.invalid("\"format\" must be a whole number"))
        }
        guard format >= 1 else { return .failure(.invalid("\"format\" must be 1 or more, got \(format)")) }
        guard format <= supportedFormat else { return .failure(.futureFormat(declared: format)) }
        guard let name = fields["name"] as? String, (1...64).contains(name.count) else {
            return .failure(.invalid("\"name\" must be text of 1 to 64 characters"))
        }
        var description: String?
        if let value = fields["description"], !(value is NSNull) {
            guard let text = value as? String, text.count <= 280 else {
                return .failure(.invalid("\"description\" must be text of at most 280 characters"))
            }
            description = text
        }
        return .success(RepositoryPassport(format: format, name: name, description: description))
    }
}

/// Small questions about values `JSONSerialization` hands back.
enum JSONValue {
    /// Whether a decoded value was `true` or `false` in the JSON.
    ///
    /// Not `value is Bool`: an `NSNumber` holding 0 or 1 answers yes to that,
    /// so `"format": 1` would be taken for a boolean and refused.
    static func isBoolean(_ value: Any) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }
}
