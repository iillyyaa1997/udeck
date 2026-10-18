import SwiftUI
import UDeckCore

// Settings → Plugins → **Your sources** (stage 4): the repositories the
// operator added, each a catalogue of its own, after the official one. Every
// control carries an accessibility identifier (S4-06) — `sources.*` for the
// group and its sheet, `source.<sid>.*` for a source's block and
// `source.<sid>.plugin.<id>.*` for its rows — because the titles are
// translated and the lab drives these screens by identifier.

/// **Your sources**: **Add a source…** and its sheet, the line a test build
/// carries, what is wrong with `sources.json`, and one block per source.
struct SourcesSection: View {
    @Bindable var model: DeckModel
    @Environment(\.strings) private var strings

    var body: some View {
        SettingsBlock(strings(.sourcesTitle)) {
            Button(strings(.sourcesAdd)) { model.toggleAddSource() }
                .accessibilityIdentifier("sources.add")
            if model.sourceSheetOpen {
                AddSourceSheet(model: model)
            }
            if !model.testBuild.isEmpty {
                Text(model.testBuild.map { strings($0) }.joined(separator: "\n"))
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("sources.testBuild")
            }
            if !model.sourcesProblemLines.isEmpty {
                Text(model.sourcesProblemLines.map { strings($0) }.joined(separator: "\n"))
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("sources.problem")
            }
            ForEach(model.sources, id: \.id) { source in
                SourceBlock(model: model, source: source)
                Divider()
            }
        }
    }
}

/// **Add a source…**'s sheet, in the pane, as **Install from a link…**'s is:
/// one field, **Look up**, and what it came to — the passport's name and
/// description and the address, with **Add**; or why nothing is offered.
/// Nothing is added until **Add** is pressed.
struct AddSourceSheet: View {
    @Bindable var model: DeckModel
    @Environment(\.strings) private var strings

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField(strings(.sourcesAddField), text: $model.sourceField)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 460)
                    .onSubmit { model.lookUpSource() }
                    .accessibilityIdentifier("sources.add.field")
                Button(strings(.linkLookUp)) { model.lookUpSource() }
                    .disabled(isReading)
                    .accessibilityIdentifier("sources.add.lookUp")
                Button(strings(.linkClose)) { model.closeAddSource() }
                    .accessibilityIdentifier("sources.add.close")
            }
            result
            if let problem = model.sourceOperationProblems[""] {
                Text(problem).font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("sources.add.problem")
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
        // Settings closed, or another section chosen: what the sheet said goes.
        .onDisappear { model.closeAddSource() }
    }

    private var isReading: Bool {
        if case .reading? = model.sourceAdding { true } else { false }
    }

    @ViewBuilder private var result: some View {
        switch model.sourceAdding {
        case nil:
            EmptyView()
        case .reading(let host)?:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(strings(.sourcesAsking(host: host))).font(.caption).foregroundStyle(.secondary)
            }
        case .came(let outcome)?:
            came(outcome)
        }
    }

    @ViewBuilder private func came(_ outcome: SourceLookUp.Outcome) -> some View {
        switch outcome {
        case .found(let found):
            let name = SourceName.shown(found.passport.name, address: found.address, officialName: model.catalogue?.passport.name)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(name).font(.headline)
                    .accessibilityIdentifier("sources.add.result")
                Text(found.address.description).font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("sources.add.address")
                Spacer()
                Button(strings(.sourcesAddConfirm)) { model.addSource() }
                    .accessibilityIdentifier("sources.add.confirm")
            }
            if let description = found.passport.description, !description.isEmpty {
                // Somebody else's words, as they wrote them.
                Text(description).font(.callout).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("sources.add.description")
            }
        case .alreadyAdded(let source):
            said(.sourceAlreadyAdded(name: model.sourceName(source), address: source.address.description))
        case .notAPluginRepository(let address, let branch):
            said(.catalogueNotARepository(source: address, branch: branch))
        case .refused(let phrase):
            said(phrase)
        case .failed(let error, let host, let address, let provider):
            said(CatalogueTrouble.phrase(error, address: address, host: host, readAt: nil,
                                         until: { Clock.text($0, strings) }, provider: provider))
        }
    }

    private func said(_ phrase: Phrase) -> some View {
        Text(strings(phrase))
            .font(.caption).foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("sources.add.result")
    }
}

