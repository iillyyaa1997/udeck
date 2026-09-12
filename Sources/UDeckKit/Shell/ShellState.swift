import CoreGraphics
import Foundation
import Observation
import SwiftUI
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

    /// Where the panel sits inside its window, in view coordinates.
    ///
    /// The window no longer changes shape when the panel does — it is sized
    /// once per screen and the panel moves inside it, so this is the thing that
    /// animates. A layer moving inside a still window is GPU work; a window
    /// changing shape makes the compositor rebuild the glass every frame.
    public internal(set) var panelRect: CGRect = .zero

    /// The curve the content fades on, which is not the curve the panel moves
    /// on: it starts after the panel has visibly begun to move, and it leaves
    /// faster than it arrives. Set by the controller, which is the only place
    /// that knows which direction this transition is going.
    public internal(set) var contentAnimation: Animation = .default

    /// How far the panel window reaches above the menu bar's lower edge on the
    /// screen it is currently on.
    ///
    /// The window is taller than its content by this much, so the content has
    /// to be inset by it or the first line of the panel lands in the menu bar.
    /// It is a property of the screen, not of the view, which is why the
    /// controller hands it over rather than the view working it out.
    public internal(set) var topOverhang: CGFloat = 0

    /// Whether the panel's top edge is currently the screen's top edge.
    ///
    /// True for the hover states on a notchless screen, false under a real
    /// notch and false in fullscreen, which stays below the menu bar so the
    /// menu bar cannot become unreachable.
    public internal(set) var weldedToTopEdge = false

    /// Whether the screen the panel is on has a notch of its own.
    ///
    /// The collapsed state is a drawn island where it does not, and a thin lip
    /// under real hardware where it does — the same state, two different things
    /// to draw.
    public internal(set) var screenHasNotch = false

    /// Whether another application currently has the whole screen.
    ///
    /// Half of which state the island is in — the phase is the other half. It
    /// arrives with the pointer samples, which is also its limit: a film
    /// started without touching the mouse is noticed at the next sample rather
    /// than at the instant it goes full-screen.
    public internal(set) var surroundingIsFullscreen = false

    /// Whether uDeck is the active application.
    ///
    /// Not the panel's key status, which is a different thing and was measured
    /// to be the wrong signal: the panel is non-activating and does not
    /// `hidesOnDeactivate`, so `isKeyWindow` stays true with another
    /// application verifiably frontmost. What the system material follows is
    /// application activation.
    public internal(set) var applicationIsActive = true

    /// Whether the panel has finished moving.
    ///
    /// False for the whole of a transition in either direction, true at rest.
    /// The views need it because one of their rules — nothing is drawn under a
    /// real notch — is about the collapsed state *at rest*, and reading it off
    /// the phase deleted the panel's glass at the first frame of every collapse
    /// on the built-in display. See `PanelChrome.drawsMaterial`.
    public internal(set) var isSettled = true

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

extension PanelMotion {
    /// The SwiftUI curve this motion means.
    ///
    /// The shape of a transition is decided in Core, where it can be tested;
    /// this is the one line that turns it into something a view can be handed.
    var swiftUI: Animation {
        switch self {
        case .immediate: .linear(duration: 0)
        case .spring(let response, let damping): .spring(response: response, dampingFraction: damping)
        case .ease(let duration): .easeOut(duration: duration)
        }
    }
}
