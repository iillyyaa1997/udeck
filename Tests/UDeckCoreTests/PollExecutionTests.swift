import Foundation
import Testing
@testable import UDeckCore

/// These run real child processes against the plugins in `examples/`.
///
/// Mocking the process layer here would test the mock. The claims worth
/// defending — that a producer cannot hang the panel, that a killed producer is
/// reported as killed rather than as crashed, that a producer printing garbage
/// is named as the culprit — are all claims about the actual process API.
@Suite("Running plugins", .serialized)
struct PollExecutionTests {
    let discovery = PluginDiscovery(searchPath: AppSettings().pluginExecutableSearchPath)
    let executor = PollExecutor()

    func example(_ name: String) -> DiscoveredPlugin {
        discovery.load(RepositoryExamples.plugin(name))
    }

    func poll(_ name: String, temp: TemporaryDirectory, settings: PluginSettings = PluginSettings()) async -> PollExecution {
        await executor.poll(
            plugin: example(name),
            grant: nil,
            enabled: true,
            settings: settings,
            paths: temp.paths,
            searchPath: AppSettings().pluginExecutableSearchPath,
            appearance: .dark,
            reason: .interval
        )
    }

    @Test("a working plugin produces a card")
    func helloCardProducesACard() async {
        let temp = TemporaryDirectory()
        guard case .card(let card) = await poll("hello-card", temp: temp) else {
            Issue.record("expected a card"); return
        }
        #expect(card.state == .ok)
        #expect(card.chip == "example")
        #expect(card.ttl == 30)
        #expect(card.rows.count == 8)
    }

    @Test("settings and host context reach the producer as environment variables")
    func environmentReachesTheProducer() async {
        let temp = TemporaryDirectory()
        var settings = PluginSettings()
        settings.set(.string("Privet"), for: "greeting", plugin: PluginIdentifier(rawValue: "hello-card")!)
        settings.set(.bool(false), for: "show_table", plugin: PluginIdentifier(rawValue: "hello-card")!)

        guard case .card(let card) = await poll("hello-card", temp: temp, settings: settings) else {
            Issue.record("expected a card"); return
        }
        guard case .text(let first) = card.rows.first else { Issue.record("expected a text row"); return }
        #expect(first.hasPrefix("Privet"))
        #expect(card.rows.count == 7, "the table row should be gone")

        guard case .keyValue(let appearance) = card.rows[1] else { Issue.record("expected a kv row"); return }
        #expect(appearance.value == "dark")
    }

    /// The claim this whole design rests on: there is no `timeout` binary on a
    /// stock macOS, so the host has to enforce the deadline. The fixture also
    /// ignores SIGTERM, so this proves the escalation to SIGKILL as well.
    @Test("a producer that hangs is killed by the host and reported as timed out")
    func hangingProducerIsKilled() async {
        let temp = TemporaryDirectory()
        let started = Date()
        guard case .failure(let failure) = await poll("slow-plugin", temp: temp) else {
            Issue.record("expected a failure"); return
        }
        let elapsed = Date().timeIntervalSince(started)
        #expect(failure.reason == .timedOut(after: 1))
        #expect(elapsed < 4, "the host should not wait much past the deadline, took \(elapsed)s")
        #expect(failure.reason.description.contains("did not answer"))
    }

    /// A producer polled every five seconds that leaked one background child
    /// per timeout would fill the process table within an hour.
    @Test("killing a hung producer also kills what it started")
    func hungProducerLeavesNothingBehind() async {
        let temp = TemporaryDirectory()
        let marker = "udeck-orphan-\(UUID().uuidString)"
        temp.writePlugin(folder: "leaky", manifest: """
        { "id": "leaky", "name": "Leaky", "version": "1.0.0", "api": 1, "kind": "poll",
          "run": ["./run.sh"], "interval": 5, "timeout": 1 }
        """, script: (name: "run.sh", body: """
        #!/bin/sh
        # A background child that outlives its parent, holding the pipe open.
        sh -c 'exec -a \(marker) sleep 120' &
        trap '' TERM
        while true; do sleep 3600; done
        """, executable: true))

        let outcome = await executor.poll(
            plugin: discovery.load(temp.url.appendingPathComponent("plugins/leaky")),
            grant: nil, enabled: true, settings: PluginSettings(), paths: temp.paths,
            searchPath: AppSettings().pluginExecutableSearchPath, appearance: .light, reason: .interval
        )
        guard case .failure(let failure) = outcome else { Issue.record("expected a failure"); return }
        #expect(failure.reason == .timedOut(after: 1))

        // Give the signals a moment to land, then look for survivors.
        try? await Task.sleep(nanoseconds: 500_000_000)
        let stillRunning = shellPidsMatching(marker)
        if !stillRunning.isEmpty { for pid in stillRunning { kill(pid, SIGKILL) } }
        #expect(stillRunning.isEmpty, "left \(stillRunning.count) orphaned processes behind")
    }

