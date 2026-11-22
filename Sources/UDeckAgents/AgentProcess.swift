import Foundation

/// One agent program running with its stdio connected: lines in, lines out.
///
/// Both agents speak newline-delimited JSON on stdin/stdout, so this is the one
/// place that starts a program, cuts its stdout into lines, writes lines to its
/// stdin and keeps the tail of its stderr for when something goes wrong.
/// Protocol meaning lives above it, in `ClaudeCodeConnection` and its Codex
/// sibling.
///
/// Lines are delivered in the order the program wrote them, through one
/// `AsyncStream`, and the stream finishes when stdout closes. Writing after the
/// program exited throws instead of raising SIGPIPE in uDeck.
///
/// Writes never block the caller: a program that stops reading its stdin fills
/// the pipe, and a blocking write would then stall whoever wrote — the helper's
/// whole actor, every session with it. They go through a queue of their own, in
/// order, with closing stdin queued behind them, and past `maxBacklog` unsent
/// bytes a write is refused instead.
///
/// `@unchecked Sendable`: `Process` and `FileHandle` are not marked Sendable, but
/// the only calls made on them after start — write, close, terminate, the pid —
/// are safe from any thread; everything mutable is behind `state`'s lock.
public final class AgentProcess: AgentChannel, @unchecked Sendable {
    public struct Exit: Sendable, Equatable {
        public let status: Int32
        /// The last part of what the program wrote on stderr.
        public let stderrTail: String

        public init(status: Int32, stderrTail: String) {
            self.status = status
            self.stderrTail = stderrTail
        }
    }

    public enum Failure: Error, Equatable {
        case notRunning
        case cannotStart(String)
        /// The program has not read what it was sent; more is refused.
        case backlogged(bytes: Int)
    }

    public static let maxBacklog = 64 * 1024 * 1024

    private let process: Process
    private let stdin: FileHandle
    private let stdout: FileHandle
    private let stderr: FileHandle
    private let stdinQueue = DispatchQueue(label: "udeck.agent.stdin")
    private let state = Locked(State())
    public let lines: AsyncStream<LineFramer.Piece>
    private let linesContinuation: AsyncStream<LineFramer.Piece>.Continuation

    private struct State {
        var framer = LineFramer()
        var stderr = Data()
        var exit: Exit?
        var exitWaiters: [CheckedContinuation<Exit, Never>] = []
        var stdoutDone = false
        var backlog = 0
        var inputClosed = false
        /// Writes still queued are dropped: the program is gone, or its output
        /// was let go of (`detachOutput`).
        var abandoned = false
    }

    /// Starts `executable` with `arguments` in `directory`, with exactly
    /// `environment` (nothing inherited: the caller decides what the agent sees).
    public init(executable: URL, arguments: [String], environment: [String: String], directory: URL) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = directory
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        self.process = process
        self.stdin = input.fileHandleForWriting
        self.stdout = output.fileHandleForReading
        self.stderr = errors.fileHandleForReading
        (lines, linesContinuation) = AsyncStream.makeStream(of: LineFramer.Piece.self)

        // SIGPIPE on a write to an agent that already exited would kill uDeck;
        // ignoring it turns that write into an error the caller sees.
        signal(SIGPIPE, SIG_IGN)

