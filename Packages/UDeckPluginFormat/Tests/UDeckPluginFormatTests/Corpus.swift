import Foundation
@testable import UDeckPluginFormat
import UDeckPluginFormatFixtures

/// `Corpus/corpus.json`: every repository the official repository's Python
/// check was run on, with what it reported — frozen by `Corpus/make-corpus.py`
/// while that check still exists, so that the Swift check replacing it can be
/// held to the same answers.
struct Corpus: Decodable, Sendable {
    static var folder: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Corpus", isDirectory: true)
    }

    /// Every rule a repository is checked against: the passport, and 1–17.
    static let rules = ["passport"] + (1 ... 17).map(String.init)

    struct Source: Decodable, Sendable {
        var repository: String
        var commit: String
        var python: String
        var git: String
        var sha256: [String: String]
    }

    struct Git: Decodable, Sendable {
        /// The `committer` line of every commit, and so of every commit id.
        var committer: String
        var branch: String
    }

    struct Tally: Decodable, Sendable, Equatable {
        var breaks: Int
        var passes: Int
    }

    var about: String
    var source: Source
    var git: Git
    var blobs: [String]
    var rules: [String: Tally]
    /// Every content any case has, once, under its git blob id.
    var contents: [String: [Segment]]
    /// The good repository — every path of it. A case's commits are changes
    /// to it.
    var base: [String: Entry]
    var cases: [Case]

    /// The bytes stored under `blob`.
    func bytes(_ blob: String) throws -> Data {
        guard let segments = contents[blob] else { throw CorpusGit.Failed(description: "no content \(blob)") }
        return try Segment.bytes(segments)
    }

    /// Every path of `commit`: the good repository, changed as it says.
    func files(of commit: Commit) -> [String: Entry] {
        var files = base
        for path in commit.remove { files[path] = nil }
        files.merge(commit.set) { _, changed in changed }
        return files
    }

    static func load() throws -> Corpus {
        try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: folder.appendingPathComponent("corpus.json")))
    }

    /// The corpus, or nothing when it will not load — `readsWhole` says why.
    /// For test arguments, which cannot throw.
    static let loaded: Corpus? = try? load()
}

extension Corpus {
    /// Bytes, as the generator wrote them: pieces of text, base64, one byte
    /// repeated, or a file of `Corpus/blobs/`, one after another.
    enum Segment: Decodable, Sendable {
        case text(String)
        case base64(Data)
        case repeated(byte: UInt8, count: Int)
        case blob(String)

        private enum Keys: String, CodingKey { case text, base64, byte, count, blob }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            if let text = try c.decodeIfPresent(String.self, forKey: .text) {
                self = .text(text)
            } else if let encoded = try c.decodeIfPresent(String.self, forKey: .base64) {
                guard let data = Data(base64Encoded: encoded) else {
                    throw DecodingError.dataCorruptedError(forKey: .base64, in: c, debugDescription: "not base64")
                }
                self = .base64(data)
            } else if let byte = try c.decodeIfPresent(UInt8.self, forKey: .byte) {
                self = .repeated(byte: byte, count: try c.decode(Int.self, forKey: .count))
            } else {
                self = .blob(try c.decode(String.self, forKey: .blob))
            }
        }

