import SwiftUI
import UDeckCore

/// One window in the grid: a title bar the host draws, and a body the plugin
/// fills.
///
/// The frame is always the host's. A plugin supplies rows, or — one day —
/// its own drawing, and either way it is drawn inside this chrome. That is what
/// keeps a panel of plugins from anyone looking like a collection of unrelated
/// applications.
struct DeckWindowView: View {
    var model: DeckModel
    var theme: DeckTheme
    var window: GridWindow
    var tabID: UUID
    @Bindable var shell: ShellState
    var isMoving: Bool
    var onDragChanged: (CGSize) -> Void
    var onResizeChanged: (CGSize) -> Void
    var onGestureEnded: () -> Void

    @State private var isHovering = false

    private var manifest: PluginManifest? { model.plugin(withID: window.pluginID)?.manifest }
    private var presentation: CardPresentation { model.presentation(for: window.pluginID) }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.rowSpacing) {
            header
                // The window's size belongs to the grid, so a card with more to
                // say than fits must scroll — not squeeze the title out of the
                // frame, which is what an unconstrained stack does.
                .layoutPriority(1)

            ScrollView(.vertical) {
                body(for: presentation)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .scrollIndicators(.never)
        }
        .padding(theme.windowPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // The same glass as the panel it sits in, rather than a flat fill on
        // top of it: one material, everywhere.
        .background(GlassSurface(
            shape: RoundedRectangle(cornerRadius: theme.windowCornerRadius),
            fallbackFill: theme.windowFill,
            tint: model.settings.glassTint
        ))
        .overlay(RoundedRectangle(cornerRadius: theme.windowCornerRadius).strokeBorder(theme.line))
        .clipShape(RoundedRectangle(cornerRadius: theme.windowCornerRadius))
        .overlay(alignment: .bottomTrailing) { resizeGrip }
        .opacity(isMoving ? 0.85 : 1)
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Refresh now") { model.refresh(window.pluginID) }
            Button("Remove from this tab", role: .destructive) {
                model.removeWindow(window.id, from: tabID)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Text(window.title ?? presentation.card?.title ?? manifest?.name ?? window.pluginID.rawValue)
                .font(theme.titleFont)
                .foregroundStyle(theme.text)
                .lineLimit(1)

            Spacer(minLength: 0)

            if let chip = presentation.card?.chip {
                Text(chip)
                    .font(theme.chipFont)
                    .foregroundStyle(theme.color(for: presentation.state))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(theme.color(for: presentation.state).opacity(0.18)))
            }

            staleBadge
        }
        .fixedSize(horizontal: false, vertical: true)
        // The header is the handle: dragging anywhere else would fight with a
        // card's own scrolling and selection.
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 3)
                .onChanged { onDragChanged($0.translation) }
                .onEnded { _ in onGestureEnded() }
        )
        .help("Drag to move this window")
    }

    /// Says out loud when a card is older than it claims to be.
    ///
    /// Without this a stale "everything is fine" is indistinguishable from a
    /// current one, which is the failure that quietly retires a panel like this.
    @ViewBuilder
    private var staleBadge: some View {
        switch presentation.freshness {
        case .fresh:
            EmptyView()
        case .stale, .silent, .neverSpoke:
            Image(systemName: "clock.badge.questionmark")
                .font(.system(size: 10))
                .foregroundStyle(theme.dim)
                .help(presentation.note ?? "no fresh data")
        }
    }

    // MARK: - Body

    @ViewBuilder
    private func body(for presentation: CardPresentation) -> some View {
        switch model.launchDecision(for: window.pluginID) {
        case .awaitingDecision(let pending):
            PermissionRequestView(
                model: model, theme: theme, pluginID: window.pluginID,
                manifest: manifest, pending: pending, shell: shell
            )
        case .refused(let denied):
            note("Not running: you declined \(denied.map(\.summary).joined(separator: ", "))", tint: theme.warn)
        case .disabled:
            note("Switched off", tint: theme.dim)
        case .allowed:
            if let card = presentation.card {
                CardBodyView(card: card, presentation: presentation, theme: theme,
                             pluginID: window.pluginID, model: model, shell: shell)
            } else {
                note(presentation.note ?? "no data yet", tint: theme.dim)
            }
        }
    }

    private func note(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(theme.bodyFont)
            .foregroundStyle(tint)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Resize

    private var resizeGrip: some View {
        Image(systemName: "arrow.down.right")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(theme.accent.opacity(isHovering ? 0.9 : 0.25))
            .frame(width: 16, height: 16)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { onResizeChanged($0.translation) }
                    .onEnded { _ in onGestureEnded() }
            )
            .help("Drag to resize, in whole cells")
    }
}
