import Foundation

/// The rules that keep a tab's grid consistent: clamping, collision resolution
/// and upward gravity.
///
/// Windows fall upward to fill the space above them, and a window dropped onto
/// an occupied cell keeps the cell while the occupant is pushed below it. That
/// combination is what "the neighbours make room" means in practice, and it is
/// the only arrangement where dragging one window has a predictable effect on
/// the rest.
///
/// There is exactly one operation underneath both of those: **settle each
/// window at the topmost free row, in a defined order, with the window being
/// placed going first.** Pushing neighbours out of the way is not a separate
/// step — it is what happens to the windows that settle after the one the
/// operator moved.
///
/// That matters more than it sounds. The obvious implementation, and the one
/// this replaced, resolved collisions by pushing each overlapped window down
/// and then re-examining whatever it now overlapped. A window can be pushed
/// many times, so the work is not bounded by the number of windows, and with
/// enough of them stacked it ran away — aborting in a debug build and, worse,
/// silently leaving overlapping windows in a release build, which then got
/// saved to disk. Settling instead is bounded by construction: each window
/// consults the ones already settled, and never moves again.
public enum GridEngine {
    /// Brings a set of windows into a legal arrangement.
    ///
    /// - Parameter pinned: a window the operator is currently placing. It
    ///   settles first, so it keeps the cell it was dropped on and everything
    ///   else arranges itself around it.
    public static func normalized(_ windows: [GridWindow], columns: Int, pinned: UUID? = nil) -> [GridWindow] {
        precondition(columns > 0, "a grid needs at least one column")
        let items = windows.map { clamped($0, columns: columns) }

        var settled: [GridWindow] = []
        settled.reserveCapacity(items.count)

        for entry in settleOrder(items, pinned: pinned) {
            var window = entry
            window.row = firstFreeRow(for: window, among: settled)
            settled.append(window)
        }

        // Preserve the caller's ordering; only the geometry was ours to change.
        let byID = Dictionary(settled.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return items.compactMap { byID[$0.id] }
    }

    /// Clamps a window into the grid without changing its identity.
    ///
    /// Height and row are bounded as well as width and column. Both arrive from
    /// two places that cannot be trusted to be sensible — a drag, which turns
    /// pointer movement into cells, and a layout file, which a person can edit
    /// — and an unbounded row in particular used to be a way to make the app
    /// think for a very long time.
    public static func clamped(_ window: GridWindow, columns: Int) -> GridWindow {
        var w = window
        w.width = min(max(1, w.width), columns)
        w.height = min(max(1, w.height), DeckLayout.maximumWindowHeight)
        w.column = min(max(0, w.column), columns - w.width)
        w.row = min(max(0, w.row), DeckLayout.maximumWindowRow)
        return w
    }

    /// Who settles before whom.
    ///
    /// Reading order — row, then column — with the caller's ordering breaking
    /// remaining ties so the result never depends on how the windows happened
    /// to be stored.
    ///
    /// The window being placed wins **only a tie**, and that limit is the whole
    /// subtlety. Letting it settle before everything regardless of its row
    /// meant a window dragged *below* another still landed above it, because it
    /// took the top row before the other had a chance at it — dragging
    /// downwards did the opposite of what was asked. Winning ties is enough for
    /// the case that matters: a window dropped *onto* an occupied cell shares
    /// that cell's row, so it goes first and the occupant is pushed below.
    private static func settleOrder(_ items: [GridWindow], pinned: UUID?) -> [GridWindow] {
        items.enumerated().sorted { lhs, rhs in
            if lhs.element.row != rhs.element.row { return lhs.element.row < rhs.element.row }
            if (lhs.element.id == pinned) != (rhs.element.id == pinned) {
                return lhs.element.id == pinned
            }
            if lhs.element.column != rhs.element.column { return lhs.element.column < rhs.element.column }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    /// The topmost row where this window does not overlap anything already
    /// settled.
    ///
    /// Each step jumps past the whole window that blocked it rather than trying
    /// the next row. An overlap means the blocker's bottom edge is below the
    /// row being tried, so every step moves strictly downward and the search
    /// ends after at most one step per settled window — whatever row the
    /// window arrived carrying.
    private static func firstFreeRow(for window: GridWindow, among settled: [GridWindow]) -> Int {
        var candidate = window
        var row = 0
        while true {
            candidate.row = row
            guard let blocker = settled.first(where: { $0.overlaps(candidate) }) else { return row }
            row = blocker.row + blocker.height
        }
    }

    /// The first free placement for a new window of the given size.
    ///
    /// Scans rows top to bottom, columns left to right, so a new window lands
    /// where the operator would expect to find it rather than at the bottom.
    public static func firstFreeSlot(
        width: Int,
        height: Int,
        in windows: [GridWindow],
        columns: Int
    ) -> (column: Int, row: Int) {
        let clampedWidth = min(max(1, width), columns)
        let clampedHeight = min(max(1, height), DeckLayout.maximumWindowHeight)
        let lastRow = windows.map { $0.row + $0.height }.max() ?? 0

        for row in 0 ... lastRow {
            for column in 0 ... (columns - clampedWidth) {
                let candidate = GridWindow(
                    pluginID: PluginIdentifier.placeholder,
                    column: column, row: row, width: clampedWidth, height: clampedHeight
                )
                if !windows.contains(where: { $0.overlaps(candidate) }) {
                    return (column, row)
                }
            }
        }
        return (0, lastRow)
    }
}
