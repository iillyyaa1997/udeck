import Foundation

/// The rules that keep a tab's grid consistent: clamping, collision resolution
/// and upward gravity.
///
/// Windows fall upward to fill the space above them, and a window dropped onto
/// an occupied cell pushes the occupant down rather than overlapping it. That
/// combination is what "the neighbours make room" means in practice, and it is
/// the only arrangement where dragging one window has a predictable effect on
/// the rest.
public enum GridEngine {
    /// Upper bound on push-down passes. Every pass moves at least one window
    /// strictly downward, so termination is guaranteed by the number of windows
    /// — this exists only so that a future change to the rules cannot turn into
    /// a hang.
    private static let maxResolutionPasses = 1_000

    /// Brings a set of windows into a legal arrangement.
    ///
    /// - Parameter pinned: a window the operator is currently placing. It keeps
    ///   its requested column and row, and everything it lands on is pushed out
    ///   of the way, rather than the other way round.
    public static func normalized(_ windows: [GridWindow], columns: Int, pinned: UUID? = nil) -> [GridWindow] {
        precondition(columns > 0, "a grid needs at least one column")
        var items = windows.map { clamped($0, columns: columns) }

        if let pinned, let index = items.firstIndex(where: { $0.id == pinned }) {
            pushAside(from: items[index], in: &items)
        }

        return compacted(items, pinned: pinned)
    }

    /// Clamps a window into the grid without changing its identity.
    public static func clamped(_ window: GridWindow, columns: Int) -> GridWindow {
        var w = window
        w.width = min(max(1, w.width), columns)
        w.height = max(1, w.height)
        w.column = min(max(0, w.column), columns - w.width)
        w.row = max(0, w.row)
        return w
    }

    /// Moves everything the given window overlaps straight down below it, and
    /// then does the same for whatever those windows now overlap.
    private static func pushAside(from anchor: GridWindow, in items: inout [GridWindow]) {
        var frontier = [anchor]
        var passes = 0

        while let current = frontier.popLast() {
            passes += 1
            guard passes < maxResolutionPasses else {
                assertionFailure("grid collision resolution did not converge")
                return
            }
            for index in items.indices where items[index].id != current.id {
                guard items[index].overlaps(current) else { continue }
                items[index].row = current.row + current.height
                frontier.append(items[index])
            }
        }
    }

    /// Lets every window fall as far up as it can without overlapping one that
    /// has already settled.
    private static func compacted(_ items: [GridWindow], pinned: UUID?) -> [GridWindow] {
        // Settle in reading order so the result does not depend on the order the
        // windows happen to be stored in. A window being placed by hand settles
        // before anything at the same row, so it wins the cell it was dropped on.
        let ordered = items.enumerated().sorted { lhs, rhs in
            if lhs.element.row != rhs.element.row { return lhs.element.row < rhs.element.row }
            if (lhs.element.id == pinned) != (rhs.element.id == pinned) { return lhs.element.id == pinned }
            if lhs.element.column != rhs.element.column { return lhs.element.column < rhs.element.column }
            return lhs.offset < rhs.offset
        }

        var settled: [GridWindow] = []
        settled.reserveCapacity(ordered.count)

        for entry in ordered {
            var window = entry.element
            while window.row > 0 {
                var lifted = window
                lifted.row -= 1
                if settled.contains(where: { $0.overlaps(lifted) }) { break }
                window = lifted
            }
            settled.append(window)
        }

        // Preserve the caller's ordering; only the geometry was ours to change.
        let byID = Dictionary(uniqueKeysWithValues: settled.map { ($0.id, $0) })
        return items.compactMap { byID[$0.id] }
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
        let clampedHeight = max(1, height)
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
