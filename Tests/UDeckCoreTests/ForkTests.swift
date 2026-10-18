import Foundation
import Testing
@testable import UDeckCore
import UDeckPluginFormatFixtures

/// Branches of forks of the official repository (stage 3, R7): a fork told
/// from any other repository by what GitHub says of it; its branch read from
/// the fork itself — its head, its listing, its files, its following and its
/// comparison — through a client for the fork on the same host, counted
/// against the same limit; recorded as the fork's; and named with its fork
/// wherever a sentence names it. UDeckKit has no tests, so every decision its
/// views show is held here.
@Suite("Branches of forks")
struct ForkTests {
    let udeck = TemporaryDirectory()
    var store: CatalogueStore { CatalogueStore(paths: udeck.paths) }

    static let official = RepositoryAddress.official
    static let fork = RepositoryAddress(path: "someone/udeck-plugins")
    static let at = Date(timeIntervalSince1970: 1_790_000_000)

    /// The fork's branch `x`: what pull request #3's head is in the other
    /// suites — `uptime` 1.0.1 and `asks-nothing` new — at a commit of its own.
    static var forkHead: FakeRepository {
        var repository = RefResolverTests.pullRequestHead
        repository.commit = String(repeating: "f", count: 40)
        return repository
    }

    // MARK: - What GitHub says of a repository

