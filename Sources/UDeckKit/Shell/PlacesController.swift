import AppKit
import SwiftUI
import UDeckCore

/// Holds the windows of uDeck's own that show a card away from the panel: an
/// ordinary window, and a mini window above every other (`WindowPlace`).
///
/// It follows the layout (`sync`): a card shown so gets its window, one
/// brought back or removed loses it. Closing the window brings the card back
/// to its cell. Where each window was on the screen is kept in the layout, so
/// that it opens there again.
@MainActor
public final class PlacesController: NSObject, NSWindowDelegate {
    private let model: DeckModel
    private var windows: [UUID: NSWindow] = [:]
    private var kinds: [UUID: WindowPlace] = [:]
    /// Windows closed by `sync`, not by the person: closing them brings
    /// nothing back.
    private var closingQuietly: Set<UUID> = []
    private var syncing = false
    private var syncAgain = false

    public init(model: DeckModel) {
        self.model = model
    }

    /// Opens a window for every card the layout shows in one, and closes the
    /// windows of cards it no longer does.
    public func sync() {
        // Closing a window remembers where it was, which writes the layout,
        // which asks for a sync again: that one comes after this one ends.
        guard !syncing else {
            syncAgain = true
            return
        }
        syncing = true
        defer {
            syncing = false
            if syncAgain {
                syncAgain = false
                sync()
            }
        }
        var wanted: [UUID: WindowPlace] = [:]
        for window in model.layout.windowsAway where window.place.isOwnWindow {
            wanted[window.id] = window.place
        }
        for (id, window) in windows where wanted[id] != kinds[id] {
            closingQuietly.insert(id)
            window.close()
            windows[id] = nil
            kinds[id] = nil
            closingQuietly.remove(id)
        }
        for (id, place) in wanted.sorted(by: { $0.key.uuidString < $1.key.uuidString }) where windows[id] == nil {
            open(id, as: place)
        }
        // A place apart is called after what it shows, which changes.
        for (id, window) in windows {
            guard let found = model.layout.window(withID: id)?.window else { continue }
            let title = title(of: found)
            if window.title != title { window.title = title }
        }
    }

    /// Whether the card of `id` is shown in an ordinary window: the panel,
    /// which sits above ordinary windows, steps aside for it.
    public func showsInAWindow(_ id: UUID) -> Bool { kinds[id] == .window }

    /// Brings the window showing the card of `id` to the front.
    public func bringForward(_ id: UUID) {
        guard let window = windows[id] else { return }
        if kinds[id] == .mini {
            window.orderFrontRegardless()
        } else {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
        }
    }

    /// Closes every window, as uDeck quits: the layout keeps where each card
    /// is shown, and they open again at the next launch.
    public func closeAll() {
        for (id, window) in windows {
            closingQuietly.insert(id)
            window.close()
        }
        windows.removeAll()
        kinds.removeAll()
        closingQuietly.removeAll()
    }

    // MARK: - Opening

    private func open(_ id: UUID, as place: WindowPlace) {
        guard let found = model.layout.window(withID: id) else { return }
        let window: NSWindow = place == .mini ? Self.miniWindow() : Self.ordinaryWindow()
        window.title = title(of: found.window)
        window.isReleasedWhenClosed = false
        window.delegate = self
        let shell = ShellState()
        let content = PlacedWindowContent(model: model, windowID: id, place: place, shell: shell)
            .environment(\.strings, model.strings)
        window.contentView = NSHostingView(rootView: content)
        window.setFrame(frame(for: found.window, place: place), display: false)
        window.identifier = NSUserInterfaceItemIdentifier("place.\(found.window.pluginID.rawValue)")
        windows[id] = window
        kinds[id] = place
        if place == .mini {
            window.orderFrontRegardless()
        } else {
            window.makeKeyAndOrderFront(nil)
        }
        DeckLog.plugins.info("\(found.window.pluginID.rawValue, privacy: .public) opened in its own \(place.rawValue, privacy: .public) window")
    }

    private static func ordinaryWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 640),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.minSize = NSSize(width: 300, height: 220)
        window.collectionBehavior = [.managed, .participatesInCycle, .fullScreenPrimary]
        window.tabbingMode = .disallowed
        return window
    }

    /// Small, above every other window — full-screen apps' too, on every
    /// space — and taking the keyboard only when clicked into.
    private static func miniWindow() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 220),
                            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .fullSizeContentView,
                                        .utilityWindow],
                            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.minSize = NSSize(width: 240, height: 150)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        // Closing brings the card back; there is nothing to make smaller or
        // bigger in a window this size.
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        return panel
    }

    /// Where the window opens: where it was last, while that is on a screen;
    /// otherwise an ordinary window in the middle of the main screen, a mini
    /// one in its bottom-right corner.
    private func frame(for window: GridWindow, place: WindowPlace) -> NSRect {
        if let numbers = window.frame(in: place), numbers.count == 4 {
            let saved = NSRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
            if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(saved) }) { return saved }
        }
        let screen = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        if place == .mini {
            let size = NSSize(width: 320, height: 220)
            return NSRect(x: screen.maxX - size.width - 20, y: screen.minY + 20, width: size.width, height: size.height)
        }
        let size = NSSize(width: min(560, screen.width - 80), height: min(680, screen.height - 80))
        return NSRect(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2, width: size.width, height: size.height)
    }

    private func title(of window: GridWindow) -> String {
        let name = model.displayManifest(withID: window.pluginID)?.name ?? window.pluginID.rawValue
        let title = model.title(of: window)
        guard title != name else { return name }
        return "\(title) — \(name)"
    }

    private func id(of window: NSWindow) -> UUID? {
        windows.first { $0.value === window }?.key
    }

    // MARK: - NSWindowDelegate

    public func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, let id = id(of: window), let place = kinds[id] else { return }
        model.remember(frame: window.frame, of: id, in: place)
        guard !closingQuietly.contains(id) else { return }
        windows[id] = nil
        kinds[id] = nil
        // Closed by the person: the card goes back to its cell; a place apart
        // goes, what it showed staying with its plugin.
        model.closePlace(id)
    }

    public func windowDidMove(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, let id = id(of: window), let place = kinds[id] else { return }
        model.remember(frame: window.frame, of: id, in: place)
    }

    public func windowDidEndLiveResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, let id = id(of: window), let place = kinds[id] else { return }
        model.remember(frame: window.frame, of: id, in: place)
    }
}

/// What a window of uDeck's own shows: the card, on the panel's look.
struct PlacedWindowContent: View {
    var model: DeckModel
    var windowID: UUID
    var place: WindowPlace
    @Bindable var shell: ShellState

    var body: some View {
        let theme = model.placeTheme
        if place == .mini {
            // The title bar is see-through and the card goes up under it, its
            // close button alone above the card's title line.
            PlacedCard(model: model, theme: theme, windowID: windowID, shell: shell)
                .padding(EdgeInsets(top: 24, leading: 6, bottom: 6, trailing: 6))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.regularMaterial)
                .ignoresSafeArea()
        } else {
            PlacedCard(model: model, theme: theme, windowID: windowID, shell: shell)
                .padding(8)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.regularMaterial)
        }
    }
}
