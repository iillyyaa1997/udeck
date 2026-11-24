import CoreGraphics
import Foundation
import Testing
@testable import UDeckCore

/// Where a window of the board is shown: its cell, a whole tab, a window of
/// its own or a mini window — kept in the layout, and read leniently.
@Suite("Window places")
struct WindowPlaceTests {
    static let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    static func layout() -> DeckLayout {
        var layout = DeckLayout(columns: 4, tabs: [DeckTab(name: "Работа")])
        layout.tabs[0].windows = [
            GridWindow(id: id, pluginID: PluginIdentifier(rawValue: "agents")!, column: 0, row: 0, width: 2, height: 3),
        ]
        return layout
    }

    @Test("a window starts on its cell, and shown elsewhere keeps the cell")
    func showKeepsTheCell() throws {
        var layout = Self.layout()
        #expect(layout.window(withID: Self.id)?.window.place == .card)
        #expect(layout.windowsAway.isEmpty)
        let moved = layout.show(Self.id, in: .window)
        let again = layout.show(Self.id, in: .window)
        #expect(moved)
        #expect(!again, "the same place again changes nothing")
        let shown = try #require(layout.window(withID: Self.id))
        #expect(shown.window.place == .window && shown.window.column == 0 && shown.window.width == 2)
        #expect(layout.windowsAway.map(\.id) == [Self.id])
        let back = layout.show(Self.id, in: .card)
        let nowhere = layout.show(UUID(), in: .tab)
        #expect(back)
        #expect(layout.window(withID: Self.id)?.window.shownIn == nil)
        #expect(!nowhere, "no such window")
    }

    @Test("the place and the frame survive being written and read back")
    func codable() throws {
        var layout = Self.layout()
        layout.show(Self.id, in: .mini)
        layout.remember(frame: CGRect(x: 1200, y: 80, width: 320, height: 200), of: Self.id, in: .mini)
        layout.remember(frame: CGRect(x: 300, y: 100, width: 560, height: 680), of: Self.id, in: .window)
        let back = try JSONDecoder().decode(DeckLayout.self, from: JSONEncoder().encode(layout))
        #expect(back == layout)
        // A mini window is not the size of a window: each place keeps its own.
        #expect(back.window(withID: Self.id)?.window.frame(in: .mini) == [1200, 80, 320, 200])
        #expect(back.window(withID: Self.id)?.window.frame(in: .window) == [300, 100, 560, 680])
        #expect(back.window(withID: Self.id)?.window.frame(in: .tab) == nil)
    }

    @Test("a place this uDeck does not know reads as the cell, and a layout without places reads as before")
    func lenient() throws {
        var window = Self.layout().tabs[0].windows[0]
        window.shownIn = "hologram"
        #expect(window.place == .card)
        let old = #"{"id":"00000000-0000-0000-0000-000000000001","pluginID":"agents","column":0,"row":0,"width":2,"height":3}"#
        let read = try JSONDecoder().decode(GridWindow.self, from: Data(old.utf8))
        #expect(read.place == .card && read.placeFrames == nil)
    }

    @Test("only a window or a mini window is a window of uDeck's own")
    func kinds() {
        #expect(WindowPlace.allCases.filter(\.isOwnWindow) == [.window, .mini])
        #expect(WindowPlace.allCases.filter(\.isAway) == [.tab, .window, .mini])
    }
}

/// What a plugin is told of a place's size: whole cells, at least one.
@Suite("A place's size in cells")
struct CellSizeTests {
    @Test("whole cells of a place, gaps between them counted once")
    func wholeCells() {
        // 3 columns of 100 with 2 gaps of 10 = 320; 2 rows of 50 with 1 gap = 110.
        #expect(CellSize.of(CGSize(width: 320, height: 110), columnWidth: 100, rowHeight: 50, spacing: 10)
                == CellSize(columns: 3, rows: 2))
        #expect(CellSize.of(CGSize(width: 319, height: 109), columnWidth: 100, rowHeight: 50, spacing: 10)
                == CellSize(columns: 2, rows: 1))
    }

    @Test("never less than one cell, whatever it is given")
    func atLeastOne() {
        #expect(CellSize.of(.zero, columnWidth: 100, rowHeight: 50, spacing: 10) == CellSize(columns: 1, rows: 1))
        #expect(CellSize.of(CGSize(width: 500, height: 500), columnWidth: 0, rowHeight: 0, spacing: 10)
                == CellSize(columns: 1, rows: 1))
        #expect(CellSize.of(CGSize(width: CGFloat.infinity, height: .nan), columnWidth: 100, rowHeight: 50, spacing: 10)
                == CellSize(columns: 1, rows: 1))
    }
}
