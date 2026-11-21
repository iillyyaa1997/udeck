import Foundation

/// One line Claude Code wrote on stdout in stream-json mode, sorted by kind.
///
/// The shapes are the ones the official Agent SDK reads (its `sdk.d.ts`, 0.3.330,
/// against Claude Code 2.1.330 — recorded in Tests/UDeckAgentsTests/Fixtures).
/// Every case keeps the whole message as `raw`: what uDeck draws today is a
/// small part of it, and a field it ignores now is still there tomorrow.
public enum ClaudeInbound: Sendable, Equatable {
    /// `system`/`init`: the session started (or a new turn re-announced it).
    case sessionStarted(ClaudeSessionInfo, raw: JSONValue)
    /// An assistant message: text, thinking and tool calls, in order. With
    /// `--include-partial-messages` its pieces arrive first as `.partial`, and
    /// this whole message closes them.
    case assistant(ClaudeAssistantMessage, raw: JSONValue)
    /// A piece of the assistant message being written (`stream_event`).
    case partial(ClaudeStreamEvent, raw: JSONValue)
    /// A user-role message — for a client like uDeck, almost always the results
    /// of tool calls the assistant made.
    case toolResults([ClaudeToolResult], raw: JSONValue)
    /// The end of one turn: Claude is waiting for the next message.
    case turnFinished(ClaudeTurnResult, raw: JSONValue)
    /// The account's limits, as the API reported them during the turn.
    case rateLimit(ClaudeRateLimit, raw: JSONValue)
    /// The CLI asks uDeck something and waits for one control_response.
    case request(ClaudeControlRequest)
    /// The CLI answers a control_request uDeck sent.
    case response(ClaudeControlResponse)
    /// The CLI withdraws a request it sent (a prompt answered elsewhere, timed
    /// out, or no longer needed). Whatever uDeck shows for it has to go.
    case cancelled(requestID: String, raw: JSONValue)
    /// Any other `system` message (status, compaction, hooks, retries…).
    case system(subtype: String, raw: JSONValue)
    /// A message of a type uDeck does not know.
    case other(type: String, raw: JSONValue)

    public init?(line: Substring) {
        guard let value = JSONValue.line(line) else { return nil }
        self.init(value)
    }

    public init(_ raw: JSONValue) {
        let type = raw["type"]?.string ?? ""
        switch type {
        case "system" where raw["subtype"]?.string == "init":
            self = .sessionStarted(ClaudeSessionInfo(raw), raw: raw)
        case "system":
            self = .system(subtype: raw["subtype"]?.string ?? "", raw: raw)
        case "assistant":
            self = .assistant(ClaudeAssistantMessage(raw), raw: raw)
        case "stream_event":
            self = .partial(ClaudeStreamEvent(raw), raw: raw)
        case "user":
            self = .toolResults(ClaudeToolResult.all(in: raw), raw: raw)
        case "result":
            self = .turnFinished(ClaudeTurnResult(raw), raw: raw)
        case "rate_limit_event":
            self = .rateLimit(ClaudeRateLimit(raw["rate_limit_info"] ?? .null), raw: raw)
        case "control_request":
            self = .request(ClaudeControlRequest(raw))
        case "control_response":
            self = .response(ClaudeControlResponse(raw))
        case "control_cancel_request":
            self = .cancelled(requestID: raw["request_id"]?.string ?? "", raw: raw)
        default:
            self = .other(type: type, raw: raw)
        }
    }
}

public struct ClaudeSessionInfo: Sendable, Equatable {
    public let sessionID: String
    public let model: String
    public let permissionMode: String
    public let cwd: String
    public let version: String
    public let slashCommands: [String]
    /// Protocol features this CLI supports — feature-detect on these, never on
    /// the version (`interrupt_cancel_queued_v1`, `ask_user_question_unanswered_v1`…).
    public let capabilities: Set<String>

    init(_ raw: JSONValue) {
        sessionID = raw["session_id"]?.string ?? ""
        model = raw["model"]?.string ?? ""
        permissionMode = raw["permissionMode"]?.string ?? ""
        cwd = raw["cwd"]?.string ?? ""
        version = raw["claude_code_version"]?.string ?? ""
        slashCommands = raw["slash_commands"]?.array?.compactMap(\.string) ?? []
        capabilities = Set(raw["capabilities"]?.array?.compactMap(\.string) ?? [])
    }
}

public struct ClaudeAssistantMessage: Sendable, Equatable {
    public enum Block: Sendable, Equatable {
        case text(String)
        case thinking(String)
        case toolUse(id: String, name: String, input: JSONValue)
        case other(type: String, raw: JSONValue)
    }

    public let id: String
    public let model: String
    public let blocks: [Block]
    /// Set when the message came from a subagent: the tool call that started it.
    public let parentToolUseID: String?
    public let sessionID: String

