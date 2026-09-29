import AppKit
import Observation
import UDeckCore

/// Everything the panel shows, and the one place that changes it.
///
/// The shell owns no content of its own. What appears in the panel is whatever
/// the installed plugins produce, so this object's job is to know which plugins
/// exist, which the operator has permitted, when to run them, and what they last
/// said. An install with no plugins leaves it holding nothing — a legitimate
/// state, and the first one anybody sees.
@MainActor
@Observable
public final class DeckModel {
    public private(set) var settings: AppSettings
    public internal(set) var layout: DeckLayout
    public private(set) var plugins: [DiscoveredPlugin] = []
    public internal(set) var snapshots: [String: PluginSnapshot] = [:]
    public internal(set) var grants: PermissionGrants
    public internal(set) var pluginSettings: PluginSettings

    // MARK: - Plugins from a repository (DeckModel+Repository.swift)

    /// `installed.json`: where each plugin uDeck installed came from.
    public internal(set) var installed: InstalledPlugins
    /// Why `installed.json` could not be read, while it cannot. uDeck installs,
    /// updates and removes nothing meanwhile, since any of those would have to
    /// overwrite it.
    public internal(set) var installedProblem: String?
    /// Where each plugin folder stands — verified, modified, a folder of the
    /// operator's own — as of the last read of the plugins folder.
    public internal(set) var standings: [String: PluginStanding] = [:]
    /// The official catalogue as the cache holds it, shown at once.
    public internal(set) var catalogue: Catalogue?
    public internal(set) var catalogueState: CatalogueState
    public internal(set) var catalogueRefreshing = false
    /// The one install, update or removal running, if any. They run one after
    /// another, which is what keeps `installed.json` and the plugins folder
    /// from ever being written by two of them at once.
    public internal(set) var busyPlugin: String?
    /// What the last operation on a plugin came to, when it did not succeed.
    public internal(set) var operationProblems: [String: OperationProblem] = [:]
    /// Earlier versions, as they were read.
    public internal(set) var histories: [String: HistoryLoad] = [:]

    /// The running uDeck's own version, as `CFBundleShortVersionString` says it.
    public let udeckVersion: String
    /// The same, as a version — nil for a build somebody stamped by hand,
    /// which skips every `minUDeck` comparison rather than refusing everything.
    public let udeck: SemanticVersion?
    let endpoints: GitHubEndpoints
    let limits: RateLimitRecorder
    let trash: any PluginTrash
    var catalogueTimer: Timer?
    var launchRefresh: Task<Void, Never>?
    /// Plugins being replaced or removed, on which nothing starts, and the
    /// runs of each in flight — polls and card actions — so quieting one can
    /// wait for them to end.
    var pluginRuns = PluginQuiet()
    /// Card actions that are running, each in a process group of its own, so
    /// that quieting a plugin can end the ones that outlast the wait.
    let actionProcesses = ActionProcesses()

    /// Problems worth showing the operator: a settings file that would not
    /// parse, a layout that could not be written, a plugin whose windows had to
    /// be removed. Collected and shown rather than only logged, because a
    /// message in a log nobody reads is the same as no message — and a layout
    /// that quietly fails to save is the operator's arrangement disappearing
    /// with no explanation the next time they launch.
    public private(set) var problems: [String] = []

    public func clearProblems() { problems.removeAll() }

    /// Records a failure the operator needs to know about, keeping the most
    /// recent few rather than growing without bound.
    func record(_ description: String) {
        DeckLog.plugins.error("\(description, privacy: .public)")
        guard !problems.contains(description) else { return }
        problems.append(description)
        // Drop the newest rather than the oldest when full. The same failure
        // with a different byte count reads as a new entry, so a repeating
        // problem would otherwise push out the earlier ones the operator has
        // not read — and the first thing that went wrong is usually the one
        // worth reading.
        if problems.count > Self.maximumProblems {
            problems.removeLast(problems.count - Self.maximumProblems)
        }
    }

    private static let maximumProblems = 10

    /// Set by the shell so the model knows whether anybody is looking.
    public var panelIsVisible = false {
        didSet { if panelIsVisible != oldValue { visibilityChanged() } }
    }

