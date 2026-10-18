import Foundation
import Testing
@testable import UDeckCore
import UDeckPluginFormatFixtures

/// The sources the operator adds (stage 4, R1a): `~/.udeck/sources.json` read
/// and written, the id each source is known by, and what a source is called on
/// screen. Every decision here is UDeckCore's, so it is held here.
@Suite("Sources of one's own")
struct SourcesTests {
    let udeck = TemporaryDirectory()
    static let at = Date(timeIntervalSince1970: 1_790_000_000)

    // The ids of the examples below, their hashes made with `shasum -a 256` over
    // `<provider>\n<host>\n<remoteID>`, not with uDeck's code.
    static let operatorsID = "gitlab.unicorns.place-udeck-plugins-cbe44e4d"
    static let teamID = "github.com-team-plugins-87a735c2"

    /// The design's example, ids and all.
    static let example = #"""
        {"version": 1, "sources": [
          {"id": "gitlab.unicorns.place-udeck-plugins-cbe44e4d", "provider": "gitlab", "host": "gitlab.unicorns.place",
           "path": "tools/udeck-plugins", "remoteID": 48, "access": "token", "trustedAt": "2026-10-20T10:01:00Z",
           "addedAt": "2026-10-20T10:00:00Z"},
          {"id": "github.com-team-plugins-87a735c2", "provider": "github", "host": "github.com",
           "path": "someone/team-plugins", "remoteID": 123456789, "access": "none", "trustedAt": null,
           "addedAt": "2026-10-20T11:00:00Z"}]}
        """#

    static func read(_ text: String) -> Result<SourceList, SourceList.Broken> {
        SourceList.read(Data(text.utf8))
    }

    static func list(_ entries: String...) -> String {
        #"{"version": 1, "sources": ["# + entries.joined(separator: ", ") + "]}"
    }

    static func entry(id: String = teamID, provider: String = "github", host: String = "github.com",
                      path: String = "someone/team-plugins", remoteID: String = "123456789", extra: String = "") -> String {
        #"{"id": "\#(id)", "provider": "\#(provider)", "host": "\#(host)", "path": "\#(path)", "remoteID": \#(remoteID)"#
            + #", "access": "none", "trustedAt": null, "addedAt": "2026-10-20T11:00:00Z"\#(extra)}"#
    }

    // MARK: - Ids

    @Test("an id is the slug and the first 8 hex digits of SHA-256 over provider, host and remoteID")
    func derivedIDs() {
        let operators = SourceIdentity(provider: "gitlab", host: "gitlab.unicorns.place", remoteID: 48)
        #expect(SourceID.derive(operators, path: "tools/udeck-plugins") == Self.operatorsID)
        let team = SourceIdentity(provider: "github", host: "GitHub.com", remoteID: 123_456_789)
        #expect(team.host == "github.com", "the host is lowercased")
        #expect(SourceID.derive(team, path: "someone/Team_Plugins") == Self.teamID, "lowercased, _ made -")
        #expect(SourceID.hash8(SourceIdentity(provider: "github", host: "github.com", remoteID: 1_393_324_153)) == "c1b97fce")
        #expect(SourceID.derive(SourceIdentity(provider: "gitlab", host: "gitlab.example:8443", remoteID: 7), path: "a/b")
                == "gitlab.example-8443-b-cd486683", "a port's colon is a -")
    }

    /// What follows from hashing the number: a rename keeps the id, a new
    /// repository at the old name gets another, and the same repository added
    /// again — after a Remove — gets the same one.
    @Test("a rename keeps the id; a new project at the old path gets another; added again, the same")
    func idFollowsTheRepository() throws {
        let a = SourceIdentity(provider: "gitlab", host: "gitlab.unicorns.place", remoteID: 48)
        let id = SourceID.derive(a, path: "tools/udeck-plugins")
        #expect(SourceID.isDerived(id, from: a), "after a rename to tools/renamed the stored id still checks")
        let b = SourceIdentity(provider: "gitlab", host: "gitlab.unicorns.place", remoteID: 49)
        let other = SourceID.derive(b, path: "tools/udeck-plugins")
        #expect(other != id, "a new project at the old path")
        #expect(!SourceID.isDerived(id, from: b) && !SourceID.isDerived(other, from: a))
        #expect(SourceID.derive(a, path: "tools/udeck-plugins") == id, "the same project added again")
        #expect(SourceID.derive(SourceIdentity(provider: "github", host: "gitlab.unicorns.place", remoteID: 48),
                                path: "tools/udeck-plugins") != id, "the provider is part of what is hashed")
        #expect(SourceID.derive(SourceIdentity(provider: "gitlab", host: "gitlab.com", remoteID: 48),
                                path: "tools/udeck-plugins") != id, "and the host")

        var list = SourceList()
        let added = try list.add(provider: "gitlab", host: "gitlab.unicorns.place", path: "tools/udeck-plugins",
                                 remoteID: 48, at: Self.at).get()
        let respelled = list.respell(added.id, path: "tools/renamed")
        #expect(respelled)
        #expect(list.source(added.id)?.path == "tools/renamed" && list.sources.count == 1)
        let data = try JSONFileStore<SourceList>.encoder.encode(list)
        let readBack = try SourceList.read(data).get()
        #expect(readBack == list, "a renamed source is no broken file: its id is still its own")
        #expect(list.remove(added.id) == readBack.sources.first)
        #expect(try list.add(provider: "gitlab", host: "gitlab.unicorns.place", path: "tools/udeck-plugins", remoteID: 48,
                             at: Self.at).get().id == id)
    }

    static let slugs: [(host: String, path: String, slug: String)] = [
        ("github.com", "someone/team-plugins", "github.com-team-plugins"),
        ("github.com", "o/Team__Plugins..x", "github.com-team-plugins..x"),
        ("gitlab.example", "group/sub/Проект", "gitlab.example"),
        ("gitlab.example", "g/p", "gitlab.example-p"),
        ("a-very-long-host-name.example.org", "group/a-very-long-project-name", "a-very-long-host-name.example.org-a-very"),
        ("a-very-long-host-name-of-thirty.example", "g/project", "a-very-long-host-name-of-thirty.example"),
        ("", "", "source"),
    ]

    @Test("the slug: lowercased, every character outside [a-z0-9.-] a -, runs of - one, at most 40", arguments: 0..<slugs.count)
    func slug(row: Int) {
        let (host, path, slug) = Self.slugs[row]
        let got = SourceID.slug(host: host, path: path)
        #expect(got == slug, "\(host) \(path)")
        #expect(got.count <= SourceID.slugLimit && !got.hasSuffix("-") && !got.contains("--"))
    }

    /// Any host and any path, of any characters and length: the id has the
    /// pattern, so it is never `official` and always a safe folder name.
    @Test("the pattern always holds", arguments: 0..<200)
    func patternHolds(seed: Int) {
        var random = SeededRandom(seed: UInt64(seed + 1))
        let alphabet = Array("abcXYZ019.-_/:@ é漢\u{202E}\u{200B}\n")
        func text() -> String { String((0..<random.next(upTo: 70)).map { _ in alphabet[random.next(upTo: alphabet.count)] }) }
        let identity = SourceIdentity(provider: ["github", "gitlab", "x"][random.next(upTo: 3)], host: text(),
                                      remoteID: random.next(upTo: 1_000_000_000) + 1)
        let id = SourceID.derive(identity, path: text())
        #expect(SourceID.isWellFormed(id), "\(id)")
        #expect(SourceID.isDerived(id, from: identity))
        #expect(id != InstalledPlugins.officialSource && !id.contains("/") && id != "." && id != "..")
        #expect(id.range(of: #"^[a-z0-9][a-z0-9.-]{0,40}-[0-9a-f]{8}$"#, options: .regularExpression) != nil, "\(id)")
    }

    static let shapes: [(String, Bool)] = [
        (operatorsID, true), (teamID, true), ("a-00000000", true),
        ("official", false), ("-a-00000000", false), (".a-00000000", false), ("a-0000000g", false), ("a-0000000", false),
        ("A-00000000", false), ("a_b-00000000", false), ("a00000000", false), ("a/b-00000000", false),
        (String(repeating: "a", count: 41) + "-00000000", true), (String(repeating: "a", count: 42) + "-00000000", false),
        ("a-ABCDEF00", false), ("", false), ("ä-00000000", false),
    ]

    @Test("what has the shape of an id", arguments: 0..<shapes.count)
    func shape(row: Int) {
        let (id, wellFormed) = Self.shapes[row]
        #expect(SourceID.isWellFormed(id) == wellFormed, "\(id)")
    }

    // MARK: - sources.json read

    @Test("the example reads whole: every field, the file's order, unknown keys ignored")
    func example() throws {
        let list = try Self.read(Self.example).get()
        #expect(list.version == 1 && list.skipped.isEmpty)
        #expect(list.sources.map(\.id) == [Self.operatorsID, Self.teamID], "the file's order is the order shown")
        let operators = try #require(list.source(Self.operatorsID))
        #expect(operators == OwnSource(id: Self.operatorsID, provider: "gitlab", host: "gitlab.unicorns.place",
                                       path: "tools/udeck-plugins", remoteID: 48, access: "token",
                                       trustedAt: ISO8601DateFormatter().date(from: "2026-10-20T10:01:00Z"),
                                       addedAt: ISO8601DateFormatter().date(from: "2026-10-20T10:00:00Z")))
        #expect(operators.address == RepositoryAddress(provider: "gitlab", host: "gitlab.unicorns.place", path: "tools/udeck-plugins"))
        #expect(list.source(Self.teamID)?.trustedAt == nil && list.source(Self.teamID)?.access == OwnSource.Access.none)
        let later = Self.list(Self.entry(extra: #", "signInClientID": "abc", "colour": {"x": [1, 2]}"#))
        #expect(try Self.read(later).get().sources.map(\.id) == [Self.teamID], "keys a later uDeck writes are ignored")
        #expect(try Self.read(#"{"sources": []}"#).get() == SourceList(), "no version: format 1")
        let signIn = Self.entry().replacingOccurrences(of: #""access": "none""#, with: #""access": "signIn""#)
        #expect(try Self.read(Self.list(signIn)).get().sources.first?.access == OwnSource.Access.signIn)
        let odd = Self.list(Self.entry().replacingOccurrences(of: #""access": "none""#, with: #""access": "oauth2""#)
            .replacingOccurrences(of: #""trustedAt": null"#, with: #""trustedAt": "yesterday""#))
        let read = try #require(try Self.read(odd).get().sources.first)
        #expect(read.access == "oauth2", "an access kind a later uDeck writes is kept as written")
        #expect(read.trustedAt == nil, "a trustedAt that is no date trusts nothing")
    }

    static let skips: [(entry: String, reason: SourceList.Skip, named: String?)] = [
        (#""a string""#, .notAnEntry, nil),
        (#"[1, 2]"#, .notAnEntry, nil),
        (entry(provider: "gitea"), .unknownProvider("gitea"), "github.com/someone/team-plugins"),
        (#"{"id": "x-00000000", "host": "github.com", "path": "o/r", "remoteID": 1}"#, .unknownProvider(nil), "github.com/o/r"),
        (entry(remoteID: #""123456789""#), .noRemoteID, "github.com/someone/team-plugins"),
        (entry(remoteID: "0"), .noRemoteID, "github.com/someone/team-plugins"),
        (entry(remoteID: "-5"), .noRemoteID, "github.com/someone/team-plugins"),
        (entry(remoteID: "1.5"), .noRemoteID, "github.com/someone/team-plugins"),
        (entry(remoteID: "null"), .noRemoteID, "github.com/someone/team-plugins"),
        (#"{"id": "x-00000000", "provider": "github", "path": "o/r", "remoteID": 1}"#, .address(.notALink), nil),
        (entry(path: "settings/tokens"), .address(.notARepository(page: "settings")), "github.com/settings/tokens"),
        (entry(path: "iillyyaa1997/udeck-plugins"), .address(.officialCatalogue), "github.com/iillyyaa1997/udeck-plugins"),
        (entry(provider: "gitlab", host: "github.com"), .address(.readsAsAnother("github.com/someone/team-plugins")),
         "github.com/someone/team-plugins"),
        (entry(provider: "github", host: "gitlab.com", path: "g/p"), .address(.readsAsAnother("gitlab.com/g/p")),
         "gitlab.com/g/p"),
        (entry(host: "GitHub.com"), .address(.readsAsAnother("github.com/someone/team-plugins")), "GitHub.com/someone/team-plugins"),
        (entry(path: "someone/team-plugins/tree/main"), .address(.readsAsAnother("github.com/someone/team-plugins")),
         "github.com/someone/team-plugins/tree/main"),
        (entry(provider: "gitlab", host: "gitlab.com", path: "single"), .address(.notAProject), "gitlab.com/single"),
        (entry(provider: "gitlab", host: "gitlab.com:443", path: "g/p"), .address(.readsAsAnother("gitlab.com/g/p")),
         "gitlab.com:443/g/p"),
        (entry(provider: "gitlab", host: "evil host", path: "g/p"), .address(.notALink), "evil host/g/p"),
    ]

    /// An entry this uDeck cannot use is left out, said with what it is and
    /// why, and the rest of the file is read — whatever its id says.
    @Test("an entry that cannot be used is skipped with its reason, and the rest reads", arguments: 0..<skips.count)
    func skipped(row: Int) throws {
        let (entry, reason, named) = Self.skips[row]
        let list = try Self.read(Self.list(entry, Self.entry(id: Self.operatorsID, provider: "gitlab",
                                                              host: "gitlab.unicorns.place", path: "tools/udeck-plugins",
                                                              remoteID: "48"))).get()
        #expect(list.skipped.map(\.reason) == [reason])
        #expect(list.skipped.first?.named == named && list.skipped.first?.position == 1)
        #expect(list.sources.map(\.id) == [Self.operatorsID])
    }

    /// A file a later uDeck wrote, written back by this one: the entries this
    /// one skips come back exactly as they were, in their places.
    @Test("an entry skipped is written back as it was, in its place")
    func skippedWrittenBack() throws {
        let later = Self.list(
            #"{"id": "gitea.example-p-00000000", "provider": "gitea", "host": "gitea.example", "path": "o/p", "remoteID": 3, "x": [true, null, 1.5, "é"]}"#,
            Self.entry())
        var list = try Self.read(later).get()
        let gitea = try #require(list.skipped.first)
        let added = try list.add(provider: "gitlab", host: "gitlab.unicorns.place", path: "tools/udeck-plugins",
                                 remoteID: 48, at: Self.at).get()
        let data = try JSONFileStore<SourceList>.encoder.encode(list)
        let again = try SourceList.read(data).get()
        #expect(again.skipped == [gitea], "the same entry, the same position")
        #expect(again.sources.map(\.id) == [Self.teamID, added.id])
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let entries = try #require(json["sources"] as? [[String: Any]])
        #expect(entries.first?["provider"] as? String == "gitea" && (entries.first?["x"] as? [Any])?.count == 4)
        #expect((entries.first?["x"] as? [Any])?.last as? String == "é")
    }

    static let broken: [(String, SourceList.Broken?)] = [
        ("not JSON", nil),
        ("[]", nil),
        (#"{"version": 1}"#, nil),
        (#"{"version": "1", "sources": []}"#, nil),
        (#"{"version": 1, "sources": {}}"#, nil),
        (list(entry(id: "github.com-team-plugins-00000000")),
         .idNotDerived(id: "github.com-team-plugins-00000000", named: "github.com/someone/team-plugins")),
        (list(entry(id: "official")), .idNotDerived(id: "official", named: "github.com/someone/team-plugins")),
        (list(#"{"provider": "github", "host": "github.com", "path": "someone/team-plugins", "remoteID": 123456789}"#),
         .idNotDerived(id: nil, named: "github.com/someone/team-plugins")),
        (list(entry(id: operatorsID)), .idNotDerived(id: operatorsID, named: "github.com/someone/team-plugins")),
        (list(entry(), entry()), .sameID(teamID)),
        (list(entry(), entry(id: "github.com-renamed-87a735c2", path: "someone/renamed")),
         .sameRepository("github.com/someone/team-plugins", "github.com/someone/renamed")),
        (list(entry(), entry(id: teamID, provider: "gitea")), .sameID(teamID)),
        // The hash is the repository's own, and the rest is no id: never a
        // folder's name or a token's key.
        (list(entry(id: "../../x-87a735c2")), .idNotDerived(id: "../../x-87a735c2", named: "github.com/someone/team-plugins")),
        (list(entry(id: "a/b-87a735c2")), .idNotDerived(id: "a/b-87a735c2", named: "github.com/someone/team-plugins")),
        (list(entry(id: "Official-87a735c2")), .idNotDerived(id: "Official-87a735c2", named: "github.com/someone/team-plugins")),
        (list(entry(id: "-x-87a735c2")), .idNotDerived(id: "-x-87a735c2", named: "github.com/someone/team-plugins")),
        (list(entry(id: "87a735c2")), .idNotDerived(id: "87a735c2", named: "github.com/someone/team-plugins")),
        // An entry left out is still the repository it says.
        (list(entry(), entry(id: "github.com-renamed-87a735c2", path: "someone/renamed/tree/main")),
         .sameRepository("github.com/someone/team-plugins", "github.com/someone/renamed/tree/main")),
        (list(entry(id: "github.com-x-87a735c2", host: "GitHub.com"), entry()),
         .sameRepository("GitHub.com/someone/team-plugins", "github.com/someone/team-plugins")),
        (list(entry(id: "a-87a735c2", path: "someone/team-plugins/tree/main"),
              entry(id: "b-87a735c2", path: "someone/team-plugins/tree/dev")),
         .sameRepository("github.com/someone/team-plugins/tree/main", "github.com/someone/team-plugins/tree/dev")),
    ]

    /// The four cases that make the whole file broken — an id that is not
    /// derived, two of one id, two of one repository, a file that does not
    /// parse. A skipped entry's id counts among the ids, and the repository
    /// it says among the repositories: two of one would share a folder and a
    /// token, whichever this uDeck reads.
    @Test("broken: an id not derived, a duplicate id, a duplicate identity, a file that does not parse", arguments: 0..<broken.count)
    func brokenFiles(row: Int) {
        let (text, wanted) = Self.broken[row]
        switch Self.read(text) {
        case .success(let list): Issue.record("\(text) read as \(list)")
        case .failure(let broken):
            if let wanted { #expect(broken == wanted, "\(text)") }
            else if case .unreadable = broken {} else { Issue.record("\(text) is \(broken), not unreadable") }
        }
    }

    /// What is not one repository twice: a provider this uDeck does not read
    /// says no repository it could judge, and an entry without a `remoteID`
    /// says none at all.
    @Test("not broken: a later provider's entry, or one without a remoteID, beside the same host and number")
    func notTheSameRepository() throws {
        let list = try Self.read(Self.list(Self.entry(id: "a-87a735c2", provider: "gitea"), Self.entry(),
                                           Self.entry(id: "b-87a735c2", remoteID: "null"),
                                           Self.entry(id: "c-87a735c2", remoteID: "0"))).get()
        #expect(list.sources.map(\.id) == [Self.teamID]
                && list.skipped.map(\.reason) == [.unknownProvider("gitea"), .noRemoteID, .noRemoteID])
        #expect(list.skipped.map(\.identity) == [nil, nil, nil]
                && list.skipped.map(\.id) == ["a-87a735c2", "b-87a735c2", "c-87a735c2"])
        let left = try Self.read(Self.list(Self.entry(id: "x-00000000", host: "GitHub.com"))).get().skipped
        #expect(left.map(\.identity) == [SourceIdentity(provider: "github", host: "github.com", remoteID: 123_456_789)])
    }

    // MARK: - sources.json written

    @Test("written: every field, trustedAt and addedAt null rather than left out, the file's order, read back the same")
    func written() throws {
        var list = SourceList()
        let first = try list.add(provider: "gitlab", host: "Gitlab.Unicorns.Place", path: "tools/udeck-plugins", remoteID: 48,
                                 access: OwnSource.Access.token, at: Self.at.addingTimeInterval(0.7)).get()
        let second = try list.add(provider: "github", host: "github.com", path: "someone/team-plugins", remoteID: 123_456_789,
                                  at: Self.at).get()
        #expect(first.id == Self.operatorsID && first.host == "gitlab.unicorns.place" && second.id == Self.teamID)
        #expect(first.addedAt == Self.at, "whole seconds, as every date in the files")
        let store = JSONFileStore<SourceList>(url: udeck.paths.sourcesFile)
        try store.save(list)
        let data = try Data(contentsOf: udeck.paths.sourcesFile)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["version"] as? Int == 1)
        let entries = try #require(json["sources"] as? [[String: Any]])
        #expect(entries.map { $0["id"] as? String } == [Self.operatorsID, Self.teamID])
        #expect(Set(entries[0].keys) == ["id", "provider", "host", "path", "remoteID", "access", "trustedAt", "addedAt"])
        #expect(entries[0]["trustedAt"] is NSNull && entries[1]["access"] as? String == "none")
        #expect(entries[0]["addedAt"] as? String == "2026-09-21T14:13:20Z" && entries[0]["remoteID"] as? Int == 48)
        #expect(try SourceList.read(data).get() == list)
        #expect(udeck.paths.sourcesFile.lastPathComponent == "sources.json"
                && udeck.paths.sourcesFile.deletingLastPathComponent() == udeck.paths.installedFile.deletingLastPathComponent())
    }

    @Test("Add: the same identity is already added, a colliding id refused, an address that would be skipped refused")
    func addRefusals() throws {
        var list = try Self.read(Self.example).get()
        let team = try #require(list.source(Self.teamID))
        #expect(list.add(provider: "github", host: "github.com", path: "someone/renamed", remoteID: 123_456_789, at: Self.at)
                == .failure(.alreadyAdded(team)), "already added compares provider, host and remoteID, not the path")
        // A collision of the hash and the slug together, made here by hand: an
        // entry whose identity is another's, under the id the new one derives.
        let colliding = OwnSource(id: SourceID.derive(SourceIdentity(provider: "github", host: "github.com", remoteID: 5),
                                                      path: "o/team-plugins"),
                                  provider: "github", host: "github.com", path: "x/team-plugins", remoteID: 6, addedAt: Self.at)
        var collided = SourceList(sources: [colliding])
        #expect(collided.add(provider: "github", host: "github.com", path: "o/team-plugins", remoteID: 5, at: Self.at)
                == .failure(.idTaken(by: colliding)))
        #expect(list.add(provider: "github", host: "github.com", path: "iillyyaa1997/udeck-plugins", remoteID: 1_393_324_153,
                         at: Self.at) == .failure(.address(.officialCatalogue)))
        #expect(list.add(provider: "gitlab", host: "github.com", path: "o/r", remoteID: 9, at: Self.at)
                == .failure(.address(.readsAsAnother("github.com/o/r"))))
        #expect(list.sources.count == 2, "nothing refused was added")
        #expect(list.remove("github.com-nothing-00000000") == nil && list.sources.count == 2)
        let respelled = list.respell(Self.teamID, path: "settings/x")
        #expect(!respelled, "a spelling that would be skipped is not written")
        #expect(list.source(Self.teamID)?.path == "someone/team-plugins")
    }

    static let skippedInTheWay: [(entry: String, why: String)] = [
        (entry(path: "someone/team-plugins/tree/main"), "its path edited by hand: the same repository, the same id"),
        (entry(id: "github.com-elsewhere-87a735c2", host: "GitHub.com"), "the same repository under another id"),
        (entry(provider: "gitea", host: "gitea.example", remoteID: "4"), "another repository with the id the new one derives"),
    ]

    /// An entry this uDeck leaves out is still in the file, and Add writes the
    /// file: the same repository or the same id beside it would make the file
    /// broken, and every source of the operator's would stop.
    @Test("Add: refused beside an entry left out that is the same repository or has the same id", arguments: 0..<skippedInTheWay.count)
    func addBesideASkippedEntry(row: Int) throws {
        let (entry, why) = Self.skippedInTheWay[row]
        var list = try Self.read(Self.list(entry)).get()
        let left = try #require(list.skipped.first, "\(why)")
        #expect(list.add(provider: "github", host: "github.com", path: "someone/team-plugins", remoteID: 123_456_789, at: Self.at)
                == .failure(.listedAsSkipped(left)), "\(why)")
        #expect(list.sources.isEmpty, "\(why)")
        let other = try list.add(provider: "github", host: "github.com", path: "someone/other", remoteID: 5, at: Self.at).get()
        let data = try JSONFileStore<SourceList>.encoder.encode(list)
        let again = try SourceList.read(data).get()
        #expect(again.sources == [other] && again.skipped == [left], "another repository is added beside it: \(why)")
    }

    /// Keys a later uDeck writes — R6's `signInClientID` among them — come back
    /// as they were whatever this uDeck adds or removes: of the file, and of
    /// each source; a source removed takes its own with it.
    @Test("keys this uDeck does not know are written back as they were, of the file and of each source")
    func laterKeysWrittenBack() throws {
        let operators = Self.entry(id: Self.operatorsID, provider: "gitlab", host: "gitlab.unicorns.place",
                                   path: "tools/udeck-plugins", remoteID: "48", extra: #", "signInClientID": "def-456""#)
        let later = #"{"version": 1, "writtenBy": {"uDeck": "0.9.0", "at": null}, "sources": ["#
            + Self.entry(extra: #", "signInClientID": "abc-123", "colour": {"x": [1, null, "é"]}"#) + ", " + operators + "]}"
        var list = try Self.read(later).get()
        #expect(list.sources.map(\.id) == [Self.teamID, Self.operatorsID])
        list.remove(Self.operatorsID)
        let back = try list.add(provider: "gitlab", host: "gitlab.unicorns.place", path: "tools/udeck-plugins", remoteID: 48,
                                at: Self.at).get()
        let added = try list.add(provider: "github", host: "github.com", path: "o/r", remoteID: 7, at: Self.at).get()
        let respelled = list.respell(Self.teamID, path: "someone/renamed")
        #expect(respelled)
        let data = try JSONFileStore<SourceList>.encoder.encode(list)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let writtenBy = try #require(json["writtenBy"] as? [String: Any], "the file's own")
        #expect(writtenBy["uDeck"] as? String == "0.9.0" && writtenBy["at"] is NSNull)
        let entries = try #require(json["sources"] as? [[String: Any]])
        #expect(entries.map { $0["id"] as? String } == [Self.teamID, back.id, added.id])
        #expect(entries[0]["signInClientID"] as? String == "abc-123" && entries[0]["path"] as? String == "someone/renamed")
        let colour = try #require(entries[0]["colour"] as? [String: Any])
        #expect((colour["x"] as? [Any])?.count == 3 && (colour["x"] as? [Any])?[1] is NSNull
                && (colour["x"] as? [Any])?.last as? String == "é")
        let known: Set<String> = ["id", "provider", "host", "path", "remoteID", "access", "trustedAt", "addedAt"]
        #expect(Set(entries[1].keys) == known && Set(entries[2].keys) == known,
                "a source removed and added again starts with none, as does a new one")
        #expect(!String(decoding: data, as: UTF8.self).contains("def-456"))
        #expect(try SourceList.read(data).get() == list, "read back the same")
    }

    /// A broken file is said, and never written over: no Add, no Remove, no
    /// respelling reaches the disk while it is broken.
    @Test("a broken or unparseable file is never overwritten",
          arguments: ["not JSON {", SourcesTests.list(SourcesTests.entry(), SourcesTests.entry())])
    func neverOverwritten(text: String) throws {
        let store = SourceStore(paths: udeck.paths)
        try FileManager.default.createDirectory(at: udeck.url, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: udeck.paths.sourcesFile)
        guard case .failure = store.load() else { Issue.record("\(text) loaded"); return }
        #expect(throws: SourceList.Broken.self) {
            try store.modify { list in
                _ = list.add(provider: "gitlab", host: "gitlab.unicorns.place", path: "tools/udeck-plugins", remoteID: 48,
                             at: Self.at)
            }
        }
        #expect(try Data(contentsOf: udeck.paths.sourcesFile) == Data(text.utf8), "byte for byte as it was")
    }

    @Test("no file is no source; the store adds, removes and writes what it read")
    func store() throws {
        let store = SourceStore(paths: udeck.paths)
        #expect(try store.load().get() == SourceList())
        let added = try store.modify { list in
            try list.add(provider: "gitlab", host: "gitlab.unicorns.place", path: "tools/udeck-plugins", remoteID: 48,
                         at: Self.at).get()
        }
        #expect(try store.load().get().sources == [added])
        try store.modify { list in list.remove(added.id) }
        #expect(try store.load().get().sources.isEmpty)
        try Data(Self.example.utf8).write(to: udeck.paths.sourcesFile)
        #expect(try store.load().get().sources.count == 2)
    }

    // MARK: - What a source is called

    static let names: [(passport: String?, shown: String, why: String)] = [
        ("Team plugins", "\u{2068}Team plugins\u{2069}", "its own name, isolated"),
        (nil, "gitlab.example/tools/x", "no passport read yet"),
        ("", "gitlab.example/tools/x", "an empty name"),
        ("  \u{200B}\u{202E}\u{2066}\n\u{2028}\u{2029}\t ", "gitlab.example/tools/x", "nothing left after cleaning"),
        ("uDeck plugins", "gitlab.example/tools/x", "the reserved name"),
        (" UDECK PLUGINS ", "gitlab.example/tools/x", "whatever its case, trimmed"),
        ("uDeck\u{200B} plugins", "gitlab.example/tools/x", "a zero-width space does not hide it"),
        ("Official Plugins", "gitlab.example/tools/x", "the official passport's name"),
        ("\u{202E}snigulp\u{202C} good", "\u{2068}snigulp good\u{2069}", "bidirectional controls taken out"),
        ("Team\u{0007} plugins\u{00AD}", "\u{2068}Team plugins\u{2069}", "a control and a soft hyphen"),
        ("Команда", "\u{2068}Команда\u{2069}", "letters of any script stay"),
        ("uDeck plugins!", "\u{2068}uDeck plugins!\u{2069}", "only an exact match is refused"),
    ]

    /// Cc, Cf, Zl and Zp taken out; FSI…PDI around what is left; the address
    /// instead of a name that is not one, or would pass for the official one.
    @Test("the name rule", arguments: 0..<names.count)
    func nameRule(row: Int) {
        let (passport, shown, why) = Self.names[row]
        let address = RepositoryAddress(provider: "gitlab", host: "gitlab.example", path: "tools/x")
        #expect(SourceName.shown(passport, address: address, officialName: " Official plugins ") == shown, "\(why)")
    }

    @Test("the official name is compared cleaned, and none is no name refused but uDeck plugins")
    func officialName() {
        let address = RepositoryAddress(path: "o/r")
        #expect(SourceName.shown("Mine", address: address, officialName: "\u{200B}mine") == "github.com/o/r")
        #expect(SourceName.shown("Mine", address: address, officialName: nil) == "\u{2068}Mine\u{2069}")
        #expect(SourceName.shown("udeck plugins", address: address, officialName: nil) == "github.com/o/r")
    }
}

/// A seeded generator, so that a failing case is the same case again.
struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next(upTo bound: Int) -> Int {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Int((state >> 33) % UInt64(max(bound, 1)))
    }
}
