import SwiftUI
import UDeckCore

/// uDeck's own settings.
///
/// Four groups, in the order they matter: how the panel opens, how it looks,
/// what is installed, and what this build is. The plugin section is the largest
/// on purpose — in an application whose every feature is a plugin, "what is
/// installed and what is it allowed to do" *is* the settings screen.
public struct SettingsView: View {
    @Bindable var model: DeckModel

    /// Absent in a build with no updater — a development build, or a copy
    /// somebody assembled themselves. The Updates group is simply not drawn
    /// then, rather than drawn with a button that cannot do anything.
    var updater: (any UpdateChecking)?
    /// Opens on the first pane rather than on the one that was most useful to
    /// me while building it. Somebody who has landed in a language they cannot
    /// read needs the language control before anything else, and it is here.
    @State private var section: Section = .general
    @State private var selectedPlugin: String?

    enum Section: String, CaseIterable, Identifiable {
        case general
        case opening
        case look
        case plugins
        case about

        var id: String { rawValue }

        var title: Phrase {
            switch self {
            case .general: .sectionGeneral
            case .opening: .sectionOpening
            case .look: .sectionLook
            case .plugins: .sectionPlugins
            case .about: .sectionAbout
            }
        }

        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .opening: "cursorarrow.rays"
            case .look: "paintbrush"
            case .plugins: "square.grid.2x2"
            case .about: "info.circle"
            }
        }
    }

    public init(model: DeckModel, updater: (any UpdateChecking)? = nil) {
        self.model = model
        self.updater = updater
    }

    public var body: some View {
        NavigationSplitView {
            List(Section.allCases, selection: $section) { item in
                Label(model.strings(item.title), systemImage: item.symbol).tag(item)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 220)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch section {
                    case .general: GeneralSettings(model: model)
                    case .opening: OpeningSettings(model: model)
                    case .look: LookSettings(model: model)
                    case .plugins: PluginSettingsSection(model: model, selected: $selectedPlugin)
                    case .about: AboutSection(model: model, updater: updater)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 720, minHeight: 480)
        // The settings window is its own window rather than part of the panel,
        // so it does not inherit the panel's environment and has to be handed
        // the language itself.
        //
        // This reaches the panes below and not this view: a value put into the
        // environment by a modifier is read by that view's children, not by the
        // view that put it there. The sidebar above therefore asks the model
        // directly — it did not, and it was the one part of the settings window
        // that stayed in English after the language was changed.
        .environment(\.strings, model.strings)
    }
}

// MARK: - General

/// Settings that belong to the application rather than to the panel.
///
/// The language lived on the Look pane, next to the tint and the ink, which is
/// where it did not belong: Look is about how the panel is dressed, and what
/// language it speaks is not that. One row for now, and the pane exists so the
/// next application-wide setting has somewhere obvious to go instead of being
/// filed under whichever pane has room.
private struct GeneralSettings: View {
    @Bindable var model: DeckModel
    @Environment(\.strings) private var strings

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
            GridRow {
                Text(strings(.lookLanguage))
                    .gridColumnAlignment(.trailing)
                    .foregroundStyle(.secondary)
                Picker("", selection: Binding(
                    get: { model.settings.language },
                    set: { newValue in
                        var settings = model.settings
                        settings.language = newValue
                        model.update(settings: settings)
                    }
                )) {
                    // Following the system is the absence of a choice rather
                    // than a language of its own, so it is `nil` here and
                    // nothing at all in the settings file.
                    Text(strings(.languageSystem)).tag(Language?.none)
                    ForEach(Language.allCases) { language in
                        // Each language names itself. Somebody who landed in a
                        // language they cannot read is looking for the word
                        // they *can* — "English", not "Английский".
                        Text(language.endonym).tag(Language?.some(language))
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 260)
            }
        }
        .frame(maxWidth: 560, alignment: .leading)
    }
}

// MARK: - Opening

/// How the panel is opened, on one screen.
///
/// Same treatment as the Look pane and for the same reason: this was four
/// headed groups with a paragraph under nearly every control, and the
/// paragraphs were mine. What survives is the one warning that stops a
/// shortcut being set to something macOS will take from every other
/// application, and one line at the foot about permissions — which is a fact
/// about uDeck worth stating once rather than four times.
private struct OpeningSettings: View {
    @Bindable var model: DeckModel
    @Environment(\.strings) private var strings

