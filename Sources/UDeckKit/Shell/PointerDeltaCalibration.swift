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
public struct PointerDeltaCalibration: Sendable {
    /// +1 when a positive `deltaY` means upward, -1 when it means downward.
    public private(set) var polarity: CGFloat = -1

    /// Points of cursor travel per unit of reported delta.
    public private(set) var scale: CGFloat = 1

    /// How many consistent observations have been folded in. The starting
    /// values are used until this passes `minimumObservations`.
    public private(set) var observations = 0

    /// Observations needed before the measured polarity replaces the assumed one.
    public let minimumObservations: Int

    /// Weight of each new observation in the running average of the scale.
    public let smoothing: CGFloat

    /// Movements smaller than this are ignored: at one or two points the
    /// quantisation noise is larger than the signal.
    public let minimumMovement: CGFloat

    public init(minimumObservations: Int = 3, smoothing: CGFloat = 0.2, minimumMovement: CGFloat = 3) {
        self.minimumObservations = minimumObservations
        self.smoothing = smoothing
        self.minimumMovement = minimumMovement
    }

    /// Folds in one movement where the cursor was free to move, so the position
    /// change and the reported delta describe the same thing.
    public mutating func observe(positionChange: CGFloat, reportedDelta: CGFloat) {
        guard abs(positionChange) >= minimumMovement, abs(reportedDelta) >= minimumMovement else { return }

        let measuredPolarity: CGFloat = (positionChange > 0) == (reportedDelta > 0) ? 1 : -1
        let measuredScale = abs(positionChange) / abs(reportedDelta)

        observations += 1
        if observations >= minimumObservations {
            polarity = measuredPolarity
        }
        scale = scale * (1 - smoothing) + measuredScale * smoothing
    }

    /// The upward movement, in points, that a reported delta represents.
    public func upwardPoints(fromReportedDelta delta: CGFloat) -> CGFloat {
        delta * polarity * scale
    }
}
