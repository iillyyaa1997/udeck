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
            if let draft = model.addSourceDraft {
                // Where Sign in is offered, it comes before the token (S4-23).
                SignInStep(model: model, key: "", link: draft.link, identifier: "sources.add",
                           applicationID: Binding(get: { model.addSourceDraft?.applicationID ?? "" },
                                                  set: { model.addSourceDraft?.applicationID = $0 }))
                TokenStep(link: draft.link, token: Binding(get: { model.addSourceDraft?.token ?? "" },
                                                           set: { model.addSourceDraft?.token = $0 }),
                          identifier: "sources.add",
                          signIn: model.signInClientID(provider: draft.link.provider, host: draft.link.host,
                                                       pasted: nil) != nil) { model.lookUpSource(withToken: true) }
            }
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
                                         until: { Clock.text($0, strings) }, provider: provider,
                                         tokened: model.sourceAddingTokened))
        }
    }

    private func said(_ phrase: Phrase) -> some View {
        Text(strings(phrase))
            .font(.caption).foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("sources.add.result")
    }
}

/// One source the operator added: its name and address, whether it is
/// trusted (S4-07), when it was read or why it was not, **Check now**,
/// **Trust…** or **Stop trusting…** (S4-08) and **Remove…**, and its
/// catalogue's rows.
struct SourceBlock: View {
    @Bindable var model: DeckModel
    var source: OwnSource
    @Environment(\.strings) private var strings
    @State private var removing = false
    /// The confirmation up under **Trust…** or **Stop trusting…**: whether it
    /// trusts, or stops trusting.
    @State private var trusting: Bool?

    private var sid: String { source.id }
    private var state: CatalogueState { model.catalogueState(of: sid) }
    private var catalogue: Catalogue? { model.sourceCatalogues[sid] }
    private var reading: Bool { model.sourcesRefreshing.contains(sid) }
    private var trusted: Bool { model.trustedSources.contains(sid) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(model.sourceName(source)).font(.headline)
                    .accessibilityIdentifier("source.\(sid).name")
                Text(source.address.description).font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("source.\(sid).address")
            }
            if trusted {
                // Whose guarantee it is, by a mark of its own and never
                // Verified's green (S4-07).
                Label(strings(.pluginMarkTrusted(name: model.sourceName(source))), systemImage: "checkmark.shield")
                    .font(.caption).foregroundStyle(.teal)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("source.\(sid).mark")
            } else {
                Label(strings(.sourceNotTrusted), systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("source.\(sid).mark")
            }
            HStack(spacing: 10) {
                Button(strings(.catalogueCheckNow)) { model.checkSourceNow(sid) }
                    .disabled(reading)
                    .accessibilityIdentifier("source.\(sid).checkNow")
                Button(strings(.sourceToken)) { model.toggleToken(sid) }
                    .disabled(reading)
                    .accessibilityIdentifier("source.\(sid).token")
                Button(strings(trusted ? .sourceStopTrusting : .sourceTrust)) {
                    removing = false
                    trusting = !trusted
                }
                .accessibilityIdentifier("source.\(sid).trust")
                Button(strings(.sourceRemove), role: .destructive) {
                    trusting = nil
                    removing = true
                }
                    .disabled(reading || model.busyPlugin != nil || model.sourcesForgetting.contains(sid))
                    .accessibilityIdentifier("source.\(sid).remove")
                if reading {
                    ProgressView().controlSize(.small)
                    Text(strings(.catalogueReading)).font(.caption).foregroundStyle(.secondary)
                }
            }
            statusLine
            if model.sourceTokenOpen == sid {
                let link = SourceLink(provider: source.provider, host: source.host, path: source.path)
                SignInStep(model: model, key: sid, link: link, identifier: "source.\(sid)",
                           applicationID: $model.sourceApplicationDraft)
                TokenStep(link: link, token: $model.sourceTokenDraft, identifier: "source.\(sid).token",
                          signIn: model.signInClientID(provider: source.provider, host: source.host,
                                                       pasted: nil) != nil) { model.keepToken(for: sid) }
                if source.access != OwnSource.Access.none {
                    Button(strings(source.access == OwnSource.Access.signIn ? .sourceSignOut : .sourceForgetToken)) {
                        model.forgetToken(of: sid)
                    }
                    .accessibilityIdentifier("source.\(sid).token.forget")
                }
            }
            if let notices = model.sourceNotices[sid], !notices.isEmpty {
                Text(notices.map { strings($0) }.joined(separator: "\n"))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("source.\(sid).notice")
            }
            if let trusting {
                trustConfirmation(trusting)
            }
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
        // A token from Sign in refused: signed out, said as such (S4-23) —
        // GitHub's do not expire, and are never renewed.
        if let error = state.lastError.map({ error -> CatalogueError in
            error == .unauthorized && source.access == OwnSource.Access.signIn ? .signedOut : error
        }) {
            Label(strings(CatalogueTrouble.phrase(error, address: address, host: source.host, readAt: readAt,
                                                  until: { Clock.text($0, strings) }, provider: source.provider,
                                                  tokened: source.access != OwnSource.Access.none)),
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

    /// **Trust…** — what trusting it means, said in full, and **Trust** — or
    /// **Stop trusting…** and **Stop trusting** (S4-08). The confirmation
    /// names the source by the name and the address it has as it is pressed;
    /// the press does what it says, whatever happened to the trust meanwhile.
    private func trustConfirmation(_ trust: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(strings(trust ? .sourceTrustConfirm(name: model.sourceName(source), address: source.address.description)
                               : .sourceStopTrustingConfirm(name: model.sourceName(source))))
                .font(.caption).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("source.\(sid).trustText")
            HStack {
                Button(strings(trust ? .sourceTrustConfirmButton : .sourceStopTrustingConfirmButton)) {
                    trusting = nil
                    if trust { model.trustSource(sid) } else { model.stopTrustingSource(sid) }
                }
                .accessibilityIdentifier("source.\(sid).trustConfirm")
                Button(strings(.actionCancel)) { trusting = nil }
                    .accessibilityIdentifier("source.\(sid).trustCancel")
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.teal.opacity(0.1)))
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
                .disabled(reading || model.busyPlugin != nil || model.sourcesForgetting.contains(sid))
                .accessibilityIdentifier("source.\(sid).confirm")
                Button(strings(.actionCancel)) { removing = false }
                    .accessibilityIdentifier("source.\(sid).cancelRemove")
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.1)))
    }
}

