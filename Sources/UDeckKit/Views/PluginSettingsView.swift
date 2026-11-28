import SwiftUI
import UDeckCore
import UDeckPluginFormat

/// A plugin's settings: in a tab each for the groups it declares, under the
/// headings it gives, and beside a group that asks for one, the card the
/// plugin draws to show what the group's settings do (0.9.32) — the operator
/// built such a page as a mock-up and asked for it in Settings (11-28).
struct PluginSettingsView: View {
    let manifest: PluginManifest
    @Bindable var model: DeckModel
    @Environment(\.strings) private var strings
    @State private var chosen = ""
    @State private var previewShell = ShellState()
    /// Where the settings and the sample are in the page's scroll view, and
    /// how tall the sample is: what keeps it in sight while they scroll.
    @State private var placed = CGRect.zero
    @State private var sampleHeight: CGFloat = 0

    /// The sample's width, and the least the settings keep beside it.
    static let sampleWidth: CGFloat = 320
    private let layout = BesideOrUnder(leastLeading: 340)

    /// The tabs: «General» for settings in no group, when there are any, then
    /// the plugin's groups in its order.
    private var tabs: [(id: String, label: String)] {
        var result: [(id: String, label: String)] = []
        if manifest.settingGroups.isEmpty || manifest.settings.contains(where: { $0.group == nil }) {
            result.append(("", strings(.pluginSettingsGeneral)))
        }
        result += manifest.settingGroups.map { ($0.id, $0.label) }
        return result
    }

