import SwiftUI
import UDeckCore

/// uDeck's own settings.
///
/// Five sections, in the order they matter: what is general to uDeck (its
/// start, its language, its own updates), how the panel opens, how it looks,
/// what is installed, and what this build is. The plugin section is the largest
/// on purpose — in an application whose every feature is a plugin, "what is
/// installed and what is it allowed to do" *is* the settings screen.
public struct SettingsView: View {
    @Bindable var model: DeckModel

    /// Absent in a build with no updater — a development build, or a copy
    /// somebody assembled themselves. The Updates group is simply not drawn
    /// then, rather than drawn with a button that cannot do anything.
    var updater: (any UpdateChecking)?

    /// Absent in a build with nothing to ask — same reasoning as the updater. A
    /// development binary has no bundle to register, and a card whose switch cannot do
    /// anything is worse than no card.
    var loginItem: (any LoginItemControlling)?
    /// Which pane, and which plugin in it: the window's controller keeps it,
    /// so that a restart into an update can say where the window was and the
    /// next launch open it there (`SettingsPlace`).
    @Bindable var navigation: SettingsNavigation

    enum Section: String, CaseIterable, Identifiable {
        case general
        case opening
        case look
        case plugins
        case about

        var id: String { rawValue }

        var title: Phrase {
            switch self {
            case .general: .sectionGeneral
            case .opening: .sectionOpening
            case .look: .sectionLook
            case .plugins: .sectionPlugins
            case .about: .sectionAbout
            }
        }

        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .opening: "cursorarrow.rays"
            case .look: "paintbrush"
            case .plugins: "square.grid.2x2"
            case .about: "info.circle"
            }
        }

        /// The colour of the square the symbol sits on, as System Settings
        /// draws its sidebar (the redesign, 2026-11-18).
        var tint: Color {
            switch self {
            case .general: Color(red: 0.56, green: 0.56, blue: 0.58)
            case .opening: Color(red: 0.04, green: 0.52, blue: 1.0)
            case .look: Color(red: 0.69, green: 0.32, blue: 0.87)
            case .plugins: Color(red: 1.0, green: 0.58, blue: 0.0)
            case .about: Color(red: 0.39, green: 0.39, blue: 0.40)
            }
        }
    }

    public init(
        model: DeckModel,
        updater: (any UpdateChecking)? = nil,
        loginItem: (any LoginItemControlling)? = nil,
        navigation: SettingsNavigation = SettingsNavigation()
    ) {
        self.model = model
        self.updater = updater
        self.loginItem = loginItem
        self.navigation = navigation
    }

    public var body: some View {
        // The sidebar is the window's only navigation, so it does not collapse.
        //
        // NavigationSplitView offers a toggle for it by default, and in a window
        // without a real toolbar that button has nothing to anchor to: it sits
        // beside the title while the sidebar is open and jumps to the far right
        // corner when it closes. Even placed correctly it would be a control
        // whose whole effect is to hide the list of sections and leave no way
        // back to them — so it is removed rather than fixed, and the column
        // visibility is stated rather than left to be remembered.
        NavigationSplitView(columnVisibility: .constant(.all)) {
            List(Section.allCases, selection: $navigation.section) { item in
                // How many plugin updates are waiting, where the operator
                // looks for the Plugins pane.
                SidebarRow(
                    title: model.strings(item.title), symbol: item.symbol, tint: item.tint,
                    updates: item == .plugins ? model.updatesWaiting : 0, chosen: item == navigation.section
                )
                    // On the row itself: a List that finds no tag on its rows
                    // selects nothing — measured in the lab on 2026-09-28, no
                    // click on any section changed the pane, with the tag
                    // under a `.badge`.
                    .tag(item)
                    // Identifiers, not titles: every title here is translated,
                    // and the language is a setting inside this same window, so
                    // anything driving the screen from outside — the end-to-end
                    // lab, VoiceOver scripting, a bug report's reproduction —
                    // would otherwise break the moment the operator switches
                    // language.
                    .accessibilityIdentifier("section.\(item)")
            }
            // Room for the longest Russian name with its icon and the
            // Plugins row's ↑N: measured in the lab (gallery of 2026-11-19),
            // the column came out at about 137 pt and cut "Появление",
            // "О программе" and "Плагины ↑1" short. The frame as well as the
            // column width: the split view honours the content's own minimum.
            .navigationSplitViewColumnWidth(min: 190, ideal: 200, max: 260)
            .frame(minWidth: 190)
            // On the sidebar's own content, which is where this modifier is
            // read: applied to the split view it is silently ignored, and the
            // button stays — inert, because the column visibility above is a
            // constant it cannot change.
            .toolbar(removing: .sidebarToggle)
        } detail: {
            switch navigation.section {
            // Grouped forms, as System Settings draws its panes: each scrolls
            // by itself (the redesign, 2026-11-18).
            case .general: GeneralSettings(model: model, loginItem: loginItem, updater: updater)
            case .opening: OpeningSettings(model: model)
            case .about: AboutSection(model: model, updater: updater)
            case .look: LookSettings(model: model)
            // Labelled tabs over their pages (PluginsPane.swift).
            case .plugins: PluginsSettingsPane(model: model, navigation: navigation)
            }
        }
        .frame(minWidth: 900, minHeight: 520)
        // The settings window is its own window rather than part of the panel,
        // so it does not inherit the panel's environment and has to be handed
        // the language itself.
        //
        // This reaches the panes below and not this view: a value put into the
        // environment by a modifier is read by that view's children, not by the
        // view that put it there. The sidebar above therefore asks the model
        // directly — it did not, and it was the one part of the settings window
        // that stayed in English after the language was changed.
        .environment(\.strings, model.strings)
    }
}

// MARK: - General

/// What is general to uDeck: starting with the Mac, its language, and its own
/// updates.
///
/// A grouped form, as System Settings draws one — rows on white groups, the
/// control at the right, what it does under it (the operator chose it on the
/// redesign canvas, 2026-11-18). Updates moved here from About, which became a
/// card: how uDeck updates itself is a setting like the others, and About is
/// what uDeck is.
///
/// The language lived on the Look pane, next to the tint and the ink, which is
/// where it did not belong: Look is about how the panel is dressed, and what
/// language it speaks is not that.
private struct GeneralSettings: View {
    @Bindable var model: DeckModel
    var loginItem: (any LoginItemControlling)?
    var updater: (any UpdateChecking)?
    @Environment(\.strings) private var strings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PaneTitle(strings(.sectionGeneral))
            form
        }
    }

    private var form: some View {
        Form {
            Section {
                if let loginItem { LoginRow(loginItem: loginItem) }
                Picker(strings(.lookLanguage), selection: Binding(
                    get: { model.settings.language },
                    set: { newValue in
                        var settings = model.settings
                        settings.language = newValue
                        model.update(settings: settings)
                    }
                )) {
                    // Following the system is the absence of a choice rather
                    // than a language of its own, so it is `nil` here and
                    // nothing at all in the settings file.
                    Text(strings(.languageSystem)).tag(Language?.none)
                    // Each language names itself. Somebody who landed in a
                    // language they cannot read is looking for the word
                    // they *can* — "English", not "Английский".
                    ForEach(Language.allCases) { language in
                        Text(language.endonym).tag(Language?.some(language))
                    }
                }
                .pickerStyle(.segmented)
            }
            if let updater { UpdatesSection(updater: updater) }
        }
        .formStyle(.grouped)
    }
}

/// Opening at login, as one statement rather than a switch on its own.
///
/// The row says three things and only three: whether uDeck opens at login, *which copy*
/// would open, and — only when there is something to say — what the system says instead.
/// The middle one is the reason the row says more than its switch: the failure this
/// setting actually suffers is a second copy of uDeck taking the record, and on the day
/// that happens the operator needs to know which copy they are looking at.
///
/// The switch is read from the system each time the window appears and each time uDeck is
/// activated again, because `ServiceManagement` publishes no notification and the operator
/// may have been in System Settings in between.
private struct LoginRow: View {
    let loginItem: any LoginItemControlling
    @Environment(\.strings) private var strings

    /// Whether the copy drawing this row is one the system could open at all.
    private var installed: Bool { isAnInstalledCopy(loginItem.thisCopy) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(strings(.generalOpenAtLogin), isOn: Binding(
                get: { loginItem.status.opensAtLogin },
                set: { loginItem.set(opensAtLogin: $0) }
            ))
            .accessibilityIdentifier("general.openAtLogin")
            .disabled(!installed)

            // One statement about the path, whichever state this copy is in. Said
            // before the click rather than after it: whether this copy can be
            // registered at all is knowable by looking at it, and a switch that
            // answers only once it has been pressed is a worse way to say so.
            if installed {
                Text(strings(.generalOpensWhich(shown(loginItem.thisCopy),
                                               opens: loginItem.status.opensAtLogin)))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("general.opensWhich")
            } else {
                Text(strings(.generalNotInstalled(shown(loginItem.thisCopy))))
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("general.notInstalled")
            }

            if let message = loginItem.status.message {
                trouble(message)
            }
        }
        // Three moments, and there is no fourth to be had: `ServiceManagement` publishes
        // no notification when a login record changes, so asking is the only way to know.
        // The pane appearing, uDeck being activated again — which is what coming back
        // from System Settings looks like — and this window being brought forward.
        //
        // What that leaves, measured in a machine: while uDeck is the active application
        // with this window already open and key, nothing re-reads, so a record taken away
        // at that moment sits on screen as a switch that is no longer true until anything
        // at all moves. Polling would close it and is what this deliberately does not do:
        // asking the system ten times a minute to catch a minute that almost never comes.
        .onAppear { loginItem.refresh() }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification
        )) { _ in loginItem.refresh() }
        .onReceive(NotificationCenter.default.publisher(
            for: NSWindow.didBecomeKeyNotification
        )) { _ in loginItem.refresh() }
    }

    @ViewBuilder private func trouble(_ message: LoginItemMessage) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(headline(for: message))
                .font(.caption).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("general.loginTrouble")

            if let other = otherCopy(in: message) {
                Text(strings(.generalAnotherCopy(shown(other))))
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("general.anotherCopy")
            }

            // Offered whenever there is anything to say, including when the asking itself
            // failed. That case used to hide the button on the grounds that an error from
            // the API is not fixed in the system's pane — but the pane has "+" and "−",
            // so a person can put uDeck in the list by hand, which is exactly what uDeck
            // could not do. It also used to disappear at the worst moment: a failed ask
            // replaces "macOS is waiting for you to allow it" with the error, and took
            // the way out with it.
            Button(strings(.generalOpenLoginItems)) { loginItem.openSystemSettings() }
                .accessibilityIdentifier("general.openLoginItems")
        }
        .padding(.top, 2)
    }

    private func headline(for message: LoginItemMessage) -> String {
        switch message {
        case .waitsForApproval: strings(.generalWaitsForApproval)
        case .vanished: strings(.generalRecordVanished)
        case .didNotTake: strings(.generalDidNotTake)
        case .couldNotAsk(let reason): strings(.generalLoginFailed(reason))
        }
    }

    /// One copy, not a list: naming three paths makes the sentence a table and the
    /// operator's problem is almost always the one other copy they forgot about.
    private func otherCopy(in message: LoginItemMessage) -> URL? {
        switch message {
        case .vanished(let copies), .didNotTake(let copies): copies.first
        case .waitsForApproval, .couldNotAsk: nil
        }
    }

    /// The home directory as a person writes it.
    private func shown(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }
}

