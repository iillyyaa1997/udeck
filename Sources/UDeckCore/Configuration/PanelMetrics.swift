import CoreGraphics
import Foundation

/// The panel's size in each of its states.
///
/// Widths and heights are expressed both as a fraction of the screen and as a
/// hard cap, and the smaller wins. The fraction keeps the panel proportionate on
/// a 1728pt laptop screen and a 2560pt external one; the cap stops it from
/// growing so wide that it no longer reads as attached to the top edge.
public struct PanelMetrics: Codable, Equatable, Sendable {
    /// Height of the collapsed pill hanging under the anchor.
    public var pillHeight: CGFloat

    /// Width of the collapsed pill, as a fraction of the anchor width.
    public var pillWidthFactor: CGFloat

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

    /// Corner radius of the collapsed island's bottom corners.
    ///
    /// Smaller than the panel's, because the island is smaller: one radius for
    /// both would either look blunt at 185 points wide or swallow the whole lip
    /// under a notch.
    public var islandCornerRadius: CGFloat

    /// Duration of the drop-down and retract animation.
    public var revealDuration: TimeInterval

    public init(
        pillHeight: CGFloat = 6,
        pillWidthFactor: CGFloat = 0.62,
        peekWidthFraction: CGFloat = 0.42,
        peekMaxWidth: CGFloat = 820,
        peekHeight: CGFloat = 96,
        openWidthFraction: CGFloat = 0.46,
        openMaxWidth: CGFloat = 1100,
        openHeightFraction: CGFloat = 0.62,
        openMaxHeight: CGFloat = 760,
        cornerRadius: CGFloat = 18,
        islandCornerRadius: CGFloat = 12,
        revealDuration: TimeInterval = 0.4
    ) {
        self.pillHeight = pillHeight
        self.pillWidthFactor = pillWidthFactor
        self.peekWidthFraction = peekWidthFraction
        self.peekMaxWidth = peekMaxWidth
        self.peekHeight = peekHeight
        self.openWidthFraction = openWidthFraction
        self.openMaxWidth = openMaxWidth
        self.openHeightFraction = openHeightFraction
        self.openMaxHeight = openMaxHeight
        self.cornerRadius = cornerRadius
        self.islandCornerRadius = islandCornerRadius
        self.revealDuration = revealDuration
    }
}

extension PanelMetrics {
    /// See `GestureTuning.init(from:)` — same tolerance, same reasoning.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = PanelMetrics()
        self.init(
            pillHeight: try c.decodeIfPresent(CGFloat.self, forKey: .pillHeight) ?? d.pillHeight,
            pillWidthFactor: try c.decodeIfPresent(CGFloat.self, forKey: .pillWidthFactor) ?? d.pillWidthFactor,
            peekWidthFraction: try c.decodeIfPresent(CGFloat.self, forKey: .peekWidthFraction) ?? d.peekWidthFraction,
            peekMaxWidth: try c.decodeIfPresent(CGFloat.self, forKey: .peekMaxWidth) ?? d.peekMaxWidth,
            peekHeight: try c.decodeIfPresent(CGFloat.self, forKey: .peekHeight) ?? d.peekHeight,
            openWidthFraction: try c.decodeIfPresent(CGFloat.self, forKey: .openWidthFraction) ?? d.openWidthFraction,
            openMaxWidth: try c.decodeIfPresent(CGFloat.self, forKey: .openMaxWidth) ?? d.openMaxWidth,
            openHeightFraction: try c.decodeIfPresent(CGFloat.self, forKey: .openHeightFraction) ?? d.openHeightFraction,
            openMaxHeight: try c.decodeIfPresent(CGFloat.self, forKey: .openMaxHeight) ?? d.openMaxHeight,
            cornerRadius: try c.decodeIfPresent(CGFloat.self, forKey: .cornerRadius) ?? d.cornerRadius,
            islandCornerRadius: try c.decodeIfPresent(CGFloat.self, forKey: .islandCornerRadius) ?? d.islandCornerRadius,
            revealDuration: try c.decodeIfPresent(TimeInterval.self, forKey: .revealDuration) ?? d.revealDuration
        )
    }
}
