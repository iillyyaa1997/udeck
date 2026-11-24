import CoreGraphics
import Foundation
import UDeckCore

extension DeckModel {
    /// Shows the window with `id` in `place` — its cell on the board, a whole
    /// tab, a window of its own or a mini window — or, shown there already,
    /// brings it to the front.
    public func show(_ id: UUID, in place: WindowPlace) {
        guard layout.show(id, in: place) else {
            if place == .tab { tabShown = id }
            if place.isAway { onBringPlaceForward?(id) }
            return
        }
        if !place.isAway { placeSizes[id] = nil }
        if place == .tab { tabShown = id } else if tabShown == id { tabShown = nil }
        DeckLog.plugins.info("window \(id.uuidString, privacy: .public) shown as \(place.rawValue, privacy: .public)")
        saveLayout()
        if place.isAway { onBringPlaceForward?(id) }
        // A card in a window of its own keeps the plugins polling with the
        // panel away, and its plugin is told its new size: both start here.
        restartPolling()
    }

    /// Where the window with `id` was last on the screen, shown in a window
    /// of its own or a mini window: where it opens next time.
    public func remember(frame: CGRect, of id: UUID, in place: WindowPlace) {
        let before = layout.window(withID: id)?.window.placeFrames
        layout.remember(frame: frame, of: id, in: place)
        guard layout.window(withID: id)?.window.placeFrames != before else { return }
        saveLayout()
    }

    /// The size the window with `id` has where it is shown away from its
    /// cell, in points: its plugin is told it in cells when that changes.
    public func placeHas(_ points: CGSize, theme: DeckTheme, for id: UUID) {
        let size = CellSize.of(points, columnWidth: gridColumnWidth, rowHeight: theme.gridRowHeight,
                               spacing: theme.gridSpacing)
        guard placeSizes[id] != size else { return }
        placeSizes[id] = size
        restartResidents()
    }

    /// The board was drawn `width` points to a column: what a window shown
    /// elsewhere is measured in.
    func boardColumnWidth(_ width: CGFloat) {
        guard width > 0, abs(width - gridColumnWidth) >= 1 else { return }
        gridColumnWidth = width
    }

    /// The look a window of uDeck's own shows a card in: the open panel's.
    public var placeTheme: DeckTheme {
        DeckTheme(density: settings.density,
                  look: settings.look(for: IslandState(phase: .open, surrounding: .ordinary)),
                  textSize: settings.resolvedTextSize)
    }
}
