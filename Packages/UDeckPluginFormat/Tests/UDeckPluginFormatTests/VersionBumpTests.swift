import Foundation
import Testing
@testable import UDeckPluginFormat
import UDeckPluginFormatFixtures

/// Rule 18: whenever anything in a plugin's folder changed, its `version` went
/// up — against `--base`, the target branch's tip, and without one against the
/// commit before; read as uDeck reads the version; and said, not passed, when
/// the clone lacks the history to compare with.
@Suite("Rule 18: a changed plugin's version goes up")
struct VersionBumpTests {
    static let manifest = RepositoryCheckTests.manifest

    static func bumped(_ version: String) throws -> TestRepository.File {
        try TestRepository.manifest(["version": version])
    }

    @Test("any change in a plugin's folder needs a new version — README included")
    func bump() throws {
        let repository = try TestRepository()
        let base = try repository.git("rev-parse", "HEAD")
        let unbumped = try repository.commit(["plugins/sample/README.md": .text("# Sample, changed\n")])
        #expect(try repository.check(.strict, base: base, head: unbumped).keys == ["error 18 \(Self.manifest)"])
        #expect(try repository.check(.installable, base: base, head: unbumped).keys == ["error 18 \(Self.manifest)"])
        let bumped = try repository.commit([Self.manifest: try Self.bumped("1.0.1")])
        #expect(try repository.check(.strict, base: base, head: bumped).findings.isEmpty)
        let older = try repository.commit([Self.manifest: try Self.bumped("0.9.0")])
        #expect(try repository.check(.strict, base: base, head: older).keys == ["error 18 \(Self.manifest)"])
        let finding = try #require(try repository.check(.strict, base: base, head: older).findings.first)
        #expect(finding.message.contains("1.0.1 or later"), "\(finding.message)")
    }

    @Test("a new plugin, a removed one, and one changed only on the target branch need nothing")
    func bumpNotNeeded() throws {
        let repository = try TestRepository()
        let start = try repository.git("rev-parse", "HEAD")
        // A new plugin, with any version.
        var files: [String: TestRepository.File?] = [:]
        for (path, file) in try TestRepository.good() where path.hasPrefix("plugins/sample/") {
            files[path.replacingOccurrences(of: "plugins/sample/", with: "plugins/second/")] = file
        }
        files["plugins/second/manifest.json"] = try TestRepository.manifest(["id": "second"])
        let added = try repository.commit(files)
        #expect(try repository.check(.strict, base: start, head: added).findings.isEmpty)
        // Removed.
        let removed = try repository.commit(files.mapValues { _ in nil })
        #expect(try repository.check(.strict, base: added, head: removed).findings.isEmpty)

        // The target branch changed sample; this branch did not touch it.
        try repository.git("checkout", "-q", "-b", "target", start)
        let target = try repository.commit([Self.manifest: try Self.bumped("1.1.0"),
                                            "plugins/sample/README.md": .text("# On target\n")])
        try repository.git("checkout", "-q", "-b", "topic", start)
        let topic = try repository.commit(["README.md": .text("# Top-level only\n")])
        #expect(try repository.check(.strict, base: target, head: topic).findings.isEmpty)
    }

    /// A manifest path that was a submodule on the base held no manifest
    /// there: the plugin is new, and a new plugin needs no version.
    @Test("a manifest that was a submodule on the base is a new plugin, not a changed one")
    func submoduleBefore() throws {
        let repository = try TestRepository()
        let first = try repository.git("rev-parse", "HEAD")
        try repository.git("update-index", "--add", "--cacheinfo", "160000,\(first),plugins/third/manifest.json")
        try CorpusGit.run(["commit", "-q", "-m", TestRepository.signedOff], in: repository.folder, scratch: repository.temp.url)
        let base = try repository.git("rev-parse", "HEAD")
        #expect(try repository.git("ls-tree", base, "plugins/third/manifest.json").hasPrefix("160000 commit "))
        var files: [String: TestRepository.File?] = [:]
        for (path, file) in try TestRepository.good() where path.hasPrefix("plugins/sample/") {
            files[path.replacingOccurrences(of: "plugins/sample/", with: "plugins/third/")] = file
        }
        files["plugins/third/manifest.json"] = try TestRepository.manifest(["id": "third"])
        let head = try repository.commit(files)
        #expect(try repository.check(.strict, base: base, head: head).findings.isEmpty)
    }

