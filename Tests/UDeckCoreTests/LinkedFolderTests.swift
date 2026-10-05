import Darwin
import Foundation
import Testing
@testable import UDeckCore
import UDeckPluginFormatFixtures

/// Everything at and under `folder`, as it is on disk: a file's bytes, a
/// link's destination, a folder as nothing — never following a link. Two of
/// these equal is a folder left byte for byte as it was.
func everythingAt(_ folder: URL) -> [String: String] {
    var found: [String: String] = [:]
    func walk(_ url: URL, _ relative: String) {
        guard let kind = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType else { return }
        switch kind {
        case .typeDirectory:
            found[relative + "/"] = ""
            for name in ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).sorted() {
                walk(url.appendingPathComponent(name), relative + "/" + name)
            }
        case .typeSymbolicLink:
            found[relative] = "-> " + ((try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) ?? "?")
        default:
            found[relative] = (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) } ?? "?"
        }
    }
    walk(folder, "")
    return found
}

/// A linked folder: `<uDeck folder>/plugins/<id>`, a link to an author's
/// working copy. uDeck reads through it; removing or replacing it acts on the
/// link, and nothing it leads to is ever deleted, sent to the Trash, or
/// written into.
@Suite("Linked folders, removed and replaced")
struct LinkedFolderInstallerTests {
    /// uDeck's folder and the author's, apart: a working copy is never inside
    /// uDeck's own.
    let udeck = TemporaryDirectory()
    let work = TemporaryDirectory()
    var paths: UDeckPaths { udeck.paths }
    var live: URL { paths.plugins.appendingPathComponent("uptime", isDirectory: true) }
    var discovery: PluginDiscovery { PluginDiscovery(searchPath: ["/bin", "/usr/bin"], udeck: SemanticVersion("0.5.0")) }

    func installer(_ repository: FakeRepository = .withUptime(), trash: TestTrash) -> PluginInstaller {
        PluginInstaller(paths: paths, discovery: discovery, trash: trash, fetch: FetchLog(repository).fetch,
                        now: { Date(timeIntervalSince1970: 1_790_000_000) })
    }

    func request(_ repository: FakeRepository, _ operation: InstallRequest.Operation) -> InstallRequest {
        InstallRequest(operation: operation, id: PluginIdentifier(rawValue: "uptime")!, repository: .official,
                       ref: PluginRef(name: "main"), commit: repository.commit, folder: repository.plugin("uptime"),
                       version: "1.0.0", headCommit: repository.commit)
    }

    /// The author's working copy of `uptime`, with what an author's folder
    /// holds beside the plugin: a `.git`, a `.env`, and files named like the
    /// ones uDeck writes and deletes in its own folder — `installed.json`, a
    /// `cache/`, a `logs/` — which must be left alone all the same.
    func workingCopy(_ name: String = "uptime-work") throws -> URL {
        let folder = work.url.appendingPathComponent(name, isDirectory: true)
        let manager = FileManager.default
        try manager.createDirectory(at: folder.appendingPathComponent(".git/refs"), withIntermediateDirectories: true)
        try manager.createDirectory(at: folder.appendingPathComponent("cache/uptime"), withIntermediateDirectories: true)
        try manager.createDirectory(at: folder.appendingPathComponent("logs"), withIntermediateDirectories: true)
        try Data(FakeRepository.manifest().utf8).write(to: folder.appendingPathComponent("manifest.json"))
        try Data("#!/bin/sh\nprintf '{}'\n".utf8).write(to: folder.appendingPathComponent("uptime.sh"))
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.appendingPathComponent("uptime.sh").path)
        try Data("TOKEN=the author's\n".utf8).write(to: folder.appendingPathComponent(".env"))
        try Data("ref: refs/heads/main\n".utf8).write(to: folder.appendingPathComponent(".git/HEAD"))
        try Data(#"{"version": 1, "plugins": {}}"#.utf8).write(to: folder.appendingPathComponent("installed.json"))
        try Data("kept".utf8).write(to: folder.appendingPathComponent("cache/uptime/state"))
        try Data("an old log\n".utf8).write(to: folder.appendingPathComponent("logs/uptime.log"))
        try manager.createSymbolicLink(atPath: folder.appendingPathComponent("latest").path, withDestinationPath: "uptime.sh")
        return folder
    }

    func linkIn(_ folder: URL) throws {
        try FileManager.default.createDirectory(at: paths.plugins, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: live.path, withDestinationPath: folder.path)
    }

