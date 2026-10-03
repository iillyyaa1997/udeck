#if canImport(Darwin)
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import Darwin

/// Runs a child process under a deadline the caller owns.
///
/// The deadline lives here, in the host, and not in the plugin, for a concrete
/// reason: a stock macOS has neither `timeout` nor `gtimeout`, so a shell
/// producer genuinely cannot police itself. A host that trusted producers to
/// exit on time would eventually freeze a card on a stale value and never say
/// why — which is the exact failure this whole design is arranged to avoid.
///
/// Three things here are less obvious than they look, and each was a hang
/// before it was a rule:
///
/// * **Output is drained while the process runs**, not after it exits. A child
///   that fills the pipe buffer blocks on `write`, so collecting output only at
///   the end would turn "this plugin prints a lot" into "this plugin always
///   times out".
/// * **Killing a producer kills what it started.** A producer that runs `sleep`
///   in the background leaves that child holding the pipe open after its parent
///   dies — and if the host only ever signalled the direct child, a plugin
///   polled every five seconds would leave a new orphan behind on every tick.
/// * **Waiting for end-of-file is bounded.** If something still holds the write
///   end — an orphaned grandchild the host could not reach — end-of-file never
///   arrives, and an unbounded read there would hang the host itself. Losing the
///   tail of a runaway producer's output is the right trade. So is the wait for
///   the reading thread to let go of the pipes after that: a grandchild that
///   left the group with `setsid` holds them for as long as it likes.
///
/// uDeck runs every producer with this, and `udeck-plugin run` runs one with it
/// too: the same deadline, the same group, the same limit.
public struct ProcessRunner: Sendable {
    /// Seconds between SIGTERM and SIGKILL when a process overruns. Enough for
    /// a well-behaved producer to clean up, short enough that a wedged one does
    /// not hold its slot.
    public var terminationGrace: TimeInterval

    /// How long to keep reading after the process has ended, waiting for the
    /// pipes to reach end-of-file.
    public var drainGrace: TimeInterval

    /// Most a single run may print before the host stops it.
    public var maximumOutputBytes: Int

    /// How often the output cap is checked, and how finely the drain waits for
    /// end-of-file. Both are measurement resolutions rather than preferences:
    /// small enough not to matter, large enough not to spin.
    private static let limitCheckInterval: TimeInterval = 0.025
    private static let drainPollInterval: TimeInterval = 0.005

    /// How long past the plugin's own timeout — the time it was given already
    /// — a run waits at most for its reading thread to stop once asked. See
    /// `OutputCollector.finish`.
    static let stopMargin: TimeInterval = 0.5

    public init(
        terminationGrace: TimeInterval = 0.5,
        drainGrace: TimeInterval = 0.5,
        maximumOutputBytes: Int = 1 << 20
    ) {
        self.terminationGrace = terminationGrace
        self.drainGrace = drainGrace
        self.maximumOutputBytes = maximumOutputBytes
    }

    public func run(
        executable: URL,
        arguments: [String],
        workingDirectory: URL,
        environment: [String: String],
        timeout: TimeInterval
    ) async -> ProcessRunResult {
        let started = Date()
        let collector = OutputCollector(limit: maximumOutputBytes)

        let child: SpawnedProcess
        do {
            child = try ProcessGroup.spawn(
                executable: executable,
                arguments: arguments,
                workingDirectory: workingDirectory,
                environment: environment
            )
        } catch {
            return ProcessRunResult(
                standardOutput: Data(),
                standardError: Data("\(error)".utf8),
                termination: .launchFailed("\(error)"),
                duration: Date().timeIntervalSince(started)
            )
        }

        collector.attach(stdout: child.standardOutput, stderr: child.standardError)

        // `waitid` blocks, so it gets a thread of its own rather than one of the
        // cooperative pool's. The signal is armed before the wait starts, and
        // both directions of it work: a producer that exits in milliseconds
        // fires it before anybody is waiting, and it is remembered.
        let ended = TerminationSignal()
        let natural = NaturalTermination()
        SystemThread.detach {
            natural.record(ProcessGroup.waitForExit(pid: child.pid))
            ended.signal()
        }

        let outcome = Outcome()

        let watchdog = Task {
            try? await Task.sleep(nanoseconds: Seconds.nanoseconds(timeout))
            guard !Task.isCancelled else { return }
            outcome.recordTimeout(after: timeout)
            await ProcessGroup.terminate(
                group: child.processGroup,
                grace: terminationGrace, pollEvery: Self.limitCheckInterval
            )
        }

        // A separate watcher for the output cap, for the same reason a deadline
        // is needed at all: a producer in a `while true: print` loop never ends
        // on its own, and would otherwise be held only by the (longer) timeout.
        let limitWatcher = Task {
            while !Task.isCancelled {
                if let overflow = collector.overflowBytes {
                    outcome.recordOverflow(bytes: overflow)
                    await ProcessGroup.terminate(
                        group: child.processGroup,
                        grace: terminationGrace, pollEvery: Self.limitCheckInterval
                    )
                    return
                }
                try? await Task.sleep(nanoseconds: Seconds.nanoseconds(Self.limitCheckInterval))
            }
        }

        await ended.wait()

        watchdog.cancel()
        limitWatcher.cancel()

        // On *every* path, not only the two the watchers cover. A producer that
        // starts something detached and then exits cleanly is the common shape
        // of this, and it used to leave that child running once per poll for as
        // long as the panel was open.
        await ProcessGroup.terminate(
            group: child.processGroup,
            grace: terminationGrace, pollEvery: Self.limitCheckInterval
        )
        ProcessGroup.reap(pid: child.pid)

        await collector.finish(after: drainGrace, pollEvery: Self.drainPollInterval,
                               stopWithin: max(timeout, 0) + Self.stopMargin)

        let dropped = collector.dropped
        return ProcessRunResult(
            standardOutput: collector.standardOutput,
            standardError: collector.standardError,
            termination: outcome.resolve(natural: natural.value),
            duration: Date().timeIntervalSince(started),
            standardOutputDropped: dropped.output,
            standardErrorDropped: dropped.error
        )
    }
}

