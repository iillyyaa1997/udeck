import CoreGraphics
import Foundation

/// Decides when a cursor movement means "show me the panel".
///
/// The problem this solves: the activation area is the same place as the menu
/// bar, so every legitimate reason to move the cursor to the top of the screen
/// is a false-positive candidate — and the failure is asymmetric. A missed
/// activation costs one extra mouse move; a spurious one covers the menu the
/// operator was reaching for and steals their click. So this is tuned for
/// precision, not recall.
///
/// Two paths lead to a reveal:
///
/// * **The push.** The cursor is already pinned against the top edge and the
///   device keeps moving upward. Reaching a menu-bar target stops the instant it
///   lands — that *is* the target — so continued pressure is a signal nothing
///   else produces. It fires with no added delay, because the operator is still
///   mid-gesture when it happens.
/// * **The dwell.** The cursor rests inside the strip for a fraction of a
///   second without sliding sideways. Cancelled by horizontal motion, which is
///   what a menu-bar traversal looks like, and lengthened when the cursor
///   arrived travelling sideways — the path taken when crossing between
///   displays.
///
/// The type is a value type with no dependencies so it can be driven by a test
/// with a fabricated event stream, which is the only practical way to verify
/// any of the above.
public struct HoverGestureRecognizer: Sendable {
    private struct HistoryEntry {
        let location: CGPoint
        let delta: CGVector
        let timestamp: TimeInterval
    }

    private var history: [HistoryEntry] = []
    private var pushWindow: [(timestamp: TimeInterval, upward: CGFloat)] = []

    private var dwellStart: TimeInterval?
    private var dwellHorizontalTravel: CGFloat = 0
    private var requiredDwell: TimeInterval = 0
    private var firedThisVisit = false
    private var insideStrip = false

    /// Whether the cursor was already against the top edge before the movement
    /// currently being handled. The delta that *arrives* at the edge is the
    /// throw itself, not the push that follows it — counting it would make the
    /// gesture fire on any fast flick towards a menu-bar target, which is the
    /// most common false positive there is.
    private var wasPinned = false

    /// Hard bound on the history buffer, so a long slow approach cannot grow it
    /// without limit. Well above what `approachSampleDistance` needs at any
    /// realistic event rate.
    private let historyLimit = 240

    public init() {}

    /// Feeds one movement in and reports what it means.
    ///
    /// `geometry` is the geometry of the screen the cursor is currently on;
    /// pass `nil` when the cursor is on no known screen, which resets the
    /// recognizer rather than leaving it half-armed.
    public mutating func handle(
        _ sample: PointerSample,
        geometry: PanelGeometry?,
        environment: GestureEnvironment,
        tuning: GestureTuning
    ) -> GestureOutcome {
        recordHistory(sample, tuning: tuning)

        guard let geometry, geometry.triggerStrip.contains(sample.location) else {
            // Leaving the strip ends the visit, whatever else is going on. This
            // is the only place the gesture re-arms.
            reset()
            return .idle(reason: blockingReason(environment: environment, tuning: tuning, now: sample.timestamp)
                ?? .outsideStrip)
        }

        if !insideStrip {
            beginStripVisit(sample, tuning: tuning)
        }

        if let blocked = blockingReason(environment: environment, tuning: tuning, now: sample.timestamp) {
            if blocked == .alreadyVisible {
                // The panel is already showing, and the cursor is sitting in the
                // strip that opened it. That visit is spent: when the panel does
                // close — because the operator switched applications, say — it
                // must not immediately spring back under a cursor that never
                // moved. The gesture re-arms when the cursor leaves.
                firedThisVisit = true
            } else {
                // Every other gate is momentary. Restart the dwell so that the
                // pause has to be made again once the gate lifts, but keep the
                // visit alive.
                dwellStart = sample.timestamp
                dwellHorizontalTravel = 0
                pushWindow.removeAll(keepingCapacity: true)
            }
            return .idle(reason: blocked)
        }

        if firedThisVisit {
            return .idle(reason: .alreadyFiredThisVisit)
        }

        updateDwell(sample, tuning: tuning)
        updatePushWindow(sample, geometry: geometry, tuning: tuning)

        if accumulatedPush(tuning: tuning, now: sample.timestamp) >= tuning.edgePushDistance {
            firedThisVisit = true
            wasPinned = geometry.isPinnedToTopEdge(sample.location)
            return .fire
        }

        if let start = dwellStart, sample.timestamp - start >= requiredDwell {
            firedThisVisit = true
            return .fire
        }

        return .arming(progress: progress(tuning: tuning, now: sample.timestamp))
    }

    /// Stops the gesture from firing again until the cursor has left the strip
    /// and come back.
    ///
    /// Used when the panel closes. Without it, a cursor parked in the strip
    /// while the operator switches to another application would immediately
    /// re-open the panel they just left — the panel would follow them around
    /// instead of getting out of the way.
    public mutating func suppressUntilPointerLeaves() {
        dwellStart = nil
        dwellHorizontalTravel = 0
        wasPinned = false
        pushWindow.removeAll(keepingCapacity: true)
        firedThisVisit = true
    }

    /// Forgets everything. Call when the panel opens or the screen arrangement
    /// changes, so a stale half-armed gesture cannot fire into a new world.
    public mutating func reset() {
        dwellStart = nil
        dwellHorizontalTravel = 0
        firedThisVisit = false
        insideStrip = false
        wasPinned = false
        pushWindow.removeAll(keepingCapacity: true)
    }

    // MARK: - Gates

