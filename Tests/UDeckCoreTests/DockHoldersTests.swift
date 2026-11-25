import Testing
@testable import UDeckCore

/// uDeck in the Dock — and so in Cmd+Tab — while any of its windows that a
/// person switches to holds it, and out when the last lets go (11-25).
@Suite("Who keeps uDeck in the Dock")
struct DockHoldersTests {
    @Test("Settings and a card's window each hold it; out only when both let go")
    func lastOneOut() {
        var dock = DockHolders()
        #expect(!dock.inTheDock, "an accessory, as it starts")
        dock.hold("settings")
        dock.hold("places")
        dock.release("settings")
        #expect(dock.inTheDock, "Settings closed with Agents still in its own window: Cmd+Tab still reaches it")
        dock.release("places")
        #expect(!dock.inTheDock)
    }

    @Test("holding twice and letting go once is let go: a holder is one, not a count")
    func oneEach() {
        var dock = DockHolders()
        dock.hold("places")
        dock.hold("places")
        dock.release("places")
        #expect(!dock.inTheDock)
        dock.release("settings")
        #expect(!dock.inTheDock, "letting go of what was never held changes nothing")
    }
}
