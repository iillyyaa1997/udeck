import Foundation
import Testing
@testable import UDeckAgents

/// A fake `claude`: a shell script that replays a recording. For every line
/// uDeck sent in the recording it waits for one line on stdin (and keeps it in
/// `received`), and it prints every line the CLI wrote, in the recorded order.
/// So the connection is driven exactly as in the real conversation, with no
/// login and no network, and what uDeck wrote can be compared afterwards.
struct ReplayAgent {
    let folder: URL
    let script: URL
    let received: URL
    /// The request ids uDeck used in the recording, in order.
    let requestIDs: [String]

    init(recording name: String) throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("udeck-replay-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        script = folder.appendingPathComponent("agent.sh")
        received = folder.appendingPathComponent("received.jsonl")
        var lines = ["#!/bin/sh", ": > '\(received.path)'"]
        var ids: [String] = []
        for line in try Recording.lines(name) {
            if line.outgoing {
                lines.append("IFS= read -r line || exit 0")
                lines.append("printf '%s\\n' \"$line\" >> '\(received.path)'")
                if let value = JSONValue.line(Substring(line.text)), value["type"]?.string == "control_request",
                   let id = value["request_id"]?.string
                {
                    ids.append(id)
                }
            } else {
                let quoted = line.text.replacingOccurrences(of: "'", with: "'\\''")
                lines.append("printf '%s\\n' '\(quoted)'")
            }
        }
        // Like the real CLI: when stdin closes at the end, exit.
        lines.append("cat > /dev/null")
        try lines.joined(separator: "\n").write(to: script, atomically: true, encoding: .utf8)
        requestIDs = ids
    }

    func idGenerator() -> @Sendable () -> String {
        let queue = Locked(requestIDs)
        return { queue.withLock { $0.isEmpty ? "unexpected" : $0.removeFirst() } }
    }

    func receivedLines() throws -> [JSONValue] {
        try String(contentsOf: received, encoding: .utf8).split(separator: "\n").compactMap { JSONValue.line($0) }
    }

    func cleanUp() { try? FileManager.default.removeItem(at: folder) }
}

@Suite("Claude Code connection, against a replayed conversation")
struct ClaudeConnectionTests {
    @Test("a whole session: initialize, two turns with a permission and a question answered, then seven requests")
    func wholeSession() async throws {
        let agent = try ReplayAgent(recording: "claude-session")
        defer { agent.cleanUp() }
        let connection = try ClaudeCodeConnection(
            executable: URL(fileURLWithPath: "/bin/sh"), arguments: [agent.script.path],
            environment: ["PATH": "/usr/bin:/bin"], directory: agent.folder, nextID: agent.idGenerator())
        await connection.start()
        var events = connection.events.makeAsyncIterator()

        let initialized = try await connection.request { ClaudeOutbound.initialize(id: $0) }
        #expect(initialized.body["claude_code_version"]?.string == "2.1.330")

        var asked: [String] = []
        func runTurn(_ text: String) async throws -> ClaudeTurnResult {
            try await connection.send(ClaudeOutbound.userMessage(text))
            while let event = await events.next() {
                switch event {
                case .request(let request):
                    let ask = try #require(request.permission)
                    asked.append(ask.toolName)
                    if ask.questions != nil {
                        try await connection.send(ClaudeOutbound.answers(
                            request.requestID, to: ask, chosen: ["Which colour do you prefer?": ["Red"]]))
                    } else {
                        try await connection.send(ClaudeOutbound.allow(request.requestID, input: ask.input))
                    }
                case .turnFinished(let result, _):
                    return result
                default:
                    continue
                }
            }
            throw ClaudeCodeConnection.Failure.closed
        }

        let first = try await runTurn("Read notes.md, then append one line.")
        #expect(!first.isError)
        let second = try await runTurn("Ask me which colour I prefer.")
        #expect(second.result == "Red.")
        #expect(asked == ["Edit", "AskUserQuestion"])

        let context = try await connection.request { ClaudeOutbound.contextUsage(id: $0) }
        #expect(ClaudeContextUsage(context.body).window == 1_000_000)
        let usage = try await connection.request { ClaudeOutbound.usage(id: $0) }
        #expect(ClaudeUsage(usage.body).subscription == "max")
        let models = try await connection.request { ClaudeOutbound.listModels(id: $0) }
        #expect(models.body["models"]?.array?.isEmpty == false)
        let files = try await connection.request { ClaudeOutbound.fileSuggestions(id: $0, query: "not") }
        #expect(files.body["suggestions"] != nil)
        _ = try await connection.request { id in
            ["type": "control_request", "request_id": .string(id), "request": ["subtype": "get_session_cost"]]
        }
        let model = try await connection.request { ClaudeOutbound.setModel(id: $0, "haiku") }
        #expect(model.succeeded)
        let mode = try await connection.request { ClaudeOutbound.setPermissionMode(id: $0, "acceptEdits") }
        #expect(mode.succeeded)

        let exit = await connection.close()
        #expect(exit.status == 0)

        // What uDeck wrote has the recording's shape, line for line.
        let original = try Recording.lines("claude-session").filter(\.outgoing).compactMap { JSONValue.line(Substring($0.text)) }
        let ours = try agent.receivedLines()
        #expect(ours.count == original.count)
        for (mine, theirs) in zip(ours, original) {
            #expect(mine["type"] == theirs["type"])
            #expect(mine["request"]?["subtype"] == theirs["request"]?["subtype"])
            #expect(mine["response"]?["request_id"] == theirs["response"]?["request_id"])
            #expect(mine["response"]?["response"]?["behavior"] == theirs["response"]?["response"]?["behavior"])
        }
    }