/// uDeck's own updates, in General: what is installed and what was found,
/// **Check now** and **Update**, and what uDeck does by itself.
private struct UpdatesSection: View {
    var updater: any UpdateChecking
    @Environment(\.strings) private var strings

    /// Mirrors the updater's own switch rather than owning the answer: Sparkle
    /// stores it, and a copy here would be a second place it could be true.
    @State private var checksAutomatically = false
    @State private var updateMode: UpdateMode = .shipped
    @State private var notifies = true

    var body: some View {
        Section(strings(.updatesTitle)) {
            UpdateStatusRow(updater: updater)

            VStack(alignment: .leading, spacing: 4) {
                Toggle(strings(.updatesAutomatically), isOn: Binding(
                    get: { checksAutomatically },
                    set: {
                        checksAutomatically = $0
                        updater.checksAutomatically = $0
                    }
                ))
                .accessibilityIdentifier("updates.automatic")
                Text(strings(.updatesAutomaticallyHelp))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // The mode governs Check now too — in the modes that download,
            // what it finds is downloaded at once — so it stays live with
            // automatic checks off.
            VStack(alignment: .leading, spacing: 4) {
                Picker(strings(.updatesWhenNew), selection: Binding(
                    get: { updateMode },
                    set: { updateMode = $0; updater.updateMode = $0 }
                )) {
                    Text(strings(.updatesModeTell)).tag(UpdateMode.tell)
                    Text(strings(.updatesModeDownloadAhead)).tag(UpdateMode.downloadAhead)
                    Text(strings(.updatesModeInstallByItself)).tag(UpdateMode.installByItself)
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("updates.mode")
                Text(strings(UpdateWords.modeHelp(updateMode)))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("updates.modeHelp")
            }

            VStack(alignment: .leading, spacing: 4) {
                Toggle(strings(.updatesNotify), isOn: Binding(
                    get: { notifies },
                    set: { notifies = $0; updater.notifiesAboutUpdates = $0 }
                ))
                .accessibilityIdentifier("updates.notify")
                Text(strings(.updatesNotifyHelp))
                    .font(.caption).foregroundStyle(.secondary)
                if notifies, updater.status.notificationsRefused == true {
                    HStack(spacing: 6) {
                        Image(systemName: "bell.slash").foregroundStyle(.orange)
                        Text(strings(.updatesNotifyDenied))
                        Link(strings(.updatesOpenNotificationSettings), destination: UpdateWords.notificationSettings)
                    }
                    .font(.caption)
                    .accessibilityIdentifier("updates.notifyDenied")
                }
            }
        }
        .onAppear {
            checksAutomatically = updater.checksAutomatically
            updateMode = updater.updateMode
            notifies = updater.notifiesAboutUpdates
            updater.refreshNotificationPermission()
        }
        // Back from macOS's notification settings, the refusal is read again.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            updater.refreshNotificationPermission()
        }
    }
}

/// What is installed, what was found, and the buttons that act on it.
private struct UpdateStatusRow: View {
    var updater: any UpdateChecking
    @Environment(\.strings) private var strings

    var body: some View {
        let status = updater.status
        HStack(alignment: .center, spacing: 10) {
            UpdateWords.symbol(status.stage)
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 3) {
                // Two numbers rather than one sentence. "Up to date" asks to be
                // believed; "installed 0.1.0, latest 0.1.0" can be checked.
                HStack(spacing: 5) {
                    Text(strings(.updatesInstalled)).foregroundStyle(.secondary)
                    Text(status.installedVersion).monospacedDigit()
                        .accessibilityIdentifier("updates.installedVersion")
                    if let latest = status.latestVersion {
                        Text("·").foregroundStyle(.secondary)
                        Text(strings(.updatesLatest)).foregroundStyle(.secondary)
                        Text(latest).monospacedDigit()
                    }
                }
                UpdateWords.sentence(status, strings: strings)
                let notesVersion = status.latestVersion ?? status.installedVersion
                if let notes = ReleaseNotes.page(for: notesVersion) {
                    Link(strings(.updatesWhatsNew(notesVersion)), destination: notes)
                        .font(.caption)
                        .accessibilityIdentifier("updates.whatsNew")
                }
            }
            Spacer(minLength: 8)
            // These buttons reached accessibility with no name of their own:
            // System Events read `name` as missing value and the description as
            // just "button", so the only way to press one from outside was by its
            // position on screen. An identifier addresses the control without
            // depending on the translated title, and it is what a screen reader's
            // scripting hooks look for.
            //
            // One button (0.9.12): it looks, downloads what it finds and
            // restarts into it — an update in one press, as the operator asked
            // (11-24), where it used to take Check now, a wait and Update. What
            // was found or downloaded already is put in by the same press,
            // named **Update**.
            switch status.stage {
            case .available:
                Button(strings(.updatesUpdate)) { updater.install() }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("updates.install")
            case .readyToInstall:
                Button(strings(.updatesUpdate)) { updater.install() }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("updates.restartAndInstall")
            default:
                Button(strings(.updatesCheckAndInstall)) { updater.install() }
                    .buttonStyle(.borderedProminent)
                    .disabled(UpdateWords.isLooking(status.stage))
                    .accessibilityIdentifier("updates.checkAndInstall")
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Opening

/// How the panel comes out: the gesture at the top edge, the keyboard
/// shortcut, and how the panel behaves once it is out.
///
/// A grouped form, as General — the operator's choice on the redesign canvas
/// (2026-11-18, Opening1): the gesture's three sliders beside a drawing of
/// where it fires, the shortcut as a field that records the combination
/// pressed into it — it replaced four modifier toggles and a list of keys,
/// which asked the operator to spell a shortcut out instead of pressing it —
/// and a Behaviour group. That group took "keep running plugins while the
/// panel is away" from Plugins: it is about what happens while the panel is
/// away, which is this pane's subject.
///
/// Every switch carries `opening.<the setting it writes>`, the field
/// `opening.shortcut`: the lab finds them by these in either language, where
/// it used to count unnamed checkboxes down the screen.
private struct OpeningSettings: View {
    @Bindable var model: DeckModel
    @Environment(\.strings) private var strings

    private func binding<Value>(_ keyPath: WritableKeyPath<AppSettings, Value>) -> Binding<Value> {
        Binding(
            get: { model.settings[keyPath: keyPath] },
            set: { newValue in
                var settings = model.settings
                settings[keyPath: keyPath] = newValue
                model.update(settings: settings)
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PaneTitle(strings(.sectionOpening))
            form
        }
    }

    private var form: some View {
        Form {
            Section(strings(.openingEdgeGroup)) {
                Toggle(strings(.openingGestureToggle), isOn: binding(\.gesture.enabled))
                    .accessibilityIdentifier("opening.gesture.enabled")
                HStack(alignment: .center, spacing: 16) {
                    EdgeDiagram(caption: strings(.openingWhereItFires), described: strings(.openingWhereItFiresDescribed))
                    sliders
                }
                .padding(.vertical, 2)
                // The sliders tune a gesture that is off: shown, so the operator
                // sees what turning it on brings back, and not movable.
                .disabled(!model.settings.gesture.enabled)
                .opacity(model.settings.gesture.enabled ? 1 : 0.5)
            }

            Section {
                ShortcutRow(model: model, enabled: binding(\.hotkey.enabled))
            } header: {
                Text(strings(.openingShortcutGroup))
            } footer: {
                // A fact about uDeck worth stating once, under the one setting
                // that could look like it watches the keyboard.
                Text(strings(.openingPermissions))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section(strings(.openingBehaviour)) {
                Picker(strings(.openingHeldLeave), selection: Binding(
                    get: { model.settings.heldPanelLeave ?? .standard },
                    set: { binding(\.heldPanelLeave).wrappedValue = $0 }
                )) {
                    ForEach(HeldPanelLeave.allCases, id: \.self) { leave in
                        Text(strings(.openingHeldLeaveChoice(leave))).tag(leave)
                    }
                }
                .accessibilityIdentifier("opening.heldPanelLeave")
                Toggle(strings(.openingRetract), isOn: binding(\.collapseOnAppSwitch))
                    .accessibilityIdentifier("opening.collapseOnAppSwitch")
                Toggle(strings(.openingFullscreen), isOn: binding(\.gesture.enabledInFullscreen))
                    .accessibilityIdentifier("opening.gesture.enabledInFullscreen")
                Toggle(strings(.openingKeepPolling), isOn: binding(\.pollWhileCollapsed))
                    .accessibilityIdentifier("opening.pollWhileCollapsed")
            }
        }
        .formStyle(.grouped)
    }

    /// The three numbers of the gesture, a label, a slider and its value each,
    /// with the one line that says which way the first one cuts.
    private var sliders: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
            slider(
                .openingPauseFirst, binding(\.gesture.dwellDuration), in: 0.08 ... 0.8, step: 0.02,
                readout: strings(.unitMilliseconds(Int((model.settings.gesture.dwellDuration * 1000).rounded()))),
                id: "opening.gesture.dwellDuration"
            )
            GridRow {
                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                Text(strings(.openingPauseHelp))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .gridCellColumns(2)
            }
            slider(
                .openingPushPast, binding(\.gesture.edgePushDistance), in: 10 ... 120, step: 5,
                readout: strings(.unitPoints(Int(model.settings.gesture.edgePushDistance))),
                id: "opening.gesture.edgePushDistance"
            )
            slider(
                .openingStayQuiet, binding(\.gesture.reopenCooldown), in: 0 ... 2, step: 0.1,
                readout: strings(.unitSeconds(model.settings.gesture.reopenCooldown)),
                id: "opening.gesture.reopenCooldown"
            )
        }
    }

    /// Generic over the number, because one of these three is a `CGFloat` — a
    /// distance in points — and the rest are plain `Double`s.
    private func slider<V: BinaryFloatingPoint>(
        _ title: Phrase,
        _ value: Binding<V>,
        in range: ClosedRange<V>,
        step: V.Stride,
        readout: String,
        id: String
    ) -> some View where V.Stride: BinaryFloatingPoint {
        GridRow {
            Text(strings(title))
                .frame(minWidth: 130, alignment: .leading)
            // With `step:`, which draws a tick under every step: without it the
            // keyboard's own increment could be smaller than half a step and be
            // rounded away, leaving a slider that arrows cannot move (Fable,
            // stage-3 review). The ticks are the cheaper of the two.
            Slider(value: value, in: range, step: step) { Text(strings(title)) }
                .labelsHidden()
                .accessibilityIdentifier(id)
            Text(readout)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 54, alignment: .trailing)
        }
    }
}

/// Where the gesture fires, drawn: the top of a screen, the panel's place at
/// the notch, the strip that answers the cursor in orange, and the cursor in it.
///
/// The strip is wider than the notch on purpose and so is the drawing — it is
/// the anchor with a margin each side (`GestureTuning.stripSideMargin`). A
/// picture rather than a control, so it keeps its own colours in dark mode, the
/// way an illustration does.
private struct EdgeDiagram: View {
    var caption: String
    /// What the drawing shows, in words, for VoiceOver — the caption alone
    /// names a colour.
    var described: String

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(red: 0.914, green: 0.933, blue: 0.961)
            // The menu bar.
            Color(red: 0.788, green: 0.827, blue: 0.878).frame(height: 6)
            // The panel's place: the notch, or the one uDeck draws on a screen without one.
            UnevenRoundedRectangle(bottomLeadingRadius: 7, bottomTrailingRadius: 7)
                .fill(Color(red: 0.110, green: 0.114, blue: 0.129))
                .frame(width: 60, height: 18)
                .offset(x: 45)
            // Where the cursor opens it.
            Color(red: 1.0, green: 0.624, blue: 0.039)
                .frame(width: 90, height: 3)
                .offset(x: 30)
            CursorArrow()
                .fill(Color.white)
                .overlay(CursorArrow().stroke(Color(red: 0.114, green: 0.114, blue: 0.122), lineWidth: 1.05))
                .frame(width: 18, height: 18)
                .offset(x: 66, y: 40)
            Text(caption)
                .font(.system(size: 10))
                .foregroundStyle(Color(red: 0.235, green: 0.235, blue: 0.263))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(width: 136, alignment: .leading)
                .offset(x: 8, y: 84)
        }
        .frame(width: 150, height: 104)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(red: 0.875, green: 0.890, blue: 0.918)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(described)
    }
}

/// The arrow of the pointer, on a 24-point square: the canvas's own path.
private struct CursorArrow: Shape {
    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 24
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * scale, y: rect.minY + y * scale)
        }
        var path = Path()
        path.move(to: point(6, 3))
        path.addLine(to: point(19, 11))
        path.addLine(to: point(13, 12.5))
        path.addLine(to: point(10, 19))
        path.closeSubpath()
        return path
    }
}

