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

@Suite("Claude Code and Codex connections through the helper", .serialized)
struct HostedConnectionTests {
    @Test("a Claude Code connection works over the helper exactly as over a pipe")
    func claudeOverHelper() async throws {
        let rig = try Rig()
        let client = try await rig.client()
        let agent = try await HostedAgent.spawn(rig.spec("c1", try controlEcho(rig)), on: client)
        #expect(agent.processIdentifier > 0)
        let connection = ClaudeCodeConnection(channel: agent)
        await connection.start()
        let response = try await connection.request { ClaudeOutbound.initialize(id: $0) }
        #expect(response.succeeded)
        #expect(response.body["answered"]?.int == 1)
        #expect(response.body["pid"]?.int == Int(agent.processIdentifier))
        try await connection.send(ClaudeOutbound.userMessage("hi"))
        var iterator = connection.events.makeAsyncIterator()
        let note = await iterator.next()
        if case .system(let subtype, _)? = note { #expect(subtype == "note") } else { Issue.record("got \(String(describing: note))") }
        let exit = await connection.close(grace: .seconds(3))
        #expect(exit.status == 0)
        await client.close()
        await rig.cleanUp()
    }

    @Test("uDeck restarts mid-session: a new connection picks up the same agent where the old one stopped")
    func reattach() async throws {
        let rig = try Rig()
        let echo = try controlEcho(rig)
        // The first uDeck.
        let first = try await rig.client()
        let agent = try await HostedAgent.spawn(rig.spec("c1", echo), on: first)
        let connection = ClaudeCodeConnection(channel: agent)
        await connection.start()
        let before = try await connection.request { ClaudeOutbound.initialize(id: $0) }
        #expect(before.body["answered"]?.int == 1)
        let seen = agent.lastSeq
        // uDeck goes away without a word: the agent is not told.
        await first.close()
        try await Task.sleep(for: .milliseconds(100))
        // The next uDeck finds the session in hello and attaches after what it saw.
        let second = try await rig.client()
        let hello = try await second.hello(client: "tests, after a restart")
        let summary = try #require(hello.sessions.first { $0.session == "c1" })
        #expect(summary.running)
        let (again, subscription) = try await HostedAgent.attach(session: "c1", after: seen, on: second)
        #expect(!subscription.gap)
        let resumed = ClaudeCodeConnection(channel: again)
        await resumed.start()
        let after = try await resumed.request { ClaudeOutbound.interrupt(id: $0) }
        // The same process: it counts on from where it was.
        #expect(after.body["answered"]?.int == 2)
        #expect(after.body["pid"]?.int == before.body["pid"]?.int)
        _ = await resumed.close(grace: .seconds(3))
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

    @Test("a Codex connection works over the helper too")
    func codexOverHelper() async throws {
        let rig = try Rig()
        let fake = try rig.script("fake-codex.sh", """
        while IFS= read -r line; do
          id=$(printf '%s' "$line" | sed -n 's/^{"id":\\([0-9]*\\).*/\\1/p')
          [ -n "$id" ] && printf '{"id":%s,"result":{"userAgent":"fake"}}\\n' "$id"
        done
        """)
        let client = try await rig.client()
        let agent = try await HostedAgent.spawn(rig.spec("x1", fake), on: client)
        let connection = CodexConnection(channel: agent)
        await connection.start()
        let result = try await connection.request("initialize", ["clientInfo": ["name": "t", "version": "0"]])
        #expect(result["userAgent"]?.string == "fake")
        _ = await connection.close(grace: .seconds(3))
        await client.close()
        await rig.cleanUp()
    }
}
