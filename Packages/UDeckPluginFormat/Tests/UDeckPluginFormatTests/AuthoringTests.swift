import Foundation
import Testing
import UDeckPluginCommand
@testable import UDeckPluginFormat
import UDeckPluginFormatFixtures

/// What `udeck-plugin` sounded like for one invocation.
struct Said {
    var status: Int32
    var output: [String]
    var errors: [String]
}

/// `udeck-plugin` started in `here`, with nothing of this machine's own in its
/// environment: git reads no configuration but `gitConfig`, and `HOME` is a
/// folder of the test's own — and so is the account's home folder, which is
/// where `link` looks for uDeck's (`homes`, `home` unless the test names
/// others) — so neither `new` nor `link` can reach the operator's git
/// settings or uDeck folder, whatever a test gets wrong.
func udeckPlugin(_ arguments: [String], in here: URL, home: URL, gitConfig: String = "/dev/null",
                 extra: [String: String] = [:], homes: UserHomes? = nil) async -> Said {
    var output: [String] = []
    var errors: [String] = []
    let environment = [
        "PATH": "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin",
        "HOME": home.path,
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_CONFIG_GLOBAL": gitConfig,
    ].merging(extra) { _, new in new }
    let status = await Command.run(arguments, environment: environment, currentDirectory: here.path,
                                   homes: homes ?? .only(home), output: { output.append($0) }, errors: { errors.append($0) })
    return Said(status: status, output: output, errors: errors)
}

extension UserHomes {
    /// One account, whose home is `home`, and no other: what a test hands
    /// `udeck-plugin` instead of the machine's account database.
    static func only(_ home: URL?, others: [String: URL] = [:]) -> UserHomes {
        let path = home?.path
        let named = others.mapValues(\.path)
        return UserHomes(current: { path }, named: { named[$0] })
    }
}

/// Everything in `folder`, every level, by path.
func everything(in folder: URL) -> [String] {
    var paths: [String] = []
    let walker = FileManager.default.enumerator(atPath: folder.path)
    while let path = walker?.nextObject() as? String { paths.append(path) }
    return paths.sorted()
}

@Suite("udeck-plugin new")
struct NewPluginTests {
    @Test("outside a repository, new makes ./<id>, and check --strict has nothing to say about it")
    func outsideARepository() async throws {
        let temp = TemporaryDirectory()
        defer { withExtendedLifetime(temp) {} }
        let made = await udeckPlugin(["new", "disk-check", "--author", "Ada Lovelace"], in: temp.url, home: temp.url)
        #expect(made.status == 0, "\(made.errors)")
        #expect(made.output.first == "made disk-check: manifest.json, manifest.ru.json, README.md, disk-check.sh")
        #expect(made.output.contains { $0.hasPrefix("note: no LICENSE: ") && $0.contains("is not in a plugin repository") })
        let folder = temp.url.appendingPathComponent("disk-check")
        #expect(everything(in: temp.url) == ["disk-check", "disk-check/README.md", "disk-check/disk-check.sh",
                                             "disk-check/manifest.json", "disk-check/manifest.ru.json"])

        let manifest = try JSONDecoder().decode(PluginManifest.self, from: Data(contentsOf: folder.appendingPathComponent("manifest.json")))
        #expect(manifest.id.rawValue == "disk-check")
        #expect(manifest.name == "Disk check")
        #expect(manifest.version == "1.0.0")
        #expect(manifest.api == 1)
        #expect(manifest.kind == .poll)
        #expect(manifest.author == "Ada Lovelace")
        #expect(manifest.run == ["./disk-check.sh"])
        #expect(manifest.interval == 60)
        #expect(manifest.timeout == 2)
        #expect(manifest.permissions.capabilities.isEmpty, "a new plugin asks for nothing")
        let mode = try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent("disk-check.sh").path)[.posixPermissions]
        #expect(GitHash.integer(mode) == 0o755)

        let checked = await udeckPlugin(["check", "--strict", folder.path], in: temp.url, home: temp.url)
        #expect(checked.status == 0)
        #expect(checked.output == ["checked \(folder.path) on disk strictly: 0 errors, 0 warnings"])
    }

    /// The official repository is the one a plugin is most likely made in, and
    /// its rules are the strictest: the LICENSE line, the author, the sign-off.
    @Test("in a plugin repository, new makes plugins/<id> from any folder in it, and the repository passes as the official one")
    func insideARepository() async throws {
        let repository = try TestRepository()
        let deep = repository.folder.appendingPathComponent("docs/notes", isDirectory: true)
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        let made = await udeckPlugin(["new", "greeter", "--author", "Ada Lovelace"], in: deep, home: repository.temp.url)
        #expect(made.status == 0, "\(made.errors)")
        #expect(made.output.first?.hasSuffix("/plugins/greeter: manifest.json, manifest.ru.json, README.md, greeter.sh, LICENSE") == true,
                "\(made.output)")
        #expect(!made.output.contains { $0.hasPrefix("note:") }, "\(made.output)")
        let folder = repository.folder.appendingPathComponent("plugins/greeter")
        #expect(!FileManager.default.fileExists(atPath: deep.appendingPathComponent("greeter").path))

        let year = Calendar.current.component(.year, from: Date())
        let root = try Data(contentsOf: repository.folder.appendingPathComponent("LICENSE"))
        let licence = try Data(contentsOf: folder.appendingPathComponent("LICENSE"))
        #expect(licence == Data("Copyright \(year) Ada Lovelace\n\n".utf8) + root)
        let readme = try String(contentsOf: folder.appendingPathComponent("README.md"), encoding: .utf8)
        #expect(readme.contains("## Licence\n\nApache-2.0, copyright Ada Lovelace"))

        try FileManager.default.removeItem(at: deep)
        let head = try repository.commit([:])
        let official = await udeckPlugin(["check-repo", "--official", "--repo", repository.folder.path], in: repository.folder,
                                         home: repository.temp.url)
        #expect(official.status == 0)
        #expect(official.output == ["checked 2 plugin folders at \(head.prefix(12)) as the official repository: 0 errors, 0 warnings"])
    }

    @Test("an author not given is git's user.name")
    func authorFromGit() async throws {
        let temp = TemporaryDirectory()
        defer { withExtendedLifetime(temp) {} }
        let config = temp.url.appendingPathComponent("gitconfig")
        try Data("[user]\n\tname = Grace Hopper\n".utf8).write(to: config)
        let made = await udeckPlugin(["new", "named"], in: temp.url, home: temp.url, gitConfig: config.path)
        #expect(made.status == 0, "\(made.errors)")
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: Data(contentsOf: temp.url.appendingPathComponent("named/manifest.json")))
        #expect(manifest.author == "Grace Hopper")

        let nobody = await udeckPlugin(["new", "anonymous"], in: temp.url, home: temp.url)
        #expect(nobody.status == 0)
        let unsigned = try JSONDecoder().decode(PluginManifest.self, from: Data(contentsOf: temp.url.appendingPathComponent("anonymous/manifest.json")))
        #expect(unsigned.author == nil, "outside a repository there is no LICENSE to name anybody in")
    }

    @Test("where every plugin is Apache-2.0, new does not make one without an author")
    func noAuthorInAnApacheRepository() async throws {
        let repository = try TestRepository()
        let said = await udeckPlugin(["new", "orphan"], in: repository.folder, home: repository.temp.url)
        #expect(said.status == 2)
        #expect(said.errors.first?.contains("--author \"Your Name\"") == true, "\(said.errors)")
        #expect(!FileManager.default.fileExists(atPath: repository.folder.appendingPathComponent("plugins/orphan").path))
    }

    @Test("a name, an author and a description reach the manifest exactly as given, quotes and all")
    func textIsEscaped() async throws {
        let temp = TemporaryDirectory()
        defer { withExtendedLifetime(temp) {} }
        let author = #"Ada "A. L." Lovelace \ Жуковская"#
        let name = #"Ω "quoted" \ name"#
        let description = "\"Quotes\"; / slashes \\ too, and no space\u{A0}that is not one."
        let made = await udeckPlugin(["new", "quoted", "--author", author, "--name", name, "--description", description],
                                     in: temp.url, home: temp.url)
        #expect(made.status == 0, "\(made.errors)")
        let folder = temp.url.appendingPathComponent("quoted")
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: Data(contentsOf: folder.appendingPathComponent("manifest.json")))
        #expect(manifest.author == author)
        #expect(manifest.name == name)
        #expect(manifest.description == description)
        let translation = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("manifest.ru.json"))) as? [String: String]
        #expect(translation == ["name": name], "a description of the author's own is not translated by anybody but them")
        let checked = await udeckPlugin(["check", "--strict", folder.path], in: temp.url, home: temp.url)
        #expect(checked.output.last == "checked \(folder.path) on disk strictly: 0 errors, 0 warnings", "\(checked.output)")
    }

    @Test("new refuses what is not an id, and writes nothing", arguments: [
        "", ".hidden", "-dash", "_under", "Upper", "a b", "a/b", "..", String(repeating: "a", count: 65), "ид",
    ])
    func notAnID(_ id: String) async {
        let temp = TemporaryDirectory()
        defer { withExtendedLifetime(temp) {} }
        // After `--`, so that "-dash" is the id it is meant to be and not an option.
        let said = await udeckPlugin(["new", "--", id], in: temp.url, home: temp.url)
        #expect(said.status == 2)
        #expect(said.errors.first?.contains("is not a plugin id") == true, "\(said.errors)")
        #expect(everything(in: temp.url).isEmpty)
    }

    @Test("new touches nothing that is already there: a folder, a file, a link to nowhere")
    func takenPlaces() async throws {
        let temp = TemporaryDirectory()
        defer { withExtendedLifetime(temp) {} }
        let manager = FileManager.default
        try manager.createDirectory(at: temp.url.appendingPathComponent("folder"), withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: temp.url.appendingPathComponent("folder/keep.txt"))
        try Data("mine".utf8).write(to: temp.url.appendingPathComponent("file"))
        try manager.createSymbolicLink(atPath: temp.url.appendingPathComponent("dangling").path, withDestinationPath: "/nowhere/at/all")
        let before = everything(in: temp.url)
        for id in ["folder", "file", "dangling"] {
            let said = await udeckPlugin(["new", id, "--author", "A"], in: temp.url, home: temp.url)
            #expect(said.status == 1, "\(id)")
            #expect(said.errors.first?.contains("is already there; nothing was written") == true, "\(id): \(said.errors)")
        }
        #expect(everything(in: temp.url) == before)
        #expect(try Data(contentsOf: temp.url.appendingPathComponent("folder/keep.txt")) == Data("mine".utf8))
    }

    @Test("new with no id, two ids or an option without its value is wrong usage", arguments: [
        ["new"], ["new", "a", "b"], ["new", "a", "--name"], ["new", "a", "--frobnicate"], ["new", "a", "--author", " "],
        ["new", "a", "--author", "two\nlines"],
    ])
    func usage(_ arguments: [String]) async {
        let temp = TemporaryDirectory()
        defer { withExtendedLifetime(temp) {} }
        let said = await udeckPlugin(arguments, in: temp.url, home: temp.url)
        #expect(said.status == 2, "\(arguments)")
        #expect(everything(in: temp.url).isEmpty, "\(arguments)")
    }

    /// A line break in the name used to reach the producer's first comment
    /// and end it: what followed was a line of the script, and ran on every
    /// poll. The text is refused now, and the script holds none of it anyway.
    @Test("a name, a description or an author with a line break or a control character in it is refused, and nothing is written",
          arguments: ["--name", "--description", "--author"],
          ["Line one\ntouch INJECTED", "a\rb", "a\tb", "a\u{0}b", "a\u{1B}[31mb", "a\u{1F}b", "a\u{7F}b", "a\u{80}b",
           "a\u{85}b", "a\u{9F}b", "a\u{2028}b", "a\u{2029}b"])
    func notOneLine(_ option: String, _ text: String) async {
        let temp = TemporaryDirectory()
        defer { withExtendedLifetime(temp) {} }
        let arguments = ["new", "nl", "--author", "T", option, text].enumerated()
            .filter { option != "--author" || ($0.offset != 2 && $0.offset != 3) }.map(\.element)
        let said = await udeckPlugin(arguments, in: temp.url, home: temp.url)
        #expect(said.status == 2, "\(arguments)")
        #expect(said.errors.first == "udeck-plugin new: \(option == "--author" ? "the author" : option) is one line of text, "
                + "with no line break or other control character in it", "\(said.errors)")
        #expect(everything(in: temp.url).isEmpty, "\(arguments)")
    }

    @Test("what is one line is kept as given: spaces of every width, accents, punctuation")
    func oneLineIsKept() async throws {
        let temp = TemporaryDirectory()
        defer { withExtendedLifetime(temp) {} }
        let text = "~ caf\u{E9} \u{A0}\u{202F}\u{2027}\u{3000}\u{A1} \"quoted\" `tick` $(not run); end"
        let made = await udeckPlugin(["new", "kept", "--author", text, "--name", text, "--description", text],
                                     in: temp.url, home: temp.url)
        #expect(made.status == 0, "\(made.errors)")
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: Data(contentsOf: temp.url.appendingPathComponent("kept/manifest.json")))
        #expect(manifest.name == text)
        #expect(manifest.description == text)
        #expect(manifest.author == text)
    }

    /// The producer is a shell script, and nothing the author typed is
    /// written into it, not even into a comment: the id is its only word of
    /// theirs, and an id is letters, digits and `. _ -`.
    @Test("the producer new makes holds none of the name or the description")
    func scriptHoldsNoText() async throws {
        let temp = TemporaryDirectory()
        defer { withExtendedLifetime(temp) {} }
        let name = "Name; touch INJECTED"
        let description = "Description `touch INJECTED`"
        let made = await udeckPlugin(["new", "quiet-one", "--author", "A", "--name", name, "--description", description],
                                     in: temp.url, home: temp.url)
        #expect(made.status == 0, "\(made.errors)")
        let script = try String(contentsOf: temp.url.appendingPathComponent("quiet-one/quiet-one.sh"), encoding: .utf8)
        #expect(!script.contains("INJECTED"), "\(script)")
        #expect(script.hasPrefix("#!/bin/sh\n# quiet-one: a uDeck producer."), "\(script.prefix(80))")
        #expect(try String(contentsOf: temp.url.appendingPathComponent("quiet-one/README.md"), encoding: .utf8).hasPrefix("# \(name)\n"))
    }
}