    func records() throws -> InstalledPlugins {
        try JSONFileStore<InstalledPlugins>(url: paths.installedFile).load() ?? InstalledPlugins()
    }

    func stagingIsEmpty() -> Bool {
        ((try? FileManager.default.contentsOfDirectory(atPath: paths.staging.path)) ?? []).isEmpty
    }

    func candidate(_ folder: URL) throws -> PluginLink.Candidate {
        try PluginLink.candidate(folder, home: paths.root)
    }

    @Test("Remove takes the link and uDeck's own records of it — the cache, the run log — and not a byte of the folder")
    func removal() throws {
        let folder = try workingCopy()
        try linkIn(folder)
        let before = everythingAt(folder)
        let id = PluginIdentifier(rawValue: "uptime")!
        let cache = paths.makeCache(forPlugin: id)
        try Data("3".utf8).write(to: cache.appendingPathComponent("runs"))
        try FileManager.default.createDirectory(at: paths.logs, withIntermediateDirectories: true)
        try Data("a run\n".utf8).write(to: paths.log(forPlugin: id))
        try Data("an older run\n".utf8).write(to: paths.previousLog(forPlugin: id))
        let trash = TestTrash(in: udeck.url)
        #expect(!OperatorsWork.goesToTrash("uptime", in: paths, record: nil), "nothing of a linked folder goes to the Trash")

        let i = installer(trash: trash)
        let removal = try i.beginRemoval(id)
        #expect(!PluginInstaller.folderIsTaken("uptime", in: paths), "gone from the plugins folder at once")
        #expect(everythingAt(folder) == before)
        try i.finishRemoval(removal)

        #expect(everythingAt(folder) == before, "the folder the link led to, byte for byte")
        #expect(trash.names.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: cache.path))
        #expect(!FileManager.default.fileExists(atPath: paths.log(forPlugin: id).path))
        #expect(!FileManager.default.fileExists(atPath: paths.previousLog(forPlugin: id).path))
        #expect(!FileManager.default.fileExists(atPath: paths.installedFile.path), "installed.json is not made for a link")
        #expect(stagingIsEmpty())
    }

    @Test("a link that leads nowhere is still in the way, and is what Remove and Install take")
    func danglingLink() async throws {
        let gone = work.url.appendingPathComponent("gone").path
        try FileManager.default.createDirectory(at: paths.plugins, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: live.path, withDestinationPath: gone)
        #expect(PluginInstaller.folderIsTaken("uptime", in: paths))
        let trash = TestTrash(in: udeck.url)
        let repository = FakeRepository.withUptime()
        let i = installer(repository, trash: trash)

        // Remove: the link goes, and nothing else is looked for.
        let id = PluginIdentifier(rawValue: "uptime")!
        try i.finishRemoval(try await i.beginRemoval(id, once: { true }))
        #expect(!PluginInstaller.folderIsTaken("uptime", in: paths), "Remove took the link that leads nowhere")
        #expect(!FileManager.default.fileExists(atPath: gone), "and made nothing where it pointed")
        #expect(trash.names.isEmpty)
        #expect(stagingIsEmpty())

        // An install over one.
        try FileManager.default.createSymbolicLink(atPath: live.path, withDestinationPath: gone)
        try i.commit(try await i.stage(request(repository, .replace)))
        #expect(!PluginInstaller.isLink(live))
        #expect(try GitHash.tree(ofDirectoryAt: live) == repository.treeID("plugins/uptime"))
        #expect(trash.names.isEmpty)
        #expect(stagingIsEmpty())
    }

    @Test("Replace… from the catalogue over a linked plugin takes the link's place and leaves the folder as it was")
    func replacedByAnInstall() async throws {
        let folder = try workingCopy()
        try linkIn(folder)
        let before = everythingAt(folder)
        let trash = TestTrash(in: udeck.url)
        let repository = FakeRepository.withUptime()
        let i = installer(repository, trash: trash)
        try i.commit(try await i.stage(request(repository, .replace)))
        #expect(!PluginInstaller.isLink(live))
        #expect(try GitHash.tree(ofDirectoryAt: live) == repository.treeID("plugins/uptime"))
        #expect(try records().plugins["uptime"] != nil)
        #expect(everythingAt(folder) == before)
        #expect(trash.names.isEmpty, "the link is unlinked, not sent to the Trash")
        #expect(stagingIsEmpty())
    }

