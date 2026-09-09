import CoreGraphics
import Foundation

/// How tightly the panel packs its content.
///
/// This is a user setting rather than a design decision: every plugin has to
/// render correctly in all three, which is why the metrics live here in one
/// place instead of being scattered through the views.
public enum Density: String, Codable, CaseIterable, Sendable {
    case compact
    case normal
    case cozy

    public var namePhrase: Phrase {
        switch self {
        case .compact: .densityCompact
        case .normal: .densityNormal
        case .cozy: .densityCozy
        }
    }

    /// Spacing between windows in the grid, in points.
    public var gridSpacing: CGFloat {
        switch self {
        case .compact: 6
        case .normal: 9
        case .cozy: 14
        }
    }

    /// Padding inside the panel, around the whole grid.
    public var panelPadding: CGFloat {
        switch self {
        case .compact: 9
        case .normal: 12
        case .cozy: 16
        }
    }

    /// Padding inside a single window.
    public var windowPadding: CGFloat {
        switch self {
        case .compact: 8
        case .normal: 11
        case .cozy: 15
        }
    }

    /// Vertical gap between rows inside a card.
    public var rowSpacing: CGFloat {
        switch self {
        case .compact: 5
        case .normal: 8
        case .cozy: 11
        }
    }

    /// Height of one grid row unit, in points. A window's height is expressed
    /// in these units, so this is what makes "3 cells tall" a real size.
    public var gridRowHeight: CGFloat {
        switch self {
        case .compact: 34
        case .normal: 42
        case .cozy: 52
        }
    }

    /// Base text size for card body copy.
    public var bodyFontSize: CGFloat {
        switch self {
        case .compact: 11
        case .normal: 12
        case .cozy: 13
        }
    }

    /// Text size for a window's title.
    public var titleFontSize: CGFloat {
        switch self {
        case .compact: 11.5
        case .normal: 12.5
        case .cozy: 14
        }
    }
}
