#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// The repository check: a plugin repository, or one plugin folder, held to
/// docs/plugin-repository.md — what `udeck-plugin check-repo` and
/// `udeck-plugin check` run, in a repository's CI and on an author's machine.
///
/// A repository is read through git, at one commit, and never through its
/// working tree (`Git`). One plugin folder is read the same way when it sits in
/// a git working copy and is committed there, and from disk when it does not —
/// with no attributes, since there is no commit an archive would be made of.
public enum RepositoryCheck {
    public struct Options: Sendable {
        public var mode: CheckMode
        /// The target branch's tip and the commit being checked, for rules 17
        /// and 18; both or neither.
        public var base: String?
        public var head: String?
        /// The environment git starts from. Every `GIT_` variable in it is left
        /// out (`Git`).
        public var environment: [String: String]
        /// Set after the above, `GIT_` or not — for tests, which keep git from
        /// looking above a folder that is not a repository.
        var gitEnvironment: [String: String] = [:]

        public init(mode: CheckMode = .installable, base: String? = nil, head: String? = nil,
                    environment: [String: String] = ProcessInfo.processInfo.environment) {
            self.mode = mode
            self.base = base
            self.head = head
            self.environment = environment
        }
    }

    /// Checks the repository `repository` at `revision`.
    public static func repository(_ repository: String, at revision: String = "HEAD",
                                  options: Options) throws -> CheckReport {
        guard (options.base == nil) == (options.head == nil) else { throw CheckFailure("--base and --head go together") }
        let git = Git(repository: repository, inherited: options.environment, extra: options.gitEnvironment)
        let tree = try Tree.commit(revision, of: git)
        let mode = options.mode
        var report = CheckReport()
        report.commit = tree.commit

        try passport(tree, mode: mode, report: &report)
        let folders = pluginFolders(tree, mode: mode, report: &report)
        let everything = folders.isEmpty ? [] : tree.under(CommitListing.pluginsFolder)
        try tree.load(everything.filter { ($0.size ?? 0) <= RepositoryRules.maximumFileBytes })
        var attributes: [String: [String: String]] = [:]
        if mode.strict, !folders.isEmpty, let plugins = tree.entries[CommitListing.pluginsFolder] {
            attributes = try tree.attributes(PluginRules.archiveAttributes, of: [plugins] + everything)
            PluginRules.archiveAttributes(of: plugins, attributes, &report)
        }
        for folder in folders {
            PluginRules.check(folder, id: String(folder.dropFirst(CommitListing.pluginsFolder.count + 1)), in: tree,
                              mode: mode, attributes: attributes, report: &report)
        }

        let head = tree.commit ?? revision
        if let base = options.base, let headRevision = options.head {
            let baseCommit = try git.commit(base)
            let headCommit = try git.commit(headRevision)
            if mode.official { try OfficialRules.signOffs(git, base: baseCommit, head: headCommit, report: &report) }
            try VersionBump.check(git, base: baseCommit, head: headCommit, label: base, report: &report)
        } else {
            // A push, with nothing to name a base: the branch as it was before
            // this commit, which on a squash-merged branch is the target's tip.
            try VersionBump.checkAgainstParent(git, head: head, report: &report)
        }
        if tree.entries[CommitListing.pluginsFolder]?.kind == .tree {
            report.pluginFolders = tree.children(of: CommitListing.pluginsFolder).filter { $0.kind == .tree }.count
        }
        return report
    }

