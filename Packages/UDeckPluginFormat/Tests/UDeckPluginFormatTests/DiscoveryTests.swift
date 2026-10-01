import Foundation
import Testing
@testable import UDeckPluginFormat
import UDeckPluginFormatFixtures

@Suite("Plugin discovery")
struct DiscoveryTests {
    let searchPath = ["/usr/bin", "/bin"]

    var discovery: PluginDiscovery { PluginDiscovery(searchPath: searchPath) }

    let goodManifest = """
    { "id": "good", "name": "Good", "version": "1.0.0", "api": 1, "kind": "poll",
      "run": ["./run.sh"], "interval": 5, "timeout": 2 }
    """

    @Test("a missing plugins directory is an empty result, not a failure")
    func missingDirectoryIsEmpty() {
        let temp = TemporaryDirectory()
        #expect(discovery.scan(temp.plugins).isEmpty)
    }

    @Test("a well-formed plugin is found and usable")
    func findsAGoodPlugin() {
        let temp = TemporaryDirectory()
        temp.writePlugin(folder: "good", manifest: goodManifest,
                         script: (name: "run.sh", body: "#!/bin/sh\necho '{}'\n", executable: true))
        let found = discovery.scan(temp.plugins)
        #expect(found.count == 1)
        #expect(found[0].isUsable)
        #expect(found[0].manifest?.id.rawValue == "good")
        #expect(found[0].executable?.lastPathComponent == "run.sh")
    }

    /// A plugin that simply fails to appear is a support question. One that
    /// appears with the reason next to it is a five-second fix.
    @Test("a folder with no manifest is still listed, with the reason")
    func brokenPluginIsStillListed() {
        let temp = TemporaryDirectory()
        let directory = temp.url.appendingPathComponent("plugins/empty", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let found = discovery.scan(temp.plugins)
        #expect(found.count == 1)
        #expect(found[0].problems == [.missingManifest])
        #expect(!found[0].isUsable)
    }

    @Test("a malformed manifest names the field that is wrong")
    func malformedManifestNamesTheField() {
        let temp = TemporaryDirectory()
        temp.writePlugin(folder: "bad", manifest: """
        { "id": "bad", "name": "Bad", "version": "1.0.0", "api": 1, "kind": "poll" }
        """)
        let found = discovery.scan(temp.plugins)
        guard case .malformedManifest(let detail) = found[0].problems.first else {
            Issue.record("expected a malformed manifest, got \(found[0].problems)"); return
        }
        #expect(detail.contains("run"))
    }

    /// A manifest that is JSON and not an object is named as the manifest,
    /// not as a field with no name.
    @Test("a manifest that is a list is said to be one, in words")
    func manifestOfTheWrongKind() {
        let temp = TemporaryDirectory()
        temp.writePlugin(folder: "listed", manifest: "[1, 2]")
        #expect(discovery.scan(temp.plugins).first?.problems == [.malformedManifest("the manifest must be an object, not a list")])
        #expect(discovery.scan(temp.plugins).first?.problems.first?.description
                == "manifest.json is not valid: the manifest must be an object, not a list")
    }

    @Test("the manifest id must match the folder it sits in")
    func idMustMatchFolder() {
        let temp = TemporaryDirectory()
        temp.writePlugin(folder: "elsewhere", manifest: goodManifest,
                         script: (name: "run.sh", body: "#!/bin/sh\n", executable: true))
        let found = discovery.scan(temp.plugins)
        #expect(found[0].problems.contains(.identifierMismatch(declared: "good", folder: "elsewhere")))
    }

    @Test("a script without the executable bit says so, in the words of the fix")
    func nonExecutableScript() {
        let temp = TemporaryDirectory()
        temp.writePlugin(folder: "good", manifest: goodManifest,
                         script: (name: "run.sh", body: "#!/bin/sh\n", executable: false))
        let found = discovery.scan(temp.plugins)
        guard case .executableNotExecutable = found[0].problems.last else {
            Issue.record("expected a non-executable complaint, got \(found[0].problems)"); return
        }
        #expect(found[0].problems.last?.description.contains("chmod +x") == true)
    }

