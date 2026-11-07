import Foundation
import Testing
@testable import UDeckCore
import UDeckPluginFormatFixtures

/// A token's life after it is checked (S4-17 to S4-20): whose turn it is to
/// change it, the lease every client asks before each request, what the
/// vault keeps and forgets, and what nothing sends again.
@Suite("Tokens over time: turns, leases, forgetting")
struct TokenLifecycleTests {
    static let origin = Origin("https://gitlab.example.test")!

    static func credential(_ token: String, remoteID: Int = 11, provider: String = "gitlab") -> SourceCredential {
        SourceCredential(token: Secret(token), binding: CredentialBinding(provider: provider, remoteID: remoteID,
                                                                          apiOrigin: origin))
    }

    static func source(_ id: String = "s", remoteID: Int = 11, access: String = OwnSource.Access.token) -> OwnSource {
        OwnSource(id: id, provider: "gitlab", host: "gitlab.example.test", path: "tools/udeck-private",
                  remoteID: remoteID, access: access, addedAt: nil)
    }

    // MARK: - Turns

    @Test("a later ticket takes the turn from every earlier one; looking at the turn takes none")
    func turns() {
        var book = SourceTokenBook()
        let first = book.begin("s")
        let looked = book.ticket("s")
        #expect(book.isCurrent(first) && book.isCurrent(looked))
        let second = book.begin("s")
        #expect(!book.isCurrent(first) && !book.isCurrent(looked) && book.isCurrent(second))
        let other = book.begin("other")
        #expect(book.isCurrent(other) && book.isCurrent(second), "another source's turn is its own")
    }

    @Test("a check that lost its turn holds nothing: Forget, Remove or another token pressed meanwhile")
    func staleHoldsNothing() {
        var book = SourceTokenBook()
        let check = book.begin("s")
        book.withdraw("s")
        #expect(book.hold(Self.credential("glpat-late"), for: check) == nil)
        #expect(book.credential(of: "s") == nil)
    }

    // MARK: - Leases

    @Test("a token held is handed out under a lease; the same token again keeps it, another ends it")
    func leases() throws {
        var book = SourceTokenBook()
        let first = book.hold(Self.credential("glpat-a"), for: book.ticket("s"))
        let held = try #require(first)
        let lease = try #require(held.lease)
        #expect(book.credential(of: "s") == held)
        let repeated = book.hold(Self.credential("glpat-a"), for: book.ticket("s"))
        let again = try #require(repeated)
        #expect(again.lease === lease, "every client's copy stays good")
        let replaced = book.hold(Self.credential("glpat-b"), for: book.ticket("s"))
        let other = try #require(replaced)
        #expect(lease.ending == .withdrawn, "the token replaced: its copies send nothing more")
        #expect(other.lease !== lease && other.lease?.ending == nil)
    }

    @Test("withdrawn: the lease ends, nothing is held, and the turn moves; released: the same, the turn kept")
    func withdrawAndRelease() throws {
        var book = SourceTokenBook()
        let first = book.hold(Self.credential("glpat-a"), for: book.ticket("s"))
        let lease = try #require(first?.lease)
        let check = book.begin("s")
        book.release("s")
        #expect(lease.ending == .withdrawn && book.credential(of: "s") == nil)
        #expect(book.isCurrent(check), "a check under way keeps its turn")
        let held = book.hold(Self.credential("glpat-b"), for: check)
        let second = try #require(held?.lease)
        book.withdraw("s")
        #expect(second.ending == .withdrawn && book.credential(of: "s") == nil && !book.isCurrent(check))
    }

    @Test("a token the host refused is held as refused: handed out to nothing until a press holds it again")
    func refused() throws {
        var book = SourceTokenBook()
        let first = book.hold(Self.credential("glpat-a"), for: book.ticket("s"))
        let lease = try #require(first?.lease)
        lease.end(.rejected)
        lease.end(.withdrawn)
        #expect(lease.ending == .rejected, "the first reason stays")
        #expect(book.wasRejected("s") && book.credential(of: "s") == nil)
        let pressed = book.hold(Self.credential("glpat-a"), for: book.ticket("s"), renewingRejected: true)
        let again = try #require(pressed)
        #expect(again.lease !== lease && again.lease?.ending == nil, "Check now: a new lease for the same token")
        #expect(!book.wasRejected("s"))
    }

