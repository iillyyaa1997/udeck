import SwiftUI
import UDeckCore

/// Where a field's suggestions are: open or not, on which tab, for what
/// query, and whether a trigger typed in the field opened them or the field's
/// «/», ⌘/ or its menu did — then the list has a search of its own.
@MainActor
@Observable
final class SuggestState {
    var open = false
    /// The tab shown; nil for «All».
    var tab: String?
    /// The tabs a typed trigger opened; nil for every one.
    var scope: [String]?
    var query = ""
    /// The trigger typed in the field, which a pick replaces.
    var token: Suggestions.Token?
    /// Opened from the button, ⌘/ or the menu: the list has its own search.
    var searching = false
    var highlighted = 0
    /// A typed trigger closed with Escape: not opened again while it stays.
    var dismissedAt: Int?

    init() { SuggestionsPresence.register(self) }

    func close() {
        open = false
        tab = nil
        scope = nil
        query = ""
        token = nil
        searching = false
        highlighted = 0
    }
}

/// Whether a field's suggestions are open: then Escape is theirs, not the
/// panel's — whose monitor sees the key first and, with no text in what has
/// the keyboard, collapsed the panel when the list's search was empty (lab
/// 45994568681). Asked of the lists themselves, held weakly: a list whose
/// field has gone goes with it.
@MainActor
enum SuggestionsPresence {
    private final class Held { weak var state: SuggestState?; init(_ state: SuggestState) { self.state = state } }
    private static var held: [Held] = []

    static func register(_ state: SuggestState) {
        held.removeAll { $0.state == nil }
        held.append(Held(state))
    }

    static var isOpen: Bool { held.contains { $0.state?.open == true } }

    static func closeAll() {
        for entry in held { entry.state?.close() }
    }
}

/// The list over a field: tabs, the search when opened without typing, the
/// suggestions in groups — recent ones first while nothing is typed — and
/// the keys. A searched tab's items are asked of the plugin as the query
/// changes (`suggest`), and shown once they come for that query.
struct SuggestList: View {
    let rowID: String
    let suggest: InputSuggest
    let theme: DeckTheme
    @Bindable var state: SuggestState
    let maxHeight: CGFloat
    let pick: (SuggestItem) -> Void
    let send: (ResidentEvent) -> Void
    @Environment(\.strings) private var strings
    @FocusState private var searchFocused: Bool

    struct Group: Identifiable {
        var id: String
        var title: String?
        var items: [SuggestItem]
    }

    /// The tabs to choose between: «All» (when there is more than one tab) and
    /// those in scope.
    var tabs: [SuggestTab] { Self.tabs(suggest, state) }

    static func tabs(_ suggest: InputSuggest, _ state: SuggestState) -> [SuggestTab] {
        suggest.tabs.filter { state.scope?.contains($0.id) ?? true }
    }

    private var current: SuggestTab? { Self.current(suggest, state) }

    static func current(_ suggest: InputSuggest, _ state: SuggestState) -> SuggestTab? {
        state.tab.flatMap { id in suggest.tabs.first { $0.id == id } }
    }

    /// What is shown, in groups, for the tab and the query.
    var groups: [Group] { Self.groups(suggest, state, recentTitle: strings(.suggestRecent)) }

    static func groups(_ suggest: InputSuggest, _ state: SuggestState, recentTitle: String) -> [Group] {
        let current = current(suggest, state)
        let tabs = tabs(suggest, state)
        let triggers = Array(Set(suggest.tabs.compactMap(\.trigger)))
        if let current, current.search == true {
            guard let found = suggest.found, found.tab == current.id, found.query == state.query else { return [] }
            return [Group(id: current.id, title: nil, items: found.items)]
        }
        let items = suggest.items ?? []
        let shownTabs = current.map { [$0] } ?? tabs.filter { $0.search != true }
        var groups: [Group] = []
        if state.query.isEmpty, current == nil {
            let inScope = Set(shownTabs.map(\.id))
            let recent = (suggest.recent ?? []).compactMap { id in items.first { $0.id == id && inScope.contains($0.tab) } }
            if !recent.isEmpty { groups.append(Group(id: "recent", title: recentTitle, items: recent)) }
        }
        for tab in shownTabs {
            let ranked = Suggestions.rank(items.filter { $0.tab == tab.id }, query: state.query, triggers: triggers)
            if !ranked.isEmpty { groups.append(Group(id: tab.id, title: current == nil ? tab.title : nil, items: ranked)) }
        }
        return groups
    }

