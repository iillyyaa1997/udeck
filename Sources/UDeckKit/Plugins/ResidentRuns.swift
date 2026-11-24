import Foundation
import UDeckAgents
import UDeckCore

/// Where resident plugins' processes run: in a helper that keeps them through
/// uDeck quitting, crashing or updating (`udeck-agentd`), so that a
/// conversation goes on and uDeck finds it again. Without one they run as
/// uDeck's own children, and go with it.
@MainActor
public protocol ResidentLauncher: AnyObject {
    /// Starts the process `name` — or, kept running since uDeck last ran,
    /// attaches to it from now on, nothing it said before said again.
    /// Answers its channel, and whether it was already running.
    func launch(name: String, executable: URL, arguments: [String], environment: [String: String],
                directory: URL) async throws -> (channel: any AgentChannel, attached: Bool)
    /// Stops the process `name` and forgets it.
    func stop(name: String) async
    /// The names of the processes it keeps whose names start with `prefix`.
    func kept(prefix: String) async -> [String]
}

/// The resident plugins that are running: one long-lived process each, its
/// stdout read line by line as `ResidentMessage`s, its stdin written with
/// `ResidentEvent`s.
///
/// uDeck owns spawn, stop and restart; the plugin owns what its card says. A
/// plugin that exits is started again after a pause that grows while it keeps
/// failing — never in a tight loop.
@MainActor
final class ResidentRuns {
    struct Wanted: Equatable {
        let id: PluginIdentifier
        let executable: URL
        let arguments: [String]
        let environment: [String: String]
        let directory: URL
        /// What a change of means the process starts again (its tree, its grant).
        let basis: String

        /// The process's name in the helper: the plugin's, and a digest of
        /// what it runs — the program as it is on disk now, its arguments,
        /// its environment, its folder — so a process left running by an
        /// earlier uDeck is taken back only when it is the one wanted now.
        /// Not `basis`: a tree's hash lands after uDeck starts, and a process
        /// kept running must not be taken for another for want of it.
        var processName: String {
            let file = try? FileManager.default.attributesOfItem(atPath: executable.path)
            let size = (file?[.size] as? NSNumber)?.int64Value ?? -1
            let modified = (file?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            var parts = [executable.path, "\(size)", "\(modified)", directory.path] + arguments
            parts += environment.keys.sorted().map { $0 + "=" + (environment[$0] ?? "") }
            var hash: UInt64 = 0xcbf29ce484222325
            for byte in parts.joined(separator: "\u{1F}").utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
            return Self.prefix + id.rawValue + "." + String(hash, radix: 16)
        }

        static let prefix = "resident."
    }

    /// One place a plugin's card is shown in, as its plugin is told of it.
    struct View: Equatable {
        /// The window's or the place's id: the plugin's `view`.
        let id: String
        var columns: Int
        var rows: Int
        /// `card`, `tab`, `window` or `mini`.
        var place: String
        /// What the plugin last said it shows there.
        var keep: String?

        var about: ResidentEvent.About { .init(view: id, place: place, keep: keep) }
    }

    private final class Run {
        let wanted: Wanted
        var channel: (any AgentChannel)?
        /// Names the current start: what an earlier one's reader or launch
        /// says comes too late.
        var token = UUID()
        var reader: Task<Void, Never>?
        var failures = 0
        /// Every place its card is shown in, its first window on the board
        /// first.
        var views: [View]
        /// The places the running process has been told of, and as what.
        var told: [View] = []
        /// Whether the running process named a place (`CardPlace`): until it
        /// does, it is told of its first window only, as a plugin was before
        /// places had names — a second window of it on the board, or a place
        /// apart, would only confuse it.
        var speaksOfPlaces = false
        var stopped = false

        init(wanted: Wanted, views: [View]) {
            self.wanted = wanted
            self.views = views
        }

        /// The places it should have been told of.
        var toTell: [View] { speaksOfPlaces ? views : Array(views.prefix(1)) }
    }

    private var runs: [PluginIdentifier: Run] = [:]
    private struct Pending: Hashable {
        let plugin: PluginIdentifier
        let view: String?
    }
    /// The newest card a plugin printed for each of its places and uDeck has
    /// not drawn yet.
    private var pendingCards: [Pending: (Card, CardPlace)] = [:]
    private var lastDrawn: [PluginIdentifier: ContinuousClock.Instant] = [:]
    private var drawScheduled: Set<PluginIdentifier> = []
    /// However fast a plugin prints, its card is redrawn at most this often —
    /// the newest one wins — so a plugin cannot keep the panel busy.
    static let cardInterval: Duration = .milliseconds(100)
    /// What a running plugin said: the model records cards, posts
    /// notifications, asks for folders.
    var onMessage: (PluginIdentifier, ResidentMessage) -> Void = { _, _ in }
    /// The plugins whose process is running changed: a running one's card
    /// does not age while it is quiet (`PluginSnapshot.presentation`).
    var onLive: (Set<PluginIdentifier>) -> Void = { _ in }
    var language: () -> String = { "en" }
    /// Where the processes run; nil: as uDeck's own children.
    var launcher: ResidentLauncher?
    /// How long after its first start uDeck looks for processes kept running
    /// that nobody wants any more.
    static let settling: Duration = .seconds(30)
    /// Whether the helper's processes nobody wants any more were looked for
    /// since uDeck started: a plugin removed while uDeck was away.
    private var sweptKept = false

