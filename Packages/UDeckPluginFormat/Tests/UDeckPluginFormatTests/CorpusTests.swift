import Foundation
import Testing
@testable import UDeckPluginFormat
import UDeckPluginFormatFixtures

/// The corpus of repositories the official repository's Python check was run
/// on (`Corpus/`), and the replay of it that the Swift check has to pass.
///
/// Two halves. That the corpus is sound — it reads, every content is what its
/// id says, every repository in it can be built again exactly as the Python
/// check saw it, every rule is both broken and kept somewhere in it — is tested
/// now. That the Swift check says what the corpus says is marked as a known
/// issue until the rules are ported (stage 2, wave B): `withKnownIssue` then
/// fails loudly, which is the reminder to take the mark off.
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

        let diverging = corpus.cases.filter { $0.divergence != nil }.compactMap(\.probe).sorted()
        #expect(diverging == ["P05", "P10"])

        // P05: Python normalises sub/../../sample/run.sh and passes it; uDeck
        // refuses a path that leaves the folder on the way.
        let climbing = try #require(probes["P05"])
        #expect(climbing.expected.findings.isEmpty)
        #expect(climbing.findingsForSwift == ["error 5 plugins/sample/manifest.json"])

        // P10: Python calls restart a field uDeck ignores; uDeck decodes it,
        // and a partial one does not decode at all.
        let restart = try #require(probes["P10"])
        #expect(restart.expected.findings.map(\.key) == ["error 12 plugins/sample/manifest.json"])
        #expect(restart.findingsForSwift == ["error 3 plugins/sample/manifest.json"])
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(RestartPolicy.self, from: Data(#"{"mode": "never"}"#.utf8))
        }
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

    @Test("the Swift check reports what the corpus says, in every case")
    func replay() throws {
        let corpus = try corpus()
        withKnownIssue("the repository rules are ported to Swift in stage 2, wave B") {
            for item in corpus.cases {
                let found = try CorpusReplay.findings(of: item, in: nil)
                #expect(found == item.findingsForSwift, "\(item.name)")
            }
        }
    }
}
