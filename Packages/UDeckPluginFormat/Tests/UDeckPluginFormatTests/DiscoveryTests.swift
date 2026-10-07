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
        try Executable.write("#!/bin/sh\n", to: tool)
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
        try Executable.write("#!/bin/sh\necho '{}'\n", to: real)
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

/// A link in the plugins folder: a folder an author works on somewhere else.
/// uDeck follows it one step, to a folder outside its own, and reads what is
/// there as it reads any folder; anything else is listed, with the reason.
@Suite("Linked folders")
struct LinkedFolderTests {
    /// uDeck's folder in `temp/udeck`, and folders of the author's own in
    /// `temp/work` — outside it, as a working copy is.
    struct Place {
        let temp = TemporaryDirectory()
        var paths: UDeckPaths { UDeckPaths(root: temp.url.appendingPathComponent("udeck", isDirectory: true)) }
        var work: URL { temp.url.appendingPathComponent("work", isDirectory: true) }

        init() {
            try? FileManager.default.createDirectory(at: paths.plugins, withIntermediateDirectories: true)
            try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        }

        /// A plugin folder `work/<folder>` whose manifest says `id`.
        @discardableResult
        func folder(_ folder: String, id: String) -> URL {
            let directory = work.appendingPathComponent(folder, isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? Data("""
                { "id": "\(id)", "name": "\(id)", "version": "1.0.0", "api": 1, "kind": "poll",
                  "run": ["./run.sh"], "interval": 5, "timeout": 2 }
                """.utf8).write(to: directory.appendingPathComponent("manifest.json"))
            let script = directory.appendingPathComponent("run.sh")
            try? Executable.write("#!/bin/sh\nprintf '{}'\n", to: script)
            return directory
        }

        func link(_ name: String, to destination: String) throws {
            try FileManager.default.createSymbolicLink(atPath: paths.plugins.appendingPathComponent(name).path,
                                                       withDestinationPath: destination)
        }

        func scan() -> [DiscoveredPlugin] {
            PluginDiscovery(searchPath: ["/usr/bin", "/bin"]).scan(paths)
        }
    }

    @Test("a link to a folder outside uDeck's own is a plugin, named after the link, run from where it leads")
    func followed() throws {
        let place = Place()
        defer { withExtendedLifetime(place) {} }
        let folder = place.folder("greeter-working-copy", id: "greeter")
        try place.link("greeter", to: folder.path)
        let found = place.scan()
        #expect(found.count == 1)
        let plugin = try #require(found.first)
        let target = try #require(PluginLink.realPath(folder.path))
        #expect(plugin.folderName == "greeter")
        #expect(plugin.isUsable, "\(plugin.problems)")
        #expect(plugin.isLinked)
        #expect(plugin.linkedAt.map { PluginLink.realPath($0.deletingLastPathComponent().path) } == PluginLink.realPath(place.paths.plugins.path))
        #expect(plugin.linkedAt?.lastPathComponent == "greeter")
        #expect(plugin.directory.path == target, "where it leads, resolved")
        #expect(plugin.executable.flatMap { PluginLink.realPath($0.path) } == target + "/run.sh")
        // The folder itself, read as a plugin folder of its own, is the same plugin but for the name.
        #expect(PluginDiscovery(searchPath: ["/usr/bin", "/bin"]).load(folder).problems
                == [.identifierMismatch(declared: "greeter", folder: "greeter-working-copy")])
    }

    @Test("a link written relative to the plugins folder is followed from there")
    func relative() throws {
        let place = Place()
        defer { withExtendedLifetime(place) {} }
        place.folder("greeter", id: "greeter")
        try place.link("greeter", to: "../../work/greeter")
        let plugin = try #require(place.scan().first)
        #expect(plugin.isUsable, "\(plugin.problems)")
        #expect(plugin.directory.path == PluginLink.realPath(place.work.appendingPathComponent("greeter").path))
    }