    @Test("sources.json changed by hand: a source gone, switched to no token, or another number gives its token back")
    func reconcile() throws {
        var book = SourceTokenBook()
        var leases: [String: CredentialLease] = [:]
        for id in ["gone", "none", "moved", "kept"] {
            let held = book.hold(Self.credential("glpat-\(id)"), for: book.ticket(id))
            leases[id] = try #require(held?.lease)
        }
        let withdrawn = book.reconcile(with: [Self.source("none", access: OwnSource.Access.none),
                                              Self.source("moved", remoteID: 12), Self.source("kept")])
        #expect(withdrawn == ["gone", "moved", "none"])
        #expect(leases["gone"]?.ending == .withdrawn && leases["none"]?.ending == .withdrawn
                && leases["moved"]?.ending == .withdrawn)
        #expect(leases["kept"]?.ending == nil && book.credential(of: "kept") != nil)
    }

    @Test("a credential is the same whatever lease it carries")
    func equality() {
        var leased = Self.credential("glpat-a")
        leased.lease = CredentialLease()
        #expect(leased == Self.credential("glpat-a"))
        #expect(Self.credential("glpat-a") != Self.credential("glpat-b"))
    }

    // MARK: - The clients ask the lease

    @Test("GitHub: a token taken back is not sent, and a 401 ends its lease so no copy sends it again")
    func githubLease() async throws {
        let host = RedirectTests.host("lease")
        StubAnswers.answer(host) { _ in (401, Data()) }
        defer { StubAnswers.forget(host) }
        var credential = RedirectTests.credential(host)
        let lease = CredentialLease()
        credential.lease = lease
        let client = RedirectTests.client(host, credential: credential)
        let copy = RedirectTests.client(host, credential: credential)
        await #expect(throws: ProviderError.unauthorized) { _ = try await client.describe() }
        #expect(lease.ending == .rejected)
        await #expect(throws: ProviderError.tokenWithdrawn(.rejected)) { _ = try await copy.describe() }
        #expect(StubAnswers.asked(host).count == 1, "the refused token went once")

        let taken = RedirectTests.host("taken")
        StubAnswers.answer(taken) { _ in (200, Data()) }
        defer { StubAnswers.forget(taken) }
        var withdrawn = RedirectTests.credential(taken)
        withdrawn.lease = CredentialLease()
        withdrawn.lease?.end(.withdrawn)
        await #expect(throws: ProviderError.tokenWithdrawn(.withdrawn)) {
            _ = try await RedirectTests.client(taken, credential: withdrawn).describe()
        }
        #expect(StubAnswers.asked(taken).isEmpty, "nothing sent, not even anonymously")
    }

    @Test("GitLab: a token taken back is not sent, and a 401 ends its lease")
    func gitlabLease() async throws {
        let stub = GitLabClientTests.Stub("gllease")
        stub.answer { _ in (401, Data(#"{"message":"401 Unauthorized"}"#.utf8)) }
        defer { stub.forget() }
        let origin = try #require(Origin(stub.endpoints.apiBase))
        let lease = CredentialLease()
        let credential = SourceCredential(token: Secret("glpat-x"), binding: CredentialBinding(
            provider: "gitlab", remoteID: GitLabClientTests.project, apiOrigin: origin), lease: lease)
        func client() -> GitLabClient {
            GitLabClient(endpoints: stub.endpoints, path: "tools/udeck-plugins", remoteID: GitLabClientTests.project,
                         udeckVersion: "0.8.0", limits: RateLimitRecorder(),
                         session: GitHubClient.makeSession(protocolClasses: [StubAnswers.self]), credential: credential)
        }
        await #expect(throws: ProviderError.unauthorized) { _ = try await client().describe() }
        #expect(lease.ending == .rejected)
        // A file, read as it arrives: refused on its headers, its body lost on the way.
        StubAnswers.failBodies(stub.host)
        let fileLease = CredentialLease()
        var fileCredential = credential
        fileCredential.lease = fileLease
        let files = GitLabClient(endpoints: stub.endpoints, path: "tools/udeck-plugins", remoteID: GitLabClientTests.project,
                                 udeckVersion: "0.8.0", limits: RateLimitRecorder(),
                                 session: GitHubClient.makeSession(protocolClasses: [StubAnswers.self]), credential: fileCredential)
        await #expect(throws: ProviderError.unauthorized) {
            _ = try await files.file(at: "plugins/x/manifest.json", commit: String(repeating: "a", count: 40))
        }
        #expect(fileLease.ending == .rejected)
        let sent = StubAnswers.asked(stub.host).count
        await #expect(throws: ProviderError.tokenWithdrawn(.rejected)) { _ = try await client().describe() }
        #expect(StubAnswers.asked(stub.host).count == sent, "nothing sent once refused")
    }

    @Test("the token's answers are never retried; a refused or taken-back token reads as the source's own trouble")
    func theTokensAnswers() {
        for error in [ProviderError.unauthorized, .forbidden(scope: "read_api"), .moved(status: 301), .credentialUnbound,
                      .tokenWithdrawn(.withdrawn), .tokenWithdrawn(.rejected)] {
            #expect(error.isTheTokens, "\(error)")
        }
        for error in [ProviderError.notFound, .refused(status: 500), .unreachable("x"), .tooLarge(bytes: 1)] {
            #expect(!error.isTheTokens, "\(error)")
        }
        #expect(CatalogueRefresher.reason(ProviderError.tokenWithdrawn(.rejected), branch: nil) == .unauthorized)
        #expect(CatalogueRefresher.reason(ProviderError.tokenWithdrawn(.withdrawn), branch: nil) == .tokenWithdrawn)
        let said = { (error: CatalogueError) in
            CatalogueTrouble.phrase(error, address: "gitlab.example.test/tools/udeck-private", host: "gitlab.example.test",
                                    readAt: nil, until: { _ in "" }, provider: "gitlab", tokened: true)
        }
        #expect(said(.tokenMissing) == .sourceTokenMissing(address: "gitlab.example.test/tools/udeck-private"))
        #expect(said(.tokenWithdrawn) == .sourceTokenWithdrawn(address: "gitlab.example.test/tools/udeck-private"))
    }

    // MARK: - The vault

    @Test("a check that lost its turn takes back its own write alone: never a write after it, of the same token or another")
    func forgetOnlyItsOwnWrite() async throws {
        let store = CredentialTests.FakeStore()
        let vault = CredentialVault(store: store)
        let token = Self.credential("glpat-same")
        let first = try await vault.keep(token, for: "s")
        let second = try await vault.keep(token, for: "s")
        #expect(first != second)
        try await vault.forget("s", written: first)
        #expect(await vault.credential(for: Self.source(), apiOrigin: Self.origin, requested: true) == .credential(token),
                "the second write of the same token stays")
        try await vault.forget("s", written: second)
        #expect(await vault.credential(for: Self.source(), apiOrigin: Self.origin, requested: true) == .missing)
        #expect(store.data == nil, "the item deleted with the last token")
        // A token another uDeck wrote — none of this one's writes — is never taken back as one.
        try await CredentialVault(store: store).keep(token, for: "s")
        try await vault.forget("s", written: second)
        #expect(store.data != nil)
    }

    @Test("pruned: tokens of sources that have none, once the item was read — never one in the list or written after the cutoff")
    func prune() async throws {
        let store = CredentialTests.FakeStore()
        try await CredentialVault(store: store).keep(Self.credential("glpat-a"), for: "a")
        try await CredentialVault(store: store).keep(Self.credential("glpat-b"), for: "b")
        let vault = CredentialVault(store: store)
        let calls = store.calls.count
        try await vault.prune(keeping: ["a"], writtenBefore: .infinity)
        #expect(store.calls.count == calls, "not read yet: the Keychain left alone, nothing pruned")
        _ = await vault.credential(for: Self.source("a"), apiOrigin: Self.origin, requested: false)
        let read = store.calls.count
        try await vault.prune(keeping: ["a", "b"], writtenBefore: .infinity)
        #expect(store.calls.count == read, "nothing to go: nothing read or written")
        let cutoff = ProcessInfo.processInfo.systemUptime
        try await vault.keep(Self.credential("glpat-c"), for: "c")
        try await vault.prune(keeping: ["a"], writtenBefore: cutoff)
        #expect(await vault.credential(for: Self.source("b"), apiOrigin: Self.origin, requested: true) == .missing,
                "another uDeck's leftover goes")
        #expect(await vault.credential(for: Self.source("c"), apiOrigin: Self.origin, requested: true)
                == .credential(Self.credential("glpat-c")), "written after the cutoff: being added, kept")
        #expect(await vault.credential(for: Self.source("a"), apiOrigin: Self.origin, requested: true)
                == .credential(Self.credential("glpat-a")))
    }

    @Test("a refused token is never held again by a lookup that waited, only by a press that may send it once more")
    func refusedIsNotRenewedByALookup() throws {
        var book = SourceTokenBook()
        let first = book.hold(Self.credential("glpat-a"), for: book.ticket("s"))
        let lease = try #require(first?.lease)
        let waiting = book.ticket("s")
        lease.end(.rejected)
        #expect(book.hold(Self.credential("glpat-a"), for: waiting) == nil, "a read that asked the Keychain before the 401")
        #expect(book.hold(Self.credential("glpat-b"), for: book.ticket("s")) == nil, "nor another token, unpressed")
        #expect(book.wasRejected("s"))
        book.release("s")
        #expect(book.wasRejected("s"), "a Keychain failure since does not make the refused token sendable")
        let pressed = book.hold(Self.credential("glpat-a"), for: book.ticket("s"), renewingRejected: true)
        #expect(pressed?.lease?.ending == nil && !book.wasRejected("s"), "Check now")
    }

    // MARK: - The schedule

    @Test("a source whose token was refused is read only when pressed: not by the clock, at launch or on Settings")
    func refusedIsNotScheduled() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var refused = CatalogueState()
        refused.lastError = .unauthorized
        refused.lastAttempt = now.addingTimeInterval(-3 * 86400)
        var other = refused
        other.lastError = .notFound
        let sources = [Self.source("refused"), Self.source("other")]
        let states = ["refused": refused, "other": other]
        #expect(SourceSchedule.due(sources, states: states, reading: [], now: now) == ["other"])
        #expect(SourceSchedule.atLaunch(sources, states: states, now: now) == ["other"])
        #expect(SourceSchedule.whenSettingsOpen(sources, states: states, now: now) == ["other"])
    }
}
