import Foundation

/// Which way the panel's text is written.
///
/// The panel used to be dark by construction, so white text was not a choice —
/// it was the only one that could work. Once the glass became something the
/// operator sets, that stopped being true: a light tint over a bright document
/// gives white on white.
///
/// Deliberately not automatic. Choosing correctly would mean knowing how bright
/// what is *behind* the panel is, and uDeck does not measure that — the glass
/// samples it, but nothing reports it back. An automatic setting here would be
/// a guess dressed up as a decision, and it would guess wrong exactly where it
/// matters: a light tint at low strength over a dark game still needs light
/// text, and the same tint over a white page needs dark.
public enum PanelInk: String, Codable, Sendable, CaseIterable {
    /// White text, for a panel that reads darker than its surroundings.
    case light

    /// Near-black text, for a panel that reads brighter than its surroundings.
    case dark
}
