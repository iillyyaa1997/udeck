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
    /// The card's question about a plugin that asks for nothing and whose
    /// code nobody verified: it is asked whether it may run at all.
    case permissionsAsksNothingUnverified(name: String)
    /// The card of a plugin held to its tree whose folder would not hash —
    /// a file in it cannot be read: nothing can be decided for it.
    case permissionsFolderUnreadable(name: String)
    /// Where code nobody verified comes from, on the card that asks about it
    /// (`ConsentSource`): the branch or the pull request, its repository, and
    /// whether it was changed on this Mac since it was installed.
    case permissionsUnverifiedSource(ref: PluginRef, repository: String, changedHere: Bool)
    /// The same while `installed.json` cannot be read: nothing says where any
    /// copy came from, so every one is asked about by its content.
    case permissionsSourceUnknown
    /// Where the code of a source of one's own that nobody vouches for comes
    /// from (`ConsentSource`): its default branch, at `address`.
    case permissionsUntrustedSource(address: String, changedHere: Bool)
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
    /// `host` is the host the request was for: `GitHub` for the official
    /// catalogue, as it always said; a source's host for a source of one's own.
    case catalogueUnreachable(reason: String, readAt: String?, host: String = "GitHub")
    case catalogueNotFound(source: String)
    case catalogueNotARepository(source: String, branch: String)
    case catalogueFutureFormat(declared: Int)
    case catalogueInvalidPassport(source: String, reason: String)
    case catalogueRefused(status: Int, host: String = "GitHub")
    case catalogueBadAnswer(reason: String, host: String = "GitHub")
    case catalogueArrivedDifferent(path: String, expected: String, got: String)

    /// A catalogue row.
    case catalogueVerified
    case catalogueSize(files: Int, size: String)
    /// The same, of a host whose listings give no sizes (GitLab's): how many
    /// files, and no bytes (S4-15).
    case catalogueFiles(files: Int)
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
    /// *Open on GitHub*, or *Open on gitlab.example* — the host the page is
    /// on (`RepositoryAddress.hostName`).
    case catalogueOpenOn(host: String)
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
    /// A copy uDeck installed taken by a copy from another line of history
    /// (`PlaceWarning.switching`): both named, and the Trash when the copy
    /// there holds the operator's changes.
    case catalogueSwitchConfirm(id: String, from: CopyName, to: CopyName, toTrash: Bool)
    /// A catalogue row whose id is linked here, to a folder of the operator's.
    case catalogueLinkedHere(id: String)
    /// A catalogue row whose id is installed from a branch or a pull request
    /// (`CatalogueRowState.unverified`): what is there, and the button that
    /// puts the row's verified copy in its place. `fork` is the fork a branch
    /// is in, `owner/repo`, when it is a fork's (`PluginOrigin.fork`) — the
    /// same in every phrase below that names a line of history.
    case catalogueInstalledUnverified(ref: PluginRef, fork: String? = nil)
    /// The same, of a copy of the default branch of a source of one's own,
    /// at `address`, in the official catalogue (`CatalogueRowState.unverifiedLine`).
    case catalogueInstalledFromSource(address: String)
    /// A row of a source of one's own whose id is installed from elsewhere
    /// (`CatalogueRowState.fromElsewhere`), and its button.
    case catalogueInstalledFromElsewhere(CopyName)
    case catalogueInstallFromHere
    case catalogueSwitchToVerified(version: String)
    /// After *Installed here from pull request #3: unverified*, what became
    /// of the pull request (`PullRequestLifecycle.cataloguePhrase`).
    case catalogueMergedDiffers
    case catalogueClosedUnmerged

    /// Every refusal names the plugin, what is wrong, and what would fix it.
    case catalogueRefusal(RepositoryRefusal)
    case catalogueFileUnreachable(path: String, reason: String)
    case catalogueTookTooLong
    case catalogueCannotWrite(reason: String)
    case catalogueStillRunning(id: String)
    case catalogueRecordsBroken(reason: String)

    /// Where a plugin on this machine stands, as its row in Settings marks it.
    case pluginMarkVerified
    /// From a branch or a pull request, exactly as installed: nobody
    /// verified it.
    case pluginMarkUnverified
    case pluginMarkOwnFolder
    case pluginMarkModified
    case pluginMarkMissing
    case pluginFrom(source: String, commit: String)
    /// Where code nobody verified came from, beside its **Unverified** mark
    /// (`InstalledRecord.fromPhrase`): the pull request or the branch, and the
    /// commit, seven characters of it.
    case pluginFromPullRequest(number: Int, commit: String)
    case pluginFromBranch(name: String, commit: String, fork: String? = nil)
    /// What became of the pull request a copy came from, under its mark
    /// (`PullRequestLifecycle.rowPhrase`): merged as something else than the
    /// copy — the verified version offered, never made by itself, or none to
    /// offer here — or closed without being merged.
    case pluginPullRequestMergedDiffers(number: Int)
    case pluginPullRequestMergedNothingOffered(number: Int)
    case pluginPullRequestClosed(number: Int)
    /// What the branch or the pull request a copy came from has for it now
    /// (`RefOffer`), under its mark: a newer version, other files under the
    /// same one, an older one, its folder no longer there — and that the head
    /// which brings it does not continue what is installed (`HistoryRewrite`).
    case pluginRefAvailable(ref: PluginRef, version: String, fork: String? = nil)
    case pluginRefChangedStill(ref: PluginRef, version: String, fork: String? = nil)
    case pluginRefNowHas(ref: PluginRef, version: String, fork: String? = nil)
    case pluginRefGone(ref: PluginRef, id: String, fork: String? = nil)
    case pluginRefRewritten(ref: PluginRef, fork: String? = nil)
    /// The branch a copy came from is not there any more; the plugin keeps
    /// running.
    case pluginBranchGone(name: String, fork: String? = nil)
    /// The last read did not ask about the branch or the pull request a copy
    /// came from — the reserve, a limit, a request that failed — since `at`.
    case pluginRefNotCheckedSince(ref: PluginRef, at: String, fork: String? = nil)
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

    /// **Install from a link…**: the button, what it is for, the field, and
    /// what a link pasted comes to — the line of history and the commit it
    /// was read at, the plugins there that are not the catalogue's, or why
    /// there is nothing to install (`LinkRefusal`). `official` is the official
    /// repository, as `github.com/owner/repo`; `fork`, a fork's `owner/repo`
    /// when the branch is a fork's.
    case linkInstall
    case linkHelp(official: String)
    case linkField
    case linkLookUp
    case linkReading
    case linkClose
    case linkOff
    case linkRefused(RepositoryLink.Refusal, official: String)
    case linkNotFound(RepositoryLink, official: String)
    case linkIsTheCatalogue(official: String, plugin: String?)
    case linkHead(ref: PluginRef, commit: String, fork: String? = nil)
    case linkPullRequestMerged
    /// Merged into `base`, another branch than the default one: nothing of it
    /// is verified, and the catalogue does not have it.
    case linkPullRequestMergedElsewhere(base: String)
    /// **Back to** or **Reinstall** of a commit GitHub no longer has: a
    /// history rewritten, and cleaned up since.
    case catalogueCommitGone(commit: String)
    case linkPullRequestClosed
    /// Nothing there differs from the catalogue's head: every plugin, or —
    /// for a link into one plugin's folder — that plugin.
    case linkNothingDiffers(ref: PluginRef, plugin: String? = nil, fork: String? = nil)
    /// A link into a plugin's folder that the branch or the pull request
    /// does not have.
    case linkPluginNotThere(ref: PluginRef, plugin: String, fork: String? = nil)
    case linkUnverifiedNote

    // MARK: - Sources of one's own (stage 4)

    /// A repository that is no fork of the official one — a repository of its
    /// own, or a fork of another, `github.com/owner/repo` — on **Install from a
    /// link…**: what to do with it, and the button that does it, which opens
    /// **Add a source…** with its address filled in.
    case linkNotAForkAddAsASource(repository: String, official: String)
    case linkAddAsASource
    /// A link to another host than github.com on **Install from a link…**
    /// (S4-20, item 16): what can be done with it — and, when it reads as a
    /// GitLab project, `page`, its page, which **Add as a source…** fills
    /// **Add a source…** with.
    case linkNotGitHubAddAsASource(host: String, page: String?)
    /// Why an address pasted into **Add a source…** is not read (`SourceLink`).
    case sourceLinkRefused(SourceLink.Refusal, official: String)
    /// `~/.udeck/sources.json` cannot be used (`SourceList.Broken`), and an
    /// entry of it that is left out (`SourceList.Skipped`).
    case sourcesBroken(SourceList.Broken)
    case sourceSkipped(SourceList.Skipped)
    /// **Add** of a source whose id another source has (`SourceList.AddRefusal.idTaken`).
    case sourceIDTaken(name: String)
    /// A source's `404`, asked without a token.
    case sourceNotFound(address: String)
    /// A copy of a source that is no longer added: its row, after its mark.
    case sourceNoLongerAdded(address: String)
    /// **Remove…** of a source: what it does.
    case sourceRemoveConfirm(name: String, address: String)
    /// **Back to** a copy from a repository that is no source any more
    /// (`PreviousCopy.source`).
    case catalogueNotASourceAnyMore(address: String)
    /// The official repository's number is not the one this uDeck knows it by.
    case catalogueOfficialRepositoryChanged

    /// Settings → Plugins → **Your sources** (S4-06): its title, **Add a
    /// source…** and its sheet — the field, **Add**, what a lookup is doing —
    /// a source's block — what nobody vouches for (S4-07), **Remove…** — and
    /// the line a test build carries (S4-20, item 24).
    case sourcesTitle
    case sourcesAdd
    case sourcesAddField
    case sourcesAddConfirm
    case sourcesAsking(host: String)
    case sourceNotTrusted
    case sourceRemove
    case sourcesTestBuild(host: String, base: String)
    /// A GitLab's limit used up, or its `429` (S4-20, item 9): `host` asked
    /// uDeck to wait — and, of gitlab.com read without a token, that a token
    /// raises the limit. `readAt` as for `catalogueLimited`.
    case sourceGitLabLimited(host: String, readAt: String?, until: String, anonymousGitLabCom: Bool)
    /// **Look up** of an address on a host that did not answer as GitLab
    /// (S4-20, item 13): a `404`, or an answer, that is not GitLab's.
    case sourceNotGitLab(host: String)
    /// **Look up** of a repository that is added already, named as its block
    /// names it (`name`) and by its address.
    case sourceAlreadyAdded(name: String, address: String)
    /// **Install from a link…** of a link into a source of one's own: not yet.
    case sourceBranchNotYet

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
    /// Beside **Reinstall** on such a window, when what it puts back is code
    /// nobody verified: which copy, from where (`InstalledRecord.reinstallSays`).
    case windowReinstallBrings(CopyName)

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
