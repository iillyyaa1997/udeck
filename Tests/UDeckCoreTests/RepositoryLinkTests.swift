import Foundation
import Testing
@testable import UDeckCore
import UDeckPluginFormatFixtures

/// A link pasted into **Install from a link…**, read without asking GitHub
/// anything (`RepositoryLink`).
@Suite("A github.com link, read")
struct RepositoryLinkTests {
    static let official = RepositoryAddress(path: "iillyyaa1997/udeck-plugins")
    static let fork = RepositoryAddress(path: "someone/udeck-plugins")

    static func read(_ text: String) -> Result<RepositoryLink, RepositoryLink.Refusal> {
        RepositoryLink.read(text, official: official)
    }

    static let accepted: [(String, RepositoryLink)] = [
        // Pull requests of the official repository, and any page under one.
        ("https://github.com/iillyyaa1997/udeck-plugins/pull/3", .pullRequest(3)),
        ("github.com/iillyyaa1997/udeck-plugins/pull/3", .pullRequest(3)),
        ("http://www.github.com/iillyyaa1997/udeck-plugins/pull/3/", .pullRequest(3)),
        ("https://github.com/iillyyaa1997/udeck-plugins/pull/3/files", .pullRequest(3)),
        ("https://github.com/iillyyaa1997/udeck-plugins/pull/3/commits/0123456789abcdef0123456789abcdef01234567",
         .pullRequest(3)),
        ("https://github.com/iillyyaa1997/udeck-plugins/pull/12?diff=split#discussion_r1", .pullRequest(12)),
        ("  https://GitHub.com/IILLYYAA1997/UDeck-Plugins/pull/3\n", .pullRequest(3)),
        ("HTTPS://github.com/iillyyaa1997/udeck-plugins/pull/3", .pullRequest(3)),
        // Branches of the official repository: up to the last plugins/<id>.
        ("https://github.com/iillyyaa1997/udeck-plugins/tree/main", .branch("main", plugin: nil)),
        ("https://github.com/iillyyaa1997/udeck-plugins/tree/first-plugin", .branch("first-plugin", plugin: nil)),
        ("https://github.com/iillyyaa1997/udeck-plugins/tree/feature/uptime", .branch("feature/uptime", plugin: nil)),
        ("https://github.com/iillyyaa1997/udeck-plugins/tree/feature/x/plugins/uptime",
         .branch("feature/x", plugin: "uptime")),
        ("https://github.com/iillyyaa1997/udeck-plugins/tree/feature/x/plugins/uptime/lib/run.sh",
         .branch("feature/x", plugin: "uptime")),
        ("https://github.com/iillyyaa1997/udeck-plugins/tree/a/plugins/b/plugins/uptime",
         .branch("a/plugins/b", plugin: "uptime")),
        ("https://github.com/iillyyaa1997/udeck-plugins/tree/plugins/uptime", .branch("plugins/uptime", plugin: nil)),
        ("https://github.com/iillyyaa1997/udeck-plugins/tree/main/plugins", .branch("main/plugins", plugin: nil)),
        ("https://github.com/iillyyaa1997/udeck-plugins/tree/main/plugins/Not_An_Id",
         .branch("main/plugins/Not_An_Id", plugin: nil)),
        ("https://github.com/iillyyaa1997/udeck-plugins/tree/feature%2Fx/plugins/uptime",
         .branch("feature/x", plugin: "uptime")),
        ("https://github.com/iillyyaa1997/udeck-plugins/tree/caf%C3%A9", .branch("café", plugin: nil)),
        // Hexadecimal short of a commit's id is a branch's name like any other.
        ("https://github.com/iillyyaa1997/udeck-plugins/tree/0123abc", .branch("0123abc", plugin: nil)),
        // The official repository's own page.
        ("https://github.com/iillyyaa1997/udeck-plugins", .officialRepository),
        ("github.com/iillyyaa1997/udeck-plugins/", .officialRepository),
        ("https://github.com/iillyyaa1997/udeck-plugins.git", .officialRepository),
        // Other repositories, which may be forks of it.
        ("https://github.com/someone/udeck-plugins", .forkRepository(fork)),
        ("https://github.com/someone/udeck-plugins/tree/fix/uptime-load",
         .forkBranch(fork, branch: "fix/uptime-load", plugin: nil)),
        ("https://github.com/someone/udeck-plugins/tree/fix/plugins/uptime/manifest.json",
         .forkBranch(fork, branch: "fix", plugin: "uptime")),
    ]

