import Foundation
import Testing
@testable import UDeckPluginFormat
import UDeckPluginFormatFixtures

/// Versions, the passport, and the two manifest fields repositories give a
/// meaning to — docs/plugin-repository.md, "Versions and compatibility".
@Suite("Plugin versions and the repository passport")
struct RepositoryFormatTests {

    // MARK: - The version grammar

    @Test("MAJOR.MINOR.PATCH reads as three numbers", arguments: [
        ("1.2.0", 1, 2, 0), ("0.1.0", 0, 1, 0), ("10.0.3", 10, 0, 3), ("0.0.0", 0, 0, 0),
        ("999999999.999999999.999999999", 999_999_999, 999_999_999, 999_999_999),
    ])
    func versionsParse(text: String, major: Int, minor: Int, patch: Int) {
        let version = SemanticVersion(text)
        #expect(version == SemanticVersion(major: major, minor: minor, patch: patch))
        #expect(version?.description == text)
    }

    @Test("what is not a version is refused", arguments: [
        "1.2", "v1.2.0", "1.2.0-beta", "01.2.0", "1.02.0", "1.2.00", "", "1..0", "1.2.0.4", " 1.2.0",
        "1.2.0 ", "1000000000.0.0", "-1.2.0", "+1.2.0", "1.2.x", "١.٢.٠", "1.2.0\n", "1,2,0",
    ])
    func versionsRefused(text: String) {
        #expect(SemanticVersion(text) == nil, "\(text.debugDescription) was read as a version")
    }

    @Test("versions compare part by part, as numbers")
    func versionsOrder() throws {
        func v(_ text: String) throws -> SemanticVersion { try #require(SemanticVersion(text)) }
        #expect(try v("1.10.0") > v("1.9.0"))
        #expect(try v("2.0.0") > v("1.10.0"))
        #expect(try v("1.0.10") > v("1.0.9"))
        #expect(try v("0.9.9") < v("1.0.0"))
        #expect(try v("1.2.0") == v("1.2.0"))
        #expect(try !(v("1.2.0") < v("1.2.0")))
    }

    // MARK: - The passport

    @Test("a passport reads its three fields and ignores the rest")
    func passportReads() throws {
        let data = Data(#"{"format":1,"name":"uDeck plugins","description":"Read first.","extra":true}"#.utf8)
        let passport = try RepositoryPassport.read(data).get()
        #expect(passport == RepositoryPassport(format: 1, name: "uDeck plugins", description: "Read first."))
        let bare = try RepositoryPassport.read(Data(#"{"format":1,"name":"x"}"#.utf8)).get()
        #expect(bare.description == nil)
    }

    @Test("no passport, or one that is not JSON, is not a plugin repository")
    func passportMissing() {
        #expect(RepositoryPassport.read(nil) == .failure(.missing))
        #expect(RepositoryPassport.read(Data("not json".utf8)) == .failure(.missing))
        #expect(RepositoryPassport.read(Data("[1]".utf8)) == .failure(.missing))
    }

    @Test("a format from the future is refused, naming it")
    func passportFromTheFuture() {
        let data = Data(#"{"format":2,"name":"future"}"#.utf8)
        #expect(RepositoryPassport.read(data) == .failure(.futureFormat(declared: 2)))
    }

    @Test("a passport with a field of the wrong kind says which")
    func passportInvalid() {
        for text in [#"{"name":"x"}"#, #"{"format":"1","name":"x"}"#, #"{"format":true,"name":"x"}"#,
                     #"{"format":0,"name":"x"}"#, #"{"format":1}"#, #"{"format":1,"name":""}"#,
                     #"{"format":1,"name":"\#(String(repeating: "n", count: 65))"}"#,
                     #"{"format":1,"name":"x","description":5}"#] {
            guard case .failure(.invalid) = RepositoryPassport.read(Data(text.utf8)) else {
                Issue.record("\(text) was not refused as invalid: \(RepositoryPassport.read(Data(text.utf8)))")
                continue
            }
        }
    }

    // MARK: - minUDeck and the version note

    let discoveryAt060 = PluginDiscovery(searchPath: ["/bin"], udeck: SemanticVersion("0.6.0"))

    func manifest(version: String = "1.0.0", minUDeck: String? = nil, api: Int = 1) -> String {
        FakeRepository.manifest(id: "p", version: version, api: api, minUDeck: minUDeck, run: "./run.sh")
    }

    @Test("minUDeck is read when it is there, and absent means any uDeck")
    func minUDeckDecodes() throws {
        let with = try JSONDecoder().decode(PluginManifest.self, from: Data(manifest(minUDeck: "0.6.0").utf8))
        #expect(with.minUDeck == "0.6.0")
        let without = try JSONDecoder().decode(PluginManifest.self, from: Data(manifest().utf8))
        #expect(without.minUDeck == nil)
        #expect(without.problems(udeck: SemanticVersion("0.1.0")).isEmpty)
    }

    /// The `api: 1` promise: a field an older uDeck ignored cannot become a
    /// reason to refuse a manifest it loaded.
    @Test("a minUDeck that is not text still loads the manifest")
    func minUDeckOfTheWrongKind() throws {
        let text = #"{ "id": "p", "name": "p", "version": "1.0.0", "api": 1, "kind": "poll", "run": ["./run.sh"], "interval": 60, "timeout": 2, "minUDeck": 5 }"#
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: Data(text.utf8))
        #expect(manifest.minUDeck == "5")
    }

    @Test("a folder whose minUDeck is newer than this uDeck is refused, naming both")
    func minUDeckRefusesAFolder() {
        let temp = TemporaryDirectory()
        temp.writePlugin(folder: "p", manifest: manifest(minUDeck: "0.8.0"),
                         script: (name: "run.sh", body: "#!/bin/sh\n", executable: true))
        let found = discoveryAt060.scan(temp.plugins)[0]
        #expect(!found.isUsable)
        #expect(found.problems.contains(.manifest(.needsNewerUDeck(required: SemanticVersion("0.8.0")!,
                                                                   running: SemanticVersion("0.6.0")!))))
        #expect(found.problems.map(\.description).contains("needs uDeck 0.8.0 or later; this is 0.6.0"))
    }

