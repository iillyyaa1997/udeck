import CoreGraphics
import Testing
@testable import UDeckCore

@Suite("A grid row's height")
struct GridRowsTests {
    /// 11-26: an 8-row card in cozy density at text size 13.5 — rows of 54 pt,
    /// 14 between — in some 510 points of panel: 22 points too tall, and its
    /// top or its bottom was cut off.
    @Test("a tab taller than the panel: its rows shrink so that all of it shows")
    func shrinks() {
        let height = GridRows.height(available: 510, rows: 8, nominal: 54, spacing: 14)
        #expect(height * 8 + 14 * 7 <= 510.0001)
        #expect(height * 8 + 14 * 7 > 509.99)
        #expect(height < 54)
    }

    @Test("a tab with room to spare: rows of the theme's height, stretched a little to fill the panel exactly")
    func fills() {
        let height = GridRows.height(available: 600, rows: 3, nominal: 54, spacing: 14)
        // (600 + 14) / (54 + 14) = 9.03: nine rows of the theme's fit.
        let shown = 9
        #expect(height >= 54)
        #expect(abs(height * CGFloat(shown) + 14 * CGFloat(shown - 1) - 600) < 0.0001)
    }

    @Test("a tab far taller than the panel stops shrinking at 60% of a row, and scrolls")
    func floor() {
        #expect(GridRows.height(available: 300, rows: 40, nominal: 54, spacing: 14) == 54 * 0.6)
    }

    @Test("nothing to measure yet: the theme's height")
    func unmeasured() {
        #expect(GridRows.height(available: 0, rows: 8, nominal: 54, spacing: 14) == 54)
    }
}