    /// A relative `run` that climbs out of the plugin folder would let a
    /// manifest reach anywhere on disk while still looking self-contained.
    @Test("a relative command cannot escape the plugin folder")
    func relativePathCannotEscape() {
        let temp = TemporaryDirectory()
        temp.writePlugin(folder: "sneaky", manifest: """
        { "id": "sneaky", "name": "Sneaky", "version": "1.0.0", "api": 1, "kind": "poll",
          "run": ["../../../../bin/sh"], "interval": 5, "timeout": 2 }
        """)
        let found = discovery.scan(temp.plugins)
        #expect(found[0].executable == nil)
        #expect(found[0].problems.contains { $0.description.contains("outside the plugin folder") })
    }

    /// The search path is two folders of the test's own rather than `/usr/bin`
    /// and `/bin`: on a Mac only `/bin` holds `sh`, and on Ubuntu, where `/bin`
    /// is a link to `/usr/bin`, both do — which is a fact about the machine,
    /// not about the rule.
    @Test("a bare command name is resolved on the configured path, not the inherited one")
    func bareCommandUsesConfiguredPath() throws {
        let temp = TemporaryDirectory()
        temp.writePlugin(folder: "bare", manifest: """
        { "id": "bare", "name": "Bare", "version": "1.0.0", "api": 1, "kind": "poll",
          "run": ["tool"], "interval": 5, "timeout": 2 }
        """)
        let first = temp.url.appendingPathComponent("first", isDirectory: true)
        let second = temp.url.appendingPathComponent("second", isDirectory: true)
        for folder in [first, second] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let tool = second.appendingPathComponent("tool")
        try Data("#!/bin/sh\n".utf8).write(to: tool)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        let configured = PluginDiscovery(searchPath: [first.path, second.path])
        #expect(configured.load(temp.url.appendingPathComponent("plugins/bare")).executable?.path
                == tool.standardizedFileURL.path)

        let empty = PluginDiscovery(searchPath: ["/nowhere"])
        let missing = empty.load(temp.url.appendingPathComponent("plugins/bare"))
        #expect(missing.executable == nil)
        #expect(missing.problems.contains { $0.description.contains("/nowhere") })
    }
}

@Suite("Discovery messages")
struct DiscoveryMessageTests {
    static let good = #"{"id":"x","name":"X","version":"1.0.0","api":1,"kind":"poll","run":["./r.sh"],"interval":5,"timeout":2"#

