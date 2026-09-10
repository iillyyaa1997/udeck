import Foundation
import Observation

/// What the settings screen needs from an updater, and nothing more.
///
/// The updater itself lives in the executable target, not here. `UDeckKit` has
/// no dependencies of its own and this is not the place to acquire the first
/// one: a settings screen needs a button, a switch and a date, none of which
/// says anything about how an update is fetched or verified.
///
/// It also means the settings screen renders in a build with no updater at all
/// — which is what `swift build && .build/debug/uDeck` is, and what the tests
/// would be if `UDeckKit` had any.
@MainActor
public protocol UpdateChecking: AnyObject {
    /// Whether uDeck looks for a new version on its own.
    ///
    /// Off until the operator turns it on. uDeck makes no network connection of
    /// any kind otherwise, and an application that quietly starts talking to a
    /// server because it was updated is doing something the operator did not
    /// ask for — even when the server is its own.
    var checksAutomatically: Bool { get set }

    /// When it last looked. `nil` when it never has.
    var lastCheck: Date? { get }

    /// Look now, and show the result whatever it is — including "you are up to
    /// date", which a check the operator asked for has to say out loud.
    func checkNow()
}

/// A no-op updater, for a build that has none.
@MainActor
public final class NoUpdateChecking: UpdateChecking {
    public var checksAutomatically = false
    public var lastCheck: Date? { nil }
    public init() {}
    public func checkNow() {}
}
