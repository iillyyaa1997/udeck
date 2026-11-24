import Foundation
import UDeckPluginFormat

/// One tab: a name and a grid of windows.
public struct DeckTab: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var windows: [GridWindow]

    public init(id: UUID = UUID(), name: String, windows: [GridWindow] = []) {
        self.id = id
        self.name = name
        self.windows = windows
    }
}

/// The whole arrangement: tabs, their windows, and which tab is showing.
///
/// Stored as a file rather than in code so it survives a reinstall and can be
/// copied between machines. Nothing in it refers to points or pixels — a layout
/// written on a 2560pt display has to be right on a 1728pt one.
public struct DeckLayout: Codable, Equatable, Sendable {
    /// Twelve, and the same number a manifest's `window.defaultWidth` is held
    /// to — both come from `PluginWindowLimits`.
    public static let defaultColumns = PluginWindowLimits.gridColumns

    /// The tallest a single window may be, in row units.
    ///
    /// Not a taste judgement — a bound. A resize drag turns pointer movement
    /// into cells, and without a ceiling a single flick downwards could ask for
    /// a window thousands of rows tall, which the grid would dutifully lay out.
    /// Twenty-four rows is well past the height of any panel on any screen.
    /// A manifest's `window.defaultHeight` is held to the same number, in the
    /// format itself (`PluginWindowLimits.maximumHeight`).
    public static let maximumWindowHeight = PluginWindowLimits.maximumHeight

    /// The lowest row a window may occupy.
    ///
    /// A bound, not a taste judgement, and for the same reason as the height
    /// ceiling — except that this one arrives from the layout file as well as
    /// from a drag. Far more rows than any panel can show, and small enough
    /// that no arithmetic over it can run away.
    public static let maximumWindowRow = 4096

    public var version: Int
    public var columns: Int
    public var tabs: [DeckTab]
    public var selectedTabID: UUID?

    /// Places of their own that a plugin's things are shown in, apart from
    /// its windows on the board: one session of a conversation in a window,
    /// another in a mini window (`openApart`). They have no cell. Each goes
    /// when it is closed, or with the last of its plugin's windows on the
    /// board. Nil in a layout that never had one.
    public var apart: [GridWindow]?

    public init(
        version: Int = 1,
        columns: Int = DeckLayout.defaultColumns,
        tabs: [DeckTab] = [],
        selectedTabID: UUID? = nil
    ) {
        self.version = version
        self.columns = max(1, columns)
        self.tabs = tabs
        self.selectedTabID = selectedTabID ?? tabs.first?.id
    }

    /// An install with no plugins yet.
    ///
    /// One empty tab, deliberately: an app whose every feature arrives as a
    /// plugin spends its first minutes with nothing to show, and that state has
    /// to look like an invitation rather than a failure. A layout with no tabs
    /// at all would leave nowhere to drop the first plugin into.
    public static func firstRun() -> DeckLayout {
        let tab = DeckTab(name: "Now")
        return DeckLayout(tabs: [tab], selectedTabID: tab.id)
    }

    public var selectedTab: DeckTab? {
        guard let selectedTabID else { return tabs.first }
        return tabs.first { $0.id == selectedTabID } ?? tabs.first
    }

    public func index(ofTab id: UUID) -> Int? { tabs.firstIndex { $0.id == id } }

    // MARK: - Mutations

    public mutating func addTab(named name: String) -> UUID {
        let tab = DeckTab(name: name)
        tabs.append(tab)
        selectedTabID = tab.id
        return tab.id
    }

    public mutating func renameTab(_ id: UUID, to name: String) {
        guard let index = index(ofTab: id) else { return }
        tabs[index].name = name
    }

    /// Removes a tab, and moves the selection to a neighbour rather than to
    /// nothing.
    public mutating func removeTab(_ id: UUID) {
        guard let index = index(ofTab: id) else { return }
        tabs.remove(at: index)
        if selectedTabID == id {
            selectedTabID = tabs.indices.contains(index) ? tabs[index].id : tabs.last?.id
        }
        pruneApart()
    }

    public mutating func moveTab(from source: Int, to destination: Int) {
        guard tabs.indices.contains(source), destination >= 0, destination <= tabs.count else { return }
        let tab = tabs.remove(at: source)
        tabs.insert(tab, at: min(destination, tabs.count))
    }

