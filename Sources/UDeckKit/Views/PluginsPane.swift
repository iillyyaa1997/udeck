import SwiftUI
import UDeckCore

// Settings → Plugins, as the redesign draws it (2026-11-18, board Plugins1a and
// the operator's «б» for the updates mark): four labelled tabs — Installed,
// Catalogue, Sources, For developers — each with its icon, a line under them
// saying what the chosen one holds, and the Catalogue tab carrying a blue arrow
// and the number of updates waiting, as the sidebar's Plugins row does.
//
// Every control keeps the identifier it had when this was one long scroll: the
// lab drives these screens by identifier, and goes to the tab — and, for an
// installed plugin, to its card — that holds the control it is after (`ui.py`,
// "the Plugins pane's tabs"). Three identifiers are new and are what it reads
// the screen by: `plugins.tab.<tab>` on each tab, `plugins.page.<tab>` on the
// line saying what the chosen tab holds, and, on Installed, `plugins.row.<id>`
// on each plugin of the list and `plugins.card.<id>` on the name its card shows.

/// A tab of Settings → Plugins.
enum PluginsTab: String, CaseIterable, Identifiable, Sendable {
    case installed
    case catalogue
    case sources
    case developers

    var id: String { rawValue }

    var title: Phrase {
        switch self {
        case .installed: .pluginsInstalled
        case .catalogue: .pluginsTabCatalogue
        case .sources: .pluginsTabSources
        case .developers: .pluginsTabDevelopers
        }
    }

    /// What the tab holds, said under the tabs while it is chosen.
    var about: Phrase {
        switch self {
        case .installed: .pluginsAboutInstalled
        case .catalogue: .pluginsAboutCatalogue
        case .sources: .pluginsAboutSources
        case .developers: .pluginsAboutDevelopers
        }
    }

    var symbol: String {
        switch self {
        case .installed: "checkmark"
        case .catalogue: "arrow.down"
        case .sources: "house"
        case .developers: "chevron.left.forwardslash.chevron.right"
        }
    }

    /// The colour of the square its symbol sits on, as the sidebar's.
    var tint: Color {
        switch self {
        case .installed: Color(red: 0.20, green: 0.78, blue: 0.35)
        case .catalogue: Color(red: 0.04, green: 0.52, blue: 1.0)
        case .sources: Color(red: 0.37, green: 0.36, blue: 0.90)
        case .developers: Color(red: 0.56, green: 0.56, blue: 0.58)
        }
    }
}

/// The Plugins pane: its title, the tabs, what the chosen one holds, and its page.
///
/// A page is built only while its tab is chosen. Kept alive under the others it
/// would keep a warning half answered across a tab, but a page hidden from
/// sight has to be hidden from the accessibility API too, and the lab would then
/// depend on SwiftUI hiding every control of it — a click aimed at a control of
/// a page underneath lands on the page on top.
struct PluginsSettingsPane: View {
    @Bindable var model: DeckModel
    @Bindable var navigation: SettingsNavigation
    @Environment(\.strings) private var strings
    /// Whether **Install from a link…**'s sheet is open, and what is typed in
    /// it — kept here, above the tabs, so a look at another tab finds it as it
    /// was left on Sources, as **Add a source…**'s, whose field the model keeps.
    @State private var linkSheetOpen = false
    @State private var linkText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PaneTitle(strings(.sectionPlugins))
            tabBar
                .padding(.horizontal, 20)
                .padding(.top, 10)
            // The page's sentinel for the lab: one line per tab, so the walk
            // says which page it read.
            Text(strings(navigation.pluginsTab.about))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 20)
                .padding(.top, 6)
                .accessibilityIdentifier("plugins.page.\(navigation.pluginsTab.rawValue)")
            ScrollView {
                page
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    // Room under the last row: measured on the look pane when
                    // it scrolled here, the content is a little taller than the
                    // scroll view decides it is, and a pane whose last setting
                    // cannot be reached is a broken pane.
                    .padding(.bottom, 28)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            // Each tab from its own top.
            .id(navigation.pluginsTab)
        }
        // Whichever tab it opens on: the catalogue is read when it is stale,
        // and the sources with it (`pluginsPaneOpened`).
        .onAppear { model.pluginsPaneOpened() }
        // Settings closed, or another section chosen: what the sheets said
        // goes, an answer still on its way is not shown, and no list of
        // earlier versions is left open for the next time.
        .onDisappear {
            linkSheetOpen = false
            linkText = ""
            model.closeLinkLookup()
            model.closeAddSource()
            model.earlierVersionsOpen = [:]
        }
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(PluginsTab.allCases) { tab in
                PluginsTabButton(
                    tab: tab, title: strings(tab.title), chosen: navigation.pluginsTab == tab,
                    updates: tab == .catalogue ? model.updatesWaiting : 0,
                    updatesSaid: strings(.pluginsUpdatesOnTab(model.updatesWaiting))
                ) {
                    navigation.pluginsTab = tab
                }
            }
            Spacer(minLength: 0)
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1)
        }
    }

    @ViewBuilder private var page: some View {
        switch navigation.pluginsTab {
        case .installed: InstalledPluginsPage(model: model, selected: $navigation.selectedPlugin)
        case .catalogue: CataloguePage(model: model)
        case .sources: SourcesPage(model: model, linkSheetOpen: $linkSheetOpen, linkText: $linkText)
        case .developers: DevelopersPage(model: model)
        }
    }
}