    @Test("a link in an installed plugin's place: the copy goes as Replace… sends it, the record goes, the folder is untouched")
    func linkOverAnInstalledPlugin() async throws {
        let repository = FakeRepository.withUptime()
        let trash = TestTrash(in: udeck.url)
        let i = installer(repository, trash: trash)
        try i.commit(try await i.stage(request(repository, .install)))
        #expect(try records().plugins["uptime"] != nil)
        let folder = try workingCopy()
        let before = everythingAt(folder)

        let quieted = Counter()
        try await i.link(try candidate(folder), once: { quieted.add(); return true })
        #expect(quieted.value == 1)
        #expect(PluginInstaller.isLink(live))
        #expect(FilePaths.real(live.path).path == FilePaths.real(folder.path).path)
        #expect(try records().plugins["uptime"] == nil, "a linked folder is never in installed.json")
        #expect(trash.names.isEmpty, "uDeck's own unchanged copy is deleted, as Replace… deletes it")
        #expect(everythingAt(folder) == before)
        #expect(stagingIsEmpty())
        #expect(discovery.scan(paths).first.map { $0.isLinked && $0.isUsable } == true)
    }

    @Test("a link over a copy holding something of the operator's, or over a folder of their own, sends that to the Trash")
    func linkOverTheOperatorsWork() async throws {
        let repository = FakeRepository.withUptime()
        let trash = TestTrash(in: udeck.url)
        let i = installer(repository, trash: trash)
        try i.commit(try await i.stage(request(repository, .install)))
        try Data("TOKEN=mine\n".utf8).write(to: live.appendingPathComponent(".env"))
        #expect(OperatorsWork.goesToTrash("uptime", in: paths, record: try records().plugins["uptime"]))
        let folder = try workingCopy()
        try await i.link(try candidate(folder), once: { true })
        #expect(trash.names == ["uptime"])
        let trashed = try FileManager.default.contentsOfDirectory(at: trash.folder, includingPropertiesForKeys: nil)
        #expect(trashed.contains { FileManager.default.fileExists(atPath: $0.appendingPathComponent(".env").path) })

        // A folder of the operator's own, no record at all.
        try FileManager.default.removeItem(at: live)
        udeck.writePlugin(folder: "uptime", manifest: FakeRepository.manifest(),
                          script: (name: "uptime.sh", body: "#!/bin/sh\necho mine\n", executable: true))
        try await i.link(try candidate(folder), once: { true })
        #expect(trash.names == ["uptime", "uptime"])
        #expect(PluginInstaller.isLink(live))
    }

    /// The wait for quiet can last the plugin's whole timeout, and the
    /// operator can save a file into the installed copy meanwhile. Where the
    /// copy goes is judged after the wait, for a link as for **Replace…**:
    /// judged before it, the copy was uDeck's own unchanged one, and it was
    /// deleted with the operator's `.env` in it.
    @Test("a file the operator saves into the copy while link waits for quiet sends the copy to the Trash, as an update would")
    func linkJudgesTheCopyAfterQuiet() async throws {
        let repository = FakeRepository.withUptime()
        let trash = TestTrash(in: udeck.url)
        let i = installer(repository, trash: trash)
        try i.commit(try await i.stage(request(repository, .install)))
        let env = live.appendingPathComponent(".env")
        #expect(!OperatorsWork.goesToTrash("uptime", in: paths, record: try records().plugins["uptime"]))

        try await i.link(try candidate(try workingCopy()), once: {
            try? Data("TOKEN=mine\n".utf8).write(to: env)
            return true
        })
        #expect(trash.names == ["uptime"], "the copy with the operator's .env in it was deleted, not sent to the Trash")
        let trashed = try FileManager.default.contentsOfDirectory(at: trash.folder, includingPropertiesForKeys: nil)
        #expect(trashed.contains { (try? String(contentsOf: $0.appendingPathComponent(".env"), encoding: .utf8)) == "TOKEN=mine\n" })
        #expect(PluginInstaller.isLink(live))
        #expect(stagingIsEmpty())

        // The same, during an update's wait: the rule the link is held to.
        let other = TemporaryDirectory()
        let control = UDeckPaths(root: other.url)
        let controlTrash = TestTrash(in: other.url)
        let updater = PluginInstaller(paths: control, discovery: discovery, trash: controlTrash,
                                      fetch: FetchLog(repository).fetch, now: { Date(timeIntervalSince1970: 1_790_000_000) })
        try updater.commit(try await updater.stage(request(repository, .install)))
        let controlEnv = control.plugins.appendingPathComponent("uptime/.env")
        try await updater.commit(try await updater.stage(request(repository, .reinstall)), once: {
            try? Data("TOKEN=mine\n".utf8).write(to: controlEnv)
            return true
        })
        #expect(controlTrash.names == ["uptime"])
        withExtendedLifetime(other) {}
    }

