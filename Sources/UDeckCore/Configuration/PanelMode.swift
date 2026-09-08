import Foundation

/// A starting point for a look.
///
/// This began as a third thing beside Light and Dark, and the operator's next
/// question retired it: he asked for the two to be configurable with something
/// deciding between them, and once there are two poles a third peer has nowhere
/// to stand — a source that answers "light or dark?" cannot answer "or the
/// other one".
///
/// So it is a preset rather than a mode. Any of these can be poured into either
/// look, and `Contrast` survives as the answer to "make this one readable over
/// anything" rather than as a state the panel can be in.
public enum PanelMode: String, Codable, CaseIterable, Sendable, Identifiable {
    /// A bright frosted panel with near-black text. Reads as part of the
    /// machine over a document or a bright desktop.
    case light

    /// A dark panel with white text — what uDeck was before any of this was a
    /// setting, and still the right answer over a dark game.
    case dark

    /// As close to opaque as the material goes, diffusing rather than
    /// refracting what is behind it.
    ///
    /// The one mode that does not care what it is over. Glass is a wager that
    /// the background is calm, and over a game, a video or a photograph it
    /// loses — the panel becomes something you have to look *through* to read.
    /// This gives that up on purpose.
    case contrast

    public var id: String { rawValue }

    /// What to call it in the settings screen.
    public var name: String {
        switch self {
        case .light: "Light"
        case .dark: "Dark"
        case .contrast: "Contrast"
        }
    }

    /// One line on what it is for.
    public var summary: String {
        switch self {
        case .light: "A bright panel with dark text, for work over documents."
        case .dark: "A dark panel with light text, for work over dark screens."
        case .contrast: "Nearly opaque, for a panel that has to be readable over anything."
        }
    }

    /// The glass this mode is made of.
    public var glass: GlassAppearance {
        switch self {
        case .light:
            GlassAppearance(style: .regular, opacity: 1, tinted: true, tintIsLight: true, tintStrength: 0.72)
        case .dark:
            GlassAppearance(style: .regular, opacity: 1, tinted: true, tintIsLight: false, tintStrength: 0.55)
        case .contrast:
            GlassAppearance(style: .clear, opacity: 1, tinted: true, tintIsLight: false, tintStrength: 0.9)
        }
    }

    /// Which way the text is written in it.
    ///
    /// Not a separate decision. The whole reason ink is a setting is that
    /// nothing reports how bright the panel will end up being — but a mode
    /// fixes the tint, and a fixed tint is most of the answer. Choosing a mode
    /// therefore chooses the ink, and choosing the ink by hand is what leaves
    /// the look Custom.
    public var ink: PanelInk {
        switch self {
        case .light: .dark
        case .dark, .contrast: .light
        }
    }
}

extension PanelMode {
    /// This preset as a whole look.
    public var look: PanelLook { PanelLook(glass: glass, ink: ink) }
}

extension ThemeSettings {
    /// The preset one of the looks currently matches, or `nil` if it is the
    /// operator's own mixture.
    public func preset(forDark isDark: Bool) -> PanelMode? {
        let current = look(forDark: isDark)
        return PanelMode.allCases.first { $0.look == current }
    }

    /// Pours a preset into one of the looks.
    public mutating func apply(_ mode: PanelMode, forDark isDark: Bool) {
        setLook(mode.look, forDark: isDark)
    }
}