/// One tab: its icon on a square of its colour, its name, and — on Catalogue —
/// the updates waiting as a blue arrow and a number, no pill (the operator's «б»).
private struct PluginsTabButton: View {
    var tab: PluginsTab
    var title: String
    var chosen: Bool
    var updates: Int
    var updatesSaid: String
    var choose: () -> Void

    var body: some View {
        Button(action: choose) {
            HStack(spacing: 7) {
                Image(systemName: tab.symbol)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 18, height: 18)
                    .background(RoundedRectangle(cornerRadius: 5).fill(tab.tint))
                    .accessibilityHidden(true)
                Text(title)
                    .fontWeight(chosen ? .semibold : .regular)
                    .foregroundStyle(chosen ? Color.accentColor : Color.primary)
                if updates > 0 {
                    HStack(spacing: 2) {
                        Image(systemName: "arrow.up")
                        Text("\(updates)")
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 9)
            .overlay(alignment: .bottom) {
                Rectangle().fill(chosen ? Color.accentColor : Color.clear).frame(height: 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(updates > 0 ? "\(title), \(updatesSaid)" : title)
        .accessibilityAddTraits(chosen ? .isSelected : [])
        .accessibilityIdentifier("plugins.tab.\(tab.rawValue)")
    }
}

/// A plugin's mark in the lists: the first letter of its name, white on a
/// square of a colour of its own — the same colour for the same id, on every
/// Mac and every launch (a hash of its own, not Swift's, which is seeded anew
/// on every launch).
struct PluginBadge: View {
    var name: String
    var id: String
    var size: CGFloat

    var body: some View {
        Text(name.first.map { String($0).uppercased() } ?? "?")
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.27).fill(Self.colour(of: id)))
            .accessibilityHidden(true)
    }

    private static let palette: [Color] = [
        Color(red: 0.20, green: 0.78, blue: 0.35), Color(red: 0.37, green: 0.36, blue: 0.90),
        Color(red: 0.04, green: 0.52, blue: 1.0), Color(red: 1.0, green: 0.62, blue: 0.04),
        Color(red: 1.0, green: 0.18, blue: 0.33), Color(red: 0.19, green: 0.69, blue: 0.78),
        Color(red: 0.69, green: 0.32, blue: 0.87), Color(red: 0.64, green: 0.52, blue: 0.37),
    ]

    static func colour(of id: String) -> Color {
        // FNV-1a over the id's bytes.
        var hash: UInt32 = 2_166_136_261
        for byte in id.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return palette[Int(hash % UInt32(palette.count))]
    }
}

// MARK: - Installed

/// What is installed: the list on the left — each plugin's name and the one
/// thing about it worth a glance (`PluginListStatus`) — and the chosen one's
/// card beside it; the plugins folder and the cards' lifetime under them.
struct InstalledPluginsPage: View {
    @Bindable var model: DeckModel
    /// The plugin the card shows, by its folder's name: the first one until
    /// another is chosen, or when the chosen one is gone.
    @Binding var selected: String?
    @Environment(\.strings) private var strings

    /// A line of the list: a plugin on disk, or one installed through uDeck
    /// whose folder has gone (`plugin` nil), which can be put back from its card.
    private struct Entry: Identifiable {
        var id: String
        var plugin: DiscoveredPlugin?
    }

    private var entries: [Entry] {
        model.plugins.map { Entry(id: $0.folderName, plugin: $0) } + missingIDs.map { Entry(id: $0, plugin: nil) }
    }

    private var missingIDs: [String] {
        model.installed.plugins.keys.filter { !model.folderExists($0) }.sorted()
    }

    private var current: Entry? {
        let all = entries
        return all.first { $0.id == selected } ?? all.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Only when there is no line at all: a plugin whose folder has gone
            // has one, and its card says it can be put back.
            if PluginsPane.saysNothingInstalled(folders: model.plugins.count, missing: missingIDs.count) {
                Text(strings(.pluginsNothingInstalled))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("plugins.nothingInstalled")
            } else {
                HStack(alignment: .top, spacing: 12) {
                    list
                        .frame(width: 230)
                    card
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            HStack {
                Text(model.pluginsDirectoryDisplayPath)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Spacer()
                Button(strings(.pluginsOpenFolder)) { model.revealPluginsDirectory() }
                Button(strings(.pluginsLookAgain)) { model.discoverPlugins() }
            }

            // A fact about cards, which cannot be changed from here: one line.
            Text(strings(.pluginsStaleness(
                seconds: Int(model.settings.defaultCardTTL),
                multiplier: Int(model.settings.silentTTLMultiplier)
            )))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var list: some View {
        let all = entries
        let chosen = current?.id
        return VStack(spacing: 0) {
            ForEach(Array(all.enumerated()), id: \.element.id) { index, entry in
                if index > 0 { Divider() }
                row(entry, chosen: entry.id == chosen)
            }
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: .separatorColor).opacity(0.6)))
    }

    private func row(_ entry: Entry, chosen: Bool) -> some View {
        let name = entry.plugin.map { model.displayManifest(for: $0)?.name ?? $0.folderName } ?? entry.id
        let status = model.listStatus(of: entry.plugin, id: entry.id)
        return Button {
            selected = entry.id
        } label: {
            HStack(spacing: 10) {
                PluginBadge(name: name, id: entry.id, size: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text(strings(status.phrase))
                        .font(.caption)
                        .foregroundStyle(status.isTrouble ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(chosen ? Color.accentColor.opacity(0.14) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(name), \(strings(status.phrase))")
        .accessibilityAddTraits(chosen ? .isSelected : [])
        .accessibilityIdentifier("plugins.row.\(entry.id)")
    }

    @ViewBuilder private var card: some View {
        if let entry = current {
            Group {
                if let plugin = entry.plugin {
                    InstalledPluginCard(model: model, plugin: plugin)
                } else {
                    MissingPluginCard(model: model, id: entry.id)
                }
            }
            // A card of its own for each plugin: a warning up on one is not
            // carried to the next.
            .id(entry.id)
        }
    }
}

/// An installed plugin's card: what it is, whether it runs, what it asks for,
/// where it came from and what can be done about it, its own settings, its
/// last run, and Earlier versions, Show in Finder and Remove along the bottom.
struct InstalledPluginCard: View {
    @Bindable var model: DeckModel
    var plugin: DiscoveredPlugin
    @Environment(\.strings) private var strings

    var body: some View {
        let manifest = model.displayManifest(for: plugin)
        VStack(alignment: .leading, spacing: 12) {
            header(manifest)

            if !plugin.problems.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(plugin.problems.enumerated()), id: \.offset) { _, problem in
                        Label(problem.description, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            if let manifest {
                permissions(manifest)
            }

            InstalledRepositoryControls(model: model, id: plugin.folderName, versionOnDisk: plugin.manifest?.version,
                                        reveal: { model.revealPlugin(plugin) }) {
                if let manifest {
                    details(manifest)
                }
            }
        }
        .lookCard()
    }

    private func header(_ manifest: PluginManifest?) -> some View {
        let name = manifest?.name ?? plugin.folderName
        return HStack(alignment: .top, spacing: 12) {
            PluginBadge(name: name, id: plugin.folderName, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(size: 16, weight: .bold))
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("plugins.card.\(plugin.folderName)")
                if let description = manifest?.description {
                    Text(description)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(subtitle(manifest))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if let manifest = plugin.manifest {
                Toggle(strings(.pluginEnabled), isOn: Binding(
                    get: { model.pluginSettings.isEnabled(manifest.id) },
                    set: { model.setEnabled($0, for: manifest.id) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .accessibilityIdentifier("plugin.\(plugin.folderName).enabled")
            }
        }
    }

    /// *script · 1.0.0 · every 60 s · Somebody*.
    private func subtitle(_ manifest: PluginManifest?) -> String {
        guard let manifest else { return plugin.folderName }
        var parts = ["\(manifest.kind.rawValue) · \(manifest.version)"]
        if let seconds = manifest.intervalInWholeSeconds {
            parts.append(strings(.pluginEverySeconds(seconds)))
        }
        if let author = manifest.author { parts.append(author) }
        return parts.joined(separator: " · ")
    }

    /// What sits between where it came from and the buttons along the bottom:
    /// its own settings, its last run, and where its files are.
    @ViewBuilder
    private func details(_ manifest: PluginManifest) -> some View {
        if !manifest.settings.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(strings(.pluginSettings)).font(.subheadline.weight(.semibold))
                // By position: a manifest with two settings sharing a key is
                // reported as a problem, and must still render rather than
                // collapsing two rows into one.
                ForEach(Array(manifest.settings.enumerated()), id: \.offset) { _, declaration in
                    settingControl(declaration, for: manifest.id)
                }
            }
        }

        let snapshot = model.snapshot(for: manifest.id)
        if let run = snapshot.lastRun {
            lastRun(run, of: manifest.id)
        }
        // A failure no run came to — the plugin not permitted, not loadable —
        // is said on its own: the last run above, if any, is an older one.
        if let failure = snapshot.failure,
           snapshot.lastRun.map({ $0.result != .failure(failure.reason) && $0.result != .lateCard(failure.reason) }) ?? true {
            Text(strings(.pluginLastFailure(reason: failure.reason)))
                .font(.caption).foregroundStyle(.orange)
                .accessibilityIdentifier("plugin.\(manifest.id).lastFailure")
            if !failure.diagnostics.isEmpty {
                Text(ShownStandardError.end(of: failure.diagnostics))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }

        // The home folder as `~`, as every other path in Settings is written.
        Text(model.displayPath(plugin.directory.path))
            .font(.system(.caption2, design: .monospaced))
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
    }

    /// The plugin's last run, whatever it came to — a card as much as a
    /// failure — and the end of its standard error, where the error is
    /// (`ShownStandardError`): what an author reads when a card is wrong
    /// without failing, and when it fails.
    @ViewBuilder
    private func lastRun(_ run: PluginRun, of id: PluginIdentifier) -> some View {
        Text(strings(.pluginLastRun(at: Clock.withSeconds(run.startedAt, strings), reason: run.reason,
                                    duration: run.duration, result: run.result)))
            .font(.caption)
            .foregroundStyle(run.result == .card ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("plugin.\(id).lastRun")
        if run.standardError.isEmpty {
            Text(strings(.pluginStandardErrorNothing))
                .font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("plugin.\(id).stderr")
        } else {
            Text(strings(.pluginStandardErrorEnd)).font(.caption).foregroundStyle(.secondary)
            Text(ShownStandardError.end(of: run.standardError))
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("plugin.\(id).stderr")
            if run.standardErrorDropped > 0 {
                Text(strings(.pluginStandardErrorBefore(bytes: run.standardErrorDropped)))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    /// What it asks for, and Allow and Decline: in a box of the warning's
    /// colour while nobody has decided, as the card in the panel asks.
    @ViewBuilder
    private func permissions(_ manifest: PluginManifest) -> some View {
        let requested = manifest.permissions.capabilities
        let undecided: Bool = { if case .awaitingDecision = model.launchDecision(for: manifest.id) { true } else { false } }()
        if requested.isEmpty, undecided, !model.waitsForItsTree(manifest.id), !model.folderWouldNotHash(manifest.id) {
            // Code nobody verified, asking for nothing, is asked whether it
            // may run at all — here as on its card.
            VStack(alignment: .leading, spacing: 3) {
                Text(strings(.permissionsAsksNothingUnverified(name: manifest.name)))
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("plugin.\(manifest.id).asksNothing")
                if let source = model.consentSource(for: manifest.id) {
                    Text(strings(source)).font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    let tree = model.consentTree(for: manifest.id)
                    let shownSource = model.requiredSource(for: manifest.id)
                    Button(strings(.actionAllow)) {
                        model.decidePermissions(for: manifest.id, allow: true, shown: [], shownTree: tree, shownSource: shownSource)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("plugin.\(manifest.id).allow")
                    Button(strings(.actionDecline)) {
                        model.decidePermissions(for: manifest.id, allow: false, shown: [], shownTree: tree, shownSource: shownSource)
                    }
                    .accessibilityIdentifier("plugin.\(manifest.id).decline")
                }
                .padding(.top, 2)
            }
            .permissionsBox(undecided: true)
        } else if requested.isEmpty {
            // Plain text, and no seal: a seal means one thing in uDeck — a
            // maintainer of the official repository read the plugin — and a
            // plugin asking for nothing is not a plugin somebody checked.
            Text(strings(.permissionsAsksNothing))
                .font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("plugin.\(manifest.id).asksNothing")
        } else {
            VStack(alignment: .leading, spacing: 3) {
                Text(strings(.permissionsAsksTo)).font(.subheadline.weight(.semibold))
                ForEach(Array(requested.enumerated()), id: \.offset) { _, capability in
                    HStack(spacing: 6) {
                        Image(systemName: granted(capability, manifest) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(granted(capability, manifest) ? .green : .secondary)
                        Text(strings(capability.summaryPhrase)).font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                        if capability.processEnforcement == .declaredOnly {
                            Text(strings(.permissionsDeclared))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .help(strings(.permissionsDeclaredHelp))
                        }
                    }
                }
                HStack {
                    // What the list above shows is what Allow grants (`ShownPlace.allows`).
                    let tree = model.consentTree(for: manifest.id)
                    let shownSource = model.requiredSource(for: manifest.id)
                    allowButton(prominent: undecided) {
                        model.decidePermissions(for: manifest.id, allow: true, shown: requested, shownTree: tree, shownSource: shownSource)
                    }
                    Button(strings(.actionDecline)) {
                        model.decidePermissions(for: manifest.id, allow: false, shown: requested, shownTree: tree, shownSource: shownSource)
                    }
                }
                .padding(.top, 2)
            }
            .permissionsBox(undecided: undecided)
        }
    }

    /// **Allow**, the button to press while nobody has decided.
    @ViewBuilder
    private func allowButton(prominent: Bool, action: @escaping () -> Void) -> some View {
        if prominent {
            Button(strings(.actionAllow), action: action).buttonStyle(.borderedProminent)
        } else {
            Button(strings(.actionAllow), action: action)
        }
    }

    /// Checked only under a decision that holds for this version — and, for
    /// code held to its tree, for the tree last hashed — so a decision the
    /// card asks again about is not shown as granted.
    private func granted(_ capability: Capability, _ manifest: PluginManifest) -> Bool {
        guard let grant = model.grants[manifest.id],
              grant.holds(forVersion: manifest.version, tree: model.treeLastHashed(for: manifest.id),
                          source: model.requiredSource(for: manifest.id)) else { return false }
        return grant.granted.contains(capability)
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

/// The card of a plugin installed through uDeck whose folder has gone: its
/// record still says where it came from, so it can be put back.
struct MissingPluginCard: View {
    @Bindable var model: DeckModel
    var id: String
    @Environment(\.strings) private var strings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                PluginBadge(name: id, id: id, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(id)
                        .font(.system(size: 16, weight: .bold))
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("plugins.card.\(id)")
                    Text(strings(.catalogueMissing(id: id, path: model.pluginsDirectoryDisplayPath)))
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            InstalledRepositoryControls(model: model, id: id, versionOnDisk: nil)
        }
        .lookCard()
    }
}

extension View {
    /// What a plugin asks for, in a box: of the warning's colour while nobody
    /// has decided, quiet once somebody has.
    func permissionsBox(undecided: Bool) -> some View {
        padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(undecided ? Color.orange.opacity(0.09) : Color.secondary.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(undecided ? Color.orange.opacity(0.35) : Color(nsColor: .separatorColor).opacity(0.5)))
    }
}

// MARK: - Catalogue

/// The catalogues: the official one's freshness, **Update all (N)** and
/// **Check now**, its rows; each source's rows under its name; and the two
/// switches — the official catalogue, and updates by themselves — under them.
struct CataloguePage: View {
    @Bindable var model: DeckModel
    @Environment(\.strings) private var strings

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            head
            if let trouble, model.settings.readsOfficialCatalogue {
                Label(trouble, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("catalogue.trouble")
            }
            // Only those still waiting: one updated since on its row is not
            // named any more.
            let left = model.updateAllLeft.filter(model.waitingUpdates.contains)
            if !left.isEmpty {
                Text(strings(.catalogueUpdateAllLeft(names: left.map(name(of:)).joined(separator: ", "))))
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("catalogue.updateAllLeft")
            }
            // While the official address belongs to another repository,
            // nothing of the catalogue read before is offered: uDeck asks it
            // nothing but its number (`readsOfficialRepository`).
            if model.settings.readsOfficialCatalogue, let catalogue = model.catalogue, model.readsOfficialRepository {
                if catalogue.entries.isEmpty {
                    Text(strings(.catalogueEmpty)).foregroundStyle(.secondary)
                } else {
                    CatalogueRows(model: model, entries: catalogue.entries, commit: catalogue.commit)
                }
            }

            // The sources the operator added, after the official catalogue:
            // each a catalogue of its own, read whatever the official switch
            // says.
            ForEach(model.sources, id: \.id) { source in
                SourceCatalogue(model: model, source: source)
            }

            switches
                .padding(.top, 6)
        }
    }

    /// `github.com/owner/repo · checked 14:02`, **Update all (N)**, **Check now**.
    private var head: some View {
        HStack(spacing: 10) {
            if !model.settings.readsOfficialCatalogue {
                Text(strings(.catalogueOff)).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("catalogue.status")
            } else if model.catalogueRefreshing {
                ProgressView().controlSize(.small)
                Text(strings(.catalogueReading)).font(.caption).foregroundStyle(.secondary)
            } else {
                Text(freshness).font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("catalogue.status")
            }
            Spacer(minLength: 8)
            if model.updatingAll {
                ProgressView().controlSize(.small)
            }
            // Every update waiting — a source's too — whatever the official
            // switch says: what the Catalogue tab's arrow counts.
            if model.updatesWaiting > 0 {
                Button(strings(.catalogueUpdateAll(model.updatesWaiting))) { model.updateAll() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.busyPlugin != nil || model.updatingAll)
                    // A button's title is not read back through the
                    // accessibility API; how many wait is, as its value.
                    .accessibilityValue(strings(.catalogueUpdatesWaiting(model.updatesWaiting)))
                    .accessibilityIdentifier("catalogue.updateAll")
            }
            if model.settings.readsOfficialCatalogue {
                Button(strings(.catalogueCheckNow)) { model.checkCatalogueNow() }
                    .disabled(model.catalogueRefreshing)
                    .accessibilityIdentifier("catalogue.checkNow")
            }
        }
    }

    private var switches: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                SwitchRow(strings(.pluginsOfficialCatalogue), identifier: "catalogue.enabled", isOn: Binding(
                    get: { model.settings.readsOfficialCatalogue },
                    set: { model.setOfficialCatalogue($0) }
                ))
                Text(strings(.pluginsOfficialCatalogueHelp(source: model.catalogueAddress.description)))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // While the official catalogue is on or a source is trusted: off
            // with no source trusted, nothing could update itself; a trusted
            // source's copies update themselves whatever Official catalogue
            // says (S4-04, S4-10).
            if model.settings.readsOfficialCatalogue || !model.trustedSources.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 3) {
                    SwitchRow(strings(.catalogueUpdatesByThemselves), identifier: "catalogue.autoUpdate", isOn: Binding(
                        get: { model.settings.updatesVerifiedByThemselves },
                        set: { model.setAutoUpdateVerified($0) }
                    ))
                    Text(strings(.catalogueUpdatesByThemselvesHelp))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("catalogue.autoUpdateHelp")
                }
            }
        }
        .lookCard()
    }

    private func name(of id: String) -> String {
        model.displayManifest(withID: PluginIdentifier(rawValue: id) ?? .placeholder)?.name ?? id
    }

    private var freshness: String {
        let source = model.catalogueAddress.description
        guard let success = model.catalogueState.lastSuccess else { return strings(.catalogueNeverRead(source: source)) }
        return strings(.catalogueChecked(source: source, at: Clock.text(success, strings)))
    }

    /// Why the list is not fresh, when the last refresh did not finish — in
    /// the official catalogue's words, which name GitHub (`CatalogueTrouble`).
    private var trouble: String? {
        guard let error = model.catalogueState.lastError else { return nil }
        let readAt = model.catalogue == nil ? nil : model.catalogueState.lastSuccess.map { Clock.text($0, strings) }
        return strings(CatalogueTrouble.phrase(error, address: model.catalogueAddress.description, host: nil, readAt: readAt,
                                               until: { Clock.text($0, strings) }))
    }
}

/// A setting's name on the left and its switch at the far right, as a grouped
/// form draws one — the switch keeping the name for VoiceOver, and the
/// identifier the lab reads it by.
struct SwitchRow: View {
    var title: String
    var identifier: String
    @Binding var isOn: Bool

    init(_ title: String, identifier: String, isOn: Binding<Bool>) {
        self.title = title
        self.identifier = identifier
        self._isOn = isOn
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityHidden(true)
            Spacer(minLength: 8)
            Toggle(title, isOn: $isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .accessibilityIdentifier(identifier)
        }
    }
}

/// A catalogue's rows in a card of their own, a line between them.
struct CatalogueRows: View {
    @Bindable var model: DeckModel
    var entries: [CatalogueEntry]
    var commit: String
    var source: String = InstalledPlugins.officialSource

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                if index > 0 { Divider() }
                CatalogueRowView(model: model, entry: entry, commit: commit, source: source)
                    .padding(.vertical, 8)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: .separatorColor).opacity(0.6)))
    }
}

/// A source's rows on the Catalogue tab, under its name; the source itself —
/// trust, token, removal — is on Sources.
struct SourceCatalogue: View {
    @Bindable var model: DeckModel
    var source: OwnSource
    @Environment(\.strings) private var strings

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(model.sourceName(source)).font(.subheadline.weight(.semibold))
                Text(source.address.description).font(.caption).foregroundStyle(.secondary)
            }
            .padding(.top, 6)
            // When it was read, or why not — as on Sources, where the line has
            // its identifier: a source never read, or failing since, says so
            // here too rather than leaving its rows, or no rows, unexplained.
            SourceStateLine(model: model, source: source)
            if let catalogue = model.sourceCatalogues[source.id] {
                if catalogue.entries.isEmpty {
                    Text(strings(.catalogueEmpty)).foregroundStyle(.secondary)
                        .accessibilityIdentifier("source.\(source.id).empty")
                } else {
                    CatalogueRows(model: model, entries: catalogue.entries, commit: catalogue.commit, source: source.id)
                }
            }
        }
    }
}

// MARK: - Sources

/// The sources the operator added — each a card: its name, its mark, when it
/// was read, Check now, Token…, Trust… and Remove… — then **Add a source…** and
/// **Install from a link…**, and their sheets.
struct SourcesPage: View {
    @Bindable var model: DeckModel
    @Binding var linkSheetOpen: Bool
    @Binding var linkText: String
    @Environment(\.strings) private var strings

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !model.testBuild.isEmpty {
                Text(model.testBuild.map { strings($0) }.joined(separator: "\n"))
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("sources.testBuild")
            }
            if !model.sourcesProblemLines.isEmpty {
                Text(model.sourcesProblemLines.map { strings($0) }.joined(separator: "\n"))
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("sources.problem")
            }
            if !model.sources.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(model.sources.enumerated()), id: \.element.id) { index, source in
                        if index > 0 { Divider() }
                        SourceBlock(model: model, source: source)
                            .padding(.vertical, 6)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: .separatorColor).opacity(0.6)))
            }
            HStack(spacing: 8) {
                Button("＋ " + strings(.sourcesAdd)) { model.toggleAddSource() }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("sources.add")
                LinkInstallButton(model: model, open: $linkSheetOpen)
            }
            if model.sourceSheetOpen {
                AddSourceSheet(model: model)
            }
            LinkInstallSheet(model: model, open: $linkSheetOpen, text: $linkText)
        }
    }
}

// MARK: - For developers

/// For somebody writing a plugin: a folder linked in place, the run log of
/// linked folders, where commands are looked for, and the command in the terminal.
struct DevelopersPage: View {
    @Bindable var model: DeckModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 12) {
                LinkFolderControls(model: model) { EmptyView() }
                Divider()
                RunLogControls(model: model)
            }
            .lookCard()
            SearchPathSection(model: model)
                .lookCard()
            CommandSection(model: model)
                .lookCard()
        }
    }
}
