import Foundation

/// Decides when a cursor that has wandered off means "close the peek".
///
/// A peek is the only state the cursor can dismiss, so this is the whole of
/// that rule. It exists as a value type away from the window because the rule
/// has an edge nobody can see by reading it: leaving is not an instant. A flick
/// past the corner of the panel on the way to somewhere else must not close it,
/// which means the first sample outside the region starts a clock rather than
/// closing anything — and that in turn means something has to wake the panel up
/// if no further sample arrives, because a cursor that stops dead outside the
/// panel produces no more events at all.
public struct PeekExitTracker: Equatable, Sendable {
    /// What the caller should do about this sample.
    public enum Decision: Equatable, Sendable {
        /// The cursor is inside, or there is no peek to close.
        case stay

        /// The cursor has just left. The grace period starts now, and the
        /// caller has to arrange for the question to be asked again even if the
        /// cursor never moves again.
        case leftJustNow

        /// Outside, but not for long enough yet.
        case waiting

        /// Outside for longer than the grace period.
        case close
    }

    /// When the cursor was first seen outside the region, if it is outside.
    private var leftAt: TimeInterval?

    public init() {}

    /// True while a departure is being timed, so the caller knows whether its
    /// safety timer is still needed.
    public var isTiming: Bool { leftAt != nil }

    public mutating func reset() {
        leftAt = nil
    }

    /// Feeds in one observation.
    ///
    /// - Parameters:
    ///   - isPeeking: whether the panel is in the one state a cursor can close.
    ///   - isInsideRegion: whether the cursor is inside the keep-alive region.
    ///   - now: a monotonic clock reading, in seconds.
    ///   - grace: how long the cursor has to stay outside before it counts.
    public mutating func update(
        isPeeking: Bool,
        isInsideRegion: Bool,
        now: TimeInterval,
        grace: TimeInterval
    ) -> Decision {
        guard isPeeking, !isInsideRegion else {
            // Coming back inside cancels a departure outright rather than
            // pausing it: a cursor that leaves, returns and leaves again has
            // made two visits, and charging the second one for the first would
            // close the panel under a cursor that is being used.
            leftAt = nil
            return .stay
        }

        guard let since = leftAt else {
            leftAt = now
            return .leftJustNow
        }
        return now - since >= grace ? .close : .waiting
    }
}