    @Test("what each form names", arguments: 0..<accepted.count)
    func reads(row: Int) {
        let (text, wanted) = Self.accepted[row]
        #expect(Self.read(text) == .success(wanted), "\(text.debugDescription)")
    }

    static let refused: [(String, RepositoryLink.Refusal)] = [
        ("", .empty),
        ("   \n", .empty),
        ("github.com", .notALink),
        ("https://github.com/iillyyaa1997", .notALink),
        ("iillyyaa1997/udeck-plugins/pull/3", .notALink),
        ("git@github.com:iillyyaa1997/udeck-plugins.git", .notALink),
        ("ssh://git@github.com/iillyyaa1997/udeck-plugins", .notALink),
        ("https://github.com:443/iillyyaa1997/udeck-plugins/pull/3", .notALink),
        ("https://user@github.com/iillyyaa1997/udeck-plugins/pull/3", .notALink),
        ("https://github.com/iilly_yaa/udeck-plugins", .notALink),
        ("https://github.com/iillyyaa1997/..", .notALink),
        ("https://github.com/iillyyaa1997/udeck%2Fplugins", .notALink),
        ("https://github.com/iillyyaa1997/udeck-plugins/tree/%E0%A4%A", .notALink),
        ("https://gitlab.com/iillyyaa1997/udeck-plugins/-/merge_requests/3", .notGitHub(host: "gitlab.com")),
        ("https://raw.githubusercontent.com/iillyyaa1997/udeck-plugins/main/udeck-plugins.json",
         .notGitHub(host: "raw.githubusercontent.com")),
        ("https://api.github.com/repos/iillyyaa1997/udeck-plugins/pulls/3", .notGitHub(host: "api.github.com")),
        ("https://github.com/iillyyaa1997/udeck-plugins/commit/0123456789abcdef0123456789abcdef01234567",
         .commit("0123456789abcdef0123456789abcdef01234567")),
        // GitHub's *Browse files* at a commit: a commit's link, not a branch's.
        ("https://github.com/iillyyaa1997/udeck-plugins/tree/0123456789abcdef0123456789abcdef01234567",
         .commit("0123456789abcdef0123456789abcdef01234567")),
        ("https://github.com/iillyyaa1997/udeck-plugins/tree/0123456789abcdef0123456789abcdef01234567/plugins/uptime",
         .commit("0123456789abcdef0123456789abcdef01234567")),
        ("https://github.com/someone/udeck-plugins/tree/0123456789abcdef0123456789abcdef01234567",
         .commit("0123456789abcdef0123456789abcdef01234567")),
        ("https://github.com/someone/udeck-plugins/pull/7", .otherRepositoryPullRequest(fork, 7)),
        ("https://github.com/iillyyaa1997/udeck-plugins/pull", .unsupported(page: "pull")),
        ("https://github.com/iillyyaa1997/udeck-plugins/pull/0", .unsupported(page: "pull")),
        ("https://github.com/iillyyaa1997/udeck-plugins/pull/-3", .unsupported(page: "pull")),
        ("https://github.com/iillyyaa1997/udeck-plugins/pull/3a", .unsupported(page: "pull")),
        ("https://github.com/iillyyaa1997/udeck-plugins/pull/1234567890", .unsupported(page: "pull")),
        ("https://github.com/iillyyaa1997/udeck-plugins/pulls", .unsupported(page: "pulls")),
        ("https://github.com/iillyyaa1997/udeck-plugins/issues/3", .unsupported(page: "issues")),
        ("https://github.com/iillyyaa1997/udeck-plugins/blob/main/plugins/uptime/manifest.json", .unsupported(page: "blob")),
        ("https://github.com/iillyyaa1997/udeck-plugins/tree", .unsupported(page: "tree")),
        ("https://github.com/iillyyaa1997/udeck-plugins/tree/a..b", .notABranch("a..b")),
        ("https://github.com/iillyyaa1997/udeck-plugins/tree/.hidden", .notABranch(".hidden")),
        ("https://github.com/iillyyaa1997/udeck-plugins/tree/x/.hidden", .notABranch("x/.hidden")),
        ("https://github.com/iillyyaa1997/udeck-plugins/tree/x.lock", .notABranch("x.lock")),
        ("https://github.com/iillyyaa1997/udeck-plugins/tree/x.", .notABranch("x.")),
        ("https://github.com/iillyyaa1997/udeck-plugins/tree/-x", .notABranch("-x")),
        ("https://github.com/iillyyaa1997/udeck-plugins/tree/@", .notABranch("@")),
        ("https://github.com/iillyyaa1997/udeck-plugins/tree/a@%7Bb", .notABranch("a@{b")),
        ("https://github.com/iillyyaa1997/udeck-plugins/tree/a%20b", .notABranch("a b")),
        ("https://github.com/iillyyaa1997/udeck-plugins/tree/a~1", .notABranch("a~1")),
        ("https://github.com/iillyyaa1997/udeck-plugins/tree/a%5Eb", .notABranch("a^b")),
        ("https://github.com/iillyyaa1997/udeck-plugins/tree/a:b", .notABranch("a:b")),
        ("https://github.com/iillyyaa1997/udeck-plugins/tree/a*b", .notABranch("a*b")),
        ("https://github.com/iillyyaa1997/udeck-plugins/tree/a%5Bb", .notABranch("a[b")),
        ("https://github.com/iillyyaa1997/udeck-plugins/tree/a%5Cb", .notABranch("a\\b")),
        ("https://github.com/iillyyaa1997/udeck-plugins/tree/a%09b", .notABranch("a\tb")),
        ("https://github.com/iillyyaa1997/udeck-plugins/tree/a%7Fb", .notABranch("a\u{7F}b")),
    ]

