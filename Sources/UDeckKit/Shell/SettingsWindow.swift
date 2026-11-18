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

/// What the panel leaves Settings when it closes to make way for it
/// (`PanelController.closeForAWindowOfUDeck`).
public struct SettingsHandover {
    /// uDeck held the front for the panel when it closed — which is when
    /// Settings, made key by an application that is active already, does not
    /// take the menu bar by itself (`SettingsWindowController.takeTheMenuBar`).
    public var heldTheFront: Bool
    /// The application the panel took the keyboard from, or one a click past
    /// the panel left waiting to come back: where the keyboard goes again when
    /// Settings closes, unless another application was chosen meanwhile.
    public var cameFrom: NSRunningApplication?

    public init(heldTheFront: Bool, cameFrom: NSRunningApplication?) {
        self.heldTheFront = heldTheFront
        self.cameFrom = cameFrom
    }
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
    /// Which showing of the window this is: anything left waiting by an
    /// earlier one — a hand-off to the Dock, a look at the menu bar — does
    /// nothing once the window has closed or been shown again.
    private var showing = 0
    /// The showing that has handed the front to the Dock already: once each.
    private var handedToTheDock = -1
    private var resignWatch: NSObjectProtocol?
    private var comeBackDeadline: Timer?
    /// Where the keyboard goes when the window closes (`SettingsHandover`).
    private var returnTo: NSRunningApplication?
    private var activationWatch: NSObjectProtocol?

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
        if place.inFront {
            present(nil)
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
    /// and that is a touch. `handover` is what the panel, closing for it,
    /// left (`PanelController.closeForAWindowOfUDeck`).
    public func show(after handover: SettingsHandover? = nil) {
        makeWindow()
        lastTouched = Date()
        present(handover)
    }

    /// Opens the window on About's updates — what a notification about an
    /// update opens when it is clicked (`UpdateNotice`).
    public func showUpdates(after handover: SettingsHandover? = nil) {
        navigation.section = .about
        show(after: handover)
    }

    private func present(_ handover: SettingsHandover?) {
        let wasShown = isShown
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

        showing += 1
        let this = showing
        if let from = handover?.cameFrom {
            returnTo = from
        } else if !wasShown {
            returnTo = nil
        }
        watchOtherApplications()

        // Settings are the one part of uDeck the operator works in with the
        // keyboard, so this is the one place activation is unambiguously right.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)

        if handover?.heldTheFront == true {
            takeTheMenuBar(this, because: "the panel held the front")
        } else {
            // Asked once the system has answered the activation above, which
            // it does in its own time.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.lookAtTheMenuBar(this)
            }
        }
    }

    /// The fault the panel's gear met (the lab, 2026-11-18): uDeck active and
    /// Settings its key window, and the menu bar another application's. An
    /// accessory that is active already does not take the menu bar by becoming
    /// regular, and activating it again — at once, a quarter of a second later,
    /// or after deactivating — changed nothing while nothing else came forward
    /// in between (runs 44291812357, 44291873291, 44291841616).
    private func lookAtTheMenuBar(_ this: Int) {
        guard this == showing, isShown else { return }
        let owner = NSWorkspace.shared.menuBarOwningApplication
        if NSApp.isActive, NSApp.keyWindow === window,
           owner?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            takeTheMenuBar(this, because: "\(owner?.localizedName ?? "nobody") has the menu bar over it")
        } else {
            tell(this, "in front")
        }
    }

    /// The front handed to the Dock and taken back, once for a showing: what
    /// gave uDeck the menu bar over Settings when nothing else did (run
    /// 44291857874). The Dock has no ordinary window to raise over Settings,
    /// where the application from before had one (run 44291798885).
    ///
    /// Taken back when uDeck has resigned — the Dock's answer — or after a
    /// quarter of a second if that answer does not come; and at once, without
    /// a hand-off, if there is no Dock or it will not take the front.
    private func takeTheMenuBar(_ this: Int, because why: String) {
        guard this == showing, handedToTheDock != this else { return }
        handedToTheDock = this
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
            DeckLog.panel.notice("Settings: \(why, privacy: .public), and there is no Dock to hand the front to")
            comeBack(this)
            return
        }
        NSApp.yieldActivation(to: dock)
        let taken = dock.activate()
        DeckLog.panel.notice(
            "Settings: \(why, privacy: .public), so the front goes to the Dock and back — the Dock \(taken ? "takes it" : "will not take it", privacy: .public)"
        )
        guard taken else {
            comeBack(this)
            return
        }
        resignWatch = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: NSApp, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.comeBack(this) }
        }
        let deadline = Timer(timeInterval: 0.25, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.comeBack(this) }
        }
        RunLoop.main.add(deadline, forMode: .common)
        comeBackDeadline = deadline
    }

    private func comeBack(_ this: Int) {
        stopWaitingForTheDock()
        guard this == showing, isShown else { return }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.tell(this, "half a second after taking the front back")
        }
    }

    private func stopWaitingForTheDock() {
        if let resignWatch { NotificationCenter.default.removeObserver(resignWatch) }
        resignWatch = nil
        comeBackDeadline?.invalidate()
        comeBackDeadline = nil
    }

    /// Who the system says is in front, in uDeck's log — kept, so that what a
    /// Mac did with Settings can be read afterwards: the menu bar's owner is
    /// the application the operator sees as active, and it is not always the
    /// one the workspace calls frontmost.
    private func tell(_ this: Int, _ when: String) {
        guard this == showing, isShown else { return }
        let workspace = NSWorkspace.shared
        DeckLog.panel.notice(
            "Settings \(when, privacy: .public): menu bar \(workspace.menuBarOwningApplication?.localizedName ?? "nobody", privacy: .public), frontmost \(workspace.frontmostApplication?.localizedName ?? "nobody", privacy: .public), active \(NSApp.isActive, privacy: .public), key window \(NSApp.keyWindow?.title ?? "none", privacy: .public)"
        )
    }

    /// Another application chosen while the window is open is where the
    /// keyboard goes next by the system's own order, and the one from before
    /// the panel is forgotten. The Dock is not a choice: `takeTheMenuBar` puts
    /// it in front for a moment.
    private func watchOtherApplications() {
        guard activationWatch == nil else { return }
        activationWatch = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let pid = app?.processIdentifier
            let isDock = app?.bundleIdentifier == "com.apple.dock"
            MainActor.assumeIsolated {
                guard let self, self.isShown, !isDock, pid != ProcessInfo.processInfo.processIdentifier else { return }
                self.returnTo = nil
            }
        }
    }

    public func windowWillClose(_ notification: Notification) {
        showing += 1
        stopWaitingForTheDock()

        // The keyboard back where it was before the panel, while uDeck still
        // has it: an application chosen since has made `returnTo` nil, and the
        // system's own order decides. Without this, the next in that order
        // could be the Dock that `takeTheMenuBar` put in front a moment — a
        // keyboard reaching nobody.
        let back = returnTo
        returnTo = nil
        if let back, !back.isTerminated, false,
           NSWorkspace.shared.menuBarOwningApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            NSApp.yieldActivation(to: back)
            back.activate()
        }

        // Back to an accessory. Deferred by one turn of the run loop because
        // changing the policy while the window that made it necessary is still
        // closing leaves the Dock icon behind — and not if the window has been
        // opened again in that turn.
        DispatchQueue.main.async { [weak self] in
            guard self?.isShown != true else { return }
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
