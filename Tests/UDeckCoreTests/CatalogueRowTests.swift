import Foundation
import Testing
@testable import UDeckCore
import UDeckPluginFormatFixtures

/// What a catalogue row says, and what the head has for an installed plugin.
/// Rules 1–9, which decide whether a row may offer Install at all, are tested
/// with the plugin format, in `UDeckPluginFormat`.
@Suite("Catalogue rows")
struct CatalogueRowTests {
    let udeck = SemanticVersion("0.5.0")

    func verdict(_ repository: FakeRepository, _ id: String = "uptime") -> RepositoryRules.Verdict {
        RepositoryRules.check(folder: id, listing: repository.plugin(id),
                              manifest: repository.data(at: "plugins/\(id)/manifest.json"), udeck: udeck)
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

    /// The panel's actor asks, as uDeck does, and the reading — every
    /// manifest read from disk, hashed again and parsed — happens on the
    /// cooperative pool: `CatalogueStore.blob` stops a debug build that
    /// reads one on the main thread.
    @MainActor
    @Test("asked from the main actor, the catalogue and a manifest are read and hashed away from the main thread")
    func readOffTheMainThread() async throws {
        let temp = TemporaryDirectory()
        let store = CatalogueStore(paths: temp.paths)
        let repository = FakeRepository.withUptime()
        try store.save(repository.listing)
        for path in ["udeck-plugins.json", "plugins/uptime/manifest.json"] { try store.save(blob: repository.data(at: path)!) }
        try store.save(CatalogueState(head: repository.commit))

        let catalogue = await Catalogue.read(from: store, address: .official, udeck: udeck, language: "en")
        #expect(catalogue?.entries.map(\.id) == ["uptime"])
        let manifest = await store.manifest(of: repository.plugin("uptime"))
        #expect(manifest == repository.data(at: "plugins/uptime/manifest.json"))
    }
}
