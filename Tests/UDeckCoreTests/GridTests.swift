import Foundation
import Testing
@testable import UDeckCore

private func window(
    _ id: String, column: Int, row: Int, width: Int, height: Int
) -> GridWindow {
    GridWindow(
        id: UUID(uuidString: "00000000-0000-0000-0000-0000000000\(id)")!,
        pluginID: PluginIdentifier(rawValue: "p")!,
        column: column, row: row, width: width, height: height
    )
}

@Suite("Grid")
struct GridTests {
    let columns = 12

    @Test("a window wider than the grid is narrowed, not allowed to overflow")
    func clampsWidth() {
        let clamped = GridEngine.clamped(window("01", column: 10, row: 0, width: 20, height: 1), columns: columns)
        #expect(clamped.width == columns)
        #expect(clamped.column == 0)
    }

    @Test("a window pushed off the right edge slides back on")
    func clampsColumn() {
        let clamped = GridEngine.clamped(window("01", column: 11, row: 0, width: 4, height: 1), columns: columns)
        #expect(clamped.column == 8)
        #expect(clamped.column + clamped.width == columns)
    }

    @Test("negative positions and zero sizes are corrected")
    func clampsNonsense() {
        let clamped = GridEngine.clamped(window("01", column: -5, row: -3, width: 0, height: 0), columns: columns)
        #expect(clamped.column == 0)
        #expect(clamped.row == 0)
        #expect(clamped.width == 1)
        #expect(clamped.height == 1)
    }

    @Test("windows fall upward to fill the gap left by one that was removed")
    func gravity() {
        let result = GridEngine.normalized([
            window("01", column: 0, row: 5, width: 6, height: 2),
            window("02", column: 6, row: 9, width: 6, height: 2),
        ], columns: columns)
        #expect(result[0].row == 0)
        #expect(result[1].row == 0)
    }

    @Test("a window dropped on an occupied cell pushes the occupant down")
    func dropPushesNeighbourDown() {
        let occupant = window("01", column: 0, row: 0, width: 6, height: 2)
        let dropped = window("02", column: 0, row: 0, width: 6, height: 2)
        let result = GridEngine.normalized([occupant, dropped], columns: columns, pinned: dropped.id)
        let placedDrop = result.first { $0.id == dropped.id }!
        let placedOccupant = result.first { $0.id == occupant.id }!
        #expect(placedDrop.row == 0, "the window being placed keeps the cell it was dropped on")
        #expect(placedOccupant.row == 2)
        #expect(!placedDrop.overlaps(placedOccupant))
    }

    @Test("a chain of collisions is resolved without leaving any overlap")
    func chainOfCollisions() {
        let a = window("01", column: 0, row: 0, width: 12, height: 2)
        let b = window("02", column: 0, row: 2, width: 12, height: 2)
        let c = window("03", column: 0, row: 4, width: 12, height: 2)
        let dropped = window("04", column: 0, row: 0, width: 12, height: 3)
        let result = GridEngine.normalized([a, b, c, dropped], columns: columns, pinned: dropped.id)
        for (i, first) in result.enumerated() {
            for second in result[(i + 1)...] {
                #expect(!first.overlaps(second), "\(first.id) overlaps \(second.id)")
            }
        }
    }

    @Test("windows side by side are left side by side")
    func sideBySideIsStable() {
        let left = window("01", column: 0, row: 0, width: 6, height: 3)
        let right = window("02", column: 6, row: 0, width: 6, height: 3)
        let result = GridEngine.normalized([left, right], columns: columns)
        #expect(result[0].row == 0 && result[0].column == 0)
        #expect(result[1].row == 0 && result[1].column == 6)
    }

    @Test("normalising is idempotent")
    func idempotent() {
        let input = [
            window("01", column: 0, row: 3, width: 5, height: 2),
            window("02", column: 4, row: 3, width: 5, height: 2),
            window("03", column: 0, row: 0, width: 12, height: 1),
        ]
        let once = GridEngine.normalized(input, columns: columns)
        let twice = GridEngine.normalized(once, columns: columns)
        #expect(once == twice)
    }

    @Test("the caller's ordering is preserved; only geometry changes")
    func orderPreserved() {
        let input = [
            window("03", column: 0, row: 9, width: 4, height: 1),
            window("01", column: 0, row: 0, width: 4, height: 1),
            window("02", column: 4, row: 0, width: 4, height: 1),
        ]
        let result = GridEngine.normalized(input, columns: columns)
        #expect(result.map(\.id) == input.map(\.id))
    }

