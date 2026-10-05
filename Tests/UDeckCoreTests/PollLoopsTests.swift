import Foundation
import Testing
@testable import UDeckCore
import UDeckPluginFormatFixtures

/// A plugin as the plugins folder reads it, without a folder: what the loop
/// decisions are made of.
private func plugin(_ id: String, interval: Double = 5, run: String = "./run.sh", version: String = "1.0.0",
                    linkedTo target: String? = nil, asks: Bool = false) -> DiscoveredPlugin {
    let permissions = asks ? #", "permissions": {"exec": ["df"]}"# : ""
    let manifest = try! JSONDecoder().decode(PluginManifest.self, from: Data("""
        { "id": "\(id)", "name": "\(id)", "version": "\(version)", "api": 1, "kind": "poll",
          "run": ["\(run)"], "interval": \(interval), "timeout": 2\(permissions) }
        """.utf8))
    let link = URL(fileURLWithPath: "/udeck/plugins/\(id)")
    let directory = target.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? link
    return DiscoveredPlugin(directory: directory, folderName: id, manifest: manifest,
                            executable: directory.appendingPathComponent(run), problems: [],
                            linkedAt: target == nil ? nil : link)
}

private func identifiers(_ ids: String...) -> Set<PluginIdentifier> {
    Set(ids.map { PluginIdentifier(rawValue: $0)! })
}

@Suite("Poll loops, kept and started again")
struct PollLoopsTests {
    let placed = identifiers("linked", "disk", "clock")

    func wanted(_ plugins: [DiscoveredPlugin], grants: PermissionGrants = PermissionGrants(),
                settings: PluginSettings = PluginSettings(), polling: Bool = true,
                quiet: Set<String> = []) -> [String: PollLoop] {
        PollLoops.wanted(plugins, placed: placed, grants: grants, settings: settings, polling: polling,
                         isQuiet: { quiet.contains($0) })
    }

    @Test("a loop for every placed, allowed poll plugin with an interval, none while nothing is polled")
    func whichLoops() {
        let plugins = [plugin("linked", linkedTo: "/work/linked"), plugin("disk"), plugin("unplaced"),
                       plugin("clock", interval: 0), plugin("asks", asks: true)]
        #expect(Set(wanted(plugins).keys) == ["linked", "disk"])
        #expect(wanted(plugins, polling: false).isEmpty)
        #expect(Set(wanted(plugins, quiet: ["disk"]).keys) == ["linked"], "a plugin being quieted gets none")
        var off = PluginSettings()
        off.setEnabled(false, for: PluginIdentifier(rawValue: "disk")!)
        #expect(Set(wanted(plugins, settings: off).keys) == ["linked"], "nor one switched off")
    }

    /// The working copy touched, the plugins folder read again: every plugin
    /// is as it was, and every loop is left to run when it was due.
    @Test("a read that finds every plugin as it was starts and stops nothing")
    func nothingChanged() {
        let plugins = [plugin("linked", linkedTo: "/work/linked"), plugin("disk")]
        let running = wanted(plugins)
        #expect(PollLoops.plan(running: running, wanted: wanted(plugins)) == PollLoops.Plan())
    }