    /// Every item in the order shown: what ↑↓ move through.
    var visible: [SuggestItem] { groups.flatMap(\.items) }

    /// A searched tab waits for the plugin's answer to this query.
    private var waiting: Bool {
        guard let current, current.search == true else { return false }
        return !(suggest.found?.tab == current.id && suggest.found?.query == state.query)
    }

    var body: some View {
        let shown = groups
        VStack(alignment: .leading, spacing: 4) {
            if tabs.count > 1 || state.searching { tabBar }
            if state.searching {
                TextField(strings(.suggestSearch), text: $state.query)
                    .textFieldStyle(.plain)
                    .font(theme.smallFont)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 6).fill(theme.backing))
                    .focused($searchFocused)
                    .onKeyPress(.upArrow) { key(.up) ? .handled : .ignored }
                    .onKeyPress(.downArrow) { key(.down) ? .handled : .ignored }
                    .onKeyPress(.return) { key(.accept) ? .handled : .ignored }
                    .onKeyPress(.tab) { key(.accept) ? .handled : .ignored }
                    .onKeyPress(.escape) { key(.close) ? .handled : .ignored }
                    .onKeyPress(phases: .down) { press in
                        guard press.modifiers == .command, let number = Int(press.characters), (1...9).contains(number)
                        else { return .ignored }
                        return key(.tab(number)) ? .handled : .ignored
                    }
                    .accessibilityIdentifier("row.input.\(rowID).suggest.search")
                    .task {
                        // After the field lets the keyboard go: set at once, the
                        // focus stayed in the field (lab 45993059585).
                        try? await Task.sleep(for: .milliseconds(80))
                        searchFocused = true
                    }
            }
            // As tall as what it holds, up to the room it has; then it scrolls.
            ScrollViewReader { proxy in
                ScrollView(.vertical) { list(shown) }
                    .frame(height: min(max(36, maxHeight - chrome), Self.height(of: shown, textSize: theme.textSize)))
                    .onChange(of: state.highlighted) { _, index in
                        let items = shown.flatMap(\.items)
                        if items.indices.contains(index) { proxy.scrollTo(items[index].id) }
                    }
            }
            Text(strings(.suggestKeys))
                .font(.system(size: max(9, theme.textSize - 3)))
                .foregroundStyle(theme.muted)
                .padding(.horizontal, 6).padding(.top, 2)
        }
        .padding(5)
        .background(RoundedRectangle(cornerRadius: 10).fill(theme.backing).shadow(color: .black.opacity(0.35), radius: 10, y: 4))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(theme.line, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("row.input.\(rowID).suggest.list")
        .task(id: searchKey) {
            // A searched tab asks the plugin, a moment after the last key.
            guard let current, current.search == true, waiting else { return }
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            send(.suggest(row: rowID, tab: current.id, query: state.query))
        }
        .onChange(of: state.query) { _, _ in state.highlighted = 0 }
        .onChange(of: state.tab) { _, _ in state.highlighted = 0 }
    }

    private var searchKey: String { (state.tab ?? "") + "\u{1}" + state.query }

    /// What the list takes besides its rows: the tabs, the search, the keys
    /// and the padding — `maxHeight` is the whole list's.
    private var chrome: CGFloat {
        let line = ceil(theme.textSize * 1.25)
        return (tabs.count > 1 || state.searching ? line + 8 : 0) + (state.searching ? line + 14 : 0) + line + 16
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            if tabs.filter({ $0.search != true }).count > 1 { tabButton(nil, strings(.suggestAll)) }
            ForEach(tabs, id: \.id) { tab in tabButton(tab.id, tab.title) }
        }
        .padding(.horizontal, 2).padding(.top, 2)
    }

    private func tabButton(_ id: String?, _ title: String) -> some View {
        let on = state.tab == id
        return Button {
            state.tab = id
        } label: {
            Text(title).font(.system(size: max(10, theme.textSize - 2)))
                .padding(.horizontal, 9).padding(.vertical, 2)
                .foregroundStyle(on ? theme.text : theme.muted)
                .background(Capsule().fill(on ? Color.accentColor.opacity(0.35) : theme.subtleFill))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("row.input.\(rowID).suggest.tab.\(id ?? "all")")
    }

    @ViewBuilder
    private func list(_ shown: [Group]) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            if shown.isEmpty {
                Text(waiting ? strings(.suggestSearching) : strings(.suggestNothing))
                    .font(theme.smallFont).foregroundStyle(theme.muted)
                    .padding(.horizontal, 8).padding(.vertical, 6)
            }
            let offsets = Self.offsets(shown)
            ForEach(Array(shown.enumerated()), id: \.element.id) { groupIndex, group in
                if let title = group.title {
                    Text(title.uppercased())
                        .font(.system(size: max(9, theme.textSize - 3.5), weight: .semibold))
                        .tracking(0.5)
                        .foregroundStyle(theme.muted)
                        .padding(.horizontal, 8).padding(.top, groupIndex == 0 ? 2 : 6).padding(.bottom, 1)
                }
                ForEach(Array(group.items.enumerated()), id: \.offset) { index, item in
                    row(item, at: offsets[groupIndex] + index)
                }
            }
        }
        .padding(.vertical, 2)
    }

    /// What the list's rows take: a row and a group's title each a line
    /// and its padding; an empty list its one line.
    static func height(of groups: [Group], textSize: CGFloat) -> CGFloat {
        let row = ceil(textSize * 1.25) + 6 + 1
        let title = ceil((textSize - 3.5) * 1.25) + 7
        guard !groups.isEmpty else { return row + 8 }
        let items = groups.reduce(0) { $0 + $1.items.count }
        let titles = groups.filter { $0.title != nil }.count
        return CGFloat(items) * row + CGFloat(titles) * title + 4
    }

    static func offsets(_ groups: [Group]) -> [Int] {
        var offsets: [Int] = []
        var count = 0
        for group in groups {
            offsets.append(count)
            count += group.items.count
        }
        return offsets
    }

    private func row(_ item: SuggestItem, at index: Int) -> some View {
        let on = index == state.highlighted
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(item.title ?? item.text)
                .font(.system(size: theme.textSize - 1, weight: .semibold, design: .monospaced))
                .foregroundStyle(theme.text)
                .lineLimit(1)
                .fixedSize()
            if let detail = item.detail, !detail.isEmpty {
                Text(detail).font(theme.smallFont).foregroundStyle(theme.muted).lineLimit(1).truncationMode(.tail)
                    .layoutPriority(-1)
            }
            Spacer(minLength: 4)
            if let note = item.note {
                Text(note).font(.system(size: max(9, theme.textSize - 3))).foregroundStyle(theme.muted).fixedSize()
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(on ? Color.accentColor.opacity(0.3) : Color.clear))
        .contentShape(Rectangle())
        .onHover { inside in if inside { state.highlighted = index } }
        .onTapGesture { pick(item) }
        .help(item.detail ?? item.text)
        .id(item.id)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("row.input.\(rowID).suggest.item.\(item.id)")
        .accessibilityAction { pick(item) }
    }

    /// A key the list takes: from the field while a trigger is typed, or from
    /// its own search.
    func key(_ key: SuggestKey) -> Bool { Self.key(key, suggest, state, pick: pick) }

    static func key(_ key: SuggestKey, _ suggest: InputSuggest, _ state: SuggestState,
                    pick: (SuggestItem) -> Void) -> Bool
    {
        guard state.open else { return false }
        let items = groups(suggest, state, recentTitle: "").flatMap(\.items)
        let tabs = tabs(suggest, state)
        switch key {
        case .up:
            state.highlighted = max(0, state.highlighted - 1)
        case .down:
            state.highlighted = min(max(0, items.count - 1), state.highlighted + 1)
        case .accept:
            guard items.indices.contains(state.highlighted) else { return false }
            pick(items[state.highlighted])
        case .enter:
            guard items.indices.contains(state.highlighted) else { return false }
            let item = items[state.highlighted]
            // Typed whole already — «/compact» and Return: it goes, as in the
            // terminal, rather than being put in a second time.
            if let token = state.token, token.trigger + token.query == item.text {
                state.close()
                return false
            }
            pick(item)
        case .close:
            if let token = state.token { state.dismissedAt = token.range.location }
            state.close()
        case .tab(let number):
            let choices: [String?] = (tabs.filter { $0.search != true }.count > 1 ? [nil] : []) + tabs.map(\.id)
            guard choices.indices.contains(number - 1) else { return false }
            state.tab = choices[number - 1]
        }
        return true
    }
}
