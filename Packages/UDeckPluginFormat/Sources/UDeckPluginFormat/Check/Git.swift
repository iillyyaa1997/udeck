#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Git, asked what a repository holds at a commit — and told nothing by
/// anybody's configuration.
///
/// The check reads a commit, not a working tree, because a commit is what
/// uDeck sees: every path with its mode, its blob and its size, the way GitHub
/// lists it. A script executable on disk but committed as `100644` has to be
/// judged as committed.
///
/// Git runs with an environment built here rather than inherited: no global or
/// system configuration, no `GIT_DIR` or `GIT_INDEX_FILE` a hook or a shell
/// left behind, no replace refs, no prompt.
///
/// **Nothing a repository says can make git start a program here.** Its own
/// configuration is still read — that is where a repository is described — and
/// git takes the names of programs from it in more places than one: a clean
/// filter it runs on files whose timestamps moved, a file-system monitor, hooks,
/// a pager, diff drivers, and in a partial clone a fetch of any object that is
/// missing, over whatever transport and `ssh` command the configuration names.
/// So no command here runs a filter (there is no `git status`, no `diff`, no
/// checkout), the monitor and the hooks are switched off, no transport of any
/// kind is allowed (`GIT_ALLOW_PROTOCOL`, which overrides every configuration),
/// a missing object is not fetched (`GIT_NO_LAZY_FETCH`), and the `ssh` command
/// is emptied besides. A manifest rule 18 compares and a partial clone left
/// out is never asked for in the first place (`absent`): a git too old to know
/// `GIT_NO_LAZY_FETCH` would try to fetch it and stop. A repository's
/// configuration can still make a command fail; it cannot make one do
/// anything else.
///
/// `safe.directory` — git's refusal to read a repository another user owns —
/// is opened for the one repository being checked, and no other: in CI the
/// checkout is often made by one user and read by another (a container running
/// as root over a runner's workspace), and the refusal is there to stop exactly
/// what the switches above already stop.
struct Git {
    let repository: String
    let environment: [String: String]
    /// The repository `repository` is in, as git finds it, links resolved:
    /// what `safe.directory` names. Nil when there is none.
    let trusted: String?

    /// Switches every git command here carries.
    static let switches = [
        "--no-pager",
        "-c", "core.fsmonitor=false",
        "-c", "core.hooksPath=/dev/null",
        // The attributes that count are the repository's: a personal file
        // (by default ~/.config/git/attributes) is not what an archive on
        // GitHub or GitLab applies.
        "-c", "core.attributesFile=/dev/null",
        "-c", "core.sshCommand=",
        "-c", "log.showSignature=false",
    ]

    /// Everything before the command itself.
    var arguments: [String] {
        Self.switches + (trusted.map { ["-c", "safe.directory=\($0)"] } ?? []) + ["-C", repository]
    }

    init(repository: String, inherited: [String: String], extra: [String: String] = [:]) {
        let environment = Self.environment(inherited: inherited, extra: extra)
        self.init(repository: repository, trusting: Self.topLevel(of: repository, environment: environment),
                  environment: environment)
    }

    /// With `trusted` given rather than found — for tests.
    init(repository: String, trusting trusted: String?, inherited: [String: String], extra: [String: String] = [:]) {
        self.init(repository: repository, trusting: trusted, environment: Self.environment(inherited: inherited, extra: extra))
    }

    private init(repository: String, trusting trusted: String?, environment: [String: String]) {
        self.repository = repository
        self.trusted = trusted
        self.environment = environment
    }

    /// The environment git runs in: `inherited` less every `GIT_` variable,
    /// with the check's own, and then `extra`.
    static func environment(inherited: [String: String], extra: [String: String]) -> [String: String] {
        var environment = inherited.filter { !$0.key.hasPrefix("GIT_") }
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        environment["GIT_ATTR_NOSYSTEM"] = "1"
        environment["GIT_NO_REPLACE_OBJECTS"] = "1"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GIT_LITERAL_PATHSPECS"] = "1"
        // Git 2.45 and later: a missing object stays missing.
        environment["GIT_NO_LAZY_FETCH"] = "1"
        // Every git since 2.6: the list of transports allowed, empty.
        environment["GIT_ALLOW_PROTOCOL"] = ""
        environment["LC_ALL"] = "C"
        environment.merge(extra) { _, new in new }
        return environment
    }

