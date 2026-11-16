import Foundation

// **Sign in** by the device flow (stage 4, R6: S4-23): GitHub through the
// uDeck GitHub App, gitlab.com through uDeck's OAuth application, a GitLab of
// one's own through an application registered there. uDeck asks the host for
// a code, shows it, and asks — at the interval the host gave — whether the
// person has entered it; it never opens a browser by itself. What comes back
// is a token and a refresh token, kept as one source's token (`oauth`), and
// renewed a minute before it ends, or once after a `401`. Every request here
// carries a secret or asks for one: it goes only to the host's own OAuth
// origin, refuses every redirect, asks for JSON, and no error of one quotes
// the answer's body — only the status and an OAuth error code uDeck knows.

// MARK: - The applications uDeck signs in as

/// The applications **Sign in** asks the host to let in (S4-23), as uDeck's
/// Info.plist names them: the GitHub App's client id and its public slug —
/// both, or no GitHub Sign in — and the gitlab.com application's id. A GitLab
/// of one's own has its own application, whose id the person pastes into the
/// source (`OwnSource.signInClientID`). Where no id is known there is no
/// button at all, not a disabled one.
public struct SignInApps: Equatable, Sendable {
    public static let gitHubClientIDKey = "UDeckGitHubAppClientID"
    public static let gitHubSlugKey = "UDeckGitHubAppSlug"
    public static let gitLabComClientIDKey = "UDeckGitLabComClientID"

    public var gitHubClientID: String?
    public var gitHubSlug: String?
    public var gitLabComClientID: String?

    public init(gitHubClientID: String? = nil, gitHubSlug: String? = nil, gitLabComClientID: String? = nil) {
        self.gitHubClientID = Self.cleaned(gitHubClientID)
        self.gitHubSlug = Self.cleaned(gitHubSlug)
        self.gitLabComClientID = Self.cleaned(gitLabComClientID)
    }

    /// As the build's Info.plist names them.
    public static func from(infoDictionary info: [String: Any]?) -> SignInApps {
        SignInApps(gitHubClientID: info?[gitHubClientIDKey] as? String, gitHubSlug: info?[gitHubSlugKey] as? String,
                   gitLabComClientID: info?[gitLabComClientIDKey] as? String)
    }

    /// The id **Sign in** asks as for a repository on `host` of `provider` —
    /// nil when there is none, and so no button: github.com with both the
    /// GitHub App's id and its slug; gitlab.com with uDeck's application;
    /// any other GitLab with the id pasted for it.
    public func clientID(provider: String, host: String, pasted: String?) -> String? {
        switch provider {
        case SourceLink.github:
            guard host == SourceLink.githubHost, gitHubSlug != nil else { return nil }
            return gitHubClientID
        case SourceLink.gitlab:
            return host == SourceLink.gitLabCom ? gitLabComClientID : Self.cleaned(pasted)
        default:
            return nil
        }
    }

    /// The page that installs the uDeck app for an account, choosing its
    /// repositories: a GitHub App's token reads only where it is installed.
    public var installPage: URL? {
        gitHubSlug.flatMap { URL(string: "https://github.com/apps/\($0)/installations/new") }
    }

    /// An id as written — trimmed; nothing when it is empty, or holds
    /// anything but what an id is made of.
    public static func cleaned(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty, text.count <= 200,
              text.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) && $0.isASCII
                  || "-_.".unicodeScalars.contains($0) }) else { return nil }
        return text
    }
}

// MARK: - Where Sign in asks

/// A host's OAuth endpoints (S4-23): GitHub's `https://github.com/login/…`,
/// a GitLab's `https://<host>/oauth/…` — or, in a test build, wherever
/// `UDeckPluginsHostMap` sends that host. Their origin is the one a refresh
/// token and a device code may go to, and no other (S4-19).
public struct OAuthEndpoints: Equatable, Sendable {
    public var provider: String
    /// The host as a person reads it: github.com, gitlab.com, one's own.
    public var host: String
    /// Where its requests go: the host itself, or its base in the host map.
    public var base: URL
    public var origin: Origin

    /// `provider`'s endpoints on `host`, after `hostMap` — nil for GitHub
    /// anywhere but github.com, and for a host no address could name.
    public static func of(provider: String, host: String, hostMap: [String: URL] = [:]) -> OAuthEndpoints? {
        switch provider {
        case SourceLink.github: guard host == SourceLink.githubHost else { return nil }
        case SourceLink.gitlab: break
        default: return nil
        }
        guard let own = URL(string: "https://\(host)"), own.host != nil else { return nil }
        let base = hostMap[host] ?? own
        guard let origin = Origin(base) else { return nil }
        return OAuthEndpoints(provider: provider, host: host, base: base, origin: origin)
    }

