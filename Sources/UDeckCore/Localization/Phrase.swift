import Foundation

/// Everything uDeck says, named.
///
/// The values a sentence needs are carried by the case rather than pasted into
/// a finished string, because word order is not a constant across languages:
/// "Light from 7:00" and "Светлая с 7:00" put the hour in the same place by
/// luck, and "every 30s" and "каждые 30 с" do not survive being built by
/// concatenation at the call site. A phrase that takes its numbers as
/// parameters can be written properly in each language.
///
/// What is deliberately *not* here: anything a plugin wrote. A plugin's name,
/// its description, the text of its cards and the diagnostics from a run that
/// failed are the author's words and the program's own output. Translating them
/// would mean inventing text nobody wrote and making an error message harder to
/// search for. uDeck localises its own chrome and repeats everything else
/// exactly as it was given.
public enum Phrase: Sendable, Equatable {

    // MARK: - The status menu

    case menuShowPanel
    case menuRefreshAll
    case menuSettings
    case menuOpenPluginsFolder
    case menuCopyDiagnostics
    case menuQuit

    // MARK: - The settings window

    case settingsWindowTitle
    case sectionGeneral
    case sectionOpening
    case sectionLook
    case sectionPlugins
    case sectionAbout

    // MARK: - Opening

    case openingGesture
    case openingGestureToggle
    case openingPauseFirst
    case openingPushPast
    case openingStayQuiet
    case openingShortcut
    case openingShortcutToggle
    case openingKeys
    case openingNeedsModifier
    case openingAlso
    case openingRetract
    case openingFullscreen
    case openingKeepPolling
    case openingPermissions

    // MARK: - Look

    case lookLightLook
    case lookDarkLook
    case lookCustom
    case lookPresets
    case lookBuiltIn
    case lookSaved
    case lookShows
    case lookLight
    case lookDark
    case lookLightFromHour(Int)
    case lookDarkFromHour(Int)
    case lookGlass
    case glassRegular
    case glassClear
    case lookTintCoversMaterial(percent: Int)
    case lookAmount
    case lookTint
    case tintLighter
    case tintDarker
    case lookStrength
    case lookTintColour
    case lookStates
    case lookStateAllTogether
    case stateNotchIsTheIsland
    case stateDropToSeparate
    case lookSharedEverywhere
    case lookStateLink
    case lookStateUnlink
    case lookStateMixed
    case lookEditingEverything
    case lookEditingStates
    case lookEditingCount(Int)
    case statePhaseCollapsed
    case statePhasePeek
    case statePhaseOpen
    case statePhaseFullscreen
    case stateSurroundingOrdinary
    case stateSurroundingFullscreen
    case lookQuietLevel
    case lookText
    case lookBrightness
    case lookColour
    case lookDensity
    case lookTextSize
    case densityCompact
    case densityNormal
    case densityCozy
    case lookLanguage

    /// The absence of a choice: whichever language the Mac is set to.
    ///
    /// Named for what it is rather than for where it comes from — the row
    /// above it already says "System" for the same idea about the look, and
    /// two names for one concept on one screen is one name too many.
    case languageSystem
    case lookNameThisLook

    /// The card in the sample. Illustrative, so it is written rather than
    /// translated — a Russian reader should see a card that reads as a card,
    /// not an English one transliterated.
    ///
    /// It names nothing outside uDeck. The sample is the one card every
    /// operator sees before they have installed anything, and one that named a
    /// product made the application look like it was about that product.
    case sampleTitle
    case sampleChip
    case sampleBody
    case sampleFooter

    // MARK: - The built-in looks

    case modeLight
    case modeDark
    case modeContrast
    case modeGhost
    case modePaper
    case modeSmoke

    /// One line on what each built-in look is for. The names do not explain
    /// themselves — nobody guesses what Ghost or Paper is from the word.
    case modeLightSummary
    case modeDarkSummary
    case modeContrastSummary
    case modeGhostSummary
    case modePaperSummary
    case modeSmokeSummary

    // MARK: - What decides which look

    case sourceSystem
    case sourceManual
    case sourceSchedule

    // MARK: - Plugins

    case pluginsInstalled
    case pluginsOpenFolder
    case pluginsLookAgain
    case pluginsNothingInstalled
    case pluginsStaleness(seconds: Int, multiplier: Int)
    case pluginEnabled
    case pluginMore
    case pluginLess
    case pluginSettings
    case pluginEverySeconds(Int)
    case pluginLastFailure(reason: PluginFailure.Reason)

