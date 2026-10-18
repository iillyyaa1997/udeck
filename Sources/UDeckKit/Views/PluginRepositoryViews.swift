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
                // Under the catalogue's own switch: off, nothing is read, so
                // nothing could update itself either.
                Toggle(strings(.catalogueUpdatesByThemselves), isOn: Binding(
                    get: { model.settings.updatesVerifiedByThemselves },
                    set: { model.setAutoUpdateVerified($0) }
                ))
                .accessibilityIdentifier("catalogue.autoUpdate")
                Text(strings(.catalogueUpdatesByThemselvesHelp))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("catalogue.autoUpdateHelp")
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
                // While the official address belongs to another repository,
                // nothing of the catalogue read before is offered: uDeck asks
                // it nothing but its number (`readsOfficialRepository`).
                if let catalogue = model.catalogue, model.readsOfficialRepository {
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

    /// Why the list is not fresh, when the last refresh did not finish — in
    /// the official catalogue's words, which name GitHub (`CatalogueTrouble`).
    private var trouble: String? {
        guard let error = model.catalogueState.lastError else { return nil }
        let readAt = model.catalogue == nil ? nil : model.catalogueState.lastSuccess.map { Clock.text($0, strings) }
        return strings(CatalogueTrouble.phrase(error, address: model.catalogueAddress.description, host: nil, readAt: readAt,
                                               until: { Clock.text($0, strings) }))
    }
}

/// One plugin a catalogue offers — the official one's, or a source of one's
/// own's (`source`, its id), whose rows are `source.<sid>.plugin.<id>.*` and
/// carry **Unverified**, never **Verified**.
///
/// Everything it shows comes from the listing and the manifest — none of it
/// cost a download — and it has one button, the one that goes with its state.
struct CatalogueRowView: View {
    @Bindable var model: DeckModel
    var entry: CatalogueEntry
    var commit: String
    var source: String = InstalledPlugins.officialSource
    @Environment(\.strings) private var strings
    @Environment(\.openURL) private var openURL
    @State private var details = false
    /// The warning up on this row — what it said, and the button it goes
    /// with. Its button is held to it: pressed when the plugin's place no
    /// longer is what it says, it says what is there now instead
    /// (`ShownPlace`).
    @State private var confirming: Confirmation?

    /// **Install** or **Replace…** over a link or a folder of the operator's,
    /// **Update** or **Switch to** over a copy holding their changes, and
    /// **Reinstall** over something put where a missing plugin's folder was.
    enum Action: Equatable { case install, update, reinstall }

    struct Confirmation: Equatable {
        var shown: ShownPlace.Place
        var then: Action
    }

