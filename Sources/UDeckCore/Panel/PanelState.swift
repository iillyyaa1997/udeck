import CoreGraphics
import Foundation

/// The four states the panel can be in.
public enum PanelPhase: String, Codable, CaseIterable, Sendable {
    /// Away. A thin pill hangs under the anchor; this is what the operator sees
    /// while working in another application.
    case collapsed

    /// Revealed by the pointer. Read-only in spirit: moving the cursor away
    /// closes it again, so nothing typed can be lost here — because nothing has
    /// been typed yet.
    case peek

    /// Working size. Entered by the first click or keystroke, and from that
    /// moment the cursor leaving no longer closes anything.
    case open

    /// The whole working area of the screen. One button in, the same button out.
    case fullscreen

    /// Whether the panel currently accepts and holds keyboard focus.
    public var isHeld: Bool {
        switch self {
        case .collapsed, .peek: false
        case .open, .fullscreen: true
        }
    }

    public var isVisible: Bool { self != .collapsed }

    /// Whether the cursor leaving is allowed to close the panel in this phase.
    ///
    /// Only a peek: nothing has been typed into it yet, so nothing can be lost.
    /// This is the typing-safety rule, and it is stated here once because it
    /// used to be stated three times — in `PanelState` and in both of the
    /// controller's gates that decide whether a departure is worth timing at
    /// all. Measured on 2026-09-21: breaking only the gates left the lab green,
    /// because the state machine still refused, and breaking only the state
    /// machine left it green too, because the gates never asked it. One
    /// property read in all three places means one edit breaks both layers,
    /// and the lab sees it: letting `open` in here turned the check of a click
    /// past the panel red on `open -> collapsed on pointerLeft`.
    public var isDismissibleByPointer: Bool { self == .peek }
}

/// Why the panel last collapsed. This decides what a later reveal restores.
public enum CollapseReason: String, Codable, Sendable {
    /// The operator switched to another application, or the panel lost focus.
    /// The work in it is not finished, so revealing it again should bring back
    /// exactly what was there.
    case interrupted

    /// The operator closed it: Escape, the close button, a click outside.
    /// A later reveal starts from a peek again.
    case dismissed
}

/// What happened, as far as the panel is concerned.
public enum PanelEvent: Sendable, Equatable {
    /// The pointer gesture (or the hotkey) fired.
    case revealRequested

    /// The cursor has been outside the keep-alive region for longer than the grace period.
    case pointerLeft

    /// The first real interaction: a click inside, a keystroke, a field focused,
    /// a scroll or a drag begun. This is what promotes a peek into a held panel.
    case interacted

    /// Escape. `isEditingText` is true when a text field holds focus and has
    /// content — in which case Escape must give up the field, not the panel.
    case escape(isEditingText: Bool)

    /// The close button, or a click outside the panel.
    case closeRequested

    /// The fullscreen button, or its keyboard equivalent.
    case toggleFullscreen

    /// Another application became frontmost.
    case otherAppActivated

    /// The screen the panel is on went away, or the arrangement changed such
    /// that the current frame is no longer valid.
    case screenLost
}

/// Reading "another application came forward" as what the operator actually did.
///
/// One click past the panel reaches uDeck by two roads, and they race. The
/// global mouse monitor hears the click itself; the workspace says the clicked
/// application has come forward. Whichever arrives first collapses the panel and
/// the loser finds nothing left to do — so the same click closed the panel as a
/// dismissal on some days and as an interruption on others, and the operator saw
/// the *next* reveal come back as a peek or as the whole panel accordingly.
///
/// Which road wins is decided by something the operator cannot see: whether
/// uDeck was the frontmost application at all. Measured in the lab on 2026-09-21
/// (macOS 27 guest, eight clicks, four by each path): a panel promoted from a
/// peek by a click *inside* it has made uDeck frontmost, so clicking away really
/// does switch applications and the notification arrives 2.0–2.7 ms after the
/// button went down — about 5 ms ahead of the monitor's own callback. A click
/// that lands on the application already in front switches nothing, so no
/// notification is posted at all and the monitor is the only messenger; that
/// was measured with a panel restored straight to `open`, and again on
/// 2026-09-21 with the Finder switched to under a held panel and then clicked.
/// It is the click landing on the same application that decides it, not how the
/// panel was opened: a restored panel over TextEdit, and a click on the desktop,
/// brought the notification 11 ms after the button all the same.
///
/// The operator's rule is that a click past the panel is him closing it, whoever
/// brings the news. So the news is read rather than taken at face value: an
/// application coming forward while the pointer sits past the panel, a moment
/// after a click, *is* that click.
public enum ApplicationSwitch {
    /// How long after a mouse button went down another application coming
    /// forward is still that button's doing.
    ///
    /// Not a preference: it is the delivery time of a system notification, and
    /// nobody has a taste in those. Measured on 2026-09-21 by logging the age of
    /// the last mouse-down at the top of the notification's handler, on a
    /// macOS 27 guest: 2.0, 2.4, 2.5 and 2.7 ms for the first four clicks past a
    /// held panel on an idle guest; then between 2 and 32 ms in the lab runs
    /// later that day, the two slowest — 24 and 32 ms — both taken while the
    /// lab was booting the next check's machine beside the guest (the log
    /// rounds to whole milliseconds). The slowest, 32 ms, is the number the
    /// window is held against — `ApplicationSwitchTests` has it — and 0.15 s is
    /// a little under five times it. Not the "fifty times" this comment claimed
    /// while the slowest measurement was 2.7 ms, and not "a machine an order of
    /// magnitude busier", which it promised on the strength of that: a busy
    /// host has already cost more than ten times. The other side of the line is
    /// a human letting go of the mouse and reaching for ⌘-Tab, which no one
    /// does inside a sixth of a second; that switch stays an interruption,
    /// which is what brings unfinished work back.
    public static let clickWindow: TimeInterval = 0.15