    private func binding<Value>(_ keyPath: WritableKeyPath<AppSettings, Value>) -> Binding<Value> {
        Binding(
            get: { model.settings[keyPath: keyPath] },
            set: { newValue in
                var settings = model.settings
                settings[keyPath: keyPath] = newValue
                model.update(settings: settings)
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    label(strings(.openingGesture))
                    Toggle(strings(.openingGestureToggle),
                           isOn: binding(\.gesture.enabled))
                }

                GridRow {
                    label(strings(.openingPauseFirst))
                    slider(binding(\.gesture.dwellDuration), in: 0.08 ... 0.8, step: 0.02,
                           readout: strings(.unitMilliseconds(Int((model.settings.gesture.dwellDuration * 1000).rounded()))))
                }

                GridRow {
                    label(strings(.openingPushPast))
                    slider(binding(\.gesture.edgePushDistance), in: 10 ... 120, step: 5,
                           readout: strings(.unitPoints(Int(model.settings.gesture.edgePushDistance))))
                }

                GridRow {
                    label(strings(.openingStayQuiet))
                    slider(binding(\.gesture.reopenCooldown), in: 0 ... 2, step: 0.1,
                           readout: strings(.unitSeconds(model.settings.gesture.reopenCooldown)))
                }

                divider

                GridRow {
                    label(strings(.openingShortcut))
                    Toggle(strings(.openingShortcutToggle), isOn: binding(\.hotkey.enabled))
                }

                GridRow {
                    label(strings(.openingKeys))
                    HStack(spacing: 8) {
                        ForEach(HotKeyModifier.allCases.sorted(), id: \.self) { modifier in
                            Toggle(modifier.symbol, isOn: Binding(
                                get: { model.settings.hotkey.modifiers.contains(modifier) },
                                set: { isOn in
                                    var updated = model.settings
                                    if isOn {
                                        updated.hotkey.modifiers.insert(modifier)
                                    } else {
                                        updated.hotkey.modifiers.remove(modifier)
                                    }
                                    model.update(settings: updated)
                                }
                            ))
                            .toggleStyle(.button)
                        }
                        Picker("", selection: Binding(
                            get: { model.settings.hotkey.key.uppercased() },
                            set: { key in
                                var updated = model.settings
                                updated.hotkey.key = key
                                model.update(settings: updated)
                            }
                        )) {
                            ForEach(HotKeyBinding.orderedKeyNames, id: \.self) { name in
                                Text(name).tag(name)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 110)
                    }
                }

                if model.settings.hotkey.modifiers.isEmpty {
                    GridRow {
                        Color.clear.frame(width: 1, height: 1)
                        Text(strings(.openingNeedsModifier))
                            .font(.caption).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                divider

                GridRow {
                    label(strings(.openingAlso))
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle(strings(.openingRetract),
                               isOn: binding(\.collapseOnAppSwitch))
                        Toggle(strings(.openingFullscreen),
                               isOn: binding(\.gesture.enabledInFullscreen))
                    }
                }
            }

            Divider()

            Text(strings(.openingPermissions))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 560, alignment: .leading)
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .gridColumnAlignment(.trailing)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder private var divider: some View {
        GridRow {
            Divider()
                .gridCellColumns(2)
                .padding(.vertical, 2)
        }
    }

    /// Generic over the number, because one of these four is a `CGFloat` — a
    /// distance in points — and the rest are plain `Double`s.
    private func slider<V: BinaryFloatingPoint>(
        _ value: Binding<V>,
        in range: ClosedRange<V>,
        step: V.Stride,
        readout: String
    ) -> some View where V.Stride: BinaryFloatingPoint {
        HStack(spacing: 10) {
            Slider(value: value, in: range, step: step).frame(width: 230)
            Text(readout)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)
        }
    }
}


// MARK: - Look

/// Everything about how the panel looks, on one screen.
///
/// It was five headed groups down a scroll, with two previews of the same slab
/// and a paragraph of explanation under nearly every control. The explanation
/// was mine and there was far too much of it: a settings screen that has to be
/// read is one that has failed, and the operator said so twice.
///
/// So: one sample at the top, every knob under it in a single grid, and prose
/// only where a control is about to do something surprising. The sample is
/// live, which is what replaces the paragraphs — a panel you can see is a panel
/// you do not need described.
private struct LookSettings: View {
    @Bindable var model: DeckModel
    @Environment(\.strings) private var strings