    /// Where a device code is asked for.
    public var deviceCode: URL {
        GitHubClient.appending(base, provider == SourceLink.github ? "login/device/code" : "oauth/authorize_device")
    }

    /// Where the device code is exchanged, and a refresh token renewed.
    public var token: URL {
        GitHubClient.appending(base, provider == SourceLink.github ? "login/oauth/access_token" : "oauth/token")
    }

    /// The scope asked for: GitLab's `read_api` — what uDeck reads with — and
    /// none on GitHub, whose app's permissions say it (Contents read-only).
    public var scope: String? { provider == SourceLink.gitlab ? "read_api" : nil }
}

// MARK: - What the host answers

/// The code the host gave for the person to enter.
public struct DeviceCode: Equatable, Sendable {
    /// What uDeck polls with: a secret, never shown or logged.
    public var deviceCode: Secret
    /// What the person enters, shown large.
    public var userCode: String
    /// The page it is entered on, as the host named it.
    public var verificationURI: URL
    /// GitLab's page with the code already in it, when it gave one.
    public var verificationURIComplete: URL?
    /// When the code expires.
    public var expiresAt: Date
    /// How often the host may be asked, at the least.
    public var interval: TimeInterval

    public init(deviceCode: Secret, userCode: String, verificationURI: URL, verificationURIComplete: URL? = nil,
                expiresAt: Date, interval: TimeInterval) {
        self.deviceCode = deviceCode
        self.userCode = userCode
        self.verificationURI = verificationURI
        self.verificationURIComplete = verificationURIComplete
        self.expiresAt = expiresAt
        self.interval = interval
    }

    /// The page **Copy the code and open…** opens: GitLab's with the code
    /// in it, or the one the code is entered on (S4-23).
    public var pageToOpen: URL { verificationURIComplete ?? verificationURI }
}

/// A token from **Sign in**, its refresh token and when it ends.
public struct OAuthTokens: Equatable, Sendable {
    public var access: Secret
    public var refresh: Secret?
    public var expiresAt: Date?

    public init(access: Secret, refresh: Secret? = nil, expiresAt: Date? = nil) {
        self.access = access
        self.refresh = refresh
        self.expiresAt = expiresAt
    }
}

/// Why **Sign in**, or a renewal, did not get a token — in words that carry
/// nothing of the answer but its status, and an OAuth error code uDeck knows
/// (S4-19, S4-23).
public enum SignInError: Error, Equatable, Sendable, CustomStringConvertible {
    /// No answer: no network, a name that does not resolve, a timeout.
    case unreachable(String)
    /// The code expired before it was entered: *"The code expired; start
    /// again."*
    case expired
    /// The person declined: *"Sign-in was declined."*
    case denied
    /// The host refused: its status, and the OAuth error it named when it is
    /// one uDeck knows.
    case refused(status: Int, code: String?)
    /// A `3xx` came back: never followed, a secret is never replayed.
    case redirected(status: Int)
    /// An answer that could not be read: its status, and the field that was
    /// missing or wrong — never the answer itself.
    case badAnswer(status: Int, field: String)
    /// Asked of an origin other than the one the token belongs to, or one
    /// no secret may travel to: nothing was sent.
    case wrongOrigin

    public var description: String {
        switch self {
        case .unreachable(let reason): "the host could not be reached: \(reason)"
        case .expired: "the code expired"
        case .denied: "sign-in was declined"
        case .refused(let status, let code): "the host refused (HTTP \(status)\(code.map { ", \($0)" } ?? ""))"
        case .redirected(let status): "the host answered with a redirect (HTTP \(status)), which was not followed"
        case .badAnswer(let status, let field): "the answer (HTTP \(status)) had no readable \(field)"
        case .wrongOrigin: "not sent: the address is not the token's own"
        }
    }

    /// Whether it says the refresh token is no good — refused, unknown,
    /// revoked, or spent on an answer that could not be read — so the source
    /// is signed out. No answer, a host's own trouble (`5xx`) or a pause it
    /// asked for (`429`) leaves it signed in, to try again later. GitHub says
    /// its refusals with a `200` (`bad_refresh_token`): those sign out too.
    public var signsOut: Bool {
        switch self {
        case .refused(let status, let code):
            !(status >= 500 || status == 429
                || code.map { ["server_error", "temporarily_unavailable", "slow_down"].contains($0) } == true)
        case .badAnswer, .redirected, .wrongOrigin, .expired, .denied: true
        case .unreachable: false
        }
    }
}

