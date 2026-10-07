import Foundation
import Testing
@testable import UDeckCore
import UDeckPluginFormatFixtures

/// A warning's button acts on what the warning said, or says what is there
/// now (`ShownPlace`). UDeckKit has no tests, so the two halves every button
/// in Settings is made of — what is there now, asked of the disk, and what a
/// press comes to — are held here; the buttons call exactly these.
@Suite("A warning's button acts on what the warning said")
struct ShownPlaceTests {
    /// uDeck's folder and the author's, apart.
    let udeck = TemporaryDirectory()
    let work = TemporaryDirectory()
    var paths: UDeckPaths { udeck.paths }

    func live(_ id: String) -> URL { paths.plugins.appendingPathComponent(id, isDirectory: true) }

    func installer(_ repository: FakeRepository, trash: TestTrash) -> PluginInstaller {
        PluginInstaller(paths: paths, discovery: PluginDiscovery(searchPath: ["/bin", "/usr/bin"], udeck: SemanticVersion("0.5.0")),
                        trash: trash, fetch: FetchLog(repository).fetch, now: { Date(timeIntervalSince1970: 1_790_000_000) })
    }

    func install(_ id: String, from repository: FakeRepository, with installer: PluginInstaller) async throws {
        try installer.commit(try await installer.stage(InstallRequest(
            operation: .install, id: PluginIdentifier(rawValue: id)!, repository: .official, ref: PluginRef(name: "main"),
            commit: repository.commit, folder: repository.plugin(id), version: "1.0.0", headCommit: repository.commit
        )))
    }

    /// An author's working copy whose manifest says `id`.
    func workingCopy(id: String) throws -> URL {
        let folder = work.url.appendingPathComponent("W", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(FakeRepository.manifest(id: id).utf8).write(to: folder.appendingPathComponent("manifest.json"))
        try Data("#!/bin/sh\nprintf '{}'\n".utf8).write(to: folder.appendingPathComponent("uptime.sh"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: folder.appendingPathComponent("uptime.sh").path)
        return folder
    }

    /// C2b's review, step for step: `uptime` and `cpu` installed, `cpu`'s copy
    /// holding the operator's changes; **Link a folder…** of a working copy
    /// whose manifest says `uptime` warns of `uptime`; its id is changed to
    /// `cpu` while the warning is up, and **Link** is pressed. It used to put
    /// the link in `cpu`'s place and send `cpu`'s copy to the Trash, though
    /// the warning never named it.
    @Test("Link a folder…: an id changed while the warning is up gets a warning of its own, and nothing is replaced")
    func idChangedUnderTheWarning() async throws {
        var repository = FakeRepository.withUptime()
        repository.addPlugin("cpu")
        let trash = TestTrash(in: udeck.url)
        let installer = installer(repository, trash: trash)
        try await install("uptime", from: repository, with: installer)
        try await install("cpu", from: repository, with: installer)
        try Data("TOKEN=mine\n".utf8).write(to: live("cpu").appendingPathComponent(".env"))
        let records = try installer.loadRecords()

        let folder = try workingCopy(id: "uptime")
        let (_, shown) = try ShownPlace.Linking.now(folder, in: paths, installed: records)
        #expect(shown.id == "uptime" && shown.occupant == .installed(source: "github.com/iillyyaa1997/udeck-plugins")
                && !shown.toTrash)
        #expect(ShownPlace.linking(confirmed: nil, now: shown) == .ask(shown), "the first press warns")

        try Data(FakeRepository.manifest(id: "cpu").utf8).write(to: folder.appendingPathComponent("manifest.json"))
        let cpuBefore = everythingAt(live("cpu"))
        let uptimeBefore = everythingAt(live("uptime"))
        let (candidate, now) = try ShownPlace.Linking.now(folder, in: paths, installed: records)
        #expect(now.id == "cpu" && now.toTrash)
        #expect(ShownPlace.linking(confirmed: shown, now: now) == .ask(now),
                "Link on the warning about uptime is the warning about cpu, not cpu replaced")
        #expect(everythingAt(live("cpu")) == cpuBefore && everythingAt(live("uptime")) == uptimeBefore)
        #expect(trash.names.isEmpty)

        // Once the warning about cpu is the one confirmed, Link does what it says.
        #expect(ShownPlace.linking(confirmed: now, now: now) == .replace)
        try await installer.link(candidate, once: { true })
        #expect(PluginInstaller.isLink(live("cpu")) && trash.names == ["cpu"])
        #expect(everythingAt(live("uptime")) == uptimeBefore)
    }