    /// Which of the two looks the knobs below are editing.
    ///
    /// Not the one that is showing. The dark look has to be set up in daylight,
    /// and a settings screen that only lets you edit what you can currently see
    /// is one you have to wait until evening to finish.
    @State private var editingDark: Bool?

    /// What the operator is typing into the name field. Held here rather than
    /// in the settings, because a half-typed name is not a setting.
    @State private var newPresetName = ""

    /// Whichever look the knobs are pointed at: the one being edited if the
    /// operator has picked one, otherwise the one on screen.
    private var edited: Bool {
        editingDark ?? model.settings.isDark(
            systemIsDark: DeckModel.systemIsDark(), hour: DeckModel.currentHour()
        )
    }

    private var editedLook: PanelLook { model.settings.theme.look(forDark: edited) }

    /// A binding into the look being edited, rather than into the resolved copy
    /// everything draws from — writing to that would be writing to a cache the
    /// next resolve throws away.
    private func look<Value>(_ keyPath: WritableKeyPath<PanelLook, Value>) -> Binding<Value> {
        Binding(
            get: { model.settings.theme.look(forDark: edited)[keyPath: keyPath] },
            set: { newValue in
                var settings = model.settings
                var look = settings.theme.look(forDark: edited)
                look[keyPath: keyPath] = newValue
                settings.theme.setLook(look, forDark: edited)
                model.update(settings: settings)
            }
        )
    }

    private func theme<Value>(_ keyPath: WritableKeyPath<ThemeSettings, Value>) -> Binding<Value> {
        Binding(
            get: { model.settings.theme[keyPath: keyPath] },
            set: { newValue in
                var settings = model.settings
                settings.theme[keyPath: keyPath] = newValue
                model.update(settings: settings)
            }
        )
    }

    /// What the "start from" menu calls itself: the preset this look currently
    /// matches, or the honest answer that it matches none of them.
    private var startingPointName: String {
        if let built = model.settings.theme.preset(forDark: edited) { return strings(built.namePhrase) }
        if let mine = model.settings.theme.saved.first(where: { $0.look == editedLook }) { return mine.name }
        return strings(.lookCustom)
    }

    /// The one note worth keeping, because it is the only control on this
    /// screen that can silently do nothing.
    ///
    /// The tint is painted by uDeck over the material rather than handed to it,
    /// so the material only shows through whatever the tint leaves. Measured on
    /// the running panel: the two characters are 19 points of 255 apart with no
    /// tint, and 8 at 72%. Without this the operator concludes the control is
    /// broken, which is what happened.
    private var characterWarning: String? {
        guard editedLook.glass.tinted, editedLook.glass.tintStrength > 0.5 else { return nil }
        return strings(.lookTintCoversMaterial(
            percent: Int((editedLook.glass.tintStrength * 100).rounded())
        ))
    }

    private func pour(_ look: PanelLook) {
        var settings = model.settings
        settings.theme.setLook(look, forDark: edited)
        model.update(settings: settings)
    }

    private func saveCurrent() {
        var settings = model.settings
        guard settings.theme.save(forDark: edited, as: newPresetName) != nil else { return }
        model.update(settings: settings)
        newPresetName = ""
    }

    private func percent(_ value: Double) -> String {
        strings(.unitPercent(Int((value * 100).rounded())))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            sample
            Divider()
            knobs
            Divider()
            presets
        }
        .frame(maxWidth: 560, alignment: .leading)
    }

    // MARK: - The sample

    private var sample: some View {
        VStack(alignment: .leading, spacing: 10) {
            GlassPreview(glass: editedLook.glass,
                         theme: DeckTheme(density: model.settings.density, look: editedLook,
                                          textSize: model.settings.resolvedTextSize))

            HStack(spacing: 12) {
                Picker("", selection: Binding(get: { edited }, set: { editingDark = $0 })) {
                    Text(strings(.lookLightLook)).tag(false)
                    Text(strings(.lookDarkLook)).tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)

                // Labelled, because it was not. The menu showed only whichever
                // preset the look currently matched — "Custom" most of the
                // time — and the operator had to ask what it was.
                Text(strings(.lookPresets))
                    .foregroundStyle(.secondary)

                Menu(startingPointName) {
                    Section(strings(.lookBuiltIn)) {
                        ForEach(PanelMode.allCases) { preset in
                            // Name and summary, because the names do not explain
                            // themselves: Ghost, Paper and Smoke tell you
                            // nothing about what you are about to pour in.
                            Button {
                                pour(preset.look)
                            } label: {
                                Text(strings(preset.namePhrase))
                                Text(strings(preset.summaryPhrase))
                            }
                        }
                    }
                    if !model.settings.theme.saved.isEmpty {
                        Section(strings(.lookSaved)) {
                            ForEach(model.settings.theme.saved) { preset in
                                Button(preset.name) { pour(preset.look) }
                            }
                        }
                    }
                }
                .frame(width: 150)
            }
        }
    }

