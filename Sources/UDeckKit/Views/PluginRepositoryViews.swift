import SwiftUI
import UDeckCore

// Settings → Plugins, the parts about repositories: the official catalogue, and
// on every installed plugin's row, where it came from and what can be done
// about it. Every control carries an accessibility identifier — the titles are
// translated, and the lab drives these screens by identifier.

// MARK: - The official catalogue

/// The official catalogue: its switch, how fresh it is, and one row per plugin.
struct CatalogueSection: View {
    @Bindable var model: DeckModel
    @Environment(\.strings) private var strings

    var body: some View {
        SettingsBlock(strings(.pluginsOfficialCatalogue)) {
            Toggle(strings(.pluginsOfficialCatalogue), isOn: Binding(
                get: { model.settings.readsOfficialCatalogue },
                set: { model.setOfficialCatalogue($0) }
            ))
            .accessibilityIdentifier("catalogue.enabled")
            Text(strings(.pluginsOfficialCatalogueHelp(source: model.catalogueAddress.description)))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if model.settings.readsOfficialCatalogue {
                HStack(spacing: 10) {
                    Button(strings(.catalogueCheckNow)) { model.checkCatalogueNow() }
                        .disabled(model.catalogueRefreshing)
                        .accessibilityIdentifier("catalogue.checkNow")
                    if model.catalogueRefreshing {
                        ProgressView().controlSize(.small)
                        Text(strings(.catalogueReading)).font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text(freshness)
                            .font(.caption).foregroundStyle(.secondary)
                            .accessibilityIdentifier("catalogue.status")
                    }
                }
                if let trouble {
                    Label(trouble, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("catalogue.trouble")
                }
                if model.updatesWaiting > 0 {
                    Text(strings(.catalogueUpdatesWaiting(model.updatesWaiting)))
                        .font(.callout).bold()
                        .accessibilityIdentifier("catalogue.updatesWaiting")
                }
                if let catalogue = model.catalogue {
                    if catalogue.entries.isEmpty {
                        Text(strings(.catalogueEmpty)).foregroundStyle(.secondary)
                    }
                    ForEach(catalogue.entries) { entry in
                        CatalogueRowView(model: model, entry: entry, commit: catalogue.commit)
                        Divider()
                    }
                }
            } else {
                Text(strings(.catalogueOff)).font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("catalogue.status")
            }
        }
        .onAppear { model.pluginsPaneOpened() }
    }

    /// `github.com/owner/repo · checked 14:02`.
    private var freshness: String {
        let source = model.catalogueAddress.description
        guard let success = model.catalogueState.lastSuccess else { return strings(.catalogueNeverRead(source: source)) }
        return strings(.catalogueChecked(source: source, at: Clock.text(success, strings)))
    }

    /// Why the list is not fresh, when the last refresh did not finish.
    private var trouble: String? {
        guard let error = model.catalogueState.lastError else { return nil }
        let readAt = model.catalogue == nil ? nil : model.catalogueState.lastSuccess.map { Clock.text($0, strings) }
        let source = model.catalogueAddress.description
        switch error {
        case .rateLimited(let until):
            return strings(.catalogueLimited(readAt: readAt, until: Clock.text(until, strings)))
        case .rawRateLimited(let until):
            return strings(.catalogueRawLimited(until: Clock.text(until, strings)))
        case .unreachable(let reason):
            return strings(.catalogueUnreachable(reason: reason, readAt: readAt))
        case .notFound:
            return strings(.catalogueNotFound(source: source))
        case .notARepository(let branch):
            return strings(.catalogueNotARepository(source: source, branch: branch))
        case .futureFormat(let declared):
            return strings(.catalogueFutureFormat(declared: declared))
        case .invalidPassport(let reason):
            return strings(.catalogueInvalidPassport(source: source, reason: reason))
        case .refused(let status):
            return strings(.catalogueRefused(status: status))
        case .badAnswer(let reason):
            return strings(.catalogueBadAnswer(reason: reason))
        case .arrivedDifferent(let path, let expected, let got):
            return strings(.catalogueArrivedDifferent(path: path, expected: expected, got: got))
        }
    }
}

/// One plugin the catalogue offers.
///
/// Everything it shows comes from the listing and the manifest — none of it
/// cost a download — and it has one button, the one that goes with its state.
struct CatalogueRowView: View {
    @Bindable var model: DeckModel
    var entry: CatalogueEntry
    var commit: String
    @Environment(\.strings) private var strings
    @Environment(\.openURL) private var openURL
    @State private var details = false
    @State private var confirming = false
    /// The version **Update** or **Switch to** was pressed for, over a copy
    /// changed on disk: what the warning names before anything is replaced.
    @State private var updatingOverChanges: String?
    /// The same for **Reinstall** on a row whose folder was missing: something
    /// may have been put at its place since the row was drawn.
    @State private var reinstallingOverChanges: String?

