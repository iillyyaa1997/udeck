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

/// Telling the operator's click apart from a real application switch.
///
/// The numbers below are the lab's, not anybody's taste, and they are named so
/// that the constant they bracket cannot be moved without one of these failing.
@Suite("Panel states — a click past the panel, heard as an app switch")
struct ApplicationSwitchTests {
    /// The slowest click-caused activation measured in the guest on 2026-09-21:
    /// four clicks past a held panel brought the notification 2.0, 2.4, 2.5 and
    /// 2.7 ms after the button went down. Measured by logging the age of the
    /// last mouse-down at the top of the notification's handler; the run is kept
    /// as `race.race` under .build/e2e/ until the lab prunes it.
    static let slowestClickCausedActivation: TimeInterval = 0.0027

    /// A switch made with no click at all, measured in the same run: `open -a
    /// Finder` from outside the session, with the last click seven and a half
    /// seconds old.
    static let switchWithNoClick: TimeInterval = 7.577

    /// A click *inside* the panel, measured in the same run: the activation that
    /// follows it arrives about 12 ms later. It is only ever uDeck's own, but a
    /// card that launches something would put another application's name on it.
    static let clickInsideThePanel: TimeInterval = 0.012

    /// The fastest a hand could leave the mouse and reach ⌘-Tab. Not measured —
    /// it is the far side of the line, and it only has to be an honest lower
    /// bound on a deliberate second action.
    static let handFromMouseToKey: TimeInterval = 0.2

    @Test("an application coming forward a moment after a click past the panel is that click")
    func aClickPastThePanelIsRead() {
        #expect(
            ApplicationSwitch.event(
                secondsSinceLastClick: Self.slowestClickCausedActivation, pointerIsPastThePanel: true
            ) == .closeRequested
        )
    }

    @Test("⌘-Tab, and every switch made without a click, is still an interruption")
    func aSwitchWithNoClickIsStillAnInterruption() {
        #expect(
            ApplicationSwitch.event(
                secondsSinceLastClick: Self.switchWithNoClick, pointerIsPastThePanel: true
            ) == .otherAppActivated
        )
    }

    /// A card in the panel that launches an application: the click was on the
    /// panel, so the operator did not put the panel away — he asked for the
    /// thing that is now in front of it, and he is coming back.
    @Test("a click inside the panel that brings something forward is not a dismissal")
    func aClickInsideIsNotADismissal() {
        #expect(
            ApplicationSwitch.event(
                secondsSinceLastClick: Self.clickInsideThePanel, pointerIsPastThePanel: false
            ) == .otherAppActivated
        )
    }

    @Test("the window is the measurement with room, and not a number someone liked")
    func theWindowIsTiedToTheMeasurement() {
        #expect(
            ApplicationSwitch.clickWindow >= Self.slowestClickCausedActivation * 10,
            "a window near the measured delivery time leaves a busy machine reading its own clicks as switches"
        )
        #expect(
            ApplicationSwitch.clickWindow < Self.handFromMouseToKey,
            "a window that long swallows a deliberate ⌘-Tab made just after a click, and with it the work it was protecting"
        )
    }

    @Test("the edge of the window is the edge of the window")
    func theWindowHasAnEdge() {
        #expect(
            ApplicationSwitch.event(
                secondsSinceLastClick: ApplicationSwitch.clickWindow, pointerIsPastThePanel: true
            ) == .closeRequested
        )
        #expect(
            ApplicationSwitch.event(
                secondsSinceLastClick: ApplicationSwitch.clickWindow + 0.001, pointerIsPastThePanel: true
            ) == .otherAppActivated
        )
    }

    /// `CGEventSource` answers with an interval, and a machine that has seen no
    /// click at all is not obliged to answer with a sensible one. An answer that
    /// cannot be true must not dismiss the panel.
    @Test("an impossible answer about the last click is not a click")
    func anImpossibleAnswerIsNotAClick() {
        for nonsense in [-1.0, -0.0001, -TimeInterval.infinity] {
            #expect(
                ApplicationSwitch.event(secondsSinceLastClick: nonsense, pointerIsPastThePanel: true)
                    == .otherAppActivated
            )
        }
    }

    @Test("a click past the panel leaves it dismissed, whichever message brought the news")
    func theClickDismissesThroughEitherRoad() {
        for secondsSinceLastClick in [0.0, Self.slowestClickCausedActivation] {
            var state = PanelState()
            state.apply(.revealRequested)
            state.apply(.interacted)
            state.apply(
                ApplicationSwitch.event(
                    secondsSinceLastClick: secondsSinceLastClick, pointerIsPastThePanel: true
                )
            )
            #expect(state.phase == .collapsed)
            #expect(state.collapseReason == .dismissed)
            state.apply(.revealRequested)
            #expect(state.phase == .peek, "the operator closed it, so the next reveal is a fresh glance")
        }
    }

    /// "Retract when I switch applications" is a preference about switching
    /// applications. Turning it off has never kept the panel up through a click
    /// past it — the click monitor collapsed it a few milliseconds later anyway —
    /// and reading the notification as that click must not quietly change that.
    @Test("a click past the panel still closes it when collapsing on an app switch is off")
    func theClickIsNotTheAppSwitchSetting() {
        var state = PanelState()
        state.apply(.revealRequested, collapseOnAppSwitch: false)
        state.apply(.interacted, collapseOnAppSwitch: false)
        state.apply(
            ApplicationSwitch.event(
                secondsSinceLastClick: Self.slowestClickCausedActivation, pointerIsPastThePanel: true
            ),
            collapseOnAppSwitch: false
        )
        #expect(state.phase == .collapsed)
        #expect(state.collapseReason == .dismissed)

        // And the switch it is not still obeys the setting.
        state.apply(.revealRequested, collapseOnAppSwitch: false)
        state.apply(.interacted, collapseOnAppSwitch: false)
        state.apply(
            ApplicationSwitch.event(
                secondsSinceLastClick: Self.switchWithNoClick, pointerIsPastThePanel: true
            ),
            collapseOnAppSwitch: false
        )
        #expect(state.phase == .open)
    }

    @Test("a switch with no click still brings the work back whole")
    func theSwitchStillRestores() {
        for phase in [PanelPhase.open, .fullscreen] {
            var state = PanelState()
            state.apply(.revealRequested)
            state.apply(.interacted)
            if phase == .fullscreen { state.apply(.toggleFullscreen) }
            state.apply(
                ApplicationSwitch.event(
                    secondsSinceLastClick: Self.switchWithNoClick, pointerIsPastThePanel: true
                )
            )
            #expect(state.collapseReason == .interrupted)
            state.apply(.revealRequested)
            #expect(state.phase == phase, "unfinished work comes back; that is what an interruption is for")
        }
    }
}
