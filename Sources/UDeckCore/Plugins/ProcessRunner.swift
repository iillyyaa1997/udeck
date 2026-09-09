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
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        process.environment = environment

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        let collector = OutputCollector(limit: maximumOutputBytes)
        collector.attach(stdout: outPipe.fileHandleForReading, stderr: errPipe.fileHandleForReading)

        // Armed *before* the process starts. Assigning `terminationHandler`
        // afterwards is a race that a fast producer wins: `echo '{}'` exits in
        // milliseconds, and if it exits before the property is set, the handler
        // is never called and the wait below never returns — that plugin stops
        // updating for the rest of the session with no error anywhere.
        let ended = TerminationSignal()
        process.terminationHandler = { _ in ended.signal() }

        do {
            try process.run()
        } catch {
            await collector.finish(after: 0, pollEvery: Self.drainPollInterval)
            return ProcessRunResult(
                standardOutput: Data(),
                standardError: Data("\(error)".utf8),
                termination: .launchFailed("\(error)"),
                duration: Date().timeIntervalSince(started)
            )
        }

        let pid = process.processIdentifier
        let stop = Stopper(pid: pid, grace: terminationGrace)

        let outcome = Outcome()

        let watchdog = Task {
            try? await Task.sleep(nanoseconds: Seconds.nanoseconds(timeout))
            guard !Task.isCancelled else { return }
            outcome.recordTimeout(after: timeout)
            await stop.terminate()
        }

        // A separate watcher for the output cap, for the same reason a deadline
        // is needed at all: a producer in a `while true: print` loop never ends
        // on its own, and would otherwise be held only by the (longer) timeout.
        let limitWatcher = Task {
            while !Task.isCancelled {
                if let overflow = collector.overflowBytes {
                    outcome.recordOverflow(bytes: overflow)
                    await stop.terminate()
                    return
                }
                try? await Task.sleep(nanoseconds: Seconds.nanoseconds(Self.limitCheckInterval))
            }
        }

        await ended.wait()

        watchdog.cancel()
        limitWatcher.cancel()
        await collector.finish(after: drainGrace, pollEvery: Self.drainPollInterval)

        return ProcessRunResult(
            standardOutput: collector.standardOutput,
            standardError: collector.standardError,
            termination: outcome.resolve(
                status: process.terminationStatus,
                reason: process.terminationReason
            ),
            duration: Date().timeIntervalSince(started)
        )
    }
}

/// Stops a producer and everything it started, politely first and then not.
///
/// The obvious implementation — give the child its own process group and signal
/// the group — is not available here. Foundation's `Process` exposes no spawn
/// attributes, and `setpgid` called from the parent afterwards always loses:
/// `posix_spawn` has already exec'd the child by the time `run()` returns, and
/// `setpgid` on a process that has exec'd fails with `EACCES`. So the tree is
/// enumerated instead, before the first signal — once the direct child dies its
/// children are re-parented to `launchd`, and a later enumeration would no
/// longer connect them to anything.
///
/// Two things here are less obvious than they look.
///
/// **The grace period has to survive cancellation, or it is not a grace
/// period.** When the producer dies on the polite signal — the common case —
/// the run finishes and cancels this task, which makes the sleep below throw at
/// once. Swallowing that would fall straight through to the second signal with
/// no wait at all: pointless, because the process is already gone, and unsafe,
/// because of the next paragraph.
///
/// **A pid is not an identity.** Between enumerating a process and signalling
/// it, that process can exit and the system can hand its number to something
/// else. Signalling on the strength of a remembered number is how a tool ends
/// up killing a stranger's process. Each target therefore carries the moment it
/// started, and is signalled only while that still matches.
private struct Stopper: Sendable {
    let pid: pid_t
    let grace: TimeInterval

