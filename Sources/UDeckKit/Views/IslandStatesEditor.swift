import AppKit
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
    /// Which group the controls are pointed at. A group is the unit here:
    /// states are set up together or not at all, so picking one state out of
    /// two groups is not a thing to be expressed.
    @Binding var selected: UUID?
    @Environment(\.strings) private var strings

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(links, id: \.id) { link in
                frame(for: link)
            }

            // Somewhere to drop a state that should stop following the others.
            // Dragging is the whole of how groups change now: onto a frame to
            // join it, here to stand alone.
            Text(strings(.stateDropToSeparate))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(7)
                .background {
                    RoundedRectangle(cornerRadius: 9)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .foregroundStyle(.tertiary)
                }
                .dropDestination(for: String.self) { ids, _ in
                    separate(ids)
                    return true
                }

            // The way back to one panel with one appearance, and the way out of
            // it. Checked means one group holding everything — which is what
            // uDeck shipped with — and clearing it puts every situation on its
            // own, each keeping what it looked like a moment before.
            Toggle(strings(.lookStateAllTogether), isOn: Binding(
                get: { model.settings.theme.states.links.count == 1 },
                set: { together in
                    change { states, light, dark in
                        if together {
                            states.link(Set(IslandState.allCases), lightBase: light, darkBase: dark)
                        } else {
                            states.unlink(Set(IslandState.allCases), lightBase: light, darkBase: dark)
                        }
                    }
                    selected = nil
                }
            ))
            .toggleStyle(.checkbox)
            .font(.caption)
            .padding(.top, 2)
        }
    }

    // MARK: - Drawing

    private func frame(for link: IslandLink) -> some View {
        let isEdited = selected == link.id
        return FlowRow(spacing: 6) {
            ForEach(link.states, id: \.self) { state in
                chip(state, lit: isEdited, selects: link.id)
            }
        }
        .padding(7)
        .background {
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(Color.accentColor.opacity(isEdited ? 0.9 : 0.35),
                              lineWidth: isEdited ? 2 : 1)
                .background(RoundedRectangle(cornerRadius: 9)
                    .fill(Color.accentColor.opacity(isEdited ? 0.12 : 0.05)))
        }
        // The frame is the thing you point at: everything in it is set up
        // together, so there is nothing smaller to select.
        .contentShape(RoundedRectangle(cornerRadius: 9))
        .onTapGesture { selected = (selected == link.id) ? nil : link.id }
        // And it says so to the accessibility layer. A tap gesture alone is a
        // control only a pointer can find: nothing about it reaches VoiceOver,
        // the keyboard, or anything else driving the application — which is
        // also how this was caught, by trying to press it from outside.
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(link.states.map { strings(phrase(for: $0.phase)) }.joined(separator: ", "))
        .accessibilityAction { selected = (selected == link.id) ? nil : link.id }
        // A frame takes what is dropped on it, which is the whole of what a
        // frame means.
        .dropDestination(for: String.self) { ids, _ in
            join(ids, to: link)
            return true
        }
    }

    /// One situation.
    ///
    /// A real button rather than a tap gesture on a rectangle: a gesture is a
    /// control only a pointer can find — nothing about it reaches the keyboard
    /// or VoiceOver — and pressing the whole group is what a click on any of
    /// its members means anyway.
    private func chip(_ state: IslandState, lit: Bool, selects link: UUID) -> some View {
        Button {
            selected = (selected == link) ? nil : link
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(strings(phrase(for: state.phase))).font(.callout)
                if state.surrounding == .fullscreenApp {
                    Text(strings(.stateSurroundingFullscreen)).font(.caption2).opacity(0.7)
                }
                if state.phase == .collapsed, screenHasNotch {
                    Text(strings(.stateNotchIsTheIsland)).font(.caption2).opacity(0.55)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(lit ? 0.14 : 0.06)))
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .draggable(state.id)
    }

    /// Whether the screen this is being read on has a notch, where a collapsed
    /// island is not drawn at all — the hardware plays it. Worth saying next to
    /// the states it applies to, because the controls still matter: the same
    /// settings are what an external monitor will use.
    private var screenHasNotch: Bool {
        // The panel's screen, not `NSScreen.main`. Main is wherever the
        // keyboard is, which flips as the operator clicks between windows — the
        // note appeared and disappeared while the settings window had not moved
        // at all.
        NSApp.windows
            .first { $0 is DeckPanel }?
            .screen?
            .auxiliaryTopLeftArea != nil
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

    /// Everything dropped on a frame joins it.
    private func join(_ ids: [String], to link: IslandLink) {
        let dropped = Set(ids.compactMap(IslandState.init(id:)))
        guard !dropped.isEmpty, !dropped.isSubset(of: Set(link.states)) else { return }
        change { states, light, dark in
            states.link(dropped.union(link.states), lightBase: light, darkBase: dark)
        }
        selected = model.settings.theme.states.link(for: link.states[0])?.id
    }

    /// Everything dropped outside a frame stands on its own.
    private func separate(_ ids: [String]) {
        let dropped = Set(ids.compactMap(IslandState.init(id:)))
        guard !dropped.isEmpty else { return }
        change { states, light, dark in
            states.unlink(dropped, lightBase: light, darkBase: dark)
        }
        selected = dropped.first.flatMap { model.settings.theme.states.link(for: $0)?.id }
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
