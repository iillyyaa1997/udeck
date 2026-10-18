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

// MARK: - Rows of two sources (stage 4, R1a)

/// One id, one copy, and now more than one catalogue: what a row says of a
/// copy from its own source, and of one from anywhere else — the official
/// catalogue's rows exactly as they were.
extension CatalogueRowTests {
    static let team = RepositoryAddress(provider: "gitlab", host: "gitlab.example", path: "tools/team-plugins")
    static let teamID = "gitlab.example-team-plugins-0a0b0c0d"
    static let other = RepositoryAddress(provider: "github", host: "github.com", path: "someone/other")
    static let otherID = "github.com-other-0e0f0a0b"

    /// A copy of `repository`'s uptime, recorded as `source`'s from `address` at `ref`.
    func record(_ repository: FakeRepository, source: String, address: RepositoryAddress, ref: PluginRef,
                version: String = "1.0.0") -> InstalledRecord {
        var record = record(repository, version: version)
        record.source = source
        record.repository = address
        record.ref = ref
        return record
    }

    enum Kind: Sendable { case official, officialPR, team, teamBranch, other, none }

    /// The row's source, the record's, the folder there, what the head has —
    /// and what the row comes to.
    static let rows: [(row: String, record: Kind, folder: Bool, head: String, wanted: String)] = [
        ("official", .official, true, "1.0.0", "installed current"),
        ("official", .official, true, "1.1.0", "installed newer 1.1.0"),
        ("official", .official, false, "1.0.0", "missing"),
        ("official", .officialPR, true, "1.0.0", "unverified 1.0.0"),
        ("official", .team, true, "1.1.0", "unverified 1.1.0"),
        ("official", .team, false, "1.0.0", "unverified 1.0.0, gone"),
        ("official", .none, false, "1.0.0", "not installed"),
        ("team", .team, true, "1.0.0", "installed current"),
        ("team", .team, true, "1.1.0", "installed newer 1.1.0"),
        ("team", .team, false, "1.1.0", "missing"),
        ("team", .official, true, "1.1.0", "from the verified 1.0.0 of github.com/iillyyaa1997/udeck-plugins, offering 1.1.0"),
        ("team", .official, false, "1.0.0", "from the verified 1.0.0, gone"),
        ("team", .officialPR, true, "1.0.0", "from pull request #3"),
        ("team", .other, true, "1.0.0", "from github.com/someone/other's default branch"),
        ("team", .teamBranch, true, "1.0.0", "from a branch, even of this source"),
        ("team", .none, false, "1.0.0", "not installed"),
        ("team", .none, true, "1.0.0", "a folder of your own"),
        ("other", .team, true, "1.0.0", "from the team source's default branch"),
    ]