    /// Adds a window for a plugin to a tab, in the first free slot.
    @discardableResult
    public mutating func addWindow(
        pluginID: PluginIdentifier,
        to tabID: UUID,
        hints: WindowHints = WindowHints()
    ) -> UUID? {
        guard let index = index(ofTab: tabID) else { return nil }
        let slot = GridEngine.firstFreeSlot(
            width: hints.defaultWidth,
            height: hints.defaultHeight,
            in: tabs[index].windows,
            columns: columns
        )
        let window = GridWindow(
            pluginID: pluginID,
            column: slot.column,
            row: slot.row,
            width: hints.defaultWidth,
            height: hints.defaultHeight
        )
        tabs[index].windows.append(window)
        tabs[index].windows = GridEngine.normalized(tabs[index].windows, columns: columns)
        return window.id
    }

    /// `addWindow`, put where the operator asked — the cell they right-clicked
    /// (0.8.7): its column as given, kept inside the grid for the window's
    /// width, and its row as given, the window then settling upward as every
    /// window does (`place`).
    @discardableResult
    public mutating func addWindow(
        pluginID: PluginIdentifier,
        to tabID: UUID,
        hints: WindowHints = WindowHints(),
        at cell: GridCell?
    ) -> UUID? {
        guard let id = addWindow(pluginID: pluginID, to: tabID, hints: hints) else { return nil }
        if let cell {
            let width = min(max(1, hints.defaultWidth), columns)
            place(windowID: id, in: tabID, column: min(max(0, cell.column), columns - width), row: max(0, cell.row))
        }
        return id
    }

    public mutating func removeWindow(_ windowID: UUID, from tabID: UUID) {
        guard let index = index(ofTab: tabID) else { return }
        tabs[index].windows.removeAll { $0.id == windowID }
        tabs[index].windows = GridEngine.normalized(tabs[index].windows, columns: columns)
        pruneApart()
    }

    /// Places a window at a new position and/or size, pushing the neighbours out
    /// of the way and letting everything settle upward.
    public mutating func place(
        windowID: UUID,
        in tabID: UUID,
        column: Int,
        row: Int,
        width: Int? = nil,
        height: Int? = nil
    ) {
        guard let tabIndex = index(ofTab: tabID),
              let windowIndex = tabs[tabIndex].windows.firstIndex(where: { $0.id == windowID })
        else { return }

        tabs[tabIndex].windows[windowIndex].column = column
        tabs[tabIndex].windows[windowIndex].row = row
        if let width { tabs[tabIndex].windows[windowIndex].width = width }
        if let height { tabs[tabIndex].windows[windowIndex].height = height }

        tabs[tabIndex].windows = GridEngine.normalized(
            tabs[tabIndex].windows, columns: columns, pinned: windowID
        )
    }

    /// The window with `id`, wherever it is, and its tab's id — for a place
    /// apart, the tab of its plugin's first window on the board.
    public func window(withID id: UUID) -> (window: GridWindow, tabID: UUID)? {
        for tab in tabs {
            if let window = tab.windows.first(where: { $0.id == id }) { return (window, tab.id) }
        }
        guard let window = apart?.first(where: { $0.id == id }) else { return nil }
        let tab = tabs.first { $0.windows.contains { $0.pluginID == window.pluginID } } ?? tabs.first
        guard let tab else { return nil }
        return (window, tab.id)
    }

    /// Whether `id` is a place apart (`apart`), not a window on the board.
    public func isApart(_ id: UUID) -> Bool {
        apart?.contains { $0.id == id } ?? false
    }

    /// Every place a plugin's card is shown in: its windows on the board, in
    /// the order of the tabs, then its places apart.
    public func views(of pluginID: PluginIdentifier) -> [GridWindow] {
        tabs.flatMap { $0.windows.filter { $0.pluginID == pluginID } } + (apart ?? []).filter { $0.pluginID == pluginID }
    }

    /// Shows the window with `id` in `place`, its cell keeping its place on
    /// the board (`WindowPlace`), or moves a place apart to another place —
    /// never to a cell, which it has none of. Answers whether anything
    /// changed.
    @discardableResult
    public mutating func show(_ id: UUID, in place: WindowPlace) -> Bool {
        for tabIndex in tabs.indices {
            guard let index = tabs[tabIndex].windows.firstIndex(where: { $0.id == id }) else { continue }
            guard tabs[tabIndex].windows[index].place != place else { return false }
            tabs[tabIndex].windows[index].place = place
            return true
        }
        guard place.isAway, let index = apart?.firstIndex(where: { $0.id == id }), apart?[index].place != place else {
            return false
        }
        apart?[index].place = place
        return true
    }

