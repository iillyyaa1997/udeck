import Foundation
import Testing
@testable import UDeckCore

@Suite("Leaving a peek")
struct PeekExitTests {
    let grace: TimeInterval = 0.25

    /// The reason the grace period exists at all: the cursor crosses a corner
    /// of the panel on its way somewhere else, and the panel must not take that
    /// as being dismissed.
    @Test("a flick past the panel never closes it")
    func flickPastDoesNotClose() {
        var tracker = PeekExitTracker()
        var now: TimeInterval = 100
        #expect(tracker.update(isPeeking: true, isInsideRegion: true, now: now, grace: grace) == .stay)

        // Out for a fraction of the grace…
        now += 0.02
        #expect(tracker.update(isPeeking: true, isInsideRegion: false, now: now, grace: grace) == .leftJustNow)
        now += 0.05
        #expect(tracker.update(isPeeking: true, isInsideRegion: false, now: now, grace: grace) == .waiting)
        // …and back in.
        now += 0.05
        #expect(tracker.update(isPeeking: true, isInsideRegion: true, now: now, grace: grace) == .stay)
        #expect(!tracker.isTiming)
    }

    @Test("staying away past the grace closes it")
    func stayingAwayCloses() {
        var tracker = PeekExitTracker()
        var now: TimeInterval = 100
        #expect(tracker.update(isPeeking: true, isInsideRegion: false, now: now, grace: grace) == .leftJustNow)
        now += grace - 0.01
        #expect(tracker.update(isPeeking: true, isInsideRegion: false, now: now, grace: grace) == .waiting)
        now += 0.02
        #expect(tracker.update(isPeeking: true, isInsideRegion: false, now: now, grace: grace) == .close)
    }

    /// Two different grace periods, because a test that only ever uses one
    /// cannot tell "waits for the grace" from "waits for a quarter of a second".
    @Test("the grace period is the configured one, whatever it is")
    func graceIsRespected() {
        for configured in [TimeInterval(0.05), 0.25, 1.5] {
            var tracker = PeekExitTracker()
            var now: TimeInterval = 500
            #expect(tracker.update(isPeeking: true, isInsideRegion: false, now: now, grace: configured) == .leftJustNow)
            now += configured * 0.9
            #expect(tracker.update(isPeeking: true, isInsideRegion: false, now: now, grace: configured) == .waiting,
                    "closed early with a grace of \(configured)")
            now += configured * 0.2
            #expect(tracker.update(isPeeking: true, isInsideRegion: false, now: now, grace: configured) == .close,
                    "never closed with a grace of \(configured)")
        }
    }

    @Test("exactly on the grace counts as elapsed")
    func boundaryCloses() {
        var tracker = PeekExitTracker()
        _ = tracker.update(isPeeking: true, isInsideRegion: false, now: 10, grace: grace)
        #expect(tracker.update(isPeeking: true, isInsideRegion: false, now: 10 + grace, grace: grace) == .close)
    }

    /// The cursor leaving, coming back, and leaving again is two visits. The
    /// second one has to be timed from when it started, or a panel the operator
    /// is dipping in and out of closes under them.
    @Test("returning starts the clock over rather than pausing it")
    func returningResetsTheClock() {
        var tracker = PeekExitTracker()
        var now: TimeInterval = 100
        _ = tracker.update(isPeeking: true, isInsideRegion: false, now: now, grace: grace)
        now += grace * 0.8
        _ = tracker.update(isPeeking: true, isInsideRegion: false, now: now, grace: grace)
        now += 0.01
        _ = tracker.update(isPeeking: true, isInsideRegion: true, now: now, grace: grace)

        // Leaving again: had the first departure been carried over, this would
        // close immediately.
        now += 0.01
        #expect(tracker.update(isPeeking: true, isInsideRegion: false, now: now, grace: grace) == .leftJustNow)
        now += grace * 0.5
        #expect(tracker.update(isPeeking: true, isInsideRegion: false, now: now, grace: grace) == .waiting)
    }

    /// The whole typing-safety rule: only a peek is dismissible by the cursor.
    /// A panel being worked in stays open however far away the mouse goes.
    @Test("a panel that is not a peek is never closed by the cursor")
    func onlyAPeekCloses() {
        var tracker = PeekExitTracker()
        var now: TimeInterval = 100
        for _ in 0 ..< 200 {
            now += 0.05
            #expect(tracker.update(isPeeking: false, isInsideRegion: false, now: now, grace: grace) == .stay)
        }
        #expect(!tracker.isTiming)
    }

    /// The first sample outside arms a timer rather than closing, and the
    /// caller is told exactly once, so it does not restart its timer on every
    /// sample of a cursor that is sitting still outside the panel.
    @Test("the caller is told to arm its timer once per departure")
    func armsOnceOnly() {
        var tracker = PeekExitTracker()
        var now: TimeInterval = 100
        var armings = 0
        for _ in 0 ..< 5 {
            now += 0.01
            if tracker.update(isPeeking: true, isInsideRegion: false, now: now, grace: grace) == .leftJustNow {
                armings += 1
            }
        }
        #expect(armings == 1)
        #expect(tracker.isTiming)
    }

    @Test("a peek that collapses stops being timed")
    func resetStopsTiming() {
        var tracker = PeekExitTracker()
        _ = tracker.update(isPeeking: true, isInsideRegion: false, now: 100, grace: grace)
        #expect(tracker.isTiming)
        tracker.reset()
        #expect(!tracker.isTiming)
        // And the next departure is a fresh one rather than an elapsed one.
        #expect(tracker.update(isPeeking: true, isInsideRegion: false, now: 200, grace: grace) == .leftJustNow)
    }
}
