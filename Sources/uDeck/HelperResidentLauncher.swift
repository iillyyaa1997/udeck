import Foundation
import UDeckAgentHost
import UDeckAgents
import UDeckKit

/// Resident plugins' processes in the helper (`udeck-agentd`): they go on
/// while uDeck quits, crashes or updates, and the next uDeck takes them back.
///
/// When the helper cannot be had — not registered and not allowed, a copy of
/// uDeck without a usable signature, run from `swift build` — `launch`
/// throws, and the plugin runs as uDeck's own child, as before. A failure is
/// not tried again for a minute: every plugin would wait on it otherwise.
@MainActor
final class HelperResidentLauncher: ResidentLauncher {
    private let helper: SystemAgentHelper
    private var client: AgentHostClient?
    private var failedAt: Date?
    static let retryAfter: TimeInterval = 60

    init(helper: SystemAgentHelper) {
        self.helper = helper
    }

    private func connected() async throws -> AgentHostClient {
        if let client { return client }
        if let failedAt, Date().timeIntervalSince(failedAt) < Self.retryAfter {
            throw CodeIdentity.Failure("the helper could not be reached a moment ago")
        }
        do {
            try helper.registerIfNeeded()
            let (client, hello) = try await helper.connectOrRestart(seconds: 10)
            DeckLog.plugins.notice("resident plugins run in the helper \(hello.info.version, privacy: .public), pid \(hello.info.pid)")
            self.client = client
            failedAt = nil
            return client
        } catch {
            failedAt = Date()
            throw error
        }
    }

    /// Once more on a new connection when the one held has gone: the helper
    /// was started again since.
    private func withClient<T>(_ body: (AgentHostClient) async throws -> T) async throws -> T {
        let first = try await connected()
        do {
            return try await body(first)
        } catch AgentHostClient.Failure.closed {
            client = nil
            return try await body(try await connected())
        }
    }

    func launch(name: String, executable: URL, arguments: [String], environment: [String: String],
                directory: URL) async throws -> (channel: any AgentChannel, attached: Bool)
    {
        try await withClient { client in
            if let live = try await client.list().first(where: { $0.session == name && $0.running }) {
                // From after the last thing it said: what it said while
                // nobody listened is not said again; `hello` asks it for its
                // cards as they are now.
                let (agent, _) = try await HostedAgent.attach(session: name, after: live.lastSeq, epoch: live.epoch,
                                                              on: client)
                return (agent, true)
            }
            let spec = SpawnSpec(session: name, executable: executable.path, arguments: arguments,
                                 environment: environment, directory: directory.path)
            return (try await HostedAgent.spawn(spec, on: client), false)
        }
    }

    func stop(name: String) async {
        guard let client = try? await connected() else { return }
        if (try? await client.list())?.contains(where: { $0.session == name && $0.running }) == true {
            _ = try? await client.terminate(session: name, grace: .seconds(3))
        }
        try? await client.forget(session: name)
    }

    func kept(prefix: String) async -> [String] {
        guard let sessions = try? await withClient({ try await $0.list() }) else { return [] }
        return sessions.map(\.session).filter { $0.hasPrefix(prefix) }
    }
}
