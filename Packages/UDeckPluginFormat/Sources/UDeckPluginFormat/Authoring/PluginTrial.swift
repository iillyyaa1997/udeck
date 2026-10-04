#if canImport(Darwin)
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import Darwin

/// One run of a plugin as uDeck runs it, for its author: `udeck-plugin run`.
///
/// The same code as uDeck's, not a copy of it: the folder is loaded by
/// `PluginDiscovery`, the producer gets `PluginEnvironment.producer` in its own
/// folder, `ProcessRunner` runs it — its own process group, its `timeout`,
/// `SIGTERM` and then `SIGKILL`, the 1 MiB limit on standard output, the tail
/// of standard error it keeps — and `PollExecution` says what the run came
/// to. What is added is only what uDeck keeps to itself: what the producer
/// wrote to stderr, and how much of it was not kept, how long it took, and
/// what uDeck would have forgiven without a word (`CardReview`, output
/// dropped at the limit, and whether the run wrote into its own folder).
///
/// What uDeck asks the operator first is said, not asked: the run happens
/// without a grant, which is the point of trying a plugin before installing it.
public enum PluginTrial {
    public struct Options: Sendable {
        /// uDeck's folder: the plugin's cache is `<home>/cache/<id>`, its
        /// settings' values are read from `<home>/plugin-settings.json`, and
        /// the search path from `<home>/settings.json`. Nil is a new folder
        /// for this run alone, taken away after it, and the default search
        /// path.
        public var home: URL?
        public var language: String
        public var reason: RefreshReason
        /// Where the command was started from: `TMPDIR` for the producer, as
        /// uDeck hands it its own, and `CFFIXED_USER_HOME` and `HOME` for the
        /// home folder it is handed (`homes`).
        public var environment: [String: String]
        /// Where the account's home folder is: the producer's `HOME` is the
        /// one uDeck hands it — `NSHomeDirectory()`, the account's, not the
        /// shell's (`UserHomes.account(in:)`). The machine's own account
        /// database but in tests.
        public var homes: UserHomes
        public var runner: ProcessRunner

        public init(home: URL? = nil, language: String = "en", reason: RefreshReason = .interval,
                    environment: [String: String], homes: UserHomes = .system, runner: ProcessRunner = ProcessRunner()) {
            self.home = home
            self.language = language
            self.reason = reason
            self.environment = environment
            self.homes = homes
            self.runner = runner
        }
    }

    /// What one run came to.
    public struct Report: Sendable {
        public var plugin: DiscoveredPlugin
        public var manifest: PluginManifest
        /// The uDeck folder the run had, and whether it was made for it alone.
        public var home: URL
        public var homeIsTemporary: Bool
        /// What the producer was handed.
        public var environment: [String: String]
        public var result: ProcessRunResult
        /// What uDeck makes of the run: the card it draws, or the failure it
        /// shows.
        public var execution: PollExecution
        /// Worth knowing, and not wrong.
        public var notes: [String]
        /// What uDeck would forgive without a word.
        public var warnings: [String]
    }

    /// Why there was no run.
    public struct Refusal: Error, CustomStringConvertible {
        public var description: String
    }