    // MARK: - The knobs

    private var knobs: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
            GridRow {
                label(strings(.lookShows))
                VStack(alignment: .leading, spacing: 6) {
                    Picker("", selection: theme(\.source)) {
                        ForEach(ThemeSource.allCases) { source in
                            Text(strings(source.namePhrase)).tag(source)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 300)

                    switch model.settings.theme.source {
                    case .manual:
                        Picker("", selection: theme(\.manualIsDark)) {
                            Text(strings(.lookLight)).tag(false)
                            Text(strings(.lookDark)).tag(true)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 160)
                    case .schedule:
                        HStack(spacing: 14) {
                            Stepper(strings(.lookLightFromHour(model.settings.theme.schedule.lightFromHour)),
                                    value: theme(\.schedule.lightFromHour), in: 0 ... 23)
                            Stepper(strings(.lookDarkFromHour(model.settings.theme.schedule.darkFromHour)),
                                    value: theme(\.schedule.darkFromHour), in: 0 ... 23)
                        }
                        .font(.callout)
                    case .system:
                        EmptyView()
                    }
                }
            }

            divider

            GridRow {
                label(strings(.lookGlass))
                Picker("", selection: look(\.glass.style)) {
                    Text(strings(.glassRegular)).tag(GlassStyle.regular)
                    Text(strings(.glassClear)).tag(GlassStyle.clear)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 200)
            }

            if let warning = characterWarning {
                GridRow {
                    Color.clear.frame(width: 1, height: 1)
                    Text(warning).font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            GridRow {
                label(strings(.lookAmount))
                slider(look(\.glass.opacity), in: GlassAppearance.opacityRange,
                       step: 0.05, readout: percent(editedLook.glass.opacity))
            }

            GridRow {
                label(strings(.lookTint))
                HStack(spacing: 10) {
                    Toggle("", isOn: look(\.glass.tinted)).labelsHidden()
                    Picker("", selection: look(\.glass.tintIsLight)) {
                        Text(strings(.tintLighter)).tag(true)
                        Text(strings(.tintDarker)).tag(false)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 180)
                    .disabled(!editedLook.glass.tinted)
                }
            }

            GridRow {
                label(strings(.lookStrength))
                slider(look(\.glass.tintStrength), in: GlassAppearance.tintStrengthRange,
                       step: 0.02, readout: percent(editedLook.glass.tintStrength))
                    .disabled(!editedLook.glass.tinted)
            }

            GridRow {
                label(strings(.lookTintColour))
                HStack(spacing: 10) {
                    // Empty means the grey that "Lighter"/"Darker" names, which
                    // is what the tint always was. The toggle is the switch
                    // between "a shade of the background" and "a colour", and
                    // it reads better than a colour well that silently means
                    // grey when nobody has touched it.
                    Toggle("", isOn: Binding(
                        get: { editedLook.glass.tintColor != nil },
                        set: { wantsColour in
                            var settings = model.settings
                            var look = settings.theme.look(forDark: edited)
                            look.glass.tintColor = wantsColour
                                ? (look.glass.tintIsLight ? .white : InkColor(red: 0, green: 0, blue: 0))
                                : nil
                            settings.theme.setLook(look, forDark: edited)
                            model.update(settings: settings)
                        }
                    ))
                    .labelsHidden()
                    .disabled(!editedLook.glass.tinted)

                    if let colour = editedLook.glass.tintColor {
                        ColorPicker("", selection: Binding(
                            get: { Color(red: colour.red, green: colour.green, blue: colour.blue) },
                            set: { newValue in
                                guard let rgb = InkColor(newValue) else { return }
                                var settings = model.settings
                                var look = settings.theme.look(forDark: edited)
                                look.glass.tintColor = rgb
                                settings.theme.setLook(look, forDark: edited)
                                model.update(settings: settings)
                            }
                        ), supportsOpacity: false)
                        .labelsHidden()
                        .disabled(!editedLook.glass.tinted)
                    }
                }
            }

            divider

            GridRow {
                label(strings(.lookText))
                Picker("", selection: look(\.ink)) {
                    Text(strings(.lookLight)).tag(PanelInk.light)
                    Text(strings(.lookDark)).tag(PanelInk.dark)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 200)
            }

            GridRow {
                label(strings(.lookBrightness))
                slider(look(\.inkBrightness), in: 0 ... 1,
                       step: 0.02, readout: percent(editedLook.inkBrightness))
            }

            GridRow {
                label(strings(.lookColour))
                HStack(spacing: 10) {
                    Toggle("", isOn: Binding(
                        get: { editedLook.inkColor != nil },
                        set: { wantsColour in
                            var settings = model.settings
                            var look = settings.theme.look(forDark: edited)
                            look.inkColor = wantsColour
                                ? (look.ink == .light ? .white : .black)
                                : nil
                            settings.theme.setLook(look, forDark: edited)
                            model.update(settings: settings)
                        }
                    ))
                    .labelsHidden()

                    if let colour = editedLook.inkColor {
                        ColorPicker("", selection: Binding(
                            get: { Color(red: colour.red, green: colour.green, blue: colour.blue) },
                            set: { newValue in
                                guard let rgb = InkColor(newValue) else { return }
                                var settings = model.settings
                                var look = settings.theme.look(forDark: edited)
                                look.inkColor = rgb
                                settings.theme.setLook(look, forDark: edited)
                                model.update(settings: settings)
                            }
                        ), supportsOpacity: false)
                        .labelsHidden()
                    }
                }
            }

            divider

            GridRow {
                label(strings(.lookDensity))
                Picker("", selection: Binding(
                    get: { model.settings.density },
                    set: { newValue in
                        var settings = model.settings
                        settings.density = newValue
                        model.update(settings: settings)
                    }
                )) {
                    ForEach(Density.allCases, id: \.self) { density in
                        Text(strings(density.namePhrase)).tag(density)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 260)
            }

            GridRow {
                label(strings(.lookTextSize))
                slider(Binding(
                    get: { model.settings.resolvedTextSize },
                    set: { newValue in
                        var settings = model.settings
                        settings.textSize = newValue
                        model.update(settings: settings)
                    }
                ), in: AppSettings.textSizeRange, step: 0.5,
                   readout: String(format: "%.1f pt", model.settings.resolvedTextSize))
            }
        }
    }

    // MARK: - Presets

    private var presets: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField(strings(.lookNameThisLook), text: $newPresetName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
                    .onSubmit(saveCurrent)
                Button(strings(.actionSave), action: saveCurrent)
                    .disabled(PanelPreset.cleaned(name: newPresetName).isEmpty)
            }

            ForEach(model.settings.theme.saved) { preset in
                HStack(spacing: 10) {
                    Text(preset.name).frame(width: 180, alignment: .leading)
                    Button(strings(.actionUse)) { pour(preset.look) }
                    Button(strings(.actionDelete), role: .destructive) {
                        var settings = model.settings
                        settings.theme.remove(preset.id)
                        model.update(settings: settings)
                    }
                }
                .font(.callout)
            }
        }
    }

