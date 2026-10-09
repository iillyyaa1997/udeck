import Foundation

/// uDeck in English, which is also the language it is written in.
struct English: Vocabulary {
    func callAsFunction(_ phrase: Phrase) -> String {
        switch phrase {

        // The status menu
        case .menuShowPanel: "Show uDeck"
        case .menuRefreshAll: "Refresh all plugins"
        case .menuSettings: "Settings…"
        case .menuOpenPluginsFolder: "Open the plugins folder"
        case .menuCopyDiagnostics: "Copy diagnostics"
        case .menuQuit: "Quit uDeck"

        // The settings window
        case .settingsWindowTitle: "uDeck Settings"
        case .sectionGeneral: "General"
        case .sectionOpening: "Opening"
        case .sectionLook: "Look"
        case .sectionPlugins: "Plugins"
        case .sectionAbout: "About"

        // Opening
        case .openingGesture: "Gesture"
        case .openingGestureToggle: "Open by moving the cursor to the top of the screen"
        case .openingPauseFirst: "Pause first"
        case .openingPushPast: "Or push past"
        case .openingStayQuiet: "Then stay quiet"
        case .openingShortcut: "Shortcut"
        case .openingShortcutToggle: "Open with a keyboard shortcut"
        case .openingKeys: "Keys"
        case .openingNeedsModifier:
            "Pick at least one modifier — without one this key is taken away from every application on this Mac."
        case .openingAlso: "Also"
        case .openingRetract: "Retract when you switch to another application"
        case .openingFullscreen: "Open over fullscreen applications"
        case .openingKeepPolling: "Keep running plugins while the panel is away"
        case .openingPermissions:
            "uDeck asks macOS for no permissions. It watches the pointer, which needs none, and registers one keyboard combination, which is not the same as watching the keyboard."

        // Look
        case .lookLightLook: "Light look"
        case .lookDarkLook: "Dark look"
        case .lookCustom: "Custom"
        case .lookPresets: "Presets"
        case .lookBuiltIn: "Built in"
        case .lookSaved: "Saved"
        case .lookShows: "Shows"
        case .lookLight: "Light"
        case .lookDark: "Dark"
        case .lookLightFromHour(let hour): "Light from \(hour):00"
        case .lookDarkFromHour(let hour): "Dark from \(hour):00"
        case .lookGlass: "Glass"
        case .glassRegular: "Regular"
        case .glassClear: "Clear"
        case .lookTintCoversMaterial(let percent):
            "At \(percent) % tint these two barely differ — the tint covers the material. Turn it down to tell them apart."
        case .lookAmount: "Amount"
        case .lookTint: "Tint"
        case .tintLighter: "Lighter"
        case .tintDarker: "Darker"
        case .lookStrength: "Strength"
        case .lookTintColour: "Tint colour"
        case .lookStates: "States"
        case .lookStateAllTogether: "Set them all up together"
        case .stateNotchIsTheIsland: "on this screen the notch is the island"
        case .stateDropToSeparate: "Drop here to set up on its own"
        case .lookSharedEverywhere: "The same in every state"
        case .lookStateLink: "Link"
        case .lookStateUnlink: "Unlink"
        case .lookStateMixed: "The selection spans more than one link"
        case .lookEditingEverything: "Editing every state"
        case .lookEditingStates: "Editing"
        case .lookEditingCount(let n): "Editing \(n) situations"
        case .statePhaseCollapsed: "Away"
        case .statePhasePeek: "Revealed"
        case .statePhaseOpen: "Open"
        case .statePhaseFullscreen: "Full screen"
        case .stateSurroundingOrdinary: "ordinary"
        case .stateSurroundingFullscreen: "another app full-screen"
        case .lookQuietLevel: "Visible"
        case .lookText: "Text"
        case .lookBrightness: "Brightness"
        case .lookColour: "Colour"
        case .lookDensity: "Density"
        case .lookTextSize: "Text size"
        case .densityCompact: "Compact"
        case .densityNormal: "Normal"
        case .densityCozy: "Cozy"
        case .lookLanguage: "Language"
        case .languageSystem: "System"
        case .lookNameThisLook: "Name this look"

        case .sampleTitle: "Disk"
        case .sampleChip: "78 GB free"
        case .sampleBody: "startup volume · of 460 GB"
        case .sampleFooter: "last checked a minute ago"

        // The built-in looks
        case .modeLight: "Light"
        case .modeDark: "Dark"
        case .modeContrast: "Contrast"
        case .modeGhost: "Ghost"
        case .modePaper: "Paper"
        case .modeSmoke: "Smoke"
        case .modeLightSummary: "A bright panel with dark text, for work over documents."
        case .modeDarkSummary: "A dark panel with light text, for work over dark screens."
        case .modeContrastSummary: "Nearly opaque, for a panel that has to be readable over anything."
        case .modeGhostSummary: "Barely there — the content hangs over whatever is behind it."
        case .modePaperSummary: "A dense light surface, for reading rather than glancing."
        case .modeSmokeSummary: "Diffused, but still visibly a material."

        // What decides which look
        case .sourceSystem: "System"
        case .sourceManual: "Manual"
        case .sourceSchedule: "By the clock"

        // Plugins
        case .pluginsInstalled: "Installed"
        case .pluginsOpenFolder: "Open the folder"
        case .pluginsLookAgain: "Look again"
        case .pluginsNothingInstalled:
            "Nothing installed yet. uDeck shows nothing of its own — everything in the panel comes from a plugin."
        case .pluginsStaleness(let seconds, let multiplier):
            "A card with no lifetime of its own is treated as current for \(seconds) s, dimmed after that, and blanked past \(multiplier)× it."
        case .pluginEnabled: "Enabled"
        case .pluginMore: "More"
        case .pluginLess: "Less"
        case .pluginSettings: "Settings"
        case .pluginEverySeconds(let seconds): "every \(seconds) s"
        case .pluginLastFailure(let reason): "Last failure: \(self(.failureReason(reason)))"
        case .failureReason(let reason):
            // The words `udeck-plugin run` prints, which are the format's own.
            reason.description
        case .pluginLastRun(let at, let reason, let duration, let result):
            "Last run \(at), \(Self.why(reason)), \(Seconds.fixed(duration, places: 2)) s: " + {
                switch result {
                case .card: "a card"
                case .lateCard(let failure): "a card, and a failure: \(self(.failureReason(failure)))"
                case .failure(let failure): "a failure: \(self(.failureReason(failure)))"
                }
            }()
        case .pluginStandardErrorEnd: "The end of its standard error:"
        case .pluginStandardErrorNothing: "Nothing on standard error."
        case .pluginStandardErrorBefore(let bytes):
            bytes == 1 ? "(1 byte came before what uDeck kept)" : "(\(bytes) bytes came before what uDeck kept)"
        case .permissionsAsksNothing: "Asks for nothing"
        case .permissionsAsksTo: "This plugin asks to:"
        case .permissionsDeclared: "declared"
        case .permissionsDeclaredHelp:
            "uDeck shows you this and will not start the plugin without your agreement, but it cannot hold it against a running program — see the plugin documentation."
        case .permissionsPluginAsksTo(let name): "\(name) asks to:"
        case .permissionsUnsandboxed:
            "uDeck runs this plugin as you, without a sandbox. Allowing it means agreeing to run this program; declining means uDeck never starts it."
        case .permissionsAllowAndRun: "Allow and run"

        // Plugins from a repository
        case .pluginsOfficialCatalogue: "Official catalogue"
        case .pluginsOfficialCatalogueHelp(let source):
            "uDeck reads the list of plugins in \(source) a few seconds after it starts and once a day, and when you press Check now — the list and each plugin's manifest, nothing else. A plugin's files are fetched only when you press Install. Off, uDeck makes no request about plugins at all; what is installed keeps running."
        case .catalogueCheckNow: "Check now"
        case .catalogueChecked(let source, let time): "\(source) · checked \(time)"
        case .catalogueNeverRead(let source): "\(source) · not read yet"
        case .catalogueReading: "Reading the catalogue…"
        case .catalogueOff:
            "The official catalogue is off. Installed plugins keep running; uDeck does not look for their updates."
        case .catalogueEmpty: "The repository offers no plugins yet."
        case .catalogueUpdatesWaiting(let count):
            count == 1 ? "1 update is waiting" : "\(count) updates are waiting"
        case .catalogueLimited(let readAt, let until):
            "GitHub allows 60 requests an hour from this network without signing in, and they are used up — by uDeck or by something else on the same connection. "
                + (readAt.map { "The list below is from \($0); " } ?? "")
                + "uDeck will look again after \(until)."
        case .catalogueRawLimited(let until):
            "GitHub's file host asked uDeck to wait; no file is fetched from it before \(until)."
        case .catalogueUnreachable(let reason, let readAt):
            "Could not reach GitHub: \(reason)." + (readAt.map { " The list below is from \($0)." } ?? "")
        case .catalogueNotFound(let source): "\(source) could not be found, or it is private."
        case .catalogueNotARepository(let source, let branch):
            "\(source) is not a uDeck plugin repository: there is no udeck-plugins.json at the top of \(branch)."
        case .catalogueFutureFormat(let declared):
            "This repository is in format \(declared); this uDeck reads format \(RepositoryPassport.supportedFormat). Update uDeck."
        case .catalogueInvalidPassport(let source, let reason):
            "\(source) has a udeck-plugins.json that uDeck cannot read: \(reason)."
        case .catalogueRefused(let status): "GitHub refused the request (HTTP \(status))."
        case .catalogueBadAnswer(let reason): "GitHub answered with something uDeck could not read: \(reason)."
        case .catalogueArrivedDifferent(let path, let expected, let got):
            "\(path) arrived different from what the repository lists (expected \(expected), got \(got))."
        case .catalogueVerified: "Verified"
        case .catalogueSize(let files, let size): files == 1 ? "1 file · \(size)" : "\(files) files · \(size)"
        case .catalogueAsksTo(let list): "Asks to \(list)"
        case .catalogueInstall: "Install"
        case .catalogueUpdate: "Update"
        case .catalogueReplace: "Replace…"
        case .catalogueInstalled: "Installed"
        case .catalogueAvailable(let version): "\(version) available"
        case .catalogueChangedStill(let version): "Changed in the repository, still \(version)"
        case .catalogueRepositoryNowHas(let version): "The repository now has \(version)"
        case .catalogueSwitchTo(let version): "Switch to \(version)"
        case .catalogueUpdateNeedsAPI(let version, let api): "\(version) needs a newer uDeck (api \(api))"
        case .catalogueUpdateNeedsUDeck(let version, let required): "\(version) needs uDeck \(required)"
        case .catalogueUpdateCannotInstall(let version): "\(version) cannot be installed here"
        case .catalogueGone: "No longer in the repository"
        case .catalogueOwnFolder(let id): "A folder of your own named \(id) is installed"
        case .catalogueMissing(let id, let path): "\(id) is not in \(path)"
        case .catalogueReinstall(let version): "Reinstall \(version)"
        case .catalogueDetails: "Details"
        case .catalogueWhatChanged: "What changed"
        case .catalogueOpenOnGitHub: "Open on GitHub"
        case .catalogueEarlierVersions: "Earlier versions…"
        case .catalogueBackTo(let version): "Back to \(version)"
        case .catalogueRemove: "Remove"
        case .catalogueWorking: "Working…"
        case .catalogueReplaceConfirm(let id, let path):
            "A folder of your own named \(id) is in \(path). Installing moves it to the Trash and puts the repository's \(id) in its place."
        case .catalogueReplaceLinkConfirm(let id, let target):
            "\(id) here is a link to \(target). Installing takes the link away — the folder it leads to stays exactly as it is — and puts the repository's \(id) in its place."
        case .catalogueUpdateOverChanges(let id, let version):
            "Your changes to \(id) will be moved to the Trash and replaced with \(version)."
        case .catalogueRemoveConfirm(let id):
            "Remove \(id)? Its folder and its cache are deleted, and your permission decision, its settings and every window of it on every tab go with them."
        case .catalogueRemoveOwnConfirm(let id):
            "Remove \(id)? Its folder is moved to the Trash — it may be your only copy — and its cache, your permission decision, its settings and every window of it go."
        case .catalogueRemoveLinkConfirm(let id, let target):
            "Remove the link \(id)? Only the link goes: the folder it leads to, \(target), stays exactly as it is. What uDeck kept of the plugin goes with the link — its cache and run log, your permission decision, its settings and every window of it."
        case .catalogueLinkedHere(let id): "\(id) is linked here, to a folder of your own"
        case .catalogueRefusal(let refusal): refusal.message
        case .catalogueFileUnreachable(let path, let reason):
            "\(path) could not be fetched: \(reason); nothing was installed."
        case .catalogueTookTooLong: "The install took more than five minutes and was stopped; nothing was installed."
        case .catalogueCannotWrite(let reason): "uDeck could not write to disk: \(reason)"
        case .catalogueStillRunning(let id):
            "Something \(id) started would not end, so its folder was left as it was. Try again in a moment."
        case .catalogueRecordsBroken(let reason):
            "~/.udeck/installed.json cannot be read, so uDeck installs, updates and removes nothing until it can: \(reason)"
        case .pluginMarkVerified: "Verified"
        case .pluginMarkOwnFolder: "A folder of your own"
        case .pluginMarkModified: "Modified locally"
        case .pluginMarkMissing: "Missing"
        case .pluginFrom(let source, let commit): "From \(source) at \(commit)"
        case .pluginPinned: "Kept at this version — newer ones are still shown"
        case .pluginMarkLinked: "Linked"
        case .pluginLinkedTo(let path): "A link to \(path): uDeck runs the plugin from there"
        case .pluginLinkNotFollowed(let destination): "A link to \(destination), which uDeck does not follow"
        case .linkFolder: "Link a folder…"
        case .linkFolderPanelMessage:
            "Choose a plugin's folder — the one with manifest.json in it. uDeck links it in and runs it where it is."
        case .linkFolderLink: "Link"
        case .linkFolderLinked(let id, let target): "Linked \(id) to \(target)."
        case .linkFolderAlready(let id, let target): "\(id) is already linked to \(target)."
        case .linkFolderOverInstalled(let id, let source, let folder, let toTrash):
            toTrash
                ? "\(id) is installed from \(source), and its copy holds changes of yours. Linking \(folder) in its place moves that copy to the Trash; its windows, settings and your permission decision stay."
                : "\(id) is installed from \(source). Linking \(folder) in its place deletes the installed copy — it is exactly what uDeck installed — and keeps its windows, settings and your permission decision."
        case .linkFolderOverOwn(let id, let path, let folder, let toTrash):
            toTrash
                ? "A folder of your own named \(id) is in \(path). Linking \(folder) in its place moves that folder to the Trash."
                : "A folder named \(id) is in \(path). Linking \(folder) in its place deletes it."
        case .linkFolderOverLink(let id, let destination, let folder):
            "\(id) is a link to \(destination) now. Linking points it at \(folder) instead; the folder it leads to now stays exactly as it is."
        case .linkFolderRefused(let refusal): Self.linkRefusal(refusal)
        case .runLogSwitch: "Keep a run log for linked folders"
        case .runLogHelp(let path):
            "Every run of a linked plugin — when, why, how it ended, how long it took, the end of its standard error — goes into \(path)/<id>.log, at most 2 MB a plugin. Other plugins keep only their last run, in memory."
        case .runLogShow: "Show the logs"
        case .searchPathTitle: "Where to look for commands"
        case .searchPathHelp:
            "A command written without a path (python3) is looked for in these folders, in this order. uDeck does not take PATH from your terminal. A change counts from the next run; nothing needs restarting."
        case .searchPathAdd: "Add a folder…"
        case .searchPathPanelMessage: "Choose a folder for uDeck to look for commands in."
        case .searchPathPanelAdd: "Add"
        case .searchPathRemove: "Remove the folder"
        case .searchPathKeepOne: "At least one folder stays: without one, no command is found."
        case .searchPathUp: "Move up"
        case .searchPathDown: "Move down"
        case .searchPathRestore: "Restore the defaults"
        case .searchPathStanding(let standing):
            switch standing {
            case .lookedIn: "looked in"
            case .notThere: "not there now"
            case .notAFolder: "not a folder"
            case .notAFullPath: "not looked in: not a full path from /"
            }
        case .commandTitle: "The udeck-plugin command"
        case .commandInstall: "Install command"
        case .commandRemove: "Remove command"
        case .commandInstalled(let path):
            "Installed: \(path) leads to the copy inside this uDeck, and updates with it."
        case .commandNotInstalled(let path):
            "Not installed. Install command puts a link at \(path) to the copy inside uDeck — no administrator password — and it updates with uDeck."
        case .commandOtherCopy(let path, let target):
            "\(path) leads to another copy of uDeck: \(target). Install command points it at this one."
        case .commandForeign(let path, let what):
            "\(path) is there already, and is not uDeck's — " + {
                switch what {
                case .file: "a file"
                case .folder: "a folder"
                case .link(let destination): "a link to \(destination)"
                }
            }() + ". uDeck leaves it as it is; move it away to install the command."
        case .commandNoHelper:
            "This copy of uDeck has no command inside it — a development build. The application Scripts/make-app.sh builds has it."
        case .commandNotLasting(let place):
            switch place {
            case .lasting: "This copy of uDeck stays where it is."
            case .translocated:
                "macOS runs this uDeck from a temporary copy — it was opened where it was downloaded — so a link to its command would lead nowhere once uDeck quits. Move uDeck to Applications first, open it from there, and install the command then."
            case .diskImage(let volume):
                "This uDeck runs from the disk image \(volume), so a link to its command would lead nowhere once the image is ejected. Move uDeck to Applications first, open it from there, and install the command then."
            }
        case .commandOnPath(let folder): "Your shell looks in \(folder): type udeck-plugin in a new terminal window."
        case .commandNotOnPath(let folder, let shell, let file):
            "Your shell (\(shell)) does not look in \(folder). Add this line to \(file), then open a new terminal window:"
        case .commandPathUnknown(let folder): "Could not tell whether your shell looks in \(folder)."
        case .commandCouldNot(let reason): "It did not work: \(reason)"
        case .historyTitle(let name): "Earlier versions of \(name)"
        case .historyReading: "Reading the plugin's history…"
        case .historyNone: "The history has no versions of this plugin."
        case .historyInstalledMark: "installed"
        case .historyInstall: "Install this version"
        case .historyFailed: "The history could not be read:"
        case .windowNotInPluginsFolder(let id, let path): "\(id) is not in \(path)"
        case .windowWillNotRun(let id): "\(id) will not run:"
        case .windowReinstall: "Reinstall"

        // What a plugin may ask for
        case .capabilityRead(let glob): "read files matching \(glob)"
        case .capabilityWrite(let glob): "write files matching \(glob)"
        case .capabilityExec(let command): "run \(command)"
        case .capabilityNetwork(let host): "reach \(host) over the network"
        case .capabilityScreen: "list and switch between running applications"
        case .capabilitySecret(let name): "be given the secret \"\(name)\" (uDeck does not hand out secrets yet)"

        // About
        case .aboutTitle: "uDeck"
        case .aboutTagline: "A panel at the top edge of the screen. Everything in it is a plugin."
        case .aboutThisBuild: "This build"
        case .aboutNotSigned: "Not signed with a Developer ID and not notarised."
        case .aboutAdHoc:
            "Builds are ad-hoc signed, so macOS will refuse a downloaded copy on first launch — on macOS 15 and later allow it in System Settings → Privacy & Security → Open Anyway, on macOS 14 Control-click it and choose Open. A binary you built yourself is unaffected."
        case .aboutNotSandboxed: "Not sandboxed, and cannot be: plugins run commands."
        case .aboutReadPermissions:
            "Read the permissions section of the plugin documentation before installing a plugin somebody else wrote."
        case .generalStartup: "Login"
        case .generalOpenAtLogin: "Open at Login"
        case .generalOpensWhich(let path, let opens):
            opens ? "Opens: \(path)" : "Would open: \(path)"
        case .generalNotInstalled(let path):
            "This copy is not installed as an application, so it cannot be opened at login: \(path). Build one with Scripts/make-app.sh and run that."
        case .generalRecordVanished: "macOS no longer has this record."
        case .generalDidNotTake: "macOS did not keep this record."
        case .generalAnotherCopy(let path):
            "There is another copy of uDeck on this Mac: \(path) — the record may have gone to it."
        case .generalWaitsForApproval: "macOS is waiting for you to allow it in System Settings."
        case .generalLoginFailed(let reason): "It did not work: \(reason)"
        case .generalOpenLoginItems: "Open Login Items & Extensions"

        case .updatesTitle: "Updates"
        case .updatesCheckNow: "Check now"
        case .updatesAutomatically: "Check for updates automatically"
        case .updatesAutomaticallyHelp:
            "Once a day, uDeck asks github.com whether there is a newer version. Off, it asks only when you press Check now."
        case .updatesNeverChecked: "Never checked."
        case .updatesJustChecked: "Checked just now."
        case .updatesLastChecked(let when): "Last checked \(when)."

        case .updatesInstalled: "Installed"
        case .updatesLatest: "Latest"
        case .updatesChecking: "Checking…"
        case .updatesUpToDate: "uDeck is up to date."
        case .updatesAvailable(let version): "Version \(version) is available."
        case .updatesInstallNow(let version): "Update to \(version)"
        case .updatesDownloading: "Downloading…"
        case .updatesReady: "Downloaded and ready."
        case .updatesRestartToInstall: "Restart and install"
        case .updatesFailed(let reason): "The check did not finish: \(reason)"

        case .menuBrokenPlugins(let count):
            count == 1 ? "1 plugin will not run" : "\(count) plugins will not run"

        case .aboutProblems: "Problems"

        // The panel
        case .deckNothingPlaced: "Nothing placed yet"
        case .deckNothingOwn: "uDeck shows nothing of its own. Open it and add a plugin."
        case .deckClickToWork: "Click or press a key to work in here"
        case .cardRefreshNow: "Refresh now"
        case .cardRemoveFromTab: "Remove from this tab"
        case .cardDragToMove: "Drag to move this window"
        case .cardDragToResize: "Drag to resize, in whole cells"
        case .cardOwnDrawing: "PLUGIN'S OWN DRAWING"
        case .cardLastRunFailed(let at, let reason): "Last run failed at \(at): \(self(.failureReason(reason)))"
        case .cardShowingValuesFrom(let time): "showing values from \(time)"
        case .cardLastRunFailedDot: "The last run failed"
        case .cardKindNotDrawn(let kind): "\"\(kind)\" is not drawn by this version of uDeck"
        case .cardUnsupportedRow(let kind):
            "this plugin sent a \"\(kind)\" row, which this version of uDeck does not draw"
        case .emptyNoPlugins: "No plugins installed"
        case .emptyTabEmpty: "This tab is empty"
        case .emptyNoPluginsBody(let path):
            "uDeck shows nothing by itself — everything in the panel comes from a plugin. Put one in \(path) to begin."
        case .emptyTabEmptyBody: "Add one of the installed plugins to this tab."
        case .emptyOpenPluginsFolder: "Open the plugins folder"
        case .emptyLookAgain: "Look for plugins again"
        case .emptyAdd: "Add"
        case .islandNothingPlaced: "uDeck, nothing placed yet"
        case .islandWorstState(let state): "uDeck, worst state \(state)"

        // Tabs and the panel's own controls
        case .tabName: "Tab name"
        case .tabAdd: "Add a tab"
        case .tabRename: "Rename"
        case .tabClose: "Close tab"
        case .tabClickAgainToRename: "Click again to rename"
        case .tabShowThis: "Show this tab"
        case .controlRefresh: "Refresh everything now"
        case .controlSettings: "Settings"
        case .controlSendAway: "Send the panel away"

        // Verbs
        case .actionSave: "Save"
        case .actionUse: "Use"
        case .actionDelete: "Delete"
        case .actionAllow: "Allow"
        case .actionDecline: "Decline"
        case .actionRun: "Run"
        case .actionCancel: "Cancel"
        case .actionClear: "Clear"

        // Units
        case .unitMilliseconds(let value): "\(value) ms"
        case .unitPoints(let value): "\(value) pt"
        case .unitSeconds(let value): String(format: "%.1f s", value)
        case .unitPercent(let value): "\(value) %"
        }
    }

