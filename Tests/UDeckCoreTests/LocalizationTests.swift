import Foundation
import Testing
@testable import UDeckCore

/// What the compiler cannot check about a translation.
///
/// It already checks the important thing — a `Vocabulary` whose `switch` misses
/// a phrase does not build, so no language can ship with a hole in it. What is
/// left is everything about the *content* of a phrase: that it says something,
/// that it is not the English still sitting there untranslated, and that a
/// sentence built from numbers still contains its numbers.
@Suite("Localization")
struct LocalizationTests {

    /// Every phrase, with a value in each hole.
    ///
    /// Written out rather than derived, because `Phrase` carries associated
    /// values and so cannot be `CaseIterable`. The division of labour: the
    /// compiler guarantees each *vocabulary* is complete — a `switch` missing a
    /// phrase does not build — and this list drives the checks on what the
    /// phrases actually say.
    ///
    /// It is maintained by hand, and nothing can make it otherwise. A phrase
    /// added to `Phrase` and left out of here is translated (the compiler saw to
    /// that) but unchecked: nobody has verified the Russian is not a copy of the
    /// English. The count below is a reminder, not a proof.
    static let all: [Phrase] = [
        .menuShowPanel, .menuRefreshAll, .menuSettings, .menuOpenPluginsFolder,
        .menuCopyDiagnostics, .menuQuit,

        .settingsWindowTitle, .sectionGeneral, .sectionOpening, .sectionLook, .sectionPlugins,
        .sectionAbout,

        .openingGesture, .openingGestureToggle, .openingPauseFirst, .openingPushPast,
        .openingStayQuiet, .openingShortcut, .openingShortcutToggle, .openingKeys,
        .openingNeedsModifier, .openingAlso, .openingRetract, .openingFullscreen,
        .openingKeepPolling, .openingPermissions,

        .lookLightLook, .lookDarkLook, .lookCustom, .lookBuiltIn, .lookSaved, .lookShows,
        .lookLight, .lookDark, .lookLightFromHour(7), .lookDarkFromHour(19), .lookGlass,
        .glassRegular, .glassClear, .lookTintCoversMaterial(percent: 58), .lookAmount,
        .lookTint, .tintLighter, .tintDarker, .lookStrength, .lookText, .lookBrightness,
        .lookColour, .lookDensity, .densityCompact, .densityNormal, .densityCozy,
        .lookLanguage, .languageSystem, .lookNameThisLook,

        .sampleTitle, .sampleChip, .sampleBody, .sampleFooter,

        .modeLight, .modeDark, .modeContrast, .modeGhost, .modePaper, .modeSmoke,

        .sourceSystem, .sourceManual, .sourceSchedule,

        .pluginsInstalled, .pluginsOpenFolder, .pluginsLookAgain, .pluginsNothingInstalled,
        .pluginsStaleness(seconds: 60, multiplier: 3), .pluginEnabled, .pluginMore,
        .pluginLess, .pluginSettings, .pluginEverySeconds(30),
        .pluginLastFailure(reason: "exit 1"), .permissionsAsksNothing, .permissionsAsksTo,
        .permissionsDeclared, .permissionsDeclaredHelp,
        .permissionsPluginAsksTo(name: "claude-sessions"), .permissionsUnsandboxed,
        .permissionsAllowAndRun,

        .capabilityRead(glob: "~/notes/*"), .capabilityWrite(glob: "/tmp/*"),
        .capabilityExec(command: "git"), .capabilityNetwork(host: "example.com"),
        .capabilityScreen, .capabilitySecret(name: "token"),

        .aboutTitle, .aboutTagline, .aboutThisBuild, .aboutNotSigned, .aboutAdHoc,
        .aboutNotSandboxed, .aboutReadPermissions, .aboutProblems,

        .deckNothingPlaced, .deckNothingOwn, .deckClickToWork, .cardRefreshNow,
        .cardRemoveFromTab, .cardDragToMove, .cardDragToResize, .cardOwnDrawing,
        .cardKindNotDrawn(kind: "svg"), .cardUnsupportedRow(kind: "sankey"),
        .emptyNoPlugins, .emptyTabEmpty, .emptyNoPluginsBody(path: "~/.udeck/plugins"),
        .emptyTabEmptyBody, .emptyOpenPluginsFolder, .emptyLookAgain, .emptyAdd,
        .islandNothingPlaced, .islandWorstState("warn"),

        .tabName, .tabAdd, .tabRename, .tabClose, .tabClickAgainToRename, .tabShowThis,
        .controlDensity(name: "Normal"), .controlRefresh, .controlSettings, .controlSendAway,

        .actionSave, .actionUse, .actionDelete, .actionAllow, .actionDecline,
        .actionRun, .actionCancel, .actionClear,

        .unitMilliseconds(60), .unitPoints(24), .unitSeconds(0.1), .unitPercent(58),
    ]