    private func shellPidsMatching(_ needle: String) -> [pid_t] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,command="]
        let pipe = Pipe()
        process.standardOutput = pipe
        try? process.run()
        let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .filter { $0.contains(needle) }
            .compactMap { pid_t($0.trimmingCharacters(in: .whitespaces).split(separator: " ").first ?? "") }
    }

    @Test("a producer printing something that is not a card is named as the culprit")
    func garbageIsReported() async {
        let temp = TemporaryDirectory()
        guard case .failure(let failure) = await poll("broken-card", temp: temp) else {
            Issue.record("expected a failure"); return
        }
        guard case .unparsableOutput(let detail) = failure.reason else {
            Issue.record("expected unparsable output, got \(failure.reason)"); return
        }
        #expect(detail.contains("exactly one key"))
        #expect(failure.diagnostics.contains("diagnostics look like"),
                "stderr belongs to the author and must be kept")
    }

    @Test("a producer that was never permitted is not run, and says why")
    func unpermittedPluginIsNotRun() async {
        let temp = TemporaryDirectory()
        temp.writePlugin(folder: "needy", manifest: """
        { "id": "needy", "name": "Needy", "version": "1.0.0", "api": 1, "kind": "poll",
          "run": ["./run.sh"], "interval": 5, "timeout": 2,
          "permissions": { "exec": ["kubectl"] } }
        """, script: (name: "run.sh", body: "#!/bin/sh\ntouch \"$UDECK_CACHE_DIR/ran\"\necho '{}'\n", executable: true))

        let plugin = discovery.load(temp.url.appendingPathComponent("plugins/needy"))
        let outcome = await executor.poll(
            plugin: plugin, grant: nil, enabled: true, settings: PluginSettings(),
            paths: temp.paths, searchPath: AppSettings().pluginExecutableSearchPath,
            appearance: .light, reason: .launch
        )
        guard case .failure(let failure) = outcome else { Issue.record("expected a failure"); return }
        guard case .notPermitted = failure.reason else {
            Issue.record("expected a permission failure, got \(failure.reason)"); return
        }
        #expect(!FileManager.default.fileExists(atPath: temp.paths.cache(forPlugin: plugin.manifest!.id).appendingPathComponent("ran").path),
                "the producer must not have run at all")
    }

    @Test("a producer that exits non-zero is reported with its status")
    func nonZeroExitIsReported() async {
        let temp = TemporaryDirectory()
        temp.writePlugin(folder: "angry", manifest: """
        { "id": "angry", "name": "Angry", "version": "1.0.0", "api": 1, "kind": "poll",
          "run": ["./run.sh"], "interval": 5, "timeout": 2 }
        """, script: (name: "run.sh", body: "#!/bin/sh\necho 'could not reach the thing' >&2\nexit 3\n", executable: true))

        let outcome = await executor.poll(
            plugin: discovery.load(temp.url.appendingPathComponent("plugins/angry")),
            grant: nil, enabled: true, settings: PluginSettings(), paths: temp.paths,
            searchPath: AppSettings().pluginExecutableSearchPath, appearance: .light, reason: .interval
        )
        guard case .failure(let failure) = outcome else { Issue.record("expected a failure"); return }
        #expect(failure.reason == .exited(code: 3))
        #expect(failure.diagnostics == "could not reach the thing")
    }

    @Test("a producer that prints nothing is reported as such, not as a blank card")
    func emptyOutputIsReported() async {
        let temp = TemporaryDirectory()
        temp.writePlugin(folder: "mute", manifest: """
        { "id": "mute", "name": "Mute", "version": "1.0.0", "api": 1, "kind": "poll",
          "run": ["./run.sh"], "interval": 5, "timeout": 2 }
        """, script: (name: "run.sh", body: "#!/bin/sh\nexit 0\n", executable: true))

        let outcome = await executor.poll(
            plugin: discovery.load(temp.url.appendingPathComponent("plugins/mute")),
            grant: nil, enabled: true, settings: PluginSettings(), paths: temp.paths,
            searchPath: AppSettings().pluginExecutableSearchPath, appearance: .light, reason: .interval
        )
        guard case .failure(let failure) = outcome else { Issue.record("expected a failure"); return }
        #expect(failure.reason == .emptyOutput)
    }

    /// Collecting output only after the child exits would deadlock on a full
    /// pipe buffer, turning "prints a lot" into "always times out".
    @Test("a producer printing more than a pipe buffer still delivers its card")
    func largeOutputIsNotADeadlock() async {
        let temp = TemporaryDirectory()
        temp.writePlugin(folder: "chatty", manifest: """
        { "id": "chatty", "name": "Chatty", "version": "1.0.0", "api": 1, "kind": "poll",
          "run": ["./run.sh"], "interval": 30, "timeout": 10 }
        """, script: (name: "run.sh", body: """
        #!/bin/sh
        # ~200 KB of log rows: several times the 64 KB pipe buffer.
        printf '{"rows":[{"log":['
        i=0
        while [ $i -lt 2000 ]; do
          [ $i -gt 0 ] && printf ','
          printf '"%s"' "line $i ------------------------------------------------------------------------------------"
          i=$((i + 1))
        done
        printf ']}]}\\n'
        """, executable: true))

        let outcome = await executor.poll(
            plugin: discovery.load(temp.url.appendingPathComponent("plugins/chatty")),
            grant: nil, enabled: true, settings: PluginSettings(), paths: temp.paths,
            searchPath: AppSettings().pluginExecutableSearchPath, appearance: .light, reason: .interval
        )
        guard case .card(let card) = outcome else {
            Issue.record("expected a card, got \(outcome)"); return
        }
        guard case .log(let lines) = card.rows.first else { Issue.record("expected a log row"); return }
        #expect(lines.count == 2000)
    }

    @Test("a producer that never stops printing is stopped at the output limit")
    func runawayOutputIsStopped() async {
        let temp = TemporaryDirectory()
        temp.writePlugin(folder: "runaway", manifest: """
        { "id": "runaway", "name": "Runaway", "version": "1.0.0", "api": 1, "kind": "poll",
          "run": ["./run.sh"], "interval": 30, "timeout": 20 }
        """, script: (name: "run.sh", body: "#!/bin/sh\nwhile true; do printf 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'; done\n", executable: true))

        var runner = ProcessRunner()
        runner.maximumOutputBytes = 200_000
        let executor = PollExecutor(runner: runner)
        let started = Date()
        let outcome = await executor.poll(
            plugin: discovery.load(temp.url.appendingPathComponent("plugins/runaway")),
            grant: nil, enabled: true, settings: PluginSettings(), paths: temp.paths,
            searchPath: AppSettings().pluginExecutableSearchPath, appearance: .light, reason: .interval
        )
        guard case .failure(let failure) = outcome else { Issue.record("expected a failure"); return }
        guard case .outputLimitExceeded = failure.reason else {
            Issue.record("expected the output limit, got \(failure.reason)"); return
        }
        #expect(Date().timeIntervalSince(started) < 10, "the limit should bite well before the timeout")
    }

    @Test("the producer's environment is built, not inherited")
    func environmentIsNotInherited() {
        let temp = TemporaryDirectory()
        let plugin = example("hello-card")
        let environment = executor.environment(
            for: plugin.manifest!, plugin: plugin, settings: PluginSettings(),
            cacheDirectory: temp.url, searchPath: ["/usr/bin"], appearance: .dark, reason: .manual
        )
        #expect(environment["PATH"] == "/usr/bin")
        #expect(environment["UDECK_API"] == "1")
        #expect(environment["UDECK_APPEARANCE"] == "dark")
        #expect(environment["UDECK_REFRESH_REASON"] == "manual")
        #expect(environment["UDECK_PLUGIN_ID"] == "hello-card")
        // Whatever the launching shell had must not leak into a third-party plugin.
        #expect(environment["UDECK_TEST_MARKER"] == nil)
        #expect(environment["UDECK_SETTING_GREETING"] == "\"Hello\"")
    }
}