    private var id: String { entry.id }
    private var manifest: PluginManifest? { entry.manifest(in: strings.language.rawValue) }
    private var state: CatalogueRowState { model.rowState(for: entry, in: source) }
    private var isOfficial: Bool { source == InstalledPlugins.officialSource }
    /// What every control of the row is called: `catalogue.<id>` in the
    /// official catalogue, `source.<sid>.plugin.<id>` in a source's.
    private var named: String { isOfficial ? "catalogue.\(id)" : "source.\(source).plugin.\(id)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(entry.name(in: strings.language.rawValue)).font(.headline)
                if let manifest {
                    Text(manifest.version).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    if let author = manifest.author { Text(author).font(.caption).foregroundStyle(.secondary) }
                }
                if isOfficial {
                    // The official repository's mark: a maintainer read it
                    // before merging. Not "safe" — the strongest thing uDeck
                    // can honestly say.
                    Label(strings(.catalogueVerified), systemImage: "checkmark.seal.fill")
                        .font(.caption).foregroundStyle(.green)
                        .accessibilityIdentifier("catalogue.\(id).verified")
                } else {
                    // A source nobody vouches for: never Verified (S4-07).
                    Label(strings(.pluginMarkUnverified), systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                        .accessibilityIdentifier("\(named).mark")
                }
                Spacer()
                action
            }
            if let description = manifest?.description {
                Text(description).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                Text(asks).font(.caption).foregroundStyle(.secondary)
                Text(size).font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("\(named).size")
                if let page = model.folderPage(id, commit: commit, source: source) {
                    // Its host's name, and the page in its value: what a person
                    // opens, on the real host whatever a test build reads from.
                    Button(strings(.catalogueOpenOn(host: address.hostName))) { openURL(page) }
                        .buttonStyle(.link).font(.caption)
                        .accessibilityIdentifier("\(named).page")
                        .accessibilityValue(page.absoluteString)
                }
            }
            stateLine
            if let confirming {
                confirmation(confirming)
            }
            if let problem = model.operationProblems[id] {
                ProblemText(problem: problem, source: model.source(source)).accessibilityIdentifier("\(named).problem")
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

    /// The repository whose catalogue this row is of.
    private var address: RepositoryAddress { model.catalogue(of: source)?.address ?? model.catalogueAddress }

    /// *4 files · 6 KB* — or, of a host whose listings give no sizes
    /// (GitLab's), *4 files* and nothing about bytes (S4-15).
    private var size: String {
        let files = entry.listing.files.count
        guard address.listsSizes else { return strings(.catalogueFiles(files: files)) }
        let russian = strings.language == .russian
        return strings(.catalogueSize(
            files: files,
            size: ByteCount.text(entry.listing.totalBytes, kilo: russian ? "КБ" : "KB", mega: russian ? "МБ" : "MB",
                                 unit: russian ? "Б" : "B", separator: russian ? "," : ".")
        ))
    }

    @ViewBuilder private var action: some View {
        if model.busyPlugin == id {
            ProgressView().controlSize(.small)
            Text(strings(.catalogueWorking)).font(.caption).foregroundStyle(.secondary)
        } else {
            switch state {
            case .notInstalled:
                // Nothing was there when the row was drawn: anything put there
                // since is warned of first, as **Replace…** warns of it.
                Button(strings(.catalogueInstall)) { press(.install) }
                    .disabled(model.busyPlugin != nil)
                    .accessibilityIdentifier("\(named).install")
            case .folderOfYourOwn:
                Button(strings(.catalogueReplace)) { press(.install) }
                    .disabled(model.busyPlugin != nil)
                    .accessibilityIdentifier("\(named).replace")
            case .installed(let offer):
                switch offer {
                case .newer, .changedStill:
                    Button(strings(.catalogueUpdate)) { press(.update) }
                        .disabled(model.busyPlugin != nil)
                        .accessibilityIdentifier("\(named).update")
                case .older(let version):
                    Button(strings(.catalogueSwitchTo(version: version))) { press(.update) }
                        .disabled(model.busyPlugin != nil)
                        .accessibilityIdentifier("\(named).update")
                default:
                    EmptyView()
                }
            case .missing:
                Button(strings(.windowReinstall)) { press(.reinstall) }
                    .disabled(model.busyPlugin != nil)
                    .accessibilityIdentifier("\(named).reinstall")
            case .unverified(let version, nil, _):
                // Code nobody verified is in this id's place: the row's copy
                // is the verified one, offered as the switch it is — or as the
                // update it is, once its pull request was merged as something
                // else, by the name the plugin's own row gives the same press
                // (`UnverifiedRow.verifiedButton`) — always after the warning
                // that names both (`ShownPlace.Switch`); its folder gone,
                // nothing is replaced and nothing warns.
                Button(strings(model.unverifiedRow(of: id)?.verifiedButton ?? .catalogueSwitchToVerified(version: version))) {
                    press(.update)
                }
                    .disabled(model.busyPlugin != nil)
                    .accessibilityIdentifier("catalogue.\(id).switchToVerified")
            case .fromElsewhere(_, _, nil, _):
                // A source's row over a copy from elsewhere — the official
                // one, another source: this source's copy in its place, after
                // the warning that names both (`ShownPlace.Switch`).
                Button(strings(.catalogueInstallFromHere)) { press(.install) }
                    .disabled(model.busyPlugin != nil)
                    .accessibilityIdentifier("\(named).installFromHere")
            case .unverified, .fromElsewhere:
                EmptyView()
            case .cannotInstall:
                Button(strings(.catalogueDetails)) { details.toggle() }
                    .buttonStyle(.link)
                    .accessibilityIdentifier("\(named).details")
            }
        }
    }

    /// A press of the row's button, or of its warning's (`shown`): what is
    /// there is asked of the disk now, by the rule the installer decides the
    /// Trash by — the work at once, or the warning first. A folder put at a
    /// missing plugin's place since the row was drawn is replaced, and goes
    /// to the Trash, only after the warning; and the warning's button acts on
    /// what the warning said or says what is there now (`ShownPlace`).
    private func press(_ action: Action, shown: ShownPlace.Place? = nil) {
        let came: ShownPlace.Press
        switch action {
        case .install: came = model.install(id, from: source, shown: shown)
        case .update: came = model.update(id, from: source, shown: shown)
        case .reinstall: came = model.reinstall(id, shown: shown)
        }
        if case .ask(let now) = came {
            confirming = Confirmation(shown: now, then: action)
        } else {
            confirming = nil
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
                .accessibilityIdentifier("\(named).state")
        }
    }

    private var isTrouble: Bool {
        switch state {
        case .cannotInstall, .missing, .unverified, .fromElsewhere: true
        case .installed(.cannotRun): true
        default: false
        }
    }

    private var stateText: String? {
        switch state {
        case .notInstalled: nil
        case .cannotInstall(let refusal): strings(.catalogueRefusal(refusal))
        case .folderOfYourOwn: model.linkedFolder(id) == nil ? strings(.catalogueOwnFolder(id: id)) : strings(.catalogueLinkedHere(id: id))
        case .missing: strings(.catalogueMissing(id: id, path: model.pluginsDirectoryDisplayPath))
        case .installed(let offer): OfferText.text(offer, strings, asksDifferently: model.updateAsksDifferently(id))
        case .unverified:
            (state.unverifiedLine(ref: model.installed.plugins[id]?.ref ?? PluginRef(kind: "", name: nil),
                                  fork: model.installed.plugins[id]?.origin.fork(official: model.catalogueAddress), id: id,
                                  path: model.pluginsDirectoryDisplayPath,
                                  lifecycle: model.unverifiedRow(of: id)?.lifecycle,
                                  source: sourceOfTheCopy) ?? []).map { strings($0) }.joined(separator: " — ")
        case .fromElsewhere(let copy, _, let refusal, let folderGone):
            ([.catalogueInstalledFromElsewhere(copy)]
                + (folderGone ? [.catalogueMissing(id: id, path: model.pluginsDirectoryDisplayPath)] : [])
                + (refusal.map { [.catalogueRefusal($0)] } ?? [])).map { strings($0) }.joined(separator: " — ")
        }
    }

    /// The address of the source of one's own the copy at this id is of,
    /// when it is one's: what the official row says it was installed from.
    private var sourceOfTheCopy: String? {
        guard let record = model.installed.plugins[id], record.source != InstalledPlugins.officialSource else { return nil }
        return record.repository.description
    }

    private func confirmation(_ confirmation: Confirmation) -> some View {
        let shown = confirmation.shown
        let version = shown.arriving ?? ""
        let button: String
        // A link there goes, and the folder it leads to stays; a folder of
        // the operator's own goes to the Trash; a copy from another line of
        // history is named beside the one that comes (`PlaceWarning.of`).
        let text = strings(PlaceWarning.of(shown, button: confirmation.then == .install ? .install : .replaceCopy, id: id,
                                           path: model.pluginsDirectoryDisplayPath,
                                           link: shown.link.map { model.displayPath($0) }))
        switch confirmation.then {
        case .install:
            if case .fromElsewhere = state {
                button = strings(.catalogueInstallFromHere)
            } else {
                button = strings(.catalogueReplace)
            }
        case .update:
            // Across two lines of history, the verified copy's button, by the
            // name the row gave it (`UnverifiedRow.verifiedButton`).
            button = shown.switching != nil
                ? strings(model.unverifiedRow(of: id)?.verifiedButton ?? .catalogueSwitchToVerified(version: version))
                : strings(.catalogueUpdate)
        case .reinstall:
            button = strings(.catalogueReinstall(version: version))
        }
        return VStack(alignment: .leading, spacing: 5) {
            Text(text).font(.caption).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("\(named).confirmText")
            HStack {
                Button(button, role: .destructive) { press(confirmation.then, shown: shown) }
                    .accessibilityIdentifier("\(named).confirm")
                Button(strings(.actionCancel)) { self.confirming = nil }
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
    /// The source whose history **Earlier versions…** was opened for: the
    /// list is shown while the copy is of that source still, and goes when
    /// another source's copy takes its place (`EarlierVersions`).
    @State private var historyOf: String?
    /// Only while the copy's source can be read, too: a list read before the
    /// official address answered another repository's number goes with it,
    /// rather than stay with an **Install this version** that does nothing.
    private var showingHistory: Bool {
        guard let historyOf, let record, historyOf == record.source else { return false }
        return model.canRead(record.source)
    }

    /// The warning up on this row: what it said, and the button it goes
    /// with. Its button is held to it (`ShownPlace`).
    struct Confirmation: Equatable {
        /// What is at the plugin's place, and the version that comes —
        /// none for **Remove**: of a link only the link goes, something of
        /// the operator's goes to the Trash.
        var shown: ShownPlace.Place
        var then: Action
    }

    /// **Remove**, or a button that replaces the folder — pressed over a copy
    /// holding something of the operator's, or over a copy from another line
    /// of history: **Switch to verified** over a branch's or a pull request's
    /// copy always names both. `alongTheLine` is **Update** of such a copy to
    /// the head its own branch or pull request moved to (`RefOffer`).
    enum Action: Equatable { case remove, update, reinstall, backTo, switchToVerified, alongTheLine }

    private var record: InstalledRecord? { model.installed.plugins[id] }
    private var standing: PluginStanding { model.standing(of: id) }
    /// What its own source's head has for it — while that source can be read.
    private var offer: UpdateOffer? {
        guard let record, model.canRead(record.source) else { return nil }
        return model.updateOffer(for: id)
    }
    /// What a copy of code nobody verified says and offers (`UnverifiedRow`).
    private var unverified: UnverifiedRow? { model.unverifiedRow(of: id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                mark
                if let record {
                    // *Unverified · pull request #3 at a1b2c3d*: where code
                    // nobody verified came from, beside its mark, and its page.
                    if !record.isOfficialDefault, model.linkedFolder(id) == nil {
                        Text("·").font(.caption).foregroundStyle(.secondary)
                    }
                    Text(strings(record.fromPhrase(official: model.catalogueAddress,
                                                   sources: model.sourcesProblem == nil ? model.sources : nil)))
                        .font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("plugin.\(id).from")
                    if let page = record.refPage {
                        Button(strings(.catalogueOpenOn(host: record.repository.hostName))) { openURL(page) }
                            .buttonStyle(.link).font(.caption)
                            .accessibilityIdentifier("plugin.\(id).refPage")
                    }
                }
            }
            if record?.pinned == true {
                Text(strings(.pluginPinned)).font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("plugin.\(id).pinned")
            }
            if let record, record.automatic == true {
                Text(strings(.pluginUpdatedByItself(date: Clock.day(record.installedAt, strings))))
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("plugin.\(id).updatedByItself")
            }
            if let offer, let text = OfferText.text(offer, strings, asksDifferently: model.updateAsksDifferently(id)),
               offer != .current {
                HStack(spacing: 8) {
                    Text(text).font(.caption).bold()
                        .accessibilityIdentifier("plugin.\(id).offer")
                    if offer.isWaiting, let page = model.whatChanged(id) {
                        Button(strings(.catalogueWhatChanged)) { openURL(page) }
                            .buttonStyle(.link).font(.caption)
                            .accessibilityIdentifier("plugin.\(id).whatChanged")
                    }
                }
            }
            // Of code nobody verified: what became of its pull request —
            // merged as something else, the verified version offered, or
            // closed without being merged, the plugin running on — its branch
            // gone, what its branch or pull request has for it now and whether
            // that head rewrote its history, and since when its line was not
            // checked (`UnverifiedRow.said`).
            if let record, let unverified {
                ForEach(unverified.said(ref: record.ref, fork: record.origin.fork(official: model.catalogueAddress), id: id,
                                        time: { Clock.text($0, strings) }), id: \.suffix) { said in
                    HStack(spacing: 8) {
                        Text(said.phrase.map { strings($0) }.joined(separator: " — ")).font(.caption)
                            .bold(said.suffix != "notChecked")
                            .foregroundStyle(Self.isWarning(said.suffix, unverified) ? AnyShapeStyle(.orange)
                                                                                   : AnyShapeStyle(.primary))
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("plugin.\(id).\(said.suffix)")
                        if let page = whatChanged(said.suffix, unverified) {
                            Button(strings(.catalogueWhatChanged)) { openURL(page) }
                                .buttonStyle(.link).font(.caption)
                                .accessibilityIdentifier("plugin.\(id).whatChanged")
                        }
                    }
                }
            }
            buttons
            if let confirming {
                confirmation(confirming)
            }
            if let version = model.autoUpdates.failures[id] {
                Text(strings(.pluginUpdateByItselfFailed(version: version)))
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("plugin.\(id).updateByItselfFailed")
            }
            if let problem = model.operationProblems[id] {
                ProblemText(problem: problem, source: record.flatMap { model.source($0.source) })
                    .accessibilityIdentifier("plugin.\(id).problem")
            }
            if showingHistory {
                HistoryList(model: model, id: id, installedCommit: record?.commit)
            }
        }
    }

    @ViewBuilder private var mark: some View {
        if let linked = model.linkedFolder(id) {
            // A linked folder (Q125): no install, nothing to verify — the mark
            // says it is a link, and where it leads.
            Label(strings(.pluginMarkLinked), systemImage: "link")
                .font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("plugin.\(id).mark")
            Text(linked.target == nil ? strings(.pluginLinkNotFollowed(destination: linked.destination))
                                      : strings(.pluginLinkedTo(path: model.displayPath(linked.leadsTo))))
                .font(.caption).foregroundStyle(.secondary)
                .textSelection(.enabled)
                .accessibilityIdentifier("plugin.\(id).linkedTo")
        } else {
            standingMark
        }
    }

    @ViewBuilder private var standingMark: some View {
        switch standing {
        case .verified:
            Label(strings(.pluginMarkVerified), systemImage: "checkmark.seal.fill")
                .font(.caption).foregroundStyle(.green)
                .accessibilityIdentifier("plugin.\(id).mark")
        case .unverified:
            Label(strings(.pluginMarkUnverified), systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.orange)
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
                    press(.update)
                }
                .disabled(busy)
                .accessibilityIdentifier("plugin.\(id).update")
            } else if let unverified, unverified.verifiedIsAnUpdate, let label = unverified.verifiedButton {
                // *The verified version differs — update*: the catalogue's
                // copy, after the warning that names both, by the name the
                // catalogue row gives the same press.
                Button(strings(label)) { press(.update) }
                    .disabled(busy)
                    .accessibilityIdentifier("plugin.\(id).update")
            } else if let label = unverified?.lineOffer?.button {
                // What its own branch or pull request has now: the head's
                // folder, pressed and never by itself; the card asks.
                Button(strings(label)) { press(.alongTheLine) }
                    .disabled(busy)
                    .accessibilityIdentifier("plugin.\(id).update")
            }
            if let record, standing.offersReinstall(readsCatalogue: model.canRead(record.source)) {
                Button(strings(.catalogueReinstall(version: record.version))) { press(.reinstall) }
                    .disabled(busy)
                    .accessibilityIdentifier("plugin.\(id).reinstall")
            }
            if let unverified, !unverified.verifiedIsAnUpdate, let label = unverified.verifiedButton {
                Button(strings(label)) { press(.switchToVerified) }
                    .disabled(busy)
                    .accessibilityIdentifier("plugin.\(id).switchToVerified")
            }
            if let previous = record?.previous, model.backToSource(id) != nil {
                Button(strings(.catalogueBackTo(version: previous.version))) { press(.backTo) }
                    .disabled(busy)
                    .accessibilityIdentifier("plugin.\(id).backTo")
            }
            if let record, model.canRead(record.source) {
                Button(strings(.catalogueEarlierVersions)) {
                    historyOf = showingHistory ? nil : record.source
                    if showingHistory { model.readEarlierVersions(id) }
                }
                .disabled(busy && !showingHistory)
                .accessibilityIdentifier("plugin.\(id).earlier")
            }
            Button(strings(.catalogueRemove), role: .destructive) { press(.remove) }
                .disabled(busy)
                .accessibilityIdentifier("plugin.\(id).remove")
        }
        .font(.caption)
    }

    /// A press of the row's button, or of its warning's (`shown`): **Remove**
    /// always warns first; **Update**, **Switch to**, **Reinstall** and
    /// **Back to** act at once, or — when the copy they replace holds
    /// something of the operator's — only after saying that it goes to the
    /// Trash, by the rule the installer decides the Trash by. A warning's
    /// button acts on what the warning said, or says what is there now.
    private func press(_ action: Action, shown: ShownPlace.Place? = nil) {
        let came: ShownPlace.Press
        switch action {
        case .remove: came = model.remove(id, shown: shown)
        case .update:
            // What its own source's head has — or, its pull request merged as
            // something else, the verified copy (`UnverifiedRow.verifiedIsAnUpdate`).
            came = model.update(id, from: offer != nil ? record?.source ?? InstalledPlugins.officialSource
                                                       : InstalledPlugins.officialSource, shown: shown)
        case .reinstall: came = model.reinstall(id, shown: shown)
        case .backTo: came = model.backToPrevious(id, shown: shown)
        case .switchToVerified: came = model.update(id, from: InstalledPlugins.officialSource, shown: shown)
        case .alongTheLine: came = model.updateAlongItsLine(id, shown: shown)
        }
        if case .ask(let now) = came {
            confirming = Confirmation(shown: now, then: action)
        } else {
            confirming = nil
        }
    }

    /// Whether a line the row says of code nobody verified is a warning: a
    /// pull request closed unmerged, a branch gone, history rewritten, a
    /// line not checked.
    private static func isWarning(_ suffix: String, _ row: UnverifiedRow) -> Bool {
        switch suffix {
        case "pullRequest": row.lifecycle == .closed
        case "branchGone", "rewritten", "notChecked": true
        default: false
        }
    }

    /// *What changed* beside a line of code nobody verified: against the
    /// verified version once its pull request was merged as something else,
    /// and along its own line beside what that line offers.
    private func whatChanged(_ suffix: String, _ row: UnverifiedRow) -> URL? {
        switch suffix {
        case "pullRequest": row.verifiedIsAnUpdate ? model.whatChanged(id) : nil
        case "offer": row.lineOffer?.offer.isWaiting == true ? model.whatChangedAlongItsLine(id) : nil
        default: nil
        }
    }

    private func isOlder(_ offer: UpdateOffer) -> Bool {
        if case .older = offer { true } else { false }
    }

    private func olderVersion(_ offer: UpdateOffer) -> String {
        if case .older(let version) = offer { version } else { "" }
    }

    private func confirmation(_ confirmation: Confirmation) -> some View {
        let shown = confirmation.shown
        let version = shown.arriving ?? ""
        // Over the operator's changes, the Trash; over a link — one put there
        // while this row was up, too — only the link goes; across two lines
        // of history, both named (`PlaceWarning.of`).
        let text = strings(PlaceWarning.of(shown, button: confirmation.then == .remove ? .remove : .replaceCopy, id: id,
                                           path: model.pluginsDirectoryDisplayPath,
                                           link: shown.link.map { model.displayPath($0) }))
        let button: String
        switch confirmation.then {
        case .remove: button = strings(.catalogueRemove)
        case .update: button = strings(.catalogueUpdate)
        case .reinstall: button = strings(.catalogueReinstall(version: version))
        case .backTo: button = strings(.catalogueBackTo(version: version))
        case .switchToVerified: button = strings(.catalogueSwitchToVerified(version: version))
        case .alongTheLine: button = strings(unverified?.lineOffer?.button ?? .catalogueUpdate)
        }
        return VStack(alignment: .leading, spacing: 5) {
            Text(text).font(.caption).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("plugin.\(id).confirmText")
            HStack {
                Button(button, role: .destructive) { press(confirmation.then, shown: shown) }
                    .accessibilityIdentifier("plugin.\(id).confirm")
                Button(strings(.actionCancel)) { self.confirming = nil }
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
    /// holding something of the operator's, and what the warning said of it:
    /// its button is held to that (`ShownPlace`).
    @State private var confirming: (line: PluginHistory.Line, shown: ShownPlace.Place)?

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
                if let confirming {
                    confirmation(confirming.line, shown: confirming.shown)
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
                    install(line)
                }
                    .disabled(model.busyPlugin != nil)
                    .accessibilityIdentifier("plugin.\(id).history.\(line.version).install")
            }
        }
        .font(.callout)
    }

    private func install(_ line: PluginHistory.Line, shown: ShownPlace.Place? = nil) {
        if case .ask(let now) = model.installEarlier(id, line: line, shown: shown) {
            confirming = (line, now)
        } else {
            confirming = nil
        }
    }

    private func confirmation(_ line: PluginHistory.Line, shown: ShownPlace.Place) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(strings(PlaceWarning.of(shown, button: .replaceCopy, id: id, path: model.pluginsDirectoryDisplayPath,
                                         link: shown.link.map { model.displayPath($0) })))
                .font(.caption).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("plugin.\(id).history.confirmText")
            HStack {
                Button(strings(.historyInstall), role: .destructive) { install(line, shown: shown) }
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

// MARK: - Install from a link…

/// **Install from a link…** (stage 3), on **Link a folder…**'s row: it opens
/// the link sheet under them, or closes it. Greyed out with **Official
/// catalogue** off: uDeck makes no request to the official repository or its
/// forks then, and the sheet says why (`LinkInstallSheet`).
struct LinkInstallButton: View {
    @Bindable var model: DeckModel
    @Binding var open: Bool
    @Environment(\.strings) private var strings

    var body: some View {
        Button(strings(.linkInstall)) {
            open.toggle()
            if !open { model.closeLinkLookup() }
        }
        .disabled(!model.settings.readsOfficialCatalogue)
        .accessibilityIdentifier("plugins.installFromLink")
    }
}

/// The link sheet: a link to a pull request or a branch of the official
/// repository pasted, read and asked of GitHub, and then the plugins there
/// that are not what the catalogue has, new or changed, each with **Install**
/// and the **Unverified** mark. A sheet in the pane rather than a window of
/// its own: it says where the copy will come from right where the operator
/// installs it. With **Official catalogue** off, only why the button does
/// nothing.
struct LinkInstallSheet: View {
    @Bindable var model: DeckModel
    @Binding var open: Bool
    @Environment(\.strings) private var strings
    @Environment(\.openURL) private var openURL
    @State private var text = ""

    var body: some View {
        Group {
            if !model.settings.readsOfficialCatalogue {
                Text(strings(.linkOff))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("link.off")
            } else if open {
                sheet
            }
        }
        // Settings closed, or another section chosen: what the sheet said
        // goes with it, and an answer still on its way is not shown.
        .onDisappear { close() }
    }

    private func close() {
        open = false
        text = ""
        model.closeLinkLookup()
    }

    private var sheet: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(strings(.linkHelp(official: model.catalogueAddress.description)))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                TextField(strings(.linkField), text: $text)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 460)
                    .onSubmit { model.lookUpLink(text) }
                    .accessibilityIdentifier("link.field")
                Button(strings(.linkLookUp)) { model.lookUpLink(text) }
                    .disabled(model.linkLookup == .reading)
                    .accessibilityIdentifier("link.lookUp")
                Button(strings(.linkClose)) { close() }
                    .accessibilityIdentifier("link.close")
            }
            lookup
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
    }

    @ViewBuilder private var lookup: some View {
        switch model.linkLookup {
        case nil:
            EmptyView()
        case .reading?:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(strings(.linkReading)).font(.caption).foregroundStyle(.secondary)
            }
        case .refused(let phrase)?:
            Text(strings(phrase))
                .font(.caption).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("link.refused")
            if let page = Self.addAsASource(phrase) {
                // Nothing is added until Add is pressed in its sheet.
                Button(strings(.linkAddAsASource)) {
                    model.openAddSource(prefilled: page)
                }
                .accessibilityIdentifier("link.addAsASource")
            }
        case .failed(let problem)?:
            ProblemText(problem: problem).accessibilityIdentifier("link.refused")
        case .catalogue(let plugin)?:
            Text(strings(.linkIsTheCatalogue(official: model.catalogueAddress.description, plugin: plugin)))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("link.catalogue")
        case .resolved(let resolution)?:
            resolved(resolution)
        }
    }

