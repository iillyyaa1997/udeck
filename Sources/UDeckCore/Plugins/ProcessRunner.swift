import Foundation

/// How a child process ended.
public enum Termination: Equatable, Sendable {
    case exited(code: Int32)
    case signalled(signal: Int32)

    /// The host killed it: it outlived its deadline.
    case timedOut(after: TimeInterval)

    /// The host killed it: it printed more than it was allowed to.
    case outputLimitExceeded(bytes: Int)

    /// It never started.
    case launchFailed(String)
}

public struct ProcessRunResult: Sendable {
    public let standardOutput: Data
    public let standardError: Data
    public let termination: Termination
    public let duration: TimeInterval
}

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
///   tail of a runaway producer's output is the right trade.
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
        Thread.detachNewThread {
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

        await collector.finish(after: drainGrace, pollEvery: Self.drainPollInterval)

        return ProcessRunResult(
            standardOutput: collector.standardOutput,
            standardError: collector.standardError,
            termination: outcome.resolve(natural: natural.value),
            duration: Date().timeIntervalSince(started)
        )
    }
}

/// How the child ended when nothing killed it, carried from the waiting thread.
private final class NaturalTermination: @unchecked Sendable {
    private let lock = NSLock()
    private var termination: Termination = .exited(code: 0)

    func record(_ value: Termination) {
        lock.lock(); defer { lock.unlock() }
        termination = value
    }

    var value: Termination {
        lock.lock(); defer { lock.unlock() }
        return termination
    }
}

/// A one-shot signal that is safe to arm before the thing it waits for.
///
/// The waiter may arrive after the signal has already fired, and must not
/// block for something that has already happened; the signal may arrive with no
/// waiter yet, and must be remembered. Both directions are what makes it usable
/// before `Process.run()`.
private final class TerminationSignal: @unchecked Sendable {
    private let lock = NSLock()
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
    private let lock = NSLock()
    private var timedOutAfter: TimeInterval?
    private var overflowBytes: Int?

    func recordTimeout(after seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        if timedOutAfter == nil && overflowBytes == nil { timedOutAfter = seconds }
    }

    func recordOverflow(bytes: Int) {
        lock.lock(); defer { lock.unlock() }
        if timedOutAfter == nil && overflowBytes == nil { overflowBytes = bytes }
    }

    func resolve(natural: Termination) -> Termination {
        lock.lock(); defer { lock.unlock() }
        if let seconds = timedOutAfter { return .timedOut(after: seconds) }
        if let bytes = overflowBytes { return .outputLimitExceeded(bytes: bytes) }
        return natural
    }
}

/// Drains both pipes while the child runs, stopping at a byte cap.
private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data()
    private var err = Data()
    private var overflow: Int?

    /// Every byte the producer sent, including the ones dropped. The number the
    /// operator is shown has to be the truth about the producer, not the size
    /// of the buffer that was allowed to hold it.
    private var observed = 0
    private var stdoutAtEndOfFile = false
    private var stderrAtEndOfFile = false
    private let limit: Int
    private var stdoutHandle: FileHandle?
    private var stderrHandle: FileHandle?

    init(limit: Int) { self.limit = limit }

    var standardOutput: Data { lock.lock(); defer { lock.unlock() }; return out }
    var standardError: Data { lock.lock(); defer { lock.unlock() }; return err }
    var overflowBytes: Int? { lock.lock(); defer { lock.unlock() }; return overflow }

    private var reachedEndOfFile: Bool {
        lock.lock(); defer { lock.unlock() }
        return stdoutAtEndOfFile && stderrAtEndOfFile
    }

    func attach(stdout: FileHandle, stderr: FileHandle) {
        stdoutHandle = stdout
        stderrHandle = stderr

        stdout.readabilityHandler = { [weak self] handle in
            self?.receive(handle.availableData, from: handle, isStandardOutput: true)
        }
        stderr.readabilityHandler = { [weak self] handle in
            self?.receive(handle.availableData, from: handle, isStandardOutput: false)
        }
    }

    /// Stops reading, giving the pipes a bounded moment to reach end-of-file
    /// first so that the tail of a normal producer's output is not lost.
    /// Waits — without blocking a thread — for the pipes to reach end-of-file,
    /// then stops reading.
    ///
    /// `Task.sleep` rather than `Thread.sleep`: this runs on the cooperative
    /// pool, and several plugins finishing at once would otherwise each hold a
    /// pool thread doing nothing for up to the grace period, starving whatever
    /// else was queued.
    func finish(after grace: TimeInterval, pollEvery interval: TimeInterval) async {
        let deadline = Date().addingTimeInterval(grace)
        while !reachedEndOfFile && Date() < deadline {
            // The readability handlers run on their own queue; this only has to
            // wait long enough for them to observe the last bytes and the
            // end-of-file that follows.
            try? await Task.sleep(nanoseconds: Seconds.nanoseconds(interval))
        }
        stdoutHandle?.readabilityHandler = nil
        stderrHandle?.readabilityHandler = nil
        stdoutHandle = nil
        stderrHandle = nil
    }

    private func receive(_ data: Data, from handle: FileHandle, isStandardOutput: Bool) {
        guard !data.isEmpty else {
            // End of file: everyone holding the write end has closed it.
            //
            // The handler must come off *here*, not later. A dispatch read
            // source stays permanently readable once the writer is gone, so
            // leaving it installed re-invokes this as fast as the queue can
            // dispatch — measured at one and a half million empty callbacks in
            // a second and a half, a full core for the rest of the producer's
            // life. And it is an ordinary shell idiom that gets you there:
            // print the card, redirect stdout away, then do the slow part.
            handle.readabilityHandler = nil

            lock.lock()
            // Recorded per handle rather than counted down. Counting made every
            // spurious empty read look like another pipe closing, so one pipe
            // spinning could drive the count to zero on its own and the drain
            // below would stop waiting while the other was still open.
            if isStandardOutput { stdoutAtEndOfFile = true } else { stderrAtEndOfFile = true }
            lock.unlock()
            return
        }

        lock.lock(); defer { lock.unlock() }

        // The cap has to bound what is *kept*, not only what is noticed. The
        // watcher that stops an overrunning producer looks every 25 ms and then
        // waits out a termination grace, and a producer writing as fast as the
        // pipe allows keeps arriving throughout — so a run nominally limited to
        // a megabyte could retain hundreds of them. Bytes past the allowance
        // are counted and dropped.
        observed += data.count
        let allowance = limit - (out.count + err.count)
        if allowance > 0 {
            let kept = allowance >= data.count ? data : data.prefix(allowance)
            if isStandardOutput { out.append(kept) } else { err.append(kept) }
        }
        if observed > limit && overflow == nil { overflow = observed }
    }
}
