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
/// application coming forward while the pointer sits past the panel, after a
/// click that came once the panel was showing and that uDeck has not heard yet,
/// *is* that click.
///
/// **There is no clock in that rule, and there used to be.** It said "a moment
/// after a click": another application coming forward within 0.15 s of the last
/// mouse-down, which was five times the slowest delivery measured on 2026-09-21.
/// A delivery time has no ceiling that can be measured once. On 2026-09-26, in a
/// whole lab run at `--jobs 2`, the news of a click past a held panel came 232 ms
/// after the button (.build/e2e/kept/20260926-211629Z,
/// panel.a-click-past-the-panel), and the panel read the operator putting it
/// away as an interruption and came back whole. So the rule asks in what order
/// things happened, not how long they took.
///
/// **What the order is taken from.** uDeck hears every click itself, by one of
/// two monitors: a click on one of its own windows through the local one, as it
/// is delivered, and a click anywhere else through the global one, which is the
/// messenger that loses the race above. A click uDeck has heard has already been
/// answered — a click on the panel was an interaction, a click past it closed the
/// panel through the monitor, and a click in the margin round the panel was
/// forgiven there. So the news of another application can only be the news of a
/// click that is younger than every click uDeck has heard, and younger than the
/// panel itself: a click from before the panel showed is about something else.
///
/// Measured in the guest on 2026-09-27 (.build/e2e/kept/20260927-165246Z): twelve
/// clicks past a held panel, the news 5 to 148 ms after the button and the last
/// click uDeck had heard 13 to 36 s old — all twelve read as closed. Three
/// switches with no click after a click inside, and three after a click in the
/// margin of a restored panel: uDeck had heard the last click 7 to 16 ms after
/// the system dated it, and all six were read as switches.
///
/// "Any click since the panel showed" is not enough, and the difference is the
/// work this exists to protect. A peek is held open by a click *inside* it, and
/// that click came after the panel showed. The operator who then leaves with
/// ⌘-Tab, clicking nothing, would find the panel closed as dismissed and his work
/// gone at the next reveal — which is exactly what an honest switch must not do.
/// That click is uDeck's own, and uDeck heard it.
public enum ApplicationSwitch {
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
        /// The readings the decision took, kept so that both outcomes can be
        /// written down with them. A switch read as a switch and a click read
        /// as a switch look the same in the panel's phase; only these tell a
        /// false interruption from an honest ⌘-Tab afterwards.
        ///
        /// Every one of them is an age, counted back from the same moment.
        public struct Evidence: Equatable, Sendable {
            /// How long ago any mouse button last went down, anywhere on the
            /// machine, as the system counts it.
            public let secondsSinceLastClick: TimeInterval

            /// How long the panel has been on screen: since it last came out of
            /// `collapsed`.
            public let secondsSinceShown: TimeInterval

            /// How long ago uDeck itself last heard a mouse button go down, by
            /// either of its monitors. Infinite when it has heard none.
            public let secondsSinceLastClickHeard: TimeInterval

            public let pointerIsPastThePanel: Bool

            public init(
                secondsSinceLastClick: TimeInterval,
                secondsSinceShown: TimeInterval,
                secondsSinceLastClickHeard: TimeInterval,
                pointerIsPastThePanel: Bool
            ) {
                self.secondsSinceLastClick = secondsSinceLastClick
                self.secondsSinceShown = secondsSinceShown
                self.secondsSinceLastClickHeard = secondsSinceLastClickHeard
                self.pointerIsPastThePanel = pointerIsPastThePanel
            }

            /// Whether the last click came after the panel showed.
            public var clickCameAfterThePanel: Bool {
                secondsSinceLastClick < secondsSinceShown
            }

            /// Whether the last click is one uDeck has not heard yet.
            ///
            /// Strictly younger. The same click, read twice, comes out *older*
            /// from the system than from uDeck: uDeck notes a click when its
            /// monitor is handed it, which is after the button went down, and
            /// the caller reads uDeck's own clocks before it asks the system.
            /// Both of those only ever push the two readings of one click apart
            /// in the direction that says "heard" — 7 to 16 ms apart in the six
            /// switches the lab logged on 2026-09-27.
            public var clickIsUnheard: Bool {
                secondsSinceLastClick < secondsSinceLastClickHeard
            }
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
    /// and the readings are one closure so that, when it is not asked, they are
    /// not taken either.
    public static func verdict(in phase: PanelPhase, readings: () -> Verdict.Evidence) -> Verdict {
        guard phase.isVisible else { return Verdict(event: .otherAppActivated, evidence: nil) }
        let evidence = readings()
        return Verdict(event: event(given: evidence), evidence: evidence)
    }

    /// What to tell the panel when another application became frontmost.
    ///
    /// A click past the panel, and so `closeRequested`, when all three hold:
    ///
    /// * the pointer is past the panel — outside the region that keeps it alive,
    ///   the same test a click outside has to pass. A click *on* the panel that
    ///   launches something is not the operator putting the panel away, so that
    ///   stays an interruption;
    /// * the last click came after the panel showed, so it is about this panel;
    /// * and uDeck has not heard it yet, so no monitor has answered it — it is
    ///   the click whose news this is, and not the one that held the panel open.
    ///
    /// Anything else is another application coming forward on its own account,
    /// and that is an interruption. An age that cannot be true — below zero, or
    /// not a number — is not a click.
    public static func event(given evidence: Verdict.Evidence) -> PanelEvent {
        guard evidence.pointerIsPastThePanel,
              evidence.secondsSinceLastClick >= 0,
              evidence.clickCameAfterThePanel,
              evidence.clickIsUnheard
        else {
            return .otherAppActivated
        }
        return .closeRequested
    }
}

/// Whether giving the keyboard back also brings back the application that had
/// it before uDeck took it.
///
/// Only when the operator closed the panel *and uDeck is still in front* at the
/// moment it lets go.
///
/// A panel that was clicked into has made uDeck the frontmost application, so
/// Escape and ⌘W pressed at one find it in front and the application from
/// before comes back, which is what closing a panel you were typing into should
/// do. Measured for Escape on 2026-09-21 at a held panel, TextEdit in front
/// before it: the workspace named uDeck as in front when Escape closed it, and
/// a key typed next reached TextEdit. With nothing brought back, the same key
/// reached nobody at all.
///
/// At a **peek** it is not in front, and the two keys therefore restore nothing
/// there. Holding the keyboard is not being in front: a peek takes the keyboard
/// and says so (`took the keyboard: … activated=true`), and the handback names
/// the *other* application as frontmost every time the lab has kept a run of it.
/// So this rule did change what happens after a peek — and it changed nothing
/// the operator can see, which was measured on 2026-09-22 rather than argued:
/// TextEdit in front on a document, a peek opened by the gesture, Escape, and
/// then one key — TextEdit held it, on this rule (`so leaving it there`) and on
/// the rule before it (`so bringing back TextEdit`) alike; ⌘W, twice over, the
/// same. There is nothing to bring back at a peek, because the application that
/// would be brought back never lost the front. What holds that is
/// `panel.the-key-after-escape` in the lab, which types and reads the document:
/// the panel being gone from the log is what `panel.escape` watches, and a uDeck
/// still holding the keyboard passes that.
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
