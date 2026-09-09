import Foundation
import Testing
@testable import UDeckCore

/// How big the panel's text is, apart from how much fits on it.
///
/// The two used to be one control with three steps, and the top step was still
/// small. They are different questions and now have different answers.
@Suite("Text size")
struct TextSizeTests {

    @Test("untouched, the density still decides", arguments: Density.allCases)
    func defaultsToDensity(density: Density) {
        var settings = AppSettings()
        settings.density = density
        #expect(settings.textSize == nil)
        #expect(settings.resolvedTextSize == density.bodyFontSize)
    }

    /// A settings file must say nothing about a control nobody has moved, so
    /// that a later change to what the densities mean still reaches an install
    /// that already exists.
    @Test("an unset size leaves nothing in the settings file")
    func unsetWritesNothing() throws {
        let written = try JSONEncoder().encode(AppSettings())
        let json = try #require(String(data: written, encoding: .utf8))
        #expect(!json.contains("textSize"))
    }

    @Test("a chosen size overrides the density and survives a round trip")
    func chosenSizeIsKept() throws {
        var settings = AppSettings()
        settings.density = .compact
        settings.textSize = 16
        #expect(settings.resolvedTextSize == 16)

        let read = try JSONDecoder().decode(
            AppSettings.self, from: try JSONEncoder().encode(settings)
        )
        #expect(read.textSize == 16)
        #expect(read.resolvedTextSize == 16)
    }

    /// The settings file is edited by hand at two in the morning; a size of
    /// 400 pt or of NaN has to come back as a panel somebody can look at.
    @Test("a size outside the range, or not a number, is brought back in")
    func nonsenseIsClamped() {
        var settings = AppSettings()
        settings.textSize = 400
        #expect(settings.resolvedTextSize == AppSettings.textSizeRange.upperBound)

        settings.textSize = 1
        #expect(settings.resolvedTextSize == AppSettings.textSizeRange.lowerBound)

        // Not-a-number is not a size that was clamped too far — it is not a
        // size at all, so it falls back to the density rather than being
        // rounded into the range and presented as a choice somebody made.
        settings.textSize = .nan
        #expect(settings.resolvedTextSize == settings.density.bodyFontSize)

        settings.textSize = .infinity
        #expect(settings.resolvedTextSize == settings.density.bodyFontSize)
    }

    /// The whole point of the setting: the size the operator wanted was above
    /// what any density offered.
    @Test("the range reaches past the largest density")
    func rangeCoversWhatDensityCannot() {
        let largest = Density.allCases.map(\.bodyFontSize).max()!
        #expect(AppSettings.textSizeRange.upperBound > largest)
        #expect(AppSettings.textSizeRange.lowerBound <= Density.allCases.map(\.bodyFontSize).min()!)
    }

    /// Density keeps owning the spacings. If moving the text size moved the
    /// padding too, the two controls would be one control again.
    @Test("the text size does not touch the spacings", arguments: Density.allCases)
    func spacingsBelongToDensity(density: Density) {
        var settings = AppSettings()
        settings.density = density
        let before = (density.panelPadding, density.gridSpacing,
                      density.windowPadding, density.rowSpacing)
        settings.textSize = 18
        #expect(before == (settings.density.panelPadding, settings.density.gridSpacing,
                           settings.density.windowPadding, settings.density.rowSpacing))
    }
}
