import CoreGraphics
import Foundation

/// Every number the pointer gesture depends on.
///
/// These are defaults, not constants: the operator can change all of them, and
/// the gesture is impossible to get right without tuning it by feel. The values
/// come from the UX analysis of how a deliberate "throw the cursor at the top
/// edge" differs from every legitimate reason to touch the menu bar.
public struct GestureTuning: Codable, Equatable, Sendable {
    /// Height of the activation strip measured down from the top edge of the
    /// screen, in points. Deliberately much shorter than the menu bar: every
    /// gesture that matters ends with the cursor pinned against the very top.
    public var stripHeight: CGFloat

    /// Extra width added on each side of the anchor (the notch, or the virtual
    /// notch on a notchless screen) to form the strip.
    public var stripSideMargin: CGFloat

    /// Width of the virtual anchor on a screen that has no notch. Chosen to
    /// match a real notch so the gesture feels identical on both screens.
    public var virtualAnchorWidth: CGFloat

    /// How far the cursor may sit from the top edge and still count as pinned.
    /// macOS clamps the cursor at `maxY - 1`, so this only needs to absorb
    /// rounding across backing scales.
    public var pinnedEpsilon: CGFloat

    /// Fast path: accumulated upward device movement, in points, required while
    /// the cursor is already pinned at the top edge. A menu-bar reach stops the
    /// instant it lands; only a deliberate gesture keeps pushing.
    ///
    /// Measured in device movement, not screen movement, and the cursor is
    /// against the edge the whole time — so on a trackpad this is a real shove
    /// with nothing on screen acknowledging it. Kept well under a full swipe so
    /// that the path which fires with no delay at all is the one a deliberate
    /// gesture actually reaches.
    public var edgePushDistance: CGFloat

    /// The window in which `edgePushDistance` has to accumulate.
    public var edgePushWindow: TimeInterval

    /// Dwell path: how long the cursor must stay inside the strip.
    ///
    /// Short — barely more than the two samples it takes to know the cursor has
    /// stopped. It was five times longer, tuned for precision on the theory that
    /// a spurious reveal covers a menu the operator was reaching for, and the
    /// operator's verdict after using it was that the wait is what he feels and
    /// the false positives are not. The reason is geometry: the strip is six
    /// points tall and 233 wide in the *middle* of the menu bar, where the app
    /// menus have ended and the status items have not begun — and on the laptop
    /// it is the notch, which nobody aims at. The defence that actually earns
    /// its keep is `dwellHorizontalTolerance`, and that is untouched.
    public var dwellDuration: TimeInterval

    /// Longer dwell demanded when the cursor arrived travelling sideways — the
    /// path taken when crossing between displays, or sweeping the menu bar.
    public var lateralApproachDwellDuration: TimeInterval

    /// Cumulative horizontal travel that cancels a dwell in progress.
    public var dwellHorizontalTolerance: CGFloat

    /// Instantaneous horizontal speed (points per second) that cancels a dwell.
    public var dwellHorizontalSpeedLimit: CGFloat

    /// Distance of travel examined to classify the approach direction.
    public var approachSampleDistance: CGFloat

    /// An approach counts as lateral when horizontal travel exceeds vertical
    /// travel by this factor.
    public var lateralApproachRatio: CGFloat

    /// Silence after any dismissal, so the panel cannot re-open under a cursor
    /// that simply has not moved away yet.
    public var reopenCooldown: TimeInterval

    /// Silence after a mouse button is released inside the menu-bar row.
    public var buttonReleaseGrace: TimeInterval

    /// How long the cursor must be outside the panel before a peek collapses.
    ///
    /// A flick past the corner must not close it — but the region it has to
    /// leave is already the panel inflated by `peekKeepAliveInset` on every
    /// side, so leaving it is deliberate before this timer is consulted at all.
    /// Charging a further quarter second on top of that read as the panel
    /// hesitating: the operator asked for it to start shrinking the moment the
    /// cursor is away, and the inset is what keeps the flick safe.
    public var peekExitGrace: TimeInterval

    /// The panel's frame is inflated by this much to form the region that keeps
    /// a peek alive. Using the panel frame rather than the trigger strip is what
    /// prevents the open/close oscillation that hover panels are prone to.
    public var peekKeepAliveInset: CGFloat

    /// Whether the gesture is allowed while the frontmost window on that screen
    /// is fullscreen.
    ///
    /// On, because a panel you cannot reach from the application you are
    /// actually looking at is a panel you stop reaching for. It was off to
    /// begin with for a real reason — hover panels of this kind have been seen
    /// to leave macOS's own menu-bar reveal stuck when they fight it inside a
    /// fullscreen app, and corrupting the *system's* state is a worse class of
    /// problem than an unwanted panel. The setting stays, so that if that ever
    /// shows up it can be turned off without a new build.
    public var enabledInFullscreen: Bool

    /// Whether the pointer gesture is enabled at all.
    public var enabled: Bool


