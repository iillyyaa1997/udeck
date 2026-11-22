import Foundation
import Testing
@testable import UDeckAgentHost
import UDeckAgents

/// A helper listening in this process (an anonymous XPC listener), and uDeck's
/// side connected to it. Both requirements default to this test process's own
/// designated requirement: the test plays uDeck and the helper at once.
struct Rig {
    let folder: URL
    let host: AgentHost
    let server: HostServer

    init(peerRequirement: String? = nil, journal: @escaping @Sendable () -> EventJournal = { EventJournal() },
         limits: AgentHost.Limits = AgentHost.Limits()) throws
    {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("udeck-host-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        host = AgentHost(journal: journal, limits: limits)
        server = try HostServer(listening: .anonymous, peerRequirement: try peerRequirement ?? CodeIdentity.ownRequirement(),
                                host: host, info: HostInfo(version: "test"))
        server.start()
    }

    func connect(helperRequirement: String? = nil) throws -> AgentHostClient {
        AgentHostClient(endpoint: server.endpoint, helperRequirement: try helperRequirement ?? CodeIdentity.ownRequirement())
    }

    func client() async throws -> AgentHostClient {
        let client = try connect()
        _ = try await client.hello(client: "tests")
        return client
    }

    func script(_ name: String, _ body: String) throws -> String {
        let url = folder.appendingPathComponent(name)
        try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        chmod(url.path, 0o755)
        return url.path
    }

    func spec(_ session: String, _ executable: String, _ arguments: [String] = [], stopLine: String? = nil)
        -> SpawnSpec
    {
        SpawnSpec(session: session, executable: executable, arguments: arguments,
                  environment: ["PATH": "/usr/bin:/bin"], directory: folder.path, stopLine: stopLine)
    }

    func cleanUp() async {
        await host.shutdown(grace: .seconds(2))
        server.stopListening()
        server.closeConnections()
        try? FileManager.default.removeItem(at: folder)
    }
}

struct RigError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Collects a client's events so a test can wait for the one it expects.
final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [HostEvent] = []
    private var task: Task<Void, Never>?

