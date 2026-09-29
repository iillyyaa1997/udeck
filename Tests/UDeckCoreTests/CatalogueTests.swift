import Foundation
import Testing
@testable import UDeckCore

/// Turning a listing into catalogue rows: rules 1–9, the manifest checks a row
/// makes before it offers Install, a truncated listing, and what an installed
/// plugin's row says about the head.
@Suite("The catalogue")
struct CatalogueTests {
    let udeck = SemanticVersion("0.5.0")

    func verdict(_ repository: FakeRepository, _ id: String = "uptime") -> RepositoryRules.Verdict {
        RepositoryRules.check(folder: id, listing: repository.plugin(id),
                              manifest: repository.data(at: "plugins/\(id)/manifest.json"), udeck: udeck)
    }

    // MARK: - The listing

    @Test("a recursive listing keeps the passport and each plugin folder, and nothing else")
    func listingFromATree() {
        var repository = FakeRepository.withUptime()
        repository.files["README.md"] = .init("# repo\n")
        repository.files[".github/workflows/validate.yml"] = .init("on: push\n")
        repository.files["plugins/stray.txt"] = .init("not a folder\n")
        let listing = repository.listing
        #expect(listing.passport == GitHash.blob(Data(FakeRepository.passport.utf8)))
        #expect(listing.pluginFolders == ["uptime"])
        #expect(listing.strays == ["stray.txt"])
        #expect(listing.plugins["uptime"]?.tree == repository.treeID("plugins/uptime"))
        #expect(Set(listing.plugins["uptime"]!.files.map(\.path)) == ["manifest.json", "uptime.sh", "README.md"])
        #expect(listing.plugins["uptime"]?.file(at: "uptime.sh")?.kind == .executable)
    }

    @Test("a listing too large for one answer is put together from its pieces, and comes out the same")
    func truncatedListing() {
        var repository = FakeRepository.withUptime()
        repository.addPlugin("second")
        repository.files["plugins/second/lib/deep.sh"] = .init("#!/bin/sh\n", executable: true)
        let root = repository.folderTree("")
        let plugins = repository.folderTree("plugins")
        var folders: [String: GitTree] = [:]
        for entry in plugins.tree where entry.type == "tree" {
            folders[entry.path] = repository.folderTreeRecursive("plugins/\(entry.path)")
        }
        let assembled = CommitListing(commit: repository.commit, root: root, pluginsFolder: plugins, folders: folders)
        let whole = repository.listing
        #expect(assembled.passport == whole.passport)
        #expect(assembled.pluginFolders == whole.pluginFolders)
        for id in whole.pluginFolders {
            #expect(assembled.plugins[id]?.tree == whole.plugins[id]?.tree)
            #expect(Set(assembled.plugins[id]!.entries.map(\.path)) == Set(whole.plugins[id]!.entries.map(\.path)))
        }
    }

    // MARK: - Rules 1–9

    @Test("a good plugin is installable, and nothing but its manifest was needed to say so")
    func goodPlugin() {
        let found = verdict(.withUptime())
        #expect(found.isInstallable, "\(found.refusals)")
        #expect(found.manifest?.version == "1.0.0")
    }

    @Test("rule 1: a folder whose name is not an id is not installable")
    func ruleOne() {
        var repository = FakeRepository.withUptime()
        repository.addPlugin("Upper", manifest: FakeRepository.manifest(id: "upper"))
        #expect(verdict(repository, "Upper").refusals.contains(.folderNameNotAnID(folder: "Upper")))
    }

