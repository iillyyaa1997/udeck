import Darwin
import Foundation
import Testing
@testable import UDeckCore

/// Installing, updating and removing a plugin from a repository, on a real
/// disk: every refusal leaves `~/.udeck` as it was, a swap is one step or a
/// fallback that puts things back, and a crash halfway is finished or undone
/// at the next launch.
@Suite("Installing plugins")
struct PluginInstallerTests {
    let temp = TemporaryDirectory()
    var paths: UDeckPaths { temp.paths }
    var discovery: PluginDiscovery { PluginDiscovery(searchPath: ["/bin", "/usr/bin"], udeck: SemanticVersion("0.5.0")) }

    func installer(_ log: FetchLog, trash: TestTrash? = nil, renames: FolderRenames = .system) -> PluginInstaller {
        PluginInstaller(paths: paths, discovery: discovery, trash: trash ?? TestTrash(in: temp.url),
                        renames: renames, fetch: log.fetch, now: { Date(timeIntervalSince1970: 1_790_000_000) })
    }

    func request(_ repository: FakeRepository, _ operation: InstallRequest.Operation = .install,
                 id: String = "uptime", version: String = "1.0.0") -> InstallRequest {
        InstallRequest(operation: operation, id: PluginIdentifier(rawValue: id)!, repository: .official,
                       ref: PluginRef(name: "main"), commit: repository.commit, folder: repository.plugin(id),
                       version: version, headCommit: repository.commit)
    }

    var live: URL { paths.plugins.appendingPathComponent("uptime", isDirectory: true) }

    func stagingIsEmpty() -> Bool {
        ((try? FileManager.default.contentsOfDirectory(atPath: paths.staging.path)) ?? []).isEmpty
    }

    func records() throws -> InstalledPlugins {
        try JSONFileStore<InstalledPlugins>(url: paths.installedFile).load() ?? InstalledPlugins()
    }