    func terminate() async {
        // One listing serves both finding the tree and checking the identities
        // in it. Enumerating every process on the system is not free, and it
        // was being done four times per termination.
        let before = ProcessTree.snapshot()
        let targets = before.identities(for: [pid] + before.descendants(of: pid))
        signal(SIGTERM, to: targets, confirmedBy: before)

        do {
            try await Task.sleep(nanoseconds: Seconds.nanoseconds(grace))
        } catch {
            // Cancelled: the producer ended while we waited, which is what the
            // polite signal was for. Nothing left to kill.
            return
        }

        // A fresh listing, because time has passed and that is the whole point
        // of checking identities before the unconditional signal.
        signal(SIGKILL, to: targets, confirmedBy: ProcessTree.snapshot())
    }

    private func signal(
        _ number: Int32,
        to targets: [ProcessTree.Identity],
        confirmedBy snapshot: ProcessTree.Snapshot
    ) {
        guard !targets.isEmpty else { return }
        let stillThere = Set(snapshot.identities(for: targets.map(\.pid)))
        for target in targets where target.pid > 1 {
            guard stillThere.contains(target) else { continue }
            kill(target.pid, number)
        }
    }
}

/// Finds processes, and tells them apart, by asking `ps`.
enum ProcessTree {
    /// A process, identified by more than its number.
    ///
    /// The start time is what makes this an identity rather than a handle: a
    /// pid is reused as soon as the system feels like it.
    struct Identity: Hashable, Sendable {
        let pid: pid_t
        let startedAt: String
    }

    /// One reading of the process table, so that finding a tree and checking
    /// the identities in it do not each pay for their own.
    struct Snapshot: Sendable {
        let rows: [(identity: Identity, ppid: pid_t)]

        /// Every process descended from `pid`, excluding `pid` itself.
        func descendants(of pid: pid_t) -> [pid_t] {
            var childrenByParent: [pid_t: [pid_t]] = [:]
            for row in rows {
                childrenByParent[row.ppid, default: []].append(row.identity.pid)
            }

            var found: [pid_t] = []
            var frontier = [pid]
            var seen: Set<pid_t> = [pid]
            while let current = frontier.popLast() {
                for child in childrenByParent[current] ?? [] where seen.insert(child).inserted {
                    found.append(child)
                    frontier.append(child)
                }
            }
            return found
        }

        /// The identities of the given processes, as of this reading. Anything
        /// that had already exited is simply absent.
        func identities(for pids: [pid_t]) -> [Identity] {
            let wanted = Set(pids)
            return rows.filter { wanted.contains($0.identity.pid) }.map(\.identity)
        }
    }

    /// Reads the process table. An empty snapshot means `ps` could not be run —
    /// the caller still signals the direct child, so a failure here degrades to
    /// the old behaviour rather than to no behaviour.
    static func snapshot() -> Snapshot { Snapshot(rows: listing()) }

    private static func listing() -> [(identity: Identity, ppid: pid_t)] {
        guard let text = run(["/bin/ps", "-axo", "pid=,ppid=,lstart="]) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            // `lstart` is a date containing spaces, so it is whatever remains
            // after the two numeric columns rather than a field of its own.
            let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard fields.count == 3,
                  let pid = pid_t(fields[0]), let ppid = pid_t(fields[1])
            else { return nil }
            let started = fields[2].trimmingCharacters(in: .whitespaces)
            guard !started.isEmpty else { return nil }
            return (Identity(pid: pid, startedAt: started), ppid)
        }
    }

    private static func run(_ argv: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: argv[0])
        process.arguments = Array(argv.dropFirst())
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = (try? pipe.fileHandleForReading.readToEnd()) ?? nil
        process.waitUntilExit()
        return data.map { String(decoding: $0, as: UTF8.self) }
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

/// Why the host killed a process, if it did. `Process` reports a killed child as
/// "uncaught signal", which on its own would be indistinguishable from a plugin
/// that crashed — and telling an author "your plugin crashed" when in fact it
/// ran too long would send them looking in the wrong place.
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

    func resolve(status: Int32, reason: Process.TerminationReason) -> Termination {
        lock.lock(); defer { lock.unlock() }
        if let seconds = timedOutAfter { return .timedOut(after: seconds) }
        if let bytes = overflowBytes { return .outputLimitExceeded(bytes: bytes) }
        return reason == .uncaughtSignal ? .signalled(signal: status) : .exited(code: status)
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
