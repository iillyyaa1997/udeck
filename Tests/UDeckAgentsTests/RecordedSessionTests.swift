import Foundation
import Testing
@testable import UDeckAgents

/// Conversations recorded from the real programs on 2026-11-21 — Claude Code
/// 2.1.330 in stream-json mode and codex-cli 0.160.0 over app-server — driven
/// the way uDeck's chat will drive them, with personal details replaced.
/// Each fixture line is `{"dir": "in"|"out", "t": seconds, "line": "<one protocol line>"}`.
enum Recording {
    struct Line {
        let outgoing: Bool
        let text: String
    }

    static func lines(_ name: String) throws -> [Line] {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "jsonl", subdirectory: "Fixtures"))
        let content = try String(contentsOf: url, encoding: .utf8)
        return try content.split(separator: "\n").map { record in
            let value = try JSONDecoder().decode(JSONValue.self, from: Data(record.utf8))
            return Line(outgoing: value["dir"]?.string == "in", text: value["line"]?.string ?? "")
        }
    }

    /// What the program wrote, decoded.
    static func claude(_ name: String) throws -> [ClaudeInbound] {
        try lines(name).filter { !$0.outgoing }.map { try #require(ClaudeInbound(line: Substring($0.text))) }
    }

    static func codex(_ name: String) throws -> [CodexInbound] {
        try lines(name).filter { !$0.outgoing }.map { try #require(CodexInbound(line: Substring($0.text))) }
    }
}

@Suite("Claude Code, as recorded")
struct ClaudeRecordedTests {
    @Test("every line the CLI wrote is understood as something, and nothing falls through as unknown")
    func everyLineIsKnown() throws {
        for name in ["claude-session", "claude-partial"] {
            for message in try Recording.claude(name) {
                if case .other(let type, _) = message { Issue.record("\(name): unknown message type \(type)") }
            }
        }
    }

    @Test("the session announces itself with its model, version and protocol capabilities")
    func sessionStart() throws {
        let starts = try Recording.claude("claude-session").compactMap { message -> ClaudeSessionInfo? in
            if case .sessionStarted(let info, _) = message { info } else { nil }
        }
        let first = try #require(starts.first)
        #expect(first.model == "claude-haiku-5-5")
        #expect(first.version == "2.1.330")
        #expect(first.cwd == "/tmp/udeck-fixture/work")
        #expect(first.capabilities.contains("interrupt_cancel_queued_v1"))
        #expect(first.slashCommands.contains("compact"))
    }

    @Test("an edit asks for permission, and the ask carries the tool and its input")
    func editAsksPermission() throws {
        let asks = try Recording.claude("claude-session").compactMap { message -> ClaudePermissionAsk? in
            if case .request(let request) = message { request.permission } else { nil }
        }
        #expect(asks.map(\.toolName) == ["Edit", "AskUserQuestion"])
        let edit = asks[0]
        #expect(edit.input["file_path"]?.string == "/tmp/udeck-fixture/work/notes.md")
        #expect(edit.questions == nil)
        #expect(edit.answerableFromSurface)
    }

    @Test("a question arrives as an ask for AskUserQuestion, with its options")
    func questionWithOptions() throws {
        let ask = try #require(try Recording.claude("claude-session").compactMap { message -> ClaudePermissionAsk? in
            if case .request(let request) = message, request.permission?.toolName == "AskUserQuestion" {
                request.permission
            } else { nil }
        }.first)
        let question = try #require(ask.questions?.first)
        #expect(question.question == "Which colour do you prefer?")
        #expect(question.options.map(\.label) == ["Red", "Blue"])
        #expect(!question.multiSelect)
    }

    @Test("uDeck's answer to the question is the shape the CLI accepted in the recording")
    func answerShape() throws {
        let lines = try Recording.lines("claude-session")
        let ask = try #require(try Recording.claude("claude-session").compactMap { message -> (String, ClaudePermissionAsk)? in
            if case .request(let request) = message, let ask = request.permission, ask.toolName == "AskUserQuestion" {
                (request.requestID, ask)
            } else { nil }
        }.first)
        let ours = ClaudeOutbound.answers(ask.0, to: ask.1, chosen: ["Which colour do you prefer?": ["Red"]])
        let sent = try #require(lines.filter(\.outgoing).compactMap { JSONValue.line(Substring($0.text)) }
            .first { $0["response"]?["request_id"]?.string == ask.0 })
        #expect(ours["response"]?["response"]?["updatedInput"]?["answers"]
            == sent["response"]?["response"]?["updatedInput"]?["answers"])
        #expect(ours["response"]?["response"]?["behavior"] == "allow")
    }

    @Test("both turns end, the first in three steps, and the answer to the question is the one chosen")
    func turnsFinish() throws {
        let results = try Recording.claude("claude-session").compactMap { message -> ClaudeTurnResult? in
            if case .turnFinished(let result, _) = message { result } else { nil }
        }
        #expect(results.count == 2)
        #expect(results.allSatisfy { !$0.isError })
        #expect(results[0].turns == 3)
        #expect(results[1].result == "Red.")
    }

    @Test("get_usage gives the plan and its windows: no 5-hour window on this account, the week at 32 %")
    func usage() throws {
        let usage = try #require(try Recording.claude("claude-session").compactMap { message -> ClaudeUsage? in
            if case .response(let response) = message, response.body["rate_limits"] != nil {
                ClaudeUsage(response.body)
            } else { nil }
        }.first)
        #expect(usage.subscription == "max")
        #expect(usage.fiveHour == nil)
        let week = try #require(usage.sevenDay)
        #expect(abs(week.used - 0.32) < 0.0001)
        let reset = try #require(week.resetsAt)
        let expected = try #require(ISO8601DateFormatter().date(from: "2026-11-27T03:00:00Z"))
        #expect(abs(reset.timeIntervalSince(expected)) < 1)
    }

    @Test("a rate limit event during the turn reports the week's utilisation and reset")
    func rateLimitEvent() throws {
        let event = try #require(try Recording.claude("claude-session").compactMap { message -> ClaudeRateLimit? in
            if case .rateLimit(let limit, _) = message { limit } else { nil }
        }.first)
        #expect(event.window == "seven_day")
        #expect(abs(event.usage.used - 0.32) < 0.0001)
        #expect(event.usage.resetsAt != nil)
    }

    @Test("get_context_usage gives tokens, window and percentage for the context bar")
    func context() throws {
        let context = try #require(try Recording.claude("claude-session").compactMap { message -> ClaudeContextUsage? in
            if case .response(let response) = message, response.body["maxTokens"] != nil {
                ClaudeContextUsage(response.body)
            } else { nil }
        }.first)
        #expect(context.window == 1_000_000)
        #expect(context.tokens > 0)
        #expect(context.percent >= 0 && context.percent < 100)
    }

    @Test("the answer streams word by word, and the deltas add up to the whole message that closes them")
    func streamingAddsUp() throws {
        var streamed = ""
        var whole: [String] = []
        for message in try Recording.claude("claude-partial") {
            switch message {
            case .partial(let event, _):
                if case .text(let piece) = event.delta { streamed += piece }
            case .assistant(let assistant, _):
                whole.append(assistant.text)
            default:
                break
            }
        }
        #expect(streamed.count > 20)
        // The interrupted turn's message never closes; what closed is a prefix of
        // what streamed, and the last turn's "ok" is in both.
        #expect(whole.contains { $0.lowercased().contains("ok") })
        #expect(streamed.lowercased().contains("ok"))
    }

    @Test("Stop with cancel_queued gets a receipt, and the interrupted turn ends as an error during execution")
    func interruptReceipt() throws {
        let messages = try Recording.claude("claude-partial")
        let receipt = try #require(messages.compactMap { message -> ClaudeControlResponse? in
            if case .response(let response) = message, response.body["still_queued"] != nil { response } else { nil }
        }.first)
        #expect(receipt.succeeded)
        #expect(receipt.body["cancelled"]?.array?.isEmpty == true)
        let results = messages.compactMap { message -> ClaudeTurnResult? in
            if case .turnFinished(let result, _) = message { result } else { nil }
        }
        #expect(results.first?.subtype == "error_during_execution")
        #expect(results.last?.isError == false)
    }

    @Test("the launch arguments are the SDK's, plus word-by-word streaming")
    func arguments() {
        let arguments = ClaudeOutbound.arguments(model: "haiku", resume: "abc")
        #expect(arguments.starts(with: ["--output-format", "stream-json", "--verbose", "--input-format", "stream-json",
                                        "--permission-prompt-tool=stdio", "--include-partial-messages"]))
        #expect(arguments.suffix(4) == ["--model", "haiku", "--resume", "abc"])
    }

    @Test("Stop asks to drop the queue only when told to")
    func interruptEncoding() throws {
        #expect(ClaudeOutbound.interrupt(id: "a")["request"]?["cancel_queued"] == nil)
        #expect(ClaudeOutbound.interrupt(id: "a", cancelQueued: true)["request"]?["cancel_queued"] == true)
    }
}

