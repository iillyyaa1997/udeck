import CoreGraphics
import Foundation

/// The panel's size in each of its states.
///
/// Widths and heights are expressed both as a fraction of the screen and as a
/// hard cap, and the smaller wins. The fraction keeps the panel proportionate on
/// a 1728pt laptop screen and a 2560pt external one; the cap stops it from
/// growing so wide that it no longer reads as attached to the top edge.
public struct PanelMetrics: Codable, Equatable, Sendable {
    public var peekWidthFraction: CGFloat
    public var peekMaxWidth: CGFloat

    /// The peek shows a summary line and an invitation, and nothing else, so it
    /// is sized for exactly that. A peek with a lot of empty space in it reads
    /// as something that failed to load.
    public var peekHeight: CGFloat

    public var openWidthFraction: CGFloat
    public var openMaxWidth: CGFloat
    public var openHeightFraction: CGFloat
    public var openMaxHeight: CGFloat

    /// Corner radius of the panel's bottom corners. The top corners are square
    /// because the panel is attached to the edge it hangs from.
    public var cornerRadius: CGFloat

    /// How far the panel's window reaches *above* the top of the screen, on a
    /// screen it is welded to.
    ///
    /// The material draws its own edge along the top of its view, and on a
    /// panel attached to the top of the display that edge is a bright line
    /// across the top row — the thing that makes it read as a window near the
    /// corner rather than as part of the machine. Pushing the window's own top
    /// edge off the display is the only way to remove an edge the material
    /// draws for itself.
    public var topEdgeBleed: CGFloat

    /// How much of its height the island keeps while the frontmost application
    /// is filling the screen.
    ///
    /// A game or a film is the one time the operator is looking at the screen
    /// rather than working on it, and something hanging the full depth of a
    /// menu bar into it is an interruption. Half still reads as the island and
    /// still carries a colour, while protruding half as far.
    ///
    /// The width is deliberately left alone: the island is the shape the panel
    /// grows out of, and one that changed width as well would have to grow back
    /// out again from somewhere else.
    public var islandFullscreenHeightFactor: CGFloat

    /// Corner radius of the collapsed island's bottom corners.
    ///
    /// Smaller than the panel's, because the island is smaller: one radius for
    /// both would either look blunt at 185 points wide or swallow the whole lip
    /// under a notch.
    public var islandCornerRadius: CGFloat

    /// The spring the panel opens with: `response` is roughly how long it takes
    /// to arrive, `damping` how much it overshoots on the way.
    ///
    /// Arriving is allowed to overshoot a little — that is what reads as mass.
    /// Below about 0.7 the ringing becomes visible, which is fine on a glyph
    /// and costly under text, because the words move while they are being read.
    public var revealSpringResponse: TimeInterval
    public var revealSpringDamping: Double

    /// Closing does **not** use the spring.
    ///
    /// Opening and closing must not share a curve. A spring on the way out
    /// means the panel bounces back towards someone who has already dismissed
    /// it, which reads as the interface arguing with them.
    public var collapseDuration: TimeInterval

    /// The content is sequenced behind the frame: it starts after the panel has
    /// visibly begun to move, and it leaves faster than it arrives.
    public var contentRevealDelay: TimeInterval
    public var contentRevealDuration: TimeInterval
    public var contentHideDuration: TimeInterval

