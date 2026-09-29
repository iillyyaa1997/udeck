import Foundation
import Testing
@testable import UDeckCore

/// The plugins in `examples/`, loaded as uDeck loads them: on the search path
/// uDeck's own settings give a plugin.
@Suite("Example plugins")
struct ExamplePluginTests {
    @Test("the examples shipped with the repository all load")
    func examplesAreValid() {
        let discovery = PluginDiscovery(searchPath: AppSettings().pluginExecutableSearchPath)
        for name in ["hello-card", "disk-space", "slow-plugin", "broken-card"] {
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

    /// The manifest an action is claimed to come from. `mayRun` needs it as
    /// well as the grant: consent is for what *this* version asked for.
    func asking(_ exec: [String], version: String = "1.0.0") -> PluginManifest {
        manifest(PermissionRequest(exec: exec), version: version)
    }

    @Test("an action runs only when exec was granted for that command")
    func actionsAreGatedByExec() {
        let m = asking(["kubectl"])
        let grant = PluginGrant(granted: [.exec("kubectl")], decidedForVersion: "1.0.0")
        #expect(PermissionGate.mayRun(CardAction(label: "a", run: ["kubectl", "get", "pods"]), requestedBy: m, grant: grant))
        #expect(!PermissionGate.mayRun(CardAction(label: "a", run: ["rm", "-rf", "/"]), requestedBy: m, grant: grant))
        #expect(!PermissionGate.mayRun(CardAction(label: "a", run: ["kubectl"]), requestedBy: m, grant: nil))
    }

    /// A grant is decided against a version. Keeping it usable after the plugin
    /// changed under it means the permission screen and the buttons disagree:
    /// the screen reads the new manifest, the buttons ran on the old consent.
    @Test("a grant does not outlive the version it was given for")
    func aGrantDoesNotOutliveItsVersion() {
        let action = CardAction(label: "a", run: ["open", "/Applications"])
        let grant = PluginGrant(granted: [.exec("open")], decidedForVersion: "1.0.0")

        #expect(PermissionGate.mayRun(action, requestedBy: asking(["open"]), grant: grant))
        // Same id, new version, asks for nothing: the screen says so, and now
        // the button agrees with the screen.
        #expect(!PermissionGate.mayRun(action, requestedBy: asking([], version: "2.0.0"), grant: grant))
        // Same version, but this manifest no longer asks for it either.
        #expect(!PermissionGate.mayRun(action, requestedBy: asking([]), grant: grant))
        // Asks for it, but the grant was decided against a different version.
        #expect(!PermissionGate.mayRun(action, requestedBy: asking(["open"], version: "2.0.0"), grant: grant))
    }

    /// A grant for `ps` is read by the operator as "may run the `ps` on this
    /// machine". Matching only the last path component made it mean "may run
    /// anything called `ps`, from anywhere" — including a file the plugin
    /// shipped itself. No privilege was gained by that, since the plugin's own
    /// process can run whatever it likes; what was wrong is that the consent
    /// sheet said something untrue.
    @Test("a grant for a command name does not permit a different file with that name")
    func aNameIsNotAPath() {
        let m = asking(["ps"])
        let grant = PluginGrant(granted: [.exec("ps")], decidedForVersion: "1.0.0")
        #expect(PermissionGate.mayRun(CardAction(label: "a", run: ["ps"]), requestedBy: m, grant: grant))
        #expect(!PermissionGate.mayRun(CardAction(label: "a", run: ["/bin/ps"]), requestedBy: m, grant: grant))
        #expect(!PermissionGate.mayRun(CardAction(label: "a", run: ["/tmp/evil/ps"]), requestedBy: m, grant: grant))
        #expect(!PermissionGate.mayRun(CardAction(label: "a", run: ["../../tmp/evil/ps"]), requestedBy: m, grant: grant))
        #expect(!PermissionGate.mayRun(CardAction(label: "a", run: ["./ps"]), requestedBy: m, grant: grant))
    }

    @Test("a plugin that wants to run its own tool has to name the path, and the operator sees it")
    func aPathIsMatchedLiterally() {
        let m = asking(["./tools/refresh"])
        let grant = PluginGrant(granted: [.exec("./tools/refresh")], decidedForVersion: "1.0.0")
        #expect(PermissionGate.mayRun(CardAction(label: "a", run: ["./tools/refresh"]), requestedBy: m, grant: grant))
        #expect(!PermissionGate.mayRun(CardAction(label: "a", run: ["refresh"]), requestedBy: m, grant: grant))
        #expect(!PermissionGate.mayRun(CardAction(label: "a", run: ["./tools/other"]), requestedBy: m, grant: grant))
        // And the operator reads the path they are agreeing to.
        #expect(Capability.exec("./tools/refresh").summary == "run ./tools/refresh")
    }

    @Test("an action with no command never runs")
    func emptyActionRefused() {
        let grant = PluginGrant(granted: [.exec("ps")], decidedForVersion: "1.0.0")
        #expect(!PermissionGate.mayRun(CardAction(label: "a", run: []), requestedBy: asking(["ps"]), grant: grant))
    }

    /// Q120: a plugin may still declare a secret, and is asked about it, but
    /// nothing hands one over — so nothing may say the host holds it for the
    /// plugin, and the consent sheet says it will not be given, in both
    /// languages.
    @Test("a secret is asked about and said not to be handed out, in English and Russian")
    func secretsAreNotProvided() {
        #expect(Capability.secret("printer").processEnforcement == .notProvided)
        #expect(Capability.read("/tmp/*").processEnforcement == .declaredOnly)
        #expect(Capability.exec("ps").processEnforcement == .declaredOnly)

        let english = Strings(.english)(Capability.secret("printer").summaryPhrase)
        #expect(english == "be given the secret \"printer\" (uDeck does not hand out secrets yet)")
        #expect(Capability.secret("printer").summary == english)
        #expect(Strings(.english)(.permissionsAsksTo) + " " + english
                == "This plugin asks to: be given the secret \"printer\" (uDeck does not hand out secrets yet)")
        let russian = Strings(.russian)(Capability.secret("printer").summaryPhrase)
        #expect(russian == "секрет «printer» (uDeck пока секретов не выдаёт)")
        for text in [english, russian] {
            #expect(!text.contains("receive") && !text.contains("получать"), "\(text) promises a secret")
        }
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
