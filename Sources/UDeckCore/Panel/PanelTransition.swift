import CoreGraphics
import Foundation

/// How something moves. The Core half of an animation: a shape and two numbers,
/// with no opinion about who draws it.
public enum PanelMotion: Equatable, Sendable {
    /// No motion at all — state it and be done.
    case immediate
    /// Arriving. Allowed to overshoot a little; that is what reads as mass.
    case spring(response: TimeInterval, damping: Double)
    /// Leaving. Monotonic, because a spring on the way out means the panel
    /// bounces back towards someone who has already dismissed it.
    case ease(duration: TimeInterval)
}

/// Everything one change of phase decides, worked out before anything moves.
///
/// This is the file the panel's faults lived in. Every one of them was a value
/// read in the wrong frame of reference, and all four came from the same idea:
/// the window is **larger than the panel while a transition is in flight** — a
/// stage the panel grows on — and **exactly the panel once it stops**. That
/// buys a reveal with no window resize in it, and it costs a rectangle whose
/// meaning changes underneath you:
///
/// * a dead strip of screen around the panel, when the stage outlived the
///   transition;
/// * a swallowed first click, when the same was patched from the pointer stream
///   and lost the race to a click;
/// * different behaviour on a display the panel was not already on, because the
///   window moved as well as resized;
/// * every reveal after the first sliding in from the corner, because the
///   outgoing rectangle was stated at the window's own origin and then read
///   against a stage that had replaced it.
///
/// So the decisions live here, as a value computed from geometry, and the
/// controller does what it is told. Being a value is the whole point: the four
/// faults above are each one assertion long against a plan, and were each
/// unreachable while this was a hundred lines inside an AppKit callback.
public struct PanelTransition: Equatable, Sendable {
    /// The frame the window takes for the duration of the transition.
    public var stageFrame: CGRect

    /// The panel's rectangle **restated in the stage's coordinates** before
    /// anything is animated, when the window is moving under it.
    ///
    /// Nil when the window is not moving, in which case the rectangle already
    /// means what it says. Non-nil means: state this first, let one turn of the
    /// run loop pass, then animate. One frame is invisible; the corner slide it
    /// prevents was not.
    public var restatedPanelRect: CGRect?

    /// Where the panel ends up, in the stage's coordinates.
    public var panelRect: CGRect

    /// The frame the window comes down to once nothing is moving: exactly the
    /// panel, so that every point in the window is a point the panel draws on
    /// and everything outside belongs to whoever is behind it.
    public var settledWindowFrame: CGRect

    /// How the shape moves.
    public var motion: PanelMotion

    /// How the content fades, and how long after the shape it starts.
    ///
    /// Sequenced behind the frame, never tied to it: text at full strength
    /// inside a box that is still growing reads as text overflowing a small
    /// panel rather than as a panel filling up.
    public var contentMotion: PanelMotion
    public var contentDelay: TimeInterval

    /// How long until the window is brought down to `settledWindowFrame`.
    /// Zero means immediately.
    public var settleAfter: TimeInterval

    /// Anything but a collapse. A peek becoming a panel and a panel becoming
    /// fullscreen are both arrivals; only going away is a departure.
    public var isArriving: Bool

    /// Whether clicks pass straight through the window. True only while the
    /// panel is away: the island is a hint, not a target.
    public var ignoresMouseEvents: Bool

    /// Whether the panel's top edge is the screen's top edge in the state it is
    /// heading for.
    public var weldedToTopEdge: Bool

    /// Works out everything one phase change decides.
    ///
    /// - Parameters:
    ///   - from: the phase being left. Its rectangle is what the animation
    ///     starts from, and reading it in the wrong window is what made the
    ///     panel slide in from the corner.
    ///   - to: the phase being entered.
    ///   - currentWindowFrame: where the window is right now — which is the
    ///     settled panel between transitions and the stage during one.
    ///   - animated: false for a placement rather than a transition (a screen
    ///     change, a first show), where there is nothing to watch.
    public static func plan(
        from: PanelPhase,
        to: PanelPhase,
        currentWindowFrame: CGRect,
        geometry: PanelGeometry,
        metrics: PanelMetrics,
        animated: Bool
    ) -> PanelTransition {
        let stage = geometry.windowFrame(for: to)
        let arriving = to != .collapsed
        let windowIsMoving = currentWindowFrame != stage

        let motion: PanelMotion = {
            guard animated else { return .immediate }
            return arriving
                ? .spring(response: metrics.revealSpringResponse, damping: metrics.revealSpringDamping)
                : .ease(duration: metrics.collapseDuration)
        }()

        // A spring has no duration — it has a tail that runs on long after the
        // eye has stopped following it. The window is brought down once the
        // shape has visibly arrived, which is a multiple of the response and
        // not the response itself.
        let settleAfter: TimeInterval = {
            guard animated else { return 0 }
            return arriving ? metrics.revealSpringResponse * 1.6 : metrics.collapseDuration
        }()

        return PanelTransition(
            stageFrame: stage,
            // Stated in the stage's coordinates, not in the window the
            // outgoing phase would have picked for itself — those two are the
            // same for every hover state and are not for fullscreen.
            restatedPanelRect: animated && windowIsMoving
                ? geometry.panelRect(for: from, inWindow: stage)
                : nil,
            panelRect: geometry.panelRectInWindow(for: to),
            settledWindowFrame: geometry.settledWindowFrame(for: to),
            motion: motion,
            contentMotion: animated
                ? .ease(duration: arriving ? metrics.contentRevealDuration : metrics.contentHideDuration)
                : .immediate,
            contentDelay: animated && arriving ? metrics.contentRevealDelay : 0,
            settleAfter: settleAfter,
            isArriving: arriving,
            ignoresMouseEvents: to == .collapsed,
            weldedToTopEdge: geometry.frame(for: to).maxY >= geometry.screen.frame.maxY
        )
    }
}