    /// Where git finds the repository that `path` is in — every link
    /// resolved, since that is the path git compares `safe.directory` with —
    /// as git itself answers it: the top of a working copy, or, where git
    /// says there is no working tree, the repository itself (a bare one, or
    /// the `.git` of a working copy when `path` is inside it). A folder that
    /// merely holds files named like a repository's is not one unless git
    /// says so. Nil when git finds none.
    ///
    /// Until git has found the repository nobody knows which path it will
    /// compare, so for this one question `safe.directory` is opened for `path`
    /// and every folder above it: the only paths git can compare for a
    /// repository it finds from `path`, which is the repository being checked.
    /// Every command after names only the path git answered.
    static func topLevel(of path: String, environment: [String: String]) -> String? {
        func resolved(_ path: String) -> String? {
            guard let real = realpath(path, nil) else { return nil }
            defer { free(real) }
            return String(cString: real)
        }
        guard let start = resolved(path) else { return nil }
        var opened: [String] = []
        var folder = start
        while true {
            opened += ["-c", "safe.directory=\(folder)"]
            guard folder != "/", let slash = folder.lastIndex(of: "/") else { break }
            folder = slash == folder.startIndex ? "/" : String(folder[..<slash])
        }
        // One question a call, so that the answer is the whole of what git
        // printed, less its line break — a path may hold one of its own.
        func ask(_ question: String) -> String? {
            guard let result = try? Subprocess.run(["git"] + switches + opened + ["-C", start, "rev-parse", question],
                                                   environment: environment),
                  result.status == 0 else { return nil }
            return String(decoding: result.output.dropLast(), as: UTF8.self)
        }
        // The top of the working copy is where git found `.git` — except
        // when core.worktree points the working tree elsewhere: git compares
        // safe.directory with the folder it found `.git` in, and that folder
        // is the repository's.
        if let top = ask("--show-toplevel").flatMap(resolved) {
            if FileManager.default.fileExists(atPath: top + "/.git") { return top }
            if let directory = ask("--absolute-git-dir").flatMap(resolved), directory.hasSuffix("/.git"),
               let slash = directory.lastIndex(of: "/") {
                return String(directory[..<slash])
            }
            return top
        }
        // No working tree: a bare repository, or `path` inside a `.git` — the
        // repository itself is what git compares.
        return ask("--absolute-git-dir").flatMap(resolved)
    }

    /// Runs git in the repository and answers its whole result, whatever the
    /// exit status.
    func attempt(_ arguments: [String], input: [UInt8] = [], environment extra: [String: String] = [:]) throws
        -> Subprocess.Result {
        let result = try Subprocess.run(["git"] + self.arguments + arguments,
                                        environment: environment.merging(extra) { _, new in new }, input: input)
        if result.status == 127 {
            throw CheckFailure("git is not installed, and the repository is read through it")
        }
        let said = String(decoding: result.errors, as: UTF8.self)
        if result.status != 0, said.contains("dubious ownership") {
            throw CheckFailure("git will not read \(repository), which another user owns: "
                               + Blank.trimmed(String(said.prefix { $0 != "\n" })))
        }
        return result
    }

    /// Runs git and answers what it printed, or throws what it said.
    func run(_ arguments: [String], input: [UInt8] = [], environment extra: [String: String] = [:]) throws -> [UInt8] {
        let result = try attempt(arguments, input: input, environment: extra)
        guard result.status == 0 else {
            let said = Blank.trimmed(String(decoding: result.errors, as: UTF8.self))
            throw CheckFailure("git \(arguments.joined(separator: " ")): \(said.isEmpty ? "exit status \(result.status)" : said)")
        }
        return result.output
    }

    /// The commit `revision` names, or a failure that says why the check could
    /// not be made.
    func commit(_ revision: String) throws -> String {
        guard let commit = try commitIfAny(revision) else { throw notACommit(revision) }
        return commit
    }