    /// Starts what is wanted and not running, stops what runs and is no longer
    /// wanted (or changed), and tells running ones of their places: a new
    /// one's `hello`, a changed one's `size`, a gone one's `closed`.
    func reconcile(_ wanted: [Wanted], views: [PluginIdentifier: [View]]) {
        let wantedIDs = Set(wanted.map(\.id))
        for (id, run) in runs where !wantedIDs.contains(id) || wanted.first(where: { $0.id == id }) != run.wanted {
            stop(run)
            runs[id] = nil
        }
        defer { onLive(live) }
        // A plugin taken off the panel, switched off or removed while uDeck
        // was away: its process is stopped once uDeck has settled what it
        // runs — a plugin waits for its decision to load, its tree to hash.
        if !sweptKept, let launcher {
            sweptKept = true
            Task { [weak self] in
                try? await Task.sleep(for: Self.settling)
                guard let self else { return }
                let names = Set(runs.values.filter { !$0.stopped }.map(\.wanted.processName))
                for name in await launcher.kept(prefix: Wanted.prefix) where !names.contains(name) {
                    DeckLog.plugins.notice("stopping \(name, privacy: .public), kept by the helper and wanted no more")
                    await launcher.stop(name: name)
                }
            }
        }
        for item in wanted {
            let places = views[item.id] ?? []
            if let run = runs[item.id] {
                run.views = places
                tell(run)
                continue
            }
            let run = Run(wanted: item, views: places)
            runs[item.id] = run
            start(run)
        }
    }

    /// Tells the running process of the places it has not been told of as
    /// they are now.
    private func tell(_ run: Run) {
        guard let process = run.channel else { return }
        let now = run.toTell
        for view in run.told where !now.contains(where: { $0.id == view.id }) {
            try? process.write(line: ResidentEvent.closed(to: nil).line(about: .init(view: view.id, keep: view.keep)))
        }
        for view in now {
            guard let before = run.told.first(where: { $0.id == view.id }) else {
                try? process.write(line: ResidentEvent.hello(columns: view.columns, rows: view.rows, language: language())
                    .line(about: view.about))
                continue
            }
            if before.columns != view.columns || before.rows != view.rows || before.place != view.place {
                try? process.write(line: ResidentEvent.size(columns: view.columns, rows: view.rows)
                    .line(about: .init(view: view.id, place: view.place)))
            }
        }
        run.told = now
    }

    /// Tells `id` of something done on its card — in the place `view`, or,
    /// with none, its first window on the board.
    func send(_ event: ResidentEvent, to id: PluginIdentifier, view: String? = nil) {
        guard let run = runs[id] else { return }
        let about = view.map { ResidentEvent.About(view: $0) } ?? run.views.first.map { ResidentEvent.About(view: $0.id) }
        try? run.channel?.write(line: event.line(about: about))
    }

    /// The place `view` of `id` was closed by the person: the plugin is told,
    /// with `to` when what it showed goes back to that window on the board.
    func closed(_ view: String, of id: PluginIdentifier, keep: String?, to: String?) {
        guard let run = runs[id] else { return }
        run.views.removeAll { $0.id == view }
        guard run.told.contains(where: { $0.id == view }) else { return }
        run.told.removeAll { $0.id == view }
        try? run.channel?.write(line: ResidentEvent.closed(to: to).line(about: .init(view: view, keep: keep)))
    }

    /// Whether `id` named a place: it can show each of its things apart.
    func speaksOfPlaces(_ id: PluginIdentifier) -> Bool { runs[id]?.speaksOfPlaces ?? false }

    var running: Set<PluginIdentifier> { Set(runs.keys) }

    /// The plugins whose process is up now — not one waiting to be started
    /// again after it exited.
    var live: Set<PluginIdentifier> { Set(runs.filter { $0.value.channel != nil && !$0.value.stopped }.keys) }

    func stopAll() {
        for run in runs.values { stop(run) }
        runs.removeAll()
        onLive(live)
    }