    private var current: String { tabs.contains { $0.id == chosen } ? chosen : (tabs.first?.id ?? "") }
    private var group: SettingGroup? { manifest.settingGroups.first { $0.id == current } }
    private var previewing: SettingGroup? { group.flatMap { $0.hasPreview ? $0 : nil } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if tabs.count > 1 {
                Picker("", selection: Binding(get: { current }, set: { chosen = $0 })) {
                    ForEach(tabs, id: \.id) { tab in Text(tab.label).tag(tab.id) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityIdentifier("plugin.\(manifest.id.rawValue).settings.groups")
            }
            if let previewing {
                // Beside the settings where the window is wide enough, under
                // them where it is not: side by side in a narrow window it
                // pushed the whole page past the window's left edge (the
                // operator's Mac, 11-28: «Все сломалось»).
                layout {
                    controls
                    preview(previewing)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { sampleHeight = $0 }
                        .offset(y: pinned)
                }
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(PluginPage.space)) } action: { placed = $0 }
            } else {
                controls
            }
        }
        .onAppear(perform: announce)
        .onChange(of: current) { announce() }
        .onDisappear { model.showSettingsPreview(manifest.id, group: nil) }
    }

    /// How far the sample is moved down to stay in sight while the settings
    /// beside it scroll up (11-28: «образец всегда на виду»): never above where
    /// it stands, never past the settings' end — and not at all under them.
    private var pinned: CGFloat {
        guard layout.beside(placed.width, trailing: Self.sampleWidth) else { return 0 }
        return min(max(0, 12 - placed.minY), max(0, placed.height - sampleHeight))
    }

    private func announce() {
        model.showSettingsPreview(manifest.id, group: previewing?.id)
    }

    /// The settings of the tab shown, each heading said before the first
    /// setting under it. By position: a manifest with two settings sharing a
    /// key is reported as a problem, and must still render rather than
    /// collapsing two rows into one.
    private var controls: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Self.blocks(of: manifest.settings, in: current)) { block in
                if let title = block.title {
                    Text(title.uppercased())
                        .font(.caption2.weight(.semibold))
                        .tracking(0.5)
                        .foregroundStyle(.secondary)
                        .padding(.top, block.id == 0 ? 0 : 8)
                        .padding(.leading, 2)
                }
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(block.rows) { row in
                        if let second = row.second {
                            HStack(alignment: .top, spacing: 14) {
                                control(row.first).frame(maxWidth: .infinity, alignment: .leading)
                                control(second).frame(maxWidth: .infinity, alignment: .leading)
                            }
                        } else if row.half {
                            HStack(alignment: .top, spacing: 14) {
                                control(row.first).frame(maxWidth: .infinity, alignment: .leading)
                                Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
                            }
                        } else {
                            control(row.first)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 9).fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color(nsColor: .separatorColor).opacity(0.6)))
            }
        }
    }

    private func control(_ declaration: SettingDeclaration) -> some View {
        PluginSettingControl(declaration: declaration, id: manifest.id, model: model)
    }

    /// A box of settings under a heading, and its rows.
    struct Block: Identifiable {
        let id: Int
        let title: String?
        var rows: [Row]
    }

    /// One setting, or two short switches side by side (`half`: one such
    /// switch left alone at a box's end, as wide as it would be beside another).
    struct Row: Identifiable {
        let id: Int
        let first: SettingDeclaration
        var second: SettingDeclaration?
        var half = false
    }

    /// The settings of `group` in boxes, a new one at each heading; switches
    /// whose label is short go two to a row (11-28: ten switches one under
    /// another took the window's height).
    static func blocks(of settings: [SettingDeclaration], in group: String) -> [Block] {
        var blocks: [Block] = []
        var pending: SettingDeclaration?
        var pendingID = 0
        func flush() {
            guard let waiting = pending, !blocks.isEmpty else { return }
            blocks[blocks.count - 1].rows.append(Row(id: pendingID, first: waiting, half: true))
            pending = nil
        }
        for (offset, declaration) in settings.enumerated() where (declaration.group ?? "") == group {
            let heading = declaration.section.flatMap { $0.isEmpty ? nil : $0 }
            if heading != nil || blocks.isEmpty {
                flush()
                blocks.append(Block(id: blocks.count, title: heading, rows: []))
            }
            let short = declaration.type == .bool && declaration.label.count <= 30
            if short {
                if let waiting = pending {
                    blocks[blocks.count - 1].rows.append(Row(id: pendingID, first: waiting, second: declaration))
                    pending = nil
                } else {
                    pending = declaration
                    pendingID = offset
                }
            } else {
                flush()
                blocks[blocks.count - 1].rows.append(Row(id: offset, first: declaration))
            }
        }
        flush()
        return blocks
    }

    /// The card the plugin drew for the group, drawn as on the deck and not
    /// to be pressed: a sample, whose buttons would act on the real thing.
    @ViewBuilder
    private func preview(_ group: SettingGroup) -> some View {
        let theme = DeckTheme(density: model.settings.density,
                              look: model.settings.look(for: IslandState(phase: .open, surrounding: .ordinary)),
                              textSize: model.settings.resolvedTextSize)
        VStack(alignment: .leading, spacing: 6) {
            Text(strings(.pluginSettingsPreview)).font(.caption).foregroundStyle(.secondary)
            if let card = model.settingPreview(manifest.id, group: group.id) {
                CardBodyView(card: card,
                             presentation: CardPresentation(state: card.state ?? .ok, card: card, freshness: .fresh,
                                                            note: nil, lastSpokeAt: nil),
                             theme: theme, pluginID: manifest.id, model: model, shell: previewShell)
                    .padding(theme.windowPadding)
                    .frame(width: Self.sampleWidth, alignment: .top)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxHeight: 720, alignment: .top)
                    .background(RoundedRectangle(cornerRadius: theme.windowCornerRadius).fill(theme.windowFill))
                    .background(RoundedRectangle(cornerRadius: theme.windowCornerRadius).fill(theme.backing))
                    .overlay(RoundedRectangle(cornerRadius: theme.windowCornerRadius).strokeBorder(theme.line))
                    .clipShape(RoundedRectangle(cornerRadius: theme.windowCornerRadius))
                    .allowsHitTesting(false)
                    .environment(\.deckTheme, theme)
                    .accessibilityIdentifier("plugin.\(manifest.id.rawValue).settings.preview")
            } else {
                Text(strings(.pluginSettingsPreviewWaits))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: Self.sampleWidth, height: 120)
                    .background(RoundedRectangle(cornerRadius: 10).strokeBorder(.secondary.opacity(0.3)))
            }
        }
        .frame(width: Self.sampleWidth)
    }
}

