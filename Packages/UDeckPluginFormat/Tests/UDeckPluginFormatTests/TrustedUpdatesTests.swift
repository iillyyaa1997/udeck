import Foundation
import Testing
@testable import UDeckPluginFormat

/// Trust in a plugin's updates: an update from the same place asking for
/// nothing more is decided as the copy before it was, and anything else is
/// asked about as before.
@Suite("Trusted updates carry a decision over")
struct TrustedUpdatesTests {
    typealias Gate = PermissionGateTests
    static let origin = "version official default main"
    static let later = Date(timeIntervalSince1970: 1_790_000_600)

    static func trusted(_ granted: [String], version: String = "1.0.0", tree: String? = nil,
                        origin: String? = TrustedUpdatesTests.origin, trust: Bool? = true) -> PluginGrant {
        var grant = Gate.grant(granted: granted, version: version, tree: tree)
        grant.trustsUpdates = trust
        grant.decidedForOrigin = origin
        return grant
    }

    @Test("A new version asking for the same runs on the decision before")
    func sameAsksCarry() throws {
        let update = Gate.manifest(["claude", "codex"], version: "1.1.0")
        let carried = try #require(Self.trusted(["claude", "codex"]).carriedOver(
            to: update, tree: nil, source: "official", origin: Self.origin, at: Self.later))
        #expect(carried.decidedForVersion == "1.1.0")
        #expect(carried.granted == [.exec("claude"), .exec("codex")])
        #expect(carried.trustsUpdates == true)
        #expect(carried.decidedForOrigin == Self.origin)
        #expect(carried.decidedForSource == "official")
        #expect(PermissionGate.launchDecision(for: update, grant: carried, enabled: true, requiredSource: "official") == .allowed)
    }

    @Test("Asking for less keeps only what is asked for")
    func lessIsNotKept() throws {
        let update = Gate.manifest(["claude"], version: "1.1.0")
        let carried = try #require(Self.trusted(["claude", "codex"]).carriedOver(
            to: update, tree: nil, source: nil, origin: Self.origin))
        #expect(carried.granted == [.exec("claude")])
    }

    @Test("Asking for more is asked about")
    func moreAsks() {
        let update = Gate.manifest(["claude", "codex", "rm"], version: "1.1.0")
        #expect(Self.trusted(["claude", "codex"]).carriedOver(to: update, tree: nil, source: nil, origin: Self.origin) == nil)
        #expect(PermissionGate.launchDecision(for: update, grant: Self.trusted(["claude", "codex"]), enabled: true,
                                              requiredSource: nil)
                == .awaitingDecision(pending: [.exec("claude"), .exec("codex"), .exec("rm")]))
    }

    @Test("No trust, trust in another place, a refusal: nothing carried")
    func nothingCarried() {
        let update = Gate.manifest(["claude"], version: "1.1.0")
        #expect(Self.trusted(["claude"], trust: nil).carriedOver(to: update, tree: nil, source: nil, origin: Self.origin) == nil)
        #expect(Self.trusted(["claude"], trust: false).carriedOver(to: update, tree: nil, source: nil, origin: Self.origin) == nil)
        #expect(Self.trusted(["claude"]).carriedOver(to: update, tree: nil, source: nil,
                                                    origin: "version mine branch next") == nil)
        #expect(Self.trusted(["claude"], origin: nil).carriedOver(to: update, tree: nil, source: nil, origin: Self.origin) == nil)
        #expect(Self.trusted(["claude"]).carriedOver(to: update, tree: nil, source: nil, origin: nil) == nil)
        var refused = Self.trusted(["claude"])
        refused.denied = [.exec("codex")]
        #expect(refused.carriedOver(to: update, tree: nil, source: nil, origin: Self.origin) == nil)
    }

    @Test("A decision that holds already is not rewritten")
    func holdingIsKept() {
        let same = Gate.manifest(["claude"])
        #expect(Self.trusted(["claude"]).carriedOver(to: same, tree: nil, source: nil, origin: Self.origin) == nil)
    }

    @Test("Held to its tree: new content carries, a folder not hashed yet waits")
    func treeHeld() throws {
        let tree = "tree mine branch next"
        let manifest = Gate.manifest(["claude"])
        let grant = Self.trusted(["claude"], tree: Gate.tree, origin: tree)
        let carried = try #require(grant.carriedOver(to: manifest, tree: Gate.other, source: nil, origin: tree))
        #expect(carried.decidedForTree == Gate.other)
        #expect(PermissionGate.launchDecision(for: manifest, grant: carried, enabled: true, requiredTree: Gate.other,
                                              requiredSource: nil) == .allowed)
        #expect(grant.carriedOver(to: manifest, tree: PermissionGate.treeNotHashedYet, source: nil, origin: tree) == nil)
    }

    @Test("Trust survives being written and read back; a decision from before reads as no trust")
    func codable() throws {
        let grant = Self.trusted(["claude"])
        let back = try JSONDecoder().decode(PluginGrant.self, from: JSONEncoder().encode(grant))
        #expect(back == grant)
        let old = #"{"granted":[],"denied":[],"decidedForVersion":"1.0.0","decidedAt":0}"#
        let read = try JSONDecoder().decode(PluginGrant.self, from: Data(old.utf8))
        #expect(read.trustsUpdates == nil)
        #expect(!read.trusts(origin: Self.origin))
    }
}
