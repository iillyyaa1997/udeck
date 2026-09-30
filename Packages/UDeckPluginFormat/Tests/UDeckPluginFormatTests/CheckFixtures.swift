import Foundation
@testable import UDeckPluginFormat
import UDeckPluginFormatFixtures

/// A git repository made for one test, starting from the corpus's good
/// repository — a passport, and `plugins/sample`, which passes every rule.
final class TestRepository {
    enum File {
        case text(String)
        case executable(String)
        case bytes(Data)
        case link(String)
    }

    let temp = TemporaryDirectory()
    var folder: URL { temp.url.appendingPathComponent("repository", isDirectory: true) }

    /// The good repository's files.
    static func good() throws -> [String: File] {
        let corpus = try Corpus.load()
        var files: [String: File] = [:]
        for (path, entry) in corpus.base {
            guard let blob = entry.blob else { throw CorpusGit.Failed(description: "\(path) has no content") }
            let bytes = try corpus.bytes(blob)
            files[path] = entry.mode == "100755" ? .executable(String(decoding: bytes, as: UTF8.self)) : .bytes(bytes)
        }
        return files
    }

    /// A repository with the good repository committed, changed by `changes`
    /// (nil removes a path).
    init(_ changes: [String: File?] = [:], message: String = TestRepository.signedOff) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try git("init", "-q", "-b", "main", "--template=")
        try git("config", "core.ignorecase", "false")
        var files: [String: File?] = try Self.good()
        files.merge(changes) { _, new in new }
        try commit(files, message: message)
    }

    static let signedOff = "Add a plugin\n\nSigned-off-by: Ada Lovelace <ada@example.com>\n"

    @discardableResult
    func git(_ arguments: String...) throws -> String {
        try CorpusGit.run(arguments, in: folder, scratch: temp.url).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Writes `changes` into the working tree and commits them, answering the
    /// commit's id.
    @discardableResult
    func commit(_ changes: [String: File?], message: String = TestRepository.signedOff) throws -> String {
        try write(changes)
        try git("add", "-A")
        try CorpusGit.run(["commit", "-q", "--allow-empty", "-m", message], in: folder, scratch: temp.url)
        return try git("rev-parse", "HEAD")
    }

    /// Writes `changes` into the working tree, committing nothing.
    func write(_ changes: [String: File?]) throws {
        let manager = FileManager.default
        for (path, file) in changes {
            let url = folder.appendingPathComponent(path)
            try? manager.removeItem(at: url)
            guard let file else { continue }
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            switch file {
            case .text(let text): try Data(text.utf8).write(to: url)
            case .bytes(let bytes): try bytes.write(to: url)
            case .executable(let text):
                try Data(text.utf8).write(to: url)
                try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            case .link(let target): try manager.createSymbolicLink(atPath: url.path, withDestinationPath: target)
            }
        }
    }

    func check(_ mode: CheckMode, base: String? = nil, head: String? = nil, at revision: String = "HEAD",
               environment: [String: String] = ProcessInfo.processInfo.environment) throws -> CheckReport {
        var options = RepositoryCheck.Options(mode: mode, base: base, head: head, environment: environment)
        options.gitEnvironment["GIT_CEILING_DIRECTORIES"] = temp.url.path
        return try RepositoryCheck.repository(folder.path, at: revision, options: options)
    }

    /// The good sample manifest, changed as `manifest` changes it, with one
    /// piece of its text then replaced — for what JSONSerialization would not
    /// write, like `1.0`.
    static func manifestText(_ fields: [String: Any?], replacing old: String, with new: String) throws -> File {
        guard case .bytes(let bytes) = try manifest(fields) else { throw CorpusGit.Failed(description: "no manifest") }
        let text = String(decoding: bytes, as: UTF8.self)
        guard text.contains(old) else { throw CorpusGit.Failed(description: "no \(old) in \(text)") }
        return .text(text.replacingOccurrences(of: old, with: new))
    }

    /// The good sample manifest, changed: `fields` set, `nil` removing one.
    static func manifest(_ fields: [String: Any?]) throws -> File {
        let corpus = try Corpus.load()
        guard let blob = corpus.base["plugins/sample/manifest.json"]?.blob,
              var object = try JSONSerialization.jsonObject(with: try corpus.bytes(blob)) as? [String: Any] else {
            throw CorpusGit.Failed(description: "no sample manifest")
        }
        for (key, value) in fields { object[key] = value }
        return .bytes(try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]))
    }
}

extension CheckReport {
    /// `level rule path` of every finding, as the corpus compares them.
    var keys: Set<String> { Set(findings.map { "\($0.level.rawValue) \($0.rule) \($0.path)" }) }
}