    @Test("a link over another link unlinks the old one, and both folders are left as they were")
    func linkOverALink() async throws {
        let first = try workingCopy("first")
        let second = try workingCopy("second")
        try linkIn(first)
        let (beforeFirst, beforeSecond) = (everythingAt(first), everythingAt(second))
        let trash = TestTrash(in: udeck.url)
        try await installer(trash: trash).link(try candidate(second), once: { true })
        #expect(FilePaths.real(live.path).path == FilePaths.real(second.path).path)
        #expect(everythingAt(first) == beforeFirst)
        #expect(everythingAt(second) == beforeSecond)
        #expect(trash.names.isEmpty)
        #expect(stagingIsEmpty())
    }

    @Test("a plugin still running is not replaced by a link: nothing moves")
    func stillRunning() async throws {
        let repository = FakeRepository.withUptime()
        let trash = TestTrash(in: udeck.url)
        let i = installer(repository, trash: trash)
        try i.commit(try await i.stage(request(repository, .install)))
        let installed = everythingAt(live)
        do {
            try await i.link(try candidate(try workingCopy()), once: { false })
            Issue.record("linked over a plugin that was still running")
        } catch let error as InstallError {
            #expect(error == .stillRunning(id: "uptime"))
        }
        #expect(!PluginInstaller.isLink(live))
        #expect(everythingAt(live) == installed)
        #expect(try records().plugins["uptime"] != nil)
        #expect(stagingIsEmpty())
    }

    /// A records file that will not parse stops a link before anything is
    /// quieted, as it stops an install before anything is downloaded: there
    /// is no going ahead, and the plugin is not stopped for nothing.
    @Test("a records file that will not parse stops a link before the plugin is quieted")
    func brokenRecordsStopBeforeQuiet() async throws {
        let folder = try workingCopy()
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: paths.installedFile)
        let quieted = Counter()
        let i = installer(trash: TestTrash(in: udeck.url))
        do {
            try await i.link(try candidate(folder), once: { quieted.add(); return true })
            Issue.record("linked with installed.json broken")
        } catch let error as InstallError {
            guard case .recordsBroken = error else { Issue.record("\(error)"); return }
        }
        #expect(quieted.value == 0, "the plugin was quieted for a link that could not go ahead")
        #expect(!PluginInstaller.folderIsTaken("uptime", in: paths))
        #expect(stagingIsEmpty())
    }

    // MARK: - A crash halfway

    func journal(_ folder: URL, oldCopyIsOperators: Bool = false) throws -> URL {
        let directory = paths.staging.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let intent = InstallIntent(operation: .link, id: "uptime", record: nil, oldCopyIsOperators: oldCopyIsOperators,
                                   linkTarget: FilePaths.real(folder.path).path)
        try JSONEncoder.iso8601.encode(intent).write(to: directory.appendingPathComponent("intent.json"))
        try FileManager.default.createSymbolicLink(atPath: directory.appendingPathComponent("uptime").path,
                                                   withDestinationPath: FilePaths.real(folder.path).path ?? folder.path)
        return directory
    }

    @Test("a crash after the link was swapped in: the record is forgotten at launch, the old copy goes, the folder stays")
    func crashAfterTheSwap() async throws {
        let repository = FakeRepository.withUptime()
        let trash = TestTrash(in: udeck.url)
        let i = installer(repository, trash: trash)
        try i.commit(try await i.stage(request(repository, .install)))
        let folder = try workingCopy()
        let before = everythingAt(folder)
        let directory = try journal(folder)
        #expect(renamex_np(directory.appendingPathComponent("uptime").path, live.path, UInt32(RENAME_SWAP)) == 0)

        #expect(i.recover() == [.linked(id: "uptime")])
        #expect(PluginInstaller.isLink(live))
        #expect(try records().plugins["uptime"] == nil)
        #expect(trash.names.isEmpty, "the old copy hashes to what uDeck put there, and is deleted")
        #expect(everythingAt(folder) == before)
        #expect(stagingIsEmpty())
    }

    @Test("a crash before the swap: the link made in staging is unlinked, the installed copy and the folder stay")
    func crashBeforeTheSwap() async throws {
        let repository = FakeRepository.withUptime()
        let trash = TestTrash(in: udeck.url)
        let i = installer(repository, trash: trash)
        try i.commit(try await i.stage(request(repository, .install)))
        let installed = everythingAt(live)
        let folder = try workingCopy()
        let before = everythingAt(folder)
        _ = try journal(folder)

        #expect(i.recover() == [.neverSwapped(id: "uptime")])
        #expect(!PluginInstaller.isLink(live))
        #expect(everythingAt(live) == installed)
        #expect(try records().plugins["uptime"] != nil)
        #expect(everythingAt(folder) == before)
        #expect(trash.names.isEmpty)
        #expect(stagingIsEmpty())
    }

    @Test("a crash after the swap, and the link pointed elsewhere since: the old copy goes as the journal said, never simply away")
    func crashAndRepointed() async throws {
        let repository = FakeRepository.withUptime()
        let trash = TestTrash(in: udeck.url)
        let i = installer(repository, trash: trash)
        // A folder of the operator's own, which the journal says goes to the Trash.
        udeck.writePlugin(folder: "uptime", manifest: FakeRepository.manifest(),
                          script: (name: "uptime.sh", body: "#!/bin/sh\necho mine\n", executable: true))
        let folder = try workingCopy()
        let other = try workingCopy("other")
        let directory = try journal(folder, oldCopyIsOperators: true)
        #expect(renamex_np(directory.appendingPathComponent("uptime").path, live.path, UInt32(RENAME_SWAP)) == 0)
        try FileManager.default.removeItem(atPath: live.path)
        try FileManager.default.createSymbolicLink(atPath: live.path, withDestinationPath: other.path)

        #expect(i.recover() == [.neverSwapped(id: "uptime")])
        #expect(trash.names == ["uptime"], "the operator's folder, to the Trash")
        #expect(FilePaths.real(live.path).path == FilePaths.real(other.path).path)
        #expect(stagingIsEmpty())
    }
}

