import CoreGraphics
import Foundation
import Testing
@testable import UDeckCore

/// The conversion between the window server's coordinates and AppKit's.
///
/// It had no tests at all while it lived inside the fullscreen detector, where
/// nothing could reach it. Everything below uses measurements from the two real
/// displays rather than round numbers, because the interesting mistakes here are
/// off by a screen height or by a window height, and both hide behind a fixture
/// that is 100 tall on a screen that is 1000 tall.
@Suite("Quartz and AppKit coordinates")
struct QuartzCoordinatesTests {
    /// The DELL is the main display: origin `(0, 0)`, so both systems measure
    /// from its top-left and bottom-left respectively.
    let mainScreenTop: CGFloat = 1440

    @Test("a maximised window measured from the running machine converts to what was seen")
    func realMaximisedWindow() {
        // A maximised window on the DELL, as reported by CGWindowListCopyWindowInfo.
        let quartz = CGRect(x: 244, y: 30, width: 2316, height: 1410)
        let appKit = QuartzCoordinates.appKitRect(fromQuartz: quartz, mainScreenTop: mainScreenTop)
        #expect(appKit == CGRect(x: 244, y: 0, width: 2316, height: 1410))
        // And so it is not fullscreen: it stops 30 points short at the top.
        #expect(!appKit.isApproximately(ScreenFixtures.externalMain.frame, within: 1))
    }

    @Test("a window filling the screen converts to the screen's own frame")
    func trueFullscreenWindow() {
        let quartz = CGRect(x: 0, y: 0, width: 2560, height: 1440)
        let appKit = QuartzCoordinates.appKitRect(fromQuartz: quartz, mainScreenTop: mainScreenTop)
        #expect(appKit.isApproximately(ScreenFixtures.externalMain.frame, within: 1))
    }

    /// The rect rule flips about the far edge and the point rule flips about
    /// the coordinate. Using one where the other belongs is off by the rect's
    /// height — invisible on a six-point strip, a screen away on a panel.
    @Test("a rect flips about its far edge, a point about itself")
    func rectAndPointAreDifferentRules() {
        let quartz = CGRect(x: 100, y: 200, width: 300, height: 400)
        let rect = QuartzCoordinates.appKitRect(fromQuartz: quartz, mainScreenTop: mainScreenTop)
        #expect(rect.minY == mainScreenTop - quartz.maxY)
        #expect(rect.maxY == mainScreenTop - quartz.minY)

        let point = QuartzCoordinates.appKitPoint(fromQuartz: quartz.origin, mainScreenTop: mainScreenTop)
        #expect(point.y == mainScreenTop - quartz.minY)
        #expect(point.y != rect.minY, "a point must not be converted with the rect rule")
    }

    @Test("converting twice returns exactly what went in")
    func conversionIsItsOwnInverse() {
        let rects = [
            CGRect(x: 244, y: 30, width: 2316, height: 1410),
            CGRect(x: 0, y: 0, width: 2560, height: 1440),
            // The built-in display, which sits above and to the left of the
            // main one, so its Quartz y is negative.
            CGRect(x: -1728, y: -100, width: 1728, height: 1117),
            CGRect(x: -957.5, y: 470.25, width: 185, height: 32),
        ]
        for rect in rects {
            let there = QuartzCoordinates.appKitRect(fromQuartz: rect, mainScreenTop: mainScreenTop)
            let back = QuartzCoordinates.quartzRect(fromAppKit: there, mainScreenTop: mainScreenTop)
            #expect(back == rect, "\(rect) did not survive the round trip")
        }
        for point in [CGPoint(x: 1280, y: 0), CGPoint(x: -864, y: 470), CGPoint.zero] {
            let there = QuartzCoordinates.appKitPoint(fromQuartz: point, mainScreenTop: mainScreenTop)
            #expect(QuartzCoordinates.quartzPoint(fromAppKit: there, mainScreenTop: mainScreenTop) == point)
        }
    }

    @Test("x and the size are never touched")
    func onlyYChanges() {
        let quartz = CGRect(x: -957, y: 470, width: 185, height: 32)
        let appKit = QuartzCoordinates.appKitRect(fromQuartz: quartz, mainScreenTop: mainScreenTop)
        #expect(appKit.minX == quartz.minX)
        #expect(appKit.width == quartz.width)
        #expect(appKit.height == quartz.height)
    }

    /// The built-in display's top edge is 470 points below the main display's
    /// in Quartz, which is the whole reason the gesture is bound to the screen
    /// the cursor is on rather than to the notched one.
    @Test("a window on the secondary display lands where the fixture says it does")
    func secondaryDisplay() {
        let builtIn = ScreenFixtures.builtInNotched
        let quartzTop = mainScreenTop - builtIn.frame.maxY
        #expect(quartzTop == 470)
        let quartz = CGRect(x: builtIn.frame.minX, y: quartzTop,
                            width: builtIn.frame.width, height: builtIn.frame.height)
        let appKit = QuartzCoordinates.appKitRect(fromQuartz: quartz, mainScreenTop: mainScreenTop)
        #expect(appKit.isApproximately(builtIn.frame, within: 0.001))
    }

    @Test("the tolerance absorbs a rounded edge and nothing wider")
    func approximateEquality() {
        let base = CGRect(x: 0, y: 0, width: 2560, height: 1440)
        #expect(base.isApproximately(CGRect(x: 0.5, y: -0.5, width: 2560, height: 1440), within: 1))
        #expect(base.isApproximately(CGRect(x: 0, y: 0, width: 2559.5, height: 1440.5), within: 1))
        #expect(!base.isApproximately(CGRect(x: 2, y: 0, width: 2560, height: 1440), within: 1))
        #expect(!base.isApproximately(CGRect(x: 0, y: 0, width: 2558, height: 1440), within: 1))
        // Every edge is checked, not just the origin: a window with the right
        // corner and the wrong size is the shape this exists to reject.
        #expect(!base.isApproximately(CGRect(x: 0, y: 0, width: 2560, height: 1410), within: 1))
        #expect(base.isApproximately(base, within: 0))
    }
}