    /// What is said of a revision that names no commit here.
    func notACommit(_ revision: String) -> CheckFailure {
        CheckFailure("\(revision) is not a commit in \(repository) — a pull request's checkout needs fetch-depth: 0")
    }

    /// The commit `revision` names, or nil when it names none.
    func commitIfAny(_ revision: String) throws -> String? {
        let result = try attempt(["rev-parse", "--verify", "--quiet", revision + "^{commit}"])
        guard result.status == 0 else { return nil }
        let text = Blank.trimmed(String(decoding: result.output, as: UTF8.self))
        return GitHash.isObjectID(text) ? text : nil
    }

    /// Whether this clone is shallow — made with a depth, so that history
    /// stops short of where it began. `rev-parse --is-shallow-repository` has
    /// answered it since git 2.15; the Linux CI image has 2.43.
    func isShallow() throws -> Bool {
        let said = Blank.trimmed(String(decoding: try run(["rev-parse", "--is-shallow-repository"]), as: UTF8.self))
        guard said == "true" || said == "false" else {
            throw CheckFailure("git rev-parse --is-shallow-repository said \"\(said)\", not true or false")
        }
        return said == "true"
    }

    /// How many parents `commit` names in itself — whether or not this clone
    /// has them. A shallow clone keeps a commit whole and leaves its parents
    /// out, and `commit^1` is then no commit here, just as for a first commit,
    /// which names none.
    func parentsWritten(in commit: String) throws -> Int {
        let object = try run(["cat-file", "commit", commit])
        var count = 0
        for line in object.split(separator: 0x0A, omittingEmptySubsequences: false) {
            if line.isEmpty { break } // the headers end at the first empty line
            if line.starts(with: Array("parent ".utf8)) { count += 1 }
        }
        return count
    }

    /// The newest commit both have, or nil when their histories never meet.
    func mergeBase(_ one: String, _ other: String) throws -> String? {
        let result = try attempt(["merge-base", one, other])
        guard result.status == 0 else {
            if result.status == 1, result.errors.isEmpty { return nil }
            throw CheckFailure("git merge-base: \(String(decoding: result.errors, as: UTF8.self))")
        }
        return Blank.trimmed(String(decoding: result.output, as: UTF8.self))
    }

    /// Every path at `commit` — `git ls-tree -r -t -l`, which is what GitHub's
    /// recursive tree listing is to uDeck.
    func listing(_ commit: String) throws -> [TreeEntry] {
        let output = try run(["ls-tree", "-r", "-t", "-l", "-z", "--full-tree", commit])
        var entries: [TreeEntry] = []
        for record in output.split(separator: 0, omittingEmptySubsequences: true) {
            guard let tab = record.firstIndex(of: 0x09) else { continue }
            let meta = String(decoding: record[..<tab], as: UTF8.self).split(separator: " ", omittingEmptySubsequences: true)
            guard meta.count == 4 else { throw CheckFailure("git ls-tree gave a line it should not have") }
            let kind: TreeEntry.Kind = switch meta[1] {
            case "blob": .blob
            case "tree": .tree
            case "commit": .commit
            default: .other
            }
            // Names are bytes to git. Rule 7 reports the ones that are not
            // plain ASCII, so they must survive being read rather than stop it.
            let raw = Array(record[record.index(after: tab)...])
            entries.append(TreeEntry(path: String(decoding: raw, as: UTF8.self), rawPath: raw, mode: String(meta[0]),
                                     kind: kind, id: String(meta[2]), size: meta[3] == "-" ? nil : Int(meta[3])))
        }
        return entries
    }

    /// What is said of a file a commit lists and this clone does not hold.
    static func notInThisClone(_ path: String, blob: String) -> String {
        "git could not read \(path) (blob \(blob.prefix(12))): it is not in this clone — fetch without a blob filter"
    }