/// The token step (S4-17), under **Add a source…** and a source's **Token…**:
/// **Make a token on <host>**, opening the page with its fields filled in —
/// its address the link's accessibility value, which the lab reads — what
/// that page cannot do for the person, the token's field, and **Look up with
/// the token**. The token is held in the model's memory alone, in the draft
/// of the one step it was pasted under.
struct TokenStep: View {
    let link: SourceLink
    @Binding var token: String
    let identifier: String
    /// Whether **Sign in with GitHub** is offered above: the collaborator's
    /// line then says so (S4-20, item 22).
    var signIn = false
    let lookUp: () -> Void
    @Environment(\.strings) private var strings
    /// The token's field takes the focus when the step appears: what is
    /// pasted next goes there, never into the address field above it.
    @FocusState private var fieldFocused: Bool

    private var page: URL {
        if link.provider == SourceLink.gitlab { return TokenLinks.gitlab(host: link.host, project: link.path) }
        let parts = link.path.split(separator: "/", maxSplits: 1).map(String.init)
        return TokenLinks.github(owner: parts.first ?? "", repository: parts.count > 1 ? parts[1] : "")
    }

    private var help: [Phrase] {
        guard link.provider == SourceLink.github else { return [.sourceTokenGitLabScopeHelp] }
        let parts = link.path.split(separator: "/", maxSplits: 1).map(String.init)
        let owner = parts.first ?? "", repository = parts.count > 1 ? parts[1] : ""
        return [.sourceTokenChooseRepository(owner: owner, repository: repository),
                .sourceTokenCollaborator(owner: owner, repository: repository, signIn: signIn)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Link(strings(.sourceMakeToken(host: link.host)), destination: page)
                .font(.caption)
                .accessibilityIdentifier("\(identifier).makeToken")
                .accessibilityValue(page.absoluteString)
            Text(help.map { strings($0) }.joined(separator: "\n"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("\(identifier).tokenHelp")
            HStack(spacing: 8) {
                SecureField(strings(.sourceTokenField), text: $token)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 360)
                    .focused($fieldFocused)
                    .onAppear { fieldFocused = true }
                    .onSubmit(lookUp)
                    .accessibilityIdentifier("\(identifier).tokenField")
                Button(strings(.sourceLookUpWithToken), action: lookUp)
                    .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("\(identifier).lookUpWithToken")
            }
        }
    }
}

/// **Sign in** (S4-23), above the token step under **Add a source…** and a
/// source's **Token…**: for a GitLab of one's own, the field its application's
/// id is pasted in and what that is; **Sign in with GitHub** or **with
/// GitLab** — only where this build, or the pasted id, has an application for
/// the host; no button at all otherwise — then the code, large, and **Copy
/// the code and open…**, which opens the page only when pressed; and what it
/// came to. The lab reads the code as `<identifier>.signIn.code`.
struct SignInStep: View {
    @Bindable var model: DeckModel
    /// The source's id, or `""` for the Add sheet.
    let key: String
    let link: SourceLink
    let identifier: String
    @Binding var applicationID: String
    @Environment(\.strings) private var strings

