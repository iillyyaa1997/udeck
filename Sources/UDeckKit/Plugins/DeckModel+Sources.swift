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

    /// `sources.json` read again, and each source's state with it: a source
    /// gone from it takes its catalogue off the screen.
    func loadSources() {
        switch sourceStore.load() {
        case .success(let list):
            sourceList = list
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
        return clients
    }

    /// The provider `source` is read through now — nil while it is not added.
    func sourceProvider(_ id: String) -> SourceProvider? {
        source(id).flatMap(sourceClients.of)
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

    /// **Check now** on a source's block.
    public func checkSourceNow(_ id: String) {
        Task { await refreshSource(id, unrequested: false, why: "Check now") }
    }

    // MARK: - Reading a source

    /// A read of the source `id`'s catalogue, as the official one is read
    /// (`CatalogueRefresher`), through its own client (`SourceProvider`) —
    /// addressed by its number — and its own cache, `catalogue/<id>/`. A
    /// describe that names the repository anew is written back to
    /// `sources.json`, the id the same. Not while it is not listed, and never
    /// two of one source at once.
    func refreshSource(_ id: String, unrequested: Bool, why: String) async {
        guard source(id) != nil, !sourcesRefreshing.contains(id) else { return }
        sourcesRefreshing.insert(id)
        await inTurn { [self] in
            defer { sourcesRefreshing.remove(id) }
            guard let source = source(id), let provider = sourceClients.of(source) else { return }
            DeckLog.plugins.info("reading \(source.address.description, privacy: .public) (\(id, privacy: .public)): \(why, privacy: .public)")
            let store = CatalogueStore(paths: paths, source: id)
            let refresher = CatalogueRefresher(provider: provider, store: store, limits: sourceClients.limits(of: source))
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
        sourceOperationProblems[""] = nil
        sourceSheetOpen = true
    }

    /// The sheet closed: what it said goes, and an answer still on its way
    /// is not shown.
    public func closeAddSource() {
        sourceLookups += 1
        sourceSheetOpen = false
        sourceField = ""
        sourceAdding = nil
        sourceOperationProblems[""] = nil
    }

    /// **Look up** on the address in the field (`SourceLookUp`): refused at
    /// once without a request, or asked of its host anonymously — on GitHub
    /// two requests to the API and the passport from the raw host, on a
    /// GitLab three to its API, counted against that host's limit.
    public func lookUpSource() {
        sourceLookups += 1
        let asked = sourceLookups
        sourceOperationProblems[""] = nil
        if let sourcesProblem {
            sourceAdding = .came(.refused(.sourcesBroken(sourcesProblem)))
            return
        }
        let official = catalogueAddress
        let link: SourceLink
        switch SourceLookUp.read(sourceField, official: official) {
        case .refused(let phrase):
            sourceAdding = .came(.refused(phrase))
            return
        case .link(let read):
            link = read
        }
        sourceAdding = .reading(host: link.host)
        if link.provider == SourceLink.gitlab, lookUpLimits[link.host] == nil { lookUpLimits[link.host] = RateLimitRecorder() }
        let list = sourceList
        let clients = sourceClients
        let officialID = endpoints.repositoryID
        DeckLog.plugins.info("looking up a source: \(link.address.description, privacy: .public)")
        Task {
            let came = await SourceLookUp.lookUp(link, list: list, official: official, officialID: officialID,
                                                 clients: clients)
            DeckLog.plugins.info("the source came to \(String(describing: came), privacy: .public)")
            persistRateLimit()
            guard asked == sourceLookups else { return }
            sourceAdding = .came(came)
        }
    }

    /// **Add** on what **Look up** found: the entry written with the id
    /// derived from its number (`SourceList.add`), its state seeded with the
    /// default branch it heard and its passport kept, and its catalogue read
    /// at once. Nothing is added but what was found, and nothing while
    /// `sources.json` cannot be read.
    public func addSource() {
        guard case .came(.found(let found))? = sourceAdding, sourcesProblem == nil else { return }
        let added: Result<OwnSource, SourceList.AddRefusal>
        do {
            added = try sourceStore.modify { list in
                list.add(provider: found.provider, host: found.host, path: found.path, remoteID: found.remoteID,
                         at: Date(), official: catalogueAddress)
            }
        } catch {
            sourceOperationProblems[""] = "\(error)"
            loadSources()
            return
        }
        let source: OwnSource
        switch added {
        case .success(let new): source = new
        case .failure(.alreadyAdded(let listed)):
            sourceAdding = .came(.alreadyAdded(listed))
            return
        case .failure(.idTaken(let taken)):
            sourceAdding = .came(.refused(.sourceIDTaken(name: taken.address.description)))
            return
        case .failure(.address(let refusal)):
            sourceAdding = .came(.refused(.sourceLinkRefused(refusal, official: catalogueAddress.description)))
            return
        case .failure(.listedAsSkipped(let skipped)):
            sourceAdding = .came(.refused(.sourceSkipped(skipped)))
            return
        }
        let store = CatalogueStore(paths: paths, source: source.id)
        try? store.save(SourceLookUp.firstState(of: found))
        _ = try? store.save(blob: found.passportData)
        DeckLog.plugins.info("added \(source.address.description, privacy: .public) as \(source.id, privacy: .public)")
        loadSources()
        closeAddSource()
        updateClock()
        Task { await refreshSource(source.id, unrequested: false, why: "added") }
    }

    // MARK: - Remove…

    /// **Remove…** on a source's block, confirmed: its entry and
    /// `catalogue/<id>/` go, and nothing more is asked of it. What was
    /// installed from it stays, and runs, its row saying the source is no
    /// longer added; nothing updates, reinstalls or puts it back until the
    /// source is added again.
    public func removeSource(_ id: String) {
        guard sourcesProblem == nil, !sourcesRefreshing.contains(id) else { return }
        sourceOperationProblems[id] = nil
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
        sourceCataloguesRead.remove(id)
        autoUpdates.forget(id)
        DeckLog.plugins.info("removed the source \(id, privacy: .public)")
        loadSources()
        updateClock()
        reverify()
    }
}
