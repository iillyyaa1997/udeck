import Foundation
import Testing
@testable import UDeckCore
import UDeckPluginFormatFixtures

/// A merged pull request becomes **Verified**, and what else becomes of one
/// (stage 3): when a copy of a branch or a pull request is what was merged and
/// its record alone is rewritten (`Adoption`), what became of its pull request
/// (`PullRequestLifecycle`), and what uDeck asks GitHub about it
/// (`PullRequestFollower`). UDeckKit has no tests, so every decision its rows
/// show is held here.
@Suite("A merged pull request becomes Verified")
struct AdoptionTests {
    static let copy = String(repeating: "a", count: 40)
    static let other = String(repeating: "b", count: 40)
    static let changed = String(repeating: "e", count: 40)
    static let head = String(repeating: "1", count: 40)
    static let mergeCommit = String(repeating: "2", count: 40)
    static let pullHead = "a1b2c3d4e5f60718293a4b5c6d7e8f9012345678"
    static let at = Date(timeIntervalSince1970: 1_790_000_000)
    static let later = Date(timeIntervalSince1970: 1_790_086_400)

    static func record(source: String = InstalledPlugins.officialSource, ref: PluginRef = .pullRequest(3),
                       tree: String = copy, previous: PreviousCopy? = nil, pinned: Bool = false) -> InstalledRecord {
        InstalledRecord(source: source, repository: .official, ref: ref, commit: pullHead, tree: tree, version: "1.0.1",
                        installedAt: at, pinned: pinned,
                        verification: PluginVerification(status: .unverified, by: nil, checkedAgainst: head, checkedAt: at),
                        previous: previous)
    }

    static func branch(at uptime: String?) -> Adoption.DefaultBranch {
        Adoption.DefaultBranch(repository: .official, name: "main", head: head,
                               trees: uptime.map { ["uptime": $0, "cpu": other] } ?? ["cpu": other])
    }

    static func pull(number: Int = 3, state: PullRequest.State = .closed, merged: Bool = true, base: String? = "main",
                     mergeCommit: String? = mergeCommit, mergeTree: String? = copy) -> FollowedPull {
        FollowedPull(number: number, head: pullHead, state: state, merged: merged, base: base, mergeCommit: mergeCommit,
                     mergeTree: mergeTree, checkedAt: at)
    }

    // MARK: - The truth table

    static let table: [(String, InstalledRecord, String?, String?, FollowedPull?, Adoption.Verdict)] = [
        ("exactly what the head has: adopted at the head", record(), copy, copy, nil, .adopt(commit: head)),
        ("a branch's copy the head has: content, not the ref", record(ref: .branch("fix/uptime")), copy, copy, nil,
         .adopt(commit: head)),
        ("the head has another tree, the commit it was merged as has the copy's: adopted there",
         record(), copy, other, pull(), .adopt(commit: mergeCommit)),
        ("changed on disk since it was installed: nobody merged what it is now",
         record(), changed, copy, pull(), .not(.changedOnDisk)),
        ("its folder not hashed, would not hash, or gone", record(), nil, copy, pull(), .not(.notHashed)),
        ("another tree at the head, nothing heard of a merge", record(), copy, other, nil, .not(.notMerged)),
        ("the plugin not at the head at all", record(), copy, nil, nil, .not(.notMerged)),
        ("merged with a change: neither commit has the copy's tree",
         record(), copy, other, pull(mergeTree: other), .not(.notMerged)),
        ("merged where the folder is not", record(), copy, other, pull(mergeTree: ""), .not(.notMerged)),
        ("another pull request's merge", record(), copy, other, pull(number: 4), .not(.notMerged)),
        ("closed without being merged, whatever else was written", record(), copy, other, pull(state: .closed, merged: false),
         .not(.notMerged)),
        ("merged with no commit named", record(), copy, other, pull(mergeCommit: nil, mergeTree: nil), .not(.notMerged)),
        ("merged into another branch, as exactly the copy: nothing there is verified",
         record(), copy, other, pull(base: "next"), .not(.notMerged)),
        ("merged into a branch GitHub did not name", record(), copy, other, pull(base: nil), .not(.notMerged)),
        ("a branch's copy and a pull request's merge", record(ref: .branch("fix/uptime")), copy, other, pull(),
         .not(.notMerged)),
        ("the default branch's copy already", record(ref: .defaultBranch("main")), copy, copy, nil,
         .not(.verifiedAlready)),
        ("another source's copy", record(source: "mine"), copy, copy, pull(), .not(.anotherSource)),
    ]

