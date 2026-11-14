import Foundation
import Testing
@testable import UDeckCore
import UDeckPluginFormat
import UDeckPluginFormatFixtures

/// A source the operator trusted (stage 4, S4-08 to S4-10): where a copy of its
/// default branch stands, what its permission decision is held to — its version,
/// and the source it was made for — and what happens to that decision across a
/// swap and an update by itself.
@Suite("Trusted sources")
struct TrustTests {
    static let tree = String(repeating: "a", count: 40)
    static let commit = String(repeating: "c", count: 40)
    static let at = Date(timeIntervalSince1970: 1_790_000_000)
    static let team = "github.com-team-plugins-8e1f0a2c"
    static let other = "gitlab.example.test-team-1b2c3d4e"

    static func record(source: String = team, ref: PluginRef = PluginRef(name: "main"), tree: String = tree) -> InstalledRecord {
        InstalledRecord(source: source, repository: RepositoryAddress(path: "someone/team-plugins"), ref: ref,
                        commit: commit, tree: tree, version: "1.0.0", installedAt: at, pinned: false,
                        verification: PluginVerification(status: .unverified, by: nil, checkedAgainst: nil, checkedAt: at),
                        previous: nil)
    }

    static func manifest(asks permissions: String = #"{ "exec": ["uname"] }"#, version: String = "1.0.0") throws -> PluginManifest {
        try JSONDecoder().decode(PluginManifest.self, from: Data(FakeRepository.manifest(
            version: version, permissions: permissions).utf8))
    }

    // MARK: - What sources.json says

    @Test("Trust writes trustedAt and Stop trusting clears it; the trusted set is the sources that have it, read back")
    func trustedAtOnDisk() throws {
        let udeck = TemporaryDirectory()
        try FileManager.default.createDirectory(at: udeck.url, withIntermediateDirectories: true)
        let store = SourceStore(paths: udeck.paths)
        let added = try store.modify { list -> OwnSource in
            guard case .success(let source) = list.add(provider: "github", host: "github.com", path: "someone/team-plugins",
                                                       remoteID: 900_000_101, at: Self.at) else { throw CocoaError(.fileWriteUnknown) }
            _ = list.add(provider: "gitlab", host: "gitlab.example.test", path: "group/sub/team", remoteID: 9, at: Self.at)
            return source
        }
        #expect(try store.load().get().trusted.isEmpty)
        let trustedAt = Date(timeIntervalSince1970: 1_790_000_000.7)
        #expect(try store.modify { $0.setTrusted(added.id, at: trustedAt) })
        let read = try store.load().get()
        #expect(read.trusted == [added.id])
        #expect(read.sources.first { $0.id == added.id }?.trustedAt == Date(timeIntervalSince1970: 1_790_000_000))
        #expect(try store.modify { $0.setTrusted(added.id, at: nil) })
        #expect(try store.load().get().trusted.isEmpty)
        #expect(try !store.modify { $0.setTrusted("github.com-nothing-00000000", at: Self.at) }, "a source not listed")
        #expect(SourceList().trusted.isEmpty)
    }

    // MARK: - Where a copy stands

    /// (source, ref, the tree as installed, trusted sources, standing)
    static let standings: [(String, PluginRef, Bool, Set<String>, PluginStanding)] = [
        (team, PluginRef(name: "main"), true, [team], .trusted),
        (team, PluginRef(name: "main"), true, [], .unverified),
        (team, PluginRef(name: "main"), true, [other], .unverified),
        (team, PluginRef(name: "main"), false, [team], .modifiedLocally),
        (team, .branch("fix"), true, [team], .unverified),
        (team, .pullRequest(3), true, [team], .unverified),
        ("official", PluginRef(name: "main"), true, ["official"], .verified),
        ("official", .branch("fix"), true, ["official"], .unverified),
    ]

    @Test("a trusted source's default branch, exactly as installed, stands trusted; nothing else does",
          arguments: 0..<standings.count)
    func standing(row: Int) {
        let (source, ref, same, trusted, wanted) = Self.standings[row]
        let record = Self.record(source: source, ref: ref)
        let onDisk = same ? Self.tree : String(repeating: "b", count: 40)
        #expect(PluginStanding.of(record: record, folderExists: true, treeOnDisk: onDisk, trusted: trusted) == wanted, "\(row)")
        #expect(PluginStanding.of(record: record, folderExists: false, treeOnDisk: nil, trusted: trusted) == .missing)
        let found = record.verification(treeOnDisk: onDisk, headCommit: "h", now: Self.at, trusted: trusted)
        switch wanted {
        case .trusted: #expect(found.status == .trusted && found.by == source, "\(row)")
        case .verified: #expect(found.status == .verified && found.by == "official", "\(row)")
        case .modifiedLocally: #expect(found.status == .modified && found.by == nil, "\(row)")
        default: #expect(found.status == .unverified && found.by == nil, "\(row)")
        }
    }

