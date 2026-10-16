import Foundation
import Testing
@testable import UDeckCore
import UDeckPluginFormatFixtures

/// **Install from a link…** and **Unverified** said everywhere (stage 3,
/// R3). UDeckKit has no tests, so every decision its views show is held
/// here: what a row listed from a link installs, and from where; the warning
/// before a copy from one line of history takes the place of a copy from
/// another, naming both; the catalogue row of an id installed from a pull
/// request, and its **Switch to verified**; where the copy came from as the
/// row, the card's header and its question say it; and why a link names
/// nothing to install.
@Suite("Install from a link, Unverified said everywhere")
struct InstallFromLinkTests {
    let udeck = TemporaryDirectory()
    var paths: UDeckPaths { udeck.paths }

    func live(_ id: String) -> URL { paths.plugins.appendingPathComponent(id, isDirectory: true) }

    static let headCommit = String(repeating: "1", count: 40)
    static let pullCommit = "a1b2c3d4e5f60718293a4b5c6d7e8f9012345678"
    static let laterCommit = "b2c3d4e5f60718293a4b5c6d7e8f901234567890"

    /// The official catalogue's head: `uptime` 1.0.0.
    static var head: FakeRepository {
        var repository = FakeRepository.withUptime()
        repository.commit = headCommit
        return repository
    }

    /// Pull request #3's head: `uptime` 1.0.1 asking for what 1.0.0 asks,
    /// and `asks-nothing`, new, asking for nothing — the lab's pr3.
    static var pullRequestHead: FakeRepository {
        var repository = head
        repository.addPlugin("uptime", version: "1.0.1")
        repository.addPlugin("asks-nothing", manifest: FakeRepository.manifest(id: "asks-nothing", permissions: "{}"))
        repository.commit = pullCommit
        return repository
    }

    static let official = PluginOrigin(repository: .official, ref: .defaultBranch("main"))
    static let pullRequest = PluginOrigin(repository: .official, ref: .pullRequest(3))
    static let branch = PluginOrigin(repository: .official, ref: .branch("fix/uptime"))
    static let repository = RepositoryAddress.official.description

    /// An installer that fetches each file from the repository whose commit it is asked at.
    func installer(_ repositories: [FakeRepository], trash: TestTrash) -> PluginInstaller {
        let byCommit = Dictionary(uniqueKeysWithValues: repositories.map { ($0.commit, $0.files.mapValues(\.data)) })
        return PluginInstaller(
            paths: paths, discovery: PluginDiscovery(searchPath: ["/bin", "/usr/bin"], udeck: SemanticVersion("0.7.0")),
            trash: trash,
            fetch: { path, commit in
                guard let data = byCommit[commit]?[path] else { throw ProviderError.notFound }
                return data
            },
            now: { Date(timeIntervalSince1970: 1_790_000_000) }
        )
    }

    static func entry(_ repository: FakeRepository, _ id: String) -> CatalogueEntry {
        CatalogueEntry(id: id, listing: repository.plugin(id),
                       verdict: RepositoryRules.check(folder: id, listing: repository.plugin(id),
                                                      manifest: repository.data(at: "plugins/\(id)/manifest.json"),
                                                      udeck: SemanticVersion("0.7.0")))
    }

    static func catalogue(_ repository: FakeRepository) -> Catalogue {
        Catalogue(address: .official, commit: repository.commit, branch: "main",
                  passport: RepositoryPassport(name: "uDeck plugins"),
                  entries: repository.listing.plugins.keys.sorted().map { entry(repository, $0) })
    }

    /// What `RefResolver` comes to for a link to `repository`'s head, from
    /// `origin`: the plugins there that differ from the catalogue's head.
    static func resolution(_ repository: FakeRepository, origin: PluginOrigin = pullRequest) -> RefResolver.Resolution {
        let ids = RefResolver.differing(repository.listing, from: head.listing, only: nil)
        return RefResolver.Resolution(origin: origin, commit: repository.commit, listing: repository.listing,
                                      entries: ids.map { entry(repository, $0) }, pullRequest: nil)
    }

    /// What a step says, done through the installer, as `DeckModel.run` does it.
    func perform(_ step: ShownPlace.Step, _ id: String, with installer: PluginInstaller) async throws -> InstalledRecord {
        let request: InstallRequest
        switch step {
        case .install(let operation, let commit, let folder, let version, let origin):
            request = InstallRequest(operation: operation, id: PluginIdentifier(rawValue: id)!, sourceRepository: .official,
                                     repository: origin.repository, ref: origin.ref, commit: commit, folder: folder,
                                     version: version, headCommit: Self.headCommit)
        case .atCommit(let operation, let commit, let version, let origin):
            let source = commit == Self.headCommit ? Self.head : Self.pullRequestHead
            request = InstallRequest(operation: operation, id: PluginIdentifier(rawValue: id)!, sourceRepository: .official,
                                     repository: origin.repository, ref: origin.ref, commit: commit,
                                     folder: source.plugin(id), version: version, headCommit: Self.headCommit)
        default:
            Issue.record("the step does no work: \(step)")
            throw CancellationError()
        }
        return try installer.commit(try await installer.stage(request))
    }

