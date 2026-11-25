import Foundation

/// Who keeps uDeck in the Dock — and so in Cmd+Tab — now.
///
/// uDeck is an accessory application (`LSUIElement`): no Dock icon, and, the
/// part that matters, not in the Cmd+Tab switcher, which lists only regular
/// applications — the ones with an icon in the Dock. That is right for a panel
/// at the edge of the screen and wrong for a window somebody is working in: a
/// window you cannot switch back to is one you have to close and open again.
/// Settings knew it since 0.6; a card's own window did not, and the operator
/// could not Cmd+Tab to Agents in one (11-25).
///
/// So each window of that kind holds uDeck in the Dock while it is open, and
/// the last one to let go makes it an accessory again. The holders are kept
/// here, apart from AppKit, so that the rule can be held to in a test.
public struct DockHolders: Equatable, Sendable {
    public private(set) var holders: Set<String> = []

    public init() {}

    /// Whether uDeck should be in the Dock.
    public var inTheDock: Bool { !holders.isEmpty }

    public mutating func hold(_ holder: String) { holders.insert(holder) }
    public mutating func release(_ holder: String) { holders.remove(holder) }
}
