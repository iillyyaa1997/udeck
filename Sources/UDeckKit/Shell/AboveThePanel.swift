import AppKit

/// A dialog uDeck opens over its panel and waits for: files or a folder to
/// choose, a question before a plugin's command.
///
/// `runModal` brings a dialog up at the modal-panel level, 8, whatever level it
/// was given before, and the panel floats at the status-bar level, 25 — so each
/// of them opened under the panel, its buttons hidden by it (the operator's
/// screenshot of 0.9.17 on 2026-11-25: the 📎 dialog under the Agents card).
/// Measured on macOS 27.0.1 the same day with a probe of a status-bar panel: an
/// open panel given level 26 and an alert given `.popUpMenu` both came up at
/// window-server layer 8, the level put back as the dialog became main or key;
/// a level set again once the dialog was up, it stayed. So the level is set
/// again whenever the dialog says it was updated or came forward, all the time
/// it is up.
@MainActor
public enum AboveThePanel {
    /// One above the highest of uDeck's windows on the screen, and never below
    /// the modal-panel level.
    public static var level: NSWindow.Level {
        let top = NSApp.windows.filter(\.isVisible).map(\.level.rawValue).max() ?? NSWindow.Level.normal.rawValue
        return NSWindow.Level(rawValue: max(top + 1, NSWindow.Level.modalPanel.rawValue))
    }

    /// The notifications on which a dialog's level is set again: the first one
    /// put it back to 8 as it became main (an open panel) or key (an alert).
    static let raisedOn: [Notification.Name] = [
        NSWindow.didUpdateNotification, NSWindow.didBecomeMainNotification, NSWindow.didBecomeKeyNotification,
    ]

    /// Brings uDeck forward and runs `run` — the dialog's own `runModal` —
    /// with `dialog` held above the panel for as long as it is up.
    public static func runModal(
        _ dialog: NSWindow, _ run: () -> NSApplication.ModalResponse
    ) -> NSApplication.ModalResponse {
        let raised = level.rawValue
        dialog.level = NSWindow.Level(rawValue: raised)
        let tokens = raisedOn.map { name in
            NotificationToken(name: name, object: dialog, queue: nil) { [weak dialog] _ in
                MainActor.assumeIsolated {
                    guard let dialog, dialog.level.rawValue < raised else { return }
                    dialog.level = NSWindow.Level(rawValue: raised)
                }
            }
        }
        defer { withExtendedLifetime(tokens) {} }
        NSApp.activate(ignoringOtherApps: true)
        return run()
    }
}
