import Foundation
import Testing
@testable import UDeckCore

/// Tokens for sources of one's own (stage 4, R3a: S4-17, S4-18): a secret
/// that never prints, the origin a token is bound to, the header each kind
/// goes in, what a prefix proves, the pre-filled pages, and the vault over
/// a fake Keychain — no test here, or anywhere, touches a real one.
@Suite("Tokens: secrets, bindings and the vault")
struct CredentialTests {
    static let token = "ghp_the-labs-own-fixture-value-0123456789"

    // MARK: - Secret

    @Test("a secret prints, interpolates, dumps and mirrors as <redacted>")
    func secret() {
        let secret = Secret(Self.token)
        #expect(secret.revealed == Self.token)
        #expect("\(secret)" == "<redacted>" && String(describing: secret) == "<redacted>")
        #expect(String(reflecting: secret) == "<redacted>" && secret.debugDescription == "<redacted>")
        #expect(Mirror(reflecting: secret).children.isEmpty)
        var dumped = ""
        dump(secret, to: &dumped)
        #expect(!dumped.contains(Self.token), "\(dumped)")
        let credential = SourceCredential(token: secret, binding: Self.github)
        #expect(!"\(credential)".contains(Self.token) && !String(reflecting: credential).contains(Self.token))
        var whole = ""
        dump(credential, to: &whole)
        #expect(!whole.contains(Self.token), "\(whole)")
    }

    // MARK: - Origins and bindings

    static let github = CredentialBinding(provider: "github", remoteID: 1412415366,
                                          apiOrigin: Origin("https://api.github.com")!)
    static let gitlab = CredentialBinding(provider: "gitlab", remoteID: 48,
                                          apiOrigin: Origin("https://gitlab.unicorns.place")!)

    @Test("an origin is scheme, host and port, its own port left out, in one case")
    func origins() throws {
        #expect(Origin("https://API.GitHub.com/repositories/1")?.description == "https://api.github.com")
        #expect(Origin("https://api.github.com:443/x") == Origin("https://api.github.com"))
        #expect(Origin("http://127.0.0.1:8768/api/v4")?.description == "http://127.0.0.1:8768")
        #expect(Origin("http://example.test:80/") == Origin("http://example.test"))
        #expect(Origin("https://gitlab.example:8443")?.port == 8443)
        #expect(Origin("ftp://x.test") == nil && Origin("not a url") == nil && Origin("file:///etc") == nil)
        #expect(Origin("https://x.test")!.mayCarryASecret && Origin("http://127.0.0.1:1")!.mayCarryASecret)
        #expect(Origin("http://localhost:8766")!.isLoopback)
        #expect(!Origin("http://gitlab.example")!.mayCarryASecret, "never in the clear across a network")
        let coded = try JSONEncoder().encode(Self.gitlab)
        #expect(try JSONDecoder().decode(CredentialBinding.self, from: coded) == Self.gitlab)
        #expect(String(decoding: coded, as: UTF8.self).contains(#""apiOrigin":"https:\/\/gitlab.unicorns.place""#))
    }

    @Test("GitHub's token in Authorization: Bearer; a pasted GitLab token in PRIVATE-TOKEN, one from Sign in in Bearer")
    func headers() {
        let github = SourceCredential(token: Secret("github_pat_x"), binding: Self.github)
        #expect(github.header.name == "Authorization" && github.header.value == "Bearer github_pat_x")
        let pasted = SourceCredential(token: Secret("glpat-x"), binding: Self.gitlab)
        #expect(pasted.header.name == "PRIVATE-TOKEN" && pasted.header.value == "glpat-x")
        let signedIn = SourceCredential(kind: .oauth, token: Secret("gloas-x"), binding: Self.gitlab)
        #expect(signedIn.header.name == "Authorization" && signedIn.header.value == "Bearer gloas-x")
    }

