import Foundation
import Testing
@testable import UDeckCore
import UDeckPluginFormatFixtures

/// The previous copy names its source (`PreviousCopy.sourceID`, 0.8.0): Back
/// to finds a renamed source by its id, and never a newcomer at a removed
/// source's old address. And Back to from another line of history puts the
/// copy back as it was — pinned only if it was — so a verified copy returned
/// to goes on updating by itself (`PreviousCopy.pinned`).
extension ShownPlaceTests {
    /// Back to, through its warning when it gives one.
    func backTo(_ records: InstalledPlugins, sources: [OwnSource]) -> ShownPlace.Step {
        let step = ShownPlace.backToPrevious("uptime", source: .official, in: paths, installed: records, shown: nil,
                                             sources: sources)
        guard case .ask(let place) = step else { return step }
        return ShownPlace.backToPrevious("uptime", source: .official, in: paths, installed: records, shown: place,
                                         sources: sources)
    }

    func officialUptime() async throws -> InstalledPlugins {
        let repository = FakeRepository.withUptime()
        let base = installer(repository, trash: TestTrash(in: udeck.url))
        try await install("uptime", from: repository, with: base)
        return try base.loadRecords()
    }

    static let previousCommit = String(repeating: "9", count: 40)
    static let previousTree = String(repeating: "7", count: 40)

