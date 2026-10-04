import Foundation

/// One run of a plugin's producer, as uDeck keeps it: the last one of every
/// plugin, beside its card (`PluginSnapshot.lastRun`), and every one of a
/// linked folder's in its run log while that is switched on (`RunLog`).
///
/// Only a run that happened: a plugin that was not permitted, or would not
/// load, started nothing, and its failure says so on the card.
public struct PluginRun: Equatable, Sendable {
    /// What the run came to, as the card shows it.
    public enum Result: Equatable, Sendable {
        /// A card, drawn.
        case card
        /// A card, drawn — and a failure counted: it ran past its timeout
        /// after printing it.
        case lateCard(PluginFailure.Reason)
        /// No card: the failure the card shows.
        case failure(PluginFailure.Reason)
    }

    public var startedAt: Date
    public var reason: RefreshReason
    public var termination: Termination
    public var duration: TimeInterval
    public var result: Result
    /// The tail of what the producer wrote to standard error, as text: what
    /// the run kept of it (`ProcessRunner.standardErrorTail`).
    public var standardError: String
    /// The bytes of standard error before that tail, which were not kept.
    public var standardErrorDropped: Int

    public init(startedAt: Date, reason: RefreshReason, termination: Termination, duration: TimeInterval,
                result: Result, standardError: String, standardErrorDropped: Int = 0) {
        self.startedAt = startedAt
        self.reason = reason
        self.termination = termination
        self.duration = duration
        self.result = result
        self.standardError = standardError
        self.standardErrorDropped = standardErrorDropped
    }

    /// The run a process result and what uDeck made of it come to.
    public init(result: ProcessRunResult, execution: PollExecution, startedAt: Date, reason: RefreshReason) {
        let came: Result
        switch execution {
        case .card: came = .card
        case .lateCard(_, let failure): came = .lateCard(failure.reason)
        case .failure(let failure): came = .failure(failure.reason)
        }
        self.init(startedAt: startedAt, reason: reason, termination: result.termination, duration: result.duration,
                  result: came, standardError: String(decoding: result.standardError, as: UTF8.self),
                  standardErrorDropped: result.standardErrorDropped)
    }
}

/// One attempt to get a card out of a plugin, and the run it took, when one
/// happened.
public struct PollAttempt: Sendable {
    public var execution: PollExecution
    /// Nil when nothing ran: the plugin would not load, was not permitted, or
    /// is of a kind uDeck does not run.
    public var run: PluginRun?

    public init(execution: PollExecution, run: PluginRun?) {
        self.execution = execution
        self.run = run
    }
}

extension RefreshReason {
    /// The reason a plugin's run is given, from the one its caller had —
    /// `interval` for a tick, `manual` for the panel opening or ⟳ — and
    /// whether the plugin has drawn a card since uDeck started.
    ///
    /// `launch` until it has: the first run of every plugin after uDeck
    /// starts, whatever started it, and every run after that until one of
    /// them prints a card. So a plugin that appears while uDeck runs — copied
    /// in, linked, installed — is told `launch` on its first run too, which
    /// for it is one; and a first run that fails, or times out before printing
    /// a card, does not use the word up: a producer that does its slow work at
    /// launch is asked for it again until it has done it. A card printed
    /// before the run went past its timeout is a card drawn (`lateCard`), and
    /// does use it.
    public static func of(_ requested: RefreshReason, hasSpoken: Bool) -> RefreshReason {
        hasSpoken ? requested : .launch
    }
}

/// The end of a failed run's standard error, as Settings shows it under the
/// failure: its last lines, which is where the error is — a traceback names
/// the exception last — and no more of them than fits there. What uDeck keeps
/// is the last 64 KiB; what is shown is the end of that.
public enum ShownStandardError {
    /// Lines shown at most.
    public static let lines = 8
    /// Characters shown at most, of those lines: a producer that writes one
    /// long line is shown the end of it.
    public static let characters = 800

    /// `text`'s last `lines` lines — any line break ends one — and of those its
    /// last `characters` characters, after a line of its own saying `…` when
    /// anything before them was left out.
    public static func end(of text: String, lines: Int = lines, characters: Int = characters) -> String {
        var kept = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        var cut = false
        if kept.count > lines {
            kept = Array(kept.suffix(lines))
            cut = true
        }
        var shown = kept.joined(separator: "\n")
        if shown.count > characters {
            shown = String(shown.suffix(characters))
            cut = true
        }
        return cut ? "…\n" + shown : shown
    }
}