    static let descriptions: [(String, Bool?, String)] = [
        (#"{"full_name": "someone/udeck-plugins", "default_branch": "main", "fork": true, "parent": {"full_name": "iillyyaa1997/udeck-plugins"}, "source": {"full_name": "iillyyaa1997/udeck-plugins"}}"#,
         true, "a fork of it"),
        (#"{"full_name": "third/udeck-plugins", "default_branch": "dev", "fork": true, "parent": {"full_name": "someone/udeck-plugins"}, "source": {"full_name": "iillyyaa1997/udeck-plugins"}}"#,
         true, "a fork of a fork of it: the network's root is what counts"),
        (#"{"full_name": "someone/udeck-plugins", "default_branch": "main", "fork": true, "source": {"full_name": "IILLYYAA1997/UDeck-Plugins"}}"#,
         true, "its name in another case"),
        (#"{"full_name": "someone/other", "default_branch": "main", "fork": true, "parent": {"full_name": "iillyyaa1997/udeck-plugins"}, "source": {"full_name": "somebody/else"}}"#,
         false, "a fork whose network grew from another repository"),
        (#"{"full_name": "someone/elsewhere", "default_branch": "main", "fork": false}"#, false, "a repository of its own"),
        (#"{"full_name": "iillyyaa1997/udeck-plugins", "default_branch": "main", "fork": false}"#, false, "the official repository itself"),
        (#"{"full_name": "someone/udeck-plugins", "default_branch": "main", "fork": true}"#, false, "a fork GitHub names no source of"),
        (#"{"full_name": "someone/udeck-plugins", "default_branch": "main"}"#, false, "no word on forking"),
        (#"{"full_name": "someone/udeck-plugins", "default_branch": "", "fork": true}"#, nil, "no default branch: not an answer"),
        ("<html>", nil, "not JSON"),
    ]

    @Test("GitHub's description of a repository, read: whether it is a fork of the official repository", arguments: 0..<descriptions.count)
    func description(row: Int) {
        let (text, fork, why) = Self.descriptions[row]
        let read = RepositoryDescription.read(Data(text.utf8))
        #expect(read.map { $0.isFork(of: Self.official) } == fork, "\(why)")
    }

    @Test("a description keeps the default branch, the name, and where the fork came from")
    func descriptionFields() throws {
        let read = try #require(RepositoryDescription.read(Data(Self.descriptions[1].0.utf8)))
        #expect(read == RepositoryDescription(fullName: "third/udeck-plugins", defaultBranch: "dev", fork: true,
                                              source: "iillyyaa1997/udeck-plugins", parent: "someone/udeck-plugins"))
    }

    // MARK: - A client per repository, one limit

    static func clients(_ host: String, limits: RateLimitRecorder = RateLimitRecorder()) -> GitHubClient {
        GitHubClient(
            endpoints: GitHubEndpoints(apiBase: URL(string: "https://\(host)/api")!, rawBase: URL(string: "https://\(host)/raw")!,
                                       repository: "iillyyaa1997/udeck-plugins"),
            udeckVersion: "0.7.0", limits: limits, session: GitHubClient.makeSession(protocolClasses: [StubAnswers.self]),
            now: { Self.at }
        )
    }

    @Test("a client for a fork: the same host's API and raw host, the fork's own path; none for another host or a path that is not owner/repo")
    func clientForAFork() throws {
        let official = Self.clients("unused.invalid")
        let fork = try #require(official.client(for: Self.fork))
        #expect(fork.address == Self.fork && fork.endpoints.repository == "someone/udeck-plugins")
        #expect(fork.endpoints.apiBase == official.endpoints.apiBase && fork.endpoints.rawBase == official.endpoints.rawBase)
        #expect(fork.comparePage(from: "a1b2c3d", to: "fffffff")?.absoluteString
                == "https://github.com/someone/udeck-plugins/compare/a1b2c3d...fffffff", "What changed opens the fork's own comparison")
        #expect(official.client(for: Self.official)?.address == Self.official)
        #expect(official.client(for: RepositoryAddress(host: "gitlab.com", path: "someone/udeck-plugins")) == nil)
        #expect(official.client(for: RepositoryAddress(provider: "gitlab", path: "someone/udeck-plugins")) == nil)
        for path in ["someone", "someone/udeck-plugins/x", "../udeck-plugins", "someone/..", "some one/x", "someone/x?y", ""] {
            #expect(official.client(for: RepositoryAddress(path: path)) == nil, "\(path)")
        }
        #expect(official.provider(for: Self.fork)?.address == Self.fork)
    }

    /// GitHub counts what an address asks, whichever repository it asks
    /// about: a fork's answers spend the official repository's hour, and a
    /// limit either learns of stops both.
    @Test("a fork's client and the official one's share one limit; a fork's description and its raw files are asked of the fork")
    func oneLimit() async throws {
        let host = "forks-\(UUID().uuidString.lowercased()).invalid"
        let reset = Date(timeIntervalSince1970: 1_790_003_600)
        let limits = RateLimitRecorder()
        let official = Self.clients(host, limits: limits)
        let fork = try #require(official.client(for: Self.fork))
        StubAnswers.answer(host) { request in
            switch request.url?.path {
            case "/api/repos/someone/udeck-plugins": (200, Data(Self.descriptions[0].0.utf8))
            case "/api/repos/iillyyaa1997/udeck-plugins": (403, Data(#"{"message": "API rate limit exceeded"}"#.utf8))
            case "/raw/someone/udeck-plugins/\(Self.forkHead.commit)/plugins/uptime/manifest.json":
                (200, Self.forkHead.data(at: "plugins/uptime/manifest.json")!)
            default: (404, Data(#"{"message": "Not Found"}"#.utf8))
            }
        }
        StubAnswers.headers(host) { request in
            guard request.url?.path.hasPrefix("/api/") == true else { return [:] }
            let left = request.url?.path == "/api/repos/iillyyaa1997/udeck-plugins" ? "0" : "41"
            return ["x-ratelimit-remaining": left, "x-ratelimit-reset": "\(Int(reset.timeIntervalSince1970))"]
        }
        defer { StubAnswers.forget(host) }

        let described = try await fork.describe()
        #expect(described.isFork(of: Self.official) && described.fullName == "someone/udeck-plugins")
        #expect(limits.current.remaining == 41, "what is left, said in the fork's answer, is the official repository's too")
        let manifest = try await official.file(of: Self.fork, at: "plugins/uptime/manifest.json", commit: Self.forkHead.commit)
        #expect(manifest == Self.forkHead.data(at: "plugins/uptime/manifest.json"))
        await #expect(throws: ProviderError.notFound) {
            _ = try await official.file(of: RepositoryAddress(host: "gitlab.com", path: "someone/udeck-plugins"),
                                        at: "plugins/uptime/manifest.json", commit: Self.forkHead.commit)
        }

        await #expect(throws: ProviderError.rateLimited(until: reset)) { _ = try await official.describe() }
        let asked = StubAnswers.asked(host).count
        await #expect(throws: ProviderError.rateLimited(until: reset), "the fork's client knows the limit the official one met") {
            _ = try await fork.head(of: "refs/heads/x", ifNoneMatch: nil)
        }
        #expect(StubAnswers.asked(host).count == asked, "and asks nothing")
        #expect(StubAnswers.asked(host).map { $0.url?.path ?? "" } == [
            "/api/repos/someone/udeck-plugins",
            "/raw/someone/udeck-plugins/\(Self.forkHead.commit)/plugins/uptime/manifest.json",
            "/api/repos/iillyyaa1997/udeck-plugins",
        ])
        #expect(StubAnswers.asked(host).allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil })
    }

    // MARK: - A fork's link, asked of GitHub

    func resolve(_ link: RepositoryLink, with official: Provider,
                 head: CommitListing? = RefResolverTests.head.listing) async throws -> RefResolver.Outcome {
        try await RefResolver(provider: official, store: store, limits: RateLimitRecorder(), now: { Self.at })
            .resolve(link, defaultBranch: "main", head: head, udeck: SemanticVersion("0.7.0"), language: "en")
    }

    @Test("a branch of a fork: whether it is a fork of the official repository, then its head, listing and manifests — all of the fork, nothing of the official repository")
    func forkBranch() async throws {
        let fork = Provider.fork(commits: [Self.forkHead], branches: ["x": Self.forkHead.commit])
        let official = Provider(commits: [RefResolverTests.head], others: [fork])
        guard case .resolved(let found) = try await resolve(.forkBranch(Self.fork, branch: "x", plugin: nil), with: official) else {
            Issue.record("a fork's branch resolves"); return
        }
        #expect(found.origin == PluginOrigin(repository: Self.fork, ref: .branch("x")))
        #expect(found.commit == Self.forkHead.commit && found.branchHead == Self.forkHead.commit && found.pullRequest == nil)
        #expect(found.fork == "someone/udeck-plugins" && found.heardAt == Self.at)
        #expect(found.entries.map(\.id) == ["asks-nothing", "uptime"], "cpu is the catalogue's own")
        #expect(fork.asked == ["describe", "head refs/heads/x", "tree \(Self.forkHead.commit) recursive"])
        #expect(Set(fork.files) == ["plugins/asks-nothing/manifest.json", "plugins/uptime/manifest.json"])
        #expect(official.asked.isEmpty && official.files.isEmpty, "nothing of a fork's branch is asked of the official repository")
        #expect(LinkRefusal.head(of: found) == [.linkHead(ref: .branch("x"), commit: "fffffff", fork: "someone/udeck-plugins")])

        guard case .resolved(let one) = try await resolve(.forkBranch(Self.fork, branch: "x", plugin: "uptime"), with: official),
              case .resolved(let same) = try await resolve(.forkBranch(Self.fork, branch: "x", plugin: "cpu"), with: official),
              case .resolved(let none) = try await resolve(.forkBranch(Self.fork, branch: "x", plugin: "gone"), with: official) else {
            Issue.record("a fork's branch resolves"); return
        }
        #expect(one.entries.map(\.id) == ["uptime"] && one.plugin == "uptime")
        #expect(LinkRefusal.head(of: same).last == .linkNothingDiffers(ref: .branch("x"), plugin: "cpu", fork: "someone/udeck-plugins"))
        #expect(LinkRefusal.head(of: none).last == .linkPluginNotThere(ref: .branch("x"), plugin: "gone", fork: "someone/udeck-plugins"))
        #expect(official.asked.isEmpty)
    }

    @Test("a fork's own page: its default branch, as its description names it, recorded as that branch of the fork")
    func forkRepository() async throws {
        let fork = Provider.fork(commits: [Self.forkHead], branches: ["trunk": Self.forkHead.commit], defaultBranch: "trunk")
        let official = Provider(commits: [RefResolverTests.head], others: [fork])
        guard case .resolved(let found) = try await resolve(.forkRepository(Self.fork), with: official) else {
            Issue.record("a fork's own page resolves"); return
        }
        #expect(found.origin == PluginOrigin(repository: Self.fork, ref: .branch("trunk")), "never the default branch's: that is the official one's")
        #expect(fork.asked == ["describe", "head refs/heads/trunk", "tree \(Self.forkHead.commit) recursive"])
        #expect(official.asked.isEmpty)
    }

    @Test("a fork renamed, or spelt in another case: GitHub's own name is asked from then on, and recorded")
    func renamed() async throws {
        let renamed = Provider.fork("someone/Renamed-Plugins", commits: [Self.forkHead], branches: ["x": Self.forkHead.commit])
        let old = Provider.fork(commits: [], fullName: "someone/Renamed-Plugins")
        let official = Provider(commits: [RefResolverTests.head], others: [old, renamed])
        guard case .resolved(let found) = try await resolve(.forkBranch(Self.fork, branch: "x", plugin: nil), with: official) else {
            Issue.record("a renamed fork's branch resolves"); return
        }
        #expect(found.origin.repository == RepositoryAddress(path: "someone/Renamed-Plugins") && found.fork == "someone/Renamed-Plugins")
        #expect(old.asked == ["describe"] && renamed.asked == ["head refs/heads/x", "tree \(Self.forkHead.commit) recursive"])
    }

    @Test("refused: a repository of its own, a fork of something else — asked once, nothing more; a fork not there; its branch not there")
    func refusals() async throws {
        let elsewhere = RepositoryAddress(path: "someone/elsewhere")
        let own = Provider(commits: [Self.forkHead], branches: ["x": Self.forkHead.commit], address: elsewhere,
                           description: RepositoryDescription(fullName: "someone/elsewhere", defaultBranch: "main", fork: false))
        let otherNetwork = Provider.fork("someone/other", commits: [Self.forkHead], branches: ["x": Self.forkHead.commit],
                                         source: "somebody/else")
        let gone = Provider(commits: [], address: RepositoryAddress(path: "someone/gone"), description: nil)
        let fork = Provider.fork(commits: [Self.forkHead], branches: ["x": Self.forkHead.commit])
        let official = Provider(commits: [RefResolverTests.head], others: [own, otherNetwork, gone, fork])

        await #expect(throws: RefResolver.Refusal.notAFork(elsewhere)) {
            _ = try await resolve(.forkBranch(elsewhere, branch: "x", plugin: "uptime"), with: official)
        }
        await #expect(throws: RefResolver.Refusal.notAFork(elsewhere)) { _ = try await resolve(.forkRepository(elsewhere), with: official) }
        #expect(own.asked == ["describe", "describe"], "its description, and no head, no listing, no file")
        #expect(own.files.isEmpty)
        await #expect(throws: RefResolver.Refusal.notAFork(otherNetwork.address)) {
            _ = try await resolve(.forkBranch(otherNetwork.address, branch: "x", plugin: nil), with: official)
        }
        #expect(otherNetwork.asked == ["describe"])
        await #expect(throws: RefResolver.Refusal.notFound(.forkRepository(gone.address))) {
            _ = try await resolve(.forkBranch(gone.address, branch: "x", plugin: nil), with: official)
        }
        await #expect(throws: RefResolver.Refusal.notFound(.forkBranch(Self.fork, branch: "gone", plugin: "uptime"))) {
            _ = try await resolve(.forkBranch(Self.fork, branch: "gone", plugin: "uptime"), with: official)
        }
        #expect(fork.asked == ["describe", "head refs/heads/gone"])
        // No client for it — another host — is nothing to ask at all.
        let alone = Provider(commits: [RefResolverTests.head])
        await #expect(throws: RefResolver.Refusal.notAFork(Self.fork)) {
            _ = try await resolve(.forkBranch(Self.fork, branch: "x", plugin: nil), with: alone)
        }
        #expect(alone.asked.isEmpty && official.asked.isEmpty)
        // A limit is the fork's client's word, passed on as it is.
        fork.limited = true
        await #expect(throws: ProviderError.rateLimited(until: Provider.until)) {
            _ = try await resolve(.forkBranch(Self.fork, branch: "x", plugin: nil), with: official)
        }
    }

    @Test("what a fork's link is refused with, said with what it is: not a fork; a fork, or its branch, not there")
    func refusalPhrases() {
        let official = "github.com/iillyyaa1997/udeck-plugins"
        #expect(LinkRefusal.phrase(RefResolver.Refusal.notAFork(RepositoryAddress(path: "someone/elsewhere")), official: .official)
                == .linkNotAForkAddAsASource(repository: "github.com/someone/elsewhere", official: official))
        #expect(LinkRefusal.phrase(RefResolver.Refusal.notFound(.forkRepository(Self.fork)), official: .official)
                == .linkNotFound(.forkRepository(Self.fork), official: official))
        let english = Strings(.english)
        let russian = Strings(.russian)
        #expect(english(.linkNotAForkAddAsASource(repository: "github.com/someone/elsewhere", official: official))
                == "github.com/someone/elsewhere is not a fork of github.com/iillyyaa1997/udeck-plugins. To install from it, "
                + "add it as a source of its own.")
        #expect(russian(.linkNotAForkAddAsASource(repository: "github.com/someone/elsewhere", official: official))
                == "github.com/someone/elsewhere — не форк github.com/iillyyaa1997/udeck-plugins. Чтобы ставить из него, "
                + "добавьте его как отдельный источник.")
        #expect(english(.linkNotFound(.forkBranch(Self.fork, branch: "x", plugin: nil), official: official))
                == "github.com/someone/udeck-plugins has no branch x — it may have been deleted.")
        #expect(russian(.linkNotFound(.forkBranch(Self.fork, branch: "x", plugin: nil), official: official))
                == "В github.com/someone/udeck-plugins нет ветки x — возможно, её удалили.")
        #expect(english(.linkNotFound(.forkRepository(Self.fork), official: official))
                == "github.com/someone/udeck-plugins could not be found — or it is private.")
        #expect(russian(.linkNotFound(.forkRepository(Self.fork), official: official))
                == "Репозиторий github.com/someone/udeck-plugins не найден — или он закрытый.")
        #expect(english(.linkRefused(.otherRepositoryPullRequest(Self.fork, 7), official: official))
                == "Pull request #7 of github.com/someone/udeck-plugins is not one of github.com/iillyyaa1997/udeck-plugins's. "
                + "Paste the link of its branch instead: a branch of a fork of github.com/iillyyaa1997/udeck-plugins can be installed from.")
        #expect(english(.linkHelp(official: official)).hasPrefix(
            "Paste the link of a pull request or a branch of github.com/iillyyaa1997/udeck-plugins, or of a branch of a fork of it."))
        #expect(russian(.linkHelp(official: official)).hasPrefix(
            "Вставьте ссылку на запрос на слияние или на ветку github.com/iillyyaa1997/udeck-plugins либо на ветку его форка."))
    }

    // MARK: - Installed from a fork's branch

    @Test("Install from a fork's branch: every file from the fork, recorded as the fork's branch, unverified; its default branch is never taken from it")
    func installFromTheFork() async throws {
        let repository = Self.forkHead
        let log = FetchLog(repository)
        let installer = PluginInstaller(paths: udeck.paths,
                                        discovery: PluginDiscovery(searchPath: ["/bin", "/usr/bin"], udeck: SemanticVersion("0.7.0")),
                                        trash: TestTrash(in: udeck.url), fetch: log.fetch, now: { Self.at })
        let request = InstallRequest(operation: .install, id: PluginIdentifier(rawValue: "uptime")!, sourceRepository: .official,
                                     repository: Self.fork, ref: .branch("x"), commit: repository.commit,
                                     folder: repository.plugin("uptime"), version: "1.0.1", headCommit: nil)
        let record = try installer.commit(try await installer.stage(request))
        #expect(!log.paths.isEmpty && log.repositories == Array(repeating: Self.fork, count: log.paths.count),
                "every file of the fork's copy from the fork")
        #expect(record.repository == Self.fork && record.ref == .branch("x") && record.source == "official")
        #expect(record.verification.status == .unverified && record.verification.by == nil)
        #expect(record.fromPhrase(official: .official) == .pluginFromBranch(name: "x", commit: "fffffff", fork: "someone/udeck-plugins"))
        #expect(record.refPage == URL(string: "https://github.com/someone/udeck-plugins/tree/x"))
        #expect(ConsentBasis.of(record, linked: false, recordsReadable: true) == .tree)

        var theirDefault = request
        theirDefault.ref = .defaultBranch("main")
        theirDefault.operation = .update
        let before = log.paths.count
        await #expect(throws: ProviderError.notFound) { _ = try await installer.stage(theirDefault) }
        #expect(log.paths.count == before, "a fork's default branch would be recorded as the official one's: nothing is fetched")
    }

    // MARK: - Following a fork's branch

    func follower(_ official: Provider) -> RefFollower {
        try? store.save(CatalogueState(defaultBranch: "main"))
        return RefFollower(provider: official, store: store, limits: RateLimitRecorder(), language: "en", now: { Self.at })
    }

    static func forkRecord(name: String = "x", repository: RepositoryAddress = fork) -> InstalledRecord {
        var record = RefFollowerTests.record(ref: .branch(name))
        record.repository = repository
        return record
    }

    @Test("a fork's branch is followed in the fork: its head with the commit installed, a moved head's listing and one comparison — nothing of the official repository")
    func followedInTheFork() async throws {
        let moved = RefFollowerTests.movedOn
        let installed = InstalledPlugins(plugins: ["uptime": Self.forkRecord()])
        let asked = "head refs/heads/x if-none-match \"\(RefFollowerTests.installedCommit)\""
        let fork = Provider.fork(commits: [moved], branches: ["x": moved.commit],
                                 comparisons: RefFollowerTests.compared(moved, .ahead))
        let official = Provider(commits: [moved], branches: ["x": RefFollowerTests.installedCommit], others: [fork])
        let outcome = await follower(official).follow(installed, headTrees: RefFollowerTests.headTrees, unrequested: false)
        #expect(official.asked.isEmpty, "the official repository's branch of the same name is another branch")
        #expect(fork.asked == [asked, "tree \(moved.commit) recursive", "compare \(RefFollowerTests.installedCommit)...\(moved.commit)"])
        #expect(fork.files == ["plugins/uptime/manifest.json"], "the copy's manifest at the moved head, from the fork")
        #expect(official.files.isEmpty)
        let heard = try #require(outcome.followed.branches["uptime"])
        #expect(heard.repository == Self.fork && heard.name == "x" && heard.head == moved.commit && heard.history?.rewritten == false)
        #expect(outcome.asked == ["uptime"])

        // What the row says, named with its fork.
        let head = RefHead(commit: moved.commit, entry: InstallFromLinkTests.entry(moved, "uptime"))
        let row = try #require(UnverifiedRow.of("uptime", record: Self.forkRecord(), followed: outcome.followed, head: head,
                                                defaultBranch: "main", readsCatalogue: true, verified: nil))
        let forkName = Self.forkRecord().origin.fork(official: .official)
        #expect(row.said(ref: .branch("x"), fork: forkName, id: "uptime", time: { _ in "" })
                == [UnverifiedRow.Said(suffix: "offer", phrase: [.pluginRefChangedStill(ref: .branch("x"), version: "1.0.1",
                                                                                         fork: "someone/udeck-plugins")])])

        // Deleted in the fork: said of the fork's branch.
        let deleted = Provider.fork(commits: [moved])
        let gone = await follower(Provider(commits: [], others: [deleted])).follow(installed, headTrees: RefFollowerTests.headTrees,
                                                                                  unrequested: false)
        #expect(deleted.asked == [asked])
        #expect(gone.followed.branches["uptime"] == FollowedBranch(name: "x", repository: Self.fork, head: nil, checkedAt: Self.at))
    }

    @Test("not asked: a fork's branch with no client for its repository — another host's — and a pull request recorded as a fork's")
    func notAskedElsewhere() async {
        var installed = InstalledPlugins()
        installed.plugins["elsewhere"] = Self.forkRecord(repository: RepositoryAddress(host: "gitlab.com", path: "someone/udeck-plugins"))
        var pull = RefFollowerTests.record(ref: .pullRequest(3))
        pull.repository = Self.fork
        installed.plugins["pull"] = pull
        let fork = Provider.fork(commits: [], branches: ["x": RefFollowerTests.installedCommit])
        let official = Provider(commits: [], others: [fork])
        let outcome = await follower(official).follow(installed, headTrees: [:], unrequested: false)
        #expect(official.asked.isEmpty && fork.asked.isEmpty && outcome.asked.isEmpty && outcome.followed == FollowedRefs())
    }

    @Test("what was heard of a branch is held to its repository: the official repository's `x` is not the fork's `x`; a file from before forks reads as either")
    func heardOfWhichBranch() {
        let forks = FollowedBranch(name: "x", repository: Self.fork, head: "h", checkedAt: Self.at)
        let officials = FollowedBranch(name: "x", repository: .official, head: "h", checkedAt: Self.at)
        let before = FollowedBranch(name: "x", head: "h", checkedAt: Self.at)
        let fromTheFork = Self.forkRecord()
        let fromTheOfficial = Self.forkRecord(repository: .official)
        #expect(FollowedRefs(branches: ["uptime": forks]).branch(of: "uptime", record: fromTheFork) == forks)
        #expect(FollowedRefs(branches: ["uptime": forks]).branch(of: "uptime", record: fromTheOfficial) == nil)
        #expect(FollowedRefs(branches: ["uptime": officials]).branch(of: "uptime", record: fromTheFork) == nil)
        #expect(FollowedRefs(branches: ["uptime": before]).branch(of: "uptime", record: fromTheOfficial) == before)
        #expect(FollowedRefs(branches: ["uptime": before]).branch(of: "uptime", record: fromTheFork) == before)
        // Written with its repository, and read back.
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        let data = try? encoder.encode(FollowedRefs(branches: ["uptime": forks]))
        #expect(data.flatMap { try? JSONDecoder().decode(FollowedRefs.self, from: $0) } == FollowedRefs(branches: ["uptime": forks]))
        #expect(data.map { String(decoding: $0, as: UTF8.self).contains("someone/udeck-plugins") } == true)
    }

    // MARK: - Said everywhere with its fork

    static let forkName = "someone/udeck-plugins"

    static let named: [(Phrase, String, String)] = [
        (.pluginFromBranch(name: "x", commit: "a1b2c3d", fork: forkName),
         "branch x of someone/udeck-plugins at a1b2c3d", "ветка x репозитория someone/udeck-plugins, коммит a1b2c3d"),
        (.linkHead(ref: .branch("x"), commit: "a1b2c3d", fork: forkName),
         "Branch x of someone/udeck-plugins at a1b2c3d", "Ветка x репозитория someone/udeck-plugins, коммит a1b2c3d"),
        (.catalogueInstalledUnverified(ref: .branch("x"), fork: forkName),
         "Installed here from branch x of someone/udeck-plugins: unverified",
         "Здесь установлен из ветки x репозитория someone/udeck-plugins: не проверен"),
        (.pluginRefAvailable(ref: .branch("x"), version: "1.0.2", fork: forkName),
         "1.0.2 available in branch x of someone/udeck-plugins", "В ветке x репозитория someone/udeck-plugins доступна 1.0.2"),
        (.pluginRefChangedStill(ref: .branch("x"), version: "1.0.1", fork: forkName),
         "Changed in branch x of someone/udeck-plugins, still 1.0.1",
         "Изменён в ветке x репозитория someone/udeck-plugins, всё ещё 1.0.1"),
        (.pluginRefNowHas(ref: .branch("x"), version: "1.0.0", fork: forkName),
         "Branch x of someone/udeck-plugins now has 1.0.0", "В ветке x репозитория someone/udeck-plugins теперь 1.0.0"),
        (.pluginRefGone(ref: .branch("x"), id: "uptime", fork: forkName),
         "uptime is no longer in branch x of someone/udeck-plugins; the plugin keeps running",
         "uptime больше нет в ветке x репозитория someone/udeck-plugins; плагин продолжает работать"),
        (.pluginRefRewritten(ref: .branch("x"), fork: forkName),
         "The history of branch x of someone/udeck-plugins was rewritten: its new head does not continue what is installed",
         "История ветки x репозитория someone/udeck-plugins переписана: новый последний коммит не продолжает установленный"),
        (.pluginBranchGone(name: "x", fork: forkName),
         "Branch x of someone/udeck-plugins no longer exists; the plugin keeps running",
         "Ветки x репозитория someone/udeck-plugins больше нет; плагин продолжает работать"),
        (.pluginRefNotCheckedSince(ref: .branch("x"), at: "14:02", fork: forkName),
         "Branch x of someone/udeck-plugins not checked since 14:02", "Ветка x репозитория someone/udeck-plugins не проверялась с 14:02"),
        (.linkNothingDiffers(ref: .branch("x"), plugin: "uptime", fork: forkName),
         "uptime in branch x of someone/udeck-plugins is what the catalogue already has: there is nothing to install from it.",
         "uptime из ветки x репозитория someone/udeck-plugins такой же, как в каталоге: устанавливать отсюда нечего."),
        (.linkPluginNotThere(ref: .branch("x"), plugin: "gone", fork: forkName),
         "Branch x of someone/udeck-plugins has no plugins/gone: there is nothing to install from it.",
         "В файлах ветки x репозитория someone/udeck-plugins нет plugins/gone: устанавливать отсюда нечего."),
        (.windowReinstallBrings(.branch(name: "x", commit: "a1b2c3d", version: "1.0.1", fork: forkName)),
         "Reinstall puts back 1.0.1 from branch x of someone/udeck-plugins at a1b2c3d: code nobody verified.",
         "«Переустановить» вернёт: версия 1.0.1 из ветки x репозитория someone/udeck-plugins, коммит a1b2c3d. Этот код никто не проверял."),
        // The official repository's own branch: nothing after its name.
        (.pluginFromBranch(name: "x", commit: "a1b2c3d"), "branch x at a1b2c3d", "ветка x, коммит a1b2c3d"),
        (.pluginBranchGone(name: "x"), "Branch x no longer exists; the plugin keeps running", "Ветки x больше нет; плагин продолжает работать"),
    ]

    @Test("a fork's branch is named with its fork, in both languages; the official repository's own is not", arguments: 0..<named.count)
    func namedWithItsFork(row: Int) {
        let (phrase, english, russian) = Self.named[row]
        #expect(Strings(.english)(phrase) == english)
        #expect(Strings(.russian)(phrase) == russian)
    }

    @Test("which repository a branch is named with: a fork's only, whatever case the official one is spelt in")
    func forkOf() {
        let branch = PluginRef.branch("x")
        #expect(PluginOrigin(repository: Self.fork, ref: branch).fork(official: .official) == "someone/udeck-plugins")
        #expect(PluginOrigin(repository: .official, ref: branch).fork(official: .official) == nil)
        #expect(PluginOrigin(repository: RepositoryAddress(path: "IILLYYAA1997/UDECK-PLUGINS"), ref: branch).fork(official: .official) == nil)
        #expect(PluginOrigin(repository: Self.fork, ref: .pullRequest(3)).fork(official: .official) == nil, "a pull request is the official repository's")
        #expect(PluginOrigin(repository: Self.fork, ref: .defaultBranch("main")).fork(official: .official) == nil)
        #expect(PluginOrigin(repository: Self.fork, ref: branch).fork(official: nil) == nil, "nothing to tell it from")
        #expect(PluginOrigin(repository: RepositoryAddress(host: "gitlab.com", path: "iillyyaa1997/udeck-plugins"), ref: branch)
                    .fork(official: .official) == "iillyyaa1997/udeck-plugins", "another host's is not the official one")
    }

    @Test("the rows of a fork's copy: the catalogue row, what its line offers, and its window's Reinstall, each with its fork")
    func rowsSayTheFork() {
        let record = Self.forkRecord()
        let fork = record.origin.fork(official: .official)
        #expect(CatalogueRowState.unverified(version: "1.0.0", refusal: nil).unverifiedLine(ref: record.ref, fork: fork, id: "uptime", path: "~")
                == [.catalogueInstalledUnverified(ref: .branch("x"), fork: "someone/udeck-plugins")])
        #expect(RefOffer(head: "h", offer: .newer(version: "1.0.2"), rewritten: false).said(ref: record.ref, fork: fork, id: "uptime")
                == [.pluginRefAvailable(ref: .branch("x"), version: "1.0.2", fork: "someone/udeck-plugins")])
        let row = UnverifiedRow(lifecycle: nil, verifiedVersion: nil, lineOffer: RefOffer(head: "h", offer: .changedStill(version: "1.0.1"), rewritten: true),
                                branchGone: true, notCheckedSince: Self.at)
        #expect(row.said(ref: record.ref, fork: fork, id: "uptime", time: { _ in "14:02" }).map(\.phrase) == [
            [.pluginBranchGone(name: "x", fork: "someone/udeck-plugins")],
            [.pluginRefRewritten(ref: .branch("x"), fork: "someone/udeck-plugins")],
            [.pluginRefChangedStill(ref: .branch("x"), version: "1.0.1", fork: "someone/udeck-plugins")],
            [.pluginRefNotCheckedSince(ref: .branch("x"), at: "14:02", fork: "someone/udeck-plugins")],
        ])
        #expect(record.reinstallSays(headTree: nil, official: .official)
                == .windowReinstallBrings(.branch(name: "x", commit: "a1b2c3d", version: "1.0.1", fork: "someone/udeck-plugins")))
    }

    // MARK: - Switches, and Back to

    func live(_ id: String) -> URL { udeck.paths.plugins.appendingPathComponent(id, isDirectory: true) }

    /// `record`'s copy on disk, exactly as recorded.
    func installed(_ record: InstalledRecord, from repository: FakeRepository) throws -> InstalledPlugins {
        for (path, file) in repository.files where path.hasPrefix("plugins/uptime/") {
            let target = live("uptime").appendingPathComponent(String(path.dropFirst("plugins/uptime/".count)))
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try file.data.write(to: target)
            try FileManager.default.setAttributes([.posixPermissions: file.mode == "100755" ? 0o755 : 0o644], ofItemAtPath: target.path)
        }
        var record = record
        record.tree = try #require(try GitHash.tree(ofDirectoryAt: live("uptime")))
        return InstalledPlugins(plugins: ["uptime": record])
    }

    @Test("Switch to verified, an earlier version and Reinstall over a fork's copy name the fork; a fork's branch over the official repository's branch of the same name is a switch that names both")
    func switchesNameTheFork() throws {
        var copy = Self.forkRecord()
        copy.commit = InstallFromLinkTests.pullCommit
        let records = try installed(copy, from: RefResolverTests.pullRequestHead)
        let catalogue = InstallFromLinkTests.catalogue(InstallFromLinkTests.head)
        let entry = try #require(catalogue.entry("uptime"))
        guard case .ask(let warning) = ShownPlace.update("uptime", catalogue: catalogue, in: udeck.paths, installed: records, shown: nil) else {
            Issue.record("a switch is warned of first"); return
        }
        #expect(warning.switching == ShownPlace.Switch(from: .branch(name: "x", commit: "a1b2c3d", version: "1.0.1", fork: "someone/udeck-plugins"),
                                                       to: .verified(version: "1.0.0", repository: "github.com/iillyyaa1997/udeck-plugins")))
        #expect(Strings(.english)(PlaceWarning.of(warning, button: .replaceCopy, id: "uptime", path: "~", link: nil))
                == "uptime is 1.0.1 from branch x of someone/udeck-plugins at a1b2c3d; installing the verified 1.0.0 from "
                + "github.com/iillyyaa1997/udeck-plugins replaces it. Its windows, settings and your permission decision stay.")
        #expect(Strings(.russian)(PlaceWarning.of(warning, button: .replaceCopy, id: "uptime", path: "~", link: nil))
                .contains("версия 1.0.1 из ветки x репозитория someone/udeck-plugins, коммит a1b2c3d"))
        #expect(warning.copy == entry.listing.tree)
        let forks = CopyName.branch(name: "x", commit: "a1b2c3d", version: "1.0.1", fork: "someone/udeck-plugins")

        // An earlier version, from the official repository's history, over the fork's copy.
        let line = PluginHistory.Line(version: "1.0.0", commit: InstallFromLinkTests.headCommit, date: nil, manifest: nil)
        guard case .ask(let earlier) = ShownPlace.earlier("uptime", line: line, source: .official, branch: "main", in: udeck.paths,
                                                          installed: records, shown: nil) else {
            Issue.record("an earlier version over a fork's copy warns first"); return
        }
        #expect(earlier.switching == ShownPlace.Switch(from: forks, to: .verified(version: "1.0.0", repository: "github.com/iillyyaa1997/udeck-plugins")))
        // Reinstall of the fork's copy whose folder is what the default branch has: the verified copy comes —
        // the fork named, from the source given, or from the catalogue's head without one.
        let merged = Adoption.DefaultBranch(repository: .official, name: "main", head: InstallFromLinkTests.headCommit,
                                            trees: ["uptime": try #require(records.plugins["uptime"]?.tree)])
        for source in [RepositoryAddress.official, nil] {
            guard case .ask(let reinstall) = ShownPlace.reinstall("uptime", in: udeck.paths, installed: records, shown: nil,
                                                                  head: merged, source: source) else {
                Issue.record("Reinstall that brings the verified copy over a fork's warns first"); return
            }
            #expect(reinstall.switching == ShownPlace.Switch(from: forks, to: .verified(version: "1.0.1", repository: "github.com/iillyyaa1997/udeck-plugins")),
                    "\(String(describing: source))")
        }

        // The official repository's own `x`, over the fork's `x`: another line, named so on both sides.
        let theirs = InstallFromLinkTests.resolution(Self.forkHead, origin: PluginOrigin(repository: .official, ref: .branch("x")))
        guard case .ask(let other) = ShownPlace.installFromLink("uptime", resolution: theirs, in: udeck.paths, installed: records,
                                                                shown: nil, source: .official) else {
            Issue.record("another repository's branch of the same name is a switch"); return
        }
        #expect(other.switching == ShownPlace.Switch(from: .branch(name: "x", commit: "a1b2c3d", version: "1.0.1", fork: "someone/udeck-plugins"),
                                                     to: .branch(name: "x", commit: "fffffff", version: "1.0.1")))
        // The same fork's same branch at a later head: the same line, no switch.
        let along = InstallFromLinkTests.resolution(Self.forkHead, origin: copy.origin)
        if case .ask(let place) = ShownPlace.installFromLink("uptime", resolution: along, in: udeck.paths, installed: records,
                                                            shown: nil, source: .official) {
            Issue.record("the same line is an update, not a switch: \(place)")
        }
    }

    @Test("Back to a fork's copy: from the fork, at its branch — the previous copy's repository; Reinstall names the fork")
    func backToTheFork() throws {
        var current = RefFollowerTests.record(ref: .defaultBranch("main"))
        current.commit = InstallFromLinkTests.headCommit
        current.version = "1.0.0"
        current.previous = PreviousCopy(ref: .branch("x"), commit: Self.forkHead.commit, tree: Self.forkHead.plugin("uptime").tree,
                                        version: "1.0.1", repository: Self.fork)
        let records = try installed(current, from: InstallFromLinkTests.head)
        guard case .ask(let warning) = ShownPlace.backToPrevious("uptime", source: .official, in: udeck.paths, installed: records,
                                                                 shown: nil) else {
            Issue.record("Back to across two lines of history warns first"); return
        }
        #expect(warning.switching?.to == .branch(name: "x", commit: "fffffff", version: "1.0.1", fork: "someone/udeck-plugins"))
        let step = ShownPlace.backToPrevious("uptime", source: .official, in: udeck.paths, installed: records, shown: warning)
        #expect(step == .atCommit(.earlier, commit: Self.forkHead.commit, version: "1.0.1",
                                  from: PluginOrigin(repository: Self.fork, ref: .branch("x"))),
                "taken from the fork it came from, at its branch")
        // A previous copy recorded before forks — no repository — comes from the source's own.
        var old = records
        old.plugins["uptime"]?.previous?.repository = nil
        #expect(ShownPlace.backToPrevious("uptime", source: .official, in: udeck.paths, installed: old, shown: warning) != step)
        guard case .ask(let fromItsOwn) = ShownPlace.backToPrevious("uptime", source: .official, in: udeck.paths, installed: old,
                                                                    shown: nil) else {
            Issue.record("still a switch, of the official repository's own branch"); return
        }
        #expect(fromItsOwn.switching?.to == .branch(name: "x", commit: "fffffff", version: "1.0.1"))
        // Reinstall names the fork, from the source given.
        var forkCopy = Self.forkRecord()
        forkCopy.commit = InstallFromLinkTests.pullCommit
        let forkRecords = InstalledPlugins(plugins: ["uptime": forkCopy])
        try? FileManager.default.removeItem(at: live("uptime"))
        _ = ShownPlace.reinstall("uptime", in: udeck.paths, installed: forkRecords, shown: nil, source: .official)
        #expect(forkCopy.reinstallSays(headTree: nil, official: .official)
                == .windowReinstallBrings(.branch(name: "x", commit: "a1b2c3d", version: "1.0.1", fork: "someone/udeck-plugins")))
    }
}

