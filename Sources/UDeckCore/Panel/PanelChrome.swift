import CoreGraphics
import Foundation

/// What the panel draws around itself, as opposed to what it puts inside.
///
/// One rule lives here, and it is a rule with an edge that cost the collapse
/// animation on the built-in display: **"nothing is drawn under a real notch"
/// is a statement about the collapsed state at rest, not about the journey into
/// it.**
///
/// The panel's glass used to be drawn under `phase != .collapsed ||
/// !screenHasNotch`, read straight from the phase. The phase changes the moment
/// the collapse is decided — before a single frame of the shape animation has
/// run — so on a notched screen the glass was deleted at frame zero and the
/// panel's rectangle then animated an empty region down into the notch. The
/// operator saw the panel vanish rather than close, and only on the laptop:
/// a notchless screen takes the other branch and keeps drawing its island all
/// the way down, which is why the external display looked right.
///
/// So the rule needs the one fact the phase cannot carry — whether the panel
/// has arrived. It is a free function over three booleans rather than a method
/// on the view because that is what makes it possible to prove.
public enum PanelChrome {
    /// Whether the panel should draw its material at all.
    ///
    /// - Parameters:
    ///   - phase: the phase the panel is in or heading for.
    ///   - screenHasNotch: whether this screen's island is hardware.
    ///   - isSettled: whether the panel has finished moving. False for the whole
    ///     of a transition, in either direction.
    public static func drawsMaterial(
        phase: PanelPhase,
        screenHasNotch: Bool,
        isSettled: Bool
    ) -> Bool {
        guard phase == .collapsed else { return true }
        // A drawn island is the panel at its smallest, and stays drawn.
        guard screenHasNotch else { return true }
        // Under a real notch there is nothing to draw once the panel is home —
        // the hardware is the island. Until then there is: the shape shrinking
        // into the notch is the close.
        return !isSettled
    }

    /// Whether the island's own mark — the small bar that says how things are
    /// while the panel is away — is drawn.
    ///
    /// Only once the panel has arrived. The mark is centred in whatever
    /// rectangle the panel currently occupies, and the collapsed state's content
    /// used to be swapped in the instant the collapse was decided: with the
    /// panel still at its full size, the bar appeared in the middle of the
    /// screen and rode up to the top as the shape shrank under it. The operator
    /// described it exactly — "эта тире появляется по центру и уезжает вверх".
    ///
    /// A mark means "the panel is away and this is how things are". During the
    /// collapse the panel is not away yet; it is leaving.
    public static func drawsIslandMark(
        phase: PanelPhase,
        screenHasNotch: Bool,
        isSettled: Bool
    ) -> Bool {
        // Under a real notch there is no drawn island to put a mark on.
        phase == .collapsed && !screenHasNotch && isSettled
    }

    /// The corner radius the material is drawn with in a given phase.
    ///
    /// The island is smaller than the panel and takes a smaller radius; one
    /// radius for both would either look blunt at 185 points wide or swallow
    /// the whole island.
    public static func cornerRadius(phase: PanelPhase, metrics: PanelMetrics) -> CGFloat {
        phase == .collapsed ? metrics.islandCornerRadius : metrics.cornerRadius
    }
}