/// Two views: the second beside the first where the first still has
/// `leastLeading` points, under it where it would not.
///
/// Not `ViewThatFits`: that built the settings and the sample twice and
/// measured each candidate over and over, and switching to a tab with a
/// sample stalled uDeck for seconds in the lab (11-28). This measures the
/// second view once a pass and gives the first what is left.
struct BesideOrUnder: Layout {
    var spacing: CGFloat = 16
    var leastLeading: CGFloat = 360

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        let trailing = subviews[1].sizeThatFits(.unspecified)
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil }
        if beside(width, trailing: trailing.width) {
            let leading = subviews[0].sizeThatFits(ProposedViewSize(width: width.map { $0 - spacing - trailing.width }, height: nil))
            return CGSize(width: width ?? leading.width + spacing + trailing.width,
                          height: max(leading.height, trailing.height))
        }
        let leading = subviews[0].sizeThatFits(ProposedViewSize(width: width, height: nil))
        return CGSize(width: width ?? max(leading.width, trailing.width),
                      height: leading.height + spacing + trailing.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let trailing = subviews[1].sizeThatFits(.unspecified)
        if beside(bounds.width, trailing: trailing.width) {
            subviews[0].place(at: bounds.origin, anchor: .topLeading,
                              proposal: ProposedViewSize(width: bounds.width - spacing - trailing.width, height: nil))
            subviews[1].place(at: CGPoint(x: bounds.maxX - trailing.width, y: bounds.minY), anchor: .topLeading,
                              proposal: ProposedViewSize(trailing))
        } else {
            let leading = subviews[0].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            subviews[0].place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: nil))
            subviews[1].place(at: CGPoint(x: bounds.minX, y: bounds.minY + leading.height + spacing), anchor: .topLeading,
                              proposal: ProposedViewSize(trailing))
        }
    }

    /// Whether the second view goes beside the first in `width`; with no
    /// width given, the ideal is side by side.
    func beside(_ width: CGFloat?, trailing: CGFloat) -> Bool {
        guard let width else { return true }
        return width >= leastLeading + spacing + trailing
    }
}

/// One setting, rendered by its type.
struct PluginSettingControl: View {
    let declaration: SettingDeclaration
    let id: PluginIdentifier
    @Bindable var model: DeckModel

    /// `plugin.<id>.setting.<key>`: what the lab and VoiceOver find it by.
    private var identifier: String { "plugin.\(id.rawValue).setting.\(declaration.key)" }

    @ViewBuilder
    var body: some View {
        let value = model.pluginSettings.value(of: declaration, for: id)

        switch declaration.type {
        case .bool:
            Toggle(declaration.label, isOn: Binding(
                get: { if case .bool(let flag) = value { flag } else { false } },
                set: { model.setSetting(.bool($0), key: declaration.key, for: id) }
            ))
            .help(declaration.help ?? "")
            .accessibilityIdentifier(identifier)

        case .int:
            // The bounds come from a plugin's manifest, so they cannot be
            // trusted to be a valid range: a declaration with `min` and no
            // `max` produced `2000...1000`, which is a fatal error rather than
            // an empty range. The range is built to be legal whatever arrives,
            // and the value is brought inside it before it is shown.
            let range = declaration.editingRange
            LabeledContent(declaration.label) {
                Stepper(
                    value: Binding(
                        get: {
                            guard case .int(let number) = value else { return range.lowerBound }
                            return min(max(number, range.lowerBound), range.upperBound)
                        },
                        set: { model.setSetting(.int($0), key: declaration.key, for: id) }
                    ),
                    in: range
                ) {
                    Text(String(describing: value.jsonLiteral))
                }
                .accessibilityIdentifier(identifier)
            }
            .help(declaration.help ?? "")

        case .string:
            LabeledContent(declaration.label) {
                TextField("", text: Binding(
                    get: { if case .string(let text) = value { text } else { "" } },
                    set: { model.setSetting(.string($0), key: declaration.key, for: id) }
                ))
                .frame(width: 240)
                .accessibilityIdentifier(identifier)
            }
            .help(declaration.help ?? "")

        case .enumeration:
            LabeledContent(declaration.label) {
                Picker("", selection: Binding(
                    get: { if case .string(let text) = value { text } else { "" } },
                    set: { model.setSetting(.string($0), key: declaration.key, for: id) }
                )) {
                    ForEach(declaration.options ?? [], id: \.value) { option in
                        Text(option.label).tag(option.value)
                    }
                }
                .labelsHidden()
                .frame(width: 240)
                .accessibilityIdentifier(identifier)
            }
            .help(declaration.help ?? "")
        }

        if let help = declaration.help {
            Text(help).font(.caption2).foregroundStyle(.secondary)
        }
    }
}
