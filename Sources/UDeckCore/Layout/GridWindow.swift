import CoreGraphics
import Foundation

/// One window in a tab's grid.
///
/// Position and size are in grid cells, never in points: the panel is a
/// different width on every screen, and a layout expressed in points would be
/// wrong the moment the operator undocks.
public struct GridWindow: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID

    /// Which plugin supplies this window's content.
    public var pluginID: PluginIdentifier

    /// Leftmost column, `0 ..< columns`.
    public var column: Int

    /// Topmost row. Rows are unbounded downward; the panel scrolls.
    public var row: Int

    /// Width in columns, at least 1.
    public var width: Int

    /// Height in row units, at least 1.
    public var height: Int

    /// An operator-supplied title, overriding the plugin's own.
    public var title: String?

    /// Where the window is shown, by name (`place`): nil for its cell. Kept
    /// as written, so that a place a later uDeck adds reads here as the cell
    /// rather than failing the whole layout.
    public var shownIn: String?

    /// Where its own window, and its mini window, were last on the screen —
    /// by the place's name, x, y, width and height in points, the origin
    /// bottom-left as AppKit counts — so that each opens there again. A mini
    /// window is not the size of a window. Nil until it has been shown so.
    public var placeFrames: [String: [Double]]?

    /// What its plugin last said the window shows, in a string of the
    /// plugin's own (`CardPlace.keep`): handed back when the plugin starts
    /// again, and carried to a place of its own when the thing is sent there.
    public var keep: String?

    /// What it shows, by the plugin's name for it (`CardPlace.name`): the
    /// title of its window and of its tab.
    public var showing: String?

    /// Where it was last on the screen shown in `place`.
    public func frame(in place: WindowPlace) -> [Double]? {
        placeFrames?[place.rawValue]
    }

    public init(
        id: UUID = UUID(),
        pluginID: PluginIdentifier,
        column: Int,
        row: Int,
        width: Int,
        height: Int,
        title: String? = nil
    ) {
        self.id = id
        self.pluginID = pluginID
        self.column = column
        self.row = row
        self.width = width
        self.height = height
        self.title = title
    }

    /// Where the window is shown: its cell on the board, a whole tab of the
    /// panel, a window of its own, or a mini window above every other.
    public var place: WindowPlace {
        get { shownIn.flatMap(WindowPlace.init(rawValue:)) ?? .card }
        set { shownIn = newValue == .card ? nil : newValue.rawValue }
    }

    public var columnRange: Range<Int> { column ..< (column + width) }
    public var rowRange: Range<Int> { row ..< (row + height) }

    public func overlaps(_ other: GridWindow) -> Bool {
        columnRange.overlaps(other.columnRange) && rowRange.overlaps(other.rowRange)
    }

    /// The window's frame in points, given the panel's content width.
    public func frame(contentWidth: CGFloat, columns: Int, rowHeight: CGFloat, spacing: CGFloat) -> CGRect {
        let columnWidth = (contentWidth - spacing * CGFloat(columns - 1)) / CGFloat(columns)
        let x = CGFloat(column) * (columnWidth + spacing)
        let y = CGFloat(row) * (rowHeight + spacing)
        let w = CGFloat(width) * columnWidth + CGFloat(width - 1) * spacing
        let h = CGFloat(height) * rowHeight + CGFloat(height - 1) * spacing
        return CGRect(x: x, y: y, width: w, height: h)
    }
}

/// Where a window of the board is shown. The plugin is told the size it has
/// there and draws for it.
public enum WindowPlace: String, Codable, Sendable, CaseIterable {
    /// Its cell on the board, as always.
    case card
    /// A whole tab of the panel, named after it; its cell says where it went.
    case tab
    /// An ordinary window of its own; closing it brings the card back.
    case window
    /// A small window above every other, full-screen apps' too, that takes
    /// the keyboard only when clicked; closing it brings the card back.
    case mini

    /// Whether it is shown away from its cell, which then says where it went.
    public var isAway: Bool { self != .card }

    /// Whether it is shown in a window of uDeck's own outside the panel.
    public var isOwnWindow: Bool { self == .window || self == .mini }
}

/// A size in cells of the board.
public struct CellSize: Equatable, Sendable {
    public var columns: Int
    public var rows: Int

    public init(columns: Int, rows: Int) {
        self.columns = columns
        self.rows = rows
    }

    /// The cells `points` hold, one column `columnWidth` wide and one row
    /// `rowHeight` high, `spacing` between them: whole cells, at least one.
    public static func of(_ points: CGSize, columnWidth: CGFloat, rowHeight: CGFloat, spacing: CGFloat) -> CellSize {
        func cells(_ length: CGFloat, _ cell: CGFloat) -> Int {
            guard cell > 0, length.isFinite else { return 1 }
            return max(1, Int(((length + spacing) / (cell + spacing)).rounded(.down)))
        }
        return CellSize(columns: cells(points.width, columnWidth), rows: cells(points.height, rowHeight))
    }
}
