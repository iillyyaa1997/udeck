import CoreGraphics
import Foundation
@testable import UDeckCore

/// The two screens uDeck was designed against, measured on the machine it was
/// built for. Real numbers, because the interesting bugs in this area come from
/// the two displays disagreeing — different origins, different menu-bar heights,
/// different backing scales — and invented round numbers hide exactly that.
enum ScreenFixtures {
    /// The external display: main, no notch, 2560x1440 at 1x. The panel has to
    /// work here first — on the machine this was measured on it is where the
    /// cursor spends most of its time. The numbers are a real display's rather
    /// than round ones, because the interesting bugs come from two screens
    /// disagreeing and round numbers hide the disagreement.
    static let externalMain = ScreenSnapshot(
        id: "external",
        name: "External 2560x1440",
        frame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
        visibleFrame: CGRect(x: 0, y: 0, width: 2560, height: 1410),
        backingScale: 1,
        safeAreaTop: 0,
        auxiliaryTopLeft: nil,
        auxiliaryTopRight: nil
    )

    /// The built-in Retina display: notched, secondary, one screen to the left
    /// and 147 points lower than the main one.
    static let builtInNotched = ScreenSnapshot(
        id: "builtin",
        name: "Built-in Retina Display",
        frame: CGRect(x: -1728, y: -147, width: 1728, height: 1117),
        visibleFrame: CGRect(x: -1728, y: -147, width: 1728, height: 1085),
        backingScale: 2,
        safeAreaTop: 32,
        auxiliaryTopLeft: CGRect(x: -1728, y: 938, width: 771, height: 32),
        auxiliaryTopRight: CGRect(x: -772, y: 938, width: 772, height: 32)
    )

    /// A notched screen whose notch is **not** in the middle.
    ///
    /// No shipping Mac looks like this. It exists because both real fixtures
    /// put the notch within half a point of the screen's centre, which means no
    /// test written against them can tell "centred on the anchor" from "centred
    /// on the screen" — and the whole design rests on the first. A fixture
    /// where the two rules disagree is the only thing that can pin it.
    ///
    /// The wings are deliberately lopsided: 400 points on the left, 1143 on the
    /// right, so the notch sits well left of centre.
    static let offCentreNotch = ScreenSnapshot(
        id: "lopsided",
        name: "Lopsided Display",
        frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
        visibleFrame: CGRect(x: 0, y: 0, width: 1728, height: 1085),
        backingScale: 2,
        safeAreaTop: 32,
        auxiliaryTopLeft: CGRect(x: 0, y: 1085, width: 400, height: 32),
        auxiliaryTopRight: CGRect(x: 585, y: 1085, width: 1143, height: 32)
    )

    /// The mirror of `offCentreNotch`: the notch well to the *right*.
    ///
    /// Needed because the two clamps in the panel's placement are separate
    /// branches — one stops it running off the left edge, the other off the
    /// right — and a notch that leans one way only ever exercises one of them.
    static let offCentreNotchRight = ScreenSnapshot(
        id: "lopsided-right",
        name: "Lopsided Display (right)",
        frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
        visibleFrame: CGRect(x: 0, y: 0, width: 1728, height: 1085),
        backingScale: 2,
        safeAreaTop: 32,
        auxiliaryTopLeft: CGRect(x: 0, y: 1085, width: 1143, height: 32),
        auxiliaryTopRight: CGRect(x: 1328, y: 1085, width: 400, height: 32)
    )

    static let both = [externalMain, builtInNotched]
}
