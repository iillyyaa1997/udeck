import CoreGraphics
import Foundation
import Testing
@testable import UDeckCore

@Suite("Screen geometry")
struct ScreenGeometryTests {
    @Test("a notch is the gap between the two unobscured wings")
    func notchDerivedFromWings() {
        let notch = ScreenFixtures.builtInNotched.notchRect
        #expect(notch != nil)
        #expect(notch?.minX == -957)
        #expect(notch?.maxX == -772)
        #expect(notch?.width == 185)
        #expect(notch?.height == 32)
        // The notch hangs from the very top of the screen.
        #expect(notch?.maxY == ScreenFixtures.builtInNotched.frame.maxY)
    }

    @Test("a screen without wings has no notch")
    func noNotchWithoutWings() {
        #expect(ScreenFixtures.externalMain.notchRect == nil)
        #expect(ScreenFixtures.externalMain.hasNotch == false)
    }

    @Test("a reported safe area with no wings still yields no notch to anchor to")
    func safeAreaWithoutWings() {
        var screen = ScreenFixtures.externalMain
        screen = ScreenSnapshot(
            id: screen.id, name: screen.name, frame: screen.frame,
            visibleFrame: screen.visibleFrame, backingScale: screen.backingScale,
            safeAreaTop: 40, auxiliaryTopLeft: nil, auxiliaryTopRight: nil
        )
        #expect(screen.notchRect == nil)
        // …but the space is still reserved: the panel must hang below it.
        #expect(screen.topInset == 40)
    }

    @Test("the panel hangs below whichever is deeper, menu bar or notch")
    func topInsetTakesTheDeeper() {
        // Dell: no notch, 30pt menu bar.
        #expect(ScreenFixtures.externalMain.topInset == 30)
        #expect(ScreenFixtures.externalMain.panelTopY == 1410)
        // Built-in: 32pt notch and a 32pt menu bar.
        #expect(ScreenFixtures.builtInNotched.topInset == 32)
        // 970 - 32 = 938, which is exactly the bottom edge of the notch.
        #expect(ScreenFixtures.builtInNotched.panelTopY == 938)
        #expect(ScreenFixtures.builtInNotched.panelTopY == ScreenFixtures.builtInNotched.notchRect?.minY)
    }

    @Test("the cursor is attributed to the screen it is on")
    func screenSelection() {
        let screens = ScreenFixtures.both
        #expect(screens.screen(containing: CGPoint(x: 1280, y: 1439))?.id == "dell")
        #expect(screens.screen(containing: CGPoint(x: -860, y: 960))?.id == "builtin")
    }

    @Test("a point in the gap between displays falls to the nearest screen rather than nowhere")
    func screenSelectionInGap() {
        // Above the built-in's top edge but left of the Dell: inside neither.
        let screens = ScreenFixtures.both
        let orphan = CGPoint(x: -800, y: 1200)
        #expect(screens.first(where: { $0.contains(orphan) }) == nil)
        #expect(screens.screen(containing: orphan)?.id == "builtin")
    }

    @Test("adjacent screens never both claim the same point")
    func noDoubleClaim() {
        // The Dell starts at x = 0; the built-in ends at x = 0.
        let seam = CGPoint(x: 0, y: 500)
        let claimants = ScreenFixtures.both.filter { $0.contains(seam) }
        #expect(claimants.count == 1)
        #expect(claimants.first?.id == "dell")
    }
}

@Suite("Panel geometry")
struct PanelGeometryTests {
    let tuning = GestureTuning()
    let metrics = PanelMetrics()

    func geometry(_ screen: ScreenSnapshot) -> PanelGeometry {
        PanelGeometry(screen: screen, tuning: tuning, metrics: metrics)
    }

    @Test("on a notched screen the anchor is the notch itself")
    func anchorIsTheNotch() {
        let anchor = geometry(ScreenFixtures.builtInNotched).anchor
        #expect(anchor == ScreenFixtures.builtInNotched.notchRect)
    }

    @Test("on a notchless screen the anchor is a virtual notch at the top centre")
    func virtualAnchor() {
        let anchor = geometry(ScreenFixtures.externalMain).anchor
        #expect(anchor.width == tuning.virtualAnchorWidth)
        #expect(anchor.midX == 1280)
        #expect(anchor.maxY == 1440)
    }

    @Test("the trigger strip straddles the anchor and hugs the very top edge")
    func triggerStrip() {
        let strip = geometry(ScreenFixtures.builtInNotched).triggerStrip
        #expect(strip.width == 185 + 2 * tuning.stripSideMargin)
        #expect(strip.midX == -864.5)
        #expect(strip.maxY == 970)
        #expect(strip.height == tuning.stripHeight)
    }

