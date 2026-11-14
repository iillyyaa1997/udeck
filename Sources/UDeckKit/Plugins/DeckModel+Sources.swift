import AppKit
import Foundation
import UDeckCore

/// What **Look up** in **Add a source…** is doing, or came to.
public enum SourceAdding: Equatable, Sendable {
    /// Being asked of `host`.
    case reading(host: String)
    /// What it came to (`SourceLookUp.Outcome`): a repository **Add** adds, or
    /// why nothing is offered.
    case came(SourceLookUp.Outcome)
}

extension DeckModel {
    // MARK: - The sources added

    var sourceStore: SourceStore { SourceStore(paths: paths, official: catalogueAddress) }

    /// The sources of one's own uDeck reads: those `sources.json` lists while
    /// it can be read, and none while it cannot (`sourcesProblem`).
    public var sources: [OwnSource] { sourcesProblem == nil ? sourceList.sources : [] }

    /// Whether a copy of `source` — `official`, or a source of one's own by
    /// its id — may be asked about at all (`SourceAccess.canRead`): read,
    /// updated, reinstalled, put back, its history read.
    public func canRead(_ source: String) -> Bool {
        SourceAccess.canRead(source, officialCatalogue: readsOfficialRepository, sources: sources)
    }

    /// Whether the official repository may be asked anything but its number:
    /// **Official catalogue** on, and its address not another repository's
    /// (`SourceAccess.readsOfficialRepository`).
    public var readsOfficialRepository: Bool {
        SourceAccess.readsOfficialRepository(officialCatalogue: settings.readsOfficialCatalogue, state: catalogueState)
    }

    /// The source of one's own with this id, while it is added.
    public func source(_ id: String) -> OwnSource? {
        sources.first { $0.id == id }
    }

    /// The sources the operator trusted, by id (`SourceList.trusted`, S4-08):
    /// none while `sources.json` cannot be read, so that every copy of a
    /// source of one's own is held to its tree then (S4-09).
    public var trustedSources: Set<String> { sourcesProblem == nil ? sourceList.trusted : [] }

    /// The names of the trusted sources, by id, as their blocks show them
    /// (`sourceName`): what a copy of one's default branch is named by
    /// (`CopyName`).
    public var trustedSourceNames: [String: String] {
        let trusted = trustedSources
        return Dictionary(sources.filter { trusted.contains($0.id) }.map { ($0.id, sourceName($0)) },
                          uniquingKeysWith: { first, _ in first })
    }

    /// `sources.json` read again, and each source's state with it: a source
    /// gone from it takes its catalogue off the screen.
    func loadSources() {
        let trustedBefore = trustedSources
        defer { if trustedSources != trustedBefore { trustChanged() } }
        switch sourceStore.load() {
        case .success(let list):
            if list != sourceList { sourceList = list }
            sourcesProblem = nil
        case .failure(let broken):
            sourceList = SourceList()
            if sourcesProblem != broken {
                DeckLog.plugins.error("\(String(describing: broken), privacy: .public)")
            }
            sourcesProblem = broken
        }
        let ids = Set(sources.map(\.id))
        var states: [String: CatalogueState] = [:]
        for id in ids { states[id] = CatalogueStore(paths: paths, source: id).state() }
        if states != sourceStates { sourceStates = states }
        for id in sourceCatalogues.keys where !ids.contains(id) { sourceCatalogues[id] = nil }
        // Each GitLab source's limit, from what its state kept, while it is listed.
        for source in sources where source.provider == SourceLink.gitlab && gitLabLimits[source.id] == nil {
            gitLabLimits[source.id] = RateLimitRecorder(states[source.id]?.rateLimit ?? RateLimitState())
        }
        for id in gitLabLimits.keys where !ids.contains(id) { gitLabLimits[id] = nil }
        // Each GitHub source with a token, its own limit the same way.
        for source in sources where source.provider == SourceLink.github && source.access != OwnSource.Access.none
            && tokenLimits[source.id] == nil {
            tokenLimits[source.id] = RateLimitRecorder(states[source.id]?.rateLimit ?? RateLimitState())
        }
        for id in tokenLimits.keys where !ids.contains(id) { tokenLimits[id] = nil }
        // A token held for a source gone from the file, switched to no token,
        // or now another repository's number: taken back from every client.
        for id in sourceTokens.reconcile(with: sources) {
            DeckLog.plugins.info("the token of \(id, privacy: .public) taken back: sources.json no longer reads it with this one")
        }
    }

    /// What a change of the sources trusted changes at once — **Trust…**,
    /// **Stop trusting…**, **Remove…** of a trusted source, a `sources.json`
    /// changed or broken (S4-08): where each copy stands, from the trees last
    /// hashed, before anything else reads it, so that a copy no longer
    /// trusted neither updates itself nor carries its decision meanwhile; and
    /// every poll loop, planned on what each decision is held to (S4-09).
    /// Its records are written by the hashing after it. Nothing before the
    /// plugins folder is first read: that reading stands every copy.
    func trustChanged() {
        guard !plugins.isEmpty else { return }
        let found = Reverification.of(plugins, installed: installed, trees: treesOnDisk.trees, heads: [:],
                                      trusted: trustedSources, now: Date())
        if found.standings != standings { standings = found.standings }
        // A copy that waited on its card and may run now — trusted, it asks
        // for nothing, or for what was allowed for this version — runs at once,
        // as **Allow** runs it, not an interval later.
        for id in restartPolling().sorted() {
            if let identifier = PluginIdentifier(rawValue: id) { refresh(identifier) }
        }
        reverify()
    }

