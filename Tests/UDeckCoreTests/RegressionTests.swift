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
    ///
    /// It holds for a *visible* panel. The collapsed state settles onto the
    /// stage instead: its window is click-through in its entirety, so shrinking
    /// it to the island protects nothing, and leaving it means the next reveal
    /// does not have to resize a window at the instant a spring starts running.
    @Test("a visible panel's settled window is the panel, so it sits at its origin")
    func settledWindowIsThePanel() {
        for screen in ScreenFixtures.both {
            let g = geometry(screen)
            for phase in PanelPhase.allCases where phase != .collapsed {
                let settled = g.settledWindowFrame(for: phase)
                #expect(settled.isApproximately(g.frame(for: phase), within: 1),
                        "\(phase) on \(screen.name) settles to something other than the panel")
            }
        }
    }

    /// The fault: the panel appeared already part-way open. The window was
    /// brought down to the island whenever the panel went away, so every reveal
    /// began by resizing it from the island to the stage — two orders of
    /// magnitude of area — at the exact moment a time-based spring started. The
    /// compositor rebuilt the glass for the new size, the first frames went
    /// missing, and the spring was already part-way through when the panel next
    /// appeared: "резко появляется, как будто анимация начинается с середины".
    ///
    /// The invariant: going away and coming back must not move the window.
    @Test("a reveal does not have to resize the window before it can animate")
    func revealNeedsNoWindowResize() {
        for screen in ScreenFixtures.both {
            let g = geometry(screen)
            let away = g.settledWindowFrame(for: .collapsed)
            for phase in [PanelPhase.peek, .open] {
                #expect(away == g.windowFrame(for: phase),
                        "\(screen.name): revealing \(phase) has to resize the window from \(away)")
            }
            // And the panel's own rectangle inside that window is still the
            // island's place on screen, not the whole window.
            let mark = g.panelRect(for: .collapsed, inWindow: away)
            #expect(mark.width < away.width, "the island filled its whole window")
            #expect(mark.size.width == g.frame(for: .collapsed).width)
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
        #expect(settings.ink == AppSettings().ink)
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

    /// The fault: the mark was the collapsed state's content, swapped in the
    /// instant a collapse was decided. It is centred in whatever rectangle the
    /// panel occupies, so with the panel still at full size it appeared in the
    /// middle of the screen and travelled up as the shape shrank under it —
    /// "эта тире появляется по центру и уезжает вверх".
    ///
    /// The operator's answer was better than waiting for the arrival: carry the
    /// mark on the panel's bottom edge in every state, so a collapse takes it
    /// down into the island rather than replacing one thing with another. That
    /// leaves no question of when to show it — it is shown wherever the surface
    /// it is drawn on is shown.
    @Test("the mark is drawn exactly where the panel's material is")
    func theMarkFollowsTheMaterial() {
        for phase in PanelPhase.allCases {
            for notch in [true, false] {
                for settled in [true, false] {
                    #expect(
                        PanelChrome.drawsIslandMark(phase: phase, screenHasNotch: notch, isSettled: settled)
                            == PanelChrome.drawsMaterial(phase: phase, screenHasNotch: notch, isSettled: settled),
                        "\(phase) notch=\(notch) settled=\(settled): the mark and its surface disagree"
                    )
                }
            }
        }
    }

    /// The whole point of the change: the mark exists while the panel is open,
    /// so that what shrinks into the island is the thing the operator was
    /// already looking at.
    @Test("the mark is there in the states the panel is open in")
    func theMarkIsCarriedByTheOpenPanel() {
        for phase in PanelPhase.allCases where phase != .collapsed {
            for notch in [true, false] {
                #expect(PanelChrome.drawsIslandMark(phase: phase, screenHasNotch: notch, isSettled: true))
            }
        }
    }

    /// And it rides the collapse the whole way, on either kind of screen —
    /// including the notched one, where what it is riding into is hardware.
    @Test("the mark is still there while the panel is closing")
    func theMarkRidesTheCollapse() {
        for notch in [true, false] {
            #expect(PanelChrome.drawsIslandMark(phase: .collapsed, screenHasNotch: notch, isSettled: false))
        }
        // Arrived under a real notch, there is nothing drawn to carry it.
        #expect(!PanelChrome.drawsIslandMark(phase: .collapsed, screenHasNotch: true, isSettled: true))
        // Arrived on a drawn island, the mark is what the island says.
        #expect(PanelChrome.drawsIslandMark(phase: .collapsed, screenHasNotch: false, isSettled: true))
    }

    // MARK: - Two looks and something that decides between them

    /// The operator's own framing, and it is the right one: the panel has a
    /// light look and a dark look, and a separate question of which is in force.
    /// Everything that draws reads the resolved pair, so this is the whole of
    /// "which look is showing".
    @Test("the source decides which look is in force, and nothing else does")
    func theSourceDecides() {
        var theme = ThemeSettings()

        theme.source = .system
        #expect(theme.isDark(systemIsDark: true, hour: 3) == true)
        #expect(theme.isDark(systemIsDark: false, hour: 3) == false)

        theme.source = .manual
        theme.manualIsDark = true
        #expect(theme.isDark(systemIsDark: false, hour: 12) == true,
                "manual must ignore a light system")
        theme.manualIsDark = false
        #expect(theme.isDark(systemIsDark: true, hour: 2) == false,
                "manual must ignore a dark system")

        theme.source = .schedule
        #expect(theme.isDark(systemIsDark: false, hour: 12) == false)
        #expect(theme.isDark(systemIsDark: true, hour: 23) == true,
                "the clock must ignore the system too")
    }

    /// The dark half of a day wraps past midnight, which is why this is not a
    /// comparison between two numbers.
    @Test("a schedule that crosses midnight is still a schedule")
    func scheduleWrapsPastMidnight() {
        let schedule = ThemeSchedule(lightFromHour: 7, darkFromHour: 19)
        for hour in 7 ..< 19 {
            #expect(!schedule.isDark(atHour: hour), "\(hour):00 should be light")
        }
        for hour in [19, 22, 23, 0, 3, 6] {
            #expect(schedule.isDark(atHour: hour), "\(hour):00 should be dark")
        }
        // And an hour outside the day still lands somewhere sensible rather
        // than throwing or reading off the end.
        #expect(schedule.isDark(atHour: 24) == schedule.isDark(atHour: 0))
        #expect(schedule.isDark(atHour: -1) == schedule.isDark(atHour: 23))
    }

    /// Resolving is the only thing that writes the pair everything draws from,
    /// so it has to produce exactly the look the source names.
    @Test("resolving puts the named look where the drawing code reads it")
    func resolvingWritesTheLookThatDraws() {
        var settings = AppSettings()
        settings.theme.source = .manual
        settings.theme.manualIsDark = true
        let dark = settings.resolved(systemIsDark: false, hour: 12)
        #expect(dark.glass == settings.theme.dark.glass)
        #expect(dark.ink == settings.theme.dark.ink)

        settings.theme.manualIsDark = false
        let light = settings.resolved(systemIsDark: true, hour: 2)
        #expect(light.glass == settings.theme.light.glass)
        #expect(light.ink == settings.theme.light.ink)
    }

    /// A look chosen before there were two of them is a real choice and has to
    /// survive: it becomes the pole its ink belongs to, pinned, so nothing
    /// changes under the operator until he asks it to.
    @Test("a settings file older than the two looks keeps the look it had")
    func anOlderFileKeepsItsLook() throws {
        let json = Data("""
        {"glass": {"tintStrength": 0.72, "tintIsLight": true}, "ink": "dark"}
        """.utf8)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: json).validated()
        #expect(decoded.theme.source == .manual)
        #expect(decoded.theme.manualIsDark == false, "dark ink means the light look")
        #expect(decoded.theme.light.glass.tintStrength == 0.72)
        #expect(decoded.theme.light.ink == .dark)
        // And it is what resolves, whatever the system says.
        let resolved = decoded.resolved(systemIsDark: true, hour: 3)
        #expect(resolved.glass.tintStrength == 0.72)
        #expect(resolved.ink == .dark)
    }

    /// The other half of the same rule: a file whose panel was dark keeps that
    /// as the dark look and gets the shipped light one for free.
    @Test("an older dark file becomes the dark look, pinned")
    func anOlderDarkFileBecomesTheDarkLook() throws {
        let json = Data("""
        {"glass": {"tintStrength": 0.4, "tintIsLight": false}, "ink": "light"}
        """.utf8)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: json).validated()
        #expect(decoded.theme.manualIsDark == true)
        #expect(decoded.theme.dark.glass.tintStrength == 0.4)
        #expect(decoded.theme.light == PanelLook.light, "the pole he never set ships as it ships")
    }

    // MARK: - Presets the operator makes himself

    /// Saving captures the look being edited exactly, and a name already in use
    /// replaces what was under it — two identical names in a list you pick from
    /// is a list you cannot pick from.
    @Test("saving a look keeps it, and the same name overwrites rather than doubles")
    func savingAPreset() {
        var theme = ThemeSettings()
        theme.dark.glass.tintStrength = 0.42
        theme.save(forDark: true, as: "  Night  ")

        #expect(theme.saved.count == 1)
        #expect(theme.saved[0].name == "Night", "the name is what is left after a person stops typing")
        #expect(theme.saved[0].look.glass.tintStrength == 0.42)

        theme.dark.glass.tintStrength = 0.7
        theme.save(forDark: true, as: "night")
        #expect(theme.saved.count == 1, "the same name, however typed, is the same preset")
        #expect(theme.saved[0].look.glass.tintStrength == 0.7)

        theme.save(forDark: true, as: "Another")
        #expect(theme.saved.count == 2)
    }

    /// A name that is only whitespace is not a name, and saving under it must
    /// not leave an unpickable row in the list.
    @Test("a preset with no name is not saved")
    func anEmptyNameSavesNothing() {
        var theme = ThemeSettings()
        #expect(theme.save(forDark: false, as: "   ") == nil)
        #expect(theme.saved.isEmpty)
    }

    /// Using one pours it into whichever pole is being edited, and only that one.
    @Test("using a preset changes the look it was poured into, and no other")
    func applyingAPreset() {
        var theme = ThemeSettings()
        let light = theme.light
        theme.dark.glass.tintStrength = 0.42
        guard let preset = theme.save(forDark: true, as: "Night") else {
            Issue.record("nothing saved"); return
        }
        theme.dark = .dark
        theme.apply(preset, forDark: true)
        #expect(theme.dark.glass.tintStrength == 0.42)
        #expect(theme.light == light, "the other pole is not touched")
    }

    /// The whole point of these being data rather than code: they outlive the
    /// build, which means the settings file.
    @Test("saved presets survive a round trip through the settings file")
    func presetsRoundTrip() throws {
        var settings = AppSettings()
        settings.theme.dark.glass.tintStrength = 0.31
        settings.theme.save(forDark: true, as: "Night")

        let data = try JSONEncoder().encode(settings)
        let back = try JSONDecoder().decode(AppSettings.self, from: data).validated()
        #expect(back.theme.saved.count == 1)
        #expect(back.theme.saved[0].name == "Night")
        #expect(back.theme.saved[0].look.glass.tintStrength == 0.31)
        #expect(back.theme.saved[0].id == settings.theme.saved[0].id, "the same preset, not a copy")
    }

    /// Validation is where a hand-edited file gets brought back into line, and
    /// a nameless preset is exactly what a hand-edited file produces.
    @Test("a hand-written preset with no name is dropped rather than shown blank")
    func namelessPresetsAreDropped() throws {
        let json = Data("""
        {"theme": {"saved": [{"name": "  ", "look": {}}, {"name": "Real", "look": {}}]}}
        """.utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: json).validated()
        #expect(settings.theme.saved.map(\.name) == ["Real"])
    }

    /// The six that ship are still six, and each is a look of its own — a
    /// preset list with two identical entries in it is a list with a mistake.
    @Test("the built-in presets are all different from one another")
    func builtInPresetsAreDistinct() {
        let looks = PanelMode.allCases.map(\.look)
        #expect(Set(PanelMode.allCases.map(\.name)).count == PanelMode.allCases.count)
        for (i, a) in looks.enumerated() {
            for b in looks[(i + 1)...] {
                #expect(a != b, "two presets ship as the same look")
            }
        }
        // And every one of them writes its text the way its own glass demands.
        for mode in PanelMode.allCases {
            let wantsDarkInk = mode.glass.tintIsLight && mode.glass.tintStrength > 0.5
            #expect((mode.ink == .dark) == wantsDarkInk,
                    "\(mode.name) writes in the wrong ink for its own glass")
        }
    }

    // MARK: - How bright the text is, and what colour

    /// Full brightness has to land exactly on what the panel had before any of
    /// this was a setting, or every look anyone already saved changes under him.
    @Test("full brightness is the ink the panel always had")
    func fullBrightnessIsUnchanged() {
        var light = PanelLook(glass: GlassAppearance(), ink: .light)
        #expect(light.foreground == InkColor.white)
        light.inkBrightness = 1
        #expect(light.foreground == InkColor.white)

        let dark = PanelLook(glass: GlassAppearance(), ink: .dark)
        #expect(dark.foreground == InkColor.black)
    }

    /// Turning it down walks the text towards the panel it is written on, from
    /// whichever end it started at.
    @Test("dimming walks the text towards the panel, from either end")
    func dimmingWalksTowardsThePanel() {
        var light = PanelLook(glass: GlassAppearance(), ink: .light)
        light.inkBrightness = 0
        #expect(light.foreground.luminance < InkColor.white.luminance,
                "light text dims by getting darker")
        #expect(light.foreground.luminance > 0.2, "and not by disappearing")

        var dark = PanelLook(glass: GlassAppearance(), ink: .dark)
        dark.inkBrightness = 0
        #expect(dark.foreground.luminance > InkColor.black.luminance,
                "dark text dims by getting lighter")
        #expect(dark.foreground.luminance < 0.8, "and not by disappearing")

        // Monotonic in between, or the slider does not mean what it looks like.
        var previous = -1.0
        for step in stride(from: 0.0, through: 1.0, by: 0.1) {
            var look = PanelLook(glass: GlassAppearance(), ink: .light)
            look.inkBrightness = step
            #expect(look.foreground.luminance > previous, "brightness \(step) is not brighter than the step before")
            previous = look.foreground.luminance
        }
    }

    /// A colour is the ink, and brightness works on it the same way it works on
    /// grey — one number does both, which is what makes the two controls one
    /// idea rather than two that interfere.
    @Test("a coloured ink dims the same way a grey one does")
    func colouredInkDimsLikeGrey() {
        var look = PanelLook(glass: GlassAppearance(), ink: .light)
        look.inkColor = InkColor(red: 0.4, green: 0.9, blue: 0.5)
        #expect(look.foreground == InkColor(red: 0.4, green: 0.9, blue: 0.5),
                "at full brightness the colour is the colour")

        look.inkBrightness = 0.5
        let dimmed = look.foreground
        #expect(dimmed.luminance < 0.9 * 0.7)
        // The hue survives dimming: the ratios between the channels hold.
        #expect(abs(dimmed.green / dimmed.red - 0.9 / 0.4) < 0.001)
    }

    /// Nonsense from a hand-written file is brought back into range rather than
    /// producing text nobody can see.
    @Test("an impossible brightness or colour is clamped, not obeyed")
    func inkIsValidated() throws {
        let json = Data("""
        {"theme": {"light": {"inkBrightness": 4, "inkColor": {"red": -1, "green": 2, "blue": 0.5}}}}
        """.utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: json).validated()
        #expect(settings.theme.light.inkBrightness == 1)
        #expect(settings.theme.light.inkColor == InkColor(red: 0, green: 1, blue: 0.5))

        var look = PanelLook()
        look.inkBrightness = .nan
        #expect(look.validated().inkBrightness == 1)
    }

    /// And it survives the settings file, which is the only reason it is data.
    @Test("brightness and colour survive a round trip")
    func inkRoundTrips() throws {
        var settings = AppSettings()
        settings.theme.dark.inkBrightness = 0.42
        settings.theme.dark.inkColor = InkColor(red: 0.2, green: 0.8, blue: 0.3)
        let back = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(back.theme.dark.inkBrightness == 0.42)
        #expect(back.theme.dark.inkColor == InkColor(red: 0.2, green: 0.8, blue: 0.3))
    }

    // MARK: - The colours came apart again

    /// The fault, twice: the peek was one colour and the open panel another.
    ///
    /// The first time it was blamed on the tint, and painting the tint ourselves
    /// did hide it — in proportion to the tint's own strength, which is why it
    /// came back the moment the operator turned the tint down. The cause was
    /// never the tint. `NSGlassEffectView` renders differently depending on how
    /// big it is: measured on the running panel at one tint, a 96-point peek
    /// came out at 66/255 and a 300-point one at 56, with nothing else changed.
    ///
    /// The fix is that the material is drawn at the size of the stage and cut
    /// to the shape of the panel, so its bounds never change and it cannot
    /// render two ways. What this test can hold is the half of that which lives
    /// in Core: the stage really is one size for every state the panel is drawn
    /// in. (Re-measured after the change: 55.9 at peek heights of 96, 300 and
    /// 600 — the same number three times.)
    @Test("the stage is one size, so anything drawn at stage size is too")
    func theStageDoesNotChangeWithThePhase() {
        for screen in ScreenFixtures.both + [ScreenFixtures.offCentreNotch] {
            let g = PanelGeometry(screen: screen, tuning: tuning, metrics: metrics)
            let stage = g.windowFrame(for: .collapsed)
            for phase in [PanelPhase.peek, .open] {
                #expect(g.windowFrame(for: phase) == stage,
                        "\(phase) on \(screen.name) is staged at a different size from collapsed")
            }
            // Fullscreen is the one that is larger than the stage, and the one
            // state that is a deliberate click rather than a brush of the
            // cursor — so its material is allowed to be its own.
            #expect(g.windowFrame(for: .fullscreen) != stage)
        }
    }

    /// The tint reaches all the way, because "all the way" is the only setting
    /// that makes two states of the panel provably the same colour: glass shows
    /// what is behind it, and the small panel and the large one are over
    /// different parts of the screen.
    @Test("the tint can be asked for all the way, and the pane can ask for it")
    func theTintReachesOpaque() {
        #expect(GlassAppearance.tintStrengthRange.upperBound == 1)
        var glass = GlassAppearance()
        glass.tintStrength = 1
        #expect(glass.validated().tintStrength == 1, "the validator must keep what the pane can offer")
        #expect(glass.tintComponents?.alpha == 1)
    }
}
