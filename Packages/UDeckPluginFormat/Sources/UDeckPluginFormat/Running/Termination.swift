#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

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

    /// How it ended, in a line: what `udeck-plugin run` says after `ended:`,
    /// and what a run log says of each run.
    public var summary: String {
        switch self {
        case .exited(let code): "exit status \(code)"
        case .signalled(let signal): "killed by signal \(signal)"
        case .timedOut(let seconds):
            "stopped by uDeck after \(Seconds.fixed(seconds, places: seconds == seconds.rounded() ? 0 : 1)) s, its timeout"
        case .outputLimitExceeded(let bytes): "stopped by uDeck after \(bytes) bytes of output, past its limit"
        case .launchFailed(let detail): "never started: \(detail)"
        }
    }
}

/// What one run of a child process came to. Made by `ProcessRunner`, which
/// runs a plugin on a Mac; read by `PollExecution(result:now:)`, which is how
/// uDeck — and `udeck-plugin run` — say what the run means.
public struct ProcessRunResult: Sendable {
    public let standardOutput: Data
    public let standardError: Data
    public let termination: Termination
    public let duration: TimeInterval

    /// Bytes of each the process wrote that the host counted and did not
    /// keep: standard output's past the output limit — its end — and standard
    /// error's before the tail that is kept — its beginning
    /// (`ProcessRunner.standardErrorTail`).
    public let standardOutputDropped: Int
    public let standardErrorDropped: Int

    public init(standardOutput: Data, standardError: Data, termination: Termination, duration: TimeInterval,
                standardOutputDropped: Int = 0, standardErrorDropped: Int = 0) {
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.termination = termination
        self.duration = duration
        self.standardOutputDropped = standardOutputDropped
        self.standardErrorDropped = standardErrorDropped
    }
}
