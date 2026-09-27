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
/// Every reading is an age counted back from the moment the news arrived, and
/// the fixtures below are the lab's, not anybody's taste. What decides is the
/// order of three things — the panel showing, the last click, and the last click
/// uDeck heard itself — and never how long ago any of them was.
@Suite("Panel states — a click past the panel, heard as an app switch")
struct ApplicationSwitchTests {
    /// The click past a held panel that the lab saw read as a switch, while the
    /// window this replaced still decided it (.build/e2e/kept/20260926-211629Z,
    /// panel.a-click-past-the-panel): the news came 232 ms after the button, in
    /// a whole lab run at `--jobs 2`, where the next check's machine boots
    /// beside the one being checked. The panel had been showing for 28.1 s and
    /// the click that held it open was 24.4 s old, as the reveal and the
    /// interaction lines of the same log place them.
    static let lateClickPastThePanel = ApplicationSwitch.Verdict.Evidence(
        secondsSinceLastClick: 0.232,
        secondsSinceShown: 28.105,
        secondsSinceLastClickHeard: 24.365,
        pointerIsPastThePanel: true
    )

    /// A click past a held panel with its news on time, as uDeck logged all
    /// four readings of it on 2026-09-27 (.build/e2e/kept/20260927-165246Z,
    /// probe.click-1, one of twelve such clicks there, every one read as
    /// closed): the news 6 ms after the button, the panel showing for 18.2 s,
    /// and the last click uDeck had heard — the one that held it open — 14.3 s
    /// before.
    static let clickPastThePanel = ApplicationSwitch.Verdict.Evidence(
        secondsSinceLastClick: 0.006,
        secondsSinceShown: 18.155,
        secondsSinceLastClickHeard: 14.337,
        pointerIsPastThePanel: true
    )

    /// A switch made with no click at all after the click that held the panel
    /// open: the Finder brought forward by `open -a` from outside the session.
    /// Logged the same day, once uDeck dated a click by its own button
    /// (.build/e2e/kept/20260927-200818Z, probe.switch-1): the last click 1866
    /// ms old as the system counts it, and 1.291 µs younger as uDeck heard it —
    /// the same click, the system's age of it older by the time the asking
    /// took — its local monitor handed it 8 ms after the button, and the panel
    /// showing for 5.0 s. The click came after the panel showed, and it is
    /// uDeck's own.
    static let switchAfterAClickInside = ApplicationSwitch.Verdict.Evidence(
        secondsSinceLastClick: 1.866,
        secondsSinceShown: 5.014,
        secondsSinceLastClickHeard: 1.866 - 0.000_001_291,
        pointerIsPastThePanel: true
    )

    /// A click *inside* the panel that brings another application forward: a
    /// card that launches something. Measured on 2026-09-21: the activation
    /// arrives about 12 ms after the click. The other two ages are not
    /// measured — no check makes this scene — and only their order matters: the
    /// panel showed before the click, and uDeck heard the click after it
    /// happened.
    static let clickInsideThePanel = ApplicationSwitch.Verdict.Evidence(
        secondsSinceLastClick: 0.012,
        secondsSinceShown: 4.0,
        secondsSinceLastClickHeard: 0.011,
        pointerIsPastThePanel: false
    )

    @Test("an application coming forward after a click past the panel is that click")
    func aClickPastThePanelIsRead() {
        #expect(ApplicationSwitch.event(given: Self.clickPastThePanel) == .closeRequested)
    }

