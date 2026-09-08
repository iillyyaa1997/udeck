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
