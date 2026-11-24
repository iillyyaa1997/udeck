import SwiftUI
import UDeckCore

/// The button at the end of a card's title line that says where the card is
/// shown — its cell, a whole tab, a window of its own, a mini window — and
/// moves it (`WindowPlace`). uDeck's own, the same on every card.
struct PlaceButton: View {
    @Environment(\.strings) private var strings
    var model: DeckModel
    var theme: DeckTheme
    var window: GridWindow
    var onInteract: () -> Void
    @State private var open = false

    var body: some View {
        Button {
            onInteract()
            open.toggle()
        } label: {
            Image(systemName: "rectangle.on.rectangle")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(open ? theme.text : theme.muted)
                .frame(width: 20, height: 20)
                .background(RoundedRectangle(cornerRadius: 5).fill(open ? theme.subtleFill : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(strings(.placeShowAs))
        .accessibilityIdentifier("card.\(window.pluginID.rawValue).place")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            OptionList(options: Self.options(strings, model: model, window: window), selected: window.place.rawValue,
                       note: nil, prefix: "card.\(window.pluginID.rawValue).place", theme: theme) { chosen in
                open = false
                guard let place = WindowPlace(rawValue: chosen) else { return }
                model.show(window.id, in: place)
            }
        }
    }

    /// The places, as the menu lists them: under one heading — naming the
    /// thing the card shows, when that is what moves (`placeMenuSubject`) —
    /// the mini window saying it stays above everything, and a place apart's
    /// *As a card* that it goes back to the board.
    static func options(_ strings: Strings, model: DeckModel, window: GridWindow) -> [MenuOption] {
        let heading = model.placeMenuSubject(of: window).map { strings(.placeShowThing($0)) } ?? strings(.placeShowAs)
        let apart = model.layout.isApart(window.id)
        return WindowPlace.allCases.map { place in
            let note: String? = switch place {
            case .mini: strings(.placeMiniNote)
            case .card where apart: strings(.placeBackToBoard)
            default: nil
            }
            return MenuOption(id: place.rawValue, text: strings(.placeName(place)), group: heading, note: note)
        }
    }
}

/// The same choice in a card's right-click menu.
struct PlaceMenuItems: View {
    @Environment(\.strings) private var strings
    var model: DeckModel
    var window: GridWindow

    var body: some View {
        Section(model.placeMenuSubject(of: window).map { strings(.placeShowThing($0)) } ?? strings(.placeShowAs)) {
            ForEach(WindowPlace.allCases, id: \.self) { place in
                Toggle(strings(.placeName(place)), isOn: Binding(
                    get: { window.place == place },
                    set: { if $0 { model.show(window.id, in: place) } }
                ))
            }
        }
    }
}

/// A cell whose card is shown elsewhere: it keeps its place on the board,
/// says where the card went, brings that place forward, and brings the card
/// back.
struct AwaySlot: View {
    @Environment(\.strings) private var strings
    var model: DeckModel
    var theme: DeckTheme
    var window: GridWindow
    var title: String
    var onInteract: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Text(strings(.placeAway(title: title, place: window.place)))
                .font(theme.bodyFont)
                .foregroundStyle(theme.muted)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .accessibilityIdentifier("card.\(window.pluginID.rawValue).away")
            HStack(spacing: 6) {
                Button(strings(.placeShow)) {
                    onInteract()
                    model.show(window.id, in: window.place)
                }
                .buttonStyle(GhostButtonStyle(theme: theme))
                .accessibilityIdentifier("card.\(window.pluginID.rawValue).away.show")
                Button(strings(.placeBringBack)) {
                    onInteract()
                    model.show(window.id, in: .card)
                }
                .buttonStyle(GhostButtonStyle(theme: theme))
                .accessibilityIdentifier("card.\(window.pluginID.rawValue).away.back")
            }
        }
        .padding(theme.windowPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(
            RoundedRectangle(cornerRadius: theme.windowCornerRadius)
                .strokeBorder(theme.line, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
        )
        .contextMenu {
            Button(strings(.placeBringBack)) { model.show(window.id, in: .card) }
        }
    }
}

/// A card shown away from its cell — a whole tab, a window of its own, a
/// mini window — at the size of its place, which its plugin is told in cells.
struct PlacedCard: View {
    var model: DeckModel
    var theme: DeckTheme
    var windowID: UUID
    @Bindable var shell: ShellState

    var body: some View {
        GeometryReader { geometry in
            if let found = model.layout.window(withID: windowID) {
                DeckWindowView(model: model, theme: theme, window: found.window, tabID: found.tabID, shell: shell,
                               isMoving: false, onDragChanged: { _ in }, onResizeChanged: { _ in }, onGestureEnded: {},
                               isPlaced: true)
                    .onAppear { model.placeHas(geometry.size, theme: theme, for: windowID) }
                    .onChange(of: geometry.size) { _, size in model.placeHas(size, theme: theme, for: windowID) }
            }
        }
    }
}
