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
    @State private var section: Section = .opening
    @State private var selectedPlugin: String?

    enum Section: String, CaseIterable, Identifiable {
        case opening = "Opening"
        case look = "Look"
        case plugins = "Plugins"
        case about = "About"

        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .opening: "cursorarrow.rays"
            case .look: "paintbrush"
            case .plugins: "square.grid.2x2"
            case .about: "info.circle"
            }
        }
    }

    public init(model: DeckModel) {
        self.model = model
    }

    public var body: some View {
        NavigationSplitView {
            List(Section.allCases, selection: $section) { item in
                Label(item.rawValue, systemImage: item.symbol).tag(item)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 220)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch section {
                    case .opening: OpeningSettings(model: model)
                    case .look: LookSettings(model: model)
                    case .plugins: PluginSettingsSection(model: model, selected: $selectedPlugin)
                    case .about: AboutSection(model: model)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 720, minHeight: 480)
    }
}

// MARK: - Opening

private struct OpeningSettings: View {
    @Bindable var model: DeckModel

    var body: some View {
        SettingsGroup("The gesture") {
            Toggle("Open by moving the cursor to the top of the screen", isOn: binding(\.gesture.enabled))
            Text("uDeck watches the pointer, which needs no permission from macOS. Only keyboard monitoring would, and uDeck does not do it.")
                .font(.caption).foregroundStyle(.secondary)

            LabeledContent("Pause before opening") {
                Slider(value: binding(\.gesture.dwellDuration), in: 0.08 ... 0.8, step: 0.02) {
                    Text(String(format: "%.0f ms", model.settings.gesture.dwellDuration * 1000))
                }
                .frame(width: 260)
            }
            Text("How long the cursor has to rest at the top edge. Sliding sideways restarts it, which is what keeps travelling along the menu bar from opening the panel.")
                .font(.caption).foregroundStyle(.secondary)

            LabeledContent("Or push past the edge by") {
                Slider(value: binding(\.gesture.edgePushDistance), in: 10 ... 120, step: 5) {
                    Text("\(Int(model.settings.gesture.edgePushDistance)) pt")
                }
                .frame(width: 260)
            }
            Text("Once the cursor has stopped at the top edge, moving the mouse further opens the panel straight away. Reaching a menu-bar target stops the moment it lands, so continued pressure is a signal nothing else produces.")
                .font(.caption).foregroundStyle(.secondary)

            LabeledContent("Stay quiet after closing for") {
                Slider(value: binding(\.gesture.reopenCooldown), in: 0 ... 2, step: 0.1) {
                    Text(String(format: "%.1f s", model.settings.gesture.reopenCooldown))
                }
                .frame(width: 260)
            }
        }

        SettingsGroup("The keyboard shortcut") {
            Toggle("Open with a keyboard shortcut", isOn: binding(\.hotkey.enabled))
            Text("The other way in, for when the cursor is nowhere near the top of the screen. It opens the panel ready to type in, rather than as a glance. This needs no permission either: macOS hands one registered combination straight to uDeck, which is not the same as watching the keyboard.")
                .font(.caption).foregroundStyle(.secondary)

            LabeledContent("Shortcut") {
                HStack(spacing: 10) {
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
                    .frame(width: 120)
                }
            }
            if model.settings.hotkey.modifiers.isEmpty {
                Text("Pick at least one modifier. A shortcut without one would take that key away from every application on this Mac.")
                    .font(.caption).foregroundStyle(.orange)
            } else if model.settings.hotkey.enabled {
                Text("\(model.settings.hotkey.displayName) — if another application already holds it, macOS gives it to whoever asked first and uDeck will say so in its log rather than pretending.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }

        SettingsGroup("When to stay out of the way") {
            Toggle("Retract when you switch to another application", isOn: binding(\.collapseOnAppSwitch))
            Toggle("Open over fullscreen applications", isOn: binding(\.gesture.enabledInFullscreen))
            Text("On by default: a fullscreen game or video is exactly when a panel you cannot reach stops being reached for. Turn it off if you ever see macOS's own menu-bar reveal get stuck in a fullscreen app — panels of this kind have been observed to do that, and corrupting the system's state is a worse problem than an unwanted panel.")
                .font(.caption).foregroundStyle(.secondary)
        }

        SettingsGroup("Plugins") {
            Toggle("Keep running plugins while the panel is away", isOn: binding(\.pollWhileCollapsed))
            Text("Off by default: a panel nobody is looking at that still runs a dozen scripts every few seconds is a laptop running out of battery for nothing. Opening the panel refreshes everything, and anything not yet refreshed is drawn as visibly old rather than as current.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

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
}

// MARK: - Look

private struct LookSettings: View {
    @Bindable var model: DeckModel

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
        SettingsGroup("Density") {
            Picker("Density", selection: Binding(
                get: { model.settings.density },
                set: { newValue in
                    var settings = model.settings
                    settings.density = newValue
                    model.update(settings: settings)
                }
            )) {
                Text("Compact").tag(Density.compact)
                Text("Normal").tag(Density.normal)
                Text("Cozy").tag(Density.cozy)
            }
            .pickerStyle(.segmented)
            .frame(width: 320)

            Text("Every plugin has to look right in all three, which is why this is one setting rather than something each plugin decides.")
                .font(.caption).foregroundStyle(.secondary)
        }

        SettingsGroup("The glass") {
            Picker("Character", selection: binding(\.glass.style)) {
                Text("Regular — what is behind stays legible").tag(GlassStyle.regular)
                Text("Clear — what is behind is diffused").tag(GlassStyle.clear)
            }
            .pickerStyle(.radioGroup)
            Text("macOS offers exactly these two and nothing in between. Both bend what is behind them towards the edges of the panel; regular keeps it recognisable, clear turns it to milk. There is no control over how much they bend — that is baked into each.")
                .font(.caption).foregroundStyle(.secondary)

            LabeledContent("How much glass") {
                Slider(value: binding(\.glass.opacity), in: GlassAppearance.opacityRange, step: 0.05) {
                    Text("\(Int(model.settings.glass.opacity * 100)) %")
                }
                .frame(width: 260)
            }
            Text("At nothing the material is gone entirely and the panel's content floats over whatever is behind it. The system's glass has no opacity of its own — style, tint and corner radius are the whole of it — so this is the view's own alpha, which is the only thing that reaches fully transparent.")
                .font(.caption).foregroundStyle(.secondary)

            Toggle("Tint the glass", isOn: binding(\.glass.tinted))
            Text("Untinted, the system material takes the colour of whatever is behind it — which is what makes it glass, and also what makes it vanish over a dark game and wash out over a bright document. A tint does not close the glass; it gives it something to be measured from.")
                .font(.caption).foregroundStyle(.secondary)

            Picker("Lean", selection: binding(\.glass.tintIsLight)) {
                Text("Lighter than the background").tag(true)
                Text("Darker than the background").tag(false)
            }
            .pickerStyle(.segmented)
            .frame(width: 380)
            .disabled(!model.settings.glass.tinted)

            Picker("Text", selection: binding(\.ink)) {
                Text("Light — for a panel darker than what is behind it").tag(PanelInk.light)
                Text("Dark — for a panel brighter than what is behind it").tag(PanelInk.dark)
            }
            .pickerStyle(.radioGroup)
            Text("Not automatic on purpose. Choosing correctly means knowing how bright what is behind the panel is, and uDeck never measures that — the glass samples it, but nothing reports it back. An automatic setting would guess, and it would guess wrong exactly where it matters.")
                .font(.caption).foregroundStyle(.secondary)

            LabeledContent("Tint strength") {
                Slider(value: binding(\.glass.tintStrength), in: GlassAppearance.tintStrengthRange, step: 0.02) {
                    Text("\(Int(model.settings.glass.tintStrength * 100)) %")
                }
                .frame(width: 260)
            }
            .disabled(!model.settings.glass.tinted)

            GlassPreview(glass: model.settings.glass, theme: DeckTheme(density: model.settings.density, ink: model.settings.ink))
            Text("The sample sits over a dark half and a light one, because those are the two cases that pull in opposite directions: a light tint stands out over a game and washes out over a document, and a dark one does the reverse. The ruling is there so the refraction is visible at all — the material bends what is behind it, and a flat colour or a field of grass gives it nothing to bend.")
                .font(.caption).foregroundStyle(.secondary)
        }

        SettingsGroup("Staleness") {
            LabeledContent("Assume a card is current for") {
                Text("\(Int(model.settings.defaultCardTTL)) s")
                    .foregroundStyle(.secondary)
            }
            Text("Used only for plugins that do not declare a lifetime of their own. Past it a card is dimmed and dated; past \(Int(model.settings.silentTTLMultiplier)) times it, its values are hidden entirely — a number nobody can vouch for should not be on screen.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Plugins

private struct PluginSettingsSection: View {
    @Bindable var model: DeckModel
    @Binding var selected: String?

    var body: some View {
        SettingsGroup("Installed") {
            HStack {
                Text(model.pluginsDirectoryDisplayPath)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Open the folder") { model.revealPluginsDirectory() }
                Button("Look again") { model.discoverPlugins() }
            }

            if model.plugins.isEmpty {
                Text("Nothing installed yet. uDeck shows nothing of its own — everything in the panel comes from a plugin.")
                    .foregroundStyle(.secondary)
            }

            ForEach(model.plugins, id: \.id) { plugin in
                PluginRow(model: model, plugin: plugin)
                Divider()
            }
        }
    }
}

private struct PluginRow: View {
    @Bindable var model: DeckModel
    var plugin: DiscoveredPlugin
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(plugin.manifest?.name ?? plugin.folderName).font(.headline)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let manifest = plugin.manifest {
                    Toggle("Enabled", isOn: Binding(
                        get: { model.pluginSettings.isEnabled(manifest.id) },
                        set: { model.setEnabled($0, for: manifest.id) }
                    ))
                    .labelsHidden()
                }
                Button(expanded ? "Less" : "More") { expanded.toggle() }
            }

            if !plugin.problems.isEmpty {
                ForEach(Array(plugin.problems.enumerated()), id: \.offset) { _, problem in
                    Label(problem.description, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            if expanded, let manifest = plugin.manifest {
                details(manifest)
            }
        }
        .padding(.vertical, 4)
    }

    private var subtitle: String {
        guard let manifest = plugin.manifest else { return plugin.folderName }
        var parts = ["\(manifest.kind.rawValue) · v\(manifest.version)"]
        if let interval = manifest.interval { parts.append("every \(Int(interval))s") }
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
            Text("Settings").font(.subheadline).padding(.top, 4)
            // By position: a manifest with two settings sharing a key is
            // reported as a problem, and must still render rather than
            // collapsing two rows into one.
            ForEach(Array(manifest.settings.enumerated()), id: \.offset) { _, declaration in
                settingControl(declaration, for: manifest.id)
            }
        }

        let snapshot = model.snapshot(for: manifest.id)
        if let failure = snapshot.failure {
            Text("Last failure: \(failure.reason.description)")
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
            Label("Asks for nothing", systemImage: "checkmark.seal")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 3) {
                Text("This plugin asks to:").font(.subheadline)
                ForEach(Array(requested.enumerated()), id: \.offset) { _, capability in
                    HStack(spacing: 6) {
                        Image(systemName: granted(capability, manifest) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(granted(capability, manifest) ? .green : .secondary)
                        Text(capability.summary).font(.caption)
                        if capability.processEnforcement == .declaredOnly {
                            Text("declared")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .help("uDeck shows you this and will not start the plugin without your agreement, but it cannot hold it against a running program — see the plugin documentation.")
                        }
                    }
                }
                HStack {
                    Button("Allow") { model.decidePermissions(for: manifest.id, allow: true) }
                    Button("Decline") { model.decidePermissions(for: manifest.id, allow: false) }
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

    var body: some View {
        SettingsGroup("uDeck") {
            Text("A panel at the top edge of the screen. Everything in it is a plugin.")
            Text("Apache-2.0 · Copyright 2026 Ilya Volkov")
                .font(.caption).foregroundStyle(.secondary)
            Link("github.com/iillyyaa1997/udeck", destination: URL(string: "https://github.com/iillyyaa1997/udeck")!)
        }

        SettingsGroup("This build") {
            Label("Not signed with a Developer ID and not notarised.", systemImage: "exclamationmark.shield")
            Text("Builds are ad-hoc signed, so macOS will refuse a downloaded copy on first launch — right-click and choose Open. A binary you built yourself is unaffected.")
                .font(.caption).foregroundStyle(.secondary)
            Label("Not sandboxed, and cannot be: plugins run commands.", systemImage: "shield.slash")
            Text("Read the permissions section of the plugin documentation before installing a plugin somebody else wrote.")
                .font(.caption).foregroundStyle(.secondary)
        }

        if !model.problems.isEmpty {
            SettingsGroup("Problems") {
                ForEach(Array(model.problems.enumerated()), id: \.offset) { _, problem in
                    Text(problem)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
                Button("Clear") { model.clearProblems() }
            }
        }
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


/// The glass, over the two backgrounds that disagree about it.
///
/// A settings screen that describes a material in prose asks the operator to
/// imagine it. This shows it — and shows it over a dark half and a light half
/// at once, because that is the whole of the trade-off: a tint that rescues the
/// panel from a dark game is the same tint that washes it out over a white
/// document.
private struct GlassPreview: View {
    var glass: GlassAppearance
    var theme: DeckTheme

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                Color(red: 0.09, green: 0.13, blue: 0.08)
                Color(red: 0.90, green: 0.89, blue: 0.86)
            }
            // Ruled, because a flat background cannot show refraction: the
            // material bends what is behind it, and there is nothing to bend in
            // a plain colour. On a wallpaper gradient or a field of grass the
            // effect is equally invisible, which is why it looked as though the
            // glass did not refract at all. Straight lines make it obvious —
            // they compress towards the edges of the slab.
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
            GlassSurface(
                shape: RoundedRectangle(cornerRadius: 12),
                fallbackFill: theme.windowFill,
                glass: glass
            )
            .frame(width: 300, height: 74)
            .overlay {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Claude sessions")
                        .font(theme.chipFont)
                        .foregroundStyle(theme.muted)
                    Text("Click or press a key to work in here")
                        .font(theme.bodyFont)
                        .foregroundStyle(theme.dim)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
            }
        }
        .frame(width: 380, height: 120)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
    }
}
