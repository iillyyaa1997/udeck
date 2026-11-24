import SwiftUI
import UDeckCore

/// A tab's windows, laid out on the 12-column grid.
///
/// Positions and sizes are cells, never points: the panel is one width on the
/// laptop screen and another on the external one, and an arrangement stored in
/// points would be wrong the moment the operator undocks. The conversion to
/// points happens here and nowhere else.
struct DeckGridView: View {
    /// The name of the space every drag in the grid is measured in. Shared with
    /// `DeckWindowView`, which is where the gestures actually live.
    static let dragSpace = "deck.grid"

    var model: DeckModel
    var theme: DeckTheme
    var tab: DeckTab
    @Bindable var shell: ShellState

    /// The window being dragged or resized, and where it would land. Held
    /// locally so the grid can preview the move without writing a layout file
    /// on every frame.
    @State private var draft: Draft?
    /// Where the pointer last was over the grid's free space: the cell a
    /// right-click's **Add plugin** puts the plugin at.
    @State private var pointer: CGPoint?
    @Environment(\.strings) private var strings

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
                        if window.place.isAway {
                            // Shown elsewhere: the cell keeps its place and says where it went.
                            AwaySlot(model: model, theme: theme, window: window, title: title(of: window),
                                     onInteract: { shell.onInteract() })
                                .frame(width: metrics.width(cells: placed.width), height: metrics.height(cells: placed.height))
                                .offset(x: metrics.x(column: placed.column), y: metrics.y(row: placed.row))
                        } else {
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
                }
                .frame(
                    maxWidth: .infinity,
                    minHeight: max(geometry.size.height, metrics.height(cells: max(1, totalRows))),
                    alignment: .topLeading
                )
                // The free space between and below the windows: right-clicked,
                // **Add plugin** puts a plugin at the cell under the pointer
                // (0.8.7); a window's own right-click is its own menu. On the
                // grid itself — a transparent layer of its own under the
                // windows made the lab's accessibility walk of the panel end in
                // an exception (run 44263870523; without it, 44263874858, none).
                .contentShape(Rectangle())
                .onContinuousHover(coordinateSpace: .named(DeckGridView.dragSpace)) { phase in
                    if case .active(let point) = phase { pointer = point }
                }
                .contextMenu { addHere(metrics) }
                // The space a drag is measured in, and the reason it is named.
                //
                // A `DragGesture` with no coordinate space reports translation
                // in the space of the view it is attached to — and the view a
                // window's drag is attached to is the window, which moves as the
                // drag snaps it from cell to cell. Every snap therefore changed
                // the number the snap was computed from, by exactly the distance
                // it had just moved, and the window shook between two cells for
                // as long as it was held. Measured against the grid, which does
                // not move, the translation means what it says.
                .coordinateSpace(name: DeckGridView.dragSpace)
                .animation(.easeOut(duration: 0.12), value: draft)
            }
            .scrollIndicators(.never)
            .onAppear { model.boardColumnWidth(metrics.columnWidth) }
            .onChange(of: metrics.columnWidth) { _, width in model.boardColumnWidth(width) }
        }
    }

    /// What a window is called where its cell says it went elsewhere.
    private func title(of window: GridWindow) -> String {
        window.title ?? model.presentation(for: window.pluginID).card?.title
            ?? model.displayManifest(withID: window.pluginID)?.name ?? window.pluginID.rawValue
    }

    @ViewBuilder
    private func addHere(_ metrics: GridMetrics) -> some View {
        let usable = model.plugins.filter { $0.isUsable && $0.manifest != nil }
        if !usable.isEmpty {
            Menu(strings(.controlAddPluginHere)) {
                ForEach(usable, id: \.id) { plugin in
                    Button(model.displayManifest(for: plugin)?.name ?? plugin.folderName) {
                        shell.onInteract()
                        guard let id = plugin.manifest?.id else { return }
                        let cell = pointer.flatMap {
                            GridCell.at(x: $0.x, y: $0.y, columnWidth: metrics.columnWidth, rowHeight: metrics.rowHeight,
                                        spacing: metrics.spacing, columns: metrics.columns)
                        }
                        model.addWindow(pluginID: id, to: tab.id, at: cell)
                    }
                }
            }
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
                min: max(1, hints.minimumHeight), max: DeckLayout.maximumWindowHeight
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