    private var id: String { entry.id }
    private var manifest: PluginManifest? { entry.manifest(in: strings.language.rawValue) }
    private var state: CatalogueRowState { model.rowState(for: entry) }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(entry.name(in: strings.language.rawValue)).font(.headline)
                if let manifest {
                    Text(manifest.version).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    if let author = manifest.author { Text(author).font(.caption).foregroundStyle(.secondary) }
                }
                // The official repository's mark: a maintainer read it before
                // merging. Not "safe" — the strongest thing uDeck can honestly say.
                Label(strings(.catalogueVerified), systemImage: "checkmark.seal.fill")
                    .font(.caption).foregroundStyle(.green)
                    .accessibilityIdentifier("catalogue.\(id).verified")
                Spacer()
                action
            }
            if let description = manifest?.description {
                Text(description).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                Text(asks).font(.caption).foregroundStyle(.secondary)
                Text(strings(.catalogueSize(
                    files: entry.listing.files.count,
                    size: ByteCount.text(entry.listing.totalBytes, kilo: strings.language == .russian ? "КБ" : "KB",
                                         mega: strings.language == .russian ? "МБ" : "MB",
                                         unit: strings.language == .russian ? "Б" : "B",
                                         separator: strings.language == .russian ? "," : ".")
                ))).font(.caption).foregroundStyle(.secondary)
                if let page = model.folderPage(id, commit: commit) {
                    Button(strings(.catalogueOpenOnGitHub)) { openURL(page) }
                        .buttonStyle(.link).font(.caption)
                }
            }
            stateLine
            if confirming, case .folderOfYourOwn = state {
                confirmation(strings(.catalogueReplaceConfirm(id: id, path: model.pluginsDirectoryDisplayPath)),
                             button: strings(.catalogueReplace), identifier: "catalogue.\(id).confirm") {
                    model.install(id)
                }
            }
            if let version = updatingOverChanges {
                confirmation(strings(.catalogueUpdateOverChanges(id: id, version: version)),
                             button: strings(.catalogueUpdate), identifier: "catalogue.\(id).confirm") {
                    model.update(id)
                }
            }
            if let version = reinstallingOverChanges {
                confirmation(strings(.catalogueUpdateOverChanges(id: id, version: version)),
                             button: strings(.catalogueReinstall(version: version)),
                             identifier: "catalogue.\(id).confirm") {
                    model.reinstall(id)
                }
            }
            if let problem = model.operationProblems[id] {
                ProblemText(problem: problem).accessibilityIdentifier("catalogue.\(id).problem")
            }
            if details {
                ForEach(Array(entry.verdict.refusals.enumerated()), id: \.offset) { _, refusal in
                    Text(strings(.catalogueRefusal(refusal)))
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 3)
    }

    private var asks: String {
        let requested = manifest?.permissions.capabilities ?? []
        guard !requested.isEmpty else { return strings(.permissionsAsksNothing) }
        return strings(.catalogueAsksTo(requested.map { strings($0.summaryPhrase) }.joined(separator: ", ")))
    }

