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
        case .pluginLastFailure(let reason): "Last failure: \(reason)"
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
        case .catalogueUpdateOverChanges(let id, let version):
            "Your changes to \(id) will be moved to the Trash and replaced with \(version)."
        case .catalogueRemoveConfirm(let id):
            "Remove \(id)? Its folder and its cache are deleted, and your permission decision, its settings and every window of it on every tab go with them."
        case .catalogueRemoveOwnConfirm(let id):
            "Remove \(id)? Its folder is moved to the Trash — it may be your only copy — and its cache, your permission decision, its settings and every window of it go."
        case .catalogueRefusal(let refusal): Self.refusal(refusal)
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
            "Builds are ad-hoc signed, so macOS will refuse a downloaded copy on first launch — right-click and choose Open. A binary you built yourself is unaffected."
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
        case .controlDensity(let name): "Density: \(name)"
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
}

extension English {
    /// Every refusal names the plugin, what is wrong, and what would fix it —
    /// in the words of docs/plugin-repository.md where it has them.
    static func refusal(_ refusal: RepositoryRefusal) -> String {
        switch refusal {
        case .folderNameNotAnID(let folder):
            "plugins/\(folder) is not a plugin id: lowercase letters, digits, \".\", \"_\" and \"-\", at most 64, starting with a letter or a digit."
        case .noManifest(let path): "\(path) is missing; a plugin folder needs one."
        case .manifestUnreadable(let path, let detail): "\(path) is not a valid manifest: \(detail)"
        case .manifestIDMismatch(let declared, let folder):
            "The manifest in plugins/\(folder) says its id is \"\(declared)\"; it has to be the folder's name."
        case .manifestProblem(let id, let detail): "\(id): \(detail)"
        case .apiNotSpoken(let name, let version, let api):
            "\(name) \(version) is written for plugin contract api \(api); this uDeck speaks api \(PluginAPI.current). Update uDeck to install it."
        case .needsNewerUDeck(let name, let version, let required, let running):
            "\(name) \(version) needs uDeck \(required) or later; this is uDeck \(running). Update uDeck (Settings → About) to install it."
        case .versionNotComparable(let name, let version):
            "\(name)'s version \"\(version)\" is not MAJOR.MINOR.PATCH, so uDeck cannot tell it from another version; it cannot be installed from a repository."
        case .minUDeckNotComparable(let name, let text):
            "\(name)'s minUDeck \"\(text)\" is not MAJOR.MINOR.PATCH, so uDeck cannot tell which release it needs; it cannot be installed from a repository."
        case .producerMissing(let path): "\(path) is what the manifest runs, and the repository does not have it."
        case .producerNotExecutable(let path):
            "\(path) is not committed as executable (git mode 100755), and uDeck takes the bit from the repository; commit it with chmod +x."
        case .producerOutsideFolder(let path): "\(path) leads out of the plugin's folder."
        case .linkOrSubmodule(let path, let isLink):
            "\(path) is a \(isLink ? "symbolic link" : "submodule"); a plugin from a repository may contain only files and folders."
        case .nameNotAllowed(let path):
            "\(path): names may use only letters, digits, \".\", \"_\" and \"-\", and may not start with \".\""
        case .namesDifferOnlyInCase(let path, let other):
            "\(path) and \(other) differ only in letter case, and a Mac's disk takes them for one file."
        case .tooLarge(let id, let bytes, let files):
            "\(id) is \(ByteCount.text(bytes, kilo: "KB", mega: "MB")) in \(files) files; uDeck installs plugins of up to 10 MB and \(RepositoryRules.maximumFiles) files."
        case .fileTooLarge(let path, let bytes):
            "\(path) is \(ByteCount.text(bytes, kilo: "KB", mega: "MB")); one file of a plugin may be up to 5 MB."
        case .nestedTooDeep(let path): "\(path) is nested more than \(RepositoryRules.maximumDepth) folders deep."
        case .sizeNotListed(let path): "The repository lists no size for \(path)."
        case .arrivedDifferent(let path, let expected, let got):
            "\(path) arrived different from what the repository lists (expected \(expected), got \(got)); nothing was installed."
        case .folderDoesNotAddUp(let id):
            "The files of \(id) do not add up to the folder the repository lists; nothing was installed."
        case .lfsPointer(let path):
            "\(path) is a Git LFS pointer, not the file; uDeck does not fetch LFS content."
        case .arrivedLarger(let path, _):
            "\(path) arrived larger than the repository lists; nothing was installed."
        case .failsTheUsualChecks(_, let detail): detail
        case .notTheVersionShown(let id, let shown, let arrived):
            "\(id) arrived as \(arrived), not the \(shown) the catalogue showed; nothing was installed. Check again."
        case .folderAppeared(let id):
            "A folder named \(id) appeared in the plugins folder while uDeck was installing; nothing was changed."
        }
    }
}
