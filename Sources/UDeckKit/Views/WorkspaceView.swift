import SwiftUI
import UDeckCore

/// The working panel: tabs across the top, a grid of windows below.
struct WorkspaceView: View {
    @Environment(\.strings) private var strings
    @Bindable var shell: ShellState
    var model: DeckModel
    var theme: DeckTheme


    /// A field that appears without focus is a field the operator has to click
    /// a second time, and the second click is easy to mistake for the first not
    /// having worked.
    @FocusState private var renameFieldFocused: Bool
    /// **+ Plugin**'s list, open under it.
    @State private var addPluginOpen = false

    var body: some View {
        VStack(spacing: theme.rowSpacing) {
            tabBar
            content
        }
        .overlay(alignment: .topTrailing) { addPluginList }
        .padding(theme.panelPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Tabs

    private var tabBar: some View {
        HStack(spacing: 5) {
            ForEach(model.layout.tabs) { tab in
                tabButton(tab)
            }
            // A card shown as a whole tab has a tab of its own, after the board's.
            ForEach(model.layout.windowsAway.filter { $0.place == .tab }) { window in
                placedTabButton(window)
            }

            Button {
                shell.onInteract()
                let id = model.addTab(named: "New tab")
                shell.tabRename = ShellState.TabRename(tabID: id, text: "New tab")
            } label: {
                Text("+").font(theme.monoFont).foregroundStyle(theme.dim)
                    .padding(.horizontal, 9).padding(.vertical, 4)
            }
            .buttonStyle(.plain)
            .help(strings(.tabAdd))

            Spacer(minLength: 8)
            controls
        }
    }

    @ViewBuilder
    private func tabButton(_ tab: DeckTab) -> some View {
        let isSelected = tab.id == model.layout.selectedTabID && model.tabShown == nil

        if shell.tabRename?.tabID == tab.id {
            TextField(strings(.tabName), text: Binding(
                get: { shell.tabRename?.text ?? tab.name },
                set: { shell.tabRename = ShellState.TabRename(tabID: tab.id, text: $0) }
            ))
                .textFieldStyle(.plain)
                .font(theme.bodyFont)
                .foregroundStyle(theme.text)
                .frame(width: 110)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 9).fill(theme.recess))
                .focused($renameFieldFocused)
                .onAppear { renameFieldFocused = true }
                // Losing focus commits rather than discards. Clicking away from
                // a half-typed name used to throw it away silently — the only
                // way to keep it was to notice that Return was required.
                .onChange(of: renameFieldFocused) { _, focused in
                    if !focused, shell.tabRename?.tabID == tab.id { commitRename(tab.id) }
                }
                .onSubmit { commitRename(tab.id) }
                .onExitCommand { shell.tabRename = nil }
        } else {
            Button {
                shell.onInteract()
                if isSelected {
                    shell.tabRename = ShellState.TabRename(tabID: tab.id, text: tab.name)
                } else {
                    model.selectTab(tab.id)
                }
            } label: {
                Text(tab.name)
                    .font(theme.bodyFont)
                    .foregroundStyle(isSelected ? theme.text : theme.muted)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 4)
                    .background {
                        if isSelected {
                            RoundedRectangle(cornerRadius: 9).fill(theme.selection)
                        }
                    }
            }
            .buttonStyle(.plain)
            .help(isSelected ? strings(.tabClickAgainToRename) : strings(.tabShowThis))
            .contextMenu {
                Button(strings(.tabRename)) {
                    shell.tabRename = ShellState.TabRename(tabID: tab.id, text: tab.name)
                }
                Button(strings(.tabClose), role: .destructive) { model.removeTab(tab.id) }
                    .disabled(model.layout.tabs.count <= 1)
            }
        }
    }

    /// The tab of a card shown as a whole tab: named after it; its
    /// right-click brings it back to its cell.
    private func placedTabButton(_ window: GridWindow) -> some View {
        let isSelected = model.tabShown == window.id
        let name = window.title ?? model.presentation(for: window.pluginID).card?.title
            ?? model.displayManifest(withID: window.pluginID)?.name ?? window.pluginID.rawValue
        return Button {
            shell.onInteract()
            model.selectTabShown(window.id)
        } label: {
            Text(name)
                .font(theme.bodyFont)
                .foregroundStyle(isSelected ? theme.text : theme.muted)
                .lineLimit(1)
                .frame(maxWidth: 180)
                .padding(.horizontal, 11)
                .padding(.vertical, 4)
                .background {
                    if isSelected { RoundedRectangle(cornerRadius: 9).fill(theme.selection) }
                }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("tab.placed.\(window.pluginID.rawValue)")
        .contextMenu {
            Button(strings(.placeBringBack)) { model.show(window.id, in: .card) }
        }
    }

    private func commitRename(_ id: UUID) {
        let trimmed = (shell.tabRename?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { model.renameTab(id, to: trimmed) }
        shell.tabRename = nil
    }

    // MARK: - Controls

    /// The panel's own buttons. Density is not one of them: it is set in
    /// Settings → Look, and a button that only stepped through it was taken
    /// off the panel (the operator, 2026-10-05). Each carries an identifier,
    /// so the lab reads which are there.
    private var controls: some View {
        HStack(spacing: 5) {
            addPlugin
            iconButton("arrow.clockwise", help: strings(.controlRefresh), identifier: "panel.refresh") {
                model.refreshAll(reason: .manual)
            }
            iconButton("gearshape", help: strings(.controlSettings), identifier: "panel.settings") {
                shell.onOpenSettings()
            }
            iconButton("chevron.up", help: strings(.controlSendAway), identifier: "panel.sendAway") {
                shell.onCollapse()
            }
            iconButton(
                shell.phase == .fullscreen
                    ? "arrow.down.right.and.arrow.up.left"
                    : "arrow.up.left.and.arrow.down.right",
                help: shell.phase == .fullscreen ? "Back to the working size" : "Fill the screen",
                identifier: "panel.fullscreen"
            ) {
                shell.onToggleFullscreen()
            }
        }
    }

    private func iconButton(_ symbol: String, help: String, identifier: String,
                            action: @escaping () -> Void) -> some View {
        Button {
            shell.onInteract()
            action()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(theme.muted)
                .frame(width: 26, height: 22)
                .background(RoundedRectangle(cornerRadius: 7).fill(theme.subtleFill))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(theme.line))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityIdentifier(identifier)
    }

    /// **+ Plugin** (0.8.7): the installed plugins that can run, as the empty
    /// tab lists them, and the one chosen put on the tab showing, in its first
    /// gap. Until 0.8.7 a plugin could be put only on an empty tab: the
    /// operator could not find how to add a second (2026-11-18). A list drawn
    /// in the panel rather than a menu: a SwiftUI `Menu` there made the lab's
    /// accessibility walk of the panel end in an exception (run 44262899356).
    private var usablePlugins: [DiscoveredPlugin] {
        model.plugins.filter { $0.isUsable && $0.manifest != nil }
    }

    @ViewBuilder
    private var addPlugin: some View {
        if model.layout.selectedTab != nil, !usablePlugins.isEmpty {
            Button {
                shell.onInteract()
                addPluginOpen.toggle()
            } label: {
                Text(strings(.controlAddPlugin)).font(theme.chipFont)
                    .foregroundStyle(addPluginOpen ? theme.text : theme.muted)
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background(RoundedRectangle(cornerRadius: 7).fill(addPluginOpen ? theme.selection : theme.subtleFill))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(theme.line))
            }
            .buttonStyle(.plain)
            .help(strings(.controlAddPluginHelp))
            .accessibilityIdentifier("panel.addPlugin")
        }
    }

    @ViewBuilder
    private var addPluginList: some View {
        if addPluginOpen, let tabID = model.layout.selectedTab?.id {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(usablePlugins, id: \.id) { plugin in
                    Button {
                        shell.onInteract()
                        addPluginOpen = false
                        if let id = plugin.manifest?.id { model.addWindow(pluginID: id, to: tabID) }
                    } label: {
                        Text(model.displayManifest(for: plugin)?.name ?? plugin.folderName)
                            .font(theme.bodyFont).foregroundStyle(theme.text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 9).padding(.vertical, 5)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("panel.addPlugin.\(plugin.manifest?.id.rawValue ?? plugin.folderName)")
                }
            }
            .padding(5)
            .frame(width: 220)
            .background(RoundedRectangle(cornerRadius: 10).fill(theme.windowFill))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(theme.line))
            .shadow(radius: 8)
            .padding(.top, 30)
            .padding(.trailing, 120)
            .onExitCommand { addPluginOpen = false }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let shown = model.tabShown, model.layout.window(withID: shown)?.window.place == .tab {
            PlacedCard(model: model, theme: theme, windowID: shown, shell: shell)
        } else if let tab = model.layout.selectedTab {
            if tab.windows.isEmpty {
                EmptyDeckView(model: model, theme: theme, tabID: tab.id, shell: shell)
            } else {
                DeckGridView(model: model, theme: theme, tab: tab, shell: shell)
            }
        } else {
            EmptyDeckView(model: model, theme: theme, tabID: nil, shell: shell)
        }
    }
}