    @ViewBuilder private var action: some View {
        if model.busyPlugin == id {
            ProgressView().controlSize(.small)
            Text(strings(.catalogueWorking)).font(.caption).foregroundStyle(.secondary)
        } else {
            switch state {
            case .notInstalled:
                Button(strings(.catalogueInstall)) { model.install(id) }
                    .disabled(model.busyPlugin != nil)
                    .accessibilityIdentifier("catalogue.\(id).install")
            case .folderOfYourOwn:
                Button(strings(.catalogueReplace)) { confirming = true }
                    .disabled(model.busyPlugin != nil)
                    .accessibilityIdentifier("catalogue.\(id).replace")
            case .installed(let offer):
                switch offer {
                case .newer, .changedStill:
                    Button(strings(.catalogueUpdate)) { update(offer) }
                        .disabled(model.busyPlugin != nil)
                        .accessibilityIdentifier("catalogue.\(id).update")
                case .older(let version):
                    Button(strings(.catalogueSwitchTo(version: version))) { update(offer) }
                        .disabled(model.busyPlugin != nil)
                        .accessibilityIdentifier("catalogue.\(id).update")
                default:
                    EmptyView()
                }
            case .missing:
                Button(strings(.windowReinstall)) { reinstall() }
                    .disabled(model.busyPlugin != nil)
                    .accessibilityIdentifier("catalogue.\(id).reinstall")
            case .cannotInstall:
                Button(strings(.catalogueDetails)) { details.toggle() }
                    .buttonStyle(.link)
                    .accessibilityIdentifier("catalogue.\(id).details")
            }
        }
    }

    /// **Reinstall** of a plugin whose folder was missing: the rule is asked
    /// of the disk when the button is pressed, as every other button that
    /// replaces a folder asks it — a folder put there since the row was drawn
    /// is replaced, and goes to the Trash, only after the warning.
    private func reinstall() {
        if model.operatorsWorkGoesToTrash(id), let version = model.installed.plugins[id]?.version {
            reinstallingOverChanges = version
        } else {
            model.reinstall(id)
        }
    }

    /// **Update** or **Switch to**: at once, or — over a copy holding
    /// something of the operator's — only after saying that it goes to the
    /// Trash, as the same button on the installed plugin's row does.
    private func update(_ offer: UpdateOffer) {
        if let version = offer.versionReplacingChanges(operatorsWork: model.operatorsWorkGoesToTrash(id)) {
            updatingOverChanges = version
        } else {
            model.update(id)
        }
    }

    /// The row's state in words: installed, an update, a folder of the
    /// operator's own, or the first reason it cannot run here.
    @ViewBuilder private var stateLine: some View {
        if let text = stateText {
            Text(text)
                .font(.caption)
                .foregroundStyle(isTrouble ? .orange : .secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("catalogue.\(id).state")
        }
    }

    private var isTrouble: Bool {
        switch state {
        case .cannotInstall, .missing: true
        case .installed(.cannotRun): true
        default: false
        }
    }

    private var stateText: String? {
        switch state {
        case .notInstalled: nil
        case .cannotInstall(let refusal): strings(.catalogueRefusal(refusal))
        case .folderOfYourOwn: strings(.catalogueOwnFolder(id: id))
        case .missing: strings(.catalogueMissing(id: id, path: model.pluginsDirectoryDisplayPath))
        case .installed(let offer): OfferText.text(offer, strings)
        }
    }

    private func confirmation(_ text: String, button: String, identifier: String,
                              action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(text).font(.caption).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("catalogue.\(id).confirmText")
            HStack {
                Button(button, role: .destructive) {
                    confirming = false
                    updatingOverChanges = nil
                    reinstallingOverChanges = nil
                    action()
                }
                .accessibilityIdentifier(identifier)
                Button(strings(.actionCancel)) {
                    confirming = false
                    updatingOverChanges = nil
                    reinstallingOverChanges = nil
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.1)))
    }
}

// MARK: - An installed plugin's repository half

/// On an installed plugin's row: where it came from, its mark, what the
/// repository has for it now, and what can be done about it.
struct InstalledRepositoryControls: View {
    @Bindable var model: DeckModel
    var id: String
    /// The version on disk, as its manifest says it.
    var versionOnDisk: String?
    @Environment(\.strings) private var strings
    @Environment(\.openURL) private var openURL
    @State private var confirming: Confirmation?
    @State private var showingHistory = false

    enum Confirmation: Equatable {
        /// **Remove**; `own` when something of the operator's goes to the Trash.
        case remove(own: Bool)
        /// A button that replaces the folder, pressed over a copy holding
        /// something of the operator's: the version it is replaced with, and
        /// what the confirmation then does.
        case overChanges(version: String, then: Replacement)
    }

    enum Replacement: Equatable { case update, reinstall, backTo }

