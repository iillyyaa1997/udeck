import AppKit
import UDeckCore

/// Watches the pointer and reports what the gesture recognizer needs.
///
/// Everything here works with no permission at all. AppKit gates *key* events
/// behind Accessibility, not mouse events, so a global monitor for movement and
/// clicks is free — which is what lets uDeck be installed and used without a
/// single trip to System Settings.
@MainActor
public final class PointerMonitor {
    /// Called for every movement, with the sample and the world around it.
    public var onMove: ((PointerSample, GestureEnvironment) -> Void)?

    public private(set) var calibration = PointerDeltaCalibration()
    public private(set) var buttonsDown = false
    public private(set) var menuTrackingActive = false
    public private(set) var lastMenuBarButtonUp: TimeInterval?

    /// Set by the panel when it closes, so the gesture can stay quiet for a
    /// moment rather than re-firing under a cursor that has not moved yet.
    public var lastDismissal: TimeInterval?

    /// Set by the panel so the monitor does not try to reveal what is already
    /// revealed.
    public var panelVisible = false

    /// How long a fullscreen answer is reused. Set by the panel from the
    /// operator's tuning.
    public var fullscreenCheckInterval: TimeInterval = GestureTuning().fullscreenCheckInterval

    private var monitors: [Any] = []
    private var fullscreenCache: [String: (value: Bool, checkedAt: TimeInterval)] = [:]
    private var menuTokens: [NotificationToken] = []
    private var previousLocation: CGPoint?
    private let screens: ScreenObserver

    public init(screens: ScreenObserver) {
        self.screens = screens
    }

