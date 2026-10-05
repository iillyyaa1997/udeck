import Darwin
import Foundation

/// A linked folder's run log: one entry per run, while the run log is
/// switched on (`AppSettings.linkedFolderRunLog`) — when it ran and why, how it
/// ended, how long it took, what it came to, and the tail of its standard
/// error. In `<uDeck folder>/logs/<id>.log`.
///
/// For linked folders only, because they are the plugins somebody is writing:
/// their author wants the run that went wrong an hour ago, and the panel keeps
/// only the last one (`PluginSnapshot.lastRun`). Every other plugin keeps that,
/// in memory, and nothing on disk.
///
/// **Never inside the folder the link leads to.** That folder is the author's
/// working copy, and uDeck writes nothing into it — not a log, not anything:
/// a log there would be a file in their repository after every run. The log
/// lives in uDeck's own folder, and an entry that would land inside the
/// plugin's folder — a uDeck folder kept in a working copy — is not written.
public struct RunLog: Sendable {
    /// One file is at most this, and is then turned over: `<id>.log` becomes
    /// `<id>.log.1`, replacing the one before, and a new `<id>.log` starts. So
    /// a plugin's log is at most two of these, 2 MiB — some thousands of runs
    /// of a producer that says little on standard error, and at least sixteen
    /// of one that fills the whole tail every time (64 KiB). A plugin polled
    /// every five seconds writes a day of quiet runs in well under that.
    public static let maximumBytes = 1 << 20

    public let paths: UDeckPaths

    public init(paths: UDeckPaths) {
        self.paths = paths
    }

    /// Whether a run of `plugin` goes into its run log: a linked folder's,
    /// while the run log is switched on. Every other plugin keeps its last
    /// run in memory, and nothing on disk.
    public static func takes(_ plugin: DiscoveredPlugin, settings: AppSettings) -> Bool {
        settings.writesLinkedFolderRunLog && plugin.isLinked
    }

    /// Why an entry was not written.
    public enum Refusal: Error, Equatable, CustomStringConvertible {
        /// The log would be inside the folder the link leads to.
        case insideThePlugin(String)
        /// What is at the log's place is not a file uDeck made: a link, a
        /// folder. Not written through.
        case notAFile(String)
        /// The disk said no, in the system's words.
        case cannotWrite(String, because: String)

        public var description: String {
            switch self {
            case .insideThePlugin(let path):
                "\(path) is inside the plugin's own folder, and uDeck writes nothing there"
            case .notAFile(let path):
                "\(path) is not a log file uDeck made, and is left alone"
            case .cannotWrite(let path, let reason):
                "could not write \(path): \(reason)"
            }
        }

        /// What `errno` says, in the system's words.
        static func because(_ code: Int32) -> String {
            String(cString: strerror(code))
        }

        /// What Foundation's error says, as the system would: a `FileManager`
        /// error is Cocoa's — its code is no `errno` — and carries the `errno`
        /// it came from as its underlying error. Its own description when it
        /// carries none.
        static func because(_ error: any Error) -> String {
            let error = error as NSError
            if error.domain == NSPOSIXErrorDomain { return because(Int32(error.code)) }
            if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSPOSIXErrorDomain {
                return because(Int32(underlying.code))
            }
            return error.localizedDescription
        }
    }