    private var record: InstalledRecord? { model.installed.plugins[id] }
    private var standing: PluginStanding { model.standing(of: id) }
    private var offer: UpdateOffer? {
        model.settings.readsOfficialCatalogue ? model.updateOffer(for: id) : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                mark
                if let record {
                    Text(strings(.pluginFrom(source: record.repository.description,
                                             commit: String(record.commit.prefix(7)))))
                        .font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("plugin.\(id).from")
                }
            }
            if record?.pinned == true {
                Text(strings(.pluginPinned)).font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("plugin.\(id).pinned")
            }
            if let offer, let text = OfferText.text(offer, strings), offer != .current {
                HStack(spacing: 8) {
                    Text(text).font(.caption).bold()
                        .accessibilityIdentifier("plugin.\(id).offer")
                    if offer.isWaiting, let page = model.whatChanged(id) {
                        Button(strings(.catalogueWhatChanged)) { openURL(page) }
                            .buttonStyle(.link).font(.caption)
                    }
                }
            }
            buttons
            if let confirming {
                confirmation(confirming)
            }
            if let problem = model.operationProblems[id] {
                ProblemText(problem: problem).accessibilityIdentifier("plugin.\(id).problem")
            }
            if showingHistory {
                HistoryList(model: model, id: id, installedCommit: record?.commit)
            }
        }
    }

    @ViewBuilder private var mark: some View {
        switch standing {
        case .verified:
            Label(strings(.pluginMarkVerified), systemImage: "checkmark.seal.fill")
                .font(.caption).foregroundStyle(.green)
                .accessibilityIdentifier("plugin.\(id).mark")
        case .modifiedLocally:
            Label(strings(.pluginMarkModified), systemImage: "pencil")
                .font(.caption).foregroundStyle(.orange)
                .accessibilityIdentifier("plugin.\(id).mark")
        case .folderOfYourOwn:
            Label(strings(.pluginMarkOwnFolder), systemImage: "folder")
                .font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("plugin.\(id).mark")
        case .missing:
            Label(strings(.pluginMarkMissing), systemImage: "questionmark.folder")
                .font(.caption).foregroundStyle(.orange)
                .accessibilityIdentifier("plugin.\(id).mark")
        }
    }

    @ViewBuilder private var buttons: some View {
        let busy = model.busyPlugin != nil
        HStack(spacing: 8) {
            if model.busyPlugin == id {
                ProgressView().controlSize(.small)
                Text(strings(.catalogueWorking)).font(.caption).foregroundStyle(.secondary)
            }
            if let offer, offer.isWaiting || isOlder(offer) {
                Button(isOlder(offer) ? strings(.catalogueSwitchTo(version: olderVersion(offer))) : strings(.catalogueUpdate)) {
                    if let version = offer.versionReplacingChanges(operatorsWork: model.operatorsWorkGoesToTrash(id)) {
                        confirming = .overChanges(version: version, then: .update)
                    } else {
                        model.update(id)
                    }
                }
                .disabled(busy)
                .accessibilityIdentifier("plugin.\(id).update")
            }
            if let record, standing.offersReinstall(readsCatalogue: model.settings.readsOfficialCatalogue) {
                Button(strings(.catalogueReinstall(version: record.version))) {
                    replace(.reinstall, version: record.version)
                }
                    .disabled(busy)
                    .accessibilityIdentifier("plugin.\(id).reinstall")
            }
            if let previous = record?.previous, model.settings.readsOfficialCatalogue {
                Button(strings(.catalogueBackTo(version: previous.version))) {
                    replace(.backTo, version: previous.version)
                }
                    .disabled(busy)
                    .accessibilityIdentifier("plugin.\(id).backTo")
            }
            if record != nil, model.settings.readsOfficialCatalogue {
                Button(strings(.catalogueEarlierVersions)) {
                    showingHistory.toggle()
                    if showingHistory { model.readEarlierVersions(id) }
                }
                .disabled(busy && !showingHistory)
                .accessibilityIdentifier("plugin.\(id).earlier")
            }
            Button(strings(.catalogueRemove), role: .destructive) {
                confirming = .remove(own: model.operatorsWorkGoesToTrash(id))
            }
                .disabled(busy)
                .accessibilityIdentifier("plugin.\(id).remove")
        }
        .font(.caption)
    }

    /// **Reinstall** or **Back to**: at once, or — when the copy it replaces
    /// holds something of the operator's — only after saying that it goes to
    /// the Trash, by the rule the installer decides the Trash by.
    private func replace(_ replacement: Replacement, version: String) {
        if model.operatorsWorkGoesToTrash(id) {
            confirming = .overChanges(version: version, then: replacement)
        } else {
            perform(replacement)
        }
    }

    private func perform(_ replacement: Replacement) {
        switch replacement {
        case .update: model.update(id)
        case .reinstall: model.reinstall(id)
        case .backTo: model.backToPrevious(id)
        }
    }

    private func isOlder(_ offer: UpdateOffer) -> Bool {
        if case .older = offer { true } else { false }
    }

    private func olderVersion(_ offer: UpdateOffer) -> String {
        if case .older(let version) = offer { version } else { "" }
    }

    private func confirmation(_ kind: Confirmation) -> some View {
        let text: String
        let button: String
        switch kind {
        case .remove(let own):
            text = own ? strings(.catalogueRemoveOwnConfirm(id: id)) : strings(.catalogueRemoveConfirm(id: id))
            button = strings(.catalogueRemove)
        case .overChanges(let version, let replacement):
            text = strings(.catalogueUpdateOverChanges(id: id, version: version))
            switch replacement {
            case .update: button = strings(.catalogueUpdate)
            case .reinstall: button = strings(.catalogueReinstall(version: version))
            case .backTo: button = strings(.catalogueBackTo(version: version))
            }
        }
        return VStack(alignment: .leading, spacing: 5) {
            Text(text).font(.caption).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("plugin.\(id).confirmText")
            HStack {
                Button(button, role: .destructive) {
                    confirming = nil
                    switch kind {
                    case .remove: model.remove(id)
                    case .overChanges(_, let replacement): perform(replacement)
                    }
                }
                .accessibilityIdentifier("plugin.\(id).confirm")
                Button(strings(.actionCancel)) { confirming = nil }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.1)))
    }
}