    @Test("a minUDeck this uDeck meets, or one lower, is no constraint")
    func minUDeckMet() {
        for required in ["0.6.0", "0.5.9", "0.0.1"] {
            let temp = TemporaryDirectory()
            temp.writePlugin(folder: "p", manifest: manifest(minUDeck: required),
                             script: (name: "run.sh", body: "#!/bin/sh\n", executable: true))
            let found = discoveryAt060.scan(temp.plugins)[0]
            #expect(found.isUsable, "minUDeck \(required) refused on 0.6.0: \(found.problems)")
        }
    }

    @Test("a uDeck whose own version does not parse skips the comparison")
    func runningVersionUnparsable() {
        let temp = TemporaryDirectory()
        temp.writePlugin(folder: "p", manifest: manifest(minUDeck: "99.0.0"),
                         script: (name: "run.sh", body: "#!/bin/sh\n", executable: true))
        let found = PluginDiscovery(searchPath: ["/bin"], udeck: nil).scan(temp.plugins)[0]
        #expect(found.isUsable)
    }

    @Test("a version that is not MAJOR.MINOR.PATCH is a note, and the plugin runs")
    func versionNote() {
        let temp = TemporaryDirectory()
        temp.writePlugin(folder: "p", manifest: manifest(version: "draft"),
                         script: (name: "run.sh", body: "#!/bin/sh\n", executable: true))
        let found = discoveryAt060.scan(temp.plugins)[0]
        #expect(found.isUsable)
        #expect(found.problems == [.versionNotComparable("draft")])
        #expect(found.problems[0].description
                == "version \"draft\" is not MAJOR.MINOR.PATCH — fine for a folder of your own, required to publish it in a repository")
    }

    @Test("a minUDeck that is not a version is a note, never a refusal, for a folder of your own")
    func minUDeckNote() {
        let temp = TemporaryDirectory()
        temp.writePlugin(folder: "p", manifest: manifest(minUDeck: "soon"),
                         script: (name: "run.sh", body: "#!/bin/sh\n", executable: true))
        let found = discoveryAt060.scan(temp.plugins)[0]
        #expect(found.isUsable)
        #expect(found.problems == [.minUDeckNotComparable("soon")])
    }

    @Test("an api this uDeck does not speak still refuses a folder, as it did")
    func apiStillRefuses() {
        let temp = TemporaryDirectory()
        temp.writePlugin(folder: "p", manifest: manifest(api: 2),
                         script: (name: "run.sh", body: "#!/bin/sh\n", executable: true))
        let found = discoveryAt060.scan(temp.plugins)[0]
        #expect(!found.isUsable)
        #expect(found.problems.contains(.manifest(.unsupportedAPI(declared: 2, supported: 1 ... 1))))
    }
}