    @Test("the id is the link's name: a manifest that says another is the mismatch any folder gets")
    func idIsTheLinksName() throws {
        let place = Place()
        defer { withExtendedLifetime(place) {} }
        let folder = place.folder("greeter", id: "greeter")
        try place.link("hello", to: folder.path)
        let plugin = try #require(place.scan().first)
        #expect(plugin.folderName == "hello")
        #expect(plugin.problems == [.identifierMismatch(declared: "greeter", folder: "hello")])
        #expect(!plugin.isUsable)
    }

    /// What the link leads to is a plugin folder like any: a link inside it
    /// that a command would leave it through is refused, as it always was.
    @Test("inside the folder a link leads to, a command that leaves it is refused as in any folder")
    func linksInside() throws {
        let place = Place()
        defer { withExtendedLifetime(place) {} }
        let folder = place.work.appendingPathComponent("sneaky", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("""
            { "id": "sneaky", "name": "Sneaky", "version": "1.0.0", "api": 1, "kind": "poll",
              "run": ["./bin/sh"], "interval": 5, "timeout": 2 }
            """.utf8).write(to: folder.appendingPathComponent("manifest.json"))
        try FileManager.default.createSymbolicLink(atPath: folder.appendingPathComponent("bin").path, withDestinationPath: "/bin")
        try place.link("sneaky", to: folder.path)
        let plugin = try #require(place.scan().first)
        #expect(plugin.isLinked)
        #expect(plugin.problems == [.executableOutsidePluginFolder(command: "./bin/sh")])
    }

    @Test("a link that leads nowhere, to a file, to another link, round in a circle, into or around uDeck's folder is listed with the reason")
    func refused() throws {
        let place = Place()
        defer { withExtendedLifetime(place) {} }
        let file = place.work.appendingPathComponent("a-file")
        try Data("x".utf8).write(to: file)
        let real = place.folder("real", id: "real")
        try FileManager.default.createSymbolicLink(atPath: place.work.appendingPathComponent("hop").path, withDestinationPath: real.path)
        try FileManager.default.createSymbolicLink(atPath: place.work.appendingPathComponent("loop-a").path,
                                                   withDestinationPath: place.work.appendingPathComponent("loop-b").path)
        try FileManager.default.createSymbolicLink(atPath: place.work.appendingPathComponent("loop-b").path,
                                                   withDestinationPath: place.work.appendingPathComponent("loop-a").path)
        let cache = place.paths.cache.appendingPathComponent("someone", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let inPlugins = place.paths.plugins.appendingPathComponent(".beside", isDirectory: true)
        try FileManager.default.createDirectory(at: inPlugins, withIntermediateDirectories: true)

        let gone = place.work.appendingPathComponent("gone").path
        let hop = place.work.appendingPathComponent("hop").path
        let circle = place.work.appendingPathComponent("loop-a").path + "/x"
        let cases: [(String, String, LinkRefusal)] = [
            ("nowhere", gone, .leadsNowhere(gone)),
            ("to-a-file", file.path, .notAFolder(file.path)),
            ("to-a-link", hop, .toALink(hop)),
            // One slash later, or a `.` name, it is still `hop` the
            // destination names, and `lstat` would go through it.
            ("to-a-link-slash", hop + "/", .toALink(hop + "/")),
            ("to-a-link-slashes", hop + "//", .toALink(hop + "//")),
            ("to-a-link-dot", hop + "/.", .toALink(hop + "/.")),
            ("to-a-link-dot-slash", hop + "/./", .toALink(hop + "/./")),
            ("to-itself", "to-itself", .toALink("to-itself")),
            ("to-itself-slash", "to-itself-slash/", .toALink("to-itself-slash/")),
            ("in-a-circle", circle, .circle(circle)),
            ("into-the-cache", cache.path, .insideUDeck(cache.path)),
            ("into-plugins", ".beside", .insideUDeck(".beside")),
            ("to-plugins", ".", .insideUDeck(".")),
            ("to-udeck", "..", .insideUDeck("..")),
            ("around-udeck", place.temp.url.path, .holdsUDeck(place.temp.url.path)),
            ("to-the-root", "/", .holdsUDeck("/")),
        ]
        for (name, destination, _) in cases { try place.link(name, to: destination) }
        let found = place.scan()
        #expect(found.map(\.folderName) == cases.map(\.0).sorted(), "every link listed, none skipped")
        for (name, _, refusal) in cases {
            let plugin = try #require(found.first { $0.folderName == name })
            #expect(plugin.problems == [.linkNotFollowed(refusal)], "\(name)")
            #expect(!plugin.isUsable && plugin.manifest == nil, "\(name)")
            #expect(plugin.isLinked && plugin.directory == plugin.linkedAt, "\(name): nothing it leads to is read")
        }
        #expect(DiscoveryProblem.linkNotFollowed(.leadsNowhere(gone)).description
                == "this is a link to \(gone), which is not there — moved, renamed, or on a disk that is not connected")
    }

    /// The slash and `.` taken off a destination to ask what it names are
    /// taken off a folder's too, which is followed as written.
    @Test("a folder written with a slash or a dot at its end is followed")
    func folderWithASlash() throws {
        let place = Place()
        defer { withExtendedLifetime(place) {} }
        let folder = place.folder("greeter", id: "greeter")
        try place.link("greeter", to: folder.path + "/./")
        let plugin = try #require(place.scan().first)
        #expect(plugin.isUsable, "\(plugin.problems)")
        #expect(plugin.directory.path == PluginLink.realPath(folder.path))
        #expect(PluginDiscovery.lastNameItself("/") == "/")
        #expect(PluginDiscovery.lastNameItself("/./") == "/")
        #expect(PluginDiscovery.lastNameItself("a/..") == "a/..")
        #expect(PluginDiscovery.lastNameItself("a/b.") == "a/b.")
        #expect(PluginDiscovery.lastNameItself("caf\u{E9}/.//") == "caf\u{E9}")
    }

    /// Whether a destination is absolute is its first byte: `/` with a
    /// combining mark after it is one Character, which is not `/`, and read
    /// that way it was looked for inside the plugins folder.
    @Test("a destination that starts with a slash is absolute, whatever follows the slash")
    func absoluteByItsFirstByte() throws {
        let place = Place()
        defer { withExtendedLifetime(place) {} }
        let destination = "/\u{301}nowhere-at-the-root"
        #expect(!FileManager.default.fileExists(atPath: destination))
        // Where it would be looked for if it were relative: a folder is there.
        try FileManager.default.createDirectory(at: place.paths.plugins.appendingPathComponent("\u{301}nowhere-at-the-root"),
                                                withIntermediateDirectories: true)
        let link = place.paths.plugins.appendingPathComponent("mark")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: destination)
        #expect(PluginDiscovery.follow(link, udeckFolder: place.paths.root) == .failure(.leadsNowhere(destination)))
    }

