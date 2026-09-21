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
/// button went down — about 5 ms ahead of the monitor's own callback. A panel
/// restored straight to `open` was never clicked, so uDeck never came forward,
/// so clicking away switches nothing: no notification is posted at all and the
/// monitor is the only messenger.
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
    /// the last mouse-down at the top of the notification's handler, four clicks
    /// past a held panel on an idle macOS 27 guest: 2.0, 2.4, 2.5 and 2.7 ms.
    /// This is fifty times the slowest of them, so a machine an order of
    /// magnitude busier is still read correctly. The other side of the line is a
    /// human letting go of the mouse and reaching for ⌘-Tab, which no one does
    /// inside a sixth of a second; that switch stays an interruption, which is
    /// what brings unfinished work back.
    public static let clickWindow: TimeInterval = 0.15

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
            // Only a peek is dismissible by the cursor. This is the whole
            // typing-safety rule, stated once.
            if phase == .peek { collapse(reason: .dismissed) }

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