/// The keyboard shortcut: a field that records the combination pressed into
/// it, and the switch.
///
/// A click starts recording, and the panel lets its shortcut go meanwhile
/// (`DeckModel.shortcutRecording`): a combination the window server holds for
/// uDeck never reaches the window as a key press, so the field could not
/// record the shortcut it already is. The next key press decides
/// (`HotKeyBinding.recording`): a combination uDeck can register becomes the
/// shortcut at once; Escape alone cancels; a bare key, one uDeck cannot bind, or
/// one that would take typing or a menu command from every application says
/// why and keeps listening. A click anywhere else, another window, another
/// application or another pane stops it, and the shortcut from before is taken
/// back; a click on the field itself starts it again.
private struct ShortcutRow: View {
    @Bindable var model: DeckModel
    var enabled: Binding<Bool>
    @Environment(\.strings) private var strings

    @State private var recording = false
    /// The modifiers held down while recording, shown in the field as they are pressed.
    @State private var held: Set<HotKeyModifier> = []
    /// The last key press that could not be a shortcut, while recording.
    @State private var refused: HotKeyRecording?
    @State private var keys: Any?
    @State private var leaving: [any NSObjectProtocol] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(strings(.openingShortcutToggle))
                    Text(strings(recording ? .openingShortcutRecordingHint : .openingShortcutHint))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                field
                Toggle(strings(.openingShortcutToggle), isOn: enabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .accessibilityIdentifier("opening.hotkey.enabled")
            }
            if let problem {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(problem).fixedSize(horizontal: false, vertical: true)
                }
                .font(.caption)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("opening.shortcutProblem")
            }
        }
        .onDisappear { stop() }
    }

    private var field: some View {
        Button {
            if recording { stop() } else { start() }  // see `take`: a click while recording arrives here stopped
        } label: {
            Text(shown)
                .font(.system(size: 14))
                .tracking(2)
                // Grey for a prompt, and for a shortcut that is switched off.
                .foregroundStyle(
                    (recording && held.isEmpty) || (!recording && !enabled.wrappedValue) ? Color.secondary : Color.primary
                )
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                // One width whatever it reads: a field that grew while it
                // recorded would push the switch beside it about.
                .frame(width: 104)
                .padding(.horizontal, 14)
                .frame(minHeight: 28)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(
                    RoundedRectangle(cornerRadius: 6).strokeBorder(
                        recording ? Color.accentColor : Color(nsColor: .separatorColor),
                        lineWidth: recording ? 2 : 1
                    )
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Not disabled with the switch: a shortcut turned off because it could
        // not be registered — one with no modifier left, written by an older
        // uDeck, or a key this one has no name for — is mended here, and
        // recording one turns it back on (`HotKeyBinding.recording`).
        .accessibilityLabel(
            recording ? strings(.openingShortcutRecordingHint)
                : strings(.openingShortcutField(model.settings.hotkey.displayName))
        )
        // What the field reads, so a click on it can be heard to have started
        // recording — VoiceOver, and the lab reading the control back.
        .accessibilityValue(shown)
        .accessibilityIdentifier("opening.shortcut")
    }

    /// What the field reads: the shortcut, or — while recording — the
    /// modifiers held so far, or a prompt.
    private var shown: String {
        guard recording else { return model.settings.hotkey.displayName }
        if held.isEmpty { return strings(.openingShortcutPrompt) }
        return held.sorted().map(\.symbol).joined()
    }

    private var problem: String? {
        if recording {
            switch refused {
            case .needsModifier: return strings(.openingNeedsModifier)
            case .notBindable: return strings(.openingNotBindable)
            case .typesText: return strings(.openingTypesText)
            case .menuCommand: return strings(.openingMenuCommand)
            default: return nil
            }
        }
        guard enabled.wrappedValue, model.shortcutRefused else { return nil }
        return strings(.openingShortcutTaken(model.settings.hotkey.displayName))
    }

    private func start() {
        guard !recording, keys == nil else { return }
        recording = true
        held = []
        refused = nil
        model.shortcutRecording(true)
        keys = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged, .leftMouseDown]) { event in
            MainActor.assumeIsolated { take(event) } ? nil : event
        }
        // Recording ends when the keys stop coming here: the window the click
        // came from stops being the key window — closed, or another chosen —
        // or uDeck stops being the active application.
        let center = NotificationCenter.default
        var watched: [(Notification.Name, AnyObject?)] = [(NSApplication.didResignActiveNotification, NSApp)]
        if let window = NSApp.keyWindow { watched.append((NSWindow.didResignKeyNotification, window)) }
        leaving = watched.map { name, object in
            center.addObserver(forName: name, object: object, queue: .main) { _ in
                MainActor.assumeIsolated { stop() }
            }
        }
    }

    /// One event while recording; true when it was the field's and goes no further.
    private func take(_ event: NSEvent) -> Bool {
        switch event.type {
        case .flagsChanged:
            held = Self.modifiers(event.modifierFlags)
            return false
        case .leftMouseDown:
            // Any click ends recording, here and at once, before the click is
            // delivered: one elsewhere leaves it ended, and one on the field
            // reaches the field's button afterwards — on the mouse-up — which
            // finds it not recording and starts again. Always that order, so a
            // click on the field while it records restarts it; Escape cancels.
            stop()
            return false
        case .keyDown:
            if event.isARepeat { return true }
            let answer = HotKeyBinding.recording(
                keyCode: UInt32(event.keyCode), modifiers: Self.modifiers(event.modifierFlags)
            )
            switch answer {
            case .cancelled:
                stop()
            case .recorded(let binding):
                // Saved while the shortcut is let go, so the panel takes it
                // once, when `stop` gives the shortcut back.
                var settings = model.settings
                settings.hotkey = binding
                model.update(settings: settings)
                stop()
            case .needsModifier, .notBindable, .typesText, .menuCommand:
                refused = answer
            }
            return true
        default:
            return false
        }
    }

    private func stop() {
        if let keys { NSEvent.removeMonitor(keys) }
        keys = nil
        for observer in leaving { NotificationCenter.default.removeObserver(observer) }
        leaving = []
        guard recording else { return }
        recording = false
        held = []
        refused = nil
        model.shortcutRecording(false)
    }

    private static func modifiers(_ flags: NSEvent.ModifierFlags) -> Set<HotKeyModifier> {
        var found: Set<HotKeyModifier> = []
        if flags.contains(.control) { found.insert(.control) }
        if flags.contains(.option) { found.insert(.option) }
        if flags.contains(.shift) { found.insert(.shift) }
        if flags.contains(.command) { found.insert(.command) }
        return found
    }
}


// MARK: - Look