    init(_ raw: JSONValue) {
        let message = raw["message"] ?? .null
        id = message["id"]?.string ?? ""
        model = message["model"]?.string ?? ""
        parentToolUseID = raw["parent_tool_use_id"]?.string
        sessionID = raw["session_id"]?.string ?? ""
        blocks = (message["content"]?.array ?? []).map { block in
            switch block["type"]?.string ?? "" {
            case "text": .text(block["text"]?.string ?? "")
            case "thinking": .thinking(block["thinking"]?.string ?? "")
            case "tool_use":
                .toolUse(id: block["id"]?.string ?? "", name: block["name"]?.string ?? "",
                         input: block["input"] ?? .object([:]))
            case let other: .other(type: other, raw: block)
            }
        }
    }

    /// The text blocks joined, for a one-line preview.
    public var text: String {
        blocks.compactMap { if case .text(let text) = $0 { text } else { nil } }.joined(separator: "\n")
    }
}

/// One `stream_event`: the Anthropic API's own streaming events, passed through.
/// uDeck needs the deltas; the rest (message and block starts and stops) only
/// mark where a block begins and ends.
public struct ClaudeStreamEvent: Sendable, Equatable {
    public enum Delta: Sendable, Equatable {
        case text(String)
        case thinking(String)
        /// A piece of a tool call's input JSON, which is only valid once whole.
        case toolInput(String)
    }

    /// `message_start`, `content_block_start`, `content_block_delta`, …
    public let type: String
    /// Which content block of the message the event belongs to.
    public let index: Int?
    public let delta: Delta?
    public let parentToolUseID: String?

    init(_ raw: JSONValue) {
        let event = raw["event"] ?? .null
        type = event["type"]?.string ?? ""
        index = event["index"]?.int
        parentToolUseID = raw["parent_tool_use_id"]?.string
        let delta = event["delta"] ?? .null
        switch delta["type"]?.string {
        case "text_delta": self.delta = .text(delta["text"]?.string ?? "")
        case "thinking_delta": self.delta = .thinking(delta["thinking"]?.string ?? "")
        case "input_json_delta": self.delta = .toolInput(delta["partial_json"]?.string ?? "")
        default: self.delta = nil
        }
    }
}

public struct ClaudeToolResult: Sendable, Equatable {
    public let toolUseID: String
    public let isError: Bool
    /// The result's text parts joined; images and other parts are in `content`.
    public let text: String
    public let content: JSONValue

    static func all(in raw: JSONValue) -> [ClaudeToolResult] {
        (raw["message"]?["content"]?.array ?? []).compactMap { block in
            guard block["type"]?.string == "tool_result" else { return nil }
            let content = block["content"] ?? .null
            let text: String
            if let string = content.string {
                text = string
            } else {
                text = (content.array ?? []).compactMap { $0["type"]?.string == "text" ? $0["text"]?.string : nil }
                    .joined(separator: "\n")
            }
            return ClaudeToolResult(toolUseID: block["tool_use_id"]?.string ?? "",
                                    isError: block["is_error"]?.bool ?? false, text: text, content: content)
        }
    }
}

public struct ClaudeTurnResult: Sendable, Equatable {
    public let isError: Bool
    public let subtype: String
    public let turns: Int
    public let result: String
    public let costUSD: Double?
    public let sessionID: String

    init(_ raw: JSONValue) {
        isError = raw["is_error"]?.bool ?? false
        subtype = raw["subtype"]?.string ?? ""
        turns = raw["num_turns"]?.int ?? 0
        result = raw["result"]?.string ?? ""
        costUSD = raw["total_cost_usd"]?.number
        sessionID = raw["session_id"]?.string ?? ""
    }
}

/// One window of an account's limits: how much is used and when it starts over.
public struct UsageWindow: Sendable, Equatable {
    /// 0…1.
    public let used: Double
    public let resetsAt: Date?
}

public struct ClaudeRateLimit: Sendable, Equatable {
    public let status: String
    /// The window the event is about (`five_hour`, `seven_day`, …).
    public let window: String
    public let usage: UsageWindow

    init(_ raw: JSONValue) {
        status = raw["status"]?.string ?? ""
        window = raw["rateLimitType"]?.string ?? ""
        usage = UsageWindow(used: raw["utilization"]?.number ?? 0,
                            resetsAt: raw["resetsAt"]?.number.map { Date(timeIntervalSince1970: $0) })
    }
}

/// A control_request the CLI sent to uDeck.
public struct ClaudeControlRequest: Sendable, Equatable {
    public let requestID: String
    public let subtype: String
    public let body: JSONValue
    public let raw: JSONValue

    init(_ raw: JSONValue) {
        self.raw = raw
        requestID = raw["request_id"]?.string ?? ""
        body = raw["request"] ?? .null
        subtype = body["subtype"]?.string ?? ""
    }

    /// `can_use_tool`: the CLI wants a decision before a tool runs. Questions
    /// (AskUserQuestion) come this way too — see `questions`.
    public var permission: ClaudePermissionAsk? {
        subtype == "can_use_tool" ? ClaudePermissionAsk(body) : nil
    }
}

