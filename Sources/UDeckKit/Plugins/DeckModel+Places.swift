import CoreGraphics
import Foundation
import UDeckCore

extension DeckModel {
    /// Shows the window with `id` in `place` — its cell on the board, a whole
    /// tab, a window of its own or a mini window — or, shown there already,
    /// brings it to the front.
    ///
    /// A window on its cell whose plugin says what it shows there (`keep`)
    /// stays, and that thing goes to a place of its own (`openApart`); a
    /// place apart sent back to the board closes, and what it showed comes
    /// back to the plugin's window there.
    public func show(_ id: UUID, in place: WindowPlace) {
        if layout.isApart(id), place == .card {
            closeApart(id, back: true)
            return
        }
        if place.isAway, sendsApart(id), let apart = layout.openApart(from: id, in: place) {
            DeckLog.plugins.info("window \(id.uuidString, privacy: .public) sent what it shows to a \(place.rawValue, privacy: .public) of its own")
            if place == .tab { tabShown = apart }
            saveLayout()
            onBringPlaceForward?(apart)
            restartPolling()
            return
        }
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

    /// Whether the place menu of the window `id` sends what it shows to a
    /// place of its own, rather than the whole card: a window on its cell
    /// whose running plugin names its places and says what this one shows.
    public func sendsApart(_ id: UUID) -> Bool {
        guard let window = layout.window(withID: id)?.window, !layout.isApart(id), window.place == .card,
              window.keep != nil else { return false }
        return speaksOfPlaces(window.pluginID)
    }

    /// What the place menu of `window` is about, by name: the thing it shows
    /// when that is what moves, nil when the whole card does.
    public func placeMenuSubject(of window: GridWindow) -> String? {
        guard layout.isApart(window.id) || sendsApart(window.id) else { return nil }
        return window.showing
    }

    /// The window or place `id` was closed by the person — its own window's
    /// close button: a window of the board goes back to its cell, a place
    /// apart goes, what it showed staying with the plugin.
    public func closePlace(_ id: UUID) {
        if layout.isApart(id) {
            closeApart(id, back: false)
        } else {
            show(id, in: .card)
        }
    }

    /// Takes the place apart `id` away. With `back`, what it showed comes
    /// back to its plugin's window on the board — the one on the tab shown,
    /// or the first.
    func closeApart(_ id: UUID, back: Bool) {
        guard let gone = layout.removeApart(id) else { return }
        let board = layout.views(of: gone.pluginID).filter { !layout.isApart($0.id) }
        let selected = layout.selectedTab?.windows.map(\.id) ?? []
        let to = back ? (board.first { selected.contains($0.id) && $0.place == .card } ?? board.first) : nil
        DeckLog.plugins.info("\(gone.pluginID.rawValue, privacy: .public)'s place apart closed\(back ? ", back to the board" : "", privacy: .public)")
        residentPlaceClosed(id, of: gone.pluginID, keep: gone.keep, to: to?.id)
        placeCards[id] = nil
        placeSizes[id] = nil
        if tabShown == id { tabShown = nil }
        if let to, to.place == .card, let tab = layout.window(withID: to.id)?.tabID {
            layout.selectedTabID = tab
        }
        saveLayout()
        restartPolling()
    }

    /// Brings the place `window` is shown in to the front — the panel at its
    /// tab, for one on its cell — when its plugin asks (`show`).
    func bringForward(_ window: GridWindow, tabID: UUID) {
        switch window.place {
        case .card:
            tabShown = nil
            if layout.selectedTabID != tabID {
                layout.selectedTabID = tabID
                saveLayout()
            }
            onRevealPanel?()
        case .tab:
            tabShown = window.id
            onRevealPanel?()
        case .window, .mini:
            onBringPlaceForward?(window.id)
        }
    }

    /// A card a resident plugin printed: for one of its places by name
    /// (`CardPlace.view`), or for its windows on the board. Its first window
    /// on the board draws the plugin's own card, which the island and the
    /// plugin's other windows go by; what each place shows (`keep`) is kept
    /// with it.
    func recordCard(_ card: Card, _ place: CardPlace, of id: PluginIdentifier) {
        let views = layout.views(of: id)
        let named = place.view.flatMap(UUID.init(uuidString:))
        // A place that has gone since: nothing is left to draw it in.
        if place.view != nil, !views.contains(where: { $0.id == named }) { return }
        let target = views.first { $0.id == named }
        if let target, target.id != views.first?.id {
            var snapshot = placeCards[target.id] ?? PluginSnapshot(pluginID: id)
            snapshot.record(card: card, at: Date())
            placeCards[target.id] = snapshot
        } else {
            var snapshot = snapshots[id.rawValue] ?? PluginSnapshot(pluginID: id)
            snapshot.record(card: card, at: Date())
            snapshots[id.rawValue] = snapshot
            // A window that became the first when the one before it went
            // draws the plugin's card now, not the one it had of its own.
            if let first = views.first { placeCards[first.id] = nil }
        }
        guard let keeper = target ?? views.first,
              layout.keep(place.keep, showing: place.name, for: keeper.id) else { return }
        residentKept(place.keep, view: keeper.id, of: id)
        saveLayout()
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

extension DeckModel {
    /// What waits for the person across the cards of running plugins
    /// (`CardAttention`): how many things, and the questions to answer, each
    /// with its plugin — for the island and the peek.
    public var attention: (count: Int, asks: [(plugin: PluginIdentifier, ask: AskRow)]) {
        var count = 0
        var asks: [(plugin: PluginIdentifier, ask: AskRow)] = []
        var seen = Set<String>()
        let cards = snapshots.values.map { ($0.pluginID, $0.card) } + placeCards.values.map { ($0.pluginID, $0.card) }
        for (plugin, card) in cards where liveResidents.contains(plugin) {
            guard let attention = card?.attention, attention.count > 0 else { continue }
            // The same plugin's places say the same thing: counted once.
            guard seen.insert(plugin.rawValue).inserted else { continue }
            count += attention.count
            if let ask = attention.ask { asks.append((plugin, ask)) }
        }
        return (count, asks)
    }
}