    @Test("a copy is adopted when its folder is what it was installed as and that is what was merged", arguments: 0..<table.count)
    func verdict(row: Int) {
        let (label, record, disk, atHead, pull, expected) = Self.table[row]
        #expect(Adoption.verdict("uptime", record: record, treeOnDisk: disk, branch: Self.branch(at: atHead), pull: pull)
                == expected, "\(label)")
    }

    @Test("merged into the default branch: only when both branches are known and are the same")
    func mergedInto() {
        #expect(Self.pull().mergedInto("main"))
        #expect(!Self.pull(base: "next").mergedInto("main"), "another branch")
        #expect(!Self.pull(merged: false).mergedInto("main"), "closed without being merged")
        #expect(!Self.pull(base: nil).mergedInto("main"), "GitHub did not say")
        #expect(!Self.pull(base: nil).mergedInto(nil), "neither is known")
        #expect(!Self.pull().mergedInto(nil), "the default branch not known")
        let unnamed = Adoption.DefaultBranch(repository: .official, name: nil, head: Self.head, trees: ["uptime": Self.other])
        #expect(Adoption.verdict("uptime", record: Self.record(), treeOnDisk: Self.copy, branch: unnamed,
                                 pull: Self.pull(base: nil)) == .not(.notMerged), "no name on either side")
    }

    @Test("adopted: the record alone, as the default branch's at that commit, verified against the head; all else kept")
    func adoptedRecord() throws {
        let previous = PreviousCopy(ref: .defaultBranch("main"), commit: Self.head, tree: Self.other, version: "1.0.0",
                                    repository: .official)
        var before = Self.record(previous: previous, pinned: true)
        before.automatic = true
        let after = Adoption.adopted(before, at: Self.mergeCommit, branch: Self.branch(at: Self.other), now: Self.later)
        #expect(after.source == "official" && after.repository == .official && after.ref == .defaultBranch("main"))
        #expect(after.commit == Self.mergeCommit)
        #expect(after.verification == PluginVerification(status: .verified, by: "official", checkedAgainst: Self.head,
                                                         checkedAt: Self.later))
        #expect(after.tree == before.tree && after.version == before.version && after.installedAt == before.installedAt)
        #expect(after.pinned && after.previous == previous && after.automatic == true, "nothing on disk changed")
        #expect(after.isOfficialDefault)
        #expect(PluginStanding.of(record: after, folderExists: true, treeOnDisk: Self.copy) == .verified)
        #expect(PluginStanding.cardSaysUnverified(.verified, record: after, linked: false) == false)
        #expect(after.fromPhrase == .pluginFrom(source: "github.com/iillyyaa1997/udeck-plugins", commit: "2222222"))
        // Written and read back as any record of the default branch.
        let data = try JSONFileStore<InstalledPlugins>.encoder.encode(InstalledPlugins(plugins: ["uptime": after]))
        #expect(try JSONFileStore<InstalledPlugins>.decoder.decode(InstalledPlugins.self, from: data).plugins["uptime"] == after)
    }

    /// The decision for a copy of code nobody verified is held to its tree;
    /// adopted, the copy is verified and its decision is held to its version,
    /// as any verified copy's is: the card does not ask again.
    @Test("the decision made for the pull request's copy holds for the adopted one, with no question")
    func decisionHolds() throws {
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: Data(FakeRepository.manifest(version: "1.0.1").utf8))
        let grant = PluginGrant(granted: [.exec("sysctl")], decidedForVersion: "1.0.1", decidedForTree: Self.copy,
                                decidedAt: Self.at)
        let before = Self.record()
        #expect(ConsentBasis.of(before, linked: false, recordsReadable: true) == .tree)
        #expect(PermissionGate.launchDecision(for: manifest, grant: grant, enabled: true, requiredTree: Self.copy) == .allowed)
        let after = Adoption.adopted(before, at: Self.head, branch: Self.branch(at: Self.copy), now: Self.later)
        let basis = ConsentBasis.of(after, linked: false, recordsReadable: true)
        #expect(basis == .version)
        #expect(PermissionGate.launchDecision(for: manifest, grant: grant, enabled: true,
                                              requiredTree: basis.requiredTree(hashed: Self.copy)) == .allowed)
        #expect(ConsentSource.of(after, basis: basis, recordsReadable: true, changedHere: false) == nil,
                "its card no longer says where code nobody verified comes from")
    }

    @Test("applied to every record: only what was merged, each at its commit, the others as they were")
    func apply() {
        let installed = InstalledPlugins(plugins: [
            "uptime": Self.record(),
            "merged": Self.record(),
            "edited": Self.record(),
            "gone": Self.record(),
            "verified": Self.record(ref: .defaultBranch("main")),
        ])
        let branch = Adoption.DefaultBranch(repository: .official, name: "main", head: Self.head,
                                            trees: ["uptime": Self.copy, "merged": Self.other, "edited": Self.copy,
                                                    "gone": Self.copy, "verified": Self.copy])
        let followed = FollowedRefs(pulls: ["merged": Self.pull(), "uptime": Self.pull(mergeTree: Self.other)])
        let trees: [String: String?] = ["uptime": Self.copy, "merged": Self.copy, "edited": Self.changed,
                                        "verified": Self.copy]
        let (records, adopted) = Adoption.apply(installed, trees: trees, branch: branch, followed: followed, now: Self.later)
        #expect(adopted == ["uptime": Self.head, "merged": Self.mergeCommit])
        #expect(records.plugins["uptime"]?.isOfficialDefault == true && records.plugins["uptime"]?.commit == Self.head)
        #expect(records.plugins["merged"]?.commit == Self.mergeCommit)
        for id in ["edited", "gone", "verified"] {
            #expect(records.plugins[id] == installed.plugins[id], "\(id) as it was")
        }
    }

    /// Adopted at the commit its pull request was merged as, the copy is a
    /// verified copy behind the head: what the head has is offered, or made
    /// by itself, as for any — and the folders hashed again find nothing to
    /// write.
    @Test("adopted where it was merged, the head's version is the update of a verified copy")
    func thenTheUpdate() throws {
        var head = FakeRepository.withUptime(version: "1.0.2")
        head.commit = Self.head
        let entry = CatalogueEntry(id: "uptime", listing: head.plugin("uptime"),
                                   verdict: RepositoryRules.check(folder: "uptime", listing: head.plugin("uptime"),
                                                                  manifest: head.data(at: "plugins/uptime/manifest.json"),
                                                                  udeck: SemanticVersion("0.7.0")))
        let before = Self.record()
        #expect(UpdateOffer.offered(before, head: entry) == nil, "a pull request's copy is offered nothing")
        let after = Adoption.adopted(before, at: Self.mergeCommit, branch: Self.branch(at: entry.listing.tree), now: Self.later)
        let offer = UpdateOffer.offered(after, head: entry)
        #expect(offer == .newer(version: "1.0.2"))
        let plugin = AutoUpdate.Plugin(record: after, offer: offer, standing: .verified, asksNow: [.exec("sysctl")],
                                       asksAtHead: [.exec("sysctl")], place: .deleted)
        #expect(AutoUpdate.verdict(plugin, switchedOn: true, busy: false) == .update(version: "1.0.2"))
        #expect(after.verification(treeOnDisk: Self.copy, headCommit: Self.head, now: Self.later)
                    .saysTheSame(as: after.verification), "verified against the head already: nothing to write")
    }

    // MARK: - At install time

    static var pullRequestHead: FakeRepository {
        var repository = FakeRepository.withUptime()
        repository.addPlugin("uptime", version: "1.0.1")
        repository.commit = pullHead
        return repository
    }

    func installer(_ repository: FakeRepository, in udeck: TemporaryDirectory) -> PluginInstaller {
        let files = repository.files.mapValues(\.data)
        return PluginInstaller(
            paths: udeck.paths, discovery: PluginDiscovery(searchPath: ["/bin", "/usr/bin"], udeck: SemanticVersion("0.7.0")),
            trash: TestTrash(in: udeck.url),
            fetch: { path, _ in
                guard let data = files[path] else { throw ProviderError.notFound }
                return data
            },
            now: { Self.later }
        )
    }

    func request(_ operation: InstallRequest.Operation, headTree: String?) -> InstallRequest {
        InstallRequest(operation: operation, id: PluginIdentifier(rawValue: "uptime")!, sourceRepository: .official,
                       repository: .official, ref: .pullRequest(3), commit: Self.pullHead,
                       folder: Self.pullRequestHead.plugin("uptime"), version: "1.0.1", headCommit: Self.head,
                       headTree: headTree, defaultBranch: "main")
    }

    @Test("installed when its folder is exactly what the head has: recorded as the default branch's at the head, verified")
    func atInstall() async throws {
        let udeck = TemporaryDirectory()
        let installer = installer(Self.pullRequestHead, in: udeck)
        let tree = Self.pullRequestHead.plugin("uptime").tree
        let record = try installer.commit(try await installer.stage(request(.install, headTree: tree)))
        #expect(record.isOfficialDefault && record.ref == .defaultBranch("main") && record.commit == Self.head)
        #expect(record.verification.status == .verified && record.verification.by == "official" && record.tree == tree)
        #expect(try installer.loadRecords().plugins["uptime"] == record)
        // Put back by Reinstall where the head has something else: the pull request's, unverified.
        let again = try installer.commit(try await installer.stage(request(.reinstall, headTree: Self.other)))
        #expect(again.ref == .pullRequest(3) && again.verification.status == .unverified && again.commit == Self.pullHead)
        // And by Reinstall where the head has exactly it: verified again.
        let merged = try installer.commit(try await installer.stage(request(.reinstall, headTree: tree)))
        #expect(merged.isOfficialDefault && merged.commit == Self.head && merged.previous == again.previous)
        // Nothing known of the head: as installed.
        var unknown = request(.install, headTree: tree)
        unknown.headCommit = nil
        #expect(try installer.commit(try await installer.stage(unknown)).ref == .pullRequest(3))
    }

    // MARK: - What became of the pull request

    /// Label, record, what was heard, the default branch, whether the
    /// verified version can be put in the copy's place here, and what the
    /// rows say.
    static let lifecycle: [(String, InstalledRecord?, FollowedPull?, String?, Bool, PullRequestLifecycle?)] = [
        ("open", record(), pull(state: .open, merged: false, mergeCommit: nil, mergeTree: nil), "main", true, .open),
        ("closed without being merged", record(), pull(state: .closed, merged: false, mergeCommit: nil, mergeTree: nil),
         "main", true, .closed),
        ("merged as something else, the verified version there to offer", record(), pull(mergeTree: other), "main", true,
         .mergedDiffers),
        ("merged, and no verified version to offer: not in the catalogue, refused here, or the catalogue off",
         record(), pull(mergeTree: ""), "main", false, .mergedNothingOffered),
        ("merged as exactly the copy, not adopted, nothing to offer", record(), pull(), "main", false,
         .mergedNothingOffered),
        ("merged into another branch: nothing more than Unverified", record(), pull(base: "next", mergeCommit: nil,
                                                                                    mergeTree: nil), "main", true, .open),
        ("merged into another branch, nothing to offer", record(), pull(base: "next", mergeCommit: nil, mergeTree: nil),
         "main", false, .open),
        ("merged, the default branch not known", record(), pull(mergeTree: other), nil, true, .open),
        ("opened again", record(), pull(state: .open, merged: false, mergeCommit: nil, mergeTree: nil), "main", true, .open),
        ("nothing heard yet", record(), nil, "main", true, nil),
        ("heard of another pull request at the id", record(), pull(number: 4, state: .closed, merged: false), "main", true, nil),
        ("a branch's copy", record(ref: .branch("fix/uptime")), pull(state: .closed, merged: false), "main", true, nil),
        ("the default branch's copy", record(ref: .defaultBranch("main")), pull(), "main", true, nil),
        ("no record", nil, pull(), "main", true, nil),
    ]

    @Test("what became of the pull request, as heard", arguments: 0..<lifecycle.count)
    func whatBecameOfIt(row: Int) {
        let (label, record, pull, defaultBranch, offered, expected) = Self.lifecycle[row]
        #expect(PullRequestLifecycle.of(record, followed: pull, defaultBranch: defaultBranch, verifiedOffered: offered)
                == expected, "\(label)")
    }

    @Test("the rows say it: merged as something else, an offer; closed, a warning; open, nothing", arguments: Language.allCases)
    func said(language: Language) {
        let strings = Strings(language)
        #expect(PullRequestLifecycle.open.rowPhrase(number: 3) == nil && PullRequestLifecycle.open.cataloguePhrase == nil)
        #expect(PullRequestLifecycle.mergedDiffers.rowPhrase(number: 3) == .pluginPullRequestMergedDiffers(number: 3))
        #expect(PullRequestLifecycle.closed.rowPhrase(number: 3) == .pluginPullRequestClosed(number: 3))
        #expect(PullRequestLifecycle.mergedNothingOffered.rowPhrase(number: 3) == .pluginPullRequestMergedNothingOffered(number: 3))
        #expect(PullRequestLifecycle.mergedNothingOffered.cataloguePhrase == .catalogueMergedDiffers)
        #expect(PullRequestLifecycle.mergedDiffers.cataloguePhrase == .catalogueMergedDiffers)
        #expect(PullRequestLifecycle.closed.cataloguePhrase == .catalogueClosedUnmerged)
        let merged = strings(.pluginPullRequestMergedDiffers(number: 3))
        let nothing = strings(.pluginPullRequestMergedNothingOffered(number: 3))
        let closed = strings(.pluginPullRequestClosed(number: 3))
        let line = CatalogueRowState.unverified(version: "1.0.2", refusal: nil, folderGone: true)
            .unverifiedLine(ref: .pullRequest(3), id: "uptime", path: "~/.udeck/plugins", lifecycle: .mergedDiffers)?
            .map { strings($0) }.joined(separator: " — ")
        switch language {
        case .english:
            #expect(merged == "Pull request #3 was merged, and the verified version differs — update")
            #expect(nothing == "Pull request #3 was merged; no verified version is offered here, and the plugin keeps running")
            #expect(closed == "Pull request #3 was closed without being merged; the plugin keeps running")
            #expect(line == "Installed here from pull request #3: unverified — merged, and the verified version differs — "
                    + "uptime is not in ~/.udeck/plugins")
            #expect(strings(.catalogueClosedUnmerged) == "closed without being merged")
        case .russian:
            #expect(merged == "Запрос на слияние #3 влит, и проверенная версия отличается — обновить")
            #expect(nothing == "Запрос на слияние #3 влит; проверенной версии здесь не предлагается, плагин продолжает работать")
            #expect(closed == "Запрос на слияние #3 закрыт без слияния; плагин продолжает работать")
            #expect(line == "Здесь установлен из запроса на слияние #3: не проверен — влит, и проверенная версия отличается — "
                    + "uptime нет в ~/.udeck/plugins")
            #expect(strings(.catalogueClosedUnmerged) == "закрыт без слияния")
        }
        // Open, the line is what it was.
        #expect(CatalogueRowState.unverified(version: "1.0.2", refusal: nil)
                    .unverifiedLine(ref: .pullRequest(3), id: "uptime", path: "~/.udeck/plugins", lifecycle: .open)
                == [.catalogueInstalledUnverified(ref: .pullRequest(3))])
    }

    @Test("what GitHub said, kept: a merge with the tree it was merged as, or nothing until that is known")
    func heard() {
        var listing = FakeRepository.withUptime(version: "1.0.1")
        listing.commit = Self.mergeCommit
        let tree = listing.plugin("uptime").tree
        func pull(state: PullRequest.State, merged: Bool, mergeCommit: String?, base: String? = "main") -> PullRequest {
            PullRequest(number: 3, state: state, merged: merged, mergeCommit: mergeCommit, head: Self.pullHead,
                        headRef: "fix", headRepository: "someone/udeck-plugins", title: "A fix", base: base)
        }
        let open = FollowedPull.of(pull(state: .open, merged: false, mergeCommit: nil), id: "uptime", defaultBranch: "main",
                                   mergeListing: nil, now: Self.at)
        #expect(open == FollowedPull(number: 3, head: Self.pullHead, state: .open, merged: false, base: "main",
                                     mergeCommit: nil, mergeTree: nil, checkedAt: Self.at))
        let merged = pull(state: .closed, merged: true, mergeCommit: Self.mergeCommit)
        let heard = FollowedPull.of(merged, id: "uptime", defaultBranch: "main", mergeListing: listing.listing, now: Self.at)
        #expect(heard?.mergeTree == tree && heard?.mergeCommit == Self.mergeCommit && heard?.base == "main")
        #expect(FollowedPull.of(merged, id: "cpu", defaultBranch: "main", mergeListing: listing.listing, now: Self.at)?.mergeTree
                == "", "a folder the merge does not have")
        #expect(FollowedPull.of(merged, id: "uptime", defaultBranch: "main", mergeListing: nil, now: Self.at) == nil,
                "merged as what, not known yet")
        var elsewhere = listing
        elsewhere.commit = Self.head
        #expect(FollowedPull.of(merged, id: "uptime", defaultBranch: "main", mergeListing: elsewhere.listing, now: Self.at) == nil,
                "another commit's listing says nothing of this one")
        let known = Self.pull(mergeTree: tree)
        #expect(FollowedPull.of(merged, id: "uptime", defaultBranch: "main", mergeListing: nil, knownBefore: known,
                                now: Self.later)?.mergeTree == tree, "read before: kept")
        #expect(FollowedPull.of(merged, id: "uptime", defaultBranch: "main", mergeListing: nil,
                                knownBefore: Self.pull(mergeCommit: Self.head), now: Self.later) == nil,
                "read before of another commit: not this one")
        #expect(FollowedPull.of(pull(state: .closed, merged: true, mergeCommit: nil), id: "uptime", defaultBranch: "main",
                                mergeListing: nil, now: Self.at)?.mergeTree == nil, "merged with no commit named: nothing to read")
        // Merged into another branch — or one GitHub did not name, or with the
        // default branch not known: said, and nothing of the commit kept, its
        // listing at hand or not.
        let next = pull(state: .closed, merged: true, mergeCommit: Self.mergeCommit, base: "next")
        for (label, pull, defaultBranch) in [("another branch", next, "main"),
                                             ("a branch not named", pull(state: .closed, merged: true,
                                                                         mergeCommit: Self.mergeCommit, base: nil), "main"),
                                             ("the default branch not known", merged, nil)] as [(String, PullRequest, String?)] {
            let said = FollowedPull.of(pull, id: "uptime", defaultBranch: defaultBranch, mergeListing: listing.listing,
                                       knownBefore: known, now: Self.at)
            #expect(said == FollowedPull(number: 3, head: Self.pullHead, state: .closed, merged: true, base: pull.base,
                                         mergeCommit: nil, mergeTree: nil, checkedAt: Self.at), "\(label)")
        }
        // Kept by plugin id, and read for the pull request the copy came from only.
        let refs = FollowedRefs(pulls: ["uptime": known])
        #expect(refs.pull(of: "uptime", record: Self.record()) == known)
        #expect(refs.pull(of: "uptime", record: Self.record(ref: .pullRequest(4))) == nil)
        #expect(refs.pull(of: "uptime", record: Self.record(ref: .defaultBranch("main"))) == nil)
        #expect(refs.pull(of: "cpu", record: Self.record()) == nil)
    }

    @Test("kept beside the catalogue, read back; a file that will not parse is started over")
    func kept() throws {
        let udeck = TemporaryDirectory()
        let store = CatalogueStore(paths: udeck.paths)
        #expect(store.followed() == FollowedRefs())
        let refs = FollowedRefs(pulls: ["uptime": Self.pull(), "cpu": Self.pull(state: .open, merged: false, mergeCommit: nil,
                                                                                 mergeTree: nil)])
        try store.save(followed: refs)
        #expect(store.followed() == refs)
        let file = udeck.paths.catalogue.appendingPathComponent("official/followed.json")
        #expect(FileManager.default.fileExists(atPath: file.path))
        try Data("{ not json".utf8).write(to: file)
        #expect(store.followed() == FollowedRefs())
    }

    // MARK: - What Look up heard, kept at install

    /// Installing from a pull request already merged or closed: what **Look
    /// up** heard is kept with the copy (`FollowedRefs.keep`), so that its row
    /// says at once what became of it — before any read of the catalogue.
    @Test("what Look up heard is kept at install, and the row says at once what became of the pull request")
    func keptAtInstall() {
        var listing = FakeRepository.withUptime(version: "1.0.1")
        listing.commit = Self.mergeCommit
        let tree = listing.plugin("uptime").tree
        var changed = FakeRepository.withUptime(version: "1.0.2")
        changed.commit = Self.mergeCommit
        let copy = Self.record(tree: tree)
        func heard(_ state: PullRequest.State = .open, merged: Bool = false, number: Int = 3,
                   base: String? = "main") -> PullRequest {
            PullRequest(number: number, state: state, merged: merged, mergeCommit: merged ? Self.mergeCommit : nil,
                        head: Self.pullHead, headRef: "fix", headRepository: nil, title: "", base: base)
        }
        func kept(_ pull: PullRequest?, record: InstalledRecord = copy, before: FollowedRefs = FollowedRefs(),
                  listing merge: CommitListing? = nil) -> FollowedRefs {
            var refs = before
            refs.keep(pull, heardAtInstall: record, of: "uptime", defaultBranch: "main", mergeListing: merge, now: Self.at)
            return refs
        }
        func said(_ refs: FollowedRefs) -> PullRequestLifecycle? {
            PullRequestLifecycle.of(copy, followed: refs.pull(of: "uptime", record: copy), defaultBranch: "main",
                                    verifiedOffered: true)
        }
        #expect(said(kept(heard(.closed))) == .closed, "closed: said at once")
        let open = kept(heard())
        #expect(said(open) == .open && open.pulls["uptime"]?.state == .open, "open: kept, to be asked about")
        #expect(said(kept(heard(.closed, merged: true), listing: changed.listing)) == .mergedDiffers,
                "merged as something else, its listing cached: the verified version offered at once")
        let exactly = kept(heard(.closed, merged: true), listing: listing.listing)
        #expect(Adoption.verdict("uptime", record: copy, treeOnDisk: tree, branch: Self.branch(at: Self.other),
                                 pull: exactly.pull(of: "uptime", record: copy)) == .adopt(commit: Self.mergeCommit),
                "merged as exactly the copy: adopted at the commit it was merged as")
        #expect(said(kept(heard(.closed, merged: true, base: "next"))) == .open, "merged into another branch: Unverified")
        let before = FollowedRefs(pulls: ["uptime": Self.pull(state: .open, merged: false, mergeCommit: nil, mergeTree: nil)])
        #expect(kept(heard(.closed, merged: true), before: before) == before,
                "merged as a commit not in the cache: what was known stays, for the next read to ask")
        #expect(kept(nil, before: before) == before, "nothing looked up")
        #expect(kept(heard(.closed, number: 4), before: before) == before, "another pull request")
        #expect(kept(heard(), record: Self.record(ref: .defaultBranch("main")), before: before).pulls.isEmpty,
                "the default branch's copy: forgotten")
        #expect(kept(heard(), record: Self.record(ref: .branch("fix/uptime")), before: before).pulls.isEmpty,
                "a branch's copy: forgotten")
        let cpu = FollowedRefs(pulls: ["cpu": Self.pull()])
        #expect(kept(heard(.closed), before: cpu).pulls["cpu"] == Self.pull(), "another id untouched")
    }

    /// The asking runs away from the main thread; an install, an adoption or
    /// a removal can happen while it waits, and says its own word of that
    /// copy (`PullRequestFollower.Outcome.merged`).
    @Test("what an asking heard joins what is known now; a copy installed, adopted or removed meanwhile keeps its own")
    func joined() {
        let asked = InstalledPlugins(plugins: ["uptime": Self.record(), "removed": Self.record(), "adopted": Self.record(),
                                               "moved": Self.record(), "rechecked": Self.record(ref: .pullRequest(5))])
        let heard = PullRequestFollower.Outcome(
            followed: FollowedRefs(pulls: ["uptime": Self.pull(state: .closed, merged: false), "removed": Self.pull(),
                                           "adopted": Self.pull(), "moved": Self.pull(mergeTree: Self.other),
                                           "rechecked": Self.pull(number: 5)]),
            asked: ["adopted", "moved", "rechecked", "removed", "uptime"], leftAsTheyWere: [])
        let now = FollowedRefs(pulls: ["uptime": Self.pull(state: .open, merged: false, mergeCommit: nil, mergeTree: nil),
                                       "moved": Self.pull(state: .closed, merged: false),
                                       "installed": Self.pull(state: .closed, merged: false), "stale": Self.pull()])
        var installed = asked
        installed.plugins["removed"] = nil
        installed.plugins["adopted"] = Adoption.adopted(Self.record(), at: Self.head, branch: Self.branch(at: Self.copy),
                                                        now: Self.later)
        installed.plugins["moved"]?.commit = Self.other
        installed.plugins["rechecked"]?.verification.checkedAt = Self.later
        installed.plugins["installed"] = Self.record()
        let joined = heard.merged(into: now, askedAbout: asked, installed: installed)
        #expect(joined.pulls["uptime"] == heard.followed.pulls["uptime"], "its copy as it was asked about: what was heard")
        #expect(joined.pulls["rechecked"] == heard.followed.pulls["rechecked"], "checked again, the same copy")
        #expect(joined.pulls["removed"] == nil && joined.pulls["adopted"] == nil, "removed or adopted meanwhile: forgotten")
        #expect(joined.pulls["moved"] == now.pulls["moved"], "another copy put in its place meanwhile: what it said")
        #expect(joined.pulls["installed"] == now.pulls["installed"], "installed meanwhile: what Look up heard")
        #expect(joined.pulls["stale"] == nil, "of no copy at all: dropped, as the asking drops it")
    }

    // MARK: - Where the copy is said, its folder gone; and the pane

    @Test("a window of a copy whose folder has gone says what Reinstall puts back, when that is code nobody verified",
          arguments: Language.allCases)
    func reinstallSays(language: Language) {
        let strings = Strings(language)
        let branch = Self.record(ref: .branch("fix/uptime"))
        #expect(Self.record(ref: .defaultBranch("main")).reinstallSays(headTree: nil) == nil)
        #expect(Self.record().reinstallSays(headTree: Self.other)
                == .windowReinstallBrings(.pullRequest(number: 3, commit: "a1b2c3d", version: "1.0.1")))
        #expect(Self.record().reinstallSays(headTree: Self.copy) == nil, "what the head has comes back verified")
        let said = branch.reinstallSays(headTree: nil).map { strings($0) }
        switch language {
        case .english:
            #expect(said == "Reinstall puts back 1.0.1 from branch fix/uptime at a1b2c3d: code nobody verified.")
        case .russian:
            #expect(said == "«Переустановить» вернёт: версия 1.0.1 из ветки fix/uptime, коммит a1b2c3d. Этот код никто не проверял.")
        }
    }

    @Test("Nothing installed yet only when the list has no row at all")
    func nothingInstalled() {
        #expect(PluginsPane.saysNothingInstalled(folders: 0, missing: 0))
        #expect(!PluginsPane.saysNothingInstalled(folders: 0, missing: 1), "a Missing row is a row")
        #expect(!PluginsPane.saysNothingInstalled(folders: 2, missing: 0))
        #expect(!PluginsPane.saysNothingInstalled(folders: 1, missing: 1))
    }
}