public struct ClaudePermissionAsk: Sendable, Equatable {
    public let toolName: String
    public let displayName: String
    public let input: JSONValue
    public let title: String?
    /// Why the ask escalated; may carry ANSI escapes — strip before showing.
    public let reason: String?
    public let reasonType: String?
    /// The persistent "don't ask again" choice must not be offered.
    public let noAlwaysAllow: Bool
    /// The decline option is the default; approving must not be one stray key.
    public let defaultToNo: Bool
    /// No one-tap answer anywhere: the user has to open the session and answer
    /// on its own card (a panel card or a notification may only offer "Open").
    public let requiresUserInteraction: Bool
    /// A user-configured ask rule forced this prompt — treat it as wanting a
    /// person, whatever automatic approval would say.
    public let matchedAskRule: JSONValue?
    /// Rules the CLI proposes for "always allow"; echoed back when chosen.
    public let suggestions: [JSONValue]

    init(_ body: JSONValue) {
        toolName = body["tool_name"]?.string ?? ""
        displayName = body["display_name"]?.string ?? toolName
        input = body["input"] ?? .object([:])
        title = body["title"]?.string
        reason = body["decision_reason"]?.string
        reasonType = body["decision_reason_type"]?.string
        noAlwaysAllow = body["suppress_always_allow_rule"]?.bool ?? false
        defaultToNo = body["default_to_no"]?.bool ?? false
        requiresUserInteraction = body["requires_user_interaction"]?.bool ?? false
        matchedAskRule = body["matched_ask_rule"]
        suggestions = body["permission_suggestions"]?.array ?? []
    }

    /// Whether a quick surface — the panel card, the mini window, a notification —
    /// may answer this ask with one tap. AskUserQuestion is answered with its
    /// options, which is always a choice the user makes, so it may; a tool ask
    /// may only when none of the CLI's flags says it needs the session itself.
    public var answerableFromSurface: Bool {
        if questions != nil { return true }
        return !requiresUserInteraction && !defaultToNo && matchedAskRule == nil
    }

    /// The questions, when this is an AskUserQuestion ask rather than a tool
    /// that needs permission.
    public var questions: [AgentQuestion]? {
        guard toolName == "AskUserQuestion" else { return nil }
        return (input["questions"]?.array ?? []).map(AgentQuestion.init)
    }
}

/// A question an agent asks, with the choices it offers.
public struct AgentQuestion: Sendable, Equatable {
    public struct Option: Sendable, Equatable {
        public let label: String
        public let description: String?
        public let preview: String?
    }

    public let question: String
    public let header: String?
    public let multiSelect: Bool
    public let options: [Option]

    init(_ raw: JSONValue) {
        question = raw["question"]?.string ?? ""
        header = raw["header"]?.string
        multiSelect = raw["multiSelect"]?.bool ?? false
        options = (raw["options"]?.array ?? []).map {
            Option(label: $0["label"]?.string ?? "", description: $0["description"]?.string,
                   preview: $0["preview"]?.string)
        }
    }
}

/// The CLI's answer to a control_request uDeck sent.
public struct ClaudeControlResponse: Sendable, Equatable {
    public let requestID: String
    public let succeeded: Bool
    public let body: JSONValue
    public let error: String?
    public let raw: JSONValue

    init(_ raw: JSONValue) {
        self.raw = raw
        let response = raw["response"] ?? .null
        requestID = response["request_id"]?.string ?? ""
        succeeded = response["subtype"]?.string == "success"
        body = response["response"] ?? .object([:])
        error = response["error"]?.string
    }
}

/// `get_usage`'s answer: the plan and its limit windows.
public struct ClaudeUsage: Sendable, Equatable {
    public let subscription: String?
    public let fiveHour: UsageWindow?
    public let sevenDay: UsageWindow?

    public init(_ body: JSONValue) {
        subscription = body["subscription_type"]?.string
        let limits = body["rate_limits"] ?? .null
        fiveHour = Self.window(limits["five_hour"])
        sevenDay = Self.window(limits["seven_day"])
    }

    private static func window(_ raw: JSONValue?) -> UsageWindow? {
        guard let raw, let percent = raw["utilization"]?.number else { return nil }
        return UsageWindow(used: percent / 100, resetsAt: raw["resets_at"]?.string.flatMap(parseDate))
    }
}

/// `get_context_usage`'s answer, the part a context bar needs.
public struct ClaudeContextUsage: Sendable, Equatable {
    public let tokens: Int
    public let window: Int
    public let percent: Double
    public let model: String

    public init(_ body: JSONValue) {
        tokens = body["totalTokens"]?.int ?? 0
        window = body["maxTokens"]?.int ?? 0
        percent = body["percentage"]?.number ?? (window > 0 ? Double(tokens) / Double(window) * 100 : 0)
        model = body["model"]?.string ?? ""
    }
}

/// ISO 8601 with or without fractional seconds, as both agents write it.
func parseDate(_ text: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: text) { return date }
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    if let date = plain.date(from: text) { return date }
    // Python writes microseconds ("…00.303187+00:00"), which the formatter does
    // not take; the second is enough for a reset time.
    if let dot = text.firstIndex(of: "."),
       let end = text[dot...].firstIndex(where: { !$0.isNumber && $0 != "." }) {
        return plain.date(from: String(text[..<dot]) + String(text[end...]))
    }
    return nil
}