    // MARK: - Pieces

    private func label(_ text: String) -> some View {
        Text(text)
            .gridColumnAlignment(.trailing)
            .foregroundStyle(.secondary)
    }

    /// A rule across the whole grid, not just the column the controls are in —
    /// a divider that starts where the second column does reads as a stray mark
    /// rather than as a break between two groups of knobs.
    @ViewBuilder private var divider: some View {
        GridRow {
            Divider()
                .gridCellColumns(2)
                .padding(.vertical, 2)
        }
    }

    /// Generic over the number, because the text size is a `CGFloat` in points
    /// and everything else here is a plain `Double`.
    private func slider<V: BinaryFloatingPoint>(
        _ value: Binding<V>,
        in range: ClosedRange<V>,
        step: V.Stride,
        readout: String
    ) -> some View where V.Stride: BinaryFloatingPoint {
        HStack(spacing: 10) {
            Slider(value: value, in: range, step: step).frame(width: 230)
            Text(readout)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 46, alignment: .trailing)
        }
    }
}


// MARK: - Plugins

private struct PluginSettingsSection: View {
    @Bindable var model: DeckModel
    @Binding var selected: String?
    @Environment(\.strings) private var strings

    var body: some View {
        SettingsGroup(strings(.pluginsInstalled)) {
            // It sat under Opening, which is about how the panel arrives. This
            // is a fact about plugins — whether they keep running when nobody
            // is looking — and it belongs with them.
            Toggle(strings(.openingKeepPolling), isOn: Binding(
                get: { model.settings.pollWhileCollapsed },
                set: { newValue in
                    var settings = model.settings
                    settings.pollWhileCollapsed = newValue
                    model.update(settings: settings)
                }
            ))

            HStack {
                Text(model.pluginsDirectoryDisplayPath)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(strings(.pluginsOpenFolder)) { model.revealPluginsDirectory() }
                Button(strings(.pluginsLookAgain)) { model.discoverPlugins() }
            }

            if model.plugins.isEmpty {
                Text(strings(.pluginsNothingInstalled))
                    .foregroundStyle(.secondary)
            }

            ForEach(model.plugins, id: \.id) { plugin in
                PluginRow(model: model, plugin: plugin)
                Divider()
            }

            // Was a headed group of its own on the Look tab, where it had
            // nothing to do with how the panel looks. It is a fact about cards,
            // it cannot be changed from here, and one line is the whole of it.
            Text(strings(.pluginsStaleness(
                seconds: Int(model.settings.defaultCardTTL),
                multiplier: Int(model.settings.silentTTLMultiplier)
            )))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct PluginRow: View {
    @Bindable var model: DeckModel
    var plugin: DiscoveredPlugin
    @Environment(\.strings) private var strings
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.displayManifest(for: plugin)?.name ?? plugin.folderName).font(.headline)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let manifest = plugin.manifest {
                    Toggle(strings(.pluginEnabled), isOn: Binding(
                        get: { model.pluginSettings.isEnabled(manifest.id) },
                        set: { model.setEnabled($0, for: manifest.id) }
                    ))
                    .labelsHidden()
                }
                Button(expanded ? strings(.pluginLess) : strings(.pluginMore)) { expanded.toggle() }
            }

            if !plugin.problems.isEmpty {
                ForEach(Array(plugin.problems.enumerated()), id: \.offset) { _, problem in
                    Label(problem.description, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            if expanded, let manifest = model.displayManifest(for: plugin) {
                details(manifest)
            }
        }
        .padding(.vertical, 4)
    }

    private var subtitle: String {
        guard let manifest = model.displayManifest(for: plugin) else { return plugin.folderName }
        var parts = ["\(manifest.kind.rawValue) · v\(manifest.version)"]
        if let seconds = manifest.intervalInWholeSeconds {
            parts.append(strings(.pluginEverySeconds(seconds)))
        }
        if let author = manifest.author { parts.append(author) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func details(_ manifest: PluginManifest) -> some View {
        if let description = manifest.description {
            Text(description).font(.callout)
        }

        Text(plugin.directory.path)
            .font(.system(.caption2, design: .monospaced))
            .foregroundStyle(.secondary)
            .textSelection(.enabled)

        permissions(manifest)

        if !manifest.settings.isEmpty {
            Text(strings(.pluginSettings)).font(.subheadline).padding(.top, 4)
            // By position: a manifest with two settings sharing a key is
            // reported as a problem, and must still render rather than
            // collapsing two rows into one.
            ForEach(Array(manifest.settings.enumerated()), id: \.offset) { _, declaration in
                settingControl(declaration, for: manifest.id)
            }
        }

        let snapshot = model.snapshot(for: manifest.id)
        if let failure = snapshot.failure {
            Text(strings(.pluginLastFailure(reason: failure.reason.description)))
                .font(.caption).foregroundStyle(.orange)
            if !failure.diagnostics.isEmpty {
                Text(failure.diagnostics)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(8)
            }
        }
    }

    @ViewBuilder
    private func permissions(_ manifest: PluginManifest) -> some View {
        let requested = manifest.permissions.capabilities
        if requested.isEmpty {
            Label(strings(.permissionsAsksNothing), systemImage: "checkmark.seal")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 3) {
                Text(strings(.permissionsAsksTo)).font(.subheadline)
                ForEach(Array(requested.enumerated()), id: \.offset) { _, capability in
                    HStack(spacing: 6) {
                        Image(systemName: granted(capability, manifest) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(granted(capability, manifest) ? .green : .secondary)
                        Text(strings(capability.summaryPhrase)).font(.caption)
                        if capability.processEnforcement == .declaredOnly {
                            Text(strings(.permissionsDeclared))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .help(strings(.permissionsDeclaredHelp))
                        }
                    }
                }
                HStack {
                    Button(strings(.actionAllow)) { model.decidePermissions(for: manifest.id, allow: true) }
                    Button(strings(.actionDecline)) { model.decidePermissions(for: manifest.id, allow: false) }
                }
                .padding(.top, 2)
            }
        }
    }

    private func granted(_ capability: Capability, _ manifest: PluginManifest) -> Bool {
        model.grants[manifest.id]?.granted.contains(capability) ?? false
    }

    @ViewBuilder
    private func settingControl(_ declaration: SettingDeclaration, for id: PluginIdentifier) -> some View {
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

// MARK: - About

private struct AboutSection: View {
    @Bindable var model: DeckModel
    var updater: (any UpdateChecking)?
    @Environment(\.strings) private var strings

    /// Mirrors the updater's own switch rather than owning the answer: Sparkle
    /// stores it, and a copy here would be a second place it could be true.
    @State private var checksAutomatically = false

    var body: some View {
        SettingsGroup(strings(.aboutTitle)) {
            Text(strings(.aboutTagline))
            Text("Apache-2.0 · Copyright 2026 Ilya Volkov")
                .font(.caption).foregroundStyle(.secondary)
            Link("github.com/iillyyaa1997/udeck", destination: URL(string: "https://github.com/iillyyaa1997/udeck")!)
        }

        if let updater {
            SettingsGroup(strings(.updatesTitle)) {
                Toggle(strings(.updatesAutomatically), isOn: Binding(
                    get: { checksAutomatically },
                    set: { checksAutomatically = $0; updater.checksAutomatically = $0 }
                ))
                Text(strings(.updatesAutomaticallyHelp))
                    .font(.caption).foregroundStyle(.secondary)

                // Two numbers rather than one sentence. "Up to date" asks to be
                // believed; "installed 0.1.0, latest 0.1.0" can be checked.
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 3) {
                    GridRow {
                        Text(strings(.updatesInstalled)).foregroundStyle(.secondary)
                        Text(updater.status.installedVersion).monospacedDigit()
                    }
                    if let latest = updater.status.latestVersion {
                        GridRow {
                            Text(strings(.updatesLatest)).foregroundStyle(.secondary)
                            Text(latest).monospacedDigit()
                        }
                    }
                }
                .font(.callout)
                .padding(.top, 2)

                HStack(spacing: 10) {
                    Button(strings(.updatesCheckNow)) { updater.checkNow() }
                        .disabled(updater.status.stage == .checking)
                    if case .available(let version) = updater.status.stage {
                        Button(strings(.updatesInstallNow(version))) { updater.install() }
                            .buttonStyle(.borderedProminent)
                    }
                    if case .readyToInstall = updater.status.stage {
                        Button(strings(.updatesRestartToInstall)) { updater.install() }
                            .buttonStyle(.borderedProminent)
                    }
                    updateSentence(updater.status)
                }
            }
            .onAppear { checksAutomatically = updater.checksAutomatically }
        }

        SettingsGroup(strings(.aboutThisBuild)) {
            Label(strings(.aboutNotSigned), systemImage: "exclamationmark.shield")
            Text(strings(.aboutAdHoc))
                .font(.caption).foregroundStyle(.secondary)
            Label(strings(.aboutNotSandboxed), systemImage: "shield.slash")
            Text(strings(.aboutReadPermissions))
                .font(.caption).foregroundStyle(.secondary)
        }

        if !model.problems.isEmpty {
            SettingsGroup(strings(.aboutProblems)) {
                ForEach(Array(model.problems.enumerated()), id: \.offset) { _, problem in
                    Text(problem)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
                Button(strings(.actionClear)) { model.clearProblems() }
            }
        }
    }
}

private extension AboutSection {
    /// One line, in the state's own colour, saying what happened.
    @ViewBuilder
    func updateSentence(_ status: UpdateStatus) -> some View {
        switch status.stage {
        case .idle:
            Text(lastChecked(status.lastCheck)).font(.caption).foregroundStyle(.secondary)
        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(strings(.updatesChecking))
            }
            .font(.caption).foregroundStyle(.secondary)
        case .upToDate:
            HStack(spacing: 5) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(strings(.updatesUpToDate) + " " + lastChecked(status.lastCheck))
            }
            .font(.caption).foregroundStyle(.secondary)
        case .available(let version):
            Text(strings(.updatesAvailable(version))).font(.caption).foregroundStyle(.secondary)
        case .downloading(let fraction):
            HStack(spacing: 6) {
                if let fraction {
                    ProgressView(value: fraction).controlSize(.small).frame(width: 80)
                } else {
                    ProgressView().controlSize(.small)
                }
                Text(strings(.updatesDownloading))
            }
            .font(.caption).foregroundStyle(.secondary)
        case .readyToInstall:
            Text(strings(.updatesReady)).font(.caption).foregroundStyle(.secondary)
        case .failed(let reason):
            HStack(spacing: 5) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(strings(.updatesFailed(reason)))
            }
            .font(.caption).foregroundStyle(.secondary)
        }
    }

    func lastChecked(_ date: Date?) -> String {
        guard let date else { return strings(.updatesNeverChecked) }
        // Under a minute the formatter rounds to zero and then picks the
        // future tense for it: "checked in 0 seconds", about something that has
        // already happened.
        guard Date().timeIntervalSince(date) >= 60 else { return strings(.updatesJustChecked) }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        // The panel's language, not the system's. Without this the sentence
        // came out half-translated — "Проверено 35 seconds ago" — which is the
        // one thing worse than being in the wrong language entirely.
        formatter.locale = Locale(identifier: strings.language.rawValue)
        return strings(.updatesLastChecked(formatter.localizedString(for: date, relativeTo: Date())))
    }
}

// MARK: - Layout helper

private struct SettingsGroup<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.title3).bold()
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 6)
    }
}


