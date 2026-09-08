import SwiftUI
import UDeckCore

/// Asks the operator about what a plugin says it needs.
///
/// The wording matters and is deliberate. It says the plugin *asked* for these
/// things, and that uDeck will not run it until the operator agrees — because
/// that is the part uDeck can actually keep. It does not say the plugin is
/// "restricted" or "sandboxed": a plugin is an ordinary program run as the
/// operator, and once it is running it can do whatever the operator can. The
/// honest promise is "it does not run unless you say so", plus real control over
/// the things uDeck itself does on the plugin's behalf — secrets it hands over,
/// and commands it runs from a card's buttons.
struct PermissionRequestView: View {
    var model: DeckModel
    var theme: DeckTheme
    var pluginID: PluginIdentifier
    var manifest: PluginManifest?
    var pending: [Capability]
    @Bindable var shell: ShellState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(manifest?.name ?? pluginID.rawValue) asks to:")
                .font(theme.bodyFont)
                .foregroundStyle(theme.text)

            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(pending.enumerated()), id: \.offset) { _, capability in
                    HStack(alignment: .top, spacing: 7) {
                        Image(systemName: symbol(for: capability))
                            .font(.system(size: 9))
                            .foregroundStyle(theme.warn)
                            .frame(width: 12)
                        Text(capability.summary)
                            .font(theme.chipFont)
                            .foregroundStyle(theme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Text("uDeck runs this plugin as you, without a sandbox. Allowing it means agreeing to run this program; declining means uDeck never starts it.")
                .font(.system(size: 9.5))
                .foregroundStyle(theme.dim)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 7) {
                Button("Allow and run") {
                    shell.onInteract()
                    model.decidePermissions(for: pluginID, allow: true)
                }
                .buttonStyle(GhostButtonStyle(theme: theme))

                Button("Decline") {
                    shell.onInteract()
                    model.decidePermissions(for: pluginID, allow: false)
                }
                .buttonStyle(GhostButtonStyle(theme: theme))
            }
        }
    }

    private func symbol(for capability: Capability) -> String {
        switch capability.family {
        case .read: "doc.text"
        case .write: "square.and.pencil"
        case .exec: "terminal"
        case .network: "network"
        case .screen: "macwindow.on.rectangle"
        case .secret: "key"
        }
    }
}