    /// Checks the one plugin folder at `path` — through git when it is
    /// committed in a working copy, from disk when it is not.
    ///
    /// A link to a folder is followed — a folder linked into uDeck's plugins
    /// folder is a link to the author's working copy — and the findings name
    /// the path as it was given.
    public static func folder(_ path: String, options: Options) throws -> CheckReport {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let target = url.resolvingSymlinksInPath()
        let type = (try? FileManager.default.attributesOfItem(atPath: target.path))?[.type] as? FileAttributeType
        guard type == .typeDirectory else { throw CheckFailure("\(path) is not a folder") }
        var shown = path
        while shown.count > 1, shown.hasSuffix("/") { shown.removeLast() }
        // The folder's own name — in a working copy, the name the repository
        // has for it, which a link to it need not share.
        var id = url.lastPathComponent

        var report = CheckReport()
        report.pluginFolders = 1
        // Is it in a working copy? Git answers from the folder; everything
        // after is asked from the top, where the paths git lists start.
        let probe = Git(repository: url.path, inherited: options.environment, extra: options.gitEnvironment)
        let inside = try probe.attempt(["rev-parse", "--show-toplevel", "--show-prefix"])
        var tree: Tree?
        var folder = shown
        let answer = String(decoding: inside.output, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
        if inside.status == 0, answer.count >= 2 {
            let prefix = Blank.trimmed(String(answer[1]))
            guard !prefix.isEmpty else {
                throw CheckFailure("\(path) is the top of a repository; udeck-plugin check-repo checks a repository")
            }
            folder = String(prefix.dropLast(prefix.hasSuffix("/") ? 1 : 0))
            let top = String(answer[0])
            let git = Git(repository: top, inherited: options.environment, extra: options.gitEnvironment)
            if let commit = try git.commitIfAny("HEAD") {
                let committed = Tree(source: .git(git, commit: commit), entries: try git.listing(commit))
                if committed.entries[folder]?.kind == .tree {
                    tree = committed
                    id = String(folder.split(separator: "/").last ?? Substring(id))
                    if try WorkingCopy.differs(git, top: URL(fileURLWithPath: top), folder: folder, from: committed) {
                        report.notes.append("\(shown) has changes that are not committed; it was checked as committed "
                                            + "at \(commit.prefix(12)), which is what a repository would publish")
                    }
                }
            }
            if tree == nil {
                report.notes.append("\(shown) is not committed in its repository yet; it was checked on disk, "
                                    + "where git's attributes do not apply")
            }
        }
        if tree == nil {
            folder = shown
            tree = try Tree.disk(url, as: shown)
        }
        guard let tree else { return report }
        report.commit = tree.commit

        if PluginIdentifier(rawValue: id) == nil {
            report.error("1", shown, "folder name \"\(id)\" is not a plugin id: lowercase letters, digits and \"._-\", "
                         + "1-64 characters, starting with a letter or digit")
            return report
        }
        let everything = tree.under(folder)
        try tree.load(everything.filter { ($0.size ?? 0) <= RepositoryRules.maximumFileBytes })
        var attributes: [String: [String: String]] = [:]
        if options.mode.strict, let entry = tree.entries[folder] {
            attributes = try tree.attributes(PluginRules.archiveAttributes, of: [entry] + everything)
        }
        PluginRules.check(folder, id: id, in: tree, mode: options.mode, attributes: attributes, report: &report)
        // Findings name the folder as it was given, not as the repository
        // has it.
        if folder != shown {
            report.findings = report.findings.map { finding in
                var finding = finding
                if finding.path == folder {
                    finding.path = shown
                } else if finding.path.hasPrefix(folder + "/") {
                    finding.path = shown + finding.path.dropFirst(folder.count)
                }
                return finding
            }
        }
        return report
    }

    /// Takes away what runs of the check that were stopped — by a signal, by
    /// a CI job's timeout — left in the temporary folder (`ScratchFolder`).
    /// `udeck-plugin` does it as it starts.
    public static func sweepTemporaryFolder() {
        ScratchFolder.sweep(ScratchFolder.home)
    }

    // MARK: - The passport

    /// A passport the commit lists and the clone does not hold — a partial
    /// clone's — is a check that could not be made, never a finding about it.
    static func passport(_ tree: Tree, mode: CheckMode, report: inout CheckReport) throws {
        let path = RepositoryPassport.path
        let entry = tree.entries[path]
        if let entry, entry.kind == .blob { try tree.load([entry]) }
        let content = entry.flatMap(tree.content)
        let before = report.findings.count
        if mode.strict { strictPassport(entry, content, report: &report) }
        guard report.findings.count == before else { return }

        // What uDeck refuses, said in its own terms.
        switch RepositoryPassport.read(content.map { Data($0) }) {
        case .success: break
        case .failure(.missing):
            report.error(CheckRule.passport, path, entry == nil
                ? "is missing, so uDeck refuses the whole repository: it is what says a repository was meant to be a plugin repository"
                : entry?.kind != .blob ? "must be a file, so uDeck refuses the whole repository"
                : "is not JSON uDeck can read, so uDeck refuses the whole repository")
        case .failure(.futureFormat(let declared)):
            report.error(CheckRule.passport, path, "\"format\" is \(declared); this check, like uDeck, reads format "
                         + "\(RepositoryPassport.supportedFormat)")
        case .failure(.invalid(let reason)):
            report.error(CheckRule.passport, path, reason)
        }
    }

    /// The passport as the Python check read it: strict JSON, every field's
    /// shape, and no field the format does not define.
    static func strictPassport(_ entry: TreeEntry?, _ content: [UInt8]?, report: inout CheckReport) {
        let path = RepositoryPassport.path
        guard let entry else {
            report.error(CheckRule.passport, path, "is missing, so uDeck refuses the whole repository: it is what "
                         + "says a repository was meant to be a plugin repository")
            return
        }
        guard entry.isFile, let content else {
            report.error(CheckRule.passport, path, "must be a file, not a \(entry.isLink ? "symbolic link" : entry.kind == .tree ? "tree" : "submodule")")
            return
        }
        guard content.count <= RepositoryPassport.maximumBytes else {
            report.error(CheckRule.passport, path, RepositoryPassport.tooLarge(content.count))
            return
        }
        let document = StrictJSON.parse(content)
        for problem in document.problems { report.error(CheckRule.passport, path, problem) }
        guard let value = document.value else { return }
        guard let object = value.object else {
            report.error(CheckRule.passport, path, "must be a JSON object")
            return
        }
        var fields = ManifestShape.Fields(object)
        let format = fields.check("format", "a whole number", required: true, ManifestShape.isInteger)?.number?.wholeValue
        let name = fields.check("name", "a string", required: true) { $0.string != nil }?.string
        let description = fields.check("description", "a string") { $0.string != nil }?.string
        for problem in fields.wrong { report.error(CheckRule.passport, path, problem) }
        if let format, format != RepositoryPassport.supportedFormat {
            report.error(CheckRule.passport, path, "\"format\" is \(format); this check, like uDeck, reads format "
                         + "\(RepositoryPassport.supportedFormat)")
        }
        // Characters as Python counts them: code points.
        if let name, !(1 ... 64).contains(name.unicodeScalars.count) || PythonSpace.isBlank(name) {
            report.error(CheckRule.passport, path, "\"name\" must be 1-64 characters and not blank; it is "
                         + "\(name.unicodeScalars.count) characters")
        }
        if let description, description.unicodeScalars.count > 280 {
            report.error(CheckRule.passport, path, "\"description\" is \(description.unicodeScalars.count) characters; at most 280")
        }
        for field in object.keys where !["format", "name", "description"].contains(field) {
            report.error(CheckRule.passport, path, "has the field \"\(field)\", which the format does not define -- usually a typo")
        }
    }

    // MARK: - Rules 1 and 2

    /// The plugin folders to check one by one.
    static func pluginFolders(_ tree: Tree, mode: CheckMode, report: inout CheckReport) -> [String] {
        let plugins = CommitListing.pluginsFolder
        guard let top = tree.entries[plugins] else { return [] }
        guard top.kind == .tree else {
            report.error("1", plugins, "must be a folder holding one folder per plugin")
            return []
        }
        var folders: [String] = []
        for entry in tree.children(of: plugins) {
            guard entry.kind == .tree else {
                // uDeck ignores it; the repository check does not (rule 2).
                if mode.strict {
                    let what = entry.isLink ? "a symbolic link" : entry.isSubmodule ? "a submodule" : "a file"
                    report.error("2", entry.path, "is \(what) directly inside plugins/, which holds nothing but plugin folders")
                }
                continue
            }
            guard PluginIdentifier(rawValue: entry.name) != nil else {
                report.error("1", entry.path, "folder name \"\(entry.name)\" is not a plugin id: lowercase letters, digits "
                             + "and \"._-\", 1-64 characters, starting with a letter or digit")
                continue
            }
            folders.append(entry.path)
        }
        return folders
    }
}