    @Test("what each refusal says it is", arguments: 0..<refused.count)
    func refuses(row: Int) {
        let (text, wanted) = Self.refused[row]
        #expect(Self.read(text) == .failure(wanted), "\(text.debugDescription)")
    }

    /// A query is cut before it is read, so `?` in a pasted link never
    /// reaches the branch's name; the same for a fragment.
    @Test("a query and a fragment are not part of a branch")
    func queryAndFragment() {
        #expect(Self.read("https://github.com/iillyyaa1997/udeck-plugins/tree/main?x=1")
                == .success(.branch("main", plugin: nil)))
        #expect(Self.read("https://github.com/iillyyaa1997/udeck-plugins/tree/main#readme")
                == .success(.branch("main", plugin: nil)))
    }
}

/// What a link comes to once GitHub is asked (`RefResolver`), against a
/// provider of the test's own that answers from repositories in memory and
/// counts what it was asked.
@Suite("A link, asked of GitHub")
struct RefResolverTests {
    let temp = TemporaryDirectory()
    var store: CatalogueStore { CatalogueStore(paths: temp.paths) }

    /// The official catalogue's head: `uptime` 1.0.0 and `cpu`.
    static var head: FakeRepository {
        var repository = FakeRepository.withUptime()
        repository.addPlugin("cpu")
        repository.commit = String(repeating: "1", count: 40)
        return repository
    }

    /// Pull request #3's head: `uptime` changed, `cpu` as it is, and
    /// `asks-nothing` new.
    static var pullRequestHead: FakeRepository {
        var repository = head
        repository.addPlugin("uptime", version: "1.0.1")
        repository.addPlugin("asks-nothing", manifest: FakeRepository.manifest(id: "asks-nothing", permissions: "{}"))
        repository.commit = String(repeating: "3", count: 40)
        return repository
    }

    func resolver(_ provider: Provider) -> RefResolver {
        RefResolver(provider: provider, store: store, limits: RateLimitRecorder())
    }

    func resolve(_ link: RepositoryLink, with provider: Provider, defaultBranch: String? = "main",
                 head: CommitListing? = RefResolverTests.head.listing) async throws -> RefResolver.Outcome {
        try await resolver(provider).resolve(link, defaultBranch: defaultBranch, head: head,
                                             udeck: SemanticVersion("0.7.0"), language: "en")
    }

