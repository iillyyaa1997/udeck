import Foundation
import Testing
@testable import UDeckCore
import UDeckPluginFormatFixtures

/// A GitLab project as a source of one's own (stage 4, R2): **Look up** by its
/// encoded path and then by its number, each GitLab source counted against a
/// limit of its own, what its reads that did not finish say (S4-20, items 9
/// and 13), **Install from a link…** of a GitLab project's link (item 16), a
/// catalogue of a host that lists no sizes (S4-15), and the one lock over
/// every write of a catalogue's state.
@Suite("GitLab projects as sources")
struct GitLabSourceTests {
    static let teamID = 9
    static let head = String(repeating: "a", count: 40)
    static let passport = Data(#"{"format": 1, "name": "Team plugins", "description": "What the team uses."}"#.utf8)
    static let link = SourceLink(provider: "gitlab", host: "gitlab.example.test", path: "group/sub/team")

    /// Clients whose GitLab, gitlab.example.test, is the stub host `host` — as
    /// the lab's host map sends it to the fake.
    static func clients(_ host: String, lookUp: RateLimitRecorder = RateLimitRecorder()) -> SourceClients {
        var clients = SourceClients(
            endpoints: GitHubEndpoints(apiBase: URL(string: "https://github-\(host)/api")!,
                                       rawBase: URL(string: "https://github-\(host)/raw")!,
                                       repository: "iillyyaa1997/udeck-plugins", repositoryID: 900_000_001),
            udeckVersion: "0.8.0", limits: RateLimitRecorder(),
            session: GitHubClient.makeSession(protocolClasses: [StubAnswers.self]),
            hostMap: ["gitlab.example.test": URL(string: "https://\(host)")!])
        clients.lookUpLimits = ["gitlab.example.test": lookUp]
        return clients
    }

    /// A GitLab whose answers are the test's: the project by its encoded
    /// path, its main branch and its passport by its number.
    static func team(_ host: String, path: String = "group/sub/team", id: Int = teamID, passport: Data? = Self.passport) {
        StubAnswers.answer(host) { request in
            let encoded = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? ""
            switch encoded {
            case "/api/v4/projects/group%2Fsub%2Fteam", "/api/v4/projects/Group%2FSub%2FTeam":
                return (200, Data(#"{"id": \#(id), "path_with_namespace": "\#(path)", "default_branch": "main"}"#.utf8))
            case "/api/v4/projects/\(id)/repository/branches/main":
                return (200, Data(#"{"name": "main", "commit": {"id": "\#(head)"}}"#.utf8))
            case "/api/v4/projects/\(id)/repository/files/udeck-plugins.json/raw":
                return passport.map { (200, $0) } ?? (404, Data(#"{"message":"404 File Not Found"}"#.utf8))
            default:
                return (404, Data(#"{"message":"404 Project Not Found"}"#.utf8))
            }
        }
        StubAnswers.headers(host) { _ in
            ["RateLimit-Name": "unauthenticated_traffic_per_ip", "RateLimit-Remaining": "41", "RateLimit-Reset": "1792278000"]
        }
    }

    static func asked(_ host: String) -> [String] {
        StubAnswers.asked(host).map { request in
            let parts = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
            return (parts?.percentEncodedPath ?? "") + (parts?.percentEncodedQuery.map { "?\($0)" } ?? "")
        }
    }

    // MARK: - Look up

    @Test("Look up of a GitLab project: by its encoded path once, then its head and its passport by its number — three API requests")
    func lookUpFound() async throws {
        let host = "gl-lookup-\(UUID().uuidString.lowercased()).invalid"
        Self.team(host, path: "group/sub/team")
        defer { StubAnswers.forget(host) }
        let lookUp = RateLimitRecorder()
        let came = await SourceLookUp.lookUp(Self.link, list: SourceList(), official: .official, officialID: 900_000_001,
                                             clients: Self.clients(host, lookUp: lookUp),
                                             now: { Date(timeIntervalSince1970: 1_792_276_900) })
        guard case .found(let found) = came else { Issue.record("came to \(came)"); return }
        #expect(found.provider == "gitlab" && found.host == "gitlab.example.test" && found.path == "group/sub/team")
        #expect(found.remoteID == Self.teamID && found.defaultBranch == "main" && found.head == Self.head)
        #expect(found.passport.name == "Team plugins" && found.passportData == Self.passport)
        #expect(Self.asked(host) == [
            "/api/v4/projects/group%2Fsub%2Fteam",
            "/api/v4/projects/9/repository/branches/main",
            "/api/v4/projects/9/repository/files/udeck-plugins.json/raw?ref=\(Self.head)",
        ], "three requests to the API — the first by its path, %2F kept, every other by its number")
        #expect(StubAnswers.asked(host).allSatisfy {
            $0.value(forHTTPHeaderField: "PRIVATE-TOKEN") == nil && $0.value(forHTTPHeaderField: "Authorization") == nil
        }, "anonymous")
        // Counted against the host's Look up limit, which the new source's starts from.
        #expect(lookUp.current.limiters?["unauthenticated_traffic_per_ip"]?.remaining == 41)
        let state = SourceLookUp.firstState(of: found)
        #expect(state.defaultBranch == "main" && state.rateLimit == lookUp.current && state.head == nil)
        // Added, its id is the one its number gives on that host.
        var list = SourceList()
        guard case .success(let added) = list.add(provider: found.provider, host: found.host, path: found.path,
                                                  remoteID: found.remoteID, at: Date()) else {
            Issue.record("not added"); return
        }
        #expect(added.id == SourceID.derive(SourceIdentity(provider: "gitlab", host: "gitlab.example.test", remoteID: 9),
                                            path: "group/sub/team"))
        #expect(added.id.hasPrefix("gitlab.example.test-team-"))
    }

    @Test("Look up of a GitLab project: GitLab's spelling of its path; one added already, once its number is known")
    func lookUpSpellingAndAlreadyAdded() async throws {
        let host = "gl-spelling-\(UUID().uuidString.lowercased()).invalid"
        Self.team(host, path: "Group/Sub/Team")
        defer { StubAnswers.forget(host) }
        let pasted = SourceLink(provider: "gitlab", host: "gitlab.example.test", path: "group/sub/team")
        guard case .found(let found) = await SourceLookUp.lookUp(pasted, list: SourceList(), official: .official,
                                                                 officialID: nil, clients: Self.clients(host)) else {
            Issue.record("not found"); return
        }
        #expect(found.path == "Group/Sub/Team", "as GitLab spells it")

        var list = SourceList()
        guard case .success(let added) = list.add(provider: "gitlab", host: "gitlab.example.test", path: "group/old-name",
                                                  remoteID: Self.teamID, at: Date()) else {
            Issue.record("not added"); return
        }
        let again = "gl-again-\(UUID().uuidString.lowercased()).invalid"
        Self.team(again)
        defer { StubAnswers.forget(again) }
        #expect(await SourceLookUp.lookUp(pasted, list: list, official: .official, officialID: nil, clients: Self.clients(again))
                == .alreadyAdded(added))
        #expect(Self.asked(again) == ["/api/v4/projects/group%2Fsub%2Fteam"], "one request, by its path")
    }

    @Test("Look up: GitLab's 404 is item 1; a 404 that is not GitLab's is item 13; no passport is not a plugin repository")
    func lookUpNothingToAdd() async throws {
        let missing = "gl-missing-\(UUID().uuidString.lowercased()).invalid"
        StubAnswers.answer(missing) { _ in (404, Data(#"{"message":"404 Project Not Found"}"#.utf8)) }
        defer { StubAnswers.forget(missing) }
        #expect(await SourceLookUp.lookUp(Self.link, list: SourceList(), official: .official, officialID: nil,
                                          clients: Self.clients(missing))
                == .refused(.sourceNotFound(address: "gitlab.example.test/group/sub/team")))

        let plain = "gl-plain-\(UUID().uuidString.lowercased()).invalid"
        StubAnswers.answer(plain) { _ in (404, Data("404 page not found\n".utf8)) }
        defer { StubAnswers.forget(plain) }
        #expect(await SourceLookUp.lookUp(Self.link, list: SourceList(), official: .official, officialID: nil,
                                          clients: Self.clients(plain))
                == .refused(.sourceNotGitLab(host: "gitlab.example.test")))
        #expect(Self.asked(plain).count == 1, "nothing asked after an answer that is not GitLab's")

        let bare = "gl-bare-\(UUID().uuidString.lowercased()).invalid"
        Self.team(bare, passport: nil)
        defer { StubAnswers.forget(bare) }
        #expect(await SourceLookUp.lookUp(Self.link, list: SourceList(), official: .official, officialID: nil,
                                          clients: Self.clients(bare))
                == .notAPluginRepository(address: "gitlab.example.test/group/sub/team", branch: "main"))

