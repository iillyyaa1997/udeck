import AppKit
import SwiftUI
import OSLog
import UDeckCore

/// Owns the window, and everything about when it is and is not on screen.
///
/// This is the part of uDeck with no reference implementation to lean on, and
/// the part a macOS release is most likely to disturb. Everything it decides is
/// delegated to `UDeckCore` — the geometry, the gesture, the state machine —
/// so that what lives here is only the plumbing between AppKit and those
/// decisions, and the decisions themselves stay testable.
@MainActor
public final class PanelController {
    public private(set) var state = PanelState()

    /// What the content is allowed to see and ask for.
    public let shell = ShellState()

    private let panel: DeckPanel
    private let screens: ScreenObserver
    private let pointer: PointerMonitor
    private var recognizer = HoverGestureRecognizer()
    private var settings: AppSettings

    /// The screen the panel is currently attached to.
    private var attachedScreenID: String?

    /// When the cursor first left the keep-alive region, if it is outside it.
    private var pointerLeftAt: TimeInterval?

    private var tokens: [NotificationToken] = []
    private var keyMonitor: Any?
    private var outsideClickMonitor: Any?
    private var exitTimer: Timer?

    /// Keeps the dwell alive while the cursor is not moving.
    private var armingTimer: Timer?

    /// The slow look at where the cursor actually is; see
    /// `GestureTuning.pointerPollInterval`.
    private var pointerPollTimer: Timer?

    /// The last idle reason logged, so a gate that blocks thousands of samples
    /// is recorded once rather than thousands of times.
    private var lastIdleReason: GestureOutcome.IdleReason?

    /// The application that was in front when uDeck took focus, so it can be
    /// put back afterwards.
    private var applicationToRestore: NSRunningApplication?

    /// True when uDeck had to activate itself for the panel to receive
    /// keystrokes. Recorded so the panel only ever gives focus back when it
    /// actually took it.
    private(set) var didActivateForKeyboard = false

    /// Told to whoever needs to react — the model stops polling when nobody is
    /// looking, and refreshes everything when somebody is.
    public var onPhaseChange: ((PanelPhase) -> Void)?