    @Test("rule 3: no manifest, a manifest that will not decode, an id that is not the folder's")
    func ruleThree() {
        var repository = FakeRepository.withUptime()
        repository.files["plugins/nomanifest/run.sh"] = .init("#!/bin/sh\n", executable: true)
        #expect(verdict(repository, "nomanifest").refusals == [.noManifest(path: "plugins/nomanifest/manifest.json")])

        repository.addPlugin("broken", manifest: #"{ "id": "broken" "#)
        guard case .manifestUnreadable(let path, _)? = verdict(repository, "broken").refusals.first else {
            Issue.record("a broken manifest was not refused: \(verdict(repository, "broken").refusals)"); return
        }
        #expect(path == "plugins/broken/manifest.json")

        repository.addPlugin("elsewhere", manifest: FakeRepository.manifest(id: "other"))
        #expect(verdict(repository, "elsewhere").refusals.contains(.manifestIDMismatch(declared: "other", folder: "elsewhere")))

        repository.addPlugin("slow", manifest: FakeRepository.manifest(id: "slow").replacingOccurrences(of: "\"timeout\": 2", with: "\"timeout\": 90"))
        #expect(verdict(repository, "slow").refusals.contains { if case .manifestProblem = $0 { true } else { false } })
    }

    @Test("an api this uDeck does not speak, and a minUDeck it does not meet, are the first reasons")
    func apiAndMinUDeck() {
        var repository = FakeRepository.withUptime()
        repository.addPlugin("future", manifest: FakeRepository.manifest(id: "future", version: "2.0.0", api: 2))
        repository.addPlugin("newer", manifest: FakeRepository.manifest(id: "newer", version: "1.4.0", minUDeck: "99.0.0"))
        #expect(verdict(repository, "future").refusals.first == .apiNotSpoken(name: "future", version: "2.0.0", api: 2))
        #expect(verdict(repository, "newer").refusals.first
                == .needsNewerUDeck(name: "newer", version: "1.4.0", required: "99.0.0", running: "0.5.0"))
        // Still shown, with the manifest read: a plugin that silently does not
        // appear is a support question.
        #expect(verdict(repository, "future").manifest != nil)
    }

    @Test("rule 4: a version or minUDeck that does not parse cannot be installed from a repository")
    func ruleFour() {
        var repository = FakeRepository.withUptime()
        repository.addPlugin("draft", manifest: FakeRepository.manifest(id: "draft", version: "1.2"))
        repository.addPlugin("vague", manifest: FakeRepository.manifest(id: "vague", minUDeck: "soon"))
        #expect(verdict(repository, "draft").refusals == [.versionNotComparable(name: "draft", version: "1.2")])
        #expect(verdict(repository, "vague").refusals == [.minUDeckNotComparable(name: "vague", text: "soon")])
    }

    @Test("rule 5: a relative run[0] has to be in the listing, committed as executable")
    func ruleFive() {
        var repository = FakeRepository.withUptime()
        repository.files["plugins/uptime/uptime.sh"] = .init("#!/bin/sh\n", executable: false)
        #expect(verdict(repository).refusals == [.producerNotExecutable(path: "plugins/uptime/uptime.sh")])

        repository.files["plugins/uptime/uptime.sh"] = nil
        #expect(verdict(repository).refusals == [.producerMissing(path: "plugins/uptime/uptime.sh")])

        repository.addPlugin("escape", manifest: FakeRepository.manifest(id: "escape", run: "../uptime/uptime.sh"))
        #expect(verdict(repository, "escape").refusals.contains(.producerOutsideFolder(path: "plugins/escape/../uptime/uptime.sh")))

        // A bare name is looked up on the search path, not in the listing.
        repository.addPlugin("bare", manifest: FakeRepository.manifest(id: "bare", run: "uptime"))
        #expect(verdict(repository, "bare").isInstallable)
    }

    @Test("rule 6: a symbolic link or a submodule is refused, naming the path")
    func ruleSix() {
        var repository = FakeRepository.withUptime()
        repository.files["plugins/uptime/lib"] = .init(data: Data("/etc".utf8), mode: "120000")
        #expect(verdict(repository).refusals == [.linkOrSubmodule(path: "plugins/uptime/lib", isLink: true)])
        repository.files["plugins/uptime/lib"] = .init(data: Data(), mode: "160000")
        #expect(verdict(repository).refusals == [.linkOrSubmodule(path: "plugins/uptime/lib", isLink: false)])
    }

