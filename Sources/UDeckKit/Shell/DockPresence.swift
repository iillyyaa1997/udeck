import AppKit
import UDeckCore

/// The application's own `DockHolders`, applied to its activation policy.
@MainActor
public enum DockPresence {
    private static var holders = DockHolders()

    /// `holder` keeps uDeck in the Dock and in Cmd+Tab until it lets go.
    public static func hold(_ holder: String) {
        holders.hold(holder)
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
    }

    /// `holder` lets go. The last one out makes uDeck an accessory again — a
    /// turn of the run loop later, because changing the policy while the
    /// window that needed it is still closing leaves the Dock icon behind; and
    /// not at all if a window took hold again in that turn.
    public static func release(_ holder: String) {
        holders.release(holder)
        DispatchQueue.main.async {
            guard !holders.inTheDock, NSApp.activationPolicy() != .accessory else { return }
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
