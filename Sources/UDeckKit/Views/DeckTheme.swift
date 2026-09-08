import AppKit
import SwiftUI
import UDeckCore

/// The glass look, in one place.
///
/// uDeck draws one deliberate appearance rather than following the system's
/// light and dark modes. The panel hangs over whatever the operator happens to
/// have on screen — a bright browser, a dark terminal, a photo wallpaper — so
/// its legibility cannot depend on any of them. A translucent dark surface with
/// its own defined edge reads against all three; a surface that inverted with
/// the system would read against half of them.
public struct DeckTheme: Sendable {
    public var density: Density

    /// Which way the text is written. Everything drawn *on* the panel takes its
    /// colour from this, so that one setting flips all of it together rather
    /// than leaving half the panel unreadable.
    public var ink: PanelInk

    /// The whole of the ink: direction, how far it goes, and whether it is grey.
    ///
    /// The direction still decides everything derived — hairlines, recesses,
    /// which set of state colours reads — because those follow from whether the
    /// panel is dark or bright, not from the shade the text happens to be.
    private let inkColour: InkColor

    public init(density: Density, ink: PanelInk = .light) {
        self.init(density: density, look: PanelLook(glass: GlassAppearance(), ink: ink))
    }

    public init(density: Density, look: PanelLook) {
        self.density = density
        self.ink = look.ink
        self.inkColour = look.foreground
    }

    private var isLightInk: Bool { ink == .light }

    /// The colour text is written in, and the colour the panel's own lines are
    /// drawn in — they have to move together, or a light panel keeps hairlines
    /// meant for a dark one.
    ///
    /// Worked out in `PanelLook.foreground`, where it can be checked without a
    /// view. At full brightness and no colour it is exactly what it always was:
    /// white, or the near-black light ink is the opposite of.
    private var foreground: Color {
        Color(red: inkColour.red, green: inkColour.green, blue: inkColour.blue)
    }

    // Surfaces
    public let panelTint = Color(red: 0.078, green: 0.102, blue: 0.149).opacity(0.62)
    public var windowFill: Color { foreground.opacity(0.07) }

    /// A sunken area — a text field, a slot waiting to be filled.
    ///
    /// Follows the ink like everything else here. It was flat black at 28%,
    /// which is a recess on a dark panel and a hole punched in a light one.
    public var recess: Color { foreground.opacity(isLightInk ? 0.28 : 0.10) }

    /// The tab that is showing, and anything else marked as chosen.
    public var selection: Color { foreground.opacity(isLightInk ? 0.14 : 0.10) }

    /// The faintest surface that is still a surface.
    public var subtleFill: Color { foreground.opacity(isLightInk ? 0.06 : 0.05) }

    /// A control under the pointer, and the same control being pressed.
    public func hoverFill(pressed: Bool) -> Color {
        foreground.opacity(pressed ? (isLightInk ? 0.12 : 0.14) : (isLightInk ? 0.05 : 0.06))
    }
    public var line: Color { foreground.opacity(isLightInk ? 0.11 : 0.16) }
    public var panelBorder: Color { foreground.opacity(isLightInk ? 0.14 : 0.20) }

    public let innerHighlight = Color.white.opacity(0.16)

    // Text
    public var text: Color { foreground }
    public var muted: Color { foreground.opacity(isLightInk ? 0.58 : 0.66) }
    public var dim: Color { foreground.opacity(isLightInk ? 0.40 : 0.50) }

    // State
    /// State colours are picked twice: the pale versions read on a dark panel
    /// and vanish on a light one, so the dark-ink set is deeper.
    public var accent: Color { isLightInk ? Color(red: 0.561, green: 0.780, blue: 1.0) : Color(red: 0.10, green: 0.36, blue: 0.62) }
    public var ok: Color { isLightInk ? Color(red: 0.435, green: 0.827, blue: 0.639) : Color(red: 0.09, green: 0.45, blue: 0.28) }
    public var warn: Color { isLightInk ? Color(red: 0.949, green: 0.776, blue: 0.541) : Color(red: 0.55, green: 0.36, blue: 0.05) }
    public var crit: Color { isLightInk ? Color(red: 1.0, green: 0.604, blue: 0.604) : Color(red: 0.63, green: 0.13, blue: 0.13) }

    public func color(for state: CardState) -> Color {
        switch state {
        case .ok: ok
        case .warn: warn
        case .crit: crit
        case .unknown: dim
        }
    }

    public func color(for icon: CardIcon) -> Color {
        switch icon {
        case .ok, .done: ok
        case .warn, .pause: warn
        case .crit: crit
        case .wait: warn
        case .run: accent
        case .idle, .dot: dim
        case .info: muted
        }
    }

    /// SF Symbol names for the closed icon vocabulary. Closed on purpose: an
    /// open-ended icon name would let one plugin dress itself up as a different
    /// application inside the panel.
    public func symbol(for icon: CardIcon) -> String {
        switch icon {
        case .ok: "checkmark.circle.fill"
        case .warn: "exclamationmark.triangle.fill"
        case .crit: "xmark.octagon.fill"
        case .wait: "hourglass"
        case .run: "play.fill"
        case .idle: "moon.zzz"
        case .done: "checkmark"
        case .pause: "pause.fill"
        case .info: "info.circle"
        case .dot: "circle.fill"
        }
    }

    // Metrics, all derived from the density setting so that every plugin gets
    // the same three sizes for free and none has to implement them.
    public var panelPadding: CGFloat { density.panelPadding }
    public var gridSpacing: CGFloat { density.gridSpacing }
    public var windowPadding: CGFloat { density.windowPadding }
    public var rowSpacing: CGFloat { density.rowSpacing }
    public var gridRowHeight: CGFloat { density.gridRowHeight }
    public var bodyFont: Font { .system(size: density.bodyFontSize) }
    public var monoFont: Font { .system(size: density.bodyFontSize - 0.5, design: .monospaced) }
    public var titleFont: Font { .system(size: density.titleFontSize, weight: .semibold) }
    public var chipFont: Font { .system(size: density.bodyFontSize - 2, design: .monospaced) }
    public let windowCornerRadius: CGFloat = 13

    /// The bar inside the island, which is the whole of what the panel says
    /// while it is away.
    ///
    /// Bigger than it looks like it needs to be, because the island is made of
    /// glass and glass takes the colour of whatever is behind it — over a dark
    /// game the island itself all but disappears, and this is then the only
    /// thing left to find it by.
    public let islandIndicatorSize = CGSize(width: 56, height: 5)
}

private struct DeckThemeKey: EnvironmentKey {
    static let defaultValue = DeckTheme(density: .normal)
}

public extension EnvironmentValues {
    var deckTheme: DeckTheme {
        get { self[DeckThemeKey.self] }
        set { self[DeckThemeKey.self] = newValue }
    }
}

extension InkColor {
    /// A SwiftUI colour as three sRGB numbers, or `nil` when it has no such
    /// form — a named system colour that changes with the appearance is not a
    /// thing a settings file can hold, and guessing at one would store a value
    /// that means something different tomorrow.
    init?(_ color: Color) {
        guard let srgb = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        self.init(red: Double(srgb.redComponent),
                  green: Double(srgb.greenComponent),
                  blue: Double(srgb.blueComponent))
    }
}