    /// Loads the plugin folder `folder` and runs its producer once.
    public static func run(_ folder: URL, options: Options) async throws -> Report {
        var searchPath = PluginEnvironment.defaultSearchPath
        var searchPathNote: String?
        if let home = options.home {
            switch Self.searchPath(in: UDeckPaths(root: home)) {
            case .read(let path): searchPath = path
            case .notThere: break
            case .unreadable(let note): searchPathNote = note
            }
        }
        let discovery = PluginDiscovery(searchPath: searchPath, udeck: SemanticVersion(UDeckRelease.version))
        let plugin = discovery.load(folder)
        // What uDeck asks of a folder before it runs it, in the order it asks.
        guard let manifest = plugin.manifest, let executable = plugin.executable, plugin.isUsable else {
            let failure = PluginFailure(reason: .notLoadable(plugin.problems.filter(\.isFatal)))
            throw Refusal(description: "uDeck would not run it: \(failure.reason)")
        }
        guard manifest.kind == .poll else {
            let failure = PluginFailure(reason: .notLoadable([.manifest(.residentNotSupportedYet)]))
            throw Refusal(description: "uDeck would not run it: \(failure.reason)")
        }

        var notes: [String] = plugin.problems.map { "uDeck notes against the plugin: \($0)" }
        if let searchPathNote { notes.append(searchPathNote) }
        switch PermissionGate.launchDecision(for: manifest, grant: nil, enabled: true) {
        case .awaitingDecision(let pending):
            notes.append("uDeck asks before it first runs the plugin, and again for every new version: may it "
                         + pending.map(\.summary).joined(separator: ", ") + "? This run did not ask")
        default:
            break
        }

        let home: URL
        let homeIsTemporary = options.home == nil
        if let given = options.home {
            home = given
        } else {
            do {
                home = try ScratchFolder.make(ScratchFolder.runPrefix)
            } catch {
                throw Refusal(description: "could not make a folder for the run in \(ScratchFolder.home.path): \(error)")
            }
        }
        defer { if homeIsTemporary { try? FileManager.default.removeItem(at: home) } }
        let paths = UDeckPaths(root: home)
        let settings = try pluginSettings(in: paths)

        let cacheDirectory = paths.makeCache(forPlugin: manifest.id)
        let environment = PluginEnvironment.producer(
            manifest: manifest,
            directory: plugin.directory,
            settings: settings,
            cacheDirectory: cacheDirectory,
            searchPath: searchPath,
            appearance: .panel,
            reason: options.reason,
            language: options.language,
            home: Self.home(options),
            temporaryDirectory: options.environment["TMPDIR"]
        )

        let before = FolderSnapshot.of(plugin.directory)
        let now = Date()
        let result = await options.runner.run(producerOf: plugin, manifest: manifest, executable: executable,
                                              environment: environment)
        let after = FolderSnapshot.of(plugin.directory)
        let execution = PollExecution(result: result, now: now)

        var warnings: [String] = []
        if case .lateCard(_, let failure) = execution {
            warnings.append("the producer printed its card and then ran on past its timeout: uDeck shows the card, "
                            + "and counts a failure -- \(failure.reason)")
        }
        if case .card(let card) = PollExecution.read(result.standardOutput) {
            warnings += CardReview.forgiven(in: result.standardOutput)
            warnings += CardReview.cut(from: card)
            if let newer = CardReview.needsNewerUDeck(result.standardOutput, manifest: manifest) { warnings.append(newer) }
        }
        if let before, let after {
            let changes = before.changes(to: after)
            var parts: [String] = []
            if !changes.added.isEmpty { parts.append("added " + list(changes.added)) }
            if !changes.changed.isEmpty { parts.append("changed " + list(changes.changed)) }
            if !changes.removed.isEmpty { parts.append("removed " + list(changes.removed)) }
            if !parts.isEmpty {
                warnings.append("the producer wrote into its own folder -- \(parts.joined(separator: "; ")). Installed "
                                + "from a repository, the plugin would be Modified locally after every run; write into "
                                + "UDECK_CACHE_DIR instead")
            }
        } else {
            notes.append("the plugin's folder could not be read whole, before the run or after it, so whether the "
                         + "producer wrote into it is not known")
        }

        if let dropped = dropped(from: result, limit: options.runner.maximumOutputBytes) { warnings.append(dropped) }
        if result.standardErrorDropped > 0 {
            notes.append("uDeck keeps the last \(options.runner.standardErrorTail) bytes of a run's standard error; the "
                         + "\(result.standardErrorDropped) before them were not kept")
        }

        if case .card = execution, !result.standardError.isEmpty {
            notes.append("uDeck keeps the standard error of a run that printed a card, as of any run, and writes it into "
                         + "the plugin's run log when the plugin is a linked folder and the run log is on "
                         + "(logs/\(manifest.id.rawValue).log in uDeck's folder); Settings shows the standard error of a "
                         + "failed run only")
        }
        if let slow = slowness(duration: result.duration, timeout: manifest.timeout, execution: execution) {
            notes.append(slow)
        }

        return Report(plugin: plugin, manifest: manifest, home: home, homeIsTemporary: homeIsTemporary,
                      environment: environment, result: result, execution: execution, notes: notes,
                      warnings: warnings)
    }

