import Foundation

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
            seconds == seconds.rounded() ? String(Int(seconds)) : String(format: "%.1f", seconds)
        }
    }

    public var reason: Reason
    /// Whatever the producer wrote to stderr, trimmed. Shown in the plugin's log
    /// rather than on the card: it is for the author, not for the glance.
    public var diagnostics: String
    public var occurredAt: Date

    public init(reason: Reason, diagnostics: String = "", occurredAt: Date = Date()) {
        self.reason = reason
        self.diagnostics = diagnostics
        self.occurredAt = occurredAt
    }
}

/// How much a card can still be believed.
public enum CardFreshness: Equatable, Sendable {
    /// Within its ttl.
    case fresh

    /// Past its ttl but not by much: the values are still shown, and visibly
    /// marked as old, with the time they were produced.
    case stale(age: TimeInterval)

    /// Long past its ttl. The values are hidden entirely — a stale "everything
    /// is fine" that still looks fine is worse than no card at all.
    case silent(age: TimeInterval)

    /// The plugin has never produced a card in this session.
    case neverSpoke
}

/// What the renderer should draw for one plugin, right now.
public struct CardPresentation: Equatable, Sendable {
    public let state: CardState
    /// Nil when there is nothing trustworthy to show.
    public let card: Card?
    public let freshness: CardFreshness
    /// One plain line explaining the state, when the state needs explaining.
    public let note: String?
    /// When the plugin last produced a card, if it ever has.
    public let lastSpokeAt: Date?

    public init(state: CardState, card: Card?, freshness: CardFreshness, note: String?, lastSpokeAt: Date?) {
        self.state = state
        self.card = card
        self.freshness = freshness
        self.note = note
        self.lastSpokeAt = lastSpokeAt
    }
}

/// Everything the host knows about one plugin's output.
public struct PluginSnapshot: Equatable, Sendable {
    public let pluginID: PluginIdentifier

    /// The last card the plugin produced, however long ago.
    public var card: Card?
    public var cardProducedAt: Date?

    /// The last failure, if the most recent attempt failed. Cleared by a
    /// successful run.
    public var failure: PluginFailure?

    /// Consecutive failed attempts. Used only for reporting; the schedule does
    /// not back off, because a producer that is failing every five seconds is
    /// cheap and the operator wants to see it recover the moment it does.
    public var consecutiveFailures: Int

    public init(
        pluginID: PluginIdentifier,
        card: Card? = nil,
        cardProducedAt: Date? = nil,
        failure: PluginFailure? = nil,
        consecutiveFailures: Int = 0
    ) {
        self.pluginID = pluginID
        self.card = card
        self.cardProducedAt = cardProducedAt
        self.failure = failure
        self.consecutiveFailures = consecutiveFailures
    }

    public mutating func record(card: Card, at date: Date) {
        self.card = card
        self.cardProducedAt = date
        self.failure = nil
        self.consecutiveFailures = 0
    }

    public mutating func record(failure: PluginFailure) {
        self.failure = failure
        self.consecutiveFailures += 1
    }

    /// Decides what to draw.
    ///
    /// The rule this encodes, which is the whole reason `ttl` exists: **"the
    /// source is quiet" must look like neither "everything is fine" nor
    /// "everything is broken".** Sources on this machine go legitimately quiet —
    /// the limit-monitor daemon exits five minutes after the last session
    /// closes, so its files are meant to be stale every night. A panel that
    /// screamed about that nightly would be ignored within a week, and an
    /// ignored panel is a dead one.
    public func presentation(
        now: Date = Date(),
        defaultTTL: TimeInterval,
        silentMultiplier: Double
    ) -> CardPresentation {
        // A failure with no previous card at all: there is nothing to be stale.
        guard let card, let producedAt = cardProducedAt else {
            return CardPresentation(
                state: .unknown,
                card: nil,
                freshness: .neverSpoke,
                note: failure?.reason.description ?? "no data yet",
                lastSpokeAt: nil
            )
        }

        let ttl = card.ttl ?? defaultTTL
        let age = now.timeIntervalSince(producedAt)
        let silentAfter = ttl * max(1, silentMultiplier)

        if age > silentAfter {
            return CardPresentation(
                state: .unknown,
                card: nil,
                freshness: .silent(age: age),
                note: failure?.reason.description ?? "silent since \(Self.time(producedAt))",
                lastSpokeAt: producedAt
            )
        }

        if age > ttl {
            return CardPresentation(
                state: card.state,
                card: card,
                freshness: .stale(age: age),
                note: failure?.reason.description ?? "last spoke \(Self.time(producedAt))",
                lastSpokeAt: producedAt
            )
        }

        // Fresh, but the most recent attempt failed. The values are still
        // current enough to show; the failure is worth saying out loud so a
        // producer that just broke is visible before its card goes stale.
        return CardPresentation(
            state: card.state,
            card: card,
            freshness: .fresh,
            note: failure?.reason.description,
            lastSpokeAt: producedAt
        )
    }

    private static func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}
