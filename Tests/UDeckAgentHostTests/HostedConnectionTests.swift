import Foundation
import Testing
@testable import UDeckAgentHost
import UDeckAgents

/// A fake `claude` that answers every control request it reads, and says how
/// many it has answered — so a test can tell one long-lived process from a new
/// one.
func controlEcho(_ rig: Rig) throws -> String {
    try rig.script("echo-claude.sh", """
    n=0
    while IFS= read -r line; do
      id=$(printf '%s' "$line" | sed -n 's/.*"request_id":"\\([^"]*\\)".*/\\1/p')
      if [ -n "$id" ]; then
        n=$((n + 1))
        printf '{"type":"control_response","response":{"subtype":"success","request_id":"%s","response":{"answered":%d,"pid":%d}}}\\n' "$id" "$n" "$$"
      else
        printf '{"type":"system","subtype":"note","text":"got a line"}\\n'
      fi
    done
    """)
}

/// One request as one JSON line, and the line answering it read back: what
/// any program a plugin runs does over its channel — Claude Code's control
/// requests, Codex's JSON-RPC — with nothing of either one's meaning, which is
/// the plugin's (Plugins/Agents).
func ask(_ channel: any AgentChannel, _ lines: inout AsyncStream<LineFramer.Piece>.Iterator,
         id: String) async throws -> JSONValue {
    try channel.write(line: #"{"type":"control_request","request_id":"\#(id)","request":{"subtype":"initialize"}}"#)
    while let piece = await lines.next() {
        guard case .line(let text) = piece, let value = JSONValue.line(Substring(text)),
              value["response"]?["request_id"]?.string == id else { continue }
        return value["response"]?["response"] ?? .null
    }
    throw CancellationError()
}

@Suite("A program's JSON lines through the helper", .serialized)
struct HostedConnectionTests {
    @Test("a conversation in JSON lines works over the helper exactly as over a pipe")
    func linesOverHelper() async throws {
        let rig = try Rig()
        let client = try await rig.client()
        let agent = try await HostedAgent.spawn(rig.spec("c1", try controlEcho(rig)), on: client)
        #expect(agent.processIdentifier > 0)
        var lines = agent.lines.makeAsyncIterator()
        let response = try await ask(agent, &lines, id: "r1")
        #expect(response["answered"]?.int == 1)
        #expect(response["pid"]?.int == Int(agent.processIdentifier))
        try agent.write(line: #"{"type":"user","message":"hi"}"#)
        var note: JSONValue?
        while let piece = await lines.next() {
            if case .line(let text) = piece { note = JSONValue.line(Substring(text)); break }
        }
        #expect(note?["subtype"]?.string == "note")
        agent.closeInput()
        let exit = await agent.exit()
        #expect(exit.status == 0)
        await client.close()
        await rig.cleanUp()
    }

    @Test("uDeck restarts mid-session: a new channel picks up the same program where the old one stopped")
    func reattach() async throws {
        let rig = try Rig()
        let echo = try controlEcho(rig)
        // The first uDeck.
        let first = try await rig.client()
        let agent = try await HostedAgent.spawn(rig.spec("c1", echo), on: first)
        var lines = agent.lines.makeAsyncIterator()
        let before = try await ask(agent, &lines, id: "r1")
        #expect(before["answered"]?.int == 1)
        let seen = agent.lastSeq
        // uDeck goes away without a word: the program is not told.
        await first.close()
        try await Task.sleep(for: .milliseconds(100))
        // The next uDeck finds the session in hello and attaches after what it saw.
        let second = try await rig.client()
        let hello = try await second.hello(client: "tests, after a restart")
        let summary = try #require(hello.sessions.first { $0.session == "c1" })
        #expect(summary.running)
        let (again, subscription) = try await HostedAgent.attach(session: "c1", after: seen, on: second)
        #expect(!subscription.gap)
        var resumedLines = again.lines.makeAsyncIterator()
        let after = try await ask(again, &resumedLines, id: "r2")
        // The same process: it counts on from where it was.
        #expect(after["answered"]?.int == 2)
        #expect(after["pid"]?.int == before["pid"]?.int)
        _ = await again.terminate(grace: .seconds(3))
        await second.close()
        await rig.cleanUp()
    }

    @Test("a tagged write is confirmed by the journal's input event")
    func deliveryReceipt() async throws {
        let rig = try Rig()
        let client = try await rig.client()
        let agent = try await HostedAgent.spawn(rig.spec("c1", "/bin/cat"), on: client)
        try agent.write(line: "one", tag: "m-1")
        var lines = agent.lines.makeAsyncIterator()
        #expect(await lines.next() == .line("one"))
        #expect(agent.delivered("m-1") != nil)
        #expect(agent.delivered("m-2") == nil)
        agent.closeInput()
        #expect(await agent.exit().status == 0)
        await client.close()
        await rig.cleanUp()
    }

    @Test("a resumed session's new channel is not ended by the previous run's exit still in the journal")
    func resumeIgnoresTheEarlierExit() async throws {
        let rig = try Rig()
        let client = try await rig.client()
        let first = try await HostedAgent.spawn(rig.spec("c1", "/bin/echo", ["first run"]), on: client)
        #expect(await first.exit().status == 0)
        // The same session again, as a resume does.
        let second = try await HostedAgent.spawn(rig.spec("c1", "/bin/cat"), on: client)
        try second.write(line: "second run")
        var lines = second.lines.makeAsyncIterator()
        #expect(await lines.next() == .line("second run"))
        second.closeInput()
        #expect(await second.exit().status == 0)
        await client.close()
        await rig.cleanUp()
    }

    @Test("attaching from the start to a resumed session reads the earlier run's lines without taking its exit for this run's")
    func attachAcrossRuns() async throws {
        let rig = try Rig()
        let owner = try await rig.client()
        let first = try await HostedAgent.spawn(rig.spec("c1", "/bin/echo", ["first run"]), on: owner)
        #expect(await first.exit().status == 0)
        _ = try await HostedAgent.spawn(rig.spec("c1", "/bin/cat"), on: owner)
        // Another uDeck, reading everything the journal has.
        let reader = try await rig.client()
        let (agent, subscription) = try await HostedAgent.attach(session: "c1", after: 0, on: reader)
        #expect(subscription.running)
        var lines = agent.lines.makeAsyncIterator()
        #expect(await lines.next() == .line("first run"))
        try agent.write(line: "second run")
        #expect(await lines.next() == .line("second run"))
        agent.closeInput()
        #expect(await agent.exit().status == 0)
        await owner.close()
        await reader.close()
        await rig.cleanUp()
    }

    @Test("attaching to a run that is already over gives its lines, then its exit")
    func attachAfterTheEnd() async throws {
        let rig = try Rig()
        let client = try await rig.client()
        try await client.spawn(rig.spec("c1", "/bin/echo", ["said before anyone listened"]))
        while try await client.list().first?.running != false { try await Task.sleep(for: .milliseconds(20)) }
        let (agent, subscription) = try await HostedAgent.attach(session: "c1", on: client)
        #expect(!subscription.running)
        var lines: [LineFramer.Piece] = []
        for await piece in agent.lines { lines.append(piece) }
        #expect(lines == [.line("said before anyone listened")])
        #expect(await agent.exit().status == 0)
        await client.close()
        await rig.cleanUp()
    }

    @Test("one channel per session: a second attach is refused and the first keeps working")
    func oneOwner() async throws {
        let rig = try Rig()
        let client = try await rig.client()
        let agent = try await HostedAgent.spawn(rig.spec("c1", "/bin/cat"), on: client)
        await #expect(throws: HostedAgent.Failure.alreadyAttached("c1")) {
            _ = try await HostedAgent.attach(session: "c1", on: client)
        }
        try agent.write(line: "still mine")
        var lines = agent.lines.makeAsyncIterator()
        #expect(await lines.next() == .line("still mine"))
        agent.closeInput()
        #expect(await agent.exit().status == 0)
        await client.close()
        await rig.cleanUp()
    }
}
