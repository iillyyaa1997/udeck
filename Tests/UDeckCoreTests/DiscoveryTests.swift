import Foundation
import Testing
@testable import UDeckCore

@Suite("Plugin discovery")
struct DiscoveryTests {
    let searchPath = ["/usr/bin", "/bin"]

    var discovery: PluginDiscovery { PluginDiscovery(searchPath: searchPath) }

    let goodManifest = """
    { "id": "good", "name": "Good", "version": "1.0.0", "api": 1, "kind": "poll",
      "run": ["./run.sh"], "interval": 5, "timeout": 2 }
    """

    @Test("a missing plugins directory is an empty result, not a failure")
    func missingDirectoryIsEmpty() {
        let temp = TemporaryDirectory()
        #expect(discovery.scan(temp.paths.plugins).isEmpty)
    }

    @Test("a well-formed plugin is found and usable")
    func findsAGoodPlugin() {
        let temp = TemporaryDirectory()
        temp.writePlugin(folder: "good", manifest: goodManifest,
                         script: (name: "run.sh", body: "#!/bin/sh\necho '{}'\n", executable: true))
        let found = discovery.scan(temp.paths.plugins)
        #expect(found.count == 1)
        #expect(found[0].isUsable)
        #expect(found[0].manifest?.id.rawValue == "good")
        #expect(found[0].executable?.lastPathComponent == "run.sh")
    }

    /// A plugin that simply fails to appear is a support question. One that
    /// appears with the reason next to it is a five-second fix.
    @Test("a folder with no manifest is still listed, with the reason")
    func brokenPluginIsStillListed() {
        let temp = TemporaryDirectory()
        let directory = temp.url.appendingPathComponent("plugins/empty", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let found = discovery.scan(temp.paths.plugins)
        #expect(found.count == 1)
        #expect(found[0].problems == [.missingManifest])
        #expect(!found[0].isUsable)
    }

    @Test("a malformed manifest names the field that is wrong")
    func malformedManifestNamesTheField() {
        let temp = TemporaryDirectory()
        temp.writePlugin(folder: "bad", manifest: """
        { "id": "bad", "name": "Bad", "version": "1.0.0", "api": 1, "kind": "poll" }
        """)
        let found = discovery.scan(temp.paths.plugins)
        guard case .malformedManifest(let detail) = found[0].problems.first else {
            Issue.record("expected a malformed manifest, got \(found[0].problems)"); return
        }
        #expect(detail.contains("run"))
    }

    @Test("the manifest id must match the folder it sits in")
    func idMustMatchFolder() {
        let temp = TemporaryDirectory()
        temp.writePlugin(folder: "elsewhere", manifest: goodManifest,
                         script: (name: "run.sh", body: "#!/bin/sh\n", executable: true))
        let found = discovery.scan(temp.paths.plugins)
        #expect(found[0].problems.contains(.identifierMismatch(declared: "good", folder: "elsewhere")))
    }

    @Test("a script without the executable bit says so, in the words of the fix")
    func nonExecutableScript() {
        let temp = TemporaryDirectory()
        temp.writePlugin(folder: "good", manifest: goodManifest,
                         script: (name: "run.sh", body: "#!/bin/sh\n", executable: false))
        let found = discovery.scan(temp.paths.plugins)
        guard case .executableNotExecutable = found[0].problems.last else {
            Issue.record("expected a non-executable complaint, got \(found[0].problems)"); return
        }
        #expect(found[0].problems.last?.description.contains("chmod +x") == true)
    }

    /// A relative `run` that climbs out of the plugin folder would let a
    /// manifest reach anywhere on disk while still looking self-contained.
    @Test("a relative command cannot escape the plugin folder")
    func relativePathCannotEscape() {
        let temp = TemporaryDirectory()
        temp.writePlugin(folder: "sneaky", manifest: """
        { "id": "sneaky", "name": "Sneaky", "version": "1.0.0", "api": 1, "kind": "poll",
          "run": ["../../../../bin/sh"], "interval": 5, "timeout": 2 }
        """)
        let found = discovery.scan(temp.paths.plugins)
        #expect(found[0].executable == nil)
        #expect(found[0].problems.contains { $0.description.contains("outside the plugin folder") })
    }

    @Test("a bare command name is resolved on the configured path, not the inherited one")
    func bareCommandUsesConfiguredPath() {
        let temp = TemporaryDirectory()
        temp.writePlugin(folder: "bare", manifest: """
        { "id": "bare", "name": "Bare", "version": "1.0.0", "api": 1, "kind": "poll",
          "run": ["sh"], "interval": 5, "timeout": 2 }
        """)
        #expect(discovery.load(temp.url.appendingPathComponent("plugins/bare")).executable?.path == "/bin/sh")

        let empty = PluginDiscovery(searchPath: ["/nowhere"])
        let missing = empty.load(temp.url.appendingPathComponent("plugins/bare"))
        #expect(missing.executable == nil)
        #expect(missing.problems.contains { $0.description.contains("/nowhere") })
    }

    @Test("the examples shipped with the repository all load")
    func examplesAreValid() {
        let discovery = PluginDiscovery(searchPath: AppSettings().pluginExecutableSearchPath)
        for name in ["hello-card", "slow-plugin", "broken-card"] {
            let plugin = discovery.load(RepositoryExamples.plugin(name))
            #expect(plugin.problems.isEmpty, "\(name): \(plugin.problems.map(\.description))")
            #expect(plugin.isUsable, "\(name) should be usable")
        }
    }
}

@Suite("Permissions")
struct PermissionTests {
    func manifest(_ permissions: PermissionRequest, version: String = "1.0.0") -> PluginManifest {
        PluginManifest(
            id: PluginIdentifier(rawValue: "p")!, name: "P", version: version, kind: .poll,
            run: ["./x"], interval: 5, timeout: 2, permissions: permissions
        )
    }