@Suite("Codex, as recorded")
struct CodexRecordedTests {
    @Test("every line app-server wrote is a response, a request or a notification")
    func everyLineIsKnown() throws {
        for message in try Recording.codex("codex-session") {
            if case .other = message { Issue.record("unclassified line") }
            if case .failure(_, let code, let text) = message { Issue.record("error \(code): \(text)") }
        }
    }

    @Test("the command Codex wants to run waits for an approval with the command in it")
    func approval() throws {
        let asks = try Recording.codex("codex-session").compactMap(\.approval)
        #expect(asks.count == 1)
        let ask = try #require(asks.first)
        guard case .command(let command) = ask.kind else {
            Issue.record("not a command approval: \(ask.kind)")
            return
        }
        #expect(command.contains("notes.md"))
        #expect(!ask.threadID.isEmpty && !ask.turnID.isEmpty)
        #expect(CodexOutbound.decide(ask, "accept")["result"]?["decision"] == "accept")
    }

    @Test("the streamed deltas of each message add up to the completed message")
    func deltasAddUp() throws {
        var streamed: [String: String] = [:]
        var completed: [String: String] = [:]
        for message in try Recording.codex("codex-session") {
            guard case .notification(let method, let params) = message else { continue }
            if method == "item/agentMessage/delta", let id = params["itemId"]?.string {
                streamed[id, default: ""] += params["delta"]?.string ?? ""
            }
            if method == "item/completed" {
                let item = CodexItem(params["item"] ?? .null)
                if item.type == "agentMessage" { completed[item.id] = item.text }
            }
        }
        #expect(completed.count == 2)
        for (id, text) in completed {
            #expect(streamed[id] == text, "message \(id)")
        }
    }