    /// A manifest the decoder refuses is said in the words of the JSON — the
    /// field as the file spells it, and the kind of value — never in the
    /// names of the Swift types it was being read into.
    @Test("a decoding error names the field and the kind of value, in words", arguments: [
        (#"{"id":"x","name":"X","version":1,"api":1,"kind":"poll","run":["./r.sh"],"interval":5,"timeout":2}"#,
         #""version" must be a string, not a number"#),
        (#"{"id":"x","name":"X","version":"1.0.0","api":1,"kind":"poll","interval":5,"timeout":2}"#,
         #""run" is required"#),
        (good + #","permissions":[]}"#, #""permissions" must be an object, not a list"#),
        (#"{"id":"x","name":"X","version":"1.0.0","api":1,"kind":"poll","run":"./r.sh","interval":"5","timeout":2}"#,
         #""run" must be a list, not a string"#),
        (#"{"id":"x","name":"X","version":"1.0.0","api":1,"kind":"poll","run":["./r.sh"],"interval":"5","timeout":2}"#,
         #""interval" must be a number, not a string"#),
        (good + #","settings":[{"key":"k","type":"frob","label":"K","default":1}]}"#,
         #""settings[0].type" is "frob", which is not one of the values it can have"#),
        (good + #","settings":[{"key":"k","type":"int","label":"K"}]}"#, #""settings[0].default" is required"#),
        (#"{"id":"x","name":null,"version":"1.0.0","api":1,"kind":"poll","run":["./r.sh"],"interval":5,"timeout":2}"#,
         #""name" must be a string, not null"#),
        (#"{"id":"x","name":"X","version":"1.0.0","api":1,"kind":"poll","run":["./r.sh"],"interval":1e400,"timeout":2}"#,
         "the number 1e400 cannot be read where it is: it is too large, or not a whole number where one belongs"),
        (#"{"id":"x","name":"X","version":"1.0.0","api":1.5,"kind":"poll","run":["./r.sh"],"interval":5,"timeout":2}"#,
         "the number 1.5 cannot be read where it is: it is too large, or not a whole number where one belongs"),
        (#"{"id":"x","name":"X","version":"1.0.0","api":true,"kind":"poll","run":["./r.sh"],"interval":5,"timeout":2}"#,
         #""api" must be a whole number, not true or false"#),
        ("not json", "is not valid JSON"),
        // Where no field is to blame, the whole of it is named — not a field
        // with no name, which used to read `""`.
        ("[1, 2]", "the manifest must be an object, not a list"),
        (#""x""#, "the manifest must be an object, not a string"),
        ("null", "the manifest must be an object, not null"),
    ])
    func decodingErrorsInWords(_ manifest: String, _ said: String) {
        do {
            _ = try JSONDecoder().decode(PluginManifest.self, from: Data(manifest.utf8))
            Issue.record("\(manifest) decoded")
        } catch {
            #expect(PluginDiscovery.describe(error, in: Data(manifest.utf8), document: "the manifest") == said)
        }
    }

    /// Outside Apple's own Foundation, JSONDecoder reports a number it cannot
    /// hold as JSON that is not valid and attaches no reason, so the number is
    /// found in the text. The same error, built as Linux builds it, is read
    /// here on every platform.
    @Test("a number the decoder could not hold is named from the text when the error does not name it", arguments: [
        (#"{"id":"x","api":1.5,"interval":5}"#, "the number 1.5 cannot be read where it is: it is too large, or not a whole number where one belongs"),
        (#"{"id":"x","api":1,"interval":1e400}"#, "the number 1e400 cannot be read where it is: it is too large, or not a whole number where one belongs"),
        (#"{"id":"x","api":1.5,"interval":2.5}"#, "a number in it cannot be read where it is: it is too large, or not a whole number where one belongs"),
        (#"{"id":"x","api":1,"interval":5}"#, "is not valid JSON"),
        ("not json", "is not valid JSON"),
    ])
    func numberNamedFromTheText(_ text: String, _ said: String) {
        let error = DecodingError.dataCorrupted(DecodingError.Context(
            codingPath: [], debugDescription: "The given data was not valid JSON.", underlyingError: nil))
        #expect(PluginDiscovery.describe(error, in: Data(text.utf8), document: "the manifest") == said)
        #expect(PluginDiscovery.describe(error, document: "the manifest") == "is not valid JSON", "without the text, nothing is guessed")
    }

    /// Every one of these ends up in front of a plugin author who is trying to
    /// work out why their plugin did not load, so each has to read as one
    /// complete sentence rather than as two templates stapled together.
    @Test("each failure reads as a sentence")
    func messagesAreSentences() {
        let problems: [DiscoveryProblem] = [
            .missingManifest,
            .unreadableManifest("permission denied"),
            .malformedManifest("missing required field \"run\""),
            .identifierMismatch(declared: "a", folder: "b"),
            .executableMissing(path: "/x/run.sh"),
            .executableNotOnSearchPath(command: "python3", searchPath: ["/usr/bin", "/bin"]),
            .executableOutsidePluginFolder(command: "../../ssh"),
            .executableNotExecutable("/x/run.sh"),
            .manifest(.missingInterval),
        ]
        for problem in problems {
            let text = problem.description
            #expect(!text.isEmpty)
            #expect(!text.contains("  "), "\(text) has doubled spacing")
            #expect(text.first?.isUppercase != true, "\(text) should read as a clause, not a title")
        }

        #expect(DiscoveryProblem.executableMissing(path: "/x/run.sh").description
            == "/x/run.sh does not exist")
        #expect(DiscoveryProblem.executableNotOnSearchPath(command: "python3", searchPath: ["/usr/bin", "/bin"]).description
            == "python3 was not found on /usr/bin:/bin")
        #expect(DiscoveryProblem.executableOutsidePluginFolder(command: "../../ssh").description
            == "../../ssh resolves outside the plugin folder, which a plugin is not allowed to do")
    }
}

@Suite("Plugin folder containment")
struct ContainmentTests {
    /// `standardizedFileURL` collapses `..` lexically and stops there, so a
    /// plugin shipping `bin -> /bin` and running `./bin/sh` passed a check that
    /// was at that point decoration.
    @Test("a symlink cannot be used to leave the plugin folder")
    func symlinkCannotEscape() throws {
        let temp = TemporaryDirectory()
        let directory = temp.url.appendingPathComponent("plugins/sneaky", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("""
        { "id": "sneaky", "name": "Sneaky", "version": "1.0.0", "api": 1, "kind": "poll",
          "run": ["./bin/sh"], "interval": 5, "timeout": 2 }
        """.utf8).write(to: directory.appendingPathComponent("manifest.json"))
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("bin"),
            withDestinationURL: URL(fileURLWithPath: "/bin")
        )

        let plugin = PluginDiscovery(searchPath: ["/usr/bin", "/bin"]).load(directory)
        #expect(plugin.executable == nil)
        #expect(plugin.problems.contains(.executableOutsidePluginFolder(command: "./bin/sh")))
        #expect(!plugin.isUsable)
    }

    @Test("a symlink that stays inside the folder still works")
    func symlinkInsideIsFine() throws {
        let temp = TemporaryDirectory()
        let directory = temp.url.appendingPathComponent("plugins/tidy", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("tools"), withIntermediateDirectories: true
        )
        try Data("""
        { "id": "tidy", "name": "Tidy", "version": "1.0.0", "api": 1, "kind": "poll",
          "run": ["./run.sh"], "interval": 5, "timeout": 2 }
        """.utf8).write(to: directory.appendingPathComponent("manifest.json"))

        let real = directory.appendingPathComponent("tools/real.sh")
        try Data("#!/bin/sh\necho '{}'\n".utf8).write(to: real)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: real.path)
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("run.sh"), withDestinationURL: real
        )

        let plugin = PluginDiscovery(searchPath: ["/usr/bin", "/bin"]).load(directory)
        #expect(plugin.problems.isEmpty, "\(plugin.problems.map(\.description))")
        #expect(plugin.isUsable)
    }

    /// A card's action is resolved by the same rules, because it used to be
    /// resolved by a second copy of them that compared paths lexically. The
    /// operator agreed to `./tools/refresh`; the plugin then pointed
    /// `tools/refresh` at something else and uDeck ran that.
    @Test("an action's command is contained by the same rule as the manifest's")
    func actionPathsAreContainedToo() throws {
        let temp = TemporaryDirectory()
        let directory = temp.url.appendingPathComponent("plugins/swap", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("tools"), withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("tools/refresh"),
            withDestinationURL: URL(fileURLWithPath: "/bin/sh")
        )

        let discovery = PluginDiscovery(searchPath: ["/usr/bin", "/bin"])
        let resolved = discovery.resolveExecutable("./tools/refresh", in: directory)
        guard case .failure(let problem) = resolved else {
            Issue.record("a symlink out of the folder resolved to \(resolved)"); return
        }
        #expect(problem == .executableOutsidePluginFolder(command: "./tools/refresh"))
    }
}