    /// What uDeck tells a producer about how its card will be drawn.
    ///
    /// Always dark, because the panel is: it hangs over whatever the operator
    /// has on screen, so its legibility cannot follow the system. Constant
    /// rather than a variable nothing writes, which is what it was — and the
    /// plugin contract now says the same thing instead of listing two values as
    /// if they varied.
    public let appearance: Appearance = .dark

    /// Told after the operator changes a setting, so the shell can rebuild
    /// anything that was created with one.
    public var onSettingsChanged: ((AppSettings) -> Void)?

    /// Told after the plugins folder has been read, which now happens whenever
    /// something in it changes rather than only at launch. The menu-bar item
    /// carries whether any of them will not run, and that answer is only as
    /// current as the last thing that told it.
    public var onPluginsChanged: (() -> Void)?

    let paths: UDeckPaths
    private let executor: PollExecutor
    private var pollTasks: [String: Task<Void, Never>] = [:]

    /// The refresh started by the most recent reveal.
    ///
    /// One task, not one per plugin, and the previous one is cancelled. Opening
    /// and closing the panel repeatedly used to stack an unbounded number of
    /// waves, each launching a process per placed plugin.
    private var refreshTask: Task<Void, Never>?

    /// Watches the plugins folder so the list is what is on disk rather than
    /// what was on disk at launch.
    private var folderWatcher: PluginFolderWatcher?

    private var settingsStore: JSONFileStore<AppSettings> { .init(url: paths.settingsFile) }
    private var layoutStore: JSONFileStore<DeckLayout> { .init(url: paths.layoutFile) }
    private var grantsStore: JSONFileStore<PermissionGrants> { .init(url: paths.grantsFile) }
    private var pluginSettingsStore: JSONFileStore<PluginSettings> { .init(url: paths.pluginSettingsFile) }