    public init(settings: AppSettings, screens: ScreenObserver, content: (ShellState) -> some View) {
        self.settings = settings
        self.screens = screens
        self.pointer = PointerMonitor(screens: screens)

        panel = DeckPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200))
        let hosting = NSHostingView(rootView: AnyView(content(shell)))
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting

        shell.onInteract = { [weak self] in self?.noteInteraction() }
        shell.onToggleFullscreen = { [weak self] in self?.toggleFullscreen() }
        shell.onCollapse = { [weak self] in self?.close() }
    }

    public func start() {
        pointer.fullscreenCheckInterval = settings.gesture.fullscreenCheckInterval
        pointer.onMove = { [weak self] sample, environment in
            self?.handlePointer(sample, environment: environment)
        }
        pointer.start()

        screens.onChange = { [weak self] in self?.handleScreenChange() }

        tokens.append(NotificationToken(
            center: NSWorkspace.shared.notificationCenter,
            name: NSWorkspace.didActivateApplicationNotification
        ) { [weak self] notification in
            // Only the process id crosses the boundary: a `Notification` carries
            // a `userInfo` dictionary that is not `Sendable`, and the id is the
            // only thing this needs.
            let pid = (notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated { self?.handleApplicationActivated(pid: pid) }
        })

        // Escape and ⌘W reach the panel only while it holds the keyboard, which
        // is exactly when they should mean "close this".
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let carried = MainThreadKeyEvent(event)
            let handled = MainActor.assumeIsolated { self?.handleKeyDown(carried.event) ?? false }
            return handled ? nil : event
        }

        // A click anywhere outside the panel dismisses it. Global monitors see
        // only other applications' events, which is precisely the set wanted
        // here — a click inside uDeck must never count as a click outside.
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleClickOutside() }
        }

        attachedScreenID = screens.screenUnderCursor?.id ?? screens.screens.first?.id
        // The content renders from `shell.phase`; without this it would start
        // out disagreeing with the window about which state it is in.
        shell.phase = state.phase
        pointer.panelVisible = state.phase.isVisible
        onPhaseChange?(state.phase)
        applyPhase(animated: false)
        panel.orderFrontRegardless()
        startPointerPoll()
    }

    private func startPointerPoll() {
        pointerPollTimer?.invalidate()
        pointerPollTimer = nil
        let interval = settings.gesture.pointerPollInterval
        guard interval > 0 else { return }
        pointerPollTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                // A peek is watched too: the cursor can be moved away without
                // producing any event this process sees, and a peek that only
                // noticed on the next movement would sit there indefinitely.
                guard let self, self.state.phase == .collapsed || self.state.phase == .peek else { return }
                self.handlePointer(
                    PointerSample(
                        location: NSEvent.mouseLocation,
                        delta: .zero,
                        timestamp: ProcessInfo.processInfo.systemUptime
                    ),
                    environment: self.pointer.currentEnvironment()
                )
            }
        }
    }

    public func stop() {
        pointer.stop()
        tokens.removeAll()
        exitTimer?.invalidate()
        armingTimer?.invalidate()
        pointerPollTimer?.invalidate()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        keyMonitor = nil
        outsideClickMonitor = nil
        panel.orderOut(nil)
    }

    public func update(settings: AppSettings) {
        self.settings = settings
        pointer.fullscreenCheckInterval = settings.gesture.fullscreenCheckInterval
        startPointerPoll()
        applyPhase(animated: false)
    }

    /// Reveals the panel from anywhere — the menu-bar item, or a future hotkey.
    public func reveal() {
        apply(.revealRequested)
    }

    public func toggleFullscreen() {
        apply(.toggleFullscreen)
    }

    public func close() {
        apply(.closeRequested)
    }

    /// Called by the content when the operator interacts with it, which is what
    /// turns a glance into a working panel.
    public func noteInteraction() {
        apply(.interacted)
    }

    // MARK: - Geometry

    private var currentScreen: ScreenSnapshot? {
        if let attachedScreenID, let screen = screens.screen(withID: attachedScreenID) { return screen }
        return screens.screenUnderCursor ?? screens.screens.first
    }

    private var geometry: PanelGeometry? {
        currentScreen.map {
            PanelGeometry(screen: $0, tuning: settings.gesture, metrics: settings.panel)
        }
    }

    // MARK: - Pointer

    private func handlePointer(_ sample: PointerSample, environment: GestureEnvironment) {
        // The gesture is always evaluated against the screen the cursor is on,
        // not the one the panel is attached to. On a docked machine those are
        // usually different, and binding the trigger to the panel's screen would
        // make it unreachable.
        let screenUnderCursor = screens.screens.screen(containing: sample.location)
        let gestureGeometry = screenUnderCursor.map {
            PanelGeometry(screen: $0, tuning: settings.gesture, metrics: settings.panel)
        }

        let outcome = recognizer.handle(sample, geometry: gestureGeometry, environment: environment, tuning: settings.gesture)
        if case .idle(let reason) = outcome, reason != lastIdleReason {
            lastIdleReason = reason
            DeckLog.gesture.debug("idle: \(reason.rawValue, privacy: .public)")
        }
        switch outcome {
        case .fire:
            DeckLog.gesture.debug("fired on \(screenUnderCursor?.name ?? "no screen", privacy: .public)")
            armingTimer?.invalidate()
            if let screenUnderCursor { attachedScreenID = screenUnderCursor.id }
            apply(.revealRequested)
        case .arming:
            // A dwell is a measurement of time, but the recognizer only ever
            // hears about time when the pointer moves. A hand resting on a
            // trackpad produces no events at all, so without this the dwell
            // would never finish and the gesture would work only for people
            // whose mouse jitters.
            scheduleArmingTick()
        case .idle:
            armingTimer?.invalidate()
            armingTimer = nil
        }

        trackPeekExit(sample)
    }

    /// A peek closes when the cursor has been away from the panel for a grace
    /// period — long enough that flicking past a corner does not count.
    private func trackPeekExit(_ sample: PointerSample) {
        guard state.phase == .peek, let geometry else {
            pointerLeftAt = nil
            return
        }

        let region = geometry.keepAliveRegion(for: state.phase)
        if region.contains(sample.location) {
            pointerLeftAt = nil
            return
        }

        if let since = pointerLeftAt {
            if sample.timestamp - since >= settings.gesture.peekExitGrace {
                apply(.pointerLeft)
            }
        } else {
            pointerLeftAt = sample.timestamp
            scheduleExitCheck()
        }
    }

    /// Feeds the recognizer a still sample, so a dwell can complete without the
    /// pointer moving.
    private func scheduleArmingTick() {
        guard armingTimer == nil else { return }
        armingTimer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard self.state.phase == .collapsed else {
                    self.armingTimer?.invalidate()
                    self.armingTimer = nil
                    return
                }
                self.handlePointer(
                    PointerSample(
                        location: NSEvent.mouseLocation,
                        delta: .zero,
                        timestamp: ProcessInfo.processInfo.systemUptime
                    ),
                    environment: self.pointer.currentEnvironment()
                )
            }
        }
    }

    /// The cursor can stop moving while outside the panel, and a peek that only
    /// closed on the next movement would sit there indefinitely.
    private func scheduleExitCheck() {
        exitTimer?.invalidate()
        exitTimer = Timer.scheduledTimer(
            withTimeInterval: settings.gesture.peekExitGrace, repeats: false
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.state.phase == .peek, self.pointerLeftAt != nil,
                      let geometry = self.geometry
                else { return }
                if !geometry.keepAliveRegion(for: .peek).contains(NSEvent.mouseLocation) {
                    self.apply(.pointerLeft)
                }
            }
        }
    }

    // MARK: - Events

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        guard panel.isKeyWindow, state.phase.isVisible else { return false }

        let escape = 53
        let closeShortcut = event.modifierFlags.contains(.command)
            && event.charactersIgnoringModifiers?.lowercased() == "w"

        if Int(event.keyCode) == escape {
            // Whether a field is holding text is the content's business; the
            // state machine only needs to be told, and it protects the text.
            apply(.escape(isEditingText: isEditingText()))
            return state.lastEventWasConsumedByField == false
        }
        if closeShortcut {
            apply(.closeRequested)
            return true
        }

        // Any other keystroke while merely peeking is a real interaction and
        // promotes the panel, so that what follows cannot be lost.
        if state.phase == .peek { apply(.interacted) }
        return false
    }

    /// True when a text field holds focus and has something in it.
    ///
    /// This is what makes the first Escape give up the field rather than the
    /// panel. Losing a half-typed answer to a stray key is the failure that
    /// would make the panel untrustworthy for the one job it exists for.
    private func isEditingText() -> Bool {
        guard let responder = panel.firstResponder as? NSText else { return false }
        return !responder.string.isEmpty
    }

    private func handleClickOutside() {
        guard state.phase.isVisible else { return }
        guard let geometry else { return }
        // A click in the trigger strip is the operator reaching for the panel,
        // not dismissing it.
        let location = NSEvent.mouseLocation
        guard !geometry.frame(for: state.phase).contains(location) else { return }
        apply(.closeRequested)
    }

    private func handleApplicationActivated(pid: pid_t?) {
        guard let pid else { return }

        // uDeck activating itself must not collapse uDeck. Without this the
        // panel would retract the instant it took focus to accept a keystroke —
        // the one behaviour that would make it useless to type in.
        guard pid != ProcessInfo.processInfo.processIdentifier else { return }

        apply(.otherAppActivated)
    }

    private func handleScreenChange() {
        guard let attachedScreenID, screens.screen(withID: attachedScreenID) == nil else {
            applyPhase(animated: false)
            return
        }
        self.attachedScreenID = screens.screenUnderCursor?.id ?? screens.screens.first?.id
        apply(.screenLost)
    }

    // MARK: - Applying state

    private func apply(_ event: PanelEvent) {
        let before = state.phase
        let changed = state.apply(event, collapseOnAppSwitch: settings.collapseOnAppSwitch)
        guard changed else {
            DeckLog.panel.debug("\(String(describing: event), privacy: .public) ignored in \(before.rawValue, privacy: .public)")
            return
        }
        DeckLog.panel.debug("\(before.rawValue, privacy: .public) -> \(self.state.phase.rawValue, privacy: .public) on \(String(describing: event), privacy: .public)")

        if before == .collapsed, state.phase != .collapsed {
            // Reveal: hand the gesture a clean slate so a half-armed dwell from
            // before cannot fire into the newly opened panel.
            recognizer.reset()
            pointerLeftAt = nil
        }

        if state.phase == .collapsed {
            pointer.lastDismissal = ProcessInfo.processInfo.systemUptime
            recognizer.suppressUntilPointerLeaves()
            pointerLeftAt = nil
            exitTimer?.invalidate()
            releaseKeyboard()
        }

        pointer.panelVisible = state.phase.isVisible
        shell.phase = state.phase
        onPhaseChange?(state.phase)
        applyPhase(animated: true)

        if state.phase.isHeld { takeKeyboard() }
    }

    private func applyPhase(animated: Bool) {
        guard let geometry else { return }
        let frame = geometry.frame(for: state.phase)

        // While away, the pill is a hint rather than a target: it must not
        // swallow clicks meant for whatever is underneath it.
        panel.ignoresMouseEvents = state.phase == .collapsed

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = settings.panel.revealDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }

        panel.orderFrontRegardless()
    }

    /// Gives the panel the keyboard, activating uDeck only if that turns out to
    /// be necessary.
    ///
    /// A non-activating panel can take clicks without pulling the application
    /// forward, which is what a glance should do. Keystrokes are a different
    /// matter: the system routes them to the active application, so a panel in a
    /// background application can be key and still see nothing typed. Rather
    /// than assume either way, the panel asks for key status first and checks
    /// whether it worked — and only then does the least intrusive thing that
    /// makes typing possible.
    private func takeKeyboard() {
        applicationToRestore = NSWorkspace.shared.frontmostApplication
        panel.makeKeyAndOrderFront(nil)

        if !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            didActivateForKeyboard = true
        }
        DeckLog.panel.debug(
            "took the keyboard: key=\(self.panel.isKeyWindow, privacy: .public) active=\(NSApp.isActive, privacy: .public) activated=\(self.didActivateForKeyboard, privacy: .public)"
        )
    }

    /// Puts the previous application back, but only if uDeck took it away.
    private func releaseKeyboard() {
        panel.resignKey()
        guard didActivateForKeyboard else { return }
        didActivateForKeyboard = false
        applicationToRestore?.activate()
        applicationToRestore = nil
    }

    // MARK: - Introspection, for the smoke test and the settings screen

    public var debugDescription: String {
        let screen = currentScreen
        return """
        phase=\(state.phase.rawValue) restore=\(state.restorePhase.rawValue) reason=\(state.collapseReason.rawValue)
        screen=\(screen?.name ?? "none") notch=\(screen?.hasNotch == true)
        frame=\(panel.frame)
        key=\(panel.isKeyWindow) appActive=\(NSApp.isActive) activatedForKeyboard=\(didActivateForKeyboard)
        calibration polarity=\(pointer.calibration.polarity) scale=\(String(format: "%.2f", pointer.calibration.scale)) observations=\(pointer.calibration.observations)
        """
    }
}

/// See `MainThreadEvent` in `PointerMonitor`: the same narrow assumption, for
/// the key-event monitor.
private struct MainThreadKeyEvent: @unchecked Sendable {
    let event: NSEvent
    init(_ event: NSEvent) { self.event = event }
}