    @Test("a plugin whose folder, manifest, command or decision changed is started again, and only it")
    func changedIsStartedAgain() {
        let running = wanted([plugin("linked", linkedTo: "/work/linked"), plugin("disk")])
        let disk = plugin("disk")
        let changes: [(String, [DiscoveredPlugin], PermissionGrants)] = [
            ("a manifest edited in the working copy", [plugin("linked", interval: 2, linkedTo: "/work/linked"), disk], PermissionGrants()),
            ("another command", [plugin("linked", run: "./run2.sh", linkedTo: "/work/linked"), disk], PermissionGrants()),
            ("the link pointed elsewhere", [plugin("linked", linkedTo: "/work/other"), disk], PermissionGrants()),
            ("a new version", [plugin("linked", version: "1.1.0", linkedTo: "/work/linked"), disk], PermissionGrants()),
        ]
        for (what, plugins, grants) in changes {
            let plan = PollLoops.plan(running: running, wanted: wanted(plugins, grants: grants))
            #expect(plan == PollLoops.Plan(stop: ["linked"], start: ["linked"]), "\(what)")
        }

        // The operator's decision, made again.
        let asking = [plugin("linked", linkedTo: "/work/linked"), plugin("disk", asks: true)]
        let manifest = asking[1].manifest!
        var grants = PermissionGrants()
        grants[manifest.id] = PluginGrant(granted: Set(manifest.permissions.capabilities), denied: [],
                                          decidedForVersion: "1.0.0", decidedAt: Date(timeIntervalSince1970: 1_790_000_000))
        let allowed = wanted(asking, grants: grants)
        #expect(Set(allowed.keys) == ["linked", "disk"])
        grants[manifest.id]?.decidedAt = Date(timeIntervalSince1970: 1_790_000_100)
        #expect(PollLoops.plan(running: allowed, wanted: wanted(asking, grants: grants))
                == PollLoops.Plan(stop: ["disk"], start: ["disk"]))
    }

    @Test("a plugin gone, unplaced or quieted is stopped; one new is started; again starts every one afresh")
    func goneAndNew() {
        let running = wanted([plugin("linked", linkedTo: "/work/linked"), plugin("disk")])
        #expect(PollLoops.plan(running: running, wanted: wanted([plugin("disk"), plugin("clock")]))
                == PollLoops.Plan(stop: ["linked"], start: ["clock"]))
        #expect(PollLoops.plan(running: running, wanted: [:]) == PollLoops.Plan(stop: ["linked", "disk"]))
        #expect(PollLoops.plan(running: running, wanted: running, again: true)
                == PollLoops.Plan(stop: ["linked", "disk"], start: ["linked", "disk"]))
    }

    /// What the panel does with the plan, on a clock of its own: a loop sleeps
    /// its interval and runs, and one started again sleeps the whole interval
    /// first. A working copy touched every 3 s reads the plugins folder every
    /// 3 s — 0.7 s after the touch, FSEvents' batch and the watcher's settle —
    /// for a minute. Started again on every read, a plugin polled every 5 s
    /// never ran; left alone, it runs every 5 s.
    @Test("a working copy touched every 3 s: a plugin polled every 5 s, and its neighbour, still run every 5 s")
    func touchedEveryThreeSeconds() {
        func runs(restartingEveryRead: Bool) -> [String: Int] {
            let plugins = [plugin("linked", linkedTo: "/work/linked"), plugin("disk")]
            var running = wanted(plugins)
            var due: [String: Double] = running.mapValues { $0.plugin.manifest!.interval! }
            var count: [String: Int] = [:]
            let reads = stride(from: 3.7, through: 60, by: 3).map { $0 }
            var time = 0.0
            for read in reads + [60] {
                // Every run due before this read.
                for (id, _) in running {
                    while let next = due[id], next <= read {
                        count[id, default: 0] += 1
                        due[id] = next + running[id]!.plugin.manifest!.interval!
                    }
                }
                time = read
                guard read < 60 else { break }
                let now = wanted(plugins)
                let plan = PollLoops.plan(running: running, wanted: now, again: restartingEveryRead)
                for id in plan.stop { running[id] = nil; due[id] = nil }
                for id in plan.start { running[id] = now[id]; due[id] = time + now[id]!.plugin.manifest!.interval! }
            }
            return count
        }
        #expect(runs(restartingEveryRead: false) == ["linked": 12, "disk": 12])
        #expect(runs(restartingEveryRead: true).isEmpty, "the old way, every loop started again on every read: none ran")
    }
}

@Suite("Where every plugin folder stands")
struct ReverificationTests {
    let head = String(repeating: "c", count: 40)
    let installedAt = String(repeating: "a", count: 40)
    let tree = String(repeating: "b", count: 40)
    let now = Date(timeIntervalSince1970: 1_790_000_000)

    func record(checkedAgainst: String) -> InstalledRecord {
        InstalledRecord(source: InstalledPlugins.officialSource, repository: .official, ref: PluginRef(name: "main"),
                        commit: installedAt, tree: tree, version: "1.0.0",
                        installedAt: Date(timeIntervalSince1970: 1_780_000_000), pinned: false,
                        verification: PluginVerification(status: .verified, by: InstalledPlugins.officialSource,
                                                         checkedAgainst: checkedAgainst,
                                                         checkedAt: Date(timeIntervalSince1970: 1_780_000_000)),
                        previous: nil)
    }