    private func blockingReason(
        environment: GestureEnvironment,
        tuning: GestureTuning,
        now: TimeInterval
    ) -> GestureOutcome.IdleReason? {
        if !tuning.enabled { return .disabled }
        if environment.panelVisible { return .alreadyVisible }
        if environment.buttonsDown { return .buttonDown }
        if environment.menuTrackingActive { return .menuTracking }
        if environment.frontmostIsFullscreen && !tuning.enabledInFullscreen { return .fullscreen }
        if let up = environment.lastMenuBarButtonUp, now - up < tuning.buttonReleaseGrace {
            return .menuBarClickGrace
        }
        if let dismissed = environment.lastDismissal, now - dismissed < tuning.reopenCooldown {
            return .reopenCooldown
        }
        return nil
    }

    // MARK: - Strip visit

    private mutating func beginStripVisit(_ sample: PointerSample, tuning: GestureTuning) {
        insideStrip = true
        dwellStart = sample.timestamp
        dwellHorizontalTravel = 0
        firedThisVisit = false
        pushWindow.removeAll(keepingCapacity: true)
        requiredDwell = approachWasLateral(tuning: tuning)
            ? tuning.lateralApproachDwellDuration
            : tuning.dwellDuration
    }

    /// True when the last stretch of travel before the strip was mostly
    /// sideways. Crossing from one display to another is almost pure horizontal
    /// motion, and on this machine that path passes straight through the other
    /// screen's menu-bar row — so it needs a visibly deliberate pause rather
    /// than an outright veto, which would also reject a genuine diagonal throw.
    private func approachWasLateral(tuning: GestureTuning) -> Bool {
        guard history.count >= 2 else { return false }
        var dx: CGFloat = 0
        var dy: CGFloat = 0
        var travelled: CGFloat = 0
        // Walk backwards from the newest sample, excluding it: the newest sample
        // is the one that entered the strip.
        for entry in history.dropLast().reversed() {
            dx += entry.delta.dx
            dy += entry.delta.dy
            travelled += hypot(entry.delta.dx, entry.delta.dy)
            if travelled >= tuning.approachSampleDistance { break }
        }
        guard travelled > 0 else { return false }
        return abs(dx) > tuning.lateralApproachRatio * max(dy, 0)
    }

    /// Horizontal motion inside the strip **restarts** the dwell rather than
    /// disabling it until the cursor leaves.
    ///
    /// Both readings prevent the menu-bar traversal from opening the panel — a
    /// cursor that keeps sliding never lets the timer finish either way. The
    /// difference is what happens when the operator slides sideways and then
    /// stops on purpose: disabling until exit would refuse to open at all,
    /// which reads as the gesture being broken. Restarting asks them to hold
    /// still for a moment instead, and asks for the longer lateral dwell,
    /// because sliding sideways is exactly the approach that needs proving.
    private mutating func updateDwell(_ sample: PointerSample, tuning: GestureTuning) {
        dwellHorizontalTravel += abs(sample.delta.dx)

        var slidSideways = dwellHorizontalTravel >= tuning.dwellHorizontalTolerance
        if !slidSideways, let previous = history.dropLast().last {
            let dt = sample.timestamp - previous.timestamp
            slidSideways = dt > 0
                && abs(sample.delta.dx) / CGFloat(dt) >= tuning.dwellHorizontalSpeedLimit
        }

        guard slidSideways else { return }
        dwellStart = sample.timestamp
        dwellHorizontalTravel = 0
        requiredDwell = tuning.lateralApproachDwellDuration
    }

    // MARK: - Edge push

    private mutating func updatePushWindow(
        _ sample: PointerSample,
        geometry: PanelGeometry,
        tuning: GestureTuning
    ) {
        let pinnedNow = geometry.isPinnedToTopEdge(sample.location)
        defer { wasPinned = pinnedNow }

        guard pinnedNow else {
            // Still in flight. Upward travel only counts once the cursor has
            // nowhere left to go.
            pushWindow.removeAll(keepingCapacity: true)
            return
        }
        // Count only movement made while already pinned.
        if wasPinned && sample.delta.dy > 0 {
            pushWindow.append((sample.timestamp, sample.delta.dy))
        }
        trimPushWindow(now: sample.timestamp, tuning: tuning)
    }

    private mutating func trimPushWindow(now: TimeInterval, tuning: GestureTuning) {
        let cutoff = now - tuning.edgePushWindow
        while let first = pushWindow.first, first.timestamp < cutoff {
            pushWindow.removeFirst()
        }
    }

    private func accumulatedPush(tuning: GestureTuning, now: TimeInterval) -> CGFloat {
        let cutoff = now - tuning.edgePushWindow
        return pushWindow.reduce(into: CGFloat(0)) { total, entry in
            if entry.timestamp >= cutoff { total += entry.upward }
        }
    }

    // MARK: - Progress

    private func progress(tuning: GestureTuning, now: TimeInterval) -> Double {
        let pushProgress = tuning.edgePushDistance > 0
            ? Double(accumulatedPush(tuning: tuning, now: now) / tuning.edgePushDistance)
            : 0
        let dwellProgress: Double = {
            guard let start = dwellStart, requiredDwell > 0 else { return 0 }
            return (now - start) / requiredDwell
        }()
        return min(1, max(0, max(pushProgress, dwellProgress)))
    }

    // MARK: - History

    private mutating func recordHistory(_ sample: PointerSample, tuning: GestureTuning) {
        history.append(HistoryEntry(location: sample.location,
                                    delta: sample.delta,
                                    timestamp: sample.timestamp))
        if history.count > historyLimit {
            history.removeFirst(history.count - historyLimit)
        }
    }
}