    @Test("a pull request: its head through the official repository, recorded as `pr` and its number, and only what differs from the head")
    func pullRequest() async throws {
        let provider = Provider(commits: [Self.pullRequestHead], pulls: [3: Provider.pull(3, head: Self.pullRequestHead.commit,
                                                                                         from: "someone/udeck-plugins")])
        guard case .resolved(let found) = try await resolve(.pullRequest(3), with: provider) else {
            Issue.record("a pull request resolves"); return
        }
        #expect(found.origin == PluginOrigin(repository: provider.address, ref: .pullRequest(3)))
        #expect(found.commit == Self.pullRequestHead.commit && found.listing.commit == found.commit)
        #expect(found.entries.map(\.id) == ["asks-nothing", "uptime"], "cpu is the head's own")
        #expect(found.entries.first { $0.id == "uptime" }?.manifest?.version == "1.0.1")
        #expect(found.entries.first { $0.id == "asks-nothing" }?.manifest?.permissions.capabilities == [])
        #expect(found.pullRequest?.headRepository == "someone/udeck-plugins")
        #expect(found.defaultBranch == "main", "the default branch as it was known: what a merge is said against")
        #expect(provider.asked == ["pull 3", "tree \(Self.pullRequestHead.commit) recursive"],
                "one request for the pull request, one for its listing")
        #expect(Set(provider.files) == ["plugins/asks-nothing/manifest.json", "plugins/uptime/manifest.json"],
                "the manifests of what it lists, by commit, and nothing else")
        // Asked again: the listing and the manifests are the cache's.
        _ = try await resolve(.pullRequest(3), with: provider)
        #expect(provider.asked == ["pull 3", "tree \(Self.pullRequestHead.commit) recursive", "pull 3"])
        #expect(provider.files.count == 2)
    }

    @Test("a branch: its head by refs/heads, recorded as `branch`; a link into a folder lists that plugin only")
    func branch() async throws {
        let provider = Provider(commits: [Self.pullRequestHead], branches: ["feature/x": Self.pullRequestHead.commit])
        guard case .resolved(let found) = try await resolve(.branch("feature/x", plugin: nil), with: provider) else {
            Issue.record("a branch resolves"); return
        }
        #expect(found.origin == PluginOrigin(repository: provider.address, ref: .branch("feature/x")))
        #expect(found.entries.map(\.id) == ["asks-nothing", "uptime"] && found.pullRequest == nil)
        #expect(found.defaultBranch == "main")
        #expect(provider.asked == ["head refs/heads/feature/x", "tree \(Self.pullRequestHead.commit) recursive"])

        guard case .resolved(let one) = try await resolve(.branch("feature/x", plugin: "uptime"), with: provider) else {
            Issue.record("a branch resolves"); return
        }
        #expect(one.entries.map(\.id) == ["uptime"] && one.plugin == "uptime")
        guard case .resolved(let same) = try await resolve(.branch("feature/x", plugin: "cpu"), with: provider) else {
            Issue.record("a branch resolves"); return
        }
        #expect(same.entries.isEmpty && same.plugin == "cpu", "cpu there is what the head has")
        #expect(LinkRefusal.head(of: same).last == .linkNothingDiffers(ref: .branch("feature/x"), plugin: "cpu"))
        guard case .resolved(let none) = try await resolve(.branch("feature/x", plugin: "gone"), with: provider) else {
            Issue.record("a branch resolves"); return
        }
        #expect(none.entries.isEmpty && LinkRefusal.head(of: none).last == .linkPluginNotThere(ref: .branch("feature/x"), plugin: "gone"))
        guard case .resolved(let whole) = try await resolve(.branch("feature/x", plugin: nil), with: provider) else {
            Issue.record("a branch resolves"); return
        }
        #expect(whole.plugin == nil)
        // Nothing to compare with: everything there is new.
        guard case .resolved(let all) = try await resolve(.branch("feature/x", plugin: nil), with: provider, head: nil) else {
            Issue.record("a branch resolves"); return
        }
        #expect(all.entries.map(\.id) == ["asks-nothing", "cpu", "uptime"])
    }

    @Test("the default branch and the repository's own page are the catalogue, asked for the default branch only when it is not known")
    func theCatalogue() async throws {
        let provider = Provider(commits: [Self.head], branches: ["main": Self.head.commit])
        #expect(try await resolve(.officialRepository, with: provider) == .catalogue(plugin: nil))
        #expect(try await resolve(.branch("main", plugin: "uptime"), with: provider) == .catalogue(plugin: "uptime"))
        #expect(try await resolve(.branch("main", plugin: "gone"), with: provider) == .catalogue(plugin: nil),
                "a plugin the catalogue's head does not have is not said to be in the catalogue below")
        #expect(try await resolve(.branch("main", plugin: "uptime"), with: provider, head: nil) == .catalogue(plugin: nil),
                "nothing to look in: nothing said of the plugin")
        #expect(provider.asked.isEmpty)
        #expect(try await resolve(.branch("main", plugin: nil), with: provider, defaultBranch: nil) == .catalogue(plugin: nil))
        #expect(provider.asked == ["default branch"])
        // A branch called Main is not main.
        await #expect(throws: RefResolver.Refusal.notFound(.branch("Main", plugin: nil))) {
            _ = try await resolve(.branch("Main", plugin: nil), with: provider)
        }
    }

    @Test("a branch or a pull request that is not there, and a fork, are refused with what they are")
    func refusals() async throws {
        let provider = Provider(commits: [Self.head])
        await #expect(throws: RefResolver.Refusal.notFound(.pullRequest(9))) {
            _ = try await resolve(.pullRequest(9), with: provider)
        }
        await #expect(throws: RefResolver.Refusal.notFound(.branch("gone", plugin: nil))) {
            _ = try await resolve(.branch("gone", plugin: nil), with: provider)
        }
        let fork = RepositoryAddress(path: "someone/udeck-plugins")
        await #expect(throws: RefResolver.Refusal.notAFork(fork)) {
            _ = try await resolve(.forkBranch(fork, branch: "x", plugin: nil), with: provider)
        }
        await #expect(throws: RefResolver.Refusal.notAFork(fork)) {
            _ = try await resolve(.forkRepository(fork), with: provider)
        }
        #expect(provider.asked == ["pull 9", "head refs/heads/gone"], "nothing is asked about a fork yet")
        // A limit is the provider's word, passed on as it is.
        provider.limited = true
        await #expect(throws: ProviderError.rateLimited(until: Provider.until)) {
            _ = try await resolve(.pullRequest(3), with: provider)
        }
    }

    @Test("what differs from the head: new, or another tree; only the plugin named")
    func differing() {
        let at = Self.pullRequestHead.listing
        let head = Self.head.listing
        #expect(RefResolver.differing(at, from: head, only: nil) == ["asks-nothing", "uptime"])
        #expect(RefResolver.differing(at, from: nil, only: nil) == ["asks-nothing", "cpu", "uptime"])
        #expect(RefResolver.differing(at, from: head, only: "uptime") == ["uptime"])
        #expect(RefResolver.differing(at, from: head, only: "cpu") == [])
        #expect(RefResolver.differing(at, from: head, only: "gone") == [])
        #expect(RefResolver.differing(head, from: head, only: nil) == [])
    }
}

