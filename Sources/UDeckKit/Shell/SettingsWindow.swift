import AppKit
import SwiftUI
import UDeckCore

/// Holds the settings window.
///
/// A real window rather than a page inside the panel: settings are read and
/// changed with two hands and a keyboard, and the panel is a surface that
/// deliberately retracts the moment attention moves elsewhere. Putting them in
/// the panel would mean either breaking that rule or losing the settings
/// half-way through changing them.
@MainActor
public final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let model: DeckModel
    private let updater: (any UpdateChecking)?

    public init(model: DeckModel, updater: (any UpdateChecking)? = nil) {
        self.model = model
        self.updater = updater
        super.init()
    }

    public func show() {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 820, height: 560),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = model.strings(.settingsWindowTitle)
            window.isReleasedWhenClosed = false
            window.center()
            window.contentView = NSHostingView(
                rootView: SettingsView(model: model, updater: updater)
            )
            window.delegate = self
            self.window = window
        }

        applyAppearance()

        // uDeck is an accessory application: no Dock icon, and — the part that
        // matters here — not in the ⌘-Tab switcher. That is right for a panel
        // that lives at the edge of the screen and wrong for a window somebody
        // is working in, because a window you cannot switch back to is a window
        // you have to close and reopen.
        //
        // So the policy is `.regular` for exactly as long as this window is
        // open. The Dock icon that comes with it is the price, and it leaves
        // again with the window.
        NSApp.setActivationPolicy(.regular)

        // Settings are the one part of uDeck the operator works in with the
        // keyboard, so this is the one place activation is unambiguously right.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    public func windowWillClose(_ notification: Notification) {
        // Back to an accessory. Deferred by one turn of the run loop because
        // changing the policy while the window that made it necessary is still
        // closing leaves the Dock icon behind.
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    /// Brings the window's own text into line with the settings.
    ///
    /// It used to dress the whole window as the panel was dressed — light ink
    /// meant a dark window — on the reasoning that the window you set a look in
    /// should wear it. In use that is the wrong thing entirely: the Text control
    /// flips the panel's ink, and what the operator saw flip was the settings
    /// window. "I change the text and the application's colour changes, not the
    /// colours." A control has to change the thing it names, and the panel is
    /// already on screen twice over — as the sample above the controls, and as
    /// the panel itself.
    ///
    /// So the window follows macOS again, like every other window, and only its
    /// title is ours to keep current: the language can change while the window
    /// is merely closed rather than gone.
    public func applyAppearance() {
        window?.title = model.strings(.settingsWindowTitle)
    }
}