    /// One run as its log says it: a line for the run, and a line for each
    /// line of standard error.
    ///
    /// ```
    /// 2026-10-04T21:04:05+02:00 launch, 0.21 s: exit status 3; a failure: the producer exited with status 3
    ///   | Traceback (most recent call last):
    ///   | …
    ///   (and 1834 bytes of standard error before these, not kept)
    /// ```
    public static func entry(_ run: PluginRun, timeZone: TimeZone = .current) -> String {
        let time = ISO8601DateFormatter()
        time.timeZone = timeZone
        time.formatOptions = [.withInternetDateTime]
        let outcome: String
        switch run.result {
        case .card: outcome = "a card"
        case .lateCard(let reason): outcome = "a card, and a failure: \(reason)"
        case .failure(let reason): outcome = "a failure: \(reason)"
        }
        var lines = ["\(time.string(from: run.startedAt)) \(run.reason.rawValue), \(Seconds.fixed(run.duration, places: 2)) s: "
                     + "\(run.termination.summary); \(outcome)"]
        var said = run.standardError.split(separator: "\n", omittingEmptySubsequences: false)
        if said.last == "" { said.removeLast() }
        lines += said.map { "  | \($0)" }
        if run.standardErrorDropped > 0 {
            lines.append("  (and \(run.standardErrorDropped) bytes of standard error before these, not kept)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Appends one run of `id` — whose link leads to `linkTarget` — to its log,
    /// turning the file over first when the entry would take it past
    /// `maximumBytes`.
    public func append(_ run: PluginRun, for id: PluginIdentifier, linkTarget: URL) throws {
        let folder = paths.logs
        // Resolved, both: a uDeck folder reached through a link of its own is
        // where the bytes go, and that is what has to be outside the plugin.
        let logs = FilePaths.resolved(folder.path)
        let target = FilePaths.resolved(linkTarget.path)
        if FilePaths.contains(target, logs) {
            throw Refusal.insideThePlugin(folder.path)
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw Refusal.cannotWrite(folder.path, because: Refusal.because(error))
        }
        guard Self.kind(folder.path) == S_IFDIR else { throw Refusal.notAFile(folder.path) }

        let file = paths.log(forPlugin: id)
        let entry = Array(Self.entry(run).utf8)
        let kind = Self.kind(file.path)
        if let kind, kind != S_IFREG { throw Refusal.notAFile(file.path) }
        if kind == S_IFREG, let size = Self.size(file.path), size > 0, size + entry.count > Self.maximumBytes {
            let previous = paths.previousLog(forPlugin: id)
            if let older = Self.kind(previous.path), older != S_IFREG { throw Refusal.notAFile(previous.path) }
            guard rename(file.path, previous.path) == 0 else {
                throw Refusal.cannotWrite(previous.path, because: Refusal.because(errno))
            }
        }

        // Not through a link put at the log's place: O_NOFOLLOW.
        let descriptor = open(file.path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { throw Refusal.cannotWrite(file.path, because: Refusal.because(errno)) }
        defer { close(descriptor) }
        var written = 0
        while written < entry.count {
            let count = entry[written...].withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
            if count < 0 {
                if errno == EINTR { continue }
                throw Refusal.cannotWrite(file.path, because: Refusal.because(errno))
            }
            written += count
        }
    }

    /// Takes `id`'s log away, and the one before it: what **Remove** does
    /// with it, as with the plugin's cache. A link taken away by hand leaves
    /// its log, and its runs go on into it when the link is back.
    public func remove(for id: PluginIdentifier) {
        for file in [paths.log(forPlugin: id), paths.previousLog(forPlugin: id)] where Self.kind(file.path) == S_IFREG {
            unlink(file.path)
        }
    }

    /// Whether any plugin's run log is on disk — what **Show the logs** in
    /// Settings needs to be worth pressing: a file `<id>.log` or `<id>.log.1`
    /// in the logs folder, a file and not a link.
    public static func anyWritten(in paths: UDeckPaths) -> Bool {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: paths.logs.path)) ?? []
        return names.contains { name in
            let bytes = Array(name.utf8)
            let isLog = bytes.reversed().starts(with: Array(".log".utf8).reversed())
                || bytes.reversed().starts(with: Array(".log.1".utf8).reversed())
            return isLog && kind(paths.logs.appendingPathComponent(name).path) == S_IFREG
        }
    }

    /// What is at `path` itself — not what a link there leads to — as the
    /// `S_IFMT` bits of its mode, or nil when nothing is.
    static func kind(_ path: String) -> mode_t? {
        var status = stat()
        guard lstat(path, &status) == 0 else { return nil }
        return status.st_mode & S_IFMT
    }

    static func size(_ path: String) -> Int? {
        var status = stat()
        guard lstat(path, &status) == 0 else { return nil }
        return Int(status.st_size)
    }
}

/// Writes run logs on a queue of its own, one entry after another and never
/// on the main thread: a run ends on the main actor, and a disk that answers
/// slowly must not hold the panel.
public final class RunLogWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "place.unicorns.udeck.run-log", qos: .utility)

    public init() {}

    /// Appends `run` to `log` for `id`, later, in the order written; `done`
    /// is told what came of it, on the writer's queue.
    public func write(_ run: PluginRun, for id: PluginIdentifier, linkTarget: URL, to log: RunLog,
                      done: (@Sendable (_ error: (any Error)?, _ onMainThread: Bool) -> Void)? = nil) {
        queue.async {
            do {
                try log.append(run, for: id, linkTarget: linkTarget)
                done?(nil, Thread.isMainThread)
            } catch {
                done?(error, Thread.isMainThread)
            }
        }
    }

    /// Returns once everything written before it is on disk: so that taking a
    /// log away comes after the last entry, rather than before an entry that
    /// would make it again.
    public func drain() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { continuation.resume() }
        }
    }
}