    /// Why a run failed, in the operator's language: each reason a run can
    /// fail for, with what it carries — the status, the signal, the seconds
    /// written as the language writes them. What a plugin or the system
    /// wrote, quoted in it (a launch error, why the output is not a card), is
    /// repeated as it was given.
    case failureReason(PluginFailure.Reason)

    /// A plugin's last run, whatever it came to: when (`at`, already
    /// formatted), why, how long (`duration`, in seconds), and what it came
    /// to. Under it, the end of its standard error.
    case pluginLastRun(at: String, reason: RefreshReason, duration: TimeInterval, result: PluginRun.Result)
    case pluginStandardErrorEnd
    case pluginStandardErrorNothing
    /// How many bytes of the run's standard error came before what uDeck
    /// kept of it, and were not kept.
    case pluginStandardErrorBefore(bytes: Int)
    case permissionsAsksNothing
    case permissionsAsksTo
    case permissionsDeclared
    case permissionsDeclaredHelp
    case permissionsPluginAsksTo(name: String)
    case permissionsUnsandboxed
    case permissionsAllowAndRun

    // MARK: - Plugins from a repository

    /// The switch for the official catalogue, and what it means — which is also
    /// what uDeck fetches, said where the operator decides about it.
    case pluginsOfficialCatalogue
    case pluginsOfficialCatalogueHelp(source: String)
    case catalogueCheckNow
    case catalogueChecked(source: String, at: String)
    case catalogueNeverRead(source: String)
    case catalogueReading
    case catalogueOff
    case catalogueEmpty
    case catalogueUpdatesWaiting(Int)
    /// **Update verified plugins by themselves** (`AutoUpdate`): the switch,
    /// and what it does and leaves to the operator.
    case catalogueUpdatesByThemselves
    case catalogueUpdatesByThemselvesHelp

    /// Why the list below is not fresh, each in the words of
    /// docs/plugin-repository.md. `readAt` is when the list below was read,
    /// already formatted, or nil when there is no list.
    case catalogueLimited(readAt: String?, until: String)
    case catalogueRawLimited(until: String)
    case catalogueUnreachable(reason: String, readAt: String?)
    case catalogueNotFound(source: String)
    case catalogueNotARepository(source: String, branch: String)
    case catalogueFutureFormat(declared: Int)
    case catalogueInvalidPassport(source: String, reason: String)
    case catalogueRefused(status: Int)
    case catalogueBadAnswer(reason: String)
    case catalogueArrivedDifferent(path: String, expected: String, got: String)

    /// A catalogue row.
    case catalogueVerified
    case catalogueSize(files: Int, size: String)
    case catalogueAsksTo(String)
    case catalogueInstall
    case catalogueUpdate
    case catalogueReplace
    case catalogueInstalled
    case catalogueAvailable(version: String)
    case catalogueChangedStill(version: String)
    /// After an offer, when the new version asks for other permissions than
    /// the copy on disk: why it waits for a press, and that the card asks.
    case catalogueAsksDifferently
    case catalogueRepositoryNowHas(version: String)
    case catalogueSwitchTo(version: String)
    case catalogueUpdateNeedsAPI(version: String, api: Int)
    case catalogueUpdateNeedsUDeck(version: String, required: String)
    case catalogueUpdateCannotInstall(version: String)
    case catalogueGone
    case catalogueOwnFolder(id: String)
    case catalogueMissing(id: String, path: String)
    case catalogueReinstall(version: String)
    case catalogueDetails
    case catalogueWhatChanged
    case catalogueOpenOnGitHub
    case catalogueEarlierVersions
    case catalogueBackTo(version: String)
    case catalogueRemove
    case catalogueWorking

    /// What a confirmation says before anything goes (`PlaceWarning`): of a
    /// link, that only the link goes and the folder it leads to stays.
    case catalogueReplaceConfirm(id: String, path: String)
    case catalogueReplaceLinkConfirm(id: String, target: String)
    case catalogueUpdateOverChanges(id: String, version: String)
    case catalogueRemoveConfirm(id: String)
    case catalogueRemoveOwnConfirm(id: String)
    case catalogueRemoveLinkConfirm(id: String, target: String)
    /// A catalogue row whose id is linked here, to a folder of the operator's.
    case catalogueLinkedHere(id: String)

