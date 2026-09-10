import SwiftUI
import UDeckCore

/// What the panel shows, in each of its states.
public struct DeckRootView: View {
    @Bindable var shell: ShellState
    var model: DeckModel

    public init(shell: ShellState, model: DeckModel) {
        self.shell = shell
        self.model = model
    }

    public var body: some View {
        let theme = DeckTheme(density: model.settings.density, look: model.settings.look,
                              textSize: model.settings.resolvedTextSize)

        // The window is the stage, sized once per screen; the panel is a
        // rectangle inside it that moves and resizes. Everything around the
        // panel is empty and lets clicks through — see `PanelHostingView`.
        ZStack(alignment: .topLeading) {
            Color.clear

            // The material is drawn at the size of the stage and cut to the
            // shape of the panel, rather than drawn at the size of the panel.
            //
            // `NSGlassEffectView` renders differently depending on how big it
            // is — measured on the running panel at one tint, a 96-point peek
            // came out at 66/255 and a 300-point one at 56, with nothing else
            // changed. Painting the tint ourselves hid that in proportion to
            // the tint's own strength, which is why it came back the moment the
            // operator turned the tint down: "у чёлки одна, а если нажать то
            // другая".
            //
            // A material whose bounds never change cannot render two ways. The
            // panel's state moves the cut, not the thing being cut.
            if PanelChrome.drawsMaterial(
                phase: shell.phase,
                screenHasNotch: shell.screenHasNotch,
                isSettled: shell.isSettled
            ) {
                material(theme: theme)
            }

            panel(theme: theme)
                .frame(
                    width: shell.panelRect.width,
                    height: shell.panelRect.height,
                    alignment: .top
                )
                // Clipped to the rectangle being animated, because the content
                // will not fit inside it and must not be allowed to say so.
                //
                // A `frame` proposes a size; it does not impose one. The peek's
                // text and padding have a minimum height of their own — about
                // 96 points — so at the start of a reveal, with the animated
                // rectangle still the size of the island, the stack reported 96
                // and the material was drawn to match. The width had no such
                // floor and followed the animation, which is why a reveal looked
                // like it began three quarters of the way through: measured
                // frame by frame off a screen recording, the first frame drawn
                // was 369 points wide (the island, 0% of the way) and 189 tall
                // (74%).
                //
                // Clipping here rather than inside `panel` keeps the corners:
                // the shape is the one the panel is drawn with, at the size it
                // is drawn at, so a growing panel is round-bottomed the whole
                // way rather than square until it arrives.
                .clipShape(BottomRoundedRectangle(
                    radius: PanelChrome.cornerRadius(
                        phase: shell.phase, metrics: model.settings.panel
                    )
                ))
                // Outside the clip, because the mark belongs to the panel's
                // bottom edge — the animated one, not the one the content would
                // have liked.
                .overlay(alignment: .bottom) {
                    if PanelChrome.drawsIslandMark(
                        phase: shell.phase,
                        screenHasNotch: shell.screenHasNotch,
                        isSettled: shell.isSettled
                    ) {
                        IslandMark(theme: theme, summary: summary)
                    }
                }
                .frame(
                    width: shell.panelRect.width,
                    height: shell.panelRect.height,
                    alignment: .top
                )
                .offset(x: shell.panelRect.minX, y: shell.panelRect.minY)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .environment(\.deckTheme, theme)
        .environment(\.strings, model.strings)
    }

    @ViewBuilder
    private func panel(theme: DeckTheme) -> some View {
        Group {
            switch shell.phase {
            case .collapsed:
                // Nothing of its own: what the operator sees while the panel
                // is away is the island's mark, and that is carried by the
                // panel rather than by this state — see `IslandMark`.
                Color.clear
            case .peek:
                PeekView(theme: theme, summary: summary, model: model)
            case .open, .fullscreen:
                WorkspaceView(shell: shell, model: model, theme: theme)
            }
        }
        // The panel reaches above the menu bar so that it stays welded to its
        // island. The content must not: the first line of a card in the
        // menu-bar row would be unreadable against the wallpaper behind it.
        .padding(.top, shell.phase == .collapsed ? 0 : shell.topOverhang)
        // Sequenced behind the frame rather than tied to it: the content starts
        // once the panel has visibly begun to move, and leaves faster than it
        // arrives. Which of the two it is, the controller decides — it is the
        // only place that knows the direction.
        .id(contentKind)
        .transition(.opacity)
        .animation(shell.contentAnimation, value: contentKind)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Any click anywhere in the panel promotes a peek into a held panel.
        // Registering it here rather than on each control means nothing can be
        // added later that forgets to.
        .contentShape(Rectangle())
        .onTapGesture { shell.onInteract() }
    }

    /// The panel's surface.
    ///
    /// Whether it is drawn at all is `PanelChrome`'s rule — the collapsed state
    /// under a real notch draws nothing once it has arrived, and during the
    /// collapse it still does, which is what makes closing visible there.
    ///
    /// It was briefly drawn at the size of the stage and cut to the panel's
    /// shape with a `mask`, on the theory that `NSGlassEffectView` renders
    /// differently at different sizes. It does not — measured over a flat grey,
    /// the material at panel size and at stage size read 97.11 and 96.99, and
    /// the height it was drawn at changed neither. What the mask did do was
    /// double the material's own edge: over a striped backdrop, where a
    /// refraction is visible at all, the panel's rim measured 11.5 points darker
    /// than its middle when clipped and 19.5 when masked. The operator saw that
    /// as a frame appearing around the panel, and spotted the difference between
    /// two of the builds himself.
    ///
    /// So it is clipped, as it was before. The mask was cheaper — 53 ms of CPU
    /// per open-and-close against 77 — and bought nothing that was wrong with
    /// the panel.
    @ViewBuilder
    private func material(theme: DeckTheme) -> some View {
        surface(
            radius: PanelChrome.cornerRadius(phase: shell.phase, metrics: model.settings.panel),
            theme: theme
        )
    }

    private func surface(radius: CGFloat, theme: DeckTheme) -> some View {
        GlassBackground(
            cornerRadius: radius,
            theme: theme,
            glass: model.settings.glass,
            applicationIsActive: shell.applicationIsActive,
            weldedToTopEdge: shell.weldedToTopEdge
        )
        .frame(width: shell.panelRect.width, height: shell.panelRect.height)
        .offset(x: shell.panelRect.minX, y: shell.panelRect.minY)
    }

    /// Which of the three layouts is showing.
    ///
    /// Deliberately not the phase. The content is keyed on this so that one
    /// layout crossfades into another instead of appearing at full size inside
    /// a window that is still growing — but `.open` and `.fullscreen` share a
    /// layout, and keying on the phase would rebuild the whole workspace every
    /// time the fullscreen button is pressed, throwing away scroll positions
    /// and anything else the views hold.
    private var contentKind: Int {
        switch shell.phase {
        case .collapsed: 0
        case .peek: 1
        case .open, .fullscreen: 2
        }
    }

    /// The one line the panel can say about itself while it is small.
    private var summary: DeckSummary {
        DeckSummary(model: model)
    }
}

/// The state of everything the operator has placed, reduced to what fits in a
/// pill and a strip.
@MainActor
struct DeckSummary {
    var worst: CardState = .ok
    var chips: [(state: CardState, text: String)] = []
    var placedPlugins = 0