    /// The objects `commits` have under `paths` that this clone does not hold
    /// — what a partial clone left out — found without fetching any.
    /// `rev-list --missing=print` never fetches, whatever the git; `cat-file`,
    /// asked for such an object, has a git older than 2.45 (which does not
    /// know `GIT_NO_LAZY_FETCH`) try to fetch it, find no transport allowed,
    /// and stop. So nothing missing is ever asked of it. Every commit is
    /// listed, whatever it changed (`--full-history --sparse`).
    func absent(at commits: [String], under paths: [String]) throws -> Set<String> {
        let output = try run(["rev-list", "--objects", "--no-walk", "--full-history", "--sparse", "--missing=print"]
                             + commits + ["--"] + paths)
        var absent = Set<String>()
        for line in output.split(separator: 0x0A) where line.first == UInt8(ascii: "?") {
            absent.insert(String(decoding: line.dropFirst().prefix { $0 != 0x20 }, as: UTF8.self))
        }
        return absent
    }

    /// The contents of objects, each named any way `git cat-file` understands —
    /// a blob id, or `<commit>:<path>` — in one `git cat-file --batch`. A name
    /// that names no blob is left out of the answer: git says the same
    /// "missing" for a path a commit does not have and for an object a partial
    /// clone left out, so a caller that must tell them apart asks by blob id.
    func blobs(_ names: [String]) throws -> [String: [UInt8]] {
        let wanted = Array(Set(names)).sorted()
        guard !wanted.isEmpty else { return [:] }
        let output = try run(["cat-file", "--batch"], input: Array((wanted.joined(separator: "\n") + "\n").utf8))
        var found: [String: [UInt8]] = [:]
        var position = 0
        for name in wanted {
            guard let end = output[position...].firstIndex(of: 0x0A) else {
                throw CheckFailure("git cat-file stopped before \(name)")
            }
            let header = String(decoding: output[position ..< end], as: UTF8.self).split(separator: " ")
            position = end + 1
            if header.last == "missing" || header.count != 3 { continue }
            guard let size = Int(header[2]), position + size <= output.count else {
                throw CheckFailure("git could not read \(name)")
            }
            if header[1] == "blob" { found[name] = Array(output[position ..< position + size]) }
            position += size + 1
        }
        return found
    }

    /// What `.gitattributes` at `commit` sets, of `attributes`, for each path:
    /// read from the commit through an index of its own, never from a working
    /// tree. A folder is asked about with a trailing slash, which is how git
    /// matches a pattern written for folders only.
    func attributes(_ attributes: [String], at commit: String, of paths: [[UInt8]]) throws -> [[UInt8]: [String: String]] {
        guard !paths.isEmpty else { return [:] }
        let scratch = try ScratchFolder.make()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let index = ["GIT_INDEX_FILE": scratch.appendingPathComponent("index").path]
        _ = try run(["read-tree", commit], environment: index)
        let output = try run(["check-attr", "--cached", "-z", "--stdin"] + attributes,
                             input: paths.flatMap { $0 + [0] }, environment: index)
        let fields = output.split(separator: 0, omittingEmptySubsequences: false).map(Array.init)
        var found: [[UInt8]: [String: String]] = [:]
        var index3 = 0
        while index3 + 2 < fields.count {
            let value = String(decoding: fields[index3 + 2], as: UTF8.self)
            if value != "unspecified" && value != "unset" {
                found[fields[index3], default: [:]][String(decoding: fields[index3 + 1], as: UTF8.self)] = value
            }
            index3 += 3
        }
        return found
    }

    /// What `git log` is told besides: no patch is asked for, and none could
    /// be made by a diff driver or a text conversion of the repository's; no
    /// signature is verified, which would start `gpg.program`; and messages
    /// come in UTF-8, whatever `i18n.logOutputEncoding` the repository sets.
    static let logSwitches = ["--no-show-signature", "--no-ext-diff", "--no-textconv", "--encoding=UTF-8"]

    /// Every commit after `base` up to `head`, with its message — the commits
    /// a pull request brings.
    func commits(after base: String, upTo head: String) throws -> [(sha: String, message: String)] {
        let output = try run(["log"] + Self.logSwitches + ["-z", "--format=%H%n%B", "\(base)..\(head)"])
        return output.split(separator: 0, omittingEmptySubsequences: true).compactMap { record in
            let text = String(decoding: record, as: UTF8.self)
            guard !Blank.isBlank(text) else { return nil }
            let sha = text.prefix { $0 != "\n" }
            return (String(sha), String(text.dropFirst(sha.count + 1)))
        }
    }
}
