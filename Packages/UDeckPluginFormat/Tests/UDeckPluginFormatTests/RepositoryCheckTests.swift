import Foundation
import Testing
@testable import UDeckPluginFormat
import UDeckPluginFormatFixtures

/// The repository check beyond what the corpus replays: its three layers, the
/// sign-offs only for the official repository, the git it runs, and one folder
/// checked on its own. The version check is `VersionBumpTests`.
@Suite("The repository check")
struct RepositoryCheckTests {
    static let manifest = "plugins/sample/manifest.json"

    // MARK: - Layers

    /// What uDeck only ignores, the installable check passes; strict does not.
    @Test("the installable check says only what uDeck refuses; strict says the rest")
    func layers() throws {
        let repository = try TestRepository([
            "plugins/stray.txt": .text("not a folder\n"),
            "plugins/sample/README.md": nil,
            "plugins/sample/manifest.ru.json": nil,
            Self.manifest: try TestRepository.manifestText(["homepag": "https://example.com"], replacing: "\"api\" : 1,",
                                                           with: "\"api\" : 1.0,"),
            "plugins/sample/run.sh": .executable("#!/bin/sh\r\necho '{}'\r\n"),
            "udeck-plugins.json": .text(#"{"format": 1, "name": "Test", "descripton": "typo"}"#),
            ".gitattributes": .text("plugins/sample/run.sh export-ignore\n"),
        ])
        #expect(try repository.check(.installable).findings.isEmpty)
        #expect(try repository.check(.strict).keys == [
            "error passport udeck-plugins.json", "error 2 plugins/stray.txt", "error 9 plugins/sample/run.sh",
            "error 3 \(Self.manifest)", "error 12 \(Self.manifest)", "error 10 plugins/sample/README.md",
            "warning 11 plugins/sample", "error 13 plugins/sample/run.sh",
        ])
    }

    /// The official rules come only with --official, and --official is
    /// strict too.
    @Test("the official rules come only with --official, which is strict as well")
    func official() throws {
        let repository = try TestRepository([
            "plugins/sample/LICENSE": nil,
            "plugins/sample/data.bin": .bytes(Data([0, 1, 2])),
            "plugins/sample/README.md": nil,
        ])
        #expect(try repository.check(.strict).keys == ["error 10 plugins/sample/README.md"])
        #expect(try repository.check(.official).keys == [
            "error 10 plugins/sample/README.md", "error 14 plugins/sample/data.bin", "error 16 plugins/sample/LICENSE",
        ])
        #expect(CheckMode(official: true).strict)
    }

    /// uDeck refuses what the listing shows it cannot install, and so does
    /// the installable check, rule by rule.
    @Test("the installable check refuses what uDeck refuses", arguments: [
        ("udeck-plugins.json", nil, "error passport udeck-plugins.json"),
        (manifest, "{ not json", "error 3 \(manifest)"),
        ("plugins/sample/run.sh", "#!/bin/sh\n", "error 5 plugins/sample/run.sh"),
        ("plugins/sample/.env", "x\n", "error 7 plugins/sample/.env"),
        ("plugins/sample/data.txt", "version https://git-lfs.github.com/spec/v1\noid sha256:00\nsize 1\n",
         "error 9 plugins/sample/data.txt"),
    ] as [(String, String?, String)])
    func installable(_ path: String, _ content: String?, _ finding: String) throws {
        let repository = try TestRepository([path: content.map { .text($0) }])
        #expect(try repository.check(.installable).keys.contains(finding))
    }

    /// uDeck knows one LFS pointer exactly, as git-lfs writes it; the
    /// repository check knows its old name and any version too.
    @Test("an LFS pointer uDeck would not recognise is only the strict check's")
    func lfsPointers() throws {
        let repository = try TestRepository([
            "plugins/sample/data.txt": .text("version https://git-lfs.github.com/spec/v2\noid sha256:00\nsize 1\n"),
        ])
        #expect(try repository.check(.installable).findings.isEmpty)
        #expect(try repository.check(.strict).keys == ["error 9 plugins/sample/data.txt"])
    }

    /// `run[0]` that leaves the folder on its way — P05 — is refused in every
    /// layer, as uDeck refuses it; `restart` uDeck cannot decode — P10 — is
    /// rule 3, not only an unknown field.
    @Test("the two places the Python check was wrong are right in every layer")
    func pythonsTwoMistakes() throws {
        for mode in [CheckMode.installable, .strict] {
            let climbing = try TestRepository([Self.manifest: try TestRepository.manifest(["run": ["sub/../../sample/run.sh"]])])
            #expect(try climbing.check(mode).keys == ["error 5 \(Self.manifest)"], "\(mode)")
            let restart = try TestRepository([Self.manifest: try TestRepository.manifest(["restart": ["mode": "never"]])])
            #expect(try restart.check(mode).keys.contains("error 3 \(Self.manifest)"), "\(mode)")
        }
    }

    /// `restart` is read by uDeck's decoder and described by no part of the
    /// contract. uDeck installs a plugin with a whole one; the strict check
    /// calls it what Python called it, a field the contract does not define —
    /// and a partial one is rule 3 as well, since uDeck would not load it.
    @Test("restart: installable when uDeck can decode it, and rule 12 when strict")
    func restartOutsideTheContract() throws {
        let whole: [String: Any] = ["mode": "never", "initialBackoff": 1, "maximumBackoff": 60, "backoffFactor": 2]
        let decodable = try TestRepository([Self.manifest: try TestRepository.manifest(["restart": whole])])
        #expect(try decodable.check(.installable).findings.isEmpty, "uDeck installs it")
        let strict = try decodable.check(.strict)
        #expect(strict.keys == ["error 12 \(Self.manifest)"])
        #expect(strict.findings.map(\.message) == [
            "has the field \"restart\", which the plugin contract does not define -- uDeck reads it only for resident "
                + "plugins, which it does not run yet; leave it out",
        ])

        let partial = try TestRepository([Self.manifest: try TestRepository.manifest(["restart": ["mode": "never"]])])
        #expect(try partial.check(.installable).keys == ["error 3 \(Self.manifest)"])
        #expect(try partial.check(.strict).keys == ["error 3 \(Self.manifest)", "error 12 \(Self.manifest)"])

        // A field inside it that uDeck's decoder does not know either is said
        // as well, by its full name.
        var more = whole
        more["jitter"] = 1
        let extra = try TestRepository([Self.manifest: try TestRepository.manifest(["restart": more])])
        let said = try extra.check(.strict).findings.filter { $0.rule == "12" }.map(\.message)
        #expect(said.count == 2)
        #expect(said.contains { $0.hasPrefix("has the field \"restart.jitter\", which the plugin contract does not define") })
    }

    /// A field of the top level given as the wrong kind of value is said in
    /// words, each one, as the Python check said it — not left to the decoder,
    /// which stops at the first and names Swift's types.
    @Test("permissions, settings and window of the wrong kind are three findings, in words")
    func wrongKindsAtTheTop() throws {
        let repository = try TestRepository([Self.manifest: try TestRepository.manifest([
            "permissions": [Any](), "settings": [String: Any](), "window": 1,
        ])])
        let report = try repository.check(.strict)
        #expect(report.findings.filter { $0.rule == "3" }.map(\.message).sorted() == [
            "\"permissions\" must be an object, not a list",
            "\"settings\" must be a list, not an object",
            "\"window\" must be an object, not a number",
        ])
        #expect(report.findings.count == 3, "\(report.findings)")
    }

    /// Where JSONDecoder reads `4.0` as 4, the strict check wants a whole
    /// number written as one.
    @Test("strict JSON: a field twice, a byte order mark, a whole number written with a point")
    func strictJSON() throws {
        let twice = try TestRepository([Self.manifest: .text(#"{"id":"sample","id":"sample"}"#)])
        #expect(try twice.check(.strict).findings.contains { $0.message.contains("more than once") })
        let bom = try TestRepository(["udeck-plugins.json": .bytes(Data([0xEF, 0xBB, 0xBF]) + Data(#"{"format":1,"name":"x"}"#.utf8))])
        #expect(try bom.check(.installable).findings.isEmpty, "uDeck reads a byte order mark")
        #expect(try bom.check(.strict).keys == ["error passport udeck-plugins.json"])
        let point = try TestRepository([Self.manifest: try TestRepository.manifest(["window": ["defaultWidth": 4.5]])])
        #expect(try point.check(.installable).keys == ["error 3 \(Self.manifest)"])
        let pointZero = try TestRepository(["udeck-plugins.json": .text(#"{"format": 1.0, "name": "x"}"#)])
        #expect(try pointZero.check(.installable).findings.isEmpty)
        #expect(try pointZero.check(.strict).keys == ["error passport udeck-plugins.json"])
    }

    /// The passport's limit is uDeck's, and the check says it in every layer.
    @Test("a passport past 64 KiB is refused by the check as uDeck refuses it")
    func passportTooLarge() throws {
        let padding = String(repeating: "a", count: RepositoryPassport.maximumBytes)
        let repository = try TestRepository(["udeck-plugins.json": .text(#"{"format": 1, "name": "x", "padding": "\#(padding)"}"#)])
        for mode in [CheckMode.installable, .strict] {
            let findings = try repository.check(mode).findings
            #expect(findings.map(\.description) == [
                "error: udeck-plugins.json: it is \(padding.count + 41) bytes, and a passport may be at most 64 KiB "
                    + "(65536 bytes) [passport]",
            ], "\(mode)")
        }
    }

    /// A command of nothing but a line break is no command — uDeck would look
    /// for a program by that name and not find one.
    @Test("run[0] of only line breaks is rule 3, strictly")
    func blankCommand() throws {
        let repository = try TestRepository([Self.manifest: try TestRepository.manifest(["run": ["\n"]])])
        #expect(try repository.check(.strict).keys == ["error 3 \(Self.manifest)"])
        #expect(try repository.check(.installable).findings.isEmpty, "uDeck loads it, as it always has")
    }

    /// Said as what it is, once — not also as a licence that is not Apache's,
    /// which it is, from the line after the copyright on.
    @Test("a licence without its blank line is said to be exactly that")
    func licenceWithoutItsBlankLine() throws {
        let apache = try Data(contentsOf: Corpus.folder.appendingPathComponent("blobs/Apache-2.0.txt"))
        let repository = try TestRepository(["plugins/sample/LICENSE": .bytes(Data("Copyright 2026 Ada Lovelace\n".utf8) + apache)])
        #expect(try repository.check(.official).findings.map(\.message) == ["must have a blank line after the copyright line"])
        #expect(try repository.check(.strict).findings.isEmpty)
    }

    // MARK: - Rule 17: sign-offs, for the official repository only

    @Test("sign-offs are the official repository's rule, not a consequence of --base")
    func signOffsOnlyWhenOfficial() throws {
        let repository = try TestRepository()
        let base = try repository.git("rev-parse", "HEAD")
        let head = try repository.commit(["README.md": .text("# Changed\n")], message: "Change the README\n")
        #expect(try repository.check(.official, base: base, head: head).keys == ["error 17 commit \(head.prefix(12))"])
        #expect(try repository.check(.strict, base: base, head: head).findings.isEmpty)
        #expect(try repository.check(.installable, base: base, head: head).findings.isEmpty)
        #expect(try repository.check(.official).findings.isEmpty, "no base, no commits to take")
        #expect(throws: CheckFailure.self) { try repository.check(.official, base: base) }
    }

    @Test("a sign-off is the line git commit -s writes", arguments: [
        ("Signed-off-by: Ada Lovelace <ada@example.com>", true),
        ("Signed-off-by: Ada <a@b> \t", true),
        ("Signed-off-by: Ада <ada@example.com>", true),
        ("Signed-off-by: Ada Lovelace", false),
        ("Signed-off-by: <ada@example.com>", false),
        ("Signed-off-by: Ada <>", false),
        ("Signed-off-by: Ada <a b>", false),
        ("Signed-off-by: Ada  <ada@example.com>", false),
        ("Signed-off-by: Ada<ada@example.com>", false),
        ("Signed-off-by: Ada <ada@example.com>\r", false),
        ("Signed-off-by: Ada <ada@example.com> x", false),
        ("signed-off-by: Ada <ada@example.com>", false),
        (" Signed-off-by: Ada <ada@example.com>", false),
        ("Signed-off-by: A<da <ada@example.com>", false),
    ])
    func signOffLine(_ line: String, _ isSignOff: Bool) {
        #expect(OfficialRules.isSignOff(line.unicodeScalars) == isSignOff)
    }

    // MARK: - Git, told nothing by anybody's configuration

    /// A hook's environment, a personal configuration, a repository's own
    /// file-system monitor: none of them reaches the git the check runs.
    @Test("git runs with an environment of the check's own")
    func gitEnvironment() throws {
        let repository = try TestRepository()
        let marker = repository.temp.url.appendingPathComponent("monitor-ran")
        let monitor = repository.temp.url.appendingPathComponent("monitor")
        try Data("#!/bin/sh\ntouch '\(marker.path)'\n".utf8).write(to: monitor)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: monitor.path)
        try repository.git("config", "core.fsmonitor", monitor.path)
        let attributes = repository.temp.url.appendingPathComponent("attributes")
        try Data("* export-ignore\n".utf8).write(to: attributes)
        let personal = repository.temp.url.appendingPathComponent("gitconfig")
        try Data("[core]\n\tattributesFile = \(attributes.path)\n".utf8).write(to: personal)
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_CONFIG_GLOBAL"] = personal.path
        environment["GIT_DIR"] = "/nonexistent"
        environment["GIT_INDEX_FILE"] = "/nonexistent/index"
        environment["GIT_WORK_TREE"] = "/nonexistent"
        #expect(try repository.check(.strict, environment: environment).findings.isEmpty)
        // Checking one folder reads the working copy's index and asks git
        // which new files it would not ignore — what a file-system monitor
        // is there to answer.
        var options = RepositoryCheck.Options(mode: .strict, environment: environment)
        options.gitEnvironment["GIT_CEILING_DIRECTORIES"] = repository.temp.url.path
        let folder = try RepositoryCheck.folder(repository.folder.appendingPathComponent("plugins/sample").path, options: options)
        #expect(folder.findings.isEmpty)
        #expect(folder.commit != nil)
        #expect(!FileManager.default.fileExists(atPath: marker.path), "the repository's file-system monitor ran")
        // And it would have run, had the check let it: the test can see it.
        try repository.git("status", "--porcelain")
        #expect(FileManager.default.fileExists(atPath: marker.path), "the monitor never runs, so this proves nothing")

        let git = Git(repository: repository.folder.path, inherited: environment)
        #expect(git.environment["GIT_DIR"] == nil)
        #expect(git.environment["GIT_CONFIG_GLOBAL"] == "/dev/null")
        #expect(git.environment["GIT_CONFIG_NOSYSTEM"] == "1")
        #expect(git.environment["GIT_NO_LAZY_FETCH"] == "1")
        #expect(git.environment["GIT_ALLOW_PROTOCOL"] == "", "no transport at all")
        #expect(Git.switches.contains("core.hooksPath=/dev/null"))
        #expect(Git.switches.contains("core.sshCommand="))
        #expect(Git.switches.first == "--no-pager")
    }

    /// A clean filter the repository's own configuration names runs whenever
    /// git refreshes the index — as `git status` does for every file whose
    /// timestamps moved. Asking whether the working copy has changes must not
    /// run it.
    @Test("checking a folder in a working copy runs no clean filter the repository names")
    func noCleanFilter() throws {
        let repository = try TestRepository()
        let marker = repository.temp.url.appendingPathComponent("filter-ran")
        try repository.git("config", "filter.evil.clean", "touch '\(marker.path)'; cat")
        try repository.write([".gitattributes": .text("* filter=evil\n")])
        let readme = repository.folder.appendingPathComponent("plugins/sample/README.md")
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: readme.path)
        var options = RepositoryCheck.Options(mode: .strict)
        options.gitEnvironment["GIT_CEILING_DIRECTORIES"] = repository.temp.url.path
        let report = try RepositoryCheck.folder(readme.deletingLastPathComponent().path, options: options)
        #expect(report.commit != nil)
        #expect(report.notes.isEmpty, "only a timestamp moved: \(report.notes)")
        #expect(!FileManager.default.fileExists(atPath: marker.path), "the repository's clean filter ran")
        // And it would have run, had the check asked git status.
        try repository.git("status", "--porcelain")
        #expect(FileManager.default.fileExists(atPath: marker.path), "the filter never runs, so this proves nothing")
    }

    /// A partial clone fetches a missing object from its promisor remote over
    /// whatever transport and `ssh` command its configuration names — a
    /// program of the repository's choosing. The check fetches nothing: a
    /// missing blob is a check that could not be made.
    @Test("a missing object is not fetched: no transport, no ssh command, whatever the repository says")
    func noLazyFetch() throws {
        let repository = try TestRepository()
        let marker = repository.temp.url.appendingPathComponent("ssh-ran")
        for (key, value) in [("extensions.partialClone", "origin"), ("remote.origin.url", "ssh://example.invalid/x"),
                             ("remote.origin.promisor", "true"), ("core.sshCommand", "touch '\(marker.path)'; false"),
                             ("protocol.allow", "always"), ("protocol.ssh.allow", "always")] {
            try repository.git("config", key, value)
        }
        let blob = try repository.git("rev-parse", "HEAD:plugins/sample/README.md")
        try FileManager.default.removeItem(at: repository.folder.appendingPathComponent(
            ".git/objects/\(blob.prefix(2))/\(blob.dropFirst(2))"))
        func check(_ extra: [String: String]) {
            var options = RepositoryCheck.Options(mode: .installable)
            options.gitEnvironment = extra.merging(["GIT_CEILING_DIRECTORIES": repository.temp.url.path]) { new, _ in new }
            #expect(throws: CheckFailure.self, "\(extra)") { try RepositoryCheck.repository(repository.folder.path, options: options) }
            #expect(!FileManager.default.fileExists(atPath: marker.path), "the repository's ssh command ran: \(extra)")
        }
        check([:])
        // A git older than 2.44 fetches whatever GIT_NO_LAZY_FETCH says: no
        // transport is allowed to it.
        check(["GIT_NO_LAZY_FETCH": "0"])
        // And were ssh allowed, the command the repository names is not the one.
        check(["GIT_NO_LAZY_FETCH": "0", "GIT_ALLOW_PROTOCOL": "ssh"])
        // It would have run, had git been let fetch.
        _ = try? repository.git("cat-file", "-p", blob)
        #expect(FileManager.default.fileExists(atPath: marker.path), "the fetch never runs, so this proves nothing")

        // A transport that is a command of its own, with no ssh in it: only
        // the empty list of transports stands in its way on an older git.
        try FileManager.default.removeItem(at: marker)
        try repository.git("config", "remote.origin.url", "ext::sh -c touch% \(marker.path)")
        try repository.git("config", "protocol.ext.allow", "always")
        check([:])
        check(["GIT_NO_LAZY_FETCH": "0"])
        _ = try? repository.git("cat-file", "-p", blob)
        #expect(FileManager.default.fileExists(atPath: marker.path), "the ext transport never runs, so this proves nothing")
    }

    /// The passport is the first file read, and one the commit lists and the
    /// clone does not hold is a check that could not be made — not a passport
    /// that is not JSON, nor a submodule.
    @Test("a passport that is not in the clone is a check that could not be made, in every layer")
    func passportNotInTheClone() throws {
        let repository = try TestRepository()
        let blob = try repository.git("rev-parse", "HEAD:udeck-plugins.json")
        try FileManager.default.removeItem(at: repository.folder.appendingPathComponent(
            ".git/objects/\(blob.prefix(2))/\(blob.dropFirst(2))"))
        let said = "git could not read udeck-plugins.json (blob \(blob.prefix(12))): it is not in this clone — fetch "
            + "without a blob filter"
        #expect(Git.notInThisClone("udeck-plugins.json", blob: blob) == said)
        for mode in [CheckMode.installable, .strict, .official] {
            #expect { try repository.check(mode) } throws: { "\($0)" == said }
        }
        for flag in [[], ["--strict"], ["--official"]] {
            let result = CommandTests().run(["check-repo", "--repo", repository.folder.path] + flag)
            #expect(result.status == 2, "\(flag)")
            #expect(result.output == ["could not check: \(said)"], "\(flag)")
        }
    }

    /// git refuses a repository another user owns; a CI container running as
    /// root over a runner's checkout is one. The check opens that refusal for
    /// the one repository it reads, by the path git compares, and no other.
    @Test("safe.directory is opened for the repository being checked, and only for it")
    func safeDirectory() throws {
        let repository = try TestRepository()
        var options = RepositoryCheck.Options(mode: .strict)
        options.gitEnvironment = ["GIT_CEILING_DIRECTORIES": repository.temp.url.path,
                                  "GIT_TEST_ASSUME_DIFFERENT_OWNER": "1"]
        #expect(try RepositoryCheck.repository(repository.folder.path, options: options).findings.isEmpty)
        let folder = repository.folder.appendingPathComponent("plugins/sample")
        let checked = try RepositoryCheck.folder(folder.path, options: options)
        #expect(checked.commit != nil, "read through git, as committed")

        // The path git itself gives the top of the working copy, links resolved.
        let top = try repository.git("rev-parse", "--show-toplevel")
        for path in [repository.folder.path, folder.path] {
            let git = Git(repository: path, inherited: [:])
            #expect(git.trusted == top)
            #expect(git.arguments.contains("safe.directory=\(top)"))
            #expect(!git.arguments.contains("safe.directory=*"))
        }
        // Where there is no repository, nothing is opened; a bare one is its
        // own top.
        #expect(Git(repository: repository.temp.url.path, inherited: [:]).trusted == nil)
        #expect(Git(repository: repository.temp.url.appendingPathComponent("nowhere").path, inherited: [:]).trusted == nil)
        let bare = repository.temp.url.appendingPathComponent("bare.git")
        try CorpusGit.run(["init", "-q", "--bare", bare.path], in: repository.temp.url, scratch: repository.temp.url)
        #expect(Git(repository: bare.path, inherited: [:]).trusted == top.replacingOccurrences(of: "/repository", with: "/bare.git"))

        // Were it not opened, git would refuse, and the check would say why.
        let refused = Git(repository: repository.folder.path, trusting: nil, inherited: [:],
                          extra: ["GIT_TEST_ASSUME_DIFFERENT_OWNER": "1"])
        #expect {
            try refused.run(["rev-parse", "HEAD"])
        } throws: { error in
            "\(error)".hasPrefix("git will not read \(repository.folder.path), which another user owns: ")
        }
    }

    /// A repository's configuration can ask for its messages in another
    /// encoding; the sign-offs are read in UTF-8 all the same.
    @Test("sign-offs are read in UTF-8 whatever encoding the repository asks for its log")
    func signOffsInUTF8() throws {
        let repository = try TestRepository()
        try repository.git("config", "i18n.logOutputEncoding", "UTF-16")
        let base = try repository.git("rev-parse", "HEAD")
        let head = try repository.commit(["README.md": .text("# Changed\n")])
        #expect(try repository.check(.official, base: base, head: head).findings.isEmpty)
        #expect(Git.logSwitches.contains("--no-ext-diff") && Git.logSwitches.contains("--no-textconv"))
        #expect(Git.logSwitches.contains("--no-show-signature"))
    }

    /// A folder's path is a path, never a pattern: `plugins/a*` is not
    /// `plugins/ab`.
    @Test("a folder's path is not read as a pattern")
    func literalPaths() throws {
        let repository = try TestRepository(["plugins/a*/README.md": .text("# One\n"), "plugins/ab/README.md": .text("# Two\n")])
        try repository.write(["plugins/ab/new.txt": .text("new\n")])
        var options = RepositoryCheck.Options(mode: .installable)
        options.gitEnvironment["GIT_CEILING_DIRECTORIES"] = repository.temp.url.path
        let report = try RepositoryCheck.folder(repository.folder.appendingPathComponent("plugins/a*").path, options: options)
        #expect(report.commit != nil)
        #expect(report.notes.isEmpty, "\(report.notes)")
    }

    @Test("a folder that is not a repository, and a commit that is not there, cannot be checked")
    func couldNotCheck() throws {
        let temp = TemporaryDirectory()
        var options = RepositoryCheck.Options(mode: .strict)
        options.gitEnvironment["GIT_CEILING_DIRECTORIES"] = temp.url.path
        #expect(throws: CheckFailure.self) { try RepositoryCheck.repository(temp.url.path, options: options) }
        let repository = try TestRepository()
        #expect(throws: CheckFailure.self) { try repository.check(.strict, at: "no-such-branch") }
        #expect(throws: CheckFailure.self) {
            try repository.check(.official, base: "HEAD", head: "ffffffffffffffffffffffffffffffffffffffff")
        }
    }

    // MARK: - One folder

    /// Outside any working copy, a folder is read from disk: its modes are its
    /// execute bits, a link is a link, and there are no attributes.
    @Test("a folder outside git is checked on disk")
    func folderOnDisk() throws {
        let temp = TemporaryDirectory()
        let folder = temp.url.appendingPathComponent("sample")
        for (path, file) in try TestRepository.good() where path.hasPrefix("plugins/sample/") {
            let url = folder.appendingPathComponent(String(path.dropFirst("plugins/sample/".count)))
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            switch file {
            case .executable(let text):
                try Data(text.utf8).write(to: url)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            case .bytes(let bytes): try bytes.write(to: url)
            case .text(let text): try Data(text.utf8).write(to: url)
            case .link: break
            }
        }
        var options = RepositoryCheck.Options(mode: .strict)
        options.gitEnvironment["GIT_CEILING_DIRECTORIES"] = temp.url.path
        let clean = try RepositoryCheck.folder(folder.path, options: options)
        #expect(clean.commit == nil)
        #expect(clean.findings.isEmpty, "\(clean.findings)")

        try Data().write(to: folder.appendingPathComponent(".DS_Store"))
        try Data().write(to: folder.appendingPathComponent(".env"))
        try FileManager.default.createSymbolicLink(atPath: folder.appendingPathComponent("lib").path, withDestinationPath: "/usr/lib")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: folder.appendingPathComponent("run.sh").path)
        let report = try RepositoryCheck.folder(folder.path + "/", options: options)
        let shown = folder.path
        #expect(report.keys == ["error 7 \(shown)/.env", "error 6 \(shown)/lib", "error 5 \(shown)/run.sh"])
        #expect(report.findings.first { $0.rule == "5" }?.message.contains("chmod +x") == true)

        let misnamed = temp.url.appendingPathComponent("Not An Id")
        try FileManager.default.createDirectory(at: misnamed, withIntermediateDirectories: true)
        #expect(try RepositoryCheck.folder(misnamed.path, options: options).keys == ["error 1 \(misnamed.path)"])
        #expect(throws: CheckFailure.self) {
            try RepositoryCheck.folder(folder.appendingPathComponent("run.sh").path, options: options)
        }
    }

    /// Inside a working copy the folder is read as committed — the modes git
    /// has, the attributes the repository sets — and the check says when the
    /// working copy has more.
    @Test("a folder in a working copy is checked as committed")
    func folderInGit() throws {
        let repository = try TestRepository([".gitattributes": .text("plugins/sample/README.md export-subst\n")])
        let folder = repository.folder.appendingPathComponent("plugins/sample")
        var options = RepositoryCheck.Options(mode: .strict)
        options.gitEnvironment["GIT_CEILING_DIRECTORIES"] = repository.temp.url.path
        let report = try RepositoryCheck.folder(folder.path, options: options)
        let head = try repository.git("rev-parse", "HEAD")
        #expect(report.commit == head)
        #expect(report.keys == ["error 9 \(folder.path)/README.md"], "paths as the folder was given")
        #expect(report.notes.isEmpty)
        #expect(try RepositoryCheck.folder(folder.path, options: RepositoryCheck.Options(mode: .installable, environment: options.environment)).findings.isEmpty)

        // Broken in the working tree only: the committed folder is what counts.
        try repository.write(["plugins/sample/manifest.json": .text("{ not json")])
        let dirty = try RepositoryCheck.folder(folder.path, options: options)
        #expect(dirty.keys == ["error 9 \(folder.path)/README.md"])
        #expect(dirty.notes.count == 1)
        #expect(dirty.notes.first?.contains("not committed") == true)

        // Not committed at all: read from disk, and said so.
        try repository.write(["plugins/fresh/manifest.json": .text("{}")])
        let fresh = try RepositoryCheck.folder(repository.folder.appendingPathComponent("plugins/fresh").path, options: options)
        #expect(fresh.commit == nil)
        #expect(fresh.notes.first?.contains("on disk") == true)
        #expect(fresh.keys.contains("error 3 \(repository.folder.path)/plugins/fresh/manifest.json"))

        #expect(throws: CheckFailure.self) { try RepositoryCheck.folder(repository.folder.path, options: options) }
    }

    /// What counts as "changes that are not committed", found without git
    /// status: the files hashed as they are on disk, the index as it is, and
    /// the new files git would not ignore.
    @Test("a working copy's changes are found without git status", arguments: [
        ("nothing", false), ("a file's content", true), ("a file's mode", true), ("a file removed", true),
        ("a new file added to the index", true), ("a new file", true), ("a new file that is ignored", false),
        ("a .DS_Store", false), ("a link retargeted", true), ("a submodule, as committed", false),
    ])
    func workingCopyChanges(_ change: String, _ noted: Bool) throws {
        let repository = try TestRepository(["plugins/sample/lib": .link("run.sh")])
        let sample = repository.folder.appendingPathComponent("plugins/sample")
        let manager = FileManager.default
        switch change {
        case "a file's content": try repository.write(["plugins/sample/README.md": .text("# Changed\n")])
        case "a file's mode":
            try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sample.appendingPathComponent("README.md").path)
        case "a file removed": try manager.removeItem(at: sample.appendingPathComponent("README.md"))
        case "a new file added to the index":
            try repository.write(["plugins/sample/notes.txt": .text("notes\n")])
            try repository.git("add", "plugins/sample/notes.txt")
        case "a new file": try repository.write(["plugins/sample/notes.txt": .text("notes\n")])
        case "a new file that is ignored":
            try repository.commit([".gitignore": .text("*.log\n")])
            try repository.write(["plugins/sample/run.log": .text("output\n")])
        case "a .DS_Store": try repository.write(["plugins/sample/.DS_Store": .bytes(Data([0, 0, 0, 1]))])
        case "a link retargeted": try repository.write(["plugins/sample/lib": .link("README.md")])
        case "a submodule, as committed":
            // Committed straight from the index: a submodule nobody checked
            // out has no folder, and `git add -A` would take it away again.
            let head = try repository.git("rev-parse", "HEAD")
            try repository.git("update-index", "--add", "--cacheinfo", "160000,\(head),plugins/sample/vendor")
            try repository.git("commit", "-q", "-m", "A submodule")
            #expect(try repository.git("ls-tree", "HEAD", "plugins/sample/vendor").hasPrefix("160000 commit"))
        default: break
        }
        var options = RepositoryCheck.Options(mode: .installable)
        options.gitEnvironment["GIT_CEILING_DIRECTORIES"] = repository.temp.url.path
        let report = try RepositoryCheck.folder(sample.path, options: options)
        #expect(report.commit != nil)
        #expect(report.notes.contains { $0.contains("not committed") } == noted, "\(change): \(report.notes)")
    }

    /// A folder linked into uDeck's plugins folder is a link to the author's
    /// working copy (docs/plugin-repository.md); checking the link checks the
    /// folder, and says the path as it was given.
    @Test("check follows a link to a folder and names the link")
    func folderThroughALink() throws {
        let repository = try TestRepository(["plugins/sample/README.md": nil])
        var options = RepositoryCheck.Options(mode: .strict)
        options.gitEnvironment["GIT_CEILING_DIRECTORIES"] = repository.temp.url.path
        let links = repository.temp.url.appendingPathComponent("links")
        try FileManager.default.createDirectory(at: links, withIntermediateDirectories: true)
        let link = links.appendingPathComponent("sample")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: repository.folder.appendingPathComponent("plugins/sample"))
        let head = try repository.git("rev-parse", "HEAD")
        for given in [link.path, link.path + "/"] {
            let report = try RepositoryCheck.folder(given, options: options)
            #expect(report.commit == head, "read through git: \(given)")
            #expect(report.keys == ["error 10 \(link.path)/README.md"], "\(given)")
        }

        // Outside any working copy, from disk, the same.
        let loose = repository.temp.url.appendingPathComponent("loose")
        try FileManager.default.copyItem(at: repository.folder.appendingPathComponent("plugins/sample"), to: loose)
        let looseLink = links.appendingPathComponent("loose-link")
        try FileManager.default.createSymbolicLink(at: looseLink, withDestinationURL: loose)
        let onDisk = try RepositoryCheck.folder(looseLink.path, options: options)
        #expect(onDisk.commit == nil)
        #expect(onDisk.keys.contains("error 10 \(looseLink.path)/README.md"), "\(onDisk.keys)")
        #expect(onDisk.keys.allSatisfy { $0.contains(looseLink.path) }, "\(onDisk.keys)")

        // A link to a file is still not a folder.
        let file = links.appendingPathComponent("file")
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: repository.folder.appendingPathComponent("README.md"))
        #expect(throws: CheckFailure.self) { try RepositoryCheck.folder(file.path, options: options) }
    }
}
