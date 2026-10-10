import Foundation
import Testing
@testable import UDeckPluginFormat

/// The gate a plugin passes before it runs, with and without a tree its
/// decision is held to — in the format library, which builds on Linux too, so
/// that `udeck-plugin run` and a repository's CI read the same rule.
///
/// A decision held to the version is what every verified plugin, folder of
/// the operator's own and linked working copy has, as before. Code nobody
/// verified is held to its tree: every new content asks again, even when the
/// plugin asks for nothing, and a folder not hashed yet waits.
@Suite("The permission gate, held to a version or to a tree")
struct PermissionGateTests {
    static let tree = String(repeating: "a", count: 40)
    static let other = String(repeating: "b", count: 40)
    static let decided = Date(timeIntervalSince1970: 1_790_000_000)

    static func manifest(_ exec: [String], version: String = "1.0.0") -> PluginManifest {
        PluginManifest(id: PluginIdentifier(rawValue: "p")!, name: "P", version: version, kind: .poll,
                       run: ["./x"], interval: 5, timeout: 2, permissions: PermissionRequest(exec: exec))
    }

    static func grant(granted: [String] = [], denied: [String] = [], version: String = "1.0.0",
                      tree: String? = nil) -> PluginGrant {
        PluginGrant(granted: Set(granted.map(Capability.exec)), denied: Set(denied.map(Capability.exec)),
                    decidedForVersion: version, decidedForTree: tree, decidedAt: decided)
    }

    /// One row: what the manifest asks, the decision, the tree required, and
    /// what the gate says.
    struct Row: Sendable, CustomTestStringConvertible {
        var what: String
        var asks: [String]
        var grant: PluginGrant?
        var requiredTree: String?
        var enabled: Bool = true
        var wanted: LaunchDecision
        var testDescription: String { what }
    }

    static let rows: [Row] = [
        // Held to the version: as it always was.
        Row(what: "version: asks nothing, no decision", asks: [], grant: nil, requiredTree: nil, wanted: .allowed),
        Row(what: "version: asks, no decision", asks: ["ps"], grant: nil, requiredTree: nil,
            wanted: .awaitingDecision(pending: [.exec("ps")])),
        Row(what: "version: allowed for this version", asks: ["ps"], grant: grant(granted: ["ps"]), requiredTree: nil,
            wanted: .allowed),
        Row(what: "version: decided for another version", asks: ["ps"], grant: grant(granted: ["ps"], version: "0.9.0"),
            requiredTree: nil, wanted: .awaitingDecision(pending: [.exec("ps")])),
        Row(what: "version: a tree in the decision changes nothing", asks: ["ps"],
            grant: grant(granted: ["ps"], tree: other), requiredTree: nil, wanted: .allowed),
        Row(what: "version: declined", asks: ["ps"], grant: grant(denied: ["ps"]), requiredTree: nil,
            wanted: .refused(denied: [.exec("ps")])),
        Row(what: "version: switched off", asks: [], grant: nil, requiredTree: nil, enabled: false, wanted: .disabled),
        // Held to the tree.
        Row(what: "tree: asks nothing, no decision — asked whether it may run", asks: [], grant: nil, requiredTree: tree,
            wanted: .awaitingDecision(pending: [])),
        Row(what: "tree: asks nothing, allowed for this tree", asks: [], grant: grant(tree: tree), requiredTree: tree,
            wanted: .allowed),
        Row(what: "tree: asks nothing, allowed for another tree", asks: [], grant: grant(tree: other), requiredTree: tree,
            wanted: .awaitingDecision(pending: [])),
        Row(what: "tree: asks nothing, a decision from before there were trees", asks: [], grant: grant(),
            requiredTree: tree, wanted: .awaitingDecision(pending: [])),
        Row(what: "tree: asks, allowed for this tree", asks: ["ps"], grant: grant(granted: ["ps"], tree: tree),
            requiredTree: tree, wanted: .allowed),
        Row(what: "tree: asks, allowed for another tree of the same version", asks: ["ps"],
            grant: grant(granted: ["ps"], tree: other), requiredTree: tree, wanted: .awaitingDecision(pending: [.exec("ps")])),
        Row(what: "tree: asks, a decision from before there were trees", asks: ["ps"], grant: grant(granted: ["ps"]),
            requiredTree: tree, wanted: .awaitingDecision(pending: [.exec("ps")])),
        Row(what: "tree: this tree, another version", asks: ["ps"], grant: grant(granted: ["ps"], version: "0.9.0", tree: tree),
            requiredTree: tree, wanted: .awaitingDecision(pending: [.exec("ps")])),
        Row(what: "tree: declined for this tree", asks: ["ps"], grant: grant(denied: ["ps"], tree: tree), requiredTree: tree,
            wanted: .refused(denied: [.exec("ps")])),
        Row(what: "tree: one command more than was decided", asks: ["ps", "df"], grant: grant(granted: ["ps"], tree: tree),
            requiredTree: tree, wanted: .awaitingDecision(pending: [.exec("df")])),
        Row(what: "tree: not hashed yet, no decision", asks: [], grant: nil, requiredTree: PermissionGate.treeNotHashedYet,
            wanted: .awaitingDecision(pending: [])),
        Row(what: "tree: not hashed yet, a decision written for an empty tree holds nothing", asks: ["ps"],
            grant: grant(granted: ["ps"], tree: PermissionGate.treeNotHashedYet),
            requiredTree: PermissionGate.treeNotHashedYet, wanted: .awaitingDecision(pending: [.exec("ps")])),
        Row(what: "tree: switched off", asks: [], grant: grant(tree: tree), requiredTree: tree, enabled: false,
            wanted: .disabled),
    ]

