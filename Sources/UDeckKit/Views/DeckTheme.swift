import AppKit
import SwiftUI
import UDeckCore

/// The look, as SwiftUI needs it.
///
/// Everything about *what colour* is decided in `Palette`, in UDeckCore, where
/// it can be tested without a window. This type adds only the two things a
/// palette cannot hold: the conversion to `Color`, and the metrics that follow
/// from the density setting.
///
/// Nothing here thins, tints or picks a colour. When something on screen needs
/// a shade that is not in the palette, the palette gains an entry — a view that
/// works one out for itself is a second place the look is decided, and the
/// panel spent a long time with twelve of those.
public struct DeckTheme: Sendable {
    public var density: Density

    /// How big the panel's text is, in points.
    ///
    /// Independent of the density, which now owns only the spacings. Everything
    /// else about type is derived from this one number, so there is one place
    /// that decides how big the panel reads — the same rule the colours follow.
    public var textSize: CGFloat

    /// Which way the text is written. Everything drawn *on* the panel takes its
    /// colour from this, so that one setting flips all of it together rather
    /// than leaving half the panel unreadable.
    public var ink: PanelInk

    /// Every colour, worked out once from the look.
    public let palette: Palette

    public init(density: Density, ink: PanelInk = .light, textSize: CGFloat? = nil) {
        self.init(density: density,
                  look: PanelLook(glass: GlassAppearance(), ink: ink),
                  textSize: textSize)
    }

    public init(density: Density, look: PanelLook, textSize: CGFloat? = nil) {
        self.density = density
        self.textSize = textSize ?? density.bodyFontSize
        self.ink = look.ink
        self.palette = Palette(look: look)
    }

    /// How far the type has been taken from what the density would have picked.
    ///
    /// Sizes that are not the body size — the title, and the height of a grid
    /// row — are scaled by this rather than offset by a constant, so that at
    /// rest they land exactly on the numbers the density has always given and
    /// the panel is unchanged for anyone who never touches the slider.
    private var typeScale: CGFloat { textSize / density.bodyFontSize }

    // MARK: - Surfaces

    public var panelTint: Color { Color(palette.panelTint) }
    public var windowFill: Color { Color(palette.windowFill) }
    public var recess: Color { Color(palette.recess) }
    public var selection: Color { Color(palette.selection) }
    public var subtleFill: Color { Color(palette.subtleFill) }
    public var line: Color { Color(palette.line) }
    public var panelBorder: Color { Color(palette.panelBorder) }
    public var innerHighlight: Color { Color(palette.innerHighlight) }

    /// A control under the pointer, and the same control being pressed.
    public func hoverFill(pressed: Bool) -> Color {
        Color(pressed ? palette.hoverPressed : palette.hover)
    }

    // MARK: - Text

    public var text: Color { Color(palette.text) }
    public var muted: Color { Color(palette.muted) }
    public var dim: Color { Color(palette.dim) }

    // MARK: - State

    public var accent: Color { Color(palette.accent) }
    public var ok: Color { Color(palette.ok) }
    public var warn: Color { Color(palette.warn) }
    public var crit: Color { Color(palette.crit) }

    public func color(for state: CardState) -> Color { Color(palette.color(for: state)) }
    public func color(for icon: CardIcon) -> Color { Color(palette.color(for: icon)) }

    // MARK: - Marks

    public var sparkline: Color { Color(palette.sparkline) }
    public var islandHalo: Color { Color(palette.islandHalo) }

    public func grip(hovering: Bool) -> Color {
        Color(hovering ? palette.gripHover : palette.grip)
    }

    /// The capsule behind a card's chip.
    public func chipFill(for state: CardState) -> Color {
        Color(palette.chipFill(for: state))
    }

    /// The island's indicator bar.
    public func islandMark(for state: CardState, placed: Bool) -> Color {
        Color(palette.islandMark(for: state, placed: placed))
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
    /// The larger of what the density asks for and what the text needs.
    ///
    /// A row that kept the density's height while the type grew would cut the
    /// second line off a card rather than admit it did not fit, and clipped
    /// text is a bug wherever it appears. Cards get taller instead, and the
    /// layout visibly moves when the size does — which is the honest answer.
    public var gridRowHeight: CGFloat { density.gridRowHeight * max(1, typeScale) }
    public var bodyFont: Font { .system(size: textSize) }
    public var monoFont: Font { .system(size: textSize - 0.5, design: .monospaced) }
    public var titleFont: Font { .system(size: density.titleFontSize * typeScale, weight: .semibold) }
    public var chipFont: Font { .system(size: textSize - 2, design: .monospaced) }
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

public extension Color {
    /// A palette entry as SwiftUI sees it. The only bridge between the two, so
    /// that a colour cannot reach the screen without having come from the table.
    init(_ palette: PaletteColor) {
        self.init(
            .sRGB,
            red: palette.ink.red,
            green: palette.ink.green,
            blue: palette.ink.blue,
            opacity: palette.alpha
        )
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
