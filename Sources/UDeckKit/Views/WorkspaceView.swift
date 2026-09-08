import SwiftUI
import UDeckCore

/// The working panel: tabs across the top, a grid of windows below.
struct WorkspaceView: View {
    @Bindable var shell: ShellState
    var model: DeckModel
    var theme: DeckTheme

    @State private var renamingTab: UUID?
    @State private var draftName = ""

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
                renamingTab = id
                draftName = "New tab"
            } label: {
                Text("+").font(theme.monoFont).foregroundStyle(theme.dim)
                    .padding(.horizontal, 9).padding(.vertical, 4)
            }
            .buttonStyle(.plain)
            .help("Add a tab")

            Spacer(minLength: 8)
            controls
        }
    }

    @ViewBuilder
    private func tabButton(_ tab: DeckTab) -> some View {
        let isSelected = tab.id == model.layout.selectedTabID

        if renamingTab == tab.id {
            TextField("Tab name", text: $draftName)
                .textFieldStyle(.plain)
                .font(theme.bodyFont)
                .foregroundStyle(theme.text)
                .frame(width: 110)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 9).fill(theme.recess))
                .focused($renameFieldFocused)
                .onAppear { renameFieldFocused = true }
                .onSubmit { commitRename(tab.id) }
                .onExitCommand { renamingTab = nil }
        } else {
            Button {
                shell.onInteract()
                if isSelected {
                    renamingTab = tab.id
                    draftName = tab.name
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
                            RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.14))
                        }
                    }
            }
            .buttonStyle(.plain)
            .help(isSelected ? "Click again to rename" : "Show this tab")
            .contextMenu {
                Button("Rename") { renamingTab = tab.id; draftName = tab.name }
                Button("Close tab", role: .destructive) { model.removeTab(tab.id) }
                    .disabled(model.layout.tabs.count <= 1)
            }
        }
    }

    private func commitRename(_ id: UUID) {
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { model.renameTab(id, to: trimmed) }
        renamingTab = nil
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 5) {
            iconButton("rectangle.compress.vertical", help: "Density: \(model.settings.density.rawValue)") {
                var settings = model.settings
                settings.density = nextDensity(after: settings.density)
                model.update(settings: settings)
            }
            iconButton("arrow.clockwise", help: "Refresh everything now") {
                model.refreshAll(reason: .manual)
            }
            iconButton("gearshape", help: "Settings") {
                shell.onOpenSettings()
            }
            iconButton("chevron.up", help: "Send the panel away") {
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
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.06)))
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
