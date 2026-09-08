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

    /// The operator's settings, read live rather than copied.
    ///
    /// This used to be a copy taken at initialisation, refreshed by an
    /// `update(settings:)` method that nothing ever called — so the whole
    /// "Opening" pane was written to disk, shown as changed, and had no effect
    /// until the next launch, while two controls in the same window did work.
    /// A wiring that is easy to forget is a wiring that will be forgotten;
    /// reading through a closure removes the thing to forget. Only the poll
    /// timer's own interval still needs to be told, and forgetting *that*
    /// degrades to one stale timer rather than to half a settings screen.
    private let readSettings: () -> AppSettings

    private var settings: AppSettings { readSettings() }

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

    /// First-responder types already logged, so the record is written once per
    /// kind rather than once per keystroke. See `isEditingText()` for why this
    /// is worth knowing at all.
    private var loggedResponderTypes: Set<String> = []

    /// How finely the dwell is measured while the pointer is not moving.
    ///
    /// Not a setting: it is the resolution of a measurement, not a preference.
    /// It only has to be small enough that the granularity is invisible against
    /// the shortest dwell anyone would configure — 30 ms against a dwell of
    /// 80 ms and up is under half a frame.
    private static let armingTickInterval: TimeInterval = 0.03

    /// A timer that keeps running while a modal loop is up.
    ///
    /// `Timer.scheduledTimer` schedules in the default run-loop mode only, so
    /// every timer here stopped the moment a confirmation alert appeared — the
    /// pointer poll, the dwell tick and the peek-exit grace all froze until the
    /// operator answered it, and the panel simply stopped responding to the
    /// cursor.
    private static func commonModeTimer(
        every interval: TimeInterval,
        repeats: Bool,
        _ block: @escaping @Sendable (Timer) -> Void
    ) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: repeats, block: block)
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

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

    public init(
        settings: @escaping () -> AppSettings,
        screens: ScreenObserver,
        content: (ShellState) -> some View
    ) {
        self.readSettings = settings
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
        pointerPollTimer = Self.commonModeTimer(every: interval, repeats: true) { [weak self] _ in
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

    /// Told when the operator changes something, so the timers that were
    /// created with an interval can be recreated with the new one. Everything
    /// else is already read live.
    public func settingsChanged() {
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
        armingTimer = Self.commonModeTimer(every: Self.armingTickInterval, repeats: true) { [weak self] _ in
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
        exitTimer = Self.commonModeTimer(
            every: settings.gesture.peekExitGrace, repeats: false
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

        // Which class actually holds the keyboard decides whether the rule that
        // Escape must never discard typed text can work at all — it is reached
        // through an `NSText` cast, and SwiftUI is migrating text to its own
        // implementation. Recorded once per kind.
        let responder = String(describing: type(of: panel.firstResponder))
        if loggedResponderTypes.insert(responder).inserted {
            DeckLog.panel.debug("first responder while typing: \(responder, privacy: .public)")
        }

        let escape = 53
        let closeShortcut = event.modifierFlags.contains(.command)
            && event.charactersIgnoringModifiers?.lowercased() == "w"

        if Int(event.keyCode) == escape {
            // A rename in progress is what Escape means first, whether or not
            // anything has been typed into it yet. An empty field used to fall
            // through and collapse the whole panel — and the content's own
            // Escape handling can never run, because this monitor sees the key
            // before the window does.
            if shell.tabRename != nil {
                shell.tabRename = nil
                return true
            }
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
        // Logged because the shape of this is an open question: SwiftUI is
        // moving to its own text implementation, and if a focused field ever
        // stops being reachable as `NSText` this returns false and Escape
        // starts eating typed text instead of protecting it. The type is in the
        // diagnostics so a bug report can say what it actually was.
        guard let responder = panel.firstResponder as? NSText else {
            DeckLog.panel.debug(
                "escape with first responder \(String(describing: type(of: self.panel.firstResponder)), privacy: .public), which is not NSText"
            )
            return false
        }
        return !responder.string.isEmpty
    }

    private func handleClickOutside() {
        guard state.phase.isVisible else { return }
        guard let geometry else { return }
        // Tested against the keep-alive region, not the panel's own frame. The
        // panel hangs below the top inset and so never contains the trigger
        // strip — which meant a click in the menu bar, the very place the
        // operator reaches to open the panel, dismissed it instead. The comment
        // here claimed otherwise for several commits.
        let location = NSEvent.mouseLocation
        guard !geometry.keepAliveRegion(for: state.phase).contains(location) else { return }
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

    /// The screen arrangement changed: a display was plugged in or unplugged,
    /// the resolution changed, the Dock moved, the machine woke up.
    ///
    /// If the panel's screen is still there, only the geometry needs redoing.
    /// If it is gone, the panel has nowhere to be, so it retracts — and because
    /// that is an interruption rather than a dismissal, a panel that was being
    /// worked in comes back as it was on whichever screen is left.
    private func handleScreenChange() {
        let stillThere = attachedScreenID.flatMap { screens.screen(withID: $0) } != nil
        if stillThere {
            applyPhase(animated: false)
            return
        }
        attachedScreenID = screens.screenUnderCursor?.id ?? screens.screens.first?.id
        if state.phase.isVisible {
            apply(.screenLost)
        } else {
            applyPhase(animated: false)
        }
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
            releaseKeyboard(restoringPreviousApplication: state.collapseReason == .dismissed)
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

    /// Gives the keyboard back, and the previous application with it — but
    /// only when uDeck took either away, and only when the operator did not
    /// just choose somewhere else to be.
    ///
    /// The second condition matters. Collapsing because another application was
    /// activated means the operator picked that application; pulling the one
    /// that was in front *before* uDeck back over it would be uDeck answering a
    /// choice it was not asked about.
    private func releaseKeyboard(restoringPreviousApplication shouldRestore: Bool) {
        // No `resignKey()` here: `NSWindow` documents it as something the
        // system calls, never the application. Ordering the panel out is what
        // actually gives up key status.
        guard didActivateForKeyboard else { return }
        didActivateForKeyboard = false
        let previous = applicationToRestore
        applicationToRestore = nil
        guard shouldRestore else { return }
        previous?.activate()
    }

    // MARK: - Introspection, for the smoke test and the settings screen

    public var debugDescription: String {
        let screen = currentScreen
        return """
        phase=\(state.phase.rawValue) restore=\(state.restorePhase.rawValue) reason=\(state.collapseReason.rawValue)
        screen=\(screen?.name ?? "none") notch=\(screen?.hasNotch == true)
        frame=\(panel.frame)
        key=\(panel.isKeyWindow) appActive=\(NSApp.isActive) activatedForKeyboard=\(didActivateForKeyboard)
        firstResponder=\(String(describing: type(of: panel.firstResponder))) editingText=\(isEditingText())
        calibration polarity=\(pointer.calibration.polarity) scale=\(String(format: "%.2f", pointer.calibration.scale)) agreement=\(pointer.calibration.agreementRun)
        """
    }
}

/// See `MainThreadEvent` in `PointerMonitor`: the same narrow assumption, for
/// the key-event monitor.
private struct MainThreadKeyEvent: @unchecked Sendable {
    let event: NSEvent
    init(_ event: NSEvent) { self.event = event }
}
