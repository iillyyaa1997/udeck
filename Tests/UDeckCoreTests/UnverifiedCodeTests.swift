import Foundation
import Testing
@testable import UDeckCore
import UDeckPluginFormatFixtures

/// Code nobody verified — a branch, a pull request — in the records and in
/// the decision: what `installed.json` says of it and reads back, where it
/// stands, and what its permission decision is held to.
@Suite("Code nobody verified")
struct UnverifiedCodeTests {
    static let tree = String(repeating: "a", count: 40)
    static let commit = String(repeating: "c", count: 40)
    static let at = Date(timeIntervalSince1970: 1_790_000_000)

    static func record(source: String = "official", ref: PluginRef, tree: String = tree) -> InstalledRecord {
        InstalledRecord(source: source, repository: .official, ref: ref, commit: commit, tree: tree, version: "1.0.0",
                        installedAt: at, pinned: false,
                        verification: PluginVerification(status: .verified, by: "official", checkedAgainst: nil,
                                                         checkedAt: at),
                        previous: nil)
    }

    // MARK: - installed.json

    /// A file written by 0.6 reads as it was; a status this uDeck does not
    /// know — a later one's `trusted` — reads as `modified` rather than
    /// making the whole file broken, which would stop every install, update
    /// and removal.
    @Test("installed.json from 0.6 reads; an unknown status reads as modified, the file whole")
    func oldAndLaterFiles() throws {
        func file(status: String, previous: String = "null") -> Data {
            Data(#"""
                {"version": 1, "plugins": {"uptime": {"source": "official",
                  "repository": {"provider": "github", "host": "github.com", "path": "iillyyaa1997/udeck-plugins"},
                  "ref": {"kind": "default", "name": "main"}, "commit": "c", "tree": "t", "version": "1.0.0",
                  "installedAt": "2026-09-21T14:13:20Z", "pinned": false,
                  "verification": {"status": "\#(status)", "by": "official", "checkedAgainst": null,
                                   "checkedAt": "2026-09-21T14:13:20Z"},
                  "previous": \#(previous)},
                  "cpu": {"source": "official",
                  "repository": {"provider": "github", "host": "github.com", "path": "iillyyaa1997/udeck-plugins"},
                  "ref": {"kind": "commit", "name": null}, "commit": "c", "tree": "t", "version": "1.0.0",
                  "installedAt": "2026-09-21T14:13:20Z", "pinned": false,
                  "verification": {"status": "modified", "by": null, "checkedAgainst": null,
                                   "checkedAt": "2026-09-21T14:13:20Z"},
                  "previous": null}}}
                """#.utf8)
        }
        let decoder = JSONFileStore<InstalledPlugins>.decoder
        for (status, read) in [("verified", PluginVerification.Status.verified), ("modified", .modified),
                               ("unverified", .unverified), ("trusted", .modified), ("anything else", .modified)] {
            let plugins = try decoder.decode(InstalledPlugins.self, from: file(status: status))
            #expect(plugins.plugins["uptime"]?.verification.status == read, "\(status)")
            #expect(plugins.plugins["cpu"]?.ref == PluginRef(kind: "commit", name: nil), "a ref's kind is read as written")
        }
        let previous = #"{"ref": {"kind": "default", "name": "main"}, "commit": "p", "tree": "q", "version": "0.9.0"}"#
        let old = try decoder.decode(InstalledPlugins.self, from: file(status: "verified", previous: previous))
        #expect(old.plugins["uptime"]?.previous == PreviousCopy(ref: PluginRef(name: "main"), commit: "p", tree: "q",
                                                                version: "0.9.0"))
        #expect(old.plugins["uptime"]?.previous?.repository == nil)
        #expect(old.plugins["uptime"]?.previous?.origin(source: .official)
                == PluginOrigin(repository: .official, ref: PluginRef(name: "main")),
                "a copy recorded without a repository came from the source's own")
    }

    @Test("a branch's and a pull request's record is written as it is read: ref, status, previous's repository")
    func roundTrip() throws {
        var record = Self.record(ref: .pullRequest(3))
        record.verification = PluginVerification(status: .unverified, by: nil, checkedAgainst: Self.commit, checkedAt: Self.at)
        record.previous = PreviousCopy(ref: .branch("feature/x"), commit: Self.commit, tree: Self.tree, version: "0.9.0",
                                       repository: RepositoryAddress(path: "someone/udeck-plugins"))
        let plugins = InstalledPlugins(plugins: ["uptime": record])
        let data = try JSONFileStore<InstalledPlugins>.encoder.encode(plugins)
        #expect(try JSONFileStore<InstalledPlugins>.decoder.decode(InstalledPlugins.self, from: data) == plugins)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let uptime = try #require((json["plugins"] as? [String: Any])?["uptime"] as? [String: Any])
        #expect(uptime["ref"] as? [String: String] == ["kind": "pr", "name": "3"])
        #expect((uptime["verification"] as? [String: Any])?["status"] as? String == "unverified")
        let previous = try #require(uptime["previous"] as? [String: Any])
        #expect(previous["ref"] as? [String: String] == ["kind": "branch", "name": "feature/x"])
        #expect((previous["repository"] as? [String: String])?["path"] == "someone/udeck-plugins")
        #expect(PluginRef.pullRequest(3).pullRequestNumber == 3 && PluginRef.branch("x").pullRequestNumber == nil)
        #expect(PluginRef(kind: "pr", name: "x").pullRequestNumber == nil && PluginRef(kind: "pr", name: "0").pullRequestNumber == nil)
        #expect(PluginRef.defaultBranch("main").isDefault && !PluginRef.branch("main").isDefault)
    }

    // MARK: - Where it stands

    /// Verified only from the official source's default branch and exactly
    /// as installed; the same tree from anywhere else is unverified — never
    /// "modified locally", which it is not — and a changed folder is
    /// modified, whatever it was.
    @Test("verified, unverified, modified: by the source, the ref and the tree on disk",
          arguments: [
              ("official", PluginRef(kind: "default", name: "main"), true, PluginVerification.Status.verified),
              ("official", PluginRef(kind: "default", name: "main"), false, .modified),
              ("official", PluginRef(kind: "branch", name: "x"), true, .unverified),
              ("official", PluginRef(kind: "branch", name: "x"), false, .modified),
              ("official", PluginRef(kind: "pr", name: "3"), true, .unverified),
              ("official", PluginRef(kind: "pr", name: "3"), false, .modified),
              ("official", PluginRef(kind: "commit", name: nil), true, .unverified),
              ("someone", PluginRef(kind: "default", name: "main"), true, .unverified),
          ])
    func standing(source: String, ref: PluginRef, same: Bool, wanted: PluginVerification.Status) {
        let record = Self.record(source: source, ref: ref)
        let onDisk = same ? Self.tree : String(repeating: "b", count: 40)
        let found = record.verification(treeOnDisk: onDisk, headCommit: "h", now: Self.at)
        #expect(found.status == wanted)
        #expect(found.by == (wanted == .verified ? "official" : nil))
        let standing = PluginStanding.of(record: record, folderExists: true, treeOnDisk: onDisk)
        switch wanted {
        case .verified: #expect(standing == .verified)
        case .unverified: #expect(standing == .unverified)
        case .modified: #expect(standing == .modifiedLocally)
        }
        #expect(standing.offersReinstall(readsCatalogue: true) == (wanted == .modified))
        #expect(PluginStanding.of(record: record, folderExists: false, treeOnDisk: nil) == .missing)
    }

    /// The hashing of the plugins folder says the same, and writes back a
    /// status the file had wrong — 0.6 wrote `modified` for what was never
    /// installed from a branch, and a hand-edited file can say anything.
    @Test("hashing the folders: a pull request's copy stands unverified, and its record is written so")
    func reverification() {
        let plugins = [DiscoveredPlugin(directory: URL(fileURLWithPath: "/u/plugins/uptime"), folderName: "uptime",
                                        manifest: nil, executable: nil, problems: [])]
        var record = Self.record(ref: .pullRequest(3))
        record.verification = PluginVerification(status: .verified, by: "official", checkedAgainst: "h", checkedAt: Self.at)
        let installed = InstalledPlugins(plugins: ["uptime": record])
        let found = Reverification.of(plugins, installed: installed, trees: ["uptime": Self.tree], head: .read("h"), now: Self.at)
        #expect(found.standings == ["uptime": .unverified])
        #expect(found.records?.plugins["uptime"]?.verification.status == .unverified)
        #expect(found.records?.plugins["uptime"]?.verification.by == nil)
        let changed = Reverification.of(plugins, installed: installed, trees: ["uptime": "0"], head: .read("h"), now: Self.at)
        #expect(changed.standings == ["uptime": .modifiedLocally])
    }

    // MARK: - What the decision is held to

    @Test("held to the tree: whatever is not the official default branch's, and is not a link")
    func basis() {
        #expect(ConsentBasis.of(nil, linked: false, recordsReadable: true) == .version, "a folder of the operator's own")
        #expect(ConsentBasis.of(nil, linked: true, recordsReadable: true) == .version, "a linked working copy")
        #expect(ConsentBasis.of(Self.record(ref: .defaultBranch("main")), linked: false, recordsReadable: true) == .version, "verified")
        #expect(ConsentBasis.of(Self.record(ref: .defaultBranch("main"), tree: "changed"), linked: false, recordsReadable: true) == .version,
                "a verified copy changed on disk is still held to its version, as before")
        #expect(ConsentBasis.of(Self.record(ref: .branch("x")), linked: false, recordsReadable: true) == .tree)
        #expect(ConsentBasis.of(Self.record(ref: .pullRequest(3)), linked: false, recordsReadable: true) == .tree)
        #expect(ConsentBasis.of(Self.record(ref: PluginRef(kind: "commit", name: nil)), linked: false, recordsReadable: true) == .tree,
                "a kind this uDeck does not know asks for more, never less")
        #expect(ConsentBasis.of(Self.record(source: "someone", ref: .defaultBranch("main")), linked: false, recordsReadable: true) == .tree)
        #expect(ConsentBasis.of(Self.record(ref: .pullRequest(3)), linked: true, recordsReadable: true) == .version,
                "a link is the operator's working copy, whatever record is left at its id")
        // While installed.json cannot be read, nothing says where a copy came
        // from: every folder but a link is held to its tree.
        #expect(ConsentBasis.of(nil, linked: false, recordsReadable: false) == .tree)
        #expect(ConsentBasis.of(Self.record(ref: .defaultBranch("main")), linked: false, recordsReadable: false) == .tree,
                "a record read before the file broke says nothing now")
        #expect(ConsentBasis.of(nil, linked: true, recordsReadable: false) == .version, "a link is still a link")
        // The tree the gate requires.
        #expect(ConsentBasis.version.requiredTree(hashed: Self.tree) == nil)
        #expect(ConsentBasis.version.requiredTree(hashed: nil) == nil)
        #expect(ConsentBasis.tree.requiredTree(hashed: Self.tree) == Self.tree)
        #expect(ConsentBasis.tree.requiredTree(hashed: nil) == PermissionGate.treeNotHashedYet)
    }

    /// A poll plugin `pr`, asking for nothing.
    static func pollPlugin(id: String = "pr", directory: String = "/u/plugins/pr",
                           linked: Bool = false) throws -> DiscoveredPlugin {
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: Data("""
            { "id": "\(id)", "name": "\(id)", "version": "1.0.0", "api": 1, "kind": "poll",
              "run": ["./run.sh"], "interval": 5, "timeout": 2 }
            """.utf8))
        return DiscoveredPlugin(directory: URL(fileURLWithPath: directory), folderName: id, manifest: manifest,
                                executable: URL(fileURLWithPath: "\(directory)/run.sh"), problems: [],
                                linkedAt: linked ? URL(fileURLWithPath: "/u/plugins/\(id)") : nil)
    }

    /// The loop that runs a plugin starts only on a decision for exactly the
    /// tree on disk — and stops when the tree is another, or not known.
    @Test("a poll loop for code held to its tree: only on a decision for that tree")
    func pollLoops() throws {
        let plugin = try Self.pollPlugin()
        let manifest = try #require(plugin.manifest)
        let id = manifest.id
        func wanted(_ grants: PermissionGrants, tree: String?) -> Set<String> {
            Set(PollLoops.wanted([plugin], placed: [id], grants: grants, settings: PluginSettings(), polling: true,
                                 isQuiet: { _ in false }, requiredTree: { _ in tree }).keys)
        }
        #expect(wanted(PermissionGrants(), tree: nil) == ["pr"], "held to its version, it asks for nothing")
        #expect(wanted(PermissionGrants(), tree: Self.tree).isEmpty, "held to its tree, it is asked about first")
        var grants = PermissionGrants()
        grants[id] = PluginGrant(decidedForVersion: "1.0.0", decidedForTree: Self.tree, decidedAt: Self.at)
        #expect(wanted(grants, tree: Self.tree) == ["pr"])
        #expect(wanted(grants, tree: String(repeating: "b", count: 40)).isEmpty, "new content")
        #expect(wanted(grants, tree: PermissionGate.treeNotHashedYet).isEmpty, "not hashed yet")
    }

    /// A change in the plugins folder that hashes to the same tree again
    /// stops no loop: the loop and the card go by the tree last hashed, and
    /// only a run that would start before the hashing lands is skipped —
    /// skipped, never failed. Another tree stops the loop.
    @Test("a hashing that finds the same tree keeps the loop; another tree stops it; runs meanwhile are skipped")
    func hashingAgain() throws {
        let plugin = try Self.pollPlugin()
        let manifest = try #require(plugin.manifest)
        let id = manifest.id
        var trees = HashedTrees(trees: ["pr": Self.tree])
        var grants = PermissionGrants()
        grants[id] = PluginGrant(decidedForVersion: "1.0.0", decidedForTree: Self.tree, decidedAt: Self.at)
        func wanted() -> [String: PollLoop] {
            PollLoops.wanted([plugin], placed: [id], grants: grants, settings: PluginSettings(), polling: true,
                             isQuiet: { _ in false }, requiredTree: { trees.lastHashed($0.rawValue, basis: .tree) })
        }
        func allowedNow() -> Bool {
            PermissionGate.launchDecision(for: manifest, grant: grants[id], enabled: true,
                                          requiredTree: trees.now("pr", basis: .tree)).isAllowed
        }
        let running = wanted()
        #expect(Set(running.keys) == ["pr"])
        #expect(!trees.skipsRun("pr", basis: .tree) && allowedNow())

        trees.mayHaveChanged()
        #expect(PollLoops.plan(running: running, wanted: wanted()) == PollLoops.Plan(),
                "until it is hashed again, the loop and the card stay as they were")
        #expect(trees.skipsRun("pr", basis: .tree) && !allowedNow(), "a run before the hashing lands is skipped")
        #expect(!trees.skipsRun("pr", basis: .version) && trees.now("pr", basis: .version) == nil,
                "a decision held to its version is never asked about a tree")

        trees.hashed(["pr": Self.tree])
        #expect(PollLoops.plan(running: running, wanted: wanted()) == PollLoops.Plan(), "the same tree: the loop keeps its rhythm")
        #expect(!trees.skipsRun("pr", basis: .tree) && allowedNow())

        trees.mayHaveChanged()
        trees.hashed(["pr": String(repeating: "b", count: 40)])
        #expect(PollLoops.plan(running: running, wanted: wanted()) == PollLoops.Plan(stop: ["pr"]),
                "new content: the loop stops, and the card asks")
        #expect(!trees.skipsRun("pr", basis: .tree) && !allowedNow())

        trees.hashed(["pr": nil])
        #expect(trees.wouldNotHash("pr") && trees.skipsRun("pr", basis: .tree))
        #expect(!HashedTrees().wouldNotHash("pr") && HashedTrees().skipsRun("pr", basis: .tree),
                "not hashed yet is not 'would not hash', and is skipped too")
    }

    /// While `installed.json` cannot be read, a folder with no record — which
    /// may be a pull request's copy the file no longer says is one — is held
    /// to its tree too, and hashed so that it can be decided: a plugin asking
    /// for nothing is asked, never let run on its version.
    @Test("installed.json that cannot be read: every folder but a link is hashed, and asks")
    func recordsUnreadable() throws {
        let own = try Self.pollPlugin(id: "own", directory: "/u/plugins/own")
        let linked = try Self.pollPlugin(id: "linked", directory: "/u/plugins/linked", linked: true)
        let plugins = [own, linked]
        #expect(Reverification.folders(of: plugins, installed: InstalledPlugins(), recordsReadable: true).isEmpty)
        #expect(Reverification.folders(of: plugins, installed: InstalledPlugins(), recordsReadable: false)
                == ["own": own.directory], "a working copy is never hashed")
        let manifest = try #require(own.manifest)
        let basis = ConsentBasis.of(nil, linked: false, recordsReadable: false)
        let trees = HashedTrees(trees: ["own": Self.tree])
        #expect(PermissionGate.launchDecision(for: manifest, grant: nil, enabled: true,
                                              requiredTree: trees.now("own", basis: basis))
                == .awaitingDecision(pending: []))
        var grants = PermissionGrants()
        grants[manifest.id] = PluginGrant(decidedForVersion: "1.0.0", decidedAt: Self.at)
        #expect(!PermissionGate.launchDecision(for: manifest, grant: grants[manifest.id], enabled: true,
                                               requiredTree: trees.now("own", basis: basis)).isAllowed,
                "a decision for the version alone does not hold")
    }

    /// The card says it whole in both languages — never "waits for your
    /// decision:" with nothing after it.
    @Test("waiting with nothing pending, and the card's question, said whole", arguments: Language.allCases)
    func saidWhole(language: Language) {
        let strings = Strings(language)
        let waiting = strings(.failureReason(.notPermitted(.awaitingDecision(pending: []))))
        #expect(!waiting.isEmpty && !waiting.hasSuffix(":") && !waiting.hasSuffix(": "), "\(waiting)")
        let asking = strings(.failureReason(.notPermitted(.awaitingDecision(pending: [.exec("git")]))))
        #expect(asking != waiting && asking.contains("git"))
        let question = strings(.permissionsAsksNothingUnverified(name: "asks-nothing"))
        #expect(question.contains("asks-nothing"))
        let unreadable = strings(.permissionsFolderUnreadable(name: "asks-nothing"))
        #expect(unreadable.contains("asks-nothing") && unreadable != question)
        for said in [question, unreadable] {
            for word in ["sandbox", "песочниц", "restricted", "огранич"] {
                #expect(!said.lowercased().contains(word), "\(said) promises what uDeck does not do")
            }
        }
        switch language {
        case .english:
            #expect(question == "asks-nothing asks for nothing, but its code is unverified")
            #expect(unreadable == "uDeck could not read every file in asks-nothing's folder, so it does not run it",
                    "docs/plugin-repository.md, Consent for unverified code, says exactly this")
            #expect(strings(.pluginMarkUnverified) == "Unverified")
        case .russian:
            #expect(question == "asks-nothing ничего не просит, но его код не проверен")
            #expect(unreadable == "uDeck не смог прочитать все файлы в папке asks-nothing, поэтому не запускает его")
            #expect(strings(.pluginMarkUnverified) == "Не проверен")
            #expect(waiting == "ждёт вашего решения, можно ли его запускать")
        }
    }
}