/// A provider of the test's own: repositories in memory, by commit, and what
/// it was asked, in order. A head asked with `If-None-Match` answers
/// unchanged when it is that commit, as GitHub's `304`; two commits are
/// compared by what the test says of them (`comparisons`), and a commit the
/// test does not name in one is not there. The same host's other
/// repositories — a fork — are providers of their own (`others`), each with
/// its own log, which `provider(for:)` answers; any other is not there.
final class Provider: RepositoryProvider, @unchecked Sendable {
    let address: RepositoryAddress
    /// What `GET /repos/{o}/{r}` says of it; nil: not there.
    let description: RepositoryDescription?
    let others: [RepositoryAddress: Provider]
    private let lock = NSLock()
    private var log: [String] = []
    private var fetched: [String] = []
    private var isLimited = false
    private var failing: Set<String> = []
    private var hook: (@Sendable (String) -> Void)?
    let commits: [String: FakeRepository]
    let branches: [String: String]
    let pulls: [Int: PullRequest]
    /// `"<base>...<head>"` → how they compare.
    let comparisons: [String: Comparison]
    static let until = Date(timeIntervalSince1970: 1_790_003_600)

    init(commits: [FakeRepository], branches: [String: String] = [:], pulls: [Int: PullRequest] = [:],
         comparisons: [String: Comparison] = [:], address: RepositoryAddress = .official,
         description: RepositoryDescription? = RepositoryDescription(fullName: nil, defaultBranch: "main", fork: false),
         others: [Provider] = []) {
        self.commits = Dictionary(uniqueKeysWithValues: commits.map { ($0.commit, $0) })
        self.branches = branches
        self.pulls = pulls
        self.comparisons = comparisons
        self.address = address
        self.description = description
        self.others = Dictionary(uniqueKeysWithValues: others.map { ($0.address, $0) })
    }

