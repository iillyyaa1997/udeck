import AppKit
import UDeckCore

/// Turns `NSScreen` into the plain values `UDeckCore` reasons about, and tells
/// the panel when the arrangement changes.
///
/// Screens change more often than it seems: docking, undocking, a lid closing,
/// waking from sleep, a resolution change, and the Dock moving to another edge
/// all invalidate the geometry. Recomputing from a notification rather than
/// caching is what keeps the panel from opening at a position that no longer
/// exists.
@MainActor
public final class ScreenObserver {
    public private(set) var screens: [ScreenSnapshot] = []

    /// Called after the arrangement changes.
    public var onChange: (() -> Void)?

    private var token: NotificationToken?

    public init() {
        refresh()
        token = NotificationToken(name: NSApplication.didChangeScreenParametersNotification) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
                self?.onChange?()
            }
        }
    }

    public func refresh() {
        screens = NSScreen.screens.map(Self.snapshot)
    }

    /// The screen the cursor is on right now.
    public var screenUnderCursor: ScreenSnapshot? {
        screens.screen(containing: NSEvent.mouseLocation)
    }

    public func screen(withID id: String) -> ScreenSnapshot? {
        screens.first { $0.id == id }
    }

    static func snapshot(_ screen: NSScreen) -> ScreenSnapshot {
        // `auxiliaryTopLeftArea` and friends are public API from macOS 12 and
        // need no entitlement. They are optional: a screen with no notch reports
        // nothing rather than an empty rect.
        ScreenSnapshot(
            id: identifier(of: screen),
            name: screen.localizedName,
            frame: screen.frame,
            visibleFrame: screen.visibleFrame,
            backingScale: screen.backingScaleFactor,
            safeAreaTop: screen.safeAreaInsets.top,
            auxiliaryTopLeft: screen.auxiliaryTopLeftArea,
            auxiliaryTopRight: screen.auxiliaryTopRightArea
        )
    }

    /// A stable id for a display.
    ///
    /// `NSScreen` instances are recreated whenever the arrangement changes, so
    /// they cannot be compared directly. The display id survives that; the
    /// localized name is the fallback for the case where the key is missing,
    /// which is rare but not impossible on a virtual display.
    static func identifier(of screen: NSScreen) -> String {
        if let number = screen.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")
        ] as? NSNumber {
            return "display-\(number.uint32Value)"
        }
        return "name-\(screen.localizedName)"
    }
}