/// Everything about how the panel looks, on three pages.
///
/// The main page asks two questions apart, as the operator chose on the
/// redesign canvas (2026-11-19): whether the panel is light or dark (the
/// appearance, one row) and what it is made of (a style, one click, holding a
/// light and a dark variant). Behind two › rows: fine tuning of either variant,
/// every knob; and the look of each state of the panel. Prose only where a
/// control is about to do something surprising — the samples are live, which is
/// what replaces the paragraphs.
private struct LookSettings: View {
    @Bindable var model: DeckModel
    @Environment(\.strings) private var strings

    /// Which of the two looks the knobs below are editing.
    ///
    /// Not the one that is showing. The dark look has to be set up in daylight,
    /// and a settings screen that only lets you edit what you can currently see
    /// is one you have to wait until evening to finish.
    @State private var editingDark: Bool?
    /// Which group of situations the controls below are setting up. Nothing
    /// selected means the theme's own look, which is what the panel had before
    /// there were any groups.
    @State private var selectedLink: UUID?

    /// What the operator is typing into the name field. Held here rather than
    /// in the settings, because a half-typed name is not a setting.
    @State private var newPresetName = ""

    /// The three pages of the pane (the redesign, 2026-11-19): the main one —
    /// the sample, the style, the appearance — and, behind its two › rows, fine
    /// tuning of either variant and the look of each state of the panel.
    enum Page { case main, fine, states }
    @State private var page: Page = .main
    /// Whether the field naming a style of one's own is open.
    @State private var naming = false
    /// The states' arrangement "set them all up together" replaced
    /// (`IslandStatesEditor.previous`), held for as long as this pane is.
    @State private var statesBefore: IslandStates?

    /// Whichever look the knobs are pointed at: the one being edited if the
    /// operator has picked one, otherwise the one on screen.
    private var edited: Bool {
        editingDark ?? model.settings.isDark(
            systemIsDark: DeckModel.systemIsDark(), hour: DeckModel.currentHour()
        )
    }

    /// The link the controls are editing, or `nil` when they edit the theme's
    /// own look — which is the case both when nothing is selected and when the
    /// selection is a link that holds every state.
    private var editedLink: IslandLink? {
        guard page == .states, let selectedLink,
              let link = model.settings.theme.states.links.first(where: { $0.id == selectedLink }),
              link.states.count < IslandState.allCases.count
        else { return nil }
        return link
    }

    /// What the controls below are setting up, in words.
    private var editingSummary: String {
        if selectionIsMixed { return strings(.lookStateMixed) }
        guard let link = editedLink else { return strings(.lookEditingEverything) }
        // Past three, the list is longer than the column it is explaining and
        // the frame already shows which ones they are.
        guard link.states.count <= 3 else { return strings(.lookEditingCount(link.states.count)) }
        let names = link.states.map { state -> String in
            let phase: Phrase = switch state.phase {
            case .collapsed: .statePhaseCollapsed
            case .peek: .statePhasePeek
            case .open: .statePhaseOpen
            case .fullscreen: .statePhaseFullscreen
            }
            let surrounding = state.surrounding == .fullscreenApp
                ? " · \(strings(.stateSurroundingFullscreen))"
                : ""
            return strings(phase) + surrounding
        }
        return "\(strings(.lookEditingStates)): " + names.joined(separator: ", ")
    }

    /// Kept so the editing line can say something is odd; a group is now the
    /// only thing that can be selected, so nothing is ever mixed.
    private var selectionIsMixed: Bool { false }

    private var editedLook: PanelLook {
        let base = model.settings.theme.look(forDark: edited)
        guard let link = editedLink, let state = link.states.first else { return base }
        return model.settings.theme.states.look(for: state, isDark: edited, base: base)
    }

    /// A binding into the look being edited, rather than into the resolved copy
    /// everything draws from — writing to that would be writing to a cache the
    /// next resolve throws away.
    /// A binding into whatever the controls are pointed at.
    ///
    /// `field` is which value it is, and it decides where the write lands: a
    /// value the operator has marked as the same everywhere is kept in the
    /// theme's own look, whatever states are selected, which is what makes
    /// "everywhere" true rather than a label.
    private func look<Value>(
        _ keyPath: WritableKeyPath<PanelLook, Value>,
        _ field: LookField? = nil
    ) -> Binding<Value> {
        Binding(
            get: { editedLook[keyPath: keyPath] },
            set: { newValue in
                // Nothing sensible to write: the selection spans two links with
                // two different answers, and picking one of them silently is
                // how a settings screen loses the operator's trust.
                guard !selectionIsMixed else { return }
                var settings = model.settings
                let isShared = field.map { settings.theme.states.shared.contains($0) } ?? false
                // A link of its own keeps its own copy, and the theme's look
                // stays where it was, so unlinking the states later lands them
                // back on something sensible; a shared value moves alone
                // (`ThemeSettings.write`).
                settings.theme.write(keyPath, newValue, edited: editedLook, link: editedLink, shared: isShared,
                                     dark: edited)
                model.update(settings: settings)
            }
        )
    }

    /// The switch that says "this value is the same in every state".
    ///
    /// Drawn beside the value it governs rather than gathered into a list
    /// somewhere, because it is a fact about that value and nothing else.
    /// Hidden while there is only one link and nothing is shared: with every
    /// state already set up together the switch would be a no-op with an
    /// explanation attached.
    @ViewBuilder
    private func chain(_ fields: Set<LookField>) -> some View {
        let shared = model.settings.theme.states.shared
        // Only where the states are: on fine tuning "the same in every state"
        // would be a switch about something that page does not show.
        if page == .states, model.settings.theme.states.links.count > 1 || !shared.isEmpty {
            Toggle(isOn: Binding(
                get: { fields.allSatisfy(shared.contains) },
                set: { share(fields, $0) }
            )) {
                Image(systemName: fields.allSatisfy(shared.contains) ? "link" : "link.badge.plus")
            }
            .toggleStyle(.button)
            .controlSize(.small)
            .labelStyle(.iconOnly)
            .help(strings(.lookSharedEverywhere))
        } else {
            Color.clear.frame(width: 1, height: 1)
        }
    }

    /// Marking a value as the same everywhere, or letting it go again.
    ///
    /// Both directions are written so that nothing on screen moves at the
    /// moment of the click. Turning it on takes the value the operator is
    /// looking at and makes it the one everybody gets; turning it off writes
    /// that same value into every link that had one of its own, so each state
    /// keeps what it was showing and simply stops following.
    private func share(_ fields: Set<LookField>, _ shared: Bool) {
        var settings = model.settings
        settings.theme.setShared(fields, shared, editing: edited, source: editedLook)
        model.update(settings: settings)
    }

    /// A binding straight into the settings, for the rows that are not about
    /// the look being edited. `look` and `theme` above write into one pole of
    /// the theme; this writes the setting itself.
    private func settings<Value>(_ keyPath: WritableKeyPath<AppSettings, Value>) -> Binding<Value> {
        Binding(
            get: { model.settings[keyPath: keyPath] },
            set: { newValue in
                var settings = model.settings
                settings[keyPath: keyPath] = newValue
                model.update(settings: settings)
            }
        )
    }

    private func theme<Value>(_ keyPath: WritableKeyPath<ThemeSettings, Value>) -> Binding<Value> {
        Binding(
            get: { model.settings.theme[keyPath: keyPath] },
            set: { newValue in
                var settings = model.settings
                settings.theme[keyPath: keyPath] = newValue
                model.update(settings: settings)
            }
        )
    }

    /// What the "start from" menu calls itself: the style whose variant on
    /// this tab the look matches, or the honest answer that it matches none.
    private var startingPointName: String {
        // Values shared by every state are not a style's to decide, and
        // pouring one keeps them — so they are left out here as well.
        let shared = model.settings.theme.states.shared
        let isThis = { (look: PanelLook) in look.taking(shared, from: editedLook) == editedLook }
        if let style = PanelStyle.allCases.first(where: { isThis($0.look(forDark: edited)) }) {
            return strings(style.namePhrase)
        }
        if let mine = model.settings.theme.saved.first(where: { isThis(edited ? $0.darkLook : $0.look) }) {
            return mine.name
        }
        return strings(.lookOwnStyle)
    }

    /// The one note worth keeping, because it is the only control on this
    /// screen that can silently do nothing.
    ///
    /// The tint is painted by uDeck over the material rather than handed to it,
    /// so the material only shows through whatever the tint leaves. Measured on
    /// the running panel: the two characters are 19 points of 255 apart with no
    /// tint, and 8 at 72%. Without this the operator concludes the control is
    /// broken, which is what happened.
    private var characterWarning: String? {
        guard editedLook.glass.tinted, editedLook.glass.tintStrength > 0.5 else { return nil }
        return strings(.lookTintCoversMaterial(
            percent: Int((editedLook.glass.tintStrength * 100).rounded())
        ))
    }

    /// Pouring a preset in goes wherever the knobs go: into the link being
    /// edited if there is one, otherwise into the theme's own look. One rule
    /// for the whole pane — a preset that ignored the selection would be the
    /// one control on the screen that means something else.
    private func pour(_ poured: PanelLook) {
        var settings = model.settings
        var look = poured
        // Values marked as the same everywhere stay that way: a preset is about
        // the character of the panel, not about undoing that decision.
        look = look.taking(settings.theme.states.shared, from: editedLook)
        if let link = editedLink {
            if edited { settings.theme.states.dark[link.id] = look }
            else { settings.theme.states.light[link.id] = look }
        } else {
            settings.theme.setLook(look, forDark: edited)
        }
        model.update(settings: settings)
    }

    /// Saves both looks as a style of the operator's own — the light variant
    /// and the dark one, whichever of them the knobs were pointed at.
    private func saveStyle() {
        var settings = model.settings
        let saved: PanelPreset?
        if page == .states, let state = editedLink?.states.first {
            // The group being set up, both variants as it wears them.
            saved = settings.theme.saveStyle(
                as: newPresetName,
                light: settings.theme.look(for: state, forDark: false),
                dark: settings.theme.look(for: state, forDark: true)
            )
        } else {
            saved = settings.theme.saveStyle(as: newPresetName)
        }
        guard saved != nil else { return }
        model.update(settings: settings)
        newPresetName = ""
        naming = false
    }

    private func percent(_ value: Double) -> String {
        strings(.unitPercent(Int((value * 100).rounded())))
    }

