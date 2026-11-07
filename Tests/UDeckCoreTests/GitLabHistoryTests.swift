import Foundation
import Testing
@testable import UDeckCore
import UDeckPluginFormatFixtures

/// A plugin's earlier versions on GitLab: a dozen manifests to a GraphQL
/// request, held to the project's number and to each blob's id, the files API
/// for whatever GraphQL does not answer — and, on any host, a read after the
/// head moved asking only about the commits it brought (`VersionIndex`).
@Suite("Earlier versions: a dozen manifests to a request on GitLab, and only new commits asked about")
struct GitLabHistoryTests {
    typealias Stub = GitLabClientTests.Stub

    static let path = "plugins/gl-hello/manifest.json"

    static func commit(_ n: Int) -> String {
        let hex = String(n, radix: 16)
        return String(repeating: "0", count: 40 - hex.count) + hex
    }

    static func manifest(_ version: String) -> Data {
        Data(#"{ "id": "gl-hello", "name": "Hello", "version": "\#(version)", "api": 1, "kind": "poll", "run": ["./run.sh"], "interval": 60, "timeout": 5 }"#.utf8)
    }

    /// A request's body: what URLSession hands a protocol as a stream.
    static func body(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }

    /// What GitLab's GraphQL was asked, request by request: the commits, in order.
    final class Asked: @unchecked Sendable {
        private let lock = NSLock()
        private var batches: [[String]] = []
        private var bodies: [[String: Any]] = []
        func add(_ commits: [String], _ body: [String: Any]) { lock.withLock { batches.append(commits); bodies.append(body) } }
        var commits: [[String]] { lock.withLock { batches } }
        var last: [String: Any]? { lock.withLock { bodies.last } }
    }

    /// GitLab's GraphQL, as gitlab.com answers the query `GitLabClient`
    /// sends (**measured**): `files` by commit — a commit not there answers
    /// no blob — weighed at 14 a commit and 3 for the project against
    /// `ceiling`; the project's `id` as `project` says.
    static func graphQL(_ request: URLRequest, files: [String: Data], asked: Asked, ceiling: Int = 200,
                        project: String? = "gid://gitlab/Project/7",
                        text: (String, Data) -> (oid: String, text: String?)? = { _, data in
                            (GitHash.blob(data), String(decoding: data, as: UTF8.self))
                        }) -> (Int, Data) {
        guard let body = try? JSONSerialization.jsonObject(with: Self.body(request)) as? [String: Any],
              let query = body["query"] as? String, let variables = body["variables"] as? [String: Any] else {
            return (400, Data(#"{"errors":[{"message":"no query"}]}"#.utf8))
        }
        let count = query.components(separatedBy: ": blobs(").count - 1
        let commits = (0 ..< count).compactMap { variables["r\($0)"] as? String }
        asked.add(commits, body)
        let complexity = 14 * count + 3
        if complexity > ceiling {
            let message = "Query has complexity of \(complexity), which exceeds max complexity of \(ceiling)"
            return (200, try! JSONSerialization.data(withJSONObject: ["errors": [["message": message]]]))
        }
        guard let project else { return (200, Data(#"{"data":{"project":null}}"#.utf8)) }
        var repository: [String: Any] = [:]
        for (index, commit) in commits.enumerated() {
            guard let data = files[commit], let given = text(commit, data) else {
                repository["c\(index)"] = ["nodes": []]
                continue
            }
            repository["c\(index)"] = ["nodes": [["oid": given.oid, "rawTextBlob": given.text as Any]]]
        }
        let answer: [String: Any] = ["data": ["project": ["id": project, "repository": repository]]]
        return (200, try! JSONSerialization.data(withJSONObject: answer))
    }

    /// The files API's answer for one file at one commit, by the project's number.
    static func filesAPI(_ request: URLRequest, files: [String: Data]) -> (Int, Data)? {
        let encoded = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? ""
        guard encoded == "/api/v4/projects/7/repository/files/plugins%2Fgl-hello%2Fmanifest.json/raw",
              let ref = GitLabClientTests.query(request, "ref") else { return nil }
        return files[ref].map { (200, $0) } ?? (404, Data(#"{"message":"404 File Not Found"}"#.utf8))
    }

    static func versions(_ commits: [String]) -> [String: Data] {
        var files: [String: Data] = [:]
        for (index, commit) in commits.enumerated() where index % 7 != 3 {
            files[commit] = manifest("1.\(index).0")
        }
        return files
    }

    // MARK: - GraphQL

    @Test("thirty commits: three GraphQL requests of a dozen at most, by the project's path, each file hashed to its blob")
    func aDozenToARequest() async throws {
        let commits = (1 ... 30).map(Self.commit)
        let files = Self.versions(commits)
        let asked = Asked()
        let stub = Stub("dozen")
        stub.answer { request in
            request.url!.path == "/api/graphql" ? Self.graphQL(request, files: files, asked: asked) : (404, Data())
        }
        defer { stub.forget() }
        let found = try await stub.client().files(at: Self.path, commits: commits)
        #expect(found == files, "every manifest there, and none where the folder was not")
        #expect(asked.commits == [Array(commits[0 ..< 12]), Array(commits[12 ..< 24]), Array(commits[24 ..< 30])])
        #expect(stub.asked == ["/api/graphql", "/api/graphql", "/api/graphql"], "nothing of the files API")
        let request = try #require(StubAnswers.asked(stub.host).first)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "uDeck/0.8.0")
        #expect(request.value(forHTTPHeaderField: "PRIVATE-TOKEN") == nil && request.value(forHTTPHeaderField: "Authorization") == nil)
        let variables = try #require(asked.last?["variables"] as? [String: Any])
        #expect(variables["path"] as? String == "tools/udeck-plugins")
        #expect(variables["paths"] as? [String] == [Self.path])
        let query = try #require(asked.last?["query"] as? String)
        #expect(query.contains("project(fullPath: $path) { id repository {"), "\(query)")
        #expect(!query.contains(commits[24]), "commits travel as variables, never in the query's text")
    }

    @Test("another project at the path — not the source's number — or none: its files are asked of the files API, by the number")
    func anotherProjectAtThePath() async throws {
        for project in ["gid://gitlab/Project/99", nil] as [String?] {
            let commits = (1 ... 3).map(Self.commit)
            let files = Self.versions(commits)
            let asked = Asked()
            let stub = Stub("another")
            stub.answer { request in
                if request.url!.path == "/api/graphql" {
                    return Self.graphQL(request, files: [commits[0]: Self.manifest("6.6.6")], asked: asked, project: project)
                }
                return Self.filesAPI(request, files: files) ?? (404, Data())
            }
            defer { stub.forget() }
            let found = try await stub.client().files(at: Self.path, commits: commits)
            #expect(found == files, "what the project by its number has, not what the path answered — \(project ?? "none")")
            #expect(stub.asked.filter { $0 == "/api/graphql" }.count == 1, "GraphQL once; the rest by the number")
            #expect(stub.asked.filter { $0.hasPrefix("/api/v4/projects/7/repository/files/") }.count == 3)
        }
    }

    @Test("a GitLab whose ceiling is lower says it, and is asked for as many as fit")
    func aLowerCeiling() async throws {
        let commits = (1 ... 14).map(Self.commit)
        let files = Self.versions(commits)
        let asked = Asked()
        let stub = Stub("ceiling")
        stub.answer { request in
            request.url!.path == "/api/graphql" ? Self.graphQL(request, files: files, asked: asked, ceiling: 100) : (404, Data())
        }
        defer { stub.forget() }
        let found = try await stub.client().files(at: Self.path, commits: commits)
        #expect(found == files)
        #expect(asked.commits.map(\.count) == [12, 6, 6, 2], "refused at a dozen, then (100 - 3) / 14 = 6 at a time")
        #expect(GitLabClient.complexityCeiling("Query has complexity of 227, which exceeds max complexity of 200") == 200)
        #expect(GitLabClient.complexityCeiling("Something else entirely") == nil)
        #expect(GitLabClient.fitting(200) == 14 && GitLabClient.fitting(10) == 1)
    }

    @Test("no GraphQL here — a 404, a refusal, an answer that is not JSON: the files API, one by one, and GraphQL not asked again")
    func noGraphQL() async throws {
        for (status, body) in [(404, #"{"message":"404 Not Found"}"#), (403, "{}"), (200, "<html>no</html>"),
                               (200, #"{"errors":[{"message":"Field 'blobs' doesn't exist on type 'Repository'"}]}"#)] {
            let commits = (1 ... 20).map(Self.commit)
            let files = Self.versions(commits)
            let stub = Stub("none")
            stub.answer { request in
                request.url!.path == "/api/graphql" ? (status, Data(body.utf8)) : (Self.filesAPI(request, files: files) ?? (404, Data()))
            }
            defer { stub.forget() }
            let found = try await stub.client().files(at: Self.path, commits: commits)
            #expect(found == files, "\(status) \(body)")
            #expect(stub.asked.filter { $0 == "/api/graphql" }.count == 1, "\(status) \(body): asked once, then the files API")
        }
    }

    @Test("a file whose text does not hash to its blob, or that has no text: that commit alone from the files API")
    func notTheBlob() async throws {
        let commits = (1 ... 4).map(Self.commit)
        let files = Self.versions(commits)
        let asked = Asked()
        let stub = Stub("blob")
        let oversized = String(repeating: " ", count: RepositoryRules.maximumFileBytes + 1)
        stub.answer { request in
            if request.url!.path == "/api/graphql" {
                return Self.graphQL(request, files: files, asked: asked) { commit, data in
                    switch commit {
                    case commits[0]: (GitHash.blob(data), "{ \"altered\": true }")
                    case commits[1]: (GitHash.blob(data), nil)
                    // Past 5 MB and not its blob either: no answer about it, rather than one left out for its size.
                    case commits[2]: (GitHash.blob(data), oversized)
                    default: (GitHash.blob(data), String(decoding: data, as: UTF8.self))
                    }
                }
            }
            return Self.filesAPI(request, files: files) ?? (404, Data())
        }
        defer { stub.forget() }
        let found = try await stub.client().files(at: Self.path, commits: commits)
        #expect(found == files)
        #expect(stub.asked.filter { $0.hasPrefix("/api/v4/projects/7/repository/files/") }.count == 3,
                "the three GraphQL gave nothing usable for: \(stub.asked)")
    }

    @Test("a manifest past 5 MB in GraphQL's answer is left out, as the files API would refuse it")
    func pastFiveMegabytes() async throws {
        let commits = [Self.commit(1), Self.commit(2)]
        let big = Data(repeating: 0x20, count: RepositoryRules.maximumFileBytes + 1)
        let files = [commits[0]: Self.manifest("1.0.0"), commits[1]: big]
        let asked = Asked()
        let stub = Stub("big")
        stub.answer { request in
            request.url!.path == "/api/graphql" ? Self.graphQL(request, files: files, asked: asked) : (404, Data())
        }
        defer { stub.forget() }
        let found = try await stub.client().files(at: Self.path, commits: commits)
        #expect(found == [commits[0]: Self.manifest("1.0.0")])
        #expect(stub.asked == ["/api/graphql"], "and not asked of the files API either")
    }

    @Test("an answer past 8 MB is not read on: that dozen is asked of the files API, one file at a time")
    func anAnswerPastEightMegabytes() async throws {
        let commits = [Self.commit(1), Self.commit(2)]
        // Two manifests of 4.5 MB each: each a plugin's file may be, together more than GraphQL's answer is read to.
        let large = Data(repeating: 0x20, count: 4_500_000)
        let files = [commits[0]: large, commits[1]: large + Data("\n".utf8)]
        let asked = Asked()
        let stub = Stub("eight")
        stub.answer { request in
            request.url!.path == "/api/graphql" ? Self.graphQL(request, files: files, asked: asked)
                : (Self.filesAPI(request, files: files) ?? (404, Data()))
        }
        defer { stub.forget() }
        let found = try await stub.client().files(at: Self.path, commits: commits)
        #expect(found == files)
        #expect(stub.asked.filter { $0 == "/api/graphql" }.count == 1)
        #expect(stub.asked.filter { $0.hasPrefix("/api/v4/projects/7/repository/files/") }.count == 2)
        #expect(GitLabClient.mostAnswered == 8 * 1024 * 1024)
    }

    @Test("one by one, a manifest the files API says is past 5 MB leaves its commit out, and the rest are read")
    func oneByOnePastFiveMegabytes() async throws {
        let commits = (1 ... 3).map(Self.commit)
        let files = Self.versions(commits)
        let stub = Stub("oneByOne")
        stub.answer { request in
            request.url!.path == "/api/graphql" ? (404, Data(#"{"message":"404 Not Found"}"#.utf8))
                : (Self.filesAPI(request, files: files) ?? (404, Data()))
        }
        stub.headers { request in
            GitLabClientTests.query(request, "ref") == commits[0] ? ["X-Gitlab-Size": "6291456"] : [:]
        }
        defer { stub.forget() }
        let found = try await stub.client().files(at: Self.path, commits: commits)
        #expect(found == files.filter { $0.key != commits[0] }, "the commit past 5 MB left out, the others read")
    }

    @Test("the limit ends the read: a 429 from GraphQL is not passed on to the files API")
    func theLimit() async throws {
        let stub = Stub("limit")
        stub.answer { _ in (429, Data(#"{"message":"Retry later"}"#.utf8)) }
        stub.headers { _ in ["Retry-After": "60"] }
        defer { stub.forget() }
        do {
            _ = try await stub.client().files(at: Self.path, commits: (1 ... 3).map(Self.commit))
            Issue.record("a 429 read on")
        } catch ProviderError.rateLimited {
            #expect(stub.asked == ["/api/graphql"])
        }
    }

    @Test("a GitLab source's provider asks GitLab's way: the dozen to a request reaches through SourceProvider")
    func throughTheSourceProvider() async throws {
        let commits = (1 ... 5).map(Self.commit)
        let files = Self.versions(commits)
        let asked = Asked()
        let stub = Stub("source")
        stub.answer { request in
            request.url!.path == "/api/graphql" ? Self.graphQL(request, files: files, asked: asked) : (404, Data())
        }
        defer { stub.forget() }
        let provider = SourceProvider(stub.client())
        #expect(try await provider.files(at: Self.path, commits: commits) == files)
        #expect(stub.asked == ["/api/graphql"])
    }

    @Test("GraphQL's address is beside the API's, on the host the map sends it to")
    func endpoint() {
        let own = GitLabEndpoints.of("gitlab.unicorns.place")
        #expect(own?.graphQL.absoluteString == "https://gitlab.unicorns.place/api/graphql")
        let lab = GitLabEndpoints.of("gitlab.example.test", hostMap: ["gitlab.example.test": URL(string: "http://127.0.0.1:8768")!])
        #expect(lab?.graphQL.absoluteString == "http://127.0.0.1:8768/api/graphql")
    }

    /// Every GraphQL request answered as if from another GitLab — a redirect
    /// followed elsewhere — naming the same project number; the files API
    /// answered where it was asked.
    final class Elsewhere: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var files: [String: Data] = [:]
        nonisolated(unsafe) static var asked: [String] = []
        static let lock = NSLock()

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let url = request.url!
            Self.lock.withLock { Self.asked.append(url.path) }
            let status: Int, body: Data, from: URL
            if url.path == "/api/graphql" {
                from = URL(string: "https://another-gitlab.invalid/api/graphql")!
                status = 200
                let wrong = GitLabHistoryTests.manifest("6.6.6")
                body = try! JSONSerialization.data(withJSONObject: ["data": ["project": [
                    "id": "gid://gitlab/Project/7",
                    "repository": ["c0": ["nodes": [["oid": GitHash.blob(wrong), "rawTextBlob": String(decoding: wrong, as: UTF8.self)]]]],
                ]]])
            } else {
                from = url
                let answer = GitLabHistoryTests.filesAPI(request, files: Self.lock.withLock { Self.files }) ?? (404, Data())
                (status, body) = answer
            }
            let response = HTTPURLResponse(url: from, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    @Test("an answer from another origin than GraphQL's — a redirect followed — is not believed, whatever number it names")
    func anotherOrigin() async throws {
        let commit = Self.commit(1)
        Elsewhere.lock.withLock {
            Elsewhere.files = [commit: Self.manifest("1.0.0")]
            Elsewhere.asked = []
        }
        let client = GitLabClient(endpoints: GitLabEndpoints(host: "gitlab.example.test",
                                                             apiBase: URL(string: "https://elsewhere-test.invalid/api/v4")!,
                                                             webBase: URL(string: "https://gitlab.example.test")!),
                                  path: "tools/udeck-plugins", remoteID: 7, udeckVersion: "0.8.0", limits: RateLimitRecorder(),
                                  session: GitHubClient.makeSession(protocolClasses: [Elsewhere.self]))
        let found = try await client.files(at: Self.path, commits: [commit])
        #expect(found == [commit: Self.manifest("1.0.0")], "what the files API has, by the number, where it was asked")
        #expect(Elsewhere.lock.withLock { Elsewhere.asked }
                == ["/api/graphql", "/api/v4/projects/7/repository/files/plugins/gl-hello/manifest.json/raw"])
        let asked = URL(string: "https://gitlab.example.test/api/graphql")!
        #expect(GitLabClient.sameOrigin(asked, asked))
        #expect(GitLabClient.sameOrigin(URL(string: "HTTPS://GitLab.Example.Test/api/graphql"), asked))
        for other in ["http://gitlab.example.test/api/graphql", "https://gitlab.example.test:8443/api/graphql",
                      "https://gitlab.example/api/graphql"] {
            #expect(!GitLabClient.sameOrigin(URL(string: other), asked), "\(other)")
        }
        #expect(!GitLabClient.sameOrigin(nil, asked))
    }

    // MARK: - Only new commits

    /// A host's answers for a plugin's history, counted: the history, and the
    /// manifests asked for, commit by commit.
    final class History: RepositoryProvider, @unchecked Sendable {
        let address = RepositoryAddress(provider: "gitlab", host: "gitlab.example.test", path: "tools/udeck-plugins")
        private let lock = NSLock()
        private var history: [String]
        private var manifests: [String: Data]
        private var askedFor: [[String]] = []
        /// Run when manifests are asked for: what happens meanwhile — a prune.
        var meanwhile: (@Sendable () -> Void)?

        init(history: [String], manifests: [String: Data]) {
            self.history = history
            self.manifests = manifests
        }

        func moved(to history: [String], adding: [String: Data]) {
            lock.withLock {
                self.history = history
                manifests.merge(adding) { _, new in new }
            }
        }

        var asked: [[String]] { lock.withLock { askedFor } }

        func commits(touching path: String, on branch: String) async throws -> [CommitSummary] {
            lock.withLock { history.map { CommitSummary(sha: $0, date: nil) } }
        }

        func files(at path: String, commits: [String]) async throws -> [String: Data] {
            let found = lock.withLock {
                askedFor.append(commits)
                return manifests.filter { commits.contains($0.key) }
            }
            meanwhile?()
            return found
        }

        func defaultBranch() async throws -> String { "main" }
        func describe() async throws -> RepositoryDescription { throw ProviderError.notFound }
        func head(of branch: String, ifNoneMatch etag: String?) async throws -> HeadAnswer { throw ProviderError.notFound }
        func tree(_ sha: String, recursive: Bool) async throws -> GitTree { throw ProviderError.notFound }
        func file(at path: String, commit: String) async throws -> Data { throw ProviderError.notFound }
        func pull(_ number: Int) async throws -> PullRequest { throw ProviderError.notFound }
        func compare(_ base: String, _ head: String) async throws -> Comparison { throw ProviderError.notFound }
        func folderPage(_ path: String, commit: String) -> URL? { nil }
        func comparePage(from: String, to: String) -> URL? { nil }
        func provider(for repository: RepositoryAddress) -> (any RepositoryProvider)? { nil }
    }

    @Test("after the head moved: the folder's history asked again, and the manifests of the commits it brought alone")
    func onlyNewCommits() async throws {
        let temp = TemporaryDirectory()
        let store = CatalogueStore(directory: temp.url.appendingPathComponent("catalogue/gl", isDirectory: true))
        let old = (1 ... 5).map(Self.commit).reversed().map { $0 }
        var manifests = Self.versions(old)
        let host = History(history: old, manifests: manifests)
        let reader = PluginHistoryReader(provider: host, store: store)

        let first = try await reader.read("gl-hello", branch: "main", head: old[0])
        #expect(host.asked == [old])
        #expect(first.lines.map(\.commit) == old.filter { manifests[$0] != nil })
        _ = try await reader.read("gl-hello", branch: "main", head: old[0])
        #expect(host.asked.count == 1, "the same head: nothing asked")

        let new = [Self.commit(7), Self.commit(6)]
        let added = [new[0]: Self.manifest("2.0.0"), new[1]: Self.manifest("1.9.0")]
        manifests.merge(added) { _, new in new }
        host.moved(to: new + old, adding: added)
        let second = try await reader.read("gl-hello", branch: "main", head: new[0])
        #expect(host.asked.last == new, "only the commits the head brought: \(host.asked)")
        #expect(second.lines.map(\.version).prefix(2) == ["2.0.0", "1.9.0"])
        #expect(second.lines.count == first.lines.count + 2)

        // A commit whose folder was not there is remembered so; a manifest whose blob is gone is asked for again.
        let index = try #require(store.versionIndex("gl-hello"))
        #expect(Set(index.absent) == Set(old.filter { manifests[$0] == nil }))
        let gone = try #require(index.manifests[old[0]])
        try FileManager.default.removeItem(at: store.directory.appendingPathComponent("blobs/\(gone)"))
        host.moved(to: [Self.commit(8)] + new + old, adding: [Self.commit(8): Self.manifest("3.0.0")])
        _ = try await reader.read("gl-hello", branch: "main", head: Self.commit(8))
        #expect(host.asked.last == [Self.commit(8), old[0]], "the new commit, and the one whose blob went: \(host.asked)")
    }

    @Test("pruning keeps the blobs a version index names, and the index while the head's listing has its plugin")
    func pruning() throws {
        let temp = TemporaryDirectory()
        let store = CatalogueStore(directory: temp.url.appendingPathComponent("catalogue/gl", isDirectory: true))
        let kept = try store.save(blob: Self.manifest("1.0.0"))
        let loose = try store.save(blob: Self.manifest("0.1.0"))
        try store.save(VersionIndex(manifests: [Self.commit(1): kept], absent: [Self.commit(2)]), for: "gl-hello")
        try store.save(VersionIndex(manifests: [Self.commit(3): loose]), for: "gone")
        var repository = FakeRepository.withUptime()
        repository.addPlugin("gl-hello")
        let listing = repository.listing
        try store.save(listing)
        store.prune(head: listing.commit, installedCommits: [])
        #expect(store.versionIndex("gl-hello") != nil && store.blob(kept) != nil)
        #expect(store.versionIndex("gone") == nil && store.blob(loose) == nil, "a plugin the head no longer has")
        // With no listing of the head kept to say, every index stays.
        try store.save(VersionIndex(manifests: [Self.commit(3): try store.save(blob: Self.manifest("0.1.0"))]), for: "gone")
        store.prune(head: String(repeating: "e", count: 40), installedCommits: [])
        #expect(store.versionIndex("gone") != nil && store.blob(loose) != nil)
    }

    @Test("keeping a read history stores each manifest under its hash and names it in the index, in one step")
    func keeping() throws {
        let temp = TemporaryDirectory()
        let store = CatalogueStore(directory: temp.url.appendingPathComponent("catalogue/gl", isDirectory: true))
        let kept = store.keep(VersionIndex(absent: [Self.commit(9)]),
                              adding: [Self.commit(1): Self.manifest("1.0.0"), Self.commit(2): Self.manifest("2.0.0")],
                              for: "gl-hello")
        #expect(kept.manifests == [Self.commit(1): GitHash.blob(Self.manifest("1.0.0")),
                                   Self.commit(2): GitHash.blob(Self.manifest("2.0.0"))])
        #expect(kept.absent == [Self.commit(9)] && store.versionIndex("gl-hello") == kept)
        #expect(kept.manifests.values.allSatisfy { store.blob($0) != nil })
    }

    @Test("a commit whose listing the catalogue keeps is not asked about: its manifest is in the store, or was refused for its size")
    func whatTheCatalogueHas() async throws {
        let temp = TemporaryDirectory()
        let store = CatalogueStore(directory: temp.url.appendingPathComponent("catalogue/official", isDirectory: true))
        var head = FakeRepository.withUptime(version: "1.2.0")
        head.commit = Self.commit(30)
        var big = FakeRepository.withUptime(version: "1.1.0")
        big.commit = Self.commit(20)
        var none = FakeRepository()
        none.addPlugin("other")
        none.commit = Self.commit(15)
        let older = Self.commit(10)
        for repository in [head, big, none] { try store.save(repository.listing) }
        let manifest = try #require(head.data(at: "plugins/uptime/manifest.json"))
        try store.save(blob: manifest)
        let bigBlob = try #require(big.listing.plugins["uptime"]?.file(at: "manifest.json")?.sha)
        try store.refuseAsTooLarge(bigBlob, bytes: 6_291_456)

        let host = History(history: [head.commit, big.commit, none.commit, older],
                           manifests: [older: Self.manifest("1.0.0")])
        let history = try await PluginHistoryReader(provider: host, store: store).read("uptime", branch: "main", head: head.commit)
        #expect(host.asked == [[older]], "only the commit no listing is kept of: \(host.asked)")
        #expect(history.lines.map(\.version) == ["1.2.0", "1.0.0"])
        let index = try #require(store.versionIndex("uptime"))
        #expect(Set(index.absent) == [big.commit, none.commit] && index.manifests[head.commit] == GitHash.blob(manifest))

        // A prune while the read waits for the rest takes the head's blob the read found in the store: the read
        // stores it again with its index, so the index never names a blob that is gone.
        let blobs = store.directory.appendingPathComponent("blobs", isDirectory: true)
        let gone = blobs.appendingPathComponent(GitHash.blob(manifest))
        let again = History(history: [Self.commit(31), head.commit, older], manifests: [Self.commit(31): Self.manifest("1.3.0")])
        again.meanwhile = { try? FileManager.default.removeItem(at: gone) }
        _ = try await PluginHistoryReader(provider: again, store: store).read("uptime", branch: "main", head: Self.commit(31))
        let after = try #require(store.versionIndex("uptime"))
        #expect(after.manifests.values.allSatisfy { store.blob($0) != nil }, "the index names a blob that is gone")
        #expect(after.manifests[head.commit] == GitHash.blob(manifest))
    }
}