    @Test("a new window lands in the first gap, not at the bottom")
    func firstFreeSlotFillsGaps() {
        let existing = [
            window("01", column: 0, row: 0, width: 4, height: 2),
            window("02", column: 8, row: 0, width: 4, height: 2),
        ]
        let slot = GridEngine.firstFreeSlot(width: 4, height: 2, in: existing, columns: columns)
        #expect(slot == (column: 4, row: 0))
    }

    @Test("a new window that fits nowhere on the current rows goes below them")
    func firstFreeSlotFallsThrough() {
        let existing = [window("01", column: 0, row: 0, width: 12, height: 3)]
        let slot = GridEngine.firstFreeSlot(width: 12, height: 2, in: existing, columns: columns)
        #expect(slot == (column: 0, row: 3))
    }

    @Test("a window's frame in points divides the panel evenly")
    func frameArithmetic() {
        let w = window("01", column: 0, row: 0, width: 12, height: 1)
        let frame = w.frame(contentWidth: 1000, columns: 12, rowHeight: 40, spacing: 10)
        #expect(frame.width == 1000)
        let half = window("02", column: 6, row: 0, width: 6, height: 1)
            .frame(contentWidth: 1000, columns: 12, rowHeight: 40, spacing: 10)
        #expect(half.maxX == 1000)
        #expect(abs(half.width - (1000 - 10) / 2) < 0.001)
    }
}

@Suite("Layout")
struct LayoutTests {
    let plugin = PluginIdentifier(rawValue: "hello-card")!

    @Test("a fresh install has one tab, not zero")
    func firstRunHasSomewhereToDrop() {
        let layout = DeckLayout.firstRun()
        #expect(layout.tabs.count == 1)
        #expect(layout.selectedTabID == layout.tabs[0].id)
        #expect(layout.tabs[0].windows.isEmpty)
    }

    @Test("tabs are created, renamed, reordered and removed")
    func tabLifecycle() {
        var layout = DeckLayout.firstRun()
        let work = layout.addTab(named: "Work")
        #expect(layout.selectedTabID == work)
        layout.renameTab(work, to: "Deep work")
        #expect(layout.tabs.last?.name == "Deep work")
        layout.moveTab(from: 1, to: 0)
        #expect(layout.tabs.first?.name == "Deep work")
        layout.removeTab(work)
        #expect(layout.tabs.count == 1)
        #expect(layout.selectedTabID == layout.tabs[0].id)
    }

    @Test("removing the selected tab selects a neighbour rather than nothing")
    func removalKeepsASelection() {
        var layout = DeckLayout.firstRun()
        let second = layout.addTab(named: "Second")
        _ = layout.addTab(named: "Third")
        layout.selectedTabID = second
        layout.removeTab(second)
        #expect(layout.selectedTabID != nil)
        #expect(layout.tabs.contains { $0.id == layout.selectedTabID })
    }

    @Test("windows are added into free space and can be moved around")
    func windowPlacement() {
        var layout = DeckLayout.firstRun()
        let tab = layout.tabs[0].id
        let hints = WindowHints(defaultWidth: 6, defaultHeight: 2)
        let first = layout.addWindow(pluginID: plugin, to: tab, hints: hints)!
        let second = layout.addWindow(pluginID: plugin, to: tab, hints: hints)!
        #expect(layout.tabs[0].windows.count == 2)
        #expect(layout.tabs[0].windows.map(\.row) == [0, 0])

        layout.place(windowID: second, in: tab, column: 0, row: 0)
        let placedSecond = layout.tabs[0].windows.first { $0.id == second }!
        let placedFirst = layout.tabs[0].windows.first { $0.id == first }!
        #expect(placedSecond.row == 0 && placedSecond.column == 0)
        #expect(!placedFirst.overlaps(placedSecond))
    }

    @Test("windows belonging to an uninstalled plugin are dropped, and named")
    func pruneRemovesOrphans() {
        var layout = DeckLayout.firstRun()
        let tab = layout.tabs[0].id
        let gone = PluginIdentifier(rawValue: "gone")!
        layout.addWindow(pluginID: plugin, to: tab)
        layout.addWindow(pluginID: gone, to: tab)
        let removed = layout.pruneWindows(keepingPlugins: [plugin])
        #expect(removed == [gone])
        #expect(layout.tabs[0].windows.allSatisfy { $0.pluginID == plugin })
    }

