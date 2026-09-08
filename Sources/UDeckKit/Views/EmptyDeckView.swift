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
    var model: DeckModel
    var theme: DeckTheme
    var tabID: UUID?
    @Bindable var shell: ShellState

    private var installed: [DiscoveredPlugin] {
        model.plugins.filter { $0.manifest != nil }
    }

    var body: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 0)

            Image(systemName: "square.grid.2x2")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(theme.dim)

            Text(installed.isEmpty ? "No plugins installed" : "This tab is empty")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(theme.text)

            Text(installed.isEmpty
                 ? "uDeck shows nothing by itself — everything in the panel comes from a plugin. Put one in \(model.pluginsDirectoryDisplayPath) to begin."
                 : "Add one of the installed plugins to this tab.")
                .font(theme.bodyFont)
                .foregroundStyle(theme.dim)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)

            if !installed.isEmpty, let tabID {
                pluginPicker(tabID: tabID)
            }

            HStack(spacing: 8) {
                Button("Open the plugins folder") {
                    shell.onInteract()
                    model.revealPluginsDirectory()
                }
                .buttonStyle(GhostButtonStyle(theme: theme))

                Button("Look for plugins again") {
                    shell.onInteract()
                    model.discoverPlugins()
                }
                .buttonStyle(GhostButtonStyle(theme: theme))
            }

            if !model.startupProblems.isEmpty {
                problems
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func pluginPicker(tabID: UUID) -> some View {
        VStack(spacing: 6) {
            ForEach(installed, id: \.id) { plugin in
                if let manifest = plugin.manifest {
                    Button {
                        shell.onInteract()
                        model.addWindow(pluginID: manifest.id, to: tabID)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: plugin.isUsable ? "square.dashed.inset.filled" : "exclamationmark.triangle")
                                .foregroundStyle(plugin.isUsable ? theme.accent : theme.warn)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(manifest.name)
                                    .font(theme.bodyFont)
                                    .foregroundStyle(theme.text)
                                Text(plugin.isUsable
                                     ? (manifest.description ?? "\(manifest.kind.rawValue) · every \(Int(manifest.interval ?? 0))s")
                                     : plugin.problems.first?.description ?? "not usable")
                                    .font(theme.chipFont)
                                    .foregroundStyle(plugin.isUsable ? theme.dim : theme.warn)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            Text("Add").font(theme.chipFont).foregroundStyle(theme.accent)
                        }
                        .padding(.horizontal, 11)
                        .padding(.vertical, 8)
                        .frame(maxWidth: 420)
                        .background(RoundedRectangle(cornerRadius: 11).fill(theme.windowFill))
                        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(theme.line))
                    }
                    .buttonStyle(.plain)
                    .disabled(!plugin.isUsable)
                }
            }
        }
    }

    private var problems: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(model.startupProblems.enumerated()), id: \.offset) { _, problem in
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
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(configuration.isPressed ? 0.12 : 0.05)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(theme.line))
    }
}
