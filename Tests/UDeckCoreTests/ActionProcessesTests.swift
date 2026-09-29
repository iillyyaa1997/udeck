import Darwin
import Foundation
import Testing
@testable import UDeckCore

/// A card's action that is still running when its plugin is quieted is ended —
/// politely, then not — before the plugin's folder is swapped or removed, and
/// the folder is never touched while anything of the plugin runs.
@Suite("Ending a plugin's card actions")
struct ActionProcessesTests {
    let temp = TemporaryDirectory()

    /// A shell that ignores `SIGTERM` and waits on a child of its own: only a
    /// `SIGKILL` to the whole group ends it.
    static let stubborn = ["-c", "trap '' TERM; /bin/sleep 60 & wait"]

    func start(_ actions: ActionProcesses, _ arguments: [String], plugin: String = "uptime",
               ended: @escaping @Sendable () -> Void = {}) throws {
        try actions.start(plugin: plugin, executable: URL(fileURLWithPath: "/bin/sh"), arguments: arguments,
                          workingDirectory: temp.url, environment: ["PATH": "/bin:/usr/bin"], ended: ended)
    }

    func waitFor(_ condition: () -> Bool, seconds: TimeInterval = 5) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline { await ActionProcesses.pause(0.02) }
        return condition()
    }

    @Test("an action that ignores SIGTERM is ended, and so is what it started")
    func stopEndsAStubbornGroup() async throws {
        let actions = ActionProcesses()
        let ended = Flag()
        try start(actions, Self.stubborn, ended: { ended.set() })
        await ActionProcesses.pause(0.2)
        #expect(actions.isRunning("uptime"))
        #expect(!actions.isRunning("other"), "another plugin has nothing running")

        let stopped = await actions.stop("uptime", grace: 0.5)
        #expect(stopped, "SIGTERM is ignored, so only the SIGKILL after it ends the group")
        #expect(!actions.isRunning("uptime"))
        #expect(await waitFor { ended.isSet }, "the caller is told it ended")
    }

    @Test("an action counts as running while anything it started still runs")
    func backgroundChildKeepsItRunning() async throws {
        let actions = ActionProcesses()
        try start(actions, ["-c", "/bin/sleep 30 &"])
        await ActionProcesses.pause(0.6)
        #expect(actions.isRunning("uptime"), "the shell has exited; the sleep it left behind has not")
        #expect(await actions.stop("uptime", grace: 0.5))
        #expect(!actions.isRunning("uptime"))
    }

    @Test("an action that ends by itself is not running, and is not signalled")
    func endsByItself() async throws {
        let actions = ActionProcesses()
        let ended = Flag()
        try start(actions, ["-c", "exit 0"], ended: { ended.set() })
        #expect(await waitFor { ended.isSet && !actions.isRunning("uptime") })
        #expect(await actions.stop("uptime", grace: 0.1), "nothing to stop")
    }

    @Test("settling waits for runs that end in time, and ends only the ones that do not")
    func settleEndsOnlyWhatOutlastsTheWait() async throws {
        let actions = ActionProcesses()
        let stopAsked = Flag()
        try start(actions, ["-c", "/bin/sleep 0.3"])
        let quick = await PluginQuiet.settle(
            wait: 5, andThen: 1,
            isRunning: { actions.isRunning("uptime") },
            stopActions: { stopAsked.set(); await actions.stop("uptime", grace: 0.5) })
        #expect(quick)
        #expect(!stopAsked.isSet, "an action that ends within the wait is not ended")

        try start(actions, Self.stubborn)
        let started = Date()
        let settled = await PluginQuiet.settle(
            wait: 0.5, andThen: 3,
            isRunning: { actions.isRunning("uptime") },
            stopActions: { stopAsked.set(); await actions.stop("uptime", grace: 0.5) })
        #expect(settled, "the action that outlasted the wait was ended")
        #expect(stopAsked.isSet)
        #expect(!actions.isRunning("uptime"))
        #expect(Date().timeIntervalSince(started) < 3, "and nothing waited out the whole of andThen")
    }

    // MARK: - Quieting, decided whole (Q117)

    /// What `DeckModel.quiet` hands the swap: a card action that outlives the
    /// wait for polls is ended, and the answer is asked of the runs, not assumed.
    @Test("quieting ends a card action that outlives the wait for polls, and says so only once it has ended")
    func quietEndsWhatOutlivesTheWait() async throws {
        let actions = ActionProcesses()
        try start(actions, Self.stubborn)
        await ActionProcesses.pause(0.2)
        let started = Date()
        let quiet = await PluginQuiet.quiet("uptime", pollTimeout: 0, actions: actions, grace: 0.3,
                                            isRunning: { actions.isRunning("uptime") })
        #expect(quiet, "the action was ended, and nothing of the plugin runs")
        #expect(!actions.isRunning("uptime"))
        #expect(Date().timeIntervalSince(started) >= 1.5, "the polls' wait came first: \(Date().timeIntervalSince(started))")
    }

    @Test("quieting waits out a run that ends within a poll's timeout, and ends nothing")
    func quietWaitsForAPollsTimeout() async throws {
        let actions = ActionProcesses()
        let finished = temp.url.appendingPathComponent("finished")
        // Longer than the half-second grace alone, shorter than the timeout
        // and the grace after it.
        try start(actions, ["-c", "/bin/sleep 1.5; : > \(finished.path)"])
        let quiet = await PluginQuiet.quiet("uptime", pollTimeout: 1, actions: actions, grace: 0.3,
                                            isRunning: { actions.isRunning("uptime") })
        #expect(quiet)
        #expect(FileManager.default.fileExists(atPath: finished.path), "the run was ended instead of waited for")
        #expect(await PluginQuiet.quiet("uptime", pollTimeout: nil, actions: actions, isRunning: { false }))
    }

    @Test("quieting a plugin something of which will not end says so, and the folder must stay")
    func quietSaysWhenSomethingWillNotEnd() async {
        let actions = ActionProcesses()
        let asked = Flag()
        let quiet = await PluginQuiet.quiet("uptime", pollTimeout: 0, actions: actions, grace: 0.1,
                                            isRunning: { asked.set(); return true })
        #expect(!quiet)
        #expect(asked.isSet)
    }

    // MARK: - The folder is not touched under a live process

    func installer(_ repository: FakeRepository, trash: TestTrash, renames: FolderRenames = .system) -> PluginInstaller {
        PluginInstaller(paths: temp.paths, discovery: PluginDiscovery(searchPath: ["/bin", "/usr/bin"],
                                                                      udeck: SemanticVersion("0.5.0")),
                        trash: trash, renames: renames, fetch: FetchLog(repository).fetch,
                        now: { Date(timeIntervalSince1970: 1_790_000_000) })
    }

    func request(_ repository: FakeRepository, _ operation: InstallRequest.Operation, version: String) -> InstallRequest {
        InstallRequest(operation: operation, id: PluginIdentifier(rawValue: "uptime")!, repository: .official,
                       ref: PluginRef(name: "main"), commit: repository.commit, folder: repository.plugin("uptime"),
                       version: version, headCommit: repository.commit)
    }

    var live: URL { temp.paths.plugins.appendingPathComponent("uptime", isDirectory: true) }

    /// Q117: an action still running when the plugin is quieted is ended, and
    /// only then is the folder swapped — never under a live process.
    @Test("an update ends a card action still running in the folder, and swaps only after it has ended")
    func updateEndsTheActionFirst() async throws {
        let trash = TestTrash(in: temp.url)
        let first = FakeRepository.withUptime(version: "1.0.0")
        let installer1 = installer(first, trash: trash)
        try installer1.commit(try await installer1.stage(request(first, .install, version: "1.0.0")))

        let actions = ActionProcesses()
        try actions.start(plugin: "uptime", executable: URL(fileURLWithPath: "/bin/sh"), arguments: Self.stubborn,
                          workingDirectory: live, environment: [:], ended: {})
        await ActionProcesses.pause(0.2)

        let runningAtTheSwap = Flag()
        let watched = FolderRenames(exchange: { from, to in
            if actions.isRunning("uptime") { runningAtTheSwap.set() }
            return FolderRenames.system.exchange(from, to)
        }, exclusive: FolderRenames.system.exclusive)
        var second = FakeRepository.withUptime(version: "1.1.0")
        second.commit = String(repeating: "d", count: 40)
        let updater = installer(second, trash: trash, renames: watched)
        let staged = try await updater.stage(request(second, .update, version: "1.1.0"))
        let record = try await updater.commit(staged, once: {
            await PluginQuiet.settle(wait: 0.3, andThen: 3, isRunning: { actions.isRunning("uptime") },
                                     stopActions: { await actions.stop("uptime", grace: 0.5) })
        })
        #expect(record.version == "1.1.0")
        #expect(!runningAtTheSwap.isSet, "the folder was swapped while the action was still running in it")
        #expect(!actions.isRunning("uptime"))
        #expect(try GitHash.tree(ofDirectoryAt: live) == second.treeID("plugins/uptime"))
    }

    @Test("when something of the plugin will not end, the folder is left exactly as it was")
    func stillRunningLeavesTheFolder() async throws {
        let trash = TestTrash(in: temp.url)
        let first = FakeRepository.withUptime(version: "1.0.0")
        let installer1 = installer(first, trash: trash)
        try installer1.commit(try await installer1.stage(request(first, .install, version: "1.0.0")))
        let before = try GitHash.tree(ofDirectoryAt: live)

        var second = FakeRepository.withUptime(version: "1.1.0")
        second.commit = String(repeating: "d", count: 40)
        let updater = installer(second, trash: trash)
        let staged = try await updater.stage(request(second, .update, version: "1.1.0"))
        await #expect(throws: InstallError.stillRunning(id: "uptime")) {
            try await updater.commit(staged, once: { false })
        }
        #expect(try GitHash.tree(ofDirectoryAt: live) == before, "nothing was swapped")
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: temp.paths.staging.path)) ?? []).isEmpty,
                "the staged copy went")
        #expect(trash.names.isEmpty)

        await #expect(throws: InstallError.stillRunning(id: "uptime")) {
            _ = try await updater.beginRemoval(PluginIdentifier(rawValue: "uptime")!, once: { false })
        }
        #expect(FileManager.default.fileExists(atPath: live.path), "nor removed")
    }
}

/// A flag set from any thread.
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}
