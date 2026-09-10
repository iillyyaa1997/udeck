import AppKit

/// The mark uDeck puts in the menu bar, drawn rather than shipped.
///
/// A template image the menu bar tints itself, so only the silhouette matters —
/// and the silhouette is `ū`: the first letter of the name and the bar the
/// panel hangs from, which happen to be the same shape. The system's
/// `rectangle.topthird.inset.filled` that was here before is a rectangle with a
/// stripe: accurate, and indistinguishable from every other rectangle in the
/// menu bar.
///
/// Drawn at whatever size it is asked for rather than kept as a PNG, because
/// the menu bar's height is not a constant — it changes with the display, and a
/// bitmap picked for one of them is soft on the others.
public enum StatusGlyph {
    /// The height AppKit gives a menu-bar image. Everything else is a fraction
    /// of it, so the mark scales as one shape rather than as a set of parts.
    public static let standardSize: CGFloat = 18

    /// - Parameter warning: draws the dot that says a plugin will not run.
    ///   Part of the same mark rather than a different symbol: an icon that
    ///   changes shape when something is wrong reads as a different
    ///   application, and the operator has to learn two silhouettes instead of
    ///   noticing one dot.
    public static func image(size: CGFloat = standardSize, warning: Bool = false) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return true }
            draw(in: ctx, size: size, warning: warning)
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func draw(in ctx: CGContext, size s: CGFloat, warning: Bool) {
        // The mark is *scaled*, not redrawn. The first attempt to make it
        // bigger moved the corners instead, and moving corners changes
        // proportions: the letter came out wider and longer than the one that
        // had been chosen. So the geometry below is the original, and `scale`
        // is applied to the whole thing about its own centre — the shape cannot
        // drift, because there is nothing left to drift.
        //
        // 1.5 puts it at the cap height its neighbours in the menu bar use. At
        // 1.0 it filled a little under half the box and read as somebody else's
        // icon shrunk.
        let scale: CGFloat = 1.5

        ctx.saveGState()
        defer { ctx.restoreGState() }
        let centre = CGPoint(x: s * 0.5, y: s * 0.479)
        ctx.translateBy(x: centre.x, y: centre.y)
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -centre.x, y: -centre.y)

        ctx.setStrokeColor(NSColor.black.cgColor)
        ctx.setFillColor(NSColor.black.cgColor)

        // Heavier than a text stroke would be: at this size a hairline
        // disappears into the menu bar's own contrast, and the mark has to
        // survive being the smallest thing on the screen.
        let stroke = s * 0.145
        ctx.setLineWidth(stroke)
        ctx.setLineCap(.round)

        let left = s * 0.29, right = s * 0.71
        let top = s * 0.50, bottom = s * 0.27
        let u = CGMutablePath()
        u.move(to: CGPoint(x: left, y: top))
        u.addLine(to: CGPoint(x: left, y: bottom + s * 0.06))
        u.addArc(tangent1End: CGPoint(x: left, y: bottom),
                 tangent2End: CGPoint(x: s * 0.5, y: bottom), radius: s * 0.11)
        u.addArc(tangent1End: CGPoint(x: right, y: bottom),
                 tangent2End: CGPoint(x: right, y: top), radius: s * 0.11)
        u.addLine(to: CGPoint(x: right, y: top))
        ctx.addPath(u)
        ctx.strokePath()

        let bar = CGRect(x: left - stroke / 2, y: s * 0.63,
                         width: right - left + stroke, height: stroke * 0.9)
        ctx.addPath(CGPath(roundedRect: bar, cornerWidth: stroke * 0.45,
                           cornerHeight: stroke * 0.45, transform: nil))
        ctx.fillPath()

        guard warning else { return }
        // Punched out of the letter before the dot is drawn, so the dot reads
        // as a separate thing rather than as a bulge on the stroke.
        let dot = CGRect(x: s * 0.62, y: s * 0.17, width: s * 0.24, height: s * 0.24)
        ctx.setBlendMode(.clear)
        ctx.addPath(CGPath(ellipseIn: dot.insetBy(dx: -s * 0.04, dy: -s * 0.04), transform: nil))
        ctx.fillPath()
        ctx.setBlendMode(.normal)
        ctx.addPath(CGPath(ellipseIn: dot, transform: nil))
        ctx.fillPath()
    }
}