/// What uDeck asks GitHub about the pull requests copies came from, and when
/// it asks nothing — against a provider of the test's own that counts its
/// requests (`Provider`, beside the link tests).
@Suite("Asking after pull requests")
struct PullRequestFollowerTests {
    let temp = TemporaryDirectory()
    var store: CatalogueStore { CatalogueStore(paths: temp.paths) }

    static let mergeCommit = String(repeating: "2", count: 40)
    static let pullHead = AdoptionTests.pullHead

    static func record(ref: PluginRef, tree: String = AdoptionTests.copy) -> InstalledRecord {
        AdoptionTests.record(ref: ref, tree: tree)
    }

    static let installed = InstalledPlugins(plugins: [
        "uptime": record(ref: .pullRequest(3)),
        "merged": record(ref: .pullRequest(5)),
        "atHead": record(ref: .pullRequest(6)),
        "branch": record(ref: .branch("fix/uptime")),
        "verified": record(ref: .defaultBranch("main")),
    ])
    static let headTrees = ["atHead": AdoptionTests.copy, "uptime": AdoptionTests.other]

    static var merge: FakeRepository {
        var repository = FakeRepository.withUptime()
        repository.addPlugin("merged", version: "1.0.1")
        repository.commit = mergeCommit
        return repository
    }