/// A plugin's earlier versions, one line per version, newest first.
struct HistoryList: View {
    @Bindable var model: DeckModel
    var id: String
    var installedCommit: String?
    @Environment(\.strings) private var strings
    /// The version **Install this version** was pressed for over a copy
    /// holding something of the operator's: what the warning names first.
    @State private var confirming: PluginHistory.Line?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(strings(.historyTitle(name: model.displayManifest(withID: PluginIdentifier(rawValue: id) ?? .placeholder)?.name ?? id)))
                .font(.subheadline)
            switch model.histories[id] {
            case .none, .reading?:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(strings(.historyReading)).font(.caption).foregroundStyle(.secondary)
                }
            case .failed(let problem)?:
                Text(strings(.historyFailed)).font(.caption).foregroundStyle(.orange)
                ProblemText(problem: problem)
            case .read(let history)?:
                if history.lines.isEmpty {
                    Text(strings(.historyNone)).font(.caption).foregroundStyle(.secondary)
                }
                ForEach(history.lines, id: \.commit) { line in
                    row(line)
                }
                if let line = confirming {
                    confirmation(line)
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
        // A container of its own, or the identifier lands on every line in it
        // and replaces theirs: measured in the lab on 2026-09-29, each version,
        // its date and its **Install this version** all answered to
        // `plugin.<id>.history`, and no line could be told from another
        // (.build/e2e/20260928-221216Z, plugins.earlier-version).
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("plugin.\(id).history")
    }

    private func row(_ line: PluginHistory.Line) -> some View {
        let installed = model.installed.plugins[id]?.version == line.version
        let refusal = line.refusal(udeck: model.udeck)
        return HStack(spacing: 8) {
            Text(line.version).monospacedDigit()
                .accessibilityIdentifier("plugin.\(id).history.\(line.version)")
            if let date = line.date {
                Text(date.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if installed {
                Text(strings(.historyInstalledMark)).font(.caption).foregroundStyle(.secondary)
            } else if let refusal {
                Text(strings(.catalogueRefusal(refusal))).font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Button(strings(.historyInstall)) {
                    // The same warning as **Update** and **Back to**, by the
                    // same rule: something of the operator's goes to the Trash.
                    if model.operatorsWorkGoesToTrash(id) {
                        confirming = line
                    } else {
                        model.installEarlier(id, line: line)
                    }
                }
                    .disabled(model.busyPlugin != nil)
                    .accessibilityIdentifier("plugin.\(id).history.\(line.version).install")
            }
        }
        .font(.callout)
    }

    private func confirmation(_ line: PluginHistory.Line) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(strings(.catalogueUpdateOverChanges(id: id, version: line.version)))
                .font(.caption).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("plugin.\(id).history.confirmText")
            HStack {
                Button(strings(.historyInstall), role: .destructive) {
                    confirming = nil
                    model.installEarlier(id, line: line)
                }
                .accessibilityIdentifier("plugin.\(id).history.confirm")
                Button(strings(.actionCancel)) { confirming = nil }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.1)))
    }
}

