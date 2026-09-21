import CoreGraphics
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

    /// The property the controller's gates read as well as `PanelState`, so a
    /// phase added to it is a phase the cursor can close in both layers at once.
    @Test("only a peek is dismissible by the pointer")
    func onlyAPeekIsDismissibleByThePointer() {
        let dismissible = PanelPhase.allCases.filter(\.isDismissibleByPointer)
        #expect(dismissible == [.peek], "the cursor may close \(dismissible), and only a peek has nothing typed in it")
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
/// The numbers below are the lab's, not anybody's taste. They bracket
/// `ApplicationSwitch.clickWindow` rather than pin it: a window shorter than
/// the slowest click-caused activation the lab has measured fails here, and so
/// does one long enough to swallow a hand going from the mouse to ⌘-Tab. A
/// window anywhere between — 0.05 s or 0.19 s as much as 0.15 s — passes, and
/// that is deliberate: nothing measured tells those apart, and a test that
/// pinned the number would only check that it had been typed the same way twice.
@Suite("Panel states — a click past the panel, heard as an app switch")
struct ApplicationSwitchTests {
    /// The slowest click-caused activation the lab has measured. All of them
    /// were measured on 2026-09-21 by logging the age of the last mouse-down at
    /// the top of the notification's handler: 2.0, 2.4, 2.5 and 2.7 ms for the
    /// first four clicks past a held panel on an idle guest; then between 2 and
    /// 32 ms in the runs later that day, the two slowest — 24 and 32 ms — both
    /// taken while the lab was booting the next check's machine beside the guest
    /// (the log rounds to whole milliseconds). The 32 ms is in
    /// .build/e2e/20260921-211640Z/focus.who-is-in-front until the lab prunes it.
    static let slowestClickCausedActivation: TimeInterval = 0.032

    /// A switch made with no click at all, measured in the first run: `open -a
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

    @Test("the window takes in every click the lab has measured, and no hand reaching for ⌘-Tab")
    func theWindowIsBracketedByMeasurement() {
        #expect(
            ApplicationSwitch.clickWindow >= Self.slowestClickCausedActivation,
            "a click the lab has seen arrive would be read as a switch, and bring back work the operator put away"
        )
        #expect(
            ApplicationSwitch.clickWindow < Self.handFromMouseToKey,
            "a window that long swallows a deliberate ⌘-Tab made just after a click, and with it the work it was protecting"
        )
    }

    /// About the comparison and not about the number: a click exactly at the
    /// edge is inside. Written in terms of the window so that it holds whatever
    /// the window is — the bracket above is what holds the window.
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

    /// `CGEventSource` answers with an interval, and nothing in its
    /// documentation promises a sensible one. An answer that cannot be true
    /// must not dismiss the panel.
    @Test("an impossible answer about the last click is not a click")
    func anImpossibleAnswerIsNotAClick() {
        for nonsense in [-1.0, -0.0001, -TimeInterval.infinity] {
            #expect(
                ApplicationSwitch.event(secondsSinceLastClick: nonsense, pointerIsPastThePanel: true)
                    == .otherAppActivated
            )
        }
    }

    /// Every button, and whichever of them went down last. The ages are handed
    /// in, because these tests run on the operator's Mac and must not ask it
    /// anything about its mouse.
    @Test("the last click is the youngest press of any button")
    func theLastClickIsTheYoungestPress() {
        #expect(
            Set(ApplicationSwitch.clickEventTypes.map(\.rawValue))
                == Set([CGEventType.leftMouseDown, .rightMouseDown, .otherMouseDown].map(\.rawValue)),
            "the click monitor listens for every button, so every button's last press is a click"
        )
        for youngest in ApplicationSwitch.clickEventTypes {
            let age = ApplicationSwitch.secondsSinceLastClick { type in
                type == youngest ? Self.slowestClickCausedActivation : Self.switchWithNoClick
            }
            #expect(
                age == Self.slowestClickCausedActivation,
                "a press of button type \(youngest.rawValue) a moment ago was not taken for the last click"
            )
        }
    }

    /// Against the island there is nothing to tell apart, and so nothing to
    /// read — not the clock, not the pointer.
    @Test("with no panel on screen an activation is only a switch, and nothing is asked")
    func nothingIsAskedAboutTheIsland() {
        var asked: [String] = []
        let verdict = ApplicationSwitch.verdict(
            in: .collapsed,
            secondsSinceLastClick: {
                asked.append("how long ago the last click was")
                return Self.slowestClickCausedActivation
            },
            pointerIsPastThePanel: {
                asked.append("where the pointer is")
                return true
            }
        )
        #expect(verdict == ApplicationSwitch.Verdict(event: .otherAppActivated, evidence: nil))
        #expect(asked.isEmpty, "the island asked \(asked)")
    }

    /// Both answers keep what they were decided from, because both are written
    /// to the log: a click read as a switch — a main thread late past the
    /// window, a pointer back on the panel — must be told from ⌘-Tab afterwards.
    @Test("a panel on screen is asked about, and both answers keep their evidence")
    func bothAnswersKeepTheirEvidence() {
        for phase in [PanelPhase.peek, .open, .fullscreen] {
            let click = ApplicationSwitch.verdict(
                in: phase,
                secondsSinceLastClick: { Self.slowestClickCausedActivation },
                pointerIsPastThePanel: { true }
            )
            #expect(click.event == .closeRequested, "\(phase)")
            #expect(click.evidence == .init(
                secondsSinceLastClick: Self.slowestClickCausedActivation, pointerIsPastThePanel: true
            ))

            let onThePanel = ApplicationSwitch.verdict(
                in: phase,
                secondsSinceLastClick: { Self.clickInsideThePanel },
                pointerIsPastThePanel: { false }
            )
            #expect(onThePanel.event == .otherAppActivated, "\(phase)")
            #expect(onThePanel.evidence == .init(
                secondsSinceLastClick: Self.clickInsideThePanel, pointerIsPastThePanel: false
            ))
        }
    }

    /// The two messengers of one click past a held panel, each as it reaches
    /// `PanelState`: the click monitor says `closeRequested` outright, and the
    /// notification says it only once `ApplicationSwitch` has read it. Whichever
    /// arrives first, the panel must end up the same. Neither road itself runs
    /// here — they are AppKit's — only what each of them hands the panel.
    @Test("a click past the panel leaves it dismissed, whichever message brought the news")
    func theClickDismissesThroughEitherRoad() {
        let byTheMonitor = PanelEvent.closeRequested
        let byTheNotification = ApplicationSwitch.verdict(
            in: .open,
            secondsSinceLastClick: { Self.slowestClickCausedActivation },
            pointerIsPastThePanel: { true }
        ).event
        for event in [byTheMonitor, byTheNotification] {
            var state = PanelState()
            state.apply(.revealRequested)
            state.apply(.interacted)
            state.apply(event)
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

/// Who has the keyboard once the panel lets go of it.
@Suite("Panel states — giving the keyboard back")
struct KeyboardHandbackTests {
    /// Escape and ⌘W reach uDeck only while it holds the keyboard. Measured in
    /// the guest on 2026-09-21: the workspace named uDeck as the application in
    /// front at the moment Escape closed a held panel.
    @Test("Escape and ⌘W bring back the application from before, because uDeck is still in front")
    func aDismissalFromUDeckRestores() {
        #expect(KeyboardHandback.restoresPreviousApplication(after: .dismissed, uDeckIsInFront: true))
    }

    /// Measured in the guest on 2026-09-21, before this rule: TextEdit in front,
    /// the panel held, a click past it onto the desktop — and two seconds later
    /// TextEdit was back over the Finder the click had brought forward.
    @Test("a click that already moved the keyboard is not overruled")
    func aClickPastThePanelIsNotOverruled() {
        #expect(!KeyboardHandback.restoresPreviousApplication(after: .dismissed, uDeckIsInFront: false))
    }

    @Test("an interruption never brings anything back, in front or not")
    func anInterruptionNeverRestores() {
        for inFront in [true, false] {
            #expect(!KeyboardHandback.restoresPreviousApplication(after: .interrupted, uDeckIsInFront: inFront))
        }
    }
}