    /// The size of the list, written down.
    ///
    /// This does not prove the list covers `Phrase` — an enum's cases cannot be
    /// counted at runtime once they carry values, so no test can. What it does
    /// is make the list's length a thing somebody has to look at: a phrase
    /// deleted from here in passing fails, and a person adding a phrase to
    /// `Phrase` who runs the tests reads a message telling them where to put it.
    @Test("the checked list is the size it was left at")
    func listIsIntact() {
        #expect(Self.all.count == 141,
                "Phrase has changed. Add the new phrase to LocalizationTests.all and update this count.")
        #expect(Set(Self.all.map(String.init(describing:))).count == Self.all.count,
                "a phrase is listed twice")
    }

    @Test("every language says something for every phrase", arguments: Language.allCases)
    func nothingIsEmpty(language: Language) {
        let strings = Strings(language)
        for phrase in Self.all {
            let text = strings(phrase)
            #expect(!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    "\(language.rawValue) has nothing for \(phrase)")
        }
    }

    /// The failure this catches is a real one and it is quiet: a phrase added to
    /// `Phrase` and filled in properly in English gets a copy-pasted English
    /// line in every other language to make the build pass, and the operator
    /// finds it months later.
    @Test("Russian is not English with the switch renamed")
    func russianIsTranslated() {
        let english = Strings(.english)
        let russian = Strings(.russian)

        /// The ones that are the same in both on purpose: a product name, and a
        /// number with a unit that happens to be written the same way.
        let sharedOnPurpose: Set<String> = [
            String(describing: Phrase.aboutTitle),
            String(describing: Phrase.unitPercent(58)),
        ]

        for phrase in Self.all where !sharedOnPurpose.contains(String(describing: phrase)) {
            #expect(english(phrase) != russian(phrase),
                    "\(phrase) is still English in Russian")
        }
    }

    /// A sentence built around a number has to still contain it. Word order can
    /// move and the unit can change, but dropping the value turns "current for
    /// 60 s" into a sentence about nothing.
    @Test("values reach the sentences that carry them", arguments: Language.allCases)
    func valuesSurvive(language: Language) {
        let strings = Strings(language)

        #expect(strings(.lookLightFromHour(7)).contains("7"))
        #expect(strings(.lookDarkFromHour(19)).contains("19"))
        #expect(strings(.lookTintCoversMaterial(percent: 58)).contains("58"))
        #expect(strings(.pluginEverySeconds(30)).contains("30"))
        #expect(strings(.unitMilliseconds(60)).contains("60"))
        #expect(strings(.unitPoints(24)).contains("24"))
        #expect(strings(.unitSeconds(0.1)).contains("0"))
        #expect(strings(.unitPercent(58)).contains("58"))

        let staleness = strings(.pluginsStaleness(seconds: 60, multiplier: 3))
        #expect(staleness.contains("60"))
        #expect(staleness.contains("3"))

        #expect(strings(.capabilityExec(command: "git")).contains("git"))
        #expect(strings(.capabilityNetwork(host: "example.com")).contains("example.com"))
        #expect(strings(.capabilitySecret(name: "token")).contains("token"))
        #expect(strings(.permissionsPluginAsksTo(name: "claude-sessions")).contains("claude-sessions"))
        #expect(strings(.emptyNoPluginsBody(path: "~/.udeck/plugins")).contains("~/.udeck/plugins"))
        #expect(strings(.cardUnsupportedRow(kind: "sankey")).contains("sankey"))
        #expect(strings(.pluginLastFailure(reason: "exit 1")).contains("exit 1"))
        #expect(strings(.islandWorstState("warn")).contains("warn"))
        #expect(strings(.controlDensity(name: "Normal")).contains("Normal"))
    }

    /// A language list written in the language the reader is stuck in is no use
    /// to the person who needs to leave it.
    @Test("every language names itself in itself")
    func endonyms() {
        #expect(Language.english.endonym == "English")
        #expect(Language.russian.endonym == "Русский")
        #expect(Set(Language.allCases.map(\.endonym)).count == Language.allCases.count)
    }

    // MARK: - Choosing one

    @Test("the Mac's preference is matched on the language, not the region")
    func preferredIgnoresRegion() {
        #expect(Language.preferred(from: ["ru-RU"]) == .russian)
        #expect(Language.preferred(from: ["en-GB"]) == .english)
        #expect(Language.preferred(from: ["RU"]) == .russian)
    }

    @Test("the first language uDeck actually speaks wins, in the reader's order")
    func preferredHonoursOrder() {
        #expect(Language.preferred(from: ["de-DE", "ru-RU", "en-US"]) == .russian)
        #expect(Language.preferred(from: ["fr", "en"]) == .english)
    }

    @Test("a Mac set to nothing uDeck speaks falls back to English")
    func preferredFallsBack() {
        #expect(Language.preferred(from: ["ja-JP", "de-DE"]) == .english)
        #expect(Language.preferred(from: []) == .english)
        #expect(Language.preferred(from: ["", "-", "ru"]) == .russian)
    }

    // MARK: - The setting

    @Test("no choice means the Mac decides, and says nothing in the file")
    func unsetFollowsTheSystem() throws {
        let settings = AppSettings()
        #expect(settings.language == nil)
        #expect(settings.resolvedLanguage(systemPreferred: .russian) == .russian)
        #expect(settings.resolvedLanguage(systemPreferred: .english) == .english)

        let written = try JSONEncoder().encode(settings)
        let json = try #require(String(data: written, encoding: .utf8))
        #expect(!json.contains("language"),
                "an unset language should leave nothing in the settings file")
    }

    @Test("a choice overrides the Mac and survives a round trip")
    func chosenLanguageIsKept() throws {
        var settings = AppSettings()
        settings.language = .russian
        #expect(settings.resolvedLanguage(systemPreferred: .english) == .russian)

        let written = try JSONEncoder().encode(settings)
        let read = try JSONDecoder().decode(AppSettings.self, from: written)
        #expect(read.language == .russian)
    }

    /// Same tolerance as every other name in the settings file: a language this
    /// build no longer has costs the operator that one setting, not the file.
    @Test("a language this build does not have falls back rather than failing")
    func unknownLanguageFallsBack() throws {
        let json = Data(#"{"version":1,"language":"kl"}"#.utf8)
        let read = try JSONDecoder().decode(AppSettings.self, from: json)
        #expect(read.language == nil)
        #expect(read.resolvedLanguage(systemPreferred: .english) == .english)
    }
}
