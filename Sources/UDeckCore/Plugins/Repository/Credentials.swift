import Foundation

// Tokens for sources of one's own (stage 4, R3: S4-17, S4-18, S4-19): what a
// token is, where it may be sent, and where it is kept. Only
// `KeychainCredentialStore.swift` speaks to the Keychain; everything here
// reaches it through `CredentialStore`, which tests fake.

// MARK: - Secret

/// A token, a refresh token, a device code: a value that says nothing of
/// itself. Printed, interpolated, dumped or mirrored it is `<redacted>`; the
/// value comes out only through `revealed`, for the header a request carries
/// it in and the Keychain item that keeps it.
public struct Secret: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    private let value: String

    public init(_ value: String) {
        self.value = value
    }

    /// The value itself — for a request's header, and the Keychain's payload.
    public var revealed: String { value }

    public var isEmpty: Bool { value.isEmpty }

    public var description: String { "<redacted>" }
    public var debugDescription: String { "<redacted>" }
    public var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
}

// MARK: - Origin

/// Where a request goes: its scheme, host and port — `https://api.github.com`,
/// `http://127.0.0.1:8768` — the port left out when it is its scheme's own.
/// Lowercased, so two spellings of one origin are one.
public struct Origin: Hashable, Sendable, CustomStringConvertible, Codable {
    public let scheme: String
    public let host: String
    public let port: Int?

    public init?(_ url: URL) {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        self.scheme = scheme
        self.host = host
        let own = scheme == "https" ? 443 : 80
        self.port = url.port.flatMap { $0 == own ? nil : $0 }
    }

    public init?(_ text: String) {
        guard let url = URL(string: text) else { return nil }
        self.init(url)
    }

    public var description: String {
        let shown = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        return "\(scheme)://\(shown)" + (port.map { ":\($0)" } ?? "")
    }

    /// This machine's own address: where the lab's fake answers.
    public var isLoopback: Bool {
        ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host)
    }

    /// Whether a secret may travel to it at all: over HTTPS, or to this
    /// machine itself — never in the clear across a network.
    public var mayCarryASecret: Bool { scheme == "https" || isLoopback }

    public init(from decoder: any Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let origin = Origin(text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not an origin"))
        }
        self = origin
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

// MARK: - A source's credential

/// What a token was checked against (S4-18): the provider, the number the
/// check read, and the origin the check request actually went to — after any
/// host map a lab build carries — and, for a token from **Sign in**, the
/// origin of its token endpoints. A token goes to that API origin alone: a
/// plugin that rewrites `sources.json`, or a host map added to an installed
/// app, sends it nowhere new.
public struct CredentialBinding: Codable, Equatable, Sendable {
    public var provider: String
    public var remoteID: Int
    public var apiOrigin: Origin
    public var oauthOrigin: Origin?

    public init(provider: String, remoteID: Int, apiOrigin: Origin, oauthOrigin: Origin? = nil) {
        self.provider = provider
        self.remoteID = remoteID
        self.apiOrigin = apiOrigin
        self.oauthOrigin = oauthOrigin
    }
}

/// A source's token, as a request carries it (S4-17): a pasted personal,
/// project or group token — GitHub's in `Authorization: Bearer`, GitLab's in
/// `PRIVATE-TOKEN`, which Apple does not reserve — or one from **Sign in**,
/// in `Authorization: Bearer` on both (R6).
public struct SourceCredential: Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// Pasted under the token step or **Token…**.
        case pat
        /// From **Sign in** (R6).
        case oauth
    }

    public var kind: Kind
    public var token: Secret
    public var binding: CredentialBinding

    public init(kind: Kind = .pat, token: Secret, binding: CredentialBinding) {
        self.kind = kind
        self.token = token
        self.binding = binding
    }

    /// The header a request carries it in, and its value.
    public var header: (name: String, value: String) {
        if binding.provider == SourceLink.gitlab, kind == .pat { return ("PRIVATE-TOKEN", token.revealed) }
        return ("Authorization", "Bearer \(token.revealed)")
    }

    /// Whether a request to `url` may carry it (S4-19): to the origin it was
    /// checked with and no other, and only over HTTPS or to this machine.
    public func mayGo(to url: URL) -> Bool {
        guard let origin = Origin(url) else { return false }
        return origin == binding.apiOrigin && origin.mayCarryASecret
    }
}

/// What a token's prefix proves (S4-17): GitHub's tokens start `ghp_`,
/// `github_pat_`, `gho_`, `ghu_`, `ghs_` or `ghr_`, and GitLab's personal,
/// project and group tokens `glpat-`. Anything else proves nothing — a
/// GitLab of one's own may change its prefix — and is not refused.
public enum TokenPrefix {
    public static let github = ["ghp_", "github_pat_", "gho_", "ghu_", "ghs_", "ghr_"]
    public static let gitlab = ["glpat-"]

