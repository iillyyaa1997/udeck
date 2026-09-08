import AppKit
import SwiftUI

/// The panel's own surface: a real system blur, tinted, with a defined edge.
///
/// macOS 26 made the menu bar translucent, so a panel can no longer borrow a
/// dark bar to sit against — whatever is behind it is the wallpaper. It has to
/// bring its own ground, which is what the tint over the blur is for.
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
        VisualEffectBackground()
            .overlay(theme.panelTint)
            .clipShape(shape)
            .overlay(
                shape
                    .strokeBorder(theme.panelBorder, lineWidth: 1)
                    // Pull the stroke up out of frame so the sides and the
                    // rounded bottom keep their edge and the top loses its.
                    .padding(.top, weldedToTopEdge ? -2 : 0)
                    .clipShape(shape)
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
