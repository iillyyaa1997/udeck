import AppKit
import SwiftUI
import UDeckCore

// Settings → Plugins, the parts for somebody writing a plugin: **Link a
// folder…**, the run log of linked folders, **Where to look for commands**,
// and **Install command**. Every control carries an accessibility identifier —
// the titles are translated, and the lab drives these screens by identifier.

// MARK: - Choosing a folder

/// A folder chosen in the system's own panel, handed to `done` — nothing when
/// the operator cancels. A sheet on the Settings window the button is in, so
/// that the window is the one still active when the panel goes: measured in
/// the lab on 2026-10-05, a panel of its own handed the activation to Finder
/// as it closed, and the first click on the warning that followed — **Link** —
/// only brought Settings forward (.build/e2e/20261005-002535Z,
/// plugins.link-a-folder). It is reached the way a person reaches it, and the
/// lab the way a person would: ⌘⇧G, a path, Return.
@MainActor
func chooseFolder(message: String, prompt: String, done: @escaping @MainActor (URL) -> Void) {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = false
    panel.message = message
    panel.prompt = prompt
    let window = NSApp.keyWindow
    let chosen: (NSApplication.ModalResponse) -> Void = { response in
        MainActor.assumeIsolated {
            // Settings again, whichever way the panel went.
            NSApp.activate(ignoringOtherApps: true)
            window?.makeKeyAndOrderFront(nil)
            guard response == .OK, let url = panel.url else { return }
            done(url)
        }
    }
    if let window {
        panel.beginSheetModal(for: window, completionHandler: chosen)
    } else {
        NSApp.activate(ignoringOtherApps: true)
        panel.begin(completionHandler: chosen)
    }
}

// MARK: - Link a folder…

/// **Link a folder…** (Q126): a folder chosen, linked into the plugins folder
/// under its manifest's id. A free id is linked at once; a taken one is linked
/// only after the warning says what becomes of what is there
/// (`PlaceWarning.linking`), as **Replace…** does.
struct LinkFolderControls: View {
    @Bindable var model: DeckModel
    @Environment(\.strings) private var strings
    /// What the last press came to.
    @State private var outcome: DeckModel.FolderLinking?
    /// The folder the warning is up for.
    @State private var pending: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(strings(.linkFolder)) {
                chooseFolder(message: strings(.linkFolderPanelMessage), prompt: strings(.linkFolderLink)) { folder in
                    link(folder, confirmed: nil)
                }
            }
            .disabled(model.busyPlugin != nil)
            .accessibilityIdentifier("plugins.linkFolder")

            if let outcome {
                said(outcome)
            }
        }
    }

    /// The folder linked — at once, or over what is at its id once the
    /// warning `confirmed` is what the operator read; when it no longer says
    /// what is there, the answer is the warning of what is there now.
    private func link(_ folder: URL, confirmed: ShownPlace.Linking?) {
        pending = nil
        Task {
            let came = await model.linkFolder(folder, confirmed: confirmed)
            outcome = came
            if case .needsConfirmation = came { pending = folder }
        }
    }

    @ViewBuilder
    private func said(_ outcome: DeckModel.FolderLinking) -> some View {
        switch outcome {
        case .linked(let id, let target):
            line(strings(.linkFolderLinked(id: id, target: model.displayPath(target))), trouble: false)
        case .alreadyLinked(let id, let target):
            line(strings(.linkFolderAlready(id: id, target: model.displayPath(target))), trouble: false)
        case .needsConfirmation(let shown):
            if let folder = pending,
               let warning = PlaceWarning.linking(id: shown.id, folder: folder.path,
                                                  occupant: shown.occupant, toTrash: shown.toTrash,
                                                  path: model.pluginsDirectoryDisplayPath,
                                                  shown: { model.displayPath($0) }) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(strings(warning)).font(.caption).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("plugins.linkFolder.confirmText")
                    HStack {
                        // Held to what the warning says: what is at the id
                        // when this is pressed has to be what it said.
                        Button(strings(.linkFolderLink), role: .destructive) { link(folder, confirmed: shown) }
                            .accessibilityIdentifier("plugins.linkFolder.confirm")
                        Button(strings(.actionCancel)) {
                            pending = nil
                            self.outcome = nil
                        }
                        .accessibilityIdentifier("plugins.linkFolder.cancel")
                    }
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.1)))
            }
        case .refused(let refusal):
            line(strings(.linkFolderRefused(refusal)), trouble: true)
        }
    }

    private func line(_ text: String, trouble: Bool) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(trouble ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .accessibilityIdentifier("plugins.linkFolder.outcome")
    }
}

