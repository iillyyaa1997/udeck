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
}

/// What one run of a child process came to. Made by `ProcessRunner`, which
/// runs a plugin on a Mac; read by `PollExecution(result:now:)`, which is how
/// uDeck — and `udeck-plugin run` — say what the run means.
public struct ProcessRunResult: Sendable {
    public let standardOutput: Data
    public let standardError: Data
    public let termination: Termination
    public let duration: TimeInterval

    public init(standardOutput: Data, standardError: Data, termination: Termination, duration: TimeInterval) {
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.termination = termination
        self.duration = duration
    }
}
