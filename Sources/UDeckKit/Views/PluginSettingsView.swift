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
                HStack(alignment: .top, spacing: 16) {
                    controls.frame(maxWidth: .infinity, alignment: .leading)
                    preview(previewing)
                }
            } else {
                controls
            }
        }
        .onAppear(perform: announce)
        .onChange(of: current) { announce() }
        .onDisappear { model.showSettingsPreview(manifest.id, group: nil) }
    }

    private func announce() {
        model.showSettingsPreview(manifest.id, group: previewing?.id)
    }

    /// The settings of the tab shown, each heading said before the first
    /// setting under it. By position: a manifest with two settings sharing a
    /// key is reported as a problem, and must still render rather than
    /// collapsing two rows into one.
    private var controls: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(manifest.settings.enumerated()).filter { ($0.element.group ?? "") == current }, id: \.offset) { _, declaration in
                if let section = declaration.section, !section.isEmpty {
                    Text(section)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.top, 6)
                }
                PluginSettingControl(declaration: declaration, id: manifest.id, model: model)
            }
        }
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
                    .frame(width: 340, height: 400, alignment: .top)
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
                    .frame(width: 340, height: 120)
                    .background(RoundedRectangle(cornerRadius: 10).strokeBorder(.secondary.opacity(0.3)))
            }
        }
        .frame(width: 340)
    }
}

/// One setting, rendered by its type.
struct PluginSettingControl: View {
    let declaration: SettingDeclaration
    let id: PluginIdentifier
    @Bindable var model: DeckModel

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
            }
            .help(declaration.help ?? "")

        case .string:
            LabeledContent(declaration.label) {
                TextField("", text: Binding(
                    get: { if case .string(let text) = value { text } else { "" } },
                    set: { model.setSetting(.string($0), key: declaration.key, for: id) }
                ))
                .frame(width: 240)
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
            }
            .help(declaration.help ?? "")
        }

        if let help = declaration.help {
            Text(help).font(.caption2).foregroundStyle(.secondary)
        }
    }
}
