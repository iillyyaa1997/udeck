import CoreGraphics
import Foundation

/// Where the panel and its activation strip sit on a given screen.
///
/// Every number here is derived at runtime from the screen and the operator's
/// tuning. Nothing is hard-coded for a particular display: the two screens on
/// the machine this was designed against differ in width, backing scale and
/// menu-bar height, and any constant would be wrong on one of them.
public struct PanelGeometry: Equatable, Sendable {
    public let screen: ScreenSnapshot
    public let tuning: GestureTuning
    public let metrics: PanelMetrics

    public init(screen: ScreenSnapshot, tuning: GestureTuning, metrics: PanelMetrics) {
        self.screen = screen
        self.tuning = tuning
        self.metrics = metrics
    }

    /// The anchor the panel grows out of: the real notch when the screen has
    /// one, otherwise a virtual notch of the same size at the top centre.
    ///
    /// The notch is an anchor, never the trigger. On a docked setup the notched
    /// display is usually not the one the cursor is on, so binding the gesture
    /// to the physical notch would make it unreachable most of the time.
    public var anchor: CGRect {
        if let notch = screen.notchRect { return notch }
        let width = tuning.virtualAnchorWidth
        return CGRect(
            x: screen.frame.midX - width / 2,
            y: screen.frame.maxY - screen.topInset,
            width: width,
            height: screen.topInset
        )
    }

    /// The band the cursor has to be inside for the gesture to arm.
    ///
    /// Short (a few points from the very top edge) rather than the full menu-bar
    /// height, because every gesture that matters — deliberate or accidental —
    /// ends with the cursor pinned against the top edge. Making it taller only
    /// adds false positives.
    public var triggerStrip: CGRect {
        let x = anchor.minX - tuning.stripSideMargin
        let width = anchor.width + tuning.stripSideMargin * 2
        let clampedX = max(x, screen.frame.minX)
        let clampedWidth = min(width, screen.frame.maxX - clampedX)
        return CGRect(
            x: clampedX,
            y: screen.frame.maxY - tuning.stripHeight,
            width: clampedWidth,
            height: tuning.stripHeight
        )
    }

    /// True when the cursor is close enough to the top edge to count as pinned
    /// against it. macOS clamps the cursor at `maxY - 1`.
    public func isPinnedToTopEdge(_ point: CGPoint) -> Bool {
        point.y >= screen.frame.maxY - 1 - tuning.pinnedEpsilon
    }

    /// The panel's frame in a given state.
    public func frame(for phase: PanelPhase) -> CGRect {
        switch phase {
        case .collapsed: collapsedFrame
        case .peek: peekFrame
        case .open: openFrame
        case .fullscreen: fullscreenFrame
        }
    }

    /// A thin pill hanging under the anchor. It is what the operator sees while
    /// the panel is away, and the surface the reveal animation grows from.
    public var collapsedFrame: CGRect {
        let width = anchor.width * metrics.pillWidthFactor
        return CGRect(
            x: anchor.midX - width / 2,
            y: screen.panelTopY - metrics.pillHeight,
            width: width,
            height: metrics.pillHeight
        )
    }

    public var peekFrame: CGRect {
        hangingFrame(
            width: min(screen.frame.width * metrics.peekWidthFraction, metrics.peekMaxWidth),
            height: metrics.peekHeight
        )
    }

    public var openFrame: CGRect {
        let usableHeight = screen.panelTopY - screen.visibleFrame.minY
        return hangingFrame(
            width: min(screen.frame.width * metrics.openWidthFraction, metrics.openMaxWidth),
            height: min(usableHeight * metrics.openHeightFraction, metrics.openMaxHeight)
        )
    }

    /// Fullscreen means "the whole working area", not "the whole display": it
    /// stops below the menu bar and above the Dock. Covering either would make
    /// the panel impossible to escape from without a keyboard.
    public var fullscreenFrame: CGRect {
        CGRect(
            x: screen.visibleFrame.minX,
            y: screen.visibleFrame.minY,
            width: screen.visibleFrame.width,
            height: screen.panelTopY - screen.visibleFrame.minY
        )
    }

    /// The region that keeps a peek alive.
    ///
    /// Two things are deliberate here, and both were bugs first.
    ///
    /// It is built from the panel's frame rather than from the trigger strip.
    /// Using the strip is what makes hover panels oscillate: the panel opens,
    /// the cursor is now inside the panel but outside the strip, so it closes,
    /// which puts the cursor back in the strip, so it opens again.
    ///
    /// And it reaches all the way up to the top of the screen. The panel hangs
    /// *below* the menu bar, but the gesture that opened it left the cursor
    /// *in* the menu bar — so a region that stopped at the panel's own top edge
    /// would consider the cursor to have left before it ever arrived, and the
    /// panel would close the instant it opened. The band above the panel is the
    /// corridor the cursor travels down; it belongs to the panel.
    public func keepAliveRegion(for phase: PanelPhase) -> CGRect {
        let inflated = frame(for: phase).insetBy(dx: -tuning.peekKeepAliveInset, dy: -tuning.peekKeepAliveInset)
        let top = max(inflated.maxY, screen.frame.maxY)
        return CGRect(
            x: inflated.minX,
            y: inflated.minY,
            width: inflated.width,
            height: top - inflated.minY
        )
    }

    /// A panel of the given size, hanging from the anchor, clamped so it never
    /// runs off the side of the screen.
    private func hangingFrame(width: CGFloat, height: CGFloat) -> CGRect {
        let clampedWidth = min(width, screen.frame.width)
        var x = anchor.midX - clampedWidth / 2
        x = max(x, screen.frame.minX)
        x = min(x, screen.frame.maxX - clampedWidth)
        return CGRect(x: x, y: screen.panelTopY - height, width: clampedWidth, height: height)
    }
}
