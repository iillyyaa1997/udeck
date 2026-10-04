import Foundation

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

    /// The plugin's last run, whatever it came to — a card as much as a
    /// failure — with the tail of its standard error: what the author reads
    /// when a card is wrong without failing. In memory only, like the card.
    public var lastRun: PluginRun?

    public init(
        pluginID: PluginIdentifier,
        card: Card? = nil,
        cardProducedAt: Date? = nil,
        failure: PluginFailure? = nil,
        consecutiveFailures: Int = 0,
        lastRun: PluginRun? = nil
    ) {
        self.pluginID = pluginID
        self.card = card
        self.cardProducedAt = cardProducedAt
        self.failure = failure
        self.consecutiveFailures = consecutiveFailures
        self.lastRun = lastRun
    }

    /// The reason the plugin's next run is given, from the one its caller
    /// had: `launch` until it has drawn a card since uDeck started
    /// (`RefreshReason.of`).
    public func reason(for requested: RefreshReason) -> RefreshReason {
        RefreshReason.of(requested, hasSpoken: cardProducedAt != nil)
    }

    /// What one attempt came to: its card or its failure, and the run it took
    /// when one happened.
    public mutating func record(_ attempt: PollAttempt, at date: Date) {
        if let run = attempt.run { lastRun = run }
        switch attempt.execution {
        case .card(let card):
            record(card: card, at: date)
        case .lateCard(let card, let failure):
            record(card: card, at: date)
            record(failure: failure)
        case .failure(let failure):
            record(failure: failure)
        }
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