    /// At launch the plugins folder is read before the catalogue's cache: a
    /// record checked against the head is not written over with the install's
    /// own commit, and written back once the catalogue is read.
    @Test("until the catalogue is read, no verification is written; then it is checked against the head")
    func notBeforeTheCatalogue() {
        let installed = InstalledPlugins(plugins: ["uptime": record(checkedAgainst: head)])
        let plugins = [plugin("uptime")]
        #expect(Reverification.folders(of: plugins, installed: installed) == ["uptime": plugins[0].directory])
        let trees: [String: String?] = ["uptime": tree]

        let atLaunch = Reverification.of(plugins, installed: installed, trees: trees, head: .notReadYet, now: now)
        #expect(atLaunch.standings == ["uptime": .verified])
        #expect(atLaunch.records == nil, "installed.json written before the catalogue was read")

        let read = Reverification.of(plugins, installed: installed, trees: trees, head: .read(head), now: now)
        #expect(read.records == nil, "the same finding: nothing to write")
        let newer = String(repeating: "d", count: 40)
        let moved = Reverification.of(plugins, installed: installed, trees: trees, head: .read(newer), now: now)
        #expect(moved.records?.plugins["uptime"]?.verification.checkedAgainst == newer)
        // No catalogue at all: checked against its own commit, as before.
        let none = Reverification.of(plugins, installed: installed, trees: trees, head: .read(nil), now: now)
        #expect(none.records?.plugins["uptime"]?.verification.checkedAgainst == installedAt)

        let changed = Reverification.of(plugins, installed: installed, trees: ["uptime": "e"], head: .notReadYet, now: now)
        #expect(changed.standings == ["uptime": .modifiedLocally], "where it stands is found all the same")
        #expect(changed.records == nil)
    }

    @Test("a linked folder is not hashed nor written, even with a record left; a record with no folder is missing")
    func linkedAndMissing() {
        let installed = InstalledPlugins(plugins: ["linked": record(checkedAgainst: head), "gone": record(checkedAgainst: head)])
        let plugins = [plugin("linked", linkedTo: "/work/linked"), plugin("own")]
        #expect(Reverification.folders(of: plugins, installed: installed).isEmpty, "a working copy is never hashed")
        let found = Reverification.of(plugins, installed: installed, trees: [:], head: .read(String(repeating: "d", count: 40)), now: now)
        #expect(found.standings == ["linked": .folderOfYourOwn, "own": .folderOfYourOwn, "gone": .missing])
        #expect(found.records == nil, "a linked plugin's record is not written")
    }

    final class Threads: @unchecked Sendable {
        private let lock = NSLock()
        private var main: [Bool] = []
        func record(_ onMain: Bool) { lock.withLock { main.append(onMain) } }
        var seen: [Bool] { lock.withLock { main } }
    }

    /// Asked from the main actor, as the model asks: the folders are hashed
    /// on the cooperative pool.
    @MainActor
    @Test("asked from the main actor, the folders are hashed away from the main thread")
    func hashedOffTheMainThread() async throws {
        let temp = TemporaryDirectory()
        defer { withExtendedLifetime(temp) {} }
        temp.writePlugin(folder: "uptime", manifest: "{}")
        let folder = temp.paths.plugins.appendingPathComponent("uptime", isDirectory: true)
        let threads = Threads()
        let trees = await Reverification.trees(of: ["uptime": folder]) { url in
            threads.record(Thread.isMainThread)
            return Reverification.tree(url)
        }
        #expect(threads.seen == [false])
        #expect(trees == ["uptime": try GitHash.tree(ofDirectoryAt: folder)])
    }
}

@Suite("What a change in a watched folder reads again")
struct FolderChangeTests {
    @Test("only a change in the plugins folder, or a read nobody watched for, hashes the installed plugins again")
    func rehashes() {
        #expect(WatchedFolders.rehashes(after: nil))
        #expect(WatchedFolders.rehashes(after: [.pluginsFolder]))
        #expect(WatchedFolders.rehashes(after: [.pluginsFolder, .linkedFolder]))
        #expect(!WatchedFolders.rehashes(after: [.linkedFolder]), "a working copy written into hashes nothing")
    }
}

@Suite("What goes into a run log")
struct RunLogDecisionTests {
    @Test("a linked folder's runs, while the run log is on; nobody else's")
    func takes() {
        var on = AppSettings()
        on.linkedFolderRunLog = true
        let linked = plugin("linked", linkedTo: "/work/linked")
        #expect(RunLog.takes(linked, settings: on))
        #expect(!RunLog.takes(linked, settings: AppSettings()), "off until it is turned on")
        #expect(!RunLog.takes(plugin("disk"), settings: on), "a plugin that is not a linked folder keeps nothing on disk")
    }
}