    func expectRefused(_ body: () async throws -> Void, _ wanted: @escaping (RepositoryRefusal) -> Bool,
                       sourceLocation: SourceLocation = #_sourceLocation) async {
        do {
            try await body()
            Issue.record("it was not refused", sourceLocation: sourceLocation)
        } catch let error as InstallError {
            #expect(error.refusals.contains(where: wanted), "refused for another reason: \(error)",
                    sourceLocation: sourceLocation)
        } catch {
            Issue.record("failed another way: \(error)", sourceLocation: sourceLocation)
        }
    }

    // MARK: - A clean install

    @Test("a clean install puts exactly the listed folder in place, with its modes, and records it")
    func cleanInstall() async throws {
        var repository = FakeRepository.withUptime()
        repository.addPlugin("other")
        let log = FetchLog(repository)
        let installer = installer(log)
        let staged = try await installer.stage(request(repository))
        let record = try installer.commit(staged)

        #expect(Set(log.paths) == ["plugins/uptime/manifest.json", "plugins/uptime/uptime.sh", "plugins/uptime/README.md"],
                "only that plugin's files, and nothing else in the repository")
        #expect(try GitHash.tree(ofDirectoryAt: live) == repository.treeID("plugins/uptime"))
        #expect(FileManager.default.isExecutableFile(atPath: live.appendingPathComponent("uptime.sh").path))
        let readme = try FileManager.default.attributesOfItem(atPath: live.appendingPathComponent("README.md").path)
        #expect((readme[.posixPermissions] as? NSNumber)?.intValue == 0o644)
        #expect(stagingIsEmpty())

        let stored = try #require(try records().plugins["uptime"])
        #expect(stored == record)
        #expect(stored.commit == repository.commit && stored.tree == repository.treeID("plugins/uptime"))
        #expect(stored.version == "1.0.0" && stored.pinned == false && stored.previous == nil)
        #expect(stored.verification.status == .verified && stored.verification.by == "official")
        #expect(stored.ref == PluginRef(kind: "default", name: "main"))
        #expect(discovery.load(live).isUsable)
    }

    /// Every field, `null`s written rather than left out: the record's shape is
    /// part of what the specification promises.
    @Test("installed.json carries every field, null included")
    func recordShape() async throws {
        let repository = FakeRepository.withUptime()
        let installer = installer(FetchLog(repository))
        try installer.commit(try await installer.stage(request(repository)))
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: paths.installedFile)) as? [String: Any])
        #expect(json["version"] as? Int == 1)
        let uptime = try #require((json["plugins"] as? [String: Any])?["uptime"] as? [String: Any])
        #expect(Set(uptime.keys) == ["source", "repository", "ref", "commit", "tree", "version", "installedAt",
                                     "pinned", "verification", "previous"])
        #expect(uptime["previous"] is NSNull)
        #expect(uptime["installedAt"] as? String == "2026-09-21T14:13:20Z")
        #expect(Set((uptime["verification"] as? [String: Any] ?? [:]).keys) == ["status", "by", "checkedAgainst", "checkedAt"])
        #expect(Set((uptime["repository"] as? [String: Any] ?? [:]).keys) == ["provider", "host", "path"])
        #expect(Set((uptime["ref"] as? [String: Any] ?? [:]).keys) == ["kind", "name"])
    }

    // MARK: - Refusals, each leaving ~/.udeck as it was

    @Test("a file whose hash is wrong is refused, and nothing is installed")
    func wrongHash() async throws {
        let repository = FakeRepository.withUptime()
        let log = FetchLog(repository)
        log.alter("plugins/uptime/uptime.sh", to: Data("#!/bin/sh\nrm -rf ~\n".utf8))
        await expectRefused({ _ = try await installer(log).stage(request(repository)) }) {
            if case .arrivedDifferent("plugins/uptime/uptime.sh", let expected, let got) = $0 {
                return expected.count == 7 && got.count == 7 && expected != got
            }
            return false
        }
        #expect(!FileManager.default.fileExists(atPath: live.path))
        #expect(stagingIsEmpty())
        #expect(!FileManager.default.fileExists(atPath: paths.installedFile.path))
    }

    @Test("a file missing from the listing, or one too many, does not add up to the folder")
    func missingOrExtra() async throws {
        let repository = FakeRepository.withUptime()
        var short = request(repository)
        short.folder.entries.removeAll { $0.path == "README.md" }
        await expectRefused({ _ = try await installer(FetchLog(repository)).stage(short) }) {
            $0 == .folderDoesNotAddUp(id: "uptime")
        }
        var extra = request(repository)
        extra.folder.entries.append(ListedEntry(path: "extra.txt", mode: "100644",
                                                sha: GitHash.blob(Data("x".utf8)), size: 1))
        var withExtra = repository
        withExtra.files["plugins/uptime/extra.txt"] = .init("x")
        await expectRefused({ _ = try await installer(FetchLog(withExtra)).stage(extra) }) {
            $0 == .folderDoesNotAddUp(id: "uptime")
        }
        #expect(stagingIsEmpty())
        #expect(!FileManager.default.fileExists(atPath: live.path))
    }

    @Test("links, submodules, names out of rule and a folder too big are refused before a single request")
    func refusedByTheListing() async throws {
        let cases: [(String, FakeRepository.File, (RepositoryRefusal) -> Bool)] = [
            ("lib", .init(data: Data("/etc".utf8), mode: "120000"), { $0 == .linkOrSubmodule(path: "plugins/uptime/lib", isLink: true) }),
            ("sub", .init(data: Data(), mode: "160000"), { $0 == .linkOrSubmodule(path: "plugins/uptime/sub", isLink: false) }),
            ("Run Me.sh", .init("x"), { $0 == .nameNotAllowed(path: "plugins/uptime/Run Me.sh") }),
            ("big.bin", .init(data: Data(count: 11 * 1024 * 1024), mode: "100644"), { if case .tooLarge = $0 { true } else { false } }),
        ]
        for (name, file, wanted) in cases {
            var repository = FakeRepository.withUptime()
            repository.files["plugins/uptime/\(name)"] = file
            let log = FetchLog(repository)
            await expectRefused({ _ = try await installer(log).stage(request(repository)) }, wanted)
            #expect(log.paths.isEmpty, "\(name): files were requested for a plugin the listing already refused")
        }
        #expect(stagingIsEmpty())
    }

    @Test("a Git LFS pointer stops the install")
    func lfsPointer() async throws {
        var repository = FakeRepository.withUptime()
        repository.files["plugins/uptime/data.bin"] = .init("version https://git-lfs.github.com/spec/v1\noid sha256:0\nsize 9\n")
        await expectRefused({ _ = try await installer(FetchLog(repository)).stage(request(repository)) }) {
            $0 == .lfsPointer(path: "plugins/uptime/data.bin")
        }
        #expect(stagingIsEmpty())
    }

    @Test("with the manifest in hand, an api this uDeck does not speak is refused before anything is requested")
    func refusedByTheManifest() async throws {
        var repository = FakeRepository()
        repository.addPlugin("uptime", manifest: FakeRepository.manifest(version: "2.0.0", api: 2))
        let log = FetchLog(repository)
        await expectRefused({
            _ = try await installer(log).stage(request(repository, version: "2.0.0"),
                                               manifest: repository.data(at: "plugins/uptime/manifest.json"))
        }) { $0 == .apiNotSpoken(name: "uptime", version: "2.0.0", api: 2) }
        #expect(log.paths.isEmpty)
    }

    @Test("a folder that fails the usual checks is refused with the words a hand-copied folder gets")
    func failsTheUsualChecks() async throws {
        var repository = FakeRepository()
        repository.addPlugin("uptime", manifest: FakeRepository.manifest(run: "nosuchcommand-anywhere"))
        await expectRefused({ _ = try await installer(FetchLog(repository)).stage(request(repository)) }) {
            if case .failsTheUsualChecks("uptime", let detail) = $0 { return detail.contains("nosuchcommand-anywhere") }
            return false
        }
    }

    @Test("what arrives has to be the version the catalogue showed")
    func versionShown() async throws {
        let repository = FakeRepository.withUptime(version: "1.1.0")
        await expectRefused({ _ = try await installer(FetchLog(repository)).stage(request(repository, version: "1.0.0")) }) {
            $0 == .notTheVersionShown(id: "uptime", shown: "1.0.0", arrived: "1.1.0")
        }
    }

    @Test("a request that keeps failing is retried twice, then given up")
    func retries() async throws {
        let repository = FakeRepository.withUptime()
        let log = FetchLog(repository)
        log.fail("plugins/uptime/README.md")
        do {
            _ = try await installer(log).stage(request(repository))
            Issue.record("an unreachable file installed")
        } catch InstallError.unreachable(let path, _) {
            #expect(path == "plugins/uptime/README.md")
        }
        #expect(log.paths.filter { $0 == "plugins/uptime/README.md" }.count == 3)
        #expect(stagingIsEmpty())
    }

    @Test("a broken installed.json stops every install rather than being overwritten")
    func brokenRecords() async throws {
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        try Data("{ broken".utf8).write(to: paths.installedFile)
        let repository = FakeRepository.withUptime()
        do {
            _ = try await installer(FetchLog(repository)).stage(request(repository))
            Issue.record("installed over a broken installed.json")
        } catch InstallError.recordsBroken {}
        #expect(try String(contentsOf: paths.installedFile, encoding: .utf8) == "{ broken")
    }

    // MARK: - The swap

    @Test("an update swaps in one step, keeps the old version as previous, and deletes the old copy")
    func update() async throws {
        let first = FakeRepository.withUptime(version: "1.0.0")
        let trash = TestTrash(in: temp.url)
        try installer(FetchLog(first), trash: trash).commit(try await installer(FetchLog(first)).stage(request(first)))

        var second = FakeRepository.withUptime(version: "1.1.0")
        second.commit = String(repeating: "d", count: 40)
        let updater = installer(FetchLog(second), trash: trash)
        let record = try updater.commit(try await updater.stage(request(second, .update, version: "1.1.0")))
        #expect(record.version == "1.1.0" && record.pinned == false)
        #expect(record.previous == PreviousCopy(ref: PluginRef(name: "main"), commit: first.commit,
                                                tree: first.treeID("plugins/uptime")!, version: "1.0.0"))
        #expect(try GitHash.tree(ofDirectoryAt: live) == second.treeID("plugins/uptime"))
        #expect(trash.names.isEmpty, "uDeck's own copy is deleted, not trashed")
        #expect(stagingIsEmpty())
    }

    @Test("an earlier version is pinned; an update after it clears the pin")
    func pinning() async throws {
        let first = FakeRepository.withUptime(version: "1.1.0")
        let i = installer(FetchLog(first))
        try i.commit(try await i.stage(request(first, version: "1.1.0")))
        var older = FakeRepository.withUptime(version: "1.0.0")
        older.commit = String(repeating: "e", count: 40)
        let back = installer(FetchLog(older))
        #expect(try back.commit(try await back.stage(request(older, .earlier))).pinned)
        let forward = installer(FetchLog(first))
        #expect(!(try forward.commit(try await forward.stage(request(first, .update, version: "1.1.0"))).pinned))
    }

    @Test("a folder of the operator's own, or one they changed, goes to the Trash")
    func ownFolderToTheTrash() async throws {
        let repository = FakeRepository.withUptime()
        let trash = TestTrash(in: temp.url)
        temp.writePlugin(folder: "uptime", manifest: FakeRepository.manifest(),
                         script: (name: "uptime.sh", body: "#!/bin/sh\necho mine\n", executable: true))
        let replacer = installer(FetchLog(repository), trash: trash)
        try replacer.commit(try await replacer.stage(request(repository, .replace)))
        #expect(trash.names == ["uptime"])
        #expect(try GitHash.tree(ofDirectoryAt: live) == repository.treeID("plugins/uptime"))

        // Changed locally, then reinstalled: the changed copy goes to the Trash too.
        try Data("# mine now\n".utf8).write(to: live.appendingPathComponent("README.md"))
        let reinstaller = installer(FetchLog(repository), trash: trash)
        try reinstaller.commit(try await reinstaller.stage(request(repository, .reinstall)))
        #expect(trash.names == ["uptime", "uptime"])
    }

    /// The tree hash skips dot-names, so a folder holding the operator's `.env`
    /// still hashes to what was installed — and must still not be deleted.
    @Test("a dot-file the operator put into an installed plugin sends the old copy to the Trash, on update and on removal")
    func dotFilesAreTheOperators() async throws {
        let first = FakeRepository.withUptime(version: "1.0.0")
        let trash = TestTrash(in: temp.url)
        try installer(FetchLog(first), trash: trash).commit(try await installer(FetchLog(first)).stage(request(first)))
        try Data("TOKEN=mine\n".utf8).write(to: live.appendingPathComponent(".env"))
        #expect(try GitHash.tree(ofDirectoryAt: live) == first.treeID("plugins/uptime"), "the hash does not see it")

        var second = FakeRepository.withUptime(version: "1.1.0")
        second.commit = String(repeating: "d", count: 40)
        let updater = installer(FetchLog(second), trash: trash)
        try updater.commit(try await updater.stage(request(second, .update, version: "1.1.0")))
        #expect(trash.names == ["uptime"], "the copy holding .env goes to the Trash, not away")
        let trashed = try FileManager.default.contentsOfDirectory(at: trash.folder, includingPropertiesForKeys: nil)
        #expect(trashed.contains { FileManager.default.fileExists(atPath: $0.appendingPathComponent(".env").path) })

        // Removal, with a working copy's .git in a subfolder of the plugin.
        let git = live.appendingPathComponent("lib/.git", isDirectory: true)
        try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
        try Data("ref: refs/heads/main\n".utf8).write(to: git.appendingPathComponent("HEAD"))
        let remover = installer(FetchLog(second), trash: trash)
        try remover.finishRemoval(try remover.beginRemoval(PluginIdentifier(rawValue: "uptime")!))
        #expect(trash.names == ["uptime", "uptime"])
    }

    @Test("what the hash leaves out is named, and the Finder's .DS_Store is not the operator's")
    func unhashedEntries() async throws {
        let repository = FakeRepository.withUptime()
        let trash = TestTrash(in: temp.url)
        let i = installer(FetchLog(repository), trash: trash)
        try i.commit(try await i.stage(request(repository)))
        #expect(GitHash.unhashed(inDirectoryAt: live).isEmpty)

        try Data().write(to: live.appendingPathComponent(".DS_Store"))
        try FileManager.default.createSymbolicLink(at: live.appendingPathComponent("latest"),
                                                   withDestinationURL: live.appendingPathComponent("README.md"))
        #expect(GitHash.unhashed(inDirectoryAt: live) == ["latest"])
        try FileManager.default.removeItem(at: live.appendingPathComponent("latest"))

        // Only the Finder's file: uDeck's own copy, deleted as any other.
        let reinstaller = installer(FetchLog(repository), trash: trash)
        try reinstaller.commit(try await reinstaller.stage(request(repository, .reinstall)))
        #expect(trash.names.isEmpty)
    }

    @Test("a folder that appeared before the rename is not overwritten")
    func folderAppeared() async throws {
        let repository = FakeRepository.withUptime()
        let i = installer(FetchLog(repository))
        let staged = try await i.stage(request(repository))
        // Appears after the install looked, before it moved anything: a swap
        // told there was nothing to swap with must fail rather than clobber it.
        let renames = FolderRenames(exchange: FolderRenames.system.exchange, exclusive: { from, to in
            try? FileManager.default.createDirectory(at: to, withIntermediateDirectories: true)
            try? Data("mine".utf8).write(to: to.appendingPathComponent("keep.txt"))
            return FolderRenames.system.exclusive(from, to)
        })
        do {
            try installer(FetchLog(repository), renames: renames).commit(staged)
            Issue.record("installed over a folder that appeared")
        } catch let error as InstallError {
            #expect(error.refusals == [.folderAppeared(id: "uptime")])
        }
        #expect(try String(contentsOf: live.appendingPathComponent("keep.txt"), encoding: .utf8) == "mine")
        #expect(try records().plugins["uptime"] == nil)
        #expect(stagingIsEmpty())
    }

    @Test("on a volume that cannot swap, two renames do the same job")
    func swapFallback() async throws {
        let first = FakeRepository.withUptime(version: "1.0.0")
        let i = installer(FetchLog(first))
        try i.commit(try await i.stage(request(first)))
        var second = FakeRepository.withUptime(version: "1.1.0")
        second.commit = String(repeating: "d", count: 40)
        let cannotSwap = FolderRenames(exchange: { _, _ in ENOTSUP }, exclusive: FolderRenames.system.exclusive)
        let updater = installer(FetchLog(second), renames: cannotSwap)
        let record = try updater.commit(try await updater.stage(request(second, .update, version: "1.1.0")))
        #expect(record.version == "1.1.0")
        #expect(try GitHash.tree(ofDirectoryAt: live) == second.treeID("plugins/uptime"))
        #expect(stagingIsEmpty())
    }

    /// Both moves of the fallback failing — the new copy into place, and the
    /// old one back — used to throw the staging folder away with the old copy
    /// in it, which may be a folder of the operator's own.
    @Test("on a volume that cannot swap, a failed move and a failed move back keep the old copy for the next launch")
    func swapFallbackFailsTwice() async throws {
        temp.writePlugin(folder: "uptime", manifest: FakeRepository.manifest(),
                         script: (name: "uptime.sh", body: "#!/bin/sh\necho mine\n", executable: true))
        let mine = try GitHash.tree(ofDirectoryAt: live)
        let repository = FakeRepository.withUptime()
        let livePath = live.standardizedFileURL.path
        let stuck = FolderRenames(exchange: { _, _ in ENOTSUP }, exclusive: FolderRenames.system.exclusive,
                                  move: { from, to in
            if to.standardizedFileURL.path == livePath { throw CocoaError(.fileWriteNoPermission) }
            try FolderRenames.fileManagerMove(from, to)
        })
        let staged = try await installer(FetchLog(repository)).stage(request(repository, .replace))
        let trash = TestTrash(in: temp.url)
        #expect(throws: InstallError.self) {
            try installer(FetchLog(repository), trash: trash, renames: stuck).commit(staged)
        }
        #expect(!FileManager.default.fileExists(atPath: live.path), "neither copy could be moved in")
        #expect(!stagingIsEmpty(), "the old copy waits in staging, beside its journal")
        #expect(try records().plugins["uptime"] == nil)

        let done = installer(FetchLog(repository), trash: trash).recover()
        #expect(done == [.neverSwapped(id: "uptime")])
        #expect(try GitHash.tree(ofDirectoryAt: live) == mine, "the next launch puts the operator's folder back")
        #expect(trash.names.isEmpty)
        #expect(stagingIsEmpty())
    }

    /// A Mac's volume ignores case: `plugins/Uptime` is where the swap for
    /// `uptime` lands, so it has to count as taken wherever the question is asked.
    @Test("a folder spelt with other case is taken, on a volume that ignores case")
    func folderTakenIgnoringCase() throws {
        let other = paths.plugins.appendingPathComponent("Uptime", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let i = installer(FetchLog(FakeRepository()))
        #expect(i.folderIsTaken("Uptime"))
        #expect(!i.folderIsTaken("other"))
        // The temporary directory is on the Mac's own volume, which ignores
        // case as it ships; on a volume set up to tell case apart there is
        // nothing more to ask.
        let probe = paths.plugins.appendingPathComponent("uPTIME", isDirectory: true)
        guard FileManager.default.fileExists(atPath: probe.path) else { return }
        #expect(i.folderIsTaken("uptime"))
        #expect(PluginInstaller.folderIsTaken("uptime", in: paths))
    }

    // MARK: - Removal

    @Test("removal takes the folder, the record and the cache, and nothing of the catalogue")
    func removal() async throws {
        let repository = FakeRepository.withUptime()
        let i = installer(FetchLog(repository))
        try i.commit(try await i.stage(request(repository)))
        let cache = paths.cache(forPlugin: PluginIdentifier(rawValue: "uptime")!)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data("3".utf8).write(to: cache.appendingPathComponent("runs"))
        let catalogue = paths.catalogue.appendingPathComponent("official/state.json")
        try FileManager.default.createDirectory(at: catalogue.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: catalogue)

        let removal = try i.beginRemoval(PluginIdentifier(rawValue: "uptime")!)
        #expect(!FileManager.default.fileExists(atPath: live.path), "gone from the plugins folder at once")
        try i.finishRemoval(removal)
        #expect(!FileManager.default.fileExists(atPath: cache.path))
        #expect(try records().plugins["uptime"] == nil)
        #expect(FileManager.default.fileExists(atPath: catalogue.path))
        #expect(stagingIsEmpty())
    }

    @Test("removing a folder of the operator's own moves it to the Trash")
    func removalOfYourOwn() throws {
        temp.writePlugin(folder: "uptime", manifest: FakeRepository.manifest(),
                         script: (name: "uptime.sh", body: "#!/bin/sh\n", executable: true))
        let trash = TestTrash(in: temp.url)
        let i = installer(FetchLog(FakeRepository()), trash: trash)
        try i.finishRemoval(try i.beginRemoval(PluginIdentifier(rawValue: "uptime")!))
        #expect(trash.names == ["uptime"])
        #expect(!FileManager.default.fileExists(atPath: live.path))
    }

    // MARK: - Recovering from a crash halfway

    func stagingFolder(_ intent: InstallIntent, holding folder: FakeRepository? = nil) throws -> URL {
        let directory = paths.staging.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder.iso8601.encode(intent)
        try data.write(to: directory.appendingPathComponent("intent.json"))
        if let folder { try write(folder, into: directory.appendingPathComponent(intent.id)) }
        return directory
    }

    func write(_ repository: FakeRepository, into folder: URL, id: String = "uptime") throws {
        for (path, file) in repository.files where path.hasPrefix("plugins/\(id)/") {
            let url = folder.appendingPathComponent(String(path.dropFirst("plugins/\(id)/".count)))
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try file.data.write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: file.mode == "100755" ? 0o755 : 0o644],
                                                  ofItemAtPath: url.path)
        }
    }

    func intendedRecord(_ repository: FakeRepository) -> InstalledRecord {
        InstalledRecord(source: "official", repository: .official, ref: PluginRef(name: "main"),
                        commit: repository.commit, tree: repository.treeID("plugins/uptime")!, version: "1.0.0",
                        installedAt: Date(timeIntervalSince1970: 1_790_000_000), pinned: false,
                        verification: PluginVerification(status: .verified, by: "official", checkedAgainst: nil,
                                                         checkedAt: Date(timeIntervalSince1970: 1_790_000_000)),
                        previous: nil)
    }

    @Test("a crash after the swap and before the record: the record is written at launch")
    func recoverAfterTheSwap() throws {
        let repository = FakeRepository.withUptime()
        try write(repository, into: live)
        let old = FakeRepository.withUptime(version: "0.9.0")
        let trash = TestTrash(in: temp.url)
        _ = try stagingFolder(InstallIntent(operation: .update, id: "uptime", record: intendedRecord(repository),
                                            oldCopyIsOperators: true), holding: old)
        let done = installer(FetchLog(repository), trash: trash).recover()
        #expect(done == [.recordWritten(id: "uptime")])
        #expect(try records().plugins["uptime"] == intendedRecord(repository))
        #expect(trash.names == ["uptime"], "the operator's copy that lost goes to the Trash")
        #expect(stagingIsEmpty())
    }

    @Test("a crash before the swap: nothing to undo, the download goes, the folder is untouched")
    func recoverBeforeTheSwap() throws {
        let old = FakeRepository.withUptime(version: "0.9.0")
        try write(old, into: live)
        let repository = FakeRepository.withUptime()
        let trash = TestTrash(in: temp.url)
        _ = try stagingFolder(InstallIntent(operation: .install, id: "uptime", record: intendedRecord(repository),
                                            oldCopyIsOperators: true), holding: repository)
        let done = installer(FetchLog(repository), trash: trash).recover()
        #expect(done == [.neverSwapped(id: "uptime")])
        #expect(try GitHash.tree(ofDirectoryAt: live) == old.treeID("plugins/uptime"))
        #expect(try records().plugins["uptime"] == nil)
        #expect(trash.names.isEmpty)
        #expect(stagingIsEmpty())
    }

    @Test("a crash between the fallback's two renames puts the old copy back")
    func recoverBetweenTheRenames() throws {
        let old = FakeRepository.withUptime(version: "0.9.0")
        let repository = FakeRepository.withUptime()
        let directory = try stagingFolder(InstallIntent(operation: .update, id: "uptime",
                                                        record: intendedRecord(repository), oldCopyIsOperators: false),
                                          holding: repository)
        try write(old, into: directory.appendingPathComponent("displaced/uptime"))
        let done = installer(FetchLog(repository)).recover()
        #expect(done == [.neverSwapped(id: "uptime")])
        #expect(try GitHash.tree(ofDirectoryAt: live) == old.treeID("plugins/uptime"))
        #expect(stagingIsEmpty())
    }

    @Test("a removal whose folder had gone is finished; one whose folder is there never started")
    func recoverRemoval() throws {
        let repository = FakeRepository.withUptime()
        try JSONFileStore<InstalledPlugins>(url: paths.installedFile)
            .save(InstalledPlugins(plugins: ["uptime": intendedRecord(repository)]))
        let cache = paths.cache(forPlugin: PluginIdentifier(rawValue: "uptime")!)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        _ = try stagingFolder(InstallIntent(operation: .remove, id: "uptime", record: nil, oldCopyIsOperators: false),
                              holding: repository)
        #expect(installer(FetchLog(repository)).recover() == [.removalFinished(id: "uptime")])
        #expect(try records().plugins["uptime"] == nil)
        #expect(!FileManager.default.fileExists(atPath: cache.path))
        #expect(stagingIsEmpty())

        try write(repository, into: live)
        _ = try stagingFolder(InstallIntent(operation: .remove, id: "uptime", record: nil, oldCopyIsOperators: false))
        #expect(installer(FetchLog(repository)).recover() == [.removalNeverStarted(id: "uptime")])
        #expect(FileManager.default.fileExists(atPath: live.path))
        #expect(stagingIsEmpty())
    }

    @Test("a staging folder with no journal is thrown away")
    func recoverWithoutAJournal() throws {
        let directory = paths.staging.appendingPathComponent("orphan", isDirectory: true)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("uptime"), withIntermediateDirectories: true)
        #expect(installer(FetchLog(FakeRepository())).recover() == [.discarded(directory: "orphan")])
        #expect(stagingIsEmpty())
    }
}