    @Test("Link a folder…: a free id is linked at once, the same folder is already linked, whatever was confirmed")
    func freeOrSame() {
        let free = ShownPlace.Linking(id: "cpu", target: "/w", occupant: .nothing, toTrash: false)
        let shown = ShownPlace.Linking(id: "uptime", target: "/w", occupant: .installed(source: "a"), toTrash: false)
        #expect(ShownPlace.linking(confirmed: shown, now: free) == .linkAtOnce)
        #expect(ShownPlace.linking(confirmed: nil, now: free) == .linkAtOnce)
        let same = ShownPlace.Linking(id: "uptime", target: "/w", occupant: .link(destination: "/w", sameFolder: true),
                                      toTrash: false)
        #expect(ShownPlace.linking(confirmed: shown, now: same) == .alreadyLinked)
    }

    @Test("Link a folder…: any of the id, the folder, what is at the id or the Trash changed is a warning again, by bytes")
    func everyPartIsHeld() {
        let shown = ShownPlace.Linking(id: "uptime", target: "/w/caf\u{E9}",
                                       occupant: .link(destination: "/old/caf\u{E9}", sameFolder: false), toTrash: false)
        #expect(ShownPlace.holds(shown, now: shown))
        var now = shown
        now.id = "cpu"
        #expect(!ShownPlace.holds(shown, now: now))
        now = shown
        now.target = "/w/cafe\u{301}"
        #expect(!ShownPlace.holds(shown, now: now), "another spelling is another folder")
        now = shown
        now.occupant = .link(destination: "/old/cafe\u{301}", sameFolder: false)
        #expect(!ShownPlace.holds(shown, now: now))
        now.occupant = .folderOfYourOwn
        #expect(!ShownPlace.holds(shown, now: now))
        now = shown
        now.toTrash = true
        #expect(!ShownPlace.holds(shown, now: now))
        #expect(!ShownPlace.holds(ShownPlace.Linking(id: "a", target: "/w", occupant: .installed(source: "x"), toTrash: false),
                                  now: ShownPlace.Linking(id: "a", target: "/w", occupant: .installed(source: "y"), toTrash: false)))
        #expect(ShownPlace.linking(confirmed: shown, now: now) == .ask(now))
    }

    @Test("what is at a plugin's place, by the installer's rule: nothing, a link and where it leads, the operator's work, uDeck's own copy")
    func placeNow() async throws {
        let repository = FakeRepository.withUptime()
        let installer = installer(repository, trash: TestTrash(in: udeck.url))
        #expect(ShownPlace.Place.now("uptime", in: paths, record: nil, arriving: "1.0.0")
                == ShownPlace.Place(fate: .nothing, arriving: "1.0.0"))
        #expect(ShownPlace.Place.now("uptime", in: paths, record: nil, arriving: "1.0.0", copy: "4b825dc")
                == ShownPlace.Place(fate: .nothing, arriving: "1.0.0", copy: "4b825dc"), "the copy that comes, as told")

        try await install("uptime", from: repository, with: installer)
        let record = try installer.loadRecords().plugins["uptime"]
        #expect(ShownPlace.Place.now("uptime", in: paths, record: record, arriving: nil).fate == .deleted)
        #expect(ShownPlace.Place.now("uptime", in: paths, record: record, arriving: "1.0.0", copy: "c1").copy == "c1",
                "over uDeck's own copy, the copy that comes as told")
        try Data("TOKEN=mine\n".utf8).write(to: live("uptime").appendingPathComponent(".env"))
        #expect(ShownPlace.Place.now("uptime", in: paths, record: record, arriving: nil).fate == .toTrash)
        #expect(ShownPlace.Place.now("uptime", in: paths, record: nil, arriving: nil).fate == .toTrash,
                "a folder uDeck did not install is the operator's")

        try FileManager.default.removeItem(at: live("uptime"))
        let folder = try workingCopy(id: "uptime")
        try FileManager.default.createSymbolicLink(atPath: live("uptime").path, withDestinationPath: folder.path)
        #expect(ShownPlace.Place.now("uptime", in: paths, record: nil, arriving: nil).fate
                == .linkGoes(leadsTo: FilePaths.real(folder.path).path!))
        #expect(ShownPlace.Place.now("uptime", in: paths, record: nil, arriving: "1.0.0", copy: "c1").copy == "c1",
                "over a link, the copy that comes as told")
        try FileManager.default.removeItem(at: live("uptime"))
        try FileManager.default.createSymbolicLink(atPath: live("uptime").path, withDestinationPath: "../gone")
        #expect(ShownPlace.Place.now("uptime", in: paths, record: nil, arriving: nil).fate == .linkGoes(leadsTo: "../gone"),
                "a link that leads nowhere says what it says")
    }

    /// C2b2's review, and D1's: which copy a warning names was decided only
    /// where Settings' buttons call in, untested — **Update** asking with no
    /// copy, or **Back to** with none, passed every test and brought back the
    /// warning held to a version alone. What a button puts there says it.
    @Test("What a button brings says the copy its warning names: the folder's tree at the head, the commit for one at a commit, none for Remove")
    func arrival() throws {
        let tree = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
        let commit = "1111111111111111111111111111111111111111"
        #expect(ShownPlace.Arrival.atHead(version: "1.3.0", tree: tree).version == "1.3.0")
        #expect(ShownPlace.Arrival.atHead(version: "1.3.0", tree: tree).copy == Optional(tree), "Install and Update: the tree")
        #expect(ShownPlace.Arrival.atCommit(version: "1.2.0", commit: commit).version == "1.2.0")
        #expect(ShownPlace.Arrival.atCommit(version: "1.2.0", commit: commit).copy == Optional(commit),
                "Reinstall, Back to, an earlier version: the commit")
        #expect(ShownPlace.Arrival.nothing.version == nil)
        #expect(ShownPlace.Arrival.nothing.copy == nil, "Remove: nothing comes")

        #expect(ShownPlace.Place.now("uptime", in: paths, record: nil, bringing: .atHead(version: "1.3.0", tree: tree))
                == ShownPlace.Place(fate: .nothing, arriving: "1.3.0", copy: tree))
        #expect(ShownPlace.Place.now("uptime", in: paths, record: nil, bringing: .atCommit(version: "1.2.0", commit: commit))
                == ShownPlace.Place(fate: .nothing, arriving: "1.2.0", copy: commit))
        #expect(ShownPlace.Place.now("uptime", in: paths, record: nil, bringing: .nothing)
                == ShownPlace.Place(fate: .nothing, arriving: nil, copy: nil))

        // The same version at the head from another tree — a republish — is
        // another warning; so is the version at the head where the warning
        // named it at a commit.
        let shown = ShownPlace.Place.now("uptime", in: paths, record: nil, bringing: .atHead(version: "1.3.0", tree: tree))
        let republished = ShownPlace.Place.now("uptime", in: paths, record: nil,
                                               bringing: .atHead(version: "1.3.0", tree: "2222222222222222222222222222222222222222"))
        #expect(!ShownPlace.holds(shown, now: republished))
        #expect(!ShownPlace.holds(shown, now: ShownPlace.Place.now("uptime", in: paths, record: nil,
                                                                   bringing: .atCommit(version: "1.3.0", commit: tree + "0"))))
        #expect(ShownPlace.holds(shown, now: shown))
    }

    /// **Remove** on a linked plugin says only the link goes. A folder put in
    /// the link's place while the warning is up would go to the Trash — not
    /// what was said — so the press is the warning of the folder instead.
    @Test("Remove: always asked first; pressed on a warning that no longer says what is there, it says what is")
    func remove() throws {
        let folder = try workingCopy(id: "uptime")
        try FileManager.default.createDirectory(at: paths.plugins, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: live("uptime").path, withDestinationPath: folder.path)
        let shown = ShownPlace.Place.now("uptime", in: paths, record: nil, arriving: nil)
        #expect(ShownPlace.press(.remove, shown: nil, now: shown) == .ask(shown), "the first press warns")
        #expect(ShownPlace.press(.remove, shown: shown, now: shown) == .goAhead)

        try FileManager.default.removeItem(at: live("uptime"))
        udeck.writePlugin(folder: "uptime", manifest: FakeRepository.manifest())
        let now = ShownPlace.Place.now("uptime", in: paths, record: nil, arriving: nil)
        #expect(now.fate == .toTrash)
        #expect(ShownPlace.press(.remove, shown: shown, now: now) == .ask(now))
    }

    @Test("Install and Replace…: at once onto nothing or uDeck's own copy; over a link or the operator's work, after the warning that says it")
    func install() {
        let nothing = ShownPlace.Place(fate: .nothing, arriving: "1.0.0")
        let own = ShownPlace.Place(fate: .toTrash, arriving: "1.0.0")
        let link = ShownPlace.Place(fate: .linkGoes(leadsTo: "/w/uptime"), arriving: "1.0.0")
        #expect(ShownPlace.press(.install, shown: nil, now: nothing) == .goAhead)
        #expect(ShownPlace.press(.install, shown: nil, now: ShownPlace.Place(fate: .deleted, arriving: "1.0.0")) == .goAhead)
        #expect(ShownPlace.press(.install, shown: nil, now: own) == .ask(own), "a folder put there since the row said nothing is there")
        #expect(ShownPlace.press(.install, shown: nil, now: link) == .ask(link))
        #expect(ShownPlace.press(.install, shown: link, now: link) == .goAhead)
        #expect(ShownPlace.press(.install, shown: link, now: own) == .ask(own), "the link became a folder of the operator's")
        #expect(ShownPlace.press(.install, shown: own, now: nothing) == .goAhead, "nothing there to warn of any more")
    }

    /// A linked working copy's manifest edited while its consent card is up:
    /// **Allow** granted what the manifest asked for when it was pressed, one
    /// command more than the card listed. It grants nothing then, and the card
    /// asks about what is asked for now.
    @Test("Allow grants nothing the card did not show: what is asked for now is held already, or was shown, byte for byte")
    func allow() {
        let shown: [Capability] = [.exec("sysctl")]
        #expect(ShownPlace.allows(shown: shown, requested: [.exec("sysctl")], grant: nil, version: "1.0.0"))
        #expect(!ShownPlace.allows(shown: shown, requested: [.exec("sysctl"), .exec("rm")], grant: nil, version: "1.0.0"),
                "a command more than the card listed")
        let held = PluginGrant(granted: [.exec("rm")], denied: [], decidedForVersion: "1.0.0")
        #expect(ShownPlace.allows(shown: shown, requested: [.exec("sysctl"), .exec("rm")], grant: held, version: "1.0.0"),
                "the card lists what is undecided; what is granted for this version was shown before")
        #expect(!ShownPlace.allows(shown: shown, requested: [.exec("sysctl"), .exec("rm")], grant: held, version: "1.1.0"),
                "a grant for another version holds nothing")
        #expect(!ShownPlace.allows(shown: [.read("~/caf\u{E9}/*")], requested: [.read("~/cafe\u{301}/*")], grant: nil,
                                   version: "1.0.0"), "another spelling is another path")
        #expect(!ShownPlace.allows(shown: [.read("~/notes/*")], requested: [.write("~/notes/*")], grant: nil, version: "1.0.0"))
        #expect(ShownPlace.allows(shown: [.screen, .network("example.com")], requested: [.network("example.com"), .screen],
                                  grant: nil, version: "1.0.0"))
    }

    /// The specification: *"A plugin marked modified is not updated over
    /// without a word."* Every row with the button has the same rule —
    /// whether the installer will send something of the operator's to the
    /// Trash (`OperatorsWork`), not the row's mark — and names the version
    /// that comes.
    @Test("Update, Reinstall, Back to: the version the warning named is the one that comes, or the warning names the new one")
    func replaceCopy() {
        let shown = ShownPlace.Place(fate: .toTrash, arriving: "1.3.0")
        #expect(ShownPlace.press(.replaceCopy, shown: nil, now: shown) == .ask(shown))
        #expect(ShownPlace.press(.replaceCopy, shown: shown, now: shown) == .goAhead)
        let newer = ShownPlace.Place(fate: .toTrash, arriving: "1.4.0")
        #expect(ShownPlace.press(.replaceCopy, shown: shown, now: newer) == .ask(newer))
        #expect(ShownPlace.press(.replaceCopy, shown: nil, now: ShownPlace.Place(fate: .deleted, arriving: "1.4.0")) == .goAhead,
                "with nothing of the operator's there, as the button does unwarned")
        #expect(ShownPlace.press(.replaceCopy, shown: shown, now: ShownPlace.Place(fate: .deleted, arriving: "1.3.0")) == .goAhead)
        #expect(!ShownPlace.holds(ShownPlace.Place(fate: .toTrash, arriving: "1.0.0-caf\u{E9}"),
                                  now: ShownPlace.Place(fate: .toTrash, arriving: "1.0.0-cafe\u{301}")), "by bytes")
        #expect(!ShownPlace.holds(ShownPlace.Place(fate: .linkGoes(leadsTo: "/caf\u{E9}"), arriving: nil),
                                  now: ShownPlace.Place(fate: .linkGoes(leadsTo: "/cafe\u{301}"), arriving: nil)))
        #expect(!ShownPlace.holds(ShownPlace.Place(fate: .toTrash, arriving: nil), now: ShownPlace.Place(fate: .deleted, arriving: nil)))
        #expect(!ShownPlace.holds(ShownPlace.Place(fate: .toTrash, arriving: nil), now: ShownPlace.Place(fate: .toTrash, arriving: "1.0.0")))
    }

    /// C2b2's review: **Reinstall** on a missing `uptime` warned of a folder
    /// put there, and while the warning was up the folder became a link to a
    /// working copy; the warning's button took the link away without a word
    /// about it. The folder it led to stayed — nothing was lost — but the
    /// warning had not said what the press did.
    @Test("Update, Reinstall, Back to: over a link, first the warning that only the link goes — one that appeared under another warning too")
    func replaceCopyOverALink() {
        let shown = ShownPlace.Place(fate: .toTrash, arriving: "1.3.0", copy: "a1")
        let link = ShownPlace.Place(fate: .linkGoes(leadsTo: "/w/uptime"), arriving: "1.3.0", copy: "a1")
        #expect(ShownPlace.press(.replaceCopy, shown: shown, now: link) == .ask(link),
                "a link put where the copy was is warned of, not taken away")
        #expect(ShownPlace.press(.replaceCopy, shown: nil, now: link) == .ask(link), "a first press over a link warns")
        #expect(ShownPlace.press(.replaceCopy, shown: link, now: link) == .goAhead)
        #expect(ShownPlace.press(.replaceCopy, shown: link,
                                 now: ShownPlace.Place(fate: .linkGoes(leadsTo: "/w/other"), arriving: "1.3.0", copy: "a1"))
                != .goAhead, "a link to another folder is another warning")
    }

    /// C2b2's review: **Update** warned "your changes go to the Trash and
    /// 1.3.0 comes", the repository then published another tree under the
    /// same 1.3.0, and the warning's button installed a tree nobody had been
    /// shown. A version is what a manifest says; the copy is what comes.
    @Test("Update, Reinstall, Back to: held to the copy that comes — the same version from another tree or commit is a warning again")
    func replaceCopyHeldToTheCopy() {
        let shown = ShownPlace.Place(fate: .toTrash, arriving: "1.3.0", copy: "1111111111111111111111111111111111111111")
        let another = ShownPlace.Place(fate: .toTrash, arriving: "1.3.0", copy: "2222222222222222222222222222222222222222")
        #expect(ShownPlace.press(.replaceCopy, shown: shown, now: another) == .ask(another),
                "the same version, another copy: the warning again, nothing replaced")
        #expect(ShownPlace.press(.replaceCopy, shown: another, now: another) == .goAhead)
        #expect(ShownPlace.press(.install, shown: ShownPlace.Place(fate: .linkGoes(leadsTo: "/w"), arriving: "1.3.0", copy: "t1"),
                                 now: ShownPlace.Place(fate: .linkGoes(leadsTo: "/w"), arriving: "1.3.0", copy: "t2"))
                == .ask(ShownPlace.Place(fate: .linkGoes(leadsTo: "/w"), arriving: "1.3.0", copy: "t2")), "Replace… too")
        #expect(!ShownPlace.holds(ShownPlace.Place(fate: .toTrash, arriving: "1.3.0", copy: "caf\u{E9}"),
                                  now: ShownPlace.Place(fate: .toTrash, arriving: "1.3.0", copy: "cafe\u{301}")), "by bytes")
        #expect(!ShownPlace.holds(ShownPlace.Place(fate: .toTrash, arriving: "1.3.0", copy: nil),
                                  now: ShownPlace.Place(fate: .toTrash, arriving: "1.3.0", copy: "a1")))
        #expect(ShownPlace.holds(ShownPlace.Place(fate: .toTrash, arriving: "1.3.0", copy: "a1"),
                                 now: ShownPlace.Place(fate: .toTrash, arriving: "1.3.0", copy: "a1")))
    }
}