    @Test("a plugin that asks for nothing needs no decision")
    func noPermissionsNeedsNoDecision() {
        #expect(PermissionGate.launchDecision(for: manifest(PermissionRequest()), grant: nil, enabled: true) == .allowed)
    }

    @Test("a plugin that asks for something waits until the operator has decided")
    func waitsForADecision() {
        let m = manifest(PermissionRequest(read: ["/tmp/x-*"]))
        guard case .awaitingDecision(let pending) = PermissionGate.launchDecision(for: m, grant: nil, enabled: true) else {
            Issue.record("expected to be waiting"); return
        }
        #expect(pending == [.read("/tmp/x-*")])
    }

    /// Half-granting would be theatre: nothing stops an already-running plugin
    /// from doing the rest. So a refused capability means the plugin does not
    /// run at all, which is enforcement that is actually real.
    @Test("a refused capability stops the plugin from running at all")
    func refusalStopsTheLaunch() {
        let m = manifest(PermissionRequest(read: ["/tmp/x-*"], exec: ["ps"]))
        let grant = PluginGrant(granted: [.read("/tmp/x-*")], denied: [.exec("ps")], decidedForVersion: "1.0.0")
        guard case .refused(let denied) = PermissionGate.launchDecision(for: m, grant: grant, enabled: true) else {
            Issue.record("expected a refusal"); return
        }
        #expect(denied == [.exec("ps")])
    }

    @Test("a plugin that updates and asks for more is asked about again")
    func upgradeReopensTheQuestion() {
        let old = PluginGrant(granted: [.read("/tmp/x-*")], decidedForVersion: "1.0.0")
        let updated = manifest(PermissionRequest(read: ["/tmp/x-*"]), version: "1.1.0")
        guard case .awaitingDecision = PermissionGate.launchDecision(for: updated, grant: old, enabled: true) else {
            Issue.record("a new version must re-ask"); return
        }
    }

    @Test("a switched-off plugin does not run whatever its grants say")
    func disabledWins() {
        let m = manifest(PermissionRequest())
        #expect(PermissionGate.launchDecision(for: m, grant: nil, enabled: false) == .disabled)
    }

    @Test("an action runs only when exec was granted for that command")
    func actionsAreGatedByExec() {
        let grant = PluginGrant(granted: [.exec("kubectl")], decidedForVersion: "1.0.0")
        #expect(PermissionGate.mayRun(CardAction(label: "a", run: ["kubectl", "get", "pods"]), grant: grant))
        #expect(!PermissionGate.mayRun(CardAction(label: "a", run: ["rm", "-rf", "/"]), grant: grant))
        #expect(!PermissionGate.mayRun(CardAction(label: "a", run: ["kubectl"]), grant: nil))
    }

    @Test("a full path cannot be used to smuggle a different command past a grant")
    func fullPathIsMatchedByItsName() {
        let grant = PluginGrant(granted: [.exec("ps")], decidedForVersion: "1.0.0")
        #expect(PermissionGate.mayRun(CardAction(label: "a", run: ["/bin/ps"]), grant: grant))
        #expect(!PermissionGate.mayRun(CardAction(label: "a", run: ["/bin/sh"]), grant: grant))
    }

    @Test("an action with no command never runs")
    func emptyActionRefused() {
        let grant = PluginGrant(granted: [.exec("ps")], decidedForVersion: "1.0.0")
        #expect(!PermissionGate.mayRun(CardAction(label: "a", run: []), grant: grant))
    }

    @Test("secrets are the one capability the host genuinely holds for a running plugin")
    func secretsAreHostMediated() {
        #expect(Capability.secret("bambu").processEnforcement == .hostMediated)
        #expect(Capability.read("/tmp/*").processEnforcement == .declaredOnly)
        #expect(Capability.exec("ps").processEnforcement == .declaredOnly)

        let grant = PluginGrant(granted: [.secret("bambu")], decidedForVersion: "1.0.0")
        #expect(PermissionGate.mayReceiveSecret("bambu", grant: grant))
        #expect(!PermissionGate.mayReceiveSecret("telegram", grant: grant))
    }

    @Test("grants survive a round trip through JSON")
    func grantsRoundTrip() throws {
        var grants = PermissionGrants()
        grants[PluginIdentifier(rawValue: "p")!] = PluginGrant(
            granted: [.read("/tmp/x-*"), .screen], denied: [.exec("ps")], decidedForVersion: "1.0.0"
        )
        let data = try JSONFileStore<PermissionGrants>.encoder.encode(grants)
        let restored = try JSONFileStore<PermissionGrants>.decoder.decode(PermissionGrants.self, from: data)
        #expect(restored == grants)
    }
}
