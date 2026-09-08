import SwiftUI
import UDeckCore

/// A tab's windows, laid out on the 12-column grid.
///
/// Positions and sizes are cells, never points: the panel is one width on the
/// laptop screen and another on the external one, and an arrangement stored in
/// points would be wrong the moment the operator undocks. The conversion to
/// points happens here and nowhere else.
struct DeckGridView: View {
    var model: DeckModel
    var theme: DeckTheme
    var tab: DeckTab
    @Bindable var shell: ShellState

    /// The window being dragged or resized, and where it would land. Held
    /// locally so the grid can preview the move without writing a layout file
    /// on every frame.
    @State private var draft: Draft?

    private struct Draft: Equatable {
        var id: UUID
        var column: Int
        var row: Int
        var width: Int
        var height: Int
        var isResizing: Bool
    }

    var body: some View {
        GeometryReader { geometry in
            let metrics = GridMetrics(
                contentWidth: geometry.size.width,
                columns: model.layout.columns,
                rowHeight: theme.gridRowHeight,
                spacing: theme.gridSpacing
            )

            ScrollView(.vertical) {
                ZStack(alignment: .topLeading) {
                    ForEach(windows) { window in
                        let placed = draftApplied(to: window)
                        DeckWindowView(
                            model: model,
                            theme: theme,
                            window: window,
                            tabID: tab.id,
                            shell: shell,
                            isMoving: draft?.id == window.id,
                            onDragChanged: { translation in
                                update(window: window, translation: translation, metrics: metrics, resizing: false)
                            },
                            onResizeChanged: { translation in
                                update(window: window, translation: translation, metrics: metrics, resizing: true)
                            },
                            onGestureEnded: commit
                        )
                        .frame(
                            width: metrics.width(cells: placed.width),
                            height: metrics.height(cells: placed.height)
                        )
                        .offset(
                            x: metrics.x(column: placed.column),
                            y: metrics.y(row: placed.row)
                        )
                        .zIndex(draft?.id == window.id ? 1 : 0)
                    }
                }
                .frame(
                    maxWidth: .infinity,
                    minHeight: metrics.height(cells: max(1, totalRows)),
                    alignment: .topLeading
                )
                .animation(.easeOut(duration: 0.12), value: draft)
            }
            .scrollIndicators(.never)
        }
    }

    private var windows: [GridWindow] {
        model.layout.tabs.first { $0.id == tab.id }?.windows ?? []
    }

    private var totalRows: Int {
        windows.map { window in
            let placed = draftApplied(to: window)
            return placed.row + placed.height
        }.max() ?? 1
    }

    /// A window's position, with the in-flight drag applied if it is the one
    /// being moved.
    private func draftApplied(to window: GridWindow) -> (column: Int, row: Int, width: Int, height: Int) {
        guard let draft, draft.id == window.id else {
            return (window.column, window.row, window.width, window.height)
        }
        return (draft.column, draft.row, draft.width, draft.height)
    }

    private func update(window: GridWindow, translation: CGSize, metrics: GridMetrics, resizing: Bool) {
        let columns = model.layout.columns
        let hints = model.plugin(withID: window.pluginID)?.manifest?.window ?? WindowHints()

        if resizing {
            let width = clamp(
                window.width + metrics.columns(forWidth: translation.width),
                min: max(1, hints.minimumWidth), max: columns - window.column
            )
            let height = clamp(
                window.height + metrics.rows(forHeight: translation.height),
                min: max(1, hints.minimumHeight), max: 24
            )
            draft = Draft(id: window.id, column: window.column, row: window.row,
                          width: width, height: height, isResizing: true)
        } else {
            let column = clamp(
                window.column + metrics.columns(forWidth: translation.width),
                min: 0, max: columns - window.width
            )
            let row = max(0, window.row + metrics.rows(forHeight: translation.height))
            draft = Draft(id: window.id, column: column, row: row,
                          width: window.width, height: window.height, isResizing: false)
        }
    }

    private func commit() {
        guard let draft else { return }
        shell.onInteract()
        model.place(
            windowID: draft.id, in: tab.id,
            column: draft.column, row: draft.row,
            width: draft.width, height: draft.height
        )
        self.draft = nil
    }

    private func clamp(_ value: Int, min lower: Int, max upper: Int) -> Int {
        Swift.min(Swift.max(value, lower), Swift.max(lower, upper))
    }
}

/// Converts between cells and points. One place, so the grid and the drag
/// arithmetic can never disagree about where a cell is.
struct GridMetrics {
    var contentWidth: CGFloat
    var columns: Int
    var rowHeight: CGFloat
    var spacing: CGFloat

    var columnWidth: CGFloat {
        max(1, (contentWidth - spacing * CGFloat(columns - 1)) / CGFloat(columns))
    }

    func x(column: Int) -> CGFloat { CGFloat(column) * (columnWidth + spacing) }
    func y(row: Int) -> CGFloat { CGFloat(row) * (rowHeight + spacing) }
    func width(cells: Int) -> CGFloat { CGFloat(cells) * columnWidth + CGFloat(cells - 1) * spacing }
    func height(cells: Int) -> CGFloat { CGFloat(cells) * rowHeight + CGFloat(cells - 1) * spacing }

    /// How many whole columns a horizontal drag covers. Rounding rather than
    /// truncating means a window follows the cursor instead of lagging half a
    /// cell behind it.
    func columns(forWidth width: CGFloat) -> Int {
        Int((width / (columnWidth + spacing)).rounded())
    }

    func rows(forHeight height: CGFloat) -> Int {
        Int((height / (rowHeight + spacing)).rounded())
    }
}
