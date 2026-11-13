import Foundation
import Testing
@testable import UDeckCore
import UDeckPluginFormatFixtures

/// How a token is sent (S4-19): to its own origin only, never to the raw
/// host, never through another repository's client or the official one,
/// never across a redirect — and no error of a request that carried one
/// quotes the answer.
@Suite("Tokens on the wire: own origin only, never redirected")
struct RedirectTests {
    static let token = "github_pat_the-labs-own-fixture-value"
    static let number = 1412415366

    static func endpoints(_ host: String) -> GitHubEndpoints {
        GitHubEndpoints(apiBase: URL(string: "https://\(host)/api")!, rawBase: URL(string: "https://\(host)/raw")!,
                        repository: "someone/private-plugins")
    }

    static func credential(_ host: String, token: String = token) -> SourceCredential {
        SourceCredential(token: Secret(token), binding: CredentialBinding(provider: "github", remoteID: number,
                                                                          apiOrigin: Origin("https://\(host)")!))
    }

    static func client(_ host: String, credential: SourceCredential?, addressing: GitHubClient.Addressing = .id(number),
                       session: URLSession? = nil) -> GitHubClient {
        GitHubClient(endpoints: endpoints(host), udeckVersion: "0.8.0", limits: RateLimitRecorder(),
                     session: session ?? GitHubClient.makeSession(protocolClasses: [StubAnswers.self]),
                     addressing: addressing, credential: credential)
    }

    static func host(_ name: String) -> String { "\(name)-\(UUID().uuidString.lowercased()).invalid" }

    // MARK: - GitHub

