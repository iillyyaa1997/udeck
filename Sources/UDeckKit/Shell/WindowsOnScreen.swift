import AppKit
import UDeckCore

/// The windows on screen, read from the window server the way
/// `FullscreenDetector` reads them: owner, level and bounds, which
/// `CGWindowListCopyWindowInfo` gives any application with no permission asked.
/// Only a window's title is withheld without Screen Recording, and nothing here
/// reads one. Measured from uDeck itself, with no permission granted to it, in
/// a Tart guest and on a GitHub runner: the owner, level and bounds of every
/// window came back, and TextEdit's title did not (20261016-140156Z, run
/// 38915483520).
///
/// What `KeyboardHandback` decides from these is in `UDeckCore`; this is only
/// the reading, kept apart so that the decision is a test's to hold.
enum WindowsOnScreen {
    static func read() -> [KeyboardHandback.Window] {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return [] }
        let top = FullscreenDetector.mainScreenTop()
        return list.compactMap { window in
            guard let number = (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let pid = window[kCGWindowOwnerPID as String] as? pid_t,
                  let layer = window[kCGWindowLayer as String] as? Int,
                  let boundsDictionary = window[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary)
            else { return nil }
            return KeyboardHandback.Window(
                number: number,
                ownerPID: pid,
                // Optional by the documentation, so a window without one is kept.
                ownerName: window[kCGWindowOwnerName as String] as? String ?? "",
                layer: layer,
                bounds: QuartzCoordinates.appKitRect(fromQuartz: bounds, mainScreenTop: top)
            )
        }
    }
}
