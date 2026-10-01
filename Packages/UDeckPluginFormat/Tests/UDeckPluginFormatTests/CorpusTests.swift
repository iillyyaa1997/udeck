import Foundation
import Testing
@testable import UDeckPluginFormat
import UDeckPluginFormatFixtures

/// The corpus of repositories the official repository's Python check was run
/// on (`Corpus/`), and the replay of it that the Swift check has to pass.
///
/// Two halves. That the corpus is sound — it reads, every content is what its
/// id says, every repository in it can be built again exactly as the Python
/// check saw it, every rule is both broken and kept somewhere in it. And that
/// the Swift check says what the corpus says, case by case: level, rule and
/// path, and the exit status — where the Python check was wrong, as the
/// case's divergence says. No finding it makes, in any layer, names a type of
/// Swift's.
@Suite("The corpus of the Python check")
struct CorpusTests {
    func corpus() throws -> Corpus { try #require(Corpus.loaded, "Corpus/corpus.json did not load: \(loadError())") }

    func loadError() -> String {
        do { _ = try Corpus.load(); return "it loads now" } catch { return "\(error)" }
    }

    @Test("the corpus reads whole, and says which check it froze")
    func readsWhole() throws {
        let corpus = try corpus()
        #expect(corpus.source.repository == "https://github.com/iillyyaa1997/udeck-plugins")
        #expect(corpus.source.commit.hasPrefix("7403916"))
        #expect(corpus.cases.count >= 250, "\(corpus.cases.count) cases")
        #expect(Set(corpus.cases.map(\.name)).count == corpus.cases.count, "two cases share a name")
        #expect(!corpus.base.isEmpty)
        for name in corpus.blobs {
            #expect(FileManager.default.fileExists(atPath: Corpus.folder.appendingPathComponent("blobs/\(name)").path))
        }
    }

    /// Stored once under the id git gives it, so the id is a checksum: a content
    /// the generator wrote wrongly, or this side reads wrongly, does not hash
    /// to its name.
    @Test("every content in the corpus is the blob its id names")
    func contentsAreTheirIDs() throws {
        let corpus = try corpus()
        #expect(corpus.contents.count > 100)
        for (id, _) in corpus.contents {
            #expect(GitHash.blob(try corpus.bytes(id)) == id, "content \(id)")
        }
        // Everything a case points at is there.
        for item in corpus.cases {
            for commit in item.repository?.commits ?? [] {
                for (path, entry) in corpus.files(of: commit) where entry.commit == nil {
                    #expect(entry.blob.map { corpus.contents[$0] != nil } == true, "\(item.name): \(path)")
                }
            }
        }
    }

    @Test("every rule is broken by some case and kept by another")
    func everyRuleBothWays() throws {
        let corpus = try corpus()
        var tally = Dictionary(uniqueKeysWithValues: Corpus.rules.map { ($0, Corpus.Tally(breaks: 0, passes: 0)) })
        for item in corpus.cases {
            let reported = Set(item.expected.findings.map(\.rule))
            for rule in reported where tally[rule] != nil { tally[rule]!.breaks += 1 }
            if let rule = item.rule, tally[rule] != nil, !reported.contains(rule), item.expected.couldNotCheck == nil {
                tally[rule]!.passes += 1
            }
        }
        for rule in Corpus.rules {
            let counts = try #require(tally[rule])
            #expect(counts.breaks >= 1, "no case breaks rule \(rule)")
            #expect(counts.passes >= 1, "no case about rule \(rule) keeps it")
        }
        #expect(tally == corpus.rules, "the tally make-corpus.py wrote is not the cases' own")
    }

    @Test("the rules map's probes are all there, and the two places Python is wrong say what Swift must do")
    func probesAndDivergences() throws {
        let corpus = try corpus()
        let probes = Dictionary(uniqueKeysWithValues: corpus.cases.compactMap { item in item.probe.map { ($0, item) } })
        for number in 1 ... 18 {
            #expect(probes[String(format: "P%02d", number)] != nil, "P\(number) is missing")
        }
        for acceptance in ["A02", "A06", "A10", "A15"] {
            #expect(probes[acceptance]?.expected.findings.isEmpty == true, "\(acceptance) is missing or not clean")
        }

        let diverging = corpus.cases.filter { $0.divergence != nil }.map { $0.probe ?? $0.name }.sorted()
        #expect(diverging == ["P05", "P10", Self.secondRestart])

        // P05: Python normalises sub/../../sample/run.sh and passes it; uDeck
        // refuses a path that leaves the folder on the way.
        let climbing = try #require(probes["P05"])
        #expect(climbing.expected.findings.isEmpty)
        #expect(climbing.findingsForSwift == ["error 5 plugins/sample/manifest.json"])

        // P10: Python calls restart a field uDeck ignores; uDeck decodes it,
        // and a partial one does not decode at all. Strictly, restart is a
        // field the contract does not define as well.
        let restart = try #require(probes["P10"])
        #expect(restart.expected.findings.map(\.key) == ["error 12 plugins/sample/manifest.json"])
        #expect(restart.findingsForSwift == ["error 3 plugins/sample/manifest.json", "error 12 plugins/sample/manifest.json"])
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(RestartPolicy.self, from: Data(#"{"mode": "never"}"#.utf8))
        }
    }

    /// The Python check's own test of `restart` builds P10's manifest again,
    /// and carries P10's divergence: the same JSON, the same answer.
    static let secondRestart = "Rule12OnlyWhatTheContractDefines.test_in_the_manifest [restart, which the contract does not describe]"

    @Test("the Python check's own test of restart diverges as P10 does, with P10's manifest")
    func secondRestartIsP10() throws {
        let corpus = try corpus()
        func manifest(_ item: Corpus.Case?) throws -> StrictJSON.Value? {
            guard let blob = item?.repository?.commits.last?.set["plugins/sample/manifest.json"]?.blob else { return nil }
            return StrictJSON.parse(Array(try corpus.bytes(blob))).value
        }
        let p10 = try #require(corpus.cases.first { $0.probe == "P10" })
        let second = try #require(corpus.cases.first { $0.name == Self.secondRestart })
        let p10Manifest = try #require(try manifest(p10))
        #expect(try manifest(second) == p10Manifest, "not P10's manifest")
        #expect(second.expected.findings.map(\.key) == p10.expected.findings.map(\.key))
        #expect(second.findingsForSwift == p10.findingsForSwift)
        #expect(second.divergence?.swift == p10.divergence?.swift)
    }

    /// The commit ids are the proof: git's id for a commit covers every byte of
    /// every file, every mode and name, the message and the parent, so the same
    /// id means the same repository the Python check read.
    @Test("each case's repository builds again exactly as the Python check saw it",
          arguments: Corpus.loaded?.cases ?? [])
    func builds(_ item: Corpus.Case) throws {
        let corpus = try corpus()
        let temp = TemporaryDirectory()
        let built = try CorpusGit.build(item, of: corpus, in: temp.url)
        guard let repository = item.repository else {
            #expect(built == nil)
            #expect(item.expected.exit == 2, "a folder that is not a repository cannot be checked")
            return
        }
        let ids = try #require(built).commits
        #expect(ids == repository.commits.map(\.sha))
        for (path, _) in item.worktree ?? [:] {
            #expect(FileManager.default.fileExists(atPath: temp.url.appendingPathComponent("repository/\(path)").path))
        }
    }

    /// Level, rule and path, exactly — and for P05 and P10 what the corpus
    /// says the Swift check must say instead. The exit status too.
    @Test("the Swift check reports what the corpus says, in every case", arguments: Corpus.loaded?.cases ?? [])
    func replay(_ item: Corpus.Case) throws {
        let corpus = try corpus()
        let temp = TemporaryDirectory()
        let outcome = try CorpusReplay.run(item, of: corpus, in: temp.url)
        #expect(outcome == CorpusReplay.expected(item))
        Self.inWords(outcome, item)
    }

    /// The findings the corpus cannot hold would be of the new rules only, and
    /// named: there are none today, and a replay that grew a list of
    /// exceptions would prove nothing.
    @Test("the Swift check adds nothing to the corpus")
    func newRulesOnly() throws {
        let corpus = try corpus()
        let names = Set(corpus.cases.map(\.name))
        for (name, findings) in CorpusReplay.newRules {
            #expect(names.contains(name), "no case \(name)")
            #expect(findings.allSatisfy { $0.split(separator: " ")[1] == Substring(CheckRule.minimumUDeck) })
        }
        #expect(CorpusReplay.newRules.isEmpty)
    }

    /// The strict check is the installable one and more: whatever uDeck would
    /// refuse, strict refuses too, in every case of the corpus.
    @Test("strict never passes what uDeck would refuse", arguments: Corpus.loaded?.cases ?? [])
    func strictHoldsWhatInstallableHolds(_ item: Corpus.Case) throws {
        let corpus = try corpus()
        // Each folder held for as long as its check runs: `TemporaryDirectory().url`
        // would let the folder go — and remove it — before the check made it
        // again, leaving it behind for nobody to take away.
        let first = TemporaryDirectory()
        let second = TemporaryDirectory()
        let installable = try CorpusReplay.run(item, of: corpus, in: first.url, mode: .installable)
        let strict = try CorpusReplay.run(item, of: corpus, in: second.url, mode: .strict)
        withExtendedLifetime((first, second)) {}
        if installable.exit != 0 { #expect(strict.exit == installable.exit, "installable \(installable), strict \(strict)") }
        Self.inWords(installable, item)
        Self.inWords(strict, item)
    }

    /// What a finding says is for an author: the names of the fields and the
    /// kinds of JSON values, never the Swift types a decoder was reading into.
    static let swiftWords = ["Dictionary<", "Array<", "Optional", "Swift.", "CodingKeys", "DecodingError", "Index ",
                             "Cannot initialize", "_JSONKey", "not representable", "a Double", "(root)"]

    static func inWords(_ outcome: CorpusReplay.Outcome, _ item: Corpus.Case) {
        for message in outcome.messages {
            for word in swiftWords where message.contains(word) {
                Issue.record("\(item.name): \"\(message)\" says \"\(word)\"")
            }
        }
    }
}