    /// Asked of the disk each time: a link an author points at another
    /// folder is another plugin folder from the next read on.
    @Test("a link pointed elsewhere is read where it leads now")
    func repointed() throws {
        let place = Place()
        defer { withExtendedLifetime(place) {} }
        let first = place.folder("first", id: "greeter")
        let second = place.folder("second", id: "greeter")
        try place.link("greeter", to: first.path)
        #expect(place.scan().first?.directory.path == PluginLink.realPath(first.path))
        try FileManager.default.removeItem(atPath: place.paths.plugins.appendingPathComponent("greeter").path)
        try place.link("greeter", to: second.path)
        #expect(place.scan().first?.directory.path == PluginLink.realPath(second.path))
        #expect(FileManager.default.fileExists(atPath: first.appendingPathComponent("manifest.json").path))
    }

    @Test("a link udeck-plugin link makes is one uDeck lists")
    func linkMakesAPlugin() async throws {
        let place = Place()
        defer { withExtendedLifetime(place) {} }
        let folder = place.folder("greeter", id: "greeter")
        let said = await udeckPlugin(["link", folder.path, "--home", place.paths.root.path], in: place.temp.url, home: place.temp.url)
        #expect(said.status == 0, "\(said.errors)")
        let plugin = try #require(place.scan().first)
        #expect(plugin.isUsable && plugin.isLinked, "\(plugin.problems)")
    }

