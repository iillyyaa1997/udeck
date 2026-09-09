import Foundation
import Testing
@testable import UDeckCore

/// The palette is the one place the look becomes a colour, so these tests are
/// what "one place" actually means: change the look and *everything* moves;
/// change nothing and the panel is exactly the colour it was before the
/// twelve scattered opacities were folded into one table.
@Suite("Palette")
struct PaletteTests {

    // MARK: - It is still the panel it was

    /// The strengths as they were spelled out at each call site before the
    /// fold, checked against the table that replaced them.
    ///
    /// Written out by hand rather than read from the table, which is the whole
    /// point: a test that asks the table what the table says would pass however
    /// the numbers were mistyped during the move.
    @Test("the dark panel keeps every strength it had")
    func darkPanelStrengthsUnchanged() {
        let p = Palette(look: PanelLook(ink: .light))

        #expect(p.windowFill.alpha == 0.07)
        #expect(p.recess.alpha == 0.28)
        #expect(p.selection.alpha == 0.14)
        #expect(p.subtleFill.alpha == 0.06)
        #expect(p.hover.alpha == 0.05)
        #expect(p.hoverPressed.alpha == 0.12)
        #expect(p.line.alpha == 0.11)
        #expect(p.panelBorder.alpha == 0.14)
        #expect(p.muted.alpha == 0.58)
        #expect(p.dim.alpha == 0.40)
        #expect(p.text.alpha == 1)
        #expect(p.innerHighlight.alpha == 0.16)
    }

    @Test("the light panel keeps every strength it had")
    func lightPanelStrengthsUnchanged() {
        let p = Palette(look: PanelLook(ink: .dark))

        #expect(p.windowFill.alpha == 0.07)
        #expect(p.recess.alpha == 0.10)
        #expect(p.selection.alpha == 0.10)
        #expect(p.subtleFill.alpha == 0.05)
        #expect(p.hover.alpha == 0.06)
        #expect(p.hoverPressed.alpha == 0.14)
        #expect(p.line.alpha == 0.16)
        #expect(p.panelBorder.alpha == 0.20)
        #expect(p.muted.alpha == 0.66)
        #expect(p.dim.alpha == 0.50)
        #expect(p.text.alpha == 1)
    }

    @Test("the state colours are the two sets they always were")
    func stateColoursUnchanged() {
        let dark = Palette(look: PanelLook(ink: .light))
        #expect(dark.accent.ink == InkColor(red: 0.561, green: 0.780, blue: 1.0))
        #expect(dark.ok.ink == InkColor(red: 0.435, green: 0.827, blue: 0.639))
        #expect(dark.warn.ink == InkColor(red: 0.949, green: 0.776, blue: 0.541))
        #expect(dark.crit.ink == InkColor(red: 1.0, green: 0.604, blue: 0.604))

        let light = Palette(look: PanelLook(ink: .dark))
        #expect(light.accent.ink == InkColor(red: 0.10, green: 0.36, blue: 0.62))
        #expect(light.ok.ink == InkColor(red: 0.09, green: 0.45, blue: 0.28))
        #expect(light.warn.ink == InkColor(red: 0.55, green: 0.36, blue: 0.05))
        #expect(light.crit.ink == InkColor(red: 0.63, green: 0.13, blue: 0.13))
    }

    @Test("the marks that used to be thinned at the call site are thinned here")
    func derivedMarksUnchanged() {
        let p = Palette(look: PanelLook(ink: .light))

        #expect(p.sparkline.ink == p.accent.ink)
        #expect(p.sparkline.alpha == 0.75)
        #expect(p.grip.alpha == 0.25)
        #expect(p.gripHover.alpha == 0.9)
        #expect(p.chipFill(for: .warn).ink == p.warn.ink)
        #expect(p.chipFill(for: .warn).alpha == 0.18)
        #expect(p.islandMark(for: .ok, placed: true).alpha == 1)
        #expect(p.islandMark(for: .ok, placed: false).alpha == 0.35)
        #expect(p.islandHalo.alpha == 0.55)
    }

    // MARK: - One place

    /// The property the fold exists for: colouring the ink colours the whole
    /// panel, not the text alone. Before this, a surface worked its own shade
    /// out from `foreground` at each call site — which happened to give the
    /// same answer, but only because every call site had been edited together.
    @Test("colouring the ink reaches every surface drawn in it")
    func inkColourReachesEverySurface() {
        let grey = Palette(look: PanelLook(ink: .light))
        let green = Palette(look: PanelLook(ink: .light, inkColor: InkColor(red: 0.2, green: 0.9, blue: 0.4)))

        // Everything written or ruled in the ink moves.
        #expect(green.text.ink != grey.text.ink)
        #expect(green.muted.ink != grey.muted.ink)
        #expect(green.dim.ink != grey.dim.ink)
        #expect(green.line.ink != grey.line.ink)
        #expect(green.recess.ink != grey.recess.ink)
        #expect(green.selection.ink != grey.selection.ink)
        #expect(green.subtleFill.ink != grey.subtleFill.ink)
        #expect(green.hover.ink != grey.hover.ink)
        #expect(green.hoverPressed.ink != grey.hoverPressed.ink)
        #expect(green.windowFill.ink != grey.windowFill.ink)
        #expect(green.panelBorder.ink != grey.panelBorder.ink)

        // And the strengths do not: the ink decides the colour, the table
        // decides how much of it there is.
        #expect(green.line.alpha == grey.line.alpha)
        #expect(green.recess.alpha == grey.recess.alpha)
    }

