import Foundation
import UDeckAgents

/// An agent the helper runs, seen as if it ran here: the `AgentChannel` the
/// connections speak through. Its `lines` are the session's journal from the
/// point it was attached, its writes go over the connection in order, and its
/// exit is the exit of the run it is attached to — never an earlier run's
/// still in the journal.
public final class HostedAgent: AgentChannel, @unchecked Sendable {
    public enum Failure: Error, Equatable {
        /// Another channel already owns this session on this connection.
        case alreadyAttached(String)
    }

    public let session: String
    public let lines: AsyncStream<LineFramer.Piece>
    private let client: AgentHostClient
    private let token: UUID
    private let state = Guarded(State())

    private struct State {
        var pid: Int32 = 0
        var exit: AgentProcess.Exit?
        var waiters: [CheckedContinuation<AgentProcess.Exit, Never>] = []
        /// The last event seen, to subscribe again from after a reconnect.
        var lastSeq = 0
        var inputs: [String: Int] = [:]
        /// Where this channel's run starts; nil until the helper has said.
        var runStartedSeq: Int?
        /// An exit seen before `runStartedSeq` was known.
        var earlyExit: (seq: Int, exit: AgentProcess.Exit)?
        /// A run already over when attached: finish once the replay up to
        /// `seq` has been read, so none of its lines is cut off.
        var finishAt: (seq: Int, exit: AgentProcess.Exit)?
        var finished = false
    }

    private let continuation: AsyncStream<LineFramer.Piece>.Continuation

    /// Starts an agent in the helper and attaches to its run from its first
    /// event.
    public static func spawn(_ spec: SpawnSpec, on client: AgentHostClient) async throws -> HostedAgent {
        let (pid, startedSeq) = try await client.spawnRun(spec)
        let agent = try await HostedAgent(session: spec.session, client: client)
        agent.state.withLock {
            $0.pid = pid
            $0.runStartedSeq = startedSeq
        }
        do {
            try await client.subscribe(session: spec.session, after: max(0, startedSeq - 1))
        } catch {
            await agent.detach()
            throw error
        }
        return agent
    }

    /// Attaches to a session the helper already runs — after uDeck restarted —
    /// from after `seq` of the journal `epoch` (0: everything still kept).
    public static func attach(session: String, after seq: Int = 0, epoch: String? = nil,
                              on client: AgentHostClient) async throws
        -> (agent: HostedAgent, subscription: AgentHostClient.Subscription)
    {
        let agent = try await HostedAgent(session: session, client: client)
        let subscription: AgentHostClient.Subscription
        do {
            subscription = try await client.subscribe(session: session, after: seq, epoch: epoch)
        } catch {
            await agent.detach()
            throw error
        }
        agent.attached(subscription)
        return (agent, subscription)
    }

    private init(session: String, client: AgentHostClient) async throws {
        guard let (token, events) = await client.route(session: session) else {
            throw Failure.alreadyAttached(session)
        }
        self.session = session
        self.client = client
        self.token = token
        (lines, continuation) = AsyncStream.makeStream(of: LineFramer.Piece.self)
        Task { [weak self] in
            for await event in events {
                guard let self else { return }
                self.receive(event)
            }
            self?.connectionLost()
        }
    }

    private func receive(_ event: HostEvent) {
        defer {
            let due = state.withLock { state -> AgentProcess.Exit? in
                guard let finishAt = state.finishAt, state.lastSeq >= finishAt.seq else { return nil }
                return finishAt.exit
            }
            if let due { finish(with: due) }
        }
        state.withLock { $0.lastSeq = max($0.lastSeq, event.seq) }
        switch event.kind {
        case .line(let text): continuation.yield(.line(text))
        case .overlong(let bytes): continuation.yield(.overlong(bytes: bytes))
        case .started(let pid):
            state.withLock { if event.seq >= ($0.runStartedSeq ?? 0) { $0.pid = pid } }
        case .input(let tag): state.withLock { $0.inputs[tag] = event.seq }
        case .exited(let status, let tail):
            let exit = AgentProcess.Exit(status: status, stderrTail: tail)
            let mine = state.withLock { state -> Bool? in
                guard let start = state.runStartedSeq else {
                    state.earlyExit = (event.seq, exit)
                    return nil
                }
                return event.seq > start
            }
            if mine == true { finish(with: exit) }
        }
    }

    /// The subscription's acknowledgement: where the run starts, and whether
    /// it is already over.
    private func attached(_ subscription: AgentHostClient.Subscription) {
        let early = state.withLock { state -> (Int, AgentProcess.Exit)? in
            state.runStartedSeq = subscription.runStartedSeq
            if let pid = subscription.pid { state.pid = pid }
            return state.earlyExit.map { ($0.seq, $0.exit) }
        }
        if let (seq, exit) = early, seq > subscription.runStartedSeq {
            finish(with: exit)
        } else if !subscription.running {
            // Over before this channel came, and its exit may be past what the
            // journal still has: finish once the replay has been read.
            let exit = AgentProcess.Exit(status: subscription.status ?? -1, stderrTail: "")
            let now = state.withLock { state -> Bool in
                if state.lastSeq >= subscription.lastSeq { return true }
                state.finishAt = (subscription.lastSeq, exit)
                return false
            }
            if now { finish(with: exit) }
        }
    }

    private func finish(with exit: AgentProcess.Exit) {
        let waiters = state.withLock { state -> [CheckedContinuation<AgentProcess.Exit, Never>]? in
            guard !state.finished else { return nil }
            state.finished = true
            state.exit = exit
            defer { state.waiters.removeAll() }
            return state.waiters
        }
        guard let waiters else { return }
        continuation.finish()
        waiters.forEach { $0.resume(returning: exit) }
        Task { await client.unroute(session: session, token: token) }
    }

    /// The connection dropped without this run's exit: the agent may well
    /// still run in the helper, but this channel is done.
    private func connectionLost() {
        finish(with: AgentProcess.Exit(status: -1, stderrTail: "the connection to udeck-agentd closed"))
    }

    private func detach() async {
        await client.unroute(session: session, token: token)
    }

    public var processIdentifier: Int32 { state.withLock { $0.pid } }

    /// The last journal event this channel has seen.
    public var lastSeq: Int { state.withLock { $0.lastSeq } }

    /// Where in the journal the helper recorded the line written with `tag`,
    /// once it has come back — the proof the agent's stdin queue took it.
    public func delivered(_ tag: String) -> Int? { state.withLock { $0.inputs[tag] } }

    public func write(line: String) throws {
        try write(line: line, tag: nil)
    }

    /// Writes with a tag, so its delivery can be checked with `delivered(_:)`.
    /// A write the helper refused earlier (the agent stopped reading) is
    /// reported here, by the next write.
    public func write(line: String, tag: String?) throws {
        if let refused = client.takeRefusedWrite(session: session) {
            throw AgentHostClient.Failure.writeRefused(refused)
        }
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
