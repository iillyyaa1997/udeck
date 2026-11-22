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

    private final class Run {
        let wanted: Wanted
        var process: AgentProcess?
        var reader: Task<Void, Never>?
        var failures = 0
        var size: (columns: Int, rows: Int)
        var stopped = false

        init(wanted: Wanted, size: (columns: Int, rows: Int)) {
            self.wanted = wanted
            self.size = size
        }
    }

    private var runs: [PluginIdentifier: Run] = [:]
    /// The newest card a plugin printed and uDeck has not drawn yet.
    private var pendingCards: [PluginIdentifier: Card] = [:]
    private var lastDrawn: [PluginIdentifier: ContinuousClock.Instant] = [:]
    private var drawScheduled: Set<PluginIdentifier> = []
    /// However fast a plugin prints, its card is redrawn at most this often —
    /// the newest one wins — so a plugin cannot keep the panel busy.
    static let cardInterval: Duration = .milliseconds(100)
    /// What a running plugin said: the model records cards, posts
    /// notifications, asks for folders.
    var onMessage: (PluginIdentifier, ResidentMessage) -> Void = { _, _ in }
    var language: () -> String = { "en" }

    /// Starts what is wanted and not running, stops what runs and is no longer
    /// wanted (or changed), and tells running ones their size when it changed.
    func reconcile(_ wanted: [Wanted], sizes: [PluginIdentifier: (columns: Int, rows: Int)]) {
        let wantedIDs = Set(wanted.map(\.id))
        for (id, run) in runs where !wantedIDs.contains(id) || wanted.first(where: { $0.id == id }) != run.wanted {
            stop(run)
            runs[id] = nil
        }
        for item in wanted {
            let size = sizes[item.id] ?? (columns: 4, rows: 2)
            if let run = runs[item.id] {
                if run.size != size {
                    run.size = size
                    send(.size(columns: size.columns, rows: size.rows), to: item.id)
                }
                continue
            }
            let run = Run(wanted: item, size: size)
            runs[item.id] = run
            start(run)
        }
    }

    func send(_ event: ResidentEvent, to id: PluginIdentifier) {
        try? runs[id]?.process?.write(line: event.line)
    }

    var running: Set<PluginIdentifier> { Set(runs.keys) }

    func stopAll() {
        for run in runs.values { stop(run) }
        runs.removeAll()
    }

    private func start(_ run: Run) {
        guard !run.stopped else { return }
        let wanted = run.wanted
        do {
            let process = try AgentProcess(executable: wanted.executable, arguments: wanted.arguments,
                                           environment: wanted.environment, directory: wanted.directory)
            run.process = process
            try? process.write(line: ResidentEvent.hello(columns: run.size.columns, rows: run.size.rows,
                                                         language: language()).line)
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
        guard case .card(let card) = message else {
            onMessage(id, message)
            return
        }
        run.failures = 0
        pendingCards[id] = card
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
        guard let card = pendingCards.removeValue(forKey: id), runs[id] != nil else { return }
        lastDrawn[id] = .now
        onMessage(id, .card(card))
    }

    private func exited(_ id: PluginIdentifier, status: Int32, process: AgentProcess) async {
        guard let run = runs[id], run.process === process, !run.stopped else { return }
        DeckLog.plugins.notice("resident \(id.rawValue, privacy: .public) exited \(status); starting it again")
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