    /// Opens a place of its own, `place`, for what the window `id` on the
    /// board keeps (`GridWindow.keep`): the window stays on its cell, and the
    /// new place starts with the window's size, its `keep` and its name.
    /// Answers the new place's id.
    public mutating func openApart(from id: UUID, in place: WindowPlace) -> UUID? {
        guard place.isAway, let source = tabs.lazy.flatMap(\.windows).first(where: { $0.id == id }) else { return nil }
        var window = GridWindow(pluginID: source.pluginID, column: 0, row: 0, width: source.width, height: source.height)
        window.place = place
        window.keep = source.keep
        window.showing = source.showing
        apart = (apart ?? []) + [window]
        return window.id
    }

    /// Takes the place apart `id` away, and answers it.
    @discardableResult
    public mutating func removeApart(_ id: UUID) -> GridWindow? {
        guard let index = apart?.firstIndex(where: { $0.id == id }) else { return nil }
        let window = apart?.remove(at: index)
        if apart?.isEmpty == true { apart = nil }
        return window
    }

    /// What the plugin says the window or place `id` shows (`GridWindow.keep`,
    /// `showing`). Answers whether that changed.
    @discardableResult
    public mutating func keep(_ keep: String?, showing: String?, for id: UUID) -> Bool {
        func set(_ window: inout GridWindow) -> Bool {
            guard window.keep != keep || window.showing != showing else { return false }
            window.keep = keep
            window.showing = showing
            return true
        }
        for tabIndex in tabs.indices {
            guard let index = tabs[tabIndex].windows.firstIndex(where: { $0.id == id }) else { continue }
            return set(&tabs[tabIndex].windows[index])
        }
        guard let index = apart?.firstIndex(where: { $0.id == id }), var window = apart?[index] else { return false }
        let changed = set(&window)
        apart?[index] = window
        return changed
    }

    /// Where the window with `id` was last on the screen shown in `place` — its
    /// own window or its mini window (`GridWindow.placeFrames`).
    public mutating func remember(frame: CGRect, of id: UUID, in place: WindowPlace) {
        let numbers = [frame.origin.x, frame.origin.y, frame.size.width, frame.size.height].map(Double.init)
        func merge(_ window: inout GridWindow) {
            window.placeFrames = (window.placeFrames ?? [:]).merging([place.rawValue: numbers]) { $1 }
        }
        for tabIndex in tabs.indices {
            guard let index = tabs[tabIndex].windows.firstIndex(where: { $0.id == id }) else { continue }
            merge(&tabs[tabIndex].windows[index])
            return
        }
        guard let index = apart?.firstIndex(where: { $0.id == id }), var window = apart?[index] else { return }
        merge(&window)
        apart?[index] = window
    }

    /// Every window shown away from its cell, in the order of the tabs, then
    /// every place apart.
    public var windowsAway: [GridWindow] {
        tabs.flatMap { $0.windows.filter { $0.place.isAway } } + (apart ?? [])
    }

    /// Places apart go with the last of their plugin's windows on the board,
    /// and none is ever on a cell.
    private mutating func pruneApart() {
        guard let places = apart else { return }
        let placed = Set(tabs.flatMap { $0.windows.map(\.pluginID) })
        let kept = places.filter { placed.contains($0.pluginID) && $0.place.isAway }
        apart = kept.isEmpty ? nil : kept
    }

    /// Takes these windows out, wherever they are, and lets every grid they
    /// were in settle.
    public mutating func removeWindows(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        for tabIndex in tabs.indices where tabs[tabIndex].windows.contains(where: { ids.contains($0.id) }) {
            tabs[tabIndex].windows.removeAll { ids.contains($0.id) }
            tabs[tabIndex].windows = GridEngine.normalized(tabs[tabIndex].windows, columns: columns)
        }
        apart?.removeAll { ids.contains($0.id) }
        pruneApart()
    }