extension ProcessRunner {
    /// Runs a plugin's producer once, as uDeck runs it: `run[0]` as discovery
    /// resolved it (`executable`), the rest of `run` as its arguments, in the
    /// plugin's own folder, with `environment`, under the manifest's
    /// `timeout`.
    public func run(producerOf plugin: DiscoveredPlugin, manifest: PluginManifest, executable: URL,
                    environment: [String: String]) async -> ProcessRunResult {
        await run(
            executable: executable,
            arguments: Array(manifest.run.dropFirst()),
            workingDirectory: plugin.directory,
            environment: environment,
            timeout: manifest.timeout ?? 0
        )
    }
}

/// How the child ended when nothing killed it, carried from the waiting thread.
private final class NaturalTermination: @unchecked Sendable {
    private let lock = SystemLock()
    private var termination: Termination = .exited(code: 0)

    func record(_ value: Termination) {
        lock.withLock { termination = value }
    }

    var value: Termination {
        lock.withLock { termination }
    }
}

/// A one-shot signal that is safe to arm before the thing it waits for.
///
/// The waiter may arrive after the signal has already fired, and must not
/// block for something that has already happened; the signal may arrive with no
/// waiter yet, and must be remembered. Both directions are what makes it usable
/// before the process is started.
private final class TerminationSignal: @unchecked Sendable {
    private let lock = SystemLock()
    private var hasFired = false
    private var waiter: CheckedContinuation<Void, Never>?

    func signal() {
        lock.lock()
        let continuation = waiter
        waiter = nil
        hasFired = true
        lock.unlock()
        continuation?.resume()
    }

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if hasFired {
                lock.unlock()
                continuation.resume()
                return
            }
            waiter = continuation
            lock.unlock()
        }
    }
}

/// Why the host killed a process, if it did. The kernel reports a killed child
/// as "died on a signal", which on its own would be indistinguishable from a
/// plugin that crashed — and telling an author "your plugin crashed" when in
/// fact it ran too long would send them looking in the wrong place.
private final class Outcome: @unchecked Sendable {
    private let lock = SystemLock()
    private var timedOutAfter: TimeInterval?
    private var overflowBytes: Int?

    func recordTimeout(after seconds: TimeInterval) {
        lock.withLock {
            if timedOutAfter == nil && overflowBytes == nil { timedOutAfter = seconds }
        }
    }

    func recordOverflow(bytes: Int) {
        lock.withLock {
            if timedOutAfter == nil && overflowBytes == nil { overflowBytes = bytes }
        }
    }

    func resolve(natural: Termination) -> Termination {
        lock.withLock {
            if let seconds = timedOutAfter { return .timedOut(after: seconds) }
            if let bytes = overflowBytes { return .outputLimitExceeded(bytes: bytes) }
            return natural
        }
    }
}

/// Drains both pipes while the child runs, stopping at a byte cap.
///
/// On a thread of its own that waits in `poll` for either pipe to have
/// something, reads what is there, and stops waiting on a pipe at its
/// end-of-file — a pipe whose writers are all gone stays readable for ever,
/// and reading it again and again is how a host spends a core on a producer
/// that closed its output and went on with something slow. Both read ends
/// belong to this collector, which closes them when it stops.
private final class OutputCollector: @unchecked Sendable {
    private let lock = SystemLock()
    private var out = Data()
    private var err = Data()
    private var overflow: Int?

    /// What was dropped of each, past the limit: bytes the producer sent and
    /// nobody keeps. Said by `udeck-plugin run`, so that "everything it wrote"
    /// is never a megabyte of it.
    private var outDropped = 0
    private var errDropped = 0

    /// Every byte the producer sent, including the ones dropped. The number the
    /// operator is shown has to be the truth about the producer, not the size
    /// of the buffer that was allowed to hold it.
    private var observed = 0
    private var stdoutAtEndOfFile = false
    private var stderrAtEndOfFile = false
    private var stopRequested = false
    private var stopped = false
    private let limit: Int

