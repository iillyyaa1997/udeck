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

    /// Builds the content for a shell. Kept because there is one of these per
    /// screen now, and the ones for the other screens are made as displays come
    /// and go rather than once at startup.
    private let makeContent: (ShellState) -> AnyView

    /// The island on every screen the panel is not currently on, by screen id.
    ///
    /// The panel is one window and lives where the gesture last fired. Without
    /// these, opening it on the laptop took the island off the game on the
    /// other display — which is the one place it was actually wanted.
    private var islands: [String: IslandWindow] = [:]


    /// The keyboard way in. Owned here rather than by the app delegate so that
    /// it is re-registered by the same `settingsChanged()` that everything else
    /// goes through — a shortcut you have to remember to re-apply is a shortcut
    /// that stops matching the settings screen.
    private let hotKeys = HotKeyMonitor()

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

    /// The screen the window was last placed on, so that arriving at a new one
    /// can be told apart from changing state on the one it is already on.
    private var placedScreenID: String?


    /// Identifies the most recent transition, so a settle scheduled for one is
    /// dropped when another starts before it fires.
    private var settleToken = 0

    /// Whether the cursor has left the peek, and for how long. The rule itself
    /// lives in `UDeckCore`; what is left here is the timer that asks it again
    /// when the cursor has stopped moving and no further sample will arrive.
    private var peekExit = PeekExitTracker()

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
        content: @escaping (ShellState) -> AnyView
    ) {
        self.readSettings = settings
        self.screens = screens
        self.pointer = PointerMonitor(screens: screens)
        self.makeContent = content

        panel = DeckPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200))
        let hosting = PanelHostingView(rootView: content(shell))
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting

        shell.onInteract = { [weak self] in self?.noteInteraction() }
        shell.onToggleFullscreen = { [weak self] in self?.toggleFullscreen() }
        shell.onCollapse = { [weak self] in self?.close() }
    }

    public func start() {
        hotKeys.onFire = { [weak self] in self?.toggleFromKeyboard() }
        hotKeys.apply(settings.hotkey)

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
                guard let self else { return }

                // Whether the window should be taking clicks is asked on every
                // tick, whatever state the panel is in. Movement events answer
                // it too, and faster — but they are not the only way a cursor
                // arrives somewhere: another application can warp it, and then
                // the first thing to happen at the new position would be a
                // click against a stale answer.

                // The gesture itself is only worth evaluating while there is
                // something for it to do. A peek is watched because the cursor
                // can be moved away without producing any event this process
                // sees, and a peek that only noticed on the next movement would
                // sit there indefinitely.
                guard self.state.phase == .collapsed || self.state.phase == .peek else { return }
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
        hotKeys.stop()
        pointer.stop()
        tokens.removeAll()
        exitTimer?.invalidate()
        armingTimer?.invalidate()
        pointerPollTimer?.invalidate()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        keyMonitor = nil
        outsideClickMonitor = nil
        for island in islands.values { island.close() }
        islands.removeAll()
        panel.orderOut(nil)
    }

    /// Told when the operator changes something, so the timers that were
    /// created with an interval can be recreated with the new one. Everything
    /// else is already read live.
    public func settingsChanged() {
        hotKeys.apply(settings.hotkey)
        pointer.fullscreenCheckInterval = settings.gesture.fullscreenCheckInterval
        startPointerPoll()
        applyPhase(animated: false)
    }

    /// Reveals the panel from anywhere — the menu-bar item, for instance.
    public func reveal() {
        apply(.revealRequested)
    }

    /// What the keyboard shortcut does: opens the panel ready to work in, and
    /// closes it again if it is already showing.
    ///
    /// Not the same as `reveal()`, which gives a peek — the glance the pointer
    /// gesture earns by the cursor being right there. Someone who reached for a
    /// shortcut has their hands on the keys and is not going to move the mouse
    /// over to promote a peek into a panel, so the reveal is promoted for them.
    /// The panel takes the keyboard as part of becoming held, so it is ready to
    /// be typed into.
    public func toggleFromKeyboard() {
        guard state.phase == .collapsed else {
            apply(.closeRequested)
            return
        }
        apply(.revealRequested)
        apply(.interacted)
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
        currentScreen.map { geometry(for: $0) }
    }

    private func geometry(for screen: ScreenSnapshot) -> PanelGeometry {
        PanelGeometry(screen: screen, tuning: settings.gesture, metrics: settings.panel)
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

    /// Brings the window down to the panel once nothing is moving. Until then
    /// it is the stage, which is bigger than what is drawn on it.
    private func scheduleWindowSettle(after delay: TimeInterval) {
        settleToken += 1
        let token = settleToken
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.settleToken == token else { return }
            self.settleWindow()
        }
    }

    /// Makes the window exactly the panel, so every point in it is a point the
    /// panel draws on and everything outside belongs to whatever is behind it
    /// without uDeck having to decide anything.
    private func settleWindow() {
        guard let geometry else { return }
        let frame = geometry.settledWindowFrame(for: state.phase)
        guard panel.frame != frame else { return }
        // The content is told where it will be *before* the window moves, so
        // that the first layout after the resize is already the right one. The
        // other order leaves one frame drawn with the panel in its old place
        // inside the new window, which is a visible jolt at the end of every
        // reveal.
        shell.panelRect = CGRect(origin: .zero, size: frame.size)
        panel.setFrame(frame, display: true)
    }

    /// Gives every screen but the active one an island of its own, and takes
    /// away the ones for screens that are gone or have become active.
    private func syncIslands(activeScreenID: String) {
        let wanted = Set(screens.screens.map(\.id)).subtracting([activeScreenID])

        for id in islands.keys where !wanted.contains(id) {
            islands.removeValue(forKey: id)?.close()
        }
        for screen in screens.screens where wanted.contains(screen.id) {
            let island: IslandWindow
            if let existing = islands[screen.id] {
                island = existing
            } else {
                island = IslandWindow(content: makeContent)
                islands[screen.id] = island
            }
            island.place(using: geometry(for: screen))
        }
    }


    /// A peek closes when the cursor has been away from the panel for a grace
    /// period — long enough that flicking past a corner does not count.
    private func trackPeekExit(_ sample: PointerSample) {
        guard let geometry else {
            peekExit.reset()
            return
        }
        let inside = geometry.containsPointer(
            sample.location, in: geometry.keepAliveRegion(for: state.phase)
        )
        switch peekExit.update(
            isPeeking: state.phase == .peek,
            isInsideRegion: inside,
            now: sample.timestamp,
            grace: settings.gesture.peekExitGrace
        ) {
        case .stay, .waiting:
            break
        case .leftJustNow:
            scheduleExitCheck()
        case .close:
            apply(.pointerLeft)
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
                guard let self, self.state.phase == .peek, self.peekExit.isTiming,
                      let geometry = self.geometry
                else { return }
                if !geometry.containsPointer(NSEvent.mouseLocation, in: geometry.keepAliveRegion(for: .peek)) {
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
        guard !geometry.containsPointer(location, in: geometry.keepAliveRegion(for: state.phase)) else { return }
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
            peekExit.reset()
        }

        if state.phase == .collapsed {
            pointer.lastDismissal = ProcessInfo.processInfo.systemUptime
            recognizer.suppressUntilPointerLeaves()
            peekExit.reset()
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

        // Every other screen keeps its own island, so that opening the panel
        // here does not take the mark off the display it was wanted on.
        syncIslands(activeScreenID: geometry.screen.id)

        // Arriving on another screen is a move, not a transition.
        let arrivedOnANewScreen = placedScreenID != geometry.screen.id
        placedScreenID = geometry.screen.id
        let phase = state.phase
        let windowFrame = geometry.windowFrame(for: phase)
        let panelFrame = geometry.frame(for: phase)
        let panelRect = geometry.panelRectInWindow(for: phase)

        // Facts about the screen, pushed to the views rather than guessed at
        // inside them.
        shell.topOverhang = geometry.topOverhang
        shell.screenHasNotch = geometry.screen.hasNotch
        shell.weldedToTopEdge = panelFrame.maxY >= geometry.screen.frame.maxY

        // While away the island is a hint, not a target: it must not swallow
        // clicks meant for whatever is underneath it.
        panel.ignoresMouseEvents = phase == .collapsed

        // The window is a stage only while something is moving. Oversized, it
        // covers screen it does not draw on — and a window above every ordinary
        // one that covers screen it does not draw on is a window that eats
        // clicks meant for what is underneath.
        //
        // That used to be handled by flipping `ignoresMouseEvents` from the
        // pointer stream, and it lost a race it could not win: arriving on the
        // panel and clicking in one motion beat the flag, so the first click
        // went to the application below and the operator had to click twice.
        // Nothing polled is correct at the instant of a click.
        //
        // So the window is the stage while a transition is in flight and
        // exactly the panel once it settles. Never animated either way — it is
        // invisible, and animating it is what made the panel fly between
        // displays.
        if panel.frame != windowFrame {
            panel.setFrame(windowFrame, display: true)
        }

        let metrics = settings.panel
        // Only a collapse is a departure. Everything else — a peek becoming a
        // panel, a panel becoming fullscreen — is still an arrival, and arrives
        // on the spring.
        let arriving = state.phase != .collapsed
        shell.contentAnimation = arriving
            ? .easeOut(duration: metrics.contentRevealDuration).delay(metrics.contentRevealDelay)
            : .easeOut(duration: metrics.contentHideDuration)

        let reveal: Animation = arriving
            ? .spring(response: metrics.revealSpringResponse,
                      dampingFraction: metrics.revealSpringDamping)
            : .easeOut(duration: metrics.collapseDuration)

        if arrivedOnANewScreen, animated {
            // The panel usually opens on the screen it is already on, and the
            // window never moves. The first reveal on a *different* display is
            // the exception: the window has to move there, and animating from
            // where the panel was is what made it appear to fly across the desk
            // — which is the opposite of a panel that belongs to the screen the
            // cursor is on.
            //
            // So it arrives collapsed, instantly, and grows from there on the
            // next turn of the run loop. One frame later is invisible; the flight
            // was not.
            shell.panelRect = geometry.panelRectInWindow(for: .collapsed)
            panel.orderFrontRegardless()
            DispatchQueue.main.async { [weak self] in
                guard let self, self.state.phase == phase else { return }
                withAnimation(reveal) { self.shell.panelRect = panelRect }
                // This path used to return without one, so a panel revealed on
                // a display it was not already on kept the whole stage for a
                // window — which is why it behaved differently there.
                self.scheduleWindowSettle(after: arriving
                    ? metrics.revealSpringResponse * 1.6
                    : metrics.collapseDuration)
            }
            return
        }

        if animated {
            withAnimation(reveal) { shell.panelRect = panelRect }
            scheduleWindowSettle(after: arriving
                ? metrics.revealSpringResponse * 1.6
                : metrics.collapseDuration)
        } else {
            shell.panelRect = panelRect
            settleWindow()
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
