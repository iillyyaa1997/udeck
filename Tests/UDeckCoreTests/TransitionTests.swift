import CoreGraphics
import Foundation
import Testing
@testable import UDeckCore

/// The plan a phase change makes, which is where the panel's faults lived.
///
/// Each of these was a bug the operator saw, restated as one assertion against
/// a value. They were unreachable while the same decisions were a hundred lines
/// inside an AppKit callback — which is the argument for the value existing.
@Suite("Transition plans")
struct TransitionTests {
    let metrics = PanelMetrics()
    let tuning = GestureTuning()

    private func geometry(_ screen: ScreenSnapshot) -> PanelGeometry {
        PanelGeometry(screen: screen, tuning: tuning, metrics: metrics)
    }

    private func plan(
        _ screen: ScreenSnapshot,
        from: PanelPhase,
        to: PanelPhase,
        window: CGRect? = nil,
        animated: Bool = true
    ) -> PanelTransition {
        let g = geometry(screen)
        return PanelTransition.plan(
            from: from,
            to: to,
            currentWindowFrame: window ?? g.settledWindowFrame(for: from),
            geometry: g,
            metrics: metrics,
            animated: animated
        )
    }

    /// The fault: the outgoing rectangle was stated at the window's own origin
    /// and then read against the stage that replaced it, so the panel slid in
    /// from the corner on every reveal after the first.
    ///
    /// The invariant: whatever rectangle the transition starts from, put back
    /// where the stage is, has to land exactly where the outgoing panel was.
    @Test("a transition starts from where the panel actually is, not from a corner")
    func transitionStartsWherePanelIs() {
        for screen in ScreenFixtures.both {
            let g = geometry(screen)
            for from in PanelPhase.allCases {
                for to in PanelPhase.allCases where to != from {
                    let p = plan(screen, from: from, to: to)
                    guard let restated = p.restatedPanelRect else { continue }
                    let backOnScreen = CGRect(
                        x: p.stageFrame.minX + restated.minX,
                        y: p.stageFrame.maxY - restated.maxY,
                        width: restated.width,
                        height: restated.height
                    )
                    #expect(backOnScreen.isApproximately(g.frame(for: from), within: 0.001),
                            "\(from) -> \(to) on \(screen.name) starts at \(backOnScreen), not \(g.frame(for: from))")
                }
            }
        }
    }

    /// The same rule for where it ends.
    @Test("a transition ends exactly where the geometry says the panel goes")
    func transitionEndsWherePanelBelongs() {
        for screen in ScreenFixtures.both {
            let g = geometry(screen)
            for to in PanelPhase.allCases {
                let p = plan(screen, from: .collapsed, to: to)
                let backOnScreen = CGRect(
                    x: p.stageFrame.minX + p.panelRect.minX,
                    y: p.stageFrame.maxY - p.panelRect.maxY,
                    width: p.panelRect.width,
                    height: p.panelRect.height
                )
                #expect(backOnScreen.isApproximately(g.frame(for: to), within: 0.001),
                        "-> \(to) on \(screen.name) ends at \(backOnScreen), not \(g.frame(for: to))")
            }
        }
    }

    /// The fault: the window stayed oversized between transitions, leaving a
    /// dead strip of screen around the panel that swallowed clicks meant for
    /// what was underneath.
    @Test("the window always has a settled frame to come down to, and it is the panel")
    func everyPlanSettlesOntoThePanel() {
        for screen in ScreenFixtures.both {
            let g = geometry(screen)
            for to in PanelPhase.allCases {
                let p = plan(screen, from: .peek, to: to)
                #expect(p.settledWindowFrame == g.settledWindowFrame(for: to))
                // The stage is never smaller than what it has to hold.
                #expect(p.stageFrame.width >= p.settledWindowFrame.width - 0.001)
                #expect(p.stageFrame.height >= p.settledWindowFrame.height - 0.001)
            }
        }
    }

    /// "Opening and closing must not share a curve." A spring on the way out
    /// means the panel bounces back towards someone who has already dismissed
    /// it, which reads as the interface arguing with them.
    @Test("arriving is a spring and leaving is not")
    func arrivalAndDepartureUseDifferentCurves() {
        let arriving = plan(ScreenFixtures.builtInNotched, from: .collapsed, to: .peek)
        #expect(arriving.isArriving)
        guard case .spring = arriving.motion else {
            Issue.record("arriving on \(arriving.motion)"); return
        }

        let leaving = plan(ScreenFixtures.builtInNotched, from: .peek, to: .collapsed)
        #expect(!leaving.isArriving)
        guard case .ease(let duration) = leaving.motion else {
            Issue.record("leaving on \(leaving.motion)"); return
        }
        #expect(duration == metrics.collapseDuration)
    }

    /// A peek becoming a panel, and a panel becoming fullscreen, are arrivals
    /// too — only going away is a departure.
    @Test("every phase but collapsed is an arrival")
    func onlyCollapseIsADeparture() {
        for to in PanelPhase.allCases {
            #expect(plan(ScreenFixtures.builtInNotched, from: .collapsed, to: to).isArriving == (to != .collapsed))
        }
    }

    /// The window must not be brought down before the shape has arrived, or the
    /// panel is clipped by its own window mid-animation — and on a screen with a
    /// real notch, where the collapsed state draws nothing at rest, settling
    /// early is what deletes the closing animation outright.
    @Test("the window settles after the motion, never during it")
    func settleWaitsForTheMotion() {
        let closing = plan(ScreenFixtures.builtInNotched, from: .peek, to: .collapsed)
        #expect(closing.settleAfter >= metrics.collapseDuration)

        let opening = plan(ScreenFixtures.builtInNotched, from: .collapsed, to: .peek)
        #expect(opening.settleAfter >= metrics.revealPerceivedDuration,
                "settling at \(opening.settleAfter)s cuts a spring that arrives at \(metrics.revealPerceivedDuration)s")
    }

    /// The content is sequenced behind the frame on the way in and leaves faster
    /// than it arrives; a departure has no delay to give it.
    @Test("content follows the shape in, and does not wait on the way out")
    func contentIsSequencedBehindTheShape() {
        let opening = plan(ScreenFixtures.builtInNotched, from: .collapsed, to: .open)
        #expect(opening.contentDelay == metrics.contentRevealDelay)
        #expect(opening.contentMotion == .ease(duration: metrics.contentRevealDuration))

        let closing = plan(ScreenFixtures.builtInNotched, from: .open, to: .collapsed)
        #expect(closing.contentDelay == 0)
        #expect(closing.contentMotion == .ease(duration: metrics.contentHideDuration))
    }

    /// A placement is not a transition: a screen change or a first show has
    /// nothing to watch, and animating it is what made the panel fly between
    /// displays.
    @Test("an unanimated placement moves nothing and settles at once")
    func placementIsNotATransition() {
        let p = plan(ScreenFixtures.builtInNotched, from: .peek, to: .open, animated: false)
        #expect(p.motion == .immediate)
        #expect(p.contentMotion == .immediate)
        #expect(p.settleAfter == 0)
        #expect(p.restatedPanelRect == nil, "nothing is animating, so there is nothing to restate")
    }

    /// The fault: the panel behaved differently on a display it was not already
    /// on, because the window moved as well as resized. A plan made against a
    /// window on the wrong screen must still restate the outgoing rectangle.
    @Test("arriving on a display the window is not on restates before it animates")
    func arrivingOnAnotherDisplayRestatesFirst() {
        let elsewhere = CGRect(x: -3000, y: -3000, width: 400, height: 200)
        let p = plan(ScreenFixtures.builtInNotched, from: .collapsed, to: .peek, window: elsewhere)
        #expect(p.restatedPanelRect != nil)
    }

    /// And the converse: a window already standing on the stage has a rectangle
    /// that already means what it says, so restating it would be a wasted frame.
    @Test("a window already on the stage is not restated")
    func aWindowAlreadyOnTheStageIsLeftAlone() {
        let g = geometry(ScreenFixtures.builtInNotched)
        let p = plan(ScreenFixtures.builtInNotched, from: .peek, to: .open,
                     window: g.windowFrame(for: .open))
        #expect(p.restatedPanelRect == nil)
    }

    /// While the panel is away its window must let clicks through: the island is
    /// a hint, not a target.
    @Test("only the collapsed state lets clicks through")
    func onlyTheIslandIsClickThrough() {
        for to in PanelPhase.allCases {
            #expect(plan(ScreenFixtures.builtInNotched, from: .peek, to: to).ignoresMouseEvents == (to == .collapsed))
        }
    }

    /// Fullscreen is the one state that stays below the menu bar, so that a
    /// utility cannot become a trap.
    @Test("fullscreen is the one state that is not welded to the top edge")
    func fullscreenIsNotWelded() {
        for screen in ScreenFixtures.both {
            #expect(!plan(screen, from: .open, to: .fullscreen).weldedToTopEdge)
            #expect(plan(screen, from: .collapsed, to: .peek).weldedToTopEdge)
        }
    }
}
