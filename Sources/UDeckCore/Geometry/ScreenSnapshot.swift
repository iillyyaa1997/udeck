import CoreGraphics
import Foundation

/// A screen, reduced to the facts uDeck's geometry needs.
///
/// AppKit's `NSScreen` is deliberately kept out of `UDeckCore` so that every
/// geometry decision — which is where this project's real risk lives — can be
/// tested against fabricated screens without a window server. `UDeckKit` builds
/// these from `NSScreen`.
///
/// Coordinates are AppKit's global space: origin bottom-left, `y` increasing
/// upward, the main screen anchored at `(0, 0)`.
public struct ScreenSnapshot: Equatable, Sendable, Identifiable {
    /// Stable across a re-enumeration of screens; `NSScreen` has no such id of
    /// its own before macOS 26, so `UDeckKit` derives it from the display id.
    public let id: String
    public let name: String
    public let frame: CGRect
    public let visibleFrame: CGRect
    public let backingScale: CGFloat

    /// `NSScreen.safeAreaInsets.top` — non-zero exactly when the display has a
    /// notch (or another top obstruction the system knows about).
    public let safeAreaTop: CGFloat

    /// `NSScreen.auxiliaryTopLeftArea` — the unobscured wing left of the notch.
    public let auxiliaryTopLeft: CGRect?

    /// `NSScreen.auxiliaryTopRightArea` — the unobscured wing right of the notch.
    public let auxiliaryTopRight: CGRect?

    public init(
        id: String,
        name: String,
        frame: CGRect,
        visibleFrame: CGRect,
        backingScale: CGFloat,
        safeAreaTop: CGFloat,
        auxiliaryTopLeft: CGRect?,
        auxiliaryTopRight: CGRect?
    ) {
        self.id = id
        self.name = name
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.backingScale = backingScale
        self.safeAreaTop = safeAreaTop
        self.auxiliaryTopLeft = auxiliaryTopLeft
        self.auxiliaryTopRight = auxiliaryTopRight
    }

    /// True when the two auxiliary areas describe a real gap between them.
    public var hasNotch: Bool { notchRect != nil }

    /// The notch itself: the gap between the two unobscured wings.
    ///
    /// Derived rather than assumed, because the wings are what the system
    /// actually reports; the notch is the space they leave. A display can report
    /// a `safeAreaTop` without wings (an obstruction that is not a notch), and
    /// in that case there is no notch rect to anchor to.
    public var notchRect: CGRect? {
        guard let left = auxiliaryTopLeft, let right = auxiliaryTopRight else { return nil }
        let width = right.minX - left.maxX
        guard width > 0 else { return nil }
        return CGRect(x: left.maxX, y: frame.maxY - safeAreaTop, width: width, height: safeAreaTop)
    }

    /// Vertical space at the top of the screen that the panel must not cover:
    /// the menu bar, or the notch, whichever reaches further down.
    ///
    /// The panel hangs *below* this. Drawing over the menu bar is technically
    /// possible at this window level and deliberately not done — a utility that
    /// covers the menu bar is a utility that gets uninstalled.
    public var topInset: CGFloat {
        max(safeAreaTop, frame.maxY - visibleFrame.maxY)
    }

    /// The y coordinate the panel hangs from.
    public var panelTopY: CGFloat { frame.maxY - topInset }

    /// Does this screen contain the given point? Uses a half-open rule on the
    /// far edges so that two adjacent screens never both claim the same point.
    public func contains(_ point: CGPoint) -> Bool {
        point.x >= frame.minX && point.x < frame.maxX
            && point.y >= frame.minY && point.y < frame.maxY
    }
}

extension Array where Element == ScreenSnapshot {
    /// The screen the cursor is on.
    ///
    /// A cursor pinned against the top edge sits at `maxY - 1`, so it is still
    /// inside the frame — but display arrangements can leave gaps, and a point
    /// in a gap belongs to nobody. Falling back to the nearest screen keeps the
    /// gesture responsive instead of silently doing nothing.
    public func screen(containing point: CGPoint) -> ScreenSnapshot? {
        if let hit = first(where: { $0.contains(point) }) { return hit }
        return self.min(by: { $0.frame.squaredDistance(to: point) < $1.frame.squaredDistance(to: point) })
    }
}

extension CGRect {
    /// Squared distance from a point to this rect; zero when inside.
    func squaredDistance(to point: CGPoint) -> CGFloat {
        let dx = max(minX - point.x, 0, point.x - maxX)
        let dy = max(minY - point.y, 0, point.y - maxY)
        return dx * dx + dy * dy
    }
}
