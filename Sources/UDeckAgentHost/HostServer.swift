import Foundation
import UDeckAgents

/// The helper's listener: takes uDeck's XPC connections, has the system hold
/// each to uDeck's code requirement, and runs each connection's requests
/// against the `AgentHost`.
public final class HostServer: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    public enum Listening: Sendable {
        /// The launchd job's Mach service: how the real helper listens.
        case machService(String)
        /// An in-process listener, reached through `endpoint`: for tests.
        case anonymous
    }

    public let host: AgentHost
    public let info: HostInfo
    /// What every message from uDeck must satisfy.
    public let peerRequirement: String
    public static let maxConnections = 16
    public static let helloDeadline: Duration = .seconds(10)
    private let listener: NSXPCListener
    private let log: @Sendable (String) -> Void
    private let onQuit: @Sendable () -> Void
    private let state = Guarded(State())

    private struct State {
        var connections: [ObjectIdentifier: Connection] = [:]
        var stopped = false
        var lastActivity = ContinuousClock.now
    }

    public init(listening: Listening, peerRequirement: String, host: AgentHost, info: HostInfo,
                log: @escaping @Sendable (String) -> Void = { _ in }, onQuit: @escaping @Sendable () -> Void = {})
        throws
    {
        try CodeIdentity.validate(peerRequirement)
        self.peerRequirement = peerRequirement
        self.host = host
        self.info = info
        self.log = log
        self.onQuit = onQuit
        switch listening {
        case .machService(let name): listener = NSXPCListener(machServiceName: name)
        case .anonymous: listener = NSXPCListener.anonymous()
        }
        super.init()
        listener.delegate = self
    }

    /// For an anonymous listener: what a client connects to.
    public var endpoint: NSXPCListenerEndpoint { listener.endpoint }

    public func start() {
        listener.resume()
    }

    /// Stops taking connections. Those already open keep working until
    /// `closeConnections`.
    public func stopListening() {
        state.withLock { $0.stopped = true }
        listener.invalidate()
    }

    public func closeConnections() {
        let connections = state.withLock { state -> [Connection] in
            defer { state.connections.removeAll() }
            return Array(state.connections.values)
        }
        connections.forEach { $0.transport.close() }
    }

    public var connectionCount: Int { state.withLock { $0.connections.count } }

    /// When a connection last opened or closed.
    public var lastActivity: ContinuousClock.Instant { state.withLock { $0.lastActivity } }

    public func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        let pid = newConnection.processIdentifier
        let admitted = state.withLock { state -> Bool in
            !state.stopped && state.connections.count < Self.maxConnections
        }
        guard admitted else {
            log("turned away pid \(pid): stopping or \(Self.maxConnections) connections open")
            return false
        }
        // The system checks every message this connection receives against
        // the requirement, and invalidates the connection at the first that
        // fails it — before anything reaches the code below.
        let connection = Connection(transport: XPCLines(newConnection, requirement: peerRequirement))
        state.withLock {
            $0.connections[ObjectIdentifier(connection)] = connection
            $0.lastActivity = .now
        }
        log("connected: pid \(pid)")
        Task { [weak self] in
            await self?.serve(connection)
            self?.state.withLock {
                $0.connections[ObjectIdentifier(connection)] = nil
                $0.lastActivity = .now
            }
            self?.log("disconnected: pid \(pid)")
        }
        Task {
            try? await Task.sleep(for: Self.helloDeadline)
            if !connection.greeted { connection.transport.close() }
        }
        return true
    }

    private func serve(_ connection: Connection) async {
        for await text in connection.transport.lines {
            guard let request = JSONValue.line(Substring(text)), request.object != nil else {
                connection.reply(nil, failure: AgentHost.Failure(.badRequest, "not a JSON object"))
                continue
            }
            let id = request["id"]
            let op = request["op"]?.string ?? ""
            // A terminate takes time: which run it stops is settled here, in
            // order with everything else; the waiting goes on beside the
            // requests behind it.
            if op == "terminate", connection.greeted {
                do throws(AgentHost.Failure) {
                    guard let session = request["session"]?.string, !session.isEmpty else {
                        throw AgentHost.Failure(.badRequest, "terminate needs a session")
                    }
                    let (run, status) = try await host.runToTerminate(session: session)
                    if let status {
                        connection.reply(id, ok: ["status": .number(Double(status))])
                        continue
                    }
                    let grace = Duration.milliseconds(request["graceMs"]?.int ?? 3000)
                    Task {
                        let status = await self.host.terminate(run, grace: grace)
                        connection.reply(id, ok: ["status": .number(Double(status))])
                    }
                } catch {
                    connection.reply(id, failure: error)
                }
                continue
            }
            await answer(request, id: id, op: op, on: connection)
        }
        await host.drop(connection)
    }

    private func answer(_ request: JSONValue, id: JSONValue?, op: String, on connection: Connection) async {
        do throws(AgentHost.Failure) {
            guard let result = try await handle(request, op: op, on: connection) else { return }
            connection.reply(id, ok: result)
            if op == "quit" {
                // The reply has left this process; whether uDeck read it before
                // the helper went is not known — uDeck takes a closed
                // connection after quit as done.
                let onQuit = self.onQuit
                connection.transport.afterPendingSends { onQuit() }
            }
        } catch {
            connection.reply(id, failure: error)
        }
    }

    /// The reply's body; nil when the reply was already sent (subscribe).
    private func handle(_ request: JSONValue, op: String, on connection: Connection) async throws(AgentHost.Failure)
        -> JSONValue?
    {
        if op == "hello" {
            let version = request["protocol"]?.int ?? 0
            guard HostWire.protocolVersions.contains(version) else {
                throw AgentHost.Failure(.protocolMismatch,
                                        "helper speaks \(HostWire.protocolVersions), not \(version)")
            }
            connection.greeted = true
            let sessions = await host.list()
            return ["version": .string(info.version), "instance": .string(info.instance),
                    "pid": .number(Double(info.pid)), "protocol": .number(Double(version)),
                    "sessions": .array(sessions.map(\.wire))]
        }
        guard connection.greeted else { throw AgentHost.Failure(.helloFirst, "send hello first") }
        func session() throws(AgentHost.Failure) -> String {
            guard let id = request["session"]?.string, !id.isEmpty else {
                throw AgentHost.Failure(.badRequest, "\(op) needs a session")
            }
            return id
        }
        switch op {
        case "spawn":
            guard let spec = SpawnSpec(wire: request) else { throw AgentHost.Failure(.badRequest, "bad spawn") }
            let (pid, startedSeq) = try await host.spawn(spec)
            return ["pid": .number(Double(pid)), "startedSeq": .number(Double(startedSeq))]
        case "write":
            guard let line = request["line"]?.string else { throw AgentHost.Failure(.badRequest, "write needs a line") }
            try await host.write(session: try session(), line: line, tag: request["tag"]?.string)
            return [:]
        case "closeInput":
            try await host.closeInput(session: try session())
            return [:]
        case "subscribe":
            let id = request["id"] ?? .null
            try await host.subscribe(session: try session(), after: request["after"]?.int ?? 0,
                                     epoch: request["epoch"]?.string, sink: connection) { state in
                var body: [String: JSONValue] = [
                    "firstSeq": .number(Double(state.firstSeq)), "lastSeq": .number(Double(state.lastSeq)),
                    "gap": .bool(state.gap), "epoch": .string(state.epoch),
                    "runStartedSeq": .number(Double(state.runStartedSeq)), "running": .bool(state.running),
                ]
                if let pid = state.pid { body["pid"] = .number(Double(pid)) }
                if let status = state.status { body["status"] = .number(Double(status)) }
                return Connection.encode(["id": id, "ok": .object(body)])
            }
            return nil
        case "unsubscribe":
            await host.unsubscribe(session: try session(), sink: connection)
            return [:]
        case "list":
            return ["sessions": .array(await host.list().map(\.wire))]
        case "forget":
            try await host.forget(session: try session())
            return [:]
        case "quit":
            // Checked and closed in one step: no spawn gets in between.
            guard await host.quiesce(force: request["force"]?.bool == true) else {
                throw AgentHost.Failure(.stillRunning, "agents are running; quit when they are done, or force")
            }
            return [:]
        default:
            throw AgentHost.Failure(.badRequest, "unknown op \(op)")
        }
    }

    final class Connection: HostSink, @unchecked Sendable {
        let transport: XPCLines
        private let flag = Guarded(false)

        init(transport: XPCLines) { self.transport = transport }

        var greeted: Bool {
            get { flag.withLock { $0 } }
            set { flag.withLock { $0 = newValue } }
        }

        func deliver(_ line: String) { transport.send(line) }

        func reply(_ id: JSONValue?, ok result: JSONValue) {
            if let line = Self.encode(["id": id ?? .null, "ok": result]) { transport.send(line) }
        }

        func reply(_ id: JSONValue?, failure: AgentHost.Failure) {
            let body: JSONValue = ["id": id ?? .null, "error": ["code": .string(failure.code.rawValue),
                                                               "message": .string(failure.message)]]
            if let line = Self.encode(body) { transport.send(line) }
        }

        static func encode(_ value: JSONValue) -> String? { try? value.encodedLine() }
    }
}
