import Foundation

/// What the panel's glass is tinted towards.
///
/// The system material takes the colour of whatever is behind it, which is what
/// makes it glass — and also what makes it disappear over a dark game and wash
/// out over a bright document. A tint does not close the glass: everything
/// behind still shows through. It gives the material something to be measured
/// from, so the panel is recognisably the same object on every background.
///
/// Which way to lean is a matter of taste and of what the operator has behind
/// their panel all day, so it is a setting rather than a constant.
public struct GlassTint: Codable, Equatable, Sendable {
    public var enabled: Bool

    /// Lighter than what is behind it, or darker.
    ///
    /// Light reads as frosted and stands out over dark backgrounds; dark keeps
    /// the panel darker than its surroundings, which is what the text and card
    /// colours were chosen for.
    public var isLight: Bool

    /// How far towards that colour, from 0 (no tint at all) to 1 (opaque).
    public var strength: Double

    public init(enabled: Bool = true, isLight: Bool = true, strength: Double = 0.16) {
        self.enabled = enabled
        self.isLight = isLight
        self.strength = strength
    }

    /// See `GestureTuning.init(from:)` — same tolerance, same reasoning.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = GlassTint()
        self.init(
            enabled: try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled,
            isLight: try c.decodeIfPresent(Bool.self, forKey: .isLight) ?? d.isLight,
            strength: try c.decodeIfPresent(Double.self, forKey: .strength) ?? d.strength
        )
    }

    /// The white level and alpha to build the colour from, or `nil` for glass
    /// left exactly as the system renders it.
    ///
    /// Returned as numbers rather than a colour because this target has no
    /// AppKit — the view that needs an `NSColor` is the one that can make one.
    public var components: (white: Double, alpha: Double)? {
        guard enabled, strength > 0 else { return nil }
        return (isLight ? 1 : 0, strength)
    }
}
