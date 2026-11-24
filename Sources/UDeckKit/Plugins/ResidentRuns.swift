import Foundation
import UDeckAgents
import UDeckCore

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
        var process: AgentProcess?
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
        guard let process = run.process else { return }
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
        try? run.process?.write(line: event.line(about: about))
    }

    /// The place `view` of `id` was closed by the person: the plugin is told,
    /// with `to` when what it showed goes back to that window on the board.
    func closed(_ view: String, of id: PluginIdentifier, keep: String?, to: String?) {
        guard let run = runs[id] else { return }
        run.views.removeAll { $0.id == view }
        guard run.told.contains(where: { $0.id == view }) else { return }
        run.told.removeAll { $0.id == view }
        try? run.process?.write(line: ResidentEvent.closed(to: to).line(about: .init(view: view, keep: keep)))
    }

    /// Whether `id` named a place: it can show each of its things apart.
    func speaksOfPlaces(_ id: PluginIdentifier) -> Bool { runs[id]?.speaksOfPlaces ?? false }

    var running: Set<PluginIdentifier> { Set(runs.keys) }

    /// The plugins whose process is up now — not one waiting to be started
    /// again after it exited.
    var live: Set<PluginIdentifier> { Set(runs.filter { $0.value.process != nil && !$0.value.stopped }.keys) }

    func stopAll() {
        for run in runs.values { stop(run) }
        runs.removeAll()
        onLive(live)
    }

    private func start(_ run: Run) {
        guard !run.stopped else { return }
        let wanted = run.wanted
        do {
            let process = try AgentProcess(executable: wanted.executable, arguments: wanted.arguments,
                                           environment: wanted.environment, directory: wanted.directory)
            run.process = process
            run.told = []
            run.speaksOfPlaces = false
            onLive(live)
            tell(run)
            let id = wanted.id
            // Read and decoded off the main thread: a card can be large, and
            // the panel must not wait on a plugin's output.
            run.reader = Task.detached(priority: .userInitiated) { [weak self] in
                for await piece in process.lines {
                    guard case .line(let text) = piece else { continue }
                    let message = ResidentMessage(line: text)
                    await self?.heard(id, message, from: process)
                }
                let exit = await process.exit()
                await self?.exited(id, status: exit.status, process: process)
            }
        } catch {
            DeckLog.plugins.error("resident \(wanted.id.rawValue, privacy: .public) did not start: \(String(describing: error), privacy: .public)")
        }
    }

    private func heard(_ id: PluginIdentifier, _ message: ResidentMessage, from process: AgentProcess) {
        guard let run = runs[id], run.process === process, !run.stopped else { return }
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

    private func exited(_ id: PluginIdentifier, status: Int32, process: AgentProcess) async {
        guard let run = runs[id], run.process === process, !run.stopped else { return }
        DeckLog.plugins.notice("resident \(id.rawValue, privacy: .public) exited \(status); starting it again")
        run.process = nil
        onLive(live)
        run.failures += 1
        let pause = min(60.0, pow(2.0, Double(min(run.failures, 6))))
        try? await Task.sleep(for: .seconds(pause))
        if !run.stopped, runs[id] === run { start(run) }
    }

    private func stop(_ run: Run) {
        run.stopped = true
        run.reader?.cancel()
        if let process = run.process {
            process.closeInput()
            Task { _ = await process.terminate(grace: .seconds(3)) }
        }
    }
}
