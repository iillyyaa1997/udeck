import Foundation
import Testing
@testable import UDeckCore
import UDeckPluginFormatFixtures

/// GitLab's client (stage 4, R2, S4-14), against stub answers shaped like the
/// ones recorded from gitlab.com and a self-hosted 18.8.2 when stage 4 was
/// designed: Look up by the encoded path, everything after it by the project's
/// number; the head with a weak ETag and its 304; the listing put together from
/// the root and `plugins`, page after page; files from the API with their size
/// held to rule 8; the history, merge requests and merge bases; every status
/// it can answer; and GitLab's limiters (S4-16).
@Suite("GitLab's client")
struct GitLabClientTests {
    static let project = 7
    static let head = String(repeating: "a", count: 40)

    /// One test's GitLab: a host of its own, so tests side by side never see
    /// each other's answers; its pages on the host a person opens.
    struct Stub {
        let host: String
        init(_ name: String) { host = "\(name)-\(UUID().uuidString.lowercased()).invalid" }

        var endpoints: GitLabEndpoints {
            GitLabEndpoints(host: "gitlab.example.test", apiBase: URL(string: "https://\(host)/api/v4")!,
                            webBase: URL(string: "https://gitlab.example.test")!)
        }

        func client(_ limits: RateLimitRecorder = RateLimitRecorder(), path: String = "tools/udeck-plugins",
                    now: Date = Date(timeIntervalSince1970: 1_792_276_900)) -> GitLabClient {
            GitLabClient(endpoints: endpoints, path: path, remoteID: GitLabClientTests.project, udeckVersion: "0.8.0",
                         limits: limits, session: GitHubClient.makeSession(protocolClasses: [StubAnswers.self]),
                         now: { now })
        }

        func answer(_ answer: @escaping StubAnswers.Answer) { StubAnswers.answer(host, with: answer) }
        func headers(_ make: @escaping @Sendable (URLRequest) -> [String: String]) { StubAnswers.headers(host, make) }
        func forget() { StubAnswers.forget(host) }

        /// Every request, as it went: its path as encoded, and its query.
        var asked: [String] {
            StubAnswers.asked(host).map { request in
                let parts = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
                return (parts?.percentEncodedPath ?? "") + (parts?.percentEncodedQuery.map { "?\($0)" } ?? "")
            }
        }
    }

    static func json(_ text: String) -> Data { Data(text.utf8) }

