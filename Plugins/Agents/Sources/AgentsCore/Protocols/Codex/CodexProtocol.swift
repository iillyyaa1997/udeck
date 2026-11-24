import Foundation
import UDeckAgents

/// One line `codex app-server` wrote on stdout, sorted by kind.
///
/// app-server speaks JSON-RPC 2.0 without the `"jsonrpc"` field, one message per
/// line (OpenAI's Codex App Server documentation; the schema uDeck was built
/// against is the one `codex app-server generate-json-schema` writes for
/// codex-cli 0.160.0, recorded in Tests/UDeckAgentsTests/Fixtures).
public enum CodexInbound: Sendable, Equatable {
    /// The answer to a request uDeck sent.
    case response(id: JSONValue, result: JSONValue)
    case failure(id: JSONValue, code: Int, message: String)
    /// The server asks uDeck something and waits for one answer — approvals.
    case request(id: JSONValue, method: String, params: JSONValue)
    /// The server tells uDeck something: streamed items, status, usage, limits.
    case notification(method: String, params: JSONValue)
    case other(JSONValue)

    public init?(line: Substring) {
        guard let value = JSONValue.line(line) else { return nil }
        self.init(value)
    }

    public init(_ raw: JSONValue) {
        let id = raw["id"]
        let method = raw["method"]?.string
        switch (id, method) {
        case (.some(let id), .some(let method)):
            self = .request(id: id, method: method, params: raw["params"] ?? .null)
        case (nil, .some(let method)):
            self = .notification(method: method, params: raw["params"] ?? .null)
        case (.some(let id), nil) where raw["error"] != nil:
            let error = raw["error"] ?? .null
            self = .failure(id: id, code: error["code"]?.int ?? 0, message: error["message"]?.string ?? "")
        case (.some(let id), nil):
            self = .response(id: id, result: raw["result"] ?? .null)
        default:
            self = .other(raw)
        }
    }

    /// An approval the server is waiting for, when this is one.
    public var approval: CodexApprovalAsk? {
        guard case .request(let id, let method, let params) = self, method.hasSuffix("/requestApproval") else {
            return nil
        }
        return CodexApprovalAsk(id: id, method: method, params: params)
    }
}

/// `item/commandExecution/requestApproval`, `item/fileChange/requestApproval` and
/// whatever else ends in `/requestApproval`.
public struct CodexApprovalAsk: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case command(String)
        case fileChange
        case other(String)
    }

    public let id: JSONValue
    public let method: String
    public let kind: Kind
    public let threadID: String
    public let turnID: String
    public let itemID: String
    public let reason: String?
    public let params: JSONValue

    init(id: JSONValue, method: String, params: JSONValue) {
        self.id = id
        self.method = method
        self.params = params
        threadID = params["threadId"]?.string ?? ""
        turnID = params["turnId"]?.string ?? ""
        itemID = params["itemId"]?.string ?? ""
        reason = params["reason"]?.string
        switch method {
        case "item/commandExecution/requestApproval": kind = .command(params["command"]?.string ?? "")
        case "item/fileChange/requestApproval": kind = .fileChange
        default: kind = .other(method)
        }
    }
}

/// An item of a Codex turn — a message, a command, a file change — as
/// `item/started` and `item/completed` carry it.
public struct CodexItem: Sendable, Equatable {
    public let id: String
    public let type: String
    /// agentMessage, userMessage and reasoning text; the command for a command.
    public let text: String
    public let status: String?
    public let raw: JSONValue

    public init(_ raw: JSONValue) {
        self.raw = raw
        id = raw["id"]?.string ?? ""
        type = raw["type"]?.string ?? ""
        status = raw["status"]?.string
        switch type {
        case "agentMessage", "reasoning":
            text = raw["text"]?.string ?? ""
        case "userMessage":
            text = (raw["content"]?.array ?? []).compactMap { $0["text"]?.string }.joined(separator: "\n")
        case "commandExecution":
            text = raw["command"]?.string ?? ""
        default:
            text = ""
        }
    }
}

/// `account/rateLimits/updated` and `account/rateLimits/read`: the windows of the
/// signed-in account (the primary window is the 5-hour one).
public struct CodexRateLimits: Sendable, Equatable {
    public struct Window: Sendable, Equatable {
        public let usage: UsageWindow
        public let minutes: Int?
    }

    public let primary: Window?
    public let secondary: Window?

    public init(_ limits: JSONValue) {
        primary = Self.window(limits["primary"])
        secondary = Self.window(limits["secondary"])
    }

    private static func window(_ raw: JSONValue?) -> Window? {
        guard let raw, let percent = raw["usedPercent"]?.number else { return nil }
        return Window(usage: UsageWindow(used: percent / 100,
                                         resetsAt: raw["resetsAt"]?.number.map { Date(timeIntervalSince1970: $0) }),
                      minutes: raw["windowDurationMins"]?.int)
    }
}

/// What uDeck writes to `codex app-server`.
public enum CodexOutbound {
    public static func request(id: Int, _ method: String, _ params: JSONValue = .object([:])) -> JSONValue {
        ["id": .number(Double(id)), "method": .string(method), "params": params]
    }

    public static func notification(_ method: String) -> JSONValue { ["method": .string(method)] }

    public static func initialize(id: Int, client: String, version: String) -> JSONValue {
        request(id: id, "initialize", ["clientInfo": ["name": .string(client), "version": .string(version)]])
    }

    /// The notification that has to follow the answer to `initialize`.
    public static let initialized = notification("initialized")

    /// - Parameters:
    ///   - approval: `untrusted`, `on-request` or `never`.
    ///   - sandbox: `read-only`, `workspace-write` or `danger-full-access`.
    public static func startThread(id: Int, cwd: String, approval: String, sandbox: String,
                                   model: String? = nil, ephemeral: Bool = false) -> JSONValue
    {
        var params: [String: JSONValue] = ["cwd": .string(cwd), "approvalPolicy": .string(approval),
                                           "sandbox": .string(sandbox)]
        if let model { params["model"] = .string(model) }
        if ephemeral { params["ephemeral"] = true }
        return request(id: id, "thread/start", .object(params))
    }

    public static func resumeThread(id: Int, threadID: String) -> JSONValue {
        request(id: id, "thread/resume", ["threadId": .string(threadID)])
    }

    public static func startTurn(id: Int, threadID: String, text: String) -> JSONValue {
        request(id: id, "turn/start", ["threadId": .string(threadID),
                                       "input": [["type": "text", "text": .string(text)]]])
    }

    public static func interrupt(id: Int, threadID: String, turnID: String) -> JSONValue {
        request(id: id, "turn/interrupt", ["threadId": .string(threadID), "turnId": .string(turnID)])
    }

    /// The answer to an approval. For a command the 0.160.0 schema lists
    /// `"accept"`, `"acceptForSession"`, `"decline"`, `"cancel"` and an object,
    /// `{"acceptWithExecpolicyAmendment": {"execpolicy_amendment": [...]}}`, that
    /// also allows matching commands from now on. Codex has no "always" beyond
    /// that and the session — the approval card offers what the provider has.
    public static func decide(_ ask: CodexApprovalAsk, _ decision: JSONValue) -> JSONValue {
        ["id": ask.id, "result": ["decision": decision]]
    }

    public static func rateLimits(id: Int) -> JSONValue { request(id: id, "account/rateLimits/read") }
}