    /// The `HOME` a producer is handed, as uDeck hands it: the account's home
    /// folder (`UserHomes.account(in:)`) — and with none of
    /// `CFFIXED_USER_HOME`, an account entry or `HOME`, `/var/empty`, where
    /// Foundation's `NSHomeDirectory()` falls back to
    /// (swift-foundation, String+Path.swift, `homeDirectoryPath()`).
    static func home(_ options: Options) -> String {
        options.homes.account(in: options.environment) ?? "/var/empty"
    }

    /// Said of a run uDeck drew a card from, and that took more than half of
    /// its timeout to: on a machine busier than the author's, the rest of it
    /// goes too.
    static func slowness(duration: TimeInterval, timeout: TimeInterval?, execution: PollExecution) -> String? {
        guard let timeout, timeout > 0, duration > timeout / 2, case .card = execution else { return nil }
        return "the run took more than half of its \(Seconds.fixed(timeout, places: 1)) s timeout"
    }

    /// Said when standard output went past the limit and nobody said so: the
    /// producer ended before uDeck's watch on the limit caught it, and uDeck
    /// kept the first `limit` bytes and let the rest go without a word. A run
    /// that was stopped for it has its failure say so instead. Standard error
    /// has no limit to go past: its tail is kept, and what came before it is a
    /// note (`run`), not something uDeck forgives.
    static func dropped(from result: ProcessRunResult, limit: Int) -> String? {
        guard result.standardOutputDropped > 0 else { return nil }
        if case .outputLimitExceeded = result.termination { return nil }
        let count = result.standardOutputDropped
        return "uDeck keeps \(limit) bytes of a run's standard output, and dropped the rest without a word: "
            + "\(count) byte\(count == 1 ? "" : "s")"
    }

    /// Where uDeck's settings file says a bare command is looked up.
    enum SearchPath: Equatable {
        /// `pluginExecutableSearchPath` in `settings.json`, as uDeck reads it.
        case read([String])
        /// No file, or no such key in it, or an empty list: uDeck's default.
        case notThere
        /// A file uDeck could not read either: uDeck runs plugins with the
        /// default while it is broken, and so does the run. Said as a note.
        case unreadable(String)
    }

    /// The search path uDeck runs plugins with, from `settings.json` in its
    /// folder — the one place uDeck keeps it — read as uDeck reads that key:
    /// a list of folders, and the default when it is absent or empty.
    ///
    /// Only that key is read. uDeck reads the whole file, and a value of the
    /// wrong type anywhere in it sends every setting back to its default, the
    /// search path too; that much of uDeck's settings is not this command's
    /// to judge.
    static func searchPath(in paths: UDeckPaths) -> SearchPath {
        struct Settings: Decodable { var pluginExecutableSearchPath: [String]? }
        let file = paths.settingsFile
        guard FileManager.default.fileExists(atPath: file.path) else { return .notThere }
        let data: Data
        do {
            data = try Data(contentsOf: file)
        } catch {
            return .unreadable("could not read \(file.path) (\(PluginDiscovery.explain(error))), so this run looked up "
                               + "commands on the default search path, as uDeck does while it cannot read its settings")
        }
        do {
            let path = try JSONDecoder().decode(Settings.self, from: data).pluginExecutableSearchPath ?? []
            return path.isEmpty ? .notThere : .read(path)
        } catch {
            return .unreadable("\(file.path) is not a settings file uDeck can read: "
                               + PluginDiscovery.describe(error, in: data, document: "the file")
                               + "; this run looked up commands on the default search path, as uDeck does while its "
                               + "settings cannot be read")
        }
    }

    /// The values the operator chose for the plugin's settings, as uDeck keeps
    /// them in `plugin-settings.json`; none — every setting at its default —
    /// when there is no such file.
    static func pluginSettings(in paths: UDeckPaths) throws -> PluginSettings {
        let file = paths.pluginSettingsFile
        guard FileManager.default.fileExists(atPath: file.path) else { return PluginSettings() }
        do {
            return try JSONDecoder().decode(PluginSettings.self, from: Data(contentsOf: file))
        } catch {
            throw Refusal(description: "could not read \(file.path): "
                          + PluginDiscovery.describe(error, in: try? Data(contentsOf: file), document: "the file"))
        }
    }

    /// `a, b and 3 more`.
    static func list(_ paths: [String]) -> String {
        let shown = paths.prefix(5).joined(separator: ", ")
        return paths.count > 5 ? "\(shown) and \(paths.count - 5) more" : shown
    }
}
#endif
