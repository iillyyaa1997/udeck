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

    public init(density: Density) {
        self.density = density
    }

    // Surfaces
    public let panelTint = Color(red: 0.078, green: 0.102, blue: 0.149).opacity(0.62)
    public let windowFill = Color.white.opacity(0.07)
    public let recess = Color.black.opacity(0.28)
    public let line = Color.white.opacity(0.11)
    public let panelBorder = Color.white.opacity(0.14)
    public let innerHighlight = Color.white.opacity(0.16)

    // Text
    public let text = Color.white
    public let muted = Color.white.opacity(0.58)
    public let dim = Color.white.opacity(0.40)

    // State
    public let accent = Color(red: 0.561, green: 0.780, blue: 1.0)
    public let ok = Color(red: 0.435, green: 0.827, blue: 0.639)
    public let warn = Color(red: 0.949, green: 0.776, blue: 0.541)
    public let crit = Color(red: 1.0, green: 0.604, blue: 0.604)

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