    /// The page **Add as a source…** fills **Add a source…** with, after a
    /// refusal that offers it: a repository that is no fork of the official
    /// one, and a GitLab project's link (S4-20, item 16).
    static func addAsASource(_ phrase: Phrase) -> String? {
        switch phrase {
        case .linkNotAForkAddAsASource(let repository, _): "https://\(repository)"
        case .linkNotGitHubAddAsASource(_, let page): page
        default: nil
        }
    }

    @ViewBuilder private func resolved(_ resolution: RefResolver.Resolution) -> some View {
        let said = LinkRefusal.head(of: resolution)
        HStack(spacing: 8) {
            Label(strings(.pluginMarkUnverified), systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.orange)
                .accessibilityIdentifier("link.mark")
            if let head = said.first {
                Text(strings(head)).font(.caption).bold()
                    .accessibilityIdentifier("link.head")
            }
            if let page = resolution.origin.repository.page(of: resolution.origin.ref) {
                Button(strings(.catalogueOpenOn(host: resolution.origin.repository.hostName))) { openURL(page) }
                    .buttonStyle(.link).font(.caption)
                    .accessibilityIdentifier("link.page")
            }
        }
        // The pull request's own title: its author's words, as they wrote them.
        if let title = resolution.pullRequest?.title, !title.isEmpty {
            Text(title).font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("link.title")
        }
        ForEach(Array(said.dropFirst().enumerated()), id: \.offset) { index, phrase in
            Text(strings(phrase))
                .font(.caption).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("link.said.\(index)")
        }
        if !resolution.entries.isEmpty {
            Text(strings(.linkUnverifiedNote))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("link.note")
        }
        ForEach(resolution.entries) { entry in
            LinkRowView(model: model, entry: entry, resolution: resolution)
            Divider()
        }
    }
}

