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
    /// The windows that show a card away from the panel (`WindowPlace`).
    private var places: PlacesController!
    /// What waits for the person, said beside a notch (`NotchMarks`).
    private var notchMarks: NotchMarks!
    /// The language the main menu was last built in: it is built again only
    /// when that changes, not on every change of a setting — a slider dragged
    /// in Look fires many a second, and a menu replaced while it is open closes.
    private var mainMenuLanguage: Language?
    private var updater: SparkleUpdater!
    /// The menu's **Check and Update uDeck**, whose line under it follows the
    /// update as the menu opens.
    private var updateItem: NSMenuItem?
    private var loginItem: SystemLoginItem!

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
        model.onPluginsChanged = { [weak self] in
            self?.rebuildStatusMenu()
            // A window of its own opened before the plugins were read was
            // called after the plugin's id ("agents"): its name now.
            self?.places?.sync()
        }
        model.onSettingsChanged = { [weak self, weak controller] _ in
            controller?.settingsChanged()
            self?.settings.applyAppearance()
            self?.rebuildStatusMenu()
            self?.rebuildMainMenu()
        }
        // Settings' shortcut field records with the shortcut let go, and says
        // so when the system refuses the one it recorded.
        model.onShortcutRecording = { [weak controller] in controller?.holdHotKey($0) }
        // Handed over on every settings change; set only when it changes, so a
        // slider's every tick does not redraw the shortcut row.
        controller.onHotKeyRefused = { [weak model] refused in
            if model?.shortcutRefused != refused { model?.shortcutRefused = refused }
        }
        self.model = model
        rebuildMainMenu()
        self.screens = screens
        self.controller = controller
        // Built here rather than lazily: Sparkle's scheduler has to be running
        // for a scheduled check to happen at all, and an updater created the
        // first time somebody opens the settings screen is an updater that
        // never checks for the operator who never opens it.
        self.updater = SparkleUpdater()
        // An update put in place by itself restarts uDeck: never while the
        // panel is out, Settings is in use — open and forgotten is not in use —
        // a Sign in, a plugin's install, update, removal or link, or a card
        // action is under way. The model is held, not watched: it does not hold
        // the updater. Settings, which does, is watched, and no window is no use.
        self.updater.restartHold = { [weak self, model] in
            model.restartHold(settingsInUse: self?.settings?.inUseForAnUpdate() ?? false)
        }
        // Nothing is asked of the system here: the record is read when the settings
        // window appears, and written only when the operator asks. An application that
        // registers at launch silently puts back a login item the operator removed.
        self.loginItem = SystemLoginItem()
        // Resident plugins: their notifications, and the folders they ask for.
        model.onPluginNotice = { [weak self] plugin, notice in
            self?.updater.notifier.postPluginNotice(plugin: plugin.rawValue, notice: notice)
        }
        model.onPluginUnnotify = { [weak self] plugin, id in
            self?.updater.notifier.withdrawPluginNotice(plugin: plugin.rawValue, id: id)
        }
        // A button pressed or a reply written in a plugin's notification: the
        // plugin is told, and nothing opens.
        updater.notifier.onAnswerPluginNotice = { [weak model] plugin, id, action, text in
            guard let plugin = PluginIdentifier(rawValue: plugin) else { return }
            model?.residentEvent(plugin, .notification(id: id, action: action, text: text))
        }
        updater.notifier.onOpenPluginNotice = { [weak self, weak model] plugin, id in
            self?.controller.reveal()
            guard let plugin = PluginIdentifier(rawValue: plugin) else { return }
            model?.residentEvent(plugin, .notification(id: id))
        }
        model.onPluginPicksFolder = { [weak model] plugin, request, prompt in
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.allowsMultipleSelection = false
            if let prompt { panel.message = prompt }
            // Above the panel, which floats over other windows: at its own
            // level the dialog opened under it, its folders hidden (0.9.5).
            let top = NSApp.windows.filter(\.isVisible).map(\.level.rawValue).max() ?? NSWindow.Level.normal.rawValue
            panel.level = NSWindow.Level(rawValue: max(top + 1, NSWindow.Level.modalPanel.rawValue))
            NSApp.activate(ignoringOtherApps: true)
            let path = panel.runModal() == .OK ? panel.url?.path : nil
            model?.residentEvent(plugin, .folder(id: request, path: path))
        }
        // Resident plugins run in the helper, which keeps them through a
        // restart of uDeck; it is registered when the first of them starts.
        if !AgentHelperSelfTest.isOn, Bundle.main.bundleURL.pathExtension == "app",
           !UserDefaults.standard.bool(forKey: "ResidentsRunHere") {
            model.residentLauncher = HelperResidentLauncher(helper: SystemAgentHelper())
        }
        // The lab's own look at the helper (AgentHelperSelfTest).
        if AgentHelperSelfTest.isOn {
            let helper = SystemAgentHelper()
            Task { await AgentHelperSelfTest.run(helper) }
        }
        self.settings = SettingsWindowController(
            model: model, updater: self.updater, loginItem: self.loginItem
        )
        // A card shown in a window of its own, or a mini window, has it from
        // launch on, as the layout says.
        let places = PlacesController(model: model)
        self.places = places
        model.onPlacesChanged = { [weak places] in places?.sync() }
        // The panel sits above ordinary windows: it closes for a card's own
        // window, as it does for Settings, and stays for a mini window.
        model.onBringPlaceForward = { [weak places, weak controller] id in
            guard let places else { return }
            if places.showsInAWindow(id) { _ = controller?.closeForAWindowOfUDeck() }
            places.bringForward(id)
        }
        // A plugin asked for its window on the board: the panel comes out.
        model.onRevealPanel = { [weak controller] in controller?.reveal() }
        places.sync()
        // Beside every notch: ears or a glow while something waits. Placed
        // again when the screens change, after the observer has read them.
        let marks = NotchMarks(model: model)
        self.notchMarks = marks
        marks.sync(screens: screens.screens)
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                guard let self else { return }
                self.notchMarks?.sync(screens: self.screens.screens)
            }
        }
        // The panel sits above ordinary windows, so leaving it open would put
        // it on top of the settings it was asked to show.
        // And it closes for Settings, not like an Escape: an Escape brings back
        // the application from before, which then came forward over Settings.
        controller.shell.onOpenSettings = { [weak self] in
            guard let self else { return }
            settings.show(after: controller.closeForAWindowOfUDeck())
        }
        // A notification about an update speaks uDeck's language, and a click
        // on it opens the updates in Settings → General.
        updater.notifier.strings = { [model] in model.strings }
        updater.notifier.onOpen = { [weak self] in
            guard let self else { return }
            settings.showUpdates(after: controller.closeForAWindowOfUDeck())
        }
        // Noted once the notification can be sent: a restart into a newer
        // version put in by itself is said now.
        updater.noteLaunch()
        // A notice clicked while uDeck was not running is what launched it.
        updater.notifier.launched(with: notification.userInfo)

        // uDeck restarted into an update with Settings open: it opens again
        // where it was. Taken whatever it holds, so that it is for one launch.
        if let place = model.takeSettingsPlace() {
            settings.reopen(at: place)
        }

        model.discoverPlugins()
        controller.start()
        // The official catalogue is read a few seconds after the panel is
        // ready — on the very first launch too, before anything is pressed —
        // unless it was read in the last day, and once a day after that.
        // Settings → Plugins → Official catalogue switches it off.
        model.startCatalogueSchedule()

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

    /// A restart into an update uDeck asked for by itself is refused when
    /// something started in the moment before it (`SparkleUpdater`); any other
    /// termination goes ahead.
    ///
    /// A termination into an update with Settings on the screen leaves where it
    /// is for the launch after (`SettingsPlace`): open, or forgotten open, it
    /// opens there again.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard updater?.mayTerminateForAnUpdate() != false else { return .terminateCancel }
        if updater?.restartingIntoAnUpdate == true, !Self.theSessionIsEnding, let place = settings?.place() {
            model?.leaveSettingsPlace(place)
        }
        return .terminateNow
    }

    /// Whether this termination is the session ending — a log out, a restart
    /// or a shut down, which the quit event's reason says — rather than
    /// Sparkle's: nothing relaunches into the update then, and the next login
    /// opens uDeck as it always opens.
    private static var theSessionIsEnding: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventClass == AEEventClass(kCoreEventClass), event.eventID == AEEventID(kAEQuitApplication),
              let reason = event.attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason))?.enumCodeValue
        else { return false }
        let ending = [kAELogOut, kAEReallyLogOut, kAEShowRestartDialog, kAERestart, kAEShowShutdownDialog, kAEShutDown]
        return ending.map { OSType($0) }.contains(reason)
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Closed as uDeck quits, not by the person: the cards stay where they
        // are shown, and their windows open again at the next launch.
        places?.closeAll()
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
        // An update in one press, without the settings window (0.9.12). What
        // it is doing is said under it each time the menu opens
        // (`menuNeedsUpdate`).
        let update = menu.addItem(withTitle: strings(.menuCheckAndInstall), action: #selector(checkAndInstall),
                                  keyEquivalent: "")
        update.target = self
        updateItem = update
        menu.addItem(.separator())
        menu.addItem(withTitle: strings(.menuOpenPluginsFolder), action: #selector(openPlugins), keyEquivalent: "")
            .target = self
        menu.addItem(withTitle: strings(.menuCopyDiagnostics), action: #selector(copyDiagnostics), keyEquivalent: "")
            .target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: strings(.menuQuit), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.delegate = self
        statusItem.menu = menu
    }

    /// The application's main menu, in the language in force: what the menu
    /// bar shows while the settings window makes uDeck a regular application —
    /// and, the part that matters, where AppKit finds the key equivalents of a
    /// text field's own commands. Without an Edit menu ⌘V pasted nothing into
    /// any field, a token's included: the lab's `plugins.source-token-clipboard`
    /// found it (run 43511904754), the token step's field empty after ⌘V. The
    /// items go to the first responder, as a standard Edit menu's do.
    private func rebuildMainMenu() {
        let strings = model.strings
        guard strings.language != mainMenuLanguage else { return }
        mainMenuLanguage = strings.language
        let main = NSMenu()
        let application = NSMenu()
        // ⌘Q from Settings, as from any window; not from the panel, which may
        // take the keyboard and where it never quit uDeck (`validateMenuItem`).
        application.addItem(withTitle: strings(.menuQuit), action: #selector(quitFromSettings), keyEquivalent: "q")
            .target = self
        let applicationItem = NSMenuItem()
        applicationItem.submenu = application
        main.addItem(applicationItem)

        let edit = NSMenu(title: strings(.menuEdit))
        edit.addItem(withTitle: strings(.menuUndo), action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: strings(.menuRedo), action: Selector(("redo:")), keyEquivalent: "z")
            .keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: strings(.menuCut), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: strings(.menuCopy), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: strings(.menuPaste), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: strings(.menuSelectAll), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem(title: strings(.menuEdit), action: nil, keyEquivalent: "")
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    @objc private func quitFromSettings() { NSApp.terminate(nil) }

    @objc private func showPanel() { controller.reveal() }
    @objc private func refreshAll() { model.refreshAll(reason: .manual) }

    @objc private func checkAndInstall() { updater.installFromTheMenu() }
    @objc private func openPlugins() { model.revealPluginsDirectory() }
    /// The status item's Settings…, through the panel as the gear goes: a click
    /// on the status item can have closed a held panel and left the application
    /// from before waiting to come back over Settings.
    @objc private func openSettings() { settings.show(after: controller.closeForAWindowOfUDeck()) }

    /// The state of the window machinery, in one paste-able block.
    ///
    /// The panel's behaviour depends on screen geometry, on how the pointer
    /// reports movement, and on whether the panel could take the keyboard — none
    /// of which is visible from a screenshot. Making it copyable means a bug
    /// report can carry the answer instead of a guess.
    @objc private func copyDiagnostics() {
        NSPasteboard.general.clearContents()
        // `controller` is an optional, and an optional has a debugDescription of
        // its own: this pasted the words "Optional(UDeckKit.PanelController)"
        // for as long as the menu item has existed. Found by pressing it.
        NSPasteboard.general.setString(
            controller?.debugDescription ?? "uDeck has no panel yet",
            forType: .string
        )
    }
}

extension AppDelegate: NSMenuItemValidation {
    /// Every item of uDeck's own is offered, but the main menu's **Quit uDeck**
    /// only while the settings window takes the keyboard: a disabled item's key
    /// equivalent does nothing, so ⌘Q in the panel stays what it always was —
    /// and **Check and Update uDeck** not while a look is under way.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(checkAndInstall) {
            if case .checking = updater.status.stage { return false }
            return true
        }
        return item.action != #selector(quitFromSettings) || settings?.isKey == true
    }
}

extension AppDelegate: NSMenuDelegate {
    /// The line under **Check and Update uDeck**: what the update is doing, as
    /// General says it — checking, downloading, the latest, a failure.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let item = updateItem, menu.items.contains(item) else { return }
        let strings = model.strings
        let status = updater.status
        let line: String? = switch status.stage {
        case .idle: nil
        case .checking: strings(.updatesChecking)
        case .upToDate: strings(.updatesUpToDate)
        case .available(let version): strings(.updatesAvailable(version))
        case .downloading: strings(.updatesDownloading)
        case .readyToInstall: strings(.updatesReady)
        case .failed(let reason): strings(.updatesFailed(reason))
        }
        if #available(macOS 14.4, *) {
            item.subtitle = line
        } else {
            // No line under an item before 14.4: the item's own title says it.
            item.title = [strings(.menuCheckAndInstall), line].compactMap { $0 }.joined(separator: " — ")
        }
    }
}