    @Test("`trusted` is written and read back, and a uDeck that knows no such word reads it as modified")
    func statusOnDisk() throws {
        var record = Self.record()
        record.verification = PluginVerification(status: .trusted, by: Self.team, checkedAgainst: Self.commit, checkedAt: Self.at)
        let plugins = InstalledPlugins(plugins: ["team-ping": record])
        let data = try JSONFileStore<InstalledPlugins>.encoder.encode(plugins)
        #expect(try JSONFileStore<InstalledPlugins>.decoder.decode(InstalledPlugins.self, from: data) == plugins)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let verification = try #require(((json["plugins"] as? [String: Any])?["team-ping"] as? [String: Any])?["verification"]
                                        as? [String: Any])
        #expect(verification["status"] as? String == "trusted" && verification["by"] as? String == Self.team)
    }

    // MARK: - What the decision is held to

    /// (record, linked, records readable, trusted sources, basis, required source)
    static let bases: [(InstalledRecord?, Bool, Bool, Set<String>, ConsentBasis, String?)] = [
        (record(), false, true, [team], .version, team),
        (record(), false, true, [], .tree, nil),
        (record(ref: .branch("fix")), false, true, [team], .tree, nil),
        (record(), false, false, [team], .tree, nil),
        (record(), true, true, [team], .version, nil),
        (record(source: "official"), false, true, [], .version, "official"),
        (nil, false, true, [team], .version, nil),
    ]

    @Test("a trusted source's default branch is held to its version, and to that source; anything else as before",
          arguments: 0..<bases.count)
    func basis(row: Int) {
        let (record, linked, readable, trusted, wanted, source) = Self.bases[row]
        let basis = ConsentBasis.of(record, linked: linked, recordsReadable: readable, trusted: trusted)
        #expect(basis == wanted, "\(row)")
        #expect(basis.requiredSource(record, linked: linked) == source, "\(row)")
    }

    /// S4-09: a decision made for the official uptime 1.0.0 is no decision
    /// about a trusted source's uptime 1.0.0 — another plugin under the same
    /// id and version.
    @Test("the gate holds a decision held to the version to the source it was made for")
    func gateHoldsTheSource() throws {
        let manifest = try Self.manifest()
        func grant(_ source: String?) -> PluginGrant {
            PluginGrant(granted: [.exec("uname")], decidedForVersion: "1.0.0", decidedForSource: source, decidedAt: Self.at)
        }
        let decide = { (grant: PluginGrant?, source: String?) in
            PermissionGate.launchDecision(for: manifest, grant: grant, enabled: true, requiredSource: source)
        }
        #expect(decide(grant(Self.team), Self.team) == .allowed)
        #expect(decide(grant("official"), Self.team) == .awaitingDecision(pending: [.exec("uname")]))
        #expect(decide(grant(Self.other), Self.team) == .awaitingDecision(pending: [.exec("uname")]))
        #expect(decide(grant(Self.team), "official") == .awaitingDecision(pending: [.exec("uname")]))
        // The format package's name for the official source is installed.json's.
        #expect(PluginGrant.officialSource == InstalledPlugins.officialSource)
        // A decision written before there were sources — or by 0.7.0 — is the official source's.
        #expect(decide(grant(nil), "official") == .allowed)
        #expect(decide(grant(nil), Self.team) == .awaitingDecision(pending: [.exec("uname")]))
        // No source required — a folder of one's own, a link, `udeck-plugin run` — and the version is enough.
        #expect(decide(grant(Self.team), nil) == .allowed)
        // A trusted copy that asks for nothing runs with no decision at all, as a verified one does.
        let asksNothing = try Self.manifest(asks: "{}")
        #expect(PermissionGate.launchDecision(for: asksNothing, grant: nil, enabled: true, requiredSource: Self.team) == .allowed)
        // A card's button the same way.
        let action = CardAction(label: "Run", run: ["uname"])
        #expect(PermissionGate.mayRun(action, requestedBy: manifest, grant: grant(Self.team), requiredSource: Self.team))
        #expect(!PermissionGate.mayRun(action, requestedBy: manifest, grant: grant("official"), requiredSource: Self.team))
        #expect(!PermissionGate.mayRun(action, requestedBy: manifest, grant: grant(nil), requiredSource: Self.team))
    }

    @Test("a decision 0.7.0 wrote reads as the official source's; the source is written beside the version")
    func grantsOnDisk() throws {
        let written = Data(#"""
        {"version": 1, "byPlugin": {"uptime": {"granted": [{"family": "exec", "scope": "sysctl"}], "denied": [],
          "decidedForVersion": "1.0.0", "decidedAt": "2026-09-01T10:00:00Z"}}}
        """#.utf8)
        let old = try JSONFileStore<PermissionGrants>.decoder.decode(PermissionGrants.self, from: written)
        let uptime = try #require(old.byPlugin["uptime"])
        #expect(uptime.decidedForSource == nil)
        #expect(uptime.holds(forVersion: "1.0.0", tree: nil, source: "official"))
        #expect(!uptime.holds(forVersion: "1.0.0", tree: nil, source: Self.team))
        var trusted = old
        trusted.byPlugin["team-ping"] = PluginGrant(granted: [.exec("uname")], decidedForVersion: "1.0.0",
                                                    decidedForSource: Self.team, decidedAt: Self.at)
        let data = try JSONFileStore<PermissionGrants>.encoder.encode(trusted)
        #expect(try JSONFileStore<PermissionGrants>.decoder.decode(PermissionGrants.self, from: data) == trusted)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let ping = try #require((json["byPlugin"] as? [String: Any])?["team-ping"] as? [String: Any])
        #expect(ping["decidedForSource"] as? String == Self.team)
    }

    @Test("Allow and Decline record the source of the copy they were for, and Allow holds only that source's decision")
    func decideRecordsTheSource() throws {
        let manifest = try Self.manifest()
        guard case .record(let allowed) = ShownPlace.decide(allow: true, shown: [.exec("uname")], shownTree: nil,
                                                             manifest: manifest, grant: nil, requiredTree: nil,
                                                             requiredSource: Self.team, source: Self.team,
                                                             shownSource: Self.team, at: Self.at) else {
            Issue.record("Allow recorded nothing")
            return
        }
        #expect(allowed.decidedForSource == Self.team && allowed.granted == [.exec("uname")])
        guard case .record(let declined) = ShownPlace.decide(allow: false, shown: [.exec("uname")], shownTree: nil,
                                                              manifest: manifest, grant: nil, requiredTree: nil,
                                                              requiredSource: nil, source: nil, shownSource: nil,
                                                              at: Self.at) else {
            Issue.record("Decline recorded nothing")
            return
        }
        #expect(declined.decidedForSource == nil, "a folder uDeck has no record of")
        // Another source's copy put in the place while the card was up — the same id, version and request — is not
        // decided on a card about the first one, Allow or Decline.
        for allow in [true, false] {
            #expect(ShownPlace.decide(allow: allow, shown: [.exec("uname")], shownTree: nil, manifest: manifest, grant: nil,
                                      requiredTree: nil, requiredSource: Self.team, source: Self.team,
                                      shownSource: Self.other, at: Self.at) == .nothing)
            #expect(ShownPlace.decide(allow: allow, shown: [.exec("uname")], shownTree: nil, manifest: manifest, grant: nil,
                                      requiredTree: nil, requiredSource: Self.team, source: Self.team,
                                      shownSource: nil, at: Self.at) == .nothing)
        }
        // The official source's decision holds nothing for the trusted copy: Allow needs what it asks shown.
        let official = PluginGrant(granted: [.exec("uname")], decidedForVersion: "1.0.0", decidedForSource: "official")
        #expect(!ShownPlace.allows(shown: [], requested: [.exec("uname")], grant: official, version: "1.0.0",
                                   requiredSource: Self.team))
        #expect(ShownPlace.allows(shown: [], requested: [.exec("uname")], grant: official, version: "1.0.0",
                                  requiredSource: "official"))
    }

    // MARK: - Across a swap, and by itself

    @Test("a decision is carried between two copies of one trusted source, keeping the source it was made for")
    func carriedWithinASource() throws {
        let grant = PluginGrant(granted: [.exec("uname")], decidedForVersion: "1.0.0", decidedForSource: Self.team,
                                decidedAt: Self.at)
        let old = GrantCarry.Copy(version: "1.0.0", asks: [.exec("uname")], guarantee: .trusted(source: Self.team))
        let new = GrantCarry.Copy(version: "1.1.0", asks: [.exec("uname")], guarantee: .trusted(source: Self.team))
        let carried = try #require(GrantCarry.after(grant, old: old, new: new))
        #expect(carried == PluginGrant(granted: [.exec("uname")], decidedForVersion: "1.1.0", decidedForSource: Self.team,
                                       decidedAt: Self.at))
        // And the gate runs the new version on it, for that source only.
        let manifest = try Self.manifest(version: "1.1.0")
        #expect(PermissionGate.launchDecision(for: manifest, grant: carried, enabled: true, requiredSource: Self.team) == .allowed)
        // A decision left from another source's copy of the same id is not this source's to advance: the other copy
        // put back later must not find it carried to a version nobody decided for.
        let anothers = PluginGrant(granted: [.exec("uname")], decidedForVersion: "1.0.0", decidedForSource: Self.other,
                                   decidedAt: Self.at)
        #expect(GrantCarry.after(anothers, old: old, new: new) == anothers)
        let officials = PluginGrant(granted: [.exec("uname")], decidedForVersion: "1.0.0", decidedAt: Self.at)
        #expect(GrantCarry.after(officials, old: old, new: new) == officials, "an absent source is the official one's")
        let verifiedOld = GrantCarry.Copy(version: "1.0.0", asks: [.exec("uname")], guarantee: .verified)
        let verifiedNew = GrantCarry.Copy(version: "1.1.0", asks: [.exec("uname")], guarantee: .verified)
        #expect(GrantCarry.after(officials, old: verifiedOld, new: verifiedNew)?.decidedForVersion == "1.1.0")
        #expect(GrantCarry.after(grant, old: verifiedOld, new: verifiedNew) == grant, "a trusted source's decision, verified copies")
        #expect(GrantCarry.Copy.guarantee(of: .trusted, record: Self.record()) == .trusted(source: Self.team))
        #expect(GrantCarry.Copy.guarantee(of: .verified, record: Self.record(source: "official")) == .verified)
        #expect(GrantCarry.Copy.guarantee(of: .unverified, record: Self.record()) == nil)
        #expect(GrantCarry.Copy.guarantee(of: nil, record: Self.record()) == nil)
    }

    @Test("a trusted copy updates itself as a verified one does; code nobody verified does not")
    func trustedUpdatesItself() {
        func plugin(_ standing: PluginStanding) -> AutoUpdate.Plugin {
            AutoUpdate.Plugin(record: Self.record(), offer: .newer(version: "1.1.0"), standing: standing, asksNow: [.exec("uname")],
                              asksAtHead: [.exec("uname")], place: .deleted)
        }
        #expect(AutoUpdate.verdict(plugin(.trusted), switchedOn: true, busy: false) == .update(version: "1.1.0"))
        #expect(AutoUpdate.verdict(plugin(.verified), switchedOn: true, busy: false) == .update(version: "1.1.0"))
        #expect(AutoUpdate.verdict(plugin(.unverified), switchedOn: true, busy: false) == .not(.notVerified))
        #expect(AutoUpdate.verdict(plugin(.trusted), switchedOn: false, busy: false) == .not(.switchedOff))
        var asksMore = plugin(.trusted)
        asksMore.asksAtHead = [.exec("uname"), .exec("ps")]
        #expect(AutoUpdate.verdict(asksMore, switchedOn: true, busy: false) == .not(.asksDifferently))
    }

    // MARK: - The plugins folder read again

    @Test("hashing the folders: a trusted source's copy stands and is recorded trusted, and unverified once it is not")
    func reverification() {
        let plugins = [DiscoveredPlugin(directory: URL(fileURLWithPath: "/u/plugins/team-ping"), folderName: "team-ping",
                                        manifest: nil, executable: nil, problems: [])]
        let installed = InstalledPlugins(plugins: ["team-ping": Self.record()])
        let heads: [String: Reverification.Head] = [Self.team: .read(Self.commit)]
        let trusted = Reverification.of(plugins, installed: installed, trees: ["team-ping": Self.tree], heads: heads,
                                        trusted: [Self.team], now: Self.at)
        #expect(trusted.standings["team-ping"] == .trusted)
        let written = trusted.records?.plugins["team-ping"]?.verification
        #expect(written?.status == .trusted && written?.by == Self.team && written?.checkedAgainst == Self.commit)
        // No longer trusted: unverified at once, and recorded so.
        let after = InstalledPlugins(plugins: ["team-ping": trusted.records?.plugins["team-ping"] ?? Self.record()])
        let untrusted = Reverification.of(plugins, installed: after, trees: ["team-ping": Self.tree], heads: heads,
                                          trusted: [], now: Self.at)
        #expect(untrusted.standings["team-ping"] == .unverified)
        #expect(untrusted.records?.plugins["team-ping"]?.verification.status == .unverified)
    }
}