        static func bytes(_ segments: [Segment]) throws -> Data {
            var data = Data()
            for segment in segments {
                switch segment {
                case .text(let text): data.append(contentsOf: Array(text.utf8))
                case .base64(let bytes): data.append(bytes)
                case .repeated(let byte, let count): data.append(Data(repeating: byte, count: count))
                case .blob(let name):
                    data.append(try Data(contentsOf: Corpus.folder.appendingPathComponent("blobs/\(name)")))
                }
            }
            return data
        }
    }

    /// One path in a commit: a file with its mode and the id of its content,
    /// or a submodule.
    struct Entry: Decodable, Sendable, Equatable {
        var mode: String
        var blob: String?
        /// For a submodule (`160000`): the commit it points at.
        var commit: String?
    }

    struct Commit: Decodable, Sendable {
        /// What differs from the good repository — not from the parent.
        var set: [String: Entry]
        var remove: [String]
        var message: String
        /// The commit before it, by its place in the list.
        var parent: Int?
        /// The id git gave it when the Python check was run.
        var sha: String
    }

    struct Repository: Decodable, Sendable {
        var commits: [Commit]
    }

    /// A commit named to the check: one of the repository's, or an id it does
    /// not have.
    struct CommitReference: Decodable, Sendable {
        var commit: Int?
        var sha: String?
    }

    struct Check: Decodable, Sendable {
        var official: Bool
        var ref: String
        var base: CommitReference?
        var head: CommitReference?
    }

    struct Finding: Decodable, Sendable, Hashable, CustomStringConvertible {
        var level: String
        var rule: String
        var path: String
        /// The Python check's own words — for whoever reads a failure. The
        /// replay compares level, rule and path.
        var message: String?

        /// What the replay compares.
        var key: String { "\(level) \(rule) \(path)" }
        var description: String { key }
    }

    struct Expected: Decodable, Sendable {
        /// 0 clean or only warnings, 1 errors, 2 could not check.
        var exit: Int
        var findings: [Finding]
        var couldNotCheck: String?
    }

    /// Where the Python check is wrong, and what the Swift check must say
    /// instead.
    struct Divergence: Decodable, Sendable {
        var python: String
        var swift: String
        var findings: [Finding]
    }

    struct Case: Decodable, Sendable, CustomStringConvertible {
        var name: String
        /// The test in test_check_repo.py that built it, or the probe.
        var source: String?
        /// The rule the test or probe is about.
        var rule: String?
        var probe: String?
        /// Nil for a folder that is not a repository at all.
        var repository: Repository?
        var check: Check
        var expected: Expected
        /// Files written after the last commit and never committed, by content.
        var worktree: [String: String]?
        /// A personal `core.attributesFile` in the checker's git configuration,
        /// by content.
        var globalAttributes: String?
        var divergence: Divergence?

        var description: String { name }

        /// What the Swift check has to report: the Python check's findings,
        /// except where the corpus says Python is wrong.
        var findingsForSwift: Set<String> {
            Set((divergence?.findings ?? expected.findings).map(\.key))
        }
    }
}

// MARK: - Building a case's repository

/// A case's repository, made on disk the way test_check_repo.py made it:
/// `git fast-import` from the same commits, so the commit ids are the same.
struct BuiltRepository {
    let folder: URL
    /// The id git gave each commit here, in the corpus's order.
    let commits: [String]
}

enum CorpusGit {
    struct Failed: Error, CustomStringConvertible {
        var description: String
    }