/// One source the operator added: its name and address, that nobody vouches
/// for it (S4-07), when it was read or why it was not, **Check now** and
/// **Remove…**, and its catalogue's rows.
struct SourceBlock: View {
    @Bindable var model: DeckModel
    var source: OwnSource
    @Environment(\.strings) private var strings
    @State private var removing = false

    private var sid: String { source.id }
    private var state: CatalogueState { model.catalogueState(of: sid) }
    private var catalogue: Catalogue? { model.sourceCatalogues[sid] }
    private var reading: Bool { model.sourcesRefreshing.contains(sid) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(model.sourceName(source)).font(.headline)
                    .accessibilityIdentifier("source.\(sid).name")
                Text(source.address.description).font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("source.\(sid).address")
            }
            Label(strings(.sourceNotTrusted), systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("source.\(sid).mark")
            HStack(spacing: 10) {
                Button(strings(.catalogueCheckNow)) { model.checkSourceNow(sid) }
                    .disabled(reading)
                    .accessibilityIdentifier("source.\(sid).checkNow")
                Button(strings(.sourceRemove), role: .destructive) { removing = true }
                    .disabled(reading || model.busyPlugin != nil)
                    .accessibilityIdentifier("source.\(sid).remove")
                if reading {
                    ProgressView().controlSize(.small)
                    Text(strings(.catalogueReading)).font(.caption).foregroundStyle(.secondary)
                }
            }
            statusLine
            if removing {
                confirmation
            }
            if let problem = model.sourceOperationProblems[sid] {
                Text(problem).font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("source.\(sid).problem")
            }
            if let catalogue {
                if catalogue.entries.isEmpty {
                    Text(strings(.catalogueEmpty)).foregroundStyle(.secondary)
                        .accessibilityIdentifier("source.\(sid).empty")
                }
                ForEach(catalogue.entries) { entry in
                    CatalogueRowView(model: model, entry: entry, commit: catalogue.commit, source: sid)
                    Divider()
                }
            }
        }
        .padding(.vertical, 4)
    }

    /// When it was read, or why its last read did not finish (S4-20), naming
    /// its host and its address.
    @ViewBuilder private var statusLine: some View {
        let address = source.address.description
        let readAt = catalogue == nil ? nil : state.lastSuccess.map { Clock.text($0, strings) }
        if let error = state.lastError {
            Label(strings(CatalogueTrouble.phrase(error, address: address, host: source.host, readAt: readAt,
                                                  until: { Clock.text($0, strings) }, provider: source.provider)),
                  systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("source.\(sid).state")
        } else if let success = state.lastSuccess {
            Text(strings(.catalogueChecked(source: address, at: Clock.text(success, strings))))
                .font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("source.\(sid).state")
        } else {
            Text(strings(.catalogueNeverRead(source: address)))
                .font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("source.\(sid).state")
        }
    }

    private var confirmation: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(strings(.sourceRemoveConfirm(name: model.sourceName(source), address: source.address.description)))
                .font(.caption).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("source.\(sid).confirmText")
            HStack {
                Button(strings(.catalogueRemove), role: .destructive) {
                    removing = false
                    model.removeSource(sid)
                }
                // Not while it is read: the removal would not be made
                // (`removeSource`), and the warning would close on nothing.
                .disabled(reading || model.busyPlugin != nil)
                .accessibilityIdentifier("source.\(sid).confirm")
                Button(strings(.actionCancel)) { removing = false }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.1)))
    }
}
