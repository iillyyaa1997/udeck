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
    /// would be sized for exactly that — a peek with a lot of empty space in it
    /// reads as something that failed to load. It is taller than that, and the
    /// reason is the material rather than the layout: see `glassTintFloor`.
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

    /// How far the island hangs into the screen, as a fraction of the space
    /// reserved at the top of it.
    ///
    /// Half. It started as a special case for fullscreen applications — a
    /// full-depth slab across the top of a game is an interruption — and the
    /// operator asked for it everywhere, which is the better answer: the island
    /// is a mark, and a mark does not need the whole menu bar's depth to be
    /// read. It also retired the machinery that watched every screen for a
    /// fullscreen window.
    ///
    /// The width is deliberately left alone: the island is the shape the panel
    /// grows out of, and one that changed width as well would have to grow back
    /// out again from somewhere else.
    public var islandHeightFactor: CGFloat

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

    /// The content is sequenced behind the frame: it starts once the panel is
    /// most of the way to its final size, and it leaves faster than it arrives.
    ///
    /// It used to start at 80 ms, which is about when the spring is halfway,
    /// and finish at 300 ms — while the shape was still moving. The operator
    /// saw it as the text arriving before the panel did, and he is right: text
    /// at full strength inside a box that is still growing reads as text
    /// overflowing a small panel rather than as a panel filling up.
    ///
    /// The spring passes 95% of its travel at about 228 ms with the default
    /// response, so the content now starts at 160 and lands at 340 — just after
    /// the shape does.
    public var contentRevealDelay: TimeInterval
    public var contentRevealDuration: TimeInterval
    public var contentHideDuration: TimeInterval

    public init(
        peekWidthFraction: CGFloat = 0.42,
        peekMaxWidth: CGFloat = 820,
        peekHeight: CGFloat = 150,
        openWidthFraction: CGFloat = 0.46,
        openMaxWidth: CGFloat = 1100,
        openHeightFraction: CGFloat = 0.62,
        openMaxHeight: CGFloat = 760,
        cornerRadius: CGFloat = 18,
        topEdgeBleed: CGFloat = 2,
        islandHeightFactor: CGFloat = 0.5,
        islandCornerRadius: CGFloat = 12,
        revealSpringResponse: TimeInterval = 0.42,
        revealSpringDamping: Double = 0.8,
        collapseDuration: TimeInterval = 0.3,
        contentRevealDelay: TimeInterval = 0.16,
        contentRevealDuration: TimeInterval = 0.18,
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
        self.islandHeightFactor = islandHeightFactor
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
    /// The height below which the system's glass stops taking its tint.
    ///
    /// Measured, not looked up. The operator said the panel was one colour on
    /// hover and another on click, and both earlier explanations — the menu
    /// bar's backdrop showing through the top strip, and the wallpaper being
    /// brighter under the taller panel — were wrong: a screenshot of the real
    /// panel put the desktop behind the open panel at 27/255 and the open panel
    /// itself at 184, while the peek sat at 58 over a desktop of 64. The tint
    /// was reaching one and not the other.
    ///
    /// What separates them is height alone. The same peek, in the same state
    /// with the same settings, was measured at every height in between:
    ///
    ///     panel height   glass
    ///     130 pt          58
    ///     164 pt          32
    ///     174 pt         184
    ///     194 pt         184
    ///     707 pt (open)  183
    ///
    /// So there is a cliff between 164 and 174 points, and everything above it
    /// renders identically. The rule belongs to `NSGlassEffectView` and is not
    /// documented; what is ours is the consequence — a peek shorter than this
    /// is a different colour from the panel it grows into.
    ///
    /// This is the panel's whole height, the overhang into the menu-bar row
    /// included, because that is what the glass view is given.
    public static let glassTintFloor: CGFloat = 174

    /// When the reveal spring has visibly arrived, in seconds.
    ///
    /// A spring has no duration — it has a tail that runs on long after the eye
    /// has stopped following it — so "how long does the panel take to open" is
    /// the time it crosses most of its travel, not the time it stops moving.
    /// The content is sequenced against this number, and getting the two out of
    /// step is what made the text arrive before the panel it was written on.
    public var revealPerceivedDuration: TimeInterval {
        let omega = 2 * Double.pi / max(revealSpringResponse, 0.001)
        let zeta = min(max(revealSpringDamping, 0.001), 1)
        let step = 0.002
        var t = 0.0
        while t < 5 {
            let value: Double
            if zeta < 1 {
                let damped = omega * (1 - zeta * zeta).squareRoot()
                value = 1 - exp(-zeta * omega * t)
                    * (cos(damped * t) + (zeta * omega / damped) * sin(damped * t))
            } else {
                value = 1 - exp(-omega * t) * (1 + omega * t)
            }
            if value >= 0.95 { return t }
            t += step
        }
        return t
    }

    /// When the content has finished arriving, in seconds.
    public var contentArrivalDuration: TimeInterval {
        contentRevealDelay + contentRevealDuration
    }

    /// Spelled out rather than synthesised: with both `init(from:)` and
    /// `encode(to:)` written by hand there is nothing left for the compiler to
    /// infer them from. The names are the settings file's keys, so a rename here
    /// is a rename of the operator's file.
    enum CodingKeys: String, CodingKey {
        case peekWidthFraction
        case peekMaxWidth
        case peekHeight
        case openWidthFraction
        case openMaxWidth
        case openHeightFraction
        case openMaxHeight
        case cornerRadius
        case topEdgeBleed
        case islandHeightFactor
        case islandCornerRadius
        case revealSpringResponse
        case revealSpringDamping
        case collapseDuration
        case contentRevealDelay
        case contentRevealDuration
        case contentHideDuration
    }

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
            islandHeightFactor: try c.decodeIfPresent(CGFloat.self, forKey: .islandHeightFactor) ?? d.islandHeightFactor,
            islandCornerRadius: try c.decodeIfPresent(CGFloat.self, forKey: .islandCornerRadius) ?? d.islandCornerRadius,
            revealSpringResponse: try c.decodeIfPresent(TimeInterval.self, forKey: .revealSpringResponse) ?? d.revealSpringResponse,
            revealSpringDamping: try c.decodeIfPresent(Double.self, forKey: .revealSpringDamping) ?? d.revealSpringDamping,
            collapseDuration: try c.decodeIfPresent(TimeInterval.self, forKey: .collapseDuration) ?? d.collapseDuration,
            contentRevealDelay: try c.decodeIfPresent(TimeInterval.self, forKey: .contentRevealDelay) ?? d.contentRevealDelay,
            contentRevealDuration: try c.decodeIfPresent(TimeInterval.self, forKey: .contentRevealDuration) ?? d.contentRevealDuration,
            contentHideDuration: try c.decodeIfPresent(TimeInterval.self, forKey: .contentHideDuration) ?? d.contentHideDuration
        )
    }

    /// Sparse encoding: a value equal to the default is **not** written.
    /// See `GestureTuning.encode(to:)` — same rule, same reason, and this is the
    /// struct the reason was found in.
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        let d = PanelMetrics()
        func put<T: Equatable & Encodable>(_ value: T, _ fallback: T, _ key: CodingKeys) throws {
            guard value != fallback else { return }
            try c.encode(value, forKey: key)
        }
        try put(peekWidthFraction, d.peekWidthFraction, .peekWidthFraction)
        try put(peekMaxWidth, d.peekMaxWidth, .peekMaxWidth)
        try put(peekHeight, d.peekHeight, .peekHeight)
        try put(openWidthFraction, d.openWidthFraction, .openWidthFraction)
        try put(openMaxWidth, d.openMaxWidth, .openMaxWidth)
        try put(openHeightFraction, d.openHeightFraction, .openHeightFraction)
        try put(openMaxHeight, d.openMaxHeight, .openMaxHeight)
        try put(cornerRadius, d.cornerRadius, .cornerRadius)
        try put(topEdgeBleed, d.topEdgeBleed, .topEdgeBleed)
        try put(islandHeightFactor, d.islandHeightFactor, .islandHeightFactor)
        try put(islandCornerRadius, d.islandCornerRadius, .islandCornerRadius)
        try put(revealSpringResponse, d.revealSpringResponse, .revealSpringResponse)
        try put(revealSpringDamping, d.revealSpringDamping, .revealSpringDamping)
        try put(collapseDuration, d.collapseDuration, .collapseDuration)
        try put(contentRevealDelay, d.contentRevealDelay, .contentRevealDelay)
        try put(contentRevealDuration, d.contentRevealDuration, .contentRevealDuration)
        try put(contentHideDuration, d.contentHideDuration, .contentHideDuration)
    }
}