        let limited = "gl-limited-\(UUID().uuidString.lowercased()).invalid"
        StubAnswers.answer(limited) { _ in (429, Data("Retry later\n".utf8)) }
        StubAnswers.headers(limited) { _ in ["Retry-After": "600"] }
        defer { StubAnswers.forget(limited) }
        guard case .failed(.rateLimited, "gitlab.example.test", "gitlab.example.test/group/sub/team", "gitlab")
                = await SourceLookUp.lookUp(Self.link, list: SourceList(), official: .official, officialID: nil,
                                            clients: Self.clients(limited)) else {
            Issue.record("a GitLab's 429 is its limit, said as a GitLab's"); return
        }
    }

    @Test("SourceLookUp.read reads every GitLab form a browser shows, before any request")
    func read() {
        for (text, path) in [("https://gitlab.example.test/group/sub/team/-/tree/main", "group/sub/team"),
                             ("gitlab.example.test/group/sub/team.git", "group/sub/team"),
                             ("https://gitlab.example.test/tools/udeck-plugins/-/merge_requests/1", "tools/udeck-plugins")] {
            #expect(SourceLookUp.read(text, official: .official)
                    == .link(SourceLink(provider: "gitlab", host: "gitlab.example.test", path: path)), "\(text)")
        }
        #expect(SourceLookUp.read("https://gitlab.example.test:8443/g/p", official: .official)
                == .link(SourceLink(provider: "gitlab", host: "gitlab.example.test:8443", path: "g/p")))
    }

    // MARK: - A GitLab source's client

    @Test("a GitLab source is read through GitLab's client, by its number, on its host — its own limit, not GitHub's")
    func sourceClient() async throws {
        let host = "gl-client-\(UUID().uuidString.lowercased()).invalid"
        StubAnswers.answer(host) { request in
            request.url!.path == "/api/v4/projects/9"
                ? (200, Data(#"{"id": 9, "path_with_namespace": "group/sub/team", "default_branch": "main"}"#.utf8))
                : (404, Data(#"{"message":"404 Project Not Found"}"#.utf8))
        }
        StubAnswers.headers(host) { _ in ["RateLimit-Name": "throttle_unauthenticated_api", "RateLimit-Remaining": "499",
                                          "RateLimit-Reset": "1792276980"] }
        defer { StubAnswers.forget(host) }
        let source = OwnSource(id: SourceID.derive(SourceIdentity(provider: "gitlab", host: "gitlab.example.test", remoteID: 9),
                                                   path: "group/sub/team"),
                               provider: "gitlab", host: "gitlab.example.test", path: "group/sub/team", remoteID: 9, addedAt: nil)
        let own = RateLimitRecorder()
        var clients = Self.clients(host)
        clients.gitLabLimits = [source.id: own]
        let provider = try #require(clients.of(source))
        #expect(provider.address == source.address && provider.remoteID == 9)
        #expect(try await provider.describe().defaultBranch == "main")
        #expect(own.current.limiters?["throttle_unauthenticated_api"]?.remaining == 499, "the source's own limit")
        #expect(clients.limits.current == RateLimitState(), "GitHub's untouched")
        #expect(clients.limits(of: source) === own)
        let github = OwnSource(id: "github.com-team-plugins-12345678", provider: "github", host: "github.com",
                               path: "someone/team-plugins", remoteID: 1, addedAt: nil)
        #expect(clients.limits(of: github) === clients.limits, "a GitHub source read without a token: GitHub's anonymous limit")
        #expect(provider.provider(for: source.address) != nil)
        #expect(provider.provider(for: RepositoryAddress(provider: "gitlab", host: "gitlab.example.test", path: "group/other")) == nil)
        #expect(clients.of(OwnSource(id: "x", provider: "gitlab", host: "not a host", path: "g/p", remoteID: 1, addedAt: nil)) == nil)
    }

    // MARK: - What a GitLab's read that did not finish says

    @Test("a GitLab's limit is item 9 — on gitlab.com, without a token, with what a token would change — in both languages")
    func gitLabLimit() {
        let english = Strings(.english), russian = Strings(.russian)
        let until: (Date) -> String = { _ in "15:07" }
        func said(_ host: String, readAt: String?, _ strings: Strings) -> String {
            strings(CatalogueTrouble.phrase(.rateLimited(until: Date()), address: "\(host)/someone/gl-plugins", host: host,
                                            readAt: readAt, until: until, provider: "gitlab"))
        }
        #expect(said("gitlab.com", readAt: "14:02", english)
                == "gitlab.com asked uDeck to wait: its limit of requests from this network, or for this token, is used up. The list below is from 14:02; uDeck will look again after 15:07. Without a token gitlab.com allows only a few requests an hour from one network; a token raises the limit.")
        #expect(said("gitlab.com", readAt: "14:02", russian)
                == "gitlab.com попросил uDeck подождать: лимит запросов с этой сети или для этого токена исчерпан. Список ниже — на 14:02; uDeck посмотрит снова после 15:07. Без токена gitlab.com разрешает с одной сети лишь несколько запросов в час; с токеном лимит выше.")
        #expect(said("gitlab.example.test", readAt: nil, english)
                == "gitlab.example.test asked uDeck to wait: its limit of requests from this network, or for this token, is used up. uDeck will look again after 15:07.")
        #expect(said("gitlab.example.test", readAt: "14:02", russian)
                == "gitlab.example.test попросил uDeck подождать: лимит запросов с этой сети или для этого токена исчерпан. Список ниже — на 14:02; uDeck посмотрит снова после 15:07.")
        // A GitHub source's limit is GitHub's sentence, item 7, as it was.
        #expect(english(CatalogueTrouble.phrase(.rateLimited(until: Date()), address: "github.com/o/r", host: "github.com",
                                                readAt: nil, until: until)).hasPrefix("GitHub allows 60 requests an hour"))
        // The rest of a GitLab's reads name its host, as a GitHub source's do.
        #expect(english(CatalogueTrouble.phrase(.unreachable("offline"), address: "gitlab.com/o/r", host: "gitlab.com",
                                                readAt: nil, until: until, provider: "gitlab"))
                == "Could not reach gitlab.com: offline.")
        #expect(english(CatalogueTrouble.phrase(.notFound, address: "gitlab.com/o/r", host: "gitlab.com", readAt: nil,
                                                until: until, provider: "gitlab"))
                == "gitlab.com/o/r could not be found, or it is private. If it is private, uDeck needs a token for it: Token…")
    }

    @Test("a host that did not answer as GitLab is item 13, in both languages")
    func notGitLab() {
        #expect(Strings(.english)(.sourceNotGitLab(host: "plain.example"))
                == "plain.example did not answer as GitLab. uDeck reads sources on github.com and on GitLab — gitlab.com or your own.")
        #expect(Strings(.russian)(.sourceNotGitLab(host: "plain.example"))
                == "plain.example не ответил как GitLab. uDeck читает источники на github.com и на GitLab — gitlab.com или собственном.")
    }

    // MARK: - Install from a link… of a GitLab project

    @Test("Install from a link… of another host: item 16, with Add as a source… for a GitLab project's page and none otherwise")
    func linkToAnotherHost() {
        let official = RepositoryAddress.official
        let text = "https://gitlab.example.test/group/sub/team/-/tree/main"
        guard case .failure(let refusal) = RepositoryLink.read(text, official: official) else {
            Issue.record("a GitLab link was read as GitHub's"); return
        }
        #expect(refusal == .notGitHub(host: "gitlab.example.test"))
        #expect(LinkRefusal.refused(refusal, text: text, official: official)
                == .linkNotGitHubAddAsASource(host: "gitlab.example.test", page: "https://gitlab.example.test/group/sub/team"))
        #expect(LinkRefusal.refused(.notGitHub(host: "www.gitlab.com"), text: "https://www.gitlab.com/g/p/-/merge_requests/2",
                                    official: official)
                == .linkNotGitHubAddAsASource(host: "gitlab.com", page: "https://gitlab.com/g/p"))
        // GitHub's own hosts that are no repository's page, and anything else, offer nothing to add.
        #expect(LinkRefusal.refused(.notGitHub(host: "api.github.com"),
                                    text: "https://api.github.com/repos/iillyyaa1997/udeck-plugins/pulls/3", official: official)
                == .linkNotGitHubAddAsASource(host: "api.github.com", page: nil))
        #expect(LinkRefusal.refused(.notALink, text: "x", official: official) == .linkRefused(.notALink, official: official.description))
        // A GitLab with a port: no link to GitHub's reading, and that project's all the same.
        let ported = "https://gitlab.example.test:8443/group/sub/team/-/merge_requests/2"
        guard case .failure(let portRefusal) = RepositoryLink.read(ported, official: official) else {
            Issue.record("a GitLab link with a port was read as GitHub's"); return
        }
        #expect(portRefusal == .notALink)
        #expect(LinkRefusal.refused(portRefusal, text: ported, official: official)
                == .linkNotGitHubAddAsASource(host: "gitlab.example.test:8443", page: "https://gitlab.example.test:8443/group/sub/team"))
        #expect(LinkRefusal.refused(.notALink, text: "git@gitlab.com:g/p.git", official: official)
                == .linkRefused(.notALink, official: official.description), "git's SSH address is no project's page")
        let english = Strings(.english), russian = Strings(.russian)
        let phrase = Phrase.linkNotGitHubAddAsASource(host: "gitlab.example.test", page: "https://gitlab.example.test/g/p")
        #expect(english(phrase) == "gitlab.example.test is not GitHub. A GitLab project can be added as a source of its own.")
        #expect(russian(phrase) == "gitlab.example.test — не GitHub. Проект GitLab можно добавить как отдельный источник.")
        #expect(english(.linkRefused(.notGitHub(host: "gitlab.com"), official: "github.com/o/r"))
                == "gitlab.com is not GitHub. A GitLab project can be added as a source of its own.")
        #expect(english(.catalogueOpenOn(host: "GitHub")) == "Open on GitHub"
                && english(.catalogueOpenOn(host: "gitlab.example.test")) == "Open on gitlab.example.test")
        #expect(russian(.catalogueOpenOn(host: "gitlab.example.test")) == "Открыть на gitlab.example.test")
        #expect(english(.catalogueFiles(files: 4)) == "4 files" && english(.catalogueFiles(files: 1)) == "1 file")
        #expect(russian(.catalogueFiles(files: 4)) == "файлов: 4")
    }

    // MARK: - A catalogue of a host that lists no sizes

    @Test("a GitLab source's catalogue rows are installable with no sizes listed; a GitHub one's are refused for them")
    func catalogueWithoutSizes() throws {
        let temp = TemporaryDirectory()
        let repository = FakeRepository.withUptime()
        let store = CatalogueStore(directory: temp.url.appendingPathComponent("catalogue/gl", isDirectory: true))
        let whole = repository.recursiveTree()
        let unsized = GitTree(sha: whole.sha, tree: whole.tree.map {
            GitTree.Entry(path: $0.path, mode: $0.mode, type: $0.type, sha: $0.sha, size: nil)
        })
        try store.save(CommitListing(commit: repository.commit, recursive: unsized))
        for path in ["udeck-plugins.json", "plugins/uptime/manifest.json"] { try store.save(blob: repository.data(at: path)!) }
        try store.save(CatalogueState(defaultBranch: "main", head: repository.commit))
        let gitLab = RepositoryAddress(provider: "gitlab", host: "gitlab.example.test", path: "tools/udeck-plugins")
        let row = try #require(Catalogue.load(from: store, address: gitLab, udeck: SemanticVersion("0.8.0"), language: "en",
                                              source: "x")?.entry("uptime"))
        #expect(row.verdict.isInstallable, "\(row.verdict.refusals)")
        let asGitHub = try #require(Catalogue.load(from: store, address: .official, udeck: SemanticVersion("0.8.0"),
                                                   language: "en")?.entry("uptime"))
        #expect(asGitHub.verdict.refusals.contains { if case .sizeNotListed = $0 { true } else { false } })
    }

    // MARK: - One write of a state at a time

    @Test("a read's own write of its state is never written over by the limit kept from before it")
    func stateWritesOneAtATime() async throws {
        let temp = TemporaryDirectory()
        let store = CatalogueStore(directory: temp.url.appendingPathComponent("catalogue/official", isDirectory: true))
        try store.save(CatalogueState(head: String(repeating: "0", count: 40)))
        for round in 1 ... 200 {
            let head = String(repeating: String(round % 10), count: 40) + ""
            let read = CatalogueState(head: head, lastSuccess: Date(timeIntervalSince1970: TimeInterval(round)))
            let limit = RateLimitState(remaining: round)
            await withTaskGroup(of: Void.self) { group in
                group.addTask { try? store.save(read) }
                group.addTask { store.updateState { $0.rateLimit = limit } }
            }
            let state = store.state()
            // Either order: the read's head and success stand, and the limit is either the one kept or the read's own.
            #expect(state.head == head && state.lastSuccess == read.lastSuccess, "round \(round): the read's write was lost")
            if state.head != head { break }
        }
        let kept = store.updateState { $0.rateLimit = RateLimitState(remaining: 7) }
        #expect(kept.rateLimit.remaining == 7 && store.state() == kept && kept.lastSuccess != nil, "the rest kept as it was")
    }
}