    /// `GET /projects/:id`, as gitlab.com answers it anonymously: no `forked_from_project`.
    static func project(_ path: String = "tools/udeck-plugins", id: Int = project, fork: String? = nil) -> Data {
        let parent = fork.map { #", "forked_from_project": {"id": 3, "path_with_namespace": "\#($0)"}"# } ?? ""
        return json(#"{"id": \#(id), "name": "udeck-plugins", "path_with_namespace": "\#(path)", "default_branch": "main", "visibility": "public"\#(parent)}"#)
    }

    static func query(_ request: URLRequest, _ name: String) -> String? {
        URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
    }

    // MARK: - Look up and describe

    @Test("Look up asks for the project by its path, %2F kept encoded — the one request ever so")
    func lookUpByThePath() async throws {
        let stub = Stub("lookup")
        stub.answer { request in
            URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.percentEncodedPath
                == "/api/v4/projects/group%2Fsub%2Fteam" ? (200, Self.project("group/sub/team", id: 9)) : (404, Data())
        }
        defer { stub.forget() }
        let came = try await GitLabClient.lookUp("group/sub/team", endpoints: stub.endpoints, udeckVersion: "0.8.0",
                                                 limits: RateLimitRecorder(),
                                                 session: GitHubClient.makeSession(protocolClasses: [StubAnswers.self]))
        #expect(came == .found(RepositoryDescription(fullName: "group/sub/team", defaultBranch: "main", fork: false, id: 9)))
        #expect(stub.asked == ["/api/v4/projects/group%2Fsub%2Fteam"])
        let request = try #require(StubAnswers.asked(stub.host).first)
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "uDeck/0.8.0")
        #expect(request.value(forHTTPHeaderField: "PRIVATE-TOKEN") == nil && request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    /// (status, body, what Look up comes to)
    static let lookUps: [(Int, String, GitLabProjectLookUp?)] = [
        (404, #"{"message":"404 Project Not Found"}"#, .notFound),
        (404, "404 page not found\n", .notGitLab),
        (404, "<html><body>Not Found</body></html>", .notGitLab),
        (404, "", .notGitLab),
        (200, "<html>a page that is no project</html>", .notGitLab),
        (200, #"{"message": "no project here"}"#, .notGitLab),
        (200, #"{"path_with_namespace": "g/p", "default_branch": "main"}"#, .notGitLab),
        // A project with no repository to read anonymously — empty, or its code for members only: GitLab's own
        // answer, and as GitHub's empty repository comes to, could not be found or private.
        (200, #"{"id": 7, "path_with_namespace": "g/p", "default_branch": null}"#, .notFound),
        (200, #"{"id": 7, "path_with_namespace": "g/p"}"#, .notFound),
        (200, #"{"id": 0, "path_with_namespace": "g/p"}"#, .notGitLab),
    ]

    @Test("Look up: GitLab's own 404, or a project naming no default branch, is not found; a 404 or an answer that is not GitLab's did not answer as GitLab",
          arguments: 0..<lookUps.count)
    func lookUpAnswers(row: Int) async throws {
        let (status, body, wanted) = Self.lookUps[row]
        let stub = Stub("lookups")
        stub.answer { _ in (status, Data(body.utf8)) }
        defer { stub.forget() }
        let came = try await GitLabClient.lookUp("g/p", endpoints: stub.endpoints, udeckVersion: "0.8.0",
                                                 limits: RateLimitRecorder(),
                                                 session: GitHubClient.makeSession(protocolClasses: [StubAnswers.self]))
        #expect(came == wanted, "\(status) \(body)")
    }

    @Test("describe, by the project's number: its path now, its default branch, and the project it was forked from when it says one")
    func describe() async throws {
        let stub = Stub("describe")
        stub.answer { request in
            switch request.url!.path {
            case "/api/v4/projects/7": (200, Self.project("tools/renamed-plugins", fork: "upstream/udeck-plugins"))
            default: (404, Data())
            }
        }
        defer { stub.forget() }
        let forked = try await stub.client().describe()
        #expect(forked == RepositoryDescription(fullName: "tools/renamed-plugins", defaultBranch: "main", fork: true,
                                                parent: "upstream/udeck-plugins", id: 7))
        #expect(stub.asked == ["/api/v4/projects/7"], "by its number, never its path")
        // Without forked_from_project, as anonymous gitlab.com answers: no fork, and nothing missing.
        #expect(GitLabClient.description(Self.project()) == RepositoryDescription(fullName: "tools/udeck-plugins",
                                                                                   defaultBranch: "main", fork: false, id: 7))
        #expect(GitLabClient.description(Self.json(#"{"id": 7, "default_branch": null}"#)) == nil, "an empty project")
    }

    @Test("describe answering another number is not believed; a renamed project's path is heard through SourceProvider")
    func describeOtherNumberAndRename() async throws {
        let stub = Stub("rename")
        stub.answer { _ in (200, Self.project("tools/new-name", id: 8)) }
        defer { stub.forget() }
        do {
            _ = try await stub.client().describe()
            Issue.record("another project's answer was believed")
        } catch ProviderError.badAnswer(let reason) {
            #expect(reason.contains("7") && reason.contains("8"))
        }
        // An answer naming no number — a redirect's, something that is no GitLab — renames nothing either.
        let unnumbered = Stub("unnumbered")
        unnumbered.answer { _ in (200, Self.json(#"{"path_with_namespace": "elsewhere/answered", "default_branch": "main"}"#)) }
        defer { unnumbered.forget() }
        let believing = SourceProvider(unnumbered.client())
        do {
            _ = try await believing.describe()
            Issue.record("an answer with no number was believed")
        } catch ProviderError.badAnswer(let reason) {
            #expect(reason == "the project asked for as 7 answered with no number")
        }
        #expect(believing.renamedTo == nil && believing.address.path == "tools/udeck-plugins")
        let renamed = Stub("renamed")
        renamed.answer { _ in (200, Self.project("tools/new-name")) }
        defer { renamed.forget() }
        let provider = SourceProvider(renamed.client())
        _ = try await provider.describe()
        #expect(provider.renamedTo == "tools/new-name" && provider.address.path == "tools/new-name")
        #expect(provider.folderPage("plugins/x", commit: Self.head)?.absoluteString
                == "https://gitlab.example.test/tools/new-name/-/tree/\(Self.head)/plugins/x", "the pages follow the new path")
    }

    // MARK: - The head

    @Test("the head: the branch escaped whole, its weak ETag asked again, and 304 when it did not move")
    func head() async throws {
        let stub = Stub("head")
        let etag = #"W/"fdc690247cda07e209a764546ff9ceec""#
        stub.answer { request in
            guard request.url!.absoluteString.hasSuffix("/projects/7/repository/branches/fix%2Fuptime") else { return (404, Data()) }
            return request.value(forHTTPHeaderField: "If-None-Match") == etag
                ? (304, Data()) : (200, Self.json(#"{"name": "fix/uptime", "commit": {"id": "\#(Self.head)"}, "default": false}"#))
        }
        stub.headers { _ in ["ETag": etag] }
        defer { stub.forget() }
        let client = stub.client()
        #expect(try await client.head(of: "fix/uptime", ifNoneMatch: nil) == .commit(Self.head, etag: etag))
        #expect(try await client.head(of: "fix/uptime", ifNoneMatch: etag) == .unchanged)
        // The refresher's fallback, "<head>" quoted, is never GitLab's: a whole answer, nothing worse.
        #expect(try await client.head(of: "fix/uptime", ifNoneMatch: "\"\(Self.head)\"") == .commit(Self.head, etag: etag))
        #expect(stub.asked == Array(repeating: "/api/v4/projects/7/repository/branches/fix%2Fuptime", count: 3))
    }

    // MARK: - The listing

    /// `repository` as GitLab's tree endpoint answers it, page by page,
    /// `pageSize` to a page: the root, or under `plugins` recursively — each
    /// entry `id`, `name`, `type`, `path` (whole) and `mode`, and no size.
    static func gitLabTree(_ repository: FakeRepository, pageSize: Int, plugins: Bool = true) -> StubAnswers.Answer {
        let whole = repository.recursiveTree().tree
        let commit = repository.commit
        let root = whole.filter { !$0.path.contains("/") }
        let under = whole.filter { $0.path.hasPrefix("plugins/") }
        return { request in
            let path = Self.query(request, "path")
            guard request.url!.path == "/api/v4/projects/7/repository/tree", Self.query(request, "ref") == commit,
                  Self.query(request, "per_page") == "100" else { return (400, Self.json(#"{"message": "400 Bad request"}"#)) }
            let entries: [GitTree.Entry]
            switch path {
            case nil: entries = root
            case "plugins"? where plugins && Self.query(request, "recursive") == "true": entries = under
            default: return (404, Self.json(#"{"message":"404 invalid revision or path Not Found"}"#))
            }
            let page = Int(Self.query(request, "page") ?? "1") ?? 1
            let slice = entries.dropFirst((page - 1) * pageSize).prefix(pageSize).map { entry in
                [
                    "id": entry.sha, "name": String(entry.path.split(separator: "/").last ?? ""), "type": entry.type,
                    "path": entry.path, "mode": entry.mode,
                ]
            }
            return (200, try! JSONSerialization.data(withJSONObject: Array(slice)))
        }
    }

    static func pages(_ repository: FakeRepository, pageSize: Int) -> @Sendable (URLRequest) -> [String: String] {
        let whole = repository.recursiveTree().tree
        let counts = ["": whole.filter { !$0.path.contains("/") }.count, "plugins": whole.filter { $0.path.hasPrefix("plugins/") }.count]
        return { request in
            let count = counts[Self.query(request, "path") ?? ""] ?? 0
            let page = Int(Self.query(request, "page") ?? "1") ?? 1
            let next = page * pageSize < count ? String(page + 1) : ""
            return ["x-next-page": next, "x-page": String(page), "x-per-page": String(pageSize)]
        }
    }

    @Test("the listing: the root, then everything under plugins, each followed across its pages — what GitHub's one tree says, less the sizes")
    func treeOverPages() async throws {
        var repository = FakeRepository.withUptime()
        repository.addPlugin("second")
        repository.files["plugins/second/lib/deep.sh"] = .init("#!/bin/sh\n", executable: true)
        repository.files["README.md"] = .init("# repo\n")
        repository.files[".gitlab-ci.yml"] = .init("stages: []\n")
        let stub = Stub("tree")
        stub.answer(Self.gitLabTree(repository, pageSize: 2))
        stub.headers(Self.pages(repository, pageSize: 2))
        defer { stub.forget() }
        let tree = try await stub.client().tree(repository.commit, recursive: true)
        #expect(!tree.truncated && tree.tree.allSatisfy { $0.size == nil })
        let listing = CommitListing(commit: repository.commit, recursive: tree)
        let github = repository.listing
        #expect(listing.passport == github.passport && listing.pluginFolders == github.pluginFolders)
        for id in github.pluginFolders {
            #expect(listing.plugins[id]?.tree == github.plugins[id]?.tree, "\(id): the same tree id as git's")
            #expect(listing.plugins[id]?.entries.map(\.path).sorted() == github.plugins[id]?.entries.map(\.path).sorted())
            #expect(listing.plugins[id]?.entries.map(\.sha).sorted() == github.plugins[id]?.entries.map(\.sha).sorted())
        }
        let roots = stub.asked.filter { !$0.contains("path=") }
        let plugins = stub.asked.filter { $0.contains("path=plugins") }
        #expect(roots.count == 2 && plugins.count == 5, "\(stub.asked)")
        #expect(plugins.allSatisfy { $0.contains("recursive=true") && $0.contains("per_page=100") })
        #expect(plugins.map { Self.page($0) } == [1, 2, 3, 4, 5] && roots.map { Self.page($0) } == [1, 2])
    }

    static func page(_ asked: String) -> Int {
        URLComponents(string: "https://x" + asked)?.queryItems?.first { $0.name == "page" }?.value.flatMap(Int.init) ?? 0
    }

    @Test("a root without plugins is a repository that offers none yet: one request, never path=plugins")
    func emptyRoot() async throws {
        var repository = FakeRepository()
        repository.files["udeck-plugins.json"] = .init(FakeRepository.passport)
        repository.files["README.md"] = .init("# nothing yet\n")
        let stub = Stub("empty")
        stub.answer(Self.gitLabTree(repository, pageSize: 3, plugins: false))
        stub.headers(Self.pages(repository, pageSize: 3))
        defer { stub.forget() }
        let tree = try await stub.client().tree(repository.commit, recursive: true)
        let listing = CommitListing(commit: repository.commit, recursive: tree)
        #expect(listing.plugins.isEmpty && listing.passport == GitHash.blob(Data(FakeRepository.passport.utf8)))
        #expect(stub.asked.count == 1 && !stub.asked[0].contains("path="), "\(stub.asked)")
    }

    @Test("a next page that does not go on is a bad answer, not a loop")
    func pagesThatDoNotGoOn() async throws {
        let stub = Stub("loop")
        stub.answer { _ in (200, Self.json("[]")) }
        stub.headers { _ in ["x-next-page": "1"] }
        defer { stub.forget() }
        do {
            _ = try await stub.client().tree(Self.head, recursive: true)
            Issue.record("a page naming itself as the next was followed")
        } catch ProviderError.badAnswer {}
        #expect(stub.asked.count == 1)
    }

    // MARK: - Files

    @Test("a file comes from the files API, by its escaped path at the commit")
    func file() async throws {
        let stub = Stub("file")
        let manifest = Self.json(#"{"id": "gl-hello"}"#)
        stub.answer { request in
            request.url!.absoluteString.hasSuffix("/projects/7/repository/files/plugins%2Fgl-hello%2Fmanifest.json/raw?ref=\(Self.head)")
                ? (200, manifest) : (404, Self.json(#"{"message":"404 File Not Found"}"#))
        }
        stub.headers { _ in ["X-Gitlab-Size": String(manifest.count), "X-Gitlab-Blob-Id": GitHash.blob(manifest)] }
        defer { stub.forget() }
        #expect(try await stub.client().file(at: "plugins/gl-hello/manifest.json", commit: Self.head) == manifest)
        do {
            _ = try await stub.client().file(at: "plugins/gl-hello/missing.json", commit: Self.head)
            Issue.record("a file that is not there was read")
        } catch ProviderError.notFound {}
    }

    @Test("a file GitLab says is larger than 5 MB is refused before it is read; one read past 5 MB is cut there")
    func fileCap() async throws {
        let stub = Stub("cap")
        let most = RepositoryRules.maximumFileBytes
        stub.answer { request in
            request.url!.path.contains("loud") ? (200, Data(repeating: 0x62, count: 16)) : (200, Data(repeating: 0x61, count: most + 2))
        }
        stub.headers { request in request.url!.path.contains("loud") ? ["X-Gitlab-Size": "6291456"] : [:] }
        defer { stub.forget() }
        do {
            _ = try await stub.client().file(at: "loud.bin", commit: Self.head)
            Issue.record("a file said to be 6 MB was read")
        } catch ProviderError.tooLarge(let bytes) {
            #expect(bytes == 6_291_456, "the size GitLab said")
        }
        do {
            _ = try await stub.client().file(at: "quiet.bin", commit: Self.head)
            Issue.record("a file past 5 MB was read whole")
        } catch ProviderError.tooLarge(let bytes) {
            #expect(bytes == most + 1, "cut one byte past the most")
        }
        let exactly = Stub("exactly")
        exactly.answer { _ in (200, Data(repeating: 0x61, count: most)) }
        defer { exactly.forget() }
        #expect(try await exactly.client().file(at: "five.bin", commit: Self.head).count == most, "5 MB is allowed")
    }

    @Test("a manifest past 5 MB is its plugin's alone: the catalogue is read, and that row says its manifest could not be fetched")
    func manifestTooLarge() async throws {
        var repository = FakeRepository.withUptime()
        repository.addPlugin("second")
        let stub = Stub("bigManifest")
        let tree = Self.gitLabTree(repository, pageSize: 100), pages = Self.pages(repository, pageSize: 100)
        let files = repository.files.mapValues(\.data), commit = repository.commit
        let big = "plugins/second/manifest.json"
        stub.answer { request in
            let encoded = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? ""
            let prefix = "/api/v4/projects/7/repository/files/"
            switch encoded {
            case "/api/v4/projects/7": return (200, Self.project())
            case "/api/v4/projects/7/repository/branches/main":
                return (200, Self.json(#"{"name": "main", "commit": {"id": "\#(commit)"}}"#))
            case _ where encoded.hasPrefix(prefix) && encoded.hasSuffix("/raw"):
                let path = String(encoded.dropFirst(prefix.count).dropLast(4)).removingPercentEncoding ?? ""
                if path == big { return (200, Data(repeating: 0x20, count: 16)) }
                return files[path].map { (200, $0) } ?? (404, Self.json(#"{"message":"404 File Not Found"}"#))
            default: return tree(request)
            }
        }
        stub.headers { request in
            request.url!.absoluteString.contains("plugins%2Fsecond%2Fmanifest.json") ? ["X-Gitlab-Size": "6291456"] : pages(request)
        }
        defer { stub.forget() }
        let temp = TemporaryDirectory()
        let store = CatalogueStore(directory: temp.url.appendingPathComponent("catalogue/gl", isDirectory: true))
        let refresher = CatalogueRefresher(provider: stub.client(), store: store, limits: RateLimitRecorder())
        let outcome = await refresher.refresh(unrequested: false, language: "en")
        guard case .refreshed(let read, _) = outcome, read == commit else {
            Issue.record("one manifest past 5 MB came to \(outcome); uDeck asked \(stub.asked)"); return
        }
        #expect(stub.asked.contains { $0.contains("plugins%2Fsecond%2Fmanifest.json") }, "\(stub.asked)")
        let address = RepositoryAddress(provider: "gitlab", host: "gitlab.example.test", path: "tools/udeck-plugins")
        let catalogue = try #require(Catalogue.load(from: store, address: address, udeck: SemanticVersion("0.8.0"),
                                                    language: "en", source: "x"))
        #expect(catalogue.entry("uptime")?.verdict.isInstallable == true, "\(catalogue.entry("uptime")?.verdict.refusals ?? [])")
        #expect(catalogue.entry("second")?.verdict.refusals == [.manifestUnreadable(path: big, detail: "it could not be fetched")])
        #expect(store.state().lastError == nil)
    }

    // MARK: - History, merge requests, merge bases

    @Test("a folder's history: ref_name, path and per_page, newest first, GitLab's dates read")
    func commits() async throws {
        let stub = Stub("commits")
        let older = String(repeating: "b", count: 40)
        stub.answer { request in
            guard Self.query(request, "ref_name") == "main", Self.query(request, "path") == "plugins/gl-hello",
                  Self.query(request, "per_page") == "100" else { return (400, Data()) }
            return (200, Self.json(#"[{"id": "\#(Self.head)", "committed_date": "2026-10-16T10:11:42.000-05:00"}, {"id": "\#(older)", "committed_date": "2026-10-01T09:00:00Z"}, {"id": "not-a-commit"}]"#))
        }
        defer { stub.forget() }
        let commits = try await stub.client().commits(touching: "plugins/gl-hello", on: "main")
        #expect(commits.map(\.sha) == [Self.head, older])
        #expect(commits.first?.date == Date(timeIntervalSince1970: 1_792_163_502))
        #expect(commits.last?.date == ISO8601DateFormatter().date(from: "2026-10-01T09:00:00Z"))
    }

    /// (state, merge_commit_sha, squash_commit_sha, the pull request's state, merged, its merge commit)
    static let mergeRequests: [(String, String?, String?, PullRequest.State, Bool, String?)] = [
        ("opened", nil, nil, .open, false, nil),
        ("closed", nil, nil, .closed, false, nil),
        ("locked", nil, nil, .closed, false, nil),
        ("merged", String(repeating: "c", count: 40), nil, .closed, true, String(repeating: "c", count: 40)),
        ("merged", nil, String(repeating: "d", count: 40), .closed, true, String(repeating: "d", count: 40)),
        ("opened", String(repeating: "c", count: 40), nil, .open, false, nil),
    ]

    @Test("a merge request's state, as a pull request reads it", arguments: 0..<mergeRequests.count)
    func mergeRequest(row: Int) async throws {
        let (state, merge, squash, wanted, merged, commit) = Self.mergeRequests[row]
        let stub = Stub("mr")
        let fields = [merge.map { #""merge_commit_sha": "\#($0)""# }, squash.map { #""squash_commit_sha": "\#($0)""# }]
            .compactMap { $0 }.map { ", " + $0 }.joined()
        stub.answer { request in
            request.url!.path == "/api/v4/projects/7/merge_requests/3"
                ? (200, Self.json(#"{"iid": 3, "state": "\#(state)", "title": "Add hello", "sha": "\#(Self.head)", "source_branch": "add/hello", "target_branch": "main"\#(fields)}"#))
                : (404, Data())
        }
        defer { stub.forget() }
        let pull = try await stub.client().pull(3)
        #expect(pull == PullRequest(number: 3, state: wanted, merged: merged, mergeCommit: commit, head: Self.head,
                                    headRef: "add/hello", headRepository: nil, title: "Add hello", base: "main"), "\(state)")
        #expect(GitLabClient.mergeRequest(Self.json(#"{"iid": 4, "state": "opened", "sha": "\#(Self.head)"}"#), asked: 3) == nil)
        #expect(GitLabClient.mergeRequest(Self.json(#"{"iid": 3, "state": "draft", "sha": "\#(Self.head)"}"#), asked: 3) == nil)
    }

    @Test("two commits through their merge base: identical asked of nobody, ahead, behind, diverged; a ref not there is not found")
    func compare() async throws {
        let base = String(repeating: "1", count: 40), head = String(repeating: "2", count: 40)
        let other = String(repeating: "3", count: 40)
        for (said, wanted) in [(base, Comparison.Status.ahead), (head, .behind), (other, .diverged)] {
            let stub = Stub("compare")
            stub.answer { request in
                let refs = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?
                    .filter { $0.name == "refs[]" }.compactMap(\.value)
                return refs == [base, head] ? (200, Self.json(#"{"id": "\#(said)", "parent_ids": []}"#)) : (400, Data())
            }
            #expect(try await stub.client().compare(base, head) == Comparison(status: wanted, aheadBy: 0, behindBy: 0))
            #expect(stub.asked.count == 1 && stub.asked[0].hasPrefix("/api/v4/projects/7/repository/merge_base?"))
            stub.forget()
        }
        let nobody = Stub("identical")
        defer { nobody.forget() }
        #expect(try await nobody.client().compare(base, base) == Comparison(status: .identical, aheadBy: 0, behindBy: 0))
        #expect(nobody.asked.isEmpty)

        let gone = Stub("gone")
        gone.answer { _ in (400, Self.json(#"{"message": "Could not find ref: \#(other)"}"#)) }
        defer { gone.forget() }
        do {
            _ = try await gone.client().compare(base, other)
            Issue.record("a ref that is not there was compared")
        } catch ProviderError.notFound {}
    }

    // MARK: - Statuses

    /// (status, body, headers, what the client throws)
    static let statuses: [(Int, String, [String: String], ProviderError)] = [
        (401, #"{"message":"401 Unauthorized"}"#, [:], .unauthorized),
        (403, #"{"error":"insufficient_scope","error_description":"The request requires higher privileges than provided by the access token.","scope":"read_api"}"#,
         [:], .forbidden(scope: "read_api")),
        (403, #"{"error":"insufficient_scope"}"#, [:], .forbidden(scope: nil)),
        (403, #"{"message":"403 Forbidden"}"#, [:], .refused(status: 403)),
        (403, "Retry later\n", ["Retry-After": "120"], .rateLimited(until: Date(timeIntervalSince1970: 1_792_277_020))),
        (404, #"{"message":"404 Project Not Found"}"#, [:], .notFound),
        (429, "Retry later\n", ["Retry-After": "60", "RateLimit-Name": "throttle_unauthenticated_api", "RateLimit-Remaining": "0",
                                "RateLimit-Reset": "1792276920"], .rateLimited(until: Date(timeIntervalSince1970: 1_792_276_960))),
        (429, "Retry later\n", ["RateLimit-Name": "unauthenticated_traffic_per_ip", "RateLimit-Remaining": "0",
                                "RateLimit-Reset": "1792278000"], .rateLimited(until: Date(timeIntervalSince1970: 1_792_278_000))),
        (301, "", ["Location": "https://gitlab.example.test/api/v4/projects/8"], .moved(status: 301)),
        (308, "", [:], .moved(status: 308)),
        // A 400 is not found only where the endpoint answers so for a missing ref or file: anywhere else, a refusal.
        (400, #"{"message":"400 Bad request - ref is missing"}"#, [:], .refused(status: 400)),
        (500, "", [:], .refused(status: 500)),
    ]

    @Test("every status, as S4-14 reads it", arguments: 0..<statuses.count)
    func everyStatus(row: Int) async throws {
        let (status, body, headers, wanted) = Self.statuses[row]
        let stub = Stub("status")
        stub.answer { _ in (status, Data(body.utf8)) }
        stub.headers { _ in headers }
        defer { stub.forget() }
        do {
            _ = try await stub.client().describe()
            Issue.record("\(status) was read as an answer")
        } catch let error as ProviderError {
            #expect(error == wanted, "\(status) \(body)")
        }
    }

    @Test("a 400 from the files endpoint is a file not there; the same from the tree is a refusal")
    func badRequestWhereItMeansNotFound() async throws {
        let stub = Stub("bad")
        stub.answer { _ in (400, Self.json(#"{"message":"400 Bad request - ref is invalid"}"#)) }
        defer { stub.forget() }
        do {
            _ = try await stub.client().file(at: "udeck-plugins.json", commit: Self.head)
            Issue.record("read")
        } catch ProviderError.notFound {}
        do {
            _ = try await stub.client().tree(Self.head, recursive: true)
            Issue.record("read")
        } catch ProviderError.refused(let status) {
            #expect(status == 400)
        }
    }

    // MARK: - Pages, its own project only, the host map

    @Test("its pages are GitLab's, on the real host whatever the API is read from; its own project only")
    func pagesAndProvider() {
        let client = Stub("pages").client()
        let commit = Self.head
        #expect(client.folderPage("plugins/gl-hello", commit: commit)?.absoluteString
                == "https://gitlab.example.test/tools/udeck-plugins/-/tree/\(commit)/plugins/gl-hello")
        #expect(client.comparePage(from: "a1", to: "b2")?.absoluteString
                == "https://gitlab.example.test/tools/udeck-plugins/-/compare/a1...b2")
        #expect(client.provider(for: client.address) != nil)
        #expect(client.provider(for: RepositoryAddress(provider: "gitlab", host: "gitlab.example.test", path: "tools/other")) == nil)
        #expect(client.provider(for: RepositoryAddress(provider: "gitlab", host: "gitlab.example.test", path: "Tools/UDeck-Plugins")) == nil,
                "GitLab's paths byte for byte")
        #expect(client.renamed(to: "tools/x")?.address.path == "tools/x" && client.renamed(to: "x") == nil)
        let gitLab = RepositoryAddress(provider: "gitlab", host: "gitlab.example.test", path: "group/sub/team")
        #expect(gitLab.page(of: .pullRequest(3))?.absoluteString == "https://gitlab.example.test/group/sub/team/-/merge_requests/3")
        #expect(gitLab.page(of: .branch("fix/x"))?.absoluteString == "https://gitlab.example.test/group/sub/team/-/tree/fix/x")
        #expect(gitLab.page(of: .defaultBranch("main")) == nil)
        #expect(RepositoryAddress.official.page(of: .pullRequest(3))?.absoluteString
                == "https://github.com/iillyyaa1997/udeck-plugins/pull/3", "GitHub's as they were")
        #expect(!gitLab.listsSizes && RepositoryAddress.official.listsSizes)
        #expect(gitLab.hostName == "gitlab.example.test" && RepositoryAddress.official.hostName == "GitHub")
    }

    @Test("UDeckPluginsHostMap sends a GitLab's API to its base, and nothing else; its pages stay on the real host")
    func hostMap() {
        let map = HostMap.from(infoDictionary: ["UDeckPluginsHostMap": [
            "gitlab.example.test": "http://127.0.0.1:8768", "GitLab.com": "http://127.0.0.1:8769/",
            "ftp.example": "ftp://127.0.0.1", "nothing.example": 7,
        ]])
        #expect(map == ["gitlab.example.test": URL(string: "http://127.0.0.1:8768")!, "gitlab.com": URL(string: "http://127.0.0.1:8769/")!])
        #expect(HostMap.from(infoDictionary: [:]).isEmpty && HostMap.from(infoDictionary: nil).isEmpty)
        let mapped = GitLabEndpoints.of("gitlab.example.test", hostMap: map)
        #expect(mapped?.apiBase.absoluteString == "http://127.0.0.1:8768/api/v4")
        #expect(mapped?.webBase.absoluteString == "https://gitlab.example.test")
        #expect(GitLabEndpoints.of("gitlab.com", hostMap: map)?.apiBase.absoluteString == "http://127.0.0.1:8769/api/v4")
        let own = GitLabEndpoints.of("gitlab.unicorns.place:8443", hostMap: map)
        #expect(own?.apiBase.absoluteString == "https://gitlab.unicorns.place:8443/api/v4")
        #expect(own?.webBase.absoluteString == "https://gitlab.unicorns.place:8443")
    }

    @Test("a test build says each host its map sends elsewhere")
    func testBuildSaysTheMap() {
        let said = TestBuild.notices(infoDictionary: ["UDeckPluginsHostMap": ["gitlab.example.test": "http://127.0.0.1:8768",
                                                                                "gitlab.com": "http://127.0.0.1:8769"]])
        #expect(said == [.sourcesTestBuild(host: "gitlab.com", base: "http://127.0.0.1:8769"),
                         .sourcesTestBuild(host: "gitlab.example.test", base: "http://127.0.0.1:8768")])
        #expect(TestBuild.notices(infoDictionary: [:]).isEmpty)
    }

    // MARK: - GitLab's limiters (S4-16)

    @Test("gitlab.com's two limiters, each kept apart: a read nobody asked for goes by the one with the least left that has not reset")
    func limiters() async throws {
        let stub = Stub("limits")
        let minute = Date(timeIntervalSince1970: 1_792_276_920), hour = Date(timeIntervalSince1970: 1_792_278_000)
        let counter = AskedPaths()
        stub.answer { _ in (200, Self.project()) }
        stub.headers { _ in
            counter.add("")
            // Alternating, as gitlab.com was seen to: the minute's 500, the hour's 60.
            return counter.names.count % 2 == 1
                ? ["RateLimit-Name": "throttle_unauthenticated_api", "RateLimit-Limit": "500", "RateLimit-Remaining": "495",
                   "RateLimit-Reset": "1792276920"]
                : ["RateLimit-Name": "unauthenticated_traffic_per_ip", "RateLimit-Limit": "60", "RateLimit-Remaining": "9",
                   "RateLimit-Reset": "1792278000"]
        }
        defer { stub.forget() }
        let limits = RateLimitRecorder()
        let client = stub.client(limits)
        _ = try await client.describe()
        #expect(limits.current.allowsUnrequested(now: Date(timeIntervalSince1970: 1_792_276_900)), "the minute's 495 alone")
        _ = try await client.describe()
        let state = limits.current
        #expect(state.limiters == ["throttle_unauthenticated_api": .init(remaining: 495, reset: minute),
                                   "unauthenticated_traffic_per_ip": .init(remaining: 9, reset: hour)])
        #expect(state.remaining == nil && state.reset == nil, "GitHub's own pair untouched")
        #expect(!state.allowsUnrequested(now: Date(timeIntervalSince1970: 1_792_276_900)),
                "the hour's 9 is under the reserve, though the minute's 495 is not")
        #expect(state.leastLeft(now: Date(timeIntervalSince1970: 1_792_276_900)) == 9)
        // Once the hour has reset, nothing it said holds.
        #expect(state.allowsUnrequested(now: Date(timeIntervalSince1970: 1_792_278_001)))
        // A self-hosted GitLab sends no limit at all: nothing is kept, and only a 429 counts.
        var none = RateLimitState()
        #expect(none.observeAPI(status: 200, headers: [:], now: minute) == .fine && none == RateLimitState())
    }

    @Test("a state with GitLab's limiters reads back, and one written before them — or GitHub's — has none")
    func limitersOnDisk() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // As 0.7.0 writes a state's limit.
        let old = try decoder.decode(RateLimitState.self, from: Data(#"{"remaining": 52, "reset": "2026-10-18T10:00:00Z"}"#.utf8))
        #expect(old.remaining == 52 && old.limiters == nil)
        let github = try JSONSerialization.jsonObject(with: encoder.encode(old)) as? [String: Any]
        #expect(github?["limiters"] == nil, "GitHub's state keeps the shape it had")
        var gitLab = RateLimitState()
        _ = gitLab.observeAPI(status: 200, headers: ["ratelimit-name": "unauthenticated_traffic_per_ip",
                                                      "ratelimit-remaining": "33", "ratelimit-reset": "1792278000"],
                              now: Date(timeIntervalSince1970: 1_792_276_900))
        #expect(try decoder.decode(RateLimitState.self, from: encoder.encode(gitLab)) == gitLab)
        // A state 0.7.0 writes back over it has none, and loses nothing else of its own.
        struct Older: Codable { var remaining: Int?; var reset: Date?; var blockedUntil: Date?; var rawBlockedUntil: Date? }
        let read = try decoder.decode(Older.self, from: encoder.encode(gitLab))
        #expect(read.remaining == nil && read.blockedUntil == nil)
    }

    @Test("GitHub's x-ratelimit headers still win when an answer carries both spellings")
    func gitHubFirst() {
        var state = RateLimitState()
        _ = state.observeAPI(status: 200, headers: ["x-ratelimit-remaining": "40", "x-ratelimit-reset": "1792278712",
                                                     "ratelimit-name": "x", "ratelimit-remaining": "1"],
                             now: Date(timeIntervalSince1970: 1_792_276_900))
        #expect(state.remaining == 40 && state.limiters == nil)
    }
}
