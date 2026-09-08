import CoreGraphics
import Foundation

/// Converting between the two coordinate systems macOS hands out.
///
/// `CGWindowListCopyWindowInfo` reports window bounds in Quartz coordinates —
/// origin at the **top left** of the display that owns the menu bar, `y`
/// growing downward. Everything else uDeck touches is AppKit: origin at that
/// display's **bottom left**, `y` growing upward. The two agree on `x` and
/// disagree on `y`, which is exactly the kind of difference that produces code
/// that looks right and is wrong by the height of a screen.
///
/// This lives here, away from AppKit, because it is arithmetic: the only thing
/// it needs from the window server is one number, and a caller that already has
/// that number can be a test. It used to sit inside the fullscreen detector,
/// where nothing could reach it and nothing did.
public enum QuartzCoordinates {
    /// Converts a rect from Quartz coordinates to AppKit coordinates.
    ///
    /// `mainScreenTop` is `maxY` of the screen whose origin is `(0, 0)` — the
    /// one that owns the menu bar, and the one both systems measure from. Note
    /// that this is *not* the screen the rect is on: a window on a display
    /// arranged above or below the main one has coordinates outside the main
    /// screen's frame in both systems, and the conversion is the same either
    /// way.
    ///
    /// The transform is its own inverse, which is what `appKitRect` and
    /// `quartzRect` being one function means.
    public static func appKitRect(fromQuartz rect: CGRect, mainScreenTop: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: mainScreenTop - rect.maxY, width: rect.width, height: rect.height)
    }

    /// The same conversion in the other direction. Same arithmetic; named
    /// separately so call sites say which way they are going.
    public static func quartzRect(fromAppKit rect: CGRect, mainScreenTop: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: mainScreenTop - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Converts a point from Quartz coordinates to AppKit coordinates.
    ///
    /// A point has no height, so unlike a rect it flips about the coordinate
    /// itself rather than about the far edge. Keeping the two apart is the
    /// point of having both: using the rect rule on a point is off by the
    /// rect's height, which is invisible on a one-point-tall strip and obvious
    /// on a panel.
    public static func appKitPoint(fromQuartz point: CGPoint, mainScreenTop: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: mainScreenTop - point.y)
    }

    public static func quartzPoint(fromAppKit point: CGPoint, mainScreenTop: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: mainScreenTop - point.y)
    }
}

extension CGRect {
    /// Whether two rects are the same to within `tolerance` on every edge.
    ///
    /// Window bounds arrive from the window server as integers while screen
    /// frames can carry a fraction, so an exact comparison between the two
    /// misses by half a point — which, for the fullscreen test that uses this,
    /// would mean never detecting a fullscreen window at all.
    public func isApproximately(_ other: CGRect, within tolerance: CGFloat) -> Bool {
        abs(minX - other.minX) <= tolerance
            && abs(minY - other.minY) <= tolerance
            && abs(width - other.width) <= tolerance
            && abs(height - other.height) <= tolerance
    }
}