    /// Why a run happened, as a sentence about it says it.
    static func why(_ reason: RefreshReason) -> String {
        switch reason {
        case .launch: "at launch"
        case .interval: "on its interval"
        case .manual: "asked for"
        }
    }

    /// Why **Link a folder…** linked nothing.
    static func linkRefusal(_ refusal: FolderLinkRefusal) -> String {
        switch refusal {
        case .busy: "Another plugin is being installed, updated, removed or linked; try again in a moment."
        case .recordsBroken(let reason):
            "installed.json cannot be read, so uDeck replaces no plugin until it can: \(reason)"
        case .failed(let reason): "The folder could not be linked: \(reason)"
        case .folder(let reason):
            switch reason {
            case .notThere(let folder): "\(folder) is not there."
            case .notAFolder(let folder): "\(folder) is not a folder: choose the plugin's folder, the one with manifest.json in it."
            case .insideUDeck(let folder, let udeck):
                "\(folder) is inside uDeck's own folder, \(udeck), where uDeck writes and deletes. Link a folder of your own."
            case .holdsUDeck(let folder, let udeck): "\(folder) holds uDeck's own folder, \(udeck). Choose the plugin's folder itself."
            case .noManifest(let folder): "\(folder) has no manifest.json, so it is not a plugin's folder."
            case .manifestUnreadable(let manifest, let detail):
                "\(manifest) is not a manifest uDeck can read: \(detail). The link is named after its id."
            case .recordsUnreadable(let file, let detail):
                "\(file) cannot be read, so whether the plugin is installed is not known; nothing was linked"
                    + (detail.map { " (\($0))" } ?? "") + "."
            case .taken(let link): "\(link) is taken."
            case .cannotLink(let link, let detail): "\(link) could not be made: \(detail)"
            }
        }
    }
}
