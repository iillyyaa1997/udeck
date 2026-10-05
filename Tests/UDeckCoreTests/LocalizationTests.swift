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

        .generalStartup, .generalOpenAtLogin,
        .generalOpensWhich("/Applications/uDeck.app", opens: true),
        .generalOpensWhich("/Applications/uDeck.app", opens: false),
        .generalNotInstalled("/Users/x/udeck/.build/debug"),
        .generalRecordVanished, .generalDidNotTake, .generalAnotherCopy("/x/uDeck.app"),
        .generalWaitsForApproval, .generalLoginFailed("no"), .generalOpenLoginItems,

        .lookLightLook, .lookDarkLook, .lookCustom, .lookPresets, .lookBuiltIn, .lookSaved, .lookShows,
        .lookLight, .lookDark, .lookLightFromHour(7), .lookDarkFromHour(19), .lookGlass,
        .glassRegular, .glassClear, .lookTintCoversMaterial(percent: 58), .lookAmount,
        .lookTint, .tintLighter, .tintDarker, .lookStrength, .lookTintColour, .lookText, .lookBrightness,
        .lookColour, .lookDensity, .lookTextSize, .densityCompact, .densityNormal, .densityCozy,
        .lookLanguage, .languageSystem, .lookNameThisLook,

        .sampleTitle, .sampleChip, .sampleBody, .sampleFooter,

        .modeLight, .modeDark, .modeContrast, .modeGhost, .modePaper, .modeSmoke,
        .modeLightSummary, .modeDarkSummary, .modeContrastSummary,
        .modeGhostSummary, .modePaperSummary, .modeSmokeSummary,

        .sourceSystem, .sourceManual, .sourceSchedule,

        .pluginsInstalled, .pluginsOpenFolder, .pluginsLookAgain, .pluginsNothingInstalled,
        .pluginsStaleness(seconds: 60, multiplier: 3), .pluginEnabled, .pluginMore,
        .pluginLess, .pluginSettings, .pluginEverySeconds(30),
        .pluginLastFailure(reason: .exited(code: 1)), .permissionsAsksNothing, .permissionsAsksTo,
        .permissionsDeclared, .permissionsDeclaredHelp,
        .permissionsPluginAsksTo(name: "disk-space"), .permissionsUnsandboxed,
        .permissionsAllowAndRun,

        .pluginsOfficialCatalogue, .pluginsOfficialCatalogueHelp(source: "github.com/o/r"),
        .catalogueCheckNow, .catalogueChecked(source: "github.com/o/r", at: "14:02"),
        .catalogueNeverRead(source: "github.com/o/r"), .catalogueReading, .catalogueOff, .catalogueEmpty,
        .catalogueUpdatesWaiting(2),
        .catalogueLimited(readAt: "14:02", until: "15:07"), .catalogueRawLimited(until: "15:07"),
        .catalogueUnreachable(reason: "offline", readAt: "14:02"), .catalogueNotFound(source: "github.com/o/r"),
        .catalogueNotARepository(source: "github.com/o/r", branch: "main"), .catalogueFutureFormat(declared: 2),
        .catalogueInvalidPassport(source: "github.com/o/r", reason: "no name"), .catalogueRefused(status: 451),
        .catalogueBadAnswer(reason: "garbled"),
        .catalogueArrivedDifferent(path: "udeck-plugins.json", expected: "1a2b3c4", got: "5d6e7f8"),
        .catalogueVerified, .catalogueSize(files: 4, size: "6 KB"), .catalogueAsksTo("run sysctl"),
        .catalogueInstall, .catalogueUpdate, .catalogueReplace, .catalogueInstalled,
        .catalogueAvailable(version: "1.3.0"), .catalogueChangedStill(version: "1.2.0"),
        .catalogueRepositoryNowHas(version: "1.1.0"), .catalogueSwitchTo(version: "1.1.0"),
        .catalogueUpdateNeedsAPI(version: "2.0.0", api: 2), .catalogueUpdateNeedsUDeck(version: "1.3.0", required: "0.8.0"),
        .catalogueUpdateCannotInstall(version: "1.3.0"), .catalogueGone, .catalogueOwnFolder(id: "uptime"),
        .catalogueMissing(id: "uptime", path: "~/.udeck/plugins"), .catalogueReinstall(version: "1.2.0"),
        .catalogueDetails, .catalogueWhatChanged, .catalogueOpenOnGitHub, .catalogueEarlierVersions,
        .catalogueBackTo(version: "1.0.0"), .catalogueRemove, .catalogueWorking,
        .catalogueReplaceConfirm(id: "uptime", path: "~/.udeck/plugins"),
        .catalogueUpdateOverChanges(id: "uptime", version: "1.3.0"),
        .catalogueRemoveConfirm(id: "uptime"), .catalogueRemoveOwnConfirm(id: "uptime"),
        .catalogueRefusal(.lfsPointer(path: "plugins/uptime/data.bin")),
        .catalogueFileUnreachable(path: "plugins/uptime/uptime.sh", reason: "offline"),
        .catalogueTookTooLong, .catalogueCannotWrite(reason: "disk full"),
        .catalogueRecordsBroken(reason: "not JSON"),
        .pluginMarkVerified, .pluginMarkOwnFolder, .pluginMarkModified, .pluginMarkMissing,
        .pluginFrom(source: "github.com/o/r", commit: "5c3e0d2"), .pluginPinned,
        .historyTitle(name: "uptime"), .historyReading, .historyNone, .historyInstalledMark, .historyInstall,
        .historyFailed,
        .windowNotInPluginsFolder(id: "uptime", path: "~/.udeck/plugins"), .windowWillNotRun(id: "uptime"),
        .windowReinstall,

        .pluginLastRun(at: "21:04:05", reason: .interval, duration: 0.21, result: .card),
        .pluginLastRun(at: "21:04:05", reason: .launch, duration: 0.21, result: .failure(.exited(code: 3))),
        .pluginLastRun(at: "21:04:05", reason: .manual, duration: 2, result: .lateCard(.timedOut(after: 2))),
        .failureReason(.timedOut(after: 2)), .failureReason(.timedOut(after: 0.5)), .failureReason(.exited(code: 3)),
        .failureReason(.signalled(signal: 9)), .failureReason(.launchFailed("No such file or directory")),
        .failureReason(.outputLimitExceeded(bytes: 1_048_576)), .failureReason(.emptyOutput),
        .failureReason(.unparsableOutput("\"rows\" is required")), .failureReason(.notPermitted(.allowed)),
        .failureReason(.notPermitted(.disabled)), .failureReason(.notPermitted(.awaitingDecision(pending: [.exec("git")]))),
        .failureReason(.notPermitted(.refused(denied: [.screen]))), .failureReason(.notLoadable([.missingManifest])),
        .pluginStandardErrorEnd, .pluginStandardErrorNothing, .pluginStandardErrorBefore(bytes: 1834),
        .catalogueReplaceLinkConfirm(id: "uptime", target: "~/src/uptime"),
        .catalogueRemoveLinkConfirm(id: "uptime", target: "~/src/uptime"), .catalogueLinkedHere(id: "uptime"),
        .pluginMarkLinked, .pluginLinkedTo(path: "~/src/uptime"), .pluginLinkNotFollowed(destination: "../gone"),
        .linkFolder, .linkFolderPanelMessage, .linkFolderLink,
        .linkFolderLinked(id: "uptime", target: "~/src/uptime"), .linkFolderAlready(id: "uptime", target: "~/src/uptime"),
        .linkFolderOverInstalled(id: "uptime", source: "github.com/o/r", folder: "~/src/uptime", toTrash: false),
        .linkFolderOverInstalled(id: "uptime", source: "github.com/o/r", folder: "~/src/uptime", toTrash: true),
        .linkFolderOverOwn(id: "uptime", path: "~/.udeck/plugins", folder: "~/src/uptime", toTrash: true),
        .linkFolderOverOwn(id: "uptime", path: "~/.udeck/plugins", folder: "~/src/uptime", toTrash: false),
        .linkFolderOverLink(id: "uptime", destination: "/work/old", folder: "~/src/uptime"),
        .linkFolderRefused(.busy), .linkFolderRefused(.recordsBroken("not JSON")), .linkFolderRefused(.failed("disk full")),
        .linkFolderRefused(.folder(.notThere(folder: "/x/uptime"))),
        .linkFolderRefused(.folder(.notAFolder(folder: "/x/uptime.zip"))),
        .linkFolderRefused(.folder(.insideUDeck(folder: "/u/.udeck/mine", udeck: "/u/.udeck"))),
        .linkFolderRefused(.folder(.holdsUDeck(folder: "/u", udeck: "/u/.udeck"))),
        .linkFolderRefused(.folder(.noManifest(folder: "/x/uptime"))),
        .linkFolderRefused(.folder(.manifestUnreadable(manifest: "/x/uptime/manifest.json", detail: "\"run\" is required"))),
        .linkFolderRefused(.folder(.recordsUnreadable(file: "/u/.udeck/installed.json", detail: "it ends early"))),
        .linkFolderRefused(.folder(.taken(link: "/u/.udeck/plugins/uptime"))),
        .linkFolderRefused(.folder(.cannotLink(link: "/u/.udeck/plugins/uptime", detail: "read-only"))),
        .runLogSwitch, .runLogHelp(path: "~/.udeck/logs"), .runLogShow,
        .searchPathTitle, .searchPathHelp, .searchPathAdd, .searchPathPanelMessage, .searchPathPanelAdd,
        .searchPathRemove, .searchPathKeepOne, .searchPathUp, .searchPathDown, .searchPathRestore,
        .searchPathStanding(.lookedIn), .searchPathStanding(.notThere), .searchPathStanding(.notAFolder),
        .searchPathStanding(.notAFullPath),
        .commandTitle, .commandInstall, .commandRemove, .commandInstalled(path: "~/.local/bin/udeck-plugin"),
        .commandNotInstalled(path: "~/.local/bin/udeck-plugin"),
        .commandOtherCopy(path: "~/.local/bin/udeck-plugin", target: "/Old/uDeck.app/Contents/Helpers/udeck-plugin"),
        .commandForeign(path: "~/.local/bin/udeck-plugin", what: .file),
        .commandForeign(path: "~/.local/bin/udeck-plugin", what: .folder),
        .commandForeign(path: "~/.local/bin/udeck-plugin", what: .link(to: "/opt/other/udeck-plugin")),
        .commandNoHelper, .commandOnPath(folder: "~/.local/bin"),
        .commandNotLasting(.lasting), .commandNotLasting(.translocated),
        .commandNotLasting(.diskImage(volume: "/Volumes/uDeck")),
        .commandNotOnPath(folder: "~/.local/bin", shell: "zsh", file: "~/.zshrc"),
        .commandPathUnknown(folder: "~/.local/bin"), .commandCouldNot(reason: "read-only"),
        .cardLastRunFailed(at: "21:04", reason: .exited(code: 3)), .cardShowingValuesFrom("21:03"),
        .cardLastRunFailedDot,

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
        .controlRefresh, .controlSettings, .controlSendAway,

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
        #expect(Self.all.count == 312,
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
        #expect(strings(.permissionsPluginAsksTo(name: "disk-space")).contains("disk-space"))
        #expect(strings(.emptyNoPluginsBody(path: "~/.udeck/plugins")).contains("~/.udeck/plugins"))
        #expect(strings(.cardUnsupportedRow(kind: "sankey")).contains("sankey"))
        #expect(strings(.pluginLastFailure(reason: .exited(code: 1))).contains(strings(.failureReason(.exited(code: 1)))))
        #expect(strings(.islandWorstState("warn")).contains("warn"))
        // The path is the actionable half of this one: "some copy of uDeck is not
        // installed" leaves the reader to guess which window they are looking at.
        #expect(strings(.generalNotInstalled("/x/.build/debug")).contains("/x/.build/debug"))
    }

    /// The repository's sentences carry what the operator acts on: the version,
    /// the path, the time.
    @Test("the catalogue's sentences keep their values", arguments: Language.allCases)
    func catalogueValuesSurvive(language: Language) {
        let strings = Strings(language)
        let checked = strings(.catalogueChecked(source: "github.com/o/r", at: "14:02"))
        #expect(checked.contains("github.com/o/r") && checked.contains("14:02"))
        let limited = strings(.catalogueLimited(readAt: "14:02", until: "15:07"))
        #expect(limited.contains("14:02") && limited.contains("15:07") && limited.contains("60"))
        #expect(!strings(.catalogueLimited(readAt: nil, until: "15:07")).contains("nil"))
        #expect(strings(.catalogueAvailable(version: "1.3.0")).contains("1.3.0"))
        #expect(strings(.catalogueChangedStill(version: "1.2.0")).contains("1.2.0"))
        #expect(strings(.catalogueUpdateNeedsUDeck(version: "1.3.0", required: "0.8.0")).contains("0.8.0"))
        #expect(strings(.catalogueUpdateNeedsAPI(version: "2.0.0", api: 2)).contains("api 2"))
        #expect(strings(.catalogueReplaceConfirm(id: "uptime", path: "~/.udeck/plugins")).contains("~/.udeck/plugins"))
        #expect(strings(.catalogueMissing(id: "uptime", path: "~/.udeck/plugins")).contains("uptime"))
        #expect(strings(.windowNotInPluginsFolder(id: "uptime", path: "~/.udeck/plugins")).contains("~/.udeck/plugins"))
        #expect(strings(.catalogueSize(files: 4, size: "6 KB")).contains("4"))
        let different = strings(.catalogueRefusal(.arrivedDifferent(path: "plugins/uptime/uptime.sh",
                                                                    expected: "1a2b3c4", got: "5d6e7f8")))
        #expect(different.contains("plugins/uptime/uptime.sh") && different.contains("1a2b3c4")
                && different.contains("5d6e7f8"))
        let large = strings(.catalogueRefusal(.tooLarge(id: "uptime", bytes: 14 * 1024 * 1024, files: 312)))
        #expect(large.contains("14") && large.contains("312") && large.contains("200"))
    }

    /// What C2b's sentences carry is what the operator acts on: the folder, the
    /// time, the line to add — and what goes where: of a link, only the link.
    @Test("linked folders, the run log, the last run, the search path and the command say what they carry",
          arguments: Language.allCases)
    func plugInSentencesSurvive(language: Language) {
        let strings = Strings(language)
        let trash = language == .russian ? "Корзин" : "Trash"

        let removeLink = strings(.catalogueRemoveLinkConfirm(id: "uptime", target: "~/src/uptime"))
        #expect(removeLink.contains("uptime") && removeLink.contains("~/src/uptime") && !removeLink.contains(trash))
        #expect(removeLink.contains(language == .russian ? "только ссылка" : "Only the link goes"))
        let replaceLink = strings(.catalogueReplaceLinkConfirm(id: "uptime", target: "~/src/uptime"))
        #expect(replaceLink.contains("~/src/uptime") && !replaceLink.contains(trash))

        let overInstalled = strings(.linkFolderOverInstalled(id: "uptime", source: "github.com/o/r", folder: "~/src/uptime",
                                                             toTrash: false))
        #expect(overInstalled.contains("github.com/o/r") && overInstalled.contains("~/src/uptime") && !overInstalled.contains(trash))
        #expect(strings(.linkFolderOverInstalled(id: "uptime", source: "github.com/o/r", folder: "~/src/uptime", toTrash: true))
            .contains(trash))
        #expect(strings(.linkFolderOverOwn(id: "uptime", path: "~/.udeck/plugins", folder: "~/src/uptime", toTrash: true))
            .contains(trash))
        #expect(!strings(.linkFolderOverOwn(id: "uptime", path: "~/.udeck/plugins", folder: "~/src/uptime", toTrash: false))
            .contains(trash))
        let overLink = strings(.linkFolderOverLink(id: "uptime", destination: "/work/old", folder: "~/src/uptime"))
        #expect(overLink.contains("/work/old") && overLink.contains("~/src/uptime") && !overLink.contains(trash))
        #expect(strings(.pluginLinkedTo(path: "~/src/uptime")).contains("~/src/uptime"))
        #expect(strings(.linkFolderLinked(id: "uptime", target: "~/src/uptime")).contains("~/src/uptime"))
        #expect(strings(.linkFolderRefused(.folder(.noManifest(folder: "/x/uptime")))).contains("/x/uptime"))
        #expect(strings(.linkFolderRefused(.folder(.manifestUnreadable(manifest: "/x/m.json", detail: "\"run\" is required"))))
            .contains("\"run\" is required"))

        let ran = strings(.pluginLastRun(at: "21:04:05", reason: .interval, duration: 0.21,
                                         result: .failure(.exited(code: 3))))
        let exited = strings(.failureReason(.exited(code: 3)))
        #expect(ran.contains("21:04:05") && ran.contains(language == .russian ? "0,21 с" : "0.21 s") && ran.contains(exited))
        #expect(strings(.pluginStandardErrorBefore(bytes: 1834)).contains("1834"))
        let failed = strings(.cardLastRunFailed(at: "21:04", reason: .exited(code: 3)))
        #expect(failed.contains("21:04") && failed.contains(exited))
        let late = strings(.pluginLastRun(at: "21:04:05", reason: .manual, duration: 2, result: .lateCard(.timedOut(after: 2))))
        #expect(late.contains(strings(.failureReason(.timedOut(after: 2)))))
        let notLasting = strings(.commandNotLasting(.diskImage(volume: "/Volumes/uDeck 0.5")))
        #expect(notLasting.contains("/Volumes/uDeck 0.5") && notLasting.contains(language == .russian ? "Программы" : "Applications"))
        #expect(strings(.commandNotLasting(.translocated)).contains(language == .russian ? "Программы" : "Applications"))
        #expect(strings(.cardShowingValuesFrom("21:03")).contains("21:03"))

        #expect(strings(.runLogHelp(path: "~/.udeck/logs")).contains("~/.udeck/logs/<id>.log"))
        #expect(strings(.searchPathHelp).contains("PATH") && strings(.searchPathHelp).contains("python3"))
        let notOnPath = strings(.commandNotOnPath(folder: "~/.local/bin", shell: "zsh", file: "~/.zshrc"))
        #expect(notOnPath.contains("~/.local/bin") && notOnPath.contains("zsh") && notOnPath.contains("~/.zshrc"))
        #expect(strings(.commandOtherCopy(path: "~/.local/bin/udeck-plugin", target: "/Old/uDeck.app"))
            .contains("/Old/uDeck.app"))
        #expect(strings(.commandForeign(path: "~/.local/bin/udeck-plugin", what: .link(to: "/opt/x")))
            .contains("/opt/x"))
    }

    /// Why a run failed is said in the operator's language, on the card and in
    /// Settings, with what it carries — the status, the signal, the seconds as
    /// the language writes them. English says the words `udeck-plugin run`
    /// prints. What the system or the plugin wrote is quoted as it was.
    @Test("why a run failed is said in each language, with what it carries", arguments: Language.allCases)
    func failureReasons(language: Language) {
        let strings = Strings(language)
        let reasons: [PluginFailure.Reason] = [
            .timedOut(after: 2), .timedOut(after: 0.5), .exited(code: 3), .signalled(signal: 9),
            .launchFailed("No such file or directory"), .outputLimitExceeded(bytes: 1_048_576), .emptyOutput,
            .unparsableOutput("\"rows\" is required"), .notPermitted(.allowed), .notPermitted(.disabled),
            .notPermitted(.awaitingDecision(pending: [.exec("git")])), .notPermitted(.refused(denied: [.screen])),
            .notLoadable([.missingManifest]),
        ]
        for reason in reasons {
            let said = strings(.failureReason(reason))
            if language == .english {
                #expect(said == reason.description, "English is what udeck-plugin run prints")
            } else {
                #expect(said != reason.description && !said.contains("the producer"), "\(reason) is English in \(language)")
            }
            #expect(strings(.pluginLastFailure(reason: reason)).contains(said))
            #expect(strings(.cardLastRunFailed(at: "21:04", reason: reason)).contains(said))
            #expect(strings(.pluginLastRun(at: "21:04:05", reason: .interval, duration: 1, result: .failure(reason))).contains(said))
        }
        #expect(strings(.failureReason(.exited(code: 3))).contains("3"))
        #expect(strings(.failureReason(.signalled(signal: 9))).contains("9"))
        #expect(strings(.failureReason(.outputLimitExceeded(bytes: 1_048_576))).contains("1048576"))
        #expect(strings(.failureReason(.timedOut(after: 0.5))).contains(language == .russian ? "0,5 с" : "0.5s"))
        #expect(strings(.failureReason(.timedOut(after: 2))).contains(language == .russian ? "2 с" : "2s"))
        #expect(strings(.failureReason(.launchFailed("No such file or directory"))).contains("No such file or directory"))
        #expect(strings(.failureReason(.unparsableOutput("\"rows\" is required"))).contains("\"rows\" is required"))
        #expect(strings(.failureReason(.notPermitted(.awaitingDecision(pending: [.exec("git")]))))
            .contains(strings(.capabilityExec(command: "git"))))
        #expect(strings(.failureReason(.notPermitted(.refused(denied: [.screen])))).contains(strings(.capabilityScreen)))
        #expect(strings(.pluginLastRun(at: "21:04:05", reason: .interval, duration: 0.01, result: .card))
            .contains(language == .russian ? "0,01 с" : "0.01 s"))
    }

    /// What came before the kept stderr is said as the contract says it:
    /// bytes that came before what uDeck kept — not before the lines shown,
    /// which are the end of what was kept.
    @Test("the bytes before the kept standard error are said as the contract says them")
    func bytesBeforeWhatWasKept() {
        let english = Strings(.english)
        #expect(english(.pluginStandardErrorBefore(bytes: 1834)) == "(1834 bytes came before what uDeck kept)")
        #expect(english(.pluginStandardErrorBefore(bytes: 1)) == "(1 byte came before what uDeck kept)")
        #expect(Strings(.russian)(.pluginStandardErrorBefore(bytes: 1834)) == "(до того, что сохранил uDeck, было ещё 1834 Б)")
    }

    /// Where docs/plugin-repository.md gives the words, uDeck says exactly them.
    @Test("the refusals in English are the specification's own sentences")
    func refusalsAreTheSpecification() {
        let english = Strings(.english)
        func say(_ refusal: RepositoryRefusal) -> String { english(.catalogueRefusal(refusal)) }
        #expect(say(.apiNotSpoken(name: "uptime", version: "2.0.0", api: 2))
                == "uptime 2.0.0 is written for plugin contract api 2; this uDeck speaks api 1. Update uDeck to install it.")
        #expect(say(.needsNewerUDeck(name: "uptime", version: "1.4.0", required: "0.8.0", running: "0.6.0"))
                == "uptime 1.4.0 needs uDeck 0.8.0 or later; this is uDeck 0.6.0. Update uDeck (Settings → About) to install it.")
        #expect(say(.versionNotComparable(name: "uptime", version: "1.2"))
                == "uptime's version \"1.2\" is not MAJOR.MINOR.PATCH, so uDeck cannot tell it from another version; it cannot be installed from a repository.")
        #expect(say(.linkOrSubmodule(path: "plugins/uptime/lib", isLink: true))
                == "plugins/uptime/lib is a symbolic link; a plugin from a repository may contain only files and folders.")
        #expect(say(.arrivedDifferent(path: "plugins/uptime/uptime.sh", expected: "1a2b3c4", got: "5d6e7f8"))
                == "plugins/uptime/uptime.sh arrived different from what the repository lists (expected 1a2b3c4, got 5d6e7f8); nothing was installed.")
        #expect(say(.folderDoesNotAddUp(id: "uptime"))
                == "The files of uptime do not add up to the folder the repository lists; nothing was installed.")
        #expect(say(.tooLarge(id: "uptime", bytes: 14 * 1024 * 1024, files: 312))
                == "uptime is 14 MB in 312 files; uDeck installs plugins of up to 10 MB and 200 files.")
        #expect(say(.nameNotAllowed(path: "plugins/uptime/Run Me.sh"))
                == "plugins/uptime/Run Me.sh: names may use only letters, digits, \".\", \"_\" and \"-\", and may not start with \".\"")
        #expect(say(.lfsPointer(path: "plugins/uptime/data.bin"))
                == "plugins/uptime/data.bin is a Git LFS pointer, not the file; uDeck does not fetch LFS content.")
        #expect(say(.failsTheUsualChecks(id: "uptime", detail: "uptime.sh is not executable — try chmod +x"))
                == "uptime.sh is not executable — try chmod +x")
        #expect(english(.catalogueLimited(readAt: "14:02", until: "15:07"))
                == "GitHub allows 60 requests an hour from this network without signing in, and they are used up — by uDeck or by something else on the same connection. The list below is from 14:02; uDeck will look again after 15:07.")
        #expect(english(.catalogueUnreachable(reason: "offline", readAt: "14:02"))
                == "Could not reach GitHub: offline. The list below is from 14:02.")
        #expect(english(.catalogueNotFound(source: "github.com/owner/repo"))
                == "github.com/owner/repo could not be found, or it is private.")
        #expect(english(.catalogueNotARepository(source: "github.com/owner/repo", branch: "main"))
                == "github.com/owner/repo is not a uDeck plugin repository: there is no udeck-plugins.json at the top of main.")
        #expect(english(.catalogueFutureFormat(declared: 2))
                == "This repository is in format 2; this uDeck reads format 1. Update uDeck.")
        #expect(english(.catalogueChecked(source: "github.com/iillyyaa1997/udeck-plugins", at: "14:02"))
                == "github.com/iillyyaa1997/udeck-plugins · checked 14:02")
        #expect(english(.catalogueReplaceConfirm(id: "uptime", path: "~/.udeck/plugins"))
                == "A folder of your own named uptime is in ~/.udeck/plugins. Installing moves it to the Trash and puts the repository's uptime in its place.")
        #expect(english(.catalogueUpdateOverChanges(id: "uptime", version: "1.3.0"))
                == "Your changes to uptime will be moved to the Trash and replaced with 1.3.0.")
        #expect(english(.windowNotInPluginsFolder(id: "uptime", path: "~/.udeck/plugins"))
                == "uptime is not in ~/.udeck/plugins")
    }

    /// Every refusal has something to say in every language, and says the path.
    @Test("every refusal is said in every language", arguments: Language.allCases)
    func everyRefusalIsSaid(language: Language) {
        let strings = Strings(language)
        let path = "plugins/x/y.sh"
        let all: [RepositoryRefusal] = [
            .folderNameNotAnID(folder: "X"), .noManifest(path: path), .manifestUnreadable(path: path, detail: "d"),
            .manifestIDMismatch(declared: "a", folder: "b"), .manifestProblem(id: "x", detail: "d"),
            .apiNotSpoken(name: "x", version: "1.0.0", api: 2),
            .needsNewerUDeck(name: "x", version: "1.0.0", required: "9.0.0", running: "0.5.0"),
            .versionNotComparable(name: "x", version: "1"), .minUDeckNotComparable(name: "x", text: "y"),
            .producerMissing(path: path), .producerNotExecutable(path: path), .producerOutsideFolder(path: path),
            .linkOrSubmodule(path: path, isLink: true), .linkOrSubmodule(path: path, isLink: false),
            .nameNotAllowed(path: path), .namesDifferOnlyInCase(path: path, other: "plugins/x/Y.sh"),
            .tooLarge(id: "x", bytes: 1, files: 1), .fileTooLarge(path: path, bytes: 6_000_000),
            .nestedTooDeep(path: path), .sizeNotListed(path: path),
            .arrivedDifferent(path: path, expected: "a", got: "b"), .folderDoesNotAddUp(id: "x"),
            .lfsPointer(path: path), .arrivedLarger(path: path, bytes: 2), .failsTheUsualChecks(id: "x", detail: "d"),
            .notTheVersionShown(id: "x", shown: "1.0.0", arrived: "1.0.1"), .folderAppeared(id: "x"),
        ]
        for refusal in all {
            let text = strings(.catalogueRefusal(refusal))
            #expect(!text.isEmpty)
            switch refusal {
            case .noManifest, .manifestUnreadable, .producerMissing, .producerNotExecutable, .producerOutsideFolder,
                 .linkOrSubmodule, .nameNotAllowed, .namesDifferOnlyInCase, .fileTooLarge, .nestedTooDeep,
                 .sizeNotListed, .arrivedDifferent, .lfsPointer, .arrivedLarger:
                #expect(text.contains(path), "\(language) drops the path from \(refusal)")
            default: break
            }
        }
    }

    /// The one sentence on the login card that can be false while everything around
    /// it is true. The switch is off, the system has no record — every fresh install
    /// spends its first day there — and a line reading "Opens: /Applications/uDeck.app"
    /// contradicts the control directly above it. The tense has to follow the state,
    /// which means the phrase has to be told the state.
    @Test("the path line does not claim uDeck opens when it does not")
    func pathLineFollowsTheState() {
        let path = "/Applications/uDeck.app"
        let english = Strings(.english)
        let russian = Strings(.russian)

        #expect(english(.generalOpensWhich(path, opens: true)) == "Opens: \(path)")
        #expect(english(.generalOpensWhich(path, opens: false)) == "Would open: \(path)")
        #expect(russian(.generalOpensWhich(path, opens: true)) == "Откроется: \(path)")
        #expect(russian(.generalOpensWhich(path, opens: false))
                == "Откроется при включении: \(path)")
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