    init(model: DeckModel) {
        let placed = Set(model.layout.tabs.flatMap { $0.windows.map(\.pluginID) }).sorted()
        placedPlugins = placed.count

        for id in placed {
            let presentation = model.presentation(for: id)
            worst = DeckSummary.worse(worst, presentation.state)
            let label = presentation.card?.chip
                ?? model.displayManifest(withID: id)?.name
                ?? id.rawValue
            chips.append((presentation.state, label))
        }
    }

    /// `unknown` deliberately does not outrank `warn` or `crit`: a source that
    /// went quiet is a smaller problem than one that is reporting trouble, and
    /// letting silence dominate the pill would bury the real signal.
    static func worse(_ lhs: CardState, _ rhs: CardState) -> CardState {
        func rank(_ state: CardState) -> Int {
            switch state {
            case .ok: 0
            case .unknown: 1
            case .warn: 2
            case .crit: 3
            }
        }
        return rank(lhs) >= rank(rhs) ? lhs : rhs
    }
}

/// The one thing the panel says about itself without being opened.
///
/// A short bar on the panel's bottom edge, in the colour of the worst thing
/// being watched. It is drawn in every state and it is always on that edge, so
/// a collapse carries it from the bottom of the open panel down into the island
/// — the operator asked for exactly that, and it is also the only version of
/// this that does not need a rule about when to appear.
///
/// On a screen with a real notch the collapsed panel draws nothing at all, and
/// the mark goes with it: the island is hardware there, and hanging a bar under
/// a screen cutout that was already doing the job is what he objected to in the
/// first place.
///
/// It says one thing and does not move on its own. With dozens of sources being
/// watched, anything that animates up here is wallpaper by the end of the day,
/// and it costs battery for the privilege of being ignored.
struct IslandMark: View {
    var theme: DeckTheme
    @Environment(\.strings) private var strings
    var summary: DeckSummary

    var body: some View {
        Capsule()
            .fill(theme.islandMark(for: summary.worst,
                                   placed: summary.placedPlugins > 0))
            .frame(width: theme.islandIndicatorSize.width,
                   height: theme.islandIndicatorSize.height)
            // A dark halo, so the bar reads against a bright document as well
            // as against a dark game. Without it the indicator only works on
            // half the things the panel sits over.
            .shadow(color: theme.islandHalo, radius: 2)
            .padding(.bottom, theme.islandIndicatorSize.height)
            .accessibilityLabel(summary.placedPlugins == 0
                ? strings(.islandNothingPlaced)
                : strings(.islandWorstState(summary.worst.rawValue)))
    }
}

/// The glance: what is asking for attention, in one line.
struct PeekView: View {
    var theme: DeckTheme
    @Environment(\.strings) private var strings
    var summary: DeckSummary
    var model: DeckModel

    var body: some View {
        VStack(alignment: .leading, spacing: theme.rowSpacing) {
            if summary.placedPlugins == 0 {
                Text(strings(.deckNothingPlaced))
                    .font(theme.titleFont)
                    .foregroundStyle(theme.text)
                Text(strings(.deckNothingOwn))
                    .font(theme.bodyFont)
                    .foregroundStyle(theme.dim)
            } else {
                HStack(spacing: 8) {
                    ForEach(Array(summary.chips.enumerated()), id: \.offset) { _, chip in
                        HStack(spacing: 5) {
                            Circle()
                                .fill(theme.color(for: chip.state))
                                .frame(width: 6, height: 6)
                            Text(chip.text)
                                .font(theme.chipFont)
                                .foregroundStyle(theme.muted)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                Text(strings(.deckClickToWork))
                    .font(theme.bodyFont)
                    .foregroundStyle(theme.dim)
            }
        }
        .padding(theme.panelPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
