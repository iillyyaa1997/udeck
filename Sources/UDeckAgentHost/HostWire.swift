import Foundation
import UDeckAgents

/// The helper's protocol: one JSON object per XPC message, both ways.
///
/// uDeck sends requests — `{"id": 7, "op": "write", …}` — and gets exactly one
/// reply to each, `{"id": 7, "ok": {…}}` or `{"id": 7, "error": {"code": …,
/// "message": …}}`, in the order it sent them. Between replies come events,
/// `{"ev": "line", "session": …, "seq": …, …}`, for the sessions it subscribed
/// to. The first request on a connection is `hello`, which names the protocol
/// version; the helper speaks only versions it lists, so an old uDeck and a new
/// helper (or the other way round, mid-update) find out at once.
///
/// | op          | fields                                                              | ok                       |
/// |-------------|---------------------------------------------------------------------|--------------------------|
/// | hello       | protocol, client                                                    | HostInfo + sessions          |
/// | spawn       | session, executable, arguments, environment, directory, stopLine?  | pid                          |
/// | write       | session, line, tag?                                                 | {} (the input event follows) |
/// | closeInput  | session                                                             | {}                           |
/// | terminate   | session, graceMs                                                    | status                       |
/// | subscribe   | session, after, epoch?                                              | firstSeq, lastSeq, gap, epoch|
/// | unsubscribe | session                                                             | {}                           |
/// | list        |                                                                     | sessions                     |
/// | forget      | session                                                             | {}                           |
/// | quit        | force?                                                              | {} (then the helper goes)    |
///
/// `subscribe` sends the journal's events after `after`, then its reply, then
/// every new event as it happens. `epoch` names the journal the position is
/// in; a session forgotten and started again has a new one, and a position in
/// the old one is read as "from the start", flagged as a gap. Requests on a
/// connection are answered in order, except `terminate` and `quit`, which take
/// time and are answered when done (replies carry the request's id). `quit`
/// is refused while agents run unless `force`: an update must not cut a turn
/// short — the helper keeps running the old version until they finish.
public enum HostWire {
    public static let protocolVersions = [1]

    public enum ErrorCode: String, Sendable {
        case badRequest
        case helloFirst
        case protocolMismatch
        case unknownSession
        case sessionExists
        case notRunning
        case stillRunning
        case cannotStart
        case refused
        case stopping
        case backlogged
    }
}

/// What it takes to start an agent. The helper adds nothing to it: the
/// environment is exactly what uDeck resolved from the user's shell.
public struct SpawnSpec: Sendable, Equatable {
    public var session: String
    public var executable: String
    public var arguments: [String]
    public var environment: [String: String]
    public var directory: String
    /// Written to the agent's stdin when the helper has to stop it (logout,
    /// shutdown, quit) before stdin is closed. uDeck puts the agent's own
    /// "interrupt" message here, so a turn ends cleanly and its transcript is
    /// whole; the helper does not know what the line means.
    public var stopLine: String?

    public init(session: String, executable: String, arguments: [String], environment: [String: String],
                directory: String, stopLine: String? = nil)
    {
        self.session = session
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.directory = directory
        self.stopLine = stopLine
    }

    var wire: [String: JSONValue] {
        var fields: [String: JSONValue] = [
            "session": .string(session),
            "executable": .string(executable),
            "arguments": .array(arguments.map(JSONValue.string)),
            "environment": .object(environment.mapValues(JSONValue.string)),
            "directory": .string(directory),
        ]
        if let stopLine { fields["stopLine"] = .string(stopLine) }
        return fields
    }

    init?(wire value: JSONValue) {
        guard let session = value["session"]?.string, !session.isEmpty,
              let executable = value["executable"]?.string,
              let directory = value["directory"]?.string
        else { return nil }
        let arguments = value["arguments"]?.array?.compactMap(\.string) ?? []
        let environment = value["environment"]?.object?.compactMapValues(\.string) ?? [:]
        self.init(session: session, executable: executable, arguments: arguments, environment: environment,
                  directory: directory, stopLine: value["stopLine"]?.string)
    }
}

/// One session as the helper holds it.
public struct SessionSummary: Sendable, Equatable {
    public let session: String
    public let pid: Int32?
    public let running: Bool
    public let firstSeq: Int
    public let lastSeq: Int
    /// The exit status, once the agent has exited.
    public let status: Int32?
    public let startedAt: Date
    /// Names the session's journal (see `subscribe`).
    public let epoch: String

    var wire: JSONValue {
        var fields: [String: JSONValue] = [
            "session": .string(session),
            "running": .bool(running),
            "firstSeq": .number(Double(firstSeq)),
            "lastSeq": .number(Double(lastSeq)),
            "startedAt": .number((startedAt.timeIntervalSince1970 * 1000).rounded()),
            "epoch": .string(epoch),
        ]
        if let pid { fields["pid"] = .number(Double(pid)) }
        if let status { fields["status"] = .number(Double(status)) }
        return .object(fields)
    }

    init(session: String, pid: Int32?, running: Bool, firstSeq: Int, lastSeq: Int, status: Int32?,
         startedAt: Date, epoch: String)
    {
        self.epoch = epoch
        self.session = session
        self.pid = pid
        self.running = running
        self.firstSeq = firstSeq
        self.lastSeq = lastSeq
        self.status = status
        self.startedAt = startedAt
    }

    init?(wire value: JSONValue) {
        guard let session = value["session"]?.string, let running = value["running"]?.bool else { return nil }
        self.init(session: session, pid: value["pid"]?.int.map(Int32.init), running: running,
                  firstSeq: value["firstSeq"]?.int ?? 1, lastSeq: value["lastSeq"]?.int ?? 0,
                  status: value["status"]?.int.map(Int32.init),
                  startedAt: Date(timeIntervalSince1970: (value["startedAt"]?.number ?? 0) / 1000),
                  epoch: value["epoch"]?.string ?? "")
    }
}

/// Who answered `hello`.
public struct HostInfo: Sendable, Equatable {
    /// The helper's own version (the uDeck it was shipped in).
    public let version: String
    /// Changes every time the helper starts: a uDeck that reconnects to a
    /// different instance knows every journal it kept a position in is gone
    /// (and every agent with it).
    public let instance: String
    public let pid: Int32
    public let protocolVersion: Int

    public init(version: String, instance: String = UUID().uuidString, pid: Int32 = getpid(),
                protocolVersion: Int = HostWire.protocolVersions.last!)
    {
        self.version = version
        self.instance = instance
        self.pid = pid
        self.protocolVersion = protocolVersion
    }
}
