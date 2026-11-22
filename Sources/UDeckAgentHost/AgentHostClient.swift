import Foundation
import UDeckAgents

/// uDeck's side of the connection to the helper.
///
/// Requests are awaited one reply each; events of every subscribed session
/// come out of `events`, in the helper's order. When the connection drops,
/// every waiting request fails with `.closed` and `events` finishes — uDeck
/// then reconnects, says hello, and subscribes again from the last `seq` it
/// saw of each session.
public actor AgentHostClient {
    public enum Failure: Error, Equatable {
        /// The helper answered with an error.
        case helper(code: String, message: String)
        /// The connection closed — the helper went away, or one side's code
        /// did not satisfy the other's requirement.
        case closed
        case timedOut(String)
        case badReply(String)
        /// Asked before the helper answered hello. Until a reply has come
        /// back — and so passed the helper's code requirement — nothing but
        /// hello leaves this side: no environment, no prompt.
        case notGreeted
        /// The helper took a write and could not deliver it (it said why).
        case writeRefused(String)
    }

    public struct Hello: Sendable, Equatable {
        public let info: HostInfo
        public let sessions: [SessionSummary]
    }

    public struct Subscription: Sendable, Equatable {
        public let firstSeq: Int
        public let lastSeq: Int
        /// Some events after the asked-for `seq` are no longer in the journal,
        /// or the position was in another journal (`epoch`) of the session.
        public let gap: Bool
        public let epoch: String
        /// The `started` event of the session's current run.
        public let runStartedSeq: Int
        public let running: Bool
        public let pid: Int32?
        public let status: Int32?
    }

    /// How many unread messages a stream may hold. Past it the connection is
    /// closed rather than anything dropped: events are numbered, and uDeck
    /// catches up from the journal when it reconnects.
    public static let maxBuffered = 100_000

    /// Events of subscribed sessions that no `HostedAgent` has claimed.
    public nonisolated let events: AsyncStream<HostEvent>
    private let eventsContinuation: AsyncStream<HostEvent>.Continuation
    private let transport: XPCLines
    /// Shared with `post`, which sends without the actor.
    private let ids = Guarded(0)
    private let greeted = Guarded(false)
    /// Requests sent with `post`, by id, with their session: their replies
    /// are not awaited, but a refusal is kept for the next write to report.
    private let posted = Guarded([Int: String]())
    private let refusedWrites = Guarded([String: String]())
    /// Sessions whose events go to a stream of their own, with who owns it.
    private var routes: [String: (token: UUID, continuation: AsyncStream<HostEvent>.Continuation)] = [:]
    private var pending: [Int: CheckedContinuation<JSONValue, any Error>] = [:]
    private var reader: Task<Void, Never>?
    private var closedWith: Failure?

    /// Connects to the helper's launchd service. Every message from it must
    /// satisfy `helperRequirement` (`CodeIdentity.peerRequirement`); nil only in
    /// tests.
    public init(machServiceName: String, helperRequirement: String?) {
        self.init(NSXPCConnection(machServiceName: machServiceName, options: []), helperRequirement)
    }

    /// Connects to an in-process listener (tests).
    public init(endpoint: NSXPCListenerEndpoint, helperRequirement: String?) {
        self.init(NSXPCConnection(listenerEndpoint: endpoint), helperRequirement)
    }

    private init(_ connection: NSXPCConnection, _ requirement: String?) {
        transport = XPCLines(connection, requirement: requirement)
        (events, eventsContinuation) = AsyncStream.makeStream(of: HostEvent.self,
                                                              bufferingPolicy: .bufferingOldest(Self.maxBuffered))
    }

    /// Starts reading; `hello` calls it, so it is needed only to read before
    /// saying hello.
    public func start() {
        guard reader == nil else { return }
        let lines = transport.lines
        reader = Task { [weak self] in
            for await text in lines {
                guard let value = JSONValue.line(Substring(text)) else { continue }
                await self?.receive(value)
            }
            await self?.ended()
        }
    }

    private func receive(_ value: JSONValue) {
        if value["ev"] != nil {
            guard let event = HostEvent(wire: value) else { return }
            let result = routes[event.session]?.continuation.yield(event) ?? eventsContinuation.yield(event)
            if case .dropped = result { transport.close() }
            return
        }
        guard let id = value["id"]?.int else { return }
        if let session = posted.withLock({ $0.removeValue(forKey: id) }) {
            if let message = value["error"]?["message"]?.string {
                refusedWrites.withLock { $0[session] = message }
            }
            return
        }
        guard let waiter = pending.removeValue(forKey: id) else { return }
        if let error = value["error"] {
            waiter.resume(throwing: Failure.helper(code: error["code"]?.string ?? "?",
                                                   message: error["message"]?.string ?? ""))
        } else {
            waiter.resume(returning: value["ok"] ?? [:])
        }
    }

    private func ended() {
        let failure = Failure.closed
        closedWith = failure
        for waiter in pending.values { waiter.resume(throwing: failure) }
        pending.removeAll()
        for route in routes.values { route.continuation.finish() }
        routes.removeAll()
        eventsContinuation.finish()
    }

    /// Sends one request and waits for its reply.
    public func request(_ op: String, _ fields: [String: JSONValue] = [:], timeout: Duration = .seconds(30))
        async throws -> JSONValue
    {
        start()
        if let closedWith { throw closedWith }
        guard op == "hello" || greeted.withLock({ $0 }) else { throw Failure.notGreeted }
        let id = ids.withLock { $0 += 1; return $0 }
        var message = fields
        message["id"] = .number(Double(id))
        message["op"] = .string(op)
        let line = try JSONValue.object(message).encodedLine()
        // Registered and sent in one step on the actor, so requests leave in
        // the order they were made.
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            await self?.expire(id, op: op)
        }
        defer { timer.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            if !transport.send(line) {
                pending[id] = nil
                continuation.resume(throwing: Failure.closed)
            }
        }
    }

    /// Sends a request without waiting for its reply (which is dropped), from
    /// any thread, in order with every other request. For writes on the hot
    /// path: their delivery shows up in the journal as the input event.
    @discardableResult
    nonisolated func post(_ op: String, _ fields: [String: JSONValue]) -> Bool {
        guard greeted.withLock({ $0 }) else { return false }
        let id = ids.withLock { $0 += 1; return $0 }
        if let session = fields["session"]?.string { posted.withLock { $0[id] = session } }
        var message = fields
        message["id"] = .number(Double(id))
        message["op"] = .string(op)
        guard let line = try? JSONValue.object(message).encodedLine() else { return false }
        return transport.send(line)
    }

    public nonisolated var isClosed: Bool { transport.isClosed }

    /// A refusal the helper sent for a posted write to `session`, taken.
    nonisolated func takeRefusedWrite(session: String) -> String? {
        refusedWrites.withLock { $0.removeValue(forKey: session) }
    }

    /// From now on this session's events go to the returned stream instead of
    /// `events`, until `unroute` with the same token or the connection drops.
    /// Nil if the session already has one: one owner per session.
    func route(session: String) -> (token: UUID, events: AsyncStream<HostEvent>)? {
        guard routes[session] == nil else { return nil }
        let (stream, continuation) = AsyncStream.makeStream(of: HostEvent.self,
                                                            bufferingPolicy: .bufferingOldest(Self.maxBuffered))
        let token = UUID()
        routes[session] = (token, continuation)
        return (token, stream)
    }

    func unroute(session: String, token: UUID) {
        guard let route = routes[session], route.token == token else { return }
        routes[session] = nil
        route.continuation.finish()
    }

    private func expire(_ id: Int, op: String) {
        pending.removeValue(forKey: id)?.resume(throwing: Failure.timedOut(op))
    }

    // MARK: - Requests

    public func hello(client: String, protocolVersion: Int = HostWire.protocolVersions.last!) async throws -> Hello {
        let reply = try await request("hello", ["protocol": .number(Double(protocolVersion)),
                                                "client": .string(client)])
        guard let version = reply["version"]?.string, let instance = reply["instance"]?.string,
              let pid = reply["pid"]?.int
        else { throw Failure.badReply("hello") }
        // This reply came through the connection's code requirement: the other
        // end is the helper, and the rest may be said.
        greeted.withLock { $0 = true }
        let info = HostInfo(version: version, instance: instance, pid: Int32(pid),
                            protocolVersion: reply["protocol"]?.int ?? protocolVersion)
        return Hello(info: info, sessions: reply["sessions"]?.array?.compactMap(SessionSummary.init(wire:)) ?? [])
    }

    @discardableResult
    public func spawn(_ spec: SpawnSpec) async throws -> Int32 {
        try await spawnRun(spec).pid
    }

    /// Starts an agent; answers its pid and the `seq` of its run's `started`
    /// event, where a channel for this run begins.
    func spawnRun(_ spec: SpawnSpec) async throws -> (pid: Int32, startedSeq: Int) {
        let reply = try await request("spawn", spec.wire)
        guard let pid = reply["pid"]?.int else { throw Failure.badReply("spawn") }
        return (Int32(pid), reply["startedSeq"]?.int ?? 0)
    }

    /// Writes one line to the agent. With a `tag`, the journal records an
    /// input event for it, which comes back to subscribers as the receipt.
    public func write(session: String, line: String, tag: String? = nil) async throws {
        var fields: [String: JSONValue] = ["session": .string(session), "line": .string(line)]
        if let tag { fields["tag"] = .string(tag) }
        _ = try await request("write", fields)
    }

    public func closeInput(session: String) async throws {
        _ = try await request("closeInput", ["session": .string(session)])
    }

    @discardableResult
    public func terminate(session: String, grace: Duration = .seconds(3)) async throws -> Int32 {
        let millis = Double(grace.components.seconds * 1000) + Double(grace.components.attoseconds) / 1e15
        let reply = try await request("terminate", ["session": .string(session), "graceMs": .number(millis.rounded())],
                                      timeout: grace + .seconds(30))
        return Int32(reply["status"]?.int ?? -1)
    }

    @discardableResult
    public func subscribe(session: String, after seq: Int = 0, epoch: String? = nil) async throws -> Subscription {
        var fields: [String: JSONValue] = ["session": .string(session), "after": .number(Double(seq))]
        if let epoch { fields["epoch"] = .string(epoch) }
        let reply = try await request("subscribe", fields)
        return Subscription(firstSeq: reply["firstSeq"]?.int ?? 1, lastSeq: reply["lastSeq"]?.int ?? 0,
                            gap: reply["gap"]?.bool ?? false, epoch: reply["epoch"]?.string ?? "",
                            runStartedSeq: reply["runStartedSeq"]?.int ?? 0, running: reply["running"]?.bool ?? false,
                            pid: reply["pid"]?.int.map(Int32.init), status: reply["status"]?.int.map(Int32.init))
    }

    public func unsubscribe(session: String) async throws {
        _ = try await request("unsubscribe", ["session": .string(session)])
    }

    public func list() async throws -> [SessionSummary] {
        try await request("list")["sessions"]?.array?.compactMap(SessionSummary.init(wire:)) ?? []
    }

    public func forget(session: String) async throws {
        _ = try await request("forget", ["session": .string(session)])
    }

    /// Asks the helper to exit, so that the next connection starts the
    /// version now on disk. Refused while agents run, unless `force` — which
    /// stops them first.
    public func quit(force: Bool = false) async throws {
        do {
            _ = try await request("quit", ["force": .bool(force)], timeout: .seconds(60))
        } catch Failure.closed {
            // The helper went before its reply was read: that is the quit.
        }
    }

    public func close() {
        transport.close()
    }
}