    /// **Trust…** of a source, confirmed (S4-08): its `trustedAt` written,
    /// and its default branch's copies trusted from now on. Kept on this Mac
    /// alone; never while `sources.json` cannot be read.
    public func trustSource(_ id: String) {
        setTrusted(id, at: Date())
    }

    /// **Stop trusting…** of a source, confirmed: at once, its copies are
    /// Unverified, held to their trees, and each asks again before it next
    /// runs.
    public func stopTrustingSource(_ id: String) {
        setTrusted(id, at: nil)
    }

    private func setTrusted(_ id: String, at date: Date?) {
        guard sourcesProblem == nil, source(id) != nil else { return }
        sourceOperationProblems[id] = nil
        do {
            try sourceStore.modify { list in _ = list.setTrusted(id, at: date) }
            DeckLog.plugins.info("\(id, privacy: .public) \(date == nil ? "no longer trusted" : "trusted", privacy: .public)")
        } catch {
            sourceOperationProblems[id] = "\(error)"
        }
        loadSources()
    }

    /// What `sources.json`'s problem line says: why the file cannot be used,
    /// or each entry left out — none when there is nothing to say.
    public var sourcesProblemLines: [Phrase] {
        if let sourcesProblem { return [.sourcesBroken(sourcesProblem)] }
        return sourceList.skipped.map(Phrase.sourceSkipped)
    }

    /// What a source is called on screen (`SourceName.shown`): its passport's
    /// name as its cache holds it, cleaned — or its address.
    public func sourceName(_ source: OwnSource) -> String {
        SourceName.shown(sourceCatalogues[source.id]?.passport.name, address: source.address,
                         officialName: catalogue?.passport.name)
    }

    /// The catalogue of `source` — the official one's, or a source of one's
    /// own's by its id — as its cache holds it.
    public func catalogue(of source: String) -> Catalogue? {
        source == InstalledPlugins.officialSource ? catalogue : sourceCatalogues[source]
    }

    /// What each source's catalogue remembers between reads.
    public func catalogueState(of source: String) -> CatalogueState {
        source == InstalledPlugins.officialSource ? catalogueState : (sourceStates[source] ?? CatalogueState())
    }

    /// The clients the sources of one's own are read through: GitHub's API
    /// and raw host as the official source has them, and its limit; each
    /// GitLab's API — where the host map sends it in a test build — and each
    /// GitLab source's own limit, and **Look up**'s by host.
    var sourceClients: SourceClients {
        var clients = SourceClients(endpoints: endpoints, udeckVersion: udeckVersion, limits: limits, hostMap: hostMap,
                                    gitLabLimits: gitLabLimits)
        clients.lookUpLimits = lookUpLimits
        clients.tokenLimits = tokenLimits
        return clients
    }

    /// The provider `source` is read through now — nil while it is not added
    /// — carrying the token held for it under its lease. A source read with a
    /// token is never read without one: nil while none is held (S4-18), so
    /// nothing goes anonymously — to GitHub's raw host least of all.
    func sourceProvider(_ id: String) -> SourceProvider? {
        guard let source = source(id) else { return nil }
        let credential = sourceTokens.credential(of: id)
        if source.access != OwnSource.Access.none, credential == nil { return nil }
        return sourceClients.of(source, credential: credential)
    }