    @Test("a layout decoded with nonsense in it is brought back to something legal")
    func normalisationRepairs() {
        var broken = DeckLayout(version: 1, columns: 0, tabs: [], selectedTabID: UUID())
        broken = broken.normalized()
        #expect(broken.columns == 1)
        #expect(broken.tabs.count == 1)
        #expect(broken.selectedTabID == broken.tabs[0].id)
    }

    @Test("a layout survives a round trip through JSON")
    func codableRoundTrip() throws {
        var layout = DeckLayout.firstRun()
        let tab = layout.tabs[0].id
        layout.addWindow(pluginID: plugin, to: tab)
        _ = layout.addTab(named: "Home")

        let data = try JSONEncoder().encode(layout)
        let restored = try JSONDecoder().decode(DeckLayout.self, from: data)
        #expect(restored == layout)
    }
}

@Suite("Grid bounds")
struct GridBoundsTests {
    /// A resize drag turns pointer movement into cells. Without a ceiling, one
    /// flick downwards asks for a window thousands of rows tall.
    @Test("a window cannot be taller than the grid allows")
    func heightIsBounded() {
        #expect(DeckLayout.maximumWindowHeight >= 8, "the ceiling must still allow a tall window")

        var layout = DeckLayout.firstRun()
        let tab = layout.tabs[0].id
        let plugin = PluginIdentifier(rawValue: "p")!
        let window = layout.addWindow(pluginID: plugin, to: tab)!
        layout.place(windowID: window, in: tab, column: 0, row: 0,
                     width: 4, height: DeckLayout.maximumWindowHeight * 100)
        let placed = layout.tabs[0].windows[0]
        // The ceiling is imposed by the model, not only by the drag: a height
        // this large can also arrive from a hand-edited layout file.
        #expect(placed.height == DeckLayout.maximumWindowHeight)
        #expect(placed.row == 0)
    }
}

@Suite("Grid — dragging downward")
struct GridDownwardDragTests {
    let columns = 12
    let plugin = PluginIdentifier(rawValue: "p")!

    func window(_ id: String, column: Int, row: Int, width: Int, height: Int) -> GridWindow {
        GridWindow(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000000\(id)")!,
            pluginID: plugin, column: column, row: row, width: width, height: height
        )
    }

    /// The window being placed settles first so that it keeps the cell it was
    /// dropped on. But "first" must not mean "above everything" — a window
    /// dragged *below* another has to land below it, or dragging downward does
    /// the opposite of what was asked.
    @Test("a window dragged below another lands below it")
    func draggingDownwardKeepsTheOrder() {
        let top = window("01", column: 0, row: 0, width: 12, height: 2)
        let bottom = window("02", column: 0, row: 2, width: 12, height: 2)

        // Drag the top one down past the other.
        var dragged = top
        dragged.row = 3
        let result = GridEngine.normalized([dragged, bottom], columns: columns, pinned: dragged.id)

        let placedDragged = result.first { $0.id == top.id }!
        let placedOther = result.first { $0.id == bottom.id }!
        #expect(placedOther.row < placedDragged.row,
                "the dragged window went to row \(placedDragged.row), the other to \(placedOther.row)")
        #expect(!placedDragged.overlaps(placedOther))
    }

    @Test("a window dropped onto an occupied cell still keeps the cell")
    func droppingOnACellStillWins() {
        let occupant = window("01", column: 0, row: 0, width: 12, height: 2)
        var dropped = window("02", column: 0, row: 4, width: 12, height: 2)
        dropped.row = 0

        let result = GridEngine.normalized([occupant, dropped], columns: columns, pinned: dropped.id)
        #expect(result.first { $0.id == dropped.id }!.row == 0)
        #expect(result.first { $0.id == occupant.id }!.row == 2)
    }

    @Test("dragging within a column of three keeps the requested order")
    func reorderingWithinAStack() {
        let a = window("01", column: 0, row: 0, width: 12, height: 1)
        let b = window("02", column: 0, row: 1, width: 12, height: 1)
        let c = window("03", column: 0, row: 2, width: 12, height: 1)

        // Drag the first one to the bottom.
        var dragged = a
        dragged.row = 3
        let result = GridEngine.normalized([dragged, b, c], columns: columns, pinned: dragged.id)
        let rows = Dictionary(uniqueKeysWithValues: result.map { ($0.id, $0.row) })
        #expect(rows[b.id]! < rows[a.id]!, "b should be above the dragged window")
        #expect(rows[c.id]! < rows[a.id]!, "c should be above the dragged window")
    }
}
