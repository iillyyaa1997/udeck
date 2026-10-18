import Foundation
import Testing
@testable import UDeckCore
import UDeckPluginFormatFixtures

/// Following the branch or the pull request a copy of code nobody verified
/// came from (stage 3, R5): what uDeck asks GitHub, and when it asks nothing
/// (`RefFollower`, against a provider of the test's own that counts its
/// requests); whether a head that moved continues what is installed
/// (`HistoryRewrite`, `Comparison`); what is kept of it (`FollowedRefs`,
/// `RefHead`); and what the plugin's row says and offers (`RefOffer`,
/// `UnverifiedRow`) — every decision its views show, since UDeckKit has no
/// tests.
@Suite("Following branches and pull requests, history rewritten said")
struct RefFollowerTests {
    let temp = TemporaryDirectory()
    var store: CatalogueStore { CatalogueStore(paths: temp.paths) }

    static let at = AdoptionTests.at
    static let later = AdoptionTests.later
    static let other = AdoptionTests.other

    /// What was installed: pull request #3's head, `uptime` 1.0.1 — the lab's pr3.
    static var installedHead: FakeRepository {
        var repository = FakeRepository.withUptime(version: "1.0.1")
        repository.commit = AdoptionTests.pullHead
        return repository
    }

    /// The head moved on: the same version, the same manifest, its script
    /// changed — the lab's p2.
    static var movedOn: FakeRepository {
        var repository = installedHead
        repository.files["plugins/uptime/uptime.sh"] = FakeRepository.File("#!/bin/sh\necho p2\n", executable: true)
        repository.commit = String(repeating: "5", count: 40)
        return repository
    }

    /// The head moved on, `uptime` as it was and another plugin changed.
    static var otherPluginChanged: FakeRepository {
        var repository = installedHead
        repository.addPlugin("cpu", version: "2.0.0")
        repository.commit = String(repeating: "6", count: 40)
        return repository
    }

    /// The head moved on, `uptime` gone from it.
    static var withoutUptime: FakeRepository {
        var repository = installedHead
        repository.files = repository.files.filter { !$0.key.hasPrefix("plugins/uptime/") }
        repository.addPlugin("cpu")
        repository.commit = String(repeating: "7", count: 40)
        return repository
    }

    static var installedCommit: String { installedHead.commit }
    static var installedTree: String { installedHead.plugin("uptime").tree }

    static func record(ref: PluginRef = .pullRequest(3)) -> InstalledRecord {
        AdoptionTests.record(ref: ref, tree: installedTree)
    }

    static func installed(_ ref: PluginRef = .pullRequest(3)) -> InstalledPlugins {
        InstalledPlugins(plugins: ["uptime": record(ref: ref)])
    }

    /// The catalogue's head has another `uptime`: nothing is adopted.
    static let headTrees = ["uptime": AdoptionTests.other]

    static func pull(head: String, state: PullRequest.State = .open, merged: Bool = false,
                     mergeCommit: String? = nil, base: String? = "main") -> PullRequest {
        PullRequest(number: 3, state: state, merged: merged, mergeCommit: mergeCommit, head: head, headRef: "fix",
                    headRepository: "someone/udeck-plugins", title: "", base: base)
    }

    static func compared(_ head: FakeRepository, _ status: Comparison.Status) -> [String: Comparison] {
        ["\(installedCommit)...\(head.commit)": Comparison(status: status, aheadBy: status == .behind ? 0 : 1,
                                                          behindBy: status == .ahead ? 0 : 1)]
    }

    /// The follower, after a read of the catalogue that found `main`.
    func follower(_ provider: Provider, limits: RateLimitRecorder = RateLimitRecorder(),
                  now: Date = RefFollowerTests.at) -> RefFollower {
        try? store.save(CatalogueState(defaultBranch: "main"))
        return RefFollower(provider: provider, store: store, limits: limits, language: "en", now: { now })
    }

    /// What the install left in the cache: the installed head's listing and its manifests.
    func installedHeadCached() throws {
        try store.save(Self.installedHead.listing)
        for path in ["plugins/uptime/manifest.json"] {
            try store.save(blob: Self.installedHead.data(at: path)!)
        }
    }

    // MARK: - The answer GitHub gives

