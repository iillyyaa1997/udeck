import Foundation
import Testing
@testable import UDeckCore

/// The island fading back while nobody is using it.
///
/// One number and one rule, which is exactly why it is worth pinning down: the
/// rule is about to be generalised into per-state looks, and these tests are
/// what says the generalisation still does what was asked for.
@Suite("Island quiet")
struct IslandQuietTests {

    // MARK: - Which phases it touches

    @Test("only the collapsed island fades")
    func onlyCollapsed() {
        let quiet = IslandQuiet(enabled: true, level: 0.3)
        #expect(quiet.opacity(for: .collapsed) == 0.3)
        #expect(quiet.opacity(for: .peek) == 1)
        #expect(quiet.opacity(for: .open) == 1)
        #expect(quiet.opacity(for: .fullscreen) == 1)
    }

    /// The surrounding is deliberately absent from the question: the operator
    /// asked for the same thing over a game, over a film and over the desktop,
    /// so there is no second argument to get wrong.
    @Test("switched off, nothing fades in any phase")
    func offMeansNothing() {
        let quiet = IslandQuiet(enabled: false, level: 0.3)
        for phase in PanelPhase.allCases {
            #expect(quiet.opacity(for: phase) == 1)
        }
    }

    // MARK: - A file edited by hand

    @Test("a level outside the range is brought inside it")
    func levelClamped() {
        #expect(IslandQuiet(enabled: true, level: 0).opacity(for: .collapsed) == IslandQuiet.levelRange.lowerBound)
        #expect(IslandQuiet(enabled: true, level: -4).opacity(for: .collapsed) == IslandQuiet.levelRange.lowerBound)
        #expect(IslandQuiet(enabled: true, level: 7).opacity(for: .collapsed) == 1)
        #expect(IslandQuiet(enabled: true, level: .nan).opacity(for: .collapsed) == IslandQuiet.levelRange.lowerBound)
    }

    /// Zero is not allowed on purpose. An island at zero cannot be found with
    /// the pointer, and finding it with the pointer is how it comes back.
    @Test("the floor keeps the island reachable")
    func floorIsAboveZero() {
        #expect(IslandQuiet.levelRange.lowerBound > 0)
    }

    @Test("validated() clamps what the settings file carries")
    func settingsValidationClamps() {
        var settings = AppSettings()
        settings.quiet = IslandQuiet(enabled: true, level: 12)
        #expect(settings.validated().quiet.level == 1)

        settings.quiet = IslandQuiet(enabled: true, level: -1)
        #expect(settings.validated().quiet.level == IslandQuiet.levelRange.lowerBound)
    }

    // MARK: - Which way it is going

    @Test("coming back is quicker than going away")
    func asymmetricTiming() {
        #expect(IslandQuiet.duration(reaching: 1) == IslandQuiet.wakeDuration)
        #expect(IslandQuiet.duration(reaching: 0.3) == IslandQuiet.fadeDuration)
        #expect(IslandQuiet.wakeDuration < IslandQuiet.fadeDuration)
    }

    // MARK: - Settings files that predate it

    @Test("a settings file without the setting loads with it off")
    func missingKeyMeansOff() throws {
        let json = Data(#"{ "version": 1, "density": "compact" }"#.utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: json)
        #expect(settings.quiet.enabled == false)
        #expect(settings.quiet.opacity(for: .collapsed) == 1)
    }

    @Test("a settings file that says only half of it keeps the other default")
    func partialKeys() throws {
        let json = Data(#"{ "quiet": { "enabled": true } }"#.utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: json)
        #expect(settings.quiet.enabled)
        #expect(settings.quiet.level == IslandQuiet().level)
    }

    @Test("what is written is what comes back")
    func roundTrips() throws {
        var settings = AppSettings()
        settings.quiet = IslandQuiet(enabled: true, level: 0.45)
        let data = try JSONEncoder().encode(settings)
        let back = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(back.quiet == settings.quiet)
    }
}