    @Test("the strip never runs off the side of the screen")
    func stripClampedToScreen() {
        // A very wide side margin would otherwise push the strip out of bounds.
        var wide = tuning
        wide.stripSideMargin = 5000
        let strip = PanelGeometry(screen: ScreenFixtures.builtInNotched, tuning: wide, metrics: metrics).triggerStrip
        #expect(strip.minX >= ScreenFixtures.builtInNotched.frame.minX)
        #expect(strip.maxX <= ScreenFixtures.builtInNotched.frame.maxX)
    }

    /// The rule the panel used to follow was "never reach into the menu bar at
    /// all". It was narrowed on purpose: the island is the shape the panel
    /// grows out of, and an island that stops one menu bar short of the top
    /// edge is a window near the corner, not part of the machine. What survives
    /// is the part that mattered — nothing *readable* is put where the menu bar
    /// is, and the menu bar never becomes unreachable.
    /// `.collapsed` is deliberately absent: the island is *supposed* to occupy
    /// the menu-bar row, that is the whole point of it, and it carries a three
    /// point bar rather than anything anyone has to read. Its shape is pinned
    /// by `collapsedShapeFollowsTheHardware` instead.
    @Test("panel content always clears the menu bar, whatever the window does")
    func contentClearsTheMenuBar() {
        for screen in ScreenFixtures.both {
            let g = geometry(screen)
            for phase in [PanelPhase.peek, .open, .fullscreen] {
                let contentTop = g.frame(for: phase).maxY - g.topOverhang
                #expect(contentTop <= screen.panelTopY,
                        "\(phase) on \(screen.name) puts content in the menu bar")
            }
        }
    }

    /// Both screens now weld. The panel used to stop below the notch on the
    /// built-in display, which left a band of menu bar above it — the operator
    /// looked at that and called it ugly, and it is: a panel that is supposed
    /// to grow out of the notch was visibly detached from it. The notch takes a
    /// bite out of the panel's top edge instead, which is the machine doing it.
    @Test("every screen welds the panel to its top edge")
    func everyScreenWelds() {
        for screen in ScreenFixtures.both {
            let g = geometry(screen)
            #expect(g.topOverhang == screen.topInset + metrics.topEdgeBleed)
            for phase in [PanelPhase.peek, .open] {
                let frame = g.frame(for: phase)
                #expect(frame.maxY == screen.frame.maxY + metrics.topEdgeBleed,
                        "\(phase) on \(screen.name) should reach past the top edge")
                // The bleed is off the display, not a gap above the panel.
                #expect(min(frame.maxY, screen.frame.maxY) == screen.frame.maxY)
            }
        }
    }

    @Test("fullscreen never takes the menu bar, on any screen")
    func fullscreenLeavesTheMenuBarAlone() {
        // The hover states are a strip in the middle, with the app menus and the
        // status items reachable either side. Fullscreen is the whole width, so
        // covering the menu bar there would leave no way back out of it.
        for screen in ScreenFixtures.both {
            let g = geometry(screen)
            #expect(g.fullscreenFrame.maxY <= screen.panelTopY)
        }
    }

    @Test("the hover states leave both ends of the menu bar reachable")
    func hoverStatesDoNotSpanTheMenuBar() {
        let screen = ScreenFixtures.externalMain
        let g = geometry(screen)
        for phase in [PanelPhase.collapsed, .peek, .open] {
            let frame = g.frame(for: phase)
            #expect(frame.minX > screen.frame.minX + 200,
                    "\(phase) reaches the app menus on the left")
            #expect(frame.maxX < screen.frame.maxX - 200,
                    "\(phase) reaches the status items on the right")
        }
    }

    @Test("the collapsed state is the island where there is no notch, and nothing where there is")
    func collapsedShapeFollowsTheHardware() {
        let dell = geometry(ScreenFixtures.externalMain)
        #expect(dell.collapsedFrame.minY == dell.anchor.minY)
        #expect(dell.collapsedFrame.width == dell.anchor.width)
        // The visible island is the anchor; the extra height is off the display.
        #expect(dell.collapsedFrame.height == ScreenFixtures.externalMain.topInset + metrics.topEdgeBleed)
        #expect(dell.collapsedFrame.width == tuning.virtualAnchorWidth)

        // Nothing hangs under a real notch. The frame is the notch itself, so
        // the window sits behind the camera housing rather than below it, and
        // nothing protrudes into the screen.
        let builtIn = geometry(ScreenFixtures.builtInNotched)
        #expect(builtIn.collapsedFrame == builtIn.anchor)
        #expect(builtIn.collapsedFrame == ScreenFixtures.builtInNotched.notchRect)
        #expect(builtIn.collapsedFrame.minY >= ScreenFixtures.builtInNotched.panelTopY,
                "nothing may hang below the notch")
    }

    @Test("the panel is centred on the anchor and stays inside the screen")
    func panelCentredAndClamped() {
        for screen in ScreenFixtures.both {
            let g = geometry(screen)
            let open = g.openFrame
            #expect(abs(open.midX - g.anchor.midX) < 0.001)
            #expect(open.minX >= screen.frame.minX)
            #expect(open.maxX <= screen.frame.maxX)
        }
    }

    @Test("a panel wider than the screen is narrowed rather than allowed to overhang")
    func panelNarrowerThanScreen() {
        var huge = metrics
        huge.openMaxWidth = 99_999
        huge.openWidthFraction = 4
        let g = PanelGeometry(screen: ScreenFixtures.builtInNotched, tuning: tuning, metrics: huge)
        #expect(g.openFrame.width == ScreenFixtures.builtInNotched.frame.width)
        #expect(g.openFrame.minX == ScreenFixtures.builtInNotched.frame.minX)
    }

    @Test("fullscreen fills the working area without covering the Dock")
    func fullscreenRespectsTheDock() {
        var docked = ScreenFixtures.externalMain
        docked = ScreenSnapshot(
            id: docked.id, name: docked.name, frame: docked.frame,
            visibleFrame: CGRect(x: 0, y: 70, width: 2560, height: 1340),
            backingScale: 1, safeAreaTop: 0, auxiliaryTopLeft: nil, auxiliaryTopRight: nil
        )
        let full = geometry(docked).fullscreenFrame
        #expect(full.minY == 70)
        #expect(full.maxY == docked.panelTopY)
    }

    @Test("the pinned test tolerates the one-point clamp macOS applies")
    func pinnedDetection() {
        let g = geometry(ScreenFixtures.externalMain)
        #expect(g.isPinnedToTopEdge(CGPoint(x: 1280, y: 1439)))
        #expect(g.isPinnedToTopEdge(CGPoint(x: 1280, y: 1437)))
        #expect(!g.isPinnedToTopEdge(CGPoint(x: 1280, y: 1430)))
    }

    /// Both real screens put the notch within half a point of their centre, so
    /// every other test here would pass just as happily against a panel centred
    /// on the screen rather than on the notch — and "the notch is the anchor"
    /// is the decision the whole design rests on. This fixture is the only one
    /// where the two rules disagree.
    @Test("the panel follows the notch, not the middle of the screen")
    func panelFollowsTheNotchNotTheCentre() {
        let screen = ScreenFixtures.offCentreNotch
        let g = PanelGeometry(screen: screen, tuning: tuning, metrics: metrics)

        let notchCentre = screen.notchRect!.midX
        #expect(abs(notchCentre - screen.frame.midX) > 100, "the fixture must actually be lopsided")

        #expect(abs(g.anchor.midX - notchCentre) < 0.001)
        #expect(abs(g.collapsedFrame.midX - notchCentre) < 0.001)
        #expect(abs(g.peekFrame.midX - notchCentre) < 0.001)
        #expect(abs(g.triggerStrip.midX - notchCentre) < 0.001)

        // …and none of them are at the screen's centre, which is the rule that
        // would otherwise pass every test in this file.
        #expect(abs(g.collapsedFrame.midX - screen.frame.midX) > 100)
        #expect(abs(g.triggerStrip.midX - screen.frame.midX) > 100)
    }

    /// The two clamps that keep the panel on the screen are separate branches,
    /// and with a centred notch neither of them can ever run: a panel centred
    /// on the middle of a screen never wants to hang off either edge. They had
    /// been read and never executed.
    @Test("a wide panel beside an off-centre notch is clamped to the edge it would overhang",
          arguments: [ScreenFixtures.offCentreNotch, ScreenFixtures.offCentreNotchRight])
    func offCentreClampingActuallyFires(_ screen: ScreenSnapshot) {
        var wide = metrics
        wide.openWidthFraction = 0.95
        wide.openMaxWidth = 5000

        let geometry = PanelGeometry(screen: screen, tuning: tuning, metrics: wide)
        let frame = geometry.openFrame

        #expect(frame.minX >= screen.frame.minX)
        #expect(frame.maxX <= screen.frame.maxX)
        // The clamp must actually have fired, not merely have been in range:
        // an unclamped panel centred on this notch would run off the screen.
        let unclamped = geometry.anchor.midX - frame.width / 2
        #expect(unclamped < screen.frame.minX || unclamped + frame.width > screen.frame.maxX,
                "the fixture is not lopsided enough to reach a clamp")
        #expect(frame.minX == screen.frame.minX || frame.maxX == screen.frame.maxX,
                "the panel should be sitting flush against the edge it would have overhung")
    }

    /// The strip has its own clamps, for the same reason and never run for the
    /// same reason.
    @Test("a strip beside an edge-hugging notch is clamped to the screen")
    func stripClampingActuallyFires() {
        var wide = tuning
        wide.stripSideMargin = 600
        for screen in [ScreenFixtures.offCentreNotch, ScreenFixtures.offCentreNotchRight] {
            let strip = PanelGeometry(screen: screen, tuning: wide, metrics: metrics).triggerStrip
            #expect(strip.minX >= screen.frame.minX)
            #expect(strip.maxX <= screen.frame.maxX)
            #expect(strip.minX == screen.frame.minX || strip.maxX == screen.frame.maxX,
                    "with a 600pt margin either side, the strip must reach an edge")
            #expect(strip.width > 0)
        }
    }

    @Test("the keep-alive region is the panel, inflated — not the trigger strip")
    func keepAliveIsThePanel() {
        let g = geometry(ScreenFixtures.externalMain)
        let region = g.keepAliveRegion(for: .open)
        #expect(region.contains(CGPoint(x: g.openFrame.midX, y: g.openFrame.minY - 10)))
        #expect(!region.contains(CGPoint(x: g.openFrame.midX, y: g.openFrame.minY - 100)))
        // The oscillation bug this prevents: the strip is a tiny sliver, so a
        // cursor inside the open panel is outside the strip almost everywhere.
        #expect(!g.triggerStrip.contains(CGPoint(x: g.openFrame.midX, y: g.openFrame.midY)))
    }

    /// Every test below pins the same rule from a different side: a cursor
    /// sitting on the screen's own top edge is *on* the screen. Measured, not
    /// assumed — `CGWarpMouseCursorPosition` to the top of the display leaves
    /// `NSEvent.mouseLocation` reporting `frame.maxY` exactly, and with the old
    /// `CGRect.contains` the panel would not open there at all.
    @Test("the very top row of the screen is inside the trigger strip")
    func topRowIsInsideTheStrip() {
        for screen in [ScreenFixtures.externalMain, ScreenFixtures.builtInNotched, ScreenFixtures.offCentreNotch] {
            let g = geometry(screen)
            let onTheEdge = CGPoint(x: g.triggerStrip.midX, y: screen.frame.maxY)
            #expect(g.containsPointer(onTheEdge, in: g.triggerStrip),
                    "a cursor on the top edge of \(screen.name) must arm the gesture")
            // The whole point of the helper: the stdlib rule says otherwise.
            #expect(!g.triggerStrip.contains(onTheEdge))
        }
    }

    @Test("the very top row of the screen keeps an open panel alive")
    func topRowKeepsThePanelAlive() {
        for screen in ScreenFixtures.both {
            let g = geometry(screen)
            for phase in [PanelPhase.peek, .open] {
                let region = g.keepAliveRegion(for: phase)
                let onTheEdge = CGPoint(x: region.midX, y: screen.frame.maxY)
                #expect(g.containsPointer(onTheEdge, in: region),
                        "\(phase) on \(screen.name) closes under a cursor that never left")
            }
        }
    }

    @Test("closing the top edge does not open any of the other three")
    func onlyTheTopEdgeIsClosed() {
        let screen = ScreenFixtures.externalMain
        let g = geometry(screen)
        let strip = g.triggerStrip
        // Below the strip: still outside, or the strip would be taller than it says.
        #expect(!g.containsPointer(CGPoint(x: strip.midX, y: strip.minY - 0.5), in: strip))
        // Right edge stays half-open, so two side-by-side screens cannot both
        // claim a point on the seam between them.
        #expect(!g.containsPointer(CGPoint(x: strip.maxX, y: strip.midY), in: strip))
        #expect(g.containsPointer(CGPoint(x: strip.minX, y: strip.midY), in: strip))
    }

    @Test("a region that does not reach the top of the screen keeps the ordinary rule")
    func regionsAwayFromTheEdgeAreUnchanged() {
        let g = geometry(ScreenFixtures.externalMain)
        // Fullscreen is the one state that still stops below the menu bar, so
        // nothing about it touches the screen edge and its top stays exclusive.
        let panel = g.fullscreenFrame
        #expect(panel.maxY < ScreenFixtures.externalMain.frame.maxY)
        #expect(!g.containsPointer(CGPoint(x: panel.midX, y: panel.maxY), in: panel))
        #expect(g.containsPointer(CGPoint(x: panel.midX, y: panel.maxY - 0.5), in: panel))
    }
}