/// Counts, from any thread.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func add() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

/// A link can be pointed at another folder at any moment — between the read
/// of the plugins folder and the run. What runs is the folder that was read,
/// which is the one whose manifest the operator was asked about; the next read
/// follows the link, and a new version there is asked about again.
@Suite("A link pointed elsewhere between the read and the run")
struct LinkRaceTests {
    @Test("the run is the folder that was read; the next read is the folder now, and a new version is asked about")
    func repointedBeforeTheRun() async throws {
        let udeck = TemporaryDirectory()
        let work = TemporaryDirectory()
        defer { withExtendedLifetime((udeck, work)) {} }
        func folder(_ name: String, version: String, says: String) throws -> URL {
            let url = work.url.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try Data(#"{ "id": "greeter", "name": "Greeter", "version": "\#(version)", "api": 1, "kind": "poll", "run": ["./run.sh"], "interval": 30, "timeout": 5, "permissions": {"exec": ["df"]} }"#.utf8)
                .write(to: url.appendingPathComponent("manifest.json"))
            let script = url.appendingPathComponent("run.sh")
            try Data("#!/bin/sh\nprintf '{\"rows\": [{\"text\": \"\(says)\"}]}'\n".utf8).write(to: script)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
            return url
        }
        let agreed = try folder("agreed", version: "1.0.0", says: "the folder that was read")
        let other = try folder("other", version: "2.0.0", says: "the folder pointed at later")
        let link = udeck.paths.plugins.appendingPathComponent("greeter")
        try FileManager.default.createDirectory(at: udeck.paths.plugins, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: agreed.path)
        let discovery = PluginDiscovery(searchPath: ["/usr/bin", "/bin"])
        let read = try #require(discovery.scan(udeck.paths).first)
        let manifest = try #require(read.manifest)
        let grant = PluginGrant(granted: Set(manifest.permissions.capabilities), denied: [], decidedForVersion: manifest.version)
        #expect(PermissionGate.launchDecision(for: manifest, grant: grant, enabled: true).isAllowed)

        // Pointed elsewhere after the read, before the run.
        try FileManager.default.removeItem(atPath: link.path)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: other.path)
        let run = await PollExecutor().poll(plugin: read, grant: grant, enabled: true, settings: PluginSettings(),
                                            paths: udeck.paths, searchPath: ["/usr/bin", "/bin"], appearance: .dark,
                                            reason: .interval, language: "en")
        guard case .card(let card) = run else { Issue.record("\(run)"); return }
        #expect(card.rows == [.text("the folder that was read")])

        let now = try #require(discovery.scan(udeck.paths).first)
        #expect(now.directory.path == FilePaths.real(other.path).path)
        let asked = PermissionGate.launchDecision(for: try #require(now.manifest), grant: grant, enabled: true)
        guard case .awaitingDecision = asked else { Issue.record("a new version is not asked about: \(asked)"); return }
    }
}

@Suite("Watching linked folders")
struct WatchedFoldersTests {
    @Test("beside the plugins folder, every folder a followed link leads to, once each")
    func watched() throws {
        let udeck = TemporaryDirectory()
        let work = TemporaryDirectory()
        defer { withExtendedLifetime((udeck, work)) {} }
        let paths = udeck.paths
        let manager = FileManager.default
        try manager.createDirectory(at: paths.plugins, withIntermediateDirectories: true)
        let folder = work.url.appendingPathComponent("greeter", isDirectory: true)
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        udeck.writePlugin(folder: "own", manifest: "{}")
        try manager.createSymbolicLink(atPath: paths.plugins.appendingPathComponent("greeter").path, withDestinationPath: folder.path)
        try manager.createSymbolicLink(atPath: paths.plugins.appendingPathComponent("twice").path, withDestinationPath: folder.path)
        try manager.createSymbolicLink(atPath: paths.plugins.appendingPathComponent("gone").path,
                                       withDestinationPath: work.url.appendingPathComponent("gone").path)
        let found = PluginDiscovery(searchPath: []).scan(paths)
        #expect(found.count == 4)
        let watched = WatchedFolders.linked(found).map(\.path)
        #expect(watched == [FilePaths.real(folder.path).path], "\(watched)")
    }
}

@Suite("The run log")
struct RunLogTests {
    let udeck = TemporaryDirectory()
    let work = TemporaryDirectory()
    let id = PluginIdentifier(rawValue: "greeter")!

