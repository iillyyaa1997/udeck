import Foundation

/// ⌘V, whatever the keyboard layout. A layout that types Latin letters is read
/// by its letter — Dvorak's V is not where QWERTY's is — and any other by the
/// key: a Russian layout's ⌘V gives «м», and a file pasted into a card's field
/// went in as its name, as text (0.9.18; 0.9.19 reads the key).
public enum PasteKey {
    /// The V key's virtual code (`kVK_ANSI_V`): where V is on a QWERTY
    /// keyboard, and «М» on a Russian one.
    public static let vKeyCode: UInt16 = 9

    /// `commandOnly`: ⌘ held and no other modifier. `letter`: the event's
    /// characters without modifiers.
    public static func isPaste(commandOnly: Bool, letter: String?, keyCode: UInt16) -> Bool {
        guard commandOnly else { return false }
        let letter = letter?.lowercased() ?? ""
        if letter == "v" { return true }
        let latin = letter.unicodeScalars.first.map(\.isASCII) ?? false
        return !latin && keyCode == vKeyCode
    }
}