    var body: some View {
        Group {
            switch page {
            case .main: mainPage
            case .fine: subpage(strings(.lookFineTuning)) { finePage }
            case .states: subpage(strings(.lookByState)) { statesPage }
            }
        }
        // A name for a style of one's own: an alert with a field rather than a
        // popover from a card in a list-backed form, which may be dismissed
        // when the row lays out again; the field takes the keyboard at once.
        .alert(strings(.lookSaveStyle), isPresented: $naming) {
            TextField(strings(.lookNameThisLook), text: $newPresetName)
                .accessibilityIdentifier("look.styleName")
            Button(strings(.actionSave), action: saveStyle)
            Button(strings(.actionCancel), role: .cancel) { newPresetName = "" }
        }
    }

    /// Each state of the panel and what it looks like, in either variant.
    ///
    /// Two columns rather than one long scroll: the situations stay put on
    /// the left while the right half changes under them, and the sample sits
    /// directly above the knobs that move it. In one column the operator was
    /// setting a slider at the bottom of the window and watching for the
    /// result at the top of it.
    private var statesPage: some View {
        HStack(alignment: .top, spacing: 20) {
            situations
            VStack(alignment: .leading, spacing: 14) {
                Text(editingSummary)
                    .font(.caption)
                    .foregroundStyle(selectionIsMixed ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
                sample
                Divider()
                knobs
            }
            .frame(maxWidth: 560, alignment: .leading)
        }
    }

    /// Which situation the sample draws.
    ///
    /// The first of the selected ones, in the order they are declared, so that
    /// selecting a link shows the state that link is mostly about — a group
    /// made of "away" and "away over a film" is a group about being away.
    private var sampledState: IslandState {
        editedLink?.states.first
            ?? selectedLink.flatMap { id in
                model.settings.theme.states.links.first { $0.id == id }?.states.first
            }
            ?? IslandState(phase: .peek, surrounding: .ordinary)
    }

    /// The left column: every situation the island can be in, and which of them
    /// are set up together.
    private var situations: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(strings(.lookStates))
                .font(.caption)
                .foregroundStyle(.secondary)
            IslandStatesEditor(model: model, selected: $selectedLink, previous: $statesBefore)
        }
        .frame(width: 236, alignment: .leading)
    }

    // MARK: - The main page

    /// The sample, the style and the appearance — what most people come here
    /// for — as the operator chose them on the canvas (2026-11-19): whether the
    /// panel is light or dark is one row, as macOS and Slack ask it, and what it
    /// is made of is one click on a style that holds both variants. Fine tuning
    /// of either variant and the look of each state are behind the two › rows.
    private var mainPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            PaneTitle(strings(.sectionLook))
            Form {
                Section { samples }
                Section(strings(.lookStyle)) { styleCards }
                Section(strings(.lookIslandGroup)) {
                    IslandPreview(choice: model.settings.notchAttention ?? .standard,
                                  glows: model.settings.islandGlowsWhenWaiting ?? true,
                                  theme: DeckTheme(density: model.settings.density,
                                                   look: model.settings.look(for: IslandState(phase: .collapsed,
                                                                                              surrounding: .ordinary)),
                                                   textSize: model.settings.resolvedTextSize))
                    Picker(strings(.lookNotchAttention), selection: Binding(
                        get: { model.settings.notchAttention ?? .standard },
                        set: { newValue in
                            var settings = model.settings
                            settings.notchAttention = newValue
                            model.update(settings: settings)
                        }
                    )) {
                        ForEach(NotchAttention.allCases, id: \.self) { choice in
                            Text(strings(.lookNotchAttentionChoice(choice))).tag(choice)
                        }
                    }
                    .accessibilityIdentifier("look.notchAttention")
                    VStack(alignment: .leading, spacing: 2) {
                        Toggle(strings(.lookIslandGlows), isOn: Binding(
                            get: { model.settings.islandGlowsWhenWaiting ?? true },
                            set: { newValue in
                                var settings = model.settings
                                settings.islandGlowsWhenWaiting = newValue
                                model.update(settings: settings)
                            }
                        ))
                        .accessibilityIdentifier("look.islandGlowsWhenWaiting")
                        Text(strings(.lookIslandGlowsHelp)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Picker(strings(.lookAppearance), selection: Binding(
                            get: { model.settings.theme.appearance },
                            set: { newValue in
                                var settings = model.settings
                                settings.theme.appearance = newValue
                                model.update(settings: settings)
                            }
                        )) {
                            ForEach(ThemeAppearance.allCases) { appearance in
                                Text(strings(appearance.namePhrase)).tag(appearance)
                            }
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("look.appearance")
                        // The clock is chosen under fine tuning; said here, so
                        // "Match the system" is not taken at its word.
                        if model.settings.theme.source == .schedule {
                            Text(strings(.lookByClockCaption(
                                light: model.settings.theme.schedule.lightFromHour,
                                dark: model.settings.theme.schedule.darkFromHour
                            )))
                            .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Picker(strings(.lookDensity), selection: settings(\.density)) {
                        ForEach(Density.allCases, id: \.self) { density in
                            Text(strings(density.namePhrase)).tag(density)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("look.density")
                    LabeledContent(strings(.lookTextSize)) {
                        HStack(spacing: 8) {
                            Text(verbatim: "A").font(.caption).foregroundStyle(.secondary)
                            Slider(value: Binding(
                                get: { model.settings.resolvedTextSize },
                                set: { newValue in
                                    var settings = model.settings
                                    settings.textSize = newValue
                                    model.update(settings: settings)
                                }
                            ), in: AppSettings.textSizeRange, step: 0.5) { Text(strings(.lookTextSize)) }
                                .labelsHidden()
                                .frame(width: 200)
                                .accessibilityIdentifier("look.textSize")
                            Text(verbatim: "A").font(.title3).foregroundStyle(.secondary)
                            Text(String(format: "%.1f pt", model.settings.resolvedTextSize))
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                .frame(width: 46, alignment: .trailing)
                        }
                    }
                }
                Section {
                    pageRow(.lookFineTuning, summary: strings(.lookFineTuningSummary), to: .fine, id: "look.fineTuning")
                    pageRow(
                        .lookByState,
                        summary: strings(statesDiffer ? .lookByStateDiffers : .lookByStateSame),
                        to: .states, id: "look.byState"
                    )
                }
            }
            .formStyle(.grouped)
        }
    }

    /// The panel as it will look: both variants side by side, by day and in
    /// the evening, while it follows the Mac; the one it wears otherwise.
    private var samples: some View {
        let theme = model.settings.theme
        return HStack(spacing: 12) {
            if theme.appearance == .automatic {
                // What each variant follows: the Mac, or the clock.
                let byClock = theme.source == .schedule
                sample(of: theme.light, width: 300, caption: byClock
                       ? strings(.lookLightFromHour(theme.schedule.lightFromHour)) : strings(.lookSampleDay))
                sample(of: theme.dark, width: 300, caption: byClock
                       ? strings(.lookDarkFromHour(theme.schedule.darkFromHour)) : strings(.lookSampleEvening))
            } else {
                sample(of: theme.look(forDark: theme.manualIsDark), width: 520, caption: nil)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }

    private func sample(of look: PanelLook, width: CGFloat, caption: String?) -> some View {
        VStack(spacing: 4) {
            GlassPreview(glass: look.glass,
                         theme: DeckTheme(density: model.settings.density, look: look,
                                          textSize: model.settings.resolvedTextSize),
                         presence: look.presence,
                         width: width)
            if let caption {
                Text(caption).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// The styles that ship, the operator's own, the look as it is when it is
    /// none of them, and a card that saves it as one.
    ///
    /// A plain grid of five to a row, not a lazy one: a handful of cards, in a
    /// row of a grouped form, which is list-backed and re-lays out lazy content
    /// in its own time (Fable, stage-3 review).
    private var styleCards: some View {
        let theme = model.settings.theme
        let style = theme.style
        let saved = theme.savedStyle
        let items: [StyleItem] = PanelStyle.allCases.map(StyleItem.style)
            + theme.saved.map(StyleItem.saved)
            + (style == nil && saved == nil ? [.own] : [])
            + [.save]
        let rows = stride(from: 0, to: items.count, by: 5).map { Array(items[$0 ..< min($0 + 5, items.count)]) }
        return Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 12) {
            ForEach(rows.indices, id: \.self) { index in
                GridRow {
                    ForEach(rows[index]) { item in
                        card(item, style: style, saved: saved).frame(width: 112)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private enum StyleItem: Identifiable {
        case style(PanelStyle)
        case saved(PanelPreset)
        case own
        case save

        var id: String {
            switch self {
            case .style(let style): "style.\(style.rawValue)"
            case .saved(let preset): "saved.\(preset.id.uuidString)"
            case .own: "own"
            case .save: "save"
            }
        }
    }

    /// Whether the dark variant is in force now: each card shows the one the
    /// panel wears.
    private var wearsDark: Bool {
        model.settings.isDark(systemIsDark: DeckModel.systemIsDark(), hour: DeckModel.currentHour())
    }

    @ViewBuilder
    private func card(_ item: StyleItem, style: PanelStyle?, saved: PanelPreset?) -> some View {
        switch item {
        case .style(let candidate):
            StyleCard(name: strings(candidate.namePhrase), summary: strings(candidate.summaryPhrase),
                      light: candidate.light, dark: candidate.dark, wearsDark: wearsDark,
                      selected: style == candidate) {
                var settings = model.settings
                settings.theme.apply(candidate)
                model.update(settings: settings)
            }
            .accessibilityIdentifier("look.style.\(candidate.rawValue)")
        case .saved(let preset):
            StyleCard(name: preset.name, summary: nil, light: preset.look, dark: preset.darkLook,
                      wearsDark: wearsDark, selected: saved?.id == preset.id) {
                var settings = model.settings
                settings.theme.apply(preset)
                model.update(settings: settings)
            }
            .contextMenu {
                Button(strings(.actionDelete), role: .destructive) {
                    var settings = model.settings
                    settings.theme.remove(preset.id)
                    model.update(settings: settings)
                }
            }
            .accessibilityIdentifier("look.saved.\(preset.id.uuidString)")
        case .own:
            StyleCard(name: strings(.lookOwnStyle), summary: strings(.lookOwnStyleSummary),
                      light: model.settings.theme.light, dark: model.settings.theme.dark, wearsDark: wearsDark,
                      selected: true) {}
                .accessibilityIdentifier("look.style.own")
        case .save:
            Button { naming = true } label: {
                VStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .foregroundStyle(.secondary)
                        .frame(height: 44)
                        .overlay(Image(systemName: "plus").foregroundStyle(.secondary))
                    Text(strings(.lookSaveStyle)).font(.caption).lineLimit(1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("look.saveStyle")
        }
    }

    /// Whether any state of the panel looks different from the theme, in
    /// either variant — what it wears, not how the states are grouped.
    private var statesDiffer: Bool {
        let theme = model.settings.theme
        return IslandState.allCases.contains { state in
            theme.look(for: state, forDark: false) != theme.light
                || theme.look(for: state, forDark: true) != theme.dark
        }
    }

    /// A row that opens one of the two other pages.
    ///
    /// The variant the knobs edit is fixed on the way in — the one on screen —
    /// so the appearance turning over while the page is open does not move
    /// the knobs to the other variant under the operator's hand.
    private func pageRow(_ title: Phrase, summary: String, to target: Page, id: String) -> some View {
        Button {
            editingDark = model.settings.isDark(systemIsDark: DeckModel.systemIsDark(), hour: DeckModel.currentHour())
            page = target
        } label: {
            HStack(spacing: 8) {
                Text(strings(title))
                Spacer()
                Text(summary).font(.callout).foregroundStyle(.secondary)
                Image(systemName: "chevron.right").foregroundStyle(.tertiary).accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }

    /// One of the two other pages, under a way back.
    private func subpage<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        let inner = content()
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button { page = .main } label: { Image(systemName: "chevron.left") }
                    .accessibilityLabel(strings(.actionBack))
                    .accessibilityIdentifier("look.back")
                (Text(strings(.sectionLook) + " › ").foregroundStyle(.secondary) + Text(title))
                    .font(.title2.bold())
                    .accessibilityAddTraits(.isHeader)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            ScrollView {
                inner
                    .padding(20)
                    .padding(.bottom, 28)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Fine tuning

    /// The name of what the panel wears, for the fine-tuning page.
    private var styleName: String {
        let theme = model.settings.theme
        if let style = theme.style { return strings(style.namePhrase) }
        if let saved = theme.savedStyle { return saved.name }
        return "\(strings(.lookOwnStyle)) (\(strings(.lookOwnStyleSummary)))"
    }

    /// Either variant of the style, every knob of it: the light one is worn
    /// while the appearance is light, the dark one while it is dark. Moving a
    /// knob makes the style the operator's own, which the button saves with
    /// both variants.
    private var finePage: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Picker("", selection: Binding(get: { edited }, set: { editingDark = $0 })) {
                    Text(strings(.lookLightLook)).tag(false)
                    Text(strings(.lookDarkLook)).tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 260)
                .accessibilityLabel(strings(.lookFineTuning))
                .accessibilityIdentifier("look.variant")
                Text(strings(edited ? .lookVariantHintDark : .lookVariantHintLight))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
            }
            HStack(spacing: 10) {
                Text(strings(.lookStyleIs(styleName))).font(.callout)
                Button(strings(.lookSaveStyleAction)) { naming = true }
                    .accessibilityIdentifier("look.saveStyleAction")
            }
            GlassPreview(glass: editedLook.glass,
                         theme: DeckTheme(density: model.settings.density, look: editedLook,
                                          textSize: model.settings.resolvedTextSize),
                         presence: editedLook.presence)
            knobs.lookCard()
            byTheClock.lookCard()
        }
        .frame(maxWidth: 640, alignment: .leading)
    }

    /// Following the clock instead of the Mac: a way of changing by itself, so
    /// it applies only while the appearance does.
    private var byTheClock: some View {
        let current = model.settings.theme
        return VStack(alignment: .leading, spacing: 6) {
            Toggle(strings(.lookByClock), isOn: Binding(
                get: { current.source == .schedule },
                set: { on in
                    var settings = model.settings
                    settings.theme.source = on ? .schedule : .system
                    model.update(settings: settings)
                }
            ))
            .disabled(current.appearance != .automatic)
            .accessibilityIdentifier("look.byClock")
            if current.source == .schedule {
                HStack(spacing: 14) {
                    Stepper(strings(.lookLightFromHour(current.schedule.lightFromHour)),
                            value: theme(\.schedule.lightFromHour), in: 0 ... 23)
                    Stepper(strings(.lookDarkFromHour(current.schedule.darkFromHour)),
                            value: theme(\.schedule.darkFromHour), in: 0 ... 23)
                }
                .font(.callout)
            }
            if current.appearance != .automatic {
                Text(strings(.lookByClockOnlyAutomatic)).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - The sample

    private var sample: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Narrower than the 520 of a page of its own: beside the states'
            // column, 520 made the page wider than the window at its own size
            // and the whole window's content moved 25 pt left (the lab,
            // 2026-11-20 — in 0.8.13 too: the General row 2 pt from the
            // window's left on this page, 27 on every other).
            GlassPreview(glass: editedLook.glass,
                         theme: DeckTheme(density: model.settings.density, look: editedLook,
                                          textSize: model.settings.resolvedTextSize),
                         phase: sampledState.phase,
                         surrounding: sampledState.surrounding,
                         presence: editedLook.presence,
                         width: 440)

            // Two rows, not one: in one, the variant tabs, the style menu and
            // Save style… were wider than the column at the window's own size
            // ("Save style…" cut short in the lab's gallery, 2026-11-20).
            Picker("", selection: Binding(get: { edited }, set: { editingDark = $0 })) {
                Text(strings(.lookLightLook)).tag(false)
                Text(strings(.lookDarkLook)).tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            // Its own width: held to 220 the Russian names overflowed it and
            // it stood out of the column to the left (the lab's gallery).
            .fixedSize()

            HStack(spacing: 12) {
                // Labelled, because it was not. The menu showed only whichever
                // preset the look currently matched — "Custom" most of the
                // time — and the operator had to ask what it was.
                Text(strings(.lookStyle))
                    .foregroundStyle(.secondary)

                // The styles of the main page, each as its variant on the tab
                // above: a state set up in the dark variant takes a style's
                // dark look.
                Menu(startingPointName) {
                    Section(strings(.lookBuiltIn)) {
                        ForEach(PanelStyle.allCases) { style in
                            Button {
                                pour(style.look(forDark: edited))
                            } label: {
                                Text(strings(style.namePhrase))
                                Text(strings(style.summaryPhrase))
                            }
                        }
                    }
                    if !model.settings.theme.saved.isEmpty {
                        Section(strings(.lookSaved)) {
                            ForEach(model.settings.theme.saved) { preset in
                                Button(preset.name) { pour(edited ? preset.darkLook : preset.look) }
                            }
                        }
                    }
                }
                .frame(width: 150)

                // The group being set up, saved as a style of its own: both
                // variants as the group wears them (`saveStyle`).
                Button(strings(.lookSaveStyleAction)) { naming = true }
                    .accessibilityIdentifier("look.saveGroupStyle")
            }
        }
    }

    // MARK: - The knobs

    /// Every knob of the look being edited, one row each — its name on the
    /// left, its control on the right, a thin line between rows — as a grouped
    /// form draws its rows (board LookFine, the operator's «1» of 2026-11-19;
    /// the grid it replaces put the names in a right-aligned column of grey).
    private var knobs: some View {
        VStack(alignment: .leading, spacing: 0) {
            // First of the values rather than last, because it is the one that
            // answers "should this situation be noticeable at all" — and every
            // other row is about a panel that has already decided to be there.
            knobRow(strings(.lookQuietLevel), [.presence]) {
                slider(look(\.presence, .presence), in: PanelLook.presenceRange,
                       step: 0.05, readout: percent(editedLook.presence))
            }

            knobRow(strings(.lookGlass), [.glassStyle]) {
                Picker(strings(.lookGlass), selection: look(\.glass.style, .glassStyle)) {
                    Text(strings(.glassRegular)).tag(GlassStyle.regular)
                    Text(strings(.glassClear)).tag(GlassStyle.clear)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 200)
            }

            if let warning = characterWarning {
                Text(warning).font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .multilineTextAlignment(.trailing)
                    .padding(.bottom, 6)
            }

            knobRow(strings(.lookAmount), [.glassOpacity]) {
                slider(look(\.glass.opacity, .glassOpacity), in: GlassAppearance.opacityRange,
                       step: 0.05, readout: percent(editedLook.glass.opacity))
            }

            knobRow(strings(.lookTint), [.tinted, .tintDirection]) {
                HStack(spacing: 10) {
                    Toggle(strings(.lookTint), isOn: look(\.glass.tinted, .tinted)).labelsHidden()
                    Picker(strings(.lookTint), selection: look(\.glass.tintIsLight, .tintDirection)) {
                        Text(strings(.tintLighter)).tag(true)
                        Text(strings(.tintDarker)).tag(false)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 180)
                    .disabled(!editedLook.glass.tinted)
                }
            }

            knobRow(strings(.lookStrength), [.tintStrength]) {
                slider(look(\.glass.tintStrength, .tintStrength), in: GlassAppearance.tintStrengthRange,
                       step: 0.02, readout: percent(editedLook.glass.tintStrength))
                    .disabled(!editedLook.glass.tinted)
            }

            knobRow(strings(.lookTintColour), [.tintColour]) {
                HStack(spacing: 10) {
                    // Empty means the grey that "Lighter"/"Darker" names, which
                    // is what the tint always was. The toggle is the switch
                    // between "a shade of the background" and "a colour", and
                    // it reads better than a colour well that silently means
                    // grey when nobody has touched it.
                    Toggle(strings(.lookTintColour), isOn: Binding(
                        get: { editedLook.glass.tintColor != nil },
                        set: { wantsColour in
                            // Through the same binding as every other value, so
                            // that it lands wherever the selection points rather
                            // than always in the theme's own look.
                            look(\.glass.tintColor, .tintColour).wrappedValue = wantsColour
                                ? (editedLook.glass.tintIsLight ? .white : InkColor(red: 0, green: 0, blue: 0))
                                : nil
                        }
                    ))
                    .labelsHidden()
                    .disabled(!editedLook.glass.tinted)

                    if let colour = editedLook.glass.tintColor {
                        ColorPicker(strings(.lookTintColour), selection: Binding(
                            get: { Color(red: colour.red, green: colour.green, blue: colour.blue) },
                            set: { newValue in
                                guard let rgb = InkColor(newValue) else { return }
                                look(\.glass.tintColor, .tintColour).wrappedValue = rgb
                            }
                        ), supportsOpacity: false)
                        .labelsHidden()
                        .disabled(!editedLook.glass.tinted)
                    }
                }
            }

            knobRow(strings(.lookText), [.ink]) {
                Picker(strings(.lookText), selection: look(\.ink, .ink)) {
                    Text(strings(.lookLight)).tag(PanelInk.light)
                    Text(strings(.lookDark)).tag(PanelInk.dark)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 200)
            }

            knobRow(strings(.lookBrightness), [.inkBrightness]) {
                slider(look(\.inkBrightness, .inkBrightness), in: 0 ... 1,
                       step: 0.02, readout: percent(editedLook.inkBrightness))
            }

            knobRow(strings(.lookColour), [.inkColour], last: true) {
                HStack(spacing: 10) {
                    Toggle(strings(.lookColour), isOn: Binding(
                        get: { editedLook.inkColor != nil },
                        set: { wantsColour in
                            look(\.inkColor, .inkColour).wrappedValue = wantsColour
                                ? (editedLook.ink == .light ? .white : .black)
                                : nil
                        }
                    ))
                    .labelsHidden()

                    if let colour = editedLook.inkColor {
                        ColorPicker(strings(.lookColour), selection: Binding(
                            get: { Color(red: colour.red, green: colour.green, blue: colour.blue) },
                            set: { newValue in
                                guard let rgb = InkColor(newValue) else { return }
                                look(\.inkColor, .inkColour).wrappedValue = rgb
                            }
                        ), supportsOpacity: false)
                        .labelsHidden()
                    }
                }
            }
        }
    }

    // MARK: - Pieces

    /// One knob's row: its name on the left, its control on the right — and,
    /// on By panel state, the switch that shares the value across the states
    /// (`chain`) — with a thin line under it unless it is the last.
    private func knobRow<Control: View>(
        _ name: String,
        _ fields: Set<LookField>,
        last: Bool = false,
        @ViewBuilder control: () -> Control
    ) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                Text(name)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                control()
                chain(fields)
            }
            .padding(.vertical, 7)
            if !last {
                Divider()
            }
        }
    }

    /// Generic over the number, as Opening's is.
    private func slider<V: BinaryFloatingPoint>(
        _ value: Binding<V>,
        in range: ClosedRange<V>,
        step: V.Stride,
        readout: String
    ) -> some View where V.Stride: BinaryFloatingPoint {
        // With `step:` — see `OpeningSettings.slider`.
        HStack(spacing: 10) {
            Slider(value: value, in: range, step: step)
                .frame(width: 230)
            Text(readout)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 46, alignment: .trailing)
        }
    }
}


// MARK: - About

/// What uDeck is: a card, as macOS draws an application's About — its icon, its
/// name and version, what it is in one line, a way to check for a newer one, and
/// where it comes from. The settings for updates are in General (the redesign,
/// 2026-11-18); what is wrong with this build stays here, under the card.
private struct AboutSection: View {
    @Bindable var model: DeckModel
    var updater: (any UpdateChecking)?
    @Environment(\.strings) private var strings

    private var version: String? {
        updater?.status.installedVersion
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
    }

    var body: some View {
        Form {
            Section {
                VStack(spacing: 8) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 84, height: 84)
                        .accessibilityHidden(true)
                    Text(strings(.aboutTitle))
                        .font(.title.bold())
                    if let version {
                        Text(strings(.aboutVersion(version)))
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("about.version")
                    }
                    Text(strings(.aboutTagline))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    if let updater {
                        HStack(spacing: 10) {
                            UpdateWords.symbol(updater.status.stage)
                            // As in General: one press looks and puts in what it
                            // finds; what was found already is put in by it.
                            if UpdateWords.canInstall(updater.status.stage) {
                                Button(strings(.updatesUpdate)) { updater.install() }
                                    .buttonStyle(.borderedProminent)
                                    .accessibilityIdentifier("about.install")
                            } else {
                                Button(strings(.updatesCheckAndInstall)) { updater.install() }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(UpdateWords.isLooking(updater.status.stage))
                                    .accessibilityIdentifier("about.checkAndInstall")
                            }
                            UpdateWords.sentence(updater.status, strings: strings)
                        }
                        .padding(.top, 6)
                    }
                    HStack(spacing: 16) {
                        // The found version's page once there is one, as in General.
                        let notesVersion = updater?.status.latestVersion ?? version
                        if let notesVersion, let notes = ReleaseNotes.page(for: notesVersion) {
                            Link(strings(.updatesWhatsNew(notesVersion)), destination: notes)
                        }
                        Link("github.com/iillyyaa1997/udeck", destination: URL(string: "https://github.com/iillyyaa1997/udeck")!)
                        Text("Apache-2.0 · Copyright 2026 Ilya Volkov").foregroundStyle(.secondary)
                    }
                    .font(.caption)
                    .padding(.top, 2)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
            }

            Section(strings(.aboutThisBuild)) {
                VStack(alignment: .leading, spacing: 3) {
                    Label(strings(.aboutNotSigned), systemImage: "exclamationmark.shield")
                    Text(strings(.aboutAdHoc))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Label(strings(.aboutNotSandboxed), systemImage: "shield.slash")
                    Text(strings(.aboutReadPermissions))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if !model.problems.isEmpty {
                Section(strings(.aboutProblems)) {
                    ForEach(Array(model.problems.enumerated()), id: \.offset) { _, problem in
                        Text(problem)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    Button(strings(.actionClear)) { model.clearProblems() }
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// What General's updates and the About card both say about an update.
@MainActor
private enum UpdateWords {
    /// macOS's notification settings, at uDeck's own row where it goes there.
    static let notificationSettings = URL(
        string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=place.unicorns.udeck"
    )!

    static func modeHelp(_ mode: UpdateMode) -> Phrase {
        switch mode {
        case .tell: .updatesModeTellHelp
        case .downloadAhead: .updatesModeDownloadAheadHelp
        case .installByItself: .updatesModeInstallByItselfHelp
        }
    }

    /// Nothing to check while one is under way, or while a download waits for
    /// Update: the session it holds is Sparkle's until then.
    static func canCheck(_ stage: UpdateStage) -> Bool {
        switch stage {
        case .checking, .readyToInstall: false
        default: true
        }
    }

    /// Whether a look is under way: **Check and update** waits for it. A
    /// download is not — pressed then, what it brings is put in once it is in.
    static func isLooking(_ stage: UpdateStage) -> Bool {
        if case .checking = stage { return true }
        return false
    }

    /// Whether there is a found or a downloaded version for **Update** to put in.
    static func canInstall(_ stage: UpdateStage) -> Bool {
        switch stage {
        case .available, .readyToInstall: true
        default: false
        }
    }

    /// The state at a glance, beside the numbers.
    @ViewBuilder
    static func symbol(_ stage: UpdateStage) -> some View {
        switch stage {
        case .checking, .downloading:
            ProgressView().controlSize(.small)
        case .upToDate:
            Image(systemName: "checkmark.circle.fill").font(.title2).foregroundStyle(.green)
        case .available, .readyToInstall:
            Image(systemName: "arrow.down.circle.fill").font(.title2).foregroundStyle(.blue)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").font(.title2).foregroundStyle(.orange)
        case .idle:
            Image(systemName: "arrow.triangle.2.circlepath").font(.title3).foregroundStyle(.secondary)
        }
    }

    /// One line, in the state's own colour, saying what happened.
    @ViewBuilder
    static func sentence(_ status: UpdateStatus, strings: Strings) -> some View {
        switch status.stage {
        case .idle:
            Text(lastChecked(status.lastCheck, strings: strings)).font(.caption).foregroundStyle(.secondary)
        case .checking:
            Text(strings(.updatesChecking)).font(.caption).foregroundStyle(.secondary)
        case .upToDate:
            Text(strings(.updatesUpToDate) + " " + lastChecked(status.lastCheck, strings: strings))
                .font(.caption).foregroundStyle(.secondary)
        case .available(let version):
            Text(strings(.updatesAvailable(version))).font(.caption).foregroundStyle(.secondary)
        case .downloading(let fraction):
            HStack(spacing: 6) {
                if let fraction {
                    ProgressView(value: fraction).controlSize(.small).frame(width: 80)
                }
                Text(strings(.updatesDownloading))
            }
            .font(.caption).foregroundStyle(.secondary)
        case .readyToInstall:
            Text(strings(.updatesReady)).font(.caption).foregroundStyle(.secondary)
        case .failed(let reason):
            Text(strings(.updatesFailed(reason))).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    static func lastChecked(_ date: Date?, strings: Strings) -> String {
        guard let date else { return strings(.updatesNeverChecked) }
        // Under a minute the formatter rounds to zero and then picks the
        // future tense for it: "checked in 0 seconds", about something that has
        // already happened.
        guard Date().timeIntervalSince(date) >= 60 else { return strings(.updatesJustChecked) }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        // The panel's language, not the system's. Without this the sentence
        // came out half-translated — "Проверено 35 seconds ago" — which is the
        // one thing worse than being in the wrong language entirely.
        formatter.locale = Locale(identifier: strings.language.rawValue)
        return strings(.updatesLastChecked(formatter.localizedString(for: date, relativeTo: Date())))
    }
}

/// A pane's name over its grouped form, as the redesign draws it (2026-11-18):
/// the window's own title stays "uDeck Settings".
struct PaneTitle: View {
    var text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.title2.bold())
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A section in the sidebar: its symbol white on a rounded square of its own
/// colour, as System Settings draws its sidebar, and — for Plugins — how many
/// plugin updates wait: an arrow and a number, the operator's choice on the
/// redesign canvas (2026-11-18), in the row's own text colour on the chosen row
/// and the accent colour elsewhere.
private struct SidebarRow: View {
    var title: String
    var symbol: String
    var tint: Color
    var updates: Int
    /// The row of the pane on show. Its selection is the accent colour, and
    /// an arrow in the accent colour on it is not there to see — measured in
    /// the lab (gallery of 2026-11-19): `backgroundProminence` did not say
    /// `.increased` there, and the arrow came out blue on blue.
    var chosen: Bool

    var body: some View {
        HStack(spacing: 6) {
            Label {
                Text(title)
            } icon: {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .background(RoundedRectangle(cornerRadius: 5).fill(tint))
            }
            Spacer(minLength: 4)
            if updates > 0 {
                HStack(spacing: 2) {
                    Image(systemName: "arrow.up").accessibilityHidden(true)
                    Text("\(updates)")
                }
                .font(.caption.weight(.semibold))
                // The row's own text colour on the chosen row — white while
                // the window is in front, dark on the grey of one behind.
                .foregroundStyle(chosen ? AnyShapeStyle(.primary) : AnyShapeStyle(Color.accentColor))
            }
        }
    }
}

// MARK: - Layout helper

private struct SettingsGroup<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.title3).bold()
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 6)
    }
}


extension View {
    /// A group of rows on a page that is not a Form — fine tuning of Look — drawn
    /// as a grouped Form draws its sections, so the two pages read as one.
    func lookCard() -> some View {
        padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: .separatorColor).opacity(0.6)))
    }
}

/// A style on the Look pane: the variant in force now over the big preview's
/// two halves, its name and what it is.
private struct StyleCard: View {
    var name: String
    var summary: String?
    var light: PanelLook
    var dark: PanelLook
    /// Whether the dark variant is the one in force now.
    var wearsDark: Bool
    var selected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                StyleSwatch(look: wearsDark ? dark : light)
                .frame(height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8).strokeBorder(
                        selected ? Color.accentColor : Color(nsColor: .separatorColor),
                        lineWidth: selected ? 3 : 1
                    )
                )
                Text(name).font(.caption).fontWeight(selected ? .semibold : .regular).lineLimit(1)
                if let summary {
                    Text(summary).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(summary.map { "\(name), \($0)" } ?? name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A style drawn small, in the big preview's own language (the operator, 11-25:
/// coloured stripes behind every card «рябит и не приятно глазу»; «в нашем
/// стиле… есть темная и светлая часть»): the dark half and the paper half with
/// their thin ruling, and the panel across the seam in the look in force now —
/// a card is the preview above it, smaller. What tells the styles apart is what
/// each does to what is behind: the ruling blurs, is covered, or shows.
private struct StyleSwatch: View {
    var look: PanelLook

    var body: some View {
        ZStack {
            PreviewBackdrop(step: 9, lineWidth: 1)
            PanelSurface(shape: RoundedRectangle(cornerRadius: 5),
                         fallbackFill: DeckTheme(density: .normal, look: look).windowFill,
                         glass: look.glass)
                .overlay(alignment: .leading) {
                    Capsule().fill(ink).frame(width: 20, height: 3).padding(.leading, 9)
                }
                .opacity(look.presence)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
        }
    }

    private var ink: Color {
        let colour = look.foreground
        return Color(red: colour.red, green: colour.green, blue: colour.blue)
    }
}

/// What is behind the panel in a preview of it: a dark window and a white
/// document side by side — a tint that rescues the panel from a dark game is
/// the one that washes it out over a page — or, over another application's
/// full screen, a film. Thin grey ruling over it, so that the material has
/// something to bend.
private struct PreviewBackdrop: View {
    var film = false
    var step: CGFloat = 13
    var lineWidth: CGFloat = 1.5

    var body: some View {
        ZStack {
            if film {
                Color(red: 0.05, green: 0.05, blue: 0.06)
            } else {
                HStack(spacing: 0) {
                    Color(red: 0.09, green: 0.13, blue: 0.08)
                    Color(red: 0.90, green: 0.89, blue: 0.86)
                }
            }
            Canvas { context, size in
                var path = Path()
                var x = -size.height
                while x < size.width {
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x + size.height, y: size.height))
                    x += step
                }
                context.stroke(path, with: .color(.gray.opacity(0.75)), lineWidth: lineWidth)
            }
        }
    }
}

/// The panel, as it will actually look, over the two backgrounds that disagree
/// about it.
///
/// This is what replaced the paragraphs: one per variant on Look's main page
/// while the appearance follows the Mac, one above the knobs on the other two
/// pages.
///
/// The dark half and the light half are the whole of the trade-off: a tint that
/// rescues the panel from a dark game is the same tint that washes it out over
/// a white document. The ruling is there so the refraction is visible at all —
/// the material bends what is behind it, and a flat colour gives it nothing to
/// bend.
private struct GlassPreview: View {
    var glass: GlassAppearance
    var theme: DeckTheme
    /// Which situation is being set up. The sample is the panel as it will
    /// actually look, and "as it will look" includes how big it is: a slab the
    /// size of the open panel says nothing about the island.
    var phase: PanelPhase = .peek
    var surrounding: IslandSurrounding = .ordinary
    /// How much of it is there, so that «Видно» is visible here rather than
    /// only on the real panel.
    var presence: Double = 1
    /// How wide the sample is: the main page of Look puts two side by side.
    var width: CGFloat = 520
    @Environment(\.strings) private var strings

    /// The panel's size in each phase, in the sample's own scale.
    private var cardSize: CGSize {
        let size: CGSize = switch phase {
        case .collapsed: CGSize(width: 180, height: 30)
        case .peek: CGSize(width: 420, height: 92)
        case .open: CGSize(width: 470, height: 118)
        case .fullscreen: CGSize(width: 500, height: 132)
        }
        // Narrowed only for the two samples side by side; at the full width
        // the fullscreen slab keeps the 500 points it always had.
        return width < 520 ? CGSize(width: min(size.width, width - 36), height: size.height) : size
    }

    private var cardRadius: CGFloat { phase == .collapsed ? 9 : 12 }

    /// Whether the card has room for the sample card's three lines.
    private var showsContent: Bool { phase != .collapsed }

    var body: some View {
        ZStack {
            // What is behind the panel, which is half of what the operator is
            // judging. Over another application's full screen there is no white
            // document to worry about — there is a film, and the question is
            // whether the island is still findable on it.
            PreviewBackdrop(film: surrounding == .fullscreenApp)
            PanelSurface(
                shape: RoundedRectangle(cornerRadius: cardRadius),
                fallbackFill: theme.windowFill,
                glass: glass
            )
            .frame(width: cardSize.width, height: cardSize.height)
            .overlay {
                // A card, not a caption: the sample has to show the text, the
                // muted text and a state colour, because those are three of the
                // things the knobs below move and none of them is the glass.
                VStack(alignment: .leading, spacing: 5) {
                    if !showsContent {
                        // The island carries the mark and nothing else, which is
                        // what it carries on the screen.
                        Capsule().fill(theme.text.opacity(0.55))
                            .frame(width: 44, height: 4)
                    }
                    if showsContent { HStack(spacing: 8) {
                        Text(strings(.sampleTitle))
                            .font(theme.titleFont)
                            .foregroundStyle(theme.text)
                        Text(strings(.sampleChip))
                            .font(theme.chipFont)
                            .foregroundStyle(theme.color(for: CardState.ok))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(theme.chipFill(for: .ok)))
                    } }
                    if showsContent {
                        Text(strings(.sampleBody))
                            .font(theme.bodyFont)
                            .foregroundStyle(theme.muted)
                        Text(strings(.sampleFooter))
                            .font(theme.chipFont)
                            .foregroundStyle(theme.dim)
                    }
                }
                // Centred, so the card sits across the seam between the two
                // backdrops rather than entirely on the dark one. That is the
                // real case — the panel is a bar the width of the screen and
                // what is behind it changes along its length — and it is the
                // only arrangement in which the sample answers the question the
                // ink controls are actually asking.
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
            .opacity(presence)
            .animation(.easeOut(duration: PanelLook.presenceDuration(reaching: presence)), value: presence)
        }
        .frame(width: width, height: 150)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
    }
}

/// Settings → Look → Island, before anything waits: a menu bar with a notch,
/// with the ears or the glow as chosen, and one without, with the island as it
/// glows. «Агент ждёт / Не ждёт» is the preview's own and changes nothing else.
struct IslandPreview: View {
    var choice: NotchAttention
    var glows: Bool
    var theme: DeckTheme
    @State private var waiting = true
    @Environment(\.strings) private var strings

    private static let notch = CGSize(width: 96, height: 24)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker(strings(.lookIslandPreview), selection: $waiting) {
                Text(strings(.lookIslandPreviewWaiting)).tag(true)
                Text(strings(.lookIslandPreviewIdle)).tag(false)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .accessibilityIdentifier("look.islandPreview.waiting")
            HStack(alignment: .top, spacing: 12) {
                screen(caption: strings(.lookIslandPreviewNotch)) {
                    ZStack(alignment: .top) {
                        UnevenRoundedRectangle(bottomLeadingRadius: 9, bottomTrailingRadius: 9)
                            .fill(Color.black)
                            .frame(width: Self.notch.width, height: Self.notch.height)
                        NotchMarkDrawing(count: waiting ? 1 : 0, choice: choice,
                                         dot: waiting ? NotchMarkView.waiting : NotchMarkView.fine,
                                         ear: NotchMarks.ear, below: NotchMarks.below,
                                         identifier: "look.islandPreview.notch")
                            .frame(width: Self.notch.width + 2 * NotchMarks.ear,
                                   height: Self.notch.height + NotchMarks.below)
                    }
                }
                screen(caption: strings(.lookIslandPreviewNoNotch)) {
                    ZStack {
                        BottomRoundedRectangle(radius: 9).fill(theme.windowFill)
                        Capsule().fill(theme.text.opacity(0.55)).frame(width: 34, height: 4)
                        if waiting && glows {
                            BottomRoundedRectangle(radius: 9)
                                .stroke(NotchMarkView.waiting, lineWidth: 2)
                                .shadow(color: NotchMarkView.waiting.opacity(0.9), radius: 5)
                                .accessibilityElement()
                                .accessibilityIdentifier("look.islandPreview.glow")
                        }
                    }
                    // Hanging from the top of the screen, over the menu bar,
                    // as the island does where there is no notch.
                    .frame(width: 150, height: 22)
                }
            }
        }
        .padding(.vertical, 4)
    }

    /// A screen's top: a menu bar over a wallpaper, with what is drawn on it.
    private func screen(caption: String, @ViewBuilder island: () -> some View) -> some View {
        VStack(spacing: 4) {
            ZStack(alignment: .top) {
                LinearGradient(colors: [Color(red: 0.44, green: 0.48, blue: 0.55),
                                        Color(red: 0.30, green: 0.33, blue: 0.39)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Rectangle().fill(Color(white: 0.17)).frame(height: Self.notch.height)
                island()
            }
            .frame(width: 260, height: 78)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
            Text(caption).font(.caption).foregroundStyle(.secondary)
        }
    }
}
