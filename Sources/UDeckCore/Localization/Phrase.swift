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
    case lookText
    case lookBrightness
    case lookColour
    case lookDensity
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
    case pluginLastFailure(reason: String)
    case permissionsAsksNothing
    case permissionsAsksTo
    case permissionsDeclared
    case permissionsDeclaredHelp
    case permissionsPluginAsksTo(name: String)
    case permissionsUnsandboxed
    case permissionsAllowAndRun

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

    // MARK: - The panel

    case deckNothingPlaced
    case deckNothingOwn
    case deckClickToWork
    case cardRefreshNow
    case cardRemoveFromTab
    case cardDragToMove
    case cardDragToResize
    case cardOwnDrawing
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
    case controlDensity(name: String)
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