    /// Every refusal names the plugin, what is wrong, and what would fix it.
    case catalogueRefusal(RepositoryRefusal)
    case catalogueFileUnreachable(path: String, reason: String)
    case catalogueTookTooLong
    case catalogueCannotWrite(reason: String)
    case catalogueStillRunning(id: String)
    case catalogueRecordsBroken(reason: String)

    /// Where a plugin on this machine stands, as its row in Settings marks it.
    case pluginMarkVerified
    case pluginMarkOwnFolder
    case pluginMarkModified
    case pluginMarkMissing
    case pluginFrom(source: String, commit: String)
    case pluginPinned
    /// A copy a verified plugin put in place by itself (`AutoUpdate`), and
    /// one it could not: tried again at the next read of the catalogue.
    case pluginUpdatedByItself(date: String)
    case pluginUpdateByItselfFailed(version: String)

    /// A linked folder (Q125): its mark, and where its link leads — or that
    /// uDeck does not follow it, and why is said above.
    case pluginMarkLinked
    case pluginLinkedTo(path: String)
    case pluginLinkNotFollowed(destination: String)

    /// **Link a folder…** (Q126): the button, the folder panel, what it came
    /// to, and what it says first when the id is taken (`PlaceWarning`).
    case linkFolder
    case linkFolderPanelMessage
    case linkFolderLink
    case linkFolderLinked(id: String, target: String)
    case linkFolderAlready(id: String, target: String)
    case linkFolderOverInstalled(id: String, source: String, folder: String, toTrash: Bool)
    case linkFolderOverOwn(id: String, path: String, folder: String, toTrash: Bool)
    case linkFolderOverLink(id: String, destination: String, folder: String)
    case linkFolderRefused(FolderLinkRefusal)

    /// The run log of linked folders (Q127): its switch, what it does, and
    /// the button that shows the logs.
    case runLogSwitch
    case runLogHelp(path: String)
    case runLogShow

    /// **Where to look for commands** (Q142): the folders a bare command is
    /// looked up in.
    case searchPathTitle
    case searchPathHelp
    case searchPathAdd
    case searchPathPanelMessage
    case searchPathPanelAdd
    case searchPathRemove
    case searchPathKeepOne
    case searchPathUp
    case searchPathDown
    case searchPathRestore
    case searchPathStanding(SearchPathList.Standing)

    /// **Install command** (Q129): `udeck-plugin` from inside uDeck, linked
    /// into `~/.local/bin`.
    case commandTitle
    case commandInstall
    case commandRemove
    case commandInstalled(path: String)
    case commandNotInstalled(path: String)
    case commandOtherCopy(path: String, target: String)
    case commandForeign(path: String, what: CommandInstall.Foreign)
    case commandNoHelper
    /// This uDeck runs from where it will not stay (`BundlePlace`): no link
    /// is made to it.
    case commandNotLasting(BundlePlace)
    case commandOnPath(folder: String)
    case commandNotOnPath(folder: String, shell: String, file: String)
    case commandPathUnknown(folder: String)
    case commandCouldNot(reason: String)

    /// Earlier versions, from the folder's history.
    case historyTitle(name: String)
    case historyReading
    case historyNone
    case historyInstalledMark
    case historyInstall
    case historyFailed

    /// A window whose plugin is not here: it stays, and says so.
    case windowNotInPluginsFolder(id: String, path: String)
    case windowWillNotRun(id: String)
    case windowReinstall

    // MARK: - What a plugin may ask for

    case capabilityRead(glob: String)
    case capabilityWrite(glob: String)
    case capabilityExec(command: String)
    case capabilityNetwork(host: String)
    case capabilityScreen
    case capabilitySecret(name: String)

    // MARK: - About

    case aboutTitle
    case aboutTagline
    case aboutThisBuild
    case aboutNotSigned
    case aboutAdHoc
    case aboutNotSandboxed
    case aboutReadPermissions
    case aboutProblems

    // MARK: - Opening at login

    /// The system's own words, on purpose. macOS calls this "Open at Login" in the Dock's
    /// menu and in Login Items & Extensions — «Открывать при входе» — and an application
    /// that invents its own phrase for the same switch makes the operator match them up.
    /// Almost nobody does this: of twelve applications measured in 2026, one.
    case generalStartup
    case generalOpenAtLogin