    /// How long one wait in `poll` lasts at most, in milliseconds: how soon the
    /// reading thread sees that it has been asked to stop. Not how output is
    /// read — `poll` answers the moment a pipe has something.
    private static let pollMilliseconds: Int32 = 10

    init(limit: Int) { self.limit = limit }

    var standardOutput: Data { lock.withLock { out } }
    var standardError: Data { lock.withLock { err } }
    var overflowBytes: Int? { lock.withLock { overflow } }
    var dropped: (output: Int, error: Int) { lock.withLock { (outDropped, errDropped) } }

    private var reachedEndOfFile: Bool {
        lock.withLock { stdoutAtEndOfFile && stderrAtEndOfFile }
    }

    func attach(stdout: Int32, stderr: Int32) {
        SystemThread.detach { [self] in read(stdout: stdout, stderr: stderr) }
    }

    /// Stops reading, giving the pipes a bounded moment to reach end-of-file
    /// first so that the tail of a normal producer's output is not lost.
    /// Waits — without blocking a thread — for the pipes to reach end-of-file,
    /// then stops reading, and returns once both read ends are closed, or once
    /// `stopWithin` has passed with the reading thread still at them.
    ///
    /// `Task.sleep` rather than `Thread.sleep`: this runs on the cooperative
    /// pool, and several plugins finishing at once would otherwise each hold a
    /// pool thread doing nothing for up to the grace period, starving whatever
    /// else was queued.
    func finish(after grace: TimeInterval, pollEvery interval: TimeInterval, stopWithin limit: TimeInterval) async {
        let deadline = Date().addingTimeInterval(grace)
        while !reachedEndOfFile && Date() < deadline {
            // The reading thread runs on its own; this only has to wait long
            // enough for it to see the last bytes and the end-of-file after.
            try? await Task.sleep(nanoseconds: Seconds.nanoseconds(interval))
        }
        lock.withLock { stopRequested = true }
        // A few milliseconds — one wait in `poll`: the descriptors are this
        // run's, and a run that returned with them open would be a leak
        // counted a few thousand polls later.
        //
        // And never longer than `limit`. Only a reading thread that does not
        // look at the request — or one the machine does not let run — gets
        // there, and then nothing ends it but end-of-file: a grandchild that
        // left the group (`setsid`) and kept the pipes would hold the run, and
        // the plugin's next poll, for as long as it lives. Past the limit the
        // run returns what was read, and the thread closes the descriptors
        // whenever it does stop: late, not leaked.
        let stopDeadline = Date().addingTimeInterval(limit)
        while !lock.withLock({ stopped }) && Date() < stopDeadline {
            await ProcessGroup.sleepIgnoringCancellation(0.001)
        }
    }

    private func read(stdout: Int32, stderr: Int32) {
        var pipes = [pollfd(fd: stdout, events: Int16(POLLIN), revents: 0),
                     pollfd(fd: stderr, events: Int16(POLLIN), revents: 0)]
        var buffer = [UInt8](repeating: 0, count: 65536)
        while !lock.withLock({ stopRequested }), pipes.contains(where: { $0.fd >= 0 }) {
            let ready = poll(&pipes, nfds_t(pipes.count), Self.pollMilliseconds)
            if ready < 0 {
                if errno == EINTR { continue }
                break
            }
            for index in pipes.indices where pipes[index].fd >= 0 && pipes[index].revents != 0 {
                let count = buffer.withUnsafeMutableBytes { Darwin.read(pipes[index].fd, $0.baseAddress, $0.count) }
                if count > 0 {
                    receive(Data(buffer[..<count]), isStandardOutput: index == 0)
                } else if count < 0 && (errno == EINTR || errno == EAGAIN) {
                    continue
                } else {
                    // End of file: everyone holding the write end has closed
                    // it — or a read that failed, which ends the pipe the same
                    // way. Not waited on again.
                    //
                    // Recorded per pipe rather than counted down. Counting made
                    // every spurious empty read look like another pipe closing,
                    // so one pipe could drive the count to zero on its own and
                    // the drain would stop waiting while the other was still open.
                    lock.withLock {
                        if index == 0 { stdoutAtEndOfFile = true } else { stderrAtEndOfFile = true }
                    }
                    pipes[index].fd = -1
                }
            }
        }
        close(stdout)
        close(stderr)
        lock.withLock { stopped = true }
    }

    private func receive(_ data: Data, isStandardOutput: Bool) {
        lock.lock(); defer { lock.unlock() }

        // The cap has to bound what is *kept*, not only what is noticed. The
        // watcher that stops an overrunning producer looks every 25 ms and then
        // waits out a termination grace, and a producer writing as fast as the
        // pipe allows keeps arriving throughout — so a run nominally limited to
        // a megabyte could retain hundreds of them. Bytes past the allowance
        // are counted and dropped.
        observed += data.count
        let allowance = max(limit - (out.count + err.count), 0)
        let kept = allowance >= data.count ? data : data.prefix(allowance)
        if isStandardOutput {
            out.append(kept)
            outDropped += data.count - kept.count
        } else {
            err.append(kept)
            errDropped += data.count - kept.count
        }
        if observed > limit && overflow == nil { overflow = observed }
    }
}
#endif
