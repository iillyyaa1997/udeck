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
    private var updater: SparkleUpdater!

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
        model.onPluginsChanged = { [weak self] in self?.rebuildStatusMenu() }
        model.onSettingsChanged = { [weak self, weak controller] _ in
            controller?.settingsChanged()
            self?.settings.applyAppearance()
            self?.rebuildStatusMenu()
        }
        self.model = model
        self.screens = screens
        self.controller = controller
        // Built here rather than lazily: Sparkle's scheduler has to be running
        // for a scheduled check to happen at all, and an updater created the
        // first time somebody opens the settings screen is an updater that
        // never checks for the operator who never opens it.
        self.updater = SparkleUpdater()
        self.settings = SettingsWindowController(model: model, updater: self.updater)
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
        statusItem.button?.image = StatusGlyph.image()
        statusItem.button?.image?.accessibilityDescription = "uDeck"
        rebuildStatusMenu()
    }

    /// The menu, in the language currently in force.
    ///
    /// Rebuilt rather than created once, because the language is a setting: a
    /// menu assembled at launch is the one part of uDeck that would keep
    /// speaking English after the operator asked for Russian, and it is also
    /// the part he would look at first to check whether the setting worked.
    private func rebuildStatusMenu() {
        // A settings change can arrive before the status item exists: resolving
        // the look on the way up writes settings, and that is a change like any
        // other. Nothing to rebuild yet is not a problem — `installStatusItem`
        // calls this itself once there is.
        guard statusItem != nil else { return }
        let strings = model.strings
        let menu = NSMenu()

        // A plugin that will not run is the one thing uDeck knows and the
        // operator does not. It was already written down — in the settings
        // screen and next to the plugin in the picker — and both of those need
        // somebody to go and look. The menu-bar item is the only part of uDeck
        // that is on screen without being asked for, so it is where this
        // belongs: the icon carries a badge and the first row of the menu says
        // how many and opens the screen that says why.
        let broken = model.plugins.filter { !$0.isUsable }
        statusItem.button?.image = StatusGlyph.image(warning: !broken.isEmpty)
        statusItem.button?.image?.accessibilityDescription = "uDeck"
        if !broken.isEmpty {
            let item = menu.addItem(
                withTitle: strings(.menuBrokenPlugins(count: broken.count)),
                action: #selector(openSettings), keyEquivalent: ""
            )
            item.target = self
            item.image = NSImage(
                systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil
            )
            menu.addItem(.separator())
        }

        menu.addItem(withTitle: strings(.menuShowPanel), action: #selector(showPanel), keyEquivalent: "")
            .target = self
        menu.addItem(withTitle: strings(.menuRefreshAll), action: #selector(refreshAll), keyEquivalent: "")
            .target = self
        menu.addItem(withTitle: strings(.menuSettings), action: #selector(openSettings), keyEquivalent: ",")
            .target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: strings(.menuOpenPluginsFolder), action: #selector(openPlugins), keyEquivalent: "")
            .target = self
        menu.addItem(withTitle: strings(.menuCopyDiagnostics), action: #selector(copyDiagnostics), keyEquivalent: "")
            .target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: strings(.menuQuit), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
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
