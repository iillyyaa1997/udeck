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
        case .lookText: "Text"
        case .lookBrightness: "Brightness"
        case .lookColour: "Colour"
        case .lookDensity: "Density"
        case .densityCompact: "Compact"
        case .densityNormal: "Normal"
        case .densityCozy: "Cozy"
        case .lookLanguage: "Language"
        case .languageSystem: "System"
        case .lookNameThisLook: "Name this look"

        case .sampleTitle: "Claude sessions"
        case .sampleChip: "4 running"
        case .sampleBody: "pers · 48 % of the week"
        case .sampleFooter: "last checked a minute ago"

        // The built-in looks
        case .modeLight: "Light"
        case .modeDark: "Dark"
        case .modeContrast: "Contrast"
        case .modeGhost: "Ghost"
        case .modePaper: "Paper"
        case .modeSmoke: "Smoke"

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

        // What a plugin may ask for
        case .capabilityRead(let glob): "read files matching \(glob)"
        case .capabilityWrite(let glob): "write files matching \(glob)"
        case .capabilityExec(let command): "run \(command)"
        case .capabilityNetwork(let host): "reach \(host) over the network"
        case .capabilityScreen: "list and switch between running applications"
        case .capabilitySecret(let name): "receive the secret \"\(name)\" from uDeck"

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
