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
    /// **Update** or **Earlier versions** — each pressed by the operator — and,
    /// after a read, the files of a verified plugin that updates itself
    /// (`updateVerifiedPlugins`).
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
                // An update by itself that waited — on a card action, on
                // another operation — is asked about again.
                self?.updateVerifiedPlugins()
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
        await reloadCatalogue()
        reverify()
        // A read that succeeded: every update waiting is asked about anew — one
        // that failed since the last read too — once the hashing just started
        // is applied, and not on a standing from before the read.
        var succeeded = false
        if case .refreshed = outcome { succeeded = true }
        autoUpdates.read(succeeded: succeeded, hashing: reverifications)
    }

    /// The catalogue as the cache holds it now, read away from the main thread
    /// (`Catalogue.read`). Two reads can overlap — the one at launch and a
    /// refresh's — and only the one asked for last is shown, whichever ends
    /// first.
    func reloadCatalogue() async {
        catalogueReads += 1
        let read = catalogueReads
        let loaded = await Catalogue.read(from: catalogueStore, address: provider.address, udeck: udeck,
                                          language: strings.language.rawValue)
        guard read == catalogueReads else { return }
        catalogue = loaded
        catalogueWasRead = true
    }

    // MARK: - What the rows show

    /// Where a plugin folder stands, as of the last read.
    public func standing(of id: String) -> PluginStanding {
        standings[id] ?? .folderOfYourOwn
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

    /// Whether the version the catalogue's head has for `id` asks for other
    /// permissions than the copy on disk (`AutoUpdate.asksDifferently`) —
    /// false when either cannot be read. Such an update never happens by
    /// itself, and its row says why.
    public func updateAsksDifferently(_ id: String) -> Bool {
        guard let now = installedManifest(id)?.permissions.capabilities,
              let head = catalogue?.entry(id)?.manifest?.permissions.capabilities else { return false }
        return AutoUpdate.asksDifferently(now, head)
    }

    /// The manifest of the copy at `plugins/<id>`, as the folder was last
    /// read — none for a linked folder, which no repository updates.
    func installedManifest(_ id: String) -> PluginManifest? {
        plugins.first { $0.folderName == id && !$0.isLinked }?.manifest
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
        let folders = Reverification.folders(of: plugins, installed: installed)
        // The hashing before this one would not be applied: it stops at its
        // next folder rather than hashing every installed plugin for nothing.
        reverifyTask?.cancel()
        reverifyTask = Task {
            guard let trees = await Reverification.trees(of: folders) else { return }
            guard asked == reverifications else { return }
            let found = Reverification.of(plugins, installed: installed, trees: trees,
                                          head: catalogueWasRead ? .read(catalogue?.commit) : .notReadYet, now: Date())
            if found.standings != standings { standings = found.standings }
            if let records = found.records, installedProblem == nil {
                installed = records
                save(JSONFileStore<InstalledPlugins>(url: paths.installedFile), installed, named: "installed plugins")
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
    func quietUnlessActing(_ id: PluginIdentifier) async -> Bool {
        guard switchedOnStill(id) else { return false }
        pluginRuns.quiet(id.rawValue)
        guard !actionProcesses.isRunning(id.rawValue) else {
            DeckLog.plugins.info("\(id.rawValue, privacy: .public) has a card action running; it is not ended for an update by itself")
            return false
        }
        return await quiet(id) && switchedOnStill(id)
    }

    private func switchedOnStill(_ id: PluginIdentifier) -> Bool {
        guard settings.verifiedPluginsUpdateThemselves else {
            DeckLog.plugins.info("\(id.rawValue, privacy: .public) does not update itself: switched off while it downloaded")
            return false
        }
        return true
    }

    // MARK: - Updating by themselves

    /// Verified plugins whose update is waiting, updated by themselves, one at
    /// a time, through the update **Update** makes — whatever `AutoUpdate`
    /// says of each, decided there and tested there. Asked once the folders
    /// are hashed after each successful read of the catalogue, after each
    /// install, update or removal ends, and on the minute's tick while one
    /// waits; at any other time it does nothing.
    func updateVerifiedPlugins() {
        guard autoUpdates.asks else { return }
        let switchedOn = settings.verifiedPluginsUpdateThemselves
        guard switchedOn, installedProblem == nil, catalogue != nil else {
            autoUpdates.asked(started: false, waits: false)
            return
        }
        var waits = false
        for id in installed.plugins.keys.sorted() {
            switch autoUpdateVerdict(for: id, switchedOn: switchedOn) {
            case .update(let version):
                DeckLog.plugins.info("\(id, privacy: .public) updates itself to \(version, privacy: .public)")
                if updateByItself(id) {
                    autoUpdates.asked(started: true, waits: waits)
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
        autoUpdates.asked(started: false, waits: waits)
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
            asksAtHead: catalogue?.entry(id)?.manifest?.permissions.capabilities,
            place: place, actionRunning: actionProcesses.isRunning(id),
            failedSinceTheLastRead: autoUpdates.failures[id] != nil
        )
        return AutoUpdate.verdict(plugin, switchedOn: switchedOn, busy: busyPlugin != nil)
    }

    /// Starts `id`'s update by itself: the step **Update** takes, pressed with
    /// nothing shown — and when that step would warn first, nothing here
    /// answers it. Answers whether it started.
    private func updateByItself(_ id: String) -> Bool {
        guard case .install(let operation, let commit, let folder, let version)
                = ShownPlace.update(id, catalogue: catalogue, in: paths, installed: installed, shown: nil) else {
            return false
        }
        run(operation, id: id, commit: commit, folder: folder, version: version, automatic: true)
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
    @discardableResult
    public func install(_ id: String, shown: ShownPlace.Place? = nil) -> ShownPlace.Press {
        act(ShownPlace.install(id, catalogue: catalogue, in: paths, installed: installed, shown: shown), id: id)
    }

    /// **Update**, or **Switch to** a version the repository went back to: the
    /// plugin at the head.
    @discardableResult
    public func update(_ id: String, shown: ShownPlace.Place? = nil) -> ShownPlace.Press {
        act(ShownPlace.update(id, catalogue: catalogue, in: paths, installed: installed, shown: shown), id: id)
    }

    /// **Reinstall**: what the record says was installed, put back — over a
    /// copy changed on disk, which goes to the Trash, or where it has gone.
    /// A download, so not while **Official catalogue** is off.
    @discardableResult
    public func reinstall(_ id: String, shown: ShownPlace.Place? = nil) -> ShownPlace.Press {
        guard settings.readsOfficialCatalogue else { return .goAhead }
        return act(ShownPlace.reinstall(id, in: paths, installed: installed, shown: shown), id: id)
    }

    /// **Back to** the copy this one replaced.
    @discardableResult
    public func backToPrevious(_ id: String, shown: ShownPlace.Place? = nil) -> ShownPlace.Press {
        act(ShownPlace.backToPrevious(id, in: paths, installed: installed, shown: shown), id: id)
    }

    /// An earlier version, chosen from history: installed and marked pinned.
    @discardableResult
    public func installEarlier(_ id: String, line: PluginHistory.Line, shown: ShownPlace.Place? = nil) -> ShownPlace.Press {
        act(ShownPlace.earlier(id, line: line, in: paths, installed: installed, shown: shown), id: id)
    }

    /// Does what `step` says — every argument it carries is `ShownPlace`'s —
    /// and answers what the press came to.
    private func act(_ step: ShownPlace.Step, id: String) -> ShownPlace.Press {
        switch step {
        case .nothing:
            return .goAhead
        case .ask(let now):
            return .ask(now)
        case .install(let operation, let commit, let folder, let version):
            run(operation, id: id, commit: commit, folder: folder, version: version)
            return .goAhead
        case .atCommit(let operation, let commit, let version):
            runAtCommit(operation, id: id, commit: commit, version: version)
            return .goAhead
        case .remove:
            // Removal has its own call; no step but `remove`'s answers this.
            return .goAhead
        }
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
                busyPlugin = nil
                run(operation, id: id, commit: commit, folder: folder, version: version)
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
    private func run(
        _ operation: InstallRequest.Operation,
        id: String,
        commit: String,
        folder: PluginListing,
        version: String,
        automatic: Bool = false
    ) {
        guard settings.readsOfficialCatalogue, busyPlugin == nil,
              let identifier = PluginIdentifier(rawValue: id) else { return }
        guard installedProblem == nil else {
            operationProblems[id] = .recordsBroken(installedProblem ?? "")
            return
        }
        busyPlugin = id
        operationProblems[id] = nil
        autoUpdates.began(id)
        let request = InstallRequest(
            operation: operation, id: identifier, repository: provider.address,
            ref: PluginRef(kind: "default", name: catalogueState.defaultBranch ?? catalogue?.branch),
            commit: commit, folder: folder, version: version, headCommit: catalogue?.commit, automatic: automatic
        )
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
                let record = try await installer.commit(staged, once: { @Sendable in
                    automatic ? await self.quietUnlessActing(identifier) : await self.quiet(identifier)
                })
                DeckLog.plugins.info("\(id, privacy: .public) \(record.version, privacy: .public) is in place")
                // Before the plugin runs again: it is quiet until `resume`.
                carryTheDecision(of: identifier, from: before, to: record, asking: staged.plugin.manifest)
                reloadInstalled()
                discoverPlugins()
            } catch {
                if automatic, autoUpdates.ended(id, version: version, throwing: error) == .leftAsItWas {
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
    }

    private func persistRateLimit() {
        var state = catalogueStore.state()
        state.rateLimit = limits.current
        try? catalogueStore.save(state)
        catalogueState = state
    }
}