    /// A fork of the official repository at `path`, as GitHub describes one.
    static func fork(_ path: String = "someone/udeck-plugins", commits: [FakeRepository], branches: [String: String] = [:],
                     comparisons: [String: Comparison] = [:], defaultBranch: String = "main", fullName: String? = nil,
                     source: String = "iillyyaa1997/udeck-plugins") -> Provider {
        Provider(commits: commits, branches: branches, comparisons: comparisons, address: RepositoryAddress(path: path),
                 description: RepositoryDescription(fullName: fullName ?? path, defaultBranch: defaultBranch, fork: true,
                                                    source: source, parent: source))
    }

    /// Requests beginning with one of these get no answer at all.
    var unreachable: Set<String> {
        get { lock.withLock { failing } }
        set { lock.withLock { failing = newValue } }
    }

    static func pull(_ number: Int, head: String, from repository: String?, state: PullRequest.State = .open,
                     merged: Bool = false) -> PullRequest {
        PullRequest(number: number, state: state, merged: merged, mergeCommit: nil, head: head, headRef: "fix",
                    headRepository: repository, title: "A fix")
    }

    /// Called with each request once it is answered — what a test changes
    /// between one request and the next: what the limit says is left.
    var afterAsking: (@Sendable (String) -> Void)? {
        get { lock.withLock { hook } }
        set { lock.withLock { hook = newValue } }
    }

    var asked: [String] { lock.withLock { log } }
    var files: [String] { lock.withLock { fetched } }
    var limited: Bool {
        get { lock.withLock { isLimited } }
        set { lock.withLock { isLimited = newValue } }
    }

    private func ask(_ what: String) throws {
        let (blocked, fails, after) = lock.withLock { () -> (Bool, Bool, (@Sendable (String) -> Void)?) in
            log.append(what)
            return (isLimited, failing.contains { what.hasPrefix($0) }, hook)
        }
        after?(what)
        if blocked { throw ProviderError.rateLimited(until: Self.until) }
        if fails { throw ProviderError.unreachable("no answer") }
    }

    func defaultBranch() async throws -> String {
        try ask("default branch")
        return "main"
    }

    func describe() async throws -> RepositoryDescription {
        try ask("describe")
        guard let description else { throw ProviderError.notFound }
        return description
    }

    func provider(for repository: RepositoryAddress) -> (any RepositoryProvider)? {
        repository == address ? self : others[repository]
    }

    func head(of branch: String, ifNoneMatch etag: String?) async throws -> HeadAnswer {
        try ask("head \(branch)" + (etag.map { " if-none-match \($0)" } ?? ""))
        let name = branch.hasPrefix("refs/heads/") ? String(branch.dropFirst("refs/heads/".count)) : branch
        guard let commit = branches[name] else { throw ProviderError.notFound }
        if etag == "\"\(commit)\"" { return .unchanged }
        return .commit(commit, etag: "\"\(commit)\"")
    }

    func tree(_ sha: String, recursive: Bool) async throws -> GitTree {
        try ask("tree \(sha)\(recursive ? " recursive" : "")")
        guard let repository = commits[sha] else { throw ProviderError.notFound }
        return repository.recursiveTree()
    }

    func file(at path: String, commit: String) async throws -> Data {
        lock.withLock { fetched.append(path) }
        guard let data = commits[commit]?.data(at: path) else { throw ProviderError.notFound }
        return data
    }

