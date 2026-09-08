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

    var body: some View {
        let shape = BottomRoundedRectangle(radius: cornerRadius)
        VisualEffectBackground()
            .overlay(theme.panelTint)
            .clipShape(shape)
            .overlay(shape.strokeBorder(theme.panelBorder, lineWidth: 1))
            .overlay(alignment: .top) {
                // The hairline that makes the top edge read as an edge rather
                // than as a crop.
                Rectangle()
                    .fill(theme.innerHighlight)
                    .frame(height: 1)
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
