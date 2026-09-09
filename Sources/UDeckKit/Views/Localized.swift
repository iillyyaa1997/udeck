import SwiftUI
import UDeckCore

/// The language, where a view can reach it.
///
/// A separate channel from `deckTheme` because they answer to different
/// settings and change at different times: the look is edited constantly and
/// the language is set once. Putting the language on the theme would have made
/// every colour change re-evaluate every sentence.
private struct StringsKey: EnvironmentKey {
    /// English, because a view rendered outside the application — a preview, a
    /// test — has no settings to read and no operator to have a preference.
    static let defaultValue = Strings(.english)
}

public extension EnvironmentValues {
    /// Everything uDeck says. Read it as `@Environment(\.strings) var strings`
    /// and call it: `strings(.actionSave)`.
    var strings: Strings {
        get { self[StringsKey.self] }
        set { self[StringsKey.self] = newValue }
    }
}
