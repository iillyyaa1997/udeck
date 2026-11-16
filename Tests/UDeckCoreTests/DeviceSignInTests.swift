import Foundation
import Testing
@testable import UDeckCore

/// **Sign in** by the device flow (stage 4, R6: S4-23): which applications a
/// build signs in as, where it asks, what each answer of the host comes to,
/// the renewal — one in flight, written to the Keychain before the new token
/// goes anywhere, signed out when the host refuses — and the requests that
/// carry its token. Every host here is a stub (`StubAnswers`); no test asks a
/// real one, nor a real Keychain.
@Suite("Sign in: the device flow, renewals and their token")
struct DeviceSignInTests {
    static let access = "ghu_the-labs-own-access-0001"
    static let refresh = "ghr_the-labs-own-refresh-0001"
    static let renewedAccess = "ghu_the-labs-own-access-0002"
    static let renewedRefresh = "ghr_the-labs-own-refresh-0002"
    static let deviceCode = "the-labs-own-device-code-0001"
    static let now = Date(timeIntervalSince1970: 1_792_276_900)

    // MARK: - The applications

    @Test("a build signs in only as the applications its Info.plist names — GitHub's needs its slug too")
    func applications() {
        let full = SignInApps.from(infoDictionary: [
            SignInApps.gitHubClientIDKey: " Iv23li5DCUHkd8JfjXwC ", SignInApps.gitHubSlugKey: "udeck-plugins",
            SignInApps.gitLabComClientIDKey: "4af709fcbb73fc93dc15a7c5f588b0c3102bb6a21864d7b63e41320e07812b3c",
        ])
        #expect(full.clientID(provider: "github", host: "github.com", pasted: nil) == "Iv23li5DCUHkd8JfjXwC")
        #expect(full.clientID(provider: "github", host: "ghe.example", pasted: "x") == nil, "GitHub is github.com alone")
        #expect(full.clientID(provider: "gitlab", host: "gitlab.com", pasted: "pasted-id")
                == "4af709fcbb73fc93dc15a7c5f588b0c3102bb6a21864d7b63e41320e07812b3c", "gitlab.com: uDeck's own")
        #expect(full.clientID(provider: "gitlab", host: "gitlab.unicorns.place", pasted: " 213e6a78 ") == "213e6a78")
        #expect(full.clientID(provider: "gitlab", host: "gitlab.unicorns.place", pasted: nil) == nil)
        #expect(full.installPage?.absoluteString == "https://github.com/apps/udeck-plugins/installations/new")
        let noSlug = SignInApps.from(infoDictionary: [SignInApps.gitHubClientIDKey: "Iv23li5DCUHkd8JfjXwC"])
        #expect(noSlug.clientID(provider: "github", host: "github.com", pasted: nil) == nil,
                "without its slug there is no install hint, so no button")
        let none = SignInApps.from(infoDictionary: [:])
        #expect(none.clientID(provider: "github", host: "github.com", pasted: nil) == nil)
        #expect(none.clientID(provider: "gitlab", host: "gitlab.com", pasted: "x") == nil, "a pasted id is not gitlab.com's")
        for junk in ["", "  ", "a b", "id\n2", "<script>", String(repeating: "a", count: 201), "идентификатор"] {
            #expect(SignInApps.cleaned(junk) == nil, "\(junk)")
        }
    }

    @Test("GitHub asks at github.com/login, a GitLab at its own /oauth — or where a test build's host map sends it")
    func endpoints() throws {
        let github = try #require(OAuthEndpoints.of(provider: "github", host: "github.com"))
        #expect(github.deviceCode.absoluteString == "https://github.com/login/device/code")
        #expect(github.token.absoluteString == "https://github.com/login/oauth/access_token")
        #expect(github.origin == Origin("https://github.com") && github.scope == nil)
        let gitlab = try #require(OAuthEndpoints.of(provider: "gitlab", host: "gitlab.unicorns.place"))
        #expect(gitlab.deviceCode.absoluteString == "https://gitlab.unicorns.place/oauth/authorize_device")
        #expect(gitlab.token.absoluteString == "https://gitlab.unicorns.place/oauth/token")
        #expect(gitlab.scope == "read_api")
        let lab = try #require(OAuthEndpoints.of(provider: "github", host: "github.com",
                                                 hostMap: ["github.com": URL(string: "http://127.0.0.1:8770")!]))
        #expect(lab.token.absoluteString == "http://127.0.0.1:8770/login/oauth/access_token" && lab.host == "github.com")
        #expect(OAuthEndpoints.of(provider: "github", host: "ghe.example") == nil)
        #expect(OAuthEndpoints.of(provider: "bitbucket", host: "bitbucket.org") == nil)
    }

    // MARK: - Polling

    static func code(interval: TimeInterval = 5, expiresIn: TimeInterval = 900) -> DeviceCode {
        DeviceCode(deviceCode: Secret(deviceCode), userCode: "WDJB-MJHT",
                   verificationURI: URL(string: "https://github.com/login/device")!,
                   expiresAt: now.addingTimeInterval(expiresIn), interval: interval)
    }

    @Test("polling: at the host's interval, five seconds more for each slow_down, until the code expires")
    func polling() {
        var polling = DevicePolling(Self.code())
        #expect(polling.first == .wait(5))
        #expect(polling.next(.pending, now: Self.now) == .wait(5))
        #expect(polling.next(.slowDown, now: Self.now) == .wait(10))
        #expect(polling.next(.slowDown, now: Self.now) == .wait(15), "each slow_down adds five more")
        #expect(polling.next(.pending, now: Self.now) == .wait(15), "and the interval stays slowed")
        #expect(polling.next(.unreachable("offline"), now: Self.now) == .wait(15), "no answer: asked again")
        #expect(polling.next(.pending, now: Self.now.addingTimeInterval(890)) == .failed(.expired),
                "the next poll would come after the code expires")
        #expect(polling.next(.expired, now: Self.now) == .failed(.expired))
        #expect(polling.next(.denied, now: Self.now) == .failed(.denied))
        let tokens = OAuthTokens(access: Secret(Self.access))
        #expect(polling.next(.tokens(tokens), now: Self.now) == .signedIn(tokens))
        #expect(polling.next(.failed(.refused(status: 400, code: "invalid_client")), now: Self.now)
                == .failed(.refused(status: 400, code: "invalid_client")))
        #expect(DevicePolling(Self.code(interval: 0)).first == .wait(1), "never faster than once a second")
    }

    // MARK: - Asking the host

    /// A stub host: GitHub's endpoints there, as a test build's host map
    /// would send them.
    struct Host {
        let name: String
        init(_ label: String) { name = "\(label)-\(UUID().uuidString.lowercased()).invalid" }
        func endpoints(_ provider: String = "github") -> OAuthEndpoints {
            OAuthEndpoints.of(provider: provider, host: provider == "github" ? "github.com" : "gitlab.example",
                              hostMap: [provider == "github" ? "github.com" : "gitlab.example": URL(string: "https://\(name)")!])!
        }
        func client(_ provider: String = "github") -> OAuthClient {
            OAuthClient(endpoints: endpoints(provider), clientID: "Iv23li5DCUHkd8JfjXwC", udeckVersion: "0.8.2",
                        session: GitHubClient.makeSession(protocolClasses: [StubAnswers.self]), now: { DeviceSignInTests.now })
        }
        func answer(_ answer: @escaping StubAnswers.Answer) { StubAnswers.answer(name, with: answer) }
        func forget() { StubAnswers.forget(name) }
        var asked: [URLRequest] { StubAnswers.asked(name) }
    }

    /// A request's form body, as the stub saw it.
    static func form(_ request: URLRequest) -> [String: String] {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
        }
        var fields: [String: String] = [:]
        for pair in String(decoding: data, as: UTF8.self).split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            fields[parts[0]] = parts.count > 1 ? parts[1].removingPercentEncoding : ""
        }
        return fields
    }

    @Test("the device code: one form POST with the client id — and read_api on GitLab — asking for JSON")
    func deviceCode() async throws {
        let host = Host("device")
        defer { host.forget() }
        host.answer { request in
            request.url!.path == "/oauth/authorize_device"
                ? (200, Data(#"{"device_code": "\#(DeviceSignInTests.deviceCode)", "user_code": "WDJB-MJHT", "verification_uri": "https://gitlab.example/oauth/device", "verification_uri_complete": "https://gitlab.example/oauth/device?user_code=WDJB-MJHT", "expires_in": 300, "interval": 5}"#.utf8))
                : (200, Data(#"{"device_code": "\#(DeviceSignInTests.deviceCode)", "user_code": "WDJB-MJHT", "verification_uri": "https://github.com/login/device", "expires_in": 899, "interval": 5}"#.utf8))
        }
        let github = try await host.client().deviceCode()
        #expect(github.userCode == "WDJB-MJHT" && github.deviceCode.revealed == Self.deviceCode)
        #expect(github.pageToOpen.absoluteString == "https://github.com/login/device")
        #expect(github.expiresAt == Self.now.addingTimeInterval(899) && github.interval == 5)
        let gitlab = try await host.client("gitlab").deviceCode()
        #expect(gitlab.pageToOpen.absoluteString == "https://gitlab.example/oauth/device?user_code=WDJB-MJHT",
                "GitLab's page with the code in it")
        let asked = host.asked
        #expect(asked.count == 2 && asked.allSatisfy { $0.httpMethod == "POST" })
        #expect(asked.allSatisfy { $0.value(forHTTPHeaderField: "Accept") == "application/json" })
        #expect(asked.allSatisfy { $0.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded" })
        #expect(asked.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil }, "no secret of the application's")
        #expect(asked[0].url!.path == "/login/device/code" && Self.form(asked[0]) == ["client_id": "Iv23li5DCUHkd8JfjXwC"])
        #expect(asked[1].url!.path == "/oauth/authorize_device"
                && Self.form(asked[1]) == ["client_id": "Iv23li5DCUHkd8JfjXwC", "scope": "read_api"])
    }

    @Test("each poll's answer — GitHub's errors come with a 200, GitLab's with a 400 — and the pair when entered")
    func polls() async throws {
        let host = Host("poll")
        defer { host.forget() }
        let answers = Answers()
        host.answer { _ in answers.next() }
        let client = host.client()
        let code = Self.code()
        for (status, body, expected) in [
            (200, #"{"error": "authorization_pending"}"#, PollAnswer.pending),
            (400, #"{"error": "authorization_pending", "error_description": "…"}"#, .pending),
            (200, #"{"error": "slow_down", "interval": 10}"#, .slowDown),
            (400, #"{"error": "expired_token"}"#, .expired),
            (200, #"{"error": "access_denied"}"#, .denied),
            (400, #"{"error": "invalid_client"}"#, .failed(.refused(status: 400, code: "invalid_client"))),
        ] {
            answers.push(status, body)
            #expect(await client.poll(code) == expected, "\(body)")
        }
        answers.push(200, #"{"access_token": "\#(Self.access)", "expires_in": 28800, "refresh_token": "\#(Self.refresh)", "refresh_token_expires_in": 15897600, "token_type": "bearer", "scope": ""}"#)
        let tokens = OAuthTokens(access: Secret(Self.access), refresh: Secret(Self.refresh),
                                 expiresAt: Self.now.addingTimeInterval(28800))
        #expect(await client.poll(code) == .tokens(tokens))
        let form = Self.form(try #require(host.asked.last))
        #expect(form == ["client_id": "Iv23li5DCUHkd8JfjXwC", "device_code": Self.deviceCode,
                         "grant_type": "urn:ietf:params:oauth:grant-type:device_code"], "no secret of the application's")
    }

    /// Answers handed out in turn.
    final class Answers: @unchecked Sendable {
        private let lock = NSLock()
        private var queue: [(Int, Data)] = []
        func push(_ status: Int, _ body: String) { lock.withLock { queue.append((status, Data(body.utf8))) } }
        func next() -> (Int, Data) { lock.withLock { queue.isEmpty ? (599, Data()) : queue.removeFirst() } }
    }

    @Test("no error quotes the answer: a form-encoded pair, a code uDeck does not know, a body after a refusal")
    func nothingQuoted() async throws {
        let host = Host("quoted")
        defer { host.forget() }
        let answers = Answers()
        host.answer { _ in answers.next() }
        let client = host.client()
        let secrets = [Self.access, Self.refresh, Self.deviceCode]
        // GitHub's answer without Accept: application/json — the pair itself.
        answers.push(200, "access_token=\(Self.access)&refresh_token=\(Self.refresh)&token_type=bearer")
        let formEncoded = await client.poll(Self.code())
        #expect(formEncoded == .failed(.badAnswer(status: 200, field: "JSON")))
        answers.push(400, #"{"error": "\#(Self.access)"}"#)
        let unknown = await client.poll(Self.code())
        #expect(unknown == .failed(.refused(status: 400, code: nil)), "an error code uDeck does not know is not said")
        answers.push(502, "<html>\(Self.refresh)</html>")
        let refused = await client.poll(Self.code())
        answers.push(200, "access_token=\(Self.renewedAccess)")
        var renewal: SignInError?
        do {
            _ = try await client.renew(Secret(Self.refresh), boundTo: client.endpoints.origin)
        } catch {
            renewal = error
        }
        answers.push(200, #"{"device_code": "\#(Self.deviceCode)", "user_code": "<b>\#(Self.access)</b>", "verification_uri": "https://github.com/login/device", "expires_in": 900}"#)
        var device: SignInError?
        do {
            _ = try await client.deviceCode()
        } catch {
            device = error
        }
        #expect(device == .badAnswer(status: 200, field: "user_code"), "a code is letters, digits and dashes")
        for said in [formEncoded, unknown, refused].map({ "\($0)" }) + [renewal, device].map({ "\(String(describing: $0))" }) {
            for secret in secrets + [Self.renewedAccess] {
                #expect(!said.contains(secret), "\(said)")
            }
        }
        for error in [renewal, device].compactMap({ $0 }) {
            for phrase in [SignInTrouble.phrase(error, host: "github.com")] {
                for language in [Language.english, .russian] {
                    let text = Strings(language)(phrase)
                    #expect(!secrets.contains { text.contains($0) } && !text.contains(Self.renewedAccess), "\(text)")
                }
            }
        }
    }

    /// A host whose every answer is a `307` to another host, which counts
    /// what reaches it.
    final class Redirecting: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var asked: [URLRequest] = []
        static let lock = NSLock()
        static let from = "oauth-redirecting.invalid", to = "oauth-elsewhere.invalid"

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            Self.lock.withLock { Self.asked.append(request) }
            let url = request.url!
            if url.host == Self.from {
                var moved = URLComponents(url: url, resolvingAgainstBaseURL: false)!
                moved.host = Self.to
                let response = HTTPURLResponse(url: url, statusCode: 307, httpVersion: "HTTP/1.1",
                                               headerFields: ["Location": moved.url!.absoluteString])!
                var next = URLRequest(url: moved.url!)
                next.httpMethod = request.httpMethod
                next.httpBody = request.httpBody
                client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: response)
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: Data("refresh_token=\(DeviceSignInTests.refresh)".utf8))
                client?.urlProtocolDidFinishLoading(self)
                return
            }
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(#"{"access_token": "x"}"#.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    @Test("a redirect is never followed with a refresh token: the 307 comes back, nothing reaches the new host")
    func notRedirected() async throws {
        Redirecting.lock.withLock { Redirecting.asked = [] }
        let endpoints = try #require(OAuthEndpoints.of(provider: "github", host: "github.com",
                                                       hostMap: ["github.com": URL(string: "https://\(Redirecting.from)")!]))
        let client = OAuthClient(endpoints: endpoints, clientID: "Iv23li5DCUHkd8JfjXwC", udeckVersion: "0.8.2",
                                 session: GitHubClient.makeSession(protocolClasses: [Redirecting.self]))
        await #expect(throws: SignInError.redirected(status: 307)) {
            _ = try await client.renew(Secret(Self.refresh), boundTo: endpoints.origin)
        }
        #expect(await client.poll(Self.code()) == .failed(.redirected(status: 307)))
        let elsewhere = Redirecting.lock.withLock { Redirecting.asked.filter { $0.url?.host == Redirecting.to } }
        #expect(elsewhere.isEmpty, "replayed to \(elsewhere.map { $0.url!.absoluteString })")
        #expect(!"\(SignInError.redirected(status: 307))".contains(Self.refresh))
    }

    @Test("a refresh token goes only to the origin it was signed in at, and only over HTTPS or to this machine")
    func renewOnlyAtItsOrigin() async throws {
        let host = Host("origin")
        defer { host.forget() }
        host.answer { _ in (200, Data(#"{"access_token": "\#(DeviceSignInTests.renewedAccess)", "refresh_token": "\#(DeviceSignInTests.renewedRefresh)", "expires_in": 28800}"#.utf8)) }
        let client = host.client()
        await #expect(throws: SignInError.wrongOrigin) {
            _ = try await client.renew(Secret(Self.refresh), boundTo: Origin("https://github.com")!)
        }
        await #expect(throws: SignInError.wrongOrigin) {
            _ = try await client.renew(Secret(Self.refresh), boundTo: nil)
        }
        #expect(host.asked.isEmpty, "nothing sent")
        let renewed = try await client.renew(Secret(Self.refresh), boundTo: client.endpoints.origin)
        #expect(renewed == OAuthTokens(access: Secret(Self.renewedAccess), refresh: Secret(Self.renewedRefresh),
                                       expiresAt: Self.now.addingTimeInterval(28800)))
        #expect(Self.form(try #require(host.asked.first)) == ["client_id": "Iv23li5DCUHkd8JfjXwC",
                                                              "grant_type": "refresh_token", "refresh_token": Self.refresh])
        let plain = OAuthClient(endpoints: OAuthEndpoints.of(provider: "gitlab", host: "gitlab.example",
                                                             hostMap: ["gitlab.example": URL(string: "http://gitlab.example")!])!,
                                clientID: "x", udeckVersion: "0.8.2")
        await #expect(throws: SignInError.wrongOrigin) {
            _ = try await plain.renew(Secret(Self.refresh), boundTo: plain.endpoints.origin)
        }
        #expect(await plain.poll(Self.code()) == .failed(.wrongOrigin), "a device code is never sent in the clear either")
    }

    @Test("what signs a source out: the host refusing its refresh token; not a network failure, a 5xx or a 429")
    func whatSignsOut() {
        for error in [SignInError.refused(status: 400, code: "invalid_grant"), .refused(status: 200, code: "bad_refresh_token"),
                      .refused(status: 401, code: nil), .badAnswer(status: 200, field: "JSON"), .redirected(status: 307)] {
            #expect(error.signsOut, "\(error)")
        }
        for error in [SignInError.unreachable("offline"), .refused(status: 502, code: nil), .refused(status: 429, code: nil),
                      .refused(status: 200, code: "temporarily_unavailable")] {
            #expect(!error.signsOut, "\(error)")
        }
    }

    // MARK: - Renewing

    /// What a renewal did, in order.
    final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func add(_ line: String) { lock.withLock { lines.append(line) } }
        var all: [String] { lock.withLock { lines } }
    }

    static func renewal(_ log: Log, ends: Date? = now.addingTimeInterval(30), checked: String? = nil,
                        renewed: Result<OAuthTokens, SignInError> = .success(OAuthTokens(
                            access: Secret(renewedAccess), refresh: Secret(renewedRefresh), expiresAt: now.addingTimeInterval(28800))),
                        kept: String? = nil, delay: UInt64 = 0) -> TokenRenewal {
        TokenRenewal(OAuthTokens(access: Secret(access), refresh: Secret(refresh), expiresAt: ends),
                     renew: { refresh throws(SignInError) in
                         log.add("renew \(refresh.revealed)")
                         if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
                         return try renewed.get()
                     },
                     check: { refresh in
                         log.add("check \(refresh.revealed)")
                         return checked
                     },
                     keep: { old, new in
                         log.add("keep \(old.revealed) → \(new.access.revealed)")
                         return kept
                     })
    }

    @Test("a token is renewed a minute before it ends — checked, renewed, kept, and only then sent")
    func renewedBeforeItEnds() async throws {
        let log = Log()
        let far = Self.renewal(log, ends: Self.now.addingTimeInterval(61))
        #expect(try await far.token(now: Self.now).revealed == Self.access)
        #expect(log.all.isEmpty, "more than a minute left: nothing asked")
        let due = Self.renewal(log)
        let token = try await due.token(now: Self.now)
        log.add("sent \(token.revealed)")
        #expect(log.all == ["check \(Self.refresh)", "renew \(Self.refresh)",
                            "keep \(Self.refresh) → \(Self.renewedAccess)", "sent \(Self.renewedAccess)"])
        #expect(await due.current.refresh == Secret(Self.renewedRefresh))
        #expect(try await due.token(now: Self.now).revealed == Self.renewedAccess, "renewed once, not again")
        let noEnd = Self.renewal(Log(), ends: nil)
        #expect(try await noEnd.token(now: Self.now.addingTimeInterval(1e7)).revealed == Self.access,
                "a token the host gave no end is sent as it is")
    }

    @Test("one renewal in flight: ten requests that need it wait for the one, and a 401 to the old token gets the new")
    func oneInFlight() async throws {
        let log = Log()
        let renewal = Self.renewal(log, delay: 50_000_000)
        let tokens = try await withThrowingTaskGroup(of: String.self) { group in
            for index in 0 ..< 10 {
                group.addTask {
                    index.isMultiple(of: 2) ? try await renewal.token(now: Self.now).revealed
                        : try await renewal.renewed(after: Secret(Self.access))?.revealed ?? "none"
                }
            }
            var all: [String] = []
            for try await token in group { all.append(token) }
            return all
        }
        #expect(tokens.allSatisfy { $0 == Self.renewedAccess }, "\(tokens)")
        #expect(log.all.filter { $0.hasPrefix("renew") }.count == 1, "\(log.all)")
        #expect(try await renewal.renewed(after: Secret(Self.access))?.revealed == Self.renewedAccess,
                "a 401 to the token renewed meanwhile is answered with the new one, not another renewal")
        #expect(log.all.filter { $0.hasPrefix("renew") }.count == 1)
    }

    @Test("a Keychain that cannot be read first: nothing is asked of the host, and the refresh token stays good")
    func keychainFirst() async throws {
        let log = Log()
        let renewal = Self.renewal(log, checked: "User interaction is not allowed. (-25308)")
        await #expect(throws: ProviderError.keychainUnavailable("User interaction is not allowed. (-25308)")) {
            _ = try await renewal.token(now: Self.now)
        }
        #expect(log.all == ["check \(Self.refresh)"], "never renewed: the old refresh token is not spent")
        #expect(await renewal.current.refresh == Secret(Self.refresh))
    }

    @Test("a renewal the host refuses signs out for good; one that got no answer is tried again")
    func refusedAndUnanswered() async throws {
        let log = Log()
        let refused = Self.renewal(log, renewed: .failure(.refused(status: 400, code: "invalid_grant")))
        await #expect(throws: ProviderError.signedOut) { _ = try await refused.token(now: Self.now) }
        await #expect(throws: ProviderError.signedOut) { _ = try await refused.renewed(after: Secret(Self.access)) }
        await #expect(throws: ProviderError.signedOut) { _ = try await refused.token(now: Self.now.addingTimeInterval(-1e6)) }
        #expect(log.all.filter { $0.hasPrefix("renew") }.count == 1, "signed out: never asked again")
        let offline = Log()
        let unanswered = Self.renewal(offline, renewed: .failure(.unreachable("The Internet connection appears to be offline.")))
        await #expect(throws: ProviderError.unreachable("the host could not be reached: The Internet connection appears to be offline.")) {
            _ = try await unanswered.token(now: Self.now)
        }
        await #expect(throws: ProviderError.self) { _ = try await unanswered.token(now: Self.now) }
        #expect(offline.all.filter { $0.hasPrefix("renew") }.count == 2, "tried again at the next request")
    }

    @Test("a new pair that could not be kept is never sent: the source is signed out")
    func notKeptNotSent() async throws {
        let log = Log()
        let renewal = Self.renewal(log, kept: "the token was changed meanwhile")
        await #expect(throws: ProviderError.signedOut) { _ = try await renewal.token(now: Self.now) }
        #expect(await renewal.current.access == Secret(Self.access), "the new token never became the one sent")
    }

    // MARK: - The requests that carry it

    @Test("sending: a pasted token refused is refused for good; Sign in's is renewed once and sent again")
    func sending() async throws {
        let binding = CredentialBinding(provider: "github", remoteID: 1, apiOrigin: Origin("https://api.github.com")!)
        let pasted = SourceCredential(token: Secret("github_pat_x"), binding: binding, lease: CredentialLease())
        let sent = Log()
        await #expect(throws: ProviderError.unauthorized) {
            _ = try await pasted.sending(now: Self.now) { token -> Int in
                sent.add(token.revealed)
                throw ProviderError.unauthorized
            }
        }
        #expect(sent.all == ["github_pat_x"] && pasted.lease?.ending == .rejected)

        let log = Log()
        var signedIn = SourceCredential(OAuthTokens(access: Secret(Self.access), refresh: Secret(Self.refresh),
                                                    expiresAt: Self.now.addingTimeInterval(3600)),
                                        clientID: "Iv23li5DCUHkd8JfjXwC", binding: binding)
        signedIn.lease = CredentialLease()
        signedIn.renewal = Self.renewal(log, ends: Self.now.addingTimeInterval(3600))
        let answer = try await signedIn.sending(now: Self.now) { token -> String in
            log.add("sent \(token.revealed)")
            if token.revealed == Self.access { throw ProviderError.unauthorized }
            return "read"
        }
        #expect(answer == "read" && signedIn.lease?.ending == nil)
        #expect(log.all == ["sent \(Self.access)", "check \(Self.refresh)", "renew \(Self.refresh)",
                            "keep \(Self.refresh) → \(Self.renewedAccess)", "sent \(Self.renewedAccess)"])
        await #expect(throws: ProviderError.unauthorized) {
            _ = try await signedIn.sending(now: Self.now) { _ -> Int in throw ProviderError.unauthorized }
        }
        #expect(signedIn.lease?.ending == .rejected, "refused again after its renewal: refused for good")

        var out = SourceCredential(signedIn.tokens, clientID: "x", binding: binding)
        out.lease = CredentialLease()
        out.renewal = Self.renewal(Log(), renewed: .failure(.refused(status: 400, code: "invalid_grant")))
        await #expect(throws: ProviderError.signedOut) {
            _ = try await out.sending(now: Self.now) { _ -> Int in 1 }
        }
        #expect(out.lease?.ending == .signedOut)
        await #expect(throws: ProviderError.tokenWithdrawn(.signedOut)) {
            _ = try await out.sending(now: Self.now) { _ -> Int in 1 }
        }
    }

    @Test("a token taken back while it was renewed is not sent, renewed or not; a remembered denial asks no Keychain")
    func takenBackWhileRenewed() async throws {
        let binding = CredentialBinding(provider: "github", remoteID: 1, apiOrigin: Origin("https://api.github.com")!)
        let lease = CredentialLease()
        var credential = SourceCredential(OAuthTokens(access: Secret(Self.access), refresh: Secret(Self.refresh),
                                                      expiresAt: Self.now), clientID: "c", binding: binding)
        credential.lease = lease
        credential.renewal = TokenRenewal(credential.tokens,
                                          renew: { _ throws(SignInError) in
                                              lease.end(.withdrawn)  // Forget pressed while the host answered
                                              return OAuthTokens(access: Secret(Self.renewedAccess), refresh: Secret(Self.renewedRefresh))
                                          },
                                          check: { _ in nil }, keep: { _, _ in nil })
        let sent = Log()
        await #expect(throws: ProviderError.tokenWithdrawn(.withdrawn)) {
            _ = try await credential.sending(now: Self.now) { token -> Int in
                sent.add(token.revealed)
                return 1
            }
        }
        #expect(sent.all.isEmpty, "sent \(sent.all)")
        let refused = CredentialLease()
        var held = SourceCredential(OAuthTokens(access: Secret(Self.access), refresh: Secret(Self.refresh),
                                                expiresAt: Self.now.addingTimeInterval(3600)), clientID: "c", binding: binding)
        held.lease = refused
        let log = Log()
        held.renewal = Self.renewal(log, ends: Self.now.addingTimeInterval(3600))
        await #expect(throws: ProviderError.tokenWithdrawn(.withdrawn)) {
            _ = try await held.sending(now: Self.now) { _ -> Int in
                refused.end(.withdrawn)  // taken back while its request was out
                throw ProviderError.unauthorized
            }
        }
        #expect(log.all.isEmpty, "nothing renewed for a token nobody holds: \(log.all)")

        let store = CredentialTests.FakeStore()
        let vault = CredentialVault(store: store)
        try await vault.keep(SourceCredential(credential.tokens, clientID: "c", binding: Self.binding), for: "s")
        store.fail(CredentialStoreError("denied"))
        #expect(await vault.mayRenew("s", with: Secret(Self.refresh)) == "denied")
        store.fail(nil)
        let reads = store.calls.count
        #expect(await vault.mayRenew("s", with: Secret(Self.refresh)) == "denied", "remembered for the process")
        #expect(store.calls.count == reads, "the Keychain was asked again")
        await vault.tryAgain()
        #expect(await vault.mayRenew("s", with: Secret(Self.refresh)) == nil, "Check now asks it again")
    }

    @Test("GitHub: Sign in's token in Bearer, renewed before it ends and after a 401, only to the API it was bound to")
    func gitHubClient() async throws {
        let api = "signin-api-\(UUID().uuidString.lowercased()).invalid"
        defer { StubAnswers.forget(api) }
        StubAnswers.answer(api) { request in
            request.value(forHTTPHeaderField: "Authorization") == "Bearer \(DeviceSignInTests.renewedAccess)"
                ? (200, Data(#"{"id": 1459487163, "default_branch": "main", "full_name": "iillyyaa1997/udeck-plugins-private"}"#.utf8))
                : (401, Data(#"{"message": "Bad credentials"}"#.utf8))
        }
        let binding = CredentialBinding(provider: "github", remoteID: 1459487163, apiOrigin: Origin("https://\(api)")!,
                                        oauthOrigin: Origin("https://github.com")!)
        let log = Log()
        for ends in [Self.now.addingTimeInterval(30), Self.now.addingTimeInterval(3600)] {
            var credential = SourceCredential(OAuthTokens(access: Secret(Self.access), refresh: Secret(Self.refresh),
                                                          expiresAt: ends), clientID: "Iv23li5DCUHkd8JfjXwC", binding: binding)
            credential.lease = CredentialLease()
            credential.renewal = Self.renewal(log, ends: ends)
            var endpoints = GitHubEndpoints.official
            endpoints.apiBase = URL(string: "https://\(api)")!
            endpoints.repository = "iillyyaa1997/udeck-plugins-private"
            let client = GitHubClient(endpoints: endpoints, udeckVersion: "0.8.2", limits: RateLimitRecorder(),
                                      session: GitHubClient.makeSession(protocolClasses: [StubAnswers.self]),
                                      now: { DeviceSignInTests.now }, addressing: .id(1459487163), credential: credential)
            #expect(try await client.describe().defaultBranch == "main")
            #expect(credential.lease?.ending == nil)
        }
        let asked = StubAnswers.asked(api).map { $0.value(forHTTPHeaderField: "Authorization") ?? "none" }
        #expect(asked == ["Bearer \(Self.renewedAccess)", "Bearer \(Self.access)", "Bearer \(Self.renewedAccess)"],
                "renewed before it ended, then — the other token — after its 401")
        #expect(StubAnswers.asked(api).allSatisfy { $0.url!.path.hasPrefix("/repositories/1459487163") })
    }

    @Test("GitLab: Sign in's token in Bearer, the API, GraphQL and a file each renewed once after a 401")
    func gitLabClient() async throws {
        let stub = GitLabClientTests.Stub("signin")
        defer { stub.forget() }
        stub.answer { request in
            guard request.value(forHTTPHeaderField: "Authorization") == "Bearer \(DeviceSignInTests.renewedAccess)" else {
                return (401, Data(#"{"message": "401 Unauthorized"}"#.utf8))
            }
            if request.url!.path == "/api/graphql" { return (200, Data(#"{"data": {"project": null}}"#.utf8)) }
            if request.url!.path.hasSuffix("/raw") { return (200, Data("{}".utf8)) }
            return (200, GitLabClientTests.project())
        }
        let origin = try #require(Origin(stub.endpoints.apiBase))
        let binding = CredentialBinding(provider: "gitlab", remoteID: GitLabClientTests.project, apiOrigin: origin,
                                        oauthOrigin: Origin("https://gitlab.example.test")!)
        for read in 0 ..< 3 {
            var credential = SourceCredential(OAuthTokens(access: Secret(Self.access), refresh: Secret(Self.refresh),
                                                          expiresAt: Self.now.addingTimeInterval(7200)),
                                              clientID: "id", binding: binding)
            credential.lease = CredentialLease()
            credential.renewal = Self.renewal(Log(), ends: Self.now.addingTimeInterval(7200))
            let client = GitLabClient(endpoints: stub.endpoints, path: "tools/udeck-plugins", remoteID: GitLabClientTests.project,
                                      udeckVersion: "0.8.2", limits: RateLimitRecorder(),
                                      session: GitHubClient.makeSession(protocolClasses: [StubAnswers.self]),
                                      now: { DeviceSignInTests.now }, credential: credential)
            switch read {
            case 0: _ = try await client.describe()
            case 1: _ = try await client.files(at: "plugins/x/manifest.json", commits: [String(repeating: "a", count: 40)])
            default: _ = try await client.file(at: "plugins/x/manifest.json", commit: String(repeating: "a", count: 40))
            }
            #expect(credential.lease?.ending == nil, "read \(read)")
        }
        let asked = StubAnswers.asked(stub.host)
        #expect(asked.allSatisfy { $0.value(forHTTPHeaderField: "PRIVATE-TOKEN") == nil })
        let file = "/api/v4/projects/7/repository/files/plugins/x/manifest.json/raw"
        let (old, new) = ("Bearer \(Self.access)", "Bearer \(Self.renewedAccess)")
        // GraphQL knew no such project, so the batch went on to the files API
        // — with the token its own renewal had already made.
        #expect(asked.map { "\($0.url!.path) \($0.value(forHTTPHeaderField: "Authorization") ?? "none")" } == [
            "/api/v4/projects/7 \(old)", "/api/v4/projects/7 \(new)",
            "/api/graphql \(old)", "/api/graphql \(new)", "\(file) \(new)",
            "\(file) \(old)", "\(file) \(new)",
        ])
    }

    // MARK: - Kept in the Keychain

    static let binding = CredentialBinding(provider: "github", remoteID: 1459487163,
                                           apiOrigin: Origin("https://api.github.com")!,
                                           oauthOrigin: Origin("https://github.com")!)

    static func source(access: String = OwnSource.Access.signIn) -> OwnSource {
        OwnSource(id: "github.com-udeck-plugins-private-12345678", provider: "github", host: "github.com",
                  path: "iillyyaa1997/udeck-plugins-private", remoteID: 1459487163, access: access, addedAt: nil)
    }

    @Test("Sign in's pair is kept whole, handed out only while it was signed in at the origin asked from")
    func keptWhole() async throws {
        let store = CredentialTests.FakeStore()
        let vault = CredentialVault(store: store)
        let ends = Date(timeIntervalSince1970: 1_792_305_700)
        let credential = SourceCredential(OAuthTokens(access: Secret(Self.access), refresh: Secret(Self.refresh),
                                                      expiresAt: ends.addingTimeInterval(0.4)),
                                          clientID: "Iv23li5DCUHkd8JfjXwC", binding: Self.binding)
        try await vault.keep(credential, for: Self.source().id)
        let item = try #require(store.data)
        let object = try JSONSerialization.jsonObject(with: item) as? [String: Any]
        let entry = try #require((object?["tokens"] as? [String: Any])?[Self.source().id] as? [String: Any])
        #expect(entry["kind"] as? String == "oauth" && entry["access"] as? String == Self.access)
        #expect(entry["refresh"] as? String == Self.refresh && entry["clientID"] as? String == "Iv23li5DCUHkd8JfjXwC")
        #expect(entry["expiresAt"] as? String == "2026-10-18T06:41:40Z" && entry["token"] == nil)
        #expect((entry["binding"] as? [String: Any])?["oauthOrigin"] as? String == "https://github.com")

        let fresh = CredentialVault(store: store)
        let found = await fresh.credential(for: Self.source(), apiOrigin: Origin("https://api.github.com")!,
                                           oauthOrigin: Origin("https://github.com")!, requested: false)
        #expect(found == .credential(credential), "the same pair, to the second")
        let lab = await fresh.credential(for: Self.source(), apiOrigin: Origin("https://api.github.com")!,
                                         oauthOrigin: Origin("http://127.0.0.1:8770")!, requested: false)
        #expect(lab == .unbound(Origin("https://github.com")!), "a host map added since sends no refresh token elsewhere")
        let pasted = SourceCredential(token: Secret("github_pat_x"), binding: CredentialTests.github)
        let other = OwnSource(id: "github.com-x-1", provider: "github", host: "github.com", path: "o/r",
                              remoteID: 1412415366, access: OwnSource.Access.token, addedAt: nil)
        try await vault.keep(pasted, for: other.id)
        #expect(await vault.credential(for: other, apiOrigin: Origin("https://api.github.com")!, oauthOrigin: nil,
                                       requested: false) == .credential(pasted), "a pasted token has no OAuth origin to hold")
    }

    @Test("a rotation is read, changed and written — and writes nothing over a pair it did not renew")
    func rotation() async throws {
        let store = CredentialTests.FakeStore()
        let vault = CredentialVault(store: store)
        let id = Self.source().id
        let credential = SourceCredential(OAuthTokens(access: Secret(Self.access), refresh: Secret(Self.refresh),
                                                      expiresAt: Self.now), clientID: "c", binding: Self.binding)
        try await vault.keep(credential, for: id)
        #expect(await vault.mayRenew(id, with: Secret(Self.refresh)) == nil)
        #expect(await vault.mayRenew(id, with: Secret("ghr_another")) == "the token was changed meanwhile")
        let before = store.calls.count
        let renewed = OAuthTokens(access: Secret(Self.renewedAccess), refresh: Secret(Self.renewedRefresh),
                                  expiresAt: Self.now.addingTimeInterval(28800))
        try await vault.rotate(id, from: Secret(Self.refresh), to: renewed)
        #expect(Array(store.calls[before...]) == ["read", "update"], "a fresh read, then one write")
        let found = await CredentialVault(store: store).credential(for: Self.source(), apiOrigin: Origin("https://api.github.com")!,
                                                                   oauthOrigin: Origin("https://github.com")!, requested: false)
        #expect(found == .credential(SourceCredential(renewed, clientID: "c", binding: Self.binding)))
        let kept = store.data
        #expect(await CredentialTests.changeError { () async throws(CredentialVault.ChangeError) in
            try await vault.rotate(id, from: Secret(Self.refresh), to: renewed)
        } == .changed, "the old refresh token is not the one kept any more")
        #expect(store.data == kept, "nothing written over it")
        store.fail(CredentialStoreError("User interaction is not allowed. (-25308)"))
        #expect(await vault.mayRenew(id, with: Secret(Self.renewedRefresh)) == "User interaction is not allowed. (-25308)")
        #expect(await CredentialTests.changeError { () async throws(CredentialVault.ChangeError) in
            try await vault.rotate(id, from: Secret(Self.renewedRefresh), to: credential.tokens)
        } == .unavailable("User interaction is not allowed. (-25308)"))
        #expect(store.data == kept && !store.calls.suffix(2).contains("update"), "a failed fresh read writes nothing")
    }

    @Test("the book takes a renewal under the same lease: a lookup that then reads the new pair keeps it")
    func bookKeepsTheLease() throws {
        var book = SourceTokenBook()
        let id = Self.source().id
        let credential = SourceCredential(OAuthTokens(access: Secret(Self.access), refresh: Secret(Self.refresh),
                                                      expiresAt: Self.now), clientID: "c", binding: Self.binding)
        let ticket = book.ticket(id)
        let first = book.hold(credential, for: ticket)
        let held = try #require(first)
        let renewed = OAuthTokens(access: Secret(Self.renewedAccess), refresh: Secret(Self.renewedRefresh),
                                  expiresAt: Self.now.addingTimeInterval(28800))
        book.renewed(id, from: Secret("ghr_another"), to: renewed)
        #expect(book.credential(of: id)?.token == Secret(Self.access), "not the pair renewed: unchanged")
        book.renewed(id, from: Secret(Self.refresh), to: renewed)
        let now = try #require(book.credential(of: id))
        #expect(now.token == Secret(Self.renewedAccess) && now.lease === held.lease)
        let again = book.ticket(id)
        let looked = book.hold(SourceCredential(renewed, clientID: "c", binding: Self.binding), for: again)
        #expect(looked?.lease === held.lease && held.lease?.ending == nil, "the same lease: no copy loses its token")
    }

    @Test("Look up with Sign in's token: in Bearer, GitHub's 404 says to install the uDeck app, a GitLab's says its token's")
    func lookUpSignedIn() async throws {
        let api = "signin-lookup-\(UUID().uuidString.lowercased()).invalid"
        defer { StubAnswers.forget(api) }
        StubAnswers.answer(api) { _ in (404, Data(#"{"message": "Not Found"}"#.utf8)) }
        var endpoints = GitHubEndpoints.official
        endpoints.apiBase = URL(string: "https://\(api)")!
        let session = GitHubClient.makeSession(protocolClasses: [StubAnswers.self])
        let clients = SourceClients(endpoints: endpoints, udeckVersion: "0.8.2", limits: RateLimitRecorder(), session: session,
                                    hostMap: ["gitlab.example": URL(string: "https://\(api)")!])
        func signedIn(_ provider: String) -> SourceCredential {
            SourceCredential(OAuthTokens(access: Secret(Self.access)), clientID: "c", binding: CredentialBinding(
                provider: provider, remoteID: 0, apiOrigin: Origin("https://\(api)")!, oauthOrigin: Origin("https://github.com")!))
        }
        let github = await SourceLookUp.lookUp(SourceLink(provider: "github", host: "github.com", path: "someone/team-plugins"),
                                               list: SourceList(), official: .official, officialID: nil, clients: clients,
                                               signedIn: signedIn("github"))
        #expect(github == .refused(.sourceSignInAppNotInstalled(owner: "someone", repository: "team-plugins")))
        let gitlab = await SourceLookUp.lookUp(SourceLink(provider: "gitlab", host: "gitlab.example", path: "tools/x"),
                                               list: SourceList(), official: .official, officialID: nil, clients: clients,
                                               signedIn: signedIn("gitlab"))
        #expect(gitlab == .refused(.sourceTokenNotFound(address: "gitlab.example/tools/x")))
        #expect(StubAnswers.asked(api).count == 2
                && StubAnswers.asked(api).allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.access)" })
    }

    // MARK: - sources.json and what is said

    @Test("a GitLab of one's own's application id is kept in sources.json, and only where one was pasted")
    func applicationID() throws {
        var list = SourceList()
        let added = try list.add(provider: "gitlab", host: "gitlab.unicorns.place", path: "tools/udeck-plugins",
                                 remoteID: 48, at: Self.now, signInClientID: " 213e6a78d565 ").get()
        #expect(added.signInClientID == "213e6a78d565")
        _ = try list.add(provider: "gitlab", host: "gitlab.com", path: "g/p", remoteID: 1001, at: Self.now).get()
        let data = try JSONFileStore<SourceList>.encoder.encode(list)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.components(separatedBy: "signInClientID").count == 2, "written once, for the one that has it: \(text)")
        let read = try SourceList.read(data).get()
        #expect(read.sources.map(\.signInClientID) == ["213e6a78d565", nil])
        var changed = read
        let cleared = changed.setSignInClientID(added.id, "not an id!")
        #expect(cleared && changed.sources.first?.signInClientID == nil, "what is no id leaves none")
        let set = changed.setSignInClientID(added.id, "abc")
        #expect(set)
        #expect(changed.sources.first?.signInClientID == "abc")
    }

    @Test("signed out, and each trouble of Sign in, said in words that name the host")
    func said() {
        #expect(CatalogueRefresher.reason(ProviderError.signedOut, branch: nil, tokened: true) == .signedOut)
        #expect(CatalogueRefresher.reason(ProviderError.tokenWithdrawn(.signedOut), branch: nil, tokened: true) == .signedOut)
        #expect(CatalogueRefresher.reason(ProviderError.keychainUnavailable("denied"), branch: nil, tokened: true)
                == .keychainUnavailable(reason: "denied"))
        #expect(CatalogueTrouble.phrase(.signedOut, address: "github.com/o/r", host: "github.com", readAt: nil,
                                        until: { _ in "" }, tokened: true) == .sourceSignedOut(host: "github.com"))
        let english = Strings(.english), russian = Strings(.russian)
        #expect(english(.sourceSignedOut(host: "gitlab.com")) == "Signed out of gitlab.com: sign in again.")
        #expect(russian(.sourceSignedOut(host: "gitlab.com")) == "Вход в gitlab.com завершён: войдите снова.")
        #expect(english(SignInTrouble.phrase(.expired, host: "github.com")) == "The code expired; start again.")
        #expect(russian(SignInTrouble.phrase(.expired, host: "github.com")) == "Код истёк; начните заново.")
        #expect(english(SignInTrouble.phrase(.denied, host: "github.com")) == "Sign-in was declined.")
        #expect(russian(SignInTrouble.phrase(.denied, host: "github.com")) == "Вход отклонён.")
        #expect(english(.sourceSignInAppNotInstalled(owner: "someone", repository: "team-plugins"))
                == "Signed in, but the uDeck app is not installed for someone, so it cannot read team-plugins. Install it on someone, choosing team-plugins.")
        #expect(russian(.sourceSignInAppNotInstalled(owner: "someone", repository: "team-plugins"))
                == "Вход выполнен, но приложение uDeck не установлено у someone, поэтому team-plugins ему недоступен. Установите его у someone, выбрав team-plugins.")
        #expect(english(SignInTrouble.phrase(.refused(status: 400, code: "invalid_client"), host: "gitlab.example"))
                == "gitlab.example refused the sign-in (HTTP 400, invalid_client).")
        #expect(english(.sourceTokenCollaborator(owner: "o", repository: "r", signIn: true)).hasSuffix(
            "use Sign in with GitHub once o installs the uDeck app, or a classic token, which can also write."))
    }
}
