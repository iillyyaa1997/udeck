import Foundation
import ServiceManagement
import UDeckAgentHost
import UDeckKit

/// The helper, `udeck-agentd`, as uDeck registers it with the system and
/// reaches it: a login agent of this bundle (`Contents/Library/LaunchAgents`,
/// written by `Scripts/make-app.sh`) with a Mach service named after this
/// copy's bundle identifier, held to the helper's code signature.
///
/// Like `SystemLoginItem`, this lives in the executable target, which has no
/// test target, so no `swift test` can register anything on anyone's Mac. The
/// socket protocol and the helper itself are tested in UDeckAgentHost.
@MainActor
final class SystemAgentHelper {
    let bundleIdentifier: String
    let label: String
    private let service: SMAppService
    /// Fixed now, from this copy's own signature (or, ad-hoc, the helper's
    /// code hash as it is on disk now): what every message from the helper
    /// must satisfy.
    let helperRequirement: String?

    init(bundle: Bundle = .main) {
        bundleIdentifier = bundle.bundleIdentifier ?? "place.unicorns.udeck"
        label = HostPaths.agentLabel(bundleIdentifier: bundleIdentifier)
        service = .agent(plistName: label + ".plist")
        let helper = bundle.bundleURL.appendingPathComponent("Contents/Helpers/udeck-agentd")
        helperRequirement = try? CodeIdentity.peerRequirement(identifier: label, codeAt: helper)
    }

    var status: SMAppService.Status { service.status }

    /// Registers the helper unless it already is. Registering again would make
    /// macOS post "Background item added" once more.
    func registerIfNeeded() throws {
        if service.status != .enabled { try service.register() }
    }

    func unregister() async throws {
        try await service.unregister()
    }

    /// Connects and says hello, trying again for up to `seconds` while the
    /// helper is still starting (launchd starts it on the first message).
    func connect(seconds: Double = 20) async throws -> (AgentHostClient, AgentHostClient.Hello) {
        guard let helperRequirement else {
            throw CodeIdentity.Failure("the helper in this bundle has no usable signature")
        }
        let deadline = Date().addingTimeInterval(seconds)
        var lastError: Error = AgentHostClient.Failure.closed
        while Date() < deadline {
            do {
                let client = AgentHostClient(machServiceName: label, helperRequirement: helperRequirement)
                let hello = try await client.hello(client: "uDeck \(Self.version)")
                return (client, hello)
            } catch {
                lastError = error
                try await Task.sleep(for: .milliseconds(250))
            }
        }
        throw lastError
    }

    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development"
    }

    static func describe(_ status: SMAppService.Status) -> String {
        switch status {
        case .enabled: "enabled"
        case .notRegistered: "notRegistered"
        case .requiresApproval: "requiresApproval"
        case .notFound: "notFound"
        @unknown default: "unknown(\(status.rawValue))"
        }
    }
}

/// The lab's look at the helper, on a key only the lab writes
/// (`defaults write <bundle id> AgentHelperSelfTest -bool true`); without it
/// nothing here runs and nothing is registered.
///
/// Each launch appends one JSON line to `~/.udeck/agents/selftest.jsonl`: was
/// the helper registered and reached, did a session started by an earlier
/// launch survive uDeck being killed (same pid), and could an agent the helper
/// started read `~/Documents` — the Full Disk Access question (spec §10.5).
@MainActor
enum AgentHelperSelfTest {
    static let key = "AgentHelperSelfTest"
    /// The lab's way to leave a machine as it found it: unregister the helper.
    static let unregisterKey = "AgentHelperUnregister"
    static let sleeper = "selftest-sleeper"

    static var isOn: Bool {
        UserDefaults.standard.bool(forKey: key) || UserDefaults.standard.bool(forKey: unregisterKey)
    }

    static func run(_ helper: SystemAgentHelper) async {
        var report: [String: Any] = ["at": ISO8601DateFormatter().string(from: Date()),
                                     "uDeckPid": Int(getpid()), "bundle": helper.bundleIdentifier]
        report["statusBefore"] = SystemAgentHelper.describe(helper.status)
        if UserDefaults.standard.bool(forKey: unregisterKey) {
            do {
                try await helper.unregister()
                report["unregistered"] = true
            } catch {
                report["unregistered"] = false
                report["error"] = String(describing: error)
            }
            report["statusAfter"] = SystemAgentHelper.describe(helper.status)
            write(report)
            return
        }
        report["helperRequirement"] = helper.helperRequirement ?? "(none)"
        do {
            try helper.registerIfNeeded()
            report["statusAfter"] = SystemAgentHelper.describe(helper.status)
            let (client, hello) = try await helper.connect()
            report["helperVersion"] = hello.info.version
            report["helperPid"] = Int(hello.info.pid)
            report["helperInstance"] = hello.info.instance
            let home = HostPaths.home.path
            let environment = ["PATH": "/usr/bin:/bin", "HOME": home]
            if let sleeper = hello.sessions.first(where: { $0.session == sleeper }), sleeper.running {
                report["sleeperSurvived"] = true
                report["sleeperPid"] = Int(sleeper.pid ?? 0)
            } else {
                let pid = try await client.spawn(SpawnSpec(
                    session: sleeper, executable: "/bin/sleep", arguments: ["900"],
                    environment: environment, directory: home))
                report["sleeperSurvived"] = false
                report["sleeperPid"] = Int(pid)
            }
            let probe = "selftest-documents-\(Int(Date().timeIntervalSince1970))"
            let agent = try await HostedAgent.spawn(SpawnSpec(
                session: probe, executable: "/bin/ls", arguments: ["-1", home + "/Documents"],
                environment: environment, directory: home), on: client)
            let exit = await agent.exit()
            report["documentsExit"] = Int(exit.status)
            report["documentsError"] = exit.stderrTail.trimmingCharacters(in: .whitespacesAndNewlines)
            try? await client.forget(session: probe)
            await client.close()
        } catch {
            report["error"] = String(describing: error)
            report["statusAfter"] = SystemAgentHelper.describe(helper.status)
        }
        write(report)
    }

    private static func write(_ report: [String: Any]) {
        let folder = HostPaths.home.appendingPathComponent(".udeck/agents", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        guard var data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) else { return }
        data.append(0x0A)
        let file = folder.appendingPathComponent("selftest.jsonl")
        if let handle = try? FileHandle(forWritingTo: file) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: file)
        }
        DeckLog.panel.notice("agent helper self-test: \(String(decoding: data, as: UTF8.self), privacy: .public)")
    }
}
