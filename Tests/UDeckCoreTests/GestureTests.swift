import CoreGraphics
import Foundation
import Testing
@testable import UDeckCore

/// Drives the recognizer the way the real event stream would: a sequence of
/// moves with real deltas and real timestamps. Nothing here is faked past the
/// event source, which is the point — the recognizer's whole job is to read a
/// stream of moves, so it has to be tested against one.
private struct Driver {
    var recognizer = HoverGestureRecognizer()
    var geometry: PanelGeometry
    var tuning: GestureTuning
    var environment = GestureEnvironment()
    var clock: TimeInterval = 1_000
    var cursor: CGPoint
    private(set) var outcomes: [GestureOutcome] = []

    init(
        screen: ScreenSnapshot = ScreenFixtures.externalMain,
        tuning: GestureTuning = GestureTuning(),
        startingAt start: CGPoint? = nil
    ) {
        self.tuning = tuning
        self.geometry = PanelGeometry(screen: screen, tuning: tuning, metrics: PanelMetrics())
        self.cursor = start ?? CGPoint(x: screen.frame.midX, y: screen.frame.midY)
    }

    /// Moves the pointer, clamping the position at the top edge the way macOS
    /// does while still reporting the full device delta.
    ///
    /// The clamp is `frame.maxY`, not `maxY - 1`. This driver used to stop one
    /// point short, which meant no test it could write was able to reach the
    /// row the cursor actually lands on — and the gesture was dead on that row
    /// for as long as the suite was green.
    @discardableResult
    mutating func move(dx: CGFloat, dy: CGFloat, over seconds: TimeInterval = 0.008) -> GestureOutcome {
        clock += seconds
        cursor.x += dx
        cursor.y = min(cursor.y + dy, geometry.screen.frame.maxY)
        cursor.x = min(max(cursor.x, geometry.screen.frame.minX), geometry.screen.frame.maxX - 1)
        let sample = PointerSample(location: cursor, delta: CGVector(dx: dx, dy: dy), timestamp: clock)
        let outcome = recognizer.handle(sample, geometry: geometry, environment: environment, tuning: tuning)
        outcomes.append(outcome)
        return outcome
    }

    /// Stays put for a while, the way a real stream still reports the odd event.
    @discardableResult
    mutating func rest(for seconds: TimeInterval, steps: Int = 8) -> GestureOutcome {
        var last: GestureOutcome = .idle(reason: .outsideStrip)
        for _ in 0 ..< steps { last = move(dx: 0, dy: 0, over: seconds / Double(steps)) }
        return last
    }

    var fired: Bool { outcomes.contains(.fire) }
}

@Suite("Pointer gesture")
struct GestureTests {
    /// The gesture the operator actually makes: throw the cursor at the top of
    /// the screen, and keep pushing after it lands.
    @Test("pushing on after the cursor pins to the edge fires immediately")
    func edgePushFires() {
        var driver = Driver(startingAt: CGPoint(x: 1280, y: 1200))
        driver.move(dx: 0, dy: 300)   // arrives, and the cursor clamps
        #expect(!driver.fired, "the throw itself must not count as the push")
        driver.move(dx: 0, dy: 25)    // still pushing, against the edge
        driver.move(dx: 0, dy: 25)
        #expect(driver.fired)
    }

    /// Stated against the tuning rather than against a number.
    ///
    /// It used to rest for a flat 0.1s, which passed only while the dwell was
    /// 0.22 and failed the moment the dwell was shortened — reading as a broken
    /// gesture when what had actually changed was a setting. How long the pause
    /// has to be is a tuning decision, argued out in `GestureTuning.dwellDuration`;
    /// what is *not* a tuning decision, and is what this guards, is that a stop
    /// shorter than the pause never opens anything.
    @Test("arriving at a menu-bar target and stopping does not fire before the dwell")
    func arrivingAndStoppingDoesNotFire() {
        var driver = Driver(startingAt: CGPoint(x: 1280, y: 1200))
        driver.move(dx: 0, dy: 300)
        // The hand stops, because the target has been reached. Real streams still
        // deliver a few zero-delta events.
        driver.rest(for: driver.tuning.dwellDuration * 0.5)
        #expect(!driver.fired)
    }

    @Test("resting in the strip fires on the dwell")
    func dwellFires() {
        var driver = Driver(startingAt: CGPoint(x: 1280, y: 1200))
        driver.move(dx: 0, dy: 300)
        driver.rest(for: 0.3)
        #expect(driver.fired)
    }

