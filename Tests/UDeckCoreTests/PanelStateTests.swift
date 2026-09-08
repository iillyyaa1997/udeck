import Foundation
import Testing
@testable import UDeckCore

@Suite("Panel states")
struct PanelStateTests {
    @Test("the pointer reveals a peek, and taking it away closes the peek")
    func peekOpensAndCloses() {
        var state = PanelState()
        var changed = state.apply(.revealRequested)
        #expect(changed)
        #expect(state.phase == .peek)
        changed = state.apply(.pointerLeft)
        #expect(changed)
        #expect(state.phase == .collapsed)
    }

    @Test("the first interaction promotes a peek into a held panel")
    func interactionHolds() {
        var state = PanelState()
        state.apply(.revealRequested)
        state.apply(.interacted)
        #expect(state.phase == .open)
        #expect(state.phase.isHeld)
    }

    /// The rule the whole design exists to guarantee. If this ever regresses,
    /// a half-typed answer goes to whatever shell was frontmost.
    @Test("once held, the pointer leaving never closes the panel")
    func heldSurvivesPointerLeaving() {
        var state = PanelState()
        state.apply(.revealRequested)
        state.apply(.interacted)
        for _ in 0 ..< 50 {
            let changed = state.apply(.pointerLeft)
            #expect(changed == false)
            #expect(state.phase == .open)
        }
    }

    @Test("fullscreen also survives the pointer leaving")
    func fullscreenSurvivesPointerLeaving() {
        var state = PanelState()
        state.apply(.revealRequested)
        state.apply(.interacted)
        state.apply(.toggleFullscreen)
        #expect(state.phase == .fullscreen)
        state.apply(.pointerLeft)
        #expect(state.phase == .fullscreen)
    }

    @Test("Escape with text in a field gives up the field, not the panel")
    func escapeProtectsTypedText() {
        var state = PanelState()
        state.apply(.revealRequested)
        state.apply(.interacted)
        var changed = state.apply(.escape(isEditingText: true))
        #expect(changed == false)
        #expect(state.phase == .open)
        #expect(state.lastEventWasConsumedByField)
        // A second Escape, now that nothing is being edited, closes it.
        changed = state.apply(.escape(isEditingText: false))
        #expect(changed)
        #expect(state.phase == .collapsed)
        #expect(state.lastEventWasConsumedByField == false)
    }

    @Test("the same button toggles fullscreen both ways")
    func fullscreenToggles() {
        var state = PanelState()
        state.apply(.revealRequested)
        state.apply(.interacted)
        state.apply(.toggleFullscreen)
        #expect(state.phase == .fullscreen)
        state.apply(.toggleFullscreen)
        #expect(state.phase == .open)
    }

    @Test("a peek sent to fullscreen comes back to the working size")
    func peekToFullscreenReturnsToOpen() {
        var state = PanelState()
        state.apply(.revealRequested)
        state.apply(.toggleFullscreen)
        #expect(state.phase == .fullscreen)
        state.apply(.toggleFullscreen)
        #expect(state.phase == .open)
    }

    @Test("switching to another application retracts the panel")
    func appSwitchCollapses() {
        var state = PanelState()
        state.apply(.revealRequested)
        state.apply(.interacted)
        let changed = state.apply(.otherAppActivated)
        #expect(changed)
        #expect(state.phase == .collapsed)
    }

    @Test("switching away can be turned off")
    func appSwitchCanBeDisabled() {
        var state = PanelState()
        state.apply(.revealRequested)
        state.apply(.interacted)
        let changed = state.apply(.otherAppActivated, collapseOnAppSwitch: false)
        #expect(changed == false)
        #expect(state.phase == .open)
    }

    /// "Come back to it and it is as you left it" — including fullscreen, and
    /// including whatever was typed into it, which the host keeps because the
    /// content is never torn down.
    @Test("an interrupted panel comes back in the state it was interrupted in")
    func interruptedPanelRestores() {
        var state = PanelState()
        state.apply(.revealRequested)
        state.apply(.interacted)
        state.apply(.toggleFullscreen)
        state.apply(.otherAppActivated)
        #expect(state.phase == .collapsed)
        state.apply(.revealRequested)
        #expect(state.phase == .fullscreen)
    }

    @Test("a panel the operator closed starts over from a peek")
    func dismissedPanelStartsOver() {
        var state = PanelState()
        state.apply(.revealRequested)
        state.apply(.interacted)
        state.apply(.closeRequested)
        #expect(state.phase == .collapsed)
        state.apply(.revealRequested)
        #expect(state.phase == .peek, "closing means done; the next reveal is a fresh glance")
    }

    @Test("clicking outside closes a held panel")
    func clickOutsideCloses() {
        var state = PanelState()
        state.apply(.revealRequested)
        state.apply(.interacted)
        state.apply(.closeRequested)
        #expect(state.phase == .collapsed)
    }

    @Test("losing the screen retracts the panel and remembers where it was")
    func screenLossRestores() {
        var state = PanelState()
        state.apply(.revealRequested)
        state.apply(.interacted)
        state.apply(.screenLost)
        #expect(state.phase == .collapsed)
        state.apply(.revealRequested)
        #expect(state.phase == .open)
    }

    @Test("a collapsed panel ignores everything except a reveal")
    func collapsedIgnoresNoise() {
        var state = PanelState()
        for event: PanelEvent in [.pointerLeft, .interacted, .escape(isEditingText: false),
                                  .closeRequested, .toggleFullscreen, .otherAppActivated, .screenLost] {
            let changed = state.apply(event)
            #expect(changed == false, "\(event) should do nothing while collapsed")
            #expect(state.phase == .collapsed)
        }
    }
}

@Suite("Panel states — coming back")
struct PanelRestoreTests {
    /// A peek has nothing in it yet, so it is not worth restoring: bringing a
    /// full working panel back from a glance the operator abandoned would be a
    /// much bigger gesture than the one they made.
    @Test("a peek interrupted by an app switch does not come back as a working panel")
    func interruptedPeekDoesNotBecomeOpen() {
        var state = PanelState()
        state.apply(.revealRequested)
        #expect(state.phase == .peek)
        state.apply(.otherAppActivated)
        #expect(state.phase == .collapsed)
        #expect(state.collapseReason == .dismissed)
        state.apply(.revealRequested)
        #expect(state.phase == .peek)
    }

    @Test("a working panel interrupted by an app switch comes back as it was")
    func interruptedWorkComesBack() {
        for phase in [PanelPhase.open, .fullscreen] {
            var state = PanelState()
            state.apply(.revealRequested)
            state.apply(.interacted)
            if phase == .fullscreen { state.apply(.toggleFullscreen) }
            #expect(state.phase == phase)
            state.apply(.otherAppActivated)
            #expect(state.collapseReason == .interrupted)
            state.apply(.revealRequested)
            #expect(state.phase == phase)
        }
    }
}