    /// The environment every git here runs in: nobody's configuration, and a
    /// fixed author, as in test_check_repo.py. Git is not asked to look above
    /// `ceiling` for a repository, so a folder that is not one stays not one.
    static func environment(ceiling: URL) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        environment["GIT_AUTHOR_NAME"] = "Ada Lovelace"
        environment["GIT_AUTHOR_EMAIL"] = "ada@example.com"
        environment["GIT_AUTHOR_DATE"] = "2026-09-28T12:00:00Z"
        environment["GIT_COMMITTER_NAME"] = "Ada Lovelace"
        environment["GIT_COMMITTER_EMAIL"] = "ada@example.com"
        environment["GIT_COMMITTER_DATE"] = "2026-09-28T12:00:00Z"
        environment["GIT_CEILING_DIRECTORIES"] = ceiling.path
        return environment
    }

    /// Runs git in `folder`, feeding it `input`, and answers what it printed.
    @discardableResult
    static func run(_ arguments: [String], in folder: URL, input: Data? = nil, scratch: URL) throws -> String {
        let id = UUID().uuidString
        let inputFile = scratch.appendingPathComponent("\(id).in")
        let outputFile = scratch.appendingPathComponent("\(id).out")
        let errorFile = scratch.appendingPathComponent("\(id).err")
        // Files, not pipes: a fast-import stream holds up to ten megabytes, and
        // a pipe nobody is reading yet fills at sixty-four kilobytes.
        try (input ?? Data()).write(to: inputFile)
        FileManager.default.createFile(atPath: outputFile.path, contents: nil)
        FileManager.default.createFile(atPath: errorFile.path, contents: nil)
        defer {
            for file in [inputFile, outputFile, errorFile] { try? FileManager.default.removeItem(at: file) }
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", folder.path] + arguments
        process.environment = environment(ceiling: scratch)
        let stdin = try FileHandle(forReadingFrom: inputFile)
        let stdout = try FileHandle(forWritingTo: outputFile)
        let stderr = try FileHandle(forWritingTo: errorFile)
        defer { try? stdin.close(); try? stdout.close(); try? stderr.close() }
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: try Data(contentsOf: outputFile), as: UTF8.self)
        guard process.terminationStatus == 0 else {
            let error = String(decoding: try Data(contentsOf: errorFile), as: UTF8.self)
            throw Failed(description: "git \(arguments.first ?? "") failed (\(process.terminationStatus)): \(error)")
        }
        return output
    }

    /// Builds `repository` in a new folder inside `scratch`, with the files a
    /// test wrote after committing, and answers the commit ids git gave.
    static func build(_ item: Corpus.Case, of corpus: Corpus, in scratch: URL) throws -> BuiltRepository? {
        let git = corpus.git
        let folder = scratch.appendingPathComponent("repository", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let repository = item.repository else { return nil }

        try run(["init", "-q", "-b", git.branch, "--template="], in: folder, scratch: scratch)
        // A Mac's git sets this, and fast-import then folds Run.sh and run.sh
        // into one path — the very collision rule 7 exists to catch.
        try run(["config", "core.ignorecase", "false"], in: folder, scratch: scratch)

        var ids: [String] = []
        for commit in repository.commits {
            var stream = Data()
            func line(_ text: String) { stream.append(contentsOf: Array((text + "\n").utf8)) }
            func data(_ bytes: Data) {
                line("data \(bytes.count)")
                stream.append(bytes)
                line("")
            }
            line("commit refs/heads/\(git.branch)")
            line("committer \(git.committer)")
            data(Data(commit.message.utf8))
            if let parent = commit.parent {
                guard ids.indices.contains(parent) else { throw Failed(description: "no commit \(parent) yet") }
                line("from \(ids[parent])")
            }
            line("deleteall")
            for (path, entry) in corpus.files(of: commit).sorted(by: { $0.key < $1.key }) {
                if let submodule = entry.commit {
                    line("M \(entry.mode) \(submodule) \(path)")
                } else if let blob = entry.blob {
                    line("M \(entry.mode) inline \(path)")
                    data(try corpus.bytes(blob))
                } else {
                    throw Failed(description: "\(path) has neither content nor a commit")
                }
            }
            line("done")
            try run(["fast-import", "--quiet", "--done", "--force"], in: folder, input: stream, scratch: scratch)
            ids.append(try run(["rev-parse", "HEAD"], in: folder, scratch: scratch)
                .trimmingCharacters(in: .whitespacesAndNewlines))
        }

        for (path, blob) in item.worktree ?? [:] {
            let file = folder.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try corpus.bytes(blob).write(to: file)
        }
        return BuiltRepository(folder: folder, commits: ids)
    }
}

// MARK: - The Swift check, run on a case

