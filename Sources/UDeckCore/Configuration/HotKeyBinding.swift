import Foundation

/// A modifier key, named the way a person would write it in a settings file.
public enum HotKeyModifier: String, Codable, Sendable, CaseIterable, Comparable {
    case control
    case option
    case shift
    case command

    /// The bit Carbon expects for this modifier.
    ///
    /// These are the values of `controlKey`, `optionKey`, `shiftKey` and
    /// `cmdKey` from `Carbon.HIToolbox`, written out rather than imported so
    /// that this target stays free of Carbon. `HotKeyTests` asserts each one
    /// against the real constant, so the copy cannot drift from the original.
    public var carbonMask: UInt32 {
        switch self {
        case .control: 0x1000
        case .option: 0x0800
        case .shift: 0x0200
        case .command: 0x0100
        }
    }

    /// The symbol macOS shows for it, in the order macOS shows them.
    public var symbol: String {
        switch self {
        case .control: "⌃"
        case .option: "⌥"
        case .shift: "⇧"
        case .command: "⌘"
        }
    }

    private var order: Int {
        switch self {
        case .control: 0
        case .option: 1
        case .shift: 2
        case .command: 3
        }
    }

    public static func < (lhs: HotKeyModifier, rhs: HotKeyModifier) -> Bool {
        lhs.order < rhs.order
    }
}

/// A global keyboard shortcut for opening the panel.
///
/// This is the alternate way in, not the main one — the pointer gesture is what
/// the panel is built around. It exists because a keyboard shortcut is the only
/// entry that works with the cursor nowhere near the top of the screen, and
/// because registering one costs no permission: `RegisterEventHotKey` is a
/// Carbon call that hands the key to the application before anyone else sees
/// it, unlike `NSEvent.addGlobalMonitorForEvents`, which watches every keystroke
/// on the machine and therefore requires Accessibility. uDeck asks macOS for
/// nothing, and that stays true with this.
public struct HotKeyBinding: Codable, Equatable, Sendable {
    public var enabled: Bool

    /// The key, by the name in `HotKeyBinding.keyCodes` — "U", "Space", "F7".
    public var key: String

    public var modifiers: Set<HotKeyModifier>

    public init(
        enabled: Bool = true,
        key: String = "U",
        modifiers: Set<HotKeyModifier> = [.control, .option]
    ) {
        self.enabled = enabled
        self.key = key
        self.modifiers = modifiers
    }

    /// See `GestureTuning.init(from:)` — same tolerance, same reasoning.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = HotKeyBinding()
        self.init(
            enabled: try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled,
            key: try c.decodeIfPresent(String.self, forKey: .key) ?? d.key,
            modifiers: try c.decodeIfPresent(Set<HotKeyModifier>.self, forKey: .modifiers) ?? d.modifiers
        )
    }

    /// The virtual key code, or `nil` when the name is not one this knows.
    ///
    /// Matched without regard to case, so a settings file saying `"u"` works as
    /// well as `"U"`; nothing else is guessed at, because a shortcut that
    /// silently becomes a different shortcut is worse than one that says it
    /// could not be read.
    public var keyCode: UInt32? {
        HotKeyBinding.keyCodes[key.uppercased()]
    }

    public var carbonModifiers: UInt32 {
        modifiers.reduce(into: UInt32(0)) { $0 |= $1.carbonMask }
    }

    /// Whether this can actually be registered.
    ///
    /// A shortcut with no modifiers is refused rather than clamped. Registering
    /// a bare key globally takes that key away from every application on the
    /// machine — typing "u" would open the panel instead of typing a letter —
    /// and there is no reading of the operator's intent under which that is
    /// what they meant.
    public var isValid: Bool {
        keyCode != nil && !modifiers.isEmpty
    }

    /// How the shortcut reads on screen: `⌃⌥U`.
    public var displayName: String {
        modifiers.sorted().map(\.symbol).joined() + key.uppercased()
    }

    /// The keys that can be bound, by name.
    ///
    /// ANSI virtual key codes. They are a fixed hardware-layout ABI rather than
    /// anything derived from the operator's keyboard layout: code 32 is the key
    /// in the U position, whatever that key types.
    public static let keyCodes: [String: UInt32] = {
        var table: [String: UInt32] = [
            "A": 0, "S": 1, "D": 2, "F": 3, "H": 4, "G": 5, "Z": 6, "X": 7, "C": 8, "V": 9,
            "B": 11, "Q": 12, "W": 13, "E": 14, "R": 15, "Y": 16, "T": 17,
            "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
            "9": 25, "7": 26, "8": 28, "0": 29,
            "O": 31, "U": 32, "I": 34, "P": 35, "L": 37, "J": 38, "K": 40,
            "N": 45, "M": 46,
            "RETURN": 36, "TAB": 48, "SPACE": 49, "DELETE": 51, "ESCAPE": 53,
            "HOME": 115, "PAGEUP": 116, "END": 119, "PAGEDOWN": 121,
            "LEFT": 123, "RIGHT": 124, "DOWN": 125, "UP": 126,
        ]
        let functionKeys: [UInt32] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
        for (index, code) in functionKeys.enumerated() {
            table["F\(index + 1)"] = code
        }
        return table
    }()

    /// The bindable keys in the order a person would look for them, for the
    /// settings picker. Letters, then digits, then function keys, then the
    /// named ones — not one alphabetical list with `F10` between `F1` and `F2`.
    public static let orderedKeyNames: [String] = {
        let letters = (0 ..< 26).map { String(UnicodeScalar(UInt8(65 + $0))) }
        let digits = (0 ... 9).map(String.init)
        let functionKeys = (1 ... 12).map { "F\($0)" }
        let named = ["SPACE", "RETURN", "TAB", "ESCAPE", "DELETE",
                     "LEFT", "RIGHT", "UP", "DOWN", "HOME", "END", "PAGEUP", "PAGEDOWN"]
        return (letters + digits + functionKeys + named).filter { keyCodes[$0] != nil }
    }()
}
