import AppKit
import UDeckCore

/// Answers "is the frontmost application filling this screen?" without asking
/// for any permission.
///
/// This matters because hovering over a fullscreen app is where panels of this
/// kind have been observed to corrupt the system's own menu-bar reveal — a bug
/// in *macOS's* state rather than in the panel's, which is a much worse class of
/// problem than an unwanted panel.
///
/// `CGWindowListCopyWindowInfo` returns window bounds and owning process for
/// every on-screen window with no entitlement; only window *titles* are withheld
/// without Screen Recording, and nothing here reads a title.
///
/// The test is deliberately strict — an exact match against the screen's full
/// frame, from the frontmost application. A merely maximised window stops below
/// the menu bar and so does not match, which is the right answer: the panel is
/// welcome over a maximised window. Measured on the machine this was built for,
/// a maximised Warp is `2316x1410` from the top of a `2560x1440` screen, so the
/// distinction is not a fine one.
///
/// What is left here is the part that has to ask AppKit questions. The
/// coordinate arithmetic moved to `QuartzCoordinates` in `UDeckCore`, where it
/// can be tested.
public enum FullscreenDetector {
    public static func isFrontmostApplicationFullscreen(on screen: ScreenSnapshot) -> Bool {
        guard let frontmost = NSWorkspace.shared.frontmostApplication else { return false }
        let frontmostPID = frontmost.processIdentifier
        guard frontmostPID != ProcessInfo.processInfo.processIdentifier else { return false }

        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return false }

        let target = screen.frame
        let top = mainScreenTop()

        for window in windows {
            guard let pid = window[kCGWindowOwnerPID as String] as? pid_t, pid == frontmostPID,
                  let layer = window[kCGWindowLayer as String] as? Int, layer == 0,
                  let boundsDictionary = window[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary)
            else { continue }

            let inAppKit = QuartzCoordinates.appKitRect(fromQuartz: bounds, mainScreenTop: top)
            if inAppKit.isApproximately(target, within: 1) { return true }
        }
        return false
    }


    /// `maxY` of the display both coordinate systems are measured from: the one
    /// whose origin is `(0, 0)`, which is the one with the menu bar.
    ///
    /// `NSScreen.main` is the screen with the *keyboard focus*, which is a
    /// different question and is only the same screen some of the time — it is
    /// the fallback rather than the answer.
    static func mainScreenTop() -> CGFloat {
        NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.maxY
            ?? NSScreen.main?.frame.maxY
            ?? 0
    }
}