    func run(_ result: PluginRun.Result = .card, stderr: String = "", dropped: Int = 0,
             termination: Termination = .exited(code: 0)) -> PluginRun {
        PluginRun(startedAt: Date(timeIntervalSince1970: 1_790_000_000), reason: .launch, termination: termination,
                  duration: 0.214, result: result, standardError: stderr, standardErrorDropped: dropped)
    }

    @Test("an entry says when, why, how it ended, how long it took, what it came to, and the end of its stderr")
    func entry() {
        let utc = TimeZone(identifier: "UTC")!
        #expect(RunLog.entry(run(), timeZone: utc) == "2026-09-21T14:13:20Z launch, 0.21 s: exit status 0; a card\n")
        let failed = run(.failure(.exited(code: 3)), stderr: "Traceback:\n  boom\n", dropped: 1834, termination: .exited(code: 3))
        #expect(RunLog.entry(failed, timeZone: utc) == """
            2026-09-21T14:13:20Z launch, 0.21 s: exit status 3; a failure: the producer exited with status 3
              | Traceback:
              |   boom
              (and 1834 bytes of standard error before these, not kept)

            """)
        let late = run(.lateCard(.timedOut(after: 2)), termination: .timedOut(after: 2))
        #expect(RunLog.entry(late, timeZone: TimeZone(secondsFromGMT: 7200)!)
                == "2026-09-21T16:13:20+02:00 launch, 0.21 s: stopped by uDeck after 2 s, its timeout; a card, and a "
                + "failure: the producer did not answer within 2s and was stopped\n")
    }

    @Test("entries are appended, and the file is turned over past its size, one older file kept")
    func rotation() throws {
        let log = RunLog(paths: udeck.paths)
        let tail = String(repeating: "e", count: ProcessRunner.defaultStandardErrorTail - 1) + "\n"
        let big = run(stderr: tail)
        let entry = RunLog.entry(big).utf8.count
        let fit = RunLog.maximumBytes / entry
        for _ in 0 ..< fit { try log.append(big, for: id, linkTarget: work.url) }
        let file = udeck.paths.log(forPlugin: id)
        let previous = udeck.paths.previousLog(forPlugin: id)
        #expect(try Data(contentsOf: file).count == fit * entry)
        #expect(!FileManager.default.fileExists(atPath: previous.path))
        // One more would take it past the size: the file is turned over first.
        let marked = run(stderr: String(repeating: "f", count: tail.count - 1) + "\n")
        try log.append(marked, for: id, linkTarget: work.url)
        #expect(try Data(contentsOf: previous).count == fit * entry, "the whole old file, kept")
        #expect(try String(contentsOf: file, encoding: .utf8) == RunLog.entry(marked), "a new file, with the one that turned it over")
        for _ in 0 ..< fit { try log.append(big, for: id, linkTarget: work.url) }
        #expect(try Data(contentsOf: file).count <= RunLog.maximumBytes)
        #expect(try Data(contentsOf: previous).count <= RunLog.maximumBytes)
        #expect(try String(contentsOf: previous, encoding: .utf8).hasPrefix(RunLog.entry(marked)), "the older file is the one before")
        #expect(try FileManager.default.contentsOfDirectory(atPath: udeck.paths.logs.path).sorted() == ["greeter.log", "greeter.log.1"])

        log.remove(for: id)
        #expect(try FileManager.default.contentsOfDirectory(atPath: udeck.paths.logs.path).isEmpty)
    }

    /// The author's folder is theirs: a uDeck folder kept inside it — for a
    /// test, a demo — still never gets a log written into it.
    @Test("a log that would land inside the folder the link leads to is not written")
    func neverInsideThePlugin() throws {
        let inside = UDeckPaths(root: work.url.appendingPathComponent("udeck", isDirectory: true))
        let before = everythingAt(work.url)
        #expect(throws: RunLog.Refusal.insideThePlugin(inside.logs.path)) {
            try RunLog(paths: inside).append(run(), for: id, linkTarget: work.url)
        }
        #expect(everythingAt(work.url) == before)
    }

    @Test("a link put where the log goes is not written through")
    func notThroughALink() throws {
        let paths = udeck.paths
        try FileManager.default.createDirectory(at: paths.logs, withIntermediateDirectories: true)
        let theirs = work.url.appendingPathComponent("notes.txt")
        try Data("the author's\n".utf8).write(to: theirs)
        try FileManager.default.createSymbolicLink(atPath: paths.log(forPlugin: id).path, withDestinationPath: theirs.path)
        #expect(throws: RunLog.Refusal.notAFile(paths.log(forPlugin: id).path)) {
            try RunLog(paths: paths).append(run(), for: id, linkTarget: work.url)
        }
        #expect(try String(contentsOf: theirs, encoding: .utf8) == "the author's\n")
        RunLog(paths: paths).remove(for: id)
        #expect(PluginInstaller.isLink(paths.log(forPlugin: id)), "remove takes files it made, not a link")
    }

    /// What the disk said, in the system's words: a logs folder that cannot be
    /// made fails in Foundation, whose error's code is Cocoa's own (513) and
    /// no `errno` — read as one it said "Unknown error: 513".
    @Test("a log that cannot be written says why in the system's words")
    func cannotWriteSaysWhy() throws {
        let root = udeck.url.appendingPathComponent("locked", isDirectory: true)
        let manager = FileManager.default
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        try manager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)
        defer { try? manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path) }
        let paths = UDeckPaths(root: root)
        #expect(throws: RunLog.Refusal.cannotWrite(paths.logs.path, because: "Permission denied")) {
            try RunLog(paths: paths).append(run(), for: id, linkTarget: work.url)
        }
        #expect(RunLog.Refusal.cannotWrite(paths.logs.path, because: "Permission denied").description
                == "could not write \(paths.logs.path): Permission denied")

        // The folder there and the file not to be made in it: `errno`, as before.
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        try manager.createDirectory(at: paths.logs, withIntermediateDirectories: true)
        try manager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: paths.logs.path)
        defer { try? manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: paths.logs.path) }
        #expect(throws: RunLog.Refusal.cannotWrite(paths.log(forPlugin: id).path, because: "Permission denied")) {
            try RunLog(paths: paths).append(run(), for: id, linkTarget: work.url)
        }
        #expect(RunLog.Refusal.because(CocoaError(.fileWriteUnknown)) == CocoaError(.fileWriteUnknown).localizedDescription,
                "an error with no errno under it is said in its own words")
        // An error that is itself the system's: its code is the errno.
        #expect(RunLog.Refusal.because(NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))) == "Permission denied")
        #expect(NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES)).localizedDescription != "Permission denied",
                "the premise: Foundation's own words for it are others")
    }

    /// Asked from the main actor, as the panel asks: the entry is written on
    /// the writer's own queue, and the main thread is never what writes it.
    @MainActor
    @Test("the writer writes off the main thread, in order")
    func offTheMainThread() async throws {
        let writer = RunLogWriter()
        let seen = Seen()
        for number in 1 ... 3 {
            writer.write(run(stderr: "run \(number)"), for: id, linkTarget: work.url, to: RunLog(paths: udeck.paths)) { error, onMain in
                seen.record(error: error, onMain: onMain)
            }
        }
        await writer.drain()
        #expect(seen.calls == 3)
        #expect(!seen.anyOnMain, "a run log entry was written on the main thread")
        #expect(seen.errors.isEmpty, "\(seen.errors)")
        let text = try String(contentsOf: udeck.paths.log(forPlugin: id), encoding: .utf8)
        #expect(text.components(separatedBy: "  | run ").dropFirst().map { $0.prefix(1) } == ["1", "2", "3"])
    }
}

final class Seen: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var calls = 0
    private(set) var anyOnMain = false
    private(set) var errors: [String] = []
    func record(error: (any Error)?, onMain: Bool) {
        lock.withLock {
            calls += 1
            anyOnMain = anyOnMain || onMain
            if let error { errors.append("\(error)") }
        }
    }
}

@Suite("A run, kept")
struct PluginRunTests {
    @Test("launch until the plugin has drawn a card since uDeck started, whatever asked; then what was asked",
          arguments: [RefreshReason.interval, .manual, .launch])
    func launchReason(_ asked: RefreshReason) {
        #expect(RefreshReason.of(asked, hasSpoken: false) == .launch)
        #expect(RefreshReason.of(asked, hasSpoken: true) == asked)
        let id = PluginIdentifier(rawValue: "greeter")!
        var snapshot = PluginSnapshot(pluginID: id)
        #expect(snapshot.reason(for: asked) == .launch, "the first run after uDeck starts")
        snapshot.record(PollAttempt(execution: .failure(PluginFailure(reason: .exited(code: 1))), run: nil), at: Date())
        #expect(snapshot.reason(for: asked) == .launch, "a first run that failed does not use the word up")
        snapshot.record(PollAttempt(execution: .lateCard(Card(), PluginFailure(reason: .timedOut(after: 2))), run: nil),
                        at: Date())
        #expect(snapshot.reason(for: asked) == asked, "a card, even a late one, has been drawn")
    }

    @Test("the last run is kept with its stderr whatever it came to, a card included; a run that never happened is not one")
    func lastRun() async {
        let temp = TemporaryDirectory()
        temp.writePlugin(folder: "chatty", manifest: """
            { "id": "chatty", "name": "Chatty", "version": "1.0.0", "api": 1, "kind": "poll",
              "run": ["./run.sh"], "interval": 30, "timeout": 5 }
            """, script: (name: "run.sh", body: "#!/bin/sh\necho 'said on the way' >&2\nprintf '{\"rows\": []}'\n", executable: true))
        let plugin = PluginDiscovery(searchPath: ["/usr/bin", "/bin"]).load(temp.plugins.appendingPathComponent("chatty"))
        let attempt = await PollExecutor().attempt(
            plugin: plugin, grant: nil, enabled: true, settings: PluginSettings(), paths: temp.paths,
            searchPath: AppSettings().pluginExecutableSearchPath, appearance: .dark, reason: .launch, language: "en")
        guard case .card = attempt.execution else { Issue.record("\(attempt.execution)"); return }
        let run = attempt.run
        #expect(run?.result == .card)
        #expect(run?.standardError == "said on the way\n")
        #expect(run?.reason == .launch)
        #expect(run?.termination == .exited(code: 0))
        var snapshot = PluginSnapshot(pluginID: PluginIdentifier(rawValue: "chatty")!)
        snapshot.record(attempt, at: Date())
        #expect(snapshot.lastRun == run)
        #expect(snapshot.failure == nil && snapshot.card != nil)

        let refused = await PollExecutor().attempt(
            plugin: plugin, grant: nil, enabled: false, settings: PluginSettings(), paths: temp.paths,
            searchPath: AppSettings().pluginExecutableSearchPath, appearance: .dark, reason: .interval, language: "en")
        #expect(refused.run == nil)
        snapshot.record(refused, at: Date())
        #expect(snapshot.lastRun == run, "nothing ran: the last run is still the last one that did")
    }

    @Test("the run log switch is off unless the settings file turns it on, and is kept when written")
    func runLogSwitch() throws {
        #expect(!AppSettings().writesLinkedFolderRunLog)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"linkedFolderRunLog": true}"#.utf8))
        #expect(decoded.writesLinkedFolderRunLog)
        let again = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(decoded))
        #expect(again.linkedFolderRunLog == true)
        #expect(try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8)).linkedFolderRunLog == nil)
    }
}