/// One plugin a link listed: a catalogue row's facts — none of them cost a
/// download — the **Unverified** mark, and **Install**, which takes the
/// folder at the commit the link was read at. Over a copy from another line
/// of history the warning names both first (`ShownPlace.installFromLink`).
struct LinkRowView: View {
    @Bindable var model: DeckModel
    var entry: CatalogueEntry
    var resolution: RefResolver.Resolution
    @Environment(\.strings) private var strings
    /// The warning up on this row: its button is held to it (`ShownPlace`).
    @State private var confirming: ShownPlace.Place?

    private var id: String { entry.id }
    private var manifest: PluginManifest? { entry.manifest(in: strings.language.rawValue) }

    /// Whether the copy installed at this id is this one: this line of
    /// history, at this commit.
    private var installedHere: Bool {
        guard let record = model.installed.plugins[id] else { return false }
        return record.origin == resolution.origin && record.commit == resolution.commit
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(entry.name(in: strings.language.rawValue)).font(.headline)
                if let manifest {
                    Text(manifest.version).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    if let author = manifest.author { Text(author).font(.caption).foregroundStyle(.secondary) }
                }
                Label(strings(.pluginMarkUnverified), systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
                    .accessibilityIdentifier("link.\(id).unverified")
                Spacer()
                action
            }
            if let description = manifest?.description {
                Text(description).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            Text(asks).font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("link.\(id).asks")
            if let refusal = entry.verdict.refusals.first {
                Text(strings(.catalogueRefusal(refusal)))
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("link.\(id).state")
            } else if installedHere {
                Text(strings(.catalogueInstalled)).font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("link.\(id).state")
            }
            if let confirming {
                confirmation(confirming)
            }
            if let problem = model.operationProblems[id] {
                ProblemText(problem: problem).accessibilityIdentifier("link.\(id).problem")
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
        } else if entry.verdict.refusals.isEmpty, entry.manifest != nil, !installedHere {
            Button(strings(.catalogueInstall)) { press() }
                .disabled(model.busyPlugin != nil)
                .accessibilityIdentifier("link.\(id).install")
        }
    }

    private func press(shown: ShownPlace.Place? = nil) {
        if case .ask(let now) = model.installFromLink(id, shown: shown) {
            confirming = now
        } else {
            confirming = nil
        }
    }

    private func confirmation(_ shown: ShownPlace.Place) -> some View {
        // Over a copy uDeck installed, what a replacing button says of it; over
        // something of the operator's own, what Replace… says (`PlaceWarning.of`).
        let replacing = model.installed.plugins[id] != nil
        return VStack(alignment: .leading, spacing: 5) {
            Text(strings(PlaceWarning.of(shown, button: replacing ? .replaceCopy : .install, id: id,
                                         path: model.pluginsDirectoryDisplayPath,
                                         link: shown.link.map { model.displayPath($0) })))
                .font(.caption).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("link.\(id).confirmText")
            HStack {
                Button(strings(.catalogueInstall), role: .destructive) { press(shown: shown) }
                    .accessibilityIdentifier("link.\(id).confirm")
                Button(strings(.actionCancel)) { confirming = nil }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.1)))
    }
}