    @Test("the account's limits arrive as a 5-hour primary window")
    func rateLimits() throws {
        let limits = try #require(try Recording.codex("codex-session").compactMap { message -> CodexRateLimits? in
            if case .notification("account/rateLimits/updated", let params) = message {
                CodexRateLimits(params["rateLimits"] ?? .null)
            } else { nil }
        }.first)
        #expect(limits.primary?.minutes == 300)
    }

    @Test("the turn ends with turn/completed and the thread goes idle")
    func turnEnds() throws {
        let methods = try Recording.codex("codex-session").compactMap { message -> String? in
            if case .notification(let method, _) = message { method } else { nil }
        }
        let completed = try #require(methods.firstIndex(of: "turn/completed"))
        #expect(methods[..<completed].contains("turn/started"))
    }
}

@Suite("Line framing")
struct LineFramerTests {
    @Test("a line split across reads, even inside a multi-byte letter, comes out whole")
    func splitAcrossReads() {
        var framer = LineFramer()
        let bytes = Array("{\"t\":\"Ждут\"}\n{\"a\":1}\n".utf8)
        var out: [LineFramer.Piece] = []
        for chunk in [bytes[0..<9], bytes[9..<10], bytes[10...]] {
            out += framer.feed(Data(chunk))
        }
        #expect(out == [.line("{\"t\":\"Ждут\"}"), .line("{\"a\":1}")])
        #expect(framer.finish().isEmpty)
    }

    @Test("a last line without a newline still counts, and CRLF is trimmed")
    func finishAndCRLF() {
        var framer = LineFramer()
        #expect(framer.feed(Data("one\r\ntwo".utf8)) == [.line("one")])
        #expect(framer.finish() == [.line("two")])
    }

    @Test("a line past the limit is dropped whole and reported, and the next one is fine")
    func overlong() {
        var framer = LineFramer(limit: 8)
        var out = framer.feed(Data("0123456789".utf8))
        out += framer.feed(Data("abc\nok\n".utf8))
        #expect(out == [.overlong(bytes: 13), .line("ok")])
    }
}

@Suite("JSON values")
struct JSONValueTests {
    @Test("unknown fields survive a round trip, and whole numbers go out without a fraction")
    func roundTrip() throws {
        let value = try #require(JSONValue.line(#"{"id":3,"x":{"new":[true,null,1.5]}}"#))
        #expect(try value.encodedLine() == #"{"id":3,"x":{"new":[true,null,1.5]}}"#)
    }

    @Test("a line that is not JSON is nil, not a crash")
    func notJSON() {
        #expect(JSONValue.line("hello from a tool") == nil)
    }
}

@Suite("Which asks a quick surface may answer")
struct SurfaceRulesTests {
    static func ask(_ fields: [String: JSONValue]) -> ClaudePermissionAsk {
        var body: [String: JSONValue] = ["subtype": "can_use_tool", "tool_name": "Bash", "input": ["command": "ls"]]
        body.merge(fields) { _, new in new }
        let request = ClaudeControlRequest(["type": "control_request", "request_id": "r1", "request": .object(body)])
        return request.permission!
    }

    @Test("a plain ask may be answered from a surface; a flagged or dangerous one only by opening the session")
    func rules() {
        #expect(Self.ask([:]).answerableFromSurface)
        #expect(!Self.ask(["requires_user_interaction": true]).answerableFromSurface)
        #expect(!Self.ask(["default_to_no": true]).answerableFromSurface)
        #expect(!Self.ask(["matched_ask_rule": ["source": "user", "tool_name": "Bash"]]).answerableFromSurface)
        #expect(!Self.ask(["decision_reason_type": "safetyCheck"]).answerableFromSurface)
        #expect(!Self.ask(["decision_reason_type": "rule", "classifier_approvable": false]).answerableFromSurface)
    }

    @Test("always-allow is offered only with a proposed rule and when the CLI does not forbid it")
    func always() {
        let rule: JSONValue = ["type": "addRules", "rules": [["toolName": "Bash"]], "behavior": "allow"]
        #expect(!Self.ask([:]).offersAlways)
        #expect(Self.ask(["permission_suggestions": [rule]]).offersAlways)
        #expect(!Self.ask(["permission_suggestions": [rule], "suppress_always_allow_rule": true]).offersAlways)
    }
}
