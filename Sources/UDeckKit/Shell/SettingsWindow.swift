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
public final class SettingsWindowController {
    private var window: NSWindow?
    private let model: DeckModel

    public init(model: DeckModel) {
        self.model = model
    }

    public func show() {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 820, height: 560),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "uDeck Settings"
            window.isReleasedWhenClosed = false
            window.center()
            window.contentView = NSHostingView(rootView: SettingsView(model: model))
            self.window = window
        }

        applyAppearance()

        // Settings are the one part of uDeck the operator works in with the
        // keyboard, so this is the one place activation is unambiguously right.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Dresses the settings window the way the panel is dressed.
    ///
    /// It is an ordinary application window and was therefore following macOS,
    /// which is the one thing it should not do: the operator sets a look for
    /// uDeck, and the window he sets it in was the only part of uDeck that
    /// ignored him. A panel written in dark ink is a bright panel, so the
    /// window that configures it is bright too.
    public func applyAppearance() {
        window?.appearance = NSAppearance(
            named: model.settings.ink == .dark ? .aqua : .darkAqua
        )
    }
}