@Suite("The end of a failed run's stderr, as Settings shows it")
struct ShownStandardErrorTests {
    @Test("the last lines, where the error is, with … when anything came before them")
    func lastLines() {
        let traceback = (1 ... 20).map { "line \($0)" }.joined(separator: "\n")
        #expect(ShownStandardError.end(of: traceback) == "…\n" + (13 ... 20).map { "line \($0)" }.joined(separator: "\n"))
        #expect(ShownStandardError.end(of: "one\ntwo\nthree") == "one\ntwo\nthree", "a short one, whole")
        #expect(ShownStandardError.end(of: "a\r\nb\r\nc", lines: 2) == "…\nb\nc", "any line break ends a line")
        let long = String(repeating: "x", count: 5000) + "ValueError: the end"
        let shown = ShownStandardError.end(of: long)
        #expect(shown.hasSuffix("ValueError: the end"))
        #expect(shown.hasPrefix("…\n"))
        #expect(shown.count == ShownStandardError.characters + 2)
        #expect(ShownStandardError.end(of: "") == "")
    }

    @Test("exactly as many lines as are shown are shown whole, with nothing said to be left out")
    func exactlyTheLines() {
        let eight = (1 ... ShownStandardError.lines).map { "line \($0)" }.joined(separator: "\n")
        #expect(ShownStandardError.end(of: eight) == eight)
        let nine = (0 ... ShownStandardError.lines).map { "line \($0)" }.joined(separator: "\n")
        #expect(ShownStandardError.end(of: nine) == "…\n" + eight)
    }
}

@Suite("The panel coming into sight and going away")
struct VisibilityTests {
    let plugins = [plugin("linked", linkedTo: "/work/linked"), plugin("disk")]
    var loops: [String: PollLoop] {
        PollLoops.wanted(plugins, placed: identifiers("linked", "disk"), grants: PermissionGrants(),
                         settings: PluginSettings(), polling: true, isQuiet: { _ in false })
    }

    @Test("shown: every plugin runs now and every loop starts afresh after it")
    func shown() {
        let change = PollLoops.visibilityChanged(nowVisible: true)
        #expect(change == PollLoops.VisibilityChange(refresh: true, again: true))
        #expect(PollLoops.plan(running: loops, wanted: loops, again: change.again).start == ["linked", "disk"])
    }

    /// Polling while the panel is away, hiding it starts nothing again: a
    /// loop with a long interval used to wait it whole once more after every
    /// close, and with the panel opened and closed by the pointer it ran
    /// late every time.
    @Test("hidden: nothing runs, and a loop that goes on while the panel is away keeps its rhythm")
    func hidden() {
        let change = PollLoops.visibilityChanged(nowVisible: false)
        #expect(change == PollLoops.VisibilityChange(refresh: false, again: false))
        #expect(PollLoops.plan(running: loops, wanted: loops, again: change.again) == PollLoops.Plan())
    }
}

@Suite("Where a watch of linked folders stands")
struct WatchRememberedTests {
    @Test("the folders are held as watched only when their stream was made; otherwise the next read asks again")
    func remembered() {
        #expect(WatchedFolders.remembered(["/work/a", "/work/b"], streamMade: true) == ["/work/a", "/work/b"])
        #expect(WatchedFolders.remembered(["/work/a"], streamMade: false) == [])
        #expect(WatchedFolders.remembered([], streamMade: false) == [], "nothing to watch is no stream, and no failure")
    }
}

@Suite("A hashing nobody will apply")
struct ReverificationCancelTests {
    /// The hashing is cancelled during its first folder — as a later read
    /// of the plugins folder cancels the one before it — and hashes no other.
    @Test("a cancelled hashing stops at the next folder, and comes to nothing")
    func stopsWhenCancelled() async {
        let folders = ["a", "b", "c"].reduce(into: [String: URL]()) { $0[$1] = URL(fileURLWithPath: "/nowhere/\($1)") }
        let hashed = Counter()
        let task = Task {
            await Reverification.trees(of: folders) { _ in
                hashed.add()
                withUnsafeCurrentTask { $0?.cancel() }
                return "tree"
            }
        }
        #expect(await task.value == nil)
        #expect(hashed.value == 1, "hashed \(hashed.value) folders after it was cancelled")

        let whole = await Reverification.trees(of: folders) { _ in "tree" }
        #expect(whole == ["a": "tree", "b": "tree", "c": "tree"], "not cancelled, every folder")
    }
}