    @Test("rule 7: names out of the alphabet, dot-names, long names and names that differ only in case")
    func ruleSeven() {
        for name in ["Run Me.sh", ".env", "naïve.sh", "a$b", String(repeating: "n", count: 256)] {
            var repository = FakeRepository.withUptime()
            repository.files["plugins/uptime/\(name)"] = .init("x\n")
            #expect(verdict(repository).refusals == [.nameNotAllowed(path: "plugins/uptime/\(name)")],
                    "\(name.prefix(20)) was not refused: \(verdict(repository).refusals)")
        }
        var folder = FakeRepository.withUptime()
        folder.files["plugins/uptime/bad dir/x.txt"] = .init("x\n")
        #expect(verdict(folder).refusals == [.nameNotAllowed(path: "plugins/uptime/bad dir")])

        var cased = FakeRepository.withUptime()
        cased.files["plugins/uptime/Uptime.sh"] = .init("x\n")
        #expect(verdict(cased).refusals.count == 1)
        guard case .namesDifferOnlyInCase? = verdict(cased).refusals.first else {
            Issue.record("names differing in case were not refused"); return
        }
        var fine = FakeRepository.withUptime()
        fine.files["plugins/uptime/A-z_0.9"] = .init("x\n")
        #expect(verdict(fine).isInstallable)
    }

    @Test("rule 8: too many files, too many bytes, one file too big, folders too deep")
    func ruleEight() {
        var many = FakeRepository.withUptime()
        for index in 0 ..< 197 { many.files["plugins/uptime/data/f\(index)"] = .init("\(index)\n") }
        #expect(verdict(many).isInstallable, "200 files is the limit, not past it")
        many.files["plugins/uptime/data/one-more"] = .init("x\n")
        #expect(verdict(many).refusals.contains { if case .tooLarge(_, _, 201) = $0 { true } else { false } })

        var big = FakeRepository.withUptime()
        big.files["plugins/uptime/big.bin"] = .init(data: Data(count: 5 * 1024 * 1024 + 1), mode: "100644")
        #expect(verdict(big).refusals.contains(.fileTooLarge(path: "plugins/uptime/big.bin", bytes: 5 * 1024 * 1024 + 1)))

        var heavy = FakeRepository.withUptime()
        for index in 0 ..< 3 { heavy.files["plugins/uptime/part\(index)"] = .init(data: Data(count: 4 * 1024 * 1024), mode: "100644") }
        #expect(verdict(heavy).refusals.contains { if case .tooLarge = $0 { true } else { false } })

        var deep = FakeRepository.withUptime()
        deep.files["plugins/uptime/1/2/3/4/5/6/7/8/ok.txt"] = .init("x\n")
        #expect(verdict(deep).isInstallable, "eight folders deep is the limit")
        deep.files["plugins/uptime/1/2/3/4/5/6/7/8/9/no.txt"] = .init("x\n")
        #expect(verdict(deep).refusals.contains(.nestedTooDeep(path: "plugins/uptime/1/2/3/4/5/6/7/8/9/no.txt")))
    }

    @Test("rule 9: an LFS pointer shows only in its content")
    func ruleNine() {
        let pointer = Data("version https://git-lfs.github.com/spec/v1\noid sha256:abc\nsize 12\n".utf8)
        #expect(RepositoryRules.isLFSPointer(pointer))
        #expect(!RepositoryRules.isLFSPointer(Data("#!/bin/sh\nversion https://git-lfs.github.com/spec/v1\n".utf8)))
    }

    // MARK: - Rows

    func entry(_ repository: FakeRepository, _ id: String = "uptime") -> CatalogueEntry {
        CatalogueEntry(id: id, listing: repository.plugin(id), verdict: verdict(repository, id))
    }

    func record(_ repository: FakeRepository, version: String = "1.0.0") -> InstalledRecord {
        InstalledRecord(
            source: "official", repository: .official, ref: PluginRef(name: "main"),
            commit: repository.commit, tree: repository.treeID("plugins/uptime")!, version: version,
            installedAt: Date(timeIntervalSince1970: 1_790_000_000), pinned: false,
            verification: PluginVerification(status: .verified, by: "official", checkedAgainst: repository.commit,
                                             checkedAt: Date(timeIntervalSince1970: 1_790_000_000)),
            previous: nil)
    }

    @Test("a row's state is the one its button goes with")
    func rowStates() {
        let repository = FakeRepository.withUptime()
        let row = entry(repository)
        #expect(CatalogueRowState.of(row, record: nil, folderExists: false) == .notInstalled)
        #expect(CatalogueRowState.of(row, record: nil, folderExists: true) == .folderOfYourOwn)
        #expect(CatalogueRowState.of(row, record: record(repository), folderExists: true) == .installed(.current))
        #expect(CatalogueRowState.of(row, record: record(repository), folderExists: false) == .missing)

        var refused = FakeRepository.withUptime()
        refused.addPlugin("future", manifest: FakeRepository.manifest(id: "future", version: "2.0.0", api: 2))
        #expect(CatalogueRowState.of(entry(refused, "future"), record: nil, folderExists: false)
                == .cannotInstall(.apiNotSpoken(name: "future", version: "2.0.0", api: 2)))
    }

    @Test("what the head has for an installed plugin is a comparison of two trees and two versions")
    func updateOffers() {
        let installed = FakeRepository.withUptime(version: "1.2.0")
        let base = record(installed, version: "1.2.0")

        #expect(UpdateOffer.of(base, head: entry(installed)) == .current)
        #expect(UpdateOffer.of(base, head: entry(.withUptime(version: "1.3.0"))) == .newer(version: "1.3.0"))
        #expect(UpdateOffer.of(base, head: entry(.withUptime(version: "1.1.0"))) == .older(version: "1.1.0"))
        var same = FakeRepository.withUptime(version: "1.2.0")
        same.files["plugins/uptime/README.md"] = .init("# changed\n")
        #expect(UpdateOffer.of(base, head: entry(same)) == .changedStill(version: "1.2.0"))
        #expect(UpdateOffer.of(base, head: nil) == .goneFromRepository)

        var needsMore = FakeRepository()
        needsMore.addPlugin("uptime", manifest: FakeRepository.manifest(version: "1.3.0", minUDeck: "0.8.0"))
        #expect(UpdateOffer.of(base, head: entry(needsMore))
                == .cannotRun(version: "1.3.0", reason: .needsNewerUDeck(name: "uptime", version: "1.3.0",
                                                                       required: "0.8.0", running: "0.5.0")))
        var nextAPI = FakeRepository()
        nextAPI.addPlugin("uptime", manifest: FakeRepository.manifest(version: "2.0.0", api: 2))
        #expect(UpdateOffer.of(base, head: entry(nextAPI))
                == .cannotRun(version: "2.0.0", reason: .apiNotSpoken(name: "uptime", version: "2.0.0", api: 2)))

        #expect(UpdateOffer.newer(version: "1").isWaiting && UpdateOffer.changedStill(version: "1").isWaiting)
        #expect(!UpdateOffer.current.isWaiting && !UpdateOffer.older(version: "1").isWaiting)
    }

    /// The specification: *"A plugin marked modified is not updated over
    /// without a word."* The catalogue's row has the same button, and the
    /// same rule.
    @Test("Update and Switch to over a copy changed on disk name the version its changes are replaced with")
    func updatingOverChanges() {
        #expect(UpdateOffer.newer(version: "1.3.0").versionReplacingChanges(standing: .modifiedLocally) == "1.3.0")
        #expect(UpdateOffer.changedStill(version: "1.2.0").versionReplacingChanges(standing: .modifiedLocally) == "1.2.0")
        #expect(UpdateOffer.older(version: "1.1.0").versionReplacingChanges(standing: .modifiedLocally) == "1.1.0")
        #expect(UpdateOffer.newer(version: "1.3.0").versionReplacingChanges(standing: .verified) == nil,
                "nothing of the operator's to warn about")
        #expect(UpdateOffer.current.versionReplacingChanges(standing: .modifiedLocally) == nil, "nothing offered")
        #expect(UpdateOffer.goneFromRepository.versionReplacingChanges(standing: .modifiedLocally) == nil)
    }

    /// *"Off, uDeck makes no request about plugins at all"* — and **Reinstall**
    /// is a download, wherever its button is.
    @Test("Reinstall is offered only while the official catalogue is on")
    func reinstallFollowsTheSwitch() throws {
        #expect(PluginStanding.modifiedLocally.offersReinstall(readsCatalogue: true))
        #expect(PluginStanding.missing.offersReinstall(readsCatalogue: true))
        #expect(!PluginStanding.verified.offersReinstall(readsCatalogue: true))
        #expect(!PluginStanding.folderOfYourOwn.offersReinstall(readsCatalogue: true))
        #expect(!PluginStanding.modifiedLocally.offersReinstall(readsCatalogue: false))
        #expect(!PluginStanding.missing.offersReinstall(readsCatalogue: false))

        let repository = FakeRepository.withUptime()
        let id = PluginIdentifier(rawValue: "uptime")!
        let installed = InstalledPlugins(plugins: ["uptime": record(repository)])
        #expect(PluginPresence.of(id, plugins: [], installed: installed, readsCatalogue: true) == .missing(reinstallable: true))
        #expect(PluginPresence.of(id, plugins: [], installed: installed, readsCatalogue: false) == .missing(reinstallable: false))
        #expect(PluginPresence.of(id, plugins: [], installed: InstalledPlugins(), readsCatalogue: true)
                == .missing(reinstallable: false))

        // A folder under the id that will not run: its window offers the same.
        let temp = TemporaryDirectory()
        let broken = temp.writePlugin(folder: "uptime", manifest: "{ not json")
        let found = PluginDiscovery(searchPath: ["/bin"], udeck: udeck).load(broken)
        guard case .broken(_, let on) = PluginPresence.of(id, plugins: [found], installed: installed, readsCatalogue: true),
              case .broken(_, let off) = PluginPresence.of(id, plugins: [found], installed: installed, readsCatalogue: false)
        else {
            Issue.record("a folder that will not run is broken")
            return
        }
        #expect(on && !off)
    }

    @Test("the catalogue loads from the cache alone, sorted by name, translated where there is a translation")
    func loadsFromTheCache() throws {
        let temp = TemporaryDirectory()
        let store = CatalogueStore(paths: temp.paths)
        var repository = FakeRepository.withUptime()
        repository.addPlugin("alpha", manifest: FakeRepository.manifest(id: "alpha").replacingOccurrences(
            of: "\"name\": \"alpha\"", with: "\"name\": \"Zulu\""))
        repository.files["plugins/uptime/manifest.ru.json"] = .init(#"{ "name": "Аптайм" }"#)
        try store.save(repository.listing)
        for path in ["udeck-plugins.json", "plugins/uptime/manifest.json", "plugins/alpha/manifest.json",
                     "plugins/uptime/manifest.ru.json"] {
            try store.save(blob: repository.data(at: path)!)
        }
        try store.save(CatalogueState(head: repository.commit))

        let english = try #require(Catalogue.load(from: store, address: .official, udeck: udeck, language: "en"))
        #expect(english.entries.map(\.id) == ["uptime", "alpha"], "sorted by name: uptime before Zulu")
        let russian = try #require(Catalogue.load(from: store, address: .official, udeck: udeck, language: "ru"))
        #expect(russian.entry("uptime")?.name(in: "ru") == "Аптайм")

        try store.save(CatalogueState())
        #expect(Catalogue.load(from: store, address: .official, udeck: udeck, language: "en") == nil)
    }
}
