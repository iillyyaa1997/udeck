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
        layout.remember(frame: CGRect(x: 1200, y: 80, width: 320, height: 200), of: Self.id)
        let back = try JSONDecoder().decode(DeckLayout.self, from: JSONEncoder().encode(layout))
        #expect(back == layout)
        #expect(back.window(withID: Self.id)?.window.placeFrame == [1200, 80, 320, 200])
    }

    @Test("a place this uDeck does not know reads as the cell, and a layout without places reads as before")
    func lenient() throws {
        var window = Self.layout().tabs[0].windows[0]
        window.shownIn = "hologram"
        #expect(window.place == .card)
        let old = #"{"id":"00000000-0000-0000-0000-000000000001","pluginID":"agents","column":0,"row":0,"width":2,"height":3}"#
        let read = try JSONDecoder().decode(GridWindow.self, from: Data(old.utf8))
        #expect(read.place == .card && read.placeFrame == nil)
    }

    @Test("only a window or a mini window is a window of uDeck's own")
    func kinds() {
        #expect(WindowPlace.allCases.filter(\.isOwnWindow) == [.window, .mini])
        #expect(WindowPlace.allCases.filter(\.isAway) == [.tab, .window, .mini])
    }
}
