import AppKit

/// The window uDeck lives in.
///
/// An `NSPanel` rather than an `NSWindow` because of one style-mask bit:
/// `.nonactivatingPanel`, which only applies to panels, and which means clicking
/// the panel does not pull the whole application to the front. That is what lets
/// a glance at the panel leave the operator's terminal exactly as it was.
///
/// The style mask is set at initialisation and never changed. Toggling
/// `.nonactivatingPanel` after the fact is known not to re-apply the underlying
/// activation flag, which produces a window that behaves like neither kind.
public final class DeckPanel: NSPanel {
    public init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        // A borderless window refuses key status by default, and a panel that
        // cannot take the keyboard cannot be worked in.
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovableByWindowBackground = false
        isMovable = false

        // Above ordinary windows and the Dock, below open system menus. Going
        // higher than the menu level would cover menus the operator pulled down,
        // which is worse than being covered by one.
        level = .statusBar

        // Present on every Space, allowed over fullscreen apps, never swept up
        // by Mission Control, and skipped by the window cycler.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        // The glass look is drawn by the content view; the window itself
        // contributes nothing but its shadow.
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
    }

    /// Borderless windows return `false` by default. Without this the panel can
    /// never hold a text field.
    public override var canBecomeKey: Bool { true }

    /// The panel is not the application's main window, and claiming otherwise
    /// would make menu commands behave as if uDeck were a document app.
    public override var canBecomeMain: Bool { false }
}
