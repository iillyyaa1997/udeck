import Foundation
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

    /// A tab rename in progress: which tab, and what has been typed so far.
    ///
    /// This lives here, outside the view, for one reason: SwiftUI destroys a
    /// view when it stops being rendered, and the panel stops rendering its
    /// workspace whenever it collapses. Kept as view state, a half-typed name
    /// was silently discarded by an application switch — which is precisely
    /// what the panel's own rule about held state promises will not happen.
    /// State that has to outlive the view does not belong to the view.
    public var tabRename: TabRename?

    public struct TabRename: Equatable, Sendable {
        public var tabID: UUID
        public var text: String

        public init(tabID: UUID, text: String) {
            self.tabID = tabID
            self.text = text
        }
    }

    /// The operator did something in the panel. This is what turns a glance
    /// into a working panel, after which the cursor leaving no longer closes it.
    public var onInteract: () -> Void = {}
    public var onToggleFullscreen: () -> Void = {}
    public var onCollapse: () -> Void = {}
    public var onOpenSettings: () -> Void = {}

    public init() {}
}
