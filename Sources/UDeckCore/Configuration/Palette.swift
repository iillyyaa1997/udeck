import Foundation

/// A colour and how much of it there is.
///
/// Two numbers rather than one four-component colour, because nearly everything
/// uDeck draws is the same ink laid on at a different strength — the strength is
/// the part that varies, and writing it separately is what lets the strengths be
/// collected in one table instead of being spelled out at each place that draws.
///
/// It lives in this target, which has no AppKit and no SwiftUI, so the whole
/// palette can be checked by a test that never opens a window.
public struct PaletteColor: Equatable, Sendable {
    public var ink: InkColor
    public var alpha: Double

    public init(_ ink: InkColor, alpha: Double = 1) {
        self.ink = ink
        self.alpha = alpha
    }

    /// The same colour, weaker.
    ///
    /// Used inside `Palette` to derive one entry from another. Views do not call
    /// it: a view that thins a colour by a number of its own has just become a
    /// second place the look is decided, which is the thing this type exists to
    /// stop.
    public func at(_ fraction: Double) -> PaletteColor {
        PaletteColor(ink, alpha: alpha * fraction)
    }
}

/// Every colour uDeck draws, worked out once from the look.
///
/// Before this, the look reached the screen as `PanelLook.foreground` and each
/// place that drew something decided for itself how far to thin it — twelve
/// opacities spelled out at twelve call sites, two full sets of state colours,
/// and a panel tint that was a constant and followed nothing at all. Changing
/// the panel's character meant finding all of them, and the one time they were
/// changed apart the operator got a light panel still wearing hairlines drawn
/// for a dark one.
///
/// So: one type, built from one `PanelLook`, holding every colour by name. The
/// strengths below are the whole of uDeck's visual judgement and this is the
/// only file that contains any of it.
///
/// Derived, not stored. A palette is never written to the settings file — it is
/// recomputed from the look whenever the look changes, so a new default reaches
/// an install that already exists rather than being pinned by what was saved
/// under an older build.
public struct Palette: Equatable, Sendable {

    // MARK: - Surfaces

    /// The panel's own colour, for the macOS versions that have no glass.
    ///
    /// On macOS 26 and later the panel is the system material with
    /// `GlassTint` painted over it, and this is not drawn. Before that there is
    /// no such material and this stands in for the whole panel — so it follows
    /// the look's tint rather than being the fixed near-black it used to be,
    /// which made every pre-26 panel dark no matter which look was chosen.
    public let panelTint: PaletteColor

    /// A card, or anything else sitting on the panel as its own surface.
    public let windowFill: PaletteColor

    /// A sunken area — a text field, a slot waiting to be filled.
    public let recess: PaletteColor

    /// The tab that is showing, and anything else marked as chosen.
    public let selection: PaletteColor

    /// The faintest surface that is still a surface.
    public let subtleFill: PaletteColor

    /// A control under the pointer.
    public let hover: PaletteColor

    /// The same control, held down.
    public let hoverPressed: PaletteColor

    /// A hairline between two things.
    public let line: PaletteColor

    /// The panel's own outline.
    public let panelBorder: PaletteColor

    /// The bright row along the panel's top edge, where it is not welded to the
    /// edge of the screen. White on purpose and in both looks: it stands for a
    /// light catching a physical edge, and a light that changed colour with the
    /// panel would stop reading as one.
    public let innerHighlight: PaletteColor

    // MARK: - Text

    public let text: PaletteColor
    public let muted: PaletteColor
    public let dim: PaletteColor

    // MARK: - State

    /// State colours are picked twice over: the pale set reads on a dark panel
    /// and vanishes on a bright one, so the set for a bright panel is deeper.
    /// This is the one part of the palette that is not the ink thinned down —
    /// a state has to be its own colour or it is not a state.
    public let accent: PaletteColor
    public let ok: PaletteColor
    public let warn: PaletteColor
    public let crit: PaletteColor

    // MARK: - Marks

    /// The bars of a sparkline.
    public let sparkline: PaletteColor

    /// The resize grip in the corner of a card, at rest and under the pointer.
    public let grip: PaletteColor
    public let gripHover: PaletteColor

    /// A dark halo under the island's indicator, so the bar reads against a
    /// bright document as well as against a dark game. Pure black in both
    /// looks: it is a shadow, and a shadow the colour of the panel is not one.
    public let islandHalo: PaletteColor

    // MARK: - Construction

    public init(look: PanelLook) {
        let ink = look.ink
        let fg = look.foreground

        func inked(_ strength: Strength) -> PaletteColor {
            PaletteColor(fg, alpha: strength.value(ink))
        }

        panelTint = Self.panelTint(for: look)
        windowFill = inked(Self.windowFill)
        recess = inked(Self.recess)
        selection = inked(Self.selection)
        subtleFill = inked(Self.subtleFill)
        hover = inked(Self.hover)
        hoverPressed = inked(Self.hoverPressed)
        line = inked(Self.line)
        panelBorder = inked(Self.panelBorder)
        innerHighlight = PaletteColor(.white, alpha: Self.innerHighlightAlpha)

        text = PaletteColor(fg)
        muted = inked(Self.muted)
        dim = inked(Self.dim)

        let accent = PaletteColor(Self.accent.value(ink))
        self.accent = accent
        ok = PaletteColor(Self.ok.value(ink))
        warn = PaletteColor(Self.warn.value(ink))
        crit = PaletteColor(Self.crit.value(ink))

        sparkline = accent.at(Self.sparklineFraction)
        grip = accent.at(Self.gripFraction)
        gripHover = accent.at(Self.gripHoverFraction)
        islandHalo = PaletteColor(Self.shadowInk, alpha: Self.islandHaloAlpha)
    }