    /// The provider `token` proves it is for, or nil.
    public static func provider(of token: String) -> String? {
        let text = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if github.contains(where: text.hasPrefix) { return SourceLink.github }
        if gitlab.contains(where: text.hasPrefix) { return SourceLink.gitlab }
        return nil
    }

    /// Whether `token`, pasted for a source of `provider`, proves it belongs
    /// to the other one — refused before any request (S4-20, item 23).
    public static func isTheOtherProviders(_ token: String, source provider: String) -> Bool {
        guard let proven = self.provider(of: token) else { return false }
        return proven != provider
    }
}

/// The pages that make a read-only token with the fields filled in (S4-17),
/// as the token step's **Make a token on <host>** opens them.
public enum TokenLinks {
    /// GitHub's fine-grained token page: named *uDeck: <repo>* — 40
    /// characters at the most, GitHub's limit — described, for `owner`,
    /// expiring in 366 days, with Contents read-only. GitHub has no parameter
    /// that selects the repository: the sheet asks the person to.
    public static func github(owner: String, repository: String) -> URL {
        let name = String("uDeck: \(repository)".prefix(40))
        return url("https://github.com/settings/personal-access-tokens/new", [
            ("name", name),
            ("description", "Read-only, for uDeck to read plugins from \(owner)/\(repository)."),
            ("target_name", owner),
            ("expires_in", "366"),
            ("contents", "read"),
        ])
    }

    /// A GitLab's personal access token page — gitlab.com's, or one's own —
    /// named *uDeck: <project>*, described, with the `read_api` scope.
    public static func gitlab(host: String, project: String) -> URL {
        let name = String("uDeck: \(project)".prefix(255))
        return url("https://\(host)/-/user_settings/personal_access_tokens", [
            ("name", name),
            ("description", "Read-only, for uDeck to read plugins from \(project)."),
            ("scopes", "read_api"),
        ])
    }

    /// `base` with `query`, each value escaped but for the unreserved
    /// characters — a `+` or a space never read as the other.
    static func url(_ base: String, _ query: [(String, String)]) -> URL {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let text = query.map { "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: unreserved) ?? "")" }
            .joined(separator: "&")
        return URL(string: "\(base)?\(text)")!
    }
}

// MARK: - Where tokens are kept

/// The one Keychain item every token lives in (S4-18), as a seam:
/// `KeychainCredentialStore` in uDeck, a fake in tests. Every call may block
/// while macOS asks the person.
public protocol CredentialStore: Sendable {
    /// The item's data — nil when there is no item.
    func read() throws(CredentialStoreError) -> Data?
    /// `data` written: over the item when `exists`, as a new item otherwise.
    func write(_ data: Data, exists: Bool) throws(CredentialStoreError)
    /// The item deleted; no item is no failure.
    func delete() throws(CredentialStoreError)
}

/// Why the Keychain did not do what was asked, in words — never a secret.
public struct CredentialStoreError: Error, Equatable, Sendable {
    public var reason: String

    public init(_ reason: String) {
        self.reason = reason
    }
}

/// The Keychain item's data: `{"version": 1, "tokens": {"<source id>": …}}`.
struct CredentialPayload: Codable, Equatable {
    struct Entry: Codable, Equatable {
        var kind: String
        var token: String?
        var access: String?
        var refresh: String?
        var expiresAt: Date?
        var clientID: String?
        var binding: CredentialBinding

        /// A kind this uDeck knows, with its secret: a pasted token's, or the
        /// access token Sign in got.
        var isWhole: Bool {
            switch SourceCredential.Kind(rawValue: kind) {
            case .pat?: !(token ?? "").isEmpty
            case .oauth?: !(access ?? "").isEmpty
            case nil: false
            }
        }
    }

    var version: Int
    var tokens: [String: Entry]

    static let current = 1

    /// The payload as the item keeps it — nil for data that is not one this
    /// uDeck reads: damaged, or a later version's.
    /// Every entry has to be whole — a kind this uDeck knows, with what that
    /// kind needs — or the item is not read, and never written over.
    static func read(_ data: Data) -> CredentialPayload? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let payload = try? decoder.decode(CredentialPayload.self, from: data), payload.version == current,
              payload.tokens.values.allSatisfy(\.isWhole) else {
            return nil
        }
        return payload
    }

    var data: Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(self)
    }
}