    @Test("a token goes to the origin it was checked with, over HTTPS or to this machine, and nowhere else")
    func whereATokenGoes() {
        let credential = SourceCredential(token: Secret("t"), binding: Self.gitlab)
        #expect(credential.mayGo(to: URL(string: "https://gitlab.unicorns.place/api/v4/projects/48")!))
        #expect(credential.mayGo(to: URL(string: "https://GITLAB.unicorns.place:443/api/graphql")!))
        for elsewhere in ["https://gitlab.com/api/v4/projects/48", "https://gitlab.unicorns.place:8443/api/v4",
                          "http://gitlab.unicorns.place/api/v4", "https://raw.githubusercontent.com/o/r/c/f"] {
            #expect(!credential.mayGo(to: URL(string: elsewhere)!), "\(elsewhere)")
        }
        let lab = SourceCredential(token: Secret("t"), binding: CredentialBinding(
            provider: "gitlab", remoteID: 11, apiOrigin: Origin("http://127.0.0.1:8768")!))
        #expect(lab.mayGo(to: URL(string: "http://127.0.0.1:8768/api/v4/projects/11")!))
        #expect(!lab.mayGo(to: URL(string: "http://127.0.0.1:8769/api/v4/projects/11")!), "another port is another origin")
        let plain = SourceCredential(token: Secret("t"), binding: CredentialBinding(
            provider: "gitlab", remoteID: 1, apiOrigin: Origin("http://gitlab.example")!))
        #expect(!plain.mayGo(to: URL(string: "http://gitlab.example/api/v4/projects/1")!), "bound to a plain-HTTP origin: never")
    }

    // MARK: - Prefixes and pages

    @Test("a prefix that proves the other provider is refused; anything else proves nothing")
    func prefixes() {
        for token in ["ghp_x", "github_pat_x", "gho_x", "ghu_x", "ghs_x", "ghr_x", "  ghp_x\n"] {
            #expect(TokenPrefix.provider(of: token) == "github", "\(token)")
            #expect(TokenPrefix.isTheOtherProviders(token, source: "gitlab"))
            #expect(!TokenPrefix.isTheOtherProviders(token, source: "github"))
        }
        #expect(TokenPrefix.provider(of: "glpat-x") == "gitlab")
        #expect(TokenPrefix.isTheOtherProviders("glpat-x", source: "github"))
        #expect(!TokenPrefix.isTheOtherProviders("glpat-x", source: "gitlab"))
        for unknown in ["", "token", "gldt-x", "x_ghp_", "GHP_x"] {
            #expect(TokenPrefix.provider(of: unknown) == nil, "\(unknown)")
            #expect(!TokenPrefix.isTheOtherProviders(unknown, source: "github"))
            #expect(!TokenPrefix.isTheOtherProviders(unknown, source: "gitlab"))
        }
    }