        let state = self.state, continuation = linesContinuation
        output.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                let rest = state.withLock { state -> [LineFramer.Piece] in
                    guard !state.stdoutDone else { return [] }
                    state.stdoutDone = true
                    return state.framer.finish()
                }
                rest.forEach { continuation.yield($0) }
                continuation.finish()
                return
            }
            let pieces = state.withLock { $0.stdoutDone ? [] : $0.framer.feed(chunk) }
            pieces.forEach { continuation.yield($0) }
        }
        errors.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            state.withLock { state in
                state.stderr.append(chunk)
                // A program that logs a lot to stderr must not grow uDeck without
                // bound; the tail is what explains a failure.
                if state.stderr.count > 64 * 1024 { state.stderr.removeFirst(state.stderr.count - 32 * 1024) }
            }
        }
        process.terminationHandler = { finished in
            let waiters = state.withLock { state -> [CheckedContinuation<Exit, Never>] in
                state.abandoned = true
                let exit = Exit(status: finished.terminationStatus,
                                stderrTail: String(decoding: state.stderr, as: UTF8.self))
                state.exit = exit
                defer { state.exitWaiters.removeAll() }
                return state.exitWaiters
            }
            let exit = state.withLock { $0.exit! }
            waiters.forEach { $0.resume(returning: exit) }
        }
        do {
            try process.run()
            // Our end only: a write that would block returns EAGAIN, and the
            // writer waits for room in short slices it can give up between.
            let descriptor = input.fileHandleForWriting.fileDescriptor
            _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            errors.fileHandleForReading.readabilityHandler = nil
            linesContinuation.finish()
            throw Failure.cannotStart(error.localizedDescription)
        }
    }

    public var processIdentifier: Int32 { process.processIdentifier }

    public var isRunning: Bool { state.withLock { $0.exit == nil } }

    /// Queues one line (a newline is added) for the program's stdin.
    public func write(line: String) throws {
        let bytes = Data((line + "\n").utf8)
        let descriptor = stdin.fileDescriptor, state = self.state, queue = stdinQueue
        // Admitted and queued in one step, so a close cannot slip in between
        // and leave an accepted line behind it.
        try state.withLock { current in
            guard current.exit == nil, !current.inputClosed else { throw Failure.notRunning }
            guard current.backlog + bytes.count <= Self.maxBacklog else {
                throw Failure.backlogged(bytes: current.backlog)
            }
            current.backlog += bytes.count
            queue.async {
                // A program that exited meanwhile: the write fails, SIGPIPE is
                // ignored, and its exit says the rest.
                Self.writeAll(bytes, to: descriptor) { state.withLock { $0.abandoned } }
                state.withLock { $0.backlog -= bytes.count }
            }
        }
    }

    /// Writes all of `bytes` to a non-blocking descriptor, waiting for room in
    /// slices of 100 ms and giving up when `abandon` says so or the write fails.
    private static func writeAll(_ bytes: Data, to descriptor: Int32, abandon: () -> Bool) {
        bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(descriptor, base + offset, raw.count - offset)
                if written > 0 {
                    offset += written
                } else if written < 0, errno == EAGAIN || errno == EINTR {
                    if abandon() { return }
                    var waiting = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
                    _ = poll(&waiting, 1, 100)
                } else {
                    return
                }
            }
        }
    }

    /// Stops reading the program's output and drops whatever is still queued
    /// for its stdin: after it exited, a job it left running can hold the
    /// pipes open indefinitely, and nothing of that belongs to the session.
    public func detachOutput() {
        state.withLock { $0.abandoned = true }
        // Not closed: a read in flight on a closed handle raises. The pipes go
        // with this object; whoever still writes to them blocks, unread.
        stdout.readabilityHandler = nil
        stderr.readabilityHandler = nil
        let rest = state.withLock { state -> [LineFramer.Piece] in
            guard !state.stdoutDone else { return [] }
            state.stdoutDone = true
            return state.framer.finish()
        }
        rest.forEach { linesContinuation.yield($0) }
        linesContinuation.finish()
        closeInput()
    }

    /// Bytes written but not yet taken by the program's stdin.
    public var backlog: Int { state.withLock { $0.backlog } }

    /// Closes stdin once everything written before has gone: for both agents,
    /// the end of the conversation. They finish what they are doing and exit.
    public func closeInput() {
        let stdin = self.stdin, queue = stdinQueue
        state.withLock { state in
            guard !state.inputClosed else { return }
            state.inputClosed = true
            queue.async { try? stdin.close() }
        }
    }

    /// Asks the program to stop (SIGTERM), then kills it if it has not gone
    /// after `grace`.
    public func terminate(grace: Duration = .seconds(3)) async -> Exit {
        if let exit = state.withLock({ $0.exit }) { return exit }
        process.terminate()
        let deadline = ContinuousClock.now + grace
        while isRunning, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        if isRunning { kill(process.processIdentifier, SIGKILL) }
        return await exit()
    }

    /// Waits for the program to exit.
    public func exit() async -> Exit {
        await withCheckedContinuation { continuation in
            let done = state.withLock { state -> Exit? in
                if let exit = state.exit { return exit }
                state.exitWaiters.append(continuation)
                return nil
            }
            if let done { continuation.resume(returning: done) }
        }
    }
}

/// An agent's stdio as the connections use it: lines out, lines in.
///
/// Either the agent runs right here (`AgentProcess`), or the helper runs it and
/// this is the helper's socket standing in for its pipes (`HostedAgent`, in
/// UDeckAgentHost). The protocol code above does not know which.
public protocol AgentChannel: Sendable {
    /// What the agent writes, line by line; finishes when its stdout closes.
    /// One reader.
    var lines: AsyncStream<LineFramer.Piece> { get }
    /// Queues one line for the agent's stdin, in order with every other line
    /// written; throws if the agent is known to be gone.
    func write(line: String) throws
    /// Closes the agent's stdin.
    func closeInput()
    /// SIGTERM, then SIGKILL after `grace`.
    func terminate(grace: Duration) async -> AgentProcess.Exit
    /// Waits for the agent to exit.
    func exit() async -> AgentProcess.Exit
    var processIdentifier: Int32 { get }
}

/// A value behind a lock, for state the pipe handlers (on their own queues)
/// and callers share.
final class Locked<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    init(_ value: Value) { self.value = value }

    func withLock<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
}