    public func start() {
        guard monitors.isEmpty else { return }

        let movement: NSEvent.EventTypeMask = [
            .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
        ]
        let buttons: NSEvent.EventTypeMask = [
            .leftMouseDown, .rightMouseDown, .otherMouseDown,
            .leftMouseUp, .rightMouseUp, .otherMouseUp,
        ]

        add(global: movement) { [weak self] event in self?.handleMovement(event) }
        add(global: buttons) { [weak self] event in self?.handleButton(event) }

        // Events delivered to uDeck itself never reach a global monitor, so the
        // panel would stop hearing about the cursor the moment it was under it.
        add(local: movement.union(buttons)) { [weak self] event in
            if buttons.contains(NSEvent.EventTypeMask(type: event.type)) {
                self?.handleButton(event)
            } else {
                self?.handleMovement(event)
            }
        }

        // Undocumented but long-standing, and the only way to know a system menu
        // is open without Accessibility. If it ever stops firing the gesture
        // still works — it simply loses one of its guards, which is why nothing
        // else depends on it.
        for name in ["com.apple.HIToolbox.beginMenuTrackingNotification",
                     "com.apple.HIToolbox.endMenuTrackingNotification"] {
            let isBegin = name.contains("begin")
            menuTokens.append(NotificationToken(
                center: DistributedNotificationCenter.default(),
                name: Notification.Name(name)
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.menuTrackingActive = isBegin }
            })
        }
    }

    public func stop() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors.removeAll()
        menuTokens.removeAll()
    }

    // MARK: - Event handling

    private func handleMovement(_ event: NSEvent) {
        let location = NSEvent.mouseLocation

        // Calibration only learns from movements where the cursor was free: at
        // the screen edge the position stops changing while the delta does not,
        // and folding that in would teach it nonsense.
        if let previous = previousLocation, let screen = screens.screens.screen(containing: location) {
            let atEdge = location.y >= screen.frame.maxY - 1
            if !atEdge {
                calibration.observe(positionChange: location.y - previous.y, reportedDelta: event.deltaY)
            }
        }
        previousLocation = location

        let sample = PointerSample(
            location: location,
            delta: CGVector(
                dx: calibration.scale * event.deltaX,
                dy: calibration.upwardPoints(fromReportedDelta: event.deltaY)
            ),
            timestamp: event.timestamp
        )

        onMove?(sample, environment(at: location, now: event.timestamp))
    }

    private func handleButton(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            buttonsDown = true
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            buttonsDown = false
            let location = NSEvent.mouseLocation
            if let screen = screens.screens.screen(containing: location),
               location.y >= screen.visibleFrame.maxY {
                lastMenuBarButtonUp = event.timestamp
            }
        default:
            break
        }
    }

    /// The world as it is right now, for a re-evaluation that no event
    /// triggered.
    public func currentEnvironment() -> GestureEnvironment {
        environment(at: NSEvent.mouseLocation, now: ProcessInfo.processInfo.systemUptime)
    }

    private func environment(at location: CGPoint, now: TimeInterval) -> GestureEnvironment {
        let screen = screens.screens.screen(containing: location)
        return GestureEnvironment(
            buttonsDown: buttonsDown,
            menuTrackingActive: menuTrackingActive,
            frontmostIsFullscreen: screen.map { isFullscreen(on: $0, at: location, now: now) } ?? false,
            panelVisible: panelVisible,
            lastMenuBarButtonUp: lastMenuBarButtonUp,
            lastDismissal: lastDismissal
        )
    }

    /// Is the frontmost application filling this screen?
    ///
    /// Two economies, because the honest answer costs about 1.5 ms — it means
    /// enumerating every window on screen — and this is asked on every pointer
    /// event:
    ///
    /// * it is only asked while the cursor is up in the menu-bar band, which is
    ///   the only place the gate can matter;
    /// * and the answer is reused for a fraction of a second.
    ///
    /// Below the band the answer is `false`, which is safe: the gesture cannot
    /// arm down there anyway, so a `false` that is never acted on costs nothing.
    private func isFullscreen(on screen: ScreenSnapshot, at location: CGPoint, now: TimeInterval) -> Bool {
        guard location.y >= screen.visibleFrame.maxY else { return false }

        if let cached = fullscreenCache[screen.id], now - cached.checkedAt < fullscreenCheckInterval {
            return cached.value
        }
        let value = FullscreenDetector.isFrontmostApplicationFullscreen(on: screen)
        fullscreenCache[screen.id] = (value, now)
        return value
    }

    private func add(global mask: NSEvent.EventTypeMask, handler: @escaping @MainActor (NSEvent) -> Void) {
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { event in
            let carried = MainThreadEvent(event)
            MainActor.assumeIsolated { handler(carried.event) }
        }) {
            monitors.append(monitor)
        }
    }

    /// The local monitor only observes; it never swallows or rewrites an event,
    /// so the event is always passed straight back to whatever it was going to.
    private func add(local mask: NSEvent.EventTypeMask, handler: @escaping @MainActor (NSEvent) -> Void) {
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { event in
            let carried = MainThreadEvent(event)
            MainActor.assumeIsolated { handler(carried.event) }
            return event
        }) {
            monitors.append(monitor)
        }
    }
}

/// Carries an `NSEvent` across the concurrency boundary that `assumeIsolated`
/// draws.
///
/// `NSEvent` is not `Sendable`, and correctly so in general. It is safe here for
/// a specific reason: AppKit delivers event-monitor callbacks on the main thread,
/// and the event is handed straight to main-actor code without being stored or
/// touched anywhere else. `assumeIsolated` traps if that assumption is ever
/// wrong, so the claim is checked at runtime rather than merely asserted.
private struct MainThreadEvent: @unchecked Sendable {
    let event: NSEvent
    init(_ event: NSEvent) { self.event = event }
}

private extension NSEvent.EventTypeMask {
    init(type: NSEvent.EventType) {
        switch type {
        case .leftMouseDown: self = .leftMouseDown
        case .leftMouseUp: self = .leftMouseUp
        case .rightMouseDown: self = .rightMouseDown
        case .rightMouseUp: self = .rightMouseUp
        case .otherMouseDown: self = .otherMouseDown
        case .otherMouseUp: self = .otherMouseUp
        case .mouseMoved: self = .mouseMoved
        case .leftMouseDragged: self = .leftMouseDragged
        case .rightMouseDragged: self = .rightMouseDragged
        case .otherMouseDragged: self = .otherMouseDragged
        default: self = []
        }
    }
}
