import AppKit
import CoreGraphics
import Observation
import SwiftUI
import UDeckCore

/// Which pane the settings window shows, and which plugin in it.
///
/// Kept by the window's controller rather than inside the view, so that a
/// restart into an update can say where the window was and the next launch
/// open it there (`SettingsPlace`).
@MainActor
@Observable
public final class SettingsNavigation {
    /// The first pane rather than the one that was most useful to me while
    /// building it: somebody who has landed in a language they cannot read
    /// needs the language control before anything else, and it is there.
    var section: SettingsView.Section = .general
    var selectedPlugin: String?

    public init() {}
}

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
    private let loginItem: (any LoginItemControlling)?
    private let navigation = SettingsNavigation()
    /// When the window was last opened, or anything of uDeck's clicked, typed
    /// in or scrolled while it was on the screen: what says it is in use
    /// (`SettingsUse`).
    private var lastTouched: Date?
    private var touchMonitor: Any?

    public init(
        model: DeckModel,
        updater: (any UpdateChecking)? = nil,
        loginItem: (any LoginItemControlling)? = nil
    ) {
        self.model = model
        self.updater = updater
        self.loginItem = loginItem
        super.init()
    }

    /// Whether the settings window is the one taking the keyboard: what the
    /// main menu's **Quit uDeck** waits for, so that ⌘Q quits from Settings as
    /// from any window, and never from the panel.
    public var isKey: Bool { window?.isKeyWindow == true }

    /// Whether the window is on the screen — which is not the same as somebody
    /// being in it: a window can stay open behind other windows, or on another
    /// desktop, for days (`inUseForAnUpdate`).
    public var isShown: Bool { window?.isVisible == true }

    /// Whether uDeck is the active application while the window is on the
    /// screen: the window, or the colour panel or a popover opened from it,
    /// takes the keyboard — Settings is uDeck's one window that does, and
    /// the panel, which may be key too, holds a restart of its own.
    private var isInFront: Bool { NSApp.isActive }

    /// Whether the window holds a restart into an update: on the screen, and
    /// touched in the last three minutes — thirty with a form open in it — or
    /// in front of somebody at the Mac (`SettingsUse`). One left open and
    /// forgotten does not: the restart opens it again where it was (`place`,
    /// `reopen(at:)`).
    public func inUseForAnUpdate(now: Date = Date()) -> Bool {
        // Any input event on this Mac, the keyboard's and the pointer's alike
        // (kCGAnyInputEventType): how long somebody has been away from it.
        let away = CGEventSource.secondsSinceLastEventType(
            .combinedSessionState, eventType: CGEventType(rawValue: ~0)!
        )
        return SettingsUse.inUse(
            shown: isShown, inFront: isInFront,
            sinceTouched: lastTouched.map { now.timeIntervalSince($0) },
            sinceAnyInput: away.isFinite && away >= 0 ? away : nil,
            formOpen: model.settingsFormOpen
        )
    }

    /// Where the window is, while it is on the screen or in the Dock: what a
    /// restart into an update leaves for the next launch.
    public func place(now: Date = Date()) -> SettingsPlace? {
        guard let window, isShown || window.isMiniaturized else { return nil }
        return SettingsPlace(
            section: navigation.section.rawValue, frame: .init(window.frame),
            inFront: isShown && isInFront, minimized: window.isMiniaturized, savedAt: now
        )
    }

    /// Opens the window where a restart into an update found it: its pane,
    /// its frame if a screen still has room for it — in front if it was in
    /// front, in the Dock if it was there, and otherwise behind, without
    /// taking the keyboard from whatever somebody is typing in. Not a touch:
    /// left alone, it holds nothing.
    public func reopen(at place: SettingsPlace) {
        navigation.section = SettingsView.Section(rawValue: place.section) ?? .general
        makeWindow()
        if let frame = place.frame, frame.isOnScreen(NSScreen.screens.map(\.visibleFrame)) {
            window?.setFrame(frame.rect, display: false)
        }
        if true {
            present()
            return
        }
        applyAppearance()
        NSApp.setActivationPolicy(.regular)
        if place.minimized {
            window?.miniaturize(nil)
        } else {
            window?.orderBack(nil)
        }
    }

    private func makeWindow() {
        guard window == nil else { return }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = model.strings(.settingsWindowTitle)
        window.isReleasedWhenClosed = false
        window.center()
        window.contentView = NSHostingView(
            rootView: SettingsView(model: model, updater: updater, loginItem: loginItem, navigation: navigation)
        )
        window.delegate = self
        self.window = window
        // A click, a drag, a key or a scroll anywhere in uDeck while the
        // window is on the screen: in it, or in the colour panel, a popover
        // or a sheet opened from it, each a window of its own. Seen, never
        // taken: the event goes on.
        touchMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseDragged, .keyDown, .scrollWheel]
        ) { [weak self] event in
            MainActor.assumeIsolated {
                if let self, self.isShown { self.lastTouched = Date() }
            }
            return event
        }
    }

    /// Opens the window from uDeck's menu or the panel: somebody asked for it,
    /// and that is a touch.
    public func show() {
        makeWindow()
        lastTouched = Date()
        present()
    }

    private func present() {
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