    /// Which copy of uDeck the system would open. The card states it on every ordinary
    /// day, because the day it matters is the day the operator has forgotten there is a
    /// second copy.
    ///
    /// The tense travels with it. On a Mac where nothing opens at login — every fresh
    /// install, and every day the switch is off — "Opens: /Applications/uDeck.app" is
    /// simply untrue, and the sentence has to say the same thing in the conditional
    /// instead of quietly asserting the state the switch above it denies.
    case generalOpensWhich(String, opens: Bool)

    /// This copy is not an application, so nothing about it can be opened at login —
    /// the state a development build runs in, where the switch would otherwise ask the
    /// system for the release identifier from a path under `.build`.
    ///
    /// It carries the path because it replaces the line above rather than joining it:
    /// "Would open: …/.build/debug" promises something that cannot happen at all for
    /// this copy, and two sentences about one path, one of them untrue, is worse than
    /// the longer sentence that is true.
    case generalNotInstalled(String)

    /// The record was there and is gone, with nobody having asked for that.
    case generalRecordVanished

    /// The operator asked, nothing failed, and the system still has no record — which is
    /// what it looks like from a copy that is not the one the system has on file.
    case generalDidNotTake

    /// Another copy exists, and it is the likeliest explanation. Never stated as proof:
    /// the system does not tell an application which copy holds the record.
    case generalAnotherCopy(String)
    case generalWaitsForApproval
    case generalLoginFailed(String)
    case generalOpenLoginItems

    // MARK: - Updates

    /// On as uDeck ships; the switch says what it does rather than just
    /// "check", because it is one of the two things uDeck asks the network
    /// about by itself (the other is the official plugin catalogue).
    case updatesTitle
    case updatesCheckNow
    case updatesAutomatically
    case updatesAutomaticallyHelp
    case updatesNeverChecked

    /// A check that has just finished. `RelativeDateTimeFormatter` rounds the
    /// zero to the nearest unit and picks the future while doing it — the
    /// screen said "checked in 0 seconds", about something that had already
    /// happened.
    case updatesJustChecked
    case updatesLastChecked(String)

    /// The answer to a check belongs on the screen that asked, not in a window
    /// over it: the commonest answer is "nothing to do", and interrupting to
    /// say that is worse than not saying it.
    case updatesInstalled
    case updatesLatest
    case updatesChecking
    case updatesUpToDate
    case updatesAvailable(String)
    case updatesInstallNow(String)
    case updatesDownloading
    case updatesReady
    case updatesRestartToInstall
    case updatesFailed(String)

    // MARK: - Plugins that will not run

    /// The menu-bar item is the only part of uDeck an operator sees without
    /// asking for it, so it is where a plugin that cannot run has to say so.
    case menuBrokenPlugins(count: Int)

    // MARK: - The panel

    case deckNothingPlaced
    case deckNothingOwn
    case deckClickToWork
    case cardRefreshNow
    case cardRemoveFromTab
    case cardDragToMove
    case cardDragToResize
    case cardOwnDrawing

    /// A run that failed while the card is still fresh (Q128): one line with
    /// when and why, one with when the values shown are from, and the amber
    /// dot's name for VoiceOver.
    case cardLastRunFailed(at: String, reason: PluginFailure.Reason)
    case cardShowingValuesFrom(String)
    case cardLastRunFailedDot
    case cardKindNotDrawn(kind: String)
    case cardUnsupportedRow(kind: String)
    case emptyNoPlugins
    case emptyTabEmpty
    case emptyNoPluginsBody(path: String)
    case emptyTabEmptyBody
    case emptyOpenPluginsFolder
    case emptyLookAgain
    case emptyAdd
    case islandNothingPlaced
    case islandWorstState(String)

    // MARK: - Tabs and the panel's own controls

    case tabName
    case tabAdd
    case tabRename
    case tabClose
    case tabClickAgainToRename
    case tabShowThis
    case controlRefresh
    case controlSettings
    case controlSendAway

    // MARK: - Verbs

    case actionSave
    case actionUse
    case actionDelete
    case actionAllow
    case actionDecline
    case actionRun
    case actionCancel
    case actionClear

    // MARK: - Units

    case unitMilliseconds(Int)
    case unitPoints(Int)
    case unitSeconds(Double)
    case unitPercent(Int)
}
