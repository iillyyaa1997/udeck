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

extension DeckModel {
    // MARK: - The source

    /// The official source: GitHub's API and raw host, or wherever
    /// `Info.plist` points a lab build.
    var provider: GitHubClient {
        GitHubClient(endpoints: endpoints, udeckVersion: udeckVersion, limits: limits)
    }

    var catalogueStore: CatalogueStore { CatalogueStore(paths: paths) }

    /// Where the catalogue comes from, as the operator reads it.
    public var catalogueAddress: RepositoryAddress { provider.address }

    private var installer: PluginInstaller {
        let provider = self.provider
        return PluginInstaller(
            paths: paths, discovery: discovery, trash: trash,
            fetch: { path, commit in try await provider.file(at: path, commit: commit) }
        )
    }

    // MARK: - When the catalogue is read

    /// Starts the catalogue's own clock: the refresh a few seconds after the
    /// panel is ready, unless it was read successfully in the last day, and
    /// then one a day while uDeck runs.
    ///
    /// Nothing else asks GitHub anything: opening Settings → Plugins when the
    /// catalogue is more than an hour old, **Check now**, and **Install**,
    /// **Update** or **Earlier versions** — each pressed by the operator.
    public func startCatalogueSchedule() {
        launchRefresh?.cancel()
        catalogueTimer?.invalidate()
        guard settings.readsOfficialCatalogue else { return }
        if CatalogueSchedule.refreshesAtLaunch(catalogueState, now: Date()) {
            launchRefresh = Task { [weak self] in
                try? await Task.sleep(nanoseconds: Seconds.nanoseconds(CatalogueSchedule.launchDelay))
                guard !Task.isCancelled else { return }
                await self?.refreshCatalogue(unrequested: true, why: "at launch")
            }
        }
        // A minute's tick asks whether the next refresh is due; the answer is
        // `CatalogueSchedule.nextDue`, which is where the rule is tested.
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.settings.readsOfficialCatalogue, !self.catalogueRefreshing,
                      CatalogueSchedule.nextDue(self.catalogueState, now: Date()) <= Date(),
                      self.catalogueState.lastAttempt.map({ Date().timeIntervalSince($0) > 60 }) ?? true
                else { return }
                Task { await self.refreshCatalogue(unrequested: true, why: "on schedule") }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        catalogueTimer = timer
    }

    /// Settings → Plugins was opened: the catalogue is read if it is more than
    /// an hour old.
    public func pluginsPaneOpened() {
        guard settings.readsOfficialCatalogue,
              CatalogueSchedule.refreshesWhenSettingsOpen(catalogueState, now: Date()) else { return }
        Task { await refreshCatalogue(unrequested: false, why: "Settings → Plugins opened") }
    }

    /// **Check now**.
    public func checkCatalogueNow() {
        guard settings.readsOfficialCatalogue else { return }
        Task { await refreshCatalogue(unrequested: false, why: "Check now") }
    }

    /// **Official catalogue**, on or off. Off, uDeck makes no request about
    /// plugins at all; installed plugins keep running.
    public func setOfficialCatalogue(_ on: Bool) {
        var changed = settings
        changed.officialCatalogue = on
        update(settings: changed)
        if on {
            startCatalogueSchedule()
            Task { await refreshCatalogue(unrequested: false, why: "the official catalogue was switched on") }
        } else {
            launchRefresh?.cancel()
            catalogueTimer?.invalidate()
            catalogueTimer = nil
        }
    }

    func refreshCatalogue(unrequested: Bool, why: String) async {
        guard settings.readsOfficialCatalogue, !catalogueRefreshing else { return }
        catalogueRefreshing = true
        defer { catalogueRefreshing = false }
        DeckLog.plugins.info("reading the official catalogue: \(why, privacy: .public)")
        let refresher = CatalogueRefresher(provider: provider, store: catalogueStore, limits: limits)
        let outcome = await refresher.refresh(unrequested: unrequested, language: strings.language.rawValue,
                                              installedCommits: installed.commits)
        DeckLog.plugins.info("the official catalogue: \(String(describing: outcome), privacy: .public)")
        catalogueState = catalogueStore.state()
        reloadCatalogue()
        reverify()
    }

    /// The catalogue as the cache holds it now.
    func reloadCatalogue() {
        catalogue = Catalogue.load(from: catalogueStore, address: provider.address, udeck: udeck,
                                   language: strings.language.rawValue)
    }

    // MARK: - What the rows show

    /// Where a plugin folder stands, as of the last read.
    public func standing(of id: String) -> PluginStanding {
        standings[id] ?? .folderOfYourOwn
    }

    /// Whether replacing or removing `id`'s folder now would send something of
    /// the operator's to the Trash — asked of the disk when a button is
    /// pressed, by the rule the installer decides the Trash by
    /// (`OperatorsWork`), so that the warning is shown whenever that happens
    /// and not only when the row says **Modified locally**.
    public func operatorsWorkGoesToTrash(_ id: String) -> Bool {
        OperatorsWork.goesToTrash(id, in: paths, record: installed.plugins[id])
    }