    /// The reason the window went. Its line was 0.15 s, and the lab has seen
    /// the news come later than that; any other line would only move the
    /// failure to a busier machine.
    @Test("however late the news of a click past the panel comes, it is still that click")
    func theNewsHasNoDeadline() {
        #expect(
            ApplicationSwitch.event(given: Self.lateClickPastThePanel) == .closeRequested,
            "the operator put the panel away, and a slow notification turned it into an interruption"
        )
    }

    /// The trap that "any click since the panel showed" falls into. The click
    /// that held the peek open came after the panel showed, and the pointer has
    /// since gone past the panel; the operator ⌘-Tabs away without clicking.
    /// That click is uDeck's own and it heard it, so this is a switch.
    @Test("a click inside the panel and then a switch with no click is an interruption")
    func aClickInsideAndThenASwitchIsAnInterruption() {
        #expect(Self.switchAfterAClickInside.clickCameAfterThePanel, "the fixture must be the trap: a click after the panel showed")
        #expect(
            ApplicationSwitch.event(given: Self.switchAfterAClickInside) == .otherAppActivated,
            "the click that held the panel open was read as a click past it, and the work in it was thrown away"
        )
    }

    /// And through the panel itself: the work comes back whole, which is what
    /// the operator actually sees.
    @Test("the panel held open by a click inside it comes back whole after a switch with no click")
    func theWorkComesBackAfterAClickInsideAndASwitch() {
        var state = PanelState()
        state.apply(.revealRequested)
        state.apply(.interacted)
        state.apply(ApplicationSwitch.event(given: Self.switchAfterAClickInside))
        #expect(state.collapseReason == .interrupted)
        state.apply(.revealRequested)
        #expect(state.phase == .open)
    }

    /// A click from before the panel showed is about something else — the
    /// operator clicked in another application and then reached for the
    /// shortcut. Here uDeck never heard it (it was not running yet, say), so
    /// only its age against the panel's can say so. The ages are made up; the
    /// order is the case.
    @Test("a click from before the panel showed is not a click past it")
    func aClickFromBeforeThePanelIsNotAboutIt() {
        let evidence = ApplicationSwitch.Verdict.Evidence(
            secondsSinceLastClick: Self.switchAfterAClickInside.secondsSinceShown + 1,
            secondsSinceShown: Self.switchAfterAClickInside.secondsSinceShown,
            secondsSinceLastClickHeard: .infinity,
            pointerIsPastThePanel: true
        )
        #expect(ApplicationSwitch.event(given: evidence) == .otherAppActivated)
    }

    /// The same click read both ways has not come out as a tie — the system's
    /// age of it came out 1.3 to 24.8 µs older than uDeck's in the eight
    /// switches of .build/e2e/kept/20260927-200818Z — but a tie is not news
    /// either way: reading it as a click past the panel throws work away, so
    /// the benefit of the doubt goes to the work.
    @Test("a click as old as the last one uDeck heard is that one")
    func aTieIsHeard() {
        let evidence = ApplicationSwitch.Verdict.Evidence(
            secondsSinceLastClick: Self.switchAfterAClickInside.secondsSinceLastClick,
            secondsSinceShown: Self.switchAfterAClickInside.secondsSinceShown,
            secondsSinceLastClickHeard: Self.switchAfterAClickInside.secondsSinceLastClick,
            pointerIsPastThePanel: true
        )
        #expect(ApplicationSwitch.event(given: evidence) == .otherAppActivated)
    }

    /// The panel opened by the gesture or the shortcut and never clicked into,
    /// and a click past it: uDeck has heard no click at all since it started,
    /// so the age of the last one it heard is infinite. That is the plainest
    /// case of a click it has not heard, and nothing held it — every other
    /// click past the panel here comes after a click uDeck did hear. The ages
    /// are made up; the order is the case.
    @Test("a click past a panel nobody has clicked into is a click past it")
    func aClickPastAPanelUDeckNeverHeardAClickIn() {
        let neverHeard = ApplicationSwitch.LastHeard()
        #expect(neverHeard.age(at: 12.0) == .infinity, "a click uDeck never heard has no age")
        let evidence = ApplicationSwitch.Verdict.Evidence(
            secondsSinceLastClick: Self.clickPastThePanel.secondsSinceLastClick,
            secondsSinceShown: Self.clickPastThePanel.secondsSinceShown,
            secondsSinceLastClickHeard: neverHeard.age(at: 12.0),
            pointerIsPastThePanel: true
        )
        #expect(
            ApplicationSwitch.event(given: evidence) == .closeRequested,
            "the operator put away a panel he had not clicked into, and it came back whole"
        )
    }

    /// A card in the panel that launches an application: the click was on the
    /// panel, so the operator did not put the panel away — he asked for the
    /// thing that is now in front of it, and he is coming back.
    @Test("a click inside the panel that brings something forward is not a dismissal")
    func aClickInsideIsNotADismissal() {
        #expect(ApplicationSwitch.event(given: Self.clickInsideThePanel) == .otherAppActivated)
        // And not only because uDeck heard it: the pointer on the panel is
        // enough on its own.
        let unheard = ApplicationSwitch.Verdict.Evidence(
            secondsSinceLastClick: Self.clickInsideThePanel.secondsSinceLastClick,
            secondsSinceShown: Self.clickInsideThePanel.secondsSinceShown,
            secondsSinceLastClickHeard: .infinity,
            pointerIsPastThePanel: false
        )
        #expect(ApplicationSwitch.event(given: unheard) == .otherAppActivated)
    }

    /// The monitor that heard the click holding the panel open ran late — the
    /// local one was handed its click 117 ms after the button in the lab on
    /// 2026-09-27, the slowest of 15 — and in between the operator clicked past
    /// the panel. Dated by when its monitor ran, the click inside would count
    /// as heard the click past the panel too, and the news of that click would
    /// read as a switch. Dated by its own button, it covers nothing after it.
    /// The news comes 40 ms after the click past the panel, inside the 2 to
    /// 232 ms the lab has seen.
    @Test("a click whose monitor ran late has not made the clicks before it ran heard")
    func aLateMonitorHearsOnlyItsOwnClick() {
        let inside = 100.000
        let handedOver = inside + 0.117
        let pastThePanel = 100.090
        let news = pastThePanel + 0.040
        var heard = ApplicationSwitch.LastHeard()
        heard.heard(wentDown: inside, handedOverAt: handedOver)
        #expect(heard.wentDown == inside)
        #expect(abs((heard.handedOverAfter ?? 0) - 0.117) < 1e-9, "how late it was handed over is kept for the log")

        let evidence = ApplicationSwitch.Verdict.Evidence(
            secondsSinceLastClick: news - pastThePanel,
            secondsSinceShown: news - 95.0,
            secondsSinceLastClickHeard: heard.age(at: news),
            pointerIsPastThePanel: true
        )
        #expect(
            ApplicationSwitch.event(given: evidence) == .closeRequested,
            "a monitor running late made the click past the panel look heard, and the dismissal became an interruption"
        )
    }

    /// Three roads bring clicks — the local monitor, the global one and the
    /// menus — and one can run behind another. An older click arriving after a
    /// younger one must not make the younger one news again.
    @Test("an older click heard late does not make a younger one unheard")
    func anOlderClickHeardLateChangesNothing() {
        var heard = ApplicationSwitch.LastHeard()
        heard.heard(wentDown: 100.090, handedOverAt: 100.101)
        heard.heard(wentDown: 100.000, handedOverAt: 100.117)
        #expect(heard.wentDown == 100.090)
        #expect(abs((heard.handedOverAfter ?? 0) - 0.011) < 1e-9)
        #expect(abs(heard.age(at: 100.130) - 0.040) < 1e-9)
    }

    /// `CGEventSource` answers with an interval, and nothing in its
    /// documentation promises a sensible one. An answer that cannot be true
    /// must not dismiss the panel.
    @Test("an impossible answer about the last click is not a click")
    func anImpossibleAnswerIsNotAClick() {
        for nonsense in [-1.0, -0.0001, -TimeInterval.infinity] {
            let evidence = ApplicationSwitch.Verdict.Evidence(
                secondsSinceLastClick: nonsense,
                secondsSinceShown: Self.clickPastThePanel.secondsSinceShown,
                secondsSinceLastClickHeard: Self.clickPastThePanel.secondsSinceLastClickHeard,
                pointerIsPastThePanel: true
            )
            #expect(ApplicationSwitch.event(given: evidence) == .otherAppActivated, "\(nonsense)")
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
                type == youngest ? Self.lateClickPastThePanel.secondsSinceLastClick : Self.switchAfterAClickInside.secondsSinceLastClick
            }
            #expect(
                age == Self.lateClickPastThePanel.secondsSinceLastClick,
                "a press of button type \(youngest.rawValue) a moment ago was not taken for the last click"
            )
        }
    }

    /// Against the island there is nothing to tell apart, and so nothing to
    /// read — not the clocks, not the pointer.
    @Test("with no panel on screen an activation is only a switch, and nothing is asked")
    func nothingIsAskedAboutTheIsland() {
        var asked = false
        let verdict = ApplicationSwitch.verdict(in: .collapsed) {
            asked = true
            return Self.clickPastThePanel
        }
        #expect(verdict == ApplicationSwitch.Verdict(event: .otherAppActivated, evidence: nil))
        #expect(!asked, "the island was asked about")
    }

    /// Both answers keep what they were decided from, because both are written
    /// to the log: a click read as a switch must be told from ⌘-Tab afterwards.
    @Test("a panel on screen is asked about, and both answers keep their evidence")
    func bothAnswersKeepTheirEvidence() {
        for phase in [PanelPhase.peek, .open, .fullscreen] {
            let click = ApplicationSwitch.verdict(in: phase) { Self.lateClickPastThePanel }
            #expect(click.event == .closeRequested, "\(phase)")
            #expect(click.evidence == Self.lateClickPastThePanel)

            let switched = ApplicationSwitch.verdict(in: phase) { Self.switchAfterAClickInside }
            #expect(switched.event == .otherAppActivated, "\(phase)")
            #expect(switched.evidence == Self.switchAfterAClickInside)
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
        let byTheNotification = ApplicationSwitch.verdict(in: .open) { Self.lateClickPastThePanel }.event
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
        state.apply(ApplicationSwitch.event(given: Self.lateClickPastThePanel), collapseOnAppSwitch: false)
        #expect(state.phase == .collapsed)
        #expect(state.collapseReason == .dismissed)

        // And the switch it is not still obeys the setting.
        state.apply(.revealRequested, collapseOnAppSwitch: false)
        state.apply(.interacted, collapseOnAppSwitch: false)
        state.apply(ApplicationSwitch.event(given: Self.switchAfterAClickInside), collapseOnAppSwitch: false)
        #expect(state.phase == .open)
    }

    @Test("a switch with no click still brings the work back whole")
    func theSwitchStillRestores() {
        for phase in [PanelPhase.open, .fullscreen] {
            var state = PanelState()
            state.apply(.revealRequested)
            state.apply(.interacted)
            if phase == .fullscreen { state.apply(.toggleFullscreen) }
            state.apply(ApplicationSwitch.event(given: Self.switchAfterAClickInside))
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
