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
    public private(set) var layout: DeckLayout
    public private(set) var plugins: [DiscoveredPlugin] = []
    public private(set) var snapshots: [String: PluginSnapshot] = [:]
    public private(set) var grants: PermissionGrants
    public private(set) var pluginSettings: PluginSettings

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
    private func record(_ description: String) {
        DeckLog.plugins.error("\(description, privacy: .public)")
        guard !problems.contains(description) else { return }
        problems.append(description)
        if problems.count > 10 { problems.removeFirst(problems.count - 10) }
    }

    /// Set by the shell so the model knows whether anybody is looking.
    public var panelIsVisible = false {
        didSet { if panelIsVisible != oldValue { visibilityChanged() } }
    }

    public var appearance: Appearance = .dark

    /// Told after the operator changes a setting, so the shell can rebuild
    /// anything that was created with one.
    public var onSettingsChanged: ((AppSettings) -> Void)?

    private let paths: UDeckPaths
    private let executor: PollExecutor
    private var pollTasks: [String: Task<Void, Never>] = [:]

    private var settingsStore: JSONFileStore<AppSettings> { .init(url: paths.settingsFile) }
    private var layoutStore: JSONFileStore<DeckLayout> { .init(url: paths.layoutFile) }
    private var grantsStore: JSONFileStore<PermissionGrants> { .init(url: paths.grantsFile) }
    private var pluginSettingsStore: JSONFileStore<PluginSettings> { .init(url: paths.pluginSettingsFile) }

    public init(paths: UDeckPaths = .fromEnvironment(), executor: PollExecutor = PollExecutor()) {
        self.paths = paths
        self.executor = executor

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
        layout = load(JSONFileStore<DeckLayout>(url: paths.layoutFile), default: DeckLayout.firstRun()).normalized()
        grants = load(JSONFileStore<PermissionGrants>(url: paths.grantsFile), default: PermissionGrants())
        pluginSettings = load(JSONFileStore<PluginSettings>(url: paths.pluginSettingsFile), default: PluginSettings())
        self.problems = problems

        for directory in paths.directoriesToCreate {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    // MARK: - Plugins

    public func discoverPlugins() {
        let discovery = PluginDiscovery(searchPath: settings.pluginExecutableSearchPath)
        plugins = discovery.scan(paths.plugins)

        let installed = Set(plugins.compactMap { $0.manifest?.id })
        let orphaned = layout.pruneWindows(keepingPlugins: installed)
        if !orphaned.isEmpty {
            record(
                "removed windows for plugins that are no longer installed: "
                + orphaned.map(\.rawValue).joined(separator: ", ")
            )
            saveLayout()
        }
        restartPolling()
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

        guard panelIsVisible || settings.pollWhileCollapsed else { return }

        for plugin in plugins {
            guard let manifest = plugin.manifest, manifest.kind == .poll,
                  placedPluginIDs.contains(manifest.id),
                  launchDecision(for: manifest.id).isAllowed,
                  let interval = manifest.interval, interval > 0
            else { continue }

            pollTasks[manifest.id.rawValue] = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: Seconds.nanoseconds(interval))
                    guard !Task.isCancelled else { return }
                    await self?.poll(plugin, reason: .interval)
                }
            }
        }
    }

    /// Runs everything once, now.
    public func refreshAll(reason: RefreshReason) {
        for plugin in plugins where plugin.manifest?.kind == .poll {
            guard let id = plugin.manifest?.id, placedPluginIDs.contains(id) else { continue }
            Task { await poll(plugin, reason: reason) }
        }
    }

    public func refresh(_ id: PluginIdentifier) {
        guard let plugin = plugin(withID: id) else { return }
        Task { await poll(plugin, reason: .manual) }
    }

    private func poll(_ plugin: DiscoveredPlugin, reason: RefreshReason) async {
        guard let id = plugin.manifest?.id else { return }
        let outcome = await executor.poll(
            plugin: plugin,
            grant: grants[id],
            enabled: pluginSettings.isEnabled(id),
            settings: pluginSettings,
            paths: paths,
            searchPath: settings.pluginExecutableSearchPath,
            appearance: appearance,
            reason: reason
        )

        var snapshot = snapshots[id.rawValue] ?? PluginSnapshot(pluginID: id)
        switch outcome {
        case .card(let card): snapshot.record(card: card, at: Date())
        case .failure(let failure): snapshot.record(failure: failure)
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
        layout.removeWindow(windowID, from: tabID)
        saveLayout()
        restartPolling()
    }

    public func place(windowID: UUID, in tabID: UUID, column: Int, row: Int, width: Int? = nil, height: Int? = nil) {
        layout.place(windowID: windowID, in: tabID, column: column, row: row, width: width, height: height)
        saveLayout()
    }

    // MARK: - Settings and permissions

    public func update(settings newValue: AppSettings) {
        settings = newValue
        save(settingsStore, newValue, named: "settings")
        restartPolling()
        onSettingsChanged?(newValue)
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
        guard PermissionGate.mayRun(action, grant: grants[id]) else {
            return "\(action.run.first ?? "that command") is not one of the commands \(id) was allowed to run"
        }
        guard let executable = resolve(command: action.run[0], for: id) else {
            return "\(action.run[0]) was not found"
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = Array(action.run.dropFirst())
        process.currentDirectoryURL = plugin(withID: id)?.directory
        // Built, not inherited — the same rule as a producer's environment, and
        // for the same reason. This is the one path the documentation calls
        // host-mediated, so it is the last place that should quietly hand a
        // plugin whatever was in the shell that started uDeck.
        process.environment = actionEnvironment(for: id)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return "\(action.run[0]) could not be started: \(error.localizedDescription)"
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
        if command.hasPrefix("/") {
            let url = URL(fileURLWithPath: command)
            return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
        }
        if command.contains("/") {
            guard let directory = plugin(withID: id)?.directory.standardizedFileURL else { return nil }
            let url = directory.appendingPathComponent(command).standardizedFileURL
            guard url.path.hasPrefix(directory.path + "/"),
                  FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
            return url
        }
        for entry in settings.pluginExecutableSearchPath {
            let candidate = URL(fileURLWithPath: entry).appendingPathComponent(command)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
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

    private func saveLayout() {
        save(layoutStore, layout, named: "layout")
    }

    private func savePluginSettings() {
        save(pluginSettingsStore, pluginSettings, named: "plugin settings")
    }

    private func save<T: Codable & Sendable>(_ store: JSONFileStore<T>, _ value: T, named name: String) {
        do {
            try store.save(value)
        } catch {
            record("could not save the \(name): \(error)")
        }
    }
}