    /// How long an answer to "is the frontmost application fullscreen?" is
    /// reused before asking again, in seconds.
    ///
    /// Asking costs about 1.5 ms, because it means enumerating every on-screen
    /// window. Asking on every pointer event — a hundred a second while the
    /// mouse is moving — would spend a seventh of a core on it, which is a
    /// ridiculous price for a gate that only matters at the top of the screen.
    public var fullscreenCheckInterval: TimeInterval

    /// How often to look at where the cursor is, in seconds, independently of
    /// any event. Zero turns it off.
    ///
    /// Events are the primary source and the only one that carries device
    /// deltas, but they are not the only way a cursor moves: another
    /// application can warp it, and a hand resting on a trackpad produces no
    /// events at all while time keeps passing. A slow look at the actual
    /// position covers both, and costs a point-in-rectangle test ten times a
    /// second while the panel is away.
    public var pointerPollInterval: TimeInterval

    public init(
        stripHeight: CGFloat = 6,
        stripSideMargin: CGFloat = 24,
        virtualAnchorWidth: CGFloat = 185,
        pinnedEpsilon: CGFloat = 2,
        edgePushDistance: CGFloat = 24,
        edgePushWindow: TimeInterval = 0.25,
        dwellDuration: TimeInterval = 0.06,
        lateralApproachDwellDuration: TimeInterval = 0.18,
        dwellHorizontalTolerance: CGFloat = 12,
        dwellHorizontalSpeedLimit: CGFloat = 250,
        approachSampleDistance: CGFloat = 120,
        lateralApproachRatio: CGFloat = 2,
        reopenCooldown: TimeInterval = 0.6,
        buttonReleaseGrace: TimeInterval = 0.3,
        peekExitGrace: TimeInterval = 0.06,
        peekKeepAliveInset: CGFloat = 24,
        enabledInFullscreen: Bool = true,
        enabled: Bool = true,
        fullscreenCheckInterval: TimeInterval = 0.25,
        pointerPollInterval: TimeInterval = 0.1
    ) {
        self.stripHeight = stripHeight
        self.stripSideMargin = stripSideMargin
        self.virtualAnchorWidth = virtualAnchorWidth
        self.pinnedEpsilon = pinnedEpsilon
        self.edgePushDistance = edgePushDistance
        self.edgePushWindow = edgePushWindow
        self.dwellDuration = dwellDuration
        self.lateralApproachDwellDuration = lateralApproachDwellDuration
        self.dwellHorizontalTolerance = dwellHorizontalTolerance
        self.dwellHorizontalSpeedLimit = dwellHorizontalSpeedLimit
        self.approachSampleDistance = approachSampleDistance
        self.lateralApproachRatio = lateralApproachRatio
        self.reopenCooldown = reopenCooldown
        self.buttonReleaseGrace = buttonReleaseGrace
        self.peekExitGrace = peekExitGrace
        self.peekKeepAliveInset = peekKeepAliveInset
        self.enabledInFullscreen = enabledInFullscreen
        self.enabled = enabled
        self.fullscreenCheckInterval = fullscreenCheckInterval
        self.pointerPollInterval = pointerPollInterval
    }
}

extension GestureTuning {
    /// Spelled out rather than synthesised: with both `init(from:)` and
    /// `encode(to:)` written by hand there is nothing left for the compiler to
    /// infer them from. The names are the settings file's keys, so a rename here
    /// is a rename of the operator's file.
    enum CodingKeys: String, CodingKey {
        case stripHeight
        case stripSideMargin
        case virtualAnchorWidth
        case pinnedEpsilon
        case edgePushDistance
        case edgePushWindow
        case dwellDuration
        case lateralApproachDwellDuration
        case dwellHorizontalTolerance
        case dwellHorizontalSpeedLimit
        case approachSampleDistance
        case lateralApproachRatio
        case reopenCooldown
        case buttonReleaseGrace
        case peekExitGrace
        case peekKeepAliveInset
        case enabledInFullscreen
        case enabled
        case fullscreenCheckInterval
        case pointerPollInterval
    }

