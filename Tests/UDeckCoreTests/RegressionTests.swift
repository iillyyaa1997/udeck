import CoreGraphics
import Foundation
import Testing
@testable import UDeckCore

/// One test per fault that reached the operator.
///
/// Every one of these was found by him using the panel, not by the suite, and
/// each is here so that the same mistake has to get past a test next time. What
/// they have in common is worth naming: none was a wrong calculation. They were
/// all a value read in the wrong frame of reference — a coordinate against the
/// wrong window, a duration against the wrong clock, an answer computed for one
/// question and reused for another.
@Suite("Faults that reached the operator")
struct RegressionTests {
    let tuning = GestureTuning()
    let metrics = PanelMetrics()

    private func geometry(_ screen: ScreenSnapshot) -> PanelGeometry {
        PanelGeometry(screen: screen, tuning: tuning, metrics: metrics)
    }

    // MARK: - The panel slid in from the corner

    /// The fault: the panel's rectangle is expressed inside its window, and the
    /// window is the panel between transitions and a larger stage during one.
    /// Settling leaves the rectangle at the window's own origin; read against
    /// the stage that replaces it, the same numbers mean the top left corner,
    /// so every reveal after the first slid in from the side.
    ///
    /// The invariant that catches it: a rectangle in window coordinates, put
    /// back where the window is, has to land exactly where the screen geometry
    /// said the panel goes. If those two ever disagree, something is being read
    /// against the wrong window.
    @Test("a panel rect in window coordinates maps back to the same place on screen")
    func panelRectRoundTripsThroughItsWindow() {
        for screen in ScreenFixtures.both + [ScreenFixtures.offCentreNotch] {
            let g = geometry(screen)
            for phase in PanelPhase.allCases {
                let window = g.windowFrame(for: phase)
                let inWindow = g.panelRectInWindow(for: phase)
                let onScreen = g.frame(for: phase)

                // Window coordinates grow downward from the window's top edge;
                // screen coordinates grow upward from its bottom.
                let backOnScreen = CGRect(
                    x: window.minX + inWindow.minX,
                    y: window.maxY - inWindow.maxY,
                    width: inWindow.width,
                    height: inWindow.height
                )
                #expect(backOnScreen.isApproximately(onScreen, within: 0.001),
                        "\(phase) on \(screen.name): \(backOnScreen) is not \(onScreen)")
            }
        }
    }

    /// The same rule for the window the panel settles into, which is a
    /// different frame from the one it animates in — and the difference between
    /// them is exactly what went wrong.
    @Test("the settled window is the panel, so the panel sits at its origin")
    func settledWindowIsThePanel() {
        for screen in ScreenFixtures.both {
            let g = geometry(screen)
            for phase in PanelPhase.allCases {
                let settled = g.settledWindowFrame(for: phase)
                #expect(settled.isApproximately(g.frame(for: phase), within: 1),
                        "\(phase) on \(screen.name) settles to something other than the panel")
            }
        }
    }

    /// The fault: an anchor 185 points wide centred on a screen lands on a half
    /// point, so the window was never equal to the frame being asked for and
    /// was resized on every pass, with the glass edge between pixels each time.
    @Test("window frames are whole points")
    func windowFramesAreWholePoints() {
        for screen in ScreenFixtures.both + [ScreenFixtures.offCentreNotch, ScreenFixtures.offCentreNotchRight] {
            let g = geometry(screen)
            for phase in PanelPhase.allCases {
                for frame in [g.windowFrame(for: phase), g.settledWindowFrame(for: phase)] {
                    #expect(frame.minX == frame.minX.rounded(), "\(phase) on \(screen.name): x")
                    #expect(frame.minY == frame.minY.rounded(), "\(phase) on \(screen.name): y")
                    #expect(frame.width == frame.width.rounded(), "\(phase) on \(screen.name): width")
                    #expect(frame.height == frame.height.rounded(), "\(phase) on \(screen.name): height")
                }
            }
        }
    }

    /// The states a passing cursor can reach must share a window, or opening
    /// the panel reshapes it — which is where the stutter came from.
    @Test("the hover states share one window on every screen")
    func hoverStatesShareOneWindow() {
        for screen in ScreenFixtures.both + [ScreenFixtures.offCentreNotch] {
            let g = geometry(screen)
            let window = g.windowFrame(for: .collapsed)
            for phase in [PanelPhase.peek, .open] {
                #expect(g.windowFrame(for: phase) == window,
                        "\(phase) on \(screen.name) would reshape the window")
            }
        }
    }

    /// Every state has to fit in the window it is drawn in, on any screen —
    /// including the lopsided fixtures, where the clamps that keep the panel on
    /// screen actually do something.
    @Test("no state is drawn outside its own window")
    func everyStateFitsItsWindow() {
        for screen in ScreenFixtures.both + [ScreenFixtures.offCentreNotch, ScreenFixtures.offCentreNotchRight] {
            let g = geometry(screen)
            for phase in PanelPhase.allCases {
                let window = g.windowFrame(for: phase)
                let rect = g.panelRectInWindow(for: phase)
                #expect(rect.minX >= -0.001, "\(phase) on \(screen.name) starts left of its window")
                #expect(rect.minY >= -0.001, "\(phase) on \(screen.name) starts above its window")
                #expect(rect.maxX <= window.width + 0.001, "\(phase) on \(screen.name) runs past its window")
                #expect(rect.maxY <= window.height + 0.001, "\(phase) on \(screen.name) runs below its window")
            }
        }
    }

    // MARK: - The text arrived before the panel

    /// The fault: the content was sequenced against a constant while the shape
    /// was sequenced by a spring, so the two drifted apart the moment the
    /// spring was retuned. Text at full strength inside a box that is still
    /// growing reads as text overflowing a small panel.
    @Test("the content lands after the shape it is written on, not before")
    func contentLandsAfterTheShape() {
        let arrival = metrics.revealPerceivedDuration
        #expect(metrics.contentArrivalDuration >= arrival,
                "content finishes at \(metrics.contentArrivalDuration)s, shape arrives at \(arrival)s")
        // And it must not start before the shape has visibly begun to move,
        // or the two read as one thing appearing rather than as a reveal.
        #expect(metrics.contentRevealDelay > 0)
    }

    /// The rule has to hold for springs other than the shipped one, because the
    /// spring is a setting and the sequencing numbers are settings beside it.
    @Test("a slower spring is still not overtaken by its own text")
    func contentKeepsUpWithAnySpring() {
        for response in [0.28, 0.42, 0.6] {
            var m = PanelMetrics()
            m.revealSpringResponse = response
            // What the settings screen would have to do to stay honest.
            m.contentRevealDelay = m.revealPerceivedDuration * 0.7
            m.contentRevealDuration = m.revealPerceivedDuration * 0.5
            #expect(m.contentArrivalDuration >= m.revealPerceivedDuration,
                    "response \(response) leaves the text ahead of the shape")
        }
    }

    @Test("the perceived arrival is a real crossing, not a guess")
    func perceivedArrivalIsMeasured() {
        var fast = PanelMetrics(); fast.revealSpringResponse = 0.2
        var slow = PanelMetrics(); slow.revealSpringResponse = 0.8
        #expect(fast.revealPerceivedDuration < slow.revealPerceivedDuration)
        // A spring is past most of its travel well before it stops moving.
        #expect(fast.revealPerceivedDuration > 0)
        #expect(slow.revealPerceivedDuration < 5)
    }

    // MARK: - Settings files written by hand

    /// Three separate faults shared this shape: a value read from the settings
    /// file that could throw took the whole file with it, so one misspelt word
    /// cost the operator every other setting they had.
    @Test("nothing in a hand-written settings file can take the rest of it down")
    func garbageInSettingsCostsOnlyItself() throws {
        let json = Data("""
        {
          "version": 1,
          "density": "cozy",
          "ink": "chartreuse",
          "glass": { "style": "frosted", "opacity": 12, "tintStrength": -3 },
          "hotkey": { "key": "nonsense", "modifiers": [] },
          "panel": { "cornerRadius": 1e9, "islandHeightFactor": 40 },
          "gesture": { "dwellDuration": -1, "pointerPollInterval": 0 }
        }
        """.utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: json).validated()

        // The readable parts survived.
        #expect(settings.density == .cozy)
        // The unreadable ones fell back rather than throwing.
        #expect(settings.ink == .light)
        #expect(settings.glass.style == .regular)
        // And every number is back in a range that means something.
        #expect(settings.glass.opacity == 1)
        #expect(settings.glass.tintStrength >= 0)
        #expect(settings.panel.cornerRadius <= 100)
        #expect(settings.panel.islandHeightFactor <= 1)
        #expect(settings.gesture.dwellDuration > 0)
        // Zero is meaningful for the poll — it turns it off — and survives.
        #expect(settings.gesture.pointerPollInterval == 0)
        // A shortcut that cannot be registered is off rather than on and silent.
        #expect(settings.hotkey.enabled == false)
    }

    /// The island is the shape the panel grows out of, so the gesture that
    /// opens it must not get harder to make when the island gets smaller.
    @Test("the strip the gesture listens on does not follow the island's size")
    func gestureIsUnaffectedByTheIsland() {
        let screen = ScreenFixtures.externalMain
        var short = PanelMetrics(); short.islandHeightFactor = 0.2
        var tall = PanelMetrics(); tall.islandHeightFactor = 1

        let a = PanelGeometry(screen: screen, tuning: tuning, metrics: short)
        let b = PanelGeometry(screen: screen, tuning: tuning, metrics: tall)
        #expect(a.triggerStrip == b.triggerStrip)
        #expect(a.collapsedFrame.height < b.collapsedFrame.height)
        #expect(a.collapsedFrame.width == b.collapsedFrame.width)
    }

    // MARK: - The panel vanished instead of closing

    /// The fault: "nothing is drawn under a real notch" was read off the phase,
    /// and the phase changes before a single frame of the collapse has run. On
    /// the built-in display the glass was deleted at frame zero and the panel's
    /// rectangle then animated an empty region down into the notch — the
    /// operator saw the panel disappear rather than close, and only on the
    /// laptop, because a notchless screen takes the other branch and keeps
    /// drawing its island all the way down.
    ///
    /// The rule is about the collapsed state *at rest*, so the answer needs the
    /// one fact the phase cannot carry: whether the panel has arrived.
    @Test("the panel is still drawn while it is closing into a real notch")
    func collapseIntoANotchIsVisible() {
        #expect(PanelChrome.drawsMaterial(phase: .collapsed, screenHasNotch: true, isSettled: false))
        // And it goes away once it is home, which is the rule that was right.
        #expect(!PanelChrome.drawsMaterial(phase: .collapsed, screenHasNotch: true, isSettled: true))
    }

    /// A drawn island is the panel at its smallest and never stops being drawn,
    /// settled or not — this is the branch that kept working and hid the bug.
    @Test("a drawn island is there in every state of a notchless screen")
    func drawnIslandIsAlwaysDrawn() {
        for settled in [true, false] {
            #expect(PanelChrome.drawsMaterial(phase: .collapsed, screenHasNotch: false, isSettled: settled))
        }
    }

    /// Nothing about being mid-transition may take the material off a panel
    /// that is open: the notch rule is the only reason to stop drawing.
    @Test("every visible phase draws its material on every screen")
    func visiblePhasesAlwaysDraw() {
        for phase in PanelPhase.allCases where phase != .collapsed {
            for notch in [true, false] {
                for settled in [true, false] {
                    #expect(PanelChrome.drawsMaterial(
                        phase: phase, screenHasNotch: notch, isSettled: settled
                    ), "\(phase) notch=\(notch) settled=\(settled)")
                }
            }
        }
    }

    // MARK: - A default that could never reach the operator again

    /// The fault the operator felt as *nothing happening*. The reveal was
    /// retuned, shipped and confirmed green, and he saw no change at all —
    /// because `AppSettings` wrote every field on save, so the first time
    /// anything was saved the whole default set was frozen into his file and no
    /// default the code ever changed could reach that install again. His file
    /// still held `contentRevealDelay 0.08` from before the fix.
    ///
    /// The invariant: a value nobody chose is not written down.
    @Test("an untouched setting is left out of the file, so a new default can still reach it")
    func untouchedSettingsAreNotFrozenIntoTheFile() throws {
        let encoder = JSONEncoder()
        let gestureKeys = try keys(of: encoder.encode(GestureTuning()))
        #expect(gestureKeys.isEmpty, "defaults were written down: \(gestureKeys.sorted())")
        let panelKeys = try keys(of: encoder.encode(PanelMetrics()))
        #expect(panelKeys.isEmpty, "defaults were written down: \(panelKeys.sorted())")
    }

    /// The other half of the same rule: what the operator *did* choose has to
    /// survive, including a choice that happens to be slower than the default.
    @Test("a chosen setting is written down, and only that one")
    func chosenSettingsAreWritten() throws {
        var tuning = GestureTuning()
        tuning.dwellDuration = 0.5
        #expect(try keys(of: JSONEncoder().encode(tuning)) == ["dwellDuration"])

        var metrics = PanelMetrics()
        metrics.contentRevealDelay = 0.4
        #expect(try keys(of: JSONEncoder().encode(metrics)) == ["contentRevealDelay"])

        // And it comes back out as what was chosen, not as the default.
        let decoded = try JSONDecoder().decode(GestureTuning.self, from: JSONEncoder().encode(tuning))
        #expect(decoded.dwellDuration == 0.5)
        #expect(decoded == tuning)
    }

    /// A file written by an older build states every value explicitly. Those are
    /// indistinguishable from choices and must be obeyed — sparse writing fixes
    /// what happens next, it does not rewrite what is already on disk.
    @Test("a fully written older file is still obeyed to the letter")
    func anOlderFullyWrittenFileIsObeyed() throws {
        let json = Data("""
        {"dwellDuration": 0.22, "peekExitGrace": 0.25}
        """.utf8)
        let decoded = try JSONDecoder().decode(GestureTuning.self, from: json)
        #expect(decoded.dwellDuration == 0.22)
        #expect(decoded.peekExitGrace == 0.25)
        // Everything it did not mention follows the code.
        #expect(decoded.stripHeight == GestureTuning().stripHeight)
    }

    private func keys(of data: Data) throws -> Set<String> {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any] else { return [] }
        return Set(dictionary.keys)
    }

    // MARK: - A setting the operator could not reach

    /// The fault: the glass tint was clamped to 0.9 by the validator and offered
    /// to 0.6 by the slider, so a third of the range the code accepted could not
    /// be asked for from the only place the operator sets it. He found the
    /// ceiling by needing what was past it.
    ///
    /// The invariant: what the pane offers and what the code keeps are one
    /// range, named once. This test guards the naming; the pane now builds its
    /// slider from the same constant, so the two cannot drift apart again.
    @Test("what the glass validator keeps is exactly what the settings pane can offer")
    func theTintRangeIsStatedOnce() {
        for value in [GlassAppearance.tintStrengthRange.lowerBound,
                      GlassAppearance.tintStrengthRange.upperBound] {
            var glass = GlassAppearance()
            glass.tintStrength = value
            #expect(glass.validated().tintStrength == value,
                    "the pane can ask for \(value) and the validator throws it away")
        }
        for value in [GlassAppearance.opacityRange.lowerBound,
                      GlassAppearance.opacityRange.upperBound] {
            var glass = GlassAppearance()
            glass.opacity = value
            #expect(glass.validated().opacity == value)
        }
        // And past the ends it still clamps rather than obeying a hand-written
        // file to the letter.
        var beyond = GlassAppearance()
        beyond.tintStrength = GlassAppearance.tintStrengthRange.upperBound + 1
        #expect(beyond.validated().tintStrength == GlassAppearance.tintStrengthRange.upperBound)
    }
    // MARK: - A dash that appeared mid-screen and rode up

    /// The fault: the island's mark is centred in whatever rectangle the panel
    /// currently occupies, and the collapsed state's content was swapped in the
    /// instant the collapse was decided. With the panel still at full size the
    /// bar appeared in the middle of the screen and travelled up to the top as
    /// the shape shrank under it — "эта тире появляется по центру и уезжает
    /// вверх".
    ///
    /// A mark means "the panel is away". During a collapse it is not away yet.
    @Test("the island's mark waits for the panel to arrive")
    func islandMarkWaitsForTheCollapseToFinish() {
        #expect(!PanelChrome.drawsIslandMark(phase: .collapsed, screenHasNotch: false, isSettled: false))
        #expect(PanelChrome.drawsIslandMark(phase: .collapsed, screenHasNotch: false, isSettled: true))
    }

    /// Under a real notch there is no drawn island, so there is nothing to put a
    /// mark on — settled or not.
    @Test("a real notch carries no mark of ours")
    func noMarkUnderARealNotch() {
        for settled in [true, false] {
            #expect(!PanelChrome.drawsIslandMark(phase: .collapsed, screenHasNotch: true, isSettled: settled))
        }
    }

    /// And no other state has one: the mark belongs to the panel being away.
    @Test("only the collapsed state carries the mark")
    func onlyTheIslandCarriesTheMark() {
        for phase in PanelPhase.allCases where phase != .collapsed {
            #expect(!PanelChrome.drawsIslandMark(phase: phase, screenHasNotch: false, isSettled: true))
        }
    }
}
