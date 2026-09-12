import SwiftUI
import UDeckCore

/// The eight situations the island can be in, and which of them are set up
/// together.
///
/// A link is drawn as a frame with the states inside it, because that is the
/// whole of what the operator has to understand: what is in one frame moves
/// together. There is no list of named presets to keep in his head — a link is
/// not called anything, it is just visibly a group.
struct IslandStatesEditor: View {
    @Bindable var model: DeckModel
    @Binding var selection: Set<IslandState>
    @Environment(\.strings) private var strings

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(links, id: \.id) { link in
                frame(for: link)
            }

            HStack(spacing: 8) {
                Button(strings(.lookStateLink)) { link() }
                    .disabled(!canLink)
                Button(strings(.lookStateUnlink)) { unlink() }
                    .disabled(!canUnlink)
            }
            .controlSize(.small)
        }
    }

    // MARK: - Drawing

    private func frame(for link: IslandLink) -> some View {
        // Its own frame only when it is a group. A state on its own in a box
        // would say "these are set up together" about one thing.
        let isGroup = link.states.count > 1
        return FlowRow(spacing: 6) {
            ForEach(link.states, id: \.self) { state in
                chip(state)
            }
        }
        .padding(isGroup ? 7 : 0)
        .background {
            if isGroup {
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(Color.accentColor.opacity(0.45), lineWidth: 1)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Color.accentColor.opacity(0.06)))
            }
        }
    }

    private func chip(_ state: IslandState) -> some View {
        let selected = selection.contains(state)
        return Button {
            if selected { selection.remove(state) } else { selection.insert(state) }
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(strings(phrase(for: state.phase))).font(.callout)
                if state.surrounding == .fullscreenApp {
                    Text(strings(.stateSurroundingFullscreen)).font(.caption2).opacity(0.7)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .frame(maxWidth: 190, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(selected ? 0.14 : 0.06)))
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(Color.accentColor, lineWidth: selected ? 2 : 0)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - What is where

    /// Links in a stable order — the order the states are declared in, by the
    /// first state each link holds — so that linking something does not shuffle
    /// the whole column under the pointer.
    private var links: [IslandLink] {
        let order = Dictionary(uniqueKeysWithValues: IslandState.allCases.enumerated().map { ($1, $0) })
        return model.settings.theme.states.links
            .map { link in
                var link = link
                link.states.sort { (order[$0] ?? 0) < (order[$1] ?? 0) }
                return link
            }
            .sorted { (order[$0.states[0]] ?? 0) < (order[$1.states[0]] ?? 0) }
    }

    private func phrase(for phase: PanelPhase) -> Phrase {
        switch phase {
        case .collapsed: .statePhaseCollapsed
        case .peek: .statePhasePeek
        case .open: .statePhaseOpen
        case .fullscreen: .statePhaseFullscreen
        }
    }

    // MARK: - Linking

    private var canLink: Bool {
        guard selection.count > 1 else { return false }
        // Already one link, exactly: nothing to do.
        let ids = Set(selection.compactMap { model.settings.theme.states.link(for: $0)?.id })
        if ids.count == 1, let id = ids.first,
           let link = model.settings.theme.states.links.first(where: { $0.id == id }),
           Set(link.states) == selection {
            return false
        }
        return true
    }

    private var canUnlink: Bool {
        selection.contains { state in
            (model.settings.theme.states.link(for: state)?.states.count ?? 0) > 1
        }
    }

    private func link() {
        change { states, light, dark in
            states.link(selection, lightBase: light, darkBase: dark)
        }
    }

    private func unlink() {
        change { states, light, dark in
            states.unlink(selection, lightBase: light, darkBase: dark)
        }
    }

    private func change(_ edit: (inout IslandStates, PanelLook, PanelLook) -> Void) {
        var settings = model.settings
        var states = settings.theme.states
        edit(&states, settings.theme.light, settings.theme.dark)
        settings.theme.states = states.validated()
        model.update(settings: settings)
    }
}

/// A row that wraps, which `HStack` does not.
///
/// Written here rather than reached for from SwiftUI because the one that would
/// do it — a `Grid` with a fixed column count — decides the number of columns
/// before it knows how wide anything is, and these chips are as wide as their
/// longest word in whichever language uDeck is speaking.
struct FlowRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: proposal.width ?? x, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