/// What one poll of the token endpoint answered (RFC 8628, §3.5).
public enum PollAnswer: Equatable, Sendable {
    /// `authorization_pending`: not entered yet.
    case pending
    /// `slow_down`: asked too often.
    case slowDown
    case expired
    case denied
    case tokens(OAuthTokens)
    /// No answer this time — asked again at the next interval, until the code
    /// expires.
    case unreachable(String)
    case failed(SignInError)
}

/// When to poll, and what each answer comes to (S4-23): at the interval the
/// host gave, five seconds more after each `slow_down`; until the code
/// expires, a poll that got no answer included. Pure, so it is tested.
public struct DevicePolling: Equatable, Sendable {
    public enum Step: Equatable, Sendable {
        /// Poll again after this many seconds.
        case wait(TimeInterval)
        case signedIn(OAuthTokens)
        case failed(SignInError)
    }

    public private(set) var interval: TimeInterval
    public let expiresAt: Date
    /// The least interval uDeck polls at, whatever a host says.
    public static let leastInterval: TimeInterval = 1
    /// What `slow_down` adds (RFC 8628, §3.5).
    public static let slowDownBy: TimeInterval = 5

    public init(_ code: DeviceCode) {
        interval = max(code.interval, Self.leastInterval)
        expiresAt = code.expiresAt
    }

    /// The wait before the first poll.
    public var first: Step { .wait(interval) }

    /// What `answer`, received at `now`, comes to.
    public mutating func next(_ answer: PollAnswer, now: Date) -> Step {
        switch answer {
        case .tokens(let tokens): return .signedIn(tokens)
        case .expired: return .failed(.expired)
        case .denied: return .failed(.denied)
        case .failed(let error): return .failed(error)
        case .slowDown:
            interval += Self.slowDownBy
            return now.addingTimeInterval(interval) > expiresAt ? .failed(.expired) : .wait(interval)
        case .pending, .unreachable:
            return now.addingTimeInterval(interval) > expiresAt ? .failed(.expired) : .wait(interval)
        }
    }
}

// MARK: - Asking

/// The device flow's and the refresh's requests to one host's OAuth
/// endpoints (S4-23): form-encoded `POST`s with `Accept: application/json` —
/// GitHub answers form-encoded otherwise — sent refusing every redirect
/// (`RedirectRefusal`), each with the application's client id and no secret
/// of the application's: it has none.
public struct OAuthClient: Sendable {
    public let endpoints: OAuthEndpoints
    public let clientID: String
    private let session: URLSession
    private let userAgent: String
    private let now: @Sendable () -> Date

