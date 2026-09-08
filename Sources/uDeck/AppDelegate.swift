import AppKit
import SwiftUI
import UDeckCore
import UDeckKit

/// Wires the pieces together and keeps them alive.
///
/// uDeck runs as an accessory application: no Dock icon, no application menu,
/// nothing in the window cycler. The only thing it puts in the menu bar is a
/// small item, and only because an application with no windows and no Dock icon
/// otherwise offers no way to quit it — everything else the operator sees comes
/// from a plugin.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: DeckModel!
    private var screens: ScreenObserver!
    private var controller: PanelController!
    private var statusItem: NSStatusItem!
    private var settings: SettingsWindowController!

    /// Watches macOS's own appearance, so the `system` theme source means what
    /// it says rather than "whatever macOS was set to when uDeck started".
    private var appearanceObserver: NSKeyValueObservation?

    /// The clock, for the scheduled source. Once a minute is far finer than an
    /// hourly turnover needs and still costs nothing measurable; the model does
    /// nothing at all when the answer has not moved.
    private var themeTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = DeckModel()
        let screens = ScreenObserver()

        let controller = PanelController(
            settings: { model.settings },
            screens: screens
        ) { shell in
            AnyView(DeckRootView(shell: shell, model: model))
        }

        controller.onPhaseChange = { [weak model] phase in
            model?.panelIsVisible = phase.isVisible
        }
        model.onSettingsChanged = { [weak self, weak controller] _ in
            controller?.settingsChanged()
            self?.settings.applyAppearance()
        }
        self.model = model
        self.screens = screens
        self.controller = controller
        self.settings = SettingsWindowController(model: model)
        // The panel sits above ordinary windows, so leaving it open would put
        // it on top of the settings it was asked to show.
        controller.shell.onOpenSettings = { [weak self] in
            self?.controller.close()
            self?.settings.show()
        }

        model.discoverPlugins()
        controller.start()

        appearanceObserver = NSApp.observe(\.effectiveAppearance) { [weak model] _, _ in
            MainActor.assumeIsolated { model?.refreshTheme() }
        }
        let timer = Timer(timeInterval: 60, repeats: true) { [weak model] _ in
            MainActor.assumeIsolated { model?.refreshTheme() }
        }
        RunLoop.main.add(timer, forMode: .common)
        themeTimer = timer
        installStatusItem()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.stop()
    }

    private func installStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(
            systemSymbolName: "rectangle.topthird.inset.filled",
            accessibilityDescription: "uDeck"
        )

        let menu = NSMenu()
        menu.addItem(withTitle: "Show uDeck", action: #selector(showPanel), keyEquivalent: "")
            .target = self
        menu.addItem(withTitle: "Refresh all plugins", action: #selector(refreshAll), keyEquivalent: "")
            .target = self
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
            .target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Open the plugins folder", action: #selector(openPlugins), keyEquivalent: "")
            .target = self
        menu.addItem(withTitle: "Copy diagnostics", action: #selector(copyDiagnostics), keyEquivalent: "")
            .target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit uDeck", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    @objc private func showPanel() { controller.reveal() }
    @objc private func refreshAll() { model.refreshAll(reason: .manual) }
    @objc private func openPlugins() { model.revealPluginsDirectory() }
    @objc private func openSettings() { settings.show() }

    /// The state of the window machinery, in one paste-able block.
    ///
    /// The panel's behaviour depends on screen geometry, on how the pointer
    /// reports movement, and on whether the panel could take the keyboard — none
    /// of which is visible from a screenshot. Making it copyable means a bug
    /// report can carry the answer instead of a guess.
    @objc private func copyDiagnostics() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(controller.debugDescription, forType: .string)
    }
}