    public init(
        peekWidthFraction: CGFloat = 0.42,
        peekMaxWidth: CGFloat = 820,
        peekHeight: CGFloat = 96,
        openWidthFraction: CGFloat = 0.46,
        openMaxWidth: CGFloat = 1100,
        openHeightFraction: CGFloat = 0.62,
        openMaxHeight: CGFloat = 760,
        cornerRadius: CGFloat = 18,
        topEdgeBleed: CGFloat = 2,
        islandFullscreenHeightFactor: CGFloat = 0.5,
        islandCornerRadius: CGFloat = 12,
        revealSpringResponse: TimeInterval = 0.42,
        revealSpringDamping: Double = 0.8,
        collapseDuration: TimeInterval = 0.3,
        contentRevealDelay: TimeInterval = 0.08,
        contentRevealDuration: TimeInterval = 0.22,
        contentHideDuration: TimeInterval = 0.12
    ) {
        self.peekWidthFraction = peekWidthFraction
        self.peekMaxWidth = peekMaxWidth
        self.peekHeight = peekHeight
        self.openWidthFraction = openWidthFraction
        self.openMaxWidth = openMaxWidth
        self.openHeightFraction = openHeightFraction
        self.openMaxHeight = openMaxHeight
        self.cornerRadius = cornerRadius
        self.topEdgeBleed = topEdgeBleed
        self.islandFullscreenHeightFactor = islandFullscreenHeightFactor
        self.islandCornerRadius = islandCornerRadius
        self.revealSpringResponse = revealSpringResponse
        self.revealSpringDamping = revealSpringDamping
        self.collapseDuration = collapseDuration
        self.contentRevealDelay = contentRevealDelay
        self.contentRevealDuration = contentRevealDuration
        self.contentHideDuration = contentHideDuration
    }
}

extension PanelMetrics {
    /// See `GestureTuning.init(from:)` — same tolerance, same reasoning.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = PanelMetrics()
        self.init(
            peekWidthFraction: try c.decodeIfPresent(CGFloat.self, forKey: .peekWidthFraction) ?? d.peekWidthFraction,
            peekMaxWidth: try c.decodeIfPresent(CGFloat.self, forKey: .peekMaxWidth) ?? d.peekMaxWidth,
            peekHeight: try c.decodeIfPresent(CGFloat.self, forKey: .peekHeight) ?? d.peekHeight,
            openWidthFraction: try c.decodeIfPresent(CGFloat.self, forKey: .openWidthFraction) ?? d.openWidthFraction,
            openMaxWidth: try c.decodeIfPresent(CGFloat.self, forKey: .openMaxWidth) ?? d.openMaxWidth,
            openHeightFraction: try c.decodeIfPresent(CGFloat.self, forKey: .openHeightFraction) ?? d.openHeightFraction,
            openMaxHeight: try c.decodeIfPresent(CGFloat.self, forKey: .openMaxHeight) ?? d.openMaxHeight,
            cornerRadius: try c.decodeIfPresent(CGFloat.self, forKey: .cornerRadius) ?? d.cornerRadius,
            topEdgeBleed: try c.decodeIfPresent(CGFloat.self, forKey: .topEdgeBleed) ?? d.topEdgeBleed,
            islandFullscreenHeightFactor: try c.decodeIfPresent(CGFloat.self, forKey: .islandFullscreenHeightFactor) ?? d.islandFullscreenHeightFactor,
            islandCornerRadius: try c.decodeIfPresent(CGFloat.self, forKey: .islandCornerRadius) ?? d.islandCornerRadius,
            revealSpringResponse: try c.decodeIfPresent(TimeInterval.self, forKey: .revealSpringResponse) ?? d.revealSpringResponse,
            revealSpringDamping: try c.decodeIfPresent(Double.self, forKey: .revealSpringDamping) ?? d.revealSpringDamping,
            collapseDuration: try c.decodeIfPresent(TimeInterval.self, forKey: .collapseDuration) ?? d.collapseDuration,
            contentRevealDelay: try c.decodeIfPresent(TimeInterval.self, forKey: .contentRevealDelay) ?? d.contentRevealDelay,
            contentRevealDuration: try c.decodeIfPresent(TimeInterval.self, forKey: .contentRevealDuration) ?? d.contentRevealDuration,
            contentHideDuration: try c.decodeIfPresent(TimeInterval.self, forKey: .contentHideDuration) ?? d.contentHideDuration
        )
    }
}