    @Test("Back to after its source was renamed: the previous copy names the source, and comes from its address now")
    func backToARenamedSource() async throws {
        var records = try await officialUptime()
        let renamed = OwnSource(id: Self.teamID, provider: "gitlab", host: "gitlab.example", path: "tools/renamed-plugins",
                                remoteID: 48, addedAt: nil)
        records.plugins["uptime"]?.previous = PreviousCopy(ref: .defaultBranch("main"), commit: Self.previousCommit,
                                                           tree: Self.previousTree, version: "0.9.0", repository: Self.team,
                                                           sourceID: Self.teamID)
        #expect(backTo(records, sources: [renamed])
                == .atCommit(.earlier, commit: Self.previousCommit, version: "0.9.0",
                             from: PluginOrigin(repository: renamed.address, ref: .defaultBranch("main"), source: Self.teamID),
                             pinned: false))
        // Recorded before 0.8.0, with no source named, the copy's old address is no source's any more.
        records.plugins["uptime"]?.previous?.sourceID = nil
        #expect(backTo(records, sources: [renamed]) == .nothing)
    }

    @Test("a source removed, another added at its old address: Back to does not take the copy from the newcomer")
    func aNewcomerAtTheOldAddress() async throws {
        var records = try await officialUptime()
        let newcomer = OwnSource(id: "gitlab.example-team-plugins-99999999", provider: "gitlab", host: "gitlab.example",
                                 path: "tools/team-plugins", remoteID: 99, addedAt: nil)
        records.plugins["uptime"]?.previous = PreviousCopy(ref: .defaultBranch("main"), commit: Self.previousCommit,
                                                           tree: Self.previousTree, version: "0.9.0", repository: Self.team,
                                                           sourceID: Self.teamID)
        #expect(backTo(records, sources: [newcomer]) == .nothing, "the source it was a copy of is no longer added")
        // Recorded before 0.8.0, the old address alone decided — and named the newcomer.
        records.plugins["uptime"]?.previous?.sourceID = nil
        guard case .atCommit(_, _, _, let from, _) = backTo(records, sources: [newcomer]) else {
            Issue.record("a previous copy with no source named is matched by its address"); return
        }
        #expect(from.source == newcomer.id)
    }

    @Test("the official source's previous copy, named so, comes from where it came — a fork's branch as well")
    func officialNamed() async throws {
        var records = try await officialUptime()
        let fork = RepositoryAddress(path: "someone/udeck-plugins")
        records.plugins["uptime"]?.previous = PreviousCopy(ref: .branch("x"), commit: Self.previousCommit,
                                                           tree: Self.previousTree, version: "0.9.0", repository: fork,
                                                           sourceID: InstalledPlugins.officialSource)
        let previous = try #require(records.plugins["uptime"]?.previous)
        let record = try #require(records.plugins["uptime"])
        #expect(previous.source(record: record, official: .official, sources: [])
                == .source(PluginOrigin(repository: fork, ref: .branch("x"))))
        // Even with a source of one's own added at the fork's address: the copy names the official source.
        let atTheFork = OwnSource(id: "github.com-udeck-plugins-12345678", provider: "github", host: "github.com",
                                  path: "someone/udeck-plugins", remoteID: 5, addedAt: nil)
        #expect(previous.source(record: record, official: .official, sources: [atTheFork])
                == .source(PluginOrigin(repository: fork, ref: .branch("x"))))
    }

    // MARK: - installed.json

    /// `PreviousCopy` as 0.7.0 declared it (43db3a8): its own keys, and every
    /// other one skipped — what 0.7.0 reads an 0.8.0 record's previous copy as.
    struct PreviousCopy070: Codable, Equatable {
        var ref: PluginRef
        var commit: String
        var tree: String
        var version: String
        var repository: RepositoryAddress?
    }

    @Test("the previous copy's source and pin are written as source and pinned, only when there is something to say — and 0.7.0 reads past them")
    func previousOnDisk() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var record = InstalledRecord(source: Self.teamID, repository: Self.team, ref: .defaultBranch("main"),
                                     commit: Self.previousCommit, tree: Self.previousTree, version: "0.9.0",
                                     installedAt: Date(timeIntervalSince1970: 1_790_000_000), pinned: true,
                                     verification: PluginVerification(status: .unverified, by: nil, checkedAgainst: nil,
                                                                      checkedAt: Date(timeIntervalSince1970: 1_790_000_000)),
                                     previous: nil)
        let pinned = String(decoding: try encoder.encode(record.asPrevious), as: UTF8.self)
        #expect(pinned.contains(#""source":"\#(Self.teamID)""#) && pinned.contains(#""pinned":true"#), "\(pinned)")
        record.pinned = false
        record.source = InstalledPlugins.officialSource
        let plain = String(decoding: try encoder.encode(record.asPrevious), as: UTF8.self)
        #expect(plain.contains(#""source":"official""#) && !plain.contains("pinned"), "\(plain)")
        let legacy = PreviousCopy(ref: .defaultBranch("main"), commit: Self.previousCommit, tree: Self.previousTree,
                                  version: "0.9.0")
        let old = String(decoding: try encoder.encode(legacy), as: UTF8.self)
        #expect(!old.contains("source") && !old.contains("pinned") && !old.contains("repository"), "\(old)")

        // Read back as written, and as 0.7.0 reads it: the same copy, the new keys skipped.
        let written = try encoder.encode(InstalledRecord.withPrevious(record))
        let back = try JSONDecoder().decode(PreviousCopy.self, from: try encoder.encode(record.asPrevious))
        #expect(back == record.asPrevious)
        let as070 = try JSONDecoder().decode(PreviousCopy070.self, from: try encoder.encode(record.asPrevious))
        #expect(as070 == PreviousCopy070(ref: .defaultBranch("main"), commit: Self.previousCommit, tree: Self.previousTree,
                                         version: "0.9.0", repository: Self.team))
        #expect(!written.isEmpty)
    }

    // MARK: - The pin

    @Test("Back to along the copy's own line pins it; from another line it comes back pinned only if it was")
    func theLineDecidesThePin() async throws {
        var records = try await officialUptime()
        // An update undone: the previous copy the same line's.
        records.plugins["uptime"]?.previous = PreviousCopy(ref: .defaultBranch("main"), commit: Self.previousCommit,
                                                           tree: Self.previousTree, version: "0.9.0",
                                                           repository: .official, sourceID: InstalledPlugins.officialSource)
        guard case .atCommit(.earlier, _, _, _, let along) = backTo(records, sources: []) else {
            Issue.record("Back to along the line"); return
        }
        #expect(along == nil, "the operation's own: pinned")
        // A pull request's copy, back to the verified copy that was not pinned — and to one that was.
        records.plugins["uptime"]?.ref = .pullRequest(3)
        for (was, comes) in [(nil, false), (true, true)] as [(Bool?, Bool)] {
            records.plugins["uptime"]?.previous?.pinned = was
            guard case .atCommit(.earlier, _, _, _, let pinned) = backTo(records, sources: []) else {
                Issue.record("Back to from a pull request's copy"); return
            }
            #expect(pinned == comes, "previous pinned \(String(describing: was))")
        }
    }

    @Test("the installer writes the pin the request says, an earlier version's own when it says none")
    func theInstallerWritesThePin() async throws {
        let first = FakeRepository.withUptime(version: "1.0.0")
        try await install("uptime", from: first, with: installer(first, trash: TestTrash(in: udeck.url)))
        var second = FakeRepository.withUptime(version: "1.1.0")
        second.commit = String(repeating: "d", count: 40)
        for (asked, written) in [(nil, true), (false, false), (true, true)] as [(Bool?, Bool)] {
            let installer = installer(second, trash: TestTrash(in: udeck.url))
            let record = try installer.commit(try await installer.stage(InstallRequest(
                operation: .earlier, id: PluginIdentifier(rawValue: "uptime")!, sourceRepository: .official,
                repository: .official, ref: PluginRef(name: "main"), commit: second.commit, folder: second.plugin("uptime"),
                version: "1.1.0", headCommit: second.commit, pinned: asked)))
            #expect(record.pinned == written, "asked \(String(describing: asked))")
            #expect(record.previous?.sourceID == InstalledPlugins.officialSource)
        }
    }
}

extension InstalledRecord {
    /// A record with `record`'s own copy as its previous one.
    static func withPrevious(_ record: InstalledRecord) -> InstalledRecord {
        var copy = record
        copy.previous = record.asPrevious
        return copy
    }
}
