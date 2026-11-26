import Carbon.HIToolbox
import Foundation
import Testing
@testable import UDeckCore

@Suite("⌘V in a card's field")
struct PasteKeyTests {
    @Test("the V key's code is the real one")
    func keyCode() {
        #expect(Int(PasteKey.vKeyCode) == kVK_ANSI_V)
    }

    @Test("⌘V on a Russian layout is a paste: «м» on the V key")
    func russian() {
        #expect(PasteKey.isPaste(commandOnly: true, letter: "м", keyCode: PasteKey.vKeyCode))
        #expect(PasteKey.isPaste(commandOnly: true, letter: "М", keyCode: PasteKey.vKeyCode))
        // ⌘C on it — «с» on the C key — is not.
        #expect(!PasteKey.isPaste(commandOnly: true, letter: "с", keyCode: UInt16(kVK_ANSI_C)))
    }

    @Test("a Latin layout is read by its letter, wherever the key is")
    func latin() {
        #expect(PasteKey.isPaste(commandOnly: true, letter: "v", keyCode: PasteKey.vKeyCode))
        // Dvorak: V is on QWERTY's period key, and QWERTY's V key types K.
        #expect(PasteKey.isPaste(commandOnly: true, letter: "v", keyCode: UInt16(kVK_ANSI_Period)))
        #expect(!PasteKey.isPaste(commandOnly: true, letter: "k", keyCode: PasteKey.vKeyCode))
    }

    @Test("only ⌘ alone: ⇧⌘V, ⌥⌘V and V are not a paste")
    func modifiers() {
        #expect(!PasteKey.isPaste(commandOnly: false, letter: "v", keyCode: PasteKey.vKeyCode))
        #expect(!PasteKey.isPaste(commandOnly: false, letter: "м", keyCode: PasteKey.vKeyCode))
    }
}
