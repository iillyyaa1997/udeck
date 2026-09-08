import Foundation

/// A whole look, in one choice.
///
/// The pieces a look is made of — how much material there is, which way it
/// leans, how far, and which way the text is written — are all settings of
/// their own, and they have to be: the panel hangs over whatever the operator
/// happens to have on screen, and no single set of numbers is right over a
/// white document and a dark game both.
///
/// But four knobs is not a look. Set independently they produce combinations
/// nobody wants — white text on a panel tinted 72% white, which is what the
/// operator was handed the first time the tint went up — and the question he
/// actually asked was "why is this not one setting". This is that setting. The
/// knobs stay underneath it for the cases a preset does not cover, and a
/// preset is recognised by its values rather than stored, so changing one knob
/// leaves the look Custom without anything having to remember it.
public enum PanelMode: String, Codable, CaseIterable, Sendable, Identifiable {
    /// A bright frosted panel with near-black text. Reads as part of the
    /// machine over a document or a bright desktop.
    case light

    /// A dark panel with white text — what uDeck was before any of this was a
    /// setting, and still the right answer over a dark game.
    case dark

    /// Neither: as close to opaque as the material goes, diffusing rather than
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

extension AppSettings {
    /// The mode these settings are, or `nil` for a look that is nobody's preset.
    public var mode: PanelMode? {
        PanelMode.allCases.first { $0.glass == glass && $0.ink == ink }
    }

    /// These settings, wearing that mode.
    public func applying(_ mode: PanelMode) -> AppSettings {
        var result = self
        result.glass = mode.glass
        result.ink = mode.ink
        return result
    }
}
