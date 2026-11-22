import Foundation
import UDeckAgentHost
import UDeckAgents

/// Where the chat's agents run: in uDeck's own process, or in the helper,
/// which keeps them running while uDeck quits, crashes or updates.
@MainActor
public protocol ChatAgents: AnyObject {
    /// Whether agents outlive uDeck here.
    var keepsAgentsAlive: Bool { get }
    func spawn(_ spec: SpawnSpec) async throws -> any AgentChannel
    /// Agents still running from before uDeck started (the helper's).
    func survivors() async -> [SessionSummary]
    /// A channel to a survivor, replaying what it said since it started.
    func attach(_ session: String) async throws -> any AgentChannel
}

/// Agents as children of uDeck: they end when it does, as a terminal's do.
@MainActor
public final class LocalAgents: ChatAgents {
    public init() {}
    public var keepsAgentsAlive: Bool { false }

    public func spawn(_ spec: SpawnSpec) async throws -> any AgentChannel {
        try AgentProcess(executable: URL(fileURLWithPath: spec.executable), arguments: spec.arguments,
                         environment: spec.environment, directory: URL(fileURLWithPath: spec.directory, isDirectory: true))
    }

    public func survivors() async -> [SessionSummary] { [] }

    public func attach(_ session: String) async throws -> any AgentChannel {
        throw AgentProcess.Failure.notRunning
    }
}

/// Agents in `udeck-agentd`, over one connection that is made again when it
/// drops (launchd starts the helper on demand).
@MainActor
public final class HelperAgents: ChatAgents {
    private let connect: @MainActor () async throws -> AgentHostClient
    private var client: AgentHostClient?

    /// `connect` registers the helper if needed and says hello to it.
    public init(connect: @escaping @MainActor () async throws -> AgentHostClient) {
        self.connect = connect
    }

    public var keepsAgentsAlive: Bool { true }

    private func live() async throws -> AgentHostClient {
        if let client, !client.isClosed { return client }
        let fresh = try await connect()
        client = fresh
        return fresh
    }

    public func spawn(_ spec: SpawnSpec) async throws -> any AgentChannel {
        try await HostedAgent.spawn(spec, on: try await live())
    }

    public func survivors() async -> [SessionSummary] {
        guard let client = try? await live(), let sessions = try? await client.list() else { return [] }
        return sessions.filter(\.running)
    }

    public func attach(_ session: String) async throws -> any AgentChannel {
        try await HostedAgent.attach(session: session, after: 0, on: try await live()).agent
    }
}
