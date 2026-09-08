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
        let theme = DeckTheme(density: model.settings.density)

        Group {
            switch shell.phase {
            case .collapsed:
                CollapsedIslandView(theme: theme, summary: summary, isLipUnderNotch: shell.screenHasNotch)
            case .peek:
                PeekView(theme: theme, summary: summary, model: model)
            case .open, .fullscreen:
                WorkspaceView(shell: shell, model: model, theme: theme)
            }
        }
        // The window reaches above the menu bar so that the panel stays welded
        // to its island. The content must not: the first line of a card in the
        // menu-bar row would be unreadable against the wallpaper behind it.
        .padding(.top, shell.phase == .collapsed ? 0 : shell.topOverhang)
        // The window's own frame is animated by the controller. Without this
        // the content simply appears at its final size inside a window that is
        // still growing, so the first two thirds of every reveal show squeezed,
        // clipped text. Faster than the reveal on purpose: the shape is what
        // the eye follows, and content that lags it looks broken rather than
        // deliberate.
        .id(contentKind)
        .transition(.opacity)
        .animation(.easeOut(duration: model.settings.panel.revealDuration * 0.55), value: contentKind)
        .environment(\.deckTheme, theme)
        .background {
            // The collapsed island is made of the same glass as the panel — it
            // is the panel, at its smallest — except under a real notch, where
            // there is only a few points of lip and glass would read as grime.
            if shell.phase != .collapsed {
                GlassBackground(
                    cornerRadius: model.settings.panel.cornerRadius,
                    theme: theme,
                    weldedToTopEdge: shell.weldedToTopEdge
                )
            } else if !shell.screenHasNotch {
                GlassBackground(
                    cornerRadius: model.settings.panel.islandCornerRadius,
                    theme: theme,
                    weldedToTopEdge: shell.weldedToTopEdge
                )
            }
        }
        // Any click anywhere in the panel promotes a peek into a held panel.
        // Registering it here rather than on each control means nothing can be
        // added later that forgets to.
        .contentShape(Rectangle())
        .onTapGesture { shell.onInteract() }
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
/// Two shapes, because the two screens are not the same object. On a display
/// with no notch this is the island itself — glass, the size of a real notch,
/// welded to the top edge — and the state is a short bar inside it. Under a
/// real notch there is nothing to build: the island is hardware, and all that
/// is left to draw is a lip carrying the same colour.
///
/// Either way it says one thing and does not move. With dozens of sources being
/// watched, anything that animates up here is wallpaper by the end of the day,
/// and it costs battery for the privilege of being ignored.
struct CollapsedIslandView: View {
    var theme: DeckTheme
    var summary: DeckSummary
    var isLipUnderNotch: Bool

    private var stateColor: Color {
        theme.color(for: summary.worst).opacity(summary.placedPlugins == 0 ? 0.25 : 0.85)
    }

    var body: some View {
        Group {
            if isLipUnderNotch {
                BottomRoundedRectangle(radius: 3).fill(stateColor)
            } else {
                Capsule()
                    .fill(stateColor)
                    .frame(width: 44, height: 3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