    /// Whether a window's plugin is here to run.
    public func presence(of id: PluginIdentifier) -> PluginPresence {
        PluginPresence.of(id, plugins: plugins, installed: installed, readsCatalogue: settings.readsOfficialCatalogue)
    }

    /// What the repository has for an installed plugin, or nil when uDeck did
    /// not install it or there is no catalogue to compare with.
    public func updateOffer(for id: String) -> UpdateOffer? {
        guard let record = installed.plugins[id], let catalogue else { return nil }
        return UpdateOffer.of(record, head: catalogue.entry(id))
    }

    /// A catalogue row's state.
    public func rowState(for entry: CatalogueEntry) -> CatalogueRowState {
        CatalogueRowState.of(entry, record: installed.plugins[entry.id], folderExists: folderExists(entry.id))
    }

    /// How many updates are waiting.
    public var updatesWaiting: Int {
        installed.plugins.keys.filter { updateOffer(for: $0)?.isWaiting == true && folderExists($0) }.count
    }

    /// Whether something sits at `plugins/<id>` — asked the way the swap
    /// will find it, so a folder spelt `Uptime` on a volume that ignores case
    /// is offered **Replace…** rather than an **Install** that would take it.
    public func folderExists(_ id: String) -> Bool {
        PluginInstaller.folderIsTaken(id, in: paths)
    }

    /// The page where a plugin's folder is read, at a commit.
    public func folderPage(_ id: String, commit: String) -> URL? {
        provider.folderPage("\(CommitListing.pluginsFolder)/\(id)", commit: commit)
    }

    /// *What changed*: the installed commit against the head.
    public func whatChanged(_ id: String) -> URL? {
        guard let record = installed.plugins[id], let head = catalogue?.commit else { return nil }
        return provider.comparePage(from: record.commit, to: head)
    }

    // MARK: - Verification

