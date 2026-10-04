#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// Why a plugin has nothing to show.
public struct PluginFailure: Equatable, Sendable {
    public enum Reason: Equatable, Sendable, CustomStringConvertible {
        case timedOut(after: TimeInterval)
        case exited(code: Int32)
        case signalled(signal: Int32)
        case launchFailed(String)
        case outputLimitExceeded(bytes: Int)
        case emptyOutput
        case unparsableOutput(String)
        case notPermitted(LaunchDecision)
        case notLoadable([DiscoveryProblem])

        public var description: String {
            switch self {
            case .timedOut(let seconds):
                "the producer did not answer within \(format(seconds))s and was stopped"
            case .exited(let code):
                "the producer exited with status \(code)"
            case .signalled(let signal):
                "the producer was killed by signal \(signal)"
            case .launchFailed(let detail):
                "the producer could not be started: \(detail)"
            case .outputLimitExceeded(let bytes):
                "the producer printed more than the \(bytes)-byte limit and was stopped"
            case .emptyOutput:
                "the producer printed nothing"
            case .unparsableOutput(let detail):
                "the producer's output is not a valid card: \(detail)"
            case .notPermitted(let decision):
                switch decision {
                case .allowed: "permitted"
                case .disabled: "switched off"
                case .awaitingDecision(let pending):
                    "waiting for you to decide about: \(pending.map(\.summary).joined(separator: ", "))"
                case .refused(let denied):
                    "needs permission you declined: \(denied.map(\.summary).joined(separator: ", "))"
                }
            case .notLoadable(let problems):
                problems.map(\.description).joined(separator: "; ")
            }
        }

        private func format(_ seconds: TimeInterval) -> String {
            seconds == seconds.rounded() ? String(Int(seconds)) : Seconds.oneDecimal(seconds)
        }
    }

    public var reason: Reason
    /// What the producer wrote to stderr — the tail of it the run kept
    /// (`ProcessRunner.standardErrorTail`) — trimmed. Shown in Settings beside
    /// the failure rather than on the card: it is for the author, not for the
    /// glance. uDeck keeps the stderr of a run that printed a card too, with
    /// the plugin's last run (`PluginRun`, in uDeck).
    public var diagnostics: String
    public var occurredAt: Date

    public init(reason: Reason, diagnostics: String = "", occurredAt: Date = Date()) {
        self.reason = reason
        self.diagnostics = diagnostics
        self.occurredAt = occurredAt
    }
}

/// One attempt to get a card out of a plugin.
public enum PollExecution: Sendable, Equatable {
    case card(Card)

    /// The producer printed a complete card and then overran its deadline.
    ///
    /// Both halves matter. Throwing the card away because the run was killed
    /// wastes data the operator can use — and a producer that prints its card
    /// and *then* does something slow is a common shape, so this was measured
    /// happening in most runs at the deadline. Hiding the overrun would be the
    /// opposite mistake: a producer that is always killed would look healthy.
    case lateCard(Card, PluginFailure)

    case failure(PluginFailure)
}

extension PollExecution {
    /// What a run that happened comes to: the one place uDeck — and
    /// `udeck-plugin run`, which says what uDeck would make of a run — reads
    /// how a producer ended and what it printed.
    ///
    /// Every path out of here produces something the operator can read. A
    /// producer that hangs, crashes, prints nothing or prints garbage each
    /// yields a different message — because "this card is not updating" with
    /// no reason attached is the state in which someone stops trusting the
    /// whole panel.
    public init(result: ProcessRunResult, now: Date) {
        let diagnostics = Self.diagnostics(result.standardError)

        switch result.termination {
        case .timedOut(let seconds):
            let failure = PluginFailure(reason: .timedOut(after: seconds), diagnostics: diagnostics, occurredAt: now)
            // It may have finished saying what it had to say before it hung.
            if case .card(let card) = PollExecution(parsing: result.standardOutput, diagnostics: diagnostics, now: now) {
                self = .lateCard(card, failure)
                return
            }
            self = .failure(failure)
            return
        case .outputLimitExceeded(let bytes):
            self = .failure(PluginFailure(reason: .outputLimitExceeded(bytes: bytes), diagnostics: diagnostics, occurredAt: now))
            return
        case .launchFailed(let detail):
            self = .failure(PluginFailure(reason: .launchFailed(detail), diagnostics: diagnostics, occurredAt: now))
            return
        case .signalled(let signal):
            self = .failure(PluginFailure(reason: .signalled(signal: signal), diagnostics: diagnostics, occurredAt: now))
            return
        case .exited(let code) where code != 0:
            self = .failure(PluginFailure(reason: .exited(code: code), diagnostics: diagnostics, occurredAt: now))
            return
        case .exited:
            break
        }

        self.init(parsing: result.standardOutput, diagnostics: diagnostics, now: now)
    }

    /// A card out of what a producer printed, brought within what uDeck draws
    /// — or the reason there is none.
    public init(parsing stdout: Data, diagnostics: String, now: Date) {
        switch Self.read(stdout) {
        case .empty:
            self = .failure(PluginFailure(reason: .emptyOutput, diagnostics: diagnostics, occurredAt: now))
        case .card(let card):
            // Bounded before anything tries to draw it: the byte cap on a
            // producer's output is the wrong unit for what actually hurts.
            self = .card(card.withinDrawingLimits())
        case .unparsable(let detail):
            self = .failure(PluginFailure(reason: .unparsableOutput(detail), diagnostics: diagnostics, occurredAt: now))
        }
    }

    /// What a producer printed, read as uDeck reads it.
    public enum Output: Equatable, Sendable {
        /// Nothing, or nothing but white space.
        case empty
        /// A card — as printed, before it is brought within what uDeck draws.
        case card(Card)
        /// Not a card, and why, in the words a failure says it.
        case unparsable(String)
    }

    /// Reads standard output: trimmed, then decoded as a card.
    public static func read(_ stdout: Data) -> Output {
        let trimmed = Blank.trimmed(String(decoding: stdout, as: UTF8.self))
        guard !trimmed.isEmpty else { return .empty }
        do {
            return .card(try JSONDecoder().decode(Card.self, from: Data(trimmed.utf8)))
        } catch {
            return .unparsable(PluginDiscovery.describe(error, in: Data(trimmed.utf8), document: "the output"))
        }
    }

    /// What a producer wrote to stderr, as a failure keeps it: the text,
    /// trimmed.
    public static func diagnostics(_ standardError: Data) -> String {
        Blank.trimmed(String(decoding: standardError, as: UTF8.self))
    }
}