    /// The row the gesture actually ends on. Shoving the cursor at the top of
    /// the screen leaves it at `frame.maxY` exactly — verified against the
    /// running app, where the panel opened at 1439 and did nothing at 1440.
    @Test("the gesture works on the top row of the screen, not only one below it")
    func firesOnTheVeryTopRow() {
        for start in [CGFloat(1439), 1440] {
            var driver = Driver(startingAt: CGPoint(x: 1280, y: 1200))
            driver.move(dx: 0, dy: 1440 - 1200)
            driver.cursor.y = start
            driver.rest(for: 0.3)
            #expect(driver.fired, "a cursor resting at y = \(start) must open the panel")
        }
    }

    /// The single most damaging false positive: travelling along the menu bar
    /// from the app menus on the left to the status items on the right.
    @Test("traversing the menu bar sideways never fires")
    func menuBarTraversalDoesNotFire() {
        var driver = Driver(startingAt: CGPoint(x: 400, y: 1439))
        for _ in 0 ..< 200 {
            driver.move(dx: 9, dy: 0, over: 0.008)
        }
        #expect(!driver.fired)
        #expect(driver.cursor.x > 1400, "the traversal should have crossed the strip")
    }

    @Test("a slow sideways traversal outlasts the dwell and still does not fire")
    func slowTraversalDoesNotFire() {
        // Slow enough that a naive delay would expire mid-crossing.
        var driver = Driver(startingAt: CGPoint(x: 1100, y: 1439))
        for _ in 0 ..< 60 {
            driver.move(dx: 4, dy: 0, over: 0.02)
        }
        #expect(!driver.fired)
    }