    /// Recomputes every record's verification from what its folder hashes to
    /// now, and writes it back only when it changed. Never trusted from the
    /// file: nothing, least of all a consent decision, is decided on it.
    func reverify() {
        var next: [String: PluginStanding] = [:]
        var changed = false
        let now = Date()
        for plugin in plugins {
            let id = plugin.folderName
            guard let record = installed.plugins[id] else {
                next[id] = .folderOfYourOwn
                continue
            }
            let tree = (try? GitHash.tree(ofDirectoryAt: plugin.directory)) ?? nil
            next[id] = PluginStanding.of(record: record, folderExists: true, treeOnDisk: tree)
            let found = record.verification(treeOnDisk: tree, headCommit: catalogue?.commit, now: now)
            if !found.saysTheSame(as: record.verification) {
                installed.plugins[id]?.verification = found
                changed = true
            }
        }
        for id in installed.plugins.keys where next[id] == nil { next[id] = .missing }
        standings = next
        if changed, installedProblem == nil {
            save(JSONFileStore<InstalledPlugins>(url: paths.installedFile), installed, named: "installed plugins")
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

    // MARK: - Install, update, earlier versions

    /// **Install** — or **Replace…** over a folder of the operator's own — at
    /// the commit the catalogue was built from, whatever the repository has
    /// done since: what the operator saw is what they get.
    public func install(_ id: String) {
        guard let catalogue, let entry = catalogue.entry(id) else { return }
        let operation: InstallRequest.Operation =
            installed.plugins[id] != nil ? .update : (folderExists(id) ? .replace : .install)
        run(operation, id: id, commit: catalogue.commit, folder: entry.listing,
            version: entry.manifest?.version ?? "", manifest: manifestData(entry))
    }

    /// **Update**, or **Switch to** a version the repository went back to: the
    /// plugin at the head.
    public func update(_ id: String) {
        guard let catalogue, let entry = catalogue.entry(id) else { return }
        run(.update, id: id, commit: catalogue.commit, folder: entry.listing,
            version: entry.manifest?.version ?? "", manifest: manifestData(entry))
    }

    /// **Reinstall**: what the record says was installed, put back — over a
    /// copy changed on disk, which goes to the Trash, or where it has gone.
    /// A download, so not while **Official catalogue** is off.
    public func reinstall(_ id: String) {
        guard settings.readsOfficialCatalogue, let record = installed.plugins[id] else { return }
        runAtCommit(.reinstall, id: id, commit: record.commit, version: record.version)
    }

    /// **Back to** the copy this one replaced.
    public func backToPrevious(_ id: String) {
        guard let previous = installed.plugins[id]?.previous else { return }
        runAtCommit(.earlier, id: id, commit: previous.commit, version: previous.version)
    }

    /// An earlier version, chosen from history: installed and marked pinned.
    public func installEarlier(_ id: String, line: PluginHistory.Line) {
        runAtCommit(.earlier, id: id, commit: line.commit, version: line.version)
    }

    /// Reads a plugin's earlier versions from its folder's history.
    public func readEarlierVersions(_ id: String) {
        guard settings.readsOfficialCatalogue, let head = catalogue?.commit,
              let branch = catalogueState.defaultBranch ?? catalogue?.branch else { return }
        if case .read(let history) = histories[id], history.headCommit == head { return }
        histories[id] = .reading
        let reader = PluginHistoryReader(provider: provider, store: catalogueStore)
        Task {
            do {
                let history = try await reader.read(id, branch: branch, head: head)
                histories[id] = .read(history)
            } catch {
                histories[id] = .failed(OperationProblem(error))
            }
            catalogueState.rateLimit = limits.current
            persistRateLimit()
        }
    }

    private func manifestData(_ entry: CatalogueEntry) -> Data? {
        entry.listing.file(at: PluginDiscovery.manifestFilename).flatMap { catalogueStore.blob($0.sha) }
    }

    /// An operation at a commit that is not the head: its listing from the
    /// cache, or one request for it.
    private func runAtCommit(_ operation: InstallRequest.Operation, id: String, commit: String, version: String) {
        // Off, uDeck makes no request about plugins at all — whichever button
        // was pressed, and whatever screen it was on.
        guard settings.readsOfficialCatalogue, busyPlugin == nil else { return }
        busyPlugin = id
        operationProblems[id] = nil
        let refresher = CatalogueRefresher(provider: provider, store: catalogueStore, limits: limits)
        Task {
            do {
                let listing = try await refresher.listing(commit)
                guard let folder = listing.plugins[id] else {
                    throw InstallError.refused([.noManifest(path: "plugins/\(id)/manifest.json")])
                }
                let manifest = folder.file(at: PluginDiscovery.manifestFilename).flatMap { catalogueStore.blob($0.sha) }
                busyPlugin = nil
                run(operation, id: id, commit: commit, folder: folder, version: version, manifest: manifest)
            } catch {
                operationProblems[id] = OperationProblem(error)
                busyPlugin = nil
            }
            catalogueState.rateLimit = limits.current
            persistRateLimit()
        }
    }

    private func run(
        _ operation: InstallRequest.Operation,
        id: String,
        commit: String,
        folder: PluginListing,
        version: String,
        manifest: Data?
    ) {
        guard settings.readsOfficialCatalogue, busyPlugin == nil,
              let identifier = PluginIdentifier(rawValue: id) else { return }
        guard installedProblem == nil else {
            operationProblems[id] = .recordsBroken(installedProblem ?? "")
            return
        }
        busyPlugin = id
        operationProblems[id] = nil
        let request = InstallRequest(
            operation: operation, id: identifier, repository: provider.address,
            ref: PluginRef(kind: "default", name: catalogueState.defaultBranch ?? catalogue?.branch),
            commit: commit, folder: folder, version: version, headCommit: catalogue?.commit
        )
        let installer = self.installer
        Task {
            defer {
                busyPlugin = nil
                catalogueState.rateLimit = limits.current
                persistRateLimit()
            }
            do {
                DeckLog.plugins.info("\(operation.rawValue, privacy: .public) \(id, privacy: .public) at \(commit, privacy: .public)")
                let staged = try await installer.stage(request, manifest: manifest)
                defer { resume(identifier) }
                let record = try await installer.commit(staged, once: { await self.quiet(identifier) })
                DeckLog.plugins.info("\(id, privacy: .public) \(record.version, privacy: .public) is in place")
                reloadInstalled()
                discoverPlugins()
            } catch {
                DeckLog.plugins.error("\(operation.rawValue, privacy: .public) \(id, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                operationProblems[id] = OperationProblem(error)
                reloadInstalled()
                discoverPlugins()
            }
        }
    }

    // MARK: - Removal

    /// **Remove**: the folder, its cache, the permission decision, its setting
    /// values and whether it was switched off, its record, every window of it on
    /// every tab, and its last card. Its catalogue data stays: it belongs to the
    /// repository. A folder of the operator's own — or one they changed — goes
    /// to the Trash rather than being deleted.
    public func remove(_ id: String) {
        guard busyPlugin == nil, let identifier = PluginIdentifier(rawValue: id) else { return }
        guard installedProblem == nil else {
            operationProblems[id] = .recordsBroken(installedProblem ?? "")
            return
        }
        busyPlugin = id
        operationProblems[id] = nil
        let installer = self.installer
        Task {
            defer { busyPlugin = nil }
            defer { resume(identifier) }
            do {
                let removal = try await installer.beginRemoval(identifier, once: { await self.quiet(identifier) })
                forgetEverythingElse(about: identifier)
                try installer.finishRemoval(removal)
                DeckLog.plugins.info("removed \(id, privacy: .public)")
            } catch {
                operationProblems[id] = OperationProblem(error)
            }
            reloadInstalled()
            discoverPlugins()
        }
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
    }

    func reloadInstalled() {
        do {
            installed = try JSONFileStore<InstalledPlugins>(url: paths.installedFile).load() ?? InstalledPlugins()
            installedProblem = nil
        } catch {
            installedProblem = "\(error)"
        }
    }

    private func persistRateLimit() {
        var state = catalogueStore.state()
        state.rateLimit = limits.current
        try? catalogueStore.save(state)
        catalogueState = state
    }
}
