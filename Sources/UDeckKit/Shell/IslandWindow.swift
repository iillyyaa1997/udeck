import AppKit
import SwiftUI
import UDeckCore

/// The island on a screen the panel is not currently on.
///
/// uDeck has one panel, and it lives on the screen the gesture last fired on.
/// That used to mean the island lived there too — so opening the panel on the
/// laptop took the island off the game on the other display, which is exactly
/// where it was wanted. The island is not the panel: it is the mark that says
/// the panel is available here, and it belongs on every screen at once.
///
/// So every screen that is not the active one gets one of these: a window the
/// size of the island and nothing more, never interactive, never expanding.
/// The screen the panel *is* on draws its own island, in the same place, from
/// the same view — this is the copy for everywhere else.
@MainActor
final class IslandWindow {
    let panel: DeckPanel
    let shell = ShellState()

    init(content: (ShellState) -> AnyView) {
        panel = DeckPanel(contentRect: NSRect(x: 0, y: 0, width: 185, height: 32))
        let hosting = NSHostingView(rootView: content(shell))
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting

        // It is a mark, not a target. Nothing here ever takes a click, so the
        // window is transparent to the mouse for its whole life.
        panel.ignoresMouseEvents = true
    }

    /// Puts the island where that screen says it goes.
    func place(using geometry: PanelGeometry) {
        let frame = geometry.collapsedFrame
        panel.setFrame(frame, display: true)

        shell.topOverhang = geometry.topOverhang
        shell.screenHasNotch = geometry.screen.hasNotch
        shell.weldedToTopEdge = frame.maxY >= geometry.screen.frame.maxY
        // The window is exactly the island, so the island is the whole of it.
        shell.panelRect = CGRect(origin: .zero, size: frame.size)

        panel.orderFrontRegardless()
    }

    func close() {
        panel.orderOut(nil)
    }
}