    @Test("link refuses a folder inside uDeck's own, or one that holds it, as discovery would not follow it")
    func linkRefusesUDecksOwn() async throws {
        let place = Place()
        defer { withExtendedLifetime(place) {} }
        let inside = place.paths.root.appendingPathComponent("mine/greeter", isDirectory: true)
        try FileManager.default.createDirectory(at: inside.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: place.folder("greeter", id: "greeter"), to: inside)
        let refused = await udeckPlugin(["link", inside.path, "--home", place.paths.root.path], in: place.temp.url, home: place.temp.url)
        #expect(refused.status == 2)
        #expect(refused.errors.first?.contains("is inside uDeck's own folder") == true, "\(refused.errors)")

        try Data("""
            { "id": "around", "name": "around", "version": "1.0.0", "api": 1, "kind": "poll",
              "run": ["./run.sh"], "interval": 5, "timeout": 2 }
            """.utf8).write(to: place.temp.url.appendingPathComponent("manifest.json"))
        let around = await udeckPlugin(["link", place.temp.url.path, "--home", place.paths.root.path], in: place.temp.url, home: place.temp.url)
        #expect(around.status == 2)
        #expect(around.errors.first?.contains("holds uDeck's own folder") == true, "\(around.errors)")
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: place.paths.plugins.path)) ?? []).isEmpty)
    }
}

/// A command, a path in a plugin's folder and a name in the plugins folder are
/// read by their bytes, as the system reads them: a `/` or a `.` with a
/// combining mark after it is one Swift `Character`, which is not `/` or `.`,
/// and a mark that goes before what follows it (U+0600) makes the `/` after it
/// part of one too. Read by the Character, each of these was another command.
@Suite("Commands and names read by their bytes")
struct ByteReadingTests {
    /// A plugin folder with an executable `tool` at `relative` inside it.
    func folder(with relative: String, in temp: TemporaryDirectory) throws -> URL {
        let directory = temp.url.appendingPathComponent("plugins/bytes", isDirectory: true)
        let tool = directory.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: tool.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Executable.write("#!/bin/sh\necho '{}'\n", to: tool)
        return directory
    }

    @Test("a command whose first byte is / is a path from the root, whatever follows the slash")
    func absoluteByItsFirstByte() throws {
        let temp = TemporaryDirectory()
        defer { withExtendedLifetime(temp) {} }
        let directory = try folder(with: "tool", in: temp)
        let command = "/\u{301}nowhere-at-the-root"
        #expect(!FileManager.default.fileExists(atPath: command))
        let resolved = PluginDiscovery(searchPath: ["/usr/bin", "/bin"]).resolveExecutable(command, in: directory)
        #expect(resolved == .failure(.executableMissing(path: command)), "read as a bare name, it was looked up on the search path")
    }

    @Test("a command with a / in it is a path in the plugin's folder, even when the / is inside one Character")
    func separatorByItsByte() throws {
        let temp = TemporaryDirectory()
        defer { withExtendedLifetime(temp) {} }
        let name = "a\u{600}/tool"
        #expect(!name.contains(Character("/")), "the premise: one Character holds the slash")
        let directory = try folder(with: name, in: temp)
        let resolved = PluginDiscovery(searchPath: ["/usr/bin", "/bin"]).resolveExecutable(name, in: directory)
        guard case .success(let url) = resolved else { Issue.record("\(resolved)"); return }
        #expect(url.lastPathComponent == "tool")
    }