    func commits(touching path: String, on branch: String) async throws -> [CommitSummary] {
        try ask("commits \(path) on \(branch)")
        return []
    }

    func pull(_ number: Int) async throws -> PullRequest {
        try ask("pull \(number)")
        guard let pull = pulls[number] else { throw ProviderError.notFound }
        return pull
    }

    func compare(_ base: String, _ head: String) async throws -> Comparison {
        try ask("compare \(base)...\(head)")
        guard let comparison = comparisons["\(base)...\(head)"] else { throw ProviderError.notFound }
        return comparison
    }

    func folderPage(_ path: String, commit: String) -> URL? { nil }
    func comparePage(from: String, to: String) -> URL? { nil }
}

/// GitHub's answer about one pull request, read: its head, its state, and a
/// merge commit only for one that was merged.
@Suite("A pull request, as GitHub answers it")
struct PullRequestTests {
    static let head = "70f74dafa34a7b8e1f9c62b84a2f8e8f6f3a1b11"
    static let merge = "7403916a2b2c84e4bcb1c1e5aa01c4f5d0c26c7b"

    static func answer(number: Int = 3, state: String = "open", merged: Bool? = false, mergeCommit: String? = merge,
                       head: String = head, repository: String? = "\"someone/udeck-plugins\"",
                       base: String = #"{"ref": "main", "sha": "8868da0f1b26000000000000000000000000000a"}"#) -> Data {
        let repo = repository.map { #"{"full_name": \#($0), "fork": true}"# } ?? "null"
        return Data(#"""
            {"number": \#(number), "state": "\#(state)", "title": "A fix", "draft": false,
             "merged": \#(merged.map(String.init) ?? "null"),
             "merge_commit_sha": \#(mergeCommit.map { "\"\($0)\"" } ?? "null"),
             "head": {"label": "someone:fix", "ref": "fix", "sha": "\#(head)", "repo": \#(repo)},
             "base": \#(base)}
            """#.utf8)
    }

    @Test("open, from a fork: the head and where it came from; the test merge GitHub names is no commit of a branch")
    func open() {
        let read = PullRequest.read(Self.answer(), asked: 3)
        #expect(read == PullRequest(number: 3, state: .open, merged: false, mergeCommit: nil, head: Self.head,
                                    headRef: "fix", headRepository: "someone/udeck-plugins", title: "A fix", base: "main"))
    }

    /// Only a merge into the default branch is what was verified (`Adoption`),
    /// so the branch it was opened against is read with the rest.
    @Test("the branch it was opened against, and merged into: base.ref; nothing when GitHub does not say")
    func base() {
        let next = PullRequest.read(Self.answer(state: "closed", merged: true, base: #"{"ref": "next", "sha": null}"#), asked: 3)
        #expect(next?.base == "next" && next?.merged == true && next?.mergeCommit == Self.merge)
        #expect(PullRequest.read(Self.answer(base: "null"), asked: 3)?.base == nil)
        #expect(PullRequest.read(Self.answer(base: #"{"sha": null}"#), asked: 3)?.base == nil)
        #expect(PullRequest.read(Self.answer(base: #"{"ref": ""}"#), asked: 3)?.base == nil)
    }

    @Test("merged: the commit it was merged as; closed unmerged: none; a deleted fork: no repository")
    func mergedClosedDeleted() {
        #expect(PullRequest.read(Self.answer(state: "closed", merged: true), asked: 3)?.mergeCommit == Self.merge)
        let closed = PullRequest.read(Self.answer(state: "closed", merged: false), asked: 3)
        #expect(closed?.state == .closed && closed?.merged == false && closed?.mergeCommit == nil)
        let gone = PullRequest.read(Self.answer(repository: nil), asked: 3)
        #expect(gone?.headRepository == nil && gone?.head == Self.head)
        #expect(PullRequest.read(Self.answer(merged: nil), asked: 3)?.merged == false, "merged absent: not merged")
        #expect(PullRequest.read(Self.answer(state: "closed", merged: true, mergeCommit: "nope"), asked: 3)?.mergeCommit == nil)
    }

    @Test("not one: another number, a head that is no commit, a state that is neither, not JSON")
    func notOne() {
        #expect(PullRequest.read(Self.answer(number: 4), asked: 3) == nil)
        #expect(PullRequest.read(Self.answer(head: "main"), asked: 3) == nil)
        #expect(PullRequest.read(Self.answer(state: "merged"), asked: 3) == nil)
        #expect(PullRequest.read(Data("<html>".utf8), asked: 3) == nil)
    }

    /// The client itself, against answers of the test's own through the
    /// session's protocol: the request it makes, and what each answer is.
    @Test("GitHubClient asks GET /repos/{o}/{r}/pulls/{n} and reads the answer; 404 and 422 are not there")
    func client() async throws {
        let host = "pulls-\(UUID().uuidString.lowercased()).invalid"
        let client = GitHubClient(
            endpoints: GitHubEndpoints(apiBase: URL(string: "https://\(host)/api")!, rawBase: URL(string: "https://\(host)/raw")!,
                                       repository: "iillyyaa1997/udeck-plugins"),
            udeckVersion: "0.7.0", limits: RateLimitRecorder(),
            session: GitHubClient.makeSession(protocolClasses: [StubAnswers.self])
        )
        StubAnswers.answer(host) { request in
            switch request.url?.path {
            case "/api/repos/iillyyaa1997/udeck-plugins/pulls/3": (200, Self.answer())
            case "/api/repos/iillyyaa1997/udeck-plugins/pulls/4": (422, Data("{}".utf8))
            case "/api/repos/iillyyaa1997/udeck-plugins/pulls/5": (200, Data("[]".utf8))
            default: (404, Data(#"{"message": "Not Found"}"#.utf8))
            }
        }
        defer { StubAnswers.forget(host) }
        #expect(try await client.pull(3).head == Self.head)
        await #expect(throws: ProviderError.notFound) { _ = try await client.pull(9) }
        await #expect(throws: ProviderError.notFound) { _ = try await client.pull(4) }
        await #expect(throws: ProviderError.badAnswer("pull request #5 could not be read")) { _ = try await client.pull(5) }
        let asked = StubAnswers.asked(host)
        #expect(asked.first?.url?.path == "/api/repos/iillyyaa1997/udeck-plugins/pulls/3")
        #expect(asked.first?.value(forHTTPHeaderField: "User-Agent") == "uDeck/0.7.0")
        #expect(asked.first?.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
        #expect(asked.first?.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(asked.count == 4)
    }
}

/// Answers a session's requests with whatever the test registered for the
/// request's host — each test its own host, so tests side by side never see
/// each other's answers.
final class StubAnswers: URLProtocol, @unchecked Sendable {
    typealias Answer = @Sendable (URLRequest) -> (Int, Data)

    private static let lock = NSLock()
    nonisolated(unsafe) private static var answers: [String: Answer] = [:]
    nonisolated(unsafe) private static var requests: [String: [URLRequest]] = [:]
    nonisolated(unsafe) private static var headers: [String: @Sendable (URLRequest) -> [String: String]] = [:]

    static func answer(_ host: String, with answer: @escaping Answer) {
        lock.withLock { answers[host] = answer }
    }

    /// Headers every answer to `host` carries besides its type: what the
    /// limit says, as GitHub's API answers say it.
    static func headers(_ host: String, _ make: @escaping @Sendable (URLRequest) -> [String: String]) {
        lock.withLock { headers[host] = make }
    }

    static func forget(_ host: String) {
        lock.withLock {
            answers[host] = nil
            requests[host] = nil
            headers[host] = nil
        }
    }

    static func asked(_ host: String) -> [URLRequest] {
        lock.withLock { requests[host] ?? [] }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let host = request.url?.host ?? ""
        let (answer, extra) = Self.lock.withLock { () -> (Answer?, (@Sendable (URLRequest) -> [String: String])?) in
            Self.requests[host, default: []].append(request)
            return (Self.answers[host], Self.headers[host])
        }
        let (status, body) = answer?(request) ?? (599, Data())
        let fields = (extra?(request) ?? [:]).merging(["Content-Type": "application/json"]) { given, _ in given }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: fields)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