    /// The source's token asked of the vault for its API origin in this
    /// build (S4-18) — `requested` for a press, which tries the Keychain once
    /// more after a failure — and held for its reads and presses. What stops
    /// it being sent comes back: a token checked with another origin
    /// (S4-20, item 18), a Keychain that could not be read (item 14), none
    /// kept at all, a token the host refused — asked again only by a press —
    /// or one taken back while the vault was asked. Nothing at all is asked
    /// for a source whose `access` is `none`.
    ///
    /// `pressed` is Check now, Token… or Add: the only presses that send a
    /// token the host refused once more (S4-19).
    func lookUpCredential(of source: OwnSource, requested: Bool, pressed: Bool = false) async -> CatalogueError? {
        guard source.access != OwnSource.Access.none else { return nil }
        if sourcesForgetting.contains(source.id) { return .tokenWithdrawn }
        if !pressed, sourceTokens.wasRejected(source.id) { return .unauthorized }
        if !requested, let held = sourceTokens.credential(of: source.id), held.binding.remoteID == source.remoteID { return nil }
        guard let origin = sourceClients.apiOrigin(of: source) else { return nil }
        let ticket = sourceTokens.ticket(source.id)
        let vault = credentialVault
        let found = await vault.credential(for: source, apiOrigin: origin, requested: requested)
        // Forgotten, replaced or removed while the vault was asked — in uDeck
        // or in `sources.json` by hand, read again now: what it said is not
        // held. Nor is a token the host refused meanwhile, unless pressed.
        loadSources()
        guard !sourcesForgetting.contains(source.id), let now = self.source(source.id),
              now.access != OwnSource.Access.none, now.remoteID == source.remoteID else { return .tokenWithdrawn }
        // A Token… press took the turn meanwhile and has changed nothing yet:
        // the token still held is read with, as before the press.
        guard sourceTokens.isCurrent(ticket) else {
            if let held = sourceTokens.credential(of: source.id), held.binding.remoteID == now.remoteID { return nil }
            return sourceTokens.wasRejected(source.id) ? .unauthorized : .tokenWithdrawn
        }
        switch found {
        case .credential(let credential):
            guard sourceTokens.hold(credential, for: ticket, renewingRejected: pressed) != nil else {
                return sourceTokens.wasRejected(source.id) ? .unauthorized : .tokenWithdrawn
            }
            pruneTokens()
            return nil
        case .none:
            return nil
        case .missing:
            sourceTokens.release(source.id)
            return .tokenMissing
        case .unbound(let checked):
            sourceTokens.release(source.id)
            return .credentialUnbound(origin: checked.description)
        case .unavailable(let reason):
            sourceTokens.release(source.id)
            return .keychainUnavailable(reason: reason)
        }
    }