    @Test("a request with no answer times out instead of waiting forever")
    func timeout() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("udeck-silent-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let connection = try ClaudeCodeConnection(
            executable: URL(fileURLWithPath: "/bin/cat"), arguments: [], environment: [:], directory: folder)
        await connection.start()
        await #expect(throws: ClaudeCodeConnection.Failure.self) {
            _ = try await connection.request({ ClaudeOutbound.usage(id: $0) }, timeout: .milliseconds(200))
        }
        _ = await connection.close(grace: .seconds(1))
    }

    @Test("a program that exits ends the events, fails what is waiting, and refuses further writes")
    func exitEndsEverything() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("udeck-exit-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let connection = try ClaudeCodeConnection(
            executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "echo '{\"type\":\"system\",\"subtype\":\"status\"}'"],
            environment: [:], directory: folder)
        await connection.start()
        var seen = 0
        for await _ in connection.events { seen += 1 }
        #expect(seen == 1)
        await #expect(throws: ClaudeCodeConnection.Failure.closed) {
            try await connection.send(ClaudeOutbound.userMessage("hello"))
        }
    }
}

@Suite("Codex connection, against a replayed conversation")
struct CodexConnectionTests {
    @Test("handshake, a thread, a turn with a command approved, then limits, models and a file search")
    func wholeSession() async throws {
        let agent = try ReplayAgent(recording: "codex-session")
        defer { agent.cleanUp() }
        let connection = try CodexConnection(
            executable: URL(fileURLWithPath: "/bin/sh"), arguments: [agent.script.path],
            environment: ["PATH": "/usr/bin:/bin"], directory: agent.folder)
        await connection.start()
        var events = connection.events.makeAsyncIterator()

        let hello = try await connection.handshake(client: "udeck-test", version: "0.0.1")
        #expect(hello["platformOs"] != nil)
        let started = try await connection.request("thread/start", ["cwd": "/tmp/udeck-fixture/work",
                                                                    "approvalPolicy": "untrusted",
                                                                    "sandbox": "workspace-write", "ephemeral": true])
        let thread = try #require(started["thread"]?["id"]?.string)
        _ = try await connection.request("turn/start", ["threadId": .string(thread),
                                                        "input": [["type": "text", "text": "Append one line."]]])
        var approvals = 0
        var answer = ""
        while let event = await events.next() {
            if let ask = event.approval {
                approvals += 1
                try await connection.send(CodexOutbound.decide(ask, "accept"))
                continue
            }
            if case .notification("item/completed", let params) = event {
                let item = CodexItem(params["item"] ?? .null)
                if item.type == "agentMessage" { answer = item.text }
            }
            if case .notification("turn/completed", _) = event { break }
        }
        #expect(approvals == 1)
        #expect(answer.contains("Recorded by uDeck"))

        let limits = try await connection.request("account/rateLimits/read")
        #expect(CodexRateLimits(limits["rateLimits"] ?? .null).primary?.minutes == 300)
        let models = try await connection.request("model/list")
        #expect(models["data"]?.array?.isEmpty == false)
        let files = try await connection.request("fuzzyFileSearch", ["query": "not", "roots": ["/tmp/udeck-fixture/work"],
                                                                     "cancellationToken": nil])
        #expect(files["files"] != nil)
        #expect(await connection.close().status == 0)
    }
}
