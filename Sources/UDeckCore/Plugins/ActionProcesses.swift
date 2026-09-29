import Darwin
import Foundation

/// The card actions that are running, each in a process group of its own, by
/// plugin — so that quieting a plugin can end them, and whatever they started,
/// before its folder is swapped or taken away.
///
/// An action has no timeout: it is a command the operator pressed, and it may
/// rightly take as long as it takes. What it may not do is run on in a folder
/// that is being replaced under it, reading half of one version and half of
/// the other, or in one that has gone. So an action still running when the
/// wait for it is up is ended (`stop`), and only then is the folder touched.
///
/// An action counts as running until its whole group has ended, not only the
/// command itself: `sh -c 'work &'` is running as long as `work` is. The group
/// leader is left a zombie until then, for the reason `ProcessGroup` gives —
/// while it is unreaped the group id cannot be recycled, so a signal to the
/// group cannot reach a stranger — and it is reaped under the same lock the
/// signals are sent under.
public final class ActionProcesses: @unchecked Sendable {
    private let lock = NSLock()
    /// Group leaders not yet reaped, by plugin.
    private var running: [String: [pid_t]] = [:]

    /// How often a group whose leader has exited is asked whether anything
    /// of it is left.
    private static let membersPollInterval: useconds_t = 100_000

    public init() {}

    /// Starts an action of `plugin`: stdin, stdout and stderr at `/dev/null`,
    /// in a process group of its own. `ended` is called once, on a thread of
    /// its own, when the action and everything in its group have ended.
    public func start(
        plugin: String,
        executable: URL,
        arguments: [String],
        workingDirectory: URL,
        environment: [String: String],
        ended: @escaping @Sendable () -> Void
    ) throws {
        // Under the lock from the spawn on, so that a `stop` cannot run between
        // the process starting and its being listed, and miss it.
        lock.lock()
        let pid: pid_t
        do {
            pid = try ProcessGroup.spawnDiscardingOutput(
                executable: executable, arguments: arguments,
                workingDirectory: workingDirectory, environment: environment)
        } catch {
            lock.unlock()
            throw error
        }
        running[plugin, default: []].append(pid)
        lock.unlock()

        Thread.detachNewThread { [self] in
            _ = ProcessGroup.waitForExit(pid: pid)
            while !ProcessGroup.liveMembers(of: pid).isEmpty {
                usleep(Self.membersPollInterval)
            }
            lock.lock()
            ProcessGroup.reap(pid: pid)
            running[plugin]?.removeAll { $0 == pid }
            if running[plugin]?.isEmpty == true { running[plugin] = nil }
            lock.unlock()
            ended()
        }
    }

    /// Whether any action of `plugin`, or anything it started, is running.
    public func isRunning(_ plugin: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return !(running[plugin] ?? []).isEmpty
    }

    /// Ends every action of `plugin` and everything it started: `SIGTERM` to
    /// each group, `grace` to go, then `SIGKILL`, and a further `grace` for the
    /// kernel to finish them. Answers whether nothing of them is left.
    @discardableResult
    public func stop(_ plugin: String, grace: TimeInterval) async -> Bool {
        guard isRunning(plugin) else { return true }
        signal(plugin, SIGTERM)
        if await waitUntilEnded(plugin, for: grace) { return true }
        signal(plugin, SIGKILL)
        return await waitUntilEnded(plugin, for: grace)
    }

    private func signal(_ plugin: String, _ signal: Int32) {
        lock.lock(); defer { lock.unlock() }
        for group in running[plugin] ?? [] { kill(-group, signal) }
    }

    private func waitUntilEnded(_ plugin: String, for seconds: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while isRunning(plugin), Date() < deadline {
            await Self.pause(0.02)
        }
        return !isRunning(plugin)
    }

    /// A pause a cancellation cannot cut short — see
    /// `ProcessGroup.sleepIgnoringCancellation`: the wait after a signal is
    /// what makes the next one follow it.
    static func pause(_ seconds: TimeInterval) async {
        await withUnsafeContinuation { (continuation: UnsafeContinuation<Void, Never>) in
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { continuation.resume() }
        }
    }
}

extension PluginQuiet {
    /// What quieting a plugin comes to once nothing more of it may start: its
    /// runs in flight are waited for as long as a poll can take — `wait` —
    /// and any still going then are card actions, which have no deadline of
    /// their own, so they are ended (`stopActions`); then the runs are waited
    /// for again, at most `andThen`.
    ///
    /// Answers whether nothing of the plugin is running. False means its folder
    /// must not be touched: uDeck never swaps or removes a folder under a live
    /// process.
    public static func settle(
        wait: TimeInterval,
        andThen: TimeInterval,
        isRunning: @escaping @Sendable () async -> Bool,
        stopActions: @Sendable () async -> Void
    ) async -> Bool {
        if await waitUntilIdle(isRunning, for: wait) { return true }
        await stopActions()
        return await waitUntilIdle(isRunning, for: andThen)
    }

    /// Quieting a plugin, decided whole (Q117), for a caller that has already
    /// stopped anything more of it from starting: what to wait for, what to
    /// end, and what to answer.
    ///
    /// * Its runs in flight — polls, which end within their `timeout`
    ///   (`pollTimeout`, 5 seconds when the manifest gives none) and the half
    ///   second after it, and card actions — are waited for that long, plus a
    ///   second.
    /// * Anything still running then is a card action, which has no deadline of
    ///   its own: `actions` ends it — `SIGTERM` to its process group, `grace`,
    ///   then `SIGKILL` — and the runs are waited for again, twice `grace` and
    ///   a second.
    /// * The answer is whether nothing of the plugin runs, asked of
    ///   `isRunning`, never assumed: false, and its folder must not be touched.
    public static func quiet(
        _ plugin: String,
        pollTimeout: TimeInterval?,
        actions: ActionProcesses,
        grace: TimeInterval = actionEndGrace,
        isRunning: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        await settle(
            wait: (pollTimeout ?? 5) + 1.5,
            andThen: grace * 2 + 1,
            isRunning: isRunning,
            stopActions: { await actions.stop(plugin, grace: grace) }
        )
    }

    /// Between `SIGTERM` and `SIGKILL` for a card action that outlasts the
    /// wait, and again after it.
    public static let actionEndGrace: TimeInterval = 1

    private static func waitUntilIdle(_ isRunning: () async -> Bool, for seconds: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while await isRunning(), Date() < deadline {
            await ActionProcesses.pause(0.05)
        }
        return await !isRunning()
    }
}
