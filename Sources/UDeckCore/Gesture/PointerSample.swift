import CoreGraphics
import Foundation

/// One pointer movement, in the terms the recognizer needs.
public struct PointerSample: Equatable, Sendable {
    /// Where the cursor is, in AppKit global coordinates.
    ///
    /// Note that this clamps: once the cursor reaches the top edge, the position
    /// stops changing no matter how much further the device is moved.
    public let location: CGPoint

    /// How far the device moved since the previous event, in points, with
    /// `dx > 0` meaning rightward and `dy > 0` meaning **upward**.
    ///
    /// This does not clamp at the screen edge, which is precisely what makes it
    /// possible to tell "threw the cursor at the top edge and kept pushing"
    /// apart from "reached a menu-bar target and stopped". The platform's own
    /// sign convention is normalised in `UDeckKit`, not here.
    public let delta: CGVector

    /// Seconds on a monotonic clock. Never wall time: the recognizer measures
    /// durations, and wall time can jump.
    public let timestamp: TimeInterval

    public init(location: CGPoint, delta: CGVector, timestamp: TimeInterval) {
        self.location = location
        self.delta = delta
        self.timestamp = timestamp
    }
}

/// The parts of the world outside the cursor that decide whether the gesture is
/// even allowed to arm.
public struct GestureEnvironment: Equatable, Sendable {
    /// A mouse button is held. Suppresses everything: a drag to the top edge is
    /// a window being tiled, not a panel being summoned.
    public var buttonsDown: Bool

    /// A system menu is being tracked. Opening a panel underneath an open menu
    /// either steals the mouse or leaves the menu stranded.
    public var menuTrackingActive: Bool

    /// The frontmost window on the trigger screen is fullscreen. Fighting the
    /// system's own menu-bar reveal is how hover panels have been observed to
    /// leave the reveal permanently stuck.
    public var frontmostIsFullscreen: Bool

    /// The panel is already showing. There is nothing to reveal.
    public var panelVisible: Bool

    /// When a mouse button was last released inside the menu-bar row, if ever.
    public var lastMenuBarButtonUp: TimeInterval?

    /// When the panel was last dismissed, if ever.
    public var lastDismissal: TimeInterval?

    public init(
        buttonsDown: Bool = false,
        menuTrackingActive: Bool = false,
        frontmostIsFullscreen: Bool = false,
        panelVisible: Bool = false,
        lastMenuBarButtonUp: TimeInterval? = nil,
        lastDismissal: TimeInterval? = nil
    ) {
        self.buttonsDown = buttonsDown
        self.menuTrackingActive = menuTrackingActive
        self.frontmostIsFullscreen = frontmostIsFullscreen
        self.panelVisible = panelVisible
        self.lastMenuBarButtonUp = lastMenuBarButtonUp
        self.lastDismissal = lastDismissal
    }
}

/// What the recognizer made of the latest sample.
public enum GestureOutcome: Equatable, Sendable {
    /// Nothing is happening, and here is why — the reason exists so a
    /// calibration screen can show the operator which gate is stopping them.
    case idle(reason: IdleReason)

    /// The gesture is underway. `progress` runs 0…1 towards whichever path is
    /// closer to completing.
    case arming(progress: Double)

    /// Reveal the panel.
    case fire

    public enum IdleReason: String, Equatable, Sendable {
        case disabled
        case buttonDown
        case menuTracking
        case fullscreen
        case alreadyVisible
        case menuBarClickGrace
        case reopenCooldown
        case outsideStrip
        case alreadyFiredThisVisit
    }
}