/// An installed plugin whose folder has gone: its record still says where it
/// came from, so it can be put back.
struct MissingPluginRow: View {
    @Bindable var model: DeckModel
    var id: String
    @Environment(\.strings) private var strings

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(id).font(.headline)
            Text(strings(.catalogueMissing(id: id, path: model.pluginsDirectoryDisplayPath)))
                .font(.caption).foregroundStyle(.orange)
            InstalledRepositoryControls(model: model, id: id, versionOnDisk: nil)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Pieces

/// What an update offer says, in one line.
enum OfferText {
    static func text(_ offer: UpdateOffer, _ strings: Strings) -> String? {
        switch offer {
        case .current: strings(.catalogueInstalled)
        case .newer(let version): strings(.catalogueAvailable(version: version))
        case .changedStill(let version): strings(.catalogueChangedStill(version: version))
        case .older(let version): strings(.catalogueRepositoryNowHas(version: version))
        case .goneFromRepository: strings(.catalogueGone)
        case .cannotRun(let version, let reason):
            switch reason {
            case .apiNotSpoken(_, _, let api): strings(.catalogueUpdateNeedsAPI(version: version, api: api))
            case .needsNewerUDeck(_, _, let required, _): strings(.catalogueUpdateNeedsUDeck(version: version, required: required))
            default: strings(.catalogueUpdateCannotInstall(version: version)) + " — " + strings(.catalogueRefusal(reason))
            }
        }
    }
}

/// An operation's problem, in the operator's words.
struct ProblemText: View {
    var problem: OperationProblem
    @Environment(\.strings) private var strings

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line).font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var lines: [String] {
        switch problem {
        case .refused(let refusals): refusals.map { strings(.catalogueRefusal($0)) }
        case .recordsBroken(let reason): [strings(.catalogueRecordsBroken(reason: reason))]
        case .rateLimited(let until): [strings(.catalogueLimited(readAt: nil, until: Clock.text(until, strings)))]
        case .rawRateLimited(let until): [strings(.catalogueRawLimited(until: Clock.text(until, strings)))]
        case .unreachable(let path, let reason): [strings(.catalogueFileUnreachable(path: path, reason: reason))]
        case .tookTooLong: [strings(.catalogueTookTooLong)]
        case .cannotWrite(let reason): [strings(.catalogueCannotWrite(reason: reason))]
        case .stillRunning(let id): [strings(.catalogueStillRunning(id: id))]
        case .catalogue(let error):
            switch error {
            case .unreachable(let reason): [strings(.catalogueUnreachable(reason: reason, readAt: nil))]
            case .notFound: [strings(.catalogueNotFound(source: "GitHub"))]
            case .refused(let status): [strings(.catalogueRefused(status: status))]
            case .badAnswer(let reason): [strings(.catalogueBadAnswer(reason: reason))]
            case .rateLimited(let until): [strings(.catalogueLimited(readAt: nil, until: Clock.text(until, strings)))]
            case .rawRateLimited(let until): [strings(.catalogueRawLimited(until: Clock.text(until, strings)))]
            case .arrivedDifferent(let path, let expected, let got):
                [strings(.catalogueArrivedDifferent(path: path, expected: expected, got: got))]
            default: ["\(error)"]
            }
        }
    }
}

/// A time as a row says it: `14:02` today, with the date on any other day.
enum Clock {
    static func text(_ date: Date, _ strings: Strings) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: strings.language.rawValue)
        formatter.timeZone = .current
        if Calendar.current.isDateInToday(date) {
            formatter.dateFormat = "HH:mm"
        } else {
            formatter.setLocalizedDateFormatFromTemplate("dMMM HH:mm")
        }
        return formatter.string(from: date)
    }
}

/// A headed group, the way the rest of the settings window draws one.
struct SettingsBlock<Content: View>: View {
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
