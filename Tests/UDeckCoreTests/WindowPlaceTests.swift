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

/// Places apart: what a plugin's window on the board shows, sent to a place
/// of its own while the window stays on its cell.
@Suite("Places apart")
struct PlacesApartTests {
    static let agents = PluginIdentifier(rawValue: "agents")!

    static func layout() -> DeckLayout {
        var layout = WindowPlaceTests.layout()
        layout.keep("s-1", showing: "Fix it", for: WindowPlaceTests.id)
        return layout
    }

    @Test("a place apart starts with what the window keeps, its name and its size; the window stays on its cell")
    func open() throws {
        var layout = Self.layout()
        let apartMade = layout.openApart(from: WindowPlaceTests.id, in: .mini)
        let apart = try #require(apartMade)
        let board = try #require(layout.window(withID: WindowPlaceTests.id)?.window)
        #expect(board.place == .card)
        let found = try #require(layout.window(withID: apart))
        #expect(found.tabID == layout.tabs[0].id, "a place apart answers its plugin's tab")
        #expect(found.window.place == .mini && found.window.keep == "s-1" && found.window.showing == "Fix it")
        #expect(found.window.width == 2 && found.window.height == 3)
        #expect(layout.isApart(apart) && !layout.isApart(WindowPlaceTests.id))
        #expect(layout.views(of: Self.agents).map(\.id) == [WindowPlaceTests.id, apart], "the board's first")
        #expect(layout.windowsAway.map(\.id) == [apart])
        let asCell = layout.openApart(from: WindowPlaceTests.id, in: .card)
        let fromApart = layout.openApart(from: apart, in: .window)
        #expect(asCell == nil, "a place apart is never a cell")
        #expect(fromApart == nil, "only a window on the board sends a thing apart")
    }

    @Test("a place apart moves between places, never to a cell; it keeps its frame and what it shows")
    func moves() throws {
        var layout = Self.layout()
        let apartMade = layout.openApart(from: WindowPlaceTests.id, in: .window)
        let apart = try #require(apartMade)
        let toTab = layout.show(apart, in: .tab)
        let again = layout.show(apart, in: .tab)
        let toCell = layout.show(apart, in: .card)
        #expect(toTab)
        #expect(!again)
        #expect(!toCell)
        #expect(layout.window(withID: apart)?.window.place == .tab)
        layout.remember(frame: CGRect(x: 10, y: 20, width: 300, height: 200), of: apart, in: .window)
        #expect(layout.window(withID: apart)?.window.frame(in: .window) == [10, 20, 300, 200])
        let changed = layout.keep("s-2", showing: "Other", for: apart)
        let same = layout.keep("s-2", showing: "Other", for: apart)
        #expect(changed)
        #expect(!same, "the same again changes nothing")
        #expect(layout.window(withID: apart)?.window.keep == "s-2")
        #expect(layout.window(withID: WindowPlaceTests.id)?.window.keep == "s-1", "the board's window keeps its own")
    }

    @Test("places apart are written and read back, and a layout without them reads as before")
    func codable() throws {
        var layout = Self.layout()
        let opened = layout.openApart(from: WindowPlaceTests.id, in: .mini)
        #expect(opened != nil)
        let back = try JSONDecoder().decode(DeckLayout.self, from: JSONEncoder().encode(layout))
        #expect(back == layout)
        let old = try JSONDecoder().decode(DeckLayout.self, from: JSONEncoder().encode(WindowPlaceTests.layout()))
        #expect(old.apart == nil)
    }

    @Test("a place apart goes when it is closed, with the last of its plugin's windows on the board, or with its tab")
    func gone() throws {
        var layout = Self.layout()
        let apartMade = layout.openApart(from: WindowPlaceTests.id, in: .window)
        let apart = try #require(apartMade)
        let removed = layout.removeApart(apart)
        let twice = layout.removeApart(apart)
        #expect(removed?.id == apart)
        #expect(layout.apart == nil && twice == nil)

        let secondMade = layout.openApart(from: WindowPlaceTests.id, in: .mini)
        let second = try #require(secondMade)
        layout.removeWindow(WindowPlaceTests.id, from: layout.tabs[0].id)
        #expect(!layout.isApart(second), "its plugin has no window on the board left")

        var again = Self.layout()
        let thirdMade = again.openApart(from: WindowPlaceTests.id, in: .mini)
        let third = try #require(thirdMade)
        again.removeWindows([WindowPlaceTests.id])
        #expect(!again.isApart(third))

        var tabbed = Self.layout()
        _ = tabbed.addTab(named: "Second")
        let fourthMade = tabbed.openApart(from: WindowPlaceTests.id, in: .tab)
        let fourth = try #require(fourthMade)
        tabbed.removeTab(tabbed.tabs[0].id)
        #expect(!tabbed.isApart(fourth))
    }

    @Test("read from a file: a place apart whose plugin is not on the board, or that claims a cell, is dropped; a shared id is renumbered")
    func normalized() throws {
        var layout = Self.layout()
        let apartMade = layout.openApart(from: WindowPlaceTests.id, in: .window)
        let apart = try #require(apartMade)
        var stray = GridWindow(pluginID: PluginIdentifier(rawValue: "gone")!, column: 0, row: 0, width: 1, height: 1)
        stray.place = .mini
        var cell = GridWindow(pluginID: Self.agents, column: 0, row: 0, width: 1, height: 1)
        cell.place = .card
        var twin = GridWindow(id: apart, pluginID: Self.agents, column: 0, row: 0, width: 1, height: 1)
        twin.place = .mini
        layout.apart = (layout.apart ?? []) + [stray, cell, twin]
        let read = layout.normalized()
        #expect(read.apart?.count == 2)
        #expect(Set(read.apart?.map(\.id) ?? []).count == 2, "each has its own id")
        #expect(read.apart?.allSatisfy { $0.pluginID == Self.agents && $0.place.isAway } == true)
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
