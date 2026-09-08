import Foundation

/// How the panel's glass is made.
///
/// The system material has exactly three things to say about itself — a style,
/// a tint and a corner radius — and none of them is "how much of it there is".
/// That turns out to matter: asked for a panel that is fully transparent, the
/// tint controls cannot deliver it, because a tint only ever *adds*. What does
/// deliver it is the view's own opacity, which fades the whole material towards
/// whatever is behind it and reaches nothing at all at zero.
///
/// So there are two knobs, and they do different things. Opacity decides how
/// much glass there is; the tint decides what colour the glass leans towards.
/// Both are settings because both are matters of taste and of what the operator
/// has behind their panel all day.
/// The two characters the system material comes in.
///
/// Not a slider: macOS offers exactly these, and the difference is optical
/// rather than a matter of degree. `regular` keeps what is behind it legible
/// and bends it towards the edges; `clear` diffuses it almost completely.
public enum GlassStyle: String, Codable, Sendable, CaseIterable {
    case regular
    case clear
}

public struct GlassAppearance: Codable, Equatable, Sendable {
    public var style: GlassStyle

    /// How much of the material there is, from 0 (nothing at all — the panel's
    /// content floats over whatever is behind it) to 1 (the material as the
    /// system renders it).
    public var opacity: Double

    public var tinted: Bool

    /// Lighter than what is behind it, or darker.
    ///
    /// Light reads as frosted and stands out over dark backgrounds; dark keeps
    /// the panel darker than its surroundings, which is what the text and card
    /// colours were chosen for.
    public var tintIsLight: Bool

    /// How far towards that colour, from 0 (no tint at all) to 1 (opaque).
    public var tintStrength: Double

    public init(
        style: GlassStyle = .regular,
        opacity: Double = 1,
        tinted: Bool = true,
        tintIsLight: Bool = true,
        tintStrength: Double = 0.16
    ) {
        self.style = style
        self.opacity = opacity
        self.tinted = tinted
        self.tintIsLight = tintIsLight
        self.tintStrength = tintStrength
    }

    /// See `GestureTuning.init(from:)` — same tolerance, same reasoning.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = GlassAppearance()
        self.init(
            // Read as a string and mapped, rather than decoded as the enum
            // directly: an unknown name would throw, and throwing here fails
            // the *whole* settings file. One misspelt style should not cost the
            // operator every other setting they have.
            style: (try c.decodeIfPresent(String.self, forKey: .style)).flatMap(GlassStyle.init(rawValue:)) ?? d.style,
            opacity: try c.decodeIfPresent(Double.self, forKey: .opacity) ?? d.opacity,
            tinted: try c.decodeIfPresent(Bool.self, forKey: .tinted) ?? d.tinted,
            tintIsLight: try c.decodeIfPresent(Bool.self, forKey: .tintIsLight) ?? d.tintIsLight,
            tintStrength: try c.decodeIfPresent(Double.self, forKey: .tintStrength) ?? d.tintStrength
        )
    }

    /// The white level and alpha to build the tint from, or `nil` for glass
    /// left exactly as the system colours it.
    ///
    /// Returned as numbers rather than a colour because this target has no
    /// AppKit — the view that needs an `NSColor` is the one that can make one.
    public var tintComponents: (white: Double, alpha: Double)? {
        guard tinted, tintStrength > 0 else { return nil }
        return (tintIsLight ? 1 : 0, tintStrength)
    }

    /// Ranges that keep both knobs meaning what they say.
    public func validated() -> GlassAppearance {
        var result = self
        func clamp(_ value: Double, _ range: ClosedRange<Double>, _ fallback: Double) -> Double {
            guard value.isFinite else { return fallback }
            return min(max(value, range.lowerBound), range.upperBound)
        }
        result.opacity = clamp(result.opacity, 0 ... 1, 1)
        result.tintStrength = clamp(result.tintStrength, 0 ... 0.9, 0.16)
        return result
    }
}
