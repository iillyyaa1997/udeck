import AppKit
import UDeckCore

/// What the last install, update or removal of a plugin came to, when it did
/// not succeed — shown in that plugin's row until the next attempt.
public enum OperationProblem: Equatable, Sendable {
    case refused([RepositoryRefusal])
    case recordsBroken(String)
    case rateLimited(until: Date)
    case rawRateLimited(until: Date)
    case unreachable(path: String, reason: String)
    case tookTooLong
    case cannotWrite(String)
    case stillRunning(id: String)
    /// The listing of the commit it needed could not be had.
    case catalogue(CatalogueError)
    /// The commit an install at a commit needed — **Back to**, **Reinstall**,
    /// an earlier version — is not on GitHub any more: the history it was on
    /// rewritten, perhaps, and cleaned up since.
    case commitGone(String)

    init(_ error: any Error) {
        switch error {
        case let error as InstallError:
            switch error {
            case .refused(let refusals): self = .refused(refusals)
            case .recordsBroken(let reason): self = .recordsBroken(reason)
            case .rawRateLimited(let until): self = .rawRateLimited(until: until)
            case .rateLimited(let until): self = .rateLimited(until: until)
            case .unreachable(let path, let reason): self = .unreachable(path: path, reason: reason)
            case .tookTooLong: self = .tookTooLong
            case .cannotWrite(let reason): self = .cannotWrite(reason)
            case .stillRunning(let id): self = .stillRunning(id: id)
            }
        case let error as ProviderError:
            switch error {
            case .rateLimited(let until): self = .rateLimited(until: until)
            case .rawRateLimited(let until): self = .rawRateLimited(until: until)
            case .notFound: self = .catalogue(.notFound)
            case .refused(let status): self = .catalogue(.refused(status: status))
            case .unreachable(let reason): self = .catalogue(.unreachable(reason))
            case .badAnswer(let reason): self = .catalogue(.badAnswer(reason))
            }
        case let error as CatalogueError:
            self = .catalogue(error)
        default:
            self = .cannotWrite("\(error)")
        }
    }
}

/// A plugin's earlier versions, as far as they have been read.
public enum HistoryLoad: Equatable, Sendable {
    case reading
    case read(PluginHistory)
    case failed(OperationProblem)
}

/// What a link pasted into **Install from a link…** came to.
public enum LinkLookup: Equatable, Sendable {
    /// Being asked of GitHub.
    case reading
    /// Nothing to install, and why, in the operator's words (`LinkRefusal`).
    case refused(Phrase)
    /// A request that got no good answer — the limit, the network — said as
    /// every such problem in Settings is.
    case failed(OperationProblem)
    /// The official repository's default branch — the catalogue, verified —
    /// and the plugin the link went into, if any.
    case catalogue(plugin: String?)
    /// A branch or a pull request, at the commit it was read at, and the
    /// plugins there that are not what the catalogue's head has.
    case resolved(RefResolver.Resolution)

