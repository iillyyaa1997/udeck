import Foundation
import UDeckAgents

/// Where the helper delivers events: one connection from uDeck.
public protocol HostSink: AnyObject, Sendable {
    func deliver(_ line: String)
}

/// The helper's state: every agent it started, with its journal and who is
/// listening. It spawns, pipes lines and remembers — nothing in here knows what
/// a Claude Code or Codex message means, so a new agent or a new protocol
/// version never needs a new helper.
public actor AgentHost {
    public struct Failure: Error, Equatable {
        public let code: HostWire.ErrorCode
        public let message: String

        init(_ code: HostWire.ErrorCode, _ message: String) {
            self.code = code
            self.message = message
        }
    }

    public struct Limits: Sendable {
        /// After its agent exits, how long a session's journal is kept for a
        /// uDeck that has not come back yet.
        public var keepFinished: Duration = .seconds(6 * 3600)
        /// At most this many finished sessions are kept; the oldest go first.
        public var maxFinished = 64
        /// After an agent exits, how long its stdout may still be read: a
        /// background job it started can hold the pipe open for hours, and the
        /// exit must not wait for that.
        public var drainAfterExit: Duration = .seconds(1)

        public init() {}
    }

    private final class Session {
        var spec: SpawnSpec
        var process: AgentProcess?
        var journal: EventJournal
        /// Names this session's journal: a session forgotten and started again
        /// under the same id is a different journal, and a uDeck holding a
        /// position in the old one must not read the new one as its sequel.
        let epoch = UUID().uuidString
        var subscribers: [ObjectIdentifier: any HostSink] = [:]
        /// Bumped at every start, so lines still arriving from a previous
        /// process are not taken for the new one's.
        var generation = 0
        /// The exit status of the current generation, once it is journalled.
        var status: Int32?
        var startedAt = Date()
        var finishedAt: ContinuousClock.Instant?

        init(spec: SpawnSpec, journal: EventJournal) {
            self.spec = spec
            self.journal = journal
        }

        var running: Bool { process != nil && status == nil }
    }

    private struct Run: Hashable {
        let session: String
        let generation: Int
    }

    private var sessions: [String: Session] = [:]
    private let makeJournal: @Sendable () -> EventJournal
    private let limits: Limits
    private var exitWaiters: [Run: [CheckedContinuation<Void, Never>]] = [:]
    /// Set when shutdown begins: nothing new starts after that.
    private var stopping = false

    public init(journal: @escaping @Sendable () -> EventJournal = { EventJournal() }, limits: Limits = Limits()) {
        makeJournal = journal
        self.limits = limits
    }

    // MARK: - Agents

    /// Starts an agent under `spec.session`. A session whose agent exited can
    /// be started again (a resume): its journal goes on, numbering included.
    @discardableResult
    public func spawn(_ spec: SpawnSpec) throws(Failure) -> Int32 {
        guard !stopping else { throw Failure(.stopping, "the helper is stopping") }
        prune()
        let session: Session
        if let existing = sessions[spec.session] {
            guard !existing.running else { throw Failure(.sessionExists, "session \(spec.session) is running") }
            existing.spec = spec
            session = existing
        } else {
            session = Session(spec: spec, journal: makeJournal())
            sessions[spec.session] = session
        }
        let process: AgentProcess
        do {
            process = try AgentProcess(executable: URL(fileURLWithPath: spec.executable), arguments: spec.arguments,
                                       environment: spec.environment,
                                       directory: URL(fileURLWithPath: spec.directory, isDirectory: true))
        } catch {
            if session.process == nil, session.journal.lastSeq == 0 { sessions[spec.session] = nil }
            throw Failure(.cannotStart, "\(spec.executable): \(error)")
        }
        session.generation += 1
        session.process = process
        session.status = nil
        session.finishedAt = nil
        session.startedAt = Date()
        record(spec.session, .started(pid: process.processIdentifier))
        let run = Run(session: spec.session, generation: session.generation)
        let drain = limits.drainAfterExit
        Task { [weak self] in
            // Stdout and the exit race: an agent's background job can keep the
            // pipe open long after the agent itself is gone, so the exit is
            // recorded after at most `drain` more of reading, not at EOF.
            let reader = Task { [weak self] in
                for await piece in process.lines {
                    switch piece {
                    case .line(let text): await self?.record(run, .line(text))
                    case .overlong(let bytes): await self?.record(run, .overlong(bytes: bytes))
                    }
                }
            }
            let exit = await process.exit()
            let drained = Task {
                try? await Task.sleep(for: drain)
                reader.cancel()
            }
            await reader.value
            drained.cancel()
            await self?.exited(run, exit)
        }
        return process.processIdentifier
    }

    /// Queues one line for the agent and journals it under `tag` once it is in
    /// the agent's stdin queue — uDeck's proof of delivery is that input event
    /// coming back.
    public func write(session id: String, line: String, tag: String?) throws(Failure) {
        let session = try live(id)
        do {
            try session.process?.write(line: line)
        } catch AgentProcess.Failure.backlogged(let bytes) {
            throw Failure(.backlogged, "session \(id) has not read \(bytes) bytes it was sent")
        } catch {
            throw Failure(.notRunning, "session \(id) is not running")
        }
        if let tag { record(id, .input(tag: tag)) }
    }

    public func closeInput(session id: String) throws(Failure) {
        try live(id).process?.closeInput()
    }

    /// Stops the agent: SIGTERM, then SIGKILL after `grace`. Returns the exit
    /// status of the run that was going when it was asked — never that of one
    /// started meanwhile under the same session.
    public func terminate(session id: String, grace: Duration) async throws(Failure) -> Int32 {
        guard let session = sessions[id] else { throw Failure(.unknownSession, "no session \(id)") }
        if let status = session.status { return status }
        guard let process = session.process else { throw Failure(.notRunning, "session \(id) never started") }
        let run = Run(session: id, generation: session.generation)
        let exit = await process.terminate(grace: grace)
        await waitForExit(of: run, upTo: limits.drainAfterExit + .seconds(2))
        guard let now = sessions[id], now.generation == run.generation, let status = now.status else {
            return exit.status
        }
        return status
    }

    /// Drops a finished session and its journal.
    public func forget(session id: String) throws(Failure) {
        guard let session = sessions[id] else { throw Failure(.unknownSession, "no session \(id)") }
        guard !session.running else { throw Failure(.stillRunning, "session \(id) is running") }
        sessions[id] = nil
    }

    public func list() -> [SessionSummary] {
        prune()
        return sessions.keys.sorted().compactMap { summary(of: $0) }
    }

    public var hasRunningAgents: Bool { sessions.values.contains { $0.running } }

    public var isStopping: Bool { stopping }

    /// Stops every agent as cleanly as it can, all within `grace`: from now on
    /// nothing new starts; each agent gets its stop line and then end of input,
    /// so it finishes and exits; at `grace` minus a margin whatever still runs
    /// is terminated, all at once.
    public func shutdown(grace: Duration) async {
        stopping = true
        let clock = ContinuousClock()
        let deadline = clock.now + grace
        let margin = min(grace / 4, .seconds(4))
        for session in sessions.values where session.running {
            if let stopLine = session.spec.stopLine { try? session.process?.write(line: stopLine) }
            session.process?.closeInput()
        }
        while hasRunningAgents, clock.now < deadline - margin {
            try? await Task.sleep(for: .milliseconds(50))
        }
        let stubborn = sessions.values.filter(\.running).compactMap(\.process)
        let left = max(.zero, deadline - clock.now - .milliseconds(200))
        await withTaskGroup(of: Void.self) { group in
            for process in stubborn {
                group.addTask { _ = await process.terminate(grace: left / 2) }
            }
        }
        while hasRunningAgents, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    // MARK: - Listening

    /// Sends `sink` the session's journalled events after `seq`, then the
    /// acknowledgement `acknowledge` builds, then every new event as it
    /// happens — in that order, with nothing in between.
    public func subscribe(session id: String, after seq: Int, epoch: String?, sink: any HostSink,
                          acknowledge: @Sendable (SubscriptionState) -> String?) throws(Failure)
    {
        guard let session = sessions[id] else { throw Failure(.unknownSession, "no session \(id)") }
        // A position in another journal means nothing here: start over.
        let from = (epoch == nil || epoch == session.epoch) ? seq : 0
        let (events, gap) = session.journal.after(from)
        for event in events {
            if let line = try? event.wire.encodedLine() { sink.deliver(line) }
        }
        let state = SubscriptionState(firstSeq: session.journal.firstSeq, lastSeq: session.journal.lastSeq,
                                      gap: gap || from != seq, epoch: session.epoch)
        if let reply = acknowledge(state) { sink.deliver(reply) }
        session.subscribers[ObjectIdentifier(sink)] = sink
    }

    public func unsubscribe(session id: String, sink: any HostSink) {
        sessions[id]?.subscribers[ObjectIdentifier(sink)] = nil
    }

    /// A connection went away.
    public func drop(_ sink: any HostSink) {
        for session in sessions.values { session.subscribers[ObjectIdentifier(sink)] = nil }
    }

    func subscriberCount(session id: String) -> Int { sessions[id]?.subscribers.count ?? 0 }

    // MARK: - Inside

    private func live(_ id: String) throws(Failure) -> Session {
        guard let session = sessions[id] else { throw Failure(.unknownSession, "no session \(id)") }
        guard session.running else { throw Failure(.notRunning, "session \(id) is not running") }
        return session
    }

    private func summary(of id: String) -> SessionSummary? {
        guard let session = sessions[id] else { return nil }
        return SessionSummary(session: id, pid: session.process?.processIdentifier, running: session.running,
                              firstSeq: session.journal.firstSeq, lastSeq: session.journal.lastSeq,
                              status: session.status, startedAt: session.startedAt, epoch: session.epoch)
    }

    /// Finished sessions past their time, and the oldest beyond the count.
    private func prune() {
        let now = ContinuousClock.now
        for (id, session) in sessions {
            if let finished = session.finishedAt, now - finished > limits.keepFinished { sessions[id] = nil }
        }
        let finished = sessions.filter { $0.value.finishedAt != nil }
            .sorted { $0.value.finishedAt! < $1.value.finishedAt! }
        for (id, _) in finished.dropLast(limits.maxFinished) { sessions[id] = nil }
    }

    private func record(_ run: Run, _ kind: HostEvent.Kind) {
        guard let session = sessions[run.session], session.generation == run.generation, session.status == nil
        else { return }
        record(run.session, kind)
    }

    private func record(_ id: String, _ kind: HostEvent.Kind) {
        guard let session = sessions[id] else { return }
        let event = session.journal.append(session: id, kind)
        guard !session.subscribers.isEmpty, let line = try? event.wire.encodedLine() else { return }
        for sink in session.subscribers.values { sink.deliver(line) }
    }

    private func exited(_ run: Run, _ exit: AgentProcess.Exit) {
        defer { for waiter in exitWaiters.removeValue(forKey: run) ?? [] { waiter.resume() } }
        guard let session = sessions[run.session], session.generation == run.generation else { return }
        record(run.session, .exited(status: exit.status, stderrTail: exit.stderrTail))
        session.status = exit.status
        session.finishedAt = .now
    }

    /// Waits for `run`'s exit to be journalled, at most `limit`.
    private func waitForExit(of run: Run, upTo limit: Duration) async {
        guard let session = sessions[run.session], session.generation == run.generation, session.status == nil
        else { return }
        let timer = Task { [weak self] in
            try? await Task.sleep(for: limit)
            await self?.releaseWaiters(of: run)
        }
        await withCheckedContinuation { exitWaiters[run, default: []].append($0) }
        timer.cancel()
    }

    private func releaseWaiters(of run: Run) {
        for waiter in exitWaiters.removeValue(forKey: run) ?? [] { waiter.resume() }
    }
}

/// Where a subscription starts, as its acknowledgement reports it.
public struct SubscriptionState: Sendable, Equatable {
    public let firstSeq: Int
    public let lastSeq: Int
    /// Some of what was asked for is no longer in the journal, or the position
    /// was in another journal of the same session id.
    public let gap: Bool
    public let epoch: String
}