@Suite("Settings and layout files")
struct StoreTests {
    @Test("a missing file is a first run, not an error")
    func missingFileIsNil() throws {
        let temp = TemporaryDirectory()
        let store = JSONFileStore<AppSettings>(url: temp.paths.settingsFile)
        #expect(try store.load() == nil)
    }

    @Test("settings survive a round trip")
    func roundTrip() throws {
        let temp = TemporaryDirectory()
        let store = JSONFileStore<AppSettings>(url: temp.paths.settingsFile)
        var settings = AppSettings()
        settings.density = .cozy
        settings.gesture.dwellDuration = 0.4
        try store.save(settings)
        #expect(try store.load() == settings)
    }

    /// A settings file written by an older build is missing keys a newer one
    /// knows about. Failing the whole file over that would throw away every
    /// other setting the operator had chosen.
    @Test("a settings file from an older build loads, filling in what it lacks")
    func partialSettingsFileLoads() throws {
        let temp = TemporaryDirectory()
        try Data("""
        { "version": 1, "density": "compact", "gesture": { "dwellDuration": 0.5 } }
        """.utf8).write(to: temp.paths.settingsFile)

        let loaded = try JSONFileStore<AppSettings>(url: temp.paths.settingsFile).load()
        #expect(loaded?.density == .compact)
        #expect(loaded?.gesture.dwellDuration == 0.5)
        #expect(loaded?.gesture.reopenCooldown == GestureTuning().reopenCooldown)
        #expect(loaded?.panel.peekHeight == PanelMetrics().peekHeight)
    }

