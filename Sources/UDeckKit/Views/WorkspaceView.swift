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

    var body: some View {
        VStack(spacing: theme.rowSpacing) {
            tabBar
            content
        }
        .padding(theme.panelPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Tabs

    private var tabBar: some View {
        HStack(spacing: 5) {
            ForEach(model.layout.tabs) { tab in
                tabButton(tab)
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
        let isSelected = tab.id == model.layout.selectedTabID

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

    private func commitRename(_ id: UUID) {
        let trimmed = (shell.tabRename?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { model.renameTab(id, to: trimmed) }
        shell.tabRename = nil
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 5) {
            iconButton("rectangle.compress.vertical", help: strings(.controlDensity(name: strings(model.settings.density.namePhrase)))) {
                var settings = model.settings
                settings.density = nextDensity(after: settings.density)
                model.update(settings: settings)
            }
            iconButton("arrow.clockwise", help: strings(.controlRefresh)) {
                model.refreshAll(reason: .manual)
            }
            iconButton("gearshape", help: strings(.controlSettings)) {
                shell.onOpenSettings()
            }
            iconButton("chevron.up", help: strings(.controlSendAway)) {
                shell.onCollapse()
            }
            iconButton(
                shell.phase == .fullscreen
                    ? "arrow.down.right.and.arrow.up.left"
                    : "arrow.up.left.and.arrow.down.right",
                help: shell.phase == .fullscreen ? "Back to the working size" : "Fill the screen"
            ) {
                shell.onToggleFullscreen()
            }
        }
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
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
    }

    private func nextDensity(after density: Density) -> Density {
        let all = Density.allCases
        let index = all.firstIndex(of: density) ?? 0
        return all[(index + 1) % all.count]
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let tab = model.layout.selectedTab {
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