    /// Brings a decoded layout into a legal state: a positive column count, at
    /// least one tab, a valid selection, and grids that obey the rules.
    public func normalized() -> DeckLayout {
        var result = self
        result.columns = max(1, columns)
        if result.tabs.isEmpty { result.tabs = [DeckTab(name: "Now")] }
        result.giveEveryoneTheirOwnIdentity()
        for index in result.tabs.indices {
            result.tabs[index].windows = GridEngine.normalized(
                result.tabs[index].windows, columns: result.columns
            )
        }
        if result.selectedTabID == nil || !result.tabs.contains(where: { $0.id == result.selectedTabID }) {
            result.selectedTabID = result.tabs.first?.id
        }
        result.pruneApart()
        return result
    }

    /// Gives a fresh identifier to any tab or window that shares one with
    /// another.
    ///
    /// Identifiers come from a file the operator can edit, and the README
    /// invites them to move that file between machines — where the obvious way
    /// to clone a tab by hand is to copy its JSON block, which duplicates every
    /// identifier inside it. Everything downstream assumes identifiers are
    /// unique: a duplicate silently loses a window when the grid maps them back
    /// by id, and used to abort the application outright.
    ///
    /// The repair is to renumber rather than to drop. The operator meant to
    /// have two windows; they should get two windows.
    private mutating func giveEveryoneTheirOwnIdentity() {
        var seenTabs = Set<UUID>()
        var seenWindows = Set<UUID>()

        for tabIndex in tabs.indices {
            if !seenTabs.insert(tabs[tabIndex].id).inserted {
                let replacement = UUID()
                if selectedTabID == tabs[tabIndex].id { selectedTabID = replacement }
                tabs[tabIndex].id = replacement
                seenTabs.insert(replacement)
            }
            for windowIndex in tabs[tabIndex].windows.indices {
                if !seenWindows.insert(tabs[tabIndex].windows[windowIndex].id).inserted {
                    let replacement = UUID()
                    tabs[tabIndex].windows[windowIndex].id = replacement
                    seenWindows.insert(replacement)
                }
            }
        }
        for index in (apart ?? []).indices where !seenWindows.insert(apart?[index].id ?? UUID()).inserted {
            let replacement = UUID()
            apart?[index].id = replacement
            seenWindows.insert(replacement)
        }
    }
}

/// Which windows leave the layout, and when.
///
/// **Never because a plugin is missing.** Reading the plugins folder used to
/// drop every window whose plugin was not found, and "not found" included a
/// folder whose manifest did not parse — so a folder replaced in two steps lost
/// its window if the watcher read the folder in between, a typo saved in a
/// manifest lost it too, and so did switching a working copy between branches.
/// A window whose plugin is not there now stays where it is and says so
/// (`PluginPresence`). It goes when the operator removes it, or when the plugin
/// itself is removed through uDeck — and then from every tab.
public enum WindowRule {
    public enum Event: Sendable {
        /// The plugins folder was read and these plugins were found.
        case pluginsFolderRead(found: Set<PluginIdentifier>)
        /// The operator took one window off its tab.
        case removedByOperator(window: UUID)
        /// The plugin was removed through uDeck.
        case pluginRemovedThroughUDeck(PluginIdentifier)
    }

    /// The windows `event` takes out of `layout`.
    public static func windowsToRemove(after event: Event, from layout: DeckLayout) -> Set<UUID> {
        switch event {
        case .pluginsFolderRead:
            return []
        case .removedByOperator(let window):
            return layout.tabs.contains { $0.windows.contains { $0.id == window } } ? [window] : []
        case .pluginRemovedThroughUDeck(let id):
            return Set(layout.tabs.flatMap { $0.windows.filter { $0.pluginID == id }.map(\.id) })
        }
    }
}


/// A cell of the grid: where a click lands, in columns and rows.
public struct GridCell: Equatable, Sendable {
    public var column: Int
    public var row: Int

    public init(column: Int, row: Int) {
        self.column = column
        self.row = row
    }

    /// The cell under a point of the grid — `x`, `y` in points from its
    /// top-left — for columns `columnWidth` wide and rows `rowHeight` high with
    /// `spacing` between them; a point in the gap belongs to the cell before it.
    /// Nil for a point outside the grid's columns or above it.
    public static func at(
        x: Double, y: Double, columnWidth: Double, rowHeight: Double, spacing: Double, columns: Int
    ) -> GridCell? {
        guard x >= 0, y >= 0, columnWidth > 0, rowHeight > 0 else { return nil }
        let column = Int(x / (columnWidth + spacing))
        guard column < columns else { return nil }
        return GridCell(column: column, row: Int(y / (rowHeight + spacing)))
    }
}
