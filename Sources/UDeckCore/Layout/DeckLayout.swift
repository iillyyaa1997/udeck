import Foundation

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
    public static let defaultColumns = 12

    /// The tallest a single window may be, in row units.
    ///
    /// Not a taste judgement — a bound. A resize drag turns pointer movement
    /// into cells, and without a ceiling a single flick downwards could ask for
    /// a window thousands of rows tall, which the grid would dutifully lay out.
    /// Twenty-four rows is well past the height of any panel on any screen.
    public static let maximumWindowHeight = 24

    public var version: Int
    public var columns: Int
    public var tabs: [DeckTab]
    public var selectedTabID: UUID?

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

    public mutating func removeWindow(_ windowID: UUID, from tabID: UUID) {
        guard let index = index(ofTab: tabID) else { return }
        tabs[index].windows.removeAll { $0.id == windowID }
        tabs[index].windows = GridEngine.normalized(tabs[index].windows, columns: columns)
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

    /// Drops every window belonging to a plugin that is no longer installed.
    ///
    /// Called after discovery, so that uninstalling a plugin does not leave a
    /// window that can never render. Returns the ids that were removed so the
    /// caller can tell the operator rather than making it look like the layout
    /// quietly changed on its own.
    @discardableResult
    public mutating func pruneWindows(keepingPlugins installed: Set<PluginIdentifier>) -> [PluginIdentifier] {
        var removed: Set<PluginIdentifier> = []
        for tabIndex in tabs.indices {
            let before = tabs[tabIndex].windows
            let kept = before.filter { installed.contains($0.pluginID) }
            if kept.count != before.count {
                removed.formUnion(before.filter { !installed.contains($0.pluginID) }.map(\.pluginID))
                tabs[tabIndex].windows = GridEngine.normalized(kept, columns: columns)
            }
        }
        return removed.sorted()
    }

    /// Brings a decoded layout into a legal state: a positive column count, at
    /// least one tab, a valid selection, and grids that obey the rules.
    public func normalized() -> DeckLayout {
        var result = self
        result.columns = max(1, columns)
        if result.tabs.isEmpty { result.tabs = [DeckTab(name: "Now")] }
        for index in result.tabs.indices {
            result.tabs[index].windows = GridEngine.normalized(
                result.tabs[index].windows, columns: result.columns
            )
        }
        if result.selectedTabID == nil || !result.tabs.contains(where: { $0.id == result.selectedTabID }) {
            result.selectedTabID = result.tabs.first?.id
        }
        return result
    }
}