/// The panel, as it will actually look, over the two backgrounds that disagree
/// about it.
///
/// This is what replaced the paragraphs. There is one of it now — there used to
/// be two of the same slab, once near the top of the pane and once further down
/// beside the tint, which asked the operator to compare a thing with itself.
///
/// The dark half and the light half are the whole of the trade-off: a tint that
/// rescues the panel from a dark game is the same tint that washes it out over
/// a white document. The ruling is there so the refraction is visible at all —
/// the material bends what is behind it, and a flat colour gives it nothing to
/// bend.
private struct GlassPreview: View {
    var glass: GlassAppearance
    var theme: DeckTheme
    @Environment(\.strings) private var strings

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                Color(red: 0.09, green: 0.13, blue: 0.08)
                Color(red: 0.90, green: 0.89, blue: 0.86)
            }
            Canvas { context, size in
                var path = Path()
                let step: CGFloat = 13
                var x = -size.height
                while x < size.width {
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x + size.height, y: size.height))
                    x += step
                }
                context.stroke(path, with: .color(.gray.opacity(0.75)), lineWidth: 1.5)
            }
            PanelSurface(
                shape: RoundedRectangle(cornerRadius: 12),
                fallbackFill: theme.windowFill,
                glass: glass
            )
            .frame(width: 420, height: 92)
            .overlay {
                // A card, not a caption: the sample has to show the text, the
                // muted text and a state colour, because those are three of the
                // things the knobs below move and none of them is the glass.
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text(strings(.sampleTitle))
                            .font(theme.titleFont)
                            .foregroundStyle(theme.text)
                        Text(strings(.sampleChip))
                            .font(theme.chipFont)
                            .foregroundStyle(theme.color(for: CardState.ok))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(theme.chipFill(for: .ok)))
                    }
                    Text(strings(.sampleBody))
                        .font(theme.bodyFont)
                        .foregroundStyle(theme.muted)
                    Text(strings(.sampleFooter))
                        .font(theme.chipFont)
                        .foregroundStyle(theme.dim)
                }
                // Centred, so the card sits across the seam between the two
                // backdrops rather than entirely on the dark one. That is the
                // real case — the panel is a bar the width of the screen and
                // what is behind it changes along its length — and it is the
                // only arrangement in which the sample answers the question the
                // ink controls are actually asking.
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
        }
        .frame(width: 520, height: 150)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
    }
}