// MARK: - A repository addressed by its number (stage 4, R1a)

/// GitHub's numeric id, read from its description, and a client that names
/// the repository by it — `/repositories/{id}/…` — for every API request,
/// raw files still by its path at a commit. Nothing uDeck builds uses it yet;
/// what it asks is held here, against answers of the test's own.
extension ForkTests {
    static let ids: [(String, Int?, String)] = [
        (#"{"id": 1393324153, "full_name": "iillyyaa1997/udeck-plugins", "default_branch": "main"}"#, 1_393_324_153,
         "the official repository's, as GitHub answered it"),
        (#"{"full_name": "o/r", "default_branch": "main"}"#, nil, "no id"),
        (#"{"id": "1393324153", "full_name": "o/r", "default_branch": "main"}"#, nil, "an id that is not a number"),
        (#"{"id": 0, "full_name": "o/r", "default_branch": "main"}"#, nil, "an id that is no repository's"),
        (#"{"id": -4, "full_name": "o/r", "default_branch": "main"}"#, nil, "a negative id"),
        (#"{"id": 1.5, "full_name": "o/r", "default_branch": "main"}"#, nil, "a fraction"),
    ]

    @Test("a description says the repository's id; an id that is not one costs the id, not the answer", arguments: 0..<ids.count)
    func descriptionID(row: Int) throws {
        let (text, id, why) = Self.ids[row]
        let read = try #require(RepositoryDescription.read(Data(text.utf8)), "\(why)")
        #expect(read.id == id, "\(why)")
        #expect(read.defaultBranch == "main" && read.fullName != nil)
    }

    /// Every question a source asks, by id: describe, the head, the listing,
    /// a folder's history, a pull request, a comparison — and raw files by
    /// the repository's path at a commit, which each is hashed against.
    @Test("addressed by id, every API request goes to /repositories/{id}/…, and raw files by the path at a commit")
    func addressedByID() async throws {
        let host = "byid-\(UUID().uuidString.lowercased()).invalid"
        let commit = String(repeating: "a", count: 40), other = String(repeating: "b", count: 40)
        let client = GitHubClient(
            endpoints: GitHubEndpoints(apiBase: URL(string: "https://\(host)/api")!, rawBase: URL(string: "https://\(host)/raw")!,
                                       repository: "someone/team-plugins"),
            udeckVersion: "0.8.0", limits: RateLimitRecorder(), session: GitHubClient.makeSession(protocolClasses: [StubAnswers.self]),
            now: { Self.at }, addressing: .id(123_456_789)
        )
        #expect(client.addressing == .id(123_456_789) && client.address == RepositoryAddress(path: "someone/team-plugins"))
        StubAnswers.answer(host) { request in
            switch request.url?.path {
            case "/api/repositories/123456789":
                (200, Data(#"{"id": 123456789, "full_name": "someone/renamed", "default_branch": "main", "fork": false}"#.utf8))
            case "/api/repositories/123456789/commits/main": (200, Data(commit.utf8))
            case "/api/repositories/123456789/git/trees/\(commit)": (200, Data(#"{"sha": "\#(commit)", "tree": []}"#.utf8))
            case "/api/repositories/123456789/commits":
                (200, Data(#"[{"sha": "\#(commit)", "commit": {"committer": {"date": "2026-10-18T10:00:00Z"}}}]"#.utf8))
            case "/api/repositories/123456789/pulls/3":
                (200, Data(#"{"number": 3, "state": "open", "head": {"sha": "\#(commit)", "ref": "x"}}"#.utf8))
            case "/api/repositories/123456789/compare/\(commit)...\(other)":
                (200, Data(#"{"status": "ahead", "ahead_by": 1, "behind_by": 0}"#.utf8))
            case "/raw/someone/team-plugins/\(commit)/udeck-plugins.json": (200, Data("{}".utf8))
            default: (404, Data(#"{"message": "Not Found"}"#.utf8))
            }
        }
        defer { StubAnswers.forget(host) }

        let described = try await client.describe()
        #expect(described.id == 123_456_789 && described.fullName == "someone/renamed", "the spelling it has now, said by id")
        #expect(try await client.head(of: "main", ifNoneMatch: nil) == .commit(commit, etag: nil))
        #expect(try await client.tree(commit, recursive: true) == GitTree(sha: commit, tree: []))
        #expect(try await client.commits(touching: "plugins/uptime", on: "main").map(\.sha) == [commit])
        #expect(try await client.pull(3).head == commit)
        #expect(try await client.compare(commit, other) == Comparison(status: .ahead, aheadBy: 1, behindBy: 0))
        #expect(try await client.file(at: "udeck-plugins.json", commit: commit) == Data("{}".utf8))
        let asked = StubAnswers.asked(host)
        #expect(asked.map { $0.url?.path ?? "" } == [
            "/api/repositories/123456789",
            "/api/repositories/123456789/commits/main",
            "/api/repositories/123456789/git/trees/\(commit)",
            "/api/repositories/123456789/commits",
            "/api/repositories/123456789/pulls/3",
            "/api/repositories/123456789/compare/\(commit)...\(other)",
            "/raw/someone/team-plugins/\(commit)/udeck-plugins.json",
        ])
        #expect(asked[1].value(forHTTPHeaderField: "Accept") == "application/vnd.github.sha")
        #expect(asked[2].url?.query == "recursive=1" && asked[3].url?.query?.contains("sha=main") == true)
        #expect(!asked.contains { $0.url?.path.contains("/repos/") == true }, "nothing addressed by the name")
        #expect(asked.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil })
        #expect(client.folderPage("plugins/uptime", commit: commit)?.absoluteString
                == "https://github.com/someone/team-plugins/tree/\(commit)/plugins/uptime", "pages a person reads by the name")
    }

    /// The id names one repository: a client for the same one, whatever the
    /// case of its name, is the client itself; for any other path — the
    /// source's earlier name among them, which another repository may have
    /// now — there is none, so no request of a source's ever goes by a name;
    /// and a path addressed client is exactly what it was, a fork's by path.
    @Test("addressed by id, a client for its own repository is itself, and for any other path there is none")
    func addressingAcrossClients() throws {
        let byID = GitHubClient(
            endpoints: GitHubEndpoints(apiBase: URL(string: "https://unused.invalid/api")!,
                                       rawBase: URL(string: "https://unused.invalid/raw")!, repository: "someone/renamed"),
            udeckVersion: "0.8.0", limits: RateLimitRecorder(), addressing: .id(123_456_789))
        let own = try #require(byID.client(for: RepositoryAddress(path: "Someone/Renamed")))
        #expect(own.addressing == .id(123_456_789) && own.address == RepositoryAddress(path: "someone/renamed"))
        #expect(byID.client(for: RepositoryAddress(path: "someone/team-plugins")) == nil,
                "its name before the rename: a squatter's now, perhaps")
        #expect(byID.client(for: Self.fork) == nil && byID.provider(for: Self.fork) == nil, "another repository")
        #expect(byID.client(for: RepositoryAddress(provider: "gitlab", host: "gitlab.com", path: "someone/renamed")) == nil)
        let official = Self.clients("unused.invalid")
        #expect(official.addressing == .path, "the official client is addressed by path, as in stage 3")
        let fork = try #require(official.client(for: Self.fork))
        #expect(fork.addressing == .path && fork.address == Self.fork, "a fork of the official one: by its own path")
    }

    /// The path addressed client asks exactly what it asked: the official
    /// repository's questions are stage 3's.
    @Test("addressed by path, the questions are stage 3's own")
    func addressedByPath() async throws {
        let host = "bypath-\(UUID().uuidString.lowercased()).invalid"
        let client = Self.clients(host)
        StubAnswers.answer(host) { request in
            request.url?.path == "/api/repos/iillyyaa1997/udeck-plugins"
                ? (200, Data(#"{"id": 1393324153, "full_name": "iillyyaa1997/udeck-plugins", "default_branch": "main"}"#.utf8))
                : (404, Data())
        }
        defer { StubAnswers.forget(host) }
        #expect(try await client.describe().id == 1_393_324_153)
        #expect(StubAnswers.asked(host).map { $0.url?.path ?? "" } == ["/api/repos/iillyyaa1997/udeck-plugins"])
    }
}
