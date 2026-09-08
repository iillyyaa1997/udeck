import AppKit
import SwiftUI

/// The panel's own surface.
///
/// On macOS 26 this is the system's own glass — `NSGlassEffectView`, the same
/// material the system uses for its own panels, which brings its own
/// refraction, its own edge and its own response to whatever is behind it.
/// Nothing here tints it: a material that adjusts itself to the wallpaper stops
/// doing that the moment something is painted over it.
///
/// Before macOS 26 there is no such material, and the panel falls back to a
/// blur with a tint of its own. That fallback needs an edge drawn for it,
/// because a blur has none — which is the whole difference between the two
/// branches below.
struct GlassBackground: View {
    var cornerRadius: CGFloat
    var theme: DeckTheme

    /// Whether the panel's top edge is the screen's top edge.
    ///
    /// When it is, the two lines that normally define that edge have to go. A
    /// border and a highlight along the very top row make the panel read as a
    /// window that happens to be near the corner — which is exactly the thing
    /// the island exists to stop looking like. When the panel hangs below a
    /// notch or a menu bar instead, its top edge is a real edge in the middle
    /// of the screen and needs drawing.
    var weldedToTopEdge: Bool

    var body: some View {
        let shape = BottomRoundedRectangle(radius: cornerRadius)
        if #available(macOS 26, *) {
            LiquidGlassBackground()
                .clipShape(shape)
        } else {
            VisualEffectBackground()
                .overlay(theme.panelTint)
                .clipShape(shape)
                .overlay(
                    // An open path rather than a stroked shape with the top
                    // pushed out of frame by negative padding. That trick did
                    // not work: `clipShape` applied after `padding` clips to
                    // the padded bounds, so the top edge was never removed and
                    // the island kept a hairline across it for as long as the
                    // code claimed otherwise.
                    PanelBorder(radius: cornerRadius, includeTopEdge: !weldedToTopEdge)
                        .stroke(theme.panelBorder, lineWidth: 1)
                )
                .overlay(alignment: .top) {
                    if !weldedToTopEdge {
                        Rectangle()
                            .fill(theme.innerHighlight)
                            .frame(height: 1)
                    }
                }
        }
    }
}

/// The panel hangs from the top of the screen, so its top corners are square:
/// a rounded corner there would read as a floating window that happens to be
/// near the edge, rather than as something attached to it.
struct BottomRoundedRectangle: InsettableShape {
    var radius: CGFloat
    var inset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let r = min(radius, min(rect.width, rect.height) / 2)
        let box = rect.insetBy(dx: inset, dy: inset)
        var path = Path()
        path.move(to: CGPoint(x: box.minX, y: box.minY))
        path.addLine(to: CGPoint(x: box.maxX, y: box.minY))
        path.addLine(to: CGPoint(x: box.maxX, y: box.maxY - r))
        path.addQuadCurve(
            to: CGPoint(x: box.maxX - r, y: box.maxY),
            control: CGPoint(x: box.maxX, y: box.maxY)
        )
        path.addLine(to: CGPoint(x: box.minX + r, y: box.maxY))
        path.addQuadCurve(
            to: CGPoint(x: box.minX, y: box.maxY - r),
            control: CGPoint(x: box.minX, y: box.maxY)
        )
        path.closeSubpath()
        return path
    }

    func inset(by amount: CGFloat) -> BottomRoundedRectangle {
        BottomRoundedRectangle(radius: radius, inset: inset + amount)
    }
}

/// The panel's outline, with the top edge optional. Used only by the
/// pre-macOS 26 fallback; the system glass draws its own.
///
/// Half a point in from every edge, because a one-point stroke centred on the
/// boundary puts half of itself outside the shape, where it is clipped away —
/// leaving a half-strength line on three sides and a full-strength one wherever
/// the clip does not reach.
struct PanelBorder: Shape {
    var radius: CGFloat
    var includeTopEdge: Bool

    func path(in rect: CGRect) -> Path {
        let box = rect.insetBy(dx: 0.5, dy: 0.5)
        let r = min(radius, min(box.width, box.height) / 2)
        var path = Path()
        path.move(to: CGPoint(x: box.minX, y: box.minY))
        path.addLine(to: CGPoint(x: box.minX, y: box.maxY - r))
        path.addQuadCurve(
            to: CGPoint(x: box.minX + r, y: box.maxY),
            control: CGPoint(x: box.minX, y: box.maxY)
        )
        path.addLine(to: CGPoint(x: box.maxX - r, y: box.maxY))
        path.addQuadCurve(
            to: CGPoint(x: box.maxX, y: box.maxY - r),
            control: CGPoint(x: box.maxX, y: box.maxY)
        )
        path.addLine(to: CGPoint(x: box.maxX, y: box.minY))
        if includeTopEdge {
            path.addLine(to: CGPoint(x: box.minX, y: box.minY))
        }
        return path
    }
}

/// Any surface made of the same glass as the panel, in a given shape.
///
/// The panel, and everything the operator puts inside it, is one material —
/// there is no second look for the things in the grid. Before macOS 26 there is
/// no such material at all, and the caller's fill stands in for it.
struct GlassSurface<S: Shape>: View {
    var shape: S
    var fallbackFill: Color

    var body: some View {
        if #available(macOS 26, *) {
            LiquidGlassBackground().clipShape(shape)
        } else {
            shape.fill(fallbackFill)
        }
    }
}

/// The system's glass, unmodified.
///
/// `cornerRadius` is left at zero and the shape comes from the caller's clip
/// instead: the property rounds all four corners, and the panel's top two are
/// square because it is attached to the edge it hangs from.
@available(macOS 26, *)
struct LiquidGlassBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSGlassEffectView {
        let view = NSGlassEffectView()
        view.style = .regular
        view.cornerRadius = 0
        // One deliberate deviation from "the system's glass as it comes": the
        // panel is drawn dark whatever the system is set to, because the theme
        // above it picks text and card colours for a dark ground. Measured on a
        // dark system it changes the result by one step out of 255 — it earns
        // its place in light mode, not here.
        view.appearance = NSAppearance(named: .vibrantDark)
        return view
    }

    func updateNSView(_ view: NSGlassEffectView, context: Context) {}
}

private struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        // The panel is drawn dark whatever the system is set to; see DeckTheme.
        view.appearance = NSAppearance(named: .vibrantDark)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
