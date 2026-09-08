import CoreGraphics
import Foundation
import Testing
@testable import UDeckCore

/// The calibration decides which direction a mouse delta means, and that sign
/// is what tells an upward push from a downward one. Getting it wrong does not
/// degrade the gesture, it inverts it: the panel arms on a downward jiggle and
/// refuses a real push.
///
/// These tests exist because this type used to live in the AppKit layer, where
/// nothing could reach it — and it was wrong in three ways at once.
@Suite("Pointer calibration")
struct CalibrationTests {
    /// AppKit reports `deltaY` in a flipped sense for mouse-moved events, so
    /// the starting assumption is that a positive delta means downward.
    @Test("it starts with the documented convention")
    func startsWithTheConvention() {
        let calibration = PointerDeltaCalibration()
        #expect(calibration.polarity == -1)
        #expect(calibration.scale == 1)
        #expect(calibration.upwardPoints(fromReportedDelta: -10) == 10)
    }

    @Test("consistent evidence changes the polarity")
    func consistentEvidenceWins() {
        var calibration = PointerDeltaCalibration()
        // A machine where a positive delta really does mean upward.
        for _ in 0 ..< 10 {
            calibration.observe(positionChange: 10, reportedDelta: 10)
        }
        #expect(calibration.polarity == 1)
        #expect(calibration.upwardPoints(fromReportedDelta: 10) > 0)
    }

    /// The bug this is here for: `observations` counted every sample, so past
    /// the third *each* sample overwrote the polarity outright. One bad reading
    /// — a coalesced event, a clamp the caller missed — inverted the sign for
    /// every event that followed.
    @Test("one disagreeing sample does not invert the sign")
    func oneBadSampleDoesNotInvert() {
        var calibration = PointerDeltaCalibration()
        for _ in 0 ..< 10 { calibration.observe(positionChange: 10, reportedDelta: 10) }
        #expect(calibration.polarity == 1)

        calibration.observe(positionChange: 10, reportedDelta: -10)   // one bad reading
        #expect(calibration.polarity == 1, "a single sample must not flip the sign")

        calibration.observe(positionChange: 10, reportedDelta: 10)
        #expect(calibration.polarity == 1)
    }

    @Test("sustained disagreement does flip it, because the machine may differ")
    func sustainedDisagreementFlips() {
        var calibration = PointerDeltaCalibration()
        for _ in 0 ..< 10 { calibration.observe(positionChange: 10, reportedDelta: 10) }
        #expect(calibration.polarity == 1)

        for _ in 0 ..< 10 { calibration.observe(positionChange: 10, reportedDelta: -10) }
        #expect(calibration.polarity == -1)
    }

    @Test("an implausible ratio is not learned from at all")
    func implausibleRatiosAreIgnored() {
        var calibration = PointerDeltaCalibration()
        let before = calibration
        // A coalesced event: the cursor moved much further than the delta says.
        calibration.observe(positionChange: 5000, reportedDelta: 5)
        calibration.observe(positionChange: 5, reportedDelta: 5000)
        #expect(calibration == before, "nothing about these samples is trustworthy")
    }

    @Test("the scale stays inside its bounds however it is fed")
    func scaleIsBounded() {
        var calibration = PointerDeltaCalibration()
        for _ in 0 ..< 200 { calibration.observe(positionChange: 90, reportedDelta: 10) }
        #expect(calibration.scale <= calibration.scaleRange.upperBound)
        #expect(calibration.scale >= calibration.scaleRange.lowerBound)

        for _ in 0 ..< 200 { calibration.observe(positionChange: 10, reportedDelta: 90) }
        #expect(calibration.scale >= calibration.scaleRange.lowerBound)
    }

    @Test("tiny movements teach it nothing, because the noise is bigger than the signal")
    func tinyMovementsIgnored() {
        var calibration = PointerDeltaCalibration()
        let before = calibration
        calibration.observe(positionChange: 1, reportedDelta: -1)
        calibration.observe(positionChange: 2, reportedDelta: 2)
        #expect(calibration == before)
    }

    @Test("nonsense numbers are refused rather than propagated")
    func nonFiniteIgnored() {
        var calibration = PointerDeltaCalibration()
        let before = calibration
        calibration.observe(positionChange: .nan, reportedDelta: 10)
        calibration.observe(positionChange: 10, reportedDelta: .infinity)
        #expect(calibration == before)
        #expect(calibration.upwardPoints(fromReportedDelta: 10).isFinite)
    }

    /// A real stream is mostly good samples with the occasional bad one; the
    /// sign must be stable across it, because an unstable sign is worse than a
    /// wrong one — the gesture would work intermittently.
    @Test("a realistic stream with occasional bad samples keeps a stable sign")
    func realisticStreamIsStable() {
        var calibration = PointerDeltaCalibration()
        var signs: Set<CGFloat> = []
        for index in 0 ..< 300 {
            if index % 17 == 0 {
                calibration.observe(positionChange: 12, reportedDelta: -9)   // bad
            } else {
                calibration.observe(positionChange: 12, reportedDelta: 9)    // good
            }
            if index > 20 { signs.insert(calibration.polarity) }
        }
        #expect(signs == [1], "the sign flapped: \(signs)")
    }
}
