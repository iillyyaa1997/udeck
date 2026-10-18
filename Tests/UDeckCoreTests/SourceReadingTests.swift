import Foundation
import Testing
@testable import UDeckCore
import UDeckPluginFormatFixtures

/// Reading the sources the operator adds (stage 4, R1b): Look up before Add,
/// the source's own client by its number, the official repository's number
/// held at its describe, what may be read with **Official catalogue** off,
/// when each source is read, and what a read that did not finish says.
@Suite("Reading sources of one's own")
struct SourceReadingTests {
    static let teamID = 900_000_101
    static let officialID = 900_000_001
    static let head = String(repeating: "a", count: 40)
    static let passport = Data(#"{"format": 1, "name": "Team plugins", "description": "What the team uses."}"#.utf8)

    static func clients(_ host: String, limits: RateLimitRecorder = RateLimitRecorder()) -> SourceClients {
        SourceClients(endpoints: GitHubEndpoints(apiBase: URL(string: "https://\(host)/api")!,
                                                 rawBase: URL(string: "https://\(host)/raw")!,
                                                 repository: "iillyyaa1997/udeck-plugins", repositoryID: officialID),
                      udeckVersion: "0.8.0", limits: limits,
                      session: GitHubClient.makeSession(protocolClasses: [StubAnswers.self]))
    }

    static func describe(_ fullName: String, id: Int? = teamID, branch: String = "main") -> Data {
        let number = id.map { #""id": \#($0), "# } ?? ""
        return Data(#"{\#(number)"full_name": "\#(fullName)", "default_branch": "\#(branch)", "fork": false, "owner": {"type": "User"}}"#.utf8)
    }

    /// A host whose answers are the test's: the repository by its path, its
    /// head by its number, the passport at the head.
    static func team(_ host: String, fullName: String = "someone/team-plugins", id: Int? = teamID,
                     passport: Data? = SourceReadingTests.passport) {
        StubAnswers.answer(host) { request in
            switch request.url?.path {
            case "/api/repos/someone/team-plugins", "/api/repos/Someone/Team-Plugins": (200, describe(fullName, id: id))
            case "/api/repositories/\(teamID)/commits/main": (200, Data(head.utf8))
            case "/raw/\(fullName)/\(head)/udeck-plugins.json":
                passport.map { (200, $0) } ?? (404, Data("404: Not Found".utf8))
            default: (404, Data(#"{"message": "Not Found"}"#.utf8))
            }
        }
    }

    static func asked(_ host: String) -> [String] {
        StubAnswers.asked(host).map { request in
            (request.url?.path ?? "") + (request.value(forHTTPHeaderField: "Accept") == "application/vnd.github.sha" ? " sha" : "")
        }
    }

    // MARK: - Look up

    @Test("Look up: the repository by its path once, then its head by its number and the passport from the raw host — nothing else")
    func lookUpFound() async throws {
        let host = "lookup-\(UUID().uuidString.lowercased()).invalid"
        Self.team(host)
        defer { StubAnswers.forget(host) }
        let link = SourceLink(provider: "github", host: "github.com", path: "Someone/Team-Plugins")
        let came = await SourceLookUp.lookUp(link, list: SourceList(), official: .official, officialID: Self.officialID,
                                             clients: Self.clients(host), now: { Date(timeIntervalSince1970: 1_790_000_000) })
        guard case .found(let found) = came else { Issue.record("came to \(came)"); return }
        #expect(found.path == "someone/team-plugins", "GitHub's own spelling of it")
        #expect(found.remoteID == Self.teamID && found.defaultBranch == "main" && found.head == Self.head)
        #expect(found.passport.name == "Team plugins" && found.passportData == Self.passport)
        #expect(found.readAt == Date(timeIntervalSince1970: 1_790_000_000))
        #expect(Self.asked(host) == [
            "/api/repos/Someone/Team-Plugins",
            "/api/repositories/\(Self.teamID)/commits/main sha",
            "/raw/someone/team-plugins/\(Self.head)/udeck-plugins.json",
        ], "two requests to the API — one by the name, one by the number — and the passport")
        #expect(StubAnswers.asked(host).allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil }, "anonymous")
        let state = SourceLookUp.firstState(of: found)
        #expect(state.defaultBranch == "main" && state.defaultBranchReadAt == found.readAt && state.head == nil)
    }

    @Test("Look up refuses before any request what SourceLink refuses, and a GitLab project is asked of its host")
    func lookUpBeforeAnyRequest() {
        let official = RepositoryAddress.official
        #expect(SourceLookUp.read("http://github.com/someone/team-plugins", official: official)
                == .refused(.sourceLinkRefused(.notHTTPS, official: official.description)))
        #expect(SourceLookUp.read("git@github.com:someone/team-plugins.git", official: official)
                == .refused(.sourceLinkRefused(.ssh, official: official.description)))
        #expect(SourceLookUp.read("github.com/iillyyaa1997/udeck-plugins", official: official)
                == .refused(.sourceLinkRefused(.officialCatalogue, official: official.description)))
        #expect(SourceLookUp.read("https://gitlab.example.test/group/sub/team/-/tree/main", official: official)
                == .link(SourceLink(provider: "gitlab", host: "gitlab.example.test", path: "group/sub/team")))
        #expect(SourceLookUp.read("github.com/someone/team-plugins/tree/main/plugins/team-clock", official: official)
                == .link(SourceLink(provider: "github", host: "github.com", path: "someone/team-plugins")))
    }

    @Test("Look up: 404 is S4-20's item 1; no passport is not a plugin repository; an answer without a number is not believed")
    func lookUpNothingToAdd() async throws {
        let link = SourceLink(provider: "github", host: "github.com", path: "someone/team-plugins")
        let missing = "missing-\(UUID().uuidString.lowercased()).invalid"
        StubAnswers.answer(missing) { _ in (404, Data(#"{"message": "Not Found"}"#.utf8)) }
        defer { StubAnswers.forget(missing) }
        #expect(await SourceLookUp.lookUp(link, list: SourceList(), official: .official, officialID: Self.officialID,
                                          clients: Self.clients(missing))
                == .refused(.sourceNotFound(address: "github.com/someone/team-plugins")))
        #expect(Self.asked(missing) == ["/api/repos/someone/team-plugins"], "one request, and nothing by a number")

        let bare = "bare-\(UUID().uuidString.lowercased()).invalid"
        Self.team(bare, passport: nil)
        defer { StubAnswers.forget(bare) }
        #expect(await SourceLookUp.lookUp(link, list: SourceList(), official: .official, officialID: Self.officialID,
                                          clients: Self.clients(bare))
                == .notAPluginRepository(address: "github.com/someone/team-plugins", branch: "main"))

        let unnumbered = "unnumbered-\(UUID().uuidString.lowercased()).invalid"
        Self.team(unnumbered, id: nil)
        defer { StubAnswers.forget(unnumbered) }
        guard case .failed(.badAnswer, "github.com", "github.com/someone/team-plugins", "github") = await SourceLookUp.lookUp(
            link, list: SourceList(), official: .official, officialID: Self.officialID, clients: Self.clients(unnumbered)) else {
            Issue.record("an answer with no number is not one a source can be added from"); return
        }
        #expect(Self.asked(unnumbered) == ["/api/repos/someone/team-plugins"], "nothing asked by a name a second time")
    }

    @Test("Look up: the same repository already added, under any name — and the official one by its number — after one request")
    func lookUpAlreadyThere() async throws {
        let host = "already-\(UUID().uuidString.lowercased()).invalid"
        Self.team(host)
        defer { StubAnswers.forget(host) }
        let link = SourceLink(provider: "github", host: "github.com", path: "someone/team-plugins")
        var list = SourceList()
        guard case .success(let added) = list.add(provider: "github", host: "github.com", path: "someone/old-name",
                                                  remoteID: Self.teamID, at: Date()) else {
            Issue.record("the source could not be added"); return
        }
        #expect(await SourceLookUp.lookUp(link, list: list, official: .official, officialID: Self.officialID,
                                          clients: Self.clients(host)) == .alreadyAdded(added))
        #expect(Self.asked(host) == ["/api/repos/someone/team-plugins"])

        let renamedOfficial = "official-\(UUID().uuidString.lowercased()).invalid"
        Self.team(renamedOfficial, id: Self.officialID)
        defer { StubAnswers.forget(renamedOfficial) }
        #expect(await SourceLookUp.lookUp(link, list: SourceList(), official: .official, officialID: Self.officialID,
                                          clients: Self.clients(renamedOfficial))
                == .refused(.sourceLinkRefused(.officialCatalogue, official: RepositoryAddress.official.description)),
                "the official repository under another name is the official catalogue")

        // An entry left out that is the same repository: its own line (Phrase.sourceSkipped).
        let skippedHost = "skipped-\(UUID().uuidString.lowercased()).invalid"
        Self.team(skippedHost)
        defer { StubAnswers.forget(skippedHost) }
        let file = #"{"version": 1, "sources": [{"provider": "github", "host": "github.com", "path": "someone/team-plugins/x", "remoteID": \#(Self.teamID)}]}"#
        let withSkipped = try SourceList.read(Data(file.utf8)).get()
        let skipped = try #require(withSkipped.skipped.first)
        #expect(await SourceLookUp.lookUp(link, list: withSkipped, official: .official, officialID: Self.officialID,
                                          clients: Self.clients(skippedHost)) == .refused(.sourceSkipped(skipped)))
    }

    @Test("Look up with GitHub's limit used up says it as a read says it, and asks nothing")
    func lookUpLimited() async throws {
        let host = "limited-\(UUID().uuidString.lowercased()).invalid"
        Self.team(host)
        defer { StubAnswers.forget(host) }
        let until = Date().addingTimeInterval(3600)
        let limits = RateLimitRecorder(RateLimitState(blockedUntil: until))
        let came = await SourceLookUp.lookUp(SourceLink(provider: "github", host: "github.com", path: "someone/team-plugins"),
                                             list: SourceList(), official: .official, officialID: Self.officialID,
                                             clients: Self.clients(host, limits: limits))
        guard case .failed(.rateLimited, "github.com", "github.com/someone/team-plugins", "github") = came else { Issue.record("came to \(came)"); return }
        #expect(StubAnswers.asked(host).isEmpty)
    }

    // MARK: - The source's own client

    @Test("a source's provider answers for its number alone, takes the name a describe gives, and asks raw files by it")
    func sourceProvider() async throws {
        let host = "renamed-\(UUID().uuidString.lowercased()).invalid"
        StubAnswers.answer(host) { request in
            switch request.url?.path {
            case "/api/repositories/\(Self.teamID)": (200, Self.describe("someone/team-plugins-2"))
            case "/raw/someone/team-plugins-2/\(Self.head)/udeck-plugins.json": (200, Self.passport)
            default: (404, Data(#"{"message": "Not Found"}"#.utf8))
            }
        }
        defer { StubAnswers.forget(host) }
        let clients = Self.clients(host)
        let source = OwnSource(id: "github.com-team-plugins-00000000", provider: "github", host: "github.com",
                               path: "someone/team-plugins", remoteID: Self.teamID, addedAt: nil)
        let provider = try #require(clients.of(source))
        #expect(provider.remoteID == Self.teamID && provider.renamedTo == nil)
        #expect(provider.provider(for: RepositoryAddress(path: "Someone/Team-Plugins")) != nil, "its own, whatever the case")
        #expect(provider.provider(for: RepositoryAddress(path: "someone/other")) == nil, "never another repository")
        #expect(try await provider.defaultBranch() == "main")
        #expect(provider.renamedTo == "someone/team-plugins-2" && provider.address.path == "someone/team-plugins-2")
        #expect(try await provider.file(at: "udeck-plugins.json", commit: Self.head) == Self.passport,
                "raw files by the name it has now")
        #expect(StubAnswers.asked(host).map { $0.url?.path ?? "" }
                == ["/api/repositories/\(Self.teamID)", "/raw/someone/team-plugins-2/\(Self.head)/udeck-plugins.json"])

        let gitlab = OwnSource(id: "gitlab.example-team-00000000", provider: "gitlab", host: "gitlab.example",
                               path: "tools/team", remoteID: 7, addedAt: nil)
        // A GitLab source is read through GitLab's client, on its own host, by its number (GitLabSourceTests).
        #expect(clients.of(gitlab)?.address == gitlab.address && clients.of(gitlab)?.remoteID == 7)
        #expect(SourceProvider(clients.byPath("someone/team-plugins")) == nil, "only a client addressed by its number")
    }

    @Test("a describe by the source's number that answers for another number is not believed")
    func anotherNumber() async throws {
        let host = "another-\(UUID().uuidString.lowercased()).invalid"
        StubAnswers.answer(host) { _ in (200, Self.describe("someone/elsewhere", id: 5)) }
        defer { StubAnswers.forget(host) }
        let provider = try #require(Self.clients(host).byID(Self.teamID, path: "someone/team-plugins"))
        await #expect(throws: ProviderError.badAnswer("the repository asked for as \(Self.teamID) answered as 5")) {
            _ = try await provider.describe()
        }
        #expect(provider.renamedTo == nil && provider.address.path == "someone/team-plugins", "its name not taken either")
    }

    @Test("renamed: only a client addressed by its number, and only to a name GitHub allows")
    func renamed() {
        let endpoints = GitHubEndpoints(apiBase: URL(string: "https://x.invalid/api")!, rawBase: URL(string: "https://x.invalid/raw")!,
                                        repository: "someone/team-plugins")
        let byPath = GitHubClient(endpoints: endpoints, udeckVersion: "0.8.0", limits: RateLimitRecorder())
        let byID = GitHubClient(endpoints: endpoints, udeckVersion: "0.8.0", limits: RateLimitRecorder(), addressing: .id(7))
        #expect(byPath.renamed(to: "someone/team-plugins-2") == nil)
        #expect(byID.renamed(to: "someone/team plugins") == nil && byID.renamed(to: "a/b/c") == nil)
        let renamed = byID.renamed(to: "someone/team-plugins-2")
        #expect(renamed?.addressing == .id(7) && renamed?.address.path == "someone/team-plugins-2"
                && renamed?.endpoints.repository == "someone/team-plugins-2")
    }

    // MARK: - The official repository's number

    static let officialHost = "iillyyaa1997/udeck-plugins"

    @Test("the official describe is held to its number: another, or none, stops the read before its head is asked")
    func officialNumber() async throws {
        for (id, stops) in [(Self.officialID as Int?, false), (5, true), (nil, true)] {
            let host = "official-\(UUID().uuidString.lowercased()).invalid"
            StubAnswers.answer(host) { request in
                switch request.url?.path {
                case "/api/repos/iillyyaa1997/udeck-plugins": (200, Self.describe("iillyyaa1997/udeck-plugins", id: id))
                default: (404, Data(#"{"message": "Not Found"}"#.utf8))
                }
            }
            defer { StubAnswers.forget(host) }
            let client = Self.clients(host).byPath("iillyyaa1997/udeck-plugins")
            let check = OfficialRepositoryCheck(client, expected: Self.officialID)
            let udeck = TemporaryDirectory()
            let store = CatalogueStore(paths: udeck.paths)
            let outcome = await CatalogueRefresher(provider: check, store: store, limits: RateLimitRecorder())
                .refresh(unrequested: false, language: "en")
            if stops {
                #expect(outcome == .failed(.officialRepositoryChanged), "\(String(describing: id))")
                #expect(store.state().lastError == .officialRepositoryChanged && store.state().head == nil)
                #expect(StubAnswers.asked(host).map { $0.url?.path ?? "" } == ["/api/repos/iillyyaa1997/udeck-plugins"],
                        "nothing of the repository at that address is read")
            } else {
                #expect(outcome != .failed(.officialRepositoryChanged), "its own number reads on")
                #expect(StubAnswers.asked(host).count >= 2, "and asks for the head next")
            }
        }
        // No number in the build: nothing compared.
        let host = "unnumbered-official-\(UUID().uuidString.lowercased()).invalid"
        StubAnswers.answer(host) { _ in (200, Self.describe("iillyyaa1997/udeck-plugins", id: 5)) }
        defer { StubAnswers.forget(host) }
        let check = OfficialRepositoryCheck(Self.clients(host).byPath("iillyyaa1997/udeck-plugins"), expected: nil)
        #expect(try await check.describe().id == 5)
        #expect(check.provider(for: RepositoryAddress(path: "someone/udeck-plugins")) != nil, "a fork through the official client")
        #expect(check.provider(for: .official) as? OfficialRepositoryCheck != nil, "the official one through the check")
    }

    @Test("the official number in Info.plist: an integer or digits; the shipped one when absent; none when it is not one")
    func officialNumberInThePlist() {
        #expect(GitHubEndpoints.official.repositoryID == 1_393_324_153)
        #expect(GitHubEndpoints.from(infoDictionary: nil).repositoryID == 1_393_324_153)
        #expect(GitHubEndpoints.from(infoDictionary: ["UDeckPluginsRepositoryID": 900_000_001]).repositoryID == 900_000_001)
        #expect(GitHubEndpoints.from(infoDictionary: ["UDeckPluginsRepositoryID": "900000001"]).repositoryID == 900_000_001)
        #expect(GitHubEndpoints.from(infoDictionary: ["UDeckPluginsRepositoryID": "12a"]).repositoryID == nil)
        #expect(GitHubEndpoints.from(infoDictionary: ["UDeckPluginsRepositoryID": 0]).repositoryID == nil)
        #expect(GitHubEndpoints.from(infoDictionary: ["UDeckPluginsRepositoryID": -3]).repositoryID == nil)
    }

    @Test("a state an older uDeck reads: the official number's error is kept here, and dropped by a build that does not know it")
    func officialNumberInTheState() throws {
        let state = CatalogueState(head: Self.head, lastError: .officialRepositoryChanged, failuresInARow: 1)
        let data = try JSONEncoder().encode(state)
        #expect(try JSONDecoder().decode(CatalogueState.self, from: data) == state)
        let later = Data(#"{"head": "\#(Self.head)", "lastError": {"aKindFromLater": {}}, "failuresInARow": 2}"#.utf8)
        let read = try JSONDecoder().decode(CatalogueState.self, from: later)
        #expect(read.lastError == nil && read.head == Self.head && read.failuresInARow == 2)
    }

    @Test("another number stands until a describe answers: asked again first, kept by a read that fails before, and nothing else of the official repository may be read meanwhile")
    func officialNumberStands() async throws {
        let udeck = TemporaryDirectory()
        let store = CatalogueStore(paths: udeck.paths)
        let twoDaysAgo = Date().addingTimeInterval(-2 * 86400)
        try store.save(CatalogueState(defaultBranch: "main", defaultBranchReadAt: twoDaysAgo, head: Self.head,
                                      lastSuccess: twoDaysAgo, lastAttempt: twoDaysAgo))
        func read(describe: (Int, Data), head: (Int, Data)) async -> (CatalogueRefresher.Outcome, [String]) {
            let host = "official-stands-\(UUID().uuidString.lowercased()).invalid"
            StubAnswers.answer(host) { request in
                switch request.url?.path {
                case "/api/repos/iillyyaa1997/udeck-plugins": describe
                case "/api/repos/iillyyaa1997/udeck-plugins/commits/main": head
                default: (404, Data(#"{"message": "Not Found"}"#.utf8))
                }
            }
            defer { StubAnswers.forget(host) }
            let check = OfficialRepositoryCheck(Self.clients(host).byPath("iillyyaa1997/udeck-plugins"), expected: Self.officialID)
            let outcome = await CatalogueRefresher(provider: check, store: store, limits: RateLimitRecorder())
                .refresh(unrequested: false, language: "en")
            return (outcome, Self.asked(host))
        }
        let failing = (500, Data(#"{"message": "Server Error"}"#.utf8))
        let describe = "/api/repos/iillyyaa1997/udeck-plugins"

        // Another number: stopped, and the next read asks the number first.
        let (changed, _) = await read(describe: (200, Self.describe("iillyyaa1997/udeck-plugins", id: 5)), head: failing)
        #expect(changed == .failed(.officialRepositoryChanged))
        #expect(store.state().lastError == .officialRepositoryChanged && store.state().defaultBranchReadAt == nil)
        #expect(!SourceAccess.readsOfficialRepository(officialCatalogue: true, state: store.state()))
        #expect(!SourceAccess.canRead(InstalledPlugins.officialSource,
                                      officialCatalogue: SourceAccess.readsOfficialRepository(officialCatalogue: true,
                                                                                              state: store.state()),
                                      sources: []), "no copy of the official source is asked about")

        // A describe that does not answer says nothing of whose the address is.
        let (unanswered, asked) = await read(describe: failing, head: failing)
        #expect(asked == [describe], "the number again, first, and nothing after it")
        #expect(unanswered == .failed(.officialRepositoryChanged) && store.state().lastError == .officialRepositoryChanged,
                "\(unanswered)")
        #expect(!SourceAccess.readsOfficialRepository(officialCatalogue: true, state: store.state()))

        // Its own number again: read on, whatever the head then says.
        let (own, askedAgain) = await read(describe: (200, Self.describe("iillyyaa1997/udeck-plugins", id: Self.officialID)),
                                           head: failing)
        #expect(askedAgain.first == describe && askedAgain.count >= 2, "its head asked next: \(askedAgain)")
        #expect(own != .failed(.officialRepositoryChanged) && store.state().lastError != .officialRepositoryChanged)
        #expect(store.state().defaultBranchReadAt != nil)
        #expect(SourceAccess.readsOfficialRepository(officialCatalogue: true, state: store.state()))
        #expect(!SourceAccess.readsOfficialRepository(officialCatalogue: false, state: store.state()), "the switch, as ever")
    }

    @Test("a read that does not finish names the repository as it was read — GitHub's spelling — not as it was pasted")
    func lookUpFailureNamesTheReadAddress() async throws {
        let host = "spelt-\(UUID().uuidString.lowercased()).invalid"
        StubAnswers.answer(host) { request in
            switch request.url?.path {
            case "/api/repos/Someone/Team-Plugins": (200, Self.describe("someone/team-plugins"))
            default: (500, Data(#"{"message": "Server Error"}"#.utf8))
            }
        }
        defer { StubAnswers.forget(host) }
        let came = await SourceLookUp.lookUp(SourceLink(provider: "github", host: "github.com", path: "Someone/Team-Plugins"),
                                             list: SourceList(), official: .official, officialID: Self.officialID,
                                             clients: Self.clients(host))
        guard case .failed(_, "github.com", "github.com/someone/team-plugins", "github") = came else {
            Issue.record("came to \(came)"); return
        }
    }

    @Test("earlier versions stand, and install, only for a copy of the source they were read from")
    func earlierVersionsOfACopy() {
        let line = PluginHistory.Line(version: "1.0.0", commit: Self.head, date: nil, manifest: nil)
        let unlisted = PluginHistory.Line(version: "0.9.0", commit: String(repeating: "b", count: 40), date: nil, manifest: nil)
        let history = PluginHistory(id: "uptime", headCommit: Self.head, lines: [line])
        let official = InstalledPlugins.officialSource, team = "github.com-team-plugins-12345678"
        #expect(EarlierVersions.installs(line, from: history, readOf: official, copyOf: official))
        #expect(!EarlierVersions.installs(line, from: history, readOf: official, copyOf: team),
                "a list read of the official source installs nothing over the source's copy that took its place")
        #expect(!EarlierVersions.installs(line, from: history, readOf: team, copyOf: official))
        #expect(!EarlierVersions.installs(unlisted, from: history, readOf: official, copyOf: official), "only a line it lists")
        #expect(!EarlierVersions.installs(line, from: nil, readOf: official, copyOf: official), "nothing read, nothing installed")
        #expect(EarlierVersions.stands(history, readOf: team, copyOf: team, head: Self.head))
        #expect(!EarlierVersions.stands(history, readOf: official, copyOf: team, head: Self.head), "read anew for another source")
        #expect(!EarlierVersions.stands(history, readOf: team, copyOf: team, head: String(repeating: "c", count: 40)),
                "and at another head")
        #expect(!EarlierVersions.stands(nil, readOf: team, copyOf: team, head: Self.head))
    }

    // MARK: - What may be read, and when

    @Test("what may be read: the official source under its switch, a source while it is listed — whatever the switch says")
    func canRead() {
        let team = OwnSource(id: "github.com-team-plugins-12345678", provider: "github", host: "github.com",
                             path: "someone/team-plugins", remoteID: 1, addedAt: nil)
        for (source, on, sources, reads) in [
            ("official", true, [OwnSource](), true), ("official", false, [team], false),
            (team.id, false, [team], true), (team.id, true, [team], true), (team.id, true, [], false),
            ("github.com-other-12345678", true, [team], false),
        ] {
            #expect(SourceAccess.canRead(source, officialCatalogue: on, sources: sources) == reads, "\(source) \(on) \(sources.count)")
        }
        #expect(SourceAccess.clockRuns(officialCatalogue: true, sources: []))
        #expect(SourceAccess.clockRuns(officialCatalogue: false, sources: [team]), "a source listed keeps the clock")
        #expect(!SourceAccess.clockRuns(officialCatalogue: false, sources: []))
    }

    @Test("when each source is read: at launch unless read in the last day, due on the tick, when Settings opens past an hour")
    func schedule() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        func source(_ name: String) -> OwnSource {
            OwnSource(id: "github.com-\(name)-12345678", provider: "github", host: "github.com", path: "o/\(name)",
                      remoteID: name.count, addedAt: nil)
        }
        let fresh = source("fresh"), stale = source("stale"), never = source("never"), failed = source("failed"),
            tried = source("tried"), hour = source("two-hours")
        let states: [String: CatalogueState] = [
            fresh.id: CatalogueState(lastSuccess: now.addingTimeInterval(-600), lastAttempt: now.addingTimeInterval(-600)),
            stale.id: CatalogueState(lastSuccess: now.addingTimeInterval(-90_000), lastAttempt: now.addingTimeInterval(-90_000)),
            failed.id: CatalogueState(lastSuccess: now.addingTimeInterval(-90_000), lastAttempt: now.addingTimeInterval(-3700),
                                      lastError: .unreachable("offline"), failuresInARow: 1),
            tried.id: CatalogueState(lastSuccess: now.addingTimeInterval(-90_000), lastAttempt: now.addingTimeInterval(-30)),
            hour.id: CatalogueState(lastSuccess: now.addingTimeInterval(-7200), lastAttempt: now.addingTimeInterval(-7200)),
        ]
        let all = [fresh, stale, never, failed, tried, hour]
        #expect(SourceSchedule.atLaunch(all, states: states, now: now) == [stale.id, never.id, failed.id, tried.id],
                "in sources.json's order; a source read in the last day is not read at launch")
        #expect(SourceSchedule.due(all, states: states, reading: [], now: now) == [stale.id, never.id, failed.id],
                "a failure again after an hour; nothing tried in the last minute; daily otherwise")
        #expect(SourceSchedule.due(all, states: states, reading: [never.id], now: now) == [stale.id, failed.id],
                "never one being read")
        #expect(SourceSchedule.whenSettingsOpen(all, states: states, now: now)
                == [stale.id, never.id, failed.id, tried.id, hour.id], "more than an hour old")
        #expect(SourceSchedule.whenSettingsOpen([fresh], states: states, now: now.addingTimeInterval(3700)) == [fresh.id])
    }

    // MARK: - What a read that did not finish says

    @Test("why a list is not fresh: the official catalogue's words as they were; a source's naming its host and its address")
    func trouble() {
        let english = Strings(.english), russian = Strings(.russian)
        let until: (Date) -> String = { _ in "15:07" }
        func said(_ error: CatalogueError, host: String?) -> String {
            english(CatalogueTrouble.phrase(error, address: "github.com/someone/team-plugins", host: host, readAt: "14:02",
                                            until: until))
        }
        #expect(said(.notFound, host: nil) == "github.com/someone/team-plugins could not be found, or it is private.")
        #expect(said(.notFound, host: "github.com")
                == "github.com/someone/team-plugins could not be found, or it is private. If it is private, uDeck needs a token for it: Token…")
        #expect(said(.unreachable("offline"), host: nil) == "Could not reach GitHub: offline. The list below is from 14:02.")
        #expect(said(.unreachable("offline"), host: "github.com")
                == "Could not reach github.com: offline. The list below is from 14:02.")
        #expect(said(.refused(status: 451), host: "github.com") == "github.com refused the request (HTTP 451).")
        #expect(said(.badAnswer("garbled"), host: "github.com")
                == "github.com answered with something uDeck could not read: garbled.")
        #expect(said(.rateLimited(until: Date()), host: "github.com").hasPrefix("GitHub allows 60 requests an hour"),
                "anonymous github.com: the existing sentence, item 7")
        #expect(said(.officialRepositoryChanged, host: nil) == english(.catalogueOfficialRepositoryChanged))
        #expect(said(.notARepository(branch: "main"), host: "github.com")
                == "github.com/someone/team-plugins is not a uDeck plugin repository: there is no udeck-plugins.json at the top of main.")
        #expect(russian(CatalogueTrouble.phrase(.notFound, address: "github.com/o/r", host: "github.com", readAt: nil, until: until))
                == "github.com/o/r не найден или закрыт. Если он закрытый, uDeck нужен токен для него: «Токен…».")
    }

    // MARK: - A test build, and links into a source

    @Test("a test build says where each host is read from; a shipped build says nothing")
    func testBuild() {
        #expect(TestBuild.notices(infoDictionary: ["UDeckPluginsAPIBase": "https://api.github.com",
                                                   "UDeckPluginsRawBase": "https://raw.githubusercontent.com"]).isEmpty)
        #expect(TestBuild.notices(infoDictionary: nil).isEmpty)
        let lab = TestBuild.notices(infoDictionary: ["UDeckPluginsAPIBase": "http://127.0.0.1:8766/api",
                                                     "UDeckPluginsRawBase": "http://127.0.0.1:8766/raw",
                                                     "UDeckPluginsHostMap": ["gitlab.com": "http://127.0.0.1:8769"]])
        #expect(lab == [.sourcesTestBuild(host: "api.github.com", base: "http://127.0.0.1:8766/api"),
                        .sourcesTestBuild(host: "raw.githubusercontent.com", base: "http://127.0.0.1:8766/raw"),
                        .sourcesTestBuild(host: "gitlab.com", base: "http://127.0.0.1:8769")])
        #expect(Strings(.english)(lab[0]) == "Test build: api.github.com is read from http://127.0.0.1:8766/api.")
        #expect(Strings(.russian)(lab[0]) == "Тестовая сборка: api.github.com читается с http://127.0.0.1:8766/api.")
    }

    @Test("Install from a link… into a source of one's own — a branch, its page, a pull request — is not installed from yet")
    func linksIntoASource() {
        let team = OwnSource(id: "github.com-team-plugins-12345678", provider: "github", host: "github.com",
                             path: "someone/team-plugins", remoteID: 1, addedAt: nil)
        let project = OwnSource(id: "gitlab.example.test-udeck-plugins-12345678", provider: "gitlab",
                                host: "gitlab.example.test", path: "tools/udeck-plugins", remoteID: 7, addedAt: nil)
        let ported = OwnSource(id: "gitlab.example.test-8443-team-12345678", provider: "gitlab",
                               host: "gitlab.example.test:8443", path: "group/sub/team", remoteID: 9, addedAt: nil)
        let official = RepositoryAddress.official
        for (link, names) in [
            ("https://github.com/someone/team-plugins/tree/main/plugins/team-clock", true),
            ("github.com/Someone/Team-Plugins", true),
            ("https://github.com/someone/team-plugins/pull/3", true),
            ("https://github.com/someone/udeck-plugins/tree/x", false),
            ("https://github.com/iillyyaa1997/udeck-plugins/tree/fix", false),
            ("https://github.com/iillyyaa1997/udeck-plugins/pull/3", false),
            ("https://gitlab.com/someone/team-plugins", false),
            // A GitLab project added: a merge request, a branch, a folder on it, its page — as the browser shows them.
            ("https://gitlab.example.test/tools/udeck-plugins/-/merge_requests/3", true),
            ("https://gitlab.example.test/tools/udeck-plugins/-/tree/fix/plugins/gl-hello", true),
            ("gitlab.example.test/tools/udeck-plugins.git", true),
            ("https://gitlab.example.test:8443/group/sub/team/-/tree/main", true),
            // Not that project: its path on another host or port, another case, another project of the host.
            ("https://gitlab.com/tools/udeck-plugins/-/tree/fix", false),
            ("https://gitlab.example.test:8443/tools/udeck-plugins", false),
            ("https://gitlab.example.test/Tools/udeck-plugins/-/tree/fix", false),
            ("https://gitlab.example.test/tools/other/-/merge_requests/3", false),
            ("https://gitlab.example.test/group/sub/team/-/tree/main", false),
        ] {
            #expect(RepositoryLink.namesASource(link, official: official, sources: [team, project, ported]) == names, "\(link)")
            #expect(!RepositoryLink.namesASource(link, official: official, sources: []), "\(link) with no source added")
        }
        #expect(Strings(.english)(.sourceBranchNotYet)
                == "Installing from a branch or a merge request of a source is not possible yet; add the project and install from its default branch.")
        #expect(Strings(.russian)(.sourceBranchNotYet)
                == "Установка из ветки или запроса на слияние источника пока невозможна; добавьте проект и ставьте из его основной ветки.")
    }

    @Test("Your sources says, in both languages, what S4-07 and the sheet say")
    func words() {
        let english = Strings(.english), russian = Strings(.russian)
        #expect(english(.sourceNotTrusted)
                == "Not trusted: nobody vouches for these plugins — each asks again whenever its code changes.")
        #expect(russian(.sourceNotTrusted)
                == "Без доверия: за эти плагины никто не ручается — каждый спрашивает снова, когда меняется его код.")
        #expect(english(.sourcesTitle) == "Your sources" && russian(.sourcesTitle) == "Свои источники")
        #expect(english(.sourcesAdd) == "Add a source…" && russian(.sourcesAdd) == "Добавить источник…")
        #expect(english(.sourceRemove) == "Remove…" && russian(.sourceRemove) == "Удалить…")
        #expect(english(.sourcesAddField) == "github.com/owner/repo or gitlab.com/group/project")
        #expect(english(.sourceAlreadyAdded(name: "\u{2068}Team plugins\u{2069}", address: "github.com/someone/team-plugins"))
                == "\u{2068}Team plugins\u{2069} (github.com/someone/team-plugins) is added already.")
        #expect(english(.sourceAlreadyAdded(name: "github.com/o/r", address: "github.com/o/r")) == "github.com/o/r is added already.")
        #expect(english(.pluginsOfficialCatalogueHelp(source: "github.com/o/r")).hasSuffix(
            "Off, uDeck makes no request to the official repository; sources you added are read until you remove them; what is installed keeps running."))
        #expect(russian(.pluginsOfficialCatalogueHelp(source: "github.com/o/r")).hasSuffix(
            "Если выключить, uDeck не делает запросов к официальному репозиторию; добавленные вами источники читаются, пока вы их не удалите; установленное продолжает работать."))
    }
}