    /// Tolerant decoding: a settings file written by an older build is missing
    /// keys that a newer build knows about, and those must fall back to the
    /// default rather than failing the whole file. A key present with the wrong
    /// type still throws — that is a real mistake worth surfacing.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = GestureTuning()
        self.init(
            stripHeight: try c.decodeIfPresent(CGFloat.self, forKey: .stripHeight) ?? d.stripHeight,
            stripSideMargin: try c.decodeIfPresent(CGFloat.self, forKey: .stripSideMargin) ?? d.stripSideMargin,
            virtualAnchorWidth: try c.decodeIfPresent(CGFloat.self, forKey: .virtualAnchorWidth) ?? d.virtualAnchorWidth,
            pinnedEpsilon: try c.decodeIfPresent(CGFloat.self, forKey: .pinnedEpsilon) ?? d.pinnedEpsilon,
            edgePushDistance: try c.decodeIfPresent(CGFloat.self, forKey: .edgePushDistance) ?? d.edgePushDistance,
            edgePushWindow: try c.decodeIfPresent(TimeInterval.self, forKey: .edgePushWindow) ?? d.edgePushWindow,
            dwellDuration: try c.decodeIfPresent(TimeInterval.self, forKey: .dwellDuration) ?? d.dwellDuration,
            lateralApproachDwellDuration: try c.decodeIfPresent(TimeInterval.self, forKey: .lateralApproachDwellDuration) ?? d.lateralApproachDwellDuration,
            dwellHorizontalTolerance: try c.decodeIfPresent(CGFloat.self, forKey: .dwellHorizontalTolerance) ?? d.dwellHorizontalTolerance,
            dwellHorizontalSpeedLimit: try c.decodeIfPresent(CGFloat.self, forKey: .dwellHorizontalSpeedLimit) ?? d.dwellHorizontalSpeedLimit,
            approachSampleDistance: try c.decodeIfPresent(CGFloat.self, forKey: .approachSampleDistance) ?? d.approachSampleDistance,
            lateralApproachRatio: try c.decodeIfPresent(CGFloat.self, forKey: .lateralApproachRatio) ?? d.lateralApproachRatio,
            reopenCooldown: try c.decodeIfPresent(TimeInterval.self, forKey: .reopenCooldown) ?? d.reopenCooldown,
            buttonReleaseGrace: try c.decodeIfPresent(TimeInterval.self, forKey: .buttonReleaseGrace) ?? d.buttonReleaseGrace,
            peekExitGrace: try c.decodeIfPresent(TimeInterval.self, forKey: .peekExitGrace) ?? d.peekExitGrace,
            peekKeepAliveInset: try c.decodeIfPresent(CGFloat.self, forKey: .peekKeepAliveInset) ?? d.peekKeepAliveInset,
            enabledInFullscreen: try c.decodeIfPresent(Bool.self, forKey: .enabledInFullscreen) ?? d.enabledInFullscreen,
            enabled: try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled,
            fullscreenCheckInterval: try c.decodeIfPresent(TimeInterval.self, forKey: .fullscreenCheckInterval) ?? d.fullscreenCheckInterval,
            pointerPollInterval: try c.decodeIfPresent(TimeInterval.self, forKey: .pointerPollInterval) ?? d.pointerPollInterval
        )
    }

    /// Sparse encoding: a value equal to the default is **not** written.
    ///
    /// The mirror image of the tolerant decoder above, and the reason it has to
    /// exist. Encoding every field froze the whole default set into the
    /// operator's settings file the first time anything was saved, and from
    /// then on no default the code ever changed could reach that install again.
    /// It was found the honest way: a reveal was retuned, shipped, and the
    /// operator saw no difference at all, because his file still held the
    /// numbers from before the fix.
    ///
    /// Leaving out what was never chosen means an untouched setting keeps
    /// following the code. The one thing it gives up is the difference between
    /// "deliberately set to exactly the default" and "never touched", and those
    /// two are indistinguishable in behaviour until the default moves — at
    /// which point adopting the new one is the better guess.
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        let d = GestureTuning()
        func put<T: Equatable & Encodable>(_ value: T, _ fallback: T, _ key: CodingKeys) throws {
            guard value != fallback else { return }
            try c.encode(value, forKey: key)
        }
        try put(stripHeight, d.stripHeight, .stripHeight)
        try put(stripSideMargin, d.stripSideMargin, .stripSideMargin)
        try put(virtualAnchorWidth, d.virtualAnchorWidth, .virtualAnchorWidth)
        try put(pinnedEpsilon, d.pinnedEpsilon, .pinnedEpsilon)
        try put(edgePushDistance, d.edgePushDistance, .edgePushDistance)
        try put(edgePushWindow, d.edgePushWindow, .edgePushWindow)
        try put(dwellDuration, d.dwellDuration, .dwellDuration)
        try put(lateralApproachDwellDuration, d.lateralApproachDwellDuration, .lateralApproachDwellDuration)
        try put(dwellHorizontalTolerance, d.dwellHorizontalTolerance, .dwellHorizontalTolerance)
        try put(dwellHorizontalSpeedLimit, d.dwellHorizontalSpeedLimit, .dwellHorizontalSpeedLimit)
        try put(approachSampleDistance, d.approachSampleDistance, .approachSampleDistance)
        try put(lateralApproachRatio, d.lateralApproachRatio, .lateralApproachRatio)
        try put(reopenCooldown, d.reopenCooldown, .reopenCooldown)
        try put(buttonReleaseGrace, d.buttonReleaseGrace, .buttonReleaseGrace)
        try put(peekExitGrace, d.peekExitGrace, .peekExitGrace)
        try put(peekKeepAliveInset, d.peekKeepAliveInset, .peekKeepAliveInset)
        try put(enabledInFullscreen, d.enabledInFullscreen, .enabledInFullscreen)
        try put(enabled, d.enabled, .enabled)
        try put(fullscreenCheckInterval, d.fullscreenCheckInterval, .fullscreenCheckInterval)
        try put(pointerPollInterval, d.pointerPollInterval, .pointerPollInterval)
    }
}
