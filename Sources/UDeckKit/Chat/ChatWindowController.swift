import AppKit
import SwiftUI
import UDeckChat
import UDeckCore

/// Holds the chat window.
///
/// A window of its own for now — the panel tab, the mini window and moving
/// between them come later (spec P5). uDeck is an accessory application, so
/// while the window is open it takes a place in the Dock and Cmd-Tab like any
/// application's window, and gives it back when it closes (as Settings does).
@MainActor
public final class ChatWindowController: NSObject, NSWindowDelegate {
    public let store: ChatStore
    private let strings: () -> Strings
    private var window: NSWindow?

    public init(store: ChatStore = ChatStore(), strings: @escaping () -> Strings) {
        self.store = store
        self.strings = strings
    }

    public func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: ChatRootView(store: store, strings: strings))
            let window = NSWindow(contentViewController: hosting)
            window.title = strings()(.chatWindowTitle)
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.setContentSize(NSSize(width: 1040, height: 720))
            window.minSize = NSSize(width: 640, height: 420)
            window.isReleasedWhenClosed = false
            window.center()
            // After centring: a size and place the user gave it win from now on.
            window.setFrameAutosaveName("uDeck.chat")
            window.delegate = self
            window.identifier = NSUserInterfaceItemIdentifier("chat.window")
            self.window = window
        }
        NSApp.setActivationPolicy(.regular)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    public var isOpen: Bool { window?.isVisible ?? false }

    public func windowWillClose(_ notification: Notification) {
        // Sessions go on running while the window is closed; only the Dock
        // place goes.
        NSApp.setActivationPolicy(.accessory)
    }
}