    /// The three that are deliberately not the ink, named so that a later
    /// change to any of them is a decision rather than an accident.
    @Test("the highlight and the halo stay out of the ink")
    func exceptionsAreDeliberate() {
        let green = Palette(look: PanelLook(ink: .light, inkColor: InkColor(red: 0.2, green: 0.9, blue: 0.4)))

        #expect(green.innerHighlight.ink == .white)
        #expect(green.islandHalo.ink == InkColor(red: 0, green: 0, blue: 0))
        // State colours are their own colours; a green ink does not make a
        // critical card green.
        #expect(green.crit.ink == InkColor(red: 1.0, green: 0.604, blue: 0.604))
    }

    @Test("the two ink directions do not draw the same panel")
    func inkDirectionsDiffer() {
        let onDark = Palette(look: PanelLook(ink: .light))
        let onLight = Palette(look: PanelLook(ink: .dark))
        #expect(onDark != onLight)
        #expect(onDark.text.ink != onLight.text.ink)
        #expect(onDark.accent.ink != onLight.accent.ink)
    }

    @Test("dimming the ink dims everything drawn in it, together")
    func brightnessMovesTheWholePalette() {
        let full = Palette(look: PanelLook(ink: .light, inkBrightness: 1))
        let half = Palette(look: PanelLook(ink: .light, inkBrightness: 0.5))

        #expect(half.text.ink.luminance < full.text.ink.luminance)
        #expect(half.muted.ink == half.text.ink)
        #expect(half.line.ink == half.text.ink)
        #expect(half.recess.ink == half.text.ink)
    }

    // MARK: - The panel's own colour

    /// It used to be a constant near-black, which meant that before macOS 26 —
    /// where this is the whole panel — every look was dark whatever had been
    /// chosen.
    @Test("the fallback panel follows the tint it is standing in for")
    func panelTintFollowsTheGlass() {
        let lightTint = Palette(look: PanelLook(
            glass: GlassAppearance(tinted: true, tintIsLight: true, tintStrength: 0.4), ink: .dark
        ))
        #expect(lightTint.panelTint.ink == InkColor(red: 1, green: 1, blue: 1))
        #expect(lightTint.panelTint.alpha == 0.4)

        let darkTint = Palette(look: PanelLook(
            glass: GlassAppearance(tinted: true, tintIsLight: false, tintStrength: 0.55), ink: .light
        ))
        #expect(darkTint.panelTint.ink == InkColor(red: 0, green: 0, blue: 0))
        #expect(darkTint.panelTint.alpha == 0.55)
    }

    @Test("an untinted look still has a panel to fall back to")
    func untintedPanelFollowsTheInk() {
        let onDark = Palette(look: PanelLook(glass: GlassAppearance(tinted: false), ink: .light))
        #expect(onDark.panelTint.ink == InkColor(red: 0, green: 0, blue: 0))
        #expect(onDark.panelTint.alpha == 0.62)

        let onLight = Palette(look: PanelLook(glass: GlassAppearance(tinted: false), ink: .dark))
        #expect(onLight.panelTint.ink == .white)
    }

    // MARK: - Nothing it produces can be undrawable

    @Test("every entry of every shipped look is a colour that can be drawn", arguments: PanelMode.allCases)
    func everyPresetIsDrawable(mode: PanelMode) {
        for brightness in [0.0, 0.5, 1.0] {
            var look = mode.look
            look.inkBrightness = brightness
            check(Palette(look: look))
        }
    }

    /// The hostile case: a settings file edited by hand into nonsense still has
    /// to produce a panel somebody can look at, because the alternative is an
    /// application that will not draw.
    @Test("a look validated out of nonsense still yields drawable colours")
    func nonsenseStillDraws() {
        let broken = PanelLook(
            glass: GlassAppearance(opacity: .nan, tintStrength: 42),
            ink: .light,
            inkBrightness: -7,
            inkColor: InkColor(red: .infinity, green: -3, blue: .nan)
        ).validated()
        check(Palette(look: broken))
    }

    private func check(_ p: Palette, sourceLocation: SourceLocation = #_sourceLocation) {
        let entries: [(String, PaletteColor)] = [
            ("panelTint", p.panelTint), ("windowFill", p.windowFill), ("recess", p.recess),
            ("selection", p.selection), ("subtleFill", p.subtleFill), ("hover", p.hover),
            ("hoverPressed", p.hoverPressed), ("line", p.line), ("panelBorder", p.panelBorder),
            ("innerHighlight", p.innerHighlight), ("text", p.text), ("muted", p.muted),
            ("dim", p.dim), ("accent", p.accent), ("ok", p.ok), ("warn", p.warn),
            ("crit", p.crit), ("sparkline", p.sparkline), ("grip", p.grip),
            ("gripHover", p.gripHover), ("islandHalo", p.islandHalo),
        ]
        + CardState.allCases.map { ("state.\($0.rawValue)", p.color(for: $0)) }
        + CardState.allCases.map { ("chip.\($0.rawValue)", p.chipFill(for: $0)) }
        + CardIcon.allCases.map { ("icon.\($0.rawValue)", p.color(for: $0)) }

        for (name, c) in entries {
            #expect((0 ... 1).contains(c.alpha), "\(name) alpha \(c.alpha)", sourceLocation: sourceLocation)
            #expect((0 ... 1).contains(c.ink.red), "\(name) red \(c.ink.red)", sourceLocation: sourceLocation)
            #expect((0 ... 1).contains(c.ink.green), "\(name) green \(c.ink.green)", sourceLocation: sourceLocation)
            #expect((0 ... 1).contains(c.ink.blue), "\(name) blue \(c.ink.blue)", sourceLocation: sourceLocation)
        }
    }
}