/// Every source's token, kept in one Keychain item and handed out only where
/// it may go (S4-18).
///
/// The item is read once, the first time a source with a token needs it —
/// one question from macOS after each update of uDeck. A read that fails —
/// denied, not allowed, any other error — is remembered for the process:
/// every source with a token says so (S4-20, item 14), and no read nobody
/// asked for touches the Keychain again; one the person asked for —
/// **Check now**, **Token…** — tries once more. No item is no failure: no
/// tokens.
///
/// Every change is read, changed, written: the item is read afresh right
/// before, the change made to what was read — not to what was remembered —
/// and written in one step; when that read fails nothing is written, so a
/// denial is never followed by a write that erases the other sources'
/// tokens. The last token gone, the item is deleted. An item a later uDeck
/// wrote in a format this one does not read is never written over.
public actor CredentialVault {
    /// What the vault has for a source.
    public enum Lookup: Equatable, Sendable {
        /// No token: the source is read without one.
        case none
        /// Its token, for requests to its binding's API origin.
        case credential(SourceCredential)
        /// A token checked with `origin`, and the source now elsewhere — or
        /// at an origin no secret may travel to: nothing is sent
        /// (S4-20, item 18).
        case unbound(Origin)
        /// The Keychain could not be read, for `reason` (S4-20, item 14).
        case unavailable(String)
    }

    /// Why a change was not made.
    public enum ChangeError: Error, Equatable, Sendable {
        /// The fresh read before the write failed: nothing was written.
        case unavailable(String)
        /// The item is not one this uDeck reads — a later version's, or
        /// damaged — and is not written over.
        case unreadable
        /// The write itself failed.
        case notWritten(String)
    }

    private let store: any CredentialStore
    private static let unreadable = "the item is not one this uDeck reads"
    private var known: [String: CredentialPayload.Entry]?
    private var failure: String?

    public init(store: any CredentialStore) {
        self.store = store
    }

    /// The token of `source` for requests to `apiOrigin` — the origin its
    /// client's requests go to now. `requested` is a press — **Check now**,
    /// **Token…**, a read the person started — which tries the Keychain once
    /// more after a failure.
    public func credential(for source: OwnSource, apiOrigin: Origin, requested: Bool) -> Lookup {
        guard source.access != OwnSource.Access.none else { return .none }
        if let failure, !requested { return .unavailable(failure) }
        if failure != nil || known == nil {
            switch load() {
            case .success(let entries): known = entries
            case .failure(let error):
                failure = error.reason
                return .unavailable(error.reason)
            }
        }
        guard let entry = known?[source.id] else { return .none }
        let binding = entry.binding
        guard binding.provider == source.provider, binding.remoteID == source.remoteID,
              binding.apiOrigin == apiOrigin, apiOrigin.mayCarryASecret else {
            return .unbound(binding.apiOrigin)
        }
        guard let kind = SourceCredential.Kind(rawValue: entry.kind),
              let token = kind == .pat ? entry.token : entry.access else { return .none }
        return .credential(SourceCredential(kind: kind, token: Secret(token), binding: binding))
    }

    /// `credential` kept for `sourceID` — over any it had.
    /// A pasted token is kept as `token`, Sign in's access token as
    /// `access`: each where a later read looks for it. An empty one is not
    /// kept.
    public func keep(_ credential: SourceCredential, for sourceID: String) throws(ChangeError) {
        guard !credential.token.isEmpty else { throw .notWritten("an empty token is not kept") }
        let secret = credential.token.revealed
        let entry = credential.kind == .pat
            ? CredentialPayload.Entry(kind: credential.kind.rawValue, token: secret, binding: credential.binding)
            : CredentialPayload.Entry(kind: credential.kind.rawValue, access: secret, binding: credential.binding)
        try change { tokens in tokens[sourceID] = entry }
    }

    /// The token of `sourceID` forgotten; the item deleted with the last.
    public func forget(_ sourceID: String) throws(ChangeError) {
        try change { tokens in tokens[sourceID] = nil }
    }

    /// The Keychain asked again at the next lookup, whatever failed before:
    /// **Check now** and **Token…**.
    public func tryAgain() {
        failure = nil
        known = nil
    }

    /// Whether the last read failed, and why.
    public var lastFailure: String? { failure }

    private func load() -> Result<[String: CredentialPayload.Entry], CredentialStoreError> {
        let data: Data?
        do throws(CredentialStoreError) {
            data = try store.read()
        } catch {
            return .failure(error)
        }
        guard let data else {
            failure = nil
            return .success([:])
        }
        guard let payload = CredentialPayload.read(data) else {
            return .failure(CredentialStoreError(Self.unreadable))
        }
        failure = nil
        return .success(payload.tokens)
    }

    private func change(_ apply: (inout [String: CredentialPayload.Entry]) -> Void) throws(ChangeError) {
        let fresh: Data?
        do throws(CredentialStoreError) {
            fresh = try store.read()
        } catch {
            failure = error.reason
            throw .unavailable(error.reason)
        }
        var payload = CredentialPayload(version: CredentialPayload.current, tokens: [:])
        if let fresh {
            guard let read = CredentialPayload.read(fresh) else {
                // What was remembered is no longer what the item holds.
                known = nil
                failure = Self.unreadable
                throw .unreadable
            }
            payload = read
        }
        apply(&payload.tokens)
        do throws(CredentialStoreError) {
            if payload.tokens.isEmpty {
                if fresh != nil { try store.delete() }
            } else {
                guard let data = payload.data else { throw CredentialStoreError("the tokens could not be written out") }
                try store.write(data, exists: fresh != nil)
            }
        } catch {
            known = nil
            throw .notWritten(error.reason)
        }
        known = payload.tokens
        failure = nil
    }
}