    private func start(_ run: Run) {
        guard !run.stopped else { return }
        let token = UUID()
        run.token = token
        let wanted = run.wanted
        Task { [weak self] in
            guard let self else { return }
            var channel: (any AgentChannel)?
            var attached = false
            if let launcher {
                do {
                    // Another of this plugin's, kept from before: another
                    // program now, or other settings.
                    let name = wanted.processName
                    for other in await launcher.kept(prefix: Wanted.prefix + wanted.id.rawValue + ".") where other != name {
                        await launcher.stop(name: other)
                    }
                    (channel, attached) = try await launcher.launch(
                        name: wanted.processName, executable: wanted.executable, arguments: wanted.arguments,
                        environment: wanted.environment, directory: wanted.directory)
                } catch {
                    DeckLog.plugins.notice("resident \(wanted.id.rawValue, privacy: .public) runs here, not in the helper: \(String(describing: error), privacy: .public)")
                }
            }
            if channel == nil {
                do {
                    channel = try AgentProcess(executable: wanted.executable, arguments: wanted.arguments,
                                               environment: wanted.environment, directory: wanted.directory)
                } catch {
                    DeckLog.plugins.error("resident \(wanted.id.rawValue, privacy: .public) did not start: \(String(describing: error), privacy: .public)")
                    return
                }
            }
            guard let channel else { return }
            // Stopped, or started again, while this one was being launched.
            guard run.token == token, !run.stopped, runs[wanted.id] === run else {
                await halt(channel, named: launcher == nil ? nil : wanted.processName)
                return
            }
            if attached {
                DeckLog.plugins.notice("resident \(wanted.id.rawValue, privacy: .public) was still running: taken back")
            }
            begin(run, on: channel, token: token)
        }
    }

    /// The process runs: it is told of its places — again, taken back after
    /// uDeck started again, so it says its cards again — and read.
    private func begin(_ run: Run, on channel: any AgentChannel, token: UUID) {
        run.channel = channel
        run.told = []
        run.speaksOfPlaces = false
        onLive(live)
        tell(run)
        let id = run.wanted.id
        // Read and decoded off the main thread: a card can be large, and
        // the panel must not wait on a plugin's output.
        run.reader = Task.detached(priority: .userInitiated) { [weak self] in
            for await piece in channel.lines {
                guard case .line(let text) = piece else { continue }
                let message = ResidentMessage(line: text)
                await self?.heard(id, message, token: token)
            }
            let exit = await channel.exit()
            await self?.exited(id, status: exit.status, token: token)
        }
    }

    /// Stops a process: in the helper, by its name, which forgets it too.
    private func halt(_ channel: any AgentChannel, named name: String?) async {
        channel.closeInput()
        _ = await channel.terminate(grace: .seconds(3))
        if let name, let launcher { await launcher.stop(name: name) }
    }

    private func heard(_ id: PluginIdentifier, _ message: ResidentMessage, token: UUID) {
        guard let run = runs[id], run.token == token, run.channel != nil, !run.stopped else { return }
        guard case .card(let card, let place) = message else {
            onMessage(id, message)
            return
        }
        run.failures = 0
        if place.speaksOfPlaces, !run.speaksOfPlaces {
            run.speaksOfPlaces = true
            tell(run)
        }
        // A card a place: each place's newest is drawn.
        pendingCards[Pending(plugin: id, view: place.view)] = (card, place)
        guard !drawScheduled.contains(id) else { return }
        let since = lastDrawn[id].map { ContinuousClock.now - $0 } ?? Self.cardInterval
        if since >= Self.cardInterval {
            draw(id)
            return
        }
        drawScheduled.insert(id)
        Task { [weak self] in
            try? await Task.sleep(for: Self.cardInterval - since)
            guard let self else { return }
            drawScheduled.remove(id)
            draw(id)
        }
    }

    private func draw(_ id: PluginIdentifier) {
        let pending = pendingCards.keys.filter { $0.plugin == id }
        guard runs[id] != nil, !pending.isEmpty else { return }
        lastDrawn[id] = .now
        for key in pending {
            guard let (card, place) = pendingCards.removeValue(forKey: key) else { continue }
            onMessage(id, .card(card, place))
        }
    }

    private func exited(_ id: PluginIdentifier, status: Int32, token: UUID) async {
        guard let run = runs[id], run.token == token, !run.stopped else { return }
        DeckLog.plugins.notice("resident \(id.rawValue, privacy: .public) exited \(status); starting it again")
        run.channel = nil
        onLive(live)
        run.failures += 1
        let pause = min(60.0, pow(2.0, Double(min(run.failures, 6))))
        try? await Task.sleep(for: .seconds(pause))
        if !run.stopped, runs[id] === run { start(run) }
    }

    private func stop(_ run: Run) {
        run.stopped = true
        run.token = UUID()
        run.reader?.cancel()
        if let channel = run.channel {
            let name = launcher == nil ? nil : run.wanted.processName
            Task { await halt(channel, named: name) }
        }
    }
}