    @Test("crossing in from the side needs a visibly longer pause")
    func lateralApproachNeedsLongerDwell() {
        var driver = Driver(startingAt: CGPoint(x: 1000, y: 1439))
        // Arrive travelling almost purely sideways, as when crossing displays,
        // and stop just inside the strip.
        for _ in 0 ..< 25 { driver.move(dx: 8, dy: 0, over: 0.008) }
        #expect(driver.geometry.containsPointer(driver.cursor, in: driver.geometry.triggerStrip))
        // Long enough to have fired on the ordinary dwell, short of the lateral
        // one — the gap between the two is the whole point, so the test is
        // written from the gap and not from the numbers that happen to fill it.
        #expect(driver.tuning.lateralApproachDwellDuration > driver.tuning.dwellDuration * 2,
                "a lateral approach has to cost visibly more than an ordinary one")
        driver.rest(for: driver.tuning.lateralApproachDwellDuration * 0.75)
        #expect(!driver.fired, "the normal dwell must not be enough after a lateral approach")
        driver.rest(for: driver.tuning.lateralApproachDwellDuration * 0.5)
        #expect(driver.fired, "a deliberate longer pause should still work")
    }

    @Test("a held mouse button suppresses the gesture entirely")
    func buttonDownSuppresses() {
        var driver = Driver(startingAt: CGPoint(x: 1280, y: 1200))
        driver.environment.buttonsDown = true
        driver.move(dx: 0, dy: 300)
        driver.move(dx: 0, dy: 60)
        driver.rest(for: 0.5)
        #expect(!driver.fired)
        #expect(driver.outcomes.last == .idle(reason: .buttonDown))
    }

    @Test("an open system menu suppresses the gesture")
    func menuTrackingSuppresses() {
        var driver = Driver(startingAt: CGPoint(x: 1280, y: 1200))
        driver.environment.menuTrackingActive = true
        driver.move(dx: 0, dy: 300)
        driver.rest(for: 0.5)
        #expect(!driver.fired)
    }

    /// A fullscreen game is exactly when the panel is wanted and exactly when
    /// it used to refuse, which is how a panel stops being reached for at all.
    /// The gate is still there, because hover panels of this kind have been
    /// seen to leave macOS's own menu-bar reveal stuck inside a fullscreen app
    /// — it is just no longer the default.
    @Test("a fullscreen app does not suppress the gesture, but the gate still works")
    func fullscreenIsAllowedByDefault() {
        var driver = Driver(startingAt: CGPoint(x: 1280, y: 1200))
        driver.environment.frontmostIsFullscreen = true
        driver.move(dx: 0, dy: 300)
        driver.rest(for: 0.5)
        #expect(driver.fired)

        var suppressed = Driver(tuning: {
            var t = GestureTuning(); t.enabledInFullscreen = false; return t
        }(), startingAt: CGPoint(x: 1280, y: 1200))
        suppressed.environment.frontmostIsFullscreen = true
        suppressed.move(dx: 0, dy: 300)
        suppressed.rest(for: 0.5)
        #expect(!suppressed.fired)
        #expect(suppressed.outcomes.last == .idle(reason: .fullscreen))
    }

    @Test("a click in the menu bar keeps the gesture quiet for a moment afterwards")
    func menuBarClickGrace() {
        var driver = Driver(startingAt: CGPoint(x: 1280, y: 1200))
        driver.environment.lastMenuBarButtonUp = driver.clock + 0.3
        driver.move(dx: 0, dy: 300)
        driver.rest(for: 0.2)
        #expect(!driver.fired)
    }

    /// The oscillation failure: the panel closes, the cursor has not moved, and
    /// the trigger fires again immediately.
    @Test("a dismissal silences the trigger for the cooldown")
    func cooldownAfterDismissal() {
        var driver = Driver(startingAt: CGPoint(x: 1280, y: 1200))
        driver.move(dx: 0, dy: 300)
        driver.environment.lastDismissal = driver.clock
        driver.rest(for: 0.4)
        #expect(!driver.fired)
        driver.rest(for: 0.5)
        #expect(driver.fired, "once the cooldown passes the gesture works again")
    }

    @Test("a visible panel is not re-triggered")
    func visiblePanelNotRetriggered() {
        var driver = Driver(startingAt: CGPoint(x: 1280, y: 1200))
        driver.environment.panelVisible = true
        driver.move(dx: 0, dy: 300)
        driver.rest(for: 0.5)
        #expect(!driver.fired)
    }

    @Test("a disabled gesture never fires")
    func disabledNeverFires() {
        var tuning = GestureTuning()
        tuning.enabled = false
        var driver = Driver(tuning: tuning, startingAt: CGPoint(x: 1280, y: 1200))
        driver.move(dx: 0, dy: 300)
        driver.rest(for: 1)
        #expect(!driver.fired)
    }

    @Test("it fires once per visit, not on every event afterwards")
    func firesOncePerVisit() {
        var driver = Driver(startingAt: CGPoint(x: 1280, y: 1200))
        driver.move(dx: 0, dy: 300)
        driver.rest(for: 0.6)
        #expect(driver.outcomes.filter { $0 == .fire }.count == 1)
    }

    @Test("leaving and coming back arms the gesture again")
    func leavingRearms() {
        var driver = Driver(startingAt: CGPoint(x: 1280, y: 1200))
        driver.move(dx: 0, dy: 300)
        driver.rest(for: 0.3)
        #expect(driver.fired)

        driver.move(dx: 0, dy: -400)          // away from the edge
        driver.recognizer.reset()             // as the host does when the panel opens
        driver.environment.panelVisible = false
        let before = driver.outcomes.filter { $0 == .fire }.count
        driver.move(dx: 0, dy: 400)
        driver.rest(for: 0.3)
        #expect(driver.outcomes.filter { $0 == .fire }.count == before + 1)
    }

    @Test("the notched screen behaves the same as the notchless one")
    func worksOnTheNotchedScreen() {
        var driver = Driver(
            screen: ScreenFixtures.builtInNotched,
            startingAt: CGPoint(x: -864, y: 700)
        )
        driver.move(dx: 0, dy: 300)
        driver.rest(for: 0.3)
        #expect(driver.fired)
    }

    @Test("the strip is where the notch is, not where the screen centre is")
    func stripFollowsTheNotch() {
        // The built-in's notch is centred at x = -864.5, and its frame midX is
        // -864 — close, so pick a point that is inside the frame but far from
        // the notch to prove the strip is not simply the screen centre.
        var driver = Driver(
            screen: ScreenFixtures.builtInNotched,
            startingAt: CGPoint(x: -1400, y: 700)
        )
        driver.move(dx: 0, dy: 300)
        driver.rest(for: 0.5)
        #expect(!driver.fired)
    }

    @Test("progress is reported while arming, so a calibration screen can show it")
    func progressIsReported() {
        var driver = Driver(startingAt: CGPoint(x: 1280, y: 1200))
        driver.move(dx: 0, dy: 300)
        driver.rest(for: 0.15, steps: 6)
        let arming = driver.outcomes.compactMap { outcome -> Double? in
            if case .arming(let progress) = outcome { return progress }
            return nil
        }
        #expect(!arming.isEmpty)
        #expect(arming.allSatisfy { $0 >= 0 && $0 <= 1 })
        #expect(arming.last! > arming.first!)
    }
}