    /// Tokens left in the item for a source that has none — removed, or
    /// switched to no token, while the item could not be written, or uDeck
    /// quit in between — forgotten, once the item has been read anyway.
    func pruneTokens() {
        // Every source with a token, every token being written, and anything
        // written from now on is kept.
        let keeping = Set(sources.filter { $0.access != OwnSource.Access.none }.map(\.id)).union(sourcesKeeping.keys)
            .union(sourceList.skipped.compactMap(\.id))
        let cutoff = ProcessInfo.processInfo.systemUptime
        let vault = credentialVault
        Task {
            do throws(CredentialVault.ChangeError) {
                try await vault.prune(keeping: keeping, writtenBefore: cutoff)
            } catch {
                DeckLog.plugins.error("tokens of sources no longer added were not forgotten: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Whether `source` is read with its token now.
    func isTokened(_ id: String) -> Bool { sourceTokens.credential(of: id) != nil }

    /// The token of the source `id` ready before an install, an update, a
    /// put-back or a history read uses its provider (S4-18): looked up when
    /// none is held — after a relaunch, before the source's first read — so
    /// that a source read with a token is never asked anything without it;
    /// `sources.json` read again first, so a source switched to no token or
    /// removed by hand is no longer read with one. A token the host refused
    /// is not sent again until Check now or Token… (S4-19). Nil for the
    /// official source and a source read without a token.
    func readyToken(for id: String) async -> CatalogueError? {
        guard id != InstalledPlugins.officialSource else { return nil }
        loadSources()
        guard let source = source(id), source.access != OwnSource.Access.none else { return nil }
        if sourceStates[id]?.lastError == .unauthorized || sourceTokens.wasRejected(id) { return .unauthorized }
        if sourceTokens.credential(of: id) != nil { return nil }
        if let problem = await lookUpCredential(of: source, requested: true) { return problem }
        return sourceTokens.credential(of: id) == nil ? .tokenMissing : nil
    }

    /// What became of the source `id`'s token in an install, a put-back or a
    /// history read: refused by the host, its block says so as a read's
    /// `401` does, and nothing more is sent until Check now or Token….
    func noteTokenRefusal(_ id: String) {
        guard sourceTokens.wasRejected(id), source(id) != nil else { return }
        sourceStates[id] = CatalogueStore(paths: paths, source: id).updateState { state in
            state.lastAttempt = Date()
            state.lastError = .unauthorized
        }
    }

    // MARK: - One read at a time

    /// `work` once every read asked for before it has ended: the official
    /// source's and each source of one's own's, one at a time, in the order
    /// they were asked — the official source first at launch, then each
    /// source in `sources.json`'s order.
    func inTurn(_ work: @escaping @MainActor () async -> Void) async {
        let previous = readTail
        let mine = Task { @MainActor in
            await previous?.value
            await work()
        }
        readTail = mine
        await mine.value
    }

    // MARK: - When the sources are read

    /// The minute's clock runs while any source can be read — the official
    /// one, or any listed — and stops when none can (`SourceAccess.clockRuns`).
    func updateClock() {
        guard SourceAccess.clockRuns(officialCatalogue: settings.readsOfficialCatalogue, sources: sources) else {
            catalogueTimer?.invalidate()
            catalogueTimer = nil
            return
        }
        guard catalogueTimer == nil else { return }
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        catalogueTimer = timer
    }

    /// The minute's tick: an update by itself that waited is asked about
    /// again, whatever any switch says — each copy's own source decides — and
    /// each source due is read (`CatalogueSchedule.nextDue`, `SourceSchedule`):
    /// the official one under its switch, each source of one's own while it is
    /// listed.
    func tick() {
        // `sources.json` read again first: a trust taken away by hand — or the
        // file broken — counts from this minute on, before anything updates.
        loadSources()
        updateVerifiedPlugins()
        let now = Date()
        if settings.readsOfficialCatalogue, !catalogueRefreshing, CatalogueSchedule.nextDue(catalogueState, now: now) <= now,
           catalogueState.lastAttempt.map({ now.timeIntervalSince($0) > 60 }) ?? true {
            Task { await refreshCatalogue(unrequested: true, why: "on schedule") }
        }
        for id in SourceSchedule.due(sources, states: sourceStates, reading: sourcesRefreshing, now: now) {
            Task { await refreshSource(id, unrequested: true, why: "on schedule") }
        }
    }

    /// The launch reads of the sources of one's own: a few seconds after the
    /// panel is ready, after the official source's, each unless it was read
    /// in the last day.
    func startSourceLaunchReads(after official: Task<Void, Never>?) {
        sourceLaunch?.cancel()
        let due = SourceSchedule.atLaunch(sources, states: sourceStates, now: Date())
        guard !due.isEmpty else { return }
        sourceLaunch = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Seconds.nanoseconds(CatalogueSchedule.launchDelay))
            guard !Task.isCancelled else { return }
            await official?.value
            for id in due {
                guard !Task.isCancelled else { return }
                await self?.refreshSource(id, unrequested: true, why: "at launch")
            }
        }
    }

    /// Settings → Plugins was opened: each source whose list is more than an
    /// hour old is read, whatever **Official catalogue** says.
    func sourcesPaneOpened() {
        for id in SourceSchedule.whenSettingsOpen(sources, states: sourceStates, now: Date()) {
            Task { await refreshSource(id, unrequested: false, why: "Settings → Plugins opened") }
        }
    }

    /// **Check now** on a source's block: a press, which asks the Keychain
    /// again, whatever failed before (S4-18), and sends a token the host
    /// refused once more (S4-19).
    public func checkSourceNow(_ id: String) {
        let tokened = (source(id)?.access ?? OwnSource.Access.none) != OwnSource.Access.none
        let vault = credentialVault
        Task {
            if tokened { await vault.tryAgain() }
            await refreshSource(id, unrequested: false, pressed: true, why: "Check now")
        }
    }

    // MARK: - Reading a source

    /// A read of the source `id`'s catalogue, as the official one is read
    /// (`CatalogueRefresher`), through its own client (`SourceProvider`) —
    /// addressed by its number — and its own cache, `catalogue/<id>/`. A
    /// describe that names the repository anew is written back to
    /// `sources.json`, the id the same. Not while it is not listed, and never
    /// two of one source at once.
    func refreshSource(_ id: String, unrequested: Bool, pressed: Bool = false, why: String) async {
        guard source(id) != nil else { return }
        guard !sourcesRefreshing.contains(id) else {
            // A press while it is read — the read without a token after
            // Forget — waits for the read under way, and comes after it.
            if pressed { sourcesRereading.insert(id) }
            return
        }
        sourcesRefreshing.insert(id)
        await inTurn { [self] in
            defer {
                sourcesRefreshing.remove(id)
                if sourcesRereading.remove(id) != nil {
                    Task { await refreshSource(id, unrequested: false, pressed: true, why: "asked again while it was read") }
                }
            }
            // `sources.json` as it is now: a source removed or switched to no
            // token by hand is not read with its token.
            loadSources()
            guard let source = source(id) else { return }
            let store = CatalogueStore(paths: paths, source: id)
            // A token the host refused (`401`): nothing more is sent for the
            // source, with it or without it, until Check now or Token…
            // (S4-19) — a read nobody pressed for leaves it alone.
            if !pressed, source.access != OwnSource.Access.none,
               sourceStates[id]?.lastError == .unauthorized || sourceTokens.wasRejected(id) {
                return
            }
            if let problem = await lookUpCredential(of: source, requested: pressed || !unrequested, pressed: pressed) {
                DeckLog.plugins.info("\(source.address.description, privacy: .public): not read, \(String(describing: problem), privacy: .public)")
                sourceStates[id] = store.updateState { state in
                    state.lastAttempt = Date()
                    // A token the host refused stays refused, whatever the
                    // Keychain said to a press since: nothing reads the source
                    // by itself until a token is read with again (S4-19).
                    if state.lastError == .unauthorized, problem != .tokenWithdrawn { return }
                    state.lastError = problem
                }
                return
            }
            guard let provider = sourceProvider(id) else { return }
            let tokened = isTokened(id)
            DeckLog.plugins.info("reading \(source.address.description, privacy: .public) (\(id, privacy: .public)): \(why, privacy: .public)\(tokened ? " with its token" : "", privacy: .public)")
            let refresher = CatalogueRefresher(provider: provider, store: store,
                                               limits: sourceClients.limits(of: source, tokened: tokened), tokened: tokened)
            let outcome = await refresher.refresh(unrequested: unrequested, language: strings.language.rawValue,
                                                  installedCommits: installed.commits)
            DeckLog.plugins.info("\(source.address.description, privacy: .public): \(String(describing: outcome), privacy: .public)")
            guard self.source(id) != nil else {
                // Removed while it was read: what the read wrote goes with it —
                // but not while `sources.json` cannot be read, which lists no
                // source and removes none.
                if sourcesProblem == nil { try? FileManager.default.removeItem(at: store.directory) }
                return
            }
            if let renamed = provider.renamedTo { respell(id, path: renamed) }
            sourceStates[id] = store.state()
            persistRateLimit()
            await reloadSourceCatalogue(id)
            reverify()
            var succeeded = false
            if case .refreshed = outcome { succeeded = true }
            autoUpdates.read(id, succeeded: succeeded, hashing: reverifications)
        }
    }

    /// The name the host gives the source now, written back to `sources.json`
    /// — the same id, the same number (`SourceList.respell`).
    func respell(_ id: String, path: String) {
        do {
            let written = try sourceStore.modify { list in list.respell(id, path: path, official: catalogueAddress) }
            DeckLog.plugins.info("\(id, privacy: .public) is called \(path, privacy: .public) now: \(written ? "written back" : "not written", privacy: .public)")
        } catch {
            DeckLog.plugins.error("\(id, privacy: .public)'s new name \(path, privacy: .public) could not be written: \(String(describing: error), privacy: .public)")
        }
        loadSources()
    }

    /// Every source's catalogue as its cache holds it, away from the main
    /// thread.
    func reloadSourceCatalogues() async {
        for source in sources { await reloadSourceCatalogue(source.id) }
    }

    /// The source `id`'s catalogue as its cache holds it, read away from the
    /// main thread (`Catalogue.read`) — only the read asked for last shown.
    func reloadSourceCatalogue(_ id: String) async {
        sourceCatalogueReads[id, default: 0] += 1
        let read = sourceCatalogueReads[id]
        guard let source = source(id) else {
            sourceCatalogues[id] = nil
            return
        }
        let loaded = await Catalogue.read(from: CatalogueStore(paths: paths, source: id), address: source.address,
                                          udeck: udeck, language: strings.language.rawValue, source: id)
        guard read == sourceCatalogueReads[id], self.source(id) != nil else { return }
        if loaded != sourceCatalogues[id] { sourceCatalogues[id] = loaded }
        sourceCataloguesRead.insert(id)
    }

    // MARK: - Add a source…

    /// **Add a source…**: its sheet opened — or closed, and what it said goes.
    public func toggleAddSource() {
        if sourceSheetOpen { closeAddSource() } else { openAddSource(prefilled: nil) }
    }

    /// The sheet opened, its field holding `prefilled` — what **Add as a
    /// source…** on a link that is no fork fills it with — or what it held.
    public func openAddSource(prefilled: String?) {
        sourceLookups += 1
        if let prefilled { sourceField = prefilled }
        sourceAdding = nil
        addSourceDraft = nil
        sourceOperationProblems[""] = nil
        sourceSheetOpen = true
    }

    /// The sheet closed: what it said goes, and an answer still on its way
    /// is not shown.
    public func closeAddSource() {
        sourceLookups += 1
        sourceSheetOpen = false
        sourceField = ""
        addSourceDraft = nil
        sourceAdding = nil
        sourceOperationProblems[""] = nil
    }

    /// **Look up** on the address in the field (`SourceLookUp`): refused at
    /// once without a request, or asked of its host anonymously — on GitHub
    /// two requests to the API and the passport from the raw host, on a
    /// GitLab three to its API, counted against that host's limit.
    /// `withToken`: **Look up with the token** under the token step — the
    /// token pasted there, sent only to the address the step is for, and
    /// only while the field still names it (S4-17).
    public func lookUpSource(withToken: Bool = false) {
        let draft = withToken ? addSourceDraft : nil
        let pasted = draft?.token.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let token: Secret? = pasted.isEmpty ? nil : Secret(pasted)
        if withToken, token == nil { return }
        sourceLookups += 1
        let asked = sourceLookups
        sourceOperationProblems[""] = nil
        if let sourcesProblem {
            sourceAdding = .came(.refused(.sourcesBroken(sourcesProblem)))
            return
        }
        let official = catalogueAddress
        let link: SourceLink
        if let draft {
            guard SourceLookUp.link(sourceField, official: official) == draft.link else {
                addSourceDraft = nil
                return
            }
            link = draft.link
        } else {
            switch SourceLookUp.read(sourceField, official: official) {
            case .refused(let phrase):
                sourceAdding = .came(.refused(phrase))
                addSourceDraft = nil
                return
            case .link(let read):
                link = read
            }
        }
        sourceAdding = .reading(host: link.host)
        sourceAddingTokened = token != nil
        if link.provider == SourceLink.gitlab, lookUpLimits[link.host] == nil { lookUpLimits[link.host] = RateLimitRecorder() }
        let list = sourceList
        let clients = sourceClients
        let officialID = endpoints.repositoryID
        DeckLog.plugins.info("looking up a source: \(link.address.description, privacy: .public)\(token == nil ? "" : " with a token", privacy: .public)")
        Task {
            let came = await SourceLookUp.lookUp(link, list: list, official: official, officialID: officialID,
                                                 clients: clients, token: token)
            DeckLog.plugins.info("the source came to \(String(describing: came), privacy: .public)")
            persistRateLimit()
            guard asked == sourceLookups else { return }
            sourceAdding = .came(came)
            // The token step, for this address alone: after a `404` without
            // a token — it may be private — and after anything said of a
            // token tried, so another can be pasted; the one tried is not
            // kept in the field.
            if Self.offersTheTokenStep(came) {
                addSourceDraft = TokenDraft(link: link, token: "")
            } else {
                addSourceDraft = nil
            }
        }
    }

    /// Whether what **Look up** came to offers the token step (S4-17).
    static func offersTheTokenStep(_ came: SourceLookUp.Outcome) -> Bool {
        guard case .refused(let phrase) = came else { return false }
        switch phrase {
        case .sourceNotFound, .sourceTokenNotFound, .sourceTokenRejected, .sourceTokenScope, .sourceTokenWrongProvider:
            return true
        default:
            return false
        }
    }

    /// **Add** on what **Look up** found: the entry written with the id
    /// derived from its number (`SourceList.add`), its state seeded with the
    /// default branch it heard and its passport kept, and its catalogue read
    /// at once. Nothing is added but what was found, and nothing while
    /// `sources.json` cannot be read.
    public func addSource() {
        guard case .came(.found(let found))? = sourceAdding, sourcesProblem == nil else { return }
        guard let credential = found.credential else {
            add(found, access: OwnSource.Access.none)
            return
        }
        // A token that read the repository is kept first, under the id the
        // source will have; the source is added only once it is (S4-17). A
        // source already listed under that id keeps its own token: Add says
        // it is added, and writes nothing.
        let id = SourceID.derive(found.identity, path: found.path)
        if let listed = source(id) {
            sourceAdding = .came(.alreadyAdded(listed))
            return
        }
        let ticket = sourceTokens.begin(id)
        let vault = credentialVault
        sourcesKeeping[id] = ticket
        Task {
            defer { if sourcesKeeping[id] == ticket { sourcesKeeping[id] = nil } }
            let revision: Int
            do throws(CredentialVault.ChangeError) {
                revision = try await vault.keep(credential, for: id)
            } catch {
                sourceOperationProblems[""] = strings(.sourceKeychainUnavailable(
                    address: found.address.description, reason: Self.said(error)))
                return
            }
            // Its turn lost meanwhile, or the entry not written: its own write
            // taken back — that write alone, never a token kept after it.
            guard sourceTokens.isCurrent(ticket), source(id) == nil,
                  add(found, access: OwnSource.Access.token),
                  sourceTokens.hold(credential, for: ticket, renewingRejected: true) != nil else {
                await takeBack(id, written: revision, address: found.address.description)
                return
            }
            sourceNotices[id] = tokenNotices(pasted: credential.token, writeScope: found.writeScope)
        }
    }

    /// A token write that lost its turn taken back — that write alone. When
    /// the Keychain will not, it is said where it was pressed, and the token
    /// is pruned the next time the item is read (`pruneTokens`).
    func takeBack(_ id: String, written revision: Int, address: String) async {
        do throws(CredentialVault.ChangeError) {
            try await credentialVault.forget(id, written: revision)
        } catch {
            DeckLog.plugins.error("a token written for \(id, privacy: .public) and not kept could not be taken back: \(String(describing: error), privacy: .public)")
            let said = strings(.sourceKeychainUnavailable(address: address, reason: Self.said(error)))
            sourceOperationProblems[source(id) == nil ? "" : id] = said
            pruneTokens()
        }
    }

    /// What a change of the vault failed with, as a sentence says it.
    static func said(_ error: CredentialVault.ChangeError) -> String {
        switch error {
        case .unavailable(let reason), .notWritten(let reason): reason
        case .unreadable: "the item is not one this uDeck reads"
        }
    }

    /// What a source says once its token is kept: the clipboard cleared of
    /// it, when it still held exactly that token (S4-20, item 20) — which
    /// narrows the time a plugin could read it there, and does not close it
    /// — and a classic token's write scope (item 21).
    func tokenNotices(pasted token: Secret, writeScope: Bool) -> [Phrase] {
        var notices: [Phrase] = []
        let board = NSPasteboard.general
        let seen = board.changeCount
        if board.string(forType: .string) == token.revealed, board.changeCount == seen {
            board.clearContents()
            notices.append(.sourceTokenClipboardCleared)
        }
        if writeScope { notices.append(.sourceTokenWriteScope) }
        return notices
    }

    /// The entry written, and the source read: whether it was added.
    @discardableResult
    private func add(_ found: SourceLookUp.Found, access: String) -> Bool {
        let added: Result<OwnSource, SourceList.AddRefusal>
        do {
            added = try sourceStore.modify { list in
                list.add(provider: found.provider, host: found.host, path: found.path, remoteID: found.remoteID,
                         access: access, at: Date(), official: catalogueAddress)
            }
        } catch {
            sourceOperationProblems[""] = "\(error)"
            loadSources()
            return false
        }
        let source: OwnSource
        switch added {
        case .success(let new): source = new
        case .failure(.alreadyAdded(let listed)):
            sourceAdding = .came(.alreadyAdded(listed))
            return false
        case .failure(.idTaken(let taken)):
            sourceAdding = .came(.refused(.sourceIDTaken(name: taken.address.description)))
            return false
        case .failure(.address(let refusal)):
            sourceAdding = .came(.refused(.sourceLinkRefused(refusal, official: catalogueAddress.description)))
            return false
        case .failure(.listedAsSkipped(let skipped)):
            sourceAdding = .came(.refused(.sourceSkipped(skipped)))
            return false
        }
        let store = CatalogueStore(paths: paths, source: source.id)
        try? store.save(SourceLookUp.firstState(of: found))
        _ = try? store.save(blob: found.passportData)
        DeckLog.plugins.info("added \(source.address.description, privacy: .public) as \(source.id, privacy: .public)")
        loadSources()
        closeAddSource()
        updateClock()
        Task { await refreshSource(source.id, unrequested: false, pressed: true, why: "added") }
        return true
    }

    // MARK: - Token…

    /// **Token…** on a source's block: its sheet opened, or closed — what
    /// was pasted under it gone either way.
    public func toggleToken(_ id: String) {
        sourceTokenDraft = ""
        sourceTokenOpen = sourceTokenOpen == id ? nil : id
    }

    /// **Look up with the token** under **Token…**: the pasted token checked
    /// with one request by the source's number — refused before any request
    /// when its prefix proves it the other provider's (S4-20, item 23) —
    /// and kept, bound to that number and the origin it went to, only when it
    /// read the repository; then the source read with it (S4-17). A check
    /// that comes back after Forget, Remove or another token was pressed
    /// keeps nothing (`SourceTokenBook`).
    public func keepToken(for id: String) {
        let pasted = sourceTokenDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let source = source(id), !pasted.isEmpty, sourcesProblem == nil, !sourcesForgetting.contains(id),
              let origin = sourceClients.apiOrigin(of: source) else { return }
        // Every press takes the turn from the check before it — a token of the
        // other provider refused at once included.
        let ticket = sourceTokens.begin(id)
        sourceTokenChecks[id]?.cancel()
        sourceTokenChecks[id] = nil
        if TokenPrefix.isTheOtherProviders(pasted, source: source.provider) {
            sourceNotices[id] = [.sourceTokenWrongProvider(host: source.host, looksLikeGitHub: source.provider == SourceLink.gitlab)]
            return
        }
        let credential = SourceCredential(token: Secret(pasted), binding: CredentialBinding(
            provider: source.provider, remoteID: source.remoteID, apiOrigin: origin))
        guard let provider = sourceClients.of(source, credential: credential) else { return }
        let vault = credentialVault
        let address = source.address.description
        sourceNotices[id] = nil
        sourcesKeeping[id] = ticket
        sourceTokenChecks[id] = Task {
            defer {
                if sourceTokens.isCurrent(ticket) { sourceTokenChecks[id] = nil }
                if sourcesKeeping[id] == ticket { sourcesKeeping[id] = nil }
            }
            let writeScope: Bool
            do {
                writeScope = try await provider.describeWithScopes().scopes.contains("repo")
            } catch {
                guard sourceTokens.isCurrent(ticket), !Task.isCancelled else { return }
                let reason = CatalogueRefresher.reason(error, branch: nil, tokened: true)
                sourceNotices[id] = [CatalogueTrouble.phrase(reason, address: address, host: source.host, readAt: nil,
                                                             until: { Clock.text($0, self.strings) },
                                                             provider: source.provider, tokened: true)]
                return
            }
            guard sourceTokens.isCurrent(ticket), let now = self.source(id), now.remoteID == source.remoteID else { return }
            // A replacement leaves `sources.json` as it is — it already says
            // the source has a token — so a failed write never costs the token
            // it replaced; a first token writes `access`, or is taken back.
            let replacing = now.access != OwnSource.Access.none
            let revision: Int
            do throws(CredentialVault.ChangeError) {
                revision = try await vault.keep(credential, for: id)
            } catch {
                guard sourceTokens.isCurrent(ticket) else { return }
                sourceNotices[id] = [.sourceKeychainUnavailable(address: address, reason: Self.said(error))]
                return
            }
            var written = false
            var problem: String?
            if sourceTokens.isCurrent(ticket), self.source(id) != nil {
                if replacing {
                    written = true
                } else {
                    do {
                        written = try sourceStore.modify { list in list.setAccess(id, OwnSource.Access.token) }
                    } catch {
                        problem = "\(error)"
                    }
                }
            }
            if written { startTheLimitOfANewToken(id) }
            loadSources()
            guard written, sourceTokens.hold(credential, for: ticket, renewingRejected: true) != nil else {
                await takeBack(id, written: revision, address: address)
                if let problem, sourceTokens.isCurrent(ticket) { sourceOperationProblems[id] = problem }
                return
            }
            sourceNotices[id] = tokenNotices(pasted: credential.token, writeScope: writeScope)
            // Its own Token… closed — never another source's opened since.
            if sourceTokenOpen == id {
                sourceTokenDraft = ""
                sourceTokenOpen = nil
            }
            await refreshSource(id, unrequested: false, pressed: true, why: "a token kept")
        }
    }

    /// A token just kept under **Token…** starts from what its host says of
    /// it: the limit the source's reads were held to until now — an address's
    /// sixty an hour on GitHub, an address's limiter on GitLab, or another
    /// token's hour — is not the new token's. Carried over, a read with it was
    /// held back until that block ended, an hour at most, and sent nothing
    /// (the lab's smoke.real-github-token, run 43521794191: the runner's
    /// address had none of its sixty left). Its kept limit and its recorders
    /// start afresh; `loadSources` seeds them from the state as written now.
    func startTheLimitOfANewToken(_ id: String) {
        sourceStates[id] = CatalogueStore(paths: paths, source: id).updateState { $0.rateLimit = RateLimitState() }
        tokenLimits[id] = nil
        gitLabLimits[id] = nil
    }

    /// **Forget the token** under **Token…**: taken back from every client
    /// at once — a read or an install under way sends it no more — then its
    /// entry gone from the Keychain item, and the item with the last token,
    /// and only then the source written as read without one and read so.
    /// When the Keychain cannot be written, the token stays, and is said to.
    public func forgetToken(of id: String) {
        guard source(id) != nil, sourcesProblem == nil, !sourcesForgetting.contains(id) else { return }
        sourceTokens.withdraw(id)
        sourceTokenChecks[id]?.cancel()
        sourceTokenChecks[id] = nil
        sourcesForgetting.insert(id)
        sourceTokenDraft = ""
        sourceTokenOpen = nil
        sourceNotices[id] = nil
        let vault = credentialVault
        Task {
            do throws(CredentialVault.ChangeError) {
                try await vault.forget(id)
            } catch {
                sourcesForgetting.remove(id)
                sourceNotices[id] = [.sourceKeychainUnavailable(address: source(id)?.address.description ?? id,
                                                                reason: Self.said(error))]
                return
            }
            do {
                try sourceStore.modify { list in _ = list.setAccess(id, OwnSource.Access.none) }
            } catch {
                sourceOperationProblems[id] = "\(error)"
            }
            sourcesForgetting.remove(id)
            loadSources()
            await refreshSource(id, unrequested: false, pressed: true, why: "its token forgotten")
        }
    }

    // MARK: - Remove…

    /// **Remove…** on a source's block, confirmed: its token taken back at
    /// once and forgotten (S4-20, item 17) — the source stays, and says why,
    /// when the Keychain cannot be written — then its entry and
    /// `catalogue/<id>/` go, and nothing more is asked of it. What was
    /// installed from it stays, and runs, its row saying the source is no
    /// longer added; nothing updates, reinstalls or puts it back until the
    /// source is added again.
    public func removeSource(_ id: String) {
        guard sourcesProblem == nil, !sourcesRefreshing.contains(id), !sourcesForgetting.contains(id) else { return }
        // A token being written counts: its write may land after the entry
        // goes, so the Keychain is cleared first either way.
        let hadAToken = (source(id)?.access ?? OwnSource.Access.none) != OwnSource.Access.none
            || sourcesKeeping[id] != nil
        sourceOperationProblems[id] = nil
        sourceTokens.withdraw(id)
        sourceTokenChecks[id]?.cancel()
        sourceTokenChecks[id] = nil
        if sourceTokenOpen == id {
            sourceTokenOpen = nil
            sourceTokenDraft = ""
        }
        guard hadAToken else {
            finishRemoving(id)
            return
        }
        sourcesForgetting.insert(id)
        let vault = credentialVault
        Task {
            defer { sourcesForgetting.remove(id) }
            do throws(CredentialVault.ChangeError) {
                try await vault.forget(id)
            } catch {
                sourceOperationProblems[id] = strings(.sourceKeychainUnavailable(
                    address: source(id)?.address.description ?? id, reason: Self.said(error)))
                return
            }
            finishRemoving(id)
        }
    }

    private func finishRemoving(_ id: String) {
        do {
            try sourceStore.modify { list in _ = list.remove(id) }
        } catch {
            sourceOperationProblems[id] = "\(error)"
            loadSources()
            return
        }
        try? FileManager.default.removeItem(at: CatalogueStore(paths: paths, source: id).directory)
        sourceCatalogues[id] = nil
        sourceStates[id] = nil
        gitLabLimits[id] = nil
        tokenLimits[id] = nil
        sourceNotices[id] = nil
        sourceCataloguesRead.remove(id)
        autoUpdates.forget(id)
        DeckLog.plugins.info("removed the source \(id, privacy: .public)")
        loadSources()
        updateClock()
        reverify()
        // Whatever a write that lost its turn left behind, once the item is read.
        pruneTokens()
    }
}

/// The token step of **Add a source…** (S4-17): the address the anonymous
/// look-up could not find, and the token pasted for it.
public struct TokenDraft: Equatable, Sendable {
    public let link: SourceLink
    public var token: String
}
