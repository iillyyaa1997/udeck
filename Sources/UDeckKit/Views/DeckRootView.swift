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
        let theme = DeckTheme(density: model.settings.density, ink: model.settings.ink)

        // The window is the stage, sized once per screen; the panel is a
        // rectangle inside it that moves and resizes. Everything around the
        // panel is empty and lets clicks through — see `PanelHostingView`.
        ZStack(alignment: .topLeading) {
            Color.clear
            panel(theme: theme)
                .frame(
                    width: shell.panelRect.width,
                    height: shell.panelRect.height,
                    alignment: .top
                )
                .offset(x: shell.panelRect.minX, y: shell.panelRect.minY)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .environment(\.deckTheme, theme)
    }

    @ViewBuilder
    private func panel(theme: DeckTheme) -> some View {
        Group {
            switch shell.phase {
            case .collapsed:
                CollapsedIslandView(theme: theme, summary: summary, drawsNothing: shell.screenHasNotch)
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
        .background {
            // The collapsed island is made of the same glass as the panel — it
            // is the panel, at its smallest — except on a screen with a real
            // notch, where the collapsed state at rest draws nothing at all.
            //
            // "At rest" is the whole of the rule: see `PanelChrome`. Read off
            // the phase alone, this deleted the glass on the first frame of
            // every collapse on the built-in display, and the operator saw the
            // panel disappear instead of close.
            if PanelChrome.drawsMaterial(
                phase: shell.phase,
                screenHasNotch: shell.screenHasNotch,
                isSettled: shell.isSettled
            ) {
                GlassBackground(
                    cornerRadius: PanelChrome.cornerRadius(
                        phase: shell.phase, metrics: model.settings.panel
                    ),
                    theme: theme,
                    glass: model.settings.glass,
                    weldedToTopEdge: shell.weldedToTopEdge
                )
            }
        }
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
                ?? model.plugin(withID: id)?.manifest?.name
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

/// What is on screen while the panel is away.
///
/// On a display with no notch this is the island itself — glass, the size of a
/// real notch, welded to the top edge — and the state is a short bar inside it.
///
/// On a display that has a notch, nothing. The island is already there in
/// hardware; a strip hung under it is a second protrusion doing a job the
/// screen cutout was already doing, which is what the operator objected to. The
/// window still exists at the notch's own coordinates, where the camera housing
/// covers it, so there is nothing to see either way — but drawing nothing is
/// the statement, and not relying on hardware to hide it is the reason this is
/// a branch rather than an accident.
///
/// It says one thing and does not move. With dozens of sources being watched,
/// anything that animates up here is wallpaper by the end of the day, and it
/// costs battery for the privilege of being ignored.
struct CollapsedIslandView: View {
    var theme: DeckTheme
    var summary: DeckSummary
    var drawsNothing: Bool

    var body: some View {
        Group {
            if drawsNothing {
                Color.clear
            } else {
                Capsule()
                    .fill(theme.color(for: summary.worst)
                        .opacity(summary.placedPlugins == 0 ? 0.35 : 1))
                    .frame(width: theme.islandIndicatorSize.width,
                           height: theme.islandIndicatorSize.height)
                    // A dark halo, so the bar reads against a bright document
                    // as well as against a dark game. Without it the indicator
                    // only works on half the things the panel sits over.
                    .shadow(color: .black.opacity(0.55), radius: 2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityHidden(drawsNothing)
        .accessibilityLabel(summary.placedPlugins == 0
            ? "uDeck, nothing placed yet"
            : "uDeck, worst state \(summary.worst.rawValue)")
    }
}

/// The glance: what is asking for attention, in one line.
struct PeekView: View {
    var theme: DeckTheme
    var summary: DeckSummary
    var model: DeckModel

    var body: some View {
        VStack(alignment: .leading, spacing: theme.rowSpacing) {
            if summary.placedPlugins == 0 {
                Text("Nothing placed yet")
                    .font(theme.titleFont)
                    .foregroundStyle(theme.text)
                Text("uDeck shows nothing of its own. Open it and add a plugin.")
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
                Text("Click or press a key to work in here")
                    .font(theme.bodyFont)
                    .foregroundStyle(theme.dim)
            }
        }
        .padding(theme.panelPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