    public init(endpoints: OAuthEndpoints, clientID: String, udeckVersion: String,
                session: URLSession = GitHubClient.makeSession(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.endpoints = endpoints
        self.clientID = clientID
        self.session = session
        self.userAgent = "uDeck/\(udeckVersion)"
        self.now = now
    }

    /// A code for the person to enter.
    public func deviceCode() async throws(SignInError) -> DeviceCode {
        var form = [("client_id", clientID)]
        if let scope = endpoints.scope { form.append(("scope", scope)) }
        let (status, object) = try await post(endpoints.deviceCode, form)
        guard (200 ..< 300).contains(status) else { throw Self.refusal(status, object) }
        guard let device = (object["device_code"] as? String).flatMap(Self.nonEmpty) else {
            throw .badAnswer(status: status, field: "device_code")
        }
        guard let user = (object["user_code"] as? String).flatMap(Self.userCode) else {
            throw .badAnswer(status: status, field: "user_code")
        }
        guard let page = (object["verification_uri"] as? String).flatMap(Self.page) else {
            throw .badAnswer(status: status, field: "verification_uri")
        }
        guard let expires = Self.seconds(object["expires_in"]), expires > 0 else {
            throw .badAnswer(status: status, field: "expires_in")
        }
        let complete = (object["verification_uri_complete"] as? String).flatMap(Self.page)
        return DeviceCode(deviceCode: Secret(device), userCode: user, verificationURI: page,
                          verificationURIComplete: complete, expiresAt: now().addingTimeInterval(expires),
                          interval: Self.seconds(object["interval"]) ?? 5)
    }

    /// One poll: whether the code was entered.
    public func poll(_ code: DeviceCode) async -> PollAnswer {
        let answer: (Int, [String: Any])
        do {
            answer = try await post(endpoints.token, [
                ("client_id", clientID), ("device_code", code.deviceCode.revealed),
                ("grant_type", "urn:ietf:params:oauth:grant-type:device_code"),
            ])
        } catch .unreachable(let reason) {
            return .unreachable(reason)
        } catch {
            return .failed(error)
        }
        let (status, object) = answer
        // GitHub says its errors with a `200`, GitLab with a `400`.
        if let error = object["error"] as? String {
            switch error {
            case "authorization_pending": return .pending
            case "slow_down": return .slowDown
            case "expired_token": return .expired
            case "access_denied": return .denied
            default: return .failed(Self.refusal(status, object))
            }
        }
        guard (200 ..< 300).contains(status) else { return .failed(Self.refusal(status, object)) }
        do {
            return .tokens(try tokens(status, object))
        } catch {
            return .failed(error)
        }
    }

    /// `refresh` exchanged for a new pair — the old refresh token dies on use
    /// on both hosts (S4-23). Only to the origin `boundTo`: the one the token
    /// was signed in at.
    public func renew(_ refresh: Secret, boundTo origin: Origin?) async throws(SignInError) -> OAuthTokens {
        guard let origin, origin == endpoints.origin, origin.mayCarryASecret else { throw .wrongOrigin }
        let (status, object) = try await post(endpoints.token, [
            ("client_id", clientID), ("grant_type", "refresh_token"), ("refresh_token", refresh.revealed),
        ])
        guard object["error"] == nil, (200 ..< 300).contains(status) else { throw Self.refusal(status, object) }
        return try tokens(status, object)
    }

    /// The pair an answer gives.
    private func tokens(_ status: Int, _ object: [String: Any]) throws(SignInError) -> OAuthTokens {
        guard let access = (object["access_token"] as? String).flatMap(Self.nonEmpty) else {
            throw .badAnswer(status: status, field: "access_token")
        }
        let refresh = (object["refresh_token"] as? String).flatMap(Self.nonEmpty)
        let ends = Self.seconds(object["expires_in"]).map { now().addingTimeInterval($0) }
        return OAuthTokens(access: Secret(access), refresh: refresh.map(Secret.init), expiresAt: ends)
    }

    /// A form `POST` to `url` — only to the host's OAuth origin, and only
    /// over HTTPS or to this machine — refusing every redirect; its status
    /// and its answer read as JSON, an answer that is not JSON said without
    /// a word of it.
    private func post(_ url: URL, _ form: [(String, String)]) async throws(SignInError) -> (Int, [String: Any]) {
        guard Origin(url) == endpoints.origin, endpoints.origin.mayCarryASecret else { throw .wrongOrigin }
        var request = URLRequest(url: url, timeoutInterval: GitHubClient.requestTimeout)
        request.httpMethod = "POST"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(Self.form(form).utf8)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request, delegate: RedirectRefusal.shared)
        } catch {
            throw .unreachable(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw .badAnswer(status: 0, field: "HTTP answer") }
        if (300 ..< 400).contains(http.statusCode) { throw .redirected(status: http.statusCode) }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            // Never what it said instead: a form-encoded answer would carry
            // the token itself (S4-19).
            throw (200 ..< 300).contains(http.statusCode)
                ? .badAnswer(status: http.statusCode, field: "JSON")
                : .refused(status: http.statusCode, code: nil)
        }
        return (http.statusCode, object)
    }

    /// The OAuth error codes said by name: those of RFC 6749, RFC 8628 and
    /// GitHub's. Anything else is not repeated — the answer is the host's,
    /// and could carry anything.
    public static let knownCodes: Set<String> = [
        "invalid_request", "invalid_client", "invalid_grant", "unauthorized_client", "unsupported_grant_type",
        "invalid_scope", "access_denied", "expired_token", "authorization_pending", "slow_down",
        "incorrect_client_credentials", "incorrect_device_code", "device_flow_disabled", "bad_refresh_token",
        "bad_verification_code", "unverified_user_email", "server_error", "temporarily_unavailable",
    ]

    static func refusal(_ status: Int, _ object: [String: Any]) -> SignInError {
        let code = (object["error"] as? String).flatMap { knownCodes.contains($0) ? $0 : nil }
        return .refused(status: status, code: code)
    }

    static func form(_ fields: [(String, String)]) -> String {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return fields.map { "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: unreserved) ?? "")" }
            .joined(separator: "&")
    }

    static func nonEmpty(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// A code to show: letters, digits and dashes, short — anything else is
    /// not a code a person types.
    static func userCode(_ text: String) -> String? {
        guard !text.isEmpty, text.count <= 32,
              text.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-") })
        else { return nil }
        return text
    }

    /// A page to show and open: HTTPS — or this machine, the lab's fake.
    static func page(_ text: String) -> URL? {
        guard let url = URL(string: text), let origin = Origin(url), origin.mayCarryASecret else { return nil }
        return url
    }

    static func seconds(_ value: Any?) -> TimeInterval? {
        switch value {
        case let number as NSNumber: number.doubleValue
        case let text as String: TimeInterval(text)
        default: nil
        }
    }
}

