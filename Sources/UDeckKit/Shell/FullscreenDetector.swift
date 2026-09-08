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
/// welcome over a maximised window.
public enum FullscreenDetector {
    public static func isFrontmostApplicationFullscreen(on screen: ScreenSnapshot) -> Bool {
        guard let frontmost = NSWorkspace.shared.frontmostApplication else { return false }
        let frontmostPID = frontmost.processIdentifier
        guard frontmostPID != ProcessInfo.processInfo.processIdentifier else { return false }

        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return false }

        let target = screen.frame

        for window in windows {
            guard let pid = window[kCGWindowOwnerPID as String] as? pid_t, pid == frontmostPID,
                  let layer = window[kCGWindowLayer as String] as? Int, layer == 0,
                  let boundsDictionary = window[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary)
            else { continue }

            if approximatelyEqual(appKitRect(fromQuartz: bounds), target) { return true }
        }
        return false
    }

    /// Quartz measures from the top-left of the display that owns the menu bar,
    /// with `y` growing downward; AppKit measures from that display's
    /// bottom-left with `y` growing upward.
    static func appKitRect(fromQuartz rect: CGRect, mainScreenTop: CGFloat? = nil) -> CGRect {
        let top = mainScreenTop ?? NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.maxY
            ?? NSScreen.main?.frame.maxY
            ?? 0
        return CGRect(x: rect.minX, y: top - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Window bounds arrive as integers while screen frames can carry a
    /// fraction, so an exact comparison would miss by half a point.
    static func approximatelyEqual(_ lhs: CGRect, _ rhs: CGRect, tolerance: CGFloat = 1) -> Bool {
        abs(lhs.minX - rhs.minX) <= tolerance
            && abs(lhs.minY - rhs.minY) <= tolerance
            && abs(lhs.width - rhs.width) <= tolerance
            && abs(lhs.height - rhs.height) <= tolerance
    }
}
