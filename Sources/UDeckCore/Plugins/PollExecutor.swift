import Foundation

/// Runs one `poll` plugin once, and turns whatever happened into either a card
/// or a legible failure.
///
/// Every path out of here produces something the operator can read. A producer
/// that hangs, crashes, prints nothing, prints garbage or was never permitted
/// each yields a different message — because "this card is not updating" with no
/// reason attached is the state in which someone stops trusting the whole panel.
///
/// What is uDeck's own is here: whether the plugin may run, and the parts of
/// its environment only this process knows. The rest is the format's — its
/// cache folder (`UDeckPaths.makeCache`), its environment
/// (`PluginEnvironment.producer`), the run (`ProcessRunner.run(producerOf:…)`)
/// and what the run came to (`PollExecution(result:now:)`) — and
/// `udeck-plugin run` does the same with the same code, so a plugin an author
/// tries in a terminal is run the way this runs it.
public struct PollExecutor: Sendable {
    public var runner: ProcessRunner

    public init(runner: ProcessRunner = ProcessRunner()) {
        self.runner = runner
    }

    public func poll(
        plugin: DiscoveredPlugin,
        grant: PluginGrant?,
        enabled: Bool,
        settings: PluginSettings,
        paths: UDeckPaths,
        searchPath: [String],
        appearance: Appearance,
        reason: RefreshReason,
        language: String,
        now: Date = Date()
    ) async -> PollExecution {
        // `isUsable` rather than "no problems at all": a translation that will
        // not parse is a note against the plugin, not a reason to refuse to run
        // it. See `DiscoveryProblem.isFatal`.
        guard let manifest = plugin.manifest, let executable = plugin.executable, plugin.isUsable else {
            return .failure(PluginFailure(reason: .notLoadable(plugin.problems.filter(\.isFatal)),
                                          occurredAt: now))
        }

        let decision = PermissionGate.launchDecision(for: manifest, grant: grant, enabled: enabled)
        guard decision.isAllowed else {
            return .failure(PluginFailure(reason: .notPermitted(decision), occurredAt: now))
        }

        guard manifest.kind == .poll else {
            return .failure(PluginFailure(reason: .notLoadable([.manifest(.residentNotSupportedYet)]),
                                          occurredAt: now))
        }

        let cacheDirectory = paths.makeCache(forPlugin: manifest.id)
        let result = await runner.run(producerOf: plugin, manifest: manifest, executable: executable, environment: environment(
            for: manifest,
            plugin: plugin,
            settings: settings,
            cacheDirectory: cacheDirectory,
            searchPath: searchPath,
            appearance: appearance,
            reason: reason,
            language: language
        ))
        return PollExecution(result: result, now: now)
    }

    /// The environment a producer runs in (`PluginEnvironment.producer`),
    /// with uDeck's own home folder and the temporary folder it was given.
    public func environment(
        for manifest: PluginManifest,
        plugin: DiscoveredPlugin,
        settings: PluginSettings,
        cacheDirectory: URL,
        searchPath: [String],
        appearance: Appearance,
        reason: RefreshReason,
        language: String
    ) -> [String: String] {
        PluginEnvironment.producer(
            manifest: manifest,
            directory: plugin.directory,
            settings: settings,
            cacheDirectory: cacheDirectory,
            searchPath: searchPath,
            appearance: appearance,
            reason: reason,
            language: language,
            home: NSHomeDirectory(),
            temporaryDirectory: ProcessInfo.processInfo.environment["TMPDIR"]
        )
    }
}
