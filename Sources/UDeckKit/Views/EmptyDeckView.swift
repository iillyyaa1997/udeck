import SwiftUI
import UDeckCore

/// What an install with nothing in it looks like.
///
/// This is not a corner case. uDeck ships no content of its own on purpose, so
/// an empty panel is the first thing every new person sees and the state anyone
/// returns to after clearing a tab. It has to read as an invitation rather than
/// as something that failed to load — which means naming what is missing, and
/// putting the way to fix it within one click.
struct EmptyDeckView: View {
    @Environment(\.strings) private var strings
    var model: DeckModel
    var theme: DeckTheme
    var tabID: UUID?
    @Bindable var shell: ShellState

    /// Every folder found, including the ones that failed to load.
    ///
    /// A plugin that simply does not appear is a support question; one that
    /// appears saying "run.sh is not executable" is a five-second fix.
    private var installed: [DiscoveredPlugin] { model.plugins }

    var body: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 0)

            Image(systemName: "square.grid.2x2")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(theme.dim)

            Text(installed.isEmpty ? strings(.emptyNoPlugins) : strings(.emptyTabEmpty))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(theme.text)

            Text(installed.isEmpty
                 ? strings(.emptyNoPluginsBody(path: model.pluginsDirectoryDisplayPath))
                 : strings(.emptyTabEmptyBody))
                .font(theme.bodyFont)
                .foregroundStyle(theme.dim)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)

            if !installed.isEmpty, let tabID {
                pluginPicker(tabID: tabID)
            }

            HStack(spacing: 8) {
                Button(strings(.emptyOpenPluginsFolder)) {
                    shell.onInteract()
                    model.revealPluginsDirectory()
                }
                .buttonStyle(GhostButtonStyle(theme: theme))

                Button(strings(.emptyLookAgain)) {
                    shell.onInteract()
                    model.discoverPlugins()
                }
                .buttonStyle(GhostButtonStyle(theme: theme))
            }

            if !model.problems.isEmpty {
                problems
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func pluginPicker(tabID: UUID) -> some View {
        VStack(spacing: 6) {
            ForEach(installed, id: \.id) { plugin in
                Button {
                    shell.onInteract()
                    if let id = plugin.manifest?.id { model.addWindow(pluginID: id, to: tabID) }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: plugin.isUsable ? "square.dashed.inset.filled" : "exclamationmark.triangle")
                            .foregroundStyle(plugin.isUsable ? theme.accent : theme.warn)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(model.displayManifest(for: plugin)?.name ?? plugin.folderName)
                                .font(theme.bodyFont)
                                .foregroundStyle(theme.text)
                            Text(subtitle(for: plugin))
                                .font(theme.chipFont)
                                .foregroundStyle(plugin.isUsable ? theme.dim : theme.warn)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                        }
                        Spacer(minLength: 0)
                        if plugin.isUsable {
                            Text(strings(.emptyAdd)).font(theme.chipFont).foregroundStyle(theme.accent)
                        }
                    }
                    .padding(.horizontal, 11)
                    .padding(.vertical, 8)
                    .frame(maxWidth: 420)
                    .background(RoundedRectangle(cornerRadius: 11).fill(theme.windowFill))
                    .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(theme.line))
                }
                .buttonStyle(.plain)
                .disabled(!plugin.isUsable)
                .help(plugin.isUsable ? "Add to this tab" : plugin.problems.first?.description ?? "")
            }
        }
    }

    private func subtitle(for plugin: DiscoveredPlugin) -> String {
        if let problem = plugin.problems.first { return problem.description }
        guard let manifest = model.displayManifest(for: plugin) else { return plugin.folderName }
        if let description = manifest.description { return description }
        return "\(manifest.kind.rawValue) · every \(Int(manifest.interval ?? 0))s"
    }

    private var problems: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(model.problems.enumerated()), id: \.offset) { _, problem in
                Text(problem)
                    .font(theme.chipFont)
                    .foregroundStyle(theme.warn)
                    .lineLimit(3)
            }
        }
        .padding(9)
        .frame(maxWidth: 460)
        .background(RoundedRectangle(cornerRadius: 9).fill(theme.recess))
    }
}

struct GhostButtonStyle: ButtonStyle {
    var theme: DeckTheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(theme.chipFont)
            .foregroundStyle(theme.muted)
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 8).fill(theme.hoverFill(pressed: configuration.isPressed)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(theme.line))
    }
}