// MARK: - Renewing

/// A token from **Sign in** kept fresh (S4-23): renewed a minute before it
/// ends, or once after the host answered it `401`; one renewal in flight at a
/// time, every request that needs one waiting for it. The rotated pair is
/// written to the Keychain before the new token is sent anywhere — the old
/// refresh token dies on use — and nothing is asked of the host when the
/// Keychain cannot be read first, so the old one stays good for later. A
/// renewal the host refuses signs the source out, for good: every request
/// after it is refused at once, until Sign in again. One whose request got no
/// answer leaves it signed in, to try again at the next request.
public actor TokenRenewal {
    /// What renews: the host asked, with the refresh token.
    public typealias Renew = @Sendable (Secret) async throws(SignInError) -> OAuthTokens
    /// The Keychain asked, before the host: nil when it can be read, and
    /// still holds this refresh token; otherwise why not.
    public typealias Check = @Sendable (Secret) async -> String?
    /// The pair written over the old one — nil once it is written, otherwise
    /// why not. Nothing is sent with the new token before.
    public typealias Keep = @Sendable (_ old: Secret, _ new: OAuthTokens) async -> String?

    /// How long before its end a token is renewed.
    public static let early: TimeInterval = 60

    private var tokens: OAuthTokens
    private let renew: Renew
    private let check: Check
    private let keep: Keep
    private var flight: Task<Result<Secret, ProviderError>, Never>?
    private var signedOut = false

    public init(_ tokens: OAuthTokens, renew: @escaping Renew, check: @escaping Check, keep: @escaping Keep) {
        self.tokens = tokens
        self.renew = renew
        self.check = check
        self.keep = keep
    }

    /// The pair as it stands.
    public var current: OAuthTokens { tokens }

    /// The token a request carries now: renewed first when it ends within
    /// `early` of `now`.
    public func token(now: Date) async throws(ProviderError) -> Secret {
        if signedOut { throw .signedOut }
        guard let ends = tokens.expiresAt, ends.addingTimeInterval(-Self.early) <= now, tokens.refresh != nil else {
            return tokens.access
        }
        return try await renewing(tokens.access)
    }

    /// After the host answered `refused` with `401`: a renewed token — the
    /// one another request renewed meanwhile, or a new one — or nil when
    /// there is no refresh token to renew with.
    public func renewed(after refused: Secret) async throws(ProviderError) -> Secret? {
        if signedOut { throw .signedOut }
        if refused != tokens.access { return tokens.access }
        guard tokens.refresh != nil else { return nil }
        return try await renewing(refused)
    }

    private func renewing(_ stale: Secret) async throws(ProviderError) -> Secret {
        if let flight { return try await flight.value.get() }
        if stale != tokens.access { return tokens.access }
        guard let refresh = tokens.refresh else { return tokens.access }
        let (renew, check, keep) = (self.renew, self.check, self.keep)
        let task = Task { () -> (Result<Secret, ProviderError>, OAuthTokens?, Bool) in
            if let reason = await check(refresh) { return (.failure(.keychainUnavailable(reason)), nil, false) }
            let fresh: OAuthTokens
            do throws(SignInError) {
                fresh = try await renew(refresh)
            } catch {
                return error.signsOut ? (.failure(.signedOut), nil, true)
                    : (.failure(.unreachable(error.description)), nil, false)
            }
            // A host that gave no new refresh token keeps the old one going.
            var kept = fresh
            if kept.refresh == nil { kept.refresh = refresh }
            if await keep(refresh, kept) != nil { return (.failure(.signedOut), nil, true) }
            return (.success(kept.access), kept, false)
        }
        let waiting = Task { await task.value.0 }
        flight = waiting
        let (result, kept, out) = await task.value
        if let kept { tokens = kept }
        if out { signedOut = true }
        flight = nil
        return try result.get()
    }
}