    @Test("what the gate says, held to a version or to a tree", arguments: rows)
    func gate(row: Row) {
        let said = PermissionGate.launchDecision(for: Self.manifest(row.asks), grant: row.grant, enabled: row.enabled,
                                                 requiredTree: row.requiredTree)
        #expect(said == row.wanted)
    }

    /// The stored ref is used to ask for more, never to allow: with whatever
    /// tree required, nothing runs that would not run without one.
    @Test("a required tree only ever asks for more")
    func aTreeOnlyAsksMore() {
        let asking: [[String]] = [[], ["ps"], ["ps", "df"]]
        let grants: [PluginGrant?] = [nil, Self.grant(), Self.grant(granted: ["ps"]), Self.grant(granted: ["ps", "df"]),
                                      Self.grant(denied: ["ps"]), Self.grant(granted: ["ps"], tree: Self.tree),
                                      Self.grant(granted: ["ps", "df"], tree: Self.other), Self.grant(tree: Self.tree),
                                      Self.grant(granted: ["ps"], version: "0.9.0", tree: Self.tree)]
        var compared = 0
        for asks in asking {
            for grant in grants {
                for tree in [Self.tree, Self.other, PermissionGate.treeNotHashedYet] {
                    let manifest = Self.manifest(asks)
                    if PermissionGate.launchDecision(for: manifest, grant: grant, enabled: true, requiredTree: tree) == .allowed {
                        #expect(PermissionGate.launchDecision(for: manifest, grant: grant, enabled: true) == .allowed,
                                "\(asks) \(String(describing: grant)) \(tree)")
                    }
                    for command in asks where PermissionGate.mayRun(CardAction(label: "a", run: [command]),
                                                                    requestedBy: manifest, grant: grant, requiredTree: tree) {
                        #expect(PermissionGate.mayRun(CardAction(label: "a", run: [command]), requestedBy: manifest, grant: grant))
                    }
                    compared += 1
                }
            }
        }
        #expect(compared == 81)
    }

    @Test("a card's command, held to a tree: only on a decision for exactly that tree")
    func cardActions() {
        let manifest = Self.manifest(["open"])
        let action = CardAction(label: "Open", run: ["open"])
        #expect(PermissionGate.mayRun(action, requestedBy: manifest, grant: Self.grant(granted: ["open"], tree: Self.tree),
                                      requiredTree: Self.tree))
        #expect(!PermissionGate.mayRun(action, requestedBy: manifest, grant: Self.grant(granted: ["open"], tree: Self.other),
                                       requiredTree: Self.tree), "another tree")
        #expect(!PermissionGate.mayRun(action, requestedBy: manifest, grant: Self.grant(granted: ["open"]),
                                       requiredTree: Self.tree), "a decision from before there were trees")
        #expect(!PermissionGate.mayRun(action, requestedBy: manifest,
                                       grant: Self.grant(granted: ["open"], tree: PermissionGate.treeNotHashedYet),
                                       requiredTree: PermissionGate.treeNotHashedYet), "not hashed yet")
        #expect(PermissionGate.mayRun(action, requestedBy: manifest, grant: Self.grant(granted: ["open"], tree: Self.other)),
                "held to the version, the tree changes nothing")
    }

    /// A `grants.json` written before there were trees reads as it was, its
    /// decisions holding for no tree; one written with a tree keeps it, and
    /// one without writes no key for it.
    @Test("grants.json from before trees reads; a tree is kept, and absent when there is none")
    func grantsFile() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let before = Data(#"""
            {"version": 1, "byPlugin": {"p": {"granted": [{"family": "exec", "scope": "ps"}], "denied": [],
              "decidedForVersion": "1.0.0", "decidedAt": "2026-09-21T14:13:20Z"}}}
            """#.utf8)
        let read = try decoder.decode(PermissionGrants.self, from: before)
        #expect(read.byPlugin["p"]?.granted == [.exec("ps")])
        #expect(read.byPlugin["p"]?.decidedForTree == nil && read.byPlugin["p"]?.decidedForVersion == "1.0.0")
        #expect(read.byPlugin["p"]?.holds(forVersion: "1.0.0", tree: nil) == true)
        #expect(read.byPlugin["p"]?.holds(forVersion: "1.0.0", tree: Self.tree) == false)

        let withTree = PermissionGrants(byPlugin: ["p": Self.grant(granted: ["ps"], tree: Self.tree)])
        let data = try encoder.encode(withTree)
        #expect(try decoder.decode(PermissionGrants.self, from: data) == withTree)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let entry = try #require((json["byPlugin"] as? [String: Any])?["p"] as? [String: Any])
        #expect(entry["decidedForTree"] as? String == Self.tree)
        let without = try encoder.encode(PermissionGrants(byPlugin: ["p": Self.grant(granted: ["ps"])]))
        let plain = try #require((try JSONSerialization.jsonObject(with: without) as? [String: Any])?["byPlugin"] as? [String: Any])
        #expect((plain["p"] as? [String: Any])?.keys.contains("decidedForTree") == false)
    }

    /// `udeck-plugin run` and uDeck's English say why a plugin did not run:
    /// with nothing pending, that it waits to be told whether it may run —
    /// never a sentence that ends on a colon.
    @Test("waiting with nothing pending is said whole")
    func waitingWithNothingPending() {
        let nothing = PluginFailure.Reason.notPermitted(.awaitingDecision(pending: []))
        #expect(nothing.description == "waiting for you to decide whether it may run")
        let something = PluginFailure.Reason.notPermitted(.awaitingDecision(pending: [.exec("ps")]))
        #expect(something.description.hasPrefix("waiting for you to decide about: ") && something.description.hasSuffix("ps"))
    }
}