    @Test("the pre-filled pages, exactly: GitHub's fine-grained token with Contents read-only, GitLab's with read_api")
    func pages() {
        #expect(TokenLinks.github(owner: "iillyyaa1997", repository: "udeck-plugins").absoluteString
                == "https://github.com/settings/personal-access-tokens/new?name=uDeck%3A%20udeck-plugins"
                + "&description=Read-only%2C%20for%20uDeck%20to%20read%20plugins%20from%20iillyyaa1997%2Fudeck-plugins."
                + "&target_name=iillyyaa1997&expires_in=366&contents=read")
        let long = TokenLinks.github(owner: "o", repository: String(repeating: "r", count: 60))
        let name = URLComponents(url: long, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "name" }?.value
        #expect(name?.count == 40 && name?.hasPrefix("uDeck: rrr") == true, "GitHub takes 40 characters at most")
        let plus = TokenLinks.github(owner: "o", repository: "a+b")
        #expect(plus.absoluteString.contains("name=uDeck%3A%20a%2Bb"), "a + is never read as a space")
        #expect(TokenLinks.gitlab(host: "gitlab.unicorns.place", project: "tools/udeck-plugins").absoluteString
                == "https://gitlab.unicorns.place/-/user_settings/personal_access_tokens?name=uDeck%3A%20tools%2Fudeck-plugins"
                + "&description=Read-only%2C%20for%20uDeck%20to%20read%20plugins%20from%20tools%2Fudeck-plugins."
                + "&scopes=read_api")
    }

    // MARK: - The vault

    /// The Keychain item, as a fake: its data, every call counted, and a
    /// failure to answer with when told.
    final class FakeStore: CredentialStore, @unchecked Sendable {
        private let lock = NSLock()
        private var item: Data?
        private var log: [String] = []
        private var failing: CredentialStoreError?
        private var failingWrites: CredentialStoreError?

        init(_ item: Data? = nil) { self.item = item }

        var data: Data? {
            get { lock.withLock { item } }
            set { lock.withLock { item = newValue } }
        }
        var calls: [String] { lock.withLock { log } }
        func fail(_ error: CredentialStoreError?) { lock.withLock { failing = error } }
        func failWrites(_ error: CredentialStoreError?) { lock.withLock { failingWrites = error } }

        func read() throws(CredentialStoreError) -> Data? {
            let (data, error) = lock.withLock { () -> (Data?, CredentialStoreError?) in
                log.append("read")
                return (item, failing)
            }
            if let error { throw error }
            return data
        }

        func write(_ data: Data, exists: Bool) throws(CredentialStoreError) {
            let error = lock.withLock { () -> CredentialStoreError? in
                log.append(exists ? "update" : "add")
                if failingWrites == nil { item = data }
                return failingWrites
            }
            if let error { throw error }
        }

        func delete() throws(CredentialStoreError) {
            lock.withLock {
                log.append("delete")
                item = nil
            }
        }
    }

    static func source(_ id: String = "gitlab.unicorns.place-udeck-plugins-12345678", provider: String = "gitlab",
                       host: String = "gitlab.unicorns.place", remoteID: Int = 48,
                       access: String = OwnSource.Access.token) -> OwnSource {
        OwnSource(id: id, provider: provider, host: host, path: "tools/udeck-plugins", remoteID: remoteID, access: access,
                  addedAt: nil)
    }

    static let origin = Origin("https://gitlab.unicorns.place")!

    /// What a change of the vault failed with — nil when it did not.
    static func changeError(_ body: () async throws(CredentialVault.ChangeError) -> Void) async
        -> CredentialVault.ChangeError? {
        do {
            try await body()
            return nil
        } catch {
            return error
        }
    }

    @Test("a token kept is handed out for its source's own origin; the item is JSON of every source's, written once")
    func keptAndHandedOut() async throws {
        let store = FakeStore()
        let vault = CredentialVault(store: store)
        let source = Self.source()
        let credential = SourceCredential(token: Secret("glpat-kept"), binding: Self.gitlab)
        try await vault.keep(credential, for: source.id)
        #expect(store.calls == ["read", "add"], "a fresh read, then one write that adds the item")
        let item = try #require(store.data)
        let object = try JSONSerialization.jsonObject(with: item)
        let json = try #require(object as? [String: Any])
        #expect(json["version"] as? Int == 1)
        let entry = try #require((json["tokens"] as? [String: Any])?[source.id] as? [String: Any])
        #expect(entry["kind"] as? String == "pat" && entry["token"] as? String == "glpat-kept")
        #expect((entry["binding"] as? [String: Any])?["remoteID"] as? Int == 48)
        #expect(await vault.credential(for: source, apiOrigin: Self.origin, requested: false) == .credential(credential))
        // A new vault — a relaunch — reads the item once, the first time a source with a token needs it.
        let relaunched = CredentialVault(store: store)
        #expect(await relaunched.credential(for: Self.source(access: OwnSource.Access.none), apiOrigin: Self.origin,
                                            requested: false) == .none)
        #expect(store.calls == ["read", "add"], "a source with no token never reads the Keychain")
        #expect(await relaunched.credential(for: source, apiOrigin: Self.origin, requested: false) == .credential(credential))
        #expect(await relaunched.credential(for: source, apiOrigin: Self.origin, requested: false) == .credential(credential))
        #expect(store.calls == ["read", "add", "read"], "read once")
    }

    @Test("a token checked with another provider, number or origin — or bound to plain HTTP — is not handed out")
    func unbound() async throws {
        let store = FakeStore()
        let vault = CredentialVault(store: store)
        let source = Self.source()
        try await vault.keep(SourceCredential(token: Secret("glpat-x"), binding: Self.gitlab), for: source.id)
        // sources.json rewritten — by a plugin, say — to point the same id elsewhere.
        #expect(await vault.credential(for: Self.source(provider: "github", host: "github.com"), apiOrigin: Self.origin,
                                       requested: false) == .unbound(Self.origin))
        #expect(await vault.credential(for: Self.source(remoteID: 49), apiOrigin: Self.origin, requested: false)
                == .unbound(Self.origin))
        // A host map added after the check: the same source, its requests going to another origin.
        #expect(await vault.credential(for: source, apiOrigin: Origin("http://127.0.0.1:9999")!, requested: false)
                == .unbound(Self.origin))
        #expect(await vault.credential(for: source, apiOrigin: Origin("https://gitlab.com")!, requested: false)
                == .unbound(Self.origin))
        let plain = Self.source("plain")
        try await vault.keep(SourceCredential(token: Secret("t"), binding: CredentialBinding(
            provider: "gitlab", remoteID: 48, apiOrigin: Origin("http://gitlab.unicorns.place")!)), for: plain.id)
        #expect(await vault.credential(for: plain, apiOrigin: Origin("http://gitlab.unicorns.place")!, requested: false)
                == .unbound(Origin("http://gitlab.unicorns.place")!))
    }

    @Test("a Keychain that will not be read is remembered: no read nobody asked for touches it again; a press tries once more")
    func denied() async throws {
        let store = FakeStore()
        let vault = CredentialVault(store: store)
        let source = Self.source()
        store.fail(CredentialStoreError("User interaction is not allowed. (-25308)"))
        #expect(await vault.credential(for: source, apiOrigin: Self.origin, requested: false)
                == .unavailable("User interaction is not allowed. (-25308)"))
        #expect(await vault.credential(for: Self.source("another"), apiOrigin: Self.origin, requested: false)
                == .unavailable("User interaction is not allowed. (-25308)"), "one status shared by every source with a token")
        #expect(store.calls == ["read"], "unrequested reads after the failure leave the Keychain alone")
        #expect(await vault.lastFailure == "User interaction is not allowed. (-25308)")
        _ = await vault.credential(for: source, apiOrigin: Self.origin, requested: true)
        #expect(store.calls == ["read", "read"], "a press tries once more")
        store.fail(nil)
        #expect(await vault.credential(for: source, apiOrigin: Self.origin, requested: true) == .none)
        #expect(await vault.lastFailure == nil)
        // Check now, Token…: asked again whatever was remembered.
        store.fail(CredentialStoreError("denied"))
        await vault.tryAgain()
        #expect(await vault.credential(for: source, apiOrigin: Self.origin, requested: false) == .unavailable("denied"))
    }

    @Test("every change reads the item afresh, changes what it read, and writes nothing after a failed read")
    func readChangeWrite() async throws {
        let store = FakeStore()
        let vault = CredentialVault(store: store)
        let first = Self.source("first"), second = Self.source("second")
        try await vault.keep(SourceCredential(token: Secret("one"), binding: Self.gitlab), for: first.id)
        // Another copy of uDeck — or a later version — wrote a token meanwhile: kept, not overwritten from memory.
        let elsewhere = CredentialVault(store: store)
        try await elsewhere.keep(SourceCredential(token: Secret("two"), binding: Self.gitlab), for: second.id)
        try await vault.keep(SourceCredential(token: Secret("three"), binding: Self.gitlab), for: "third")
        #expect(store.calls.suffix(2) == ["read", "update"], "an item there is updated, in one write")
        let fresh = CredentialVault(store: store)
        for (id, token) in [("first", "one"), ("second", "two"), ("third", "three")] {
            #expect(await fresh.credential(for: Self.source(id), apiOrigin: Self.origin, requested: false)
                    == .credential(SourceCredential(token: Secret(token), binding: Self.gitlab)), "\(id)")
        }

        // The fresh read fails: nothing written, so a denial never erases the others' tokens.
        let before = store.data
        let writes = store.calls.filter { $0 != "read" }.count
        store.fail(CredentialStoreError("denied"))
        #expect(await Self.changeError { () async throws(CredentialVault.ChangeError) in try await vault.forget(first.id) } == .unavailable("denied"))
        #expect(store.data == before && store.calls.filter { $0 != "read" }.count == writes)
        #expect(await vault.credential(for: first, apiOrigin: Self.origin, requested: false) == .unavailable("denied"))
        store.fail(nil)

        // A write that fails says so, and what was remembered is read again rather than believed.
        store.failWrites(CredentialStoreError("disk full"))
        #expect(await Self.changeError { () async throws(CredentialVault.ChangeError) in try await vault.forget(first.id) } == .notWritten("disk full"))
        store.failWrites(nil)
        #expect(await vault.credential(for: first, apiOrigin: Self.origin, requested: true)
                == .credential(SourceCredential(token: Secret("one"), binding: Self.gitlab)))
    }

    @Test("the last token forgotten deletes the item; an item this uDeck does not read is never written over")
    func forgettingAndLaterVersions() async throws {
        let store = FakeStore()
        let vault = CredentialVault(store: store)
        try await vault.keep(SourceCredential(token: Secret("one"), binding: Self.gitlab), for: "a")
        try await vault.keep(SourceCredential(token: Secret("two"), binding: Self.gitlab), for: "b")
        try await vault.forget("a")
        #expect(store.calls.last == "update" && store.data != nil)
        try await vault.forget("b")
        #expect(store.calls.last == "delete" && store.data == nil)
        try await vault.forget("b")
        #expect(store.calls.last == "read", "nothing to delete: no item, no call")

        // Whole but for its version: a later uDeck's item.
        let later = Data(#"{"version": 2, "tokens": {"a": {"kind": "pat", "token": "x", "binding": {"provider": "gitlab", "remoteID": 48, "apiOrigin": "https://gitlab.unicorns.place"}}}}"#.utf8)
        let kept = FakeStore(later)
        let reader = CredentialVault(store: kept)
        #expect(await Self.changeError { () async throws(CredentialVault.ChangeError) in try await reader.keep(SourceCredential(token: Secret("t"), binding: Self.gitlab), for: "c") } == .unreadable)
        #expect(kept.data == later && !kept.calls.contains("update") && !kept.calls.contains("add"))
        #expect(await reader.credential(for: Self.source("a"), apiOrigin: Self.origin, requested: false)
                == .unavailable("the item is not one this uDeck reads"))
        // Version 1, and an entry that is not whole — no token, or a kind this uDeck does not know: not written over.
        for entry in [#"{"kind": "pat", "binding": {"provider": "gitlab", "remoteID": 48, "apiOrigin": "https://gitlab.unicorns.place"}}"#,
                      #"{"kind": "pat", "tokn": "x", "binding": {"provider": "gitlab", "remoteID": 48, "apiOrigin": "https://gitlab.unicorns.place"}}"#,
                      #"{"kind": "ssh", "token": "x", "binding": {"provider": "gitlab", "remoteID": 48, "apiOrigin": "https://gitlab.unicorns.place"}}"#] {
            let item = Data(#"{"version": 1, "tokens": {"a": \#(entry)}}"#.utf8)
            let store = FakeStore(item)
            #expect(await Self.changeError { () async throws(CredentialVault.ChangeError) in
                try await CredentialVault(store: store).keep(SourceCredential(token: Secret("t"), binding: Self.gitlab), for: "c")
            } == .unreadable, "\(entry)")
            #expect(store.data == item && !store.calls.contains("update") && !store.calls.contains("delete"), "\(entry)")
        }
        let damaged = FakeStore(Data("not json".utf8))
        #expect(await Self.changeError { () async throws(CredentialVault.ChangeError) in try await CredentialVault(store: damaged).forget("a") } == .unreadable)
        #expect(damaged.data == Data("not json".utf8))
    }

    @Test("an item found damaged by a change is no longer believed from memory: unavailable until asked again")
    func damagedSinceItWasRead() async throws {
        let store = FakeStore()
        let vault = CredentialVault(store: store)
        let source = Self.source()
        let credential = SourceCredential(token: Secret("glpat-a"), binding: Self.gitlab)
        try await vault.keep(credential, for: source.id)
        #expect(await vault.credential(for: source, apiOrigin: Self.origin, requested: false) == .credential(credential))
        store.data = Data("damaged since".utf8)
        #expect(await Self.changeError { () async throws(CredentialVault.ChangeError) in
            try await vault.keep(SourceCredential(token: Secret("b"), binding: Self.gitlab), for: "another")
        } == .unreadable)
        #expect(await vault.credential(for: source, apiOrigin: Self.origin, requested: false)
                == .unavailable("the item is not one this uDeck reads"), "not the token remembered from before")
        #expect(store.data == Data("damaged since".utf8))
    }

    @Test("Sign in's token is kept as access and read back as one; an empty token is not kept")
    func signInsTokenKept() async throws {
        let store = FakeStore()
        let vault = CredentialVault(store: store)
        let signedIn = SourceCredential(kind: .oauth, token: Secret("gloas-access"), binding: Self.gitlab)
        try await vault.keep(signedIn, for: "signed")
        try await vault.keep(SourceCredential(token: Secret("glpat-pasted"), binding: Self.gitlab), for: "pasted")
        let item = try #require(store.data)
        let payload = try #require(CredentialPayload.read(item), "the item it wrote is one it reads")
        #expect(payload.tokens["signed"]?.access == "gloas-access" && payload.tokens["signed"]?.token == nil)
        #expect(payload.tokens["pasted"]?.token == "glpat-pasted" && payload.tokens["pasted"]?.access == nil)
        #expect(await CredentialVault(store: store).credential(for: Self.source("signed"), apiOrigin: Self.origin,
                                                               requested: false) == .credential(signedIn))
        #expect(await Self.changeError { () async throws(CredentialVault.ChangeError) in
            try await vault.keep(SourceCredential(token: Secret(""), binding: Self.gitlab), for: "empty")
        } == .notWritten("an empty token is not kept"))
        #expect(store.data == item)
    }

    @Test("changes made side by side are made one at a time: none lost")
    func sideBySide() async throws {
        let store = FakeStore()
        let vault = CredentialVault(store: store)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0 ..< 24 {
                group.addTask {
                    try await vault.keep(SourceCredential(token: Secret("t\(index)"), binding: Self.gitlab), for: "s\(index)")
                }
            }
            try await group.waitForAll()
        }
        let item = try #require(store.data)
        let payload = try #require(CredentialPayload.read(item))
        #expect(payload.tokens.count == 24)
    }

    // MARK: - The Keychain itself

    @Test("only KeychainCredentialStore.swift imports Security")
    func onlyOneFileImportsSecurity() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources", isDirectory: true)
        var importing: [String] = []
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        for case let file as URL in files where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            if text.split(separator: "\n").contains(where: {
                $0.trimmingCharacters(in: .whitespaces).range(of: #"^(@\w+\s+)*import\s+(\w+\s+)?Security(\.|\s|$)"#,
                                                              options: .regularExpression) != nil
            }) {
                importing.append(file.lastPathComponent)
            }
        }
        #expect(importing == ["KeychainCredentialStore.swift"])
        #expect(KeychainCredentialStore(bundleIdentifier: "place.unicorns.udeck").service == "place.unicorns.udeck.sources")
        #expect(KeychainCredentialStore.account == "tokens" && KeychainCredentialStore.label == "uDeck: tokens for plugin sources")
    }
}