    func everythingAt(_ folder: URL) -> [String: Data] {
        var found: [String: Data] = [:]
        let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            found[url.path.replacingOccurrences(of: folder.path, with: "")] = try? Data(contentsOf: url)
        }
        return found
    }

    // MARK: - Install, from a link

    @Test("Install on a row listed from a link: the pull request's copy at the commit read, recorded as pr #3, unverified, by nobody")
    func installsThePullRequestsCopy() async throws {
        let resolution = Self.resolution(Self.pullRequestHead)
        #expect(resolution.entries.map(\.id) == ["asks-nothing", "uptime"], "the premise: what differs from the head")
        let none = InstalledPlugins()
        let step = ShownPlace.installFromLink("asks-nothing", resolution: resolution, in: paths, installed: none, shown: nil)
        #expect(step == .install(.install, commit: Self.pullCommit, folder: Self.pullRequestHead.plugin("asks-nothing"),
                                 version: "1.0.0", from: Self.pullRequest), "onto nothing, at once, from the pull request")
        #expect(ShownPlace.installFromLink("cpu", resolution: resolution, in: paths, installed: none, shown: nil) == .nothing,
                "an id the link did not list installs nothing")

        let installer = installer([Self.head, Self.pullRequestHead], trash: TestTrash(in: udeck.url))
        let record = try await perform(step, "asks-nothing", with: installer)
        #expect(record.ref == PluginRef(kind: "pr", name: "3") && record.repository == .official && record.source == "official")
        #expect(record.commit == Self.pullCommit && record.tree == Self.pullRequestHead.plugin("asks-nothing").tree)
        #expect(record.verification.status == .unverified && record.verification.by == nil)
        #expect(record.previous == nil && !record.pinned)
        #expect(PluginStanding.of(record: record, folderExists: true, treeOnDisk: record.tree) == .unverified)
        #expect(ConsentBasis.of(record, linked: false, recordsReadable: true) == .tree)
        #expect(record.fromPhrase == .pluginFromPullRequest(number: 3, commit: "a1b2c3d"))
        #expect(record.refPage == URL(string: "https://github.com/iillyyaa1997/udeck-plugins/pull/3"))
    }

    @Test("Over the verified copy: the warning names both sources and the ref, and nothing changes until it is confirmed")
    func overTheVerifiedCopy() async throws {
        let installer = installer([Self.head, Self.pullRequestHead], trash: TestTrash(in: udeck.url))
        let verified = try await perform(
            ShownPlace.install("uptime", catalogue: Self.catalogue(Self.head), in: paths, installed: InstalledPlugins(),
                               shown: nil), "uptime", with: installer)
        #expect(verified.verification.status == .verified, "the premise: the verified 1.0.0 is installed")
        let records = try installer.loadRecords()
        let before = everythingAt(live("uptime"))
        let resolution = Self.resolution(Self.pullRequestHead)

        let switching = ShownPlace.Switch(from: .verified(version: "1.0.0", repository: Self.repository),
                                          to: .pullRequest(number: 3, commit: "a1b2c3d", version: "1.0.1"))
        let warning = ShownPlace.Place(fate: .deleted, arriving: "1.0.1", copy: Self.pullCommit, switching: switching)
        #expect(ShownPlace.installFromLink("uptime", resolution: resolution, in: paths, installed: records, shown: nil)
                == .ask(warning), "uDeck's own copy, verified, is replaced only after the warning that names both")
        let after = try installer.loadRecords()
        #expect(everythingAt(live("uptime")) == before && after == records, "nothing changed")

        let english = Strings(.english)(PlaceWarning.of(warning, button: .replaceCopy, id: "uptime", path: "~/.udeck/plugins",
                                                        link: nil))
        #expect(english == "uptime is the verified 1.0.0 from github.com/iillyyaa1997/udeck-plugins; installing 1.0.1 from "
                + "pull request #3 at a1b2c3d replaces it. Its windows and settings stay. Nobody verified the code that "
                + "comes: it asks before it runs, unless you allowed exactly that code before.",
                "code nobody verified is held to its tree: the decision there was does not let it run, and the warning does not say it would")
        let russian = Strings(.russian)(PlaceWarning.of(warning, button: .replaceCopy, id: "uptime", path: "~/.udeck/plugins",
                                                        link: nil))
        #expect(russian.contains("проверенная версия 1.0.0 из github.com/iillyyaa1997/udeck-plugins")
                && russian.contains("версия 1.0.1 из запроса на слияние #3, коммит a1b2c3d") && !russian.contains("Корзин"))
        #expect(russian.hasSuffix("Окна плагина и его настройки останутся. Код, который встанет, никто не проверял: плагин "
                                  + "спросит разрешения перед запуском, если только вы уже не разрешали именно этот код.")
                && !russian.contains("решение о разрешениях останутся"))

        let confirmed = ShownPlace.installFromLink("uptime", resolution: resolution, in: paths, installed: records,
                                                   shown: warning)
        #expect(confirmed == .install(.update, commit: Self.pullCommit, folder: Self.pullRequestHead.plugin("uptime"),
                                      version: "1.0.1", from: Self.pullRequest))
        let record = try await perform(confirmed, "uptime", with: installer)
        #expect(record.ref == .pullRequest(3) && record.verification.status == .unverified)
        #expect(record.previous == PreviousCopy(ref: verified.ref, commit: Self.headCommit, tree: verified.tree,
                                                version: "1.0.0", repository: .official),
                "the verified copy is what Back to puts back")
    }

    @Test("A warning about one switch does not hold for another: the copy there changed while it was up")
    func aSwitchIsHeldToBothCopies() {
        let shown = ShownPlace.Place(fate: .deleted, arriving: "1.0.1", copy: Self.pullCommit,
                                     switching: .init(from: .verified(version: "1.0.0", repository: Self.repository),
                                                      to: .pullRequest(number: 3, commit: "a1b2c3d", version: "1.0.1")))
        var now = shown
        now.switching?.from = .verified(version: "1.1.0", repository: Self.repository)
        #expect(ShownPlace.press(.install, shown: shown, now: now) == .ask(now), "the verified copy was updated meanwhile")
        now = shown
        now.switching?.to = .pullRequest(number: 3, commit: "b2c3d4e", version: "1.0.1")
        #expect(ShownPlace.press(.install, shown: shown, now: now) == .ask(now))
        now = shown
        now.switching?.to = .branch(name: "caf\u{E9}", commit: "a1b2c3d", version: "1.0.1")
        var other = shown
        other.switching?.to = .branch(name: "cafe\u{301}", commit: "a1b2c3d", version: "1.0.1")
        #expect(!ShownPlace.holds(now, now: other), "two spellings of a branch are two branches")
        now = shown
        now.switching = nil
        #expect(!ShownPlace.holds(shown, now: now))
        #expect(ShownPlace.press(.install, shown: nil, now: shown) == .ask(shown), "a switch is always warned of first")
        #expect(ShownPlace.press(.replaceCopy, shown: nil, now: shown) == .ask(shown))
        #expect(ShownPlace.press(.install, shown: shown, now: shown) == .goAhead)
    }

    @Test("Install from a link over a folder of the operator's own or a link: their own warnings, no switch")
    func overTheOperatorsWork() throws {
        let resolution = Self.resolution(Self.pullRequestHead)
        udeck.writePlugin(folder: "uptime", manifest: FakeRepository.manifest())
        let own = ShownPlace.Place(fate: .toTrash, arriving: "1.0.1", copy: Self.pullCommit)
        #expect(ShownPlace.installFromLink("uptime", resolution: resolution, in: paths, installed: InstalledPlugins(),
                                           shown: nil) == .ask(own))
        #expect(ShownPlace.installFromLink("uptime", resolution: resolution, in: paths, installed: InstalledPlugins(),
                                           shown: own)
                == .install(.replace, commit: Self.pullCommit, folder: Self.pullRequestHead.plugin("uptime"),
                            version: "1.0.1", from: Self.pullRequest))
        try FileManager.default.removeItem(at: live("uptime"))
        try FileManager.default.createSymbolicLink(atPath: live("uptime").path, withDestinationPath: "../gone")
        guard case .ask(let link) = ShownPlace.installFromLink("uptime", resolution: resolution, in: paths,
                                                              installed: InstalledPlugins(), shown: nil) else {
            Issue.record("a link is warned of"); return
        }
        #expect(link.link == "../gone" && link.switching == nil)
    }

    // MARK: - Switch to verified, and the lines of history

    @Test("Switch to verified: the catalogue row's state for a pull request's copy, and its press names both before it puts the verified copy back")
    func switchToVerified() async throws {
        let installer = installer([Self.head, Self.pullRequestHead], trash: TestTrash(in: udeck.url))
        let resolution = Self.resolution(Self.pullRequestHead)
        let pulled = try await perform(ShownPlace.installFromLink("uptime", resolution: resolution, in: paths,
                                                                  installed: InstalledPlugins(), shown: nil),
                                       "uptime", with: installer)
        let records = try installer.loadRecords()
        let catalogue = Self.catalogue(Self.head)
        let entry = try #require(catalogue.entry("uptime"))
        #expect(CatalogueRowState.of(entry, record: pulled, folderExists: true) == .unverified(version: "1.0.0", refusal: nil))
        #expect(UpdateOffer.offered(pulled, head: entry) == nil,
                "a pull request's copy is not an older version of the catalogue's: nothing waits, nothing updates by itself")

        let switching = ShownPlace.Switch(from: .pullRequest(number: 3, commit: "a1b2c3d", version: "1.0.1"),
                                          to: .verified(version: "1.0.0", repository: Self.repository))
        let warning = ShownPlace.Place(fate: .deleted, arriving: "1.0.0", copy: entry.listing.tree, switching: switching)
        #expect(ShownPlace.update("uptime", catalogue: catalogue, in: paths, installed: records, shown: nil) == .ask(warning))
        #expect(Strings(.english)(PlaceWarning.of(warning, button: .replaceCopy, id: "uptime", path: "~", link: nil))
                == "uptime is 1.0.1 from pull request #3 at a1b2c3d; installing the verified 1.0.0 from "
                + "github.com/iillyyaa1997/udeck-plugins replaces it. Its windows, settings and your permission decision stay.")
        let step = ShownPlace.update("uptime", catalogue: catalogue, in: paths, installed: records, shown: warning)
        #expect(step == .install(.update, commit: Self.headCommit, folder: entry.listing, version: "1.0.0", from: Self.official))
        let verified = try await perform(step, "uptime", with: installer)
        #expect(verified.ref.isDefault && verified.verification.status == .verified && verified.verification.by == "official")
        #expect(verified.previous?.ref == .pullRequest(3) && verified.previous?.commit == Self.pullCommit)
        #expect(CatalogueRowState.of(entry, record: verified, folderExists: true) == .installed(.current))
        #expect(UpdateOffer.offered(verified, head: entry) == .current)

        // Back to the pull request's copy: from where it came, and named so.
        let back = try installer.loadRecords()
        guard case .ask(let backWarning) = ShownPlace.backToPrevious("uptime", source: .official, in: paths, installed: back,
                                                                     shown: nil) else {
            Issue.record("Back to across two lines of history warns first"); return
        }
        #expect(backWarning.switching == .init(from: .verified(version: "1.0.0", repository: Self.repository),
                                               to: .pullRequest(number: 3, commit: "a1b2c3d", version: "1.0.1")))
    }

    /// R4+R6's review, low #8: before **Back to** or **Reinstall** of a pull
    /// request's copy whose folder is what the default branch's head has, the
    /// warning said *Nobody verified the code that comes* while the installer
    /// records that copy **Verified** (`Adoption`). The warning names the copy
    /// as it is recorded: the verified one.
    @Test("Back to and Reinstall of a pull request's copy the head has: named as the verified copy the installer records it as")
    func putBackAsWhatWasMerged() async throws {
        let installer = installer([Self.head, Self.pullRequestHead], trash: TestTrash(in: udeck.url))
        let pullTree = Self.pullRequestHead.plugin("uptime").tree
        _ = try await perform(ShownPlace.installFromLink("uptime", resolution: Self.resolution(Self.pullRequestHead), in: paths,
                                                         installed: InstalledPlugins(), shown: nil), "uptime", with: installer)
        let catalogue = Self.catalogue(Self.head)
        guard case .ask(let toVerified) = ShownPlace.update("uptime", catalogue: catalogue, in: paths,
                                                           installed: try installer.loadRecords(), shown: nil) else {
            Issue.record("the switch to verified warns first"); return
        }
        _ = try await perform(ShownPlace.update("uptime", catalogue: catalogue, in: paths, installed: try installer.loadRecords(),
                                                shown: toVerified), "uptime", with: installer)
        let back = try installer.loadRecords()
        // Not merged: the pull request's copy, named as code nobody verified.
        guard case .ask(let notMerged) = ShownPlace.backToPrevious("uptime", source: .official, in: paths, installed: back,
                                                                   shown: nil, head: Adoption.DefaultBranch(catalogue)) else {
            Issue.record("Back to across two lines of history warns first"); return
        }
        #expect(notMerged.switching?.to == .pullRequest(number: 3, commit: "a1b2c3d", version: "1.0.1"))
        // Merged as exactly that copy: the head has its tree, and it comes back as the verified copy it is recorded as —
        // the verified copy for the verified copy, the same line: nothing to warn of.
        let merged = Adoption.DefaultBranch(repository: .official, name: "main", head: Self.laterCommit, trees: ["uptime": pullTree])
        let step = ShownPlace.backToPrevious("uptime", source: .official, in: paths, installed: back, shown: nil, head: merged)
        #expect(step == .atCommit(.earlier, commit: Self.pullCommit, version: "1.0.1", from: Self.pullRequest),
                "no warning, and the files from where they came")
        let request = InstallRequest(operation: .earlier, id: PluginIdentifier(rawValue: "uptime")!, sourceRepository: .official,
                                     repository: .official, ref: .pullRequest(3), commit: Self.pullCommit,
                                     folder: Self.pullRequestHead.plugin("uptime"), version: "1.0.1", headCommit: Self.laterCommit,
                                     headTree: pullTree, defaultBranch: "main")
        let record = try installer.commit(try await installer.stage(request))
        #expect(record.isOfficialDefault && record.verification.status == .verified && record.commit == Self.laterCommit,
                "what the warning did not warn of is what the installer did: the verified copy")

        // Reinstall of a pull request's copy changed on disk, its tree the head's: the Trash, and the verified copy named.
        // The folder is the pull request's copy, as Back to left it; its record, the pull request's.
        var changed = try installer.loadRecords()
        changed.plugins["uptime"]?.ref = .pullRequest(3)
        changed.plugins["uptime"]?.commit = Self.pullCommit
        #expect(changed.plugins["uptime"]?.tree == pullTree)
        try Data("echo changed\n".utf8).write(to: live("uptime").appendingPathComponent("uptime.sh"))
        guard case .ask(let reinstall) = ShownPlace.reinstall("uptime", in: paths, installed: changed, shown: nil, head: merged),
              case .ask(let plain) = ShownPlace.reinstall("uptime", in: paths, installed: changed, shown: nil,
                                                          head: Adoption.DefaultBranch(catalogue)) else {
            Issue.record("Reinstall over the operator's changes warns first"); return
        }
        #expect(reinstall.fate == .toTrash && reinstall.switching == .init(
            from: .pullRequest(number: 3, commit: "a1b2c3d", version: "1.0.1"),
            to: .verified(version: "1.0.1", repository: Self.repository)))
        let said = Strings(.english)(PlaceWarning.of(reinstall, button: .replaceCopy, id: "uptime", path: "~", link: nil))
        #expect(said.contains("the verified 1.0.1 from github.com/iillyyaa1997/udeck-plugins") && !said.contains("Nobody verified"),
                "\(said)")
        #expect(plain.fate == .toTrash && plain.switching == nil, "not merged: the same copy put back, as before")
        #expect(!ShownPlace.holds(plain, now: reinstall), "a warning of one is not a warning of the other")
    }

    @Test("The same line of history is no switch: Reinstall, the pull request again at a later head; an earlier version of a pull request's copy is one")
    func theSameLine() async throws {
        let installer = installer([Self.head, Self.pullRequestHead], trash: TestTrash(in: udeck.url))
        _ = try await perform(ShownPlace.installFromLink("uptime", resolution: Self.resolution(Self.pullRequestHead), in: paths,
                                                         installed: InstalledPlugins(), shown: nil), "uptime", with: installer)
        let records = try installer.loadRecords()
        #expect(ShownPlace.reinstall("uptime", in: paths, installed: records, shown: nil)
                == .atCommit(.reinstall, commit: Self.pullCommit, version: "1.0.1", from: Self.pullRequest),
                "Reinstall puts the pull request's copy back without a word: it is the same copy")
        var later = Self.pullRequestHead
        later.files["plugins/uptime/README.md"] = .init("# uptime, pushed again\n")
        later.commit = Self.laterCommit
        #expect(ShownPlace.installFromLink("uptime", resolution: Self.resolution(later), in: paths, installed: records, shown: nil)
                == .install(.update, commit: Self.laterCommit, folder: later.plugin("uptime"), version: "1.0.1",
                            from: Self.pullRequest), "the same pull request at a later head is no switch")
        let line = PluginHistory.Line(version: "1.0.0", commit: Self.headCommit, date: nil, manifest: nil)
        guard case .ask(let earlier) = ShownPlace.earlier("uptime", line: line, source: .official, branch: "main", in: paths,
                                                          installed: records, shown: nil) else {
            Issue.record("an earlier version over a pull request's copy warns first"); return
        }
        #expect(earlier.switching == .init(from: .pullRequest(number: 3, commit: "a1b2c3d", version: "1.0.1"),
                                           to: .verified(version: "1.0.0", repository: Self.repository)))
        // The pull request's copy changed on disk: the switch, and the Trash, together.
        try Data("TOKEN=mine\n".utf8).write(to: live("uptime").appendingPathComponent(".env"))
        guard case .ask(let both) = ShownPlace.update("uptime", catalogue: Self.catalogue(Self.head), in: paths,
                                                      installed: records, shown: nil) else {
            Issue.record("warned"); return
        }
        #expect(both.fate == .toTrash && both.switching != nil)
        let said = Strings(.english)(PlaceWarning.of(both, button: .replaceCopy, id: "uptime", path: "~", link: nil))
        #expect(said.contains("Your changes to uptime will be moved to the Trash") && said.contains("pull request #3 at a1b2c3d")
                && said.contains("the verified 1.0.0") && said.hasSuffix("Its windows, settings and your permission decision stay."))
        #expect(Strings(.russian)(PlaceWarning.of(both, button: .replaceCopy, id: "uptime", path: "~", link: nil))
            .contains("Корзин"))
    }

    @Test("A record whose folder has gone: no copy there, no switch — the link's copy goes in as an update")
    func missingFolder() async throws {
        let installer = installer([Self.head, Self.pullRequestHead], trash: TestTrash(in: udeck.url))
        _ = try await perform(ShownPlace.install("uptime", catalogue: Self.catalogue(Self.head), in: paths,
                                                 installed: InstalledPlugins(), shown: nil), "uptime", with: installer)
        try FileManager.default.removeItem(at: live("uptime"))
        let records = try installer.loadRecords()
        #expect(ShownPlace.installFromLink("uptime", resolution: Self.resolution(Self.pullRequestHead), in: paths,
                                           installed: records, shown: nil)
                == .install(.update, commit: Self.pullCommit, folder: Self.pullRequestHead.plugin("uptime"), version: "1.0.1",
                            from: Self.pullRequest))
    }

    @Test("A pull request's copy whose folder has gone: its catalogue row says unverified and gone, and Switch to verified puts the verified copy where nothing is")
    func unverifiedFolderGone() async throws {
        let installer = installer([Self.head, Self.pullRequestHead], trash: TestTrash(in: udeck.url))
        _ = try await perform(ShownPlace.installFromLink("uptime", resolution: Self.resolution(Self.pullRequestHead), in: paths,
                                                         installed: InstalledPlugins(), shown: nil), "uptime", with: installer)
        try FileManager.default.removeItem(at: live("uptime"))
        let records = try installer.loadRecords()
        let catalogue = Self.catalogue(Self.head)
        let entry = try #require(catalogue.entry("uptime"))
        let state = CatalogueRowState.of(entry, record: records.plugins["uptime"], folderExists: false)
        #expect(state == .unverified(version: "1.0.0", refusal: nil, folderGone: true))
        let line = try #require(state.unverifiedLine(ref: .pullRequest(3), id: "uptime", path: "~/.udeck/plugins"))
        #expect(line.map { Strings(.english)($0) }.joined(separator: " — ")
                == "Installed here from pull request #3: unverified — uptime is not in ~/.udeck/plugins")
        #expect(line.map { Strings(.russian)($0) }.joined(separator: " — ")
                == "Здесь установлен из запроса на слияние #3: не проверен — uptime нет в ~/.udeck/plugins")
        let step = ShownPlace.update("uptime", catalogue: catalogue, in: paths, installed: records, shown: nil)
        #expect(step == .install(.update, commit: Self.headCommit, folder: entry.listing, version: "1.0.0", from: Self.official),
                "nothing there to replace, so nothing to warn of: the verified copy goes in")
        let verified = try await perform(step, "uptime", with: installer)
        #expect(verified.ref.isDefault && verified.verification.status == .verified)
        #expect(verified.previous?.ref == .pullRequest(3) && verified.previous?.commit == Self.pullCommit,
                "the pull request's copy is what Back to puts back")
        #expect(CatalogueRowState.of(entry, record: verified, folderExists: true) == .installed(.current))
    }

    @Test("what an unverified catalogue row says, in order; nothing for any other state")
    func unverifiedLines() {
        let refusal = RepositoryRefusal.apiNotSpoken(name: "uptime", version: "2.0.0", api: 2)
        #expect(CatalogueRowState.unverified(version: "2.0.0", refusal: refusal).unverifiedLine(ref: .branch("x"), id: "uptime", path: "~")
                == [.catalogueInstalledUnverified(ref: .branch("x")), .catalogueRefusal(refusal)])
        #expect(CatalogueRowState.unverified(version: "2.0.0", refusal: refusal, folderGone: true)
                    .unverifiedLine(ref: .branch("x"), id: "uptime", path: "~")
                == [.catalogueInstalledUnverified(ref: .branch("x")), .catalogueMissing(id: "uptime", path: "~"),
                    .catalogueRefusal(refusal)])
        for other: CatalogueRowState in [.missing, .notInstalled, .folderOfYourOwn, .installed(.current)] {
            #expect(other.unverifiedLine(ref: .branch("x"), id: "uptime", path: "~") == nil)
        }
    }

    @Test("which origins follow the same line of history", arguments: [
        (official, PluginOrigin(repository: RepositoryAddress(path: "renamed/udeck-plugins"), ref: .defaultBranch("main")), true),
        (official, PluginOrigin(repository: .official, ref: .defaultBranch(nil)), true),
        (pullRequest, pullRequest, true),
        (pullRequest, PluginOrigin(repository: .official, ref: .pullRequest(4)), false),
        (pullRequest, official, false),
        (official, branch, false),
        (branch, branch, true),
        (branch, PluginOrigin(repository: .official, ref: .branch("fix/Uptime")), false),
        (PluginOrigin(repository: .official, ref: .branch("caf\u{E9}")), PluginOrigin(repository: .official, ref: .branch("cafe\u{301}")), false),
        (branch, PluginOrigin(repository: RepositoryAddress(path: "someone/udeck-plugins"), ref: .branch("fix/uptime")), false),
        (PluginOrigin(repository: .official, ref: .branch("3")), pullRequest, false),
    ])
    func sameLine(one: PluginOrigin, other: PluginOrigin, same: Bool) {
        #expect(one.followsTheSameLine(as: other) == same)
        #expect(other.followsTheSameLine(as: one) == same)
    }

    @Test("a copy as a warning names it", arguments: [
        (official, "1.0.0", CopyName.verified(version: "1.0.0", repository: "github.com/iillyyaa1997/udeck-plugins")),
        (pullRequest, "1.0.1", CopyName.pullRequest(number: 3, commit: "a1b2c3d", version: "1.0.1")),
        (branch, "1.0.1", CopyName.branch(name: "fix/uptime", commit: "a1b2c3d", version: "1.0.1")),
        (PluginOrigin(repository: .official, ref: PluginRef(kind: "commit", name: pullCommit)), "1.0.1",
         CopyName.other(commit: "a1b2c3d", version: "1.0.1")),
        (PluginOrigin(repository: .official, ref: PluginRef(kind: "pr", name: "x")), "1.0.1",
         CopyName.other(commit: "a1b2c3d", version: "1.0.1")),
    ])
    func copyNames(origin: PluginOrigin, version: String, name: CopyName) {
        #expect(CopyName.of(origin, commit: Self.pullCommit, version: version) == name)
    }

    // MARK: - Rows

    func record(_ ref: PluginRef, tree: String = Self.head.plugin("uptime").tree) -> InstalledRecord {
        InstalledRecord(source: "official", repository: .official, ref: ref, commit: Self.pullCommit, tree: tree,
                        version: "1.0.1", installedAt: Date(timeIntervalSince1970: 1_790_000_000), pinned: false,
                        verification: PluginVerification(status: .unverified, by: nil, checkedAgainst: nil,
                                                         checkedAt: Date(timeIntervalSince1970: 1_790_000_000)),
                        previous: nil)
    }

    @Test("a catalogue row of an id installed from a branch or a pull request: Switch to verified, or why it cannot")
    func catalogueRows() {
        let head = Self.entry(Self.head, "uptime")
        #expect(CatalogueRowState.of(head, record: record(.pullRequest(3)), folderExists: true)
                == .unverified(version: "1.0.0", refusal: nil))
        #expect(CatalogueRowState.of(head, record: record(.branch("fix/uptime")), folderExists: true)
                == .unverified(version: "1.0.0", refusal: nil))
        #expect(CatalogueRowState.of(head, record: record(PluginRef(kind: "commit", name: "x")), folderExists: true)
                == .unverified(version: "1.0.0", refusal: nil), "a kind this uDeck does not know is unverified too")
        #expect(CatalogueRowState.of(head, record: record(.pullRequest(3)), folderExists: false)
                == .unverified(version: "1.0.0", refusal: nil, folderGone: true),
                "its folder gone, still unverified: the row offers the verified copy, never Reinstall of the pull request's under its Verified")
        #expect(CatalogueRowState.of(head, record: record(.branch("fix/uptime")), folderExists: false)
                == .unverified(version: "1.0.0", refusal: nil, folderGone: true))
        #expect(CatalogueRowState.of(head, record: record(PluginRef(name: "main")), folderExists: false) == .missing,
                "the default branch's copy gone: Reinstall, as before")
        #expect(CatalogueRowState.of(head, record: record(PluginRef(name: "main")), folderExists: true) == .installed(.current),
                "the default branch's copy is an ordinary installed row")

        var future = Self.head
        future.addPlugin("uptime", manifest: FakeRepository.manifest(version: "2.0.0", api: 2))
        #expect(CatalogueRowState.of(Self.entry(future, "uptime"), record: record(.pullRequest(3)), folderExists: true)
                == .unverified(version: "2.0.0", refusal: .apiNotSpoken(name: "uptime", version: "2.0.0", api: 2)),
                "the verified copy cannot run here: said, and nothing offered")
        var broken = Self.head
        broken.files["plugins/uptime/manifest.json"] = nil
        let none = CatalogueEntry(id: "uptime", listing: broken.plugin("uptime"),
                                  verdict: RepositoryRules.check(folder: "uptime", listing: broken.plugin("uptime"),
                                                                 manifest: nil, udeck: SemanticVersion("0.7.0")))
        guard case .unverified("?", let refusal?, false) = CatalogueRowState.of(none, record: record(.pullRequest(3)), folderExists: true)
        else { Issue.record("a row with no manifest offers no switch"); return }
        #expect(refusal == none.verdict.refusals.first ?? .noManifest(path: "plugins/uptime/manifest.json"))
        // Only the default branch's copies are offered updates against the head.
        let verified = InstalledRecord(source: "official", repository: .official, ref: PluginRef(name: "main"),
                                       commit: Self.headCommit, tree: "0", version: "0.9.0",
                                       installedAt: Date(timeIntervalSince1970: 1_790_000_000), pinned: false,
                                       verification: PluginVerification(status: .verified, by: "official", checkedAgainst: nil,
                                                                        checkedAt: Date(timeIntervalSince1970: 1_790_000_000)),
                                       previous: nil)
        #expect(UpdateOffer.offered(verified, head: head) == .newer(version: "1.0.0"))
        #expect(UpdateOffer.offered(record(.branch("fix/uptime")), head: head) == nil)
        #expect(UpdateOffer.offered(record(.pullRequest(3)), head: nil) == nil, "not even gone from the repository")
    }

    @Test("where a copy came from, as its row says it, and the page it links to", arguments: [
        (PluginRef(name: "main"), Phrase.pluginFrom(source: "github.com/iillyyaa1997/udeck-plugins", commit: "a1b2c3d"), nil),
        (PluginRef.pullRequest(3), Phrase.pluginFromPullRequest(number: 3, commit: "a1b2c3d"),
         "https://github.com/iillyyaa1997/udeck-plugins/pull/3"),
        (PluginRef.branch("fix/uptime"), Phrase.pluginFromBranch(name: "fix/uptime", commit: "a1b2c3d"),
         "https://github.com/iillyyaa1997/udeck-plugins/tree/fix/uptime"),
        (PluginRef.branch("a b#c"), Phrase.pluginFromBranch(name: "a b#c", commit: "a1b2c3d"),
         "https://github.com/iillyyaa1997/udeck-plugins/tree/a%20b%23c"),
        (PluginRef(kind: "commit", name: "x"), Phrase.pluginFrom(source: "github.com/iillyyaa1997/udeck-plugins", commit: "a1b2c3d"),
         nil),
    ] as [(PluginRef, Phrase, String?)])
    func fromLines(ref: PluginRef, phrase: Phrase, page: String?) {
        let installed = record(ref)
        #expect(installed.fromPhrase == phrase)
        #expect(installed.refPage?.absoluteString == page)
    }

    @Test("Unverified on the card's header: a branch's or a pull request's copy, as installed or changed since; nothing else")
    func cardHeader() {
        let pulled = record(.pullRequest(3))
        let verified = record(PluginRef(name: "main"))
        #expect(PluginStanding.cardSaysUnverified(.unverified, record: pulled, linked: false))
        #expect(PluginStanding.cardSaysUnverified(.modifiedLocally, record: pulled, linked: false))
        #expect(!PluginStanding.cardSaysUnverified(.modifiedLocally, record: verified, linked: false),
                "the default branch's copy changed on disk is Modified locally, in Settings")
        #expect(!PluginStanding.cardSaysUnverified(.verified, record: verified, linked: false))
        #expect(!PluginStanding.cardSaysUnverified(.folderOfYourOwn, record: nil, linked: false))
        #expect(!PluginStanding.cardSaysUnverified(.missing, record: pulled, linked: false))
        #expect(!PluginStanding.cardSaysUnverified(.unverified, record: pulled, linked: true), "a link is the operator's own")
        #expect(!PluginStanding.cardSaysUnverified(nil, record: pulled, linked: false), "not hashed yet: nothing said yet")
    }

    @Test("what the card asking about code nobody verified says of where it comes from")
    func consentSource() {
        let pulled = record(.pullRequest(3))
        #expect(ConsentSource.of(pulled, basis: .tree, recordsReadable: true, changedHere: false)
                == .permissionsUnverifiedSource(ref: .pullRequest(3), repository: Self.repository, changedHere: false))
        #expect(ConsentSource.of(pulled, basis: .tree, recordsReadable: true, changedHere: true)
                == .permissionsUnverifiedSource(ref: .pullRequest(3), repository: Self.repository, changedHere: true))
        #expect(ConsentSource.of(pulled, basis: .version, recordsReadable: true, changedHere: false) == nil,
                "held to the version — a link at its id — nothing is said")
        #expect(ConsentSource.of(nil, basis: .tree, recordsReadable: false, changedHere: false) == .permissionsSourceUnknown)
        #expect(ConsentSource.of(pulled, basis: .tree, recordsReadable: false, changedHere: false) == .permissionsSourceUnknown)
        #expect(ConsentSource.of(record(PluginRef(name: "main")), basis: .tree, recordsReadable: true, changedHere: false) == nil)
        #expect(ConsentSource.of(nil, basis: .tree, recordsReadable: true, changedHere: false) == nil)

        for language in Language.allCases {
            let strings = Strings(language)
            let said = strings(.permissionsUnverifiedSource(ref: .pullRequest(3), repository: Self.repository, changedHere: false))
            #expect(said.contains(Self.repository) && said.contains("#3"))
            #expect(said.contains(language == .russian ? "запроса на слияние #3" : "pull request #3"))
            #expect(said.contains(language == .russian ? "а не из того, что репозиторий влил" : "not from what the repository merged"))
            let branch = strings(.permissionsUnverifiedSource(ref: .branch("fix/uptime"), repository: Self.repository,
                                                              changedHere: true))
            #expect(branch.contains(language == .russian ? "ветки fix/uptime" : "branch fix/uptime"))
            #expect(branch.contains(language == .russian ? "изменён на этом Mac" : "changed on this Mac"))
            for text in [said, branch, strings(.permissionsSourceUnknown)] {
                let lower = text.lowercased()
                #expect(!lower.contains("sandbox") && !lower.contains("restrict") && !lower.contains("песочниц"),
                        "never sandboxed, never restricted: \(text)")
            }
        }
    }

    // MARK: - A link that names nothing to install

    @Test("why a link names nothing to install, said with what it is", arguments: [
        (RepositoryLink.Refusal.commit(pullCommit) as any Error,
         Phrase.linkRefused(.commit(pullCommit), official: repository) as Phrase?),
        (RepositoryLink.Refusal.notGitHub(host: "gitlab.com"), .linkRefused(.notGitHub(host: "gitlab.com"), official: repository)),
        (RefResolver.Refusal.notFound(.pullRequest(9)), .linkNotFound(.pullRequest(9), official: repository)),
        (RefResolver.Refusal.notFound(.branch("gone", plugin: nil)), .linkNotFound(.branch("gone", plugin: nil), official: repository)),
        (RefResolver.Refusal.forkNotYet(RepositoryAddress(path: "someone/udeck-plugins")),
         .linkOtherRepository(repository: "github.com/someone/udeck-plugins", official: repository)),
        (ProviderError.rateLimited(until: Date(timeIntervalSince1970: 1_790_003_600)), nil),
        (ProviderError.unreachable("offline"), nil),
        (CatalogueError.notFound, nil),
    ] as [(any Error, Phrase?)])
    func linkRefusals(error: any Error, phrase: Phrase?) {
        #expect(LinkRefusal.phrase(error, official: .official) == phrase)
    }

    @Test("what each refusal says, in both languages: what the link was, and what to paste instead")
    func linkRefusalWords() {
        for language in Language.allCases {
            let strings = Strings(language)
            let commit = strings(.linkRefused(.commit(Self.pullCommit), official: Self.repository))
            #expect(commit.contains("a1b2c3d") && !commit.contains(Self.pullCommit))
            #expect(strings(.linkRefused(.notGitHub(host: "gitlab.com"), official: Self.repository)).contains("gitlab.com"))
            let other = strings(.linkRefused(.otherRepositoryPullRequest(RepositoryAddress(path: "o/r"), 7), official: Self.repository))
            #expect(other.contains("#7") && other.contains("github.com/o/r") && other.contains(Self.repository))
            #expect(strings(.linkRefused(.notABranch("a..b"), official: Self.repository)).contains("a..b"))
            #expect(strings(.linkRefused(.empty, official: Self.repository)).contains(Self.repository))
            #expect(strings(.linkNotFound(.pullRequest(9), official: Self.repository)).contains("#9"))
            #expect(strings(.linkNotFound(.branch("gone", plugin: nil), official: Self.repository)).contains("gone"))
            let fork = strings(.linkOtherRepository(repository: "github.com/someone/udeck-plugins", official: Self.repository))
            #expect(fork.contains("github.com/someone/udeck-plugins") && fork.contains(Self.repository))
            #expect(strings(.linkIsTheCatalogue(official: Self.repository, plugin: "uptime")).contains("uptime"))
            #expect(strings(.linkHead(ref: .pullRequest(3), commit: "a1b2c3d")).contains("#3")
                    && strings(.linkHead(ref: .pullRequest(3), commit: "a1b2c3d")).contains("a1b2c3d"))
            #expect(strings(.linkHead(ref: .branch("fix/uptime"), commit: "a1b2c3d")).hasPrefix(language == .russian ? "Ветка" : "Branch"))
            #expect(strings(.catalogueInstalledUnverified(ref: .pullRequest(3))).contains("#3"))
            #expect(strings(.catalogueSwitchToVerified(version: "1.0.0")).contains("1.0.0"))
        }
        #expect(Strings(.english)(.linkHead(ref: .pullRequest(3), commit: "a1b2c3d")) == "Pull request #3 at a1b2c3d")
        #expect(Strings(.english)(.pluginFromPullRequest(number: 3, commit: "a1b2c3d")) == "pull request #3 at a1b2c3d")
        #expect(Strings(.russian)(.pluginFromPullRequest(number: 3, commit: "a1b2c3d")) == "запрос на слияние #3, коммит a1b2c3d")
        #expect(Strings(.english)(.catalogueSwitchToVerified(version: "1.0.0")) == "Switch to verified 1.0.0")
        #expect(Strings(.russian)(.catalogueSwitchToVerified(version: "1.0.0")) == "Перейти на проверенную 1.0.0")
    }

    @Test("what a resolved link says above its list: the line and the commit, merged or closed, nothing new")
    func linkHead() {
        var resolution = Self.resolution(Self.pullRequestHead)
        #expect(LinkRefusal.head(of: resolution) == [.linkHead(ref: .pullRequest(3), commit: "a1b2c3d")])
        resolution.pullRequest = PullRequest(number: 3, state: .closed, merged: false, mergeCommit: nil, head: Self.pullCommit,
                                             headRef: "fix", headRepository: "someone/udeck-plugins", title: "A fix")
        #expect(LinkRefusal.head(of: resolution) == [.linkHead(ref: .pullRequest(3), commit: "a1b2c3d"), .linkPullRequestClosed])
        resolution.pullRequest?.merged = true
        #expect(LinkRefusal.head(of: resolution).last == .linkPullRequestMerged)
        // Merged into another branch than the default one (R4+R6's review,
        // low #3): what it merged is not in the catalogue, and nothing of it
        // is verified. Into main, or while either branch is not known, it is
        // said as a merge.
        resolution.defaultBranch = "main"
        resolution.pullRequest?.base = "main"
        #expect(LinkRefusal.head(of: resolution).last == .linkPullRequestMerged)
        resolution.pullRequest?.base = "next"
        #expect(LinkRefusal.head(of: resolution) == [.linkHead(ref: .pullRequest(3), commit: "a1b2c3d"),
                                                     .linkPullRequestMergedElsewhere(base: "next")])
        resolution.defaultBranch = nil
        #expect(LinkRefusal.head(of: resolution).last == .linkPullRequestMerged)
        resolution.defaultBranch = "main"
        resolution.pullRequest?.base = nil
        #expect(LinkRefusal.head(of: resolution).last == .linkPullRequestMerged)
        resolution.pullRequest?.merged = false
        resolution.pullRequest?.base = "next"
        #expect(LinkRefusal.head(of: resolution).last == .linkPullRequestClosed, "closed, unmerged, whatever its base")
        resolution.pullRequest?.state = .open
        resolution.pullRequest?.merged = false
        resolution.entries = []
        #expect(LinkRefusal.head(of: resolution) == [.linkHead(ref: .pullRequest(3), commit: "a1b2c3d"),
                                                     .linkNothingDiffers(ref: .pullRequest(3))])
        // A link into one plugin's folder: what is said is of that plugin — and
        // that it is not there, when it is not.
        resolution.plugin = "uptime"
        #expect(LinkRefusal.head(of: resolution).last == .linkNothingDiffers(ref: .pullRequest(3), plugin: "uptime"))
        resolution.plugin = "gone"
        #expect(LinkRefusal.head(of: resolution).last == .linkPluginNotThere(ref: .pullRequest(3), plugin: "gone"))
    }

    @Test("a commit GitHub no longer has, installed at — Back to, Reinstall, an earlier version: said, in both languages")
    func commitGoneWords() {
        #expect(Strings(.english)(.catalogueCommitGone(commit: "a1b2c3d"))
                == "a1b2c3d is no longer on GitHub — the history it was on may have been rewritten — so nothing can be installed from it; nothing was changed.")
        #expect(Strings(.russian)(.catalogueCommitGone(commit: "a1b2c3d"))
                == "Коммита a1b2c3d больше нет на GitHub — возможно, историю, где он был, переписали, — поэтому из него ничего не установить; ничего не изменено.")
    }

    @Test("a pull request merged into another branch, as the sheet says it, in both languages")
    func mergedElsewhereWords() {
        #expect(Strings(.english)(.linkPullRequestMergedElsewhere(base: "next"))
                == "This pull request was merged into next, not the default branch: what is listed is its head, and nothing of it is verified.")
        #expect(Strings(.russian)(.linkPullRequestMergedElsewhere(base: "next"))
                == "Этот запрос на слияние влит в next, а не в основную ветку: ниже — его последний коммит, и ничего из него не проверено.")
    }

    @Test("what an empty list says, in both languages: every plugin, the one named, or the one that is not there")
    func nothingToInstallWords() {
        let branch = PluginRef.branch("fix/uptime")
        #expect(Strings(.english)(.linkNothingDiffers(ref: branch))
                == "Every plugin in branch fix/uptime is what the catalogue already has: there is nothing to install from it.")
        #expect(Strings(.english)(.linkNothingDiffers(ref: branch, plugin: "uptime"))
                == "uptime in branch fix/uptime is what the catalogue already has: there is nothing to install from it.")
        #expect(Strings(.english)(.linkPluginNotThere(ref: branch, plugin: "gone"))
                == "Branch fix/uptime has no plugins/gone: there is nothing to install from it.")
        #expect(Strings(.russian)(.linkNothingDiffers(ref: branch, plugin: "uptime"))
                == "uptime из ветки fix/uptime такой же, как в каталоге: устанавливать отсюда нечего.")
        #expect(Strings(.russian)(.linkPluginNotThere(ref: branch, plugin: "gone"))
                == "В файлах ветки fix/uptime нет plugins/gone: устанавливать отсюда нечего.")
    }
}
