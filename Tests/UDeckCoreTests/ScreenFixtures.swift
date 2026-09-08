import CoreGraphics
import Foundation
@testable import UDeckCore

/// The two screens uDeck was designed against, measured on the machine it was
/// built for. Real numbers, because the interesting bugs in this area come from
/// the two displays disagreeing — different origins, different menu-bar heights,
/// different backing scales — and invented round numbers hide exactly that.
enum ScreenFixtures {
    /// DELL P2723DE. The main display, and it has no notch. The panel has to
    /// work here first: this is where the cursor spends most of its time.
    static let externalMain = ScreenSnapshot(
        id: "dell",
        name: "DELL P2723DE",
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

    static let both = [externalMain, builtInNotched]
}