@Suite("udeck-plugin link")
struct LinkPluginTests {
    /// A plugin folder made by `new`, in `temp/work`.
    static func made(_ id: String, in temp: TemporaryDirectory, folder: String? = nil) async throws -> URL {
        let work = temp.url.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let said = await udeckPlugin(["new", id, "--author", "A"], in: work, home: temp.url)
        #expect(said.status == 0, "\(said.errors)")
        let made = work.appendingPathComponent(id)
        guard let folder else { return made }
        let renamed = work.appendingPathComponent(folder)
        try FileManager.default.moveItem(at: made, to: renamed)
        return renamed
    }

    @Test("link puts one link into <home>/plugins, named after the id, and nothing else anywhere")
    func links() async throws {
        let temp = TemporaryDirectory()
        defer { withExtendedLifetime(temp) {} }
        let folder = try await Self.made("greeter", in: temp, folder: "greeter-work")
        let home = temp.url.appendingPathComponent("udeck", isDirectory: true)
        let before = everything(in: folder)
        let said = await udeckPlugin(["link", "work/greeter-work", "--home", "udeck"], in: temp.url, home: temp.url)
        #expect(said.status == 0, "\(said.errors)")
        let link = home.appendingPathComponent("plugins/greeter")
        let target = try #require(PluginLink.realPath(folder.path))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == target)
        #expect(everything(in: home) == ["plugins", "plugins/greeter"], "installed.json is not touched, nor made")
        #expect(everything(in: folder) == before)
        #expect(said.output.first?.hasPrefix("linked ") == true && said.output.first?.hasSuffix("/udeck/plugins/greeter -> \(target)") == true,
                "\(said.output)")
        #expect(said.output.contains { $0.hasPrefix("to undo it: rm ") })
        #expect(!said.output.contains { $0.hasPrefix("note: ") }, "uDeck lists a plugin through a link: \(said.output)")
        #expect(PluginLink.udeckReadsLinks)
    }

    /// uDeck finds its folder in the account's home folder, as Foundation's
    /// `NSHomeDirectory()` does — not in `HOME`, which a shell can set to
    /// anything — and `link` has to put the link where uDeck will look.
    @Test("without --home, link goes into ~/.udeck of the account's home folder, not of HOME")
    func defaultHome() async throws {
        let temp = TemporaryDirectory()
        defer { withExtendedLifetime(temp) {} }
        let folder = try await Self.made("greeter", in: temp)
        let user = temp.url.appendingPathComponent("someone", isDirectory: true)
        let shell = temp.url.appendingPathComponent("elsewhere", isDirectory: true)
        let said = await udeckPlugin(["link", folder.path], in: temp.url, home: shell, homes: .only(user))
        #expect(said.status == 0, "\(said.errors)")
        let link = user.appendingPathComponent(".udeck/plugins/greeter")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == PluginLink.realPath(folder.path))
        #expect(!FileManager.default.fileExists(atPath: shell.path), "HOME is not where uDeck looks")

        // An account the database has no home for: HOME, as Foundation falls back to it.
        try FileManager.default.removeItem(at: link)
        let fallback = await udeckPlugin(["link", folder.path], in: temp.url, home: shell, homes: .only(nil))
        #expect(fallback.status == 0, "\(fallback.errors)")
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: shell.appendingPathComponent(".udeck/plugins/greeter").path))
                == PluginLink.realPath(folder.path))

        // And CFFIXED_USER_HOME before either, which Foundation reads first.
        let fixed = temp.url.appendingPathComponent("fixed", isDirectory: true)
        let pinned = await udeckPlugin(["link", folder.path], in: temp.url, home: shell, extra: ["CFFIXED_USER_HOME": fixed.path],
                                       homes: .only(user))
        #expect(pinned.status == 0, "\(pinned.errors)")
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: fixed.appendingPathComponent(".udeck/plugins/greeter").path))
                == PluginLink.realPath(folder.path))

        var nowhere: [String] = []
        let status = await Command.run(["link", folder.path], environment: ["PATH": "/usr/bin:/bin"], currentDirectory: temp.url.path,
                                       homes: .only(nil), output: { _ in }, errors: { nowhere.append($0) })
        #expect(status == 2, "no home folder, no HOME and no --home: nowhere to link to")
        #expect(nowhere.first?.contains("--home") == true, "\(nowhere)")
    }

    /// What `link` reads the account database with, against what uDeck's
    /// Foundation answers on the same machine for the same account.
    @Test("the account's home folder is the one Foundation gives uDeck")
    func accountHome() throws {
        let mine = try #require(UserHomes.system.current())
        #expect(mine.hasPrefix("/"))
        #expect(UserHomes.system.named("") == nil)
        #expect(UserHomes.system.named("no-such-account-\(UUID().uuidString.prefix(8).lowercased())") == nil)
        #if canImport(Darwin)
        if ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] == nil {
            #expect(mine == NSHomeDirectory())
            #expect(UserHomes.system.account(in: ProcessInfo.processInfo.environment) == NSHomeDirectory())
            #expect(UserHomes.system.account(in: ["HOME": "/elsewhere"]) == NSHomeDirectory(), "HOME only without an entry")
            #expect(UserHomes.system.named(NSUserName()) == NSHomeDirectory())
            #expect(("~\(NSUserName())/deck" as NSString).expandingTildeInPath == mine + "/deck")
        }
        #endif
    }

    @Test("the same link again changes nothing; another folder, a folder of one's own, an installed plugin are refused")
    func onlyAFreeID() async throws {
        let temp = TemporaryDirectory()
        defer { withExtendedLifetime(temp) {} }
        let folder = try await Self.made("greeter", in: temp, folder: "greeter-1")
        let other = try await Self.made("greeter", in: temp, folder: "greeter-2")
        let home = temp.url.appendingPathComponent("udeck", isDirectory: true)
        let link = home.appendingPathComponent("plugins/greeter")
        #expect(await udeckPlugin(["link", folder.path, "--home", home.path], in: temp.url, home: temp.url).status == 0)

        let again = await udeckPlugin(["link", folder.path, "--home", home.path], in: temp.url, home: temp.url)
        #expect(again.status == 0)
        #expect(again.output.first?.hasPrefix("already linked: ") == true, "\(again.output)")

        let elsewhere = await udeckPlugin(["link", other.path, "--home", home.path], in: temp.url, home: temp.url)
        #expect(elsewhere.status == 1)
        #expect(elsewhere.errors.first?.contains("is already a link, to \(PluginLink.realPath(folder.path) ?? "")") == true, "\(elsewhere.errors)")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == PluginLink.realPath(folder.path))

        // A folder of the operator's own where the link would go.
        let own = temp.url.appendingPathComponent("own", isDirectory: true)
        try FileManager.default.createDirectory(at: own.appendingPathComponent("plugins/greeter"), withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: own.appendingPathComponent("plugins/greeter/keep.txt"))
        let taken = await udeckPlugin(["link", folder.path, "--home", own.path], in: temp.url, home: temp.url)
        #expect(taken.status == 1)
        #expect(taken.errors.first?.contains("a plugin folder uDeck did not install; move it out of the way first") == true, "\(taken.errors)")
        #expect(everything(in: own) == ["plugins", "plugins/greeter", "plugins/greeter/keep.txt"])

        // A plugin uDeck installed: its record, whether or not its folder is there.
        let installed = temp.url.appendingPathComponent("installed", isDirectory: true)
        try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
        let record = Data(#"{"version": 1, "plugins": {"greeter": {"source": "official", "repository": {"provider": "github", "host": "github.com", "path": "o/r"}}}}"#.utf8)
        try record.write(to: installed.appendingPathComponent("installed.json"))
        let replaced = await udeckPlugin(["link", folder.path, "--home", installed.path], in: temp.url, home: temp.url)
        #expect(replaced.status == 1)
        #expect(replaced.errors.first?.contains("greeter is installed in uDeck from github.com/o/r") == true, "\(replaced.errors)")
        #expect(replaced.errors.first?.hasSuffix("To work on it from \(PluginLink.realPath(folder.path) ?? "") instead, remove the "
                                                 + "installed copy first -- Remove, beside it under Plugins in uDeck's "
                                                 + "Settings -- and link again") == true, "\(replaced.errors)")
        #expect(replaced.errors.first?.contains("Link a folder") == false, "a button this uDeck does not have")
        #expect(everything(in: installed) == ["installed.json"])
        #expect(try Data(contentsOf: installed.appendingPathComponent("installed.json")) == record)

        // And a list uDeck could not read itself: nothing is linked past it.
        try Data("{ not json".utf8).write(to: installed.appendingPathComponent("installed.json"))
        let broken = await udeckPlugin(["link", folder.path, "--home", installed.path], in: temp.url, home: temp.url)
        #expect(broken.status == 1)
        #expect(broken.errors.first?.contains("is not the list of installed plugins uDeck writes (it ") == true, "\(broken.errors)")
        #expect(everything(in: installed) == ["installed.json"])

        // JSON, and not that list: said without a gap where the reason would be.
        try Data(#"{"format": 2, "items": {}}"#.utf8).write(to: installed.appendingPathComponent("installed.json"))
        let notTheList = await udeckPlugin(["link", folder.path, "--home", installed.path], in: temp.url, home: temp.url)
        #expect(notTheList.status == 1)
        #expect(notTheList.errors.first == "udeck-plugin link: \(installed.appendingPathComponent("installed.json").path) is not "
                + "the list of installed plugins uDeck writes; uDeck installs nothing while it is broken, and nothing was linked",
                "\(notTheList.errors)")
        #expect(everything(in: installed) == ["installed.json"])
    }

    /// What `link` prints to undo it is meant to be copied into a shell, so
    /// it has to be the link's path to the shell too — a space or a quote in
    /// uDeck's folder included.
    @Test("the rm link prints is one the shell reads as the link's path, and nothing else")
    func undoIsQuoted() async throws {
        let temp = TemporaryDirectory()
        defer { withExtendedLifetime(temp) {} }
        let folder = try await Self.made("greeter", in: temp, folder: "greeter-1")
        let home = temp.url.appendingPathComponent("it's my home/.udeck", isDirectory: true)
        let said = await udeckPlugin(["link", folder.path, "--home", home.path], in: temp.url, home: temp.url)
        #expect(said.status == 0, "\(said.errors)")
        let link = home.appendingPathComponent("plugins/greeter").path
        let quoted = PluginLink.shellQuoted(link)
        #expect(quoted == "'" + link.replacingOccurrences(of: "'", with: #"'\''"#) + "'")
        #expect(said.output.contains("to undo it: rm \(quoted) (the link goes; the folder it points at stays as it is)"),
                "\(said.output)")
        #expect(try Self.shellReads(quoted) == [link])

        // And the same when a link to another folder is in the way.
        let other = try await Self.made("greeter", in: temp, folder: "greeter-2")
        let refused = await udeckPlugin(["link", other.path, "--home", home.path], in: temp.url, home: temp.url)
        #expect(refused.status == 1)
        #expect(refused.errors.first?.contains("take it away first (rm \(quoted) -- that takes the link") == true, "\(refused.errors)")
    }

    /// The words `sh` makes of `text`, each ended by a NUL byte, which no
    /// path holds.
    static func shellReads(_ text: String) throws -> [String] {
        let read = try Subprocess.run(["sh", "-c", "for word in " + text + "; do printf '%s\\000' \"$word\"; done"],
                                      environment: ["PATH": "/usr/bin:/bin"])
        #expect(read.status == 0)
        return read.output.split(separator: 0, omittingEmptySubsequences: false).dropLast().map { String(decoding: $0, as: UTF8.self) }
    }

    @Test("a path is quoted for the shell only when it has to be, and always comes back as it was", arguments: [
        "/plain/path-1.2_x+y,z:w@v%u=t", "/with space", "/it's", "/''", "/tab\there", "/new\nline", "/$HOME", "/`date`", "/a;b",
        "/a*b?[c]", "/ünï cödé", "~", "/a\\b", "-n",
    ])
    func shellQuoting(_ path: String) throws {
        let quoted = PluginLink.shellQuoted(path)
        #expect(try Self.shellReads(quoted) == [path], "\(quoted)")
        let plain = path.utf8.allSatisfy { "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/._-+,:@%=".utf8.contains($0) }
        #expect((quoted == path) == plain, "\(quoted)")
    }

    @Test("--home that is empty is wrong usage: it would be the current folder, and nothing is made there",
          arguments: [["link", "work/greeter", "--home="], ["link", "work/greeter", "--home", ""],
                      ["run", "work/greeter", "--home="], ["run", "work/greeter", "--home", ""]])
    func emptyHome(_ arguments: [String]) async throws {
        let temp = TemporaryDirectory()
        defer { withExtendedLifetime(temp) {} }
        _ = try await Self.made("greeter", in: temp)
        let before = everything(in: temp.url)
        let said = await udeckPlugin(arguments, in: temp.url, home: temp.url)
        #expect(said.status == 2, "\(arguments)")
        #expect(said.errors.first?.hasPrefix("udeck-plugin \(arguments[0]): --home is uDeck's folder, and an empty one names none\n") == true,
                "\(said.errors)")
        #expect(everything(in: temp.url) == before, "\(arguments)")
    }

    /// uDeck reads `UDECK_HOME` before `~/.udeck`, and a link made anywhere
    /// else is one it never looks at.
    @Test("without --home, link goes where uDeck looks: UDECK_HOME when it is set, ~/.udeck when it is not")
    func udeckHome() async throws {
        let temp = TemporaryDirectory()
        defer { withExtendedLifetime(temp) {} }
        let folder = try await Self.made("greeter", in: temp)
        let target = try #require(PluginLink.realPath(folder.path))
        let user = temp.url.appendingPathComponent("someone", isDirectory: true)
        let other = temp.url.appendingPathComponent("other's home", isDirectory: true)
        let homes = UserHomes.only(user, others: ["other": other])
        let cases: [(String, URL)] = [
            (temp.url.appendingPathComponent("moved").path, temp.url.appendingPathComponent("moved")),
            ("~/elsewhere", user.appendingPathComponent("elsewhere")),
            ("~", user),
            ("~other/deck", other.appendingPathComponent("deck")),
            ("~other", other),
            ("relative/udeck", temp.url.appendingPathComponent("relative/udeck")),
            ("", user.appendingPathComponent(".udeck")),
        ]
        for (moved, expected) in cases {
            let said = await udeckPlugin(["link", folder.path], in: temp.url, home: user, extra: ["UDECK_HOME": moved], homes: homes)
            #expect(said.status == 0, "\(moved): \(said.errors)")
            let link = expected.appendingPathComponent("plugins/greeter")
            #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == target, "\(moved)")
            try? FileManager.default.removeItem(atPath: link.path)
        }

        // ~name of an account there is not: nothing is linked, and nothing is
        // made where a folder literally named ~nobody would be.
        let stranger = await udeckPlugin(["link", folder.path], in: temp.url, home: user, extra: ["UDECK_HOME": "~nobody/deck"],
                                         homes: homes)
        #expect(stranger.status == 2)
        #expect(stranger.errors.first == "udeck-plugin link: UDECK_HOME is ~nobody/deck, and this machine has no account "
                + "nobody for its ~nobody; say where uDeck's folder is with --home", "\(stranger.errors)")
        #expect(!FileManager.default.fileExists(atPath: temp.url.appendingPathComponent("~nobody").path))

        // CFFIXED_USER_HOME is every account's home to Foundation's ~name, as
        // it is the running account's: swift-foundation's
        // homeDirectoryPath(forUser:) reads it before the account database.
        let fixed = temp.url.appendingPathComponent("fixed", isDirectory: true)
        for moved in ["~other/deck", "~nobody/deck", "~/deck"] {
            let said = await udeckPlugin(["link", folder.path], in: temp.url, home: user,
                                         extra: ["UDECK_HOME": moved, "CFFIXED_USER_HOME": fixed.path], homes: homes)
            #expect(said.status == 0, "\(moved): \(said.errors)")
            let link = fixed.appendingPathComponent("deck/plugins/greeter")
            #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == target, "\(moved)")
            try? FileManager.default.removeItem(atPath: link.path)
        }
        #expect(!FileManager.default.fileExists(atPath: other.appendingPathComponent("deck/plugins/greeter").path))
        #expect(homes.account(named: "other", in: ["CFFIXED_USER_HOME": ""]) == other.path, "an empty one is not set")

        // No home folder: an absolute UDECK_HOME is enough, and one that needs one is not.
        var errors: [String] = []
        let absolute = temp.url.appendingPathComponent("absolute")
        let found = await Command.run(["link", folder.path], environment: ["UDECK_HOME": absolute.path],
                                      currentDirectory: temp.url.path, homes: .only(nil), output: { _ in },
                                      errors: { errors.append($0) })
        #expect(found == 0, "\(errors)")
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: absolute.appendingPathComponent("plugins/greeter").path)) == target)
        let lost = await Command.run(["link", folder.path], environment: ["UDECK_HOME": "~/x"], currentDirectory: temp.url.path,
                                     homes: .only(nil), output: { _ in }, errors: { errors.append($0) })
        #expect(lost == 2)
        #expect(errors.last?.contains("UDECK_HOME") == true, "\(errors)")
        #expect(!FileManager.default.fileExists(atPath: temp.url.appendingPathComponent("~").path))
    }

    /// Swift calls two spellings of `café` one string; a file system that
    /// keeps names as bytes — Linux's — calls them two folders.
    @Test("one path is another only byte for byte")
    func samePath() {
        let composed = "/work/caf\u{E9}"
        let decomposed = "/work/cafe\u{301}"
        #expect(composed == decomposed, "Swift's == is what the comparison must not be")
        #expect(!PluginLink.samePath(composed, decomposed))
        #expect(PluginLink.samePath(composed, "/work/caf\u{E9}"))
        #expect(!PluginLink.samePath("/work/a", "/work/a/"))
    }

    /// Where a file system keeps both spellings as two folders, a link to one
    /// is not a link to the other. A Mac's does not keep them apart, and there
    /// this has nothing to show.
    @Test("a link to one spelling of a name is not a link to the other")
    func twoSpellings() async throws {
        let temp = TemporaryDirectory()
        defer { withExtendedLifetime(temp) {} }
        let composed = try await Self.made("greeter", in: temp, folder: "caf\u{E9}")
        let decomposed = temp.url.appendingPathComponent("work/cafe\u{301}")
        guard (try? FileManager.default.copyItem(at: composed, to: decomposed)) != nil,
              let one = PluginLink.realPath(composed.path), let other = PluginLink.realPath(decomposed.path),
              !one.utf8.elementsEqual(other.utf8) else { return }
        let home = temp.url.appendingPathComponent("udeck").path
        #expect(await udeckPlugin(["link", composed.path, "--home", home], in: temp.url, home: temp.url).status == 0)
        let second = await udeckPlugin(["link", decomposed.path, "--home", home], in: temp.url, home: temp.url)
        #expect(second.status == 1, "\(second.output)")
        #expect(second.errors.first?.contains("is already a link, to \(one)") == true, "\(second.errors)")
    }

    @Test("link refuses what is not a plugin folder")
    func notAPluginFolder() async throws {
        let temp = TemporaryDirectory()
        defer { withExtendedLifetime(temp) {} }
        let home = temp.url.appendingPathComponent("udeck").path
        try Data("x".utf8).write(to: temp.url.appendingPathComponent("file"))
        try FileManager.default.createDirectory(at: temp.url.appendingPathComponent("empty"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: temp.url.appendingPathComponent("broken"), withIntermediateDirectories: true)
        try Data(#"{"id": "Not An Id"}"#.utf8).write(to: temp.url.appendingPathComponent("broken/manifest.json"))
        for (folder, said) in [("absent", "is not there"), ("file", "is not a folder"), ("empty", "has no manifest.json"),
                               ("broken", "is not a manifest uDeck can read")] {
            let result = await udeckPlugin(["link", folder, "--home", home], in: temp.url, home: temp.url)
            #expect(result.status == 2, "\(folder)")
            #expect(result.errors.first?.contains(said) == true, "\(folder): \(result.errors)")
        }
        #expect(!FileManager.default.fileExists(atPath: home))
        for arguments in [["link"], ["link", "a", "b"], ["link", "a", "--home"]] {
            #expect(await udeckPlugin(arguments, in: temp.url, home: temp.url).status == 2, "\(arguments)")
        }
    }
}

@Suite("What uDeck forgives in a card")
struct CardReviewTests {
    @Test("keys uDeck ignores are named where they are, with the key they were probably meant to be")
    func ignoredKeys() {
        let card = Data("""
            {"stat": "warn", "tll": 30, "chip": "x", "zzzzzz": 1,
             "rows": [{"txt": "a"}, {"meter": {"value": 0.5, "lable": "l"}}, {"list": [{"text": "a", "icno": "ok"}]},
                      {"spark": {"values": [1], "captoin": "c"}}, {"table": {"columns": [{"title": "a", "algin": "leading"}],
                      "rows": [], "row": []}}, {"canvas": {"kind": "svg", "hieght": 3}}, {"text": "fine"}, {"kv": ["a", "b"]}],
             "actions": [{"label": "x", "run": ["true"], "confrim": "?"}]}
            """.utf8)
        #expect(CardReview.forgiven(in: card) == [
            #""stat" is not a field uDeck reads, and it is ignored -- did you mean "state"?"#,
            #""tll" is not a field uDeck reads, and it is ignored -- did you mean "ttl"?"#,
            #""zzzzzz" is not a field uDeck reads, and it is ignored"#,
            #"rows[0] is of the type "txt", which uDeck does not draw: it shows a note in its place -- did you mean "text"?"#,
            #""rows[1].meter.lable" is not a field uDeck reads, and it is ignored -- did you mean "label"?"#,
            #""rows[2].list[0].icno" is not a field uDeck reads, and it is ignored -- did you mean "icon"?"#,
            #""rows[3].spark.captoin" is not a field uDeck reads, and it is ignored -- did you mean "caption"?"#,
            #""rows[4].table.row" is not a field uDeck reads, and it is ignored -- did you mean "rows"?"#,
            #""rows[4].table.columns[0].algin" is not a field uDeck reads, and it is ignored -- did you mean "align"?"#,
            #""rows[5].canvas.hieght" is not a field uDeck reads, and it is ignored -- did you mean "height"?"#,
            #""actions[0].confrim" is not a field uDeck reads, and it is ignored -- did you mean "confirm"?"#,
        ])
        // A card uDeck draws all the same, which is the trouble.
        guard case .card = PollExecution.read(card) else { Issue.record("uDeck does not read it as a card"); return }
    }

    @Test("a key given twice is said; a card that is all right, or not a card, has nothing to say")
    func repeatsAndNothing() {
        #expect(CardReview.forgiven(in: Data(#"{"rows": [], "rows": [{"text": "x"}]}"#.utf8))
                == [#"the card gives the field "rows" more than once in one object; uDeck reads one of the values and says nothing about the other"#])
        #expect(CardReview.forgiven(in: Data(#"  {"state": "ok", "rows": [{"kv": ["a", "b", "warn"]}], "ttl": 30}  "#.utf8)).isEmpty)
        #expect(CardReview.forgiven(in: Data("not json".utf8)).isEmpty)
        #expect(CardReview.forgiven(in: Data("[1]".utf8)).isEmpty)
    }

    @Test("an edit is a letter added, taken away, changed, or two swapped")
    func editDistance() {
        func distance(_ a: String, _ b: String) -> Int {
            CardReview.editDistance(Array(a.unicodeScalars), Array(b.unicodeScalars))
        }
        #expect(distance("stat", "state") == 1)
        #expect(distance("tll", "ttl") == 1)
        #expect(distance("lable", "label") == 1)
        #expect(distance("confrim", "confirm") == 1)
        #expect(distance("", "ttl") == 3)
        #expect(distance("rows", "rows") == 0)
        #expect(distance("chip", "state") == 5)
        #expect(CardReview.suggestion(for: "x", among: ["y", "ttl"]) == "", "one letter is no evidence of anything")
        #expect(CardReview.suggestion(for: "stte", among: ["chip", "state"]) == #" -- did you mean "state"?"#)
    }

    /// The registry as it would be after a release that brought `spark`,
    /// a release later that brought the list icon `dot`, and `minUDeck`
    /// read from 1.1.0.
    static let laterRegistry: [ContractFeature: ContractRelease] = {
        var registry = ContractFeatures.registry
        registry[.manifestField("minUDeck")] = .released(SemanticVersion(major: 1, minor: 1, patch: 0))
        registry[.row("spark")] = .released(SemanticVersion(major: 1, minor: 2, patch: 0))
        registry[.listIcon("dot")] = .released(SemanticVersion(major: 1, minor: 3, patch: 0))
        return registry
    }()

    static func card(_ text: String) -> StrictJSON.Object {
        StrictJSON.parse(Array(text.utf8)).value?.object ?? StrictJSON.Object(members: [])
    }

    @Test("a card that uses more than minUDeck promises is said, from whichever part of it is newest")
    func newerThanMinUDeck() {
        let spark = Self.card(#"{"rows": [{"text": "a"}, {"spark": [1, 2]}]}"#)
        let dot = Self.card(#"{"rows": [{"spark": [1]}, {"list": [{"text": "a", "icon": "dot"}]}]}"#)
        let plain = Self.card(#"{"state": "warn", "rows": [{"list": [{"text": "a", "icon": "ok"}]}]}"#)
        func said(_ card: StrictJSON.Object, _ minUDeck: String?) -> String? {
            ContractFeatures.cardNeedsNewerUDeck(card, minUDeck: minUDeck, registry: Self.laterRegistry)
        }
        #expect(said(spark, "1.0.0") == #"the card uses the row type "spark", which uDeck 1.2.0 brought, and "minUDeck" is "#
                + "1.0.0: an older uDeck would install the plugin and not draw that")
        #expect(said(spark, "1.2.0") == nil)
        #expect(said(spark, nil) == #"the card uses the row type "spark", which uDeck 1.2.0 brought, and the manifest "#
                + #"has no "minUDeck": an older uDeck would install the plugin and not draw that"#)
        #expect(said(dot, "1.2.0")?.hasPrefix(#"the card uses the list icon "dot", which uDeck 1.3.0 brought"#) == true)
        #expect(said(plain, nil) == nil)
        #expect(said(plain, "0.1.0") == nil)
        // With the registry as it is, every part of a card is as old as uDeck.
        #expect(ContractFeatures.cardNeedsNewerUDeck(dot, minUDeck: nil) == nil)
        #expect(ContractFeatures.used(byCard: Self.card(#"{"rows": [{"table": {"columns": [{"title": "a", "align": "trailing"}], "rows": []}}, {"kv": ["a", "b", "crit"]}], "actions": [{"label": "x", "run": ["y"], "confirm": null}]}"#))
                == [.cardField("rows"), .cardField("actions"), .row("table"), .row("kv"), .rowField(row: "table", field: "columns"),
                    .rowField(row: "table", field: "rows"), .rowField(row: "table.columns", field: "title"),
                    .rowField(row: "table.columns", field: "align"), .tableAlignment("trailing"), .cardState("crit"),
                    .actionField("label"), .actionField("run")])
    }

    /// Each card is past one limit, or none, and the sentences have to say so
    /// exactly when uDeck draws less than the card holds.
    static let cards: [(Card, String?)] = {
        let long = String(repeating: "x", count: 1001)
        let row = CardRow.text("a")
        let longest = String(repeating: "x", count: 1000)
        return [
            (Card(rows: [row, .keyValue(KeyValueRow(label: "a", value: "b")), .log(["a"])]), nil),
            // At each limit, and not past it: drawn whole.
            (Card(title: longest, rows: Array(repeating: .text(longest), count: 200),
                  actions: Array(repeating: CardAction(label: "a", run: Array(repeating: "w", count: 64)), count: 12)), nil),
            (Card(rows: [.list(Array(repeating: ListItem(text: "a"), count: 200)), .log(Array(repeating: "l", count: 200)),
                         .spark(SparkRow(values: Array(repeating: 1, count: 512))),
                         .table(CardTable(columns: Array(repeating: CardTableColumn(title: "c"), count: 12),
                                          rows: Array(repeating: Array(repeating: "1", count: 12), count: 200)))]), nil),
            (Card(rows: Array(repeating: row, count: 201)), "the card has 201 rows, and uDeck draws the first 200"),
            (Card(rows: [.list(Array(repeating: ListItem(text: "a"), count: 201))]), "rows[0] lists 201 items, and uDeck draws the first 200"),
            (Card(rows: [.table(CardTable(columns: Array(repeating: CardTableColumn(title: "c"), count: 13), rows: []))]),
             "rows[0] has 13 columns, and uDeck draws the first 12"),
            (Card(rows: [.table(CardTable(columns: [CardTableColumn(title: "c")], rows: Array(repeating: ["1"], count: 201)))]),
             "rows[0] has 201 table rows, and uDeck draws the first 200"),
            (Card(rows: [.table(CardTable(columns: [CardTableColumn(title: "c"), CardTableColumn(title: "d")], rows: [["1", "2", "3"]]))]),
             "rows[0].table.rows[0] has 3 cells for 2 columns, and uDeck draws 2"),
            (Card(rows: [.log(Array(repeating: "l", count: 201))]), "rows[0] has 201 log lines, and uDeck draws the first 200"),
            (Card(rows: [.spark(SparkRow(values: Array(repeating: 1, count: 513)))]), "rows[0] has 513 values, and uDeck draws the first 512"),
            (Card(actions: Array(repeating: CardAction(label: "a", run: ["true"]), count: 13)),
             "the card has 13 actions, and uDeck draws the first 12"),
            (Card(actions: [CardAction(label: "a", run: Array(repeating: "w", count: 65))]),
             "actions[0].run has 65 words, and uDeck keeps the first 64"),
            (Card(title: long), "uDeck draws at most 1000 characters of a piece of text, and cuts the rest of title (1001)"),
            (Card(rows: [.text(long)]), "uDeck draws at most 1000 characters of a piece of text, and cuts the rest of rows[0].text (1001)"),
            (Card(rows: [.keyValue(KeyValueRow(label: "a", value: long))]), "uDeck draws at most 1000 characters of a piece of text, and cuts the rest of rows[0].kv[1] (1001)"),
            (Card(rows: [.meter(MeterRow(value: 1, caption: long))]), "uDeck draws at most 1000 characters of a piece of text, and cuts the rest of rows[0].meter.caption (1001)"),
            (Card(rows: [.canvas(CanvasRow(kind: "svg", payload: long))]), "uDeck draws at most 1000 characters of a piece of text, and cuts the rest of rows[0].canvas.payload (1001)"),
            (Card(rows: [.unsupported(kind: long)]), "uDeck draws at most 1000 characters of a piece of text, and cuts the rest of the name of the type of rows[0] (1001)"),
            (Card(actions: [CardAction(label: "a", run: ["true"], confirm: long)]), "uDeck draws at most 1000 characters of a piece of text, and cuts the rest of actions[0].confirm (1001)"),
        ]
    }()

    @Test("what uDeck cuts is said exactly when it cuts something")
    func cut() {
        for (card, sentence) in Self.cards {
            let said = CardReview.cut(from: card)
            #expect(said.isEmpty == (card.withinDrawingLimits() == card), "\(said)")
            #expect(said == (sentence.map { [$0] } ?? []))
        }
    }
}

@Suite("A folder before and after a run")
struct FolderSnapshotTests {
    @Test("what was added, taken away or changed — content or executable bit — and not what was only touched")
    func changes() throws {
        let temp = TemporaryDirectory()
        defer { withExtendedLifetime(temp) {} }
        let manager = FileManager.default
        let folder = temp.url.appendingPathComponent("plugin", isDirectory: true)
        try manager.createDirectory(at: folder.appendingPathComponent("sub"), withIntermediateDirectories: true)
        for name in ["a.txt", "sub/b.txt", "touched.txt", ".hidden"] {
            try Data(name.utf8).write(to: folder.appendingPathComponent(name))
        }
        try manager.createSymbolicLink(atPath: folder.appendingPathComponent("link").path, withDestinationPath: "a.txt")
        let before = try #require(FolderSnapshot.of(folder))

        try Data("changed".utf8).write(to: folder.appendingPathComponent("a.txt"))
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.appendingPathComponent("sub/b.txt").path)
        try manager.setAttributes([.modificationDate: Date().addingTimeInterval(-86400)],
                                  ofItemAtPath: folder.appendingPathComponent("touched.txt").path)
        try manager.removeItem(at: folder.appendingPathComponent("link"))
        try manager.createDirectory(at: folder.appendingPathComponent("__pycache__"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: folder.appendingPathComponent("__pycache__/m.pyc"))
        try Data("y".utf8).write(to: folder.appendingPathComponent(".hidden"))
        let after = try #require(FolderSnapshot.of(folder))

        let changes = before.changes(to: after)
        #expect(changes.added == ["__pycache__", "__pycache__/m.pyc"])
        #expect(changes.removed == ["link"])
        #expect(changes.changed == [".hidden", "a.txt", "sub/b.txt"])
        #expect(before.changes(to: before) == ([], [], []))
    }

    /// Two spellings of one name are one Swift string and, on Linux, two
    /// files: a producer that wrote the other one wrote a file.
    @Test("paths, and where a link points, are compared byte for byte")
    func bytes() {
        let composed = Array("caf\u{E9}".utf8)
        let decomposed = Array("cafe\u{301}".utf8)
        let one = FolderSnapshot(entries: [composed: .file(blob: "b", executable: false), Array("link".utf8): .link(composed)])
        let other = FolderSnapshot(entries: [decomposed: .file(blob: "b", executable: false), Array("link".utf8): .link(decomposed)])
        let changes = one.changes(to: other)
        #expect(changes.added == ["cafe\u{301}"] && changes.added.first?.unicodeScalars.count == 5)
        #expect(changes.removed == ["caf\u{E9}"] && changes.removed.first?.unicodeScalars.count == 4)
        #expect(changes.changed == ["link"])
    }
}

@Suite("udeck-plugin run", .serialized)
struct RunPluginTests {
    /// A plugin of the test's own, in `temp/plugins/<id>`: `script` is all it runs.
    @discardableResult
    static func plugin(_ temp: TemporaryDirectory, _ id: String, timeout: String = "2", extra: String = "",
                       script: String) -> URL {
        temp.writePlugin(folder: id, manifest: """
            { "id": "\(id)", "name": "\(id)", "version": "1.0.0", "api": 1, "kind": "poll",
              "run": ["./run.sh"], "interval": 5, "timeout": \(timeout)\(extra) }
            """, script: (name: "run.sh", body: "#!/bin/sh\n" + script + "\n", executable: true))
    }

    #if canImport(Darwin)
    @Test("run runs the producer in its folder, with uDeck's environment and nothing else")
    func environment() async throws {
        let temp = TemporaryDirectory()
        defer { withExtendedLifetime(temp) {} }
        let folder = Self.plugin(temp, "env", script: """
            env > "$UDECK_CACHE_DIR/env.txt"
            pwd -P > "$UDECK_CACHE_DIR/pwd.txt"
            printf '{"rows": [{"text": "ok"}]}'
            """)
        let home = temp.url.appendingPathComponent("udeck", isDirectory: true)
        let account = temp.url.appendingPathComponent("someone", isDirectory: true)
        let report = try await PluginTrial.run(folder, options: PluginTrial.Options(
            home: home, language: "ru", reason: .manual,
            environment: ["HOME": "/Users/nobody-at-all", "TMPDIR": "/private/tmp/somewhere/", "SECRET": "leaked"],
            homes: .only(account)))
        guard case .card = report.execution else { Issue.record("\(report.execution)"); return }
        #expect(!report.homeIsTemporary)

        let cache = home.appendingPathComponent("cache/env")
        let handed = try String(contentsOf: cache.appendingPathComponent("env.txt"), encoding: .utf8)
            .split(separator: "\n").reduce(into: [String: String]()) { all, line in
                let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                all[String(parts[0])] = parts.count > 1 ? String(parts[1]) : ""
            }
        #expect(handed["UDECK_CACHE_DIR"] == cache.path)
        #expect(handed["UDECK_PLUGIN_DIR"] == folder.path)
        #expect(handed["UDECK_PLUGIN_ID"] == "env")
        #expect(handed["UDECK_LANG"] == "ru")
        #expect(handed["UDECK_REFRESH_REASON"] == "manual")
        #expect(handed["UDECK_APPEARANCE"] == "dark")
        #expect(handed["UDECK_API"] == "1")
        #expect(handed["PATH"] == PluginEnvironment.defaultSearchPath.joined(separator: ":"))
        #expect(handed["HOME"] == account.path, "the account's, as uDeck hands it, not the shell's")
        #expect(handed["TMPDIR"] == "/private/tmp/somewhere/")
        #expect(handed["LANG"] == "en_US.UTF-8")
        #expect(handed["LC_ALL"] == "en_US.UTF-8")
        // What the shell adds of its own, and nothing from anywhere else.
        let ownShell: Set<String> = ["PWD", "SHLVL", "_", "OLDPWD"]
        #expect(Set(handed.keys).subtracting(ownShell) == Set(report.environment.keys), "\(handed.keys.sorted())")
        for (name, value) in report.environment { #expect(handed[name] == value, "\(name)") }
        #expect(handed["SECRET"] == nil)
        let directory = try String(contentsOf: cache.appendingPathComponent("pwd.txt"), encoding: .utf8)
        #expect(directory == (PluginLink.realPath(folder.path) ?? "") + "\n")
    }

    /// uDeck hands a producer `NSHomeDirectory()` as `HOME`: the account's
    /// home folder, not whatever `HOME` the shell that started uDeck had. A
    /// run that handed the shell's would try a producer in a home uDeck
    /// never gives it.
    @Test("run hands the producer the account's home folder as HOME, as uDeck does, and the shell's only without one")
    func homeIsTheAccounts() async throws {
        let temp = TemporaryDirectory()
        defer { withExtendedLifetime(temp) {} }
        let folder = Self.plugin(temp, "home", script: #"printf '{"rows": [{"text": "%s"}]}' "$HOME""#)
        let account = temp.url.appendingPathComponent("someone", isDirectory: true).path
        let fixed = temp.url.appendingPathComponent("fixed", isDirectory: true).path
        let cases: [([String: String], UserHomes, String)] = [
            (["HOME": "/shell"], .only(URL(fileURLWithPath: account)), account),
            (["HOME": "/shell", "CFFIXED_USER_HOME": fixed], .only(URL(fileURLWithPath: account)), fixed),
            (["HOME": "/shell", "CFFIXED_USER_HOME": ""], .only(URL(fileURLWithPath: account)), account),
            (["HOME": "/shell"], .only(nil), "/shell"),
            ([:], .only(nil), "/var/empty"),
        ]
        for (environment, homes, expected) in cases {
            let report = try await PluginTrial.run(folder, options: PluginTrial.Options(environment: environment, homes: homes))
            #expect(report.environment["HOME"] == expected, "\(environment)")
            guard case .card(let card) = report.execution else { Issue.record("\(report.execution)"); continue }
            #expect(card.rows == [.text(expected)], "\(environment)")
        }

        // Through the command, as an author runs it.
        let said = await udeckPlugin(["run", folder.path], in: temp.url, home: URL(fileURLWithPath: "/shell"),
                                     homes: .only(URL(fileURLWithPath: account)))
        #expect(said.status == 0, "\(said.errors)")
        #expect(said.output.contains { $0.contains("\"text\" : \"\(account)\"") }, "\(said.output)")
    }

    /// The plugin `new` makes is the first one an author runs: it has to draw
    /// its card, in both of its languages, with nothing for uDeck to forgive.
    @Test("what new makes runs as uDeck runs it, and draws its card with nothing to forgive")
    func newPluginRuns() async throws {
        let temp = TemporaryDirectory()
        defer { withExtendedLifetime(temp) {} }
        #expect(await udeckPlugin(["new", "fresh", "--author", "A"], in: temp.url, home: temp.url).status == 0)
        for (language, greeting) in [("en", "Hello!"), ("ru", "Привет!")] {
            let said = await udeckPlugin(["run", "fresh", "--lang", language], in: temp.url, home: temp.url)
            #expect(said.status == 0, "\(said.output)")
            #expect(said.output.last == "ran fresh: a card, 0 warnings", "\(said.output)")
            #expect(said.output.contains("stderr: nothing"))
            #expect(said.output.contains { $0.contains(greeting) }, "\(language): \(said.output)")
        }
    }

    /// Its producer builds the card's JSON from values it does not control;
    /// whatever a value holds, the card is still one uDeck reads.
    @Test("the producer new makes keeps any value a JSON string")
    func newPluginEscapes() async throws {
        let temp = TemporaryDirectory()
        defer { withExtendedLifetime(temp) {} }
        #expect(await udeckPlugin(["new", "fresh", "--author", "A"], in: temp.url, home: temp.url).status == 0)
        let folder = temp.url.appendingPathComponent("fresh")
        let plugin = PluginDiscovery(searchPath: PluginEnvironment.defaultSearchPath).load(folder)
        let manifest = try #require(plugin.manifest)
        let executable = try #require(plugin.executable)
        var environment = PluginEnvironment.producer(
            manifest: manifest, directory: folder, settings: PluginSettings(), cacheDirectory: temp.url,
            searchPath: PluginEnvironment.defaultSearchPath, appearance: .panel, reason: .manual, language: "en",
            home: temp.url.path, temporaryDirectory: nil)
        environment["UDECK_REFRESH_REASON"] = "a\"b\\c\td\u{1}e\nf"
        let result = await ProcessRunner().run(producerOf: plugin, manifest: manifest, executable: executable,
                                               environment: environment)
        guard case .card(let card) = PollExecution.read(result.standardOutput) else {
            Issue.record("not a card: \(String(decoding: result.standardOutput, as: UTF8.self))"); return
        }
        #expect(card.rows.last == .keyValue(KeyValueRow(label: "refreshed because", value: "a\"b\\c de f")))
    }

    @Test("without --home, the run has a uDeck folder of its own, and takes it away after")
    func temporaryHome() async throws {
        let temp = TemporaryDirectory()
        defer { withExtendedLifetime(temp) {} }
        let folder = Self.plugin(temp, "cached", script: #"touch "$UDECK_CACHE_DIR/ran"; printf '{"rows": []}'"#)
        let report = try await PluginTrial.run(folder, options: PluginTrial.Options(environment: [:]))
        #expect(report.homeIsTemporary)
        #expect(report.home.deletingLastPathComponent().path == ScratchFolder.home.path)
        #expect(report.home.lastPathComponent.hasPrefix(ScratchFolder.runPrefix))
        #expect(report.environment["UDECK_CACHE_DIR"] == report.home.appendingPathComponent("cache/cached").path)
        #expect(!FileManager.default.fileExists(atPath: report.home.path), "the run's folder is still there")
        guard case .card = report.execution else { Issue.record("\(report.execution)"); return }
    }

    @Test("run says what uDeck forgives: an ignored key, a row it does not draw, a cut, a write into the plugin's own folder")
    func forgiven() async throws {
        let temp = TemporaryDirectory()
        defer { withExtendedLifetime(temp) {} }
        Self.plugin(temp, "sloppy", script: """
            : > ./state.txt
            printf '{"stat": "warn", "tll": 30, "rows": [{"txt": "x"}'
            i=0; while [ $i -lt 200 ]; do printf ', {"text": "r"}'; i=$((i + 1)); done
            printf ']}'
            """)
        let said = await udeckPlugin(["run", "plugins/sloppy"], in: temp.url, home: temp.url)
        #expect(said.status == 0, "uDeck draws a card, so the run is a card: \(said.output)")
        let warnings = said.output.filter { $0.hasPrefix("warning: ") }
        #expect(warnings == [
            #"warning: "stat" is not a field uDeck reads, and it is ignored -- did you mean "state"?"#,
            #"warning: "tll" is not a field uDeck reads, and it is ignored -- did you mean "ttl"?"#,
            #"warning: rows[0] is of the type "txt", which uDeck does not draw: it shows a note in its place -- did you mean "text"?"#,
            "warning: the card has 201 rows, and uDeck draws the first 200",
            "warning: the producer wrote into its own folder -- added state.txt. Installed from a repository, the plugin "
                + "would be Modified locally after every run; write into UDECK_CACHE_DIR instead",
        ])
        #expect(said.output.last == "ran plugins/sloppy: a card, 5 warnings")
        #expect(said.output.contains("uDeck draws the card:"))
    }

    @Test("a card printed before the timeout is a card uDeck draws and a failure it counts")
    func lateCard() async throws {
        let temp = TemporaryDirectory()
        defer { withExtendedLifetime(temp) {} }
        Self.plugin(temp, "late", timeout: "0.5", script: #"printf '{"rows": [{"text": "early"}]}'; sleep 30"#)
        let said = await udeckPlugin(["run", "plugins/late"], in: temp.url, home: temp.url)
        #expect(said.status == 1)
        #expect(said.output.contains("ended: stopped by uDeck after 0.5 s, its timeout"))
        #expect(said.output.contains("uDeck draws the card, and counts a failure: the producer did not answer within 0.5s and was stopped"))
        #expect(said.output.contains { $0.hasPrefix("warning: the producer printed its card and then ran on past its timeout") })
        #expect(said.output.last == "ran plugins/late: a failure, 1 warning")
    }

    @Test("a failure is said in uDeck's words, with every line of stderr")
    func failure() async throws {
        let temp = TemporaryDirectory()
        defer { withExtendedLifetime(temp) {} }
        Self.plugin(temp, "angry", script: #"printf 'one\n  two\n' >&2; exit 3"#)
        let said = await udeckPlugin(["run", "plugins/angry"], in: temp.url, home: temp.url)
        #expect(said.status == 1)
        let from = try #require(said.output.firstIndex(of: "ended: exit status 3"))
        #expect(Array(said.output[from...]) == [
            "ended: exit status 3", "stdout: 0 bytes", "stderr: 10 bytes, 2 lines:", "  | one", "  |   two",
            "uDeck shows a failure: the producer exited with status 3", "ran plugins/angry: a failure, 0 warnings",
        ])
    }

    @Test("what it asks before running, and where the stderr of a good run goes, are said too")
    func notes() async throws {
        let temp = TemporaryDirectory()
        defer { withExtendedLifetime(temp) {} }
        Self.plugin(temp, "asking", extra: #", "permissions": {"exec": ["sysctl"], "read": ["~/x"]}"#,
                    script: #"echo 'a diagnostic' >&2; printf '{"rows": []}'"#)
        let said = await udeckPlugin(["run", "plugins/asking"], in: temp.url, home: temp.url)
        #expect(said.status == 0)
        #expect(said.output.contains("note: uDeck asks before it first runs the plugin, and again for every new version: "
                                     + "may it read files matching ~/x, run sysctl? This run did not ask"), "\(said.output)")
        #expect(said.output.contains("note: uDeck keeps the standard error of a run that printed a card, as of any run, "
                                     + "and writes it into the plugin's run log when the plugin is a linked folder and the "
                                     + "run log is on (logs/asking.log in uDeck's folder); Settings shows the standard "
                                     + "error of a failed run only"), "\(said.output)")
        #expect(said.output.contains("  | a diagnostic"))
    }

    @Test("what uDeck notes against a plugin it runs all the same is said, and the run goes on")
    func notesAgainstThePlugin() async throws {
        let temp = TemporaryDirectory()
        defer { withExtendedLifetime(temp) {} }
        let folder = Self.plugin(temp, "noted", script: #"printf '{"rows": []}'"#)
        try Data("{ not json".utf8).write(to: folder.appendingPathComponent("manifest.ru.json"))
        let problems = PluginDiscovery(searchPath: PluginEnvironment.defaultSearchPath).load(folder).problems
        #expect(problems.count == 1 && problems.allSatisfy { !$0.isFatal }, "\(problems)")
        let said = await udeckPlugin(["run", "plugins/noted"], in: temp.url, home: temp.url)
        #expect(said.status == 0, "\(said.output)")
        #expect(said.output.contains("note: uDeck notes against the plugin: \(problems[0])"), "\(said.output)")
        #expect(said.output.contains { $0.hasPrefix("note: uDeck notes against the plugin: manifest.ru.json is not valid") })
        #expect(said.output.last == "ran plugins/noted: a card, 0 warnings")
    }

    @Test("a run uDeck draws a card from is said to be slow past half of its timeout, and only then")
    func slowness() {
        let card = PollExecution.card(Card())
        let said = "the run took more than half of its 2.0 s timeout"
        #expect(PluginTrial.slowness(duration: 1.01, timeout: 2, execution: card) == said)
        #expect(PluginTrial.slowness(duration: 1.9, timeout: 2, execution: card) == said)
        #expect(PluginTrial.slowness(duration: 1, timeout: 2, execution: card) == nil)
        #expect(PluginTrial.slowness(duration: 0.2, timeout: 2, execution: card) == nil)
        #expect(PluginTrial.slowness(duration: 0.3, timeout: 0.5, execution: card) == "the run took more than half of its 0.5 s timeout")
        #expect(PluginTrial.slowness(duration: 1.5, timeout: nil, execution: card) == nil)
        let failure = PluginFailure(reason: .timedOut(after: 2))
        #expect(PluginTrial.slowness(duration: 1.5, timeout: 2, execution: .failure(failure)) == nil,
                "a failure is said as one, and not as slow")
        #expect(PluginTrial.slowness(duration: 2.5, timeout: 2, execution: .lateCard(Card(), failure)) == nil)
    }

    @Test("standard output dropped past the limit is said, unless the run was stopped for it and its failure says so")
    func droppedSaid() {
        func result(_ termination: Termination, output: Int, error: Int) -> ProcessRunResult {
            ProcessRunResult(standardOutput: Data(), standardError: Data(), termination: termination, duration: 0,
                             standardOutputDropped: output, standardErrorDropped: error)
        }
        let start = "uDeck keeps 1000 bytes of a run's standard output, and dropped the rest without a word: "
        #expect(PluginTrial.dropped(from: result(.exited(code: 0), output: 1, error: 0), limit: 1000) == start + "1 byte")
        #expect(PluginTrial.dropped(from: result(.exited(code: 3), output: 2, error: 3), limit: 1000) == start + "2 bytes")
        #expect(PluginTrial.dropped(from: result(.exited(code: 0), output: 0, error: 51), limit: 1000) == nil,
                "standard error has no limit to go past: what came before its tail is a note")
        #expect(PluginTrial.dropped(from: result(.exited(code: 0), output: 0, error: 0), limit: 1000) == nil)
        #expect(PluginTrial.dropped(from: result(.outputLimitExceeded(bytes: 2000), output: 1000, error: 0), limit: 1000) == nil)
    }

    @Test("run says how much of standard output the limit dropped, and how much of standard error came before its tail")
    func droppedShown() async throws {
        let temp = TemporaryDirectory()
        defer { withExtendedLifetime(temp) {} }
        Self.plugin(temp, "flood", script: #"printf '{"rows": []}'; head -c 1100000 /dev/zero | tr '\000' e >&2"#)
        let said = await udeckPlugin(["run", "plugins/flood"], in: temp.url, home: temp.url)
        let kept = ProcessRunner.defaultStandardErrorTail
        #expect(said.status == 0, "a megabyte of standard error stops nothing: \(said.output.filter { !$0.hasPrefix("  |") })")
        #expect(said.output.contains("stderr: \(kept) bytes, 1 line (its end: the \(1_100_000 - kept) bytes before it, dropped):"),
                "\(said.output.filter { !$0.hasPrefix("  |") })")
        #expect(said.output.contains("note: uDeck keeps the last \(kept) bytes of a run's standard error; the "
                                     + "\(1_100_000 - kept) before them were not kept"))
        #expect(said.output.contains("ended: exit status 0"))
        #expect(!said.output.contains { $0.hasPrefix("warning: uDeck keeps") })

        Self.plugin(temp, "spill", script: #"/usr/bin/perl -e 'print "o" x 1100000'"#)
        let spilt = await udeckPlugin(["run", "plugins/spill"], in: temp.url, home: temp.url)
        let stdout = try #require(spilt.output.first { $0.hasPrefix("stdout: ") }, "\(spilt.output)")
        #expect(stdout.hasPrefix("stdout: \(1 << 20) bytes (and "), "\(stdout)")
        #expect(stdout.hasSuffix(" bytes past the output limit, dropped)"), "\(stdout)")
        #expect(spilt.output.contains("stderr: nothing"))
    }

    @Test("with --home, the settings' values are the ones kept there")
    func settingsFromHome() async throws {
        let temp = TemporaryDirectory()
        defer { withExtendedLifetime(temp) {} }
        let folder = Self.plugin(temp, "greeter",
                                 extra: #", "settings": [{"key": "greeting", "type": "string", "default": "Hello", "label": "Greeting"}]"#,
                                 script: #"printf '{"rows": [{"text": %s}]}' "$UDECK_SETTING_GREETING""#)
        let home = temp.url.appendingPathComponent("udeck", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let id = try #require(PluginIdentifier(rawValue: "greeter"))
        var settings = PluginSettings()
        settings.set(.string("Privet"), for: "greeting", plugin: id)
        try JSONEncoder().encode(settings).write(to: home.appendingPathComponent("plugin-settings.json"))

        let kept = try await PluginTrial.run(folder, options: PluginTrial.Options(home: home, environment: [:]))
        guard case .card(let chosen) = kept.execution else { Issue.record("\(kept.execution)"); return }
        #expect(chosen.rows == [.text("Privet")])
        let fresh = try await PluginTrial.run(folder, options: PluginTrial.Options(environment: [:]))
        guard case .card(let card) = fresh.execution else { Issue.record("\(fresh.execution)"); return }
        #expect(card.rows == [.text("Hello")])

        try Data("{ broken".utf8).write(to: home.appendingPathComponent("plugin-settings.json"))
        let said = await udeckPlugin(["run", folder.path, "--home", home.path], in: temp.url, home: temp.url)
        #expect(said.status == 2)
        #expect(said.errors.first?.contains("could not read \(home.appendingPathComponent("plugin-settings.json").path)") == true, "\(said.errors)")
        #expect(said.output.isEmpty, "\(said.output)")
    }

    /// uDeck looks up a bare command on the search path in its settings file;
    /// a run given uDeck's folder looks it up there too, and finds — or does
    /// not find — what uDeck would.
    @Test("with --home, a bare command is looked up on the search path uDeck's settings give, and PATH is it")
    func searchPathFromHome() async throws {
        let temp = TemporaryDirectory()
        defer { withExtendedLifetime(temp) {} }
        let tools = temp.url.appendingPathComponent("tools", isDirectory: true)
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        let greet = tools.appendingPathComponent("greet-from-tools")
        try Data("#!/bin/sh\nprintf '{\"rows\": [{\"text\": \"%s\"}]}' \"$PATH\"\n".utf8).write(to: greet)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: greet.path)
        let folder = temp.writePlugin(folder: "bare", manifest: """
            { "id": "bare", "name": "bare", "version": "1.0.0", "api": 1, "kind": "poll",
              "run": ["greet-from-tools"], "interval": 5, "timeout": 2 }
            """)
        let home = temp.url.appendingPathComponent("udeck", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let path = [tools.path, "/usr/bin", "/bin"]
        let settings = home.appendingPathComponent("settings.json")
        try JSONSerialization.data(withJSONObject: ["version": 1, "pluginExecutableSearchPath": path]).write(to: settings)

        let found = try await PluginTrial.run(folder, options: PluginTrial.Options(home: home, environment: [:]))
        guard case .card(let card) = found.execution else { Issue.record("\(found.execution)"); return }
        #expect(card.rows == [.text(path.joined(separator: ":"))], "the producer's PATH is the same search path")
        #expect(found.environment["PATH"] == path.joined(separator: ":"))

        // Not given uDeck's folder, the run has the default, and the command is not on it.
        do {
            _ = try await PluginTrial.run(folder, options: PluginTrial.Options(environment: [:]))
            Issue.record("a command only the settings' search path has was found without them")
        } catch let refusal as PluginTrial.Refusal {
            #expect(refusal.description.contains("greet-from-tools was not found on \(PluginEnvironment.defaultSearchPath.joined(separator: ":"))"),
                    "\(refusal.description)")
        }

        // An empty list, or none, is the default, as uDeck reads it.
        for written in [#"{"pluginExecutableSearchPath": []}"#, #"{"version": 1}"#] {
            try Data(written.utf8).write(to: settings)
            #expect(PluginTrial.searchPath(in: UDeckPaths(root: home)) == .notThere, "\(written)")
        }

        // A file uDeck cannot read: the default, and a note that says why.
        try Data(#"{"pluginExecutableSearchPath": "/usr/bin"}"#.utf8).write(to: settings)
        let said = await udeckPlugin(["run", folder.path, "--home", home.path], in: temp.url, home: temp.url)
        #expect(said.status == 2, "\(said.output)")
        try Data("#!/bin/sh\nprintf '{\"rows\": []}'\n".utf8).write(to: greet)
        try Data(#"{"pluginExecutableSearchPath": 7}"#.utf8).write(to: settings)
        let local = temp.writePlugin(folder: "local", manifest: """
            { "id": "local", "name": "local", "version": "1.0.0", "api": 1, "kind": "poll",
              "run": ["./run.sh"], "interval": 5, "timeout": 2 }
            """, script: (name: "run.sh", body: "#!/bin/sh\nprintf '{\"rows\": []}'\n", executable: true))
        let noted = await udeckPlugin(["run", local.path, "--home", home.path], in: temp.url, home: temp.url)
        #expect(noted.status == 0, "\(noted.output)")
        #expect(noted.output.contains { $0.hasPrefix("note: \(settings.path) is not a settings file uDeck can read: ") && $0.hasSuffix(
            "; this run looked up commands on the default search path, as uDeck does while its settings cannot be read") },
                "\(noted.output)")
        #expect(noted.output.contains { $0.hasSuffix("PATH=\(PluginEnvironment.defaultSearchPath.joined(separator: ":"))") })
    }

    @Test("what uDeck would not run is not run")
    func notRun() async throws {
        let temp = TemporaryDirectory()
        defer { withExtendedLifetime(temp) {} }
        try FileManager.default.createDirectory(at: temp.url.appendingPathComponent("plugins/empty"), withIntermediateDirectories: true)
        temp.writePlugin(folder: "resident", manifest: """
            { "id": "resident", "name": "R", "version": "1.0.0", "api": 1, "kind": "resident", "run": ["./run.sh"] }
            """, script: (name: "run.sh", body: "#!/bin/sh\ntouch ran\n", executable: true))
        Self.plugin(temp, "misnamed", script: "touch ran")
        try FileManager.default.moveItem(at: temp.url.appendingPathComponent("plugins/misnamed"),
                                         to: temp.url.appendingPathComponent("plugins/other-name"))
        for (folder, said) in [("plugins/empty", "uDeck would not run it: "), ("plugins/resident", "uDeck would not run it: "),
                               ("plugins/other-name", "they must match"), ("plugins/absent", "uDeck would not run it: ")] {
            let result = await udeckPlugin(["run", folder], in: temp.url, home: temp.url)
            #expect(result.status == 2, "\(folder)")
            // On standard error, as new and link say why they did nothing.
            #expect(result.errors.first?.hasPrefix("udeck-plugin run: could not run \(folder): ") == true
                    && result.errors.first?.contains(said) == true, "\(folder): \(result.errors)")
            #expect(result.output.isEmpty, "\(folder): \(result.output)")
            #expect(!FileManager.default.fileExists(atPath: temp.url.appendingPathComponent(folder + "/ran").path))
        }
    }
    #else
    /// On Linux a plugin's run cannot be what uDeck's is, so it is not tried.
    @Test("on Linux, run says it takes a Mac, and runs nothing")
    func needsAMac() async throws {
        let temp = TemporaryDirectory()
        defer { withExtendedLifetime(temp) {} }
        Self.plugin(temp, "any", script: "touch ran; printf '{}'")
        let said = await udeckPlugin(["run", "plugins/any"], in: temp.url, home: temp.url)
        #expect(said.status == 2)
        #expect(said.errors.first?.contains("which takes a Mac") == true, "\(said.errors)")
        #expect(!FileManager.default.fileExists(atPath: temp.url.appendingPathComponent("plugins/any/ran").path))
    }
    #endif

    @Test("run with no folder, two, or an option that makes no sense is wrong usage", arguments: [
        ["run"], ["run", "a", "b"], ["run", "a", "--reason", "boredom"], ["run", "a", "--lang", ""], ["run", "a", "--lang", "e n"],
        ["run", "a", "--home"],
    ])
    func usage(_ arguments: [String]) async {
        let temp = TemporaryDirectory()
        defer { withExtendedLifetime(temp) {} }
        let said = await udeckPlugin(arguments, in: temp.url, home: temp.url)
        #expect(said.status == 2, "\(arguments)")
        #expect(said.errors.first?.contains("usage: udeck-plugin") == true, "\(arguments): \(said.errors)")
    }

    /// A run stopped by a signal leaves its uDeck folder behind; the next
    /// command takes it away as it starts, as it does a check's index.
    @Test("a stopped run's folder is taken away by the next command")
    func sweptAfterwards() async throws {
        let left = ScratchFolder.home
            .appendingPathComponent("\(ScratchFolder.runPrefix)\(Int32.max - 1)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: left.appendingPathComponent("cache/x"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: left) }
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-2 * ScratchFolder.leftAfter)],
                                              ofItemAtPath: left.path)
        let temp = TemporaryDirectory()
        defer { withExtendedLifetime(temp) {} }
        _ = await udeckPlugin(["check", temp.url.path], in: temp.url, home: temp.url)
        #expect(!FileManager.default.fileExists(atPath: left.path), "the folder a stopped run left is still there")
    }
}
