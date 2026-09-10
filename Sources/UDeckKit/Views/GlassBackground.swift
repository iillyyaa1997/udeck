import AppKit
import SwiftUI
import UDeckCore

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
    var glass: GlassAppearance

    /// Whether uDeck is the active application. See `PanelSurface`.
    var applicationIsActive: Bool

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
            // The same surface the settings screen previews, built in one
            // place so the two cannot drift apart.
            PanelSurface(
                shape: shape, fallbackFill: theme.panelTint, glass: glass,
                applicationIsActive: applicationIsActive
            )
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
/// The panel's surface, whole: the system material with uDeck's own tint on it.
///
/// Used by the panel and by the settings screen's preview, which has to show
/// what the panel will actually look like — it was showing the bare material,
/// so the preview stopped matching the panel the moment the tint moved out of
/// the material and into a layer of our own.
struct PanelSurface<S: Shape>: View {
    var shape: S
    var fallbackFill: Color
    var glass: GlassAppearance

    /// Whether uDeck is the active application.
    ///
    /// The system's glass dims itself in an inactive application, and for this
    /// panel that is backwards: it exists to be looked at from *inside* another
    /// application, so the state it dims in is the state it is normally seen
    /// in. uDeck used to answer that by taking the key window back on every
    /// application switch, which made it grab focus the operator had not given
    /// it — the thing he actually noticed and asked to stop.
    ///
    /// So the material changes instead of the focus. Nothing on
    /// `NSGlassEffectView` carries the dimming — `_subduedState`, `_scrimState`
    /// and `_interactionState` were all measured at 0 in both states, and the
    /// layer tree is identical — so the dimming cannot be pinned and the view
    /// has to be swapped for one that does not do it.
    var applicationIsActive: Bool = true

    /// How far the material is grown before it is cut to the panel's shape.
    ///
    /// The material draws a bright line along its own edge — that is what a
    /// lens does, and it is the rim the operator has been reporting. Measured
    /// over a striped backdrop on the settled panel, the last row reads 22.5 %
    /// brighter than the interior, and it reads 22.5 % brighter with the tint
    /// turned off too: the tint is a flat multiplier over the whole panel, so
    /// the rim is in the glass and nowhere else.
    ///
    /// A line drawn at the edge of the material cannot be turned off, so the
    /// material is made bigger than the panel and cut back to it. The clip
    /// passes through the middle of the material instead of along its edge, and
    /// the edge — with its line — falls outside and is never drawn. The panel's
    /// own shape is untouched, so the corners are still the ones he chose
    /// rather than the ones the material would round for itself.
    private static var edgeBleed: CGFloat { 2 }

    var body: some View {
        if #available(macOS 26, *) {
            // Each layer is clipped on its own, and the tint is a filled path
            // rather than a rectangle behind a mask.
            //
            // Overlaying the tint and then clipping the pair is the shorter way
            // to write it, and it asks the compositor to gather both layers
            // into an offscreen buffer and mask the result on every frame of
            // every reveal — work that does not show up in this process's CPU
            // time at all, which is exactly what makes it worth avoiding by
            // construction rather than by measurement.
            ZStack {
                // Both are kept and crossfaded rather than swapped outright: a
                // material appearing where another one was is a visible jump,
                // and this happens every time the operator clicks away.
                SteadyGlassBackground(glass: glass)
                    .padding(-Self.edgeBleed)
                    .clipShape(shape)
                    .opacity(applicationIsActive ? 0 : 1)

                LiquidGlassBackground(glass: glass)
                    .padding(-Self.edgeBleed)
                    .clipShape(shape)
                    .opacity(applicationIsActive ? 1 : 0)
            }
            .animation(.easeInOut(duration: 0.18), value: applicationIsActive)
            .overlay { GlassTint(glass: glass, shape: shape) }
        } else {
            shape.fill(fallbackFill).opacity(glass.opacity)
        }
    }
}