    public init(
        paths: UDeckPaths = .fromEnvironment(),
        executor: PollExecutor = PollExecutor(),
        udeckVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0",
        endpoints: GitHubEndpoints = .from(infoDictionary: Bundle.main.infoDictionary),
        trash: any PluginTrash = SystemTrash()
    ) {
        self.paths = paths
        self.executor = executor
        self.udeckVersion = udeckVersion
        self.udeck = SemanticVersion(udeckVersion)
        self.endpoints = endpoints
        self.trash = trash

        // Before the plugins folder is first read: an install, update or
        // removal a crash interrupted is finished or undone, so nothing below
        // reads a folder half-way through one.
        let recovered = PluginInstaller(
            paths: paths, discovery: PluginDiscovery(searchPath: []), trash: trash,
            fetch: { _, _ in throw ProviderError.unreachable("nothing is fetched while recovering") }
        ).recover()

        // Every store is loaded the same way: a missing file is a first run, a
        // broken file is reported and the defaults are used *without* the broken
        // file being overwritten, so the operator still has it to look at.
        var problems: [String] = []
        func load<T: Codable & Sendable>(_ store: JSONFileStore<T>, default fallback: @autoclosure @Sendable () -> T) -> T {
            do {
                return try store.load() ?? fallback()
            } catch {
                problems.append("\(error)")
                return fallback()
            }
        }

        settings = load(JSONFileStore<AppSettings>(url: paths.settingsFile), default: AppSettings())
            .validated()
            .resolved(systemIsDark: DeckModel.systemIsDark(), hour: DeckModel.currentHour())
        layout = load(JSONFileStore<DeckLayout>(url: paths.layoutFile), default: DeckLayout.firstRun()).normalized()
        grants = load(JSONFileStore<PermissionGrants>(url: paths.grantsFile), default: PermissionGrants())
        pluginSettings = load(JSONFileStore<PluginSettings>(url: paths.pluginSettingsFile), default: PluginSettings())
        do {
            installed = try JSONFileStore<InstalledPlugins>(url: paths.installedFile).load() ?? InstalledPlugins()
        } catch {
            installed = InstalledPlugins()
            installedProblem = "\(error)"
            problems.append("\(error)")
        }
        let store = CatalogueStore(paths: paths)
        let catalogueState = store.state()
        self.catalogueState = catalogueState
        limits = RateLimitRecorder(catalogueState.rateLimit)
        self.problems = problems

        if udeck == nil {
            DeckLog.plugins.error(
                "this uDeck's own version \(udeckVersion, privacy: .public) is not MAJOR.MINOR.PATCH; minUDeck is not compared"
            )
        }
        for operation in recovered {
            DeckLog.plugins.info("recovered at launch: \(String(describing: operation), privacy: .public)")
            if case .removalFinished(let id) = operation, let identifier = PluginIdentifier(rawValue: id) {
                forgetEverythingElse(about: identifier)
            }
        }
        catalogue = Catalogue.load(from: store, address: provider.address, udeck: udeck,
                                   language: strings.language.rawValue)

        for directory in paths.directoriesToCreate {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        folderWatcher = PluginFolderWatcher { [weak self] in
            self?.discoverPlugins()
        }
        folderWatcher?.start(watching: paths.plugins)
    }

    // MARK: - Plugins

    /// Re-reads the plugins folder.
    ///
    /// Called by the watcher whenever something in that folder changes, and by
    /// the button in the settings screen — which stays, because a watcher is a
    /// thing that can fail quietly and a button is a thing the operator can
    /// press when they suspect it has.
    public func discoverPlugins() {
        plugins = discovery.scan(paths.plugins)
        DeckLog.plugins.debug(
            "read the plugins folder: \(self.plugins.count, privacy: .public) found"
        )

        // Windows are never removed because a plugin is missing: a window
        // whose plugin is not here stays and says so (`PluginPresence`).
        let found = Set(plugins.compactMap { $0.manifest?.id })
        let gone = WindowRule.windowsToRemove(after: .pluginsFolderRead(found: found), from: layout)
        if !gone.isEmpty {
            layout.removeWindows(gone)
            saveLayout()
        }
        reverify()
        restartPolling()
        onPluginsChanged?()
    }

    /// How plugin folders are read: the configured search path, and this
    /// uDeck's version for `minUDeck`.
    var discovery: PluginDiscovery {
        PluginDiscovery(searchPath: settings.pluginExecutableSearchPath, udeck: udeck)
    }

    public func plugin(withID id: PluginIdentifier) -> DiscoveredPlugin? {
        plugins.first { $0.manifest?.id == id }
    }

    public func snapshot(for id: PluginIdentifier) -> PluginSnapshot {
        snapshots[id.rawValue] ?? PluginSnapshot(pluginID: id)
    }

    public func presentation(for id: PluginIdentifier, now: Date = Date()) -> CardPresentation {
        snapshot(for: id).presentation(
            now: now,
            defaultTTL: settings.defaultCardTTL,
            silentMultiplier: settings.silentTTLMultiplier
        )
    }

    public func launchDecision(for id: PluginIdentifier) -> LaunchDecision {
        guard let manifest = plugin(withID: id)?.manifest else { return .disabled }
        return PermissionGate.launchDecision(
            for: manifest, grant: grants[id], enabled: pluginSettings.isEnabled(id)
        )
    }

    // MARK: - Polling

    /// How many producers a single refresh may have in flight at once.
    private static let refreshWidth = 4

    /// Plugins with a window somewhere in the layout. Nothing else is run:
    /// a plugin the operator installed but has not placed anywhere is not
    /// something they asked to have executed every few seconds.
    private var placedPluginIDs: Set<PluginIdentifier> {
        Set(layout.tabs.flatMap { $0.windows.map(\.pluginID) })
    }

    private func visibilityChanged() {
        if panelIsVisible {
            refreshAll(reason: .manual)
        }
        restartPolling()
    }

    public func restartPolling() {
        for (_, task) in pollTasks { task.cancel() }
        pollTasks.removeAll()
        if !panelIsVisible && !settings.pollWhileCollapsed { refreshTask?.cancel() }

        guard panelIsVisible || settings.pollWhileCollapsed else { return }

        for plugin in plugins {
            guard let manifest = plugin.manifest, manifest.kind == .poll,
                  !pluginRuns.isQuiet(manifest.id.rawValue),
                  placedPluginIDs.contains(manifest.id),
                  launchDecision(for: manifest.id).isAllowed,
                  let interval = manifest.interval, interval > 0
            else { continue }

            pollTasks[manifest.id.rawValue] = Task { [weak self] in
                while !Task.isCancelled {
                    // Re-read the failure count each time round rather than
                    // capturing it: the wait after this sleep depends on how the
                    // poll it follows went.
                    let wait = self?.pollDelay(for: manifest) ?? interval
                    try? await Task.sleep(nanoseconds: Seconds.nanoseconds(wait))
                    guard !Task.isCancelled else { return }
                    await self?.poll(plugin, reason: .interval)
                }
            }
        }
    }

    /// Cancels one plugin's poll loop. Part of quieting it: see `quiet`.
    func stopPolling(_ id: PluginIdentifier) {
        pollTasks[id.rawValue]?.cancel()
        pollTasks[id.rawValue] = nil
    }

    /// How long to wait before polling this plugin again.
    ///
    /// A plugin that has just failed is asked again later than one that
    /// answered, which is what stops a broken producer from costing what a
    /// working one costs for as long as the panel is open.
    private func pollDelay(for manifest: PluginManifest) -> TimeInterval {
        manifest.delay(
            afterConsecutiveFailures: snapshots[manifest.id.rawValue]?.consecutiveFailures ?? 0
        )
    }

    /// Runs everything once, now, replacing any refresh still in flight.
    public func refreshAll(reason: RefreshReason) {
        refreshTask?.cancel()
        let due = plugins.filter { plugin in
            guard plugin.manifest?.kind == .poll, let id = plugin.manifest?.id,
                  !pluginRuns.isQuiet(id.rawValue) else { return false }
            return placedPluginIDs.contains(id)
        }
        refreshTask = Task { [weak self] in
            // Concurrent, but not unboundedly: one plugin sitting on its
            // deadline used to delay every plugin behind it in the list, so
            // opening the panel with one hung producer meant the others were
            // refreshed seconds late. A width, rather than all of them at once,
            // because each is a process and a machine with twenty plugins
            // should not start twenty at the same moment.
            await withTaskGroup(of: Void.self) { group in
                var running = 0
                for plugin in due {
                    guard !Task.isCancelled else { break }
                    if running == Self.refreshWidth {
                        await group.next()
                        running -= 1
                    }
                    group.addTask { await self?.poll(plugin, reason: reason) }
                    running += 1
                }
            }
        }
    }

    public func refresh(_ id: PluginIdentifier) {
        guard let plugin = plugin(withID: id) else { return }
        Task { await poll(plugin, reason: .manual) }
    }

    private func poll(_ plugin: DiscoveredPlugin, reason: RefreshReason) async {
        guard let id = plugin.manifest?.id, pluginRuns.begin(id.rawValue) else { return }
        defer { pluginRuns.end(id.rawValue) }
        let outcome = await executor.poll(
            plugin: plugin,
            grant: grants[id],
            enabled: pluginSettings.isEnabled(id),
            settings: pluginSettings,
            paths: paths,
            searchPath: settings.pluginExecutableSearchPath,
            appearance: appearance,
            reason: reason,
            language: strings.language.rawValue
        )

        // Re-read rather than reuse the value from before the await: another
        // poll of the same plugin can have finished in between — a manual
        // refresh on reveal races the interval task — and writing back a
        // snapshot captured earlier would drop its card and undercount its
        // failures.
        var snapshot = snapshots[id.rawValue] ?? PluginSnapshot(pluginID: id)
        switch outcome {
        case .card(let card):
            snapshot.record(card: card, at: Date())
        case .lateCard(let card, let failure):
            snapshot.record(card: card, at: Date())
            snapshot.record(failure: failure)
        case .failure(let failure):
            snapshot.record(failure: failure)
        }
        snapshots[id.rawValue] = snapshot
    }

    // MARK: - Layout editing

    public func selectTab(_ id: UUID) {
        layout.selectedTabID = id
        saveLayout()
    }

    @discardableResult
    public func addTab(named name: String) -> UUID {
        let id = layout.addTab(named: name)
        saveLayout()
        return id
    }

    public func renameTab(_ id: UUID, to name: String) {
        layout.renameTab(id, to: name)
        saveLayout()
    }

    public func removeTab(_ id: UUID) {
        layout.removeTab(id)
        saveLayout()
        restartPolling()
    }

    public func moveTab(from source: Int, to destination: Int) {
        layout.moveTab(from: source, to: destination)
        saveLayout()
    }

    public func addWindow(pluginID: PluginIdentifier, to tabID: UUID) {
        let hints = plugin(withID: pluginID)?.manifest?.window ?? WindowHints()
        layout.addWindow(pluginID: pluginID, to: tabID, hints: hints)
        saveLayout()
        restartPolling()
        refresh(pluginID)
    }

    public func removeWindow(_ windowID: UUID, from tabID: UUID) {
        let gone = WindowRule.windowsToRemove(after: .removedByOperator(window: windowID), from: layout)
        guard !gone.isEmpty else { return }
        layout.removeWindows(gone)
        saveLayout()
        restartPolling()
    }

    public func place(windowID: UUID, in tabID: UUID, column: Int, row: Int, width: Int? = nil, height: Int? = nil) {
        layout.place(windowID: windowID, in: tabID, column: column, row: row, width: width, height: height)
        saveLayout()
    }

    // MARK: - Settings and permissions

    public func update(settings newValue: AppSettings) {
        let settings = newValue.validated()
            .resolved(systemIsDark: DeckModel.systemIsDark(), hour: DeckModel.currentHour())
        self.settings = settings
        save(settingsStore, settings, named: "settings")
        restartPolling()
        onSettingsChanged?(settings)
    }

    /// Re-reads the world and puts the panel in whichever look it now calls for.
    ///
    /// Called when macOS changes appearance and once a minute for the clock. It
    /// does nothing at all when the answer has not moved, which is almost every
    /// time — a look that is rebuilt every minute is a panel that flickers for
    /// no reason, and a settings file that is rewritten every minute is a disk
    /// that never sleeps.
    public func refreshTheme() {
        let resolved = settings.resolved(
            systemIsDark: DeckModel.systemIsDark(), hour: DeckModel.currentHour()
        )
        guard resolved.glass != settings.glass || resolved.ink != settings.ink else { return }
        settings = resolved
        onSettingsChanged?(resolved)
    }

    /// What macOS is set to.
    ///
    /// Asked of the effective appearance rather than the `AppleInterfaceStyle`
    /// default, which is absent in light mode and therefore indistinguishable
    /// from a system that has never been asked.
    public static func systemIsDark() -> Bool {
        NSApp?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    public static func currentHour() -> Int {
        Calendar.current.component(.hour, from: Date())
    }

    /// Everything uDeck says, in the language in force.
    ///
    /// Derived rather than stored, so that changing the setting changes the
    /// application in the same instant the switch is thrown — the settings
    /// window is written in the language it is setting, and a stored copy would
    /// mean the screen you changed it on was the last one to notice.
    /// A plugin's manifest as the operator should read it — its own strings
    /// replaced by the translation for the language in force, where the plugin
    /// ships one.
    ///
    /// Display only. Everything uDeck acts on — what it runs, what it may do —
    /// keeps reading `plugin.manifest`, and could not do otherwise: a
    /// translation is strings and has nowhere to put a command.
    public func displayManifest(for plugin: DiscoveredPlugin) -> PluginManifest? {
        plugin.manifest(in: strings.language.rawValue)
    }

    public func displayManifest(withID id: PluginIdentifier) -> PluginManifest? {
        plugin(withID: id).flatMap(displayManifest(for:))
    }

    public var strings: Strings {
        Strings(settings.resolvedLanguage(systemPreferred: Language.preferred()))
    }

    public func setEnabled(_ enabled: Bool, for id: PluginIdentifier) {
        pluginSettings.setEnabled(enabled, for: id)
        savePluginSettings()
        restartPolling()
    }

    public func setSetting(_ value: SettingValue, key: String, for id: PluginIdentifier) {
        pluginSettings.set(value, for: key, plugin: id)
        savePluginSettings()
        refresh(id)
    }

    /// Records the operator's answer to a plugin's request, in full.
    ///
    /// Partial answers are not offered: a plugin either runs with everything it
    /// declared or does not run. Anything else would be a promise the host
    /// cannot keep — see `CapabilityEnforcement`.
    public func decidePermissions(for id: PluginIdentifier, allow: Bool) {
        guard let manifest = plugin(withID: id)?.manifest else { return }
        let requested = Set(manifest.permissions.capabilities)
        grants[id] = PluginGrant(
            granted: allow ? requested : [],
            denied: allow ? [] : requested,
            decidedForVersion: manifest.version
        )
        save(grantsStore, grants, named: "permission decisions")
        restartPolling()
        if allow { refresh(id) }
    }

    /// Runs a card's action, if the plugin was granted the right to.
    ///
    /// The host runs it, not the plugin — which is what makes the grant real:
    /// the refusal happens in code the plugin does not control.
    public func run(_ action: CardAction, from id: PluginIdentifier) -> String? {
        guard let manifest = plugin(withID: id)?.manifest,
              PermissionGate.mayRun(action, requestedBy: manifest, grant: grants[id]) else {
            return "\(action.run.first ?? "that command") is not one of the commands \(id) was allowed to run"
        }
        guard let executable = resolve(command: action.run[0], for: id) else {
            return "\(action.run[0]) was not found"
        }
        // Nothing of a plugin runs across the swap of its folder or its
        // removal: an action pressed meanwhile is refused, and one that starts
        // is counted, so quieting the plugin waits for it as it waits for a poll.
        guard pluginRuns.begin(id.rawValue) else {
            return "\(id) is being updated or removed; try again in a moment"
        }

        let plugin = id.rawValue
        do {
            // In a process group of its own, so that quieting the plugin can
            // end it and whatever it started (`ActionProcesses`). It counts as
            // running until the whole group has ended.
            //
            // The environment is built, not inherited — the same rule as a
            // producer's, and for the same reason. This is the one path the
            // documentation calls host-mediated, so it is the last place that
            // should quietly hand a plugin whatever was in the shell that
            // started uDeck.
            try actionProcesses.start(
                plugin: plugin, executable: executable, arguments: Array(action.run.dropFirst()),
                workingDirectory: self.plugin(withID: id)?.directory ?? executable.deletingLastPathComponent(),
                environment: actionEnvironment(for: id),
                ended: { [weak self] in Task { @MainActor in self?.pluginRuns.end(plugin) } }
            )
        } catch {
            pluginRuns.end(plugin)
            return "\(action.run[0]) could not be started: \(error)"
        }
        return nil
    }

    /// The environment a card's action runs in.
    ///
    /// Deliberately the same shape as a producer's: a known search path, a
    /// UTF-8 locale, and nothing else carried over from however uDeck happened
    /// to be started.
    private func actionEnvironment(for id: PluginIdentifier) -> [String: String] {
        var environment: [String: String] = [
            "PATH": settings.pluginExecutableSearchPath.joined(separator: ":"),
            "HOME": NSHomeDirectory(),
            "LANG": "en_US.UTF-8",
            "LC_ALL": "en_US.UTF-8",
            "UDECK_API": String(PluginAPI.current),
            "UDECK_PLUGIN_ID": id.rawValue,
        ]
        if let directory = plugin(withID: id)?.directory {
            environment["UDECK_PLUGIN_DIR"] = directory.path
        }
        if let tmp = ProcessInfo.processInfo.environment["TMPDIR"] { environment["TMPDIR"] = tmp }
        return environment
    }

    /// Resolves an action's command the same way a manifest's `run` is
    /// resolved: a path relative to the plugin's own folder, an absolute path,
    /// or a bare name on the configured search path — never on whatever `PATH`
    /// uDeck happened to inherit.
    private func resolve(command: String, for id: PluginIdentifier) -> URL? {
        guard let directory = plugin(withID: id)?.directory else { return nil }
        return try? discovery.resolveExecutable(command, in: directory).get()
    }

    // MARK: - The plugins folder

    /// The folder the operator drops plugins into, written the way they would
    /// say it rather than as an absolute path.
    public var pluginsDirectoryDisplayPath: String {
        let home = NSHomeDirectory()
        let path = paths.plugins.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    public func revealPluginsDirectory() {
        try? FileManager.default.createDirectory(at: paths.plugins, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([paths.plugins])
    }

    // MARK: - Persistence

    func saveLayout() {
        save(layoutStore, layout, named: "layout")
    }

    func savePluginSettings() {
        save(pluginSettingsStore, pluginSettings, named: "plugin settings")
    }

    func saveGrants() {
        save(grantsStore, grants, named: "permission decisions")
    }

    func save<T: Codable & Sendable>(_ store: JSONFileStore<T>, _ value: T, named name: String) {
        do {
            try store.save(value)
        } catch {
            record("could not save the \(name): \(error)")
        }
    }
}