    /// One line for uDeck's log: what it came to, without the listing.
    var logged: String {
        switch self {
        case .reading: "reading"
        case .refused(let phrase): "refused: \(phrase)"
        case .failed(let problem): "failed: \(problem)"
        case .catalogue(let plugin): "the catalogue" + (plugin.map { " (\($0))" } ?? "")
        case .resolved(let resolution):
            "\(resolution.origin.ref.kind) \(resolution.origin.ref.name ?? "") at \(resolution.commit): "
                + (resolution.entries.map(\.id).joined(separator: ", ").nilIfEmpty ?? "nothing new")
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

extension DeckModel {
    // MARK: - The source

    /// The official source: GitHub's API and raw host, or wherever
    /// `Info.plist` points a lab build.
    var provider: GitHubClient {
        GitHubClient(endpoints: endpoints, udeckVersion: udeckVersion, limits: limits)
    }

    /// The official source as its catalogue and **Install from a link…**
    /// read it: every describe held to the number this build knows the
    /// official repository by (`OfficialRepositoryCheck`).
    var officialReader: OfficialRepositoryCheck {
        OfficialRepositoryCheck(provider, expected: endpoints.repositoryID)
    }

    /// The client a copy from `origin` is taken through: the official
    /// source's, or one for another repository on the same host — a fork's —
    /// asking the same API and raw host and counted against the same limit
    /// (`GitHubClient.client(for:)`); nil for a repository elsewhere, and for
    /// another repository's default branch, which would be recorded as the
    /// official one's (`PluginOrigin.mayBeTaken`).
    func provider(for origin: PluginOrigin) -> GitHubClient? {
        let official = provider
        guard origin.mayBeTaken(forSourceAt: official.address) else { return nil }
        return official.client(for: origin.repository)
    }

    /// The provider a copy from `origin` is taken through, whichever source it
    /// is of: the official source's (`provider(for:)`), or a source of one's
    /// own's — its default branch only, by its number, found by the copy's
    /// source and never by its repository's name (`SourceProvider`); nil for
    /// a source that is not added.
    func client(for origin: PluginOrigin) -> (any RepositoryProvider)? {
        guard origin.source != InstalledPlugins.officialSource else { return provider(for: origin) }
        guard origin.ref.isDefault else { return nil }
        return sourceProvider(origin.source)
    }

    /// `origin` as a copy of it is taken now: a source of one's own's at the
    /// address the source has now — the repository as the record keeps it is
    /// where it was when it was installed, and a source renamed since is read
    /// by its number all the same — the official source's as it is.
    func takenNow(_ origin: PluginOrigin) -> PluginOrigin {
        guard origin.source != InstalledPlugins.officialSource, let source = source(origin.source) else { return origin }
        return PluginOrigin(repository: source.address, ref: origin.ref, source: origin.source)
    }

    /// The repository a source's default branch is taken from: the official
    /// one, or a source of one's own's own (`PluginOrigin.mayBeTaken`).
    func sourceRepository(of source: String) -> RepositoryAddress {
        self.source(source)?.address ?? catalogueAddress
    }

    var catalogueStore: CatalogueStore { CatalogueStore(paths: paths) }

    /// Where the catalogue comes from, as the operator reads it.
    public var catalogueAddress: RepositoryAddress { provider.address }

    /// The installer, fetching each copy's files from the source it is a copy
    /// of: the official source's from the repository its request names — the
    /// official one's, or a fork's — on the official source's host
    /// (`RepositoryProvider.file(of:at:commit:)`); a source of one's own's
    /// through that source's own provider, by its number, whatever its
    /// repository was called when the copy was installed — and nothing of a
    /// source that is not added.
    private var installer: PluginInstaller {
        let official = provider
        var own: [String: SourceProvider] = [:]
        for source in sources {
            if let provider = sourceClients.of(source) { own[source.id] = provider }
        }
        return PluginInstaller(
            paths: paths, discovery: discovery, trash: trash,
            fetchOfSource: { [own] source, repository, path, commit in
                guard source != InstalledPlugins.officialSource else {
                    return try await official.file(of: repository, at: path, commit: commit)
                }
                guard let provider = own[source] else { throw ProviderError.notFound }
                return try await provider.file(at: path, commit: commit)
            }
        )
    }

    // MARK: - When the catalogue is read

    /// Starts the catalogue's own clock: the refresh a few seconds after the
    /// panel is ready, unless it was read successfully in the last day, and
    /// then one a day while uDeck runs.
    ///
    /// Nothing else asks GitHub anything: opening Settings → Plugins when the
    /// catalogue is more than an hour old, **Check now**, and **Install**,
    /// **Update** or **Earlier versions** — each pressed by the operator — and,
    /// after a read, the files of a verified plugin that updates itself
    /// (`updateVerifiedPlugins`). Each read asks after the branches and pull
    /// requests copies came from too (`followLines`).
    ///
    /// The sources the operator added are read on the same schedule, each by
    /// its own state, for as long as `sources.json` lists them — whatever
    /// **Official catalogue** says, which governs the official repository
    /// alone — after the official source's launch read, one at a time
    /// (`SourceSchedule`, `inTurn`). The minute's clock runs while any source
    /// can be read (`updateClock`).
    public func startCatalogueSchedule() {
        launchRefresh?.cancel()
        launchRefresh = nil
        catalogueTimer?.invalidate()
        catalogueTimer = nil
        if settings.readsOfficialCatalogue, CatalogueSchedule.refreshesAtLaunch(catalogueState, now: Date()) {
            launchRefresh = Task { [weak self] in
                try? await Task.sleep(nanoseconds: Seconds.nanoseconds(CatalogueSchedule.launchDelay))
                guard !Task.isCancelled else { return }
                await self?.refreshCatalogue(unrequested: true, why: "at launch")
            }
        }
        startSourceLaunchReads(after: launchRefresh)
        // A minute's tick asks whether the next refresh is due; the answer is
        // `CatalogueSchedule.nextDue`, which is where the rule is tested.
        updateClock()
    }

    /// Settings → Plugins was opened: the catalogue is read if it is more than
    /// an hour old, and so is each source of one's own whatever the switch.
    public func pluginsPaneOpened() {
        if settings.readsOfficialCatalogue, CatalogueSchedule.refreshesWhenSettingsOpen(catalogueState, now: Date()) {
            Task { await refreshCatalogue(unrequested: false, why: "Settings → Plugins opened") }
        }
        sourcesPaneOpened()
    }

    /// **Check now**.
    public func checkCatalogueNow() {
        guard settings.readsOfficialCatalogue else { return }
        Task { await refreshCatalogue(unrequested: false, why: "Check now") }
    }

    /// **Official catalogue**, on or off. Off, uDeck makes no request to the
    /// official repository — its catalogue, **Install from a link…**, its
    /// forks, the lines its copies came from; the sources the operator added
    /// are read until they are removed, and installed plugins keep running.
    /// The minute's clock stops only when no source is left to read.
    public func setOfficialCatalogue(_ on: Bool) {
        var changed = settings
        changed.officialCatalogue = on
        update(settings: changed)
        if on {
            updateClock()
            Task { await refreshCatalogue(unrequested: false, why: "the official catalogue was switched on") }
        } else {
            launchRefresh?.cancel()
            launchRefresh = nil
            updateClock()
        }
    }

    func refreshCatalogue(unrequested: Bool, why: String) async {
        guard settings.readsOfficialCatalogue, !catalogueRefreshing else { return }
        catalogueRefreshing = true
        await inTurn { [self] in
            defer { catalogueRefreshing = false }
            guard settings.readsOfficialCatalogue else { return }
            await readOfficialCatalogue(unrequested: unrequested, why: why)
        }
    }

    /// One read of the official catalogue, in its turn (`inTurn`).
    private func readOfficialCatalogue(unrequested: Bool, why: String) async {
        DeckLog.plugins.info("reading the official catalogue: \(why, privacy: .public)")
        let refresher = CatalogueRefresher(provider: officialReader, store: catalogueStore, limits: limits)
        // The heads the branches and pull requests copies came from were
        // last heard at are kept with the installed commits: what they offer
        // is read again from the cache.
        let outcome = await refresher.refresh(unrequested: unrequested, language: strings.language.rawValue,
                                              installedCommits: installed.commits.union(followed.heads))
        DeckLog.plugins.info("the official catalogue: \(String(describing: outcome), privacy: .public)")
        if case .failed(.officialRepositoryChanged) = outcome {
            // The official address is another repository's now — or was, and
            // no describe has answered since: the next read asks its number
            // again before anything else (`CatalogueRefresher`), and nothing
            // else is asked of it meanwhile (`readsOfficialRepository`).
            DeckLog.plugins.error("the official repository answered another number than \(String(describing: self.endpoints.repositoryID), privacy: .public): not read, and nothing updates by itself")
        }
        catalogueState = catalogueStore.state()
        // In the same read, after the catalogue: what became of the branch
        // or the pull request each copy installed from one came from — or,
        // when the read did not get that far, that none of them was asked
        // about, and since when.
        switch outcome {
        case .refreshed(let head, _):
            await followLines(head: head, unrequested: unrequested)
        case .leftForLater, .failed:
            await followLines(head: catalogueState.head, unrequested: unrequested, asking: false)
        }
        await reloadCatalogue()
        reverify()
        // A read that succeeded: every update waiting is asked about anew — one
        // that failed since the last read too — once the hashing just started
        // is applied, and not on a standing from before the read.
        var succeeded = false
        if case .refreshed = outcome { succeeded = true }
        autoUpdates.read(InstalledPlugins.officialSource, succeeded: succeeded, hashing: reverifications)
    }

    /// What became of the branch or the pull request each copy installed from
    /// one came from — its head, merged, closed, gone — asked of the official
    /// repository, or of the fork a fork's branch is in, one request each,
    /// after a read of the catalogue that succeeded (`RefFollower`), with the
    /// listing of a head that moved and one comparison when the copy changed
    /// there: never for a copy whose tree the new head has, which is what was
    /// merged (`Adoption`), and, in
    /// a read nobody asked for, not while the reserve for the operator is all
    /// that is left — those say since when they were not checked. `asking`
    /// false: the read of the catalogue was left for later or failed, nothing
    /// is asked, and every one of them says since when, `head` being the
    /// catalogue's head as it was before.
    func followLines(head: String?, unrequested: Bool, asking: Bool = true) async {
        let installed = self.installed
        let fromLines = installed.plugins.values.contains {
            !$0.isOfficialDefault && ($0.ref.pullRequestNumber != nil || $0.ref.kind == PluginRef.branchKind)
        }
        guard fromLines || followed != FollowedRefs() else { return }
        let store = catalogueStore
        let headTrees = await Self.trees(at: head, in: store)
        let follower = RefFollower(provider: provider, store: store, limits: limits, language: strings.language.rawValue)
        let outcome = await follower.follow(installed, headTrees: headTrees, unrequested: unrequested, asking: asking)
        // What an install, an adoption or a removal said while it asked stands
        // for that copy (`RefFollower.Outcome.merged`).
        let kept = outcome.merged(into: followed, askedAbout: installed, installed: self.installed)
        followed = kept
        if kept != outcome.followed { saveFollowed() }
        DeckLog.plugins.info("branches and pull requests asked about: \(outcome.asked.joined(separator: ", "), privacy: .public); left as they were: \(outcome.leftAsTheyWere.joined(separator: ", "), privacy: .public)")
        catalogueState.rateLimit = limits.current
        persistRateLimit()
    }

    /// The tree of each plugin's folder at `commit`, from the cached listing,
    /// away from the main thread — none while no head was read.
    nonisolated static func trees(at commit: String?, in store: CatalogueStore) async -> [String: String] {
        commit.flatMap { store.listing($0) }.map { $0.plugins.mapValues(\.tree) } ?? [:]
    }

    func saveFollowed() {
        do {
            try catalogueStore.save(followed: followed)
        } catch {
            DeckLog.plugins.error("what was heard of branches and pull requests could not be kept: \(String(describing: error), privacy: .public)")
        }
    }

    /// The catalogue as the cache holds it now, read away from the main thread
    /// (`Catalogue.read`). Two reads can overlap — the one at launch and a
    /// refresh's — and only the one asked for last is shown, whichever ends
    /// first.
    func reloadCatalogue() async {
        catalogueReads += 1
        let read = catalogueReads
        let store = catalogueStore
        let language = strings.language.rawValue
        let loaded = await Catalogue.read(from: store, address: provider.address, udeck: udeck, language: language)
        // With it, the heads the branches and pull requests copies came from
        // moved to: what each of those rows offers (`RefOffer`).
        let heads = await RefHead.read(from: store, followed: followed, installed: installed,
                                       defaultBranch: loaded?.branch ?? catalogueState.defaultBranch, udeck: udeck,
                                       language: language)
        guard read == catalogueReads else { return }
        catalogue = loaded
        if heads != refHeads { refHeads = heads }
        catalogueWasRead = true
    }

    // MARK: - What the rows show

    /// Where a plugin folder stands, as of the last read.
    public func standing(of id: String) -> PluginStanding {
        standings[id] ?? .folderOfYourOwn
    }

    /// Whether a window's plugin is here to run — **Reinstall** offered while
    /// its copy's source can be read (`canRead`).
    public func presence(of id: PluginIdentifier) -> PluginPresence {
        PluginPresence.of(id, plugins: plugins, installed: installed,
                          readsCatalogue: installed[id].map { canRead($0.source) } ?? false)
    }

    /// What the repository has for an installed plugin — its own source's
    /// head, never another source's — or nil when uDeck did not install it or
    /// there is no catalogue to compare with.
    public func updateOffer(for id: String) -> UpdateOffer? {
        guard let record = installed.plugins[id], let catalogue = catalogue(of: record.source) else { return nil }
        return UpdateOffer.offered(record, head: catalogue.entry(id), source: record.source)
    }

    /// A catalogue row's state, in the catalogue of `source`.
    public func rowState(for entry: CatalogueEntry, in source: String = InstalledPlugins.officialSource) -> CatalogueRowState {
        CatalogueRowState.of(entry, record: installed.plugins[entry.id], folderExists: folderExists(entry.id),
                             source: source, official: catalogueAddress)
    }

    /// How many updates are waiting: the verified copies' — and those of
    /// copies of code nobody verified (`UnverifiedRow.waiting`): the verified
    /// version offered once a pull request was merged as something else, and
    /// a newer version or other files along a branch or a pull request.
    public var updatesWaiting: Int {
        // Only what the rows offer: a copy whose source cannot be read now is
        // offered nothing (`canRead`).
        installed.plugins.filter { id, record in
            canRead(record.source) && folderExists(id)
                && (updateOffer(for: id)?.isWaiting == true || unverifiedRow(of: id)?.waiting == true)
        }.count
    }

    /// What the rows of `id`'s copy say and offer when it is code nobody
    /// verified (`UnverifiedRow`): what became of its pull request, what its
    /// branch or pull request has for it now, the verified copy that can take
    /// its place — nil for any other copy.
    public func unverifiedRow(of id: String) -> UnverifiedRow? {
        UnverifiedRow.of(id, record: installed.plugins[id], followed: followed, head: refHeads[id],
                         defaultBranch: catalogue?.branch ?? catalogueState.defaultBranch,
                         readsCatalogue: readsOfficialRepository, verified: catalogue?.entry(id))
    }

    /// The default branch's head as the catalogue was read at: what a copy
    /// put back is recorded as when its folder is what the head has
    /// (`ShownPlace.recordedAs`).
    private var defaultHead: Adoption.DefaultBranch? {
        catalogue.map(Adoption.DefaultBranch.init)
    }

    /// What a window of `id` says beside **Reinstall** of what it puts back,
    /// when that is code nobody verified (`InstalledRecord.reinstallSays`).
    public func reinstallSays(_ id: PluginIdentifier) -> Phrase? {
        installed.plugins[id.rawValue]?.reinstallSays(headTree: catalogue?.entry(id.rawValue)?.listing.tree,
                                                      official: catalogueAddress)
    }

    /// Whether the version the catalogue's head has for `id` asks for other
    /// permissions than the copy on disk (`AutoUpdate.asksDifferently`) —
    /// false when either cannot be read. Such an update never happens by
    /// itself, and its row says why.
    public func updateAsksDifferently(_ id: String) -> Bool {
        guard let now = installedManifest(id)?.permissions.capabilities,
              let head = headEntry(id)?.manifest?.permissions.capabilities else { return false }
        return AutoUpdate.asksDifferently(now, head)
    }

    /// What the head of the source `id`'s copy is of has for it.
    func headEntry(_ id: String) -> CatalogueEntry? {
        catalogue(of: installed.plugins[id]?.source ?? InstalledPlugins.officialSource)?.entry(id)
    }

    /// The manifest of the copy at `plugins/<id>`, as the folder was last
    /// read — none for a linked folder, which no repository updates.
    func installedManifest(_ id: String) -> PluginManifest? {
        plugins.first { $0.folderName == id && !$0.isLinked }?.manifest
    }

    /// Whether something sits at `plugins/<id>` — asked the way the swap
    /// will find it, so a folder spelt `Uptime` on a volume that ignores case
    /// is offered **Replace…** rather than an **Install** that would take it.
    ///
    /// The disk answers, and SwiftUI does not watch the disk: `standings` is
    /// read too, so that a view asking this is drawn again when a folder comes
    /// or goes — every reading of the plugins folder that finds one gone, or
    /// a new one, writes it. Without it the catalogue row of a copy whose
    /// folder was taken away went on saying what it said with the folder there
    /// (R3's lab, .build/e2e/kept/20261012-001204Z, plugins.install-from-a-branch,
    /// 04-at-the-end.png), while the plugin's own row said **Missing**.
    public func folderExists(_ id: String) -> Bool {
        _ = standings[id]
        return PluginInstaller.folderIsTaken(id, in: paths)
    }

    /// Whether a window of `id` says **Unverified** in its header: a branch's
    /// or a pull request's copy (`PluginStanding.cardSaysUnverified`).
    public func cardSaysUnverified(_ id: PluginIdentifier) -> Bool {
        PluginStanding.cardSaysUnverified(standings[id.rawValue], record: installed.plugins[id.rawValue],
                                          linked: plugin(withID: id)?.isLinked ?? false)
    }

    /// What the card asking about `id` says of where its code comes from —
    /// for a decision held to its tree; nil for one held to its version
    /// (`ConsentSource`).
    public func consentSource(for id: PluginIdentifier) -> Phrase? {
        ConsentSource.of(installed.plugins[id.rawValue], basis: consentBasis(of: id),
                         recordsReadable: installedProblem == nil,
                         changedHere: standings[id.rawValue] == .modifiedLocally)
    }

    /// The page where a plugin's folder is read, at a commit, in the
    /// repository of `source`.
    public func folderPage(_ id: String, commit: String, source: String = InstalledPlugins.officialSource) -> URL? {
        let path = "\(CommitListing.pluginsFolder)/\(id)"
        guard source != InstalledPlugins.officialSource else { return provider.folderPage(path, commit: commit) }
        return sourceProvider(source)?.folderPage(path, commit: commit)
    }

    /// *What changed*: the installed commit against the head of its own
    /// source.
    public func whatChanged(_ id: String) -> URL? {
        guard let record = installed.plugins[id], let head = catalogue(of: record.source)?.commit else { return nil }
        guard record.source != InstalledPlugins.officialSource else {
            return provider.comparePage(from: record.commit, to: head)
        }
        return sourceProvider(record.source)?.comparePage(from: record.commit, to: head)
    }

    /// *What changed* along the line a copy of code nobody verified came
    /// from: the commit installed against the head its branch or pull request
    /// moved to, in that line's repository.
    public func whatChangedAlongItsLine(_ id: String) -> URL? {
        guard let record = installed.plugins[id], let head = unverifiedRow(of: id)?.lineOffer?.head else { return nil }
        return provider(for: record.origin)?.comparePage(from: record.commit, to: head)
    }

    // MARK: - Verification

    /// Recomputes where every plugin folder stands, and every record's
    /// verification, from what its folder hashes to now — and writes a record
    /// back only when it changed (`Reverification`). Never trusted from the
    /// file: nothing, least of all a consent decision, is decided on it.
    ///
    /// The folders are hashed away from the main thread, and what that comes
    /// to is applied when it is done — unless the plugins folder was read, or
    /// the records loaded, again meanwhile: then the later hashing applies.
    /// Until the catalogue has been read, no verification is written.
    func reverify() {
        reverifications += 1
        let asked = reverifications
        let plugins = self.plugins
        let folders = Reverification.folders(of: plugins, installed: installed, recordsReadable: installedProblem == nil)
        // The hashing before this one would not be applied: it stops at its
        // next folder rather than hashing every installed plugin for nothing.
        reverifyTask?.cancel()
        reverifyTask = Task {
            guard let trees = await Reverification.trees(of: folders) else { return }
            guard asked == reverifications else { return }
            // A copy of a branch or a pull request that is what was merged —
            // at the head, or as its pull request was merged — is recorded as
            // the default branch's, Verified, with nothing downloaded and
            // nothing swapped (`Adoption`); never while an install, update or
            // removal runs — the next hashing after it asks again — nor before
            // the catalogue is read.
            var records = installed
            var adopted: [String: String] = [:]
            if busyPlugin == nil, installedProblem == nil, catalogueWasRead, let catalogue {
                (records, adopted) = Adoption.apply(installed, trees: trees, branch: Adoption.DefaultBranch(catalogue),
                                                    followed: followed, now: Date())
            }
            var heads: [String: Reverification.Head] = [
                InstalledPlugins.officialSource: catalogueWasRead ? .read(catalogue?.commit) : .notReadYet,
            ]
            for source in sources where sourceCataloguesRead.contains(source.id) {
                heads[source.id] = .read(sourceCatalogues[source.id]?.commit)
            }
            let found = Reverification.of(plugins, installed: records, trees: trees, heads: heads, now: Date())
            if found.standings != standings { standings = found.standings }
            // What code held to its tree runs on from now (`requiredTree`):
            // its loop starts or stops only when its tree is another.
            var hashed = treesOnDisk
            hashed.hashed(trees)
            if hashed != treesOnDisk {
                let moved = hashed.trees != treesOnDisk.trees
                treesOnDisk = hashed
                if moved { restartPolling() }
            }
            if installedProblem == nil, let written = found.records ?? (adopted.isEmpty ? nil : records) {
                installed = written
                save(JSONFileStore<InstalledPlugins>(url: paths.installedFile), installed, named: "installed plugins")
            }
            if !adopted.isEmpty {
                for (id, commit) in adopted.sorted(by: { $0.key < $1.key }) {
                    DeckLog.plugins.info("\(id, privacy: .public) is what was merged, at \(commit, privacy: .public): recorded as the default branch's, verified; nothing was downloaded")
                    followed.forget(id)
                }
                saveFollowed()
                // Held to its version now, not its tree: its loop is planned
                // on that.
                restartPolling()
            }
            // After a read of the catalogue: on standings hashed since.
            autoUpdates.hashed(asked)
            updateVerifiedPlugins()
        }
    }

    // MARK: - Quieting

    /// Stops scheduling a plugin's polls and refuses its card actions, then
    /// quiets it by `PluginQuiet.quiet` — what to wait for, what to end and
    /// what to answer are decided there, in UDeckCore, where they are tested —
    /// so nothing of it runs across a swap or a removal. Answers whether
    /// nothing of the plugin is running; false, and its folder is not touched.
    ///
    /// Whether anything runs is asked of `pluginRuns`, which counts a card
    /// action until its whole process group has ended (`ActionProcesses`).
    func quiet(_ id: PluginIdentifier) async -> Bool {
        pluginRuns.quiet(id.rawValue)
        stopPolling(id)
        let plugin = id.rawValue
        let settled = await PluginQuiet.quiet(
            plugin,
            pollTimeout: self.plugin(withID: id)?.manifest?.timeout,
            actions: actionProcesses,
            isRunning: { [weak self] in await MainActor.run { self?.pluginRuns.isRunning(plugin) ?? false } }
        )
        if !settled {
            DeckLog.plugins.error("\(plugin, privacy: .public) is still running; its folder is left as it was")
        }
        return settled
    }

    func resume(_ id: PluginIdentifier) {
        pluginRuns.resume(id.rawValue)
        restartPolling()
    }

    /// `quiet`, for an update nobody pressed: nothing more of the plugin
    /// starts from here on, and a card action that is running is not ended
    /// for it — the answer is false then, the folder is left as it was, and
    /// the update is asked about again on the minute's tick. False too when
    /// **Update verified plugins by themselves** or **Official catalogue** was
    /// switched off while it downloaded: then it is not made at all.
    func quietUnlessActing(_ id: PluginIdentifier, source: String) async -> Bool {
        guard switchedOnStill(id, source: source) else { return false }
        pluginRuns.quiet(id.rawValue)
        guard !actionProcesses.isRunning(id.rawValue) else {
            DeckLog.plugins.info("\(id.rawValue, privacy: .public) has a card action running; it is not ended for an update by itself")
            return false
        }
        return await quiet(id) && switchedOnStill(id, source: source)
    }

    private func switchedOnStill(_ id: PluginIdentifier, source: String) -> Bool {
        guard updatesByThemselves(source) else {
            DeckLog.plugins.info("\(id.rawValue, privacy: .public) does not update itself: switched off while it downloaded")
            return false
        }
        return true
    }

    /// Whether copies of `source` update themselves now: **Update verified
    /// plugins by themselves** on, and the source readable — the official
    /// one's under **Official catalogue**, and not while its address belongs
    /// to another repository (`CatalogueError.officialRepositoryChanged`); a
    /// source of one's own's while it is listed, whatever **Official
    /// catalogue** says. Which copies do is each copy's own (`AutoUpdate`).
    func updatesByThemselves(_ source: String) -> Bool {
        AutoUpdate.switchedOn(source, settings: settings, sources: sources,
                              officialChanged: catalogueState.lastError == .officialRepositoryChanged)
    }

    // MARK: - Updating by themselves

    /// Verified plugins whose update is waiting, updated by themselves, one at
    /// a time, through the update **Update** makes — whatever `AutoUpdate`
    /// says of each, decided there and tested there. Asked once the folders
    /// are hashed after each successful read of the catalogue, after each
    /// install, update or removal ends, and on the minute's tick while one
    /// waits; at any other time it does nothing.
    ///
    /// Source by source (`AutoUpdateSchedules`): the official one first, then
    /// each source of one's own as `sources.json` lists them, each only after a
    /// read of its own that succeeded, and each copy only among its own
    /// source's — whatever any switch but its own source's says
    /// (`updatesByThemselves`).
    func updateVerifiedPlugins() {
        let asking = autoUpdates.asking(in: [InstalledPlugins.officialSource] + sources.map(\.id))
        guard !asking.isEmpty else { return }
        for source in asking {
            let switchedOn = updatesByThemselves(source)
            guard switchedOn, installedProblem == nil, catalogue(of: source) != nil else {
                autoUpdates.asked(source, started: false, waits: false)
                continue
            }
            var waits = false
            for id in installed.plugins.keys.sorted() where installed.plugins[id]?.source == source {
                switch autoUpdateVerdict(for: id, switchedOn: switchedOn) {
                case .update(let version):
                    DeckLog.plugins.info("\(id, privacy: .public) updates itself to \(version, privacy: .public)")
                    if updateByItself(id) {
                        autoUpdates.asked(source, started: true, waits: waits)
                        return
                    }
                    DeckLog.plugins.info("\(id, privacy: .public) did not update itself: its place is not what was asked about")
                case .later(let wait):
                    waits = true
                    DeckLog.plugins.info("\(id, privacy: .public) updates itself later: \(String(describing: wait), privacy: .public)")
                case .not(.nothingWaiting):
                    break
                case .not(let reason):
                    DeckLog.plugins.info("\(id, privacy: .public) does not update itself: \(String(describing: reason), privacy: .public)")
                }
            }
            autoUpdates.asked(source, started: false, waits: waits)
        }
    }

    /// What `AutoUpdate` says of `id` now. Its place is hashed — what
    /// replacing it would do, by the rule every button warns by — only for a
    /// plugin whose update could otherwise go ahead.
    func autoUpdateVerdict(for id: String, switchedOn: Bool) -> AutoUpdate.Verdict {
        guard let record = installed.plugins[id] else { return .not(.nothingWaiting) }
        let offer = updateOffer(for: id)
        let standing = standings[id]
        let asked = offer?.isWaiting == true && standing == .verified && !record.pinned
        let place = asked ? ShownPlace.Place.now(id, in: paths, record: record, bringing: .nothing).fate : .nothing
        let plugin = AutoUpdate.Plugin(
            record: record, offer: offer, standing: standing,
            asksNow: installedManifest(id)?.permissions.capabilities,
            asksAtHead: headEntry(id)?.manifest?.permissions.capabilities,
            place: place, actionRunning: actionProcesses.isRunning(id),
            failedSinceTheLastRead: autoUpdates.failures[id] != nil
        )
        return AutoUpdate.verdict(plugin, switchedOn: switchedOn, busy: busyPlugin != nil)
    }

    /// Starts `id`'s update by itself: the step **Update** takes, pressed with
    /// nothing shown — and when that step would warn first, nothing here
    /// answers it. Answers whether it started.
    private func updateByItself(_ id: String) -> Bool {
        let source = installed.plugins[id]?.source ?? InstalledPlugins.officialSource
        guard case .install(let operation, let commit, let folder, let version, let origin)
                = ShownPlace.update(id, catalogue: catalogue(of: source), in: paths, installed: installed, shown: nil,
                                    official: catalogueAddress) else {
            return false
        }
        run(operation, id: id, commit: commit, folder: folder, version: version, from: origin, automatic: true)
        return busyPlugin == id
    }

    /// **Update verified plugins by themselves**, on or off. On, it counts
    /// from the next read of the catalogue.
    public func setAutoUpdateVerified(_ on: Bool) {
        var changed = settings
        changed.autoUpdateVerified = on
        update(settings: changed)
    }

    // MARK: - Install, update, earlier versions

    // Every button below takes what its warning showed (`shown`, nil for a
    // press nothing was shown before) and passes it, with what the model has,
    // to `ShownPlace`, which decides the rest — the copy the button brings,
    // what is there now, whether the warning holds — and is tested there; the
    // button does what it says (`act`). The first press of each is the same
    // call with nothing shown: the warning, or the work at once.

    /// **Install** — or **Replace…** over a folder of the operator's own or a
    /// link — at the commit the catalogue was built from, whatever the
    /// repository has done since: what the operator saw is what they get.
    ///
    /// `source` is the catalogue whose row it is: the official one, or a
    /// source of one's own's — there, over a copy from elsewhere, **Install
    /// from here…**, which names both first.
    @discardableResult
    public func install(_ id: String, from source: String = InstalledPlugins.officialSource,
                        shown: ShownPlace.Place? = nil) -> ShownPlace.Press {
        act(ShownPlace.install(id, catalogue: catalogue(of: source), in: paths, installed: installed, shown: shown,
                               official: catalogueAddress), id: id)
    }

    /// **Update**, or **Switch to** a version the repository went back to: the
    /// plugin at the head of `source` — the copy's own source for the update a
    /// row offers it, the official one for **Switch to verified**.
    @discardableResult
    public func update(_ id: String, from source: String = InstalledPlugins.officialSource,
                       shown: ShownPlace.Place? = nil) -> ShownPlace.Press {
        act(ShownPlace.update(id, catalogue: catalogue(of: source), in: paths, installed: installed, shown: shown,
                              official: catalogueAddress), id: id)
    }

    /// **Reinstall**: what the record says was installed, put back — over a
    /// copy changed on disk, which goes to the Trash, or where it has gone.
    /// A download, so not while the copy's source cannot be read — the
    /// official one's with **Official catalogue** off, a source of one's
    /// own's once it is no longer added. Its warning names the copy as it
    /// will be recorded: a pull request's copy the head has comes back
    /// verified (`ShownPlace.recordedAs`).
    @discardableResult
    public func reinstall(_ id: String, shown: ShownPlace.Place? = nil) -> ShownPlace.Press {
        guard let record = installed.plugins[id], canRead(record.source) else { return .goAhead }
        return act(ShownPlace.reinstall(id, in: paths, installed: installed, shown: shown, head: defaultHead,
                                        source: catalogueAddress, sources: sources), id: id)
    }

    /// **Back to** the copy this one replaced, from where it came — named as
    /// **Reinstall** names its copy — and from the source it is a copy of
    /// (`PreviousCopy.source`): nothing for a source no longer added.
    @discardableResult
    public func backToPrevious(_ id: String, shown: ShownPlace.Place? = nil) -> ShownPlace.Press {
        act(ShownPlace.backToPrevious(id, source: catalogueAddress, in: paths, installed: installed, shown: shown,
                                      head: defaultHead, sources: sources), id: id)
    }

    /// The source **Back to** of `id` takes its copy from, when it offers one
    /// and that source can be read now — nil otherwise.
    public func backToSource(_ id: String) -> String? {
        guard let record = installed.plugins[id], let previous = record.previous,
              case .source(let origin) = previous.source(record: record, official: catalogueAddress, sources: sources),
              canRead(origin.source) else { return nil }
        return origin.source
    }

    /// **Update** on a copy of code nobody verified: the folder at the head
    /// its branch or pull request moved to (`RefOffer`), from that line —
    /// pressed, never by itself; the card asks about it before it runs. A
    /// download, so not while the official repository cannot be read
    /// (`readsOfficialRepository`).
    @discardableResult
    public func updateAlongItsLine(_ id: String, shown: ShownPlace.Place? = nil) -> ShownPlace.Press {
        guard readsOfficialRepository, unverifiedRow(of: id)?.lineOffer != nil else { return .goAhead }
        return act(ShownPlace.alongTheLine(id, head: refHeads[id], in: paths, installed: installed, shown: shown), id: id)
    }

    /// An earlier version, chosen from the default branch's history: installed
    /// and marked pinned.
    ///
    /// From the history of the source the copy is of: the official one's, or
    /// a source of one's own's — its own default branch, its own copies.
    @discardableResult
    public func installEarlier(_ id: String, line: PluginHistory.Line, shown: ShownPlace.Place? = nil) -> ShownPlace.Press {
        let source = installed.plugins[id]?.source ?? InstalledPlugins.officialSource
        // Only a version the history of the copy's own source lists: a list
        // read while the copy was of another source installs nothing.
        guard EarlierVersions.installs(line, from: readHistory(id), readOf: historySources[id], copyOf: source) else {
            return .goAhead
        }
        guard source != InstalledPlugins.officialSource else {
            return act(ShownPlace.earlier(id, line: line, source: catalogueAddress,
                                          branch: catalogueState.defaultBranch ?? catalogue?.branch,
                                          in: paths, installed: installed, shown: shown), id: id)
        }
        guard let own = self.source(source) else { return .goAhead }
        return act(ShownPlace.earlier(id, line: line, source: own.address,
                                      branch: sourceStates[source]?.defaultBranch ?? sourceCatalogues[source]?.branch,
                                      in: paths, installed: installed, shown: shown, sourceID: source), id: id)
    }

    /// Does what `step` says — every argument it carries is `ShownPlace`'s —
    /// and answers what the press came to.
    private func act(_ step: ShownPlace.Step, id: String) -> ShownPlace.Press {
        switch step {
        case .nothing:
            return .goAhead
        case .ask(let now):
            return .ask(now)
        case .install(let operation, let commit, let folder, let version, let origin):
            run(operation, id: id, commit: commit, folder: folder, version: version, from: origin)
            return .goAhead
        case .atCommit(let operation, let commit, let version, let origin):
            runAtCommit(operation, id: id, commit: commit, version: version, from: origin)
            return .goAhead
        case .remove:
            // Removal has its own call; no step but `remove`'s answers this.
            return .goAhead
        }
    }

    // MARK: - Install from a link…

    /// **Look up** on a link pasted into **Install from a link…**: read for
    /// what it names (`RepositoryLink`) — a refusal is said at once, without a
    /// request — and then asked of GitHub (`RefResolver`): through the
    /// official repository, one request for a pull request or a branch's head;
    /// of a fork, one for whether it is a fork of the official repository and
    /// one for its branch's head; then one for the listing unless the cache
    /// has it, and the manifests of the plugins there that differ from the
    /// catalogue's head. Off, **Official
    /// catalogue** governs this too: uDeck makes no request to the official
    /// repository or its forks, and says why nothing is looked up — as it
    /// does while the official address belongs to another repository
    /// (`readsOfficialRepository`).
    public func lookUpLink(_ text: String) {
        linkLookups += 1
        let asked = linkLookups
        guard settings.readsOfficialCatalogue else {
            linkLookup = .refused(.linkOff)
            return
        }
        guard readsOfficialRepository else {
            linkLookup = .refused(.catalogueOfficialRepositoryChanged)
            return
        }
        let official = catalogueAddress
        // A branch, the page or a pull request of a source of one's own: its
        // branches are not installed from yet — only its default branch,
        // under Your sources — and nothing is asked.
        if RepositoryLink.namesASource(text, official: official, sources: sources) {
            linkLookup = .refused(.sourceBranchNotYet)
            return
        }
        let link: RepositoryLink
        switch RepositoryLink.read(text, official: official) {
        case .failure(let refusal):
            linkLookup = .refused(.linkRefused(refusal, official: official.description))
            return
        case .success(let read):
            link = read
        }
        linkLookup = .reading
        let resolver = RefResolver(provider: officialReader, store: catalogueStore, limits: limits)
        let store = catalogueStore
        let head = catalogue?.commit
        let branch = catalogueState.defaultBranch ?? catalogue?.branch
        let language = strings.language.rawValue
        let udeck = self.udeck
        DeckLog.plugins.info("looking up a link: \(String(describing: link), privacy: .public)")
        Task {
            let came: LinkLookup
            do {
                let listing = await Self.listing(head, in: store)
                switch try await resolver.resolve(link, defaultBranch: branch, head: listing, udeck: udeck,
                                                  language: language) {
                case .catalogue(let plugin): came = .catalogue(plugin: plugin)
                case .resolved(let resolution): came = .resolved(resolution)
                }
            } catch {
                came = LinkRefusal.phrase(error, official: official).map(LinkLookup.refused) ?? .failed(OperationProblem(error))
            }
            DeckLog.plugins.info("the link came to \(came.logged, privacy: .public)")
            catalogueState.rateLimit = limits.current
            persistRateLimit()
            guard asked == linkLookups else { return }
            linkLookup = came
        }
    }

    /// The listing of the catalogue's head, from the cache, away from the
    /// main thread — what a link's plugins are compared with.
    nonisolated static func listing(_ commit: String?, in store: CatalogueStore) async -> CommitListing? {
        commit.flatMap { store.listing($0) }
    }

    /// The sheet closed: what it said goes, and an answer still on its way
    /// is not shown.
    public func closeLinkLookup() {
        linkLookups += 1
        linkLookup = nil
    }

    /// **Install** on a plugin the link listed: its folder at the commit the
    /// link was read at, from that branch or pull request — over a copy from
    /// another line of history, after the warning that names both
    /// (`ShownPlace.installFromLink`).
    @discardableResult
    public func installFromLink(_ id: String, shown: ShownPlace.Place? = nil) -> ShownPlace.Press {
        guard readsOfficialRepository, case .resolved(let resolution)? = linkLookup else { return .goAhead }
        return act(ShownPlace.installFromLink(id, resolution: resolution, in: paths, installed: installed, shown: shown,
                                              source: catalogueAddress), id: id)
    }

    /// Reads a plugin's earlier versions from its folder's history — the
    /// history of the default branch of the source its copy is of, through
    /// that source's own provider.
    public func readEarlierVersions(_ id: String) {
        let source = installed.plugins[id]?.source ?? InstalledPlugins.officialSource
        guard canRead(source), let head = catalogue(of: source)?.commit,
              let branch = catalogueState(of: source).defaultBranch ?? catalogue(of: source)?.branch else { return }
        let reader: PluginHistoryReader
        if source == InstalledPlugins.officialSource {
            reader = PluginHistoryReader(provider: provider, store: catalogueStore)
        } else if let own = sourceProvider(source) {
            reader = PluginHistoryReader(provider: own, store: CatalogueStore(paths: paths, source: source))
        } else {
            return
        }
        if EarlierVersions.stands(readHistory(id), readOf: historySources[id], copyOf: source, head: head) { return }
        histories[id] = .reading
        historySources[id] = source
        Task {
            let came: HistoryLoad
            do {
                came = .read(try await reader.read(id, branch: branch, head: head))
            } catch {
                came = .failed(OperationProblem(error))
            }
            // An answer for a copy that is of another source since is not
            // shown as its history.
            if historySources[id] == source { histories[id] = came }
            catalogueState.rateLimit = limits.current
            persistRateLimit()
        }
    }

    /// The history last read for `id`, when it was read.
    private func readHistory(_ id: String) -> PluginHistory? {
        if case .read(let history)? = histories[id] { history } else { nil }
    }

    /// An operation at a commit that is not the head: its listing from the
    /// cache, or one request for it — to the repository the copy comes from.
    private func runAtCommit(_ operation: InstallRequest.Operation, id: String, commit: String, version: String,
                             from origin: PluginOrigin) {
        // Nothing is asked of a source that cannot be read — the official one
        // with **Official catalogue** off, a source no longer added —
        // whichever button was pressed, and whatever screen it was on.
        let origin = takenNow(origin)
        guard canRead(origin.source), busyPlugin == nil else { return }
        guard let provider = client(for: origin) else {
            operationProblems[id] = .catalogue(.notFound)
            return
        }
        busyPlugin = id
        operationProblems[id] = nil
        let refresher = CatalogueRefresher(provider: provider, store: CatalogueStore(paths: paths, source: origin.source),
                                           limits: limits)
        Task {
            do {
                let listing = try await refresher.listing(commit)
                guard let folder = listing.plugins[id] else {
                    throw InstallError.refused([.noManifest(path: "plugins/\(id)/manifest.json")])
                }
                busyPlugin = nil
                run(operation, id: id, commit: commit, folder: folder, version: version, from: origin)
            } catch ProviderError.notFound {
                // uDeck keeps no copy of what a rewritten history took away:
                // the commit is gone, and that is what is said.
                operationProblems[id] = .commitGone(String(commit.prefix(7)))
                busyPlugin = nil
            } catch {
                operationProblems[id] = OperationProblem(error)
                busyPlugin = nil
            }
            catalogueState.rateLimit = limits.current
            persistRateLimit()
        }
    }

    /// One install, update, reinstall or earlier version of `id`, at `commit`.
    /// The manifest the catalogue row was checked by is read again from the
    /// blob store — off the main thread (`CatalogueStore.manifest(of:)`) — and
    /// every rule checked against it before a file is requested.
    ///
    /// `automatic` is an update nobody pressed (`updateVerifiedPlugins`): its
    /// record says so, it ends no card action (`quietUnlessActing`), and when
    /// it fails its row says it was one.
    ///
    /// `origin` is where the copy comes from, as the button's step says it
    /// (`ShownPlace.Step`) — the repository the files are fetched from and
    /// the ref the record keeps — and nothing here assumes it: a copy from a
    /// pull request put back is recorded as one, and stays unverified.
    private func run(
        _ operation: InstallRequest.Operation,
        id: String,
        commit: String,
        folder: PluginListing,
        version: String,
        from origin: PluginOrigin,
        automatic: Bool = false
    ) {
        let origin = takenNow(origin)
        guard canRead(origin.source), busyPlugin == nil,
              let identifier = PluginIdentifier(rawValue: id) else { return }
        guard installedProblem == nil else {
            operationProblems[id] = .recordsBroken(installedProblem ?? "")
            return
        }
        // Taken from where it came, and only from a repository a copy of its
        // line may be taken from: the installer refuses the rest too, before
        // a file is asked for (`PluginInstaller.stage`).
        guard client(for: origin) != nil else {
            operationProblems[id] = .catalogue(.notFound)
            return
        }
        busyPlugin = id
        operationProblems[id] = nil
        autoUpdates.began(id)
        // The copy's own source's head, which it is verified — or recorded —
        // against, and the source its record names.
        let head = catalogue(of: origin.source)
        let request = InstallRequest(
            operation: operation, id: identifier, from: origin, sourceRepository: sourceRepository(of: origin.source),
            commit: commit, folder: folder, version: version,
            headCommit: head?.commit, headTree: head?.entry(id)?.listing.tree,
            defaultBranch: head?.branch ?? catalogueState(of: origin.source).defaultBranch, automatic: automatic
        )
        // What **Look up** heard of the pull request or the branch this copy
        // comes from, if that is where it comes from, and when: kept with what
        // is heard of it later, so that its row says at once whether it was
        // merged or closed — and nothing a read heard of the branch before
        // Look up, while what a read heard after it stands.
        var heard: PullRequest?
        var branchHead: String?
        var heardAt: Date?
        if case .resolved(let resolution)? = linkLookup, resolution.origin == origin, resolution.commit == commit {
            heard = resolution.pullRequest
            branchHead = resolution.branchHead
            heardAt = resolution.heardAt
        }
        let installer = self.installer
        let store = catalogueStore
        // The copy the permission decision was made for, read before the swap.
        let before = copyForTheDecision(id)
        Task {
            defer {
                busyPlugin = nil
                catalogueState.rateLimit = limits.current
                persistRateLimit()
                // An update by itself that waited on this one goes now.
                updateVerifiedPlugins()
            }
            do {
                DeckLog.plugins.info("\(operation.rawValue, privacy: .public) \(id, privacy: .public) at \(commit, privacy: .public)\(automatic ? " by itself" : "", privacy: .public)")
                let manifest = await store.manifest(of: folder)
                let staged = try await installer.stage(request, manifest: manifest)
                defer { resume(identifier) }
                let source = origin.source
                let record = try await installer.commit(staged, once: { @Sendable in
                    automatic ? await self.quietUnlessActing(identifier, source: source) : await self.quiet(identifier)
                })
                DeckLog.plugins.info("\(id, privacy: .public) \(record.version, privacy: .public) is in place")
                // Before the plugin runs again: it is quiet until `resume`.
                carryTheDecision(of: identifier, from: before, to: record, asking: staged.plugin.manifest)
                await keepWhatWasHeard(heard, branchHead: branchHead, heardAt: heardAt, of: id, for: record)
                reloadInstalled()
                discoverPlugins()
            } catch {
                if automatic, autoUpdates.ended(origin.source, id: id, version: version, throwing: error) == .leftAsItWas {
                    // A card action was running, the switch went off, or the
                    // operator's work came to the place: no failure, and the
                    // next asking says what becomes of it.
                    DeckLog.plugins.info("\(id, privacy: .public) is left as it was by its update by itself: \(String(describing: error), privacy: .public)")
                } else {
                    DeckLog.plugins.error("\(operation.rawValue, privacy: .public) \(id, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                    operationProblems[id] = OperationProblem(error)
                }
                reloadInstalled()
                discoverPlugins()
            }
        }
    }

    /// What **Look up** heard of the pull request or the branch a copy was
    /// just installed from — `pull`, or the branch's head `branchHead`, heard
    /// at `heardAt`; nil when it was not looked up — kept as what is known of
    /// it unless a read heard of it since (`FollowedRefs.keep`), with the
    /// cached listing of the commit it was merged as, if there is one.
    private func keepWhatWasHeard(_ pull: PullRequest?, branchHead: String?, heardAt: Date?, of id: String,
                                  for record: InstalledRecord) async {
        let mergeListing = await Self.listing(pull?.merged == true ? pull?.mergeCommit : nil, in: catalogueStore)
        var kept = followed
        kept.keep(pull, branchHead: branchHead, heardAt: heardAt, heardAtInstall: record, of: id,
                  defaultBranch: catalogue?.branch ?? catalogueState.defaultBranch, mergeListing: mergeListing, now: Date())
        guard kept != followed else { return }
        followed = kept
        saveFollowed()
    }

    /// The copy at `plugins/<id>` as the permission decision knows it: its
    /// version, what it asks for, and whether it stands **Verified**.
    private func copyForTheDecision(_ id: String) -> GrantCarry.Copy? {
        guard let manifest = installedManifest(id) else { return nil }
        return GrantCarry.Copy(version: manifest.version, asks: manifest.permissions.capabilities,
                               verified: standings[id] == .verified)
    }

    /// The permission decision after `before` was replaced by `record`'s copy,
    /// which asks for what `manifest` asks: carried to the new version when
    /// `GrantCarry` says so — a verified copy for a verified copy, asking for
    /// the same — and left as it was otherwise, so that the card asks.
    private func carryTheDecision(of id: PluginIdentifier, from before: GrantCarry.Copy?, to record: InstalledRecord,
                                  asking manifest: PluginManifest?) {
        guard let manifest else { return }
        let after = GrantCarry.Copy(version: record.version, asks: manifest.permissions.capabilities,
                                    verified: record.verification.status == .verified)
        let carried = GrantCarry.after(grants[id], old: before, new: after)
        guard carried != grants[id] else { return }
        grants[id] = carried
        saveGrants()
        DeckLog.plugins.info("the permission decision of \(id.rawValue, privacy: .public) holds for \(record.version, privacy: .public): it asks for what \(before?.version ?? "", privacy: .public) asked for")
    }

    // MARK: - Removal

    /// **Remove**: the folder, its cache, the permission decision, its setting
    /// values and whether it was switched off, its record, every window of it on
    /// every tab, and its last card. Its catalogue data stays: it belongs to the
    /// repository. A folder of the operator's own — or one they changed — goes
    /// to the Trash rather than being deleted. Always after a warning: the
    /// first press (`shown` nil) answers it, and only the press on a warning
    /// that says what is there now removes anything.
    @discardableResult
    public func remove(_ id: String, shown: ShownPlace.Place? = nil) -> ShownPlace.Press {
        switch ShownPlace.remove(id, in: paths, installed: installed, shown: shown) {
        case .ask(let now): return .ask(now)
        case .remove: break
        case .nothing, .install, .atCommit: return .goAhead
        }
        guard busyPlugin == nil, let identifier = PluginIdentifier(rawValue: id) else { return .goAhead }
        guard installedProblem == nil else {
            operationProblems[id] = .recordsBroken(installedProblem ?? "")
            return .goAhead
        }
        busyPlugin = id
        operationProblems[id] = nil
        autoUpdates.began(id)
        let installer = self.installer
        Task {
            defer {
                busyPlugin = nil
                updateVerifiedPlugins()
            }
            defer { resume(identifier) }
            do {
                let removal = try await installer.beginRemoval(identifier, once: { await self.quiet(identifier) })
                forgetEverythingElse(about: identifier)
                // The plugin's last run may still be on its way into its run
                // log; the log goes after it, not before it is made again.
                await runLogs.drain()
                try installer.finishRemoval(removal)
                refreshRunLogsWritten()
                DeckLog.plugins.info("removed \(id, privacy: .public)")
            } catch {
                operationProblems[id] = OperationProblem(error)
            }
            reloadInstalled()
            discoverPlugins()
        }
        return .goAhead
    }

    /// The parts of a removal that live in uDeck's own stores: the permission
    /// decision, the setting values and the switch, every window, the last
    /// card. Also what finishes a removal a crash interrupted.
    func forgetEverythingElse(about id: PluginIdentifier) {
        if grants[id] != nil {
            grants[id] = nil
            saveGrants()
        }
        if pluginSettings.values[id.rawValue] != nil || pluginSettings.disabled.contains(id.rawValue) {
            pluginSettings.forget(id)
            savePluginSettings()
        }
        let gone = WindowRule.windowsToRemove(after: .pluginRemovedThroughUDeck(id), from: layout)
        if !gone.isEmpty {
            layout.removeWindows(gone)
            saveLayout()
        }
        snapshots[id.rawValue] = nil
        histories[id.rawValue] = nil
        historySources[id.rawValue] = nil
        if followed.holds(id.rawValue) {
            followed.forget(id.rawValue)
            saveFollowed()
        }
    }

    // MARK: - Linked folders

    /// A linked plugin's link and where it leads, as the plugins folder was
    /// last read — what **Linked** beside the plugin says (`target` nil when
    /// the link is not followed, and the plugin says why).
    public struct LinkedFolder: Equatable, Sendable {
        /// `<uDeck folder>/plugins/<id>`.
        public var link: URL
        /// The folder it leads to, every link on the way resolved.
        public var target: URL?
        /// What the link says, as it is written.
        public var destination: String

        /// Where it leads, as a row and a warning say it: the folder, or what
        /// the link says when uDeck does not follow it.
        public var leadsTo: String { target?.path ?? destination }
    }

    /// `id`'s link, when its folder in `plugins/` is one; nil for a folder that
    /// is there itself.
    public func linkedFolder(_ id: String) -> LinkedFolder? {
        guard let plugin = plugins.first(where: { $0.folderName == id }), let link = plugin.linkedAt else { return nil }
        let destination = (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) ?? link.path
        return LinkedFolder(link: link, target: plugin.directory == link ? nil : plugin.directory, destination: destination)
    }

    /// What **Link a folder…** came to.
    public enum FolderLinking: Equatable, Sendable {
        /// `<uDeck folder>/plugins/<id>` is a link to `target` now.
        case linked(id: String, target: String)
        /// It already was.
        case alreadyLinked(id: String, target: String)
        /// Something is at the id: a plugin uDeck installed, a folder of the
        /// operator's own, a link elsewhere — what the warning says, and
        /// whether it goes to the Trash (`OperatorsWork`) rather than being
        /// deleted as uDeck's own copy, or unlinked as a link. Nothing was
        /// done; asked again with this as `confirmed` once the operator has
        /// read it, and done then only if it is still what is there.
        case needsConfirmation(ShownPlace.Linking)
        /// Nothing was linked, and why. When the installer said no — the
        /// plugin would not end, the disk — its row says that too
        /// (`operationProblems`).
        case refused(FolderLinkRefusal)
    }

    /// **Link a folder…**: `folder` — an author's working copy — into uDeck as
    /// a link named after its manifest's id, `<uDeck folder>/plugins/<id>`.
    ///
    /// A free id is linked at once, as `udeck-plugin link` links it. An id that
    /// is taken is linked only when asked again with the warning the operator
    /// read as `confirmed`, and only while that warning still says what is
    /// there — the same id, the same thing at it, the same answer about the
    /// Trash (`ShownPlace.linking`); anything else, and the answer is the
    /// warning of what is there now. Linking over an installed plugin is
    /// uDeck's to do, with a warning (`FolderLinking`), and goes the way
    /// **Replace…** goes (`PluginInstaller.link`): the plugin quieted, the link
    /// swapped into place, what it replaces deleted, sent to the Trash or
    /// unlinked, and its record forgotten. Its windows, settings and permission
    /// decision stay; the decision is held to the linked manifest's version,
    /// as to any.
    public func linkFolder(_ folder: URL, confirmed: ShownPlace.Linking? = nil) async -> FolderLinking {
        guard busyPlugin == nil else { return .refused(.busy) }
        let candidate: PluginLink.Candidate
        let now: ShownPlace.Linking
        do {
            (candidate, now) = try ShownPlace.Linking.now(folder, in: paths, installed: installed)
        } catch let refusal as PluginLink.Refusal {
            return .refused(.folder(refusal.reason))
        } catch {
            return .refused(.failed("\(error)"))
        }
        let id = candidate.id.rawValue
        switch ShownPlace.linking(confirmed: confirmed, now: now) {
        case .linkAtOnce:
            do {
                try PluginLink.place(candidate, in: paths)
            } catch let refusal as PluginLink.Refusal {
                return .refused(.folder(refusal.reason))
            } catch {
                return .refused(.failed("\(error)"))
            }
            discoverPlugins()
            return .linked(id: id, target: candidate.target)
        case .alreadyLinked:
            return .alreadyLinked(id: id, target: candidate.target)
        case .ask(let shown):
            return .needsConfirmation(shown)
        case .replace:
            break
        }
        guard installedProblem == nil else { return .refused(.recordsBroken(installedProblem ?? "")) }
        busyPlugin = id
        operationProblems[id] = nil
        autoUpdates.began(id)
        defer { busyPlugin = nil }
        let installer = self.installer
        do {
            defer { resume(candidate.id) }
            try await installer.link(candidate, once: { await self.quiet(candidate.id) })
        } catch {
            operationProblems[id] = OperationProblem(error)
            reloadInstalled()
            discoverPlugins()
            if case InstallError.recordsBroken(let reason) = error { return .refused(.recordsBroken(reason)) }
            return .refused(.failed("\(error)"))
        }
        DeckLog.plugins.info("linked \(id, privacy: .public) to \(candidate.target, privacy: .public)")
        reloadInstalled()
        discoverPlugins()
        return .linked(id: id, target: candidate.target)
    }

    func reloadInstalled() {
        // A hashing begun against the records before these is not applied,
        // and stops at its next folder.
        reverifications += 1
        reverifyTask?.cancel()
        do {
            installed = try JSONFileStore<InstalledPlugins>(url: paths.installedFile).load() ?? InstalledPlugins()
            installedProblem = nil
        } catch {
            installedProblem = "\(error)"
        }
        // A copy just put in place is not run on its predecessor's tree: not
        // until the hashing after this read of the plugins folder lands.
        if !treesOnDisk.inQuestion { treesOnDisk.mayHaveChanged() }
    }

    func persistRateLimit() {
        var state = catalogueStore.state()
        state.rateLimit = limits.current
        try? catalogueStore.save(state)
        catalogueState = state
    }
}