    /// Two pull requests both take `sample` to 1.0.1 with different content;
    /// the second, checked against the tip that has the first, must go on.
    @Test("the version is held to the target's tip, not to where the branch began")
    func bumpRace() throws {
        let repository = try TestRepository()
        let start = try repository.git("rev-parse", "HEAD")
        try repository.git("checkout", "-q", "-b", "first")
        let first = try repository.commit([Self.manifest: try Self.bumped("1.0.1"),
                                           "plugins/sample/README.md": .text("# First\n")])
        try repository.git("checkout", "-q", "-b", "second", start)
        let second = try repository.commit([Self.manifest: try Self.bumped("1.0.1"),
                                            "plugins/sample/README.md": .text("# Second\n")])
        #expect(try repository.check(.strict, base: start, head: second).findings.isEmpty)
        let raced = try repository.check(.strict, base: first, head: second)
        #expect(raced.keys == ["error 18 \(Self.manifest)"])
        #expect(raced.findings.first?.message.contains("1.0.2 or later") == true)
    }

    /// A push has no base to name: the commit before it is the base.
    @Test("without a base, the commit before HEAD is the base")
    func bumpAgainstParent() throws {
        let repository = try TestRepository()
        #expect(try repository.check(.strict).findings.isEmpty, "one commit, no parent")
        try repository.commit(["plugins/sample/run.sh": .executable("#!/bin/sh\necho '{ \"rows\": [] }'\n")])
        let report = try repository.check(.installable)
        #expect(report.keys == ["error 18 \(Self.manifest)"])
        #expect(report.findings.first?.message.contains("the commit before") == true)
        try repository.commit([Self.manifest: try Self.bumped("2.0.0")])
        #expect(try repository.check(.installable).findings.isEmpty)
    }

