import CoreGraphics
import Foundation

/// Learns how this machine's mouse deltas relate to on-screen points.
///
/// The gesture needs to know how far the device moved *after* the cursor has
/// already stopped at the top edge, which is the one moment when the cursor
/// position says nothing. Only `NSEvent`'s delta fields still carry that
/// information — and they carry it in a form that cannot safely be assumed:
///
/// * **Sign.** For mouse-moved events AppKit reports `deltaY` in a flipped
///   sense: moving the mouse away from the user, which raises the cursor in
///   AppKit's bottom-left coordinates, yields a *negative* `deltaY`. Hard-coding
///   that would make the gesture fire on downward movement if it were ever
///   wrong — and it is the kind of detail that has changed before.
/// * **Scale.** Pointer acceleration means a delta of 10 does not move the
///   cursor 10 points, and the ratio depends on the tracking-speed setting.
///   A threshold expressed in points would otherwise mean something different
///   on every machine.
///
/// So both are measured instead, continuously, from the moments when the cursor
/// is free to move and the two sources can be compared. Until enough has been
/// seen, the documented convention is used as the starting point.
public struct PointerDeltaCalibration: Sendable, Equatable {
    /// +1 when a positive `deltaY` means upward, -1 when it means downward.
    public private(set) var polarity: CGFloat = -1

    /// Points of cursor travel per unit of reported delta.
    public private(set) var scale: CGFloat = 1

    /// How many consecutive observations have agreed with the current polarity.
    ///
    /// Consecutive, not cumulative. Counting every sample and then letting each
    /// one overwrite the polarity outright meant a single bad sample inverted
    /// the sign for every event until another flipped it back — and the sign is
    /// what tells an upward push from a downward one, so the gesture would
    /// arm on a downward jiggle and refuse a real push.
    public private(set) var agreementRun = 0

    /// Consecutive agreeing observations needed before the measured polarity
    /// replaces the one in use.
    public let requiredAgreement: Int

    /// Weight of each new observation in the running average of the scale.
    public let smoothing: CGFloat

    /// Movements smaller than this are ignored: at one or two points the
    /// quantisation noise is larger than the signal.
    public let minimumMovement: CGFloat

    /// Bounds on the scale. Pointer acceleration is a multiplier, not a
    /// teleport; a ratio outside this range is a bad sample rather than a fast
    /// hand, and letting one in would make the push threshold mean a different
    /// number of points from one moment to the next.
    public let scaleRange: ClosedRange<CGFloat>

    public init(
        requiredAgreement: Int = 3,
        smoothing: CGFloat = 0.2,
        minimumMovement: CGFloat = 3,
        scaleRange: ClosedRange<CGFloat> = 0.1 ... 10
    ) {
        self.requiredAgreement = requiredAgreement
        self.smoothing = smoothing
        self.minimumMovement = minimumMovement
        self.scaleRange = scaleRange
    }

    /// Folds in one movement where the cursor was free to move, so the position
    /// change and the reported delta describe the same thing.
    ///
    /// The caller is responsible for only offering samples where the cursor was
    /// not against any screen edge — at an edge the position stops changing
    /// while the delta does not, and the two stop describing the same movement.
    public mutating func observe(positionChange: CGFloat, reportedDelta: CGFloat) {
        guard positionChange.isFinite, reportedDelta.isFinite,
              abs(positionChange) >= minimumMovement, abs(reportedDelta) >= minimumMovement
        else { return }

        let measuredPolarity: CGFloat = (positionChange > 0) == (reportedDelta > 0) ? 1 : -1
        let measuredScale = abs(positionChange) / abs(reportedDelta)
        guard scaleRange.contains(measuredScale) else {
            // Out of range means the two numbers are not describing the same
            // movement — a coalesced event, or a clamp the caller missed. It
            // says nothing about polarity either, so nothing is learned.
            return
        }

        if measuredPolarity == polarity {
            agreementRun = min(agreementRun + 1, requiredAgreement)
        } else {
            agreementRun -= 1
            if agreementRun <= -requiredAgreement {
                // Consistently disagreeing: the convention really is the other
                // way round.
                polarity = measuredPolarity
                agreementRun = requiredAgreement
            }
        }

        scale = min(max(scale * (1 - smoothing) + measuredScale * smoothing,
                        scaleRange.lowerBound), scaleRange.upperBound)
    }

    /// The upward movement, in points, that a reported delta represents.
    public func upwardPoints(fromReportedDelta delta: CGFloat) -> CGFloat {
        delta * polarity * scale
    }
}
