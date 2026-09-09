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
            PanelSurface(shape: shape, fallbackFill: theme.panelTint, glass: glass)
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
            LiquidGlassBackground(glass: glass)
                .padding(-Self.edgeBleed)
                .clipShape(shape)
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
@available(macOS 26, *)
struct LiquidGlassBackground: NSViewRepresentable {
    var glass: GlassAppearance

    func makeNSView(context: Context) -> NSGlassEffectView {
        let view = UnsubduedGlassView()
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
    /// Whether the material can be told not to dim itself in a window that is
    /// not key.
    ///
    /// Read once. Where it is false the shell falls back to making the panel a
    /// key window, which covers the panel and cannot cover the islands — only
    /// one window of an application can be key at a time, and there is one
    /// island per screen.
    @available(macOS 26, *)
    static let canUnsubdue: Bool = NSGlassEffectView().responds(to: Selector(("set_subduedState:")))

    /// The value that means "do not dim".
    ///
    /// Found by measurement rather than by documentation, and got wrong the
    /// first time by measuring each value once: the island on a second display,
    /// with another application frontmost, reads 32/94/136 dimmed and 52/120/165
    /// undimmed, and a single run of each value put those the wrong way round.
    /// Run as an alternating sequence instead, 0 gives the undimmed reading
    /// every time and 2 gives the dimmed one — 2 being what AppKit itself sets
    /// when the window stops being key.
    static let unsubduedState = 0

    private func apply(_ glass: GlassAppearance, to view: NSGlassEffectView) {
        view.style = glass.style == .clear ? .clear : .regular
        // No tint. The system applies one in proportion to something it does
        // not document — below a panel height of about 170 points it applies
        // almost none of it — so the same setting came out as two different
        // colours depending on which state the panel was in. `GlassTint` paints
        // it instead, where it means the same thing at every size.
        view.tintColor = nil
        view.alphaValue = glass.opacity

        // AppKit dims a system material in a window that is not key, and the
        // glass inherits it. That is right for an ordinary window and wrong for
        // this one: the panel's whole job is to be looked at from inside
        // another application, so the state it is dimmed in is the state it is
        // normally seen in — the operator spent an evening reporting it as the
        // panel changing colour when clicked.
        //
        // There is no public way to decline. `_subduedState` is private and is
        // used here deliberately, guarded so that a macOS which removes it
        // degrades to the dimmed look rather than to a crash — and so that the
        // shell knows to fall back to the public workaround. See `canUnsubdue`.
        (view as? UnsubduedGlassView)?.reassert()
    }
}

/// The system's glass, with its own dimming declined.
///
/// AppKit dims a system material in a window that is not key — `NSGlassEffectView`
/// has a `_windowChangedKeyState` and a private `_subduedState` to prove it —
/// and it re-applies that on every change of key or active state. Setting the
/// property once is therefore not enough: it is set, and then the first time
/// the operator clicks away it is set back.
///
/// So the value is re-asserted after each of those events, on the turn of the
/// run loop *after* AppKit's own handling, which is the only ordering that
/// survives it.
///
/// Everything here is guarded on the property existing. A macOS that removes it
/// leaves a view that behaves exactly like the stock one.
@available(macOS 26, *)
final class UnsubduedGlassView: NSGlassEffectView {
    private var tokens: [NSObjectProtocol] = []

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observe()
        reassert()
    }

    /// The one hook that cannot lose the race.
    ///
    /// Re-asserting from the notifications alone left it dimmed about one run
    /// in three: AppKit resets the state as part of handling the key change,
    /// and a re-assertion scheduled for the next turn of the run loop is only
    /// reliably after it when the view already existed to hear the
    /// notification. Drawing happens after every reset, whatever caused it.
    override func viewWillDraw() {
        reassert()
        super.viewWillDraw()
    }

    private func observe() {
        guard tokens.isEmpty else { return }
        let centre = NotificationCenter.default
        let names: [Notification.Name] = [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification,
            NSWindow.didBecomeMainNotification,
            NSWindow.didResignMainNotification,
            NSApplication.didBecomeActiveNotification,
            NSApplication.didResignActiveNotification,
        ]
        for name in names {
            tokens.append(centre.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                // After AppKit has had its turn, not during it.
                DispatchQueue.main.async { self?.reassert() }
            })
        }
    }

    /// Says again what was already said, because something said otherwise.
    func reassert() {
        guard LiquidGlassBackground.canUnsubdue else { return }
        // Only when it has actually been changed back: setting a property to
        // what it already holds is cheap, but this runs before every draw and
        // KVC on a private property is not free.
        guard value(forKey: "_subduedState") as? Int != LiquidGlassBackground.unsubduedState else { return }
        setValue(LiquidGlassBackground.unsubduedState, forKey: "_subduedState")
    }

    // No `deinit` unregistration: the block-based observers are held by the
    // centre for the life of the process, and this view lives as long as the
    // panel does — one per window, made once. Reaching into the array from a
    // nonisolated `deinit` is what the compiler objects to, and it would be
    // objecting to a cleanup that has nothing to clean.
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