    /// Quietly replacing a corrupt file with defaults would destroy the
    /// operator's arrangement and never mention it.
    @Test("a corrupt file is reported rather than silently replaced")
    func corruptFileThrows() throws {
        let temp = TemporaryDirectory()
        try Data("{ this is not json".utf8).write(to: temp.paths.layoutFile)
        let store = JSONFileStore<DeckLayout>(url: temp.paths.layoutFile)
        #expect(throws: JSONFileStore<DeckLayout>.StoreError.self) { _ = try store.load() }

        // …and can be set aside deliberately, keeping the evidence.
        let moved = try store.quarantine()
        #expect(FileManager.default.fileExists(atPath: moved.path))
        #expect(try store.load() == nil)
    }

    @Test("a value of the wrong type is an error, not a silent default")
    func wrongTypeThrows() throws {
        let temp = TemporaryDirectory()
        try Data(#"{ "version": 1, "density": 7 }"#.utf8).write(to: temp.paths.settingsFile)
        #expect(throws: JSONFileStore<AppSettings>.StoreError.self) {
            _ = try JSONFileStore<AppSettings>(url: temp.paths.settingsFile).load()
        }
    }

    @Test("plugin settings are keyed by plugin and forgotten with it")
    func pluginSettingsLifecycle() {
        let id = PluginIdentifier(rawValue: "p")!
        var settings = PluginSettings()
        let rows = SettingDeclaration(key: "rows", type: .int, label: "Rows",
                                      defaultValue: .int(8), minimum: 1, maximum: 20)
        #expect(settings.value(of: rows, for: id) == .int(8))
        settings.set(.int(40), for: "rows", plugin: id)
        #expect(settings.value(of: rows, for: id) == .int(20), "stored values are clamped on read")
        #expect(settings.isEnabled(id))
        settings.setEnabled(false, for: id)
        #expect(!settings.isEnabled(id))
        settings.forget(id)
        #expect(settings.isEnabled(id))
        #expect(settings.value(of: rows, for: id) == .int(8))
    }

    @Test("the plugins root can be moved with an environment variable")
    func pathsAreRelocatable() {
        let paths = UDeckPaths.fromEnvironment(["UDECK_HOME": "/tmp/somewhere"])
        #expect(paths.root.path == "/tmp/somewhere")
        #expect(paths.plugins.path == "/tmp/somewhere/plugins")

        let fallback = UDeckPaths.fromEnvironment([:], home: URL(fileURLWithPath: "/Users/x"))
        #expect(fallback.root.path == "/Users/x/.udeck")
    }
}