    static func pull(_ number: Int, state: PullRequest.State = .open, merged: Bool = false,
                     base: String? = "main") -> PullRequest {
        PullRequest(number: number, state: state, merged: merged, mergeCommit: merged ? mergeCommit : nil, head: pullHead,
                    headRef: "fix", headRepository: nil, title: "", base: base)
    }

    static func provider() -> Provider {
        Provider(commits: [merge], pulls: [3: pull(3, state: .closed), 5: pull(5, state: .closed, merged: true), 6: pull(6)])
    }

    /// The follower, after a read of the catalogue that found `defaultBranch`.
    func follower(_ provider: Provider, limits: RateLimitRecorder = RateLimitRecorder(),
                  defaultBranch: String? = "main") -> PullRequestFollower {
        try? store.save(CatalogueState(defaultBranch: defaultBranch))
        return PullRequestFollower(provider: provider, store: store, limits: limits, now: { AdoptionTests.at })
    }

    @Test("one question for each pull request's copy not at the head; the commit a merge was made as listed once")
    func asks() async {
        let provider = Self.provider()
        let outcome = await follower(provider).follow(Self.installed, headTrees: Self.headTrees, unrequested: true)
        #expect(provider.asked == ["pull 5", "tree \(Self.mergeCommit) recursive", "pull 3"],
                "not the copy at the head, the branch's or the default branch's")
        #expect(outcome.asked == ["merged", "uptime"] && outcome.leftAsTheyWere.isEmpty)
        #expect(outcome.followed.pulls.keys.sorted() == ["merged", "uptime"])
        #expect(outcome.followed.pulls["uptime"]?.state == .closed && outcome.followed.pulls["uptime"]?.merged == false)
        #expect(outcome.followed.pulls["merged"]?.mergeTree == Self.merge.plugin("merged").tree)
        #expect(store.followed() == outcome.followed, "kept")
        // Asked again, its listing pruned from the cache as a read of the
        // catalogue prunes it: what it was merged as was kept, and the merge
        // is not listed again.
        store.prune(head: nil, installedCommits: [])
        #expect(store.listing(Self.mergeCommit) == nil, "the premise: the listing is gone from the cache")
        _ = await follower(provider).follow(Self.installed, headTrees: Self.headTrees, unrequested: false)
        #expect(Array(provider.asked.suffix(2)) == ["pull 5", "pull 3"])
        // A copy gone from the records is forgotten.
        var fewer = Self.installed
        fewer.plugins["merged"] = nil
        let after = await follower(provider).follow(fewer, headTrees: Self.headTrees, unrequested: false)
        #expect(after.followed.pulls.keys.sorted() == ["uptime"] && store.followed() == after.followed)
    }

    @Test("a merge into another branch is asked about and kept, and the commit it was merged as is never listed")
    func mergedElsewhere() async {
        let installed = InstalledPlugins(plugins: ["merged": Self.record(ref: .pullRequest(5))])
        let provider = Provider(commits: [Self.merge], pulls: [5: Self.pull(5, state: .closed, merged: true, base: "next")])
        let outcome = await follower(provider).follow(installed, headTrees: [:], unrequested: false)
        #expect(provider.asked == ["pull 5"], "nothing listed of a commit on another branch")
        #expect(outcome.followed.pulls["merged"] == FollowedPull(number: 5, head: Self.pullHead, state: .closed, merged: true,
                                                                 base: "next", mergeCommit: nil, mergeTree: nil,
                                                                 checkedAt: AdoptionTests.at))
        // Into `main`, with the default branch not known: nothing listed either.
        let unknown = Provider(commits: [Self.merge], pulls: [5: Self.pull(5, state: .closed, merged: true)])
        let heard = await follower(unknown, defaultBranch: nil).follow(installed, headTrees: [:], unrequested: false)
        #expect(unknown.asked == ["pull 5"] && heard.followed.pulls["merged"]?.mergeTree == nil)
        // Known, and it is the default branch: listed.
        let known = Provider(commits: [Self.merge], pulls: [5: Self.pull(5, state: .closed, merged: true)])
        _ = await follower(known).follow(installed, headTrees: [:], unrequested: false)
        #expect(known.asked == ["pull 5", "tree \(Self.mergeCommit) recursive"])
    }

    @Test("a read nobody asked for asks nothing while the reserve is all that is left; one asked for does")
    func reserve() async {
        let provider = Self.provider()
        let heard = FollowedRefs(pulls: ["uptime": AdoptionTests.pull(state: .open, merged: false, mergeCommit: nil,
                                                                      mergeTree: nil)])
        try? store.save(followed: heard)
        let low = RateLimitRecorder(RateLimitState(remaining: RateLimitState.reserveForTheOperator - 1,
                                                   reset: AdoptionTests.at.addingTimeInterval(3600)))
        let left = await follower(provider, limits: low).follow(Self.installed, headTrees: Self.headTrees, unrequested: true)
        #expect(provider.asked.isEmpty)
        #expect(left.followed == heard && left.leftAsTheyWere == ["merged", "uptime"], "what was heard stands")
        let asked = await follower(provider, limits: low).follow(Self.installed, headTrees: Self.headTrees, unrequested: false)
        #expect(provider.asked.first == "pull 5" && asked.asked == ["merged", "uptime"])
    }

    @Test("a limit reached stops the asking there, and what was heard stands")
    func limited() async {
        let provider = Self.provider()
        let heard = FollowedRefs(pulls: ["uptime": AdoptionTests.pull(state: .closed, merged: false, mergeCommit: nil,
                                                                      mergeTree: nil)])
        try? store.save(followed: heard)
        provider.limited = true
        let outcome = await follower(provider).follow(Self.installed, headTrees: Self.headTrees, unrequested: false)
        #expect(provider.asked == ["pull 5"], "one refusal, and nothing more asked")
        #expect(outcome.followed == heard && outcome.leftAsTheyWere == ["merged", "uptime"] && outcome.asked.isEmpty)
    }
}