// MARK: - Pieces

/// What an update offer says, in one line — and, when the update asks for
/// other permissions than the copy on disk (`asksDifferently`), that it does:
/// why it waits for a press, and that the card will ask.
enum OfferText {
    static func text(_ offer: UpdateOffer, _ strings: Strings, asksDifferently: Bool = false) -> String? {
        let asks = asksDifferently ? ", " + strings(.catalogueAsksDifferently) : ""
        return switch offer {
        case .current: strings(.catalogueInstalled)
        case .newer(let version): strings(.catalogueAvailable(version: version)) + asks
        case .changedStill(let version): strings(.catalogueChangedStill(version: version)) + asks
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

/// An operation's problem, in the operator's words — of a copy of a source of
/// one's own (`source`), naming that source's host and address.
struct ProblemText: View {
    var problem: OperationProblem
    var source: OwnSource? = nil
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
        case .rateLimited(let until) where source?.provider == SourceLink.gitlab:
            // A GitLab's limit is the GitLab's own (S4-20, item 9), not GitHub's sixty an hour.
            [strings(CatalogueTrouble.phrase(.rateLimited(until: until), address: source?.address.description ?? "",
                                             host: source?.host, readAt: nil, until: { Clock.text($0, strings) },
                                             provider: SourceLink.gitlab))]
        case .rateLimited(let until): [strings(.catalogueLimited(readAt: nil, until: Clock.text(until, strings)))]
        case .rawRateLimited(let until): [strings(.catalogueRawLimited(until: Clock.text(until, strings)))]
        case .unreachable(let path, let reason): [strings(.catalogueFileUnreachable(path: path, reason: reason))]
        case .tookTooLong: [strings(.catalogueTookTooLong)]
        case .cannotWrite(let reason): [strings(.catalogueCannotWrite(reason: reason))]
        case .stillRunning(let id): [strings(.catalogueStillRunning(id: id))]
        case .commitGone(let commit): [strings(.catalogueCommitGone(commit: commit))]
        case .catalogue(let error) where source != nil:
            [strings(CatalogueTrouble.phrase(error, address: source?.address.description ?? "", host: source?.host,
                                             readAt: nil, until: { Clock.text($0, strings) },
                                             provider: source?.provider ?? SourceLink.github))]
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
            case .officialRepositoryChanged: [strings(.catalogueOfficialRepositoryChanged)]
            default: ["\(error)"]
            }
        }
    }
}

/// A time as a row says it: `14:02` today, with the date on any other day.
enum Clock {
    /// A day as a sentence says it, in uDeck's language: *October 10, 2026*,
    /// *10 октября 2026 г.*
    static func day(_ date: Date, _ strings: Strings) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: strings.language.rawValue)
        formatter.timeZone = .current
        formatter.setLocalizedDateFormatFromTemplate("dMMMMyyyy")
        return formatter.string(from: date)
    }

    /// The same, to the second: when a run started.
    static func withSeconds(_ date: Date, _ strings: Strings) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: strings.language.rawValue)
        formatter.timeZone = .current
        if Calendar.current.isDateInToday(date) {
            formatter.dateFormat = "HH:mm:ss"
        } else {
            formatter.setLocalizedDateFormatFromTemplate("dMMM HH:mm:ss")
        }
        return formatter.string(from: date)
    }

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