    @Test("with a token every request is the API's, Bearer to its own origin — files through contents with raw media, no raw host")
    func githubWithAToken() async throws {
        let host = Self.host("token")
        let commit = String(repeating: "a", count: 40)
        StubAnswers.answer(host) { request in
            switch request.url?.path {
            case "/api/repositories/\(Self.number)/commits/main": (200, Data(commit.utf8))
            case "/api/repositories/\(Self.number)/contents/plugins/team clock/manifest.json": (200, Data("{}".utf8))
            default: (404, Data())
            }
        }
        defer { StubAnswers.forget(host) }
        let client = Self.client(host, credential: Self.credential(host))
        #expect(try await client.head(of: "main", ifNoneMatch: nil) == .commit(commit, etag: nil))
        #expect(try await client.file(at: "plugins/team clock/manifest.json", commit: commit) == Data("{}".utf8))
        let asked = StubAnswers.asked(host)
        #expect(asked.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.token)" })
        #expect(asked.map { $0.url?.path ?? "" } == ["/api/repositories/\(Self.number)/commits/main",
                                                    "/api/repositories/\(Self.number)/contents/plugins/team clock/manifest.json"])
        let file = try #require(asked.last)
        #expect(file.value(forHTTPHeaderField: "Accept") == "application/vnd.github.raw+json")
        #expect(URLComponents(url: file.url!, resolvingAgainstBaseURL: false)?.query == "ref=\(commit)")
        #expect(!asked.contains { $0.url?.path.hasPrefix("/raw/") == true }, "never the raw host")
    }

    @Test("a token checked with another origin is never sent: not to another host, nor over plain HTTP")
    func githubElsewhere() async throws {
        let host = Self.host("elsewhere")
        StubAnswers.answer(host) { _ in (200, Data()) }
        defer { StubAnswers.forget(host) }
        let checkedElsewhere = Self.client(host, credential: Self.credential("api.github.com"))
        await #expect(throws: ProviderError.credentialUnbound) {
            _ = try await checkedElsewhere.describe()
        }
        let plain = SourceCredential(token: Secret(Self.token), binding: CredentialBinding(
            provider: "github", remoteID: Self.number, apiOrigin: Origin("http://\(host)")!))
        var endpoints = Self.endpoints(host)
        endpoints.apiBase = URL(string: "http://\(host)/api")!
        let overHTTP = GitHubClient(endpoints: endpoints, udeckVersion: "0.8.0", limits: RateLimitRecorder(),
                                    session: GitHubClient.makeSession(protocolClasses: [StubAnswers.self]),
                                    addressing: .id(Self.number), credential: plain)
        await #expect(throws: ProviderError.credentialUnbound) {
            _ = try await overHTTP.describe()
        }
        #expect(StubAnswers.asked(host).isEmpty, "nothing was sent")
    }

    @Test("the official client — addressed by its path — and another repository's never carry a token")
    func neverTheOfficialNorAnother() async throws {
        let host = Self.host("official")
        StubAnswers.answer(host) { _ in (200, Data(#"{"default_branch": "main", "full_name": "someone/private-plugins"}"#.utf8)) }
        defer { StubAnswers.forget(host) }
        let official = Self.client(host, credential: Self.credential(host), addressing: .path)
        #expect(official.credential == nil)
        _ = try await official.describe()
        #expect(StubAnswers.asked(host).allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil })
        let source = Self.client(host, credential: Self.credential(host))
        #expect(source.client(for: RepositoryAddress(path: "someone/other")) == nil, "never another repository's files")
        #expect(source.client(for: RepositoryAddress(path: "Someone/Private-Plugins"))?.credential != nil, "its own, any case")
        #expect(source.renamed(to: "someone/renamed")?.credential == Self.credential(host), "the same repository, by number")
    }

    @Test("401, 403, 404 and a 3xx with a token: unauthorized, refused, not found, moved — said as the token's")
    func statuses() async throws {
        for (status, wanted) in [(401, ProviderError.unauthorized), (403, .refused(status: 403)), (404, .notFound),
                                 (301, .moved(status: 301)), (308, .moved(status: 308))] {
            let host = Self.host("status")
            StubAnswers.answer(host) { _ in (status, Data(#"{"message": "\#(Self.token)"}"#.utf8)) }
            defer { StubAnswers.forget(host) }
            await #expect(throws: wanted, "\(status)") {
                _ = try await Self.client(host, credential: Self.credential(host)).describe()
            }
        }
        #expect(CatalogueRefresher.reason(ProviderError.unauthorized, branch: nil, tokened: true) == .unauthorized)
        #expect(CatalogueRefresher.reason(ProviderError.unauthorized, branch: nil) == .refused(status: 401))
        #expect(CatalogueRefresher.reason(ProviderError.forbidden(scope: "read_api"), branch: nil, tokened: true)
                == .forbidden(scope: "read_api"))
        #expect(CatalogueRefresher.reason(ProviderError.forbidden(scope: "read_api"), branch: nil) == .refused(status: 403))
        #expect(CatalogueRefresher.reason(ProviderError.moved(status: 301), branch: nil, tokened: true) == .moved(status: 301))
        #expect(CatalogueRefresher.reason(ProviderError.moved(status: 301), branch: nil) == .refused(status: 301))
        #expect(CatalogueRefresher.reason(ProviderError.credentialUnbound, branch: nil) == .credentialUnbound(origin: nil))
    }

    @Test("no error of a request that carried a token quotes its answer")
    func noBodyQuoted() async throws {
        let host = Self.host("quote")
        StubAnswers.answer(host) { request in
            switch request.url?.path {
            case let path? where path.hasSuffix("/commits/main"): (200, Data("not a commit \(Self.token)".utf8))
            default: (200, Data("{\"tree\": \"\(Self.token)\"}".utf8))
            }
        }
        defer { StubAnswers.forget(host) }
        let client = Self.client(host, credential: Self.credential(host))
        for ask in [{ _ = try await client.head(of: "main", ifNoneMatch: nil) },
                    { _ = try await client.tree(String(repeating: "b", count: 40), recursive: true) }] as [() async throws -> Void] {
            do {
                try await ask()
                Issue.record("a garbled answer was read")
            } catch {
                #expect(!"\(error)".contains(Self.token) && !"\(error)".contains(": not a commit"), "\(error)")
            }
        }
        // Without a token the head's few characters are still said, as before.
        let anonymous = Self.client(host, credential: nil)
        do {
            _ = try await anonymous.head(of: "main", ifNoneMatch: nil)
        } catch ProviderError.badAnswer(let reason) {
            #expect(reason.contains(": not a commit"), "\(reason)")
        }
    }

    // MARK: - Redirects

    /// A host whose every answer to `from` is a `301` to `to` on another
    /// host, answered there with `body`; the second host's requests counted.
    final class Moving: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var asked: [URLRequest] = []
        static let lock = NSLock()
        static let from = "moving.invalid", to = "elsewhere.invalid"

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            Self.lock.withLock { Self.asked.append(request) }
            let url = request.url!
            if url.host == Self.from {
                var moved = URLComponents(url: url, resolvingAgainstBaseURL: false)!
                moved.host = Self.to
                let response = HTTPURLResponse(url: url, statusCode: 301, httpVersion: "HTTP/1.1",
                                               headerFields: ["Location": moved.url!.absoluteString])!
                client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: moved.url!), redirectResponse: response)
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocolDidFinishLoading(self)
                return
            }
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(#"{"id": 1412415366, "default_branch": "main", "full_name": "x/y"}"#.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    /// Whether a session *without* the delegate follows a redirect a custom
    /// `URLProtocol` raises is the loading system's business, and differs by
    /// macOS (it followed on macOS 27, not on the CI runner's — run
    /// 42331797308): only the refusal, which is uDeck's, is held here.
    @Test("a request carrying a token refuses the redirect — the move comes back, and nothing reaches the new host")
    func notAcrossARedirect() async throws {
        Moving.lock.withLock { Moving.asked = [] }
        let session = GitHubClient.makeSession(protocolClasses: [Moving.self])
        let tokened = Self.client(Moving.from, credential: Self.credential(Moving.from), session: session)
        await #expect(throws: ProviderError.moved(status: 301)) {
            _ = try await tokened.describe()
        }
        let reachedTheNewHost = Moving.lock.withLock { Moving.asked.filter { $0.url?.host == Moving.to } }
        #expect(reachedTheNewHost.isEmpty, "the token went to \(reachedTheNewHost.map { $0.url!.absoluteString })")
        #expect(await RedirectRefusal.shared.urlSession(session, task: session.dataTask(with: URL(string: "https://x.invalid")!),
                                                        willPerformHTTPRedirection: HTTPURLResponse(),
                                                        newRequest: URLRequest(url: URL(string: "https://y.invalid")!)) == nil)
    }

    // MARK: - GitLab

    @Test("GitLab: a pasted token in PRIVATE-TOKEN, one from Sign in in Bearer — GraphQL too — and never to another origin")
    func gitlab() async throws {
        let stub = GitLabClientTests.Stub("gltoken")
        stub.answer { request in
            request.url!.path == "/api/graphql" ? (200, Data(#"{"data": {"project": null}}"#.utf8)) : (200, GitLabClientTests.project())
        }
        defer { stub.forget() }
        let origin = try #require(Origin(stub.endpoints.apiBase))
        for (kind, name, value) in [(SourceCredential.Kind.pat, "PRIVATE-TOKEN", "glpat-x"),
                                    (.oauth, "Authorization", "Bearer glpat-x")] {
            let credential = SourceCredential(kind: kind, token: Secret("glpat-x"), binding: CredentialBinding(
                provider: "gitlab", remoteID: GitLabClientTests.project, apiOrigin: origin))
            let client = GitLabClient(endpoints: stub.endpoints, path: "tools/udeck-plugins", remoteID: GitLabClientTests.project,
                                      udeckVersion: "0.8.0", limits: RateLimitRecorder(),
                                      session: GitHubClient.makeSession(protocolClasses: [StubAnswers.self]), credential: credential)
            _ = try await client.describe()
            _ = try await client.files(at: "plugins/x/manifest.json", commits: [String(repeating: "a", count: 40)])
            let asked = StubAnswers.asked(stub.host).suffix(3)
            #expect(asked.allSatisfy { $0.value(forHTTPHeaderField: name) == value }, "\(kind)")
            #expect(asked.contains { $0.url?.path == "/api/graphql" })
        }
        let checkedElsewhere = SourceCredential(token: Secret("glpat-x"), binding: CredentialBinding(
            provider: "gitlab", remoteID: GitLabClientTests.project, apiOrigin: Origin("https://gitlab.com")!))
        let before = StubAnswers.asked(stub.host).count
        let client = GitLabClient(endpoints: stub.endpoints, path: "tools/udeck-plugins", remoteID: GitLabClientTests.project,
                                  udeckVersion: "0.8.0", limits: RateLimitRecorder(),
                                  session: GitHubClient.makeSession(protocolClasses: [StubAnswers.self]), credential: checkedElsewhere)
        await #expect(throws: ProviderError.credentialUnbound) {
            _ = try await client.describe()
        }
        #expect(StubAnswers.asked(stub.host).count == before, "nothing sent")
    }

    @Test("GitLab with a token: a scope GitLab names is said; anything else in its place — a token echoed back — is not")
    func scopeNeverQuoted() async throws {
        for (scope, wanted) in [("read_api", ProviderError.forbidden(scope: "read_api")),
                                // As GitLab says it: every scope that would do, joined by spaces.
                                ("api read_api", .forbidden(scope: "read_api")), ("read_api api", .forbidden(scope: "read_api")),
                                ("api read_user", .forbidden(scope: "api")),
                                ("api glpat-the-token-echoed", .forbidden(scope: nil)),
                                ("glpat-the-token-echoed", .forbidden(scope: nil)), ("", .forbidden(scope: nil))] {
            let stub = GitLabClientTests.Stub("scope")
            stub.answer { _ in (403, Data(#"{"error": "insufficient_scope", "scope": "\#(scope)"}"#.utf8)) }
            defer { stub.forget() }
            let origin = try #require(Origin(stub.endpoints.apiBase))
            let client = GitLabClient(endpoints: stub.endpoints, path: "tools/udeck-plugins", remoteID: GitLabClientTests.project,
                                      udeckVersion: "0.8.0", limits: RateLimitRecorder(),
                                      session: GitHubClient.makeSession(protocolClasses: [StubAnswers.self]),
                                      credential: SourceCredential(token: Secret("glpat-the-token-echoed"), binding: CredentialBinding(
                                          provider: "gitlab", remoteID: GitLabClientTests.project, apiOrigin: origin)))
            do {
                _ = try await client.describe()
                Issue.record("a 403 was read")
            } catch {
                #expect(error as? ProviderError == wanted, "\(scope)")
                #expect(!"\(error)".contains("glpat-"), "\(error)")
            }
        }
    }

    @Test("with a token, GraphQL's refusal of it is the read's answer: the files API is not asked, the token not sent again")
    func graphQLRefusalWithAToken() async throws {
        for (status, wanted) in [(401, ProviderError.unauthorized), (302, .moved(status: 302))] {
            let stub = GitLabClientTests.Stub("glrefused")
            stub.answer { _ in (status, Data("{}".utf8)) }
            defer { stub.forget() }
            let origin = try #require(Origin(stub.endpoints.apiBase))
            let tokened = GitLabClient(endpoints: stub.endpoints, path: "tools/udeck-plugins", remoteID: GitLabClientTests.project,
                                       udeckVersion: "0.8.0", limits: RateLimitRecorder(),
                                       session: GitHubClient.makeSession(protocolClasses: [StubAnswers.self]),
                                       credential: SourceCredential(token: Secret("glpat-x"), binding: CredentialBinding(
                                           provider: "gitlab", remoteID: GitLabClientTests.project, apiOrigin: origin)))
            await #expect(throws: wanted, "\(status)") {
                _ = try await tokened.files(at: "plugins/x/manifest.json", commits: [String(repeating: "a", count: 40)])
            }
            #expect(stub.asked == ["/api/graphql"], "\(status): nothing more was sent — \(stub.asked)")
        }
        // Without a token, GraphQL refusing is GraphQL not answering here: the files API is asked, as before.
        let stub = GitLabClientTests.Stub("glanonymous")
        stub.answer { _ in (401, Data("{}".utf8)) }
        defer { stub.forget() }
        await #expect(throws: ProviderError.unauthorized) {
            _ = try await stub.client().files(at: "plugins/x/manifest.json", commits: [String(repeating: "a", count: 40)])
        }
        #expect(stub.asked.count == 2 && stub.asked.last?.hasPrefix("/api/v4/projects/7/repository/files/") == true)
    }

    @Test("a refresher whose reads carry the token keeps a 401 as the token's; one without, as the refusal it is")
    func refresherKeepsWhatTheTokenGot() async throws {
        for tokened in [true, false] {
            let stub = GitLabClientTests.Stub("refresher")
            stub.answer { _ in (401, Data(#"{"message": "401 Unauthorized"}"#.utf8)) }
            defer { stub.forget() }
            let temp = TemporaryDirectory()
            let store = CatalogueStore(directory: temp.url.appendingPathComponent("catalogue/gl", isDirectory: true))
            let refresher = CatalogueRefresher(provider: stub.client(), store: store, limits: RateLimitRecorder(), tokened: tokened)
            _ = await refresher.refresh(unrequested: false, language: "en")
            #expect(store.state().lastError == (tokened ? .unauthorized : .refused(status: 401)), "tokened \(tokened)")
        }
    }

    // MARK: - A source's clients

    @Test("a source's provider with its token: GitHub's with a limit of its own; each source's API origin as this build reads it")
    func sourceClients() throws {
        let limits = RateLimitRecorder()
        var clients = SourceClients(endpoints: .official, udeckVersion: "0.8.0", limits: limits,
                                    hostMap: ["gitlab.example.test": URL(string: "http://127.0.0.1:8768")!])
        let own = RateLimitRecorder()
        clients.tokenLimits = ["github.com-team-00000000": own]
        let source = OwnSource(id: "github.com-team-00000000", provider: "github", host: "github.com",
                               path: "someone/team-plugins", remoteID: 5, access: OwnSource.Access.token, addedAt: nil)
        #expect(clients.limits(of: source) === limits && clients.limits(of: source, tokened: true) === own)
        #expect(clients.apiOrigin(of: source) == Origin("https://api.github.com"))
        let project = OwnSource(id: "gitlab.example.test-x-00000000", provider: "gitlab", host: "gitlab.example.test",
                                path: "tools/x", remoteID: 11, addedAt: nil)
        #expect(clients.apiOrigin(of: project) == Origin("http://127.0.0.1:8768"), "after the host map: where requests go")
        let credential = SourceCredential(token: Secret("t"), binding: CredentialBinding(
            provider: "github", remoteID: 5, apiOrigin: Origin("https://api.github.com")!))
        let provider = try #require(clients.of(source, credential: credential))
        #expect(provider.remoteID == 5)
        #expect(clients.of(source)?.remoteID == 5)
    }

    // MARK: - What is said

    @Test("what a read with a token says: items 2 to 6, 8, 14 and 18, each naming its host and address")
    func phrases() {
        func said(_ error: CatalogueError, tokened: Bool = true, provider: String = "github", host: String = "GitHub") -> Phrase {
            CatalogueTrouble.phrase(error, address: "github.com/o/r", host: host, readAt: "14:02", until: { _ in "15:07" },
                                    provider: provider, tokened: tokened)
        }
        #expect(said(.notFound) == .sourceTokenNotFound(address: "github.com/o/r"))
        #expect(said(.notFound, tokened: false, host: "gitlab.example") == .sourceNotFound(address: "github.com/o/r"))
        #expect(said(.unauthorized) == .sourceTokenRejected(host: "GitHub", address: "github.com/o/r"))
        #expect(said(.forbidden(scope: "read_api"), host: "gitlab.example")
                == .sourceTokenScope(address: "github.com/o/r", host: "gitlab.example", scope: "read_api"))
        #expect(said(.forbidden(scope: nil)) == .sourceTokenRefused(host: "GitHub", address: "github.com/o/r", status: 403))
        #expect(said(.refused(status: 403)) == .sourceTokenRefused(host: "GitHub", address: "github.com/o/r", status: 403))
        #expect(said(.refused(status: 403), tokened: false) == .catalogueRefused(status: 403, host: "GitHub"))
        #expect(said(.moved(status: 301)) == .sourceMoved(address: "github.com/o/r"))
        let until = Date(timeIntervalSince1970: 1)
        #expect(said(.rateLimited(until: until)) == .sourceTokenLimited(address: "github.com/o/r", readAt: "14:02", until: "15:07"))
        #expect(said(.rateLimited(until: until), tokened: false) == .catalogueLimited(readAt: "14:02", until: "15:07"))
        #expect(said(.rateLimited(until: until), provider: "gitlab", host: "gitlab.com")
                == .sourceGitLabLimited(host: "gitlab.com", readAt: "14:02", until: "15:07", anonymousGitLabCom: false),
                "gitlab.com read with a token: no word of what a token would change")
        #expect(said(.keychainUnavailable(reason: "denied"))
                == .sourceKeychainUnavailable(address: "github.com/o/r", reason: "denied"))
        #expect(said(.credentialUnbound(origin: "https://gitlab.com"))
                == .sourceTokenUnbound(address: "github.com/o/r", origin: "https://gitlab.com"))
        let english = Strings(.english), russian = Strings(.russian)
        #expect(english(.sourceTokenRejected(host: "gitlab.example", address: "gitlab.example/g/p"))
                == "gitlab.example did not accept the token for gitlab.example/g/p: it is wrong, has expired or was revoked. uDeck sends nothing more with it; paste a new one under Token…")
        #expect(russian(.sourceMoved(address: "github.com/o/r"))
                == "github.com/o/r сообщает, что переехал. uDeck не передаёт токен по другому адресу: удалите этот источник и добавьте его по новому адресу.")
        #expect(english(.sourceTokenUnbound(address: "a/b", origin: nil)).contains("checked with another address"))
    }
}