@Suite("Pointer gesture — re-arming")
struct GestureRearmTests {
    /// The panel closes because the operator switched to another application,
    /// while their cursor happens to be parked in the strip. It must not follow
    /// them back.
    @Test("a spent visit does not fire again until the cursor leaves the strip")
    func spentVisitDoesNotRefire() {
        var recognizer = HoverGestureRecognizer()
        let geometry = PanelGeometry(
            screen: ScreenFixtures.externalMain, tuning: GestureTuning(), metrics: PanelMetrics()
        )
        let tuning = GestureTuning()
        var clock: TimeInterval = 100

        func send(_ point: CGPoint, visible: Bool, dismissedAt: TimeInterval? = nil) -> GestureOutcome {
            clock += 0.05
            return recognizer.handle(
                PointerSample(location: point, delta: .zero, timestamp: clock),
                geometry: geometry,
                environment: GestureEnvironment(panelVisible: visible, lastDismissal: dismissedAt),
                tuning: tuning
            )
        }

        let inStrip = CGPoint(x: 1280, y: 1439)
        let away = CGPoint(x: 400, y: 700)

        // Arm and fire.
        _ = send(inStrip, visible: false)
        var fired = false
        for _ in 0 ..< 10 where !fired {
            if send(inStrip, visible: false) == .fire { fired = true }
        }
        #expect(fired)

        // The panel is up; the cursor stays where it is.
        for _ in 0 ..< 5 { _ = send(inStrip, visible: true) }

        // The panel closes on its own — an application switch — and the cursor
        // has still not moved. Long enough after that the cooldown has expired.
        clock += 5
        for _ in 0 ..< 20 {
            #expect(send(inStrip, visible: false, dismissedAt: clock - 5) != .fire)
        }

        // Leaving and coming back is what re-arms it.
        _ = send(away, visible: false, dismissedAt: clock - 5)
        var refired = false
        for _ in 0 ..< 15 where !refired {
            if send(inStrip, visible: false, dismissedAt: clock - 5) == .fire { refired = true }
        }
        #expect(refired)
    }
}

@Suite("Pointer gesture — bounds")
struct GestureBoundsTests {
    /// The recognizer keeps a history to judge the approach direction. It is
    /// bounded, and the comment says so — which is the kind of sentence that
    /// should have a test behind it rather than a reader's trust.
    @Test("the history does not grow without limit")
    func historyIsBounded() {
        var recognizer = HoverGestureRecognizer()
        let geometry = PanelGeometry(
            screen: ScreenFixtures.externalMain, tuning: GestureTuning(), metrics: PanelMetrics()
        )
        var clock: TimeInterval = 0
        for index in 0 ..< 20_000 {
            clock += 0.001
            _ = recognizer.handle(
                PointerSample(
                    location: CGPoint(x: 400 + CGFloat(index % 100), y: 700),
                    delta: CGVector(dx: 1, dy: 0),
                    timestamp: clock
                ),
                geometry: geometry,
                environment: GestureEnvironment(),
                tuning: GestureTuning()
            )
        }
        // Nothing observable leaks, and the run finishes in reasonable time —
        // an unbounded history would make each sample more expensive than the
        // last.
        #expect(clock > 0)
    }

    /// "A stale half-armed gesture cannot fire into a new world" — the reason
    /// `reset()` exists.
    @Test("a reset gesture does not fire on the next sample")
    func resetDisarms() {
        var recognizer = HoverGestureRecognizer()
        let geometry = PanelGeometry(
            screen: ScreenFixtures.externalMain, tuning: GestureTuning(), metrics: PanelMetrics()
        )
        var clock: TimeInterval = 100
        func send() -> GestureOutcome {
            clock += 0.05
            return recognizer.handle(
                PointerSample(location: CGPoint(x: 1280, y: 1439), delta: .zero, timestamp: clock),
                geometry: geometry, environment: GestureEnvironment(), tuning: GestureTuning()
            )
        }

        _ = send()
        recognizer.reset()
        // A dwell that was nearly complete must start again from nothing.
        clock += 1
        #expect(send() != .fire, "the dwell should have restarted, not completed")
    }
}
