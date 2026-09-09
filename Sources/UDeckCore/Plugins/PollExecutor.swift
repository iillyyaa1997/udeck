import Foundation

/// Why a poll is happening. Passed to the producer so it can, for instance,
/// skip an expensive computation on an automatic refresh but do it when the
/// operator asked.
public enum RefreshReason: String, Sendable {
    case launch
    case interval
    case manual
}

/// One attempt to get a card out of a plugin.
public enum PollExecution: Sendable, Equatable {
    case card(Card)

    /// The producer printed a complete card and then overran its deadline.
    ///
    /// Both halves matter. Throwing the card away because the run was killed
    /// wastes data the operator can use — and a producer that prints its card
    /// and *then* does something slow is a common shape, so this was measured
    /// happening in most runs at the deadline. Hiding the overrun would be the
    /// opposite mistake: a producer that is always killed would look healthy.
    case lateCard(Card, PluginFailure)

    case failure(PluginFailure)
}

/// Runs one `poll` plugin once, and turns whatever happened into either a card
/// or a legible failure.
///
/// Every path out of here produces something the operator can read. A producer
/// that hangs, crashes, prints nothing, prints garbage or was never permitted
/// each yields a different message — because "this card is not updating" with no
/// reason attached is the state in which someone stops trusting the whole panel.
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

        let cacheDirectory = paths.cache(forPlugin: manifest.id)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)

        let result = await runner.run(
            executable: executable,
            arguments: Array(manifest.run.dropFirst()),
            workingDirectory: plugin.directory,
            environment: environment(
                for: manifest,
                plugin: plugin,
                settings: settings,
                cacheDirectory: cacheDirectory,
                searchPath: searchPath,
                appearance: appearance,
                reason: reason,
                language: language
            ),
            timeout: manifest.timeout ?? 0
        )

        let diagnostics = String(decoding: result.standardError, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        switch result.termination {
        case .timedOut(let seconds):
            let failure = PluginFailure(reason: .timedOut(after: seconds), diagnostics: diagnostics, occurredAt: now)
            // It may have finished saying what it had to say before it hung.
            if case .card(let card) = PollExecution(parsing: result.standardOutput, diagnostics: diagnostics, now: now) {
                return .lateCard(card, failure)
            }
            return .failure(failure)
        case .outputLimitExceeded(let bytes):
            return .failure(PluginFailure(reason: .outputLimitExceeded(bytes: bytes), diagnostics: diagnostics, occurredAt: now))
        case .launchFailed(let detail):
            return .failure(PluginFailure(reason: .launchFailed(detail), diagnostics: diagnostics, occurredAt: now))
        case .signalled(let signal):
            return .failure(PluginFailure(reason: .signalled(signal: signal), diagnostics: diagnostics, occurredAt: now))
        case .exited(let code) where code != 0:
            return .failure(PluginFailure(reason: .exited(code: code), diagnostics: diagnostics, occurredAt: now))
        case .exited:
            break
        }

        return .init(parsing: result.standardOutput, diagnostics: diagnostics, now: now)
    }

    /// The environment a producer runs in.
    ///
    /// Built from scratch rather than inherited. uDeck can be launched from
    /// Finder, from a shell or by launchd, each with a different environment,
    /// and a plugin that works when started one way and not another is close to
    /// impossible to debug. Building it explicitly also means a third-party
    /// plugin never sees whatever secrets happen to be in the launching shell.
    func environment(
        for manifest: PluginManifest,
        plugin: DiscoveredPlugin,
        settings: PluginSettings,
        cacheDirectory: URL,
        searchPath: [String],
        appearance: Appearance,
        reason: RefreshReason,
        language: String
    ) -> [String: String] {
        var environment: [String: String] = [
            "PATH": searchPath.joined(separator: ":"),
            "HOME": NSHomeDirectory(),
            // Producers print human text; without a UTF-8 locale a runtime can
            // fall back to ASCII and mangle everything non-Latin.
            "LANG": "en_US.UTF-8",
            "LC_ALL": "en_US.UTF-8",
            "UDECK_API": String(PluginAPI.current),
            "UDECK_PLUGIN_ID": manifest.id.rawValue,
            "UDECK_PLUGIN_DIR": plugin.directory.path,
            "UDECK_CACHE_DIR": cacheDirectory.path,
            "UDECK_APPEARANCE": appearance.rawValue,
            "UDECK_REFRESH_REASON": reason.rawValue,
            // The language the panel is speaking, so a producer can answer in
            // it. `LANG` and `LC_ALL` above stay pinned to a UTF-8 locale and
            // are not this: they exist so a runtime prints UTF-8 rather than
            // mangling anything non-Latin, and changing them to carry the
            // language would put that guarantee at the mercy of which locales
            // happen to be generated on the machine.
            "UDECK_LANG": language,
        ]
        if let tmp = ProcessInfo.processInfo.environment["TMPDIR"] { environment["TMPDIR"] = tmp }
        environment.merge(settings.environment(for: manifest)) { _, new in new }
        return environment
    }
}

/// Whether the panel is currently drawn light or dark. Passed to producers so a
/// card can pick colours that work, without each one guessing.
public enum Appearance: String, Sendable {
    case light
    case dark
}

extension PollExecution {
    init(parsing stdout: Data, diagnostics: String, now: Date) {
        let trimmed = String(decoding: stdout, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            self = .failure(PluginFailure(reason: .emptyOutput, diagnostics: diagnostics, occurredAt: now))
            return
        }
        do {
            let card = try JSONDecoder().decode(Card.self, from: Data(trimmed.utf8))
            // Bounded before anything tries to draw it: the byte cap on a
            // producer's output is the wrong unit for what actually hurts.
            self = .card(card.withinDrawingLimits())
        } catch {
            self = .failure(PluginFailure(
                reason: .unparsableOutput(PluginDiscovery.describe(error)),
                diagnostics: diagnostics,
                occurredAt: now
            ))
        }
    }
}