    private var asksForAnID: Bool { model.asksForAnApplicationID(provider: link.provider, host: link.host) }
    private var offered: Bool {
        let pasted = asksForAnID ? (applicationID.isEmpty ? nil : applicationID) : nil
        return model.signInClientID(provider: link.provider, host: link.host,
                                    pasted: pasted ?? (key.isEmpty ? nil : model.source(key)?.signInClientID)) != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if asksForAnID {
                TextField(strings(.sourceSignInApplicationField(host: link.host)), text: $applicationID)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 460)
                    .accessibilityIdentifier("\(identifier).signIn.application")
                Text(strings(.sourceSignInApplicationHelp(host: link.host)))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("\(identifier).signIn.applicationHelp")
            }
            if offered {
                Button(strings(.sourceSignIn(provider: link.provider))) { model.signIn(key) }
                    .disabled(model.signIns[key]?.isUnderWay == true)
                    .accessibilityIdentifier("\(identifier).signIn")
            }
            state
        }
    }

    @ViewBuilder private var state: some View {
        switch model.signIns[key] {
        case nil:
            EmptyView()
        case .asking(let host)?, .checking(let host)?:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(strings(.sourcesAsking(host: host))).font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("\(identifier).signIn.state")
            }
        case .code(let userCode, let page, let shown, let host)?:
            Text(userCode)
                .font(.system(size: 28, weight: .semibold, design: .monospaced))
                .textSelection(.enabled)
                .accessibilityIdentifier("\(identifier).signIn.code")
                .accessibilityValue(userCode)
            Text(strings(.sourceSignInEnterCode(host: host)))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("\(identifier).signIn.state")
            HStack(spacing: 8) {
                Button(strings(.sourceSignInCopyAndOpen(page: shown))) { model.copyCodeAndOpen(key) }
                    .accessibilityIdentifier("\(identifier).signIn.copyAndOpen")
                    .accessibilityValue(page.absoluteString)
                Button(strings(.actionCancel)) { model.cancelSignIn(key) }
                    .accessibilityIdentifier("\(identifier).signIn.cancel")
            }
        case .notInstalled(let phrase, let install)?:
            Text(strings(phrase))
                .font(.caption).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("\(identifier).signIn.state")
            HStack(spacing: 8) {
                if let install, case .sourceSignInAppNotInstalled(let owner, _) = phrase {
                    Link(strings(.sourceSignInInstallApp(owner: owner)), destination: install)
                        .accessibilityIdentifier("\(identifier).signIn.install")
                        .accessibilityValue(install.absoluteString)
                }
                Button(strings(.sourceSignInLookUpAgain)) { model.lookUpAgain(key) }
                    .accessibilityIdentifier("\(identifier).signIn.lookUpAgain")
            }
        case .failed(let phrase)?:
            Text(strings(phrase))
                .font(.caption).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("\(identifier).signIn.state")
        }
    }
}
