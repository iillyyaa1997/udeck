import Carbon.HIToolbox
import Foundation
import Testing
@testable import UDeckCore

@Suite("Keyboard shortcut")
struct HotKeyTests {
    /// `UDeckCore` writes the virtual key codes out as literals so that it does
    /// not have to import Carbon. Literals copied from somewhere else are only
    /// as good as the last time somebody checked them, so this checks them.
    @Test("the key codes are the real ones, not plausible ones")
    func keyCodesMatchCarbon() {
        let fromCarbon: [String: Int] = [
            "A": kVK_ANSI_A, "B": kVK_ANSI_B, "C": kVK_ANSI_C, "M": kVK_ANSI_M,
            "U": kVK_ANSI_U, "Z": kVK_ANSI_Z, "0": kVK_ANSI_0, "5": kVK_ANSI_5,
            "9": kVK_ANSI_9, "SPACE": kVK_Space, "RETURN": kVK_Return,
            "TAB": kVK_Tab, "ESCAPE": kVK_Escape, "DELETE": kVK_Delete,
            "LEFT": kVK_LeftArrow, "RIGHT": kVK_RightArrow,
            "UP": kVK_UpArrow, "DOWN": kVK_DownArrow,
            "HOME": kVK_Home, "END": kVK_End,
            "PAGEUP": kVK_PageUp, "PAGEDOWN": kVK_PageDown,
            "F1": kVK_F1, "F2": kVK_F2, "F5": kVK_F5, "F11": kVK_F11, "F12": kVK_F12,
        ]
        for (name, expected) in fromCarbon {
            #expect(HotKeyBinding.keyCodes[name] == UInt32(expected), "\(name) has the wrong code")
        }
    }

    @Test("the modifier masks are the real ones too")
    func modifierMasksMatchCarbon() {
        #expect(HotKeyModifier.control.carbonMask == UInt32(controlKey))
        #expect(HotKeyModifier.option.carbonMask == UInt32(optionKey))
        #expect(HotKeyModifier.shift.carbonMask == UInt32(shiftKey))
        #expect(HotKeyModifier.command.carbonMask == UInt32(cmdKey))
    }

    @Test("every offered key resolves, and none is offered twice")
    func offeredKeysAreReal() {
        let names = HotKeyBinding.orderedKeyNames
        #expect(!names.isEmpty)
        #expect(Set(names).count == names.count, "the picker lists a key twice")
        for name in names {
            #expect(HotKeyBinding.keyCodes[name] != nil, "\(name) is offered but cannot be bound")
        }
    }

    @Test("a key name is read whatever case it was written in")
    func keyLookupIgnoresCase() {
        #expect(HotKeyBinding(key: "u").keyCode == HotKeyBinding(key: "U").keyCode)
        #expect(HotKeyBinding(key: "space").keyCode == HotKeyBinding(key: "SPACE").keyCode)
        // But nothing beyond case is guessed at.
        #expect(HotKeyBinding(key: "spacebar").keyCode == nil)
        #expect(HotKeyBinding(key: "").keyCode == nil)
    }

    /// Registering a bare key globally takes it away from every application on
    /// the machine. There is no reading of the operator's settings file under
    /// which "u" should mean "you can no longer type the letter u".
    @Test("a shortcut with no modifiers is refused, not clamped")
    func bareKeyIsRefused() {
        #expect(!HotKeyBinding(key: "U", modifiers: []).isValid)
        #expect(HotKeyBinding(key: "U", modifiers: [.control]).isValid)
    }

    @Test("an unregisterable shortcut is turned off rather than left broken")
    func invalidShortcutIsDisabled() {
        var settings = AppSettings()
        settings.hotkey = HotKeyBinding(enabled: true, key: "nonsense", modifiers: [.command])
        #expect(settings.validated().hotkey.enabled == false)
        // What was meant is kept, so the settings screen can show it back.
        #expect(settings.validated().hotkey.key == "nonsense")

        settings.hotkey = HotKeyBinding(enabled: true, key: "U", modifiers: [])
        #expect(settings.validated().hotkey.enabled == false)

        settings.hotkey = HotKeyBinding(enabled: true, key: "U", modifiers: [.control, .option])
        #expect(settings.validated().hotkey.enabled == true)
    }

    @Test("the modifiers read in the order macOS writes them")
    func displayNameFollowsSystemOrder() {
        let all = HotKeyBinding(key: "U", modifiers: [.command, .shift, .option, .control])
        #expect(all.displayName == "⌃⌥⇧⌘U")
        #expect(HotKeyBinding(key: "space", modifiers: [.command, .control]).displayName == "⌃⌘SPACE")
    }

    @Test("the combined mask is every modifier and nothing else")
    func carbonModifiersCombine() {
        let binding = HotKeyBinding(key: "U", modifiers: [.control, .option])
        #expect(binding.carbonModifiers == UInt32(controlKey) | UInt32(optionKey))
        #expect(HotKeyBinding(key: "U", modifiers: []).carbonModifiers == 0)
    }

    /// A settings file written before the shortcut existed must not fail to
    /// load, and must not silently arrive with an empty binding either.
    @Test("a settings file from before the shortcut existed still loads")
    func olderSettingsFileGetsTheDefault() throws {
        let json = Data(#"{ "version": 1, "density": "normal" }"#.utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: json)
        #expect(settings.hotkey == HotKeyBinding())
        #expect(settings.hotkey.isValid)
    }

    @Test("a shortcut written by hand survives a round trip")
    func roundTrips() throws {
        let original = HotKeyBinding(enabled: true, key: "F7", modifiers: [.command, .shift])
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(HotKeyBinding.self, from: data) == original)
    }

    @Test("a half-written shortcut keeps the defaults for what it left out")
    func partialShortcutDecodes() throws {
        let json = Data(#"{ "enabled": false }"#.utf8)
        let binding = try JSONDecoder().decode(HotKeyBinding.self, from: json)
        #expect(binding.enabled == false)
        #expect(binding.key == HotKeyBinding().key)
        #expect(binding.modifiers == HotKeyBinding().modifiers)
    }
}
