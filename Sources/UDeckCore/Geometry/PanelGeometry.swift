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
    /// against it. The cursor can reach `frame.maxY` exactly, so this has to be
    /// a range rather than an equality.
    public func isPinnedToTopEdge(_ point: CGPoint) -> Bool {
        point.y >= screen.frame.maxY - 1 - tuning.pinnedEpsilon
    }

    /// Whether the cursor is inside a region of this screen.
    ///
    /// Not `CGRect.contains`, which is half-open at the top: a point whose `y`
    /// is exactly `maxY` is outside. That is the right rule for tiling
    /// rectangles and the wrong one for the cursor, because the cursor really
    /// does reach the top row of the screen — driving it there with
    /// `CGWarpMouseCursorPosition` lands it on `frame.maxY` exactly, not on
    /// `maxY - 1` as the code used to assume in three places.
    ///
    /// The consequence of the assumption was that the gesture died precisely
    /// where every gesture that matters ends: the trigger strip is flush with
    /// the top of the screen, so a cursor pushed all the way up fell outside it
    /// and the panel refused to open. The keep-alive region has its top pinned
    /// to the same edge, so the same cursor also read as having left the panel.
    ///
    /// Only the top edge is closed, and only when the region reaches the top of
    /// the screen. The sides stay half-open: horizontally adjacent screens share
    /// an edge, and both claiming a point there is a worse bug than neither.
    public func containsPointer(_ point: CGPoint, in rect: CGRect) -> Bool {
        guard point.x >= rect.minX, point.x < rect.maxX, point.y >= rect.minY else { return false }
        if rect.maxY >= screen.frame.maxY { return point.y <= rect.maxY }
        return point.y < rect.maxY
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

    /// The y coordinate the panel's top edge sits on: the top of the screen,
    /// plus `topEdgeBleed`.
    ///
    /// The bleed is there because the material draws an edge along the top of
    /// its own view and offers no way to decline. On a panel attached to the
    /// top of the display that edge is a bright rim across the top row.
    /// Pushing the window's top row off the display removes it at the source.
    ///
    /// This used to stop below the notch on a notched screen, on the reasoning
    /// that a panel drawn through opaque hardware would have a hole punched in
    /// its top. It does — the notch is that hole — but what it left behind was
    /// a band of menu bar above the panel, which the operator saw and called
    /// ugly, and he is right: the panel looked detached from the very thing it
    /// is supposed to grow out of. The hole is the notch, and the notch is the
    /// island; a bite taken out of the top edge by the machine itself reads as
    /// the panel belonging to the machine.
    public var panelHangY: CGFloat {
        screen.frame.maxY + metrics.topEdgeBleed
    }

    /// How far the panel reaches above the menu bar's lower edge: the whole of
    /// whatever is reserved at the top of that screen — a menu bar, a notch, or
    /// both — plus the bleed. Panel content is inset by this much so that the
    /// numbers in `PanelMetrics` keep meaning the height of the *content*, not
    /// of the window around it.
    public var topOverhang: CGFloat { panelHangY - screen.panelTopY }

    /// What the operator sees while the panel is away.
    ///
    /// Where there is no notch, this is the anchor: a drawn island filling the
    /// menu bar's height at the top centre, the same size as the real notch on
    /// the built-in display, and the shape the panel grows out of. It is bled
    /// past the top edge for the same reason the panel is; the visible part is
    /// still exactly the anchor.
    ///
    /// Where there *is* a notch, nothing is drawn at all. The island already
    /// exists in hardware and costs nothing to keep, and anything hung under it
    /// is a second protrusion below a screen cutout that was already doing the
    /// job — the operator's word for it was "доп выступ". The frame stays the
    /// notch itself, so the window has somewhere to be and nowhere to be seen:
    /// those points are behind the camera housing.
    public var collapsedFrame: CGRect {
        guard !screen.hasNotch else { return anchor }
        return CGRect(
            x: anchor.minX,
            y: anchor.minY,
            width: anchor.width,
            height: anchor.height + metrics.topEdgeBleed
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
    ///
    /// This is the one state that does not take the overhang. The hover states
    /// are a strip in the middle of the menu bar with the app menus and the
    /// status items still reachable either side of them; fullscreen is the
    /// whole width, and hiding the entire menu bar behind an application that
    /// covers the screen is how a utility becomes a trap.
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

    /// A panel of the given *content* size, hanging from the anchor, clamped so
    /// it never runs off the side of the screen.
    ///
    /// The window grows upward by the overhang rather than downward, so the
    /// panel stays attached to the island while every height in `PanelMetrics`
    /// keeps describing the room the content actually gets.
    private func hangingFrame(width: CGFloat, height: CGFloat) -> CGRect {
        let clampedWidth = min(width, screen.frame.width)
        var x = anchor.midX - clampedWidth / 2
        x = max(x, screen.frame.minX)
        x = min(x, screen.frame.maxX - clampedWidth)
        return CGRect(
            x: x,
            y: screen.panelTopY - height,
            width: clampedWidth,
            height: height + topOverhang
        )
    }
}