// MARK: - The run log

/// **Keep a run log for linked folders** (Q127), what it does, and **Show the
/// logs** once there is one.
struct RunLogControls: View {
    @Bindable var model: DeckModel
    @Environment(\.strings) private var strings

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Toggle(strings(.runLogSwitch), isOn: Binding(
                    get: { model.settings.writesLinkedFolderRunLog },
                    set: { model.setLinkedFolderRunLog($0) }
                ))
                .accessibilityIdentifier("plugins.runLog")
                if model.runLogsWritten {
                    Button(strings(.runLogShow)) { model.revealRunLogs() }
                        .accessibilityIdentifier("plugins.runLog.show")
                }
            }
            Text(strings(.runLogHelp(path: model.runLogsDisplayPath)))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { model.refreshRunLogsWritten() }
    }
}

// MARK: - Where to look for commands

/// **Where to look for commands** (Q142): the folders a bare command is looked
/// up in, in order — add, remove, move, restore the defaults — each change
/// written at once and read by the next run (`SearchPathList`).
struct SearchPathSection: View {
    @Bindable var model: DeckModel
    @Environment(\.strings) private var strings
    @State private var selected: Int?

    private var list: [String] { model.settings.pluginExecutableSearchPath }

    var body: some View {
        SettingsBlock(strings(.searchPathTitle)) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(list.enumerated()), id: \.offset) { index, folder in
                    row(index, folder)
                    if index < list.count - 1 { Divider() }
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
            .frame(maxWidth: 560, alignment: .leading)

            HStack(spacing: 6) {
                Button("＋ " + strings(.searchPathAdd)) {
                    chooseFolder(message: strings(.searchPathPanelMessage), prompt: strings(.searchPathPanelAdd)) { folder in
                        let added = SearchPathList.adding(folder.path, to: list)
                        if added != list {
                            model.setSearchPath(added)
                            selected = 0
                        } else {
                            selected = list.firstIndex { $0.utf8.elementsEqual(folder.path.utf8) }
                        }
                    }
                }
                .accessibilityIdentifier("searchPath.add")
                Button("−") {
                    guard let index = selected else { return }
                    model.setSearchPath(SearchPathList.removing(at: index, from: list))
                    selected = nil
                }
                .disabled(selected.map { !SearchPathList.canRemove(at: $0, from: list) } ?? true)
                .help(selected.map { SearchPathList.canRemove(at: $0, from: list) } ?? true
                      ? strings(.searchPathRemove) : strings(.searchPathKeepOne))
                .accessibilityLabel(strings(.searchPathRemove))
                .accessibilityIdentifier("searchPath.remove")
                Button("↑") { move(by: -1) }
                    .disabled((selected ?? 0) == 0)
                    .help(strings(.searchPathUp))
                    .accessibilityLabel(strings(.searchPathUp))
                    .accessibilityIdentifier("searchPath.up")
                Button("↓") { move(by: 1) }
                    .disabled(selected.map { $0 >= list.count - 1 } ?? true)
                    .help(strings(.searchPathDown))
                    .accessibilityLabel(strings(.searchPathDown))
                    .accessibilityIdentifier("searchPath.down")
                Button(strings(.searchPathRestore)) {
                    model.setSearchPath(SearchPathList.defaults)
                    selected = nil
                }
                .disabled(list == SearchPathList.defaults)
                .accessibilityIdentifier("searchPath.restore")
            }
            Text(strings(.searchPathHelp))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func move(by offset: Int) {
        guard let index = selected else { return }
        let moved = SearchPathList.moving(at: index, by: offset, in: list)
        guard moved != list else { return }
        model.setSearchPath(moved)
        selected = index + offset
    }

    /// One folder of the list: chosen by a click, for **−**, **↑** and **↓** —
    /// and chosen it stays: a click that let go of the row chosen already,
    /// right after **＋ Add a folder…** chose the folder it added, left the
    /// arrows with nothing to move (.build/e2e/20261005-013146Z).
    ///
    /// A row of texts with a tap rather than a button: a button's words are
    /// its label, which the accessibility API hands out as no title at all
    /// (measured in the lab on 2026-10-05, .build/e2e/20261005-012534Z,
    /// plugins.search-path-field), and the folder it shows has to be readable
    /// by its own identifier — by the lab, and by anything else that reads the
    /// screen.
    private func row(_ index: Int, _ folder: String) -> some View {
        let standing = SearchPathList.standing(of: folder)
        // Chosen, as a list chooses: a click on the row chosen already keeps it.
        let choose = { selected = index }
        return HStack(spacing: 8) {
            Text(model.displayPath(folder))
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(standing == .notAFullPath ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .accessibilityIdentifier("searchPath.folder.\(index)")
            Spacer(minLength: 8)
            if standing != .lookedIn {
                Text(strings(.searchPathStanding(standing)))
                    .font(.caption).foregroundStyle(.orange)
                    .accessibilityIdentifier("searchPath.standing.\(index)")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(selected == index ? Color.accentColor.opacity(0.18) : Color.clear)
        .onTapGesture(perform: choose)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(selected == index ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { choose() }
        .accessibilityIdentifier("searchPath.row.\(index)")
    }
}

// MARK: - Install command

/// **Install command** (Q129): `udeck-plugin` from inside this uDeck, linked
/// into `~/.local/bin` — what is there now, the button that goes with it, and
/// whether the operator's shell finds it.
struct CommandSection: View {
    @Bindable var model: DeckModel
    @Environment(\.strings) private var strings

    var body: some View {
        SettingsBlock(strings(.commandTitle)) {
            let path = model.commandDisplayPath
            let command = model.command
            let buttons = command.buttons(for: model.commandState)
            if command.helper == nil {
                note(strings(.commandNoHelper), trouble: true, identifier: "command.noHelper")
            } else if command.place != .lasting {
                // Said instead of the button, which is not offered
                // (`CommandInstall.buttons`): a link to this copy would lead
                // nowhere once it goes.
                note(strings(.commandNotLasting(command.place)), trouble: true, identifier: "command.notLasting")
            }
            switch model.commandState {
            case .notInstalled:
                note(strings(.commandNotInstalled(path: path)), trouble: false, identifier: "command.state")
            case .installed:
                note(strings(.commandInstalled(path: path)), trouble: false, identifier: "command.state")
            case .otherCopy(let target):
                note(strings(.commandOtherCopy(path: path, target: model.displayPath(target))), trouble: true,
                     identifier: "command.state")
            case .foreign(let what):
                note(strings(.commandForeign(path: path, what: what)), trouble: true, identifier: "command.state")
            }
            HStack(spacing: 8) {
                if buttons.contains(.install) {
                    Button(strings(.commandInstall)) { model.installCommand() }
                        .accessibilityIdentifier("command.install")
                }
                if buttons.contains(.remove) {
                    Button(strings(.commandRemove)) { model.removeCommand() }
                        .accessibilityIdentifier("command.remove")
                }
            }
            if let problem = model.commandProblem {
                note(said(problem, path: path), trouble: true, identifier: "command.problem")
            }
            shell
        }
        .onAppear { model.refreshCommandState() }
    }

    @ViewBuilder private var shell: some View {
        let folder = model.commandFolderDisplayPath
        switch model.shellFindsCommand {
        case .notAsked:
            EmptyView()
        case .asking:
            ProgressView().controlSize(.small)
        case .finds:
            note(strings(.commandOnPath(folder: folder)), trouble: false, identifier: "command.shell")
        case .doesNotFind(let shell, let file, let line):
            note(strings(.commandNotOnPath(folder: folder, shell: shell, file: file)), trouble: true,
                 identifier: "command.shell")
            Text(line)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .accessibilityIdentifier("command.line")
        case .cannotTell:
            note(strings(.commandPathUnknown(folder: folder)), trouble: false, identifier: "command.shell")
        }
    }

    private func said(_ problem: CommandInstall.Refusal, path: String) -> String {
        switch problem {
        case .noHelper: strings(.commandNoHelper)
        case .temporaryPlace(let place): strings(.commandNotLasting(place))
        case .foreign(let what): strings(.commandForeign(path: path, what: what))
        case .cannotWrite(let reason): strings(.commandCouldNot(reason: reason))
        }
    }

    private func note(_ text: String, trouble: Bool, identifier: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(trouble ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .accessibilityIdentifier(identifier)
    }
}
