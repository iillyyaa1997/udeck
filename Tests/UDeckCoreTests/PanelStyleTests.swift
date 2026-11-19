import Foundation
import Testing
@testable import UDeckCore

/// Settings → Look as the operator chose it on 2026-11-19: whether the panel is
/// light or dark is one question (the appearance), what it is made of is
/// another (the style), and a style is one click with both variants inside.
@Suite("Styles and the appearance")
struct PanelStyleTests {
    @Test("every style's light variant is light and its dark variant is dark")
    func variantsAreWhatTheySay() {
        for style in PanelStyle.allCases {
            #expect(style.light.ink == .dark, "\(style)'s light variant must carry dark text")
            #expect(style.light.glass.tintIsLight, "\(style)'s light variant must be tinted lighter")
            #expect(style.dark.ink == .light, "\(style)'s dark variant must carry light text")
            #expect(!style.dark.glass.tintIsLight, "\(style)'s dark variant must be tinted darker")
            // A style read back from the settings file must still be the style.
            #expect(style.light.validated() == style.light && style.dark.validated() == style.dark)
            #expect(style.look(forDark: false) == style.light)
            #expect(style.look(forDark: true) == style.dark)
        }
        // No two styles share a variant: a card would light up for both.
        for (index, style) in PanelStyle.allCases.enumerated() {
            for other in PanelStyle.allCases.dropFirst(index + 1) {
                #expect(style.light != other.light && style.dark != other.dark, "\(style) and \(other) share a variant")
            }
        }
    }

    @Test("the six presets are the variants of the styles, and uDeck ships wearing Glass")
    func presetsAreVariants() {
        #expect(PanelStyle.glass.light == PanelMode.light.look)
        #expect(PanelStyle.glass.dark == PanelMode.dark.look)
        #expect(PanelStyle.solid.light == PanelMode.paper.look)
        #expect(PanelStyle.solid.dark == PanelMode.contrast.look)
        #expect(PanelStyle.smoke.dark == PanelMode.smoke.look)
        #expect(PanelStyle.ghost.dark == PanelMode.ghost.look)
        #expect(ThemeSettings().style == .glass, "a fresh install wears Glass")
    }

    @Test("the appearance reads and writes the source the file keeps")
    func appearance() {
        var theme = ThemeSettings()
        #expect(theme.appearance == .light, "a fresh install is light and changes by nothing")
        theme.appearance = .dark
        #expect(theme.source == .manual && theme.manualIsDark)
        theme.appearance = .automatic
        #expect(theme.source == .system)
        theme.appearance = .light
        #expect(theme.source == .manual && !theme.manualIsDark)
        // Following the clock is automatic too, and choosing automatic keeps it.
        theme.source = .schedule
        #expect(theme.appearance == .automatic)
        theme.appearance = .automatic
        #expect(theme.source == .schedule)
    }

    @Test("a style is one click: both looks change, the appearance does not")
    func applyingAStyle() {
        var theme = ThemeSettings(source: .system)
        theme.apply(.solid)
        #expect(theme.light == PanelStyle.solid.light)
        #expect(theme.dark == PanelStyle.solid.dark)
        #expect(theme.style == .solid)
        #expect(theme.source == .system)
        // A knob moved in one variant makes it the operator's own.
        theme.light.glass.tintStrength = 0.4
        #expect(theme.style == nil)
    }

    @Test("a value shared by every state stays when a style is applied, and does not stop it matching")
    func sharedValuesStay() {
        var theme = ThemeSettings()
        theme.states.shared = [.presence]
        theme.light.presence = 0.5
        theme.dark.presence = 0.5
        theme.apply(.ghost)
        #expect(theme.light.presence == 0.5 && theme.dark.presence == 0.5)
        #expect(theme.light.glass == PanelStyle.ghost.light.glass)
        #expect(theme.style == .ghost)
    }

    @Test("a state set up on its own wears the style too, keeping how visible it is")
    func statesWearTheStyle() throws {
        var theme = ThemeSettings()
        let id = UUID()
        var faded = PanelStyle.glass.dark
        faded.presence = 0.4
        theme.states.dark[id] = faded
        theme.states.light[id] = PanelStyle.glass.light
        theme.apply(.solid)
        let dark = try #require(theme.states.dark[id])
        #expect(dark.glass == PanelStyle.solid.dark.glass && dark.ink == PanelStyle.solid.dark.ink)
        #expect(dark.presence == 0.4, "the state's own visibility is kept")
        #expect(theme.states.light[id] == PanelStyle.solid.light)
    }

    @Test("a group of states' own looks can be saved as a style")
    func savingAGroup() throws {
        var theme = ThemeSettings()
        let savedNow = theme.saveStyle(as: "Away", light: PanelStyle.ghost.light, dark: PanelStyle.smoke.dark)
        let saved = try #require(savedNow)
        #expect(saved.look == PanelStyle.ghost.light && saved.darkLook == PanelStyle.smoke.dark)
        #expect(theme.light == PanelStyle.glass.light, "saving does not change what is worn")
    }

    @Test("a style of one's own keeps both variants, and a name in use is replaced")
    func savingAStyle() throws {
        var theme = ThemeSettings()
        theme.apply(.smoke)
        theme.dark.inkBrightness = 0.8
        let savedNow = theme.saveStyle(as: "  Ночь ")
        let saved = try #require(savedNow)
        #expect(saved.name == "Ночь")
        #expect(saved.look == theme.light && saved.darkLook == theme.dark)
        #expect(theme.savedStyle?.id == saved.id)
        #expect(theme.style == nil)

        theme.apply(.glass)
        #expect(theme.savedStyle == nil)
        theme.apply(saved)
        #expect(theme.savedStyle?.id == saved.id)

        theme.light.inkBrightness = 0.9
        let againNow = theme.saveStyle(as: "ночь")
        let again = try #require(againNow)
        #expect(theme.saved.count == 1 && again.id == saved.id)
        #expect(theme.saved[0].look.inkBrightness == 0.9)
        #expect(theme.saveStyle(as: "   ") == nil)
    }

    @Test("a preset saved by an older uDeck is one look worn in both appearances")
    func olderPresets() throws {
        let json = Data(#"{ "id": "8F0E0000-0000-4000-8000-000000000001", "name": "Old", "look": { "ink": "dark" } }"#.utf8)
        let preset = try JSONDecoder().decode(PanelPreset.self, from: json)
        #expect(preset.dark == nil)
        #expect(preset.darkLook == preset.look)
        // Written back, it still has no dark variant of its own.
        let written = try JSONEncoder().encode(preset)
        let object = try #require(try JSONSerialization.jsonObject(with: written) as? [String: Any])
        #expect(object["dark"] == nil)
        // And a two-variant one survives the round trip.
        let both = PanelPreset(name: "Both", look: PanelStyle.ghost.light, dark: PanelStyle.ghost.dark)
        #expect(try JSONDecoder().decode(PanelPreset.self, from: JSONEncoder().encode(both)) == both)
    }
}