    init(_ stream: AsyncStream<HostEvent>) {
        task = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                self.lock.withLock { self.events.append(event) }
            }
        }
    }

    var all: [HostEvent] { lock.withLock { events } }

    func lines(_ session: String) -> [String] {
        all.compactMap { event in
            guard event.session == session, case .line(let text) = event.kind else { return nil }
            return text
        }
    }

    /// Waits until `predicate` holds for what has arrived, or fails after `timeout`.
    func until(_ what: String, timeout: Duration = .seconds(10), _ predicate: ([HostEvent]) -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !predicate(all) {
            guard ContinuousClock.now < deadline else { throw RigError("timed out waiting for \(what); have \(all)") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

func exited(_ session: String) -> ([HostEvent]) -> Bool {
    { events in events.contains { $0.session == session && $0.kind.isExit } }
}

func helperError(_ code: String) -> (any Error) -> Bool {
    { error in
        guard case .helper(let got, _)? = error as? AgentHostClient.Failure else { return false }
        return got == code
    }
}

@Suite("The helper over XPC", .serialized)
struct HostTests {
    @Test("an agent's lines come back in order, with the input journalled by tag, and its exit")
    func roundTrip() async throws {
        let rig = try Rig()
        let client = try await rig.client()
        let events = Collected(client.events)
        let pid = try await client.spawn(rig.spec("s1", "/bin/cat"))
        #expect(pid > 0)
        let subscription = try await client.subscribe(session: "s1")
        #expect(!subscription.gap)
        try await client.write(session: "s1", line: #"{"hello":"мир"}"#, tag: "m1")
        try await client.write(session: "s1", line: "second")
        try await events.until("two lines") { _ in events.lines("s1").count == 2 }
        #expect(events.lines("s1") == [#"{"hello":"мир"}"#, "second"])
        try await client.closeInput(session: "s1")
        try await events.until("the exit", exited("s1"))
        let kinds = events.all.map(\.kind)
        #expect(kinds.first == .started(pid: pid))
        #expect(kinds.contains(.input(tag: "m1")))
        #expect(events.all.map(\.seq) == Array(1...events.all.count))
        if case .exited(let status, _) = kinds.last { #expect(status == 0) } else { Issue.record("no exit last") }
        let listed = try await client.list()
        #expect(listed.map(\.session) == ["s1"])
        #expect(listed.first?.running == false)
        #expect(listed.first?.status == 0)
        await client.close()
        await rig.cleanUp()
    }

    @Test("uDeck reconnects: the agent kept running, and the journal gives exactly what it missed")
    func reconnect() async throws {
        let rig = try Rig()
        let first = try await rig.client()
        let firstEvents = Collected(first.events)
        try await first.spawn(rig.spec("s1", "/bin/cat"))
        let epoch = try await first.subscribe(session: "s1").epoch
        try await first.write(session: "s1", line: "before")
        try await firstEvents.until("before") { _ in firstEvents.lines("s1") == ["before"] }
        let seen = firstEvents.all.last!.seq
        await first.close()
        try await Task.sleep(for: .milliseconds(100))
        // uDeck is gone; the agent is not.
        #expect(await rig.host.subscriberCount(session: "s1") == 0)
        let second = try rig.connect()
        let hello = try await second.hello(client: "tests again")
        #expect(hello.sessions.first?.running == true)
        #expect(hello.sessions.first?.epoch == epoch)
        #expect(hello.info.instance == rig.server.info.instance)
        try await second.write(session: "s1", line: "while away")
        let secondEvents = Collected(second.events)
        let subscription = try await second.subscribe(session: "s1", after: seen, epoch: epoch)
        #expect(!subscription.gap)
        try await second.write(session: "s1", line: "after")
        try await secondEvents.until("after") { _ in secondEvents.lines("s1") == ["while away", "after"] }
        #expect(secondEvents.all.first?.seq == seen + 1)
        await second.close()
        await rig.cleanUp()
    }

    @Test("a position in another journal of the same session id reads from the start, flagged")
    func otherEpoch() async throws {
        let rig = try Rig()
        let client = try await rig.client()
        try await client.spawn(rig.spec("s1", "/bin/echo", ["old"]))
        while try await client.list().first?.running != false { try await Task.sleep(for: .milliseconds(20)) }
        let old = try await client.list().first!.epoch
        try await client.forget(session: "s1")
        try await client.spawn(rig.spec("s1", "/bin/echo", ["new"]))
        while try await client.list().first?.running != false { try await Task.sleep(for: .milliseconds(20)) }
        let subscription = try await client.subscribe(session: "s1", after: 2, epoch: old)
        #expect(subscription.gap)
        #expect(subscription.epoch != old)
        await client.close()
        await rig.cleanUp()
    }

    @Test("a journal too small for what was missed says so")
    func gap() async throws {
        let rig = try Rig(journal: { EventJournal(maxEvents: 3) })
        let client = try await rig.client()
        try await client.spawn(rig.spec("s1", "/bin/cat"))
        for index in 1...6 { try await client.write(session: "s1", line: "\(index)") }
        try await client.closeInput(session: "s1")
        while try await client.list().first?.running != false { try await Task.sleep(for: .milliseconds(20)) }
        // started, six lines, exited: eight events, of which the last three are kept.
        let events = Collected(client.events)
        let subscription = try await client.subscribe(session: "s1", after: 0)
        #expect(subscription.gap)
        #expect(subscription.firstSeq == 6)
        #expect(subscription.lastSeq == 8)
        try await events.until("the kept three") { $0.count == 3 }
        #expect(events.lines("s1") == ["5", "6"])
        await client.close()
        await rig.cleanUp()
    }

    @Test("the same session started again goes on numbering: a resume reads as one stream")
    func respawn() async throws {
        let rig = try Rig()
        let client = try await rig.client()
        let events = Collected(client.events)
        try await client.spawn(rig.spec("s1", "/bin/echo", ["one"]))
        try await client.subscribe(session: "s1")
        try await events.until("first exit", exited("s1"))
        try await client.spawn(rig.spec("s2", "/bin/sleep", ["5"]))
        // Not while it runs.
        await #expect(performing: { try await client.spawn(rig.spec("s2", "/bin/sleep", ["5"])) },
                      throws: helperError("sessionExists"))
        try await client.spawn(rig.spec("s1", "/bin/echo", ["two"]))
        try await events.until("second exit") { all in all.filter { $0.session == "s1" && $0.kind.isExit }.count == 2 }
        let s1 = events.all.filter { $0.session == "s1" }
        #expect(s1.map(\.seq) == Array(1...s1.count))
        #expect(events.lines("s1") == ["one", "two"])
        #expect(s1.filter(\.kind.isStart).count == 2)
        try await client.terminate(session: "s2", grace: .milliseconds(200))
        await client.close()
        await rig.cleanUp()
    }

    @Test("terminate stops an agent that ignores its stdin, and other requests are not held up meanwhile")
    func terminate() async throws {
        let rig = try Rig()
        let client = try await rig.client()
        let stubborn = try rig.script("stubborn.sh", "trap '' TERM; echo ready; while :; do sleep 0.1; done")
        let events = Collected(client.events)
        try await client.spawn(rig.spec("s1", stubborn))
        try await client.subscribe(session: "s1")
        try await client.spawn(rig.spec("s2", "/bin/cat"))
        // Only once it ignores SIGTERM: before its trap is set, SIGTERM kills it.
        try await events.until("ready") { _ in events.lines("s1") == ["ready"] }
        let started = ContinuousClock.now
        async let status = client.terminate(session: "s1", grace: .seconds(1))
        try await Task.sleep(for: .milliseconds(100))
        // Answered while the terminate waits out its grace.
        let listed = try await client.list()
        #expect(ContinuousClock.now - started < .milliseconds(800))
        #expect(listed.count == 2)
        let got = try await status
        #expect(got == SIGKILL, "status \(got)")
        try await client.terminate(session: "s2", grace: .milliseconds(200))
        await client.close()
        await rig.cleanUp()
    }

    @Test("an agent whose background job keeps its stdout open still has its exit recorded")
    func backgroundJobHoldsStdout() async throws {
        let rig = try Rig()
        let client = try await rig.client()
        let agent = try rig.script("leaves-a-job.sh", "sleep 30 & echo started a job; exit 4")
        let events = Collected(client.events)
        try await client.spawn(rig.spec("s1", agent))
        try await client.subscribe(session: "s1")
        try await events.until("the exit", timeout: .seconds(5), exited("s1"))
        #expect(events.lines("s1") == ["started a job"])
        #expect(try await client.list().first?.status == 4)
        await client.close()
        await rig.cleanUp()
    }

    @Test("an agent gets no descriptor of the helper's beyond its stdio")
    func noInheritedDescriptors() async throws {
        let rig = try Rig()
        let client = try await rig.client()
        let events = Collected(client.events)
        // lsof, not `ls /dev/fd`: ls opens two descriptors of its own to read
        // it. And below 255: the shell keeps its script open on 255.
        let agent = try rig.script("descriptors.sh", "/usr/sbin/lsof -p $$ -a -d 0-254 -F f | grep '^f'")
        try await client.spawn(rig.spec("s1", agent))
        try await client.subscribe(session: "s1")
        try await events.until("the exit", exited("s1"))
        #expect(events.lines("s1") == ["f0", "f1", "f2"])
        await client.close()
        await rig.cleanUp()
    }

    @Test("stopping the helper gives every agent its stop line, then closes its stdin")
    func shutdownWithStopLine() async throws {
        let rig = try Rig()
        let client = try await rig.client()
        let agent = try rig.script("agent.sh", """
        while IFS= read -r line; do
          if [ "$line" = '{"interrupt":true}' ]; then echo "interrupted cleanly"; fi
        done
        echo "stdin closed"
        exit 3
        """)
        try await client.spawn(rig.spec("s1", agent, stopLine: #"{"interrupt":true}"#))
        let events = Collected(client.events)
        try await client.subscribe(session: "s1")
        await rig.host.shutdown(grace: .seconds(5))
        try await events.until("the exit", exited("s1"))
        #expect(events.lines("s1") == ["interrupted cleanly", "stdin closed"])
        #expect(try await client.list().first?.status == 3)
        // Nothing new starts once stopping.
        await #expect(performing: { try await client.spawn(rig.spec("s2", "/bin/cat")) },
                      throws: helperError("stopping"))
        await client.close()
        await rig.cleanUp()
    }

    @Test("shutdown keeps to its deadline with several agents that ignore everything")
    func shutdownDeadline() async throws {
        let rig = try Rig()
        let client = try await rig.client()
        let stubborn = try rig.script("stubborn.sh", "trap '' TERM; echo ready; while :; do sleep 0.1; done")
        let events = Collected(client.events)
        for index in 1...4 {
            try await client.spawn(rig.spec("s\(index)", stubborn))
            try await client.subscribe(session: "s\(index)")
        }
        try await events.until("all ready") { _ in (1...4).allSatisfy { events.lines("s\($0)") == ["ready"] } }
        let started = ContinuousClock.now
        await rig.host.shutdown(grace: .seconds(3))
        let took = ContinuousClock.now - started
        #expect(took < .seconds(4), "took \(took)")
        #expect(await !rig.host.hasRunningAgents)
        await client.close()
        await rig.cleanUp()
    }

    @Test("quit is refused while agents run, unless forced")
    func quit() async throws {
        let rig = try Rig()
        let client = try await rig.client()
        try await client.spawn(rig.spec("s1", "/bin/cat"))
        await #expect(performing: { try await client.quit() }, throws: helperError("stillRunning"))
        try await client.closeInput(session: "s1")
        while try await client.list().first?.running != false { try await Task.sleep(for: .milliseconds(20)) }
        try await client.quit()
        await client.close()
        await rig.cleanUp()
    }

    @Test("two uDecks subscribed to one session both see it; one leaving does not stop the other")
    func twoSubscribers() async throws {
        let rig = try Rig()
        let a = try await rig.client(), b = try await rig.client()
        let seenA = Collected(a.events), seenB = Collected(b.events)
        try await a.spawn(rig.spec("s1", "/bin/cat"))
        try await a.subscribe(session: "s1")
        try await b.subscribe(session: "s1")
        try await a.write(session: "s1", line: "one")
        try await seenB.until("one at b") { _ in seenB.lines("s1") == ["one"] }
        await a.close()
        try await Task.sleep(for: .milliseconds(100))
        try await b.write(session: "s1", line: "two")
        try await seenB.until("two at b") { _ in seenB.lines("s1") == ["one", "two"] }
        #expect(seenA.lines("s1").last != "two")
        try await b.closeInput(session: "s1")
        await b.close()
        await rig.cleanUp()
    }

    @Test("requests are refused before hello, with an unknown protocol, and for unknown sessions")
    func refusals() async throws {
        let rig = try Rig()
        let raw = try rig.connect()
        await #expect(performing: { _ = try await raw.list() }, throws: helperError("helloFirst"))
        await #expect(performing: { _ = try await raw.hello(client: "old", protocolVersion: 99) },
                      throws: helperError("protocolMismatch"))
        _ = try await raw.hello(client: "tests")
        await #expect(performing: { try await raw.write(session: "nope", line: "x") },
                      throws: helperError("unknownSession"))
        await #expect(performing: { try await raw.spawn(rig.spec("s1", "/nonexistent/agent")) },
                      throws: helperError("cannotStart"))
        #expect(try await raw.list().isEmpty)
        await raw.close()
        await rig.cleanUp()
    }

    @Test("a uDeck whose code does not satisfy the helper's requirement is cut off before anything reaches the helper")
    func helperRefusesPeer() async throws {
        let rig = try Rig(peerRequirement: #"identifier "place.unicorns.udeck.nobody""#)
        let client = try rig.connect()
        await #expect(performing: { _ = try await client.hello(client: "tests") },
                      throws: { ($0 as? AgentHostClient.Failure) == .closed })
        #expect(await rig.host.list().isEmpty)
        await rig.cleanUp()
    }

    @Test("uDeck will not talk to a helper whose code does not satisfy its requirement")
    func clientRefusesHelper() async throws {
        let rig = try Rig()
        let client = try rig.connect(helperRequirement: #"identifier "place.unicorns.udeck.nobody.agentd""#)
        await #expect(performing: { _ = try await client.hello(client: "tests") },
                      throws: { ($0 as? AgentHostClient.Failure) == .closed || $0 is AgentHostClient.Failure })
        await rig.cleanUp()
    }

    @Test("a requirement is fixed from this code's own signature or the other side's code hash")
    func requirements() throws {
        let own = try CodeIdentity.ownRequirement()
        try CodeIdentity.validate(own)
        #expect(throws: CodeIdentity.Failure.self) { try CodeIdentity.validate("this is not a requirement (") }
        let team = CodeIdentity.teamRequirement(identifier: "place.unicorns.udeck", team: "ABCDE12345")
        try CodeIdentity.validate(team)
        #expect(team.contains(#"leaf[subject.OU] = "ABCDE12345""#))
        let app = URL(fileURLWithPath: "/Applications/uDeck.app/Contents/Helpers/udeck-agentd")
        #expect(CodeIdentity.enclosingApplication(of: app)?.path == "/Applications/uDeck.app")
        #expect(CodeIdentity.enclosingApplication(of: URL(fileURLWithPath: "/usr/local/bin/udeck-agentd")) == nil)
    }
}
