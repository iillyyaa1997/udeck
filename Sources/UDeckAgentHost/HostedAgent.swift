import Foundation
import UDeckAgents

/// An agent the helper runs, seen as if it ran here: the `AgentChannel` the
/// connections speak through. Its `lines` are the session's journal from the
/// point it was attached, its writes go over the socket in order, and its exit
/// is the journal's exit event.
public final class HostedAgent: AgentChannel, @unchecked Sendable {
    public let session: String
    public let lines: AsyncStream<LineFramer.Piece>
    private let client: AgentHostClient
    private let state = Guarded(State())

    private struct State {
        var pid: Int32 = 0
        var exit: AgentProcess.Exit?
        var waiters: [CheckedContinuation<AgentProcess.Exit, Never>] = []
        /// The last event seen, to subscribe again from after a reconnect.
        var lastSeq = 0
        var inputs: [String: Int] = [:]
    }

    /// Starts an agent in the helper and attaches to it from its first event.
    public static func spawn(_ spec: SpawnSpec, on client: AgentHostClient) async throws -> HostedAgent {
        let agent = await HostedAgent(session: spec.session, client: client)
        let pid = try await client.spawn(spec)
        agent.state.withLock { if $0.pid == 0 { $0.pid = pid } }
        try await client.subscribe(session: spec.session, after: 0)
        return agent
    }

    /// Attaches to a session the helper already runs — after uDeck restarted —
    /// from after `seq` of the journal `epoch` (0: everything still kept).
    public static func attach(session: String, after seq: Int = 0, epoch: String? = nil,
                              on client: AgentHostClient) async throws
        -> (agent: HostedAgent, subscription: AgentHostClient.Subscription)
    {
        let agent = await HostedAgent(session: session, client: client)
        let subscription = try await client.subscribe(session: session, after: seq, epoch: epoch)
        return (agent, subscription)
    }

    private init(session: String, client: AgentHostClient) async {
        self.session = session
        self.client = client
        let events = await client.route(session: session)
        let (lines, continuation) = AsyncStream.makeStream(of: LineFramer.Piece.self)
        self.lines = lines
        let state = self.state
        Task {
            for await event in events {
                state.withLock { $0.lastSeq = event.seq }
                switch event.kind {
                case .line(let text): continuation.yield(.line(text))
                case .overlong(let bytes): continuation.yield(.overlong(bytes: bytes))
                case .started(let pid): state.withLock { $0.pid = pid }
                case .input(let tag): state.withLock { $0.inputs[tag] = event.seq }
                case .exited(let status, let tail):
                    let exit = AgentProcess.Exit(status: status, stderrTail: tail)
                    let waiters = state.withLock { state -> [CheckedContinuation<AgentProcess.Exit, Never>] in
                        state.exit = exit
                        defer { state.waiters.removeAll() }
                        return state.waiters
                    }
                    waiters.forEach { $0.resume(returning: exit) }
                }
            }
            continuation.finish()
            // The connection dropped without an exit: the agent may well still
            // run in the helper, but this channel is done. Waiters learn of it
            // as an exit with no status.
            let lost = AgentProcess.Exit(status: -1, stderrTail: "the connection to udeck-agentd closed")
            let waiters = state.withLock { state -> [CheckedContinuation<AgentProcess.Exit, Never>] in
                if state.exit == nil { state.exit = lost }
                defer { state.waiters.removeAll() }
                return state.waiters
            }
            waiters.forEach { $0.resume(returning: lost) }
        }
    }

    public var processIdentifier: Int32 { state.withLock { $0.pid } }

    /// The last journal event this channel has seen.
    public var lastSeq: Int { state.withLock { $0.lastSeq } }

    /// Where in the journal the helper recorded the line written with `tag`,
    /// once it has come back — the proof the agent got it.
    public func delivered(_ tag: String) -> Int? { state.withLock { $0.inputs[tag] } }

    public func write(line: String) throws {
        try write(line: line, tag: nil)
    }

    /// Writes with a tag, so its delivery can be checked with `delivered(_:)`.
    public func write(line: String, tag: String?) throws {
        guard state.withLock({ $0.exit == nil }), !client.isClosed else { throw AgentProcess.Failure.notRunning }
        var fields: [String: JSONValue] = ["session": .string(session), "line": .string(line)]
        if let tag { fields["tag"] = .string(tag) }
        guard client.post("write", fields) else { throw AgentProcess.Failure.notRunning }
    }

    public func closeInput() {
        client.post("closeInput", ["session": .string(session)])
    }

    public func terminate(grace: Duration) async -> AgentProcess.Exit {
        if let exit = state.withLock({ $0.exit }) { return exit }
        _ = try? await client.terminate(session: session, grace: grace)
        return await exit()
    }

    public func exit() async -> AgentProcess.Exit {
        await withCheckedContinuation { continuation in
            let done = state.withLock { state -> AgentProcess.Exit? in
                if let exit = state.exit { return exit }
                state.waiters.append(continuation)
                return nil
            }
            if let done { continuation.resume(returning: done) }
        }
    }
}