    /// The version is the one uDeck reads, so a manifest the strict reader
    /// refuses and uDeck installs is no way around the rule.
    @Test("rule 18 reads the version as uDeck does: a byte order mark or 1e400 is no way around it")
    func bumpAsUDeckReadsIt() throws {
        let manifest = try TestRepository.manifest([:])
        guard case .bytes(let good) = manifest else { throw CorpusGit.Failed(description: "no manifest") }
        let described = String(decoding: good, as: UTF8.self)
            .replacingOccurrences(of: "\"description\" : \"", with: "\"description\" : \"Changed. ")
        #expect(described != String(decoding: good, as: UTF8.self))
        let variants: [String: Data] = [
            "a byte order mark": Data([0xEF, 0xBB, 0xBF]) + Data(described.utf8),
            "1e400 in a field nobody reads": Data(described.replacingOccurrences(of: "{", with: "{ \"x-note\": 1e400,",
                                                                               options: .anchored).utf8),
        ]
        for (what, bytes) in variants {
            let repository = try TestRepository()
            let base = try repository.git("rev-parse", "HEAD")
            let head = try repository.commit([Self.manifest: .bytes(bytes)])
            #expect(try repository.check(.installable, base: base, head: head).keys == ["error 18 \(Self.manifest)"], "\(what)")
            #expect(try repository.check(.strict, base: base, head: head).keys
                    == ["error 3 \(Self.manifest)", "error 18 \(Self.manifest)"], "\(what)")
        }
    }

    /// A version given twice is the first to uDeck, whatever comes after.
    @Test("rule 18 holds the version uDeck reads when it is given twice: the first")
    func bumpWithTheVersionTwice() throws {
        let repository = try TestRepository()
        let base = try repository.git("rev-parse", "HEAD")
        let twice = try TestRepository.manifestText(["version": "1.0.0"], replacing: "\"version\" : \"1.0.0\"",
                                                    with: "\"version\" : \"1.0.0\", \"version\" : \"2.0.0\"")
        let head = try repository.commit([Self.manifest: twice])
        #expect(try repository.check(.installable, base: base, head: head).keys == ["error 18 \(Self.manifest)"])
        let bumpedFirst = try TestRepository.manifestText(["version": "1.0.0"], replacing: "\"version\" : \"1.0.0\"",
                                                          with: "\"version\" : \"1.0.1\", \"version\" : \"1.0.0\"")
        let fixed = try repository.commit([Self.manifest: bumpedFirst])
        #expect(try repository.check(.installable, base: base, head: fixed).findings.isEmpty)
    }

    /// A clone of one commit, as a CI checkout is by default.
    func shallowClone(of repository: TestRepository, branches: Bool = false) throws -> URL {
        let clone = repository.temp.url.appendingPathComponent("clone-\(UUID().uuidString)")
        try CorpusGit.run(["clone", "-q", "--depth", "1"] + (branches ? ["--no-single-branch"] : [])
                          + ["file://\(repository.folder.path)", clone.path], in: repository.temp.url, scratch: repository.temp.url)
        return clone
    }

    func check(_ folder: URL, _ mode: CheckMode, base: String? = nil, head: String? = nil,
               in repository: TestRepository, extra: [String: String] = [:]) throws -> CheckReport {
        var options = RepositoryCheck.Options(mode: mode, base: base, head: head)
        options.gitEnvironment = extra
        options.gitEnvironment["GIT_CEILING_DIRECTORIES"] = repository.temp.url.path
        return try RepositoryCheck.repository(folder.path, at: head ?? "HEAD", options: options)
    }

    /// Without the commit before HEAD there is nothing to compare with, and
    /// the check says so instead of passing — unless HEAD is a first commit,
    /// which has nothing before it anywhere.
    @Test("in a clone of one commit, rule 18 is said to be unchecked, not passed")
    func bumpInAShallowClone() throws {
        let repository = try TestRepository()
        try repository.commit(["plugins/sample/README.md": .text("# Sample, changed\n")])
        #expect(try repository.check(.installable).keys == ["error 18 \(Self.manifest)"], "the whole history")
        let report = try check(try shallowClone(of: repository), .installable, in: repository)
        #expect(report.errors.isEmpty)
        #expect(report.findings.map(\.description) == [
            "warning: rule 18 not checked: HEAD has no parent here — fetch history (fetch-depth: 2 or 0) [rule 18]",
        ])
        // A first commit has no parent in any clone, and nothing to compare —
        // a line of its message that starts with "parent" included.
        let first = try TestRepository(message: "Add a plugin\n\nparent of all the rest\n\n"
                                       + "Signed-off-by: Ada Lovelace <ada@example.com>\n")
        #expect(try check(try shallowClone(of: first), .strict, in: first).findings.isEmpty)
    }

    /// With a base whose history does not meet the head's here, every folder
    /// would look changed; the check says it cannot compare instead.
    @Test("with --base and no common history here, rule 18 says it cannot compare")
    func bumpWithoutAMergeBase() throws {
        let repository = try TestRepository()
        try repository.git("checkout", "-q", "-b", "topic")
        try repository.commit(["README.md": .text("# Only the top\n")])
        try repository.git("checkout", "-q", "main")
        try repository.commit(["LICENSE": .text("Moved on\n")])
        #expect(try repository.check(.strict, base: "main", head: "topic").findings.isEmpty, "the whole history")

        let clone = try shallowClone(of: repository, branches: true)
        let report = try check(clone, .strict, base: "origin/main", head: "origin/topic", in: repository)
        #expect(report.findings.map(\.description) == [
            "error: cannot compare with origin/main: no common history here — fetch full history (fetch-depth: 0) [rule 18]",
        ])
    }

    /// A clone without blobs — `actions/checkout` with `filter: blob:none` —
    /// has every commit and tree and only the files it checked out, and the
    /// check fetches nothing. The manifest the base has is listed and not
    /// there: the check says it cannot compare, rather than taking the plugin
    /// for one that is new. A plugin new on the branch, which the base does
    /// not list at all, still needs nothing.
    @Test("in a clone without blobs, rule 18 says it cannot compare, and a new plugin still needs nothing")
    func bumpInABloblessClone() async throws {
        let repository = try TestRepository()
        try repository.git("config", "uploadpack.allowFilter", "true")
        try repository.git("checkout", "-q", "-b", "topic")
        var files: [String: TestRepository.File?] = [:]
        for (path, file) in try TestRepository.good() where path.hasPrefix("plugins/sample/") {
            files[path.replacingOccurrences(of: "plugins/sample/", with: "plugins/second/")] = file
        }
        files["plugins/second/manifest.json"] = try TestRepository.manifest(["id": "second"])
        // Changed, and not bumped: the manifest's blob is a new one.
        files[Self.manifest] = try TestRepository.manifest(["description": "Changed, and still 1.0.0."])
        try repository.commit(files)
        try repository.git("checkout", "-q", "main")
        let unbumped = "error: plugins/sample/manifest.json: the folder changed, and \"version\" is 1.0.0 where "
        #expect(try repository.check(.installable, base: "main", head: "topic").findings.map(\.description).count == 1)
        #expect(try repository.check(.installable, base: "main", head: "topic").findings.first?.description
                    .hasPrefix(unbumped) == true)

        let clone = repository.temp.url.appendingPathComponent("blobless-\(UUID().uuidString)")
        try CorpusGit.run(["clone", "-q", "--no-local", "--no-checkout", "--filter=blob:none",
                           "file://\(repository.folder.path)", clone.path], in: repository.temp.url, scratch: repository.temp.url)
        try CorpusGit.run(["checkout", "-q", "topic"], in: clone, scratch: repository.temp.url)
        #expect(try CorpusGit.run(["config", "remote.origin.partialclonefilter"], in: clone, scratch: repository.temp.url)
                    .trimmingCharacters(in: .whitespacesAndNewlines) == "blob:none", "the clone is not a partial one")

        let notHere = "plugins/sample/manifest.json is not in this clone — fetch without a blob filter [rule 18]"
        let base = try CorpusGit.run(["rev-parse", "HEAD^1"], in: clone, scratch: repository.temp.url)
        // A git older than 2.45 knows no GIT_NO_LAZY_FETCH and tries to fetch
        // whatever it is asked for, and stops when it cannot (Linux's CI image
        // has 2.43); GIT_NO_LAZY_FETCH=0 is how a newer one behaves the same:
        // rule 18 gives the same answer either way.
        for (mode, extra) in [(CheckMode.installable, [:]), (.strict, [:]), (.installable, ["GIT_NO_LAZY_FETCH": "0"])] {
            let againstBase = try check(clone, mode, base: "origin/main", head: "HEAD", in: repository, extra: extra)
            #expect(againstBase.findings.map(\.description) == ["error: cannot compare with origin/main: \(notHere)"],
                    "\(mode) \(extra)")
            let againstParent = try check(clone, mode, in: repository, extra: extra)
            #expect(againstParent.findings.map(\.description)
                    == ["error: cannot compare with the commit before, \(base.prefix(12)): \(notHere)"], "\(mode) \(extra)")
        }
        // And a file the check reads that the clone does not hold is a check
        // that could not be made — said so; an older git, which tries to
        // fetch what it lists the size of, stops first and says it in its own
        // words. Which of the two this machine's git is decides what the
        // first case has to say: GIT_NO_LAZY_FETCH came with git 2.45.
        let lazyFetchCanBeRefused = try !Self.gitVersion(in: repository).lexicographicallyPrecedes([2, 45])
        for extra in [[:], ["GIT_NO_LAZY_FETCH": "0"]] {
            var options = RepositoryCheck.Options(mode: .installable)
            options.gitEnvironment = extra.merging(["GIT_CEILING_DIRECTORIES": repository.temp.url.path]) { new, _ in new }
            #expect {
                try RepositoryCheck.repository(clone.path, at: "origin/main", options: options)
            } throws: { error in
                guard error is CheckFailure else { return false }
                return !extra.isEmpty || !lazyFetchCanBeRefused
                    || "\(error)".hasPrefix("git could not read plugins/sample/manifest.json (blob ")
                    && "\(error)".hasSuffix("): it is not in this clone — fetch without a blob filter")
            }
        }
        let command = await CommandTests().run("check-repo", "--repo", clone.path, "--base", "origin/main", "--head", "HEAD")
        #expect(command.status == 1, "\(command.output)")
    }

    // MARK: - From the command line

    @Test("check-repo with --base and --head checks versions, and sign-offs as the official repository")
    func baseAndHead() async throws {
        let repository = try TestRepository()
        let base = try repository.git("rev-parse", "HEAD")
        let head = try repository.commit(["plugins/sample/README.md": .text("# Changed\n")], message: "Change\n")
        let official = await CommandTests().run("check-repo", "--official", "--repo", repository.folder.path, "--base", base, "--head", head)
        #expect(official.status == 1)
        #expect(official.output.filter { $0.hasSuffix("[rule 17]") }.count == 1)
        #expect(official.output.filter { $0.hasSuffix("[rule 18]") }.count == 1)
        let strict = await CommandTests().run("check-repo", "--strict", "--repo=\(repository.folder.path)", "--base=\(base)", "--head=\(head)")
        #expect(strict.output.filter { $0.hasSuffix("[rule 17]") }.isEmpty)
        #expect(strict.output.filter { $0.hasSuffix("[rule 18]") }.count == 1)
    }

    /// This machine's git as numbers: "git version 2.43.0" is [2, 43, 0].
    static func gitVersion(in repository: TestRepository) throws -> [Int] {
        let said = try CorpusGit.run(["version"], in: repository.temp.url, scratch: repository.temp.url)
        let words = said.split(separator: " ")
        guard words.count >= 3 else { return [] }
        return words[2].split(separator: ".").prefix(3).map { Int($0.prefix { $0.isNumber }) ?? 0 }
    }
}