    /// The presses whose age is asked: every button, because the click monitor
    /// that is the other messenger listens for every button, and a click past
    /// the panel with the right button is still the operator putting it away.
    public static let clickEventTypes: [CGEventType] = [.leftMouseDown, .rightMouseDown, .otherMouseDown]

    /// How long ago any mouse button last went down: the youngest of the three.
    ///
    /// - Parameter ageOf: how long ago a press of one kind last happened. In
    ///   the application that is `CGEventSource.secondsSinceLastEventType`;
    ///   it is handed in so that nothing here reads the machine it runs on —
    ///   the tests run on the operator's Mac and must not ask it anything.
    ///
    /// The `?? .infinity` is never reached: the list is never empty, and `min()`
    /// on a non-empty list always answers. What a machine that has never seen a
    /// press of some kind answers for that kind is `CGEventSource`'s business
    /// and its documentation does not say. The lab clicks with the left button
    /// only, so its guests had never had a right or middle press when they
    /// logged every age above — and the youngest of the three was a few
    /// milliseconds old each time, which only the real left click could be. An
    /// unused button answered with something no younger, not with zero.
    public static func secondsSinceLastClick(ageOf: (CGEventType) -> TimeInterval) -> TimeInterval {
        clickEventTypes.map(ageOf).min() ?? .infinity
    }

    /// What was decided about one activation, and what it was decided from.
    public struct Verdict: Equatable, Sendable {
        /// The two readings the decision took, kept so that both outcomes can
        /// be written down with them. A switch read as a switch and a click
        /// read as a switch look the same in the panel's phase; only these
        /// tell a false interruption from an honest ⌘-Tab afterwards.
        public struct Evidence: Equatable, Sendable {
            public let secondsSinceLastClick: TimeInterval
            public let pointerIsPastThePanel: Bool
        }

        public let event: PanelEvent

        /// Nil when nothing was asked, which is when there was no panel on screen.
        public let evidence: Evidence?
    }

    /// What to tell the panel when another application became frontmost, and
    /// whether it was worth asking at all.
    ///
    /// Telling a click from a switch is only worth doing while there is a panel
    /// on screen to collapse. Against the island the keep-alive region is the
    /// island's own, so the question would be about something nobody asked —
    /// and the readings are closures so that, when it is not asked, they are
    /// not taken either.
    public static func verdict(
        in phase: PanelPhase,
        secondsSinceLastClick: () -> TimeInterval,
        pointerIsPastThePanel: () -> Bool
    ) -> Verdict {
        guard phase.isVisible else { return Verdict(event: .otherAppActivated, evidence: nil) }
        let evidence = Verdict.Evidence(
            secondsSinceLastClick: secondsSinceLastClick(),
            pointerIsPastThePanel: pointerIsPastThePanel()
        )
        return Verdict(
            event: event(
                secondsSinceLastClick: evidence.secondsSinceLastClick,
                pointerIsPastThePanel: evidence.pointerIsPastThePanel
            ),
            evidence: evidence
        )
    }

    /// What to tell the panel when another application became frontmost.
    ///
    /// - Parameters:
    ///   - secondsSinceLastClick: how long ago any mouse button last went down,
    ///     anywhere on the machine. Asked of the system rather than remembered
    ///     from uDeck's own click monitor, because that monitor is the messenger
    ///     this exists to stop waiting for.
    ///   - pointerIsPastThePanel: whether the pointer is outside the region that
    ///     keeps the panel alive — the same test a click outside has to pass. A
    ///     click *on* the panel that launches something is not the operator
    ///     putting the panel away, so that stays an interruption.
    public static func event(
        secondsSinceLastClick: TimeInterval,
        pointerIsPastThePanel: Bool,
        within window: TimeInterval = clickWindow
    ) -> PanelEvent {
        guard pointerIsPastThePanel, secondsSinceLastClick >= 0, secondsSinceLastClick <= window else {
            return .otherAppActivated
        }
        return .closeRequested
    }
}