    @Test("a path is inside the plugin's folder by its bytes, even when the folder's / is one Character with what follows")
    func insideByItsBytes() throws {
        let temp = TemporaryDirectory()
        defer { withExtendedLifetime(temp) {} }
        let name = "\u{301}x/tool"
        let directory = try folder(with: name, in: temp)
        let root = directory.standardizedFileURL.resolvingSymlinksInPath().path
        #expect(!Array(root + "/" + name).starts(with: Array(root + "/")),
                "the premise: by the Character, it is not under the folder")
        let resolved = PluginDiscovery(searchPath: ["/usr/bin", "/bin"]).resolveExecutable(name, in: directory)
        guard case .success(let url) = resolved else { Issue.record("read by the Character, it was outside: \(resolved)"); return }
        #expect(url.lastPathComponent == "tool")
        // And outside is still outside.
        #expect(FilePaths.isInside(root, root + "-sibling/tool") == false)
        #expect(FilePaths.isInside(root, root) == false)
        #expect(FilePaths.isInside(root, root + "/tool"))
    }

    /// A folder written with a `/` at its end is still that folder, and not
    /// inside itself: what is below it starts after the slash.
    @Test("a folder is not inside itself, a / at the end of either or both")
    func notInsideItself() {
        #expect(!FilePaths.isInside("/a", "/a/"))
        #expect(!FilePaths.isInside("/a/", "/a/"))
        #expect(!FilePaths.isInside("/a/", "/a"))
        #expect(FilePaths.isInside("/a/", "/a/b") && FilePaths.isInside("/a", "/a/b"))
        #expect(!FilePaths.isInside("/a", "/ab"))
    }

    /// What Linux calls hidden — the name alone, on the build without
    /// Foundation's resource values, where the plugins folder's listing
    /// leaves such names out.
    @Test("a name is hidden by its first byte")
    func hiddenByItsFirstByte() {
        #expect(Array(".\u{301}x").first != Optional(Character(".")), "the premise: one Character holds the dot")
        #expect(FilePaths.isHiddenName(".\u{301}x"))
        #expect(FilePaths.isHiddenName(".git"))
        #expect(!FilePaths.isHiddenName("x.") && !FilePaths.isHiddenName("") && !FilePaths.isHiddenName("\u{301}.x"))
    }

    /// A folder of the search path written otherwise than from `/` — `bin`,
    /// `~/bin` — would be read from uDeck's working folder by uDeck and from
    /// the plugin's folder by its shell, and nothing expands a `~` there:
    /// neither looks in it.
    @Test("only folders written from / are looked in, and handed over in PATH")
    func searchPathFromTheRoot() throws {
        let temp = TemporaryDirectory()
        defer { withExtendedLifetime(temp) {} }
        let tools = temp.url.appendingPathComponent("tools", isDirectory: true)
        let directory = try folder(with: "tool", in: temp)
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        let greet = tools.appendingPathComponent("greet-from-tools")
        try Executable.write("#!/bin/sh\n", to: greet)
        // The same folder, written relative to this process's own working folder.
        let here = FileManager.default.currentDirectoryPath
        let relative = String(repeating: "../", count: here.split(separator: "/").count) + String(tools.path.dropFirst())
        #expect(FileManager.default.fileExists(atPath: URL(fileURLWithPath: relative).appendingPathComponent("greet-from-tools").path),
                "the premise: read from the working folder, it is the folder")

        let relativeOnly = PluginDiscovery(searchPath: [relative, "/usr/bin"]).resolveExecutable("greet-from-tools", in: directory)
        #expect(relativeOnly == .failure(.executableNotOnSearchPath(command: "greet-from-tools", searchPath: ["/usr/bin"])))
        let absolute = PluginDiscovery(searchPath: [relative, tools.path]).resolveExecutable("greet-from-tools", in: directory)
        #expect((try? absolute.get())?.lastPathComponent == "greet-from-tools")

        #expect(PluginEnvironment.lookedIn(["bin", "/usr/bin", "~/bin", "", "/\u{301}x"]) == ["/usr/bin", "/\u{301}x"])
        #expect(PluginEnvironment.effective(["bin", "~/bin"]) == PluginEnvironment.defaultSearchPath)
        #expect(PluginEnvironment.effective([]) == PluginEnvironment.defaultSearchPath)
        #expect(PluginEnvironment.effective(["bin", "/opt/x"]) == ["bin", "/opt/x"])
        let action = PluginEnvironment.action(id: PluginIdentifier(rawValue: "bytes")!, directory: directory,
                                              searchPath: ["bin", "/usr/bin", "~/bin", "/bin"], home: "/h", temporaryDirectory: nil)
        #expect(action["PATH"] == "/usr/bin:/bin")
    }
}