    @Test("a comparison, as GitHub answers it: the status and both counts; anything else is no answer")
    func comparisonRead() {
        func answer(_ status: String, _ ahead: String = "1", _ behind: String = "0") -> Data {
            Data(#"{"status": "\#(status)", "ahead_by": \#(ahead), "behind_by": \#(behind), "total_commits": 1, "files": []}"#.utf8)
        }
        #expect(Comparison.read(answer("ahead")) == Comparison(status: .ahead, aheadBy: 1, behindBy: 0))
        #expect(Comparison.read(answer("diverged", "2", "3")) == Comparison(status: .diverged, aheadBy: 2, behindBy: 3))
        #expect(Comparison.read(answer("behind", "0", "1"))?.status == .behind)
        #expect(Comparison.read(answer("identical", "0", "0"))?.status == .identical)
        #expect(Comparison.read(answer("rewritten")) == nil, "a status GitHub does not have")
        #expect(Comparison.read(answer("ahead", "-1")) == nil && Comparison.read(answer("ahead", "\"one\"")) == nil)
        #expect(Comparison.read(Data("<html>".utf8)) == nil)
    }

    @Test("GitHubClient asks GET /repos/{o}/{r}/compare/{base}...{head}?per_page=1; 404 and 422 are not there")
    func client() async throws {
        let host = "compare-\(UUID().uuidString.lowercased()).invalid"
        let client = GitHubClient(
            endpoints: GitHubEndpoints(apiBase: URL(string: "https://\(host)/api")!, rawBase: URL(string: "https://\(host)/raw")!,
                                       repository: "iillyyaa1997/udeck-plugins"),
            udeckVersion: "0.7.0", limits: RateLimitRecorder(),
            session: GitHubClient.makeSession(protocolClasses: [StubAnswers.self])
        )
        let one = String(repeating: "1", count: 40), two = String(repeating: "2", count: 40)
        let gone = String(repeating: "9", count: 40), refused = String(repeating: "8", count: 40)
        StubAnswers.answer(host) { request in
            switch request.url?.path {
            case "/api/repos/iillyyaa1997/udeck-plugins/compare/\(one)...\(two)":
                (200, Data(#"{"status": "diverged", "ahead_by": 1, "behind_by": 1, "files": [{"filename": "x"}]}"#.utf8))
            case "/api/repos/iillyyaa1997/udeck-plugins/compare/\(refused)...\(two)": (422, Data("{}".utf8))
            case "/api/repos/iillyyaa1997/udeck-plugins/compare/\(two)...\(one)": (200, Data("[]".utf8))
            default: (404, Data(#"{"message": "Not Found"}"#.utf8))
            }
        }
        defer { StubAnswers.forget(host) }
        #expect(try await client.compare(one, two) == Comparison(status: .diverged, aheadBy: 1, behindBy: 1))
        await #expect(throws: ProviderError.notFound) { _ = try await client.compare(gone, two) }
        await #expect(throws: ProviderError.notFound) { _ = try await client.compare(refused, two) }
        await #expect(throws: ProviderError.badAnswer("the comparison of 2222222 with 1111111 could not be read")) {
            _ = try await client.compare(two, one)
        }
        await #expect(throws: ProviderError.self) { _ = try await client.compare("main", two) }
        let asked = StubAnswers.asked(host)
        #expect(asked.count == 4, "only two commits are compared: a name is not asked")
        #expect(asked.first?.url?.query == "per_page=1")
        #expect(asked.first?.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
        #expect(asked.first?.value(forHTTPHeaderField: "Authorization") == nil)
    }

    // MARK: - History rewritten

    static let rewrites: [(String, Result<Comparison, ProviderError>, Bool?)] = [
        ("ahead: the new head continues what is installed", .success(Comparison(status: .ahead, aheadBy: 2, behindBy: 0)), false),
        ("identical: nothing rewritten", .success(Comparison(status: .identical, aheadBy: 0, behindBy: 0)), false),
        ("behind: gone back before what is installed", .success(Comparison(status: .behind, aheadBy: 0, behindBy: 1)), true),
        ("diverged: pushed again over what is installed", .success(Comparison(status: .diverged, aheadBy: 1, behindBy: 1)), true),
        ("the commit installed not there any more", .failure(.notFound), true),
        ("the limit: not known", .failure(.rateLimited(until: Provider.until)), nil),
        ("no answer: not known", .failure(.unreachable("offline")), nil),
        ("a refusal: not known", .failure(.refused(status: 500)), nil),
        ("an answer not read: not known", .failure(.badAnswer("?")), nil),
    ]

    @Test("whether the new head continues what is installed, by what the comparison says", arguments: 0..<rewrites.count)
    func rewritten(row: Int) {
        let (label, answer, expected) = Self.rewrites[row]
        #expect(HistoryRewrite.rewritten(answer) == expected, "\(label)")
    }

    @Test("what was found holds for exactly the two commits it was found of")
    func holds() {
        let found = HeadHistory(from: "a", to: "b", rewritten: true, checkedAt: Self.at.addingTimeInterval(0.7))
        #expect(found.holds(installed: "a", head: "b"))
        #expect(!found.holds(installed: "b", head: "b") && !found.holds(installed: "a", head: "c"))
        #expect(found.checkedAt == Self.at, "whole seconds, as every date in the file")
    }

    // MARK: - What is asked: a pull request

    @Test("a pull request moved on: its head listed and compared with what is installed once; then from what was kept")
    func pullMovedOn() async throws {
        let moved = Self.movedOn
        let provider = Provider(commits: [moved], pulls: [3: Self.pull(head: moved.commit)],
                                comparisons: Self.compared(moved, .ahead))
        let outcome = await follower(provider).follow(Self.installed(), headTrees: Self.headTrees, unrequested: false)
        #expect(provider.asked == ["pull 3", "tree \(moved.commit) recursive", "compare \(Self.installedCommit)...\(moved.commit)"],
                "the pull request, the listing of its new head, one comparison of the commit installed with it")
        #expect(provider.files == ["plugins/uptime/manifest.json"], "the copy's manifest there, from the raw host")
        let heard = try #require(outcome.followed.pulls["uptime"])
        #expect(heard.head == moved.commit && heard.state == .open)
        #expect(heard.history == HeadHistory(from: Self.installedCommit, to: moved.commit, rewritten: false, checkedAt: Self.at))
        #expect(store.listing(moved.commit) != nil && store.followed() == outcome.followed, "kept")
        // Asked again: the head's listing is cached, its manifest stored, what
        // was found of the two commits kept.
        let again = await follower(provider, now: Self.later).follow(Self.installed(), headTrees: Self.headTrees,
                                                                     unrequested: false)
        #expect(Array(provider.asked.dropFirst(3)) == ["pull 3"] && provider.files.count == 1)
        #expect(again.followed.pulls["uptime"]?.history == heard.history)
        // The copy updated to that head: nothing moved, nothing listed or compared.
        var updated = Self.installed()
        updated.plugins["uptime"]?.commit = moved.commit
        updated.plugins["uptime"]?.tree = moved.plugin("uptime").tree
        let after = await follower(provider).follow(updated, headTrees: Self.headTrees, unrequested: false)
        #expect(Array(provider.asked.dropFirst(4)) == ["pull 3"] && after.followed.pulls["uptime"]?.history == nil)
    }

    @Test("pushed again over what is installed: rewritten — diverged, gone back, or the installed commit gone")
    func pullRewritten() async throws {
        let moved = Self.movedOn
        for status in [Comparison.Status.diverged, .behind] {
            let provider = Provider(commits: [moved], pulls: [3: Self.pull(head: moved.commit)],
                                    comparisons: Self.compared(moved, status))
            let outcome = await follower(provider).follow(Self.installed(), headTrees: Self.headTrees, unrequested: false)
            #expect(outcome.followed.pulls["uptime"]?.history?.rewritten == true, "\(status)")
        }
        // GitHub no longer has the commit installed: rewritten, and cleaned up.
        let gone = Provider(commits: [moved], pulls: [3: Self.pull(head: moved.commit)])
        let outcome = await follower(gone).follow(Self.installed(), headTrees: Self.headTrees, unrequested: false)
        #expect(outcome.followed.pulls["uptime"]?.history?.rewritten == true && outcome.asked == ["uptime"])
    }

    @Test("a comparison with no answer leaves what was heard before, said as not checked; asked again next read")
    func compareUnanswered() async throws {
        let moved = Self.movedOn
        let before = FollowedPull(number: 3, head: Self.installedCommit, state: .open, merged: false, base: "main",
                                  mergeCommit: nil, mergeTree: nil, checkedAt: Self.at)
        try store.save(followed: FollowedRefs(pulls: ["uptime": before]))
        let provider = Provider(commits: [moved], pulls: [3: Self.pull(head: moved.commit)],
                                comparisons: Self.compared(moved, .ahead))
        provider.unreachable = ["compare"]
        let outcome = await follower(provider, now: Self.later).follow(Self.installed(), headTrees: Self.headTrees,
                                                                       unrequested: false)
        #expect(outcome.followed.pulls["uptime"] == before && outcome.leftAsTheyWere == ["uptime"] && outcome.asked.isEmpty)
        #expect(outcome.followed.notCheckedSince["uptime"] == Self.at, "since it was last asked about")
        provider.unreachable = []
        let again = await follower(provider, now: Self.later).follow(Self.installed(), headTrees: Self.headTrees,
                                                                     unrequested: false)
        #expect(again.followed.pulls["uptime"]?.history?.rewritten == false && again.followed.notCheckedSince.isEmpty)
        #expect(provider.asked.filter { $0.hasPrefix("compare") }.count == 2)
    }

    @Test("a head that moved with the copy's folder as it was, or with no such folder: compared only when something is offered")
    func nothingToOffer() async throws {
        let others = Self.otherPluginChanged
        let provider = Provider(commits: [others], pulls: [3: Self.pull(head: others.commit)])
        let outcome = await follower(provider).follow(Self.installed(), headTrees: Self.headTrees, unrequested: false)
        #expect(provider.asked == ["pull 3", "tree \(others.commit) recursive"], "the copy is as it was there: no comparison")
        #expect(outcome.followed.pulls["uptime"]?.head == others.commit && outcome.followed.pulls["uptime"]?.history == nil)
        let without = Self.withoutUptime
        let gone = Provider(commits: [without], pulls: [3: Self.pull(head: without.commit)],
                            comparisons: Self.compared(without, .ahead))
        let said = await follower(gone).follow(Self.installed(), headTrees: Self.headTrees, unrequested: false)
        #expect(gone.asked.last == "compare \(Self.installedCommit)...\(without.commit)" && gone.files.isEmpty,
                "its folder gone from the head is offered too, and nothing of it fetched")
        #expect(said.followed.pulls["uptime"]?.history?.rewritten == false)
    }

    /// The squash trap: against the default branch, a squash merge has gone
    /// another way too (measured when stage 3 was designed), and that is no
    /// rewrite of anything — so the default branch is never compared with.
    @Test("merged into the default branch: its head is not listed, and nothing is compared — with the default branch least of all")
    func squashTrap() async throws {
        var merge = FakeRepository.withUptime(version: "1.0.2")
        merge.commit = AdoptionTests.mergeCommit
        let moved = Self.movedOn
        let provider = Provider(commits: [merge, moved],
                                pulls: [3: Self.pull(head: moved.commit, state: .closed, merged: true,
                                                     mergeCommit: merge.commit)])
        let outcome = await follower(provider).follow(Self.installed(), headTrees: Self.headTrees, unrequested: false)
        #expect(provider.asked == ["pull 3", "tree \(merge.commit) recursive"], "the commit it was merged as, and nothing more")
        #expect(outcome.followed.pulls["uptime"]?.history == nil && outcome.followed.pulls["uptime"]?.mergeTree == merge.plugin("uptime").tree)
        // Merged into another branch: its head is still its line's, and compared with what is installed — never with main.
        let elsewhere = Provider(commits: [merge, moved],
                                 pulls: [3: Self.pull(head: moved.commit, state: .closed, merged: true,
                                                      mergeCommit: merge.commit, base: "next")],
                                 comparisons: Self.compared(moved, .ahead))
        _ = await follower(elsewhere).follow(Self.installed(), headTrees: Self.headTrees, unrequested: false)
        let comparisons = (provider.asked + elsewhere.asked).filter { $0.hasPrefix("compare") }
        #expect(comparisons == ["compare \(Self.installedCommit)...\(moved.commit)"],
                "only ever the commit installed with its own line's head")
    }

    // MARK: - What is asked: a branch

    @Test("a branch: its head asked with the commit installed — unchanged, nothing more; moved, listed and compared; deleted, said")
    func branch() async throws {
        let moved = Self.movedOn
        let ref = PluginRef.branch("fix/uptime")
        let asked = "head refs/heads/fix/uptime if-none-match \"\(Self.installedCommit)\""
        let still = Provider(commits: [moved], branches: ["fix/uptime": Self.installedCommit])
        let unchanged = await follower(still).follow(Self.installed(ref), headTrees: Self.headTrees, unrequested: false)
        #expect(still.asked == [asked], "GitHub's 304: the branch is where it was, and nothing more is asked")
        #expect(unchanged.followed.branches["uptime"] == FollowedBranch(name: "fix/uptime", repository: .official,
                                                                         head: Self.installedCommit,
                                                                         checkedAt: Self.at))
        #expect(unchanged.followed.pulls.isEmpty && unchanged.asked == ["uptime"])

