import Observation
import UDeckCore

/// The bridge between the window controller and the SwiftUI content.
///
/// The controller owns the state machine; the views only need to know which
/// phase is showing and how to ask for a change. Keeping that in one small
/// object means the views never reach into AppKit, and the controller never
/// reaches into SwiftUI.
@MainActor
@Observable
public final class ShellState {
    public internal(set) var phase: PanelPhase = .collapsed

    /// The operator did something in the panel. This is what turns a glance
    /// into a working panel, after which the cursor leaving no longer closes it.
    public var onInteract: () -> Void = {}
    public var onToggleFullscreen: () -> Void = {}
    public var onCollapse: () -> Void = {}

    public init() {}
}