    // MARK: - Lookups

    public func color(for state: CardState) -> PaletteColor {
        switch state {
        case .ok: ok
        case .warn: warn
        case .crit: crit
        case .unknown: dim
        }
    }

    public func color(for icon: CardIcon) -> PaletteColor {
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

    /// The capsule behind a card's chip: the state's own colour, thinned to a
    /// wash the text on top of it can still be read against.
    public func chipFill(for state: CardState) -> PaletteColor {
        color(for: state).at(Self.chipFillFraction)
    }

    /// The island's indicator bar.
    ///
    /// Dimmed when nothing has been placed yet, because at full strength it
    /// reads as a report about plugins that are not there.
    public func islandMark(for state: CardState, placed: Bool) -> PaletteColor {
        color(for: state).at(placed ? 1 : Self.islandEmptyFraction)
    }

    // MARK: - The table

    /// One strength, stated for both panels it may be drawn on.
    ///
    /// Named by the panel rather than by the ink, because that is what the
    /// number is answering: a hairline has to be fainter on a dark panel than a
    /// bright one to read as equally faint, and "0.11 when the ink is light" is
    /// the same fact said in a way nobody can check by eye.
    private struct Strength {
        let onDarkPanel: Double
        let onLightPanel: Double

        func value(_ ink: PanelInk) -> Double {
            ink == .light ? onDarkPanel : onLightPanel
        }
    }

    /// A colour stated for both panels, for the few things that are not the ink.
    private struct Duo {
        let onDarkPanel: InkColor
        let onLightPanel: InkColor

        func value(_ ink: PanelInk) -> InkColor {
            ink == .light ? onDarkPanel : onLightPanel
        }
    }

    private static let windowFill = Strength(onDarkPanel: 0.07, onLightPanel: 0.07)
    private static let recess = Strength(onDarkPanel: 0.28, onLightPanel: 0.10)
    private static let selection = Strength(onDarkPanel: 0.14, onLightPanel: 0.10)
    private static let subtleFill = Strength(onDarkPanel: 0.06, onLightPanel: 0.05)
    private static let hover = Strength(onDarkPanel: 0.05, onLightPanel: 0.06)
    private static let hoverPressed = Strength(onDarkPanel: 0.12, onLightPanel: 0.14)
    private static let line = Strength(onDarkPanel: 0.11, onLightPanel: 0.16)
    private static let panelBorder = Strength(onDarkPanel: 0.14, onLightPanel: 0.20)
    private static let muted = Strength(onDarkPanel: 0.58, onLightPanel: 0.66)
    private static let dim = Strength(onDarkPanel: 0.40, onLightPanel: 0.50)

    private static let innerHighlightAlpha = 0.16

    private static let accent = Duo(
        onDarkPanel: InkColor(red: 0.561, green: 0.780, blue: 1.0),
        onLightPanel: InkColor(red: 0.10, green: 0.36, blue: 0.62)
    )
    private static let ok = Duo(
        onDarkPanel: InkColor(red: 0.435, green: 0.827, blue: 0.639),
        onLightPanel: InkColor(red: 0.09, green: 0.45, blue: 0.28)
    )
    private static let warn = Duo(
        onDarkPanel: InkColor(red: 0.949, green: 0.776, blue: 0.541),
        onLightPanel: InkColor(red: 0.55, green: 0.36, blue: 0.05)
    )
    private static let crit = Duo(
        onDarkPanel: InkColor(red: 1.0, green: 0.604, blue: 0.604),
        onLightPanel: InkColor(red: 0.63, green: 0.13, blue: 0.13)
    )

    private static let sparklineFraction = 0.75
    private static let gripFraction = 0.25
    private static let gripHoverFraction = 0.9
    private static let chipFillFraction = 0.18
    private static let islandEmptyFraction = 0.35

    /// A shadow is black, not the ink's black — `InkColor.black` is a text
    /// colour that stops short of the bottom of the scale so that dark text
    /// does not read as a hole.
    private static let shadowInk = InkColor(red: 0, green: 0, blue: 0)
    private static let islandHaloAlpha = 0.55

    /// What stands in for the panel where there is no glass to tint.
    ///
    /// The tint, when there is one — the same white level and strength the
    /// material would have been given, so the two macOS versions agree. Without
    /// a tint there is nothing to copy, and the panel falls back to the colour
    /// its own ink implies: light ink means a dark panel, dark ink a bright one.
    private static let untintedPanelAlpha = 0.62

    private static func panelTint(for look: PanelLook) -> PaletteColor {
        if let tint = look.glass.tintComponents {
            return PaletteColor(tint.color, alpha: tint.alpha)
        }
        let implied: InkColor = look.ink == .light ? shadowInk : .white
        return PaletteColor(implied, alpha: untintedPanelAlpha)
    }
}