    @Test("a row's state by its own source and the record's", arguments: 0..<rows.count)
    func rowsOfTwoSources(index: Int) {
        let (rowSource, kind, folder, headVersion, why) = Self.rows[index]
        let installed = FakeRepository.withUptime()
        let head = entry(.withUptime(version: headVersion))
        let source = ["official": InstalledPlugins.officialSource, "team": Self.teamID, "other": Self.otherID][rowSource]!
        let record: InstalledRecord? = switch kind {
        case .official: record(installed)
        case .officialPR: record(installed, source: "official", address: .official, ref: .pullRequest(3))
        case .team: record(installed, source: Self.teamID, address: Self.team, ref: .defaultBranch("main"))
        case .teamBranch: record(installed, source: Self.teamID, address: Self.team, ref: .branch("x"))
        case .other: record(installed, source: Self.otherID, address: Self.other, ref: .defaultBranch("main"))
        case .none: nil
        }
        let state = CatalogueRowState.of(head, record: record, folderExists: folder, source: source, official: .official)
        let commit = String(installed.commit.prefix(7))
        let wanted: CatalogueRowState = switch (rowSource, kind) {
        case (_, .none): folder ? .folderOfYourOwn : .notInstalled
        case ("official", .official), ("team", .team):
            folder ? .installed(headVersion == "1.0.0" ? .current : .newer(version: headVersion)) : .missing
        case ("official", _): .unverified(version: headVersion, refusal: nil, folderGone: !folder)
        case (_, .official):
            .fromElsewhere(.verified(version: "1.0.0", repository: "github.com/iillyyaa1997/udeck-plugins"),
                           version: headVersion, refusal: nil, folderGone: !folder)
        case (_, .officialPR): .fromElsewhere(.pullRequest(number: 3, commit: commit, version: "1.0.0"), version: headVersion,
                                              refusal: nil, folderGone: !folder)
        case (_, .teamBranch): .fromElsewhere(.branch(name: "x", commit: commit, version: "1.0.0", fork: "tools/team-plugins"),
                                              version: headVersion, refusal: nil, folderGone: !folder)
        case (_, .other): .fromElsewhere(.sourceDefault(version: "1.0.0", address: "github.com/someone/other"),
                                         version: headVersion, refusal: nil, folderGone: !folder)
        default: .fromElsewhere(.sourceDefault(version: "1.0.0", address: "gitlab.example/tools/team-plugins"),
                                version: headVersion, refusal: nil, folderGone: !folder)
        }
        #expect(state == wanted, "\(why)")
        if source == InstalledPlugins.officialSource {
            #expect(state == CatalogueRowState.of(head, record: record, folderExists: folder),
                    "the official catalogue's rows are what they were")
        }
    }

    /// A catalogue read from a source's own folder, `catalogue/<id>/`, is that
    /// source's: what its rows bring is recorded as that source's copy
    /// (`ShownPlace.origin(of:)`). Read as the official one's, it is the
    /// official source's, as it always was.
    @Test("a catalogue read for a source is that source's")
    func catalogueKnowsItsSource() async throws {
        let temp = TemporaryDirectory()
        let store = CatalogueStore(paths: temp.paths, source: Self.teamID)
        #expect(store.directory.lastPathComponent == Self.teamID)
        let repository = FakeRepository.withUptime()
        try store.save(repository.listing)
        for path in ["udeck-plugins.json", "plugins/uptime/manifest.json"] { try store.save(blob: repository.data(at: path)!) }
        try store.save(CatalogueState(head: repository.commit))
        let team = await Catalogue.read(from: store, address: Self.team, udeck: udeck, language: "en", source: Self.teamID)
        #expect(team?.source == Self.teamID && team?.address == Self.team && team?.entries.map(\.id) == ["uptime"])
        let official = await Catalogue.read(from: store, address: .official, udeck: udeck, language: "en")
        #expect(official?.source == InstalledPlugins.officialSource)
    }

    @Test("a row of another source that cannot be installed here says why, and offers nothing")
    func fromElsewhereCannotInstall() {
        var future = FakeRepository()
        future.addPlugin("uptime", manifest: FakeRepository.manifest(version: "2.0.0", api: 2))
        let state = CatalogueRowState.of(entry(future), record: record(.withUptime()), folderExists: true, source: Self.teamID)
        #expect(state == .fromElsewhere(.verified(version: "1.0.0", repository: "github.com/iillyyaa1997/udeck-plugins"),
                                        version: "2.0.0", refusal: .apiNotSpoken(name: "uptime", version: "2.0.0", api: 2)))
    }

    /// An update is offered from a copy's own source's head and from nowhere
    /// else: the official head offers a source's copy nothing, a source's head
    /// offers the official copy nothing.
    @Test("an update is offered only from the head of the copy's own source")
    func updatesPerSource() {
        let installed = FakeRepository.withUptime()
        let newer = entry(.withUptime(version: "1.1.0"))
        let official = record(installed)
        let team = record(installed, source: Self.teamID, address: Self.team, ref: .defaultBranch("main"))
        let branch = record(installed, source: Self.teamID, address: Self.team, ref: .branch("x"))
        #expect(UpdateOffer.offered(official, head: newer) == .newer(version: "1.1.0"))
        #expect(UpdateOffer.offered(official, head: newer, source: InstalledPlugins.officialSource) == .newer(version: "1.1.0"))
        #expect(UpdateOffer.offered(team, head: newer) == nil, "the official head offers a source's copy nothing")
        #expect(UpdateOffer.offered(team, head: newer, source: Self.teamID) == .newer(version: "1.1.0"))
        #expect(UpdateOffer.offered(official, head: newer, source: Self.teamID) == nil, "nor a source's head the official copy")
        #expect(UpdateOffer.offered(team, head: newer, source: Self.otherID) == nil)
        #expect(UpdateOffer.offered(branch, head: newer, source: Self.teamID) == nil, "a branch's copy is no copy of its head")
        #expect(UpdateOffer.offered(team, head: nil, source: Self.teamID) == .goneFromRepository)
    }

    /// In the official catalogue, a copy of a source of one's own is code
    /// nobody verified, and its line names the source it came from.
    @Test("the official row of a source's copy names the source; a branch's and a pull request's say their line")
    func officialRowNamesTheSource() {
        let state = CatalogueRowState.unverified(version: "1.0.0", refusal: nil, folderGone: true)
        #expect(state.unverifiedLine(ref: .defaultBranch("main"), id: "uptime", path: "~/.udeck/plugins",
                                     source: "gitlab.example/tools/team-plugins")
                == [.catalogueInstalledFromSource(address: "gitlab.example/tools/team-plugins"),
                    .catalogueMissing(id: "uptime", path: "~/.udeck/plugins")])
        #expect(state.unverifiedLine(ref: .pullRequest(3), id: "uptime", path: "~/.udeck/plugins", source: "x")?.first
                == .catalogueInstalledUnverified(ref: .pullRequest(3)), "a pull request's line is its own")
        #expect(state.unverifiedLine(ref: .defaultBranch("main"), id: "uptime", path: "p")?.first
                == .catalogueInstalledUnverified(ref: .defaultBranch("main")), "no source given: as it was")
        #expect(CatalogueRowState.fromElsewhere(.other(commit: "a", version: "1"), version: "1", refusal: nil)
            .unverifiedLine(ref: .defaultBranch(nil), id: "uptime", path: "p") == nil)
        let english = Strings(.english), russian = Strings(.russian)
        #expect(english(.catalogueInstalledFromSource(address: "gitlab.example/tools/x"))
                == "Installed here from gitlab.example/tools/x: unverified")
        #expect(russian(.catalogueInstalledFromSource(address: "gitlab.example/tools/x"))
                == "Здесь установлен из gitlab.example/tools/x: не проверен")
        let verified = CopyName.verified(version: "1.0.0", repository: "github.com/o/r")
        #expect(english(.catalogueInstalledFromElsewhere(verified)) == "Installed here: the verified 1.0.0 from github.com/o/r")
        #expect(russian(.catalogueInstalledFromElsewhere(verified)) == "Здесь установлена проверенная версия 1.0.0 из github.com/o/r")
        #expect(english(.catalogueInstallFromHere) == "Install from here…" && russian(.catalogueInstallFromHere) == "Установить отсюда…")
    }
}
