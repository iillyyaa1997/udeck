import Foundation

/// What Settings → Plugins says above its rows, decided here where it is
/// tested: UDeckKit has none.
public enum PluginsPane {
    /// Whether the list of installed plugins says *Nothing installed yet*:
    /// only when it has no row at all — no plugin folder (`folders`), and no
    /// plugin uDeck installed whose folder has gone (`missing`), which has a
    /// row of its own, **Missing**, saying it can be put back. A line saying
    /// nothing is installed above such a row was the screen contradicting
    /// itself (R3's lab, 04-the-folder-gone.png of 20261012-032204Z).
    public static func saysNothingInstalled(folders: Int, missing: Int) -> Bool {
        folders == 0 && missing == 0
    }
}