/// The tint, as a layer uDeck draws itself.
///
/// It used to be handed to `NSGlassEffectView.tintColor`, which is the obvious
/// way to do it and the reason the panel had two colours. The system applies a
/// tint in proportion to something it does not document and, below a panel
/// height of about 170 points, very nearly not at all: measured over the
/// running panel, the open panel took the tint fully (184/255 over a desktop of
/// 27) while the peek did not (58 over a desktop of 64). One setting, two
/// results, and no way to ask for the one the operator chose.
///
/// Painted here it is exactly the colour and strength that was asked for, at
/// every size, in every state, over every surface. The cost is real and worth
/// stating: a tint of the material's own adjusts itself to what is behind the
/// panel, and a layer painted on top does not. That adjustment is what the
/// operator was being offered instead of the colour he set, so it is not a
/// trade — it is the same thing, done where it can be relied on.
struct GlassTint<S: Shape>: View {
    var glass: GlassAppearance
    var shape: S

    var body: some View {
        if let tint = glass.tintComponents {
            shape.fill(Color(PaletteColor(tint.color, alpha: tint.alpha * glass.opacity)))
        }
    }
}

/// The system's glass, unmodified.
///
/// `cornerRadius` is left at zero and the shape comes from the caller's clip
/// instead: the property rounds all four corners, and the panel's top two are
/// square because it is attached to the edge it hangs from.
/// The material uDeck draws when it is not the active application.
///
/// `NSVisualEffectView` is the previous generation of the same idea, and it has
/// the one knob the new one does not: `state`. Pinned to `.active` it stops
/// following the window's activation and keeps blurring whatever is behind it
/// whoever is in front. It is not the same picture — the system's glass
/// refracts and this only blurs — which is why it is used for the state the
/// panel is *glanced* at in and not the state it is worked in.
///
/// `.hudWindow` is the closest of the stock materials, and it is the one the
/// pre-macOS-26 path already uses, so the two agree.
struct SteadyGlassBackground: NSViewRepresentable {
    var glass: GlassAppearance

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        // The panel is drawn dark whatever the system is set to; see DeckTheme.
        view.appearance = NSAppearance(named: .vibrantDark)
        apply(glass, to: view)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        apply(glass, to: view)
    }

    private func apply(_ glass: GlassAppearance, to view: NSVisualEffectView) {
        // The same meaning `opacity` has for the glass: at zero there is no
        // material left and the content floats over whatever is behind it.
        view.alphaValue = glass.opacity
    }
}

@available(macOS 26, *)
struct LiquidGlassBackground: NSViewRepresentable {
    var glass: GlassAppearance

    func makeNSView(context: Context) -> NSGlassEffectView {
        let view = NSGlassEffectView()
        apply(glass, to: view)
        view.cornerRadius = 0
        // One deliberate deviation from "the system's glass as it comes": the
        // panel is drawn dark whatever the system is set to, because the theme
        // above it picks text and card colours for a dark ground. Measured on a
        // dark system it changes the result by one step out of 255 — it earns
        // its place in light mode, not here.
        view.appearance = NSAppearance(named: .vibrantDark)
        return view
    }

    func updateNSView(_ view: NSGlassEffectView, context: Context) {
        apply(glass, to: view)
    }

    /// The material has no opacity of its own — `style`, `tintColor` and
    /// `cornerRadius` are the whole of its API — so "less glass" has to be the
    /// view's own alpha. At zero there is no material left and the panel's
    /// content floats over whatever is behind it, which is what "fully
    /// transparent" has to mean when the thing being made transparent is a
    /// material rather than a fill.
    private func apply(_ glass: GlassAppearance, to view: NSGlassEffectView) {
        view.style = glass.style == .clear ? .clear : .regular
        // No tint. The system applies one in proportion to something it does
        // not document — below a panel height of about 170 points it applies
        // almost none of it — so the same setting came out as two different
        // colours depending on which state the panel was in. `GlassTint` paints
        // it instead, where it means the same thing at every size.
        view.tintColor = nil
        view.alphaValue = glass.opacity

        // AppKit dims a system material in an application that is not active,
        // and the glass inherits it. That is right for an ordinary window and
        // wrong for this one: the panel's whole job is to be looked at from
        // inside another application, so the state it is dimmed in is the state
        // it is normally seen in.
        //
        // Nothing is done about it here, and nothing can be. Two sessions of
        // measurement from inside the running application say so: the private
        // `_subduedState`, `_scrimState` and `_interactionState` all read 0 in
        // both states, the layer tree is byte-for-byte the same, and asserting
        // any of them moves nothing. The dimming is inside the material's own
        // drawing. `PanelSurface` swaps the material instead.
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