/// What the Swift check says of a case's repository, run the way the Python
/// check was: strictly, as the official repository when the case says so, and
/// with its base and head.
enum CorpusReplay {
    struct Outcome: Equatable, CustomStringConvertible {
        /// 0 clean or only warnings, 1 errors, 2 could not check.
        var exit: Int
        var findings: Set<String>
        /// Every finding's words — not compared with the corpus, only read.
        var messages: [String] = []
        var description: String { "exit \(exit), \(findings.sorted())" }

        static func == (one: Outcome, other: Outcome) -> Bool {
            one.exit == other.exit && one.findings == other.findings
        }
    }

    static func run(_ item: Corpus.Case, of corpus: Corpus, in scratch: URL,
                    mode: CheckMode? = nil) throws -> Outcome {
        let built = try CorpusGit.build(item, of: corpus, in: scratch)
        let folder = scratch.appendingPathComponent("repository", isDirectory: true)
        func commit(_ reference: Corpus.CommitReference?) -> String? {
            guard let reference else { return nil }
            if let index = reference.commit, let ids = built?.commits, ids.indices.contains(index) { return ids[index] }
            return reference.sha
        }
        var options = RepositoryCheck.Options(mode: mode ?? (item.check.official ? .official : .strict),
                                              base: commit(item.check.base), head: commit(item.check.head),
                                              environment: try environment(for: item, of: corpus, in: scratch))
        // A folder that is not a repository stays one that is not, wherever
        // the scratch folder happens to be.
        options.gitEnvironment["GIT_CEILING_DIRECTORIES"] = scratch.path
        do {
            let report = try RepositoryCheck.repository(folder.path, at: item.check.ref, options: options)
            return Outcome(exit: report.errors.isEmpty ? 0 : 1,
                           findings: Set(report.findings.map { "\($0.level.rawValue) \($0.rule) \($0.path)" }),
                           messages: report.findings.map(\.message))
        } catch is CheckFailure {
            return Outcome(exit: 2, findings: [])
        }
    }

    /// The environment the check is started with. For a case with a personal
    /// attributes file, every way git could find one points at it — the
    /// check must hear none of them.
    static func environment(for item: Corpus.Case, of corpus: Corpus, in scratch: URL) throws -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        guard let id = item.globalAttributes else { return environment }
        let attributes = try corpus.bytes(id)
        let home = scratch.appendingPathComponent("home", isDirectory: true)
        let xdg = home.appendingPathComponent(".config/git", isDirectory: true)
        try FileManager.default.createDirectory(at: xdg, withIntermediateDirectories: true)
        let file = home.appendingPathComponent("attributes")
        try attributes.write(to: file)
        try attributes.write(to: xdg.appendingPathComponent("attributes"))
        let config = home.appendingPathComponent(".gitconfig")
        try Data("[core]\n\tattributesFile = \(file.path)\n".utf8).write(to: config)
        environment["HOME"] = home.path
        environment["XDG_CONFIG_HOME"] = home.appendingPathComponent(".config").path
        environment["GIT_CONFIG_GLOBAL"] = config.path
        return environment
    }

    /// Findings of rules the Python check never had — so the corpus cannot
    /// hold them — that the Swift check reports in a case. None today: rule 18
    /// needs history, which only rule 17's cases have, and none of them
    /// changes a plugin; rule 19 says nothing of the `minUDeck` the corpus
    /// declares — 0.6.0 and 99.0.0 are both past the smallest number the
    /// release that first reads the field can have, and nothing a plugin uses
    /// came after 0.1.0. Once that release
    /// has its number, a case declaring it or less gets rule 19's warning,
    /// and it is listed here.
    static let newRules: [String: Set<String>] = [:]

    /// What the Swift check must say of a case, as the corpus records it.
    static func expected(_ item: Corpus.Case) -> Outcome {
        let findings = item.findingsForSwift.union(newRules[item.name] ?? [])
        let exit = item.divergence == nil ? item.expected.exit : findings.contains { $0.hasPrefix("error ") } ? 1 : 0
        return Outcome(exit: exit, findings: findings)
    }
}