        let on = Provider(commits: [moved], branches: ["fix/uptime": moved.commit], comparisons: Self.compared(moved, .diverged))
        let moving = await follower(on).follow(Self.installed(ref), headTrees: Self.headTrees, unrequested: false)
        #expect(on.asked == [asked, "tree \(moved.commit) recursive", "compare \(Self.installedCommit)...\(moved.commit)"])
        #expect(moving.followed.branches["uptime"]?.head == moved.commit
                && moving.followed.branches["uptime"]?.history?.rewritten == true)

        let deleted = Provider(commits: [moved])
        let gone = await follower(deleted, now: Self.later).follow(Self.installed(ref), headTrees: Self.headTrees,
                                                                   unrequested: false)
        #expect(deleted.asked == [asked])
        #expect(gone.followed.branches["uptime"] == FollowedBranch(name: "fix/uptime", repository: .official, head: nil,
                                                                    checkedAt: Self.later))
        #expect(gone.asked == ["uptime"] && gone.leftAsTheyWere.isEmpty, "asked, and answered: it is not there")
    }

    @Test("not asked: a copy the head has, the default branch's, another source's or another repository's, a kind uDeck does not know")
    func notAsked() async {
        var installed = InstalledPlugins()
        installed.plugins["atHead"] = AdoptionTests.record(ref: .branch("b"), tree: Self.other)
        installed.plugins["verified"] = AdoptionTests.record(ref: .defaultBranch("main"))
        installed.plugins["mine"] = AdoptionTests.record(source: "mine", ref: .branch("b"))
        var fork = AdoptionTests.record(ref: .branch("b"))
        fork.repository = RepositoryAddress(path: "someone/udeck-plugins")
        installed.plugins["fork"] = fork
        installed.plugins["commit"] = AdoptionTests.record(ref: PluginRef(kind: "commit", name: "abc"))
        installed.plugins["empty"] = AdoptionTests.record(ref: PluginRef(kind: PluginRef.branchKind, name: ""))
        let provider = Provider(commits: [])
        let outcome = await follower(provider).follow(installed, headTrees: ["atHead": Self.other], unrequested: false)
        #expect(provider.asked.isEmpty && outcome.asked.isEmpty && outcome.followed == FollowedRefs())
    }

    @Test("the reserve: a read nobody asked for asks no branch either, and says since when it was not checked")
    func reserve() async throws {
        let ref = PluginRef.branch("fix/uptime")
        // Last asked about a day after it was installed.
        let before = FollowedBranch(name: "fix/uptime", head: Self.installedCommit, checkedAt: Self.later)
        try store.save(followed: FollowedRefs(branches: ["uptime": before]))
        let provider = Provider(commits: [], branches: ["fix/uptime": Self.installedCommit])
        let low = RateLimitRecorder(RateLimitState(remaining: RateLimitState.reserveForTheOperator - 1,
                                                   reset: Self.later.addingTimeInterval(7200)))
        let left = await follower(provider, limits: low, now: Self.later.addingTimeInterval(60))
            .follow(Self.installed(ref), headTrees: Self.headTrees, unrequested: true)
        #expect(provider.asked.isEmpty && left.leftAsTheyWere == ["uptime"])
        #expect(left.followed.branches["uptime"] == before && left.followed.notCheckedSince == ["uptime": Self.later],
                "since it was last asked about, not since it was installed")
        #expect(store.followed() == left.followed, "kept, so that the row says it after a relaunch too")
        // The same, left again: still since the last time it was asked about.
        let again = await follower(provider, limits: low, now: Self.later.addingTimeInterval(3600))
            .follow(Self.installed(ref), headTrees: Self.headTrees, unrequested: true)
        #expect(again.followed.notCheckedSince == ["uptime": Self.later])
        // Asked for: asked within the reserve, and not said any more.
        let asked = await follower(provider, limits: low, now: Self.later).follow(Self.installed(ref), headTrees: Self.headTrees,
                                                                                  unrequested: false)
        #expect(provider.asked.count == 1 && asked.followed.notCheckedSince.isEmpty)
    }

    @Test("the reserve reached halfway through a copy, in a read nobody asked for: neither listed nor compared, said not checked")
    func reserveHalfway() async throws {
        let moved = Self.movedOn
        let provider = Provider(commits: [moved], pulls: [3: Self.pull(head: moved.commit)],
                                comparisons: Self.compared(moved, .ahead))
        // One above the reserve when the copy is asked about; every answer one fewer.
        let limits = RateLimitRecorder(RateLimitState(remaining: RateLimitState.reserveForTheOperator, reset: Self.later))
        provider.afterAsking = { _ in limits.update { $0.remaining = ($0.remaining ?? 0) - 1 } }
        let left = await follower(provider, limits: limits).follow(Self.installed(), headTrees: Self.headTrees,
                                                                   unrequested: true)
        #expect(provider.asked == ["pull 3"], "the pull request, and not one request into the reserve after it")
        #expect(left.asked.isEmpty && left.leftAsTheyWere == ["uptime"])
        #expect(left.followed.pulls.isEmpty && left.followed.notCheckedSince == ["uptime": AdoptionTests.at],
                "what it heard on the way is not kept, and it says since when: here, since it was installed")
        // The head's listing in the cache: the comparison is the request held back.
        try store.save(moved.listing)
        limits.update { $0.remaining = RateLimitState.reserveForTheOperator }
        let again = await follower(provider, limits: limits).follow(Self.installed(), headTrees: Self.headTrees,
                                                                    unrequested: true)
        #expect(Array(provider.asked.dropFirst()) == ["pull 3"] && again.leftAsTheyWere == ["uptime"])
        // Asked for, the same read goes on within the reserve.
        limits.update { $0.remaining = RateLimitState.reserveForTheOperator }
        let asked = await follower(provider, limits: limits).follow(Self.installed(), headTrees: Self.headTrees,
                                                                    unrequested: false)
        #expect(Array(provider.asked.dropFirst(2)) == ["pull 3", "compare \(Self.installedCommit)...\(moved.commit)"])
        #expect(asked.asked == ["uptime"] && asked.followed.notCheckedSince.isEmpty)
        // The listing cached and what was found of the two commits kept: nothing more to ask, nothing held back.
        limits.update { $0.remaining = RateLimitState.reserveForTheOperator }
        let known = await follower(provider, limits: limits).follow(Self.installed(), headTrees: Self.headTrees,
                                                                    unrequested: true)
        #expect(Array(provider.asked.dropFirst(4)) == ["pull 3"] && known.asked == ["uptime"]
                && known.followed.notCheckedSince.isEmpty)
        // Merged into main: the listing of the commit it was merged as is held back the same way.
        var merge = FakeRepository.withUptime(version: "1.0.2")
        merge.commit = AdoptionTests.mergeCommit
        let merged = Provider(commits: [merge], pulls: [3: Self.pull(head: moved.commit, state: .closed, merged: true,
                                                                     mergeCommit: merge.commit)])
        merged.afterAsking = { _ in limits.update { $0.remaining = ($0.remaining ?? 0) - 1 } }
        limits.update { $0.remaining = RateLimitState.reserveForTheOperator }
        let held = await follower(merged, limits: limits).follow(Self.installed(), headTrees: Self.headTrees,
                                                                 unrequested: true)
        #expect(merged.asked == ["pull 3"] && held.leftAsTheyWere == ["uptime"])
        #expect(held.followed.pulls["uptime"] == known.followed.pulls["uptime"], "what was heard before stands")
    }

    @Test("a read of the catalogue left for later or failed: nothing asked, every line said not checked since it was last asked about")
    func leftUnasked() async throws {
        var installed = Self.installed()
        installed.plugins["cpu"] = AdoptionTests.record(ref: .branch("fix/cpu"))
        installed.plugins["atHead"] = AdoptionTests.record(ref: .branch("b"), tree: Self.other)
        installed.plugins["verified"] = AdoptionTests.record(ref: .defaultBranch("main"))
        let heard = FollowedPull(number: 3, head: Self.movedOn.commit, state: .open, merged: false, base: "main",
                                 mergeCommit: nil, mergeTree: nil, checkedAt: Self.later)
        try store.save(followed: FollowedRefs(pulls: ["uptime": heard]))
        let provider = Provider(commits: [Self.movedOn], branches: ["fix/cpu": Self.installedCommit],
                                pulls: [3: Self.pull(head: Self.movedOn.commit)])
        let trees = ["atHead": Self.other, "uptime": AdoptionTests.other]
        let left = await follower(provider, now: Self.later.addingTimeInterval(3600))
            .follow(installed, headTrees: trees, unrequested: true, asking: false)
        #expect(provider.asked.isEmpty && provider.files.isEmpty, "nothing asked at all")
        #expect(left.asked.isEmpty && left.leftAsTheyWere == ["cpu", "uptime"], "the copy the head has is what was merged")
        #expect(left.followed.pulls == ["uptime": heard], "what was heard stands, still offered")
        #expect(left.followed.notCheckedSince == ["uptime": Self.later, "cpu": AdoptionTests.at],
                "since it was last asked about, or since it was installed when it never was")
        #expect(store.followed() == left.followed, "kept, so that the row says it after a relaunch too")
        // A read asked for that failed: the same, the dates as they were.
        let failed = await follower(provider, now: Self.later.addingTimeInterval(7200))
            .follow(installed, headTrees: trees, unrequested: false, asking: false)
        #expect(provider.asked.isEmpty && failed.followed == left.followed)
    }

    @Test("what a read asks of a line, said beside Official catalogue, in both languages")
    func catalogueHelp() {
        #expect(Strings(.english)(.pluginsOfficialCatalogueHelp(source: "github.com/o/r")) == "uDeck reads the list of plugins in github.com/o/r a few seconds after it starts, once a day, when you open this pane and the list is more than an hour old, and when you press Check now — the list and each plugin's manifest; for a plugin installed from a branch or a pull request, also where that branch or pull request is now — a fork's branch asked of the fork — and, once it has moved, its list of files, that plugin's manifest there and one comparison with what is installed. A plugin's files are fetched when you press Install, and when a verified plugin updates itself. Off, uDeck makes no request to the official repository; sources you added are read until you remove them; what is installed keeps running.")
        #expect(Strings(.russian)(.pluginsOfficialCatalogueHelp(source: "github.com/o/r")) == "uDeck читает список плагинов в github.com/o/r через несколько секунд после запуска, раз в день, при открытии этой панели, если списку больше часа, и по кнопке «Проверить» — список и манифест каждого плагина, а для плагина, установленного из ветки или запроса на слияние, ещё и где сейчас эта ветка или запрос — ветку форка спрашивают у самого форка — и, если они сдвинулись, их список файлов, манифест этого плагина там и одно сравнение с установленным. Файлы плагина скачиваются, когда вы нажимаете «Установить» и когда проверенный плагин обновляется сам. Если выключить, uDeck не делает запросов к официальному репозиторию; добавленные вами источники читаются, пока вы их не удалите; установленное продолжает работать.")
    }

    @Test("what an asking heard of a branch joins what is known now; a copy installed meanwhile keeps its own")
    func joined() {
        let ref = PluginRef.branch("fix/uptime")
        let asked = Self.installed(ref)
        let heard = RefFollower.Outcome(
            followed: FollowedRefs(branches: ["uptime": FollowedBranch(name: "fix/uptime", head: nil, checkedAt: Self.at)],
                                   notCheckedSince: ["uptime": Self.at]),
            asked: [], leftAsTheyWere: ["uptime"])
        let now = FollowedRefs(notCheckedSince: ["cpu": Self.at])
        #expect(heard.merged(into: now, askedAbout: asked, installed: asked)
                == FollowedRefs(branches: heard.followed.branches, notCheckedSince: ["uptime": Self.at]),
                "its copy as it was asked about: what was heard; of no copy at all: dropped, as the asking drops it")
        var replaced = asked
        replaced.plugins["uptime"]?.commit = Self.movedOn.commit
        let joined = heard.merged(into: FollowedRefs(), askedAbout: asked, installed: replaced)
        #expect(joined.branches.isEmpty && joined.notCheckedSince.isEmpty, "another copy put in its place meanwhile: its own word")
    }

    // MARK: - What is kept

    @Test("followed.json from before branches were followed reads as it is; a branch, its absence and a line not checked read back")
    func file() throws {
        let old = #"""
            {"version": 1, "pulls": {"uptime": {"number": 3, "head": "\#(Self.installedCommit)", "state": "open",
             "merged": false, "base": "main", "checkedAt": "2026-09-21T14:13:20Z"}}}
            """#
        let file = temp.paths.catalogue.appendingPathComponent("official/followed.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(old.utf8).write(to: file)
        let read = store.followed()
        #expect(read.pulls["uptime"]?.head == Self.installedCommit && read.pulls["uptime"]?.history == nil)
        #expect(read.branches.isEmpty && read.notCheckedSince.isEmpty)
        let refs = FollowedRefs(
            pulls: ["uptime": FollowedPull(number: 3, head: Self.movedOn.commit, state: .open, merged: false, base: "main",
                                           mergeCommit: nil, mergeTree: nil, checkedAt: Self.at,
                                           history: HeadHistory(from: Self.installedCommit, to: Self.movedOn.commit,
                                                                rewritten: true, checkedAt: Self.at))],
            branches: ["cpu": FollowedBranch(name: "fix/cpu", head: nil, checkedAt: Self.at),
                       "disk": FollowedBranch(name: "disk", head: Self.installedCommit, checkedAt: Self.at)],
            notCheckedSince: ["cpu": Self.at])
        try store.save(followed: refs)
        #expect(store.followed() == refs)
        #expect(refs.heads == [Self.movedOn.commit, Self.installedCommit], "a deleted branch has no head to keep")
    }

    @Test("the head a copy's line was last heard at: the pull request's, the branch's — none merged into main, deleted, or another's")
    func head() {
        let history = HeadHistory(from: Self.installedCommit, to: "h", rewritten: false, checkedAt: Self.at)
        func pull(merged: Bool, base: String?) -> FollowedPull {
            FollowedPull(number: 3, head: "h", state: merged ? .closed : .open, merged: merged, base: base, mergeCommit: nil,
                         mergeTree: nil, checkedAt: Self.at, history: history)
        }
        let open = FollowedRefs(pulls: ["uptime": pull(merged: false, base: "main")])
        #expect(open.head(of: "uptime", record: Self.record(), defaultBranch: "main")?.commit == "h")
        #expect(open.head(of: "uptime", record: Self.record(), defaultBranch: "main")?.history == history)
        #expect(FollowedRefs(pulls: ["uptime": pull(merged: true, base: "main")])
                    .head(of: "uptime", record: Self.record(), defaultBranch: "main") == nil, "merged into main: what was merged")
        #expect(FollowedRefs(pulls: ["uptime": pull(merged: true, base: "next")])
                    .head(of: "uptime", record: Self.record(), defaultBranch: "main")?.commit == "h", "merged elsewhere: its head")
        #expect(open.head(of: "uptime", record: Self.record(ref: .pullRequest(4)), defaultBranch: "main") == nil)
        let branch = FollowedRefs(branches: ["uptime": FollowedBranch(name: "fix/uptime", head: "h", checkedAt: Self.at)])
        #expect(branch.head(of: "uptime", record: Self.record(ref: .branch("fix/uptime")), defaultBranch: "main")?.commit == "h")
        #expect(branch.head(of: "uptime", record: Self.record(ref: .branch("Fix/uptime")), defaultBranch: "main") == nil,
                "two spellings of a branch are two branches")
        #expect(branch.head(of: "uptime", record: Self.record(ref: .defaultBranch("main")), defaultBranch: "main") == nil)
        let deleted = FollowedRefs(branches: ["uptime": FollowedBranch(name: "fix/uptime", head: nil, checkedAt: Self.at)])
        #expect(deleted.head(of: "uptime", record: Self.record(ref: .branch("fix/uptime")), defaultBranch: "main") == nil)
    }

    @Test("kept at install: a branch's copy keeps its branch, or what Look up heard of it, and drops the rest; any copy put in place drops not checked; forgotten whole")
    func keptAtInstall() {
        let branch = FollowedBranch(name: "fix/uptime", head: nil, checkedAt: Self.at)
        let pull = AdoptionTests.pull(state: .open, merged: false, mergeCommit: nil, mergeTree: nil)
        let before = FollowedRefs(pulls: ["uptime": pull], branches: ["uptime": branch, "cpu": branch],
                                  notCheckedSince: ["uptime": Self.at, "cpu": Self.at])
        let fromTheBranch = Self.record(ref: .branch("fix/uptime"))
        var refs = before
        refs.keep(nil, branchHead: nil, heardAtInstall: fromTheBranch, of: "uptime", defaultBranch: "main",
                  mergeListing: nil, now: Self.later)
        #expect(refs.branches["uptime"] == branch && refs.pulls["uptime"] == nil && refs.notCheckedSince["uptime"] == nil,
                "put back or updated along it, not looked up: what was heard of the branch stands")
        #expect(refs.branches["cpu"] == branch && refs.notCheckedSince["cpu"] == Self.at, "another id untouched")
        // Installed from a link: Look up heard the branch at the commit
        // installed, whatever a read heard before — here, no branch at all.
        refs = before
        refs.keep(nil, branchHead: Self.installedCommit, heardAtInstall: fromTheBranch, of: "uptime", defaultBranch: "main",
                  mergeListing: nil, now: Self.later)
        #expect(refs.branches["uptime"] == FollowedBranch(name: "fix/uptime", repository: .official, head: Self.installedCommit,
                                                           checkedAt: Self.later))
        #expect(refs.pulls["uptime"] == nil && refs.notCheckedSince["uptime"] == nil && refs.branches["cpu"] == branch)
        let gone = UnverifiedRow.of("uptime", record: fromTheBranch, followed: refs, head: nil, defaultBranch: "main",
                                    readsCatalogue: true, verified: nil)
        #expect(gone?.branchGone == false, "made again and installed from: not said to be gone")
        // A read heard the branch at another head before: not offered over the commit just installed from it.
        refs = FollowedRefs(branches: ["uptime": FollowedBranch(name: "fix/uptime", head: Self.movedOn.commit, checkedAt: Self.at)])
        refs.keep(nil, branchHead: Self.installedCommit, heardAtInstall: fromTheBranch, of: "uptime", defaultBranch: "main",
                  mergeListing: nil, now: Self.later)
        let stale = UnverifiedRow.of("uptime", record: fromTheBranch, followed: refs, head: Self.head(Self.movedOn),
                                     defaultBranch: "main", readsCatalogue: true, verified: nil)
        #expect(stale?.lineOffer == nil && stale?.waiting == false)
        // The sheet left open across a read: what that read heard after Look
        // up — the branch deleted, or at another head — is newer than the head
        // installed from, and stands; Look up's head is kept only over what
        // was heard before it, and as heard when Look up heard it.
        for (after, said) in [(FollowedBranch(name: "fix/uptime", repository: .official, head: nil, checkedAt: Self.later),
                               "deleted after Look up"),
                              (FollowedBranch(name: "fix/uptime", head: Self.movedOn.commit, checkedAt: Self.later),
                               "moved on after Look up")] {
            refs = FollowedRefs(branches: ["uptime": after])
            refs.keep(nil, branchHead: Self.installedCommit, heardAt: Self.at, heardAtInstall: fromTheBranch, of: "uptime",
                      defaultBranch: "main", mergeListing: nil, now: Self.later.addingTimeInterval(60))
            #expect(refs.branches["uptime"] == after, "\(said): what the read heard stands")
        }
        refs = FollowedRefs(branches: ["uptime": FollowedBranch(name: "fix/uptime", head: Self.movedOn.commit, checkedAt: Self.later)])
        refs.keep(nil, branchHead: Self.installedCommit, heardAt: Self.at, heardAtInstall: fromTheBranch, of: "uptime",
                  defaultBranch: "main", mergeListing: nil, now: Self.later.addingTimeInterval(60))
        let newer = UnverifiedRow.of("uptime", record: fromTheBranch, followed: refs, head: Self.head(Self.movedOn),
                                     defaultBranch: "main", readsCatalogue: true, verified: nil)
        #expect(newer?.lineOffer?.head == Self.movedOn.commit && newer?.waiting == true,
                "the head a read heard after Look up is offered over the one installed from")
        refs = FollowedRefs(branches: ["uptime": FollowedBranch(name: "fix/uptime", repository: .official, head: nil, checkedAt: Self.later)])
        refs.keep(nil, branchHead: Self.installedCommit, heardAt: Self.at, heardAtInstall: fromTheBranch, of: "uptime",
                  defaultBranch: "main", mergeListing: nil, now: Self.later.addingTimeInterval(60))
        #expect(UnverifiedRow.of("uptime", record: fromTheBranch, followed: refs, head: nil, defaultBranch: "main",
                                 readsCatalogue: true, verified: nil)?.branchGone == true, "deleted after Look up: still said")
        refs = FollowedRefs(branches: ["uptime": FollowedBranch(name: "fix/uptime", head: nil, checkedAt: Self.at)])
        refs.keep(nil, branchHead: Self.installedCommit, heardAt: Self.later, heardAtInstall: fromTheBranch, of: "uptime",
                  defaultBranch: "main", mergeListing: nil, now: Self.later.addingTimeInterval(60))
        #expect(refs.branches["uptime"] == FollowedBranch(name: "fix/uptime", repository: .official, head: Self.installedCommit,
                                                           checkedAt: Self.later),
                "heard before Look up: Look up's head, as heard when Look up heard it, not when the install ended")
        refs = FollowedRefs(branches: ["uptime": FollowedBranch(name: "fix/uptime", head: nil, checkedAt: Self.at)])
        refs.keep(nil, branchHead: Self.installedCommit, heardAt: Self.at, heardAtInstall: fromTheBranch, of: "uptime",
                  defaultBranch: "main", mergeListing: nil, now: Self.later)
        #expect(refs.branches["uptime"]?.head == Self.installedCommit, "heard in the same second: Look up's, which was installed from")
        // A pull request the same way: closed by a read after Look up, it stays closed.
        let closed = AdoptionTests.pull(state: .closed, merged: false, mergeCommit: nil, mergeTree: nil)
        var laterRead = closed
        laterRead.checkedAt = Self.later
        let lookedUp = PullRequest(number: 3, state: .open, merged: false, mergeCommit: nil, head: AdoptionTests.pullHead,
                                   headRef: "fix", headRepository: nil, title: "", base: "main")
        refs = FollowedRefs(pulls: ["uptime": laterRead])
        refs.keep(lookedUp, branchHead: nil, heardAt: Self.at, heardAtInstall: Self.record(), of: "uptime", defaultBranch: "main",
                  mergeListing: nil, now: Self.later.addingTimeInterval(60))
        #expect(refs.pulls["uptime"] == laterRead, "closed after Look up: still said")
        refs = FollowedRefs(pulls: ["uptime": closed])
        refs.keep(lookedUp, branchHead: nil, heardAt: Self.later, heardAtInstall: Self.record(), of: "uptime", defaultBranch: "main",
                  mergeListing: nil, now: Self.later.addingTimeInterval(60))
        #expect(refs.pulls["uptime"]?.state == .open && refs.pulls["uptime"]?.checkedAt == Self.later,
                "closed before Look up, open when Look up asked: open, as heard then")
        refs = before
        refs.keep(nil, branchHead: nil, heardAtInstall: Self.record(), of: "uptime", defaultBranch: "main", mergeListing: nil,
                  now: Self.later)
        #expect(refs.pulls["uptime"] == pull && refs.branches["uptime"] == nil && refs.notCheckedSince["uptime"] == nil)
        refs = before
        refs.keep(nil, branchHead: nil, heardAtInstall: Self.record(ref: .defaultBranch("main")), of: "uptime",
                  defaultBranch: "main", mergeListing: nil, now: Self.later)
        #expect(!refs.holds("uptime") && refs.holds("cpu"))
        refs.forget("cpu")
        #expect(refs == FollowedRefs())
    }

    @Test("what Look up heard of a branch: its head, the commit it read; of a pull request nothing — its answer says it; and when it heard it")
    func branchHeadHeard() async throws {
        let branch = PluginOrigin(repository: .official, ref: .branch("fix/uptime"))
        #expect(InstallFromLinkTests.resolution(Self.movedOn, origin: branch).branchHead == Self.movedOn.commit)
        #expect(InstallFromLinkTests.resolution(Self.movedOn).branchHead == nil)
        // When: the moment the head was answered, as the resolver's clock says it.
        let provider = Provider(commits: [Self.movedOn], branches: ["fix/uptime": Self.movedOn.commit],
                                pulls: [3: Self.pull(head: Self.movedOn.commit)])
        let resolver = RefResolver(provider: provider, store: store, limits: RateLimitRecorder(), now: { Self.later })
        for link in [RepositoryLink.branch("fix/uptime", plugin: nil), .pullRequest(3)] {
            guard case .resolved(let found) = try await resolver.resolve(link, defaultBranch: "main", head: nil, udeck: nil,
                                                                         language: "en") else {
                Issue.record("\(link) resolves"); continue
            }
            #expect(found.heardAt == Self.later, "\(link)")
        }
    }

    @Test("a moved head as the cache holds it: the copy's folder there as a catalogue row reads it")
    func refHeads() async throws {
        let moved = Self.movedOn
        try store.save(moved.listing)
        try store.save(blob: moved.data(at: "plugins/uptime/manifest.json")!)
        let pull = FollowedPull(number: 3, head: moved.commit, state: .open, merged: false, base: "main", mergeCommit: nil,
                                mergeTree: nil, checkedAt: Self.at)
        var installed = Self.installed()
        installed.plugins["same"] = AdoptionTests.record(ref: .branch("same"))
        installed.plugins["uncached"] = AdoptionTests.record(ref: .branch("uncached"))
        installed.plugins["cpu"] = AdoptionTests.record(ref: .branch("cpu"))
        let followed = FollowedRefs(pulls: ["uptime": pull],
                                    branches: ["same": FollowedBranch(name: "same", head: AdoptionTests.pullHead, checkedAt: Self.at),
                                               "uncached": FollowedBranch(name: "uncached", head: "f00d", checkedAt: Self.at),
                                               "cpu": FollowedBranch(name: "cpu", head: moved.commit, checkedAt: Self.at)])
        let heads = await RefHead.read(from: store, followed: followed, installed: installed, defaultBranch: "main",
                                       udeck: SemanticVersion("0.7.0"), language: "en")
        #expect(Set(heads.keys) == ["uptime", "cpu"], "not a head that is the commit installed, nor one not listed")
        #expect(heads["uptime"]?.commit == moved.commit && heads["uptime"]?.entry?.listing == moved.plugin("uptime"))
        #expect(heads["uptime"]?.entry?.manifest?.version == "1.0.1" && heads["uptime"]?.entry?.verdict.refusals.isEmpty == true)
        #expect(heads["cpu"] == RefHead(commit: moved.commit, entry: nil), "the folder not at that head")
    }

    // MARK: - What the row offers

    static func head(_ repository: FakeRepository, _ id: String = "uptime") -> RefHead {
        RefHead(commit: repository.commit,
                entry: repository.listing.plugins[id] == nil ? nil : InstallFromLinkTests.entry(repository, id))
    }

    static var olderHead: FakeRepository {
        var repository = FakeRepository.withUptime(version: "1.0.0")
        repository.commit = String(repeating: "4", count: 40)
        return repository
    }

    static var newerHead: FakeRepository {
        var repository = FakeRepository.withUptime(version: "1.1.0")
        repository.commit = String(repeating: "3", count: 40)
        return repository
    }

    static var cannotRunHead: FakeRepository {
        var repository = FakeRepository.withUptime()
        repository.addPlugin("uptime", manifest: FakeRepository.manifest(version: "2.0.0", api: 2))
        repository.commit = String(repeating: "2", count: 40)
        return repository
    }

    static func heard(_ repository: FakeRepository, rewritten: Bool? = nil,
                      from: String = installedCommit) -> (commit: String, history: HeadHistory?) {
        (repository.commit, rewritten.map { HeadHistory(from: from, to: repository.commit, rewritten: $0, checkedAt: at) })
    }

    static let offers: [(String, InstalledRecord, (commit: String, history: HeadHistory?)?, RefHead?, RefOffer?)] = [
        ("nothing heard", record(), nil, head(movedOn), nil),
        ("the head is the commit installed", record(), heard(installedHead), head(installedHead), nil),
        ("the head's listing not read yet", record(), heard(movedOn, rewritten: false), nil, nil),
        ("the cache holds another head than was heard", record(), heard(movedOn, rewritten: false), head(newerHead), nil),
        ("moved on, the copy's folder as it was there", record(), heard(otherPluginChanged), head(otherPluginChanged), nil),
        ("other files under the same version", record(), heard(movedOn, rewritten: false), head(movedOn),
         RefOffer(head: movedOn.commit, offer: .changedStill(version: "1.0.1"), rewritten: false)),
        ("pushed again over what is installed", record(), heard(movedOn, rewritten: true), head(movedOn),
         RefOffer(head: movedOn.commit, offer: .changedStill(version: "1.0.1"), rewritten: true)),
        ("what was found was of another commit installed", record(), heard(movedOn, rewritten: true, from: "c0ffee"),
         head(movedOn), RefOffer(head: movedOn.commit, offer: .changedStill(version: "1.0.1"), rewritten: false)),
        ("a newer version", record(ref: .branch("fix/uptime")), heard(newerHead, rewritten: false), head(newerHead),
         RefOffer(head: newerHead.commit, offer: .newer(version: "1.1.0"), rewritten: false)),
        ("an older one", record(), heard(olderHead, rewritten: true), head(olderHead),
         RefOffer(head: olderHead.commit, offer: .older(version: "1.0.0"), rewritten: true)),
        ("its folder gone from the head", record(), heard(withoutUptime, rewritten: false), head(withoutUptime),
         RefOffer(head: withoutUptime.commit, offer: .goneFromRepository, rewritten: false)),
        ("a version that cannot run here", record(), heard(cannotRunHead), head(cannotRunHead),
         RefOffer(head: cannotRunHead.commit,
                  offer: UpdateOffer.of(record(), head: head(cannotRunHead).entry), rewritten: false)),
        ("the default branch's copy", record(ref: .defaultBranch("main")), heard(movedOn), head(movedOn), nil),
    ]

    @Test("what a copy's line offers it, against the copy installed", arguments: 0..<offers.count)
    func offer(row: Int) {
        let (label, record, heard, head, expected) = Self.offers[row]
        #expect(RefOffer.of(record, heard: heard, head: head) == expected, "\(label)")
    }

    @Test("what the row says of what its line offers, and the button that goes with it", arguments: Language.allCases)
    func offerSaid(language: Language) {
        let strings = Strings(language)
        func said(_ offer: UpdateOffer, _ ref: PluginRef = .pullRequest(3)) -> String {
            RefOffer(head: "h", offer: offer, rewritten: false).said(ref: ref, id: "uptime").map { strings($0) }
                .joined(separator: " — ")
        }
        let cannot = UpdateOffer.of(Self.record(), head: Self.head(Self.cannotRunHead).entry)
        #expect(RefOffer(head: "h", offer: .newer(version: "1.1.0"), rewritten: false).button == .catalogueUpdate)
        #expect(RefOffer(head: "h", offer: .changedStill(version: "1.0.1"), rewritten: false).button == .catalogueUpdate)
        #expect(RefOffer(head: "h", offer: .older(version: "1.0.0"), rewritten: false).button == .catalogueSwitchTo(version: "1.0.0"))
        #expect(RefOffer(head: "h", offer: .goneFromRepository, rewritten: false).button == nil)
        #expect(RefOffer(head: "h", offer: cannot, rewritten: false).button == nil)
        switch language {
        case .english:
            #expect(said(.changedStill(version: "1.0.1")) == "Changed in pull request #3, still 1.0.1")
            #expect(said(.changedStill(version: "1.0.1"), .branch("fix/uptime")) == "Changed in branch fix/uptime, still 1.0.1")
            #expect(said(.newer(version: "1.1.0")) == "1.1.0 available in pull request #3")
            #expect(said(.older(version: "1.0.0"), .branch("fix/uptime")) == "Branch fix/uptime now has 1.0.0")
            #expect(said(.goneFromRepository) == "uptime is no longer in pull request #3; the plugin keeps running")
            #expect(said(cannot) == "2.0.0 needs a newer uDeck (api 2)")
            #expect(strings(.pluginRefRewritten(ref: .pullRequest(3)))
                    == "The history of pull request #3 was rewritten: its new head does not continue what is installed")
            #expect(strings(.pluginRefRewritten(ref: .branch("fix/uptime")))
                    == "The history of branch fix/uptime was rewritten: its new head does not continue what is installed")
            #expect(strings(.pluginBranchGone(name: "fix/uptime")) == "Branch fix/uptime no longer exists; the plugin keeps running")
            #expect(strings(.pluginRefNotCheckedSince(ref: .pullRequest(3), at: "14:02")) == "Pull request #3 not checked since 14:02")
            #expect(strings(.pluginRefNotCheckedSince(ref: .branch("fix/uptime"), at: "14:02"))
                    == "Branch fix/uptime not checked since 14:02")
        case .russian:
            #expect(said(.changedStill(version: "1.0.1")) == "Изменён в запросе на слияние #3, всё ещё 1.0.1")
            #expect(said(.changedStill(version: "1.0.1"), .branch("fix/uptime")) == "Изменён в ветке fix/uptime, всё ещё 1.0.1")
            #expect(said(.newer(version: "1.1.0")) == "В запросе на слияние #3 доступна 1.1.0")
            #expect(said(.older(version: "1.0.0"), .branch("fix/uptime")) == "В ветке fix/uptime теперь 1.0.0")
            #expect(said(.goneFromRepository) == "uptime больше нет в запросе на слияние #3; плагин продолжает работать")
            #expect(said(cannot) == "2.0.0 нужен uDeck новее (api 2)")
            #expect(strings(.pluginRefRewritten(ref: .pullRequest(3)))
                    == "История запроса на слияние #3 переписана: новый последний коммит не продолжает установленный")
            #expect(strings(.pluginRefRewritten(ref: .branch("fix/uptime")))
                    == "История ветки fix/uptime переписана: новый последний коммит не продолжает установленный")
            #expect(strings(.pluginBranchGone(name: "fix/uptime")) == "Ветки fix/uptime больше нет; плагин продолжает работать")
            #expect(strings(.pluginRefNotCheckedSince(ref: .pullRequest(3), at: "14:02")) == "Запрос на слияние #3 не проверялся с 14:02")
            #expect(strings(.pluginRefNotCheckedSince(ref: .branch("fix/uptime"), at: "14:02"))
                    == "Ветка fix/uptime не проверялась с 14:02")
        }
    }

    // MARK: - The row, whole

    static var verified: CatalogueEntry { InstallFromLinkTests.entry(InstallFromLinkTests.head, "uptime") }
    static var verifiedRefused: CatalogueEntry {
        var repository = InstallFromLinkTests.head
        repository.addPlugin("uptime", manifest: FakeRepository.manifest(api: 2))
        return InstallFromLinkTests.entry(repository, "uptime")
    }

    static func followed(_ pull: FollowedPull? = nil, branch: FollowedBranch? = nil, notChecked: Date? = nil) -> FollowedRefs {
        FollowedRefs(pulls: pull.map { ["uptime": $0] } ?? [:], branches: branch.map { ["uptime": $0] } ?? [:],
                     notCheckedSince: notChecked.map { ["uptime": $0] } ?? [:])
    }

    static func heardPull(state: PullRequest.State = .open, merged: Bool = false, base: String? = "main",
                          mergeTree: String? = nil, head: String = movedOn.commit, rewritten: Bool? = false) -> FollowedPull {
        FollowedPull(number: 3, head: head, state: state, merged: merged, base: base,
                     mergeCommit: merged && base == "main" ? AdoptionTests.mergeCommit : nil, mergeTree: mergeTree,
                     checkedAt: at, history: rewritten.map { HeadHistory(from: installedCommit, to: head, rewritten: $0, checkedAt: at) })
    }

    static let changedStill = RefOffer(head: movedOn.commit, offer: .changedStill(version: "1.0.1"), rewritten: false)

    /// (label, record, followed, readsCatalogue, verified entry, the row)
    static let rows: [(String, InstalledRecord?, FollowedRefs, Bool, CatalogueEntry?, UnverifiedRow?)] = [
        ("the default branch's copy: no such row", record(ref: .defaultBranch("main")), followed(), true, verified, nil),
        ("nothing installed: no such row", nil, followed(), true, verified, nil),
        ("nothing heard: the verified copy, switched to", record(), followed(), true, verified,
         UnverifiedRow(lifecycle: nil, verifiedVersion: "1.0.0", lineOffer: nil, branchGone: false, notCheckedSince: nil)),
        ("the catalogue off: no verified copy, nothing offered, nothing said not checked", record(),
         followed(heardPull(), notChecked: at), false, verified,
         UnverifiedRow(lifecycle: .open, verifiedVersion: nil, lineOffer: nil, branchGone: false, notCheckedSince: nil)),
        ("the catalogue does not have it", record(), followed(), true, nil,
         UnverifiedRow(lifecycle: nil, verifiedVersion: nil, lineOffer: nil, branchGone: false, notCheckedSince: nil)),
        ("the catalogue's copy cannot run here", record(), followed(), true, verifiedRefused,
         UnverifiedRow(lifecycle: nil, verifiedVersion: nil, lineOffer: nil, branchGone: false, notCheckedSince: nil)),
        ("its pull request moved on: offered along it, and the verified copy still there to switch to", record(),
         followed(heardPull()), true, verified,
         UnverifiedRow(lifecycle: .open, verifiedVersion: "1.0.0", lineOffer: changedStill, branchGone: false,
                       notCheckedSince: nil)),
        ("not checked in the last read: said, and what was heard still offered", record(),
         followed(heardPull(), notChecked: at), true, verified,
         UnverifiedRow(lifecycle: .open, verifiedVersion: "1.0.0", lineOffer: changedStill, branchGone: false,
                       notCheckedSince: at)),
        ("merged into main as something else: the verified copy is the update, its head offered no more", record(),
         followed(heardPull(state: .closed, merged: true, mergeTree: other)), true, verified,
         UnverifiedRow(lifecycle: .mergedDiffers, verifiedVersion: "1.0.0", lineOffer: nil, branchGone: false,
                       notCheckedSince: nil)),
        ("merged into main, nothing verified offered here", record(),
         followed(heardPull(state: .closed, merged: true, mergeTree: other)), false, verified,
         UnverifiedRow(lifecycle: .mergedNothingOffered, verifiedVersion: nil, lineOffer: nil, branchGone: false,
                       notCheckedSince: nil)),
        ("merged into main, the catalogue read and without the plugin: nothing verified offered", record(),
         followed(heardPull(state: .closed, merged: true, mergeTree: other)), true, nil,
         UnverifiedRow(lifecycle: .mergedNothingOffered, verifiedVersion: nil, lineOffer: nil, branchGone: false,
                       notCheckedSince: nil)),
        ("merged into main, the catalogue's copy cannot run here: nothing verified offered", record(),
         followed(heardPull(state: .closed, merged: true, mergeTree: other)), true, verifiedRefused,
         UnverifiedRow(lifecycle: .mergedNothingOffered, verifiedVersion: nil, lineOffer: nil, branchGone: false,
                       notCheckedSince: nil)),
        ("merged into another branch: its head is still its line's", record(),
         followed(heardPull(state: .closed, merged: true, base: "next")), true, verified,
         UnverifiedRow(lifecycle: .open, verifiedVersion: "1.0.0", lineOffer: changedStill, branchGone: false,
                       notCheckedSince: nil)),
        ("closed unmerged, and moved on before it was", record(), followed(heardPull(state: .closed)), true, verified,
         UnverifiedRow(lifecycle: .closed, verifiedVersion: "1.0.0", lineOffer: changedStill, branchGone: false,
                       notCheckedSince: nil)),
        ("a branch moved on", record(ref: .branch("fix/uptime")),
         followed(branch: FollowedBranch(name: "fix/uptime", head: movedOn.commit,
                                         history: HeadHistory(from: installedCommit, to: movedOn.commit, rewritten: true,
                                                              checkedAt: at), checkedAt: at)), true, verified,
         UnverifiedRow(lifecycle: nil, verifiedVersion: "1.0.0",
                       lineOffer: RefOffer(head: movedOn.commit, offer: .changedStill(version: "1.0.1"), rewritten: true),
                       branchGone: false, notCheckedSince: nil)),
        ("a branch deleted: said, nothing offered along it", record(ref: .branch("fix/uptime")),
         followed(branch: FollowedBranch(name: "fix/uptime", head: nil, checkedAt: at)), true, verified,
         UnverifiedRow(lifecycle: nil, verifiedVersion: "1.0.0", lineOffer: nil, branchGone: true, notCheckedSince: nil)),
        ("another branch deleted: nothing said", record(ref: .branch("fix/uptime")),
         followed(branch: FollowedBranch(name: "other", head: nil, checkedAt: at)), true, verified,
         UnverifiedRow(lifecycle: nil, verifiedVersion: "1.0.0", lineOffer: nil, branchGone: false, notCheckedSince: nil)),
    ]

    @Test("the row of a copy of code nobody verified, decided whole", arguments: 0..<rows.count)
    func row(row: Int) {
        let (label, record, followed, reads, entry, expected) = Self.rows[row]
        let said = UnverifiedRow.of("uptime", record: record, followed: followed,
                                    head: Self.head(Self.movedOn), defaultBranch: "main", readsCatalogue: reads,
                                    verified: entry)
        #expect(said == expected, "\(label)")
    }

    /// One press, one name (R4+R6's review, low #5): the verified copy's
    /// button says **Update** on both rows once the pull request was merged
    /// as something else — what the row says to do — and **Switch to
    /// verified** otherwise.
    @Test("the verified copy's button: one name on both rows; what counts as waiting")
    func verifiedButton() {
        func row(_ lifecycle: PullRequestLifecycle?, _ version: String?, _ line: RefOffer? = nil) -> UnverifiedRow {
            UnverifiedRow(lifecycle: lifecycle, verifiedVersion: version, lineOffer: line, branchGone: false, notCheckedSince: nil)
        }
        #expect(row(.mergedDiffers, "1.0.2").verifiedButton == .catalogueUpdate && row(.mergedDiffers, "1.0.2").verifiedIsAnUpdate)
        #expect(row(.mergedDiffers, "1.0.2").waiting)
        #expect(row(.open, "1.0.2").verifiedButton == .catalogueSwitchToVerified(version: "1.0.2") && !row(.open, "1.0.2").waiting)
        #expect(row(.closed, "1.0.2").verifiedButton == .catalogueSwitchToVerified(version: "1.0.2"))
        #expect(row(nil, nil).verifiedButton == nil && !row(.mergedDiffers, nil).verifiedIsAnUpdate)
        #expect(row(.open, nil, Self.changedStill).waiting, "other files along its line: waiting")
        let older = RefOffer(head: "h", offer: .older(version: "1.0.0"), rewritten: false)
        let gone = RefOffer(head: "h", offer: .goneFromRepository, rewritten: false)
        #expect(!row(.open, nil, older).waiting && !row(.open, nil, gone).waiting, "a switch back or a folder gone: not an update")
    }

    @Test("what the plugin's row says under its mark, in order, each with its identifier", arguments: Language.allCases)
    func said(language: Language) {
        let strings = Strings(language)
        let all = UnverifiedRow(lifecycle: .closed, verifiedVersion: "1.0.0",
                                lineOffer: RefOffer(head: "h", offer: .changedStill(version: "1.0.1"), rewritten: true),
                                branchGone: false, notCheckedSince: Self.at)
        let said = all.said(ref: .pullRequest(3), id: "uptime", time: { _ in "14:02" })
        #expect(said.map(\.suffix) == ["pullRequest", "rewritten", "offer", "notChecked"])
        let gone = UnverifiedRow(lifecycle: nil, verifiedVersion: nil, lineOffer: nil, branchGone: true, notCheckedSince: nil)
        #expect(gone.said(ref: .branch("fix/uptime"), id: "uptime", time: { _ in "" })
                == [UnverifiedRow.Said(suffix: "branchGone", phrase: [.pluginBranchGone(name: "fix/uptime")])])
        #expect(gone.said(ref: .pullRequest(3), id: "uptime", time: { _ in "" }).isEmpty, "a branch is said gone only of a branch")
        let open = UnverifiedRow(lifecycle: .open, verifiedVersion: nil, lineOffer: nil, branchGone: false, notCheckedSince: nil)
        #expect(open.said(ref: .pullRequest(3), id: "uptime", time: { _ in "" }).isEmpty, "open, with nothing offered: nothing")
        let text = said.map { $0.phrase.map { strings($0) }.joined(separator: " — ") }
        switch language {
        case .english:
            #expect(text == ["Pull request #3 was closed without being merged; the plugin keeps running",
                             "The history of pull request #3 was rewritten: its new head does not continue what is installed",
                             "Changed in pull request #3, still 1.0.1", "Pull request #3 not checked since 14:02"])
        case .russian:
            #expect(text == ["Запрос на слияние #3 закрыт без слияния; плагин продолжает работать",
                             "История запроса на слияние #3 переписана: новый последний коммит не продолжает установленный",
                             "Изменён в запросе на слияние #3, всё ещё 1.0.1", "Запрос на слияние #3 не проверялся с 14:02"])
        }
    }

    // MARK: - Update along the line

    @Test("Update along the line: the head's folder from the copy's own line, at once or over the operator's work after the warning")
    func alongTheLine() throws {
        let udeck = TemporaryDirectory()
        let paths = udeck.paths
        let installed = Self.installed()
        let moved = Self.head(Self.movedOn)
        let folder = paths.plugins.appendingPathComponent("uptime", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Self.installedHead.files.filter { $0.key.hasPrefix("plugins/uptime/") }.forEach { path, file in
            let url = folder.appendingPathComponent(String(path.dropFirst("plugins/uptime/".count)))
            try file.data.write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: file.mode == "100755" ? 0o755 : 0o644],
                                                  ofItemAtPath: url.path)
        }
        #expect(try GitHash.tree(ofDirectoryAt: folder) == Self.installedTree, "the premise: the folder is what was installed")
        let origin = PluginOrigin(repository: .official, ref: .pullRequest(3))
        #expect(ShownPlace.alongTheLine("uptime", head: moved, in: paths, installed: installed, shown: nil)
                == .install(.update, commit: Self.movedOn.commit, folder: Self.movedOn.plugin("uptime"), version: "1.0.1",
                            from: origin), "the same line: no switch, nothing to warn of")
        #expect(ShownPlace.alongTheLine("uptime", head: nil, in: paths, installed: installed, shown: nil) == .nothing)
        #expect(ShownPlace.alongTheLine("uptime", head: Self.head(Self.installedHead), in: paths, installed: installed,
                                        shown: nil) == .nothing, "the head is the commit installed")
        #expect(ShownPlace.alongTheLine("uptime", head: Self.head(Self.withoutUptime), in: paths, installed: installed,
                                        shown: nil) == .nothing, "no folder there")
        #expect(ShownPlace.alongTheLine("uptime", head: Self.head(Self.cannotRunHead), in: paths, installed: installed,
                                        shown: nil) == .nothing, "a version that cannot run here")
        #expect(ShownPlace.alongTheLine("uptime", head: moved, in: paths, installed: Self.installed(.defaultBranch("main")),
                                        shown: nil) == .nothing, "the default branch's copy follows the catalogue")
        // A .env of the operator's in the folder: the warning first, then the update.
        try Data("TOKEN=x\n".utf8).write(to: folder.appendingPathComponent(".env"))
        guard case .ask(let shown) = ShownPlace.alongTheLine("uptime", head: moved, in: paths, installed: installed, shown: nil)
        else { Issue.record("no warning over the operator's work"); return }
        #expect(shown.fate == .toTrash && shown.copy == Self.movedOn.commit && shown.switching == nil)
        #expect(ShownPlace.alongTheLine("uptime", head: moved, in: paths, installed: installed, shown: shown)
                == .install(.update, commit: Self.movedOn.commit, folder: Self.movedOn.plugin("uptime"), version: "1.0.1",
                            from: origin))
    }
}