/// Whether giving the keyboard back also brings back the application that had
/// it before uDeck took it.
///
/// Only when the operator closed the panel *and uDeck is still in front* at the
/// moment it lets go. Escape and ⌘W reach uDeck only while it holds the
/// keyboard, so for them it is in front and the application from before comes
/// back, which is what closing a panel you were typing into should do. Measured
/// for Escape on 2026-09-21, TextEdit in front before the panel: the workspace
/// named uDeck as in front when Escape closed it, and a key typed next reached
/// TextEdit. With nothing brought back, the same key reached nobody at all.
///
/// A click past the panel is also a dismissal, but it is a click on something:
/// the system has already brought that something forward, or is about to.
/// Measured the same day, with TextEdit in front before the panel and a click
/// past it onto the desktop: two seconds later TextEdit was in front again, not
/// the Finder the click had activated — uDeck gave the keyboard back and then
/// pulled the application from before over the one the operator had just
/// chosen. Before a click past the panel was always read as a dismissal, the
/// same click often arrived as an interruption, which never brings anything
/// back, so this was hidden rather than absent: the click monitor did the same
/// whenever it won the race. The monitor is the only messenger when the click
/// lands on the application already in front, and that was measured too —
/// collapsing on an app switch turned off, the Finder switched to with the panel
/// held open, a click past the panel onto it — and TextEdit came back over the
/// Finder.
public enum KeyboardHandback {
    public static func restoresPreviousApplication(after reason: CollapseReason, uDeckIsInFront: Bool) -> Bool {
        reason == .dismissed && uDeckIsInFront
    }
}

/// The panel's state, and the rules that move it between phases.
///
/// The one rule this exists to guarantee: **once the panel is held, the cursor
/// leaving never closes it.** Everything else is detail. A panel that closes
/// itself while the operator is typing into it loses whatever was typed, and
/// the keystrokes after that go to whatever was frontmost before — which, on
/// this machine, is usually a shell with a live session in it.
public struct PanelState: Equatable, Sendable {
    public private(set) var phase: PanelPhase

    /// The phase to come back to after an interruption. Only meaningful while
    /// collapsed with `collapseReason == .interrupted`.
    public private(set) var restorePhase: PanelPhase

    public private(set) var collapseReason: CollapseReason

    /// Set when the panel wants Escape handled by the focused field rather than
    /// by itself. The host reads it to know that the event was consumed.
    public private(set) var lastEventWasConsumedByField: Bool

    public init(
        phase: PanelPhase = .collapsed,
        restorePhase: PanelPhase = .open,
        collapseReason: CollapseReason = .dismissed
    ) {
        self.phase = phase
        self.restorePhase = restorePhase
        self.collapseReason = collapseReason
        self.lastEventWasConsumedByField = false
    }

    /// Applies an event and returns whether the phase changed.
    @discardableResult
    public mutating func apply(_ event: PanelEvent, collapseOnAppSwitch: Bool = true) -> Bool {
        let before = phase
        lastEventWasConsumedByField = false

        switch event {
        case .revealRequested:
            guard phase == .collapsed else { break }
            // An interrupted panel comes back in the phase it was interrupted
            // in. Not "exactly as it was left, content and all", which is what
            // this comment used to claim and was not true: the panel's content
            // is a view, and a collapse takes the view down with it. Anything
            // that has to survive lives outside the view, in `ShellState` — a
            // half-typed tab name, for instance. A dismissed panel starts over
            // from a peek, because the operator said they were done with it.
            phase = collapseReason == .interrupted ? restorePhase : .peek

        case .pointerLeft:
            // The whole typing-safety rule, and `PanelPhase` is where it is
            // stated: the controller asks the same property before it times a
            // departure at all.
            if phase.isDismissibleByPointer { collapse(reason: .dismissed) }

        case .interacted:
            if phase == .peek { phase = .open }

        case .escape(let isEditingText):
            if isEditingText {
                // The field gives up focus; the panel and the text stay.
                lastEventWasConsumedByField = true
            } else if phase != .collapsed {
                collapse(reason: .dismissed)
            }

        case .closeRequested:
            if phase != .collapsed { collapse(reason: .dismissed) }

        case .toggleFullscreen:
            switch phase {
            case .fullscreen: phase = .open
            case .open, .peek: phase = .fullscreen
            case .collapsed: break
            }

        case .otherAppActivated:
            guard collapseOnAppSwitch, phase != .collapsed else { break }
            collapse(reason: .interrupted)

        case .screenLost:
            if phase != .collapsed { collapse(reason: .interrupted) }
        }

        return phase != before
    }

    private mutating func collapse(reason: CollapseReason) {
        // Only a panel that was being worked in is worth restoring. A peek
        // interrupted by an application switch has nothing in it yet, and
        // bringing it back as a full working panel would be a much bigger
        // gesture than the one the operator made.
        if phase.isHeld {
            restorePhase = phase
            collapseReason = reason
        } else {
            collapseReason = .dismissed
        }
        phase = .collapsed
    }
}
