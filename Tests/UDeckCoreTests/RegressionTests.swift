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
}
