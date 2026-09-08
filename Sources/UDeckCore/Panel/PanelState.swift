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
            // An interrupted panel comes back exactly as it was left, content
            // and all. A dismissed one starts over from a peek, because the
            // operator said they were done with it.
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
