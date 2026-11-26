import CoreGraphics

/// How tall a grid row is drawn.
public enum GridRows {
    /// The row height that shows a tab's `rows` in `available` points: the
    /// tab fills the panel exactly and does not scroll — whatever the screen,
    /// the density or the text size (11-26: an 8-row card was some 20 points
    /// taller than the panel, and its top or its bottom was cut off). Rows
    /// that fit with room to spare are the theme's, stretched to fill; more
    /// rows than fit are shrunk, down to `smallest` of the theme's — a layout
    /// taller still scrolls, as every layout did before.
    public static func height(available: CGFloat, rows: Int, nominal: CGFloat, spacing: CGFloat,
                              smallest: CGFloat = 0.6) -> CGFloat {
        guard available > 0, nominal > 0 else { return nominal }
        let fitting = max(1, Int(((available + spacing) / (nominal + spacing)).rounded(.down)))
        let shown = max(1, rows, fitting)
        let height = (available - spacing * CGFloat(shown - 1)) / CGFloat(shown)
        return max(nominal * smallest, height)
    }
}
